import Foundation
import CryptoKit
import UniformTypeIdentifiers
import TDLibKit
import os

// Cascade users.
///
/// Sender: the file's vault chunk messages are FORWARDED (reference copies —
/// zero re-upload, any size) into a channel from the pool. PRIVATE shares each
/// take a dedicated pool channel (ids 1…5, one active share per channel) with a
/// one-use expiring invite — revoking deletes the whole channel, instant death.
/// PUBLIC shares (never expiring) live together in the persistent public
/// channel whose stored permanent invite every public link embeds. Private
/// files stay flag-only: sharing leaks nothing more than the file itself, so
/// private files can't be shared at all.
///
/// Recipient: opening the link joins the channel, reads the exact forwarded
/// messages the link names, forwards each into their OWN vault channel (Telegram
/// copies the document server-side — no re-upload), catalogs the file, and leaves.
///
/// Legacy shares (created before v22) used per-share disposable channels with
/// re-encrypted copies and `cascade:share:v1:` captions — still imported, forever.
enum ShareEngine {
    /// Legacy share-channel caption prefix (pre-v22 disposable channels).
    static let captionPrefix = "cascade:share:v1:"
    /// How long a private share lives (link expiry + server-side message TTL).
    /// Recipient has this window to open the link; after it, the share revokes
    /// itself and the channel copies are removed.
    static let defaultLifetime: TimeInterval = 24 * 3600
    /// v24: how many private links can be live at once — each takes a dedicated
    /// channel from the pool (ids 1…privatePoolSize). A pool-full share request
    /// is blocked with a clear error (never silently evicts an older share).
    static let privatePoolSize = 5

    /// Per-slot channel titles, so Telegram shows WHICH channel is which: the
    /// persistent public channel is "Cascade OC" (open channel — home of every
    /// everlasting public link), private pool slots are "Cascade PC1"…"Cascade
    /// PC5" (private channels — one expiring private link each). All of them
    /// are private Telegram channels; the difference is what they carry.
    static func poolChannelTitle(id: Int64, kind: ShareKind) -> String {
        if kind == .public { return "Cascade OC" }
        return "Cascade PC\(id)"
    }

    /// Short label drawn on the channel's profile photo (matches
    /// `poolChannelTitle`'s convention).
    static func poolAvatarLabel(id: Int64, kind: ShareKind) -> String {
        if kind == .public { return "OC" }
        return "PC\(id)"
    }

    /// Per-slot gradient hue so pool channels are distinguishable at a glance;
    /// the public channel gets its own family color.
    static func poolAvatarHue(id: Int64, kind: ShareKind) -> Double {
        if kind == .public { return 0.75 }
        return 0.02 + Double(id - 1) * 0.055
    }
    /// Row id of the persistent public channel in share_state.
    static let publicChannelRowID: Int64 = 100

    /// What kind of share a link is. Private: dedicated pool channel, expiring
    /// one-use invite, revocable (channel deleted). Public: the persistent public
    /// channel, permanent invite, never expires, revocable per-file.
    enum ShareKind: String, Sendable {
        case `private`
        case `public`
    }

    private static let logger = Logger(
        subsystem: "com.cascade.app",
        category: "share"
    )

    // MARK: - Link codec

    /// `cascade://share?v=2&id=…&ch=…&inv=…&key=…&name=…&exp=…&m=…&w=…[&f=…]`
    /// The `key` (the share secret) is what authorizes the file — the link IS the
    /// credential, so a one-time invite (memberLimit 1) keeps the channel closed
    /// to everyone except whoever holds the link.
    /// v2 (forward-based, reusable channel): `m` = comma-joined forwarded message
    /// IDs of the file's chunks in the share channel; `w` = the object key wrapped
    /// under the share key or link key, base64. GROUP shares (two or more files under
    /// one link) additionally carry `f` = a base64url JSON manifest naming every file
    /// with its own message IDs and wrapped keys. (`salt` only ever appears on
    /// links minted by old encrypted builds — password protection is retired.)
    struct ShareLink: Equatable, Sendable {
        var id: String
        var channelID: Int64
        var inviteLink: String
        var shareKey: String = ""      // base64 (empty if password protected)
        var fileName: String
        var expiry: Foundation.Date
        var messageIDs: [Int64] = []       // v2 (flat list; group shares flatten all files)
        var wrappedKeyB64: String = ""     // v2, single-file wrapped key
        var saltB64: String = ""           // v2, password PBKDF2 salt
        /// Per-file entries. Single-file links synthesize one entry on parse;
        /// group links carry one entry per shared file, each naming that file's
        /// forwarded chunk messages in the share channel.
        var files: [ShareFile] = []
        var thumbMessageID: Int64? = nil

        var isForwardBased: Bool { !files.isEmpty || !messageIDs.isEmpty }
        /// True when the link carries TWO OR MORE files shared together as a group.
        var isGroup: Bool { files.count > 1 }
        /// True when the link is sealed with a password.
        var isPasswordProtected: Bool { !saltB64.isEmpty }

        var urlString: String {
            var comps = URLComponents()
            comps.scheme = "cascade"
            comps.host = "share"
            var items = [
                URLQueryItem(name: "v", value: isForwardBased ? "2" : "1"),
                URLQueryItem(name: "id", value: id),
                URLQueryItem(name: "ch", value: String(channelID)),
                URLQueryItem(name: "inv", value: inviteLink),
                URLQueryItem(name: "key", value: shareKey),
                URLQueryItem(name: "name", value: fileName),
                // exp = 0 encodes a never-expiring (public) link.
                URLQueryItem(name: "exp", value: expiry == .distantFuture
                    ? "0"
                    : String(Int(expiry.timeIntervalSince1970)))
            ]
            if isForwardBased {
                if !saltB64.isEmpty {
                    items.append(URLQueryItem(name: "salt", value: saltB64))
                }
                if let th = thumbMessageID {
                    items.append(URLQueryItem(name: "th", value: String(th)))
                }
                if isGroup {
                    // Group share: `f` carries the per-file manifest; `m` stays the
                    // flat list so self-open detection and expiry cleanup read
                    // messageIDs unchanged.
                    items.append(URLQueryItem(name: "f", value: Self.encodeFiles(files)))
                    items.append(URLQueryItem(name: "m", value: files.flatMap(\.messageIDs).map(String.init).joined(separator: ",")))
                    if !wrappedKeyB64.isEmpty {
                        items.append(URLQueryItem(name: "w", value: wrappedKeyB64))
                    }
                } else {
                    items.append(URLQueryItem(name: "m", value: messageIDs.map(String.init).joined(separator: ",")))
                    items.append(URLQueryItem(name: "w", value: wrappedKeyB64))
                }
            }
            comps.queryItems = items
            return comps.url?.absoluteString ?? ""
        }

