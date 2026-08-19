import Foundation
import SwiftUI
import AppKit
import Combine
import CoreAudio
import os

/// Single source of truth for the app's volume: the macOS SYSTEM output volume
/// — the same control the keyboard volume keys and the Control Center slider
/// touch. Every player slider reads and writes THIS, so dragging the slider
/// moves the system volume and pressing the keyboard keys moves the slider:
/// one volume, always in sync. mpv's own volume property stays at 100; the
/// device volume is the only attenuation.
@Observable
final class SystemVolumeManager {
    static let shared = SystemVolumeManager()

    /// The last value written to the device, so the device-change listener
    /// (which fires for our own writes too) never echoes a write back.
    private var lastWritten: Double = 1.0

    /// The output element whose volume scalar actually reads/writes on the
    /// CURRENT default output device. Bluetooth devices (earbuds, speakers)
    /// expose their volume on the stream elements (1, 2) while the master
    /// element (0) is unsupported — pinning `kAudioObjectPropertyElementMain`
    /// alone made every read/write fail silently on them (dead slider). The
    /// element is resolved by probing on start and whenever the default device
    /// changes; nil means no element works (nothing to control).
    private var volumeElement: AudioObjectPropertyElement?

    var volume: Double = 1.0 {
        didSet {
            let clamped = min(1.0, max(0.0, volume))
            guard abs(clamped - lastWritten) > 0.0001 else { return }
            lastWritten = clamped
            writeScalar(clamped)
        }
    }

    private var deviceListenerRegistered = false

    private init() {}

    /// Starts observing the default output device's volume. Safe to call
    /// repeatedly. Runs once at launch so keyboard/Control Center volume
    /// changes reach the sliders.
    func start() {
        guard !deviceListenerRegistered else { return }
        deviceListenerRegistered = true
        registerDeviceListener()
        resolveVolumeElement()
        let current = readScalar()
        volume = current
        lastWritten = current
    }

