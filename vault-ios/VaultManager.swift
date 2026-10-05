import Foundation
import Combine
import LocalAuthentication
import Security
import CryptoKit

@MainActor
final class VaultManager: ObservableObject {
    @Published var metadata = VaultMetadataIndex()
    @Published var activeVaultDirectoryURL: URL? = nil
    @Published var isUnlocked: Bool = false
    @Published var isBusy: Bool = false
    @Published var statusDescription: String = "Locked"
    @Published var activeError: String? = nil
    @Published var isBiometricsAvailable: Bool = false

    // Instant O(1) in-memory index
    @Published private(set) var filesByFolder: [UUID?: [EncryptedFileHeader]] = [:]
    @Published private(set) var subfoldersByParent: [UUID?: [VaultFolder]] = [:]

    private var masterKey: SymmetricKey? = nil
    private var cachedSalt: Data? = nil
    private var cachedPassword: String? = nil
    private let keychainService = "com.likithsai.vaultios.master"

    private var storageDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("ActiveVaultStorage", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    init() {
        checkBiometricAvailability()
    }

    func checkBiometricAvailability() {
        let context = LAContext()
        var error: NSError?
        self.isBiometricsAvailable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    private func rebuildLookupIndex() {
        var fMap: [UUID?: [EncryptedFileHeader]] = [:]
        for f in metadata.fileHeaders {
            fMap[f.folder_id, default: []].append(f)
        }
        self.filesByFolder = fMap

        var dirMap: [UUID?: [VaultFolder]] = [:]
        for folder in metadata.folders {
            dirMap[folder.parent_id, default: []].append(folder)
        }
        self.subfoldersByParent = dirMap
    }

    // MARK: - Container Lifecycle

    func unlockVault(at originalURL: URL, password: String, saveToBiometrics: Bool = false) async {
        isBusy = true
        statusDescription = "Deriving key (Argon2id 64MB)..."
        activeError = nil

        let didAccess = originalURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { originalURL.stopAccessingSecurityScopedResource() }
        }

        do {
            let containerBytes = try Data(contentsOf: originalURL, options: .alwaysMapped)
            guard containerBytes.count >= VaultCrypto.saltLength else {
                throw CryptoVaultError.payloadTooShort
            }

            let salt = containerBytes.prefix(VaultCrypto.saltLength)
            let combined = containerBytes.dropFirst(VaultCrypto.saltLength)

            let derived = try await Task.detached(priority: .userInitiated) {
                try VaultCrypto.deriveKey(password: password, salt: salt)
            }.value

            self.statusDescription = "Decrypting container index..."
            let decryptedIndexData = try VaultCrypto.decryptBlock(combinedCiphertext: combined, using: derived)
            let decodedIndex = try JSONDecoder().decode(VaultMetadataIndex.self, from: decryptedIndexData)

            self.masterKey = derived
            self.cachedSalt = salt
            self.cachedPassword = password
            self.metadata = decodedIndex
            self.activeVaultDirectoryURL = originalURL
            self.rebuildLookupIndex()
            self.isUnlocked = true
            self.statusDescription = "Vault unlocked"

            if saveToBiometrics {
                savePasswordToKeychain(password: password, vaultURL: originalURL)
            }
        } catch {
            self.activeError = error.localizedDescription
            self.statusDescription = "Authentication failed"
        }
        isBusy = false
    }

    func unlockWithBiometrics(at originalURL: URL) async {
        guard let savedPassword = readPasswordFromKeychain(for: originalURL) else {
            self.activeError = "No biometrics enrolled for this container."
            return
        }

        let context = LAContext()
        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock IronVault")
            if success {
                await unlockVault(at: originalURL, password: savedPassword, saveToBiometrics: false)
            }
        } catch {
            self.activeError = "Biometric authentication failed."
        }
    }

    func createNewVault(at targetURL: URL, password: String, saveToBiometrics: Bool = false) async {
        isBusy = true
        statusDescription = "Generating container with fresh salt..."
        activeError = nil

        let didAccess = targetURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { targetURL.stopAccessingSecurityScopedResource() }
        }

