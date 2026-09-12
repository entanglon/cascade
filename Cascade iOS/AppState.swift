#if os(iOS)
import CryptoKit
import Foundation
import GRDB
import SwiftUI
import TDLibKit

typealias Date = Foundation.Date
typealias Notification = Foundation.Notification

extension Foundation.Notification.Name {
    static let tdlibCacheChanged = Foundation.Notification.Name("tdlibCacheChanged")
}

struct FileItem: Identifiable, Hashable {
    let id: String
    let name: String
    let isFolder: Bool
    let size: Int64
    let mime: String
    let isPrivate: Bool
    let createdAt: Date
    let parentID: String?
    var thumbnailData: Data?
    let isFavorite: Bool
    let isArchived: Bool
    let trashed: Bool
    let isPinned: Bool

    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.id == rhs.id && (lhs.thumbnailData != nil) == (rhs.thumbnailData != nil) && lhs.isFavorite == rhs.isFavorite && lhs.isPinned == rhs.isPinned && lhs.name == rhs.name
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var isVideo: Bool {
        guard !isFolder else { return false }
        if mime.hasPrefix("video/") { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "mkv", "webm", "avi", "ts", "m2ts", "flv", "wmv", "3gp"].contains(ext)
    }

    var isImage: Bool {
        guard !isFolder else { return false }
        if mime.hasPrefix("image/") { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp", "svg"].contains(ext)
    }

    var isAudio: Bool {
        guard !isFolder else { return false }
        if mime.hasPrefix("audio/") { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["mp3", "m4a", "flac", "wav", "aac", "ogg", "wma", "aiff", "opus", "alac"].contains(ext)
    }

    var isDocument: Bool {
        guard !isFolder else { return false }
        if mime.hasPrefix("application/pdf") || mime.hasPrefix("text/") { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["pdf", "txt", "md", "doc", "docx", "pages", "xls", "xlsx", "numbers", "ppt", "pptx", "key", "rtf", "csv", "json"].contains(ext)
    }

    private static let shortDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "dd/MM/yy"
        return df
    }()

    var formattedDate: String {
        Self.shortDateFormatter.string(from: createdAt)
    }

    var systemIcon: String {
        if isFolder { return "folder.fill" }
        if isVideo { return "film" }
        if isAudio { return "music.note" }
        if isImage { return "photo" }
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "pdf" { return "doc.text.fill" }
        if ["zip", "rar", "7z", "tar", "gz"].contains(ext) { return "archivebox" }
        return "doc"
    }

    var iconColor: Color {
        if isFolder { return .blue }
        if isVideo { return .purple }
        if isImage { return .green }
        if isAudio { return .orange }
        return .gray
    }

    var formattedSize: String? {
        guard size > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    init(record: ObjectRecord, thumbnailData: Data? = nil) {
        self.id = record.id
        self.name = record.name
        self.isFolder = record.isFolder
        self.size = record.size
        self.mime = record.mime
        self.thumbnailData = thumbnailData
        self.isPrivate = record.isPrivate
        self.createdAt = record.createdAt
        self.parentID = record.parentID
        self.isFavorite = record.isFavorite
        self.isArchived = record.isArchived
        self.trashed = record.trashed
        self.isPinned = record.isPinned
    }
}

@Observable
final class AppState {
    var currentFolderID: String = ""
    var currentFolderName: String = "My Files"
    var folderStack: [(id: String, name: String)] = []
    var files: [FileItem] = []
    var allFiles: [FileItem] = []
    var isLoadingFiles = false
    var isInitialLoading = true
    var currentNotification: String?
    var isUploading = false
    var uploadStatus = ""
    var uploadProgress: Double = 0
    var isAuthorized = false
    var isAuthResolved = false
    var isVaultConnected = false
    var databaseError: String?
    var identity: TelegramClient.AccountIdentity?
    var profilePhotoData: Data?
    var theaterFile: FileItem?
    var presentedFile: FileItem?
    var thumbnailVersion: Int = 0
    var isVaultLocked: Bool = false
    var showVaultUnlockSheet: Bool = false
    var hasRecoveryBlob: Bool = false
    var currentAudioTrack: FileItem?
    var isAudioPlaying: Bool = false
    var audioCurrentTime: Double = 0
    var audioDuration: Double = 0
    var showFullAudioPlayer: Bool = false
    var recentFileIDs: [String] = RecentsSyncEngine.loadLocalEntries().map(\.id)
    var editingFileID: String? = nil
    var isCreatingFolder: Bool = false
    var creatingFolderParentID: String? = nil

    // Share & Move Presentation State
    var outgoingShares: [ShareRecord] = []
    var incomingShares: [ShareRecord] = []
    var shareSheetTargetFile: FileItem? = nil
    var moveSheetFileIDs: Set<String>? = nil
    var shareActivityItems: [Any]? = nil
    var showImportShareSheet: Bool = false
    var isImportingShareLink: Bool = false
    var pendingPasswordLink: String? = nil

    // Document Scanner State
    var showDocumentScanner: Bool = false
    var scannerTargetFolderID: String? = nil

    func startDocumentScan(in folderID: String? = nil) {
        self.scannerTargetFolderID = folderID
        self.showDocumentScanner = true
    }

    var activeOutgoingShares: [ShareRecord] {
        outgoingShares.filter { $0.state == "active" && !$0.isArchived }
    }

    var archivedOutgoingShares: [ShareRecord] {
        outgoingShares.filter { $0.state == "active" && $0.isArchived }
    }

    var hasTelegramCredentials: Bool {
        (try? KeychainStore.loadTelegramCredentials()) != nil
    }

    // MARK: - Category Item Counts & Storage
    var driveFilesCount: Int {
        allFiles.filter { !$0.trashed && !$0.isPrivate && $0.parentID == nil }.count
    }
    var vaultFilesCount: Int {
        allFiles.filter { $0.isPrivate && !$0.trashed }.count
    }
    var trashFilesCount: Int {
        allFiles.filter { $0.trashed }.count
    }
    var archiveFilesCount: Int {
        allFiles.filter { $0.isArchived && !$0.trashed }.count
    }
    var favoritesFilesCount: Int {
        allFiles.filter { $0.isFavorite && !$0.trashed && !$0.isArchived }.count
    }
    var photosCount: Int {
        allFiles.filter { $0.isImage && !$0.trashed && !$0.isArchived }.count
    }
    var videosCount: Int {
        allFiles.filter { $0.isVideo && !$0.trashed && !$0.isArchived }.count
    }
    var audioCount: Int {
        allFiles.filter { $0.isAudio && !$0.trashed && !$0.isArchived }.count
    }
    var documentsCount: Int {
        allFiles.filter { $0.isDocument && !$0.trashed && !$0.isArchived }.count
    }
    var totalStorageBytes: Int64 {
        allFiles.filter { !$0.trashed }.reduce(into: Int64(0)) { $0 += $1.size }
    }

    func bootstrap() async {
        isInitialLoading = true
        defer { isInitialLoading = false }
        do {
            try await DatabaseManager.shared.start()
        } catch {
            databaseError = "Database failed: \(error.localizedDescription)"
            return
        }

        guard let creds = try? KeychainStore.loadTelegramCredentials() else {
            isAuthResolved = true
            isAuthorized = false
            return
        }

        TelegramClient.shared.configure(apiID: creds.apiID, apiHash: creds.apiHash)
        do {
            try await TelegramClient.shared.start()
        } catch {
            databaseError = "Telegram failed: \(error.localizedDescription)"
            isAuthResolved = true
            return
        }

        for _ in 0..<60 {
            if TelegramClient.shared.isAuthResolved { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        isAuthorized = TelegramClient.shared.isAuthorized
        isAuthResolved = TelegramClient.shared.isAuthResolved

        if isAuthorized {
            await completePostAuthSetup()
        }
    }

    func completePostAuthSetup() async {
        identity = try? await TelegramClient.shared.fetchIdentity()
        profilePhotoData = try? await TelegramClient.shared.fetchProfilePhotoData()

        guard let vault = try? await VaultManager.ensureVault() else {
            databaseError = "Vault not found. Set up Cascade on another device first."
            isVaultConnected = false
            return
        }

        isVaultConnected = true
        await TelegramClient.shared.archiveVaultChannel(chatId: vault.channelID)
        _ = await VaultManager.ensureBackupChannel()

        // Start the byte-range streaming server for video/audio playback
        await VaultStreamServer.shared.startServer()

        // Prewarm populates the scan cache used by restore/repair
        _ = await TelegramClient.shared.prewarmChannelScan(chatId: vault.channelID)
        await CatalogSnapshot.pruneOldSnapshots(chatId: vault.channelID)

        // Check if vault recovery is needed on this device
        hasRecoveryBlob = await VaultManager.hasRecoveryBlob()
        let hasLocalPIN = KeychainStore.loadVaultPINHash() != nil
        if !hasLocalPIN && hasRecoveryBlob {
            isVaultLocked = true
            // Note: Vault PIN is ONLY for Private Vault files. Open files do not require any PIN.
        } else if hasLocalPIN {
            await VaultManager.autoRecoverWithDeviceSeal()
        }

        // iCloud-style instant restore: if this device has no catalog yet, fetch
        // the newest cascade:dbsnapshot:v1: document.
        let restored = await CatalogSnapshot.restore()

        // After restore (or if already had catalog), check for phantom File- names
        // which indicate a bad prior repair cycle — force a fresh re-restore to heal.
        let postRestoreObjects = (try? await DatabaseManager.shared.allObjects()) ?? []
        let hasPhantoms = postRestoreObjects.contains(where: { $0.name.hasPrefix("File-") })

        if hasPhantoms {
            print("[iOS] Detected File- phantom names after restore — forcing catalog re-restore")
            let reRestored = await CatalogSnapshot.restore(force: true)
            if !reRestored {
                print("[iOS] Re-restore failed — falling back to VaultRepair heal")
                _ = await VaultRepair.run()
            }
            _ = await CatalogSnapshot.upload()
        } else if !restored {
            let objects = postRestoreObjects
            if objects.isEmpty {
                print("[iOS] Empty catalog — running VaultRepair heal")
                _ = await VaultRepair.run()
                _ = await CatalogSnapshot.upload()
            }
        }

        await loadAllFiles()

        // Listen for thumbnail-ready notifications to incrementally update the UI
        observeThumbnailNotifications()
    }

    private func observeThumbnailNotifications() {
        NotificationCenter.default.addObserver(
            forName: .xcThumbnailReady,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.thumbnailVersion += 1
        }
    }

    func unlockVault(pin: String) async -> Bool {
        if KeychainStore.loadVaultPINHash() != nil {
            guard KeychainStore.pinAttemptAllowed() else { return false }
            let ok = KeychainStore.verifyVaultPIN(pin)
            KeychainStore.registerPINResult(success: ok)
            if ok {
                Task { await VaultManager.ensureRecoveryBlob(pin: pin) }
                isVaultLocked = false
                showVaultUnlockSheet = false
                await loadAllFiles()
                Task { await loadThumbnails() }
                return true
            } else {
                return false
            }
        } else if hasRecoveryBlob {
            let recovered = await VaultManager.attemptRecovery(pin: pin)
            if recovered {
                KeychainStore.saveVaultPIN(pin)
                KeychainStore.registerPINResult(success: true)
                isVaultLocked = false
                showVaultUnlockSheet = false
                await loadAllFiles()
                Task { await loadThumbnails() }
                return true
            } else {
                return false
            }
        } else {
            // Setting a new PIN
            KeychainStore.saveVaultPIN(pin)
            Task { await VaultManager.ensureRecoveryBlob(pin: pin) }
            isVaultLocked = false
            showVaultUnlockSheet = false
            return true
        }
    }

    func unlockWithBiometrics() async -> Bool {
        guard KeychainStore.loadVaultPINHash() != nil else { return false }
        guard BiometricUnlock.isAvailable() else { return false }
        guard KeychainStore.pinAttemptAllowed() else { return false }

        let success = await BiometricUnlock.authenticate(reason: "Unlock your Cascade Vault")
        if success {
            KeychainStore.registerPINResult(success: true)
            isVaultLocked = false
            showVaultUnlockSheet = false
            await loadAllFiles()
            Task { await loadThumbnails() }
            return true
        }
        return false
    }

    /// Fetches the thumbnail for a single file on demand (called by per-cell .task).
    /// Returns the thumbnail Data if successfully loaded from disk or Telegram.
    func fetchSingleThumbnail(for fileID: String) async -> Data? {
        // 1. Check disk cache first
        if let diskURL = UploadEngine.thumbnailURL(for: fileID),
           let data = try? Data(contentsOf: diskURL), !data.isEmpty {
            return data
        }

        // 2. Fetch from Telegram
        guard let vault = try? await DatabaseManager.shared.firstVault(),
              let object = try? await DatabaseManager.shared.object(fileID) else {
            return nil
        }
        let fileItem = FileItem(record: object)
        let data = await fetchThumbnailData(for: fileItem, vault: vault)
        if data != nil {
            NotificationCenter.default.post(name: .xcThumbnailReady, object: nil)
        }
        return data
    }

    func loadAllFiles(reconcileCloud: Bool = true) async {
        isLoadingFiles = true
        defer { isLoadingFiles = false }
        do {
            if reconcileCloud && TelegramClient.shared.isAuthorized,
               let vault = try? await DatabaseManager.shared.firstVault() {
                _ = await CatalogSnapshot.upload()
            }

            let objects = try await DatabaseManager.shared.allObjects()
                .filter { $0.tombstoneAt == nil }
            self.allFiles = objects.map { FileItem(record: $0) }
            self.files = currentFiles
            print("[iOS] loadAllFiles: loaded \(allFiles.count) files (\(files.count) in current folder)")

            // If vault is connected but catalog is empty, retry repair
            if allFiles.isEmpty && isVaultConnected {
                print("[iOS] Catalog empty after restore — running VaultRepair")
                _ = await VaultRepair.run()
                let retryObjects = try await DatabaseManager.shared.allObjects()
                    .filter { $0.tombstoneAt == nil }
                self.allFiles = retryObjects.map { FileItem(record: $0) }
                self.files = currentFiles
                print("[iOS] After retry: \(allFiles.count) files")
            }

            // 1. Fast pass: load from local disk cache immediately on main thread
            loadThumbnailsFromDisk()

            // 2. Fetch missing thumbnails asynchronously in background so pull-to-refresh returns immediately
            Task.detached(priority: .utility) { [weak self] in
                await self?.loadMissingThumbnailsFromNetwork()
            }
        } catch {
            print("[iOS] loadAllFiles failed: \(error)")
        }
    }

    func loadThumbnails() async {
        loadThumbnailsFromDisk()
        await loadMissingThumbnailsFromNetwork()
    }

    private func loadThumbnailsFromDisk() {
        var diskUpdated = false
        for i in 0..<allFiles.count {
            let file = allFiles[i]
            guard file.thumbnailData == nil, !file.isFolder else { continue }
            if let diskURL = UploadEngine.thumbnailURL(for: file.id),
               let data = try? Data(contentsOf: diskURL), !data.isEmpty {
                allFiles[i].thumbnailData = data
                diskUpdated = true
            }
        }
        if diskUpdated {
            files = currentFiles
            thumbnailVersion += 1
        }
    }

    func loadMissingThumbnailsFromNetwork() async {
        guard let vault = try? await DatabaseManager.shared.firstVault() else { return }
        let missingFiles = allFiles.filter { $0.thumbnailData == nil && !$0.isFolder }
        guard !missingFiles.isEmpty else { return }

        await withTaskGroup(of: (String, Data?).self) { group in
            var iterator = missingFiles.makeIterator()
            let maxConcurrent = 3

            for _ in 0..<maxConcurrent {
                if let next = iterator.next() {
                    group.addTask {
                        let data = await self.fetchThumbnailData(for: next, vault: vault)
                        return (next.id, data)
                    }
                }
            }

            while let (fileID, data) = await group.next() {
                if let data {
                    await MainActor.run {
                        if let idx = self.allFiles.firstIndex(where: { $0.id == fileID }) {
                            self.allFiles[idx].thumbnailData = data
                        }
                        self.files = self.currentFiles
                        self.thumbnailVersion += 1
                    }
                }
                if let next = iterator.next() {
                    group.addTask {
                        let data = await self.fetchThumbnailData(for: next, vault: vault)
                        return (next.id, data)
                    }
                }
            }
        }
    }

    private func fetchThumbnailData(for file: FileItem, vault: VaultRecord) async -> Data? {
        guard let object = try? await DatabaseManager.shared.object(file.id) else {
            return nil
        }

        let sidecarID = object.thumbMessageID

        // Path 1: Encrypted sidecar document (thumbMessageID)
        if let sidecarID,
           let wrappedKey = object.wrappedKey, !wrappedKey.isEmpty,
           let vaultKey = try? VaultManager.vaultKey(for: vault),
           let objectKey = try? CryptoEngine.unwrap(wrappedKey, with: vaultKey) {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("thumb-\(file.id).bin")
            defer { try? FileManager.default.removeItem(at: tmp) }
            do {
                try await TelegramClient.shared.downloadMessageFile(messageId: sidecarID, chatId: vault.channelID, to: tmp)
                let encrypted = try Data(contentsOf: tmp)
                let plain = try CryptoEngine.decryptChunk(encrypted, objectKey: objectKey, startSliceIndex: 0)
                if !plain.isEmpty {
                    if let thumbDir = try? UploadEngine.thumbnailsDirectory() {
                        // The sidecar isn't format-constrained (unlike the attached
                        // inputThumbnail below, which TDLib requires to be JPEG) —
                        // alpha-bearing sources are uploaded as PNG, so cache under
                        // the extension matching the real bytes (sniffed via the PNG
                        // signature) instead of always assuming JPEG.
                        let isPNG = plain.count >= 4 && plain.prefix(4).elementsEqual([0x89, 0x50, 0x4E, 0x47])
                        let dest = thumbDir.appendingPathComponent(isPNG ? "\(file.id)-tg.png" : "\(file.id)-tg.jpg")
                        try? FileManager.default.removeItem(at: thumbDir.appendingPathComponent(isPNG ? "\(file.id)-tg.jpg" : "\(file.id)-tg.png"))
                        try? plain.write(to: dest)
                    }
                    return plain
                }
            } catch {
                print("[iOS] sidecar fetch failed for \(file.name): \(error.localizedDescription)")
            }
        }

        // Path 2: Attached thumbnail from chunk messages
        let chunks = (try? await DatabaseManager.shared.chunks(for: file.id)) ?? []
        for chunk in chunks {
            guard let messageId = chunk.messageID else { continue }
            if let thumbData = try? await TelegramClient.shared.thumbnailData(
                forMessage: messageId,
                chatId: vault.channelID
            ), !thumbData.isEmpty {
                if let thumbDir = try? UploadEngine.thumbnailsDirectory() {
                    let dest = thumbDir.appendingPathComponent("\(file.id)-tg.jpg")
                    try? thumbData.write(to: dest)
                }
                return thumbData
            }
        }

        return nil
    }

    var currentFiles: [FileItem] {
        allFiles
            .filter { !$0.trashed && !$0.isArchived && ($0.parentID ?? "") == currentFolderID }
            .sorted { lhs, rhs in
                if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
                return lhs.createdAt > rhs.createdAt
            }
    }

    func refreshFiles() {
        files = currentFiles
        Task { await loadAllFiles(reconcileCloud: true) }
    }

    func navigateToFolder(_ file: FileItem) {
        guard file.isFolder else { return }
        folderStack.append((id: currentFolderID, name: currentFolderName))
        currentFolderID = file.id
        currentFolderName = file.name
        files = currentFiles
    }

    func navigateBack() {
        guard let prev = folderStack.popLast() else { return }
        currentFolderID = prev.id
        currentFolderName = prev.name
        files = currentFiles
    }

    var canNavigateBack: Bool {
        !folderStack.isEmpty
    }

    func openTheater(_ file: FileItem) {
        theaterFile = file
    }

    func closeTheater() {
        theaterFile = nil
        presentedFile = nil
    }

    func markFileAsRecent(_ fileID: String) {
        let updated = RecentsSyncEngine.recordAccess(fileID: fileID)
        recentFileIDs = updated.map(\.id)
        RecentsSyncEngine.shared.scheduleUpload()
    }

    func syncRecentsFromCloud() async {
        let merged = await RecentsSyncEngine.shared.syncFromCloud()
        let ids = merged.map(\.id)
        await MainActor.run {
            self.recentFileIDs = ids
        }
    }

    func openFile(_ file: FileItem) {
        markFileAsRecent(file.id)
        if file.isVideo {
            theaterFile = file
        } else if file.isAudio {
            playAudio(file)
        } else {
            presentedFile = file
        }
    }

    func playAudio(_ file: FileItem) {
        currentAudioTrack = file
        isAudioPlaying = true
        showFullAudioPlayer = true

        Task {
            await VaultStreamServer.shared.startServer()
            guard let obj = try? await DatabaseManager.shared.object(file.id),
                  let streamURL = await VideoStreamingEngine.shared.mpvStreamURL(for: obj) else {
                return
            }
            await MainActor.run {
                AudioPlaybackManager.shared.onTimeUpdate = { [weak self] time, duration, playing in
                    self?.audioCurrentTime = time
                    if duration > 0 { self?.audioDuration = duration }
                    self?.isAudioPlaying = playing
                }
                AudioPlaybackManager.shared.onEnded = { [weak self] in
                    self?.isAudioPlaying = false
                }
                AudioPlaybackManager.shared.play(url: streamURL)
            }
        }
    }

    func toggleAudioPlayPause() {
        if isAudioPlaying {
            AudioPlaybackManager.shared.pause()
            isAudioPlaying = false
        } else {
            AudioPlaybackManager.shared.resume()
            isAudioPlaying = true
        }
    }

    func seekAudio(to seconds: Double) {
        AudioPlaybackManager.shared.seek(to: seconds)
        audioCurrentTime = seconds
    }

    func stopAudio() {
        AudioPlaybackManager.shared.stop()
        currentAudioTrack = nil
        isAudioPlaying = false
        showFullAudioPlayer = false
    }

    func trashFile(_ file: FileItem) {
        Task {
            do {
                guard var obj = try await DatabaseManager.shared.object(file.id) else { return }
                obj.trashed = true
                try await DatabaseManager.shared.save(obj)
                await loadAllFiles()
            } catch {
                print("[iOS] trashFile failed: \(error)")
            }
        }
    }

    func startCreatingFolder(in parentID: String? = nil) {
        isCreatingFolder = true
        creatingFolderParentID = parentID
    }

    func cancelCreatingFolder() {
        isCreatingFolder = false
        creatingFolderParentID = nil
    }

    func startInlineRename(for file: FileItem) {
        editingFileID = file.id
    }

    func cancelInlineRename() {
        editingFileID = nil
    }

    func createFolder(named name: String, parentID: String? = nil, isPrivate: Bool = false) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let vault = try? DatabaseManager.shared.firstVault()
        let folder = ObjectRecord(
            id: UUID().uuidString,
            vaultID: vault?.id ?? "local",
            name: trimmed,
            size: 0,
            mime: "cascade/folder",
            state: "ready",
            rootHash: nil,
            wrappedKey: nil,
            createdAt: .now,
            modifiedAt: .now,
            isFavorite: false,
            trashed: false,
            parentID: (parentID?.isEmpty == true) ? nil : parentID,
            isFolder: true,
            isPrivate: isPrivate
        )

        // Optimistic UI update: insert folder into memory immediately so there is no flicker or disappearance
        let newFileItem = FileItem(record: folder)
        self.allFiles.insert(newFileItem, at: 0)
        self.files = currentFiles
        self.isCreatingFolder = false
        self.creatingFolderParentID = nil

        Task {
            do {
                try await DatabaseManager.shared.save(folder)
                _ = await CatalogSnapshot.upload()
                let objects = try await DatabaseManager.shared.allObjects().filter { $0.tombstoneAt == nil }
                await MainActor.run {
                    self.allFiles = objects.map { FileItem(record: $0) }
                    self.files = self.currentFiles
                }
            } catch {
                print("[iOS] createFolder failed: \(error)")
            }
        }
    }

    func uploadBatch(urls: [URL], parentID: String? = nil, isPrivate: Bool = false) async {
        guard !urls.isEmpty else { return }
        await MainActor.run {
            self.isUploading = true
            self.uploadStatus = "Preparing \(urls.count) file\(urls.count == 1 ? "" : "s")..."
            self.uploadProgress = 0
        }

        var completedCount = 0
        let totalCount = urls.count
        let effectiveParentID = (parentID?.isEmpty == true) ? nil : parentID

        for (index, rawURL) in urls.enumerated() {
            let accessing = rawURL.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    rawURL.stopAccessingSecurityScopedResource()
                }
            }

            let filename = rawURL.lastPathComponent
            await MainActor.run {
                self.uploadStatus = "Uploading \(filename) (\(index + 1)/\(totalCount))..."
            }

            let tempDir = (try? UploadEngine.tempDirectory()) ?? FileManager.default.temporaryDirectory
            let workingURL = tempDir.appendingPathComponent("\(UUID().uuidString)_\(filename)")

            do {
                if FileManager.default.fileExists(atPath: workingURL.path) {
                    try? FileManager.default.removeItem(at: workingURL)
                }
                try FileManager.default.copyItem(at: rawURL, to: workingURL)

                try await UploadEngine.upload(
                    fileURL: workingURL,
                    parentID: effectiveParentID,
                    isPrivate: isPrivate
                ) { [weak self] status, fraction in
                    Task { @MainActor in
                        let overallProgress = (Double(completedCount) + fraction) / Double(totalCount)
                        self?.uploadProgress = overallProgress
                        self?.uploadStatus = "\(status) (\(index + 1)/\(totalCount))"
                    }
                }

                try? FileManager.default.removeItem(at: workingURL)
                completedCount += 1

                let objects = try await DatabaseManager.shared.allObjects().filter { $0.tombstoneAt == nil }
                await MainActor.run {
                    self.allFiles = objects.map { FileItem(record: $0) }
                    self.files = self.currentFiles
                    self.thumbnailVersion += 1
                }
            } catch {
                print("[iOS] Upload failed for \(filename): \(error)")
            }
        }

        _ = await CatalogSnapshot.upload()
        await MainActor.run {
            self.isUploading = false
            self.uploadStatus = ""
            self.uploadProgress = 0
            self.thumbnailVersion += 1
        }
    }

    func trashFiles(_ fileIDs: Set<String>) {
        guard !fileIDs.isEmpty else { return }
        Task {
            do {
                for id in fileIDs {
                    if var obj = try await DatabaseManager.shared.object(id) {
                        obj.trashed = true
                        try await DatabaseManager.shared.save(obj)
                    }
                }
                _ = await CatalogSnapshot.upload()
                await loadAllFiles()
            } catch {
                print("[iOS] trashFiles failed: \(error)")
            }
        }
    }

    func restoreFiles(_ fileIDs: Set<String>) {
        guard !fileIDs.isEmpty else { return }
        Task {
            do {
                for id in fileIDs {
                    if var obj = try await DatabaseManager.shared.object(id) {
                        obj.trashed = false
                        try await DatabaseManager.shared.save(obj)
                    }
                }
                _ = await CatalogSnapshot.upload()
                await loadAllFiles()
            } catch {
                print("[iOS] restoreFiles failed: \(error)")
            }
        }
    }

    func deletePermanently(_ fileIDs: Set<String>) {
        guard !fileIDs.isEmpty else { return }
        Task {
            do {
                for id in fileIDs {
                    try await DatabaseManager.shared.deleteObjectWithChunks(id: id)
                }
                _ = await CatalogSnapshot.upload()
                await loadAllFiles()
            } catch {
                print("[iOS] deletePermanently failed: \(error)")
            }
        }
    }

    func toggleFavorites(_ fileIDs: Set<String>) {
        guard !fileIDs.isEmpty else { return }
        Task {
            do {
                let current = allFiles.filter { fileIDs.contains($0.id) }
                let anyUnfavorited = current.contains { !$0.isFavorite }
                for id in fileIDs {
                    if var obj = try await DatabaseManager.shared.object(id) {
                        obj.isFavorite = anyUnfavorited
                        try await DatabaseManager.shared.save(obj)
                    }
                }
                _ = await CatalogSnapshot.upload()
                await loadAllFiles()
            } catch {
                print("[iOS] toggleFavorites failed: \(error)")
            }
        }
    }

    func toggleArchive(_ fileIDs: Set<String>) {
        guard !fileIDs.isEmpty else { return }
        Task {
            do {
                let current = allFiles.filter { fileIDs.contains($0.id) }
                let anyUnarchived = current.contains { !$0.isArchived }
                for id in fileIDs {
                    if var obj = try await DatabaseManager.shared.object(id) {
                        obj.isArchived = anyUnarchived
                        try await DatabaseManager.shared.save(obj)
                    }
                }
                _ = await CatalogSnapshot.upload()
                await loadAllFiles()
            } catch {
                print("[iOS] toggleArchive failed: \(error)")
            }
        }
    }

    func renameFile(_ file: FileItem, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                guard var obj = try await DatabaseManager.shared.object(file.id) else { return }
                obj.name = trimmed
                try await DatabaseManager.shared.save(obj)
                _ = await CatalogSnapshot.upload()
                await loadAllFiles()
            } catch {
                print("[iOS] renameFile failed: \(error)")
            }
        }
    }

