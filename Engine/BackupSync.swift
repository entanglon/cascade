import Foundation
import GRDB

/// Mirrors every message the app posts to the vault channel into a second private
/// channel ("Cascade Backup", archived + muted) via cheap reference forwards
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

    /// File-based mirror log (/tmp/xcloud-backup.log) — the unified log is not
    /// reliably readable on this machine, and the app's stdout goes nowhere when
    /// launched via `open`.
    static func mirrorLog(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: .now)
        let entry = Data("\(stamp) \(line)\n".utf8)
        if let handle = FileHandle(forWritingAtPath: "/tmp/xcloud-backup.log") {
            handle.seekToEndOfFile()
            handle.write(entry)
            try? handle.close()
        } else {
            try? entry.write(to: URL(fileURLWithPath: "/tmp/xcloud-backup.log"))
        }
    }

    /// Records a vault-channel message for mirroring and kicks the drainer.
    static func enqueue(messageID: Int64, objectID: String) {
        guard messageID > 0 else { return }
        try? DatabaseManager.shared.enqueueBackup(messageID: messageID, objectID: objectID)
        mirrorLog("enqueue message \(messageID) (\(objectID))")
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
    /// SAFEGUARD: Checkpoints, deltas, and vault key records are NEVER deleted
    /// from the backup channel — the backup channel remains an immutable audit log.
    static func deleteFromVaultAndBackup(messageIDs: [Int64]) async {
        guard !messageIDs.isEmpty,
              let vault = try? await DatabaseManager.shared.firstVault() else { return }

        // Main channel.
        for i in stride(from: 0, to: messageIDs.count, by: 100) {
            let batch = Array(messageIDs[i..<min(i + 100, messageIDs.count)])
            try? await TelegramClient.shared.deleteMessages(chatId: vault.channelID, messageIds: batch)
        }

        // Backup copies, then mapping rows. Protect critical database/key records.
        let protectedObjectIDs: Set<String> = [checkpointObjectID, deltaObjectID, keyRecordObjectID]
        if let backupID = vault.backupChannelID,
           let targets = try? await DatabaseManager.shared.backupTargets(for: messageIDs),
           !targets.isEmpty {
            let safeTargets = targets.filter { !protectedObjectIDs.contains($0.objectID) }
            let backupIDs = safeTargets.compactMap(\.backupMessageID)
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
              let backupID = vault.backupChannelID else { return }
        let ids = await TelegramClient.shared.allChannelMessageIDs(chatId: backupID)
        for i in stride(from: 0, to: ids.count, by: 100) {
            let batch = Array(ids[i..<min(i + 100, ids.count)])
            try? await TelegramClient.shared.deleteMessages(chatId: backupID, messageIds: batch)
        }
        try? await DatabaseManager.shared.deleteAllBackupRows()
    }

    private static func syncCaption(messageID: Int64, caption: String) async {
        guard let vault = try? await DatabaseManager.shared.firstVault(),
              let backupID = vault.backupChannelID,
              let row = try? await DatabaseManager.shared.backupRow(messageID: messageID),
              let backupMsgID = row.backupMessageID else { return }
        try? await TelegramClient.shared.editMessageCaption(chatId: backupID, messageId: backupMsgID, caption: caption)
    }
}

/// Serial drainer for the mirror queue. The actor guard makes concurrent
/// `drain()` calls coalesce — enqueueing kicks a drain, but only one runs.
/// Processes at most `maxPerDrain` rows per invocation so a stuck TDLib request
/// can never wedge the queue permanently (the launch drain re-triggers later).
actor BackupDrainer {
    static let shared = BackupDrainer()
    private var active = false
    private let maxPerDrain = 50
    /// A message that keeps failing to forward (e.g. it was deleted or pruned from
    /// the vault channel before the mirror completed) can never succeed. After this
    /// many attempts it is marked failed and SKIPPED — otherwise a single dead
    /// message at the head of the FIFO queue wedges the entire backup behind it and
    /// the backup channel goes permanently stale (it only ever recovers when a
    /// fresh forward happens to beat the dead one).
    private let maxForwardAttempts = 5

    func drain() async {
        guard !active else { return }
        active = true
        defer { active = false }

        guard let vault = try? await DatabaseManager.shared.firstVault(),
              let backupID = vault.backupChannelID,
              await TelegramClient.shared.isAuthorized else {
            BackupSync.mirrorLog("drain skipped (no vault/backup channel/authorization)")
            return
        }

        var forwarded = 0
        while forwarded < maxPerDrain,
              let pending = try? await DatabaseManager.shared.nextPendingBackup() {
            do {
                BackupSync.mirrorLog("forward \(pending.messageID) → \(backupID)")
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
                forwarded += 1
                BackupSync.mirrorLog("forwarded \(pending.messageID) → backup message \(newID)")
                // 500ms between forwards: a full 50-message drain takes ~25s
                // instead of <10s — still fast, but stays well clear of
                // sustained FLOOD_WAIT on write operations.
                try? await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                // Non-flood failure: back off and retry on the next drain trigger
                // (next upload, next launch). Flood waits are already handled inside
                // withFloodWait — a return here means a real error.
                try? await DatabaseManager.shared.bumpBackupAttempts(messageID: pending.messageID)
                BackupSync.mirrorLog("forward FAILED for \(pending.messageID): \(error.localizedDescription)")
                print("Cascade backup forward failed for \(pending.messageID): \(error.localizedDescription)")
                if (try? await DatabaseManager.shared.backupAttempts(messageID: pending.messageID)) ?? 0 >= maxForwardAttempts {
                    // Permanently dead message (deleted/pruned source): skip it so
                    // the queue can progress. Its content is gone from the vault
                    // channel anyway — nothing to mirror.
                    try? await DatabaseManager.shared.markBackupFailed(messageID: pending.messageID)
                    BackupSync.mirrorLog("skipping \(pending.messageID) (exceeded \(maxForwardAttempts) attempts)")
                    print("Cascade backup: skipping dead message \(pending.messageID)")
                    continue
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return
            }
        }
        BackupSync.mirrorLog("drain done (forwarded \(forwarded))")
    }
}