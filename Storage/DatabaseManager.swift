import Foundation
import GRDB
import os

enum StorageError: Error, Sendable {
    case notStarted
}

actor DatabaseManager {
    static let shared = DatabaseManager()

    private var pool: DatabasePool?
    private let logger = Logger(subsystem: "com.xcloud.app", category: "database")

    func start() throws {
        guard pool == nil else { return }

        let url = try Self.databaseFileURL()
        let newPool = try DatabasePool(path: url.path(percentEncoded: false))
        
        // Inline migration to avoid actor isolation issues
        var migrator = DatabaseMigrator()
        migrator.registerMigration("create-v1") { db in
            try db.create(table: "accounts") { t in
                t.column("id", .text).primaryKey()
                t.column("telegramUserID", .integer).notNull()
                t.column("displayName", .text).notNull()
                t.column("state", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "vaults") { t in
                t.column("id", .text).primaryKey()
                t.column("accountID", .text).notNull().references("accounts")
                t.column("channelID", .integer).notNull()
                t.column("name", .text).notNull()
                t.column("wrappedKey", .blob).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "objects") { t in
                t.column("id", .text).primaryKey()
                t.column("vaultID", .text).notNull().references("vaults")
                t.column("name", .text).notNull()
                t.column("size", .integer).notNull()
                t.column("mime", .text).notNull()
                t.column("state", .text).notNull()
                t.column("rootHash", .text)
                t.column("wrappedKey", .blob)
                t.column("createdAt", .datetime).notNull()
                t.column("modifiedAt", .datetime).notNull()
            }

            try db.create(table: "chunks") { t in
                t.column("id", .text).primaryKey()
                t.column("objectID", .text).notNull()
                    .references("objects", onDelete: .cascade)
                t.column("index", .integer).notNull()
                t.column("size", .integer).notNull()
                t.column("plainHash", .text)
                t.column("cipherHash", .text)
                t.column("state", .text).notNull()
                t.column("messageID", .integer)
                t.column("fileUniqueID", .text)
                t.column("channelID", .integer)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "transfers") { t in
                t.column("id", .text).primaryKey()
                t.column("objectID", .text).notNull()
                    .references("objects", onDelete: .cascade)
                t.column("direction", .text).notNull()
                t.column("state", .text).notNull()
                t.column("progress", .double).notNull().defaults(to: 0)
                t.column("errorMessage", .text)
                t.column("startedAt", .datetime)
                t.column("finishedAt", .datetime)
            }

            try db.create(index: "idx_chunks_object", on: "chunks", columns: ["objectID"])
            try db.create(index: "idx_transfers_object", on: "transfers", columns: ["objectID"])
        }
        
        migrator.registerMigration("v2-favorites-trash") { db in
            try db.alter(table: "objects") { t in
                t.add(column: "isFavorite", .boolean).notNull().defaults(to: false)
                t.add(column: "trashed", .boolean).notNull().defaults(to: false)
            }
        }
        
        migrator.registerMigration("v3-folders") { db in
            try db.alter(table: "objects") { t in
                t.add(column: "parentID", .text)
                t.add(column: "isFolder", .boolean).notNull().defaults(to: false)
            }
        }
        
        migrator.registerMigration("v4-private") { db in
            try db.alter(table: "objects") { t in
                t.add(column: "isPrivate", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v5-source-path") { db in
            try db.alter(table: "objects") { t in
                t.add(column: "sourcePath", .text)
            }
        }

        migrator.registerMigration("v6-chunk-size") { db in
            try db.alter(table: "objects") { t in
                t.add(column: "chunkSize", .integer)
            }
        }
        
        try migrator.migrate(newPool)
        pool = newPool

        logger.info("xCloud database ready")
    }

    func read<T>(_ query: (Database) throws -> T) throws -> T {
        guard let pool else { throw StorageError.notStarted }
        return try pool.read(query)
    }

    func write<T>(_ query: (Database) throws -> T) throws -> T {
        guard let pool else { throw StorageError.notStarted }
        return try pool.write(query)
    }

    func save(_ account: AccountRecord) throws {
        try write { db in try account.save(db) }
    }

    func save(_ vault: VaultRecord) throws {
        try write { db in try vault.save(db) }
    }

    func save(_ object: ObjectRecord) throws {
        try write { db in try object.save(db) }
    }

    func save(_ chunk: ChunkRecord) throws {
        try write { db in try chunk.save(db) }
    }

    func save(_ transfer: TransferRecord) throws {
        try write { db in try transfer.save(db) }
    }

    func allObjects() throws -> [ObjectRecord] {
        try read { db in try ObjectRecord.fetchAll(db) }
    }

    func chunks(for objectID: String) throws -> [ChunkRecord] {
        try read { db in
            try ChunkRecord
                .filter(Column("objectID") == objectID)
                .order(Column("index"))
                .fetchAll(db)
        }
    }

    func allChunks() throws -> [ChunkRecord] {
        try read { db in try ChunkRecord.fetchAll(db) }
    }

    func updateChunk(_ id: String, _ mutate: (inout ChunkRecord) -> Void) throws {
        try write { db in
            guard var chunk = try ChunkRecord.fetchOne(db, id: id) else { return }
            mutate(&chunk)
            try chunk.update(db)
        }
    }

    func firstVault() throws -> VaultRecord? {
        try read { db in try VaultRecord.fetchOne(db) }
    }

    func object(_ id: String) throws -> ObjectRecord? {
        try read { db in try ObjectRecord.fetchOne(db, id: id) }
    }

    @discardableResult
    func updateObject(_ id: String, _ mutate: (inout ObjectRecord) -> Void) throws -> ObjectRecord? {
        try write { db in
            guard var object = try ObjectRecord.fetchOne(db, id: id) else { return nil }
            mutate(&object)
            try object.update(db)
            return object
        }
    }

    func clearObjects() throws {
        try write { db in
            _ = try ChunkRecord.deleteAll(db)
            _ = try ObjectRecord.deleteAll(db)
        }
    }

    func deleteObjectWithChunks(id: String) throws {
        try write { db in
            _ = try ChunkRecord.filter(Column("objectID") == id).deleteAll(db)
            _ = try ObjectRecord.deleteOne(db, id: id)
        }
    }
    
    func selfTest() throws {
        try write { db in
            let account = AccountRecord(
                id: "t-account",
                telegramUserID: 0,
                displayName: "Self Test",
                state: "test",
                createdAt: .now
            )
            try account.save(db)

            let vault = VaultRecord(
                id: "t-vault",
                accountID: account.id,
                channelID: 0,
                name: "Test Vault",
                wrappedKey: Data(),
                createdAt: .now
            )
            try vault.save(db)

            let object = ObjectRecord(
                id: "t-object",
                vaultID: vault.id,
                name: "Self Test.txt",
                size: 12,
                mime: "text/plain",
                state: "pending",
                rootHash: nil,
                wrappedKey: nil,
                createdAt: .now,
                modifiedAt: .now
            )
            try object.save(db)

            let chunk = ChunkRecord(
                id: "t-chunk",
                objectID: object.id,
                index: 0,
                size: 12,
                plainHash: nil,
                cipherHash: nil,
                state: "pending",
                messageID: nil,
                fileUniqueID: nil,
                channelID: nil,
                createdAt: .now
            )
            try chunk.save(db)

            let transfer = TransferRecord(
                id: "t-transfer",
                objectID: object.id,
                direction: "upload",
                state: "completed",
                progress: 1,
                errorMessage: nil,
                startedAt: .now,
                finishedAt: .now
            )
            try transfer.save(db)

            _ = try TransferRecord.deleteOne(db, id: transfer.id)
            _ = try ChunkRecord.deleteOne(db, id: chunk.id)
            _ = try ObjectRecord.deleteOne(db, id: object.id)
            _ = try VaultRecord.deleteOne(db, id: vault.id)
            _ = try AccountRecord.deleteOne(db, id: account.id)
        }

        logger.info("Database self-test passed")
    }

    private static func databaseFileURL() throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = support.appendingPathComponent("xCloud", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("xcloud.sqlite")
    }
}
