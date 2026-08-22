import SwiftUI
import AppKit
import OpenGL.GL
import MPVKit
import Combine
import Darwin
import ScreenCaptureKit
import os

// MARK: - SwiftUI View

/// mpv (libmpv) player view. mpv embeds FFmpeg's libavformat, so it demuxes any
/// container — mkv, webm, avi, ts, ... — and plays byte-range HTTP streams (the
/// local VaultStreamServer) with full seeking. Ported from the flux app.
struct MPVVideoView: NSViewControllerRepresentable {
    @ObservedObject var controller: MPVController

    func makeNSViewController(context: Context) -> MPVViewController {
        let mpv = MPVViewController()
        context.coordinator.player = mpv
        controller.playerView = mpv // Link controller to view
        mpv.delegate = controller // Link view to controller
        return mpv
    }

    func updateNSViewController(_ nsViewController: MPVViewController, context: Context) {
        // Re-assert the fill after SwiftUI re-layouts the theater — but ONLY
        // while the player is actually hosted here. While the fullscreen
        // window is active the layer is re-parented into it; touching its
        // frame here would shrink/shift the video inside the fullscreen
        // player (every PlayerControlsView re-render triggers this update).
        if nsViewController.playerView.superview === nsViewController.view {
            nsViewController.playerView.frame = nsViewController.view.bounds
        }
    }

    static func dismantleNSViewController(_ nsViewController: MPVViewController, coordinator: Coordinator) {
        nsViewController.playerView.cleanup()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject {
        var parent: MPVVideoView
        weak var player: MPVViewController?

        init(_ parent: MPVVideoView) {
            self.parent = parent
        }
    }
}

// MARK: - Models

struct Track: Identifiable, Equatable {
    let id: Int
    let type: String // "audio", "sub"
    let title: String
    let lang: String
    var isSelected: Bool

    var displayName: String {
        let rawTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let isUnknownTitle = rawTitle.isEmpty || rawTitle.lowercased() == "unknown" || rawTitle.lowercased().starts(with: "track")

        var languageName = ""
        if !lang.isEmpty && lang.lowercased() != "und" {
            let locale = Locale(identifier: "en")
            if let localized = locale.localizedString(forLanguageCode: lang), !localized.isEmpty {
                languageName = localized.capitalized
            } else {
                switch lang.lowercased() {
                case "eng", "en": languageName = "English"
                case "hin", "hi": languageName = "Hindi"
                case "spa", "es": languageName = "Spanish"
                case "fre", "fra", "fr": languageName = "French"
                case "ger", "deu", "de": languageName = "German"
                case "jpn", "ja": languageName = "Japanese"
                case "kor", "ko": languageName = "Korean"
                case "rus", "ru": languageName = "Russian"
                case "ita", "it": languageName = "Italian"
                case "por", "pt": languageName = "Portuguese"
                case "tam", "ta": languageName = "Tamil"
                case "tel", "te": languageName = "Telugu"
                case "kan", "kn": languageName = "Kannada"
                case "mal", "ml": languageName = "Malayalam"
                case "ara", "ar": languageName = "Arabic"
                default: languageName = lang.uppercased()
                }
            }
        }

        if !isUnknownTitle {
            if !languageName.isEmpty && !rawTitle.lowercased().contains(languageName.lowercased()) {
                return "\(languageName) - \(rawTitle)"
            }
            return rawTitle
        }

        if !languageName.isEmpty {
            return "\(languageName) (\(type == "audio" ? "Audio" : "Subtitles"))"
        }

        return "\(type == "audio" ? "Audio Track" : "Subtitle Track") \(id)"
    }
}

// MARK: - Controller

class MPVController: ObservableObject {
    @Published var isPlaying = false
    @Published var progress: Double = 0.0
    @Published var duration: Double = 0.0
    @Published var timePos: Double = 0.0
    @Published var volume: Double = 1.0
    @Published var bufferProgress: Double = 0.0

    /// Set while a user-initiated seek is in flight. mpv's async seek keeps
    /// reporting the OLD (or transiently zeroed) position until data arrives at
    /// the target — accepting those updates made the scrubber "dance": target →
    /// back → target. While pending, time-pos updates are ignored until one lands
    /// within ~1 s of the target (or a safety timeout releases the hold).
    var pendingSeekTarget: Double?
    var pendingSeekAt = Date.distantPast

    @Published var isBuffering = false
    @Published var isSeeking = false
    @Published var isUserPaused = false

    /// True once the mpv core (view-bound or headless) finished initializing and
    /// the initial load was issued. Until it flips, the theater shows the
    /// "Preparing player…" overlay instead of a black void.
    @Published var isCoreReady = false

    /// True after the first video frame was actually rendered by the GL layer —
    /// the signal that playback is visually live (the "Loading…" overlay lifts).
    @Published var hasFirstFrame = false

    @Published var audioTracks: [Track] = []
    @Published var subtitleTracks: [Track] = []

    var onPlaybackError: (() -> Void)?

    /// Fired when the current file ends naturally (EOF) — the playlist's auto-
    /// advance (replaces the old AVPlayer time-observer behavior; mpv reports
    /// MPV_EVENT_END_FILE with reason EOF).
    var onEndOfFile: (() -> Void)?
    weak var playerView: MPVViewController?

    /// Set when play(url:) is called before the MPVViewController exists (the engine
    /// creates the controller first; the view attaches later). Cleared once played.
    private(set) var pendingURL: URL?

    /// True when this controller plays audio headless — no MPVVideoView is ever
    /// attached, so mpv runs without a GL render surface (vo=null).
    private(set) var isHeadless = false
    private var headlessView: MPVLayerView?

    /// The file this controller is (or was last) playing — lets a freshly
    /// attached view resume headless playback without re-resolving the source.
    private(set) var lastURL: URL?

    /// The view calls this when it attaches while this controller is playing
    /// headless (a video minimized to the mini player, then expanded back into
    /// the theater). Captures the exact position, tears down the headless core,
    /// and returns the URL + position so the fresh view-side core resumes
    /// seamlessly instead of restarting from zero.
    func takeHeadlessHandoff() -> (url: URL, position: Double)? {
        guard isHeadless, let lastURL else { return nil }
        let position = timePos
        stopHeadless()
        isHeadless = false
        isUserPaused = false
        return (url: lastURL, position: position)
    }

    /// Starts headless (view-less) playback for audio-only streams: mpv is fully
    /// initialized without any GL surface, the file loads immediately, and the event
    /// loop publishes state exactly like the video path. Tear down via `shutdown()`.
    func playHeadless(url: URL, startPosition: Double = 0) {
        isHeadless = true
        isUserPaused = false
        lastURL = url
        let view = MPVLayerView(frame: .zero)
        headlessView = view
        view.onPropertyChange = { [weak self] name, value in
            self?.handlePropertyChange(name: name, value: value)
        }
        view.onPlaybackError = { [weak self] in
            DispatchQueue.main.async { self?.onPlaybackError?() }
        }
        view.onEndOfFile = { [weak self] in
            DispatchQueue.main.async { self?.onEndOfFile?() }
        }
        view.onCoreReady = { [weak self] in
            DispatchQueue.main.async { self?.coreReady() }
        }
        view.setupMpv()
        // No render surface exists, so route any video output (e.g. an embedded
        // cover-art frame) to null — it can never stall the VO — then load now.
        view.setVideoOutput(false)
        view.setVolume(volume)
        view.playHeadless(url, startPosition: startPosition)
    }

    /// Marks the mpv core as ready (fired from the view's onCoreReady, main thread).
    func coreReady() {
        self.isCoreReady = true
    }

    /// Marks the first rendered frame (fired from the GL layer, main thread).
    func firstFrameRendered() {
        self.hasFirstFrame = true
    }

    func stopHeadless() {
        guard isHeadless else { return }
        headlessView?.stop()
        headlessView?.cleanup()
        headlessView = nil
        isHeadless = false
    }

    /// Stops playback and releases the mpv core for either mode (viewed or headless).
    func shutdown() {
        if isHeadless {
            stopHeadless()
        } else {
            playerView?.stop()
        }
    }

    func play(url: URL) {
        self.isUserPaused = false
        lastURL = url
        // A new file invalidates any in-flight seek hold from the previous one,
        // and playback intent begins the cold-start loading state.
        pendingSeekTarget = nil
        waitingFirstFrame = true
        refreshBuffering()
        if isHeadless {
            headlessView?.playHeadless(url)
            return
        }
        if let playerView {
            pendingURL = nil
            playerView.play(url)
        } else {
            pendingURL = url
        }
    }

    func clearPending() {
        pendingURL = nil
    }

    func play() {
        self.isUserPaused = false
        if isHeadless {
            headlessView?.setPause(false)
        } else {
            playerView?.resume()
        }
    }

    func pause() {
        self.isUserPaused = true
        if isHeadless {
            headlessView?.setPause(true)
        } else {
            playerView?.pause()
        }
    }

    func stop() {
        self.isUserPaused = false
        if isHeadless {
            headlessView?.stop()
        } else {
            playerView?.stop()
        }
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func seek(to value: Double) {
        // Delegate so progress, timePos AND the pending-seek hold stay in sync.
        seek(absolute: value * max(duration, 0))
    }

    func seek(absolute time: Double) {
        if duration > 0 { self.progress = time / duration }
        // Keep the TIME LABEL in sync with the scrubber while the seek lands,
        // not just the bar position.
        self.timePos = time
        beginPendingSeek(time)
        if isHeadless {
            headlessView?.seek(absoluteSeconds: time)
        } else {
            playerView?.seek(absolute: time)
        }
    }

    private func beginPendingSeek(_ targetTime: Double) {
        pendingSeekTarget = targetTime
        pendingSeekAt = Date()
        refreshBuffering()
    }

    // Buffering = cache underrun OR first frame not flowing yet OR seek data
    // fetch in flight. paused-for-cache alone never fires during cold start or
    // seek waits — leaving those stretches without any loading indication.
    private var cachePaused = false
    private var waitingFirstFrame = false

    private func refreshBuffering() {
        isBuffering = cachePaused || waitingFirstFrame || (pendingSeekTarget != nil)
    }

    func seek(relative seconds: Double) {
        if isHeadless {
            headlessView?.seek(relativeSeconds: seconds)
        } else {
            playerView?.seek(relative: seconds)
        }
    }

    /// Queues a seek to apply once the next file finishes loading — mpv drops
    /// seeks issued before a file is loaded, so a seek requested during the
    /// loading window must ride the MPV_EVENT_FILE_LOADED hook.
    func seekAfterLoad(_ seconds: Double) {
        if isHeadless {
            headlessView?.seekAfterLoad(seconds)
        } else {
            playerView?.seekAfterLoad(seconds)
        }
    }

    private var volumeSyncTask: Task<Void, Never>?

    func setVolume(_ value: Double) {
        // Publish the value immediately (slider responsiveness + engine sink),
        // but COALESCE the actual mpv property write. A drag used to hammer the
        // core with 100+ volume changes/sec — one from the slider tick plus one
        // from the engine's feedback round-trip each — and mpv re-applies its
        // gain filter on every write, which makes the audio crackle/break.
        // One write per ~60 ms is plenty for a smooth fade.
        volume = value
        volumeSyncTask?.cancel()
        let target = value
        volumeSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if self.isHeadless {
                self.headlessView?.setVolume(target)
            } else {
                self.playerView?.setVolume(target)
            }
        }
    }

    /// Warms the mpv runtime at app launch: loads the MPVKit dylib, registers
    /// FFmpeg's codec tables, and runs a full core init — the one-time cold
    /// costs behind "the first file after restart lags, every later one is
    /// instant". Creates a throwaway headless core, waits for init to finish
    /// (4 s timeout so a failed init can't hang), then tears it down.
    static func warmUp() async {
        let view = MPVLayerView(frame: .zero)
        let ready = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    view.onCoreReady = { continuation.resume() }
                    view.setupMpv()
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        view.cleanup()
        print("[MPV] warm-up core \(ready ? "ready" : "timed out")")
    }

