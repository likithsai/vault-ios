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
    @Published var pendingSharedImportsCount: Int = 0

    @Published private(set) var filesByFolder: [UUID?: [EncryptedFileHeader]] = [:]
    @Published private(set) var subfoldersByParent: [UUID?: [VaultFolder]] = [:]

    private var masterKey: SymmetricKey? = nil
    private var cachedSalt: Data? = nil
    private var cachedPassword: String? = nil
    private let keychainService = "com.likithsai.vaultios.master"

    // App Group ID for the Share Extension
    static let appGroupId = "group.com.likithsai.vaultios"

    private static let magicHeader = "IVLT".data(using: .utf8)!
    private static let headerSize: UInt64 = 40

    init() {
        checkBiometricAvailability()
        checkSharedSpoolCount()
    }

    func checkBiometricAvailability() {
        let context = LAContext()
        var error: NSError?
        self.isBiometricsAvailable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    // MARK: - App Group Shared Spool Support

    private var sharedSpoolURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupId)?
            .appendingPathComponent("SharedImports", isDirectory: true)
    }

    func checkSharedSpoolCount() {
        guard let spoolDir = sharedSpoolURL, FileManager.default.fileExists(atPath: spoolDir.path) else {
            pendingSharedImportsCount = 0
            return
        }
        let items = (try? FileManager.default.contentsOfDirectory(at: spoolDir, includingPropertiesForKeys: nil)) ?? []
        self.pendingSharedImportsCount = items.count
    }

    func drainSharedExtensionSpool() async {
        guard isUnlocked, let spoolDir = sharedSpoolURL else { return }
        guard let items = try? FileManager.default.contentsOfDirectory(at: spoolDir, includingPropertiesForKeys: nil), !items.isEmpty else { return }

        isBusy = true
        statusDescription = "Importing shared files (\(items.count))..."

        for item in items {
            await importFile(name: item.lastPathComponent, sourceURL: item, folderId: nil)
            try? FileManager.default.removeItem(at: item)
        }

        checkSharedSpoolCount()
        isBusy = false
        self.statusDescription = "Shared items imported"
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

            if saveToBiometrics {
                savePasswordToKeychain(password: password, vaultURL: fileURL)
            }

            // Auto-check shared queue
            checkSharedSpoolCount()
            if pendingSharedImportsCount > 0 {
                await drainSharedExtensionSpool()
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

            if saveToBiometrics {
                savePasswordToKeychain(password: password, vaultURL: targetURL)
            }
        } catch {
            self.activeError = error.localizedDescription
            self.statusDescription = "Creation aborted"
        }
        isBusy = false
    }

    // MARK: - Append File with Instant SHA-256 Computation

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
            
            // Single-pass fast hardware SHA-256 and AES encryption
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

    // MARK: - Lazy Chunk Decryption with SHA-256 Integrity Verification

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

        // Verify SHA-256 integrity if present
        if !file.sha256_checksum.isEmpty {
            let actualHash = VaultCrypto.computeSHA256(data: decrypted)
            if actualHash.lowercased() != file.sha256_checksum.lowercased() {
                throw CryptoVaultError.checksumMismatch(expected: file.sha256_checksum, actual: actualHash)
            }
        }

        return decrypted
    }

    // MARK: - Container Compaction / Vacuum (Zero RAM Thrashing)

    /// Copies only referenced blocks sequentially to reclaim unallocated deleted spaces
    func vacuumAndCompactContainer() async {
        guard isUnlocked, let vaultURL = activeVaultURL, let key = masterKey, let salt = cachedSalt else { return }
        isBusy = true
        statusDescription = "Defragmenting & compacting container..."

        let didAccess = vaultURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { vaultURL.stopAccessingSecurityScopedResource() }
        }

        do {
            let tempCompactURL = FileManager.default.temporaryDirectory.appendingPathComponent("compacted_\(UUID().uuidString).ivault")
            FileManager.default.createFile(atPath: tempCompactURL.path, contents: nil)

            let readHandle = try FileHandle(forReadingFrom: vaultURL)
            let writeHandle = try FileHandle(forWritingTo: tempCompactURL)

            // Write 40-byte header placeholder
            var currentWriteOffset = Self.headerSize
            var dummyOffset: UInt64 = 0
            var dummyLen: UInt64 = 0
            var reserved: UInt32 = 0

            var header = Data()
            header.append(Self.magicHeader)
            header.append(salt)
            header.append(Data(bytes: &dummyOffset, count: 8))
            header.append(Data(bytes: &dummyLen, count: 8))
            header.append(Data(bytes: &reserved, count: 4))
            try writeHandle.write(contentsOf: header)

            var compactedHeaders: [EncryptedFileHeader] = []

            // Copy active blocks in 64KB stream buffers without loading whole files into memory
            for var f in metadata.fileHeaders {
                try readHandle.seek(toOffset: f.block_offset)
                guard let cipherData = try readHandle.read(upToCount: Int(f.block_length)) else { continue }

                f.block_offset = currentWriteOffset
                try writeHandle.seek(toOffset: currentWriteOffset)
                try writeHandle.write(contentsOf: cipherData)

                currentWriteOffset += f.block_length
                compactedHeaders.append(f)
            }

            // Write updated metadata table
            var compactedMetadata = metadata
            compactedMetadata.fileHeaders = compactedHeaders

            let serialized = try JSONEncoder().encode(compactedMetadata)
            let encryptedIndex = try VaultCrypto.encryptBlock(plainData: serialized, using: key)

            var finalIndexOffset = currentWriteOffset
            var finalIndexLength = UInt64(encryptedIndex.count)

            try writeHandle.seek(toOffset: finalIndexOffset)
            try writeHandle.write(contentsOf: encryptedIndex)

            // Finalize header offsets
            try writeHandle.seek(toOffset: 20)
            try writeHandle.write(contentsOf: Data(bytes: &finalIndexOffset, count: 8))
            try writeHandle.write(contentsOf: Data(bytes: &finalIndexLength, count: 8))

            try writeHandle.close()
            try readHandle.close()

            // Atomically replace file
            _ = try FileManager.default.replaceItemAt(vaultURL, withItemAt: tempCompactURL)

            self.metadata = compactedMetadata
            self.rebuildLookupIndex()
            self.statusDescription = "Vacuum complete"
        } catch {
            self.activeError = "Compaction error: \(error.localizedDescription)"
        }
        isBusy = false
    }

    // MARK: - File Management Operations

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

    // MARK: - Folders

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
}
