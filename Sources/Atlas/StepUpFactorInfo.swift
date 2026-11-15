import Foundation

/// What a step-up factor needs from the person. A factor the SDK does not know
/// yet (the server adds them in minor releases) maps to ``otp``.
public enum StepUpInputKind: String, Sendable, Equatable {
    case password, otp, none, redirect, push, webauthn
}

/// How to render a step-up factor. `factor` is the raw wire string.
public struct StepUpFactorInfo: Sendable, Equatable {
    public let factor: String
    public let label: String
    public let needsInput: Bool
    public let inputKind: StepUpInputKind
}

private let knownStepUpFactors: [String: (String, Bool, StepUpInputKind)] = [
    "password": ("Password", true, .password),
    "passkey": ("Passkey", false, .webauthn),
    "totp": ("Authenticator app code", true, .otp),
    "backup_code": ("Backup code", true, .otp),
    "email_code": ("Code sent by email", true, .otp),
    "phone_code": ("Code sent by text message", true, .otp),
    "push": ("Approve on your device", false, .push),
    "duo": ("Duo", false, .redirect),
    "yubikey": ("Security key code", true, .otp),
]

/// Every factor this SDK version knows; a newer server may offer more.
public let stepUpFactors: [String] = ["password", "passkey", "totp", "backup_code", "email_code", "phone_code", "push", "duo", "yubikey"]

/// Render info for any factor string; an unknown one gets a readable label and a typed-code input.
public func stepUpFactorInfo(_ factor: String) -> StepUpFactorInfo {
    if let k = knownStepUpFactors[factor] { return StepUpFactorInfo(factor: factor, label: k.0, needsInput: k.1, inputKind: k.2) }
    let words = factor.replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    let label = words.isEmpty ? "Verification" : words.prefix(1).uppercased() + words.dropFirst()
    return StepUpFactorInfo(factor: factor, label: label, needsInput: true, inputKind: .otp)
}