    deinit {
        if isHeadless {
            headlessView?.cleanup()
        }
    }

    func handlePropertyChange(name: String, value: Any) {
        DispatchQueue.main.async {
            switch name {
            case "time-pos":
                if let time = value as? Double {
                    // Seek-suppression: while a user seek is in flight, mpv keeps
                    // reporting the old (or transiently zero) position. Hold the
                    // scrubber at the target until an update lands within ~1 s of
                    // it — that's the seek completing.
                    if let target = self.pendingSeekTarget {
                        let settled = abs(time - target) < 1.0
                        let timedOut = Date().timeIntervalSince(self.pendingSeekAt) > 12
                        guard settled || timedOut else { return }
                        self.pendingSeekTarget = nil
                    }
                    self.waitingFirstFrame = false
                    self.refreshBuffering()
                    self.timePos = time
                    if self.duration > 0 {
                        self.progress = time / self.duration
                    }
                }
            case "duration":
                if let dur = value as? Double {
                    self.duration = dur
                    self.fetchTracks()
                }
            case "pause":
                if let paused = value as? Bool {
                    self.isPlaying = !paused
                    if !self.isBuffering {
                        self.isUserPaused = paused
                    }
                }
            case "eof-reached":
                // Reliable natural-end signal with keep-open=yes (the file
                // stays loaded at the last frame, so MPV_EVENT_END_FILE alone
                // cannot be trusted to fire). The engine dedupes against the
                // END_FILE event.
                if let reached = value as? Bool, reached {
                    DispatchQueue.main.async { self.onEndOfFile?() }
                }
            case "paused-for-cache":
                if let buff = value as? Bool {
                    self.cachePaused = buff
                    self.refreshBuffering()
                    if buff {
                        self.isUserPaused = false
                    }
                }
            case "seeking":
                if let seek = value as? Bool {
                    self.isSeeking = seek
                }
            case "volume":
                if let vol = value as? Double {
                    self.volume = vol / 100.0
                }
            case "cache-buffering-state":
                if let percent = value as? Int64 {
                    self.bufferProgress = min(1.0, max(0.0, Double(percent) / 100.0))
                } else if let percent = value as? Int {
                    self.bufferProgress = min(1.0, max(0.0, Double(percent) / 100.0))
                } else if let percent = value as? Double {
                    self.bufferProgress = min(1.0, max(0.0, percent / 100.0))
                }
            default:
                break
            }
        }
    }

    func fetchTracks() {
        let tracks: [Track]
        if isHeadless {
            tracks = headlessView?.getTracks() ?? []
        } else {
            guard let viewTracks = playerView?.getTracks() else { return }
            tracks = viewTracks
        }

        DispatchQueue.main.async {
            self.audioTracks = tracks.filter { $0.type == "audio" }
            self.subtitleTracks = tracks.filter { $0.type == "sub" }
        }
    }

    func selectTrack(_ track: Track) {
        if isHeadless {
            headlessView?.selectTrack(track)
        } else {
            playerView?.selectTrack(track)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.fetchTracks()
        }
    }

    func addExternalSubtitle(url: String, title: String) {
        if isHeadless {
            headlessView?.addExternalSubtitle(url: url, title: title)
        } else {
            playerView?.addExternalSubtitle(url: url, title: title)
        }
        // Re-fetch tracks after a brief delay to show the new track selected
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.fetchTracks()
        }
    }
}

// MARK: - View Controller

class MPVViewController: NSViewController {
    var playerView: MPVLayerView!
    weak var delegate: MPVController?

    override func loadView() {
        self.view = NSView(frame: .init(x: 0, y: 0, width: 1280, height: 720))
        self.playerView = MPVLayerView(frame: self.view.bounds)
        self.playerView.autoresizingMask = [.width, .height]
        self.view.addSubview(playerView)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.playerView.setupContext()

        self.playerView.onPropertyChange = { [weak self] name, value in
            self?.delegate?.handlePropertyChange(name: name, value: value)
        }

        self.playerView.onPlaybackError = { [weak self] in
            print("[MPV] Playback error detected")
            DispatchQueue.main.async {
                self?.delegate?.onPlaybackError?()
            }
        }

        self.playerView.onEndOfFile = { [weak self] in
            DispatchQueue.main.async {
                self?.delegate?.onEndOfFile?()
            }
        }

        self.playerView.onFirstFrame = { [weak self] in
            self?.delegate?.firstFrameRendered()
        }

        self.playerView.onCoreReady = { [weak self] in
            guard let self else { return }
            self.delegate?.coreReady()
            // The engine may have created the controller and called play(url:)
            // before this view existed — pick the pending URL up now that mpv is
            // initialized. A headless→view handoff resumes at the exact position.
            if let pending = self.delegate?.pendingURL {
                self.delegate?.clearPending()
                self.delegate?.play(url: pending)
            } else if let handoff = self.delegate?.takeHeadlessHandoff() {
                // Resuming a video that was minimized to the mini player (headless):
                // this fresh view-side core loads the same URL and seeks to the exact
                // position so expanding back to the theater continues seamlessly.
                self.playerView.setVolume(self.delegate?.volume ?? 1.0)
                self.playerView.loadFile(handoff.url, startAt: handoff.position)
            }
        }

        // Kick off core initialization LAST — it runs on the background queue, so
        // this call returns immediately and the theater's open animation is never
        // blocked; onCoreReady (above) fires once init completes.
        self.playerView.setupMpv()
    }

    func play(_ url: URL) { playerView.loadFile(url) }
    func pause() { playerView.setPause(true) }
    func resume() { playerView.setPause(false) }
    func stop() { playerView.stop() }

    func seek(absolute seconds: Double) { playerView.seek(absoluteSeconds: seconds) }
    func seek(relative seconds: Double) { playerView.seek(relativeSeconds: seconds) }
    func seekAfterLoad(_ seconds: Double) { playerView.seekAfterLoad(seconds) }

    func setVolume(_ value: Double) { playerView.setVolume(value) }
    func getTracks() -> [Track] { return playerView.getTracks() }
    func selectTrack(_ track: Track) { playerView.selectTrack(track) }
    func addExternalSubtitle(url: String, title: String) { playerView.addExternalSubtitle(url: url, title: title) }
}

// MARK: - OpenGL View & MPV Backend

// MARK: - CAOpenGLLayer Subclass for Zero Main-Thread Hop Rendering
final class MPVLayer: CAOpenGLLayer {
    weak var ownerView: MPVLayerView?
    private let frameLock = NSLock()
    private var hasNewFrame = false
    private var hasRenderedFirstFrame = false
    private var lastSurfaceW: Int32 = 0
    private var lastSurfaceH: Int32 = 0

    override init() {
        super.init()
        self.isAsynchronous = true
        // EDR starts OFF and is toggled dynamically by applyColorPipeline()
        // based on the actual content: HDR video on an EDR-capable display and
        // nothing else. Leaving it on unconditionally washes out SDR content —
        // macOS interprets an EDR-opted-in float layer as linear light, while
        // mpv writes sRGB-encoded values by default, so the gamma gets decoded
        // twice and colors come out faded.
    }

    override init(layer: Any) {
        super.init(layer: layer)
        self.isAsynchronous = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.isAsynchronous = true
    }

    func markNewFrame() {
        frameLock.lock()
        hasNewFrame = true
        frameLock.unlock()
    }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        // HDR/EDR needs a floating-point backbuffer — an 8-bit buffer clamps
        // pixel values to [0,1], so there is no headroom above SDR white.
        // Use RGBA16F ONLY on EDR-capable displays. On SDR screens the float
        // surface is pure overhead (double the bandwidth, slower compositing)
        // and buys nothing since EDR never engages — the original player used
        // the standard 8-bit surface and ran every format smoothly.
        var pix: CGLPixelFormatObj?
        var npix: GLint = 0
        if NSScreen.screens.contains(where: { $0.maximumExtendedDynamicRangeColorComponentValue > 1.0 }) {
            let floatAttributes: [CGLPixelFormatAttribute] = [
                kCGLPFAAccelerated,
                kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
                kCGLPFADoubleBuffer,
                kCGLPFAColorFloat,
                kCGLPFAColorSize, CGLPixelFormatAttribute(64),
                kCGLPFADepthSize, CGLPixelFormatAttribute(24),
                CGLPixelFormatAttribute(0)
            ]
            if CGLChoosePixelFormat(floatAttributes, &pix, &npix) == kCGLNoError, pix != nil {
                return pix!
            }
        }
        let attributes: [CGLPixelFormatAttribute] = [
            kCGLPFAAccelerated,
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
            kCGLPFADoubleBuffer,
            kCGLPFAColorSize, CGLPixelFormatAttribute(32),
            kCGLPFADepthSize, CGLPixelFormatAttribute(24),
            CGLPixelFormatAttribute(0)
        ]
        CGLChoosePixelFormat(attributes, &pix, &npix)
        return pix!
    }

    override func copyCGLContext(forPixelFormat pixelFormat: CGLPixelFormatObj) -> CGLContextObj {
        var ctx: CGLContextObj?
        CGLCreateContext(pixelFormat, nil, &ctx)
        if let ctx {
            // Retain the context on the view: mpv_render_context_free destroys GL
            // objects (glDeleteTextures) and requires the context CURRENT on the
            // calling thread — teardown() binds it on the background queue.
            CGLRetainContext(ctx)
            ownerView?.renderContext = ctx
        }
        return ctx!
    }

    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat: CGLPixelFormatObj, forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        return true
    }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat: CGLPixelFormatObj, forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        CGLSetCurrentContext(ctx)

        guard let owner = ownerView else {
            glFlush()
            return
        }

        // Serialize against teardown(): a draw may be in flight (main thread or the
        // async CAOpenGLLayer thread) while cleanup frees the render context and
        // destroys mpv. Freeing mpv mid-render is a use-after-free that surfaces as
        // garbage frames and an assert inside gl_upload_tex / the mpv dispatch queue.
        owner.renderLock.lock()
        defer { owner.renderLock.unlock() }

        guard owner.mpv != nil else {
            glFlush()
            return
        }

        if owner.mpvGL == nil {
            owner.setupMPVGL(with: ctx)
        }

        guard let mpvGL = owner.mpvGL else {
            glFlush()
            return
        }

        // Update render context on OpenGL thread with active context
        _ = mpv_render_context_update(mpvGL)

        let scale = contentsScale
        let w = Int32(bounds.width * scale)
        let h = Int32(bounds.height * scale)

        guard w > 0 && h > 0 else {
            glFlush()
            return
        }

        // Diagnostics: the surface size must follow the view across the
        // fullscreen → theater re-parent. Log on every size change.
        if w != lastSurfaceW || h != lastSurfaceH {
            lastSurfaceW = w
            lastSurfaceH = h
            let dw = owner.getPropertyInt("video-out-params/dw") ?? -1
            let dh = owner.getPropertyInt("video-out-params/dh") ?? -1
            print("Cascade gl: surface=\(w)x\(h) videoOut=\(dw)x\(dh) viewFrame=\(owner.frame)")
        }

        glViewport(0, 0, GLsizei(w), GLsizei(h))

        var currentFBO: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &currentFBO)

        var flipY: Int32 = 1
        var fbo = mpv_opengl_fbo(fbo: currentFBO, w: w, h: h, internal_format: 0)

        withUnsafeMutablePointer(to: &fbo) { fboPtr in
            withUnsafeMutablePointer(to: &flipY) { flipPtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fboPtr),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipPtr),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                let result = mpv_render_context_render(mpvGL, &params)
                if result >= 0 {
                    mpv_render_context_report_swap(mpvGL)
                    if !hasRenderedFirstFrame {
                        hasRenderedFirstFrame = true
                        DispatchQueue.main.async { [weak owner] in
                            owner?.onFirstFrame?()
                        }
                    }
                }
            }
        }

        glFlush()
    }
}

