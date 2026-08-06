import SwiftUI
import AVKit

struct VideoPlaybackView: View {
    let object: ObjectRecord
    @State private var player: AVPlayer?
    @State private var progress: Double = 0
    @State private var error: String?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else if let error {
                VStack(spacing: 10) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.red.opacity(0.8))
                    Text(error).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
            } else {
                VStack(spacing: 14) {
                    ZStack {
                        Circle().stroke(.white.opacity(0.1), lineWidth: 4)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(XTheme.brandGradient, style: .init(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 72, height: 72)
                    Text("Buffering from Telegram…")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .task { await prepare() }
    }

    private func prepare() async {
        if DownloadEngine.isCached(object) {
            player = AVPlayer(url: DownloadEngine.cacheURL(for: object))
            player?.play()
            return
        }
        do {
            let url = try await DownloadEngine.download(object: object) { _, p in
                Task { @MainActor in progress = p }
            }
            player = AVPlayer(url: url)
            player?.play()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
