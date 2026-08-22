import Foundation
import CryptoKit
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
/// - When encrypted, each 1 MB slice maps to a sealed slice of (1 MB + 28 bytes).
///   The engine fetches the exact sealed slice and decrypts it in-memory with O(1) latency.
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
    // Up to N concurrent read-ahead runs per object. mpv issues SEPARATE byte-range
    // streams (main playback + moov/tail probes), and ONE run cannot cover two
    // distant positions — the previous single-run design made them cancel each
    // other in a ping-pong that killed every batch (telemetry 2026-08-21: 1623
    // restarts, 99 completed batches).
    private var readAheadRuns: [String: [ReadAheadRun]] = [:]
    private static let maxConcurrentRuns = 3

    private let sliceCache = SliceCache()
    // In-flight layout loads, so concurrent callers (theater's play() kickoff +
    // the same file's stream-URL resolve) share ONE network fetch instead of
    // each hitting Telegram per chunk.
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
    /// Batching 8 slices per call amortizes the round trip 8× — a fetch covers
    /// ~6 s of playback.
    private static let slicesPerFetch = 16

    // Encrypted-path read-ahead. The serve path fetches exactly ONE sealed slice
    // (fast startup — mpv gets its first byte after a single ~1 MB round trip);
    // a background run then keeps the SliceCache filled `readAheadWindowSlices`
    // ahead of the playhead using batched fetches of `readAheadBatchSlices`
    // sealed slices per TDLib round trip. This is the plaintext batching that
    // made streaming rock solid, moved OFF the critical path so it can no longer
    // delay startup: blocking a background task for a few MB is harmless.
    //
    // Window sizing (telemetry 2026-08-21): a TrueHD+HEVC stream consumes
    // ~1.25 MB/s, so 48 slices ≈ 38 s of forward buffer — enough to absorb a
    // multi-second TDLib stall without mpv ever reaching pause-for-cache.
    private static let readAheadBatchSlices = 32
    // Serve-path batches stay SMALL: the synchronous fetch must fully complete
    // before mpv sees even its first slice, so a big batch here would add
    // seconds of latency to every start/seek. Throughput comes from the deep
    // read-ahead runs (32-slice batches); responsiveness from these.
    private static let serveBatchSlices = 8
    private static let readAheadWindowSlices = 96

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
            ensureReadAhead(objectID: objectID, layout: layout, servedSlice: fileSliceIndex)
            return cached
        }

        let (chunkIndex, localSliceIndex) = layout.chunkAndLocalIndex(for: fileSliceIndex)
        let chunk = layout.chunks[chunkIndex]
        let fileID = try await fileID(for: objectID, chunkIndex: chunkIndex, layout: layout)

        let fetcher = fetcher(for: objectID, chunkIndex: chunkIndex)

        if let objectKey = layout.objectKey {
            // Encrypted streaming: the first slice of a range walk (jump/start) is
            // a single-slice fetch — fast startup, mpv gets bytes after one ~1 MB
            // round trip. A slice that directly continues this stream's previous
            // serve is part of mpv's sequential walk: fetch a whole batch in that
            // round trip (8× fewer negotiations on linear playback).
            let isSequential = afterSlice == fileSliceIndex - 1
            let batchCount = isSequential ? Self.serveBatchSlices : 1
            if !isSequential {
                Self.streamLog("serve miss obj=\(objectID) slice=\(fileSliceIndex) chunk=\(chunkIndex) local=\(localSliceIndex) (jump)")
            }

            let sliceCipherOffset = Int64(localSliceIndex) * Int64(CryptoEngine.sealedSliceSize)
            let plainRemainingInChunk = max(0, chunk.plainSize - Int64(localSliceIndex) * Int64(CryptoEngine.sliceSize))
            let plainSliceLen = min(Int64(CryptoEngine.sliceSize), plainRemainingInChunk)
            let sealedSliceLen = plainSliceLen + 28

            if batchCount > 1 {
                let batchStartedAt = Date()
                let cached = try await fetchEncryptedBatchIntoCache(
                    objectID: objectID,
                    layout: layout,
                    firstSlice: fileSliceIndex,
                    maxCount: batchCount,
                    priority: 32
                )
                let ms = Int(Date().timeIntervalSince(batchStartedAt) * 1000)
                Self.streamLog("serve batch obj=\(objectID) slices=\(fileSliceIndex)+\(cached) prio=32 ms=\(ms)")
                if cached > 0, let sliced = sliceCache.get(cacheKey) {
                    ensureReadAhead(objectID: objectID, layout: layout, servedSlice: fileSliceIndex + cached - 1)
                    return sliced
                }
            }

            Self.streamLog("serve miss obj=\(objectID) slice=\(fileSliceIndex) chunk=\(chunkIndex) local=\(localSliceIndex)")
            // A read-ahead run batch we just queued behind may have filled this
            // slice while we waited on the chain — never re-download it.
            if let filled = sliceCache.get(cacheKey) {
                return filled
            }
            let sealedData = try await fetchWithRetry(
                fetcher, fileID: fileID, offset: sliceCipherOffset, limit: sealedSliceLen, objectID: objectID
            )
            let decryptedSlice = try CryptoEngine.decryptSlice(
                sealedData, objectKey: objectKey, index: fileSliceIndex
            )
            sliceCache.put(cacheKey, decryptedSlice)
            ensureReadAhead(objectID: objectID, layout: layout, servedSlice: fileSliceIndex)
            return decryptedSlice
        } else {
            // Plaintext streaming: batch slices via ObjectFetcher.
            let slicePlainOffset = Int64(localSliceIndex) * Int64(CryptoEngine.sliceSize)
            let remainingInChunk = chunk.plainSize - slicePlainOffset
            let batchBytes = min(
                Int64(Self.slicesPerFetch) * Int64(CryptoEngine.sliceSize),
                remainingInChunk
            )

            let raw = try await fetchWithRetry(
                fetcher, fileID: fileID, offset: slicePlainOffset, limit: batchBytes, objectID: objectID
            )

            var pieceStart = 0
            while pieceStart < raw.count {
                let pieceEnd = min(pieceStart + Int(CryptoEngine.sliceSize), raw.count)
                let piece = raw.subdata(in: pieceStart..<pieceEnd)
                sliceCache.put(
                    SliceCache.Key(
                        objectID: objectID,
                        sliceIndex: fileSliceIndex + pieceStart / Int(CryptoEngine.sliceSize)
                    ),
                    piece
                )
                pieceStart = pieceEnd
            }
            return sliceCache.get(cacheKey) ?? raw
        }
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
                    let firstSlice = Int(start / Int64(CryptoEngine.sliceSize))
                    let lastSlice = Int((end - 1) / Int64(CryptoEngine.sliceSize))
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
                        let sliceStart = Int64(sliceIndex) * Int64(CryptoEngine.sliceSize)
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

    // MARK: - Encrypted-path read-ahead

    /// Keeps the SliceCache filled ahead of the playhead for encrypted streams.
    /// Called after every served slice. Spawns a run only when NO live run already
    /// spans the position's needed window; never cancels healthy runs to start
    /// another one (that was the restart storm). Backward movement (seeks, mpv's
    /// tail probes) never triggers anything — uncached backward data is served by
    /// single fetches until playback advances past the old window.
    private func ensureReadAhead(objectID: String, layout: ObjectLayout, servedSlice: Int) {
        // Plaintext streaming batches on the serve path already (slicesPerFetch);
        // read-ahead is an encrypted-path-only mechanism.
        guard layout.objectKey != nil else { return }
        let totalSlices = Int((layout.fileSize + Int64(CryptoEngine.sliceSize) - 1) / Int64(CryptoEngine.sliceSize))
        guard servedSlice + 1 < totalSlices else { return }

        let windowEnd = min(totalSlices - 1, servedSlice + Self.readAheadWindowSlices)
        var start = servedSlice + 1
        while start <= windowEnd,
              sliceCache.contains(SliceCache.Key(objectID: objectID, sliceIndex: start)) {
            start += 1
        }
        guard start <= windowEnd else { return }

        stateLock.lock()
        // Only ACTIVE runs provide coverage — a finished run will never fetch
        // again and must not block spawning. Prune finished/cancelled entries.
        let liveRuns = (readAheadRuns[objectID] ?? []).filter { $0.isActive }
        readAheadRuns[objectID] = liveRuns

        // Covered when a live run either (a) has already filled everything we
        // need, or (b) is actively spanning our neighborhood and has progressed
        // close to us (within a batch) — it will reach us.
        let covered = liveRuns.contains { r in
            r.head >= start + Self.readAheadWindowSlices
                || (r.startSlice <= start + Self.readAheadBatchSlices
                    && r.endSlice >= start
                    && r.head + Self.readAheadBatchSlices >= start)
        }

        if !covered {
            let run = ReadAheadRun(start: start, end: windowEnd)
            var next = liveRuns
            if next.count >= Self.maxConcurrentRuns {
                // Replace the run whose span is FURTHEST from the current serve
                // position. Creation-age eviction would kill the long-lived
                // playhead run first (it is always the oldest); distance keeps the
                // run feeding the playhead and sheds stale/distant probes.
                let victim = next.max {
                    abs($0.startSlice - servedSlice) < abs($1.startSlice - servedSlice)
                } ?? next[0]
                next.removeAll { $0 === victim }
                victim.cancel()
            }
            next.append(run)
            readAheadRuns[objectID] = next
            stateLock.unlock()
            run.task = Task { [weak self] in
                await self?.readAheadLoop(objectID: objectID, layout: layout, run: run, from: start, end: windowEnd)
            }
            Self.streamLog("read-ahead start obj=\(objectID) slices=\(start)...\(windowEnd) (served=\(servedSlice))")
        } else {
            stateLock.unlock()
        }
    }

    /// Fills [from ... end] with decrypted slices, batched `readAheadBatchSlices`
    /// per TDLib round trip. Short-lived by design — it exits at the window edge or
    /// when cancelled, and the next served slice re-arms it. On failures it backs
    /// off and KEEPS TRYING (0.3 s doubling to a 5 s cap) instead of giving up:
    /// re-arming is driven by successful serves, which stop during a stall — a
    /// give-up here would leave the pipeline dead exactly when healing matters.
    private func readAheadLoop(
        objectID: String,
        layout: ObjectLayout,
        run: ReadAheadRun,
        from start: Int,
        end: Int
    ) async {
        var index = start
        var consecutiveFailures = 0
        while index <= end, !run.isCancelled, !Task.isCancelled {
            if sliceCache.contains(SliceCache.Key(objectID: objectID, sliceIndex: index)) {
                run.advance(to: index + 1)
                index += 1
                continue
            }
            do {
                let batchStartedAt = Date()
                let n = try await fetchEncryptedBatchIntoCache(
                    objectID: objectID,
                    layout: layout,
                    firstSlice: index,
                    maxCount: min(Self.readAheadBatchSlices, end - index + 1),
                    priority: 8
                )
                guard n > 0 else { break }
                run.advance(to: index + n)
                let ms = Int(Date().timeIntervalSince(batchStartedAt) * 1000)
                Self.streamLog("read-ahead batch obj=\(objectID) slices=\(index)+\(n) ms=\(ms)")
                index += n
                consecutiveFailures = 0
            } catch {
                if run.isCancelled || Task.isCancelled { break }
                consecutiveFailures += 1
                Self.streamLog("read-ahead FAIL #\(consecutiveFailures) obj=\(objectID) slice=\(index): \(error.localizedDescription)")
                let backoffNs = min(300_000_000 << min(consecutiveFailures - 1, 8), 5_000_000_000)
                try? await Task.sleep(nanoseconds: UInt64(backoffNs))
            }
        }
        if !run.isCancelled {
            run.finish()
            Self.streamLog("read-ahead end obj=\(objectID) at slice=\(index) (window \(start)...\(end))")
        }
    }

    /// Fetches up to `maxCount` sealed slices starting at `firstSlice` in ONE TDLib
    /// range request (clamped to the chunk boundary), decrypts each piece with its
    /// file-wide slice key, and caches them. Returns the number of slices covered
    /// INCLUDING any leading slices that were already cached by the time the fetch
    /// was about to start (a run batch we queued behind can fill them first —
    /// re-downloading would double the bandwidth bill on cold files).
    private func fetchEncryptedBatchIntoCache(
        objectID: String,
        layout: ObjectLayout,
        firstSlice requestedFirst: Int,
        maxCount requestedMax: Int,
        priority: Int
    ) async throws -> Int {
        guard let objectKey = layout.objectKey else { return 0 }
        // Skip leading slices filled meanwhile (race with a read-ahead run).
        var firstSlice = requestedFirst
        var maxCount = requestedMax
        while maxCount > 0,
              sliceCache.contains(SliceCache.Key(objectID: objectID, sliceIndex: firstSlice)) {
            firstSlice += 1
            maxCount -= 1
        }
        if maxCount <= 0 { return requestedMax }
        if firstSlice != requestedFirst {
            Self.streamLog("batch dedup obj=\(objectID) skipping \(firstSlice - requestedFirst) already-cached (requested \(requestedFirst))")
        }
        let (chunkIndex, localSliceIndex) = layout.chunkAndLocalIndex(for: firstSlice)
        let chunk = layout.chunks[chunkIndex]

        let plainRemainingInChunk = max(0, chunk.plainSize - Int64(localSliceIndex) * Int64(CryptoEngine.sliceSize))
        guard plainRemainingInChunk > 0 else { return 0 }

        let plan = Self.planEncryptedBatch(plainRemainingInChunk: plainRemainingInChunk, maxCount: maxCount)
        let count = plan.count
        guard count > 0 else { return 0 }
        let batchBytes = plan.batchBytes

        let fileID = try await self.fileID(for: objectID, chunkIndex: chunkIndex, layout: layout)
        let fetcher = self.fetcher(for: objectID, chunkIndex: chunkIndex)
        let cipherOffset = Int64(localSliceIndex) * Int64(CryptoEngine.sealedSliceSize)

        let raw = try await fetchWithRetry(
            fetcher, fileID: fileID, offset: cipherOffset, limit: batchBytes,
            objectID: objectID, priority: priority
        )
        guard raw.count >= Int(batchBytes) else { throw ShortRangeFetch() }

        var offsetInRaw = 0
        for i in 0..<count {
            let len = min(Int64(CryptoEngine.sliceSize), plainRemainingInChunk - Int64(i) * Int64(CryptoEngine.sliceSize)) + 28
            guard offsetInRaw + Int(len) <= raw.count else { break }
            let piece = raw.subdata(in: offsetInRaw..<(offsetInRaw + Int(len)))
            offsetInRaw += Int(len)
            do {
                let plain = try CryptoEngine.decryptSlice(piece, objectKey: objectKey, index: firstSlice + i)
                sliceCache.put(SliceCache.Key(objectID: objectID, sliceIndex: firstSlice + i), plain)
            } catch {
                // GCM auth failure — corrupt bytes; surface as retryable so the
                // loop refetches this range. Earlier pieces of the batch stay cached.
                throw ShortRangeFetch()
            }
        }
        return count
    }

    /// Pure planner for one encrypted batch request: clamps `maxCount` to the chunk
    /// remainder and computes the total sealed byte length. A batch must NEVER cross
    /// a chunk boundary (one fileId per chunk — crossing would read bytes past the
    /// document's end or attribute them to the wrong chunk). Exposed for unit tests.
    static func planEncryptedBatch(
        plainRemainingInChunk: Int64,
        maxCount: Int
    ) -> (count: Int, batchBytes: Int64) {
        let fullRemaining = Int(plainRemainingInChunk / Int64(CryptoEngine.sliceSize))
        let hasPartialTail = plainRemainingInChunk % Int64(CryptoEngine.sliceSize) != 0
        let count = min(maxCount, fullRemaining + (hasPartialTail ? 1 : 0))
        guard count > 0 else { return (0, 0) }
        // Sealed length per piece: full slices are uniform; the chunk's final
        // partial slice is shorter.
        var batchBytes: Int64 = 0
        for i in 0..<count {
            let plainLen = min(Int64(CryptoEngine.sliceSize), plainRemainingInChunk - Int64(i) * Int64(CryptoEngine.sliceSize))
            batchBytes += plainLen + 28
        }
        return (count, batchBytes)
    }

    /// Up to three attempts per range: a corrupted/partial download or GCM tag
    /// failure is transient; the fetcher chain is CANCELLED between attempts so a
    /// stale/superseded TDLib session can't poison the retry. If all three fail,
    /// the error propagates to the stream — the HTTP response dies and mpv retries
    /// the byte range with fresh state (clean failure, never a crash).
    ///
    /// IMPORTANT: a failed fetch must NEVER evict the object's cached slices. Cached
    /// slices were successfully fetched (and GCM-verified on the encrypted path) before
    /// being cached — they cannot be corrupted by a later failed request. Wiping the
    /// whole cache on one transient error threw away megabytes of buffered playback and
    /// turned a single network hiccup into permanent buffering.
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

    private func withFetchTimeout<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw FetchTimeout()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw FetchTimeout() }
            return result
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

        let objectKey: SymmetricKey?
        if let wrappedKey = object.wrappedKey, !wrappedKey.isEmpty {
            if let vaultKey = try? VaultManager.vaultKey(for: vault) {
                objectKey = try? CryptoEngine.unwrap(wrappedKey, with: vaultKey)
            } else {
                objectKey = nil
            }
        } else {
            objectKey = nil
        }

        var chunkLayouts: [ChunkLayout] = []
        var starts: [Int64] = []
        var offset: Int64 = 0
        for (idx, chunk) in chunks.enumerated() {
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
            let cipherSize = actual ?? chunk.size
            let plainSize: Int64
            if objectKey != nil {
                if idx == chunks.count - 1 {
                    plainSize = max(0, object.size - offset)
                } else {
                    let slices = Int64(cipherSize / Int64(CryptoEngine.sealedSliceSize))
                    plainSize = slices * Int64(CryptoEngine.sliceSize)
                }
            } else {
                plainSize = cipherSize
            }
            chunkLayouts.append(ChunkLayout(messageID: messageID, plainSize: plainSize))
            starts.append(offset)
            offset += plainSize
        }

        // Invariant: no slice may straddle two chunks. Every non-final chunk must be an
        // exact multiple of the 1 MB slice size (ChunkPlanner guarantees this for new
        // uploads); plans that violate it fall back to full download.
        let canStream = chunkLayouts.dropLast().allSatisfy {
            $0.plainSize % Int64(CryptoEngine.sliceSize) == 0
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
            canStream: canStream,
            objectKey: objectKey
        )
        Self.logger.info(
            "Stream layout \(objectID, privacy: .public): chunks=\(chunks.count, privacy: .public) size=\(object.size, privacy: .public) encrypted=\(objectKey != nil, privacy: .public) canStream=\(canStream, privacy: .public)"
        )
        Self.streamLog("layout built obj=\(objectID) chunks=\(chunks.count) size=\(object.size) encrypted=\(objectKey != nil) canStream=\(canStream)")

        stateLock.lock()
        // Evict least-recently-used layouts when over cap — NEVER the object being
        // inserted (the active playback). Victims' fetcher chains and read-ahead
        // runs are cancelled so no orphaned TDLib chains linger on their fileIds.
        var victimFetchers: [ObjectFetcher] = []
        while layouts.count >= Self.maxCachedLayouts,
              let oldest = layoutRecency.first {
            guard oldest != objectID else { break }
            layouts[oldest] = nil
            fileIDs[oldest] = nil
            victimFetchers.append(contentsOf: (fetchers.removeValue(forKey: oldest) ?? [:]).values)
            for run in readAheadRuns.removeValue(forKey: oldest) ?? [] {
                run.cancel()
            }
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
        let id = try await TelegramClient.shared.getFileId(chatId: layout.channelID, messageId: chunk.messageID)

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
        let readAhead = readAheadRuns.removeValue(forKey: objectID) ?? []
        stateLock.unlock()
        readAhead.forEach { $0.cancel() }
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
}

