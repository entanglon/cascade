import SwiftUI
import UniformTypeIdentifiers
import AppKit
import os

struct FileBrowserView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    @AppStorage("xc.viewMode") private var viewModeRaw = "grid"
    @AppStorage("xc.cardWidth") private var cardWidth = 200.0

    @State private var showImporter = false
    @State private var showNewFolder = false
    @State private var showNewPrivateFolder = false
    @State private var folderName = ""
    @State private var showNewPlaylist = false
    @State private var playlistName = ""
    @State private var renameTarget: ObjectRecord?
    @State private var renameText = ""
    @FocusState private var gridFocused: Bool
    @FocusState private var searchFocused: Bool
    @State private var showEmptyTrashAlert = false
    /// Wave 2 item 7 — duplicate finder review sheet (All Files page menu).
    @State private var showDuplicatesFinder = false
    @State private var showMiniTransfersPopover = false
    @State private var dropTargeted = false
    @State private var columnCount = 4
    @State private var fabHovering = false
    @State private var itemFrames: [String: CGRect] = [:]
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    /// Finder-style list expansion: folder IDs whose children render nested
    /// below them in list view (session-local; grid view never inlines).
    @State private var expandedFolderIDs = Set<String>()
    /// Set whenever keyboard navigation changes the selection; the grid/list
    /// scroll to this item so arrow navigation never leaves it off-screen.
    @State private var scrollTargetID: String?
    /// Keyboard navigation state reported by the Photos/Videos media grids
    /// (their visual order differs from folders-first and their columns are
    /// adaptive, so they own the math). The order itself lives in AppState
    /// (mediaOrderedIDs) so the TheaterView preview can navigate the same
    /// on-screen sequence.
    @State private var mediaColumnCount = 5
    @Namespace private var viewModeNamespace
    @AppStorage("xc.sortOptionRaw") private var sortOptionRaw = "name"
    @AppStorage("xc.sortAscending") private var sortAscending = false

    private enum SearchScope: Hashable {
        case everywhere
        case currentFolder
    }

    @State private var searchScope: SearchScope = .everywhere

    private var isSearching: Bool {
        !appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var currentScopeName: String? {
        if let folder = appState.files.first(where: { $0.id == appState.currentFolderID }) {
            return folder.name
        }
        if appState.selectedDestination != .allFiles {
            return appState.selectedDestination.title
        }
        return nil
    }

    private var sortOption: SortOption {
        get { Self.sortOption(for: sortOptionRaw) }
        nonmutating set {
            sortOptionRaw = newValue.rawValue
        }
    }

    /// Maps a stored raw string to its option. RawValues are display strings
    /// ("Size", "Date Created", …) — matched directly so the getter agrees
    /// with what the setter writes (a hand-rolled lowercase switch once
    /// pinned the UI on Name forever). Legacy lowercase "name" falls through
    /// to .name. Exposed for unit tests.
    static func sortOption(for raw: String) -> SortOption {
        SortOption(rawValue: raw) ?? .name
    }

    enum SortOption: String, CaseIterable, Identifiable {
        case name = "Name"
        case dateCreated = "Date Created"
        case dateModified = "Date Modified"
        case size = "Size"
        case kind = "Kind"

        var id: String { rawValue }

        var iconName: String {
            switch self {
            case .name: "textformat.abc"
            case .dateCreated: "calendar.badge.plus"
            case .dateModified: "calendar"
            case .size: "arrow.up.and.down.square"
            case .kind: "square.grid.3x3.square"
            }
        }
    }

    private var visibleFiles: [ObjectRecord] {
        let query = appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            return searchResults(for: query)
        }

        let base: [ObjectRecord] = {
            let files = appState.files.filter { $0.state == "ready" }
            switch appState.selectedDestination {
            case .allFiles:
                return files.filter { !$0.trashed && !$0.isPrivate && $0.parentID == appState.currentFolderID }
            case .privateVault:
                return files.filter { !$0.trashed && $0.isPrivate && $0.parentID == appState.currentFolderID }
            case .recent:
                let entries = RecentsSyncEngine.loadLocalEntries()
                let fileMap = Dictionary(uniqueKeysWithValues: files.filter { !$0.trashed && !$0.isFolder && !$0.isPrivate }.map { ($0.id, $0) })
                return entries.compactMap { fileMap[$0.id] }
            case .favorites:
                return files.filter { $0.isFavorite && !$0.trashed && !$0.isPrivate }
            case .photos:
                if let currentID = appState.currentFolderID {
                    return files.filter { !$0.trashed && !$0.isPrivate && $0.parentID == currentID }
                } else {
                    // The Photos page is a single place for EVERY photo in the cloud,
                    // wherever it lives — folders don't appear here, only albums.
                    let albums = files.filter { !$0.trashed && !$0.isPrivate && $0.isFolder && $0.mime == "cascade/album-photo" }
                    let photoFiles = files.filter { !$0.trashed && !$0.isFolder && !$0.isPrivate && (
                        $0.mime.hasPrefix("image/") || ["jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp", "svg"].contains(($0.name as NSString).pathExtension.lowercased())
                    ) }
                    return albums + photoFiles
                }
            case .video:
                if let currentID = appState.currentFolderID {
                    return files.filter { !$0.trashed && !$0.isPrivate && $0.parentID == currentID }
                } else {
                    let playlists = files.filter { !$0.trashed && !$0.isPrivate && $0.isFolder && $0.mime == "cascade/playlist-video" }
                    let videoFiles = files.filter { !$0.trashed && !$0.isFolder && !$0.isPrivate && (
                        $0.mime.hasPrefix("video/") || ["mp4", "mov", "m4v", "mkv", "avi", "webm", "3gp", "mpg", "mpeg"].contains(($0.name as NSString).pathExtension.lowercased())
                    ) }
                    return playlists + videoFiles
                }
            case .audio:
                if let currentID = appState.currentFolderID {
                    return files.filter { !$0.trashed && !$0.isPrivate && $0.parentID == currentID }
                } else {
                    let playlists = files.filter { !$0.trashed && !$0.isPrivate && $0.isFolder && $0.mime == "cascade/playlist-audio" }
                    let audioFiles = files.filter { !$0.trashed && !$0.isFolder && !$0.isPrivate && (
                        $0.mime.hasPrefix("audio/") || ["mp3", "m4a", "wav", "flac", "aac", "ogg"].contains(($0.name as NSString).pathExtension.lowercased())
                    ) }
                    return playlists + audioFiles
                }
            case .documents:
                return files.filter { !$0.trashed && !$0.isFolder && !$0.isPrivate &&
                    ($0.mime.contains("pdf") || $0.mime.hasPrefix("text/") ||
                     $0.mime.contains("msword") || $0.mime.contains("officedocument")) }
            case .library:
                return files.filter { !$0.trashed && $0.isBook }
            case .transfers:
                return []
            case .shared:
                // The Shared page is the outgoing-share manager (ShareManagerView),
                // not a file grid — no objects show here.
                return []
            case .archive:
                return files.filter { $0.isArchived }
            case .trash:
                return files.filter { $0.trashed }
            }
        }()

        // Archived files are hidden everywhere except the Archive destination.
        let baseUnarchived = appState.selectedDestination == .archive ? base : base.filter { !$0.isArchived }

        if appState.selectedDestination == .recent {
            return baseUnarchived
        }

        switch sortOption {
        case .name:
            return baseUnarchived.sorted {
                let res = $0.name.localizedCaseInsensitiveCompare($1.name)
                return sortAscending ? res == .orderedAscending : res == .orderedDescending
            }
        case .dateCreated:
            return baseUnarchived.sorted {
                sortAscending ? $0.createdAt < $1.createdAt : $0.createdAt > $1.createdAt
            }
        case .dateModified:
            return baseUnarchived.sorted {
                sortAscending ? $0.modifiedAt < $1.modifiedAt : $0.modifiedAt > $1.modifiedAt
            }
        case .size:
            return baseUnarchived.sorted {
                sortAscending ? $0.size < $1.size : $0.size > $1.size
            }
        case .kind:
            return baseUnarchived.sorted {
                let k0 = $0.isFolder ? "0_\($0.mime)" : "1_\($0.mime)"
                let k1 = $1.isFolder ? "0_\($1.mime)" : "1_\($1.mime)"
                let res = k0.localizedCaseInsensitiveCompare(k1)
                return sortAscending ? res == .orderedAscending : res == .orderedDescending
            }
        }
    }

    private func searchResults(for query: String) -> [ObjectRecord] {
        let files = appState.files.filter { $0.state == "ready" }

        let pool: [ObjectRecord] = {
            if searchScope == .currentFolder {
                switch appState.selectedDestination {
                case .allFiles:
                    return files.filter { !$0.trashed && !$0.isPrivate && $0.parentID == appState.currentFolderID }
                case .privateVault:
                    return files.filter { !$0.trashed && $0.isPrivate && $0.parentID == appState.currentFolderID }
                case .recent:
                    return files.filter { !$0.trashed && !$0.isFolder && !$0.isPrivate }
                case .favorites:
                    return files.filter { $0.isFavorite && !$0.trashed && !$0.isPrivate }
                case .photos:
                    return files.filter { !$0.trashed && !$0.isPrivate && ($0.mime.hasPrefix("image/") || $0.isPhoto) }
                case .video:
                    return files.filter { !$0.trashed && !$0.isPrivate && ($0.mime.hasPrefix("video/") || $0.isVideo) }
                case .audio:
                    return files.filter { !$0.trashed && !$0.isPrivate && ($0.mime.hasPrefix("audio/") || $0.isAudio) }
                case .documents:
                    return files.filter { !$0.trashed && !$0.isPrivate && $0.isDocument }
                case .library:
                    return files.filter { !$0.trashed && $0.isBook }
                case .archive:
                    return files.filter { $0.isArchived }
                case .trash:
                    return files.filter { $0.trashed }
                case .transfers, .shared:
                    return files.filter { !$0.trashed && !$0.isPrivate && !$0.isArchived }
                }
            } else {
                // Everywhere across the app!
                if appState.selectedDestination == .trash {
                    return files.filter { $0.trashed }
                } else if appState.selectedDestination == .archive {
                    return files.filter { $0.isArchived && !$0.trashed }
                } else if appState.selectedDestination == .privateVault {
                    return files.filter { $0.isPrivate && !$0.trashed && !$0.isArchived }
                } else {
                    return files.filter { file in
                        guard !file.trashed, !file.isArchived else { return false }
                        if file.isPrivate {
                            return appState.isPrivateVaultUnlocked
                        }
                        return true
                    }
                }
            }
        }()

        let matching = pool.filter { matchesSearch($0, query: query) }

        let q = query.lowercased()
        return matching.sorted { a, b in
            let aPrefix = a.name.lowercased().hasPrefix(q)
            let bPrefix = b.name.lowercased().hasPrefix(q)
            if aPrefix != bPrefix { return aPrefix }

            if a.isFolder != b.isFolder { return a.isFolder }

            switch sortOption {
            case .name:
                let res = a.name.localizedCaseInsensitiveCompare(b.name)
                return sortAscending ? res == .orderedAscending : res == .orderedDescending
            case .dateCreated:
                return sortAscending ? a.createdAt < b.createdAt : a.createdAt > b.createdAt
            case .dateModified:
                return sortAscending ? a.modifiedAt < b.modifiedAt : a.modifiedAt > b.modifiedAt
            case .size:
                return sortAscending ? a.size < b.size : a.size > b.size
            case .kind:
                let k0 = a.isFolder ? "0_\(a.mime)" : "1_\(a.mime)"
                let k1 = b.isFolder ? "0_\(b.mime)" : "1_\(b.mime)"
                let res = k0.localizedCaseInsensitiveCompare(k1)
                return sortAscending ? res == .orderedAscending : res == .orderedDescending
            }
        }
    }

    private func matchesSearch(_ file: ObjectRecord, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }

        // 1. Direct name match (case- and diacritic-insensitive)
        if file.name.localizedCaseInsensitiveContains(q) {
            return true
        }

        // 2. Extension match
        let ext = (file.name as NSString).pathExtension.lowercased()
        let cleanQ = q.hasPrefix(".") ? String(q.dropFirst()).lowercased() : q.lowercased()
        if !ext.isEmpty && (ext == cleanQ || ext.localizedCaseInsensitiveContains(cleanQ)) {
            return true
        }

        // 3. Category / kind keyword match
        if (cleanQ == "image" || cleanQ == "photo" || cleanQ == "photos") && file.isPhoto { return true }
        if (cleanQ == "video" || cleanQ == "movie" || cleanQ == "movies") && file.isVideo { return true }
        if (cleanQ == "audio" || cleanQ == "music" || cleanQ == "song" || cleanQ == "songs" || cleanQ == "mp3") && file.isAudio { return true }
        if (cleanQ == "book" || cleanQ == "books" || cleanQ == "epub") && file.isBook { return true }
        if (cleanQ == "doc" || cleanQ == "document" || cleanQ == "documents" || cleanQ == "pdf") && file.isDocument { return true }
        if (cleanQ == "folder" || cleanQ == "folders") && file.isFolder { return true }
        if (cleanQ == "favorite" || cleanQ == "favorites" || cleanQ == "starred") && file.isFavorite { return true }

        return false
    }

    var body: some View {
        // Alerts/sheets live on their own chain — the browser's main view is already
        // at the type-checker's expression-size limit.
        mainContent
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    for url in urls {
                        appState.startUpload(url: url)
                    }
                }
            }
            .fileImporter(
                isPresented: Binding(
                    get: { appState.subtitlePickerTarget != nil },
                    set: { if !$0 { appState.subtitlePickerTarget = nil } }
                ),
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                let target = appState.subtitlePickerTarget
                appState.subtitlePickerTarget = nil
                guard case .success(let urls) = result else { return }
                for url in urls {
                    appState.addSubtitleSidecar(from: url, to: target)
                }
            }
            .alert("New Folder", isPresented: $showNewFolder) {
                TextField("Folder name", text: $folderName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    appState.createFolder(named: folderName)
                    folderName = ""
                }
            } message: {
                Text("Create a new folder in the current directory.")
            }
            .alert("New Private Folder", isPresented: $showNewPrivateFolder) {
                TextField("Folder name", text: $folderName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    appState.createPrivateFolder(named: folderName)
                    folderName = ""
                }
            } message: {
                Text("Files inside a private folder are locked behind your PIN and hidden from the main library.")
            }
            .alert(appState.selectedDestination == .photos ? "New Photo Album" : "New Playlist", isPresented: $showNewPlaylist) {
                TextField(appState.selectedDestination == .photos ? "Album name" : "Playlist name", text: $playlistName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    let kind = appState.selectedDestination == .video ? "video" : (appState.selectedDestination == .photos ? "photo" : "audio")
                    appState.createPlaylist(named: playlistName, kind: kind)
                    playlistName = ""
                }
            } message: {
                Text("Create a new \(appState.selectedDestination == .photos ? "photo album" : (appState.selectedDestination == .video ? "video playlist" : "audio playlist")).")
            }
            .alert("Rename", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("Name", text: $renameText)
                    // Fresh field per presentation: a reused alert TextField keeps
                    // its previous editing session's text, so a cleared-then-canceled
                    // rename would reopen showing stale (empty) text.
                    .id(renameTarget?.id ?? "no-target")
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    if let target = renameTarget {
                        appState.rename(target, to: renameText)
                    }
                }
            } message: {
                Text("Enter a new name.")
            }
            .alert("Empty Trash?", isPresented: $showEmptyTrashAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Empty Trash", role: .destructive) {
                    appState.emptyTrash()
                }
            } message: {
                Text("Are you sure you want to permanently delete all items in the Trash? This action cannot be undone.")
            }
            .alert("Cascade", isPresented: Binding(
                get: { appState.alertMessage != nil },
                set: { if !$0 { appState.alertMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(appState.alertMessage ?? "")
            }
            .sheet(isPresented: Binding(
                get: { appState.isSharingFile || appState.shareResultLink != nil },
                set: {
                    if !$0 {
                        appState.shareResultLink = nil
                        appState.isSharingFile = false
                    }
                }
            )) {
                // Creating a share forwards the file's chunks into the share
                // channel — show progress so the user knows the action is running,
                // then swap to the link when it's ready.
                if appState.isSharingFile {
                    ShareProgressSheet()
                } else if let link = appState.shareResultLink {
                    ShareLinkSheet(link: link, fileCount: appState.shareResultFileCount)
                }
            }
            .sheet(isPresented: $showDuplicatesFinder) {
                DuplicatesReviewView()
                    .environment(appState)
            }
            .sheet(isPresented: Binding(
                get: { appState.versionHistoryTarget != nil },
                set: { if !$0 { appState.versionHistoryTarget = nil } }
            )) {
                if let target = appState.versionHistoryTarget {
                    VersionsSheet(file: target)
                        .environment(appState)
                }
            }
            .sheet(isPresented: Binding(
                get: { appState.movePickerTargets != nil },
                set: { if !$0 { appState.movePickerTargets = nil } }
            )) {
                if let targets = appState.movePickerTargets {
                    MoveDestinationSheet(targets: targets)
                        .environment(appState)
                }
            }
    }

    /// The destination's content area: Transfers and Shared have their own pages;
    /// everything else shows the file grid/list (or loading/empty states).
    /// Extracted so mainContent stays under the type-checker's expression limit.
    @ViewBuilder
    private var destinationContent: some View {
        if isSearching {
            if visibleFiles.isEmpty {
                emptyStateView
            } else {
                VStack(spacing: 16) {
                    if viewModeRaw == "list" { listView } else { gridView }
                    Spacer(minLength: 0)
                }
            }
        } else if appState.selectedDestination == .transfers {
            TransfersView()
        } else if appState.selectedDestination == .shared {
            ShareManagerView()
        } else if visibleFiles.isEmpty && !appState.isUploading {
            if appState.isInitialLoading {
                loadingStateView
            } else {
                emptyStateView
            }
        } else {
            VStack(spacing: 16) {
                if !visibleFiles.isEmpty {
                    if viewModeRaw == "list" { listView } else { gridView }
                }
                // While an upload is in progress the folder may still be
                // empty. Keep the content area filled so the VStack can't
                // collapse to just the top bar — the outer ZStack aligns
                // .bottomTrailing, so a collapsed stack pins the bar to
                // the bottom of the window.
                Spacer(minLength: 0)
            }
        }
    }

    private func searchScopeBar(scopeName: String) -> some View {
        HStack(spacing: 8) {
            Text("Search:")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    searchScope = .everywhere
                }
            } label: {
                Text("Everywhere")
                    .font(.system(size: 11, weight: searchScope == .everywhere ? .semibold : .regular))
                    .foregroundStyle(searchScope == .everywhere ? .white : .white.opacity(0.7))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background {
                        if searchScope == .everywhere {
                            Capsule().fill(Color.white.opacity(0.18))
                        } else {
                            Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                        }
                    }
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    searchScope = .currentFolder
                }
            } label: {
                Text("\"\(scopeName)\"")
                    .font(.system(size: 11, weight: searchScope == .currentFolder ? .semibold : .regular))
                    .foregroundStyle(searchScope == .currentFolder ? .white : .white.opacity(0.7))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background {
                        if searchScope == .currentFolder {
                            Capsule().fill(Color.white.opacity(0.18))
                        } else {
                            Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                        }
                    }
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.15))
        .overlay(alignment: .bottom) {
            Divider().overlay(.white.opacity(0.05))
        }
    }

    private var mainContent: some View {
        ZStack(alignment: .bottomTrailing) {
            AppBackground()

            VStack(spacing: 0) {
                if appState.selectedDestination == .privateVault && !appState.isPrivateVaultUnlocked {
                    PrivateVaultLockView()
                        .transition(.opacity)
                } else {
                    topBar

                    if isSearching, let scopeName = currentScopeName {
                        searchScopeBar(scopeName: scopeName)
                    }

                    destinationContent
                        // No transition here: crossfading between destinations
                        // made shared items visibly shuffle/morph from one page
                        // layout to another. Page switches are instant; motion
                        // lives in the content itself (progress, spinners).
                        .id("browser-\(appState.selectedDestination.rawValue)-\(appState.currentFolderID ?? "root")")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                appState.clearSelection()
            }
            .contextMenu {
                // Page menu on ANY empty area (not just cards): the whole content
                // region right-clicks to the page actions, while card/row menus
                // (deeper in the hierarchy) still win on individual items.
                // Transfers has its own page — no file-page menu there.
                if appState.selectedDestination != .transfers {
                    pageContextMenu
                }
            }

            // Floating Mini Audio Player (Centered at Bottom)
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    MiniPlayerView()
                    Spacer()
                }
            }

            // Morphing Liquid Glass Cell-Division FAB (bottom right)
            if appState.selectedDestination != .trash && appState.selectedDestination != .archive && (appState.selectedDestination != .privateVault || appState.isPrivateVaultUnlocked) {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        LiquidMorphingFAB(
                            showImporter: $showImporter,
                            showNewFolder: $showNewFolder,
                            showNewPrivateFolder: $showNewPrivateFolder,
                            folderName: $folderName
                        )
                    }
                }
                .padding(24)
            }
        }
        .ignoresSafeArea(edges: .top)
        .focusable()
        .focusEffectDisabled()
        .focused($gridFocused)
        .onKeyPress(.delete) {
            if appState.selectedDestination == .trash {
                showEmptyTrashAlert = true
                return .handled
            }
            guard !appState.selectedFiles.isEmpty else { return .ignored }
            let flags = NSEvent.modifierFlags
            if flags.contains(.command) && flags.contains(.option) {
                appState.bulkDeleteForever()
                return .handled
            } else {
                appState.bulkTrash()
                return .handled
            }
        }
        .onKeyPress(.escape) {
            if isSearching {
                appState.searchText = ""
                searchScope = .everywhere
                searchFocused = false
                return .handled
            }
            appState.clearSelection()
            return .handled
        }
        .onKeyPress("a", phases: .down) { press in
            // While the rename alert's field is up, Cmd+A belongs to the text
            // field (select-all text), not the file grid — let the event through.
            if renameTarget != nil { return .ignored }
            if press.modifiers.contains(.command) {
                appState.selectAll()
                return .handled
            }
            return .ignored
        }
        .onKeyPress("c", phases: .down) { press in
            if renameTarget != nil { return .ignored }
            if press.modifiers.contains(.command) {
                copySelectedFilesToClipboard()
                return .handled
            }
            return .ignored
        }
        .onKeyPress("v", phases: .down) { press in
            if renameTarget != nil { return .ignored }
            if press.modifiers.contains(.command) {
                pasteFromClipboard()
                return .handled
            }
            return .ignored
        }
        .onKeyPress("r", phases: .down) { press in
            if press.modifiers.contains(.command) {
                Task {
                    await appState.loadFiles(reconcileCloud: true)
                    appState.thumbnailVersion += 1
                }
                return .handled
            }
            return .ignored
        }
        .onKeyPress("z", phases: .down) { press in
            // Finder-style undo/redo for moves, trash, restore, rename, favorites.
            // Leave Cmd+Z to the search field's own text undo while it's focused.
            guard press.modifiers.contains(.command), !searchFocused else { return .ignored }
            if press.modifiers.contains(.shift) {
                appState.redo()
            } else {
                appState.undo()
            }
            return .handled
        }
        .onChange(of: appState.theaterFile?.id) { _, newID in
            // When the viewer closes, hand keyboard control back to the browser so
            // space re-opens the preview and arrows move the selection again.
            if newID == nil {
                gridFocused = true
            }
        }
        .onChange(of: appState.readerFile?.id) { _, newID in
            if newID == nil {
                gridFocused = true
            }
        }
        .onKeyPress("o", phases: .down) { press in
            if press.modifiers.contains(.command), let f = appState.selectedFile {
                open(f)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.downArrow, phases: .down) { press in
            if press.modifiers.contains(.command), let f = appState.selectedFile {
                open(f)
                return .handled
            }
            return keyNav(1, isVertical: true) ? .handled : .ignored
        }
        .onKeyPress(.upArrow, phases: .down) { press in
            if press.modifiers.contains(.command) {
                appState.navigateBack()
                return .handled
            }
            return keyNav(-1, isVertical: true) ? .handled : .ignored
        }
        .onKeyPress(.leftArrow)  { keyNav(-1, isVertical: false) ? .handled : .ignored }
        .onKeyPress(.rightArrow) { keyNav(1, isVertical: false) ? .handled : .ignored }
        .onKeyPress(.space) {
            if let file = appState.selectedFile {
                quickLook(file)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.return) {
            if let f = appState.selectedFile { open(f); return .handled }
            return .ignored
        }
        .background {
            // Reliable key handling regardless of SwiftUI focus (see FileBrowserKeyView).
            // Covers arrow/column navigation, space/return, and the ⌘C/⌘V/⌘R/⌘O/⌘Z
            // shortcuts that the Edit menu's key equivalents would otherwise swallow
            // (NSText.paste no-ops when no text field is focused).
            FileBrowserKeyMonitorView(
                shouldDefer: {
                    appState.theaterFile != nil
                        || appState.readerFile != nil
                        || AudioPlayerEngine.shared.isFullScreen
                        || appState.selectedDestination == .transfers
                        || appState.selectedDestination == .shared
                },
                onMediaPlayPause: {
                    // Media keys (F8 / NX play): own them whenever a track is
                    // loaded — the mini player is the only audio surface here
                    // (the theater's own monitor handles them while it's open).
                    // consumeMediaKeyPress dedupes against MPRemoteCommandCenter
                    // (the app claims now-playing, so one press arrives twice).
                    guard AudioPlayerEngine.shared.currentTrack != nil,
                          appState.theaterFile == nil,
                          !AudioPlayerEngine.shared.isFullScreen,
                          AudioPlayerEngine.consumeMediaKeyPress() else { return false }
                    AudioPlayerEngine.shared.togglePlayPause()
                    return true
                },
                onMediaForward: {
                    guard AudioPlayerEngine.shared.currentTrack != nil,
                          appState.theaterFile == nil,
                          !AudioPlayerEngine.shared.isFullScreen,
                          AudioPlayerEngine.consumeMediaKeyPress() else { return false }
                    AudioPlayerEngine.shared.skipNext()
                    return true
                },
                onMediaBackward: {
                    guard AudioPlayerEngine.shared.currentTrack != nil,
                          appState.theaterFile == nil,
                          !AudioPlayerEngine.shared.isFullScreen,
                          AudioPlayerEngine.consumeMediaKeyPress() else { return false }
                    AudioPlayerEngine.shared.skipPrevious()
                    return true
                },
                onDelete: {
                    if appState.selectedDestination == .trash {
                        showEmptyTrashAlert = true
                        return true
                    }
                    guard !appState.selectedFiles.isEmpty else { return false }
                    appState.bulkTrash()
                    return true
                },
                onDeleteForever: {
                    if appState.selectedDestination == .trash {
                        showEmptyTrashAlert = true
                        return true
                    }
                    guard !appState.selectedFiles.isEmpty else { return false }
                    appState.bulkDeleteForever()
                    return true
                },
                onEscape: {
                    appState.clearSelection()
                    return true
                },
                onArrow: { delta, isVertical in
                    keyNav(delta, isVertical: isVertical)
                },
                onCmdUp: {
                    appState.navigateBack()
                    return true
                },
                onCmdDown: {
                    if let f = appState.selectedFile {
                        open(f)
                    } else {
                        keyNav(1, isVertical: true)
                    }
                    return true
                },
                onSpace: {
                    guard let file = appState.selectedFile else { return false }
                    quickLook(file)
                    return true
                },
                onReturn: {
                    guard let f = appState.selectedFile else { return false }
                    open(f)
                    return true
                },
                onCmdC: {
                    guard !appState.selectedFiles.isEmpty else { return false }
                    copySelectedFilesToClipboard()
                    return true
                },
                onCmdV: {
                    pasteFromClipboard()
                    return true
                },
                onCmdR: {
                    Task {
                        await appState.loadFiles()
                        appState.thumbnailVersion += 1
                    }
                    return true
                },
                onCmdO: {
                    guard let f = appState.selectedFile else { return false }
                    open(f)
                    return true
                },
                onCmdZ: { isShift in
                    if isShift {
                        appState.redo()
                    } else {
                        appState.undo()
                    }
                    return true
                }
            )
            .frame(width: 0, height: 0)
        }
        .onDrop(of: [UTType.item], isTargeted: $dropTargeted) { providers in
            importDrops(providers)
        }
        .overlay {
            if dropTargeted { dropOverlay }
        }
        .onReceive(NotificationCenter.default.publisher(for: .xcThumbnailReady)) { _ in
            // A thumbnail/cover landed in the background (warm-up, thumbnail-only
            // download, or a just-finished download) — re-key the standard grid's
            // cells (including Library poster cards) so it picks it up live,
            // instead of waiting for a manual ⌘R.
            appState.thumbnailVersion += 1
        }
    }

    // MARK: - Top Bar

    /// Right-click menu for a page's empty area. Carries the page-specific actions
    /// (New Album/Playlist, Lock Now, Empty Trash) so the top bar stays uniform and
    /// the search bar can be perfectly centered on every page.
    @ViewBuilder
    private var pageContextMenu: some View {
        if canUploadOnThisPage {
            Button("Upload Files…") { showImporter = true }
        }

        // Wave 2 item 7 — duplicate finder (All Files only; needs the whole
        // catalog, which that destination aggregates).
        if appState.selectedDestination == .allFiles {
            Button("Find Duplicates…") {
                showDuplicatesFinder = true
            }
        }

        if appState.selectedDestination == .trash {
            if !visibleFiles.isEmpty {
                Button("Empty Trash", role: .destructive) {
                    showEmptyTrashAlert = true
                }
            }
        } else if appState.selectedDestination != .shared {
            createMenuItems
        }

        if appState.selectedDestination == .privateVault && appState.isPrivateVaultUnlocked {
            Divider()
            Button("Lock Now") {
                appState.isPrivateVaultUnlocked = false
            }
        }

        Divider()
        Menu("Sort By") { sortPickerContent }
    }

    private var canUploadOnThisPage: Bool {
        // The Shared page lists handed-out links, not files — uploading/creating
        // there would be meaningless.
        appState.selectedDestination != .trash
            && appState.selectedDestination != .archive
            && appState.selectedDestination != .shared
    }

    @ViewBuilder
    private var createMenuItems: some View {
        Button("New Folder") {
            folderName = ""
            showNewFolder = true
        }
        Button("New Private Folder") {
            folderName = ""
            showNewPrivateFolder = true
        }
        if appState.selectedDestination == .photos {
            Button("New Album") {
                playlistName = ""
                showNewPlaylist = true
            }
        } else if appState.selectedDestination == .video || appState.selectedDestination == .audio {
            Button("New Playlist") {
                playlistName = ""
                showNewPlaylist = true
            }
        }
    }

    /// Whether the top-bar sort button shows on the current page: only where
    /// the listing honors sortOption (folder browsing, favorites, documents,
    /// library, archive, audio). Recent is MRU-ordered, Trash/Transfers/
    /// Shared aren't sortable listings, and Photos/Videos carry their own
    /// day-grouped order.
    private var showsSortButton: Bool {
        switch appState.selectedDestination {
        case .allFiles, .privateVault, .favorites, .documents, .library, .archive, .audio:
            return true
        case .recent, .trash, .transfers, .shared, .photos, .video:
            return false
        }
    }

    @ViewBuilder
    private var sortPickerContent: some View {
        Picker("Sort By", selection: Binding(
            get: { sortOption },
            set: { newOption in
                if sortOption == newOption {
                    sortAscending.toggle()
                } else {
                    sortOption = newOption
                    sortAscending = (newOption == .name || newOption == .kind)
                }
            }
        )) {
            ForEach(SortOption.allCases) { option in
                Text(option.rawValue).tag(option)
            }
        }
        .pickerStyle(.inline)

        Divider()

        Picker("Order", selection: $sortAscending) {
            Text(sortOption == .name ? "Ascending (A to Z)" : (sortOption == .size ? "Ascending (Smallest First)" : "Ascending (Oldest First)")).tag(true)
            Text(sortOption == .name ? "Descending (Z to A)" : (sortOption == .size ? "Descending (Largest First)" : "Descending (Newest First)")).tag(false)
        }
        .pickerStyle(.inline)
    }

    private var topBarTopPadding: CGFloat {
        XTheme.topBarTopPadding(isFullScreen: appState.isWindowFullScreen)
    }

    private var topBar: some View {
        @Bindable var appState = appState
        return HStack(spacing: 10) {            // LEFT — page heading
            HStack(spacing: 10) {
                if appState.currentFolderID != nil {
                    Button {
                        appState.navigateBack()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.08))
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                        .frame(width: 32, height: 32)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Back")
                }

                Text(headingTitle)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text("\(visibleFiles.count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.white.opacity(0.08)))
            }
            .frame(width: 210, alignment: .leading)

            Spacer(minLength: 8)

            // CENTER — search. The left/right sides reserve symmetric 210pt, so the
            // search stays perfectly centered on every page; it shrinks instead of
            // overlapping the side controls in narrow windows.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                TextField("Search across Cascade…", text: $appState.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .focused($searchFocused)
                if !appState.searchText.isEmpty {
                    Button {
                        appState.searchText = ""
                        searchScope = .everywhere
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 140, maxWidth: 360)
            .frame(height: 35)
            .contentShape(Capsule())
            .glassEffect(searchFocused ? .regular.interactive() : .regular, in: .capsule)
            .overlay(
                Capsule()
                    .strokeBorder(
                        searchFocused ? XTheme.accent : Color.white.opacity(0.12),
                        lineWidth: searchFocused ? 1.5 : 1
                    )
            )
            .shadow(color: searchFocused ? XTheme.accent.opacity(0.4) : .clear, radius: 8, y: 0)
            .animation(.easeInOut(duration: 0.15), value: searchFocused)
            .onTapGesture { searchFocused = true }
            .background(
                Button("") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .hidden()
            )

            Spacer(minLength: 8)

            // RIGHT — controls. Uniform on every page (page-specific actions like
            // New Album/Playlist, Lock Now, Empty Trash live in the context menu).
            HStack(spacing: 10) {
                // View Mode Toggle (Grid / List) with Liquid Glass pill transition
                HStack(spacing: 0) {
                    ForEach(["grid", "list"], id: \.self) { mode in
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                viewModeRaw = mode
                            }
                        } label: {
                            Image(systemName: mode == "grid" ? "square.grid.2x2.fill" : "list.bullet")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(viewModeRaw == mode ? .white : .white.opacity(0.5))
                                .frame(width: 34, height: 28)
                                .contentShape(Rectangle())
                                .background {
                                    if viewModeRaw == mode {
                                        Capsule()
                                            .fill(XTheme.accent)
                                            .glassEffect(.regular.interactive(), in: .capsule)
                                            .matchedGeometryEffect(id: "viewModePill", in: viewModeNamespace)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .glassEffect(.regular, in: .capsule)

                // Sort Menu Button — only where the listing honors it. Recent
                // is MRU-ordered (sorting would destroy its meaning, and the
                // page early-returns past the sort switch anyway), Trash /
                // Transfers / Shared aren't sortable listings, and Photos /
                // Videos grids carry their own day-grouped order.
                if showsSortButton {
                    Menu {
                        sortPickerContent
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.system(size: 11, weight: .bold))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 46, height: 28)
                        .contentShape(Capsule())
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.plain)
                    .help("Sort options")
                }
            }
            .frame(width: 210, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .frame(height: XTheme.topBarBaseHeight)
        .padding(.top, topBarTopPadding)
        .background(.black.opacity(0.22), ignoresSafeAreaEdges: .top)
        .overlay(alignment: .bottom) {
            Divider().overlay(.white.opacity(0.08))
        }
    }

    private var headingTitle: String {
        if isSearching {
            return "Search Results"
        }
        if let folder = appState.files.first(where: { $0.id == appState.currentFolderID }) {
            return folder.name
        }
        return appState.selectedDestination.title
    }

    // MARK: - FAB + Transfer Pill

    private var activeTransfers: [TransferCenter.Item] {
        TransferCenter.shared.items.filter { $0.state == .active }
    }

    private var overallProgress: Double {
        guard !activeTransfers.isEmpty else { return 0 }
        let total = activeTransfers.reduce(0.0) { $0 + $1.progress }
        return total / Double(activeTransfers.count)
    }

    @ViewBuilder
    private var morphingFloatingButton: some View {
        if let item = activeTransfers.first {
            // ACTIVE TRANSFERS: Liquid Glass Morphing Transfer Pill Button
            Button {
                showMiniTransfersPopover.toggle()
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .stroke(.white.opacity(0.15), lineWidth: 3)
                            .frame(width: 28, height: 28)
                        Circle()
                            .trim(from: 0, to: max(0.05, overallProgress))
                            .stroke(
                                XTheme.brandGradient,
                                style: StrokeStyle(lineWidth: 3, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .frame(width: 28, height: 28)

                        Image(systemName: item.direction == .upload ? "arrow.up" : "arrow.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }

                    Text("\(Int(overallProgress * 100))%")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)

                    if activeTransfers.count > 1 {
                        Text("(\(activeTransfers.count))")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular.interactive(), in: .capsule)
                .shadow(color: XTheme.accent.opacity(0.35), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showMiniTransfersPopover, arrowEdge: .bottom) {
                MiniTransfersView()
            }
            .transition(.scale.combined(with: .opacity))
        } else {
            // IDLE: Standard Floating (+) Add Button
            fabButton
                .transition(.scale.combined(with: .opacity))
        }
    }

    private var fabButton: some View {
        Menu {
            Button { showImporter = true } label: {
                Label(appState.selectedDestination == .privateVault ? "Upload to Locked" : "Upload File", systemImage: "arrow.up.doc.fill")
            }
            Divider()
            if appState.selectedDestination == .privateVault {
                Button {
                    folderName = ""
                    showNewPrivateFolder = true
                } label: {
                    Label("New Private Folder", systemImage: "number")
                }
            } else {
                if appState.selectedDestination == .audio || appState.selectedDestination == .video {
                    Button {
                        playlistName = ""
                        showNewPlaylist = true
                    } label: {
                        Label("New Playlist", systemImage: "plus.square.on.square")
                    }
                }
                Button {
                    folderName = ""
                    showNewFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Circle().fill(XTheme.accent.opacity(0.35)))
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
    }

    // MARK: - Grid

    private var currentFolders: [ObjectRecord] {
        visibleFiles.filter(\.isFolder)
    }

    private var currentFiles: [ObjectRecord] {
        visibleFiles.filter { !$0.isFolder }
    }

    /// One visible list row: the record plus its Finder-style nesting depth.
    private struct ListNode: Identifiable {
        let file: ObjectRecord
        let depth: Int
        var id: String { file.id }
    }

    /// Flat visible order for list view: top-level folders (with expanded
    /// subtrees inlined beneath their parents), then top-level files. Drives
    /// both rendering and arrow-key navigation so the two never disagree.
    private var visibleListNodes: [ListNode] {
        var nodes: [ListNode] = []
        var visited = Set<String>()
        for folder in currentFolders {
            nodes.append(ListNode(file: folder, depth: 0))
            appendChildNodes(parentID: folder.id, depth: 1, to: &nodes, visited: &visited)
        }
        for file in currentFiles {
            nodes.append(ListNode(file: file, depth: 0))
        }
        return nodes
    }

    private func appendChildNodes(parentID: String, depth: Int, to nodes: inout [ListNode], visited: inout Set<String>) {
        // Cycle-safe: a corrupt parent graph must never recurse forever.
        guard expandedFolderIDs.contains(parentID), !visited.contains(parentID) else { return }
        visited.insert(parentID)
        for kid in nestedChildren(of: parentID) {
            nodes.append(ListNode(file: kid, depth: depth))
            if kid.isFolder {
                appendChildNodes(parentID: kid.id, depth: depth + 1, to: &nodes, visited: &visited)
            }
        }
    }

    /// A folder's real contents for inline expansion: ready items, trashed
    /// iff on the Trash page, archived hidden except on Archive, private
    /// matching the page (vault-only in the vault). Folders first, then files,
    /// by name — Finder order within each level.
    private func nestedChildren(of parentID: String) -> [ObjectRecord] {
        let pool = appState.files.filter { $0.state == "ready" && $0.parentID == parentID }
        let trashedOK = appState.selectedDestination == .trash
        let showArchived = appState.selectedDestination == .archive
        let kids = pool.filter { kid in
            guard kid.trashed == trashedOK else { return false }
            guard showArchived || !kid.isArchived else { return false }
            switch appState.selectedDestination {
            case .privateVault:
                return kid.isPrivate
            case .library, .archive, .trash, .recent:
                return true
            default:
                return !kid.isPrivate
            }
        }
        return kids.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func toggleExpand(_ id: String) {
        if expandedFolderIDs.contains(id) {
            expandedFolderIDs.remove(id)
        } else {
            expandedFolderIDs.insert(id)
        }
    }

    private var gridView: some View {
        if appState.selectedDestination == .photos {
            return AnyView(
                PhotosGridView(
                    files: visibleFiles,
                    showsCollections: appState.currentFolderID == nil,
                    onOpen: { open($0) },
                    onSelect: { select($0) },
                    menuProvider: { AnyView(menu(for: $0)) },
                    onOrderedChange: { appState.mediaOrderedIDs = $0 },
                    onColumnCountChange: { mediaColumnCount = $0; appState.gridColumnCount = $0 },
                    scrollTargetID: $scrollTargetID
                )
            )
        }
        if appState.selectedDestination == .video {
            return AnyView(
                VideosGridView(
                    files: visibleFiles,
                    showsCollections: appState.currentFolderID == nil,
                    onOpen: { open($0) },
                    onSelect: { select($0) },
                    menuProvider: { AnyView(menu(for: $0)) },
                    onOrderedChange: { appState.mediaOrderedIDs = $0 },
                    onColumnCountChange: { mediaColumnCount = $0; appState.gridColumnCount = $0 },
                    scrollTargetID: $scrollTargetID
                )
            )
        }
        return AnyView(standardGridView)
    }

    private var standardGridView: some View {
        GeometryReader { geo in
            let cols = max(2, Int(geo.size.width / cardWidth))
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    // Folders on top, files below — no section headings
                    // (Finder scheme, followed on every page).
                    if !currentFolders.isEmpty {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: cols),
                            spacing: 28
                        ) {
                            ForEach(currentFolders) { folder in
                                FileGridItem(file: folder, isSelected: appState.selectedFiles.contains(folder.id), renameTarget: $renameTarget, renameText: $renameText)
                                    .onTapGesture(count: 2) { open(folder) }
                                    .simultaneousGesture(TapGesture(count: 1).onEnded { select(folder) })
                                    .contextMenu { menu(for: folder) }
                                    .onDrag { dragProvider(for: folder) }
                                    .reportGridFrame(id: folder.id)
                            }
                        }
                    }

                    if !currentFiles.isEmpty {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: cols),
                            spacing: 28
                        ) {
                            ForEach(currentFiles) { file in
                                FileGridItem(file: file, isSelected: appState.selectedFiles.contains(file.id), renameTarget: $renameTarget, renameText: $renameText)
                                    .onTapGesture(count: 2) { open(file) }
                                    .simultaneousGesture(TapGesture(count: 1).onEnded { select(file) })
                                    .contextMenu { menu(for: file) }
                                    .onDrag { dragProvider(for: file) }
                                    .reportGridFrame(id: file.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 80)
                .coordinateSpace(name: "gridContent")
                .onPreferenceChange(GridFrameKey.self) { itemFrames = $0 }
                .background {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(marqueeDrag)
                }
                .overlay(alignment: .topLeading) { marqueeOverlay }
            }
            .onChange(of: geo.size.width, initial: true) {
                columnCount = max(2, Int(geo.size.width / cardWidth))
                appState.gridColumnCount = columnCount
            }
            .onChange(of: scrollTargetID) { _, newID in
                guard let newID else { return }
                proxy.scrollTo(newID, anchor: nil)
            }
            .onAppear {
                // Reveal-in-folder: the grid mounts fresh after the destination
                // switch, so scroll to the revealed object once layout settles.
                if let id = appState.revealObjectID {
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: nil) }
                }
            }
            .onChange(of: appState.revealToken) { _, _ in
                if let id = appState.revealObjectID {
                    proxy.scrollTo(id, anchor: nil)
                }
            }
            }
        }
    }

    // MARK: - List

    private var listView: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(visibleListNodes, id: \.file.id) { node in
                    FileListRow(
                        file: node.file,
                        isSelected: appState.selectedFiles.contains(node.file.id),
                        depth: node.depth,
                        isExpanded: expandedFolderIDs.contains(node.file.id),
                        hasChildren: node.file.isFolder && !nestedChildren(of: node.file.id).isEmpty,
                        onToggleExpand: { toggleExpand(node.file.id) }
                    )
                        .onTapGesture(count: 2) { open(node.file) }
                        .simultaneousGesture(TapGesture(count: 1).onEnded { select(node.file) })
                        .contextMenu { menu(for: node.file) }
                        .onDrag { dragProvider(for: node.file) }
                        .reportGridFrame(id: node.file.id)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 80)
            .coordinateSpace(name: "gridContent")
            .onPreferenceChange(GridFrameKey.self) { itemFrames = $0 }
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(marqueeDrag)
            }
            .overlay(alignment: .topLeading) { marqueeOverlay }
        }
        .onChange(of: scrollTargetID) { _, newID in
            guard let newID else { return }
            proxy.scrollTo(newID, anchor: nil)
        }
        .onAppear {
            if let id = appState.revealObjectID {
                DispatchQueue.main.async { proxy.scrollTo(id, anchor: nil) }
            }
        }
        .onChange(of: appState.revealToken) { _, _ in
            if let id = appState.revealObjectID {
                proxy.scrollTo(id, anchor: nil)
            }
        }
        }
    }

    // MARK: - Marquee (rectangle) selection & multi-drag

    private var marqueeDrag: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("gridContent"))
            .onChanged { value in
                if marqueeStart == nil {
                    // A press that begins in the content (not on a card) moves
                    // keyboard focus here from the sidebar.
                    appState.isSidebarFocused = false
                    // Never start a marquee when the press began on a file card.
                    let beganOnItem = itemFrames.values.contains { $0.contains(value.startLocation) }
                    guard !beganOnItem else { return }
                    marqueeStart = value.startLocation
                    if !NSEvent.modifierFlags.contains(.command) {
                        appState.clearSelection()
                    }
                }
                marqueeCurrent = value.location
            }
            .onEnded { _ in
                defer { marqueeStart = nil; marqueeCurrent = nil }
                guard let start = marqueeStart, let current = marqueeCurrent else { return }
                let rect = marqueeRect(from: start, to: current)
                let hit = Set(itemFrames.filter { $0.value.intersects(rect) }.map(\.key))
                if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
                    appState.selectedFiles.formUnion(hit)
                } else {
                    appState.selectedFiles = hit
                }
            }
    }

    @ViewBuilder
    private var marqueeOverlay: some View {
        if let start = marqueeStart, let current = marqueeCurrent {
            let rect = marqueeRect(from: start, to: current)
            Rectangle()
                .fill(XTheme.accent.opacity(0.12))
                .overlay(
                    Rectangle().strokeBorder(XTheme.accent.opacity(0.7), lineWidth: 1)
                )
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }

    private func marqueeRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x), y: min(a.y, b.y),
            width: abs(a.x - b.x), height: abs(a.y - b.y)
        )
    }

    /// Drags the whole selection when the dragged file is part of it (Finder behavior).
    /// Payload is a newline-joined list of object IDs, parsed by the drop targets.
    private func dragProvider(for file: ObjectRecord) -> NSItemProvider {
        let ids = appState.selectedFiles.contains(file.id)
            ? Array(appState.selectedFiles)
            : [file.id]
        return NSItemProvider(object: ids.joined(separator: "\n") as NSString)
    }

    // MARK: - Actions

    private func open(_ file: ObjectRecord) {
        appState.isSidebarFocused = false
        if file.isFolder {
            appState.searchText = ""
            searchScope = .everywhere
            appState.openFolder(file)
        } else if file.isBook {
            // Books open in the dedicated reader (Library page or anywhere else).
            appState.readerFile = file
        } else if isPDF(file) {
            // PDFs open in the reader too: it streams from the vault (byte
            // ranges) instead of the Theater's metadata panel + manual Preview.
            appState.readerFile = file
        } else if appState.selectedDestination == .audio {
            AudioPlayerEngine.shared.play(file: file, in: visibleFiles)
        } else if PictureInPictureWindow.shared.isShowing(file.id) {
            // Wave 2 item 5 UX: opening the video that's floating in PiP
            // EXPANDS it back into the theater at its position.
            PictureInPictureWindow.shared.expandToTheater()
        } else {
            appState.theaterFile = file
        }
    }

    /// Finder-style Quick Look: space previews the selected item. Books open in
    /// the dedicated reader; folders and unsupported files show a details panel;
    /// it never navigates into folders (double-click / Enter still do that via
    /// `open`).
    private func quickLook(_ file: ObjectRecord) {
        if file.isBook {
            appState.readerFile = file
        } else if isPDF(file) {
            appState.readerFile = file
        } else if appState.selectedDestination == .audio, !file.isFolder {
            AudioPlayerEngine.shared.play(file: file, in: visibleFiles)
        } else if PictureInPictureWindow.shared.isShowing(file.id) {
            PictureInPictureWindow.shared.expandToTheater()
        } else {
            appState.theaterFile = file
        }
    }

    private func isPDF(_ file: ObjectRecord) -> Bool {
        let ext = (file.name as NSString).pathExtension.lowercased()
        return file.mime.contains("pdf") || ext == "pdf"
    }

    private func isAudioFile(_ file: ObjectRecord) -> Bool {
        let ext = (file.name as NSString).pathExtension.lowercased()
        return file.mime.hasPrefix("audio/") || ["mp3", "m4a", "wav", "flac", "aac", "ogg"].contains(ext)
    }

    private var navigableFiles: [ObjectRecord] {
        if mediaGridActive {
            return appState.mediaOrderedIDs.compactMap { id in appState.files.first(where: { $0.id == id }) }
        }
        // List view walks the visible flattened order (expanded subtrees
        // inline); grid view walks folders-then-files.
        if viewModeRaw == "list" {
            return visibleListNodes.map { $0.file }
        }
        return currentFolders + currentFiles
    }

    /// The Photos/Videos pages use their own boxy grids (adaptive columns,
    /// albums-first ordering) — arrow navigation walks THEIR visual order.
    private var mediaGridActive: Bool {
        (appState.selectedDestination == .photos || appState.selectedDestination == .video)
            && viewModeRaw == "grid"
    }

    @discardableResult
    private func keyNav(_ delta: Int, isVertical: Bool = false) -> Bool {
        // While the sidebar has focus (last click was a sidebar row), up/down
        // moves the sidebar selection — content selection stays cleared.
        // Left/right, or any content tap, hands focus back to the content.
        if appState.isSidebarFocused, isVertical {
            Self.keyNavLogger.log("keyNav: sidebar-owned (delta=\(delta, privacy: .public))")
            appState.moveSidebarSelection(delta: delta)
            return true
        }
        appState.isSidebarFocused = false
        let files = navigableFiles
        // Nothing to move through (e.g. Shared/Transfers pages list no
        // files): do NOT consume — the page's own key monitor is newer and
        // must still see the event regardless of monitor fire order.
        guard !files.isEmpty else { return false }
        guard let current = files.firstIndex(where: { appState.selectedFiles.contains($0.id) }) else {
            appState.selectedFiles = [files[0].id]
            scrollTargetID = files[0].id
            Self.keyNavLogger.log("keyNav: no selection -> selected first of \(files.count, privacy: .public) (folders=\(files.filter(\.isFolder).count, privacy: .public))\(files[0].isFolder ? " [folder]" : "")")
            return true
        }

        let nextIndex: Int
        if isVertical && viewModeRaw == "grid" {
            nextIndex = gridVerticalNavigation(current: current, delta: delta, files: files)
        } else {
            nextIndex = min(max(current + delta, 0), files.count - 1)
        }
        appState.selectedFiles = [files[nextIndex].id]
        scrollTargetID = files[nextIndex].id
        Self.keyNavLogger.log("keyNav: delta=\(delta, privacy: .public) vertical=\(isVertical, privacy: .public) total=\(files.count, privacy: .public) folders=\(files.filter(\.isFolder).count, privacy: .public) cols=\(columnCount, privacy: .public) cur=\(current, privacy: .public)(\(files[current].isFolder ? "folder" : "file")) -> next=\(nextIndex, privacy: .public)(\(files[nextIndex].isFolder ? "folder" : "file"))\(files[nextIndex].isFolder ? " " + files[nextIndex].name : "")")
        return true
    }

    private static let keyNavLogger = Logger(
        subsystem: "com.cascade.app",
        category: "keynav"
    )

    /// Row-aware up/down navigation for the stacked grids (folders grid, then
    /// files grid — both at the same column count since Round 208). Moves to
    /// the item in the same column of the next/previous row — so going down
    /// from a folder selects the file directly beneath it (or the folder
    /// below, when a second folder row exists), instead of jumping by a fixed
    /// column count that lands on the wrong row.
    private func gridVerticalNavigation(current: Int, delta: Int, files: [ObjectRecord]) -> Int {
        FileBrowserView.gridVerticalStep(current: current, delta: delta, files: files, cols: mediaGridActive ? mediaColumnCount : columnCount)
    }

    /// Pure grid row/column math (static so it's unit-testable). `files` must be the
    /// navigable list (folders first, then files). Returns the flat index to select.
    static func gridVerticalStep(current: Int, delta: Int, files: [ObjectRecord], cols: Int) -> Int {
        let cols = max(2, cols)
        // Folders and files share one column count (Round 208 unified the two
        // grids — the old min(cols, 4) folder cap mis-mapped rows on wide
        // windows and broke up/down navigation).
        let folderCols = cols
        let folderCount = files.prefix { $0.isFolder }.count
        let folderRows = folderCount == 0 ? 0 : (folderCount + folderCols - 1) / folderCols

        // Visual (row, col) of every item: folders occupy the first rows, files after.
        var positions: [(row: Int, col: Int)] = []
        positions.reserveCapacity(files.count)
        for i in 0..<files.count {
            if i < folderCount {
                positions.append((i / folderCols, i % folderCols))
            } else {
                let j = i - folderCount
                positions.append((folderRows + j / cols, j % cols))
            }
        }

        let currentPos = positions[current]
        let targetRow = currentPos.row + delta
        guard positions.contains(where: { $0.row == targetRow }) else { return current }

        // Prefer the exact same column; fall back to the closest column in that row
        // (handles the folder row having fewer columns than the files grid).
        var best = current
        var bestColDist = Int.max
        for (index, pos) in positions.enumerated() where pos.row == targetRow {
            let dist = abs(pos.col - currentPos.col)
            if dist == 0 { return index }
            if dist < bestColDist {
                bestColDist = dist
                best = index
            }
        }
        return best
    }

    private func select(_ file: ObjectRecord) {
        appState.isSidebarFocused = false
        let isCmd = NSEvent.modifierFlags.contains(.command)
        if isCmd {
            if appState.selectedFiles.contains(file.id) {
                appState.selectedFiles.remove(file.id)
            } else {
                appState.selectedFiles.insert(file.id)
            }
        } else {
            appState.selectedFiles = [file.id]
        }
    }

    private func copySelectedFilesToClipboard() {
        let selectedIDs = appState.selectedFiles
        let targetFiles = visibleFiles.filter { selectedIDs.contains($0.id) }
        guard !targetFiles.isEmpty else { return }

        let pb = NSPasteboard.general
        pb.clearContents()

        var fileURLs: [NSURL] = []
        var fileNames: [String] = []

        for file in targetFiles {
            if DownloadEngine.isCached(file) {
                let localURL = DownloadEngine.cacheURL(for: file)
                fileURLs.append(localURL as NSURL)
            }
            fileNames.append(file.name)
        }

        if !fileURLs.isEmpty {
            pb.writeObjects(fileURLs)
        } else {
            pb.setString(fileNames.joined(separator: "\n"), forType: .string)
        }
    }

    private func pasteFromClipboard() {
        let pb = NSPasteboard.general

        // 0. Check for Cascade Share Link copied to clipboard
        if let string = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           string.hasPrefix("cascade://share") {
            appState.importShareLink(string)
            return
        }

        // 1. Check for File URLs copied from Finder, Desktop, Downloads, etc.
        var targetURLs: [URL] = []
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            targetURLs = urls
        } else if let paths = pb.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String], !paths.isEmpty {
            targetURLs = paths.map { URL(fileURLWithPath: $0) }
        }

        if !targetURLs.isEmpty {
            for url in targetURLs {
                appState.startUpload(url: url)
            }
            return
        }

        // 2. Check for Copied Image Data (Screenshots, browser images)
        if let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            if let pngData = rep.representation(using: .png, properties: [:]) {
                let tempDir = FileManager.default.temporaryDirectory
                let fileName = "Pasted_Image_\(Int(Date().timeIntervalSince1970)).png"
                let tempURL = tempDir.appendingPathComponent(fileName)
                try? pngData.write(to: tempURL)
                appState.startUpload(url: tempURL)
                return
            }
        }
    }

    private func importDrops(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers
        where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in appState.startUpload(url: url) }
            }
            handled = true
        }
        return handled
    }

    @ViewBuilder
    private func menu(for file: ObjectRecord) -> some View {
        FileItemContextMenu(file: file, renameTarget: $renameTarget, renameText: $renameText)
    }

    // MARK: - Drop overlay

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(
                XTheme.accent.opacity(0.7),
                style: StrokeStyle(lineWidth: 2, dash: [10, 8])
            )
            .background(.black.opacity(0.3))
            .overlay(
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(XTheme.accent)
                    Text("Drop to upload")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
            )
            .padding(20)
            .allowsHitTesting(false)
    }

    // MARK: - Breadcrumbs & Empty

    private var breadcrumbBar: some View {
        HStack(spacing: 4) {
            ForEach(Array(appState.breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(XTheme.textTertiary)
                }
                Button(crumb.name) {
                    appState.navigateTo(crumb.id)
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: index == appState.breadcrumbs.count - 1 ? .bold : .medium))
                .foregroundStyle(index == appState.breadcrumbs.count - 1 ? .white : XTheme.textSecondary)
                .disabled(index == appState.breadcrumbs.count - 1)
            }
            Spacer()
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: emptyIcon)
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(XTheme.brandGradient)

            Text(emptyTitle)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)

            Text(emptySubtitle)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            if isSearching {
                Button {
                    appState.searchText = ""
                    searchScope = .everywhere
                } label: {
                    Label("Clear Search", systemImage: "xmark.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
            } else if appState.selectedDestination == .allFiles || appState.selectedDestination == .privateVault {
                Button {
                    showImporter = true
                } label: {
                    Label("Upload Files", systemImage: "arrow.up.doc.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(XTheme.brandGradient))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(40)
        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .contextMenu { pageContextMenu }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Shown while the app is still loading the catalog at startup. A YouTube-style
    /// skeleton feed of placeholder cards (not the empty state) so the user never
    /// sees a misleading "Nothing Here Yet" flash before the files appear.
    private var loadingStateView: some View {
        GeometryReader { geo in
            let cols = max(2, Int(geo.size.width / cardWidth))
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    // Folders section skeleton (two rows so the feed feels full)
                    ForEach(0..<2, id: \.self) { _ in
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: cols),
                            spacing: 28
                        ) {
                            ForEach(0..<cols, id: \.self) { _ in
                                folderSkeletonCard
                            }
                        }
                    }

                    // Files section skeleton
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: cols),
                        spacing: 28
                    ) {
                        ForEach(0..<(cols * 3), id: \.self) { _ in
                            fileSkeletonCard
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 80)
            }
        }
    }

    private var folderSkeletonCard: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .frame(width: 132, height: 132)

            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 90, height: 10)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 56, height: 8)
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(width: 140, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .center)
        .modifier(ShimmerModifier())
    }

    private var fileSkeletonCard: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .frame(width: 132, height: 132)

            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 110, height: 10)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 48, height: 8)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 40, height: 8)
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(width: 140, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .center)
        .modifier(ShimmerModifier())
    }

    private var emptyIcon: String {
        if isSearching { return "magnifyingglass" }
        switch appState.selectedDestination {
        case .trash: return "trash"
        case .archive: return "archivebox"
        case .library: return "books.vertical"
        case .favorites: return "star"
        case .photos: return "photo.fill"
        case .video: return "play.rectangle"
        case .audio: return "music.note"
        case .documents: return "doc.text"
        case .shared: return "arrow.triangle.swap"
        default: return "cloud"
        }
    }

    private var emptyTitle: String {
        if isSearching {
            let q = appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            return "No Results for “\(q)”"
        }
        if appState.selectedDestination == .trash { return "Trash is Empty" }
        if appState.selectedDestination == .archive { return "Archive is Empty" }
        if appState.selectedDestination == .library { return "Library is Empty" }
        if appState.selectedDestination == .shared { return "No Shared Files Yet" }
        if appState.currentFolderID != nil { return "Folder is Empty" }
        return "Nothing Here Yet"
    }

    private var emptySubtitle: String {
        if isSearching {
            return searchScope == .currentFolder
                ? "Try searching Everywhere, or check your spelling."
                : "Check your spelling or try searching with fewer keywords."
        }
        if appState.selectedDestination == .library {
            return "Upload EPUB, PDF or text books and they'll be collected here."
        }
        if appState.selectedDestination == .archive {
            return "Files you archive are hidden from your other views and collected here."
        }
        if appState.selectedDestination == .shared {
            return "Files you import via share links appear here — the file itself stays in All Files."
        }
        if appState.selectedDestination == .allFiles {
            return "Drop files here or tap + to get started"
        }
        return "Files matching this category will appear here."
    }

    }

