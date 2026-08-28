#if os(iOS)
import SwiftUI
import PDFKit

// MARK: - Reusable Blue Ellipsis Menu Button

struct BlueEllipsisMenu<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.blue)
        }
    }
}

// MARK: - Reusable Bottom Item Count Footer

struct PageItemCountFooter: View {
    let count: Int
    var noun: String = "item"
    var showSyncStatus: Bool = true

    var body: some View {
        VStack(spacing: 4) {
            Text("\(count) \(count == 1 ? noun : "\(noun)s")")
                .font(.subheadline.bold())
                .foregroundStyle(.primary)
            if showSyncStatus {
                Text("Synced with Cascade")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 20)
    }
}

// MARK: - Reusable Search Empty State

struct NoSearchResultsView: View {
    let query: String

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("No Results")
                .font(.title2.bold())
            Text("No results found for “\(query)”.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }
}

// MARK: - Share Sheet Helper

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - PDFKit Represented View

struct PDFKitRepresentedView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.document = PDFDocument(url: url)
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        if pdfView.document?.documentURL != url {
            pdfView.document = PDFDocument(url: url)
        }
    }
}

// MARK: - File Quick Look / Preview View

struct FilePreviewView: View {
    let file: FileItem
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var isDownloading = false
    @State private var downloadProgress: Double = 0
    @State private var downloadStatus: String = ""
    @State private var localURL: URL? = nil
    @State private var textContent: String? = nil
    @State private var showShareSheet = false
    @State private var showInfo = false
    @State private var errorMessage: String? = nil
    @State private var showControls = false

    private var isPDF: Bool {
        file.name.lowercased().hasSuffix(".pdf") || file.mime == "application/pdf"
    }

    private var isText: Bool {
        let ext = (file.name as NSString).pathExtension.lowercased()
        return ["txt", "md", "markdown", "json", "csv", "swift", "py", "sh", "log"].contains(ext) || file.mime.hasPrefix("text/")
    }

    /// Whether the current file resolves to an image that can be displayed full-screen.
    private var isImageContent: Bool {
        guard let localURL else { return false }
        return loadedImage(for: localURL) != nil
    }

    var body: some View {
        ZStack {
            // Black background for images (like Apple Files), system background for other files
            if isImageContent {
                Color.black.ignoresSafeArea()
            } else {
                Color(.systemBackground).ignoresSafeArea()
            }

            if let localURL {
                if let uiImage = loadedImage(for: localURL) {
                    // Apple-Files-style image viewer: aspect-fit, centered, black background
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showControls.toggle()
                            }
                        }
                } else if isPDF {
                    PDFKitRepresentedView(url: localURL)
                        .edgesIgnoringSafeArea(.bottom)
                } else if isText, let textContent {
                    ScrollView {
                        Text(textContent)
                            .font(.system(.body, design: .monospaced))
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    cachedFileFallback(localURL)
                }
            } else if isDownloading {
                downloadingView
            } else {
                notDownloadedView
            }
        }
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(isImageContent && !showControls ? .hidden : .visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    if let localURL {
                        Button {
                            showShareSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    } else if !isDownloading {
                        Button {
                            startDownload()
                        } label: {
                            Image(systemName: "arrow.down.circle")
                        }
                    }

                    BlueEllipsisMenu {
                        Button {
                            appState.toggleFavorite(file)
                        } label: {
                            Label(file.isFavorite ? "Unfavorite" : "Favorite", systemImage: file.isFavorite ? "heart.slash" : "heart")
                        }

                        Button {
                            appState.togglePin(file)
                        } label: {
                            Label(file.isPinned ? "Remove Download" : "Keep Downloaded", systemImage: file.isPinned ? "arrow.down.circle.fill" : "arrow.down.circle")
                        }

                        Divider()

                        Button {
                            showInfo = true
                        } label: {
                            Label("Get Info", systemImage: "info.circle")
                        }

                        Divider()

                        Button(role: .destructive) {
                            appState.trashFile(file)
                            dismiss()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }

                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .statusBarHidden(isImageContent && !showControls)
        .sheet(isPresented: $showShareSheet) {
            if let localURL {
                ShareSheet(items: [localURL])
            }
        }
        .alert("File Info", isPresented: $showInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.getInfo(file))
        }
        .task {
            checkLocalFile()
            if localURL == nil && (file.isImage || file.size < 15 * 1024 * 1024) && !file.isFolder {
                startDownload()
            }
        }
    }

    private func loadedImage(for url: URL) -> UIImage? {
        if let img = UIImage(contentsOfFile: url.path) {
            return img
        }
        if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
            return img
        }
        return nil
    }

    private func checkLocalFile() {
        if appState.isCached(file) {
            let url = appState.cachedURL(for: file)
            self.localURL = url
            if isText, let content = try? String(contentsOf: url) {
                self.textContent = content
            }
        }
    }

