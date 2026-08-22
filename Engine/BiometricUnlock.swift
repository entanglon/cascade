import Foundation
import LocalAuthentication

/// Wave 2 item 4 — biometric unlock for the Private Vault (Touch ID / Face ID).
///
/// The PIN stays the source of truth: a successful biometric only flips the
/// same in-memory unlock flag the PIN path flips (`AppState.isPrivateVaultUnlocked`)
/// and only substitutes the ENTER phase — PIN creation/confirm/recovery always
/// need the literal digits because they derive crypto material (PBKDF2 seal,
/// recovery blob). When the toggle is off or no sensor exists, the lock screen
/// behaves exactly as before.
enum BiometricUnlock {
    static let enabledKey = "xc.vault.biometricUnlock"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: enabledKey)
    }

    /// Human-readable sensor name for UI labels.
    static var biometryName: String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return "Biometric"
        }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "Biometric"
        }
    }

    static func isAvailable() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// Pure gate for the lock screen's biometric affordance (testable).
    nonisolated static func isEligible(enabled: Bool, hasPINHash: Bool, biometryAvailable: Bool) -> Bool {
        enabled && hasPINHash && biometryAvailable
    }

    /// Convenience wrapper used by the lock view.
    static func isEligible(hasPINHash: Bool) -> Bool {
        isEligible(enabled: isEnabled, hasPINHash: hasPINHash, biometryAvailable: isAvailable())
    }

    /// Runs the system biometric prompt. Biometrics ONLY — no system-passcode
    /// fallback (the app's own PIN screen is the fallback). Returns true on a
    /// successful match.
    @discardableResult
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "" // hide "Use Password…" — PIN is ours
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
        } catch {
            return false
        }
    }
}