// MARK: - Context Menu View Component

/// Lists apps that can open a file and launches them externally — the same
/// "Open With" behavior the viewer's Open Externally button uses, shared by the
/// file-card context menu (VLC, IINA, QuickTime, etc.).
enum ExternalOpen {
    struct AppItem: Identifiable {
        let name: String
        let appURL: URL
        var id: URL { appURL }
    }

    static func availableApps(for fileURL: URL, isMedia: Bool) -> [AppItem] {
        let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: fileURL)
        let knownMediaPlayers: Set<String> = [
            "vlc", "iina", "quicktime player", "elmedia player", "infuse", "mpv",
            "mplayer", "kmplayer", "movist", "omniplayer", "soda player", "plex"
        ]
        let filtered = appURLs.filter { appURL in
            let name = FileManager.default.displayName(atPath: appURL.path)
                .replacingOccurrences(of: ".app", with: "").lowercased()
            let bundleID = (Bundle(url: appURL)?.bundleIdentifier ?? "").lowercased()
            if isMedia {
                return knownMediaPlayers.contains(name)
                    || name.contains("player") || name.contains("vlc") || name.contains("iina")
                    || name.contains("quicktime")
                    || bundleID.contains("vlc") || bundleID.contains("iina")
                    || bundleID.contains("quicktime") || bundleID.contains("player")
            } else {
                let excluded: Set<String> = ["xcode", "textedit", "coteditor", "sublime text", "visual studio code", "vscode", "terminal"]
                return !excluded.contains(name)
            }
        }
        return filtered.map { appURL in
            AppItem(
                name: FileManager.default.displayName(atPath: appURL.path)
                    .replacingOccurrences(of: ".app", with: ""),
                appURL: appURL
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Drive-style move destination picker: breadcrumb + folder list to drill
/// through, inline New Folder, and a Move-here confirmation for the CURRENT
/// location (navigate to choose, then paste — no hundred-row submenu).
/// Excludes the moved items themselves and their descendants (a folder can
/// never land inside itself) plus trashed folders.
struct MoveDestinationSheet: View {
    @Environment(AppState.self) private var appState
    let targets: [ObjectRecord]
    @State private var currentID: String? = nil
    @State private var creatingFolder = false
    @State private var newFolderName = ""
    @Environment(\.dismiss) private var dismiss

    private var targetIDs: Set<String> { Set(targets.map(\.id)) }

    private var currentFolder: ObjectRecord? {
        currentID.flatMap { id in appState.files.first(where: { $0.id == id }) }
    }

    private var childFolders: [ObjectRecord] {
        appState.files.filter { f in
            f.isFolder && !f.trashed && f.parentID == currentID
                && !targetIDs.contains(f.id)
                && !targets.contains { t in t.isFolder && appState.isDescendant(f.id, of: t.id) }
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var crumbs: [(id: String?, name: String)] {
        var trail: [(String?, String)] = []
        var seen = Set<String>()
        var pid = currentID
        var guardCount = 0
        while let id = pid, guardCount < 32, !seen.contains(id) {
            guardCount += 1
            seen.insert(id)
            guard let f = appState.files.first(where: { $0.id == id }) else { break }
            trail.insert((f.id, f.name), at: 0)
            pid = f.parentID
        }
        return [(nil, "Cascade Drive")] + trail
    }

    /// Disabled when a single item already lives here (nothing would change).
    private var alreadyHere: Bool {
        targets.count == 1 && targets[0].parentID == currentID
    }

    private var locationPrivacy: Bool {
        currentFolder?.isPrivate ?? targets.first?.isPrivate ?? (appState.selectedDestination == .privateVault)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Move \(targets.count) item\(targets.count == 1 ? "" : "s")")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(XTheme.textPrimary)
                    Text("Choose a destination folder")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            Divider().overlay(Color.white.opacity(0.1))

            // Breadcrumb trail through the vault hierarchy.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(XTheme.textTertiary)
                        }
                        Button(crumb.name) {
                            currentID = crumb.id
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: index == crumbs.count - 1 ? .bold : .medium))
                        .foregroundStyle(index == crumbs.count - 1 ? .white : XTheme.textSecondary)
                        .disabled(index == crumbs.count - 1)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
            }

            Divider().overlay(Color.white.opacity(0.06))

            ScrollView {
                LazyVStack(spacing: 4) {
                    if creatingFolder {
                        HStack(spacing: 10) {
                            AppleFolderIcon(width: 36, height: 28)
                                .frame(width: 36, height: 32)
                            TextField("Folder name", text: $newFolderName)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .foregroundStyle(.white)
                                .onSubmit { createFolder() }
                            Spacer()
                            Button("Create") { createFolder() }
                                .buttonStyle(.plain)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(XTheme.accent)
                                .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("Cancel") {
                                creatingFolder = false
                                newFolderName = ""
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(XTheme.accent.opacity(0.10))
                        )
                    }

                    if childFolders.isEmpty && !creatingFolder {
                        Text("No subfolders here")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.45))
                            .padding(.vertical, 20)
                    }

                    ForEach(childFolders) { folder in
                        Button {
                            currentID = folder.id
                        } label: {
                            HStack(spacing: 10) {
                                AppleFolderIcon(width: 36, height: 28)
                                    .frame(width: 36, height: 32)
                                Text(folder.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(XTheme.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(XTheme.textTertiary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            Divider().overlay(Color.white.opacity(0.1))

            HStack {
                Button {
                    creatingFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .disabled(creatingFolder)

                Spacer()

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))

                Button(alreadyHere ? "Already Here" : "Move Here") {
                    appState.moveObjects(ids: targets.map(\.id), to: currentID)
                    appState.movePickerTargets = nil
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(XTheme.accent))
                .disabled(alreadyHere)
                .opacity(alreadyHere ? 0.5 : 1.0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 480, height: 520)
        .background(AppBackground())
        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        newFolderName = ""
        creatingFolder = false
        Task {
            await appState.createFolder(named: name, parentID: currentID, isPrivate: locationPrivacy)
        }
    }
}

struct FileItemContextMenu: View {
    @Environment(AppState.self) private var appState
    let file: ObjectRecord
    @Binding var renameTarget: ObjectRecord?
    @Binding var renameText: String

    /// The files this menu's actions apply to: the whole selection when the
    /// right-clicked file is part of a multi-selection, otherwise just that file
    /// (Finder behavior).
    private var actionTargets: [ObjectRecord] {
        let selected = appState.selectedFiles
        if selected.contains(file.id) && selected.count > 1 {
            return appState.files.filter { selected.contains($0.id) }
        }
        return [file]
    }

    var body: some View {
        // (The Shared page no longer lists files — it manages outgoing share
        // links, so there's no page-specific file action here.)
        if file.isBook {
            Button {
                appState.readerFile = file
            } label: {
                Label("Read", systemImage: "book")
            }
        }
        if !file.isFolder {
            Button {
                appState.theaterFile = file
            } label: {
                Label("Quick Look", systemImage: "eye")
            }
            // Media can open STRAIGHT into the fullscreen player — no theater,
            // no small player first: videos start playing in the player window
            // itself, images show fit-to-screen (spinner while they download).
            if file.isVideo || file.isPhoto {
                Button {
                    if file.isVideo {
                        PlayerFullScreenWindow.presentDirect(
                            appState: appState,
                            file: file,
                            playlist: appState.files.filter { $0.isAudio || $0.isVideo }
                        )
                    } else {
                        PlayerFullScreenWindow.presentImage(appState: appState, file: file)
                    }
                } label: {
                    Label("Open in Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
            // Sidecar subtitles (Wave 2): attach .srt/.ass/.vtt files to this
            // video — they ride along in the vault and auto-load at playback.
            if file.isVideo {
                Button {
                    appState.subtitlePickerTarget = file
                } label: {
                    Label("Add Subtitles…", systemImage: "captions.bubble")
                }
                let subs = file.subtitleList
                if !subs.isEmpty {
                    Menu {
                        ForEach(subs, id: \.messageID) { sub in
                            Button {
                                appState.removeSubtitleSidecar(from: file, sidecar: sub)
                            } label: {
                                Label(sub.name, systemImage: "minus.circle")
                            }
                        }
                    } label: {
                        Label("Subtitles (\(subs.count))", systemImage: "list.bullet")
                    }
                }
            }
            // Open externally: submenu listing every app that can open this file
            // (VLC, IINA, QuickTime, …), plus Default App and Choose App — the same
            // Open With behavior as the viewer.
            Menu {
                let targetURL = DownloadEngine.cacheURL(for: file)
                let isMedia = file.mime.hasPrefix("video/") || file.mime.hasPrefix("audio/")
                    || ["mp4", "mov", "mkv", "webm", "avi", "m4v", "mp3", "m4a", "wav", "flac", "aac", "ogg"].contains((file.name as NSString).pathExtension.lowercased())
                let apps = ExternalOpen.availableApps(for: targetURL, isMedia: isMedia)
                if !apps.isEmpty {
                    Section("Open With") {
                        ForEach(apps) { item in
                            Button(item.name) { openExternally(appURL: item.appURL) }
                        }
                    }
                    Divider()
                }
                Button("Default App") { openExternally(appURL: nil) }
                Button("Choose App…") { chooseAppFor(targetURL) }
            } label: {
                Label("Open externally", systemImage: "arrow.up.forward.app")
            }
            Button {
                saveFileToMac(file)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            Divider()
        } else {
            Button {
                appState.openFolder(file)
            } label: {
                Label("Open", systemImage: "folder")
            }
            Button {
                appState.toggleSidebarPin(file)
            } label: {
                Label(
                    appState.sidebarPinnedFolderIDs.contains(file.id) ? "Unpin from Sidebar" : "Pin to Sidebar",
                    systemImage: appState.sidebarPinnedFolderIDs.contains(file.id) ? "sidebar.left.slash" : "sidebar.left"
                )
            }
        }

        if !appState.searchText.isEmpty {
            Button {
                appState.revealObject(file)
            } label: {
                Label("Show in Enclosing Folder", systemImage: "folder")
            }
            Divider()
        }

        // Share + Export live here (files AND folders — the engine expands
        // folders to their descendants). Private-only selections show neither
        // (same rule as before, now uniform).
        if !file.trashed {
            // The whole shareable selection shares as ONE group link — a
            // multi-selection produces a single grouped share the recipient
            // imports together. The Share menu expands into the two kinds:
            // PRIVATE (lock) — expiring link in a dedicated pool channel,
            // max 5; PUBLIC (globe) — never expires, persistent channel.
            let shareTargets = actionTargets.filter { !$0.isPrivate }
            if !shareTargets.isEmpty {
                Menu {
                    Button {
                        appState.shareFiles(shareTargets)
                    } label: {
                        Label("Private", systemImage: "lock.fill")
                    }
                    Button {
                        appState.shareFiles(shareTargets, isPublic: true)
                    } label: {
                        Label("Public", systemImage: "globe")
                    }
                } label: {
                    Label(shareTargets.count > 1 ? "Share \(shareTargets.count) Items" : "Share", systemImage: "arrow.triangle.swap")
                }
            }
        }
        // Wave 2 item 8 — bulk export: decrypt the selection (folders expand
        // to their whole tree) into a user-chosen local folder.
        Button {
            exportSelection()
        } label: {
            Label(
                actionTargets.count > 1 ? "Export \(actionTargets.count) Items…" : "Export…",
                systemImage: "tray.and.arrow.down"
            )
        }
        Button {
            renameText = file.name
            renameTarget = file
        } label: {
            Label("Rename…", systemImage: "pencil")
        }
        // Offline pin ("Keep Downloaded") — files AND folders (folders apply
        // recursively). Pinning downloads uncached targets with visible cards.
        Button {
            let makePinned = !file.isPinned
            for target in actionTargets { appState.setPinned(target, makePinned) }
        } label: {
            Label(file.isPinned ? "Remove Download" : "Keep Downloaded", systemImage: file.isPinned ? "pin.slash" : "pin")
        }
        // Drive-style move: opens the destination picker (files AND folders).
        // Replaces the old flat Move-to-Folder submenu, which was unusable
        // with more than a handful of folders.
        Button {
            appState.movePickerTargets = actionTargets
        } label: {
            Label(
                actionTargets.count > 1 ? "Move \(actionTargets.count) Items…" : "Move…",
                systemImage: "folder"
            )
        }
        // Finder-style duplicate: instant server-side copy (files AND
        // folders; folder copies are shallow, matching iOS).
        Button {
            appState.duplicateObjects(actionTargets)
        } label: {
            Label(
                actionTargets.count > 1 ? "Duplicate \(actionTargets.count) Items" : "Duplicate",
                systemImage: "plus.square.on.square"
            )
        }
        Button {
            for target in actionTargets { appState.toggleFavorite(target) }
        } label: {
            Label(file.isFavorite ? "Remove Favorite" : "Add Favorite", systemImage: file.isFavorite ? "star.slash" : "star")
        }
        if !file.isFolder {
            // Add to Playlist / Album Menu
            let isAudio = file.mime.hasPrefix("audio/") || ["mp3", "m4a", "wav", "flac", "aac", "ogg"].contains((file.name as NSString).pathExtension.lowercased())
            let isVideo = file.mime.hasPrefix("video/")
            let isPhoto = file.mime.hasPrefix("image/") || ["jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp", "svg"].contains((file.name as NSString).pathExtension.lowercased())
            let targetPlaylistMime = isAudio ? "cascade/playlist-audio" : (isVideo ? "cascade/playlist-video" : (isPhoto ? "cascade/album-photo" : nil))

            if let targetPlaylistMime {
                let collections = appState.files.filter { $0.isFolder && !$0.trashed && $0.mime == targetPlaylistMime }
                let menuTitle = isPhoto ? "Add to Album" : "Add to Playlist"
                let menuIcon = isPhoto ? "photo.stack" : "plus.square.on.square"
                Menu {
                    if collections.isEmpty {
                        Text(isPhoto ? "No albums yet" : "No playlists yet").font(.caption)
                    } else {
                        ForEach(collections) { collection in
                            Button(collection.name) {
                                for target in actionTargets {
                                    appState.addToPlaylist(target, playlistID: collection.id)
                                }
                            }
                        }
                    }
                } label: {
                    Label(menuTitle, systemImage: menuIcon)
                }
            }

            // (Flat Move submenu removed — Drive-style Move… picker below.)
        }
        Divider()
        // Library membership is opt-in for ambiguous formats (PDF/TXT/MD) so
        // document-style files never sneak onto the bookshelf. EPUB/CBZ/CBR are
        // always books and offer no toggle.
        if file.isBookFile && !file.isHardBook {
            if file.isInLibrary {
                Button {
                    for target in actionTargets { appState.setInLibrary(target, false) }
                } label: {
                    Label(actionTargets.count > 1 ? "Remove \(actionTargets.count) Items from Library" : "Remove from Library", systemImage: "bookmark.slash")
                }
            } else {
                Button {
                    for target in actionTargets { appState.setInLibrary(target, true) }
                } label: {
                    Label(actionTargets.count > 1 ? "Add \(actionTargets.count) Items to Library" : "Add to Library", systemImage: "bookmark")
                }
            }
        }
        Divider()
        // Wave 2 item 8 — version history (files replaced by folder-sync edits).
        if !file.isFolder && !file.trashed {
            Button {
                appState.versionHistoryTarget = file
            } label: {
                Label("Version History…", systemImage: "clock.arrow.circlepath")
            }
        }
        if file.isArchived {
            Button {
                for target in actionTargets { appState.setArchived(target, false) }
            } label: {
                Label(actionTargets.count > 1 ? "Unarchive \(actionTargets.count) Items" : "Unarchive", systemImage: "tray.and.arrow.up")
            }
        } else {
            Button {
                for target in actionTargets { appState.setArchived(target, true) }
            } label: {
                Label(actionTargets.count > 1 ? "Archive \(actionTargets.count) Items" : "Archive", systemImage: "archivebox")
            }
        }
        if file.trashed {
            Button {
                for target in actionTargets { appState.setTrashed(target, false) }
            } label: {
                Label(actionTargets.count > 1 ? "Restore \(actionTargets.count) Items" : "Restore", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) {
                appState.deleteForever(actionTargets)
            } label: {
                Label(actionTargets.count > 1 ? "Delete \(actionTargets.count) Items Forever" : "Delete Forever", systemImage: "trash.slash")
            }
        } else {
            Button(role: .destructive) {
                for target in actionTargets { appState.setTrashed(target, true) }
            } label: {
                Label(actionTargets.count > 1 ? "Move \(actionTargets.count) Items to Trash" : "Move to Trash", systemImage: "trash")
            }
            Button(role: .destructive) {
                appState.deleteForever(actionTargets)
            } label: {
                Label(actionTargets.count > 1 ? "Delete \(actionTargets.count) Items Permanently" : "Delete Permanently", systemImage: "trash.slash")
            }
        }
    }

    /// Downloads the file if it isn't cached yet, then opens it — with the chosen
    /// app if one was picked, otherwise with the system default.
    private func openExternally(appURL: URL?) {
        Task {
            let url: URL
            if DownloadEngine.isCached(file) {
                url = DownloadEngine.cacheURL(for: file)
            } else {
                let downloaded = try? await DownloadEngine.download(object: file, quiet: true) { _, _ in }
                guard let downloaded else { return }
                url = downloaded
            }
            if let appURL {
                try? await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func chooseAppFor(_ fileURL: URL) {
        let openPanel = NSOpenPanel()
        openPanel.title = "Select Application to Open \(file.name)"
        openPanel.directoryURL = URL(fileURLWithPath: "/Applications")
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.allowedContentTypes = [.application]
        openPanel.begin { response in
            guard response == .OK, let appURL = openPanel.url else { return }
            openExternally(appURL: appURL)
        }
    }

    private func saveFileToMac(_ file: ObjectRecord) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.canCreateDirectories = true
        panel.prompt = "Save"

        panel.begin { response in
            guard response == .OK, let destinationURL = panel.url else { return }
            Task {
                do {
                    let downloadedURL = try await DownloadEngine.download(object: file) { status, progress in }
                    let destPath = destinationURL.path(percentEncoded: false)
                    if FileManager.default.fileExists(atPath: destPath) {
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                    try FileManager.default.copyItem(at: downloadedURL, to: destinationURL)
                    NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
                } catch {
                    Task { @MainActor in
                        appState.alertMessage = "Download failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    /// Wave 2 item 8 — bulk export: folder targets expand to their whole tree,
    /// the user picks a destination, and ExportEngine streams every file there
    /// decrypted (hierarchy preserved). Feedback rides the app's banner system.
    private func exportSelection() {
        var ids: [String] = []
        let all = appState.files
        for target in actionTargets {
            ids.append(target.id)
            if target.isFolder {
                var stack = [target.id]
                while let id = stack.popLast() {
                    for child in all where child.parentID == id {
                        ids.append(child.id)
                        if child.isFolder { stack.append(child.id) }
                    }
                }
            }
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose a destination folder for export"
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        let itemCount = ids.count
        appState.notify(title: "Exporting \(itemCount) item\(itemCount == 1 ? "" : "s")…", kind: .info, duration: 3.0)
        Task {
            do {
                let exported = try await ExportEngine.shared.export(objectIDs: ids, to: dest)
                appState.notify(
                    title: "Export complete",
                    message: "\(exported) file\(exported == 1 ? "" : "s") saved to “\(dest.lastPathComponent)”",
                    kind: .success,
                    duration: 5.0
                )
            } catch {
                appState.notify(
                    title: "Export failed",
                    message: error.localizedDescription,
                    kind: .error,
                    duration: 6.0
                )
            }
        }
    }
}

// MARK: - Grid Item (Google Drive-style clean card)

/// A soft highlight that sweeps across a view once on appear, then loops —
/// gives loading placeholders the classic "shimmer" look.
private struct ShimmerModifier: ViewModifier {
    @State private var swept = false

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.10), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.5)
                    .offset(x: swept ? geo.size.width * 1.5 : -geo.size.width * 0.5)
                    .allowsHitTesting(false)
                }
                .clipped()
            }
            .onAppear {
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                    swept = true
                }
            }
    }
}

/// Collects each file card's frame in the browser's named coordinate space, so the
/// marquee (rectangle) selection can hit-test which cards the drag rectangle covers.
private struct GridFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct ReportGridFrame: ViewModifier {
    let id: String
    let space: String

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { geo in
                Color.clear
                    .preference(
                        key: GridFrameKey.self,
                        value: [id: geo.frame(in: .named(space))]
                    )
            }
            .allowsHitTesting(false)
        }
    }
}

private extension View {
    func reportGridFrame(id: String, space: String = "gridContent") -> some View {
        modifier(ReportGridFrame(id: id, space: space))
    }
}

/// Parses a drag payload (newline-joined object IDs) into the list of IDs to act on.
private func parseDroppedObjectIDs(_ object: Any?) -> [String] {
    guard let str = object as? String else { return [] }
    return str.split(separator: "\n").map(String.init)
}

// MARK: - Apple Files-style folder icon (ported from the iOS app)

/// Vector folder tab (back flap) with Apple Files geometry: rear tab
/// curvature, continuous corner radii, proportional to the target rect so it
/// renders identically at any size. Pure SwiftUI — shared with iOS verbatim.
struct AppleFolderTabShape: Shape {
    var bodyYFraction: CGFloat = 0.13
    var tabWFraction: CGFloat = 0.40
    var cornerRadiusFraction: CGFloat = 0.11

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height
        let bodyY = height * bodyYFraction
        let tabW = width * tabWFraction
        let cornerRadius = height * cornerRadiusFraction
        let r = cornerRadius * 0.75

        path.move(to: CGPoint(x: 0, y: r))
        path.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: tabW - r, y: 0))
        path.addCurve(
            to: CGPoint(x: tabW + width * 0.09, y: bodyY),
            control1: CGPoint(x: tabW + r * 0.6, y: 0),
            control2: CGPoint(x: tabW + r * 0.3, y: bodyY)
        )
        path.addLine(to: CGPoint(x: width - cornerRadius, y: bodyY))
        path.addQuadCurve(to: CGPoint(x: width, y: bodyY + cornerRadius), control: CGPoint(x: width, y: bodyY))
        path.addLine(to: CGPoint(x: width, y: height - cornerRadius))
        path.addQuadCurve(to: CGPoint(x: width - cornerRadius, y: height), control: CGPoint(x: width, y: height))
        path.addLine(to: CGPoint(x: cornerRadius, y: height))
        path.addQuadCurve(to: CGPoint(x: 0, y: height - cornerRadius), control: CGPoint(x: 0, y: height))
        path.closeSubpath()
        return path
    }
}

/// Apple Files folder: darker tab behind, lighter gradient body in front with
/// a top highlight edge. Same component, same metrics (84×66) as iOS — one
/// visual language on both platforms.
struct AppleFolderIcon: View {
    var width: CGFloat = 84
    var height: CGFloat = 66

    var body: some View {
        let bodyY = height * 0.13
        let cornerRadius = height * 0.11

        ZStack(alignment: .topLeading) {
            // Back Tab / Flap
            AppleFolderTabShape()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 60/255, green: 160/255, blue: 222/255),
                            Color(red: 50/255, green: 146/255, blue: 206/255)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: width, height: height)

            // Front Main Body
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 104/255, green: 194/255, blue: 242/255),
                            Color(red: 80/255, green: 172/255, blue: 226/255)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.40), Color.white.opacity(0.06)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.75
                        )
                )
                .frame(width: width, height: height - bodyY)
                .offset(y: bodyY)
        }
        .frame(width: width, height: height)
    }
}

struct FileGridItem: View {
    @Environment(AppState.self) private var appState
    let file: ObjectRecord
    let isSelected: Bool
    @Binding var renameTarget: ObjectRecord?
    @Binding var renameText: String
    @State private var hovering = false
    @State private var dropTargeted = false
    @State private var thumbURL: URL? = nil
    @State private var coverURL: URL? = nil
    @State private var revealPulse = 0.0
    @State private var revealScale: CGFloat = 1.0
    @State private var revealTaskActive = false
    /// Reading position (0...1) persisted by BookReaderView — drives the
    /// Apple Books-style progress bar at the bottom of library covers.
    @AppStorage private var bookProgressFraction: Double

    init(file: ObjectRecord, isSelected: Bool, renameTarget: Binding<ObjectRecord?>, renameText: Binding<String>) {
        self.file = file
        self.isSelected = isSelected
        self._renameTarget = renameTarget
        self._renameText = renameText
        self._bookProgressFraction = AppStorage(wrappedValue: 0, "xc.reader.progressFraction.\(file.id)")
    }

    private var itemCount: Int {
        appState.files.filter { $0.parentID == file.id && !$0.trashed }.count
    }

    var body: some View {
        Group {
            if file.isFolder {
                folderCard
            } else if file.isBook && appState.selectedDestination == .library {
                bookPosterCard
            } else {
                fileCard
            }
        }
        .contentShape(Rectangle())
        .task(id: "\(file.id)-\(appState.thumbnailVersion)-\(appState.selectedDestination.rawValue)") {
            if file.isBook && appState.selectedDestination == .library {
                coverURL = await ThumbnailService.shared.bookCoverURL(for: file)
            } else {
                thumbURL = await ThumbnailService.shared.thumbnailURL(for: file)
            }
        }
        .onHover { hovering = $0 }
        .onDrop(of: [UTType.text], isTargeted: $dropTargeted) { providers in
            guard file.isFolder else { return false }
            return dropIntoFolder(providers)
        }
        .overlay {
            // When a selected card is part of a multi-selection, tint it and show the
            // count so the drag preview communicates that the whole selection moves.
            if isSelected && hovering && appState.selectedFiles.count > 1 {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(XTheme.accent.opacity(0.22))
                    .overlay {
                        Text("\(appState.selectedFiles.count) items")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                    }
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            // Reveal-in-folder flash: a Finder-style ring that fades in (scaling up
            // from a slight inset), settles, then expands and fades out — twice — on
            // the exact card the user just revealed from Transfers.
            if file.id == appState.revealObjectID {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(XTheme.accent.opacity(0.10 * revealPulse))
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(XTheme.accent, lineWidth: 2.5)
                        .shadow(color: XTheme.accent.opacity(0.8), radius: 7)
                        .opacity(revealPulse)
                }
                .scaleEffect(revealScale)
                .allowsHitTesting(false)
            }
        }
        .onChange(of: appState.revealToken) { _, _ in
            if file.id == appState.revealObjectID { startRevealFlash() }
        }
        .onAppear {
            if file.id == appState.revealObjectID { startRevealFlash() }
        }
    }

    /// Finder-style reveal flash: the card's accent ring fades in and grows to size,
    /// then expands slightly while fading out — twice — and finally clears the reveal
    /// target so a later reveal of the same file retriggers.
    private func startRevealFlash() {
        guard !revealTaskActive else { return }
        revealTaskActive = true
        Task { @MainActor in
            revealPulse = 0
            revealScale = 0.96
            for _ in 0..<2 {
                withAnimation(.easeOut(duration: 0.13)) {
                    revealPulse = 1
                    revealScale = 1.0
                }
                try? await Task.sleep(nanoseconds: 140_000_000)
                withAnimation(.easeIn(duration: 0.18)) {
                    revealPulse = 0
                    revealScale = 1.03
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if appState.revealObjectID == file.id {
                appState.revealObjectID = nil
            }
            revealTaskActive = false
        }
    }

    /// Finder / Apple Files-style folder tile: the vector folder sits centered
    /// in a 132pt square container (comfortable padding on all sides — same
    /// footprint as the iOS tile zone), name + item count below. The selection
    /// wash and ring hug the square, never the full column width.
    private var folderCard: some View {
        VStack(spacing: 6) {
            ZStack {
                AppleFolderIcon(width: 84, height: 66)
                    .shadow(color: .black.opacity(0.15), radius: 2.5, x: 0, y: 1.5)
            }
            .frame(width: 132, height: 132)
            .background(squareHighlight)
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(XTheme.accent, lineWidth: 1.5)
                }
            }
            .overlay(alignment: .topTrailing) { tileBadges }

            VStack(spacing: 2) {
                Text(file.name)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(XTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)

                if !appState.searchText.isEmpty {
                    Text(appState.folderPath(for: file))
                        .font(.system(size: 10))
                        .foregroundStyle(XTheme.accent)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Text("\(itemCount) item\(itemCount == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(XTheme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(width: 140, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .center)
        .contentShape(Rectangle())
    }

    /// Library poster card: just the book cover in a clean 2:3 portrait frame.
    /// No name, no size — the cover art is the card (double-click / menu still
    /// offer the full file actions; hover reveals the title and the menu button).
    /// A reading-progress bar sits at the bottom edge once the book has been
    /// opened, so the shelf shows where each book was left off.
    private var bookPosterCard: some View {
        // Apple Books-style shelf card: the cover art IS the card. Covers render
        // a little smaller than the cell (breathing room + room for the shadow).
        // Imperfect art (non-2:3, PDF first pages) is center-cropped to the
        // poster shape — no letterboxing, no stretched thumbs.
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                if let coverURL = coverURL, let ns = NSImage(contentsOf: coverURL) {
                    Image(nsImage: ns)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    // Stylized placeholder: muted gradient "dust jacket" with the
                    // title set like a book spine, instead of a bare icon.
                    ZStack {
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.10),
                                Color.white.opacity(0.04),
                                Color.black.opacity(0.18)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        VStack(spacing: 10) {
                            Image(systemName: "book.closed.fill")
                                .font(.system(size: 30, weight: .light))
                                .foregroundStyle(XTheme.textTertiary)
                            Text(file.name)
                                .font(.system(size: 11, weight: .semibold, design: .serif))
                                .foregroundStyle(XTheme.textTertiary)
                                .lineLimit(3)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 12)
                        }
                    }
                }

                // Reading progress: thin accent bar pinned to the bottom edge.
                if bookProgressFraction > 0.02 {
                    Rectangle()
                        .fill(Color.black.opacity(0.35))
                        .frame(height: 4)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(XTheme.accent)
                                .frame(width: max(4, geo.size.width * bookProgressFraction))
                        }
                }

                if hovering {
                    Text(file.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background(.black.opacity(0.45))
                        .allowsHitTesting(false)
                }
            }
            .clipped()
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        // The menu button lives INSIDE the cover's own bounds (attached before
        // the breathing-room padding, so its alignment box is the cover, not the
        // padded cell) — pinned to the top-right corner, clearly inset.
        .overlay(alignment: .topTrailing) {
            Menu {
                FileItemContextMenu(file: file, renameTarget: $renameTarget, renameText: $renameText)
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.40))
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 24, height: 24)
                .glassEffect(.regular.interactive(), in: .circle)
                .contentShape(Circle())
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .padding(8)
        }
        .shadow(color: .black.opacity(hovering ? 0.5 : 0.35), radius: 5, y: 3)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(XTheme.accent, lineWidth: 2.5)
            }
        }
        // Breathing room goes OUTSIDE the clip: the rounded corners belong to the
        // cover itself, not to a padded box around it.
        .padding(.horizontal, 4)
        .padding(.vertical, 7)
    }

    /// Finder / Apple Files-style file tile: the thumbnail sits centered in a
    /// 132pt square container (aspect-fit, so full frames show with padding —
    /// never cropped, never stretched), name + date + size below.
    private var fileCard: some View {
        VStack(spacing: 6) {
            ZStack {
                if let thumbURL, let ns = NSImage(contentsOf: thumbURL) {
                    Image(nsImage: ns)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 132, maxHeight: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 2.5, x: 0, y: 1.5)
                } else {
                    placeholderView
                }
            }
            .frame(width: 132, height: 132)
            .background(squareHighlight)
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(XTheme.accent, lineWidth: 1.5)
                }
            }
            .overlay(alignment: .topTrailing) { tileBadges }

            VStack(spacing: 2) {
                Text(file.name)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(XTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)

                if !appState.searchText.isEmpty {
                    Text(appState.folderPath(for: file))
                        .font(.system(size: 10))
                        .foregroundStyle(XTheme.accent)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Text(file.createdAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 11))
                    .foregroundStyle(XTheme.textTertiary)

                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .font(.system(size: 11))
                    .foregroundStyle(XTheme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(width: 140, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .center)
        .contentShape(Rectangle())
    }

    /// Liquid glass selection card: fills the tile's square container when
    /// selected (non-interactive glass — display only, taps pass through to
    /// the tile). Quiet when unselected — no hover state.
    @ViewBuilder
    private var squareHighlight: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(XTheme.accent.opacity(0.10))
                .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
        }
    }

    /// Pin / private status badges, pinned to the thumbnail zone's top-trailing
    /// corner. The card menu button was removed (Round 209) — right-click /
    /// two-finger tap opens the same menu, like Finder. Shared by folder and
    /// file tiles.
    private var tileBadges: some View {
        HStack(spacing: 4) {
            if file.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(Circle().fill(XTheme.accent))
            }
            if file.isPrivate {
                Image(systemName: "number")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(Circle().fill(XTheme.categoryRed))
            }
        }
        .padding(6)
    }

