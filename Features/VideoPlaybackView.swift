import SwiftUI
import AppKit

extension Notification.Name {
    static let toggleVideoPlayback = Notification.Name("xcloud_toggleVideoPlayback")
}

/// Apple-TV-style button hover: a slight white tint fills the button's shape
/// while the pointer is over it (over the liquid-glass material). Applied to
/// every player button via `.playerHoverTint(...)` — the shape argument must
/// match the button's own glass shape.
enum PlayerHoverShape {
    case circle
    case capsule
    case roundedRect(cornerRadius: CGFloat)
}

struct PlayerHoverTint: ViewModifier {
    let shape: PlayerHoverShape
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay {
                switch shape {
                case .circle:
                    Circle().fill(Color.white.opacity(hovering ? 0.16 : 0))
                case .capsule:
                    Capsule().fill(Color.white.opacity(hovering ? 0.16 : 0))
                case .roundedRect(let r):
                    RoundedRectangle(cornerRadius: r, style: .continuous)
                        .fill(Color.white.opacity(hovering ? 0.16 : 0))
                }
            }
            // Decorative tint only — it must NEVER intercept input. A shape
            // overlay is hit-testable even when its fill is transparent, so
            // without this a tinted PARENT (the volume pill capsule) would
            // swallow every drag aimed at the slider beneath it.
            .allowsHitTesting(false)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    func playerHoverTint(_ shape: PlayerHoverShape = .circle) -> some View {
        modifier(PlayerHoverTint(shape: shape))
    }
}

struct VideoPlaybackView: View {
    let object: ObjectRecord
    var onMinimize: () -> Void = {}
    var onToggleFullScreen: () -> Void = {}
    var onClose: () -> Void = {}
    @Bindable var audioEngine = AudioPlayerEngine.shared
    @ObservedObject private var fullScreenWindow = PlayerFullScreenWindow.shared
    @State private var error: String?

