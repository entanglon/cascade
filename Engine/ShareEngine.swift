import Foundation
import CryptoKit
import TDLibKit
import os

/// Cloud-to-cloud sharing between two xCloud users.
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
/// re-encrypted copies and `xcloud:share:v1:` captions — still imported, forever.
enum ShareEngine {
    /// Legacy share-channel caption prefix (pre-v22 disposable channels).
    static let captionPrefix = "xcloud:share:v1:"
    static let defaultLifetime: TimeInterval = 7 * 24 * 3600
    /// v24: how many private links can be live at once — each takes a dedicated
    /// channel from the pool (ids 1…privatePoolSize). A pool-full share request
    /// is blocked with a clear error (never silently evicts an older share).
    static let privatePoolSize = 5

    /// Per-slot channel titles, so Telegram shows WHICH channel is which: the
    /// persistent public channel is "xCloud OC" (open channel — home of every
    /// everlasting public link), private pool slots are "xCloud PC1"…"xCloud
    /// PC5" (private channels — one expiring private link each). All of them
    /// are private Telegram channels; the difference is what they carry.
    static func poolChannelTitle(id: Int64, kind: ShareKind) -> String {
        if kind == .public { return "xCloud OC" }
        return "xCloud PC\(id)"
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
        subsystem: "com.xcloud.app",
        category: "share"
    )

    // MARK: - Link codec

    /// `xcloud://share?v=2&id=…&ch=…&inv=…&key=…&name=…&exp=…&m=…&w=…[&f=…]`
    /// The `key` (the share secret) is what authorizes the file — the link IS the
    /// credential, so a one-time invite (memberLimit 1) keeps the channel closed
    /// to everyone except whoever holds the link.
    ///
    /// v2 (forward-based, reusable channel): `m` = comma-joined forwarded message
    /// IDs of the file's chunks in the share channel; `w` = the object key wrapped
    /// under the share key, base64 — EMPTY for non-private files. GROUP shares
    /// (two or more files under one link) additionally carry `f` = a base64url
    /// JSON manifest naming every file with its own message IDs. v1 (legacy
    /// disposable channels) has neither and is parsed for backward compatibility.
    struct ShareLink: Equatable, Sendable {
        var id: String
        var channelID: Int64
        var inviteLink: String
        var shareKey: String      // base64
        var fileName: String
        var expiry: Foundation.Date
        var messageIDs: [Int64] = []       // v2 (flat list; group shares flatten all files)
        var wrappedKeyB64: String = ""     // v2, private files only
        /// Per-file entries. Single-file links synthesize one entry on parse;
        /// group links carry one entry per shared file, each naming that file's
        /// forwarded chunk messages in the share channel.
        var files: [ShareFile] = []

        var isForwardBased: Bool { !files.isEmpty || !messageIDs.isEmpty }
        /// True when the link carries TWO OR MORE files shared together as a group.
        var isGroup: Bool { files.count > 1 }

