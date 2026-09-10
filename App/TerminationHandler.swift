import AppKit

final class TerminationHandler: NSObject, NSApplicationDelegate {
    /// Share links (`cascade://share…`) delivered by the OS while the app was
    /// running OR while it was still launching. AppState drains this list, so
    /// every link is processed exactly once (warm delivery via the notification
    /// below; cold-launch delivery drained once post-auth setup completes).
    static var pendingOpenURLs: [URL] = []
    /// Posted whenever the OS hands the app a URL, so the running scene can
    /// drain `pendingOpenURLs` immediately. The list — not the notification's
    /// payload — is the source of truth (it also covers URLs that arrived
    /// before any observer was attached).
    static let didOpenURL = Notification.Name("cascadeDidOpenURL")

    /// Posted when a URL arrived but the main window could not be found (the
    /// SwiftUI scene was torn down — e.g. the window was closed while another
    /// window existed, or the scene failed to restore). `CascadeApp` observes
    /// this and calls `openWindow(id: "main")` to recreate the scene.
    static let recreateMainWindow = Notification.Name("cascadeRecreateMainWindow")

    /// Distributed notification used by a duplicate instance to tell the running
    /// one that share links are waiting in the handoff file. Scoped to the bundle
    /// id so the dev and production builds never hand links to each other.
    private static var handoffNotificationName: Notification.Name {
        Notification.Name((Bundle.main.bundleIdentifier ?? "com.cascade.app") + ".handoffURLs")
    }
    private static let handoffFileName = "handoff-urls.json"

    // MARK: - Single-instance guard

