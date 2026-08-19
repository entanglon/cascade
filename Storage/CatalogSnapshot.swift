import Foundation
import TDLibKit

/// The "database imaging" feature. The catalog (every file/folder record and every
/// chunk's Telegram message ID) lives in TWO message types in the vault channel:
///
///  - **Checkpoint** (`xcloud:dbsnapshot:v1:`): the full catalog in one JSON document,
///    published when the catalog first exists, when many records changed at once, or
///    periodically (every 24h) to bound restore cost. A fresh device fetches the
///    newest checkpoint and is instantly up to date — iCloud style. Older checkpoints
///    are auto-pruned; exactly one is kept.
///  - **Delta** (`xcloud:dbdelta:v1:`): only the RECORDS that changed since the last
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
    static let captionPrefix = "xcloud:dbsnapshot:v1:"
    static let deltaCaptionPrefix = "xcloud:dbdelta:v1:"

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
    }

    /// The complete state currently published in the channel.
    struct ChannelState {
        var checkpoint: Payload?   // newest checkpoint (raw, not normalized)
        var checkpointID: Int64?
        var deltas: [(id: Int64, payload: Payload)] = []
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
            let merged = merge(local: local, remote: remote, localVaultID: vault.id)

            // 2) Adopt the merged catalog locally — remote records become visible
            //    immediately and future merges stay idempotent.
            // Safety: never replace a populated catalog with an empty merged result.
            if merged.objects.isEmpty && !local.objects.isEmpty {
                print("Cascade snapshot: merge produced 0 objects from \(local.objects.count) local — refusing replaceCatalog (data safety)")
                return nil
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
                let deltaPayload = Payload(version: 1, objects: changes.objects, chunks: changes.chunks)
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
        // Fold in local records: local wins strictly-newer; ties keep remote.
        for o in local.objects {
            if let remoteWinner = objectsByID[o.id] {
                if o.modifiedAt > remoteWinner.modifiedAt {
                    objectsByID[o.id] = o
                }
            } else {
                objectsByID[o.id] = o
            }
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
                    picked = candidates.first(where: { $0.size % slice == 0 })
                        ?? candidates.first(where: { $0.messageID != nil })
                        ?? candidates[0]
                }
                chosenIDs.insert(picked.id)
                chosenSum += picked.size
            }
            kept.append(contentsOf: objectChunks.filter { chosenIDs.contains($0.id) })
        }
        return kept
    }

    /// The records the LOCAL side changed relative to what the channel already knows
    /// — i.e. exactly what a delta message should carry. A record is "changed" when
    /// it exists only locally, or its local `modifiedAt` is strictly newer than the
    /// remote copy's (ties mean the channel already knows it). Chunks are changed
    /// only when the local copy has a Telegram messageID the remote copy lacks.
    static func changedRecords(local: Payload, remote: Payload) -> (objects: [ObjectRecord], chunks: [ChunkRecord]) {
        let remoteObjects = Dictionary(uniqueKeysWithValues: remote.objects.map { ($0.id, $0) })
        let changedObjects = local.objects.filter { o in
            guard let r = remoteObjects[o.id] else { return true }
            return o.modifiedAt > r.modifiedAt
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
    private static func fetchChannelState(chatId: Int64) async -> ChannelState {
        var state = ChannelState()
        let messages = await TelegramClient.shared.allChannelMessages(chatId: chatId)
        let checkpoints = messages
            .filter { (VaultRepair.caption(of: $0) ?? "").hasPrefix(captionPrefix) }
            .sorted { $0.id < $1.id }
        let deltas = messages
            .filter { (VaultRepair.caption(of: $0) ?? "").hasPrefix(deltaCaptionPrefix) }
            .sorted { $0.id < $1.id }

        if let newest = checkpoints.last, let payload = await decodeMessagePayload(newest, chatId: chatId) {
            state.checkpoint = payload
            state.checkpointID = newest.id
        }
        for delta in deltas {
            if let payload = await decodeMessagePayload(delta, chatId: chatId) {
                state.deltas.append((delta.id, payload))
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
            let base = checkpoint.baseMessageID ?? -1
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
    private static func decodeMessagePayload(_ message: Message, chatId: Int64) async -> Payload? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snap-fetch-\(UUID().uuidString).json")
        do {
            try await TelegramClient.shared.downloadMessageFile(messageId: message.id, chatId: chatId, to: tempURL)
            let data = try Data(contentsOf: tempURL)
            try? FileManager.default.removeItem(at: tempURL)
            return try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            print("Cascade snapshot decode failed (msg \(message.id)): \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }
    }

    private static func publishDocument(chatId: Int64, payload: Payload, caption: String, backupObjectID: String) async throws -> Int64 {
        let data = try JSONEncoder().encode(payload)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-\(UUID().uuidString).json")
        try data.write(to: tempURL)
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
            var payload = local
            // All existing deltas are at or below the newest channel message ID, so a
            // restore replays only deltas published after this checkpoint — the
            // deleted records can't leak back in from an older delta.
            payload.baseMessageID = channel.newestID
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

    /// Deletes stale CHECKPOINT messages from the channel so it never accumulates
    /// (deltas are never pruned — they are the durable change log). With
    /// `keepingNewerThan` set, only messages OLDER than that id are removed (the
    /// just-posted checkpoint replaces the previous one). Without it, everything
    /// except the single newest checkpoint is removed — used at post-auth to clean
    /// up any accumulation from older builds.
    static func pruneOldSnapshots(chatId: Int64, keepingNewerThan anchor: Int64? = nil) async {
        let messages = await TelegramClient.shared.allChannelMessages(chatId: chatId)
        let snapshots = messages.filter { (VaultRepair.caption(of: $0) ?? "").hasPrefix(captionPrefix) }
        let toDelete: [Int64]
        if let anchor {
            toDelete = snapshots.filter { $0.id < anchor }.map(\.id)
        } else {
            // Keep only the single newest checkpoint.
            let newestFirst = snapshots.sorted { $0.id > $1.id }
            toDelete = Array(newestFirst.dropFirst().map(\.id))
        }
        guard !toDelete.isEmpty else { return }
        do {
            // Old checkpoints are pruned from the main channel; their forwarded
            // backup copies go too (the newest checkpoint's copy is forwarded last,
            // leaving it as the single checkpoint in the backup channel).
            await BackupSync.deleteFromVaultAndBackup(messageIDs: toDelete)
            print("Cascade snapshot pruned \(toDelete.count) old checkpoint message(s)")
        } catch {
            print("Cascade snapshot prune failed: \(error.localizedDescription)")
        }
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

        let channel = await fetchChannelState(chatId: vault.channelID)
        guard channel.checkpoint != nil || !channel.deltas.isEmpty else { return false }
        let merged = mergedChannelState(channel, vaultID: vault.id)
        try? await DatabaseManager.shared.replaceCatalog(objects: merged.objects, chunks: merged.chunks)
        print("Cascade snapshot restored: \(merged.objects.count) objects, \(merged.chunks.count) chunks")
        return true
    }
}
