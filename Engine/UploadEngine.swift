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
    /// How many chunks of one file may be uploading at the same time. Each chunk is
    /// an independent Telegram document, so TDLib pipelines them; parallelism pays
    /// off when per-connection/per-session throttling or latency is the bottleneck.
    /// It can never exceed the ISP's raw bandwidth cap.
    static let maxConcurrentChunkUploads = 3

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
        let mime = Self.mimeType(for: fileURL)

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
            // Empty wrapped key = legacy/unencrypted record; treat as missing so we
            // generate a fresh key instead of throwing on a zero-length sealed box.
            if let wrapped = wrappedKey, !wrapped.isEmpty {
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

        // Immediate local thumbnail (only for non-private files), plus a small JPEG that
        // gets attached to every chunk message so Telegram permanently stores a preview
        // that survives local cache clears (blob videos get no auto-generated thumbnail).
        var uploadThumbnailPath: String? = nil
        if !isParentPrivate {
            let ext = fileURL.pathExtension.lowercased()
            let isVideo = mime.hasPrefix("video/") || ["mp4", "mov", "m4v", "mkv", "avi", "webm", "3gp", "mpg", "mpeg", "ts", "flv", "wmv", "vob"].contains(ext)
            if isVideo {
                // One capture, both outputs (grid .png + Telegram -up.jpg).
                uploadThumbnailPath = await generateVideoThumbnails(for: fileURL, objectID: objectID)
            } else {
                await generateThumbnail(for: fileURL, objectID: objectID)
                uploadThumbnailPath = await generateUploadThumbnail(for: fileURL, objectID: objectID)?.path(percentEncoded: false)
            }
            if ["epub", "pdf", "txt", "md", "markdown", "cbz", "cbr"].contains(ext) {
                await generateBookCover(for: fileURL, objectID: objectID)
            }
        }

        // Single-chunk media goes in as real Telegram photo/video (if not private)
        let kind: TelegramClient.MediaKind
        let isSingleChunkVideo = mime.hasPrefix("video/") || ["mp4", "mov", "m4v", "mkv", "avi", "webm"].contains(fileURL.pathExtension.lowercased())
        if !isParentPrivate && plan.items.count == 1 && isSingleChunkVideo {
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
                let tmpDir = try tempDirectory()
                let progressState = ParallelUploadProgress(total: plan.items.count)
                // Resume: the already-recorded chunks count toward the total, so the
                // displayed progress starts where the pause left off instead of 0.
                progressState.setCompleted(doneIndexes.count)

                // One chunk upload, fully independent of the others: it opens its own
                // file handle (a shared handle would race on seek), reads, encrypts,
                // writes a temp file, uploads via Telegram, and records its own row.
                func uploadChunk(_ item: ChunkPlanItem) async throws {
                    if pauseToken.isCancelled { return }

                    let handle = try FileHandle(forReadingFrom: fileURL)
                    defer { try? handle.close() }

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

                    progressState.setFraction(item.index, 0)
                    // Parallel sends finish in arbitrary order, so the in-flight label
                    // is intentionally aggregate (no per-chunk claim) — per-chunk
                    // numbers flicker backwards and read as a bug.
                    let messageId = try await TelegramClient.shared.sendFile(
                        chatId: vault.channelID,
                        path: tmpURL.path(percentEncoded: false),
                        kind: kind,
                        caption: captionString,
                        thumbnailPath: uploadThumbnailPath,
                        onProgress: { p in
                            progressState.setFraction(item.index, min(max(0.0, p), 1.0))
                            report("Uploading chunks…", min(progressState.overall, 0.99))
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

                    progressState.complete(item.index)
                    report("Uploaded \(progressState.completedCount)/\(plan.items.count) chunks", progressState.overall)
                }

                // Run up to `maxConcurrentChunkUploads` chunks at once. Each chunk is an
                // independent Telegram document, so TDLib pipelines the uploads; per-chunk
                // records keep pause/resume exactly as before (pause cancels every
                // in-flight send — none of them post a message — and resume re-uploads
                // only the chunks missing from the DB).
                try await withThrowingTaskGroup(of: Void.self) { group in
                    var iterator = plan.items
                        .filter { !doneIndexes.contains($0.index) }
                        .sorted { $0.index < $1.index }
                        .makeIterator()

                    // Seed the first batch.
                    for _ in 0..<UploadEngine.maxConcurrentChunkUploads {
                        if let item = iterator.next() {
                            group.addTask { try await uploadChunk(item) }
                        }
                    }
                    // Refill a slot each time a chunk finishes.
                    while let _ = try await group.next() {
                        if pauseToken.isCancelled || Task.isCancelled {
                            group.cancelAll()
                            break
                        }
                        if let item = iterator.next() {
                            group.addTask { try await uploadChunk(item) }
                        }
                    }
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

    /// Best-available subject-aware square thumbnail for any file type: images are
    /// cropped from the FULL-resolution source so Vision can reliably find faces;
    /// videos use a representative frame captured by our own mpv renderer (never
    /// QuickLook's black first frame); everything else (audio/docs) uses QuickLook's
    /// artwork thumbnail as the source, then the same face/saliency-aware square
    /// crop (ThumbnailCrop).
    static func subjectThumbnail(for url: URL, target: CGFloat, scale: CGFloat = 1, isVideo: Bool = false) async -> NSImage? {
        let ext = url.pathExtension.lowercased()
        let imageExts = ["jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp"]
        if imageExts.contains(ext), let loaded = NSImage(contentsOf: url) {
            return ThumbnailCrop.subjectSquare(loaded, target: target * scale)
        }

        // Videos: extract a representative frame with our own mpv renderer instead
        // of QuickLook, which always picks the FIRST frame — typically a black
        // title card (the black thumbnails users saw). QuickLook stays as the
        // fallback for files mpv can't capture (audio-only, undecodable).
        if isVideo,
           let frame = await VideoFrameExtractor.representativeFrame(from: url) {
            return ThumbnailCrop.subjectSquare(frame, target: target * scale)
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: target, height: target),
            scale: scale,
            representationTypes: .thumbnail
        )
        guard let thumb = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request) else { return nil }
        let ns = NSImage(cgImage: thumb.cgImage, size: NSSize(width: thumb.cgImage.width, height: thumb.cgImage.height))
        return ThumbnailCrop.subjectSquare(ns, target: target * scale)
    }

    /// Generates a small (≤320px) JPEG thumbnail from the source file and stores it at
    /// `<id>-up.jpg` in the thumbnails directory. This exact file is attached to every
    /// chunk message on upload, so Telegram permanently stores a thumbnail with the
    /// message — after a local cache clear wipes our thumbnails, the app re-fetches it
    /// from Telegram instead of losing the preview forever (blob-stored videos never
    /// get an auto-generated Telegram thumbnail, so we must supply our own).
    /// Single-capture video thumbnail pair: captures ONE representative frame
    /// with the FFmpeg frame extractor and writes both the grid preview
    /// (`<id>.png`, 2x) and the Telegram-attached JPEG (`<id>-up.jpg`, 1x).
    /// Returns the path of the upload JPEG (used as the document thumbnail on
    /// every chunk message). Fast path: a full capture costs a fraction of a
    /// second, so the pair is generated with a single pass.
    static func generateVideoThumbnails(for url: URL, objectID: String) async -> String? {
        guard let frame = await VideoFrameExtractor.representativeFrame(from: url),
              let dir = try? thumbnailsDirectory() else { return nil }
        var uploadPath: String? = nil
        if let square = ThumbnailCrop.subjectSquare(frame, target: 320),
           let tiff = square.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            let dest = dir.appendingPathComponent("\(objectID)-up.jpg")
            try? jpg.write(to: dest)
            uploadPath = FileManager.default.fileExists(atPath: dest.path(percentEncoded: false)) ? dest.path(percentEncoded: false) : nil
        }
        if let square = ThumbnailCrop.subjectSquare(frame, target: 320 * 2),
           let tiff = square.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("\(objectID).png"))
        }
        return uploadPath
    }

    static func generateUploadThumbnail(for url: URL, objectID: String, isVideo: Bool = false) async -> URL? {
        guard let image = await subjectThumbnail(for: url, target: 320, scale: 1, isVideo: isVideo),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpg = rep.representation(
                  using: .jpeg,
                  properties: [.compressionFactor: 0.8]
              ),
              let dir = try? thumbnailsDirectory() else { return nil }

        let dest = dir.appendingPathComponent("\(objectID)-up.jpg")
        try? jpg.write(to: dest)
        return FileManager.default.fileExists(atPath: dest.path(percentEncoded: false)) ? dest : nil
    }

    static func generateThumbnail(for url: URL, objectID: String, isVideo: Bool = false) async {
        guard let square = await subjectThumbnail(for: url, target: 320, scale: 2, isVideo: isVideo),
              let tiff = square.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(
                  using: NSBitmapImageRep.FileType.png,
                  properties: [:]
              ),
              let dir = try? thumbnailsDirectory() else { return }
        try? png.write(to: dir.appendingPathComponent("\(objectID).png"))
    }

    /// Book covers are portrait: QuickLook gives us the cover page/artwork, then
    /// a 2:3 center-crop + downscale so every cover fits the Library's poster
    /// shape exactly (imperfect art is cropped, never letterboxed). Stored as
    /// `<id>-cover.jpg`.
    static func generateBookCover(for url: URL, objectID: String) async {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 360, height: 540),
            scale: 2,
            representationTypes: .thumbnail
        )
        guard let rep = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request) else { return }
        let ns = NSImage(cgImage: rep.cgImage, size: NSSize(width: rep.cgImage.width, height: rep.cgImage.height))
        guard let fitted = ThumbnailCrop.coverPortrait(ns, maxDimension: 540),
              let tiff = fitted.tiffRepresentation,
              let imgRep = NSBitmapImageRep(data: tiff),
              let jpg = imgRep.representation(
                  using: .jpeg,
                  properties: [.compressionFactor: 0.82]
              ),
              let dir = try? thumbnailsDirectory() else { return }
        let dest = dir.appendingPathComponent("\(objectID)-cover.jpg")
        try? jpg.write(to: dest)
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

    /// Thread-safe aggregate of per-chunk progress for the parallel upload loop:
    /// completed chunks plus the fractional progress of in-flight ones, so the
    /// transfer card shows smooth collective progress like before.
    final class ParallelUploadProgress: @unchecked Sendable {
        private let lock = NSLock()
        private let total: Int
        private var completed: Int = 0
        private var fractions: [Int: Double] = [:]

        init(total: Int) {
            self.total = max(1, total)
        }

        func setFraction(_ index: Int, _ f: Double) {
            lock.lock()
            fractions[index] = min(max(f, 0), 1)
            lock.unlock()
        }

        func setCompleted(_ n: Int) {
            lock.lock()
            completed = min(max(0, n), total)
            lock.unlock()
        }

        var completedCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return completed
        }

        func complete(_ index: Int) {
            lock.lock()
            fractions[index] = nil
            completed += 1
            lock.unlock()
        }

        var overall: Double {
            lock.lock()
            defer { lock.unlock() }
            let sum = fractions.values.reduce(0, +)
            return min(Double(completed) + sum, Double(total)) / Double(total)
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

    static func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "avi": return "video/x-msvideo"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "m4v": return "video/x-m4v"
        case "ts": return "video/mp2t"
        case "flv": return "video/x-flv"
        case "wmv": return "video/x-ms-wmv"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "flac": return "audio/flac"
        case "wav": return "audio/wav"
        case "aac": return "audio/aac"
        case "ogg", "oga": return "audio/ogg"
        case "opus": return "audio/opus"
        case "epub": return "application/epub+zip"
        case "cbz": return "application/vnd.comicbook+zip"
        case "cbr": return "application/vnd.comicbook-rar"
        case "pdf": return "application/pdf"
        default:
            if let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType, mime != "application/octet-stream" {
                return mime
            }
            return "application/octet-stream"
        }
    }
}
