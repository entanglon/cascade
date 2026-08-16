import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState
    @State private var importLinkText = ""

    var body: some View {
        ZStack {
            AppBackground()

            // The whole app is gated behind Telegram authorization: no vault access
            // (browser, notes, transfers) until the user is logged in.
            if TelegramClient.shared.isAuthorized {
                // The theater ALWAYS lives at the same structural position and the
                // sidebar always stays visible. "Full screen" is a native window
                // toggle (TheaterView calls NSWindow.toggleFullScreen) — it must never
                // restructure this tree: swapping branches on isTheaterFullScreen used
                // to dismantle the live MPVVideoView (destroying the mpv handle and
                // replacing it with a fresh idle one), which killed playback and left
                // a blank player on toggle.
                HStack(spacing: 12) {
                    SidebarView(
                        selection: Binding(
                            get: { appState.selectedDestination },
                            set: { appState.selectDestination($0) }
                        )
                    )
                    .frame(width: 236)
                    .padding(.leading, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 10)

                    ZStack {
                        FileBrowserView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if let file = appState.theaterFile {
                            TheaterView(file: file)
                                // Smooth opacity transition — scale transforms cause OpenGL
                                // rasterization lag during animation on live video layers.
                                .transition(.opacity)
                                .zIndex(10)
                        }

                        if let book = appState.readerFile {
                            BookReaderView(file: book)
                                // Fade-only: scale transforms glitch WKWebView content
                                // during the transition (blank/black page).
                                .transition(.opacity)
                                .zIndex(11)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                    )
                    .padding(.trailing, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 10)
                }
            } else if TelegramClient.shared.isAuthResolved || !appState.hasTelegramCredentials {
                // Gate shows either once TDLib has reported an authorization state,
                // or immediately when no API credentials are stored yet: without
                // them TDLib can never start, so waiting for a state that will
                // never arrive would strand a first-time user on the splash.
                LoginGateView()
                    .transition(.opacity)
                    .zIndex(30)
            } else {
                // TDLib hasn't reported an authorization state yet — show a neutral
                // splash instead of flashing the login screen on every launch when the
                // account is already logged in.
                AuthSplashView()
                    .transition(.opacity)
                    .zIndex(30)
            }
        }
        .ignoresSafeArea(.all, edges: .top)
        .animation(.easeInOut(duration: 0.20), value: appState.theaterFile?.id)
        .animation(.easeInOut(duration: 0.20), value: appState.readerFile?.id)
        .animation(.easeOut(duration: 0.18), value: appState.isTheaterFullScreen)
        .animation(.easeOut(duration: 0.25), value: TelegramClient.shared.isAuthorized)
        .sheet(isPresented: Binding(
            get: { appState.showOnboarding },
            set: { appState.showOnboarding = $0 }
        )) {
            OnboardingView().environment(appState)
        }
        .sheet(isPresented: Binding(
            get: { appState.showSettings },
            set: { appState.showSettings = $0 }
        )) {
            SettingsView()
                .environment(appState)
        }
        .background(WindowChromeFixer())
        .onReceive(NotificationCenter.default.publisher(for: .xCloudUploadFinished)) { _ in
            // Refresh the file list the moment an upload completes so files appear
            // in the browser in real time (also covers resume/retry completions).
            Task { await appState.loadFiles() }
        }
        .onChange(of: TelegramClient.shared.isAuthorized) { _, authorized in
            // Login completes mid-session (via the login gate): run the same post-auth
            // reconciliation bootstrap does at launch — scan the vault channel to
            // restore files, load the profile, restore transfers. Without this, a fresh
            // login shows an empty cloud and no profile until the app is restarted.
            if authorized {
                Task { await appState.completePostAuthSetup() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: TerminationHandler.didOpenURL)) { _ in
            // Share links (`xcloud://share…`) delivered while the app is running —
            // the AppDelegate activates the app and focuses the existing window,
            // then pings here so the queued URL is processed exactly once.
            appState.drainPendingShareLinks()
        }
        .alert("Import Shared Link", isPresented: Binding(
            get: { appState.importShareLinkPrompt },
            set: { if !$0 { appState.importShareLinkPrompt = false } }
        )) {
            TextField("xcloud://share…", text: $importLinkText)
            Button("Cancel", role: .cancel) { importLinkText = "" }
            Button("Import") {
                let raw = importLinkText
                importLinkText = ""
                appState.importShareLink(raw)
            }
        } message: {
            Text("Paste a share link you received from another xCloud user.")
        }
    }
}

/// Shown while TDLib is starting and hasn't reported whether the account is
/// authorized yet — avoids the login-gate flash on every launch.
struct AuthSplashView: View {
    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 14) {
                Text("xCloud")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.6))
            }
        }
        .transition(.opacity)
    }
}

struct WindowChromeFixer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowChromeView()
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Applies the transparent-titlebar window styling as soon as the view is attached
/// to a window (and again on every window change), so windowed mode never shows the
/// default macOS titlebar band over the app's dark UI.
final class WindowChromeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.applyChrome()
        }
    }

    private func applyChrome() {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        window.isMovableByWindowBackground = true
        window.toolbar = nil
        window.titlebarSeparatorStyle = .none
        // The window follows to whichever Space the user activates the app on, so
        // it can never be stranded invisible on another Space (the "window
        // disappeared" bug).
        window.collectionBehavior.insert(.moveToActiveSpace)

        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for b in buttons {
            if let btn = window.standardWindowButton(b) {
                btn.isHidden = false
                btn.superview?.isHidden = false
                btn.superview?.alphaValue = 1.0
            }
        }

        // A window restored/created off every screen (e.g. macOS remembered a
        // position on a display that's no longer attached) looks like the app
        // "opened invisible". Rescure it: if the frame doesn't intersect any
        // screen, center it on the active screen. Leaves the user's own position
        // untouched when it's already visible.
        let frame = window.frame
        let screens = NSScreen.screens
        let onSomeScreen = screens.contains { $0.frame.intersects(frame) }
        if !screens.isEmpty && !onSomeScreen,
           let screen = NSScreen.main ?? screens.first {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(
                x: visible.midX - frame.width / 2,
                y: visible.midY - frame.height / 2
            ))
        }
    }
}
