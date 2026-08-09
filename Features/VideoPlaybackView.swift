import SwiftUI
import AVKit
import AppKit

extension Notification.Name {
    static let toggleVideoPlayback = Notification.Name("xcloud_toggleVideoPlayback")
}

struct NativeAVPlayerView: NSViewRepresentable {
    let player: AVPlayer
    let showControls: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = showControls ? .floating : .none
        playerView.showsSharingServiceButton = false
        playerView.showsFullScreenToggleButton = false
        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
        let targetStyle: AVPlayerViewControlsStyle = showControls ? .floating : .none
        if nsView.controlsStyle != targetStyle {
            nsView.controlsStyle = targetStyle
        }
    }
}

struct VideoPlaybackView: View {
    let object: ObjectRecord
    let showControls: Bool
    @Bindable var audioEngine = AudioPlayerEngine.shared
    @State private var progress: Double = 0
    @State private var error: String?

    var body: some View {
        ZStack {
            if let player = audioEngine.player, audioEngine.currentTrack?.id == object.id {
                NativeAVPlayerView(player: player, showControls: showControls)
                    .onKeyPress(.space) {
                        audioEngine.togglePlayPause()
                        return .handled
                    }
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
        .task(id: object.id) {
            if audioEngine.currentTrack?.id != object.id {
                audioEngine.play(file: object)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleVideoPlayback)) { _ in
            audioEngine.togglePlayPause()
        }
    }
}
