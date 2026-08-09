import Foundation
import GRDB

// MARK: - Accounts

struct AccountRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: String
    var telegramUserID: Int64
    var displayName: String
    var state: String
    var createdAt: Date
}

extension AccountRecord {
    static let databaseTableName = "accounts"
}

// MARK: - Vaults

struct VaultRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: String
    var accountID: String
    var channelID: Int64
    var name: String
    var wrappedKey: Data
    var createdAt: Date
}

extension VaultRecord {
    static let databaseTableName = "vaults"
}

// MARK: - Objects

struct ObjectRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: String
    var vaultID: String
    var name: String
    var size: Int64
    var mime: String
    var state: String
    var rootHash: String?
    var wrappedKey: Data?
    var createdAt: Date
    var modifiedAt: Date
    var isFavorite: Bool = false
    var trashed: Bool = false
    var parentID: String? = nil
    var isFolder: Bool = false
    var isPrivate: Bool = false
    var sourcePath: String? = nil
    var chunkSize: Int64? = nil
}

extension ObjectRecord {
    static let databaseTableName = "objects"
}

// MARK: - Chunks

struct ChunkRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: String
    var objectID: String
    var index: Int
    var size: Int64
    var plainHash: String?
    var cipherHash: String?
    var state: String
    var messageID: Int64?
    var fileUniqueID: String?
    var channelID: Int64?
    var createdAt: Date
}

extension ChunkRecord {
    static let databaseTableName = "chunks"
}

// MARK: - Transfers

struct TransferRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: String
    var objectID: String
    var direction: String   // "upload" | "download"
    var state: String       // queued | active | paused | failed | completed
    var progress: Double
    var errorMessage: String?
    var startedAt: Date?
    var finishedAt: Date?
}

extension TransferRecord {
    static let databaseTableName = "transfers"
}
