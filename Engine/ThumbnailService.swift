import Foundation
import AppKit
import AVFoundation

actor ThumbnailService {
    static let shared = ThumbnailService()
    private var cache: [String: URL] = [:]

    func clearMemoryCache() {
        cache.removeAll()
    }

    func thumbnailURL(for object: ObjectRecord) async -> URL? {
        let fm = FileManager.default

        // 1. In-Memory Cache hit (only if file still exists on disk)
        if let hit = cache[object.id], fm.fileExists(atPath: hit.path(percentEncoded: false)) {
            return hit
        }

        // 2. Local Telegram Thumbnail file on disk
        let tgURL = telegramPath(for: object.id)
        if fm.fileExists(atPath: tgURL.path(percentEncoded: false)) {
            cache[object.id] = tgURL
            return tgURL
        }

        // 3. Local QuickLook / Generated Thumbnail on disk
        if let quick = UploadEngine.thumbnailURL(for: object.id), fm.fileExists(atPath: quick.path(percentEncoded: false)) {
            cache[object.id] = quick
            return quick
        }

        // 4. Re-fetch thumbnail from Telegram for media/documents
        if let url = await fetchFromTelegram(object) {
            cache[object.id] = url
            return url
        }

        return nil
    }

    func generateAndSaveThumbnail(for object: ObjectRecord, from fileURL: URL) {
        guard object.mime.hasPrefix("image/") || object.mime.hasPrefix("video/") else { return }
        guard let thumbDir = try? UploadEngine.thumbnailsDirectory() else { return }
        let dest = thumbDir.appendingPathComponent("\(object.id).jpg")

        if object.mime.hasPrefix("image/"), let image = NSImage(contentsOf: fileURL) {
            let resized = resize(image: image, targetSize: NSSize(width: 320, height: 320))
            if let tiff = resized.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                try? jpg.write(to: dest)
                cache[object.id] = dest
            }
        } else if object.mime.hasPrefix("video/") {
            let asset = AVAsset(url: fileURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            if let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) {
                let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                let resized = resize(image: image, targetSize: NSSize(width: 320, height: 320))
                if let tiff = resized.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                    try? jpg.write(to: dest)
                    cache[object.id] = dest
                }
            }
        }
    }

    private func telegramPath(for id: String) -> URL {
        let base = (try? UploadEngine.thumbnailsDirectory()) ?? URL.temporaryDirectory
        return base.appendingPathComponent("\(id)-tg.jpg")
    }

    private func fetchFromTelegram(_ object: ObjectRecord) async -> URL? {
        guard let vault = try? await DatabaseManager.shared.firstVault(),
              let chunk = (try? await DatabaseManager.shared.chunks(for: object.id))?.first,
              let messageId = chunk.messageID,
              let fileId = try? await TelegramClient.shared.thumbnailFileId(
                  forMessage: messageId, chatId: vault.channelID
              ),
              let data = try? await TelegramClient.shared.downloadFileData(fileId: fileId)
        else { return nil }
        let url = telegramPath(for: object.id)
        try? data.write(to: url)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    private func resize(image: NSImage, targetSize: NSSize) -> NSImage {
        let aspect = min(targetSize.width / image.size.width, targetSize.height / image.size.height)
        let newSize = NSSize(width: image.size.width * aspect, height: image.size.height * aspect)
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize), from: NSRect(origin: .zero, size: image.size), operation: .copy, fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }
}
