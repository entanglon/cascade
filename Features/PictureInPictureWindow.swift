import AppKit
import SwiftUI

/// Wave 2 item 5 — Picture-in-Picture: a floating always-on-top mini window
/// that keeps video playing while the main window is free for other things.
///
/// UX contract (user-confirmed): entering PiP CLOSES the theater — the panel is
/// where playback lives now. The single live `MPVLayerView` is re-parented into
/// the panel (mpv never learns about superview changes; playback continues),
/// and two teardown hazards are handled explicitly:
///   1. The theater's view dismantle would normally destroy the mpv core —
///      `MPVVideoView.dismantleNSViewController` skips cleanup while this
///      window owns the layer.
///   2. `MPVController.playerView` is WEAK and routes every command through
///      the MPVViewController — this window RETAINS that controller-view so
///      play/pause/seek/tracks keep working after the theater unmounts.
///
/// EXPAND (green traffic light, hover expand, or re-opening the file in
/// Cascade) is SEAMLESS: the panel closes, the theater remounts, and
/// `MPVViewController.viewDidLoad` ADOPTS the live layer — same core, same
/// GL surface, zero restart. Closing the red traffic light stops playback.
/// The middle (minimize) button is greyed out. Mutual exclusion with the
/// fullscreen player: both own the same render surface.
@MainActor
final class PictureInPictureWindow {
    static let shared = PictureInPictureWindow()

    private enum Mode {
        case floating   // panel up; this window owns layer + core + controller-view
        case expanding  // panel closed; theater remounting — viewDidLoad will adopt
    }

    private var panel: NSPanel?
    private var mode: Mode = .floating
    private var hostView: NSView?
    private(set) var playerView: MPVLayerView?
    /// Retained on purpose — see contract above (weak on MPVController side).
    private(set) var viewController: MPVViewController?
    private(set) var controller: MPVController?
    private(set) var file: ObjectRecord?
    private weak var appState: AppState?
    private var willCloseObserver: NSObjectProtocol?

    var isActive: Bool { panel != nil || mode == .expanding }

    func isShowing(_ fileID: String) -> Bool { isActive && file?.id == fileID }

    /// Enters PiP with the engine's CURRENT controller/layer. Returns false
    /// when nothing is playing, the fullscreen player owns the layer, or the
    /// layer has no live host. The CALLER closes the theater afterwards.
    @discardableResult
    func presentFromEngine(title: String, file: ObjectRecord?, appState: AppState) -> Bool {
        guard !isActive else { return false }
        guard !PlayerFullScreenWindow.shared.isActive else { return false }
        guard let mpv = AudioPlayerEngine.shared.mpvController,
              let vc = mpv.playerView,
              let layer = vc.playerView as MPVLayerView?,
              layer.window != nil,
              layer.superview != nil else { return false }
        present(player: layer, viewController: vc, mpv: mpv, title: title, file: file, appState: appState)
        return true
    }

    func present(
        player: MPVLayerView,
        viewController: MPVViewController,
        mpv: MPVController,
        title: String,
        file: ObjectRecord?,
        appState: AppState
    ) {
        guard panel == nil, !PlayerFullScreenWindow.shared.isActive else { return }
        guard let host = player.superview else { return }

        hostView = host
        playerView = player
        self.viewController = viewController
        controller = mpv
        self.file = file
        self.appState = appState
        mode = .floating

        let size = NSSize(width: 480, height: 270)
        let content = PiPContentView(frame: NSRect(origin: .zero, size: size), player: player)
        content.onZoom = { [weak self] in self?.expandToTheater() }

        let pip = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        pip.title = title
        pip.titleVisibility = .hidden
        pip.titlebarAppearsTransparent = true
        pip.level = .floating
        pip.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        pip.isMovableByWindowBackground = true
        pip.isReleasedWhenClosed = false
        pip.hidesOnDeactivate = false
        pip.backgroundColor = .black
        pip.contentView = content
        // Keep the floating picture 16:9 no matter how the user stretches it.
        pip.contentAspectRatio = NSSize(width: 16, height: 9)

        // Traffic lights (user request): RED close = exit PiP (stop), YELLOW
        // minimize = greyed out (nothing to miniaturize into), GREEN zoom =
        // seamless expand back into the Cascade theater.
        pip.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        if let zoom = pip.standardWindowButton(.zoomButton) {
            zoom.target = content
            zoom.action = #selector(PiPContentView.handleZoom)
        }

        // The close traffic light must route through the same exit logic as
        // everything else (restore if possible, otherwise stop).
        willCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: pip, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }

