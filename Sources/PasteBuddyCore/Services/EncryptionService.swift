import CryptoKit
import Foundation
import Security

public struct EncryptedEnvelope: Codable, Equatable, Sendable {
    public var version: Int
    public var algorithm: String
    public var keyID: String
    public var createdAt: Date
    public var sealedData: Data

    public init(
        version: Int = 1,
        algorithm: String = "AES.GCM.256",
        keyID: String,
        createdAt: Date = Date(),
        sealedData: Data
    ) {
        self.version = version
        self.algorithm = algorithm
        self.keyID = keyID
        self.createdAt = createdAt
        self.sealedData = sealedData
    }
}

public enum EncryptionServiceError: LocalizedError, Equatable {
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)
    case secureEnclaveUnavailable(String)
    case keyWrappingFailed(String)
    case keyUnwrappingFailed(String)
    case invalidKeyMaterial
    case invalidSealedBox
    case unsupportedEnvelopeVersion(Int)
    case unsupportedAlgorithm(String)
    case keyIdentifierMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .keychainReadFailed(let status):
            PasteBuddyLocalization.format(
                "error.encryption.keychain_read_failed",
                defaultValue: "Keychain read failed with status %d.",
                status
            )
        case .keychainWriteFailed(let status):
            PasteBuddyLocalization.format(
                "error.encryption.keychain_write_failed",
                defaultValue: "Keychain write failed with status %d.",
                status
            )
        case .keychainDeleteFailed(let status):
            PasteBuddyLocalization.format(
                "error.encryption.keychain_delete_failed",
                defaultValue: "Keychain delete failed with status %d.",
                status
            )
        case .secureEnclaveUnavailable(let reason):
            PasteBuddyLocalization.format(
                "error.encryption.secure_enclave_unavailable",
                defaultValue: "Secure Enclave key wrapping is unavailable: %@",
                reason
            )
        case .keyWrappingFailed(let reason):
            PasteBuddyLocalization.format(
                "error.encryption.key_wrapping_failed",
                defaultValue: "Secure Enclave key wrapping failed: %@",
                reason
            )
        case .keyUnwrappingFailed(let reason):
            PasteBuddyLocalization.format(
                "error.encryption.key_unwrapping_failed",
                defaultValue: "Secure Enclave key unwrapping failed: %@",
                reason
            )
        case .invalidKeyMaterial:
            PasteBuddyLocalization.string(
                "error.encryption.invalid_key_material",
                defaultValue: "Stored encryption key has an invalid size."
            )
        case .invalidSealedBox:
            PasteBuddyLocalization.string(
                "error.encryption.invalid_sealed_box",
                defaultValue: "Encrypted data could not be opened."
            )
        case .unsupportedEnvelopeVersion(let version):
            PasteBuddyLocalization.format(
                "error.encryption.unsupported_envelope_version",
                defaultValue: "Encrypted envelope version %d is unsupported.",
                version
            )
        case .unsupportedAlgorithm(let algorithm):
            PasteBuddyLocalization.format(
                "error.encryption.unsupported_algorithm",
                defaultValue: "Encrypted envelope algorithm %@ is unsupported.",
                algorithm
            )
        case .keyIdentifierMismatch(let expected, let actual):
            PasteBuddyLocalization.format(
                "error.encryption.key_identifier_mismatch",
                defaultValue: "Encrypted envelope uses key %@, but %@ is required.",
                actual,
                expected
            )
        }
    }
}

public protocol EncryptionKeyMaterialStore: Sendable {
    func loadOrCreateKeyData() throws -> Data
    func deleteStoredKeyMaterial() throws
}

protocol ValidatingLegacyEncryptionKeyStore: EncryptionKeyMaterialStore {
    var requiresValidatedLegacyMigration: Bool { get }
    func loadPrimaryKeyData() throws -> Data?
    func loadLegacyKeyData() throws -> Data?
    func persistValidatedLegacyKeyData(_ keyData: Data) throws -> Data
}

public final class KeychainKeyMaterialStore: ValidatingLegacyEncryptionKeyStore, @unchecked Sendable {
    public let service: String
    public let account: String
    public let accessGroup: String?

