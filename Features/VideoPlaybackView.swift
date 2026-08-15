import SwiftUI
import AppKit

extension Notification.Name {
    static let toggleVideoPlayback = Notification.Name("xcloud_toggleVideoPlayback")
}

struct VideoPlaybackView: View {
    let object: ObjectRecord
    var showExitWarning = false
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
                                showExitWarning: showExitWarning,
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
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.large)
            .tint(.white.opacity(0.7))
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

    @State private var isControlsVisible = true
    @State private var hoverTimer: Timer?
    @State private var showSubtitlePopover = false
    @State private var showAudioPopover = false
    @State private var dragProgress: Double?

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
                        centerControls
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
            Button(action: onMinimize) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .help(isFullScreen ? "Exit Full Screen" : "Close Player")

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.leading, 4)

            Spacer()

            // Volume pill — the app's volume IS the system output volume
            // (SystemVolumeManager), so keyboard keys and this slider are
            // the same control.
            HStack(spacing: 10) {
                Image(systemName: SystemVolumeManager.shared.volume > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.8))

                Slider(
                    value: Binding(
                        get: { SystemVolumeManager.shared.volume },
                        set: { SystemVolumeManager.shared.volume = $0 }
                    ),
                    in: 0...1
                )
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
            }
            .buttonStyle(.plain)
            .help("Close Player")
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .background(
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }

    // MARK: - Center Transport

    private var centerControls: some View {
        HStack(spacing: 80) {
            Button {
                mpv.seek(relative: -10)
            } label: {
                Image(systemName: "gobackward.10")
                    .font(.system(size: 28))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(24)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)

            Button {
                mpv.togglePlayPause()
            } label: {
                Image(systemName: mpv.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundColor(.white)
                    .padding(36)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)

            Button {
                mpv.seek(relative: 10)
            } label: {
                Image(systemName: "goforward.10")
                    .font(.system(size: 28))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(24)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
        }
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
                        .shadow(radius: 4)
                }

                Spacer()

                // Subtitles & Audio Pills
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
            }

            // Progress Bar Row (Full Width)
            HStack(spacing: 20) {
                Text(formatTime(displayedTime))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .shadow(radius: 2)

                // Custom Slider
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
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let newProgress = min(max(value.location.x / geo.size.width, 0), 1)
                                dragProgress = newProgress
                                mpv.seek(to: newProgress)
                            }
                            .onEnded { _ in
                                dragProgress = nil
                            }
                    )
                }
                .frame(height: 18)

                Text("-\(formatTime(max(0, mpv.duration - displayedTime)))")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .shadow(radius: 2)
            }
        }
        .padding(.horizontal, 60)
        .padding(.bottom, 40)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }

    // MARK: - Helpers

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
        dragProgress ?? mpv.progress
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