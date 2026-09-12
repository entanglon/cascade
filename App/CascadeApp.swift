import SwiftUI
import AppKit

/// Dark/Light Dock icon switching for the user's dark.png/light.png artwork
/// (both rebuilt at the 90% footprint with baked shadow). macOS AppIcon
/// catalogs do NOT support luminosity appearances (actool rejects them), so
/// the bundle icon stays dark and the running app swaps its own Dock tile
/// via applicationIconImage whenever the OS appearance flips. Started from
/// the app delegate at launch.
final class AppIconSwitcher {
    static let shared = AppIconSwitcher()
    private var observer: Any?

    private init() {
        applyIcon()
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.applyIcon() }
    }

    private var isDarkMode: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    func applyIcon() {
        guard let image = NSImage(named: isDarkMode ? "IconDark" : "IconLight") else { return }
        NSApplication.shared.applicationIconImage = image
    }
}

@main
struct CascadeApp: App {
    @NSApplicationDelegateAdaptor(TerminationHandler.self) private var terminationHandler
    @Environment(\.openWindow) private var openWindow
    @State private var appState = AppState()

    init() {
        // Line-buffer stdout so `print` diagnostics survive redirection to a
        // file (launch via `> log 2>&1` otherwise block-buffers and hides them).
        setvbuf(stdout, nil, _IOLBF, 0)
        // The fullscreen transition gate must observe every window's
        // transition from the very first frame (Swift globals are lazy —
        // touching it here guarantees registration before any window exists).
        _ = FullscreenTransitionGate.shared
    }

    var body: some Scene {
        // Single-instance `Window` (not `WindowGroup`): when macOS delivers an
        // `cascade://` link while the app is running, a WindowGroup answers the
        // open-URL event by opening a NEW scene window — so every link click
        // spawned a second, third… window. A `Window` scene physically cannot
        // duplicate; the OS reuses the one main window (which the AppDelegate
        // also activates and brings to the front on URL delivery).
        Window("Cascade", id: "main") {
            RootView()
                .environment(appState)
                .frame(minWidth: 1024, minHeight: 640)
                .preferredColorScheme(.dark)
                .background(FullscreenWindowLink())
                .task { await appState.bootstrap() }
                .onReceive(NotificationCenter.default.publisher(for: TerminationHandler.recreateMainWindow)) { _ in
                    openWindow(id: "main")
                }
        }
        .defaultSize(width: 1280, height: 780)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Cascade") {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "about")
                }
            }

            CommandGroup(after: .appInfo) {
                Button("Settings...") {
                    appState.showSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandMenu("File") {
                Button("Import Shared Link…") {
                    appState.importShareLinkPrompt = true
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }

            CommandGroup(after: .pasteboard) {
                Button("Select All") { appState.selectAll() }
                    .keyboardShortcut("a", modifiers: .command)
                Button("Deselect All") { appState.clearSelection() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }

            // The pasteboard group holds Cut/Copy/Paste — replacing it wiped the Edit
            // menu's ⌘X/⌘C/⌘V, so paste silently stopped working in every text field
            // (API setup, login, search). Restore them with the standard
            // selectors: they validate against the first responder, so ⌘C/⌘V in the
            // file browser still fall through to the browser's own key handlers when no
            // text field is focused, and paste into any text field (including sheets)
            // works again.
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                    .keyboardShortcut("x", modifiers: .command)
                Button("Copy") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                    .keyboardShortcut("c", modifiers: .command)
                Button("Paste") {
                    let isEditingText: Bool = {
                        guard let firstResponder = NSApp.keyWindow?.firstResponder else { return false }
                        return firstResponder is NSTextView || firstResponder is NSTextField
                    }()
                    if !isEditingText,
                       let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       clip.hasPrefix("cascade://share") {
                        appState.importShareLink(clip)
                        return
                    }
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                }
                    .keyboardShortcut("v", modifiers: .command)
                Button("Move to Trash") { appState.bulkTrash() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(appState.selectedFiles.isEmpty)
            }

            // Add "Reload Page" to the system's existing View menu instead of
            // creating a duplicate "View" menu in the menu bar.
            CommandGroup(after: .toolbar) {
                Button("Reload Page") {
                    Task {
                        await appState.loadFiles(reconcileCloud: true)
                        appState.thumbnailVersion += 1
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        Window("About", id: "about") {
            AboutView()
                .environment(appState)
                .preferredColorScheme(.dark)
                .onReceive(NotificationCenter.default.publisher(for: TerminationHandler.recreateMainWindow)) { _ in
                    openWindow(id: "main")
                }
        }
        .windowResizability(.contentSize)

        // Player-only full screen: a system-managed SwiftUI window (like the
        // flux player window) that the theater's full-screen toggle opens.
        // The scene window is a normal titled window — correct sizing and
        // native Spaces fullscreen come from the system, not from hand-rolled
        // NSWindow work. FullscreenPlayerSceneView renders the transferred mpv
        // layer + controls and enters native fullscreen once the window is key.
        Window("Fullscreen Player", id: "fullscreenPlayer") {
            FullscreenPlayerSceneView()
                .environment(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
    }
}
