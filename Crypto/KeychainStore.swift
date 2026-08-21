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

        // ThisDeviceOnly for every item: long-lived secrets (master key, PIN hash)
        // must not silently migrate to other devices through Keychain backup
        // flows. Updating the attribute here also migrates pre-existing items the
        // next time they are re-saved.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
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

    /// Re-adds long-lived secrets with ThisDeviceOnly accessibility (idempotent).
    /// Called at launch — items created by older builds used WhenUnlocked, which
    /// allows silent migration to other devices via Keychain backup flows.
    static func migrateSecretsToThisDeviceOnly() {
        for account in [masterKeyAccount, vaultPINAccount] {
            guard let data = try? load(account: account) else { continue }
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(query as CFDictionary)
            try? save(data: data, account: account)
        }
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

    /// Constant-time equality for equal-length ASCII digests — no early exit on
    /// the first differing byte.
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (ca, cb) in zip(a.utf8, b.utf8) { diff |= ca ^ cb }
        return diff == 0
    }

    /// PBKDF2-HMAC-SHA256 hash of the PIN under a random salt. Uses the same
    /// OWASP-2026 cost (600k) as the vault password KDF — the old unsalted
    /// SHA-256 scheme fell to instant offline brute force if the Keychain item
    /// was ever exfiltrated.
    private static func pinHash(_ pin: String, salt: Data) -> String {
        CryptoEngine.passwordKey(from: pin, salt: salt)
            .withUnsafeBytes { Data($0) }
            .base64EncodedString()
    }

    static func saveVaultPIN(_ pin: String) {
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        guard status == errSecSuccess else { return }
        let record = "pbkdf2-sha256:600000:\(salt.base64EncodedString()):\(pinHash(pin, salt: salt))"
        if let data = record.data(using: .utf8) {
            try? save(data: data, account: vaultPINAccount)
        }
    }

    static func loadVaultPINHash() -> String? {
        guard let data = try? load(account: vaultPINAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func verifyVaultPIN(_ pin: String) -> Bool {
        guard let stored = loadVaultPINHash() else { return false }

        // Current format: pbkdf2-sha256:600000:<saltB64>:<hashB64>
        let prefix = "pbkdf2-sha256:600000:"
        if stored.hasPrefix(prefix) {
            let body = stored.dropFirst(prefix.count)
            let parts = body.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let salt = Data(base64Encoded: parts[0]) else {
                return false
            }
            return constantTimeEquals(pinHash(pin, salt: salt), parts[1])
        }

        // Legacy unsalted SHA-256 entry: verify the old way, then transparently
        // upgrade in place to the PBKDF2 record.
        let legacyOK = constantTimeEquals(sha256hex(pin), stored)
        if legacyOK { saveVaultPIN(pin) }
        return legacyOK
    }

    // MARK: - PIN attempt throttling

    private static let pinFailCountKey = "xc.pin.failCount"
    private static let pinLockUntilKey = "xc.pin.lockUntil"

    /// Seconds remaining before the next PIN attempt is allowed (0 = now).
    static func pinLockRemainingSeconds() -> Int {
        Int(max(0, UserDefaults.standard.double(forKey: pinLockUntilKey) - Date().timeIntervalSince1970))
    }

    static func pinAttemptAllowed() -> Bool {
        pinLockRemainingSeconds() == 0
    }

    /// Exponential backoff ladder after repeated failures: 1 s, 2 s, 4 s … capped
    /// at ~17 minutes. UX throttling only (the hash itself is brute-force
    /// resistant); state lives in UserDefaults because losing it just reopens the
    /// gate — the PIN still has to be right.
    static func registerPINResult(success: Bool) {
        let d = UserDefaults.standard
        guard !success else {
            d.set(0, forKey: pinFailCountKey)
            d.set(0, forKey: pinLockUntilKey)
            return
        }
        let failures = d.integer(forKey: pinFailCountKey) + 1
        d.set(failures, forKey: pinFailCountKey)
        if failures >= 3 {
            let delay = min(pow(2, Double(failures - 3)), 1024)
            d.set(Date().timeIntervalSince1970 + delay, forKey: pinLockUntilKey)
        }
    }
}
