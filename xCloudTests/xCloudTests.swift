//
//  xCloudTests.swift
//  xCloudTests
//
//  Created by Zain Ul Nazir on 05/08/26.
//

import Testing
import Foundation
@testable import xCloud

@Suite(.serialized)
struct xCloudTests {

    @Test func transferPauseKeepsCardResumable() async {
        await MainActor.run {
            let center = TransferCenter.shared
            center.clearFinished()
            let id = center.begin(.upload, objectID: "obj-pause", name: "movie.mp4")
            #expect(center.items.count == 1)
            #expect(center.items.first?.state == .active)

            center.cancel(id)
            #expect(center.items.first?.state == .paused)

            center.pause(id, progress: 0.6, text: "Paused — 3/5 chunks uploaded")
            #expect(center.items.first?.progress == 0.6)
            #expect(center.items.first?.statusText == "Paused — 3/5 chunks uploaded")

            // "Clear Finished" must never drop paused (resumable) cards
            center.clearFinished()
            #expect(center.items.count == 1)

            center.removeItems(forObjectID: "obj-pause")
        }
    }

    @Test func beginReusesPausedCard() async {
        await MainActor.run {
            let center = TransferCenter.shared
            center.clearFinished()
            let first = center.begin(.upload, objectID: "obj-reuse", name: "movie.mp4")
            center.pause(first, progress: 0.4, text: "Paused — 2/5 chunks uploaded")

            // Resuming the same object must reuse the existing card, not create a duplicate
            let resumed = center.begin(
                .upload,
                objectID: "obj-reuse",
                name: "movie.mp4",
                initialProgress: 0.4,
                reuseExisting: true
            )
            #expect(resumed == first)
            #expect(center.items.count == 1)
            #expect(center.items.first?.state == .active)
            #expect(center.items.first?.progress == 0.4)

            center.removeItems(forObjectID: "obj-reuse")
        }
    }

    @Test func downloadCancelIsPlainFailure() async {
        await MainActor.run {
            let center = TransferCenter.shared
            center.clearFinished()
            let id = center.begin(.download, objectID: "obj-dl", name: "movie.mp4")
            center.cancel(id)
            #expect(center.items.first?.state == .failed)
            #expect(center.items.first?.statusText == "Cancelled")

            // Failed cards are clearable (retry is optional)
            center.clearFinished()
            #expect(center.items.isEmpty)
        }
    }

    @Test func discardRemovesCardImmediately() async {
        await MainActor.run {
            let center = TransferCenter.shared
            center.clearFinished()
            let id = center.begin(.upload, objectID: "obj-discard", name: "movie.mp4")
            center.pause(id, progress: 0.2, text: "Paused — 1/5 chunks uploaded")
            center.discard(id)
            #expect(center.items.isEmpty)
        }
    }

    @Test func discardStopsRunningUploadTask() async {
        await MainActor.run {
            let center = TransferCenter.shared
            center.clearFinished()
            let id = center.begin(.upload, objectID: "obj-stop", name: "movie.mp4")

            // Simulate the upload engine's cancel registration
            var stopped = false
            center.registerCancel(id) { stopped = true }

            center.discard(id)
            #expect(center.items.isEmpty)
            // Discard must invoke the registered cancel handler so a running upload
            // stops posting chunks instead of resurrecting the file.
            #expect(stopped)
        }
    }

    @Test @MainActor func resumeIsBlockedWhilePauseIsSettling() async {
        let center = TransferCenter.shared
        center.clearFinished()
        let id = center.begin(.upload, objectID: "obj-busy", name: "movie.mp4")
        center.cancel(id)
        #expect(center.items.first?.state == .paused)
        #expect(center.items.first?.statusText == "Pausing…")

        // While the pause is still settling, a resume must be a no-op so two
        // upload tasks never race on the same object.
        await center.resume(id)
        #expect(center.items.count == 1)
        #expect(center.items.first?.state == .paused)

        center.removeItems(forObjectID: "obj-busy")
    }

    @Test @MainActor func resumeAfterPauseSettlesProceeds() async {
        let center = TransferCenter.shared
        center.clearFinished()
        let id = center.begin(.upload, objectID: "obj-settle", name: "movie.mp4")
        center.cancel(id)
        center.pause(id, progress: 0.4, text: "Paused — 2/5 chunks uploaded")
        #expect(center.items.first?.state == .paused)

        // The object doesn't exist in the test DB, so the resume attempt must
        // settle the card into a clear failure instead of silently doing nothing.
        await center.resume(id)
        #expect(center.items.first?.state == .failed)
        #expect(center.items.first?.statusText == "Source no longer available — discard")

        center.removeItems(forObjectID: "obj-settle")
    }

