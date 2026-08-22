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
        subsystem: "com.cascade.app",
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
        let dir = support.appendingPathComponent("\(AppPaths.dataFolder)/tmp", isDirectory: true)
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
        let dir = support.appendingPathComponent("\(AppPaths.dataFolder)/thumbs", isDirectory: true)
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
        existingTransferID: String? = nil,
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

        let objectKey: SymmetricKey?
        let wrappedKeyData: Data?
        if let resumeObject {
            if let existingWrapped = resumeObject.wrappedKey, !existingWrapped.isEmpty {
                let vaultKey = try VaultManager.vaultKey(for: vault)
                objectKey = try? CryptoEngine.unwrap(existingWrapped, with: vaultKey)
                wrappedKeyData = existingWrapped
            } else {
                objectKey = nil
                wrappedKeyData = nil
            }
        } else {
            let key = SymmetricKey(size: .bits256)
            let vaultKey = try VaultManager.vaultKey(for: vault)
            let wrapped = try CryptoEngine.wrap(key, with: vaultKey)
            objectKey = key
            wrappedKeyData = wrapped
        }

        var isParentPrivate = resumeObject?.isPrivate ?? isPrivate
        if resumeObject == nil, let parentID {
            let parentObj = (try? await DatabaseManager.shared.allObjects())?.first { $0.id == parentID }
            if let parentObj {
                isParentPrivate = parentObj.isPrivate
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
                wrappedKey: wrappedKeyData,
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

        let transferID: String
        if let existingID = existingTransferID, await TransferCenter.shared.items.contains(where: { $0.id == existingID }) {
            transferID = existingID
            await TransferCenter.shared.bindObjectID(transferID, objectID: objectID)
            // A resumed upload spends a few seconds in TDLib's silent revalidation
            // (re-hashing the staged partial before part uploads continue) — label
            // it truthfully instead of "Starting…".
            await TransferCenter.shared.update(
                transferID,
                progress: initialProgress,
                text: resumeObject != nil ? "Resuming…" : "Starting…"
            )
        } else {
            transferID = await TransferCenter.shared.begin(
                .upload,
                objectID: objectID,
                name: displayName,
                initialProgress: initialProgress,
                totalWork: Double(max(1, plan.items.count)),
                reuseExisting: resumeObject != nil
            )
        }
        func report(_ s: String, _ p: Double) {
            progress(s, p)
            Task { @MainActor in TransferCenter.shared.update(transferID, progress: p, text: s) }
        }

        // Immediate local thumbnail (only for non-private files), plus a small JPEG that
        // gets attached to every chunk message so Telegram permanently stores a preview
        // that survives local cache clears (blob videos get no auto-generated thumbnail).
        // Single pass: one subject-aware crop at 2x produces both the grid PNG and the
        // Telegram-attached JPEG. Photos included — they upload as documents, so the
        // attached thumbnail is their only stored preview (Telegram auto-generates
        // sizes only for real photo messages, which the vault never uses).
        var uploadThumbnailPath: String? = nil
        if !isParentPrivate {
            let ext = fileURL.pathExtension.lowercased()
            let isVideo = mime.hasPrefix("video/") || ["mp4", "mov", "m4v", "mkv", "avi", "webm", "3gp", "mpg", "mpeg", "ts", "flv", "wmv", "vob"].contains(ext)
            uploadThumbnailPath = await generateThumbnails(for: fileURL, objectID: objectID, isVideo: isVideo)
            if ["epub", "pdf", "txt", "md", "markdown", "cbz", "cbr"].contains(ext) {
                await generateBookCover(for: fileURL, objectID: objectID)
            }
        }

        // Single-chunk media goes in as real Telegram photo/video (if not private and unencrypted)
        let kind: TelegramClient.MediaKind
        let isSingleChunkVideo = mime.hasPrefix("video/") || ["mp4", "mov", "m4v", "mkv", "avi", "webm"].contains(fileURL.pathExtension.lowercased())
        if objectKey == nil && !isParentPrivate && plan.items.count == 1 && isSingleChunkVideo {
            kind = .video
        } else {
            kind = .document
        }

        // Pause aborts immediately: the in-flight chunk's send is cancelled (its
        // continuation is resumed with a cancellation error, so no message is posted
        // for it) and the token stops any chunk from starting at the next boundary.
        // The last fully-recorded chunk is untouched, so resume continues from there.
        let pauseToken = UploadPauseToken()
        // Hoisted so the OUTER catch (pause mid-chunk) can preserve the last known
        // in-flight fraction — for single-chunk files done=0 there, and reporting
        // 0/N visually resets the card to 0%.
        let progressState = ParallelUploadProgress(total: plan.items.count)

        let work = Task { () throws -> Void in
            do {
                let tmpDir = try tempDirectory()
                // Resume: the already-recorded chunks count toward the total, so the
                // displayed progress starts where the pause left off instead of 0.
                progressState.setCompleted(doneIndexes.count)

                // One chunk upload, fully independent of the others: it opens its own
                // file handle (a shared handle would race on seek), reads, writes a
                // temp file, uploads via Telegram, and records its own row.
                func uploadChunk(_ item: ChunkPlanItem) async throws {
                    if pauseToken.isCancelled { return }

                    let handle = try FileHandle(forReadingFrom: fileURL)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: UInt64(item.offset))

                    let chunkFileName: String
                    if objectKey != nil || isParentPrivate || plan.items.count > 1 {
                        chunkFileName = "\(objectID)-\(item.index).bin"
                    } else {
                        chunkFileName = displayName
                    }
                    let tmpURL = tmpDir.appendingPathComponent(chunkFileName)

                    // RESUME OPTIMIZATION: if a previous attempt staged this exact
                    // chunk (file exists with the exact expected sealed size), reuse
                    // it — same path + same bytes lets TDLib continue its cached
                    // upload progress instead of restarting, and we skip re-encrypting
                    // up to ~1.9 GiB. Size equality is the guard: a crash mid-write
                    // leaves a short file, which falls through to regeneration.
                    let expectedSliceCount = (Int64(item.size) + Int64(CryptoEngine.sliceSize) - 1) / Int64(CryptoEngine.sliceSize)
                    let expectedStagedSize: Int64 = objectKey != nil
                        ? Int64(item.size) + expectedSliceCount * 28
                        : Int64(item.size)
                    var reuseStaging = false
                    if let attrs = try? FileManager.default.attributesOfItem(
                        atPath: tmpURL.path(percentEncoded: false)
                    ), let sz = attrs[.size] as? NSNumber, sz.int64Value == expectedStagedSize {
                        reuseStaging = true
                        logger.info("reusing staged chunk \(item.index) (\(sz.int64Value) B) for resume")
                    }

                    if !reuseStaging {
                        FileManager.default.createFile(
                            atPath: tmpURL.path(percentEncoded: false), contents: nil
                        )
                    }
                    let outHandle = try FileHandle(forWritingTo: tmpURL)
                    defer { try? outHandle.close() }
                    if reuseStaging {
                        try outHandle.seekToEndOfFile()
                    }

                    var plainHasher: SHA256? = SHA256()
                    var cipherHasher: SHA256? = objectKey != nil ? SHA256() : nil

                    let uploadedByteCount: Int64
                    if reuseStaging {
                        // Staged file already holds the sealed bytes: hash source
                        // (plain) and staging (cipher) without re-encrypting.
                        plainHasher?.update(data: try readExactly(handle, count: Int(item.size)))
                        uploadedByteCount = item.size
                        if cipherHasher != nil {
                            let staged = try FileHandle(forReadingFrom: tmpURL)
                            defer { try? staged.close() }
                            var remaining = expectedStagedSize
                            while remaining > 0 {
                                let want = Int(min(4 * 1024 * 1024, remaining))
                                guard let chunkData = try staged.read(upToCount: want),
                                      !chunkData.isEmpty else { break }
                                cipherHasher?.update(data: chunkData)
                                remaining -= Int64(chunkData.count)
                            }
                        }
                    } else if let objectKey {
                        let startSliceIndex = Int(item.offset / Int64(CryptoEngine.sliceSize))
                        uploadedByteCount = try CryptoEngine.encryptStream(
                            from: handle, to: outHandle,
                            plainByteLimit: item.size,
                            objectKey: objectKey, startSliceIndex: startSliceIndex,
                            plainHasher: &plainHasher, cipherHasher: &cipherHasher
                        )
                    } else {
                        // Plaintext upload: byte-identical copy of the source range.
                        uploadedByteCount = try CryptoEngine.decryptStream(
                            from: handle, to: outHandle,
                            cipherByteLimit: item.size,
                            objectKey: nil, startSliceIndex: 0,
                            cipherHasher: &cipherHasher, plainHasher: &plainHasher
                        )
                    }
                    guard uploadedByteCount > 0 else { throw UploadError.readFailed }

                    let plainHash = plainHasher!.finalize().hexString
                    let cipherHash: String?
                    if var ch = cipherHasher {
                        cipherHash = ch.finalize().hexString
                    } else {
                        cipherHash = nil
                    }

                    var captionString: String? = nil
                    let meta = ChunkCaption.Meta(
                        kind: ChunkCaption.kindChunk,
                        id: objectID,
                        name: objectKey != nil ? "" : displayName,
                        size: fileSize,
                        mime: objectKey != nil ? "application/octet-stream" : mime,
                        parentID: parentID,
                        isPrivate: isParentPrivate,
                        isFolder: false,
                        trashed: false,
                        isFavorite: false,
                        index: item.index,
                        totalChunks: plan.items.count,
                        wrappedKey: wrappedKeyData?.base64EncodedString() ?? "",
                        chunkSize: plan.chunkSize,
                        plainHash: plainHash,
                        cipherHash: cipherHash,
                        rootHash: rootHash
                    )
                    captionString = ChunkCaption.encode(meta, kind: ChunkCaption.kindChunk)

                    progressState.setFraction(item.index, 0)
                    // Parallel sends finish in arbitrary order, so the in-flight label
                    // is intentionally aggregate (no per-chunk claim) — per-chunk
                    // numbers flicker backwards and read as a bug.
                    let messageId = try await TelegramClient.shared.sendFile(
                        chatId: vault.channelID,
                        path: tmpURL.path(percentEncoded: false),
                        kind: objectKey != nil ? .document : kind,
                        caption: captionString,
                        // Encrypted uploads NEVER attach the thumbnail: an attached
                        // JPEG is a plaintext preview sitting in the channel. The
                        // preview for these files is the encrypted sidecar document
                        // uploaded once after the chunks (see uploadThumbnailSidecar).
                        // Private (plaintext) files keep the attachment — their
                        // channel is private, so a visible preview is intended.
                        thumbnailPath: objectKey != nil ? nil : uploadThumbnailPath,
                        onProgress: { p in
                            progressState.setFraction(item.index, min(max(0.0, p), 1.0))
                            report("Uploading", min(progressState.overall, 0.99))
                        }
                    )
                    // Every chunk is mirrored into the backup channel (cheap
                    // reference forward — no re-upload of the bytes).
                    BackupSync.enqueue(messageID: messageId, objectID: objectID)

                    let chunk = ChunkRecord(
                        id: UUID().uuidString,
                        objectID: objectID,
                        index: item.index,
                        size: uploadedByteCount,
                        plainHash: plainHash,
                        cipherHash: cipherHash,
                        state: "uploaded",
                        messageID: messageId,
                        fileUniqueID: nil,
                        channelID: vault.channelID,
                        createdAt: .now
                    )
                    try await DatabaseManager.shared.save(chunk)

                    // The staging copy is transient — the chunk is in Telegram now.
                    // Delete it so completed uploads never accumulate .bin files in
                    // tmp (this was leaving gigabytes of orphans behind).
                    try? FileManager.default.removeItem(at: tmpURL)

                    progressState.complete(item.index)
                    report("Uploading", progressState.overall)
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
                    // continues exactly from here. Preserve the last known in-flight
                    // fraction — with uniform ~1.9 GiB chunks a single-chunk file has
                    // done=0 at pause time, and reporting 0/N would visually reset the
                    // card even though TDLib will resume the staged upload.
                    let done = ((try? await DatabaseManager.shared.chunks(for: objectID)) ?? [])
                        .filter { ($0.messageID ?? 0) > 0 }.count
                    let total = plan.items.count
                    let overall = progressState.overall
                    let doneRatio = total > 0 ? Double(done) / Double(total) : 0
                    let displayProgress = max(doneRatio, min(overall, 0.99))
                    let pauseText = total > 1 ? "Paused — \(done)/\(total) chunks" : "Paused"
                    _ = try? await DatabaseManager.shared.updateObject(objectID) {
                        $0.state = "paused"
                        $0.modifiedAt = .now
                    }
                    Task { @MainActor in
                        TransferCenter.shared.pause(
                            transferID,
                            progress: displayProgress,
                            text: pauseText
                        )
                    }
                    throw UploadError.cancelled
                }

                try await DatabaseManager.shared.updateObject(objectID) { $0.state = "ready" }

                // Encrypted uploads have no attached thumbnail (plaintext previews
                // in the channel are gone) — the preview is this sidecar: the same
                // ≤320px JPEG, AES-GCM sealed with the object key, posted as an
                // opaque document and linked via the object row. Skipped when a
                // sidecar already exists (resume) or the thumbnail could not be
                // generated. A sidecar failure logs and continues — the file is
                // complete; only its Telegram-backed preview is missing (the
                // local `<id>.png` still serves the current session).
                if let objectKey, let uploadThumbnailPath,
                   ((try? await DatabaseManager.shared.object(objectID))?.thumbMessageID) == nil {
                    do {
                        try await uploadThumbnailSidecar(
                            uploadPath: uploadThumbnailPath,
                            objectID: objectID,
                            objectKey: objectKey,
                            vault: vault
                        )
                    } catch {
                        logger.error("thumb sidecar upload failed: \(error.localizedDescription, privacy: .public)")
                    }
                }

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
                // TDLib preheat (item 164): pull each chunk document into TDLib's
                // local store in the background at low priority. Streaming then
                // serves from local disk (ms-level fetches, observed on rewatched
                // files) instead of network — this is exactly why previously
                // watched files never buffer while fresh uploads do.
                if !isParentPrivate {
                    let oid = objectID
                    let chatId = vault.channelID
                    Task.detached(priority: .utility) {
                        let chunks = (try? await DatabaseManager.shared.chunks(for: oid)) ?? []
                        for c in chunks {
                            guard !Task.isCancelled, let mid = c.messageID else { continue }
                            if let fid = try? await TelegramClient.shared.getFileId(chatId: chatId, messageId: mid) {
                                await TelegramClient.shared.beginBackgroundWarm(fileId: fid)
                            }
                        }
                    }
                }
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
                    // Preserve the last known in-flight fraction (single-chunk files
                    // have done=0 here — reporting 0/N visually resets the card).
                    let doneRatio = total > 0 ? Double(done) / Double(total) : 0
                    let displayProgress = max(doneRatio, min(progressState.overall, 0.99))
                    let pauseText = total > 1 ? "Paused — \(done)/\(total) chunks" : "Paused"
                    Task { @MainActor in
                        TransferCenter.shared.pause(
                            transferID,
                            progress: displayProgress,
                            text: pauseText
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
    /// videos use a representative frame captured by our own FFmpeg frame extractor
    /// (never QuickLook's black first frame); everything else (audio/docs) uses
    /// QuickLook's artwork thumbnail as the source, then the same face/saliency-aware
    /// square crop (ThumbnailCrop).
    private static func subjectThumbnail(for url: URL, isVideo: Bool) async -> NSImage? {
        let ext = url.pathExtension.lowercased()
        let imageExts = ["jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp"]
        if imageExts.contains(ext), let loaded = NSImage(contentsOf: url) {
            return loaded
        }

        // Audio files: extract real embedded artwork (Pure-Swift parser -> QuickLook -> FFmpeg attached pic)
        let audioExts = ["mp3", "m4a", "flac", "wav", "aac", "ogg", "wma", "aiff", "opus", "alac", "dsf", "ape", "m4b", "m4p"]
        if audioExts.contains(ext) {
            if let art = AudioArtworkParser.extractArtwork(from: url) {
                return art
            }
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: 640, height: 640),
                scale: 1,
                representationTypes: .thumbnail
            )
            if let thumb = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                return NSImage(cgImage: thumb.cgImage, size: NSSize(width: thumb.cgImage.width, height: thumb.cgImage.height))
            }
            if let frame = await VideoFrameExtractor.representativeFrame(from: url) {
                return frame
            }
            return nil
        }

        // Videos: extract representative frame with FFmpeg
        if isVideo, let frame = await VideoFrameExtractor.representativeFrame(from: url) {
            return frame
        }

        // Artwork request at 2x so the pair's PNG preview isn't upscaled from a
        // 1x thumbnail.
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 640, height: 640),
            scale: 1,
            representationTypes: .thumbnail
        )
        guard let thumb = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request) else { return nil }
        return NSImage(cgImage: thumb.cgImage, size: NSSize(width: thumb.cgImage.width, height: thumb.cgImage.height))
    }

    /// One source image, one subject-aware crop, two outputs: the 2x grid preview
    /// (`<id>.png`) and the Telegram-attached JPEG (`<id>-up.jpg`, ≤320px so it
    /// meets TDLib's inputThumbnail limit, progressive + gamma-optimized).
    /// Returns the upload JPEG path, used as the document thumbnail on every
    /// chunk message — Telegram permanently stores it, so after a local cache
    /// clear the app re-fetches it instead of losing the preview forever.
    static func generateThumbnails(for url: URL, objectID: String, isVideo: Bool = false) async -> String? {
        guard let source = await subjectThumbnail(for: url, isVideo: isVideo),
              let dir = try? thumbnailsDirectory() else { return nil }
        var uploadPath: String? = nil
        // Single Vision pass at 2x; the JPEG is a cheap downscale of the same crop.
        if let square = ThumbnailCrop.subjectSquare(source, target: 640) ?? ThumbnailCrop.aspectFit(source, maxDimension: 640) {
            if let tiff = square.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("\(objectID).png"))
            }
            if let jpgSquare = ThumbnailCrop.aspectFit(square, maxDimension: 320),
               let jpg = ThumbnailCrop.jpegData(from: jpgSquare, quality: 0.85) {
                let dest = dir.appendingPathComponent("\(objectID)-up.jpg")
                try? jpg.write(to: dest)
                if FileManager.default.fileExists(atPath: dest.path(percentEncoded: false)) {
                    uploadPath = dest.path(percentEncoded: false)
                }
            }
        }
        return uploadPath
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
              let jpg = ThumbnailCrop.jpegData(from: fitted, quality: 0.85),
              let dir = try? thumbnailsDirectory() else { return }
        let dest = dir.appendingPathComponent("\(objectID)-cover.jpg")
        try? jpg.write(to: dest)
    }

    // MARK: - Thumbnail sidecar

    /// Uploads the object's preview as its OWN tiny encrypted document: the
    /// ≤320px JPEG sealed with the object key (AES-GCM, same codec as chunks —
    /// a single 1 MB slice) and posted to the vault channel as an opaque
    /// `file.bin` with a `thumb` caption and NO thumbnail attachment, so the
    /// channel shows nothing but a name-less file. The messageID is recorded on
    /// the object row; ThumbnailService downloads + decrypts it after a local
    /// cache clear. Mirrored to the backup channel like every vault message.
    static func uploadThumbnailSidecar(
        uploadPath: String,
        objectID: String,
        objectKey: SymmetricKey,
        vault: VaultRecord
    ) async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: uploadPath))
        guard !data.isEmpty else { throw UploadError.readFailed }
        let encrypted = try CryptoEngine.encryptChunk(data, objectKey: objectKey, startSliceIndex: 0)
        let tmpURL = try tempDirectory().appendingPathComponent("\(objectID)-thumb.bin")
        try encrypted.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let messageId = try await TelegramClient.shared.sendFile(
            chatId: vault.channelID,
            path: tmpURL.path(percentEncoded: false),
            kind: .document,
            caption: ChunkCaption.thumbCaption(objectID: objectID),
            thumbnailPath: nil
        )
        BackupSync.enqueue(messageID: messageId, objectID: objectID)
        try await DatabaseManager.shared.updateObject(objectID) { $0.thumbMessageID = messageId }
        logger.info("thumb sidecar uploaded for \(objectID, privacy: .public) msg=\(messageId, privacy: .public)")
    }

    // MARK: - Subtitle sidecars

    /// Uploads a sidecar subtitle (.srt/.ass/…) for `video` as its own vault
    /// document and links it on the video's record. Bytes follow the video's own
    /// storage mode: AES-GCM sealed with the object key for private videos
    /// (single slice — the same codec the thumb sidecar uses), raw bytes for
    /// public videos. The caption carries only the video's object id
    /// (`cascade:{kind:"sub"}`), so VaultRepair's purge resolves ownership while
    /// the video exists. Mirrored to the backup channel like every vault message.
    static func uploadSubtitleSidecar(
        video: ObjectRecord,
        name: String,
        data: Data,
        vault: VaultRecord
    ) async throws -> Int64 {
        guard !data.isEmpty else { throw UploadError.readFailed }
        let payload: Data
        if let wrappedKey = video.wrappedKey, !wrappedKey.isEmpty {
            let vaultKey = try VaultManager.vaultKey(for: vault)
            let objectKey = try CryptoEngine.unwrap(wrappedKey, with: vaultKey)
            payload = try CryptoEngine.encryptChunk(data, objectKey: objectKey, startSliceIndex: 0)
        } else {
            payload = data
        }
        let safeName = (name as NSString).lastPathComponent
        let tmpURL = try tempDirectory().appendingPathComponent("\(video.id)-sub-\(UUID().uuidString).bin")
        try payload.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let messageId = try await TelegramClient.shared.sendFile(
            chatId: vault.channelID,
            path: tmpURL.path(percentEncoded: false),
            kind: .document,
            caption: ChunkCaption.subCaption(objectID: video.id),
            thumbnailPath: nil
        )
        BackupSync.enqueue(messageID: messageId, objectID: video.id)
        // updateObject bumps modifiedAt → the LWW snapshot merge keeps the new
        // linkage (and carries it to other devices) instead of reverting it.
        try await DatabaseManager.shared.updateObject(video.id) { record in
            var list = record.subtitleList.filter { $0.name != safeName }
            list.append(SubtitleSidecar(messageID: messageId, name: safeName))
            record.subtitleSidecars = ObjectRecord.encodedSubtitles(list)
        }
        logger.info("subtitle sidecar uploaded for \(video.id, privacy: .public) msg=\(messageId, privacy: .public) name=\(safeName, privacy: .public)")
        return messageId
    }

    /// Materializes one linked subtitle to scratch (`sub-<messageID>.<ext>`) so
    /// mpv can load it from disk: downloads the sidecar document by message ID,
    /// decrypts when the video is private, and returns the file URL. The result
    /// is cached per session (scratch is wiped at launch), so replaying the same
    /// video never re-downloads its subs.
    static func materializeSubtitle(
        video: ObjectRecord,
        sidecar: SubtitleSidecar,
        vault: VaultRecord
    ) async throws -> URL {
        let ext = (sidecar.name as NSString).pathExtension.lowercased()
        let dest = try DownloadEngine.scratchDirectory()
            .appendingPathComponent("sub-\(sidecar.messageID).\(ext.isEmpty ? "srt" : ext)")
        if FileManager.default.fileExists(atPath: dest.path(percentEncoded: false)),
           ((try? FileManager.default.attributesOfItem(atPath: dest.path(percentEncoded: false)))?[.size] as? Int64) ?? 0 > 0 {
            return dest
        }
        let tmp = try tempDirectory().appendingPathComponent("sub-\(sidecar.messageID).bin")
        try? FileManager.default.removeItem(at: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await TelegramClient.shared.downloadMessageFile(
            messageId: sidecar.messageID, chatId: vault.channelID, to: tmp
        )
        var plain = try Data(contentsOf: tmp)
        if let wrappedKey = video.wrappedKey, !wrappedKey.isEmpty {
            let vaultKey = try VaultManager.vaultKey(for: vault)
            let objectKey = try CryptoEngine.unwrap(wrappedKey, with: vaultKey)
            plain = try CryptoEngine.decryptChunk(plain, objectKey: objectKey, startSliceIndex: 0)
        }
        try plain.write(to: dest)
        return dest
    }

    // MARK: - Helpers

    /// Deletes a partial upload from Telegram and the local database (used by discard and TTL cleanup).
    static func cleanupPartialUpload(objectID: String) async {
        // 1. Gather Telegram message IDs BEFORE any local deletion so we can
        //    clean them out of the vault and backup channels.
        let object = try? await DatabaseManager.shared.object(objectID)
        var msgIDs: [Int64] = []
        if let thumbMsg = object?.thumbMessageID { msgIDs.append(thumbMsg) }
        msgIDs.append(contentsOf: (object?.subtitleList ?? []).map(\.messageID))
        let chunks = (try? await DatabaseManager.shared.chunks(for: objectID)) ?? []
        msgIDs.append(contentsOf: chunks.compactMap(\.messageID))

        // 2. Tombstone first so deletion-absolutism blocks stale-delta resurrection
        //    during the window between local delete and catalog republish.
        let now = Date()
        try? await DatabaseManager.shared.markTombstones(ids: [objectID], at: now)
        if let thumb = thumbnailURL(for: objectID) {
            try? FileManager.default.removeItem(at: thumb)
        }

        // 3. Remove Telegram messages from vault + backup channels.
        if !msgIDs.isEmpty {
            await BackupSync.deleteFromVaultAndBackup(messageIDs: msgIDs)
        }

        // 4. Drop the cached channel scan so the next snapshot sync fetches live
        //    state instead of merging a stale delta back into the catalog.
        if let vault = try? await DatabaseManager.shared.firstVault() {
            TelegramClient.shared.invalidateScanCache(chatId: vault.channelID)
        }

        // 5. Purge orphan sidecar/thumbnail messages created during upload.
        await VaultRepair.purgeOrphanedMessages()

        // 6. Hard-delete the local rows (now safe: messages gone, tombstone held
        //    long enough for the republished checkpoint to propagate).
        try? await DatabaseManager.shared.deleteObjectWithChunks(id: objectID)
        try? await DatabaseManager.shared.deleteBackupRows(objectID: objectID)

        // 7. Force-republish the checkpoint so the cloud catalog drops the object
        //    immediately — no stale delta can resurrect it on the next reconcile.
        _ = await CatalogSnapshot.publishCheckpointFromLocal(force: true)
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
            // Monotonic per chunk: TDLib can report a retried segment's progress
            // going backward (its uploaded_size resets while re-uploading the
            // part), which would make the aggregate dip (e.g. 70% -> 68%).
            fractions[index] = max(fractions[index] ?? 0, min(max(f, 0), 1))
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
