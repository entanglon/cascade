import Foundation
import CryptoKit
import TDLibKit
import os
import UniformTypeIdentifiers

/// Cloud-to-cloud sharing between two xCloud users.
///
/// Sender: a fresh random key encrypts the file, the encrypted chunks are posted
/// into a brand-new PRIVATE channel (joinable only via its one-use invite link),
/// and a share link carries the secret needed to unwrap the key. The channel stays
/// alive until `expiry`, then the cleanup loop deletes it — so the link is valid
/// for exactly as long as we want, and the sender can be offline the whole time.
///
/// Recipient: opening the link joins the channel, reads the chunk metadata,
/// forwards each message into their OWN vault channel (Telegram copies the
/// document server-side — no re-upload), re-wraps the key under their vault
/// master key, catalogs the file, and leaves the channel.
enum ShareEngine {
    static let captionPrefix = "xcloud:share:v1:"
    static let defaultLifetime: TimeInterval = 7 * 24 * 3600
    /// Expired outgoing channels are deleted by the cleanup loop.
    static let maxChannelTitleLength = 120

    private static let logger = Logger(
        subsystem: "com.xcloud.app",
        category: "share"
    )

    // MARK: - Link codec

    /// `xcloud://share?v=1&id=…&ch=…&inv=…&key=…&name=…&exp=…`
    /// The `key` (the share secret) is what authorizes the file — the link IS the
    /// credential, so a one-time invite (memberLimit 1) keeps the channel closed
    /// to everyone except whoever holds the link.
    struct ShareLink: Equatable, Sendable {
        var id: String
        var channelID: Int64
        var inviteLink: String
        var shareKey: String      // base64
        var fileName: String
        var expiry: Foundation.Date

        var urlString: String {
            var comps = URLComponents()
            comps.scheme = "xcloud"
            comps.host = "share"
            comps.queryItems = [
                URLQueryItem(name: "v", value: "1"),
                URLQueryItem(name: "id", value: id),
                URLQueryItem(name: "ch", value: String(channelID)),
                URLQueryItem(name: "inv", value: inviteLink),
                URLQueryItem(name: "key", value: shareKey),
                URLQueryItem(name: "name", value: fileName),
                URLQueryItem(name: "exp", value: String(Int(expiry.timeIntervalSince1970)))
            ]
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
                  let key = q["key"], !key.isEmpty,
                  let expStr = q["exp"], let exp = Int64(expStr) else { return nil }
            return ShareLink(
                id: id,
                channelID: channelID,
                inviteLink: invite,
                shareKey: key,
                fileName: q["name"] ?? "Shared file",
                expiry: Foundation.Date(timeIntervalSince1970: TimeInterval(exp))
            )
        }
    }

    // MARK: - Manifest (per-chunk caption)

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

    /// Creates the share channel, uploads the encrypted chunks, and returns the
    /// share link. The link (and therefore the file) lives until `expiry`.
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
        // expired) reuses that link instead of creating a fresh channel and
        // re-uploading the chunks. Sharing the same file twice gives you the same
        // link — no second channel, no double quota spend.
        if let existing = try await reusableShareLink(for: object.id) {
            logger.info("Share: reusing existing link for \(object.name)")
            return existing
        }

        do {
            // The share channel is independent of the vault, but make sure the vault
            // exists so a broken storage layer surfaces here, not mid-share.
            _ = try await VaultManager.ensureVault()
        } catch {
            throw ShareError.importFailed(describe(error))
        }

        // Source of the plaintext: the original local file, else the decrypted cache copy.
        let sourceURL: URL
        if let path = object.sourcePath, FileManager.default.fileExists(atPath: path) {
            sourceURL = URL(fileURLWithPath: path)
        } else if DownloadEngine.isCached(object) {
            sourceURL = DownloadEngine.cacheURL(for: object)
        } else {
            throw ShareError.sourceUnavailable
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path(percentEncoded: false))
        guard let sizeNum = attrs[.size] as? NSNumber else { throw ShareError.sourceUnavailable }
        let fileSize = sizeNum.int64Value
        let mime = object.mime
        let plan = ChunkPlanner.plan(fileSize: fileSize, mime: mime)
        guard !plan.items.isEmpty else { throw ShareError.notShareable }
        let rootHash = try FileHasher.sha256(of: sourceURL)

