import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WebKit

struct TheaterView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
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
    // The two-step "press Esc again" exit hint lives ONLY in the fullscreen
    // player (PlayerFullScreenWindow.showExitWarning); in the theater a single
    // ESC exits playback for everything.
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
        if file.isVideo { return .video }
        if file.isPhoto { return .image }
        if file.isAudio { return .audio }
        let ext = (file.name as NSString).pathExtension.lowercased()
        if file.mime.contains("pdf") || ext == "pdf" { return .pdf }
        if file.mime.hasPrefix("text/") || ["txt", "md", "json", "log", "csv", "swift", "js", "ts", "py", "sh", "yml", "yaml", "xml", "html", "css"].contains(ext) { return .text }
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
            // While the video plays in the separate fullscreen player window,
            // the theater fades out entirely (the mpv layer is re-parented
            // into that window, so there is nothing left to show here) — the
            // file browser behind becomes visible and usable, so the user can
            // explore the app while the video keeps playing fullscreen. The
            // view stays MOUNTED: dismantling it would tear down mpv and close
            // the fullscreen window. Only the key monitor stays live, so
            // ESC/arrows/space keep working while the theater is invisible.
            Group {
                ZStack {
                    // The player stays MOUNTED here at all times. Swapping it for the
                    // placeholder when fullscreen activates would dismantle the mpv
                    // NSViewController, whose teardown destroys the core AND auto-closes
                    // the fullscreen window (PlayerFullScreenWindow.dismiss in teardown)
                    // — the window flashed up and died instantly. Underneath, the (now
                    // empty) player view just sits idle while the mpv layer is in the
                    // fullscreen window.
                    ZStack {
                        // Adaptable canvas background (Dark / Slate / Light)
                        canvasBackground.color.ignoresSafeArea()

                    // Content
                    Group {
                        if isMetadataOnly {
                            detailsView
                        } else if let errorMessage {
                            errorView(errorMessage)
                        } else if previewKind == .video || previewKind == .audio || url != nil {
                            contentView
                        } else {
                            downloadingView
                        }
                    }

                    // Floating top controls. Video AND audio players own all their chrome now
                    // (self-contained PlayerControlsView), so the old viewer top bar is
                    // suppressed for media to avoid two overlapping control sets.
                    VStack {
                        if showControls, previewKind != .video, previewKind != .audio {
                            topControls
                                .transition(.opacity)
                        }
                        Spacer()

                        // Bottom info bar (hidden for media — the player controls own the
                        // bottom chrome there: seek bar, time labels, volume, tracks).
                        if showControls, url != nil, previewKind != .video, previewKind != .audio {
                            bottomInfoBar
                                .transition(.opacity)
                        }
                    }

                    // Navigation arrows (media players use keyboard arrows; the chevrons
                    // are part of the old viewer chrome and would clash with the player).
                    if showControls, url != nil, previewKind != .video, previewKind != .audio {
                        navigationOverlay
                    }
                }
                }
            }
            .opacity(fullscreenHidesTheater ? 0 : 1)
            .allowsHitTesting(!fullscreenHidesTheater)
            .animation(.easeOut(duration: 0.15), value: PlayerFullScreenWindow.shared.videoLiveInFullscreen)

            // Global window key monitor for ESC, Left/Right Arrows, Spacebar, and
            // the media keys (F7/F8/F9). While a video plays, arrows seek instead of
            // navigating files (player-standard) and up/down change volume — the
            // seek is handled by AudioPlayerEngine.seekVideo which NEVER falls back
            // to switching files.
            KeyMonitorView(
                onEscape: { handleEscapeKey() },
                onLeftArrow: {
                    // Video in FULLSCREEN: arrows seek ±10s (player standard).
                    // Everywhere else (preview player, audio): arrows move
                    // between files.
                    if previewKind == .video, PlayerFullScreenWindow.shared.isActive {
                        AudioPlayerEngine.shared.seekVideo(relative: -10)
                    } else {
                        navigateMedia(delta: -1)
                    }
                },
                onRightArrow: {
                    if previewKind == .video, PlayerFullScreenWindow.shared.isActive {
                        AudioPlayerEngine.shared.seekVideo(relative: 10)
                    } else {
                        navigateMedia(delta: 1)
                    }
                },
                onUpArrow: {
                    // Video AND audio: up/down step the IN-PLAYER volume
                    // (flux adjustVolume, ±5%) — never the system device.
                    // Other previews: vertical navigation.
                    if previewKind == .video || previewKind == .audio {
                        if let mpv = AudioPlayerEngine.shared.mpvController {
                            mpv.adjustPlayerVolume(0.05)
                        } else {
                            SystemVolumeManager.shared.volume = min(1.0, SystemVolumeManager.shared.volume + 0.1)
                        }
                    } else {
                        navigateMediaVertical(delta: -1)
                    }
                },
                onDownArrow: {
                    if previewKind == .video || previewKind == .audio {
                        if let mpv = AudioPlayerEngine.shared.mpvController {
                            mpv.adjustPlayerVolume(-0.05)
                        } else {
                            SystemVolumeManager.shared.volume = max(0.0, SystemVolumeManager.shared.volume - 0.1)
                        }
                    } else {
                        navigateMediaVertical(delta: 1)
                    }
                },
                onSpacebar: {
                    mediaPlayPause()
                },
                onMediaPlayPause: (previewKind == .video || previewKind == .audio) ? { mediaPlayPause() } : nil,
                onMediaForward: (previewKind == .video || previewKind == .audio) ? { mediaForward() } : nil,
                onMediaBackward: (previewKind == .video || previewKind == .audio) ? { mediaBackward() } : nil
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
                withAnimation { togglePlayerFullScreen() }
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
            if previewKind == .video, PlayerFullScreenWindow.shared.isActive {
                AudioPlayerEngine.shared.seekVideo(relative: -10)
            } else {
                navigateMedia(delta: -1)
            }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            if previewKind == .video, PlayerFullScreenWindow.shared.isActive {
                AudioPlayerEngine.shared.seekVideo(relative: 10)
            } else {
                navigateMedia(delta: 1)
            }
            return .handled
        }
        .onKeyPress(.upArrow) {
            // Video AND audio: up/down adjust the in-player volume (see the
            // key-monitor copy above). Other previews: vertical navigation.
            if previewKind == .video || previewKind == .audio {
                if let mpv = AudioPlayerEngine.shared.mpvController {
                    mpv.adjustPlayerVolume(0.05)
                } else {
                    SystemVolumeManager.shared.volume = min(1.0, SystemVolumeManager.shared.volume + 0.1)
                }
            } else {
                navigateMediaVertical(delta: -1)
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if previewKind == .video || previewKind == .audio {
                if let mpv = AudioPlayerEngine.shared.mpvController {
                    mpv.adjustPlayerVolume(-0.05)
                } else {
                    SystemVolumeManager.shared.volume = max(0.0, SystemVolumeManager.shared.volume - 0.1)
                }
            } else {
                navigateMediaVertical(delta: 1)
            }
            return .handled
        }
        .onKeyPress(.space) {
            mediaPlayPause()
            return .handled
        }
        .task(id: file.id) {
            isFocused = true
            // Start media playback IMMEDIATELY, in parallel with loadFile — the
            // layout load + mpv core init then overlap the theater fade-in instead
            // of following it. This is what killed the "split second of lag / the
            // player opens semi-transparent like the animation got stuck" pause:
            // playback previously waited for loadFile's stream-URL await AND the
            // view's own task, both sequential. The views' tasks guard
            // (currentTrack?.id == file.id) makes them no-ops here.
            if previewKind == .video || previewKind == .audio {
                AudioPlayerEngine.shared.play(file: file, in: mediaFiles)
            }
            await loadFile()
        }
        .onChange(of: AudioPlayerEngine.shared.currentTrack?.id) { _, _ in
            // Play Next / Previous (transport buttons, F7/F9, EOF auto-advance)
            // swap the engine's currentTrack. The theater MUST follow: the player
            // view is bound to the theater's file, so without this it stays on the
            // old file and detaches from the new mpv controller — the black
            // loading screen the skip buttons used to show.
            guard let track = AudioPlayerEngine.shared.currentTrack,
                  track.isVideo || track.isAudio,
                  let current = appState.theaterFile,
                  current.isVideo || current.isAudio,
                  current.id != track.id else { return }
            appState.theaterFile = track
            appState.selectedFiles = [track.id]
        }
    }

    /// Player-only full screen: presents the video in a separate borderless window
    /// covering the screen (PlayerFullScreenWindow). The app window — sidebar,
    /// browser, controls — stays untouched, and the mpv view is re-parented rather
    /// than recreated, so playback continues across the transition. The full-screen
    /// window hosts its own controls overlay (same chrome as the windowed player).
    private func togglePlayerFullScreen() {
        if PlayerFullScreenWindow.shared.isActive {
            PlayerFullScreenWindow.shared.dismiss()
            appState.isTheaterFullScreen = false
        } else if previewKind == .image {
            // Images have no mpv controller — the player window shows the
            // image itself (fit-to-screen, spinner while it downloads).
            // The theater hides underneath and restores on exit.
            PlayerFullScreenWindow.presentImage(appState: appState, file: file)
            appState.isTheaterFullScreen = true
        } else if let mpv = AudioPlayerEngine.shared.mpvController,
                  let layer = mpv.playerView?.playerView {
            PlayerFullScreenWindow.shared.present(
                layer,
                mpv: mpv,
                title: file.name,
                subtitle: sizeText,
                appState: appState,
                onClose: {
                    AudioPlayerEngine.shared.stop()
                    appState.theaterFile = nil
                },
                onDismiss: {
                    appState.isTheaterFullScreen = false
                }
            )
            appState.isTheaterFullScreen = true
        }
    }

    // MARK: - Top Controls

    /// True while the fullscreen window shows THIS theater's content — the
    /// ordinary view hides underneath (opacity 0, no hit-testing) so the two
    /// never display together, and restores on dismiss. Video matches by kind
    /// (one video theater at a time); images match by file, so a direct-open
    /// fullscreen of another file never hides this theater.
    private var fullscreenHidesTheater: Bool {
        if PlayerFullScreenWindow.shared.videoLiveInFullscreen, previewKind == .video {
            return true
        }
        if PlayerFullScreenWindow.shared.imageLiveInFullscreen, previewKind == .image,
           PlayerFullScreenWindow.shared.session?.file?.id == file.id {
            return true
        }
        return false
    }

    /// True while THIS theater's image lives in the fullscreen window — the
    /// fullscreen viewer owns all keys then (it navigates its own playlist
    /// and keeps theaterFile in sync for a seamless restore).
    private var imageFullscreenOwnsKeys: Bool {
        previewKind == .image
            && PlayerFullScreenWindow.shared.imageLiveInFullscreen
            && PlayerFullScreenWindow.shared.session?.file?.id == file.id
    }

    private var topControls: some View {
        HStack(spacing: 12) {
            // Left slot: video floats into the PiP panel (theater closes;
            // expand from the panel's hover controls or by re-opening the
            // file); audio hands off to the mini player (headless playback
            // continues). Images and documents have NOTHING to hand off to —
            // the minimize button used to sit here as a dead no-op (its action
            // never had an image branch), so the slot stays empty for them.
            if previewKind == .video {
                Button {
                    withAnimation(.easeInOut(duration: 0.20)) {
                        togglePictureInPicture()
                    }
                } label: {
                    Image(systemName: "rectangle.bottomthird.inset.filled")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .help("Picture in Picture")
            } else if previewKind == .audio {
                Button {
                    withAnimation(.easeInOut(duration: 0.20)) {
                        if AudioPlayerEngine.shared.currentTrack == nil {
                            AudioPlayerEngine.shared.play(file: file, in: mediaFiles)
                            appState.theaterFile = nil
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .help("Minimize to Background")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                // Folders have no stored size — show the real recursive total so the
                // header never displays a fake "Zero KB" under a folder name.
                Text(sizeText)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.leading, 4)

            Spacer()

            // Full Screen toggle button — player-only fullscreen (separate window),
            // never a whole-app/native-window toggle. For video/audio the mpv view is
            // re-parented, so playback survives the transition; for images the window
            // shows the image fit-to-screen. Top-right, next to Close.
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    togglePlayerFullScreen()
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
            .help(appState.isTheaterFullScreen ? "Exit Full Screen" : "Full Screen")

            // Close button (Stops playback completely)
            Button {
                withAnimation(.easeInOut(duration: 0.20)) {
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
        .padding(.top, appState.isWindowFullScreen ? 12 : 12 + 36)
        .padding(.bottom, 12)
        .background(.black.opacity(0.4), ignoresSafeAreaEdges: .top)
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
            VideoPlaybackView(
                object: file,
                onMinimize: closePlayer,
                onToggleFullScreen: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        togglePlayerFullScreen()
                    }
                },
                onClose: closePlayer,
                onPiP: { togglePictureInPicture() }
            )
        case .audio:
            TheaterAudioPlayerView(
                file: file,
                mediaFiles: mediaFiles,
                onMinimize: {
                    // Minimize hands audio off to the mini player (headless
                    // playback keeps going) — the mini player springs in as the
                    // theater fades out.
                    withAnimation(.easeInOut(duration: 0.20)) {
                        if AudioPlayerEngine.shared.currentTrack == nil {
                            AudioPlayerEngine.shared.play(file: file, in: mediaFiles)
                        }
                        appState.theaterFile = nil
                    }
                },
                onClose: closePlayer
            )
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

                if previewKind == .pdf {
                    Button {
                        // In-app streaming preview: the reader streams the PDF
                        // from the vault (byte ranges) instead of downloading.
                        let book = file
                        appState.theaterFile = nil
                        appState.readerFile = book
                    } label: {
                        Label("Preview", systemImage: "book")
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
        .padding(40)
        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
    }

    private func openWithDefaultApp() {
        Task {
            if let cached = activeLocalURL {
                NSWorkspace.shared.open(cached)
                return
            }
            let downloaded = try? await DownloadEngine.download(object: file, quiet: true) { _, _ in }
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
    private var mediaBase: [ObjectRecord] {
        let files = appState.files
        let base: [ObjectRecord]
        switch appState.selectedDestination {
        case .allFiles:
            base = files.filter { !$0.trashed && !$0.isPrivate && $0.parentID == appState.currentFolderID }
        case .privateVault:
            base = files.filter { !$0.trashed && $0.isPrivate && $0.parentID == appState.currentFolderID }
        case .recent:
            base = Array(files.filter { !$0.trashed && !$0.isFolder && !$0.isPrivate }.prefix(20))
        case .favorites:
            base = files.filter { $0.isFavorite && !$0.trashed && !$0.isPrivate }
        case .photos:
            if let currentID = appState.currentFolderID {
                base = files.filter { !$0.trashed && !$0.isPrivate && $0.parentID == currentID }
            } else {
                // Matches the browser grid: albums first, then EVERY photo in the
                // cloud (no parentID filter — photos living inside folders still
                // appear on the Photos page and must stay navigable in the viewer).
                let albums = files.filter { !$0.trashed && !$0.isPrivate && $0.isFolder && $0.mime == "cascade/album-photo" }
                let photoFiles = files.filter { !$0.trashed && !$0.isFolder && !$0.isPrivate && (
                    $0.mime.hasPrefix("image/") || ["jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp", "svg"].contains(($0.name as NSString).pathExtension.lowercased())
                ) }
                base = albums + photoFiles
            }
        case .video:
            if let currentID = appState.currentFolderID {
                base = files.filter { !$0.trashed && !$0.isPrivate && $0.parentID == currentID }
            } else {
                // Playlists first, then every video in the cloud (extension fallback
                // included, mirroring the browser grid).
                let playlists = files.filter { !$0.trashed && !$0.isPrivate && $0.isFolder && $0.mime == "cascade/playlist-video" }
                let videoFiles = files.filter { !$0.trashed && !$0.isFolder && !$0.isPrivate && (
                    $0.mime.hasPrefix("video/") || ["mp4", "mov", "m4v", "mkv", "avi", "webm", "3gp", "mpg", "mpeg"].contains(($0.name as NSString).pathExtension.lowercased())
                ) }
                base = playlists + videoFiles
            }
        case .audio:
            if let currentID = appState.currentFolderID {
                base = files.filter { !$0.trashed && !$0.isPrivate && $0.parentID == currentID }
            } else {
                // Playlists first, then every audio file in the cloud.
                let playlists = files.filter { !$0.trashed && !$0.isPrivate && $0.isFolder && $0.mime == "cascade/playlist-audio" }
                let audioFiles = files.filter { !$0.trashed && !$0.isFolder && !$0.isPrivate && (
                    $0.mime.hasPrefix("audio/") || ["mp3", "m4a", "wav", "flac", "aac", "ogg"].contains(($0.name as NSString).pathExtension.lowercased())
                ) }
                base = playlists + audioFiles
            }
        case .documents:
            base = files.filter { !$0.trashed && !$0.isFolder && !$0.isPrivate &&
                ($0.mime.contains("pdf") || $0.mime.hasPrefix("text/") ||
                 $0.mime.contains("msword") || $0.mime.contains("officedocument")) }
        case .library:
            base = files.filter { !$0.trashed && $0.isBook }
        case .transfers:
            base = []
        case .shared:
            // Files I imported via share links (incoming only) — mirrors the
            // browser grid's Shared filter.
            let sharedIDs = appState.sharedObjectIDs
            base = files.filter { sharedIDs.contains($0.id) && !$0.trashed }
        case .archive:
            base = files.filter { $0.isArchived }
        case .trash:
            base = files.filter { $0.trashed }
        }
        // Archived files are hidden everywhere except the Archive destination.
        if appState.selectedDestination == .archive { return base }
        return base.filter { !$0.isArchived }
    }

    /// Same filters, search, and sort as the browser's visible list — folders and
    /// files are kept together here and split by `mediaFiles`/`navigableFiles`.
    private var sortedMediaBase: [ObjectRecord] {
        let query = appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let searched = query.isEmpty ? mediaBase : mediaBase.filter { $0.name.lowercased().contains(query) }

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

    /// Files only — drives audio playback queues and the filmstrip. On the
    /// Photos/Videos pages this follows the grid's reported visual order
    /// (albums/playlists, then day-grouped media) so the queue, counter, and
    /// filmstrip all match what's on screen.
    private var mediaFiles: [ObjectRecord] {
        let files = sortedMediaBase.filter { !$0.isFolder }
        guard appState.selectedDestination == .photos || appState.selectedDestination == .video else { return files }
        return orderedFromGrid(files)
    }

    /// Reorders `files` to the exact sequence the Photos/Videos grid reports
    /// (AppState.mediaOrderedIDs). Falls back to the input order if the grid
    /// hasn't reported yet — never empty, never a different order than the grid.
    private func orderedFromGrid(_ files: [ObjectRecord]) -> [ObjectRecord] {
        guard !appState.mediaOrderedIDs.isEmpty else { return files }
        let byID = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ordered = appState.mediaOrderedIDs.compactMap { byID[$0] }
        return ordered.isEmpty ? files : ordered
    }

    /// Navigable arrow-key order, matching the browser grid: the folder section
    /// first (up to 4 columns), then the files. Includes folders so that a folder
    /// preview can navigate on both axes — previously folders were stripped here,
    /// so previewing a folder made every arrow key a no-op. On the Photos/Videos
    /// pages the order is the grid's own reported sequence (day-grouped), never
    /// the global sort — this is what keeps the viewer's arrows in lockstep with
    /// the visible grid.
    private var navigableFiles: [ObjectRecord] {
        let folders = sortedMediaBase.filter(\.isFolder)
        let files = sortedMediaBase.filter { !$0.isFolder }
        guard appState.selectedDestination == .photos || appState.selectedDestination == .video else {
            return folders + files
        }
        return orderedFromGrid(folders + files)
    }

    private func canNavigate(_ delta: Int) -> Bool {
        let files = navigableFiles
        guard let idx = files.firstIndex(where: { $0.id == file.id }) else { return false }
        let next = idx + delta
        return next >= 0 && next < files.count
    }

    private func onMouseActivity() {
        controlsTimer?.invalidate()
        // NOTE: chrome visibility flips are intentionally NOT animated
        // anywhere in the viewer — fades/slides made toggles feel laggy.
        showControls = true
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { _ in
            Task { @MainActor in
                showControls = false
            }
        }
    }

    private func refreshTimerIfVisible() {
        if showControls {
            controlsTimer?.invalidate()
            controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { _ in
                Task { @MainActor in
                    showControls = false
                }
            }
        }
    }

    private func navigateMedia(delta: Int) {
        // The fullscreen image viewer owns navigation while it shows this
        // theater's file (it keeps theaterFile in sync for the restore).
        guard !imageFullscreenOwnsKeys else { return }
        refreshTimerIfVisible()
        let files = navigableFiles
        guard let currentIndex = files.firstIndex(where: { $0.id == file.id }) else { return }
        let nextIndex = min(max(currentIndex + delta, 0), files.count - 1)
        guard nextIndex != currentIndex else { return }
        let next = files[nextIndex]
        appState.theaterFile = next
        // Keep the browser's selection in sync so closing the viewer (space) and
        // reopening it shows the image we were just looking at.
        appState.selectedFiles = [next.id]
    }

    /// Up/down arrow navigation: moves to the file in the same grid column of the
    /// row above/below, using the exact row/column math the browser's arrow keys
    /// use (FileBrowserView.gridVerticalStep) over the same on-screen order. This
    /// is what makes "column navigation" work while previewing, matching what the
    /// grid shows under the viewer.
    private func navigateMediaVertical(delta: Int) {
        guard !imageFullscreenOwnsKeys else { return }
        refreshTimerIfVisible()
        let files = navigableFiles
        guard let currentIndex = files.firstIndex(where: { $0.id == file.id }) else { return }
        let cols = max(2, appState.gridColumnCount)
        let nextIndex = FileBrowserView.gridVerticalStep(current: currentIndex, delta: delta, files: files, cols: cols)
        guard nextIndex != currentIndex, files.indices.contains(nextIndex) else { return }
        let next = files[nextIndex]
        appState.theaterFile = next
        appState.selectedFiles = [next.id]
    }
    // MARK: - Media key / player transport helpers

    /// Shared by space, the F8 media key, and the .onKeyPress fallback.
    private func mediaPlayPause() {
        // Space while the fullscreen viewer owns this image must not close
        // the hidden theater underneath it.
        if imageFullscreenOwnsKeys { return }
        if previewKind == .image || previewKind == .pdf || previewKind == .text || previewKind == .other || previewKind == .folder {
            // Space toggles the viewer (Quick Look style): close it.
            appState.theaterFile = nil
        } else if previewKind == .video {
            NotificationCenter.default.post(name: .toggleVideoPlayback, object: nil)
        } else if previewKind == .audio {
            AudioPlayerEngine.shared.togglePlayPause()
        }
    }

    /// F9 / fast-forward media key: videos seek +10 s, audio skips to the next track.
    private func mediaForward() {
        if previewKind == .video {
            AudioPlayerEngine.shared.seekVideo(relative: 10)
        } else if previewKind == .audio {
            AudioPlayerEngine.shared.skipNext()
        }
    }

    /// F7 / rewind media key: videos seek -10 s, audio goes to the previous track.
    private func mediaBackward() {
        if previewKind == .video {
            AudioPlayerEngine.shared.seekVideo(relative: -10)
        } else if previewKind == .audio {
            AudioPlayerEngine.shared.skipPrevious()
        }
    }

    private var activeLocalURL: URL? {
        // The cascade-stream:// URL is not a real file — only expose real local files
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
            showControls = false
        } else {
            onMouseActivity()
        }
    }

    /// Stops playback and closes the theater (the player chrome's minimize and
    /// close buttons, windowed mode). While PiP holds the video, its layer is
    /// restored FIRST so the view teardown never destroys a core the panel is
    /// still showing.
    private func closePlayer() {
        withAnimation(.easeInOut(duration: 0.20)) {
            if PictureInPictureWindow.shared.isActive {
                PictureInPictureWindow.shared.dismiss()
                AudioPlayerEngine.shared.stop()
                appState.theaterFile = nil
            } else {
                AudioPlayerEngine.shared.stop()
                appState.theaterFile = nil
            }
        }
    }

    /// Wave 2 item 5 — float the live video into the always-on-top PiP panel
    /// (or expand it back). Entering CLOSES the theater: the panel is where
    /// playback lives; the view's dismantle skips mpv cleanup while PiP holds
    /// the layer, and PiP retains the controller-view so commands keep routing.
    private func togglePictureInPicture() {
        if PictureInPictureWindow.shared.isActive {
            PictureInPictureWindow.shared.expandToTheater()
        } else {
            guard PictureInPictureWindow.shared.presentFromEngine(
                title: file.name, file: file, appState: appState
            ) else { return }
            withAnimation(.easeInOut(duration: 0.20)) {
                appState.theaterFile = nil
            }
        }
    }

    private func handleEscapeKey() {
        controlsTimer?.invalidate()
        // While the full-screen player window is up it owns the Escape key (it has
        // its own two-step handler); ignore it here so windowed ESC never closes
        // the theater out from under the full-screen player.
        if PlayerFullScreenWindow.shared.isActive { return }
        // PiP active → ESC means "stop everything": restore the layer first so
        // the teardown below never hits a view the panel still hosts.
        if PictureInPictureWindow.shared.isActive {
            PictureInPictureWindow.shared.dismiss()
        }
        withAnimation(.easeInOut(duration: 0.20)) {
            if previewKind == .video {
                // Single ESC exits playback and closes the theater (the two-step
                // "Press Esc again" hint is reserved for the FULLSCREEN player).
                // Videos stop when the theater closes — no background handoff.
                AudioPlayerEngine.shared.stop()
                appState.theaterFile = nil
            } else {
                if AudioPlayerEngine.shared.currentTrack == nil {
                    // (Audio already plays headless and keeps going in the mini player.)
                    AudioPlayerEngine.shared.stop()
                }
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

        // Uncached video AND audio stream byte-by-byte from Telegram via mpv instead
        // of downloading the whole file first. mpv demuxes any container (mkv, webm,
        // avi, ogg, flac, ...) from the local byte-range server — audio plays headless
        // with no render surface. The stream URL is set OPTIMISTICALLY so the player
        // view appears instantly: AudioPlayerEngine.play (kicked off in .task, in
        // parallel) resolves the real URL — cached → local file, uncached → stream,
        // unloadable layout → full download — while the player's spinner covers the
        // wait. No layout await here, no separate download gate: play() owns the
        // fallback (a second download path here would double-download).
        if previewKind == .video || previewKind == .audio {
            url = URL(string: "cascade-stream://object-\(file.id)")
            return
        }

        do {
            let downloaded = try await DownloadEngine.download(object: file, quiet: true) { status, progress in
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

// MARK: - Music Player View

/// Apple Music / Spotify-style music player (research: 2026 music-player UI best
/// practices — big artwork as the hero, always-visible chrome, glass controls,
/// drag scrubber with monospaced times, ambient glow from the artwork). Playback
/// starts immediately on open (theater `.task`, in parallel with loadFile) — the
/// spinner overlay covers the mpv core init, and the album art loads in parallel
/// too, so nothing gates the first sound. Minimize hands off to the mini player.
struct TheaterAudioPlayerView: View {
    let file: ObjectRecord
    let mediaFiles: [ObjectRecord]
    var onMinimize: () -> Void = {}
    var onClose: () -> Void = {}
    @Bindable var audioEngine = AudioPlayerEngine.shared
    @Bindable private var volumeManager = SystemVolumeManager.shared
    @State private var thumbURL: URL?
    @State private var dragProgress: Double?
    // Holds the clicked/dragged position after release until mpv's telemetry
    // lands there (the bar used to snap back for a split second after seeks).
    @State private var seekTarget: Double?

    private var isCurrent: Bool { audioEngine.currentTrack?.id == file.id }
    private var isPlaying: Bool { isCurrent && audioEngine.isPlaying }



    private var indexText: String? {
        let idx = mediaFiles.firstIndex(where: { $0.id == file.id })
        return idx.map { "\($0 + 1) of \(mediaFiles.count)" }
    }

    var body: some View {
        ZStack {
            // Ambient glow that echoes the artwork (Spotify-style dynamic tint)
            Circle()
                .fill(XTheme.brandGradient)
                .frame(width: 560, height: 560)
                .blur(radius: 130)
                .opacity(0.14)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                // Top bar
                HStack {
                    Button(action: onMinimize) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white.opacity(0.85))
                            .frame(width: 36, height: 36)
                            .contentShape(Circle())
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .help("Minimize to Mini Player")

                    Spacer()

                    Text("NOW PLAYING")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(XTheme.accent)

                    Spacer()

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white.opacity(0.85))
                            .frame(width: 36, height: 36)
                            .contentShape(Circle())
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .help("Close Player")
                }
                .padding(.horizontal, 32)
                .padding(.top, 24)

                Spacer()

                // Hero artwork — thumbnail if available, else gradient + waveform
                ZStack {
                    if let thumbURL, let nsImage = NSImage(contentsOf: thumbURL) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                    } else {
                        Circle()
                            .fill(XTheme.brandGradient)
                        if isPlaying {
                            EqualizerWaveformView(barCount: 7)
                                .frame(width: 110, height: 96)
                        } else {
                            Image(systemName: "music.note")
                                .font(.system(size: 72, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .frame(width: 240, height: 240)
                .clipShape(Circle())
                .shadow(color: XTheme.accent.opacity(isPlaying ? 0.55 : 0.35), radius: 34, y: 14)
                .scaleEffect(isPlaying ? 1 : 0.97)
                .animation(.easeInOut(duration: 0.5), value: isPlaying)

                // Track details
                VStack(spacing: 6) {
                    Text(file.name)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 8) {
                        Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.5))
                        if let indexText {
                            Text("•")
                                .foregroundStyle(.white.opacity(0.3))
                            Text(indexText)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 22)

                // Custom drag scrubber (same design language as the video player)
                scrubberRow
                    .padding(.top, 26)

                // Transport — 3 iconic player buttons (previous, play/pause, next)
                HStack(spacing: 36) {
                    Button { audioEngine.skipPrevious() } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white.opacity(0.85))
                            .frame(width: 48, height: 48)
                            .contentShape(Circle())
                            .glassEffect(.regular.interactive(), in: .circle)
                            .playerHoverTint()
                    }
                    .buttonStyle(.plain)

                    Button {
                        if isCurrent {
                            audioEngine.togglePlayPause()
                        } else {
                            audioEngine.play(file: file, in: mediaFiles)
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.001)) // glass renders over the backdrop
                            if audioEngine.isLoading && isCurrent {
                                ProgressView()
                                    .controlSize(.regular)
                                    .tint(.white)
                            } else {
                                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 26, weight: .bold))
                                    .foregroundStyle(.white)
                                    .offset(x: isPlaying ? 0 : 2)
                            }
                        }
                        .frame(width: 68, height: 68)
                        .contentShape(Circle())
                        .glassEffect(.regular.interactive(), in: .circle)
                        .playerHoverTint()
                    }
                    .buttonStyle(.plain)

                    Button { audioEngine.skipNext() } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white.opacity(0.85))
                            .frame(width: 48, height: 48)
                            .contentShape(Circle())
                            .glassEffect(.regular.interactive(), in: .circle)
                            .playerHoverTint()
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 68)
                .padding(.top, 30)

                // Volume pill — flux-style gauge shared with the video player
                // (system device 0–100% + orange mpv boost zone, mute toggle).
                Group {
                    if let mpv = audioEngine.mpvController {
                        VolumeGauge(mpv: mpv, gaugeWidth: 90)
                    } else {
                        HStack(spacing: 10) {
                            Image(systemName: volumeManager.volume > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.8))
                            Slider(value: $volumeManager.volume, in: 0...1,
                                   onEditingChanged: { volumeManager.isUserDragging = $0 })
                                .frame(width: 90)
                                .tint(.white)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 34)
                .glassEffect(.regular.interactive(), in: .capsule)
                .padding(.top, 24)

                Spacer()
            }
        }
        .overlay {
            // Spinner while the mpv core initializes (or the URL resolves / a
            // fallback download runs) — playback started from the theater task.
            if isCurrent {
                if audioEngine.isMPVPlayback, let mpv = audioEngine.mpvController {
                    PlayerStatusOverlay(mpv: mpv, isAudio: true)
                } else if !audioEngine.isPlaying && audioEngine.isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.large)
                        .tint(.white)
                }
            }
        }
        .task(id: file.id) {
            // Album art loads in parallel — it never gates playback start.
            thumbURL = await ThumbnailService.shared.thumbnailURL(for: file)
        }
    }

    // MARK: - Scrubber

    private var scrubberRow: some View {
        HStack(spacing: 20) {
            Text(timeString(displayedTime))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
                .frame(width: 76, height: 28, alignment: .trailing)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.3))
                        .frame(height: 5)

                    Capsule()
                        .fill(Color.white)
                        .frame(width: geo.size.width * displayedProgress, height: 5)
                        .shadow(color: .white.opacity(0.5), radius: 4)

                    Circle()
                        .fill(Color.white)
                        .frame(width: 18, height: 18)
                        .offset(x: geo.size.width * displayedProgress - 9)
                        .shadow(radius: 4)
                }
                // Same top-leading fix as the video overlay scrubber:
                // GeometryReader aligns children top-leading by default.
                .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                .contentShape(Rectangle()) // whole 28pt band hit-tests, not just the 5pt track
                .gesture(
                    // minimumDistance 0 → the gesture fires on press, so a
                    // plain CLICK seeks too (onChanged fires with the click
                    // location) and dragging responds immediately. Visual-only
                    // while dragging — one seek on release, no live seeks
                    // (mpv fast-forward artifacts).
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let newProgress = min(max(value.location.x / geo.size.width, 0), 1)
                            dragProgress = newProgress
                        }
                        .onEnded { value in
                            let newProgress = min(max(value.location.x / geo.size.width, 0), 1)
                            dragProgress = nil
                            audioEngine.seek(to: newProgress * max(1, audioEngine.duration))
                            holdProgressUntilSeekLands(newProgress)
                        }
                )
            }
            .frame(height: 28)
            .contentShape(Rectangle())

            Text("-\(timeString(max(0, audioEngine.duration - displayedTime)))")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
                .frame(width: 76, height: 28, alignment: .leading)
        }
        .padding(.horizontal, 60)
        .frame(maxWidth: 720)
    }

    private var displayedProgress: Double {
        guard audioEngine.duration > 0 else { return 0 }
        if let dragProgress { return dragProgress }
        if let seekTarget, abs(progressFraction - seekTarget) > 0.01 {
            return seekTarget
        }
        return progressFraction
    }

    private var progressFraction: Double {
        min(max(audioEngine.currentTime / audioEngine.duration, 0), 1)
    }

    /// Pins the bar to the requested position until mpv reports it; gives up
    /// after 12s (matching MPVController's hold) so a failed seek can never freeze the bar.
    private func holdProgressUntilSeekLands(_ target: Double) {
        seekTarget = target
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            if self.seekTarget == target {
                self.seekTarget = nil
            }
        }
    }

    private var displayedTime: Double {
        if let dragProgress {
            return dragProgress * audioEngine.duration
        }
        return audioEngine.currentTime
    }

    private func timeString(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite && seconds >= 0 else { return "0:00" }
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }
}