    private func startDownload() {
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        downloadStatus = "Starting download…"
        errorMessage = nil

        Task {
            do {
                if let url = try await appState.downloadFile(file, progress: { status, p in
                    Task { @MainActor in
                        self.downloadStatus = status
                        self.downloadProgress = p
                    }
                }) {
                    await MainActor.run {
                        self.localURL = url
                        self.isDownloading = false
                        if self.isText, let content = try? String(contentsOf: url) {
                            self.textContent = content
                        }
                    }
                } else {
                    await MainActor.run {
                        self.errorMessage = "Download failed."
                        self.isDownloading = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isDownloading = false
                }
            }
        }
    }

    private var downloadingView: some View {
        VStack(spacing: 20) {
            if let thumbData = file.thumbnailData, let img = UIImage(data: thumbData) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .opacity(0.7)
            } else {
                Image(systemName: file.systemIcon)
                    .font(.system(size: 64))
                    .foregroundStyle(.blue)
            }

            VStack(spacing: 8) {
                Text(downloadStatus.isEmpty ? "Downloading…" : downloadStatus)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ProgressView(value: downloadProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 200)

                Text("\(Int(downloadProgress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(32)
    }

    private var notDownloadedView: some View {
        VStack(spacing: 20) {
            if let thumbData = file.thumbnailData, let img = UIImage(data: thumbData) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 4)
            } else {
                Image(systemName: file.systemIcon)
                    .font(.system(size: 64))
                    .foregroundStyle(.blue)
            }

            VStack(spacing: 6) {
                Text(file.name)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                if let size = file.formattedSize {
                    Text(size)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text("Created \(file.formattedDate)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.top, 4)
                }
            }

            Button {
                startDownload()
            } label: {
                Label("Download File", systemImage: "arrow.down.circle.fill")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .padding(32)
    }

    private func cachedFileFallback(_ url: URL) -> some View {
        VStack(spacing: 20) {
            Image(systemName: file.systemIcon)
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            VStack(spacing: 6) {
                Text(file.name)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                if let size = file.formattedSize {
                    Text(size)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text("Downloaded")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
            }

            Button {
                showShareSheet = true
            } label: {
                Label("Share or Export", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}

// MARK: - Root View

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: Tab = .browse

    enum Tab: Hashable {
        case recents
        case shared
        case browse
    }

    var body: some View {
        ZStack {
            if appState.isInitialLoading {
                loadingView
            } else if TelegramClient.shared.isAuthorized {
                mainTabs
            } else {
                LoginGateView()
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 20) {
            Image("CascadeLogo")
                .resizable()
                .renderingMode(.original)
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
            ProgressView()
        }
    }

    private var mainTabs: some View {
        @Bindable var appState = appState
        return TabView(selection: $selectedTab) {
            RecentsView()
                .tabItem {
                    Label("Recents", systemImage: "clock")
                }
                .tag(Tab.recents)

            SharedView()
                .tabItem {
                    Label("Shared", systemImage: "folder.badge.person.crop")
                }
                .tag(Tab.shared)

            BrowseView()
                .tabItem {
                    Label("Browse", systemImage: "folder")
                }
                .tag(Tab.browse)
        }
        .task {
            if appState.allFiles.isEmpty {
                await appState.completePostAuthSetup()
            }
        }
        .fullScreenCover(item: $appState.theaterFile) { file in
            NavigationStack {
                VideoPlaybackView(file: file)
            }
        }
        .sheet(item: Binding(
            get: {
                if let file = appState.presentedFile, !file.isVideo, !file.isAudio {
                    return file
                }
                return nil
            },
            set: { appState.presentedFile = $0 }
        )) { file in
            NavigationStack {
                FilePreviewView(file: file)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                appState.isVaultLocked = true
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let track = appState.currentAudioTrack {
                AudioMiniPlayerView(track: track)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $appState.showFullAudioPlayer) {
            if let track = appState.currentAudioTrack {
                FullAudioPlayerView(track: track)
                    .presentationDragIndicator(.visible)
            }
        }
    }
}

// MARK: - Browse Destination Enum

enum BrowseDestination: Hashable {
    case cascadeDrive
    case privateVault
    case transfers
    case archive
    case trash
    case favorites
    case downloads
    case photos
    case videos
    case audio
    case documents
    case tag(name: String)
}

// MARK: - Browse View (Files-app style with Locations, Media, Tags)

struct BrowseView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var showSettings = false
    @State private var locationsExpanded = true
    @State private var favoritesExpanded = true
    @State private var mediaExpanded = true
    @State private var tagsExpanded = true
    @State private var navPath: [BrowseDestination] = [.cascadeDrive]

    var body: some View {
        NavigationStack(path: $navPath) {
            List {
                // Locations section
                Section {
                    if locationsExpanded {
                        NavigationLink(value: BrowseDestination.cascadeDrive) {
                            locationRow(icon: "icloud", name: "Cascade Drive", color: .blue)
                        }

                        NavigationLink(value: BrowseDestination.privateVault) {
                            locationRow(icon: "lock", name: "Private Vault", color: .blue)
                        }

                        NavigationLink(value: BrowseDestination.transfers) {
                            locationRow(icon: "arrow.up.arrow.down", name: "Transfers", color: .blue)
                        }

                        NavigationLink(value: BrowseDestination.archive) {
                            locationRow(icon: "archivebox", name: "Archive", color: .blue)
                        }

                        NavigationLink(value: BrowseDestination.trash) {
                            locationRow(icon: "trash", name: "Recently Deleted", color: .blue)
                        }
                    }
                } header: {
                    sectionHeader(title: "Locations", isExpanded: $locationsExpanded)
                }

                // Favorites section
                Section {
                    if favoritesExpanded {
                        NavigationLink(value: BrowseDestination.favorites) {
                            locationRow(icon: "star", name: "Favorites", color: .blue)
                        }

                        NavigationLink(value: BrowseDestination.downloads) {
                            locationRow(icon: "arrow.down.circle", name: "Downloads", color: .blue)
                        }
                    }
                } header: {
                    sectionHeader(title: "Favorites", isExpanded: $favoritesExpanded)
                }

                // Media section
                Section {
                    if mediaExpanded {
                        NavigationLink(value: BrowseDestination.photos) {
                            locationRow(icon: "photo", name: "Photos", color: .blue)
                        }

                        NavigationLink(value: BrowseDestination.videos) {
                            locationRow(icon: "film", name: "Videos", color: .blue)
                        }

                        NavigationLink(value: BrowseDestination.audio) {
                            locationRow(icon: "music.note", name: "Audio", color: .blue)
                        }

                        NavigationLink(value: BrowseDestination.documents) {
                            locationRow(icon: "doc.text", name: "Documents", color: .blue)
                        }
                    }
                } header: {
                    sectionHeader(title: "Media", isExpanded: $mediaExpanded)
                }

                // Tags section
                Section {
                    if tagsExpanded {
                        tagRow(name: "Red", color: .red)
                        tagRow(name: "Orange", color: .orange)
                        tagRow(name: "Yellow", color: .yellow)
                        tagRow(name: "Green", color: .green)
                        tagRow(name: "Blue", color: .blue)
                        tagRow(name: "Purple", color: .purple)
                        tagRow(name: "Gray", color: .gray)
                    }
                } header: {
                    sectionHeader(title: "Tags", isExpanded: $tagsExpanded)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Browse")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    BlueEllipsisMenu {
                        Button { } label: {
                            Label("Scan Documents", systemImage: "document.viewfinder")
                        }
                        Divider()
                        Button {
                            showSettings = true
                        } label: {
                            Label("Settings", systemImage: "gear")
                        }
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .navigationDestination(for: BrowseDestination.self) { destination in
                switch destination {
                case .cascadeDrive:
                    FileBrowserView(folderID: "", folderTitle: "Cascade Drive")
                case .privateVault:
                    PrivateVaultView()
                case .transfers:
                    TransfersView()
                case .archive:
                    ArchiveView()
                case .trash:
                    TrashView()
                case .favorites:
                    FavoritesView()
                case .downloads:
                    FileBrowserView(folderID: "", folderTitle: "Downloads")
                case .photos:
                    PhotosView()
                case .videos:
                    VideosView()
                case .audio:
                    AudioView()
                case .documents:
                    DocumentsView()
                case .tag(let name):
                    TagFilterView(tag: name, color: tagColor(for: name))
                }
            }
        }
    }

    private func sectionHeader(title: String, isExpanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.blue)
            }
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .padding(.vertical, 4)
    }

    private func locationRow(icon: String, name: String, color: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(color)
                .frame(width: 28, height: 28, alignment: .center)
            Text(name)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 2)
    }

    private func tagColor(for name: String) -> Color {
        switch name.lowercased() {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        default: return .gray
        }
    }

    private func tagRow(name: String, color: Color) -> some View {
        NavigationLink(value: BrowseDestination.tag(name: name)) {
            HStack(spacing: 14) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(color)
                    .frame(width: 28, height: 28, alignment: .center)
                Text(name)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.primary)
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Tag Filter View

struct TagFilterView: View {
    let tag: String
    let color: Color
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "circle.circle")
                .font(.system(size: 64))
                .foregroundStyle(color)
            Text("No Tagged Files")
                .font(.title2.bold())
            Text("Files tagged as \"\(tag)\" will appear here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .navigationTitle(tag)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                BlueEllipsisMenu {
                    Button { } label: {
                        Label("Select", systemImage: "checkmark.circle")
                    }
                }
            }
        }
    }
}

// MARK: - Recents View

struct RecentsView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var viewMode: ViewMode = .grid
    @State private var sortBy: SortOption = .date
    @State private var sortAscending = true
    @State private var isSelecting = false
    @State private var selectedFileIDs: Set<String> = []

    enum ViewMode: String, CaseIterable {
        case grid = "Icons"
        case list = "List"
    }

    enum SortOption: String, CaseIterable {
        case date = "Date"
        case name = "Name"
        case size = "Size"
    }

    var body: some View {
        NavigationStack {
            Group {
                if filteredFiles.isEmpty {
                    if !searchText.isEmpty {
                        NoSearchResultsView(query: searchText)
                    } else {
                        emptyState
                    }
                } else if viewMode == .grid {
                    gridView
                } else {
                    listView
                }
            }
            .navigationTitle("Recents")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .toolbar {
                if isSelecting {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(selectedFileIDs.count == filteredFiles.count ? "Deselect All" : "Select All") {
                            if selectedFileIDs.count == filteredFiles.count {
                                selectedFileIDs.removeAll()
                            } else {
                                selectedFileIDs = Set(filteredFiles.map(\.id))
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            isSelecting = false
                            selectedFileIDs.removeAll()
                        }
                        .fontWeight(.semibold)
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        BlueEllipsisMenu {
                            Button {
                                isSelecting = true
                            } label: {
                                Label("Select", systemImage: "checkmark.circle")
                            }
                            Button { } label: {
                                Label("Scan Documents", systemImage: "document.viewfinder")
                            }

                            Divider()

                            Button {
                                viewMode = .grid
                            } label: {
                                HStack {
                                    Text("Icons")
                                    if viewMode == .grid {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }

                            Button {
                                viewMode = .list
                            } label: {
                                HStack {
                                    Text("List")
                                    if viewMode == .list {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }

                            Divider()

                            ForEach(SortOption.allCases, id: \.self) { option in
                                Button {
                                    if sortBy == option {
                                        sortAscending.toggle()
                                    } else {
                                        sortBy = option
                                        sortAscending = true
                                    }
                                } label: {
                                    HStack {
                                        Text(option.rawValue)
                                        if sortBy == option {
                                            Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting {
                    selectionBottomBar
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Material.ultraThinMaterial, for: .navigationBar)
            .task {
                await appState.syncRecentsFromCloud()
            }
            .refreshable {
                async let f1: () = appState.loadAllFiles()
                async let f2: () = appState.syncRecentsFromCloud()
                _ = await (f1, f2)
            }
        }
    }

    private var selectionBottomBar: some View {
        HStack {
            Button {
                appState.toggleFavorites(selectedFileIDs)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "heart")
                        .font(.system(size: 20))
                    Text("Favorite")
                        .font(.system(size: 10))
                }
            }
            .disabled(selectedFileIDs.isEmpty)

            Spacer()

            Button {
                appState.toggleArchive(selectedFileIDs)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 20))
                    Text("Archive")
                        .font(.system(size: 10))
                }
            }
            .disabled(selectedFileIDs.isEmpty)

            Spacer()

            Button(role: .destructive) {
                appState.trashFiles(selectedFileIDs)
                selectedFileIDs.removeAll()
                isSelecting = false
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "trash")
                        .font(.system(size: 20))
                    Text("Delete")
                        .font(.system(size: 10))
                }
                .foregroundStyle(selectedFileIDs.isEmpty ? Color.secondary : Color.red)
            }
            .disabled(selectedFileIDs.isEmpty)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 10)
        .background(Material.bar)
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "clock")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)
                Text("No Recent Files")
                    .font(.title2.bold())
                Text("Files you open or add will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 100)
        }
    }

    private var recentFiles: [FileItem] {
        let fileMap = Dictionary(uniqueKeysWithValues: appState.allFiles.filter { !$0.isFolder && !$0.trashed && !$0.isArchived }.map { ($0.id, $0) })
        let ordered = appState.recentFileIDs.compactMap { fileMap[$0] }
        switch sortBy {
        case .date:
            return sortAscending ? ordered : ordered.reversed()
        case .name:
            return ordered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == (sortAscending ? .orderedAscending : .orderedDescending) }
        case .size:
            return ordered.sorted { sortAscending ? ($0.size > $1.size) : ($0.size < $1.size) }
        }
    }

    private var filteredFiles: [FileItem] {
        let files = Array(recentFiles.prefix(40))
        guard !searchText.isEmpty else { return files }
        return files.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var gridView: some View {
        ScrollView {
            VStack(spacing: 0) {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ], spacing: 20) {
                    ForEach(filteredFiles) { file in
                        if isSelecting {
                            FileGridItem(
                                file: file,
                                isSelecting: true,
                                isSelected: selectedFileIDs.contains(file.id)
                            ) {
                                toggleSelection(file.id)
                            }
                        } else {
                            FileGridItem(file: file) {
                                appState.openFile(file)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer(minLength: 40)

                PageItemCountFooter(count: filteredFiles.count)
                    .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var listView: some View {
        List {
            ForEach(filteredFiles) { file in
                if isSelecting {
                    FileRow(
                        file: file,
                        isSelecting: true,
                        isSelected: selectedFileIDs.contains(file.id)
                    ) {
                        toggleSelection(file.id)
                    }
                } else {
                    FileRow(file: file) {
                        appState.openFile(file)
                    }
                }
            }

            PageItemCountFooter(count: filteredFiles.count)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
    }

    private func toggleSelection(_ id: String) {
        if selectedFileIDs.contains(id) {
            selectedFileIDs.remove(id)
        } else {
            selectedFileIDs.insert(id)
        }
    }
}

// MARK: - Shared View (Files-app style with banner & menu)

struct SharedView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var showBanner = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if showBanner {
                        familyBanner
                    }

                    VStack(spacing: 16) {
                        Image(systemName: "folder.badge.person.crop")
                            .font(.system(size: 48))
                            .foregroundStyle(.blue)
                        Text("No Shared Files")
                            .font(.title2.bold())
                        Text("Files and folders shared with you will appear here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .padding(.top, showBanner ? 20 : 80)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .navigationTitle("Shared")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    BlueEllipsisMenu {
                        Button { } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }
                        Button { } label: {
                            Label("Scan Documents", systemImage: "document.viewfinder")
                        }
                    }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Material.ultraThinMaterial, for: .navigationBar)
        }
    }

    private var familyBanner: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.blue.gradient)
                    .frame(width: 44, height: 44)
                Image(systemName: "person.2.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Share Files with Family")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("Invite family members to share files in one place.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button { } label: {
                    Text("Create a Family Folder")
                        .font(.subheadline.bold())
                        .foregroundStyle(.blue)
                        .padding(.top, 4)
                }
            }

            Spacer()

            Button {
                withAnimation { showBanner = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(Color(.tertiarySystemFill), in: Circle())
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Photos View

struct PhotosView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var viewportHeight: CGFloat = 0
    @State private var isSelecting = false
    @State private var selectedFileIDs: Set<String> = []

    var body: some View {
        Group {
            if filteredPhotos.isEmpty {
                if !searchText.isEmpty {
                    NoSearchResultsView(query: searchText)
                } else {
                    emptyState
                }
            } else {
                gridView
            }
        }
        .navigationTitle("Photos")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selectedFileIDs.count == filteredPhotos.count ? "Deselect All" : "Select All") {
                        if selectedFileIDs.count == filteredPhotos.count {
                            selectedFileIDs.removeAll()
                        } else {
                            selectedFileIDs = Set(filteredPhotos.map(\.id))
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isSelecting = false
                        selectedFileIDs.removeAll()
                    }
                    .fontWeight(.semibold)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    BlueEllipsisMenu {
                        Button {
                            isSelecting = true
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBottomBar
            }
        }
    }

    private var selectionBottomBar: some View {
        HStack {
            Button {
                appState.toggleFavorites(selectedFileIDs)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "heart")
                        .font(.system(size: 20))
                    Text("Favorite")
                        .font(.system(size: 10))
                }
            }
            .disabled(selectedFileIDs.isEmpty)

            Spacer()

            Button {
                appState.toggleArchive(selectedFileIDs)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 20))
                    Text("Archive")
                        .font(.system(size: 10))
                }
            }
            .disabled(selectedFileIDs.isEmpty)

            Spacer()

            Button(role: .destructive) {
                appState.trashFiles(selectedFileIDs)
                selectedFileIDs.removeAll()
                isSelecting = false
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "trash")
                        .font(.system(size: 20))
                    Text("Delete")
                        .font(.system(size: 10))
                }
                .foregroundStyle(selectedFileIDs.isEmpty ? Color.secondary : Color.red)
            }
            .disabled(selectedFileIDs.isEmpty)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 10)
        .background(Material.bar)
    }

    private var photoFiles: [FileItem] {
        appState.allFiles.filter { $0.isImage && !$0.trashed && !$0.isArchived }
    }

    private var filteredPhotos: [FileItem] {
        guard !searchText.isEmpty else { return photoFiles }
        return photoFiles.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "photo")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("No Photos")
                .font(.title2.bold())
            Spacer()
        }
    }

    private var gridView: some View {
        ScrollView {
            VStack(spacing: 0) {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ], spacing: 20) {
                    ForEach(filteredPhotos) { file in
                        if isSelecting {
                            FileGridItem(
                                file: file,
                                isSelecting: true,
                                isSelected: selectedFileIDs.contains(file.id)
                            ) {
                                toggleSelection(file.id)
                            }
                        } else {
                            FileGridItem(file: file) {
                                appState.openFile(file)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer(minLength: 40)

                PageItemCountFooter(count: filteredPhotos.count, noun: "photo")
                    .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: max(0, viewportHeight - 16), alignment: .top)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { viewportHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, newHeight in viewportHeight = newHeight }
            }
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedFileIDs.contains(id) {
            selectedFileIDs.remove(id)
        } else {
            selectedFileIDs.insert(id)
        }
    }
}

// MARK: - Videos View

struct VideosView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var viewportHeight: CGFloat = 0
    @State private var isSelecting = false
    @State private var selectedFileIDs: Set<String> = []

    var body: some View {
        Group {
            if filteredVideos.isEmpty {
                if !searchText.isEmpty {
                    NoSearchResultsView(query: searchText)
                } else {
                    emptyState
                }
            } else {
                gridView
            }
        }
        .navigationTitle("Videos")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selectedFileIDs.count == filteredVideos.count ? "Deselect All" : "Select All") {
                        if selectedFileIDs.count == filteredVideos.count {
                            selectedFileIDs.removeAll()
                        } else {
                            selectedFileIDs = Set(filteredVideos.map(\.id))
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isSelecting = false
                        selectedFileIDs.removeAll()
                    }
                    .fontWeight(.semibold)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    BlueEllipsisMenu {
                        Button {
                            isSelecting = true
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBottomBar
            }
        }
    }

    private var selectionBottomBar: some View {
        HStack {
            Button {
                appState.toggleFavorites(selectedFileIDs)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "heart")
                        .font(.system(size: 20))
                    Text("Favorite")
                        .font(.system(size: 10))
                }
            }
            .disabled(selectedFileIDs.isEmpty)

            Spacer()

            Button {
                appState.toggleArchive(selectedFileIDs)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 20))
                    Text("Archive")
                        .font(.system(size: 10))
                }
            }
            .disabled(selectedFileIDs.isEmpty)

