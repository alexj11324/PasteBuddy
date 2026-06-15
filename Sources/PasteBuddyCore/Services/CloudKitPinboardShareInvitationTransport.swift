#if canImport(CloudKit)
import CloudKit
import Foundation

public enum CloudKitPinboardShareRecordFactoryError: LocalizedError {
    case identityEncodingFailed(Error)
    case identityDecodingFailed(Error)
    case invitationEncodingFailed(Error)
    case invitationDecodingFailed(Error)
    case invalidField(String)
    case missingField(String)
    case wrongRecordType(recordType: String, expected: String)

    public var errorDescription: String? {
        switch self {
        case .identityEncodingFailed(let error):
            "CloudKit public identity record could not be encoded: \(error.localizedDescription)"
        case .identityDecodingFailed(let error):
            "CloudKit public identity record could not be decoded: \(error.localizedDescription)"
        case .invitationEncodingFailed(let error):
            "CloudKit invitation record could not be encoded: \(error.localizedDescription)"
        case .invitationDecodingFailed(let error):
            "CloudKit invitation record could not be decoded: \(error.localizedDescription)"
        case .invalidField(let field):
            "CloudKit pinboard sharing record contains an invalid \(field) field."
        case .missingField(let field):
            "CloudKit pinboard sharing record is missing the \(field) field."
        case .wrongRecordType(let recordType, let expected):
            "CloudKit record type \(recordType) is not \(expected)."
        }
    }
}

public struct CloudKitPinboardShareRecordFactory: Sendable {
    public static let publicIdentityRecordType = "PasteBuddyPinboardShareIdentity"
    public static let invitationRecordType = "PasteBuddyPinboardShareInvitation"

    public static let identityIDField = "identityID"
    public static let displayNameField = "displayName"
    public static let publicKeyDataField = "publicKeyData"
    public static let publicKeyFingerprintField = "publicKeyFingerprint"
    public static let createdAtField = "createdAt"
    public static let publicIdentityDataField = "publicIdentityData"

    public static let invitationIDField = "invitationID"
    public static let pinboardIDField = "pinboardID"
    public static let participantIDField = "participantID"
    public static let permissionField = "permission"
    public static let ownerPublicKeyFingerprintField = "ownerPublicKeyFingerprint"
    public static let recipientPublicKeyFingerprintField = "recipientPublicKeyFingerprint"
    public static let boardKeyFingerprintField = "boardKeyFingerprint"
    public static let expiresAtField = "expiresAt"
    public static let invitationPackageDataField = "invitationPackageData"
    public static let invitationSubscriptionIDPrefix = "PasteBuddyPinboardShareInvitation."

    public init() {}

    public func makeIdentityRecord(from identity: PinboardSharePublicIdentity) throws -> CKRecord {
        let record = CKRecord(
            recordType: Self.publicIdentityRecordType,
            recordID: CKRecord.ID(recordName: identity.publicKeyFingerprint)
        )
        record[Self.identityIDField] = identity.id.uuidString as NSString
        record[Self.displayNameField] = identity.displayName as NSString
        record[Self.publicKeyDataField] = identity.publicKeyData as NSData
        record[Self.publicKeyFingerprintField] = identity.publicKeyFingerprint as NSString
        record[Self.createdAtField] = identity.createdAt as NSDate
        do {
            record[Self.publicIdentityDataField] = try JSONEncoder.pasteBuddy
                .encode(identity) as NSData
        } catch {
            throw CloudKitPinboardShareRecordFactoryError.identityEncodingFailed(error)
        }
        return record
    }

