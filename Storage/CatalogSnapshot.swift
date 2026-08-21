import Foundation
import TDLibKit

/// The "database imaging" feature. The catalog (every file/folder record and every
/// chunk's Telegram message ID) lives in TWO message types in the vault channel:
///
///  - **Checkpoint** (`cascade:dbsnapshot:v1:`): the full catalog in one JSON document,
///    published when the catalog first exists, when many records changed at once, or
///    periodically (every 24h) to bound restore cost. A fresh device fetches the
///    newest checkpoint and is instantly up to date — iCloud style. Older checkpoints
///    are auto-pruned; exactly one is kept.
///  - **Delta** (`cascade:dbdelta:v1:`): only the RECORDS that changed since the last
///    publish (a few KB per change-burst), published for routine changes so a huge
///    catalog never requires re-uploading the whole snapshot. Deltas are append-only
///    and never pruned — they are the durable change log.
///
/// Restore = newest checkpoint + every delta newer than the checkpoint's base message
/// ID, replayed in any order. Every merge is last-write-wins by `modifiedAt`
/// (idempotent, the same model Syncthing and CRDT research converge on), so replaying
/// or reordering can never corrupt anything. The per-message scan remains as the
/// catastrophic fallback.
enum CatalogSnapshot {
    static let captionPrefix = "cascade:dbsnapshot:v1:"
    static let deltaCaptionPrefix = "cascade:dbdelta:v1:"
    static let partCaptionPrefix = "cascade:dbpart:v1:"
    static let maxObjectsPerPart = 50_000

    static func isSnapshotMessage(_ caption: String) -> Bool {
        caption.hasPrefix(captionPrefix)
    }
    static func isDeltaMessage(_ caption: String) -> Bool {
        caption.hasPrefix(deltaCaptionPrefix)
    }
    static func isPartMessage(_ caption: String) -> Bool {
        caption.hasPrefix(partCaptionPrefix)
    }

    static func parsePartCaption(_ caption: String) -> (index: Int, total: Int, nonce: String, baseMessageID: Int64?)? {
        guard caption.hasPrefix(partCaptionPrefix) else { return nil }
        let rest = String(caption.dropFirst(partCaptionPrefix.count))
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              let index = Int(parts[0]),
              let total = Int(parts[1]) else { return nil }
        let nonce = String(parts[2])
        let baseMessageID = parts.count >= 4 ? Int64(parts[3]) : nil
        return (index, total, nonce, baseMessageID)
    }

    static func makePartCaption(index: Int, total: Int, nonce: String, baseMessageID: Int64?) -> String {
        "\(partCaptionPrefix)\(index):\(total):\(nonce):\(baseMessageID ?? 0)"
    }

    /// Above this many changed records, publish a full checkpoint instead of a delta.
    static let checkpointRecordThreshold = 200
    /// Publish a checkpoint at least this often to bound delta replay on restore.
    static let checkpointInterval: TimeInterval = 24 * 60 * 60

    struct Payload: Codable {
        var version: Int
        var objects: [ObjectRecord]
        var chunks: [ChunkRecord]
        /// For CHECKPOINT messages: the newest channel message ID the publishing
        /// device had merged when it captured this catalog. Restore replays every
        /// delta with a message ID greater than this. Nil for delta messages and for
        /// legacy checkpoints (which predate deltas).
        var baseMessageID: Int64? = nil
        /// Unique random nonce to deduplicate delta/checkpoint messages if retried or re-sent.
        var nonce: String? = nil
    }

    /// The complete state currently published in the channel.
    struct ChannelState {
        var checkpoint: Payload?   // newest checkpoint (raw, not normalized)
        var checkpointID: Int64?
        var deltas: [(id: Int64, payload: Payload)] = []
        /// Message-ID threshold (in the DELTAS' id-space) that the checkpoint already
        /// covers; deltas with id ≤ deltaBase are skipped on merge. Normally this is
        /// the checkpoint's own `baseMessageID` (vault-channel ids). When the checkpoint
        /// came from the BACKUP channel fallback it is set to -1 — a backup forward is a
        /// best-effort snapshot that may be stale, so every delta is replayed on top and
        /// LWW merge keeps the newest records.
        var deltaBase: Int64?
        var newestID: Int64? { [checkpointID, deltas.last?.id].compactMap { $0 }.max() }
    }

