#if os(iOS)
import SwiftUI

struct VideoPlaybackView: View {
    let file: FileItem
    @Environment(AppState.self) private var appState
    @State private var playerView: MPVPlayerView?
    @State private var isPlaying = true
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showControls = true
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0
    @State private var controlsTimer: Timer?
    @State private var pollTimer: Timer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let playerView {
                VideoPlayerContainer(playerView: playerView)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showControls.toggle()
                        }
                        if showControls {
                            resetControlsTimer()
                        }
                    }
            }

            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .tint(.white)
                    Text("Loading stream…")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                }
            }

            if let errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundStyle(.red)
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }

            // Controls Overlay
            if showControls && !isLoading && errorMessage == nil {
                controlsOverlay
                    .transition(.opacity)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(!showControls)
        .onAppear {
            let view = MPVPlayerView(frame: .zero)
            view.onEndReached = { appState.closeTheater() }
            self.playerView = view
            startPlayback()
            startPolling()
            resetControlsTimer()
        }
        .onDisappear {
            stopPolling()
            controlsTimer?.invalidate()
            playerView?.stop()
        }
    }

    private var controlsOverlay: some View {
        VStack {
            // Top Bar
            HStack {
                Button {
                    playerView?.stop()
                    appState.closeTheater()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }

                Spacer()

                Text(file.name)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)

                Spacer()

                Button {
                    playerView?.stop()
                    appState.closeTheater()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            Spacer()

            // Center Controls
            HStack(spacing: 48) {
                // Rewind 10s
                Button {
                    seekRelative(-10)
                    resetControlsTimer()
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(.white)
                }

                // Play / Pause
                Button {
                    togglePlayPause()
                    resetControlsTimer()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }

                // Forward 10s
                Button {
                    seekRelative(10)
                    resetControlsTimer()
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(.white)
                }
            }

            Spacer()

            // Bottom Timeline & Scrubber
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Text(formatTime(isScrubbing ? scrubTime : currentTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white)

                    Slider(
                        value: Binding(
                            get: { isScrubbing ? scrubTime : currentTime },
                            set: { newValue in
                                isScrubbing = true
                                scrubTime = newValue
                            }
                        ),
                        in: 0...max(1, duration),
                        onEditingChanged: { editing in
                            if !editing {
                                playerView?.seek(to: scrubTime)
                                currentTime = scrubTime
                                isScrubbing = false
                                resetControlsTimer()
                            }
                        }
                    )
                    .tint(.blue)

                    Text(formatTime(duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.75)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    private func togglePlayPause() {
        guard let pv = playerView else { return }
        if isPlaying {
            pv.pause()
            isPlaying = false
        } else {
            pv.resume()
            isPlaying = true
        }
    }

    private func seekRelative(_ delta: Double) {
        guard let pv = playerView else { return }
        let newTime = max(0, min(duration, currentTime + delta))
        pv.seek(to: newTime)
        currentTime = newTime
    }

    private func resetControlsTimer() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { _ in
            withAnimation(.easeInOut(duration: 0.25)) {
                if isPlaying && !isScrubbing {
                    showControls = false
                }
            }
        }
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            guard let pv = playerView else { return }
            if !isScrubbing {
                currentTime = pv.currentTime
            }
            if duration <= 0 || duration != pv.duration {
                let d = pv.duration
                if d > 0 { duration = d }
            }
            isPlaying = !pv.isPaused
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func formatTime(_ seconds: Double) -> String {
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

    private func startPlayback() {
        Task {
            await VaultStreamServer.shared.startServer()

            guard let object = try? await DatabaseManager.shared.object(file.id) else {
                await MainActor.run {
                    errorMessage = "File not found in database"
                    isLoading = false
                }
                return
            }

            guard let streamURL = await VideoStreamingEngine.shared.mpvStreamURL(for: object) else {
                await MainActor.run {
                    errorMessage = "Could not resolve stream URL"
                    isLoading = false
                }
                return
            }

            await MainActor.run {
                isLoading = false
                playerView?.play(streamURL)
            }
        }
    }
}

// MARK: - UIViewRepresentable Bridge

private struct VideoPlayerContainer: UIViewRepresentable {
    let playerView: MPVPlayerView

    func makeUIView(context: Context) -> MPVPlayerView { playerView }
    func updateUIView(_ uiView: MPVPlayerView, context: Context) {}
}
#endif
