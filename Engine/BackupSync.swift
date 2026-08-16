import Foundation
import GRDB

/// Mirrors every message the app posts to the vault channel into a second private
/// channel ("xCloud Restore", archived + muted) via cheap reference forwards
/// (`sendCopy: false` — no re-upload, captions and encryption preserved). If the
/// main vault channel is ever deleted — by the user or by a malfunctioning app —
/// the backup channel still holds the complete storage + catalog, and a future
/// "restore from backup" phase can rebuild from it.
///
/// Design decisions (2026-08-16):
/// - No retention/tombstones: Trash is already the backup; permanently deleting a
///   file removes its messages from BOTH channels. Nothing lingers after a
///   permanent delete.
/// - The mirror queue is the `backup_msgs` table; the drainer forwards one message
///   at a time with flood-wait handling (~1 msg/sec is Telegram's only real cap).
/// - Edits are mirrored too: `editAndMirror` updates a backup copy's caption via
///   the main→backup message-id mapping. Edits that land before a forward happens
///   are picked up automatically (the forward copies the current caption).
enum BackupSync {
    /// Sentinel `objectID`s for non-chunk vault messages.
    static let checkpointObjectID = "xcloud:checkpoint"
    static let deltaObjectID = "xcloud:delta"
    static let keyRecordObjectID = "xcloud:vaultkey"

    /// Records a vault-channel message for mirroring and kicks the drainer.
    static func enqueue(messageID: Int64, objectID: String) {
        guard messageID > 0 else { return }
        try? DatabaseManager.shared.enqueueBackup(messageID: messageID, objectID: objectID)
        Task { await BackupDrainer.shared.drain() }
    }

    /// Edits a vault-channel message caption AND its backup copy (when already
    /// forwarded). If the forward hasn't happened yet, the forward picks up the
    /// edited caption by itself — no gap either way.
    static func editAndMirror(chatId: Int64, messageId: Int64, caption: String) async {
        try? await TelegramClient.shared.editMessageCaption(chatId: chatId, messageId: messageId, caption: caption)
        await syncCaption(messageID: messageId, caption: caption)
    }

    /// Deletes messages from the vault channel plus their forwarded backup copies,
    /// then drops the mapping rows. Batches like the call sites it replaces did.
    static func deleteFromVaultAndBackup(messageIDs: [Int64]) async {
        guard !messageIDs.isEmpty,
              let vault = try? await DatabaseManager.shared.firstVault() else { return }

        // Main channel.
        for i in stride(from: 0, to: messageIDs.count, by: 100) {
            let batch = Array(messageIDs[i..<min(i + 100, messageIDs.count)])
            try? await TelegramClient.shared.deleteMessages(chatId: vault.channelID, messageIds: batch)
        }

        // Backup copies, then mapping rows.
        if let backupID = vault.backupChannelID, backupID > 0,
           let targets = try? await DatabaseManager.shared.backupTargets(for: messageIDs),
           !targets.isEmpty {
            let backupIDs = targets.compactMap(\.backupMessageID)
            for i in stride(from: 0, to: backupIDs.count, by: 100) {
                let batch = Array(backupIDs[i..<min(i + 100, backupIDs.count)])
                try? await TelegramClient.shared.deleteMessages(chatId: backupID, messageIds: batch)
            }
        }
        try? await DatabaseManager.shared.deleteBackupRows(messageIDs: messageIDs)
    }

    /// Wipes the entire backup channel and mirror queue (used by vault reset).
    static func wipeBackupChannel() async {
        guard let vault = try? await DatabaseManager.shared.firstVault(),
              let backupID = vault.backupChannelID, backupID > 0 else { return }
        let ids = await TelegramClient.shared.allChannelMessageIDs(chatId: backupID)
        for i in stride(from: 0, to: ids.count, by: 100) {
            let batch = Array(ids[i..<min(i + 100, ids.count)])
            try? await TelegramClient.shared.deleteMessages(chatId: backupID, messageIds: batch)
        }
        try? await DatabaseManager.shared.deleteAllBackupRows()
    }

    private static func syncCaption(messageID: Int64, caption: String) async {
        guard let vault = try? await DatabaseManager.shared.firstVault(),
              let backupID = vault.backupChannelID, backupID > 0,
              let row = try? await DatabaseManager.shared.backupRow(messageID: messageID),
              let backupMsgID = row.backupMessageID else { return }
        try? await TelegramClient.shared.editMessageCaption(chatId: backupID, messageId: backupMsgID, caption: caption)
    }
}

/// Serial drainer for the mirror queue. The actor guard makes concurrent
/// `drain()` calls coalesce — enqueueing kicks a drain, but only one runs.
actor BackupDrainer {
    static let shared = BackupDrainer()
    private var active = false

    func drain() async {
        guard !active else { return }
        active = true
        defer { active = false }

        guard let vault = try? await DatabaseManager.shared.firstVault(),
              let backupID = vault.backupChannelID, backupID > 0,
              await TelegramClient.shared.isAuthorized else { return }

        while let pending = try? await DatabaseManager.shared.nextPendingBackup() {
            do {
                let newID = try await TelegramClient.shared.withFloodWait {
                    try await TelegramClient.shared.forwardMessage(
                        chatId: backupID,
                        fromChatId: vault.channelID,
                        messageId: pending.messageID
                    )
                }
                try? await DatabaseManager.shared.markBackupForwarded(
                    messageID: pending.messageID, backupMessageID: newID
                )
            } catch {
                // Non-flood failure: back off and retry on the next drain trigger
                // (next upload, next launch). Flood waits are already handled inside
                // withFloodWait — a return here means a real error.
                try? await DatabaseManager.shared.bumpBackupAttempts(messageID: pending.messageID)
                print("xCloud backup forward failed for \(pending.messageID): \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return
            }
        }
    }
}