// MARK: - Hosting NSView Backed by CAOpenGLLayer
final class MPVLayerView: NSView {
    private static let mpvLogger = Logger(subsystem: "com.cascade.app", category: "mpv")

    /// Guards mpvGL/mpv lifecycle against concurrent CAOpenGLLayer draws.
    fileprivate let renderLock = NSLock()

    private(set) var mpv: OpaquePointer!
    var mpvGL: OpaquePointer!
    /// Retained copy of the CAOpenGLLayer's context, bound on the teardown
    /// queue thread so mpv_render_context_free can destroy its GL objects.
    var renderContext: CGLContextObj?
    private var pendingURL: URL?
    private var displayLink: CVDisplayLink?
    let mpvLayer = MPVLayer()

    var queue = DispatchQueue(label: "mpv", qos: .userInteractive)
    var onPropertyChange: ((String, Any) -> Void)?
    var onPlaybackError: (() -> Void)?
    var onEndOfFile: (() -> Void)?
    /// Fired on the main thread once the mpv core finished initializing.
    var onCoreReady: (() -> Void)?
    /// Fired once, on the main thread, after the first frame was rendered.
    var onFirstFrame: (() -> Void)?
    /// True once mpv_initialize completed (set on the main thread). Guards the
    /// headless path, which must issue loadfile itself (it never gets a render
    /// context to consume a pending load).
    private(set) var isMpvReady = false
    /// Whether video output is routed to the GL surface (true) or null (headless).
    private var videoOutputEnabled = true
    private var isEventLoopRunning = false
    private let eventLoopLock = NSLock()
    private var isCleaningUp = false
    private var lastTimePosDispatchTime: Double = 0
    private var lastTelemetryLogTime: Double = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        mpvLayer.ownerView = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func makeBackingLayer() -> CALayer {
        return mpvLayer
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        mpvLayer.contentsScale = window?.backingScaleFactor ?? 2.0
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        mpvLayer.contentsScale = window?.backingScaleFactor ?? 2.0
        // Extended-range color space so EDR values (>1.0) reach the display on
        // HDR-capable screens. On SDR displays it must NOT be set: it pushes
        // the whole window down the extended-range compositing path for no
        // benefit, which costs performance — the original player left it alone
        // and ran smoothly.
        if let window, window.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 0 > 1.0 {
            window.colorSpace = .extendedSRGB
        }
    }

    func setupDisplayLink() {
        // Display link setup if needed
    }

    func mpvRenderUpdate() {
        DispatchQueue.main.async { [weak self] in
            self?.mpvLayer.setNeedsDisplay()
        }
    }

    func teardown() {
        guard !isCleaningUp else { return }
        isCleaningUp = true
        // If this view is currently presented in the player full-screen window, close
        // it first so we never tear down mpv while its layer is being displayed there.
        PlayerFullScreenWindow.shared.dismiss()

        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }

        // Heavy mpv destruction is deferred OFF the main thread: freeing the render
        // context and destroying the core blocks for tens of milliseconds, which
        // froze the theater's exit transition exactly when it should be smoothest.
        // mpv_render_context_free requires the GL context CURRENT on the calling
        // thread (it deletes textures via glDeleteTextures), so we bind the layer's
        // retained context while inside the lock. The renderLock serializes against
        // any in-flight CAOpenGLLayer draw (draws that passed the mpv guard hold
        // the lock until their render finishes, so the context is never bound on
        // two threads at once), and a strong self capture keeps the view alive
        // until the destruction completes so the mpv handle is never leaked.
        let gl = self.mpvGL
        let handle = self.mpv
        let ctx = self.renderContext
        self.mpvGL = nil
        self.mpv = nil
        queue.async {
            self.renderLock.lock()
            if let ctx {
                CGLSetCurrentContext(ctx)
            }
            if let gl {
                mpv_render_context_set_update_callback(gl, { _ in }, nil)
                mpv_render_context_free(gl)
            }
            if let handle {
                mpv_terminate_destroy(handle)
            }
            if let ctx {
                CGLSetCurrentContext(nil)
                CGLReleaseContext(ctx)
                self.renderContext = nil
            }
            self.renderLock.unlock()
        }
    }

    func cleanup() {
        teardown()
    }

    deinit { cleanup() }

    func setupContext() {
        // Context created natively by CAOpenGLLayer
    }

    /// The display's EDR peak in nits, or nil for SDR-only screens. Apple's EDR
    /// value is relative to SDR white (1.0); the WWDC21 "Explore HDR rendering
    /// with EDR" session maps EDR 3.2 to 1600 nits, so nits ~= 500 x EDR value.
    private func edrPeakNits() -> Int? {
        let screen = window?.screen ?? NSScreen.main
        guard let screen else { return nil }
        let edr = screen.maximumExtendedDynamicRangeColorComponentValue
        guard edr > 1.0 else { return nil }
        return min(1600, max(300, Int((edr * 500).rounded())))
    }

    /// Picks the color pipeline that matches the current content.
    ///
    /// HDR video (PQ or HLG transfer on BT.2020 / Display-P3 primaries) played
    /// on an EDR-capable display gets the EDR layer with a PQ color space and
    /// mpv's HDR target settings (passthrough, hard-clipped at the display's
    /// EDR peak). Everything else — SDR content, and HDR on plain SDR displays
    /// (mpv tone-maps those itself) — renders as sRGB with mpv's defaults.
    ///
    /// EDR must never be enabled for SDR content: macOS interprets an
    /// EDR-opted-in float layer as linear light, but mpv writes sRGB-encoded
    /// values by default. That decodes the gamma twice and the picture comes
    /// out washed out and faded. The layer's EDR flag and color space are
    /// toggled here as content changes (video-params observation) — the same
    /// approach IINA uses.
    private var lastPipelineKey = ""

    func applyColorPipeline() {
        guard mpv != nil else { return }
        let gamma = getPropertyString("video-params/gamma") ?? ""
        let primaries = getPropertyString("video-params/primaries") ?? ""
        let isHDR = gamma == "pq" || gamma == "hlg"
        let pqColorSpace: CGColorSpace? = {
            switch primaries {
            case "bt.2020": return CGColorSpace(name: CGColorSpace.itur_2100_PQ)
            case "display-p3": return CGColorSpace(name: CGColorSpace.displayP3_PQ)
            default: return nil
            }
        }()
        let peakNits = edrPeakNits()
        let useEDR = isHDR && pqColorSpace != nil && peakNits != nil

        // Property sets below can trigger a VO/GPU-pipeline reconfig inside mpv.
        // Re-running them on every video-params observation (mpv fires several
        // at load) causes repeated reconfig churn right as playback starts — the
        // exact moment the original player was smooth. Only apply when the
        // decided pipeline actually changes.
        let key = "\(useEDR)|peak=\(peakNits ?? 0)|\(gamma)|\(primaries)"
        guard key != lastPipelineKey else { return }
        lastPipelineKey = key

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // SDR: pin the layer to the sRGB transfer so the compositor decodes
            // mpv's sRGB-encoded output exactly once (the pre-EDR behavior).
            // HDR: the PQ color space tells the compositor how to interpret the
            // extended-range float values produced by the HDR target settings
            // below.
            self.mpvLayer.wantsExtendedDynamicRangeContent = useEDR
            self.mpvLayer.colorspace = useEDR ? pqColorSpace : CGColorSpaceCreateDeviceRGB()
        }

        if useEDR, let peakNits {
            // HDR passthrough: encode to PQ in the video's primaries and hard-
            // clip at the display's EDR peak (WWDC21 "Explore HDR with EDR"
            // recipe for libmpv, mpv issue #7341). No tone mapping, so HDR
            // keeps its brightness instead of being squeezed into SDR.
            mpv_set_property_string(mpv, "target-trc", "pq")
            mpv_set_property_string(mpv, "target-prim", primaries)
            mpv_set_property_string(mpv, "target-peak", "\(peakNits)")
            mpv_set_property_string(mpv, "tone-mapping", "clip")
            Self.mpvLogger.log("HDR/EDR active: \(gamma, privacy: .public) \(primaries, privacy: .public), target-peak=\(peakNits, privacy: .public) nits")
        } else {
            // SDR (or HDR on a non-EDR display): restore mpv's default sRGB
            // target so colors render at full saturation.
            mpv_set_property_string(mpv, "target-trc", "auto")
            mpv_set_property_string(mpv, "target-prim", "auto")
            mpv_set_property_string(mpv, "target-peak", "auto")
            mpv_set_property_string(mpv, "tone-mapping", "auto")
            Self.mpvLogger.log("SDR pipeline active (gamma=\(gamma, privacy: .public), primaries=\(primaries, privacy: .public))")
        }
    }

    /// Initializes the mpv core. The heavy work (mpv_create, option setup,
    /// mpv_initialize, event-loop start) runs on the background `queue` — a fresh
    /// core costs tens of milliseconds of main-thread blocking that previously
    /// froze the theater's open/close animations at the exact moment they should
    /// be smoothest. `onCoreReady` fires on the main thread once init completes.
    func setupMpv() {
        queue.async { [weak self] in
            self?.initializeMpvCore()
        }
    }

    private func initializeMpvCore() {
        // The view may have been torn down while this block was queued — don't
        // create a core that nothing will destroy.
        guard !isCleaningUp else { return }
        guard mpv == nil else { return }
        mpv = mpv_create()
        if mpv == nil { return }

        // Options prior to initialization (matching Stremio's mpv.cpp)
        mpv_set_option_string(mpv, "terminal", "yes")
        mpv_set_option_string(mpv, "load-scripts", "no")
        mpv_set_option_string(mpv, "load-osd-console", "no")
        mpv_set_option_string(mpv, "load-stats-overlay", "no")
        mpv_set_option_string(mpv, "load-auto-profiles", "no")
        mpv_set_option_string(mpv, "ytdl", "no")
        mpv_set_option_string(mpv, "osc", "no")
        // Software-decoded frames bypass mpv's direct-rendering buffer pool. DR
        // recycles buffers while the GL renderer may still hold a reference, which
        // can hand the upload path a frame with a stale/zero plane stride
        // (mpv 0.38 assert "stride > 0" in gl_upload_tex — crashed on 8K AV1).
        mpv_set_option_string(mpv, "vd-lavc-dr", "no")

        if mpv_initialize(mpv) < 0 {
            print("[MPV] init failed")
            return
        }

        // Properties set AFTER initialization (matching Stremio's mpv.cpp)
        mpv_set_property_string(mpv, "vo", "libmpv")
        mpv_set_property_string(mpv, "profile", "fast")
        mpv_set_property_string(mpv, "scale", "bilinear")
        mpv_set_property_string(mpv, "hwdec", "auto")
        mpv_set_property_string(mpv, "gpu-hwdec-interop", "auto")
        mpv_set_property_string(mpv, "video-sync", "audio")
        // After natural EOF keep the file loaded (paused at the last frame)
        // instead of unloading the core. MPV_EVENT_END_FILE still fires; the
        // player layer uses this for the ended-state replay (Space → seek 0 +
        // play on the SAME core — no teardown/reload race).
        mpv_set_property_string(mpv, "keep-open", "yes")

        mpv_set_property_string(mpv, "sub-cache", "yes")
        mpv_set_property_string(mpv, "sub-ass-override", "no")

        mpv_set_property_string(mpv, "cache", "yes")
        mpv_set_property_string(mpv, "cache-secs", "30")
        // Network-profile insurance (mpv big-cache recommendation): with the
        // deep-range fetcher feeding the loopback server, this buffer absorbs
        // any transient stall before it can reach playback.
        mpv_set_property_string(mpv, "demuxer-max-bytes", "268435456")
        mpv_set_property_string(mpv, "demuxer-max-back-bytes", "33554432")
        mpv_set_property_string(mpv, "demuxer-readahead-secs", "30")
        mpv_set_property_string(mpv, "demuxer-mkv-subtitle-preroll", "yes")
        mpv_set_property_string(mpv, "access-references", "no")
        mpv_set_property_string(mpv, "audio-fallback-to-null", "yes")
        mpv_set_property_string(mpv, "framedrop", "vo")

        // Dolby Atmos / DTS passthrough: when enabled, bitstream the raw Dolby/DTS
        // data (E-AC-3 JOC carries Atmos; TrueHD carries lossless Atmos) to an HDMI
        // receiver or soundbar in CoreAudio exclusive mode instead of decoding to
        // PCM. mpv falls back to decoding when the output can't take the bitstream.
        if UserDefaults.standard.bool(forKey: "xc.audioPassthrough") {
            mpv_set_property_string(mpv, "audio-spdif", "ac3,eac3,truehd,dts")
            mpv_set_property_string(mpv, "audio-exclusive", "yes")
        }

        mpv_set_property_string(mpv, "user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
        mpv_set_property_string(mpv, "referrer", "https://cascade.app/")

        // Capture mpv's warnings+ (demuxer/codec/render failures). NOT verbose:
        // at "v" mpv emits per-frame timing lines that flood the unified log
        // (drowning real signals like the telemetry) and add formatting load to
        // the playback thread — a regression the original player never had.
        mpv_request_log_messages(mpv, "warn")

        mpv_set_property_string(mpv, "sub-font-size", "45")
        mpv_set_property_string(mpv, "sub-border-size", "2")
        mpv_set_property_string(mpv, "sub-margin-y", "40")

        let audioLang = UserDefaults.standard.string(forKey: "defaultAudioLang") ?? "English"
        let subLang = UserDefaults.standard.string(forKey: "defaultSubLang") ?? "English"

        func getIsoCode(_ lang: String) -> String {
            switch lang {
            case "English": return "eng,en"
            case "Spanish": return "spa,es"
            case "French": return "fra,fre,fr"
            case "German": return "deu,ger,de"
            case "Japanese": return "jpn,ja"
            case "Korean": return "kor,ko"
            case "Hindi": return "hin,hi"
            default: return "eng,en"
            }
        }

        mpv_set_property_string(mpv, "alang", getIsoCode(audioLang))
        mpv_set_property_string(mpv, "slang", getIsoCode(subLang))

        // Observe properties (Must be called AFTER mpv_initialize)
        mpv_observe_property(mpv, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "eof-reached", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "volume", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "cache-buffering-state", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "seeking", MPV_FORMAT_FLAG)
        // HDR detection: fires when a file loads and its color parameters are
        // known, letting applyColorPipeline() pick the EDR vs sRGB pipeline.
        mpv_observe_property(mpv, 0, "video-params/gamma", MPV_FORMAT_STRING)
        mpv_observe_property(mpv, 0, "video-params/primaries", MPV_FORMAT_STRING)

        mpv_set_wakeup_callback(self.mpv, mpvWakeUp, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        startEventLoop()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.isCleaningUp {
                // The view was torn down while the core was initializing — destroy
                // the handle here so it can't leak (teardown's own block captured
                // the pre-init handle, which was nil).
                if let handle = self.mpv {
                    self.mpv = nil
                    mpv_terminate_destroy(handle)
                }
                return
            }
            self.isMpvReady = true
            self.onCoreReady?()
            // Headless playback never creates a render context (a video view's
            // pending load is consumed by setupMPVGL on the first draw instead),
            // so the load queued by playHeadless() must be issued here.
            if !self.videoOutputEnabled, let pending = self.pendingURL {
                self.pendingURL = nil
                self.command("loadfile", pending.absoluteString)
            }
        }
    }

    func setupMPVGL(with ctx: CGLContextObj) {
        guard mpvGL == nil, mpv != nil else { return }
        CGLSetCurrentContext(ctx)

        let getProcAddress: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? = { _, name in
            guard let name = name else { return nil }
            return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) // RTLD_DEFAULT
        }

        var initParams = mpv_opengl_init_params(
            get_proc_address: getProcAddress,
            get_proc_address_ctx: nil
        )

        "opengl".withCString { api in
            withUnsafeMutablePointer(to: &initParams) { initParamsPtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: api)),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: initParamsPtr),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                let res = mpv_render_context_create(&mpvGL, mpv, &params)
                if res < 0 {
                    print("[MPV] Failed to create mpv render context: \(res)")
                } else {
                    print("[MPV] Successfully created render context!")
                }
            }
        }

        mpv_render_context_set_update_callback(mpvGL, mpvGLUpdate, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        setupDisplayLink()

        // Pick the color pipeline for the current content: HDR video gets the
        // EDR layer + PQ target, everything else renders as plain sRGB with
        // mpv defaults. No file is loaded yet here, so this applies SDR
        // defaults; the video-params observation re-runs it once a file loads.
        applyColorPipeline()

        if let pending = pendingURL {
            print("[MPV] Context ready! Now loading pending URL: \(pending.lastPathComponent)")
            let urlToLoad = pending
            pendingURL = nil
            command("loadfile", urlToLoad.absoluteString)
        }
    }

    /// Seek target applied once the next file finishes loading. mpv drops a
    /// "seek" issued before the file is loaded, so resume positions must wait
    /// for MPV_EVENT_FILE_LOADED (handled in the event loop).
    private var seekOnLoad: Double?

    func loadFile(_ url: URL) {
        loadFile(url, startAt: nil)
    }

    /// Loads `url`, optionally resuming at `startAt` seconds once the file is
    /// loaded (used by headless→view handoffs: a video minimized to the mini
    /// player expands back into the theater and must continue where it left off).
    func loadFile(_ url: URL, startAt seconds: Double?) {
        seekOnLoad = seconds
        if mpvGL == nil {
            print("[MPV] Deferring loadFile until render context is initialized: \(url.lastPathComponent)")
            pendingURL = url
        } else {
            pendingURL = nil
            command("loadfile", url.absoluteString)
        }
    }

    /// Loads a file for headless (view-less) playback — used for audio-only streams.
    /// Bypasses the render-context gate that video playback relies on; the caller
    /// must have disabled video output (vo=null) so nothing ever needs to render.
    /// If the core is still initializing (init runs off the main thread), the load
    /// is queued and issued from the init completion on the background queue.
    func playHeadless(_ url: URL, startPosition: Double = 0) {
        pendingURL = url
        seekOnLoad = startPosition > 0.5 ? startPosition : nil
        guard isMpvReady else { return }
        pendingURL = nil
        command("loadfile", url.absoluteString)
    }

    /// Routes video output to the GL render surface (enabled, the default) or to
    /// null (disabled — headless audio). Must be set before loadfile.
    func setVideoOutput(_ enabled: Bool) {
        videoOutputEnabled = enabled
        guard mpv != nil else { return }
        if enabled {
            mpv_set_property_string(mpv, "vo", "libmpv")
            mpv_set_property_string(mpv, "vid", "auto")
        } else {
            mpv_set_property_string(mpv, "vid", "no")
            mpv_set_property_string(mpv, "vo", "null")
        }
    }

    func setPause(_ paused: Bool) {
        guard mpv != nil else { return }
        mpv_set_property_string(mpv, "pause", paused ? "yes" : "no")
    }

    func stop() {
        command("stop")
    }

    func seek(absoluteSeconds seconds: Double) {
        command("seek", String(format: "%.2f", seconds), "absolute")
    }

    func seek(relativeSeconds seconds: Double) {
        command("seek", String(format: "%.2f", seconds), "relative")
    }

    /// Queues a seek to apply once the next file finishes loading (mpv drops
    /// pre-load seeks) — for seeks requested while the core was still loading.
    func seekAfterLoad(_ seconds: Double) {
        seekOnLoad = seconds
    }

    func setVolume(_ value: Double) {
        guard mpv != nil else { return }
        var doubleVal = value * 100
        mpv_set_property(mpv, "volume", MPV_FORMAT_DOUBLE, &doubleVal)
    }

    func getVolume() -> Double {
        var vol: Double = 0
        guard mpv != nil else { return 0 }
        mpv_get_property(mpv, "volume", MPV_FORMAT_DOUBLE, &vol)
        return vol
    }

    func getTracks() -> [Track] {
        guard mpv != nil else { return [] }
        var tracks: [Track] = []
        var count: Int64 = 0
        if mpv_get_property(mpv, "track-list/count", MPV_FORMAT_INT64, &count) >= 0 {
            for i in 0..<Int(count) {
                let type = getPropertyString("track-list/\(i)/type") ?? ""
                let id = getPropertyInt("track-list/\(i)/id") ?? 0
                let title = getPropertyString("track-list/\(i)/title") ?? getPropertyString("track-list/\(i)/demux-title") ?? ""
                let lang = getPropertyString("track-list/\(i)/lang") ?? "und"
                let selected = getPropertyBool("track-list/\(i)/selected") ?? false
                if type == "audio" || type == "sub" {
                    tracks.append(Track(id: id, type: type, title: title, lang: lang, isSelected: selected))
                }
            }
        }
        return tracks
    }

    func selectTrack(_ track: Track) {
        guard mpv != nil else { return }
        let propertyName = track.type == "audio" ? "aid" : "sid"
        mpv_set_option_string(mpv, propertyName, "\(track.id)")
    }

    func addExternalSubtitle(url: String, title: String) {
        command("sub-add", url, "select", title)
    }

    private func command(_ args: String...) {
        guard mpv != nil else { return }
        withCStrings(args) { cArgs in
            var mutableArgs = cArgs
            mutableArgs.withUnsafeMutableBufferPointer { buffer in
                // ASYNC, never blocking: mpv_command() blocks the CALLING thread
                // until the core finishes the command. loadfile of a streamed
                // file blocks through the whole network demuxer open, and stop
                // blocks through the stream teardown — both ran on the main
                // thread, which froze the theater's open/close exactly when it
                // should be smoothest. mpv_command_async() queues the command
                // onto the core's own thread and returns immediately; the args
                // are copied internally, so the pointers only live for the call.
                _ = mpv_command_async(mpv, 0, buffer.baseAddress)
            }
        }
    }

    // Helpers
    private func getPropertyDouble(_ name: String) -> Double? {
        guard mpv != nil else { return nil }
        var value: Double = 0
        if mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &value) >= 0 { return value }
        return nil
    }

    private func getPropertyString(_ name: String) -> String? {
        guard mpv != nil else { return nil }
        guard let cString = mpv_get_property_string(mpv, name) else { return nil }
        let str = String(cString: cString)
        mpv_free(cString)
        return str
    }

    fileprivate func getPropertyInt(_ name: String) -> Int? {
        guard mpv != nil else { return nil }
        var value: Int64 = 0
        if mpv_get_property(mpv, name, MPV_FORMAT_INT64, &value) >= 0 { return Int(value) }
        return nil
    }

    private func getPropertyBool(_ name: String) -> Bool? {
        guard mpv != nil else { return nil }
        var value: Int32 = 0
        if mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &value) >= 0 { return value != 0 }
        return nil
    }

    func startEventLoop() {
        eventLoopLock.lock()
        guard !isEventLoopRunning else {
            eventLoopLock.unlock()
            return
        }
        isEventLoopRunning = true
        eventLoopLock.unlock()

        queue.async { [weak self] in
            guard let self = self else { return }
            defer {
                self.eventLoopLock.lock()
                self.isEventLoopRunning = false
                self.eventLoopLock.unlock()
            }

            while !self.isCleaningUp, let handle = self.mpv {
                let now = CFAbsoluteTimeGetCurrent()
                if now - self.lastTelemetryLogTime >= 1.0 {
                    self.lastTelemetryLogTime = now
                    let cacheSecs = self.getPropertyDouble("demuxer-cache-duration") ?? 0.0
                    let mistimed = self.getPropertyInt("mistimed-frame-count") ?? 0
                    let voDrop = self.getPropertyInt("vo-drop-frame-count") ?? 0
                    let decDrop = self.getPropertyInt("decoder-frame-drop-count") ?? 0
                    let hwdec = self.getPropertyString("hwdec-current") ?? "none"
                    // Top-level codec properties ("av01", "h264", "eac3", "aac", ...)
                    // — `video-params/codec` reads as unavailable on this mpv build.
                    let codec = self.getPropertyString("video-codec") ?? "none"
                    let audioCodec = self.getPropertyString("audio-codec") ?? "none"
                    let vfps = self.getPropertyDouble("estimated-vf-fps") ?? 0
                    let pausedCache = self.getPropertyBool("paused-for-cache") ?? false
                    let drop = self.getPropertyInt("drop-frame-count") ?? 0
                    let telemetry = "[MPV TELEMETRY] vcodec:\(codec) acodec:\(audioCodec) hwdec:\(hwdec) cache:\(String(format: "%.1f", cacheSecs))s paused4cache:\(pausedCache) | mistimed:\(mistimed) voDrop:\(voDrop) decDrop:\(decDrop) drop:\(drop) vfps:\(String(format: "%.1f", vfps))"
                    print(telemetry)
                    Self.mpvLogger.log("\(telemetry, privacy: .public)")
                    self.appendTelemetryFile(telemetry)
                }

                guard let event = mpv_wait_event(handle, 1.0) else { continue }
                let eventId = event.pointee.event_id
                if eventId == MPV_EVENT_NONE { continue }

                if eventId == MPV_EVENT_PROPERTY_CHANGE {
                    let prop = event.pointee.data.assumingMemoryBound(to: mpv_event_property.self)
                    let name = String(cString: prop.pointee.name)

                    if prop.pointee.format == MPV_FORMAT_DOUBLE {
                        let value = prop.pointee.data.assumingMemoryBound(to: Double.self).pointee
                        if name == "time-pos" {
                            let now = CFAbsoluteTimeGetCurrent()
                            if now - self.lastTimePosDispatchTime >= 0.25 {
                                self.lastTimePosDispatchTime = now
                                DispatchQueue.main.async { self.onPropertyChange?(name, value) }
                            }
                        } else {
                            DispatchQueue.main.async { self.onPropertyChange?(name, value) }
                        }
                    } else if prop.pointee.format == MPV_FORMAT_FLAG {
                        let value = prop.pointee.data.assumingMemoryBound(to: Int32.self).pointee != 0
                        DispatchQueue.main.async { self.onPropertyChange?(name, value) }
                    } else if prop.pointee.format == MPV_FORMAT_INT64 {
                        let value = prop.pointee.data.assumingMemoryBound(to: Int64.self).pointee
                        DispatchQueue.main.async { self.onPropertyChange?(name, value) }
                    } else if prop.pointee.format == MPV_FORMAT_STRING {
                        let cstr = prop.pointee.data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee
                        let value = cstr.map { String(cString: $0) } ?? ""
                        // Color parameters are known as soon as a file loads;
                        // re-evaluate the EDR vs sRGB pipeline on change.
                        if name == "video-params/gamma" || name == "video-params/primaries" {
                            self.applyColorPipeline()
                        }
                        DispatchQueue.main.async { self.onPropertyChange?(name, value) }
                    }
                } else if eventId == MPV_EVENT_LOG_MESSAGE {
                    let msg = event.pointee.data.assumingMemoryBound(to: mpv_event_log_message.self)
                    let level = msg.pointee.level.map { String(cString: $0) } ?? "?"
                    let prefix = msg.pointee.prefix.map { String(cString: $0) } ?? ""
                    var text = msg.pointee.text.map { String(cString: $0) } ?? ""
                    if !text.hasSuffix("\n") { text += "\n" }
                    // Forward to stderr (captured by dev-launch scripts) AND the
                    // unified log, so mpv's trace is always available no matter
                    // how the app was launched.
                    print("[MPV \(prefix)][\(level)] \(text)", terminator: "")
                    // explicit .public keeps the text visible in the unified log
                    // (default os.Logger interpolation is redacted).
                    Self.mpvLogger.log("[MPV \(prefix, privacy: .public)][\(level, privacy: .public)] \(text, privacy: .public)")
                } else if eventId == MPV_EVENT_FILE_LOADED {
                    // A resume position queued by loadFile(url, startAt:) is only
                    // valid once the new file is actually loaded — mpv ignores
                    // seeks issued before that.
                    if let target = self.seekOnLoad {
                        self.seekOnLoad = nil
                        self.command("seek", String(format: "%.2f", target), "absolute")
                    }
                } else if eventId == MPV_EVENT_END_FILE {
                    let endFile = event.pointee.data.assumingMemoryBound(to: mpv_event_end_file.self)
                    if endFile.pointee.reason == MPV_END_FILE_REASON_ERROR {
                        print("[MPV] Error: End File Reason ERROR")
                        DispatchQueue.main.async { self.onPlaybackError?() }
                    } else if endFile.pointee.reason == MPV_END_FILE_REASON_EOF {
                        // Natural end of track — notify so playlists advance.
                        DispatchQueue.main.async { self.onEndOfFile?() }
                    }
                }
            }
        }
    }

    /// Appends a line to /tmp/cascade-mpv-telemetry.log so playback stats survive
    /// no matter how the app was launched (open(1) swallows stdout, and the
    /// unified log can drop high-frequency lines under mpv's message load).
    private func appendTelemetryFile(_ line: String) {
        let path = "/tmp/cascade-mpv-telemetry.log"
        let text = line + "\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            handle.write(text.data(using: .utf8)!)
        } else {
            try? text.data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
        }
    }

    private func withCStrings(_ strings: [String], block: ([UnsafePointer<CChar>?]) -> Void) {
        var cStrings: [UnsafePointer<CChar>?] = []
        var keepAlive: [Any] = []
        for string in strings {
            let utf8 = string.utf8CString
            let ptrCopy = UnsafeMutablePointer<CChar>.allocate(capacity: utf8.count)
            utf8.withUnsafeBufferPointer { ptrCopy.initialize(from: $0.baseAddress!, count: utf8.count) }
            cStrings.append(UnsafePointer(ptrCopy))
            keepAlive.append(ptrCopy)
        }
        cStrings.append(nil)
        block(cStrings)
        for case let ptr as UnsafeMutablePointer<CChar> in keepAlive { ptr.deallocate() }
    }
}

