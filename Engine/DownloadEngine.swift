import Foundation
import CryptoKit
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
import os
import UniformTypeIdentifiers

enum DownloadError: Error, Sendable, LocalizedError {
    case fileNotFound
    case hashMismatch
    case noChunks
    case vaultMissing
    case cancelled
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .fileNotFound: return "File not found on Telegram."
        case .hashMismatch: return "File integrity check failed."
        case .noChunks: return "No chunks recorded for this file."
        case .vaultMissing: return "No vault channel configured."
        case .cancelled: return "Download cancelled."
        case .downloadFailed: return "Telegram download failed."
        }
    }
}

enum DownloadEngine {
    private static let logger = Logger(
        subsystem: "com.cascade.app",
        category: "download"
    )

    /// Scratch materialization directory. Since 2026-08-22 (item 159) the app
    /// keeps NO playback cache of its own — TDLib's downloaded-file store is the
    /// single cache (capped via optimizeStorage). This directory only holds
    /// short-lived plaintext files materialized on demand (books, thumbnails,
    /// exports, "open with default app") and is wiped at every launch.
    static func scratchDirectory() throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appendingPathComponent("\(AppPaths.dataFolder)/scratch", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Launch janitor for the single-cache architecture: wipes last session's
    /// scratch files and the LEGACY playback cache (pre-item-159) so its bytes
    /// are reclaimed without user action. Offline-pinned objects' files are
    /// SPARED — "Keep Downloaded" must survive relaunch. If the database is not
    /// readable yet the wipe is skipped entirely: silently deleting pinned data
    /// to save a few MB would break the guarantee the user explicitly asked for.
    static func cleanScratchAndLegacyCache() {
        let fm = FileManager.default
        if let legacy = try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ).appendingPathComponent("\(AppPaths.dataFolder)/cache", isDirectory: true) {
            do {
                let existed = fm.fileExists(atPath: legacy.path)
                if existed {
                    try fm.removeItem(at: legacy)
                    logger.info("Janitor: removed legacy playback cache")
                }
            } catch {
                logger.error("Janitor: legacy cache removal failed: \(error.localizedDescription)")
            }
        }
        // Legacy cache holds no pins by definition (pre-pin architecture) — wipe.
        guard let scratch = try? scratchDirectory() else { return }
        let pinned = DatabaseManager.shared.pinnedObjectIDs()
        if pinned.isEmpty && DatabaseManager.shared.hasStarted() == false {
            logger.info("Janitor: DB not started — skipping scratch wipe to protect pins")
            return
        }
        if let entries = try? fm.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil) {
            var removed = 0
            for url in entries where !isPinnedFile(url, pinned: pinned) {
                try? fm.removeItem(at: url)
                removed += 1
            }
            if removed > 0 {
                logger.info("Janitor: wiped \(removed) scratch file(s), kept \(pinned.count) pin(s)")
            }
        }
    }

    static func cacheDirectory() throws -> URL {
        try scratchDirectory()
    }

    static func cacheURL(for object: ObjectRecord) -> URL {
        let base = (try? cacheDirectory()) ?? URL.temporaryDirectory
        let ext = (object.name as NSString).pathExtension
        let fileName = ext.isEmpty ? object.id : "\(object.id).\(ext)"
        return base.appendingPathComponent(fileName)
    }

    /// True when `url` is the materialized copy of one of `pinned` object IDs —
    /// scratch names objects `<objectID>.<ext>` (or bare `<objectID>` with no
    /// extension), so the stem is the ID. Unit-testable pure helper.
    static func isPinnedFile(_ url: URL, pinned: Set<String>) -> Bool {
        guard !pinned.isEmpty else { return false }
        return pinned.contains(url.deletingPathExtension().lastPathComponent)
    }

    /// True only when a COMPLETE cached copy exists — non-empty AND exactly the
    /// recorded object size. A 0-byte leftover from an interrupted download must
    /// not count, and neither must a PARTIAL file (e.g. a thumbnail-only quiet
    /// download that was cut off by a quit): serving a truncated file "plays" an
    /// empty/cut-off stream and silently disables the mpv streaming path, which
    /// is gated on `!isCached`.
    static func isCached(_ object: ObjectRecord) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(
            atPath: cacheURL(for: object).path(percentEncoded: false)
        ), let size = attrs[.size] as? Int, size > 0 else { return false }
        return Int64(size) == object.size
    }

    static func download(
        object: ObjectRecord,
        progress: @escaping @Sendable (String, Double) -> Void,
        quiet: Bool = false
    ) async throws -> URL {
        let dest = cacheURL(for: object)
        if isCached(object) { return dest }

        // Evict before adding a new file so a large download never pushes the
        // cache past its budgets (cap + free-space floor).
        enforceCacheBudget()

        let chunks0 = (try? DatabaseManager.shared.chunks(for: object.id)) ?? []
        // Quiet mode (thumbnail-only downloads, background warm-up) skips the
        // Transfers UI entirely — no card, no progress, no cancel registration.
        let transferID: String? = quiet ? nil : await TransferCenter.shared.begin(
            .download,
            objectID: object.id,
            name: object.name,
            totalWork: Double(max(1, chunks0.count)),
            reuseExisting: true
        )
        // Hoisted so both report() and the catch block share them: the exact
        // resume state when the task is cancelled (pause) — which chunks fully
        // landed, how many plain bytes were appended to dest, and the last
        // overall fraction for the paused card.
        var completedChunks = 0
        var writtenTotal: Int64 = 0
        var lastOverall = 0.0

        func report(_ s: String, _ p: Double) {
            lastOverall = max(lastOverall, min(max(p, 0), 1))
            progress(s, p)
            if let transferID {
                Task { @MainActor in TransferCenter.shared.update(transferID, progress: p, text: s) }
            }
        }

        let work = Task { () throws -> URL in
            do {
                guard let vault = try DatabaseManager.shared.firstVault() else {
                    throw DownloadError.vaultMissing
                }
                let chunks = try DatabaseManager.shared.chunks(for: object.id)
                guard !chunks.isEmpty else { throw DownloadError.noChunks }

                // Pre-fetch messages so TDLib has them in its local cache
                await TelegramClient.shared.fetchRecentMessages(chatId: vault.channelID, limit: 200)

                let fm = FileManager.default
                let destPath = dest.path(percentEncoded: false)

                // Pause/resume: a previously paused download left a partial dest
                // file plus a recorded (completedChunks, plainBytes) state. If the
                // partial is intact, skip past the completed chunks and append from
                // the exact byte offset (TDLib separately resumes an interrupted
                // chunk from its own cached parts via fileId).
                var startIndex = 0
                var resumeBytes: Int64 = 0
                if let saved = loadResumeState(objectID: object.id),
                   saved.chunks > 0, saved.chunks < chunks.count,
                   let attrs = try? fm.attributesOfItem(atPath: destPath),
                   (attrs[.size] as? NSNumber)?.int64Value == saved.bytes {
                    startIndex = saved.chunks
                    resumeBytes = saved.bytes
                    logger.info("Download resume: \(saved.chunks)/\(chunks.count) chunks, \(saved.bytes) bytes already on disk")
                } else {
                    clearResumeState(objectID: object.id)
                    if fm.fileExists(atPath: destPath) { try fm.removeItem(at: dest) }
                    fm.createFile(atPath: destPath, contents: nil)
                }
                let tmpDir = try UploadEngine.tempDirectory()
                let total = Double(chunks.count)

                // A catalog with duplicate chunk rows (old plan + new plan for the
                // same message) must not write the message's bytes twice. Track the
                // message IDs already written and skip repeats.
                var writtenMessageIDs = Set<Int64>()
                var writtenBytes: Int64 = 0

                let handle = try FileHandle(forWritingTo: dest)
                defer { try? handle.close() }
                if startIndex > 0 {
                    try handle.seek(toOffset: UInt64(resumeBytes))
                    writtenBytes = resumeBytes
                }

                for (i, chunk) in chunks.enumerated() {
                    try Task.checkCancellation()
                    guard i >= startIndex else { continue }
                    guard let messageId = chunk.messageID else { throw DownloadError.fileNotFound }
                    guard writtenMessageIDs.insert(messageId).inserted else { continue }
                    let n = i + 1

                    report("Downloading chunk \(n)/\(chunks.count)", Double(i) / total)
                    let tmp = tmpDir.appendingPathComponent("dl-\(chunk.id).bin")
                    try await TelegramClient.shared.downloadMessageFile(
                        messageId: messageId,
                        chatId: vault.channelID,
                        to: tmp,
                        onProgress: { p in
                            let overallProgress = (Double(i) + min(max(0.0, p), 1.0)) / total
                            report("Downloading chunk \(n)/\(chunks.count)", min(overallProgress, 0.99))
                        }
                    )

                    report("Verifying chunk \(n)/\(chunks.count)", (Double(i) + 0.5) / total)

                    // Stream the downloaded document through verification +
                    // decryption one sealed slice at a time — never holds the
                    // chunk in RAM (chunks can be ~1.9 GB).
                    let inHandle = try FileHandle(forReadingFrom: tmp)
                    defer { try? inHandle.close() }
                    let tmpAttrs = try? fm.attributesOfItem(
                        atPath: tmp.path(percentEncoded: false)
                    )
                    let tmpSize = (tmpAttrs?[.size] as? NSNumber)?.int64Value ?? 0

                    var hasher: SHA256? = chunk.plainHash != nil ? SHA256() : nil

                    // Files are stored as plain bytes: copy the downloaded document
                    // straight into the destination while hashing it for verification.
                    var copied: Int64 = 0
                    while copied < tmpSize {
                        let want = Int(min(4 * 1024 * 1024, tmpSize - copied))
                        guard let piece = try inHandle.read(upToCount: want), !piece.isEmpty else {
                            throw DownloadError.fileNotFound
                        }
                        hasher?.update(data: piece)
                        try handle.write(contentsOf: piece)
                        copied += Int64(piece.count)
                    }

                    if let expectedPlain = chunk.plainHash {
                        var h = hasher!
                        if h.finalize().hexString != expectedPlain {
                            // Legacy fallback: images uploaded before per-chunk
                            // hashing may mismatch — accept a decodable image.
                            try handle.seek(toOffset: UInt64(writtenBytes))
                            let probe = try handle.read(upToCount: 64 * 1024 * 1024) ?? Data()
                            let imageOK: Bool = {
                                #if canImport(AppKit)
                                return NSImage(data: probe) != nil
                                #elseif canImport(UIKit)
                                return UIImage(data: probe) != nil
                                #else
                                return false
                                #endif
                            }()
                            if !(object.mime.hasPrefix("image/") && imageOK) {
                                throw DownloadError.hashMismatch
                            }
                            try handle.seekToEndOfFile()
                        }
                    }

                    writtenBytes += copied
                    completedChunks = i + 1
                    writtenTotal = writtenBytes

                    try? fm.removeItem(at: tmp)
                    report("Assembled chunk \(n)/\(chunks.count)", Double(n) / total)
                }

                try handle.close()
                clearResumeState(objectID: object.id)
                // The assembled file must be exactly the recorded size. Catches
                // catalog corruption (duplicated/missing chunk rows) even where
                // the root-hash check doesn't apply.
                guard writtenBytes == object.size else { throw DownloadError.hashMismatch }
                if let root = object.rootHash,
                   try FileHasher.sha256(of: dest) != root {
                    throw DownloadError.hashMismatch
                }

                report("Complete", 1.0)
                if let transferID {
                    Task { @MainActor in TransferCenter.shared.finish(transferID, success: true) }
                }
                logger.info("Download complete: \(object.name)")
                // Single-cache architecture: keep TDLib's downloaded-file store
                // under the user's cap right after adding to it.
                let capGB = UserDefaults.standard.integer(forKey: cacheCapKey)
                if capGB > 0 {
                    await TelegramClient.shared.enforceDownloadStoreCap(bytes: Int64(capGB) * 1_073_741_824)
                }
                #if os(macOS)
                await ThumbnailService.shared.generateAndSaveThumbnail(for: object, from: dest)
                #endif
                // Books: the download IS the trigger for cover generation (covers
                // are otherwise made at upload time; older uploads have none until
                // the book is next downloaded).
                if object.isBook {
                    await UploadEngine.generateBookCover(for: dest, objectID: object.id)
                }
                // Let open grids refresh when a generated thumb lands (e.g. a
                // video that was only downloaded when the user played it).
                if !quiet {
                    NotificationCenter.default.post(name: .xcThumbnailReady, object: nil)
                }
                enforceCacheBudget()
                return dest
            } catch {
                // Pause semantics: a cancelled download keeps its partial dest
                // file plus exact resume state, so Resume continues from the
                // last completed chunk at the exact byte offset (the in-flight
                // chunk is resumed inside TDLib from its cached parts). Any
                // other failure drops the partial so a retry starts clean.
                if Task.isCancelled, let transferID {
                    saveResumeState(objectID: object.id, chunks: completedChunks, bytes: writtenTotal)
                    await TransferCenter.shared.pause(transferID, progress: lastOverall, text: "Paused")
                    throw DownloadError.cancelled
                }
                clearResumeState(objectID: object.id)
                // Drop the partial file on any failure so a retry re-downloads cleanly from scratch
                try? FileManager.default.removeItem(at: dest)
                if Task.isCancelled {
                    throw DownloadError.cancelled
                }
                if let transferID {
                    Task { @MainActor in
                        TransferCenter.shared.finish(transferID, success: false, error: error.localizedDescription)
                    }
                }
                throw error
            }
        }
        if let transferID {
            await TransferCenter.shared.registerCancel(transferID) { work.cancel() }
        }

        do {
            return try await work.value
        } catch is CancellationError {
            throw DownloadError.cancelled
        }
    }

    // MARK: - Download pause/resume state
    //
    // Exact byte-offset bookkeeping for a paused download, persisted in
    // UserDefaults so Resume (even after a relaunch) can verify the partial
    // file and skip past completed chunks. Key format: "count:bytes".

    private static func resumeStateKey(_ objectID: String) -> String {
        "xc.dl.resume.\(objectID)"
    }

    static func saveResumeState(objectID: String, chunks: Int, bytes: Int64) {
        guard chunks > 0 else {
            clearResumeState(objectID: objectID)
            return
        }
        UserDefaults.standard.set("\(chunks):\(bytes)", forKey: resumeStateKey(objectID))
    }

    static func loadResumeState(objectID: String) -> (chunks: Int, bytes: Int64)? {
        guard let raw = UserDefaults.standard.string(forKey: resumeStateKey(objectID)) else { return nil }
        let parts = raw.split(separator: ":")
        guard parts.count == 2, let chunks = Int(parts[0]), let bytes = Int64(parts[1]) else {
            clearResumeState(objectID: objectID)
            return nil
        }
        return (chunks, bytes)
    }

    static func clearResumeState(objectID: String) {
        UserDefaults.standard.removeObject(forKey: resumeStateKey(objectID))
    }

    /// Drops any partial download artifacts for an object (discarded download):
    /// the partial cache file and its resume state.
    static func removePartialDownload(object: ObjectRecord) {
        clearResumeState(objectID: object.id)
        try? FileManager.default.removeItem(at: cacheURL(for: object))
    }

    // MARK: - Adaptive LRU Cache Management
    //
    // Two complementary budgets keep the disk from filling up:
    //   1. HARD CAP — the cache never exceeds `maxCacheSizeBytes` (default 5 GB,
    //      user-configurable in Settings; 0 = no hard cap).
    //   2. FREE-SPACE FLOOR — when the volume holding the cache drops below
    //      `minFreeSpaceBytes` (15 GB), oldest-accessed files are evicted until
    //      the disk breathes again. This mirrors how iCloud/Dropbox self-tune on
    //      any machine instead of applying one arbitrary cap to all of them.
    static let cacheCapKey = "xc.cacheCapGB"
    static let minFreeSpaceBytes: Int64 = 15 * 1024 * 1024 * 1024 // 15 GB

    /// Hard ceiling on the cache in bytes. Read from Settings (`xc.cacheCapGB`,
    /// in GB): absent → 5 GB default, explicit 0 → unlimited.
    static var maxCacheSizeBytes: Int64 {
        let raw = UserDefaults.standard.object(forKey: cacheCapKey) as? Int
        let gb = raw ?? 5
        guard gb > 0 else { return 0 }
        return Int64(gb) * 1024 * 1024 * 1024
    }

    /// Free bytes on the volume that holds the cache directory.
    static func freeDiskSpaceBytes() -> Int64? {
        if let dir = try? cacheDirectory(),
           let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage {
            return free
        }
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        return (attrs?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    /// Evicts oldest-accessed cached files until the hard cap and the free-space
    /// floor are both satisfied. Runs at launch, on a periodic timer, and around
    /// downloads. Files modified within the last 15 minutes are skipped — they
    /// are almost certainly in-flight downloads being written to the cache dir.
    /// Offline-pinned files ("Keep Downloaded") are exempt BOTH from eviction and
    /// from the size accounting: the budgets govern evictable data only, so pins
    /// never pressure unpinned files out of the cache (iCloud-style semantics —
    /// if pinned data fills the disk, that is what the user asked for).
    static func enforceCacheBudget() {
        guard let dir = try? cacheDirectory() else { return }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey, .attributeModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let pinned = DatabaseManager.shared.pinnedObjectIDs()

        var totalSize: Int64 = 0
        var items: [(url: URL, size: Int64, date: Date)] = []

        for file in files {
            // Pinned copies are permanent by definition.
            if isPinnedFile(file, pinned: pinned) { continue }
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey, .attributeModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            let date = values?.contentAccessDate ?? values?.attributeModificationDate ?? .distantPast
            totalSize += size
            items.append((url: file, size: size, date: date))
        }

        let cap = maxCacheSizeBytes
        var needToFree: Int64 = 0
        if cap > 0, totalSize > cap {
            needToFree = totalSize - cap
        }
        if let free = freeDiskSpaceBytes(), free < minFreeSpaceBytes {
            needToFree = max(needToFree, minFreeSpaceBytes - free)
        }
        guard needToFree > 0 else { return }

        items.sort { $0.date < $1.date }
        let cutoff = Date().addingTimeInterval(-15 * 60)
        var freed: Int64 = 0
        for item in items {
            if freed >= needToFree { break }
            // Protect in-flight downloads: a partial file being written right now
            // has a fresh modification date and must not be yanked mid-write.
            if let mod = try? item.url.resourceValues(forKeys: [.attributeModificationDateKey]).attributeModificationDate,
               mod > cutoff { continue }
            try? fm.removeItem(at: item.url)
            freed += item.size
        }
        if freed > 0 {
            logger.info("Cache cleanup: freed \(freed) bytes (needed \(needToFree))")
        }
    }
}

// MARK: - Local Vault Export Engine

actor ExportEngine {
    static let shared = ExportEngine()

    private let logger = Logger(subsystem: "com.cascade.app", category: "export")

    struct Progress: Sendable {
        var completedFiles: Int
        var totalFiles: Int
        var currentFile: String
        var isRunning: Bool
    }

    private var isCancelled = false

    func cancel() {
        isCancelled = true
    }

    /// Exports the specified objects (or the full vault catalog if `objectIDs` is empty)
    /// to the target local folder, preserving folder hierarchy.
    func export(
        objectIDs: [String]? = nil,
        to destinationURL: URL,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Int {
        isCancelled = false
        let allObjects = try await DatabaseManager.shared.allObjects()
            .filter { $0.tombstoneAt == nil && !$0.trashed }

        let objectsByID = Dictionary(uniqueKeysWithValues: allObjects.map { ($0.id, $0) })
        let exportSet: [ObjectRecord]

        if let objectIDs, !objectIDs.isEmpty {
            let requestedIDs = Set(objectIDs)
            exportSet = allObjects.filter { requestedIDs.contains($0.id) }
        } else {
            exportSet = allObjects
        }

        let nonFolderObjects = exportSet.filter { !$0.isFolder }
        let totalCount = nonFolderObjects.count
        var completedCount = 0

        func relativePath(for object: ObjectRecord) -> String {
            var components: [String] = [object.name]
            var currentParentID = object.parentID
            while let pid = currentParentID, let parent = objectsByID[pid] {
                components.insert(parent.name, at: 0)
                currentParentID = parent.parentID
            }
            return components.joined(separator: "/")
        }

        let fm = FileManager.default
        try fm.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        for obj in exportSet {
            guard !isCancelled else { break }

            let relPath = relativePath(for: obj)
            let targetURL = destinationURL.appendingPathComponent(relPath)

            if obj.isFolder {
                try? fm.createDirectory(at: targetURL, withIntermediateDirectories: true)
                continue
            }

            let parentDir = targetURL.deletingLastPathComponent()
            try? fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

            onProgress?(Progress(
                completedFiles: completedCount,
                totalFiles: totalCount,
                currentFile: obj.name,
                isRunning: true
            ))

            do {
                let downloadedURL = try await DownloadEngine.download(object: obj, progress: { _, _ in }, quiet: true)
                if fm.fileExists(atPath: targetURL.path) {
                    try? fm.removeItem(at: targetURL)
                }
                try fm.copyItem(at: downloadedURL, to: targetURL)
                completedCount += 1
            } catch {
                logger.error("Export failed for \(obj.name): \(error.localizedDescription)")
            }
        }

        onProgress?(Progress(
            completedFiles: completedCount,
            totalFiles: totalCount,
            currentFile: "",
            isRunning: false
        ))

        return completedCount
    }
}
