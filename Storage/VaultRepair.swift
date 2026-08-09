import Foundation
import TDLibKit
import os

enum VaultRepair {
    private static let logger = Logger(
        subsystem: "com.xcloud.app",
        category: "repair"
    )

    /// Scans Telegram channel to reconstruct missing catalog objects/chunks, repair chunk message IDs, promote stuck objects, and purge orphaned channel messages.
    static func run() async -> Bool {
        guard TelegramClient.shared.isAuthorized else { return false }
        guard let vault = try? await DatabaseManager.shared.firstVault() else { return false }
        var changed = false

        // 1. Fetch channel messages from Telegram
        let messages = await TelegramClient.shared.allChannelMessages(chatId: vault.channelID)
        let chunks = (try? await DatabaseManager.shared.allChunks()) ?? []
        let objects = (try? await DatabaseManager.shared.allObjects()) ?? []

        let objectDict = Dictionary(uniqueKeysWithValues: objects.map { ($0.id, $0) })

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
                case .messageVideo(let vid):
                    fileSize = Int64(vid.video.video.size)
                    captionText = vid.caption.text
                case .messagePhoto(let ph):
                    if let best = ph.photo.sizes.max(by: { $0.width < $1.width }) {
                        fileSize = Int64(best.photo.size)
                    }
                    captionText = ph.caption.text
                default:
                    break
                }

                // Ignore database snapshot messages
                if let caption = captionText, caption.hasPrefix("xcloud:dbsnapshot:") {
                    continue
                }

                // A. Reconstruct from JSON metadata caption (xcloud:v1:...)
                if let caption = captionText, caption.hasPrefix("xcloud:v1:") {
                    let jsonString = String(caption.dropFirst(10))
                    if let data = jsonString.data(using: .utf8),
                       let meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                       let objectID = meta["id"] as? String,
                       let name = meta["name"] as? String,
                       let size = meta["size"] as? Int64 ?? (meta["size"] as? Int).map(Int64.init),
                       let mime = meta["mime"] as? String,
                       let index = meta["index"] as? Int {

                        let parentID = meta["parentID"] as? String
                        let isPrivate = meta["isPrivate"] as? Bool ?? false
                        let totalChunks = meta["totalChunks"] as? Int ?? 1
                        let wrappedKeyStr = meta["wrappedKey"] as? String ?? ""
                        let wrappedKey = Data(base64Encoded: wrappedKeyStr)

                        // Restore Object if missing in SQLite
                        if objectDict[objectID] == nil {
                            let newObj = ObjectRecord(
                                id: objectID,
                                vaultID: vault.id,
                                name: name,
                                size: size,
                                mime: mime,
                                state: "ready",
                                rootHash: nil,
                                wrappedKey: wrappedKey,
                                createdAt: .now,
                                modifiedAt: .now,
                                isFavorite: false,
                                trashed: false,
                                parentID: (parentID == nil || parentID?.isEmpty == true) ? nil : parentID,
                                isFolder: false,
                                isPrivate: isPrivate,
                                sourcePath: nil
                            )
                            try? await DatabaseManager.shared.save(newObj)
                            changed = true
                        }

                        // Restore Chunk if missing or update messageID
                        let existingChunks = (try? await DatabaseManager.shared.chunks(for: objectID)) ?? []
                        if let target = existingChunks.first(where: { $0.index == index }) {
                            if target.messageID != message.id {
                                try? await DatabaseManager.shared.updateChunk(target.id) { $0.messageID = message.id }
                                changed = true
                            }
                        } else {
                            let newChunk = ChunkRecord(
                                id: UUID().uuidString,
                                objectID: objectID,
                                index: index,
                                size: size / Int64(max(1, totalChunks)),
                                plainHash: nil,
                                cipherHash: nil,
                                state: "uploaded",
                                messageID: message.id,
                                fileUniqueID: nil,
                                channelID: vault.channelID,
                                createdAt: .now
                            )
                            try? await DatabaseManager.shared.save(newChunk)
                            changed = true
                        }
                        continue
                    }
                }

                // B. Fallback: Match filename pattern "OBJECT_ID-INDEX.bin"
                let brokenChunks = chunks.filter { $0.messageID == nil || ($0.messageID ?? 0) <= 10_000_000 }
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

        // 2. Promote failed or uploading objects to ready if all chunks have real message IDs
        let currentObjects = (try? await DatabaseManager.shared.allObjects()) ?? []
        for var object in currentObjects where object.state != "ready" {
            let objChunks = (try? await DatabaseManager.shared.chunks(for: object.id)) ?? []
            guard !objChunks.isEmpty else { continue }
            if objChunks.allSatisfy({ ($0.messageID ?? 0) > 10_000_000 }) {
                object.state = "ready"
                try? await DatabaseManager.shared.save(object)
                changed = true
            }
        }

        // 3. Purge invalid/orphaned ObjectRecords in SQLite that have no chunks (except folders)
        let allObjectsNow = (try? await DatabaseManager.shared.allObjects()) ?? []
        let allChunksNow = (try? await DatabaseManager.shared.allChunks()) ?? []
        let validObjectIDsWithChunks = Set(allChunksNow.map(\.objectID))
        for obj in allObjectsNow where !obj.isFolder {
            if !validObjectIDsWithChunks.contains(obj.id) {
                try? await DatabaseManager.shared.deleteObjectWithChunks(id: obj.id)
                changed = true
            }
        }

        // 4. Purge any orphaned messages in Telegram channel that no longer belong to active chunks
        let purgedCount = await purgeOrphanedMessages()
        if purgedCount > 0 {
            changed = true
        }

        return changed
    }

    /// Scans Telegram channel and deletes any messages that are not associated with active chunks in SQLite.
    @discardableResult
    static func purgeOrphanedMessages() async -> Int {
        guard TelegramClient.shared.isAuthorized else { return 0 }
        guard let vault = try? await DatabaseManager.shared.firstVault() else { return 0 }

        let allMessages = await TelegramClient.shared.allChannelMessages(chatId: vault.channelID)
        guard !allMessages.isEmpty else { return 0 }

        let validChunks = (try? await DatabaseManager.shared.allChunks()) ?? []
        let validIDs = Set(validChunks.compactMap(\.messageID))

        let orphanedIDs = allMessages.filter { msg in
            if case .messageDocument(let doc) = msg.content, doc.caption.text.hasPrefix("xcloud:dbsnapshot:") {
                return true
            }
            return !validIDs.contains(msg.id)
        }.map(\.id)

        guard !orphanedIDs.isEmpty else { return 0 }

        logger.info("Purging \(orphanedIDs.count) orphaned message(s) from Telegram channel...")
        for i in stride(from: 0, to: orphanedIDs.count, by: 100) {
            let batch = Array(orphanedIDs[i..<min(i + 100, orphanedIDs.count)])
            try? await TelegramClient.shared.deleteMessages(chatId: vault.channelID, messageIds: batch)
        }
        return orphanedIDs.count
    }
}