func mpvGLUpdate(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx = ctx else { return }
    let layerView = Unmanaged<MPVLayerView>.fromOpaque(ctx).takeUnretainedValue()
    layerView.mpvRenderUpdate()
}

func mpvWakeUp(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx = ctx else { return }
    let layerView = Unmanaged<MPVLayerView>.fromOpaque(ctx).takeUnretainedValue()
    layerView.startEventLoop()
}

// MARK: - Player-only Full Screen Window

/// Presents the player's MPVLayerView in a separate borderless full-screen window so
/// ONLY the player goes full screen — the app window (sidebar, browser, controls)
/// stays put. The layer view is re-parented between windows, never recreated, so the
/// mpv instance survives the transition and playback continues uninterrupted. A
/// SwiftUI controls overlay (the same PlayerControlsView the windowed player uses)
// MARK: - Player-only Full Screen Player

/// App-wide serializer for native fullscreen transitions. macOS runs at most
/// one fullscreen Space transition at a time; a `toggleFullScreen` issued
/// while another window is mid-transition is SILENTLY IGNORED and leaves the
/// target window permanently unable to enter fullscreen (private AppKit
/// state — only close+recreate recovers). Every fullscreen request in the app
/// (player presentation, player toggle) is routed through this gate so that
// CascadeApp.init`).
final class FullscreenTransitionGate {
    static let shared = FullscreenTransitionGate()

    private var activeTransitions = 0
    private var pendingStarts: [UUID: Date] = [:]
    private var idleHandlers: [UUID: () -> Void] = [:]

    var isTransitioning: Bool { activeTransitions > 0 }

    private init() {
        let center = NotificationCenter.default
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.transitionBegan()
            }
        }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.transitionEnded()
            }
        }
    }

    private func transitionBegan() {
        activeTransitions += 1
        let id = UUID()
        pendingStarts[id] = Date()
        // macOS has no "transition failed" notification; if a transition never
        // completes the counter must still settle or the gate would block
        // every future fullscreen request forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self, self.pendingStarts[id] != nil else { return }
            self.pendingStarts[id] = nil
            self.activeTransitions = max(0, self.activeTransitions - 1)
            self.drainIfIdle()
        }
    }

    private func transitionEnded() {
        guard !pendingStarts.isEmpty else {
            activeTransitions = max(0, activeTransitions - 1)
            drainIfIdle()
            return
        }
        // Transitions are serialized by the OS, so FIFO pairing is correct.
        let oldest = pendingStarts.keys.min { pendingStarts[$0]! < pendingStarts[$1]! }!
        pendingStarts[oldest] = nil
        activeTransitions = max(0, activeTransitions - 1)
        drainIfIdle()
    }

    private func drainIfIdle() {
        guard activeTransitions == 0 else { return }
        let handlers = idleHandlers
        idleHandlers.removeAll()
        DispatchQueue.main.async {
            for handler in handlers.values { handler() }
        }
    }

    /// Runs `handler` now if no fullscreen transition is in flight, otherwise
    /// after the in-flight transition completes.
    func runWhenIdle(_ handler: @escaping () -> Void) {
        if isTransitioning {
            idleHandlers[UUID()] = handler
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.isTransitioning {
                    self.runWhenIdle(handler)
                } else {
                    handler()
                }
            }
        }
    }
}

/// Presents the video in a SEPARATE, system-managed SwiftUI `Window` scene
/// ("fullscreenPlayer") instead of a hand-rolled NSWindow. The scene window is
/// a normal titled window, so it sizes itself correctly and can enter native
/// Spaces fullscreen — no manual style masks, no intrinsic-size collapse (the
/// same pattern the flux app uses). Entering fullscreen is owned by
/// `present`/`enterFullscreenSafely` so it works even if the scene window was
/// created earlier or the configurator no-ops.
/// Playback transfers by re-parenting the SAME `MPVLayerView` (never recreated,
/// mpv keeps running); the window hosts video + controls in one SwiftUI render
/// tree so `.glassEffect()` materials work. The main window stays open; the
/// theater shows an opaque placeholder OVER the still-mounted player (it must
/// stay mounted — dismantling it tears down mpv, which would kill the
/// fullscreen window via teardown → dismiss).
/// Fullscreen entry is flashless: the window is alpha-0 until the native
/// transition starts (`willEnterFullScreen`), so the user only ever sees the
/// window sliding into its own Space — no pop-up in the normal Space first.
final class PlayerFullScreenWindow: NSObject, ObservableObject {
    static let shared = PlayerFullScreenWindow()
    /// NSWindow identifier used to locate the scene window from AppKit code.
    static let windowTag = "CascadeFullscreenPlayer"

    enum SessionKind {
        /// Player opened from the theater: the layer comes from the theater and
        /// the window slides in over a ghost-window snapshot of it.
        case theater
        /// "Open in Full Screen" on a video: no theater — the window hosts its
        /// own layer from the engine's controller (spinner until it exists).
        case directVideo
        /// "Open in Full Screen" on an image: no engine at all — the window
        /// shows the image (spinner while it downloads).
        case image
    }

    struct Session {
        /// The theater's live mpv layer — nil in every non-theater kind (the
        /// window hosts its own content).
        let kind: SessionKind
        let player: MPVLayerView?
        let mpv: MPVController?
        let title: String
        let subtitle: String
        let appState: AppState
        /// The file being shown — non-nil in `.image` sessions (the image
        /// view resolves/downloads it itself, theater-style).
        let file: ObjectRecord?
    }

