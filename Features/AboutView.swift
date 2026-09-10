import SwiftUI
import AppKit

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 18) {
            // App Icon — the dark artwork (theme switching parked; the Dock
            // tile comes from the bundle icon, same art).
            if let appIcon = NSImage(named: "IconDark") ?? NSApp.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                    )
            }

            VStack(spacing: 4) {
                Text("Cascade")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                
                Text(appVersion)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }

            VStack(spacing: 4) {
                Text("Zero-Knowledge Cloud Storage")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)

                Text("Client-side encrypted • Native MPV media engine")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 8)

            Button("Close") { dismiss() }
                .buttonStyle(.xGlass)
                .frame(width: 120)
                .padding(.top, 4)
        }
        .padding(32)
        .frame(width: 320, height: 350)
        .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .preferredColorScheme(.dark)
    }
}
