#if os(iOS)
import UIKit
import MPVKit
import OpenGLES
import QuartzCore
import os

/// iOS mpv video player — UIKit UIView subclass using OpenGL ES rendering.
final class MPVPlayerView: UIView {
    private var mpv: OpaquePointer?
    private var mpvGL: OpaquePointer?
    private var eaglContext: EAGLContext?
    private var displayLink: CADisplayLink?
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

        guard let eaglLayer = self.layer as? CAEAGLLayer else {
            log.error("Layer is not CAEAGLLayer")
            return
        }
        eaglLayer.drawableProperties = [
            kEAGLDrawablePropertyRetainedBacking: false,
            kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8
        ]
        eaglContext.renderbufferStorage(Int(GL_RENDERBUFFER), from: eaglLayer)

        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_RENDERBUFFER), colorRenderBuffer)
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_WIDTH), &backingWidth)
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_HEIGHT), &backingHeight)

        var initParams = mpv_opengl_init_params(
            get_proc_address: { _, name in
                guard let name = name else { return nil }
                return UnsafeMutableRawPointer(bitPattern: Int(bitPattern: dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)))
            },
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
                guard res >= 0 else {
                    self.log.error("mpv_render_context_create failed: \(res)")
                    return
                }
            }
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

        withUnsafeMutablePointer(to: &fbo) { fboPtr in
            withUnsafeMutablePointer(to: &flip) { flipPtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                mpv_render_context_render(mpvGL, &params)
            }
        }

        eaglContext.presentRenderbuffer(Int(GL_RENDERBUFFER))
    }

    private func requestRender() {
        displayLink?.isPaused = false
    }

    // MARK: - Playback Controls

    func play(_ url: URL) {
        command("loadfile", url.absoluteString)
    }

    func pause() { mpv_set_property_string(mpv, "pause", "yes") }
    func resume() { mpv_set_property_string(mpv, "pause", "no") }

    func seek(to seconds: Double) {
        mpv_set_property_string(mpv, "time-pos", "\(seconds)")
    }

    var currentTime: Double {
        getPropertyDouble("time-pos") ?? 0
    }

    var duration: Double {
        getPropertyDouble("duration") ?? 0
    }

    var isPaused: Bool {
        getPropertyString("pause") == "yes"
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

    // MARK: - MPV Helpers

    private func command(_ args: String...) {
        guard mpv != nil else { return }
        var cStrings: [UnsafePointer<CChar>?] = []
        var keepAlive: [Any] = []
        for string in args {
            let utf8 = string.utf8CString
            let ptrCopy = UnsafeMutablePointer<CChar>.allocate(capacity: utf8.count)
            utf8.withUnsafeBufferPointer { ptrCopy.initialize(from: $0.baseAddress!, count: utf8.count) }
            cStrings.append(UnsafePointer(ptrCopy))
            keepAlive.append(ptrCopy)
        }
        cStrings.append(nil)
        cStrings.withUnsafeMutableBufferPointer { buffer in
            _ = mpv_command_async(mpv, 0, buffer.baseAddress)
        }
        for case let ptr as UnsafeMutablePointer<CChar> in keepAlive { ptr.deallocate() }
    }

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

    // MARK: - Events

    private func handleMPVEvents() {
        guard let mpv else { return }
        while true {
            guard let event = mpv_wait_event(mpv, 0) else { break }
            let eventId = event.pointee.event_id
            if eventId == MPV_EVENT_NONE { break }
            if eventId == MPV_EVENT_END_FILE {
                if let data = event.pointee.data {
                    let reason = data.assumingMemoryBound(to: mpv_end_file_reason.self).pointee
                    if reason == MPV_END_FILE_REASON_EOF {
                        onEndReached?()
                    }
                }
            }
        }
    }

    // MARK: - Layer

    override class var layerClass: AnyClass { CAEAGLLayer.self }
}
#endif