    /// No-thumbnail placeholder per file type — same cards as the iOS app
    /// (white doc/audio cards, dark video/photo cards, EXT caption).
    private var placeholderView: some View {
        let ext = (file.name as NSString).pathExtension.uppercased()
        return ZStack {
            if file.isAudio {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white)
                        .frame(width: 70, height: 92)
                        .shadow(color: .black.opacity(0.16), radius: 2.5, x: 0, y: 1.5)
                    Image(systemName: "music.note")
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(Color(white: 0.78))
                }
            } else if file.isVideo {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(red: 0.13, green: 0.13, blue: 0.15))
                        .frame(width: 90, height: 60)
                        .shadow(color: .black.opacity(0.20), radius: 2.5, x: 0, y: 1.5)
                    VStack(spacing: 3) {
                        Image(systemName: "film")
                            .font(.system(size: 26))
                            .foregroundStyle(.white.opacity(0.75))
                        if !ext.isEmpty {
                            Text(ext)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white.opacity(0.50))
                        }
                    }
                }
            } else if file.isPhoto {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(red: 0.16, green: 0.18, blue: 0.22))
                        .frame(width: 84, height: 62)
                        .shadow(color: .black.opacity(0.18), radius: 2.5, x: 0, y: 1.5)
                    VStack(spacing: 3) {
                        Image(systemName: "photo")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.70))
                        if !ext.isEmpty {
                            Text(ext)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white.opacity(0.50))
                        }
                    }
                }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white)
                        .frame(width: 70, height: 92)
                        .shadow(color: .black.opacity(0.18), radius: 2.5, x: 0, y: 1.5)
                    VStack(spacing: 4) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 28))
                            .foregroundStyle(Color(white: 0.65))
                        if !ext.isEmpty {
                            Text(ext)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color(white: 0.45))
                        }
                    }
                }
            }
        }
    }

    private func dropIntoFolder(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: NSString.self) {
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                let ids = parseDroppedObjectIDs(object)
                guard !ids.isEmpty else { return }
                Task { @MainActor in
                    for id in ids {
                        appState.moveObject(id: id, to: file.id)
                    }
                }
            }
            handled = true
        }
        return handled
    }
}

