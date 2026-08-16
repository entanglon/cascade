import Foundation
import CryptoKit
import TDLibKit
import os

/// Cloud-to-cloud sharing between two xCloud users.
///
/// Sender: the file's vault chunk messages are FORWARDED (reference copies —
/// zero re-upload, any size) into ONE reusable share channel, joinable via a
/// per-share expiring invite link. Non-private files carry no key at all; private
/// files stay encrypted under the vault object key, which the link carries
/// re-wrapped under a fresh share key. The link is valid until `expiry`, then the
/// cleanup loop deletes JUST that file's messages — the channel persists for the
/// next share.
///
/// Recipient: opening the link joins the channel, reads the exact forwarded
/// messages the link names, forwards each into their OWN vault channel (Telegram
/// copies the document server-side — no re-upload), re-wraps the key under their
/// vault master key, catalogs the file, and leaves.
///
/// Legacy shares (created before v22) used per-share disposable channels with
/// re-encrypted copies and `xcloud:share:v1:` captions — still imported, forever.
enum ShareEngine {
    /// Legacy share-channel caption prefix (pre-v22 disposable channels).
    static let captionPrefix = "xcloud:share:v1:"
    static let defaultLifetime: TimeInterval = 7 * 24 * 3600
    static let reusableChannelTitle = "xCloud Shares"

    private static let logger = Logger(
        subsystem: "com.xcloud.app",
        category: "share"
    )

    // MARK: - Link codec

    /// `xcloud://share?v=2&id=…&ch=…&inv=…&key=…&name=…&exp=…&m=…&w=…`
    /// The `key` (the share secret) is what authorizes the file — the link IS the
    /// credential, so a one-time invite (memberLimit 1) keeps the channel closed
    /// to everyone except whoever holds the link.
    ///
    /// v2 (forward-based, reusable channel): `m` = comma-joined forwarded message
    /// IDs of the file's chunks in the share channel; `w` = the object key wrapped
    /// under the share key, base64 — EMPTY for non-private files. v1 (legacy
    /// disposable channels) has neither and is parsed for backward compatibility.
    struct ShareLink: Equatable, Sendable {
        var id: String
        var channelID: Int64
        var inviteLink: String
        var shareKey: String      // base64
        var fileName: String
        var expiry: Foundation.Date
        var messageIDs: [Int64] = []       // v2
        var wrappedKeyB64: String = ""     // v2, private files only

