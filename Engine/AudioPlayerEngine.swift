import Foundation
import SwiftUI
import AVFoundation
import AppKit

@Observable
final class AudioPlayerEngine {
    static let shared = AudioPlayerEngine()

    var currentTrack: ObjectRecord?
    var playlist: [ObjectRecord] = []
    var isPlaying = false
    var isLoading = false
    var currentTime: Double = 0
    var duration: Double = 0
    var isFullScreen = false
    var volume: Double = 1.0 {
        didSet { player?.volume = Float(volume) }
    }

    private var player: AVPlayer?
    private var timeObserver: Any?

    private init() {}

    @MainActor
    func play(file: ObjectRecord, in trackList: [ObjectRecord] = []) {
        currentTrack = file
        if !trackList.isEmpty {
            playlist = trackList.filter { $0.mime.hasPrefix("audio/") || ["mp3", "m4a", "wav", "flac", "aac", "ogg"].contains(($0.name as NSString).pathExtension.lowercased()) }
        }
        isLoading = true
        isPlaying = false
        currentTime = 0
        duration = 0

        Task {
            do {
                let url: URL
                if DownloadEngine.isCached(file) {
                    url = DownloadEngine.cacheURL(for: file)
                } else {
                    url = try await DownloadEngine.download(object: file) { _, _ in }
                }

                await MainActor.run {
                    setupPlayer(with: url)
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    isPlaying = false
                }
            }
        }
    }

    private func setupPlayer(with url: URL) {
        removeTimeObserver()
        player?.pause()

        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player?.volume = Float(volume)

        let d = CMTimeGetSeconds(item.asset.duration)
        if !d.isNaN && d > 0 {
            duration = d
        } else {
            duration = 180 // fallback estimate
        }

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds
            if let dur = self.player?.currentItem?.duration.seconds, !dur.isNaN, dur > 0 {
                self.duration = dur
            }
            if self.currentTime >= self.duration - 0.5 && self.duration > 0 {
                self.skipNext()
            }
        }

        player?.play()
        isPlaying = true
        isLoading = false
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time)
        currentTime = seconds
    }

    func skipNext() {
        guard let currentTrack, !playlist.isEmpty else { return }
        if let idx = playlist.firstIndex(where: { $0.id == currentTrack.id }), idx + 1 < playlist.count {
            play(file: playlist[idx + 1], in: playlist)
        }
    }

    func skipPrevious() {
        guard let currentTrack, !playlist.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        if let idx = playlist.firstIndex(where: { $0.id == currentTrack.id }), idx > 0 {
            play(file: playlist[idx - 1], in: playlist)
        } else {
            seek(to: 0)
        }
    }

    func stop() {
        removeTimeObserver()
        player?.pause()
        player = nil
        currentTrack = nil
        isPlaying = false
        isLoading = false
        isFullScreen = false
    }

    private func removeTimeObserver() {
        if let token = timeObserver {
            player?.removeTimeObserver(token)
            timeObserver = nil
        }
    }
}
