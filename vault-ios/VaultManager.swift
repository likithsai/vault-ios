import Foundation
import Combine
import LocalAuthentication
import Security
import CryptoKit

@MainActor
final class VaultManager: ObservableObject {
    @Published var metadata = VaultMetadataIndex()
    @Published var activeVaultURL: URL? = nil
    @Published var isUnlocked: Bool = false
    @Published var isBusy: Bool = false
    @Published var statusDescription: String = "Locked"
    @Published var activeError: String? = nil
    @Published var isBiometricsAvailable: Bool = false

    @Published private(set) var filesByFolder: [UUID?: [EncryptedFileHeader]] = [:]
    @Published private(set) var subfoldersByParent: [UUID?: [VaultFolder]] = [:]
    @Published var availableVaults: [URL] = []

    private var masterKey: SymmetricKey? = nil
    private var cachedSalt: Data? = nil
    private var cachedPassword: String? = nil

    private let keychainService = "com.likithsai.vaultios.master"
    private let savedBookmarksKey = "com.likithsai.ironvault.savedVaultBookmarks"

    private static let magicHeader = "IVLT".data(using: .utf8)!
    private static let headerSize: UInt64 = 40

    init() {
        checkBiometricAvailability()
        refreshAvailableVaults()
    }

    func checkBiometricAvailability() {
        let context = LAContext()
        var error: NSError?
        self.isBiometricsAvailable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    func evaluateBiometricPrompt() async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return false
        }
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Unlock IronVault"
            )
        } catch {
            return false
        }
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

    // MARK: - Persistent Vault List Management

    func recordVault(at url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        var storedBookmarks = UserDefaults.standard.array(forKey: savedBookmarksKey) as? [Data] ?? []
        
        do {
            let bookmarkData = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            let urlStandard = url.standardizedFileURL.path
            var alreadyExists = false
            for data in storedBookmarks {
                var isStale = false
                if let resolved = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale),
                   resolved.standardizedFileURL.path == urlStandard {
                    alreadyExists = true
                    break
                }
            }

            if !alreadyExists {
                storedBookmarks.append(bookmarkData)
                UserDefaults.standard.set(storedBookmarks, forKey: savedBookmarksKey)
            }
        } catch {
            print("Failed to record bookmark: \(error.localizedDescription)")
        }

        refreshAvailableVaults()
    }

    func removeVaultFromList(at index: Int) {
        var storedBookmarks = UserDefaults.standard.array(forKey: savedBookmarksKey) as? [Data] ?? []
        guard index < availableVaults.count else { return }
        let targetURL = availableVaults[index]

        storedBookmarks.removeAll { data in
            var isStale = false
            if let resolved = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale),
               resolved.standardizedFileURL.path == targetURL.standardizedFileURL.path {
                return true
            }
            return false
        }

        UserDefaults.standard.set(storedBookmarks, forKey: savedBookmarksKey)
        refreshAvailableVaults()
    }

    func refreshAvailableVaults() {
        var resolvedVaults: [URL] = []
        let fileManager = FileManager.default

        // 1. Resolve stored bookmarks
        let storedBookmarks = UserDefaults.standard.array(forKey: savedBookmarksKey) as? [Data] ?? []
        for bookmarkData in storedBookmarks {
            var isStale = false
            if let resolvedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withoutUI,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                if !resolvedVaults.contains(where: { $0.standardizedFileURL.path == resolvedURL.standardizedFileURL.path }) {
                    resolvedVaults.append(resolvedURL)
                }
            }
        }

        // 2. Discover local sandbox vaults in App Documents
        if let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
           let contents = try? fileManager.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) {
            let localVaults = contents.filter { $0.pathExtension == "ivault" }
            for local in localVaults {
                if !resolvedVaults.contains(where: { $0.standardizedFileURL.path == local.standardizedFileURL.path }) {
                    resolvedVaults.append(local)
                }
            }
        }

        self.availableVaults = resolvedVaults
    }

    // MARK: - Unlock & Open

    func unlockVault(at fileURL: URL, password: String, saveToBiometrics: Bool = false) async {
        isBusy = true
        statusDescription = "Reading container header..."
        activeError = nil

        let didAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { fileURL.stopAccessingSecurityScopedResource() }
        }

        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }

            guard let headerData = try handle.read(upToCount: Int(Self.headerSize)),
                  headerData.count == Int(Self.headerSize) else {
                throw CryptoVaultError.payloadTooShort
            }

            let magic = headerData.prefix(4)
            guard magic == Self.magicHeader else { throw CryptoVaultError.payloadTooShort }

            let salt = headerData.subdata(in: 4..<20)
            let indexOffset = headerData.subdata(in: 20..<28).withUnsafeBytes { $0.load(as: UInt64.self) }
            let indexLength = headerData.subdata(in: 28..<36).withUnsafeBytes { $0.load(as: UInt64.self) }

            self.statusDescription = "Deriving key (Argon2id)..."
            let derived = try await Task.detached(priority: .userInitiated) {
                try VaultCrypto.deriveKey(password: password, salt: salt)
            }.value

            try handle.seek(toOffset: indexOffset)
            guard let encryptedIndex = try handle.read(upToCount: Int(indexLength)) else {
                throw CryptoVaultError.payloadTooShort
            }

            self.statusDescription = "Decrypting table of contents..."
            let decryptedIndexData = try VaultCrypto.decryptBlock(combinedCiphertext: encryptedIndex, using: derived)
            let decodedIndex = try JSONDecoder().decode(VaultMetadataIndex.self, from: decryptedIndexData)

            self.masterKey = derived
            self.cachedSalt = salt
            self.cachedPassword = password
            self.metadata = decodedIndex
            self.activeVaultURL = fileURL
            self.rebuildLookupIndex()
            self.isUnlocked = true
            self.statusDescription = "Vault unlocked"

            self.recordVault(at: fileURL)

            if saveToBiometrics {
                savePasswordToKeychain(password: password, vaultURL: fileURL)
            }
        } catch {
            self.activeError = error.localizedDescription
            self.statusDescription = "Authentication failed"
        }
        isBusy = false
    }

    func createNewVault(at targetURL: URL, password: String, saveToBiometrics: Bool = false) async {
        isBusy = true
        statusDescription = "Initializing container..."
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

            var initialOffset = Self.headerSize
            var indexLen = UInt64(encryptedIndex.count)
            var reserved: UInt32 = 0

            var fileData = Data()
            fileData.append(Self.magicHeader)
            fileData.append(salt)
            fileData.append(Data(bytes: &initialOffset, count: 8))
            fileData.append(Data(bytes: &indexLen, count: 8))
            fileData.append(Data(bytes: &reserved, count: 4))
            fileData.append(encryptedIndex)

            try fileData.write(to: targetURL, options: .atomic)

            self.masterKey = derived
            self.cachedSalt = salt
            self.cachedPassword = password
            self.metadata = emptyIndex
            self.activeVaultURL = targetURL
            self.rebuildLookupIndex()
            self.isUnlocked = true
            self.statusDescription = "Container initialized"

            self.recordVault(at: targetURL)

            if saveToBiometrics {
                savePasswordToKeychain(password: password, vaultURL: targetURL)
            }
        } catch {
            self.activeError = error.localizedDescription
            self.statusDescription = "Creation aborted"
        }
        isBusy = false
    }

    // MARK: - Append File In-Place

    func importFile(name: String, sourceURL: URL, folderId: UUID?) async {
        guard let key = masterKey, let vaultURL = activeVaultURL else { return }
        isBusy = true
        statusDescription = "Hashing & encrypting \(name)..."

        let didAccess = vaultURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { vaultURL.stopAccessingSecurityScopedResource() }
        }

        do {
            let rawData = try Data(contentsOf: sourceURL, options: .alwaysMapped)
            let checksum = VaultCrypto.computeSHA256(data: rawData)
            let encryptedBlock = try await Task.detached(priority: .userInitiated) {
                try VaultCrypto.encryptBlock(plainData: rawData, using: key)
            }.value

            let handle = try FileHandle(forUpdating: vaultURL)
            defer { try? handle.close() }

            try handle.seek(toOffset: 20)
            guard let offsetData = try handle.read(upToCount: 8) else { throw CryptoVaultError.payloadTooShort }
            let currentIndexOffset = offsetData.withUnsafeBytes { $0.load(as: UInt64.self) }

            let newFileOffset = currentIndexOffset
            let newFileLength = UInt64(encryptedBlock.count)

            try handle.seek(toOffset: newFileOffset)
            try handle.write(contentsOf: encryptedBlock)

            let header = EncryptedFileHeader(
                file_name: name,
                file_size_bytes: rawData.count,
                folder_id: folderId,
                block_offset: newFileOffset,
                block_length: newFileLength,
                sha256_checksum: checksum
            )
            metadata.fileHeaders.append(header)

            let serialized = try JSONEncoder().encode(metadata)
            let encryptedIndex = try VaultCrypto.encryptBlock(plainData: serialized, using: key)

            var nextIndexOffset = newFileOffset + newFileLength
            var nextIndexLength = UInt64(encryptedIndex.count)

            try handle.seek(toOffset: nextIndexOffset)
            try handle.write(contentsOf: encryptedIndex)
            try handle.truncate(atOffset: nextIndexOffset + nextIndexLength)

            try handle.seek(toOffset: 20)
            try handle.write(contentsOf: Data(bytes: &nextIndexOffset, count: 8))
            try handle.write(contentsOf: Data(bytes: &nextIndexLength, count: 8))

            rebuildLookupIndex()
            self.statusDescription = "Saved"
        } catch {
            self.activeError = "Import error: \(error.localizedDescription)"
        }
        isBusy = false
    }

    // MARK: - Coordinated Recursive Folder Import

    func importFolderRecursively(from rootFolderURL: URL, parentFolderId: UUID?) async {
        isBusy = true
        statusDescription = "Preparing folder import..."

        let didAccess = rootFolderURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { rootFolderURL.stopAccessingSecurityScopedResource() }
        }

        let rootName = rootFolderURL.lastPathComponent
        let rootFolderId = UUID()
        let rootFolder = VaultFolder(id: rootFolderId, name: rootName, parent_id: parentFolderId)
        metadata.folders.append(rootFolder)

        var directoryIdMap: [URL: UUID] = [rootFolderURL.standardizedFileURL: rootFolderId]

        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]

        guard let enumerator = fileManager.enumerator(
            at: rootFolderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .producesRelativePathURLs]
        ) else {
            isBusy = false
            return
        }

        var pendingFilesToImport: [(name: String, url: URL, folderId: UUID)] = []

        while let itemURL = enumerator.nextObject() as? URL {
            let fullURL = itemURL.standardizedFileURL
            guard let values = try? fullURL.resourceValues(forKeys: Set(keys)) else { continue }

            let parentURL = fullURL.deletingLastPathComponent().standardizedFileURL
            let assignedParentId = directoryIdMap[parentURL] ?? rootFolderId

            if values.isDirectory == true {
                let newSubId = UUID()
                let subFolder = VaultFolder(id: newSubId, name: fullURL.lastPathComponent, parent_id: assignedParentId)
                metadata.folders.append(subFolder)
                directoryIdMap[fullURL] = newSubId
            } else if values.isRegularFile == true {
                pendingFilesToImport.append((fullURL.lastPathComponent, fullURL, assignedParentId))
            }
        }

        var count = 0
        for item in pendingFilesToImport {
            count += 1
            statusDescription = "Importing \(count)/\(pendingFilesToImport.count): \(item.name)..."
            await importFile(name: item.name, sourceURL: item.url, folderId: item.folderId)
        }

        rebuildLookupIndex()
        await persistIndexOnly()
        isBusy = false
        statusDescription = "Folder import complete"
    }

    // MARK: - Lazy Chunk Decryption & Verification

    func readAndDecryptPayload(for file: EncryptedFileHeader) throws -> Data {
        guard let key = masterKey, let vaultURL = activeVaultURL else { throw CryptoVaultError.decryptionFailed }

        let didAccess = vaultURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { vaultURL.stopAccessingSecurityScopedResource() }
        }

        let handle = try FileHandle(forReadingFrom: vaultURL)
        defer { try? handle.close() }

        try handle.seek(toOffset: file.block_offset)
        guard let encryptedBlock = try handle.read(upToCount: Int(file.block_length)) else {
            throw CryptoVaultError.payloadTooShort
        }

        let decrypted = try VaultCrypto.decryptBlock(combinedCiphertext: encryptedBlock, using: key)

        if !file.sha256_checksum.isEmpty {
            let actualHash = VaultCrypto.computeSHA256(data: decrypted)
            if actualHash.lowercased() != file.sha256_checksum.lowercased() {
                throw CryptoVaultError.checksumMismatch(expected: file.sha256_checksum, actual: actualHash)
            }
        }

        return decrypted
    }

    private func persistIndexOnly() async {
        guard let key = masterKey, let vaultURL = activeVaultURL else { return }

        let didAccess = vaultURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { vaultURL.stopAccessingSecurityScopedResource() }
        }

        do {
            let serialized = try JSONEncoder().encode(metadata)
            let encryptedIndex = try VaultCrypto.encryptBlock(plainData: serialized, using: key)

            let handle = try FileHandle(forUpdating: vaultURL)
            defer { try? handle.close() }

            try handle.seek(toOffset: 20)
            guard let offsetData = try handle.read(upToCount: 8) else { return }
            let indexOffset = offsetData.withUnsafeBytes { $0.load(as: UInt64.self) }

            try handle.seek(toOffset: indexOffset)
            try handle.write(contentsOf: encryptedIndex)
            var newIndexLength = UInt64(encryptedIndex.count)
            try handle.truncate(atOffset: indexOffset + newIndexLength)

            try handle.seek(toOffset: 28)
            try handle.write(contentsOf: Data(bytes: &newIndexLength, count: 8))
        } catch {
            self.activeError = "Failed to update index: \(error.localizedDescription)"
        }
    }

    // MARK: - Item Management

    func deleteFile(id: UUID) async {
        if let idx = metadata.fileHeaders.firstIndex(where: { $0.id == id }) {
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

        metadata.fileHeaders.removeAll { f in
            if let p = f.folder_id { return toDeleteFolderIds.contains(p) }
            return false
        }
        metadata.folders.removeAll { toDeleteFolderIds.contains($0.id) }

        rebuildLookupIndex()
        await persistIndexOnly()
    }

    func changeMasterPassword(newPassword: String) async {
        guard isUnlocked, let vaultURL = activeVaultURL else { return }
        isBusy = true
        statusDescription = "Rekeying container..."

        let didAccess = vaultURL.startAccessingSecurityScopedResource()
        defer { if didAccess { vaultURL.stopAccessingSecurityScopedResource() } }

        do {
            var newSalt = Data(count: VaultCrypto.saltLength)
            let status = newSalt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, VaultCrypto.saltLength, $0.baseAddress!) }
            guard status == errSecSuccess else { throw CryptoVaultError.encryptionFailed }

            let newDerivedKey = try await Task.detached(priority: .userInitiated) {
                try VaultCrypto.deriveKey(password: newPassword, salt: newSalt)
            }.value

            let tempOutputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ivault")
            FileManager.default.createFile(atPath: tempOutputURL.path, contents: nil)
            let writeHandle = try FileHandle(forWritingTo: tempOutputURL)
            let readHandle = try FileHandle(forReadingFrom: vaultURL)

            var currentWriteOffset = Self.headerSize
            var dummyOffset: UInt64 = 0
            var dummyLen: UInt64 = 0
            var reserved: UInt32 = 0

            var newHeader = Data()
            newHeader.append(Self.magicHeader)
            newHeader.append(newSalt)
            newHeader.append(Data(bytes: &dummyOffset, count: 8))
            newHeader.append(Data(bytes: &dummyLen, count: 8))
            newHeader.append(Data(bytes: &reserved, count: 4))
            try writeHandle.write(contentsOf: newHeader)

            var updatedHeaders: [EncryptedFileHeader] = []
            for var f in metadata.fileHeaders {
                try readHandle.seek(toOffset: f.block_offset)
                if let oldCipher = try readHandle.read(upToCount: Int(f.block_length)),
                   let decrypted = try? VaultCrypto.decryptBlock(combinedCiphertext: oldCipher, using: self.masterKey!) {
                    let reEncrypted = try VaultCrypto.encryptBlock(plainData: decrypted, using: newDerivedKey)
                    f.block_offset = currentWriteOffset
                    f.block_length = UInt64(reEncrypted.count)
                    try writeHandle.seek(toOffset: currentWriteOffset)
                    try writeHandle.write(contentsOf: reEncrypted)
                    currentWriteOffset += f.block_length
                    updatedHeaders.append(f)
                }
            }

            var newMetadata = metadata
            newMetadata.fileHeaders = updatedHeaders
            let serialized = try JSONEncoder().encode(newMetadata)
            let encryptedIndex = try VaultCrypto.encryptBlock(plainData: serialized, using: newDerivedKey)

            var finalIndexOffset = currentWriteOffset
            var finalIndexLength = UInt64(encryptedIndex.count)

            try writeHandle.seek(toOffset: finalIndexOffset)
            try writeHandle.write(contentsOf: encryptedIndex)

            try writeHandle.seek(toOffset: 20)
            try writeHandle.write(contentsOf: Data(bytes: &finalIndexOffset, count: 8))
            try writeHandle.write(contentsOf: Data(bytes: &finalIndexLength, count: 8))

            try writeHandle.close()
            try readHandle.close()

            _ = try FileManager.default.replaceItemAt(vaultURL, withItemAt: tempOutputURL)

            self.masterKey = newDerivedKey
            self.cachedSalt = newSalt
            self.cachedPassword = newPassword
            self.metadata = newMetadata
            self.rebuildLookupIndex()
            savePasswordToKeychain(password: newPassword, vaultURL: vaultURL)
            self.recordVault(at: vaultURL)
            self.statusDescription = "Container rekeyed"
        } catch {
            self.activeError = "Rekey error: \(error.localizedDescription)"
        }
        isBusy = false
    }

    func lockVault() {
        self.masterKey = nil
        self.cachedSalt = nil
        self.cachedPassword = nil
        self.metadata = VaultMetadataIndex()
        self.filesByFolder = [:]
        self.subfoldersByParent = [:]
        self.activeVaultURL = nil
        self.isUnlocked = false
        self.statusDescription = "Locked"
        self.refreshAvailableVaults()
    }

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