    public init(service: String, account: String, accessGroup: String? = nil) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func loadOrCreateKeyData() throws -> Data {
        if let keyData = try loadPrimaryKeyData() {
            return keyData
        }
        if accessGroup != nil,
           let legacyKeyData = try loadLegacyKeyData() {
            return try saveKeyData(legacyKeyData)
        }
        return try saveKeyData(Self.randomKeyData())
    }

    var requiresValidatedLegacyMigration: Bool { accessGroup != nil }

    func loadPrimaryKeyData() throws -> Data? {
        try loadKeyData(query: keychainBaseQuery())
    }

    func loadLegacyKeyData() throws -> Data? {
        guard accessGroup != nil else { return nil }
        return try loadKeyData(query: legacyKeychainBaseQuery())
    }

    func persistValidatedLegacyKeyData(_ keyData: Data) throws -> Data {
        try saveKeyData(keyData)
    }

    private func loadKeyData(query baseQuery: [String: Any]) throws -> Data? {
        var item: CFTypeRef?
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw EncryptionServiceError.keychainReadFailed(status)
        }
        guard let data = item as? Data, data.count == 32 else {
            throw EncryptionServiceError.invalidKeyMaterial
        }
        return data
    }

    private func saveKeyData(_ keyData: Data) throws -> Data {
        var addQuery = keychainBaseQuery()
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecValueData as String] = keyData
        addQuery[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem,
           let storedKeyData = try loadKeyData(query: keychainBaseQuery()) {
            return storedKeyData
        }
        guard addStatus == errSecSuccess else {
            throw EncryptionServiceError.keychainWriteFailed(addStatus)
        }
        return keyData
    }

    public func deleteStoredKeyMaterial() throws {
        var query = keychainBaseQuery()
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw EncryptionServiceError.keychainDeleteFailed(status)
        }
    }

    func keychainBaseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    func legacyKeychainBaseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func randomKeyData() throws -> Data {
        let keyByteCount = 32
        var bytes = [UInt8](repeating: 0, count: keyByteCount)
        let status = bytes.withUnsafeMutableBytes { rawBuffer in
            SecRandomCopyBytes(kSecRandomDefault, keyByteCount, rawBuffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw EncryptionServiceError.keychainWriteFailed(status)
        }
        return Data(bytes)
    }
}

public final class SecureEnclaveWrappedKeyStore: EncryptionKeyMaterialStore, @unchecked Sendable {
    public static let wrappingAlgorithm: SecKeyAlgorithm = .eciesEncryptionStandardVariableIVX963SHA256AESGCM

    public let service: String
    public let account: String
    public let accessGroup: String?

    private let wrappedKeyAccount: String
    private let privateKeySelectorAccount: String
    private let privateKeyApplicationTag: Data

    public init(
        service: String = "com.pastebuddy.encryption",
        account: String = "primary-store-key",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
        wrappedKeyAccount = "\(account).secure-enclave-wrapped-aes-key"
        privateKeySelectorAccount = "\(account).secure-enclave-private-key-selector"
        privateKeyApplicationTag = Data("com.pastebuddy.secure-enclave.\(service).\(account)".utf8)
    }

    public func loadOrCreateKeyData() throws -> Data {
        let privateKey = try loadOrCreatePrivateKey()
        if let wrappedKey = try loadWrappedKeyData() {
            let unwrapped = try unwrap(wrappedKey, with: privateKey)
            guard unwrapped.count == 32 else {
                throw EncryptionServiceError.invalidKeyMaterial
            }
            return unwrapped
        }

        let keyData = try KeychainKeyMaterialStore.randomKeyData()
        let wrappedKey = try wrap(keyData, with: privateKey)
        let persistedWrappedKey = try saveWrappedKeyData(wrappedKey)
        let persistedKeyData = try unwrap(persistedWrappedKey, with: privateKey)
        guard persistedKeyData.count == 32 else {
            throw EncryptionServiceError.invalidKeyMaterial
        }
        return persistedKeyData
    }

