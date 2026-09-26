import Foundation
import GRDB

// MARK: - Accounts

struct AccountRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: String
    var telegramUserID: Int64
    var displayName: String
    var state: String
    var createdAt: Date
}

extension AccountRecord {
    static let databaseTableName = "accounts"
}

// MARK: - Vaults

struct VaultRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: String
    var accountID: String
    var channelID: Int64
    var name: String
    /// Legacy column from the encryption era. Files are now stored as plain
    /// bytes, so this is always empty; the column remains NOT NULL for schema
    /// stability (old databases still open without a migration).
    var wrappedKey: Data
    var createdAt: Date
    /// Channel ID of the "Cascade Backup" channel: every message the app
    /// posts to the vault (Saved Messages) is forwarded here (Engine/BackupSync.swift),
    /// so the files survive even if the account's chat data is ever lost.
    var backupChannelID: Int64? = nil
}

// MARK: - Backup mirror queue

/// One row per vault-channel message that must be mirrored into the backup channel
/// (or has already been mirrored). `messageID` is the vault-channel message id;
/// `backupMessageID` is filled once the forward succeeds.
struct BackupMsgRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var messageID: Int64
    var objectID: String
    var backupMessageID: Int64? = nil
    var status: String
    var attempts: Int
    var createdAt: Date

    var id: Int64 { messageID }
}

extension BackupMsgRecord {
    static let databaseTableName = "backup_msgs"
}

extension VaultRecord {
    static let databaseTableName = "vaults"
}

// MARK: - Objects

