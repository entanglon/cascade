import Foundation
import TDLibKit

public struct RecentEntry: Codable, Equatable, Sendable {
    public var id: String
    public var openedAt: Double

    public init(id: String, openedAt: Double) {
        self.id = id
        self.openedAt = openedAt
    }
}

public struct RecentsPayload: Codable, Sendable {
    public var version: Int
    public var updatedAt: Double
    public var entries: [RecentEntry]

    public init(version: Int = 1, updatedAt: Double = Foundation.Date().timeIntervalSince1970, entries: [RecentEntry]) {
        self.version = version
        self.updatedAt = updatedAt
        self.entries = entries
    }
}

public final class RecentsSyncEngine: @unchecked Sendable {
    public static let shared = RecentsSyncEngine()
    public static let captionPrefix = "cascade:recents:v1:"
    public static let maxEntries = 40
    public static let userDefaultsKey = "cascade_recent_entries"

    private let stateLock = NSLock()
    private var pendingUploadTask: Task<Void, Never>?

    private init() {}

    // MARK: - Local Storage

    public static func loadLocalEntries() -> [RecentEntry] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let entries = try? JSONDecoder().decode([RecentEntry].self, from: data) else {
            // Migration: check if older cascade_recent_file_ids array exists
            if let ids = UserDefaults.standard.stringArray(forKey: "cascade_recent_file_ids"), !ids.isEmpty {
                let now = Foundation.Date().timeIntervalSince1970
                let migrated = ids.enumerated().map { index, id in
                    RecentEntry(id: id, openedAt: now - Double(index * 60))
                }
                saveLocalEntries(migrated)
                return migrated
            }
            return []
        }
        return entries
    }

    public static func saveLocalEntries(_ entries: [RecentEntry]) {
        let capped = Array(entries.prefix(maxEntries))
        if let data = try? JSONEncoder().encode(capped) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
        UserDefaults.standard.set(capped.map(\.id), forKey: "cascade_recent_file_ids")
    }

    public static func recordAccess(fileID: String) -> [RecentEntry] {
        var current = loadLocalEntries()
        let now = Foundation.Date().timeIntervalSince1970
        current.removeAll { $0.id == fileID }
        current.insert(RecentEntry(id: fileID, openedAt: now), at: 0)
        let updated = Array(current.prefix(maxEntries))
        saveLocalEntries(updated)
        return updated
    }

    // MARK: - Merging

    public static func merge(local: [RecentEntry], remote: [RecentEntry]) -> [RecentEntry] {
        var map: [String: Double] = [:]
        for entry in local {
            map[entry.id] = entry.openedAt
        }
        for entry in remote {
            if let existing = map[entry.id] {
                map[entry.id] = max(existing, entry.openedAt)
            } else {
                map[entry.id] = entry.openedAt
            }
        }
        let sorted = map.map { RecentEntry(id: $0.key, openedAt: $0.value) }
            .sorted { $0.openedAt > $1.openedAt }
        return Array(sorted.prefix(maxEntries))
    }

    // MARK: - Cloud Sync

    /// Fetches the newest recents payload from the channel, merges with local entries,
    /// saves the result, and returns the merged list.
    public func syncFromCloud() async -> [RecentEntry] {
        guard TelegramClient.shared.isAuthorized else { return Self.loadLocalEntries() }
        guard let vault = try? await DatabaseManager.shared.firstVault() else { return Self.loadLocalEntries() }

        let messages = await TelegramClient.shared.searchChannelMetadataMessages(chatId: vault.channelID, query: Self.captionPrefix, limit: 20)
        let recentsMessages: [Message] = messages.filter { (TelegramClient.shared.messageCaption($0) ?? "").hasPrefix(Self.captionPrefix) }
            .sorted { $0.id > $1.id }

        guard let newest = recentsMessages.first,
              let caption = TelegramClient.shared.messageCaption(newest),
              caption.hasPrefix(Self.captionPrefix) else {
            return Self.loadLocalEntries()
        }

        let base64Part = String(caption.dropFirst(Self.captionPrefix.count))
        guard let data = Data(base64Encoded: base64Part),
              let payload = try? JSONDecoder().decode(RecentsPayload.self, from: data) else {
            return Self.loadLocalEntries()
        }

        let local = Self.loadLocalEntries()
        let merged = Self.merge(local: local, remote: payload.entries)
        Self.saveLocalEntries(merged)

        // Prune older recents messages from the channel
        if recentsMessages.count > 1 {
            let staleIDs = recentsMessages.dropFirst().map { (msg: Message) -> Int64 in msg.id }
            try? await TelegramClient.shared.deleteMessages(chatId: vault.channelID, messageIds: Array(staleIDs))
        }

        // If local had newer items not present in remote, push merged update
        let remoteMaxTime = payload.entries.map { (e: RecentEntry) -> Double in e.openedAt }.max() ?? 0
        let localMaxTime = local.map { (e: RecentEntry) -> Double in e.openedAt }.max() ?? 0
        if localMaxTime > remoteMaxTime {
            scheduleUpload()
        }

        return merged
    }

    /// Schedules a debounced upload to the channel (5s delay to batch rapid file opens).
    public func scheduleUpload() {
        stateLock.lock()
        defer { stateLock.unlock() }

        pendingUploadTask?.cancel()
        pendingUploadTask = Task.detached(priority: .background) { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.uploadToCloud()
        }
    }

    /// Publishes current local recents to the channel as a metadata text message.
    public func uploadToCloud() async {
        guard TelegramClient.shared.isAuthorized else { return }
        guard let vault = try? await DatabaseManager.shared.firstVault() else { return }

        let entries = Self.loadLocalEntries()
        guard !entries.isEmpty else { return }

        let payload = RecentsPayload(
            version: 1,
            updatedAt: Foundation.Date().timeIntervalSince1970,
            entries: entries
        )

        guard let data = try? JSONEncoder().encode(payload) else { return }
        let base64 = data.base64EncodedString()
        let text = "\(Self.captionPrefix)\(base64)"

        do {
            let newMsgID = try await TelegramClient.shared.sendMetadataMessage(chatId: vault.channelID, text: text)
            print("Cascade recents: published recents.json to channel \(vault.channelID) (msg \(newMsgID ?? 0), \(entries.count) items)")

            // Clean up previous recents messages in the channel
            let messages = await TelegramClient.shared.searchChannelMetadataMessages(chatId: vault.channelID, query: Self.captionPrefix, limit: 20)
            let oldMessages: [Message] = messages.filter {
                (TelegramClient.shared.messageCaption($0) ?? "").hasPrefix(Self.captionPrefix) && $0.id != newMsgID
            }
            if !oldMessages.isEmpty {
                let staleIDs = oldMessages.map { (msg: Message) -> Int64 in msg.id }
                try? await TelegramClient.shared.deleteMessages(chatId: vault.channelID, messageIds: staleIDs)
            }
        } catch {
            print("Cascade recents upload failed: \(error.localizedDescription)")
        }
    }
}
