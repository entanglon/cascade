import SwiftUI
import AppKit

extension Notification.Name {
    static let toggleVideoPlayback = Notification.Name("cascade_toggleVideoPlayback")
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
                // The tint is decoration ONLY — it must never intercept input.
                // allowsHitTesting(false) is scoped to the OVERLAY: placed
                // outside (on the whole composed label) it removes the button's
                // own label + interactive glass from the hit-test tree, which
                // killed every player transport button on macOS 26. A shape
                // overlay is hit-testable even with a transparent fill, so the
                // false is still required here (a tinted PARENT pill would
                // otherwise swallow drags aimed at the slider beneath it).
                switch shape {
                case .circle:
                    Circle().fill(Color.white.opacity(hovering ? 0.16 : 0))
                        .allowsHitTesting(false)
                case .capsule:
                    Capsule().fill(Color.white.opacity(hovering ? 0.16 : 0))
                        .allowsHitTesting(false)
                case .roundedRect(let r):
                    RoundedRectangle(cornerRadius: r, style: .continuous)
                        .fill(Color.white.opacity(hovering ? 0.16 : 0))
                        .allowsHitTesting(false)
                }
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    func playerHoverTint(_ shape: PlayerHoverShape = .circle) -> some View {
        modifier(PlayerHoverTint(shape: shape))
    }
}

/// flux-style volume gauge (ported mechanism from flux/Views/
/// PlayerControlsView.swift `volumeCapsule`): white fill 0–100%, ORANGE boost
/// zone 100–200% with divider notch, % readout, speaker mute toggle with wave
/// levels. The gauge owns the IN-PLAYER volume end to end (mpv 0…200 via
/// VolumeCurve) and never touches the system output device — keyboard/volume
/// keys keep driving the device independently. Drag anywhere on the gauge;
/// mute remembers the pre-mute level. Shared by the video pill and the
/// music-player pill.
struct VolumeGauge: View {
    @ObservedObject var mpv: MPVController
    var gaugeWidth: CGFloat = 80
    @State private var lastUnmuted: Double = 1.0

    private var vol: Double { mpv.playerVolume }
    private var isBoosted: Bool { vol > 1.0 }
    private var isMuted: Bool { vol <= 0.001 }

    private var iconName: String {
        if isMuted { return "speaker.slash.fill" }
        if vol <= 0.33 { return "speaker.wave.1.fill" }
        if vol <= 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if vol > 0.001 {
                    lastUnmuted = min(vol, 1.0)
                    mpv.setPlayerVolume(0)
                } else {
                    mpv.setPlayerVolume(lastUnmuted > 0.001 ? lastUnmuted : 1.0)
                }
            } label: {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isBoosted ? .orange : (isMuted ? .white.opacity(0.45) : .white.opacity(0.9)))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(isMuted ? "Unmute" : "Mute")

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let midX = w / 2.0
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: w, height: h)

                    let normalWidth = midX * CGFloat(min(max(vol, 0.0), 1.0))
                    if normalWidth > 0 {
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: normalWidth, height: h)
                    }

                    if isBoosted {
                        let boostWidth = midX * CGFloat(min(max(vol - 1.0, 0.0), 1.0))
                        if boostWidth > 0 {
                            Rectangle()
                                .fill(LinearGradient(
                                    colors: [Color.orange.opacity(0.90), Color.orange],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ))
                                .frame(width: boostWidth, height: h)
                                .offset(x: midX)
                                .shadow(color: Color.orange.opacity(0.4), radius: 3, x: 0, y: 0)
                        }
                    }

                    Rectangle()
                        .fill(isBoosted ? Color.black.opacity(0.35) : Color.white.opacity(0.55))
                        .frame(width: 1.5, height: h + 2)
                        .position(x: midX, y: h / 2.0)
                }
                .clipShape(Capsule())
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let clampedX = max(0.0, min(value.location.x, w))
                            let stepped = (Double(clampedX / w) * 2.0 * 20.0).rounded() / 20.0
                            mpv.setPlayerVolume(stepped)
                        }
                )
            }
            .frame(width: gaugeWidth, height: 6)
            .accessibilityLabel("Volume gauge")

            Text("\(Int((vol * 100).rounded()))%")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(isBoosted ? .orange : .white.opacity(0.75))
                .frame(minWidth: 36, alignment: .trailing)
        }
    }
}

