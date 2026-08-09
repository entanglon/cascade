import Foundation
import Observation

extension Notification.Name {
    /// Posted (on the main actor) whenever an upload finishes successfully, so the
    /// file browser can refresh in real time regardless of how the upload was started
    /// (fresh upload, resume, or retry).
    static let xCloudUploadFinished = Notification.Name("xCloudUploadFinished")
}

@MainActor
@Observable
final class TransferCenter {
    static let shared = TransferCenter()

    struct Item: Identifiable {
        let id = UUID().uuidString
        let direction: Direction
        let objectID: String
        let name: String
        var progress: Double = 0
        var statusText: String = "Starting…"
        var state: State = .active
        /// How much work this transfer represents (e.g. chunk count), used to
        /// aggregate collective progress across concurrent transfers.
        var totalWork: Double = 1

        enum Direction { case upload, download }
        enum State { case active, paused, complete, failed }
    }

    private(set) var items: [Item] = []
    private var cancelHandlers: [String: () -> Void] = [:]

    @discardableResult
    func begin(
        _ direction: Item.Direction,
        objectID: String,
        name: String,
        initialProgress: Double = 0,
        statusText: String = "Starting…",
        state: Item.State = .active,
        totalWork: Double = 1,
        reuseExisting: Bool = false
    ) -> String {
        // Reuse a paused/failed card for the same object so a resume keeps one card per file
        if reuseExisting,
           let existingIndex = items.firstIndex(where: {
               $0.objectID == objectID && $0.direction == direction &&
               ($0.state == .paused || $0.state == .failed)
           }) {
            let id = items[existingIndex].id
            items[existingIndex].state = state
            items[existingIndex].progress = initialProgress
            items[existingIndex].statusText = statusText
            items[existingIndex].totalWork = totalWork
            return id
        }
        let item = Item(
            direction: direction,
            objectID: objectID,
            name: name,
            progress: initialProgress,
            statusText: statusText,
            state: state,
            totalWork: totalWork
        )
        items.insert(item, at: 0)
        if items.count > 100 { items.removeLast() }
        return item.id
    }

    func registerCancel(_ id: String, handler: @escaping () -> Void) {
        cancelHandlers[id] = handler
    }

    /// Pauses an active upload (keeping its uploaded chunks) or aborts an active download.
    func cancel(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if items[i].direction == .upload {
            items[i].state = .paused
            items[i].statusText = "Pausing…"
        } else {
            items[i].state = .failed
            items[i].statusText = "Cancelled"
        }
        if let handler = cancelHandlers.removeValue(forKey: id) {
            handler()
        }
    }

    /// Called by the upload engine once cancellation settles: the upload keeps its chunks and becomes resumable.
    func pause(_ id: String, progress: Double, text: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].state = .paused
        items[i].progress = progress
        items[i].statusText = text
        cancelHandlers.removeValue(forKey: id)
    }

    func update(_ id: String, progress: Double, text: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if items[i].state != .active { return }
        items[i].progress = progress
        items[i].statusText = text
    }

    func finish(_ id: String, success: Bool, error: String? = nil) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].state = success ? .complete : .failed
        items[i].progress = success ? 1 : items[i].progress
        items[i].statusText = success ? "Complete" : (error ?? "Failed")
        cancelHandlers.removeValue(forKey: id)
        if success, items[i].direction == .upload {
            NotificationCenter.default.post(name: .xCloudUploadFinished, object: nil)
        }
    }

    /// Resumes a paused/failed upload from its last uploaded chunk, or retries a failed download.
    func resume(_ id: String) async {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]
        guard item.state == .paused || item.state == .failed else { return }
        // Don't start a second attempt while one is already running (or still settling
        // after a pause) for the same object — two racing tasks would both upload chunks
        // for the same object and corrupt the transfer.
        if items.contains(where: {
            $0.objectID == item.objectID && $0.direction == item.direction &&
            ($0.state == .active || $0.statusText == "Pausing…")
        }) { return }

        if item.direction == .upload {
            guard let object = try? await DatabaseManager.shared.object(item.objectID) else {
                if let i = items.firstIndex(where: { $0.id == id }) {
                    items[i].state = .failed
                    items[i].statusText = "Source no longer available — discard"
                }
                return
            }
            guard let path = object.sourcePath,
                  FileManager.default.fileExists(atPath: path) else {
                if let i = items.firstIndex(where: { $0.id == id }) {
                    items[i].statusText = "Source file missing — discard or re-upload"
                }
                return
            }
            Task {
                try? await UploadEngine.upload(
                    fileURL: URL(fileURLWithPath: path),
                    parentID: object.parentID,
                    isPrivate: object.isPrivate,
                    progress: { _, _ in },
                    resumeObject: object
                )
            }
        } else {
            guard let object = try? await DatabaseManager.shared.object(item.objectID) else {
                if let i = items.firstIndex(where: { $0.id == id }) {
                    items[i].state = .failed
                    items[i].statusText = "File no longer available"
                }
                return
            }
            Task {
                _ = try? await DownloadEngine.download(object: object) { _, _ in }
            }
        }
    }

    /// Removes a paused/failed upload entirely: stops the running upload task, then deletes
    /// its chunk messages from Telegram and the local record.
    func discard(_ id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        // Stop the upload task first so it doesn't keep posting chunks after cleanup
        if let handler = cancelHandlers.removeValue(forKey: id) {
            handler()
        }
        let objectID = item.objectID
        Task {
            await UploadEngine.cleanupPartialUpload(objectID: objectID)
        }
    }

    func removeItems(forObjectID objectID: String) {
        items.removeAll { $0.objectID == objectID }
    }

    func clearFinished() {
        items.removeAll { $0.state == .complete || $0.state == .failed }
    }
}