        var isForwardBased: Bool { !messageIDs.isEmpty }

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
                URLQueryItem(name: "exp", value: String(Int(expiry.timeIntervalSince1970)))
            ]
            if isForwardBased {
                items.append(URLQueryItem(name: "m", value: messageIDs.map(String.init).joined(separator: ",")))
                items.append(URLQueryItem(name: "w", value: wrappedKeyB64))
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
            if version == "2" {
                // Forward-based links: the message IDs name the chunks; the key is
                // only present for private files (wrappedKeyB64 non-empty).
                messageIDs = (q["m"] ?? "").split(separator: ",").compactMap { Int64($0) }
                guard !messageIDs.isEmpty else { return nil }
                wrappedKeyB64 = q["w"] ?? ""
                if !wrappedKeyB64.isEmpty {
                    guard !key.isEmpty else { return nil }
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
                expiry: Foundation.Date(timeIntervalSince1970: TimeInterval(exp)),
                messageIDs: messageIDs,
                wrappedKeyB64: wrappedKeyB64
            )
        }
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

    /// Creates the share (forwarding the vault chunks into the reusable share
    /// channel) and returns the share link. The link (and therefore the file)
    /// lives until `expiry`.
    @discardableResult
    static func share(
        object: ObjectRecord,
        lifetime: TimeInterval = defaultLifetime
    ) async throws -> String {
        guard TelegramClient.shared.isAuthorized else {
            throw ShareError.notAuthorized
        }
        guard !object.isFolder else { throw ShareError.notShareable }

        // Drive-style reuse: a file that already has a LIVE share (active, not yet
        // expired) reuses that link instead of forwarding the chunks again.
        // Sharing the same file twice gives you the same link — no second channel,
        // no double quota spend.
        if let existing = try await reusableShareLink(for: object.id) {
            logger.info("Share: reusing existing link for \(object.name)")
            return existing
        }

        let vault: VaultRecord
        do {
            vault = try await VaultManager.ensureVault()
        } catch {
            throw ShareError.importFailed(describe(error))
        }

        // The source of a forward-based share is the VAULT COPY, not a local file:
        // every chunk must have an uploaded message to forward. (Old records with
        // missing message IDs predate the messageID threshold fix.)
        let chunks = ((try? await DatabaseManager.shared.chunks(for: object.id)) ?? [])
            .sorted { $0.index < $1.index }
        guard !chunks.isEmpty, chunks.allSatisfy({ ($0.messageID ?? 0) > 0 }) else {
            throw ShareError.sourceUnavailable
        }

        // Reusable share channel: created once, archived like the vault, reused by
        // every share. Per-share expiring invite link keeps the one-use semantics.
        let channelID: Int64
        do {
            channelID = try await reusableShareChannel()
        } catch {
            throw ShareError.createFailed(describe(error))
        }
        let inviteLink: String
        do {
            inviteLink = try await TelegramClient.shared.createShareInviteLink(
                chatId: channelID,
                expiresIn: lifetime
            )
        } catch {
            // Channel was created but the invite failed — nothing was forwarded yet.
            try? await retireShareChannelIfEmpty()
            throw ShareError.createFailed(describe(error))
        }

        // Forward each chunk message into the share channel — a reference copy,
        // Telegram copies the document server-side: no re-upload, no size limit.
        var messageIDs: [Int64] = []
        do {
            for chunk in chunks {
                guard let messageID = chunk.messageID else { continue }
                let mid = try await TelegramClient.shared.forwardMessage(
                    chatId: channelID,
                    fromChatId: vault.channelID,
                    messageId: messageID
                )
                messageIDs.append(mid)
            }
            guard messageIDs.count == chunks.count else { throw ShareError.uploadFailed("Partial forward") }
        } catch {
            // Roll back the forwarded copies so the reusable channel stays clean.
            if !messageIDs.isEmpty {
                try? await TelegramClient.shared.deleteMessages(chatId: channelID, messageIds: messageIDs)
            }
            throw ShareError.uploadFailed(describe(error))
        }

        // Keys: only private files carry a key at all. The forwarded chunks are the
        // vault's ciphertext (encrypted under the object key), so the link must
        // carry that object key re-wrapped under a fresh share key. Non-private
        // files: no key anywhere in the link.
        var shareKeyB64 = ""
        var wrappedB64 = ""
        if object.isPrivate, let wk = object.wrappedKey, !wk.isEmpty {
            do {
                let master = try CryptoEngine.masterKey()
                let objectKey = try CryptoEngine.unwrap(wk, with: master)
                let shareKey = SymmetricKey(size: .bits256)
                let wrapped = try CryptoEngine.wrap(objectKey, with: shareKey)
                wrappedB64 = wrapped.base64EncodedString()
                shareKeyB64 = shareKey.withUnsafeBytes { Data($0) }.base64EncodedString()
            } catch {
                try? await TelegramClient.shared.deleteMessages(chatId: channelID, messageIds: messageIDs)
                throw ShareError.uploadFailed("Key re-wrap failed: \(describe(error))")
            }
        }

        let expiry = Foundation.Date().addingTimeInterval(lifetime)
        let plainLink = ShareLink(
            id: UUID().uuidString,
            channelID: channelID,
            inviteLink: inviteLink,
            shareKey: shareKeyB64,
            fileName: object.name,
            expiry: expiry,
            messageIDs: messageIDs,
            wrappedKeyB64: wrappedB64
        ).urlString
        // Hand out the obfuscated form: the link travels as an opaque blob with no
        // visible t.me invite, channel id, or key material. The exact string is
        // stored so reusing this share later returns the IDENTICAL link.
        let finalLink = (try? obfuscate(plainLink)) ?? plainLink
        var record = ShareRecord(
            id: UUID().uuidString,
            objectID: object.id,
            channelID: channelID,
            inviteLink: inviteLink,
            shareKey: shareKeyB64,
            expiry: expiry,
            role: "outgoing",
            state: "active",
            fileName: object.name,
            createdAt: .now
        )
        record.linkBlob = finalLink
        record.messageIDs = messageIDs.map(String.init).joined(separator: ",")
        record.wrappedKeyB64 = wrappedB64
        try await DatabaseManager.shared.saveShare(record)
        logger.info("Share: \(object.name) forwarded (\(messageIDs.count) chunks) into channel \(channelID)")
        return finalLink
    }

    /// The link of this file's most recent LIVE outgoing share (state `active`,
    /// not yet expired, channel still alive), or nil. Re-sharing a file that
    /// already has one returns the SAME link — identical string when the record
    /// stored it, same channel/key/expiry either way — so no second forward is
    /// made.
    static func reusableShareLink(for objectID: String) async throws -> String? {
        let shares = (try? await DatabaseManager.shared.shares(role: "outgoing")) ?? []
        let candidates = shares
            .filter { $0.objectID == objectID && $0.state == "active" && $0.expiry > Foundation.Date() }
            .sorted { $0.expiry > $1.expiry }
        for share in candidates {
            // The record can outlive its channel (deleted manually in Telegram, or
            // a crash between deleteMessages and marking revoked) — never hand out
            // a link whose channel is gone. getChat is served from TDLib's cache, so
            // this is cheap; skipped when Telegram isn't ready (e.g. unit tests).
            if TelegramClient.shared.isAuthorized,
               !(await TelegramClient.shared.chatExists(chatId: share.channelID)) {
                var stale = share
                stale.state = "revoked"
                try? await DatabaseManager.shared.saveShare(stale)
                continue
            }
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

    /// The one reusable outgoing-share channel: returns the recorded one if it
    /// still exists, otherwise creates it (archived + muted, like the vault) and
    /// records it. A channel — not a group — so invites work like the legacy
    /// disposable channels.
    static func reusableShareChannel() async throws -> Int64 {
        if let existing = try? await DatabaseManager.shared.shareChannelID(),
           await TelegramClient.shared.chatExists(chatId: existing) {
            return existing
        }
        let channelID = try await TelegramClient.shared.createShareChannel(title: reusableChannelTitle)
        await TelegramClient.shared.archiveVaultChannel(chatId: channelID)
        try? await DatabaseManager.shared.setShareChannelID(channelID)
        return channelID
    }

    /// Deletes the reusable share channel when it exists and no active outgoing
    /// share uses it anymore (frees the chat list; a future share recreates it).
    static func retireShareChannelIfEmpty() async {
        guard let channelID = try? await DatabaseManager.shared.shareChannelID() else { return }
        let active = (try? await DatabaseManager.shared.shares(role: "outgoing"))?
            .filter { $0.state == "active" } ?? []
        guard active.isEmpty else { return }
        try? await TelegramClient.shared.deleteChat(chatId: channelID)
        try? await DatabaseManager.shared.setShareChannelID(nil)
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
        // IDs for v2 links; legacy links (own disposable channel) match by id.
        let outgoing = (try? await DatabaseManager.shared.shares(role: "outgoing")) ?? []
        let own: ShareRecord? = link.isForwardBased
            ? outgoing.first { $0.messageIDs == link.messageIDs.map(String.init).joined(separator: ",") }
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
    /// codec. Private files decrypt with the object key from the link; non-private
    /// files have no key at all.
    private static func importForwarded(link: ShareLink, channelID: Int64, vault: VaultRecord) async throws -> ImportOutcome {
        do {
            let messages = try await TelegramClient.shared.messagesByIds(chatId: channelID, messageIds: link.messageIDs)
            guard messages.count == link.messageIDs.count else { throw ShareError.invalidPayload }
            var metas: [ChunkCaption.Meta] = []
            for (_, caption) in messages {
                guard let caption, let meta = ChunkCaption.parse(caption) else { throw ShareError.invalidPayload }
                metas.append(meta)
            }
            guard let first = metas.first else { throw ShareError.invalidPayload }

            // Key: private files carry the object key wrapped under the link's
            // share key. The forwarded chunks are the SENDER's vault ciphertext —
            // the caption's own wrappedKey is locked under the sender's master key
            // and is never usable here; the link is the only key source.
            var objectKey: SymmetricKey? = nil
            if !link.wrappedKeyB64.isEmpty {
                let shareKey = SymmetricKey(data: Data(base64Encoded: link.shareKey) ?? Data())
                objectKey = try CryptoEngine.unwrap(
                    Data(base64Encoded: link.wrappedKeyB64) ?? Data(),
                    with: shareKey
                )
            }
            let masterKey = try CryptoEngine.masterKey()

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

            let wrappedForVault: Data?
            if let objectKey {
                wrappedForVault = try CryptoEngine.wrap(objectKey, with: masterKey)
            } else {
                wrappedForVault = nil
            }

            let object = ObjectRecord(
                id: objectID,
                vaultID: vault.id,
                name: first.name,
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
                isPrivate: objectKey != nil,
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
                fileName: first.name,
                createdAt: .now,
                messageIDs: link.messageIDs.map(String.init).joined(separator: ","),
                wrappedKeyB64: link.wrappedKeyB64
            )
            try await DatabaseManager.shared.saveShare(record)

            logger.info("Share \(link.id): imported \(first.name) (\(chunkRecords.count) chunks)")
            NotificationCenter.default.post(name: .xCloudUploadFinished, object: nil)
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
            // Positional pairing: shareChannelMessages returns messages ordered by
            // message id, and compactMap preserves order, so index i in one list is
            // index i in the other. Never string-compare a re-encoded caption —
            // JSONEncoder's key order isn't stable across builds, so byte-equality
            // with the original caption would silently mismatch.
            guard metas.count == messages.count else { throw ShareError.invalidPayload }

            let objectKey = try CryptoEngine.unwrap(
                Data(base64Encoded: first.wrappedKey) ?? Data(),
                with: SymmetricKey(data: Data(base64Encoded: link.shareKey) ?? Data())
            )
            let masterKey = try CryptoEngine.masterKey()

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

            let object = ObjectRecord(
                id: objectID,
                vaultID: vault.id,
                name: first.name,
                size: first.size,
                mime: first.mime,
                state: "ready",
                rootHash: first.rootHash.isEmpty ? nil : first.rootHash,
                wrappedKey: try CryptoEngine.wrap(objectKey, with: masterKey),
                createdAt: .now,
                modifiedAt: .now,
                isFavorite: false,
                trashed: false,
                parentID: nil,
                isFolder: false,
                isPrivate: true,       // legacy shares were always re-keyed under our vault key
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
                fileName: first.name,
                createdAt: .now
            )
            try await DatabaseManager.shared.saveShare(record)

            logger.info("Share \(link.id): imported \(first.name) (\(chunkRecords.count) chunks)")
            NotificationCenter.default.post(name: .xCloudUploadFinished, object: nil)
            return .imported
        } catch let error as ShareError {
            throw error
        } catch {
            throw ShareError.importFailed(describe(error))
        }
    }

    // MARK: - Expiry cleanup (sender side)

    /// Revokes outgoing shares whose expiry has passed: legacy shares delete their
    /// whole disposable channel; v2 shares delete JUST their own forwarded
    /// messages from the reusable channel. Runs alongside the transfer cleanup
    /// loop; idempotent.
    static func cleanupExpiredShares() async {
        guard TelegramClient.shared.isAuthorized else { return }
        let shares = (try? await DatabaseManager.shared.shares(role: "outgoing")) ?? []
        for share in shares where share.state == "active" && share.expiry < Foundation.Date() {
            do {
                if share.messageIDs.isEmpty {
                    try await TelegramClient.shared.deleteChat(chatId: share.channelID)
                    logger.info("Share \(share.id): disposable channel deleted at expiry")
                } else {
                    let ids = share.messageIDs.split(separator: ",").compactMap { Int64($0) }
                    if !ids.isEmpty {
                        try await TelegramClient.shared.deleteMessages(chatId: share.channelID, messageIds: ids)
                    }
                    logger.info("Share \(share.id): \(ids.count) message(s) deleted from reusable channel at expiry")
                }
                var updated = share
                updated.state = "revoked"
                try await DatabaseManager.shared.saveShare(updated)
            } catch {
                logger.error("Share \(share.id): expiry cleanup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // The reusable channel is retired when the last active outgoing share is gone.
        await retireShareChannelIfEmpty()
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

    enum ShareError: Swift.Error, LocalizedError, Sendable {
        case notAuthorized, notShareable, sourceUnavailable, invalidLink, expired, invalidPayload
        case createFailed(String)
        case uploadFailed(String)
        case joinFailed(String)
        case importFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Sign in to Telegram to share files."
            case .notShareable: return "Only files can be shared."
            case .sourceUnavailable: return "This file has no uploaded chunks in the vault to forward."
            case .invalidLink: return "That doesn't look like a valid xCloud share link."
            case .expired: return "This share link has expired."
            case .invalidPayload: return "The share channel doesn't contain a valid xCloud file."
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