    @Published private(set) var isActive = false
    /// True once the live mpv layer has been moved into the fullscreen window
    /// (the swap at didEnterFullScreen); false again when it returns to the
    /// theater at dismissal. The theater uses this to fade itself out while
    /// the video lives in the player window (the browser behind becomes
    /// usable), but stay visible during the entry slide, when the video is
    /// still in the theater.
    @Published private(set) var videoLiveInFullscreen = false
    /// True when the player was opened without a theater ("Open in Full
    /// Screen"): there is no theater layer to attach, re-parent, or swap — the
    /// window hosts its own content. True for both the direct-video and image
    /// kinds.
    private(set) var directMode = false
    @Published var showExitWarning = false
    private(set) var session: Session?
    var onClose: (() -> Void)?
    private var onDismiss: (() -> Void)?

    private var openWindow: OpenWindowAction?
    private var dismissWindow: DismissWindowAction?
    private weak var playerView: MPVLayerView?
    private weak var hostView: NSView?
    /// The SwiftUI container inside the fullscreen window that the mpv layer
    /// is attached to. Created by `MPVLayerHost.makeNSView` at window mount;
    /// `configureAndEnter` does the actual attach (the video stays in the
    /// theater until the transition starts, so there is no hole before the
    /// slide).
    fileprivate weak var playerContainer: NSView?
    /// Composited capture of the theater window (incl. the live video) taken at
    /// present time. The fullscreen window slides in showing this static
    /// snapshot ("ghost window") — no live GL layer composited through the
    /// Space absorb, no surface reconfig mid-slide — and the live layer is
    /// swapped in at didEnterFullScreen with a fade. nil when capture failed
    /// (falls back to attaching the live layer pre-toggle).
    fileprivate var snapshotImage: CGImage?
    private var exitWarningTimer: Timer?
    private var keyMonitor: Any?
    private var miniaturizeObserver: Any?
    private var isDismissing = false
    /// Bumped on every present; stale async closures (window-find ladder,
    /// fullscreen watchdog) bail when the generation no longer matches.
    private var entryGeneration = 0

    private override init() {
        super.init()
    }

    /// Captures the scene actions from the main window's SwiftUI environment
    /// (called by `FullscreenWindowLink` when the main window appears).
    func bind(openWindow: OpenWindowAction, dismissWindow: DismissWindowAction) {
        self.openWindow = openWindow
        self.dismissWindow = dismissWindow
    }

