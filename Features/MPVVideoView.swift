import SwiftUI
import AppKit
import OpenGL.GL
import MPVKit
import Combine
import Darwin
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
        // Updates handled via controller
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
        // Optimistic update
        self.progress = value
        let targetTime = value * duration
        if isHeadless {
            headlessView?.seek(absoluteSeconds: targetTime)
        } else {
            playerView?.seek(absolute: targetTime)
        }
    }

    func seek(absolute time: Double) {
        if duration > 0 { self.progress = time / duration }
        if isHeadless {
            headlessView?.seek(absoluteSeconds: time)
        } else {
            playerView?.seek(absolute: time)
        }
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
                    self.isBuffering = buff
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
    private static let mpvLogger = Logger(subsystem: "com.xcloud.app", category: "mpv")

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
        PlayerFullScreenWindow.shared.dismissIfPresented(for: self)

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
        mpv_set_property_string(mpv, "cache-secs", "20")
        mpv_set_property_string(mpv, "demuxer-max-bytes", "104857600")
        mpv_set_property_string(mpv, "demuxer-max-back-bytes", "26214400")
        mpv_set_property_string(mpv, "demuxer-readahead-secs", "20")
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
        mpv_set_property_string(mpv, "referrer", "https://xcloud.app/")

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

    private func getPropertyInt(_ name: String) -> Int? {
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

    /// Appends a line to /tmp/xcloud-mpv-telemetry.log so playback stats survive
    /// no matter how the app was launched (open(1) swallows stdout, and the
    /// unified log can drop high-frequency lines under mpv's message load).
    private func appendTelemetryFile(_ line: String) {
        let path = "/tmp/xcloud-mpv-telemetry.log"
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
/// is hosted on top, and Escape is two-step: first press shows "Press Esc again to
/// exit", the second exits full screen back to the windowed player.
final class PlayerFullScreenWindow: NSObject, ObservableObject {
    static let shared = PlayerFullScreenWindow()

    @Published private(set) var isActive = false
    @Published var showExitWarning = false
    var onClose: (() -> Void)?

    private var window: NSWindow?
    private weak var playerView: MPVLayerView?
    private weak var hostView: NSView?
    private var keyMonitor: Any?
    private var exitWarningTimer: Timer?
    private var controlsHost: NSHostingView<AnyView>?
    private var onDismiss: (() -> Void)?

    private override init() {
        super.init()
    }

    func present(
        _ player: MPVLayerView,
        mpv: MPVController,
        title: String,
        subtitle: String,
        appState: AppState,
        onClose: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        guard !isActive, window == nil else { return }
        isActive = true
        playerView = player
        hostView = player.superview
        self.onClose = onClose
        self.onDismiss = onDismiss

        let screen = player.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let win = NSWindow(
            contentRect: screen?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.level = .mainMenu
        win.backgroundColor = .black
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.fullScreenAuxiliary, .stationary]
        // Full-screen player window must also opt into the extended-range color
        // space on HDR displays, otherwise HDR content is clipped there. On SDR
        // screens leave it alone (extended-range compositing costs performance).
        if (screen?.maximumExtendedDynamicRangeColorComponentValue ?? 0) > 1.0 {
            win.colorSpace = .extendedSRGB
        }

        player.removeFromSuperview()
        win.contentView = player
        player.frame = win.contentView?.bounds ?? .zero
        player.autoresizingMask = [.width, .height]

        // Controls overlay — the same PlayerControlsView chrome, hosted on top of
        // the re-parented layer. Transparent root, so the video shows through.
        // The window is NOT part of the SwiftUI scene, so the environment must
        // be injected manually — PlayerControlsView reads @Environment(AppState.self),
        // and a missing environment value asserts (EXC_BREAKPOINT on layout).
        let controls = PlayerFullScreenControls(
            mpv: mpv,
            title: title,
            subtitle: subtitle,
            window: self
        )
        let hosting = NSHostingView(rootView: AnyView(controls.environment(appState)))
        hosting.frame = win.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        win.contentView?.addSubview(hosting)
        controlsHost = hosting

        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // ESC is two-step: first press shows the exit hint, second exits full
        // screen; swallow the key so nothing else reacts.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                if self.showExitWarning {
                    self.clearExitWarning()
                    self.dismiss()
                } else {
                    self.showExitWarning = true
                    self.exitWarningTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                        Task { @MainActor in
                            self?.showExitWarning = false
                        }
                    }
                }
                return nil
            }
            return event
        }
    }

    func dismiss() {
        dismissIfPresented(for: nil)
    }

    /// Closes the full-screen window and puts the player view back into its original
    /// host view. `player` may be passed to match the current view (teardown path).
    func dismissIfPresented(for player: MPVLayerView?) {
        guard isActive, let win = window else { return }
        isActive = false
        window = nil
        clearExitWarning()
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        controlsHost?.removeFromSuperview()
        controlsHost = nil
        if let playerView, let hostView, player == nil || player === playerView {
            playerView.removeFromSuperview()
            hostView.addSubview(playerView)
            playerView.frame = hostView.bounds
            playerView.autoresizingMask = [.width, .height]
        }
        win.close()
        let dismissAction = onDismiss
        onDismiss = nil
        onClose = nil
        NSApp.activate(ignoringOtherApps: true)
        dismissAction?()
    }

    private func clearExitWarning() {
        showExitWarning = false
        exitWarningTimer?.invalidate()
        exitWarningTimer = nil
    }
}

/// SwiftUI overlay hosted in the full-screen player window. Reuses the same
/// PlayerControlsView chrome as the windowed player, wired to full-screen actions:
/// minimize / full-screen toggle exit full screen, close stops playback and closes
/// the theater.
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
            onToggleFullScreen: { window.dismiss() },
            onClose: {
                window.onClose?()
                window.dismiss()
            }
        )
        .overlay {
            // Buffer loader — the windowed theater shows it over the video; the
            // full-screen window must too (its layer is re-parented here).
            PlayerStatusOverlay(mpv: mpv)
        }
    }
}