struct ObjectLayout {
    let fileSize: Int64
    let channelID: Int64
    let chunks: [ChunkLayout]
    let chunkStarts: [Int64]
    let contentType: String
    let canStream: Bool
    var objectKey: SymmetricKey? = nil

    /// Maps a file-wide plaintext slice index to its chunk and the slice's index
    /// *within that chunk* (indices restart at 0 per chunk).
    func chunkAndLocalIndex(for fileSliceIndex: Int) -> (chunk: Int, local: Int) {
        let sliceBytes = Int64(fileSliceIndex) * Int64(CryptoEngine.sliceSize)
        var lo = 0
        var hi = chunks.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            // `<=`: a slice landing EXACTLY on a chunk boundary belongs to the NEXT
            // chunk. With `<` the search stops one chunk early and returns local =
            // one-past-the-end (fetchLen 0 → range-fetch retry storms).
            if chunkStarts[mid] <= sliceBytes { lo = mid } else { hi = mid - 1 }
        }
        let local = Int((sliceBytes - chunkStarts[lo]) / Int64(CryptoEngine.sliceSize))
        return (lo, local)
    }
}

// MARK: - Serialized per-object range fetcher

/// Handle for one background read-ahead run. `head` is the furthest slice index
/// the run has filled (or skipped as cached); serve-path calls read it to decide
/// whether the window is still covered. `cancel()` stops the loop promptly on
/// seek / playback teardown.
final class ReadAheadRun: @unchecked Sendable {
    private let lock = NSLock()
    private var _start: Int
    private var _end: Int
    private var _head: Int
    private var _cancelled = false
    private var _finished = false
    var task: Task<Void, Never>?