        do {
            var salt = Data(count: VaultCrypto.saltLength)
            let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, VaultCrypto.saltLength, $0.baseAddress!) }
            guard status == errSecSuccess else { throw CryptoVaultError.encryptionFailed }

            let derived = try await Task.detached(priority: .userInitiated) {
                try VaultCrypto.deriveKey(password: password, salt: salt)
            }.value

            let emptyIndex = VaultMetadataIndex()
            let serialized = try JSONEncoder().encode(emptyIndex)
            let encryptedIndex = try VaultCrypto.encryptBlock(plainData: serialized, using: derived)

            var output = Data()
            output.reserveCapacity(salt.count + encryptedIndex.count)
            output.append(salt)
            output.append(encryptedIndex)
            try output.write(to: targetURL, options: .atomic)

            self.masterKey = derived
            self.cachedSalt = salt
            self.cachedPassword = password
            self.metadata = emptyIndex
            self.activeVaultDirectoryURL = targetURL
            self.rebuildLookupIndex()
            self.isUnlocked = true
            self.statusDescription = "New vault active"

            if saveToBiometrics {
                savePasswordToKeychain(password: password, vaultURL: targetURL)
            }
        } catch {
            self.activeError = error.localizedDescription
            self.statusDescription = "Failed to create vault"
        }
        isBusy = false
    }

    func changeMasterPassword(newPassword: String) async {
        guard isUnlocked, let url = activeVaultDirectoryURL else { return }
        isBusy = true
        statusDescription = "Rekeying container with new Argon2id salt..."

        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        do {
            var newSalt = Data(count: VaultCrypto.saltLength)
            let status = newSalt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, VaultCrypto.saltLength, $0.baseAddress!) }
            guard status == errSecSuccess else { throw CryptoVaultError.encryptionFailed }

            let newDerivedKey = try await Task.detached(priority: .userInitiated) {
                try VaultCrypto.deriveKey(password: newPassword, salt: newSalt)
            }.value

            let serialized = try JSONEncoder().encode(metadata)
            let encryptedIndex = try VaultCrypto.encryptBlock(plainData: serialized, using: newDerivedKey)

            var output = Data()
            output.reserveCapacity(newSalt.count + encryptedIndex.count)
            output.append(newSalt)
            output.append(encryptedIndex)
            try output.write(to: url, options: .atomic)

            self.masterKey = newDerivedKey
            self.cachedSalt = newSalt
            self.cachedPassword = newPassword
            savePasswordToKeychain(password: newPassword, vaultURL: url)
            self.statusDescription = "Password updated"
        } catch {
            self.activeError = "Rekeying failed: \(error.localizedDescription)"
        }
        isBusy = false
    }

    private func persistIndexOnly() async {
        guard let key = masterKey, let salt = cachedSalt, let url = activeVaultDirectoryURL else { return }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let serialized = try JSONEncoder().encode(metadata)
            let encryptedIndex = try VaultCrypto.encryptBlock(plainData: serialized, using: key)

            var output = Data()
            output.reserveCapacity(salt.count + encryptedIndex.count)
            output.append(salt)
            output.append(encryptedIndex)
            try output.write(to: url, options: .atomic)
        } catch {
            self.activeError = "Failed to persist index: \(error.localizedDescription)"
        }
    }

    // MARK: - Lazy File Operations

    func readAndDecryptPayload(for file: EncryptedFileHeader) throws -> Data {
        guard let key = masterKey else { throw CryptoVaultError.decryptionFailed }
        let diskURL = storageDirectory.appendingPathComponent(file.storage_filename)
        let encryptedFileBytes = try Data(contentsOf: diskURL, options: .mappedIfSafe)
        return try VaultCrypto.decryptBlock(combinedCiphertext: encryptedFileBytes, using: key)
    }

    func importFile(name: String, sourceURL: URL, folderId: UUID?) async {
        guard let key = masterKey else { return }
        isBusy = true
        statusDescription = "Encrypting \(name)..."

        do {
            let rawData = try Data(contentsOf: sourceURL, options: .alwaysMapped)
            let encryptedData = try await Task.detached(priority: .userInitiated) {
                try VaultCrypto.encryptBlock(plainData: rawData, using: key)
            }.value

            let storageId = UUID().uuidString
            let destination = storageDirectory.appendingPathComponent(storageId)
            try encryptedData.write(to: destination, options: .atomic)

            let header = EncryptedFileHeader(
                file_name: name,
                file_size_bytes: rawData.count,
                folder_id: folderId,
                storage_filename: storageId
            )

            metadata.fileHeaders.append(header)
            rebuildLookupIndex()
            await persistIndexOnly()
        } catch {
            self.activeError = "Import failed: \(error.localizedDescription)"
        }
        isBusy = false
    }

    func deleteFile(id: UUID) async {
        if let idx = metadata.fileHeaders.firstIndex(where: { $0.id == id }) {
            let file = metadata.fileHeaders[idx]
            let fileOnDisk = storageDirectory.appendingPathComponent(file.storage_filename)
            try? FileManager.default.removeItem(at: fileOnDisk)

            metadata.fileHeaders.remove(at: idx)
            rebuildLookupIndex()
            await persistIndexOnly()
        }
    }

    func renameFile(id: UUID, newName: String) async {
        if let idx = metadata.fileHeaders.firstIndex(where: { $0.id == id }) {
            metadata.fileHeaders[idx].file_name = newName
            rebuildLookupIndex()
            await persistIndexOnly()
        }
    }

    func moveFile(id: UUID, toFolderId: UUID?) async {
        if let idx = metadata.fileHeaders.firstIndex(where: { $0.id == id }) {
            metadata.fileHeaders[idx].folder_id = toFolderId
            rebuildLookupIndex()
            await persistIndexOnly()
        }
    }

    // MARK: - Folder Operations

    func createFolder(name: String, parentId: UUID?) async {
        let folder = VaultFolder(name: name, parent_id: parentId)
        metadata.folders.append(folder)
        rebuildLookupIndex()
        await persistIndexOnly()
    }

    func renameFolder(id: UUID, newName: String) async {
        if let idx = metadata.folders.firstIndex(where: { $0.id == id }) {
            metadata.folders[idx].name = newName
            rebuildLookupIndex()
            await persistIndexOnly()
        }
    }

    func moveFolder(id: UUID, toFolderId: UUID?) async {
        guard id != toFolderId else { return }
        var current = toFolderId
        while let parent = current {
            if parent == id { return }
            current = metadata.folders.first(where: { $0.id == parent })?.parent_id
        }

        if let idx = metadata.folders.firstIndex(where: { $0.id == id }) {
            metadata.folders[idx].parent_id = toFolderId
            rebuildLookupIndex()
            await persistIndexOnly()
        }
    }

    func deleteFolder(id: UUID) async {
        var toDeleteFolderIds = Set<UUID>([id])
        var addedMore = true
        while addedMore {
            let directChildren = metadata.folders.filter { f in
                if let p = f.parent_id, toDeleteFolderIds.contains(p) {
                    return !toDeleteFolderIds.contains(f.id)
                }
                return false
            }.map { $0.id }
            if directChildren.isEmpty { addedMore = false } else { toDeleteFolderIds.formUnion(directChildren) }
        }

        let filesToDelete = metadata.fileHeaders.filter { f in
            guard let parent = f.folder_id else { return false }
            return toDeleteFolderIds.contains(parent)
        }

        for f in filesToDelete {
            let path = storageDirectory.appendingPathComponent(f.storage_filename)
            try? FileManager.default.removeItem(at: path)
        }

        metadata.fileHeaders.removeAll { f in
            if let p = f.folder_id { return toDeleteFolderIds.contains(p) }
            return false
        }
        metadata.folders.removeAll { toDeleteFolderIds.contains($0.id) }

        rebuildLookupIndex()
        await persistIndexOnly()
    }

    func lockVault() {
        self.masterKey = nil
        self.cachedSalt = nil
        self.cachedPassword = nil
        self.metadata = VaultMetadataIndex()
        self.filesByFolder = [:]
        self.subfoldersByParent = [:]
        self.activeVaultDirectoryURL = nil
        self.isUnlocked = false
        self.statusDescription = "Locked"
    }

    // MARK: - Keychain Biometric Support

    private func savePasswordToKeychain(password: String, vaultURL: URL) {
        let account = vaultURL.path
        let data = password.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var newQuery = query
        newQuery[kSecValueData as String] = data
        SecItemAdd(newQuery as CFDictionary, nil)
    }

    func readPasswordFromKeychain(for vaultURL: URL) -> String? {
        let account = vaultURL.path
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
