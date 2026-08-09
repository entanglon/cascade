import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            AppBackground()

            if appState.isTheaterFullScreen, let file = appState.theaterFile {
                TheaterView(file: file)
                    .transition(.opacity)
                    .zIndex(20)
            } else {
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
                                .transition(.opacity)
                                .zIndex(10)
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
            }
        }
        .ignoresSafeArea(.all, edges: .top)
        .animation(.easeOut(duration: 0.18), value: appState.theaterFile?.id)
        .animation(.easeOut(duration: 0.18), value: appState.isTheaterFullScreen)
        .sheet(isPresented: Binding(
            get: { appState.showOnboarding },
            set: { appState.showOnboarding = $0 }
        )) {
            OnboardingView().environment(appState)
        }
        .sheet(isPresented: Binding(
            get: { appState.showSetup },
            set: { appState.showSetup = $0 }
        )) {
            TelegramSetupView(onSuccess: {
                appState.showSetup = false
                appState.showLogin = true
            })
        }
        .sheet(isPresented: Binding(
            get: { appState.showLogin },
            set: { appState.showLogin = $0 }
        )) {
            LoginView()
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

        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for b in buttons {
            if let btn = window.standardWindowButton(b) {
                btn.isHidden = false
                btn.superview?.isHidden = false
                btn.superview?.alphaValue = 1.0
            }
        }
    }
}