// MARK: - List Row

/// Disclosure chevron for expandable list folders (extracted: FileListRow's
/// body sits at the type-checker's complexity limit).
/// High-priority single tap fires instantly instead of waiting out the row's
/// double-tap-to-open recognizer, and claims the touch so a chevron tap never
/// opens the folder. Row selection still lands via the parent's simultaneous
/// single-tap, Finder-style.
struct FolderDisclosureChevron: View {
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(XTheme.textTertiary)
            .frame(width: 24, height: 32)
            .contentShape(Rectangle())
            .highPriorityGesture(TapGesture(count: 1).onEnded(onToggle))
    }
}

struct FileListRow: View {
    @Environment(AppState.self) private var appState
    let file: ObjectRecord
    let isSelected: Bool
    /// Nesting depth for Finder-style expandable folders (indent per level).
    var depth: Int = 0
    /// Whether this folder's children are currently shown.
    var isExpanded: Bool = false
    /// Whether this folder has children to show (chevron hidden when none).
    var hasChildren: Bool = false
    /// Toggle handler for the disclosure chevron (folders with children only).
    var onToggleExpand: (() -> Void)? = nil
    @State private var hovering = false
    @State private var dropTargeted = false
    @State private var thumbURL: URL? = nil
    @State private var revealPulse = 0.0
    @State private var revealScale: CGFloat = 1.0
    @State private var revealTaskActive = false

