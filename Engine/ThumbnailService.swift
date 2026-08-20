import Foundation
import AppKit
import Vision
import OSLog
import UniformTypeIdentifiers
import QuickLookThumbnailing

extension Notification.Name {
    static let xcThumbnailReady = Notification.Name("xc.thumbnailReady")
}

/// Squares and downscales an image for thumbnails, centering the crop on the
/// SUBJECT so the important content (a model's face!) stays visible instead of
/// being cut off by a naive center crop: the largest face wins, then the
/// attention-saliency region, then the plain center. EXIF orientation is baked
/// into upright pixels first so Vision sees the photo the way the user does.
enum ThumbnailCrop {
    static func subjectSquare(_ image: NSImage, target: CGFloat) -> NSImage? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage else { return nil }
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let side = min(w, h)
        guard side > 0 else { return nil }

        guard let cropped = cg.cropping(to: subjectCropRect(cg: cg, side: side)) else { return nil }

        // Downscale with a CGContext (deterministic and thread-safe — this runs on
        // ThumbnailService's actor executor, not the main thread).
        let target = Int(target.rounded())
        guard target > 0,
              let ctx = CGContext(
                  data: nil, width: target, height: target,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: target, height: target))
        guard let outCG = ctx.makeImage() else { return nil }
        return NSImage(cgImage: outCG, size: NSSize(width: target, height: target))
    }

    /// Largest square crop rect anchored on the subject. Vision returns normalized
    /// rects with the origin at the BOTTOM-left; CGImage.cropping works in
    /// TOP-left pixel coordinates, so the Y axis is flipped back.
    private static func subjectCropRect(cg: CGImage, side: CGFloat) -> CGRect {
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)

        // Normalized anchor in Vision space (bottom-left origin, 0...1): center by
        // default, largest face if any, else the most salient region.
        var anchor = CGPoint(x: 0.5, y: 0.5)
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])

        let faceReq = VNDetectFaceRectanglesRequest()
        try? handler.perform([faceReq])
        if let face = faceReq.results?.first {
            anchor = CGPoint(x: face.boundingBox.midX, y: face.boundingBox.midY)
        } else {
            let salReq = VNGenerateAttentionBasedSaliencyImageRequest()
            try? handler.perform([salReq])
            if let sal = salReq.results?.first as? VNSaliencyImageObservation,
               let obj = sal.salientObjects?.first {
                anchor = CGPoint(x: obj.boundingBox.midX, y: obj.boundingBox.midY)
            }
        }

        // Clamp so the square stays fully inside the image, then flip Y for
        // CGImage's top-left pixel space.
        let minNormX = side / (2 * w)
        let maxNormX = 1 - minNormX
        let minNormY = side / (2 * h)
        let maxNormY = 1 - minNormY
        let cx = min(max(anchor.x, minNormX), maxNormX) * w
        let cy = min(max(anchor.y, minNormY), maxNormY) * h

        var rect = CGRect(x: cx - side / 2, y: (h - cy) - side / 2, width: side, height: side)
        // Snap to integer pixels and clamp inside bounds (cropping fails on
        // fractional/out-of-bounds rects).
        rect.origin.x = rect.origin.x.rounded()
        rect.origin.y = rect.origin.y.rounded()
        rect.size.width = rect.size.width.rounded()
        rect.size.height = rect.size.height.rounded()
        if rect.maxX > w { rect.origin.x = w - rect.width }
        if rect.maxY > h { rect.origin.y = h - rect.height }
        if rect.minX < 0 { rect.origin.x = 0 }
        if rect.minY < 0 { rect.origin.y = 0 }
        return rect
    }

    /// Book covers are portrait — downscale the cover art as-is (no square crop)
    /// so the Library's poster cards show the full cover, not a center chunk.
    static func aspectFit(_ image: NSImage, maxDimension: CGFloat) -> NSImage? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage else { return nil }
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        guard w > 0, h > 0 else { return nil }
        let scale = min(1, maxDimension / max(w, h))
        let outW = Int((w * scale).rounded())
        let outH = Int((h * scale).rounded())
        guard outW > 0, outH > 0,
              let ctx = CGContext(
                  data: nil, width: outW, height: outH,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        guard let outCG = ctx.makeImage() else { return nil }
        return NSImage(cgImage: outCG, size: NSSize(width: outW, height: outH))
    }

    /// JPEG-encodes an image with ImageIO: gamma-aware color optimization (kills
    /// banding in dark gradients), optional progressive scan, and a quality in
    /// 0...1. Better quality-per-byte than NSBitmapImageRep's JPEG encoder, which
    /// applies neither. This is the single encoder for every JPEG the app writes
    /// (grid previews, Telegram-attached upload thumbnails, book covers).
    static func jpegData(from image: NSImage, quality: Double, progressive: Bool = true) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        var props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImageDestinationOptimizeColorForSharing: true,
        ]
        if progressive {
            props[kCGImagePropertyJFIFDictionary] = [kCGImagePropertyJFIFIsProgressive: true]
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Book-cover crop: center-crops to a 2:3 portrait frame when the artwork
    /// isn't already close to 2:3, then downscales. Imperfect covers (odd
    /// dimensions, PDF first pages) get cropped to fit the poster shape instead
    /// of letterboxing — books whose covers are already 2:3 are untouched.
    static func coverPortrait(_ image: NSImage, maxDimension: CGFloat) -> NSImage? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage else { return nil }
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        guard w > 0, h > 0 else { return nil }

        let targetRatio: CGFloat = 2.0 / 3.0
        let sourceRatio = w / h
        var cropRect = CGRect(x: 0, y: 0, width: w, height: h)
        if sourceRatio > targetRatio + 0.01 {
            let newW = h * targetRatio
            cropRect = CGRect(x: (w - newW) / 2, y: 0, width: newW, height: h)
        } else if sourceRatio < targetRatio - 0.01 {
            let newH = w / targetRatio
            cropRect = CGRect(x: 0, y: (h - newH) / 2, width: w, height: newH)
        }
        guard let cropped = cg.cropping(to: cropRect.integral.standardized) else { return nil }

        let outH = Int(maxDimension.rounded())
        let outW = Int((CGFloat(outH) * targetRatio).rounded())
        guard outW > 0, outH > 0,
              let ctx = CGContext(
                  data: nil, width: outW, height: outH,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        guard let outCG = ctx.makeImage() else { return nil }
        return NSImage(cgImage: outCG, size: NSSize(width: outW, height: outH))
    }
}

