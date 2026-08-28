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

            if let note = appState.currentNotification {
                VStack {
                    NotificationBannerView(notification: note) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            appState.dismissNotification()
                        }
                    }
                    .padding(.top, 16)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(200)
            }
        }
        .ignoresSafeArea(.all, edges: .top)
        .animation(.easeInOut(duration: 0.20), value: appState.theaterFile?.id)
        .animation(.easeInOut(duration: 0.20), value: appState.readerFile?.id)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: appState.currentNotification)
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
        .sheet(isPresented: Binding(
            get: { appState.pendingImportID != nil },
            set: { if !$0 { appState.pendingImportID = nil; appState.pendingImportObject = nil } }
        )) {
            if let object = appState.pendingImportObject {
                PendingImportView(object: object)
                    .environment(appState)
            }
        }
        .sheet(isPresented: Binding(
            get: { appState.passwordUnlockLink != nil },
            set: { if !$0 { appState.passwordUnlockLink = nil } }
        )) {
            if let link = appState.passwordUnlockLink {
                SharePasswordUnlockSheet(link: link)
                    .environment(appState)
            }
        }
        .background(WindowChromeFixer())
        .onReceive(NotificationCenter.default.publisher(for: .cascadeUploadFinished)) { _ in
            // Refresh the file list the moment an upload completes so files appear
            // in the browser in real time (also covers resume/retry completions).
            Task { await appState.loadFiles() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Reconcile cloud catalog snapshots when window becomes active (high-water mark makes this <100ms)
            Task { await appState.loadFiles(reconcileCloud: true) }
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
            // Share links (`cascade://share…`) delivered while the app is running —
            // the AppDelegate activates the app and focuses the existing window,
            // then pings here so the queued URL is processed exactly once.
            appState.drainPendingShareLinks()
        }
        .alert("Import Shared Link", isPresented: Binding(
            get: { appState.importShareLinkPrompt },
            set: { if !$0 { appState.importShareLinkPrompt = false } }
        )) {
            TextField("cascade://share…", text: $importLinkText)
            Button("Cancel", role: .cancel) { importLinkText = "" }
            Button("Import") {
                let raw = importLinkText
                importLinkText = ""
                appState.importShareLink(raw)
            }
        } message: {
            Text("Paste a share link you received from another Cascade user.")
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
                Text("Cascade")
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
    private var fullScreenObservers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            for o in fullScreenObservers { NotificationCenter.default.removeObserver(o) }
            fullScreenObservers = []
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.applyChrome()
        }
        observeFullScreenTransitions(window)
    }

    /// `.moveToActiveSpace` (inserted below) is what makes a windowed window
    /// follow the user to the active Space — but a FULL-SCREEN window owns its
    /// Space. If the flag stays set while full screen, activating the app (e.g.
    /// when a browser share link is delivered) makes the window server pull the
    /// window OUT of full screen to follow the active space, stranding it so it
    /// looks like it "disappeared". Remove the flag on enter, restore on exit.
    private func observeFullScreenTransitions(_ window: NSWindow) {
        guard fullScreenObservers.isEmpty else { return }
        let nc = NotificationCenter.default
        fullScreenObservers.append(nc.addObserver(
            forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.window?.collectionBehavior.remove(.moveToActiveSpace)
        })
        // Belt and suspenders: re-assert the removal once the transition completes
        // (in case something re-inserted the flag mid-transition), and restore it
        // when full screen ends.
        fullScreenObservers.append(nc.addObserver(
            forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.window?.collectionBehavior.remove(.moveToActiveSpace)
        })
        fullScreenObservers.append(nc.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.window?.collectionBehavior.insert(.moveToActiveSpace)
        })
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
        // disappeared" bug). Removed automatically while full screen (see
        // observeFullScreenTransitions) because a full-screen window can't follow
        // spaces — it owns its Space.
        if !window.styleMask.contains(.fullScreen) {
            window.collectionBehavior.insert(.moveToActiveSpace)
        }

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