            Spacer()

            Button(role: .destructive) {
                appState.trashFiles(selectedFileIDs)
                selectedFileIDs.removeAll()
                isSelecting = false
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "trash")
                        .font(.system(size: 20))
                    Text("Delete")
                        .font(.system(size: 10))
                }
                .foregroundStyle(selectedFileIDs.isEmpty ? Color.secondary : Color.red)
            }
            .disabled(selectedFileIDs.isEmpty)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 10)
        .background(Material.bar)
    }

    private var videoFiles: [FileItem] {
        appState.allFiles.filter { $0.isVideo && !$0.trashed && !$0.isArchived }
    }

    private var filteredVideos: [FileItem] {
        guard !searchText.isEmpty else { return videoFiles }
        return videoFiles.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "film")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("No Videos")
                .font(.title2.bold())
            Spacer()
        }
    }

    private var gridView: some View {
        ScrollView {
            VStack(spacing: 0) {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ], spacing: 20) {
                    ForEach(filteredVideos) { file in
                        if isSelecting {
                            FileGridItem(
                                file: file,
                                isSelecting: true,
                                isSelected: selectedFileIDs.contains(file.id)
                            ) {
                                toggleSelection(file.id)
                            }
                        } else {
                            FileGridItem(file: file) {
                                appState.openFile(file)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer(minLength: 40)

                PageItemCountFooter(count: filteredVideos.count, noun: "video")
                    .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: max(0, viewportHeight - 16), alignment: .top)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { viewportHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, newHeight in viewportHeight = newHeight }
            }
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedFileIDs.contains(id) {
            selectedFileIDs.remove(id)
        } else {
            selectedFileIDs.insert(id)
        }
    }
}

// MARK: - Audio View

struct AudioView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var viewMode: ViewMode = .grid
    @State private var viewportHeight: CGFloat = 0
    @State private var isSelecting = false
    @State private var selectedFileIDs: Set<String> = []

    enum ViewMode: String {
        case grid = "Icons"
        case list = "List"
    }

    var body: some View {
        Group {
            if filteredAudio.isEmpty {
                if !searchText.isEmpty {
                    NoSearchResultsView(query: searchText)
                } else {
                    emptyState
                }
            } else if viewMode == .grid {
                gridView
            } else {
                listView
            }
        }
        .navigationTitle("Audio")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selectedFileIDs.count == filteredAudio.count ? "Deselect All" : "Select All") {
                        if selectedFileIDs.count == filteredAudio.count {
                            selectedFileIDs.removeAll()
                        } else {
                            selectedFileIDs = Set(filteredAudio.map(\.id))
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isSelecting = false
                        selectedFileIDs.removeAll()
                    }
                    .fontWeight(.semibold)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    BlueEllipsisMenu {
                        Button {
                            isSelecting = true
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }
                        Divider()
                        Button { viewMode = .grid } label: {
                            HStack {
                                Text("Icons")
                                if viewMode == .grid { Image(systemName: "checkmark") }
                            }
                        }
                        Button { viewMode = .list } label: {
                            HStack {
                                Text("List")
                                if viewMode == .list { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBottomBar
            }
        }
    }

    private var selectionBottomBar: some View {
        HStack {
            Button {
                appState.toggleFavorites(selectedFileIDs)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "heart")
                        .font(.system(size: 20))
                    Text("Favorite")
                        .font(.system(size: 10))
                }
            }
            .disabled(selectedFileIDs.isEmpty)

            Spacer()

            Button {
                appState.toggleArchive(selectedFileIDs)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 20))
                    Text("Archive")
                        .font(.system(size: 10))
                }
            }
            .disabled(selectedFileIDs.isEmpty)

            Spacer()

            Button(role: .destructive) {
                appState.trashFiles(selectedFileIDs)
                selectedFileIDs.removeAll()
                isSelecting = false
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "trash")
                        .font(.system(size: 20))
                    Text("Delete")
                        .font(.system(size: 10))
                }
                .foregroundStyle(selectedFileIDs.isEmpty ? Color.secondary : Color.red)
            }
            .disabled(selectedFileIDs.isEmpty)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 10)
        .background(Material.bar)
    }

    private var audioFiles: [FileItem] {
        appState.allFiles.filter { $0.isAudio && !$0.trashed && !$0.isArchived }
    }

    private var filteredAudio: [FileItem] {
        guard !searchText.isEmpty else { return audioFiles }
        return audioFiles.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "music.note")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("No Audio Files")
                .font(.title2.bold())
            Spacer()
        }
    }

    private var gridView: some View {
        ScrollView {
            VStack(spacing: 0) {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ], spacing: 20) {
                    ForEach(filteredAudio) { file in
                        if isSelecting {
                            FileGridItem(
                                file: file,
                                isSelecting: true,
                                isSelected: selectedFileIDs.contains(file.id)
                            ) {
                                toggleSelection(file.id)
                            }
                        } else {
                            FileGridItem(file: file) {
                                appState.openFile(file)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer(minLength: 40)

                PageItemCountFooter(count: filteredAudio.count)
                    .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: max(0, viewportHeight - 16), alignment: .top)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { viewportHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, newHeight in viewportHeight = newHeight }
            }
        }
    }

    private var listView: some View {
        List {
            ForEach(filteredAudio) { file in
                if isSelecting {
                    FileRow(
                        file: file,
                        isSelecting: true,
                        isSelected: selectedFileIDs.contains(file.id)
                    ) {
                        toggleSelection(file.id)
                    }
                } else {
                    FileRow(file: file) {
                        appState.openFile(file)
                    }
                }
            }

            PageItemCountFooter(count: filteredAudio.count)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
    }

    private func toggleSelection(_ id: String) {
        if selectedFileIDs.contains(id) {
            selectedFileIDs.remove(id)
        } else {
            selectedFileIDs.insert(id)
        }
    }
}

// MARK: - Documents View

struct DocumentsView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var viewMode: ViewMode = .grid
    @State private var viewportHeight: CGFloat = 0
    @State private var isSelecting = false
    @State private var selectedFileIDs: Set<String> = []

    enum ViewMode: String {
        case grid = "Icons"
        case list = "List"
    }

    var body: some View {
        Group {
            if filteredDocs.isEmpty {
                if !searchText.isEmpty {
                    NoSearchResultsView(query: searchText)
                } else {
                    emptyState
                }
            } else if viewMode == .grid {
                gridView
            } else {
                listView
            }
        }
        .navigationTitle("Documents")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selectedFileIDs.count == filteredDocs.count ? "Deselect All" : "Select All") {
                        if selectedFileIDs.count == filteredDocs.count {
                            selectedFileIDs.removeAll()
                        } else {
                            selectedFileIDs = Set(filteredDocs.map(\.id))
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isSelecting = false
                        selectedFileIDs.removeAll()
                    }
                    .fontWeight(.semibold)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    BlueEllipsisMenu {
                        Button {
                            isSelecting = true
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }
                        Divider()
                        Button { viewMode = .grid } label: {
                            HStack {
                                Text("Icons")
                                if viewMode == .grid { Image(systemName: "checkmark") }
                            }
                        }
                        Button { viewMode = .list } label: {
                            HStack {
                                Text("List")
                                if viewMode == .list { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBottomBar
            }
        }
    }

    private var selectionBottomBar: some View {
        HStack {
            Button {
                appState.toggleFavorites(selectedFileIDs)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "heart")
                        .font(.system(size: 20))
                    Text("Favorite")
                        .font(.system(size: 10))
                }
            }
            .disabled(selectedFileIDs.isEmpty)

            Spacer()

            Button {
                appState.toggleArchive(selectedFileIDs)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 20))
                    Text("Archive")
                        .font(.system(size: 10))
                }
            }
            .disabled(selectedFileIDs.isEmpty)

            Spacer()

            Button(role: .destructive) {
                appState.trashFiles(selectedFileIDs)
                selectedFileIDs.removeAll()
                isSelecting = false
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "trash")
                        .font(.system(size: 20))
                    Text("Delete")
                        .font(.system(size: 10))
                }
                .foregroundStyle(selectedFileIDs.isEmpty ? Color.secondary : Color.red)
            }
            .disabled(selectedFileIDs.isEmpty)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 10)
        .background(Material.bar)
    }

    private var documentFiles: [FileItem] {
        appState.allFiles.filter { $0.isDocument && !$0.trashed && !$0.isArchived }
    }

    private var filteredDocs: [FileItem] {
        guard !searchText.isEmpty else { return documentFiles }
        return documentFiles.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("No Documents")
                .font(.title2.bold())
            Spacer()
        }
    }

    private var gridView: some View {
        ScrollView {
            VStack(spacing: 0) {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ], spacing: 20) {
                    ForEach(filteredDocs) { file in
                        if isSelecting {
                            FileGridItem(
                                file: file,
                                isSelecting: true,
                                isSelected: selectedFileIDs.contains(file.id)
                            ) {
                                toggleSelection(file.id)
                            }
                        } else {
                            FileGridItem(file: file) {
                                appState.openFile(file)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer(minLength: 40)

                PageItemCountFooter(count: filteredDocs.count)
                    .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: max(0, viewportHeight - 16), alignment: .top)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { viewportHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, newHeight in viewportHeight = newHeight }
            }
        }
    }

    private var listView: some View {
        List {
            ForEach(filteredDocs) { file in
                if isSelecting {
                    FileRow(
                        file: file,
                        isSelecting: true,
                        isSelected: selectedFileIDs.contains(file.id)
                    ) {
                        toggleSelection(file.id)
                    }
                } else {
                    FileRow(file: file) {
                        appState.openFile(file)
                    }
                }
            }

            PageItemCountFooter(count: filteredDocs.count)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
    }

    private func toggleSelection(_ id: String) {
        if selectedFileIDs.contains(id) {
            selectedFileIDs.remove(id)
        } else {
            selectedFileIDs.insert(id)
        }
    }
}

// MARK: - Vault PIN Screen

struct VaultPINView: View {
    @Environment(AppState.self) private var appState
    var onUnlocked: (() -> Void)? = nil

    @State private var pin: String = ""
    @State private var errorMessage: String? = nil
    @State private var shake: Bool = false
    @State private var isProcessing: Bool = false

    var isRecovery: Bool {
        KeychainStore.loadVaultPINHash() == nil && appState.hasRecoveryBlob
    }

    var isCreate: Bool {
        KeychainStore.loadVaultPINHash() == nil && !appState.hasRecoveryBlob
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            // Icon
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 80, height: 80)
                Image(systemName: isRecovery ? "key.fill" : "lock.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.blue)
            }

            // Title & Subtitle
            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.bold())
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                        .padding(.top, 4)
                }
            }

            // 4-dot indicator
            HStack(spacing: 20) {
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .fill(index < pin.count ? Color.blue : Color(.tertiarySystemFill))
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle()
                                .stroke(index < pin.count ? Color.blue : Color(.separator), lineWidth: 1.5)
                        )
                }
            }
            .padding(.vertical, 12)
            .offset(x: shake ? -10 : 0)
            .animation(shake ? .default.repeatCount(4, autoreverses: true).speed(4) : .default, value: shake)

            // Keypad
            VStack(spacing: 16) {
                ForEach(0..<3) { row in
                    HStack(spacing: 32) {
                        ForEach(1...3, id: \.self) { col in
                            let digit = row * 3 + col
                            keypadButton(title: "\(digit)") { appendDigit("\(digit)") }
                        }
                    }
                }
                HStack(spacing: 32) {
                    if BiometricUnlock.isAvailable() && !isCreate {
                        Button {
                            Task {
                                if await appState.unlockWithBiometrics() {
                                    onUnlocked?()
                                } else {
                                    errorMessage = "\(BiometricUnlock.biometryName) failed — enter your PIN"
                                }
                            }
                        } label: {
                            Image(systemName: BiometricUnlock.biometryName == "Face ID" ? "faceid" : "touchid")
                                .font(.system(size: 28))
                                .frame(width: 72, height: 72)
                                .foregroundStyle(.blue)
                        }
                    } else {
                        Spacer().frame(width: 72, height: 72)
                    }

                    keypadButton(title: "0") { appendDigit("0") }

                    Button {
                        if !pin.isEmpty {
                            pin.removeLast()
                            errorMessage = nil
                        }
                    } label: {
                        Image(systemName: "delete.left.fill")
                            .font(.system(size: 22))
                            .frame(width: 72, height: 72)
                            .foregroundStyle(.primary)
                    }
                }
            }
            .disabled(isProcessing)

            Spacer()
        }
        .padding(.horizontal, 24)
        .task {
            if BiometricUnlock.isEligible(hasPINHash: KeychainStore.loadVaultPINHash() != nil) {
                if await appState.unlockWithBiometrics() {
                    onUnlocked?()
                }
            }
        }
    }

    private var title: String {
        if isRecovery { return "Enter Vault PIN" }
        if isCreate { return "Create Vault PIN" }
        return "Unlock Vault"
    }

    private var subtitle: String {
        if isRecovery {
            return "Enter the 4-digit PIN you set on your Mac to unlock and decrypt your files."
        }
        if isCreate {
            return "Choose a 4-digit PIN to secure your files and enable recovery on other devices."
        }
        return "Enter your 4-digit PIN to decrypt your files."
    }

    private func keypadButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.title.bold())
                .frame(width: 72, height: 72)
                .background(Circle().fill(Color(.secondarySystemFill)))
                .foregroundStyle(.primary)
        }
    }

    private func appendDigit(_ digit: String) {
        guard pin.count < 4 else { return }
        pin.append(digit)
        errorMessage = nil
        if pin.count == 4 {
            isProcessing = true
            let submitted = pin
            Task {
                let success = await appState.unlockVault(pin: submitted)
                isProcessing = false
                if success {
                    onUnlocked?()
                } else {
                    errorMessage = "Incorrect PIN. Please try again."
                    triggerShake()
                    pin = ""
                }
            }
        }
    }

    private func triggerShake() {
        shake = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            shake = false
        }
    }
}