    private var itemCount: Int {
        appState.files.filter { $0.parentID == file.id && !$0.trashed }.count
    }

    var body: some View {
        HStack(spacing: 10) {
            // Finder gutter: EVERY row reserves the 24pt disclosure column so
            // icons align whether or not a chevron shows (an expandable folder
            // must not shift right next to its siblings).
            if file.isFolder, hasChildren {
                FolderDisclosureChevron(isExpanded: isExpanded) { onToggleExpand?() }
            } else {
                Color.clear
                    .frame(width: 24, height: 32)
            }

            rowIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(XTheme.textPrimary)
                    .lineLimit(1)

                if !appState.searchText.isEmpty {
                    Text(appState.folderPath(for: file))
                        .font(.system(size: 11))
                        .foregroundStyle(XTheme.accent)
                        .lineLimit(1)
                }
            }

            if file.isFolder {
                Text("\(itemCount) item\(itemCount == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundStyle(XTheme.textTertiary)
            }

            Spacer()

            if !file.isFolder {
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(XTheme.textSecondary)
                    .frame(width: 80, alignment: .trailing)
            }

            Text(file.createdAt.formatted(.relative(presentation: .named)))
                .font(.system(size: 12))
                .foregroundStyle(XTheme.textTertiary)
                .frame(width: 100, alignment: .trailing)
        }
        .padding(.leading, 14 + CGFloat(depth) * 20)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(XTheme.accent.opacity(0.10))
                    .glassEffect(.regular, in: .rect(cornerRadius: 10, style: .continuous))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(dropTargeted ? XTheme.accent : .clear, lineWidth: 1.5)
        )
        .overlay {
            // Reveal-in-folder flash: a Finder-style ring that fades in (scaling up
            // from a slight inset), settles, then expands and fades out — twice — on
            // the exact row the user just revealed from Transfers.
            if file.id == appState.revealObjectID {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(XTheme.accent.opacity(0.10 * revealPulse))
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(XTheme.accent, lineWidth: 2.5)
                        .shadow(color: XTheme.accent.opacity(0.8), radius: 7)
                        .opacity(revealPulse)
                }
                .scaleEffect(revealScale)
                .allowsHitTesting(false)
            }
        }
        .onChange(of: appState.revealToken) { _, _ in
            if file.id == appState.revealObjectID { startRevealFlash() }
        }
        .onAppear {
            if file.id == appState.revealObjectID { startRevealFlash() }
        }
        .overlay(alignment: .trailing) {
            HStack(spacing: 4) {
                if file.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Circle().fill(XTheme.accent.opacity(0.9)))
                }
                if file.isPrivate {
                    Image(systemName: "number")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Circle().fill(XTheme.categoryRed.opacity(0.9)))
                }
            }
            .padding(.trailing, 6)
        }
        .task(id: "\(file.id)-\(appState.thumbnailVersion)") {
            thumbURL = await ThumbnailService.shared.thumbnailURL(for: file)
        }
        .onHover { hovering = $0 }
        .onDrop(of: [UTType.text], isTargeted: $dropTargeted) { providers in
            guard file.isFolder else { return false }
            var handled = false
            for provider in providers where provider.canLoadObject(ofClass: NSString.self) {
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    let ids = (object as? String).map {
                        $0.split(separator: "\n").map(String.init)
                    } ?? []
                    guard !ids.isEmpty else { return }
                    Task { @MainActor in
                        for id in ids {
                            appState.moveObject(id: id, to: file.id)
                        }
                    }
                }
                handled = true
            }
            return handled
        }
        .overlay {
            if isSelected && hovering && appState.selectedFiles.count > 1 {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(XTheme.accent.opacity(0.22))
                    .overlay {
                        Text("\(appState.selectedFiles.count) items")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                    }
                    .allowsHitTesting(false)
            }
        }
    }

    /// Finder-style reveal flash: the row's accent ring fades in and grows to size,
    /// then expands slightly while fading out — twice — and finally clears the reveal
    /// target so a later reveal of the same file retriggers.
    private func startRevealFlash() {
        guard !revealTaskActive else { return }
        revealTaskActive = true
        Task { @MainActor in
            revealPulse = 0
            revealScale = 0.96
            for _ in 0..<2 {
                withAnimation(.easeOut(duration: 0.13)) {
                    revealPulse = 1
                    revealScale = 1.0
                }
                try? await Task.sleep(nanoseconds: 140_000_000)
                withAnimation(.easeIn(duration: 0.18)) {
                    revealPulse = 0
                    revealScale = 1.03
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if appState.revealObjectID == file.id {
                appState.revealObjectID = nil
            }
            revealTaskActive = false
        }
    }

    @ViewBuilder
    private var rowIcon: some View {
        if file.isFolder {
            // Same vector folder as the grid tiles (list size) — private
            // folders read blue here too; the trailing `#` badge carries it.
            AppleFolderIcon(width: 36, height: 28)
                .shadow(color: .black.opacity(0.15), radius: 1.5, x: 0, y: 1)
                .frame(width: 36, height: 32)
        } else if let thumbURL, let ns = NSImage(contentsOf: thumbURL) {
            Image(nsImage: ns)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: fileIcon)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(XTheme.textSecondary)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.04)))
        }
    }

    private var fileIcon: String {
        let mime = file.mime
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("video/") { return "film" }
        if mime.hasPrefix("audio/") { return "music.note" }
        if mime.contains("pdf") { return "doc.richtext" }
        if mime.hasPrefix("text/") { return "doc.text" }
        return "doc"
    }
}