    /// Publishes the current catalog. Routine changes go out as a tiny delta; full
    /// checkpoints are published for the first publish, large change-bursts, and
    /// periodically. Every publish first RECONCILES with the channel (fetch the
    /// newest checkpoint + newer deltas, merge them in, adopt locally), so changes
    /// made on other devices are carried forward instead of clobbered.
    /// Returns the time of the last reconcile (so callers can record "last synced"),
    /// or nil when nothing happened (not authorized / no vault / error).
    static func upload() async -> Foundation.Date? {
        guard TelegramClient.shared.isAuthorized else { return nil }
        guard let vault = try? await DatabaseManager.shared.firstVault() else { return nil }
        do {
            let local = Payload(
                version: 1,
                objects: try await DatabaseManager.shared.allObjects(),
                chunks: try await DatabaseManager.shared.allChunks()
            )

            // 1) Reconcile: fold the channel's published state into ours.
            let channel = await fetchChannelState(chatId: vault.channelID)
            let remote = mergedChannelState(channel, vaultID: vault.id)
            var merged = merge(local: local, remote: remote, localVaultID: vault.id)

            // 2) Adopt the merged catalog locally — remote records become visible
            //    immediately and future merges stay idempotent.
            // Safety: never replace a populated catalog with an empty merged result.
            if merged.objects.isEmpty && !local.objects.isEmpty {
                print("Cascade snapshot: merge produced 0 objects from \(local.objects.count) local — refusing replaceCatalog (data safety)")
                return nil
            }

            // Race-condition guard: the `local` payload was captured BEFORE the
            // network round-trip to fetch the channel state. During that window an
            // upload may have completed and flipped an object from "uploading" to
            // "ready". If we blindly write the stale merged result, the object
            // reverts to "uploading" and disappears from the UI (which filters on
            // state == "ready"). Fix: re-read the current DB and preserve any state
            // that advanced to "ready" since the snapshot was taken.
            let currentStates: [String: String]
            if merged.objects.contains(where: { $0.state != "ready" }) {
                let current = (try? await DatabaseManager.shared.allObjects()) ?? []
                currentStates = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0.state) })
            } else {
                currentStates = [:]
            }
            for i in merged.objects.indices {
                if let dbState = currentStates[merged.objects[i].id],
                   dbState == "ready" && merged.objects[i].state != "ready" {
                    merged.objects[i].state = "ready"
                    // Also update modifiedAt so the merge metadata stays consistent
                    merged.objects[i].modifiedAt = max(merged.objects[i].modifiedAt, Date())
                }
            }

            try await DatabaseManager.shared.replaceCatalog(objects: merged.objects, chunks: merged.chunks)

            // 3) The records WE changed (the channel doesn't have them yet) are what
            //    this publish carries. Diff against the deduplicated local catalog so
            //    duplicate chunk rows are never (re)published to the channel.
            let dedupedLocal = Payload(
                version: 1,
                objects: local.objects,
                chunks: deduplicatedChunks(local.chunks, objects: local.objects)
            )
            let changes = changedRecords(local: dedupedLocal, remote: remote)
            guard !(changes.objects.isEmpty && changes.chunks.isEmpty) else {
                print("Cascade snapshot: reconciled, nothing new to publish")
                return Foundation.Date()
            }

            // 4) Checkpoint vs delta: first-ever publish, huge bursts, or a stale
            //    checkpoint all force a full checkpoint; routine changes go as a delta.
            let lastCheckpointAt = UserDefaults.standard.double(forKey: checkpointDateKey(vault.channelID))
            let checkpointIsStale = lastCheckpointAt == 0 || Date().timeIntervalSince1970 - lastCheckpointAt > checkpointInterval
            let publishCheckpoint = channel.checkpoint == nil
                || (changes.objects.count + changes.chunks.count) >= checkpointRecordThreshold
                || checkpointIsStale

            if publishCheckpoint {
                // Full catalog; base = the newest channel message we merged.
                var checkpointPayload = merged
                checkpointPayload.baseMessageID = channel.newestID
                checkpointPayload.nonce = UUID().uuidString
                let newID = try await publishDocument(
                    chatId: vault.channelID,
                    payload: checkpointPayload,
                    caption: captionPrefix,
                    backupObjectID: BackupSync.checkpointObjectID
                )
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: checkpointDateKey(vault.channelID))
                print("Cascade checkpoint uploaded: \(merged.objects.count) objects, \(merged.chunks.count) chunks")
                // Only checkpoints are pruned (keep the newest) — deltas are never touched.
                await pruneOldSnapshots(chatId: vault.channelID, keepingNewerThan: newID)
            } else {
                let deltaPayload = Payload(
                    version: 1,
                    objects: changes.objects,
                    chunks: changes.chunks,
                    nonce: UUID().uuidString
                )
                _ = try await publishDocument(
                    chatId: vault.channelID,
                    payload: deltaPayload,
                    caption: deltaCaptionPrefix,
                    backupObjectID: BackupSync.deltaObjectID
                )
                print("Cascade delta uploaded: \(changes.objects.count) objects, \(changes.chunks.count) chunks")
            }
            return Foundation.Date()
        } catch {
            print("Cascade snapshot upload failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Last-write-wins merge of two catalog snapshots. Independent records from both
    /// sides are all kept (union); for the same record the one with the newer
    /// `modifiedAt` wins, exact ties keep the remote side (deterministic enough for a
    /// tie that is practically unreachable — human edits are never millisecond-equal).
    /// Records that originate from the REMOTE side are normalized for local adoption
    /// (vaultID remapped, device-specific sourcePath dropped, state forced to
    /// "ready"), exactly like `restore()` does. Local-origin records are kept intact
    /// so this device's own in-flight uploads keep their source path and state.
    static func merge(local: Payload, remote: Payload, localVaultID: String) -> Payload {
        var objectsByID: [String: ObjectRecord] = [:]

        // Seed with remote records, normalized for local adoption.
        for r in remote.objects {
            var rec = r
            rec.vaultID = localVaultID
            rec.sourcePath = nil
            rec.state = "ready"
            // Empty wrappedKey (public files carry "") must be nil, not empty Data —
            // unwrap() throws a CryptoKit error on a zero-length sealed box.
            if rec.wrappedKey?.isEmpty == true { rec.wrappedKey = nil }
            objectsByID[rec.id] = rec
        }
        var conflictedObjects: [ObjectRecord] = []
        var conflictedChunks: [ChunkRecord] = []

        // Fold in local records: local wins strictly-newer; ties keep remote.
        for o in local.objects {
            if let remoteWinner = objectsByID[o.id] {
                // Tombstone resolution — DELETION ABSOLUTISM: a local tombstone
                // means the user destroyed this object on this device. No remote
                // timestamp can undo that decision (a stale cached channel scan
                // carrying a pre-deletion copy once resurrected deleted files in
                // the UI). Only an explicit user restore may clear a tombstone,
                // and that rewrites the row directly rather than relying on merge.
                if o.tombstoneAt != nil && remoteWinner.tombstoneAt == nil {
                    objectsByID[o.id] = o
                } else if remoteWinner.tombstoneAt != nil && o.tombstoneAt == nil {
                    if o.modifiedAt > remoteWinner.modifiedAt {
                        objectsByID[o.id] = o
                    }
                } else {
                    // Conflict branch preservation:
                    // If both sides are active files (not folders, not deleted), have differing content
                    // hashes, and both have non-empty rootHashes, preserve the losing version as a conflicted copy.
                    if let lHash = o.rootHash, let rHash = remoteWinner.rootHash,
                       !lHash.isEmpty, !rHash.isEmpty, lHash != rHash,
                       !o.isFolder && !remoteWinner.isFolder {
                        let isLocalWinner = o.modifiedAt > remoteWinner.modifiedAt
                        let loser = isLocalWinner ? remoteWinner : o
                        let df = DateFormatter()
                        df.dateFormat = "yyyy-MM-dd HH.mm"
                        let dateStr = df.string(from: loser.modifiedAt)

                        let baseName = (loser.name as NSString).deletingPathExtension
                        let ext = (loser.name as NSString).pathExtension
                        let conflictName = ext.isEmpty
                            ? "\(baseName) (Conflicted copy \(dateStr))"
                            : "\(baseName) (Conflicted copy \(dateStr)).\(ext)"

                        let conflictID = UUID().uuidString
                        var conflictRecord = loser
                        conflictRecord.id = conflictID
                        conflictRecord.name = conflictName
                        conflictRecord.vaultID = localVaultID
                        conflictRecord.createdAt = Date()
                        conflictedObjects.append(conflictRecord)

                        let loserChunks = (isLocalWinner ? remote.chunks : local.chunks)
                            .filter { $0.objectID == loser.id }
                        for c in loserChunks {
                            var copy = c
                            copy.id = "\(conflictID)-\(c.index)"
                            copy.objectID = conflictID
                            conflictedChunks.append(copy)
                        }
                    }

                    if o.modifiedAt > remoteWinner.modifiedAt {
                        objectsByID[o.id] = o
                    }
                }
            } else {
                objectsByID[o.id] = o
            }
        }

        for conf in conflictedObjects {
            objectsByID[conf.id] = conf
        }

        // Chunks are immutable once uploaded — merge is a union, preferring the copy
        // that carries a Telegram messageID (i.e. actually uploaded).
        var chunksByID: [String: ChunkRecord] = [:]
        for c in remote.chunks { chunksByID[c.id] = c }
        for c in local.chunks {
            if let remoteChunk = chunksByID[c.id] {
                if c.messageID != nil && remoteChunk.messageID == nil {
                    chunksByID[c.id] = c
                }
            } else {
                chunksByID[c.id] = c
            }
        }
        for c in conflictedChunks {
            chunksByID[c.id] = c
        }

        // Defensive dedup: older channel snapshots can carry two chunk rows for the
        // same (object, index) — one from an old chunk plan and one from a newer plan
        // — which would otherwise make downloads write every message's bytes twice.
        // Collapse to one row per index before the merged catalog is adopted.
        let dedupedChunks = deduplicatedChunks(
            Array(chunksByID.values),
            objects: Array(objectsByID.values)
        )

        return Payload(
            version: 1,
            objects: Array(objectsByID.values),
            chunks: dedupedChunks
        )
    }

    /// Collapses duplicate chunk rows (multiple records for the same object+index)
    /// that can accumulate in the channel's snapshots. Same rule as
    /// DatabaseManager.dedupeChunkRecords: one row per index, preferring whole
    /// 1 MiB-slice sizes for non-final chunks and, for the final chunk, the size
    /// that makes the object's chunks sum to exactly its recorded size.
    static func deduplicatedChunks(_ chunks: [ChunkRecord], objects: [ObjectRecord]) -> [ChunkRecord] {
        let sizesByObject = Dictionary(uniqueKeysWithValues: objects.map { ($0.id, $0.size) })
        let slice = Int64(CryptoEngine.sliceSize)
        var kept: [ChunkRecord] = []
        for objectID in Set(chunks.map(\.objectID)) {
            let objectChunks = chunks
                .filter { $0.objectID == objectID }
                .sorted { $0.index < $1.index }
            guard objectChunks.count > 1 else {
                kept.append(contentsOf: objectChunks)
                continue
            }
            let size = sizesByObject[objectID] ?? 0
            let maxIndex = objectChunks.last?.index ?? -1
            var chosenIDs = Set<String>()
            var chosenSum: Int64 = 0
            for index in objectChunks.map(\.index) {
                let candidates = objectChunks.filter { $0.index == index }
                let picked: ChunkRecord
                if index == maxIndex {
                    let remainder = size - chosenSum
                    picked = candidates.first(where: { $0.size == remainder })
                        ?? candidates.first(where: { $0.messageID != nil })
                        ?? candidates[0]
                } else {
                    let full = candidates.filter { $0.size % slice == 0 }
                    picked = full.first(where: { $0.messageID != nil })
                        ?? full.first
                        ?? candidates.first(where: { $0.messageID != nil })
                        ?? candidates[0]
                }
                if chosenIDs.insert(picked.id).inserted {
                    chosenSum += picked.size
                    kept.append(picked)
                }
            }
        }
        return kept
    }

    /// The records the LOCAL side changed relative to what the channel already knows
    /// — i.e. exactly what a delta message should carry. A record is "changed" when
    /// it exists only locally, or its local `modifiedAt` is strictly newer than the
    /// remote copy's (ties mean the channel already knows it), or when a tombstone is added.
    /// Chunks are changed only when the local copy has a Telegram messageID the remote copy lacks.
    static func changedRecords(local: Payload, remote: Payload) -> (objects: [ObjectRecord], chunks: [ChunkRecord]) {
        let remoteObjects = Dictionary(uniqueKeysWithValues: remote.objects.map { ($0.id, $0) })
        let changedObjects = local.objects.filter { o in
            guard let r = remoteObjects[o.id] else { return true }
            return o.modifiedAt > r.modifiedAt || (o.tombstoneAt != nil && r.tombstoneAt == nil)
        }

        let remoteChunks = Dictionary(uniqueKeysWithValues: remote.chunks.map { ($0.id, $0) })
        let changedChunks = local.chunks.filter { c in
            guard let r = remoteChunks[c.id] else { return true }
            return c.messageID != nil && r.messageID == nil
        }
        return (changedObjects, changedChunks)
    }

    // MARK: - Channel state

    /// Fetches the newest checkpoint and every delta message currently in the channel.
    /// When `allowBackupFallback` is true (RESTORE ONLY — never for upload/reconcile,
    /// which must not let a stale backup clobber a populated local catalog), and the
    /// vault channel yields no usable checkpoint (pruned, deleted, or undecodable),
    /// the immutable checkpoint forwards in the BACKUP channel are used instead
    /// (BackupSync mirrors every vault message there and never prunes it).
    private static func fetchChannelState(chatId: Int64, allowBackupFallback: Bool = false) async -> ChannelState {
        var state = ChannelState()
        let messages = await TelegramClient.shared.allChannelMessages(chatId: chatId, usingCache: true)
        let checkpoints = messages
            .filter { CatalogSnapshot.isSnapshotMessage(VaultRepair.caption(of: $0) ?? "") }
            .sorted { $0.id < $1.id }
        let deltas = messages
            .filter { CatalogSnapshot.isDeltaMessage(VaultRepair.caption(of: $0) ?? "") }
            .sorted { $0.id < $1.id }
        let partMessages = messages
            .filter { CatalogSnapshot.isPartMessage(VaultRepair.caption(of: $0) ?? "") }
            .sorted { $0.id < $1.id }

        var seenNonces = Set<String>()
        if let newest = checkpoints.last, let payload = await decodeMessagePayload(newest, chatId: chatId) {
            state.checkpoint = payload
            state.checkpointID = newest.id
            state.deltaBase = payload.baseMessageID
            if let nonce = payload.nonce {
                seenNonces.insert(nonce)
            }
        }

        // Reassemble multi-part checkpoints
        var partGroups: [String: [Int: (msgId: Int64, payload: Payload, total: Int, base: Int64?)]] = [:]
        for msg in partMessages {
            guard let cap = VaultRepair.caption(of: msg),
                  let parsed = parsePartCaption(cap),
                  let payload = await decodeMessagePayload(msg, chatId: chatId) else { continue }
            var group = partGroups[parsed.nonce, default: [:]]
            group[parsed.index] = (msg.id, payload, parsed.total, parsed.baseMessageID)
            partGroups[parsed.nonce] = group
        }

        for (nonce, group) in partGroups {
            guard let first = group.values.first, group.count == first.total else { continue }
            let sortedParts = (1...first.total).compactMap { group[$0] }
            guard sortedParts.count == first.total else { continue }

            let allObjects = sortedParts.flatMap { $0.payload.objects }
            let allChunks = sortedParts.flatMap { $0.payload.chunks }
            let newestMsgId = sortedParts.map(\.msgId).max() ?? 0

            if state.checkpointID == nil || newestMsgId > (state.checkpointID ?? 0) {
                state.checkpoint = Payload(
                    version: 1,
                    objects: allObjects,
                    chunks: allChunks,
                    baseMessageID: first.base,
                    nonce: nonce
                )
                state.checkpointID = newestMsgId
                state.deltaBase = first.base
                seenNonces.insert(nonce)
            }
        }

        for delta in deltas {
            if let payload = await decodeMessagePayload(delta, chatId: chatId) {
                if let nonce = payload.nonce {
                    guard !seenNonces.contains(nonce) else {
                        print("Cascade fetchChannelState: skipping duplicate delta \(delta.id) (nonce \(nonce))")
                        continue
                    }
                    seenNonces.insert(nonce)
                }
                state.deltas.append((delta.id, payload))
            }
        }

        if state.checkpoint == nil, allowBackupFallback,
           let vault = try? await DatabaseManager.shared.firstVault(),
           let backupID = vault.backupChannelID {
            let backupMessages = await TelegramClient.shared.allChannelMessages(chatId: backupID, usingCache: true)
            let backupCheckpoints = backupMessages
                .filter { CatalogSnapshot.isSnapshotMessage(VaultRepair.caption(of: $0) ?? "") }
                .sorted { $0.id < $1.id }
            if let newest = backupCheckpoints.last, let payload = await decodeMessagePayload(newest, chatId: backupID) {
                state.checkpoint = payload
                state.checkpointID = newest.id
                if let nonce = payload.nonce {
                    seenNonces.insert(nonce)
                }
                print("Cascade fetchChannelState: vault channel had no usable checkpoint — using backup-channel forward \(newest.id) as restore base")
                // Freshness: a backup forward is trustworthy only when no delta
                // carries records NEWER than the checkpoint's newest record. If the
                // deltas are newer, the checkpoint's publisher had a stale catalog
                // and the deltas hold the real state — replay every delta on top
                // (LWW merge keeps the newest records; deltaBase = -1 disables the
                // checkpoint's own base filter).
                if messages.isEmpty {
                    let backupDeltas = backupMessages
                        .filter { CatalogSnapshot.isDeltaMessage(VaultRepair.caption(of: $0) ?? "") }
                        .sorted { $0.id < $1.id }
                    for delta in backupDeltas {
                        if let payload = await decodeMessagePayload(delta, chatId: backupID) {
                            if let nonce = payload.nonce {
                                guard !seenNonces.contains(nonce) else {
                                    print("Cascade fetchChannelState: skipping duplicate backup delta \(delta.id) (nonce \(nonce))")
                                    continue
                                }
                                seenNonces.insert(nonce)
                            }
                            state.deltas.append((delta.id, payload))
                        }
                    }
                    print("Cascade fetchChannelState: vault channel empty — also using \(state.deltas.count) delta forward(s) from backup channel")
                }
                let checkpointNewest = payload.objects.map(\.modifiedAt).max() ?? .distantPast
                let deltaNewest = state.deltas
                    .map { $0.payload.objects.map(\.modifiedAt).max() ?? .distantPast }
                    .max() ?? .distantPast
                if deltaNewest > checkpointNewest {
                    state.deltaBase = -1
                    print("Cascade fetchChannelState: backup checkpoint is stale (deltas carry newer records) — replaying all deltas on top")
                } else {
                    state.deltaBase = payload.baseMessageID
                }
            } else {
                print("Cascade fetchChannelState: backup channel \(backupID) also had no usable checkpoint")
            }
        }
        return state
    }

    /// Merges the channel's published state into one remote catalog (normalized for
    /// local adoption): newest checkpoint + every delta newer than its base message
    /// ID (deltas at or before the base are already contained in the checkpoint).
    static func mergedChannelState(_ channel: ChannelState, vaultID: String) -> Payload {
        if let checkpoint = channel.checkpoint {
            var merged = normalized(checkpoint, vaultID: vaultID)
            let base = channel.deltaBase ?? checkpoint.baseMessageID ?? -1
            for (id, delta) in channel.deltas where id > base {
                merged = merge(local: merged, remote: delta, localVaultID: vaultID)
            }
            return merged
        }
        // No checkpoint yet (should only happen for channels that predate this
        // feature): replay every delta onto an empty state.
        var merged = Payload(version: 1, objects: [], chunks: [])
        for (_, delta) in channel.deltas {
            merged = merge(local: merged, remote: delta, localVaultID: vaultID)
        }
        return merged
    }

    /// Remaps a payload's records for local adoption (device-specific fields cleared).
    private static func normalized(_ payload: Payload, vaultID: String) -> Payload {
        Payload(
            version: 1,
            objects: payload.objects.map { obj in
                var o = obj
                o.vaultID = vaultID
                o.sourcePath = nil
                o.state = "ready"
                if o.wrappedKey?.isEmpty == true { o.wrappedKey = nil }
                return o
            },
            chunks: payload.chunks
        )
    }

    /// Downloads and decodes a checkpoint/delta document message. Returns nil on any
    /// failure — a corrupt or undecodable message is skipped, never fatal.
    /// Transparently decompresses zlib-compressed payloads with fallback to raw JSON.
    private static func decodeMessagePayload(_ message: Message, chatId: Int64) async -> Payload? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snap-fetch-\(UUID().uuidString).bin")
        do {
            try await TelegramClient.shared.downloadMessageFile(messageId: message.id, chatId: chatId, to: tempURL)
            let rawData = try Data(contentsOf: tempURL)
            try? FileManager.default.removeItem(at: tempURL)
            
            let jsonData: Data
            if let decompressed = try? (rawData as NSData).decompressed(using: .zlib) as Data {
                jsonData = decompressed
            } else {
                jsonData = rawData
            }
            return try JSONDecoder().decode(Payload.self, from: jsonData)
        } catch {
            print("Cascade snapshot decode failed (msg \(message.id)): \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }
    }

    private static func publishDocument(chatId: Int64, payload: Payload, caption: String, backupObjectID: String) async throws -> Int64 {
        let jsonData = try JSONEncoder().encode(payload)
        let compressedData = (try? (jsonData as NSData).compressed(using: .zlib) as Data) ?? jsonData
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-\(UUID().uuidString).bin")
        try compressedData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let messageID = try await TelegramClient.shared.sendFile(
            chatId: chatId,
            path: tempURL.path(percentEncoded: false),
            kind: .document,
            caption: caption,
            onProgress: nil
        )
        // Catalog snapshots/deltas are mirrored into the backup channel too — a
        // device with a lost local DB must be able to rebuild the catalog from it.
        BackupSync.enqueue(messageID: messageID, objectID: backupObjectID)
        return messageID
    }

    /// Publishes the current local catalog as a fresh checkpoint WITHOUT reconciling
    /// against the channel first. Used after destructive local-only changes (e.g.
    /// "delete forever") where the channel's older state must not resurrect deleted
    /// records: the new checkpoint becomes the channel's authoritative full state and
    /// old checkpoints are pruned, so the next normal reconcile sees the object gone
    /// on both sides instead of merging it back in.
    static func publishCheckpointFromLocal(force: Bool = false) async -> Foundation.Date? {
        guard TelegramClient.shared.isAuthorized else { return nil }
        guard let vault = try? await DatabaseManager.shared.firstVault() else { return nil }
        do {
            let local = Payload(
                version: 1,
                objects: try await DatabaseManager.shared.allObjects(),
                chunks: try await DatabaseManager.shared.allChunks()
            )
            // Collapse guard: refuse to publish an empty catalog unless the caller
            // explicitly says this is intentional (e.g. deleteForever on the last file).
            let fileCount = local.objects.filter { !$0.isFolder }.count
            if fileCount == 0 && !force {
                print("Cascade snapshot: refusing to publish empty checkpoint from local (collapse guard)")
                return nil
            }
            let channel = await fetchChannelState(chatId: vault.channelID)
            let totalParts = Int(ceil(Double(local.objects.count) / Double(maxObjectsPerPart)))

            if totalParts > 1 {
                let nonce = UUID().uuidString
                var lastMsgID: Int64 = 0
                for partIndex in 1...totalParts {
                    let start = (partIndex - 1) * maxObjectsPerPart
                    let end = min(start + maxObjectsPerPart, local.objects.count)
                    let partObjects = Array(local.objects[start..<end])
                    let partObjIDs = Set(partObjects.map(\.id))
                    let partChunks = local.chunks.filter { partObjIDs.contains($0.objectID) }
                    let partPayload = Payload(
                        version: 1,
                        objects: partObjects,
                        chunks: partChunks,
                        baseMessageID: channel.newestID,
                        nonce: "\(nonce)-p\(partIndex)"
                    )
                    let caption = makePartCaption(index: partIndex, total: totalParts, nonce: nonce, baseMessageID: channel.newestID)
                    lastMsgID = try await publishDocument(
                        chatId: vault.channelID,
                        payload: partPayload,
                        caption: caption,
                        backupObjectID: BackupSync.checkpointObjectID
                    )
                }
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: checkpointDateKey(vault.channelID))
                print("Cascade multi-part checkpoint published: \(totalParts) parts for \(local.objects.count) objects")
                await pruneOldSnapshots(chatId: vault.channelID, keepingNewerThan: lastMsgID)
                return Foundation.Date()
            }

            var payload = local
            payload.baseMessageID = channel.newestID
            payload.nonce = UUID().uuidString
            let newID = try await publishDocument(
                chatId: vault.channelID,
                payload: payload,
                caption: captionPrefix,
                backupObjectID: BackupSync.checkpointObjectID
            )
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: checkpointDateKey(vault.channelID))
            print("Cascade checkpoint published from local catalog: \(local.objects.count) objects, \(local.chunks.count) chunks")
            await pruneOldSnapshots(chatId: vault.channelID, keepingNewerThan: newID)
            return Foundation.Date()
        } catch {
            print("Cascade checkpoint-from-local failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func checkpointDateKey(_ channelID: Int64) -> String {
        "xc.lastCheckpointAt.\(abs(channelID))"
    }

    // MARK: - Pruning

    /// Deletes stale CHECKPOINT messages from the active vault channel so it never accumulates.
    /// BACKUP CHANNEL COPIES ARE NEVER DELETED — the backup channel maintains an immutable
    /// historical record of all snapshots, deltas, and vault keys for disaster recovery.
    static func pruneOldSnapshots(chatId: Int64, keepingNewerThan anchor: Int64? = nil) async {
        let messages = await TelegramClient.shared.allChannelMessages(chatId: chatId, usingCache: true)
        let snapshots = messages.filter { CatalogSnapshot.isSnapshotMessage(VaultRepair.caption(of: $0) ?? "") }
        let toDelete: [Int64]
        if let anchor {
            toDelete = snapshots.filter { $0.id < anchor }.map(\.id)
        } else {
            // Keep only the single newest checkpoint in the active vault channel.
            let newestFirst = snapshots.sorted { $0.id > $1.id }
            toDelete = Array(newestFirst.dropFirst().map(\.id))
        }
        guard !toDelete.isEmpty else { return }
        for i in stride(from: 0, to: toDelete.count, by: 100) {
            let batch = Array(toDelete[i..<min(i + 100, toDelete.count)])
            try? await TelegramClient.shared.deleteMessages(chatId: chatId, messageIds: batch)
        }
        print("Cascade snapshot pruned \(toDelete.count) old checkpoint message(s) from vault channel (backup copies preserved)")
    }

    /// Rebuilds the local catalog from the channel's published state: newest
    /// checkpoint + newer deltas replayed in any order. Returns true when a
    /// checkpoint or deltas were found and applied. Only used when the local DB has
    /// no catalog yet — a populated device keeps its own data.
    @discardableResult
    static func restore() async -> Bool {
        guard TelegramClient.shared.isAuthorized else { return false }
        guard let vault = try? await DatabaseManager.shared.firstVault() else { return false }
        // Never clobber a device that already has a catalog.
        if !((try? await DatabaseManager.shared.allObjects()) ?? []).isEmpty { return false }

        let channel = await fetchChannelState(chatId: vault.channelID, allowBackupFallback: true)
        print("Cascade restore: channel checkpoint=\(channel.checkpoint != nil) deltas=\(channel.deltas.count)")
        guard channel.checkpoint != nil || !channel.deltas.isEmpty else {
            print("Cascade restore: no decodable channel state — falling through to VaultRepair")
            return false
        }
        let merged = mergedChannelState(channel, vaultID: vault.id)
        do {
            try await DatabaseManager.shared.replaceCatalog(objects: merged.objects, chunks: merged.chunks)
            print("Cascade snapshot restored: \(merged.objects.count) objects, \(merged.chunks.count) chunks")
            return true
        } catch {
            print("Cascade snapshot restore FAILED: \(error.localizedDescription)")
            return false
        }
    }
}
