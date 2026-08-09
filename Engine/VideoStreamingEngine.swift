import Foundation
import AVFoundation
import UniformTypeIdentifiers

final class VideoStreamingEngine: NSObject, AVAssetResourceLoaderDelegate, Sendable {
    static let shared = VideoStreamingEngine()
    private let queue = DispatchQueue(label: "com.xcloud.streaming", qos: .userInitiated)

    func playerItem(for object: ObjectRecord) async -> AVPlayerItem {
        // If file is fully downloaded and cached locally, play directly from local file URL
        if DownloadEngine.isCached(object) {
            let localURL = DownloadEngine.cacheURL(for: object)
            return AVPlayerItem(url: localURL)
        }

        // Otherwise, stream instantly using custom URL scheme xcloud-stream://
        guard let customURL = URL(string: "xcloud-stream://object-\(object.id)") else {
            let fallbackURL = DownloadEngine.cacheURL(for: object)
            return AVPlayerItem(url: fallbackURL)
        }

        let asset = AVURLAsset(url: customURL)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return AVPlayerItem(asset: asset)
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, url.scheme == "xcloud-stream" else {
            return false
        }

        let objectID = url.absoluteString.replacingOccurrences(of: "xcloud-stream://object-", with: "")

        Task {
            await handleStreamingRequest(loadingRequest, objectID: objectID)
        }
        return true
    }

    private func handleStreamingRequest(_ request: AVAssetResourceLoadingRequest, objectID: String) async {
        guard let object = (try? await DatabaseManager.shared.allObjects())?.first(where: { $0.id == objectID }) else {
            request.finishLoading(with: DownloadError.fileNotFound)
            return
        }

        // Fulfill Content Information Request
        if let infoRequest = request.contentInformationRequest {
            infoRequest.isByteRangeAccessSupported = true
            infoRequest.contentLength = object.size
            if let uti = UTType(filenameExtension: (object.name as NSString).pathExtension) {
                infoRequest.contentType = uti.identifier
            } else {
                infoRequest.contentType = AVFileType.mp4.rawValue
            }
        }

        // Fulfill Data Range Request
        if let dataRequest = request.dataRequest {
            let requestedOffset = dataRequest.requestedOffset
            let requestedLength = Int64(dataRequest.requestedLength)

            do {
                guard let vault = try await DatabaseManager.shared.firstVault(),
                      let chunk = (try await DatabaseManager.shared.chunks(for: object.id)).first,
                      let messageId = chunk.messageID
                else {
                    request.finishLoading(with: DownloadError.fileNotFound)
                    return
                }

                let fileId = try await TelegramClient.shared.getFileId(chatId: vault.channelID, messageId: messageId)
                let localFilePath = try await TelegramClient.shared.fetchRange(
                    fileId: fileId,
                    offset: requestedOffset,
                    limit: requestedLength > 0 ? requestedLength : 2 * 1024 * 1024
                )

                if FileManager.default.fileExists(atPath: localFilePath) {
                    let fileURL = URL(fileURLWithPath: localFilePath)
                    let fileData = try Data(contentsOf: fileURL)
                    dataRequest.respond(with: fileData)
                    request.finishLoading()
                } else {
                    request.finishLoading(with: DownloadError.fileNotFound)
                }
            } catch {
                request.finishLoading(with: error)
            }
        } else {
            request.finishLoading()
        }
    }
}