    /// Another Cascade process already running (same bundle id, different pid)?
    /// Stale URL-scheme registrations can make LaunchServices START a second copy
    /// of the app when a share link is opened (e.g. an older build's app bundle
    /// is still registered as the `cascade://` handler). Two instances then fight
    /// over the window: one window vanishes, the app looks stuck and won't quit.
    private static func otherRunningInstance() -> NSRunningApplication? {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != me }
    }

    private static func handoffFileURL() -> URL? {
        let fm = FileManager.default
        guard let support = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = support.appendingPathComponent(AppPaths.dataFolder, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(handoffFileName)
    }

    /// Hands share links to the already-running instance: appends them to the
    /// shared handoff file, pokes that instance over the distributed
    /// notification center, activates it, then exits this duplicate copy.
    private static func handOff(urls: [URL], to other: NSRunningApplication) {
        if let file = handoffFileURL() {
            var stored: [String] = []
            if let data = try? Data(contentsOf: file),
               let decoded = try? JSONDecoder().decode([String].self, from: data) {
                stored = decoded
            }
            stored.append(contentsOf: urls.map(\.absoluteString))
            if let data = try? JSONEncoder().encode(stored) {
                try? data.write(to: file)
            }
        }
        // Post twice: the running instance may still be registering its observer.
        DistributedNotificationCenter.default().post(name: handoffNotificationName, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            DistributedNotificationCenter.default().post(name: handoffNotificationName, object: nil)
        }
        // NO activation from the duplicate: ANY programmatic activate (including
        // .activateAllWindows / .activateIgnoringOtherApps) can yank a
        // full-screen window out of its Space. Activation is the running
        // instance's decision alone — its drainHandoff → raiseMainWindow raises
        // its own window (full-screen aware). We just deliver the payload and
        // exit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            _exit(0)
        }
    }

    /// The running instance: pull any links a duplicate copy left in the handoff
    /// file, queue them, and process them like any OS-delivered link. Also raises
    /// THIS instance's own window — the URL was delivered to a copy that is now
    /// exiting, so only this process can bring the real window forward.
    private func drainHandoff() {
        guard let file = Self.handoffFileURL() else { return }
        guard let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode([String].self, from: data),
              !stored.isEmpty else { return }
        try? FileManager.default.removeItem(at: file)
        Self.pendingOpenURLs.append(contentsOf: stored.compactMap(URL.init(string:)))
        NotificationCenter.default.post(name: Self.didOpenURL, object: nil)
        // Same re-entry net as direct delivery: arm while the window is still
        // full screen (the duplicate no longer activates us — we raise our own
        // window).
        FullScreenReentryGuard.shared.armIfNeeded(NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.canBecomeKey && $0.isVisible && !$0.isSheet }))
        raiseMainWindow()
    }

    // MARK: - App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Appearance-aware Dock icon (90%-footprint artwork both modes).
        AppIconSwitcher.shared.applyIcon()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleHandoffNotification),
            name: Self.handoffNotificationName,
            object: nil
        )
        // Re-assert ownership of the cascade:// scheme on EVERY launch. Stale
        // copies of the app (old DerivedData builds, DMG test installs) keep
        // their LaunchServices registration and make the browser START a second
        // instance instead of delivering the link to this one — the running
        // instance then never sees application(_:open:) and the window is never
        // raised. Whichever copy runs now claims the scheme, so this self-heals
        // even if a stale bundle is ever re-registered.
        NSWorkspace.shared.setDefaultApplication(
            at: Bundle.main.bundleURL,
            toOpenURLsWithScheme: "cascade"
        ) { error in
            if let error {
                print("Cascade URL: self-registration failed: \(error)")
            } else {
                print("Cascade URL: registered \(Bundle.main.bundleURL.lastPathComponent) as cascade:// handler")
            }
        }
        // A duplicate instance may have left links behind before we registered.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.drainHandoff()
        }
    }

    @objc private func handleHandoffNotification() {
        self.drainHandoff()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        print("Cascade URL: received \(urls.count) url(s): \(urls.map { $0.absoluteString.prefix(80) })")
        // Arm the full-screen re-entry net FIRST, while the window's full-screen
        // state still reflects pre-delivery reality.
        FullScreenReentryGuard.shared.armIfNeeded(NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.canBecomeKey && $0.isVisible && !$0.isSheet }))
        // Duplicate instance? Hand the links to the running one and quit this
        // copy instead of fighting over the window.
        if let other = Self.otherRunningInstance() {
            print("Cascade URL: duplicate instance \(other.processIdentifier) — handing off")
            Self.handOff(urls: urls, to: other)
            return
        }

        Self.pendingOpenURLs.append(contentsOf: urls)
        self.drainHandoff()
        NotificationCenter.default.post(name: Self.didOpenURL, object: nil)
        raiseMainWindow()
    }

    /// Brings the app's existing window forward, or recreates the scene if none
    /// exists. Called on direct URL delivery and after draining a handoff.
    ///
    /// RULES (verified live on this machine + confirmed by external review):
    ///  - A FULL-SCREEN window owns its Space and is left COMPLETELY alone.
    ///    `.moveToActiveSpace`'s documented semantics are "when the window
    ///    becomes active, MOVE it to the active space instead of SWITCHING
    ///    spaces" — for a full-screen window that's only satisfiable by first
    ///    kicking it out of full screen. Any `NSApp.activate` /
    ///    `makeKeyAndOrderFront` during delivery does the same (the window
    ///    server un-full-screens it to make it key on the current space; worse
    ///    since Sonoma, and when the user's Mission Control "switch to a Space
    ///    with open windows" setting is off). The OS's own activation from the
    ///    browser click switches to the window's Space (Cmd-Tab semantics).
    ///  - A WINDOWED window may live on another Space/display, which makes it
    ///    look like it vanished — move it onto the ACTIVE screen's visible frame
    ///    and order it front. Only activate when the app isn't already active
    ///    (avoids pointless activation churn).
    ///  - A minimized window is still "visible == false" to SwiftUI, so
    ///    deminiaturize first; if the window list is empty the scene was torn
    ///    down and only the Dock icon remains → recreate the scene.
    private func raiseMainWindow() {
        DispatchQueue.main.async {
            let window = NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.canBecomeKey && $0.isVisible && !$0.isSheet })
                ?? NSApp.windows.first(where: { $0.canBecomeKey && !$0.isSheet })

            if let window, window.styleMask.contains(.fullScreen) {
                // Belt and suspenders only: ensure the flag can't trigger an exit
                // and log whether it was present (re-insertion race check). The
                // window itself is untouched — the OS's own activation already
                // switched to its Space.
                let hadFlag = window.collectionBehavior.contains(.moveToActiveSpace)
                window.collectionBehavior.remove(.moveToActiveSpace)
                print("Cascade URL: full-screen window — leaving untouched (had moveToActiveSpace: \(hadFlag))")
                return
            }

            // Windowed (or no window): activate only if needed. We keep
            // activate(ignoringOtherApps:) here on purpose — its Spaces
            // degradation only affects full-screen windows, which never reach
            // this path, and it is what makes windowed delivery reliably raise
            // the app (the macOS 14+ cooperative NSApp.activate() can silently
            // no-op when the frontmost app doesn't yield).
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
            if let window {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.collectionBehavior.insert(.moveToActiveSpace)
                TerminationHandler.rescueWindowOnScreen(window)
                window.makeKeyAndOrderFront(nil)
            } else {
                // No window at all: the SwiftUI scene was torn down (known
                // `Window`-scene quirk when the window is lost while another
                // window exists, or after a scene-restore hiccup). Two recovery
                // paths, both idempotent:
                //  - ask the SwiftUI app to recreate the scene via openWindow
                //    (any live scene observes this — main or About);
                //  - simulate the Dock-icon reopen, which SwiftUI Window scenes
                //    answer natively by restoring the scene window.
                print("Cascade URL: no window found — asking scene to recreate")
                NotificationCenter.default.post(name: TerminationHandler.recreateMainWindow, object: nil)
                for delay in [0.4, 1.2] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        if !NSApp.isActive {
                            NSApp.activate(ignoringOtherApps: true)
                        }
                        _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
                    }
                }
            }
        }
    }

    /// Physically moves a window onto a visible screen when its frame is entirely
    /// off every screen (a stranded/invisible window). If it's already on a
    /// screen, leaves it exactly where the user put it.
    private static func rescueWindowOnScreen(_ window: NSWindow) {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let frame = window.frame
        let onSomeScreen = screens.contains { $0.frame.intersects(frame) }
        guard !onSomeScreen else { return }
        if let screen = NSScreen.main ?? screens.first {
            let visible = screen.visibleFrame
            let origin = NSPoint(
                x: visible.midX - frame.width / 2,
                y: visible.midY - frame.height / 2
            )
            window.setFrameOrigin(origin)
        }
    }

    /// Closing the app's only window quits the app. Without this, a SwiftUI
    /// `Window` scene keeps the process running headless after the window closes:
    /// no window to reopen, nothing visible to quit — the app looks "stuck".
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Clicking the dock icon (or reopening the app) with no visible windows
    /// must restore the main window instead of leaving the app hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let window = sender.windows.first(where: { $0.canBecomeKey && !$0.isSheet }) {
                if window.styleMask.contains(.fullScreen) {
                    window.collectionBehavior.remove(.moveToActiveSpace)
                    // Same rule as URL delivery: never order-front a full-screen
                    // window (it would exit full screen). The dock-click activation
                    // already switches to its Space.
                } else {
                    window.collectionBehavior.insert(.moveToActiveSpace)
                    TerminationHandler.rescueWindowOnScreen(window)
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // TDLibKit's C++ core does not have a graceful Swift-side shutdown hook.
        // Calling exit(0) triggers C++ destructors and LLVM profiling while the 
        // background receive thread is still running, causing an EXC_BAD_ACCESS.
        // _exit(0) instantly kills the process at the kernel level, bypassing 
        // the teardown race safely.
        _exit(0)
    }
}