    var body: some View {
        ZStack {
            if audioEngine.currentTrack?.id == object.id {
                if audioEngine.isMPVPlayback, let mpv = audioEngine.mpvController {
                    // mpv (libmpv) streams any container from the local byte-range server.
                    MPVVideoView(controller: mpv)
                        .id(ObjectIdentifier(mpv)) // rebuild the view when a new controller takes over
                        .onKeyPress(.space) {
                            audioEngine.togglePlayPause()
                            return .handled
                        }
                        .overlay { PlayerStatusOverlay(mpv: mpv) }
                        .overlay {
                            PlayerControlsView(
                                mpv: mpv,
                                title: object.name,
                                subtitle: ByteCountFormatter.string(fromByteCount: object.size, countStyle: .file),
                                isFullScreen: fullScreenWindow.isActive,
                                onMinimize: onMinimize,
                                onToggleFullScreen: onToggleFullScreen,
                                onClose: onClose
                            )
                        }
                } else {
                    loadingView
                }
            } else if let playbackError = audioEngine.playbackError {
                VStack(spacing: 10) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.red.opacity(0.8))
                    Text(playbackError).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
            } else if let error {
                VStack(spacing: 10) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.red.opacity(0.8))
                    Text(error).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
            } else {
                loadingView
            }
        }
        .task(id: object.id) {
            if audioEngine.currentTrack?.id != object.id {
                audioEngine.play(file: object)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleVideoPlayback)) { _ in
            audioEngine.togglePlayPause()
        }
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.large)
                .tint(.white)
            Text("Connecting to stream…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .background(
            .black.opacity(0.45),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Buffer loader shown while the mpv core is initializing (covers the theater's
/// fade-in window), until the first video frame is on screen, and while mpv
/// stalls for the cache — the player never presents a silent black void. It
/// observes the controller directly so @Published transitions re-render it live,
/// and fades in/out smoothly.
///
/// Two states:
///  - Initial loading (core init / first frame pending): circular spinner +
///    "Loading…" label.
///  - Mid-playback cache stall: a progress ring that fills as mpv's
///    cache-buffering-state climbs, with the percentage in the center.
struct PlayerStatusOverlay: View {
    @ObservedObject var mpv: MPVController
    var isAudio = false

    private var showStatus: Bool {
        // Headless audio never renders a first frame — gate on the core only.
        isAudio
            ? (!mpv.isCoreReady || (mpv.isBuffering && !mpv.isSeeking))
            : (!mpv.isCoreReady || !mpv.hasFirstFrame || (mpv.isBuffering && !mpv.isSeeking))
    }

    private var isLoading: Bool {
        isAudio ? !mpv.isCoreReady : (!mpv.isCoreReady || !mpv.hasFirstFrame)
    }

    var body: some View {
        if showStatus {
            VStack(spacing: 10) {
                if isLoading {
                    // Initial load — core init / first frame not on screen yet.
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text("Loading…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                } else if mpv.bufferProgress > 0 {
                    // Cache stall — the ring fills as the buffer refills.
                    ZStack {
                        Circle()
                            .stroke(.white.opacity(0.2), lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: mpv.bufferProgress)
                            .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.easeOut(duration: 0.2), value: mpv.bufferProgress)
                        Text("\(Int((mpv.bufferProgress * 100).rounded()))%")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                    }
                    .frame(width: 46, height: 46)
                    Text("Buffering…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                } else {
                    // Fresh stall, no progress data yet.
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text("Buffering…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(
                .black.opacity(0.45),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: showStatus)
        }
    }
}

/// Self-contained player chrome (flux-style): a top bar (minimize, title,
/// volume, full screen, close), a truly-centered transport (-10s / play / +10s),
/// a bottom bar (title, track selection, drag seek bar) and the "Press Esc again
/// to exit" hint. Owns its own hover timer so it auto-hides after 3 seconds of
/// mouse stillness, in both the windowed player and the full-screen window.
struct PlayerControlsView: View {
    @ObservedObject var mpv: MPVController
    let title: String
    let subtitle: String
    var isFullScreen = false
    var showExitWarning = false
    var onMinimize: () -> Void = {}
    var onToggleFullScreen: () -> Void = {}
    var onClose: () -> Void = {}
    @Environment(AppState.self) private var appState

    @State private var isControlsVisible = true
    @State private var hoverTimer: Timer?
    @State private var showSubtitlePopover = false
    @State private var showAudioPopover = false
    @State private var dragProgress: Double?
    // Holds the clicked/dragged position after release until mpv's time-pos
    // telemetry actually lands there — without it the bar snaps back to the
    // OLD position for a split second after every seek.
    @State private var seekTarget: Double?
    @State private var isSharing = false
    @State private var showShareFeedback = false
    @Bindable private var volumeManager = SystemVolumeManager.shared

    private let autoHideDelay: TimeInterval = 3.0

    var body: some View {
        ZStack {
            // Invisible hover catcher keeps the auto-hide timer alive while the
            // mouse is over the player and lets the chrome fade back in.
            Color.black.opacity(0.001)
                .onContinuousHover { phase in
                    if case .active = phase {
                        showControls()
                    }
                }

            if isControlsVisible || showExitWarning {
                VStack(spacing: 0) {
                    topBar

                    Spacer()

                    // Center transport — hidden until the first frame is live so it
                    // never overlaps the status spinner, and while buffering
                    // (spinner takes over).
                    if mpv.hasFirstFrame && !mpv.isBuffering {
                        transportArea
                    }

                    Spacer()

                    bottomBar
                }
                .transition(.opacity)
            }

            if showExitWarning {
                Text("Press Esc again to exit")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            // Share feedback — brief glass pill under the top bar after the link
            // is created and copied.
            if showShareFeedback {
                Text("Share link copied")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 72)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isControlsVisible)
        .animation(.easeInOut(duration: 0.2), value: showExitWarning)
        .onAppear { showControls() }
        .onChange(of: showExitWarning) { _, newValue in
            if newValue { showControls() }
        }
        .onChange(of: showSubtitlePopover) { _, newValue in
            if newValue {
                hoverTimer?.invalidate()
            } else {
                showControls()
            }
        }
        .onChange(of: showAudioPopover) { _, newValue in
            if newValue {
                hoverTimer?.invalidate()
            } else {
                showControls()
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 12) {
            // Share the file currently playing — same ShareEngine flow as the
            // browser's Share action (forward-based link, copied to clipboard).
            Button {
                shareCurrentFile()
            } label: {
                Group {
                    if isSharing {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.85))
                    }
                }
                .frame(width: 36, height: 36)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: .circle)
                .playerHoverTint()
            }
            .buttonStyle(.plain)
            .help("Share")

            // The file name + size live ONLY above the progress bar (bottom bar)
            // — no duplicate title row up here. The X on the right closes the
            // player, so there's no minimize chevron either.
            Spacer()

            // Volume pill — the app's volume IS the system output volume
            // (SystemVolumeManager), so keyboard keys, the volume rockers, and
            // this slider are the same control. Bound via @Bindable so the
            // slider and mute icon track EXTERNAL changes (rocker keys, Control
            // Center) live — a raw Binding(get:) would only ever re-read on
            // this view's own re-renders and appear dead to rocker changes.
            HStack(spacing: 10) {
                Image(systemName: volumeManager.volume > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.8))

                Slider(value: $volumeManager.volume, in: 0...1)
                    .frame(width: 80)
                    .tint(.white)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .glassEffect(.regular.interactive(), in: .capsule)

            Button(action: onToggleFullScreen) {
                Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
                    .playerHoverTint()
            }
            .buttonStyle(.plain)
            .help(isFullScreen ? "Exit Full Screen" : "Full Screen")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
                    .playerHoverTint()
            }
            .buttonStyle(.plain)
            .help("Close Player")
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .background(
            LinearGradient(colors: [isFullScreen ? .black.opacity(0.15) : .black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }

    // MARK: - Center Transport

    /// True while a previous file exists in the playlist row navigation — the
    /// Previous button only shows then (no disabled ghost buttons).
    private var canGoPrevious: Bool {
        let engine = AudioPlayerEngine.shared
        guard let track = engine.currentTrack, !engine.playlist.isEmpty else { return false }
        guard let idx = engine.playlist.firstIndex(where: { $0.id == track.id }) else { return false }
        return idx > 0
    }

    /// True while a next file exists in the playlist row navigation.
    private var canGoNext: Bool {
        let engine = AudioPlayerEngine.shared
        guard let track = engine.currentTrack, !engine.playlist.isEmpty else { return false }
        guard let idx = engine.playlist.firstIndex(where: { $0.id == track.id }) else { return false }
        return idx + 1 < engine.playlist.count
    }

    /// The centered transport (-10s / play / +10s) with Play Previous / Play Next
    /// pinned to the left and right edges of the player, vertically centered with
    /// the transport. Every control is the same liquid-glass material
    /// (.glassEffect regular interactive, circle) — the transport reads as one
    /// glass control cluster; nothing is a solid fill.
    private var transportArea: some View {
        ZStack {
            HStack(spacing: 56) {
                Button {
                    mpv.seek(relative: -10)
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(width: 58, height: 58)
                        .contentShape(Circle())
                        .glassEffect(.regular.interactive(), in: .circle)
                        .playerHoverTint()
                }
                .buttonStyle(.plain)
                .help("Back 10 seconds")

                Button {
                    // Through the engine so an ended (EOF) video replays from
                    // the start instead of toggling a dead core.
                    AudioPlayerEngine.shared.togglePlayPause()
                } label: {
                    Image(systemName: mpv.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 76, height: 76)
                        .contentShape(Circle())
                        .glassEffect(.regular.interactive(), in: .circle)
                        .playerHoverTint()
                }
                .buttonStyle(.plain)
                .help(mpv.isPlaying ? "Pause" : "Play")

                Button {
                    mpv.seek(relative: 10)
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(width: 58, height: 58)
                        .contentShape(Circle())
                        .glassEffect(.regular.interactive(), in: .circle)
                        .playerHoverTint()
                }
                .buttonStyle(.plain)
                .help("Forward 10 seconds")
            }

            // Previous / next arrows on the left/right edges, vertically centered
            // with the transport — the row fills the cluster's height band so
            // the buttons always share its exact center. Each shows ONLY when
            // a file exists on that side of the row navigation.
            HStack {
                if canGoPrevious {
                    Button {
                        AudioPlayerEngine.shared.skipPrevious()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white.opacity(0.92))
                            .frame(width: 46, height: 46)
                            .contentShape(Circle())
                            .glassEffect(.regular.interactive(), in: .circle)
                            .playerHoverTint()
                    }
                    .buttonStyle(.plain)
                    .help("Previous")
                }

                Spacer()

                if canGoNext {
                    Button {
                        AudioPlayerEngine.shared.skipNext()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white.opacity(0.92))
                            .frame(width: 46, height: 46)
                            .contentShape(Circle())
                            .glassEffect(.regular.interactive(), in: .circle)
                            .playerHoverTint()
                    }
                    .buttonStyle(.plain)
                    .help("Next")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity) // fill the 76pt band → same center as the play cluster
            .padding(.horizontal, 28)
        }
        .frame(height: 76) // pin the band: the play cluster defines the row's height
        .frame(maxWidth: .infinity)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Title & Track Selection Row
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(subtitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .shadow(radius: 2)

                    Text(title)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.middle) // long filenames keep their start + extension
                        .shadow(radius: 4)
                }

                Spacer()

                // Pills: subtitles + audio — one shared glass capsule.
                HStack(spacing: 0) {
                    Button {
                        showSubtitlePopover.toggle()
                    } label: {
                        Image(systemName: "captions.bubble.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.9))
                    }
                    .frame(width: 44, height: 36)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    .popover(isPresented: $showSubtitlePopover, arrowEdge: .bottom) {
                        TrackSelectionList(
                            title: "Subtitles",
                            tracks: mpv.subtitleTracks,
                            onSelect: { mpv.selectTrack($0) }
                        )
                    }

                    Divider()
                        .frame(height: 20)
                        .background(Color.white.opacity(0.2))

                    Button {
                        showAudioPopover.toggle()
                    } label: {
                        Image(systemName: "waveform")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.9))
                    }
                    .frame(width: 44, height: 36)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    .popover(isPresented: $showAudioPopover, arrowEdge: .bottom) {
                        TrackSelectionList(
                            title: "Audio",
                            tracks: mpv.audioTracks,
                            onSelect: { mpv.selectTrack($0) }
                        )
                    }
                }
                .glassEffect(.regular.interactive(), in: .capsule)
                .playerHoverTint(.capsule)
            }

            // Progress Bar Row (Full Width)
            HStack(spacing: 20) {
                // Equal-width time labels so the bar is centered between them —
                // a wide "-1:23:45" right label would otherwise push the bar's
                // visual center off to the left. Text hugs the BAR side of its
                // frame (left label trailing, right label leading) so the gap
                // from each stamp to the bar is the same 20pt — the bar reads
                // as centered between the two stamps (Apple TV / flux look).
                Text(formatTime(displayedTime))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .shadow(radius: 2)
                    .frame(width: 76, height: 28, alignment: .trailing)

                // Custom Slider — the whole 28pt band is the hit area
                // (contentShape on the ZStack that owns the gesture, NOT the
                // thin 5pt track: SwiftUI hit-tests the gesture view's shape).
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
                    .contentShape(Rectangle())
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
                                mpv.seek(to: newProgress)
                                holdProgressUntilSeekLands(newProgress)
                            }
                    )
                }
                .frame(height: 28)
                .contentShape(Rectangle())

                Text("-\(formatTime(max(0, mpv.duration - displayedTime)))")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .shadow(radius: 2)
                    .frame(width: 76, height: 28, alignment: .leading)
            }
        }
        .padding(.horizontal, 60)
        .padding(.bottom, 40)
        .background(
            LinearGradient(colors: [.clear, isFullScreen ? .black.opacity(0.25) : .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }

    // MARK: - Helpers

    /// Creates a share link for the file currently playing (same ShareEngine
    /// flow as the browser: forward-based link, Drive-style reuse) and copies it
    /// to the clipboard with a brief glass confirmation.
    private func shareCurrentFile() {
        guard let track = AudioPlayerEngine.shared.currentTrack, !isSharing else { return }
        isSharing = true
        Task {
            defer { isSharing = false }
            do {
                let link = try await ShareEngine.share(object: track)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
                withAnimation(.easeOut(duration: 0.2)) {
                    showShareFeedback = true
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                withAnimation(.easeIn(duration: 0.2)) {
                    showShareFeedback = false
                }
            } catch {
                appState.alertMessage = ShareEngine.describe(error)
            }
        }
    }

    private func showControls() {
        hoverTimer?.invalidate()
        if !isControlsVisible {
            withAnimation(.easeInOut(duration: 0.2)) {
                isControlsVisible = true
            }
        }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: autoHideDelay, repeats: false) { _ in
            Task { @MainActor in
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.isControlsVisible = false
                }
            }
        }
    }

    private var displayedProgress: Double {
        if let dragProgress {
            return dragProgress
        }
        if let seekTarget, abs(mpv.progress - seekTarget) > 0.01 {
            return seekTarget
        }
        return mpv.progress
    }

    /// Pins the bar to the requested position until mpv reports it (seeks to
    /// keyframes land a few frames later); gives up after 1.5s so a failed
    /// seek can never leave the bar frozen at a stale position.
    private func holdProgressUntilSeekLands(_ target: Double) {
        seekTarget = target
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if self.seekTarget == target {
                self.seekTarget = nil
            }
        }
    }

    private var displayedTime: Double {
        if let dragProgress {
            return dragProgress * mpv.duration
        }
        return mpv.timePos
    }

    private func formatTime(_ seconds: Double) -> String {
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

/// Track picker for the audio / subtitle popovers — checkmark on the selected
/// track, plain list rows, scrollable when many tracks exist.
private struct TrackSelectionList: View {
    let title: String
    let tracks: [Track]
    let onSelect: (Track) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(tracks) { track in
                        Button {
                            onSelect(track)
                        } label: {
                            HStack {
                                if track.isSelected {
                                    Image(systemName: "checkmark")
                                        .frame(width: 16)
                                } else {
                                    Spacer().frame(width: 16)
                                }

                                Text(track.displayName)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(track.isSelected ? Color.white.opacity(0.1) : Color.clear)
                        .cornerRadius(6)
                    }
                }
                .padding(8)
            }
        }
        .frame(minWidth: 200, maxHeight: 300)
        .padding(.bottom, 8)
    }
}