struct ObjectRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: String
    var vaultID: String
    var name: String
    var size: Int64
    var mime: String
    var state: String
    var rootHash: String?
    var wrappedKey: Data?
    var createdAt: Date
    var modifiedAt: Date
    var isFavorite: Bool = false
    var trashed: Bool = false
    var parentID: String? = nil
    var isFolder: Bool = false
    var isPrivate: Bool = false
    var sourcePath: String? = nil
    var chunkSize: Int64? = nil
    /// Archived files are hidden from every default view and smart folder; they
    /// only appear on the Archive destination (Gmail-style decluttering without
    /// deletion). Synced through the catalog snapshot + chunk-caption metadata.
    var isArchived: Bool = false
    /// Opt-in membership in the Library (books destination). Ambiguous formats —
    /// PDF/TXT/MD — are only "books" when the user adds them; EPUB/CBZ/CBR are
    /// always books. Synced through the catalog snapshot + chunk-caption metadata.
    var isInLibrary: Bool = false
    /// Album/playlist cover: the object whose thumbnail represents this folder
    /// in the Photos/Videos collections. Auto-set to the first photo moved in,
    /// manually changeable. Synced like the other flags.
    var coverObjectID: String? = nil
    /// Telegram messageID of the object's encrypted thumbnail sidecar document
    /// (encrypted uploads only). The sidecar replaced the plaintext attached
    /// thumbnail: it is an opaque encrypted file in the vault channel, and
    /// ThumbnailService downloads + decrypts it to restore the preview after a
    /// local cache clear. nil → pre-sidecar uploads (attached thumbnail path).
    var thumbMessageID: Int64? = nil
    /// Deletion tombstone timestamp: when an object is permanently deleted,
    /// tombstoneAt is set. Deltas and checkpoints carry the tombstone to prevent
    /// deleted objects from being resurrected on delta replay or multi-device sync.
    var tombstoneAt: Date? = nil
    /// Sidecar subtitle files attached to this video, JSON-encoded as a
    /// `[SubtitleSidecar]` array (GRDB TEXT column) so old rows decode to nil.
    /// Synced through the catalog snapshot like every other ObjectRecord field.
    var subtitleSidecars: String? = nil
    /// Offline pin ("Keep Downloaded"): the object keeps a complete decrypted
    /// copy in scratch that is exempt from cache eviction AND the launch wipe,
    /// so it opens with no network. DEVICE-LOCAL by design — CatalogSnapshot
    /// strips it from remote records on merge/restore (a pin on one Mac must
    /// not silently download gigabytes on another). Folders pin recursively
    /// (the flag lives on every descendant object row).
    var isPinned: Bool = false

    // Custom decoding so records missing newer fields (old catalog snapshots in the
    // channel, or rows read before a migration) still decode — every optional-ish
    // flag falls back to its default instead of throwing.
    enum CodingKeys: String, CodingKey {
        case id, vaultID, name, size, mime, state, rootHash, wrappedKey, createdAt, modifiedAt
        case isFavorite, trashed, parentID, isFolder, isPrivate, sourcePath, chunkSize, isArchived, isInLibrary, coverObjectID, thumbMessageID, tombstoneAt
        case subtitleSidecars
        case isPinned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        vaultID = try c.decode(String.self, forKey: .vaultID)
        name = try c.decode(String.self, forKey: .name)
        size = try c.decode(Int64.self, forKey: .size)
        mime = try c.decode(String.self, forKey: .mime)
        state = try c.decode(String.self, forKey: .state)
        rootHash = try c.decodeIfPresent(String.self, forKey: .rootHash)
        wrappedKey = try c.decodeIfPresent(Data.self, forKey: .wrappedKey)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        modifiedAt = try c.decode(Date.self, forKey: .modifiedAt)
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        trashed = try c.decodeIfPresent(Bool.self, forKey: .trashed) ?? false
        parentID = try c.decodeIfPresent(String.self, forKey: .parentID)
        isFolder = try c.decodeIfPresent(Bool.self, forKey: .isFolder) ?? false
        isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        sourcePath = try c.decodeIfPresent(String.self, forKey: .sourcePath)
        chunkSize = try c.decodeIfPresent(Int64.self, forKey: .chunkSize)
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        isInLibrary = try c.decodeIfPresent(Bool.self, forKey: .isInLibrary) ?? false
        coverObjectID = try c.decodeIfPresent(String.self, forKey: .coverObjectID)
        thumbMessageID = try c.decodeIfPresent(Int64.self, forKey: .thumbMessageID)
        tombstoneAt = try c.decodeIfPresent(Date.self, forKey: .tombstoneAt)
        subtitleSidecars = try c.decodeIfPresent(String.self, forKey: .subtitleSidecars)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }

    // Explicit memberwise init (matching the old synthesized one, in property
    // order) so existing call sites keep working now that `init(from:)` is custom.
    init(
        id: String,
        vaultID: String,
        name: String,
        size: Int64,
        mime: String,
        state: String,
        rootHash: String? = nil,
        wrappedKey: Data? = nil,
        createdAt: Date,
        modifiedAt: Date,
        isFavorite: Bool = false,
        trashed: Bool = false,
        parentID: String? = nil,
        isFolder: Bool = false,
        isPrivate: Bool = false,
        sourcePath: String? = nil,
        chunkSize: Int64? = nil,
        isArchived: Bool = false,
        isInLibrary: Bool = false,
        coverObjectID: String? = nil,
        thumbMessageID: Int64? = nil,
        tombstoneAt: Date? = nil,
        subtitleSidecars: String? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.vaultID = vaultID
        self.name = name
        self.size = size
        self.mime = mime
        self.state = state
        self.rootHash = rootHash
        self.wrappedKey = wrappedKey
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isFavorite = isFavorite
        self.trashed = trashed
        self.parentID = parentID
        self.isFolder = isFolder
        self.isPrivate = isPrivate
        self.sourcePath = sourcePath
        self.chunkSize = chunkSize
        self.isArchived = isArchived
        self.isInLibrary = isInLibrary
        self.coverObjectID = coverObjectID
        self.thumbMessageID = thumbMessageID
        self.tombstoneAt = tombstoneAt
        self.subtitleSidecars = subtitleSidecars
        self.isPinned = isPinned
    }
}

// MARK: - Subtitle sidecars

/// One sidecar subtitle document linked to a video object. `messageID` is the
/// vault-channel message carrying the (optionally encrypted) subtitle bytes;
/// `name` is the original file name ("Movie.en.srt") used as the track title.
struct SubtitleSidecar: Codable, Equatable, Sendable {
    var messageID: Int64
    var name: String
}

