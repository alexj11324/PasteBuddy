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

public enum EncryptionServiceError: LocalizedError {
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)
    case secureEnclaveUnavailable(String)
    case keyWrappingFailed(String)
    case keyUnwrappingFailed(String)
    case invalidKeyMaterial
    case invalidSealedBox

    public var errorDescription: String? {
        switch self {
        case .keychainReadFailed(let status):
            "Keychain read failed with status \(status)."
        case .keychainWriteFailed(let status):
            "Keychain write failed with status \(status)."
        case .keychainDeleteFailed(let status):
            "Keychain delete failed with status \(status)."
        case .secureEnclaveUnavailable(let reason):
            "Secure Enclave key wrapping is unavailable: \(reason)"
        case .keyWrappingFailed(let reason):
            "Secure Enclave key wrapping failed: \(reason)"
        case .keyUnwrappingFailed(let reason):
            "Secure Enclave key unwrapping failed: \(reason)"
        case .invalidKeyMaterial:
            "Stored encryption key has an invalid size."
        case .invalidSealedBox:
            "Encrypted data could not be opened."
        }
    }
}

public protocol EncryptionKeyMaterialStore: Sendable {
    func loadOrCreateKeyData() throws -> Data
    func deleteStoredKeyMaterial() throws
}

public final class KeychainKeyMaterialStore: EncryptionKeyMaterialStore, @unchecked Sendable {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public func loadOrCreateKeyData() throws -> Data {
        var item: CFTypeRef?
        var query = keychainBaseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip

        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess {
            guard let data = item as? Data, data.count == 32 else {
                throw EncryptionServiceError.invalidKeyMaterial
            }
            return data
        }

        guard status == errSecItemNotFound else {
            throw EncryptionServiceError.keychainReadFailed(status)
        }

        let keyData = try Self.randomKeyData()
        var addQuery = keychainBaseQuery()
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecValueData as String] = keyData
        addQuery[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
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

    private func keychainBaseQuery() -> [String: Any] {
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

    private let wrappedKeyAccount: String
    private let privateKeyApplicationTag: Data

    public init(
        service: String = "com.pastebuddy.encryption",
        account: String = "primary-store-key"
    ) {
        self.service = service
        self.account = account
        wrappedKeyAccount = "\(account).secure-enclave-wrapped-aes-key"
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
        try saveWrappedKeyData(wrappedKey)
        return keyData
    }

    public func deleteStoredKeyMaterial() throws {
        var wrappedQuery = wrappedKeyQuery()
        wrappedQuery[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        let wrappedStatus = SecItemDelete(wrappedQuery as CFDictionary)
        guard wrappedStatus == errSecSuccess || wrappedStatus == errSecItemNotFound else {
            throw EncryptionServiceError.keychainDeleteFailed(wrappedStatus)
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
        if let key = try loadPrivateKey() {
            return key
        }
        return try createPrivateKey()
    }

    private func loadPrivateKey() throws -> SecKey? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(privateKeyQuery(returnRef: true) as CFDictionary, &item)
        if status == errSecSuccess {
            guard let key = item else {
                throw EncryptionServiceError.secureEnclaveUnavailable("private key reference was empty")
            }
            return (key as! SecKey)
        }
        if status == errSecItemNotFound {
            return nil
        }
        throw EncryptionServiceError.keychainReadFailed(status)
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

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: privateKeyApplicationTag,
                kSecAttrAccessControl as String: accessControl
            ]
        ]

        var createError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &createError) else {
            throw EncryptionServiceError.secureEnclaveUnavailable(Self.errorDescription(createError))
        }
        return privateKey
    }

    private func wrap(_ keyData: Data, with privateKey: SecKey) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw EncryptionServiceError.keyWrappingFailed("could not derive Secure Enclave public key")
        }
        guard SecKeyIsAlgorithmSupported(publicKey, .encrypt, Self.wrappingAlgorithm) else {
            throw EncryptionServiceError.keyWrappingFailed("ECIES AES-GCM wrapping is not supported")
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
            throw EncryptionServiceError.keyUnwrappingFailed("ECIES AES-GCM unwrapping is not supported")
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

    private func saveWrappedKeyData(_ data: Data) throws {
        var addQuery = wrappedKeyQuery()
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecValueData as String] = data
        addQuery[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            var updateQuery = wrappedKeyQuery()
            updateQuery[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
            let updateStatus = SecItemUpdate(
                updateQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw EncryptionServiceError.keychainWriteFailed(updateStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw EncryptionServiceError.keychainWriteFailed(status)
        }
    }

    private func wrappedKeyQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: wrappedKeyAccount
        ]
    }

    private func privateKeyQuery(returnRef: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: privateKeyApplicationTag
        ]
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        if returnRef {
            query[kSecReturnRef as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return query
    }

    private static func errorDescription(_ error: Unmanaged<CFError>?) -> String {
        guard let error = error?.takeRetainedValue() else {
            return "unknown Security framework error"
        }
        return CFErrorCopyDescription(error) as String
    }
}

public final class EncryptionService: @unchecked Sendable {
    public let service: String
    public let account: String
    public let keyID: String
    private let keyMaterialStore: any EncryptionKeyMaterialStore

    public init(
        service: String = "com.pastebuddy.encryption",
        account: String = "primary-store-key",
        keyID: String = "local-primary-v1",
        keyMaterialStore: (any EncryptionKeyMaterialStore)? = nil
    ) {
        self.service = service
        self.account = account
        self.keyID = keyID
        self.keyMaterialStore = keyMaterialStore ?? KeychainKeyMaterialStore(
            service: service,
            account: account
        )
    }

    public static func secureEnclaveProtected(
        service: String = "com.pastebuddy.encryption",
        account: String = "primary-store-key",
        keyID: String = "local-secure-enclave-v1"
    ) -> EncryptionService {
        EncryptionService(
            service: service,
            account: account,
            keyID: keyID,
            keyMaterialStore: SecureEnclaveWrappedKeyStore(service: service, account: account)
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
        let key = try loadOrCreateKey()
        let sealed = try AES.GCM.SealedBox(combined: envelope.sealedData)
        return try AES.GCM.open(sealed, using: key)
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
