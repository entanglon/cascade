import Foundation
import TDLibKit
import os

enum VaultRepair {
    private static let logger = Logger(
        subsystem: "com.xcloud.app",
        category: "repair"
    )

    /// Scans Telegram channel to repair chunk message IDs and promote stuck objects.
    static func run() async -> Bool {
        guard TelegramClient.shared.isAuthorized else { return false }
        guard let vault = try? await DatabaseManager.shared.firstVault() else { return false }
        var changed = false

        // 1. Fetch channel messages from Telegram
        let messages = await TelegramClient.shared.allChannelMessages(chatId: vault.channelID)
        let chunks = (try? await DatabaseManager.shared.allChunks()) ?? []

        // Find chunks needing repair (missing messageID or <= 10_000_000 temporary local ID)
        let brokenChunks = chunks.filter { $0.messageID == nil || ($0.messageID ?? 0) <= 10_000_000 }

        if !brokenChunks.isEmpty && !messages.isEmpty {
            logger.info("Repairing \(brokenChunks.count) chunk(s)...")
            for message in messages {
                var fileName: String? = nil
                var fileSize: Int64 = 0

                switch message.content {
                case .messageDocument(let doc):
                    fileName = doc.document.fileName
                    fileSize = Int64(doc.document.document.size)
                case .messageVideo(let vid):
                    fileSize = Int64(vid.video.video.size)
                case .messagePhoto(let ph):
                    if let best = ph.photo.sizes.max(by: { $0.width < $1.width }) {
                        fileSize = Int64(best.photo.size)
                    }
                default:
                    break
                }

                // Match document filename pattern "OBJECT_ID-INDEX.bin"
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
                } else if fileSize > 0 {
                    // Match single-chunk photos/videos by file size
                    if let targetChunk = brokenChunks.first(where: { $0.size == fileSize }) {
                        try? await DatabaseManager.shared.updateChunk(targetChunk.id) {
                            $0.messageID = message.id
                        }
                        changed = true
                    }
                }
            }
        }

        // 2. Promote failed or uploading objects to ready if all chunks have real message IDs
        let objects = (try? await DatabaseManager.shared.allObjects()) ?? []
        for var object in objects where object.state != "ready" {
            let objChunks = (try? await DatabaseManager.shared.chunks(for: object.id)) ?? []
            guard !objChunks.isEmpty else { continue }
            if objChunks.allSatisfy({ ($0.messageID ?? 0) > 10_000_000 }) {
                object.state = "ready"
                try? await DatabaseManager.shared.save(object)
                changed = true
            }
        }

        return changed
    }
}
