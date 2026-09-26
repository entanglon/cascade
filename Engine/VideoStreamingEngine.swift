import Foundation
import UniformTypeIdentifiers
import os

/// Byte-range streaming from the Telegram-backed vault — mpv only. There is NO
/// AVFoundation anywhere in this app: mpv (libmpv + FFmpeg) demuxes every container
/// from the local byte-range HTTP server (`VaultStreamServer`), which this engine
/// feeds with plaintext slices.
///
/// Layout model (why the arithmetic works):
/// - A file is split into chunk documents whose sizes are multiples of the 1 MB slice
///   size (except the final chunk), so no slice ever straddles two chunks.
/// - Files are stored as PLAIN bytes (the encryption era is over — uniform layout,
///   real Telegram previews, and the plaintext streaming path that was always the
///   stable one). A slice is exactly `SliceMath.sliceSize` bytes of the document.
final class VideoStreamingEngine {
    static let shared = VideoStreamingEngine()

    private static let logger = Logger(subsystem: "com.cascade.app", category: "stream")

    private let stateLock = NSLock()
    private var layouts: [String: ObjectLayout] = [:]
    // Recency order for `layouts` (oldest first). Background probes (thumbnail
    // generation, other files' stream URLs) build layouts DURING playback; the old
    // "wipe everything at 8" eviction destroyed the PLAYING file's fetchers/fileIDs
    // mid-stream — two concurrent TDLib chains then clobbered each other on the same
    // fileId (supersede semantics), producing minutes-long hangs. Now: LRU eviction,
    // a much higher cap, and the most-recently-touched object (the one being served)
    // is never a victim.
    private var layoutRecency: [String] = []
    private static let maxCachedLayouts = 16
    private var fileIDs: [String: [Int: Int]] = [:]
    private var fetchers: [String: [Int: ObjectFetcher]] = [:] // objectID -> [chunkIndex: TDLib file id]

    private let sliceCache = SliceCache()
    // In-flight layout loads, so concurrent callers (theater's play() kickoff + the
    // same file's stream-URL resolve) share ONE network fetch instead of each hitting
    // Telegram per chunk.
    private var loadingLayouts: [String: Task<ObjectLayout?, Error>] = [:]

    // MARK: - Public

    /// Returns a playable mpv stream URL for any container with a loadable layout
    /// (mpv/FFmpeg demuxes what AVFoundation can't — mkv, webm, avi, ...). The URL
    /// points at the local byte-range server, which serves plaintext. Since the
    /// single-cache architecture (item 159) EVERYTHING streams — replays are fed
    /// from TDLib's local store without network until evicted by its cap.
    func mpvStreamURL(for object: ObjectRecord) async -> URL? {
        guard let layout = try? await loadLayout(objectID: object.id), layout.fileSize > 0 else {
            return nil
        }
        return await VaultStreamServer.shared.streamURL(for: object.id)
    }

    /// PDF variant of `mpvStreamURL`: same byte-range server, `application/pdf`
    /// content type.
    func pdfStreamURL(for object: ObjectRecord) async -> URL? {
        guard let layout = try? await loadLayout(objectID: object.id), layout.fileSize > 0 else {
            return nil
        }
        return await VaultStreamServer.shared.streamURL(for: object.id)
    }

    // MARK: - Slice serving

    /// How many 1 MB slices a single TDLib range fetch pulls at once. Streaming is
    /// latency-bound at 1 slice/fetch (one downloadFile round trip per MB): a TrueHD +
    /// HEVC stream needs ~1.25 MB/s sustained, so one-fetch-per-slice runs at the edge
    /// and every round-trip hiccup collapses mpv's cache into endless buffering
    /// (observed: cache 9.4s → 0.1s, then a permanent pause-for-cache trickle).
    /// Batching 16 slices per call amortizes the round trip 16× — a fetch covers
    /// ~12 s of playback.
    private static let slicesPerFetch = 16

    /// Appends a timestamped line to /tmp/cascade-stream.log. The unified log is
    /// unreliable on this machine (HANDOVER item 48), and stdout is lost when the
    /// app is launched via `open` — this file is the streaming pipeline's evidence
    /// trail (serve misses, batch outcomes, timeouts, teardowns). Best-effort.
    private static let streamLogLock = NSLock()
    private static let streamLogFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    private static func streamLog(_ message: String) {
        // Compile-time gated: stream internals (offsets, object IDs, layout)
        // must never exist in Release builds.
        #if DEBUG
        streamLogLock.lock()
        defer { streamLogLock.unlock() }
        let line = "[\(streamLogFormatter.string(from: Date()))] \(message)\n"
        let url = URL(fileURLWithPath: "/tmp/cascade-stream.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? line.write(to: url, atomically: false, encoding: .utf8)
        }
        #endif
    }

