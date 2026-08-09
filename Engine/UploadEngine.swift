import Foundation
import CryptoKit
import os
import UniformTypeIdentifiers
import QuickLookThumbnailing
import AppKit

enum UploadError: Error, Sendable, LocalizedError {
    case notAuthorized
    case readFailed
    case uploadFailed
    case cancelled
    case fileChanged

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Not authorized on Telegram."
        case .readFailed: return "Could not read the file."
        case .uploadFailed: return "Upload failed."
        case .cancelled: return "Upload cancelled."
        case .fileChanged: return "The file changed since this upload was interrupted. The partial upload was discarded — please upload the file again."
        }
    }
}

enum UploadEngine {
    private static let logger = Logger(
        subsystem: "com.xcloud.app",
        category: "upload"
    )

    // MARK: - Paths

    static func tempDirectory() throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appendingPathComponent("xCloud/tmp", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func thumbnailsDirectory() throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appendingPathComponent("xCloud/thumbs", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func thumbnailURL(for objectID: String) -> URL? {
        let fm = FileManager.default
        guard let dir = try? thumbnailsDirectory() else { return nil }
        let candidates = [
            dir.appendingPathComponent("\(objectID).jpg"),
            dir.appendingPathComponent("\(objectID).png"),
            dir.appendingPathComponent("\(objectID)-tg.jpg")
        ]
        for cand in candidates {
            if fm.fileExists(atPath: cand.path(percentEncoded: false)) {
                return cand
            }
        }
        return nil
    }

    // MARK: - Upload (plaintext, Telegram-native)

    static func upload(
        fileURL: URL,
        parentID: String? = nil,
        isPrivate: Bool = false,
        progress: @escaping @Sendable (String, Double) -> Void,
        resumeObject: ObjectRecord? = nil
    ) async throws {
        guard TelegramClient.shared.isAuthorized else {
            throw UploadError.notAuthorized
        }

        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }

        let vault = try await VaultManager.ensureVault()

        let fm = FileManager.default
        let attrs = try fm.attributesOfItem(atPath: fileURL.path(percentEncoded: false))
        guard let sizeNum = attrs[.size] as? NSNumber else {
            throw UploadError.readFailed
        }
        let fileSize = sizeNum.int64Value

        let objectID = resumeObject?.id ?? UUID().uuidString

        // Unique display name (icon.png -> icon (1).png) within current folder
        var displayName = resumeObject?.name ?? fileURL.lastPathComponent
        if resumeObject == nil {
            let existing = Set(
                ((try? await DatabaseManager.shared.allObjects()) ?? [])
                    .filter { !$0.trashed && $0.parentID == parentID }
                    .map(\.name)
            )
            if existing.contains(displayName) {
                let base = fileURL.deletingPathExtension().lastPathComponent
                let ext = fileURL.pathExtension
                var i = 1
                let candidate: (Int) -> String = { n in
                    ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
                }
                while existing.contains(candidate(i)) { i += 1 }
                displayName = candidate(i)
            }
        }

        // Resume must re-derive the exact chunk boundaries used by the original upload,
        // so the stored chunk size wins over the global profile constants.
        let plan = ChunkPlanner.plan(fileSize: fileSize, chunkSize: resumeObject?.chunkSize)
        let rootHash = try FileHasher.sha256(of: fileURL)
        let mime = UTType(filenameExtension: fileURL.pathExtension)?
            .preferredMIMEType ?? "application/octet-stream"

        // If the file on disk changed since the upload was interrupted, the stored chunks
        // no longer match it. Discard the stale partial rather than producing a corrupt file.
        if let resumeObject, let originalHash = resumeObject.rootHash, rootHash != originalHash {
            await cleanupPartialUpload(objectID: resumeObject.id)
            Task { @MainActor in TransferCenter.shared.removeItems(forObjectID: resumeObject.id) }
            throw UploadError.fileChanged
        }

        var isParentPrivate = resumeObject?.isPrivate ?? isPrivate
        if resumeObject == nil, let parentID {
            let parentObj = (try? await DatabaseManager.shared.allObjects())?.first { $0.id == parentID }
            if let parentObj {
                isParentPrivate = parentObj.isPrivate
            }
        }

        var objectKey: SymmetricKey? = nil
        var wrappedKey: Data? = resumeObject?.wrappedKey
        if isParentPrivate {
            let master = try CryptoEngine.masterKey()
            if let wrapped = wrappedKey {
                objectKey = try CryptoEngine.unwrap(wrapped, with: master)
            } else {
                let newKey = SymmetricKey(size: .bits256)
                wrappedKey = try CryptoEngine.wrap(newKey, with: master)
                objectKey = newKey
            }
        }

        if let resumeObject {
            try await DatabaseManager.shared.updateObject(resumeObject.id) {
                $0.state = "uploading"
                $0.sourcePath = fileURL.path(percentEncoded: false)
            }
        } else {
            let object = ObjectRecord(
                id: objectID,
                vaultID: vault.id,
                name: displayName,
                size: fileSize,
                mime: mime,
                state: "uploading",
                rootHash: rootHash,
                wrappedKey: wrappedKey,
                createdAt: .now,
                modifiedAt: .now,
                isFavorite: false,
                trashed: false,
                parentID: parentID,
                isFolder: false,
                isPrivate: isParentPrivate,
                sourcePath: fileURL.path(percentEncoded: false),
                chunkSize: plan.chunkSize
            )
            try await DatabaseManager.shared.save(object)
        }

        var doneIndexes: Set<Int> = []
        var initialProgress: Double = 0
        if let resumeObject {
            let existing = (try? await DatabaseManager.shared.chunks(for: resumeObject.id)) ?? []
            doneIndexes = Set(existing.compactMap { $0.messageID != nil ? $0.index : nil })
            initialProgress = Double(doneIndexes.count) / Double(max(1, plan.items.count))
        }

        let transferID = await TransferCenter.shared.begin(
            .upload,
            objectID: objectID,
            name: displayName,
            initialProgress: initialProgress,
            totalWork: Double(max(1, plan.items.count)),
            reuseExisting: resumeObject != nil
        )
        func report(_ s: String, _ p: Double) {
            progress(s, p)
            Task { @MainActor in TransferCenter.shared.update(transferID, progress: p, text: s) }
        }

        // Immediate local thumbnail (only for non-private files)
        if !isParentPrivate {
            await generateThumbnail(for: fileURL, objectID: objectID)
        }

        // Single-chunk media goes in as real Telegram photo/video (if not private)
        let kind: TelegramClient.MediaKind
        if !isParentPrivate && plan.items.count == 1 && mime.hasPrefix("video/") {
            kind = .video
        } else {
            kind = .document
        }

        // Pause aborts immediately: the in-flight chunk's send is cancelled (its
        // continuation is resumed with a cancellation error, so no message is posted
        // for it) and the token stops any chunk from starting at the next boundary.
        // The last fully-recorded chunk is untouched, so resume continues from there.
        let pauseToken = UploadPauseToken()

        let work = Task { () throws -> Void in
            do {
                let handle = try FileHandle(forReadingFrom: fileURL)
                defer { try? handle.close() }

                let tmpDir = try tempDirectory()
                let total = Double(plan.items.count)

                for item in plan.items where !doneIndexes.contains(item.index) {
                    if pauseToken.isCancelled { break }
                    let n = item.index + 1
                    report("Reading chunk \(n)/\(plan.items.count)",
                           Double(item.index) / total)

                    try handle.seek(toOffset: UInt64(item.offset))
                    let plain = try readExactly(handle, count: Int(item.size))
                    guard !plain.isEmpty else { throw UploadError.readFailed }
                    let plainHash = FileHasher.sha256(of: plain)

                    let chunkFileName: String
                    if isParentPrivate || plan.items.count > 1 {
                        chunkFileName = "\(objectID)-\(item.index).bin"
                    } else {
                        chunkFileName = displayName
                    }
                    let tmpURL = tmpDir.appendingPathComponent(chunkFileName)

                    if let key = objectKey {
                        // ENCRYPT: Slice into 1MB chunks and seal with AES-GCM
                        var encrypted = Data()
                        encrypted.reserveCapacity(plain.count + 64)
                        var offset = 0
                        var sliceIndex = 0
                        while offset < plain.count {
                            let end = min(offset + CryptoEngine.sliceSize, plain.count)
                            let slice = plain.subdata(in: offset..<end)
                            let sealed = try CryptoEngine.encryptSlice(slice, objectKey: key, index: sliceIndex)
                            encrypted.append(sealed)
                            offset = end
                            sliceIndex += 1
                        }
                        try encrypted.write(to: tmpURL)
                    } else {
                        // PLAINTEXT: Standard Telegram-native upload
                        try plain.write(to: tmpURL)
                    }

                    report("Uploading chunk \(n)/\(plan.items.count)", Double(item.index) / total)

                    var captionString: String? = nil
                    let meta: [String: Any] = [
                        "id": objectID,
                        "name": displayName,
                        "size": fileSize,
                        "mime": mime,
                        "parentID": parentID ?? "",
                        "isPrivate": isParentPrivate,
                        "isFolder": false,
                        "trashed": false,
                        "isFavorite": false,
                        "index": item.index,
                        "totalChunks": plan.items.count,
                        "wrappedKey": wrappedKey?.base64EncodedString() ?? ""
                    ]
                    if let jsonData = try? JSONSerialization.data(withJSONObject: meta),
                       let jsonStr = String(data: jsonData, encoding: .utf8) {
                        captionString = "xcloud:v1:" + jsonStr
                    }

                    let messageId = try await TelegramClient.shared.sendFile(
                        chatId: vault.channelID,
                        path: tmpURL.path(percentEncoded: false),
                        kind: kind,
                        caption: captionString,
                        onProgress: { p in
                            let overallProgress = (Double(item.index) + min(max(0.0, p), 1.0)) / total
                            report("Uploading chunk \(n)/\(plan.items.count)", min(overallProgress, 0.99))
                        }
                    )

                    let chunk = ChunkRecord(
                        id: UUID().uuidString,
                        objectID: objectID,
                        index: item.index,
                        size: item.size,
                        plainHash: plainHash,
                        cipherHash: nil,
                        state: "uploaded",
                        messageID: messageId,
                        fileUniqueID: nil,
                        channelID: vault.channelID,
                        createdAt: .now
                    )
                    try await DatabaseManager.shared.save(chunk)

                    report("Uploaded chunk \(n)/\(plan.items.count)", Double(n) / total)
                }

                if pauseToken.isCancelled {
                    // Paused between chunks: every posted chunk was recorded, so resume
                    // continues exactly from here.
                    _ = try? await DatabaseManager.shared.updateObject(objectID) {
                        $0.state = "paused"
                        $0.modifiedAt = .now
                    }
                    let done = ((try? await DatabaseManager.shared.chunks(for: objectID)) ?? [])
                        .filter { ($0.messageID ?? 0) > 0 }.count
                    let total = plan.items.count
                    Task { @MainActor in
                        TransferCenter.shared.pause(
                            transferID,
                            progress: total > 0 ? Double(done) / Double(total) : 0,
                            text: "Paused — \(done)/\(total) chunks uploaded"
                        )
                    }
                    throw UploadError.cancelled
                }

                try await DatabaseManager.shared.updateObject(objectID) { $0.state = "ready" }

                // Populate local cache for instant (0ms) double-click previews
                if let cacheDir = try? DownloadEngine.cacheDirectory() {
                    let ext = fileURL.pathExtension
                    let fileName = ext.isEmpty ? objectID : "\(objectID).\(ext)"
                    let dest = cacheDir.appendingPathComponent(fileName)
                    let fm = FileManager.default
                    if !fm.fileExists(atPath: dest.path(percentEncoded: false)) {
                        try? fm.copyItem(at: fileURL, to: dest)
                    }
                }

                report("Complete", 1.0)
                Task { @MainActor in TransferCenter.shared.finish(transferID, success: true) }
                logger.info("Upload complete: \(plan.items.count) chunk(s) stored in vault")
            } catch {
                // Pause requested mid-chunk or the task was cancelled externally: keep the
                // uploaded chunks in Telegram + DB so the upload can resume from the last
                // recorded chunk. Chunks posted before the cancellation were recorded.
                if pauseToken.isCancelled || Task.isCancelled {
                    _ = try? await DatabaseManager.shared.updateObject(objectID) {
                        $0.state = "paused"
                        $0.modifiedAt = .now
                    }
                    let done = ((try? await DatabaseManager.shared.chunks(for: objectID)) ?? [])
                        .filter { ($0.messageID ?? 0) > 0 }.count
                    let total = plan.items.count
                    Task { @MainActor in
                        TransferCenter.shared.pause(
                            transferID,
                            progress: total > 0 ? Double(done) / Double(total) : 0,
                            text: "Paused — \(done)/\(total) chunks uploaded"
                        )
                    }
                    throw UploadError.cancelled
                }
                _ = try? await DatabaseManager.shared.updateObject(objectID) {
                    $0.state = "failed"
                    $0.modifiedAt = .now
                }
                Task { @MainActor in
                    TransferCenter.shared.finish(transferID, success: false, error: error.localizedDescription)
                }
                throw error
            }
        }
        await TransferCenter.shared.registerCancel(transferID) {
            pauseToken.cancel()
            work.cancel()
        }

        do {
            try await work.value
        } catch is CancellationError {
            throw UploadError.cancelled
        }
    }

    // MARK: - Thumbnail

    static func generateThumbnail(for url: URL, objectID: String) async {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 320, height: 320),
            scale: 2,
            representationTypes: .thumbnail
        )