        var urlString: String {
            var comps = URLComponents()
            comps.scheme = "xcloud"
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
                if isGroup {
                    // Group share: `f` carries the per-file manifest; `m` stays the
                    // flat list so self-open detection and expiry cleanup read
                    // messageIDs unchanged.
                    items.append(URLQueryItem(name: "f", value: Self.encodeFiles(files)))
                    items.append(URLQueryItem(name: "m", value: files.flatMap(\.messageIDs).map(String.init).joined(separator: ",")))
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
            // Obfuscated form: `xcloud://share#<base64url blob>`. Decrypt it back
            // to the plaintext link and parse that — the transported form carries no
            // visible invite link, channel id or key material.
            if trimmed.hasPrefix("xcloud://share#") {
                guard let plain = try? ShareEngine.deobfuscate(trimmed) else { return nil }
                return parse(plain)
            }
            guard let comps = URLComponents(string: trimmed),
                  comps.scheme == "xcloud", comps.host == "share" else { return nil }
            let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            })
            guard let id = q["id"],
                  let chStr = q["ch"], let channelID = Int64(chStr),
                  let invite = q["inv"], !invite.isEmpty,
                  let expStr = q["exp"], let exp = Int64(expStr) else { return nil }
            let version = q["v"] ?? "1"
            let key = q["key"] ?? ""
            var messageIDs: [Int64] = []
            var wrappedKeyB64 = ""
            var files: [ShareFile] = []
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
                    if !wrappedKeyB64.isEmpty {
                        guard !key.isEmpty else { return nil }
                    }
                } else {
                    // Forward-based links: the message IDs name the chunks; the key
                    // is only present for private files (wrappedKeyB64 non-empty).
                    messageIDs = (q["m"] ?? "").split(separator: ",").compactMap { Int64($0) }
                    guard !messageIDs.isEmpty else { return nil }
                    wrappedKeyB64 = q["w"] ?? ""
                    if !wrappedKeyB64.isEmpty {
                        guard !key.isEmpty else { return nil }
                    }
                    // Single-file links synthesize one entry so the import path can
                    // treat every forward-based link uniformly.
                    files = [ShareFile(name: q["name"] ?? "Shared file", messageIDs: messageIDs)]
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
                files: files
            )
        }

        /// Compact per-file manifest for group links: JSON
        /// `[{"n":"name","m":"1,2,3"},…]`, base64url-encoded so it survives any
        /// URL transport untouched.
        static func encodeFiles(_ files: [ShareFile]) -> String {
            struct Payload: Codable {
                var n: String
                var m: String
            }
            let payload = files.map {
                Payload(n: $0.name, m: $0.messageIDs.map(String.init).joined(separator: ","))
            }
            guard let data = try? JSONEncoder().encode(payload) else { return "" }
            return base64URLEncode(data)
        }

        static func decodeFiles(_ raw: String) -> [ShareFile]? {
            struct Payload: Codable {
                var n: String
                var m: String
            }
            guard let data = base64URLDecode(raw),
                  let payload = try? JSONDecoder().decode([Payload].self, from: data) else { return nil }
            let files = payload.map {
                ShareFile(name: $0.n, messageIDs: $0.m.split(separator: ",").compactMap { Int64($0) })
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
    struct ShareFile: Equatable, Sendable, Codable {
        var name: String
        var messageIDs: [Int64]
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
    /// and live in the persistent public channel. Convenience for a single file —
    /// see `share(objects:)`.
    @discardableResult
    static func share(
        object: ObjectRecord,
        lifetime: TimeInterval = defaultLifetime,
        isPublic: Bool = false
    ) async throws -> String {
        try await share(objects: [object], lifetime: lifetime, isPublic: isPublic)
    }

    /// Creates ONE share link for the given files: a single file produces a
    /// normal share; two or more produce a GROUP share — every file's chunks are
    /// forwarded into the same channel under one invite, one link, one expiry, so
    /// the recipient imports them all together from a single link.
    @discardableResult
    static func share(
        objects: [ObjectRecord],
        lifetime: TimeInterval = defaultLifetime,
        isPublic: Bool = false
    ) async throws -> String {
        // Private files can't be shared: the vault no longer encrypts anything, so
        // the private flag is a PIN-gated visibility choice, not a key layer —
        // sharing would leak the file outside the PIN gate. All guards run BEFORE
        // auth (and before any DB access) so the rules are unit-testable without a
        // live Telegram session.
        guard !objects.isEmpty else { throw ShareError.notShareable }
        for object in objects {
            guard !object.isPrivate else { throw ShareError.notShareablePrivate }
            guard !object.isFolder else { throw ShareError.notShareable }
        }
        guard TelegramClient.shared.isAuthorized else {
            throw ShareError.notAuthorized
        }

        // Drive-style reuse: a single file that already has a LIVE share (active,
        // not yet expired) reuses that link instead of forwarding the chunks
        // again; a group whose EXACT object set was shared before reuses that
        // link. Sharing the same selection twice gives you the same link — no
        // second forward, no double quota spend. Reuse is kind-aware: a public
        // share is only reused by another public share (and vice versa).
        if objects.count == 1, let object = objects.first {
            if let existing = try await reusableShareLink(for: object.id, isPublic: isPublic) {
                logger.info("Share: reusing existing \(isPublic ? "public" : "private") link for \(object.name)")
                return existing
            }
        } else if let existing = try await reusableGroupShareLink(for: Set(objects.map(\.id)), isPublic: isPublic) {
            logger.info("Share: reusing existing \(isPublic ? "public" : "private") group link for \(objects.count) files")
            return existing
        }
        return try await forwardShare(objects: objects, lifetime: lifetime, isPublic: isPublic)
    }

    /// The forward path shared by single-file and group shares: validates every
    /// file's chunk availability, forwards each chunk of each file into the pool
    /// channel, and persists the outgoing share record.
    private static func forwardShare(
        objects: [ObjectRecord],
        lifetime: TimeInterval,
        isPublic: Bool
    ) async throws -> String {
        let vault: VaultRecord
        do {
            vault = try await VaultManager.ensureVault()
        } catch {
            throw ShareError.importFailed(describe(error))
        }

        // The source of a forward-based share is the VAULT COPY, not a local file:
        // every chunk must have an uploaded message to forward. (Old records with
        // missing message IDs predate the messageID threshold fix.)
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
        var files: [ShareFile] = []
        do {
            for (object, chunks) in perFileChunks {
                var fileIDs: [Int64] = []
                for chunk in chunks {
                    guard let messageID = chunk.messageID else { continue }
                    let mid = try await TelegramClient.shared.forwardMessage(
                        chatId: channelID,
                        fromChatId: vault.channelID,
                        messageId: messageID
                    )
                    fileIDs.append(mid)
                }
                guard fileIDs.count == chunks.count else { throw ShareError.uploadFailed("Partial forward") }
                files.append(ShareFile(name: object.name, messageIDs: fileIDs))
                allMessageIDs.append(contentsOf: fileIDs)
            }
        } catch {
            // Roll back the forwarded copies so the reusable channel stays clean.
            if !allMessageIDs.isEmpty {
                try? await TelegramClient.shared.deleteMessages(chatId: channelID, messageIds: allMessageIDs)
            }
            throw ShareError.uploadFailed(describe(error))
        }

        // No key layer anymore: the forwarded chunks are plaintext (the vault no
        // longer encrypts file bytes), so the link carries no key material at all.
        let shareKeyB64 = ""
        let wrappedB64 = ""

        // Group links present a combined name; the record also stores every object
        // ID so single-file reuse never hands out a group link and group reuse can
        // match the exact same selection.
        let isGroup = files.count > 1
        let displayName = isGroup ? "\(files.count) files" : (files.first?.name ?? "Shared file")

        // Public shares never expire; private shares live for `lifetime`.
        let expiry = isPublic ? Foundation.Date.distantFuture : Foundation.Date().addingTimeInterval(lifetime)
        let plainLink = ShareLink(
            id: UUID().uuidString,
            channelID: channelID,
            inviteLink: inviteLink,
            shareKey: shareKeyB64,
            fileName: displayName,
            expiry: expiry,
            messageIDs: allMessageIDs,
            wrappedKeyB64: wrappedB64,
            files: isGroup ? files : []
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
        record.wrappedKeyB64 = wrappedB64
        record.isPublic = isPublic
        if isGroup {
            record.groupObjectIDs = objects.map(\.id).joined(separator: ",")
        }
        try await DatabaseManager.shared.saveShare(record)
        logger.info("Share: \(displayName) (\(files.count) file(s), \(allMessageIDs.count) chunks) into channel \(channelID) [\(isPublic ? "public" : "private")]")
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
    /// messages. Live recorded channels are reused; a slot whose channel is gone
    /// (deleted out-of-band) is recreated in place — the app never leaves or
    /// retires owned channels. When all `privatePoolSize` slots are taken by
    /// active shares, throws `privatePoolFull` — never silently evicts.
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
                // Legacy channels (pre-naming) are renamed to their slot title.
                await TelegramClient.shared.renameChatIfNeeded(
                    chatId: state.channelID,
                    title: poolChannelTitle(id: state.id, kind: .private)
                )
                return state
            }
        }
        // Second pass: create a channel in the first slot with no live channel
        // (no recorded row, or a recorded row whose channel is gone).
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
        await TelegramClient.shared.archiveVaultChannel(chatId: channelID)
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

    /// Revokes ONE active outgoing share. Private: the whole dedicated channel
    /// is deleted (instant death, slot freed) unless another active share still
    /// uses it (legacy data shared one channel) — then just that file's messages
    /// go. Public: only that file's messages are deleted from the persistent
    /// channel; the channel lives on for other public shares.
    static func cancelShare(_ share: ShareRecord) async {
        guard share.state == "active" else { return }
        let others = ((try? await DatabaseManager.shared.shares(role: "outgoing")) ?? [])
            .filter { $0.id != share.id && $0.state == "active" && $0.channelID == share.channelID }
        if !share.isPublic, others.isEmpty {
            try? await TelegramClient.shared.deleteChat(chatId: share.channelID)
            // The slot is free again; drop its row so allocation recreates cleanly.
            if let state = try? await DatabaseManager.shared.shareChannelState(channelID: share.channelID) {
                try? await DatabaseManager.shared.deleteShareChannel(id: state.id)
            }
        } else {
            let mids = share.messageIDs.split(separator: ",").compactMap { Int64($0) }
            if !mids.isEmpty {
                try? await TelegramClient.shared.deleteMessages(chatId: share.channelID, messageIds: mids)
            }
        }
        var updated = share
        updated.state = "revoked"
        try? await DatabaseManager.shared.saveShare(updated)
    }

    /// Revokes every active outgoing share (private and public). The public
    /// channel itself persists; each private channel dies with its share.
    static func cancelAllShares() async {
        let shares = (try? await DatabaseManager.shared.shares(role: "outgoing")) ?? []
        for share in shares where share.state == "active" {
            await cancelShare(share)
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
    }

    /// Opens a share link: joins the channel, forwards every chunk into the
    /// recipient's own vault channel, catalogs the file, and leaves. When the
    /// sharer opens their own link, it short-circuits to `.selfOpen` — the file
    /// is already in their cloud, so nothing is imported.
    @discardableResult
    static func importLink(_ rawLink: String) async throws -> ImportOutcome {
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
            return try await importForwarded(link: link, channelID: channelID, vault: vault)
        }
        return try await importLegacy(link: link, channelID: channelID, vault: vault)
    }

    /// v2 import: the link names the file's forwarded messages (the reusable
    /// channel holds many files at once, so only those are touched). Captions are
    /// the vault's own unified/legacy chunk captions — parsed with the shared
    /// codec. Chunks are plaintext (since the encryption drop), so the import is
    /// a pure forward with no key handling.
    private static func importForwarded(link: ShareLink, channelID: Int64, vault: VaultRecord) async throws -> ImportOutcome {
        do {
            // The link names one or more files. Single-file links parse into a
            // one-entry manifest; group links carry one entry per shared file —
            // each entry names that file's forwarded messages in the channel.
            let files = link.files.isEmpty
                ? [ShareFile(name: link.fileName, messageIDs: link.messageIDs)]
                : link.files
            guard files.allSatisfy({ !$0.messageIDs.isEmpty }) else { throw ShareError.invalidPayload }

            var importedCount = 0
            var alreadyImportedID: String?
            var firstImportedName: String?
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

                // No key layer: shared chunks are plaintext, so the import is a pure
                // forward — the vault records the file as plaintext (isPrivate: false).

                // Forward every chunk message into our vault channel (server-side copy).
                let objectID = UUID().uuidString
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
                        cipherHash: nil,
                        state: "uploaded",
                        messageID: newMessageId,
                        fileUniqueID: nil,
                        channelID: vault.channelID,
                        createdAt: .now
                    ))
                }
                guard chunkRecords.count == metas.count else { throw ShareError.invalidPayload }

                let wrappedForVault: Data? = nil
                let finalName = try await Self.uniqueImportName(first.name)

                let object = ObjectRecord(
                    id: objectID,
                    vaultID: vault.id,
                    name: finalName,
                    size: first.size,
                    mime: first.mime,
                    state: "ready",
                    rootHash: first.rootHash,
                    wrappedKey: wrappedForVault,
                    createdAt: .now,
                    modifiedAt: .now,
                    isFavorite: false,
                    trashed: false,
                    parentID: nil,
                    isFolder: false,
                    isPrivate: false,
                    sourcePath: nil,
                    chunkSize: first.chunkSize
                )
                try await DatabaseManager.shared.save(object)
                for chunk in chunkRecords {
                    try await DatabaseManager.shared.save(chunk)
                }

                // One incoming record per imported file so the Shared page lists
                // (and can remove) each file individually.
                let record = ShareRecord(
                    id: UUID().uuidString,
                    objectID: objectID,
                    channelID: channelID,
                    inviteLink: link.inviteLink,
                    shareKey: link.shareKey,
                    expiry: link.expiry,
                    role: "incoming",
                    state: "imported",
                    fileName: finalName,
                    createdAt: .now,
                    messageIDs: file.messageIDs.map(String.init).joined(separator: ","),
                    wrappedKeyB64: link.wrappedKeyB64
                )
                try await DatabaseManager.shared.saveShare(record)

                importedCount += 1
                firstImportedName = firstImportedName ?? finalName
                logger.info("Share \(link.id): imported \(finalName) (\(chunkRecords.count) chunks)")
            }

            // The files' chunks are now copied into our vault — leave the share
            // channel so it doesn't clutter the Telegram chat list (the invite was
            // one-use and is consumed anyway). Only on full success: a failed import
            // may need to retry, and rejoining requires membership.
            try? await TelegramClient.shared.leaveChat(chatId: channelID)

            NotificationCenter.default.post(name: .xCloudUploadFinished, object: nil)
            if importedCount == 0, let alreadyImportedID {
                // Every file in the link was already in this vault — reveal the
                // existing copy instead of claiming a fresh import.
                return .alreadyImported(objectID: alreadyImportedID)
            }
            logger.info("Share \(link.id): imported \(importedCount) of \(files.count) file(s)")
            return .imported
        } catch let error as ShareError {
            throw error
        } catch {
            throw ShareError.importFailed(describe(error))
        }
    }

    /// v1 (legacy) import: the share channel is a per-share disposable channel
    /// whose messages carry `xcloud:share:v1:` captions with a per-chunk manifest.
    /// Kept forever — old links and channels must keep working.
    private static func importLegacy(link: ShareLink, channelID: Int64, vault: VaultRecord) async throws -> ImportOutcome {
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

            let finalName = try await Self.uniqueImportName(first.name)

            let object = ObjectRecord(
                id: objectID,
                vaultID: vault.id,
                name: finalName,
                size: first.size,
                mime: first.mime,
                state: "ready",
                rootHash: first.rootHash.isEmpty ? nil : first.rootHash,
                wrappedKey: nil,
                createdAt: .now,
                modifiedAt: .now,
                isFavorite: false,
                trashed: false,
                parentID: nil,
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
                state: "imported",
                fileName: finalName,
                createdAt: .now
            )
            try await DatabaseManager.shared.saveShare(record)

            // Same as the v2 path: once every chunk is forwarded into our vault we
            // no longer need membership in the disposable share channel.
            try? await TelegramClient.shared.leaveChat(chatId: channelID)

            logger.info("Share \(link.id): imported \(first.name) (\(chunkRecords.count) chunks)")
            NotificationCenter.default.post(name: .xCloudUploadFinished, object: nil)
            return .imported
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
    /// expire (skipped). Expired PRIVATE shares delete their whole dedicated
    /// channel (slot freed) when no other active share uses it, or just their
    /// own messages when the channel is shared (legacy data). Runs alongside
    /// the transfer cleanup loop; idempotent.
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
            try await TelegramClient.shared.deleteChat(chatId: share.channelID)
            if let state = try? await DatabaseManager.shared.shareChannelState(channelID: share.channelID) {
                try? await DatabaseManager.shared.deleteShareChannel(id: state.id)
            }
            return
        }
        let others = ((try? await DatabaseManager.shared.shares(role: "outgoing")) ?? [])
            .filter { $0.id != share.id && $0.state == "active" && $0.channelID == share.channelID }
        if others.isEmpty {
            try await TelegramClient.shared.deleteChat(chatId: share.channelID)
            if let state = try? await DatabaseManager.shared.shareChannelState(channelID: share.channelID) {
                try? await DatabaseManager.shared.deleteShareChannel(id: state.id)
            }
        } else {
            let ids = share.messageIDs.split(separator: ",").compactMap { Int64($0) }
            if !ids.isEmpty {
                try await TelegramClient.shared.deleteMessages(chatId: share.channelID, messageIds: ids)
            }
        }
        var updated = share
        updated.state = "revoked"
        try await DatabaseManager.shared.saveShare(updated)
    }

    // MARK: - Link obfuscation

    /// Wraps a plaintext share link so it travels as an opaque blob:
    /// `xcloud://share#<base64url(key || AES-GCM(link))>`. The random key rides
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
        return "xcloud://share#" + base64URLEncode(blob)
    }

    static func deobfuscate(_ raw: String) throws -> String {
        guard raw.hasPrefix("xcloud://share#"), let hash = raw.firstIndex(of: "#") else {
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
            case .invalidLink: return "That doesn't look like a valid xCloud share link."
            case .expired: return "This share link has expired."
            case .invalidPayload: return "The share channel doesn't contain a valid xCloud file."
            case .privatePoolFull: return "5 private shares are already active — cancel one on the Shared page, or make this share public instead."
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