    func present(
        _ player: MPVLayerView?,
        mpv: MPVController?,
        title: String,
        subtitle: String,
        appState: AppState,
        onClose: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        kind: SessionKind = .theater,
        file: ObjectRecord? = nil
    ) {
        guard !isActive, !isDismissing else { return }
        // Opening a window while another window of the app is mid-fullscreen
        // transition is what triggers the "silently ignored toggle + poisoned
        // window" AppKit bug — queue the request until no transition is in
        // flight.
        guard !FullscreenTransitionGate.shared.isTransitioning else {
            FullscreenTransitionGate.shared.runWhenIdle { [weak self] in
                self?.present(player, mpv: mpv, title: title, subtitle: subtitle, appState: appState, onClose: onClose, onDismiss: onDismiss, kind: kind, file: file)
            }
            return
        }
        // If a scene window from a previous session is still open (e.g. a
        // close that never landed), SwiftUI would REUSE it without re-creating
        // its content — the mpv layer would never re-mount and no fullscreen
        // would happen. Close it first and re-present fresh.
        if Self.sceneWindow != nil {
            dismissWindow?(id: "fullscreenPlayer")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.presentNow(player, mpv: mpv, title: title, subtitle: subtitle, appState: appState, onClose: onClose, onDismiss: onDismiss, kind: kind, file: file)
            }
        } else {
            presentNow(player, mpv: mpv, title: title, subtitle: subtitle, appState: appState, onClose: onClose, onDismiss: onDismiss, kind: kind, file: file)
        }
    }

    /// Opens a video STRAIGHT into the fullscreen player — the browser's "Open
    /// in Full Screen" menu action. No theater: playback starts through the
    /// engine and the fullscreen window hosts its own layer from the engine's
    /// controller once it exists (direct mode). The window slides in over a
    /// spinner; the video appears when the stream resolves. Exiting (ESC)
    /// stops playback and returns to the browser.
    @MainActor
    static func presentDirect(appState: AppState, file: ObjectRecord, playlist: [ObjectRecord]) {
        let engine = AudioPlayerEngine.shared
        engine.play(file: file, in: playlist)
        PlayerFullScreenWindow.shared.present(
            nil,
            mpv: nil,
            title: file.name,
            subtitle: ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file),
            appState: appState,
            onClose: {
                engine.stop()
                appState.theaterFile = nil
            },
            onDismiss: {
                engine.stop()
                appState.theaterFile = nil
                appState.isTheaterFullScreen = false
            },
            kind: .directVideo,
            file: file
        )
    }

    /// Opens an image STRAIGHT into the fullscreen player — the browser's
    /// "Open in Full Screen" menu action and the theater's fullscreen button
    /// for images. No engine, no theater: the window slides in over a spinner
    /// while the image view resolves the file (cached → instant; uncached →
    /// download with progress), then shows it fit-to-screen. Exiting
    /// (ESC / close) returns to the browser. The image view owns the download
    /// (view `.task`, like the theater's loadFile) — never gate it on the
    /// window's session state, which races present()'s deferral paths.
    @MainActor
    static func presentImage(appState: AppState, file: ObjectRecord) {
        PlayerFullScreenWindow.shared.present(
            nil,
            mpv: nil,
            title: file.name,
            subtitle: ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file),
            appState: appState,
            onClose: {
                appState.theaterFile = nil
            },
            onDismiss: {
                appState.theaterFile = nil
                appState.isTheaterFullScreen = false
            },
            kind: .image,
            file: file
        )
    }

    private func presentNow(
        _ player: MPVLayerView?,
        mpv: MPVController?,
        title: String,
        subtitle: String,
        appState: AppState,
        onClose: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        kind: SessionKind,
        file: ObjectRecord? = nil
    ) {
        guard !isActive, !isDismissing else { return }
        entryGeneration += 1
        softResetsDone = 0
        reopensDone = 0
        isActive = true
        directMode = kind != .theater
        session = Session(kind: kind, player: player, mpv: mpv, title: title, subtitle: subtitle, appState: appState, file: file)
        self.onClose = onClose
        self.onDismiss = onDismiss
        playerView = player

        // Remember where the live mpv layer lives in the THEATER so the exit
        // can re-parent it back. The video is NOT detached here: it stays
        // visible in the theater until `configureAndEnter` attaches it to the
        // fullscreen window's container right before the transition starts —
        // no hole in the theater during window setup, no vanish-then-slide.
        // (Direct mode has no theater — nothing to remember.)
        if let player, player.window != nil, let host = player.superview {
            hostView = host
        }

        // Ghost-window snapshot: capture the theater's composited pixels
        // (includes the live GL video — WindowServer has it in the window
        // surface) while it is still unobstructed. The fullscreen window
        // slides in showing this frame, so no live-GL content is composited
        // through the Space transition and the theater never shows a hole.
        // The capture is async (ScreenCaptureKit) — the window opens only
        // after it completes, so the container can mount the snapshot.
        // Skipped in direct mode (no theater): the window slides in over the
        // engine's loading spinner instead.
        Task { @MainActor in
            if player != nil {
                await self.captureTheaterSnapshot()
            }

            openWindow?(id: "fullscreenPlayer")

            // Ensure the scene window actually enters native fullscreen. The
            // scene's configurator runs at most once per window lifetime and may
            // silently no-op (window not yet present when it probes), so the
            // toggle is owned here. Entry is flashless (alpha-0 until the
            // transition starts) and gated (never toggle during another window's
            // transition — that is what poisons a window).
            self.enterFullscreenSafely(attempt: 0)

            // ESC is two-step: first press shows the exit hint, second exits
            // full screen; swallow the key so nothing else reacts.
            self.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                if event.keyCode == 53 {
                if self.showExitWarning {
                    print("Cascade player: ESC #2 — dismissing to theater")
                    self.clearExitWarning()
                    self.dismiss()
                } else {
                    print("Cascade player: ESC #1 — showing exit hint")
                    self.showExitWarning = true
                    self.exitWarningTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                        Task { @MainActor in self?.showExitWarning = false }
                    }
                }
                return nil
            }
            return event
        }

        // The OS minimize button (traffic light) on the FULLSCREEN player
        // would shrink the player into a small windowed box in the normal
        // Space — the user expects it to behave like ESC and return to the
        // theater player. Intercept while the window is fullscreen; windowed
        // minimize keeps its default dock-miniaturize behavior.
        self.miniaturizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willMiniaturizeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let window = note.object as? NSWindow,
                  window.identifier?.rawValue == Self.windowTag,
                  window.styleMask.contains(.fullScreen)
            else { return }
            print("Cascade player: minimize pressed in fullscreen — dismissing like ESC")
            self.dismiss()
        }
        }
    }

    /// Captures the theater window's composited pixels (including the live GL
    /// video) via ScreenCaptureKit. Called before the fullscreen window opens,
    /// so its container can mount the snapshot as the "ghost window" content
    /// for the Space transition. On failure the entry falls back to attaching
    /// the live layer pre-toggle.
    /// The capture is CROPPED to the video layer's frame: an uncropped window
    /// capture would show the whole app UI (sidebar + small player) scaled up
    /// on the fullscreen slide — the "player went back to the small player
    /// for a split second" glitch. The cropped ghost is pure video, visually
    /// identical to the live layer.
    @MainActor
    private func captureTheaterSnapshot() async {
        // ScreenCaptureKit requires Screen Recording permission (TCC) — without this
        // preflight, entering fullscreen made macOS throw a "Cascade wants to record
        // this screen" prompt at the user. When unauthorized, skip the ghost snapshot
        // entirely: the live-attach fallback covers the Space transition.
        guard CGPreflightScreenCaptureAccess() else {
            print("Cascade player: snapshot skipped — no Screen Recording permission (live attach fallback)")
            snapshotImage = nil
            return
        }
        guard let theaterWindow = hostView?.window, theaterWindow.windowNumber > 0 else {
            print("Cascade player: snapshot skipped — no theater window")
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let scWindow = content.windows.first(where: { Int($0.windowID) == theaterWindow.windowNumber }) else {
                print("Cascade player: snapshot — SCWindow not found for \(theaterWindow.windowNumber)")
                snapshotImage = nil
                return
            }
            let config = SCStreamConfiguration()
            let backing = theaterWindow.convertToBacking(theaterWindow.frame).size
            config.width = Int(backing.width)
            config.height = Int(backing.height)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: scWindow), configuration: config)
            // Crop to the video layer's frame (window base coords → image pixel
            // coords, flipped: CGImage origin is top-left, AppKit is bottom-left).
            if let playerView {
                let rect = playerView.convert(playerView.bounds, to: nil)
                let scale = theaterWindow.backingScaleFactor
                let backingRect = CGRect(
                    x: rect.minX * scale,
                    y: rect.minY * scale,
                    width: rect.width * scale,
                    height: rect.height * scale
                )
                let flipped = CGRect(
                    x: backingRect.minX,
                    y: CGFloat(image.height) - backingRect.maxY,
                    width: backingRect.width,
                    height: backingRect.height
                )
                if flipped.minX >= 0, flipped.minY >= 0,
                   flipped.maxX <= CGFloat(image.width), flipped.maxY <= CGFloat(image.height),
                   let cropped = image.cropping(to: flipped) {
                    snapshotImage = cropped
                    print("Cascade player: captured theater snapshot \(cropped.width)x\(cropped.height) (cropped to video area \(rect))")
                    return
                }
            }
            snapshotImage = image
            print("Cascade player: captured theater snapshot \(image.width)x\(image.height) (uncropped)")
        } catch {
            snapshotImage = nil
            print("Cascade player: snapshot capture failed: \(error.localizedDescription) — live attach fallback")
        }
    }

    /// The scene window (by identifier), if currently open.
    static var sceneWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == windowTag }
    }

    /// Finds the scene window, then enters native fullscreen flashlessly:
    /// alpha-0 until `willEnterFullScreen` (the user sees only the slide into
    /// the window's own Space). A watchdog treats a toggle that never starts
    /// as the "silently ignored" AppKit failure and recovers: one soft reset,
    /// then a fresh scene window (the only reliable cure for a poisoned
    /// window). Idempotent: skips once the window is already fullscreen.
    private func enterFullscreenSafely(attempt: Int) {
        guard isActive else { return }
        let generation = entryGeneration
        if let window = Self.sceneWindow {
            guard !window.styleMask.contains(.fullScreen) else { return }
            // The gate normally prevents a collision here (present() already
            // waited), but the user can still green-button the main window in
            // between — never toggle into a live transition.
            guard !FullscreenTransitionGate.shared.isTransitioning else {
                FullscreenTransitionGate.shared.runWhenIdle { [weak self] in
                    guard let self, self.entryGeneration == generation else { return }
                    self.configureAndEnter(window)
                }
                return
            }
            configureAndEnter(window)
            return
        }
        let delays = [0.02, 0.1, 0.3, 0.6]
        guard attempt < delays.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) { [weak self] in
            guard let self, self.entryGeneration == generation else { return }
            self.enterFullscreenSafely(attempt: attempt + 1)
        }
    }

    /// Prepares the window (fullscreen-primary, black, invisible), attaches the
    /// mpv layer to its container, and toggles it into native fullscreen,
    /// revealing it the moment the transition starts. The video is attached
    /// only HERE — the theater keeps showing it until the slide begins, and the
    /// window is sized exactly to the screen and made borderless first, so the
    /// GL surface does NOT change size during the transition (each mpv surface
    /// reconfig stalls rendering — that was the stutter). Installs a watchdog:
    /// if the toggle was silently ignored, the window recovers via
    /// `recoverIgnoredFullscreen`.
    private func configureAndEnter(_ window: NSWindow) {
        let generation = entryGeneration
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .disallowed
        window.backgroundColor = .black
        // Invisible until the transition starts → no flash in the normal Space.
        // (The configurator also sets alpha 0 at attach — earliest moment.)
        window.alphaValue = 0
        // The scene opens at its default size (1280×800); without this the
        // native fullscreen transition SCALES the window up during the slide.
        // Size the window to the target screen first so the transition is a
        // pure Space absorb (Apple-TV style), no scaling animation.
        // NOTE: do NOT mutate styleMask here (e.g. removing .titled to avoid
        // the title-bar height growth) — a styleMask write right before the
        // toggle makes the fullscreen toggle get SILENTLY IGNORED (window
        // server rejects the transition). Sizing to the screen alone yields a
        // content size that already equals the screen.
        // display: true forces the content layout synchronously — with
        // display: false the content can still be 30pt short (title bar) when
        // the window hasn't finished mapping, which reconfigures the GL
        // surface MID-slide (the stutter). The retry loop in
        // attachVideoThenToggle re-asserts the frame after mapping.
        if let screen = window.screen ?? NSScreen.main {
            window.setFrame(screen.frame, display: true, animate: false)
        }
        print("Cascade player: configureAndEnter t=\(Date().timeIntervalSince1970) fs=\(window.styleMask.contains(.fullScreen)) frame=\(window.frame) winScreen=\(String(describing: window.screen?.frame)) main=\(String(describing: NSScreen.main?.frame)) content=\(String(describing: window.contentView?.bounds.size))")

        var didEnter = false
        var willObserver: NSObjectProtocol?
        var didObserver: NSObjectProtocol?
        willObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main
        ) { [weak window] _ in
            // Reveal at the START of the slide — this is what reads as the
            // window swiping into its own Space.
            print("Cascade player: willEnterFullScreen reveal t=\(Date().timeIntervalSince1970)")
            window?.alphaValue = 1
            if let willObserver { NotificationCenter.default.removeObserver(willObserver) }
        }
        didObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            didEnter = true
            print("Cascade player: didEnterFullScreen t=\(Date().timeIntervalSince1970)")
            if let didObserver { NotificationCenter.default.removeObserver(didObserver) }
            // Ghost-window handoff: the live layer is still in the theater
            // (it never left); move it into the fullscreen container now and
            // fade it over the snapshot. The theater is in the background
            // space, so its video area going dark is not visible.
            self?.swapLiveVideoIn(window: window)
        }
        if !window.isVisible {
            window.makeKeyAndOrderFront(nil)
        }
        attachVideoThenToggle(window: window, generation: generation)

        // Watchdog: a toggle that never produced a willEnter was ignored —
        // the window is poisoned and will never enter fullscreen on its own.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.entryGeneration == generation, !didEnter else { return }
            guard !window.styleMask.contains(.fullScreen) else { return }
            print("Cascade player: watchdog — toggle ignored, recovering")
            self.recoverIgnoredFullscreen(window)
        }
    }

    /// Waits for the fullscreen window's SwiftUI container to mount, then toggles
    /// fullscreen. With a ghost snapshot the live layer stays in the theater
    /// (it is swapped in at didEnterFullScreen); without one (capture failed)
    /// the live layer is attached here, before the toggle, so the window never
    /// slides in black. In direct mode there is no theater layer at all — the
    /// window's own view mounts from the engine — so only the frame re-assert
    /// and the toggle run here. Also re-asserts the screen frame on every
    /// retry — the window is fully mapped by then, so the content ends up
    /// EXACTLY screen-sized (the 1440×870 race) and the GL surface never
    /// changes size during the slide.
    private func attachVideoThenToggle(window: NSWindow, generation: Int, attempt: Int = 0) {
        if let screen = window.screen ?? NSScreen.main {
            window.setFrame(screen.frame, display: true, animate: false)
        }
        if directMode {
            // Direct mode: no theater layer to attach and no MPVLayerHost
            // container (the window's own view hosts the video from the
            // engine) — the container wait below would time out and dismiss
            // the window. Just toggle once the window is mapped.
            guard !FullscreenTransitionGate.shared.isTransitioning else {
                FullscreenTransitionGate.shared.runWhenIdle { [weak self] in
                    guard let self, self.entryGeneration == generation else { return }
                    self.attachVideoThenToggle(window: window, generation: generation, attempt: attempt)
                }
                return
            }
            print("Cascade player: toggleFullScreen (direct) t=\(Date().timeIntervalSince1970)")
            window.toggleFullScreen(nil)
            return
        }
        if let playerView, snapshotImage == nil, let container = playerContainer, playerView.superview !== container {
            // No ghost snapshot: attach the live layer pre-toggle (old path).
            playerView.removeFromSuperview()
            container.addSubview(playerView)
            playerView.frame = container.bounds
            playerView.autoresizingMask = [.width, .height]
            window.contentView?.layoutSubtreeIfNeeded()
            print("Cascade player: attached video to container (fallback) \(container.bounds)")
        }
        guard playerContainer != nil else {
            // Container not mounted yet (SwiftUI content creation can take a
            // few hundred ms) — wait a beat and retry before toggling. If it
            // never mounts, abort cleanly: the video never left the theater.
            guard attempt < 50 else {
                print("Cascade player: attach aborted — container never mounted")
                self.dismiss()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                guard let self, self.entryGeneration == generation else { return }
                self.attachVideoThenToggle(window: window, generation: generation, attempt: attempt + 1)
            }
            return
        }
        // Never toggle into a live transition (the gate normally serializes
        // present(), but the delayed toggle above can outlive it).
        guard !FullscreenTransitionGate.shared.isTransitioning else {
            FullscreenTransitionGate.shared.runWhenIdle { [weak self] in
                guard let self, self.entryGeneration == generation else { return }
                self.attachVideoThenToggle(window: window, generation: generation, attempt: attempt)
            }
            return
        }
        print("Cascade player: toggleFullScreen t=\(Date().timeIntervalSince1970)")
        window.toggleFullScreen(nil)
    }

    /// Ghost-window handoff at didEnterFullScreen: moves the live mpv layer
    /// from the theater into the fullscreen container and fades it in over
    /// the snapshot. The snapshot is NOT removed upfront — the first frames
    /// of the moved layer are stale (the GL surface reconfigures to the new
    /// size mid-render), and the snapshot masks that "small player stretched"
    /// flash; it is removed when the fade completes. Idempotent (recovery
    /// paths may re-enter).
    private func swapLiveVideoIn(window: NSWindow?) {
        guard snapshotImage != nil, let playerView, let container = playerContainer,
              playerView.superview !== container, container.window != nil else { return }
        playerView.removeFromSuperview()
        container.addSubview(playerView)
        playerView.frame = container.bounds
        playerView.autoresizingMask = [.width, .height]
        playerView.alphaValue = 0
        playerView.mpvRenderUpdate()
        window?.contentView?.layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08
            playerView.animator().alphaValue = 1
        } completionHandler: { [weak self, weak container] in
            // The live layer is opaque at the correct size now — drop the ghost.
            for sub in container?.layer?.sublayers ?? [] where sub.name == "cascadeGhostSnapshot" {
                sub.removeFromSuperlayer()
            }
            self?.snapshotImage = nil
        }
        videoLiveInFullscreen = true
        print("Cascade player: live video swapped in at didEnter \(container.bounds)")
    }

    /// Recovery ladder for a window whose fullscreen toggle was ignored (the
    /// AppKit poisoned-window state): one soft reset (re-register Space
    /// eligibility), then at most two fresh scene windows — the only reliable
    /// cure. If the environment still refuses fullscreen, leave the player
    /// visible and windowed (the controls' fullscreen button stays available).
    private var softResetsDone = 0
    private var reopensDone = 0

    private func recoverIgnoredFullscreen(_ window: NSWindow) {
        guard isActive else { return }
        if softResetsDone == 0 {
            softResetsDone += 1
            let generation = entryGeneration
            let behavior = window.collectionBehavior
            window.orderOut(nil)
            window.collectionBehavior = behavior.union([.fullScreenPrimary])
            window.alphaValue = 0
            window.makeKeyAndOrderFront(nil)
            print("Cascade player: recovery — soft reset")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.entryGeneration == generation else { return }
                self.configureAndEnter(window)
            }
        } else if reopensDone < 2 {
            // Fresh window — the poisoned one cannot be fixed in place.
            reopensDone += 1
            print("Cascade player: recovery — reopening scene (\(reopensDone))")
            reopenScene()
        } else {
            // Give up gracefully: visible windowed player; the controls'
            // fullscreen button remains as a manual fallback.
            print("Cascade player: recovery exhausted — leaving player windowed")
            window.alphaValue = 1
        }
    }

    /// Closes the current scene window and re-presents the session in a fresh
    /// one. `completeDismissal` clears session/callbacks, so capture first.
    private func reopenScene() {
        guard let session else { return }
        let close = onClose
        let dismiss = onDismiss
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let miniaturizeObserver {
            NotificationCenter.default.removeObserver(miniaturizeObserver)
            self.miniaturizeObserver = nil
        }
        onClose = nil
        onDismiss = nil
        dismissWindow?(id: "fullscreenPlayer")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.presentNow(session.player, mpv: session.mpv, title: session.title, subtitle: session.subtitle, appState: session.appState, onClose: close ?? {}, onDismiss: dismiss ?? {}, kind: session.kind, file: session.file)
        }
    }

    /// Toggles the scene window's native fullscreen from the player controls.
    /// While the window is in native fullscreen the button EXITS back to the
    /// theater (same as ESC — the user expects the player, not a windowed
    /// box). When the window is windowed (recovery fallback) it re-attempts
    /// fullscreen. Gate-guarded like present().
    func toggleFullScreen() {
        guard let window = Self.sceneWindow else { return }
        if window.styleMask.contains(.fullScreen) {
            print("Cascade player: exit fullscreen button — dismissing to theater")
            dismiss()
            return
        }
        guard !FullscreenTransitionGate.shared.isTransitioning else {
            FullscreenTransitionGate.shared.runWhenIdle { [weak self] in
                self?.toggleFullScreen()
            }
            return
        }
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.toggleFullScreen(nil)
    }

    /// Closes the full-screen window; the player view returns to the theater
    /// once the scene window actually tears down (sceneDidDisappear).
    func dismiss() {
        guard isActive, !isDismissing else { return }
        isDismissing = true
        print("Cascade player: dismiss t=\(Date().timeIntervalSince1970)")
        clearExitWarning()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let miniaturizeObserver {
            NotificationCenter.default.removeObserver(miniaturizeObserver)
            self.miniaturizeObserver = nil
        }
        dismissWindow?(id: "fullscreenPlayer")
        // Fallback for the (unlikely) case the window close never lands.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.isDismissing else { return }
            self.completeDismissal()
        }
    }

    /// The scene window disappeared — either because we closed it (dismiss) or
    /// the user closed it out-of-band (Cmd+W, Window menu). Both finish here.
    func sceneDidDisappear() {
        guard isDismissing || isActive else { return }
        isDismissing = true
        print("Cascade player: sceneDidDisappear t=\(Date().timeIntervalSince1970)")
        completeDismissal()
    }

    private func completeDismissal() {
        guard isDismissing else { return }
        isDismissing = false
        isActive = false
        session = nil
        directMode = false
        videoLiveInFullscreen = false
        clearExitWarning()
        playerContainer = nil
        snapshotImage = nil
        // Close the scene window if it is still around (the dismissWindow
        // close may not have landed) so the next present() gets a fresh one.
        if let window = Self.sceneWindow {
            window.close()
        }
        // Return the layer view to its original host.
        if let playerView, let hostView {
            playerView.removeFromSuperview()
            hostView.addSubview(playerView)
            playerView.frame = hostView.bounds
            playerView.autoresizingMask = [.width, .height]
            videoLiveInFullscreen = false
            print("Cascade player: returned to theater host=\(hostView.bounds) player=\(playerView.frame)")
            // Nudge the async GL layer to redraw at the new size — without
            // this it can sit on the stale fullscreen-size surface.
            playerView.needsDisplay = true
            playerView.mpvRenderUpdate()
            // Fit-state diagnostics: mpv reconfigures on the FBO change, so
            // sample after the dust settles.
            for delay in [0.5, 1.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak playerView] in
                    guard let playerView else { return }
                    let dw = playerView.getPropertyInt("video-out-params/dw") ?? -1
                    let dh = playerView.getPropertyInt("video-out-params/dh") ?? -1
                    let aw = playerView.getPropertyInt("video-params/w") ?? -1
                    let ah = playerView.getPropertyInt("video-params/h") ?? -1
                    print("Cascade player: post-return t=\(delay) videoOut=\(dw)x\(dh) video=\(aw)x\(ah) view=\(playerView.frame.size)")
                }
            }
        }
        let dismissAction = onDismiss
        onDismiss = nil
        onClose = nil
        dismissAction?()
    }

    private func clearExitWarning() {
        showExitWarning = false
        exitWarningTimer?.invalidate()
        exitWarningTimer = nil
    }
}