// MARK: - Private Vault Lock View

struct PrivateVaultLockView: View {
    @Environment(AppState.self) private var appState
    @State private var buffer = ""
    @State private var firstEntry = ""
    @State private var phase: Phase = .enter
    @State private var shake = false
    @State private var revealedIndex: Int? = nil
    @State private var revealTimer: Task<Void, Never>? = nil
    @State private var pinLockMessage: String? = nil
    @State private var biometricAutoPrompted = false
    @FocusState private var focused: Bool

    enum Phase { case enter, create, confirm, recover }

    /// Wave 2 item 4 — Touch ID / Face ID replaces the ENTER phase only (the
    /// PIN stays the source of truth; create/confirm/recover need the literal
    /// digits because they derive crypto material).
    private var showBiometricUnlock: Bool {
        phase == .enter && BiometricUnlock.isEligible(hasPINHash: KeychainStore.loadVaultPINHash() != nil)
    }

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 22) {
                // Hero mark: layered lock in an accent ring
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [XTheme.accent.opacity(0.28), XTheme.accent.opacity(0.08)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 84, height: 84)
                    Circle()
                        .strokeBorder(XTheme.accent.opacity(0.35), lineWidth: 1.5)
                        .frame(width: 84, height: 84)
                    Image(systemName: phase == .recover ? "key.fill" : "lock.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [XTheme.accent, XTheme.accent.opacity(0.65)],
                                startPoint: .top, endPoint: .bottom))
                }
                VStack(spacing: 6) {
                    Text(title).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                    if let pinLockMessage {
                        Text(pinLockMessage)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }
                }
                
                HStack(spacing: 14) {
                    ForEach(0..<4, id: \.self) { i in
                        let chars = Array(buffer)
                        let hasValue = i < chars.count
                        let isRevealed = (i == revealedIndex) && hasValue

                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(hasValue ? XTheme.accent.opacity(0.15) : .white.opacity(0.06))
                                .frame(width: 52, height: 60)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(
                                            i == buffer.count ? XTheme.accent : (hasValue ? XTheme.accent.opacity(0.6) : .white.opacity(0.12)),
                                            lineWidth: 1.5
                                        )
                                )

                            if hasValue {
                                if isRevealed {
                                    Text(String(chars[i]))
                                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.white)
                                } else {
                                    Circle()
                                        .fill(.white)
                                        .frame(width: 10, height: 10)
                                }
                            }
                        }
                    }
                }
                .offset(x: shake ? 12 : 0)

                // Biometric unlock (Touch ID / Face ID) — PIN stays as fallback.
                if showBiometricUnlock {
                    Button {
                        Task { await unlockWithBiometrics() }
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: BiometricUnlock.biometryName == "Face ID" ? "faceid" : "touchid")
                                .font(.system(size: 26, weight: .medium))
                            Text("Unlock with \(BiometricUnlock.biometryName)")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(XTheme.accent)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(XTheme.accent.opacity(0.12))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Unlock the Locked folder using \(BiometricUnlock.biometryName)")
                }

                // App-level PIN reset: the PIN guards a local UI gate, not key
                // material, so it can always be replaced by its owner.
                if phase == .enter {
                    Button("Forgot PIN?") {
                        phase = .recover
                        buffer = ""
                        pinLockMessage = nil
                        focused = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
                    .help("Replace the PIN — the files in this folder are not affected")
                }

                // Invisible capture field
                TextField("", text: $buffer)
                    .textFieldStyle(.plain)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .focused($focused)
                    .onChange(of: buffer) { oldValue, new in
                        let digits = String(new.filter(\.isNumber).prefix(4))
                        if new != digits { buffer = digits; return }

                        if digits.count > oldValue.count {
                            let newlyAdded = digits.count - 1
                            revealedIndex = newlyAdded
                            revealTimer?.cancel()
                            revealTimer = Task {
                                try? await Task.sleep(for: .milliseconds(450))
                                if !Task.isCancelled {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        revealedIndex = nil
                                    }
                                }
                            }
                        } else {
                            revealedIndex = nil
                        }

                        if digits.count == 4 { submit(digits) }
                    }
            }
            .padding(36)
            .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
        }
        .onAppear {
            focused = true
            Task {
                await chooseInitialPhase()
                // Auto-prompt the sensor once per lock-screen appearance —
                // Touch ID unlock should feel like the DEFAULT path.
                if showBiometricUnlock && !biometricAutoPrompted {
                    biometricAutoPrompted = true
                    await unlockWithBiometrics()
                }
            }
        }
        .task(id: appState.selectedDestination) {
            try? await Task.sleep(for: .milliseconds(50))
            focused = true
        }
        .onTapGesture { focused = true }
    }

    private func chooseInitialPhase() async {
        if KeychainStore.loadVaultPINHash() != nil {
            phase = .enter
        } else {
            phase = .create
        }
        focused = true
    }

    private var title: String {
        switch phase {
        case .enter: "Locked"
        case .create: "Create a PIN"
        case .confirm: "Confirm PIN"
        case .recover: "Reset PIN"
        }
    }
    private var subtitle: String {
        switch phase {
        case .enter: "Enter your 4-digit PIN to unlock."
        case .create: "Choose a 4-digit PIN. It locks this folder behind an app-level screen — files inside are regular vault files."
        case .confirm: "Enter the same PIN again."
        case .recover: "Enter a new 4-digit PIN. The old PIN is discarded — this folder keeps its files."
        }
    }

    /// App-level PIN reset: the PIN guards a local UI gate, not any key material,
    /// so a forgotten PIN can simply be replaced. Throttling is reset too — the
    /// backoff ladder exists to slow PIN guessing, and a reset makes the old
    /// attempts irrelevant.
    private func resetPIN() {
        KeychainStore.resetVaultPIN()
        buffer = ""; revealedIndex = nil; pinLockMessage = nil; phase = .create
        focused = true
    }

    private func submit(_ pin: String) {
        switch phase {
        case .enter:
            guard KeychainStore.pinAttemptAllowed() else {
                pinLockMessage = "Too many attempts — wait \(KeychainStore.pinLockRemainingSeconds())s"
                return
            }
            let ok = KeychainStore.verifyVaultPIN(pin)
            KeychainStore.registerPINResult(success: ok)
            if ok {
                pinLockMessage = nil
                appState.isPrivateVaultUnlocked = true
            } else {
                if !KeychainStore.pinAttemptAllowed() {
                    pinLockMessage = "Too many attempts — wait \(KeychainStore.pinLockRemainingSeconds())s"
                }
                failEntry()
            }
        case .create:
            firstEntry = pin; buffer = ""; revealedIndex = nil; phase = .confirm
        case .confirm:
            if pin == firstEntry {
                KeychainStore.saveVaultPIN(pin)
                appState.isPrivateVaultUnlocked = true
            } else {
                buffer = ""; revealedIndex = nil; phase = .create   // mismatch -> start over
            }
        case .recover:
            // Reached only through the Forgot-PIN button: save the new PIN and
            // unlock (the gate exists to hide files, not to protect keys).
            KeychainStore.saveVaultPIN(pin)
            KeychainStore.registerPINResult(success: true)
            pinLockMessage = nil
            appState.isPrivateVaultUnlocked = true
        }
    }

    private func failEntry() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.4)) { shake = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            shake = false; buffer = ""; revealedIndex = nil
        }
    }

    /// Biometric unlock success flips the exact same flag the PIN path does —
    /// the vault gate re-evaluates and crossfades open. The recovery-blob
    /// backfill is skipped here (it needs the raw PIN); it is best-effort and
    /// runs on the next successful PIN entry.
    private func unlockWithBiometrics() async {
        guard phase == .enter else { return }
        guard KeychainStore.pinAttemptAllowed() else {
            pinLockMessage = "Too many attempts — wait \(KeychainStore.pinLockRemainingSeconds())s"
            return
        }
        let ok = await BiometricUnlock.authenticate(reason: "Unlock the Locked folder")
        if ok {
            // Mirror a PIN success: clear the failure backoff, then unlock.
            KeychainStore.registerPINResult(success: true)
            pinLockMessage = nil
            appState.isPrivateVaultUnlocked = true
        } else {
            pinLockMessage = "\(BiometricUnlock.biometryName) didn't match — enter your PIN."
        }
    }
}

