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
            Theme.bg.ignoresSafeArea()

            if appState.isInitialLoading {
                loadingView
            } else if appState.isAuthorized {
                mainTabs
            } else {
                LoginGateView()
            }
        }
        .preferredColorScheme(.dark)
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
        .tint(Theme.accent)
    }
}

// MARK: - Login Gate

struct LoginGateView: View {
    @Environment(AppState.self) private var appState
    @State private var showSetup = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Brand
            VStack(spacing: 8) {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Theme.accent, Theme.accent.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: Theme.accent.opacity(0.4), radius: 20)

                Text("Cascade")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)

                Text("Your private cloud")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.bottom, 48)

            // Card
            card
                .padding(.horizontal, 24)

            Spacer()

            // Footer
            Text("Encrypted storage synced through Telegram")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .padding(.bottom, 16)
        }
        .task {
            // Auto-start TDLib if credentials exist but client isn't running
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

    private var card: some View {
        VStack(spacing: 0) {
            if !appState.hasTelegramCredentials {
                credentialsStep
            } else {
                LoginStepsView()
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerL, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerL, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.15), .white.opacity(0.03)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.5
                )
        )
        .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
    }

    private var credentialsStep: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("Connect to Telegram")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)

                Text("Enter your API credentials from my.telegram.org")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                showSetup = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.right.circle.fill")
                    Text("Get Started")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: [Theme.accent, Theme.accent.opacity(0.8)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerS, style: .continuous))
            }
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
            ZStack {
                Theme.bg.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        // Header
                        VStack(spacing: 8) {
                            Image(systemName: "key.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(Theme.accent)
                            Text("API Credentials")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(Theme.textPrimary)
                            Text("Get these from my.telegram.org\n→ API Development Tools")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 20)

                        // Fields
                        VStack(spacing: 16) {
                            fieldCard(label: "API ID", text: $apiID, placeholder: "12345678")
                                .focused($focusedField, equals: .apiID)
                                .keyboardType(.numberPad)
                                .onSubmit { focusedField = .apiHash }

                            fieldCard(label: "API Hash", text: $apiHash, placeholder: "0123456789abcdef...")
                                .focused($focusedField, equals: .apiHash)
                                .onSubmit { connect() }
                        }
                        .padding(.horizontal, 20)

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)
                        }

                        // Connect button
                        Button {
                            connect()
                        } label: {
                            HStack(spacing: 8) {
                                if isConnecting {
                                    ProgressView().tint(.white)
                                } else {
                                    Image(systemName: "link")
                                    Text("Connect")
                                }
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                apiID.isEmpty || apiHash.isEmpty || isConnecting
                                    ? AnyShapeStyle(Color.gray.opacity(0.3))
                                    : AnyShapeStyle(LinearGradient(
                                        colors: [Theme.accent, Theme.accent.opacity(0.8)],
                                        startPoint: .leading, endPoint: .trailing
                                    ))
                            )
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerS, style: .continuous))
                        }
                        .disabled(apiID.isEmpty || apiHash.isEmpty || isConnecting)
                        .padding(.horizontal, 20)
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .onAppear { focusedField = .apiID }
    }

    private func fieldCard(label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)

            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerS, style: .continuous)
                        .fill(Theme.cardBG)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerS, style: .continuous)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                )
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func connect() {
        guard let id = Int(apiID), !apiHash.isEmpty else {
            errorMessage = "Enter a valid API ID and Hash"
            return
        }
        errorMessage = nil
        isConnecting = true
        Task {
            await appState.startTelegram(apiID: id, apiHash: apiHash)
            isConnecting = false
            if appState.hasTelegramCredentials {
                dismiss()
            } else {
                errorMessage = appState.databaseError ?? "Connection failed"
            }
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
            stepHeader

            switch TelegramClient.shared.authStep {
            case .phone:
                phoneInput
            case .code:
                codeInput
            case .password:
                passwordInput
            case .confirmation:
                confirmationView
            default:
                ProgressView()
                    .tint(.white)
                    .padding(.vertical, 20)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: TelegramClient.shared.authStep)
    }

    private var stepHeader: some View {
        VStack(spacing: 4) {
            switch TelegramClient.shared.authStep {
            case .phone:
                EmptyView()
            case .code:
                Text("Verification Code")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Enter the code sent to your phone")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            case .password:
                Text("Two-Step Verification")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Enter your account password")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            case .confirmation:
                Text("Confirm Login")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Approve this login from another device")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            default:
                EmptyView()
            }
        }
        .multilineTextAlignment(.center)
    }

    // MARK: - Phone

    private var phoneInput: some View {
        VStack(spacing: 14) {
            Text("Enter your phone number")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textPrimary)

            HStack(spacing: 8) {
                // Dial code
                TextField("+1", text: $dialCode)
                    .textFieldStyle(.plain)
                    .frame(width: 60)
                    .padding(10)
                    .background(cardBG)
                    .overlay(cardBorder)
                    .foregroundStyle(Theme.textPrimary)
                    .keyboardType(.phonePad)
                    .focused($focusedField, equals: .phone)

                // Phone number
                TextField("234 567 8900", text: $phoneNumber)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(cardBG)
                    .overlay(cardBorder)
                    .foregroundStyle(Theme.textPrimary)
                    .keyboardType(.phonePad)
                    .focused($focusedField, equals: .phone)
            }

            Button {
                Task { await sendPhone() }
            } label: {
                HStack(spacing: 6) {
                    if isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Text("Send Code")
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerS, style: .continuous))
            }
            .disabled(phoneNumber.isEmpty || isLoading)
        }
        .onAppear { focusedField = .phone }
    }

    // MARK: - Code

    private var codeInput: some View {
        VStack(spacing: 14) {
            // Code digits display
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { i in
                    let char = i < authCode.count ? String(authCode[authCode.index(authCode.startIndex, offsetBy: i)]) : ""
                    Text(char)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 42, height: 50)
                        .background(cardBG)
                        .overlay(cardBorder)
                }
            }

            // Hidden text field
            TextField("", text: $authCode)
                .keyboardType(.numberPad)
                .frame(height: 1)
                .opacity(0.01)
                .focused($focusedField, equals: .code)

            Button {
                Task { await verifyCode() }
            } label: {
                HStack(spacing: 6) {
                    if isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Text("Verify")
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(authCode.count < 6 ? Color.gray.opacity(0.3) : Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerS, style: .continuous))
            }
            .disabled(authCode.count < 6 || isLoading)
        }
        .onAppear { focusedField = .code }
    }

    // MARK: - Password

    private var passwordInput: some View {
        VStack(spacing: 14) {
            SecureField("Password", text: $password)
                .textFieldStyle(.plain)
                .padding(12)
                .background(cardBG)
                .overlay(cardBorder)
                .foregroundStyle(Theme.textPrimary)
                .focused($focusedField, equals: .password)

            Button {
                Task { await verifyPassword() }
            } label: {
                HStack(spacing: 6) {
                    if isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Text("Verify")
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(password.isEmpty ? Color.gray.opacity(0.3) : Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerS, style: .continuous))
            }
            .disabled(password.isEmpty || isLoading)
        }
        .onAppear { focusedField = .password }
    }

    // MARK: - Confirmation

    private var confirmationView: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)

            Text("Open Telegram on another device and approve this login request.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 20)
    }

    // MARK: - Helpers

    private var cardBG: some View {
        RoundedRectangle(cornerRadius: Theme.cornerS, style: .continuous)
            .fill(Theme.cardBG)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: Theme.cornerS, style: .continuous)
            .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
    }

    // MARK: - Actions

    private func sendPhone() async {
        isLoading = true
        errorMessage = nil
        let full = "\(dialCode)\(phoneNumber)".replacingOccurrences(of: " ", with: "")
        do {
            try await TelegramClient.shared.setAuthenticationPhoneNumber(full)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func verifyCode() async {
        isLoading = true
        errorMessage = nil
        do {
            try await TelegramClient.shared.checkAuthenticationCode(authCode)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func verifyPassword() async {
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
#endif