    private func plaintextSlice(
        _ fileSliceIndex: Int,
        objectID: String,
        layout: ObjectLayout,
        afterSlice: Int? = nil
    ) async throws -> Data {
        // Keep the playing file the most-recently-used layout so LRU eviction can
        // never select it while background probes churn other layouts; also shield
        // its slices from the slice cache's global LRU.
        stateLock.lock()
        if layouts[objectID] != nil { touchLayoutLocked(objectID) }
        stateLock.unlock()
        sliceCache.protectedObjectID = objectID

        let cacheKey = SliceCache.Key(objectID: objectID, sliceIndex: fileSliceIndex)
        if let cached = sliceCache.get(cacheKey) {
            return cached
        }

        let (chunkIndex, localSliceIndex) = layout.chunkAndLocalIndex(for: fileSliceIndex)
        let chunk = layout.chunks[chunkIndex]
        let fileID = try await fileID(for: objectID, chunkIndex: chunkIndex, layout: layout)
        let fetcher = fetcher(for: objectID, chunkIndex: chunkIndex)

        // A slice that directly continues this stream's previous serve is part of
        // mpv's sequential walk: fetch a whole batch in that round trip (16× fewer
        // negotiations on linear playback). Jumps/startup stay single-slice —
        // the synchronous fetch must fully complete before mpv sees its first
        // byte, so a big batch there would add seconds of latency to every start
        // and seek. Throughput comes from this sequential batching.
        let isSequential = afterSlice == fileSliceIndex - 1
        let batchCount = isSequential ? Self.slicesPerFetch : 1
        if !isSequential {
            Self.streamLog("serve miss obj=\(objectID) slice=\(fileSliceIndex) chunk=\(chunkIndex) local=\(localSliceIndex) (jump)")
        }

        let slicePlainOffset = Int64(localSliceIndex) * SliceMath.sliceSize
        let remainingInChunk = chunk.plainSize - slicePlainOffset
        // A slice past the chunk's real bytes means the catalog disagrees with
        // Telegram — fetching 0 bytes would spin retry storms. Fail the range so
        // mpv retries with fresh state instead.
        guard remainingInChunk > 0 else { throw ShortRangeFetch() }
        let batchBytes = min(Int64(batchCount) * SliceMath.sliceSize, remainingInChunk)

        let raw = try await fetchWithRetry(
            fetcher, fileID: fileID, offset: slicePlainOffset, limit: batchBytes, objectID: objectID
        )

        var pieceStart = 0
        while pieceStart < raw.count {
            let pieceEnd = min(pieceStart + Int(SliceMath.sliceSize), raw.count)
            let piece = raw.subdata(in: pieceStart..<pieceEnd)
            sliceCache.put(
                SliceCache.Key(
                    objectID: objectID,
                    sliceIndex: fileSliceIndex + pieceStart / Int(SliceMath.sliceSize)
                ),
                piece
            )
            pieceStart = pieceEnd
        }
        return sliceCache.get(cacheKey) ?? raw
    }

