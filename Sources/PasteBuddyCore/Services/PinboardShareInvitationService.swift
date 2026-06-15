import CryptoKit
import Foundation

public struct PinboardSharePublicIdentity: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var displayName: String
    public var publicKeyData: Data
    public var publicKeyFingerprint: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String,
        publicKeyData: Data,
        publicKeyFingerprint: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.publicKeyData = publicKeyData
        self.publicKeyFingerprint = publicKeyFingerprint
        self.createdAt = createdAt
    }
}

public struct PinboardShareInvitationPackage: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var pinboardID: UUID
    public var participantID: UUID
    public var permission: PinboardSharePermission
    public var ownerIdentity: PinboardSharePublicIdentity
    public var recipientIdentity: PinboardSharePublicIdentity
    public var boardKeyFingerprint: String
    public var wrappedBoardKey: PinboardWrappedBoardKey
    public var createdAt: Date
    public var expiresAt: Date?

    public init(
        id: UUID = UUID(),
        pinboardID: UUID,
        participantID: UUID,
        permission: PinboardSharePermission,
        ownerIdentity: PinboardSharePublicIdentity,
        recipientIdentity: PinboardSharePublicIdentity,
        boardKeyFingerprint: String,
        wrappedBoardKey: PinboardWrappedBoardKey,
        createdAt: Date = Date(),
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.pinboardID = pinboardID
        self.participantID = participantID
        self.permission = permission
        self.ownerIdentity = ownerIdentity
        self.recipientIdentity = recipientIdentity
        self.boardKeyFingerprint = boardKeyFingerprint
        self.wrappedBoardKey = wrappedBoardKey
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

public enum PinboardShareInvitationError: LocalizedError, Equatable {
    case invalidIdentityPublicKey
    case expiredInvitation
    case recipientMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidIdentityPublicKey:
            "Shared pinboard identity public key is invalid."
        case .expiredInvitation:
            "Shared pinboard invitation has expired."
        case .recipientMismatch:
            "Shared pinboard invitation belongs to a different recipient key."
        }
    }
}

public protocol PinboardShareInvitationTransport: Sendable {
    func publishIdentity(_ identity: PinboardSharePublicIdentity) async throws -> PinboardSharePublicIdentity
    func saveInvitation(_ package: PinboardShareInvitationPackage) async throws -> PinboardShareInvitationPackage
    func fetchInvitations(recipientPublicKeyFingerprint: String) async throws -> [PinboardShareInvitationPackage]
}

public final class PinboardShareInvitationDeliveryService: @unchecked Sendable {
    private let transport: any PinboardShareInvitationTransport

    public init(transport: any PinboardShareInvitationTransport) {
        self.transport = transport
    }

    @discardableResult
    public func publishIdentity(_ identity: PinboardSharePublicIdentity) async throws -> PinboardSharePublicIdentity {
        try await transport.publishIdentity(identity)
    }

    @discardableResult
    public func sendInvitation(_ package: PinboardShareInvitationPackage) async throws -> PinboardShareInvitationPackage {
        try await transport.saveInvitation(package)
    }

    public func fetchInvitations(
        for identity: PinboardSharePublicIdentity
    ) async throws -> [PinboardShareInvitationPackage] {
        try await transport.fetchInvitations(
            recipientPublicKeyFingerprint: identity.publicKeyFingerprint
        )
    }
}

public struct PinboardShareInvitationInboxRefreshResult: Equatable, Sendable {
    public var recipientIdentity: PinboardSharePublicIdentity
    public var fetchedPackageCount: Int
    public var savedEntries: [PinboardInvitationInboxEntry]

    public init(
        recipientIdentity: PinboardSharePublicIdentity,
        fetchedPackageCount: Int,
        savedEntries: [PinboardInvitationInboxEntry]
    ) {
        self.recipientIdentity = recipientIdentity
        self.fetchedPackageCount = fetchedPackageCount
        self.savedEntries = savedEntries
    }
}

@MainActor
public final class PinboardShareInvitationInboxRefreshService {
    private let deliveryService: PinboardShareInvitationDeliveryService
    private let invitationService: PinboardShareInvitationService

    public init(
        deliveryService: PinboardShareInvitationDeliveryService,
        invitationService: PinboardShareInvitationService = PinboardShareInvitationService()
    ) {
        self.deliveryService = deliveryService
        self.invitationService = invitationService
    }