    public func deleteStoredKeyMaterial() throws {
        var wrappedQuery = wrappedKeyQuery()
        wrappedQuery[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        let wrappedStatus = SecItemDelete(wrappedQuery as CFDictionary)
        guard wrappedStatus == errSecSuccess || wrappedStatus == errSecItemNotFound else {
            throw EncryptionServiceError.keychainDeleteFailed(wrappedStatus)
        }

        let selectorStatus = SecItemDelete(privateKeySelectorQuery() as CFDictionary)
        guard selectorStatus == errSecSuccess || selectorStatus == errSecItemNotFound else {
            throw EncryptionServiceError.keychainDeleteFailed(selectorStatus)
        }

        let privateKeyStatus = SecItemDelete(privateKeyQuery(returnRef: false) as CFDictionary)
        guard privateKeyStatus == errSecSuccess || privateKeyStatus == errSecItemNotFound else {
            throw EncryptionServiceError.keychainDeleteFailed(privateKeyStatus)
        }
    }

    public func loadWrappedKeyDataForTesting() throws -> Data? {
        try loadWrappedKeyData()
    }

    private func loadOrCreatePrivateKey() throws -> SecKey {
        if let key = try loadSelectedPrivateKey() {
            return key
        }
        if let key = try migrateUnselectedPrivateKey() {
            return key
        }
        let candidate = try createPrivateKey()
        return try selectPrivateKey(candidate)
    }

    private func loadSelectedPrivateKey() throws -> SecKey? {
        guard let applicationLabel = try loadPrivateKeySelector() else { return nil }
        guard let key = try loadPrivateKey(applicationLabel: applicationLabel) else {
            throw EncryptionServiceError.secureEnclaveUnavailable(
                Self.localizedReason(
                    "error.encryption.reason.selected_private_key_missing",
                    defaultValue: "The selected Secure Enclave private key is missing."
                )
            )
        }
        return key
    }

    private func migrateUnselectedPrivateKey() throws -> SecKey? {
        let applicationLabels = try privateKeyApplicationLabels()
        guard !applicationLabels.isEmpty else { return nil }

        if let wrappedKeyData = try loadWrappedKeyData() {
            var matchingKeys: [SecKey] = []
            for applicationLabel in applicationLabels {
                guard let key = try loadPrivateKey(applicationLabel: applicationLabel),
                      let keyData = try? unwrap(wrappedKeyData, with: key),
                      keyData.count == 32 else {
                    continue
                }
                matchingKeys.append(key)
            }
            if matchingKeys.count == 1, let matchingKey = matchingKeys.first {
                return try selectPrivateKey(matchingKey)
            }
            if let concurrentlySelectedKey = try loadSelectedPrivateKey() {
                return concurrentlySelectedKey
            }
            if matchingKeys.count > 1 {
                throw EncryptionServiceError.keyUnwrappingFailed(
                    Self.localizedReason(
                        "error.encryption.reason.multiple_private_keys_match",
                        defaultValue: "Multiple Secure Enclave private keys can unwrap the persisted AES key."
                    )
                )
            }
            throw EncryptionServiceError.keyUnwrappingFailed(
                Self.localizedReason(
                    "error.encryption.reason.no_private_key_matches",
                    defaultValue: "No stored Secure Enclave private key can unwrap the persisted AES key."
                )
            )
        }

        guard let key = try loadPrivateKey(applicationLabel: applicationLabels[0]) else {
            throw EncryptionServiceError.secureEnclaveUnavailable(
                Self.localizedReason(
                    "error.encryption.reason.private_key_reference_missing",
                    defaultValue: "The private key reference is missing."
                )
            )
        }
        return try selectPrivateKey(key)
    }

    private func loadPrivateKey(applicationLabel: Data) throws -> SecKey? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(
            privateKeyQuery(returnRef: true, applicationLabel: applicationLabel) as CFDictionary,
            &item
        )
        if status == errSecSuccess {
            guard let item, CFGetTypeID(item) == SecKeyGetTypeID() else {
                throw EncryptionServiceError.secureEnclaveUnavailable(
                    Self.localizedReason(
                        "error.encryption.reason.private_key_reference_invalid",
                        defaultValue: "The private key reference is missing or invalid."
                    )
                )
            }
            let key = item as! SecKey
            _ = try privateKeyApplicationLabel(for: key)
            return key
        }
        if status == errSecItemNotFound {
            return nil
        }
        throw EncryptionServiceError.keychainReadFailed(status)
    }