// MARK: - Private Vault View

struct PrivateVaultView: View {
    @Environment(AppState.self) private var appState
    @State private var isUnlocked = false

    var body: some View {
        Group {
            if isUnlocked {
                FileBrowserView(folderID: "", folderTitle: "Private Vault", filterPrivate: true)
            } else {
                VaultPINView {
                    isUnlocked = true
                    appState.isVaultLocked = false
                }
            }
        }
        .navigationTitle("Private Vault")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            isUnlocked = false
            appState.isVaultLocked = true
        }
    }
}

// MARK: - Favorites View

struct FavoritesView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var viewMode: ViewMode = .grid
    @State private var viewportHeight: CGFloat = 0
    @State private var isSelecting = false
    @State private var selectedFileIDs: Set<String> = []

    enum ViewMode: String {
        case grid = "Icons"
        case list = "List"
    }

    var body: some View {
        Group {
            if filteredFavorites.isEmpty {
                if !searchText.isEmpty {
                    NoSearchResultsView(query: searchText)
                } else {
                    emptyState
                }
            } else if viewMode == .grid {
                gridView
            } else {
                listView
            }
        }
        .navigationTitle("Favorites")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selectedFileIDs.count == filteredFavorites.count ? "Deselect All" : "Select All") {
                        if selectedFileIDs.count == filteredFavorites.count {
                            selectedFileIDs.removeAll()
                        } else {
                            selectedFileIDs = Set(filteredFavorites.map(\.id))
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isSelecting = false
                        selectedFileIDs.removeAll()
                    }
                    .fontWeight(.semibold)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    BlueEllipsisMenu {
                        Button {
                            isSelecting = true
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }
                        Divider()
                        Button { viewMode = .grid } label: {
                            HStack {
                                Text("Icons")
                                if viewMode == .grid { Image(systemName: "checkmark") }
                            }
                        }
                        Button { viewMode = .list } label: {
                            HStack {
                                Text("List")
                                if viewMode == .list { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBottomBar
            }
        }
    }

    private var selectionBottomBar: some View {
        HStack {
            Button {
                appState.toggleFavorites(selectedFileIDs)
                selectedFileIDs.removeAll()
                isSelecting = false
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "heart.slash")
                        .font(.system(size: 20))
                    Text("Unfavorite")
                        .font(.system(size: 10))
                }
            }
            .disabled(selectedFileIDs.isEmpty)

            Spacer()

            Button {
                appState.toggleArchive(selectedFileIDs)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 20))
                    Text("Archive")
                        .font(.system(size: 10))
                }
            }
            .disabled(selectedFileIDs.isEmpty)

            Spacer()

            Button(role: .destructive) {
                appState.trashFiles(selectedFileIDs)
                selectedFileIDs.removeAll()
                isSelecting = false
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "trash")
                        .font(.system(size: 20))
                    Text("Delete")
                        .font(.system(size: 10))
                }
                .foregroundStyle(selectedFileIDs.isEmpty ? Color.secondary : Color.red)
            }
            .disabled(selectedFileIDs.isEmpty)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 10)
        .background(Material.bar)
    }

    private var favoriteFiles: [FileItem] {
        appState.allFiles.filter { $0.isFavorite && !$0.trashed }
    }

    private var filteredFavorites: [FileItem] {
        guard !searchText.isEmpty else { return favoriteFiles }
        return favoriteFiles.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "star")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("No Favorites")
                .font(.title2.bold())
            Text("Mark files as favorites to see them here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var gridView: some View {
        ScrollView {
            VStack(spacing: 0) {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ], spacing: 20) {
                    ForEach(filteredFavorites) { file in
                        if isSelecting {
                            FileGridItem(
                                file: file,
                                isSelecting: true,
                                isSelected: selectedFileIDs.contains(file.id)
                            ) {
                                toggleSelection(file.id)
                            }
                        } else {
                            FileGridItem(file: file) {
                                appState.openFile(file)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer(minLength: 40)

                PageItemCountFooter(count: filteredFavorites.count)
                    .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: max(0, viewportHeight - 16), alignment: .top)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { viewportHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, newHeight in viewportHeight = newHeight }
            }
        }
    }

    private var listView: some View {
        List {
            ForEach(filteredFavorites) { file in
                if isSelecting {
                    FileRow(
                        file: file,
                        isSelecting: true,
                        isSelected: selectedFileIDs.contains(file.id)
                    ) {
                        toggleSelection(file.id)
                    }
                } else {
                    FileRow(file: file) {
                        appState.openFile(file)
                    }
                }
            }

            PageItemCountFooter(count: filteredFavorites.count)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
    }

    private func toggleSelection(_ id: String) {
        if selectedFileIDs.contains(id) {
            selectedFileIDs.remove(id)
        } else {
            selectedFileIDs.insert(id)
        }
    }
}

// MARK: - Transfers View

struct TransfersView: View {
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("No Active Transfers")
                .font(.title2.bold())
            Text("Uploads and downloads will appear here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .navigationTitle("Transfers")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
    }
}

// MARK: - Archive View

struct ArchiveView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var viewMode: ViewMode = .grid
    @State private var viewportHeight: CGFloat = 0
    @State private var isSelecting = false
    @State private var selectedFileIDs: Set<String> = []

    enum ViewMode: String {
        case grid = "Icons"
        case list = "List"
    }

    var body: some View {
        Group {
            if filteredArchived.isEmpty {
                if !searchText.isEmpty {
                    NoSearchResultsView(query: searchText)
                } else {
                    emptyState
                }
            } else if viewMode == .grid {
                gridView
            } else {
                listView
            }
        }
        .navigationTitle("Archive")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selectedFileIDs.count == filteredArchived.count ? "Deselect All" : "Select All") {
                        if selectedFileIDs.count == filteredArchived.count {
                            selectedFileIDs.removeAll()
                        } else {
                            selectedFileIDs = Set(filteredArchived.map(\.id))
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isSelecting = false
                        selectedFileIDs.removeAll()
                    }
                    .fontWeight(.semibold)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    BlueEllipsisMenu {
                        Button {
                            isSelecting = true
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }
                        Divider()
                        Button { viewMode = .grid } label: {
                            HStack {
                                Text("Icons")
                                if viewMode == .grid { Image(systemName: "checkmark") }
                            }
                        }
                        Button { viewMode = .list } label: {
                            HStack {
                                Text("List")
                                if viewMode == .list { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBottomBar
            }
        }
    }

    private var selectionBottomBar: some View {
        HStack {
            Button {
                appState.toggleArchive(selectedFileIDs)
                selectedFileIDs.removeAll()
                isSelecting = false
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "tray.and.arrow.up")
                        .font(.system(size: 20))
                    Text("Unarchive")
                        .font(.system(size: 10))
                }
            }
            .disabled(selectedFileIDs.isEmpty)

            Spacer()

            Button(role: .destructive) {
                appState.trashFiles(selectedFileIDs)
                selectedFileIDs.removeAll()
                isSelecting = false
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "trash")
                        .font(.system(size: 20))
                    Text("Delete")
                        .font(.system(size: 10))
                }
                .foregroundStyle(selectedFileIDs.isEmpty ? Color.secondary : Color.red)
            }
            .disabled(selectedFileIDs.isEmpty)
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 10)
        .background(Material.bar)
    }

    private var archivedFiles: [FileItem] {
        appState.allFiles.filter { $0.isArchived && !$0.trashed }
    }

    private var filteredArchived: [FileItem] {
        guard !searchText.isEmpty else { return archivedFiles }
        return archivedFiles.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "archivebox")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("No Archived Files")
                .font(.title2.bold())
            Text("Archived files are stored safely in cold storage.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var gridView: some View {
        ScrollView {
            VStack(spacing: 0) {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ], spacing: 20) {
                    ForEach(filteredArchived) { file in
                        if isSelecting {
                            FileGridItem(
                                file: file,
                                isSelecting: true,
                                isSelected: selectedFileIDs.contains(file.id)
                            ) {
                                toggleSelection(file.id)
                            }
                        } else {
                            FileGridItem(file: file) {
                                appState.openFile(file)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer(minLength: 40)

                PageItemCountFooter(count: filteredArchived.count)
                    .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: max(0, viewportHeight - 16), alignment: .top)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { viewportHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, newHeight in viewportHeight = newHeight }
            }
        }
    }

    private var listView: some View {
        List {
            ForEach(filteredArchived) { file in
                if isSelecting {
                    FileRow(
                        file: file,
                        isSelecting: true,
                        isSelected: selectedFileIDs.contains(file.id)
                    ) {
                        toggleSelection(file.id)
                    }
                } else {
                    FileRow(file: file) {
                        appState.openFile(file)
                    }
                }
            }

            PageItemCountFooter(count: filteredArchived.count)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
    }

    private func toggleSelection(_ id: String) {
        if selectedFileIDs.contains(id) {
            selectedFileIDs.remove(id)
        } else {
            selectedFileIDs.insert(id)
        }
    }
}

// MARK: - Trash View (Recently Deleted, Files-app style)

struct TrashView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var viewMode: ViewMode = .grid
    @State private var viewportHeight: CGFloat = 0
    @State private var isSelecting = false
    @State private var selectedFileIDs: Set<String> = []

    enum ViewMode: String {
        case grid = "Icons"
        case list = "List"
    }

    var body: some View {
        Group {
            if filteredTrash.isEmpty {
                if !searchText.isEmpty {
                    NoSearchResultsView(query: searchText)
                } else {
                    emptyState
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        Text("Recently deleted items may be permanently deleted by your storage provider.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 8)

                        if viewMode == .grid {
                            LazyVGrid(columns: [
                                GridItem(.flexible(), spacing: 16),
                                GridItem(.flexible(), spacing: 16),
                                GridItem(.flexible(), spacing: 16)
                            ], spacing: 20) {
                                ForEach(filteredTrash) { file in
                                    if isSelecting {
                                        FileGridItem(
                                            file: file,
                                            isSelecting: true,
                                            isSelected: selectedFileIDs.contains(file.id)
                                        ) {
                                            toggleSelection(file.id)
                                        }
                                    } else {
                                        FileGridItem(file: file) { }
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(filteredTrash) { file in
                                    if isSelecting {
                                        FileRow(
                                            file: file,
                                            isSelecting: true,
                                            isSelected: selectedFileIDs.contains(file.id)
                                        ) {
                                            toggleSelection(file.id)
                                        }
                                    } else {
                                        FileRow(file: file) { }
                                    }
                                    Divider().padding(.leading, 60)
                                }
                            }
                        }

                        Spacer(minLength: 40)

                        PageItemCountFooter(count: filteredTrash.count, showSyncStatus: false)
                            .padding(.bottom, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: max(0, viewportHeight - 16), alignment: .top)
                }
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { viewportHeight = proxy.size.height }
                            .onChange(of: proxy.size.height) { _, newHeight in viewportHeight = newHeight }
                    }
                }
            }
        }
        .navigationTitle("Recently Deleted")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selectedFileIDs.count == filteredTrash.count ? "Deselect All" : "Select All") {
                        if selectedFileIDs.count == filteredTrash.count {
                            selectedFileIDs.removeAll()
                        } else {
                            selectedFileIDs = Set(filteredTrash.map(\.id))
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isSelecting = false
                        selectedFileIDs.removeAll()
                    }
                    .fontWeight(.semibold)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    BlueEllipsisMenu {
                        Button {
                            isSelecting = true
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }
                        Divider()
                        Button { viewMode = .grid } label: {
                            HStack {
                                Text("Icons")
                                if viewMode == .grid { Image(systemName: "checkmark") }
                            }
                        }
                        Button { viewMode = .list } label: {
                            HStack {
                                Text("List")
                                if viewMode == .list { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBottomBar
            }
        }
    }

    private var selectionBottomBar: some View {
        HStack {
            Button {
                appState.restoreFiles(selectedFileIDs)
                selectedFileIDs.removeAll()
                isSelecting = false
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 20))
                    Text("Recover")
                        .font(.system(size: 10))
                }
            }
            .disabled(selectedFileIDs.isEmpty)

            Spacer()

            Button(role: .destructive) {
                appState.deletePermanently(selectedFileIDs)
                selectedFileIDs.removeAll()
                isSelecting = false
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 20))
                    Text("Delete Immediately")
                        .font(.system(size: 10))
                }
                .foregroundStyle(selectedFileIDs.isEmpty ? Color.secondary : Color.red)
            }
            .disabled(selectedFileIDs.isEmpty)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 10)
        .background(Material.bar)
    }

    private var trashedFiles: [FileItem] {
        appState.allFiles.filter { $0.trashed }
    }

    private var filteredTrash: [FileItem] {
        guard !searchText.isEmpty else { return trashedFiles }
        return trashedFiles.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "trash")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("No Recently Deleted Files")
                .font(.title2.bold())
            Text("Deleted files will appear here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedFileIDs.contains(id) {
            selectedFileIDs.remove(id)
        } else {
            selectedFileIDs.insert(id)
        }
    }
}

