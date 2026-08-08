import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            AppBackground()

            HStack(spacing: 12) {
                SidebarView(
                    selection: Binding(
                        get: { appState.selectedDestination },
                        set: {
                            appState.selectedDestination = $0
                            appState.currentFolderID = nil
                        }
                    )
                )
                .frame(width: 236)
                .padding(.leading, 10)
                .padding(.top, 10)
                .padding(.bottom, 10)

                FileBrowserView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .ignoresSafeArea(.all, edges: .top)
        .overlay {
            if let file = appState.theaterFile {
                TheaterView(file: file)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.easeOut(duration: 0.18), value: appState.theaterFile?.id)
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
    }
}

struct WindowChromeFixer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let window = v.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
            window.isMovableByWindowBackground = true
            window.toolbar = nil
            
            let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for b in buttons {
                if let btn = window.standardWindowButton(b) {
                    btn.isHidden = false
                    btn.superview?.isHidden = false
                    btn.superview?.alphaValue = 1.0
                }
            }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
