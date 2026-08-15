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
        
        migrator.registerMigration("v7-notes") { db in
            try db.create(table: "notes") { t in
                t.column("id", .text).primaryKey()
                t.column("vaultID", .text).notNull().references("vaults", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("content", .text).notNull()
                t.column("colorHex", .text).notNull()
                t.column("isPinned", .boolean).notNull().defaults(to: false)
                t.column("trashed", .boolean).notNull().defaults(to: false)
                t.column("tags", .text).notNull().defaults(to: "")
                t.column("createdAt", .datetime).notNull()
                t.column("modifiedAt", .datetime).notNull()
                t.column("telegramMessageID", .integer)
            }
            try db.create(index: "idx_notes_vault", on: "notes", columns: ["vaultID"])
            try db.create(index: "idx_notes_pinned", on: "notes", columns: ["isPinned"])
            try db.create(index: "idx_notes_trashed", on: "notes", columns: ["trashed"])
        }

        migrator.registerMigration("v8-note-rtf") { db in
            try db.alter(table: "notes") { t in
                t.add(column: "contentRTF", .blob)
            }
        }

        migrator.registerMigration("v9-vault-recovery") { db in
            try db.alter(table: "vaults") { t in
                t.add(column: "recoveryMessageID", .integer)
            }
        }

        migrator.registerMigration("v10-vault-salt") { db in
            try db.alter(table: "vaults") { t in
                t.add(column: "recoverySalt", .blob)
            }
        }

        // The v1 `transfers` table only carried the fields the transfer cards need
        // for display. Wire up transfer-history persistence (complete/failed rows
        // restored on launch) by adding the card-facing columns.
        migrator.registerMigration("v11-transfers-history") { db in
            try db.alter(table: "transfers") { t in
                t.add(column: "name", .text).notNull().defaults(to: "")
                t.add(column: "statusText", .text).notNull().defaults(to: "")
                t.add(column: "totalWork", .double).notNull().defaults(to: 1)
            }
        }

        // One-time recovery: transfers completed BEFORE v11 were never persisted
        // (they lived only in memory), so on upgrade the Transfers page looks empty.
        // Rebuild history rows from completed uploads already in the catalog.
        migrator.registerMigration("v12-transfer-history-backfill") { db in
            let objects = try ObjectRecord.fetchAll(db)
            for object in objects where object.state == "ready" && !object.isFolder && !object.trashed {
                let exists = try TransferRecord.filter(Column("objectID") == object.id).fetchCount(db)
                guard exists == 0 else { continue }
                let record = TransferRecord(
                    id: "hist-\(object.id)",
                    objectID: object.id,
                    name: object.name,
                    direction: "upload",
                    state: "complete",
                    progress: 1,
                    statusText: "Complete",
                    totalWork: 1,
                    errorMessage: nil,
                    startedAt: object.createdAt,
                    finishedAt: object.modifiedAt
                )
                try record.save(db)
            }
        }

        // WHY HISTORY NEVER STUCK: the v1 `transfers` table declares
        // `objectID REFERENCES objects ON DELETE CASCADE`, but the snapshot sync
        // rebuilds the objects table on every launch (replaceCatalog: deleteAll +
        // reinsert). The cascade silently destroyed every transfer row — which is
        // why completed transfers always vanished after a restart. Rebuild the
        // table WITHOUT the FK so history is independent of the catalog, then re-run
        // the backfill (the v12 rows were cascade-deleted by that first sync).
        migrator.registerMigration("v13-transfers-independent") { db in
            try db.create(table: "transfers_new") { t in
                t.column("id", .text).primaryKey()
                t.column("objectID", .text).notNull()
                t.column("name", .text).notNull().defaults(to: "")
                t.column("direction", .text).notNull()
                t.column("state", .text).notNull()
                t.column("progress", .double).notNull().defaults(to: 0)
                t.column("statusText", .text).notNull().defaults(to: "")
                t.column("totalWork", .double).notNull().defaults(to: 1)
                t.column("errorMessage", .text)
                t.column("startedAt", .datetime)
                t.column("finishedAt", .datetime)
            }
            try db.execute(sql: """
                INSERT INTO transfers_new (id, objectID, name, direction, state, progress, statusText, totalWork, errorMessage, startedAt, finishedAt)
                SELECT id, objectID, name, direction, state, progress, statusText, totalWork, errorMessage, startedAt, finishedAt FROM transfers
                """)
            try db.execute(sql: "DROP TABLE transfers")
            try db.execute(sql: "ALTER TABLE transfers_new RENAME TO transfers")
            try db.create(index: "idx_transfers_object", on: "transfers", columns: ["objectID"])

            // Re-run the completed-upload backfill (idempotent — objects that
            // already have a history row are skipped).
            let objects = try ObjectRecord.fetchAll(db)
            for object in objects where object.state == "ready" && !object.isFolder && !object.trashed {
                let exists = try TransferRecord.filter(Column("objectID") == object.id).fetchCount(db)
                guard exists == 0 else { continue }
                let record = TransferRecord(
                    id: "hist-\(object.id)",
                    objectID: object.id,
                    name: object.name,
                    direction: "upload",
                    state: "complete",
                    progress: 1,
                    statusText: "Complete",
                    totalWork: 1,
                    errorMessage: nil,
                    startedAt: object.createdAt,
                    finishedAt: object.modifiedAt
                )
                try record.save(db)
            }
        }
        // Cloud-to-cloud sharing: the sender keeps a record per share channel so the
        // cleanup loop can delete it at expiry; the recipient keeps a record per
        // imported share for the "Shared with Me" view.
        migrator.registerMigration("v14-shares") { db in
            try db.create(table: "shares") { t in
                t.column("id", .text).primaryKey()
                t.column("objectID", .text).notNull()
                t.column("channelID", .integer).notNull()
                t.column("inviteLink", .text).notNull()
                t.column("shareKey", .text).notNull()
                t.column("expiry", .datetime).notNull()
                t.column("role", .text).notNull()
                t.column("state", .text).notNull()
                t.column("fileName", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "idx_shares_role", on: "shares", columns: ["role"])
        }
        // The exact link string handed out at share creation, so reusing a live
        // share returns the IDENTICAL link instead of a re-obfuscated look-alike.
        migrator.registerMigration("v15-share-link-blob") { db in
            try db.alter(table: "shares") { t in
                t.add(column: "linkBlob", .text)
            }
        }
        // Archive: hidden-from-default-view flag (Gmail-style decluttering).
        migrator.registerMigration("v16-archive") { db in
            try db.alter(table: "objects") { t in
                t.add(column: "isArchived", .boolean).notNull().defaults(to: false)
            }
        }
        // Library membership: opt-in flag so ambiguous formats (PDF/TXT/MD) only
        // count as books when the user adds them.
        migrator.registerMigration("v17-library-flag") { db in
            try db.alter(table: "objects") { t in
                t.add(column: "isInLibrary", .boolean).notNull().defaults(to: false)
            }
        }
        // On-device photo intelligence: recognized people + their face
        // embeddings. Local-only by design — never synced (derived, private).
        migrator.registerMigration("v18-people-faces") { db in
            try db.create(table: "people") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "faces") { t in
                t.column("id", .text).primaryKey()
                t.column("objectID", .text).notNull()
                t.column("personID", .text)
                t.column("boxX", .double).notNull()
                t.column("boxY", .double).notNull()
                t.column("boxW", .double).notNull()
                t.column("boxH", .double).notNull()
                t.column("quality", .double).notNull()
                t.column("vectorData", .blob).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "idx_faces_object", on: "faces", columns: ["objectID"])
            try db.create(index: "idx_faces_person", on: "faces", columns: ["personID"])
        }
        // Album/playlist covers: the object whose thumbnail represents the
        // folder in the Photos/Videos collections.
        migrator.registerMigration("v19-album-cover") { db in
            try db.alter(table: "objects") { t in
                t.add(column: "coverObjectID", .text)
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

    func save(_ note: NoteRecord) throws {
        try write { db in try note.save(db) }
    }

    func delete(_ note: NoteRecord) throws {
        try write { db in _ = try NoteRecord.deleteOne(db, id: note.id) }
    }

    /// Finished-transfer history, newest first. Bounded to the most recent
    /// transfers so a long-lived vault doesn't grow an unbounded history table.
    func loadTransfers() throws -> [TransferRecord] {
        try read { db in
            try TransferRecord
                .order(Column("finishedAt").desc, Column("startedAt").desc)
                .limit(100)
                .fetchAll(db)
        }
    }

    func deleteTransfers(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try write { db in
            for id in ids {
                _ = try TransferRecord.deleteOne(db, id: id)
            }
        }
    }

    /// Replaces any existing history row for the same object (so one card per
    /// object — a new attempt supersedes the old row, including backfilled ones),
    /// then inserts the new terminal transfer.
    func upsertTransfer(_ transfer: TransferRecord) throws {
        try write { db in
            _ = try TransferRecord.filter(Column("objectID") == transfer.objectID).deleteAll(db)
            try transfer.save(db)
        }
    }

    // MARK: - Shares

    func saveShare(_ share: ShareRecord) throws {
        try write { db in try share.save(db) }
    }

    func deleteShare(id: String) throws {
        try write { db in _ = try ShareRecord.deleteOne(db, id: id) }
    }

    func share(id: String) throws -> ShareRecord? {
        try read { db in try ShareRecord.fetchOne(db, id: id) }
    }

    func shares(role: String? = nil) throws -> [ShareRecord] {
        try read { db in
            if let role {
                return try ShareRecord
                    .filter(Column("role") == role)
                    .order(Column("createdAt").desc)
                    .fetchAll(db)
            }
            return try ShareRecord.order(Column("createdAt").desc).fetchAll(db)
        }
    }

    func allNotes() throws -> [NoteRecord] {
        try read { db in
            try NoteRecord
                .order(Column("isPinned").desc, Column("modifiedAt").desc)
                .fetchAll(db)
        }
    }

    func note(id: String) throws -> NoteRecord? {
        try read { db in
            try NoteRecord.filter(Column("id") == id).fetchOne(db)
        }
    }

    // MARK: - People & Faces

    func savePerson(_ person: PersonRecord) throws {
        try write { db in try person.save(db) }
    }

    func saveFace(_ face: FaceRecord) throws {
        try write { db in try face.save(db) }
    }

    func person(id: String) throws -> PersonRecord? {
        try read { db in try PersonRecord.fetchOne(db, id: id) }
    }

    func allPeople() throws -> [PersonRecord] {
        try read { db in try PersonRecord.order(Column("createdAt")).fetchAll(db) }
    }

    /// Every person that still has faces, sorted by face count descending.
    func peopleWithFaceCounts() throws -> [(PersonRecord, Int)] {
        try read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.*, COUNT(f.id) AS faceCount FROM people p
                LEFT JOIN faces f ON f.personID = p.id
                GROUP BY p.id ORDER BY faceCount DESC, p.createdAt
                """)
            return try rows.map { row in
                (try PersonRecord(row: row), row["faceCount"] as? Int ?? 0)
            }
        }
    }

    func faces(for objectID: String) throws -> [FaceRecord] {
        try read { db in
            try FaceRecord
                .filter(Column("objectID") == objectID)
                .order(Column("createdAt"))
                .fetchAll(db)
        }
    }

    func faces(forObjectIDs objectIDs: [String]) throws -> [String: [FaceRecord]] {
        guard !objectIDs.isEmpty else { return [:] }
        return try read { db in
            let placeholders = Array(repeating: "?", count: objectIDs.count).joined(separator: ",")
            let rows = try FaceRecord.fetchAll(
                db,
                sql: "SELECT * FROM faces WHERE objectID IN (\(placeholders))",
                arguments: StatementArguments(objectIDs)
            )
            return Dictionary(grouping: rows, by: \.objectID)
        }
    }

    func faces(forPerson personID: String) throws -> [FaceRecord] {
        try read { db in
            try FaceRecord
                .filter(Column("personID") == personID)
                .fetchAll(db)
        }
    }

    func allFaces() throws -> [FaceRecord] {
        try read { db in try FaceRecord.fetchAll(db) }
    }

    func face(id: String) throws -> FaceRecord? {
        try read { db in try FaceRecord.fetchOne(db, id: id) }
    }

    /// Face counts per object — used to skip re-indexing photos already scanned.
    func faceCountsByObject() throws -> [String: Int] {
        try read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT objectID, COUNT(id) AS n FROM faces GROUP BY objectID
                """)
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard let id = row["objectID"] as? String else { return nil }
                return (id, row["n"] as? Int ?? 0)
            })
        }
    }

    func setPersonName(_ personID: String, name: String) throws {
        try write { db in
            try db.execute(sql: "UPDATE people SET name = ? WHERE id = ?",
                           arguments: [name, personID])
        }
    }

    func assignFace(_ faceID: String, to personID: String) throws {
        try write { db in
            try db.execute(sql: "UPDATE faces SET personID = ? WHERE id = ?",
                           arguments: [personID, faceID])
        }
    }

    func deleteFace(id: String) throws {
        try write { db in _ = try FaceRecord.deleteOne(db, id: id) }
    }

    func deleteFaces(forObjectID objectID: String) throws {
        try write { db in
            try FaceRecord.filter(Column("objectID") == objectID).deleteAll(db)
        }
    }

    func deletePerson(id: String) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM faces WHERE personID = ?", arguments: [id])
            _ = try PersonRecord.deleteOne(db, id: id)
        }
    }

    /// Merge `fromID` into `toID`: every face moves to `toID`, then the empty
    /// person row is dropped.
    func mergePerson(_ fromID: String, into toID: String) throws {
        try write { db in
            try db.execute(sql: "UPDATE faces SET personID = ? WHERE personID = ?",
                           arguments: [toID, fromID])
            _ = try PersonRecord.deleteOne(db, id: fromID)
        }
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

    /// Removes duplicate chunk records — the catalog corruption that made some
    /// downloads assemble files twice the real size. Older snapshot merges could
    /// leave TWO rows for the same (object, index) referencing the same Telegram
    /// message (one from an old chunk plan, one from a newer plan), so
    /// DownloadEngine wrote every message's bytes twice. Keeps exactly one row
    /// per index: for non-final chunks it prefers a size that is a whole 1 MiB
    /// slice (the streaming invariant), and for the final chunk the size that
    /// makes the object's chunks sum to exactly its recorded size. Returns the
    /// number of rows removed. Idempotent — a healthy catalog yields 0.
    func dedupeChunkRecords() throws -> Int {
        try write { db in
            let objects = try ObjectRecord.fetchAll(db)
            var removed = 0
            let slice = Int64(CryptoEngine.sliceSize)
            for object in objects where !object.isFolder && object.size > 0 {
                let chunks = try ChunkRecord
                    .filter(Column("objectID") == object.id)
                    .order(Column("index"))
                    .fetchAll(db)
                guard chunks.count > 1 else { continue }
                let indexes = chunks.map(\.index)
                let maxIndex = indexes.max() ?? -1
                var chosenIDs = Set<String>()
                var chosenSum: Int64 = 0
                for index in indexes.sorted() {
                    let candidates = chunks.filter { $0.index == index }
                    let picked: ChunkRecord
                    if index == maxIndex {
                        // Final chunk: prefer the size that completes the object
                        // size (the plan whose rows sum to the real file size).
                        let remainder = object.size - chosenSum
                        picked = candidates.first(where: { $0.size == remainder })
                            ?? candidates.first(where: { $0.messageID != nil })
                            ?? candidates[0]
                    } else {
                        // Non-final chunk: prefer a whole 1 MiB slice size so the
                        // byte-range streaming layout stays slice-aligned.
                        picked = candidates.first(where: { $0.size % slice == 0 })
                            ?? candidates.first(where: { $0.messageID != nil })
                            ?? candidates[0]
                    }
                    chosenIDs.insert(picked.id)
                    chosenSum += picked.size
                }
                for chunk in chunks where !chosenIDs.contains(chunk.id) {
                    try chunk.delete(db)
                    removed += 1
                }
            }
            return removed
        }
    }

    func updateChunk(_ id: String, _ mutate: (inout ChunkRecord) -> Void) throws {
        try write { db in
            guard var chunk = try ChunkRecord.fetchOne(db, id: id) else { return }
            mutate(&chunk)
            try chunk.update(db)
        }
    }

    /// Removes all chunk rows for an object — used by the recovery re-upload path
    /// (stale chunk rows reference Telegram messages that no longer exist, and the
    /// upload engine would otherwise treat them as already-done and skip).
    func deleteChunks(forObjectID objectID: String) throws {
        try write { db in
            _ = try ChunkRecord.filter(Column("objectID") == objectID).deleteAll(db)
        }
    }

    func firstVault() throws -> VaultRecord? {
        try read { db in try VaultRecord.fetchOne(db) }
    }

    /// Removes a vault and everything referencing it (objects, chunks, transfers,
    /// notes) plus its account row. Used to purge test/dummy vaults so they can't
    /// block discovery of the real vault channel.
    func deleteVaultAndData(id: String) throws {
        try write { db in
            let objectIDs = try ObjectRecord.filter(Column("vaultID") == id).fetchAll(db).map(\.id)
            for oid in objectIDs {
                _ = try TransferRecord.filter(Column("objectID") == oid).deleteAll(db)
                _ = try ChunkRecord.filter(Column("objectID") == oid).deleteAll(db)
            }
            _ = try ObjectRecord.filter(Column("vaultID") == id).deleteAll(db)
            _ = try NoteRecord.filter(Column("vaultID") == id).deleteAll(db)
            guard let vault = try VaultRecord.fetchOne(db, id: id) else { return }
            // Delete the vault BEFORE its account row — the vault holds a foreign key
            // to the account, so deleting the account first violates the constraint.
            _ = try VaultRecord.deleteOne(db, id: id)
            _ = try AccountRecord.deleteOne(db, id: vault.accountID)
        }
    }

    func object(_ id: String) throws -> ObjectRecord? {
        try read { db in try ObjectRecord.fetchOne(db, id: id) }
    }

    @discardableResult
    func updateObject(_ id: String, _ mutate: (inout ObjectRecord) -> Void) throws -> ObjectRecord? {
        try write { db in
            guard var object = try ObjectRecord.fetchOne(db, id: id) else { return nil }
            mutate(&object)
            // The catalog's LWW merge uses `modifiedAt` as its version clock (ties
            // keep the remote side, and changedRecords publishes only records whose
            // local timestamp is newer). Every mutation MUST therefore bump it, or a
            // local change like trashing a file carries the old timestamp, the merge
            // sees a tie with the channel's copy, keeps the remote (untrashed) record
            // and the file silently resurrects on the next refresh.
            object.modifiedAt = .now
            try object.update(db)
            return object
        }
    }

    func clearObjects() throws {
        let count = (try? read { db in try ObjectRecord.fetchCount(db) }) ?? 0
        print("xCloud DB: clearObjects() wiping \(count) objects (DESTRUCTIVE — resetVault only)")
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

    /// Atomically replaces the entire catalog (objects + chunks) with the given
    /// rows — used by CatalogSnapshot.restore() to rebuild a fresh device's database
    /// from the snapshot document in one transaction.
    func replaceCatalog(objects: [ObjectRecord], chunks: [ChunkRecord]) throws {
        try write { db in
            // Safety snapshot: stash current catalog into backup tables so a bad
            // replace is recoverable via manual SQL. The backup tables are small
            // (same WAL page) and overwritten on every replace — no accumulation.
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS objects_backup AS SELECT * FROM objects WHERE 0")
            try db.execute(sql: "DELETE FROM objects_backup")
            try db.execute(sql: "INSERT INTO objects_backup SELECT * FROM objects")
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS chunks_backup AS SELECT * FROM chunks WHERE 0")
            try db.execute(sql: "DELETE FROM chunks_backup")
            try db.execute(sql: "INSERT INTO chunks_backup SELECT * FROM chunks")
            _ = try ChunkRecord.deleteAll(db)
            _ = try ObjectRecord.deleteAll(db)
            for object in objects {
                try object.save(db)
            }
            for chunk in chunks {
                try chunk.save(db)
            }
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
                name: "self-test.bin",
                direction: "upload",
                state: "complete",
                progress: 1,
                statusText: "Complete",
                totalWork: 1,
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
