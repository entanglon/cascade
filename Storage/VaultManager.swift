import Foundation
import Security
import TDLibKit
import os

enum VaultManager {
    private static let logger = Logger(subsystem: "com.cascade.app", category: "vault")

    /// Returns the existing vault, or adopts the account's Saved Messages as the
    /// vault destination.
    ///
    /// Saved Messages is tied to the Telegram account itself — a private chat
    /// owned by the user's own identity, so nothing short of the whole account
    /// being deleted can take the files away. Channels remain in use for the
    /// backup mirror (Cascade Backup) and for sharing (ShareEngine).
    ///
    /// On a fresh install/device (empty local DB) the vault is the account's
    /// Saved Messages chat by construction — no discovery needed: the chat ID is
    /// derived deterministically from the user ID, and both devices of the same
    /// account converge on the same chat.
    static func ensureVault() async throws -> VaultRecord {
        if let existing = try await DatabaseManager.shared.firstVault() {
            // In TDLib's JSON API the Saved Messages chat ID equals the account's
            // own user ID — a positive ~1e9 number. Legacy vault CHANNEL rows are
            // negative, and dummy/test rows are small positives (999999), so
            // anything below 1,000,000 is stale and gets purged + re-adopted.
            if existing.channelID > 1_000_000 {
                return existing
            }
            try? await DatabaseManager.shared.deleteVaultAndData(id: existing.id)
        }

        // 1) Register the Telegram account row (satisfies the vaults foreign key)
        let userID = try await TelegramClient.shared.myUserID()
        let accountID = String(userID)
        try await DatabaseManager.shared.save(AccountRecord(
            id: accountID,
            telegramUserID: userID,
            displayName: "Telegram User",
            state: "ready",
            createdAt: .now
        ))

        // 2) The vault lives in the account's own Saved Messages.
        let chatID = try await TelegramClient.shared.savedMessagesChatID()
        guard await TelegramClient.shared.canSendSavedMessages() else {
            throw VaultError.savedMessagesUnavailable
        }
        logger.info("Vault destination: Saved Messages chat \(chatID)")

        // No vault key: files are stored as plain bytes. `wrappedKey` remains a
        // NOT NULL column for schema stability — it stays empty.
        let vault = VaultRecord(
            id: UUID().uuidString,
            accountID: accountID,
            channelID: chatID,
            name: "Cascade Vault",
            wrappedKey: Data(),
            createdAt: .now
        )
        try await DatabaseManager.shared.save(vault)
        // Keep Saved Messages out of the way: archive + mute it so the constant
        // stream of chunk messages never surfaces in the Telegram chat list.
        Task { await TelegramClient.shared.archiveVaultChannel(chatId: chatID) }
        return vault
    }

    enum VaultError: Swift.Error, Sendable {
        case savedMessagesUnavailable
    }

    // MARK: - Backup mirror channel

    /// Returns the "Cascade Backup" channel, adopting an existing one or creating
    /// it fresh, archived + muted like the vault itself. Every message the app
    /// posts to the vault (Saved Messages) is mirrored into it
    /// (Engine/BackupSync.swift) — the deletion-risk mitigation that replaces
    /// the old encryption story for durability.
    static func ensureBackupChannel() async -> Int64? {
        guard let vault = try? await DatabaseManager.shared.firstVault() else { return nil }
        if let existing = vault.backupChannelID {
            return existing
        }
        let backupID: Int64
        if let found = await TelegramClient.shared.findBackupChannel() {
            backupID = found
        } else if let created = try? await TelegramClient.shared.createVaultChannel(title: "Cascade Backup") {
            backupID = created
        } else {
            return nil
        }
        await TelegramClient.shared.archiveVaultChannel(chatId: backupID)
        // Photo is set by ShareEngine.healChannelPhotos() at every launch.
        var updated = vault
        updated.backupChannelID = backupID
        try? await DatabaseManager.shared.save(updated)
        logger.info("Backup channel ready (channel \(backupID))")
        return backupID
    }
}