    // MARK: - Device plumbing

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    /// Finds the output element whose volume scalar can actually be READ on the
    /// current default device: Main (1) first — the stream element that works
    /// on Bluetooth — then Master (0, built-in/USB), then remaining stream
    /// elements. An element that can't even be read can't be written either.
    private func resolveVolumeElement() {
        guard let deviceID = defaultOutputDeviceID() else {
            volumeElement = nil
            return
        }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: 0
        )
        let candidates: [AudioObjectPropertyElement] = [
            kAudioObjectPropertyElementMain, // 1 — stream element (Bluetooth)
            0,                                // master — built-in/USB speakers
            2, 3, 4                            // further stream elements
        ]
        for element in candidates {
            addr.mElement = element
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value)
            if status == noErr, value.isFinite {
                volumeElement = element
                return
            }
        }
        volumeElement = nil
    }

    private func volumeScalarAddress() -> AudioObjectPropertyAddress? {
        guard let element = volumeElement else { return nil }
        return AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
    }

    private func readScalar() -> Double {
        guard let deviceID = defaultOutputDeviceID() else { return 1.0 }
        if volumeElement == nil { resolveVolumeElement() }
        guard var addr = volumeScalarAddress() else { return 1.0 }
        var value: Float32 = 1.0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value)
        guard status == noErr, value.isFinite else { return 1.0 }
        return Double(min(1.0, max(0.0, value)))
    }

    private func writeScalar(_ value: Double) {
        guard let deviceID = defaultOutputDeviceID() else { return }
        if volumeElement == nil { resolveVolumeElement() }
        guard var addr = volumeScalarAddress() else { return }
        var value = Float32(value)
        AudioObjectSetPropertyData(
            deviceID, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value
        )
    }

    private func registerDeviceListener() {
        // Volume changes from outside the app (keyboard keys, Control Center).
        guard let deviceID = defaultOutputDeviceID() else { return }

        var deviceAddr = volumeScalarAddress()
        guard var deviceAddr else { return }
        AudioObjectAddPropertyListenerBlock(deviceID, &deviceAddr, .main) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                let current = self.readScalar()
                if abs(current - self.lastWritten) > 0.0001 {
                    self.volume = current
                }
            }
        }

        // The default output device can change (headphones plugged in, etc.) —
        // re-resolve the volume element and re-attach the listener so the new
        // device's volume is the one tracked.
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddr, .main) { [weak self] _, _ in
            Task { @MainActor in
                self?.resolveVolumeElement()
                self?.registerDeviceListener()
            }
        }
    }
}

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
    var playbackError: String?

    /// Auto-advance to the next track when the current one ends naturally
    /// (EOF). One setting for audio AND video; off → playback stops at the
    /// end and Space/Play replays the track.
    var autoplayNextEnabled = UserDefaults.standard.object(forKey: "autoplayNextEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoplayNextEnabled, forKey: "autoplayNextEnabled") }
    }

    /// True after natural EOF when nothing advanced (autoplay off, last track,
    /// or empty playlist). The next toggle/play replays the finished track.
    private(set) var ended = false

    /// EOF dedupe: eof-reached and MPV_EVENT_END_FILE can both fire for one
    /// natural end — only the first signal per track acts (within 5s).
    private var lastEOFAt: Date?
    private var lastEOFTrackID: String?

    private static let playbackLogger = Logger(subsystem: "com.cascade.app", category: "playback")

    private(set) var mpvController: MPVController?
    private var mpvCancellables: Set<AnyCancellable> = []

    /// mpv is the only player in the app — there is no AVPlayer fallback anywhere.
    var isMPVPlayback: Bool { mpvController != nil }

    private init() {}

    @MainActor
    func play(file: ObjectRecord, in trackList: [ObjectRecord] = []) {
        playbackError = nil
        ended = false
        // The track we're leaving — its streaming state must be torn down (see
        // stopMPVIfNeeded) so the next play starts with a clean TDLib download
        // queue. Captured BEFORE currentTrack is overwritten below.
        let previousTrackID = currentTrack?.id
        // A seek requested while the previous player was still resolving (arrow
        // keys during the open window) applies to the file we're about to start.
        var resumePos: Double = 0
        if let pending = pendingVideoSeek {
            resumePos = pending
            pendingVideoSeek = nil
        }
        // If already playing this exact track in video mode, don't restart it. Also bail while a
        // setup is still resolving: re-entering play() mid-setup would call
        // setupMPVPlayer again, which stops the controller it just created and
        // replaces it — churning mpv (and the MPVVideoView) mid-playback.
        if currentTrack?.id == file.id, !ended {
            if isLoading { return }
            if let mpv = mpvController {
                if !mpv.isHeadless {
                    mpv.play()
                    isPlaying = true
                    return
                } else {
                    // Transitioning from headless background audio to full video player
                    resumePos = max(currentTime, mpv.timePos)
                }
            }
        }

        currentTrack = file
        if !trackList.isEmpty {
            playlist = filteredPlaylist(trackList)
        }
        isLoading = true
        isPlaying = false
        currentTime = resumePos
        duration = 0

        Task {
            do {
                // mpv is THE player — the ONLY player. It embeds FFmpeg's libavformat
                // (demuxes any container — mkv, webm, avi, ogg, flac, ...) and handles
                // HDR tone-mapping. Cached → local file URL; uncached → byte-range
                // stream from Telegram (VaultStreamServer). There is no AVFoundation
                // fallback anywhere: if mpv can't build a source, we download the file
                // and play it from disk.
                let url = try await resolvePlaybackURL(for: file)
                let isVideo = file.isVideo
                await MainActor.run { setupMPVPlayer(with: url, audioOnly: !isVideo, startPosition: resumePos, previousTrackID: previousTrackID) }
            } catch {
                await MainActor.run {
                    isLoading = false
                    isPlaying = false
                    playbackError = error.localizedDescription
                }
            }
        }
    }

    private func filteredPlaylist(_ trackList: [ObjectRecord]) -> [ObjectRecord] {
        trackList.filter { $0.isAudio || $0.isVideo }
    }

    /// Resolves the playable URL for `file`: cached → local file; uncached →
    /// byte-range stream from Telegram (VaultStreamServer); neither → download the
    /// file to disk. The single source of truth for play() and the background paths.
    private func resolvePlaybackURL(for file: ObjectRecord) async throws -> URL {
        let isMedia = file.isAudio || file.isVideo
        if isMedia {
            if DownloadEngine.isCached(file) {
                return DownloadEngine.cacheURL(for: file)
            }
            if let streamURL = await VideoStreamingEngine.shared.mpvStreamURL(for: file) {
                return streamURL
            }
        }
        if DownloadEngine.isCached(file) {
            return DownloadEngine.cacheURL(for: file)
        }
        return try await DownloadEngine.download(object: file, quiet: true) { _, _ in }
    }

    /// Starts mpv playback of a VaultStreamServer URL. The MPVController is owned
    /// here so TheaterView/MiniPlayer keep reading this engine's state; the
    /// MPVVideoView attaches later and picks up the pending URL when its view loads.
    /// For audio (`audioOnly`) the controller plays headless — mpv runs with no GL
    /// surface and the file loads immediately.
    private func setupMPVPlayer(with url: URL, audioOnly: Bool = false, startPosition: Double = 0, previousTrackID: String? = nil) {
        stopMPVIfNeeded(for: previousTrackID)
        let controller = MPVController()
        controller.onPlaybackError = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.playbackError = "Playback failed — the stream could not be loaded."
                // Stop mpv and clear the current track so the theater's error UI
                // replaces the player. The teardown (view dismantle → cleanup) is
                // serialized against in-flight renders by MPVLayerView's renderLock,
                // so this can no longer abort while a frame is being drawn.
                self.stopMPVIfNeeded()
                self.currentTrack = nil
                self.isPlaying = false
                self.isLoading = false
            }
        }
        controller.onEndOfFile = { [weak self] in
            // Natural end of track — advance the playlist when autoplay-next is
            // on (replaces the old AVPlayer periodic-time-observer auto-advance;
            // mpv reports EOF via eof-reached AND MPV_EVENT_END_FILE — deduped
            // per track, the first signal wins, the second within 5s is a
            // duplicate). If nothing advances (autoplay off / last track / no
            // playlist), mark the track ended so the next Space/Play replays it.
            Task { @MainActor in
                guard let self else { return }
                let now = Date()
                if self.currentTrack?.id == self.lastEOFTrackID,
                   let last = self.lastEOFAt, now.timeIntervalSince(last) < 5 {
                    return // duplicate EOF signal for the same track
                }
                self.lastEOFAt = now
                self.lastEOFTrackID = self.currentTrack?.id
                let beforeID = self.currentTrack?.id
                if self.autoplayNextEnabled {
                    self.skipNext()
                }
                if self.currentTrack?.id == beforeID, beforeID != nil {
                    self.ended = true
                }
                Self.playbackLogger.info("EOF track=\(beforeID ?? "nil", privacy: .public) autoplay=\(self.autoplayNextEnabled, privacy: .public) ended=\(self.ended, privacy: .public)")
            }
        }
        mpvController = controller
        // mpv's own volume stays at 100 — the app's volume IS the system
        // output volume (SystemVolumeManager), so there is exactly one control.
        controller.setVolume(1.0)
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
        isLoading = false
        if audioOnly {
            controller.playHeadless(url: url, startPosition: startPosition)
        } else {
            if startPosition > 0.5 {
                controller.seek(absolute: startPosition)
            }
            controller.play(url: url)
        }
    }

    private func stopMPVIfNeeded(for objectID: String? = nil) {
        guard let mpv = mpvController else { return }
        let stoppedObjectID = objectID ?? currentTrack?.id
        mpv.shutdown()
        mpvCancellables.removeAll()
        mpvController = nil
        if let stoppedObjectID {
            // Cancel any leftover TDLib chunk downloads from this playback so the
            // next play of the same file starts with a clean download queue
            // (stale full-chunk downloads were starving replays into buffering).
            VideoStreamingEngine.shared.invalidatePlayback(for: stoppedObjectID)
        }
    }

    func togglePlayPause() {
        if let mpv = mpvController {
            if ended {
                // Natural EOF with nothing to advance: the core keeps the file
                // loaded at the end (keep-open=yes), so replay synchronously
                // from 0 — no teardown, no async race, works for audio and
                // video alike.
                ended = false
                Self.playbackLogger.info("replay seek0+play track=\(self.currentTrack?.id ?? "nil", privacy: .public)")
                mpv.seek(absolute: 0)
                mpv.play()
            } else {
                mpv.togglePlayPause()
            }
        }
    }

    func seek(to seconds: Double) {
        if let mpv = mpvController {
            mpv.seek(absolute: seconds)
            currentTime = seconds
        }
    }

    /// A seek requested while the mpv core wasn't up yet — applied once the next
    /// file actually loads. Lets arrow/media-key seeks work even during the open
    /// window instead of being dropped.
    private var pendingVideoSeek: Double?

    /// Video-player transport seek (arrow keys / media keys): relative ±N seconds.
    /// If the mpv core isn't ready, the seek is remembered and applied on load —
    /// it NEVER falls back to switching to another file.
    func seekVideo(relative seconds: Double) {
        if let mpv = mpvController {
            if mpv.isCoreReady {
                mpv.seek(relative: seconds)
            } else {
                mpv.seekAfterLoad(max(0, currentTime + seconds))
            }
            return
        }
        pendingVideoSeek = max(0, currentTime + seconds)
    }

    func skipNext() {
        guard let currentTrack, !playlist.isEmpty else { return }
        if let idx = playlist.firstIndex(where: { $0.id == currentTrack.id }), idx + 1 < playlist.count {
            play(file: playlist[idx + 1], in: playlist)
        }
    }

    func skipPrevious() {
        guard let currentTrack, !playlist.isEmpty else { return }
        // Always the previous track — no "restart if >3s in" heuristic (the
        // transport buttons and the artist view treat Back as track
        // navigation). Only seek to 0 when already at the first track.
        if let idx = playlist.firstIndex(where: { $0.id == currentTrack.id }), idx > 0 {
            play(file: playlist[idx - 1], in: playlist)
        } else {
            seek(to: 0)
        }
    }

    func stop() {
        stopMPVIfNeeded(for: currentTrack?.id)
        currentTrack = nil
        isPlaying = false
        isLoading = false
        isFullScreen = false
        playbackError = nil
        ended = false
    }
}
