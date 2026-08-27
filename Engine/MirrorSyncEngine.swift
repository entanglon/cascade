#if os(macOS)
import Foundation
import CoreServices
import Combine
import os

/// Local-side snapshot for the mirror decision matrix (exists + stat values).
struct MirrorSide {
    var exists: Bool = false
    var size: Int64 = 0
    var modifiedAt: Date? = nil
}

/// Wave 2 item 3 — Finder drop-zone sync: a TWO-WAY mirrored folder between
/// the user's disk and one cloud folder (Dropbox-style, user-confirmed scope).
///
///   Local → cloud : FSEvents watcher on the mirror dir; new/changed files are
///                   uploaded into the paired cloud folder.
///   Cloud → local : 30 s poller reconciles the channel snapshot; new/changed
///                   objects materialize into the mirror dir.
///   Conflicts     : last-writer-wins per file by modification time.
///   Deletions     : NOT propagated either direction in v1 (safest) — removing
///                   a file on one side leaves the other side untouched and
///                   simply un-pairs it.
///
/// Flat v1: only files directly inside the mirror dir ↔ files directly inside
/// the cloud folder. Subfolders on either side are ignored (documented).
///
/// Uploads go through `UploadEngine.upload` DIRECTLY (not UploadManager — its
/// parent resolution is coupled to UI state); downloads reuse DownloadEngine's
/// scratch materialization + copy-out, exactly like ExportEngine. The paired
/// baseline lives in `mirror_state` (sizes + mtimes at sync time), so each
/// pass can tell who changed since without re-hashing the world.
@MainActor
final class MirrorSyncEngine: ObservableObject {
    static let shared = MirrorSyncEngine()

    private static let logger = Logger(subsystem: "com.cascade.app", category: "mirror")

    // MARK: - Configuration