    private func privateKeyApplicationLabels() throws -> [Data] {
        var item: CFTypeRef?
        var query = privateKeyQuery(returnRef: false)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw EncryptionServiceError.keychainReadFailed(status)
        }
        guard let records = item as? [[String: Any]] else {
            throw EncryptionServiceError.secureEnclaveUnavailable(
                Self.localizedReason(
                    "error.encryption.reason.private_key_attributes_invalid",
                    defaultValue: "The private key attributes are invalid."
                )
            )
        }
        return records.compactMap { $0[kSecAttrApplicationLabel as String] as? Data }
    }

    private func createPrivateKey() throws -> SecKey {
        var accessControlError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage],
            &accessControlError
        ) else {
            throw EncryptionServiceError.secureEnclaveUnavailable(Self.errorDescription(accessControlError))
        }

        var privateKeyAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: privateKeyApplicationTag,
            kSecAttrAccessControl as String: accessControl
        ]
        if let accessGroup {
            privateKeyAttributes[kSecAttrAccessGroup as String] = accessGroup
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: privateKeyAttributes
        ]

        var createError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &createError) else {
            throw EncryptionServiceError.secureEnclaveUnavailable(Self.errorDescription(createError))
        }
        return privateKey
    }

    private func selectPrivateKey(_ candidate: SecKey) throws -> SecKey {
        let candidateLabel = try privateKeyApplicationLabel(for: candidate)
        let winnerLabel = try savePrivateKeySelector(candidateLabel)
        guard let winner = try loadPrivateKey(applicationLabel: winnerLabel) else {
            throw EncryptionServiceError.secureEnclaveUnavailable(
                Self.localizedReason(
                    "error.encryption.reason.selected_private_key_unloadable",
                    defaultValue: "The selected private key could not be loaded."
                )
            )
        }
        if candidateLabel != winnerLabel {
            try deletePrivateKey(applicationLabel: candidateLabel)
        }
        return winner
    }

    private func privateKeyApplicationLabel(for key: SecKey) throws -> Data {
        guard let attributes = SecKeyCopyAttributes(key) as? [String: Any],
              let tokenID = attributes[kSecAttrTokenID as String] as? String,
              tokenID == (kSecAttrTokenIDSecureEnclave as String),
              let applicationLabel = attributes[kSecAttrApplicationLabel as String] as? Data,
              !applicationLabel.isEmpty else {
            throw EncryptionServiceError.secureEnclaveUnavailable(
                Self.localizedReason(
                    "error.encryption.reason.private_key_not_secure_enclave",
                    defaultValue: "The private key is not a valid Secure Enclave key."
                )
            )
        }
        return applicationLabel
    }

    private func loadPrivateKeySelector() throws -> Data? {
        var item: CFTypeRef?
        var query = privateKeySelectorQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw EncryptionServiceError.keychainReadFailed(status)
        }
        guard let applicationLabel = item as? Data, !applicationLabel.isEmpty else {
            throw EncryptionServiceError.invalidKeyMaterial
        }
        return applicationLabel
    }

    private func savePrivateKeySelector(_ applicationLabel: Data) throws -> Data {
        var query = privateKeySelectorQuery()
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecValueData as String] = applicationLabel
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard let winner = try loadPrivateKeySelector() else {
                throw EncryptionServiceError.keychainReadFailed(errSecItemNotFound)
            }
            return winner
        }
        guard status == errSecSuccess else {
            throw EncryptionServiceError.keychainWriteFailed(status)
        }
        return applicationLabel
    }

    private func deletePrivateKey(applicationLabel: Data) throws {
        let status = SecItemDelete(
            privateKeyQuery(returnRef: false, applicationLabel: applicationLabel) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw EncryptionServiceError.keychainDeleteFailed(status)
        }
    }

    private func wrap(_ keyData: Data, with privateKey: SecKey) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw EncryptionServiceError.keyWrappingFailed(
                Self.localizedReason(
                    "error.encryption.reason.public_key_derivation_failed",
                    defaultValue: "The Secure Enclave public key could not be derived."
                )
            )
        }
        guard SecKeyIsAlgorithmSupported(publicKey, .encrypt, Self.wrappingAlgorithm) else {
            throw EncryptionServiceError.keyWrappingFailed(
                Self.localizedReason(
                    "error.encryption.reason.wrapping_algorithm_unsupported",
                    defaultValue: "ECIES AES-GCM key wrapping is not supported."
                )
            )
        }

        var wrapError: Unmanaged<CFError>?
        guard let wrapped = SecKeyCreateEncryptedData(
            publicKey,
            Self.wrappingAlgorithm,
            keyData as CFData,
            &wrapError
        ) else {
            throw EncryptionServiceError.keyWrappingFailed(Self.errorDescription(wrapError))
        }
        return wrapped as Data
    }

    private func unwrap(_ wrappedKeyData: Data, with privateKey: SecKey) throws -> Data {
        guard SecKeyIsAlgorithmSupported(privateKey, .decrypt, Self.wrappingAlgorithm) else {
            throw EncryptionServiceError.keyUnwrappingFailed(
                Self.localizedReason(
                    "error.encryption.reason.unwrapping_algorithm_unsupported",
                    defaultValue: "ECIES AES-GCM key unwrapping is not supported."
                )
            )
        }

        var unwrapError: Unmanaged<CFError>?
        guard let keyData = SecKeyCreateDecryptedData(
            privateKey,
            Self.wrappingAlgorithm,
            wrappedKeyData as CFData,
            &unwrapError
        ) else {
            throw EncryptionServiceError.keyUnwrappingFailed(Self.errorDescription(unwrapError))
        }
        return keyData as Data
    }

    private func loadWrappedKeyData() throws -> Data? {
        var item: CFTypeRef?
        var query = wrappedKeyQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip

        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess {
            guard let data = item as? Data, !data.isEmpty else {
                throw EncryptionServiceError.invalidKeyMaterial
            }
            return data
        }
        if status == errSecItemNotFound {
            return nil
        }
        throw EncryptionServiceError.keychainReadFailed(status)
    }

    private func saveWrappedKeyData(_ data: Data) throws -> Data {
        var addQuery = wrappedKeyQuery()
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecValueData as String] = data
        addQuery[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Never overwrite the key another caller already persisted: the
            // losing caller may otherwise return a key that can no longer
            // decrypt the next save. Re-read and return the durable winner.
            guard let storedData = try loadWrappedKeyData() else {
                throw EncryptionServiceError.keychainReadFailed(errSecItemNotFound)
            }
            return storedData
        }
        guard status == errSecSuccess else {
            throw EncryptionServiceError.keychainWriteFailed(status)
        }
        return data
    }

    private func wrappedKeyQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: wrappedKeyAccount
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func privateKeySelectorQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: privateKeySelectorAccount
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func privateKeyQuery(
        returnRef: Bool,
        applicationLabel: Data? = nil
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag as String: privateKeyApplicationTag
        ]
        if let applicationLabel {
            query[kSecAttrApplicationLabel as String] = applicationLabel
        }
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        if returnRef {
            query[kSecReturnRef as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return query
    }

    private static func errorDescription(_ error: Unmanaged<CFError>?) -> String {
        guard let error = error?.takeRetainedValue() else {
            return localizedReason(
                "error.encryption.reason.unknown_security_framework_error",
                defaultValue: "An unknown Security framework error occurred."
            )
        }
        return CFErrorCopyDescription(error) as String
    }

    private static func localizedReason(_ key: String, defaultValue: String) -> String {
        PasteBuddyLocalization.string(key, defaultValue: defaultValue)
    }
}

