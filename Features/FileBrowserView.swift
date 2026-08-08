import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct FileBrowserView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    @AppStorage("xc.viewMode") private var viewModeRaw = "grid"
    @AppStorage("xc.cardWidth") private var cardWidth = 200.0

    @State private var showImporter = false
    @State private var showNewFolder = false
    @State private var showNewPrivateFolder = false
    @State private var folderName = ""
    @State private var renameTarget: ObjectRecord?
    @State private var renameText = ""
    @FocusState private var gridFocused: Bool
    @FocusState private var searchFocused: Bool
    @State private var showEmptyTrashAlert = false
    @State private var showMiniTransfersPopover = false
    @State private var dropTargeted = false
    @State private var columnCount = 4
    @State private var fabHovering = false
    @Namespace private var viewModeNamespace
    @State private var sortOption: SortOption = .name

    enum SortOption { case name, date, size }

    private var visibleFiles: [ObjectRecord] {
        let base: [ObjectRecord] = {
            let files = appState.files
            switch appState.selectedDestination {
            case .allFiles:
                return files.filter { !$0.trashed && !$0.isPrivate && $0.parentID == appState.currentFolderID }
            case .privateVault:
                return files.filter { !$0.trashed && $0.isPrivate && $0.parentID == appState.currentFolderID }
            case .recent:
                return Array(files.filter { !$0.trashed && !$0.isFolder && !$0.isPrivate }.prefix(20))
            case .favorites:
                return files.filter { $0.isFavorite && !$0.trashed && !$0.isPrivate }
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
            case .trash:
                return files.filter { $0.trashed }
            }
        }()

        let query = appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = query.isEmpty ? base : base.filter { $0.name.lowercased().contains(query) }

        switch sortOption {
        case .name:
            return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .date:
            return filtered.sorted { $0.createdAt > $1.createdAt }
        case .size:
            return filtered.sorted { $0.size > $1.size }
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AppBackground()

            VStack(spacing: 0) {
                if appState.selectedDestination == .privateVault && !appState.isPrivateVaultUnlocked {
                    PrivateVaultLockView()
                } else {
                    topBar

                    if appState.selectedDestination == .transfers {
                        TransfersView()
                    } else if visibleFiles.isEmpty && !appState.isUploading {
                        emptyStateView
                    } else {
                        if viewModeRaw == "list" { listView } else { gridView }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                appState.clearSelection()
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

            // Morphing FAB <-> Transfer Pill overlay (bottom right)
            if appState.selectedDestination != .trash && (appState.selectedDestination != .privateVault || appState.isPrivateVaultUnlocked) {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        morphingFloatingButton
                    }
                }
                .padding(24)
            }
        }
        .ignoresSafeArea(edges: .top)
        .focusable()
        .focusEffectDisabled()
        .focused($gridFocused)
        .onKeyPress(.delete, phases: .down) { press in
            guard !appState.selectedFiles.isEmpty else { return .ignored }
            let isCmd = press.modifiers.contains(.command)
            let isOpt = press.modifiers.contains(.option)

            if isCmd && isOpt {
                appState.bulkDeleteForever()
                return .handled
            } else if appState.selectedDestination == .trash {
                appState.bulkDeleteForever()
                return .handled
            } else {
                appState.bulkTrash()
                return .handled
            }
        }
        .onKeyPress(.escape) {
            appState.clearSelection()
            return .handled
        }
        .onKeyPress("a", phases: .down) { press in
            if press.modifiers.contains(.command) {
                appState.selectAll()
                return .handled
            }
            return .ignored
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
            keyNav(columnCount)
            return .handled
        }
        .onKeyPress(.upArrow, phases: .down) { press in
            if press.modifiers.contains(.command) {
                appState.navigateBack()
                return .handled
            }
            keyNav(-columnCount)
            return .handled
        }
        .onKeyPress(.leftArrow)  { keyNav(-1); return .handled }
        .onKeyPress(.rightArrow) { keyNav(1); return .handled }
        .onKeyPress(.space) {
            if let file = appState.selectedFile, !file.isFolder {
                appState.theaterFile = file
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.return) {
            if let f = appState.selectedFile { open(f); return .handled }
            return .ignored
        }
        .onDrop(of: [UTType.item], isTargeted: $dropTargeted) { providers in
            importDrops(providers)
        }
        .overlay {
            if dropTargeted { dropOverlay }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                appState.startUpload(url: url)
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
            Text("Files inside a private folder are encrypted on your Mac before upload. Telegram only sees noise.")
        }
        .alert("Rename", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
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
        .alert("xCloud", isPresented: Binding(
            get: { appState.alertMessage != nil },
            set: { if !$0 { appState.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.alertMessage ?? "")
        }
    }

    // MARK: - Top Bar

    private var sortPickerContent: some View {
        Group {
            Button("Sort by Name") { sortOption = .name }
            Button("Sort by Date") { sortOption = .date }
            Button("Sort by Size") { sortOption = .size }
        }
    }

    private var topBar: some View {
        @Bindable var appState = appState
        return ZStack {
            // LEFT — page heading
            HStack(spacing: 8) {
                if appState.selectedDestination == .allFiles && appState.currentFolderID != nil {
                    Button {
                        appState.navigateBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("Back")
                }

                if appState.selectedDestination == .privateVault {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.red)
                }

                Text(headingTitle)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("\(visibleFiles.count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.white.opacity(0.08)))

                Spacer()
            }

            // CENTER — search, truly centered via ZStack
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                TextField("Search", text: $appState.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .focused($searchFocused)
                if !appState.searchText.isEmpty {
                    Button { appState.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(width: 360, height: 35)
            .contentShape(Capsule())
            .glassEffect(searchFocused ? .regular.interactive() : .regular, in: .capsule)
            .onTapGesture { searchFocused = true }
            .background(
                Button("") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .hidden()
            )

            // RIGHT — controls
            HStack(spacing: 10) {
                Spacer()

                if appState.selectedDestination == .trash && !visibleFiles.isEmpty {
                    Button(role: .destructive) {
                        showEmptyTrashAlert = true
                    } label: {
                        Image(systemName: "trash.slash")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.red)
                            .frame(width: 32, height: 32)
                            .contentShape(Circle())
                            .glassEffect(.regular.interactive(), in: .circle)
                            .overlay(Circle().strokeBorder(.red.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Empty Trash")
                }

                if appState.selectedDestination == .privateVault && appState.isPrivateVaultUnlocked {
                    Button {
                        appState.isPrivateVaultUnlocked = false
                    } label: {
                        Label("Lock Now", systemImage: "lock.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .glassEffect(.regular, in: .capsule)
                            .overlay(Capsule().strokeBorder(.red.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Lock Private Vault")
                }

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

                // Sort Menu Button
                Menu { sortPickerContent } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(.black.opacity(0.22), ignoresSafeAreaEdges: .top)
        .overlay(alignment: .bottom) {
            Divider().overlay(.white.opacity(0.08))
        }
    }

    private var headingTitle: String {
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
                Label(appState.selectedDestination == .privateVault ? "Upload Encrypted File" : "Upload File", systemImage: "arrow.up.doc.fill")
            }
            Divider()
            if appState.selectedDestination == .privateVault {
                Button {
                    folderName = ""
                    showNewPrivateFolder = true
                } label: {
                    Label("New Private Folder", systemImage: "lock.shield.fill")
                }
            } else {
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

    private var gridView: some View {
        GeometryReader { geo in
            let cols = max(2, Int(geo.size.width / cardWidth))
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    // Folders Section
                    if !currentFolders.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Folders")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(XTheme.textPrimary)

                            LazyVGrid(
                                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: min(cols, 4)),
                                spacing: 10
                            ) {
                                ForEach(currentFolders) { folder in
                                    FileGridItem(file: folder, isSelected: appState.selectedFiles.contains(folder.id), renameTarget: $renameTarget, renameText: $renameText)
                                        .onTapGesture(count: 2) { open(folder) }
                                        .simultaneousGesture(TapGesture(count: 1).onEnded { select(folder) })
                                        .contextMenu { menu(for: folder) }
                                        .onDrag { NSItemProvider(object: folder.id as NSString) }
                                }
                            }
                        }
                    }

                    // Files Section
                    if !currentFiles.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            if !currentFolders.isEmpty {
                                Text("Files")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(XTheme.textPrimary)
                            }

                            LazyVGrid(
                                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: cols),
                                spacing: 12
                            ) {
                                ForEach(currentFiles) { file in
                                    FileGridItem(file: file, isSelected: appState.selectedFiles.contains(file.id), renameTarget: $renameTarget, renameText: $renameText)
                                        .onTapGesture(count: 2) { open(file) }
                                        .simultaneousGesture(TapGesture(count: 1).onEnded { select(file) })
                                        .contextMenu { menu(for: file) }
                                        .onDrag { NSItemProvider(object: file.id as NSString) }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 80)
            }
            .contextMenu {
                Button("New Folder") { showNewFolder = true }
                Button("New Private Folder") { showNewPrivateFolder = true }
                Button("Upload Files…") { showImporter = true }
                Divider()
                Menu("Sort By") { sortPickerContent }
            }
            .onChange(of: geo.size.width, initial: true) {
                columnCount = max(2, Int(geo.size.width / cardWidth))
            }
        }
    }

    // MARK: - List

    private var listView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !currentFolders.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Folders")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(XTheme.textPrimary)

                        LazyVStack(spacing: 4) {
                            ForEach(currentFolders) { folder in
                                FileListRow(file: folder, isSelected: appState.selectedFiles.contains(folder.id), renameTarget: $renameTarget, renameText: $renameText)
                                    .onTapGesture(count: 2) { open(folder) }
                                    .simultaneousGesture(TapGesture(count: 1).onEnded { select(folder) })
                                    .contextMenu { menu(for: folder) }
                                    .onDrag { NSItemProvider(object: folder.id as NSString) }
                            }
                        }
                    }
                }

                if !currentFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        if !currentFolders.isEmpty {
                            Text("Files")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(XTheme.textPrimary)
                        }

                        LazyVStack(spacing: 4) {
                            ForEach(currentFiles) { file in
                                FileListRow(file: file, isSelected: appState.selectedFiles.contains(file.id), renameTarget: $renameTarget, renameText: $renameText)
                                    .onTapGesture(count: 2) { open(file) }
                                    .simultaneousGesture(TapGesture(count: 1).onEnded { select(file) })
                                    .contextMenu { menu(for: file) }
                                    .onDrag { NSItemProvider(object: file.id as NSString) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 80)
        }
        .contextMenu {
            Button("New Folder") { showNewFolder = true }
            Button("New Private Folder") { showNewPrivateFolder = true }
            Button("Upload Files…") { showImporter = true }
            Divider()
            Menu("Sort By") { sortPickerContent }
        }
    }

    // MARK: - Actions

    private func open(_ file: ObjectRecord) {
        if file.isFolder {
            appState.openFolder(file)
        } else if isAudioFile(file) {
            AudioPlayerEngine.shared.play(file: file, in: visibleFiles)
        } else {
            appState.theaterFile = file
        }
    }

    private func isAudioFile(_ file: ObjectRecord) -> Bool {
        let ext = (file.name as NSString).pathExtension.lowercased()
        return file.mime.hasPrefix("audio/") || ["mp3", "m4a", "wav", "flac", "aac", "ogg"].contains(ext)
    }

    private func keyNav(_ delta: Int) {
        let files = visibleFiles
        guard !files.isEmpty else { return }
        let current = files.firstIndex { appState.selectedFiles.contains($0.id) }
        let next: Int
        if let current {
            next = min(max(current + delta, 0), files.count - 1)
        } else {
            next = delta > 0 ? 0 : files.count - 1
        }
        appState.selectedFiles = [files[next].id]
    }

    private func select(_ file: ObjectRecord) {
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

            if appState.selectedDestination == .allFiles || appState.selectedDestination == .privateVault {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyIcon: String {
        switch appState.selectedDestination {
        case .trash: return "trash"
        case .favorites: return "star"
        case .video: return "play.rectangle"
        case .audio: return "music.note"
        case .documents: return "doc.text"
        default: return "cloud"
        }
    }

    private var emptyTitle: String {
        if appState.selectedDestination == .trash { return "Trash is Empty" }
        if appState.currentFolderID != nil { return "Folder is Empty" }
        return "Nothing Here Yet"
    }

    private var emptySubtitle: String {
        appState.selectedDestination == .allFiles
        ? "Drop files here or tap + to get started"
        : "Files matching this category will appear here."
    }
}

// MARK: - Context Menu View Component

struct FileItemContextMenu: View {
    @Environment(AppState.self) private var appState
    let file: ObjectRecord
    @Binding var renameTarget: ObjectRecord?
    @Binding var renameText: String

    var body: some View {
        if !file.isFolder {
            Button {
                appState.theaterFile = file
            } label: {
                Label("Quick Look", systemImage: "eye")
            }
            Button {
                appState.openFile(file)
            } label: {
                Label("Open", systemImage: "arrow.up.forward.app")
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
        }
        Button {
            renameText = file.name
            renameTarget = file
        } label: {
            Label("Rename…", systemImage: "pencil")
        }
        if !file.isFolder {
            Button {
                appState.toggleFavorite(file)
            } label: {
                Label(file.isFavorite ? "Remove Favorite" : "Add Favorite", systemImage: file.isFavorite ? "star.slash" : "star")
            }
            Menu {
                Button("Root") { appState.moveObject(id: file.id, to: nil) }
                ForEach(appState.files.filter {
                    $0.isFolder && !$0.trashed && $0.id != file.id
                }) { folder in
                    Button(folder.name) {
                        appState.moveObject(id: file.id, to: folder.id)
                    }
                }
            } label: {
                Label("Move to Folder", systemImage: "folder.badge.gearshape")
            }
        }
        Divider()
        if file.trashed {
            Button {
                appState.setTrashed(file, false)
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) {
                appState.deleteForever(file)
            } label: {
                Label("Delete Forever", systemImage: "trash.slash")
            }
        } else {
            Button(role: .destructive) {
                appState.setTrashed(file, true)
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            Button(role: .destructive) {
                appState.deleteForever(file)
            } label: {
                Label("Delete Permanently", systemImage: "trash.slash")
            }
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
}

// MARK: - Grid Item (Google Drive-style clean card)

struct FileGridItem: View {
    @Environment(AppState.self) private var appState
    let file: ObjectRecord
    let isSelected: Bool
    @Binding var renameTarget: ObjectRecord?
    @Binding var renameText: String
    @State private var hovering = false
    @State private var dropTargeted = false
    @State private var thumbURL: URL? = nil

    private var itemCount: Int {
        appState.files.filter { $0.parentID == file.id && !$0.trashed }.count
    }

    var body: some View {
        Group {
            if file.isFolder {
                folderCard
            } else {
                fileCard
            }
        }
        .contentShape(Rectangle())
        .scaleEffect(hovering ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .task(id: file.id) {
            thumbURL = await ThumbnailService.shared.thumbnailURL(for: file)
        }
        .onHover { hovering = $0 }
        .onDrop(of: [UTType.text], isTargeted: $dropTargeted) { providers in
            guard file.isFolder else { return false }
            return dropIntoFolder(providers)
        }
    }

    private var folderCard: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(file.isPrivate ? XTheme.categoryRed : XTheme.accent)

                if file.isPrivate {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(Circle().fill(XTheme.categoryRed))
                        .offset(x: 4, y: 2)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(XTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("\(itemCount) item\(itemCount == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(XTheme.textTertiary)
            }

            Spacer(minLength: 0)

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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(height: 54)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? XTheme.accent.opacity(0.18) : (hovering ? Color.white.opacity(0.08) : Color.white.opacity(0.04)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? XTheme.accent : (dropTargeted ? XTheme.accent : Color.white.opacity(0.06)), lineWidth: isSelected || dropTargeted ? 1.5 : 1)
        )
    }

    private var fileCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color.white.opacity(0.03)

                if let thumbURL, let ns = NSImage(contentsOf: thumbURL) {
                    Image(nsImage: ns)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else {
                    Image(systemName: fileIcon)
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(XTheme.textTertiary)
                }
            }
            .frame(height: 115)
            .clipped()

            HStack(spacing: 8) {
                Image(systemName: fileIcon)
                    .font(.system(size: 12))
                    .foregroundStyle(XTheme.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(XTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                        .font(.system(size: 10))
                        .foregroundStyle(XTheme.textTertiary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.04))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? XTheme.accent.opacity(0.18) : (hovering ? Color.white.opacity(0.08) : Color.white.opacity(0.04)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? XTheme.accent : Color.white.opacity(0.06), lineWidth: isSelected ? 1.5 : 1)
        )
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 4) {
                if file.isPrivate {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(Circle().fill(XTheme.categoryRed))
                }

                Menu {
                    FileItemContextMenu(file: file, renameTarget: $renameTarget, renameText: $renameText)
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(0.55))
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
            }
            .padding(6)
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

    private func dropIntoFolder(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: NSString.self) {
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let targetID = object as? String else { return }
                Task { @MainActor in
                    appState.moveObject(id: targetID, to: file.id)
                }
            }
            handled = true
        }
        return handled
    }
}

// MARK: - List Row

struct FileListRow: View {
    @Environment(AppState.self) private var appState
    let file: ObjectRecord
    let isSelected: Bool
    @Binding var renameTarget: ObjectRecord?
    @Binding var renameText: String
    @State private var hovering = false
    @State private var dropTargeted = false
    @State private var thumbURL: URL? = nil

    private var itemCount: Int {
        appState.files.filter { $0.parentID == file.id && !$0.trashed }.count
    }

    var body: some View {
        HStack(spacing: 14) {
            rowIcon

            Text(file.name)
                .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(XTheme.textPrimary)
                .lineLimit(1)

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

            Menu {
                FileItemContextMenu(file: file, renameTarget: $renameTarget, renameText: $renameText)
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.10))
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .frame(width: 24, height: 24)
                .glassEffect(.regular.interactive(), in: .circle)
                .contentShape(Circle())
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isSelected ? XTheme.accent.opacity(0.18)
                    : hovering ? Color.white.opacity(0.04)
                    : Color.clear
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? XTheme.accent.opacity(0.5) : .clear, lineWidth: 1)
        )
        .overlay(alignment: .trailing) {
            if file.isPrivate {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Circle().fill(XTheme.categoryRed.opacity(0.9)))
                    .padding(.trailing, 6)
            }
        }
        .task(id: file.id) {
            thumbURL = await ThumbnailService.shared.thumbnailURL(for: file)
        }
        .onHover { hovering = $0 }
        .onDrop(of: [UTType.text], isTargeted: $dropTargeted) { providers in
            guard file.isFolder else { return false }
            var handled = false
            for provider in providers where provider.canLoadObject(ofClass: NSString.self) {
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let id = object as? String else { return }
                    Task { @MainActor in
                        appState.moveObject(id: id, to: file.id)
                    }
                }
                handled = true
            }
            return handled
        }
    }

    @ViewBuilder
    private var rowIcon: some View {
        if file.isFolder {
            Image(systemName: file.isPrivate ? "lock.folder.fill" : "folder.fill")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(file.isPrivate ? XTheme.categoryRed : XTheme.accent)
                .frame(width: 32, height: 32)
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
    @FocusState private var focused: Bool

    enum Phase { case enter, create, confirm }

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 24) {
                ZStack {
                    Circle().fill(XTheme.accent.opacity(0.15)).frame(width: 72, height: 72)
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 30)).foregroundStyle(XTheme.accent)
                }
                VStack(spacing: 6) {
                    Text(title).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
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
            phase = KeychainStore.loadVaultPINHash() == nil ? .create : .enter
        }
        .onTapGesture { focused = true }
    }

    private var title: String {
        switch phase {
        case .enter: "Private Vault Locked"
        case .create: "Create a PIN"
        case .confirm: "Confirm PIN"
        }
    }
    private var subtitle: String {
        switch phase {
        case .enter: "Enter your 4-digit PIN to unlock encrypted files."
        case .create: "Choose a 4-digit PIN for your Private Vault."
        case .confirm: "Enter the same PIN again."
        }
    }

    private func submit(_ pin: String) {
        switch phase {
        case .enter:
            if KeychainStore.verifyVaultPIN(pin) {
                appState.isPrivateVaultUnlocked = true
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.4)) { shake = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    shake = false; buffer = ""; revealedIndex = nil
                }
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
        }
    }
}
