import Foundation
import AVFoundation
import UniformTypeIdentifiers
import CryptoKit
import os

/// Byte-range video streaming from the Telegram-backed vault.
///
/// AVPlayer asks for byte ranges of the logical file; this engine maps each range to the
/// 1 MB slices it covers, fetches exactly those slices from the chunk messages that hold
/// them (TDLib `downloadFile` with offset/limit — its media-streaming range support),
/// decrypts them for private vault files, and serves the plaintext range back to
/// AVFoundation via `AVAssetResourceLoader`. No local HTTP server needed: the resource
/// loader is the native macOS equivalent, and AVPlayer can seek freely because byte-range
/// access is advertised.
///
/// Layout model (why the arithmetic works):
/// - A file is split into chunk documents whose sizes are multiples of the 1 MB slice
///   size (except the final chunk), so no slice ever straddles two chunks.
/// - Public files: chunk ciphertext == chunk plaintext; ranges map 1:1.
/// - Private files: each 1 MB plaintext slice is AES-GCM sealed into
///   `sealedSliceSize = sliceSize + 28` bytes (12 B nonce + 16 B tag) with a *per-chunk*
///   slice index starting at 0. GCM cannot be opened from mid-box, so a fetch always
///   starts at a slice boundary and pulls the FULL sealed slice, then we trim in memory.
final class VideoStreamingEngine: NSObject, AVAssetResourceLoaderDelegate {
    static let shared = VideoStreamingEngine()

    private static let logger = Logger(subsystem: "com.xcloud.app", category: "stream")

    // The delegate queue must stay free so didCancel is deliverable while a range fetch
    // runs; all TDLib/decrypt work happens in Tasks, never on this queue.
    private let delegateQueue = DispatchQueue(label: "com.xcloud.streaming.delegate", qos: .userInitiated)

    private let stateLock = NSLock()
    private var layouts: [String: ObjectLayout] = [:]
    private var fileIDs: [String: [Int: Int]] = [:] // objectID -> [chunkIndex: TDLib file id]
    private var fetchers: [String: ObjectFetcher] = [:]
    private var activeTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let sliceCache = SliceCache()

    // MARK: - Public

    /// Returns an AVPlayerItem that streams `object` byte-by-byte from Telegram, a local
    /// item when the file is already cached, or nil when streaming isn't supported (the
    /// caller falls back to a full download).
    func playerItem(for object: ObjectRecord) async -> AVPlayerItem? {
        if DownloadEngine.isCached(object) {
            return AVPlayerItem(url: DownloadEngine.cacheURL(for: object))
        }
        // AVFoundation's resource loader can only reliably range-demux MP4-family
        // containers; anything else must go through mpv (mpvStreamURL).
        let ext = (object.name as NSString).pathExtension.lowercased()
        guard ["mp4", "m4v", "mov"].contains(ext),
              let layout = try? await loadLayout(objectID: object.id), layout.canStream,
              let customURL = URL(string: "xcloud-stream://object-\(object.id)") else {
            return nil
        }
        let asset = AVURLAsset(url: customURL)
        asset.resourceLoader.setDelegate(self, queue: delegateQueue)
        return AVPlayerItem(asset: asset)
    }

    /// Returns a playable mpv stream URL for any container with a loadable layout
    /// (mpv/FFmpeg demuxes what AVFoundation can't — mkv, webm, avi, ...). The URL
    /// points at the local byte-range server, which serves decrypted plaintext.
    /// Returns nil for cached files (play them directly) or unloadable layouts.
    func mpvStreamURL(for object: ObjectRecord) async -> URL? {
        if DownloadEngine.isCached(object) { return nil }
        guard let layout = try? await loadLayout(objectID: object.id), layout.fileSize > 0 else {
            return nil
        }
        return await VaultStreamServer.shared.streamURL(for: object.id)
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url, url.scheme == "xcloud-stream" else {
            return false
        }
        let objectID = url.absoluteString.replacingOccurrences(of: "xcloud-stream://object-", with: "")
        let task = Task { await handle(loadingRequest, objectID: objectID) }
        stateLock.lock()
        activeTasks[ObjectIdentifier(loadingRequest)] = task
        stateLock.unlock()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        stateLock.lock()
        let task = activeTasks.removeValue(forKey: ObjectIdentifier(loadingRequest))
        stateLock.unlock()
        task?.cancel()
    }

