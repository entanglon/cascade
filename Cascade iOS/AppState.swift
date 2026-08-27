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
        self.createdAt = record.createdAt
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
            print("[iOS] DB start failed: \(error)")
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
            print("[iOS] Telegram start failed: \(error)")
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

        // 1. Fetch identity
        do {
            identity = try await TelegramClient.shared.fetchIdentity()
            print("[iOS] identity: \(identity?.firstName ?? "?") \(identity?.lastName ?? "")")
        } catch {
            print("[iOS] fetchIdentity failed: \(error)")
        }

        // 2. Fetch profile photo
        do {
            profilePhotoData = try await TelegramClient.shared.fetchProfilePhotoData()
        } catch {
            print("[iOS] fetchProfilePhoto failed: \(error)")
        }

        // 3. Ensure vault
        guard let vault = try? await VaultManager.ensureVault() else {
            print("[iOS] vault ensure failed")
            databaseError = "Vault not found. Make sure you've set up Cascade on another device first."
            return
        }
        print("[iOS] vault ready (channel \(vault.channelID))")

        // 4. Archive vault from chat list
        await TelegramClient.shared.archiveVaultChannel(chatId: vault.channelID)

        // 5. Backup channel
        _ = await VaultManager.ensureBackupChannel()

        // 6. Prewarm + snapshot prune
        await TelegramClient.shared.prewarmChannelScan(chatId: vault.channelID)
        await CatalogSnapshot.pruneOldSnapshots(chatId: vault.channelID)

        // 7. Restore catalog
        let restored = await CatalogSnapshot.restore()
        if restored {
            print("[iOS] catalog restored from snapshot")
        } else {
            print("[iOS] no snapshot, running repair scan...")
            let changed = await VaultRepair.run()
            print("[iOS] repair scan changed=\(changed)")
        }

        // 8. Load files
        await loadFiles()
        print("[iOS] loaded \(files.count) files")
    }

    func loadFiles() async {
        isLoadingFiles = true
        defer { isLoadingFiles = false }
        do {
            let objects = try await DatabaseManager.shared.allObjects()
                .filter { $0.tombstoneAt == nil }
            self.files = objects
                .sorted { lhs, rhs in
                    if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
                    return lhs.createdAt > rhs.createdAt
                }
                .map { FileItem(record: $0) }
        } catch {
            print("[iOS] loadFiles failed: \(error)")
        }
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
