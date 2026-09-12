#if os(macOS)
import Foundation
import CryptoKit

/// Owns the serial file-upload queue (audit item 7 / roadmap M3): enqueue,
/// pause/resume bookkeeping, and per-file orchestration. Extracted from
/// AppState so upload logic is testable and AppState stops being a god object.
///
/// Threading: @MainActor — it mutates AppState's observable UI fields
/// (`isUploading`, `uploadStatus`, `uploadProgress`) exactly as the pre-extraction
/// code did. Heavy byte work lives in `UploadEngine` off this actor.
///
/// Serialization rule (unchanged): ONE file uploads at a time. Concurrent file
/// uploads congested TDLib's pipeline (files stuck at 99% while their last chunk
/// waited behind other files' chunks). Per-file chunk parallelism (3) is
/// unchanged — only files are serialized.
@MainActor
final class UploadManager {
    struct PendingUpload {
        let url: URL
        let resumeObject: ObjectRecord?
        let transferID: String?
        var parentID: String? = nil
        var isPrivate: Bool? = nil
    }

    weak var appState: AppState?

    private(set) var isDraining = false
    var isIdle: Bool { queue.isEmpty && !isDraining }

    private var queue: [PendingUpload] = []

    func enqueue(_ pending: PendingUpload) {
        queue.append(pending)
        drain()
    }

    /// Drains the queue serially until empty.
    func drain() {
        guard !isDraining else { return }
        isDraining = true
        Task {
            while !queue.isEmpty {
                let pending = queue.removeFirst()
                await performUpload(pending)
            }
            isDraining = false
            appState?.isUploading = false
        }
    }

    private func performUpload(_ pending: PendingUpload) async {
        guard let appState else { return }
        if let transferID = pending.transferID,
           let item = TransferCenter.shared.items.first(where: { $0.id == transferID }),
           item.state == .paused || item.state == .failed {
            // Upload was cancelled or discarded while waiting in queue
            return
        }
        let url = pending.url
        appState.isUploading = true
        appState.uploadStatus = "Preparing…"
        appState.uploadProgress = 0
        let isPrivate = pending.isPrivate ?? (appState.selectedDestination == .privateVault || appState.isFolderPrivate(appState.currentFolderID))
        let parent = pending.parentID ?? ((appState.selectedDestination == .allFiles || appState.selectedDestination == .privateVault) ? appState.currentFolderID : nil)

        do {
            let path = url.path(percentEncoded: false)
            let all = (try? await DatabaseManager.shared.allObjects()) ?? []
            var didUpload = true

            // Uploading the same file again resumes its interrupted upload from the last chunk
            if let existing = pending.resumeObject ?? all.first(where: {
                $0.sourcePath == path && !$0.isFolder && !$0.trashed &&
                ($0.state == "paused" || $0.state == "failed")
            }) {
                if FileManager.default.fileExists(atPath: path) {
                    try await UploadEngine.upload(
                        fileURL: url,
                        parentID: existing.parentID,
                        isPrivate: existing.isPrivate,
                        progress: { [weak appState] status, p in
                            Task { @MainActor in
                                appState?.uploadStatus = status
                                appState?.uploadProgress = p
                            }
                        },
                        existingTransferID: pending.transferID,
                        resumeObject: existing
                    )
                } else {
                    // Source file is gone: discard the stale partial, then upload fresh
                    await UploadEngine.cleanupPartialUpload(objectID: existing.id)
                    TransferCenter.shared.removeItems(forObjectID: existing.id)
                    try await UploadEngine.upload(
                        fileURL: url,
                        parentID: parent,
                        isPrivate: isPrivate,
                        progress: { [weak appState] status, p in
                            Task { @MainActor in
                                appState?.uploadStatus = status
                                appState?.uploadProgress = p
                            }
                        },
                        existingTransferID: pending.transferID
                    )
                }
            } else if all.contains(where: {
                $0.sourcePath == path && !$0.trashed && $0.state == "uploading"
            }) {
                appState.uploadStatus = "Already uploading this file"
                didUpload = false
                if let transferID = pending.transferID {
                    TransferCenter.shared.removeItems(forObjectID: transferID)
                }
            } else {
                try await UploadEngine.upload(
                    fileURL: url,
                    parentID: parent,
                    isPrivate: isPrivate,
                    progress: { [weak appState] status, p in
                        Task { @MainActor in
                            appState?.uploadStatus = status
                            appState?.uploadProgress = p
                        }
                    },
                    existingTransferID: pending.transferID
                )
            }
            if didUpload {
                appState.uploadStatus = "Upload complete ✅"
                await appState.loadFiles()
            }
        } catch {
            if let uploadError = error as? UploadError, case .cancelled = uploadError {
                appState.uploadStatus = "Upload paused — resume anytime from Transfers"
            } else {
                appState.uploadStatus = "Upload failed: \(error.localizedDescription)"
            }
            await appState.loadFiles()
        }
    }
}
#endif