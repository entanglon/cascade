#if os(iOS)
import SwiftUI

@main
struct CascadeApp: App {
    @State private var appState = AppState()

    init() {
        // Navigation Bar styling
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithTransparentBackground()
        navAppearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        navAppearance.backgroundColor = UIColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 0.80)
        navAppearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        navAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]

        let scrollEdgeAppearance = UINavigationBarAppearance()
        scrollEdgeAppearance.configureWithTransparentBackground()
        scrollEdgeAppearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        scrollEdgeAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]

        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = scrollEdgeAppearance
        UINavigationBar.appearance().tintColor = UIColor(red: 0.25, green: 0.52, blue: 1.0, alpha: 1.0)

        // Stock Tab Bar hiding
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithTransparentBackground()
        tabAppearance.backgroundColor = .clear
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance

        // Search Bar styling matching macOS aesthetic
        let searchField = UITextField.appearance(whenContainedInInstancesOf: [UISearchBar.self])
        searchField.backgroundColor = UIColor(white: 0.14, alpha: 0.85)
        searchField.textColor = .white
        searchField.tintColor = UIColor(red: 0.25, green: 0.52, blue: 1.0, alpha: 1.0)
        searchField.layer.cornerRadius = 10
        searchField.clipsToBounds = true
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(.dark)
                .task { await appState.bootstrap() }
                .onOpenURL { url in
                    if url.scheme == "cascade" {
                        Task {
                            await appState.importShareLink(url.absoluteString)
                        }
                    } else {
                        Task {
                            await appState.uploadBatch(urls: [url], parentID: nil)
                        }
                    }
                }
        }
    }
}
#endif