    init(start: Int, end: Int) {
        _start = start
        _end = end
        _head = start
    }

    /// A run that exited normally (window filled or gave ground) must NOT count as
    /// coverage: it will never fetch again. Treating finished runs as covering let
    /// them silently block new spawns — background filling stopped and playback
    /// fell back to just-in-time single fetches (visible as buffering on cold
    /// files, where single fetches run at ~0.9 MB/s vs ~5 MB/s batched).
    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return !_cancelled && !_finished
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        _finished = true
    }

    var startSlice: Int {
        lock.lock(); defer { lock.unlock() }
        return _start
    }

    var endSlice: Int {
        lock.lock(); defer { lock.unlock() }
        return _end
    }

    var head: Int {
        lock.lock(); defer { lock.unlock() }
        return _head
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    func advance(to value: Int) {
        lock.lock(); defer { lock.unlock() }
        _head = max(_head, value)
    }

    func cancel() {
        lock.lock()
        _cancelled = true
        let t = task
        lock.unlock()
        t?.cancel()
    }
}

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
/// is 3 read-ahead runs × 48-slice windows = 144 slices, plus serve-path writes and
/// background probe traffic — the old 128 cap meant prefetchers could evict each
/// other's not-yet-consumed writes. 256 gives real headroom over that ceiling.
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

    /// Existence check that does NOT bump LRU recency (used by the read-ahead loop,
    /// which must not perturb eviction for slices mpv actually reads).
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