    func duplicateFile(_ file: FileItem) {
        Task {
            do {
                guard let original = try await DatabaseManager.shared.object(file.id) else { return }
                let name = original.name
                let baseName: String
                let ext: String
                if original.isFolder {
                    baseName = name
                    ext = ""
                } else if let dotIdx = name.lastIndex(of: ".") {
                    baseName = String(name[..<dotIdx])
                    ext = String(name[dotIdx...])
                } else {
                    baseName = name
                    ext = ""
                }

                let newName = "\(baseName) Copy\(ext)"
                let duplicate = ObjectRecord(
                    id: UUID().uuidString,
                    vaultID: original.vaultID,
                    name: newName,
                    size: original.size,
                    mime: original.mime,
                    state: original.state,
                    rootHash: original.rootHash,
                    wrappedKey: original.wrappedKey,
                    createdAt: .now,
                    modifiedAt: .now,
                    isFavorite: original.isFavorite,
                    trashed: false,
                    parentID: original.parentID,
                    isFolder: original.isFolder,
                    isPrivate: original.isPrivate,
                    isArchived: original.isArchived
                )

                if !original.isFolder {
                    let chunks = try await DatabaseManager.shared.chunks(for: original.id)
                    for chunk in chunks {
                        var newChunk = chunk
                        newChunk.id = UUID().uuidString
                        newChunk.objectID = duplicate.id
                        newChunk.createdAt = .now
                        try await DatabaseManager.shared.save(newChunk)
                    }
                }

                try await DatabaseManager.shared.save(duplicate)
                _ = await CatalogSnapshot.upload()
                await loadAllFiles()
            } catch {
                print("[iOS] duplicateFile failed: \(error)")
            }
        }
    }

