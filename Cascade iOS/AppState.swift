#if os(iOS)
import Foundation
import GRDB
import SwiftUI

struct FileItem: Identifiable {
    let id: String
    let name: String
    let isFolder: Bool
    let size: Int64
    let mime: String
    let thumbnailData: Data?
    let isPrivate: Bool
    let createdAt: Date
    let parentID: String?

    var isVideo: Bool {
        guard !isFolder else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "mkv", "webm", "avi"].contains(ext)
    }

    var isImage: Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp"].contains(ext)
    }

    var isAudio: Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["mp3", "m4a", "flac", "wav", "aac", "ogg", "wma", "aiff", "opus", "alac"].contains(ext)
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
    var databaseError: String?
    var identity: TelegramClient.AccountIdentity?
    var profilePhotoData: Data?

    var hasTelegramCredentials: Bool {
        (try? KeychainStore.loadTelegramCredentials()) != nil
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

    private func completePostAuthSetup() async {
        isInitialLoading = true
        defer { isInitialLoading = false }

        identity = try? await TelegramClient.shared.fetchIdentity()
        profilePhotoData = try? await TelegramClient.shared.fetchProfilePhotoData()

        guard let vault = try? await VaultManager.ensureVault() else {
            databaseError = "Vault not found. Set up Cascade on another device first."
            return
        }

        await TelegramClient.shared.archiveVaultChannel(chatId: vault.channelID)
        _ = await VaultManager.ensureBackupChannel()
        await TelegramClient.shared.prewarmChannelScan(chatId: vault.channelID)
        await CatalogSnapshot.pruneOldSnapshots(chatId: vault.channelID)

        let restored = await CatalogSnapshot.restore()
        if !restored {
            _ = await VaultRepair.run()
        }

        await loadAllFiles()
    }

    func loadAllFiles() async {
        isLoadingFiles = true
        defer { isLoadingFiles = false }
        do {
            let objects = try await DatabaseManager.shared.allObjects()
                .filter { $0.tombstoneAt == nil && !$0.trashed }
            self.allFiles = objects.map { FileItem(record: $0) }
            self.files = currentFiles
        } catch {
            print("[iOS] loadAllFiles failed: \(error)")
        }
    }

    var currentFiles: [FileItem] {
        allFiles
            .filter { ($0.parentID ?? "") == currentFolderID }
            .sorted { lhs, rhs in
                if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
                return lhs.createdAt > rhs.createdAt
            }
    }

    func refreshFiles() {
        files = currentFiles
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

    func openTheater(_ file: FileItem) {}
    func closeTheater() {}
    func logout() { isAuthorized = false }
    func clearLocalCache() {}

    func startTelegram(apiID: Int, apiHash: String) async {
        TelegramClient.shared.configure(apiID: apiID, apiHash: apiHash)
        do {
            try await TelegramClient.shared.start()
        } catch {
            databaseError = "Telegram init failed: \(error.localizedDescription)"
        }
    }
}
#endif