        // Channel + one-use invite link.
        let title = "xCloud \u{00B7} \(object.name)"
        let channelID: Int64
        do {
            channelID = try await TelegramClient.shared.createShareChannel(title: String(title.prefix(maxChannelTitleLength)))
        } catch {
            // Surface the real TDLib reason ("error 1" says nothing).
            throw ShareError.createFailed(describe(error))
        }
        let inviteLink: String
        do {
            inviteLink = try await TelegramClient.shared.createShareInviteLink(
                chatId: channelID,
                expiresIn: lifetime
            )
        } catch {
            // Channel was created but the invite failed — don't leave an orphan behind.
            try? await TelegramClient.shared.deleteChat(chatId: channelID)
            throw ShareError.createFailed(describe(error))
        }

        // Fresh random keys: the object key encrypts the file; the share key wraps
        // the object key and rides inside the link.
        let shareKey = SymmetricKey(size: .bits256)
        let objectKey = SymmetricKey(size: .bits256)
        let wrappedObjectKey = try CryptoEngine.wrap(objectKey, with: shareKey)
        let shareKeyB64 = shareKey.withUnsafeBytes { Data($0) }.base64EncodedString()
        let wrappedB64 = wrappedObjectKey.base64EncodedString()

        // Encrypt each chunk into a temp file and post it to the channel.
        let shareID = UUID().uuidString
        let tmpDir = try tempDirectory()
        var messageIDs: [(index: Int, messageId: Int64)] = []
        let tmpPaths: [URL] = plan.items.map { _ in tmpDir.appendingPathComponent(UUID().uuidString) }

        do {
            for (i, item) in plan.items.enumerated() {
                let tmpURL = tmpPaths[i]
                let plain = try readFileSlice(sourceURL, offset: item.offset, count: Int(item.size))
                let plainHash = FileHasher.sha256(of: plain)
                var encrypted = Data()
                encrypted.reserveCapacity(plain.count + 64)
                var offset = 0
                var sliceIndex = 0
                while offset < plain.count {
                    let end = min(offset + CryptoEngine.sliceSize, plain.count)
                    let sealed = try CryptoEngine.encryptSlice(plain.subdata(in: offset..<end), objectKey: objectKey, index: sliceIndex)
                    encrypted.append(sealed)
                    offset = end
                    sliceIndex += 1
                }
                try encrypted.write(to: tmpURL)

                let meta = ChunkMeta(
                    index: item.index,
                    totalChunks: plan.items.count,
                    name: object.name,
                    size: fileSize,
                    mime: mime,
                    wrappedKey: wrappedB64,
                    rootHash: rootHash,
                    chunkSize: plan.chunkSize,
                    plainHash: plainHash
                )
                // No content protection on the chunk posts: the recipient must be
                // able to forward them into their own vault. (The recipient's copy
                // gets protectContent: true via forwardMessage.)
                let messageId = try await TelegramClient.shared.sendFile(
                    chatId: channelID,
                    path: tmpURL.path(percentEncoded: false),
                    kind: .document,
                    caption: caption(for: meta),
                    protectContent: false,
                    onProgress: nil
                )
                messageIDs.append((item.index, messageId))
                logger.info("Share \\(shareID): chunk \\(item.index)/\\(plan.items.count) posted")
            }
        } catch {
            // Clean up the channel so a failed share leaves no orphan behind.
            try? await TelegramClient.shared.deleteChat(chatId: channelID)
            throw ShareError.uploadFailed(describe(error))
        }
        defer {
            for url in tmpPaths { try? FileManager.default.removeItem(at: url) }
        }

