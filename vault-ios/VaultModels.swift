import Foundation

// MARK: - Structural Vault Entities

struct VaultFolder: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var parent_id: UUID?
    var created_at: Date

    init(id: UUID = UUID(), name: String, parent_id: UUID? = nil, created_at: Date = Date()) {
        self.id = id
        self.name = name
        self.parent_id = parent_id
        self.created_at = created_at
    }

    enum CodingKeys: String, CodingKey {
        case id, name, parent_id, created_at
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.parent_id = try container.decodeIfPresent(UUID.self, forKey: .parent_id)
        self.created_at = try container.decodeIfPresent(Date.self, forKey: .created_at) ?? Date()
    }
}

struct EncryptedFileHeader: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var file_name: String
    var file_size_bytes: Int
    var folder_id: UUID?
    var created_at: Date
    var block_offset: UInt64
    var block_length: UInt64
    var sha256_checksum: String

    init(
        id: UUID = UUID(),
        file_name: String,
        file_size_bytes: Int,
        folder_id: UUID? = nil,
        created_at: Date = Date(),
        block_offset: UInt64,
        block_length: UInt64,
        sha256_checksum: String
    ) {
        self.id = id
        self.file_name = file_name
        self.file_size_bytes = file_size_bytes
        self.folder_id = folder_id
        self.created_at = created_at
        self.block_offset = block_offset
        self.block_length = block_length
        self.sha256_checksum = sha256_checksum
    }

    enum CodingKeys: String, CodingKey {
        case id, file_name, file_size_bytes, folder_id, created_at, block_offset, block_length, sha256_checksum
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.file_name = try container.decode(String.self, forKey: .file_name)
        self.file_size_bytes = try container.decode(Int.self, forKey: .file_size_bytes)
        self.folder_id = try container.decodeIfPresent(UUID.self, forKey: .folder_id)
        self.created_at = try container.decodeIfPresent(Date.self, forKey: .created_at) ?? Date()
        self.block_offset = try container.decode(UInt64.self, forKey: .block_offset)
        self.block_length = try container.decode(UInt64.self, forKey: .block_length)
        self.sha256_checksum = try container.decodeIfPresent(String.self, forKey: .sha256_checksum) ?? ""
    }
}

struct VaultMetadataIndex: Codable {
    var folders: [VaultFolder]
    var fileHeaders: [EncryptedFileHeader]

    init(folders: [VaultFolder] = [], fileHeaders: [EncryptedFileHeader] = []) {
        self.folders = folders
        self.fileHeaders = fileHeaders
    }
}