    public func makePublicIdentity(from record: CKRecord) throws -> PinboardSharePublicIdentity {
        guard record.recordType == Self.publicIdentityRecordType else {
            throw CloudKitPinboardShareRecordFactoryError.wrongRecordType(
                recordType: record.recordType,
                expected: Self.publicIdentityRecordType
            )
        }
        let identityData = try dataField(Self.publicIdentityDataField, in: record)
        let identity: PinboardSharePublicIdentity
        do {
            identity = try JSONDecoder.pasteBuddy.decode(
                PinboardSharePublicIdentity.self,
                from: identityData
            )
        } catch {
            throw CloudKitPinboardShareRecordFactoryError.identityDecodingFailed(error)
        }

        let fingerprint = try stringField(Self.publicKeyFingerprintField, in: record)
        guard identity.publicKeyFingerprint == fingerprint,
              identity.publicKeyFingerprint == record.recordID.recordName else {
            throw CloudKitPinboardShareRecordFactoryError.invalidField(Self.publicKeyFingerprintField)
        }
        return identity
    }

    public func makeInvitationRecord(from package: PinboardShareInvitationPackage) throws -> CKRecord {
        let record = CKRecord(
            recordType: Self.invitationRecordType,
            recordID: CKRecord.ID(recordName: package.id.uuidString)
        )
        record[Self.invitationIDField] = package.id.uuidString as NSString
        record[Self.pinboardIDField] = package.pinboardID.uuidString as NSString
        record[Self.participantIDField] = package.participantID.uuidString as NSString
        record[Self.permissionField] = package.permission.rawValue as NSString
        record[Self.ownerPublicKeyFingerprintField] = package.ownerIdentity.publicKeyFingerprint as NSString
        record[Self.recipientPublicKeyFingerprintField] = package.recipientIdentity.publicKeyFingerprint as NSString
        record[Self.boardKeyFingerprintField] = package.boardKeyFingerprint as NSString
        record[Self.createdAtField] = package.createdAt as NSDate
        if let expiresAt = package.expiresAt {
            record[Self.expiresAtField] = expiresAt as NSDate
        }
        do {
            record[Self.invitationPackageDataField] = try JSONEncoder.pasteBuddy
                .encode(package) as NSData
        } catch {
            throw CloudKitPinboardShareRecordFactoryError.invitationEncodingFailed(error)
        }
        return record
    }

    public func makeInvitationPackage(from record: CKRecord) throws -> PinboardShareInvitationPackage {
        guard record.recordType == Self.invitationRecordType else {
            throw CloudKitPinboardShareRecordFactoryError.wrongRecordType(
                recordType: record.recordType,
                expected: Self.invitationRecordType
            )
        }
        let packageData = try dataField(Self.invitationPackageDataField, in: record)
        let package: PinboardShareInvitationPackage
        do {
            package = try JSONDecoder.pasteBuddy.decode(
                PinboardShareInvitationPackage.self,
                from: packageData
            )
        } catch {
            throw CloudKitPinboardShareRecordFactoryError.invitationDecodingFailed(error)
        }

        let invitationID = try stringField(Self.invitationIDField, in: record)
        let recipientFingerprint = try stringField(Self.recipientPublicKeyFingerprintField, in: record)
        guard package.id.uuidString == invitationID,
              record.recordID.recordName == invitationID else {
            throw CloudKitPinboardShareRecordFactoryError.invalidField(Self.invitationIDField)
        }
        guard package.recipientIdentity.publicKeyFingerprint == recipientFingerprint else {
            throw CloudKitPinboardShareRecordFactoryError.invalidField(Self.recipientPublicKeyFingerprintField)
        }
        return package
    }

    public func makeInvitationSubscriptionID(
        recipientPublicKeyFingerprint: String
    ) throws -> String {
        let trimmedFingerprint = recipientPublicKeyFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFingerprint.isEmpty else {
            throw CloudKitPinboardShareRecordFactoryError.invalidField(Self.recipientPublicKeyFingerprintField)
        }
        return "\(Self.invitationSubscriptionIDPrefix)\(trimmedFingerprint)"
    }

