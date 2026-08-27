#if os(iOS)
import SwiftUI

@main
struct CascadeApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(.dark)
                .task { await appState.bootstrap() }
        }
    }
}
#endif
