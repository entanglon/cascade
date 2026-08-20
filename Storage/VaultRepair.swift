import Foundation
import TDLibKit
import os

enum VaultRepair {
    private static let logger = Logger(
        subsystem: "com.cascade.app",
        category: "repair"
    )

    /// Scans Telegram channel to reconstruct missing catalog objects/chunks, repair chunk message IDs, promote stuck objects, and purge orphaned channel messages.
    static func run() async -> Bool {
        guard TelegramClient.shared.isAuthorized else { return false }
        guard let vault = try? await DatabaseManager.shared.firstVault() else { return false }
        var changed = false

        // 1. Fetch channel messages from Telegram
        let messages = await TelegramClient.shared.allChannelMessages(chatId: vault.channelID, usingCache: true)
        print("Cascade VaultRepair.run: channel \(vault.channelID) returned \(messages.count) messages")
        logger.info("Repair scan: channel \(vault.channelID, privacy: .public) returned \(messages.count, privacy: .public) messages")
        // TEMP DIAGNOSTIC: enumerate the real channel contents so we can compare
        // against the local catalog and find which message IDs fail to resolve.
        for message in messages {
            let text = caption(of: message) ?? ""
            let prefix = String(text.prefix(42))
            var fileName = ""
            var contentKind = "text"
            switch message.content {
            case .messageDocument(let doc): fileName = doc.document.fileName; contentKind = "doc"
            case .messageVideo(let vid): fileName = vid.video.fileName ?? ""; contentKind = "video"
            case .messagePhoto(let ph): contentKind = "photo"
            case .messageAudio: contentKind = "audio"
            default: break
            }
            logger.info("Cascade diag: id=\(message.id, privacy: .public) kind=\(contentKind, privacy: .public) cap=\(prefix, privacy: .public) file=\(fileName, privacy: .public)")
        }
        let chunks = (try? await DatabaseManager.shared.allChunks()) ?? []
        let objects = (try? await DatabaseManager.shared.allObjects()) ?? []

        let objectDict = Dictionary(uniqueKeysWithValues: objects.map { ($0.id, $0) })

        // Folder IDs the CHANNEL knows about (folder metadata messages AND the
        // parentID carried by any file caption). Used to guard the orphan
        // flatten: a file must never be flattened while the cloud still knows
        // its folder.
        var channelKnownFolderIDs = Set<String>()

        if !messages.isEmpty {
            for message in messages {
                var fileName: String? = nil
                var fileSize: Int64 = 0
                var captionText: String? = nil

                switch message.content {
                case .messageDocument(let doc):
                    fileName = doc.document.fileName
                    fileSize = Int64(doc.document.document.size)
                    captionText = doc.caption.text
                case .messageAudio(let au):
                    fileSize = Int64(au.audio.audio.size)
                    captionText = au.caption.text
                case .messageVideo(let vid):
                    fileSize = Int64(vid.video.video.size)
                    captionText = vid.caption.text
                case .messagePhoto(let ph):
                    if let best = ph.photo.sizes.max(by: { $0.width < $1.width }) {
                        fileSize = Int64(best.photo.size)
                    }
                    captionText = ph.caption.text
                case .messageText(let text):
                    // Folder metadata lives in TEXT messages
                    // (sendMetadataMessage) — without this case the repair
                    // could never rebuild a lost folder record from the
                    // channel (2026-08-19: folders lost locally, files
                    // flattened, cloud intact).
                    captionText = text.text.text
                default:
                    break
                }

                // Ignore database snapshot and delta messages
                if let caption = captionText, caption.hasPrefix(CatalogSnapshot.captionPrefix) || caption.hasPrefix(CatalogSnapshot.legacyCaptionPrefix) || caption.hasPrefix(CatalogSnapshot.deltaCaptionPrefix) || caption.hasPrefix(CatalogSnapshot.legacyDeltaCaptionPrefix) {
                    continue
                }

                // A. Reconstruct from a chunk/object metadata caption (unified
                // xcloud:{...} or legacy xcloud:v1:...). Uses the unified codec so
                // Cascade caption variant parses through one path.
                if let caption = captionText, let meta = ChunkCaption.parse(caption) {
                    let objectID = meta.id
                    let name = meta.name
                    let size = meta.size
                    let mime = meta.mime
                    let index = meta.index

                    let parentID = meta.parentID
                    let isPrivate = meta.isPrivate
                    let trashed = meta.trashed
                    let isFavorite = meta.isFavorite
                    let isFolder = meta.isFolder || meta.mime == "cascade/folder"
                    let totalChunks = meta.totalChunks
                    let wrappedKeyStr = meta.wrappedKey
                    // Empty base64 string (public/unencrypted files carry "") must
                    // become nil, NOT empty Data — DownloadEngine guards unwrap on
                    // nil but an empty non-nil Data makes AES.GCM throw a CryptoKit
                    // error when it tries to open the zero-length sealed box.
                    let wrappedKey: Data? = {
                        guard !wrappedKeyStr.isEmpty else { return nil }
                        return Data(base64Encoded: wrappedKeyStr)
                    }()
                    let cleanParentID = (parentID == nil || parentID?.isEmpty == true) ? nil : parentID
                    // The cloud's known folder set: folder metadata messages and
                    // every parentID a file caption references.
                    if isFolder { channelKnownFolderIDs.insert(objectID) }
                    if let cleanParentID { channelKnownFolderIDs.insert(cleanParentID) }

                    // Restore or Update Object in SQLite
                    if let existing = objectDict[objectID] {
                        if existing.tombstoneAt != nil {
                            // Object was explicitly deleted/tombstoned; do not resurrect it from an old message
                            continue
                        }
                        // Existing object metadata in the local DB/checkpoint is authoritative over
                        // older immutable chunk captions (e.g. moves into folders, renames, favorites).
                        // Only fill in if existing fields are empty/missing, or if a previously unparented
                        // object gains a parent from the cloud caption.
                        let nameRepaired = existing.name.isEmpty && !name.isEmpty
                        let mimeRepaired = (existing.mime.isEmpty || existing.mime == "application/octet-stream") && (!mime.isEmpty && mime != "application/octet-stream")
                        let parentRepaired = existing.parentID == nil && cleanParentID != nil
                        if nameRepaired || mimeRepaired || parentRepaired {
                            var updated = existing
                            if nameRepaired { updated.name = name }
                            if mimeRepaired { updated.mime = mime }
                            if parentRepaired { updated.parentID = cleanParentID }
                            do {
                                try await DatabaseManager.shared.save(updated)
                            } catch {
                                logger.error("VaultRepair: failed to save updated object \(objectID): \(error.localizedDescription)")
                            }
                            changed = true
                        }
                    } else {
                        // A forwarded SHARE chunk's caption carries the SENDER's
                        // object id — the recipient's import mints its own UUID, so
                        // the local catalog references this message under a
                        // DIFFERENT object id. If a local chunk already references
                        // this exact message, the object is already cataloged;
                        // fabricating a new object here creates a phantom duplicate
                        // that resurrects on every scan (2026-08-17 incident).
                        let alreadyCataloged = chunks.contains { $0.messageID == message.id }
                        if alreadyCataloged {
                            logger.info("VaultRepair: message \(message.id, privacy: .public) already cataloged under another object — skipping phantom object \(objectID)")
                            continue
                        }
                        let resolvedName = name.isEmpty ? "File-\(objectID.prefix(8))" : name
                        let newObj = ObjectRecord(
                            id: objectID,
                            vaultID: vault.id,
                            name: resolvedName,
                            size: size,
                            mime: mime,
                            state: "ready",
                            rootHash: nil,
                            wrappedKey: wrappedKey,
                            createdAt: .now,
                            modifiedAt: .now,
                            isFavorite: isFavorite,
                            trashed: trashed,
                            parentID: cleanParentID,
                            isFolder: isFolder,
                            isPrivate: isPrivate,
                            sourcePath: nil
                        )
                        do {
                            try await DatabaseManager.shared.save(newObj)
                        } catch {
                            logger.error("VaultRepair: failed to save reconstructed object \(objectID): \(error.localizedDescription)")
                        }
                        changed = true
                    }

                    // Folders have no data chunks, but the folder's metadata
                    // message IS tracked by a size-0 chunk row (created by
                    // syncObjectMetadataToTelegram) so renames edit the same
                    // message. Recreate that linkage row when it's missing.
                    if !isFolder {
                        // Restore Chunk if missing or update messageID
                        let existingChunks = (try? await DatabaseManager.shared.chunks(for: objectID)) ?? []
                        if let target = existingChunks.first(where: { $0.index == index }) {
                            let realSize = fileSize > 0 ? fileSize : target.size
                            var repaired = false
                            if target.messageID != message.id {
                                do {
                                    try await DatabaseManager.shared.updateChunk(target.id) { $0.messageID = message.id }
                                    repaired = true
                                } catch {
                                    logger.error("VaultRepair: failed to update chunk messageID for \(objectID)/\(index): \(error.localizedDescription)")
                                }
                            }
                            if target.size != realSize {
                                do {
                                    try await DatabaseManager.shared.updateChunk(target.id) { $0.size = realSize }
                                    repaired = true
                                } catch {
                                    logger.error("VaultRepair: failed to update chunk size for \(objectID)/\(index): \(error.localizedDescription)")
                                }
                            }
                            changed = changed || repaired
                        } else {
                            let existingObject = objectDict[objectID]
                            let isResumablePartial = existingObject != nil && existingObject?.state != "ready"
                            if !isResumablePartial {
                                let newChunk = ChunkRecord(
                                    id: UUID().uuidString,
                                    objectID: objectID,
                                    index: index,
                                    size: fileSize > 0 ? fileSize : size / Int64(max(1, totalChunks)),
                                    plainHash: meta.plainHash,
                                    cipherHash: meta.cipherHash,
                                    state: "uploaded",
                                    messageID: message.id,
                                    fileUniqueID: nil,
                                    channelID: vault.channelID,
                                    createdAt: .now
                                )
                                do {
                                    try await DatabaseManager.shared.save(newChunk)
                                } catch {
                                    logger.error("VaultRepair: failed to save reconstructed chunk \(objectID)/\(index): \(error.localizedDescription)")
                                }
                                changed = true
                            }
                        }
                    } else {
                        // Folder linkage row: the metadata message is the folder's
                        // whole record, tracked by a size-0 chunk row. Recreate it
                        // when missing (e.g. the folder record was rebuilt above).
                        let existingChunks = (try? await DatabaseManager.shared.chunks(for: objectID)) ?? []
                        if !existingChunks.contains(where: { $0.messageID == message.id }) {
                            let newChunk = ChunkRecord(
                                id: UUID().uuidString,
                                objectID: objectID,
                                index: 0,
                                size: 0,
                                plainHash: nil,
                                cipherHash: nil,
                                state: "uploaded",
                                messageID: message.id,
                                fileUniqueID: nil,
                                channelID: vault.channelID,
                                createdAt: .now
                            )
                            do {
                                try await DatabaseManager.shared.save(newChunk)
                            } catch {
                                logger.error("VaultRepair: failed to save folder linkage chunk \(objectID): \(error.localizedDescription)")
                            }
                            changed = true
                        }
                    }
                    continue
                }

                // B. Fallback: Match filename pattern "OBJECT_ID-INDEX.bin"
                let brokenChunks = chunks.filter { $0.messageID == nil || ($0.messageID ?? 0) <= 0 }
                if let fn = fileName, fn.hasSuffix(".bin") {
                    let nameWithoutExt = (fn as NSString).deletingPathExtension
                    let parts = nameWithoutExt.split(separator: "-")
                    if parts.count >= 2, let index = Int(parts.last!) {
                        let objectID = parts.dropLast().joined(separator: "-")
                        if let targetChunk = brokenChunks.first(where: { $0.objectID == objectID && $0.index == index }) {
                            try? await DatabaseManager.shared.updateChunk(targetChunk.id) {
                                $0.messageID = message.id
                            }
                            changed = true
                        }
                    }
                }
            }
        }

        // 2. Promote failed or uploading objects to ready if all chunks have real message IDs.
        //    Local partial uploads (they carry a sourcePath) are the upload engine's resumable
        //    state and must never be promoted here — a cancelled upload would otherwise
        //    reappear as a phantom "ready" file in the folder.
        let currentObjects = (try? await DatabaseManager.shared.allObjects()) ?? []
        for var object in currentObjects where object.state != "ready" {
            if object.sourcePath != nil { continue }
            let objChunks = (try? await DatabaseManager.shared.chunks(for: object.id)) ?? []
            guard !objChunks.isEmpty else { continue }
            if objChunks.allSatisfy({ ($0.messageID ?? 0) > 0 }) {
                object.state = "ready"
                try? await DatabaseManager.shared.save(object)
                changed = true
            }
        }

        // 2b. Orphaned-parent reconciliation: a file whose parentID references a
        //     folder that doesn't exist locally (e.g. imported from a share — folder
        //     metadata does not travel with a share link, so the recipient has no
        //     such folder) is placed at the root. Without this, the file matches no
        //     folder's `parentID == currentFolderID` filter and becomes INVISIBLE in
        //     All Files while still showing in Recent/Photos/Videos (which filter by
        //     type, not parent). Fresh fetch so folders created earlier in this scan
        //     are honored.
        //     GUARD (2026-08-19): never flatten while the CHANNEL still knows the
        //     folder (its metadata message or a file caption references it) — the
        //     folder record was simply lost locally and must be rebuilt by the
        //     scan, not erased from the structure.
        let reconcileObjects = (try? await DatabaseManager.shared.allObjects()) ?? []
        let folderIDs = Set(reconcileObjects.filter(\.isFolder).map(\.id))
        for var orphan in reconcileObjects where !orphan.isFolder && orphan.parentID != nil && !folderIDs.contains(orphan.parentID!) && !channelKnownFolderIDs.contains(orphan.parentID!) {
            orphan.parentID = nil
            try? await DatabaseManager.shared.save(orphan)
            changed = true
        }

        // 3. DIAGNOSTIC ONLY — ready objects whose chunks carry no valid message ID.
        //    NEVER auto-purge (2026-08-15 incident): an incomplete channel fetch or a
        //    restored catalog can temporarily lack chunk IDs, and purging here fed the
        //    orphan purge that deleted the entire vault's chunk documents from
        //    Telegram. Reconstruction fills missing records; removal is exclusively the
        //    user's explicit trash/delete action.
        let allObjectsNow = (try? await DatabaseManager.shared.allObjects()) ?? []
        let allChunksNow = (try? await DatabaseManager.shared.allChunks()) ?? []
        let validObjectIDsWithChunks = Set(allChunksNow.compactMap { ($0.messageID ?? 0) > 0 ? $0.objectID : nil })
        let missingChunkRefs = allObjectsNow.filter { !$0.isFolder && $0.state == "ready" && !validObjectIDsWithChunks.contains($0.id) }
        if !missingChunkRefs.isEmpty {
            logger.info("Repair: \(missingChunkRefs.count, privacy: .public) ready file(s) lack valid chunk message IDs — left in place (reconstruction only)")
        }

        // 3b. DIAGNOSTIC ONLY — ready objects whose chunk messages are absent from
        //     the channel. NEVER purge: a partial channel fetch looks identical, and
        //     this purge was half of the 2026-08-15 data-loss chain. A file genuinely
        //     removed from the cloud is the user's explicit trash/delete action.
        if !messages.isEmpty {
            let liveIDs = Set(messages.map(\.id))
            var absent = 0
            for obj in allObjectsNow where !obj.isFolder && obj.state == "ready" {
                let objChunks = (try? await DatabaseManager.shared.chunks(for: obj.id)) ?? []
                let chunkIDs = objChunks.compactMap { $0.messageID }
                if !chunkIDs.isEmpty, chunkIDs.allSatisfy({ !liveIDs.contains($0) }) {
                    absent += 1
                }
            }
            if absent > 0 {
                logger.info("Repair: \(absent, privacy: .public) ready file(s) have all chunks absent from the channel — left in place (reconstruction only)")
            }
        }

        // 4. Telegram-message removal was DELETED from the automatic repair
        //    (2026-08-15: the orphan purge destroyed the vault's chunk documents when
        //    the local catalog had been collapsed by a bad restore).
        //    `purgeOrphanedMessages()` still exists for EXPLICIT operator use only.

        return changed
    }

