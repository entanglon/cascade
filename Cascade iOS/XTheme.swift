#if os(iOS)
import SwiftUI

enum XTheme {
    // MARK: - Corner Radius Scale
    static let cornerS: CGFloat = 10
    static let cornerM: CGFloat = 14
    static let cornerL: CGFloat = 20
    static let cornerXL: CGFloat = 28

    // MARK: - Spacing Scale
    static let spaceXS: CGFloat = 4
    static let spaceS: CGFloat = 8
    static let spaceM: CGFloat = 14
    static let spaceL: CGFloat = 22
    static let spaceXL: CGFloat = 32

    // MARK: - Brand Colors — Clean blue palette
    static let accent = Color(red: 0.25, green: 0.52, blue: 1.00)      // #4085FF — Apple-style blue
    static let accentSecondary = Color(red: 0.40, green: 0.60, blue: 1.00)

    // Category colors — matching macOS app
    static let categoryCyan = Color(red: 0.30, green: 0.72, blue: 0.90)
    static let categoryOrange = Color(red: 0.95, green: 0.55, blue: 0.25)
    static let categoryYellow = Color(red: 0.95, green: 0.78, blue: 0.25)
    static let categoryPurple = Color(red: 0.65, green: 0.42, blue: 0.90)
    static let categoryPink = Color(red: 0.95, green: 0.40, blue: 0.60)
    static let categoryBlue = Color(red: 0.30, green: 0.58, blue: 0.98)
    static let categoryEmerald = Color(red: 0.22, green: 0.78, blue: 0.55)
    static let categoryRed = Color(red: 0.92, green: 0.30, blue: 0.35)

    // MARK: - Gradients
    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentSecondary],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var driveGradient: LinearGradient {
        LinearGradient(
            colors: [accent, Color(red: 0.18, green: 0.40, blue: 0.92)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var privateFolderGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.95, green: 0.26, blue: 0.32), Color(red: 0.76, green: 0.14, blue: 0.30)],
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

    static var transfersGradient: LinearGradient {
        LinearGradient(
            colors: [categoryCyan, Color(red: 0.15, green: 0.60, blue: 0.85)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var archiveGradient: LinearGradient {
        LinearGradient(
            colors: [categoryYellow, Color(red: 0.88, green: 0.68, blue: 0.18)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var trashGradient: LinearGradient {
        LinearGradient(
            colors: [categoryRed, Color(red: 0.75, green: 0.20, blue: 0.25)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var favoritesGradient: LinearGradient {
        LinearGradient(
            colors: [categoryOrange, Color(red: 0.98, green: 0.45, blue: 0.20)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var downloadsGradient: LinearGradient {
        LinearGradient(
            colors: [categoryBlue, Color(red: 0.22, green: 0.45, blue: 0.95)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var photosGradient: LinearGradient {
        LinearGradient(
            colors: [categoryPink, Color(red: 0.88, green: 0.28, blue: 0.55)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var videosGradient: LinearGradient {
        LinearGradient(
            colors: [categoryPurple, Color(red: 0.52, green: 0.30, blue: 0.85)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var audioGradient: LinearGradient {
        LinearGradient(
            colors: [categoryCyan, Color(red: 0.20, green: 0.65, blue: 0.82)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var documentsGradient: LinearGradient {
        LinearGradient(
            colors: [categoryEmerald, Color(red: 0.16, green: 0.68, blue: 0.48)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var booksGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.85, green: 0.55, blue: 0.25), Color(red: 0.65, green: 0.38, blue: 0.16)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var sharedGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.25, green: 0.55, blue: 0.95), Color(red: 0.15, green: 0.40, blue: 0.85)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Dark Theme Surfaces
    static let surface = Color.white.opacity(0.06)
    static let surfaceHover = Color.white.opacity(0.10)
    static let surfaceBorder = Color.white.opacity(0.08)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.35)

    // MARK: - Byte Formatter
    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Squircle Category Badge

struct CategoryBadge: View {
    let icon: String
    let gradient: LinearGradient
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: icon)
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: Color.black.opacity(0.20), radius: 3, x: 0, y: 1.5)
    }
}

// MARK: - Frosted Glass Card Modifier

struct FrostedGlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.18),
                                Color.white.opacity(0.05),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 4)
    }
}

extension View {
    func frostedGlassCard(cornerRadius: CGFloat = 16) -> some View {
        self.modifier(FrostedGlassCardModifier(cornerRadius: cornerRadius))
    }
}
#endif
