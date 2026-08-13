import Foundation
import SwiftUI
import AVFoundation
import AppKit
import Combine

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
        didSet {
            player?.volume = Float(volume)
            mpvController?.setVolume(volume)
        }
    }
    var playbackError: String?

    private(set) var player: AVPlayer?
    private(set) var mpvController: MPVController?
    private var mpvCancellables: Set<AnyCancellable> = []
    private var timeObserver: Any?

    /// True when the current track is playing through mpv (libmpv) instead of AVPlayer.
    var isMPVPlayback: Bool { mpvController != nil }

    private init() {}

    @MainActor
    func play(file: ObjectRecord, in trackList: [ObjectRecord] = []) {
        playbackError = nil

        // If already playing this exact track and player exists, don't restart it
        if currentTrack?.id == file.id {
            if let mpv = mpvController {
                mpv.play()
                isPlaying = true
                return
            }
            if let player {
                player.play()
                isPlaying = true
                return
            }
        }

        currentTrack = file
        if !trackList.isEmpty {
            playlist = trackList.filter {
                $0.mime.hasPrefix("audio/") ||
                $0.mime.hasPrefix("video/") ||
                ["mp3", "m4a", "wav", "flac", "aac", "ogg", "mp4", "mov", "mkv", "webm", "avi", "m4v"].contains(($0.name as NSString).pathExtension.lowercased())
            }
        }
        isLoading = true
        isPlaying = false
        currentTime = 0
        duration = 0

        Task {
            do {
                let ext = (file.name as NSString).pathExtension.lowercased()
                let isVideo = file.mime.hasPrefix("video/") || ["mp4", "mov", "m4v", "mkv", "webm", "avi"].contains(ext)

                // Uncached videos stream through mpv: mpv embeds FFmpeg's libavformat,
                // so it demuxes any container (mkv, webm, avi, ...) from the local
                // byte-range server. mpvStreamURL returns nil when the file is cached
                // or its layout can't be built, so playback degrades gracefully.
                if !DownloadEngine.isCached(file), isVideo,
                   let streamURL = await VideoStreamingEngine.shared.mpvStreamURL(for: file) {
                    await MainActor.run { setupMPVPlayer(with: streamURL) }
                    return
                }

                // AVFoundation byte-range streaming (MP4/MOV/M4V only) as a fallback.
                if !DownloadEngine.isCached(file), isVideo,
                   let item = await VideoStreamingEngine.shared.playerItem(for: file) {
                    await MainActor.run { setupPlayer(with: item) }
                    return
                }

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
                    playbackError = error.localizedDescription
                }
            }
        }
    }

    private func setupPlayer(with url: URL) {
        setupPlayer(with: AVPlayerItem(url: url))
    }

    private func setupPlayer(with item: AVPlayerItem) {
        removeTimeObserver()
        player?.pause()

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
            if let status = self.player?.timeControlStatus {
                self.isPlaying = (status == .playing || status == .waitingToPlayAtSpecifiedRate)
            }
            if self.currentTime >= self.duration - 0.5 && self.duration > 0 {
                self.skipNext()
            }
        }

        player?.play()
        isPlaying = true
        isLoading = false
    }

    /// Starts mpv playback of a VaultStreamServer URL. The MPVController is owned
    /// here so TheaterView/MiniPlayer keep reading this engine's state; the
    /// MPVVideoView attaches later and picks up the pending URL when its view loads.
    private func setupMPVPlayer(with url: URL) {
        stopMPVIfNeeded()
        let controller = MPVController()
        controller.onPlaybackError = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.playbackError = "Playback failed — the stream could not be loaded."
                self.stopMPVIfNeeded()
                self.isPlaying = false
                self.isLoading = false
            }
        }
        mpvController = controller
        mpvCancellables.removeAll()
        mpvCancellables.insert(controller.$isPlaying.receive(on: DispatchQueue.main).sink { [weak self] playing in
            self?.isPlaying = playing
        })
        mpvCancellables.insert(controller.$timePos.receive(on: DispatchQueue.main).sink { [weak self] t in
            self?.currentTime = t
        })
        mpvCancellables.insert(controller.$duration.receive(on: DispatchQueue.main).sink { [weak self] d in
            if d > 0 { self?.duration = d }
        })
        mpvCancellables.insert(controller.$volume.receive(on: DispatchQueue.main).sink { [weak self] v in
            guard let self else { return }
            if abs(self.volume - v) > 0.001 {
                self.volume = v
            }
        })
        isLoading = false
        controller.play(url: url)
    }

    private func stopMPVIfNeeded() {
        guard let mpv = mpvController else { return }
        mpv.stop()
        mpvCancellables.removeAll()
        mpvController = nil
    }

    func togglePlayPause() {
        if let mpv = mpvController {
            mpv.togglePlayPause()
            return
        }
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
        if let mpv = mpvController {
            mpv.seek(absolute: seconds)
            currentTime = seconds
            return
        }
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
        stopMPVIfNeeded()
        removeTimeObserver()
        player?.pause()
        player = nil
        currentTrack = nil
        isPlaying = false
        isLoading = false
        isFullScreen = false
        playbackError = nil
    }

    private func removeTimeObserver() {
        if let token = timeObserver {
            player?.removeTimeObserver(token)
            timeObserver = nil
        }
    }
}