        let expiry = Foundation.Date().addingTimeInterval(lifetime)
        let plainLink = ShareLink(
            id: shareID,
            channelID: channelID,
            inviteLink: inviteLink,
            shareKey: shareKeyB64,
            fileName: object.name,
            expiry: expiry
        ).urlString
        // Hand out the obfuscated form: the link travels as an opaque blob with no
        // visible t.me invite, channel id, or key material. The exact string is
        // stored so reusing this share later returns the IDENTICAL link.
        let finalLink = (try? obfuscate(plainLink)) ?? plainLink
        var record = ShareRecord(
            id: shareID,
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
        try await DatabaseManager.shared.saveShare(record)
        return finalLink
    }

    /// The share link of this file's most recent LIVE outgoing share (state
    /// `active`, not yet expired, channel still alive), or nil if the file has no
    /// reusable link. Re-sharing a file that already has one returns the SAME
    /// link — identical string when the record stored it, same channel/key/expiry
    /// either way — so no second copy is uploaded.
    static func reusableShareLink(for objectID: String) async throws -> String? {
        let shares = (try? await DatabaseManager.shared.shares(role: "outgoing")) ?? []
        let candidates = shares
            .filter { $0.objectID == objectID && $0.state == "active" && $0.expiry > Foundation.Date() }
            .sorted { $0.expiry > $1.expiry }
        for share in candidates {
            // The record can outlive its channel (deleted manually in Telegram, or
            // a crash between deleteChat and marking revoked) — never hand out a
            // link whose channel is gone. getChat is served from TDLib's cache, so
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
                expiry: share.expiry
            ).urlString
            return (try? obfuscate(plain)) ?? plain
        }
        return nil
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
        // copy is still valid until expiry.)
        let outgoing = (try? await DatabaseManager.shared.shares(role: "outgoing")) ?? []
        if let own = outgoing.first(where: { $0.channelID == link.channelID }) {
            if let object = try? await DatabaseManager.shared.object(own.objectID) {
                return .selfOpen(objectID: object.id)
            }
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
                isPrivate: true,       // always re-keyed under our vault key
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

            logger.info("Share \\(link.id): imported \\(first.name) (\\(chunkRecords.count) chunks)")
            NotificationCenter.default.post(name: .xCloudUploadFinished, object: nil)
            return .imported
        } catch let error as ShareError {
            throw error
        } catch {
            throw ShareError.importFailed(describe(error))
        }
    }

    // MARK: - Expiry cleanup (sender side)

    /// Deletes outgoing share channels whose expiry has passed. Runs alongside the
    /// transfer cleanup loop; idempotent.
    static func cleanupExpiredShares() async {
        guard TelegramClient.shared.isAuthorized else { return }
        let shares = (try? await DatabaseManager.shared.shares(role: "outgoing")) ?? []
        for share in shares where share.state == "active" && share.expiry < Foundation.Date() {
            do {
                try await TelegramClient.shared.deleteChat(chatId: share.channelID)
                var updated = share
                updated.state = "revoked"
                try await DatabaseManager.shared.saveShare(updated)
                logger.info("Share \\(share.id): channel deleted at expiry")
            } catch {
                logger.error("Share \\(share.id): expiry cleanup failed: \\(error.localizedDescription, privacy: .public)")
            }
        }
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
            case .sourceUnavailable: return "The original file is no longer available on this Mac."
            case .invalidLink: return "That doesn't look like a valid xCloud share link."
            case .expired: return "This share link has expired."
            case .invalidPayload: return "The share channel doesn't contain a valid xCloud file."
            case .createFailed(let message): return "Couldn't create the share channel. \(message)"
            case .uploadFailed(let message): return "Uploading the shared file failed. \(message)"
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

    static func tempDirectory() throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appendingPathComponent("xCloud/share-tmp", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func readFileSlice(_ url: URL, offset: Int64, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let data = handle.readData(ofLength: count)
        guard data.count == count else { throw ShareError.sourceUnavailable }
        return data
    }
}
