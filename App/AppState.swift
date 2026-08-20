import Foundation
import Observation
import AppKit

enum SidebarDestination: String, CaseIterable, Identifiable, Hashable {
    case allFiles, privateVault, recent, favorites, photos, video, audio, documents, library, transfers, shared, archive, trash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allFiles: return "All Files"
        case .privateVault: return "Private Vault"
        case .recent: return "Recent"
        case .favorites: return "Favorites"
        case .photos: return "Photos"
        case .video: return "Video"
        case .audio: return "Audio"
        case .documents: return "Documents"
        case .library: return "Library"
        case .transfers: return "Transfers"
        case .shared: return "Shared"
        case .archive: return "Archive"
        case .trash: return "Trash"
        }
    }

    var icon: String {
        switch self {
        case .allFiles: return "square.grid.2x2"
        case .privateVault: return "number"
        case .recent: return "clock"
        case .favorites: return "star"
        case .photos: return "photo.fill"
        case .video: return "play.rectangle"
        case .audio: return "music.note"
        case .documents: return "doc.text"
        case .library: return "books.vertical"
        case .transfers: return "arrow.up.arrow.down"
        case .shared: return "arrow.triangle.swap"
        case .archive: return "archivebox"
        case .trash: return "trash"
        }
    }
}

extension Notification.Name {
    /// Posted when a user-facing toast/banner notification should be shown.
    static let cascadeAppNotification = Notification.Name("cascadeAppNotification")
}

@Observable
final class AppState {
    var selectedDestination: SidebarDestination = .allFiles
    var searchText = ""
    var selectedFiles: Set<String> = []
    var isPrivateVaultUnlocked = false
    var thumbnailVersion = 0
    /// The file grid's live column count, kept in sync by FileBrowserView so the
    /// TheaterView preview can navigate up/down through the same rows/columns the
    /// user sees in the browser (instead of being limited to left/right).
    var gridColumnCount = 4
    /// The exact visual order the Photos/Videos grid is showing (albums/playlists
    /// first, then day-grouped media). Reported by the grid via onOrderedChange;
    /// the TheaterView preview walks THIS order for its arrow navigation so the
    /// viewer always follows what the user sees on screen (the grid's day-grouped
    /// order is not expressible as a single global sort, which is why the theater
    /// used to drift to a "random" photo).
    var mediaOrderedIDs: [String] = []

    /// Files shared WITH me — incoming share records, each keyed to the vault
    /// object its import created. Loaded at launch; shown under "Shared".
    var incomingShares: [ShareRecord] = []
    /// Links I handed out — outgoing share records, loaded at launch and after
    /// every share/cancel. Drives the Shared management page.
    var outgoingShares: [ShareRecord] = []
    /// Share link waiting to be shown (drives the "Share Link Ready" sheet).
    var shareResultLink: String? = nil
    /// How many files the pending share link carries (1 = single file; >1 = a
    /// group share) — lets the "Share Link Ready" sheet word itself correctly.
    var shareResultFileCount = 1
    var isSharingFile = false
    /// Targets queued for password-protected share link creation.
    var sharePasswordTargets: [ObjectRecord]? = nil
    /// Share link awaiting password unlock before import.
    var passwordUnlockLink: String? = nil
    /// True when the "Import Shared Link…" dialog should appear (File menu).
    var importShareLinkPrompt = false
    /// A share file staged in the vault channel (pendingImport) awaiting the
    /// user's Import/Cancel decision — drives the review sheet. The forwarded
    /// copy is streamable/previewable before any decision is made.
    var pendingImportID: String? = nil
    /// The staged file backing the review sheet (loaded from the DB by id).
    var pendingImportObject: ObjectRecord? = nil

    // Computed property to keep the Inspector working (only shows if exactly 1 is selected)
    var selectedFile: ObjectRecord? {
        guard selectedFiles.count == 1, let id = selectedFiles.first else { return nil }
        return files.first { $0.id == id }
    }
    var currentFolderID: String? = nil
    var files: [ObjectRecord] = []

    var isDatabaseReady = false
    var isEngineReady = false
    var isCryptoReady = false

    /// True when Telegram API credentials are stored (the API setup step has been
    /// completed at least once). Lets RootView show the login gate on a fresh
    /// install even before TDLib has reported an authorization state — without
    /// stored credentials TDLib can never start, so the neutral splash would
    /// otherwise trap a first-time user on a loading screen forever.
    /// Set synchronously from the Keychain at init so the very FIRST RootView
    /// render already knows whether API credentials exist. Previously this started
    /// false and bootstrap() set it only after ~1-3s of DB/engine setup, so every
    /// launch briefly flashed the login gate (`!hasTelegramCredentials` branch)
    /// before swapping to the auth splash — the "login screen for a split second"
    /// bug for already-logged-in users.
    var hasTelegramCredentials: Bool = (try? KeychainStore.loadTelegramCredentials()) != nil
    var databaseError: String?

    /// Guards the post-auth reconciliation (channel scan, profile, transfers) so it
    /// runs exactly once per session — whether it fires from `bootstrap` at launch or
    /// from the login gate when the user signs in mid-session. Reset on logout so a
    /// re-login re-runs it.
    private var hasCompletedPostAuthSetup = false

    /// Debounced catalog-snapshot uploader (the "database imaging" feature). After
    /// any catalog mutation `loadFiles()` calls `scheduleSnapshotIfChanged()`, which
    /// cancels any pending upload and re-arms a 4s timer — so a burst of changes
    /// publishes ONE fresh snapshot, and the channel always carries the latest full
    /// catalog for instant restore on another device.
    private var snapshotTask: Task<Void, Never>?
    /// Signature of the last catalog state we uploaded a snapshot for.
    private var lastSnapshotSignature = ""

    /// True from app launch until the initial catalog load + Telegram reconciliation
    /// finishes. The file browser shows a loading state instead of the misleading
    /// "Nothing Here Yet" empty state while this is set.
    var isInitialLoading = true

    var showSetup = false
    var showLogin = false
    var showOnboarding = !UserDefaults.standard.bool(forKey: "xc.hasOnboarded")
    var showSettings = false

    /// When the catalog was last successfully published to the channel snapshot.
    /// Persisted so Settings can show it across launches.
    var lastSyncDate: Date? = {
        let v = UserDefaults.standard.double(forKey: "xc.lastSyncDate")
        return v > 0 ? Date(timeIntervalSince1970: v) : nil
    }() {
        didSet {
            if let lastSyncDate {
                UserDefaults.standard.set(lastSyncDate.timeIntervalSince1970, forKey: "xc.lastSyncDate")
            } else {
                UserDefaults.standard.removeObject(forKey: "xc.lastSyncDate")
            }
        }
    }
    /// True while the Settings "Sync Now" action is running.
    var isSyncing = false

    var uploadStatus: String? = nil
    var uploadProgress: Double = 0
    var isUploading = false

    /// Uploads are strictly serial — ONE file at a time. Dropping/pasting several
    /// files enqueues them and they drain one-by-one: concurrent file uploads
    /// congested TDLib's upload pipeline (files visibly stuck at 99% while their
    /// last chunk waited behind other files' chunks). Per-file chunk parallelism
    /// (3 chunks) is unchanged — only files are serialized.
    private struct PendingUpload {
        let url: URL
        let resumeObject: ObjectRecord?
        let transferID: String?
    }

    @MainActor private var uploadQueue: [PendingUpload] = []
    @MainActor private var isDrainingUploadQueue = false
    var isResetting = false

    var isDownloading = false
    var downloadStatus: String? = nil
    var downloadProgress: Double = 0
    var alertMessage: String? = nil
    var theaterFile: ObjectRecord? = nil
    /// Book currently open in the reader (epub / pdf / text / comic).
    var readerFile: ObjectRecord? = nil
    var isTheaterFullScreen: Bool = false

    /// Object whose card should flash its border after a "reveal in folder"
    /// (double-click on a completed transfer card). Cleared automatically once the
    /// flash finishes.
    var revealObjectID: String? = nil
    /// Bumped on every reveal so the flash retriggers even for the same object.
    var revealToken = 0
    var identity: TelegramClient.AccountIdentity? = nil
    var profilePhotoData: Data? = nil

    var statusText: String {
        if let databaseError { return "Startup error: \(databaseError)" }
        if isCryptoReady {
            let tg = TelegramClient.shared
            if tg.isAuthorized { return "All engines ready · Telegram connected" }
            if tg.isConnected { return "All engines ready · Telegram awaiting auth" }
            return "Storage + chunk + crypto ready."
        }
        if isEngineReady { return "Preparing crypto engine…" }
        if isDatabaseReady { return "Verifying chunk engine…" }
        return "Starting storage engine…"
    }

    // MARK: - Toast / Banner Notifications

    enum NotificationKind: String, Sendable {
        case info
        case warning
        case error
        case success
    }

    struct AppNotification: Identifiable, Equatable, Sendable {
        let id: UUID
        let title: String
        let message: String?
        let kind: NotificationKind
        let timestamp: Date

        init(title: String, message: String? = nil, kind: NotificationKind = .info) {
            self.id = UUID()
            self.title = title
            self.message = message
            self.kind = kind
            self.timestamp = Date()
        }
    }

    var currentNotification: AppNotification? = nil
    private var notificationDismissTask: Task<Void, Never>? = nil

