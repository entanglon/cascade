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

        // 2. Check local disk for generated or downloaded thumbnail (.png, .jpg, -tg.jpg)
        if let local = localThumbnailOnDisk(for: object.id) {
            cache[object.id] = local
            return local
        }

        // 3. If video or audio is cached on disk, generate thumbnail immediately
        if DownloadEngine.isCached(object) {
            let cacheURL = DownloadEngine.cacheURL(for: object)
            if object.mime.hasPrefix("video/") || object.mime.hasPrefix("audio/") || ["mp3", "m4a", "wav", "flac", "aac", "ogg"].contains((object.name as NSString).pathExtension.lowercased()) {
                generateAndSaveThumbnail(for: object, from: cacheURL)
                if let thumb = localThumbnailOnDisk(for: object.id) {
                    cache[object.id] = thumb
                    return thumb
                }
            }
        }

        // 4. Re-fetch high-resolution thumbnail directly from Telegram
        if let url = await fetchFromTelegram(object) {
            cache[object.id] = url
            return url
        }

        return nil
    }

    func generateAndSaveThumbnail(for object: ObjectRecord, from fileURL: URL) {
        guard object.mime.hasPrefix("image/") || object.mime.hasPrefix("video/") else { return }
        guard let thumbDir = try? UploadEngine.thumbnailsDirectory() else { return }
        let destJPG = thumbDir.appendingPathComponent("\(object.id).jpg")
        let destPNG = thumbDir.appendingPathComponent("\(object.id).png")

        if object.mime.hasPrefix("image/"), let image = NSImage(contentsOf: fileURL) {
            let resized = resize(image: image, targetSize: NSSize(width: 320, height: 320))
            if let tiff = resized.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                if let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                    try? jpg.write(to: destJPG)
                    cache[object.id] = destJPG
                }
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: destPNG)
                }
            }
        } else if object.mime.hasPrefix("video/") {
            let asset = AVAsset(url: fileURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            if let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) {
                let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                let resized = resize(image: image, targetSize: NSSize(width: 320, height: 320))
                if let tiff = resized.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    if let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                        try? jpg.write(to: destJPG)
                        cache[object.id] = destJPG
                    }
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: destPNG)
                    }
                }
            }
        } else if object.mime.hasPrefix("audio/") || ["mp3", "m4a", "wav", "flac", "aac", "ogg"].contains((object.name as NSString).pathExtension.lowercased()) {
            let asset = AVAsset(url: fileURL)
            for item in asset.metadata {
                if item.commonKey == .commonKeyArtwork, let data = item.dataValue, let image = NSImage(data: data) {
                    let resized = resize(image: image, targetSize: NSSize(width: 320, height: 320))
                    if let tiff = resized.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                        if let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                            try? jpg.write(to: destJPG)
                            cache[object.id] = destJPG
                            return
                        }
                    }
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

    private func telegramPath(for id: String) -> URL {
        let base = (try? UploadEngine.thumbnailsDirectory()) ?? URL.temporaryDirectory
        return base.appendingPathComponent("\(id)-tg.jpg")
    }

    private func fetchFromTelegram(_ object: ObjectRecord) async -> URL? {
        guard let vault = try? await DatabaseManager.shared.firstVault(),
              let chunk = (try? await DatabaseManager.shared.chunks(for: object.id))?.first,
              let messageId = chunk.messageID,
              let data = try? await TelegramClient.shared.thumbnailData(
                  forMessage: messageId, chatId: vault.channelID
              )
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