// MARK: - Apple Files Folder Icon

struct AppleFolderIcon: View {
    var width: CGFloat = 84
    var height: CGFloat = 66

    var body: some View {
        let bodyY = height * 0.13
        let tabW = width * 0.40
        let cornerRadius = height * 0.11

        ZStack(alignment: .topLeading) {
            // Back Tab / Flap
            Path { path in
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
            }
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
                    // Subtle top highlight border along front body
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

// MARK: - Inline New Folder Items (Files-app style)

struct InlineNewFolderGridItem: View {
    @Environment(AppState.self) private var appState
    let parentID: String
    let filterPrivate: Bool
    @State private var folderName: String = "untitled folder"
    @FocusState private var isFocused: Bool
    @State private var isCommitted: Bool = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                AppleFolderIcon(width: 86, height: 68)
                    .shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 1.5)
            }
            .frame(height: 105)
            .frame(maxWidth: .infinity)

            VStack(spacing: 2) {
                TextField("Folder Name", text: $folderName)
                    .font(.system(size: 13, weight: .regular))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(uiColor: .systemGray5))
                    )
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit {
                        commit()
                    }
                    .onChange(of: isFocused) { _, focused in
                        if !focused {
                            commit()
                        }
                    }
                    .frame(height: 34, alignment: .top)

