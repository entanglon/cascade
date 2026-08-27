#if os(iOS)
import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            if appState.isInitialLoading {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Loading…")
                        .foregroundStyle(.secondary)
                }
            } else if appState.isAuthorized {
                TabView {
                    FileBrowserView()
                        .tabItem {
                            Label("Files", systemImage: "folder")
                        }

                    Text("Transfers")
                        .tabItem {
                            Label("Transfers", systemImage: "arrow.triangle.2.circlepath")
                        }

                    SettingsView()
                        .tabItem {
                            Label("Settings", systemImage: "gearshape")
                        }
                }
                .tint(.accentColor)
            } else {
                LoginGateView()
            }
        }
    }
}

struct LoginGateView: View {
    @Environment(AppState.self) private var appState
    @State private var showSetup = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("Welcome to Cascade")
                .font(.title.bold())

            Text("Sign in with your Telegram account to access your encrypted vault.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if !appState.hasTelegramCredentials {
                VStack(spacing: 12) {
                    Text("No Telegram account configured on this device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Set Up Telegram") {
                        showSetup = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if appState.isAuthResolved && !appState.isAuthorized {
                Text("Authorization failed. Please check your Telegram credentials.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            } else {
                ProgressView("Connecting to Telegram…")
            }
        }
        .sheet(isPresented: $showSetup) {
            TelegramSetupSheet()
        }
    }
}

struct TelegramSetupSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var apiID: String = ""
    @State private var apiHash: String = ""
    @State private var phoneNumber: String = ""
    @State private var code: String = ""
    @State private var step: Step = .credentials
    @State private var errorMessage: String?

    enum Step {
        case credentials, phone, code
    }

    var body: some View {
        NavigationStack {
            Form {
                switch step {
                case .credentials:
                    Section("Telegram API Credentials") {
                        Text("Get these from my.telegram.org")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("API ID", text: $apiID)
                            .keyboardType(.numberPad)
                        SecureField("API Hash", text: $apiHash)
                    }

                case .phone:
                    Section("Phone Number") {
                        TextField("+1 234 567 8900", text: $phoneNumber)
                            .keyboardType(.phonePad)
                    }

                case .code:
                    Section("Verification Code") {
                        TextField("Code", text: $code)
                            .keyboardType(.numberPad)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Telegram Setup")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    switch step {
                    case .credentials:
                        Button("Next") {
                            guard let id = Int(apiID), !apiHash.isEmpty else {
                                errorMessage = "Enter valid API ID and Hash"
                                return
                            }
                            TelegramClient.shared.configure(apiID: id, apiHash: apiHash)
                            try? KeychainStore.saveTelegramCredentials(apiID: id, apiHash: apiHash)
                            step = .phone
                        }
                    case .phone:
                        Button("Next") {
                            Task {
                                do {
                                    try await TelegramClient.shared.start()
                                    // TODO: TDLib will prompt for code
                                    step = .code
                                } catch {
                                    errorMessage = error.localizedDescription
                                }
                            }
                        }
                    case .code:
                        Button("Sign In") {
                            Task {
                                // TODO: send code to TDLib
                                dismiss()
                                await appState.bootstrap()
                            }
                        }
                    }
                }
            }
        }
    }
}
#endif
