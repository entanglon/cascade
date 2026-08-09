import SwiftUI

enum XTheme {
    // MARK: - Corner Radius Scale
    static let cornerS: CGFloat = 10
    static let cornerM: CGFloat = 14
    static let cornerL: CGFloat = 22
    static let cornerXL: CGFloat = 30

    // MARK: - Spacing Scale
    static let spaceXS: CGFloat = 4
    static let spaceS: CGFloat = 8
    static let spaceM: CGFloat = 14
    static let spaceL: CGFloat = 22
    static let spaceXL: CGFloat = 34

    // MARK: - Brand Colors — Clean blue palette
    static let accent = Color(red: 0.25, green: 0.52, blue: 1.00)      // #4085FF — Apple-style blue
    static let accentSecondary = Color(red: 0.40, green: 0.60, blue: 1.00)

    // Category colors — subtle, professional
    static let categoryCyan = Color(red: 0.30, green: 0.72, blue: 0.90)
    static let categoryOrange = Color(red: 0.95, green: 0.55, blue: 0.25)
    static let categoryYellow = Color(red: 0.95, green: 0.78, blue: 0.25)
    static let categoryPurple = Color(red: 0.65, green: 0.42, blue: 0.90)
    static let categoryPink = Color(red: 0.95, green: 0.40, blue: 0.60)
    static let categoryBlue = Color(red: 0.30, green: 0.58, blue: 0.98)
    static let categoryEmerald = Color(red: 0.22, green: 0.78, blue: 0.55)
    static let categoryRed = Color(red: 0.92, green: 0.30, blue: 0.35)

    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentSecondary],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var privateFolderGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.92, green: 0.25, blue: 0.30), Color(red: 0.72, green: 0.15, blue: 0.35)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var standardFolderGradient: LinearGradient {
        LinearGradient(
            colors: [accent, Color(red: 0.20, green: 0.42, blue: 0.88)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Surface colors for dark theme
    static let surface = Color.white.opacity(0.06)
    static let surfaceHover = Color.white.opacity(0.10)
    static let surfaceBorder = Color.white.opacity(0.08)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.35)

    // MARK: - Byte Formatter (Bytes, KB, MB, GB, TB)
    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }
}
