import Foundation
import Security
import CryptoKit

struct TelegramCredentials: Sendable {
    let apiID: Int
    let apiHash: String
}

enum KeychainStore {
    // Cascade.dev) and the
    // Cascade) never share Telegram credentials or vault keys.
    static let service = Bundle.main.bundleIdentifier ?? "com.cascade.app"

    private static let masterKeyAccount = "master-key"
    private static let telegramAccount = "telegram-credentials"

    // MARK: - Generic helpers

    private static func save(data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CryptoError.keychain(addStatus)
            }
        } else if status != errSecSuccess {
            throw CryptoError.keychain(status)
        }
    }

    private static func load(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CryptoError.keychain(status)
        }
        return data
    }

    // MARK: - Master key

    static func saveMasterKey(_ data: Data) throws {
        try save(data: data, account: masterKeyAccount)
    }

    static func loadMasterKey() throws -> Data? {
        try load(account: masterKeyAccount)
    }

    // MARK: - Device identity

    /// A stable per-device identifier used to label the device seal inside the v2
    /// vault key record. Stored in the Keychain so it survives app-container wipes
    /// (and stays stable for as long as the physical device does). Informational
    /// only — the actual crypto is the master key, not this string.
    private static let deviceIDAccount = "xc.device.id"

    static func deviceID() -> String {
        if let data = try? load(account: deviceIDAccount),
           let id = String(data: data, encoding: .utf8), !id.isEmpty {
            return id
        }
        let id = UUID().uuidString
        try? save(data: Data(id.utf8), account: deviceIDAccount)
        return id
    }

    // MARK: - Telegram credentials

    static func saveTelegramCredentials(apiID: Int, apiHash: String) throws {
        let payload: [String: String] = ["apiID": String(apiID), "apiHash": apiHash]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try save(data: data, account: telegramAccount)
    }

    static func loadTelegramCredentials() throws -> TelegramCredentials? {
        guard
            let data = try load(account: telegramAccount),
            let json = try JSONSerialization.jsonObject(with: data) as? [String: String],
            let idString = json["apiID"],
            let apiID = Int(idString),
            let apiHash = json["apiHash"]
        else { return nil }
        return TelegramCredentials(apiID: apiID, apiHash: apiHash)
    }

    // MARK: - Vault PIN

    private static let vaultPINAccount = "xc.vault.pin"

    private static func sha256hex(_ input: String) -> String {
        let digest = CryptoKit.SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func saveVaultPIN(_ pin: String) {
        let hashHex = sha256hex(pin)
        if let data = hashHex.data(using: .utf8) {
            try? save(data: data, account: vaultPINAccount)
        }
    }

    static func loadVaultPINHash() -> String? {
        guard let data = try? load(account: vaultPINAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func verifyVaultPIN(_ pin: String) -> Bool {
        guard let storedHash = loadVaultPINHash() else { return false }
        return storedHash == sha256hex(pin)
    }
}