    /// Debug hook: dump the full channel message list to /tmp/cascade-channel.txt so
    /// the real channel state can be compared against the local catalog.
    static func dumpChannelToFile() async {
        guard let vault = try? await DatabaseManager.shared.firstVault() else { return }
        let msgs = await TelegramClient.shared.allChannelMessages(chatId: vault.channelID, usingCache: true)
        var out = "channel messages: \(msgs.count)\n"
        for m in msgs {
            let text = caption(of: m) ?? ""
            var fileName = ""
            var kind = "text"
            switch m.content {
            case .messageDocument(let d): fileName = d.document.fileName; kind = "doc"
            case .messageVideo(let v): fileName = v.video.fileName ?? ""; kind = "video"
            case .messagePhoto(let p): kind = "photo"
            case .messageAudio: kind = "audio"
            default: break
            }
            out += "id=\(m.id) kind=\(kind) cap=\(String(text.prefix(70))) file=\(fileName)\n"
        }
        try? out.write(toFile: "/tmp/cascade-channel.txt", atomically: true, encoding: .utf8)
        logger.info("Channel dump written: \(msgs.count) messages")
    }

    /// Extracts a message's text caption regardless of media kind (document, video,
    /// photo, plain text). Shared by the repair scan and the Rescan diagnostic.
    static func caption(of message: Message) -> String? {
        switch message.content {
        case .messageText(let mt): return mt.text.text
        case .messageDocument(let doc): return doc.caption.text
        case .messageVideo(let vid): return vid.caption.text
        case .messagePhoto(let ph): return ph.caption.text
        case .messageAudio(let au): return au.caption.text
        default: return nil
        }
    }

