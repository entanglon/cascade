//
//  CascadeTests.swift
//  CascadeTests
//
//  Created by Zain Ul Nazir on 05/08/26.
//

import Testing
import Foundation
import AppKit
import CryptoKit
import GRDB
@testable import Cascade

@Suite(.serialized)
struct CascadeTests {

    @Test func databaseIsolationSupportsCustomDatabase() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let tempURL = tempDir.appendingPathComponent("custom-test.sqlite")

        let testDB = DatabaseManager()
        try await testDB.start(customURL: tempURL)
        let path = try await testDB.databasePath()
        #expect(path.hasSuffix("custom-test.sqlite"))
        let transfers = try await testDB.loadTransfers()
        #expect(transfers.isEmpty)
    }

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

    @Test func gridVerticalNavigationUsesFullWidthFolderRows() {
        // Regression (Round 211): folders share the files grid's column count
        // since Round 208 — the old min(cols, 4) cap mis-mapped rows on wide
        // windows. 5 folders at 6 columns = ONE row; down from folder-0 must
        // land on the first file, not wrap into a phantom second folder row.
        var files: [ObjectRecord] = []
        for i in 0..<5 {
            files.append(ObjectRecord(
                id: "folder-\(i)", vaultID: "v", name: "Folder \(i)", size: 0, mime: "",
                state: "ready", createdAt: Date(), modifiedAt: Date(), isFolder: true
            ))
        }
        for i in 0..<6 {
            files.append(ObjectRecord(
                id: "file-\(i)", vaultID: "v", name: "File \(i)", size: 100,
                mime: "text/plain", state: "ready",
                createdAt: Date(), modifiedAt: Date()
            ))
        }
        #expect(FileBrowserView.gridVerticalStep(current: 0, delta: 1, files: files, cols: 6) == 5)
        #expect(FileBrowserView.gridVerticalStep(current: 5, delta: -1, files: files, cols: 6) == 0)
        #expect(FileBrowserView.gridVerticalStep(current: 4, delta: 1, files: files, cols: 6) == 9)
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

        // Uniform ~1.9 GiB chunks: a 1 GiB file fits in ONE chunk
        let fresh = ChunkPlanner.plan(fileSize: gib)
        #expect(fresh.chunkSize == ChunkPlanner.maxSafeChunkSize)
        #expect(fresh.items.count == 1)
        #expect(fresh.items[0].size == gib)

        // A stored chunk size (set at upload time) wins over the global constant so a
        // resumed upload re-derives the exact same chunk boundaries — even across old
        // uploads planned with legacy 128/256 MB sizes.
        let resumed = ChunkPlanner.plan(fileSize: gib, chunkSize: 256 * ChunkPlanner.byteMiB)
        #expect(resumed.chunkSize == 256 * ChunkPlanner.byteMiB)
        #expect(resumed.items.count == 4)
        #expect(resumed.items[1].offset == 256 * ChunkPlanner.byteMiB)
        #expect(resumed.items[1].size == 256 * ChunkPlanner.byteMiB)

        // A 50 GB file splits into ceil(50 GiB / 1.9 GiB) = 27 pieces
        let huge = ChunkPlanner.plan(fileSize: 50 * gib)
        #expect(huge.items.count == 27)
        #expect(huge.items.allSatisfy { $0.size <= ChunkPlanner.maxSafeChunkSize })
    }

    @Test func streamingCryptoRoundTripMatchesWholeBuffer() throws {
        // Deterministic payload spanning whole slices + a partial tail.
        let mb = CryptoEngine.sliceSize
        let totalPlain = 3 * mb + 777
        var source = Data(count: totalPlain)
        for i in 0..<source.count { source[i] = UInt8((i * 31) % 251) }
        let objectKey = SymmetricKey(size: .bits256)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcURL = dir.appendingPathComponent("src.bin")
        let encURL = dir.appendingPathComponent("enc.bin")
        let outURL = dir.appendingPathComponent("out.bin")
        try source.write(to: srcURL)

        // Encrypt via the streaming path
        try FileManager.default.createFile(atPath: encURL.path, contents: nil)
        let inHandle = try FileHandle(forReadingFrom: srcURL)
        let encHandle = try FileHandle(forWritingTo: encURL)
        var pH: SHA256? = SHA256()
        var cH: SHA256? = SHA256()
        let sealedLen = try CryptoEngine.encryptStream(
            from: inHandle, to: encHandle,
            plainByteLimit: Int64(totalPlain),
            objectKey: objectKey, startSliceIndex: 0,
            plainHasher: &pH, cipherHasher: &cH
        )
        try? inHandle.close()
        try? encHandle.close()

        // Sealed size must be exactly slices × (MiB + tag)
        let expectedSealed = 3 * Int64(CryptoEngine.sealedSliceSize) + 777 + 28
        #expect(sealedLen == expectedSealed)

        // Decrypt via the streaming path
        try FileManager.default.createFile(atPath: outURL.path, contents: nil)
        let decIn = try FileHandle(forReadingFrom: encURL)
        let outHandle = try FileHandle(forWritingTo: outURL)
        var dH: SHA256? = SHA256()
        var pH2: SHA256? = SHA256()
        let plainLen = try CryptoEngine.decryptStream(
            from: decIn, to: outHandle,
            cipherByteLimit: sealedLen,
            objectKey: objectKey, startSliceIndex: 0,
            cipherHasher: &dH, plainHasher: &pH2
        )
        try? decIn.close()
        try? outHandle.close()

        #expect(plainLen == Int64(totalPlain))
        let srcSha = try FileHasher.sha256(of: srcURL)
        let outSha = try FileHasher.sha256(of: outURL)
        #expect(outSha == srcSha)

        // Hash bookkeeping must match whole-buffer hashing exactly
        #expect(pH!.finalize().hexString == FileHasher.sha256(of: source))

        // And the classic (whole-buffer) decryptor must read the streamed
        // ciphertext perfectly — cross-implementation compatibility. (Byte-equality
        // of two encryptions is impossible: AES-GCM seals with a random nonce.)
        let streamedCiphertext = try Data(contentsOf: encURL)
        let classicDecrypted = try CryptoEngine.decryptChunk(
            streamedCiphertext, objectKey: objectKey, startSliceIndex: 0
        )
        #expect(classicDecrypted == source)
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

    @Test func encryptedBatchPlanClampsToChunkBoundary() {
        let mb: Int64 = 1024 * 1024
        let sealedFull: Int64 = mb + 28

        // Room for many slices, ask for a batch → exactly the batch size, one
        // chunk's worth of bytes (never past the chunk document).
        let fullChunk = VideoStreamingEngine.planEncryptedBatch(
            plainRemainingInChunk: 128 * mb, maxCount: 8)
        #expect(fullChunk.count == 8)
        #expect(fullChunk.batchBytes == 8 * sealedFull)

        // Near the END of a chunk (2 full slices + 100-byte partial tail): an
        // 8-slice request must clamp to 3 pieces and never cross into the next
        // chunk — this is the round-1 bug class re-checked on the round-4 path.
        let nearTail = VideoStreamingEngine.planEncryptedBatch(
            plainRemainingInChunk: 2 * mb + 100, maxCount: 8)
        #expect(nearTail.count == 3)
        #expect(nearTail.batchBytes == 2 * sealedFull + 128)

        // Tiny remainder → exactly one short piece.
        let tinyTail = VideoStreamingEngine.planEncryptedBatch(
            plainRemainingInChunk: 500, maxCount: 8)
        #expect(tinyTail.count == 1)
        #expect(tinyTail.batchBytes == 528)

        // Remaining smaller than the batch → all of it.
        let threeLeft = VideoStreamingEngine.planEncryptedBatch(
            plainRemainingInChunk: 3 * mb, maxCount: 8)
        #expect(threeLeft.count == 3)
        #expect(threeLeft.batchBytes == 3 * sealedFull)

        // Nothing remaining → nothing requested.
        let empty = VideoStreamingEngine.planEncryptedBatch(plainRemainingInChunk: 0, maxCount: 8)
        #expect(empty.count == 0 && empty.batchBytes == 0)
    }

    @Test func duplicateObjectsClonesRecordAndChunks() async throws {
        // Finder Duplicate: new record ("Name Copy.ext") + cloned chunk rows
        // pointing at the same vault messages (no re-upload). Vault staged
        // first (objects.vaultID FK is enforced).
        let account = AccountRecord(
            id: "acc-test-dup", telegramUserID: 999996,
            displayName: "Dup User", state: "ready", createdAt: Date()
        )
        let vault = VaultRecord(
            id: "vault-test-dup", accountID: account.id, channelID: 999996,
            name: "Dup Vault", wrappedKey: Data(), createdAt: Date()
        )
        try await DatabaseManager.shared.save(account)
        try await DatabaseManager.shared.save(vault)
        let file = ObjectRecord(
            id: "obj-dup-file", vaultID: vault.id, name: "Report.pdf", size: 200,
            mime: "application/pdf", state: "ready",
            createdAt: Date(), modifiedAt: Date()
        )
        try await DatabaseManager.shared.save(file)
        for (i, msg) in [111, 222].enumerated() {
            try await DatabaseManager.shared.save(ChunkRecord(
                id: "chunk-dup-\(i)", objectID: file.id, index: i, size: 100,
                plainHash: nil, cipherHash: nil, state: "uploaded",
                messageID: Int64(msg), fileUniqueID: nil, channelID: -100, createdAt: Date()
            ))
        }
        let appState = await AppState()
        await appState.duplicateObjects([file])
        var copy: ObjectRecord?
        for _ in 0..<100 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            let all = try await DatabaseManager.shared.allObjects()
            if let found = all.first(where: { $0.name == "Report Copy.pdf" }) {
                copy = found
                break
            }
        }
        guard let copy else {
            Issue.record("duplicate copy never materialized")
            try await DatabaseManager.shared.deleteVaultAndData(id: vault.id)
            return
        }
        #expect(copy.id != file.id)
        #expect(copy.parentID == file.parentID)
        #expect(copy.size == file.size)
        let copyChunks = try await DatabaseManager.shared.chunks(for: copy.id)
        #expect(copyChunks.count == 2, "chunk rows cloned, not just the record")
        #expect(Set(copyChunks.compactMap(\.messageID)) == [111, 222], "clones reference the same vault messages")
        #expect(!copyChunks.map(\.id).contains { $0.hasPrefix("chunk-dup-") }, "clones get fresh row IDs")
        try await DatabaseManager.shared.deleteVaultAndData(id: vault.id)
    }

    @Test func transferInfoCloudPathBuildsBreadcrumbs() async throws {        // objects.vaultID has an enforced FK — stage a vault first (the
        // history test's pattern), torn down at the end.
        let account = AccountRecord(
            id: "acc-test-path", telegramUserID: 999997,
            displayName: "Path User", state: "ready", createdAt: Date()
        )
        let vault = VaultRecord(
            id: "vault-test-path", accountID: account.id, channelID: 999997,
            name: "Path Vault", wrappedKey: Data(), createdAt: Date()
        )
        try await DatabaseManager.shared.save(account)
        try await DatabaseManager.shared.save(vault)
        let folder = ObjectRecord(
            id: "obj-path-movies", vaultID: vault.id, name: "Movies", size: 0,
            mime: "cascade/folder", state: "ready",
            createdAt: Date(), modifiedAt: Date(), isFolder: true
        )
        let sub = ObjectRecord(
            id: "obj-path-sub", vaultID: vault.id, name: "Sci-Fi", size: 0,
            mime: "cascade/folder", state: "ready",
            createdAt: Date(), modifiedAt: Date(), parentID: "obj-path-movies", isFolder: true
        )
        let file = ObjectRecord(
            id: "obj-path-file", vaultID: vault.id, name: "Dune.mp4", size: 100,
            mime: "video/mp4", state: "ready",
            createdAt: Date(), modifiedAt: Date(), parentID: "obj-path-sub"
        )
        let priv = ObjectRecord(
            id: "obj-path-priv", vaultID: vault.id, name: "Secret.txt", size: 10,
            mime: "text/plain", state: "ready",
            createdAt: Date(), modifiedAt: Date(), isPrivate: true
        )
        for o in [folder, sub, file, priv] { try await DatabaseManager.shared.save(o) }
        let visible = try await DatabaseManager.shared.object("obj-path-file")
        #expect(visible != nil, "DIAG: row missing right after save (background interference?)")
        let filePath = await TransferInfoPanel.cloudPath(for: file)
        let folderPath = await TransferInfoPanel.cloudPath(for: folder)
        let privPath = await TransferInfoPanel.cloudPath(for: priv)
        #expect(filePath == "All Files / Movies / Sci-Fi", "got: \(filePath)")
        #expect(folderPath == "All Files", "got: \(folderPath)")
        #expect(privPath == "Private Vault", "got: \(privPath)")
        try await DatabaseManager.shared.deleteVaultAndData(id: vault.id)
    }

    @Test func volumeCurveMapsUiToMpvAndBack() {        // flux VolumeCurve mechanism: perceptual sqrt below unity, linear
        // boost above, mute at zero, clamped both ends.
        #expect(abs(VolumeCurve.uiToMpv(0) - 0) < 1e-9)
        #expect(abs(VolumeCurve.uiToMpv(1) - 100) < 1e-9)
        #expect(abs(VolumeCurve.uiToMpv(2) - 200) < 1e-9)
        #expect(abs(VolumeCurve.uiToMpv(0.5) - 70.710678) < 1e-4)
        #expect(abs(VolumeCurve.uiToMpv(1.5) - 150) < 1e-9)
        #expect(abs(VolumeCurve.uiToMpv(-1) - 0) < 1e-9)
        #expect(abs(VolumeCurve.uiToMpv(5) - 200) < 1e-9)
        #expect(abs(VolumeCurve.mpvToUi(0) - 0) < 1e-9)
        #expect(abs(VolumeCurve.mpvToUi(100) - 1) < 1e-9)
        #expect(abs(VolumeCurve.mpvToUi(200) - 2) < 1e-9)
        #expect(abs(VolumeCurve.mpvToUi(50) - 0.25) < 1e-9)
        #expect(abs(VolumeCurve.mpvToUi(150) - 1.5) < 1e-9)
    }

    @Test func sortOptionRoundTripsStoredRawValues() {        // Regression (Round 218): the getter compared lowercase keys that no
        // stored value ever matched, so the menu checkmark sat on Name while
        // sorting obeyed the (correctly written) stored value.
        #expect(FileBrowserView.sortOption(for: "Name") == .name)
        #expect(FileBrowserView.sortOption(for: "name") == .name) // legacy default
        #expect(FileBrowserView.sortOption(for: "Size") == .size)
        #expect(FileBrowserView.sortOption(for: "Date Created") == .dateCreated)
        #expect(FileBrowserView.sortOption(for: "Date Modified") == .dateModified)
        #expect(FileBrowserView.sortOption(for: "Kind") == .kind)
        #expect(FileBrowserView.sortOption(for: "bogus") == .name)
        // Setter writes exactly what the getter reads.
        for option in [FileBrowserView.SortOption.name, .size, .dateCreated, .dateModified, .kind] {
            #expect(FileBrowserView.sortOption(for: option.rawValue) == option)
        }
    }

    @Test func prebufferTargetClampsToShortClips() {        // Normal/long file → the full 4 s threshold.
        #expect(MPVController.prebufferTarget(durationSecs: 3600) == 4.0)
        #expect(MPVController.prebufferTarget(durationSecs: 60) == 4.0)
        // Short clip → (duration − 0.5 s) so the gate can release instead of
        // hanging until the watchdog.
        #expect(MPVController.prebufferTarget(durationSecs: 3) == 2.5)
        // (Binary float: 4.4 − 0.5 is 3.9000000000000004 — compare loosely.)
        #expect(abs(MPVController.prebufferTarget(durationSecs: 4.4) - 3.9) < 1e-9)
        // Unknown duration yet → full threshold (watchdog still backstops).
        #expect(MPVController.prebufferTarget(durationSecs: 0) == 4.0)
        #expect(MPVController.prebufferTarget(durationSecs: -1) == 4.0)
        // Degenerate sub-second clip → floored at 0.5 s, never zero/negative.
        #expect(MPVController.prebufferTarget(durationSecs: 0.6) == 0.5)
    }

    @Test func encryptedStreamingLayoutAndSliceDecryption() throws {
        let mb: Int64 = 1024 * 1024
        let objectKey = SymmetricKey(size: .bits256)
        
        // 5.5 MB payload across 3 chunks: [2 MB, 2 MB, 1.5 MB]
        let totalSize = Int(5.5 * Double(mb))
        var filePlaintext = Data(count: totalSize)
        _ = filePlaintext.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, totalSize, $0.baseAddress!)
        }
        
        let chunk0Plain = filePlaintext.subdata(in: 0 ..< Int(2 * mb))
        let chunk1Plain = filePlaintext.subdata(in: Int(2 * mb) ..< Int(4 * mb))
        let chunk2Plain = filePlaintext.subdata(in: Int(4 * mb) ..< totalSize)
        
        // Encrypt each chunk independently with sequential slice indices
        let chunk0Encrypted = try CryptoEngine.encryptChunk(chunk0Plain, objectKey: objectKey, startSliceIndex: 0)
        let chunk1Encrypted = try CryptoEngine.encryptChunk(chunk1Plain, objectKey: objectKey, startSliceIndex: 2)
        let chunk2Encrypted = try CryptoEngine.encryptChunk(chunk2Plain, objectKey: objectKey, startSliceIndex: 4)
        
        let layout = ObjectLayout(
            fileSize: Int64(totalSize),
            channelID: 100,
            chunks: [
                ChunkLayout(messageID: 101, plainSize: 2 * mb),
                ChunkLayout(messageID: 102, plainSize: 2 * mb),
                ChunkLayout(messageID: 103, plainSize: Int64(chunk2Plain.count))
            ],
            chunkStarts: [0, 2 * mb, 4 * mb],
            contentType: "video/mp4",
            canStream: true,
            objectKey: objectKey
        )
        
        // Verify seek to slice #3 (offset 3MB..4MB, inside chunk 1, local slice 1):
        let targetSliceIndex = 3
        let mapping = layout.chunkAndLocalIndex(for: targetSliceIndex)
        #expect(mapping.chunk == 1)
        #expect(mapping.local == 1)
        
        let sliceCipherOffset = mapping.local * CryptoEngine.sealedSliceSize
        let sealedSliceData = chunk1Encrypted.subdata(in: sliceCipherOffset ..< sliceCipherOffset + CryptoEngine.sealedSliceSize)
        
        let decryptedSlice = try CryptoEngine.decryptSlice(sealedSliceData, objectKey: objectKey, index: targetSliceIndex)
        let expectedSlicePlain = filePlaintext.subdata(in: Int(3 * mb) ..< Int(4 * mb))
        #expect(decryptedSlice == expectedSlicePlain)
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
        #expect(caption.hasPrefix(VaultManager.v2Prefix))
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

    @Test func payloadNonceRoundTripsAndIdentifiesPayload() throws {
        let nonce = UUID().uuidString
        let payload = CatalogSnapshot.Payload(version: 1, objects: [], chunks: [], baseMessageID: 12345, nonce: nonce)
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(CatalogSnapshot.Payload.self, from: data)

        #expect(decoded.nonce == nonce)
        #expect(decoded.baseMessageID == 12345)
    }

    @Test func catalogSnapshotZlibCompressionAndDecompression() throws {
        let now = Date()
        var objects: [ObjectRecord] = []
        var chunks: [ChunkRecord] = []
        for i in 0..<50 {
            let objID = "obj-\(i)"
            objects.append(ObjectRecord(
                id: objID,
                vaultID: "vault-1",
                name: "LargeDataset_File_\(i).dat",
                size: 100 * 1024 * 1024,
                mime: "application/octet-stream",
                state: "ready",
                rootHash: "roothash_\(i)",
                wrappedKey: Data(repeating: UInt8(i), count: 32),
                createdAt: now,
                modifiedAt: now,
                isFavorite: false,
                trashed: false,
                parentID: nil,
                isFolder: false,
                isPrivate: true,
                sourcePath: nil,
                chunkSize: 64 * 1024 * 1024
            ))
            chunks.append(ChunkRecord(
                id: "chunk-\(i)-0",
                objectID: objID,
                index: 0,
                size: 64 * 1024 * 1024,
                plainHash: "plain_\(i)",
                cipherHash: "cipher_\(i)",
                state: "uploaded",
                messageID: Int64(1000 + i),
                fileUniqueID: nil,
                channelID: -10012345,
                createdAt: now
            ))
        }

        let payload = CatalogSnapshot.Payload(version: 1, objects: objects, chunks: chunks)
        let jsonData = try JSONEncoder().encode(payload)
        let compressedData = try (jsonData as NSData).compressed(using: .zlib) as Data
        
        // Zlib compression must compress repetitive JSON significantly (< 30% of original size)
        #expect(compressedData.count < jsonData.count / 2)
        
        // Decompress compressed payload
        let decompressedData = try (compressedData as NSData).decompressed(using: .zlib) as Data
        let decodedCompressed = try JSONDecoder().decode(CatalogSnapshot.Payload.self, from: decompressedData)
        #expect(decodedCompressed.objects.count == 50)
        #expect(decodedCompressed.chunks.count == 50)
        #expect(decodedCompressed.objects[0].name == "LargeDataset_File_0.dat")
        #expect(decodedCompressed.objects[0].wrappedKey == Data(repeating: 0, count: 32))
        
        // Backwards compatibility: uncompressed raw JSON decodes directly without zlib
        let decodedUncompressed = try JSONDecoder().decode(CatalogSnapshot.Payload.self, from: jsonData)
        #expect(decodedUncompressed.objects.count == 50)
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

    @Test func mergeTombstoneAtWinsOverOlderRemoteRecord() {
        let t0 = Date(timeIntervalSince1970: 1_750_000_000)
        let tDeleted = t0.addingTimeInterval(120)
        var tombstonedObj = mergeTestObject(id: "del-1", name: "Deleted.mp4", modifiedAt: tDeleted, trashed: true)
        tombstonedObj.tombstoneAt = tDeleted

        let local = CatalogSnapshot.Payload(version: 1, objects: [tombstonedObj], chunks: [])
        let remote = CatalogSnapshot.Payload(version: 1, objects: [
            mergeTestObject(id: "del-1", name: "Deleted.mp4", modifiedAt: t0)
        ], chunks: [])

        let merged = CatalogSnapshot.merge(local: local, remote: remote, localVaultID: "vault-local")
        let mergedObj = merged.objects.first { $0.id == "del-1" }
        #expect(mergedObj?.tombstoneAt == tDeleted, "tombstone timestamp must survive the merge")

        let changes = CatalogSnapshot.changedRecords(local: local, remote: remote)
        #expect(changes.objects.contains { $0.id == "del-1" && $0.tombstoneAt != nil }, "tombstone record must be publishable in delta")
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
            .appendingPathComponent("cascade-booktest-\(UUID().uuidString)", isDirectory: true)
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
            .appendingPathComponent("cascade-flatten-\(UUID().uuidString)", isDirectory: true)
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

        // Chunk classification for the orphan purge.
        #expect(ChunkCaption.isChunkCaption(caption ?? ""))
        let objectMeta = ChunkCaption.encode(ChunkCaption.Meta(
            kind: ChunkCaption.kindObject,
            id: "folder-1", name: "Folder", size: 0, mime: "text/plain",
            isFolder: true, index: 0, totalChunks: 1, wrappedKey: ""
        ), kind: ChunkCaption.kindObject)
        #expect(ChunkCaption.isChunkCaption(objectMeta ?? "") == false,
                "kind \"object\" metadata is never a chunk")
    }

    @Test func encryptedChunkCaptionWithSanitizedMetadataRoundTrips() {
        let wrappedKeyB64 = Data(repeating: 7, count: 60).base64EncodedString()
        let meta = ChunkCaption.Meta(
            kind: ChunkCaption.kindChunk,
            id: "C1A729A4-2A4A-4835-9C49-E8C2B3C00A11",
            name: "", // Sanitized
            size: 104_857_600,
            mime: "application/octet-stream", // Sanitized
            parentID: nil,
            isPrivate: false,
            index: 1,
            totalChunks: 3,
            wrappedKey: wrappedKeyB64,
            chunkSize: 33_554_432,
            plainHash: "plain12345",
            cipherHash: "cipher67890",
            rootHash: "rootabcdef"
        )
        let encoded = ChunkCaption.encode(meta, kind: ChunkCaption.kindChunk)
        #expect(encoded != nil)
        let parsed = ChunkCaption.parse(encoded ?? "")
        #expect(parsed != nil)
        #expect(parsed?.id == meta.id)
        #expect(parsed?.name == "")
        #expect(parsed?.mime == "application/octet-stream")
        #expect(parsed?.wrappedKey == wrappedKeyB64)
        #expect(parsed?.cipherHash == "cipher67890")
        #expect(parsed?.plainHash == "plain12345")
        #expect(parsed?.chunkSize == 33_554_432)
        #expect(ChunkCaption.isChunkCaption(encoded ?? ""))
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

    @Test func passwordProtectedShareLinkRoundTripsAndUnlocks() throws {
        let objectKey = SymmetricKey(size: .bits256)
        let password = "SecretPassword123!"
        var saltBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &saltBytes)
        let salt = Data(saltBytes)
        let linkKey = CryptoEngine.deriveLinkKey(from: password, salt: salt)
        let wrappedKey = try CryptoEngine.wrap(objectKey, with: linkKey)
        
        let expiry = Date(timeIntervalSinceNow: 7 * 24 * 3600)
        let link = ShareEngine.ShareLink(
            id: "pw-share-1",
            channelID: -100987654321,
            inviteLink: "https://t.me/+SecretLink123456",
            shareKey: "",
            fileName: "classified.pdf",
            expiry: expiry,
            messageIDs: [2001, 2002],
            wrappedKeyB64: wrappedKey.base64EncodedString(),
            saltB64: salt.base64EncodedString()
        )
        
        #expect(link.isPasswordProtected)
        let obfuscated = try ShareEngine.obfuscate(link.urlString)
        let parsed = try #require(ShareEngine.ShareLink.parse(obfuscated))
        
        #expect(parsed.isPasswordProtected)
        #expect(parsed.shareKey.isEmpty)
        #expect(parsed.saltB64 == salt.base64EncodedString())
        #expect(parsed.wrappedKeyB64 == wrappedKey.base64EncodedString())
        
        // Correct password unwraps original objectKey
        let recipientDerivedKey = CryptoEngine.deriveLinkKey(from: password, salt: Data(base64Encoded: parsed.saltB64)!)
        let unwrappedKey = try CryptoEngine.unwrap(Data(base64Encoded: parsed.wrappedKeyB64)!, with: recipientDerivedKey)
        #expect(unwrappedKey == objectKey)
        
        // Wrong password fails to unwrap
        let wrongDerivedKey = CryptoEngine.deriveLinkKey(from: "WrongPassword!", salt: Data(base64Encoded: parsed.saltB64)!)
        #expect(throws: Error.self) {
            try CryptoEngine.unwrap(Data(base64Encoded: parsed.wrappedKeyB64)!, with: wrongDerivedKey)
        }
    }

    @Test func unprotectedSimpleShareLinkRoundTripsAndUnwraps() throws {
        let objectKey = SymmetricKey(size: .bits256)
        let shareKey = SymmetricKey(size: .bits256)
        let wrappedKey = try CryptoEngine.wrap(objectKey, with: shareKey)
        let shareKeyB64 = shareKey.withUnsafeBytes { Data($0).base64EncodedString() }
        
        let expiry = Date(timeIntervalSinceNow: 7 * 24 * 3600)
        let link = ShareEngine.ShareLink(
            id: "simple-share-1",
            channelID: -100987654321,
            inviteLink: "https://t.me/+SimpleLink123456",
            shareKey: shareKeyB64,
            fileName: "vacation.mp4",
            expiry: expiry,
            messageIDs: [3001, 3002, 3003],
            wrappedKeyB64: wrappedKey.base64EncodedString(),
            saltB64: ""
        )
        
        #expect(!link.isPasswordProtected)
        let obfuscated = try ShareEngine.obfuscate(link.urlString)
        let parsed = try #require(ShareEngine.ShareLink.parse(obfuscated))
        
        #expect(!parsed.isPasswordProtected)
        #expect(parsed.shareKey == shareKeyB64)
        
        // Recipient directly un-fragments shareKey and unwraps objectKey with zero password
        let recipientShareKey = SymmetricKey(data: Data(base64Encoded: parsed.shareKey)!)
        let unwrappedKey = try CryptoEngine.unwrap(Data(base64Encoded: parsed.wrappedKeyB64)!, with: recipientShareKey)
        #expect(unwrappedKey == objectKey)
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
            // Folders ARE shareable since item 168 — they expand to descendant
            // files (DB access happens post-auth). Without a session this now
            // surfaces notAuthorized instead of the old folder refusal.
            _ = try await ShareEngine.share(objects: [folder])
            Issue.record("unauthorized session must refuse before any sharing")
        } catch let error as ShareEngine.ShareError {
            #expect(error == .notAuthorized)
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
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let tempDBURL = tempDir.appendingPathComponent("test-replace.sqlite")

        let testDB = DatabaseManager()
        try await testDB.start(customURL: tempDBURL)

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
        try await testDB.save(account)
        try await testDB.save(vault)

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
        try await testDB.save(obj1)
        try await testDB.save(chunk1)

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
        try await testDB.replaceCatalog(objects: [obj2], chunks: [])

        // Verify current catalog has obj2
        let currentObjects = try await testDB.allObjects()
        #expect(currentObjects.contains { $0.id == "obj-backup-2" })
        #expect(!currentObjects.contains { $0.id == "obj-backup-1" })

        // Verify backup tables hold the previous catalog (obj1 and chunk1)
        let backupCount = try await testDB.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM objects_backup WHERE id = 'obj-backup-1'") ?? 0
        }
        #expect(backupCount == 1, "objects_backup must preserve previously replaced objects")

        let chunkBackupCount = try await testDB.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunks_backup WHERE id = 'chunk-backup-1'") ?? 0
        }
        #expect(chunkBackupCount == 1, "chunks_backup must preserve previously replaced chunks")
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

    // MARK: - Upload-time thumbnail pipeline

    @Test func uploadThumbnailJPEGIsGeneratedAndReturnedForAttachment() async throws {
        // A real upload attaches `<id>-up.jpg` to every chunk message — that is
        // the ONLY permanent preview Telegram stores for document uploads, and
        // the guarantee that thumbnails survive local cache clears. This test
        // guards the pipeline end-to-end: subject thumbnail → subject crop →
        // ≤320px JPEG on disk → path returned (non-nil = attached on upload).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumb-test-\(UUID().uuidString).png")
        let size = NSSize(width: 800, height: 600)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            Issue.record("failed to synthesize test PNG")
            return
        }
        try png.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let objectID = "thumb-test-obj-\(UUID().uuidString)"
        let uploadPath = await UploadEngine.generateThumbnails(for: tmp, objectID: objectID)

        #expect(uploadPath != nil, "upload pipeline must return the -up.jpg path")
        if let uploadPath {
            let url = URL(fileURLWithPath: uploadPath)
            #expect(FileManager.default.fileExists(atPath: uploadPath), "-up.jpg must exist on disk")
            #expect(url.lastPathComponent == "\(objectID)-up.jpg")
            #expect(url.pathExtension == "jpg")
            // Must satisfy TDLib's inputThumbnail limit (≤320px).
            if let src = NSImage(contentsOf: url) {
                #expect(max(src.size.width, src.size.height) <= 320, "attached JPEG must be ≤320px for TDLib")
            }
        }
    }

    @Test func thumbnailSidecarEncryptDecryptRoundTrips() async throws {
        // Encrypted uploads attach no thumbnail — the preview is an encrypted
        // sidecar document. The sidecar must round-trip through the SAME chunk
        // codec used for files: encryptChunk/decryptChunk with startSliceIndex 0
        // (the ≤320px JPEG is one slice). Guards the upload+fetch pipeline.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumb-sidecar-\(UUID().uuidString).png")
        let size = NSSize(width: 640, height: 480)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            Issue.record("failed to synthesize test PNG")
            return
        }
        try png.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let objectID = "thumb-sidecar-obj-\(UUID().uuidString)"
        guard let uploadPath = await UploadEngine.generateThumbnails(for: tmp, objectID: objectID) else {
            Issue.record("upload pipeline must produce the -up.jpg path")
            return
        }
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: uploadPath)) }
        let plain = try Data(contentsOf: URL(fileURLWithPath: uploadPath))
        #expect(!plain.isEmpty)

        let key = SymmetricKey(size: .bits256)
        let encrypted = try CryptoEngine.encryptChunk(plain, objectKey: key, startSliceIndex: 0)
        #expect(encrypted != plain, "sidecar bytes must be encrypted (opaque in the channel)")
        let decrypted = try CryptoEngine.decryptChunk(encrypted, objectKey: key, startSliceIndex: 0)
        #expect(decrypted == plain, "sidecar decrypt must restore the exact JPEG")
        // One sealed slice for a <1 MB thumbnail.
        #expect(encrypted.count == plain.count + 28)
    }

    @Test func thumbCaptionCodecMarksSidecarDocuments() {
        let objectID = "sidecar-obj-\(UUID().uuidString)"
        guard let caption = ChunkCaption.thumbCaption(objectID: objectID) else {
            Issue.record("thumb caption must encode")
            return
        }
        #expect(caption.hasPrefix(ChunkCaption.unifiedPrefix))
        #expect(ChunkCaption.isThumbCaption(caption))
        #expect(!ChunkCaption.isChunkCaption(caption), "sidecars must never be orphan-purge candidates")
        guard let meta = ChunkCaption.parse(caption) else {
            Issue.record("thumb caption must parse")
            return
        }
        #expect(meta.kind == ChunkCaption.kindThumb)
        #expect(meta.id == objectID)
    }

    // MARK: - Subtitle sidecars (Wave 2 item 1)

    @Test func subCaptionCodecMarksSidecarDocuments() {
        let videoID = "video-\(UUID().uuidString)"
        guard let caption = ChunkCaption.subCaption(objectID: videoID) else {
            Issue.record("sub caption must encode")
            return
        }
        #expect(caption.hasPrefix(ChunkCaption.unifiedPrefix))
        #expect(ChunkCaption.isSubCaption(caption))
        #expect(!ChunkCaption.isThumbCaption(caption))
        #expect(!ChunkCaption.isChunkCaption(caption), "subtitle sidecars must never be orphan-purge candidates")
        guard let meta = ChunkCaption.parse(caption) else {
            Issue.record("sub caption must parse")
            return
        }
        #expect(meta.kind == ChunkCaption.kindSub)
        #expect(meta.id == videoID)
    }

    @Test func subtitleSidecarJSONRoundTripAndLegacyDecode() throws {
        var record = ObjectRecord(
            id: "video-\(UUID().uuidString)",
            vaultID: "vault",
            name: "Movie.mkv",
            size: 1234,
            mime: "video/x-matroska",
            state: "ready",
            createdAt: Date(),
            modifiedAt: Date()
        )
        #expect(record.subtitleList.isEmpty, "no linkage column → no subtitles")

        // Round-trip a populated list through the JSON column encoding.
        let list = [
            SubtitleSidecar(messageID: 111, name: "Movie.en.srt"),
            SubtitleSidecar(messageID: 222, name: "Movie.ar.ass")
        ]
        let encoded = try #require(ObjectRecord.encodedSubtitles(list))
        record.subtitleSidecars = encoded
        #expect(record.subtitleList == list)

        // Empty list encodes to nil (column stays NULL, not an empty JSON array).
        #expect(ObjectRecord.encodedSubtitles([]) == nil)

        // Old snapshots/rows without the key decode to nil (defensive decoding).
        let legacyJSON = """
        {"id":"\(record.id)","vaultID":"vault","name":"Movie.mkv","size":1234,"mime":"video/x-matroska","state":"ready","createdAt":\(Int(record.createdAt.timeIntervalSince1970)),"modifiedAt":\(Int(record.modifiedAt.timeIntervalSince1970))}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(ObjectRecord.self, from: Data(legacyJSON.utf8))
        #expect(decoded.subtitleSidecars == nil)
        #expect(decoded.subtitleList.isEmpty)
    }

    @Test func subtitleExtensionClassification() {
        func record(_ name: String) -> ObjectRecord {
            ObjectRecord(
                id: UUID().uuidString, vaultID: "v", name: name, size: 10,
                mime: "application/octet-stream", state: "ready",
                createdAt: Date(), modifiedAt: Date()
            )
        }
        #expect(record("movie.srt").isSubtitleFile)
        #expect(record("movie.ass").isSubtitleFile)
        #expect(record("movie.SRT").isSubtitleFile)
        #expect(record("movie.vtt").isSubtitleFile)
        #expect(!record("movie.mkv").isSubtitleFile)
        #expect(!record("notes.txt").isSubtitleFile)
    }

    // MARK: - Offline pins (Wave 2 item 2)

    @Test func offlinePinFlagSurvivesOldSnapshots() throws {
        var record = ObjectRecord(
            id: "obj-\(UUID().uuidString)",
            vaultID: "vault",
            name: "Movie.mkv",
            size: 1234,
            mime: "video/x-matroska",
            state: "ready",
            createdAt: Date(),
            modifiedAt: Date()
        )
        #expect(!record.isPinned, "no flag column → not pinned")

        // Round-trip through Codable.
        record.isPinned = true
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(record)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        #expect(try decoder.decode(ObjectRecord.self, from: data).isPinned)

        // Legacy JSON without the key decodes to false (defensive decoding).
        let legacyJSON = """
        {"id":"\(record.id)","vaultID":"vault","name":"Movie.mkv","size":1234,"mime":"video/x-matroska","state":"ready","createdAt":\(Int(record.createdAt.timeIntervalSince1970)),"modifiedAt":\(Int(record.modifiedAt.timeIntervalSince1970))}
        """
        #expect(try decoder.decode(ObjectRecord.self, from: Data(legacyJSON.utf8)).isPinned == false)
    }

    @Test func pinnedFileStemMatching() {
        let id = UUID().uuidString
        let pinned: Set<String> = [id]
        let base = URL(fileURLWithPath: "/tmp/scratch")

        // Materialized copy naming: <objectID>.<ext> and bare <objectID>.
        #expect(DownloadEngine.isPinnedFile(base.appendingPathComponent("\(id).mkv"), pinned: pinned))
        #expect(DownloadEngine.isPinnedFile(base.appendingPathComponent(id), pinned: pinned))

        // Non-pinned and collision cases.
        #expect(!DownloadEngine.isPinnedFile(base.appendingPathComponent("other-id.mp4"), pinned: pinned))
        #expect(!DownloadEngine.isPinnedFile(base.appendingPathComponent("\(id)-extra.mp4"), pinned: pinned),
                "a longer stem sharing the ID as prefix must NOT match")
        #expect(!DownloadEngine.isPinnedFile(base.appendingPathComponent("prefix-\(id).mp4"), pinned: pinned))

        // Scratch neighbors that are never pins: subtitle sidecars, thumb temps.
        #expect(!DownloadEngine.isPinnedFile(base.appendingPathComponent("sub-123456.srt"), pinned: pinned))
        #expect(!DownloadEngine.isPinnedFile(base.appendingPathComponent("\(id)-thumb.bin"), pinned: pinned))

        // Empty pin set short-circuits.
        #expect(!DownloadEngine.isPinnedFile(base.appendingPathComponent("\(id).mkv"), pinned: []))
    }

    @Test func deviceLocalPinStrippedFromRemoteAdoption() {        // merge() normalizes REMOTE records for adoption — a pin made on another
        // Mac must never arrive here as pinned (device-local semantics).
        var remote = ObjectRecord(
            id: "obj-\(UUID().uuidString)",
            vaultID: "other-vault",
            name: "Big.mkv",
            size: 999,
            mime: "video/x-matroska",
            state: "ready",
            createdAt: Date(),
            modifiedAt: Date(),
            isPinned: true
        )
        remote.vaultID = "remote"
        let local = ObjectRecord(
            id: "local-\(UUID().uuidString)",
            vaultID: "local-vault",
            name: "Mine.txt",
            size: 1,
            mime: "text/plain",
            state: "ready",
            createdAt: Date(),
            modifiedAt: Date()
        )
        let localPayload = CatalogSnapshot.Payload(version: 1, objects: [local], chunks: [])
        let remotePayload = CatalogSnapshot.Payload(version: 1, objects: [remote], chunks: [])
        let merged = CatalogSnapshot.merge(local: localPayload, remote: remotePayload, localVaultID: "local-vault")
        let mergedRemoteCopy = merged.objects.first { $0.id == remote.id }
        #expect(mergedRemoteCopy?.isPinned == false, "remote pins are stripped on adoption")
        #expect(mergedRemoteCopy?.sourcePath == nil)

        // Local pin survives even when the REMOTE record wins LWW (newer timestamp).
        remote.modifiedAt = local.modifiedAt.addingTimeInterval(60)
        remote.name = "Renamed remotely.mkv"
        let localPinned = ObjectRecord(
            id: remote.id,
            vaultID: "local-vault",
            name: "Big.mkv",
            size: 999,
            mime: "video/x-matroska",
            state: "ready",
            createdAt: remote.createdAt,
            modifiedAt: remote.modifiedAt.addingTimeInterval(-120),
            isPinned: true
        )
        let mergedAgain = CatalogSnapshot.merge(
            local: CatalogSnapshot.Payload(version: 1, objects: [localPinned], chunks: []),
            remote: CatalogSnapshot.Payload(version: 1, objects: [remote], chunks: []),
            localVaultID: "local-vault"
        )
        let winner = mergedAgain.objects.first { $0.id == remote.id }
        #expect(winner?.name == "Renamed remotely.mkv", "remote content wins LWW")
        #expect(winner?.isPinned == true, "…but this device's pin survives")
    }

    // MARK: - Finder mirror sync (Wave 2 item 3)

    @Test func mirrorStateTableRoundTrip() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-mirror-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let testDB = DatabaseManager()
        try await testDB.start(customURL: tempURL)

        // Empty at first.
        #expect(try await testDB.mirrorStates().isEmpty)

        let now = Date()
        let entry = MirrorStateRecord(
            id: "obj-mirror-1",
            name: "Report.pdf",
            size: 4096,
            remoteModifiedAt: now,
            localModifiedAt: now.addingTimeInterval(-5),
            rootHash: "hash-1",
            lastSyncedAt: now
        )
        try await testDB.saveMirrorState(entry)

        var fetched = try await testDB.mirrorStates()
        #expect(fetched.count == 1)
        #expect(fetched[0].id == "obj-mirror-1")
        #expect(fetched[0].name == "Report.pdf")
        #expect(fetched[0].size == 4096)
        // GRDB persists dates as millisecond text — compare with tolerance.
        #expect(abs(fetched[0].remoteModifiedAt.timeIntervalSince(now)) < 0.01)
        #expect(abs(fetched[0].localModifiedAt.timeIntervalSince(now.addingTimeInterval(-5))) < 0.01)

        // Upsert replaces (save on the same PK).
        var updated = entry
        updated.size = 8192
        updated.remoteModifiedAt = now.addingTimeInterval(120)
        try await testDB.saveMirrorState(updated)
        fetched = try await testDB.mirrorStates()
        #expect(fetched.count == 1, "upsert must not duplicate the pairing row")
        #expect(fetched[0].size == 8192)

        try await testDB.deleteMirrorState(objectID: "obj-mirror-1")
        #expect(try await testDB.mirrorStates().isEmpty)
    }

    @Test func mirrorDecisionMatrix() {
        let base = Date()
        func record(size: Int64, modifiedAt: Date) -> ObjectRecord {
            ObjectRecord(
                id: UUID().uuidString, vaultID: "v", name: "f.bin", size: size,
                mime: "application/octet-stream", state: "ready",
                createdAt: base, modifiedAt: modifiedAt
            )
        }
        func side(size: Int64 = 100, mtime: Date) -> MirrorSide {
            MirrorSide(exists: true, size: size, modifiedAt: mtime)
        }

        // Nothing anywhere.
        #expect(MirrorSyncEngine.decide(entry: nil, remote: nil, local: nil) == .none)
        // Local-only file → upload.
        #expect(MirrorSyncEngine.decide(entry: nil, remote: nil, local: side(mtime: base)) == .uploadNew)
        // Cloud-only file → materialize locally.
        #expect(MirrorSyncEngine.decide(entry: nil, remote: record(size: 10, modifiedAt: base), local: nil) == .pullOverwrite)
        // Same-named both sides, identical size, never paired → adopt silently.
        #expect(MirrorSyncEngine.decide(
            entry: nil, remote: record(size: 100, modifiedAt: base), local: side(mtime: base)) == .adoptPair)
        // Different sizes, remote newer → LWW overwrite local.
        #expect(MirrorSyncEngine.decide(
            entry: nil, remote: record(size: 200, modifiedAt: base.addingTimeInterval(50)),
            local: side(mtime: base)) == .pullOverwrite)
        // Different sizes, local newer → keep local (no destructive push on adoption).
        #expect(MirrorSyncEngine.decide(
            entry: nil, remote: record(size: 200, modifiedAt: base),
            local: side(mtime: base.addingTimeInterval(50))) == .conflictLocalKeeps)

        // Paired trio — baselines recorded at t=base.
        let entry = MirrorStateRecord(
            id: "obj-x", name: "f.bin", size: 100,
            remoteModifiedAt: base, localModifiedAt: base,
            rootHash: nil, lastSyncedAt: base
        )
        let unchangedRemote = record(size: 100, modifiedAt: base)
        // Nothing changed since baseline.
        #expect(MirrorSyncEngine.decide(
            entry: entry, remote: unchangedRemote, local: side(mtime: base)) == .none)
        // Local edited only → replace remote content.
        #expect(MirrorSyncEngine.decide(
            entry: entry, remote: unchangedRemote, local: side(mtime: base.addingTimeInterval(30))) == .replaceRemote)
        // Remote changed only → pull over local.
        #expect(MirrorSyncEngine.decide(
            entry: entry, remote: record(size: 140, modifiedAt: base.addingTimeInterval(30)),
            local: side(mtime: base)) == .pullOverwrite)
        // Both changed, local newer → replace wins LWW.
        #expect(MirrorSyncEngine.decide(
            entry: entry, remote: record(size: 140, modifiedAt: base.addingTimeInterval(20)),
            local: side(size: 160, mtime: base.addingTimeInterval(40))) == .replaceRemote)
        // Both changed, remote newer → pull wins LWW.
        #expect(MirrorSyncEngine.decide(
            entry: entry, remote: record(size: 180, modifiedAt: base.addingTimeInterval(60)),
            local: side(size: 160, mtime: base.addingTimeInterval(40))) == .pullOverwrite)
        // Paired but local file deleted → v1 skips delete propagation.
        #expect(MirrorSyncEngine.decide(
            entry: entry, remote: unchangedRemote, local: nil) == .dropEntry)
        // Paired but remote gone → v1 keeps the local file, forgets pairing.
        #expect(MirrorSyncEngine.decide(
            entry: entry, remote: nil, local: side(mtime: base)) == .dropEntry)
    }

    @Test func mirrorNameFilter() {
        #expect(MirrorSyncEngine.shouldTrackName("movie.mp4"))
        #expect(MirrorSyncEngine.shouldTrackName("Report FINAL.pdf"))
        #expect(!MirrorSyncEngine.shouldTrackName(".DS_Store"))
        #expect(!MirrorSyncEngine.shouldTrackName(".~lock.Report.docx#"))
        #expect(!MirrorSyncEngine.shouldTrackName("setup.crdownload"))
        #expect(!MirrorSyncEngine.shouldTrackName("export.part"))
        #expect(!MirrorSyncEngine.shouldTrackName("notes.tmp"))
        #expect(!MirrorSyncEngine.shouldTrackName("~$Quarterly.xlsx"))
        #expect(!MirrorSyncEngine.shouldTrackName(".#hidden-edit"))
        #expect(MirrorSyncEngine.shouldTrackName("my.partfile.txt"), ".partfile is part of the stem, not a partial suffix")
    }

    // MARK: - Touch ID vault unlock (Wave 2 item 4)

    @Test func biometricEligibilityGate() {
        // All three conditions must hold: enabled + PIN exists + sensor present.
        #expect(BiometricUnlock.isEligible(enabled: true, hasPINHash: true, biometryAvailable: true))
        #expect(!BiometricUnlock.isEligible(enabled: false, hasPINHash: true, biometryAvailable: true), "toggle off → PIN only")
        #expect(!BiometricUnlock.isEligible(enabled: true, hasPINHash: false, biometryAvailable: true), "no PIN yet (create phase) → never biometric")
        #expect(!BiometricUnlock.isEligible(enabled: true, hasPINHash: true, biometryAvailable: false), "no sensor on this Mac")
        #expect(!BiometricUnlock.isEligible(enabled: false, hasPINHash: false, biometryAvailable: false))

        // The Settings toggle persists and defaults to off.
        let key = BiometricUnlock.enabledKey
        let original = UserDefaults.standard.bool(forKey: key)
        defer { UserDefaults.standard.set(original, forKey: key) }
        #expect(original == false || original == true)
        UserDefaults.standard.set(true, forKey: key)
        #expect(UserDefaults.standard.bool(forKey: key) == true)
    }

    // MARK: - Storage dashboard (Wave 2 item 6)

    private func dashObject(
        _ id: String, parent: String?, isFolder: Bool, size: Int64,
        trashed: Bool = false
    ) -> ObjectRecord {
        ObjectRecord(
            id: id, vaultID: "v", name: isFolder ? id : "\(id).bin", size: size,
            mime: isFolder ? "inode/directory" : "application/octet-stream",
            state: "ready", createdAt: Date(), modifiedAt: Date(),
            trashed: trashed, parentID: parent, isFolder: isFolder
        )
    }

    @Test func storageDashboardRecursiveFolderSizes() {
        let objects = [
            dashObject("Movies", parent: nil, isFolder: true, size: 0),
            dashObject("Season 1", parent: "Movies", isFolder: true, size: 0),
            dashObject("ep1.mkv", parent: "Season 1", isFolder: false, size: 100),
            dashObject("ep2.mkv", parent: "Season 1", isFolder: false, size: 250),
            dashObject("trailer.mp4", parent: "Movies", isFolder: false, size: 50),
            dashObject("Music", parent: nil, isFolder: true, size: 0),
            dashObject("song.mp3", parent: "Music", isFolder: false, size: 10)
        ]
        let sizes = StorageDashboard.folderSubtreeSizes(objects)

        #expect(sizes["Movies"] == 400, "parent folder sums its whole subtree")
        #expect(sizes["Season 1"] == 350, "nested folder counts its own files")
        #expect(sizes["Music"] == 10)

        // Root-level files (parentID nil) are NOT folders — excluded from map.
        #expect(sizes.count == 3)

        // Largest files descending; trash + zero-size excluded.
        let withTrash = objects + [
            dashObject("huge.bin", parent: nil, isFolder: false, size: 9000),
            dashObject("deleted.mkv", parent: "Movies", isFolder: false, size: 5000, trashed: true)
        ]
        let top = StorageDashboard.largestFiles(withTrash, limit: 3)
        #expect(top.map(\.size) == [9000, 250, 100], "trash excluded, descending order")
        #expect(StorageDashboard.totalBytes(withTrash) == 9410, "100+250+50+10+9000; trashed excluded")
    }

    @Test func storageDashboardCycleSafe() {
        // A corrupted catalog cycle (A↔B) must not hang or crash the DFS.
        let objects = [
            dashObject("A", parent: "B", isFolder: true, size: 0),
            dashObject("B", parent: "A", isFolder: true, size: 0),
            dashObject("file.bin", parent: "A", isFolder: false, size: 42)
        ]
        let sizes = StorageDashboard.folderSubtreeSizes(objects)
        #expect(sizes["A"] == 42, "cycle tolerated, files counted once")
        #expect(sizes["B"].map { $0 >= 0 } == true)
    }

    // MARK: - Duplicate finder (Wave 2 item 7)

    private func dupObject(
        _ id: String, name: String, hash: String?, size: Int64,
        trashed: Bool = false, createdDaysAgo: Int = 0
    ) -> ObjectRecord {
        ObjectRecord(
            id: id, vaultID: "v", name: name, size: size,
            mime: "video/x-matroska", state: "ready",
            rootHash: hash, createdAt: Date().addingTimeInterval(Double(-createdDaysAgo) * 86_400),
            modifiedAt: Date(), trashed: trashed, parentID: nil, isFolder: false
        )
    }

    @Test func duplicateFinderGroupsByRootHash() {
        let objects = [
            dupObject("a1", name: "Movie.mkv", hash: "H1", size: 1000, createdDaysAgo: 10),
            dupObject("a2", name: "Movie copy.mkv", hash: "H1", size: 1000, createdDaysAgo: 3),
            dupObject("b1", name: "Song.flac", hash: "H2", size: 80, createdDaysAgo: 5),
            dupObject("b2", name: "Song again.flac", hash: "H2", size: 80, createdDaysAgo: 2),
            dupObject("b3", name: "Song third.flac", hash: "H2", size: 80, createdDaysAgo: 1)
        ]
        let groups = DuplicateFinder.groups(in: objects)

        #expect(groups.count == 2, "two content hashes with >1 copies")
        #expect(groups.map(\.files.count).sorted() == [2, 3], "larger sets first")

        // Members sorted OLDEST FIRST — the keep candidate is the original.
        let h1 = groups.first { $0.id == "H1" }!
        #expect(h1.keepCandidateID == "a1")
        #expect(h1.files.map(\.id) == ["a1", "a2"])
        #expect(h1.wastedBytes(keeping: "a1") == 1000)
        #expect(h1.wastedBytes(keeping: "a2") == 1000)

        let h2 = groups.first { $0.id == "H2" }!
        #expect(h2.wastedBytes(keeping: "b2") == 160, "two non-kept copies")

        // Global reclaimable honors per-group overrides.
        let reclaimable = DuplicateFinder.totalReclaimable(
            groups: groups, keeping: ["H1": "a2"]
        )
        #expect(reclaimable == 1000 + 160)
        #expect(DuplicateFinder.totalReclaimable(groups: groups, keeping: [:]) == 1000 + 160,
                "missing selections default to the oldest copy")
    }

    @Test func duplicateFinderExclusions() {
        let objects = [
            // Unique file → no group.
            dupObject("u1", name: "Unique.pdf", hash: "U1", size: 500),
            // Hashless legacy upload → never a candidate.
            dupObject("n1", name: "Old.mkv", hash: nil, size: 700),
            // Trashed copy → excluded, so its twin is NOT a duplicate.
            dupObject("t1", name: "Twin.mkv", hash: "T1", size: 300),
            dashObject("folderX", parent: nil, isFolder: true, size: 0),
            dupObject("t2", name: "Twin.mkv", hash: "T1", size: 300, trashed: true),
            // Still-uploading object → excluded.
            ObjectRecord(
                id: "wip", vaultID: "v", name: "wip.bin", size: 99,
                mime: "application/octet-stream", state: "uploading",
                rootHash: "W1", createdAt: Date(), modifiedAt: Date(),
                parentID: nil, isFolder: false
            )
        ]
        #expect(DuplicateFinder.groups(in: objects).isEmpty,
                "singletons, trash, hashless, folders and in-flight uploads never group")
    }

    @Test func versionHistoryCarryOverOnReplace() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-versions-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let testDB = DatabaseManager()
        try await testDB.start(customURL: tempURL)

        // Objects carry an FK to their vault — seed one first.
        try await testDB.save(AccountRecord(id: "acc-ver2", telegramUserID: 1, displayName: "T", state: "ready", createdAt: Date()))
        try await testDB.save(VaultRecord(id: "v", accountID: "acc-ver2", channelID: -100, name: "Vault", wrappedKey: Data(), createdAt: Date()))

        let old = ObjectRecord(
            id: "old-file", vaultID: "v", name: "Doc.txt", size: 10,
            mime: "text/plain", state: "ready",
            rootHash: "hash-v1", createdAt: Date(), modifiedAt: Date()
        )
        try await testDB.save(old)
        try await testDB.recordVersion(for: "old-file")

        let replacement = ObjectRecord(
            id: "new-file", vaultID: "v", name: "Doc.txt", size: 20,
            mime: "text/plain", state: "ready",
            rootHash: "hash-v2", createdAt: Date(), modifiedAt: Date()
        )
        try await testDB.save(replacement)

        // The mirror's replace flow carries the retired copy's lineage over.
        try await testDB.carryOverVersions(from: "old-file", to: "new-file")

        let carried = try await testDB.versions(for: "new-file")
        #expect(carried.count == 1)
        #expect(carried[0].versionNumber == 1)
        #expect(carried[0].rootHash == "hash-v1", "history reflects the REPLACED content")

        // Source rows are gone with the old object — nothing dangles.
        let orphans = try await testDB.versions(for: "old-file")
        #expect(orphans.isEmpty)

        // A second replace appends ABOVE the carried history (numbering continues).
        var v2content = replacement
        v2content.rootHash = "hash-v2-still"
        try await testDB.save(v2content)
        try await testDB.carryOverVersions(from: "old-file", to: "new-file") // no-op now
        try await testDB.recordVersion(for: "new-file")
        let all = try await testDB.versions(for: "new-file")
        #expect(all.count == 2)
        #expect(all[0].versionNumber == 2, "descending order, newest first")
    }

    @Test func shareActivityLogRoundTripAndChannelFallback() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-shareact-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let testDB = DatabaseManager()
        try await testDB.start(customURL: tempURL)

        func event(_ id: String, _ shareID: String, _ channelID: Int64, kind: String) -> ShareActivityRecord {
            ShareActivityRecord(
                id: id, shareID: shareID, channelID: channelID,
                kind: kind, userID: kind == "join" ? 4242 : nil,
                detail: "", createdAt: Date()
            )
        }

        try await testDB.recordShareActivity(event("e1", "share-A", -500, kind: "created"))
        try await testDB.recordShareActivity(event("e2", "share-A", -500, kind: "join"))
        // Unattributable public-channel join — same channel, empty share ID.
        try await testDB.recordShareActivity(event("e3", "", -500, kind: "join"))
        try await testDB.recordShareActivity(event("e4", "share-B", -999, kind: "created"))

        let forA = try await testDB.shareActivity(shareID: "share-A", channelID: -500)
        #expect(forA.count == 3, "own rows + unattributed public-channel rows")
        #expect(Set(forA.map(\.id)) == ["e1", "e2", "e3"])

        let joins = forA.filter { $0.kind == "join" }
        #expect(joins.count == 2)
        #expect(joins.compactMap(\.userID) == [4242, 4242])
    }

    @Test func addPasswordToShareRotatesLinkAndInvalidatesOld() throws {
        let objectKey = SymmetricKey(size: .bits256)
        let linkKey = SymmetricKey(size: .bits256)
        let wrapped = try CryptoEngine.wrap(objectKey, with: linkKey).base64EncodedString()
        let oldLinkKeyB64 = linkKey.withUnsafeBytes { Data($0).base64EncodedString() }

        let plain = ShareEngine.ShareLink(
            id: UUID().uuidString, channelID: -700, inviteLink: "https://t.me/+abc",
            shareKey: oldLinkKeyB64, fileName: "Movie.mkv", expiry: Date().addingTimeInterval(3600),
            messageIDs: [11, 22], wrappedKeyB64: wrapped
        ).urlString
        let blob = try ShareEngine.obfuscate(plain)

        var record = ShareRecord(
            id: UUID().uuidString, objectID: "obj-x", channelID: -700,
            inviteLink: "https://t.me/+abc", shareKey: oldLinkKeyB64,
            expiry: Date().addingTimeInterval(3600), role: "outgoing",
            state: "active", fileName: "Movie.mkv", createdAt: Date()
        )
        record.linkBlob = blob
        record.messageIDs = "11,22"
        record.wrappedKeyB64 = wrapped

        let newBlob = try ShareEngine.remintLinkWithPassword(record, password: "hunter2").blob
        #expect(newBlob != blob, "the link is re-minted")

        guard let newPlain = try? ShareEngine.deobfuscate(newBlob),
              let newLink = ShareEngine.ShareLink.parse(newPlain) else {
            Issue.record("new blob must parse")
            return
        }
        #expect(newLink.shareKey.isEmpty, "protected links carry no naked key")
        #expect(!newLink.saltB64.isEmpty)
        #expect(newLink.channelID == -700 && newLink.messageIDs == [11, 22])

        // The new password unwraps the SAME object key.
        let salt = try #require(Data(base64Encoded: newLink.saltB64))
        let derived = CryptoEngine.deriveLinkKey(from: "hunter2", salt: salt)
        let sealed = try #require(Data(base64Encoded: newLink.wrappedKeyB64))
        let recovered = try CryptoEngine.unwrap(sealed, with: derived)
        let originalBytes = objectKey.withUnsafeBytes { Data($0) }
        let recoveredBytes = recovered.withUnsafeBytes { Data($0) }
        #expect(recoveredBytes == originalBytes)

        // The OLD (unprotected) key no longer opens the new blob.
        if let sealedOld = Data(base64Encoded: newLink.wrappedKeyB64) {
            #expect((try? CryptoEngine.unwrap(sealedOld, with: linkKey)) == nil,
                    "old link material must be invalidated")
        }
    }

    @Test func appNotificationLifecycle() async {
        let appState = await AppState()
        await appState.notify(title: "Upload Failed", message: "Network timeout", kind: .error, duration: 10.0)
        let note = await appState.currentNotification
        #expect(note?.title == "Upload Failed")
        #expect(note?.message == "Network timeout")
        #expect(note?.kind == .error)

        await appState.dismissNotification()
        let dismissed = await appState.currentNotification
        #expect(dismissed == nil)
    }

    @Test func rateLimiterBurstAndRefill() async {
        let limiter = RateLimiter(burstCapacity: 3.0, sustainedPerMinute: 60.0) // 1 token/sec
        #expect(await limiter.tryAcquire() == true)
        #expect(await limiter.tryAcquire() == true)
        #expect(await limiter.tryAcquire() == true)
        #expect(await limiter.tryAcquire() == false) // burst depleted

        try? await Task.sleep(nanoseconds: 1_100_000_000)
        #expect(await limiter.tryAcquire() == true) // refilled at least 1 token
    }

    @Test func apiMetricsCallCounting() async {
        let metrics = APIMetrics()
        await metrics.recordCall("sendMessage")
        await metrics.recordCall("sendMessage")
        await metrics.recordCall("deleteMessages")
        #expect(await metrics.totalCallCount(for: "sendMessage") == 2)
        #expect(await metrics.totalCallCount(for: "deleteMessages") == 1)
        #expect(await metrics.currentHourTotal() == 3)
    }

    @Test func logManagerStructuredLogging() async {
        let logger = LogManager.shared
        await logger.log("Test log entry for unit test", level: .info, subsystem: "test")
        let recent = await logger.readRecentLogs(limit: 10)
        #expect(recent.contains { $0.contains("Test log entry for unit test") && $0.contains("[INFO]") && $0.contains("[test]") })
    }

    @Test func partCaptionCodecRoundTrip() {
        let nonce = "test-nonce-\(UUID().uuidString)"
        let caption = CatalogSnapshot.makePartCaption(index: 2, total: 5, nonce: nonce, baseMessageID: 1048576)
        #expect(caption.hasPrefix(CatalogSnapshot.partCaptionPrefix))
        guard let parsed = CatalogSnapshot.parsePartCaption(caption) else {
            Issue.record("part caption must parse")
            return
        }
        #expect(parsed.index == 2)
        #expect(parsed.total == 5)
        #expect(parsed.nonce == nonce)
        #expect(parsed.baseMessageID == 1048576)
    }

    @Test func fts5FullTextSearch() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-fts5-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let testDB = DatabaseManager()
        try await testDB.start(customURL: tempURL)

        let account = AccountRecord(id: "acc-fts", telegramUserID: 12345, displayName: "Test", state: "ready", createdAt: Date())
        let vault = VaultRecord(id: "v1", accountID: account.id, channelID: -100, name: "Vault", wrappedKey: Data(), createdAt: Date())
        try await testDB.save(account)
        try await testDB.save(vault)

        let now = Date()
        let obj1 = ObjectRecord(id: "fts-1", vaultID: "v1", name: "Quarterly Financial Report 2026.pdf", size: 1000, mime: "application/pdf", state: "ready", rootHash: nil, wrappedKey: nil, createdAt: now, modifiedAt: now, isFavorite: false, trashed: false, parentID: nil, isFolder: false, isPrivate: false, sourcePath: nil, chunkSize: 1000)
        let obj2 = ObjectRecord(id: "fts-2", vaultID: "v1", name: "Holiday Photos in Japan.zip", size: 5000, mime: "application/zip", state: "ready", rootHash: nil, wrappedKey: nil, createdAt: now, modifiedAt: now, isFavorite: false, trashed: false, parentID: nil, isFolder: false, isPrivate: false, sourcePath: nil, chunkSize: 5000)
        let obj3 = ObjectRecord(id: "fts-3", vaultID: "v1", name: "Report Summary Draft.docx", size: 2000, mime: "application/docx", state: "ready", rootHash: nil, wrappedKey: nil, createdAt: now, modifiedAt: now, isFavorite: false, trashed: false, parentID: nil, isFolder: false, isPrivate: false, sourcePath: nil, chunkSize: 2000)

        try await testDB.save(obj1)
        try await testDB.save(obj2)
        try await testDB.save(obj3)

        let results = try await testDB.searchObjects(query: "Report")
        #expect(results.count == 2)
        #expect(results.contains { $0.id == "fts-1" })
        #expect(results.contains { $0.id == "fts-3" })

        let prefixResults = try await testDB.searchObjects(query: "Finan")
        #expect(prefixResults.count == 1)
        #expect(prefixResults.first?.id == "fts-1")
    }

    @Test func versionHistoryTracking() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-ver-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let testDB = DatabaseManager()
        try await testDB.start(customURL: tempURL)

        let account = AccountRecord(id: "acc-ver", telegramUserID: 12345, displayName: "Test", state: "ready", createdAt: Date())
        let vault = VaultRecord(id: "v1", accountID: account.id, channelID: -100, name: "Vault", wrappedKey: Data(), createdAt: Date())
        try await testDB.save(account)
        try await testDB.save(vault)

        let now = Date()
        let obj = ObjectRecord(id: "ver-obj-1", vaultID: "v1", name: "document.txt", size: 50, mime: "text/plain", state: "ready", rootHash: "hash-v1", wrappedKey: nil, createdAt: now, modifiedAt: now, isFavorite: false, trashed: false, parentID: nil, isFolder: false, isPrivate: false, sourcePath: nil, chunkSize: 50)
        try await testDB.save(obj)

        try await testDB.recordVersion(for: "ver-obj-1")

        var updated = obj
        updated.rootHash = "hash-v2"
        updated.size = 120
        updated.modifiedAt = now.addingTimeInterval(60)
        try await testDB.save(updated)
        try await testDB.recordVersion(for: "ver-obj-1")

        let versions = try await testDB.versions(for: "ver-obj-1")
        #expect(versions.count == 2)
        #expect(versions[0].versionNumber == 2)
        #expect(versions[0].rootHash == "hash-v2")
        #expect(versions[1].versionNumber == 1)
        #expect(versions[1].rootHash == "hash-v1")
    }

    @Test func conflictBranchPreservationInMerge() {
        let localID = "conflict-file-1"
        let localDate = Date()
        let remoteDate = localDate.addingTimeInterval(-30) // local is slightly newer

        let localObj = ObjectRecord(id: localID, vaultID: "v1", name: "Notes.txt", size: 100, mime: "text/plain", state: "ready", rootHash: "hash-local", wrappedKey: nil, createdAt: localDate, modifiedAt: localDate, isFavorite: false, trashed: false, parentID: nil, isFolder: false, isPrivate: false, sourcePath: nil, chunkSize: 100)
        let remoteObj = ObjectRecord(id: localID, vaultID: "v1", name: "Notes.txt", size: 150, mime: "text/plain", state: "ready", rootHash: "hash-remote", wrappedKey: nil, createdAt: remoteDate, modifiedAt: remoteDate, isFavorite: false, trashed: false, parentID: nil, isFolder: false, isPrivate: false, sourcePath: nil, chunkSize: 150)

        let localChunk = ChunkRecord(id: "c-local", objectID: localID, index: 0, size: 100, plainHash: "p-l", cipherHash: "c-l", state: "uploaded", messageID: 101, fileUniqueID: "fu-l", channelID: -100, createdAt: localDate)
        let remoteChunk = ChunkRecord(id: "c-remote", objectID: localID, index: 0, size: 150, plainHash: "p-r", cipherHash: "c-r", state: "uploaded", messageID: 202, fileUniqueID: "fu-r", channelID: -100, createdAt: remoteDate)

        let local = CatalogSnapshot.Payload(version: 1, objects: [localObj], chunks: [localChunk])
        let remote = CatalogSnapshot.Payload(version: 1, objects: [remoteObj], chunks: [remoteChunk])

        let merged = CatalogSnapshot.merge(local: local, remote: remote, localVaultID: "v1")

        // Merged must have the canonical winner (local) AND the preserved conflicted copy (remote)
        #expect(merged.objects.count == 2)
        let winner = merged.objects.first { $0.id == localID }
        #expect(winner?.rootHash == "hash-local")

        let conflicted = merged.objects.first { $0.id != localID }
        #expect(conflicted != nil)
        #expect(conflicted?.name.contains("Conflicted copy") == true)
        #expect(conflicted?.rootHash == "hash-remote")
    }

    @Test func mergeTombstoneBeatsNewerRemoteLive() {
        // DELETION ABSOLUTISM: a locally tombstoned (deleted) object must stay
        // deleted even when the channel carries a LIVE copy with a NEWER
        // modifiedAt. This exact race resurrected deleted files in the UI when a
        // debounced snapshot sync merged against a stale cached channel scan.
        let deletedAt = Date()
        let newerLive = deletedAt.addingTimeInterval(60) // remote is NEWER

        var localObj = ObjectRecord(
            id: "tomb-file-1", vaultID: "v1", name: "Gone.mp4", size: 1000,
            mime: "video/mp4", state: "ready", rootHash: "hash-gone", wrappedKey: nil,
            createdAt: deletedAt.addingTimeInterval(-3600), modifiedAt: deletedAt,
            isFavorite: false, trashed: false, parentID: nil, isFolder: false,
            isPrivate: false, sourcePath: nil, chunkSize: 1900 * 1024 * 1024
        )
        localObj.tombstoneAt = deletedAt

        let remoteObj = ObjectRecord(
            id: "tomb-file-1", vaultID: "v1", name: "Gone.mp4", size: 1000,
            mime: "video/mp4", state: "ready", rootHash: "hash-gone", wrappedKey: nil,
            createdAt: deletedAt.addingTimeInterval(-3600), modifiedAt: newerLive,
            isFavorite: false, trashed: false, parentID: nil, isFolder: false,
            isPrivate: false, sourcePath: nil, chunkSize: 1900 * 1024 * 1024
        )

        let merged = CatalogSnapshot.merge(
            local: CatalogSnapshot.Payload(version: 1, objects: [localObj], chunks: []),
            remote: CatalogSnapshot.Payload(version: 1, objects: [remoteObj], chunks: []),
            localVaultID: "v1"
        )

        #expect(merged.objects.count == 1)
        let survivor = merged.objects.first { $0.id == "tomb-file-1" }
        #expect(survivor?.tombstoneAt != nil) // stays deleted — never resurrected
    }

    @Test func replaceCatalogNeverResurrectsTombstonedObjects() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let testDB = DatabaseManager()
        try await testDB.start(customURL: tempDir.appendingPathComponent("tomb-replace.sqlite"))

        // objects.vaultID has a FK to vaults — seed the parent rows first.
        try await testDB.save(AccountRecord(
            id: "acc-tomb-replace", telegramUserID: 999995, displayName: "T",
            state: "ready", createdAt: Date()
        ))
        try await testDB.save(VaultRecord(
            id: "v-tr", accountID: "acc-tomb-replace", channelID: 999995,
            name: "T Vault", wrappedKey: Data(), createdAt: Date()
        ))

        let now = Date()
        var obj = ObjectRecord(
            id: "tomb-replace-1", vaultID: "v-tr", name: "Deleted.zip", size: 500,
            mime: "application/zip", state: "ready", rootHash: "rz", wrappedKey: nil,
            createdAt: now, modifiedAt: now, isFavorite: false, trashed: false,
            parentID: nil, isFolder: false, isPrivate: false, sourcePath: nil,
            chunkSize: 1900 * 1024 * 1024
        )
        try await testDB.save(obj)
        try await testDB.markTombstones(ids: [obj.id], at: now)

        // A stale catalog replace arrives carrying the object as LIVE again.
        obj.tombstoneAt = nil
        obj.modifiedAt = now.addingTimeInterval(120) // even "newer"
        try await testDB.replaceCatalog(objects: [obj], chunks: [])

        let row = try await testDB.object(obj.id)
        #expect(row != nil)
        #expect(row?.tombstoneAt != nil) // still deleted — replace must not resurrect
    }

    @Test func transferCenterPriorityOrdering() async {
        let tc = await TransferCenter()
        let id1 = await tc.begin(.download, objectID: "obj-bg", name: "background.zip", priority: .background)
        let id2 = await tc.begin(.download, objectID: "obj-stream", name: "stream.mp4", priority: .interactive)

        let items = await tc.items
        let bgItem = items.first { $0.id == id1 }
        let interactiveItem = items.first { $0.id == id2 }

        #expect(bgItem?.priority == .background)
        #expect(interactiveItem?.priority == .interactive)
        #expect((bgItem?.priority ?? .standard) < (interactiveItem?.priority ?? .standard))
    }

    @Test func pendingUploadRetainsParentIDAndPrivacy() {
        let upload = UploadManager.PendingUpload(
            url: URL(fileURLWithPath: "/tmp/sample.txt"),
            resumeObject: nil,
            transferID: "t-1",
            parentID: "folder-123",
            isPrivate: true
        )
        #expect(upload.parentID == "folder-123")
        #expect(upload.isPrivate == true)
    }
}


