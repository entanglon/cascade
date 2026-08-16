import Foundation

/// Build-scoped data folder name. The production build (bundle id
/// `com.nemesys.xcloud.xCloud.prod`) must never share state with the dev/testing
/// build (`com.nemesys.xcloud.xCloud`), so each uses its own folder under
/// Application Support / Caches: separate database, TDLib state, downloads and
/// handoff files. The two builds can be installed and run side by side.
enum AppPaths {
    /// "xCloud" for the dev/testing build, "xCloud-Prod" for the production build.
    static var dataFolder: String {
        if Bundle.main.bundleIdentifier?.hasSuffix(".prod") == true {
            return "xCloud-Prod"
        }
        return "xCloud"
    }
}