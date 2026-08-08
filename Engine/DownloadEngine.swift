import Foundation
import CryptoKit
import os

enum DownloadError: Error, Sendable, LocalizedError {
    case fileNotFound
    case hashMismatch
    case noChunks
    case vaultMissing

    var errorDescription: String? {
        switch self {
        case .fileNotFound: return "File not found on Telegram."
        case .hashMismatch: return "File integrity check failed."
        case .noChunks: return "No chunks recorded for this file."
        case .vaultMissing: return "No vault channel configured."
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

        let transferID = await TransferCenter.shared.begin(.download, objectID: object.id, name: object.name)
        func report(_ s: String, _ p: Double) {
            progress(s, p)
            Task { @MainActor in TransferCenter.shared.update(transferID, progress: p, text: s) }
        }

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
                guard let messageId = chunk.messageID else { throw DownloadError.fileNotFound }
                let n = i + 1

                report("Downloading chunk \(n)/\(chunks.count)", Double(i) / total)
                let tmp = tmpDir.appendingPathComponent("dl-\(chunk.id).bin")
                try await TelegramClient.shared.downloadMessageFile(
                    messageId: messageId,
                    chatId: vault.channelID,
                    to: tmp
                )

                report("Verifying chunk \(n)/\(chunks.count)", (Double(i) + 0.5) / total)
                let data = try Data(contentsOf: tmp)
                if objectKey == nil, let expected = chunk.plainHash,
                   FileHasher.sha256(of: data) != expected {
                    throw DownloadError.hashMismatch
                }

                if let key = objectKey {
                    // DECRYPT: Unseal 1MB AES-GCM slices
                    var offset = 0
                    var sliceIndex = 0
                    while offset < data.count {
                        let end = min(offset + CryptoEngine.sliceSize, data.count)
                        let slice = data.subdata(in: offset..<end)
                        let decrypted = try CryptoEngine.decryptSlice(slice, objectKey: key, index: sliceIndex)
                        handle.write(decrypted)
                        offset = end
                        sliceIndex += 1
                    }
                } else {
                    handle.write(data)
                }

                try? fm.removeItem(at: tmp)
                report("Assembled chunk \(n)/\(chunks.count)", Double(n) / total)
            }

            try handle.close()
            if let root = object.rootHash,
               try FileHasher.sha256(of: dest) != root {
                throw DownloadError.hashMismatch
            }

            report("Complete", 1.0)
            Task { @MainActor in TransferCenter.shared.finish(transferID, success: true) }
            logger.info("Download complete: \(object.name)")
            return dest
        } catch {
            Task { @MainActor in
                TransferCenter.shared.finish(transferID, success: false, error: error.localizedDescription)
            }
            throw error
        }
    }
}