struct VideoPlaybackView: View {
    let object: ObjectRecord
    var onMinimize: () -> Void = {}
    var onToggleFullScreen: () -> Void = {}
    var onClose: () -> Void = {}
    /// Wave 2 item 5 — float the live video into the PiP panel.
    var onPiP: () -> Void = {}
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
                                onClose: onClose,
                                onPiP: onPiP
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
        // Seeks now SHOW the overlay too: the fetch wait at the new offset is
        // exactly when users need feedback (previously excluded via !isSeeking).
        isAudio
            ? (!mpv.isCoreReady || mpv.isBuffering)
            : (!mpv.isCoreReady || !mpv.hasFirstFrame || mpv.isBuffering)
    }

    private var isLoading: Bool {
        // isPrebuffering (video only — audio never arms the gate): the first
        // frame renders while the gate holds playback paused, so without this
        // the overlay would lift the moment the paused frame appears, before
        // the buffer cushion is banked.
        isAudio ? !mpv.isCoreReady : (!mpv.isCoreReady || !mpv.hasFirstFrame || mpv.isPrebuffering)
    }

    var body: some View {
        if showStatus {
            VStack(spacing: 10) {
                if mpv.isPrebuffering {
                    // Initial buffer gate (video AND headless audio): the ring
                    // fills live as the forward cushion banks toward release
                    // instead of spinning blindly — then playback starts.
                    bufferRing(progress: mpv.prebufferProgress, label: "Loading…")
                } else if isLoading {
                    // Core init / first frame not on screen yet.
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text("Loading…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                } else if mpv.bufferProgress > 0 {
                    // Cache stall — the ring fills as the buffer refills.
                    bufferRing(progress: mpv.bufferProgress, label: "Buffering…")
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

    /// Buffer progress ring: larger dial, heavier track, gradient sweep,
    /// tabular % readout + caption. Shared by the prebuffer gate and
    /// mid-playback stalls so both read as one instrument.
    private func bufferRing(progress: Double, label: String) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.14), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: min(1.0, max(0.0, progress)))
                    .stroke(
                        LinearGradient(
                            colors: [.white, XTheme.accent],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.2), value: progress)
                Text("\(Int((min(1.0, max(0.0, progress)) * 100).rounded()))%")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
            .frame(width: 64, height: 64)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
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
    /// Wave 2 item 5 — move the live video into the floating PiP panel.
    var onPiP: () -> Void = {}
    @Environment(AppState.self) private var appState

    @State private var isControlsVisible = true
    @State private var hoverTimer: Timer?
    @State private var showSubtitlePopover = false
    @State private var showAudioPopover = false
    @State private var showOutputPopover = false
    @State private var dragProgress: Double?
    // Holds the clicked/dragged position after release until mpv's time-pos
    // telemetry actually lands there — without it the bar snaps back to the
    // OLD position for a split second after every seek.
    @State private var seekTarget: Double?
    @State private var isSharing = false
    @State private var showShareFeedback = false
    @State private var volumeHUDVisible = false
    @State private var volumeHUDTask: Task<Void, Never>?

    private let autoHideDelay: TimeInterval = 3.0

    var body: some View {
        ZStack {
            // Bottom interaction layer (flux pattern): click empty player area
            // toggles chrome; hover only restarts the idle timer while chrome
            // is up (it must NOT show chrome — enter-then-tap would show +
            // instantly hide, stranding it hidden). So: mouse moves = cursor
            // only (system unhides it), click = chrome. Lives INSIDE the
            // controls, so theater, fullscreen and direct behave identically.
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture {
                    if isControlsVisible {
                        hideControls()
                    } else {
                        showControls()
                    }
                }
                .onContinuousHover { phase in
                    if case .active = phase, isControlsVisible {
                        showControls()
                    }
                }

            if isControlsVisible || showExitWarning {
                VStack(spacing: 0) {
                    topBar

                    Spacer()

                    // Center transport — hidden until the first frame is live so it
                    // never overlaps the status spinner, and while buffering
                    // (spinner takes over). Opacity-only appearance (no slide):
                    // move transitions tear over live GL content.
                    if mpv.hasFirstFrame && !mpv.isBuffering {
                        transportArea
                            .transition(.opacity)
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

            // Volume HUD (flux pattern): the gauge flashes center-screen for
            // ~2 s whenever in-player volume changes (arrows, mute, gauge
            // drag). Display-only — taps pass through to the toggle catcher.
            if volumeHUDVisible {
                VolumeGauge(mpv: mpv, gaugeWidth: 140)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
                    .allowsHitTesting(false)
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
        // No .animation(value:) drivers here: show/hide already animate
        // explicitly, and value-drivers re-animate mid-transition (flicker
        // over live video). Transitions are opacity-only (flux pattern) —
        // move transitions tear over GL content.
        .onAppear { showControls() }
        .onDisappear {
            hoverTimer?.invalidate()
            volumeHUDTask?.cancel()
            volumeHUDVisible = false
            // Never leave a hidden cursor behind when the player goes away.
            NSCursor.unhide()
        }
        .onChange(of: mpv.playerVolume) {
            showVolumeHUD()
        }
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

            // Picture-in-Picture lives on the LEFT (flux arrangement) — float
            // the video in an always-on-top mini window. Meaningless inside
            // the fullscreen window (it owns the layer), so windowed only.
            if !isFullScreen {
                Button(action: onPiP) {
                    Image(systemName: "rectangle.bottomthird.inset.filled")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                        .glassEffect(.regular.interactive(), in: .circle)
                        .playerHoverTint()
                }
                .buttonStyle(.plain)
                .help(PictureInPictureWindow.shared.isActive ? "Exit Picture-in-Picture" : "Picture in Picture")
            }

            // The file name + size live ONLY above the progress bar (bottom bar)
            // — no duplicate title row up here.
            Spacer()

            // Volume pill — flux-style gauge (in-player volume 0–200%,
            // decoupled from the system device).
            VolumeGauge(mpv: mpv)
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

            // No close button in fullscreen — ESC exits (the X stays in the
            // windowed theater, which has a browser to return to).
            if !isFullScreen {
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

            // Previous / next TRACK arrows on the left/right edges (playlist
            // row navigation — not the ±10s transport above). Track switching
            // belongs to the ordinary viewer, so these show in the windowed
            // theater only, never in fullscreen (same rule as the image
            // viewer's removed chevrons). Each shows ONLY when a file exists
            // on that side of the row navigation.
            HStack {
                if !isFullScreen, canGoPrevious {
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

                if !isFullScreen, canGoNext {
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

                    // Output device picker (Wave 2 item 5): AirPlay speakers,
                    // headphones, HDMI, USB DACs — mpv switches its AO live.
                    Divider()
                        .frame(height: 20)
                        .background(Color.white.opacity(0.2))

                    Button {
                        if showOutputPopover == false { mpv.refreshAudioDevices() }
                        showOutputPopover.toggle()
                    } label: {
                        Image(systemName: "hifispeaker.2")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.9))
                    }
                    .frame(width: 44, height: 36)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    .popover(isPresented: $showOutputPopover, arrowEdge: .bottom) {
                        AudioOutputList(
                            devices: mpv.audioOutputDevices,
                            currentID: mpv.currentAudioDeviceID,
                            onSelect: { mpv.selectAudioDevice($0) }
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
                    // GeometryReader aligns children TOP-LEADING by default —
                    // without this frame the capsule rides above the time
                    // labels instead of sharing their axis.
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
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
        NSCursor.unhide()
        // NOTE: intentionally NOT animated — the 0.2 s fade made click-toggle
        // feel laggy (the toggle felt a beat behind the click). Instant.
        isControlsVisible = true
        hoverTimer = Timer.scheduledTimer(withTimeInterval: autoHideDelay, repeats: false) { _ in
            Task { @MainActor in
                self.isControlsVisible = false
                // Apple-TV style: the cursor goes with the chrome (any mouse
                // movement brings it back automatically).
                if NSApp.isActive {
                    NSCursor.setHiddenUntilMouseMoves(true)
                }
            }
        }
    }

    private func hideControls() {
        hoverTimer?.invalidate()
        isControlsVisible = false
        if NSApp.isActive {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    /// Flashes the volume HUD for ~2 s, re-armed by every change (flux
    /// `triggerVolumeHUD`). Instant on/off like the rest of the chrome.
    private func showVolumeHUD() {
        volumeHUDVisible = true
        volumeHUDTask?.cancel()
        volumeHUDTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            volumeHUDVisible = false
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
            try? await Task.sleep(nanoseconds: 12_000_000_000)
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
/// track, plain list rows, scrollable when many tracks exist. Subtitle lists
/// gain an "Off" row (mpv `sid=0`) so sidecar/embedded subs can be hidden.
private struct TrackSelectionList: View {
    let title: String
    let tracks: [Track]
    let onSelect: (Track) -> Void

    private var showsOffRow: Bool {
        tracks.contains { $0.type == "sub" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if showsOffRow {
                        Button {
                            onSelect(Track(id: 0, type: "sub", title: "Off", lang: "", isSelected: !tracks.contains { $0.isSelected }))
                        } label: {
                            HStack {
                                if !tracks.contains { $0.isSelected } {
                                    Image(systemName: "checkmark")
                                        .frame(width: 16)
                                } else {
                                    Spacer().frame(width: 16)
                                }
                                Text("Off")
                                Spacer()
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(!tracks.contains { $0.isSelected } ? Color.white.opacity(0.1) : Color.clear)
                        .cornerRadius(6)
                    }
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

/// Output device picker (Wave 2 item 5): lists mpv's audio endpoints —
/// built-in speakers, AirPlay speakers when connected, headphones, HDMI,
/// USB DACs. Checkmark marks the active one; selecting switches the AO live.
private struct AudioOutputList: View {
    let devices: [AudioDevice]
    let currentID: String?
    let onSelect: (AudioDevice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output Device")
                .font(.headline)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if devices.isEmpty {
                        Text("No output devices found")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                    }
                    ForEach(devices) { device in
                        let isSelected = device.id == currentID
                        Button {
                            onSelect(device)
                        } label: {
                            HStack {
                                Image(systemName: isSelected ? "checkmark" : "speaker.wave.1")
                                    .font(.system(size: 10, weight: .semibold))
                                    .frame(width: 16)
                                Text(device.label)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(isSelected ? Color.white.opacity(0.1) : Color.clear)
                        .cornerRadius(6)
                    }
                }
                .padding(8)
            }
        }
        .frame(minWidth: 240, maxHeight: 300)
        .padding(.bottom, 8)
    }
}