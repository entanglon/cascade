#if os(iOS)
import SwiftUI

struct VideoPlaybackView: View {
    let file: FileItem
    @Environment(AppState.self) private var appState
    @State private var playerView: MPVPlayerView?
    @State private var isPlaying = true
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let playerView {
                VideoPlayerContainer(playerView: playerView)
                    .ignoresSafeArea()
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

            if let vaultURL = file.vaultURL {
                view.play(vaultURL)
            }
        }
        .onDisappear {
            playerView?.stop()
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
