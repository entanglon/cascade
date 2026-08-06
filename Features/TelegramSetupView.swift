import SwiftUI

struct TelegramSetupView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    var onSuccess: (() -> Void)? = nil

    @State private var apiID: String = ""
    @State private var apiHash: String = ""

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Image(systemName: "bolt.shield")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(XTheme.brandGradient)

                Text("Connect Telegram")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Use your existing API credentials from my.telegram.org")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("API ID")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))

                    TextField("12345678", text: $apiID)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("API Hash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))

                    SecureField("0123456789abcdef...", text: $apiHash)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                        .foregroundStyle(.white)
                }
            }

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.xGlass)

                Button("Connect") {
                    guard let id = Int(apiID), !apiHash.isEmpty else { return }
                    Task {
                        await appState.startTelegram(apiID: id, apiHash: apiHash)
                        if let onSuccess {
                            onSuccess()
                        } else {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.xGlassProminent)
                .disabled(apiID.isEmpty || apiHash.isEmpty)
            }
        }
        .padding(42)
        .glassEffect(.regular, in: .rect(cornerRadius: 30, style: .continuous))
        .frame(width: 480)
    }
}
