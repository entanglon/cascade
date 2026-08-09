import SwiftUI
import AVKit
import AppKit

struct NativeAVPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.showsSharingServiceButton = false
        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

struct VideoPlaybackView: View {
    let object: ObjectRecord
    @State private var player: AVPlayer?
    @State private var error: String?

    var body: some View {
        ZStack {
            if let player {
                NativeAVPlayerView(player: player)
            } else if let error {
                VStack(spacing: 10) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.red.opacity(0.8))
                    Text(error).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
            } else {
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Streaming from Telegram…")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .task { await prepare() }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private func prepare() async {
        let item = await VideoStreamingEngine.shared.playerItem(for: object)
        await MainActor.run {
            let p = AVPlayer(playerItem: item)
            self.player = p
            p.play()
        }
    }
}
