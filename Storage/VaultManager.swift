import Foundation
import CryptoKit

enum VaultManager {
    /// Returns the existing vault, or creates a private Telegram channel vault.
    static func ensureVault() async throws -> VaultRecord {
        if let existing = try await DatabaseManager.shared.firstVault() {
            return existing
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

        // 2) Create the vault key and wrap it with the master key
        let master = try CryptoEngine.masterKey()
        let vaultKey = SymmetricKey(size: .bits256)
        let wrapped = try CryptoEngine.wrap(vaultKey, with: master)

        // 3) Create the private channel on Telegram
        let chatID = try await TelegramClient.shared
            .createVaultChannel(title: "xCloud Vault")

        let vault = VaultRecord(
            id: UUID().uuidString,
            accountID: accountID,
            channelID: chatID,
            name: "xCloud Vault",
            wrappedKey: wrapped,
            createdAt: .now
        )
        try await DatabaseManager.shared.save(vault)
        return vault
    }

    static func vaultKey(for vault: VaultRecord) throws -> SymmetricKey {
        let master = try CryptoEngine.masterKey()
        return try CryptoEngine.unwrap(vault.wrappedKey, with: master)
    }
}