public final class EncryptionService: @unchecked Sendable {
    public static let supportedEnvelopeVersion = 1
    public static let supportedAlgorithm = "AES.GCM.256"
    public let service: String
    public let account: String
    public let keyID: String
    public let accessGroup: String?
    private let keyMaterialStore: any EncryptionKeyMaterialStore

    public init(
        service: String = "com.pastebuddy.encryption",
        account: String = "primary-store-key",
        keyID: String = "local-primary-v1",
        accessGroup: String? = nil,
        keyMaterialStore: (any EncryptionKeyMaterialStore)? = nil
    ) {
        self.service = service
        self.account = account
        self.keyID = keyID
        self.accessGroup = accessGroup
        self.keyMaterialStore = keyMaterialStore ?? KeychainKeyMaterialStore(
            service: service,
            account: account,
            accessGroup: accessGroup
        )
    }

    public static func secureEnclaveProtected(
        service: String = "com.pastebuddy.encryption",
        account: String = "primary-store-key",
        keyID: String = "local-secure-enclave-v1",
        accessGroup: String? = nil
    ) -> EncryptionService {
        EncryptionService(
            service: service,
            account: account,
            keyID: keyID,
            accessGroup: accessGroup,
            keyMaterialStore: SecureEnclaveWrappedKeyStore(
                service: service,
                account: account,
                accessGroup: accessGroup
            )
        )
    }