// MARK: - Reliable Key Handling Monitor
//
// SwiftUI's `.onKeyPress` + FocusState is unreliable on macOS: when the TheaterView
// overlay closes, focus is often left dangling, so arrows/space/⌘V silently stop
// working even though `gridFocused = true` was requested. The established app
// pattern (TheaterView) is a local NSEvent monitor that works regardless
// of SwiftUI focus — this is the file browser's copy. It also reclaims ⌘C/⌘V/⌘Z
// from the Edit menu, whose NSText.* actions no-op whenever no text field is focused.
//
// Every callback returns Bool: `true` = handled (the key event is consumed),
// `false` = the event keeps flowing (e.g. no selection, so space/return should
// still activate a focused control, or ⌘C should reach a text field).

private struct FileBrowserKeyMonitorView: NSViewRepresentable {
    var shouldDefer: () -> Bool
    var onMediaPlayPause: () -> Bool
    var onMediaForward: () -> Bool
    var onMediaBackward: () -> Bool
    var onDelete: () -> Bool
    var onDeleteForever: () -> Bool
    var onEscape: () -> Bool
    var onArrow: (Int, Bool) -> Bool
    var onCmdUp: () -> Bool
    var onCmdDown: () -> Bool
    var onSpace: () -> Bool
    var onReturn: () -> Bool
    var onCmdC: () -> Bool
    var onCmdV: () -> Bool
    var onCmdR: () -> Bool
    var onCmdO: () -> Bool
    var onCmdZ: (Bool) -> Bool