// MARK: - Key Monitor for Reliable Escape Key Interception

struct KeyMonitorView: NSViewRepresentable {
    let onEscape: () -> Void
    var onLeftArrow: (() -> Void)? = nil
    var onRightArrow: (() -> Void)? = nil
    var onUpArrow: (() -> Void)? = nil
    var onDownArrow: (() -> Void)? = nil
    var onSpacebar: (() -> Void)? = nil
    // Media keys (F7/F8/F9 on a MacBook keyboard). Non-nil only while a media
    // player is on screen — otherwise the keys pass through to the system.
    var onMediaPlayPause: (() -> Void)? = nil
    var onMediaForward: (() -> Void)? = nil
    var onMediaBackward: (() -> Void)? = nil

    func makeNSView(context: Context) -> KeyView {
        let v = KeyView()
        v.onEscape = onEscape
        v.onLeftArrow = onLeftArrow
        v.onRightArrow = onRightArrow
        v.onUpArrow = onUpArrow
        v.onDownArrow = onDownArrow
        v.onSpacebar = onSpacebar
        v.onMediaPlayPause = onMediaPlayPause
        v.onMediaForward = onMediaForward
        v.onMediaBackward = onMediaBackward
        return v
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onEscape = onEscape
        nsView.onLeftArrow = onLeftArrow
        nsView.onRightArrow = onRightArrow
        nsView.onUpArrow = onUpArrow
        nsView.onDownArrow = onDownArrow
        nsView.onSpacebar = onSpacebar
        nsView.onMediaPlayPause = onMediaPlayPause
        nsView.onMediaForward = onMediaForward
        nsView.onMediaBackward = onMediaBackward
    }

