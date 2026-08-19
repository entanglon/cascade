import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            // App Icon Graphic
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(XTheme.brandGradient)
                .frame(width: 90, height: 90)
                .overlay(
                    Image(systemName: "icloud.and.arrow.up.and.arrow.down.fill")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(.white)
                )
                .shadow(color: .black.opacity(0.3), radius: 12, y: 6)

            VStack(spacing: 4) {
                Text("Cascade")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                
                Text("Version 1.0.0")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }

            VStack(spacing: 8) {
                Text("Unlimited cloud storage")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                
                Text("Powered by Telegram & TDLibKit")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }

            Button("Close") { dismiss() }
                .buttonStyle(.xGlass)
                .frame(width: 120)
        }
        .padding(40)
        .frame(width: 320, height: 360)
        .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
    }
}