    static let enabledKey = "xc.mirrorEnabled"
    static let localPathKey = "xc.mirrorLocalPath"
    static let folderIDKey = "xc.mirrorFolderID"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var configuredLocalPath: String? {
        let raw = UserDefaults.standard.string(forKey: localPathKey)
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    /// Cloud folder object ID paired with the mirror dir ("" = vault root).
    static var configuredFolderID: String? {
        let raw = UserDefaults.standard.string(forKey: folderIDKey)
        guard let raw else { return nil }
        return raw.isEmpty ? nil : raw
    }

    // MARK: - Published state (Settings surface)

    @Published private(set) var isWatching = false
    @Published private(set) var statusText: String = "Idle"
    @Published private(set) var lastError: String?

    // MARK: - Internals

    private weak var appState: AppState?
    private var eventStream: FSEventStreamRef?
    private var pollTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var isReconciling = false

    private init() {}

    // MARK: - Lifecycle

    /// Starts watching/polling if enabled. Called from post-auth setup and
    /// whenever Settings changes the config. Idempotent: always tears the old
    /// stream/loop down first so config edits apply live.
    func start(appState: AppState) {
        self.appState = appState
        stopInternal()
        guard Self.isEnabled,
              let path = Self.configuredLocalPath,
              FileManager.default.fileExists(atPath: path),
              TelegramClient.shared.isAuthorized else {
            statusText = Self.isEnabled ? "Waiting for connection…" : "Off"
            return
        }
        startWatching(path: path)
        startPolling()
        isWatching = true
        statusText = "Watching “\((path as NSString).lastPathComponent)”"
        Task { await reconcile() }
    }

    func stop() {
        stopInternal()
        statusText = "Off"
    }

    private func stopInternal() {
        if let eventStream {
            FSEventStreamStop(eventStream)
            FSEventStreamInvalidate(eventStream)
            FSEventStreamRelease(eventStream)
            self.eventStream = nil
        }
        pollTask?.cancel()
        pollTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        isWatching = false
    }

    // MARK: - FSEvents (local → cloud)

    private func startWatching(path: String) {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, clientInfo, _, eventPaths, _, _ in
                guard let clientInfo else { return }
                let engine = Unmanaged<MirrorSyncEngine>.fromOpaque(clientInfo).takeUnretainedValue()
                // UseCFTypes → eventPaths is a CFArray of CFString.
                let array = eventPaths.assumingMemoryBound(to: NSArray.self).pointee
                let paths = (array as? [String]) ?? []
                Task { @MainActor in
                    engine.handleLocalEvents(paths: paths)
                }
            },
            &context,
            [path] as CFArray,
            FSEventStreamEventId(UInt64(kFSEventStreamEventIdSinceNow)),
            1.0, // latency — coalesce bursts of writes
            flags
        ) else {
            lastError = "Could not watch the folder."
            return
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "com.cascade.mirror.fsevents"))
        FSEventStreamStart(stream)
        eventStream = stream
    }

    /// FSEvents burst landed — debounce, then run one reconciliation pass that
    /// covers everything (the events only serve as the trigger; reconcile()
    /// diffs both sides from scratch, which also heals missed events).
    private func handleLocalEvents(paths: [String]) {
        guard Self.isEnabled else { return }
        // Ignore our own download writes landing back as events: reconcile()
        // records baselines BEFORE copying out, but the write itself bumps the
        // mtime — so record AFTER copy and treat post-copy events via baseline
        // comparison (mtime == recorded → no-op). The debounce just merges them.
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.reconcile(trigger: "fs-events (\(paths.count))")
        }
    }

    // MARK: - Poller (cloud → local)

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.pollOnce()
            }
        }
    }

    private func pollOnce() async {
        guard Self.isEnabled, TelegramClient.shared.isAuthorized else { return }
        // Reconcile the channel into the catalog first (uses the cached scan;
        // cheap when nothing changed), then diff both sides.
        _ = await CatalogSnapshot.upload()
        await reconcile(trigger: "poll")
    }

    // MARK: - Reconciliation core

    /// Files never tracked by the mirror: hidden, editor temporaries, partial
    /// downloads. Pure/static for unit testing.
    nonisolated static func shouldTrackName(_ name: String) -> Bool {
        if name.hasPrefix(".") { return false } // .DS_Store, .~lock, dotfiles
        let lower = name.lowercased()
        let partialSuffixes = ["crdownload", "part", "partial", "download", "tmp", "swp", "dtmp"]
        if let ext = name.split(separator: ".").last.map(String.init)?.lowercased(),
           partialSuffixes.contains(ext) {
            return false
        }
        if lower.hasPrefix("~$") || lower.hasPrefix(".#") { return false }
        return true
    }

    /// The decision matrix — pure so tests can pin every branch.
    enum MirrorAction: Equatable {
        case uploadNew          // local file, no pairing, no remote → upload
        case replaceRemote      // local won LWW over an existing pair → re-upload replacement
        case pullOverwrite      // remote won LWW → overwrite the local file
        case adoptPair          // identical content both sides, no entry yet → pair silently
        case conflictLocalKeeps // ambiguous adoption, local newer → keep local, record baseline
        case dropEntry          // remote vanished → v1 keeps local file, forgets the pairing
        case none
    }

    nonisolated static func decide(
        entry: MirrorStateRecord?,
        remote: ObjectRecord?,
        local: MirrorSide?
    ) -> MirrorAction {
        switch (entry, remote, local?.exists ?? false) {
        case (.none, .none, false):
            return .none
        case (.none, .none, true):
            return .uploadNew
        case (.none, .some(let r), false):
            // Cloud-only file → materialize locally.
            return r.trashed ? .none : .pullOverwrite
        case (.none, .some(let r), true):
            // Same-named file both sides, never paired.
            if r.size == local?.size {
                return .adoptPair
            }
            let remoteDate = r.modifiedAt
            if let lm = local?.modifiedAt, remoteDate > lm {
                return .pullOverwrite // LWW: remote is newer
            }
            return .conflictLocalKeeps
        case (.some, .none, _):
            // Remote gone (deleted/trashed remotely) — v1 skips delete
            // propagation: keep the local file, forget the pairing.
            return .dropEntry
        case (.some(let e), .some(let r), let localExists):
            let remoteChanged = r.modifiedAt > e.remoteModifiedAt || r.size != e.size
            let localChanged = !localExists
                || local?.modifiedAt != e.localModifiedAt
                || local?.size != e.size
            if !localExists {
                // Local file deleted → v1 skip-delete: keep cloud, drop entry.
                return .dropEntry
            }
            switch (localChanged, remoteChanged) {
            case (false, false):
                return .none
            case (true, false):
                return .replaceRemote
            case (false, true):
                return .pullOverwrite
            case (true, true):
                // True conflict — last writer wins by absolute time.
                if let lm = local?.modifiedAt, lm >= r.modifiedAt {
                    return .replaceRemote
                }
                return .pullOverwrite
            }
        }
    }

    /// One full pass: diff local dir ↔ cloud folder ↔ pairing table, act.
    func reconcile(trigger: String = "manual") async {
        guard Self.isEnabled,
              let localPath = Self.configuredLocalPath,
              FileManager.default.fileExists(atPath: localPath),
              let folderID = Self.configuredFolderID,
              TelegramClient.shared.isAuthorized,
              !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }

        do {
            let states = try await DatabaseManager.shared.mirrorStates()
            let allObjects = try await DatabaseManager.shared.allObjects()
            let cloudFiles = allObjects.filter {
                !$0.isFolder && !$0.trashed && $0.tombstoneAt == nil
                    && $0.state == "ready" && $0.parentID == folderID
            }
            let cloudByName = Dictionary(cloudFiles.map { ($0.name, $0) },
                                         uniquingKeysWith: { a, _ in a })
            let stateByName = Dictionary(states.map { ($0.name, $0) },
                                         uniquingKeysWith: { a, _ in a })
            let fm = FileManager.default

            // Union of names across all three sides.
            var names = Set(stateByName.keys)
            names.formUnion(cloudByName.keys)
            if let entries = try? fm.contentsOfDirectory(atPath: localPath) {
                for n in entries where Self.shouldTrackName(n) {
                    names.insert(n)
                }
            }

            for name in names.sorted() {
                guard !Task.isCancelled else { return }
                let url = URL(fileURLWithPath: localPath).appendingPathComponent(name)

                var side = MirrorSide(exists: false)
                if let attrs = try? fm.attributesOfItem(atPath: url.path(percentEncoded: false)),
                   (attrs[.type] as? FileAttributeType) == .typeRegular {
                    side.exists = true
                    side.size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                    side.modifiedAt = attrs[.modificationDate] as? Date
                }

                let action = Self.decide(
                    entry: stateByName[name],
                    remote: cloudByName[name],
                    local: side.exists ? side : nil
                )
                try await perform(action: action, name: name, url: url, side: side,
                                  remote: cloudByName[name], entry: stateByName[name])
            }
            lastError = nil
            statusText = "Synced \(Date().formatted(date: .omitted, time: .shortened))"
            Self.logger.info("mirror reconcile done (\(trigger, privacy: .public)): \(names.count) name(s)")
        } catch {
            lastError = error.localizedDescription
            Self.logger.error("mirror reconcile failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func perform(
        action: MirrorAction,
        name: String,
        url: URL,
        side: MirrorSide,
        remote: ObjectRecord?,
        entry: MirrorStateRecord?
    ) async throws {
        switch action {
        case .none:
            break

        case .uploadNew:
            statusText = "Uploading “\(name)”…"
            try await UploadEngine.upload(fileURL: url, parentID: Self.configuredFolderID) { _, _ in }
            guard let created = try await findCreatedObject(sourceURL: url, fallbackName: name) else {
                throw MirrorError.uploadResultNotFound
            }
            try await recordPair(object: created, localName: name, localURL: url)

        case .replaceRemote:
            guard let old = remote else { return }
            // Replace = retire the old content, upload fresh bytes under the
            // same name. Wave 2 item 8: the retired copy becomes VERSION
            // HISTORY — snapshotted into object_versions (metadata travels to
            // the replacement via carryOverVersions) and moved to TRASH with
            // its channel messages INTACT, so recovery stays possible until
            // the user empties Trash (Trash-is-the-backup decision). Trashing
            // first also frees the display name (UploadEngine's dedupe skips
            // trashed siblings); an upload failure restores the old row.
            try? await DatabaseManager.shared.recordVersion(for: old.id)
            try await DatabaseManager.shared.updateObject(old.id) { $0.trashed = true }
            do {
                try await UploadEngine.upload(fileURL: url, parentID: Self.configuredFolderID) { _, _ in }
            } catch {
                try? await DatabaseManager.shared.updateObject(old.id) { $0.trashed = false }
                throw error
            }
            guard let created = try await findCreatedObject(sourceURL: url, fallbackName: name) else {
                try? await DatabaseManager.shared.updateObject(old.id) { $0.trashed = false }
                throw MirrorError.uploadResultNotFound
            }
            // The old row is gone from the active catalog after this — re-home
            // its version rows so the replacement carries the lineage.
            try? await DatabaseManager.shared.carryOverVersions(from: old.id, to: created.id)
            if let appState {
                await appState.loadFiles()
            }
            try await recordPair(object: created, localName: name, localURL: url)
            statusText = "Updated “\(name)”"

        case .pullOverwrite:
            guard let obj = remote else { return }
            statusText = "Downloading “\(name)”…"
            let scratchURL = try await DownloadEngine.download(object: obj, quiet: true) { _, _ in }
            let fm = FileManager.default
            // Atomic-ish replace: copy to a temp sibling, then swap.
            let tmp = url.deletingLastPathComponent()
                .appendingPathComponent(".\(name).mirror-\(UUID().uuidString)")
            if fm.fileExists(atPath: tmp.path(percentEncoded: false)) {
                try? fm.removeItem(at: tmp)
            }
            try fm.copyItem(at: scratchURL, to: tmp)
            if fm.fileExists(atPath: url.path(percentEncoded: false)) {
                try fm.removeItem(at: url)
            }
            try fm.moveItem(at: tmp, to: url)
            try await recordPair(object: obj, localName: name, localURL: url)

        case .adoptPair, .conflictLocalKeeps:
            guard let obj = remote, side.exists else { return }
            // Identical content (or local wins an ambiguous adoption): pair
            // without touching either side.
            try await recordPair(object: obj, localName: name, localURL: url)

        case .dropEntry:
            // v1 skips delete propagation: leave the surviving side alone,
            // forget the stale pairing.
            if let entry {
                try? await DatabaseManager.shared.deleteMirrorState(objectID: entry.id)
            }
        }
    }

    /// After `UploadEngine.upload` returns, locate the object it created — the
    /// row carries `sourcePath = fileURL.path` and flips to `"ready"` before
    /// returning. Newest match wins.
    private func findCreatedObject(sourceURL: URL, fallbackName: String) async throws -> ObjectRecord? {
        let path = sourceURL.path(percentEncoded: false)
        let all = try await DatabaseManager.shared.allObjects()
        return all
            .filter { !$0.trashed && $0.tombstoneAt == nil && $0.state == "ready" && $0.sourcePath == path }
            .max { $0.createdAt < $1.createdAt }
            ?? all.first { !$0.trashed && $0.state == "ready" && $0.name == fallbackName && $0.parentID == Self.configuredFolderID }
    }

    /// Records/refreshes the paired baseline after any successful sync action.
    /// Keyed by the LOCAL file name (not the object's) — the two only differ
    /// when UploadEngine deduped a colliding name, and every lookup in
    /// reconcile() is driven by local names.
    private func recordPair(object: ObjectRecord, localName: String, localURL: URL) async throws {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: localURL.path(percentEncoded: false))
        let record = MirrorStateRecord(
            id: object.id,
            name: localName,
            size: object.size,
            remoteModifiedAt: object.modifiedAt,
            localModifiedAt: attrs?[.modificationDate] as? Date ?? Date(),
            rootHash: object.rootHash,
            lastSyncedAt: Date()
        )
        try await DatabaseManager.shared.saveMirrorState(record)
    }
}

enum MirrorError: Error, LocalizedError {
    case uploadResultNotFound

    var errorDescription: String? {
        switch self {
        case .uploadResultNotFound:
            return "Upload finished but the mirrored file could not be linked."
        }
    }
}
#endif