    @Test @MainActor func uploadFinishPostsRefreshNotification() async {
        let center = TransferCenter.shared
        center.clearFinished()

        var posted = false
        let token = NotificationCenter.default.addObserver(
            forName: .xCloudUploadFinished,
            object: nil,
            queue: nil
        ) { _ in posted = true }
        defer { NotificationCenter.default.removeObserver(token) }

        let id = center.begin(.upload, objectID: "obj-notify", name: "movie.mp4")
        center.finish(id, success: true)
        #expect(posted, "a successful upload must notify the UI to refresh the file list")

        // A failed upload must NOT trigger a refresh
        posted = false
        let failedID = center.begin(.upload, objectID: "obj-notify-2", name: "movie2.mp4")
        center.finish(failedID, success: false, error: "boom")
        #expect(!posted)

        center.removeItems(forObjectID: "obj-notify")
        center.removeItems(forObjectID: "obj-notify-2")
    }

    @Test func gridVerticalNavigationMovesDownToFileBelowFolder() {
        // One folder row, then files: down from a folder must select the file
        // directly beneath it (same column), not jump by a fixed column count.
        var files: [ObjectRecord] = []
        files.append(ObjectRecord(
            id: "folder-0", vaultID: "v", name: "Folder", size: 0, mime: "",
            state: "ready", createdAt: Date(), modifiedAt: Date(), isFolder: true
        ))
        for i in 0..<10 {
            files.append(ObjectRecord(
                id: "file-\(i)", vaultID: "v", name: "File \(i)", size: 100,
                mime: "text/plain", state: "ready",
                createdAt: Date(), modifiedAt: Date()
            ))
        }
        // Down from folder (row 0, col 0) → first file row, col 0 → flat index 1
        #expect(FileBrowserView.gridVerticalStep(current: 0, delta: 1, files: files, cols: 4) == 1)
        // Up from that file → back to the folder
        #expect(FileBrowserView.gridVerticalStep(current: 1, delta: -1, files: files, cols: 4) == 0)
        // Down two rows from the folder → the file two rows below
        #expect(FileBrowserView.gridVerticalStep(current: 0, delta: 2, files: files, cols: 4) == 5)
    }

    @Test func gridVerticalNavigationHandlesMultipleFolderRows() {
        // 5 folders (2 rows of up to 4), then files: down from a folder in the
        // second folder row must land on the file below it, and down from the
        // first row must land on the folder below.
        var files: [ObjectRecord] = []
        for i in 0..<5 {
            files.append(ObjectRecord(
                id: "folder-\(i)", vaultID: "v", name: "Folder \(i)", size: 0, mime: "",
                state: "ready", createdAt: Date(), modifiedAt: Date(), isFolder: true
            ))
        }
        for i in 0..<8 {
            files.append(ObjectRecord(
                id: "file-\(i)", vaultID: "v", name: "File \(i)", size: 100,
                mime: "text/plain", state: "ready",
                createdAt: Date(), modifiedAt: Date()
            ))
        }
        // Down from folder-0 (row 0, col 0) → folder-4 (row 1, col 0)
        #expect(FileBrowserView.gridVerticalStep(current: 0, delta: 1, files: files, cols: 4) == 4)
        // Down from folder-4 (row 1, col 0) → file-0 (first file, row 2, col 0)
        #expect(FileBrowserView.gridVerticalStep(current: 4, delta: 1, files: files, cols: 4) == 5)
        // Up from file-0 → folder-4
        #expect(FileBrowserView.gridVerticalStep(current: 5, delta: -1, files: files, cols: 4) == 4)
    }

    @Test func chunkPlanUsesStoredChunkSizeOnResume() {
        let gib: Int64 = 1_073_741_824

        // New defaults: 128MB standard chunks → a 1 GiB file gets 8 chunks
        let fresh = ChunkPlanner.plan(fileSize: gib)
        #expect(fresh.chunkSize == 128 * ChunkPlanner.byteMiB)
        #expect(fresh.items.count == 8)

        // A stored chunk size from an earlier upload wins over the defaults so a
        // resumed upload re-derives identical chunk boundaries
        let resumed = ChunkPlanner.plan(fileSize: gib, chunkSize: 256 * ChunkPlanner.byteMiB)
        #expect(resumed.chunkSize == 256 * ChunkPlanner.byteMiB)
        #expect(resumed.items.count == 4)
        #expect(resumed.items[1].offset == 256 * ChunkPlanner.byteMiB)
        #expect(resumed.items[1].size == 256 * ChunkPlanner.byteMiB)
    }

}
