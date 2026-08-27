#if os(iOS)
import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            AppBackground()

            if TelegramClient.shared.isAuthorized {
                TabView {
                    FileBrowserView()
                        .tabItem {
                            Label("Files", systemImage: "folder")
                        }

                    TransfersView()
                        .tabItem {
                            Label("Transfers", systemImage: "arrow.triangle.2.circlepath")
                        }

                    SettingsView()
                        .tabItem {
                            Label("Settings", systemImage: "gearshape")
                        }
                }
                .tint(.accentColor)
            } else if TelegramClient.shared.isAuthResolved || !appState.hasTelegramCredentials {
                LoginGateView()
                    .transition(.opacity)
            } else {
                AuthSplashView()
                    .transition(.opacity)
            }

            if let note = appState.currentNotification {
                VStack {
                    ActiveTransferHUD(note: note)
                        .padding(.top, 16)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(50)
            }
        }
    }
}
#endif
