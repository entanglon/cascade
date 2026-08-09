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
    @State private var progress: Double = 0
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
                    ProgressView(value: progress)
                        .progressViewStyle(.circular)
                        .controlSize(.large)
                    Text("Fetching video from Telegram… \(Int(progress * 100))%")
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
        if DownloadEngine.isCached(object) {
            let url = DownloadEngine.cacheURL(for: object)
            await MainActor.run {
                let p = AVPlayer(url: url)
                self.player = p
                p.play()
            }
            return
        }

        do {
            let url = try await DownloadEngine.download(object: object) { _, p in
                Task { @MainActor in
                    self.progress = p
                }
            }
            await MainActor.run {
                let p = AVPlayer(url: url)
                self.player = p
                p.play()
            }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
            }
        }
    }
}