    // MARK: - Request handling

    private func handle(_ request: AVAssetResourceLoadingRequest, objectID: String) async {
        defer {
            stateLock.lock()
            activeTasks[ObjectIdentifier(request)] = nil
            stateLock.unlock()
        }

        guard let layout = try? await loadLayout(objectID: objectID), layout.canStream else {
            request.finishLoading(with: DownloadError.fileNotFound)
            return
        }

        if let info = request.contentInformationRequest {
            info.isByteRangeAccessSupported = true
            info.contentLength = layout.fileSize
            info.contentType = layout.contentType
        }

        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return
        }

        let start = dataRequest.requestedOffset
        let requestedLength = Int64(dataRequest.requestedLength)
        let length: Int64 = requestedLength <= 0
            ? (layout.fileSize - start)
            : requestedLength
        guard start >= 0, length > 0, start < layout.fileSize else {
            request.finishLoading()
            return
        }
        let end = min(layout.fileSize, start + length)
        guard end > start else {
            request.finishLoading()
            return
        }

        Self.logger.debug("Range request object=\(objectID, privacy: .public) offset=\(start, privacy: .public) length=\(length, privacy: .public)")

        let fetcher = fetcher(for: objectID)
        let firstSlice = Int(start / Int64(CryptoEngine.sliceSize))
        let lastSlice = Int((end - 1) / Int64(CryptoEngine.sliceSize))

        do {
            for sliceIndex in firstSlice...lastSlice {
                if request.isCancelled { return }
                let plain = try await plaintextSlice(
                    sliceIndex, objectID: objectID, layout: layout, fetcher: fetcher
                )
                if request.isCancelled { return }
                let sliceStart = Int64(sliceIndex) * Int64(CryptoEngine.sliceSize)
                let from = max(0, start - sliceStart)
                let to = min(Int64(plain.count), end - sliceStart)
                guard to > from else { continue }
                dataRequest.respond(with: plain.subdata(in: Int(from)..<Int(to)))
            }
            if request.isCancelled { return }
            request.finishLoading()
        } catch {
            if request.isCancelled { return }
            request.finishLoading(with: error)
        }
    }

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
    /// if it repeats, the error propagates to AVPlayer (clean failure, never a crash).
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
        stateLock.unlock()

        guard let object = try? await DatabaseManager.shared.object(objectID), !object.isFolder else {
            return nil
        }
        // The layout is container-agnostic — it maps logical bytes to chunk slices.
        // AVFoundation streaming additionally gates on mp4/m4v/mov in playerItem(for:);
        // mpv (via mpvStreamURL) can play any container from the same layout.
        let ext = (object.name as NSString).pathExtension.lowercased()
        let contentType: String
        switch ext {
        case "mp4", "m4v": contentType = UTType.mpeg4Movie.identifier
        case "mov": contentType = UTType.quickTimeMovie.identifier
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
            chunkLayouts.append(ChunkLayout(messageID: messageID, plainSize: chunk.size))
            starts.append(offset)
            offset += chunk.size
        }

        // Invariant: no slice may straddle two chunks. Every non-final chunk must be an
        // exact multiple of the 1 MB slice size (ChunkPlanner guarantees this for new
        // uploads); plans that violate it fall back to full download.
        let canStream = chunks.dropLast().allSatisfy { $0.size % Int64(CryptoEngine.sliceSize) == 0 }

        var objectKey: SymmetricKey? = nil
        if object.isPrivate {
            // An EMPTY wrapped key means unencrypted (public files carry "" in their
            // metadata caption) — unwrapping zero-length Data throws CryptoKit error.
            guard let wrapped = object.wrappedKey, !wrapped.isEmpty else { return nil }
            let master = try CryptoEngine.masterKey()
            objectKey = try CryptoEngine.unwrap(wrapped, with: master)
        }

        let layout = ObjectLayout(
            fileSize: object.size,
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
/// Caching at slice granularity dedups the overlapping re-reads AVPlayer makes around the
/// playhead and keeps eviction trivial (48 entries ≈ 48 MB).
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
