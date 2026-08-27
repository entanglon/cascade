#if os(iOS)
import SwiftUI

// MARK: - Theme

private enum Theme {
    static let accent = Color(red: 0.25, green: 0.52, blue: 1.00)
    static let bg = Color(red: 0.06, green: 0.06, blue: 0.10)
    static let cardBG = Color.white.opacity(0.06)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.35)
    static let cornerS: CGFloat = 10
    static let cornerM: CGFloat = 14
    static let cornerL: CGFloat = 22
}

// MARK: - Root

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            if appState.isInitialLoading {
                loadingView
            } else if TelegramClient.shared.isAuthorized {
                mainTabs
            } else {
                LoginGateView()
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.accent)
            ProgressView()
                .tint(.white)
            Text("Loading…")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var mainTabs: some View {
        TabView {
            FileBrowserView()
                .tabItem {
                    Label("Browse", systemImage: "folder")
                }

            Text("Search")
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
        .task {
            // Run post-auth setup when we first see the main tabs
            if appState.allFiles.isEmpty {
                await appState.completePostAuthSetup()
            }
        }
    }
}

// MARK: - Login Gate

struct LoginGateView: View {
    @Environment(AppState.self) private var appState
    @State private var showSetup = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()

                VStack(spacing: 32) {
                    Spacer()

                    VStack(spacing: 8) {
                        Image(systemName: "cloud.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(Theme.accent)

                        Text("Cascade")
                            .font(.system(size: 32, weight: .bold, design: .rounded))

                        Text("Your private cloud")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if !appState.hasTelegramCredentials {
                        VStack(spacing: 16) {
                            Text("Connect your Telegram account to access your encrypted vault.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)

                            Button {
                                showSetup = true
                            } label: {
                                Text("Get Started")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(Theme.accent)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .padding(.horizontal, 32)
                        }
                    } else {
                        LoginStepsView()
                    }

                    Spacer()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if appState.databaseError != nil || appState.hasTelegramCredentials {
                        Button("Back") {
                            appState.logout()
                        }
                        .foregroundStyle(Theme.accent)
                    }
                }
            }
        }
        .task {
            if appState.hasTelegramCredentials, !TelegramClient.shared.isClientStarted {
                if let creds = try? KeychainStore.loadTelegramCredentials() {
                    await appState.startTelegram(apiID: creds.apiID, apiHash: creds.apiHash)
                }
            }
        }
        .sheet(isPresented: $showSetup) {
            TelegramSetupSheet()
        }
    }
}

// MARK: - Setup Sheet

struct TelegramSetupSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var apiID: String = ""
    @State private var apiHash: String = ""
    @State private var errorMessage: String?
    @State private var isConnecting = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case apiID, apiHash }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 4) {
                        Image(systemName: "key.fill")
                            .font(.title2)
                            .foregroundStyle(Theme.accent)
                        Text("Telegram API")
                            .font(.headline)
                        Text("Get these from my.telegram.org")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                Section("Credentials") {
                    TextField("API ID", text: $apiID)
                        .keyboardType(.numberPad)
                        .focused($focusedField, equals: .apiID)
                        .onSubmit { focusedField = .apiHash }

                    SecureField("API Hash", text: $apiHash)
                        .focused($focusedField, equals: .apiHash)
                        .onSubmit { connect() }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Connect") { connect() }
                        .disabled(apiID.isEmpty || apiHash.isEmpty || isConnecting)
                }
            }
        }
        .onAppear { focusedField = .apiID }
    }

    private func connect() {
        guard let id = Int(apiID), !apiHash.isEmpty else {
            errorMessage = "Enter valid API ID and Hash"
            return
        }
        errorMessage = nil
        isConnecting = true
        Task {
            await appState.startTelegram(apiID: id, apiHash: apiHash)
            isConnecting = false
            if appState.hasTelegramCredentials { dismiss() }
            else { errorMessage = appState.databaseError ?? "Connection failed" }
        }
    }
}