    func makeNSView(context: Context) -> FileBrowserKeyView {
        let view = FileBrowserKeyView()
        apply(view)
        return view
    }

    func updateNSView(_ nsView: FileBrowserKeyView, context: Context) {
        apply(nsView)
    }

    private func apply(_ view: FileBrowserKeyView) {
        view.shouldDefer = shouldDefer
        view.onMediaPlayPause = onMediaPlayPause
        view.onMediaForward = onMediaForward
        view.onMediaBackward = onMediaBackward
        view.onDelete = onDelete
        view.onDeleteForever = onDeleteForever
        view.onEscape = onEscape
        view.onArrow = onArrow
        view.onCmdUp = onCmdUp
        view.onCmdDown = onCmdDown
        view.onSpace = onSpace
        view.onReturn = onReturn
        view.onCmdC = onCmdC
        view.onCmdV = onCmdV
        view.onCmdR = onCmdR
        view.onCmdO = onCmdO
        view.onCmdZ = onCmdZ
    }
}

final class FileBrowserKeyView: NSView {
    // This view exists ONLY as an NSEvent-monitor host in `.background` — it
    // must never participate in mouse hit-testing. macOS 26's NSHostingView
    // layering regression can hand clicks to a background-hosted NSView that
    // doesn't opt out (its default AppKit hitTest returns self for any point
    // inside its full-window bounds, swallowing sibling SwiftUI buttons).
    // Overriding hitTest to nil keeps the monitors' coordinate space without
    // ever stealing a click. The key monitoring is event-based
    // (NSEvent.addLocalMonitorForEvents), not view-based, so this is safe.
    override func hitTest(_ point: NSPoint) -> NSView? { return nil }

    var shouldDefer: (() -> Bool)?
    var onMediaPlayPause: (() -> Bool)?
    var onMediaForward: (() -> Bool)?
    var onMediaBackward: (() -> Bool)?
    var onDelete: (() -> Bool)?
    var onDeleteForever: (() -> Bool)?
    var onEscape: (() -> Bool)?
    var onArrow: ((Int, Bool) -> Bool)?
    var onCmdUp: (() -> Bool)?
    var onCmdDown: (() -> Bool)?
    var onSpace: (() -> Bool)?
    var onReturn: (() -> Bool)?
    var onCmdC: (() -> Bool)?
    var onCmdV: (() -> Bool)?
    var onCmdR: (() -> Bool)?
    var onCmdO: (() -> Bool)?
    var onCmdZ: ((Bool) -> Bool)?
    private var monitor: Any?
    private var mediaMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.window != nil else { return event }
                // Only intercept keys destined for our own window — defer to open
                // menus, sheets (settings, note editor, importers), and other windows.
                guard event.window === self.window else { return event }
                // Never steal keys while the user is typing in a text field/view
                // (search bar, PIN entry, …) — those go to the field and the Edit menu.
                if let responder = self.window?.firstResponder,
                   responder is NSTextView || responder is NSTextField {
                    return event
                }
                if self.shouldDefer?() == true { return event }

                let flags = event.modifierFlags
                let isCmd = flags.contains(.command)
                let isOption = flags.contains(.option)
                let isShift = flags.contains(.shift)
                let chars = event.charactersIgnoringModifiers?.lowercased()

                switch event.keyCode {
                case 51: // delete / backspace
                    if isCmd && isOption {
                        if self.onDeleteForever?() == true { return nil }
                    } else if self.onDelete?() == true {
                        return nil
                    }
                    return event
                case 53: // escape
                    if self.onEscape?() == true { return nil }
                    return event
                case 123: // left arrow
                    if self.onArrow?(-1, false) == true { return nil }
                    return event
                case 124: // right arrow
                    if self.onArrow?(1, false) == true { return nil }
                    return event
                case 125: // down arrow
                    if isCmd {
                        if self.onCmdDown?() == true { return nil }
                    } else if self.onArrow?(1, true) == true {
                        return nil
                    }
                    return event
                case 126: // up arrow
                    if isCmd {
                        if self.onCmdUp?() == true { return nil }
                    } else if self.onArrow?(-1, true) == true {
                        return nil
                    }
                    return event
                case 49: // space
                    if self.onSpace?() == true { return nil }
                    return event
                case 98: // F7 (rewind) — function-key mode media control
                    if self.onMediaBackward?() == true { return nil }
                    return event
                case 100: // F8 (play/pause)
                    if self.onMediaPlayPause?() == true { return nil }
                    return event
                case 101: // F9 (forward)
                    if self.onMediaForward?() == true { return nil }
                    return event
                case 36: // return
                    if self.onReturn?() == true { return nil }
                    return event
                default:
                    if isCmd {
                        switch chars {
                        case "c":
                            if self.onCmdC?() == true { return nil }
                        case "v":
                            if self.onCmdV?() == true { return nil }
                        case "r":
                            if self.onCmdR?() == true { return nil }
                        case "o":
                            if self.onCmdO?() == true { return nil }
                        case "z":
                            if self.onCmdZ?(isShift) == true { return nil }
                        default:
                            break
                        }
                        return event
                    }
                    return event
                }
            }
        } else if window == nil && monitor != nil {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        // Media keys are NSSystemDefined events (subtype 8, NX_SUBTYPE_AUX_CONTROL_BUTTONS),
        // NOT keyDown events — a plain key monitor never sees them. Consume only
        // play/next/previous; volume/mute (codes 0/1/7) MUST pass through so the OS
        // still adjusts the system output volume (which is the app's volume).
        // The theater installs its own newer monitor while open, so it wins there;
        // this monitor covers the browser + mini player.
        if window != nil && mediaMonitor == nil {
            mediaMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
                guard let self, self.window != nil, event.subtype.rawValue == 8 else { return event }
                let keyCode = Int((event.data1 & 0xFFFF0000) >> 16)
                let keyFlags = event.data1 & 0x0000FFFF
                let keyState = (keyFlags & 0xFF00) >> 8 // 0xA = down, 0xB = up
                guard keyState == 0xA else { return event }
                switch keyCode {
                case 16: // NX_KEYTYPE_PLAY
                    if self.onMediaPlayPause?() == true { return nil }
                case 17, 19: // NX_KEYTYPE_NEXT / NX_KEYTYPE_FAST
                    if self.onMediaForward?() == true { return nil }
                case 18, 20: // NX_KEYTYPE_PREVIOUS / NX_KEYTYPE_REWIND
                    if self.onMediaBackward?() == true { return nil }
                default:
                    break // volume/mute and everything else: system handles it
                }
                return event
            }
        } else if window == nil && mediaMonitor != nil {
            if let mediaMonitor { NSEvent.removeMonitor(mediaMonitor) }
            mediaMonitor = nil
        }
    }

    func teardown() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let mediaMonitor { NSEvent.removeMonitor(mediaMonitor) }
        mediaMonitor = nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let mediaMonitor { NSEvent.removeMonitor(mediaMonitor) }
    }
}

// MARK: - Share Link Sheet

// Cascade share link so it can
// Cascade user. The link IS the credential — it carries
/// the (base64) share key that unwraps the file's object key, so only someone holding
/// the link can import the file. The share channel lives 7 days, then the cleanup
/// loop deletes it (revoking the link).
struct ShareLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    let link: String
    var fileCount: Int = 1
    @State private var copied = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.swap")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(XTheme.accent)
                .padding(.top, 6)

            Text("Share Link Ready")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)

            Text(fileCount > 1
                ? "Anyone with this link can import all \(fileCount) files into their own cloud.\nThe link carries no visible invite or key material."
                : "Anyone with this link can import the file into their own cloud.\nThe link carries no visible invite or key material.")
                .font(.system(size: 12))
                .foregroundStyle(XTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            HStack(spacing: 8) {
                Text(link)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )

                Button {
                    copy()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(copied ? .green : .white.opacity(0.8))
                        .frame(width: 34, height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.white.opacity(0.07))
                        )
                }
                .buttonStyle(.plain)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            Text(fileCount > 1
                ? "This link expires in 24 hours — after the share channel is deleted, the shared files can no longer be imported."
                : "This link expires in 24 hours — after the share channel is deleted, the file can no longer be imported.")
                .font(.system(size: 10.5))
                .foregroundStyle(XTheme.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            HStack(spacing: 10) {
                // The plain button style hit-tests ONLY the label's frame, so the
                // pill (padding + background) must live INSIDE the label — padding
                // on the button itself expands the visual but not the clickable
                // area, which is why clicking the pill's edges did nothing before.
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.white.opacity(0.07))
                        )
                }
                .buttonStyle(.plain)

                Button {
                    copy()
                } label: {
                    Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(XTheme.accent)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .padding(30)
        .frame(width: 460)
        .background(Color(red: 0.055, green: 0.07, blue: 0.11))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .preferredColorScheme(.dark)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        copied = true
    }
}

/// Shown while a share link is being created (channel setup + chunk forward),
/// so the Share action gives immediate feedback instead of appearing to hang.
struct ShareProgressSheet: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.regular)
                .tint(XTheme.accent)

            Text("Creating Share Link…")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)

            Text("Setting up the share link.\nThis can take a moment for larger files or selections.")
                .font(.system(size: 12))
                .foregroundStyle(XTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(width: 400)
        .background(Color(red: 0.055, green: 0.07, blue: 0.11))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .preferredColorScheme(.dark)
    }
}

