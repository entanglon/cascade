import SwiftUI
import AppKit
import AVKit
import WebKit

struct TheaterView: View {
    @Environment(AppState.self) private var appState
    let file: ObjectRecord

    @FocusState private var isFocused: Bool
    @State private var url: URL?
    @State private var imageScale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var imageOffset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var downloadProgress: Double = 0
    @State private var downloadStatus: String = "Preparing…"
    @State private var errorMessage: String?
    @State private var showControls = true
    @State private var controlsTimer: Timer?
    @AppStorage("xc.canvasBackground") private var canvasBackground: CanvasBackground = .dark
    // Keep the same sort option AND direction as the file browser, so left/right
    // navigation follows the exact on-screen order of the files.
    @AppStorage("xc.sortOptionRaw") private var sortOptionRaw = "name"
    @AppStorage("xc.sortAscending") private var sortAscending = false

    enum CanvasBackground: String, CaseIterable, Codable {
        case dark = "Dark"
        case slate = "Slate"
        case light = "Light"

        var color: Color {
            switch self {
            case .dark: return Color.black.opacity(0.96)
            case .slate: return Color(red: 0.20, green: 0.20, blue: 0.24)
            case .light: return Color(red: 0.92, green: 0.92, blue: 0.94)
            }
        }
    }

    private var previewKind: PreviewKind {
        if file.isFolder { return .folder }
        let ext = (file.name as NSString).pathExtension.lowercased()
        if file.mime.hasPrefix("image/") { return .image }
        if file.mime.hasPrefix("video/") { return .video }
        if file.mime.hasPrefix("audio/") || ["mp3", "m4a", "wav", "flac", "aac", "ogg"].contains(ext) { return .audio }
        if file.mime.contains("pdf") || ext == "pdf" { return .pdf }
        if file.mime.hasPrefix("text/") || ["txt", "md", "json", "log", "csv", "swift"].contains(ext) { return .text }
        return .other
    }

    enum PreviewKind { case image, video, audio, pdf, text, other, folder }

    /// Kinds that render a metadata/details panel without downloading the file's
    /// contents (folders have nothing to download; unsupported types show Finder-style
    /// info and only fetch on demand when the user asks to open them).
    private var isMetadataOnly: Bool {
        previewKind == .folder || previewKind == .pdf || previewKind == .text || previewKind == .other
    }