    func createFolderWithItem(_ file: FileItem) {
        Task {
            do {
                guard var targetObj = try await DatabaseManager.shared.object(file.id) else { return }
                let vault = try? await DatabaseManager.shared.firstVault()
                let folder = ObjectRecord(
                    id: UUID().uuidString,
                    vaultID: vault?.id ?? "local",
                    name: "New Folder",
                    size: 0,
                    mime: "cascade/folder",
                    state: "ready",
                    rootHash: nil,
                    wrappedKey: nil,
                    createdAt: .now,
                    modifiedAt: .now,
                    isFavorite: false,
                    trashed: false,
                    parentID: targetObj.parentID,
                    isFolder: true,
                    isPrivate: targetObj.isPrivate
                )

                try await DatabaseManager.shared.save(folder)
                targetObj.parentID = folder.id
                try await DatabaseManager.shared.save(targetObj)

                _ = await CatalogSnapshot.upload()
                await loadAllFiles()
            } catch {
                print("[iOS] createFolderWithItem failed: \(error)")
            }
        }
    }

    func moveFiles(_ fileIDs: Set<String>, to destinationParentID: String?) {
        guard !fileIDs.isEmpty else { return }
        let effectiveDest = (destinationParentID?.isEmpty == true) ? nil : destinationParentID
        Task {
            do {
                for id in fileIDs {
                    if id == effectiveDest { continue }
                    if var obj = try await DatabaseManager.shared.object(id) {
                        obj.parentID = effectiveDest
                        try await DatabaseManager.shared.save(obj)
                    }
                }
                _ = await CatalogSnapshot.upload()
                await loadAllFiles()
            } catch {
                print("[iOS] moveFiles failed: \(error)")
            }
        }
    }

