import CryptoKit
import Foundation
import Security

public struct PinboardShareIdentity: Codable, Equatable, Sendable {
    public var privateKeyData: Data
    public var publicKeyData: Data

    public init(privateKeyData: Data, publicKeyData: Data) {
        self.privateKeyData = privateKeyData
        self.publicKeyData = publicKeyData
    }
}

public struct PinboardShareKeyExchangeSetup: Equatable, Sendable {
    public var state: PinboardKeyExchangeState
    public var boardKey: Data

    public init(state: PinboardKeyExchangeState, boardKey: Data) {
        self.state = state
        self.boardKey = boardKey
    }
}

public enum PinboardShareKeyExchangeError: LocalizedError, Equatable {
    case invalidPrivateKey
    case invalidPublicKey
    case missingKeyExchange
    case missingWrappedBoardKey
    case recipientMismatch
    case fingerprintMismatch
    case invalidBoardKeySize
    case sealFailed

    public var errorDescription: String? {
        switch self {
        case .invalidPrivateKey:
            "Pinboard sharing could not load the local key agreement private key."
        case .invalidPublicKey:
            "Pinboard sharing could not load the participant key agreement public key."
        case .missingKeyExchange:
            "Shared pinboard is missing encrypted key exchange metadata."
        case .missingWrappedBoardKey:
            "Shared pinboard participant is missing a wrapped board key."
        case .recipientMismatch:
            "Wrapped pinboard key belongs to a different participant key."
        case .fingerprintMismatch:
            "Unwrapped pinboard key does not match the expected fingerprint."
        case .invalidBoardKeySize:
            "Pinboard board key must be 32 bytes."
        case .sealFailed:
            "Pinboard board key could not be sealed for the participant."
        }
    }
}

public final class PinboardShareKeyExchangeService: Sendable {
    public static let boardKeyByteCount = 32
    private static let hkdfInfo = Data("PasteBuddy.PinboardShareKeyExchange.v1".utf8)

    public init() {}

    public func makeIdentity() -> PinboardShareIdentity {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        return PinboardShareIdentity(
            privateKeyData: privateKey.rawRepresentation,
            publicKeyData: privateKey.publicKey.rawRepresentation
        )
    }

    public func setupOwnerKeyExchange(
        ownerIdentity: PinboardShareIdentity,
        boardKey: Data? = nil,
        createdAt: Date = Date()
    ) throws -> PinboardShareKeyExchangeSetup {
        let resolvedBoardKey: Data
        if let boardKey {
            resolvedBoardKey = boardKey
        } else {
            resolvedBoardKey = try Self.randomBoardKey()
        }
        guard resolvedBoardKey.count == Self.boardKeyByteCount else {
            throw PinboardShareKeyExchangeError.invalidBoardKeySize
        }
        let wrappedKey = try wrapBoardKey(
            resolvedBoardKey,
            recipientPublicKeyData: ownerIdentity.publicKeyData
        )
        let state = PinboardKeyExchangeState(
            boardKeyFingerprint: Self.fingerprint(for: resolvedBoardKey),
            ownerPublicKeyData: ownerIdentity.publicKeyData,
            ownerWrappedBoardKey: wrappedKey,
            createdAt: createdAt
        )
        return PinboardShareKeyExchangeSetup(state: state, boardKey: resolvedBoardKey)
    }

    public func unwrapOwnerBoardKey(
        from state: PinboardKeyExchangeState,
        ownerIdentity: PinboardShareIdentity
    ) throws -> Data {
        let boardKey = try unwrapBoardKey(
            state.ownerWrappedBoardKey,
            recipientIdentity: ownerIdentity
        )
        guard Self.fingerprint(for: boardKey) == state.boardKeyFingerprint else {
            throw PinboardShareKeyExchangeError.fingerprintMismatch
        }
        return boardKey
    }

    public func wrapBoardKey(
        _ boardKey: Data,
        recipientPublicKeyData: Data
    ) throws -> PinboardWrappedBoardKey {
        guard boardKey.count == Self.boardKeyByteCount else {
            throw PinboardShareKeyExchangeError.invalidBoardKeySize
        }
        let recipientPublicKey: Curve25519.KeyAgreement.PublicKey
        do {
            recipientPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPublicKeyData)
        } catch {
            throw PinboardShareKeyExchangeError.invalidPublicKey
        }

        let ephemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let sharedSecret = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: recipientPublicKey)
        let sealingKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Self.hkdfInfo,
            outputByteCount: Self.boardKeyByteCount
        )
        let sealedBox = try AES.GCM.seal(boardKey, using: sealingKey)
        guard let sealedData = sealedBox.combined else {
            throw PinboardShareKeyExchangeError.sealFailed
        }

        return PinboardWrappedBoardKey(
            recipientPublicKeyData: recipientPublicKeyData,
            ephemeralPublicKeyData: ephemeralPrivateKey.publicKey.rawRepresentation,
            sealedBoardKeyData: sealedData
        )
    }

    public func unwrapBoardKey(
        _ wrappedKey: PinboardWrappedBoardKey,
        recipientIdentity: PinboardShareIdentity
    ) throws -> Data {
        guard wrappedKey.recipientPublicKeyData == recipientIdentity.publicKeyData else {
            throw PinboardShareKeyExchangeError.recipientMismatch
        }
        let recipientPrivateKey: Curve25519.KeyAgreement.PrivateKey
        let ephemeralPublicKey: Curve25519.KeyAgreement.PublicKey
        do {
            recipientPrivateKey = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: recipientIdentity.privateKeyData
            )
            ephemeralPublicKey = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: wrappedKey.ephemeralPublicKeyData
            )
        } catch {
            throw PinboardShareKeyExchangeError.invalidPrivateKey
        }

        let sharedSecret = try recipientPrivateKey.sharedSecretFromKeyAgreement(with: ephemeralPublicKey)
        let sealingKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Self.hkdfInfo,
            outputByteCount: Self.boardKeyByteCount
        )
        let sealedBox = try AES.GCM.SealedBox(combined: wrappedKey.sealedBoardKeyData)
        return try AES.GCM.open(sealedBox, using: sealingKey)
    }

    public func validateBoardKey(_ boardKey: Data, fingerprint: String) throws {
        guard Self.fingerprint(for: boardKey) == fingerprint else {
            throw PinboardShareKeyExchangeError.fingerprintMismatch
        }
    }

    public static func fingerprint(for boardKey: Data) -> String {
        SHA256.hash(data: boardKey).map { String(format: "%02x", $0) }.joined()
    }

    private static func randomBoardKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: boardKeyByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, boardKeyByteCount, &bytes)
        guard status == errSecSuccess else {
            throw PinboardShareKeyExchangeError.invalidBoardKeySize
        }
        return Data(bytes)
    }
}
