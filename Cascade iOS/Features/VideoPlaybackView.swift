#if os(iOS)
import SwiftUI

struct VideoPlaybackView: View {
    let file: FileItem
    @Environment(AppState.self) private var appState
    @State private var playerView: MPVPlayerView?
    @State private var isPlaying = true
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let playerView {
                VideoPlayerContainer(playerView: playerView)
                    .ignoresSafeArea()
            }

            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .tint(.white)
                    Text("Loading…")
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
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    playerView?.stop()
                    appState.closeTheater()
                } label: {
                    Image(systemName: "chevron.left")
                        .foregroundStyle(.white)
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    Button {
                        isPlaying.toggle()
                        isPlaying ? playerView?.resume() : playerView?.pause()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .onAppear {
            let view = MPVPlayerView(frame: .zero)
            view.onEndReached = { appState.closeTheater() }
            self.playerView = view
            startPlayback()
        }
        .onDisappear {
            playerView?.stop()
        }
    }

    private func startPlayback() {
        Task {
            // Start the stream server if not already running
            await VaultStreamServer.shared.startServer()

            // Get the object from database
            guard let object = try? await DatabaseManager.shared.object(file.id) else {
                errorMessage = "File not found in database"
                isLoading = false
                return
            }

            // Resolve stream URL
            guard let streamURL = await VideoStreamingEngine.shared.mpvStreamURL(for: object) else {
                errorMessage = "Could not resolve stream URL"
                isLoading = false
                return
            }

            // Start playback
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