    /// Incrementally yields the plaintext bytes covering `start..<start+length` as
    /// 1 MB slices, so a full-file GET never buffers the whole movie.
    /// Used by the local HTTP server that feeds mpv.
    ///
    /// Sequential tracking is PER-STREAM (local `lastDelivered`), never per-object:
    /// mpv runs concurrent range streams (main + moov/tail probes) against the same
    /// object, and shared sequential state would flicker batching off for the main
    /// stream on every probe interleaving (Claude/Qwen review round 6).
    func plaintextSliceStream(
        objectID: String,
        start: Int64,
        length: Int64,
        layout: ObjectLayout
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let end = min(layout.fileSize, start + length)
                    guard start >= 0, end > start else {
                        continuation.finish()
                        return
                    }
                    let firstSlice = Int(start / SliceMath.sliceSize)
                    let lastSlice = Int((end - 1) / SliceMath.sliceSize)
                    var lastDelivered: Int? = nil
                    for sliceIndex in firstSlice...lastSlice {
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }
                        let plain = try await plaintextSlice(
                            sliceIndex, objectID: objectID, layout: layout,
                            afterSlice: lastDelivered
                        )
                        let sliceStart = Int64(sliceIndex) * SliceMath.sliceSize
                        let from = max(0, start - sliceStart)
                        let to = min(Int64(plain.count), end - sliceStart)
                        if to > from {
                            continuation.yield(plain.subdata(in: Int(from)..<Int(to)))
                        }
                        // Updated only after a successful serve — a cancelled or
                        // failed attempt leaves the tracker honest (it must reflect
                        // bytes actually delivered to this stream).
                        lastDelivered = sliceIndex
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Up to three attempts per range: a corrupted/partial download is transient;
    /// the fetcher chain is CANCELLED between attempts so a stale/superseded TDLib
    /// session can't poison the retry. If all three fail, the error propagates to
    /// the stream — the HTTP response dies and mpv retries the byte range with
    /// fresh state (clean failure, never a crash).
    ///
    /// IMPORTANT: a failed fetch must NEVER evict the object's cached slices. Cached
    /// slices were successfully fetched before being cached and cannot be corrupted
    /// by a later failed request. Wiping the whole cache on one transient error threw
    /// away megabytes of buffered playback and turned a single network hiccup into
    /// permanent buffering.
    private func fetchWithRetry(
        _ fetcher: ObjectFetcher,
        fileID: Int,
        offset: Int64,
        limit: Int64,
        objectID: String,
        priority: Int = 32
    ) async throws -> Data {
        let startedAt = Date()
        defer {
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            Self.streamLog("fetch done obj=\(objectID) off=\(offset) len=\(limit) prio=\(priority) ms=\(ms)")
        }
        for attempt in 1...3 {
            do {
                return try await withFetchTimeout {
                    try await fetcher.fetch(fileId: fileID, offset: offset, limit: limit, priority: priority)
                }
            } catch is FetchTimeout {
                Self.streamLog("fetch TIMEOUT attempt=\(attempt)/3 obj=\(objectID) off=\(offset) len=\(limit)")
                guard attempt < 3 else { throw FetchTimeout() }
                fetcher.cancelPending()
            } catch where error is CancellationError || Task.isCancelled {
                // Our own context was cancelled (run restart, teardown) — retrying
                // a cancelled operation can never succeed; fail through immediately.
                throw error
            } catch {
                Self.streamLog("fetch ERROR attempt=\(attempt)/3 obj=\(objectID) off=\(offset) len=\(limit): \(error.localizedDescription)")
                guard attempt < 3 else { throw error }
                fetcher.cancelPending()
            }
        }
        throw FetchTimeout()
    }

    private struct FetchTimeout: Error {}
    private struct ShortRangeFetch: Error {}

    private func withFetchTimeout<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        // Genuine timeout via the shared unstructured-task race: the previous
        // withThrowingTaskGroup implementation could never fire on a dropped
        // TDLib response (item 124 — a task group must await every child, hung
        // or not), which would stall the stream forever with no retry.
        do {
            return try await TelegramClient.shared.withResponseTimeout(30, operation)
        } catch TelegramError.timedOut {
            // The race itself timed out (operation errors pass through
            // untouched) — surface as FetchTimeout so the retry loop treats
            // it like any other fetch failure.
            throw FetchTimeout()
        }
    }

    // MARK: - Layout / file-id / download caches

