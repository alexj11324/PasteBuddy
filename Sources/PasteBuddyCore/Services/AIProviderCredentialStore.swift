import CryptoKit
import Foundation
import Security

public enum AIProviderCredentialRole: String, CaseIterable, Sendable {
    case document
    case embedding
}

public protocol AIProviderCredentialStoring: Sendable {
    func apiKey(for provider: BYOKProviderPreset, role: AIProviderCredentialRole, baseURL: String) throws -> String?
    func legacyAPIKey(for provider: BYOKProviderPreset) throws -> String?
    func saveAPIKey(_ apiKey: String, for provider: BYOKProviderPreset, role: AIProviderCredentialRole, baseURL: String) throws
    func deleteAPIKey(for provider: BYOKProviderPreset, role: AIProviderCredentialRole, baseURL: String) throws
    func deleteLegacyAPIKey(for provider: BYOKProviderPreset) throws
}

public final class KeychainAIProviderCredentialStore: AIProviderCredentialStoring, @unchecked Sendable {
    private let service: String
    private let accountPrefix: String

    public init(bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        service = "com.alexjiang.PasteBuddy.ai-byok"
        accountPrefix = bundleIdentifier ?? "com.alexjiang.PasteBuddy"
    }

    public func apiKey(
        for provider: BYOKProviderPreset,
        role: AIProviderCredentialRole,
        baseURL: String
    ) throws -> String? {
        try apiKey(query: baseQuery(for: provider, role: role, baseURL: baseURL))
    }

    public func legacyAPIKey(for provider: BYOKProviderPreset) throws -> String? {
        try apiKey(query: legacyBaseQuery(for: provider))
    }

    private func apiKey(query baseQuery: [String: Any]) throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw EncryptionServiceError.keychainReadFailed(status)
        }
        return value
    }

    public func saveAPIKey(
        _ apiKey: String,
        for provider: BYOKProviderPreset,
        role: AIProviderCredentialRole,
        baseURL: String
    ) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            throw EncryptionServiceError.invalidKeyMaterial
        }
        var query = baseQuery(for: provider, role: role, baseURL: baseURL)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let updateStatus = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw EncryptionServiceError.keychainWriteFailed(updateStatus)
            }
            return
        }
        guard status == errSecItemNotFound else { throw EncryptionServiceError.keychainReadFailed(status) }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw EncryptionServiceError.keychainWriteFailed(addStatus) }
    }

    public func deleteAPIKey(
        for provider: BYOKProviderPreset,
        role: AIProviderCredentialRole,
        baseURL: String
    ) throws {
        var query = baseQuery(for: provider, role: role, baseURL: baseURL)
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw EncryptionServiceError.keychainDeleteFailed(status)
        }
    }

    public func deleteLegacyAPIKey(for provider: BYOKProviderPreset) throws {
        var query = legacyBaseQuery(for: provider)
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw EncryptionServiceError.keychainDeleteFailed(status)
        }
    }

    private func baseQuery(
        for provider: BYOKProviderPreset,
        role: AIProviderCredentialRole,
        baseURL: String
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(accountPrefix).\(role.rawValue).\(provider.rawValue).\(endpointID(baseURL))"
        ]
    }

    private func legacyBaseQuery(for provider: BYOKProviderPreset) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(accountPrefix).\(provider.rawValue)"
        ]
    }

    private func endpointID(_ baseURL: String) -> String {
        let normalized = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
