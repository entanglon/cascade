import SwiftUI

/// Full-screen login gate. RootView shows this whenever Telegram authorization is
/// missing, so the cloud (file browser, transfers — everything) is unreachable
/// until the user is logged in. All content lives inside a single glass card: brand text,
/// then either the API-credentials step (first run) or the phone/code/password login
/// steps. Auto-dismisses when `TelegramClient.shared.isAuthorized` flips true.
struct LoginGateView: View {
    @Environment(AppState.self) private var appState

    private var needsCredentials: Bool {
        !appState.hasTelegramCredentials
    }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            card
            Spacer(minLength: 0)
        }
        .padding(48)
        .task {
            // Credentials stored but TDLib not started yet (fresh launch): bring it up
            // so the login steps can run.
            if let creds = try? KeychainStore.loadTelegramCredentials(),
               !TelegramClient.shared.isClientStarted {
                await appState.startTelegram(apiID: creds.apiID, apiHash: creds.apiHash)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: needsCredentials)
    }

    /// The glass card holds everything — brand text and the active auth step. Material
    /// background (behind the controls) gives the liquid-glass look without the macOS 26
    /// container-glass hit-testing problem that once made these fields unclickable.
    private var card: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Text("Cascade")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Your private cloud")
                    .font(.system(size: 13))
                    .foregroundStyle(XTheme.textSecondary)
            }

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 8)

            if needsCredentials {
                TelegramSetupForm()
            } else {
                LoginStepsView()
            }
        }
        .padding(30)
        .frame(width: 480)
        .background {
            RoundedRectangle(cornerRadius: XTheme.cornerXL, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: XTheme.cornerXL, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.22), .white.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.45), radius: 40, y: 16)
    }
}

/// API credentials step (api_id + api_hash from my.telegram.org). Used by the login gate
/// on first run; the gate switches to the login steps automatically once credentials are
/// stored and TDLib reaches the phone-number state.
struct TelegramSetupForm: View {
    @Environment(AppState.self) private var appState
    var onSuccess: (() -> Void)? = nil

    @State private var apiID: String = ""
    @State private var apiHash: String = ""
    @State private var errorMessage: String?
    @State private var isConnecting: Bool = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case apiID
        case apiHash
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Get your API ID and API Hash from my.telegram.org")
                .font(.system(size: 12))
                .foregroundStyle(XTheme.textSecondary)

            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("API ID")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(XTheme.textSecondary)

                    TextField("12345678", text: $apiID)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: XTheme.cornerS, style: .continuous).fill(.white.opacity(0.08)))
                        .overlay(
                            RoundedRectangle(cornerRadius: XTheme.cornerS, style: .continuous)
                                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                                .allowsHitTesting(false)
                        )
                        .foregroundStyle(.white)
                        .focused($focusedField, equals: .apiID)
                        .onSubmit { focusedField = .apiHash }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("API Hash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(XTheme.textSecondary)

                    SecureField("0123456789abcdef...", text: $apiHash)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: XTheme.cornerS, style: .continuous).fill(.white.opacity(0.08)))
                        .overlay(
                            RoundedRectangle(cornerRadius: XTheme.cornerS, style: .continuous)
                                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                                .allowsHitTesting(false)
                        )
                        .foregroundStyle(.white)
                        .focused($focusedField, equals: .apiHash)
                        .onSubmit { connect() }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: connect) {
                HStack(spacing: 8) {
                    if isConnecting {
                        ProgressView().tint(.white)
                    } else {
                        Text("Connect")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.xGlassProminent)
            .disabled(apiID.isEmpty || apiHash.isEmpty || isConnecting)
        }
        .onAppear { focusedField = .apiID }
    }

    private func connect() {
        guard let id = Int(apiID), !apiHash.isEmpty else { return }
        errorMessage = nil
        isConnecting = true
        Task {
            await appState.startTelegram(apiID: id, apiHash: apiHash)
            isConnecting = false
            if let dbError = appState.databaseError {
                errorMessage = dbError
                return
            }
            onSuccess?()
        }
    }
}