        guard let thumb = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request) else { return }

        let rep = NSBitmapImageRep(cgImage: thumb.cgImage)
        guard let png = rep.representation(
            using: NSBitmapImageRep.FileType.png,
            properties: [:]
        ),
              let dir = try? thumbnailsDirectory() else { return }
        try? png.write(to: dir.appendingPathComponent("\(objectID).png"))
    }

    // MARK: - Helpers

    /// Deletes a partial upload from Telegram and the local database (used by discard and TTL cleanup).
    static func cleanupPartialUpload(objectID: String) async {
        let chunks = (try? await DatabaseManager.shared.chunks(for: objectID)) ?? []
        let msgIDs = chunks.compactMap { $0.messageID }
        if !msgIDs.isEmpty, let vault = try? await DatabaseManager.shared.firstVault() {
            for i in stride(from: 0, to: msgIDs.count, by: 100) {
                let batch = Array(msgIDs[i..<min(i + 100, msgIDs.count)])
                try? await TelegramClient.shared.deleteMessages(chatId: vault.channelID, messageIds: batch)
            }
        }
        try? await DatabaseManager.shared.deleteObjectWithChunks(id: objectID)
        if let thumb = thumbnailURL(for: objectID) {
            try? FileManager.default.removeItem(at: thumb)
        }
    }

    /// Thread-safe cooperative pause flag. The upload engine only reads it between
    /// chunks, so an in-flight chunk always finishes posting and being recorded first.
    private final class UploadPauseToken: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false

        func cancel() {
            lock.lock()
            flag = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return flag
        }
    }

    private static func readExactly(
        _ handle: FileHandle,
        count: Int
    ) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        var remaining = count
        while remaining > 0 {
            guard let piece = try handle.read(
                upToCount: min(remaining, 8 * 1024 * 1024)
            ), !piece.isEmpty else { break }
            data.append(piece)
            remaining -= piece.count
        }
        return data
    }
}
