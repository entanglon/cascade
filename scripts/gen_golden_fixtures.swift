// gen_golden_fixtures.swift — Cross-platform golden vector generator for Cascade.
//
// Compiled TOGETHER with the real production sources so every crypto byte comes
// from the genuine CryptoKit / Codable code path; only keys, nonces, dates and
// patterns are fixed for determinism:
//
//   /Library/Developer/CommandLineTools/usr/bin/swiftc -o /tmp/genfix \
//     scripts/gen_golden_fixtures.swift \
//     Crypto/CryptoEngine.swift Engine/ChunkPlanner.swift Engine/ChunkCaption.swift \
//     -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
//   /tmp/genfix  # writes to the Android test resources by default
//
// NOTE: works with the standalone Command Line Tools toolchain — the Xcode
// license gate does NOT apply to this path (Xcode.app shims do gate it).
//
// All "keys" here are fixed test patterns (0x00..0x1f etc.), never real keys.

import Foundation
import CryptoKit

// MARK: - Deterministic material

let objectKeyBytes = Data((0..<32).map { UInt8($0) })                    // 00..1f
let secondObjectKeyBytes = Data((0..<32).map { UInt8(0x80 + UInt8($0)) })// 80..9f
let vaultKeyBytes = Data((0..<32).map { UInt8(0x20 + UInt8($0)) })       // 20..3f
let shareKeyBytes = Data((0..<32).map { UInt8(0x40 + UInt8($0)) })       // 40..5f (stands in for a device master key)
let linkKeyBytes = Data((0..<32).map { UInt8(0x60 + UInt8($0)) })        // 60..7f
let obfKeyBytes = Data(SHA256.hash(data: Data("cascade-golden-obfuscation-key".utf8)))

func nonce12(_ start: UInt8) -> Data { Data((0..<12).map { UInt8(start &+ UInt8($0)) }) }
let nA = nonce12(0xa0), nB = nonce12(0xb0), nC = nonce12(0xc0)
let nD = nonce12(0xd0), nE = nonce12(0xe0), nF = nonce12(0xf0)

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
func sha256hex(_ d: Data) -> String { hex(Data(SHA256.hash(data: d))) }
func pattern(_ size: Int, offset: Int = 0) -> Data {
    Data((0..<size).map { UInt8(($0 + offset) & 0xff) })
}

/// AES-GCM CryptoKit combined box (nonce || ct || tag) with a FIXED nonce —
/// identical to CryptoEngine.encryptSlice/wrap except the nonce is injected.
func sealFixed(_ plain: Data, key: Data, nonce: Data) -> Data {
    let box = try! AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce))
    return box.combined!
}

func sliceKeyBytes(_ objectKey: Data, index: Int) -> Data {
    let k = CryptoEngine.sliceKey(objectKey: SymmetricKey(data: objectKey), index: index)
    return k.withUnsafeBytes { Data($0) }
}