                Text("0 items")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(height: 14)
                Text("")
                    .font(.system(size: 11))
                    .frame(height: 14)
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFocused = true
            }
        }
    }

    private func commit() {
        guard !isCommitted else { return }
        isCommitted = true
        let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "untitled folder" : trimmed
        appState.createFolder(named: finalName, parentID: parentID, isPrivate: filterPrivate)
        appState.isCreatingFolder = false
    }
}

struct InlineNewFolderRow: View {
    @Environment(AppState.self) private var appState
    let parentID: String
    let filterPrivate: Bool
    @State private var folderName: String = "untitled folder"
    @FocusState private var isFocused: Bool
    @State private var isCommitted: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            AppleFolderIcon(width: 36, height: 28)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                TextField("Folder Name", text: $folderName)
                    .font(.body)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(uiColor: .systemGray5))
                    )
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit {
                        commit()
                    }
                    .onChange(of: isFocused) { _, focused in
                        if !focused {
                            commit()
                        }
                    }

                Text("0 items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFocused = true
            }
        }
    }

    private func commit() {
        guard !isCommitted else { return }
        isCommitted = true
        let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "untitled folder" : trimmed
        appState.createFolder(named: finalName, parentID: parentID, isPrivate: filterPrivate)
        appState.isCreatingFolder = false
    }
}

// MARK: - File Row

struct FileRow: View {
    @Environment(AppState.self) private var appState
    let file: FileItem
    var isSelecting: Bool = false
    var isSelected: Bool = false
    var onTap: (() -> Void)? = nil
    @State private var renameText = ""
    @State private var showInfo = false
    @State private var thumbData: Data?
    @FocusState private var isRenameFocused: Bool

    var isRenaming: Bool {
        appState.editingFileID == file.id
    }

    var body: some View {
        rowContent
            .contentShape(Rectangle())
            .task(id: "\(file.id)-\(appState.thumbnailVersion)") {
                guard !file.isFolder else { return }
                // Use already-loaded data from the bulk pass if available
                if let existing = file.thumbnailData {
                    thumbData = existing
                    return
                }
                // Lazy on-demand fetch
                if let data = await appState.fetchSingleThumbnail(for: file.id) {
                    await MainActor.run {
                        thumbData = data
                        if let idx = appState.allFiles.firstIndex(where: { $0.id == file.id }) {
                            appState.allFiles[idx].thumbnailData = data
                        }
                    }
                }
            }
            .contextMenu {
                if !file.isFolder {
                    Button { appState.openFile(file) } label: {
                        Label("Open", systemImage: "arrow.up.forward")
                    }
                }
                if file.isFolder {
                    Button { appState.navigateToFolder(file) } label: {
                        Label("Open", systemImage: "folder")
                    }
                }
                Divider()
                Button { appState.toggleFavorite(file) } label: {
                    Label(file.isFavorite ? "Unfavorite" : "Favorite", systemImage: file.isFavorite ? "heart.slash" : "heart")
                }
                if !file.isFolder {
                    Button { appState.togglePin(file) } label: {
                        Label(file.isPinned ? "Remove Download" : "Keep Downloaded", systemImage: file.isPinned ? "arrow.down.circle.fill" : "arrow.down.circle")
                    }
                }
                Divider()
                Button {
                    startRenaming()
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button { showInfo = true } label: {
                    Label("Get Info", systemImage: "info.circle")
                }
                Divider()
                Button(role: .destructive) { appState.trashFile(file) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .alert("File Info", isPresented: $showInfo) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(appState.getInfo(file))
            }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Color.blue : Color.secondary)
            }

            // Thumbnail / Icon tap target (opens file/folder)
            Button {
                if isSelecting {
                    onTap?()
                } else if isRenaming {
                    commitRename()
                } else {
                    onTap?()
                }
            } label: {
                thumbnailView
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Name", text: $renameText)
                        .font(.body)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(uiColor: .systemGray5))
                        )
                        .focused($isRenameFocused)
                        .submitLabel(.done)
                        .onSubmit {
                            commitRename()
                        }
                        .onChange(of: isRenameFocused) { _, focused in
                            if !focused {
                                commitRename()
                            }
                        }
                        .onAppear {
                            renameText = file.name
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                isRenameFocused = true
                            }
                        }
                } else {
                    // Tapping filename directly starts inline rename (or selects if in selection mode)
                    Button {
                        if isSelecting {
                            onTap?()
                        } else {
                            startRenaming()
                        }
                    } label: {
                        Text(file.name)
                            .font(.body)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }

                if file.isFolder {
                    Text("\(countChildren) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        Text(file.formattedDate)
                        if let size = file.formattedSize {
                            Text(size)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
    }

    private func startRenaming() {
        renameText = file.name
        appState.editingFileID = file.id
    }

    private func commitRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != file.name {
            appState.renameFile(file, to: trimmed)
        }
        if appState.editingFileID == file.id {
            appState.editingFileID = nil
        }
    }

    private var countChildren: Int {
        appState.allFiles.filter { $0.parentID == file.id && !$0.trashed && !$0.isArchived }.count
    }

    @ViewBuilder
    private var thumbnailView: some View {
        let effectiveThumb = thumbData ?? file.thumbnailData
        if file.isFolder {
            AppleFolderIcon(width: 36, height: 28)
        } else if let data = effectiveThumb, let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else if file.isAudio {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.12), radius: 1)
                Image(systemName: "music.note")
                    .font(.system(size: 16))
                    .foregroundStyle(Color(white: 0.65))
            }
        } else if file.isDocument {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.12), radius: 1)
                Image(systemName: "doc.text")
                    .font(.system(size: 16))
                    .foregroundStyle(Color(white: 0.65))
            }
        } else if file.isVideo {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(red: 0.14, green: 0.14, blue: 0.16))
                Image(systemName: "film")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.80))
            }
        } else if file.isImage {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(red: 0.16, green: 0.18, blue: 0.22))
                Image(systemName: "photo")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.80))
            }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                Image(systemName: file.systemIcon)
                    .font(.system(size: 16))
                    .foregroundStyle(.blue)
            }
        }
    }
}

