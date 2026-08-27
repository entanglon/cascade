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

    var isVideo: Bool {
        guard !isFolder else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "mkv", "webm", "avi"].contains(ext)
    }

    var systemIcon: String {
        if isFolder { return "folder.fill" }
        let ext = (name as NSString).pathExtension.lowercased()
        if ["mp4", "mov", "m4v", "mkv"].contains(ext) { return "film" }
        if ["mp3", "m4a", "flac", "wav", "aac", "ogg"].contains(ext) { return "music.note" }
        if ["jpg", "jpeg", "png", "gif", "heic", "webp"].contains(ext) { return "photo" }
        if ["pdf"].contains(ext) { return "doc.text" }
        return "doc"
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
    }
}

@Observable
final class AppState {
    var currentFolderID: String = ""
    var files: [FileItem] = []
    var isLoadingFiles = false
    var isInitialLoading = true
    var currentFolderName = "My Files"
    var currentNotification: String?
    var isUploading = false
    var uploadStatus = ""
    var uploadProgress: Double = 0
    var isAuthorized = false
    var isAuthResolved = false
    var databaseError: String?
    var hasTelegramCredentials: Bool {
        (try? KeychainStore.loadTelegramCredentials()) != nil
    }

    func bootstrap() async {
        isInitialLoading = true
        defer { isInitialLoading = false }
        do {
            try await DatabaseManager.shared.start()
        } catch {
            print("DB start failed: \(error)")
        }

        guard let creds = try? KeychainStore.loadTelegramCredentials() else {
            // No credentials — show setup screen immediately
            isAuthResolved = true
            isAuthorized = false
            return
        }

        TelegramClient.shared.configure(apiID: creds.apiID, apiHash: creds.apiHash)
        do {
            try await TelegramClient.shared.start()
        } catch {
            print("Telegram start failed: \(error)")
            isAuthResolved = true
            return
        }

        // Poll until auth is resolved (TDLib reports state async)
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

        // Ensure vault channel exists
        guard let vault = try? await VaultManager.ensureVault() else {
            print("iOS: vault ensure failed")
            return
        }
        print("iOS: vault ready (channel \(vault.channelID))")

        // Archive vault channel from chat list
        await TelegramClient.shared.archiveVaultChannel(chatId: vault.channelID)

        // Ensure backup channel
        _ = await VaultManager.ensureBackupChannel()

        // Prewarm channel scan
        await TelegramClient.shared.prewarmChannelScan(chatId: vault.channelID)

        // Prune old snapshots
        await CatalogSnapshot.pruneOldSnapshots(chatId: vault.channelID)

        // Try instant restore from snapshot, fall back to full repair scan
        let restored = await CatalogSnapshot.restore()
        if restored {
            print("iOS: catalog restored from snapshot")
        } else {
            let changed = await VaultRepair.run()
            print("iOS: repair scan changed=\(changed)")
        }

        await loadFiles()
    }

    func loadFiles() async {
        isLoadingFiles = true
        defer { isLoadingFiles = false }
        let all = (try? await DatabaseManager.shared.allObjects()) ?? []
        files = all
            .filter { $0.parentID == currentFolderID && !$0.trashed }
            .map { FileItem(record: $0) }
    }

    func navigateToFolder(_ file: FileItem) {
        currentFolderID = file.id
        currentFolderName = file.name
        Task { await loadFiles() }
    }

    func openTheater(_ file: FileItem) {
    }

    func closeTheater() {
    }

    func logout() {
        isAuthorized = false
    }

    func clearLocalCache() {
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
#endif