    func loadLayout(objectID: String) async throws -> ObjectLayout? {
        stateLock.lock()
        if let existing = layouts[objectID] {
            touchLayoutLocked(objectID)
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
        case "pdf": contentType = "application/pdf"
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
            // Chunks record the channel they were uploaded to. The vault moved to
            // Saved Messages; legacy rows uploaded into the old vault channel must
            // still resolve, so every lookup goes through the chunk's own channel.
            // The vault's channel is the fallback for rows predating the column.
            let channelID = chunk.channelID ?? vault.channelID
            // Use Telegram's ACTUAL document size, not the catalog's recorded size.
            // A stale chunk-size record (chunk-plan change / interrupted upload) maps
            // slices past the real bytes — the moov tail of an mp4 then comes back as
            // garbage and mpv fails with "Invalid sample size" / moov atom not found.
            // The object's recorded total usually still matches reality, so the layout
            // must be rebuilt from the real sizes. Messages are cached by TDLib.
            let actual = try? await TelegramClient.shared.fileSize(
                forMessage: messageID, chatId: channelID
            )
            let plainSize = actual ?? chunk.size
            chunkLayouts.append(ChunkLayout(messageID: messageID, plainSize: plainSize, channelID: channelID))
            starts.append(offset)
            offset += plainSize
        }

        // Invariant: no slice may straddle two chunks. Every non-final chunk must be an
        // exact multiple of the 1 MB slice size (ChunkPlanner guarantees this for new
        // uploads); plans that violate it fall back to full download.
        let canStream = chunkLayouts.dropLast().allSatisfy {
            $0.plainSize % SliceMath.sliceSize == 0
        }

        let layout = ObjectLayout(
            // The layout must span the ACTUAL chunk bytes (sum of real sizes) — the
            // object's recorded size is usually the same, but a stale chunk record can
            // make it diverge, and the layout must agree with what TDLib can serve.
            fileSize: object.size > 0 ? object.size : offset,
            channelID: vault.channelID,
            chunks: chunkLayouts,
            chunkStarts: starts,
            contentType: contentType,
            canStream: canStream
        )
        Self.logger.info(
            "Stream layout \(objectID, privacy: .public): chunks=\(chunks.count, privacy: .public) size=\(object.size, privacy: .public) canStream=\(canStream, privacy: .public)"
        )
        Self.streamLog("layout built obj=\(objectID) chunks=\(chunks.count) size=\(object.size) canStream=\(canStream)")

        stateLock.lock()
        // Evict least-recently-used layouts when over cap — NEVER the object being
        // inserted (the active playback). Victims' fetcher chains are cancelled so
        // no orphaned TDLib chains linger on their fileIds.
        var victimFetchers: [ObjectFetcher] = []
        while layouts.count >= Self.maxCachedLayouts,
              let oldest = layoutRecency.first {
            guard oldest != objectID else { break }
            layouts[oldest] = nil
            fileIDs[oldest] = nil
            victimFetchers.append(contentsOf: (fetchers.removeValue(forKey: oldest) ?? [:]).values)
            layoutRecency.removeFirst()
            Self.streamLog("layout evicted obj=\(oldest) (LRU cap \(Self.maxCachedLayouts))")
        }
        touchLayoutLocked(objectID)
        layouts[objectID] = layout
        stateLock.unlock()
        for f in victimFetchers { f.cancelPending() }
        return layout
    }

    /// Marks `objectID` as most-recently-used. Caller MUST hold stateLock.
    private func touchLayoutLocked(_ objectID: String) {
        layoutRecency.removeAll { $0 == objectID }
        layoutRecency.append(objectID)
    }

    private func fileID(for objectID: String, chunkIndex: Int, layout: ObjectLayout) async throws -> Int {
        stateLock.lock()
        if let id = fileIDs[objectID]?[chunkIndex] {
            stateLock.unlock()
            return id
        }
        stateLock.unlock()

        let chunk = layout.chunks[chunkIndex]
        // Chunks record the channel they were uploaded to (Saved Messages now,
        // the legacy vault channel before the migration) — resolve against that.
        let id = try await TelegramClient.shared.getFileId(chatId: chunk.channelID, messageId: chunk.messageID)

        stateLock.lock()
        fileIDs[objectID, default: [:]][chunkIndex] = id
        stateLock.unlock()
        return id
    }

    /// Tears down ALL streaming state for an object — cancels in-flight fetcher
    /// chains AND the underlying TDLib chunk downloads, then drops the fetchers.
    /// Called when a playback stops or switches files, so the NEXT play of the
    /// same file starts with a clean TDLib download queue.
    ///
    /// Why this is required (observed live): TDLib's ranged downloadFile does NOT
    /// stop at the requested limit — it keeps downloading the whole chunk, and a
    /// stopped playback leaves those full-chunk downloads running in the queue.
    /// A fresh play's range requests then queue BEHIND the leftover downloads
    /// (one 128 MB chunk at a time, ~50 s each), starving the stream into
    /// permanent buffering until the queue drains. Cancelling on teardown removes
    /// the leftovers so replays start instantly.
    func fetcher(for objectID: String, chunkIndex: Int) -> ObjectFetcher {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let existing = fetchers[objectID]?[chunkIndex] { return existing }
        let f = ObjectFetcher()
        fetchers[objectID, default: [:]][chunkIndex] = f
        return f
    }

