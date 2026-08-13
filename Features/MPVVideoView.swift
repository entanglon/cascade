import SwiftUI
import AppKit
import OpenGL.GL
import MPVKit
import Combine
import Darwin

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

    @Published var audioTracks: [Track] = []
    @Published var subtitleTracks: [Track] = []

    var onPlaybackError: (() -> Void)?
    weak var playerView: MPVViewController?

    /// Set when play(url:) is called before the MPVViewController exists (the engine
    /// creates the controller first; the view attaches later). Cleared once played.
    private(set) var pendingURL: URL?

    func play(url: URL) {
        self.isUserPaused = false
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
        playerView?.resume()
    }

    func pause() {
        self.isUserPaused = true
        playerView?.pause()
    }

    func stop() {
        self.isUserPaused = false
        playerView?.stop()
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
        playerView?.seek(absolute: targetTime)
    }

    func seek(absolute time: Double) {
        if duration > 0 { self.progress = time / duration }
        playerView?.seek(absolute: time)
    }

    func seek(relative seconds: Double) {
        playerView?.seek(relative: seconds)
    }

    func setVolume(_ value: Double) {
        playerView?.setVolume(value)
        volume = value
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
        guard let tracks = playerView?.getTracks() else { return }

        DispatchQueue.main.async {
            self.audioTracks = tracks.filter { $0.type == "audio" }
            self.subtitleTracks = tracks.filter { $0.type == "sub" }
        }
    }

    func selectTrack(_ track: Track) {
        playerView?.selectTrack(track)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.fetchTracks()
        }
    }

    func addExternalSubtitle(url: String, title: String) {
        playerView?.addExternalSubtitle(url: url, title: title)
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
        self.playerView.setupMpv()

        self.playerView.onPropertyChange = { [weak self] name, value in
            self?.delegate?.handlePropertyChange(name: name, value: value)
        }

        self.playerView.onPlaybackError = { [weak self] in
            print("[MPV] Playback error detected")
            DispatchQueue.main.async {
                self?.delegate?.onPlaybackError?()
            }
        }

        let vol = self.playerView.getVolume()
        DispatchQueue.main.async {
            self.delegate?.volume = vol / 100.0
        }

        // The engine may have created the controller and called play(url:) before
        // this view existed — pick the pending URL up now that mpv is initialized.
        if let pending = self.delegate?.pendingURL {
            self.delegate?.clearPending()
            self.delegate?.play(url: pending)
        }
    }

    func play(_ url: URL) { playerView.loadFile(url) }
    func pause() { playerView.setPause(true) }
    func resume() { playerView.setPause(false) }
    func stop() { playerView.stop() }

    func seek(absolute seconds: Double) { playerView.seek(absoluteSeconds: seconds) }
    func seek(relative seconds: Double) { playerView.seek(relativeSeconds: seconds) }

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

    override init() {
        super.init()
        self.isAsynchronous = true
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
        let attributes: [CGLPixelFormatAttribute] = [
            kCGLPFAAccelerated,
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
            kCGLPFADoubleBuffer,
            kCGLPFAColorSize, CGLPixelFormatAttribute(32),
            kCGLPFADepthSize, CGLPixelFormatAttribute(24),
            CGLPixelFormatAttribute(0)
        ]
        var pix: CGLPixelFormatObj?
        var npix: GLint = 0
        CGLChoosePixelFormat(attributes, &pix, &npix)
        return pix!
    }

    override func copyCGLContext(forPixelFormat pixelFormat: CGLPixelFormatObj) -> CGLContextObj {
        var ctx: CGLContextObj?
        CGLCreateContext(pixelFormat, nil, &ctx)
        return ctx!
    }

    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat: CGLPixelFormatObj, forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        return true
    }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat: CGLPixelFormatObj, forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        CGLSetCurrentContext(ctx)

        guard let owner = ownerView, owner.mpv != nil else {
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
                }
            }
        }

        glFlush()
    }
}

// MARK: - Hosting NSView Backed by CAOpenGLLayer
final class MPVLayerView: NSView {
    private(set) var mpv: OpaquePointer!
    var mpvGL: OpaquePointer!
    private var pendingURL: URL?
    private var displayLink: CVDisplayLink?
    let mpvLayer = MPVLayer()

    var queue = DispatchQueue(label: "mpv", qos: .userInteractive)
    var onPropertyChange: ((String, Any) -> Void)?
    var onPlaybackError: (() -> Void)?
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

        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }

        if let glCtx = self.mpvGL {
            mpv_render_context_set_update_callback(glCtx, { _ in }, nil)
            mpv_render_context_free(glCtx)
            self.mpvGL = nil
        }
        if let handle = self.mpv {
            mpv_terminate_destroy(handle)
            self.mpv = nil
        }
    }

    func cleanup() {
        teardown()
    }

    deinit { cleanup() }

    func setupContext() {
        // Context created natively by CAOpenGLLayer
    }

    func setupMpv() {
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

        mpv_set_property_string(mpv, "user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
        mpv_set_property_string(mpv, "referrer", "https://xcloud.app/")

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
        mpv_observe_property(mpv, 0, "volume", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "cache-buffering-state", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "seeking", MPV_FORMAT_FLAG)

        mpv_set_wakeup_callback(self.mpv, mpvWakeUp, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        startEventLoop()
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

        if let pending = pendingURL {
            print("[MPV] Context ready! Now loading pending URL: \(pending.lastPathComponent)")
            let urlToLoad = pending
            pendingURL = nil
            command("loadfile", urlToLoad.absoluteString)
        }
    }

    func loadFile(_ url: URL) {
        if mpvGL == nil {
            print("[MPV] Deferring loadFile until render context is initialized: \(url.lastPathComponent)")
            pendingURL = url
        } else {
            pendingURL = nil
            command("loadfile", url.absoluteString)
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
                _ = mpv_command(mpv, buffer.baseAddress)
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
                    print("[MPV TELEMETRY] cache:\(String(format: "%.1f", cacheSecs))s | mistimed:\(mistimed) | voDrop:\(voDrop) | decDrop:\(decDrop) | hwdec:\(hwdec)")
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
                    }
                } else if eventId == MPV_EVENT_END_FILE {
                    let endFile = event.pointee.data.assumingMemoryBound(to: mpv_event_end_file.self)
                    if endFile.pointee.reason == MPV_END_FILE_REASON_ERROR {
                        print("[MPV] Error: End File Reason ERROR")
                        DispatchQueue.main.async { self.onPlaybackError?() }
                    }
                }
            }
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
