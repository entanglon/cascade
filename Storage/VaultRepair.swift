import Foundation

enum VaultRepair {
    /// Promotes "failed" objects back to "ready" when Telegram confirms their chunks.
    static func run() async -> Bool {
        guard let vault = try? await DatabaseManager.shared.firstVault() else { return false }
        await TelegramClient.shared.fetchRecentMessages(chatId: vault.channelID)

        let objects = (try? await DatabaseManager.shared.allObjects()) ?? []
        var changed = false

        for var object in objects where object.state == "failed" {
            let chunks = (try? await DatabaseManager.shared.chunks(for: object.id)) ?? []
            guard !chunks.isEmpty else { continue }

            var allUploaded = true
            for chunk in chunks {
                guard let messageId = chunk.messageID else { allUploaded = false; break }
                if case .uploaded = await TelegramClient.shared.uploadStatus(
                    chatId: vault.channelID, messageId: messageId
                ) { continue } else { allUploaded = false; break }
            }

            if allUploaded {
                object.state = "ready"
                try? await DatabaseManager.shared.save(object)
                changed = true
            }
        }
        return changed
    }
}