// MARK: - SwiftUI Views

/// NSViewRepresentable that hosts the mpv layer inside the fullscreen window.
/// Both video and controls share one SwiftUI render tree, so `.glassEffect()`
/// materials can sample the video as a backdrop.
///
/// The attach is deliberately NOT done here: `PlayerFullScreenWindow` decides
/// when the live layer moves in (ghost-window pattern: the window slides in
/// showing a static snapshot of the theater; the live layer is swapped in at
/// didEnterFullScreen). This view creates the container, registers it on the
/// window object, and shows the ghost snapshot while present.
private struct MPVLayerHost: NSViewRepresentable {
    let playerView: MPVLayerView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.isOpaque = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        let window = PlayerFullScreenWindow.shared
        window.playerContainer = container
        if let snap = window.snapshotImage {
            let snapLayer = CALayer()
            snapLayer.name = "cascadeGhostSnapshot"
            snapLayer.contents = snap
            snapLayer.contentsGravity = .resizeAspect
            snapLayer.frame = container.bounds
            snapLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            container.layer?.addSublayer(snapLayer)
            print("Cascade player: ghost snapshot layer mounted \(snap.width)x\(snap.height)")
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if playerView.superview === nsView {
            playerView.frame = nsView.bounds
        }
    }
}

/// Root SwiftUI view for the fullscreen player.
private struct FullscreenPlayerRoot<Controls: View>: View {
    let mpvView: MPVLayerView?
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        ZStack {
            if let mpvView {
                MPVLayerHost(playerView: mpvView)
                    .ignoresSafeArea()
            }
            controls()
        }
        .background(Color.black)
    }
}

/// Controls overlay wired to full-screen actions.
private struct PlayerFullScreenControls: View {
    @ObservedObject var mpv: MPVController
    let title: String
    let subtitle: String
    @ObservedObject var window: PlayerFullScreenWindow

    var body: some View {
        PlayerControlsView(
            mpv: mpv,
            title: title,
            subtitle: subtitle,
            isFullScreen: true,
            showExitWarning: window.showExitWarning,
            onMinimize: { window.dismiss() },
            onToggleFullScreen: { window.toggleFullScreen() },
            onClose: {
                window.onClose?()
                window.dismiss()
            }
        )
        .overlay {
            PlayerStatusOverlay(mpv: mpv)
        }
    }
}

// MARK: - Fullscreen Player Scene

/// Root view of the "fullscreenPlayer" Window scene. Renders the transferred
/// mpv layer + controls while a session is active; a black window otherwise.
struct FullscreenPlayerSceneView: View {
    @ObservedObject private var window = PlayerFullScreenWindow.shared

    var body: some View {
        Group {
            if let session = window.session, window.isActive {
                switch session.kind {
                case .theater:
                    FullscreenPlayerRoot(mpvView: session.player) {
                        PlayerFullScreenControls(
                            mpv: session.mpv ?? AudioPlayerEngine.shared.mpvController ?? MPVController(),
                            title: session.title,
                            subtitle: session.subtitle,
                            window: window
                        )
                    }
                    .environment(session.appState)
                    .environment(\.colorScheme, .dark)
                case .directVideo:
                    // No theater: the video view mounts here from the engine's
                    // controller as soon as it exists (spinner until then).
                    DirectFullscreenRoot(session: session, window: window)
                case .image:
                    ImageFullscreenRoot(session: session, window: window)
                }
            } else {
                Color.black
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FullscreenWindowConfigurator())
        .onDisappear {
            window.sceneDidDisappear()
        }
    }
}

/// Image-session root ("Open in Full Screen" on an image — no engine): the
/// image fit-to-screen on black, with the file name and a close button in the
/// top-right corner. The view owns the file resolution (cached → instant,
/// uncached → download with progress, theater-style `.task`) — the window
/// slides in over the spinner immediately and the image appears when the
/// bytes land. ESC exits.
private struct ImageFullscreenRoot: View {
    let session: PlayerFullScreenWindow.Session
    @ObservedObject var window: PlayerFullScreenWindow
    @State private var url: URL?
    @State private var failed = false
    @State private var progress: Double = 0

    var body: some View {
        ZStack {
            Group {
                if let url {
                    if (session.title as NSString).pathExtension.lowercased() == "svg" {
                        SVGWebView(url: url)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(24)
                    } else if let nsImage = NSImage(contentsOf: url) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .padding(24)
                    } else {
                        Text("This image cannot be previewed")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                } else if failed {
                    Text("The image could not be downloaded")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.5))
                } else {
                    ZStack {
                        Color.black
                        VStack(spacing: 12) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.large)
                                .tint(.white.opacity(0.7))
                            if progress > 0 && progress < 1 {
                                Text("Downloading \(Int(progress * 100))%")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                    }
                }
            }
            .ignoresSafeArea()

            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(session.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                    Button {
                        window.onClose?()
                        window.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 32, height: 32)
                            .contentShape(Circle())
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .help("Close Viewer")
                }
                .padding(20)

                Spacer()

                if window.showExitWarning {
                    Text("Press ESC to exit full screen")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.bottom, 28)
                }
            }
        }
        .background(Color.black)
        .environment(session.appState)
        .environment(\.colorScheme, .dark)
        .task(id: session.file?.id) {
            guard let file = session.file else { return }
            // Single-cache architecture (item 159): stream via the byte-range
            // server; materialize to scratch only as a fallback.
            if let stream = await VideoStreamingEngine.shared.mpvStreamURL(for: file) {
                url = stream
                return
            }
            do {
                let downloaded = try await DownloadEngine.download(object: file, quiet: true) { _, p in
                    Task { @MainActor in progress = p }
                }
                url = downloaded
            } catch {
                failed = true
            }
        }
    }
}

/// Direct-mode root ("Open in Full Screen" — no theater): mounts the engine's
/// MPVVideoView once the controller exists, with the full controls overlay.
/// The engine drives playback, state and track switching; the title follows
/// currentTrack so Play Next / autoplay-next update it.
private struct DirectFullscreenRoot: View {
    let session: PlayerFullScreenWindow.Session
    @ObservedObject var window: PlayerFullScreenWindow
    @Bindable private var engine = AudioPlayerEngine.shared

    var body: some View {
        ZStack {
            Group {
                if let mpv = engine.mpvController, engine.isMPVPlayback {
                    MPVVideoView(controller: mpv)
                        .id(ObjectIdentifier(mpv))
                } else {
                    ZStack {
                        Color.black
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.large)
                            .tint(.white.opacity(0.7))
                    }
                }
            }
            .ignoresSafeArea()

            if let mpv = engine.mpvController, engine.isMPVPlayback {
                PlayerControlsView(
                    mpv: mpv,
                    title: engine.currentTrack?.name ?? session.title,
                    subtitle: session.subtitle,
                    isFullScreen: true,
                    showExitWarning: window.showExitWarning,
                    onMinimize: { window.dismiss() },
                    onToggleFullScreen: { window.toggleFullScreen() },
                    onClose: {
                        window.onClose?()
                        window.dismiss()
                    }
                )
                .overlay {
                    PlayerStatusOverlay(mpv: mpv)
                }
            }
        }
        .background(Color.black)
        .environment(session.appState)
        .environment(\.colorScheme, .dark)
    }
}

/// One-time configuration of the scene's NSWindow (dark appearance,
/// fullscreen-primary, EDR color space, identifier tag). Entering native
/// fullscreen is NOT done here — it is owned by `PlayerFullScreenWindow`
/// (present → ensureFullscreen), because this view is created at most once
/// per window lifetime and a reuse/no-op here would leave the window
/// non-fullscreen with no way to enter it.
private struct FullscreenWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            context.coordinator.configure(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        func configure(_ window: NSWindow) {
            window.identifier = NSUserInterfaceItemIdentifier(PlayerFullScreenWindow.windowTag)
            window.appearance = NSAppearance(named: .darkAqua)
            window.collectionBehavior = [.fullScreenPrimary]
            let screen = window.screen ?? NSScreen.main
            if let screen, screen.maximumExtendedDynamicRangeColorComponentValue > 1.0 {
                window.colorSpace = .extendedSRGB
            }
            // Invisible from the very first frame — the window must never be
            // seen sitting in the normal Space; `configureAndEnter` toggles it
            // into fullscreen and reveals it when the slide starts. If the
            // toggle never happens, `recoverIgnoredFullscreen`'s fallback
            // restores visibility. Only when a session is active: a window
            // opened by restoration / the Window menu must stay visible.
            if PlayerFullScreenWindow.shared.isActive {
                window.alphaValue = 0
                print("Cascade player: configurator attach t=\(Date().timeIntervalSince1970) alpha=0")
            }
        }
    }
}

/// Invisible view in the MAIN window that hands the scene actions
/// (openWindow / dismissWindow) to PlayerFullScreenWindow, so the player can
/// open and close the full-screen scene from plain AppKit code.
struct FullscreenWindowLink: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                PlayerFullScreenWindow.shared.bind(openWindow: openWindow, dismissWindow: dismissWindow)
            }
    }
}
