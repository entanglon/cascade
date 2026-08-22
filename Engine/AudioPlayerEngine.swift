import Foundation
import SwiftUI
import AppKit
import Combine
import CoreAudio
import MediaPlayer
import os

/// Single source of truth for the app's volume: the macOS SYSTEM output volume
/// — the same control the keyboard volume keys and the Control Center slider
/// touch. Every player slider reads and writes THIS, so dragging the slider
/// moves the system volume and pressing the keyboard keys moves the slider:
/// one volume, always in sync. mpv's own volume property stays at 100; the
/// device volume is the only attenuation.
///
/// Three-layer sync strategy (hybrid approach per Apple/CoreAudio best practices):
///  1. NSEvent global monitor  — catches F10/F11/mute keypresses with near-zero
///     latency, independent of CoreAudio listener reliability.
///  2. CoreAudio listeners    — catches Control Center slider drags and other-app
///     volume changes. Uses wildcard element + dedicated queue for reliability.
///  3. Polling timer (500 ms)  — safety net that catches anything the listeners
///     miss (Bluetooth HFP relay quirks, etc.).
@Observable
final class SystemVolumeManager {
    static let shared = SystemVolumeManager()

    /// The last value written to the device, so the device-change listener
    /// (which fires for our own writes too) never echoes a write back.
    private var lastWritten: Double = 1.0

    /// All elements that expose a writable kAudioDevicePropertyVolumeScalar
    /// on the CURRENT default output device. On A2DP Bluetooth devices (e.g.
    /// OnePlus Buds 3), VolumeScalar is per-channel: element 1 = left,
    /// element 2 = right. Writing to only one shifts stereo balance. On
    /// built-in speakers, typically [0] (master). Resolved on start and
    /// whenever the default device changes.
    private var volumeElements: [AudioObjectPropertyElement] = []

    /// The last known device ID, so we can detect device changes and re-probe.
    private var currentDeviceID: AudioDeviceID?

    /// Layer 1: NSEvent global monitor for media volume keys.
    private var mediaKeyMonitor: Any?

    /// Layer 2: CoreAudio listener reference for cleanup on device change.
    private var volumeListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceChangeListenerBlock: AudioObjectPropertyListenerBlock?

    /// Layer 3: DispatchSourceTimer polling as safety net.
    private var pollSource: DispatchSourceTimer?

    /// Dedicated serial queue for CoreAudio listener callbacks — avoids
    /// main-thread starvation during SwiftUI re-renders / modal tracking.
    private let audioQueue = DispatchQueue(label: "com.cascade.app.volume-listener", qos: .userInteractive)

    /// Set while the user drags the volume slider so poll/listener updates
    /// don't fight the gesture with stale mid-drag reads.
    var isUserDragging = false

    var volume: Double = 1.0 {
        didSet {
            let clamped = min(1.0, max(0.0, volume))
            guard abs(clamped - lastWritten) > 0.0001 else { return }
            lastWritten = clamped
            writeScalar(clamped)
        }
    }

    private var started = false

    private init() {}

    deinit {
        if let m = mediaKeyMonitor { NSEvent.removeMonitor(m) }
        pollSource?.cancel()
    }

    /// Starts observing the default output device's volume. Safe to call
    /// repeatedly (idempotent). Runs once at launch so keyboard/Control
    /// Center volume changes reach the sliders.
    func start() {
        guard !started else { return }
        started = true
        resolveVolumeElements()
        let current = readScalar()
        volume = current
        lastWritten = current
        registerDeviceListener()   // Layer 2
        installMediaKeyMonitor()   // Layer 1
        startPolling()             // Layer 3
    }

    // MARK: — Layer 1: NSEvent Global Monitor (F10/F11/Mute)