        static func parse(_ raw: String) -> ShareLink? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Obfuscated form: `cascade://share#<base64url blob>`. Decrypt it back
            // to the plaintext link and parse that — the transported form carries no
            // visible invite link, channel id or key material.
            if trimmed.hasPrefix("cascade://share#") {
                guard let plain = try? ShareEngine.deobfuscate(trimmed) else { return nil }
                return parse(plain)
            }
            guard let comps = URLComponents(string: trimmed),
                  comps.scheme == "cascade", comps.host == "share" else { return nil }
            let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            })
            guard let id = q["id"],
                  let chStr = q["ch"], let channelID = Int64(chStr),
                  let invite = q["inv"], !invite.isEmpty,
                  let expStr = q["exp"], let exp = Int64(expStr) else { return nil }
            let version = q["v"] ?? "1"
            let key = q["key"] ?? ""
            let saltB64 = q["salt"] ?? ""
            var messageIDs: [Int64] = []
            var wrappedKeyB64 = ""
            var files: [ShareFile] = []
            let parsedThumbMID = q["th"].flatMap { Int64($0) }
            if version == "2" {
                if let manifest = q["f"], !manifest.isEmpty {
                    // Group share: `f` names each file with its own chunk message
                    // IDs. A malformed manifest makes the whole link invalid — a
                    // group link must never degrade into a single-file import.
                    guard let decoded = decodeFiles(manifest),
                          decoded.count > 1,
                          !decoded.flatMap(\.messageIDs).isEmpty else { return nil }
                    files = decoded
                    messageIDs = decoded.flatMap(\.messageIDs)
                    wrappedKeyB64 = q["w"] ?? ""
                } else {
                    // Forward-based links: the message IDs name the chunks
                    messageIDs = (q["m"] ?? "").split(separator: ",").compactMap { Int64($0) }
                    guard !messageIDs.isEmpty else { return nil }
                    wrappedKeyB64 = q["w"] ?? ""
                    // Single-file links synthesize one entry so the import path can
                    // treat every forward-based link uniformly.
                    files = [ShareFile(name: q["name"] ?? "Shared file", messageIDs: messageIDs, wrappedKey: wrappedKeyB64.isEmpty ? nil : wrappedKeyB64, path: nil, thumbMessageID: parsedThumbMID)]
                }
            } else {
                // Legacy disposable-channel links always carry the share secret.
                guard !key.isEmpty else { return nil }
            }
            return ShareLink(
                id: id,
                channelID: channelID,
                inviteLink: invite,
                shareKey: key,
                fileName: q["name"] ?? "Shared file",
                // exp = 0 means never (public shares); everything else is a
                // plain epoch timestamp.
                expiry: exp <= 0
                    ? .distantFuture
                    : Foundation.Date(timeIntervalSince1970: TimeInterval(exp)),
                messageIDs: messageIDs,
                wrappedKeyB64: wrappedKeyB64,
                saltB64: saltB64,
                files: files,
                thumbMessageID: parsedThumbMID
            )
        }

        /// Compact per-file manifest for group links: JSON
        /// `[{"n":"name","m":"1,2,3","w":"wrappedKey"},…]`, base64url-encoded so it survives any
        /// URL transport untouched.
        static func encodeFiles(_ files: [ShareFile]) -> String {
            struct Payload: Codable {
                var n: String
                var m: String
                var w: String? = nil
                var p: String? = nil
                var th: Int64? = nil
            }
            let payload = files.map {
                Payload(n: $0.name, m: $0.messageIDs.map(String.init).joined(separator: ","), w: $0.wrappedKey, p: $0.path, th: $0.thumbMessageID)
            }
            guard let data = try? JSONEncoder().encode(payload) else { return "" }
            return base64URLEncode(data)
        }

        static func decodeFiles(_ raw: String) -> [ShareFile]? {
            struct Payload: Codable {
                var n: String
                var m: String
                var w: String?
                var p: String?
                var th: Int64?
            }
            guard let data = base64URLDecode(raw),
                  let payload = try? JSONDecoder().decode([Payload].self, from: data) else { return nil }
            let files = payload.map {
                ShareFile(name: $0.n, messageIDs: $0.m.split(separator: ",").compactMap { Int64($0) }, wrappedKey: $0.w, path: $0.p, thumbMessageID: $0.th)
            }
            // Every entry must resolve to at least one message — a file with zero
            // chunks would import-fail and silently drop from the group.
            guard files.allSatisfy({ !$0.messageIDs.isEmpty }) else { return nil }
            return files
        }
    }

    /// One file carried by a forward-based share link. Single-file links carry a
    /// single entry (synthesized on parse); group links carry one entry per
    /// shared file, each naming that file's forwarded chunk messages in the
    /// share channel.
    /// Resolves (creating missing folders) the destination parent for an
    /// imported file: destination folder + optional relative path "a/b/name".
    static func resolveImportDestination(_ destinationID: String?, path: String?) async throws -> String? {
        guard destinationID != nil || (path != nil && !path!.isEmpty) else { return nil }
        var parent = destinationID
        if let path, !path.isEmpty {
            for component in path.split(separator: "/").map(String.init).dropLast() {
                parent = try await ensureFolder(named: component, under: parent)
            }
        }
        return parent
    }

    static func ensureFolder(named name: String, under parentID: String?) async throws -> String {
        let pool = (try? await DatabaseManager.shared.allObjects()) ?? []
        if let existing = pool.first(where: {
            $0.isFolder && $0.tombstoneAt == nil && $0.parentID == parentID && $0.name == name
        }) {
            return existing.id
        }
        let folder = ObjectRecord(
            id: UUID().uuidString,
            vaultID: (try? await DatabaseManager.shared.firstVault())?.id ?? "",
            name: name,
            size: 0,
            mime: "cascade/folder",
            state: "ready",
            rootHash: nil,
            wrappedKey: nil,
            createdAt: .now,
            modifiedAt: .now,
            isFavorite: false,
            trashed: false,
            parentID: parentID,
            isFolder: true
        )
        try await DatabaseManager.shared.save(folder)
        return folder.id
    }

    struct ShareFile: Equatable, Sendable, Codable {
        var name: String
        var messageIDs: [Int64]
        var wrappedKey: String? = nil
        /// Relative path inside a shared folder ("sub/dir/file.ext"); nil for
        /// plain file shares. Imports rebuild hierarchy under the destination.
        var path: String? = nil
        var thumbMessageID: Int64? = nil
    }

    // MARK: - Legacy manifest (pre-v22 per-chunk caption, disposable channels)

    struct ChunkMeta: Codable, Sendable {
        var index: Int
        var totalChunks: Int
        var name: String
        var size: Int64
        var mime: String
        var wrappedKey: String      // object key wrapped with the share key
        var rootHash: String
        var chunkSize: Int64
        var plainHash: String       // sha256 of this chunk's plaintext
    }

    static func caption(for meta: ChunkMeta) -> String {
        guard let data = try? JSONEncoder().encode(meta),
              let json = String(data: data, encoding: .utf8) else { return captionPrefix }
        return captionPrefix + json
    }

    static func parseChunkMeta(_ caption: String) -> ChunkMeta? {
        guard caption.hasPrefix(captionPrefix) else { return nil }
        let json = String(caption.dropFirst(captionPrefix.count))
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ChunkMeta.self, from: data)
    }

    // MARK: - Sender

    /// Creates the share (forwarding the vault chunks into the pool channel) and
    /// returns the share link. PRIVATE shares live `lifetime` days in a dedicated
    /// pool channel with a one-use invite; PUBLIC shares (isPublic) never expire
    /// and live in the persistent public channel. (`password` is ignored —
    /// protection is retired with the encryption era.)
    @discardableResult
    static func share(
        object: ObjectRecord,
        lifetime: TimeInterval = defaultLifetime,
        isPublic: Bool = false,
        password: String? = nil
    ) async throws -> String {
        try await share(objects: [object], lifetime: lifetime, isPublic: isPublic, password: password)
    }

    /// Creates ONE share link for the given files: a single file produces a
    /// normal share; two or more produce a GROUP share — every file's chunks are
    /// forwarded into the same channel under one invite, one link, one expiry, so
    /// the recipient imports them all together from a single link.
    @discardableResult
    static func share(
        objects: [ObjectRecord],
        lifetime: TimeInterval = defaultLifetime,
        isPublic: Bool = false,
        password: String? = nil
    ) async throws -> String {
        // Private files can't be shared: the vault no longer encrypts anything, so
        // the private flag is a PIN-gated visibility choice, not a key layer —
        // sharing would leak the file outside the PIN gate. All guards run BEFORE
        // auth (and before any DB access) so the rules are unit-testable without a
        // live Telegram session.
        guard !objects.isEmpty else { throw ShareError.notShareable }
        for object in objects {
            guard !object.isPrivate else { throw ShareError.notShareablePrivate }
        }
        guard TelegramClient.shared.isAuthorized else {
            throw ShareError.notAuthorized
        }

        // Folder sharing: folders expand to their descendant FILES — each file
        // records its path relative to the shared root so imports rebuild the
        // hierarchy under the destination folder. Private/trashed descendants
        // are skipped; an empty expansion refuses.
        var expanded: [(object: ObjectRecord, path: String?)] = []
        if objects.contains(where: \.isFolder) {
            let pool = ((try? await DatabaseManager.shared.allObjects()) ?? []).filter { !$0.trashed && $0.tombstoneAt == nil }
            let byParent = Dictionary(grouping: pool, by: { $0.parentID ?? "" })
            var expandedIDs = Set<String>()
            func walk(_ folder: ObjectRecord, _ prefix: String) {
                for child in byParent[folder.id] ?? [] where !child.isFolder {
                    guard !child.isPrivate, expandedIDs.insert(child.id).inserted else { continue }
                    expanded.append((child, prefix.isEmpty ? child.name : prefix + "/" + child.name))
                }
                for child in byParent[folder.id] ?? [] where child.isFolder {
                    guard !child.isPrivate else { continue }
                    walk(child, (prefix.isEmpty ? "" : prefix + "/") + child.name)
                }
            }
            for object in objects where object.isFolder { walk(object, object.name) }
            for object in objects where !object.isFolder {
                if expandedIDs.insert(object.id).inserted { expanded.append((object, nil)) }
            }
        } else {
            expanded = objects.map { ($0, nil as String?) }
        }
        guard !expanded.isEmpty else { throw ShareError.notShareable }
        let pathByObjectID = Dictionary(uniqueKeysWithValues: expanded.map { ($0.object.id, $0.path) })
        let objects = expanded.map(\.object)

        // Drive-style reuse: a single file that already has a LIVE share (active,
        // not yet expired) reuses that link instead of forwarding the chunks
        // again; a group whose EXACT object set was shared before reuses that
        // link. Re-using only applies to unprotected shares (password-protected shares
        // mint fresh links with dedicated salts).
        if password == nil || password!.isEmpty {
            if objects.count == 1, let object = objects.first {
                if let existing = try await reusableShareLink(for: object.id, isPublic: isPublic) {
                    logger.info("Share: reusing existing \(isPublic ? "public" : "private") link for \(object.name)")
                    return existing
                }
            } else if let existing = try await reusableGroupShareLink(for: Set(objects.map(\.id)), isPublic: isPublic) {
                logger.info("Share: reusing existing \(isPublic ? "public" : "private") group link for \(objects.count) files")
                return existing
            }
        }
        return try await forwardShare(
            objects: objects,
            lifetime: lifetime,
            isPublic: isPublic,
            password: password,
            pathByObjectID: pathByObjectID
        )
    }

    /// The forward path shared by single-file and group shares: validates every
    /// file's chunk availability, forwards each chunk of each file into the pool
    /// channel, wraps object keys, and persists the outgoing share record.
    private static func forwardShare(
        objects: [ObjectRecord],
        lifetime: TimeInterval,
        isPublic: Bool,
        password: String? = nil,
        pathByObjectID: [String: String?] = [:]
    ) async throws -> String {
        let vault: VaultRecord
        do {
            vault = try await VaultManager.ensureVault()
        } catch {
            throw ShareError.importFailed(describe(error))
        }

        // The source of a forward-based share is the VAULT COPY, not a local file:
        // every chunk must have an uploaded message to forward.
        var perFileChunks: [(object: ObjectRecord, chunks: [ChunkRecord])] = []
        for object in objects {
            let chunks = ((try? await DatabaseManager.shared.chunks(for: object.id)) ?? [])
                .sorted { $0.index < $1.index }
            guard !chunks.isEmpty, chunks.allSatisfy({ ($0.messageID ?? 0) > 0 }) else {
                throw ShareError.sourceUnavailable
            }
            perFileChunks.append((object, chunks))
        }

        // Pool channel: private shares take a dedicated slot (one active share per
        // channel, so a private link's holder can never see other files); public
        // shares share the persistent public channel. Every channel is archived
        // like the vault.
        let state: ShareChannelState
        do {
            state = isPublic ? try await publicChannel() : try await allocatePrivateChannel()
        } catch {
            throw ShareError.createFailed(describe(error))
        }
        let channelID = state.channelID
        let inviteLink: String
        do {
            // Private: a fresh one-use invite so only the link holder can join
            // (the link expires with the share). Public: the channel's stored
            // permanent invite — the SAME invite embeds in every public link, so
            // any holder can join, any time, forever.
            if isPublic {
                guard !state.inviteLink.isEmpty else {
                    throw ShareError.createFailed("Public share channel has no invite.")
                }
                inviteLink = state.inviteLink
            } else {
                inviteLink = try await TelegramClient.shared.createShareInviteLink(
                    chatId: channelID,
                    expiresIn: lifetime
                )
            }
        } catch {
            // Channel was created but the invite failed — nothing was forwarded
            // yet and no record was saved, so it's unused: delete it outright.
            if state.createdAt.timeIntervalSinceNow > -60 {
                try? await TelegramClient.shared.deleteChat(chatId: channelID)
                try? await DatabaseManager.shared.deleteShareChannel(id: state.id)
            }
            throw ShareError.createFailed(describe(error))
        }

        // Forward each chunk message into the share channel — a reference copy,
        // Telegram copies the document server-side: no re-upload, no size limit.
        var allMessageIDs: [Int64] = []
        var forwardedPerFile: [(object: ObjectRecord, fileIDs: [Int64])] = []
        var thumbMIDByObjectID: [String: Int64] = [:]
        do {
            for (object, chunks) in perFileChunks {
                var fileIDs: [Int64] = []
                for (chunkIndex, chunk) in chunks.enumerated() {
                    guard let messageID = chunk.messageID else { continue }
                    // 300ms between forwards keeps multi-chunk / multi-file shares
                    // under Telegram's write flood limits.
                    if chunkIndex > 0 || forwardedPerFile.count > 0 {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                    }
                    let mid = try await TelegramClient.shared.forwardMessage(
                        chatId: channelID,
                        fromChatId: vault.channelID,
                        messageId: messageID
                    )
                    fileIDs.append(mid)
                }
                guard fileIDs.count == chunks.count else { throw ShareError.uploadFailed("Partial forward") }
                forwardedPerFile.append((object, fileIDs))
                allMessageIDs.append(contentsOf: fileIDs)

                // Forward thumbnail sidecar message if present so recipient receives the preview
                if let thumbMID = object.thumbMessageID {
                    if let fwdThumb = try? await TelegramClient.shared.forwardMessage(
                        chatId: channelID,
                        fromChatId: vault.channelID,
                        messageId: thumbMID
                    ) {
                        thumbMIDByObjectID[object.id] = fwdThumb
                        allMessageIDs.append(fwdThumb)
                    }
                }
            }
        } catch {
            // Roll back the forwarded copies so the reusable channel stays clean.
            if !allMessageIDs.isEmpty {
                try? await TelegramClient.shared.deleteMessages(chatId: channelID, messageIds: allMessageIDs)
            }
            throw ShareError.uploadFailed(describe(error))
        }

        // Cryptographic keys for the share link — RETIRED with the encryption era.
        // Files are plain bytes, so there is no object key to wrap: links carry no
        // key material and password protection (which depended on wrapping an
        // object key with a password-derived key) no longer exists. Links remain
        // opaque obfuscated blobs — that is transport obscurity, not secrecy.
        let isProtected = false
        let linkKey = SymmetricKey(size: .bits256)
        let saltB64 = ""
        let shareKeyB64 = linkKey.withUnsafeBytes { Data($0).base64EncodedString() }

        var files: [ShareFile] = []
        var singleWrappedKeyB64 = ""

        for (object, fileIDs) in forwardedPerFile {
            // No object key exists anymore — links never wrap keys.
            let wrappedForLink: String? = nil

            if forwardedPerFile.count == 1 {
                singleWrappedKeyB64 = wrappedForLink ?? ""
            }
            files.append(ShareFile(
                name: object.name,
                messageIDs: fileIDs,
                wrappedKey: wrappedForLink,
                path: pathByObjectID[object.id] ?? nil,
                thumbMessageID: thumbMIDByObjectID[object.id]
            ))
        }

        // Group links present a combined name; the record also stores every object
        // ID so single-file reuse never hands out a group link and group reuse can
        // match the exact same selection.
        let isGroup = files.count > 1 || files.contains(where: { $0.path != nil })
        let displayName: String
        let folderPrefixes = Set(files.compactMap { $0.path?.split(separator: "/").first.map(String.init) })
        if folderPrefixes.count == 1, let folderName = folderPrefixes.first {
            displayName = folderName
        } else {
            displayName = isGroup ? "\(files.count) files" : (files.first?.name ?? "Shared file")
        }

        // Public shares never expire; private shares live for `lifetime`.
        let expiry = isPublic ? Foundation.Date.distantFuture : Foundation.Date().addingTimeInterval(lifetime)
        let singleThumbMID = forwardedPerFile.count == 1 ? thumbMIDByObjectID[forwardedPerFile.first?.object.id ?? ""] : nil
        let plainLink = ShareLink(
            id: UUID().uuidString,
            channelID: channelID,
            inviteLink: inviteLink,
            shareKey: shareKeyB64,
            fileName: displayName,
            expiry: expiry,
            messageIDs: allMessageIDs,
            wrappedKeyB64: singleWrappedKeyB64,
            saltB64: saltB64,
            files: isGroup ? files : [],
            thumbMessageID: singleThumbMID
        ).urlString
        // Hand out the obfuscated form: the link travels as an opaque blob with no
        // visible t.me invite, channel id, or key material. The exact string is
        // stored so reusing this share later returns the IDENTICAL link.
        let finalLink = (try? obfuscate(plainLink)) ?? plainLink
        var record = ShareRecord(
            id: UUID().uuidString,
            objectID: objects.first?.id ?? "",
            channelID: channelID,
            inviteLink: inviteLink,
            shareKey: shareKeyB64,
            expiry: expiry,
            role: "outgoing",
            state: "active",
            fileName: displayName,
            createdAt: .now
        )
        record.linkBlob = finalLink
        record.messageIDs = allMessageIDs.map(String.init).joined(separator: ",")
        record.wrappedKeyB64 = singleWrappedKeyB64
        record.isPublic = isPublic
        if isGroup {
            record.groupObjectIDs = objects.map(\.id).joined(separator: ",")
        }
        try await DatabaseManager.shared.saveShare(record)
        try? await DatabaseManager.shared.recordShareActivity(ShareActivityRecord(
            id: UUID().uuidString, shareID: record.id, channelID: channelID,
            kind: "created", userID: nil,
            detail: isPublic ? "Public link created (never expires)" : "Private link created (24h)",
            createdAt: .now
        ))
        logger.info("Share: \(displayName) (\(files.count) file(s), \(allMessageIDs.count) chunks) into channel \(channelID) [\(isPublic ? "public" : "private"), protected=\(isProtected)]")
        return finalLink
    }

    /// The link of this file's most recent LIVE outgoing share (state `active`,
    /// not yet expired, channel still alive), or nil. Re-sharing a file that
    /// already has one returns the SAME link — identical string when the record
    /// stored it, same channel/key/expiry either way — so no second forward is
    /// made. Group shares are never reused here: sharing a member file alone must
    /// mint its own single-file link, not the link that also carries its siblings.
    /// Kind-aware: a public share is only reused by another public share.
    static func reusableShareLink(for objectID: String, isPublic: Bool = false) async throws -> String? {
        let shares = (try? await DatabaseManager.shared.shares(role: "outgoing")) ?? []
        let candidates = shares
            .filter {
                $0.objectID == objectID
                    && $0.groupObjectIDs.isEmpty
                    && $0.isPublic == isPublic
                    && $0.state == "active"
                    && $0.expiry > Foundation.Date()
            }
            .sorted { $0.expiry > $1.expiry }
        for share in candidates {
            guard await isLiveShare(share) else { continue }
            // The stored blob is THE link the user was handed; return it verbatim
            // so re-sharing produces the identical string.
            if let blob = share.linkBlob {
                return blob
            }
            // Pre-v15 record: reconstruct the same underlying link from its fields.
            let plain = ShareLink(
                id: share.id,
                channelID: share.channelID,
                inviteLink: share.inviteLink,
                shareKey: share.shareKey,
                fileName: share.fileName,
                expiry: share.expiry,
                messageIDs: share.messageIDs.split(separator: ",").compactMap { Int64($0) },
                wrappedKeyB64: share.wrappedKeyB64
            ).urlString
            return (try? obfuscate(plain)) ?? plain
        }
        return nil
    }

    /// The link of the most recent LIVE outgoing GROUP share covering EXACTLY the
    /// given object set (active, not expired, channel alive), or nil. Re-sharing
    /// the same multi-file selection returns the SAME link — identical string —
    /// so no second forward is made. Kind-aware: a public group share is only
    /// reused by another public group share.
    static func reusableGroupShareLink(for objectIDs: Set<String>, isPublic: Bool = false) async throws -> String? {
        let shares = (try? await DatabaseManager.shared.shares(role: "outgoing")) ?? []
        let candidates = shares
            .filter {
                $0.state == "active"
                    && $0.isPublic == isPublic
                    && $0.expiry > Foundation.Date()
                    && !$0.groupObjectIDs.isEmpty
                    && Set($0.groupObjectIDs.split(separator: ",").map(String.init)) == objectIDs
            }
            .sorted { $0.expiry > $1.expiry }
        for share in candidates {
            guard await isLiveShare(share) else { continue }
            // Group records always store the blob (they postdate v15); reconstructing
            // a group link from fields would lose the per-file manifest, so a record
            // without a blob is never reused.
            if let blob = share.linkBlob {
                return blob
            }
        }
        return nil
    }

    /// Verifies a candidate outgoing share is still truly reusable and revokes it
    /// when broken, so re-sharing mints a fresh link instead of handing out a dead
    /// one. Returns false when the share must not be reused.
    private static func isLiveShare(_ share: ShareRecord) async -> Bool {
        // Legacy v1 shares (pre-forward-based, disposable channel) are never
        // reused: their link points at an old upload copy, and re-forwarding
        // the file into the reusable channel requires the v2 message IDs.
        // Re-sharing such a file mints a fresh v2 share; the legacy record
        // stays valid for recipients until expiry and is cleaned up then.
        guard !share.messageIDs.isEmpty else { return false }
        // Shares created before the server-confirm fix persisted TDLib LOCAL
        // ids (forwardMessages returned pending ids). Real server ids in a
        // channel are multiples of 2^20 (TDLib's shifted id space); local ids
        // carry low bits, so any stored id that isn't a clean multiple is a
        // broken local id whose message never existed server-side — importing
        // that link fails with "Not Found". Never hand such a link out again:
        // revoke it so the next share of the same file mints a fresh, valid
        // link with confirmed ids.
        let storedIDs = share.messageIDs.split(separator: ",").compactMap { Int64($0) }
        if storedIDs.contains(where: { $0 % (1 << 20) != 0 }) {
            var broken = share
            broken.state = "revoked"
            try? await DatabaseManager.shared.saveShare(broken)
            return false
        }
        // The record can outlive its channel (deleted manually in Telegram, or
        // a crash between deleteMessages and marking revoked) — never hand out
        // a link whose channel is gone. getChat is served from TDLib's cache, so
        // this is cheap; skipped when Telegram isn't ready or under XCTest (the
        // app-hosted test suite boots the real app, whose auto-login can flip
        // isAuthorized mid-run and would revoke the fake share records).
        if TelegramClient.shared.isAuthorized,
           !ShareEngine.underXCTest,
           !(await TelegramClient.shared.chatExists(chatId: share.channelID)) {
            var stale = share
            stale.state = "revoked"
            try? await DatabaseManager.shared.saveShare(stale)
            return false
        }
        // The record can ALSO outlive its forwarded messages: deleting them
        // manually in Telegram (or any out-of-band deletion) breaks the copies
        // the link names — a reused link would import-fail with "invalid
        // payload". Verify the chunks still exist before reusing; if they're
        // gone, revoke the stale record so the next share of this file
        // re-forwards fresh copies and mints a NEW working link. getMessage is
        // served from TDLib's cache, so this is cheap (a handful of lookups,
        // only on an explicit share action — never a hot path).
        if TelegramClient.shared.isAuthorized,
           !ShareEngine.underXCTest,
           !storedIDs.isEmpty {
            let stillThere = (try? await TelegramClient.shared.messagesByIds(
                chatId: share.channelID,
                messageIds: storedIDs
            ))?.count == storedIDs.count
            if !stillThere {
                var stale = share
                stale.state = "revoked"
                try? await DatabaseManager.shared.saveShare(stale)
                return false
            }
        }
        return true
    }

    // MARK: - Share channel pool (v24)

    /// True when we're inside the app-hosted test suite: Telegram is never
    /// touched — no liveness checks, no channel creation (tests use fake
    /// records; the real app's auto-login can flip isAuthorized mid-run).
    static let underXCTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// A private share's dedicated pool channel. One active private share per
    /// slot (channel), so a private link's holder can never read other files'
    /// messages. Join/leave semantics: a free recorded channel is reused live;
    /// a slot whose channel we LEFT (cancel) is REJOINED via its recorded
    /// permanent invite (the invite resolves to the same channel and the
    /// creator regains admin instantly); a new channel is created only when no
    /// recorded invite resolves (deleted out-of-band). When all
    /// `privatePoolSize` slots are taken by active shares, throws
    /// `privatePoolFull` — never silently evicts.
    static func allocatePrivateChannel() async throws -> ShareChannelState {
        let active = ((try? await DatabaseManager.shared.shares(role: "outgoing")) ?? [])
            .filter { $0.state == "active" && !$0.isPublic }
        guard active.count < privatePoolSize else {
            throw ShareError.privatePoolFull
        }
        // Which slots are busy: the channels active private shares live in.
        var busySlots: Set<Int64> = []
        for share in active {
            if let state = try? await DatabaseManager.shared.shareChannelState(channelID: share.channelID) {
                busySlots.insert(state.id)
            }
        }
        // First pass: reuse a live, free recorded channel.
        for slot in 1...Int64(privatePoolSize) where !busySlots.contains(slot) {
            if let state = try? await DatabaseManager.shared.shareChannelState(id: slot),
               await TelegramClient.shared.chatExists(chatId: state.channelID) {
                // Legacy channels (pre-naming) are renamed to their slot title;
                // legacy channels (pre-TTL) get the 24h auto-delete enabled.
                await TelegramClient.shared.renameChatIfNeeded(
                    chatId: state.channelID,
                    title: poolChannelTitle(id: state.id, kind: .private)
                )
                await TelegramClient.shared.setMessageAutoDelete(chatId: state.channelID)
                // Legacy channels get branded once, when they have no photo yet.
                if !(await TelegramClient.shared.hasChannelPhoto(chatId: state.channelID)) {
                    await TelegramClient.shared.setChannelPhoto(
                        chatId: state.channelID,
                        pngNamed: "pc"
                    )
                }
                return state
            }
        }
        // Second pass: reuse a slot whose channel we LEFT (join/leave) by
        // rejoining through its recorded permanent invite. The invite resolves
        // to the SAME channel (verified live: creator rejoining regains admin
        // instantly), so the row stays valid — no new channel is created.
        for slot in 1...Int64(privatePoolSize) where !busySlots.contains(slot) {
            guard let existing = try? await DatabaseManager.shared.shareChannelState(id: slot),
                  !existing.inviteLink.isEmpty,
                  !(await TelegramClient.shared.chatExists(chatId: existing.channelID)) else { continue }
            if let joined = try? await TelegramClient.shared.joinShareChannel(inviteLink: existing.inviteLink) {
                if joined == existing.channelID {
                    await TelegramClient.shared.renameChatIfNeeded(
                        chatId: existing.channelID,
                        title: poolChannelTitle(id: existing.id, kind: .private)
                    )
                    await TelegramClient.shared.setMessageAutoDelete(chatId: existing.channelID)
                    if !(await TelegramClient.shared.hasChannelPhoto(chatId: existing.channelID)) {
                        await TelegramClient.shared.setChannelPhoto(
                            chatId: existing.channelID,
                            pngNamed: "pc"
                        )
                    }
                    return existing
                }
                // The invite resolved to a different channel — adopt it so the
                // row never points at a stale channel.
                var adopted = existing
                adopted.channelID = joined
                try? await DatabaseManager.shared.saveShareChannel(adopted)
                await TelegramClient.shared.renameChatIfNeeded(
                    chatId: joined,
                    title: poolChannelTitle(id: existing.id, kind: .private)
                )
                await TelegramClient.shared.setMessageAutoDelete(chatId: joined)
                if !(await TelegramClient.shared.hasChannelPhoto(chatId: joined)) {
                    await TelegramClient.shared.setChannelPhoto(
                        chatId: joined,
                        pngNamed: "pc"
                    )
                }
                return adopted
            }
        }
        // Third pass: create a channel in the first slot with no reusable row
        // (no recorded row, or a recorded row whose channel AND invite are gone).
        for slot in 1...Int64(privatePoolSize) where !busySlots.contains(slot) {
            if let existing = try? await DatabaseManager.shared.shareChannelState(id: slot) {
                if await TelegramClient.shared.chatExists(chatId: existing.channelID) {
                    continue
                }
            }
            return try await createPoolChannel(id: slot, kind: .private)
        }
        throw ShareError.privatePoolFull
    }

    /// The persistent public channel: created once, reused by every public
    /// share; recreated in place if it ever goes missing. Never retired.
    static func publicChannel() async throws -> ShareChannelState {
        if let state = try? await DatabaseManager.shared.shareChannelState(id: publicChannelRowID),
           await TelegramClient.shared.chatExists(chatId: state.channelID) {
            // Legacy channels (pre-naming) are renamed to their slot title.
            await TelegramClient.shared.renameChatIfNeeded(
                chatId: state.channelID,
                title: poolChannelTitle(id: state.id, kind: .public)
            )
            if !(await TelegramClient.shared.hasChannelPhoto(chatId: state.channelID)) {
                await TelegramClient.shared.setChannelPhoto(chatId: state.channelID, pngNamed: "oc")
            }
            return state
        }
        return try await createPoolChannel(id: publicChannelRowID, kind: .public)
    }

    /// Creates and archives a pool channel, stores its permanent invite in
    /// share_state, and returns the state. Refuses under XCTest — the app-hosted
    /// suite auto-logs in and must never create real Telegram channels.
    private static func createPoolChannel(id: Int64, kind: ShareKind) async throws -> ShareChannelState {
        guard !underXCTest else {
            throw ShareError.createFailed("Telegram unavailable under test")
        }
        let channelID = try await TelegramClient.shared.createShareChannel(title: poolChannelTitle(id: id, kind: kind))
        // 24h server-side auto-delete on PRIVATE slots only: share messages
        // vanish from Telegram a day after posting, even if this app never
        // runs again. The public channel's messages must persist forever.
        if kind == .private {
            await TelegramClient.shared.setMessageAutoDelete(chatId: channelID)
        }
        await TelegramClient.shared.archiveVaultChannel(chatId: channelID)
        // Brand the channel with the appropriate icon.
        let pngName = kind == .public ? "oc" : "pc"
        await TelegramClient.shared.setChannelPhoto(chatId: channelID, pngNamed: pngName)
        let invite = (try? await TelegramClient.shared.createPermanentShareInvite(chatId: channelID)) ?? ""
        var state = ShareChannelState(
            id: id,
            channelID: channelID,
            kind: kind.rawValue,
            inviteLink: invite,
            createdAt: .now
        )
        try await DatabaseManager.shared.saveShareChannel(state)
        return state
    }

    /// One-time branding pass for channels created before profile pictures
    /// existed (legacy vault/backup/pool channels): sets a branded photo on
    /// every recorded channel that has none or updates to official PNG assets.
    /// Runs at every launch after auth.
    static func healChannelPhotos(force: Bool = false) async {
        guard !underXCTest else { return }
        let shouldForce = force || !UserDefaults.standard.bool(forKey: "xc_hasAppliedBrandedPNGPhotosV6")
        if let vault = try? await DatabaseManager.shared.firstVault() {
            let hasVaultPhoto = await TelegramClient.shared.hasChannelPhoto(chatId: vault.channelID)
            if shouldForce || !hasVaultPhoto {
                await TelegramClient.shared.setChannelPhoto(chatId: vault.channelID, pngNamed: "cascade")
            }
            let backupID: Int64?
            if let bid = vault.backupChannelID {
                backupID = bid
            } else {
                backupID = await TelegramClient.shared.findBackupChannel()
            }
            if let backupID {
                let hasBackupPhoto = await TelegramClient.shared.hasChannelPhoto(chatId: backupID)
                if shouldForce || !hasBackupPhoto {
                    await TelegramClient.shared.setChannelPhoto(chatId: backupID, pngNamed: "backup")
                }
            }
        }
        for slot in 1...Int64(privatePoolSize) {
            guard let state = try? await DatabaseManager.shared.shareChannelState(id: slot),
                  await TelegramClient.shared.chatExists(chatId: state.channelID) else { continue }
            let hasPhoto = await TelegramClient.shared.hasChannelPhoto(chatId: state.channelID)
            if shouldForce || !hasPhoto {
                await TelegramClient.shared.setChannelPhoto(chatId: state.channelID, pngNamed: "pc")
            }
        }
        if let state = try? await DatabaseManager.shared.shareChannelState(id: publicChannelRowID),
           await TelegramClient.shared.chatExists(chatId: state.channelID) {
            let hasPhoto = await TelegramClient.shared.hasChannelPhoto(chatId: state.channelID)
            if shouldForce || !hasPhoto {
                await TelegramClient.shared.setChannelPhoto(chatId: state.channelID, pngNamed: "oc")
            }
        }
        UserDefaults.standard.set(true, forKey: "xc_hasAppliedBrandedPNGPhotosV6")
    }

    /// Idempotent launch heal: ensures every PRIVATE pool channel has the 24h
    /// server-side auto-delete (TTL) enabled. Catches channels whose TTL was
    /// previously cleared or never set (legacy slots). Public channel is never
    /// touched — its messages must persist forever.
    static func ensureTTLOnPrivatePoolChannels() async {
        guard !underXCTest else { return }
        for state in (try? await DatabaseManager.shared.allShareChannels()) ?? [] {
            if state.kind == ShareKind.private.rawValue {
                await TelegramClient.shared.setMessageAutoDelete(chatId: state.channelID)
            }
        }
    }

    /// Revokes ONE active outgoing share: that file's messages are deleted from
    /// its channel and, for PRIVATE shares, the pool channel is LEFT. Channels
    /// are never destroyed — leaveChat just removes the account from the chat
    /// (the channel persists server-side, its permanent invite stays valid), so
    /// the next private share REJOINS the same slot via the invite recorded in
    /// share_state; allocation only creates a channel when the recorded invite
    /// itself is gone. The public channel is permanent and is never left —
    /// cancelling a public share only deletes that share's messages.
    static func cancelShare(_ share: ShareRecord) async {
        guard share.state == "active" else { return }
        let mids = share.messageIDs.split(separator: ",").compactMap { Int64($0) }
        if !mids.isEmpty {
            try? await TelegramClient.shared.deleteMessages(chatId: share.channelID, messageIds: mids)
        }
        if !share.isPublic {
            try? await TelegramClient.shared.leaveChat(chatId: share.channelID)
        }
        var updated = share
        updated.state = "revoked"
        try? await DatabaseManager.shared.saveShare(updated)
        try? await DatabaseManager.shared.recordShareActivity(ShareActivityRecord(
            id: UUID().uuidString, shareID: share.id, channelID: share.channelID,
            kind: "revoked", userID: nil, detail: "Link cancelled — recipients can no longer open it",
            createdAt: .now
        ))
    }

    /// Revokes every active outgoing share (private and public). Private slots
    /// are left and rejoined by the next private share; the public channel is
    /// never left — only its share messages are deleted.
    static func cancelAllShares() async {
        let shares = (try? await DatabaseManager.shared.shares(role: "outgoing")) ?? []
        for share in shares where share.state == "active" {
            await cancelShare(share)
        }
    }

    /// Grace period between a recipient joining a private pool channel and the
    /// share cancelling itself: long enough for their app to open the link and
    /// forward the file into their own vault (a pure server-side copy).
    static let cancelOnUseGrace: TimeInterval = 300

    /// Cancel-on-use: fired from the TDLib update handler when a member joins a
    /// chat. If the chat is one of our PRIVATE pool slots and the joiner is not
    /// our own account, that share was used — after `cancelOnUseGrace` seconds
    /// it revokes itself (messages deleted, channel left), exactly like a
    /// manual cancel. The recipient's forwarded copy lives in THEIR vault
    /// channel, so the grace-protected forward is unaffected.
    ///
    /// Wave 2 item 9 — importer visibility: EVERY join (private AND public
    /// channels) lands in the share-activity log. Private joins attribute to
    /// the active share on that slot; public joins stay channel-level (every
    /// public link shares one channel, so per-link attribution is impossible).
    static func handleShareChannelMemberJoined(chatId: Int64, userId: Int64) async {
        guard let state = try? await DatabaseManager.shared.shareChannelState(channelID: chatId) else { return }

        // Activity first — even when nothing else acts on the join.
        if state.kind == "private" {
            // Our own account rejoining its slot (after a cancel/leave) is not a use.
            let isSelf = ((try? await TelegramClient.shared.myUserID()) ?? nil) == userId
            let share = ((try? await DatabaseManager.shared.shares(role: "outgoing")) ?? [])
                .first { $0.state == "active" && !$0.isPublic && $0.channelID == chatId }
            if !isSelf {
                try? await DatabaseManager.shared.recordShareActivity(ShareActivityRecord(
                    id: UUID().uuidString,
                    shareID: share?.id ?? "",
                    channelID: chatId,
                    kind: "join",
                    userID: userId,
                    detail: "Importer joined the private share channel",
                    createdAt: .now
                ))
            }
            guard !isSelf else { return }
            guard let share else { return }
            logger.info("Share \(share.id): recipient joined slot \(state.id) — cancelling after \(cancelOnUseGrace)s grace")
            try? await Task.sleep(nanoseconds: UInt64(cancelOnUseGrace * 1_000_000_000))
            guard let latest = try? await DatabaseManager.shared.share(id: share.id),
                  latest.state == "active" else { return }
            await cancelShare(latest)
        } else {
            // Public channel: a join means SOMEONE opened one of the public
            // links and came in. Not attributable to a single link.
            let isSelf = ((try? await TelegramClient.shared.myUserID()) ?? nil) == userId
            guard !isSelf else { return }
            try? await DatabaseManager.shared.recordShareActivity(ShareActivityRecord(
                id: UUID().uuidString,
                shareID: "",
                channelID: chatId,
                kind: "join",
                userID: userId,
                detail: "Someone joined the public share channel via a link",
                createdAt: .now
            ))
        }
    }

    // MARK: - Recipient

    /// What opening a share link produced.
    enum ImportOutcome: Sendable {
        /// The file was forwarded into the recipient's vault and cataloged.
        case imported
        /// The sharer opened their OWN link — the file is already in their vault;
        /// surfaced so the UI can reveal the original (Drive/iCloud behavior)
        /// instead of importing a duplicate.
        case selfOpen(objectID: String)
        /// The recipient ALREADY holds this exact file (same content rootHash)
        /// from an earlier import of the same share — nothing was imported;
        /// surfaced so the UI can reveal the existing copy instead of duplicating.
        case alreadyImported(objectID: String)
        /// The file's chunks were forwarded into the recipient's vault channel
        /// and staged as a `pendingImport` — streamable/previewable but NOT
        /// cataloged. The UI shows a detail screen where the user decides:
        /// Import (catalog it) or Cancel (delete the forwarded copies).
        case pending(objectID: String)
    }

    /// Opens a share link: joins the channel, forwards every chunk into the
    /// recipient's own vault channel, leaves, and returns `.pending` — the file
    /// is staged (streamable/previewable) but NOT cataloged until the user
    /// decides on the detail screen (Import = catalog + backup mirror,
    /// Cancel = delete the forwarded copies). When the sharer opens their own
    /// link, it short-circuits to `.selfOpen` — the file is already in their
    /// cloud, so nothing is imported.
    /// Opens a share link: joins the channel, forwards every chunk into the
    /// recipient's own vault channel, leaves, and returns `.pending` — the file
    /// is staged (streamable/previewable) but NOT cataloged until the user
    /// decides on the detail screen (Import = catalog + backup mirror,
    /// Cancel = delete the forwarded copies). When the sharer opens their own
    /// link, it short-circuits to `.selfOpen` — the file is already in their
    /// cloud, so nothing is imported.
    @discardableResult
    static func importLink(
        _ rawLink: String,
        password: String? = nil,
        destinationFolderID: String? = nil
    ) async throws -> ImportOutcome {
        guard TelegramClient.shared.isAuthorized else {
            throw ShareError.notAuthorized
        }
        guard let link = ShareLink.parse(rawLink) else { throw ShareError.invalidLink }
        guard link.expiry > Date() else { throw ShareError.expired }

        // The sharer opening their own link: the file is already in this vault —
        // reveal the original instead of duplicating it. (If the original was
        // deleted since sharing, fall through to a normal import — the channel
        // copy is still valid until expiry.) With the reusable channel, every
        // outgoing share lives in the SAME channel, so match by forwarded message
        // IDs AND the channel for v2 links; legacy links (own disposable channel)
        // match by id. Matching channelID is mandatory: message IDs are only
        // unique WITHIN a chat — two accounts' channels can contain messages with
        // the same numeric id (e.g. local ids before the server-confirm fix), and
        // matching messageIDs alone made a recipient mistake a foreign link for
        // their own share, revealing (and blinking) the wrong file instead of
        // importing.
        let outgoing = (try? await DatabaseManager.shared.shares(role: "outgoing")) ?? []
        let own: ShareRecord? = link.isForwardBased
            ? outgoing.first {
                $0.channelID == link.channelID
                    && $0.messageIDs == link.messageIDs.map(String.init).joined(separator: ",")
            }
            : outgoing.first { $0.channelID == link.channelID }
        if let own, let object = try? await DatabaseManager.shared.object(own.objectID) {
            return .selfOpen(objectID: object.id)
        }

        let vault: VaultRecord
        do {
            vault = try await VaultManager.ensureVault()
        } catch {
            throw ShareError.importFailed(describe(error))
        }

        // Join the share channel. The one-use invite may already be consumed — the
        // recipient could have opened the link in the browser or Telegram app first
        // (which also joins, using up the invite). Fall back to reading the channel
        // directly via the chat id carried inside the link itself.
        let channelID: Int64
        do {
            channelID = try await TelegramClient.shared.joinShareChannel(inviteLink: link.inviteLink)
        } catch {
            guard try await TelegramClient.shared.isChatMember(chatId: link.channelID) else {
                throw ShareError.joinFailed(describe(error))
            }
            channelID = link.channelID
        }
        defer { Task { try? await TelegramClient.shared.leaveChat(chatId: channelID) } }

        if link.isForwardBased {
            return try await stageImport(link: link, channelID: channelID, vault: vault, password: password, destinationFolderID: destinationFolderID)
        }
        return try await stageLegacyImport(link: link, channelID: channelID, vault: vault, destinationFolderID: destinationFolderID)
    }

    /// v2 import staging: reads the link's messages in the share channel and
    /// forwards every chunk into the recipient's vault channel IMMEDIATELY —
    /// the file becomes streamable/previewable without being cataloged. The
    /// object is saved as `pendingImport` (invisible to the catalog, snapshot,
    /// sync and heal) and the UI offers Import (catalog + backup mirror) or
    /// Cancel (delete the forwarded copies). Backup mirroring is deferred to
    /// the Import decision so cancelled files never reach the backup channel.
    private static func stageImport(
        link: ShareLink,
        channelID: Int64,
        vault: VaultRecord,
        password: String? = nil,
        destinationFolderID: String? = nil
    ) async throws -> ImportOutcome {
        do {
            // The link names one or more files. Single-file links parse into a
            // one-entry manifest; group links carry one entry per shared file —
            // each entry names that file's forwarded messages in the channel.
            let files = link.files.isEmpty
                ? [ShareFile(name: link.fileName, messageIDs: link.messageIDs, wrappedKey: link.wrappedKeyB64.isEmpty ? nil : link.wrappedKeyB64)]
                : link.files
            guard files.allSatisfy({ !$0.messageIDs.isEmpty }) else { throw ShareError.invalidPayload }

            // Link keys are retired with the encryption era. A password-protected
            // link can only have been minted by an old encrypted build.
            if link.isPasswordProtected {
                throw ShareError.createFailed(
                    "This link is password-protected by an older, encrypted version of the app and can no longer be imported."
                )
            }

            var stagedCount = 0
            var alreadyImportedID: String?
            var firstStagedID: String?
            var firstStagedName: String?

            for file in files {
                let messages = try await TelegramClient.shared.messagesByIds(chatId: channelID, messageIds: file.messageIDs)
                guard messages.count == file.messageIDs.count else { throw ShareError.invalidPayload }
                var metas: [ChunkCaption.Meta] = []
                for (_, caption) in messages {
                    guard let caption, let meta = ChunkCaption.parse(caption) else { throw ShareError.invalidPayload }
                    metas.append(meta)
                }
                guard let first = metas.first else { throw ShareError.invalidPayload }

                // Re-import of a file this account already holds (same content hash,
                // e.g. the sharer shared it again after the first import): reveal
                // the existing copy instead of forwarding a duplicate into the vault.
                if let existing = try await Self.existingObject(rootHash: first.rootHash) {
                    alreadyImportedID = alreadyImportedID ?? existing.id
                    continue
                }
                // Already staged from an earlier open of this link: re-present the
                // existing pending decision instead of forwarding a second copy.
                if let staged = ((try? await DatabaseManager.shared.pendingImports()) ?? [])
                    .first(where: { $0.rootHash == first.rootHash }) {
                    firstStagedID = firstStagedID ?? staged.id
                    firstStagedName = firstStagedName ?? staged.name
                    stagedCount += 1
                    continue
                }

                // Key wrapping is retired: files are plain bytes. A link minted by
                // an OLD build that carries a wrapped object key describes an
                // encrypted object — those cannot be imported anymore.
                let wrappedKeyForFile = file.wrappedKey ?? (files.count == 1 ? link.wrappedKeyB64 : nil)
                let rewrappedKey: Data?
                if let wrappedKeyForFile, !wrappedKeyForFile.isEmpty {
                    throw ShareError.createFailed(
                        "This link was created by an older, encrypted version of the app and can no longer be imported. Ask the sender to re-share from the current version."
                    )
                } else {
                    rewrappedKey = nil
                }

                // Forward every chunk message into our vault channel (server-side copy).
                let objectID = UUID().uuidString

                // Forward thumbnail sidecar message if present so recipient gets the thumbnail
                let shareThumbMID = file.thumbMessageID ?? (files.count == 1 ? link.thumbMessageID : nil)
                var importedThumbMID: Int64? = nil
                if let shareThumbMID {
                    importedThumbMID = try? await TelegramClient.shared.forwardMessage(
                        chatId: vault.channelID,
                        fromChatId: channelID,
                        messageId: shareThumbMID
                    )
                }

                // Cache thumbnail directly from the share channel or vault before leaving
                if let shareThumbMID, let firstMessageId = messages.first?.messageId {
                    if let thumbData = try? await TelegramClient.shared.thumbnailData(forMessage: firstMessageId, chatId: channelID),
                       !thumbData.isEmpty,
                       let thumbDir = try? UploadEngine.thumbnailsDirectory() {
                        let dest = thumbDir.appendingPathComponent("\(objectID)-tg.jpg")
                        try? thumbData.write(to: dest)
                    }
                }
                let chunkSize = first.effectiveChunkSize
                var chunkRecords: [ChunkRecord] = []
                for (message, meta) in zip(messages, metas) {
                    let newMessageId = try await TelegramClient.shared.forwardMessage(
                        chatId: vault.channelID,
                        fromChatId: channelID,
                        messageId: message.messageId
                    )
                    // Legacy captions predate chunkSize; derive per-chunk sizes from
                    // the effective chunk size, capped by the file remainder.
                    let offset = Int64(meta.index) * chunkSize
                    let size = max(0, min(chunkSize, first.size - offset))
                    chunkRecords.append(ChunkRecord(
                        id: UUID().uuidString,
                        objectID: objectID,
                        index: meta.index,
                        size: size,
                        plainHash: meta.plainHash,
                        cipherHash: meta.cipherHash,
                        state: "uploaded",
                        messageID: newMessageId,
                        fileUniqueID: nil,
                        channelID: vault.channelID,
                        createdAt: .now
                    ))
                }
                guard chunkRecords.count == metas.count else { throw ShareError.invalidPayload }

                let resolvedName = !file.name.isEmpty && file.name != "Shared file"
                    ? file.name
                    : (!first.name.isEmpty ? first.name : link.fileName)
                let resolvedMime = !first.mime.isEmpty && first.mime != "application/octet-stream"
                    ? first.mime
                    : (UTType(filenameExtension: (resolvedName as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream")

                // pendingImport: streamable via the existing stack (reads the DB by
                // object id) but invisible to every catalog view/sync/heal path.
                let object = ObjectRecord(
                    id: objectID,
                    vaultID: vault.id,
                    name: resolvedName,
                    size: first.size,
                    mime: resolvedMime,
                    state: "pendingImport",
                    rootHash: first.rootHash,
                    wrappedKey: rewrappedKey,
                    createdAt: .now,
                    modifiedAt: .now,
                    isFavorite: false,
                    trashed: false,
                    parentID: try await Self.resolveImportDestination(destinationFolderID, path: file.path),
                    isFolder: false,
                    isPrivate: false,
                    sourcePath: nil,
                    chunkSize: first.chunkSize,
                    thumbMessageID: importedThumbMID
                )
                try await DatabaseManager.shared.save(object)
                for chunk in chunkRecords {
                    try await DatabaseManager.shared.save(chunk)
                }

                // Incoming record starts as `pending` and flips to `imported` when
                // the user decides — the Shared page hides pending rows.
                try await DatabaseManager.shared.saveShare(ShareRecord(
                    id: UUID().uuidString,
                    objectID: objectID,
                    channelID: channelID,
                    inviteLink: link.inviteLink,
                    shareKey: link.shareKey,
                    expiry: link.expiry,
                    role: "incoming",
                    state: "pending",
                    fileName: resolvedName,
                    createdAt: .now,
                    messageIDs: file.messageIDs.map(String.init).joined(separator: ","),
                    wrappedKeyB64: link.wrappedKeyB64
                ))

                stagedCount += 1
                firstStagedID = firstStagedID ?? objectID
                firstStagedName = firstStagedName ?? resolvedName
                logger.info("Share \(link.id): staged \(resolvedName) (\(chunkRecords.count) chunks) — awaiting import decision")
            }

            // The files' chunks are now copied into our vault — leave the share
            // channel so it doesn't clutter the Telegram chat list (the invite was
            // one-use and is consumed anyway). Only on full success: a failed import
            // may need to retry, and rejoining requires membership.
            try? await TelegramClient.shared.leaveChat(chatId: channelID)

            if stagedCount == 0, let alreadyImportedID {
                // Every file in the link was already in this vault — reveal the
                // existing copy instead of claiming a fresh import.
                return .alreadyImported(objectID: alreadyImportedID)
            }
            guard let firstStagedID else { throw ShareError.invalidPayload }
            logger.info("Share \(link.id): staged \(stagedCount) of \(files.count) file(s)")
            return .pending(objectID: firstStagedID)
        } catch let error as ShareError {
            throw error
        } catch {
            throw ShareError.importFailed(describe(error))
        }
    }

    /// Import decision: catalog a staged (`pendingImport`) file — Finder-style
    /// unique name, state → ready, mirror the vault copies into the backup
    /// channel, incoming record pending → imported. Returns the final name.
    static func confirmImport(objectID: String) async throws -> String {
        guard var object = try await DatabaseManager.shared.object(objectID),
              object.state == "pendingImport" else {
            throw ShareError.invalidPayload
        }
        let finalName = try await Self.uniqueImportName(object.name)
        object.name = finalName
        object.state = "ready"
        try await DatabaseManager.shared.save(object)
        let chunks = (try? await DatabaseManager.shared.chunks(for: objectID)) ?? []
        for chunk in chunks {
            if let mid = chunk.messageID {
                BackupSync.enqueue(messageID: mid, objectID: objectID)
            }
        }
        // One incoming record per imported file so the Shared page lists (and
        // can remove) each file individually.
        if let record = (try? await DatabaseManager.shared.shares(role: "incoming"))?
            .first(where: { $0.objectID == objectID && $0.state == "pending" }) {
            var updated = record
            updated.state = "imported"
            updated.fileName = finalName
            try? await DatabaseManager.shared.saveShare(updated)

            // Multi-file / Folder batch confirmation:
            // If this share was part of a multi-file or folder link (sharing the same inviteLink),
            // confirm and catalog all other pending sibling files in this batch!
            if !record.inviteLink.isEmpty {
                let pendingSiblings = ((try? await DatabaseManager.shared.shares(role: "incoming")) ?? [])
                    .filter { $0.inviteLink == record.inviteLink && $0.state == "pending" && $0.objectID != objectID }
                for sibling in pendingSiblings {
                    if var sibObj = try? await DatabaseManager.shared.object(sibling.objectID),
                       sibObj.state == "pendingImport" {
                        let sibFinalName = try await Self.uniqueImportName(sibObj.name)
                        sibObj.name = sibFinalName
                        sibObj.state = "ready"
                        try? await DatabaseManager.shared.save(sibObj)

                        let sibChunks = (try? await DatabaseManager.shared.chunks(for: sibling.objectID)) ?? []
                        for chunk in sibChunks {
                            if let mid = chunk.messageID {
                                BackupSync.enqueue(messageID: mid, objectID: sibling.objectID)
                            }
                        }

                        var updatedSib = sibling
                        updatedSib.state = "imported"
                        updatedSib.fileName = sibFinalName
                        try? await DatabaseManager.shared.saveShare(updatedSib)
                        logger.info("Pending sibling import \(sibling.objectID): imported as \(sibFinalName)")
                    }
                }
            }
        }
        NotificationCenter.default.post(name: .cascadeUploadFinished, object: nil)
        logger.info("Pending import \(objectID): imported as \(finalName) (\(chunks.count) chunks)")
        return finalName
    }

    /// Import decision: discard a staged file — its forwarded copies are
    /// deleted from the vault channel and every record is dropped. The file
    /// never appears in the catalog.
    static func discardImport(objectID: String) async {
        guard let object = try? await DatabaseManager.shared.object(objectID),
              object.state == "pendingImport" else { return }
        let mids = ((try? await DatabaseManager.shared.chunks(for: objectID)) ?? []).compactMap(\.messageID)
        if !mids.isEmpty, let vault = try? await VaultManager.ensureVault() {
            try? await TelegramClient.shared.deleteMessages(chatId: vault.channelID, messageIds: mids)
        }
        if let record = (try? await DatabaseManager.shared.shares(role: "incoming"))?
            .first(where: { $0.objectID == objectID && $0.state == "pending" }) {
            if !record.inviteLink.isEmpty {
                let pendingSiblings = ((try? await DatabaseManager.shared.shares(role: "incoming")) ?? [])
                    .filter { $0.inviteLink == record.inviteLink && $0.state == "pending" && $0.objectID != objectID }
                for sibling in pendingSiblings {
                    let sibMids = ((try? await DatabaseManager.shared.chunks(for: sibling.objectID)) ?? []).compactMap(\.messageID)
                    if !sibMids.isEmpty, let vault = try? await VaultManager.ensureVault() {
                        try? await TelegramClient.shared.deleteMessages(chatId: vault.channelID, messageIds: sibMids)
                    }
                    try? await DatabaseManager.shared.deleteShare(id: sibling.id)
                    try? await DatabaseManager.shared.deleteObjectWithChunks(id: sibling.objectID)
                }
            }
            try? await DatabaseManager.shared.deleteShare(id: record.id)
        }
        try? await DatabaseManager.shared.deleteObjectWithChunks(id: objectID)
        logger.info("Pending import \(objectID): discarded")
    }

    /// v1 (legacy) import staging: the share channel is a per-share disposable
    /// channel whose messages carry `cascade:share:v1:` captions with a
    /// per-chunk manifest. Kept forever — old links and channels must keep
    /// working. Same stage-then-decide semantics as the v2 path.
    private static func stageLegacyImport(
        link: ShareLink,
        channelID: Int64,
        vault: VaultRecord,
        destinationFolderID: String? = nil
    ) async throws -> ImportOutcome {
        do {
            let messages = try await TelegramClient.shared.shareChannelMessages(chatId: channelID, prefix: captionPrefix)
            let metas = messages.compactMap { ShareEngine.parseChunkMeta($0.caption) }
            guard !metas.isEmpty, let first = metas.first else { throw ShareError.invalidPayload }

            // Same re-import guard as the v2 path: if this exact file (content
            // hash) is already in the vault, reveal it instead of duplicating.
            if let existing = try await Self.existingObject(rootHash: first.rootHash) {
                return .alreadyImported(objectID: existing.id)
            }
            // Positional pairing: shareChannelMessages returns messages ordered by
            // message id, and compactMap preserves order, so index i in one list is
            // index i in the other. Never string-compare a re-encoded caption —
            // JSONEncoder's key order isn't stable across builds, so byte-equality
            // with the original caption would silently mismatch.
            guard metas.count == messages.count else { throw ShareError.invalidPayload }

            // No key layer: the imported chunks are recorded as plaintext. (Legacy
            // v1 shares were always encrypted, but the vault no longer decrypts —
            // the pre-refactor channels were wiped, so no live links remain.)

            // Forward every chunk message into our vault channel (server-side copy).
            let objectID = UUID().uuidString
            let plan = ChunkPlanner.plan(fileSize: first.size, mime: first.mime, chunkSize: first.chunkSize)
            var chunkRecords: [ChunkRecord] = []
            for (message, meta) in zip(messages, metas) {
                let newMessageId = try await TelegramClient.shared.forwardMessage(
                    chatId: vault.channelID,
                    fromChatId: channelID,
                    messageId: message.messageId
                )
                let item = plan.items.first { $0.index == meta.index }
                chunkRecords.append(ChunkRecord(
                    id: UUID().uuidString,
                    objectID: objectID,
                    index: meta.index,
                    size: item?.size ?? meta.size,
                    plainHash: meta.plainHash,
                    cipherHash: nil,
                    state: "uploaded",
                    messageID: newMessageId,
                    fileUniqueID: nil,
                    channelID: vault.channelID,
                    createdAt: .now
                ))
            }
            guard chunkRecords.count == metas.count else { throw ShareError.invalidPayload }

            // Staged, not cataloged: the user decides (Import/Cancel) on the
            // detail screen; backup mirroring happens only on Import.
            let object = ObjectRecord(
                id: objectID,
                vaultID: vault.id,
                name: first.name,
                size: first.size,
                mime: first.mime,
                state: "pendingImport",
                rootHash: first.rootHash.isEmpty ? nil : first.rootHash,
                wrappedKey: nil,
                createdAt: .now,
                modifiedAt: .now,
                isFavorite: false,
                trashed: false,
                parentID: try await Self.resolveImportDestination(destinationFolderID, path: nil),
                isFolder: false,
                isPrivate: false,
                sourcePath: nil,
                chunkSize: first.chunkSize
            )
            try await DatabaseManager.shared.save(object)
            for chunk in chunkRecords {
                try await DatabaseManager.shared.save(chunk)
            }

            let record = ShareRecord(
                id: link.id,
                objectID: objectID,
                channelID: channelID,
                inviteLink: link.inviteLink,
                shareKey: link.shareKey,
                expiry: link.expiry,
                role: "incoming",
                state: "pending",
                fileName: first.name,
                createdAt: .now
            )
            try await DatabaseManager.shared.saveShare(record)

            // Same as the v2 path: once every chunk is forwarded into our vault we
            // no longer need membership in the disposable share channel.
            try? await TelegramClient.shared.leaveChat(chatId: channelID)

            logger.info("Share \(link.id): staged \(first.name) (\(chunkRecords.count) chunks) — awaiting import decision")
            return .pending(objectID: objectID)
        } catch let error as ShareError {
            throw error
        } catch {
            throw ShareError.importFailed(describe(error))
        }
    }


    // MARK: - Import helpers

    /// The recipient's copy of a file this account already holds, matched by
    /// content rootHash (files only — folders carry no hash). Trashed copies are
    /// ignored so a trashed-then-reimported file imports fresh instead of
    /// revealing the trash row.
    private static func existingObject(rootHash: String?) async throws -> ObjectRecord? {
        guard let rootHash, !rootHash.isEmpty else { return nil }
        let objects = try await DatabaseManager.shared.allObjects()
        return objects.first { $0.rootHash == rootHash && !$0.trashed }
    }

    /// Finder-style unique name for imports that land at the root: if a
    /// non-trashed root-level file already uses the name, append " 2", " 3", …
    /// before the extension ("Report.pdf" → "Report 2.pdf"), matching how the
    /// Finder keeps same-named items side by side. Case-insensitive, like Apple.
    private static func uniqueImportName(_ base: String) async throws -> String {
        let objects = try await DatabaseManager.shared.allObjects()
        let taken = Set(objects
            .filter { $0.parentID == nil && !$0.trashed }
            .map { $0.name.lowercased() })
        return uniqueName(base, taken: taken)
    }

    /// Pure name-collision math (unit-tested): returns `base` unchanged when
    /// free, otherwise "Name 2.ext", "Name 3.ext", … skipping every name in
    /// `taken` (compared case-insensitively, like the Finder).
    static func uniqueName(_ base: String, taken: Set<String>) -> String {
        let ext = (base as NSString).pathExtension
        let stem = (base as NSString).deletingPathExtension
        var name = base
        var n = 2
        while taken.contains(where: { $0.lowercased() == name.lowercased() }) {
            name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            n += 1
        }
        return name
    }

    // MARK: - Expiry cleanup (sender side)

    /// Revokes outgoing shares whose expiry has passed. Public shares never
    /// expire (skipped). Expired PRIVATE shares in pool slots follow the same
    /// join/leave semantics as cancelShare — their messages are deleted and the
    /// slot channel is left (row kept, so the next private share rejoins it via
    /// its permanent invite). Legacy v1 disposable channels (no forwarded
    /// copies) are forgotten outright. Runs alongside the transfer cleanup
    /// loop; idempotent.
    static func cleanupExpiredShares() async {
        guard TelegramClient.shared.isAuthorized else { return }
        let shares = (try? await DatabaseManager.shared.shares(role: "outgoing")) ?? []
        for share in shares where share.state == "active"
            && !share.isPublic
            && share.expiry < Foundation.Date() {
            do {
                try await revokeExpired(share)
                logger.info("Share \(share.id): expired — \(share.messageIDs.isEmpty ? "disposable channel deleted" : "forwarded copies revoked")")
            } catch {
                logger.error("Share \(share.id): expiry cleanup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The expiry/revoke path: legacy disposable-channel shares delete the whole
    /// channel; forward-based shares delete the whole dedicated channel when it's
    /// not shared with another active share, else just their own messages.
    private static func revokeExpired(_ share: ShareRecord) async throws {
        if share.messageIDs.isEmpty {
            // Legacy v1 disposable channel: no forwarded copies to revoke and
            // no pool row to reuse — remove the account from it (deleteChat
            // leaves owned channels; it never destroys them) and forget the row.
            try await TelegramClient.shared.deleteChat(chatId: share.channelID)
            if let state = try? await DatabaseManager.shared.shareChannelState(channelID: share.channelID) {
                try? await DatabaseManager.shared.deleteShareChannel(id: state.id)
            }
            return
        }
        let others = ((try? await DatabaseManager.shared.shares(role: "outgoing")) ?? [])
            .filter { $0.id != share.id && $0.state == "active" && $0.channelID == share.channelID }
        let mids = share.messageIDs.split(separator: ",").compactMap { Int64($0) }
        if !mids.isEmpty {
            try await TelegramClient.shared.deleteMessages(chatId: share.channelID, messageIds: mids)
        }
        if others.isEmpty {
            // Pool slot: join/leave, same as cancelShare — leave the channel
            // and KEEP the row so the next private share rejoins the slot via
            // its recorded permanent invite instead of creating a new channel.
            try? await TelegramClient.shared.leaveChat(chatId: share.channelID)
        }
        var updated = share
        updated.state = "revoked"
        try await DatabaseManager.shared.saveShare(updated)
        try? await DatabaseManager.shared.recordShareActivity(ShareActivityRecord(
            id: UUID().uuidString, shareID: share.id, channelID: share.channelID,
            kind: "expired", userID: nil, detail: "Link expired (24h TTL)",
            createdAt: .now
        ))
    }

    // MARK: - Re-share controls (Wave 2 item 9)

    // MARK: - Link obfuscation

    /// Wraps a plaintext share link so it travels as an opaque blob:
    /// `cascade://share#<base64url(key || AES-GCM(link))>`. The random key rides
    /// inside the blob so the recipient's app can unwrap it — this is OBFUSCATION,
    /// not end-to-end secrecy (the link is the credential either way: anyone with
    /// the app could decode it). What it buys: no visible t.me invite, channel id
    /// or key material on Telegram, in chat logs, or to link scanners — and the
    /// link no longer looks like a channel join.
    static func obfuscate(_ plaintext: String) throws -> String {
        let key = SymmetricKey(size: .bits256)
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        guard let combined = sealed.combined else { throw ShareError.invalidLink }
        var blob = key.withUnsafeBytes { Data($0) }
        blob.append(combined)
        return "cascade://share#" + base64URLEncode(blob)
    }

    static func deobfuscate(_ raw: String) throws -> String {
        guard raw.hasPrefix("cascade://share#"), let hash = raw.firstIndex(of: "#") else {
            throw ShareError.invalidLink
        }
        let b64 = String(raw[raw.index(after: hash)...])
        guard let blob = base64URLDecode(b64), blob.count > 32 else { throw ShareError.invalidLink }
        let key = SymmetricKey(data: Data(blob.prefix(32)))
        let box = try AES.GCM.SealedBox(combined: Data(blob.dropFirst(32)))
        let data = try AES.GCM.open(box, using: key)
        guard let text = String(data: data, encoding: .utf8) else { throw ShareError.invalidLink }
        return text
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }

    // MARK: - Helpers

    enum ShareError: Swift.Error, LocalizedError, Equatable, Sendable {
        case notAuthorized, notShareable, notShareablePrivate, sourceUnavailable, invalidLink, expired, invalidPayload
        case privatePoolFull
        case passwordRequired
        case invalidPassword
        case createFailed(String)
        case uploadFailed(String)
        case joinFailed(String)
        case importFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Sign in to Telegram to share files."
            case .notShareable: return "Only files can be shared."
            case .notShareablePrivate: return "Private files can't be shared — move them out of the Private Vault first."
            case .sourceUnavailable: return "This file has no uploaded chunks in the vault to forward."
            case .invalidLink: return "That doesn't look like a valid Cascade share link."
            case .expired: return "This share link has expired."
            case .invalidPayload: return "The share channel doesn't contain a valid Cascade file."
            case .privatePoolFull: return "5 private shares are already active — cancel one on the Shared page, or make this share public instead."
            case .passwordRequired: return "This share is protected by a password."
            case .invalidPassword: return "Incorrect password for this share link."
            case .createFailed(let message): return "Couldn't create the share channel. \(message)"
            case .uploadFailed(let message): return "Forwarding the shared file failed. \(message)"
            case .joinFailed(let message): return "Couldn't join the share channel. \(message)"
            case .importFailed(let message): return "Importing the shared file failed. \(message)"
            }
        }
    }

    /// Pulls the human-readable message out of a TDLibKit error (which otherwise
    /// surfaces as a bare "TDLibKit.Error error N" with no context).
    static func describe(_ error: Swift.Error) -> String {
        if let td = error as? TDLibKit.Error {
            return td.message
        }
        return error.localizedDescription
    }
}