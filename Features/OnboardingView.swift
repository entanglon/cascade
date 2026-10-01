import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(XTheme.accent.opacity(0.15))
                        .frame(width: 80, height: 80)

                    Image(systemName: "cloud.fill")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(XTheme.accent)
                }

                Text("Welcome to Cascade")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)

                Text("Unlimited personal cloud storage and instant media streaming")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 16)

            // Features list
            VStack(alignment: .leading, spacing: 20) {
                featureRow(
                    icon: "cloud.fill",
                    color: .cyan,
                    title: "Unlimited Cloud Storage",
                    description: "Store documents, videos, and archives on your private Telegram channel without storage caps."
                )

                featureRow(
                    icon: "number",
                    color: .red,
                    title: "PIN-Locked Private Folders",
                    description: "Files in private folders are locked behind your PIN and hidden from the main library."
                )

                featureRow(
                    icon: "play.tv.fill",
                    color: .purple,
                    title: "Native Streaming & Quick Look",
                    description: "Instant in-window video streaming, image previews, and desktop-class macOS integration."
                )
            }
            .padding(.horizontal, 16)

            Spacer()

            // Footer buttons
            HStack(spacing: 16) {
                Button("Not Now") {
                    completeOnboarding()
                }
                .buttonStyle(.xGlass)
                .frame(maxWidth: .infinity)

                Button {
                    // The login gate takes over once onboarding closes — it handles the
                    // API credentials step and the phone/code/password login flow.
                    completeOnboarding()
                } label: {
                    Text("Get Started")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.xGlassProminent)
                .frame(maxWidth: .infinity)
            }
            .padding(.bottom, 8)
        }
        .padding(28)
        .frame(width: 480, height: 520)
        .background(
            ZStack {
                AppBackground()
                Color.black.opacity(0.35)
            }
        )
    }

    private func featureRow(icon: String, color: Color, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .background(color.opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)

                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "xc.hasOnboarded")
        appState.showOnboarding = false
        dismiss()
    }
}
