import SwiftUI
import TDLibKit

enum LoginStep {
    case phone
    case code
    case password
}

struct CountryDetector {
    static var currentDialCode: String {
        guard let regionCode = Locale.current.region?.identifier else { return "+1" }
        let map: [String: String] = [
            "US": "+1", "CA": "+1", "GB": "+44", "IN": "+91", "AU": "+61",
            "DE": "+49", "FR": "+33", "ES": "+34", "IT": "+39", "BR": "+55",
            "JP": "+81", "KR": "+82", "CN": "+86", "RU": "+7", "AE": "+971",
            "SA": "+966", "ZA": "+27", "MX": "+52", "AR": "+54", "PK": "+92",
            "BD": "+880", "TR": "+90", "EG": "+20", "NG": "+234", "PH": "+63",
            "ID": "+62", "MY": "+60", "SG": "+65", "TH": "+66", "VN": "+84"
        ]
        return map[regionCode] ?? "+1"
    }
}

struct LoginView: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var dialCode = CountryDetector.currentDialCode
    @State private var phoneNumber = ""
    @State private var authCode = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isLoading = false
    
    private var currentStep: LoginStep {
        // Accessing the singleton directly ensures SwiftUI's @Observable tracks it
        switch TelegramClient.shared.authStep {
        case .code: return .code
        case .password: return .password
        default: return .phone
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            headerView
            
            Group {
                switch currentStep {
                case .phone: phoneInputView
                case .code: codeInputView
                case .password: passwordInputView
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: currentStep)
            
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(42)
        .glassEffect(.regular, in: .rect(cornerRadius: 30, style: .continuous))
        .frame(width: 480)
        .onChange(of: TelegramClient.shared.isAuthorized) { _, isAuth in
            if isAuth { dismiss() }
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        VStack(spacing: 12) {
            Image(systemName: iconForStep)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(XTheme.brandGradient)
            
            Text(titleForStep)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            
            Text(subtitleForStep)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
    }
    
    private var iconForStep: String {
        switch currentStep {
        case .phone: return "person.crop.circle.badge.checkmark"
        case .code: return "message.fill"
        case .password: return "lock.fill"
        }
    }
    
    private var titleForStep: String {
        switch currentStep {
        case .phone: return "Welcome to xCloud"
        case .code: return "Enter Code"
        case .password: return "Two-Step Verification"
        }
    }
    
    private var subtitleForStep: String {
        switch currentStep {
        case .phone: return "Enter your phone number to connect your Telegram account."
        case .code: return "We've sent a code via SMS or Telegram message."
        case .password: return "Your account is protected with an additional password."
        }
    }
    
    // MARK: - Input Views
    
    private var phoneInputView: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                TextField("+1", text: $dialCode)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .frame(width: 64)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
                    .foregroundStyle(.white.opacity(0.8))
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                
                TextField("Phone Number", text: $phoneNumber)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                    .foregroundStyle(.white)
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .onChange(of: phoneNumber) { _, newValue in
                        let filtered = newValue.filter { $0.isNumber || $0 == " " }
                        if filtered != newValue { phoneNumber = filtered }
                    }
            }
            
            Button(action: submitPhone) {
                HStack {
                    if isLoading { ProgressView().tint(.white) }
                    else { Text("Send Code") }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.xGlassProminent)
            .disabled(phoneNumber.filter(\.isNumber).count < 5 || isLoading)
        }
    }
    
    private var codeInputView: some View {
        VStack(spacing: 16) {
            TextField("12345", text: $authCode)
                .textFieldStyle(.plain)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .foregroundStyle(.white)
                .font(.system(size: 24, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.center)
            
            Button(action: submitCode) {
                HStack {
                    if isLoading { ProgressView().tint(.white) }
                    else { Text("Verify") }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.xGlassProminent)
            .disabled(authCode.filter(\.isNumber).isEmpty || isLoading)
        }
    }
    
    private var passwordInputView: some View {
        VStack(spacing: 16) {
            SecureField("Password", text: $password)
                .textFieldStyle(.plain)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .foregroundStyle(.white)
                .font(.system(size: 16, weight: .medium))
            
            Button(action: submitPassword) {
                HStack {
                    if isLoading { ProgressView().tint(.white) }
                    else { Text("Log In") }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.xGlassProminent)
            .disabled(password.isEmpty || isLoading)
        }
    }
    
    // MARK: - Actions
    
    private func submitPhone() {
        Task { @MainActor in
            isLoading = true
            errorMessage = nil
            let fullNumber = dialCode + phoneNumber.filter(\.isNumber)
            do {
                try await TelegramClient.shared.setAuthenticationPhoneNumber(fullNumber)
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
    
    private func submitCode() {
        Task { @MainActor in
            isLoading = true
            errorMessage = nil
            do {
                try await TelegramClient.shared.checkAuthenticationCode(authCode.filter(\.isNumber))
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
    
    private func submitPassword() {
        Task { @MainActor in
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
}
