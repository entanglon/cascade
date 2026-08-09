import Foundation
import Observation
import AppKit

enum SidebarDestination: String, CaseIterable, Identifiable, Hashable {
    case allFiles, privateVault, recent, favorites, photos, video, audio, documents, transfers, trash

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
        case .transfers: return "Transfers"
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
        case .transfers: return "arrow.up.arrow.down"
        case .trash: return "trash"
        }
    }
}

@Observable
final class AppState {
    var selectedDestination: SidebarDestination = .allFiles
    var searchText = ""
    var selectedFiles: Set<String> = []
    var isPrivateVaultUnlocked = false
    var thumbnailVersion = 0

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
    var databaseError: String?

    /// True from app launch until the initial catalog load + Telegram reconciliation
    /// finishes. The file browser shows a loading state instead of the misleading
    /// "Nothing Here Yet" empty state while this is set.
    var isInitialLoading = true

    var showSetup = false
    var showLogin = false
    var showOnboarding = !UserDefaults.standard.bool(forKey: "xc.hasOnboarded")
    var showSettings = false

    var uploadStatus: String? = nil
    var uploadProgress: Double = 0
    var isUploading = false
    var isResetting = false

    var isDownloading = false
    var downloadStatus: String? = nil
    var downloadProgress: Double = 0
    var alertMessage: String? = nil
    var theaterFile: ObjectRecord? = nil
    var isTheaterFullScreen: Bool = false
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
            let objects = try await DatabaseManager.shared.allObjects()
            self.files = objects.sorted { lhs, rhs in
                if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
                return lhs.createdAt > rhs.createdAt
            }
        } catch {
            print("Failed to load files: \(error)")
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
            try await DatabaseManager.shared.start()
            try await DatabaseManager.shared.selfTest()
            isDatabaseReady = true
            await self.loadFiles()

            try await ChunkEngine.selfTest()
            isEngineReady = true

            try await CryptoEngine.selfTest()
            isCryptoReady = true

            guard !isRunningUnderXCTest else { return }

            if let creds = try KeychainStore.loadTelegramCredentials() {
                await startTelegram(apiID: creds.apiID, apiHash: creds.apiHash)
            }

            for _ in 0..<20 {
                if TelegramClient.shared.isAuthorized { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if TelegramClient.shared.isAuthorized {
                let changed = await VaultRepair.run()
                if changed { await self.loadFiles() }
                identity = try? await TelegramClient.shared.fetchIdentity()
                if let photo = try? await TelegramClient.shared.fetchProfilePhotoData() {
                    profilePhotoData = photo
                }
                await cleanupExpiredTransfers()
                await restoreTransferCards()
                await resumeInterruptedUploads()
                startTransferCleanupLoop()
            }
        } catch {
            databaseError = error.localizedDescription
        }
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
            Task {
                try? await UploadEngine.upload(
                    fileURL: URL(fileURLWithPath: path),
                    parentID: object.parentID,
                    progress: { _, _ in },
                    resumeObject: object
                )
                await self.loadFiles()
            }
        }
        await self.loadFiles()
    }

    @MainActor
    func logout() async {
        try? await TelegramClient.shared.logout()
        identity = nil
        profilePhotoData = nil
        selectedFiles.removeAll()
        theaterFile = nil
        await self.loadFiles()
    }

    @MainActor
    func startTelegram(apiID: Int, apiHash: String) async {
        TelegramClient.shared.configure(apiID: apiID, apiHash: apiHash)
        do {
            try await TelegramClient.shared.start()
            try? KeychainStore.saveTelegramCredentials(apiID: apiID, apiHash: apiHash)
        } catch {
            databaseError = "Telegram init failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func startUpload(url: URL) {
        isUploading = true
        uploadStatus = "Preparing…"
        uploadProgress = 0
        let isPrivate = (selectedDestination == .privateVault || isFolderPrivate(currentFolderID))
        let parent = (selectedDestination == .allFiles || selectedDestination == .privateVault) ? currentFolderID : nil

        Task {
            do {
                let path = url.path(percentEncoded: false)
                let all = (try? await DatabaseManager.shared.allObjects()) ?? []
                var didUpload = true

                // Uploading the same file again resumes its interrupted upload from the last chunk
                if let existing = all.first(where: {
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
                            resumeObject: existing
                        )
                    } else {
                        // Source file is gone: discard the stale partial, then upload fresh
                        await UploadEngine.cleanupPartialUpload(objectID: existing.id)
                        TransferCenter.shared.removeItems(forObjectID: existing.id)
                        try await UploadEngine.upload(fileURL: url, parentID: parent, isPrivate: isPrivate) { [weak self] status, p in
                            Task { @MainActor in
                                self?.uploadStatus = status
                                self?.uploadProgress = p
                            }
                        }
                    }
                } else if all.contains(where: {
                    $0.sourcePath == path && !$0.trashed && $0.state == "uploading"
                }) {
                    uploadStatus = "Already uploading this file"
                    didUpload = false
                } else {
                    try await UploadEngine.upload(fileURL: url, parentID: parent, isPrivate: isPrivate) { [weak self] status, p in
                        Task { @MainActor in
                            self?.uploadStatus = status
                            self?.uploadProgress = p
                        }
                    }
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
            isUploading = false
        }
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
                let url = try await DownloadEngine.download(object: file) { [weak self] status, p in
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
                print("xCloud open error: \(error)")
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
        Task {
            for id in ids {
                try? await DatabaseManager.shared.updateObject(id) { $0.trashed = true }
            }
            selectedFiles.removeAll()
            await self.loadFiles()
            registerUndo("Move \(ids.count) Items to Trash") {
                for id in ids {
                    try? await DatabaseManager.shared.updateObject(id) { $0.trashed = false }
                }
                await self.loadFiles()
            } redo: {
                for id in ids {
                    try? await DatabaseManager.shared.updateObject(id) { $0.trashed = true }
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
            for id in ids {
                oldParents[id] = files.first(where: { $0.id == id })?.parentID
                try? await DatabaseManager.shared.updateObject(id) { $0.parentID = folderID }
            }
            selectedFiles.removeAll()
            await self.loadFiles()
            registerUndo("Move \(ids.count) Items") {
                for id in ids {
                    try? await DatabaseManager.shared.updateObject(id) { $0.parentID = oldParents[id] ?? nil }
                }
                await self.loadFiles()
            } redo: {
                for id in ids {
                    try? await DatabaseManager.shared.updateObject(id) { $0.parentID = folderID }
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
            }
            await self.loadFiles()
            registerUndo("Restore \(ids.count) Items") {
                for id in ids {
                    try? await DatabaseManager.shared.updateObject(id) { $0.trashed = true }
                }
                await self.loadFiles()
            } redo: {
                for id in ids {
                    try? await DatabaseManager.shared.updateObject(id) { $0.trashed = false }
                }
                await self.loadFiles()
            }
        }
    }

    func visibleFilesInCurrentContext() -> [ObjectRecord] {
        let files = self.files.filter { $0.state == "ready" }
        switch selectedDestination {
        case .allFiles:
            return files.filter { !$0.trashed && !$0.isPrivate && $0.parentID == currentFolderID }
        case .privateVault:
            return files.filter { !$0.trashed && $0.isPrivate && $0.parentID == currentFolderID }
        case .trash:
            return files.filter { $0.trashed }
        case .favorites:
            return files.filter { $0.isFavorite && !$0.trashed && !$0.isPrivate }
        case .photos:
            return files.filter { !$0.trashed && !$0.isFolder && !$0.isPrivate &&
                ($0.mime.hasPrefix("image/") || ["jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp", "svg"].contains(($0.name as NSString).pathExtension.lowercased())) }
        case .recent:
            return Array(files.filter { !$0.trashed && !$0.isFolder && !$0.isPrivate }.prefix(20))
        case .video:
            return files.filter { !$0.trashed && !$0.isFolder && !$0.isPrivate && $0.mime.hasPrefix("video/") }
        case .audio:
            return files.filter { !$0.trashed && !$0.isFolder && !$0.isPrivate && $0.mime.hasPrefix("audio/") }
        case .documents:
            return files.filter { !$0.trashed && !$0.isFolder && !$0.isPrivate &&
                ($0.mime.contains("pdf") || $0.mime.hasPrefix("text/") ||
                 $0.mime.contains("msword") || $0.mime.contains("officedocument")) }
        case .transfers:
            return []
        }
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
            var updated = file
            updated.parentID = playlistID
            try? await DatabaseManager.shared.save(updated)
            syncObjectMetadataToTelegram(updated)
            await self.loadFiles()
            registerUndo("Add to Playlist") {
                try? await DatabaseManager.shared.updateObject(file.id) { $0.parentID = oldParent }
                await self.loadFiles()
            } redo: {
                try? await DatabaseManager.shared.updateObject(file.id) { $0.parentID = playlistID }
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
        Task {
            try? await DatabaseManager.shared.updateObject(file.id) { $0.parentID = folderID }
            await self.loadFiles()
        }
    }

    private func isFolderPrivate(_ folderID: String?) -> Bool {
        guard let folderID else { return false }
        guard let folder = files.first(where: { $0.id == folderID }) else { return false }
        if folder.isPrivate { return true }
        return isFolderPrivate(folder.parentID)
    }

    @MainActor
    func moveObject(id: String, to folderID: String?) {
        guard id != folderID else { return }
        if let folderID, isDescendant(folderID, of: id) { return }

        let targetIsPrivate = isFolderPrivate(folderID)

        Task {
            if let obj = files.first(where: { $0.id == id }) {
                let wasPrivate = obj.isPrivate
                let oldParent = obj.parentID
                try? await DatabaseManager.shared.updateObject(id) {
                    $0.parentID = folderID
                    if !targetIsPrivate && wasPrivate {
                        $0.isPrivate = false
                    }
                }

                if let updated = try? await DatabaseManager.shared.object(id) {
                    syncObjectMetadataToTelegram(updated)
                }

                // If moved out of private vault into a public folder, unencrypt in Telegram
                if wasPrivate && !targetIsPrivate {
                    await unencryptFileInTelegram(id: id)
                }
                await self.loadFiles()

                registerUndo("Move") {
                    try? await DatabaseManager.shared.updateObject(id) {
                        $0.parentID = oldParent
                        $0.isPrivate = wasPrivate
                    }
                    await self.loadFiles()
                } redo: {
                    try? await DatabaseManager.shared.updateObject(id) {
                        $0.parentID = folderID
                        if !targetIsPrivate && wasPrivate {
                            $0.isPrivate = false
                        }
                    }
                    await self.loadFiles()
                }
            }
        }
    }

    private func unencryptFileInTelegram(id: String) async {
        guard let file = files.first(where: { $0.id == id }) else { return }
        if file.isFolder {
            // Unencrypt child objects recursively
            let children = files.filter { $0.parentID == file.id }
            for child in children {
                await unencryptFileInTelegram(id: child.id)
            }
            return
        }

        // Fetch decrypted temp file using DownloadEngine
        guard let decryptedURL = try? await DownloadEngine.download(object: file, progress: { _, _ in }) else { return }
        guard let vault = try? await DatabaseManager.shared.firstVault() else { return }

        let chunks = (try? await DatabaseManager.shared.chunks(for: file.id)) ?? []
        guard let oldChunk = chunks.first, let oldMsgID = oldChunk.messageID else { return }

        // Send unencrypted file to Telegram channel
        let meta: [String: Any] = [
            "id": file.id,
            "name": file.name,
            "size": file.size,
            "mime": file.mime,
            "parentID": file.parentID ?? "",
            "isPrivate": false,
            "index": 0,
            "totalChunks": 1,
            "wrappedKey": ""
        ]

        var captionString: String? = nil
        if let jsonData = try? JSONSerialization.data(withJSONObject: meta),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            captionString = "xcloud:v1:" + jsonStr
        }

        if let messageId = try? await TelegramClient.shared.sendFile(
            chatId: vault.channelID,
            path: decryptedURL.path(percentEncoded: false),
            kind: .document,
            caption: captionString,
            onProgress: nil
        ) {
            // Delete old encrypted Telegram message
            _ = try? await TelegramClient.shared.deleteMessages(chatId: vault.channelID, messageIds: [oldMsgID])

            // Update chunk record with new unencrypted message ID
            try? await DatabaseManager.shared.updateChunk(oldChunk.id) { $0.messageID = messageId }
            try? await DatabaseManager.shared.updateObject(file.id) { $0.isPrivate = false }
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

            let meta: [String: Any] = [
                "id": object.id,
                "name": object.name,
                "size": object.size,
                "mime": object.mime,
                "parentID": object.parentID ?? "",
                "isPrivate": object.isPrivate,
                "isFolder": object.isFolder,
                "trashed": object.trashed,
                "isFavorite": object.isFavorite,
                "totalChunks": max(1, chunks.count),
                "wrappedKey": object.wrappedKey?.base64EncodedString() ?? ""
            ]
            guard let jsonData = try? JSONSerialization.data(withJSONObject: meta),
                  let jsonStr = String(data: jsonData, encoding: .utf8) else { return }
            let captionString = "xcloud:v1:" + jsonStr

            if object.isFolder {
                if let folderChunk = chunks.first, let msgID = folderChunk.messageID {
                    try? await TelegramClient.shared.editMessageCaption(chatId: vault.channelID, messageId: msgID, caption: captionString)
                } else {
                    if let msgID = try? await TelegramClient.shared.sendMetadataMessage(chatId: vault.channelID, text: captionString) {
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
                        try? await TelegramClient.shared.editMessageCaption(chatId: vault.channelID, messageId: msgID, caption: captionString)
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
    func rename(_ file: ObjectRecord, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let oldName = file.name
        Task {
            try? await DatabaseManager.shared.updateObject(file.id) { $0.name = trimmed }
            if let updated = try? await DatabaseManager.shared.object(file.id) {
                syncObjectMetadataToTelegram(updated)
            }
            await self.loadFiles()
            registerUndo("Rename") {
                try? await DatabaseManager.shared.updateObject(file.id) { $0.name = oldName }
                await self.loadFiles()
            } redo: {
                try? await DatabaseManager.shared.updateObject(file.id) { $0.name = trimmed }
                await self.loadFiles()
            }
        }
    }

    @MainActor
    func emptyTrash() {
        let trashed = files.filter { $0.trashed }
        Task {
            for file in trashed {
                deleteForever(file)
            }
            await VaultRepair.purgeOrphanedMessages()
        }
    }

    @MainActor
    func deleteForever(_ file: ObjectRecord) {
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

            if let vault = try? await DatabaseManager.shared.firstVault() {
                for id in ids {
                    let chunks = (try? await DatabaseManager.shared.chunks(for: id)) ?? []
                    let msgIDs = chunks.compactMap(\.messageID)
                    for i in stride(from: 0, to: msgIDs.count, by: 100) {
                        let batch = Array(msgIDs[i..<min(i + 100, msgIDs.count)])
                        try? await TelegramClient.shared.deleteMessages(
                            chatId: vault.channelID, messageIds: batch
                        )
                    }
                }
            }

            for id in ids {
                try? await DatabaseManager.shared.deleteObjectWithChunks(id: id)
                if let url = UploadEngine.thumbnailURL(for: id) {
                    try? FileManager.default.removeItem(at: url)
                }
            }

            selectedFiles.subtract(ids)
            if let cur = currentFolderID, ids.contains(cur) { currentFolderID = nil }
            await self.loadFiles()
            await VaultRepair.purgeOrphanedMessages()
        }
    }

    @MainActor
    func resetVault() async {
        isResetting = true
        defer { isResetting = false }

        guard let vault = try? await DatabaseManager.shared.firstVault() else { return }

        let ids = await TelegramClient.shared.allChannelMessageIDs(chatId: vault.channelID)
        for i in stride(from: 0, to: ids.count, by: 100) {
            let batch = Array(ids[i..<min(i + 100, ids.count)])
            try? await TelegramClient.shared.deleteMessages(
                chatId: vault.channelID, messageIds: batch
            )
        }

        try? await DatabaseManager.shared.clearObjects()

        if let dir = try? UploadEngine.thumbnailsDirectory() {
            try? FileManager.default.removeItem(at: dir)
        }

        selectedFiles.removeAll()
        currentFolderID = nil
        await self.loadFiles()
    }
}