let b64: (Data) -> String = { $0.base64EncodedString() }
func b64urlDecode(_ s: String) -> Data? {
    var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while t.count % 4 != 0 { t.append("=") }
    return Data(base64Encoded: t)
}
func b64url(_ d: Data) -> String {
    d.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

// MARK: - 1. Chunk planner (real ChunkPlanner)

struct PlanCaseEnc {
    let fileSize: Int64
    let chunkSize: Int64?
}
func planCaseDict(_ c: PlanCaseEnc) -> [String: Any] {
    let plan = ChunkPlanner.plan(fileSize: c.fileSize, chunkSize: c.chunkSize)
    var d: [String: Any] = [
        "fileSize": c.fileSize,
        "expectedChunkSize": plan.chunkSize,
        "expectedCount": plan.count,
        "expectedItems": plan.items.map { ["index": $0.index, "offset": $0.offset, "size": $0.size] },
    ]
    if let cs = c.chunkSize { d["chunkSizeOverride"] = cs }
    return d
}
let plannerCases = [
    PlanCaseEnc(fileSize: 0, chunkSize: nil),
    PlanCaseEnc(fileSize: 1_048_576, chunkSize: nil),
    PlanCaseEnc(fileSize: 1_900 * 1_048_576 + 123_456, chunkSize: nil),
    PlanCaseEnc(fileSize: 50 * 1_024 * 1_048_576, chunkSize: nil),
    PlanCaseEnc(fileSize: 268_435_456, chunkSize: 134_217_728), // legacy stored-size override
].map(planCaseDict)

// MARK: - 2. HKDF slice keys (real CryptoEngine.sliceKey)

let hkdfCases: [[String: Any]] = [0, 1, 2, 255, 700].map { i in
    ["index": i, "keyHex": hex(sliceKeyBytes(objectKeyBytes, index: i))]
}

// MARK: - 3. AES-GCM slices + chunk (real keys/derivation, fixed nonces)

let plain64 = pattern(64)
let plain700 = pattern(700, offset: 9)
let plain1MiB = pattern(1_048_576)
let chunkPlain = pattern(2_111_497) // 2 MiB + 11,497 → 3 slices
let chunkPlainSHA = sha256hex(chunkPlain)

func sliceDict(name: String, plain: Data, index: Int, nonce: Data, fullHex: Bool) -> [String: Any] {
    let key = sliceKeyBytes(objectKeyBytes, index: index)
    let sealed = sealFixed(plain, key: key, nonce: nonce)
    // Self-check: the production decrypt path accepts the fixed-nonce box.
    assert((try? CryptoEngine.decryptSlice(sealed, objectKey: SymmetricKey(data: objectKeyBytes), index: index)) == plain,
           "slice self-check failed: \(name)")
    var d: [String: Any] = [
        "name": name, "index": index,
        "size": plain.count,
        "plainSha256": sha256hex(plain),
        "sliceKeyHex": hex(key),
        "nonceHex": hex(nonce),
        "sealedSha256": sha256hex(sealed),
        "sealedSize": sealed.count,
        "sealedFirst48Hex": hex(sealed.prefix(48)),
        "sealedLast48Hex": hex(sealed.suffix(48)),
    ]
    if fullHex { d["sealedHex"] = hex(sealed) }
    return d
}

let sliceCases = [
    sliceDict(name: "small-64B", plain: plain64, index: 0, nonce: nA, fullHex: true),
    sliceDict(name: "small-700B", plain: plain700, index: 5, nonce: nC, fullHex: true),
    sliceDict(name: "boundary-1MiB", plain: plain1MiB, index: 1, nonce: nB, fullHex: false),
]

// Multi-slice chunk: per-slice nonces ride in the fixture so Kotlin can
// reconstruct the exact sealed bytes and round-trip decryptChunk.
let chunkNonces = [nA, nB, nC]
var chunkSealed = Data()
for (i, nonce) in chunkNonces.enumerated() {
    let start = i * CryptoEngine.sliceSize
    let end = min(start + CryptoEngine.sliceSize, chunkPlain.count)
    chunkSealed.append(sealFixed(chunkPlain.subdata(in: start..<end),
                                 key: sliceKeyBytes(objectKeyBytes, index: 7 + i), nonce: nonce))
}
let chunkCase: [String: Any] = [
    "startSliceIndex": 7,
    "size": chunkPlain.count,
    "plainSha256": chunkPlainSHA,
    "noncesHex": chunkNonces.map(hex),
    "sealedSize": chunkSealed.count,
    "sealedSha256": sha256hex(chunkSealed),
    "sealedFirst64Hex": hex(chunkSealed.prefix(64)),
    "sealedLast64Hex": hex(chunkSealed.suffix(64)),
]

// MARK: - 4. Key wrapping + PBKDF2 (real CryptoEngine derivations, fixed nonces)

let wrapCases: [[String: Any]] = [
    ["name": "object-under-vault", "wrappedB64": b64(sealFixed(objectKeyBytes, key: vaultKeyBytes, nonce: nD)),
     "wrappingKeyHex": hex(vaultKeyBytes), "expectedKeyHex": hex(objectKeyBytes)],
    ["name": "vault-under-master", "wrappedB64": b64(sealFixed(vaultKeyBytes, key: shareKeyBytes, nonce: nE)),
     "wrappingKeyHex": hex(shareKeyBytes), "expectedKeyHex": hex(vaultKeyBytes)],
]

let saltLink = Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0x00, 0x7f])
let pbkdf2Cases: [[String: Any]] = [
    ["name": "link-600k", "password": "cascade-test-password", "saltHex": hex(saltLink),
     "iterations": 600_000, "keyHex": hex(CryptoEngine.deriveLinkKey(from: "cascade-test-password", salt: saltLink).withUnsafeBytes { Data($0) })],
    ["name": "link-legacy-100k", "password": "cascade-test-password", "saltHex": hex(saltLink),
     "iterations": 100_000, "keyHex": hex(CryptoEngine.deriveLegacyLinkKey(from: "cascade-test-password", salt: saltLink).withUnsafeBytes { Data($0) })],
    ["name": "v1-recovery-150k", "password": "1234", "saltHex": hex(Data("cascade-recovery-v1".utf8)),
     "iterations": 150_000, "keyHex": hex(CryptoEngine.recoveryKey(from: "1234").withUnsafeBytes { Data($0) })],
]