    class KeyView: NSView {
        var onEscape: (() -> Void)?
        var onLeftArrow: (() -> Void)?
        var onRightArrow: (() -> Void)?
        var onUpArrow: (() -> Void)?
        var onDownArrow: (() -> Void)?
        var onSpacebar: (() -> Void)?
        var onMediaPlayPause: (() -> Void)?
        var onMediaForward: (() -> Void)?
        var onMediaBackward: (() -> Void)?
        private var monitor: Any?
        private var mediaMonitor: Any?
        private var lastMediaKeyTime: CFTimeInterval = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil && monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    // If this view is no longer attached to a window (viewer closed),
                    // don't swallow keys — pass everything through so the browser's own
                    // space/arrow handling works again.
                    guard let self, self.window != nil else { return event }
                    if event.keyCode == 53 { // ESC key
                        // While the fullscreen player window is up it OWNS ESC
                        // (two-step exit, key monitor installed at present).
                        // Pass the key through so its monitor sees it — local
                        // monitors fire newest-first, but a re-mount of this
                        // view can reorder them, so never swallow ESC here
                        // while the player is active.
                        if PlayerFullScreenWindow.shared.isActive { return event }
                        DispatchQueue.main.async { self.onEscape?() }
                        return nil
                    } else if event.keyCode == 123, let onLeft = self.onLeftArrow { // Left Arrow
                        DispatchQueue.main.async { onLeft() }
                        return nil
                    } else if event.keyCode == 124, let onRight = self.onRightArrow { // Right Arrow
                        DispatchQueue.main.async { onRight() }
                        return nil
                    } else if event.keyCode == 126, let onUp = self.onUpArrow { // Up Arrow
                        DispatchQueue.main.async { onUp() }
                        return nil
                    } else if event.keyCode == 125, let onDown = self.onDownArrow { // Down Arrow
                        DispatchQueue.main.async { onDown() }
                        return nil
                    } else if event.keyCode == 49, let onSpace = self.onSpacebar { // Spacebar
                        DispatchQueue.main.async { onSpace() }
                        return nil
                    } else if event.keyCode == 98, let cb = self.onMediaBackward { // F7 (rewind)
                        DispatchQueue.main.async { cb() }
                        return nil
                    } else if event.keyCode == 100, let cb = self.onMediaPlayPause { // F8 (play/pause)
                        DispatchQueue.main.async { cb() }
                        return nil
                    } else if event.keyCode == 101, let cb = self.onMediaForward { // F9 (forward)
                        DispatchQueue.main.async { cb() }
                        return nil
                    }
                    return event
                }
            } else if window == nil && monitor != nil {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }

            // Media keys are NSSystemDefined events (subtype 8, NX_SUBTYPE_AUX_CONTROL_BUTTONS),
            // NOT keyDown events — a plain key monitor never sees F7/F8/F9. Consume only
            // play/next/previous; volume/mute (codes 0/1/7) MUST pass through so the OS
            // still adjusts the system output volume (which is the app's volume).
            if window != nil && mediaMonitor == nil {
                mediaMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
                    guard let self, self.window != nil, event.subtype.rawValue == 8 else { return event }
                    let keyCode = Int((event.data1 & 0xFFFF0000) >> 16)
                    let keyFlags = event.data1 & 0x0000FFFF
                    let keyState = (keyFlags & 0xFF00) >> 8 // 0xA = down, 0xB = up
                    guard keyState == 0xA else { return event }
                    let isRepeat = keyFlags & 0x1 != 0
                    // Throttle held-key repeats to ~3 seeks/sec so holding F9 scrubs
                    // forward instead of jumping 10s per event.
                    if isRepeat {
                        let now = CFAbsoluteTimeGetCurrent()
                        guard now - self.lastMediaKeyTime >= 0.3 else { return event }
                    }
                    switch keyCode {
                    case 16: // NX_KEYTYPE_PLAY
                        if let cb = self.onMediaPlayPause, AudioPlayerEngine.consumeMediaKeyPress() {
                            self.lastMediaKeyTime = CFAbsoluteTimeGetCurrent()
                            DispatchQueue.main.async { cb() }
                            return nil
                        }
                    case 17, 19: // NX_KEYTYPE_NEXT / NX_KEYTYPE_FAST
                        if let cb = self.onMediaForward, AudioPlayerEngine.consumeMediaKeyPress() {
                            self.lastMediaKeyTime = CFAbsoluteTimeGetCurrent()
                            DispatchQueue.main.async { cb() }
                            return nil
                        }
                    case 18, 20: // NX_KEYTYPE_PREVIOUS / NX_KEYTYPE_REWIND
                        if let cb = self.onMediaBackward, AudioPlayerEngine.consumeMediaKeyPress() {
                            self.lastMediaKeyTime = CFAbsoluteTimeGetCurrent()
                            DispatchQueue.main.async { cb() }
                            return nil
                        }
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

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let mediaMonitor { NSEvent.removeMonitor(mediaMonitor) }
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