    public func makeInvitationNotificationRoute(
        subscriptionID: String
    ) throws -> CloudKitPinboardShareInvitationNotificationRoute {
        let trimmedSubscriptionID = subscriptionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSubscriptionID.hasPrefix(Self.invitationSubscriptionIDPrefix) else {
            throw CloudKitPinboardShareRecordFactoryError.invalidField("subscriptionID")
        }
        let fingerprintStartIndex = trimmedSubscriptionID.index(
            trimmedSubscriptionID.startIndex,
            offsetBy: Self.invitationSubscriptionIDPrefix.count
        )
        let recipientPublicKeyFingerprint = String(trimmedSubscriptionID[fingerprintStartIndex...])
        guard !recipientPublicKeyFingerprint.isEmpty else {
            throw CloudKitPinboardShareRecordFactoryError.invalidField(Self.recipientPublicKeyFingerprintField)
        }
        return CloudKitPinboardShareInvitationNotificationRoute(
            subscriptionID: trimmedSubscriptionID,
            recipientPublicKeyFingerprint: recipientPublicKeyFingerprint
        )
    }

    public func makeInvitationSubscription(
        recipientPublicKeyFingerprint: String
    ) throws -> CKQuerySubscription {
        let subscription = CKQuerySubscription(
            recordType: Self.invitationRecordType,
            predicate: NSPredicate(
                format: "%K == %@",
                Self.recipientPublicKeyFingerprintField,
                recipientPublicKeyFingerprint
            ),
            subscriptionID: try makeInvitationSubscriptionID(
                recipientPublicKeyFingerprint: recipientPublicKeyFingerprint
            ),
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo
        return subscription
    }

    private func stringField(_ field: String, in record: CKRecord) throws -> String {
        guard let value = record[field] else {
            throw CloudKitPinboardShareRecordFactoryError.missingField(field)
        }
        if let string = value as? String {
            return string
        }
        if let string = value as? NSString {
            return string as String
        }
        throw CloudKitPinboardShareRecordFactoryError.invalidField(field)
    }

    private func dataField(_ field: String, in record: CKRecord) throws -> Data {
        guard let value = record[field] else {
            throw CloudKitPinboardShareRecordFactoryError.missingField(field)
        }
        if let data = value as? Data {
            return data
        }
        if let data = value as? NSData {
            return data as Data
        }
        throw CloudKitPinboardShareRecordFactoryError.invalidField(field)
    }
}

public struct CloudKitPinboardShareInvitationNotificationRoute: Equatable, Sendable {
    public var subscriptionID: String
    public var recipientPublicKeyFingerprint: String

    public init(
        subscriptionID: String,
        recipientPublicKeyFingerprint: String
    ) {
        self.subscriptionID = subscriptionID
        self.recipientPublicKeyFingerprint = recipientPublicKeyFingerprint
    }
}

@MainActor
public final class CloudKitPinboardShareInvitationNotificationHandler {
    private let factory: CloudKitPinboardShareRecordFactory
    private let invitationService: PinboardShareInvitationService
    private let inboxRefreshService: PinboardShareInvitationInboxRefreshService

    public init(
        deliveryService: PinboardShareInvitationDeliveryService,
        invitationService: PinboardShareInvitationService = PinboardShareInvitationService(),
        factory: CloudKitPinboardShareRecordFactory = CloudKitPinboardShareRecordFactory()
    ) {
        self.factory = factory
        self.invitationService = invitationService
        self.inboxRefreshService = PinboardShareInvitationInboxRefreshService(
            deliveryService: deliveryService,
            invitationService: invitationService
        )
    }

    public func handleInvitationSubscription(
        subscriptionID: String,
        recipientIdentity: PinboardShareIdentity,
        displayName: String,
        store: PasteBuddyStore,
        receivedAt: Date = Date()
    ) async throws -> PinboardShareInvitationInboxRefreshResult? {
        let route = try factory.makeInvitationNotificationRoute(subscriptionID: subscriptionID)
        let publicIdentity = try invitationService.publicIdentity(
            displayName: displayName,
            identity: recipientIdentity,
            createdAt: receivedAt
        )
        guard route.recipientPublicKeyFingerprint == publicIdentity.publicKeyFingerprint else {
            return nil
        }
        return try await inboxRefreshService.refreshPendingInvitations(
            for: recipientIdentity,
            displayName: displayName,
            into: store,
            receivedAt: receivedAt
        )
    }
}

public final class CloudKitPinboardShareInvitationTransport: PinboardShareInvitationTransport, @unchecked Sendable {
    private let database: CKDatabase
    private let factory: CloudKitPinboardShareRecordFactory

