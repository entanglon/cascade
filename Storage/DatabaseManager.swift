import Foundation
import GRDB
import os

enum StorageError: Error, Sendable {
    case notStarted
}

actor DatabaseManager {
    static let shared = DatabaseManager()

    private var pool: DatabasePool?
    private let logger = Logger(subsystem: "com.cascade.app", category: "database")

    func start(customURL: URL? = nil) throws {
        if let customURL {
            let newPool = try DatabasePool(path: customURL.path(percentEncoded: false))
            var migrator = DatabaseMigrator()
            Self.registerMigrations(&migrator)
            try migrator.migrate(newPool)
            pool = newPool
            logger.info("Cascade database ready (custom/test URL: \(customURL.path, privacy: .public))")
            return
        }
        guard pool == nil else { return }

        let url = try Self.databaseFileURL()
        let newPool = try DatabasePool(path: url.path(percentEncoded: false))
        
        var migrator = DatabaseMigrator()
        Self.registerMigrations(&migrator)
        try migrator.migrate(newPool)
        pool = newPool

        logger.info("Cascade database ready")
    }

    func resetForTesting() throws {
        guard Self.isRunningTests else { return }
        pool = nil
        let url = try Self.databaseFileURL()
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
        try start()
    }

    /// True once `start()` has opened the pool. DownloadEngine's launch janitor
    /// checks this before wiping scratch — an unreadable DB must never look like
    /// "no pins", or pinned files would be destroyed on early launch.
    func hasStarted() -> Bool {
        pool != nil
    }

    func databasePath() throws -> String {
        guard let pool else { throw StorageError.notStarted }
        return pool.path
    }

    private static func registerMigrations(_ migrator: inout DatabaseMigrator) {
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
        // Backup mirror channel: every vault-channel message is forwarded into a
        // second private channel ("Cascade Backup") for disaster recovery.
        migrator.registerMigration("v20-backup-channel") { db in
            try db.alter(table: "vaults") { t in
                t.add(column: "backupChannelID", .integer)
            }
            try db.create(table: "backup_msgs") { t in
                t.column("messageID", .integer).primaryKey()
                t.column("objectID", .text).notNull()
                t.column("backupMessageID", .integer)
                t.column("status", .text).notNull()
                t.column("attempts", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }

        // Notes feature removed (2026-08-16) — local-only, never synced to the
        // vault; drop the orphaned table. The v7/v8 migrations above stay as-is
        // because GRDB only applies migrations that haven't run yet.
        migrator.registerMigration("v21-drop-notes") { db in
            try db.drop(table: "notes")
        }

        // Forward-based shares (2026-08-16): shares no longer re-upload a fresh
        // encrypted copy into a per-share disposable channel. Vault chunk messages
        // are FORWARDED (zero re-upload) into ONE reusable share channel, and the
        // link carries the forwarded message IDs; cleanup deletes just that file's
        // messages instead of the whole channel. New columns hold the forwarded
        // message-ID list and the share-wrapped object key (private files only).
        // share_state tracks the single reusable channel.
        migrator.registerMigration("v22-forward-shares") { db in
            try db.alter(table: "shares") { t in
                t.add(column: "messageIDs", .text).defaults(to: "")
                t.add(column: "wrappedKeyB64", .text).defaults(to: "")
            }
            try db.create(table: "share_state") { t in
                t.column("id", .integer).primaryKey()
                t.column("channelID", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }

        // Group shares (2026-08-17): ONE link can carry multiple files, all
        // forwarded into the reusable channel together. Outgoing records list
        // every shared object ID (comma-separated) so single-file reuse never
        // returns a group link and group reuse can match the exact same selection.
        migrator.registerMigration("v23-group-shares") { db in
            try db.alter(table: "shares") { t in
                t.add(column: "groupObjectIDs", .text).defaults(to: "")
            }
        }

        // Channel pool + public/private shares (2026-08-17): share_state grows
        // a kind and a stored permanent invite; the pre-existing single reusable
        // channel (row id 1) becomes private pool slot 1. Shares grow a public
        // flag: public links never expire and live in the persistent public
        // channel; private links each take a dedicated pool slot.
        migrator.registerMigration("v24-channel-pool") { db in
            try db.alter(table: "shares") { t in
                t.add(column: "isPublic", .boolean).notNull().defaults(to: false)
            }
            try db.alter(table: "share_state") { t in
                t.add(column: "kind", .text).notNull().defaults(to: "private")
                t.add(column: "inviteLink", .text).notNull().defaults(to: "")
            }
            try db.execute(sql: "UPDATE share_state SET kind = 'private' WHERE id = 1")
        }
        migrator.registerMigration("v25-share-archive") { db in
            try db.alter(table: "shares") { t in
                t.add(column: "isArchived", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v26-thumb-sidecar") { db in
            try db.alter(table: "objects") { t in
                t.add(column: "thumbMessageID", .integer)
            }
        }

        migrator.registerMigration("v27-tombstone") { db in
            try db.alter(table: "objects") { t in
                t.add(column: "tombstoneAt", .datetime)
            }
            try db.create(index: "idx_objects_tombstone", on: "objects", columns: ["tombstoneAt"])
        }

        migrator.registerMigration("v28-fts5-search") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS objects_fts USING fts5(
                    id UNINDEXED,
                    name,
                    tokenize = 'unicode61'
                );
            """)
            try db.execute(sql: """
                INSERT INTO objects_fts(id, name)
                SELECT id, name FROM objects WHERE tombstoneAt IS NULL;
            """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS objects_ai AFTER INSERT ON objects BEGIN
                    INSERT INTO objects_fts(id, name) VALUES (new.id, new.name);
                END;
                CREATE TRIGGER IF NOT EXISTS objects_ad AFTER DELETE ON objects BEGIN
                    DELETE FROM objects_fts WHERE id = old.id;
                END;
                CREATE TRIGGER IF NOT EXISTS objects_au AFTER UPDATE ON objects BEGIN
                    DELETE FROM objects_fts WHERE id = old.id;
                    INSERT INTO objects_fts(id, name) VALUES (new.id, new.name);
                END;
            """)
        }

        migrator.registerMigration("v29-object-versions") { db in
            try db.create(table: "object_versions") { t in
                t.column("id", .text).primaryKey()
                t.column("objectID", .text).notNull()
                t.column("versionNumber", .integer).notNull()
                t.column("rootHash", .text)
                t.column("size", .integer).notNull()
                t.column("modifiedAt", .datetime).notNull()
                t.column("chunksJSON", .text)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "idx_object_versions_objectID", on: "object_versions", columns: ["objectID"])
        }

        migrator.registerMigration("v30-subtitle-sidecars") { db in
            try db.alter(table: "objects") { t in
                // JSON-encoded [SubtitleSidecar] (messageID + name per entry).
                t.add(column: "subtitleSidecars", .text)
            }
        }

        migrator.registerMigration("v31-offline-pins") { db in
            try db.alter(table: "objects") { t in
                // "Keep Downloaded": exempt from cache eviction + launch wipe.
                t.add(column: "isPinned", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v32-mirror-state") { db in
            // Finder mirror (two-way sync folder) paired-file baselines. No
            // foreign keys — snapshot sync does deleteAll+reinsert on objects
            // and must never cascade here (v13 lesson).
            try db.create(table: "mirror_state") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("size", .integer).notNull()
                t.column("remoteModifiedAt", .datetime).notNull()
                t.column("localModifiedAt", .datetime).notNull()
                t.column("rootHash", .text)
                t.column("lastSyncedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v33-share-activity") { db in
            try db.create(table: "share_activity") { t in
                t.column("id", .text).primaryKey()
                t.column("shareID", .text).notNull().defaults(to: "")
                t.column("channelID", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("userID", .integer)
                t.column("detail", .text).notNull().defaults(to: "")
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "idx_share_activity_share", on: "share_activity", columns: ["shareID"])
        }
    }

    private func ensureStarted() throws -> DatabasePool {
        if let pool { return pool }
        try start()
        guard let pool else { throw StorageError.notStarted }
        return pool
    }

    func read<T>(_ query: (Database) throws -> T) throws -> T {
        let p = try ensureStarted()
        return try p.read(query)
    }

    func write<T>(_ query: (Database) throws -> T) throws -> T {
        let p = try ensureStarted()
        return try p.write(query)
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

    func archiveShare(id: String) throws {
        try write { db in
            if var record = try ShareRecord.fetchOne(db, id: id) {
                record.isArchived = true
                try record.save(db)
            }
        }
    }

    func unarchiveShare(id: String) throws {
        try write { db in
            if var record = try ShareRecord.fetchOne(db, id: id) {
                record.isArchived = false
                try record.save(db)
            }
        }
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

    // MARK: - Share channel pool (v24)

    /// A pool channel by its row id (1…5 = private slots, 100 = public), or nil.
    func shareChannelState(id: Int64) throws -> ShareChannelState? {
        try read { db in try ShareChannelState.fetchOne(db, id: id) }
    }

    /// Every recorded pool channel (private slots and the public channel).
    func allShareChannels() throws -> [ShareChannelState] {
        try read { db in try ShareChannelState.order(Column("id")).fetchAll(db) }
    }

    /// Records a pool channel (insert or update by row id).
    func saveShareChannel(_ state: ShareChannelState) throws {
        try write { db in try state.save(db) }
    }

    /// The pool slot whose channel carries the given chat, or nil.
    func shareChannelState(channelID: Int64) throws -> ShareChannelState? {
        try read { db in
            try ShareChannelState.filter(Column("channelID") == channelID).fetchOne(db)
        }
    }

    /// Deletes a pool channel row (its Telegram channel is already gone).
    func deleteShareChannel(id: Int64) throws {
        try write { db in _ = try ShareChannelState.deleteOne(db, id: id) }
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

    // MARK: - Full-Text Search (FTS5)

    func searchObjects(query: String, vaultID: String? = nil, limit: Int = 100) throws -> [ObjectRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Sanitize tokens and append * for prefix matching
        let tokens = trimmed.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        let matchQuery = tokens.map { "\"\($0)\"*" }.joined(separator: " ")

        return try read { db in
            if let vaultID {
                let sql = """
                    SELECT o.* FROM objects o
                    JOIN objects_fts f ON o.id = f.id
                    WHERE objects_fts MATCH ?
                      AND o.tombstoneAt IS NULL
                      AND o.vaultID = ?
                    ORDER BY rank
                    LIMIT ?
                """
                return try ObjectRecord.fetchAll(db, sql: sql, arguments: [matchQuery, vaultID, limit])
            } else {
                let sql = """
                    SELECT o.* FROM objects o
                    JOIN objects_fts f ON o.id = f.id
                    WHERE objects_fts MATCH ?
                      AND o.tombstoneAt IS NULL
                    ORDER BY rank
                    LIMIT ?
                """
                return try ObjectRecord.fetchAll(db, sql: sql, arguments: [matchQuery, limit])
            }
        }
    }

    // MARK: - Version History

    func recordVersion(for objectID: String) throws {
        try write { db in
            guard let obj = try ObjectRecord.fetchOne(db, id: objectID) else { return }
            let existingCount = try ObjectVersionRecord.filter(Column("objectID") == objectID).fetchCount(db)
            let chunks = try ChunkRecord.filter(Column("objectID") == objectID).fetchAll(db)
            let chunksJSON = (try? String(data: JSONEncoder().encode(chunks), encoding: .utf8)) ?? ""

            let version = ObjectVersionRecord(
                id: UUID().uuidString,
                objectID: objectID,
                versionNumber: existingCount + 1,
                rootHash: obj.rootHash,
                size: obj.size,
                modifiedAt: obj.modifiedAt,
                chunksJSON: chunksJSON,
                createdAt: Date()
            )
            try version.save(db)
        }
    }

    func versions(for objectID: String) throws -> [ObjectVersionRecord] {
        try read { db in
            try ObjectVersionRecord
                .filter(Column("objectID") == objectID)
                .order(Column("versionNumber").desc)
                .fetchAll(db)
        }
    }

    /// Moves every recorded version from one object to another, renumbered
    /// above the target's existing history (used when the Finder mirror
    /// replaces a file: the retired copy's lineage follows the file identity).
    /// Source rows are removed after copying so nothing dangles once the old
    /// object row is gone.
    func carryOverVersions(from sourceID: String, to targetID: String) throws {
        try write { db in
            let source = try ObjectVersionRecord
                .filter(Column("objectID") == sourceID)
                .order(Column("versionNumber").asc)
                .fetchAll(db)
            guard !source.isEmpty else { return }
            var next = try ObjectVersionRecord
                .filter(Column("objectID") == targetID)
                .fetchCount(db) + 1
            for record in source {
                var moved = record
                moved.id = UUID().uuidString
                moved.objectID = targetID
                moved.versionNumber = next
                next += 1
                try moved.insert(db)
            }
            _ = try ObjectVersionRecord.filter(Column("objectID") == sourceID).deleteAll(db)
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

    /// Every cataloged object — EXCLUDING `pendingImport` rows, which are
        /// staged share files awaiting the user's Import/Cancel decision: they
        /// are streamable by id but invisible to the catalog, snapshot, sync,
        /// repair and name-collision paths.
        func allObjects() throws -> [ObjectRecord] {
            try read { db in
                try ObjectRecord.fetchAll(db).filter { $0.state != "pendingImport" }
            }
        }

        /// Staged share files awaiting the user's Import/Cancel decision.
        func pendingImports() throws -> [ObjectRecord] {
            try read { db in
                try ObjectRecord.fetchAll(db).filter { $0.state == "pendingImport" }
            }
        }

    func chunks(for objectID: String) throws -> [ChunkRecord] {
        try read { db in
            try ChunkRecord
                .filter(Column("objectID") == objectID)
                .order(Column("index"))
                .fetchAll(db)
        }
    }

    // MARK: - Backup mirror queue (backup_msgs)

    /// Records that a vault-channel message needs mirroring into the backup
    /// channel. Idempotent — a message is never queued twice.
    func enqueueBackup(messageID: Int64, objectID: String) throws {
        try write { db in
            guard try BackupMsgRecord.fetchOne(db, key: messageID) == nil else { return }
            try BackupMsgRecord(
                messageID: messageID,
                objectID: objectID,
                backupMessageID: nil,
                status: "pending",
                attempts: 0,
                createdAt: .now
            ).insert(db)
        }
    }

    /// Oldest un-forwarded message in the mirror queue (ascending message id).
    func nextPendingBackup() throws -> BackupMsgRecord? {
        try read { db in
            try BackupMsgRecord
                .filter(Column("status") == "pending")
                .order(Column("messageID"))
                .fetchOne(db)
        }
    }

    func markBackupForwarded(messageID: Int64, backupMessageID: Int64) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE backup_msgs SET backupMessageID = ?, status = 'done' WHERE messageID = ?",
                arguments: [backupMessageID, messageID]
            )
        }
    }

    func bumpBackupAttempts(messageID: Int64) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE backup_msgs SET attempts = attempts + 1 WHERE messageID = ?",
                arguments: [messageID]
            )
        }
    }

    func backupAttempts(messageID: Int64) throws -> Int {
        try read { db in
            (try BackupMsgRecord.fetchOne(db, key: messageID))?.attempts ?? 0
        }
    }

    /// Marks a message permanently unforwardable (source deleted/pruned before the
    /// mirror completed) so the drainer can skip it instead of wedging the queue.
    func markBackupFailed(messageID: Int64) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE backup_msgs SET status = 'failed' WHERE messageID = ?",
                arguments: [messageID]
            )
        }
    }

    func backupRow(messageID: Int64) throws -> BackupMsgRecord? {
        try read { db in try BackupMsgRecord.fetchOne(db, key: messageID) }
    }

    /// Forwarded backup copies (non-nil backupMessageID) for the given
    /// vault-channel message ids.
    func backupTargets(for messageIDs: [Int64]) throws -> [BackupMsgRecord] {
        guard !messageIDs.isEmpty else { return [] }
        return try read { db in
            try BackupMsgRecord
                .filter(keys: messageIDs)
                .filter(Column("backupMessageID") != nil)
                .fetchAll(db)
        }
    }

    func deleteBackupRows(messageIDs: [Int64]) throws {
        guard !messageIDs.isEmpty else { return }
        try write { db in
            _ = try BackupMsgRecord.deleteAll(db, keys: messageIDs)
        }
    }

    func deleteBackupRows(objectID: String) throws {
        try write { db in
            _ = try BackupMsgRecord
                .filter(Column("objectID") == objectID)
                .deleteAll(db)
        }
    }

    func deleteAllBackupRows() throws {
        try write { db in
            _ = try BackupMsgRecord.deleteAll(db)
        }
    }

    /// All chunk records EXCLUDING those of `pendingImport` objects — the
        /// catalog signature, snapshot checkpoints and repair scans must not
        /// see staged-share chunks (their object is not part of the catalog).
        func allChunks() throws -> [ChunkRecord] {
            try read { db in
                let pendingObjectIDs = Set(
                    try ObjectRecord.fetchAll(db)
                        .filter { $0.state == "pendingImport" }
                        .map(\.id)
                )
                return try ChunkRecord.fetchAll(db)
                    .filter { !pendingObjectIDs.contains($0.objectID) }
            }
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

    /// Objects must be unique by content: two catalog records referencing the
    /// SAME Telegram chunk message render as the same file twice in the browser
    /// (2026-08-17: a second root-level object with no rootHash was recorded for
    /// a message the original already owned). Keeps the record WITH a rootHash
    /// (content-dedup then works), or the older one on ties, and deletes the
    /// duplicate object plus its chunk rows — the survivor still references the
    /// message, so Telegram is untouched. Idempotent — a healthy catalog yields 0.
    func dedupeDuplicateObjects() throws -> Int {
        try write { db in
            let objects = try ObjectRecord.fetchAll(db)
            var messageOwner: [Int64: String] = [:]
            var deletedIDs = Set<String>()
            var removed = 0
            for object in objects where !object.isFolder && object.state == "ready" {
                let chunks = try ChunkRecord
                    .filter(Column("objectID") == object.id)
                    .fetchAll(db)
                for chunk in chunks {
                    guard let messageID = chunk.messageID else { continue }
                    if let ownerID = messageOwner[messageID] {
                        guard ownerID != object.id else { continue }
                        guard let owner = objects.first(where: { $0.id == ownerID }) else { continue }
                        let ownerHasHash = owner.rootHash?.isEmpty == false
                        let objectHasHash = object.rootHash?.isEmpty == false
                        let survivor: ObjectRecord
                        let loser: ObjectRecord
                        if ownerHasHash && !objectHasHash {
                            survivor = owner; loser = object
                        } else if objectHasHash && !ownerHasHash {
                            survivor = object; loser = owner
                        } else {
                            survivor = owner.createdAt <= object.createdAt ? owner : object
                            loser = survivor.id == owner.id ? object : owner
                        }
                        if !deletedIDs.contains(loser.id) {
                            deletedIDs.insert(loser.id)
                            try ObjectRecord.deleteOne(db, key: loser.id)
                            try ChunkRecord.filter(Column("objectID") == loser.id).deleteAll(db)
                            removed += 1
                        }
                        messageOwner[messageID] = survivor.id
                    } else {
                        messageOwner[messageID] = object.id
                    }
                }
            }
            return removed
        }
    }

    /// Finder-style unique name within a parent folder (nil = root): if a
    /// non-trashed sibling already uses the name, append " 2", " 3", … before
    /// the extension ("file.mp4" → "file 2.mp4"), case-insensitively, like
    /// Apple. `reserved` lets a batch reserve names other items will take
    /// (two same-named files moved together land as "file.mp4" and
    /// "file 2.mp4"); `excluding` skips one object id — the item itself when
    /// renaming in place. Returns `base` unchanged when the name is free.
    func uniqueObjectName(base: String, parentID: String?, reserved: Set<String> = [], excluding objectID: String? = nil) throws -> String {
        try read { db in
            let taken = Set(
                try ObjectRecord.fetchAll(db)
                    .filter { $0.parentID == parentID && !$0.trashed && $0.id != objectID }
                    .map { $0.name.lowercased() }
            )
            return ShareEngine.uniqueName(base, taken: taken.union(reserved))
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

    /// Removes a vault and everything referencing it (objects, chunks, transfers)
    /// plus its account row. Used to purge test/dummy vaults so they can't
    /// block discovery of the real vault channel.
    func deleteVaultAndData(id: String) throws {
        try write { db in
            let objectIDs = try ObjectRecord.filter(Column("vaultID") == id).fetchAll(db).map(\.id)
            for oid in objectIDs {
                _ = try TransferRecord.filter(Column("objectID") == oid).deleteAll(db)
                _ = try ChunkRecord.filter(Column("objectID") == oid).deleteAll(db)
            }
            _ = try ObjectRecord.filter(Column("vaultID") == id).deleteAll(db)
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

    /// Object IDs currently flagged "Keep Downloaded" — read SYNCHRONOUSLY by
    /// DownloadEngine's eviction paths (enforceCacheBudget and the launch janitor
    /// are sync statics and must not block on an async hop).
    func pinnedObjectIDs() -> Set<String> {
        let ids = (try? read { db in
            try String.fetchAll(db, sql: "SELECT id FROM objects WHERE isPinned = 1")
        }) ?? []
        return Set(ids)
    }

    // MARK: - Finder mirror state (Wave 2 item 3)

    func mirrorStates() throws -> [MirrorStateRecord] {
        try read { db in try MirrorStateRecord.fetchAll(db) }
    }

    func saveMirrorState(_ record: MirrorStateRecord) throws {
        try write { db in
            try record.save(db)
        }
    }

    func deleteMirrorState(objectID: String) throws {
        try write { db in
            _ = try MirrorStateRecord.deleteOne(db, id: objectID)
        }
    }

    func clearMirrorStates() throws {
        try write { db in
            _ = try MirrorStateRecord.deleteAll(db)
        }
    }

    // MARK: - Share activity (Wave 2 item 9)

    func recordShareActivity(_ record: ShareActivityRecord) throws {
        try write { db in
            try record.insert(db)
        }
    }

    /// Events for one share: its own rows PLUS unattributable public-channel
    /// rows (shareID == "") for the same channel, newest first, capped.
    func shareActivity(shareID: String, channelID: Int64, limit: Int = 100) throws -> [ShareActivityRecord] {
        try read { db in
            let share = Column("shareID")
            let channel = Column("channelID")
            return try ShareActivityRecord
                .filter(share == shareID || (share == "" && channel == channelID))
                .order(Column("createdAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
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
        print("Cascade DB: clearObjects() wiping \(count) objects (DESTRUCTIVE — resetVault only)")
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

    func markTombstone(id: String, at: Date = Date()) throws {
        try markTombstones(ids: [id], at: at)
    }

    func markTombstones(ids: [String], at: Date = Date()) throws {
        guard !ids.isEmpty else { return }
        try write { db in
            for id in ids {
                _ = try ChunkRecord.filter(Column("objectID") == id).deleteAll(db)
                if var obj = try ObjectRecord.fetchOne(db, id: id) {
                    obj.tombstoneAt = at
                    obj.modifiedAt = at
                    obj.trashed = true
                    obj.isFavorite = false
                    try obj.save(db)
                }
            }
        }
    }

    func purgeOldTombstones(olderThan cutoff: Date = Date().addingTimeInterval(-90 * 86400)) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM objects WHERE tombstoneAt IS NOT NULL AND tombstoneAt < ?", arguments: [cutoff])
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
            // DROP + recreate EVERY time: a backup table created before a schema
            // migration keeps the old column count, and `INSERT ... SELECT *`
            // then fails ("20 columns but 21 values").
            try db.execute(sql: "DROP TABLE IF EXISTS objects_backup")
            try db.execute(sql: "CREATE TABLE objects_backup AS SELECT * FROM objects WHERE 0")
            try db.execute(sql: "INSERT INTO objects_backup SELECT * FROM objects")
            try db.execute(sql: "DROP TABLE IF EXISTS chunks_backup")
            try db.execute(sql: "CREATE TABLE chunks_backup AS SELECT * FROM chunks WHERE 0")
            try db.execute(sql: "INSERT INTO chunks_backup SELECT * FROM chunks")
            // FK safety: a chunk whose object row is missing (orphan — the object was
            // deleted from the catalog but its size-0 folder-linkage chunk rows still
            // float in channel deltas) would violate chunks.objectID → objects.id and
            // roll back the ENTIRE replace, silently leaving the DB empty. Orphan
            // chunks are dead data, so drop them instead of failing.
            let objectIDs = Set(objects.map(\.id))
            let validChunks = chunks.filter { objectIDs.contains($0.objectID) }
            if validChunks.count != chunks.count {
                print("Cascade replaceCatalog: dropping \(chunks.count - validChunks.count) orphan chunk(s) referencing deleted objects")
            }
            // DELETION ABSOLUTISM (belt to merge's suspenders): an incoming LIVE
            // record whose id matches a locally tombstoned row is re-tombstoned
            // before insert. A user deletion must never be undone by a catalog
            // replace, no matter what a stale channel payload claimed.
            var tombstonedIDs: Set<String> = []
            do {
                tombstonedIDs = try Set(String.fetchAll(
                    db, sql: "SELECT id FROM objects WHERE tombstoneAt IS NOT NULL"
                ))
            } catch {
                tombstonedIDs = []
            }
            let guardedObjects = objects.map { o -> ObjectRecord in
                guard o.tombstoneAt == nil, tombstonedIDs.contains(o.id) else { return o }
                var t = o
                t.tombstoneAt = Date()
                return t
            }
            // Preserve pending imports: staged share files awaiting user decision
            // are local-only and excluded from snapshot payloads, but must never be
            // erased during snapshot sync/reconciliation.
            let pendingObjects = (try? ObjectRecord.filter(Column("state") == "pendingImport").fetchAll(db)) ?? []
            let pendingObjectIDs = Set(pendingObjects.map(\.id))
            let pendingChunks = (try? ChunkRecord.fetchAll(db).filter { pendingObjectIDs.contains($0.objectID) }) ?? []

            _ = try ChunkRecord.deleteAll(db)
            _ = try ObjectRecord.deleteAll(db)
            for object in guardedObjects {
                try object.save(db)
            }
            for chunk in validChunks {
                try chunk.save(db)
            }
            for pObj in pendingObjects {
                try pObj.save(db)
            }
            for pChunk in pendingChunks {
                try pChunk.save(db)
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

    static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil ||
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
        ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil ||
        ProcessInfo.processInfo.environment["XCInjectBundleInto"] != nil
    }

    private static func databaseFileURL() throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = support.appendingPathComponent(AppPaths.dataFolder, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("cascade.sqlite")
    }
}
