import Foundation

// Cascade caption codec.
///
// Cascade payload caption shares ONE prefix (`xcloud:`) followed by JSON
/// that self-describes its `kind` — so a vault chunk, a share-channel copy and a
/// forwarded message are all the SAME message type, and any reader can parse any
/// copy:
///   - `"chunk"`  — one byte-chunk of a file (vault + share channels)
///   - `"object"` — a file/folder's metadata record (vault channel)
///
/// Legacy formats are still read forever (captions on already-sent messages can't
/// be rewritten): `xcloud:v1:` (chunk/object, no kind) and `xcloud:share:v1:`
/// (share chunk). Writers use the unified format only.
enum ChunkCaption {
    static let unifiedPrefix = "xcloud:"
    static let legacyVaultPrefix = "xcloud:v1:"
    static let legacySharePrefix = "xcloud:share:v1:"
    static let kindChunk = "chunk"
    static let kindObject = "object"
    static let kindThumb = "thumb"

    struct Meta: Equatable, Sendable {
        var kind: String? = nil        // unified only; legacy captions carry no kind
        var id: String
        var name: String
        var size: Int64
        var mime: String
        var parentID: String? = nil
        var isPrivate: Bool = false
        var isFolder: Bool = false
        var trashed: Bool = false
        var isFavorite: Bool = false
        var index: Int = 0
        var totalChunks: Int = 1
        var wrappedKey: String = ""
        var chunkSize: Int64? = nil
        var plainHash: String? = nil
        var cipherHash: String? = nil
        var rootHash: String? = nil

        /// Chunk size to assume when the caption doesn't carry one (legacy
        /// uploads predate the chunkSize field). Mirrors ChunkPlanner's automatic
        /// profile so derived per-chunk sizes match the original boundaries.
        var effectiveChunkSize: Int64 {
            chunkSize ?? ChunkPlanner.chunkSize(
                for: size,
                profile: .automatic,
                mime: mime
            )
        }
    }

    /// Encodes a unified chunk/object caption: `xcloud:{"kind":...,"v":1,...}`.
    static func encode(_ meta: Meta, kind: String) -> String? {
        var dict: [String: Any] = [
            "kind": kind,
            "v": 1,
            "id": meta.id,
            "name": meta.name,
            "size": meta.size,
            "mime": meta.mime,
            "parentID": meta.parentID ?? "",
            "isPrivate": meta.isPrivate,
            "isFolder": meta.isFolder,
            "trashed": meta.trashed,
            "isFavorite": meta.isFavorite,
            "index": meta.index,
            "totalChunks": meta.totalChunks,
            "wrappedKey": meta.wrappedKey
        ]
        if let chunkSize = meta.chunkSize { dict["chunkSize"] = chunkSize }
        if let plainHash = meta.plainHash { dict["plainHash"] = plainHash }
        if let cipherHash = meta.cipherHash { dict["cipherHash"] = cipherHash }
        if let rootHash = meta.rootHash { dict["rootHash"] = rootHash }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return unifiedPrefix + json
    }

    // Cascade caption — unified (`xcloud:`), legacy vault
    /// (`xcloud:v1:`) or legacy share (`xcloud:share:v1:`) — into normalized
    // Cascade payloads.
    static func parse(_ caption: String) -> Meta? {
        let json: String
        if caption.hasPrefix(legacySharePrefix) {
            json = String(caption.dropFirst(legacySharePrefix.count))
        } else if caption.hasPrefix(legacyVaultPrefix) {
            json = String(caption.dropFirst(legacyVaultPrefix.count))
        } else if caption.hasPrefix(unifiedPrefix) {
            json = String(caption.dropFirst(unifiedPrefix.count))
        } else {
            return nil
        }
        guard let data = json.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = dict["id"] as? String,
              let size = (dict["size"] as? Int64) ?? (dict["size"] as? Int).map(Int64.init) else {
            return nil
        }
        let name = dict["name"] as? String ?? ""
        let mime = dict["mime"] as? String ?? "application/octet-stream"
        // Legacy captions predate the index field (folder metadata messages
        // carry no index at all) — 0 is the correct fallback for those.
        let index = dict["index"] as? Int ?? 0
        let chunkSize = (dict["chunkSize"] as? Int64) ?? (dict["chunkSize"] as? Int).map(Int64.init)
        return Meta(
            kind: dict["kind"] as? String,
            id: id,
            name: name,
            size: size,
            mime: mime,
            parentID: (dict["parentID"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            isPrivate: dict["isPrivate"] as? Bool ?? false,
            isFolder: dict["isFolder"] as? Bool ?? false,
            trashed: dict["trashed"] as? Bool ?? false,
            isFavorite: dict["isFavorite"] as? Bool ?? false,
            index: index,
            totalChunks: dict["totalChunks"] as? Int ?? 1,
            wrappedKey: dict["wrappedKey"] as? String ?? "",
            chunkSize: chunkSize,
            plainHash: dict["plainHash"] as? String,
            cipherHash: dict["cipherHash"] as? String,
            rootHash: dict["rootHash"] as? String
        )
    }

    /// True when a caption identifies a file-chunk message (vault or share copy) —
    /// used by VaultRepair's orphan purge. Legacy vault captions are always
    /// treated as chunks (they predate the kind field and could be either);
    /// unified captions must say `"chunk"` — kind `"object"` is metadata and is
    /// never a purge candidate.
    static func isChunkCaption(_ caption: String) -> Bool {
        if caption.hasPrefix(legacySharePrefix) || caption.hasPrefix(legacyVaultPrefix) {
            return true
        }
        guard let meta = parse(caption) else { return false }
        return meta.kind == kindChunk
    }

    // MARK: - Thumbnail sidecar captions

    /// Caption for an encrypted thumbnail sidecar document: `xcloud:{"kind":"thumb","v":1,"id":...}`.
    /// Deliberately carries ONLY the object id — the bytes themselves are AES-GCM
    /// encrypted with the object key, and the id is the same random UUID the
    /// chunk captions already expose. Minimal metadata keeps the channel clean.
    static func thumbCaption(objectID: String) -> String? {
        let dict: [String: Any] = [
            "kind": kindThumb,
            "v": 1,
            "id": objectID,
            // parse() requires a size for any unified caption — the sidecar
            // size is unknown at encode time, so 0 (never read for thumbs).
            "size": 0
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return unifiedPrefix + json
    }

    /// True when a caption identifies a thumbnail sidecar document.
    static func isThumbCaption(_ caption: String) -> Bool {
        guard let meta = parse(caption) else { return false }
        return meta.kind == kindThumb
    }
}