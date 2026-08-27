#if os(iOS)
import UIKit
import MPVKit
import os

/// iOS mpv video player — UIKit UIView subclass using OpenGL ES rendering.
/// Mirrors the macOS MPVLayerView but adapted for iOS's EAGLContext.
final class MPVPlayerView: UIView {
    private var mpv: OpaquePointer?
    private var mpvGL: OpaquePointer?
    private var eaglContext: EAGLContext?
    private var displayLink: CADisplayLink?
    private var renderBuffer: GLuint = 0
    private var framebuffer: GLuint = 0
    private var colorRenderBuffer: GLuint = 0
    private var backingWidth: GLint = 0
    private var backingHeight: GLint = 0
    private var isStopped = false
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Cascade", category: "MPVPlayerView")

    var onEndReached: (() -> Void)?
    var onPlaybackStateChange: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupMPV()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupMPV()
    }

    deinit {
        stop()
    }

    // MARK: - Setup

    private func setupMPV() {
        guard mpv == nil else { return }

        mpv = mpv_create()
        guard let mpv else { return }

        mpv_set_option_string(mpv, "terminal", "yes")
        mpv_set_option_string(mpv, "load-scripts", "no")
        mpv_set_option_string(mpv, "load-osd-console", "no")
        mpv_set_option_string(mpv, "load-stats-overlay", "no")
        mpv_set_option_string(mpv, "load-auto-profiles", "no")
        mpv_set_option_string(mpv, "ytdl", "no")
        mpv_set_option_string(mpv, "osc", "no")
        mpv_set_option_string(mpv, "vd-lavc-dr", "no")
        mpv_set_option_string(mpv, "hwdec", "videotoolbox")
        mpv_set_option_string(mpv, "vo", "libmpv")
        mpv_set_option_string(mpv, "ao", "avfoundation")
        mpv_set_option_string(mpv, "input-vo-keyboard", "no")
        mpv_set_option_string(mpv, "force-window", "immediate")

        mpv_set_wakeup_callback(mpv, { ctx in
            guard let ctx else { return }
            let view = Unmanaged<MPVPlayerView>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { view.handleMPVEvents() }
        }, Unmanaged.passUnretained(self).toOpaque())

        let err = mpv_initialize(mpv)
        guard err >= 0 else {
            log.error("mpv_initialize failed: \(err)")
            return
        }

        setupOpenGL()
        startDisplayLink()
    }

    private func setupOpenGL() {
        eaglContext = EAGLContext(api: .openGLES3) ?? EAGLContext(api: .openGLES2)
        guard let eaglContext else {
            log.error("Failed to create EAGLContext")
            return
        }
        EAGLContext.setCurrent(eaglContext)

        glGenFramebuffers(1, &framebuffer)
        glGenRenderbuffers(1, &colorRenderBuffer)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorRenderBuffer)
        eaglContext.renderbufferStorage(fromDrawable: layer)
        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_RENDERBUFFER), colorRenderBuffer)
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_WIDTH), &backingWidth)
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_HEIGHT), &backingHeight)

        var api = MPVRenderAPIType(rawValue: UInt32(MPV_RENDER_API_TYPE_OPENGL_ES))
        var initParams = mpv_opengl_init_params(
            get_proc_address: { _, name in
                name.withCString { glGetString(UInt32(bitPattern: $0)) }
            },
            get_proc_address_ctx: nil,
            log_level: MPV_LOG_LEVEL_WARN
        )
        var params = [
            mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: &api)),
            mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: &initParams),
            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
        ]
        let res = mpv_render_context_create(&mpvGL, mpv, &params)
        guard res >= 0 else {
            log.error("mpv_render_context_create failed: \(res)")
            return
        }

        mpv_render_context_set_update_callback(mpvGL, { ctx in
            guard let ctx else { return }
            let view = Unmanaged<MPVPlayerView>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { view.requestRender() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: - Display Link

    private func startDisplayLink() {
        displayLink = CADisplayLink(target: self, selector: #selector(renderFrame))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 120, preferred: 60)
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc private func renderFrame() {
        guard let mpvGL, let eaglContext else { return }
        EAGLContext.setCurrent(eaglContext)

        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorRenderBuffer)

        var fbo = mpv_opengl_fbo(
            fbo: Int32(framebuffer),
            w: Int32(backingWidth),
            h: Int32(backingHeight),
            internal_format: 0
        )
        var flip: Int32 = 1
        var fboPtr = UnsafeMutableRawPointer(&fbo).assumingMemoryBound(to: Int32.self)
        var flipPtr = UnsafeMutableRawPointer(&flip)

        withUnsafeMutablePointer(to: &fboPtr) { fboPtrArg in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fboPtrArg),
                mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipPtr),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
            ]
            mpv_render_context_render(mpvGL, &params)
        }

        eaglContext.presentRenderbuffer(GLenum(GL_RENDERBUFFER))
    }

    private func requestRender() {
        displayLink?.isPaused = false
    }

    // MARK: - Playback Controls

    func play(_ url: URL) {
        let urlString = url.absoluteString.cString(using: .utf8)!
        var args: [UnsafePointer<CChar>?] = ["loadfile".withCString(strdup), urlString.withCString(strdup), nil]
        mpv_command(mpv, &args)
        args.forEach { if let p = $0 { free(p) } }
    }

    func pause() { mpv_set_property_string(mpv, "pause", "yes") }
    func resume() { mpv_set_property_string(mpv, "pause", "no") }

    func seek(to seconds: Double) {
        mpv_set_property_number(mpv, "time-pos", seconds)
    }

    var currentTime: Double {
        mpv_get_property_number(mpv, "time-pos") ?? 0
    }

    var duration: Double {
        mpv_get_property_number(mpv, "duration") ?? 0
    }

    var isPaused: Bool {
        mpv_get_property_string(mpv, "pause") == "yes"
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        displayLink?.invalidate()
        displayLink = nil
        if let mpvGL {
            mpv_render_context_set_update_callback(mpvGL, { _ in }, nil)
            mpv_render_context_free(mpvGL)
        }
        if let mpv {
            mpv_destroy(mpv)
        }
        EAGLContext.setCurrent(nil)
        eaglContext = nil
    }

    // MARK: - Events

    private func handleMPVEvents() {
        while let mpv {
            let event = mpv_wait_event(mpv, 0)
            guard event.pointee.event_type != MPV_EVENT_NONE else { break }
            switch event.pointee.event_type {
            case MPV_EVENT_END_FILE:
                let reason = event.pointee.data?.assumingMemoryBound(to: mpv_end_file_reason.self).pointee
                if reason == MPV_END_FILE_REASON_EOF {
                    onEndReached?()
                }
            default:
                break
            }
        }
    }

    // MARK: - Layer

    override class var layerClass: AnyClass { CAEAGLLayer.self }
}
#endif
