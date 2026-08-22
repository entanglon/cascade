import AppKit
import SwiftUI

/// Wave 2 item 5 — Picture-in-Picture: a floating always-on-top mini window
/// that keeps video playing while the main window is used for other things.
///
/// Mechanism mirrors PlayerFullScreenWindow's ghost-free path: the SINGLE live
/// `MPVLayerView` is physically re-parented into the panel (mpv never learns
/// about superview changes — playback continues untouched), and moving it back
/// restores the theater exactly like completeDismissal does. Mutual exclusion
/// with the fullscreen player: both own the same view.
///
/// Lifecycle contract: entering PiP keeps the THEATER OPEN (the view hierarchy
/// must stay mounted — its dismantle destroys the mpv core). Theater exit paths
/// dismiss PiP first so the layer is back home before any teardown. Closing the
/// PiP panel returns the video to the theater; if the theater's host is gone by
/// then, playback stops instead of leaking an orphaned surface.
@MainActor
final class PictureInPictureWindow {
    static let shared = PictureInPictureWindow()

    private var panel: NSPanel?
    private var hostView: NSView?
    private(set) var playerView: MPVLayerView?
    private(set) var controller: MPVController?
    private var willCloseObserver: NSObjectProtocol?

    var isActive: Bool { panel != nil }

    /// Enters PiP with the engine's CURRENT controller/layer. Returns false
    /// when nothing is playing, the fullscreen player owns the layer, or the
    /// layer has no live host to return to later.
    @discardableResult
    func presentFromEngine(title: String) -> Bool {
        guard !isActive else { return false }
        guard !PlayerFullScreenWindow.shared.isActive else { return false }
        guard let mpv = AudioPlayerEngine.shared.mpvController,
              let layer = mpv.playerView?.playerView,
              layer.window != nil,
              layer.superview != nil else { return false }
        present(player: layer, mpv: mpv, title: title)
        return true
    }

    func present(player: MPVLayerView, mpv: MPVController, title: String) {
        guard panel == nil, !PlayerFullScreenWindow.shared.isActive else { return }
        guard let host = player.superview else { return }
        hostView = host
        playerView = player
        controller = mpv

        let size = NSSize(width: 480, height: 270)
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        content.layer?.isOpaque = true

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
        // The close traffic light must RESTORE, not destroy: route it through
        // the same dismiss path as every other exit.
        willCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: pip, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }

        // Move the live render view into the panel — mpv keeps decoding; only
        // its pixel destination changes (same handoff the fullscreen player
        // uses at didEnterFullScreen).
        player.removeFromSuperview()
        content.addSubview(player)
        player.frame = content.bounds
        player.autoresizingMask = [.width, .height]
        player.needsDisplay = true
        player.mpvRenderUpdate()

        // Bottom-right of the main screen, clear of the dock margin.
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            let origin = NSPoint(
                x: visible.maxX - size.width - 24,
                y: visible.minY + 24
            )
            pip.setFrameOrigin(origin)
        }
        panel = pip
        pip.makeKeyAndOrderFront(nil)
        print("Cascade PiP: entered (\(title))")
    }

    /// Leaves PiP: the layer returns to its theater host and playback continues.
    /// If the theater host is gone (window closed meanwhile), playback stops —
    /// there is nothing left to return to.
    func dismiss() {
        guard let panel else { return }
        if let willCloseObserver {
            NotificationCenter.default.removeObserver(willCloseObserver)
            self.willCloseObserver = nil
        }
        defer {
            panel.orderOut(nil)
            self.panel = nil
            hostView = nil
            playerView = nil
            controller = nil
        }

        guard let player = playerView else { return }
        if let host = hostView, host.window != nil {
            player.removeFromSuperview()
            host.addSubview(player)
            player.frame = host.bounds
            player.autoresizingMask = [.width, .height]
            // Nudge the async GL layer off the stale small-size surface —
            // same nudge the fullscreen dismissal performs.
            player.needsDisplay = true
            player.mpvRenderUpdate()
            print("Cascade PiP: exited, video restored to theater")
        } else {
            AudioPlayerEngine.shared.stop()
            print("Cascade PiP: exited, theater gone — playback stopped")
        }
    }
}