// MARK: - 5. Captions (real ChunkCaption.encode)

func captionMetaDict(_ m: ChunkCaption.Meta, kind: String) -> [String: Any] {
    var d: [String: Any] = [
        "kind": kind,
        "id": m.id, "name": m.name, "size": m.size, "mime": m.mime,
        "parentID": m.parentID ?? "", "isPrivate": m.isPrivate, "isFolder": m.isFolder,
        "trashed": m.trashed, "isFavorite": m.isFavorite, "index": m.index,
        "totalChunks": m.totalChunks, "wrappedKey": m.wrappedKey,
    ]
    if let v = m.chunkSize { d["chunkSize"] = v }
    if let v = m.plainHash { d["plainHash"] = v }
    if let v = m.cipherHash { d["cipherHash"] = v }
    if let v = m.rootHash { d["rootHash"] = v }
    return d
}
func captionCase(_ m0: ChunkCaption.Meta, kind: String) -> [String: Any] {
    var m = m0
    m.kind = kind // parse() reads kind back from the JSON; compare like-for-like
    let expected = ChunkCaption.encode(m, kind: kind)!
    // Self-check: production parse round-trips the production output.
    assert(ChunkCaption.parse(expected) == m, "caption round-trip failed for \(m.name)")
    return ["meta": captionMetaDict(m, kind: kind), "expected": expected]
}