actor ThumbnailService {
    static let shared = ThumbnailService()
    private var cache: [String: URL] = [:]

    private let logger = Logger(
        subsystem: "com.cascade.app",
        category: "thumbnail"
    )

    func clearMemoryCache() {
        cache.removeAll()
    }

    func thumbnailURL(for object: ObjectRecord) async -> URL? {
        let fm = FileManager.default

        // 1. In-Memory Cache hit (only if file still exists on disk)
        if let hit = cache[object.id], fm.fileExists(atPath: hit.path(percentEncoded: false)) {
            return hit
        }

        // 2. Books: portrait cover art wins over the square thumbnail — the cover
        //    is the true representation of a book (the square thumb would be
        //    cropped again in the Library's portrait cards).
        if object.isBook, let cover = bookCoverOnDisk(for: object.id) {
            cache[object.id] = cover
            return cover
        }

        // 2b. Albums/playlists: the folder's cover photo thumbnail represents it
        //     (auto-set to the first photo moved in, or chosen manually).
        if object.isFolder, let coverID = object.coverObjectID {
            if let cover = localThumbnailOnDisk(for: coverID) {
                cache[object.id] = cover
                return cover
            }
            // Kick off thumbnail generation when the cover photo is cached.
            if let coverObj = try? await DatabaseManager.shared.object(coverID),
               DownloadEngine.isCached(coverObj) {
                generateAndSaveThumbnail(for: coverObj, from: DownloadEngine.cacheURL(for: coverObj))
                if let cover = localThumbnailOnDisk(for: coverID) {
                    cache[object.id] = cover
                    return cover
                }
            }
        }

        // 3. Check local disk for generated or downloaded thumbnail (.png, .jpg, -tg.jpg)
        if let local = localThumbnailOnDisk(for: object.id) {
            cache[object.id] = local
            return local
        }

        // 4. Photos cached on disk generate a square thumbnail immediately. Video
        //    previews are extracted locally with the direct-FFmpeg frame extractor
        //    (no AVFoundation — the bundled libavformat/libavcodec/libswscale), and
        //    audio previews come from Telegram's own attached thumbnail below,
        //    which works for any codec with zero CPU cost.
        if DownloadEngine.isCached(object) {
            let cacheURL = DownloadEngine.cacheURL(for: object)
            if object.isPhoto {
                if let lastFail = failedIDs[object.id], Date().timeIntervalSince(lastFail) < 600 {
                    // Fall through to the Telegram thumbnail instead of retrying.
                } else {
                    generateAndSaveThumbnail(for: object, from: cacheURL)
                    if let thumb = localThumbnailOnDisk(for: object.id) {
                        cache[object.id] = thumb
                        return thumb
                    }
                }
            } else if object.isVideo {
                if let lastFail = failedIDs[object.id], Date().timeIntervalSince(lastFail) < 600 {
                    // Fall through to the Telegram thumbnail instead of retrying.
                } else {
                    await generateAndSaveVideoThumbnail(for: object, from: cacheURL)
                    if let thumb = localThumbnailOnDisk(for: object.id) {
                        cache[object.id] = thumb
                        return thumb
                    }
                }
            } else if isAudio(object) {
                if let lastFail = failedIDs[object.id], Date().timeIntervalSince(lastFail) < 600 {
                    // Fall through to the Telegram thumbnail instead of retrying.
                } else {
                    await generateAndSaveAudioThumbnail(for: object, from: cacheURL)
                    if let thumb = localThumbnailOnDisk(for: object.id) {
                        cache[object.id] = thumb
                        return thumb
                    }
                }
            } else if object.isBook {
                Task { await UploadEngine.generateBookCover(for: cacheURL, objectID: object.id) }
                if let cover = bookCoverOnDisk(for: object.id) {
                    cache[object.id] = cover
                }
            }
        } else if object.isVideo {
            // Never-downloaded videos (they stream via the byte-range server) still
            // get a real frame: the extractor opens the loopback stream URL and
            // seeks with a few byte-range requests — no whole-file download. This is
            // what gives streamed files like House of the Dragon a thumbnail.
            if let lastFail = failedIDs[object.id], Date().timeIntervalSince(lastFail) < 600 {
                // Fall through to the Telegram thumbnail instead of retrying.
            } else if let streamURL = await VideoStreamingEngine.shared.mpvStreamURL(for: object) {
                await generateAndSaveVideoThumbnail(for: object, from: streamURL)
                if let thumb = localThumbnailOnDisk(for: object.id) {
                    cache[object.id] = thumb
                    return thumb
                }
            }
        } else if isAudio(object) {
            if let lastFail = failedIDs[object.id], Date().timeIntervalSince(lastFail) < 600 {
                // Fall through to the Telegram thumbnail instead of retrying.
            } else if let streamURL = await VideoStreamingEngine.shared.mpvStreamURL(for: object) {
                await generateAndSaveAudioThumbnail(for: object, from: streamURL)
                if let thumb = localThumbnailOnDisk(for: object.id) {
                    cache[object.id] = thumb
                    return thumb
                }
            }
        }

        // 5. Re-fetch high-resolution thumbnail directly from Telegram
        if let url = await fetchFromTelegram(object) {
            cache[object.id] = url
            return url
        }

        // 6. LAST RESORT — thumbnail-only download for PHOTOS ONLY: quietly pull
        //    the file down, generate a thumbnail, then delete the cached copy so
        //    we never hold the whole file. Photos are small; videos are
        //    deliberately excluded (a video can be gigabytes). Audio is excluded
        //    too: audio previews must come from Telegram's attached thumbnail or
        //    the local cache — a whole-file download just to produce a preview is
        //    wasteful (an audio library can be hundreds of GB). This is the
        //    guarantee that every photo — including uploads that predate Telegram
        //    thumbnail attachment — eventually gets a preview. Single-flight so a
        //    grid of placeholders never starts a download storm.
        if !object.isFolder, !object.isPrivate, object.isPhoto {
            await ensureThumbnailByDownload(object)
            if let thumb = localThumbnailOnDisk(for: object.id) {
                cache[object.id] = thumb
                return thumb
            }
        }

        return nil
    }

    /// True for media that can have a preview: photos (local generation),
    /// videos and audio (Telegram's attached thumbnail). Used by the warm-up
    /// pass so every file eventually gets a preview without opening the grid.
    private func isThumbnailable(_ object: ObjectRecord) -> Bool {
        if object.isPhoto { return true }
        if object.isVideo { return true }
        if isAudio(object) { return true }
        return false
    }

    /// Background pass that guarantees a thumbnail for every media file that
    /// doesn't have one yet. Runs at low priority after login; videos are
    /// processed last since their thumbnail-only downloads are the heaviest.
    func warmUpMissingThumbnails() async {
        let all = (try? await DatabaseManager.shared.allObjects()) ?? []
        let missing = all
            .filter { $0.state == "ready" && !$0.isFolder && !$0.trashed && !$0.isPrivate && isThumbnailable($0) }
            .filter { localThumbnailOnDisk(for: $0.id) == nil }
            .sorted { lhs, rhs in
                // Videos sink to the end of the queue.
                if lhs.isVideo != rhs.isVideo { return !lhs.isVideo }
                return lhs.createdAt < rhs.createdAt
            }
        guard !missing.isEmpty else { return }
        logger.info("Cascade thumbs: warming up \(missing.count) missing thumbnails")
        for object in missing {
            if Task.isCancelled { return }
            _ = await thumbnailURL(for: object)
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private var generatingIDs: Set<String> = []
    private var failedIDs: [String: Date] = [:]

    /// Downloads a file purely to produce its thumbnail, then removes the
    /// download so the cache holds no more than a few seconds of it. Photos only
    /// (audio/video previews must never trigger a whole-file download).
    private func ensureThumbnailByDownload(_ object: ObjectRecord) async {
        // Single-flight: one thumbnail-only download at a time.
        if generatingIDs.contains(object.id) { return }
        // A thumb may have landed between the check and the gate.
        if localThumbnailOnDisk(for: object.id) != nil { return }
        // Back off after a failed attempt (corrupt file, no chunks...) so a
        // broken record doesn't loop forever.
        if let lastFail = failedIDs[object.id], Date().timeIntervalSince(lastFail) < 600 { return }
        if DownloadEngine.isCached(object) {
            // Cached but generation failed earlier — try once more from disk.
            generateAndSaveThumbnail(for: object, from: DownloadEngine.cacheURL(for: object))
        } else {
            generatingIDs.insert(object.id)
            defer { generatingIDs.remove(object.id) }
            do {
                let url = try await DownloadEngine.download(object: object, progress: { _, _ in }, quiet: true)
                generateAndSaveThumbnail(for: object, from: url)
                // The file was only needed for its preview — drop it.
                try? FileManager.default.removeItem(at: url)
            } catch {
                failedIDs[object.id] = Date()
            }
        }
        if localThumbnailOnDisk(for: object.id) != nil {
            failedIDs.removeValue(forKey: object.id)
        }
        // Wake up any open grid so it re-requests and finds the new thumbnail.
        NotificationCenter.default.post(name: .xcThumbnailReady, object: nil)
    }

    /// Portrait cover URL for a book, generating it on demand if missing. Only
    /// ever sourced from the local cache — opening the Library with many uncached
    /// books must NOT start a concurrent download storm (the thumbnail pipeline
    /// has a single-flight gate for exactly this reason); books uploaded before
    /// cover generation get their covers when they're next downloaded (reading
    /// the book), which DownloadEngine handles. The square thumbnail is
    /// deliberately NEVER returned here — the Library's poster cards must show
    /// full cover art, not a cropped thumb.
    func bookCoverURL(for object: ObjectRecord) async -> URL? {
        guard object.isBook else { return nil }
        if let cover = bookCoverOnDisk(for: object.id) {
            cache[object.id] = cover
            return cover
        }
        guard DownloadEngine.isCached(object) else {
            // Cover not made yet AND the book isn't local: fetch it quietly in
            // the background (bounded concurrency, single-flight per book) so
            // every Library poster materializes without a download storm and
            // without waiting for the user to open the book. The fetch posts
            // .xcThumbnailReady when the cover lands, which re-keys open grids
            // so the card picks it up live.
            Task { await BookCoverFetcher.shared.fetch(object) }
            return nil
        }
        let source = DownloadEngine.cacheURL(for: object)
        await UploadEngine.generateBookCover(for: source, objectID: object.id)
        if let cover = bookCoverOnDisk(for: object.id) {
            cache[object.id] = cover
            return cover
        }
        return nil
    }

    /// Extracts a representative (non-black) frame from a VIDEO and saves the
    /// square thumbnails. Works on both cached files and the loopback stream URL
    /// (never-downloaded files) — direct FFmpeg, no AVFoundation, no window.
    /// Single-flight with the photo gate so a grid of missing video thumbs never
    /// starts an extraction storm.
    func generateAndSaveVideoThumbnail(for object: ObjectRecord, from url: URL) async {
        guard object.isVideo, !generatingIDs.contains(object.id) else { return }
        generatingIDs.insert(object.id)
        defer { generatingIDs.remove(object.id) }
        defer {
            if localThumbnailOnDisk(for: object.id) != nil {
                failedIDs.removeValue(forKey: object.id)
            } else {
                failedIDs[object.id] = Date()
            }
            // Wake up any open grid so it re-requests and finds the new thumbnail.
            NotificationCenter.default.post(name: .xcThumbnailReady, object: nil)
        }

        guard let frame = await VideoFrameExtractor.representativeFrame(from: url),
              let thumbDir = try? UploadEngine.thumbnailsDirectory() else { return }
        let destJPG = thumbDir.appendingPathComponent("\(object.id).jpg")
        let destPNG = thumbDir.appendingPathComponent("\(object.id).png")
        if let square = ThumbnailCrop.subjectSquare(frame, target: 320) {
            if let jpg = ThumbnailCrop.jpegData(from: square, quality: 0.85) {
                try? jpg.write(to: destJPG)
                cache[object.id] = destJPG
            }
            if let tiff = square.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: destPNG)
            }
        }
    }

    /// Extracts embedded album artwork from an audio file using FFmpeg (or the
    /// pure-Swift artwork parser for local files). Audio WITHOUT embedded art
    /// falls back to QuickLook's generic audio icon, matching the upload-time
    /// thumbnail pipeline — so a recovered thumb is identical to the original.
    func generateAndSaveAudioThumbnail(for object: ObjectRecord, from url: URL) async {
        guard isAudio(object), !generatingIDs.contains(object.id) else { return }
        generatingIDs.insert(object.id)
        defer { generatingIDs.remove(object.id) }
        defer {
            if localThumbnailOnDisk(for: object.id) != nil {
                failedIDs.removeValue(forKey: object.id)
            } else {
                failedIDs[object.id] = Date()
            }
            NotificationCenter.default.post(name: .xcThumbnailReady, object: nil)
        }

        var frame = await VideoFrameExtractor.representativeFrame(from: url)
        if frame == nil, url.isFileURL {
            // No embedded artwork (e.g. voice memos) — QuickLook's generic audio
            // icon, same as the upload-time pipeline's last resort.
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: 640, height: 640),
                scale: 1,
                representationTypes: .thumbnail
            )
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                frame = NSImage(cgImage: rep.cgImage, size: NSSize(width: rep.cgImage.width, height: rep.cgImage.height))
            }
        }
        guard let frame,
              let thumbDir = try? UploadEngine.thumbnailsDirectory() else { return }
        let destJPG = thumbDir.appendingPathComponent("\(object.id).jpg")
        let destPNG = thumbDir.appendingPathComponent("\(object.id).png")
        if let square = ThumbnailCrop.subjectSquare(frame, target: 320) {
            if let jpg = ThumbnailCrop.jpegData(from: square, quality: 0.85) {
                try? jpg.write(to: destJPG)
                cache[object.id] = destJPG
            }
            if let tiff = square.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: destPNG)
            }
        }
    }

    private func isAudio(_ object: ObjectRecord) -> Bool {
        if object.mime.hasPrefix("audio/") { return true }
        let ext = (object.name as NSString).pathExtension.lowercased()
        return ["mp3", "m4a", "wav", "flac", "aac", "ogg", "wma", "aiff", "opus", "alac", "dsf", "ape"].contains(ext)
    }

    /// Squares + downscales a PHOTO into its thumbnail. Videos and audio are
    /// deliberately not handled here: their previews come from Telegram's
    /// attached thumbnail (AVFoundation — the only local frame/artwork
    /// extractor — is fully removed from the app; mpv is the sole media engine).
    func generateAndSaveThumbnail(for object: ObjectRecord, from fileURL: URL) {
        guard object.mime.hasPrefix("image/") else { return }
        guard let thumbDir = try? UploadEngine.thumbnailsDirectory() else { return }
        let destJPG = thumbDir.appendingPathComponent("\(object.id).jpg")
        let destPNG = thumbDir.appendingPathComponent("\(object.id).png")

        if let image = NSImage(contentsOf: fileURL) {
            if let resized = ThumbnailCrop.subjectSquare(image, target: 320) {
                if let jpg = ThumbnailCrop.jpegData(from: resized, quality: 0.85) {
                    try? jpg.write(to: destJPG)
                    cache[object.id] = destJPG
                }
                if let tiff = resized.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: destPNG)
                }
            }
        }
    }

    private func localThumbnailOnDisk(for id: String) -> URL? {
        let fm = FileManager.default
        guard let dir = try? UploadEngine.thumbnailsDirectory() else { return nil }

        let candidates = [
            dir.appendingPathComponent("\(id).jpg"),
            dir.appendingPathComponent("\(id).png"),
            dir.appendingPathComponent("\(id)-tg.jpg")
        ]

        for cand in candidates {
            if fm.fileExists(atPath: cand.path(percentEncoded: false)) {
                return cand
            }
        }
        return nil
    }

    private func bookCoverOnDisk(for id: String) -> URL? {
        let fm = FileManager.default
        guard let dir = try? UploadEngine.thumbnailsDirectory() else { return nil }
        let cover = dir.appendingPathComponent("\(id)-cover.jpg")
        return fm.fileExists(atPath: cover.path(percentEncoded: false)) ? cover : nil
    }

    private func telegramPath(for id: String) -> URL {
        let base = (try? UploadEngine.thumbnailsDirectory()) ?? URL.temporaryDirectory
        return base.appendingPathComponent("\(id)-tg.jpg")
    }

    private func fetchFromTelegram(_ object: ObjectRecord) async -> URL? {
        guard let vault = try? await DatabaseManager.shared.firstVault() else { return nil }
        // Iterate every chunk message — uploads now attach the same thumbnail to each
        // chunk, so the first one with a stored thumbnail wins. This also keeps older
        // files fetchable if their first chunk predates thumbnails.
        let chunks = (try? await DatabaseManager.shared.chunks(for: object.id)) ?? []
        for chunk in chunks {
            guard let messageId = chunk.messageID,
                  let data = try? await TelegramClient.shared.thumbnailData(
                      forMessage: messageId, chatId: vault.channelID
                  ),
                  !data.isEmpty
            else { continue }
            let url = telegramPath(for: object.id)
            try? data.write(to: url)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                return url
            }
        }
        return nil
    }

    // MARK: - Background book-cover fetch (Library)

    /// Fetches uncached books quietly so their covers materialize on Library
    /// poster cards without waiting for the book to be opened. Single-flight per
    /// book (repeated re-keys of the grid never double-download) and bounded
    /// concurrency (3 at a time) so a Library full of books can't start a
    /// download storm. On success the cover is on disk and .xcThumbnailReady is
    /// posted — open grids re-key and pick it up live.
    private actor BookCoverFetcher {
        static let shared = BookCoverFetcher()
        private var inFlight: Set<String> = []
        private var running = 0
        private let maxConcurrent = 3

        func fetch(_ object: ObjectRecord) async {
            guard !inFlight.contains(object.id) else { return }
            inFlight.insert(object.id)
            defer { inFlight.remove(object.id) }
            while running >= maxConcurrent {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            running += 1
            defer { running -= 1 }
            // Another fetch may have landed the file (or the user opened the
            // book) while we waited for a slot.
            if DownloadEngine.isCached(object) { return }
            do {
                _ = try await DownloadEngine.download(
                    object: object,
                    progress: { _, _ in },
                    quiet: true
                )
                NotificationCenter.default.post(name: .xcThumbnailReady, object: nil)
            } catch {
                // Non-critical: the cover just doesn't appear until the book is
                // read (DownloadEngine makes it then).
            }
        }
    }
}