extension ObjectRecord {
    /// Decoded sidecar list (empty when the JSON column is nil/corrupt).
    var subtitleList: [SubtitleSidecar] {
        guard let json = subtitleSidecars, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([SubtitleSidecar].self, from: data)) ?? []
    }

    /// Encodes a sidecar list for the `subtitleSidecars` column.
    static func encodedSubtitles(_ list: [SubtitleSidecar]) -> String? {
        guard !list.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(list) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension ObjectRecord {
    static let databaseTableName = "objects"

    /// Any file the reader can open, regardless of Library membership.
    var isBookFile: Bool {
        guard !isFolder else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["epub", "pdf", "txt", "md", "markdown", "cbz", "cbr"].contains(ext)
    }

    /// Formats that are unambiguously books (self-contained book packaging).
    var isHardBook: Bool {
        guard !isFolder else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["epub", "cbz", "cbr"].contains(ext)
    }

    /// Book formats the Library destination collects. EPUB/CBZ/CBR are always
    /// books; PDF/TXT/MD only count when the user explicitly added them to the
    /// Library — so document-style PDFs never sneak into the bookshelf.
    var isBook: Bool {
        isHardBook || (isBookFile && isInLibrary)
    }

    var isPhoto: Bool {
        guard !isFolder else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return mime.hasPrefix("image/") || ["jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp", "svg", "raw", "cr2", "nef", "arw", "dng"].contains(ext)
    }

    var isVideo: Bool {
        guard !isFolder else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return mime.hasPrefix("video/") || ["mp4", "mov", "m4v", "mkv", "avi", "webm", "3gp", "mpg", "mpeg", "ts", "flv", "wmv", "vob", "ogv"].contains(ext)
    }

    var isAudio: Bool {
        guard !isFolder else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return mime.hasPrefix("audio/") || ["mp3", "m4a", "wav", "flac", "aac", "ogg", "wma", "opus", "aiff", "alac"].contains(ext)
    }

    /// Sidecar subtitle formats mpv consumes directly.
    static let subtitleExtensions = ["srt", "ass", "ssa", "vtt", "sub"]

    var isSubtitleFile: Bool {
        guard !isFolder else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return Self.subtitleExtensions.contains(ext)
    }
}

// MARK: - Chunks

struct ChunkRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: String
    var objectID: String
    var index: Int
    var size: Int64
    var plainHash: String?
    var cipherHash: String?
    var state: String
    var messageID: Int64?
    var fileUniqueID: String?
    var channelID: Int64?
    var createdAt: Date
}

extension ChunkRecord {
    static let databaseTableName = "chunks"
}

// MARK: - Transfers

/// Persisted history of finished transfers (complete/failed), restored into
/// TransferCenter on launch. Active/paused transfers stay in-memory only — they
/// are tied to live tasks that cannot outlive the process.
struct TransferRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: String
    var objectID: String
    var name: String
    var direction: String   // "upload" | "download"
    var state: String       // "active" | "paused" | "complete" | "failed"
    var progress: Double
    var statusText: String
    var totalWork: Double
    var errorMessage: String?
    var startedAt: Date?
    var finishedAt: Date?
}

extension TransferRecord {
    static let databaseTableName = "transfers"
}

// MARK: - Shares

/// A cloud-to-cloud share. `outgoing` rows are created by the sender (the share
/// channel lives until `expiry`, then is deleted by the cleanup loop); `incoming`
/// rows are created by the recipient when a link is imported (the file was
/// forwarded into their own vault).
struct ShareRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: String
    var objectID: String          // sender: source file; recipient: new vault object
    var channelID: Int64          // the share channel (reusable since v22)
    var inviteLink: String        // Telegram invite link (join credential)
    var shareKey: String          // base64 share key — the link secret
    var expiry: Date
    var role: String              // "outgoing" | "incoming"
    var state: String             // "active" | "revoked" | "imported"
    var fileName: String
    var createdAt: Date
    /// The exact link string handed out when this share was created. Reusing a
    /// live share returns this verbatim, so re-sharing a file always yields the
    /// IDENTICAL link (re-obfuscating would produce a different-looking blob for
    /// the same underlying share). Nil for records created before v15 — those
    /// reconstruct the link from their fields instead.
    var linkBlob: String? = nil
    /// v22+: comma-separated message IDs of the file's chunks FORWARDED into the
    /// share channel (zero re-upload). Empty for legacy shares, which instead own
    /// a whole disposable channel deleted at expiry.
    var messageIDs: String = ""
    /// v22+: the object key wrapped under the share key (base64) — only for
    /// private files; the forwarded chunks stay encrypted under the vault object
    /// key, so the link must carry it. Empty for non-private files.
    var wrappedKeyB64: String = ""
    /// v23+: comma-separated object IDs of a GROUP share (2+ files shared under
    /// ONE link). Empty for single-file shares, and empty on incoming records
    /// (each imported file gets its own record). Lets single-file reuse never
    /// hand out a group link and lets group reuse match the exact same selection.
    var groupObjectIDs: String = ""
    /// v24+: true for PUBLIC shares — the link never expires and lives in the
    /// persistent public channel; false for private shares (dedicated pool
    /// channel, expiring one-use invite). Always false on incoming records.
    var isPublic: Bool = false
    /// v25+: archived shares are hidden from the Shared page but the link
    /// still works. The share record and channel messages are untouched.
    var isArchived: Bool = false
}

// MARK: - Share channel pool (v24)

