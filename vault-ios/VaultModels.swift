import Foundation

// MARK: - Folder Model

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

// MARK: - File Descriptor (Zero RAM Overhead)

/// File metadata header. The file's encrypted ciphertext is stored in isolated disk blocks
/// and only decrypted into RAM when previewed or exported.
struct EncryptedFileHeader: Identifiable, Codable, Equatable {
    let id: UUID
    var file_name: String
    var file_size_bytes: Int
    var folder_id: UUID?
    var created_at: Date
    var storage_filename: String

    init(
        id: UUID = UUID(),
        file_name: String,
        file_size_bytes: Int,
        folder_id: UUID? = nil,
        created_at: Date = Date(),
        storage_filename: String = UUID().uuidString
    ) {
        self.id = id
        self.file_name = file_name
        self.file_size_bytes = file_size_bytes
        self.folder_id = folder_id
        self.created_at = created_at
        self.storage_filename = storage_filename
    }

    enum CodingKeys: String, CodingKey {
        case id, file_name, file_size_bytes, folder_id, created_at, storage_filename
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.file_name = try container.decode(String.self, forKey: .file_name)
        self.file_size_bytes = try container.decode(Int.self, forKey: .file_size_bytes)
        self.folder_id = try container.decodeIfPresent(UUID.self, forKey: .folder_id)
        self.created_at = try container.decodeIfPresent(Date.self, forKey: .created_at) ?? Date()
        self.storage_filename = try container.decode(String.self, forKey: .storage_filename)
    }
}

// MARK: - Sorting & Indexing

enum VaultSortOption: String, CaseIterable, Identifiable {
    case name = "Name"
    case size = "Size"
    case date = "Date Added"
    var id: String { rawValue }
}

struct VaultMetadataIndex: Codable {
    var folders: [VaultFolder]
    var fileHeaders: [EncryptedFileHeader]

    init(folders: [VaultFolder] = [], fileHeaders: [EncryptedFileHeader] = []) {
        self.folders = folders
        self.fileHeaders = fileHeaders
    }
}
