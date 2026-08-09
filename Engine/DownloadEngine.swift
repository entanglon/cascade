import Foundation
import AppKit
import CryptoKit
import os
import UniformTypeIdentifiers

enum DownloadError: Error, Sendable, LocalizedError {
    case fileNotFound
    case hashMismatch
    case noChunks
    case vaultMissing
    case cancelled

    var errorDescription: String? {
        switch self {
        case .fileNotFound: return "File not found on Telegram."
        case .hashMismatch: return "File integrity check failed."
        case .noChunks: return "No chunks recorded for this file."
        case .vaultMissing: return "No vault channel configured."
        case .cancelled: return "Download cancelled."
        }
    }
}

enum DownloadEngine {
    private static let logger = Logger(
        subsystem: "com.xcloud.app",
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
        let dir = support.appendingPathComponent("xCloud/cache", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cacheURL(for object: ObjectRecord) -> URL {
        let base = (try? cacheDirectory()) ?? URL.temporaryDirectory
        let ext = (object.name as NSString).pathExtension
        let fileName = ext.isEmpty ? object.id : "\(object.id).\(ext)"
        return base.appendingPathComponent(fileName)
    }

    static func isCached(_ object: ObjectRecord) -> Bool {
        FileManager.default.fileExists(
            atPath: cacheURL(for: object).path(percentEncoded: false)
        )
    }

    static func download(
        object: ObjectRecord,
        progress: @escaping @Sendable (String, Double) -> Void
    ) async throws -> URL {
        let dest = cacheURL(for: object)
        if isCached(object) { return dest }

        let chunks0 = (try? DatabaseManager.shared.chunks(for: object.id)) ?? []
        let transferID = await TransferCenter.shared.begin(
            .download,
            objectID: object.id,
            name: object.name,
            totalWork: Double(max(1, chunks0.count)),
            reuseExisting: true
        )
        func report(_ s: String, _ p: Double) {
            progress(s, p)
            Task { @MainActor in TransferCenter.shared.update(transferID, progress: p, text: s) }
        }

        let work = Task { () throws -> URL in
            do {
                var objectKey: SymmetricKey? = nil
                if let wrapped = object.wrappedKey {
                    let master = try CryptoEngine.masterKey()
                    objectKey = try CryptoEngine.unwrap(wrapped, with: master)
                }

                guard let vault = try DatabaseManager.shared.firstVault() else {
                    throw DownloadError.vaultMissing
                }
                let chunks = try DatabaseManager.shared.chunks(for: object.id)
                guard !chunks.isEmpty else { throw DownloadError.noChunks }

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

                for (i, chunk) in chunks.enumerated() {
                    try Task.checkCancellation()
                    guard let messageId = chunk.messageID else { throw DownloadError.fileNotFound }
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
                    let data = try Data(contentsOf: tmp)

                    if let key = objectKey {
                        // DECRYPT: Unseal AES-GCM slices using sealedSliceSize (sliceSize + 28B overhead)
                        var offset = 0
                        var sliceIndex = 0
                        var decryptedChunkData = Data()
                        decryptedChunkData.reserveCapacity(data.count)

                        while offset < data.count {
                            let end = min(offset + CryptoEngine.sealedSliceSize, data.count)
                            let slice = data.subdata(in: offset..<end)
                            let decrypted = try CryptoEngine.decryptSlice(slice, objectKey: key, index: sliceIndex)
                            decryptedChunkData.append(decrypted)
                            offset = end
                            sliceIndex += 1
                        }

                        if let expected = chunk.plainHash,
                           FileHasher.sha256(of: decryptedChunkData) != expected {
                            throw DownloadError.hashMismatch
                        }

                        handle.write(decryptedChunkData)
                    } else {
                        if let expected = chunk.plainHash,
                           FileHasher.sha256(of: data) != expected {
                            if !(object.mime.hasPrefix("image/") && NSImage(data: data) != nil) {
                                throw DownloadError.hashMismatch
                            }
                        }

                        handle.write(data)
                    }

                    try? fm.removeItem(at: tmp)
                    report("Assembled chunk \(n)/\(chunks.count)", Double(n) / total)
                }

                try handle.close()
                if objectKey != nil, let root = object.rootHash,
                   try FileHasher.sha256(of: dest) != root {
                    throw DownloadError.hashMismatch
                }

                report("Complete", 1.0)
                Task { @MainActor in TransferCenter.shared.finish(transferID, success: true) }
                logger.info("Download complete: \(object.name)")
                await ThumbnailService.shared.generateAndSaveThumbnail(for: object, from: dest)
                cleanCacheIfOverLimit()
                return dest
            } catch {
                // Drop the partial file on any failure so a retry re-downloads cleanly from scratch
                try? FileManager.default.removeItem(at: dest)
                if Task.isCancelled {
                    throw DownloadError.cancelled
                }
                Task { @MainActor in
                    TransferCenter.shared.finish(transferID, success: false, error: error.localizedDescription)
                }
                throw error
            }
        }
        await TransferCenter.shared.registerCancel(transferID) { work.cancel() }

        do {
            return try await work.value
        } catch is CancellationError {
            throw DownloadError.cancelled
        }
    }

    // MARK: - LRU Cache Management (Default 5GB Limit)
    static let maxCacheSizeBytes: Int64 = 5 * 1024 * 1024 * 1024 // 5 GB

    static func cleanCacheIfOverLimit() {
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

        if totalSize > maxCacheSizeBytes {
            items.sort { $0.date < $1.date }
            var currentTotal = totalSize
            for item in items {
                if currentTotal <= maxCacheSizeBytes { break }
                try? fm.removeItem(at: item.url)
                currentTotal -= item.size
            }
        }
    }
}