// MARK: - File Grid Item

struct FileGridItem: View {
    @Environment(AppState.self) private var appState
    let file: FileItem
    var isSelecting: Bool = false
    var isSelected: Bool = false
    var onTap: (() -> Void)? = nil
    @State private var renameText = ""
    @State private var showInfo = false
    @State private var thumbData: Data?
    @FocusState private var isRenameFocused: Bool

    var isRenaming: Bool {
        appState.editingFileID == file.id
    }

    var body: some View {
        gridContent
            .contentShape(Rectangle())
            .task(id: "\(file.id)-\(appState.thumbnailVersion)") {
                guard !file.isFolder else { return }
                // Use already-loaded data from the bulk pass if available
                if let existing = file.thumbnailData {
                    thumbData = existing
                    return
                }
                // Lazy on-demand fetch
                if let data = await appState.fetchSingleThumbnail(for: file.id) {
                    await MainActor.run {
                        thumbData = data
                        if let idx = appState.allFiles.firstIndex(where: { $0.id == file.id }) {
                            appState.allFiles[idx].thumbnailData = data
                        }
                    }
                }
            }
            .contextMenu {
                if !file.isFolder {
                    Button { appState.openFile(file) } label: {
                        Label("Open", systemImage: "arrow.up.forward")
                    }
                }
                if file.isFolder {
                    Button { appState.navigateToFolder(file) } label: {
                        Label("Open", systemImage: "folder")
                    }
                }
                Divider()
                Button { appState.toggleFavorite(file) } label: {
                    Label(file.isFavorite ? "Unfavorite" : "Favorite", systemImage: file.isFavorite ? "heart.slash" : "heart")
                }
                if !file.isFolder {
                    Button { appState.togglePin(file) } label: {
                        Label(file.isPinned ? "Remove Download" : "Keep Downloaded", systemImage: file.isPinned ? "arrow.down.circle.fill" : "arrow.down.circle")
                    }
                }
                Divider()
                Button {
                    startRenaming()
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button { showInfo = true } label: {
                    Label("Get Info", systemImage: "info.circle")
                }
                Divider()
                Button(role: .destructive) { appState.trashFile(file) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .alert("File Info", isPresented: $showInfo) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(appState.getInfo(file))
            }
    }

    private var gridContent: some View {
        VStack(spacing: 6) {
            // Card container / thumbnail (tapping opens file/folder)
            Button {
                if isSelecting {
                    onTap?()
                } else if isRenaming {
                    commitRename()
                } else {
                    onTap?()
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    thumbnailView
                        .frame(height: 105)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())

                    if isSelecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22))
                            .foregroundStyle(isSelected ? Color.blue : Color.secondary)
                            .background(Circle().fill(Color.white).padding(2))
                            .padding(4)
                    }
                }
            }
            .buttonStyle(.plain)

            // Labels
            VStack(spacing: 2) {
                if isRenaming {
                    TextField("Name", text: $renameText)
                        .font(.system(size: 13, weight: .regular))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(uiColor: .systemGray5))
                        )
                        .focused($isRenameFocused)
                        .submitLabel(.done)
                        .onSubmit {
                            commitRename()
                        }
                        .onChange(of: isRenameFocused) { _, focused in
                            if !focused {
                                commitRename()
                            }
                        }
                        .onAppear {
                            renameText = file.name
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                isRenameFocused = true
                            }
                        }
                        .frame(height: 34, alignment: .top)
                } else {
                    // Tapping filename directly starts inline rename (or selects if in selection mode)
                    Button {
                        if isSelecting {
                            onTap?()
                        } else {
                            startRenaming()
                        }
                    } label: {
                        Text(file.name)
                            .font(.system(size: 13, weight: .regular))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .truncationMode(.middle)
                            .foregroundStyle(.primary)
                            .frame(height: 34, alignment: .top)
                    }
                    .buttonStyle(.plain)
                }

                if file.isFolder {
                    Text("\(countChildren) \(countChildren == 1 ? "item" : "items")")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(height: 14)
                    Text("")
                        .font(.system(size: 11))
                        .frame(height: 14)
                } else {
                    Text(file.formattedDate)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(height: 14)
                    if let size = file.formattedSize {
                        Text(size)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(height: 14)
                    } else {
                        Text("")
                            .font(.system(size: 11))
                            .frame(height: 14)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func startRenaming() {
        renameText = file.name
        appState.editingFileID = file.id
    }

    private func commitRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != file.name {
            appState.renameFile(file, to: trimmed)
        }
        if appState.editingFileID == file.id {
            appState.editingFileID = nil
        }
    }

    private var countChildren: Int {
        appState.allFiles.filter { $0.parentID == file.id && !$0.trashed && !$0.isArchived }.count
    }

    @ViewBuilder
    private var thumbnailView: some View {
        let effectiveThumb = thumbData ?? file.thumbnailData
        if file.isFolder {
            AppleFolderIcon(width: 86, height: 68)
                .shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 1.5)
        } else if let data = effectiveThumb, let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 100)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.16), radius: 3, x: 0, y: 1.5)
        } else if file.isAudio {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 76, height: 92)
                    .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 1.5)
                Image(systemName: "music.note")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Color(white: 0.70))
            }
        } else if file.isDocument {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 72, height: 94)
                    .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 1.5)
                VStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 28))
                        .foregroundStyle(Color(white: 0.65))
                    let ext = (file.name as NSString).pathExtension.uppercased()
                    if !ext.isEmpty {
                        Text(ext)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color(white: 0.45))
                    }
                }
            }
        } else if file.isVideo {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: 0.13, green: 0.13, blue: 0.15))
                    .frame(width: 96, height: 60)
                    .shadow(color: .black.opacity(0.20), radius: 3, x: 0, y: 1.5)
                VStack(spacing: 4) {
                    Image(systemName: "film")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.75))
                    let ext = (file.name as NSString).pathExtension.uppercased()
                    if !ext.isEmpty {
                        Text(ext)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(0.50))
                    }
                }
            }
        } else if file.isImage {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: 0.16, green: 0.18, blue: 0.22))
                    .frame(width: 88, height: 66)
                    .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 1.5)
                VStack(spacing: 4) {
                    Image(systemName: "photo")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.70))
                    let ext = (file.name as NSString).pathExtension.uppercased()
                    if !ext.isEmpty {
                        Text(ext)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(0.50))
                    }
                }
            }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .frame(width: 74, height: 92)
                    .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
                VStack(spacing: 6) {
                    Image(systemName: file.systemIcon)
                        .font(.system(size: 28))
                        .foregroundStyle(.blue)
                    let ext = (file.name as NSString).pathExtension.uppercased()
                    if !ext.isEmpty {
                        Text(ext)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Login Gate

struct LoginGateView: View {
    @Environment(AppState.self) private var appState
    @State private var showSetup = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                VStack(spacing: 32) {
                    Spacer()
                    VStack(spacing: 12) {
                        Image("CascadeLogo")
                            .resizable()
                            .renderingMode(.original)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 80, height: 80)
                        Text("Cascade")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                        Text("Your private cloud")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !appState.hasTelegramCredentials {
                        VStack(spacing: 16) {
                            Text("Connect your Telegram account to access your encrypted vault.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                            Button { showSetup = true } label: {
                                Text("Get Started")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(.blue)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .padding(.horizontal, 32)
                        }
                    } else {
                        LoginStepsView()
                    }
                    Spacer()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if appState.databaseError != nil || appState.hasTelegramCredentials {
                        Button("Back") { appState.logout() }
                            .foregroundStyle(.blue)
                    }
                }
            }
        }
        .task {
            if appState.hasTelegramCredentials, !TelegramClient.shared.isClientStarted {
                if let creds = try? KeychainStore.loadTelegramCredentials() {
                    await appState.startTelegram(apiID: creds.apiID, apiHash: creds.apiHash)
                }
            }
        }
        .sheet(isPresented: $showSetup) {
            TelegramSetupSheet()
        }
    }
}

// MARK: - Setup Sheet

struct TelegramSetupSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var apiID: String = ""
    @State private var apiHash: String = ""
    @State private var errorMessage: String?
    @State private var isConnecting = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case apiID, apiHash }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 4) {
                        Image(systemName: "key.fill")
                            .font(.title2)
                            .foregroundStyle(.blue)
                        Text("Telegram API")
                            .font(.headline)
                        Text("Get these from my.telegram.org")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                Section("Credentials") {
                    TextField("API ID", text: $apiID)
                        .keyboardType(.numberPad)
                        .focused($focusedField, equals: .apiID)
                        .onSubmit { focusedField = .apiHash }
                    SecureField("API Hash", text: $apiHash)
                        .focused($focusedField, equals: .apiHash)
                        .onSubmit { connect() }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Connect") { connect() }
                        .disabled(apiID.isEmpty || apiHash.isEmpty || isConnecting)
                }
            }
        }
        .onAppear { focusedField = .apiID }
    }

    private func connect() {
        guard let id = Int(apiID), !apiHash.isEmpty else {
            errorMessage = "Enter valid API ID and Hash"
            return
        }
        errorMessage = nil
        isConnecting = true
        Task {
            await appState.startTelegram(apiID: id, apiHash: apiHash)
            isConnecting = false
            if appState.hasTelegramCredentials { dismiss() }
            else { errorMessage = appState.databaseError ?? "Connection failed" }
        }
    }
}

