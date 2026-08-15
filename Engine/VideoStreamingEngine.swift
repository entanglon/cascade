import Foundation
import UniformTypeIdentifiers
import CryptoKit
import os

/// Byte-range streaming from the Telegram-backed vault — mpv only. There is NO
/// AVFoundation anywhere in this app: mpv (libmpv + FFmpeg) demuxes every container
/// from the local byte-range HTTP server (`VaultStreamServer`), which this engine
/// feeds with decrypted plaintext slices.
///
/// Layout model (why the arithmetic works):
/// - A file is split into chunk documents whose sizes are multiples of the 1 MB slice
///   size (except the final chunk), so no slice ever straddles two chunks.
/// - Public files: chunk ciphertext == chunk plaintext; ranges map 1:1.
/// - Private files: each 1 MB plaintext slice is AES-GCM sealed into
///   `sealedSliceSize = sliceSize + 28` bytes (12 B nonce + 16 B tag) with a *per-chunk*
///   slice index starting at 0. GCM cannot be opened from mid-box, so a fetch always
///   starts at a slice boundary and pulls the FULL sealed slice, then we trim in memory.
final class VideoStreamingEngine {
    static let shared = VideoStreamingEngine()

    private static let logger = Logger(subsystem: "com.xcloud.app", category: "stream")

    private let stateLock = NSLock()
    private var layouts: [String: ObjectLayout] = [:]
    private var fileIDs: [String: [Int: Int]] = [:] // objectID -> [chunkIndex: TDLib file id]
    private var fetchers: [String: ObjectFetcher] = [:]
    private let sliceCache = SliceCache()
    // In-flight layout loads, so concurrent callers (theater's play() kickoff +
    // the same file's stream-URL resolve) share ONE network fetch instead of
    // each hitting Telegram per chunk.
    private var loadingLayouts: [String: Task<ObjectLayout?, Error>] = [:]

    // MARK: - Public

    /// Returns a playable mpv stream URL for any container with a loadable layout
    /// (mpv/FFmpeg demuxes what AVFoundation can't — mkv, webm, avi, ...). The URL
    /// points at the local byte-range server, which serves decrypted plaintext.
    /// Returns nil for cached files (the caller plays the local file directly via
    /// mpv) or unloadable layouts.
    func mpvStreamURL(for object: ObjectRecord) async -> URL? {
        if DownloadEngine.isCached(object) { return nil }
        guard let layout = try? await loadLayout(objectID: object.id), layout.fileSize > 0 else {
            return nil
        }
        return await VaultStreamServer.shared.streamURL(for: object.id)
    }

    // MARK: - Slice serving

    private func plaintextSlice(
        _ fileSliceIndex: Int,
        objectID: String,
        layout: ObjectLayout,
        fetcher: ObjectFetcher
    ) async throws -> Data {
        let cacheKey = SliceCache.Key(objectID: objectID, sliceIndex: fileSliceIndex)
        if let cached = sliceCache.get(cacheKey) { return cached }

        let (chunkIndex, localSliceIndex) = layout.chunkAndLocalIndex(for: fileSliceIndex)
        let chunk = layout.chunks[chunkIndex]
        let fileID = try await fileID(for: objectID, chunkIndex: chunkIndex, layout: layout)

        let slicePlainOffset = Int64(localSliceIndex) * Int64(CryptoEngine.sliceSize)
        let slicePlainSize = min(Int64(CryptoEngine.sliceSize), chunk.plainSize - slicePlainOffset)

        if layout.isPrivate {
            guard let key = layout.objectKey else { throw DownloadError.fileNotFound }
            // Fetch the FULL sealed slice from its boundary — GCM can't open mid-box.
            let cipherOffset = Int64(localSliceIndex) * Int64(CryptoEngine.sealedSliceSize)
            let cipherLength = slicePlainSize + 28
            let sealed = try await fetchWithRetry(
                fetcher, fileID: fileID, offset: cipherOffset, limit: cipherLength, objectID: objectID
            )
            let plain = try CryptoEngine.decryptSlice(sealed, objectKey: key, index: localSliceIndex)
            sliceCache.put(cacheKey, plain)
            return plain
        } else {
            let raw = try await fetchWithRetry(
                fetcher, fileID: fileID, offset: slicePlainOffset, limit: slicePlainSize, objectID: objectID
            )
            sliceCache.put(cacheKey, raw)
            return raw
        }
    }