        // Bottom-right of the main screen, clear of the dock margin.
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            pip.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 24, y: visible.minY + 24))
        }
        panel = pip
        pip.makeKeyAndOrderFront(nil)
        print("Cascade PiP: entered (\(title))")
    }

    /// Leaves PiP: restores the video into its theater host when one still
    /// exists; otherwise stops playback and destroys the orphaned core.
    func dismiss() {
        guard mode == .floating else { return }
        guard panel != nil else { return }
        guard let player = playerView else { clearAll(); return }

        if let host = hostView, host.window != nil {
            teardownPanelOnly()
            player.removeFromSuperview()
            host.addSubview(player)
            player.frame = host.bounds
            player.autoresizingMask = [.width, .height]
            // Nudge the async GL layer off the stale small-size surface —
            // same nudge the fullscreen dismissal performs.
            player.needsDisplay = true
            player.mpvRenderUpdate()
            print("Cascade PiP: exited, video restored to theater")
            clearAll()
        } else {
            performFullStop()
        }
    }

    /// SEAMLESS expand: close the panel, reopen the theater, and hand the live
    /// layer over to the fresh view controller — the mpv core NEVER stops, so
    /// playback continues without a single buffered frame lost.
    func expandToTheater() {
        guard isActive, let file else { dismiss(); return }
        guard mode == .floating else { return }
        let state = appState
        guard state != nil else { performFullStop(); return }
        mode = .expanding
        teardownPanelOnly()
        state?.theaterFile = file
    }

    /// Called by MPVViewController.viewDidLoad when the expanding theater's
    /// fresh view boots: hands the LIVE layer over (core still running) and
    /// ends PiP ownership. Returns nil unless an expand handoff is in flight.
    func takePendingLayer(for newVC: MPVViewController) -> MPVLayerView? {
        guard mode == .expanding, let live = playerView else { return nil }
        // Command routing moves to the fresh controller-view (the engine's
        // controller.playerView already points at it).
        viewController = newVC
        finishHandoff()
        return live
    }

    // MARK: - Internals

    /// Full stop: engine bookkeeping first (shutdown routes through the
    /// retained VC harmlessly), then destroy the orphaned core with the layer.
    private func performFullStop() {
        AudioPlayerEngine.shared.stop()
        let layer = playerView
        clearAll()
        layer?.cleanup()
        print("Cascade PiP: stopped playback (no theater to return to)")
    }

    private func finishHandoff() {
        mode = .floating
        playerView = nil     // ownership → the theater's VC hierarchy
        controller = nil
        file = nil
        appState = nil
        // NOTE: viewController intentionally kept until clearAll/finish — the
        // fresh VC replaced it above; dropping our strong ref lets it dealloc.
        viewController = nil
    }

    private func teardownPanelOnly() {
        if let willCloseObserver {
            NotificationCenter.default.removeObserver(willCloseObserver)
            self.willCloseObserver = nil
        }
        panel?.orderOut(nil)
        panel = nil
        hostView = nil
    }

    private func clearAll() {
        teardownPanelOnly()
        mode = .floating
        playerView = nil
        viewController = nil
        controller = nil
        file = nil
        appState = nil
    }
}

/// Panel content: the live render view plus a control strip revealed on hover.
final class PiPContentView: NSView {
    var onZoom: (() -> Void)?

    private let controlsHost: NSHostingView<PiPControlsOverlay>

    init(frame: NSRect, player: NSView) {
        controlsHost = NSHostingView(rootView: PiPControlsOverlay(
            onTogglePlay: { AudioPlayerEngine.shared.togglePlayPause() }
        ))
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.isOpaque = true

        player.frame = bounds
        player.autoresizingMask = [.width, .height]
        addSubview(player)

        controlsHost.isHidden = true
        controlsHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controlsHost)
        NSLayoutConstraint.activate([
            controlsHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            controlsHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            controlsHost.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    required init?(coder: NSCoder) { fatalError("PiPContentView is code-only") }

    override func mouseEntered(with event: NSEvent) { controlsHost.isHidden = false }
    override func mouseExited(with event: NSEvent) { controlsHost.isHidden = true }

    /// Target of the GREEN traffic-light button — seamless expand.
    @objc func handleZoom() { onZoom?() }
}

/// Bottom strip shown on hover: transport + title. Expand lives on the green
/// traffic light (user request); close lives on the red one.
private struct PiPControlsOverlay: View {
    var onTogglePlay: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTogglePlay) {
                Image(systemName: AudioPlayerEngine.shared.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(AudioPlayerEngine.shared.isPlaying ? "Pause" : "Play")

            Text("Playing in Picture-in-Picture")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .shadow(radius: 2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .bottom, endPoint: .top)
                .ignoresSafeArea()
        )
        .frame(maxWidth: .infinity)
    }
}