    /// Finds legacy (old-format "xcloud:v1:" text metadata) folder messages whose
    /// folder is EMPTY locally (no children, or not present in the local catalog at
    /// all) — these are old-version artifact folders (e.g. "Video"/"Audio") that can
    /// never hold files again. Returns (messageIDs, objectIDs) for the
    /// `--purge-legacy-folders` cleanup hook. A legacy-format folder WITH children
    /// is never a candidate.
    static func legacyFolderPurgeCandidates(chatId: Int64) async -> ([Int64], [String]) {
        let local = (try? await DatabaseManager.shared.allObjects()) ?? []
        let parentIDs = Set(local.compactMap(\.parentID))
        let messages = await TelegramClient.shared.allChannelMessages(chatId: chatId, usingCache: true)
        var messageIDs: [Int64] = []
        var objectIDs: [String] = []
        for msg in messages {
            guard let cap = caption(of: msg),
                  (cap.hasPrefix(ChunkCaption.legacyVaultPrefix) || cap.hasPrefix(ChunkCaption.unifiedPrefix)) else { continue }
            let prefixLen = cap.hasPrefix(ChunkCaption.legacyVaultPrefix) ? ChunkCaption.legacyVaultPrefix.count : ChunkCaption.unifiedPrefix.count
            guard let data = cap.dropFirst(prefixLen).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? String,
                  (json["isFolder"] as? Bool) == true,
                  !parentIDs.contains(id)
            else { continue }
            messageIDs.append(msg.id)
            objectIDs.append(id)
        }
        return (messageIDs, objectIDs)
    }