    /// Incrementally yields the plaintext bytes covering `start..<start+length` as
    /// decrypted 1 MB slices, so a full-file GET never buffers the whole movie.
    /// Used by the local HTTP server that feeds mpv.
    func plaintextSliceStream(
        objectID: String,
        start: Int64,
        length: Int64,
        layout: ObjectLayout,
        fetcher: ObjectFetcher
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let end = min(layout.fileSize, start + length)
                    guard start >= 0, end > start else {
                        continuation.finish()
                        return
                    }
                    let firstSlice = Int(start / Int64(CryptoEngine.sliceSize))
                    let lastSlice = Int((end - 1) / Int64(CryptoEngine.sliceSize))
                    for sliceIndex in firstSlice...lastSlice {
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }
                        let plain = try await plaintextSlice(
                            sliceIndex, objectID: objectID, layout: layout, fetcher: fetcher
                        )
                        let sliceStart = Int64(sliceIndex) * Int64(CryptoEngine.sliceSize)
                        let from = max(0, start - sliceStart)
                        let to = min(Int64(plain.count), end - sliceStart)
                        if to > from {
                            continuation.yield(plain.subdata(in: Int(from)..<Int(to)))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One retry per slice: a corrupted/partial download or GCM tag failure is transient;
    /// if it repeats, the error propagates to the stream (clean failure, never a crash).
    private func fetchWithRetry(
        _ fetcher: ObjectFetcher,
        fileID: Int,
        offset: Int64,
        limit: Int64,
        objectID: String
    ) async throws -> Data {
        do {
            return try await fetcher.fetch(fileId: fileID, offset: offset, limit: limit)
        } catch {
            Self.logger.warning("Range fetch failed once for \(objectID, privacy: .public) offset=\(offset, privacy: .public) limit=\(limit, privacy: .public), retrying")
            sliceCache.removeAll(for: objectID)
            return try await fetcher.fetch(fileId: fileID, offset: offset, limit: limit)
        }
    }

    // MARK: - Layout / file-id / fetcher caches

    func loadLayout(objectID: String) async throws -> ObjectLayout? {
        stateLock.lock()
        if let existing = layouts[objectID] {
            stateLock.unlock()
            return existing
        }
        // Another caller is already fetching this layout — piggyback on it.
        if let inFlight = loadingLayouts[objectID] {
            stateLock.unlock()
            return try await inFlight.value
        }
        let task = Task<ObjectLayout?, Error> { [weak self] in
            guard let self else { return nil }
            return try await self.loadLayoutUncached(objectID: objectID)
        }
        loadingLayouts[objectID] = task
        stateLock.unlock()

        // Clear the in-flight entry on BOTH success and failure — a stale entry
        // would make future calls await a task that already finished/errored.
        do {
            let layout = try await task.value
            stateLock.lock()
            loadingLayouts[objectID] = nil
            stateLock.unlock()
            return layout
        } catch {
            stateLock.lock()
            loadingLayouts[objectID] = nil
            stateLock.unlock()
            throw error
        }
    }

    private func loadLayoutUncached(objectID: String) async throws -> ObjectLayout? {

        guard let object = try? await DatabaseManager.shared.object(objectID), !object.isFolder else {
            return nil
        }
        // The layout is container-agnostic — it maps logical bytes to chunk slices.
        // mpv (via mpvStreamURL) can play any container from the same layout.
        let ext = (object.name as NSString).pathExtension.lowercased()
        let contentType: String
        switch ext {
        case "mp4", "m4v": contentType = UTType.mpeg4Movie.identifier
        case "mov": contentType = UTType.quickTimeMovie.identifier
        case "mp3": contentType = UTType.mp3.identifier
        case "m4a": contentType = UTType.mpeg4Audio.identifier
        case "wav": contentType = UTType.wav.identifier
        case "aac": contentType = UTType(filenameExtension: "aac")?.identifier ?? "public.aac-audio"
        default: contentType = "application/octet-stream"
        }
        guard let vault = try? await DatabaseManager.shared.firstVault() else { return nil }
        let chunks = (try? await DatabaseManager.shared.chunks(for: objectID)) ?? []
        guard !chunks.isEmpty else { return nil }

        var chunkLayouts: [ChunkLayout] = []
        var starts: [Int64] = []
        var offset: Int64 = 0
        for chunk in chunks {
            guard let messageID = chunk.messageID else { return nil }
            // Use Telegram's ACTUAL document size, not the catalog's recorded size.
            // A stale chunk-size record (chunk-plan change / interrupted upload) maps
            // slices past the real bytes — the moov tail of an mp4 then comes back as
            // garbage and mpv fails with "Invalid sample size" / moov atom not found.
            // The object's recorded total usually still matches reality, so the layout
            // must be rebuilt from the real sizes. Messages are cached by TDLib.
            let actual = try? await TelegramClient.shared.fileSize(
                forMessage: messageID, chatId: vault.channelID
            )
            let size = actual ?? chunk.size
            chunkLayouts.append(ChunkLayout(messageID: messageID, plainSize: size))
            starts.append(offset)
            offset += size
        }

        // Invariant: no slice may straddle two chunks. Every non-final chunk must be an
        // exact multiple of the 1 MB slice size (ChunkPlanner guarantees this for new
        // uploads); plans that violate it fall back to full download.
        let canStream = chunkLayouts.dropLast().allSatisfy {
            $0.plainSize % Int64(CryptoEngine.sliceSize) == 0
        }

        var objectKey: SymmetricKey? = nil
        if object.isPrivate {
            // An EMPTY wrapped key means unencrypted (public files carry "" in their
            // metadata caption) — unwrapping zero-length Data throws CryptoKit error.
            guard let wrapped = object.wrappedKey, !wrapped.isEmpty else { return nil }
            let master = try CryptoEngine.masterKey()
            objectKey = try CryptoEngine.unwrap(wrapped, with: master)
        }

        let layout = ObjectLayout(
            // The layout must span the ACTUAL chunk bytes (sum of real sizes) — the
            // object's recorded size is usually the same, but a stale chunk record can
            // make it diverge, and the layout must agree with what TDLib can serve.
            fileSize: offset,
            channelID: vault.channelID,
            isPrivate: object.isPrivate,
            objectKey: objectKey,
            chunks: chunkLayouts,
            chunkStarts: starts,
            contentType: contentType,
            canStream: canStream
        )
        Self.logger.info(
            "Stream layout \(objectID, privacy: .public): chunks=\(chunks.count, privacy: .public) size=\(object.size, privacy: .public) canStream=\(canStream, privacy: .public)"
        )

        stateLock.lock()
        if layouts.count >= 8 {
            layouts.removeAll()
            fileIDs.removeAll()
            fetchers.removeAll()
        }
        layouts[objectID] = layout
        stateLock.unlock()
        return layout
    }

    private func fileID(for objectID: String, chunkIndex: Int, layout: ObjectLayout) async throws -> Int {
        stateLock.lock()
        if let id = fileIDs[objectID]?[chunkIndex] {
            stateLock.unlock()
            return id
        }
        stateLock.unlock()

        let chunk = layout.chunks[chunkIndex]
        let id = try await TelegramClient.shared.getFileId(chatId: layout.channelID, messageId: chunk.messageID)

        stateLock.lock()
        fileIDs[objectID, default: [:]][chunkIndex] = id
        stateLock.unlock()
        return id
    }

    func fetcher(for objectID: String) -> ObjectFetcher {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let existing = fetchers[objectID] { return existing }
        let fetcher = ObjectFetcher()
        fetchers[objectID] = fetcher
        return fetcher
    }
}

// MARK: - Layout

struct ChunkLayout {
    let messageID: Int64
    let plainSize: Int64
}

struct ObjectLayout {
    let fileSize: Int64
    let channelID: Int64
    let isPrivate: Bool
    let objectKey: SymmetricKey?
    let chunks: [ChunkLayout]
    let chunkStarts: [Int64]
    let contentType: String
    let canStream: Bool

    /// Maps a file-wide plaintext slice index to its chunk and the slice's index
    /// *within that chunk* (indices restart at 0 per chunk, as encrypted at upload time).
    func chunkAndLocalIndex(for fileSliceIndex: Int) -> (chunk: Int, local: Int) {
        let sliceBytes = Int64(fileSliceIndex) * Int64(CryptoEngine.sliceSize)
        var lo = 0
        var hi = chunks.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if chunkStarts[mid] <= sliceBytes { lo = mid } else { hi = mid - 1 }
        }
        let local = Int((sliceBytes - chunkStarts[lo]) / Int64(CryptoEngine.sliceSize))
        return (lo, local)
    }
}

// MARK: - Serialized per-object range fetcher

/// Serializes range downloads per object. TDLib lets a downloadFile call with a new
/// offset/limit supersede an in-flight one for the same file, so concurrent ranges on one
/// chunk would clobber each other (and race on the shared local file). Chaining guarantees
/// a single range fetch at a time; slices are ≤ 1 MB, so waits are short.
actor ObjectFetcher {
    private var tail: Task<Data, any Error>?

    func fetch(fileId: Int, offset: Int64, limit: Int64) async throws -> Data {
        let previous = tail
        let work = Task<Data, any Error> {
            if let previous {
                _ = try? await previous.value // keep the chain alive past errors/cancels
            }
            return try await TelegramClient.shared.fetchRangeData(
                fileId: fileId, offset: offset, limit: limit
            )
        }
        tail = work
        return try await work.value
    }
}

// MARK: - Slice-granularity LRU

/// In-memory LRU of fully decrypted 1 MB slices, keyed by (object, file-wide slice index).
/// Caching at slice granularity dedups the overlapping re-reads mpv's demuxer makes
/// around the playhead and keeps eviction trivial (48 entries ≈ 48 MB).
final class SliceCache: @unchecked Sendable {
    struct Key: Hashable {
        let objectID: String
        let sliceIndex: Int
    }

    private let lock = NSLock()
    private var entries: [Key: Data] = [:]
    private var order: [Key] = []
    private let maxEntries = 48

    func get(_ key: Key) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let data = entries[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return data
    }

    func put(_ key: Key, _ data: Data) {
        lock.lock(); defer { lock.unlock() }
        if entries[key] != nil {
            order.removeAll { $0 == key }
        } else {
            if order.count >= maxEntries, let evicted = order.first {
                entries[evicted] = nil
                order.removeFirst()
            }
            order.append(key)
        }
        entries[key] = data
    }

    func removeAll(for objectID: String) {
        lock.lock(); defer { lock.unlock() }
        for key in entries.keys where key.objectID == objectID {
            entries[key] = nil
            order.removeAll { $0 == key }
        }
    }
}
