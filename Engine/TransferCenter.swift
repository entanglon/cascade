import Foundation
import Observation
import os

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
        // `var` (not `let`) so the record-based initializer below can override it
        // when restoring persisted history — a `let` with a default value can't be
        // reassigned from an extension initializer.
        var id = UUID().uuidString
        let direction: Direction
        let objectID: String
        let name: String
        var progress: Double = 0
        var statusText: String = "Starting…"
        var state: State = .active
        /// How much work this transfer represents (e.g. chunk count), used to
        /// aggregate collective progress across concurrent transfers.
        var totalWork: Double = 1

        enum Direction { case upload, download, inbound }
        enum State { case active, paused, complete, failed }
    }

    private(set) var items: [Item] = []
    private var cancelHandlers: [String: () -> Void] = [:]
    /// Work (chunk counts) of transfers that finished during the current upload
    /// batch. Completed items drop out of `items`-state filtering, so without
    /// this the FAB's aggregate would reweight only the still-active transfers
    /// and jump BACKWARD the moment one of several parallel uploads finishes
    /// (e.g. 30% -> 27%): the finished file's 1.0 * totalWork left both sides.
    /// Keeping it settled keeps the aggregate monotonic: a completed item moves
    /// its work from the active side (at 1.0) to the settled side (at 1.0).
    private var settledWork: Double = 0
    private var settledItems: Set<String> = []

    /// Aggregate progress across the current batch of transfers, weighted by
    /// work (chunk count): completed items count at 1.0 through `settledWork`,
    /// active ones at their current fraction. Never goes backward while items
    /// complete, unlike a plain average over active transfers.
    var batchProgress: Double {
        let active = items.filter { $0.state == .active }
        guard !active.isEmpty else { return 0 }
        let totalWork = settledWork + active.reduce(0.0) { $0 + $1.totalWork }
        guard totalWork > 0 else { return 0 }
        let done = settledWork + active.reduce(0.0) { $0 + $1.progress * $1.totalWork }
        return min(1.0, done / totalWork)
    }

    /// Removes a settled (completed-this-batch) item's contribution. Safe to
    /// call for any item — only items actually settled are adjusted.
    private func unsettle(_ id: String) {
        guard settledItems.contains(id) else { return }
        if let i = items.firstIndex(where: { $0.id == id }) {
            settledWork = max(0, settledWork - items[i].totalWork)
        }
        settledItems.remove(id)
    }

    // MARK: - Persistence (transfer history)

    /// Tests run against the app's real database file (see xCloudTests), so the
    /// engine must not write history rows while XCTest is driving it — the tests use
    /// fake object IDs and would pollute the user's actual transfer history.
    private var persistenceEnabled: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }

    private let logger = Logger(subsystem: "com.xcloud.app", category: "transfers")

    /// Persists a finished (complete/failed) transfer so it survives app restarts.
    /// One row per object: a new attempt supersedes the previous history row (and
    /// any backfilled row for the same object). Failures are logged, never silent.
    private func persist(_ item: Item) {
        guard persistenceEnabled else { return }
        Task {
            do {
                try await DatabaseManager.shared.upsertTransfer(item.record)
            } catch {
                logger.error("Failed to persist transfer history for \(item.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func unpersist(ids: [String]) {
        guard persistenceEnabled, !ids.isEmpty else { return }
        Task {
            try? await DatabaseManager.shared.deleteTransfers(ids: ids)
        }
    }

    /// Restores finished-transfer history from the catalog into the in-memory list,
    /// newest first, so completed/failed cards survive app restarts. Active/paused
    /// transfers are never persisted — they're tied to live tasks.
    func restoreHistory() async {
        guard persistenceEnabled else { return }
        guard let records = try? await DatabaseManager.shared.loadTransfers() else { return }
        items.append(contentsOf: records.map { Item(record: $0) })
    }

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
        // A batch starts when an active transfer begins with nothing else
        // active — the settled-work accumulator belongs to the previous batch.
        let hadActive = items.contains(where: { $0.state == .active })
        if state == .active && !hadActive {
            settledWork = 0
            settledItems.removeAll()
        }
        // Reuse a paused/failed card for the same object so a resume keeps one card per file
        if reuseExisting,
           let existingIndex = items.firstIndex(where: {
               $0.objectID == objectID && $0.direction == direction &&
               ($0.state == .paused || $0.state == .failed)
           }) {
            let id = items[existingIndex].id
            if items[existingIndex].state == .failed {
                // The new attempt supersedes the old failed-history row.
                unpersist(ids: [id])
            }
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
        if items.count > 100 {
            // Keep the in-memory list bounded; drop evicted history from the DB too
            // so it doesn't resurrect on the next launch.
            let evicted = items.removeLast()
            if evicted.state == .complete || evicted.state == .failed {
                unsettle(evicted.id)
                unpersist(ids: [evicted.id])
            }
        }
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
            persist(items[i])
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
        // Monotonic: never let a stale/out-of-order report walk the progress
        // backward (the engine already clamps per chunk; this is defense in depth).
        items[i].progress = max(items[i].progress, min(max(progress, 0), 1))
        items[i].statusText = text
    }

    func finish(_ id: String, success: Bool, error: String? = nil) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].state = success ? .complete : .failed
        items[i].progress = success ? 1 : items[i].progress
        items[i].statusText = success ? "Complete" : (error ?? "Failed")
        if success {
            // Move this transfer's work into the settled bucket so the FAB's
            // aggregate stays monotonic when parallel transfers finish.
            if !settledItems.contains(id) {
                settledItems.insert(id)
                settledWork += items[i].totalWork
            }
        }
        cancelHandlers.removeValue(forKey: id)
        persist(items[i])
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
                    persist(items[i])
                }
                return
            }
            guard let path = object.sourcePath,
                  FileManager.default.fileExists(atPath: path) else {
                if let i = items.firstIndex(where: { $0.id == id }) {
                    items[i].state = .failed
                    items[i].statusText = "Source file missing — discard or re-upload"
                    persist(items[i])
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
                    persist(items[i])
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
        unsettle(id)
        unpersist(ids: [item.id])
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
        let removed = items.filter { $0.objectID == objectID }
        for item in removed { unsettle(item.id) }
        unpersist(ids: removed.map(\.id))
        items.removeAll { $0.objectID == objectID }
    }

    func clearFinished() {
        let finished = items.filter { $0.state == .complete || $0.state == .failed }
        for item in finished { unsettle(item.id) }
        unpersist(ids: finished.map(\.id))
        items.removeAll { $0.state == .complete || $0.state == .failed }
    }
}

// MARK: - Transfer history persistence

extension TransferCenter.Item {
    /// Restores a finished-transfer history row into a card. Only terminal
    /// states are ever persisted, so anything else maps defensively to `.complete`.
    init(record: TransferRecord) {
        self.init(
            id: record.id,
            direction: record.direction == "download" ? .download
                : record.direction == "import" ? .inbound
                : .upload,
            objectID: record.objectID,
            name: record.name,
            progress: record.progress,
            statusText: record.statusText.isEmpty
                ? (record.state == "failed" ? "Failed" : "Complete")
                : record.statusText,
            state: record.state == "failed" ? .failed : .complete,
            totalWork: record.totalWork
        )
    }

    /// The persisted form of this transfer. Only called for terminal states.
    var record: TransferRecord {
        TransferRecord(
            id: id,
            objectID: objectID,
            name: name,
            direction: direction == .download ? "download"
                : direction == .inbound ? "import"
                : "upload",
            state: state == .failed ? "failed" : "complete",
            progress: progress,
            statusText: statusText,
            totalWork: totalWork,
            errorMessage: (state == .failed && !statusText.isEmpty) ? statusText : nil,
            startedAt: nil,
            finishedAt: .now
        )
    }
}
