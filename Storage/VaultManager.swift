import Foundation
import CryptoKit
import Security
import TDLibKit
import os

enum VaultManager {
    private static let logger = Logger(subsystem: "com.xcloud.app", category: "vault")

    /// Returns the existing vault, or creates a private Telegram channel vault.
    ///
    /// On a fresh install/device (empty local DB) this first searches the account's
    /// existing Telegram chats for a previously-created "xCloud Vault" channel and
    /// adopts it, so files uploaded on another device reappear instead of the app
    /// silently creating a brand-new empty channel.
    static func ensureVault() async throws -> VaultRecord {
        if let existing = try await DatabaseManager.shared.firstVault() {
            // Real vault channels have large negative TDLib chat IDs. A positive/small
            // ID means leftover test/dummy data (the unit-test host writes a "Test
            // Vault" row with channelID 999999 into the app's real database). Such a
            // row would block discovery of the user's actual vault and make files
            // "disappear", so purge it and rediscover below.
            if existing.channelID < 0 {
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

        let master = try CryptoEngine.masterKey()

        // 2) Discovery: adopt the account's existing vault channel if one exists.
        // The vault key is per-device (wrapped with the per-device master key), so on
        // a new container we mint a fresh vault key until the user recovers the real
        // one via their PIN (`attemptRecovery`). The file catalog and public files
        // restore immediately; private files unlock once the PIN is entered.
        let chatID: Int64
        let wrapped: Data
        if let found = await TelegramClient.shared.findVaultChannel() {
            let vaultKey = SymmetricKey(size: .bits256)
            wrapped = try CryptoEngine.wrap(vaultKey, with: master)
            chatID = found
            logger.info("Adopted existing vault channel \(chatID)")
        } else {
            // 3) No existing vault: create the private channel on Telegram.
            let vaultKey = SymmetricKey(size: .bits256)
            wrapped = try CryptoEngine.wrap(vaultKey, with: master)
            chatID = try await TelegramClient.shared
                .createVaultChannel(title: "xCloud Vault")
            logger.info("Created new vault channel \(chatID)")
        }

        let vault = VaultRecord(
            id: UUID().uuidString,
            accountID: accountID,
            channelID: chatID,
            name: "xCloud Vault",
            wrappedKey: wrapped,
            createdAt: .now
        )
        try await DatabaseManager.shared.save(vault)
        // Keep the channel out of the Telegram chat list: archive + mute it so
        // nobody (the user included) opens it and messes up the storage messages.
        Task { await TelegramClient.shared.archiveVaultChannel(chatId: chatID) }
        // Same-device fresh container: if the channel's v2 key record carries a seal
        // made with THIS device's Keychain master key, adopt the real vault key
        // silently — private files work again without re-entering the PIN.
        await autoRecoverWithDeviceSeal()
        return vault
    }

    static func vaultKey(for vault: VaultRecord) throws -> SymmetricKey {
        let master = try CryptoEngine.masterKey()
        return try CryptoEngine.unwrap(vault.wrappedKey, with: master)
    }

    // MARK: - Cross-device recovery (password-derived vault key, v2)

    /// The canonical key record posted to the channel (`xcloud:vaultkey:v2:` caption).
    /// It carries the vault key sealed TWICE:
    ///  - `passwordSeal`: with the password-derived key (PBKDF2(pin, per-vault salt)) —
    ///    ANY device that knows the PIN can unwrap it. This is the single source of
    ///    truth for the vault key; nothing depends on which device posted it.
    ///  - `deviceSeal`: with this device's Keychain master key — so a fresh container
    ///    on the SAME device recovers private files without re-entering the PIN.
    /// The salt is per-vault, random, and public (uniqueness, not secrecy).
    struct VaultKeyRecordV2: Codable {
        var salt: Data
        var passwordSeal: Data
        var deviceSeal: Data
        var deviceID: String
    }

    static let v2Prefix = "xcloud:vaultkey:v2:"
    private static let v1Prefix = "xcloud:vaultkey:"

    static func v2Caption(_ record: VaultKeyRecordV2) -> String {
        v2Prefix + (try! JSONEncoder().encode(record)).base64EncodedString()
    }

    static func parseV2Record(caption: String) throws -> VaultKeyRecordV2 {
        guard caption.hasPrefix(v2Prefix),
              let data = Data(base64Encoded: String(caption.dropFirst(v2Prefix.count))) else {
            throw CryptoError.tampered
        }
        return try JSONDecoder().decode(VaultKeyRecordV2.self, from: data)
    }

    /// Posts (or updates) the canonical v2 key record in the channel, then removes
    /// any OLDER key records (v1 blobs or v2 records from other devices) so the
    /// channel holds exactly one. Called whenever the vault PIN is set or verified
    /// on a device that holds the vault key.
    static func ensureRecoveryBlob(pin: String) async {
        do {
            guard TelegramClient.shared.isAuthorized else { return }
            guard let vault = try await DatabaseManager.shared.firstVault() else { return }
            let vaultKey = try vaultKey(for: vault)
            let master = try CryptoEngine.masterKey()
            let salt = vault.recoverySalt ?? generateSalt()
            let record = VaultKeyRecordV2(
                salt: salt,
                passwordSeal: try CryptoEngine.wrap(vaultKey, with: CryptoEngine.passwordKey(from: pin, salt: salt)),
                deviceSeal: try CryptoEngine.wrap(vaultKey, with: master),
                deviceID: KeychainStore.deviceID()
            )
            let caption = v2Caption(record)

            let postedID: Int64?
            if let msgID = vault.recoveryMessageID {
                try? await TelegramClient.shared.editMessageCaption(
                    chatId: vault.channelID, messageId: msgID, caption: caption
                )
                postedID = msgID
            } else if let msgID = try await TelegramClient.shared.sendMetadataMessage(
                chatId: vault.channelID, text: caption
            ) {
                postedID = msgID
            } else {
                postedID = nil
            }
            guard let postedID else { return }

            var updated = vault
            updated.recoveryMessageID = postedID
            updated.recoverySalt = salt
            try? await DatabaseManager.shared.save(updated)
            logger.info("Posted vault key record v2 (message \(postedID))")

            // Additive migration: once the v2 record is up, drop every OLDER key
            // record (legacy v1 blobs, other devices' v2 records). Only ones older
            // than ours are removed, so a racing peer's newer record is never deleted.
            await deleteStaleKeyRecords(chatId: vault.channelID, keepingNewerThan: postedID)
        } catch {
            logger.error("Failed to post recovery record: \(error.localizedDescription)")
        }
    }

    /// True when the channel carries a `xcloud:vaultkey:` key record (v2 or legacy
    /// v1) — i.e. the account's private files can be recovered by entering the PIN
    /// on this device.
    static func hasRecoveryBlob() async -> Bool {
        guard let vault = try? await DatabaseManager.shared.firstVault() else { return false }
        return await TelegramClient.shared.findRecoveryBlob(chatId: vault.channelID) != nil
    }

    /// Recovers the real vault key from the channel using the PIN the user entered.
    /// Prefers the canonical v2 record (password-derived key + per-vault salt); falls
    /// back to legacy v1 blobs for vaults that predate v2. On success the recovered
    /// key replaces the local (freshly-minted) vault key so private files uploaded on
    /// other devices can be decrypted. Returns false when the PIN is wrong or no key
    /// record exists.
    static func attemptRecovery(pin: String) async -> Bool {
        do {
            guard let vault = try await DatabaseManager.shared.firstVault() else { return false }
            guard let recordMsg = await TelegramClient.shared.findRecoveryBlob(chatId: vault.channelID),
                  let caption = blobCaption(recordMsg) else { return false }

            // v2: derive the key from the PIN + the record's own salt. No dependency
            // on the local DB or on which device posted the record — this is what
            // makes the vault-key-mismatch bug class impossible.
            if let record = try? parseV2Record(caption: caption) {
                let derived = CryptoEngine.passwordKey(from: pin, salt: record.salt)
                let recovered = try CryptoEngine.unwrap(record.passwordSeal, with: derived)
                try await persistRecoveredKey(recovered, salt: record.salt, recordMessageID: recordMsg.id, vault: vault)
                logger.info("Recovered vault key via PIN from v2 record \(recordMsg.id)")
                return true
            }

            // v1 legacy blob (fixed salt, 150k iterations). After recovering, post the
            // v2 record so this vault is upgraded and the old blob is cleaned up.
            guard let sealedData = Data(base64Encoded: String(caption.dropFirst(v1Prefix.count))) else { return false }
            let recovered = try CryptoEngine.unwrap(sealedData, with: CryptoEngine.recoveryKey(from: pin))
            try await persistRecoveredKey(recovered, salt: vault.recoverySalt, recordMessageID: recordMsg.id, vault: vault)
            logger.info("Recovered vault key via PIN from legacy blob \(recordMsg.id)")
            Task { await ensureRecoveryBlob(pin: pin) }
            return true
        } catch {
            return false
        }
    }

    /// Same-device fresh container: the v2 record's device seal unlocks the real
    /// vault key with the local Keychain master key — no PIN needed. Returns true
    /// when the real key was adopted. Also heals the vault-key-mismatch case (a DB
    /// row whose wrappedKey was made by another device's master key) when that
    /// "other device" is actually this one.
    @discardableResult
    static func autoRecoverWithDeviceSeal() async -> Bool {
        do {
            guard TelegramClient.shared.isAuthorized else { return false }
            guard let vault = try await DatabaseManager.shared.firstVault() else { return false }
            // Already hold a working vault key → nothing to do.
            if (try? vaultKey(for: vault)) != nil { return false }
            guard let recordMsg = await TelegramClient.shared.findRecoveryBlob(chatId: vault.channelID),
                  let caption = blobCaption(recordMsg),
                  let record = try? parseV2Record(caption: caption) else { return false }
            let master = try CryptoEngine.masterKey()
            let recovered = try CryptoEngine.unwrap(record.deviceSeal, with: master)
            try await persistRecoveredKey(recovered, salt: record.salt, recordMessageID: recordMsg.id, vault: vault)
            logger.info("Auto-recovered vault key via device seal (message \(recordMsg.id))")
            return true
        } catch {
            return false
        }
    }

    private static func persistRecoveredKey(
        _ key: SymmetricKey,
        salt: Data?,
        recordMessageID: Int64,
        vault: VaultRecord
    ) async throws {
        let master = try CryptoEngine.masterKey()
        let reWrapped = try CryptoEngine.wrap(key, with: master)
        var updated = vault
        updated.wrappedKey = reWrapped
        updated.recoveryMessageID = recordMessageID
        updated.recoverySalt = salt ?? vault.recoverySalt
        try await DatabaseManager.shared.save(updated)
    }

    private static func deleteStaleKeyRecords(chatId: Int64, keepingNewerThan anchor: Int64) async {
        let messages = await TelegramClient.shared.allChannelMessages(chatId: chatId)
        let stale = messages.filter { msg in
            guard let text = blobCaption(msg), text.hasPrefix(v1Prefix) else { return false }
            return msg.id < anchor
        }.map(\.id)
        guard !stale.isEmpty else { return }
        try? await TelegramClient.shared.deleteMessages(chatId: chatId, messageIds: stale)
        logger.info("Removed \(stale.count) stale vault key record(s)")
    }

    private static func generateSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    private static func blobCaption(_ message: TDLibKit.Message) -> String? {
        switch message.content {
        case .messageText(let mt): return mt.text.text
        case .messageDocument(let doc): return doc.caption.text
        case .messageAudio(let au): return au.caption.text
        default: return nil
        }
    }
}
