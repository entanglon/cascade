import Foundation
import CryptoKit
import Security
import CommonCrypto
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
        subsystem: "com.cascade.app",
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
        var info = Data("cascade-slice-v1:".utf8)
        let idx = UInt64(index).bigEndian
        withUnsafeBytes(of: idx) { info.append(contentsOf: $0) }
        
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: objectKey,
            salt: Data("cascade-salt-v1".utf8),
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

    // MARK: - Chunk encryption / decryption

    /// Encrypts an arbitrary chunk payload (which may span multiple 1 MB slices)
    /// into concatenated AES-GCM sealed slices.
    static func encryptChunk(
        _ plaintext: Data,
        objectKey: SymmetricKey,
        startSliceIndex: Int
    ) throws -> Data {
        var encrypted = Data()
        var offset = 0
        var currentSliceIndex = startSliceIndex
        
        while offset < plaintext.count {
            let length = min(sliceSize, plaintext.count - offset)
            let sliceData = plaintext.subdata(in: offset ..< offset + length)
            let sealed = try encryptSlice(sliceData, objectKey: objectKey, index: currentSliceIndex)
            encrypted.append(sealed)
            offset += length
            currentSliceIndex += 1
        }
        return encrypted
    }

    /// Decrypts concatenated AES-GCM sealed slices back into the original plaintext.
    static func decryptChunk(
        _ ciphertext: Data,
        objectKey: SymmetricKey,
        startSliceIndex: Int
    ) throws -> Data {
        var decrypted = Data()
        var offset = 0
        var currentSliceIndex = startSliceIndex

        while offset < ciphertext.count {
            let remaining = ciphertext.count - offset
            let sliceCipherLength = min(sealedSliceSize, remaining)
            let sealedSliceData = ciphertext.subdata(in: offset ..< offset + sliceCipherLength)
            let plain = try decryptSlice(sealedSliceData, objectKey: objectKey, index: currentSliceIndex)
            decrypted.append(plain)
            offset += sliceCipherLength
            currentSliceIndex += 1
        }
        return decrypted
    }

    // MARK: - Streaming chunk transform (fixed ~MiB RAM regardless of chunk size)

    /// Streams chunk ENCRYPTION: reads up to `plainByteLimit` plaintext bytes from
    /// `src` one slice at a time, appending sealed slices to `dst`. Peak RAM is one
    /// slice, so multi-GiB chunks never materialize in memory.
    /// Returns the number of CIPHERTEXT bytes written to `dst`.
    static func encryptStream(
        from src: FileHandle,
        to dst: FileHandle,
        plainByteLimit: Int64,
        objectKey: SymmetricKey,
        startSliceIndex: Int,
        plainHasher: inout SHA256?,
        cipherHasher: inout SHA256?
    ) throws -> Int64 {
        var consumed: Int64 = 0
        var written: Int64 = 0
        var index = startSliceIndex
        while consumed < plainByteLimit {
            let want = Int(min(Int64(sliceSize), plainByteLimit - consumed))
            guard let piece = try src.read(upToCount: want), piece.count == want else {
                throw CryptoError.testFailed // source shorter than the plan says
            }
            plainHasher?.update(data: piece)
            let sealed = try encryptSlice(piece, objectKey: objectKey, index: index)
            cipherHasher?.update(data: sealed)
            try dst.write(contentsOf: sealed)
            written += Int64(sealed.count)
            consumed += Int64(want)
            index += 1
        }
        return written
    }

    /// Streams chunk DECRYPTION — or, with `objectKey == nil`, a plain byte copy
    /// (plaintext objects). Reads `cipherByteLimit` bytes from `src` one sealed
    /// slice at a time, appending plaintext to `dst`.
    /// Returns the number of PLAINTEXT bytes written to `dst`.
    static func decryptStream(
        from src: FileHandle,
        to dst: FileHandle,
        cipherByteLimit: Int64,
        objectKey: SymmetricKey?,
        startSliceIndex: Int,
        cipherHasher: inout SHA256?,
        plainHasher: inout SHA256?
    ) throws -> Int64 {
        var consumed: Int64 = 0
        var written: Int64 = 0
        var index = startSliceIndex
        while consumed < cipherByteLimit {
            let want = Int(min(Int64(sealedSliceSize), cipherByteLimit - consumed))
            guard let sealed = try src.read(upToCount: want), sealed.count == want else {
                throw CryptoError.testFailed // source shorter than recorded size
            }
            cipherHasher?.update(data: sealed)
            let piece: Data
            if let objectKey {
                piece = try decryptSlice(sealed, objectKey: objectKey, index: index)
            } else {
                piece = sealed
            }
            plainHasher?.update(data: piece)
            try dst.write(contentsOf: piece)
            written += Int64(piece.count)
            consumed += Int64(sealed.count)
            index += 1
        }
        return written
    }

    // MARK: - Password-derived link key

    /// Derives a 256-bit key from a user-supplied share password using PBKDF2-SHA256 (100k iterations).
    static func deriveLinkKey(from password: String, salt: Data) -> SymmetricKey {
        let pw = Array(password.utf8)
        let sl = [UInt8](salt)
        var derived = [UInt8](repeating: 0, count: 32)
        CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            pw, pw.count,
            sl, sl.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            100_000,
            &derived, derived.count
        )
        return SymmetricKey(data: Data(derived))
    }
    
    // MARK: - Password-derived vault key (v2)

    /// Derives the vault master key from the user's PIN/password plus a per-vault
    /// random salt (PBKDF2-SHA256, 600k iterations — OWASP's recommended cost for
    /// password hashing). Derived identically on every device, so the same PIN
    /// recovers the vault key anywhere; the salt is public (its job is uniqueness,
    /// not secrecy) and rides inside the channel's key record.
    static func passwordKey(from password: String, salt: Data) -> SymmetricKey {
        let pw = Array(password.utf8)
        let sl = [UInt8](salt)
        var derived = [UInt8](repeating: 0, count: 32)
        CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            pw, pw.count,
            sl, sl.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            600_000,
            &derived, derived.count
        )
        return SymmetricKey(data: Data(derived))
    }

    // MARK: - PIN recovery key (v1, legacy)

    /// Derives a deterministic key from the vault PIN (PBKDF2-SHA256) using the v1
    /// fixed salt and iteration count. Kept EXACTLY as-is so legacy `cascade:vaultkey:`
    /// blobs posted by older builds can still be unwrapped during migration.
    static func recoveryKey(from pin: String) -> SymmetricKey {
        let password = Array(pin.utf8)
        let salt = Array("cascade-recovery-v1".utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            password, password.count,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            150_000,
            &derived, derived.count
        )
        return SymmetricKey(data: Data(derived))
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