// MARK: - Login Steps

struct LoginStepsView: View {
    @Environment(AppState.self) private var appState
    @State private var phoneNumber = ""
    @State private var dialCode = "+1"
    @State private var authCode = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isLoading = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case phone, code, password }

    var body: some View {
        VStack(spacing: 20) {
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
                ProgressView()
                    .tint(.primary)
                    .padding(.vertical, 20)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 32)
        .animation(.easeInOut(duration: 0.2), value: TelegramClient.shared.authStep)
    }

    private var phoneView: some View {
        VStack(spacing: 14) {
            Text("Enter your phone number")
                .font(.headline)

            HStack(spacing: 8) {
                TextField("+1", text: $dialCode)
                    .textFieldStyle(.plain)
                    .frame(width: 56)
                    .padding(10)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .keyboardType(.phonePad)
                    .focused($focusedField, equals: .phone)

                TextField("234 567 8900", text: $phoneNumber)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .keyboardType(.phonePad)
                    .focused($focusedField, equals: .phone)
            }

            Button {
                Task { await sendPhone() }
            } label: {
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    Text("Send Code")
                }
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(phoneNumber.isEmpty ? Color.gray.opacity(0.3) : Theme.accent)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .disabled(phoneNumber.isEmpty || isLoading)
        }
        .onAppear { focusedField = .phone }
    }

    private var codeView: some View {
        VStack(spacing: 14) {
            Text("Verification Code")
                .font(.headline)
            Text("Enter the code sent to your phone")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("000000", text: $authCode)
                .textFieldStyle(.plain)
                .font(.title2.monospacedDigit().bold())
                .multilineTextAlignment(.center)
                .padding(12)
                .background(Color(.tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .keyboardType(.numberPad)
                .focused($focusedField, equals: .code)
                .onChange(of: authCode) { _, newValue in
                    authCode = String(newValue.prefix(6).filter(\.isNumber))
                }

            Button {
                focusedField = nil
                Task { await verifyCode() }
            } label: {
                HStack(spacing: 6) {
                    if isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Text("Verify")
                    }
                }
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(authCode.count < 6 ? Color.gray.opacity(0.3) : Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(authCode.count < 6 || isLoading)
        }
        .onAppear {
            authCode = ""
            focusedField = .code
        }
    }

    private var passwordView: some View {
        VStack(spacing: 14) {
            Text("Two-Step Verification")
                .font(.headline)

            SecureField("Password", text: $password)
                .textFieldStyle(.plain)
                .padding(12)
                .background(Color(.tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .focused($focusedField, equals: .password)

            Button {
                Task { await verifyPassword() }
            } label: {
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    Text("Verify")
                }
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(password.isEmpty ? Color.gray.opacity(0.3) : Theme.accent)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .disabled(password.isEmpty || isLoading)
        }
        .onAppear { focusedField = .password }
    }

    private var confirmationView: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)
            Text("Confirm Login")
                .font(.headline)
            Text("Approve this login from another device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 20)
    }

    private func sendPhone() async {
        isLoading = true; errorMessage = nil
        let full = "\(dialCode)\(phoneNumber)".replacingOccurrences(of: " ", with: "")
        do { try await TelegramClient.shared.setAuthenticationPhoneNumber(full) }
        catch { errorMessage = error.localizedDescription }
        isLoading = false
    }

    private func verifyCode() async {
        isLoading = true; errorMessage = nil
        do { try await TelegramClient.shared.checkAuthenticationCode(authCode) }
        catch { errorMessage = error.localizedDescription }
        isLoading = false
    }

    private func verifyPassword() async {
        isLoading = true; errorMessage = nil
        do { try await TelegramClient.shared.checkAuthenticationPassword(password) }
        catch { errorMessage = error.localizedDescription }
        isLoading = false
    }
}
#endif
