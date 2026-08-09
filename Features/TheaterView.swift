import SwiftUI
import AppKit
import AVKit

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

    private var previewKind: PreviewKind {
        let ext = (file.name as NSString).pathExtension.lowercased()
        if file.mime.hasPrefix("image/") { return .image }
        if file.mime.hasPrefix("video/") { return .video }
        if file.mime.hasPrefix("audio/") || ["mp3", "m4a", "wav", "flac", "aac", "ogg"].contains(ext) { return .audio }
        if file.mime.contains("pdf") || ext == "pdf" { return .pdf }
        if file.mime.hasPrefix("text/") || ["txt", "md", "json", "log", "csv", "swift"].contains(ext) { return .text }
        return .other
    }

    enum PreviewKind { case image, video, audio, pdf, text, other }

    var body: some View {
        ZStack {
            // Full-bleed background
            Color.black.opacity(0.96).ignoresSafeArea()

            // Content
            Group {
                if let errorMessage {
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

            // Key monitor for ESC key handling
            KeyMonitorView {
                withAnimation(.easeOut(duration: 0.2)) {
                    if previewKind == .audio {
                        AudioPlayerEngine.shared.stop()
                    }
                    appState.theaterFile = nil
                }
            }
            .frame(width: 0, height: 0)
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear {
            isFocused = true
        }
        .onDisappear {
            if previewKind == .audio {
                AudioPlayerEngine.shared.stop()
            }
        }
        .onExitCommand {
            withAnimation(.easeOut(duration: 0.2)) {
                if previewKind == .audio {
                    AudioPlayerEngine.shared.stop()
                }
                appState.theaterFile = nil
            }
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
            if previewKind == .image {
                toggleControls()
            } else if previewKind == .video {
                NotificationCenter.default.post(name: .toggleVideoPlayback, object: nil)
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
                withAnimation(.easeOut(duration: 0.2)) {
                    if previewKind == .audio {
                        if AudioPlayerEngine.shared.currentTrack?.id != file.id {
                            AudioPlayerEngine.shared.play(file: file, in: mediaFiles)
                        }
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
                withAnimation(.easeOut(duration: 0.2)) {
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
                withAnimation(.easeOut(duration: 0.2)) {
                    if previewKind == .audio {
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

            // Open Externally button at bottom right
            Button {
                if let url {
                    NSWorkspace.shared.open(url)
                } else {
                    appState.openFile(file)
                }
            } label: {
                Label("Open Externally", systemImage: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .contentShape(Capsule())
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
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
            VideoPlaybackView(object: file)
        case .audio:
            TheaterAudioPlayerView(file: file, mediaFiles: mediaFiles)
        default:
            VStack(spacing: 16) {
                Image(systemName: iconForFile)
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(XTheme.accent.opacity(0.6))
                Text(file.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text("This file type can't be previewed.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
                Button {
                    if let url {
                        NSWorkspace.shared.open(url)
                    }
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
    }

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
        if let url, let nsImage = NSImage(contentsOf: url) {
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

    private var mediaFiles: [ObjectRecord] {
        let base: [ObjectRecord] = {
            let files = appState.files
            switch appState.selectedDestination {
            case .allFiles:
                return files.filter { !$0.trashed && $0.parentID == appState.currentFolderID }
            case .recent:
                return Array(files.filter { !$0.trashed && !$0.isFolder }.prefix(20))
            case .favorites:
                return files.filter { $0.isFavorite && !$0.trashed }
            case .video:
                return files.filter { !$0.trashed && !$0.isFolder && $0.mime.hasPrefix("video/") }
            case .audio:
                return files.filter { !$0.trashed && !$0.isFolder && (
                    $0.mime.hasPrefix("audio/") || ["mp3", "m4a", "wav", "flac", "aac", "ogg"].contains(($0.name as NSString).pathExtension.lowercased())
                ) }
            case .documents:
                return files.filter { !$0.trashed && !$0.isFolder &&
                    ($0.mime.contains("pdf") || $0.mime.hasPrefix("text/") ||
                     $0.mime.contains("msword") || $0.mime.contains("officedocument")) }
            case .privateVault, .transfers, .trash:
                return files.filter { !$0.trashed && !$0.isFolder }
            }
        }()

        let query = appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = base.filter { !$0.isFolder }
        if query.isEmpty { return filtered }
        return filtered.filter { $0.name.lowercased().contains(query) }
    }

    private func canNavigate(_ delta: Int) -> Bool {
        let files = mediaFiles
        guard let idx = files.firstIndex(where: { $0.id == file.id }) else { return false }
        let next = idx + delta
        return next >= 0 && next < files.count
    }

    private func navigateMedia(delta: Int) {
        let files = mediaFiles
        guard let currentIndex = files.firstIndex(where: { $0.id == file.id }) else { return }
        let nextIndex = min(max(currentIndex + delta, 0), files.count - 1)
        guard nextIndex != currentIndex else { return }
        appState.theaterFile = files[nextIndex]
    }

    private func toggleControls() {
        withAnimation {
            showControls.toggle()
        }
    }

    private func loadFile() async {
        if previewKind != .audio {
            AudioPlayerEngine.shared.stop()
        }

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

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            // Large Glowing Disc with Animated Equalizer Waveform
            ZStack {
                Circle()
                    .fill(XTheme.brandGradient)
                    .frame(width: 200, height: 200)
                    .shadow(color: XTheme.accent.opacity(0.5), radius: 30, y: 10)

                if audioEngine.isPlaying && audioEngine.currentTrack?.id == file.id {
                    EqualizerWaveformView(barCount: 7)
                        .frame(width: 90, height: 80)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 72, weight: .bold))
                        .foregroundStyle(.white)
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
        .onAppear {
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

    func makeNSView(context: Context) -> KeyView {
        let v = KeyView()
        v.onEscape = onEscape
        return v
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onEscape = onEscape
    }

    class KeyView: NSView {
        var onEscape: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil && monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    if event.keyCode == 53 { // 53 = ESC key
                        DispatchQueue.main.async {
                            self?.onEscape?()
                        }
                        return nil // Swallows event so macOS window full-screen is NEVER toggled!
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
