#if os(iOS)
import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
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
    }
}
#endif
