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

            Text("Your private cloud storage, encrypted and synced through Telegram.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if !appState.hasTelegramCredentials {
                Button("Set Up Telegram") {
                    showSetup = true
                }
                .buttonStyle(.borderedProminent)
            } else {
                LoginStepsView()
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
    @State private var errorMessage: String?
    @State private var isConnecting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Telegram API Credentials") {
                    Text("Get these from my.telegram.org → API Development Tools")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("API ID", text: $apiID)
                        .keyboardType(.numberPad)
                    SecureField("API Hash", text: $apiHash)
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
                    Button("Connect") {
                        guard let id = Int(apiID), !apiHash.isEmpty else {
                            errorMessage = "Enter valid API ID and Hash"
                            return
                        }
                        errorMessage = nil
                        isConnecting = true
                        Task {
                            TelegramClient.shared.configure(apiID: id, apiHash: apiHash)
                            try? KeychainStore.saveTelegramCredentials(apiID: id, apiHash: apiHash)
                            await appState.startTelegram(apiID: id, apiHash: apiHash)
                            isConnecting = false
                            if appState.hasTelegramCredentials {
                                dismiss()
                            } else {
                                errorMessage = appState.databaseError ?? "Connection failed"
                            }
                        }
                    }
                    .disabled(apiID.isEmpty || apiHash.isEmpty || isConnecting)
                }
            }
        }
    }
}

struct LoginStepsView: View {
    @Environment(AppState.self) private var appState
    @State private var phoneNumber = ""
    @State private var authCode = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isLoading = false

    private var currentStep: String {
        TelegramClient.shared.authStep.rawValue
    }

    var body: some View {
        VStack(spacing: 16) {
            switch TelegramClient.shared.authStep {
            case .phone:
                phoneView
            case .code:
                codeView
            case .password:
                passwordView
            case .confirmation:
                confirmationView
            default:
                ProgressView("Connecting…")
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
    }

    private var phoneView: some View {
        VStack(spacing: 12) {
            Text("Enter your phone number")
                .font(.headline)

            TextField("+1 234 567 8900", text: $phoneNumber)
                .keyboardType(.phonePad)
                .textFieldStyle(.roundedBorder)

            Button("Send Code") {
                Task {
                    isLoading = true
                    errorMessage = nil
                    do {
                        try await TelegramClient.shared.setAuthenticationPhoneNumber(phoneNumber)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    isLoading = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(phoneNumber.isEmpty || isLoading)
        }
    }

    private var codeView: some View {
        VStack(spacing: 12) {
            Text("Enter verification code")
                .font(.headline)

            TextField("Code", text: $authCode)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)

            Button("Verify") {
                Task {
                    isLoading = true
                    errorMessage = nil
                    do {
                        try await TelegramClient.shared.checkAuthenticationCode(authCode)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    isLoading = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(authCode.isEmpty || isLoading)
        }
    }

    private var passwordView: some View {
        VStack(spacing: 12) {
            Text("Two-Step Verification")
                .font(.headline)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)

            Button("Verify") {
                Task {
                    isLoading = true
                    errorMessage = nil
                    do {
                        try await TelegramClient.shared.checkAuthenticationPassword(password)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    isLoading = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(password.isEmpty || isLoading)
        }
    }

    private var confirmationView: some View {
        VStack(spacing: 12) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("Confirm Login")
                .font(.headline)
            Text("Open Telegram on another device and approve this login.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
#endif
