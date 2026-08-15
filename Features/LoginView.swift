import SwiftUI
import TDLibKit
import os

enum LoginStep {
    case phone
    case code
    case password
    case confirmation
}

// MARK: - Country database

/// A country entry for the login dial-code picker: ISO alpha-2 code, display name
/// and international dial code. Flag artwork is bundled as real PNGs in
/// `xCloud/Flags/{CODE}.png` (loaded via `CountryFlagView`) — no emoji flags.
struct Country: Identifiable, Hashable {
    let code: String
    let name: String
    let dialCode: String

    var id: String { code }
    var searchKey: String { "\(name) \(dialCode) \(code)".lowercased() }
}

enum CountryDatabase {
    /// The full pickable list, in a roughly population-weighted order so common
    /// countries sit at the top (mirrors how Telegram orders its country picker).
    static let all: [Country] = [
        Country(code: "US", name: "United States", dialCode: "+1"),
        Country(code: "GB", name: "United Kingdom", dialCode: "+44"),
        Country(code: "IN", name: "India", dialCode: "+91"),
        Country(code: "BR", name: "Brazil", dialCode: "+55"),
        Country(code: "RU", name: "Russia", dialCode: "+7"),
        Country(code: "MX", name: "Mexico", dialCode: "+52"),
        Country(code: "JP", name: "Japan", dialCode: "+81"),
        Country(code: "DE", name: "Germany", dialCode: "+49"),
        Country(code: "FR", name: "France", dialCode: "+33"),
        Country(code: "ID", name: "Indonesia", dialCode: "+62"),
        Country(code: "IT", name: "Italy", dialCode: "+39"),
        Country(code: "TR", name: "Turkey", dialCode: "+90"),
        Country(code: "KR", name: "South Korea", dialCode: "+82"),
        Country(code: "ES", name: "Spain", dialCode: "+34"),
        Country(code: "AR", name: "Argentina", dialCode: "+54"),
        Country(code: "CA", name: "Canada", dialCode: "+1"),
        Country(code: "AU", name: "Australia", dialCode: "+61"),
        Country(code: "VN", name: "Vietnam", dialCode: "+84"),
        Country(code: "TH", name: "Thailand", dialCode: "+66"),
        Country(code: "PH", name: "Philippines", dialCode: "+63"),
        Country(code: "MY", name: "Malaysia", dialCode: "+60"),
        Country(code: "PL", name: "Poland", dialCode: "+48"),
        Country(code: "NL", name: "Netherlands", dialCode: "+31"),
        Country(code: "SA", name: "Saudi Arabia", dialCode: "+966"),
        Country(code: "ZA", name: "South Africa", dialCode: "+27"),
        Country(code: "BD", name: "Bangladesh", dialCode: "+880"),
        Country(code: "PK", name: "Pakistan", dialCode: "+92"),
        Country(code: "NG", name: "Nigeria", dialCode: "+234"),
        Country(code: "EG", name: "Egypt", dialCode: "+20"),
        Country(code: "CN", name: "China", dialCode: "+86"),
        Country(code: "UA", name: "Ukraine", dialCode: "+380"),
        Country(code: "SE", name: "Sweden", dialCode: "+46"),
        Country(code: "BE", name: "Belgium", dialCode: "+32"),
        Country(code: "AT", name: "Austria", dialCode: "+43"),
        Country(code: "CH", name: "Switzerland", dialCode: "+41"),
        Country(code: "PT", name: "Portugal", dialCode: "+351"),
        Country(code: "GR", name: "Greece", dialCode: "+30"),
        Country(code: "CZ", name: "Czechia", dialCode: "+420"),
        Country(code: "NO", name: "Norway", dialCode: "+47"),
        Country(code: "DK", name: "Denmark", dialCode: "+45"),
        Country(code: "FI", name: "Finland", dialCode: "+358"),
        Country(code: "IE", name: "Ireland", dialCode: "+353"),
        Country(code: "IL", name: "Israel", dialCode: "+972"),
        Country(code: "AE", name: "United Arab Emirates", dialCode: "+971"),
        Country(code: "QA", name: "Qatar", dialCode: "+974"),
        Country(code: "KW", name: "Kuwait", dialCode: "+965"),
        Country(code: "JO", name: "Jordan", dialCode: "+962"),
        Country(code: "LB", name: "Lebanon", dialCode: "+961"),
        Country(code: "IQ", name: "Iraq", dialCode: "+964"),
        Country(code: "IR", name: "Iran", dialCode: "+98"),
        Country(code: "AF", name: "Afghanistan", dialCode: "+93"),
        Country(code: "NP", name: "Nepal", dialCode: "+977"),
        Country(code: "LK", name: "Sri Lanka", dialCode: "+94"),
        Country(code: "MM", name: "Myanmar", dialCode: "+95"),
        Country(code: "KH", name: "Cambodia", dialCode: "+855"),
        Country(code: "TW", name: "Taiwan", dialCode: "+886"),
        Country(code: "HK", name: "Hong Kong", dialCode: "+852"),
        Country(code: "NZ", name: "New Zealand", dialCode: "+64"),
        Country(code: "SG", name: "Singapore", dialCode: "+65"),
        Country(code: "KE", name: "Kenya", dialCode: "+254"),
        Country(code: "ET", name: "Ethiopia", dialCode: "+251"),
        Country(code: "GH", name: "Ghana", dialCode: "+233"),
        Country(code: "TZ", name: "Tanzania", dialCode: "+255"),
        Country(code: "UG", name: "Uganda", dialCode: "+256"),
        Country(code: "MA", name: "Morocco", dialCode: "+212"),
        Country(code: "DZ", name: "Algeria", dialCode: "+213"),
        Country(code: "TN", name: "Tunisia", dialCode: "+216"),
        Country(code: "SD", name: "Sudan", dialCode: "+249"),
        Country(code: "CM", name: "Cameroon", dialCode: "+237"),
        Country(code: "ZW", name: "Zimbabwe", dialCode: "+263"),
        Country(code: "ZM", name: "Zambia", dialCode: "+260"),
        Country(code: "MZ", name: "Mozambique", dialCode: "+258"),
        Country(code: "AO", name: "Angola", dialCode: "+244"),
        Country(code: "MU", name: "Mauritius", dialCode: "+230"),
        Country(code: "RW", name: "Rwanda", dialCode: "+250"),
        Country(code: "CO", name: "Colombia", dialCode: "+57"),
        Country(code: "VE", name: "Venezuela", dialCode: "+58"),
        Country(code: "PE", name: "Peru", dialCode: "+51"),
        Country(code: "CL", name: "Chile", dialCode: "+56"),
        Country(code: "EC", name: "Ecuador", dialCode: "+593"),
        Country(code: "BO", name: "Bolivia", dialCode: "+591"),
        Country(code: "PY", name: "Paraguay", dialCode: "+595"),
        Country(code: "UY", name: "Uruguay", dialCode: "+598"),
        Country(code: "GT", name: "Guatemala", dialCode: "+502"),
        Country(code: "HN", name: "Honduras", dialCode: "+504"),
        Country(code: "SV", name: "El Salvador", dialCode: "+503"),
        Country(code: "NI", name: "Nicaragua", dialCode: "+505"),
        Country(code: "CR", name: "Costa Rica", dialCode: "+506"),
        Country(code: "PA", name: "Panama", dialCode: "+507"),
        Country(code: "CU", name: "Cuba", dialCode: "+53"),
        Country(code: "DO", name: "Dominican Republic", dialCode: "+1"),
        Country(code: "PR", name: "Puerto Rico", dialCode: "+1"),
        Country(code: "JM", name: "Jamaica", dialCode: "+1"),
        Country(code: "TT", name: "Trinidad and Tobago", dialCode: "+1"),
        Country(code: "BS", name: "Bahamas", dialCode: "+1"),
        Country(code: "BB", name: "Barbados", dialCode: "+1"),
        Country(code: "IS", name: "Iceland", dialCode: "+354"),
        Country(code: "LU", name: "Luxembourg", dialCode: "+352"),
        Country(code: "MT", name: "Malta", dialCode: "+356"),
        Country(code: "CY", name: "Cyprus", dialCode: "+357"),
        Country(code: "EE", name: "Estonia", dialCode: "+372"),
        Country(code: "LV", name: "Latvia", dialCode: "+371"),
        Country(code: "LT", name: "Lithuania", dialCode: "+370"),
        Country(code: "SI", name: "Slovenia", dialCode: "+386"),
        Country(code: "HR", name: "Croatia", dialCode: "+385"),
        Country(code: "BA", name: "Bosnia and Herzegovina", dialCode: "+387"),
        Country(code: "RS", name: "Serbia", dialCode: "+381"),
        Country(code: "MK", name: "North Macedonia", dialCode: "+389"),
        Country(code: "AL", name: "Albania", dialCode: "+355"),
        Country(code: "BG", name: "Bulgaria", dialCode: "+359"),
        Country(code: "SK", name: "Slovakia", dialCode: "+421"),
        Country(code: "BY", name: "Belarus", dialCode: "+375"),
        Country(code: "MD", name: "Moldova", dialCode: "+373"),
        Country(code: "GE", name: "Georgia", dialCode: "+995"),
        Country(code: "AM", name: "Armenia", dialCode: "+374"),
        Country(code: "AZ", name: "Azerbaijan", dialCode: "+994"),
        Country(code: "KZ", name: "Kazakhstan", dialCode: "+7"),
        Country(code: "UZ", name: "Uzbekistan", dialCode: "+998"),
        Country(code: "KG", name: "Kyrgyzstan", dialCode: "+996"),
        Country(code: "TJ", name: "Tajikistan", dialCode: "+992"),
        Country(code: "TM", name: "Turkmenistan", dialCode: "+993"),
        Country(code: "MN", name: "Mongolia", dialCode: "+976"),
        Country(code: "BT", name: "Bhutan", dialCode: "+975"),
        Country(code: "MV", name: "Maldives", dialCode: "+960"),
        Country(code: "BN", name: "Brunei", dialCode: "+673"),
        Country(code: "YE", name: "Yemen", dialCode: "+967"),
        Country(code: "SY", name: "Syria", dialCode: "+963"),
        Country(code: "PS", name: "Palestine", dialCode: "+970"),
        Country(code: "TL", name: "Timor-Leste", dialCode: "+670"),
        Country(code: "PG", name: "Papua New Guinea", dialCode: "+675"),
        Country(code: "FJ", name: "Fiji", dialCode: "+679"),
        Country(code: "SB", name: "Solomon Islands", dialCode: "+677"),
        Country(code: "VU", name: "Vanuatu", dialCode: "+678"),
        Country(code: "WS", name: "Samoa", dialCode: "+685"),
        Country(code: "TO", name: "Tonga", dialCode: "+676"),
        Country(code: "HT", name: "Haiti", dialCode: "+509"),
        Country(code: "SR", name: "Suriname", dialCode: "+597"),
        Country(code: "GY", name: "Guyana", dialCode: "+592"),
        Country(code: "BZ", name: "Belize", dialCode: "+501"),
        Country(code: "LI", name: "Liechtenstein", dialCode: "+423"),
        Country(code: "MC", name: "Monaco", dialCode: "+377"),
        Country(code: "SM", name: "San Marino", dialCode: "+378"),
        Country(code: "GI", name: "Gibraltar", dialCode: "+350"),
        Country(code: "FO", name: "Faroe Islands", dialCode: "+298"),
        Country(code: "GL", name: "Greenland", dialCode: "+299"),
        Country(code: "AX", name: "Åland Islands", dialCode: "+358"),
        Country(code: "JE", name: "Jersey", dialCode: "+44"),
        Country(code: "GG", name: "Guernsey", dialCode: "+44"),
        Country(code: "IM", name: "Isle of Man", dialCode: "+44"),
        Country(code: "BM", name: "Bermuda", dialCode: "+1"),
        Country(code: "KY", name: "Cayman Islands", dialCode: "+1"),
        Country(code: "AW", name: "Aruba", dialCode: "+297"),
        Country(code: "CW", name: "Curaçao", dialCode: "+599"),
        Country(code: "GF", name: "French Guiana", dialCode: "+594"),
        Country(code: "GP", name: "Guadeloupe", dialCode: "+590"),
        Country(code: "MQ", name: "Martinique", dialCode: "+596"),
        Country(code: "RE", name: "Réunion", dialCode: "+262"),
        Country(code: "PF", name: "French Polynesia", dialCode: "+689"),
        Country(code: "NC", name: "New Caledonia", dialCode: "+687"),
        Country(code: "PM", name: "Saint Pierre and Miquelon", dialCode: "+508"),
        Country(code: "FK", name: "Falkland Islands", dialCode: "+500"),
        Country(code: "SH", name: "Saint Helena", dialCode: "+290"),
        Country(code: "IO", name: "British Indian Ocean Territory", dialCode: "+246"),
        Country(code: "CX", name: "Christmas Island", dialCode: "+61"),
        Country(code: "CC", name: "Cocos Islands", dialCode: "+61"),
        Country(code: "NF", name: "Norfolk Island", dialCode: "+672"),
        Country(code: "TK", name: "Tokelau", dialCode: "+690"),
        Country(code: "NU", name: "Niue", dialCode: "+683"),
        Country(code: "CK", name: "Cook Islands", dialCode: "+682"),
        Country(code: "PN", name: "Pitcairn Islands", dialCode: "+64"),
        Country(code: "EH", name: "Western Sahara", dialCode: "+212"),
        Country(code: "SJ", name: "Svalbard and Jan Mayen", dialCode: "+47"),
        Country(code: "ER", name: "Eritrea", dialCode: "+291"),
        Country(code: "DJ", name: "Djibouti", dialCode: "+253"),
        Country(code: "SO", name: "Somalia", dialCode: "+252"),
        Country(code: "CF", name: "Central African Republic", dialCode: "+236"),
        Country(code: "TD", name: "Chad", dialCode: "+235"),
        Country(code: "NE", name: "Niger", dialCode: "+227"),
        Country(code: "BF", name: "Burkina Faso", dialCode: "+226"),
        Country(code: "TG", name: "Togo", dialCode: "+228"),
        Country(code: "BJ", name: "Benin", dialCode: "+229"),
        Country(code: "GN", name: "Guinea", dialCode: "+224"),
        Country(code: "SL", name: "Sierra Leone", dialCode: "+232"),
        Country(code: "LR", name: "Liberia", dialCode: "+231"),
        Country(code: "MR", name: "Mauritania", dialCode: "+222"),
        Country(code: "GM", name: "Gambia", dialCode: "+220"),
        Country(code: "CV", name: "Cape Verde", dialCode: "+238"),
        Country(code: "GA", name: "Gabon", dialCode: "+241"),
        Country(code: "CG", name: "Republic of the Congo", dialCode: "+242"),
        Country(code: "CD", name: "DR Congo", dialCode: "+243"),
        Country(code: "BI", name: "Burundi", dialCode: "+257"),
        Country(code: "SZ", name: "Eswatini", dialCode: "+268"),
        Country(code: "LS", name: "Lesotho", dialCode: "+266"),
        Country(code: "SC", name: "Seychelles", dialCode: "+248"),
        Country(code: "KM", name: "Comoros", dialCode: "+269"),
        Country(code: "AD", name: "Andorra", dialCode: "+376"),
        Country(code: "VA", name: "Vatican City", dialCode: "+379"),
    ].sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    /// Loads the bundled real flag artwork for a country code, if present. The
    /// synchronized-resource group flattens the Flags/ folder into the bundle root,
    /// so try both the subdirectory and the root.
    static func flagImage(code: String) -> NSImage? {
        let candidates = [
            Bundle.main.url(forResource: code, withExtension: "png", subdirectory: "Flags"),
            Bundle.main.url(forResource: code, withExtension: "png"),
        ]
        guard let url = candidates.compactMap({ $0 }).first else { return nil }
        return NSImage(contentsOf: url)
    }