    public func encrypt<T: Encodable>(_ value: T) throws -> EncryptedEnvelope {
        let plaintext = try JSONEncoder.pasteBuddy.encode(value)
        return try encryptData(plaintext)
    }

    public func decrypt<T: Decodable>(_ type: T.Type, from envelope: EncryptedEnvelope) throws -> T {
        let plaintext = try decryptData(from: envelope)
        return try JSONDecoder.pasteBuddy.decode(T.self, from: plaintext)
    }

    public func encryptData(_ plaintext: Data) throws -> EncryptedEnvelope {
        let key = try loadOrCreateKey()
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw EncryptionServiceError.invalidSealedBox
        }
        return EncryptedEnvelope(keyID: keyID, sealedData: combined)
    }

    public func decryptData(from envelope: EncryptedEnvelope) throws -> Data {
        guard envelope.version == Self.supportedEnvelopeVersion else {
            throw EncryptionServiceError.unsupportedEnvelopeVersion(envelope.version)
        }
        guard envelope.algorithm == Self.supportedAlgorithm else {
            throw EncryptionServiceError.unsupportedAlgorithm(envelope.algorithm)
        }
        guard envelope.keyID == keyID else {
            throw EncryptionServiceError.keyIdentifierMismatch(expected: keyID, actual: envelope.keyID)
        }
        if let migrationStore = keyMaterialStore as? any ValidatingLegacyEncryptionKeyStore,
           migrationStore.requiresValidatedLegacyMigration {
            return try decryptDataWithValidatedLegacyMigration(
                envelope.sealedData,
                keyStore: migrationStore
            )
        }
        let key = try loadOrCreateKey()
        let sealed = try AES.GCM.SealedBox(combined: envelope.sealedData)
        return try AES.GCM.open(sealed, using: key)
    }

    private func decryptDataWithValidatedLegacyMigration(
        _ sealedData: Data,
        keyStore: any ValidatingLegacyEncryptionKeyStore
    ) throws -> Data {
        if let primaryKeyData = try keyStore.loadPrimaryKeyData() {
            return try open(sealedData, using: primaryKeyData)
        }
        guard let legacyKeyData = try keyStore.loadLegacyKeyData() else {
            throw EncryptionServiceError.invalidKeyMaterial
        }

        // The app, keyboard, and share extension historically had distinct
        // default Keychain groups while sharing one encrypted file. Prove a
        // legacy candidate against that file before it can become the shared
        // winner; a wrong extension-first candidate must leave no residue.
        let plaintext = try open(sealedData, using: legacyKeyData)
        let persistedKeyData = try keyStore.persistValidatedLegacyKeyData(legacyKeyData)
        if persistedKeyData == legacyKeyData {
            return plaintext
        }
        return try open(sealedData, using: persistedKeyData)
    }

    private func open(_ sealedData: Data, using keyData: Data) throws -> Data {
        guard keyData.count == 32 else {
            throw EncryptionServiceError.invalidKeyMaterial
        }
        let sealed = try AES.GCM.SealedBox(combined: sealedData)
        return try AES.GCM.open(sealed, using: SymmetricKey(data: keyData))
    }

    public func deleteKeyForTesting() throws {
        try keyMaterialStore.deleteStoredKeyMaterial()
    }

    private func loadOrCreateKey() throws -> SymmetricKey {
        let keyData = try keyMaterialStore.loadOrCreateKeyData()
        guard keyData.count == 32 else {
            throw EncryptionServiceError.invalidKeyMaterial
        }
        return SymmetricKey(data: keyData)
    }
}
