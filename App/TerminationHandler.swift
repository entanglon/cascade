import AppKit

final class TerminationHandler: NSObject, NSApplicationDelegate {
    /// Share links (`xcloud://share…`) delivered by the OS while the app was
    /// running OR while it was still launching. AppState drains this list, so
    /// every link is processed exactly once (warm delivery via the notification
    /// below; cold-launch delivery drained once post-auth setup completes).
    static var pendingOpenURLs: [URL] = []
    /// Posted whenever the OS hands the app a URL, so the running scene can
    /// drain `pendingOpenURLs` immediately. The list — not the notification's
    /// payload — is the source of truth (it also covers URLs that arrived
    /// before any observer was attached).
    static let didOpenURL = Notification.Name("xCloudDidOpenURL")

    /// Distributed notification used by a duplicate instance to tell the running
    /// one that share links are waiting in the handoff file.
    private static let handoffNotificationName = Notification.Name("com.nemesys.xcloud.xCloud.handoffURLs")
    private static let handoffFileName = "handoff-urls.json"

    // MARK: - Single-instance guard

    /// Another xCloud process already running (same bundle id, different pid)?
    /// Stale URL-scheme registrations can make LaunchServices START a second copy
    /// of the app when a share link is opened (e.g. an older build's app bundle
    /// is still registered as the `xcloud://` handler). Two instances then fight
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
        let dir = support.appendingPathComponent("xCloud", isDirectory: true)
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
        other.activate(options: [.activateAllWindows])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            _exit(0)
        }
    }

    /// The running instance: pull any links a duplicate copy left in the handoff
    /// file, queue them, and process them like any OS-delivered link.
    private static func drainHandoff() {
        guard let file = handoffFileURL() else { return }
        guard let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode([String].self, from: data),
              !stored.isEmpty else { return }
        try? FileManager.default.removeItem(at: file)
        pendingOpenURLs.append(contentsOf: stored.compactMap(URL.init(string:)))
        NotificationCenter.default.post(name: didOpenURL, object: nil)
    }

    // MARK: - App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleHandoffNotification),
            name: Self.handoffNotificationName,
            object: nil
        )
        // A duplicate instance may have left links behind before we registered.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Self.drainHandoff()
        }
    }

    @objc private func handleHandoffNotification() {
        Self.drainHandoff()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Duplicate instance? Hand the links to the running one and quit this
        // copy instead of fighting over the window.
        if let other = Self.otherRunningInstance() {
            Self.handOff(urls: urls, to: other)
            return
        }

        Self.pendingOpenURLs.append(contentsOf: urls)
        Self.drainHandoff()
        NotificationCenter.default.post(name: Self.didOpenURL, object: nil)

        // Open the link in the app's EXISTING, active window. Three subtleties:
        //  - Activating synchronously inside URL delivery can deadlock the main
        //    thread on some macOS versions (the app then can't be closed) —
        //    defer to the next main-thread tick.
        //  - The window may live on another Space or display (where the user last
        //    had it, or where macOS restored it), which makes it look like it
        //    "disappeared". Move it onto the ACTIVE screen's visible frame before
        //    ordering it front, so a link click can never strand it off-screen.
        //  - moveToActiveSpace makes the window follow to the active Space; it is
        //    intentionally NOT removed afterwards — removing it right away races
        //    the window server's space move and can leave the window stranded
        //    off-screen (verified live).
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let window = NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.canBecomeKey && $0.isVisible && !$0.isSheet })
                ?? NSApp.windows.first(where: { $0.canBecomeKey && !$0.isSheet })
            if let window {
                window.collectionBehavior.insert(.moveToActiveSpace)
                TerminationHandler.rescueWindowOnScreen(window)
                window.makeKeyAndOrderFront(nil)
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
                window.collectionBehavior.insert(.moveToActiveSpace)
                TerminationHandler.rescueWindowOnScreen(window)
                window.makeKeyAndOrderFront(nil)
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
