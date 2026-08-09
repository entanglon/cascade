import Foundation
import Observation
import AppKit

enum SidebarDestination: String, CaseIterable, Identifiable, Hashable {
    case allFiles, privateVault, recent, favorites, video, audio, documents, transfers, trash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allFiles: return "All Files"
        case .privateVault: return "Private Vault"
        case .recent: return "Recent"
        case .favorites: return "Favorites"
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
        case .privateVault: return "asterisk"
        case .recent: return "clock"
        case .favorites: return "star"
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

    @MainActor
    func bootstrap() async {
        do {
            try await DatabaseManager.shared.start()
            try await DatabaseManager.shared.selfTest()
            isDatabaseReady = true
            await loadFiles()

            try await ChunkEngine.selfTest()
            isEngineReady = true

            try await CryptoEngine.selfTest()
            isCryptoReady = true

            if let creds = try KeychainStore.loadTelegramCredentials() {
                await startTelegram(apiID: creds.apiID, apiHash: creds.apiHash)
            }

            for _ in 0..<20 {
                if TelegramClient.shared.isAuthorized { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if TelegramClient.shared.isAuthorized {
                let changed = await VaultRepair.run()
                if changed { await loadFiles() }
                identity = try? await TelegramClient.shared.fetchIdentity()
                if let photo = try? await TelegramClient.shared.fetchProfilePhotoData() {
                    profilePhotoData = photo
                }
                await resumeInterruptedUploads()
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
                await loadFiles()
            }
        }
        await loadFiles()
    }

    @MainActor
    func logout() async {
        try? await TelegramClient.shared.logout()
        identity = nil
        profilePhotoData = nil
        selectedFiles.removeAll()
        theaterFile = nil
        await loadFiles()
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
        let isPrivate = (selectedDestination == .privateVault)
        let parent = (selectedDestination == .allFiles || isPrivate) ? currentFolderID : nil

        Task {
            do {
                try await UploadEngine.upload(fileURL: url, parentID: parent, isPrivate: isPrivate) { [weak self] status, p in
                    Task { @MainActor in
                        self?.uploadStatus = status
                        self?.uploadProgress = p
                    }
                }
                uploadStatus = "Upload complete ✅"
                await loadFiles()
            } catch {
                uploadStatus = "Upload failed: \(error.localizedDescription)"
                await loadFiles()
            }
            isUploading = false
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
                    print("xCloud: NSWorkspace refused to open \(url.path())")
                    alertMessage = "macOS refused to open \(file.name)."
                }
            } catch {
                print("xCloud open error: \(error)")
                alertMessage = "Open failed: \(error.localizedDescription)"
            }
            isDownloading = false
        }
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
                if let file = files.first(where: { $0.id == id }) {
                    try? await DatabaseManager.shared.updateObject(id) { $0.trashed = true }
                }
            }
            selectedFiles.removeAll()
            await loadFiles()
        }
    }

    @MainActor
    func bulkMove(to folderID: String?) {
        let ids = selectedFiles.filter { $0 != folderID }
        Task {
            for id in ids {
                try? await DatabaseManager.shared.updateObject(id) { $0.parentID = folderID }
            }
            selectedFiles.removeAll()
            await loadFiles()
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
            await loadFiles()
        }
    }

    func visibleFilesInCurrentContext() -> [ObjectRecord] {
        switch selectedDestination {
        case .allFiles:
            return files.filter { !$0.trashed && !$0.isPrivate && $0.parentID == currentFolderID }
        case .privateVault:
            return files.filter { !$0.trashed && $0.isPrivate && $0.parentID == currentFolderID }
        case .trash:
            return files.filter { $0.trashed }
        case .favorites:
            return files.filter { $0.isFavorite && !$0.trashed && !$0.isPrivate }
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
            await loadFiles()
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
            await loadFiles()
        }
    }

    @MainActor
    func moveToFolder(_ file: ObjectRecord, _ folderID: String?) {
        Task {
            try? await DatabaseManager.shared.updateObject(file.id) { $0.parentID = folderID }
            await loadFiles()
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
                try? await DatabaseManager.shared.updateObject(id) {
                    $0.parentID = folderID
                    if !targetIsPrivate && wasPrivate {
                        $0.isPrivate = false
                    }
                }

                // If moved out of private vault into a public folder, unencrypt in Telegram
                if wasPrivate && !targetIsPrivate {
                    await unencryptFileInTelegram(id: id)
                }
            }
            await loadFiles()
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
    func clearLocalCache() {
        Task {
            await ThumbnailService.shared.clearMemoryCache()
            if let cacheDir = try? DownloadEngine.cacheDirectory() {
                try? FileManager.default.removeItem(at: cacheDir)
            }
            if let thumbDir = try? UploadEngine.thumbnailsDirectory() {
                try? FileManager.default.removeItem(at: thumbDir)
            }
            // Force thumbnails to regenerate on next load
            await loadFiles()
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

    // MARK: - File operations

    @MainActor
    func toggleFavorite(_ file: ObjectRecord) {
        Task {
            try? await DatabaseManager.shared.updateObject(file.id) { $0.isFavorite.toggle() }
            await loadFiles()
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
            }
            selectedFiles.subtract(ids)
            if let cur = currentFolderID, ids.contains(cur) { currentFolderID = nil }
            await loadFiles()
        }
    }

    @MainActor
    func rename(_ file: ObjectRecord, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            try? await DatabaseManager.shared.updateObject(file.id) { $0.name = trimmed }
            await loadFiles()
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
            await loadFiles()
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
        await loadFiles()
    }
}