// MARK: - Login Steps

struct LoginStepsView: View {
    @Environment(AppState.self) private var appState
    @State private var phoneNumber = ""
    @State private var dialCode = "+1"
    @State private var authCode = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isLoading = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case phone, code, password }

    var body: some View {
        VStack(spacing: 20) {
            switch TelegramClient.shared.authStep {
            case .phone: phoneView
            case .code: codeView
            case .password: passwordView
            case .confirmation: confirmationView
            default: ProgressView().padding(.vertical, 20)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 32)
        .animation(.easeInOut(duration: 0.2), value: TelegramClient.shared.authStep)
    }

    private var phoneView: some View {
        VStack(spacing: 14) {
            Text("Enter your phone number").font(.headline)
            HStack(spacing: 8) {
                TextField("+1", text: $dialCode)
                    .textFieldStyle(.plain)
                    .frame(width: 56)
                    .padding(10)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .keyboardType(.phonePad)
                    .focused($focusedField, equals: .phone)
                TextField("234 567 8900", text: $phoneNumber)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .keyboardType(.phonePad)
                    .focused($focusedField, equals: .phone)
            }
            Button { Task { await sendPhone() } } label: {
                if isLoading { ProgressView().tint(.white) } else { Text("Send Code") }
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(phoneNumber.isEmpty ? Color.gray.opacity(0.3) : .blue)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .disabled(phoneNumber.isEmpty || isLoading)
        }
        .onAppear { focusedField = .phone }
    }

    private var codeView: some View {
        VStack(spacing: 14) {
            Text("Verification Code").font(.headline)
            Text("Enter the code sent to your phone")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("00000", text: $authCode)
                .textFieldStyle(.plain)
                .font(.title2.monospacedDigit().bold())
                .multilineTextAlignment(.center)
                .padding(12)
                .background(Color(.tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .keyboardType(.numberPad)
                .focused($focusedField, equals: .code)
                .onChange(of: authCode) { _, newValue in
                    authCode = String(newValue.prefix(5).filter(\.isNumber))
                }
            Button { focusedField = nil; Task { await verifyCode() } } label: {
                if isLoading { ProgressView().tint(.white) } else { Text("Verify") }
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(authCode.count < 5 ? Color.gray.opacity(0.3) : .blue)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .disabled(authCode.count < 5 || isLoading)
        }
        .onAppear { authCode = ""; focusedField = .code }
    }

    private var passwordView: some View {
        VStack(spacing: 14) {
            Text("Two-Step Verification").font(.headline)
            SecureField("Password", text: $password)
                .textFieldStyle(.plain)
                .padding(12)
                .background(Color(.tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .focused($focusedField, equals: .password)
            Button { Task { await verifyPassword() } } label: {
                if isLoading { ProgressView().tint(.white) } else { Text("Verify") }
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(password.isEmpty ? Color.gray.opacity(0.3) : .blue)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .disabled(password.isEmpty || isLoading)
        }
        .onAppear { focusedField = .password }
    }

    private var confirmationView: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 44))
                .foregroundStyle(.blue)
            Text("Confirm Login").font(.headline)
            Text("Approve this login from another device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 20)
    }

    private func sendPhone() async {
        isLoading = true; errorMessage = nil
        let full = "\(dialCode)\(phoneNumber)".replacingOccurrences(of: " ", with: "")
        do { try await TelegramClient.shared.setAuthenticationPhoneNumber(full) }
        catch { errorMessage = error.localizedDescription }
        isLoading = false
    }

    private func verifyCode() async {
        isLoading = true; errorMessage = nil
        do { try await TelegramClient.shared.checkAuthenticationCode(authCode) }
        catch { errorMessage = error.localizedDescription }
        isLoading = false
    }

    private func verifyPassword() async {
        isLoading = true; errorMessage = nil
        do { try await TelegramClient.shared.checkAuthenticationPassword(password) }
        catch { errorMessage = error.localizedDescription }
        isLoading = false
    }
}

// MARK: - Audio Player Views & Components

private func formatPlayerTime(_ seconds: Double) -> String {
    guard !seconds.isNaN && !seconds.isInfinite && seconds >= 0 else { return "00:00" }
    let total = Int(seconds)
    let s = total % 60
    let m = (total / 60) % 60
    let h = total / 3600
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%02d:%02d", m, s)
}

struct EqualizerWaveformView: View {
    let barCount: Int
    var isPlaying: Bool = true

    var body: some View {
        TimelineView(.animation) { timeline in
            let date = timeline.date.timeIntervalSince1970
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    let factor: Double = {
                        guard isPlaying else { return 0.15 }
                        let phase = Double(index) * 0.9
                        let speed = 4.0 + Double(index % 3) * 1.5
                        let primary = sin(date * speed + phase) * 0.45 + 0.55
                        let secondary = sin(date * 7.5 + phase * 2.0) * 0.25
                        return max(0.2, min(1.0, primary + secondary))
                    }()

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.white)
                        .frame(width: 3, height: CGFloat(factor * 16))
                }
            }
        }
    }
}

struct AudioMiniPlayerView: View {
    let track: FileItem
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 12) {
            // Artwork / Equalizer Icon
            ZStack {
                if let thumb = track.thumbnailData, let uiImage = UIImage(data: thumb) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 42, height: 42)
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                        }
                }

                if appState.isAudioPlaying {
                    EqualizerWaveformView(barCount: 3, isPlaying: true)
                        .frame(width: 16, height: 16)
                        .background(Color.black.opacity(0.4), in: Circle())
                }
            }

            // Track info and time
            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(formatPlayerTime(appState.audioCurrentTime) + " / " + formatPlayerTime(appState.audioDuration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            // Play / Pause Button
            Button {
                appState.toggleAudioPlayPause()
            } label: {
                Image(systemName: appState.isAudioPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
            }

            // Close Button
            Button {
                appState.stopAudio()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture {
            appState.showFullAudioPlayer = true
        }
    }
}

struct FullAudioPlayerView: View {
    let track: FileItem
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0

    var body: some View {
        ZStack {
            // Ambient dynamic background glow
            LinearGradient(
                colors: [Color.blue.opacity(0.35), Color.purple.opacity(0.25), Color(.systemBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top Bar
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.primary)
                            .padding(10)
                            .background(Circle().fill(Color.primary.opacity(0.08)))
                    }

                    Spacer()

                    Text("NOW PLAYING")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .tracking(1.5)

                    Spacer()

                    Button {
                        appState.stopAudio()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.primary)
                            .padding(10)
                            .background(Circle().fill(Color.primary.opacity(0.08)))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                Spacer(minLength: 20)

                // Hero Artwork
                ZStack {
                    if let thumb = track.thumbnailData, let uiImage = UIImage(data: thumb) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 240, height: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .shadow(color: Color.blue.opacity(0.4), radius: 24, y: 12)
                    } else {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [.blue, .purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 240, height: 240)
                            .overlay {
                                if appState.isAudioPlaying {
                                    EqualizerWaveformView(barCount: 5, isPlaying: true)
                                        .frame(width: 60, height: 50)
                                } else {
                                    Image(systemName: "music.note")
                                        .font(.system(size: 72, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .shadow(color: Color.purple.opacity(0.35), radius: 24, y: 12)
                    }
                }
                .scaleEffect(appState.isAudioPlaying ? 1.0 : 0.94)
                .animation(.spring(response: 0.4, dampingFraction: 0.7), value: appState.isAudioPlaying)

                Spacer(minLength: 24)

                // Track Title & Details
                VStack(spacing: 6) {
                    Text(track.name)
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    HStack(spacing: 8) {
                        Text((track.name as NSString).pathExtension.uppercased())
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))

                        if let size = track.formattedSize {
                            Text(size)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 20)

                // Scrubber Slider & Timers
                VStack(spacing: 6) {
                    Slider(
                        value: Binding(
                            get: { isScrubbing ? scrubTime : appState.audioCurrentTime },
                            set: { newValue in
                                isScrubbing = true
                                scrubTime = newValue
                            }
                        ),
                        in: 0...max(1, appState.audioDuration),
                        onEditingChanged: { editing in
                            if !editing {
                                appState.seekAudio(to: scrubTime)
                                isScrubbing = false
                            }
                        }
                    )
                    .tint(.blue)

                    HStack {
                        Text(formatPlayerTime(isScrubbing ? scrubTime : appState.audioCurrentTime))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)

                        Spacer()

                        Text(formatPlayerTime(appState.audioDuration))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 32)

                Spacer(minLength: 16)

                // Playback Transport Controls
                HStack(spacing: 36) {
                    // Skip -15s
                    Button {
                        appState.seekAudio(to: max(0, appState.audioCurrentTime - 15))
                    } label: {
                        Image(systemName: "gobackward.15")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(.primary)
                    }

                    // Play / Pause Circle
                    Button {
                        appState.toggleAudioPlayPause()
                    } label: {
                        Image(systemName: appState.isAudioPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 68, height: 68)
                            .background(Circle().fill(Color.blue))
                            .shadow(color: Color.blue.opacity(0.4), radius: 12, y: 6)
                    }

                    // Skip +15s
                    Button {
                        appState.seekAudio(to: min(appState.audioDuration, appState.audioCurrentTime + 15))
                    } label: {
                        Image(systemName: "goforward.15")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                }
                .padding(.bottom, 40)
            }
        }
    }
}
#endif