    var body: some View {
        ZStack {
            // Adaptable canvas background (Dark / Slate / Light)
            canvasBackground.color.ignoresSafeArea()

            // Content
            Group {
                if isMetadataOnly {
                    detailsView
                } else if let errorMessage {
                    errorView(errorMessage)
                } else if url != nil {
                    contentView
                } else {
                    downloadingView
                }
            }

            // Floating top controls
            VStack {
                if showControls {
                    topControls
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()

                // Bottom info bar
                if showControls, url != nil {
                    bottomInfoBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: showControls)

            // Navigation arrows
            if showControls, url != nil {
                navigationOverlay
            }

            // Global window key monitor for ESC, Left/Right Arrows, and Spacebar
            KeyMonitorView(
                onEscape: { handleEscapeKey() },
                onLeftArrow: { navigateMedia(delta: -1) },
                onRightArrow: { navigateMedia(delta: 1) },
                onSpacebar: {
                    if previewKind == .image || previewKind == .pdf || previewKind == .text || previewKind == .other || previewKind == .folder {
                        // Space toggles the viewer (Quick Look style): close it.
                        appState.theaterFile = nil
                    } else if previewKind == .video {
                        NotificationCenter.default.post(name: .toggleVideoPlayback, object: nil)
                    } else if previewKind == .audio {
                        AudioPlayerEngine.shared.togglePlayPause()
                    }
                }
            )
            .frame(width: 0, height: 0)
        }
        .contextMenu {
            Menu("Canvas Background") {
                Button {
                    canvasBackground = .dark
                } label: {
                    if canvasBackground == .dark {
                        Label("Dark", systemImage: "checkmark")
                    } else {
                        Text("Dark")
                    }
                }
                Button {
                    canvasBackground = .slate
                } label: {
                    if canvasBackground == .slate {
                        Label("Slate", systemImage: "checkmark")
                    } else {
                        Text("Slate")
                    }
                }
                Button {
                    canvasBackground = .light
                } label: {
                    if canvasBackground == .light {
                        Label("Light", systemImage: "checkmark")
                    } else {
                        Text("Light")
                    }
                }
            }
            Divider()
            Button(appState.isTheaterFullScreen ? "Exit Full Screen" : "Full Screen") {
                withAnimation { appState.isTheaterFullScreen.toggle() }
            }
            Button("Close Viewer") {
                handleEscapeKey()
            }
        }
        .onContinuousHover { phase in
            if case .active = phase {
                onMouseActivity()
            }
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear {
            isFocused = true
            onMouseActivity()
        }
        .onExitCommand {
            handleEscapeKey()
        }
        .onKeyPress(.leftArrow) {
            navigateMedia(delta: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            navigateMedia(delta: 1)
            return .handled
        }
        .onKeyPress(.space) {
            if previewKind == .image || previewKind == .pdf || previewKind == .text || previewKind == .other || previewKind == .folder {
                // Space toggles the viewer (Quick Look style): close it.
                appState.theaterFile = nil
            } else if previewKind == .video {
                NotificationCenter.default.post(name: .toggleVideoPlayback, object: nil)
            } else if previewKind == .audio {
                AudioPlayerEngine.shared.togglePlayPause()
            }
            return .handled
        }
        .task(id: file.id) {
            isFocused = true
            await loadFile()
        }
    }

    // MARK: - Top Controls

    private var topControls: some View {
        HStack(spacing: 12) {
            // Minimize button (Background play in Mini Player)
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    if (previewKind == .audio || previewKind == .video) && !AudioPlayerEngine.shared.isPlaying {
                        AudioPlayerEngine.shared.play(file: file, in: mediaFiles)
                    }
                    appState.theaterFile = nil
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .help("Minimize to Background")

            // Full Screen toggle button
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    appState.isTheaterFullScreen.toggle()
                }
            } label: {
                Image(systemName: appState.isTheaterFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .help(appState.isTheaterFullScreen ? "Exit Full Screen" : "Full Screen (Hide Sidebar)")

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.leading, 4)

            Spacer()

            // Close button (Stops playback completely)
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    if previewKind == .audio || previewKind == .video {
                        AudioPlayerEngine.shared.stop()
                    }
                    appState.theaterFile = nil
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .help("Close Player")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.black.opacity(0.4))
    }

    // MARK: - Bottom Info

    private var bottomInfoBar: some View {
        HStack(spacing: 12) {
            let siblings = mediaFiles
            if let idx = siblings.firstIndex(where: { $0.id == file.id }) {
                Text("\(idx + 1) of \(siblings.count)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
            }

            Spacer()

            if previewKind == .image {
                Text("\(Int(imageScale * 100))%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
            }

            // Open Externally button at bottom right (Icon-only with Open With app options)
            Menu {
                if let targetURL = activeLocalURL {
                    let apps = availableApps(for: targetURL)
                    if !apps.isEmpty {
                        Section("Open With") {
                            ForEach(apps, id: \.appURL) { item in
                                Button {
                                    NSWorkspace.shared.open([targetURL], withApplicationAt: item.appURL, configuration: NSWorkspace.OpenConfiguration())
                                } label: {
                                    Text(item.name)
                                }
                            }
                        }
                        Divider()
                    }

                    Button("Default App") {
                        NSWorkspace.shared.open(targetURL)
                    }

                    Button("Choose App…") {
                        showOpenWithPanel(for: targetURL)
                    }
                } else {
                    Button("Open Default App") {
                        appState.openFile(file)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .help("Open With / External Player")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    // MARK: - Navigation Overlay

    private var navigationOverlay: some View {
        HStack {
            Button { navigateMedia(delta: -1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .opacity(canNavigate(-1) ? 1 : 0.3)
            .disabled(!canNavigate(-1))

            Spacer()

            Button { navigateMedia(delta: 1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .opacity(canNavigate(1) ? 1 : 0.3)
            .disabled(!canNavigate(1))
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        switch previewKind {
        case .image:
            imageViewer
                .onTapGesture { toggleControls() }
        case .video:
            VideoPlaybackView(object: file, showControls: showControls)
        case .audio:
            TheaterAudioPlayerView(file: file, mediaFiles: mediaFiles)
        default:
            // Folders and unsupported types get a Finder-style details panel.
            detailsView
        }
    }

    // MARK: - Details Panel (folders & unsupported files)

    private var detailsView: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 116, height: 116)

                Image(systemName: previewKind == .folder ? "folder.fill" : iconForFile)
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(previewKind == .folder ? XTheme.accent : XTheme.accent.opacity(0.65))
            }

            Text(file.name)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            VStack(spacing: 10) {
                detailRow("Kind", kindText)
                detailRow("Size", sizeText)
                if previewKind == .folder {
                    detailRow("Items", itemCountText)
                }
                if !file.mime.isEmpty && previewKind != .folder {
                    detailRow("Format", file.mime)
                }
                detailRow("Created", file.createdAt.formatted(date: .abbreviated, time: .shortened))
                detailRow("Modified", file.modifiedAt.formatted(date: .abbreviated, time: .shortened))
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )

            if previewKind != .folder {
                Button {
                    openWithDefaultApp()
                } label: {
                    Label("Open with Default App", systemImage: "arrow.up.right.square")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .contentShape(Capsule())
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(40)
        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
    }

    private func openWithDefaultApp() {
        Task {
            if let cached = activeLocalURL {
                NSWorkspace.shared.open(cached)
                return
            }
            let downloaded = try? await DownloadEngine.download(object: file) { _, _ in }
            if let downloaded {
                NSWorkspace.shared.open(downloaded)
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.trailing)
        }
    }

    private var kindText: String {
        if previewKind == .folder { return "Folder" }
        let ext = (file.name as NSString).pathExtension.lowercased()
        if !ext.isEmpty { return "\(ext.uppercased()) File" }
        return file.mime.isEmpty ? "File" : file.mime
    }

    private var sizeText: String {
        if previewKind == .folder {
            return XTheme.formatBytes(totalFolderSize)
        }
        return ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
    }

    private var itemCountText: String {
        let count = folderChildren.count
        return "\(count) item\(count == 1 ? "" : "s")"
    }

    private var folderChildren: [ObjectRecord] {
        appState.files.filter { $0.parentID == file.id && !$0.trashed }
    }

    /// Total size of everything inside this folder, recursing through subfolders.
    private var totalFolderSize: Int64 {
        var seen = Set<String>()
        var total: Int64 = 0
        var stack = folderChildren
        while let item = stack.popLast() {
            guard seen.insert(item.id).inserted else { continue }
            if item.isFolder {
                stack.append(contentsOf: appState.files.filter { $0.parentID == item.id && !$0.trashed })
            } else {
                total += item.size
            }
        }
        return total
    }

    // MARK: - Download Progress

    // MARK: - Download Progress

    private var downloadingView: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.08), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: downloadProgress)
                    .stroke(
                        XTheme.brandGradient,
                        style: .init(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: downloadProgress)

                VStack(spacing: 2) {
                    Text("\(Int(downloadProgress * 100))%")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                    Image(systemName: "arrow.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(width: 80, height: 80)

            VStack(spacing: 6) {
                Text(file.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(downloadStatus)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
                    .animation(.easeInOut(duration: 0.15), value: downloadStatus)
            }
        }
        .padding(32)
        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.red.opacity(0.7))

            VStack(spacing: 6) {
                Text("Failed to Load")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            HStack(spacing: 12) {
                Button {
                    errorMessage = nil
                    downloadProgress = 0
                    downloadStatus = "Preparing…"
                    Task { await loadFile() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .contentShape(Capsule())
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)

                Button {
                    appState.theaterFile = nil
                } label: {
                    Text("Close")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .contentShape(Capsule())
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(40)
        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
    }

    // MARK: - Image Viewer

    @ViewBuilder
    private var imageViewer: some View {
        let isSVG = (file.name as NSString).pathExtension.lowercased() == "svg" || file.mime.contains("svg")
        if let url, isSVG {
            SVGWebView(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
                .transition(.opacity)
        } else if let url, let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .scaleEffect(imageScale)
                .offset(imageOffset)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            imageScale = lastScale * value
                        }
                        .onEnded { _ in
                            lastScale = imageScale
                            if imageScale < 1.0 {
                                withAnimation(.spring()) {
                                    imageScale = 1.0
                                    lastScale = 1.0
                                    imageOffset = .zero
                                    lastOffset = .zero
                                }
                            }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            guard imageScale > 1.0 else { return }
                            imageOffset = CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in
                            lastOffset = imageOffset
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring()) {
                        if imageScale > 1.0 {
                            imageScale = 1.0
                            lastScale = 1.0
                            imageOffset = .zero
                            lastOffset = .zero
                        } else {
                            imageScale = 2.5
                            lastScale = 2.5
                        }
                    }
                }
                .padding(20)
                .transition(.opacity)
        } else if url != nil {
            ProgressView().tint(.white)
        }
    }

    // MARK: - Helpers

    private var iconForFile: String {
        if file.mime.contains("pdf") { return "doc.richtext" }
        if file.mime.hasPrefix("text/") { return "doc.text" }
        return "doc.fill"
    }

    /// The files left/right arrow keys navigate through, in the EXACT same order
    /// they appear in the file browser (same filters, sort option, and direction),
    /// so navigating 1 → 2 → 3 … matches what the user sees on screen.
    private var mediaFiles: [ObjectRecord] {
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
            case .photos:
                if let currentID = appState.currentFolderID {
                    return files.filter { !$0.trashed && !$0.isPrivate && $0.parentID == currentID }
                } else {
                    return files.filter { !$0.trashed && !$0.isFolder && !$0.isPrivate && $0.parentID == nil && (
                        $0.mime.hasPrefix("image/") || ["jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp", "svg"].contains(($0.name as NSString).pathExtension.lowercased())
                    ) }
                }
            case .video:
                if let currentID = appState.currentFolderID {
                    return files.filter { !$0.trashed && !$0.isPrivate && $0.parentID == currentID }
                } else {
                    return files.filter { !$0.trashed && !$0.isFolder && !$0.isPrivate && $0.parentID == nil && $0.mime.hasPrefix("video/") }
                }
            case .audio:
                if let currentID = appState.currentFolderID {
                    return files.filter { !$0.trashed && !$0.isPrivate && $0.parentID == currentID }
                } else {
                    return files.filter { !$0.trashed && !$0.isFolder && !$0.isPrivate && $0.parentID == nil && (
                        $0.mime.hasPrefix("audio/") || ["mp3", "m4a", "wav", "flac", "aac", "ogg"].contains(($0.name as NSString).pathExtension.lowercased())
                    ) }
                }
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
        let filtered = base.filter { !$0.isFolder }
        let searched = query.isEmpty ? filtered : filtered.filter { $0.name.lowercased().contains(query) }

        switch sortOptionRaw {
        case "dateCreated":
            return searched.sorted { sortAscending ? $0.createdAt < $1.createdAt : $0.createdAt > $1.createdAt }
        case "dateModified":
            return searched.sorted { sortAscending ? $0.modifiedAt < $1.modifiedAt : $0.modifiedAt > $1.modifiedAt }
        case "size":
            return searched.sorted { sortAscending ? $0.size < $1.size : $0.size > $1.size }
        case "kind":
            return searched.sorted {
                let res = $0.mime.localizedCaseInsensitiveCompare($1.mime)
                return sortAscending ? res == .orderedAscending : res == .orderedDescending
            }
        default: // "name"
            return searched.sorted {
                let res = $0.name.localizedCaseInsensitiveCompare($1.name)
                return sortAscending ? res == .orderedAscending : res == .orderedDescending
            }
        }
    }

    private func canNavigate(_ delta: Int) -> Bool {
        let files = mediaFiles
        guard let idx = files.firstIndex(where: { $0.id == file.id }) else { return false }
        let next = idx + delta
        return next >= 0 && next < files.count
    }

    private func onMouseActivity() {
        controlsTimer?.invalidate()
        if !showControls {
            withAnimation(.easeInOut(duration: 0.25)) {
                showControls = true
            }
        }
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { _ in
            Task { @MainActor in
                withAnimation(.easeInOut(duration: 0.25)) {
                    showControls = false
                }
            }
        }
    }

    private func refreshTimerIfVisible() {
        if showControls {
            controlsTimer?.invalidate()
            controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { _ in
                Task { @MainActor in
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showControls = false
                    }
                }
            }
        }
    }

    private func navigateMedia(delta: Int) {
        refreshTimerIfVisible()
        let files = mediaFiles
        guard let currentIndex = files.firstIndex(where: { $0.id == file.id }) else { return }
        let nextIndex = min(max(currentIndex + delta, 0), files.count - 1)
        guard nextIndex != currentIndex else { return }
        let next = files[nextIndex]
        appState.theaterFile = next
        // Keep the browser's selection in sync so closing the viewer (space) and
        // reopening it shows the image we were just looking at.
        appState.selectedFiles = [next.id]
    }
    private var activeLocalURL: URL? {
        // The xcloud-stream:// URL is not a real file — only expose real local files
        // to "Open With" / "Open Externally".
        if let url, url.isFileURL { return url }
        if DownloadEngine.isCached(file) {
            return DownloadEngine.cacheURL(for: file)
        }
        return nil
    }

    private func availableApps(for fileURL: URL) -> [(name: String, appURL: URL)] {
        let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: fileURL)
        let ext = fileURL.pathExtension.lowercased()
        let isVideoOrAudio = ["mp4", "mov", "mkv", "webm", "avi", "m4v", "mp3", "m4a", "wav", "flac", "aac", "ogg"].contains(ext) || previewKind == .video || previewKind == .audio
        
        let knownMediaPlayers: Set<String> = [
            "vlc", "iina", "quicktime player", "elmedia player", "infuse", "mpv", 
            "mplayer", "kmplayer", "movist", "omniplayer", "soda player", "plex"
        ]
        
        let filtered = appURLs.filter { appURL in
            let name = FileManager.default.displayName(atPath: appURL.path).replacingOccurrences(of: ".app", with: "").lowercased()
            let bundleID = (Bundle(url: appURL)?.bundleIdentifier ?? "").lowercased()
            
            if isVideoOrAudio {
                return knownMediaPlayers.contains(name) ||
                       name.contains("player") ||
                       name.contains("vlc") ||
                       name.contains("iina") ||
                       name.contains("quicktime") ||
                       bundleID.contains("vlc") ||
                       bundleID.contains("iina") ||
                       bundleID.contains("quicktime") ||
                       bundleID.contains("player")
            } else {
                let excluded: Set<String> = ["xcode", "textedit", "coteditor", "sublime text", "visual studio code", "vscode", "terminal"]
                return !excluded.contains(name)
            }
        }
        
        return filtered.map { appURL in
            let name = FileManager.default.displayName(atPath: appURL.path).replacingOccurrences(of: ".app", with: "")
            return (name: name, appURL: appURL)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func showOpenWithPanel(for fileURL: URL) {
        let openPanel = NSOpenPanel()
        openPanel.title = "Select Application to Open \(fileURL.lastPathComponent)"
        openPanel.directoryURL = URL(fileURLWithPath: "/Applications")
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.allowedContentTypes = [.application]
        
        if openPanel.runModal() == .OK, let appURL = openPanel.url {
            NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func toggleControls() {
        if showControls {
            controlsTimer?.invalidate()
            withAnimation(.easeInOut(duration: 0.25)) {
                showControls = false
            }
        } else {
            onMouseActivity()
        }
    }

    private func handleEscapeKey() {
        controlsTimer?.invalidate()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            if previewKind == .audio || previewKind == .video {
                if AudioPlayerEngine.shared.isPlaying {
                    // Seamlessly transition to MiniPlayer without interrupting playback
                    appState.theaterFile = nil
                } else {
                    // Fully exit and stop playback when paused
                    AudioPlayerEngine.shared.stop()
                    appState.theaterFile = nil
                }
            } else {
                appState.theaterFile = nil
            }
        }
    }

    private func loadFile() async {
        refreshTimerIfVisible()

        // Metadata-only kinds (folders, unsupported types) render instantly from the
        // catalog — no download needed. They fetch on demand when "Open" is tapped.
        guard !isMetadataOnly else { return }

        imageScale = 1.0
        lastScale = 1.0
        imageOffset = .zero
        lastOffset = .zero
        url = nil
        errorMessage = nil
        downloadProgress = 0
        downloadStatus = "Preparing…"

        if DownloadEngine.isCached(file) {
            url = DownloadEngine.cacheURL(for: file)
            return
        }

        // Uncached videos stream byte-by-byte from Telegram via mpv instead of
        // downloading the whole file first. mpv demuxes any container (mkv, webm,
        // avi, ...) from the local byte-range server; mpvStreamURL returns nil when
        // the layout can't load, so those fall through to the full download below.
        // VideoPlaybackView picks the item up via AudioPlayerEngine once `url` is set.
        if previewKind == .video,
           await VideoStreamingEngine.shared.mpvStreamURL(for: file) != nil {
            url = URL(string: "xcloud-stream://object-\(file.id)")
            return
        }

        do {
            let downloaded = try await DownloadEngine.download(object: file) { status, progress in
                Task { @MainActor in
                    self.downloadStatus = status
                    self.downloadProgress = progress
                }
            }
            withAnimation(.easeOut(duration: 0.3)) {
                url = downloaded
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Theater Audio Player View

struct TheaterAudioPlayerView: View {
    let file: ObjectRecord
    let mediaFiles: [ObjectRecord]
    @Bindable var audioEngine = AudioPlayerEngine.shared
    @State private var thumbURL: URL? = nil

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            // Large Glowing Disc with Animated Equalizer Waveform
            ZStack {
                if let thumbURL, let nsImage = NSImage(contentsOf: thumbURL) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: 200, height: 200)
                        .clipShape(Circle())
                        .shadow(color: XTheme.accent.opacity(0.5), radius: 30, y: 10)
                } else {
                    Circle()
                        .fill(XTheme.brandGradient)
                        .frame(width: 200, height: 200)
                        .shadow(color: XTheme.accent.opacity(0.5), radius: 30, y: 10)

                    EqualizerWaveformView(barCount: 7, isPlaying: audioEngine.isPlaying && audioEngine.currentTrack?.id == file.id)
                        .frame(width: 90, height: 80)
                }
            }

            // Track Details
            VStack(spacing: 6) {
                Text(file.name)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 32)

            // Scrubber Bar
            VStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { audioEngine.currentTrack?.id == file.id ? audioEngine.currentTime : 0 },
                        set: { audioEngine.seek(to: $0) }
                    ),
                    in: 0...max(1, audioEngine.currentTrack?.id == file.id ? audioEngine.duration : 1)
                )
                .tint(XTheme.accent)

                HStack {
                    Text(timeString(audioEngine.currentTrack?.id == file.id ? audioEngine.currentTime : 0))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    Text(timeString(audioEngine.currentTrack?.id == file.id ? audioEngine.duration : 0))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 32)

            // Playback Controls
            HStack(spacing: 32) {
                Button { audioEngine.skipPrevious() } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)

                Button {
                    if audioEngine.currentTrack?.id == file.id {
                        audioEngine.togglePlayPause()
                    } else {
                        audioEngine.play(file: file, in: mediaFiles)
                    }
                } label: {
                    ZStack {
                        Circle().fill(XTheme.accent)
                            .frame(width: 64, height: 64)
                            .shadow(color: XTheme.accent.opacity(0.6), radius: 12, y: 5)
                        Image(systemName: (audioEngine.isPlaying && audioEngine.currentTrack?.id == file.id) ? "pause.fill" : "play.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: (audioEngine.isPlaying && audioEngine.currentTrack?.id == file.id) ? 0 : 2)
                    }
                    .frame(width: 64, height: 64)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)

                Button { audioEngine.skipNext() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .task(id: file.id) {
            thumbURL = await ThumbnailService.shared.thumbnailURL(for: file)
            if audioEngine.currentTrack?.id != file.id {
                audioEngine.play(file: file, in: mediaFiles)
            }
        }
    }

    private func timeString(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite && seconds >= 0 else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Key Monitor for Reliable Escape Key Interception

struct KeyMonitorView: NSViewRepresentable {
    let onEscape: () -> Void
    var onLeftArrow: (() -> Void)? = nil
    var onRightArrow: (() -> Void)? = nil
    var onSpacebar: (() -> Void)? = nil

    func makeNSView(context: Context) -> KeyView {
        let v = KeyView()
        v.onEscape = onEscape
        v.onLeftArrow = onLeftArrow
        v.onRightArrow = onRightArrow
        v.onSpacebar = onSpacebar
        return v
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onEscape = onEscape
        nsView.onLeftArrow = onLeftArrow
        nsView.onRightArrow = onRightArrow
        nsView.onSpacebar = onSpacebar
    }

    class KeyView: NSView {
        var onEscape: (() -> Void)?
        var onLeftArrow: (() -> Void)?
        var onRightArrow: (() -> Void)?
        var onSpacebar: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil && monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    // If this view is no longer attached to a window (viewer closed),
                    // don't swallow keys — pass everything through so the browser's own
                    // space/arrow handling works again.
                    guard let self, self.window != nil else { return event }
                    if event.keyCode == 53 { // ESC key
                        DispatchQueue.main.async { self.onEscape?() }
                        return nil
                    } else if event.keyCode == 123, let onLeft = self.onLeftArrow { // Left Arrow
                        DispatchQueue.main.async { onLeft() }
                        return nil
                    } else if event.keyCode == 124, let onRight = self.onRightArrow { // Right Arrow
                        DispatchQueue.main.async { onRight() }
                        return nil
                    } else if event.keyCode == 49, let onSpace = self.onSpacebar { // Spacebar
                        DispatchQueue.main.async { onSpace() }
                        return nil
                    }
                    return event
                }
            } else if window == nil && monitor != nil {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

class NonMenuWKWebView: WKWebView {
    override func menu(for event: NSEvent) -> NSMenu? {
        return nil
    }
}

struct SVGWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = NonMenuWKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
}