    static func code(forDialCode dialCode: String) -> String {
        all.first(where: { $0.dialCode == dialCode })?.code ?? "US"
    }

    static func name(forDialCode dialCode: String) -> String {
        all.first(where: { $0.dialCode == dialCode })?.name ?? dialCode
    }
}

/// Detects the user's home country from the system locale so the login screen
/// preselects the right dial code on first open.
struct CountryDetector {
    static var currentDialCode: String {
        guard let regionCode = Locale.current.region?.identifier else { return "+1" }
        return CountryDatabase.all.first(where: { $0.code == regionCode })?.dialCode ?? "+1"
    }
}

/// Renders a country's real flag from the bundled PNGs as a small rounded chip.
/// Falls back to a letter badge only if the artwork is somehow missing.
struct CountryFlagView: View {
    let code: String
    var height: CGFloat = 16

    var body: some View {
        Group {
            if let img = CountryDatabase.flagImage(code: code) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(.white.opacity(0.14))
                    .overlay(
                        Text(code)
                            .font(.system(size: max(height * 0.38, 8), weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                    )
            }
        }
        .frame(width: height * 1.6, height: height)
        .clipShape(RoundedRectangle(cornerRadius: height * 0.18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: height * 0.18, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                .allowsHitTesting(false)
        )
    }
}

/// The phone/code/password/confirmation login steps, driven by TDLib's live
/// authorization state. Embedded in the full-screen login gate.
///
/// Every auth call is guarded against the current state: firing an auth method while
/// TDLib is in a different state (e.g. submitting a code after it already advanced to the
/// 2FA password step, or calling resendAuthenticationCode from the other-device
/// confirmation step) returns an instant 400 "unexpected" error, which used to surface as
/// a confusing "login got out of sync". The guards instead let the UI follow TDLib's state.
struct LoginStepsView: View {
    @State private var dialCode = CountryDetector.currentDialCode
    @State private var phoneNumber = ""
    @State private var authCode = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var showCountryPicker = false
    @State private var restartHovering = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case code
        case password
    }

    private let logger = Logger(subsystem: "com.xcloud.app", category: "login")

    private var currentStep: LoginStep {
        switch TelegramClient.shared.authStep {
        case .code: return .code
        case .password: return .password
        case .confirmation: return .confirmation
        default: return .phone
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                if !titleForStep.isEmpty {
                    Text(titleForStep)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }

                Text(subtitleForStep)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Group {
                switch currentStep {
                case .phone: phoneInputView
                case .code: codeInputView
                case .password: passwordInputView
                case .confirmation: confirmationView
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: currentStep)
            .onChange(of: currentStep) { _, step in
                switch step {
                case .code: focusedField = .code
                case .password: focusedField = .password
                default: focusedField = nil
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Universal escape hatch: if a login attempt gets wedged (e.g. the
            // other-device confirmation never resolves because the other session was
            // signed out), reset the whole auth flow back to the phone step.
            Button(action: signOutAndRestart) {
                Label("Start over", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(restartHovering ? .white.opacity(0.9) : .white.opacity(0.55))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(restartHovering ? .white.opacity(0.10) : .white.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                            .allowsHitTesting(false)
                    )
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .onHover { restartHovering = $0 }
        }
        .padding(28)
    }

    // MARK: - Header text

    private var iconForStep: String {
        switch currentStep {
        case .phone: return "person.crop.circle.badge.checkmark"
        case .code: return "message.fill"
        case .password: return "lock.fill"
        case .confirmation: return "iphone.gen3"
        }
    }

    private var titleForStep: String {
        switch currentStep {
        case .phone: return "" // No title on the phone step — just the subtitle.
        case .code: return "Enter Code"
        case .password: return "Two-Step Verification"
        case .confirmation: return "Confirm Login"
        }
    }

    private var subtitleForStep: String {
        switch currentStep {
        case .phone: return "Enter your phone number to connect your Telegram account."
        case .code: return "We've sent a code via SMS or Telegram message."
        case .password: return "Your account is protected with an additional password."
        case .confirmation: return "Open Telegram on one of your other devices and tap the login confirmation."
        }
    }

    // MARK: - Input Views

    private var phoneInputView: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                // Country / dial-code chip — opens the searchable country popover.
                Button {
                    showCountryPicker = true
                } label: {
                    Text(dialCode)
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 62)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                                .allowsHitTesting(false)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showCountryPicker, arrowEdge: .bottom) {
                    CountryPickerView(dialCode: $dialCode)
                }

                TextField("Phone Number", text: $phoneNumber)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                            .allowsHitTesting(false)
                    )
                    .foregroundStyle(.white)
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .onSubmit { submitPhone() }
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
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                        .allowsHitTesting(false)
                )
                .foregroundStyle(.white)
                .font(.system(size: 24, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.center)
                .focused($focusedField, equals: .code)
                .onSubmit { submitCode() }

            Button(action: submitCode) {
                HStack {
                    if isLoading { ProgressView().tint(.white) }
                    else { Text("Verify") }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.xGlassProminent)
            .disabled(authCode.filter(\.isNumber).isEmpty || isLoading)

            Button(action: resendCode) {
                Text("Resend Code")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.blue.opacity(0.85))
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
        }
    }

    private var passwordInputView: some View {
        VStack(spacing: 16) {
            SecureField("Password", text: $password)
                .textFieldStyle(.plain)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08)))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                        .allowsHitTesting(false)
                )
                .foregroundStyle(.white)
                .font(.system(size: 16, weight: .medium))
                .focused($focusedField, equals: .password)
                .onSubmit { submitPassword() }

            Button(action: submitPassword) {
                HStack {
                    if isLoading { ProgressView().tint(.white) }
                    else { Text("Log In") }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.xGlassProminent)
            .disabled(password.isEmpty || isLoading)

            Text("Forgot it? Reset your password in the Telegram app on another device.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
    }

    private var confirmationView: some View {
        VStack(spacing: 16) {
            Image(systemName: iconForStep)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white.opacity(0.7))

            Button(action: checkConfirmation) {
                HStack {
                    if isLoading { ProgressView().tint(.white) }
                    else { Text("I've Confirmed — Check Again") }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.xGlassProminent)
            .disabled(isLoading)

            Text("Didn't get a prompt? Make sure you're logged into Telegram on another device.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Actions

    private func submitPhone() {
        Task { @MainActor in
            // Never fire auth calls while TDLib is in a different state — calling
            // setAuthenticationPhoneNumber in WaitCode/WaitPassword returns an instant
            // 400 "unexpected" error. The phone view only shows in the phone state, but
            // guard anyway so a stale UI can't shoot the wrong call.
            guard TelegramClient.shared.authStep == .phone || TelegramClient.shared.authStep == .unknown else {
                errorMessage = nil
                return
            }
            isLoading = true
            errorMessage = nil
            let fullNumber = dialCode + phoneNumber.filter(\.isNumber)
            do {
                try await TelegramClient.shared.setAuthenticationPhoneNumber(fullNumber)
            } catch {
                logger.error("setAuthenticationPhoneNumber failed: \(error.localizedDescription)")
                errorMessage = TelegramClient.describeAuthError(error, method: "setAuthenticationPhoneNumber")
            }
            isLoading = false
        }
    }

    private func submitCode() {
        Task { @MainActor in
            guard TelegramClient.shared.authStep == .code else {
                // The state may already have advanced (2FA password, other-device
                // confirmation, or ready) — surface that view instead of submitting a
                // code to the wrong state.
                errorMessage = nil
                return
            }
            isLoading = true
            errorMessage = nil
            do {
                try await TelegramClient.shared.checkAuthenticationCode(authCode.filter(\.isNumber))
            } catch {
                logger.error("checkAuthenticationCode failed: \(error.localizedDescription)")
                errorMessage = TelegramClient.describeAuthError(error, method: "checkAuthenticationCode")
            }
            isLoading = false
        }
    }

    private func submitPassword() {
        Task { @MainActor in
            guard TelegramClient.shared.authStep == .password else {
                errorMessage = nil
                return
            }
            isLoading = true
            errorMessage = nil
            do {
                try await TelegramClient.shared.checkAuthenticationPassword(password)
            } catch {
                logger.error("checkAuthenticationPassword failed: \(error.localizedDescription)")
                errorMessage = TelegramClient.describeAuthError(error, method: "checkAuthenticationPassword")
            }
            isLoading = false
        }
    }

    private func resendCode() {
        Task { @MainActor in
            // resendAuthenticationCode is only valid in WaitCode — never fire it from the
            // confirmation view (that would be an instant "unexpected" 400).
            guard TelegramClient.shared.authStep == .code else {
                errorMessage = nil
                return
            }
            isLoading = true
            errorMessage = nil
            do {
                try await TelegramClient.shared.resendAuthenticationCode()
            } catch {
                logger.error("resendAuthenticationCode failed: \(error.localizedDescription)")
                errorMessage = TelegramClient.describeAuthError(error, method: "resendAuthenticationCode")
            }
            isLoading = false
        }
    }

    /// The other-device confirmation has no auth call to make — TDLib pushes the state
    /// change to .ready on its own once the user confirms on another device. This just
    /// waits a few seconds and re-checks, so the button gives feedback without firing an
    /// invalid resendAuthenticationCode into the confirmation state.
    private func checkConfirmation() {
        Task { @MainActor in
            isLoading = true
            errorMessage = nil
            for _ in 0..<10 {
                if TelegramClient.shared.isAuthorized { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            isLoading = false
        }
    }

    /// Resets a wedged login (e.g. other-device confirmation that never resolves after
    /// the other session signed out) back to the phone step.
    private func signOutAndRestart() {
        Task { @MainActor in
            isLoading = true
            errorMessage = nil
            try? await TelegramClient.shared.logout()
            isLoading = false
        }
    }
}

// MARK: - Country picker popover

/// The searchable country list shown when the user taps the flag chip —
/// Telegram-style: a search field on top, then the matching countries with flag,
/// name and dial code.
struct CountryPickerView: View {
    @Binding var dialCode: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [Country] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return CountryDatabase.all }
        return CountryDatabase.all.filter { $0.searchKey.contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
                TextField("Search country or code", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .onSubmit { selectFirstMatch() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.08)))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .padding(12)

            Divider()
                .overlay(.white.opacity(0.08))

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { country in
                        CountryRow(
                            country: country,
                            isSelected: dialCode == country.dialCode
                        ) {
                            dialCode = country.dialCode
                            dismiss()
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(height: 320)
        }
        .frame(width: 360)
        .background(Color(red: 0.10, green: 0.11, blue: 0.14))
        .preferredColorScheme(.dark)
    }

    private func selectFirstMatch() {
        guard let first = filtered.first else { return }
        dialCode = first.dialCode
        dismiss()
    }
}

/// A single country row in the picker, with its own hover highlight.
private struct CountryRow: View {
    let country: Country
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                CountryFlagView(code: country.code, height: 15)
                Text(country.name)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(country.dialCode)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isSelected ? XTheme.accent.opacity(0.30)
                        : hovering ? Color.white.opacity(0.06) : .clear
                )
                .padding(.horizontal, 5)
        )
        .onHover { hovering = $0 }
    }
}