    /// Scans the channel and deletes ONLY messages that are provably orphaned chunk
    // Cascade chunk messages whose owning object no longer exists in the
    /// local catalog at all. Everything else — text messages (folder metadata, vault
    /// key records, welcome messages), catalog checkpoints/deltas, and any chunk
    /// whose object still exists (even with a wrong/old message ID — the scan fixes
    /// those, never deletes them) — is left untouched.
    ///
    /// This is deliberately conservative: the old version deleted ANY message not in
    /// the DB's chunk table, which destroyed real folder metadata and files whose
    /// chunk IDs were stale, and was how the vault PIN appeared to reset.
    @discardableResult
    static func purgeOrphanedMessages() async -> Int {
        guard TelegramClient.shared.isAuthorized else { return 0 }
        guard let vault = try? await DatabaseManager.shared.firstVault() else { return 0 }

        let allMessages = await TelegramClient.shared.allChannelMessages(chatId: vault.channelID, usingCache: true)
        guard !allMessages.isEmpty else { return 0 }

        let validChunks = (try? await DatabaseManager.shared.allChunks()) ?? []

        // SAFETY (hardened 2026-08-15): never purge when the local DB has no chunk
        // records at all, AND only trust a catalog that still contains at least one
        // ready FILE object with a valid chunk message ID. The old gate only checked
        // the first condition — after a collapsed restore the chunks table held only
        // folder rows, the gate passed, and every file's chunk document was deleted
        // from Telegram. A catalog without real ready files is never authoritative
        // enough to authorize deletion.
        guard !validChunks.isEmpty else {
            logger.warning("Skipping orphan purge: local DB has no chunk records")
            return 0
        }
        let readyFileObjects = ((try? await DatabaseManager.shared.allObjects()) ?? []).filter { !$0.isFolder && $0.state == "ready" }
        var hasTrustedReadyFile = false
        for obj in readyFileObjects {
            let objChunks = (try? await DatabaseManager.shared.chunks(for: obj.id)) ?? []
            if objChunks.contains(where: { ($0.messageID ?? 0) > 0 }) {
                hasTrustedReadyFile = true
                break
            }
        }
        guard hasTrustedReadyFile else {
            logger.warning("Skipping orphan purge: no ready file object has a valid chunk message ID (catalog not authoritative)")
            return 0
        }

        // Ratio guard (2026-08-15 hardening): if fewer than half of ready files
        // have valid chunk message IDs, the catalog is likely a partial restore —
        // refuse to purge, because the "orphaned" messages may belong to the files
        // the partial restore didn't reconstruct.
        let allReadyFiles = readyFileObjects
        let trustedCount = allReadyFiles.filter { obj in
            validChunks.contains { $0.objectID == obj.id && ($0.messageID ?? 0) > 0 }
        }.count
        if allReadyFiles.count > 1 && trustedCount < (allReadyFiles.count + 1) / 2 {
            logger.warning("Skipping orphan purge: only \(trustedCount)/\(allReadyFiles.count) ready files trusted (ratio guard)")
            return 0
        }

        let validIDs = Set(validChunks.compactMap(\.messageID))
        let objectIDs = Set((try? await DatabaseManager.shared.allObjects())?.map(\.id) ?? [])

        let orphanedIDs = allMessages.filter { msg in
            let text = caption(of: msg) ?? ""
            // Cascade's own metadata (key records, the delta log,
            // checkpoints) — protected regardless of what the local DB contains.
            let isProtectedMeta = [
                VaultManager.v2Prefix, VaultManager.legacyV2Prefix,
                CatalogSnapshot.deltaCaptionPrefix, CatalogSnapshot.legacyDeltaCaptionPrefix,
                CatalogSnapshot.captionPrefix, CatalogSnapshot.legacyCaptionPrefix
            ].contains { text.hasPrefix($0) }
            if isProtectedMeta {
                return false
            }
            // Only CHUNK messages are ever candidates — documents (new format,
            // caption JSON; old format, OBJECT_ID-INDEX.bin name) and audio
            // messages (TDLib auto-converts .mp3 documents into audio). Text
            // messages (folder metadata, welcome messages, anything caption-less)
            // are never purged.
            let isChunk: Bool
            switch msg.content {
            case .messageDocument(let doc):
                isChunk = ChunkCaption.isChunkCaption(text) || doc.document.fileName.hasSuffix(".bin")
            case .messageAudio:
                isChunk = ChunkCaption.isChunkCaption(text)
            default:
                isChunk = false
            }
            guard isChunk else { return false }

            // Resolve which object this chunk belongs to (unified/legacy caption
            // JSON, or the OBJECT_ID-INDEX.bin filename for old-format chunks).
            // If that object still exists in the catalog, its messages are NEVER
            // purged — a wrong message ID is repaired by the scan, never fixed by
            // deletion.
            var chunkObjectID: String? = nil
            if let meta = ChunkCaption.parse(text) {
                chunkObjectID = meta.id
            } else if case .messageDocument(let doc) = msg.content {
                let name = (doc.document.fileName as NSString).deletingPathExtension
                let parts = name.split(separator: "-")
                if parts.count >= 2 {
                    chunkObjectID = parts.dropLast().joined(separator: "-")
                }
            }
            if let chunkObjectID, objectIDs.contains(chunkObjectID) { return false }
            return !validIDs.contains(msg.id)
        }.map(\.id)

        guard !orphanedIDs.isEmpty else { return 0 }

        logger.info("Purging \(orphanedIDs.count) provably-orphaned chunk message(s) from Telegram channel...")
        // Orphaned chunks (and any already-forwarded backup copies) are deleted
        // from both channels so the backup mirror stays a true mirror.
        await BackupSync.deleteFromVaultAndBackup(messageIDs: orphanedIDs)
        return orphanedIDs.count
    }
}