    func presentMoveSheet(for fileIDs: Set<String>) {
        moveSheetFileIDs = fileIDs
    }

    func presentShareSheet(for file: FileItem) {
        shareSheetTargetFile = file
    }

    func loadShares() async {
        do {
            let out = (try? await DatabaseManager.shared.shares(role: "outgoing")) ?? []
            let inc = (try? await DatabaseManager.shared.shares(role: "incoming")) ?? []
            await MainActor.run {
                self.outgoingShares = out
                self.incomingShares = inc
            }
        }
    }

    func cancelShare(_ share: ShareRecord) {
        Task {
            await ShareEngine.cancelShare(share)
            await loadShares()
        }
    }

    func shareFile(_ file: FileItem, isPublic: Bool = false, password: String? = nil) async throws -> String {
        guard let obj = try await DatabaseManager.shared.object(file.id) else {
            throw ShareEngine.ShareError.notShareable
        }
        let link = try await ShareEngine.share(object: obj, isPublic: isPublic, password: password)
        await loadShares()
        return link
    }

    func importShareLink(_ raw: String, password: String? = nil, destinationFolderID: String? = nil) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        await MainActor.run {
            self.isImportingShareLink = true
        }

        defer {
            Task { @MainActor in
                self.isImportingShareLink = false
            }
        }