/// Safety net for URL delivery while the window is full screen. If the OS still
/// kicks the window out of full screen during delivery (some macOS versions, or
/// the user's Mission Control "switch to a Space with open windows" setting),
/// re-enter full screen — but ONLY if the exit happens within a tight window of
/// the delivery, so a genuine user-initiated exit (Esc, green button) is never
/// overridden.
///
/// Arm at the very top of URL processing, while the window's full-screen state
/// still reflects pre-delivery reality. If the window is already windowed by the
/// time we can look at it (the OS exited it before the delegate callback), the
/// windowed path of `raiseMainWindow` handles it instead — the two paths together
/// mean the window can never be stranded invisible.
private final class FullScreenReentryGuard {
    static let shared = FullScreenReentryGuard()
    private var pendingWindow: NSWindow?
    private var deliveryTimestamp: Date?
    private var observer: NSObjectProtocol?
    private let reentryWindow: TimeInterval = 0.75   // exit must be within this of delivery
    private let settleDelay: TimeInterval = 0.4      // let AppKit's exit animation finish first

    func armIfNeeded(_ window: NSWindow?) {
        guard let window, window.styleMask.contains(.fullScreen) else { return }
        pendingWindow = window
        deliveryTimestamp = Date()
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.handleExit(of: window)
            }
        }
    }

    private func handleExit(of window: NSWindow) {
        guard let ts = deliveryTimestamp,
              Date().timeIntervalSince(ts) < reentryWindow else {
            disarm()
            return
        }
        disarm()
        print("Cascade URL: window exited full screen \(String(format: "%.2f", Date().timeIntervalSince(ts)))s after delivery — re-entering")
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
            window.toggleFullScreen(nil)
        }
    }

    private func disarm() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        pendingWindow = nil
        deliveryTimestamp = nil
    }
}
