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
/// Hover over the panel for controls: play/pause · title · expand back.
/// Expand (or re-opening the same file in Cascade) tears the floating core
/// down cleanly and reopens the theater resuming at the exact position.
/// Closing the panel stops playback entirely. Mutual exclusion with the
/// fullscreen player: both own the same render surface.
@MainActor
final class PictureInPictureWindow {
    static let shared = PictureInPictureWindow()

    private var panel: NSPanel?
    private var hostView: NSView?
    private(set) var playerView: MPVLayerView?
    /// Retained on purpose — see contract above (weak on MPVController side).
    private(set) var viewController: MPVViewController?
    private(set) var controller: MPVController?
    private(set) var file: ObjectRecord?
    private weak var appState: AppState?
    private var willCloseObserver: NSObjectProtocol?

    var isActive: Bool { panel != nil }

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

        let size = NSSize(width: 480, height: 270)
        let content = PiPContentView(frame: NSRect(origin: .zero, size: size), player: player)

        let pip = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
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

    /// Called by AudioPlayerEngine.play() when the file being opened is the one
    /// currently floating here: tears the panel down (full stop) and returns
    /// the position to resume at, so "re-opening" behaves as EXPAND. Returns
    /// nil when this window isn't showing that file.
    func takeOverForReopen(fileID: String) -> Double? {
        guard isActive, file?.id == fileID else { return nil }
        let pos = controller?.timePos ?? 0
        performFullStop()
        return pos
    }

    /// Hover/expand action: leave PiP back INTO a reopened theater — stops the
    /// floating core and arms its position so the fresh stream resumes exactly
    /// where the panel left off.
    func expandToTheater() {
        guard isActive, let file else { dismiss(); return }
        let pos = controller?.timePos ?? 0
        let state = appState
        performFullStop()
        AudioPlayerEngine.shared.resumeVideoAt(pos)
        state?.theaterFile = file
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
        playerView = nil
        viewController = nil
        controller = nil
        file = nil
        appState = nil
    }
}

/// Panel content: the live render view plus a control strip revealed on hover.
private final class PiPContentView: NSView {
    private let controlsHost: NSHostingView<PiPControlsOverlay>

    init(frame: NSRect, player: NSView) {
        controlsHost = NSHostingView(rootView: PiPControlsOverlay(
            title: "",
            onTogglePlay: { AudioPlayerEngine.shared.togglePlayPause() },
            onExpand: { PictureInPictureWindow.shared.expandToTheater() }
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
}

/// Bottom strip shown on hover: transport + expand back into Cascade.
private struct PiPControlsOverlay: View {
    var title: String
    var onTogglePlay: () -> Void
    var onExpand: () -> Void

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

            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .shadow(radius: 2)

            Spacer(minLength: 0)

            Button(action: onExpand) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Back to Cascade")
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