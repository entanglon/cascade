import Foundation
import CryptoKit
import AppKit
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

    static func cacheDirectory() throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appendingPathComponent("\(AppPaths.dataFolder)/cache", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cacheURL(for object: ObjectRecord) -> URL {
        let base = (try? cacheDirectory()) ?? URL.temporaryDirectory
        let ext = (object.name as NSString).pathExtension
        let fileName = ext.isEmpty ? object.id : "\(object.id).\(ext)"
        return base.appendingPathComponent(fileName)
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
        func report(_ s: String, _ p: Double) {
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

                let objectKey: SymmetricKey?
                if let wrappedKey = object.wrappedKey, !wrappedKey.isEmpty {
                    let vaultKey = try VaultManager.vaultKey(for: vault)
                    objectKey = try CryptoEngine.unwrap(wrappedKey, with: vaultKey)
                } else {
                    objectKey = nil
                }

                // Pre-fetch messages so TDLib has them in its local cache
                await TelegramClient.shared.fetchRecentMessages(chatId: vault.channelID, limit: 200)

                let fm = FileManager.default
                let destPath = dest.path(percentEncoded: false)
                if fm.fileExists(atPath: destPath) { try fm.removeItem(at: dest) }
                fm.createFile(atPath: destPath, contents: nil)
                let handle = try FileHandle(forWritingTo: dest)
                defer { try? handle.close() }

                let tmpDir = try UploadEngine.tempDirectory()
                let total = Double(chunks.count)

                // A catalog with duplicate chunk rows (old plan + new plan for the
                // same message) must not write the message's bytes twice. Track the
                // message IDs already written and skip repeats.
                var writtenMessageIDs = Set<Int64>()
                var writtenBytes: Int64 = 0

                for (i, chunk) in chunks.enumerated() {
                    try Task.checkCancellation()
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

                    var cipherHasher: SHA256? = chunk.cipherHash != nil ? SHA256() : nil
                    var plainHasher: SHA256? = chunk.plainHash != nil ? SHA256() : nil

                    let startSliceIndex = Int(writtenBytes / Int64(CryptoEngine.sliceSize))
                    let plainCount = try CryptoEngine.decryptStream(
                        from: inHandle, to: handle,
                        cipherByteLimit: tmpSize,
                        objectKey: objectKey,
                        startSliceIndex: startSliceIndex,
                        cipherHasher: &cipherHasher,
                        plainHasher: &plainHasher
                    )
                    guard plainCount > 0 || tmpSize == 0 else {
                        throw DownloadError.fileNotFound
                    }

                    if let expectedCipher = chunk.cipherHash {
                        var h = cipherHasher!
                        if h.finalize().hexString != expectedCipher {
                            throw DownloadError.hashMismatch
                        }
                    }
                    if let expectedPlain = chunk.plainHash {
                        var h = plainHasher!
                        if h.finalize().hexString != expectedPlain {
                            // Legacy fallback: images uploaded before per-chunk
                            // hashing may mismatch — accept a decodable image.
                            try handle.seek(toOffset: UInt64(writtenBytes))
                            let probe = try handle.read(upToCount: 64 * 1024 * 1024) ?? Data()
                            if !(object.mime.hasPrefix("image/") && NSImage(data: probe) != nil) {
                                throw DownloadError.hashMismatch
                            }
                            try handle.seekToEndOfFile()
                        }
                    }

                    writtenBytes += plainCount

                    try? fm.removeItem(at: tmp)
                    report("Assembled chunk \(n)/\(chunks.count)", Double(n) / total)
                }

                try handle.close()
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
                await ThumbnailService.shared.generateAndSaveThumbnail(for: object, from: dest)
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
    static func enforceCacheBudget() {
        guard let dir = try? cacheDirectory() else { return }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey, .attributeModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        var totalSize: Int64 = 0
        var items: [(url: URL, size: Int64, date: Date)] = []

        for file in files {
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