/// Prompt modal for entering a password to unlock and import a password-protected share link.
struct SharePasswordUnlockSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let link: String
    @State private var password = ""
    @State private var errorMessage: String? = nil
    @State private var isUnlocking = false

    private var shareName: String {
        ShareEngine.ShareLink.parse(link)?.fileName ?? "Shared File"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(XTheme.accent)
                .padding(.top, 6)

            Text("Password Required")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)

            Text("This link for '\(shareName)' is password protected.\nEnter the password to unlock and import it.")
                .font(.system(size: 12))
                .foregroundStyle(XTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            SecureField("Password", text: $password)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
                .foregroundStyle(.white)
                .frame(maxWidth: 300)

            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
            }

            if isUnlocking {
                ProgressView()
                    .controlSize(.small)
                    .tint(XTheme.accent)
            } else {
                HStack(spacing: 10) {
                    Button {
                        appState.passwordUnlockLink = nil
                        dismiss()
                    } label: {
                        Text("Cancel")
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.white.opacity(0.07))
                            )
                    }
                    .buttonStyle(.plain)

                    Button {
                        submit()
                    } label: {
                        Text("Unlock & Import")
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(password.isEmpty ? Color.gray.opacity(0.4) : XTheme.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(password.isEmpty)
                }
                .padding(.top, 4)
            }
        }
        .padding(30)
        .frame(width: 420)
        .background(Color(red: 0.055, green: 0.07, blue: 0.11))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .preferredColorScheme(.dark)
    }

    private func submit() {
        guard !password.isEmpty else { return }
        isUnlocking = true
        errorMessage = nil
        Task {
            let pw = password
            do {
                switch try await ShareEngine.importLink(link, password: pw) {
                case .pending(let objectID):
                    appState.passwordUnlockLink = nil
                    appState.pendingImportID = objectID
                    appState.pendingImportObject = try? await DatabaseManager.shared.object(objectID)
                    await appState.loadFiles()
                    dismiss()
                case .imported:
                    appState.passwordUnlockLink = nil
                    let isGroup = ShareEngine.ShareLink.parse(link)?.isGroup ?? false
                    let before = Set(appState.incomingShares.map(\.objectID))
                    await appState.loadShares()
                    let fresh = appState.incomingShares.filter { !before.contains($0.objectID) }
                    let freshObjects = fresh.isEmpty ? nil : ((try? await DatabaseManager.shared.allObjects()) ?? [])
                        .first { $0.id == fresh.first?.objectID }
                    TransferCenter.shared.begin(
                        .inbound,
                        objectID: fresh.first?.objectID ?? "",
                        name: isGroup
                            ? "\(fresh.count) files"
                            : (freshObjects?.name ?? "Shared file"),
                        statusText: "Imported",
                        state: .complete
                    )
                    appState.alertMessage = isGroup
                        ? "Shared files imported — find them in Transfers."
                        : "Shared file imported — find it in Transfers."
                    await appState.loadFiles()
                    dismiss()
                case .selfOpen(let objectID):
                    appState.passwordUnlockLink = nil
                    await appState.loadFiles()
                    if let object = appState.files.first(where: { $0.id == objectID }) {
                        appState.revealObject(object)
                    }
                    dismiss()
                case .alreadyImported(let objectID):
                    appState.passwordUnlockLink = nil
                    await appState.loadFiles()
                    if let object = appState.files.first(where: { $0.id == objectID }) {
                        appState.revealObject(object)
                    }
                    dismiss()
                }
            } catch ShareEngine.ShareError.invalidPassword {
                isUnlocking = false
                errorMessage = "Incorrect password. Please try again."
            } catch {
                isUnlocking = false
                errorMessage = ShareEngine.describe(error)
            }
        }
    }
}

// MARK: - Toast / Banner Notification View

struct NotificationBannerView: View {
    let notification: AppState.AppNotification
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(iconColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(notification.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)

                if let message = notification.message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(5)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 420)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.35), radius: 12, x: 0, y: 6)
        )
    }

    private var iconName: String {
        switch notification.kind {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch notification.kind {
        case .info: return Color.blue
        case .warning: return Color.orange
        case .error: return Color.red
        case .success: return Color.green
        }
    }
}