/// One channel from the share-channel pool. PRIVATE shares each take a dedicated
/// slot (ids 1…5): a channel per share so a holder of one private link can never
/// see other files' messages. PUBLIC shares all share the single persistent
/// channel (id 100); its permanent invite is stored here and every public link
/// embeds it. The app never leaves or retires owned channels — a missing channel
/// (deleted out-of-band) is recreated in the same slot.
struct ShareChannelState: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: Int64           // 1…5 = private pool slots; 100 = the public channel
    var channelID: Int64
    var kind: String        // "private" | "public"
    /// Permanent reclaim invite — for the public channel this is also the invite
    /// every public share link embeds; never handed out directly.
    var inviteLink: String = ""
    var createdAt: Date = .now

    static let databaseTableName = "share_state"
}

extension ShareRecord {
    static let databaseTableName = "shares"
}

// MARK: - People & Faces (on-device photo intelligence)

/// A recognized person (cluster of face embeddings). `name` is user-entered;
/// unnamed people show as "Person N". Local-only — faces are derived, private
/// data and deliberately never sync to Telegram or another device.
struct PersonRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: String
    var name: String
    var createdAt: Date
}

extension PersonRecord {
    static let databaseTableName = "people"
}

/// One detected face inside a photo: the normalized bounding box, capture
/// quality, the 2048-dim VNGenerateImageFeaturePrintRequest featureprint of the
/// tight face crop (stored as raw little-endian float32 data) and the person
/// cluster it belongs to (nil while unmatched). The face thumbnail lives in the
/// app-support faces dir as `<objectID>-<faceID>.jpg`.
struct FaceRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Hashable {
    var id: String
    var objectID: String
    var personID: String? = nil
    var boxX: Double = 0   // normalized (Vision space, bottom-left origin)
    var boxY: Double = 0
    var boxW: Double = 0
    var boxH: Double = 0
    var quality: Double = 0
    var vectorData: Data = Data()
    var createdAt: Date
}

extension FaceRecord {
    static let databaseTableName = "faces"
    static let faceThumbDirectory = "faces"
}

// MARK: - Object Versions (Version History)

struct ObjectVersionRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: String
    var objectID: String
    var versionNumber: Int
    var rootHash: String?
    var size: Int64
    var modifiedAt: Date
    var chunksJSON: String?
    var createdAt: Date
}

extension ObjectVersionRecord {
    static let databaseTableName = "object_versions"
}

// MARK: - Finder mirror (Wave 2 item 3)

/// One row per file paired between the Finder mirror folder and its cloud
/// counterpart (two-way sync folder, flat v1). Holds the SYNCED BASELINE —
/// sizes and modification dates of both sides at reconciliation time — so the
/// next pass can tell who changed since ("hash-based change detection": size +
/// mtime + remote modifiedAt; rootHash rides along when known). Local-only
/// state; never synced to Telegram.
struct MirrorStateRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    /// == objectID (the cloud object this local file mirrors).
    var id: String
    var name: String
    var size: Int64
    var remoteModifiedAt: Date
    var localModifiedAt: Date
    var rootHash: String?
    var lastSyncedAt: Date
}

extension MirrorStateRecord {
    static let databaseTableName = "mirror_state"
}

// MARK: - Share activity log (Wave 2 item 9)

/// One row per observed sharing event, newest-first lists on the Shared page's
/// Activity sheet. Kinds: `created` (link minted), `join` (a recipient joined
/// the share channel — `userID` carries their Telegram user when known;
/// public-channel joins carry `shareID = ""` because every public link shares
/// one channel), `revoked` (manual cancel), `expired` (TTL cleanup),
/// `cancel_on_use` (private one-use semantics fired).
struct ShareActivityRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: String
    var shareID: String
    var channelID: Int64
    var kind: String
    var userID: Int64?
    var detail: String
    var createdAt: Date
}

extension ShareActivityRecord {
    static let databaseTableName = "share_activity"
}

extension Notification.Name {
    static let cascadeAppNotification = Notification.Name("cascadeAppNotification")
    static let xcThumbnailReady = Notification.Name("xc.thumbnailReady")
}

enum AppPaths {
    static var dataFolder: String {
        // Release builds live in their own data folder, isolated from Debug:
        // legacy ".prod"-suffixed IDs and the current com.entanglon.cascade.
        let id = Bundle.main.bundleIdentifier ?? ""
        if id.hasSuffix(".prod") || id == "com.entanglon.cascade" {
            return "Cascade-Prod"
        }
        return "Cascade"
    }
}

#if canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#endif
