#if os(iOS)
import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            if appState.isInitialLoading {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Loading…")
                        .foregroundStyle(.secondary)
                }
            } else if appState.isAuthorized {
                TabView {
                    FileBrowserView()
                        .tabItem {
                            Label("Files", systemImage: "folder")
                        }

                    Text("Transfers")
                        .tabItem {
                            Label("Transfers", systemImage: "arrow.triangle.2.circlepath")
                        }

                    SettingsView()
                        .tabItem {
                            Label("Settings", systemImage: "gearshape")
                        }
                }
                .tint(.accentColor)
            } else {
                LoginGateView()
            }
        }
    }
}

struct LoginGateView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("Welcome to Cascade")
                .font(.title.bold())

            Text("Sign in with your Telegram account to access your encrypted vault.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if appState.isAuthResolved {
                Text("Please sign in from the Mac app first, then open Cascade on iPhone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            } else {
                ProgressView("Connecting to Telegram…")
            }
        }
    }
}
#endif