    func invalidatePlayback(for objectID: String) {
        Self.streamLog("invalidatePlayback obj=\(objectID)")
        if sliceCache.protectedObjectID == objectID {
            sliceCache.protectedObjectID = nil
        }
        stateLock.lock()
        let chunkFetchers = fetchers[objectID] ?? [:]
        let chunkFileIDs = fileIDs[objectID] ?? [:]
        fetchers[objectID] = nil
        stateLock.unlock()
        for f in chunkFetchers.values {
            f.cancelPending()
        }
        for fileID in chunkFileIDs.values {
            TelegramClient.shared.cancelDownload(fileId: fileID)
        }
        sliceCache.removeAll(for: objectID)
    }
}

// MARK: - Layout

struct ChunkLayout {
    let messageID: Int64
    let plainSize: Int64
    /// Channel the chunk document lives in — Saved Messages for new uploads,
    /// the legacy vault channel for pre-migration rows.
    let channelID: Int64
}

struct ObjectLayout {
    let fileSize: Int64
    let channelID: Int64
    let chunks: [ChunkLayout]
    let chunkStarts: [Int64]
    let contentType: String
    let canStream: Bool

    /// Maps a file-wide plaintext slice index to its chunk and the slice's index
    /// *within that chunk* (indices restart at 0 per chunk).
    func chunkAndLocalIndex(for fileSliceIndex: Int) -> (chunk: Int, local: Int) {
        let sliceBytes = Int64(fileSliceIndex) * SliceMath.sliceSize
        var lo = 0
        var hi = chunks.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            // `<=`: a slice landing EXACTLY on a chunk boundary belongs to the NEXT
            // chunk. With `<` the search stops one chunk early and returns local =
            // one-past-the-end (fetchLen 0 → range-fetch retry storms).
            if chunkStarts[mid] <= sliceBytes { lo = mid } else { hi = mid - 1 }
        }
        let local = Int((sliceBytes - chunkStarts[lo]) / SliceMath.sliceSize)
        return (lo, local)
    }
}

// MARK: - Serialized per-object range fetcher

/// Serializes range downloads per chunk. TDLib lets a downloadFile call with a new
/// offset/limit supersede an in-flight one for the same file, so concurrent ranges on one
/// chunk would clobber each other (and race on the shared local file). Chaining guarantees
/// a single range fetch at a time; slices are ≤ 1 MB, so waits are short.
actor ObjectFetcher {
    private var tail: Task<Data, any Error>?

    func cancelPending() {
        tail?.cancel()
        tail = nil
    }

    func fetch(fileId: Int, offset: Int64, limit: Int64, priority: Int = 32) async throws -> Data {
        let previous = tail
        let work = Task<Data, any Error> {
            if let previous {
                _ = try? await previous.value
            }
            return try await TelegramClient.shared.fetchRangeData(
                fileId: fileId, offset: offset, limit: limit, priority: priority
            )
        }
        tail = work
        return try await work.value
    }
}

// MARK: - Slice-granularity LRU

/// In-memory LRU of 1 MB plaintext slices, keyed by (object, file-wide slice index).
/// Caching at slice granularity dedups the overlapping re-reads mpv's demuxer makes
/// around the playhead and keeps eviction trivial.
///
/// Capacity arithmetic (Claude/Qwen review round 6): worst-case concurrent demand
/// is the serve path (16-slice batches) plus background probe traffic — the old 128
/// cap meant prefetchers could evict each other's not-yet-consumed writes. 256 gives
/// real headroom over that ceiling.
final class SliceCache: @unchecked Sendable {
    struct Key: Hashable {
        let objectID: String
        let sliceIndex: Int
    }

    private let lock = NSLock()
    private var entries: [Key: Data] = [:]
    private var order: [Key] = []
    private let maxEntries = 256

    /// The object currently feeding the playhead (set by the engine). Its entries
    /// are skipped by normal eviction so background probe traffic on other objects
    /// can never flush the foreground buffer; if the cache fills entirely with
    /// protected entries they become evictable again (safety valve).
    var protectedObjectID: String?

    func contains(_ key: Key) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries[key] != nil
    }

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
            let protected = protectedObjectID
            if order.count >= maxEntries {
                // Evict the oldest UNPROTECTED entry; only fall through to the
                // playhead's own slices when everything resident is protected.
                if let victim = order.first(where: { $0.objectID != protected }) {
                    entries[victim] = nil
                    order.removeAll { $0 == victim }
                }
            }
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
