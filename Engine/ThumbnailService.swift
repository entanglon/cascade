import Foundation

actor ThumbnailService {
    static let shared = ThumbnailService()
    private var cache: [String: URL] = [:]

    func thumbnailURL(for object: ObjectRecord) async -> URL? {
        if let hit = cache[object.id] { return hit }

        let fm = FileManager.default
        let tgURL = telegramPath(for: object.id)
        if fm.fileExists(atPath: tgURL.path(percentEncoded: false)) {
            cache[object.id] = tgURL
            return tgURL
        }

        // Fetch from Telegram for media; documents fall back to QuickLook thumb
        if object.mime.hasPrefix("image/") || object.mime.hasPrefix("video/") {
            if let url = await fetchFromTelegram(object) {
                cache[object.id] = url
                return url
            }
        }
        if let quick = UploadEngine.thumbnailURL(for: object.id) {
            cache[object.id] = quick
            return quick
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
              let fileId = try? await TelegramClient.shared.thumbnailFileId(
                  forMessage: messageId, chatId: vault.channelID
              ),
              let data = try? await TelegramClient.shared.downloadFileData(fileId: fileId)
        else { return nil }
        let url = telegramPath(for: object.id)
        try? data.write(to: url)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }
}