let wrappedObjectUnderVault = (try? CryptoEngine.wrap(SymmetricKey(data: objectKeyBytes), with: SymmetricKey(data: vaultKeyBytes))) ?? Data()
let captionCases = [
    captionCase(
        ChunkCaption.Meta(
            id: "11111111-2222-3333-4444-555555555555", name: "Video.mkv", size: 5_368_709_120,
            mime: "video/x-matroska", parentID: "folder-root-01", isPrivate: true, isFavorite: true,
            index: 2, totalChunks: 3,
            wrappedKey: wrappedObjectUnderVault.base64EncodedString(),
            chunkSize: 1_992_294_400,
            plainHash: sha256hex(pattern(1024)), cipherHash: sha256hex(pattern(2048)),
            rootHash: sha256hex(Data("root".utf8))
        ), kind: ChunkCaption.kindChunk),
    captionCase(
        ChunkCaption.Meta(id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", name: "Photos", size: 0, mime: ""),
        kind: ChunkCaption.kindObject),
    captionCase(
        ChunkCaption.Meta(id: "c0ffee00-1234-5678-9abc-def012345678", name: "résumé — final ✓.pdf",
                          size: 123_456, mime: "application/pdf", index: 0, totalChunks: 1),
        kind: ChunkCaption.kindChunk),
]

let sidecarCases: [[String: Any]] = [
    ["kind": ChunkCaption.kindThumb, "objectID": "11111111-2222-3333-4444-555555555555",
     "expected": ChunkCaption.thumbCaption(objectID: "11111111-2222-3333-4444-555555555555")!],
    ["kind": ChunkCaption.kindSub, "objectID": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
     "expected": ChunkCaption.subCaption(objectID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!],
]

let captionParseCases: [[String: Any]] = [
    ["raw": "cascade:{\"id\":\"legacy-0001\",\"size\":42,\"name\":\"old.bin\"}", "expectOk": true],
    ["raw": "cascade:{\"cipherHash\":\"ab\",\"chunkSize\":1024,\"id\":\"u1\",\"isFavorite\":true,\"index\":2,\"kind\":\"chunk\",\"mime\":\"text/plain\",\"name\":\"a.txt\",\"rootHash\":\"cd\",\"size\":9,\"totalChunks\":4,\"unknownFutureKey\":[1,2],\"wrappedKey\":\"AA==\"}", "expectOk": true],
    ["raw": "not-a-cascade-caption", "expectOk": false],
    ["raw": "cascade:{broken", "expectOk": false],
]

// MARK: - 6. Vault key record v2 (real Codable field order: salt, passwordSeal, deviceSeal, deviceID)

struct VaultKeyRecordMirror: Codable {
    var salt: Data
    var passwordSeal: Data
    var deviceSeal: Data
    var deviceID: String
}
let vaultSalt = Data([0x0f, 0x1e, 0x2d, 0x3c, 0x4b, 0x5a, 0x69, 0x78, 0x87, 0x96, 0xa5, 0xb4, 0xc3, 0xd2, 0xe1, 0xf0])
let pin = "cascade-test-pin-2026"
let pinDerivedKey = CryptoEngine.passwordKey(from: pin, salt: vaultSalt).withUnsafeBytes { Data($0) }
let passwordSeal = sealFixed(vaultKeyBytes, key: pinDerivedKey, nonce: nD)
let deviceSeal = sealFixed(vaultKeyBytes, key: shareKeyBytes, nonce: nE)
let vaultRecord = VaultKeyRecordMirror(salt: vaultSalt, passwordSeal: passwordSeal, deviceSeal: deviceSeal, deviceID: "golden-mac-01")
let vaultRecordJSON = try! JSONEncoder().encode(vaultRecord)
let vaultRecordCaption = "cascade:vaultkey:v2:" + vaultRecordJSON.base64EncodedString()
// Self-check: JSON decodes back to the record.
assert((try? JSONDecoder().decode(VaultKeyRecordMirror.self, from: vaultRecordJSON))!.passwordSeal == passwordSeal)

// MARK: - 7. Share links (real URLComponents builder + Codable manifest, fixed crypto)

struct ManifestEntry: Codable {
    var n: String
    var m: String
    var w: String?
    var p: String?
    var th: Int64?
}
func encodeFiles(_ files: [ManifestEntry]) -> String { b64url(try! JSONEncoder().encode(files)) }

func makeLink(id: String, ch: Int64, inv: String, key: String, name: String, exp: Int64,
              salt: String = "", th: Int64? = nil, f: String? = nil, m: String, w: String = "") -> String {
    var comps = URLComponents()
    comps.scheme = "cascade"
    comps.host = "share"
    var items = [
        URLQueryItem(name: "v", value: "2"),
        URLQueryItem(name: "id", value: id),
        URLQueryItem(name: "ch", value: String(ch)),
        URLQueryItem(name: "inv", value: inv),
        URLQueryItem(name: "key", value: key),
        URLQueryItem(name: "name", value: name),
        URLQueryItem(name: "exp", value: String(exp)),
    ]
    if !salt.isEmpty { items.append(URLQueryItem(name: "salt", value: salt)) }
    if let th { items.append(URLQueryItem(name: "th", value: String(th))) }
    if let f { items.append(URLQueryItem(name: "f", value: f)) }
    items.append(URLQueryItem(name: "m", value: m))
    if !w.isEmpty { items.append(URLQueryItem(name: "w", value: w)) }
    comps.queryItems = items
    return comps.url!.absoluteString
}

let manifestFiles = [
    ManifestEntry(n: "Q4 Report + notes.pdf", m: "1001,1002",
                  w: b64(sealFixed(objectKeyBytes, key: linkKeyBytes, nonce: nA)), p: nil, th: 1004),
    ManifestEntry(n: "photo éàü — ünïcode.png", m: "1003",
                  w: b64(sealFixed(secondObjectKeyBytes, key: linkKeyBytes, nonce: nB)), p: "sub/dir", th: nil),
]
let manifestEncoded = encodeFiles(manifestFiles)
// Self-check: manifest decodes back.
assert(try! JSONDecoder().decode([ManifestEntry].self, from: b64urlDecode(manifestEncoded)!).count == 2)

let plainGroupLink = makeLink(
    id: "A1B2C3D4-1111-2222-3333-444455556666", ch: 1_234_567_890_123,
    inv: "https://t.me/+AbCdEf-GhIjKlMnOp", key: b64(shareKeyBytes),
    name: "Q4 Report + notes.pdf", exp: 0, th: 1004, f: manifestEncoded, m: "1001,1002,1003",
    w: b64(sealFixed(objectKeyBytes, key: linkKeyBytes, nonce: nA)))

let sentinelKey = Data((0..<32).map { UInt8(0xee &+ UInt8($0)) })
// Password links seal the sentinel under the PBKDF2-derived link key —
// exactly what forwardShare does (ShareEngine.swift ~line 600).
let derivedLinkKey = CryptoEngine.deriveLinkKey(from: "cascade-test-password", salt: saltLink).withUnsafeBytes { Data($0) }
let plainProtectedLink = makeLink(
    id: "F0E1D2C3-9999-8888-7777-666655554444", ch: 987_654_321_098,
    inv: "https://t.me/+Zq9wXy8vRuT", key: "",
    name: "Backup Archive 2026.zip", exp: 1_800_000_000,
    salt: b64(saltLink), th: 4096, m: "2001,2002,2003",
    w: b64(sealFixed(sentinelKey, key: derivedLinkKey, nonce: nF)))

// Obfuscated transport: cascade://share# + base64url(key(32) || AES-GCM-combined(link))
let obfBlob = obfKeyBytes + sealFixed(Data(plainProtectedLink.utf8), key: obfKeyBytes, nonce: nC)
let obfuscatedLink = "cascade://share#" + b64url(obfBlob)
// Self-check: reproduce ShareEngine.deobfuscate exactly.
do {
    let b = b64urlDecode(String(obfuscatedLink.dropFirst("cascade://share#".count)))!
    let k = SymmetricKey(data: b.prefix(32))
    let opened = try AES.GCM.open(try AES.GCM.SealedBox(combined: b.dropFirst(32)), using: k)
    assert(String(data: opened, encoding: .utf8)! == plainProtectedLink, "deobfuscate self-check failed")
}

// MARK: - 8. Catalog snapshot (real Codable, declaration-order keys + real Apple zlib)

struct SnapObjectRecord: Codable {
    var id: String; var vaultID: String; var name: String; var size: Int64; var mime: String; var state: String
    var rootHash: String?; var wrappedKey: Data?
    var createdAt: Date; var modifiedAt: Date
    var isFavorite: Bool = false; var trashed: Bool = false; var parentID: String? = nil
    var isFolder: Bool = false; var isPrivate: Bool = false; var sourcePath: String? = nil
    var chunkSize: Int64? = nil; var isArchived: Bool = false; var isInLibrary: Bool = false
    var coverObjectID: String? = nil; var thumbMessageID: Int64? = nil; var tombstoneAt: Date? = nil
    var subtitleSidecars: String? = nil; var isPinned: Bool = false
}
struct SnapChunkRecord: Codable {
    var id: String; var objectID: String; var index: Int; var size: Int64
    var plainHash: String?; var cipherHash: String?; var state: String
    var messageID: Int64?; var fileUniqueID: String?; var channelID: Int64?; var createdAt: Date
}
struct SnapPayload: Codable {
    var version: Int
    var objects: [SnapObjectRecord]
    var chunks: [SnapChunkRecord]
    var baseMessageID: Int64? = nil
    var nonce: String? = nil
}

let refDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
let refDate2 = Date(timeIntervalSinceReferenceDate: 800_000_500)
let snapPayload = SnapPayload(
    version: 1,
    objects: [
        SnapObjectRecord(
            id: "obj-0001", vaultID: "vault-0001", name: "Report.pdf", size: 1_048_576, mime: "application/pdf",
            state: "ready", rootHash: sha256hex(pattern(1024)),
            wrappedKey: wrappedObjectUnderVault,
            createdAt: refDate, modifiedAt: refDate, isFavorite: true, chunkSize: 1_992_294_400, thumbMessageID: 5_000),
        SnapObjectRecord(
            id: "obj-0002", vaultID: "vault-0001", name: "Folder", size: 0, mime: "", state: "ready",
            createdAt: refDate, modifiedAt: refDate2, isFolder: true),
        SnapObjectRecord(
            id: "obj-0003", vaultID: "vault-0001", name: "Deleted.txt", size: 12, mime: "text/plain",
            state: "ready", createdAt: refDate, modifiedAt: refDate2, trashed: false,
            tombstoneAt: Date(timeIntervalSinceReferenceDate: 799_000_000), isPinned: false),
    ],
    chunks: [
        SnapChunkRecord(id: "chk-0001", objectID: "obj-0001", index: 0, size: 1_048_576,
                        plainHash: sha256hex(pattern(1024)), cipherHash: sha256hex(pattern(2048)),
                        state: "ready", messageID: 4_999, fileUniqueID: "fu-1", channelID: 1_234_567_890_123, createdAt: refDate),
    ],
    baseMessageID: 12_345, nonce: "snapshot-nonce-0001")

func zlibWrap(_ deflateData: Data, plaintext: Data) -> Data {
    // 0x78 0x9c header + raw deflate + big-endian Adler-32 computed over the
    // PLAINTEXT (zlib spec) — a standard zlib stream, i.e. exactly what Java's
    // default Deflater emits. Apple's NSData .zlib does NOT add this wrapper.
    var out = Data([0x78, 0x9c])
    out.append(deflateData)
    var a: UInt32 = 1, b: UInt32 = 0
    for byte in plaintext {
        a = (a &+ UInt32(byte)) % 65521
        b = (b &+ a) % 65521
    }
    let adler = (b << 16) | a
    out.append(withUnsafeBytes(of: adler.bigEndian) { Data($0) })
    return out
}
let snapJSON = try! JSONEncoder().encode(snapPayload)
let snapZlib = try (snapJSON as NSData).compressed(using: .zlib) as Data
let snapZlibWrapped = zlibWrap(snapZlib, plaintext: snapJSON) // Java-default hazard pin
// Self-check: header + trailer present.
assert(snapZlibWrapped.prefix(2) == Data([0x78, 0x9c]))
assert(snapZlibWrapped.count == snapZlib.count + 6)
// Self-check: Apple zlib round trip.
let snapZlibRoundTrip = (try? (snapZlib as NSData).decompressed(using: .zlib) as Data) ?? Data()
assert(snapZlibRoundTrip == snapJSON, "zlib self-check failed")

// MARK: - Emit

let fixture: [String: Any] = [
    "meta": [
        "generator": "scripts/gen_golden_fixtures.swift (Command Line Tools Swift 6.4)",
        "sourceCommit": "a1b5951",
        "generatedAt": "2026-09-15",
        "note": "All keys are fixed test patterns (never real keys). AES-GCM boxes use CryptoKit with the nonce embedded in the fixture; slice keys and PBKDF2 come from the real CryptoEngine. Dates in snapshot JSON are Swift reference-date seconds (2001-01-01 UTC).",
    ],
    "chunkPlanner": ["cases": plannerCases],
    "hkdfSliceKeys": [
        "objectKeyHex": hex(objectKeyBytes),
        "salt": "cascade-salt-v1",
        "infoPrefix": "cascade-slice-v1:",
        "cases": hkdfCases,
    ],
    "aesGcm": [
        "objectKeyHex": hex(objectKeyBytes),
        "secondObjectKeyHex": hex(secondObjectKeyBytes),
        "vaultKeyHex": hex(vaultKeyBytes),
        "shareKeyHex": hex(shareKeyBytes),
        "linkKeyHex": hex(linkKeyBytes),
        "slices": sliceCases,
        "chunk": chunkCase,
        "wraps": wrapCases,
        "pbkdf2": pbkdf2Cases,
    ],
    "captions": [
        "encode": captionCases,
        "sidecars": sidecarCases,
        "parse": captionParseCases,
    ],
    "vaultKeyRecord": [
        "prefix": "cascade:vaultkey:v2:",
        "pin": pin,
        "derivedKeyHex": hex(pinDerivedKey),
        "plainJSON": String(data: vaultRecordJSON, encoding: .utf8)!,
        "expectedCaption": vaultRecordCaption,
    ],
    "shareLinks": [
        "plainGroupLink": plainGroupLink,
        "plainProtectedLink": plainProtectedLink,
        "manifest": [
            "encodedB64url": manifestEncoded,
            "files": manifestFiles.map { f -> [String: Any] in
                var d: [String: Any] = ["n": f.n, "m": f.m]
                if let w = f.w { d["w"] = w }
                if let p = f.p { d["p"] = p }
                if let th = f.th { d["th"] = th }
                return d
            },
        ],
        "obfuscated": [
            "plain": plainProtectedLink,
            "keyHex": hex(obfKeyBytes),
            "nonceHex": hex(nC),
            "blobB64url": b64url(obfBlob),
            "obfuscatedLink": obfuscatedLink,
        ],
    ],
    "snapshot": [
        "plainJSON": String(data: snapJSON, encoding: .utf8)!,
        "zlibHex": hex(snapZlib),
        "zlibB64": b64(snapZlib),
        "zlibWrappedB64": b64(snapZlibWrapped),
        "dateNote": "createdAt/modifiedAt/tombstoneAt are Double seconds since 2001-01-01 00:00:00 UTC (Swift JSONEncoder default). Apple NSData .zlib emits RAW DEFLATE (no 0x789c wrapper); Kotlin consumers must Inflater(false), and Kotlin publishers must strip the Java wrapper or pin it like zlibWrappedB64.",
    ],
]

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : NSHomeDirectory() + "/AndroidStudioProjects/cascade/app/src/test/resources/golden_fixtures.json"

let outDir = (outPath as NSString).deletingLastPathComponent
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let outData = try JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted, .sortedKeys])
try outData.write(to: URL(fileURLWithPath: outPath))
print("Wrote \(outPath) (\(outData.count) bytes)")
print("Sections: chunkPlanner \(plannerCases.count) cases · hkdf \(hkdfCases.count) · slices \(sliceCases.count) · captions \(captionCases.count + sidecarCases.count + captionParseCases.count) · share links 3 · snapshot 1")