    /// Intercepts media-key system-defined events globally. On F10/F11/Mute
    /// key-down, schedules a delayed volume re-read so the slider tracks the
    /// change with near-zero latency — no dependence on CoreAudio listeners.
    private func installMediaKeyMonitor() {
        let mask = CGEventMask(1 << NX_SYSDEFINED)
        mediaKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard event.subtype.rawValue == 8 else { return }
            let data1 = event.data1
            let keyCode = Int((data1 & 0xFFFF0000) >> 16)
            let keyState = (data1 >> 8) & 0xFF  // 0xA = key-down
            guard keyState == 0xA else { return }
            // NX_KEYTYPE_SOUND_UP = 0, NX_KEYTYPE_SOUND_DOWN = 1, NX_KEYTYPE_MUTE = 7
            guard keyCode == 0 || keyCode == 1 || keyCode == 7 else { return }
            // 50 ms delay lets coreaudiod finish adjusting before we read.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self?.pollVolume()
            }
        }
    }

    // MARK: — Layer 2: CoreAudio Listeners

    /// Registers volume-change + mute-change listeners on the current default
    /// output device. Uses `kAudioObjectPropertyElementWildcard` so the
    /// callback fires regardless of which element the HAL plugin updates.
    /// Re-attaches automatically when the default device changes (e.g.
    /// Bluetooth connect / disconnect).
    private func registerDeviceListener() {
        guard let deviceID = defaultOutputDeviceID() else { return }

        // --- Volume scalar listener (wildcard element) ---
        let volBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.pollVolume()
        }
        volumeListenerBlock = volBlock
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementWildcard
        )
        AudioObjectAddPropertyListenerBlock(deviceID, &volAddr, audioQueue, volBlock)

        // --- Mute listener (wildcard element) ---
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementWildcard
        )
        AudioObjectAddPropertyListenerBlock(deviceID, &muteAddr, audioQueue) { [weak self] _, _ in
            self?.pollVolume()
        }

        // --- Default-output-device-change listener ---
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.resolveVolumeElements()
                // Re-register volume listeners on the new device.
                self.removeDeviceListeners()
                self.registerDeviceListener()
            }
        }
        deviceChangeListenerBlock = defaultBlock
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddr, audioQueue, defaultBlock
        )
    }

    private func removeDeviceListeners() {
        guard let deviceID = defaultOutputDeviceID() else { return }
        if let block = volumeListenerBlock {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementWildcard
            )
            AudioObjectRemovePropertyListenerBlock(deviceID, &addr, audioQueue, block)
            volumeListenerBlock = nil
        }
        if let block = deviceChangeListenerBlock {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, audioQueue, block
            )
            deviceChangeListenerBlock = nil
        }
    }

    // MARK: — Layer 3: Polling Timer (safety net)

    /// 500 ms DispatchSourceTimer on a background queue. Catches anything the
    /// listeners miss (Bluetooth HFP quirks, Control Center via other apps,
    /// etc.). Uses DispatchSourceTimer (not RunLoop Timer) so it keeps firing
    /// during modal tracking loops (menu open, window drag, slider drag).
    private func startPolling() {
        pollSource?.cancel()
        let source = DispatchSource.makeTimerSource(queue: audioQueue)
        source.schedule(deadline: .now() + 0.5, repeating: 0.5)
        source.setEventHandler { [weak self] in
            self?.reprobeIfDeviceChanged()
            self?.pollVolume()
        }
        source.resume()
        pollSource = source
    }

    /// Reads the current system volume and publishes it if it changed. Shared
    /// entry point for all three layers — the `isUserDragging` and
    /// `lastWritten` guards prevent feedback loops and redundant updates.
    private func pollVolume() {
        guard !isUserDragging else { return }
        let current = readScalar()
        guard abs(current - lastWritten) > 0.005 else { return }
        DispatchQueue.main.async { [weak self] in
            self?.volume = current
        }
    }

    /// Checks whether the default output device changed (e.g. Bluetooth
    /// connected/disconnected) and re-resolves the volume element if so.
    private func reprobeIfDeviceChanged() {
        guard let newID = defaultOutputDeviceID() else { return }
        if newID != currentDeviceID {
            currentDeviceID = newID
            resolveVolumeElements()
        }
    }

    // MARK: — Core Audio plumbing

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

    /// Probes the current default output device and finds ALL elements that
    /// expose a writable kAudioDevicePropertyVolumeScalar. On A2DP Bluetooth
    /// devices, VolumeScalar is per-channel (element 1 = L, element 2 = R);
    /// writing to only one shifts stereo balance. On built-in/USB speakers,
    /// typically only element 0 (master) exists.
    private func resolveVolumeElements() {
        guard let deviceID = defaultOutputDeviceID() else {
            volumeElements = []
            return
        }
        var found: [AudioObjectPropertyElement] = []
        for element: AudioObjectPropertyElement in [0, 1, 2, 3, 4] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &addr) else { continue }
            var settable: DarwinBoolean = false
            AudioObjectIsPropertySettable(deviceID, &addr, &settable)
            guard settable.boolValue else { continue }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value)
            guard status == noErr, value.isFinite else { continue }
            found.append(element)
        }
        volumeElements = found
    }

    private func readScalar() -> Double {
        guard let deviceID = defaultOutputDeviceID() else { return 1.0 }
        if volumeElements.isEmpty { resolveVolumeElements() }
        guard let element = volumeElements.first else { return 1.0 }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
        var value: Float32 = 1.0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value)
        guard status == noErr, value.isFinite else { return 1.0 }
        return Double(min(1.0, max(0.0, value)))
    }

    /// Writes the same volume scalar to ALL resolved elements simultaneously.
    /// On A2DP Bluetooth (per-channel VolumeScalar), this moves both left and
    /// right channels together — preventing the stereo balance shift.
    private func writeScalar(_ value: Double) {
        guard let deviceID = defaultOutputDeviceID() else { return }
        if volumeElements.isEmpty { resolveVolumeElements() }
        guard !volumeElements.isEmpty else { return }
        let clamped = min(1.0, max(0.0, value))
        for element in volumeElements {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )
            var writeVal = Float32(clamped)
            AudioObjectSetPropertyData(
                deviceID, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &writeVal
            )
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

    private init() {
        setupRemoteCommands()
    }

    // MARK: - Now-playing claim (media keys & Control Center)

    /// One physical media-key press is delivered BOTH as an NX systemDefined
    /// event to the frontmost app (local monitor) AND as an MPRemoteCommandCenter
    /// callback (because this app claims now-playing). The gate lets exactly one
    /// path act per press — whichever arrives first wins, the duplicate is dropped.
    private static let mediaKeyGateLock = NSLock()
    private static var lastMediaKeyConsumedAt: CFTimeInterval = 0
    static func consumeMediaKeyPress(at time: CFTimeInterval = CFAbsoluteTimeGetCurrent()) -> Bool {
        mediaKeyGateLock.lock()
        defer { mediaKeyGateLock.unlock() }
        guard time - lastMediaKeyConsumedAt > 0.3 else { return false }
        lastMediaKeyConsumedAt = time
        return true
    }

    /// Registers with MediaRemote so the media keys (F7/F8/F9, headset buttons,
    /// Control Center) control THIS app — not Apple Music — whenever a track is
    /// loaded, even while another app is frontmost. The handlers dedupe against
    /// the local NX monitors via consumeMediaKeyPress. The commands start
    /// disabled and are enabled in play() — while disabled the system keeps
    /// routing media keys to Music.
    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        let toggle = center.togglePlayPauseCommand
        toggle.isEnabled = false
        toggle.addTarget { [weak self] _ in
            guard Self.consumeMediaKeyPress() else { return .commandFailed }
            DispatchQueue.main.async { self?.togglePlayPause() }
            return .success
        }
        let next = center.nextTrackCommand
        next.isEnabled = false
        next.addTarget { [weak self] _ in
            guard Self.consumeMediaKeyPress() else { return .commandFailed }
            DispatchQueue.main.async { self?.skipNext() }
            return .success
        }
        let prev = center.previousTrackCommand
        prev.isEnabled = false
        prev.addTarget { [weak self] _ in
            guard Self.consumeMediaKeyPress() else { return .commandFailed }
            DispatchQueue.main.async { self?.skipPrevious() }
            return .success
        }
    }

    private func setRemoteCommandsEnabled(_ enabled: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.isEnabled = enabled
        center.nextTrackCommand.isEnabled = enabled
        center.previousTrackCommand.isEnabled = enabled
    }

    /// Last elapsed time pushed to the system (throttles per-second updates).
    private var lastElapsedReported: Double = -1

    /// Reflects the current track in the system now-playing state. Empty while
    /// nothing is loaded — releases the claim so Music gets its keys back.
    private func updateNowPlayingInfo() {
        guard let track = currentTrack, mpvController != nil else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            if #available(macOS 13.0, *) {
                MPNowPlayingInfoCenter.default().playbackState = .stopped
            }
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.name,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
        ]
        if let idx = playlist.firstIndex(where: { $0.id == track.id }) {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = idx
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = playlist.count
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        if #available(macOS 13.0, *) {
            MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        }
    }

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
        setRemoteCommandsEnabled(true)
        updateNowPlayingInfo()

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

    /// Resolves the playable URL for `file`: media streams via the byte-range
    /// server (VaultStreamServer) — since the single-cache architecture (item 159)
    /// there is no app-side playback cache; TDLib's store feeds replays locally.
    /// Non-media (rare) materializes to scratch. The single source of truth for
    /// play() and the background paths.
    private func resolvePlaybackURL(for file: ObjectRecord) async throws -> URL {
        let isMedia = file.isAudio || file.isVideo
        if isMedia, let streamURL = await VideoStreamingEngine.shared.mpvStreamURL(for: file) {
            return streamURL
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
                self.setRemoteCommandsEnabled(false)
                self.updateNowPlayingInfo()
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
            self?.updateNowPlayingInfo()
        })
        mpvCancellables.insert(controller.$timePos.receive(on: DispatchQueue.main).sink { [weak self] t in
            guard let self else { return }
            self.currentTime = t
            if abs(t - self.lastElapsedReported) >= 1.0 {
                self.lastElapsedReported = t
                self.updateNowPlayingInfo()
            }
        })
        mpvCancellables.insert(controller.$duration.receive(on: DispatchQueue.main).sink { [weak self] d in
            if d > 0 {
                self?.duration = d
                self?.updateNowPlayingInfo()
            }
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
        setRemoteCommandsEnabled(false)
        updateNowPlayingInfo()
    }
}
