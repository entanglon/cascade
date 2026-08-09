import Foundation
import os
import TDLibKit

enum DBSnapshotEngine {
    private static let logger = Logger(
        subsystem: "com.xcloud.app",
        category: "dbsnapshot"
    )

    private static var lastBackupTime: Foundation.Date = .distantPast

    /// Uploads a lightweight database snapshot of SQLite to the Telegram Vault Channel.
    static func uploadSnapshot() async {
        guard TelegramClient.shared.isAuthorized else { return }
        guard Foundation.Date().timeIntervalSince(lastBackupTime) > 10 else { return } // Debounce 10s
        guard let vault = try? await DatabaseManager.shared.firstVault() else { return }

        lastBackupTime = Foundation.Date()

        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dbURL = support.appendingPathComponent("xCloud/xcloud.sqlite")
            guard FileManager.default.fileExists(atPath: dbURL.path(percentEncoded: false)) else { return }

            // Copy DB to temporary snapshot file
            let tmpDir = try UploadEngine.tempDirectory()
            let snapshotURL = tmpDir.appendingPathComponent("xcloud-db-\(Int(Foundation.Date().timeIntervalSince1970)).sqlite")
            if FileManager.default.fileExists(atPath: snapshotURL.path(percentEncoded: false)) {
                try? FileManager.default.removeItem(at: snapshotURL)
            }
            try FileManager.default.copyItem(at: dbURL, to: snapshotURL)

            let meta: [String: Any] = [
                "timestamp": Foundation.Date().timeIntervalSince1970,
                "version": 1
            ]
            var captionString = "xcloud:dbsnapshot:v1:"
            if let data = try? JSONSerialization.data(withJSONObject: meta),
               let str = String(data: data, encoding: .utf8) {
                captionString += str
            }

            // Upload snapshot to Telegram channel
            let messageId = try await TelegramClient.shared.sendFile(
                chatId: vault.channelID,
                path: snapshotURL.path(percentEncoded: false),
                kind: .document,
                caption: captionString,
                onProgress: nil
            )

            logger.info("Uploaded DB snapshot message ID: \(messageId)")
            try? FileManager.default.removeItem(at: snapshotURL)

            // Clean up older snapshots (keep only newest 2)
            await cleanupOldSnapshots(chatId: vault.channelID, keepMessageId: messageId)
        } catch {
            logger.error("Failed to upload DB snapshot: \(error.localizedDescription)")
        }
    }

    /// Restores database catalog from the latest Telegram Channel DB Snapshot if available.
    static func restoreLatestSnapshot() async -> Bool {
        guard TelegramClient.shared.isAuthorized else { return false }
        guard let vault = try? await DatabaseManager.shared.firstVault() else { return false }

        let messages = await TelegramClient.shared.allChannelMessages(chatId: vault.channelID)
        let snapshots = messages.filter { msg in
            if case .messageDocument(let doc) = msg.content,
               doc.caption.text.hasPrefix("xcloud:dbsnapshot:v1:") {
                return true
            }
            return false
        }

        guard let latestMsg = snapshots.first else { return false }

        do {
            let tmpDir = try UploadEngine.tempDirectory()
            let dest = tmpDir.appendingPathComponent("restore-snapshot.sqlite")
            try await TelegramClient.shared.downloadMessageFile(
                messageId: latestMsg.id,
                chatId: vault.channelID,
                to: dest
            )

            guard FileManager.default.fileExists(atPath: dest.path(percentEncoded: false)) else { return false }

            // Attach snapshot DB and merge missing records into active SQLite database
            try await DatabaseManager.shared.mergeSnapshot(from: dest)
            try? FileManager.default.removeItem(at: dest)
            logger.info("Successfully restored and merged latest DB snapshot from Telegram.")
            return true
        } catch {
            logger.error("Failed to restore DB snapshot: \(error.localizedDescription)")
            return false
        }
    }

    private static func cleanupOldSnapshots(chatId: Int64, keepMessageId: Int64) async {
        let messages = await TelegramClient.shared.allChannelMessages(chatId: chatId)
        let oldSnapshots = messages.filter { msg in
            msg.id != keepMessageId &&
            {
                if case .messageDocument(let doc) = msg.content,
                   doc.caption.text.hasPrefix("xcloud:dbsnapshot:v1:") {
                    return true
                }
                return false
            }()
        }

        guard !oldSnapshots.isEmpty else { return }
        let oldIDs = oldSnapshots.map(\.id)
        try? await TelegramClient.shared.deleteMessages(chatId: chatId, messageIds: oldIDs)
    }
}
