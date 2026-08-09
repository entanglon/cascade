import Foundation
import CryptoKit
import Security
import os

enum CryptoError: Error, Sendable {
    case keychain(OSStatus)
    case noMasterKey
    case tampered
    case testFailed
}

enum CryptoEngine {
    /// Plaintext size of one encrypted slice.
    static let sliceSize = 1024 * 1024
    /// Ciphertext size of one encrypted slice (nonce 12B + tag 16B = 28B overhead).
    static let sealedSliceSize = sliceSize + 28
    
    private static let logger = Logger(
        subsystem: "com.xcloud.app",
        category: "crypto"
    )
    
    // MARK: - Master key
    
    static func masterKey() throws -> SymmetricKey {
        if let data = try KeychainStore.loadMasterKey() {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        try KeychainStore.saveMasterKey(key.withUnsafeBytes { Data($0) })
        return key
    }
    
    // MARK: - Key wrapping (AES-GCM sealed boxes)
    
    static func wrap(_ key: SymmetricKey, with wrappingKey: SymmetricKey) throws -> Data {
        let raw = key.withUnsafeBytes { Data($0) }
        let sealed = try AES.GCM.seal(raw, using: wrappingKey)
        guard let combined = sealed.combined else { throw CryptoError.testFailed }
        return combined
    }
    
    static func unwrap(_ wrapped: Data, with wrappingKey: SymmetricKey) throws -> SymmetricKey {
        let box = try AES.GCM.SealedBox(combined: wrapped)
        let raw = try AES.GCM.open(box, using: wrappingKey)
        return SymmetricKey(data: raw)
    }
    
    // MARK: - Slice key derivation (HKDF-SHA256)
    
    static func sliceKey(objectKey: SymmetricKey, index: Int) -> SymmetricKey {
        var info = Data("xcloud-slice-v1:".utf8)
        let idx = UInt64(index).bigEndian
        withUnsafeBytes(of: idx) { info.append(contentsOf: $0) }
        
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: objectKey,
            salt: Data("xcloud-salt-v1".utf8),
            info: info,
            outputByteCount: 32
        )
    }
    
    // MARK: - Slice encryption / decryption
    
    static func encryptSlice(
        _ plaintext: Data,
        objectKey: SymmetricKey,
        index: Int
    ) throws -> Data {
        let key = sliceKey(objectKey: objectKey, index: index)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw CryptoError.testFailed }
        return combined
    }
    
    static func decryptSlice(
        _ combined: Data,
        objectKey: SymmetricKey,
        index: Int
    ) throws -> Data {
        let key = sliceKey(objectKey: objectKey, index: index)
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: key)
    }
    
    // MARK: - Self test
    
    static func selfTest() async throws {
        try runSelfTest()
    }
    
    private static func runSelfTest() throws {
        let master = try masterKey()
        let masterAgain = try masterKey()
        let a = master.withUnsafeBytes { Data($0) }
        let b = masterAgain.withUnsafeBytes { Data($0) }
        guard a == b else { throw CryptoError.noMasterKey }
        
        let vaultKey = SymmetricKey(size: .bits256)
        let wrappedVault = try wrap(vaultKey, with: master)
        let unwrappedVault = try unwrap(wrappedVault, with: master)
        
        let objectKey = SymmetricKey(size: .bits256)
        let wrappedObject = try wrap(objectKey, with: unwrappedVault)
        let unwrappedObject = try unwrap(wrappedObject, with: vaultKey)
        
        var plaintext = Data(count: sliceSize)
        let randomResult = plaintext.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, sliceSize, $0.baseAddress!)
        }
        guard randomResult == errSecSuccess else { throw CryptoError.testFailed }
        
        let encrypted = try encryptSlice(plaintext, objectKey: unwrappedObject, index: 7)
        let decrypted = try decryptSlice(encrypted, objectKey: unwrappedObject, index: 7)
        guard decrypted == plaintext else { throw CryptoError.testFailed }
        
        var tampered = encrypted
        let pos = tampered.index(tampered.startIndex, offsetBy: 20)
        tampered[pos] ^= 0xFF
        
        var tamperDetected = false
        do {
            _ = try decryptSlice(tampered, objectKey: unwrappedObject, index: 7)
        } catch {
            tamperDetected = true
        }
        guard tamperDetected else { throw CryptoError.tampered }
        
        var indexDetected = false
        do {
            _ = try decryptSlice(encrypted, objectKey: unwrappedObject, index: 8)
        } catch {
            indexDetected = true
        }
        guard indexDetected else { throw CryptoError.testFailed }
        
        logger.info("Crypto engine self-test passed")
    }
}