    public func refreshPendingInvitations(
        for recipientIdentity: PinboardShareIdentity,
        displayName: String,
        into store: PasteBuddyStore,
        receivedAt: Date = Date()
    ) async throws -> PinboardShareInvitationInboxRefreshResult {
        let publicIdentity = try invitationService.publicIdentity(
            displayName: displayName,
            identity: recipientIdentity,
            createdAt: receivedAt
        )
        let packages = try await deliveryService.fetchInvitations(for: publicIdentity)
        let savedEntries = store.savePendingPinboardInvitationPackages(
            packages,
            receivedAt: receivedAt
        )
        return PinboardShareInvitationInboxRefreshResult(
            recipientIdentity: publicIdentity,
            fetchedPackageCount: packages.count,
            savedEntries: savedEntries
        )
    }
}

public final class PinboardShareInvitationService: Sendable {
    private let keyExchangeService: PinboardShareKeyExchangeService

    public init(keyExchangeService: PinboardShareKeyExchangeService = PinboardShareKeyExchangeService()) {
        self.keyExchangeService = keyExchangeService
    }

    public func publicIdentity(
        displayName: String,
        identity: PinboardShareIdentity,
        createdAt: Date = Date()
    ) throws -> PinboardSharePublicIdentity {
        try publicIdentity(
            displayName: displayName,
            publicKeyData: identity.publicKeyData,
            createdAt: createdAt
        )
    }

    public func publicIdentity(
        displayName: String,
        publicKeyData: Data,
        createdAt: Date = Date()
    ) throws -> PinboardSharePublicIdentity {
        do {
            _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKeyData)
        } catch {
            throw PinboardShareInvitationError.invalidIdentityPublicKey
        }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return PinboardSharePublicIdentity(
            displayName: trimmedName.isEmpty ? "PasteBuddy Device" : trimmedName,
            publicKeyData: publicKeyData,
            publicKeyFingerprint: Self.publicKeyFingerprint(for: publicKeyData),
            createdAt: createdAt
        )
    }

    public func makeInvitationPackage(
        pinboardID: UUID,
        participantID: UUID,
        permission: PinboardSharePermission,
        ownerIdentity: PinboardShareIdentity,
        ownerDisplayName: String,
        recipientIdentity: PinboardSharePublicIdentity,
        keyExchange: PinboardKeyExchangeState,
        createdAt: Date = Date(),
        expiresAt: Date? = nil
    ) throws -> PinboardShareInvitationPackage {
        guard recipientIdentity.publicKeyFingerprint == Self.publicKeyFingerprint(for: recipientIdentity.publicKeyData) else {
            throw PinboardShareInvitationError.invalidIdentityPublicKey
        }
        let ownerPublicIdentity = try publicIdentity(
            displayName: ownerDisplayName,
            identity: ownerIdentity,
            createdAt: createdAt
        )
        let boardKey = try keyExchangeService.unwrapOwnerBoardKey(
            from: keyExchange,
            ownerIdentity: ownerIdentity
        )
        let wrappedBoardKey = try keyExchangeService.wrapBoardKey(
            boardKey,
            recipientPublicKeyData: recipientIdentity.publicKeyData
        )
        return PinboardShareInvitationPackage(
            pinboardID: pinboardID,
            participantID: participantID,
            permission: permission,
            ownerIdentity: ownerPublicIdentity,
            recipientIdentity: recipientIdentity,
            boardKeyFingerprint: keyExchange.boardKeyFingerprint,
            wrappedBoardKey: wrappedBoardKey,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
    }

    public func acceptInvitation(
        _ package: PinboardShareInvitationPackage,
        recipientIdentity: PinboardShareIdentity,
        now: Date = Date()
    ) throws -> Data {
        if let expiresAt = package.expiresAt, expiresAt <= now {
            throw PinboardShareInvitationError.expiredInvitation
        }
        guard package.recipientIdentity.publicKeyData == recipientIdentity.publicKeyData,
              package.recipientIdentity.publicKeyFingerprint == Self.publicKeyFingerprint(for: recipientIdentity.publicKeyData) else {
            throw PinboardShareInvitationError.recipientMismatch
        }

        let boardKey = try keyExchangeService.unwrapBoardKey(
            package.wrappedBoardKey,
            recipientIdentity: recipientIdentity
        )
        try keyExchangeService.validateBoardKey(
            boardKey,
            fingerprint: package.boardKeyFingerprint
        )
        return boardKey
    }

    public static func publicKeyFingerprint(for publicKeyData: Data) -> String {
        SHA256.hash(data: publicKeyData).map { String(format: "%02x", $0) }.joined()
    }
}
