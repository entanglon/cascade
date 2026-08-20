//
//  xCloudTests.swift
//  xCloudTests
//
//  Created by Zain Ul Nazir on 05/08/26.
//

import Testing
import Foundation
import AppKit
import CryptoKit
import GRDB
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
            forName: .cascadeUploadFinished,
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

    @Test func importUniqueNameAppendsFinderStyleSuffix() {
        // Free name → unchanged.
        #expect(ShareEngine.uniqueName("Report.pdf", taken: ["Other.pdf"]) == "Report.pdf")
        // Collision → " 2" before the extension, Finder-style.
        #expect(ShareEngine.uniqueName("Report.pdf", taken: ["report.pdf"]) == "Report 2.pdf")
        // Existing " 2" → skip to " 3".
        #expect(ShareEngine.uniqueName("Report.pdf", taken: ["report.pdf", "REPORT 2.PDF"]) == "Report 3.pdf")
        // Case-insensitive, like Apple (names collide regardless of case).
        #expect(ShareEngine.uniqueName("Photo.JPG", taken: ["photo.jpg"]) == "Photo 2.JPG")
        // Extensionless names get the suffix appended directly.
        #expect(ShareEngine.uniqueName("Folder", taken: ["folder"]) == "Folder 2")
        // Multi-dot names keep the full extension intact.
        #expect(ShareEngine.uniqueName("archive.tar.gz", taken: ["archive.tar.gz"]) == "archive.tar 2.gz")
    }

    @Test @MainActor func thumbnailCropProducesSquareSubjectThumbnail() {
        // Landscape 800×600 source (a phone photo) → square 320×320 thumb.
        let source = NSImage(size: NSSize(width: 800, height: 600))
        source.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 800, height: 600).fill()
        source.unlockFocus()

        let thumb = ThumbnailCrop.subjectSquare(source, target: 320)
        #expect(thumb != nil)
        guard let thumb else { return }
        let rep = NSBitmapImageRep(data: thumb.tiffRepresentation ?? Data())
        #expect(rep?.pixelsWide == 320)
        #expect(rep?.pixelsHigh == 320)
    }

    @Test @MainActor func thumbnailCropHandlesDegenerateSizes() {
        // Tiny and already-square inputs must not crash and still crop to a square.
        let tiny = NSImage(size: NSSize(width: 10, height: 10))
        tiny.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 10, height: 10).fill()
        tiny.unlockFocus()
        #expect(ThumbnailCrop.subjectSquare(tiny, target: 64) != nil)

        let square = NSImage(size: NSSize(width: 400, height: 400))
        square.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 400, height: 400).fill()
        square.unlockFocus()
        let thumb = ThumbnailCrop.subjectSquare(square, target: 128)
        #expect(thumb != nil)
        guard let thumb else { return }
        let rep = NSBitmapImageRep(data: thumb.tiffRepresentation ?? Data())
        #expect(rep?.pixelsWide == 128)
        #expect(rep?.pixelsHigh == 128)
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

    @Test func streamingSliceMappingAcrossChunks() {
        let mb: Int64 = 1024 * 1024
        // A 292 MB file in 3 chunks: 128 MB, 128 MB, 36 MB. Slice indices restart at 0
        // within each chunk, so file-wide slice N maps to chunk k with local slice
        // (N - startSliceOfChunkK).
        let layout = ObjectLayout(
            fileSize: 292 * mb,
            channelID: 1,
            chunks: [
                ChunkLayout(messageID: 1, plainSize: 128 * mb),
                ChunkLayout(messageID: 2, plainSize: 128 * mb),
                ChunkLayout(messageID: 3, plainSize: 36 * mb)
            ],
            chunkStarts: [0, 128 * mb, 256 * mb],
            contentType: "public.mpeg-4",
            canStream: true
        )

        // Chunk 0 boundaries (slices 0..127)
        var r = layout.chunkAndLocalIndex(for: 0)
        #expect(r.chunk == 0 && r.local == 0)
        r = layout.chunkAndLocalIndex(for: 127)
        #expect(r.chunk == 0 && r.local == 127)
        // Chunk 1 boundaries (slices 128..255)
        r = layout.chunkAndLocalIndex(for: 128)
        #expect(r.chunk == 1 && r.local == 0)
        r = layout.chunkAndLocalIndex(for: 255)
        #expect(r.chunk == 1 && r.local == 127)
        // Chunk 2 boundaries (slices 256..291)
        r = layout.chunkAndLocalIndex(for: 256)
        #expect(r.chunk == 2 && r.local == 0)
        r = layout.chunkAndLocalIndex(for: 291)
        #expect(r.chunk == 2 && r.local == 35)
    }

    @Test func pinRecoveryKeyRoundTripsVaultKey() throws {
        // The cross-device recovery path: the vault key sealed with the PIN-derived
        // key must unwrap back to the identical key, and a wrong PIN must fail.
        let vaultKey = SymmetricKey(size: .bits256)
        let wrapped = try CryptoEngine.wrap(vaultKey, with: CryptoEngine.recoveryKey(from: "2468"))

        let recovered = try CryptoEngine.unwrap(wrapped, with: CryptoEngine.recoveryKey(from: "2468"))
        let a = vaultKey.withUnsafeBytes { Data($0) }
        let b = recovered.withUnsafeBytes { Data($0) }
        #expect(a == b)

        // Wrong PIN (different derived key) must not unwrap.
        var wrongRejected = false
        do {
            _ = try CryptoEngine.unwrap(wrapped, with: CryptoEngine.recoveryKey(from: "1357"))
        } catch {
            wrongRejected = true
        }
        #expect(wrongRejected)
    }

    @Test func passwordDerivedKeyRoundTripsVaultKey() throws {
        // v2: the master key is PBKDF2(password, per-vault salt) — derived identically
        // on any device. Same PIN + same salt must reproduce the key; wrong PIN or
        // wrong salt must fail.
        let salt = Data("0123456789abcdef".utf8)
        let vaultKey = SymmetricKey(size: .bits256)
        let derived = CryptoEngine.passwordKey(from: "2468", salt: salt)
        let wrapped = try CryptoEngine.wrap(vaultKey, with: derived)

        let recovered = try CryptoEngine.unwrap(wrapped, with: CryptoEngine.passwordKey(from: "2468", salt: salt))
        #expect(vaultKey.withUnsafeBytes { Data($0) } == recovered.withUnsafeBytes { Data($0) })

        var wrongPinRejected = false
        do {
            _ = try CryptoEngine.unwrap(wrapped, with: CryptoEngine.passwordKey(from: "1357", salt: salt))
        } catch {
            wrongPinRejected = true
        }
        #expect(wrongPinRejected)

        var wrongSaltRejected = false
        do {
            _ = try CryptoEngine.unwrap(wrapped, with: CryptoEngine.passwordKey(from: "2468", salt: Data("fedcba9876543210".utf8)))
        } catch {
            wrongSaltRejected = true
        }
        #expect(wrongSaltRejected)
    }

    @Test func vaultKeyRecordV2CaptionRoundTrip() throws {
        // The canonical v2 key record (salt + password seal + device seal) must
        // survive caption encode/decode and unlock via BOTH the password path (any
        // device + PIN) and the device-seal path (same device, Keychain master).
        let vaultKey = SymmetricKey(size: .bits256)
        let salt = Data("0123456789abcdef".utf8)
        let master = SymmetricKey(data: Data(repeating: 7, count: 32))
        let record = VaultManager.VaultKeyRecordV2(
            salt: salt,
            passwordSeal: try CryptoEngine.wrap(vaultKey, with: CryptoEngine.passwordKey(from: "2468", salt: salt)),
            deviceSeal: try CryptoEngine.wrap(vaultKey, with: master),
            deviceID: "test-device"
        )

        let caption = VaultManager.v2Caption(record)
        #expect(caption.hasPrefix("xcloud:vaultkey:v2:"))
        let parsed = try VaultManager.parseV2Record(caption: caption)
        #expect(parsed.salt == salt)
        #expect(parsed.deviceID == "test-device")

        // Password path: any device with the PIN.
        let viaPIN = try CryptoEngine.unwrap(parsed.passwordSeal, with: CryptoEngine.passwordKey(from: "2468", salt: parsed.salt))
        #expect(vaultKey.withUnsafeBytes { Data($0) } == viaPIN.withUnsafeBytes { Data($0) })

        // Device-seal path: the original device without re-entering the PIN.
        let viaDevice = try CryptoEngine.unwrap(parsed.deviceSeal, with: master)
        #expect(vaultKey.withUnsafeBytes { Data($0) } == viaDevice.withUnsafeBytes { Data($0) })
    }

    @Test func parallelProgressResumeSeedsCompletedChunks() {
        // Regression: on resume the aggregate must start at the already-recorded
        // chunk count, not 0 — otherwise the card drops back to 0% after begin().
        let p = UploadEngine.ParallelUploadProgress(total: 9)
        p.setCompleted(3)
        #expect(abs(p.overall - (3.0 / 9.0)) < 0.0001)

        p.setFraction(4, 0.5)
        #expect(abs(p.overall - (3.5 / 9.0)) < 0.0001)

        p.complete(4)
        #expect(p.completedCount == 4)
        #expect(abs(p.overall - (4.0 / 9.0)) < 0.0001)
    }

    @Test func catalogSnapshotRoundTripPreservesCatalog() throws {
        // The database-imaging feature serializes the full catalog (objects + chunks)
        // into one JSON document in the channel. The round-trip must preserve every
        // field exactly — especially createdAt/modifiedAt, whose GRDB storage (Double
        // since the 2001 reference date) matches JSONEncoder's default .deferredToDate
        // so dates survive unchanged.
        let now = Date(timeIntervalSince1970: 1_725_000_000)
        let object = ObjectRecord(
            id: "obj-1",
            vaultID: "vault-1",
            name: "Movie.mp4",
            size: 3_000_000_000,
            mime: "video/mp4",
            state: "ready",
            rootHash: "abc",
            wrappedKey: Data([1, 2, 3]),
            createdAt: now,
            modifiedAt: now.addingTimeInterval(60),
            isFavorite: true,
            trashed: false,
            parentID: "folder-9",
            isFolder: false,
            isPrivate: true,
            sourcePath: nil,
            chunkSize: 128 * 1024 * 1024
        )
        let chunk = ChunkRecord(
            id: "chunk-1",
            objectID: "obj-1",
            index: 2,
            size: 128 * 1024 * 1024,
            plainHash: "p",
            cipherHash: "c",
            state: "uploaded",
            messageID: 55_123_456_789,
            fileUniqueID: "fu",
            channelID: -100_123_456_789,
            createdAt: now
        )
        let payload = CatalogSnapshot.Payload(version: 1, objects: [object], chunks: [chunk])
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(CatalogSnapshot.Payload.self, from: data)

        #expect(decoded.objects.count == 1)
        #expect(decoded.chunks.count == 1)
        let o = decoded.objects[0]
        #expect(o.id == object.id)
        #expect(o.name == "Movie.mp4")
        #expect(o.size == object.size)
        #expect(o.isPrivate)
        let expectedChunkSize: Int64 = 128 * 1024 * 1024
        #expect(o.chunkSize == expectedChunkSize)
        #expect(o.createdAt == now)
        #expect(o.modifiedAt == now.addingTimeInterval(60))
        let c = decoded.chunks[0]
        #expect(c.index == 2)
        #expect(c.messageID == 55_123_456_789)
        #expect(c.channelID == -100_123_456_789)
        #expect(c.createdAt == now)
    }

    // MARK: - Catalog snapshot LWW merge

    private func mergeTestObject(
        id: String,
        name: String,
        modifiedAt: Date,
        trashed: Bool = false,
        sourcePath: String? = nil,
        state: String = "ready",
        parentID: String? = nil
    ) -> ObjectRecord {
        ObjectRecord(
            id: id,
            vaultID: "vault-test",
            name: name,
            size: 100,
            mime: "text/plain",
            state: state,
            rootHash: nil,
            wrappedKey: nil,
            createdAt: modifiedAt,
            modifiedAt: modifiedAt,
            isFavorite: false,
            trashed: trashed,
            parentID: parentID,
            isFolder: false,
            sourcePath: sourcePath
        )
    }

    @Test func mergeKeepsIndependentRecordsFromBothDevices() {
        // Device A renamed file X; device B moved file Y. Neither knows about the
        // other — the merge must keep BOTH changes (union), not lose one.
        let t0 = Date(timeIntervalSince1970: 1_750_000_000)
        let local = CatalogSnapshot.Payload(version: 1, objects: [
            mergeTestObject(id: "x", name: "X renamed.mp4", modifiedAt: t0.addingTimeInterval(10)),
            mergeTestObject(id: "y", name: "Y old.mp4", modifiedAt: t0)
        ], chunks: [])
        let remote = CatalogSnapshot.Payload(version: 1, objects: [
            mergeTestObject(id: "x", name: "X old.mp4", modifiedAt: t0),
            mergeTestObject(id: "y", name: "Y.mp4", modifiedAt: t0.addingTimeInterval(20), parentID: "movies")
        ], chunks: [])

        let merged = CatalogSnapshot.merge(local: local, remote: remote, localVaultID: "vault-local")
        #expect(merged.objects.count == 2)
        let x = merged.objects.first { $0.id == "x" }
        let y = merged.objects.first { $0.id == "y" }
        // X: local is newer → local wins, untouched.
        #expect(x?.name == "X renamed.mp4")
        // Y: remote is newer → remote wins, normalized for local adoption.
        #expect(y?.name == "Y.mp4")
        #expect(y?.parentID == "movies")
        #expect(y?.vaultID == "vault-local")
        #expect(y?.sourcePath == nil)
        #expect(y?.state == "ready")
    }

    @Test func mergeLocalNewerKeepsLocalRecordIntact() {
        // A record this device is actively uploading must keep its source path and
        // state after a merge — otherwise resume would break.
        let t0 = Date(timeIntervalSince1970: 1_750_000_000)
        let local = CatalogSnapshot.Payload(version: 1, objects: [
            mergeTestObject(
                id: "big", name: "Big.mp4", modifiedAt: t0.addingTimeInterval(30),
                sourcePath: "/tmp/Big.mp4", state: "uploading"
            )
        ], chunks: [])
        let remote = CatalogSnapshot.Payload(version: 1, objects: [
            mergeTestObject(id: "big", name: "Big.mp4", modifiedAt: t0, state: "ready")
        ], chunks: [])

        let merged = CatalogSnapshot.merge(local: local, remote: remote, localVaultID: "vault-local")
        let big = merged.objects.first { $0.id == "big" }
        #expect(big?.state == "uploading")
        #expect(big?.sourcePath == "/tmp/Big.mp4")
    }

    @Test func mergePropagatesDeletionAsTombstone() {
        // Device A deleted file X (trashed, newer timestamp). Device B hasn't seen
        // the delete. The merge must keep the tombstone — B must not resurrect it.
        let t0 = Date(timeIntervalSince1970: 1_750_000_000)
        let local = CatalogSnapshot.Payload(version: 1, objects: [
            mergeTestObject(id: "x", name: "X.mp4", modifiedAt: t0)
        ], chunks: [])
        let remote = CatalogSnapshot.Payload(version: 1, objects: [
            mergeTestObject(id: "x", name: "X.mp4", modifiedAt: t0.addingTimeInterval(60), trashed: true)
        ], chunks: [])

        let merged = CatalogSnapshot.merge(local: local, remote: remote, localVaultID: "vault-local")
        #expect(merged.objects.count == 1)
        #expect(merged.objects[0].trashed == true)
    }

    @Test func localTrashWithBumpedModifiedAtSurvivesMergeAndPublishes() {
        // Regression: trashing a file must bump modifiedAt, otherwise the LWW merge
        // sees a tie with the channel's copy (same timestamp, untrashed), keeps the
        // REMOTE side, and the file silently resurrects on the next refresh. With the
        // bump, the tombstone wins the merge AND changedRecords publishes it.
        let t0 = Date(timeIntervalSince1970: 1_750_000_000)
        let local = CatalogSnapshot.Payload(version: 1, objects: [
            mergeTestObject(id: "x", name: "X.mp4", modifiedAt: t0.addingTimeInterval(30), trashed: true)
        ], chunks: [])
        let remote = CatalogSnapshot.Payload(version: 1, objects: [
            mergeTestObject(id: "x", name: "X.mp4", modifiedAt: t0)  // channel copy, untrashed, older
        ], chunks: [])

        let merged = CatalogSnapshot.merge(local: local, remote: remote, localVaultID: "vault-local")
        #expect(merged.objects.first?.trashed == true, "trash must survive the merge")

        let changes = CatalogSnapshot.changedRecords(local: local, remote: remote)
        #expect(Set(changes.objects.map(\.id)) == ["x"], "the trash change must be publishable")
    }

    @Test func mergeNormalizesEmptyWrappedKeyToNil() {
        // Regression: public files carry wrappedKey "" in their caption. Restoring
        // that as EMPTY Data makes DownloadEngine call AES.GCM.open on a zero-length
        // box, which throws the "CryptoKit error 2" users saw on Movies files. The
        // merge (and restore) must normalize empty wrappedKey to nil.
        let t0 = Date(timeIntervalSince1970: 1_750_000_000)
        var remote = mergeTestObject(id: "x", name: "X.mp4", modifiedAt: t0)
        remote.wrappedKey = Data()
        let remotePayload = CatalogSnapshot.Payload(version: 1, objects: [remote], chunks: [])

        let merged = CatalogSnapshot.merge(
            local: CatalogSnapshot.Payload(version: 1, objects: [], chunks: []),
            remote: remotePayload,
            localVaultID: "vault-local"
        )
        let adopted = merged.objects.first { $0.id == "x" }
        #expect(adopted?.wrappedKey == nil, "empty wrappedKey must normalize to nil")
    }

    @Test func mergePrefersChunkWithTelegramMessageID() {
        let t0 = Date(timeIntervalSince1970: 1_750_000_000)
        // Local chunk actually uploaded (messageID set); remote copy still in flight.
        let localChunk = ChunkRecord(
            id: "c1", objectID: "o1", index: 0, size: 100, plainHash: nil, cipherHash: nil,
            state: "uploaded", messageID: 777, fileUniqueID: nil, channelID: -100, createdAt: t0
        )
        let remoteChunk = ChunkRecord(
            id: "c1", objectID: "o1", index: 0, size: 100, plainHash: nil, cipherHash: nil,
            state: "uploading", messageID: nil, fileUniqueID: nil, channelID: -100, createdAt: t0
        )
        let local = CatalogSnapshot.Payload(version: 1, objects: [], chunks: [localChunk])
        let remote = CatalogSnapshot.Payload(version: 1, objects: [], chunks: [remoteChunk])

        let merged = CatalogSnapshot.merge(local: local, remote: remote, localVaultID: "vault-local")
        #expect(merged.chunks.count == 1)
        #expect(merged.chunks[0].messageID == 777)
    }

    @Test func changedRecordsPicksOnlyLocalChanges() {
        // A delta must carry ONLY what the channel doesn't know: local-newer records,
        // local-only records, and uploaded chunks the remote side lacks.
        let t0 = Date(timeIntervalSince1970: 1_750_000_000)
        let local = CatalogSnapshot.Payload(version: 1, objects: [
            mergeTestObject(id: "a", name: "A", modifiedAt: t0.addingTimeInterval(5)),   // local newer → changed
            mergeTestObject(id: "b", name: "B", modifiedAt: t0),                         // remote newer → unchanged
            mergeTestObject(id: "c", name: "C", modifiedAt: t0)                          // local-only → changed
        ], chunks: [])
        let remote = CatalogSnapshot.Payload(version: 1, objects: [
            mergeTestObject(id: "a", name: "A", modifiedAt: t0),
            mergeTestObject(id: "b", name: "B", modifiedAt: t0.addingTimeInterval(10)),
            mergeTestObject(id: "d", name: "D", modifiedAt: t0)                           // remote-only → not ours
        ], chunks: [])

        let changes = CatalogSnapshot.changedRecords(local: local, remote: remote)
        #expect(Set(changes.objects.map(\.id)) == ["a", "c"])
    }

    @Test func restoreReplaysCheckpointPlusDeltasNewerThanBase() {
        // Restore = newest checkpoint + every delta with a message ID greater than
        // the checkpoint's base. Deltas at/before the base are already inside the
        // checkpoint and must be skipped, not replayed.
        let t0 = Date(timeIntervalSince1970: 1_750_000_000)
        var checkpoint = CatalogSnapshot.Payload(version: 1, objects: [
            mergeTestObject(id: "a", name: "A", modifiedAt: t0),
            mergeTestObject(id: "c", name: "C", modifiedAt: t0)  // from the delta@99 the publisher had merged
        ], chunks: [])
        checkpoint.baseMessageID = 100
        let deltaAfter = CatalogSnapshot.Payload(version: 1, objects: [
            mergeTestObject(id: "b", name: "B", modifiedAt: t0)
        ], chunks: [])
        let deltaBefore = CatalogSnapshot.Payload(version: 1, objects: [
            mergeTestObject(id: "d", name: "D", modifiedAt: t0)
        ], chunks: [])

        let state = CatalogSnapshot.ChannelState(
            checkpoint: checkpoint,
            checkpointID: 100,
            deltas: [(99, deltaBefore), (101, deltaAfter)]
        )
        let merged = CatalogSnapshot.mergedChannelState(state, vaultID: "vault-local")
        #expect(Set(merged.objects.map(\.id)) == ["a", "b", "c"])
    }

    @Test func deltaIsIdempotentWhenReplayedAgainstCheckpoint() {
        // Applying a delta that the checkpoint already contains must be a no-op —
        // this is what makes reorder/redelivery safe.
        let t0 = Date(timeIntervalSince1970: 1_750_000_000)
        let checkpoint = CatalogSnapshot.Payload(version: 1, objects: [
            mergeTestObject(id: "x", name: "X", modifiedAt: t0.addingTimeInterval(30))
        ], chunks: [])
        let delta = CatalogSnapshot.Payload(version: 1, objects: [
            mergeTestObject(id: "x", name: "X", modifiedAt: t0)
        ], chunks: [])

        let merged = CatalogSnapshot.merge(local: checkpoint, remote: delta, localVaultID: "vault-local")
        let x = merged.objects.first { $0.id == "x" }
        #expect(x?.name == "X")
        #expect(x?.modifiedAt == t0.addingTimeInterval(30))
    }

    @Test func deduplicatedChunksCollapsesOldAndNewPlansForSameMessages() {
        // Regression: the vault catalog carried TWO chunk rows per index for the same
        // Telegram messages — one from an old ~122 MiB plan, one from the newer 128
        // MiB plan. Downloads wrote every message's bytes twice, producing files
        // twice the real size. Dedup must keep exactly one row per index, sized so
        // the chunks sum to the object's recorded size.
        let t0 = Date(timeIntervalSince1970: 1_750_000_000)
        let object = ObjectRecord(
            id: "o1", vaultID: "vault-test", name: "Movie.mp4", size: 1_098_879_765,
            mime: "video/mp4", state: "ready", rootHash: nil, wrappedKey: nil,
            createdAt: t0, modifiedAt: t0
        )
        let messageIDs: [Int64] = [
            118489088, 117440512, 116391936, 121634816,
            120586240, 119537664, 122683392, 123731968, 124780544,
        ]
        var chunks: [ChunkRecord] = []
        for (i, msg) in messageIDs.enumerated() {
            let newSize = i == 8 ? 25_137_941 : 134_217_728
            let oldSize: Int64 = 122_097_751
            chunks.append(ChunkRecord(
                id: "new-\(i)", objectID: "o1", index: i, size: Int64(newSize),
                plainHash: nil, cipherHash: nil, state: "uploaded", messageID: msg,
                fileUniqueID: nil, channelID: -100, createdAt: t0
            ))
            chunks.append(ChunkRecord(
                id: "old-\(i)", objectID: "o1", index: i, size: oldSize,
                plainHash: nil, cipherHash: nil, state: "uploaded", messageID: msg,
                fileUniqueID: nil, channelID: -100, createdAt: t0
            ))
        }

        let deduped = CatalogSnapshot.deduplicatedChunks(chunks, objects: [object])
        #expect(deduped.count == 9, "exactly one row per chunk index")
        #expect(Set(deduped.map(\.messageID)) == Set(messageIDs), "each message referenced exactly once")
        let total = deduped.reduce(Int64(0)) { $0 + $1.size }
        #expect(total == object.size, "chunk sizes sum to the real file size")
        #expect(deduped.filter { $0.size % 1_048_576 == 0 }.count == 8, "non-final chunks are whole 1 MiB slices")
    }

    @Test func transferHistoryPersistsAndClears() async throws {
        // The transfer-history persistence path: a terminal transfer is saved to the
        // catalog, restored by loadTransfers (what restoreHistory uses at launch),
        // and removed by deleteTransfers (what Clear Finished uses). The transfers
        // table FKs to objects, so a real object row is required — mirroring how the
        // app persists after an actual upload. Must clean up after itself — the test
        // host shares the app's real database.
        let account = AccountRecord(
            id: "acc-test-history",
            telegramUserID: 999998,
            displayName: "Test User",
            state: "ready",
            createdAt: Date()
        )
        let vault = VaultRecord(
            id: "vault-test-history",
            accountID: account.id,
            channelID: 999998,
            name: "Test Vault",
            wrappedKey: Data(),
            createdAt: Date()
        )
        try await DatabaseManager.shared.save(account)
        try await DatabaseManager.shared.save(vault)

        let object = ObjectRecord(
            id: "obj-test-history", vaultID: vault.id, name: "history-test.mp4",
            size: 1_024, mime: "video/mp4", state: "ready", rootHash: nil, wrappedKey: nil,
            createdAt: Date(), modifiedAt: Date()
        )
        try await DatabaseManager.shared.save(object)

        let record = TransferRecord(
            id: "t-test-history",
            objectID: object.id,
            name: object.name,
            direction: "upload",
            state: "complete",
            progress: 1,
            statusText: "Complete",
            totalWork: 4,
            errorMessage: nil,
            startedAt: Date(),
            finishedAt: Date()
        )
        try await DatabaseManager.shared.upsertTransfer(record)

        let restored = try await DatabaseManager.shared.loadTransfers()
        #expect(restored.contains { $0.id == record.id && $0.name == record.name && $0.state == "complete" },
                "finished transfer survives a save/load round-trip")

        // A second terminal transfer for the same object supersedes the first row
        // (one card per object), so the old row must not resurface.
        let second = TransferRecord(
            id: "t-test-history-2",
            objectID: object.id,
            name: object.name,
            direction: "upload",
            state: "failed",
            progress: 0.5,
            statusText: "Failed",
            totalWork: 4,
            errorMessage: "boom",
            startedAt: Date(),
            finishedAt: Date()
        )
        try await DatabaseManager.shared.upsertTransfer(second)
        let afterUpsert = try await DatabaseManager.shared.loadTransfers()
        #expect(!afterUpsert.contains { $0.id == record.id }, "old row superseded by the new attempt")
        #expect(afterUpsert.contains { $0.id == second.id })

        try await DatabaseManager.shared.deleteTransfers(ids: [second.id])
        let after = try await DatabaseManager.shared.loadTransfers()
        #expect(!after.contains { $0.id == second.id }, "deleted history is gone")

        // Clean up the dummy account/vault (deletes the object + any leftover
        // transfers too) so nothing poisons the user's real vault discovery.
        try await DatabaseManager.shared.deleteVaultAndData(id: vault.id)
    }

    @Test func archiveFlagPersistsAndSurvivesOldSnapshots() async throws {
        // The Archive feature's storage contract: an archived object survives a
        // save/load round-trip, and catalog snapshots that predate the isArchived
        // column (no key in the JSON) still decode with isArchived == false instead
        // of throwing — so a fresh device restoring an old checkpoint never breaks.
        let account = AccountRecord(
            id: "acc-test-archive",
            telegramUserID: 999997,
            displayName: "Test User",
            state: "ready",
            createdAt: Date()
        )
        let vault = VaultRecord(
            id: "vault-test-archive",
            accountID: account.id,
            channelID: 999997,
            name: "Test Vault",
            wrappedKey: Data(),
            createdAt: Date()
        )
        try await DatabaseManager.shared.save(account)
        try await DatabaseManager.shared.save(vault)

        let object = ObjectRecord(
            id: "obj-test-archive", vaultID: vault.id, name: "archive-me.txt",
            size: 64, mime: "text/plain", state: "ready", rootHash: nil, wrappedKey: nil,
            createdAt: Date(), modifiedAt: Date()
        )
        try await DatabaseManager.shared.save(object)

        // Archive it, then confirm the flag round-trips through the DB.
        try await DatabaseManager.shared.updateObject(object.id) { $0.isArchived = true }
        let reloaded = try await DatabaseManager.shared.object(object.id)
        #expect(reloaded?.isArchived == true, "archived flag persists")

        // A record that was NEVER archived comes back unarchived.
        let plain = ObjectRecord(
            id: "obj-test-archive-plain", vaultID: vault.id, name: "keep.txt",
            size: 64, mime: "text/plain", state: "ready", rootHash: nil, wrappedKey: nil,
            createdAt: Date(), modifiedAt: Date()
        )
        try await DatabaseManager.shared.save(plain)
        let plainReloaded = try await DatabaseManager.shared.object(plain.id)
        #expect(plainReloaded?.isArchived == false)

        // Old-snapshot compatibility: JSON without the isArchived key must decode
        // (synthesized Codable would throw on the missing key).
        let legacyJSON = try JSONSerialization.data(withJSONObject: [
            "id": "legacy-obj", "vaultID": vault.id, "name": "legacy.txt",
            "size": 12, "mime": "text/plain", "state": "ready",
            "createdAt": Date().timeIntervalSinceReferenceDate,
            "modifiedAt": Date().timeIntervalSinceReferenceDate
        ])
        let legacy = try JSONDecoder().decode(ObjectRecord.self, from: legacyJSON)
        #expect(legacy.isArchived == false, "missing key defaults to unarchived")
        #expect(legacy.trashed == false)
        #expect(legacy.name == "legacy.txt")

        // And the modern round-trip: encoding includes isArchived.
        let data = try JSONEncoder().encode(reloaded!)
        let decoded = try JSONDecoder().decode(ObjectRecord.self, from: data)
        #expect(decoded.isArchived == true, "encode/decode keeps the archived flag")

        try await DatabaseManager.shared.deleteVaultAndData(id: vault.id)
    }

    @Test func bookLoaderParsesEpubSpineAndToc() throws {
        // Builds a minimal EPUB (zip with container/OPF/spine/NCX), extracts it and
        // verifies the reader gets ordered chapters + TOC titles mapped to indexes.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcloud-booktest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let epubDir = tmp.appendingPathComponent("book", isDirectory: true)
        try FileManager.default.createDirectory(at: epubDir.appendingPathComponent("META-INF", isDirectory: true), withIntermediateDirectories: true)
        let oebps = epubDir.appendingPathComponent("OEBPS", isDirectory: true)
        try FileManager.default.createDirectory(at: oebps, withIntermediateDirectories: true)

        try """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """.write(to: epubDir.appendingPathComponent("META-INF/container.xml"), atomically: true, encoding: .utf8)

        try """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
          <metadata><dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">Test Book</dc:title></metadata>
          <manifest>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine toc="ncx">
            <itemref idref="c1"/>
            <itemref idref="c2"/>
          </spine>
        </package>
        """.write(to: oebps.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        try "<html><body><h1>One</h1></body></html>"
            .write(to: oebps.appendingPathComponent("chapter1.xhtml"), atomically: true, encoding: .utf8)
        try "<html><body><h1>Two</h1></body></html>"
            .write(to: oebps.appendingPathComponent("chapter2.xhtml"), atomically: true, encoding: .utf8)

        try """
        <?xml version="1.0" encoding="utf-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <navMap>
            <navPoint id="n1" playOrder="1">
              <navLabel><text>Chapter One</text></navLabel>
              <content src="chapter1.xhtml"/>
            </navPoint>
            <navPoint id="n2" playOrder="2">
              <navLabel><text>Chapter Two</text></navLabel>
              <content src="chapter2.xhtml#p2"/>
            </navPoint>
          </navMap>
        </ncx>
        """.write(to: oebps.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)

        let epubURL = tmp.appendingPathComponent("test.epub")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = epubDir
        zip.arguments = ["-q", "-r", epubURL.path(percentEncoded: false), "."]
        try zip.run()
        zip.waitUntilExit()

        let dir = try BookLoader.extractArchive(fileURL: epubURL, fileID: "test")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (chapters, toc) = try BookLoader.loadEpub(extractedDir: dir)

        #expect(chapters.count == 2, "spine order drives chapters")
        #expect(toc.count == 2)
        #expect(toc[0].title == "Chapter One")
        #expect(toc[1].title == "Chapter Two")
        #expect(toc[1].chapterIndex == 1, "fragment-bearing NCX src still maps to its chapter")
        #expect(chapters[1].url.path.contains("chapter2"))

        // Text renderer escapes HTML so book content can't inject markup.
        let html = BookLoader.htmlDocument(fromText: "<script>alert(1)</script>\n\nPara two")
        #expect(!html.contains("<script>"), "raw HTML in a text book must be escaped")
        #expect(html.contains("&lt;script&gt;"))
        #expect(html.contains("<p>Para two</p>"))
    }

    @Test func flattenEpubProducesOneContinuousScrollableDocument() throws {
        // Regression: the reader used to load each spine item as its own page, so
        // books split into many short chapter files required arrow-tapping while
        // books with long files scrolled. flattenEpub must merge every chapter
        // into ONE document — and keep images/stylesheets resolving by rewriting
        // relative URLs to absolute file URLs.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcloud-flatten-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let epubDir = tmp.appendingPathComponent("book", isDirectory: true)
        try FileManager.default.createDirectory(at: epubDir.appendingPathComponent("META-INF", isDirectory: true), withIntermediateDirectories: true)
        let oebps = epubDir.appendingPathComponent("OEBPS", isDirectory: true)
        try FileManager.default.createDirectory(at: oebps.appendingPathComponent("images", isDirectory: true), withIntermediateDirectories: true)

        try """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.write(to: epubDir.appendingPathComponent("META-INF/container.xml"), atomically: true, encoding: .utf8)

        try """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
          <metadata><dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">Test Book</dc:title></metadata>
          <manifest>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine toc="ncx"><itemref idref="c1"/><itemref idref="c2"/></spine>
        </package>
        """.write(to: oebps.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        // Chapter 1 carries a stylesheet link, an inline <style> with a CSS url(),
        // a relative image and a cross-chapter relative link with a fragment.
        try """
        <html><head><link rel="stylesheet" type="text/css" href="styles.css"/>
        <style>.hero { background: url(images/cover.jpg); }</style></head>
        <body><h1>One</h1><p>See <img src="images/cover.jpg" alt="cover"/></p>
        <a href="ch2.xhtml#next">Next chapter</a></body></html>
        """.write(to: oebps.appendingPathComponent("ch1.xhtml"), atomically: true, encoding: .utf8)

        try "<html><head></head><body><h1 id=\"next\">Two</h1><p>More</p></body></html>"
            .write(to: oebps.appendingPathComponent("ch2.xhtml"), atomically: true, encoding: .utf8)

        try """
        <?xml version="1.0" encoding="utf-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <navMap>
            <navPoint id="n1" playOrder="1"><navLabel><text>One</text></navLabel><content src="ch1.xhtml"/></navPoint>
            <navPoint id="n2" playOrder="2"><navLabel><text>Two</text></navLabel><content src="ch2.xhtml"/></navPoint>
          </navMap>
        </ncx>
        """.write(to: oebps.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)

        let epubURL = tmp.appendingPathComponent("test.epub")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = epubDir
        zip.arguments = ["-q", "-r", epubURL.path(percentEncoded: false), "."]
        try zip.run()
        zip.waitUntilExit()

        let dir = try BookLoader.extractArchive(fileURL: epubURL, fileID: "flatten")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (chapters, _) = try BookLoader.loadEpub(extractedDir: dir)
        let combined = try BookLoader.flattenEpub(extractedDir: dir, chapters: chapters)
        let html = try String(contentsOf: combined, encoding: .utf8)

        // Both chapters live in one document, each wrapped in a scroll anchor.
        #expect(html.contains(#"id="xc-ch-0""#), "chapter 1 anchor present")
        #expect(html.contains(#"id="xc-ch-1""#), "chapter 2 anchor present")
        #expect(html.contains("<h1>One</h1>"))
        #expect(html.contains("<h1 id=\"next\">Two</h1>"), "chapter 2 body concatenated")

        // Relative URLs were rewritten to absolute file URLs so they still resolve
        // from the combined document at the book root.
        #expect(html.contains("file://"), "relative URLs become absolute")
        #expect(html.contains("images/cover.jpg"), "image path preserved in the absolute URL")
        #expect(html.contains("styles.css"), "stylesheet link preserved")
        #expect(html.contains("ch2.xhtml#next"), "cross-chapter link keeps its fragment")

        // The combined document sits in the extracted dir and is a single file.
        #expect(combined.path(percentEncoded: false).hasPrefix(dir.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: combined.path(percentEncoded: false)))
    }

    @Test func partialCachedFileIsNotCached() throws {
        // Regression: a truncated cached copy (e.g. a thumbnail-only quiet download
        // cut off by a quit) must NOT count as "cached" — playback gating on
        // `!isCached` would otherwise feed the truncated file to mpv as a local
        // file (moov atom missing -> won't play) instead of streaming the intact
        // bytes from Telegram. Only a file with the exact recorded size counts.
        let fm = FileManager.default
        let object = ObjectRecord(
            id: "test-partial-\(UUID().uuidString)",
            vaultID: "test",
            name: "video.mp4",
            size: 1000,
            mime: "video/mp4",
            state: "ready",
            createdAt: Date(),
            modifiedAt: Date()
        )
        let url = DownloadEngine.cacheURL(for: object)
        defer { try? fm.removeItem(at: url) }

        try? fm.removeItem(at: url)
        try Data(repeating: 0, count: 500).write(to: url) // half the file
        #expect(DownloadEngine.isCached(object) == false, "a partial file must not count as cached")

        try Data(repeating: 0, count: 1000).write(to: url) // now complete
        #expect(DownloadEngine.isCached(object) == true, "a complete file counts as cached")
    }

    @Test func readerCSSLiteralIsValidJSONString() throws {
        // Regression: BookWebView used JSONSerialization.data(withJSONObject:) on a
        // Swift String, which raises an uncaught ObjC exception ("Invalid top-level
        // type in JSON write") that `try?` can't catch — SIGABRT on every EPUB open.
        // The reader now uses JSONEncoder; assert the produced literal is a quoted,
        // escaped string usable verbatim as a JS string literal.
        let css = "body { font-family: Georgia, 'Times New Roman', serif !important; font-size: 18.0px !important; }\np { margin: 0 0 1.15em !important; }"
        let literal = (try? JSONEncoder().encode(css))
            .map { String(data: $0, encoding: .utf8) ?? "\"\"" } ?? "\"\""

        #expect(literal.hasPrefix("\""))
        #expect(literal.hasSuffix("\""))
        #expect(literal.contains("\\n"), "newlines must be escaped as \\n")
        #expect(literal.contains("'Times New Roman'"))

        // The JSON string parses back to the original CSS (round-trip).
        let decoded = try JSONDecoder().decode(String.self, from: Data(literal.utf8))
        #expect(decoded == css)
    }

    @Test func transferItemRestoresFromRecord() {
        // The record -> card conversion used by restoreHistory must keep identity,
        // so retry/remove/Clear Finished stay in sync with the persisted rows.
        let record = TransferRecord(
            id: "t-restore-fail",
            objectID: "obj-restore-fail",
            name: "lost.bin",
            direction: "download",
            state: "failed",
            progress: 0.4,
            statusText: "Cancelled",
            totalWork: 2,
            errorMessage: "Cancelled",
            startedAt: Date(),
            finishedAt: Date()
        )
        let item = TransferCenter.Item(record: record)
        #expect(item.id == record.id)
        #expect(item.direction == .download)
        #expect(item.state == .failed)
        #expect(item.name == record.name)
        #expect(item.statusText == "Cancelled")

        // And back: a card's persisted form round-trips through the record.
        let roundTrip = TransferCenter.Item(record: item.record)
        #expect(roundTrip.id == item.id)
        #expect(roundTrip.state == .failed)
        #expect(roundTrip.name == item.name)
    }

    // MARK: - Cloud sharing codecs

    @Test func shareLinkRoundTripsThroughURLCodec() {
        let expiry = Date(timeIntervalSinceNow: 7 * 24 * 3600)
        let link = ShareEngine.ShareLink(
            id: "abc-123",
            channelID: -100123456789,
            inviteLink: "https://t.me/+AbCdEf123456",
            shareKey: Data(repeating: 7, count: 32).base64EncodedString(),
            fileName: "photo.jpg",
            expiry: expiry
        )
        let parsed = ShareEngine.ShareLink.parse(link.urlString)
        #expect(parsed != nil, "encoded link must parse back")
        #expect(parsed?.id == link.id)
        #expect(parsed?.channelID == link.channelID)
        #expect(parsed?.inviteLink == link.inviteLink)
        #expect(parsed?.shareKey == link.shareKey)
        #expect(parsed?.fileName == link.fileName)
        #expect(abs((parsed?.expiry.timeIntervalSince1970 ?? 0) - expiry.timeIntervalSince1970) < 1)
    }

    @Test func shareLinkObfuscationHidesInviteAndRoundTrips() throws {
        let expiry = Date(timeIntervalSinceNow: 7 * 24 * 3600)
        let link = ShareEngine.ShareLink(
            id: "obf-1",
            channelID: -100123456789,
            inviteLink: "https://t.me/+AbCdEf123456",
            shareKey: Data(repeating: 9, count: 32).base64EncodedString(),
            fileName: "secret.png",
            expiry: expiry
        )
        let obfuscated = try ShareEngine.obfuscate(link.urlString)

        // The transported form must not leak the invite, the key, or anything that
        // looks like a link — it's an opaque blob.
        #expect(obfuscated.hasPrefix("cascade://share#"))
        #expect(!obfuscated.contains("t.me"))
        #expect(!obfuscated.contains("https"))
        #expect(!obfuscated.contains("inv="))
        #expect(!obfuscated.contains("key="))
        #expect(!obfuscated.contains(link.shareKey))

        // The recipient's app decodes it back to the same link.
        let parsed = ShareEngine.ShareLink.parse(obfuscated)
        #expect(parsed != nil, "obfuscated link must decode back")
        #expect(parsed?.id == link.id)
        #expect(parsed?.channelID == link.channelID)
        #expect(parsed?.inviteLink == link.inviteLink)
        #expect(parsed?.shareKey == link.shareKey)
        #expect(parsed?.fileName == link.fileName)
    }

    @Test func shareChunkMetaRoundTripsThroughCaption() {
        let expectedChunkSize: Int64 = 1024 * 1024
        let meta = ShareEngine.ChunkMeta(
            index: 2,
            totalChunks: 5,
            name: "movie.mkv",
            size: 123456789,
            mime: "video/x-matroska",
            wrappedKey: "wrapped-key-b64",
            rootHash: "deadbeef",
            chunkSize: expectedChunkSize,
            plainHash: "cafebabe"
        )
        let caption = ShareEngine.caption(for: meta)
        #expect(caption.hasPrefix(ShareEngine.captionPrefix))
        let parsed = ShareEngine.parseChunkMeta(caption)
        #expect(parsed != nil, "caption must decode back to the chunk metadata")
        #expect(parsed?.index == 2)
        #expect(parsed?.totalChunks == 5)
        #expect(parsed?.name == "movie.mkv")
        #expect(parsed?.size == 123456789)
        #expect(parsed?.mime == "video/x-matroska")
        #expect(parsed?.wrappedKey == "wrapped-key-b64")
        #expect(parsed?.rootHash == "deadbeef")
        // NB: compare against a stored Int64 variable, not a bare `1024 * 1024`
        // literal — Swift Testing's #expect has a quirk where an Optional LHS
        // compared to an integer arithmetic expression fails even when equal.
        #expect(parsed?.chunkSize == expectedChunkSize)
        #expect(parsed?.plainHash == "cafebabe")
    }

    @Test func unifiedCaptionCodecParsesAllFormats() {
        // Unified chunk caption (what new uploads and shares write).
        let meta = ChunkCaption.Meta(
            kind: ChunkCaption.kindChunk,
            id: "26326FD2-AAF4-4D49-8F2E-286872D02E8E",
            name: "Rings - Dolby Atmos - 16-9.mkv",
            size: 507_814_337,
            mime: "video/x-matroska",
            parentID: "069584F2-331B-46B8-8BE9-54FAA65EB52E",
            isPrivate: false,
            index: 0,
            totalChunks: 4,
            wrappedKey: "",
            chunkSize: 134_217_728,
            plainHash: "cafebabe",
            rootHash: "deadbeef"
        )
        let caption = ChunkCaption.encode(meta, kind: ChunkCaption.kindChunk)
        // Encode emits JSON with sorted keys, so the exact key order after the
        // prefix is not part of the contract — only the unified prefix + object.
        #expect(caption?.hasPrefix(ChunkCaption.unifiedPrefix + "{") == true)
        let parsed = ChunkCaption.parse(caption ?? "")
        #expect(parsed == meta, "unified caption must round-trip")

        // Legacy vault caption (pre-unified uploads — the user's real one).
        let legacyVault = "xcloud:v1:{\"isPrivate\":false,\"isFolder\":false,\"totalChunks\":4,\"wrappedKey\":\"\",\"mime\":\"video/x-matroska\",\"size\":507814337,\"name\":\"Rings - Dolby Atmos - 16-9.mkv\",\"trashed\":false,\"isFavorite\":false,\"index\":0,\"parentID\":\"069584F2-331B-46B8-8BE9-54FAA65EB52E\",\"id\":\"26326FD2-AAF4-4D49-8F2E-286872D02E8E\"}"
        let legacyParsed = ChunkCaption.parse(legacyVault)
        #expect(legacyParsed != nil, "legacy vault captions must stay readable")
        #expect(legacyParsed?.id == "26326FD2-AAF4-4D49-8F2E-286872D02E8E")
        #expect(legacyParsed?.name == "Rings - Dolby Atmos - 16-9.mkv")
        #expect(legacyParsed?.size == 507_814_337)
        #expect(legacyParsed?.index == 0)
        #expect(legacyParsed?.totalChunks == 4)
        #expect(legacyParsed?.wrappedKey == "")
        #expect(legacyParsed?.chunkSize == nil, "legacy captions carry no chunk size")
        #expect(legacyParsed?.effectiveChunkSize == ChunkPlanner.streamingChunkSize,
                "media files assume the streaming chunk size when the caption lacks one")

        // Legacy share caption (pre-v22 disposable channels) — different keys, no id.
        let legacyShare = ShareEngine.caption(for: ShareEngine.ChunkMeta(
            index: 1, totalChunks: 2, name: "f.zip", size: 1000, mime: "application/zip",
            wrappedKey: "wk", rootHash: "rh", chunkSize: 500, plainHash: "ph"
        ))
        #expect(ChunkCaption.parse(legacyShare) == nil, "legacy share captions have no object id — parsed by ShareEngine only")
        #expect(ShareEngine.parseChunkMeta(legacyShare) != nil)

        // Chunk classification for the orphan purge.
        #expect(ChunkCaption.isChunkCaption(caption ?? ""))
        #expect(ChunkCaption.isChunkCaption(legacyVault))
        #expect(ChunkCaption.isChunkCaption(legacyShare))
        let objectMeta = ChunkCaption.encode(ChunkCaption.Meta(
            kind: ChunkCaption.kindObject,
            id: "folder-1", name: "Folder", size: 0, mime: "text/plain",
            isFolder: true, index: 0, totalChunks: 1, wrappedKey: ""
        ), kind: ChunkCaption.kindObject)
        #expect(ChunkCaption.isChunkCaption(objectMeta ?? "") == false,
                "kind \"object\" metadata is never a chunk")
    }

    @Test func forwardShareLinkRoundTripsMessageIDsAndKey() {
        let expiry = Date(timeIntervalSinceNow: 7 * 24 * 3600)
        let link = ShareEngine.ShareLink(
            id: "fwd-1",
            channelID: -100987654321,
            inviteLink: "https://t.me/+XyZ987654321",
            shareKey: Data(repeating: 3, count: 32).base64EncodedString(),
            fileName: "movie.mkv",
            expiry: expiry,
            messageIDs: [1048601, 1048602, 1048603, 1048604],
            wrappedKeyB64: "wrapped-object-key"
        )
        let parsed = ShareEngine.ShareLink.parse(link.urlString)
        #expect(parsed != nil, "v2 link must parse back")
        #expect(parsed?.isForwardBased == true)
        #expect(parsed?.messageIDs == [1048601, 1048602, 1048603, 1048604])
        #expect(parsed?.wrappedKeyB64 == "wrapped-object-key")
        #expect(parsed?.channelID == link.channelID)
        #expect(parsed?.fileName == link.fileName)

        // Non-private files carry no wrapped key; messageIDs alone distinguish v2.
        let plain = ShareEngine.ShareLink(
            id: "fwd-2",
            channelID: -100987654321,
            inviteLink: "https://t.me/+XyZ987654321",
            shareKey: "",
            fileName: "notes.txt",
            expiry: expiry,
            messageIDs: [1048610]
        )
        let parsedPlain = ShareEngine.ShareLink.parse(plain.urlString)
        #expect(parsedPlain?.messageIDs == [1048610])
        #expect(parsedPlain?.wrappedKeyB64 == "")

        // Legacy v1 links parse as non-forward-based.
        let legacy = ShareEngine.ShareLink(
            id: "old-1",
            channelID: -100123456789,
            inviteLink: "https://t.me/+AbCdEf123456",
            shareKey: "sk",
            fileName: "photo.jpg",
            expiry: expiry
        )
        let parsedLegacy = ShareEngine.ShareLink.parse(legacy.urlString)
        #expect(parsedLegacy?.isForwardBased == false)
        #expect(parsedLegacy?.messageIDs.isEmpty == true)
    }

    @Test func groupShareLinkRoundTripsThroughURLCodec() {
        let expiry = Date(timeIntervalSinceNow: 7 * 24 * 3600)
        let link = ShareEngine.ShareLink(
            id: "grp-1",
            channelID: -100555555555,
            inviteLink: "https://t.me/+GrOuP123456789",
            shareKey: "",
            fileName: "3 files",
            expiry: expiry,
            messageIDs: [1048601, 1048602, 1048603, 1048604, 1048605, 1048606, 1048607],
            wrappedKeyB64: "",
            files: [
                ShareEngine.ShareFile(name: "photo.jpg", messageIDs: [1048601, 1048602]),
                ShareEngine.ShareFile(name: "notes.txt", messageIDs: [1048603]),
                ShareEngine.ShareFile(name: "movie.mkv", messageIDs: [1048604, 1048605, 1048606, 1048607])
            ]
        )
        #expect(link.isGroup)
        #expect(link.isForwardBased)

        let parsed = ShareEngine.ShareLink.parse(link.urlString)
        #expect(parsed != nil, "group link must parse back")
        #expect(parsed?.isGroup == true)
        #expect(parsed?.isForwardBased == true)
        #expect(parsed?.files.count == 3)
        #expect(parsed?.files[0].name == "photo.jpg")
        #expect(parsed?.files[0].messageIDs == [1048601, 1048602])
        #expect(parsed?.files[1].name == "notes.txt")
        #expect(parsed?.files[1].messageIDs == [1048603])
        #expect(parsed?.files[2].name == "movie.mkv")
        #expect(parsed?.files[2].messageIDs == [1048604, 1048605, 1048606, 1048607])
        // The flat list stays readable for self-open detection and expiry cleanup.
        #expect(parsed?.messageIDs == [1048601, 1048602, 1048603, 1048604, 1048605, 1048606, 1048607])
        #expect(parsed?.channelID == link.channelID)
        #expect(parsed?.fileName == link.fileName)

        // Obfuscated group links round-trip too (the form actually transported).
        let obfuscated = try? ShareEngine.obfuscate(link.urlString)
        let parsedObf = ShareEngine.ShareLink.parse(obfuscated ?? "")
        #expect(parsedObf?.isGroup == true)
        #expect(parsedObf?.files.count == 3)
        #expect(parsedObf?.files[2].name == "movie.mkv")

        // Single-file links still parse as one-entry, non-group links.
        let single = ShareEngine.ShareLink(
            id: "single-1",
            channelID: -100111,
            inviteLink: "https://t.me/+Single123456789",
            shareKey: "",
            fileName: "a.pdf",
            expiry: expiry,
            messageIDs: [1048610, 1048611]
        )
        let parsedSingle = ShareEngine.ShareLink.parse(single.urlString)
        #expect(parsedSingle?.isGroup == false)
        #expect(parsedSingle?.files.count == 1)
        #expect(parsedSingle?.files.first?.name == "a.pdf")
        #expect(parsedSingle?.files.first?.messageIDs == [1048610, 1048611])
        #expect(parsedSingle?.messageIDs == [1048610, 1048611])
    }

    @Test func groupShareManifestRejectsMalformedPayloads() {
        // A group manifest with a file that resolves to zero chunks must be
        // rejected outright — a partial group would silently drop a file.
        let expiry = Date(timeIntervalSinceNow: 3600)
        let ok = ShareEngine.ShareLink(
            id: "ok", channelID: -1001, inviteLink: "https://t.me/+X", shareKey: "",
            fileName: "2 files", expiry: expiry,
            messageIDs: [1, 2], files: [
                ShareEngine.ShareFile(name: "a", messageIDs: [1]),
                ShareEngine.ShareFile(name: "b", messageIDs: [2])
            ]
        )
        #expect(ShareEngine.ShareLink.parse(ok.urlString) != nil)

        // A manifest naming a single file is not a group link — the parser
        // rejects it instead of degrading to a single-file import.
        let single = ShareEngine.ShareLink(
            id: "solo", channelID: -1001, inviteLink: "https://t.me/+X", shareKey: "",
            fileName: "1 file", expiry: expiry,
            messageIDs: [1], files: [ShareEngine.ShareFile(name: "a", messageIDs: [1])]
        )
        #expect(ShareEngine.ShareLink.parse(single.urlString)?.isGroup == false,
                "a one-entry manifest serializes as a plain single-file link")

        // Garbage in the manifest field is an invalid link, never a fallback.
        let bogus = "cascade://share?v=2&id=x&ch=-1001&inv=https%3A%2F%2Ft.me%2F%2BX&key=&name=2+files&exp=9999999999&f=not-base64"
        #expect(ShareEngine.ShareLink.parse(bogus) == nil)

        // A group manifest whose file has empty message IDs is invalid too.
        let emptyIDs = ShareEngine.ShareLink.encodeFiles([
            ShareEngine.ShareFile(name: "a", messageIDs: [1]),
            ShareEngine.ShareFile(name: "b", messageIDs: [])
        ])
        let withEmpty = "cascade://share?v=2&id=x&ch=-1001&inv=https%3A%2F%2Ft.me%2F%2BX&key=&name=2+files&exp=9999999999&f=\(emptyIDs)"
        #expect(ShareEngine.ShareLink.parse(withEmpty) == nil)
    }

    @Test func shareRefusesPrivateAndFolderObjects() async {
        // Guards run before auth (and before any Telegram/DB access), so the
        // rules are testable without a session.
        let privateFile = ObjectRecord(
            id: "p1", vaultID: "v", name: "secret.txt", size: 1, mime: "text/plain",
            state: "ready", createdAt: Date(), modifiedAt: Date(), isPrivate: true
        )
        do {
            _ = try await ShareEngine.share(objects: [privateFile])
            Issue.record("private files must not be shareable")
        } catch let error as ShareEngine.ShareError {
            #expect(error == .notShareablePrivate)
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        let folder = ObjectRecord(
            id: "f1", vaultID: "v", name: "Folder", size: 0, mime: "text/plain",
            state: "ready", createdAt: Date(), modifiedAt: Date(), isFolder: true
        )
        do {
            _ = try await ShareEngine.share(objects: [folder])
            Issue.record("folders must not be shareable")
        } catch let error as ShareEngine.ShareError {
            #expect(error == .notShareable)
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        // A mixed selection with any non-shareable member fails as a whole — no
        // silent partial share.
        let normal = ObjectRecord(
            id: "n1", vaultID: "v", name: "ok.txt", size: 1, mime: "text/plain",
            state: "ready", createdAt: Date(), modifiedAt: Date()
        )
        do {
            _ = try await ShareEngine.share(objects: [privateFile, normal])
            Issue.record("a selection containing a private file must not share")
        } catch let error as ShareEngine.ShareError {
            #expect(error == .notShareablePrivate)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func shareKeyWrapUnwrapRoundTrips() throws {
        // The share flow wraps the object key with a fresh share key (which rides
        // inside the link); the recipient unwraps it, then re-wraps it under their
        // own vault master key. Round-trip must reproduce the exact same key.
        let shareKey = SymmetricKey(size: .bits256)
        let objectKey = SymmetricKey(size: .bits256)
        let wrapped = try CryptoEngine.wrap(objectKey, with: shareKey)
        let unwrapped = try CryptoEngine.unwrap(wrapped, with: shareKey)

        // AES-GCM seals use a fresh random nonce per call, so two ciphertexts for
        // the same plaintext never compare equal byte-for-byte. Proving the keys
        // are the same key material: each key must decrypt the OTHER's ciphertext.
        let plain = Data("hello share".utf8)
        let withOriginal = try CryptoEngine.encryptSlice(plain, objectKey: objectKey, index: 0)
        let withUnwrapped = try CryptoEngine.encryptSlice(plain, objectKey: unwrapped, index: 0)
        let decOriginal = try CryptoEngine.decryptSlice(withUnwrapped, objectKey: objectKey, index: 0)
        #expect(decOriginal == plain)
        let decUnwrapped = try CryptoEngine.decryptSlice(withOriginal, objectKey: unwrapped, index: 0)
        #expect(decUnwrapped == plain)
    }

    @Test func chunkEncryptionDecryptionMultiSliceRoundTrip() throws {
        let objectKey = SymmetricKey(size: .bits256)
        // 2.5 MB payload spans 3 slices: [1 MB, 1 MB, 512 KB]
        let size = 2 * 1024 * 1024 + 512 * 1024
        var plaintext = Data(count: size)
        _ = plaintext.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, size, $0.baseAddress!)
        }
        
        let startSlice = 12
        let encrypted = try CryptoEngine.encryptChunk(plaintext, objectKey: objectKey, startSliceIndex: startSlice)
        // Overhead should be 3 * 28 = 84 bytes
        #expect(encrypted.count == plaintext.count + 3 * 28)
        
        let decrypted = try CryptoEngine.decryptChunk(encrypted, objectKey: objectKey, startSliceIndex: startSlice)
        #expect(decrypted == plaintext)
    }

    @Test func randomAccessSliceDecryptionMatchesSubrange() throws {
        let objectKey = SymmetricKey(size: .bits256)
        let size = 2 * 1024 * 1024 + 512 * 1024
        var plaintext = Data(count: size)
        _ = plaintext.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, size, $0.baseAddress!)
        }
        
        let startSlice = 4
        let encrypted = try CryptoEngine.encryptChunk(plaintext, objectKey: objectKey, startSliceIndex: startSlice)
        
        // Random access to slice 1 within the chunk (global slice index 5):
        // Slice 0 in chunk: offset 0 ..< sealedSliceSize (1 MB + 28)
        // Slice 1 in chunk: offset sealedSliceSize ..< 2 * sealedSliceSize
        let s0 = 0
        let s1 = CryptoEngine.sealedSliceSize
        let s2 = 2 * CryptoEngine.sealedSliceSize
        
        let slice1Cipher = encrypted.subdata(in: s1 ..< s2)
        let slice1Plain = try CryptoEngine.decryptSlice(slice1Cipher, objectKey: objectKey, index: startSlice + 1)
        let expectedSlice1 = plaintext.subdata(in: 1024 * 1024 ..< 2 * 1024 * 1024)
        #expect(slice1Plain == expectedSlice1)
        
        // Random access to slice 2 (remainder 512 KB):
        let slice2Cipher = encrypted.subdata(in: s2 ..< encrypted.count)
        let slice2Plain = try CryptoEngine.decryptSlice(slice2Cipher, objectKey: objectKey, index: startSlice + 2)
        let expectedSlice2 = plaintext.subdata(in: 2 * 1024 * 1024 ..< size)
        #expect(slice2Plain == expectedSlice2)
    }

    @Test func passwordDerivedLinkKeySealsAndUnlocks() throws {
        let objectKey = SymmetricKey(size: .bits256)
        let salt = Data("cascade-link-salt-42".utf8)
        let password = "SecretPassphrase2026!"
        
        let linkKey = CryptoEngine.deriveLinkKey(from: password, salt: salt)
        let wrapped = try CryptoEngine.wrap(objectKey, with: linkKey)
        
        // Unlock with correct password
        let correctLinkKey = CryptoEngine.deriveLinkKey(from: password, salt: salt)
        let unlocked = try CryptoEngine.unwrap(wrapped, with: correctLinkKey)
        #expect(unlocked.withUnsafeBytes { Data($0) } == objectKey.withUnsafeBytes { Data($0) })
        
        // Attempt unlock with wrong password throws
        let wrongLinkKey = CryptoEngine.deriveLinkKey(from: "WrongPassword123", salt: salt)
        #expect(throws: Error.self) {
            _ = try CryptoEngine.unwrap(wrapped, with: wrongLinkKey)
        }
    }

    @Test func shareReusesLiveLinkInsteadOfMintingNewOne() async throws {
        // Re-sharing a file that already has an active, unexpired outgoing share
        // returns that SAME link (same id/channel/key/expiry) instead of minting a
        // new one — no second channel, no re-upload. Expired or revoked shares are
        // never reused, and legacy v1 records (no forwarded message IDs) always
        // mint a fresh v2 share instead of reusing the old link. Clean up after
        // itself (the test host shares the real DB).
        let now = Date()
        // Server-confirmed message ids in a channel are multiples of 2^20
        // (TDLib's shifted id space); only those are reusable. Local ids (e.g.
        // 101) are broken and must be revoked — covered in step 5 below.
        let live = ShareRecord(
            id: "share-test-live", objectID: "obj-share-reuse",
            channelID: -100123, inviteLink: "https://t.me/+abc", shareKey: "bGl2ZQ==",
            expiry: now.addingTimeInterval(3600), role: "outgoing", state: "active",
            fileName: "reuse-test.png", createdAt: now,
            messageIDs: "1048576,2097152"
        )
        let expired = ShareRecord(
            id: "share-test-expired", objectID: "obj-share-reuse",
            channelID: -100124, inviteLink: "https://t.me/+def", shareKey: "ZXhw",
            expiry: now.addingTimeInterval(-10), role: "outgoing", state: "active",
            fileName: "reuse-test.png", createdAt: now
        )
        try await DatabaseManager.shared.saveShare(live)
        try await DatabaseManager.shared.saveShare(expired)

        // 1) Pre-blob record (no stored linkBlob) reconstructs the same link.
        let link = try await ShareEngine.reusableShareLink(for: "obj-share-reuse")
        #expect(link != nil, "a live outgoing share is reusable")
        if let link, let parsed = ShareEngine.ShareLink.parse(link) {
            #expect(parsed.id == live.id)
            #expect(parsed.channelID == live.channelID)
            #expect(parsed.shareKey == live.shareKey)
            #expect(parsed.messageIDs == [1048576, 2097152])
            // The URL codec stores expiry as whole seconds, so compare at that
            // precision (the record keeps sub-second components).
            #expect(Int(parsed.expiry.timeIntervalSince1970) == Int(live.expiry.timeIntervalSince1970))
        }

        // 2) A v15 record with the stored blob returns it VERBATIM — re-sharing
        // must yield the identical string, not a re-obfuscated look-alike. Give it
        // a LATER expiry so it sorts as the newest share and wins the lookup.
        var withBlob = live
        withBlob.id = "share-test-blob"
        withBlob.linkBlob = "cascade://share#stored-blob-example"
        withBlob.expiry = now.addingTimeInterval(7200)
        try await DatabaseManager.shared.saveShare(withBlob)
        let blobby = try await ShareEngine.reusableShareLink(for: "obj-share-reuse")
        #expect(blobby == "cascade://share#stored-blob-example", "stored blob returned verbatim")

        // 3) Revoking the live share makes it non-reusable (expired is already
        // skipped). Drop the other active record first so the only candidate left
        // is the revoked one.
        try await DatabaseManager.shared.deleteShare(id: live.id)
        var revoked = withBlob
        revoked.state = "revoked"
        try await DatabaseManager.shared.saveShare(revoked)
        let afterRevoke = try await ShareEngine.reusableShareLink(for: "obj-share-reuse")
        #expect(afterRevoke == nil, "revoked or expired shares are never reused")

        // 4) A legacy v1 record (no message IDs, even live and unexpired) is never
        // reused — the old link points at the old upload copy, not forwarded
        // chunks, so re-sharing must mint a fresh v2 share instead.
        try await DatabaseManager.shared.deleteShare(id: revoked.id)
        let legacy = ShareRecord(
            id: "share-test-legacy", objectID: "obj-share-reuse",
            channelID: -100125, inviteLink: "https://t.me/+ghi", shareKey: "bGVn",
            expiry: now.addingTimeInterval(3600), role: "outgoing", state: "active",
            fileName: "reuse-test.png", createdAt: now
        )
        try await DatabaseManager.shared.saveShare(legacy)
        let afterLegacy = try await ShareEngine.reusableShareLink(for: "obj-share-reuse")
        #expect(afterLegacy == nil, "legacy v1 records are never reused")

        try await DatabaseManager.shared.deleteShare(id: expired.id)
        try await DatabaseManager.shared.deleteShare(id: legacy.id)

        // 5) A v2 record whose messageIDs are TDLib LOCAL ids (not multiples of
        // 2^20 — the pre-server-confirm-fix bug that made imports fail with "Not
        // Found") is never reused: it's revoked on sight so re-sharing mints a
        // fresh, valid link instead of handing out a link that can never import.
        try await DatabaseManager.shared.deleteShare(id: live.id)
        let broken = ShareRecord(
            id: "share-test-broken", objectID: "obj-share-reuse",
            channelID: -100126, inviteLink: "https://t.me/+jkl", shareKey: "YnJva2Vu",
            expiry: now.addingTimeInterval(3600), role: "outgoing", state: "active",
            fileName: "reuse-test.png", createdAt: now,
            messageIDs: "1048577,1048585"
        )
        try await DatabaseManager.shared.saveShare(broken)
        let afterBroken = try await ShareEngine.reusableShareLink(for: "obj-share-reuse")
        #expect(afterBroken == nil, "local-id (broken) shares are never reused")
        let reloadedBroken = try await DatabaseManager.shared.share(id: "share-test-broken")
        #expect(reloadedBroken?.state == "revoked", "broken share is revoked so a fresh link is minted")
        try await DatabaseManager.shared.deleteShare(id: "share-test-broken")
    }

    // MARK: - Data-Safety & Hardening Tests

    @Test func replaceCatalogCreatesBackupSnapshot() async throws {
        let account = AccountRecord(
            id: "acc-test-replace-backup",
            telegramUserID: 999996,
            displayName: "Test User",
            state: "ready",
            createdAt: Date()
        )
        let vault = VaultRecord(
            id: "vault-test-replace-backup",
            accountID: account.id,
            channelID: 999996,
            name: "Test Vault",
            wrappedKey: Data(),
            createdAt: Date()
        )
        try await DatabaseManager.shared.save(account)
        try await DatabaseManager.shared.save(vault)

        let obj1 = ObjectRecord(
            id: "obj-backup-1",
            vaultID: vault.id,
            name: "file1.txt",
            size: 100,
            mime: "text/plain",
            state: "ready",
            rootHash: nil,
            wrappedKey: nil,
            createdAt: Date(),
            modifiedAt: Date()
        )
        let chunk1 = ChunkRecord(
            id: "chunk-backup-1",
            objectID: "obj-backup-1",
            index: 0,
            size: 100,
            plainHash: nil,
            cipherHash: nil,
            state: "uploaded",
            messageID: 1001,
            fileUniqueID: nil,
            channelID: 999996,
            createdAt: Date()
        )
        try await DatabaseManager.shared.save(obj1)
        try await DatabaseManager.shared.save(chunk1)

        // Now perform replaceCatalog with new data
        let obj2 = ObjectRecord(
            id: "obj-backup-2",
            vaultID: vault.id,
            name: "file2.txt",
            size: 200,
            mime: "text/plain",
            state: "ready",
            rootHash: nil,
            wrappedKey: nil,
            createdAt: Date(),
            modifiedAt: Date()
        )
        try await DatabaseManager.shared.replaceCatalog(objects: [obj2], chunks: [])

        // Verify current catalog has obj2
        let currentObjects = try await DatabaseManager.shared.allObjects()
        #expect(currentObjects.contains { $0.id == "obj-backup-2" })
        #expect(!currentObjects.contains { $0.id == "obj-backup-1" })

        // Verify backup tables hold the previous catalog (obj1 and chunk1)
        let backupCount = try await DatabaseManager.shared.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM objects_backup WHERE id = 'obj-backup-1'") ?? 0
        }
        #expect(backupCount == 1, "objects_backup must preserve previously replaced objects")

        let chunkBackupCount = try await DatabaseManager.shared.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunks_backup WHERE id = 'chunk-backup-1'") ?? 0
        }
        #expect(chunkBackupCount == 1, "chunks_backup must preserve previously replaced chunks")

        try await DatabaseManager.shared.deleteVaultAndData(id: vault.id)
    }

    @Test func resetVaultRefusesUnconfirmedExecution() async throws {
        let appState = await AppState()
        // Calling resetVault without confirmed: true must early-return without setting isResetting or deleting data
        await appState.resetVault(confirmed: false)
        let isResetting = await appState.isResetting
        #expect(!isResetting)
    }

    @Test func mkvFileClassifiedAsVideoRegardlessOfOctetStreamMime() {
        let obj = ObjectRecord(
            id: "mkv-test",
            vaultID: "v",
            name: "DolbyAtmosTest.mkv",
            size: 50_000_000,
            mime: "application/octet-stream",
            state: "ready",
            rootHash: nil,
            wrappedKey: nil,
            createdAt: Date(),
            modifiedAt: Date()
        )
        #expect(obj.isVideo, "MKV file with octet-stream MIME must be recognized as video")
        #expect(!obj.isAudio)
        #expect(!obj.isPhoto)
        #expect(!obj.isFolder)

        let resolvedMime = UploadEngine.mimeType(for: URL(fileURLWithPath: "/tmp/DolbyAtmosTest.mkv"))
        #expect(resolvedMime == "video/x-matroska", "UploadEngine resolves MKV to video/x-matroska")
    }

    @Test func downloadFailureCardCanBeDiscarded() async {
        await MainActor.run {
            let center = TransferCenter.shared
            center.clearFinished()
            let id = center.begin(.download, objectID: "dl-fail-test", name: "clip.mkv")
            center.cancel(id)
            #expect(center.items.first?.state == .failed)

            // Discarding a failed download must remove it from the center
            center.discard(id)
            #expect(center.items.isEmpty, "discard removes failed download card")
        }
    }

    // MARK: - Share Channel Pool & Public/Private Shares (v24)

    @Test func publicShareLinkCodecNeverExpires() throws {
        // A public share encodes exp = 0 and parses back to Date.distantFuture —
        // "never" must survive the link codec round-trip, and a normal (private)
        // timestamp must parse back to the same second it was encoded with.
        let never = ShareEngine.ShareLink(
            id: "pub-1", channelID: -100200, inviteLink: "https://t.me/+pub",
            shareKey: "", fileName: "public.txt",
            expiry: .distantFuture,
            messageIDs: [1048576, 2097152],
            wrappedKeyB64: "",
            files: [ShareEngine.ShareFile(name: "public.txt", messageIDs: [1048576, 2097152])]
        )
        let parsedNever = try #require(ShareEngine.ShareLink.parse(never.urlString))
        #expect(parsedNever.expiry == .distantFuture, "exp = 0 means never")

        let expiring = ShareEngine.ShareLink(
            id: "priv-1", channelID: -100201, inviteLink: "https://t.me/+priv",
            shareKey: "", fileName: "private.txt",
            expiry: Date(timeIntervalSince1970: 1_800_000_000),
            messageIDs: [3145728],
            wrappedKeyB64: "",
            files: [ShareEngine.ShareFile(name: "private.txt", messageIDs: [3145728])]
        )
        let parsedExpiring = try #require(ShareEngine.ShareLink.parse(expiring.urlString))
        #expect(Int(parsedExpiring.expiry.timeIntervalSince1970) == 1_800_000_000)
    }

    @Test func shareReuseIsKindAware() async throws {
        // A private live share is reused by a private share request, never by a
        // public one — and vice versa. The same file can hold one of each.
        let now = Date()
        let privateShare = ShareRecord(
            id: "share-kind-private", objectID: "obj-kind-test",
            channelID: -100300, inviteLink: "https://t.me/+p", shareKey: "",
            expiry: now.addingTimeInterval(3600), role: "outgoing", state: "active",
            fileName: "kind.txt", createdAt: now,
            messageIDs: "1048576", isPublic: false
        )
        let publicShare = ShareRecord(
            id: "share-kind-public", objectID: "obj-kind-test",
            channelID: -100301, inviteLink: "https://t.me/+u", shareKey: "",
            expiry: .distantFuture, role: "outgoing", state: "active",
            fileName: "kind.txt", createdAt: now,
            messageIDs: "2097152", isPublic: true
        )
        try await DatabaseManager.shared.saveShare(privateShare)
        try await DatabaseManager.shared.saveShare(publicShare)

        let privateLink = try await ShareEngine.reusableShareLink(for: "obj-kind-test", isPublic: false)
        #expect(privateLink != nil, "a private request reuses the private share")
        if let privateLink, let parsed = ShareEngine.ShareLink.parse(privateLink) {
            #expect(parsed.channelID == privateShare.channelID)
        }
        let publicLink = try await ShareEngine.reusableShareLink(for: "obj-kind-test", isPublic: true)
        #expect(publicLink != nil, "a public request reuses the public share")
        if let publicLink, let parsed = ShareEngine.ShareLink.parse(publicLink) {
            #expect(parsed.channelID == publicShare.channelID)
            #expect(parsed.expiry == .distantFuture)
        }

        try await DatabaseManager.shared.deleteShare(id: privateShare.id)
        try await DatabaseManager.shared.deleteShare(id: publicShare.id)
    }

    @Test func privateSharePoolBlocksAtFive() async throws {
        // Five active private shares fill the pool (ids 1…5) — the sixth request
        // is blocked with privatePoolFull, never silently evicting an older link.
        // A public share does NOT occupy a private slot. The test runs against
        // the REAL app database, which can already hold active private shares
        // (genuine links handed out during real usage), so the assertions are
        // relative to that baseline instead of assuming an empty pool.
        let now = Date()
        func activePrivateCount() async -> Int {
            ((try? await DatabaseManager.shared.shares(role: "outgoing")) ?? [])
                .filter { $0.state == "active" && !$0.isPublic }.count
        }
        let baseline = await activePrivateCount()
        // Fillers guarantee the pool is over capacity regardless of baseline.
        let fillerCount = max(0, 5 - baseline) + 1
        var ids: [String] = []
        for i in 1...fillerCount {
            let share = ShareRecord(
                id: "share-pool-\(i)", objectID: "obj-pool-\(i)",
                channelID: -100_400 - Int64(i), inviteLink: "https://t.me/+pool\(i)", shareKey: "",
                expiry: now.addingTimeInterval(3600), role: "outgoing", state: "active",
                fileName: "pool-\(i).txt", createdAt: now,
                messageIDs: "1048576"
            )
            ids.append(share.id)
            try await DatabaseManager.shared.saveShare(share)
        }
        // A public share exists alongside the full private pool — no slot taken.
        try await DatabaseManager.shared.saveShare(ShareRecord(
            id: "share-pool-public", objectID: "obj-pool-public",
            channelID: -100500, inviteLink: "https://t.me/+pub", shareKey: "",
            expiry: .distantFuture, role: "outgoing", state: "active",
            fileName: "pub.txt", createdAt: now,
            messageIDs: "2097152", isPublic: true
        ))
        ids.append("share-pool-public")

        // Over capacity (baseline + fillers ≥ 5): the pool guard must fire.
        do {
            _ = try await ShareEngine.allocatePrivateChannel()
            Issue.record("allocatePrivateChannel must throw when all 5 slots are busy")
        } catch let error as ShareEngine.ShareError {
            #expect(error == .privatePoolFull)
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        // Drop the fillers: back at the baseline (which is < 5 by construction —
        // the pool can't hold more than 5 live private shares in practice), the
        // guard must NOT fire (it will fail later for lack of Telegram — that's
        // fine, the point is the pool guard itself passes).
        for id in ids {
            try await DatabaseManager.shared.deleteShare(id: id)
        }
        if baseline < ShareEngine.privatePoolSize {
            do {
                _ = try await ShareEngine.allocatePrivateChannel()
                Issue.record("expected allocation to fail on Telegram, not the pool guard")
            } catch let error as ShareEngine.ShareError {
                #expect(error != .privatePoolFull, "free slots must not hit the pool limit")
            } catch {
                // TelegramError.notInitialized etc — the guard passed.
            }
        }
    }

    @Test func cancelShareMarksRecordsRevoked() async throws {
        // cancelShare deletes that file's messages from its channel and leaves
        // PRIVATE pool channels (join/leave: the next private share rejoins the
        // same slot via its stored permanent invite); the public channel is
        // permanent and never left. Telegram is not initialized under XCTest,
        // so the Telegram calls fail silently — the record transition is what's
        // verified here.
        let now = Date()
        let privateShare = ShareRecord(
            id: "share-cancel-private", objectID: "obj-cancel-1",
            channelID: -100600, inviteLink: "https://t.me/+cp", shareKey: "",
            expiry: now.addingTimeInterval(3600), role: "outgoing", state: "active",
            fileName: "p.txt", createdAt: now, messageIDs: "1048576"
        )
        let publicShare = ShareRecord(
            id: "share-cancel-public", objectID: "obj-cancel-2",
            channelID: -100601, inviteLink: "https://t.me/+cu", shareKey: "",
            expiry: .distantFuture, role: "outgoing", state: "active",
            fileName: "u.txt", createdAt: now, messageIDs: "2097152", isPublic: true
        )
        try await DatabaseManager.shared.saveShare(privateShare)
        try await DatabaseManager.shared.saveShare(publicShare)

        await ShareEngine.cancelShare(privateShare)
        await ShareEngine.cancelShare(publicShare)

        #expect(try await DatabaseManager.shared.share(id: privateShare.id)?.state == "revoked")
        #expect(try await DatabaseManager.shared.share(id: publicShare.id)?.state == "revoked")

        try await DatabaseManager.shared.deleteShare(id: privateShare.id)
        try await DatabaseManager.shared.deleteShare(id: publicShare.id)
    }

    @Test func archiveShareHidesFromActiveList() async throws {
        let now = Date()
        let share = ShareRecord(
            id: "share-archive-test", objectID: "obj-archive-1",
            channelID: -100700, inviteLink: "https://t.me/+ca", shareKey: "",
            expiry: now.addingTimeInterval(86400), role: "outgoing", state: "active",
            fileName: "archive-test.txt", createdAt: now, messageIDs: "3145728"
        )
        try await DatabaseManager.shared.saveShare(share)

        // Before archive: appears in active list
        let activeBefore = try await DatabaseManager.shared.shares(role: "outgoing")
            .filter { $0.state == "active" && !$0.isArchived }
        #expect(activeBefore.contains { $0.id == share.id })

        // Archive it
        try await DatabaseManager.shared.archiveShare(id: share.id)
        let archived = try await DatabaseManager.shared.share(id: share.id)
        #expect(archived?.isArchived == true, "isArchived should be true after archiving")

        // After archive: disappears from active list
        let activeAfter = try await DatabaseManager.shared.shares(role: "outgoing")
            .filter { $0.state == "active" && !$0.isArchived }
        #expect(!activeAfter.contains { $0.id == share.id })

        // Unarchive it
        try await DatabaseManager.shared.unarchiveShare(id: share.id)
        let unarchived = try await DatabaseManager.shared.share(id: share.id)
        #expect(unarchived?.isArchived == false, "isArchived should be false after unarchiving")

        // Back in active list
        let activeRestore = try await DatabaseManager.shared.shares(role: "outgoing")
            .filter { $0.state == "active" && !$0.isArchived }
        #expect(activeRestore.contains { $0.id == share.id })

        try await DatabaseManager.shared.deleteShare(id: share.id)
    }
}


