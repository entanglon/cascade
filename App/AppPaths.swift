import Foundation

/// Build-scoped data folder name. The production build (bundle id
/// `com.cascade.app.prod`) must never share state with the dev/testing
/// build (`com.cascade.app`), so each uses its own folder under
/// Application Support / Caches: separate database, TDLib state, downloads and
/// handoff files. The two builds can be installed and run side by side.
enum AppPaths {
    /// "Cascade" for the dev/testing build, "Cascade-Prod" for the production build.
    static var dataFolder: String {
        if Bundle.main.bundleIdentifier?.hasSuffix(".prod") == true {
            return "Cascade-Prod"
        }
        return "Cascade"
    }
}