    @MainActor
    func notify(title: String, message: String? = nil, kind: NotificationKind = .info, duration: TimeInterval = 4.0) {
        notificationDismissTask?.cancel()
        currentNotification = AppNotification(title: title, message: message, kind: kind)
        notificationDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if self.currentNotification?.title == title {
                self.currentNotification = nil
            }
        }
    }

    @MainActor
    func dismissNotification() {
        notificationDismissTask?.cancel()
        currentNotification = nil
    }

    var breadcrumbs: [(id: String?, name: String)] {
        var chain: [ObjectRecord] = []
        var current = currentFolderID
        while let id = current, let folder = files.first(where: { $0.id == id }) {
            chain.append(folder)
            current = folder.parentID
        }
        var result: [(String?, String)] = [(nil, "All Files")]
        for folder in chain.reversed() {
            result.append((folder.id, folder.name))
        }
        return result
    }

    @MainActor
    func loadFiles() async {
        do {
            let objects = try await DatabaseManager.shared.allObjects().filter { $0.tombstoneAt == nil }
            self.files = objects.sorted { lhs, rhs in
                if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
                return lhs.createdAt > rhs.createdAt
            }
            if let currentTrackID = AudioPlayerEngine.shared.currentTrack?.id {
                if let track = self.files.first(where: { $0.id == currentTrackID }) {
                    if track.trashed {
                        AudioPlayerEngine.shared.stop()
                    }
                } else {
                    AudioPlayerEngine.shared.stop()
                }
            }
            if let theaterID = theaterFile?.id {
                if let file = self.files.first(where: { $0.id == theaterID }) {
                    if file.trashed {
                        theaterFile = nil
                    }
                } else {
                    theaterFile = nil
                }
            }
        } catch {
            print("Failed to load files: \(error)")
        }
        await scheduleSnapshotIfChanged()
    }

    /// Publishes a fresh catalog snapshot to the channel when the catalog changed
    /// since the last publish. Debounced so a burst of mutations produces one upload.
    @MainActor
    private func scheduleSnapshotIfChanged() async {
        guard TelegramClient.shared.isAuthorized else { return }
        let signature = await currentCatalogSignature()
        guard signature != lastSnapshotSignature else { return }
        lastSnapshotSignature = signature
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            if let syncedAt = await CatalogSnapshot.upload() {
                self?.lastSyncDate = syncedAt
                // The upload merges the channel's snapshot into the local catalog —
                // reload so records published by other devices show up immediately.
                await self?.loadFiles()
            }
        }
    }

    /// Stable fingerprint of the current catalog (object identity + state + parent +
    /// modifiedAt, plus the chunk count) used to decide whether a publish is needed.
    @MainActor
    private func currentCatalogSignature() async -> String {
        let chunkCount = (try? await DatabaseManager.shared.allChunks())?.count ?? 0
        return files.map { "\($0.id):\($0.modifiedAt.timeIntervalSince1970):\($0.state):\($0.trashed):\($0.isArchived):\($0.parentID ?? "")" }
            .joined(separator: "|") + "|chunks:\(chunkCount)"
    }

    /// Uploads a fresh catalog snapshot immediately, bypassing the debounce. Used by
    /// the Settings "Sync Now" button and at the end of every post-auth setup, so the
    /// channel is guaranteed to carry a snapshot even if it was ever missing.
    @MainActor
    func forcePublishSnapshot() async {
        guard TelegramClient.shared.isAuthorized else { return }
        // Collapse guard: never overwrite the channel's snapshot if the local
        // catalog is empty — an empty publish is exactly how the 2026-08-15
        // collapse propagated.
        let fileCount = ((try? await DatabaseManager.shared.allObjects()) ?? [])
            .filter { !$0.isFolder }.count
        if fileCount == 0 {
            print("Cascade: refusing to force-publish empty snapshot (collapse guard)")
            return
        }
        snapshotTask?.cancel()
        if let syncedAt = await CatalogSnapshot.upload() {
            lastSyncDate = syncedAt
            lastSnapshotSignature = await currentCatalogSignature()
            // The upload merges the channel's snapshot into the local catalog —
            // reload so records published by other devices show up immediately.
            await self.loadFiles()
            notify(title: "Catalog Synced", message: "Cloud catalog snapshot successfully updated.", kind: .success)
        } else {
            notify(title: "Sync Failed", message: "Unable to update cloud snapshot. Check your connection.", kind: .error)
        }
    }

    /// True when the app is running as a unit-test host. In that case TDLib must not
    /// start: XCTest exits the process with exit(), which tears down TDLib's C++ core
    /// while its background receive thread is still polling, crashing with a segfault
    /// (the app normally avoids this via TerminationHandler's _exit).
    private var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    @MainActor
    func bootstrap() async {
        isInitialLoading = true
        defer { isInitialLoading = false }
        do {
            NotificationCenter.default.addObserver(forName: .cascadeAppNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, let userInfo = note.userInfo,
                      let title = userInfo["title"] as? String else { return }
                let message = userInfo["message"] as? String
                let kindStr = userInfo["kind"] as? String ?? "info"
                let kind = NotificationKind(rawValue: kindStr) ?? .info
                self.notify(title: title, message: message, kind: kind)
            }

            try await DatabaseManager.shared.start()
            try await DatabaseManager.shared.selfTest()
            isDatabaseReady = true
            await self.loadFiles()

            // Restore finished-transfer history (completed/failed cards) so the
            // Transfers page keeps its cards across app restarts.
            await TransferCenter.shared.restoreHistory()
            await self.loadShares()

            try await ChunkEngine.selfTest()
            isEngineReady = true

            try await CryptoEngine.selfTest()
            isCryptoReady = true

            guard !isRunningUnderXCTest else { return }

            // Keep the local cache within budget even when the user only streams:
            // evict oldest files at launch and on a 30-minute timer when the hard
            // cap is hit or free disk space drops below the floor. Downloads also
            // trigger this in DownloadEngine.
            DownloadEngine.enforceCacheBudget()
            Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
                    DownloadEngine.enforceCacheBudget()
                }
            }

            if let creds = try KeychainStore.loadTelegramCredentials() {
                hasTelegramCredentials = true
                await startTelegram(apiID: creds.apiID, apiHash: creds.apiHash)
            }

            for _ in 0..<20 {
                if TelegramClient.shared.isAuthorized { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if TelegramClient.shared.isAuthorized {
                // Hidden debug hook: `--repair-catalog <comma,objectIDs>` performs
                // catalog surgery THROUGH the app's own DatabaseManager (same GRDB
                // connection — no CLI-vs-app WAL divergence), then republishes the
                // corrected catalog as a fresh checkpoint (pruning stale ones) and
                // quits. It runs BEFORE completePostAuthSetup so the reconcile merge
                // (which folds stale records from an old checkpoint back in) can't
                // undo the surgery. Operations: (1) drop the given object IDs and
                // their chunk rows, (2) re-sync every chunk's recorded size to the
                // actual document size Telegram stores, (3) publish checkpoint.
                // Result goes to /tmp/xcloud-repair-catalog.txt.
                if let idx = CommandLine.arguments.firstIndex(of: "--repair-catalog"),
                   CommandLine.arguments.indices.contains(idx + 1) {
                    let dropIDs = CommandLine.arguments[idx + 1].split(separator: ",").map(String.init)
                    var log = "repair-catalog: dropping \(dropIDs.count) object(s)\n"
                    for id in dropIDs {
                        do {
                            // Capture the object's chunk message IDs BEFORE the rows go —
                            // a local-only drop leaves the messages in the channel and
                            // VaultRepair rebuilds the object from its caption at the
                            // next launch (the "file1.txt keeps coming back" loop).
                            let messageIDs = (try? await DatabaseManager.shared.chunks(for: id))?
                                .compactMap(\.messageID) ?? []
                            try await DatabaseManager.shared.deleteObjectWithChunks(id: id)
                            log += "dropped \(id)"
                            if !messageIDs.isEmpty {
                                await BackupSync.deleteFromVaultAndBackup(messageIDs: messageIDs)
                                log += " (+\(messageIDs.count) channel message(s) deleted from vault + backup)"
                            }
                            log += "\n"
                        } catch {
                            log += "drop failed \(id): \(error.localizedDescription)\n"
                        }
                    }
                    var fixed = 0
                    if let vault = try? await DatabaseManager.shared.firstVault() {
                        let chunks = (try? await DatabaseManager.shared.allChunks()) ?? []
                        for chunk in chunks {
                            guard let messageID = chunk.messageID, messageID > 0 else { continue }
                            if let actual = try? await TelegramClient.shared.fileSize(
                                forMessage: messageID, chatId: vault.channelID
                            ), actual > 0, actual != chunk.size {
                                try? await DatabaseManager.shared.updateChunk(chunk.id) { $0.size = actual }
                                fixed += 1
                            }
                        }
                    }
                    log += "fixed \(fixed) chunk size(s)\n"
                    if let syncedAt = await CatalogSnapshot.publishCheckpointFromLocal(force: true) {
                        log += "checkpoint republished: \(syncedAt)\n"
                    } else {
                        log += "checkpoint publish FAILED\n"
                    }
                    try? log.write(toFile: "/tmp/xcloud-repair-catalog.txt", atomically: true, encoding: .utf8)
                    NSApp.terminate(nil)
                    return
                }

                await completePostAuthSetup()

                // Hidden debug hook: `--cache-video <objectID>` downloads the object
                // to the cache dir and quits — used to pull a real vault file for
                // offline debugging (e.g. reproducing mpv render crashes).
                if let idx = CommandLine.arguments.firstIndex(of: "--cache-video"),
                   CommandLine.arguments.indices.contains(idx + 1) {
                    let objectID = CommandLine.arguments[idx + 1]
                    if let obj = try? await DatabaseManager.shared.object(objectID) {
                        print("Cascade debug: caching video \(objectID)")
                        _ = try? await DownloadEngine.download(object: obj, quiet: true) { _, _ in }
                        print("Cascade debug: cached \(obj.name) -> \(DownloadEngine.cacheURL(for: obj).path(percentEncoded: false))")
                    }
                    NSApp.terminate(nil)
                }

                // Hidden debug hook: `--regenerate-thumbnails` re-extracts a
                // representative mpv frame for every cached video, replacing old
                // black QuickLook first-frame thumbs (the `<id>.png` + `<id>-up.jpg`
                // pair), then quits. Used after the thumbnail capturer changed.
                if CommandLine.arguments.contains("--regenerate-thumbnails") {
                    let objects = (try? await DatabaseManager.shared.allObjects()) ?? []
                    var done = 0
                    var failed = 0
                    for obj in objects where obj.mime.hasPrefix("video/") && !obj.isFolder {
                        let url = DownloadEngine.cacheURL(for: obj)
                        guard DownloadEngine.isCached(obj),
                              FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { continue }
                        if await UploadEngine.generateThumbnails(for: url, objectID: obj.id, isVideo: true) != nil {
                            done += 1
                            print("Cascade debug: regenerated thumbnail for \(obj.name)")
                        } else {
                            failed += 1
                            print("Cascade debug: thumbnail FAILED for \(obj.name)")
                        }
                    }
                    print("Cascade debug: regenerated \(done) video thumbnails (\(failed) failed)")
                    NSApp.terminate(nil)
                }

                // Hidden debug hook: `--capture-test <path>` runs ONE representative-
                // frame extraction on a file and writes the result to /tmp/thumb-test.png
                // (plus diagnostics to the unified log), then quits — fast iteration
                // for the FFmpeg frame extractor.
                if let idx = CommandLine.arguments.firstIndex(of: "--capture-test"),
                   CommandLine.arguments.indices.contains(idx + 1) {
                    let url = URL(fileURLWithPath: CommandLine.arguments[idx + 1])
                    let img = await VideoFrameExtractor.representativeFrame(from: url)
                    if let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                       let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: "/tmp/thumb-test.png"))
                        print("Cascade debug: capture-test OK \(Int(img.size.width))x\(Int(img.size.height)) -> /tmp/thumb-test.png")
                    } else {
                        print("Cascade debug: capture-test FAILED")
                    }
                    NSApp.terminate(nil)
                }

                // Hidden debug hook: `--video-thumb <objectID>` generates a video
                // thumbnail through the REAL thumbnail-service path — cached files
                // extract locally, never-downloaded files extract via the loopback
                // stream URL (byte-range requests, no whole-file download) — writes
                // the result to a FILE (stdout is block-buffered when launched by an
                // agent, so prints can vanish on terminate) and quits. Verifies the
                // uncached-video thumbnail fix (e.g. House of the Dragon) headlessly.
                if let idx = CommandLine.arguments.firstIndex(of: "--video-thumb"),
                   CommandLine.arguments.indices.contains(idx + 1) {
                    let id = CommandLine.arguments[idx + 1]
                    let resultPath = "/tmp/xcloud-vidthumb-result.txt"
                    let out = { (text: String) in try? text.write(toFile: resultPath, atomically: true, encoding: .utf8) }
                    if let obj = try? await DatabaseManager.shared.object(id) {
                        let url = await ThumbnailService.shared.thumbnailURL(for: obj)
                        out("video-thumb \(obj.name) -> \(String(describing: url?.path(percentEncoded: false)))")
                    } else {
                        out("video-thumb object not found \(id)")
                    }
                    NSApp.terminate(nil)
                }

                // Hidden debug hook: `--recover-upload <cacheDir>` re-uploads every
                // READY file object whose bytes exist in <cacheDir> back to the vault
                // channel (2026-08-15 recovery: a repair regression deleted the chunk
                // documents from Telegram; the local cache still holds the plaintext).
                // Reuses each object's ID/name/parent/chunk-size via resumeObject, so
                // folder memberships survive. Chunk rows are cleared first so nothing
                // is skipped. Progress + result go to /tmp/xcloud-recover-progress.txt.
                // Resumable: run repeatedly until all files report uploaded.
                if let idx = CommandLine.arguments.firstIndex(of: "--recover-upload"),
                   CommandLine.arguments.indices.contains(idx + 1) {
                    let cacheDir = URL(fileURLWithPath: CommandLine.arguments[idx + 1], isDirectory: true)
                    let resultPath = "/tmp/xcloud-recover-progress.txt"
                    let log = { (text: String) in
                        if var cur = try? String(contentsOfFile: resultPath, encoding: .utf8) {
                            cur += text + "\n"
                            try? cur.write(toFile: resultPath, atomically: true, encoding: .utf8)
                        } else {
                            try? text.write(toFile: resultPath, atomically: true, encoding: .utf8)
                        }
                        print("Cascade recover: \(text)")
                    }
                    log("=== recovery run \(Date()) ===")
                    let objects = (try? await DatabaseManager.shared.allObjects()) ?? []
                    let files = objects.filter { !$0.isFolder && !$0.trashed }
                    log("\(files.count) file objects in catalog")
                    let fm = FileManager.default
                    let cacheEntries = (try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? []
                    for obj in files {
                        // Locate the cached bytes: <cacheDir>/<objectID>.<ext>
                        let cached = cacheEntries.first {
                            $0.deletingPathExtension().lastPathComponent == obj.id &&
                            fm.fileExists(atPath: $0.path(percentEncoded: false))
                        }
                        guard let cached else {
                            log("MISSING-CACHE \(obj.id) \(obj.name) — bytes not on disk, cannot recover")
                            continue
                        }
                        if obj.state == "ready" {
                            // Clear stale chunk rows (they reference deleted Telegram
                            // messages) so the upload re-chunks from scratch.
                            try? await DatabaseManager.shared.deleteChunks(forObjectID: obj.id)
                        }
                        do {
                            try await UploadEngine.upload(fileURL: cached, progress: { _, _ in }, resumeObject: obj)
                            log("UPLOADED \(obj.id) \(obj.name)")
                        } catch {
                            log("FAILED \(obj.id) \(obj.name): \(error.localizedDescription)")
                        }
                    }
                    log("=== recovery run done ===")
                    NSApp.terminate(nil)
                }

                // Hidden debug hook: `--stream-server` starts the local byte-range
                // server at launch (it's normally lazy, started on first playback)
                // and keeps the app running, so the streaming pipeline can be tested
                // with curl / the mpv harness without touching the UI.
                if CommandLine.arguments.contains("--stream-server") {
                    await VaultStreamServer.shared.startServer()
                }

                // Hidden debug hook: `--chunk-info <objectID>` prints each chunk's
                // DB-recorded size vs Telegram's actual document size, then quits.
                if let idx = CommandLine.arguments.firstIndex(of: "--chunk-info"),
                   CommandLine.arguments.indices.contains(idx + 1) {
                    await TelegramClient.shared.debugChunkInfo(objectID: CommandLine.arguments[idx + 1])
                    NSApp.terminate(nil)
                }

                // Hidden debug hook: `--dump-channel` writes the full channel message
                // list (id, kind, caption, file name) to /tmp/xcloud-channel.txt, so
                // the real channel state can be compared against the local catalog.
                if CommandLine.arguments.contains("--dump-channel") {
                    await VaultRepair.dumpChannelToFile()
                    NSApp.terminate(nil)
                }

                // Hidden debug hook: `--dump-chat <chatID>` writes any chat's message
                // list (id, kind, caption) to /tmp/xcloud-chat-<id>.txt, then quits —
                // used to inspect share channels directly.
                if let idx = CommandLine.arguments.firstIndex(of: "--dump-chat"),
                   CommandLine.arguments.indices.contains(idx + 1),
                   let chatID = Int64(CommandLine.arguments[idx + 1]) {
                    try? await TelegramClient.shared.debugDumpChat(chatId: chatID)
                    NSApp.terminate(nil)
                }

                // Hidden debug hook: `--import-share <link>` runs the full recipient
                // import path (join, read, forward, catalog) against a share link,
                // then quits — lets the flow be tested without URL routing. Writes
                // the result to a file (stdout is lost on _exit).
                if let idx = CommandLine.arguments.firstIndex(of: "--import-share"),
                   CommandLine.arguments.indices.contains(idx + 1) {
                    let result: String
                    do {
                        try await ShareEngine.importLink(CommandLine.arguments[idx + 1])
                        result = "SUCCESS"
                    } catch {
                        result = "FAILED: \(error.localizedDescription)"
                    }
                    try? result.write(toFile: "/tmp/xcloud-import-result.txt", atomically: true, encoding: .utf8)
                    NSApp.terminate(nil)
                }

                // Hidden debug hook: `--create-share <objectID>` runs the full sender
                // share path (forward chunks into the reusable channel) and writes
                // the minted link to /tmp/xcloud-share-link.txt, then quits — lets
                // the forward/serve side be tested headlessly.
                if let idx = CommandLine.arguments.firstIndex(of: "--create-share"),
                   CommandLine.arguments.indices.contains(idx + 1) {
                    let objectID = CommandLine.arguments[idx + 1]
                    let result: String
                    do {
                        if let object = try await DatabaseManager.shared.object(objectID) {
                            result = try await ShareEngine.share(object: object)
                        } else {
                            result = "FAILED: no object \(objectID)"
                        }
                    } catch {
                        result = "FAILED: \(ShareEngine.describe(error))"
                    }
                    try? result.write(toFile: "/tmp/xcloud-share-link.txt", atomically: true, encoding: .utf8)
                    NSApp.terminate(nil)
                }

                // Hidden debug hook: `--delete-messages <chatID> <comma,ids>` deletes
                // the given messages from a chat (vault cleanup / test data removal)
                // and writes the count to /tmp/xcloud-deleted.txt, then quits.
                if let idx = CommandLine.arguments.firstIndex(of: "--delete-messages"),
                   CommandLine.arguments.indices.contains(idx + 2),
                   let chatID = Int64(CommandLine.arguments[idx + 1]) {
                    let ids = CommandLine.arguments[idx + 2]
                        .split(separator: ",")
                        .compactMap { Int64($0) }
                    var deleted = 0
                    if !ids.isEmpty {
                        try? await TelegramClient.shared.deleteMessages(chatId: chatID, messageIds: ids)
                        deleted = ids.count
                    }
                    try? "deleted \(deleted) message(s)".write(
                        toFile: "/tmp/xcloud-deleted.txt", atomically: true, encoding: .utf8
                    )
                    NSApp.terminate(nil)
                }

                // Hidden debug hook: `--purge-legacy-folders` permanently removes
                // legacy (old-format "xcloud:v1:" text metadata) folder records that
                // exist only in the channel, not in the local catalog: deletes those
                // messages, deletes the matching local records, publishes a fresh
                // checkpoint (base = newest channel message) so old deltas can never
                // resurrect them, writes a summary to /tmp/xcloud-purge.txt, then quits.
                if CommandLine.arguments.contains("--purge-legacy-folders") {
                    var summary = ""
                    if let vault = try? await DatabaseManager.shared.firstVault() {
                        let (legacyMessageIDs, legacyObjectIDs) =
                            await VaultRepair.legacyFolderPurgeCandidates(chatId: vault.channelID)
                        if !legacyMessageIDs.isEmpty {
                            try? await TelegramClient.shared.deleteMessages(
                                chatId: vault.channelID, messageIds: legacyMessageIDs
                            )
                            summary += "deleted \(legacyMessageIDs.count) legacy folder message(s)\n"
                        }
                        if !legacyObjectIDs.isEmpty {
                            for id in legacyObjectIDs {
                                try? await DatabaseManager.shared.deleteObjectWithChunks(id: id)
                            }
                            summary += "deleted \(legacyObjectIDs.count) local folder record(s)\n"
                        }
                        if !legacyMessageIDs.isEmpty || !legacyObjectIDs.isEmpty {
                            if await CatalogSnapshot.publishCheckpointFromLocal() != nil {
                                summary += "published fresh checkpoint (base = newest)\n"
                            } else {
                                summary += "checkpoint publish skipped or failed\n"
                            }
                        }
                    }
                    try? summary.isEmpty
                        ? "nothing to purge".write(toFile: "/tmp/xcloud-purge.txt", atomically: true, encoding: .utf8)
                        : summary.write(toFile: "/tmp/xcloud-purge.txt", atomically: true, encoding: .utf8)
                    NSApp.terminate(nil)
                }

                // Hidden debug hook: `--revoke-shares` deletes every outgoing share
                // channel (revoking their links) so stale test channels can be
                // cleaned up, writes the count to /tmp/xcloud-revoke.txt, then quits.
                if CommandLine.arguments.contains("--revoke-shares") {
                    let shares = (try? await DatabaseManager.shared.shares(role: "outgoing")) ?? []
                    var revoked = 0
                    for share in shares where share.state == "active" {
                        try? await TelegramClient.shared.deleteChat(chatId: share.channelID)
                        var updated = share
                        updated.state = "revoked"
                        try? await DatabaseManager.shared.saveShare(updated)
                        revoked += 1
                    }
                    try? "revoked \(revoked) share(s) (of \(shares.count) total)".write(
                        toFile: "/tmp/xcloud-revoke.txt", atomically: true, encoding: .utf8
                    )
                    NSApp.terminate(nil)
                }
            }
        } catch {
            databaseError = error.localizedDescription
        }
    }

    /// Everything that must happen once Telegram authorization completes: adopt/create
    /// the vault channel, scan it to rebuild the file catalog (this is what restores
    /// files on a new device), load the profile, and restore transfer state. Runs from
    /// `bootstrap` at launch and from the login gate the moment the user signs in.
    @MainActor
    func completePostAuthSetup() async {
        guard !hasCompletedPostAuthSetup else { return }
        hasCompletedPostAuthSetup = true
        isInitialLoading = true
        defer { isInitialLoading = false }

        // Fetch the account identity/profile FIRST — the sidebar user card fills
        // in within a second of login instead of waiting for the full channel
        // scan (which can take 10–20s on a fresh account and left the card
        // showing the generic "Telegram Vault / Connected" placeholder).
        identity = try? await TelegramClient.shared.fetchIdentity()
        print("Cascade post-auth: identity=\(identity?.firstName ?? "nil")")
        if let photo = try? await TelegramClient.shared.fetchProfilePhotoData() {
            profilePhotoData = photo
        }

        // Ensure the vault record exists BEFORE the scan so we have a channel to
        // read. On a fresh container this adopts the account's existing vault channel
        // instead of creating an empty new one.
        if let vault = try? await VaultManager.ensureVault() {
            print("Cascade post-auth: vault ready (channel \(vault.channelID))")
            // Keep the channel out of the Telegram chat list (archive + mute) so it
            // is never accidentally opened — runs at every session start, since
            // ensureVault returns early for an existing vault.
            await TelegramClient.shared.archiveVaultChannel(chatId: vault.channelID)
            // Disaster-recovery mirror: every vault-channel message is forwarded
            // into the "Cascade Backup" channel (created on first run).
            if let backupID = await VaultManager.ensureBackupChannel() {
                print("Cascade post-auth: backup channel ready (channel \(backupID))")
                // Drain any forwards queued while the app was closed.
                Task { await BackupDrainer.shared.drain() }
            }
            // Keep the channel tidy: snapshots older than the newest are stale now
            // that upload() replaces the previous snapshot automatically — this
            // cleans up any accumulation from before that behavior existed.
            // ONE shared channel scan for the whole startup sequence: prewarm the
            // session cache here, and pruneOldSnapshots / restore / VaultRepair all
            // reuse it instead of each paging the full channel (3 scans → 1).
            await TelegramClient.shared.prewarmChannelScan(chatId: vault.channelID)
            await CatalogSnapshot.pruneOldSnapshots(chatId: vault.channelID)
            // iCloud-style instant restore: if this device has no catalog yet, fetch
            // the newest `xcloud:dbsnapshot:v1:` document and rebuild the DB from it
            // in one shot — no slow per-message scan. Falls back to the full scan.
            let restored = await CatalogSnapshot.restore()
            if restored {
                print("Cascade post-auth: catalog restored from snapshot")
                await self.loadFiles()
            } else {
                let changed = await VaultRepair.run()
                print("Cascade post-auth: repair scan changed=\(changed), files=\((try? await DatabaseManager.shared.allObjects())?.count ?? -1)")
                if changed {
                    await self.loadFiles()
                    // Publish a corrected checkpoint so a stale snapshot document on
                    // the channel can't resurrect objects that were purged because
                    // their Telegram messages no longer exist. SAFETY (2026-08-15
                    // incident): never publish a catalog that has no real files — a
                    // collapsed/folders-only state must never overwrite the channel's
                    // good checkpoint (that is exactly how the collapse propagated).
                    let fileCount = ((try? await DatabaseManager.shared.allObjects()) ?? [])
                        .filter { !$0.isFolder && !$0.trashed }.count
                    if fileCount > 0, let syncedAt = await CatalogSnapshot.publishCheckpointFromLocal() {
                        self.lastSyncDate = syncedAt
                        self.lastSnapshotSignature = await self.currentCatalogSignature()
                    } else if fileCount == 0 {
                        print("Cascade post-auth: catalog has zero files — refusing to publish checkpoint (collapse guard)")
                    }
                }
            }
        } else {
            print("Cascade post-auth: vault ensure FAILED")
        }

        // Heal the catalog if earlier snapshot merges duplicated chunk records
        // (each chunk index must reference exactly ONE Telegram message — duplicates
        // made downloads assemble files twice the real size). Publish a corrected
        // checkpoint when anything was removed so the channel's state can't
        // resurrect the duplicates on the next reconcile.
        let removedDuplicates = ((try? await DatabaseManager.shared.dedupeChunkRecords()) ?? 0)
            + ((try? await DatabaseManager.shared.dedupeDuplicateObjects()) ?? 0)
        if removedDuplicates > 0 {
            print("Cascade post-auth: removed \(removedDuplicates) duplicate chunk/object record(s)")
            let dedupeFileCount = ((try? await DatabaseManager.shared.allObjects()) ?? [])
                .filter { !$0.isFolder }.count
            if dedupeFileCount > 0, let syncedAt = await CatalogSnapshot.publishCheckpointFromLocal() {
                self.lastSyncDate = syncedAt
                self.lastSnapshotSignature = await self.currentCatalogSignature()
            } else if dedupeFileCount == 0 {
                print("Cascade post-auth: catalog empty after dedupe — refusing checkpoint (collapse guard)")
            }
            await self.loadFiles()
        }

        await cleanupExpiredTransfers()
        await ShareEngine.cleanupExpiredShares()
        await ShareEngine.healChannelPhotos()
        await ShareEngine.ensureTTLOnPrivatePoolChannels()
        await restoreTransferCards()
        await loadShares()
        await resumeInterruptedUploads()
        // Share links delivered while the app was still starting (before the
        // scene / Telegram were ready) are drained now that everything is up.
        drainPendingShareLinks()
        startTransferCleanupLoop()
        await self.loadFiles()

        // Re-surface a share file that was staged (pending import) in an
        // earlier session: the forwarded copy is in the vault channel, and the
        // Import/Cancel decision is still owed.
        if pendingImportID == nil,
           let pending = (try? await DatabaseManager.shared.pendingImports())?.first {
            pendingImportID = pending.id
            pendingImportObject = pending
        }
        await self.loadFiles()

        // Background thumbnail warm-up: guarantee every media file in the cloud
        // gets a preview — including uploads that predate Telegram thumbnail
        // attachment. Quiet thumbnail-only downloads run one at a time, videos
        // last, so the grid placeholders fill in progressively.
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await ThumbnailService.shared.warmUpMissingThumbnails()
        }
        // Media pipeline warm-up: bind the loopback stream server (lazily started
        // on first playback otherwise) and initialize one throwaway mpv core, so
        // the FIRST play after a restart never pays the cold-start cost — dylib
        // load, FFmpeg codec registration, core init, NWListener bind. This is
        // exactly the "first file lags, every later file is instant" symptom.
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            // App volume = system volume: start observing the output device so
            // keyboard keys / Control Center changes reach the player sliders.
            await MainActor.run { SystemVolumeManager.shared.start() }
            await VaultStreamServer.shared.startServer()
            await MPVController.warmUp()
        }
        // Always publish a snapshot after login — even if the channel's snapshot was
        // ever missing or deleted, every launch recreates it from the local catalog
        // (the auto-database-repair guarantee).
        await forcePublishSnapshot()
    }

    @MainActor
    func resumeInterruptedUploads() async {
        let stuck = files.filter { $0.state == "uploading" }
        guard !stuck.isEmpty else { return }
        for object in stuck {
            guard let path = object.sourcePath,
                  FileManager.default.fileExists(atPath: path) else {
                try? await DatabaseManager.shared.updateObject(object.id) { $0.state = "failed" }
                continue
            }
            let chunks = (try? await DatabaseManager.shared.chunks(for: object.id)) ?? []
            let total = max(1, ChunkPlanner.plan(fileSize: object.size).items.count)
            let done = chunks.filter { ($0.messageID ?? 0) > 0 }.count
            let transferID = TransferCenter.shared.begin(
                .upload,
                objectID: object.id,
                name: object.name,
                initialProgress: Double(done) / Double(total),
                statusText: "Queued…",
                state: .active,
                totalWork: Double(total),
                reuseExisting: true
            )
            // Same serial queue as user-initiated uploads — resumed files go one
            // at a time too, so a launch-time pileup can't congest TDLib again.
            uploadQueue.append(PendingUpload(url: URL(fileURLWithPath: path), resumeObject: object, transferID: transferID))
        }
        drainUploadQueue()
        await self.loadFiles()
    }

    @MainActor
    func logout() async {
        try? await TelegramClient.shared.logout()
        identity = nil
        profilePhotoData = nil
        selectedFiles.removeAll()
        theaterFile = nil
        hasCompletedPostAuthSetup = false
        files = []
        await self.loadFiles()
    }

    @MainActor
    func startTelegram(apiID: Int, apiHash: String) async {
        // Test host must never start TDLib: XCTest exits with exit(), tearing down
        // the C++ core while its background receive thread still polls — a segfault
        // on every test run. bootstrap() guards, but TelegramSetupView's auto-start
        // (.task with stored creds) bypasses that; guard the single choke point.
        guard !isRunningUnderXCTest else { return }
        TelegramClient.shared.configure(apiID: apiID, apiHash: apiHash)
        do {
            try await TelegramClient.shared.start()
            try? KeychainStore.saveTelegramCredentials(apiID: apiID, apiHash: apiHash)
            hasTelegramCredentials = true
        } catch {
            databaseError = "Telegram init failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func startUpload(url: URL) {
        let path = url.path(percentEncoded: false)
        let fileName = url.lastPathComponent
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        let chunks = max(1, ChunkPlanner.plan(fileSize: fileSize).items.count)
        let isFirst = uploadQueue.isEmpty && !isDrainingUploadQueue
        let transferID = TransferCenter.shared.begin(
            .upload,
            objectID: UUID().uuidString,
            name: fileName,
            initialProgress: 0,
            statusText: isFirst ? "Starting…" : "Queued…",
            state: .active,
            totalWork: Double(chunks)
        )
        uploadQueue.append(PendingUpload(url: url, resumeObject: nil, transferID: transferID))
        drainUploadQueue()
    }

    @MainActor
    private func drainUploadQueue() {
        guard !isDrainingUploadQueue else { return }
        isDrainingUploadQueue = true
        Task {
            while !uploadQueue.isEmpty {
                let pending = uploadQueue.removeFirst()
                await performUpload(pending)
            }
            isDrainingUploadQueue = false
            isUploading = false
        }
    }

    @MainActor
    private func performUpload(_ pending: PendingUpload) async {
        if let transferID = pending.transferID,
           let item = TransferCenter.shared.items.first(where: { $0.id == transferID }),
           item.state == .paused || item.state == .failed {
            // Upload was cancelled or discarded while waiting in queue
            return
        }
        let url = pending.url
        isUploading = true
        uploadStatus = "Preparing…"
        uploadProgress = 0
        let isPrivate = (selectedDestination == .privateVault || isFolderPrivate(currentFolderID))
        let parent = (selectedDestination == .allFiles || selectedDestination == .privateVault) ? currentFolderID : nil

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
                        progress: { [weak self] status, p in
                            Task { @MainActor in
                                self?.uploadStatus = status
                                self?.uploadProgress = p
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
                        progress: { [weak self] status, p in
                            Task { @MainActor in
                                self?.uploadStatus = status
                                self?.uploadProgress = p
                            }
                        },
                        existingTransferID: pending.transferID
                    )
                }
            } else if all.contains(where: {
                $0.sourcePath == path && !$0.trashed && $0.state == "uploading"
            }) {
                uploadStatus = "Already uploading this file"
                didUpload = false
                if let transferID = pending.transferID {
                    TransferCenter.shared.removeItems(forObjectID: transferID)
                }
            } else {
                try await UploadEngine.upload(
                    fileURL: url,
                    parentID: parent,
                    isPrivate: isPrivate,
                    progress: { [weak self] status, p in
                        Task { @MainActor in
                            self?.uploadStatus = status
                            self?.uploadProgress = p
                        }
                    },
                    existingTransferID: pending.transferID
                )
            }
            if didUpload {
                uploadStatus = "Upload complete ✅"
                await self.loadFiles()
            }
        } catch {
            if let uploadError = error as? UploadError, case .cancelled = uploadError {
                uploadStatus = "Upload paused — resume anytime from Transfers"
            } else {
                uploadStatus = "Upload failed: \(error.localizedDescription)"
            }
            await self.loadFiles()
        }
    }

    /// Settings → "Sync Now": the one-shot repair + publish action. If the local
    /// catalog is empty it first tries the instant snapshot restore; otherwise (or
    /// when no snapshot exists) it falls back to rebuilding from the per-message
    /// channel scan — the auto-database-repair path. Either way it then force-
    /// publishes a fresh snapshot, so the channel always carries the current catalog.
    /// Shows the outcome in an alert so a failed sync is visible, not silent.
    @MainActor
    func syncNow() async {
        guard TelegramClient.shared.isAuthorized else {
            alertMessage = "Not logged in — connect your Telegram account first."
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        guard let vault = try? await VaultManager.ensureVault() else {
            alertMessage = "No vault available to sync."
            return
        }

        let before = ((try? await DatabaseManager.shared.allObjects()) ?? []).count
        // Only an empty local catalog is eligible for instant snapshot restore — a
        // populated device keeps its own data and reconciles via the channel scan.
        let restored: Bool
        if before == 0 {
            restored = await CatalogSnapshot.restore()
        } else {
            restored = false
        }
        if restored {
            await self.loadFiles()
            alertMessage = "Sync complete — catalog restored instantly from the cloud snapshot."
        } else {
            let messages = await TelegramClient.shared.allChannelMessages(chatId: vault.channelID, usingCache: true)
            let v1Captions = messages.filter { ChunkCaption.isChunkCaption(VaultRepair.caption(of: $0) ?? "") }.count
            let changed = await VaultRepair.run()
            let after = ((try? await DatabaseManager.shared.allObjects()) ?? []).count
            await self.loadFiles()
            print("Cascade sync: messages=\(messages.count) v1Captions=\(v1Captions) before=\(before) after=\(after) changed=\(changed)")
            alertMessage = "Sync complete — \(messages.count) messages in the channel (\(v1Captions) with file metadata), \(before) → \(after) files restored."
        }
        await forcePublishSnapshot()
    }

    // MARK: - Resumable transfers

    /// Retention window for paused/interrupted uploads before their chunk messages are cleaned from Telegram.
    static let transferRetention: TimeInterval = 24 * 60 * 60

    /// Re-creates in-memory transfer cards for paused/interrupted uploads that survived an app restart.
    @MainActor
    func restoreTransferCards() async {
        let all = (try? await DatabaseManager.shared.allObjects()) ?? []
        for object in all where (object.state == "paused" || object.state == "failed") && !object.isFolder {
            guard let path = object.sourcePath, FileManager.default.fileExists(atPath: path) else { continue }
            let chunks = (try? await DatabaseManager.shared.chunks(for: object.id)) ?? []
            let total = max(1, ChunkPlanner.plan(fileSize: object.size).items.count)
            let done = chunks.filter { ($0.messageID ?? 0) > 0 }.count
            let stateText = object.state == "paused" ? "Paused" : "Interrupted"
            TransferCenter.shared.begin(
                .upload,
                objectID: object.id,
                name: object.name,
                initialProgress: Double(done) / Double(total),
                statusText: "\(stateText) — \(done)/\(total) chunks uploaded",
                state: .paused,
                reuseExisting: true
            )
        }
    }

    /// Removes abandoned partial uploads (older than the retention window) from Telegram and the local DB.
    @MainActor
    func cleanupExpiredTransfers() async {
        let cutoff = Date().addingTimeInterval(-Self.transferRetention)
        let all = (try? await DatabaseManager.shared.allObjects()) ?? []
        for object in all where (object.state == "paused" || object.state == "failed") && !object.isFolder && object.modifiedAt < cutoff {
            await UploadEngine.cleanupPartialUpload(objectID: object.id)
            TransferCenter.shared.removeItems(forObjectID: object.id)
        }
        // Drop dangling upload cards whose object record is gone (e.g. purged by repair)
        var danglingIDs: [String] = []
        for item in TransferCenter.shared.items where item.direction == .upload {
            if (try? await DatabaseManager.shared.object(item.objectID)) == nil {
                danglingIDs.append(item.objectID)
            }
        }
        for objectID in danglingIDs {
            TransferCenter.shared.removeItems(forObjectID: objectID)
        }
    }

    @MainActor
    func startTransferCleanupLoop() {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6 * 60 * 60 * 1_000_000_000)
                await cleanupExpiredTransfers()
                await ShareEngine.cleanupExpiredShares()
                await loadShares()
            }
        }
    }

    // MARK: - Navigation

    @MainActor
    func openFile(_ file: ObjectRecord) {
        Task {
            isDownloading = true
            downloadStatus = "Fetching from Telegram…"
            downloadProgress = 0
            do {
                // Opening/previewing is NOT a download — no transfer card for it.
                // Only the explicit right-click "Download" action counts.
                let url = try await DownloadEngine.download(object: file, quiet: true) { [weak self] status, p in
                    Task { @MainActor in
                        self?.downloadStatus = status
                        self?.downloadProgress = p
                    }
                }
                downloadStatus = nil
                if !NSWorkspace.shared.open(url) {
                    let ext = (file.name as NSString).pathExtension.lowercased()
                    if ext == "svg" || file.mime.contains("svg") {
                        theaterFile = file
                    } else if let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) {
                        try? await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
                    } else {
                        theaterFile = file
                    }
                }
            } catch {
                print("Cascade open error: \(error)")
                alertMessage = "Open failed: \(error.localizedDescription)"
            }
            isDownloading = false
        }
    }

    @MainActor
    func selectDestination(_ destination: SidebarDestination) {
        selectedDestination = destination
        currentFolderID = nil
        selectedFiles.removeAll()
    }

    @MainActor
    func openFolder(_ folder: ObjectRecord) {
        currentFolderID = folder.id
        selectedFiles.removeAll()
    }

    @MainActor
    func navigateTo(_ id: String?) {
        currentFolderID = id
        selectedFiles.removeAll()
    }

    /// Finder-style "reveal in folder": jumps to the object's enclosing folder
    /// (switching to a destination where it's visible), selects it, and asks the
    /// browser to flash its border highlight. Used by the transfer cards' reveal.
    @MainActor
    func revealObject(_ object: ObjectRecord) {
        selectDestination(object.isPrivate ? .privateVault : .allFiles)
        currentFolderID = object.parentID
        searchText = ""
        selectedFiles = [object.id]
        revealObjectID = object.id
        revealToken &+= 1
    }

    // MARK: - Cloud sharing

    /// Loads share records: incoming (files others shared with me) and outgoing
    /// (links I handed out, for the Shared management page).
    @MainActor
    func loadShares() async {
        incomingShares = ((try? await DatabaseManager.shared.shares(role: "incoming")) ?? [])
            .filter { $0.state != "pending" }   // pending rows await the import decision
        outgoingShares = (try? await DatabaseManager.shared.shares(role: "outgoing")) ?? []
    }

    /// Active outgoing shares (state == "active", not archived), private and
    /// public, newest first — what the Shared page manages.
    @MainActor
    var activeOutgoingShares: [ShareRecord] {
        outgoingShares.filter { $0.state == "active" && !$0.isArchived }
    }

    /// Archived outgoing shares — hidden from the Shared page by default.
    @MainActor
    var archivedOutgoingShares: [ShareRecord] {
        let result = outgoingShares.filter { $0.state == "active" && $0.isArchived }
        return result
    }

    /// Object IDs shown under "Shared": only files I imported through share
    /// links (incoming). Files I've shared OUT live on the sender side in the
    /// share channel and are deliberately NOT shown here — the Shared page is a
    /// history of imports, like the Transfers page.
    var sharedObjectIDs: Set<String> {
        Set(incomingShares.map(\.objectID))
    }

    /// Removes the incoming share record(s) for an object — the file itself
    /// stays in the vault and in All Files; only the Shared page entry goes
    /// away. The shared copy in the share channel is the sender's to manage.
    @MainActor
    func removeFromShared(_ object: ObjectRecord) {
        Task {
            let incoming = (try? await DatabaseManager.shared.shares(role: "incoming")) ?? []
            for share in incoming where share.objectID == object.id {
                try? await DatabaseManager.shared.deleteShare(id: share.id)
            }
            await loadShares()
        }
    }

    /// Sender side: creates ONE share link for the whole selection by forwarding
    /// the files' chunks into the pool channel. A single file produces a normal
    /// link; two or more produce a GROUP share — one link, one expiry, and the
    /// recipient imports them all together. Only someone holding the link can
    /// import the files. `isPublic` mints a never-expiring public link in the
    /// persistent public channel (default: private, expiring, dedicated channel).
    /// `password` optionally protects the link with a client-side derived password key.
    @MainActor
    func promptPasswordShare(_ objects: [ObjectRecord]) {
        let shareable = objects.filter { !$0.isFolder && !$0.isPrivate }
        guard !shareable.isEmpty else {
            alertMessage = ShareEngine.describe(
                objects.contains(where: { $0.isPrivate })
                    ? ShareEngine.ShareError.notShareablePrivate
                    : ShareEngine.ShareError.notShareable
            )
            return
        }
        sharePasswordTargets = shareable
    }

    @MainActor
    func shareFiles(_ objects: [ObjectRecord], isPublic: Bool = false, password: String? = nil) {
        guard !isSharingFile else { return }
        // Folders and private files can't be shared — drop them from the request
        // (the context menu already hides the action for folder-only selections).
        let shareable = objects.filter { !$0.isFolder && !$0.isPrivate }
        guard !shareable.isEmpty else {
            // Name the actual blocker — private files and folders have different
            // remedies (move out of Private Vault vs. share the files inside).
            alertMessage = ShareEngine.describe(
                objects.contains(where: { $0.isPrivate })
                    ? ShareEngine.ShareError.notShareablePrivate
                    : ShareEngine.ShareError.notShareable
            )
            return
        }
        shareResultFileCount = shareable.count
        isSharingFile = true
        Task {
            defer { isSharingFile = false }
            do {
                shareResultLink = try await ShareEngine.share(objects: shareable, isPublic: isPublic, password: password)
                await loadShares()
            } catch {
                // describe() pulls the real reason out of TDLibKit errors instead of
                // the useless "TDLibKit.Error error 1" localizedDescription.
                alertMessage = ShareEngine.describe(error)
            }
        }
    }

    /// Sender side: creates the share link for a single file (single selection,
    /// player). Convenience wrapper over `shareFiles`.
    @MainActor
    func shareFile(_ object: ObjectRecord, isPublic: Bool = false, password: String? = nil) {
        shareFiles([object], isPublic: isPublic, password: password)
    }

    /// Revokes ONE active outgoing share (private: dedicated channel dies;
    /// public: that file's messages are deleted from the public channel).
    @MainActor
    func cancelShare(_ share: ShareRecord) {
        Task {
            await ShareEngine.cancelShare(share)
            await loadShares()
        }
    }

    /// Revokes every active outgoing share — private channels die, public
    /// messages are deleted — after the user confirms in the UI.
    @MainActor
    func cancelAllShares() {
        Task {
            await ShareEngine.cancelAllShares()
            await loadShares()
        }
    }

    /// Archives a share — hides it from the Shared page without revoking it.
    /// The link stays live; the share record and channel messages are untouched.
    @MainActor
    func archiveShare(_ share: ShareRecord) {
        Task {
            try? await DatabaseManager.shared.archiveShare(id: share.id)
            await loadShares()
        }
    }

    /// Unarchives a share — makes it visible on the Shared page again.
    @MainActor
    func unarchiveShare(_ share: ShareRecord) {
        Task {
            try? await DatabaseManager.shared.unarchiveShare(id: share.id)
            await loadShares()
        }
    }

    /// Recipient side: opens a share link — joins the share channel, forwards the
    /// chunks into this user's own vault, catalogs the file, and leaves. When the
    /// sharer opens their own link, the original file is revealed instead (no
    /// duplicate import — Drive/iCloud behavior).
    @MainActor
    func importShareLink(_ raw: String, password: String? = nil) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                switch try await ShareEngine.importLink(trimmed, password: password) {
                case .pending(let objectID):
                    print("Cascade URL: staged for import decision (object \(objectID))")
                    self.passwordUnlockLink = nil
                    pendingImportID = objectID
                    pendingImportObject = try? await DatabaseManager.shared.object(objectID)
                    await self.loadFiles()
                case .imported:
                    print("Cascade URL: imported via link")
                    self.passwordUnlockLink = nil
                    let isGroup = ShareEngine.ShareLink.parse(trimmed)?.isGroup ?? false
                    // An import is a transfer: the card shows in Transfers
                    // (history like uploads/downloads), not on the Shared page —
                    // Shared now manages the links I handed OUT.
                    let before = Set(incomingShares.map(\.objectID))
                    await self.loadShares()
                    let fresh = incomingShares.filter { !before.contains($0.objectID) }
                    let freshObjects = fresh.isEmpty ? nil : ((try? await DatabaseManager.shared.allObjects()) ?? [])
                        .first { $0.id == fresh.first?.objectID }
                    TransferCenter.shared.begin(
                        .inbound,
                        objectID: fresh.first?.objectID ?? "",
                        name: isGroup
                            ? "\(fresh.count) files"
                            : (freshObjects?.name ?? "Shared file"),
                        statusText: "Imported",
                        state: .complete
                    )
                    alertMessage = isGroup
                        ? "Shared files imported — find them in Transfers."
                        : "Shared file imported — find it in Transfers."
                    await self.loadFiles()
                case .selfOpen(let objectID):
                    print("Cascade URL: self-open, revealing object \(objectID)")
                    self.passwordUnlockLink = nil
                    // Quiet, Drive-style behavior: reveal + select the original.
                    // No modal alert — the reveal highlight IS the feedback.
                    // A trashed original is revealed inside the Trash itself.
                    await self.loadFiles()
                    if let object = self.files.first(where: { $0.id == objectID }) {
                        if object.trashed {
                            selectDestination(.trash)
                            currentFolderID = nil
                            searchText = ""
                            selectedFiles = [object.id]
                            revealObjectID = object.id
                            revealToken &+= 1
                        } else {
                            revealObject(object)
                        }
                    }
                case .alreadyImported(let objectID):
                    print("Cascade URL: already imported, revealing object \(objectID)")
                    self.passwordUnlockLink = nil
                    // The same exact file was imported before (content hash match) —
                    // reveal + blink the existing copy instead of a duplicate import.
                    await self.loadFiles()
                    if let object = self.files.first(where: { $0.id == objectID }) {
                        revealObject(object)
                    }
                }
            } catch ShareEngine.ShareError.passwordRequired {
                self.passwordUnlockLink = trimmed
            } catch {
                print("Cascade URL: import failed: \(error)")
                alertMessage = ShareEngine.describe(error)
            }
        }
    }

    /// The user accepted a staged share file: catalog it (unique name, backup
    /// mirror, incoming record) and show it like any import.
    @MainActor
    func confirmPendingImport() {
        guard let pendingImportID else { return }
        Task {
            do {
                let name = try await ShareEngine.confirmImport(objectID: pendingImportID)
                self.pendingImportID = nil
                self.pendingImportObject = nil
                TransferCenter.shared.begin(
                    .inbound,
                    objectID: pendingImportID,
                    name: name,
                    statusText: "Imported",
                    state: .complete
                )
                alertMessage = "Shared file imported — find it in Transfers."
                await self.loadFiles()
                await self.loadShares()
            } catch {
                alertMessage = ShareEngine.describe(error)
            }
        }
    }

    /// The user rejected a staged share file: its forwarded copies are deleted
    /// from the vault channel and the file never appears in the catalog.
    @MainActor
    func discardPendingImport() {
        guard let pendingImportID else { return }
        let id = pendingImportID
        self.pendingImportID = nil
        self.pendingImportObject = nil
        Task {
            await ShareEngine.discardImport(objectID: id)
            await self.loadFiles()
        }
    }

    /// Entry point for `cascade://share…` links opened by the OS (onOpenURL).
    @MainActor
    func handleIncomingURL(_ url: URL) {
        print("Cascade URL: AppState.handleIncomingURL \(url.absoluteString.prefix(80))")
        guard url.scheme == "xcloud" else { return }
        importShareLink(url.absoluteString)
    }

    /// Processes share links queued by the AppDelegate. Each link is handled
    /// exactly once: warm delivery drains immediately (the app is post-auth), and
    /// cold-launch delivery is deferred until `completePostAuthSetup` finishes
    /// (otherwise the import would race Telegram authorization and fail with
    /// "Sign in to Telegram").
    @MainActor
    func drainPendingShareLinks() {
        guard hasCompletedPostAuthSetup else { return }
        let urls = TerminationHandler.pendingOpenURLs
        guard !urls.isEmpty else { return }
        TerminationHandler.pendingOpenURLs = []
        for url in urls {
            handleIncomingURL(url)
        }
    }

    @MainActor
    func navigateBack() {
        if let currentFolderID {
            self.currentFolderID = files.first { $0.id == currentFolderID }?.parentID
            selectedFiles.removeAll()
        }
    }

    // MARK: - Bulk Actions & Selection

    @MainActor
    func selectAll() {
        selectedFiles = Set(visibleFilesInCurrentContext().map(\.id))
    }

    @MainActor
    func clearSelection() {
        selectedFiles.removeAll()
    }

    @MainActor
    func bulkTrash() {
        let ids = selectedFiles
        for id in ids {
            if AudioPlayerEngine.shared.currentTrack?.id == id {
                AudioPlayerEngine.shared.stop()
            }
            if theaterFile?.id == id {
                theaterFile = nil
            }
        }
        Task {
            for id in ids {
                try? await DatabaseManager.shared.updateObject(id) { $0.trashed = true }
                // Rewrite the chunk captions with trashed=true: VaultRepair rebuilds
                // trashed from captions at every launch, so a stale caption would
                // silently restore trashed files on the next launch.
                if let updated = try? await DatabaseManager.shared.object(id) {
                    syncObjectMetadataToTelegram(updated)
                }
            }
            selectedFiles.removeAll()
            await self.loadFiles()
            registerUndo("Move \(ids.count) Items to Trash") {
                for id in ids {
                    try? await DatabaseManager.shared.updateObject(id) { $0.trashed = false }
                    if let updated = try? await DatabaseManager.shared.object(id) {
                        self.syncObjectMetadataToTelegram(updated)
                    }
                }
                await self.loadFiles()
            } redo: {
                for id in ids {
                    try? await DatabaseManager.shared.updateObject(id) { $0.trashed = true }
                    if let updated = try? await DatabaseManager.shared.object(id) {
                        self.syncObjectMetadataToTelegram(updated)
                    }
                }
                await self.loadFiles()
            }
        }
    }

    @MainActor
    func bulkMove(to folderID: String?) {
        let ids = selectedFiles.filter { $0 != folderID }
        Task {
            var oldParents: [String: String?] = [:]
            var oldNames: [String: String] = [:]
            var newNames: [String: String] = [:]
            var reserved: Set<String> = []
            for id in ids {
                let name = files.first(where: { $0.id == id })?.name ?? ""
                oldParents[id] = files.first(where: { $0.id == id })?.parentID
                oldNames[id] = name
                let newName = (try? await DatabaseManager.shared.uniqueObjectName(base: name, parentID: folderID, reserved: reserved)) ?? name
                newNames[id] = newName
                reserved.insert(newName.lowercased())
                try? await DatabaseManager.shared.updateObject(id) {
                    $0.parentID = folderID
                    $0.name = newName
                }
            }
            selectedFiles.removeAll()
            await self.loadFiles()
            registerUndo("Move \(ids.count) Items") {
                for id in ids {
                    try? await DatabaseManager.shared.updateObject(id) {
                        $0.parentID = oldParents[id] ?? nil
                        $0.name = oldNames[id] ?? ""
                    }
                }
                await self.loadFiles()
            } redo: {
                for id in ids {
                    try? await DatabaseManager.shared.updateObject(id) {
                        $0.parentID = folderID
                        $0.name = newNames[id] ?? ""
                    }
                }
                await self.loadFiles()
            }
        }
    }

    @MainActor
    func bulkDeleteForever() {
        let ids = selectedFiles
        selectedFiles.removeAll()
        for id in ids {
            if let file = files.first(where: { $0.id == id }) {
                deleteForever(file)
            }
        }
    }

    @MainActor
    func bulkRestore() {
        let ids = selectedFiles
        selectedFiles.removeAll()
        Task {
            for id in ids {
                try? await DatabaseManager.shared.updateObject(id) { $0.trashed = false }
                // Captions must carry trashed=false again or the next launch's
                // VaultRepair would re-trash the restored files.
                if let updated = try? await DatabaseManager.shared.object(id) {
                    syncObjectMetadataToTelegram(updated)
                }
            }
            await self.loadFiles()
            registerUndo("Restore \(ids.count) Items") {
                for id in ids {
                    try? await DatabaseManager.shared.updateObject(id) { $0.trashed = true }
                    if let updated = try? await DatabaseManager.shared.object(id) {
                        self.syncObjectMetadataToTelegram(updated)
                    }
                }
                await self.loadFiles()
            } redo: {
                for id in ids {
                    try? await DatabaseManager.shared.updateObject(id) { $0.trashed = false }
                    if let updated = try? await DatabaseManager.shared.object(id) {
                        self.syncObjectMetadataToTelegram(updated)
                    }
                }
                await self.loadFiles()
            }
        }
    }

    func visibleFilesInCurrentContext() -> [ObjectRecord] {
        let files = self.files.filter { $0.state == "ready" }
        let base: [ObjectRecord]
        switch selectedDestination {
        case .allFiles:
            base = files.filter { !$0.trashed && !$0.isPrivate && $0.parentID == currentFolderID }
        case .privateVault:
            base = files.filter { !$0.trashed && $0.isPrivate && $0.parentID == currentFolderID }
        case .trash:
            base = files.filter { $0.trashed }
        case .archive:
            base = files.filter { $0.isArchived }
        case .favorites:
            base = files.filter { $0.isFavorite && !$0.trashed && !$0.isPrivate }
        case .photos:
            base = files.filter { !$0.trashed && !$0.isFolder && !$0.isPrivate && $0.isPhoto }
        case .recent:
            base = Array(files.filter { !$0.trashed && !$0.isFolder && !$0.isPrivate }.prefix(20))
        case .video:
            base = files.filter { !$0.trashed && !$0.isFolder && !$0.isPrivate && $0.isVideo }
        case .audio:
            base = files.filter { !$0.trashed && !$0.isFolder && !$0.isPrivate && $0.isAudio }
        case .documents:
            base = files.filter { !$0.trashed && !$0.isFolder && !$0.isPrivate &&
                ($0.mime.contains("pdf") || $0.mime.hasPrefix("text/") ||
                 $0.mime.contains("msword") || $0.mime.contains("officedocument")) }
        case .library:
            base = files.filter { !$0.trashed && $0.isBook }
        case .transfers:
            base = []
        case .shared:
            base = files.filter { sharedObjectIDs.contains($0.id) && !$0.trashed }
        }
        // Archived files are hidden everywhere except the Archive destination.
        if selectedDestination == .archive { return base }
        return base.filter { !$0.isArchived }
    }

    // MARK: - Folder operations

    @MainActor
    func createFolder(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            let vault = try? await DatabaseManager.shared.firstVault()
            let folder = ObjectRecord(
                id: UUID().uuidString,
                vaultID: vault?.id ?? "local",
                name: trimmed,
                size: 0,
                mime: "xcloud/folder",
                state: "ready",
                rootHash: nil,
                wrappedKey: nil,
                createdAt: .now,
                modifiedAt: .now,
                isFavorite: false,
                trashed: false,
                parentID: currentFolderID,
                isFolder: true
            )
            try? await DatabaseManager.shared.save(folder)
            syncObjectMetadataToTelegram(folder)
            await self.loadFiles()
            registerUndo("Create Folder") {
                try? await DatabaseManager.shared.deleteObjectWithChunks(id: folder.id)
                await self.loadFiles()
            } redo: {
                try? await DatabaseManager.shared.save(folder)
                await self.loadFiles()
            }
        }
    }

    @MainActor
    func createPlaylist(named name: String, kind: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            let vault = try? await DatabaseManager.shared.firstVault()
            let folder = ObjectRecord(
                id: UUID().uuidString,
                vaultID: vault?.id ?? "local",
                name: trimmed,
                size: 0,
                mime: kind == "video" ? "xcloud/playlist-video" : (kind == "photo" ? "xcloud/album-photo" : "xcloud/playlist-audio"),
                state: "ready",
                rootHash: nil,
                wrappedKey: nil,
                createdAt: .now,
                modifiedAt: .now,
                isFavorite: false,
                trashed: false,
                parentID: nil,
                isFolder: true
            )
            try? await DatabaseManager.shared.save(folder)
            syncObjectMetadataToTelegram(folder)
            await self.loadFiles()
            registerUndo("Create \(kind == "video" ? "Playlist" : (kind == "photo" ? "Album" : "Playlist"))") {
                try? await DatabaseManager.shared.deleteObjectWithChunks(id: folder.id)
                await self.loadFiles()
            } redo: {
                try? await DatabaseManager.shared.save(folder)
                await self.loadFiles()
            }
        }
    }

    @MainActor
    func addToPlaylist(_ file: ObjectRecord, playlistID: String) {
        Task {
            let oldParent = file.parentID
            let oldName = file.name
            let newName = (try? await DatabaseManager.shared.uniqueObjectName(base: file.name, parentID: playlistID)) ?? file.name
            // Must go through updateObject: a plain save() writes the record with
            // its OLD modifiedAt, the snapshot merge sees a tie with the channel's
            // copy, keeps the remote parentID and the move silently reverts ~4s
            // later (the "photo moves back" bug).
            try? await DatabaseManager.shared.updateObject(file.id) {
                $0.parentID = playlistID
                $0.name = newName
            }
            if let updated = try? await DatabaseManager.shared.object(file.id) {
                syncObjectMetadataToTelegram(updated)
                // Auto cover: the first photo added to an album without a cover
                // becomes its cover, matching the drag-drop path.
                if updated.isPhoto,
                   let album = self.files.first(where: { $0.id == playlistID }),
                   album.isFolder, album.mime == "xcloud/album-photo", album.coverObjectID == nil {
                    try? await DatabaseManager.shared.updateObject(album.id) { $0.coverObjectID = updated.id }
                    if let albumUpdated = try? await DatabaseManager.shared.object(album.id) {
                        syncObjectMetadataToTelegram(albumUpdated)
                    }
                }
            }
            await self.loadFiles()
            registerUndo("Add to Playlist") {
                try? await DatabaseManager.shared.updateObject(file.id) {
                    $0.parentID = oldParent
                    $0.name = oldName
                }
                await self.loadFiles()
            } redo: {
                try? await DatabaseManager.shared.updateObject(file.id) {
                    $0.parentID = playlistID
                    $0.name = newName
                }
                await self.loadFiles()
            }
        }
    }

    @MainActor
    func createPrivateFolder(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            let vault = try? await DatabaseManager.shared.firstVault()
            let folder = ObjectRecord(
                id: UUID().uuidString,
                vaultID: vault?.id ?? "local",
                name: trimmed,
                size: 0,
                mime: "xcloud/private-folder",
                state: "ready",
                rootHash: nil,
                wrappedKey: nil,
                createdAt: .now,
                modifiedAt: .now,
                isFavorite: false,
                trashed: false,
                parentID: currentFolderID,
                isFolder: true,
                isPrivate: true
            )
            try? await DatabaseManager.shared.save(folder)
            syncObjectMetadataToTelegram(folder)
            await self.loadFiles()
            registerUndo("Create Private Folder") {
                try? await DatabaseManager.shared.deleteObjectWithChunks(id: folder.id)
                await self.loadFiles()
            } redo: {
                try? await DatabaseManager.shared.save(folder)
                await self.loadFiles()
            }
        }
    }

    @MainActor
    func moveToFolder(_ file: ObjectRecord, _ folderID: String?) {
        moveObject(id: file.id, to: folderID)
    }

    private func isFolderPrivate(_ folderID: String?) -> Bool {
        guard let folderID else { return false }
        guard let folder = files.first(where: { $0.id == folderID }) else { return false }
        if folder.isPrivate { return true }
        return isFolderPrivate(folder.parentID)
    }

    @MainActor
    func moveObject(id: String, to folderID: String?, overrideName: String? = nil) {
        guard id != folderID else { return }
        if let folderID, isDescendant(folderID, of: id) { return }

        let targetIsPrivate = isFolderPrivate(folderID)

        Task {
            if let obj = files.first(where: { $0.id == id }) {
                let wasPrivate = obj.isPrivate
                let oldParent = obj.parentID
                let oldName = obj.name
                // Finder-style name conflict handling: a moved file never
                // collides with a same-named sibling — it becomes "file 2.mp4"
                // etc. Batch moves pre-compute names (overrideName) so items
                // moving together don't race each other.
                var newName = overrideName ?? obj.name
                if overrideName == nil {
                    newName = (try? await DatabaseManager.shared.uniqueObjectName(base: obj.name, parentID: folderID)) ?? obj.name
                }
                try? await DatabaseManager.shared.updateObject(id) {
                    $0.parentID = folderID
                    $0.name = newName
                    if !targetIsPrivate && wasPrivate {
                        $0.isPrivate = false
                    }
                }

                if let updated = try? await DatabaseManager.shared.object(id) {
                    syncObjectMetadataToTelegram(updated)
                }

                // Moving out of Private is an instant flag flip now — the vault no
                // longer encrypts anything, so no decrypt/re-upload happens.
                await self.loadFiles()

                registerUndo("Move") {
                    try? await DatabaseManager.shared.updateObject(id) {
                        $0.parentID = oldParent
                        $0.isPrivate = wasPrivate
                        $0.name = oldName
                    }
                    await self.loadFiles()
                } redo: {
                    try? await DatabaseManager.shared.updateObject(id) {
                        $0.parentID = folderID
                        if !targetIsPrivate && wasPrivate {
                            $0.isPrivate = false
                        }
                        $0.name = newName
                    }
                    await self.loadFiles()
                }
            }
        }
    }

    /// Moves several objects into a folder/album at once. When the target is an
    /// album with no cover yet, the first moved photo becomes its cover.
    /// Names are pre-computed with a shared reserved set: two same-named files
    /// moved together land as "file.mp4" and "file 2.mp4", not as a race.
    @MainActor
    func moveObjects(ids: [String], to folderID: String?) {
        let target = folderID.flatMap { id in files.first(where: { $0.id == id }) }
        // In-memory sibling names (the catalog as last loaded) + a reserved set
        // shared across the batch: two same-named files moving together land as
        // "file.mp4" and "file 2.mp4" without racing each other's DB writes.
        let siblingNames = Set(files
            .filter { $0.parentID == folderID && !$0.trashed }
            .map { $0.name.lowercased() })
        var reserved: Set<String> = []
        for id in ids {
            let base = files.first(where: { $0.id == id })?.name ?? ""
            let newName = ShareEngine.uniqueName(base, taken: siblingNames.union(reserved))
            reserved.insert(newName.lowercased())
            moveObject(id: id, to: folderID, overrideName: newName)
        }
        guard let album = target, album.isFolder, album.coverObjectID == nil else { return }
        Task {
            if let first = ids.first {
                try? await DatabaseManager.shared.updateObject(album.id) { $0.coverObjectID = first }
                if let updated = try? await DatabaseManager.shared.object(album.id) {
                    syncObjectMetadataToTelegram(updated)
                }
                await self.loadFiles()
            }
        }
    }

    /// Sets (or clears) the cover of an album/playlist folder.
    @MainActor
    func setAlbumCover(_ album: ObjectRecord, photoID: String?) {
        let oldCover = album.coverObjectID
        Task {
            try? await DatabaseManager.shared.updateObject(album.id) { $0.coverObjectID = photoID }
            if let updated = try? await DatabaseManager.shared.object(album.id) {
                syncObjectMetadataToTelegram(updated)
            }
            await self.loadFiles()
            registerUndo(photoID == nil ? "Remove Album Cover" : "Set Album Cover") {
                try? await DatabaseManager.shared.updateObject(album.id) { $0.coverObjectID = oldCover }
                await self.loadFiles()
            } redo: {
                try? await DatabaseManager.shared.updateObject(album.id) { $0.coverObjectID = photoID }
                await self.loadFiles()
            }
        }
    }

    @MainActor
    var localCacheBytes: Int64 {
        var total: Int64 = 0
        let fm = FileManager.default
        if let cacheDir = try? DownloadEngine.cacheDirectory(),
           let urls = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey]) {
            for url in urls {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                total += Int64(size)
            }
        }
        if let thumbDir = try? UploadEngine.thumbnailsDirectory(),
           let urls = try? fm.contentsOfDirectory(at: thumbDir, includingPropertiesForKeys: [.fileSizeKey]) {
            for url in urls {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                total += Int64(size)
            }
        }
        // Upload/download staging files count too — they are real disk usage (and
        // historically a large source of "hidden" space: leftover .bin files).
        if let tmpDir = try? UploadEngine.tempDirectory(),
           let urls = try? fm.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: [.fileSizeKey]) {
            for url in urls {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                total += Int64(size)
            }
        }
        return total
    }

    @MainActor
    func clearLocalCache() {
        Task {
            await ThumbnailService.shared.clearMemoryCache()
            if let cacheDir = try? DownloadEngine.cacheDirectory() {
                try? FileManager.default.removeItem(at: cacheDir)
            }
            if let thumbDir = try? UploadEngine.thumbnailsDirectory() {
                try? FileManager.default.removeItem(at: thumbDir)
            }
            // Clear upload staging files that don't belong to an IN-FLIGHT upload
            // (state uploading/paused). Staging .bin files are named
            // <objectID>-<index>.bin and are recreated on demand, so orphans —
            // from uploads that finished, failed, or were interrupted — are safe
            // to delete regardless of age. (The old ">1h old" heuristic let
            // fresh orphans from a recent batch slip through, which is exactly
            // how "Clear Cache" visibly left gigabytes behind.)
            if let tmpDir = try? UploadEngine.tempDirectory() {
                let activeIDs = Set(files.filter { $0.state == "uploading" || $0.state == "paused" }.map(\.id))
                let entries = (try? FileManager.default.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil)) ?? []
                for url in entries {
                    let stem = (url.lastPathComponent as NSString).deletingPathExtension
                    if let lastDash = stem.lastIndex(of: "-") {
                        let objectID = String(stem[..<lastDash])
                        if !activeIDs.contains(objectID) {
                            try? FileManager.default.removeItem(at: url)
                        }
                    } else {
                        // No <objectID>-<index> shape — a staging leftover of some
                        // other kind; safe to drop with the cache.
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }
            thumbnailVersion += 1
            // Force thumbnails to regenerate on next load
            await self.loadFiles()
        }
    }

    private func isDescendant(_ candidate: String, of ancestor: String) -> Bool {
        var current: String? = candidate
        while let cur = current {
            if cur == ancestor { return true }
            current = files.first { $0.id == cur }?.parentID
        }
        return false
    }

    // MARK: - Undo / Redo (Finder-style)

    private struct UndoEntry {
        let name: String
        let undo: @MainActor () async -> Void
        let redo: @MainActor () async -> Void
    }

    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []
    private(set) var canUndo = false
    private(set) var canRedo = false

    private func registerUndo(
        _ name: String,
        undo: @escaping @MainActor () async -> Void,
        redo: @escaping @MainActor () async -> Void
    ) {
        undoStack.append(UndoEntry(name: name, undo: undo, redo: redo))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        canUndo = true
        canRedo = false
    }

    func undo() {
        guard let entry = undoStack.popLast() else { return }
        redoStack.append(entry)
        canUndo = !undoStack.isEmpty
        canRedo = true
        Task { await entry.undo() }
    }

    func redo() {
        guard let entry = redoStack.popLast() else { return }
        undoStack.append(entry)
        canUndo = true
        canRedo = !redoStack.isEmpty
        Task { await entry.redo() }
    }

    /// Undo for a simple DB-field mutation: captures the before/after state of one
    /// object and rewrites it on undo/redo, then refreshes the browser.
    private func registerFieldUndo<Value>(
        _ name: String,
        objectID: String,
        keyPath: WritableKeyPath<ObjectRecord, Value>,
        oldValue: Value,
        newValue: Value
    ) {
        registerUndo(name) {
            try? await DatabaseManager.shared.updateObject(objectID) { $0[keyPath: keyPath] = oldValue }
            await self.loadFiles()
        } redo: {
            try? await DatabaseManager.shared.updateObject(objectID) { $0[keyPath: keyPath] = newValue }
            await self.loadFiles()
        }
    }

    // MARK: - File operations

    @MainActor
    func syncObjectMetadataToTelegram(_ object: ObjectRecord) {
        Task.detached {
            guard TelegramClient.shared.isAuthorized else { return }
            guard let vault = try? await DatabaseManager.shared.firstVault() else { return }
            let chunks = (try? await DatabaseManager.shared.chunks(for: object.id)) ?? []

            // Unified caption codec: file chunks stay kind "chunk" WITH their
            // per-chunk fields (index, plainHash, chunkSize) so the caption is
            // complete even after renames/favorites/trash — metadata edits rewrite
            // the caption, and a forward-based share of this file later must still
            // be parseable. Folders carry kind "object" metadata instead.
            func fileCaption(index: Int, plainHash: String?) -> String {
                ChunkCaption.encode(ChunkCaption.Meta(
                    kind: ChunkCaption.kindChunk,
                    id: object.id,
                    name: object.name,
                    size: object.size,
                    mime: object.mime,
                    parentID: object.parentID,
                    isPrivate: object.isPrivate,
                    isFolder: object.isFolder,
                    trashed: object.trashed,
                    isFavorite: object.isFavorite,
                    index: index,
                    totalChunks: max(1, chunks.count),
                    wrappedKey: object.wrappedKey?.base64EncodedString() ?? "",
                    chunkSize: object.chunkSize,
                    plainHash: plainHash,
                    rootHash: object.rootHash
                ), kind: ChunkCaption.kindChunk) ?? ""
            }

            if object.isFolder {
                let captionString = ChunkCaption.encode(ChunkCaption.Meta(
                    kind: ChunkCaption.kindObject,
                    id: object.id,
                    name: object.name,
                    size: object.size,
                    mime: object.mime,
                    parentID: object.parentID,
                    isPrivate: object.isPrivate,
                    isFolder: true,
                    trashed: object.trashed,
                    isFavorite: object.isFavorite,
                    index: 0,
                    totalChunks: 1,
                    wrappedKey: ""
                ), kind: ChunkCaption.kindObject) ?? ""
                if let folderChunk = chunks.first, let msgID = folderChunk.messageID {
                    await BackupSync.editAndMirror(chatId: vault.channelID, messageId: msgID, caption: captionString)
                } else {
                    if let msgID = try? await TelegramClient.shared.sendMetadataMessage(chatId: vault.channelID, text: captionString) {
                        BackupSync.enqueue(messageID: msgID, objectID: object.id)
                        let record = ChunkRecord(
                            id: UUID().uuidString,
                            objectID: object.id,
                            index: 0,
                            size: 0,
                            plainHash: nil,
                            cipherHash: nil,
                            state: "uploaded",
                            messageID: msgID,
                            fileUniqueID: nil,
                            channelID: vault.channelID,
                            createdAt: .now
                        )
                        try? await DatabaseManager.shared.save(record)
                    }
                }
            } else {
                for chunk in chunks {
                    if let msgID = chunk.messageID {
                        await BackupSync.editAndMirror(chatId: vault.channelID, messageId: msgID, caption: fileCaption(index: chunk.index, plainHash: chunk.plainHash))
                    }
                }
            }
        }
    }

    @MainActor
    func toggleFavorite(_ file: ObjectRecord) {
        Task {
            let oldValue = file.isFavorite
            try? await DatabaseManager.shared.updateObject(file.id) { $0.isFavorite.toggle() }
            if let updated = try? await DatabaseManager.shared.object(file.id) {
                syncObjectMetadataToTelegram(updated)
            }
            await self.loadFiles()
            registerFieldUndo("Favorite", objectID: file.id, keyPath: \.isFavorite, oldValue: oldValue, newValue: !oldValue)
        }
    }

    @MainActor
    func setTrashed(_ file: ObjectRecord, _ trashed: Bool) {
        Task {
            let all = (try? await DatabaseManager.shared.allObjects()) ?? []
            var ids = [file.id]
            var stack = [file.id]
            while let id = stack.popLast() {
                for child in all where child.parentID == id {
                    ids.append(child.id)
                    stack.append(child.id)
                }
            }
            for id in ids {
                try? await DatabaseManager.shared.updateObject(id) { $0.trashed = trashed }
                if let updated = try? await DatabaseManager.shared.object(id) {
                    syncObjectMetadataToTelegram(updated)
                }
            }
            selectedFiles.subtract(ids)
            if let cur = currentFolderID, ids.contains(cur) { currentFolderID = nil }
            await self.loadFiles()
            registerUndo(trashed ? "Move \(ids.count) Item\(ids.count == 1 ? "" : "s") to Trash" : "Restore") {
                for id in ids {
                    try? await DatabaseManager.shared.updateObject(id) { $0.trashed = !trashed }
                }
                await self.loadFiles()
            } redo: {
                for id in ids {
                    try? await DatabaseManager.shared.updateObject(id) { $0.trashed = trashed }
                }
                await self.loadFiles()
            }
        }
    }

    @MainActor
    func setArchived(_ file: ObjectRecord, _ archived: Bool) {
        Task {
            let all = (try? await DatabaseManager.shared.allObjects()) ?? []
            var ids = [file.id]
            var stack = [file.id]
            while let id = stack.popLast() {
                for child in all where child.parentID == id {
                    ids.append(child.id)
                    stack.append(child.id)
                }
            }
            for id in ids {
                try? await DatabaseManager.shared.updateObject(id) { $0.isArchived = archived }
                if let updated = try? await DatabaseManager.shared.object(id) {
                    syncObjectMetadataToTelegram(updated)
                }
            }
            selectedFiles.subtract(ids)
            if let cur = currentFolderID, ids.contains(cur) { currentFolderID = nil }
            await self.loadFiles()
            registerUndo(archived ? "Archive \(ids.count) Item\(ids.count == 1 ? "" : "s")" : "Unarchive") {
                for id in ids {
                    try? await DatabaseManager.shared.updateObject(id) { $0.isArchived = !archived }
                }
                await self.loadFiles()
            } redo: {
                for id in ids {
                    try? await DatabaseManager.shared.updateObject(id) { $0.isArchived = archived }
                }
                await self.loadFiles()
            }
        }
    }

    @MainActor
    func setInLibrary(_ file: ObjectRecord, _ inLibrary: Bool) {
        Task {
            try? await DatabaseManager.shared.updateObject(file.id) { $0.isInLibrary = inLibrary }
            if let updated = try? await DatabaseManager.shared.object(file.id) {
                syncObjectMetadataToTelegram(updated)
            }
            selectedFiles.subtract([file.id])
            await self.loadFiles()
            registerUndo(inLibrary ? "Add to Library" : "Remove from Library") {
                try? await DatabaseManager.shared.updateObject(file.id) { $0.isInLibrary = !inLibrary }
                await self.loadFiles()
            } redo: {
                try? await DatabaseManager.shared.updateObject(file.id) { $0.isInLibrary = inLibrary }
                await self.loadFiles()
            }
        }
    }

    @MainActor
    func rename(_ file: ObjectRecord, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let oldName = file.name
        Task {
            // Finder behavior: renaming onto a taken sibling name becomes
            // "Name 2.ext" (self excluded — case-only renames stay exact).
            let finalName = (try? await DatabaseManager.shared.uniqueObjectName(base: trimmed, parentID: file.parentID, excluding: file.id)) ?? trimmed
            try? await DatabaseManager.shared.updateObject(file.id) { $0.name = finalName }
            if let updated = try? await DatabaseManager.shared.object(file.id) {
                syncObjectMetadataToTelegram(updated)
            }
            await self.loadFiles()
            registerUndo("Rename") {
                try? await DatabaseManager.shared.updateObject(file.id) { $0.name = oldName }
                await self.loadFiles()
            } redo: {
                try? await DatabaseManager.shared.updateObject(file.id) { $0.name = finalName }
                await self.loadFiles()
            }
        }
    }

    @MainActor
    func emptyTrash() {
        let trashed = files.filter { $0.trashed }
        for file in trashed {
            if AudioPlayerEngine.shared.currentTrack?.id == file.id {
                AudioPlayerEngine.shared.stop()
            }
            if theaterFile?.id == file.id {
                theaterFile = nil
            }
        }
        Task {
            for file in trashed {
                deleteForever(file)
            }
            await VaultRepair.purgeOrphanedMessages()
        }
    }

    @MainActor
    func deleteForever(_ file: ObjectRecord) {
        if AudioPlayerEngine.shared.currentTrack?.id == file.id {
            AudioPlayerEngine.shared.stop()
        }
        if theaterFile?.id == file.id {
            theaterFile = nil
        }
        Task {
            let all = (try? await DatabaseManager.shared.allObjects()) ?? []
            var ids = [file.id]
            var stack = [file.id]
            while let id = stack.popLast() {
                for child in all where child.parentID == id {
                    ids.append(child.id)
                    stack.append(child.id)
                }
            }

            // Share links die with the file: revoke every outgoing share of these
            // objects — delete the share channel (the link's payload) and mark the
            // record revoked so the expiry cleanup doesn't double-handle. The link
            // stops working the moment the file is gone.
            await revokeShares(for: ids)

            if let vault = try? await DatabaseManager.shared.firstVault() {
                var allMsgIDs: [Int64] = []
                for id in ids {
                    let chunks = (try? await DatabaseManager.shared.chunks(for: id)) ?? []
                    allMsgIDs.append(contentsOf: chunks.compactMap(\.messageID))
                }
                // Safety: never delete a channel message that ANOTHER object's chunk
                // still references. A phantom duplicate (VaultRepair fabricating the
                // sender's id from a forwarded share caption) shares the real file's
                // message — deleting it here would break the surviving file.
                let allChunks = (try? await DatabaseManager.shared.allChunks()) ?? []
                let deleteIDs = allMsgIDs.filter { mid in
                    !allChunks.contains { $0.messageID == mid && !ids.contains($0.objectID) }
                }
                // Deletes from the vault channel AND the backup channel's forwarded
                // copies — permanent deletion means gone from both mirrors.
                await BackupSync.deleteFromVaultAndBackup(messageIDs: deleteIDs)
            }

            for id in ids {
                try? await DatabaseManager.shared.markTombstone(id: id)
                if let url = UploadEngine.thumbnailURL(for: id) {
                    try? FileManager.default.removeItem(at: url)
                }
            }

            selectedFiles.subtract(ids)
            if let cur = currentFolderID, ids.contains(cur) { currentFolderID = nil }
            await self.loadFiles()
            await VaultRepair.purgeOrphanedMessages()
            // Publish the post-deletion catalog as a fresh checkpoint (no reconcile,
            // which would merge the deleted records back in from the channel's older
            // checkpoint). Without this, the next refresh's upload() reconciles the
            // channel state — which still lists the deleted object — and the file
            // silently resurrects. Uses force: true because the user intentionally
            // deleted these files — even if the catalog is now empty, that's correct.
            let remainingFiles = ((try? await DatabaseManager.shared.allObjects()) ?? [])
                .filter { !$0.isFolder && $0.tombstoneAt == nil }.count
            print("Cascade deleteForever: publishing checkpoint with \(remainingFiles) remaining file(s)")
            if let syncedAt = await CatalogSnapshot.publishCheckpointFromLocal(force: true) {
                self.lastSyncDate = syncedAt
                self.lastSnapshotSignature = await self.currentCatalogSignature()
            }
        }
    }

    /// Deletes the share channel of every active outgoing share of the given
    /// objects and marks the records revoked — the links stop working immediately
    /// (the channel no longer exists, so importing fails cleanly instead of
    /// silently restoring a deleted file).
    @MainActor
    private func revokeShares(for ids: [String]) async {
        let shares = (try? await DatabaseManager.shared.shares(role: "outgoing")) ?? []
        for share in shares where share.state == "active" && ids.contains(share.objectID) {
            await ShareEngine.cancelShare(share)
        }
        await loadShares()
    }

    @MainActor
    func resetVault(confirmed: Bool = false) async {
        guard confirmed else {
            print("Cascade: resetVault called without confirmation — refusing")
            return
        }
        isResetting = true
        defer { isResetting = false }

        guard let vault = try? await DatabaseManager.shared.firstVault() else { return }

        // A reset kills every share link too: the objects they point at are gone.
        // Private channels die with their shares; the public channel dies too —
        // its forwarded copies reference the wiped vault.
        await ShareEngine.cancelAllShares()
        for state in (try? await DatabaseManager.shared.allShareChannels()) ?? [] {
            try? await TelegramClient.shared.deleteChat(chatId: state.channelID)
            try? await DatabaseManager.shared.deleteShareChannel(id: state.id)
        }

        let ids = await TelegramClient.shared.allChannelMessageIDs(chatId: vault.channelID, usingCache: true)
        await BackupSync.deleteFromVaultAndBackup(messageIDs: ids)
        // The backup mirror is wiped entirely too — a reset means a clean slate.
        await BackupSync.wipeBackupChannel()

        try? await DatabaseManager.shared.clearObjects()

        if let dir = try? UploadEngine.thumbnailsDirectory() {
            try? FileManager.default.removeItem(at: dir)
        }

        selectedFiles.removeAll()
        currentFolderID = nil
        await self.loadFiles()
    }
}