        do {
            let outcome = try await ShareEngine.importLink(
                trimmed,
                password: password,
                destinationFolderID: destinationFolderID
            )

            switch outcome {
            case .pending(let objectID):
                let finalName = try await ShareEngine.confirmImport(objectID: objectID)
                _ = await CatalogSnapshot.upload()
                await loadAllFiles()
                await loadShares()
                await MainActor.run {
                    self.pendingPasswordLink = nil
                    self.showImportShareSheet = false
                    self.currentNotification = "Imported \"\(finalName)\""
                }
            case .imported:
                _ = await CatalogSnapshot.upload()
                await loadAllFiles()
                await loadShares()
                await MainActor.run {
                    self.pendingPasswordLink = nil
                    self.showImportShareSheet = false
                    self.currentNotification = "Shared file imported successfully"
                }
            case .selfOpen(let objectID):
                await loadAllFiles()
                await MainActor.run {
                    self.pendingPasswordLink = nil
                    self.showImportShareSheet = false
                    if let file = self.allFiles.first(where: { $0.id == objectID }) {
                        self.currentNotification = "This is your own file: \(file.name)"
                        self.openFile(file)
                    }
                }
            case .alreadyImported(let objectID):
                await loadAllFiles()
                await MainActor.run {
                    self.pendingPasswordLink = nil
                    self.showImportShareSheet = false
                    if let file = self.allFiles.first(where: { $0.id == objectID }) {
                        self.currentNotification = "Already in your drive: \(file.name)"
                        self.openFile(file)
                    }
                }
            }
        } catch ShareEngine.ShareError.passwordRequired {
            await MainActor.run {
                self.pendingPasswordLink = trimmed
                self.showImportShareSheet = true
                self.currentNotification = "Password required for this share link"
            }
        } catch {
            await MainActor.run {
                self.currentNotification = "Import failed: \(ShareEngine.describe(error))"
            }
            print("[iOS] importShareLink error: \(error)")
        }
    }

    func getInfo(_ file: FileItem) -> String {
        var info = "Name: \(file.name)\n"
        if let size = file.formattedSize {
            info += "Size: \(size)\n"
        }
        info += "Type: \(file.mime)\n"
        info += "Created: \(file.createdAt.formatted())\n"
        return info
    }

    func logout() {
        isAuthorized = false
        isVaultConnected = false
        files = []
        allFiles = []
    }

    func toggleFavorite(_ file: FileItem) {
        Task {
            do {
                guard var obj = try await DatabaseManager.shared.object(file.id) else { return }
                obj.isFavorite.toggle()
                try await DatabaseManager.shared.save(obj)
                await loadAllFiles()
            } catch {
                print("[iOS] toggleFavorite failed: \(error)")
            }
        }
    }

    func togglePin(_ file: FileItem) {
        Task {
            do {
                guard var obj = try await DatabaseManager.shared.object(file.id) else { return }
                let newPinned = !obj.isPinned
                obj.isPinned = newPinned
                try await DatabaseManager.shared.save(obj)
                await loadAllFiles()
                if newPinned {
                    _ = try? await DownloadEngine.download(object: obj) { _, _ in }
                } else {
                    let url = cachedURL(for: file)
                    try? FileManager.default.removeItem(at: url)
                }
            } catch {
                print("[iOS] togglePin failed: \(error)")
            }
        }
    }

    func cachedURL(for file: FileItem) -> URL {
        let base = (try? DownloadEngine.cacheDirectory()) ?? URL.temporaryDirectory
        let ext = (file.name as NSString).pathExtension
        let fileName = ext.isEmpty ? file.id : "\(file.id).\(ext)"
        return base.appendingPathComponent(fileName)
    }

    func isCached(_ file: FileItem) -> Bool {
        let url = cachedURL(for: file)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let sz = attrs[.size] as? Int64, sz > 0 else { return false }
        return file.size <= 0 || sz == file.size
    }

    func downloadFile(_ file: FileItem, progress: @escaping @Sendable (String, Double) -> Void) async throws -> URL? {
        guard let obj = try await DatabaseManager.shared.object(file.id) else { return nil }
        return try await DownloadEngine.download(object: obj, progress: progress)
    }

    func deleteFilePermanently(_ file: FileItem) {
        Task {
            do {
                try await DatabaseManager.shared.deleteObjectWithChunks(id: file.id)
                let url = cachedURL(for: file)
                try? FileManager.default.removeItem(at: url)
                await loadAllFiles()
            } catch {
                print("[iOS] deleteFilePermanently failed: \(error)")
            }
        }
    }

    func clearLocalCache() {
        Task {
            if let scratch = try? DownloadEngine.cacheDirectory() {
                try? FileManager.default.removeItem(at: scratch)
                try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            }
            if let thumbs = try? UploadEngine.thumbnailsDirectory() {
                try? FileManager.default.removeItem(at: thumbs)
                try? FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
            }
            try? await TelegramClient.shared.purgeDownloadedFiles()
            NotificationCenter.default.post(name: .tdlibCacheChanged, object: nil)
            await MainActor.run {
                for i in files.indices { files[i].thumbnailData = nil }
                for i in allFiles.indices { allFiles[i].thumbnailData = nil }
                thumbnailVersion += 1
            }
            await loadThumbnails()
        }
    }

    func calculateCacheSize() -> Int64 {
        var total: Int64 = 0
        let fm = FileManager.default
        if let scratch = try? DownloadEngine.cacheDirectory(),
           let items = try? fm.subpathsOfDirectory(atPath: scratch.path) {
            for item in items {
                let p = scratch.appendingPathComponent(item).path
                if let attr = try? fm.attributesOfItem(atPath: p), let sz = attr[.size] as? Int64 {
                    total += sz
                }
            }
        }
        if let thumbs = try? UploadEngine.thumbnailsDirectory(),
           let items = try? fm.subpathsOfDirectory(atPath: thumbs.path) {
            for item in items {
                let p = thumbs.appendingPathComponent(item).path
                if let attr = try? fm.attributesOfItem(atPath: p), let sz = attr[.size] as? Int64 {
                    total += sz
                }
            }
        }
        return total
    }

    func startTelegram(apiID: Int, apiHash: String) async {
        TelegramClient.shared.configure(apiID: apiID, apiHash: apiHash)
        do {
            try await TelegramClient.shared.start()
        } catch {
            databaseError = "Telegram init failed: \(error.localizedDescription)"
        }
    }
}

@MainActor
final class AudioPlaybackManager {
    static let shared = AudioPlaybackManager()
    private var playerView: MPVPlayerView?
    private var pollTimer: Timer?
    var onTimeUpdate: ((Double, Double, Bool) -> Void)?
    var onEnded: (() -> Void)?

    init() {
        let pv = MPVPlayerView(frame: .zero)
        pv.onEndReached = { [weak self] in
            Task { @MainActor in
                self?.onEnded?()
            }
        }
        self.playerView = pv
    }

    func play(url: URL) {
        playerView?.play(url)
        startPolling()
    }

    func pause() {
        playerView?.pause()
    }

    func resume() {
        playerView?.resume()
    }

    func seek(to seconds: Double) {
        playerView?.seek(to: seconds)
    }

    func stop() {
        stopPolling()
        playerView?.stop()
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self, let pv = self.playerView else { return }
            self.onTimeUpdate?(pv.currentTime, pv.duration, !pv.isPaused)
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
#endif