    public init(
        containerIdentifier: String,
        databaseScope: CKDatabase.Scope = .public,
        factory: CloudKitPinboardShareRecordFactory = CloudKitPinboardShareRecordFactory()
    ) {
        let container = CKContainer(identifier: containerIdentifier)
        switch databaseScope {
        case .private:
            database = container.privateCloudDatabase
        case .public:
            database = container.publicCloudDatabase
        case .shared:
            database = container.sharedCloudDatabase
        @unknown default:
            database = container.publicCloudDatabase
        }
        self.factory = factory
    }

    public init(
        database: CKDatabase,
        factory: CloudKitPinboardShareRecordFactory = CloudKitPinboardShareRecordFactory()
    ) {
        self.database = database
        self.factory = factory
    }

    public func publishIdentity(_ identity: PinboardSharePublicIdentity) async throws -> PinboardSharePublicIdentity {
        let savedRecord = try await saveRecord(factory.makeIdentityRecord(from: identity))
        return try factory.makePublicIdentity(from: savedRecord)
    }

    public func saveInvitation(_ package: PinboardShareInvitationPackage) async throws -> PinboardShareInvitationPackage {
        let savedRecord = try await saveRecord(factory.makeInvitationRecord(from: package))
        return try factory.makeInvitationPackage(from: savedRecord)
    }

    public func fetchInvitations(recipientPublicKeyFingerprint: String) async throws -> [PinboardShareInvitationPackage] {
        let query = CKQuery(
            recordType: CloudKitPinboardShareRecordFactory.invitationRecordType,
            predicate: NSPredicate(
                format: "%K == %@",
                CloudKitPinboardShareRecordFactory.recipientPublicKeyFingerprintField,
                recipientPublicKeyFingerprint
            )
        )
        query.sortDescriptors = [
            NSSortDescriptor(key: CloudKitPinboardShareRecordFactory.createdAtField, ascending: true)
        ]
        let records = try await perform(query, limit: 100)
        return try records.map { try factory.makeInvitationPackage(from: $0) }
    }

    @discardableResult
    public func subscribeToInvitations(
        recipientPublicKeyFingerprint: String
    ) async throws -> CKSubscription {
        try await saveSubscription(
            factory.makeInvitationSubscription(
                recipientPublicKeyFingerprint: recipientPublicKeyFingerprint
            )
        )
    }

    private func saveRecord(_ record: CKRecord) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { continuation in
            database.save(record) { savedRecord, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let savedRecord {
                    continuation.resume(returning: savedRecord)
                } else {
                    continuation.resume(
                        throwing: CloudKitPinboardShareRecordFactoryError.invalidField("savedRecord")
                    )
                }
            }
        }
    }

    private func saveSubscription(_ subscription: CKSubscription) async throws -> CKSubscription {
        try await withCheckedThrowingContinuation { continuation in
            database.save(subscription) { savedSubscription, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let savedSubscription {
                    continuation.resume(returning: savedSubscription)
                } else {
                    continuation.resume(
                        throwing: CloudKitPinboardShareRecordFactoryError.invalidField("savedSubscription")
                    )
                }
            }
        }
    }

    private func perform(_ query: CKQuery, limit: Int) async throws -> [CKRecord] {
        guard limit > 0 else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            database.fetch(
                withQuery: query,
                inZoneWith: nil,
                desiredKeys: nil,
                resultsLimit: limit
            ) { result in
                switch result {
                case .success(let response):
                    do {
                        let records = try response.matchResults.map { _, recordResult in
                            try recordResult.get()
                        }
                        continuation.resume(returning: records)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
#endif
