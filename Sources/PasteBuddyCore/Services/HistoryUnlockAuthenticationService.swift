import Foundation

#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

public enum HistoryUnlockAuthenticationError: LocalizedError, Equatable {
    case biometricsUnavailable(String)
    case authenticationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .biometricsUnavailable(let reason):
            "Touch ID is unavailable: \(reason)"
        case .authenticationFailed(let reason):
            "Touch ID authentication failed: \(reason)"
        }
    }
}

public protocol HistoryUnlockAuthenticating: Sendable {
    func authenticate(reason: String) async throws -> Bool
}

public struct SystemHistoryUnlockAuthenticator: HistoryUnlockAuthenticating {
    public init() {}

    public func authenticate(reason: String) async throws -> Bool {
        #if canImport(LocalAuthentication)
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw HistoryUnlockAuthenticationError.biometricsUnavailable(
                error?.localizedDescription ?? "biometric authentication is not available on this device"
            )
        }

        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
        } catch {
            throw HistoryUnlockAuthenticationError.authenticationFailed(error.localizedDescription)
        }
        #else
        throw HistoryUnlockAuthenticationError.biometricsUnavailable(
            "LocalAuthentication is unavailable on this platform"
        )
        #endif
    }
}
