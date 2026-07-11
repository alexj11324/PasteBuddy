import Foundation
import XCTest
@testable import PasteBuddyCore

extension PasteBuddyStoreTests {
    func testSyncDefaultsToLocalOnlyWithoutPlaintextFallback() {
        let sync = PasteBuddySnapshot().sync

        XCTAssertEqual(sync.provider, .none)
        XCTAssertFalse(sync.isCloudSyncEnabled)
        XCTAssertFalse(sync.isSharedPinboardsEnabled)
        XCTAssertFalse(sync.allowsPlaintextFallback)
        XCTAssertEqual(sync.readiness, .localOnly)
        XCTAssertFalse(sync.readiness.canAttemptCloudSync)
    }

    func testCloudSyncRequiresEncryptedCloudKitConfiguration() {
        var sync = SyncConfiguration(
            provider: .cloudKit,
            isCloudSyncEnabled: true,
            cloudKitContainerIdentifier: "iCloud.com.example.PasteBuddy"
        )

        XCTAssertEqual(sync.readiness, .blocked([.endToEndKeyHierarchy, .cloudKitCapability]))
        XCTAssertFalse(sync.readiness.canAttemptCloudSync)

        sync.isCloudKitCapabilityConfigured = true

        XCTAssertEqual(sync.readiness, .blocked([.endToEndKeyHierarchy]))
        XCTAssertFalse(sync.readiness.canAttemptCloudSync)

        sync.keyHierarchyVersion = 1

        XCTAssertEqual(sync.readiness, .ready)
        XCTAssertTrue(sync.readiness.canAttemptCloudSync)
        XCTAssertFalse(sync.allowsPlaintextFallback)
    }

    func testCloudSyncPreflightExplainsLocalOnlyModeAndEncryptionBoundary() {
        let report = CloudSyncPreflightReport(configuration: PasteBuddySnapshot().sync)

        XCTAssertEqual(report.readiness, .localOnly)
        XCTAssertFalse(report.canAttemptCloudSync)
        XCTAssertFalse(report.hasBlockers)
        XCTAssertEqual(report.summary, "Local only: CloudKit sync is disabled.")
        XCTAssertTrue(report.findings.contains { $0.id == "cloud-sync-local-only" })
    }

    func testCloudSyncPreflightReportsMissingRequirementsAndSharedPinboardBlocker() {
        let sync = SyncConfiguration(
            provider: .cloudKit,
            isCloudSyncEnabled: true,
            isSharedPinboardsEnabled: true
        )

        let report = CloudSyncPreflightReport(configuration: sync)

        XCTAssertEqual(
            report.readiness,
            .blocked([.cloudKitContainerIdentifier, .endToEndKeyHierarchy, .cloudKitCapability])
        )
        XCTAssertFalse(report.canAttemptCloudSync)
        XCTAssertTrue(report.hasBlockers)
        XCTAssertEqual(report.summary, "CloudKit sync is blocked by 4 required setup items.")
        XCTAssertTrue(report.findings.contains { $0.id == "missing-cloudkit-container" })
        XCTAssertTrue(report.findings.contains { $0.id == "missing-end-to-end-key-hierarchy" })
        XCTAssertTrue(report.findings.contains { $0.id == "missing-cloudkit-capability" })
        XCTAssertTrue(report.findings.contains { $0.id == "shared-pinboards-blocked" })
    }

    func testCloudSyncPreflightWarnsWhenReadyButFirstSyncOrConflictReviewIsPending() {
        var sync = SyncConfiguration(
            provider: .cloudKit,
            isCloudSyncEnabled: true,
            cloudKitContainerIdentifier: "iCloud.com.example.PasteBuddy",
            keyHierarchyVersion: 1,
            isCloudKitCapabilityConfigured: true,
            lastSyncConflictCount: 2
        )

        var report = CloudSyncPreflightReport(configuration: sync)

        XCTAssertEqual(report.readiness, .ready)
        XCTAssertTrue(report.canAttemptCloudSync)
        XCTAssertFalse(report.hasBlockers)
        XCTAssertEqual(report.summary, "Encrypted CloudKit sync is ready with 2 warnings.")
        XCTAssertTrue(report.findings.contains { $0.id == "cloud-sync-ready" })
        XCTAssertTrue(report.findings.contains { $0.id == "first-sync-pending" })
        XCTAssertTrue(report.findings.contains { $0.id == "last-sync-conflicts" })

        sync.lastSyncAt = Date()
        sync.lastSyncConflictCount = 0
        report = CloudSyncPreflightReport(configuration: sync)

        XCTAssertEqual(report.summary, "Encrypted CloudKit sync is ready.")
        XCTAssertFalse(report.findings.contains { $0.severity == .warning })
    }

    func testSharedPinboardsRequireReadyEncryptedSync() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.setSharedPinboardsEnabled(true)

        XCTAssertFalse(store.snapshot.sync.isSharedPinboardsEnabled)
        XCTAssertEqual(store.lastErrorMessage, "Shared pinboards require configured CloudKit sync and end-to-end encryption.")

        store.configureCloudKitSync(
            containerIdentifier: "iCloud.com.example.PasteBuddy",
            keyHierarchyVersion: 1,
            capabilityConfigured: true
        )
        store.setSharedPinboardsEnabled(true)

        XCTAssertEqual(store.snapshot.sync.readiness, .ready)
        XCTAssertTrue(store.snapshot.sync.isSharedPinboardsEnabled)

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertEqual(reloaded.snapshot.sync.readiness, .ready)
        XCTAssertTrue(reloaded.snapshot.sync.isSharedPinboardsEnabled)
        XCTAssertFalse(reloaded.snapshot.sync.allowsPlaintextFallback)
    }

    func testSharedPinboardParticipantManagementRequiresEncryptedSync() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let pinboardID = store.snapshot.pinboards[0].id

        XCTAssertNil(store.sharePinboard(pinboardID))
        XCTAssertNil(store.snapshot.pinboards[0].sharing)

        store.configureCloudKitSync(
            containerIdentifier: "iCloud.com.example.PasteBuddy",
            keyHierarchyVersion: 1,
            capabilityConfigured: true
        )
        store.setSharedPinboardsEnabled(true)

        let token = try XCTUnwrap(store.sharePinboard(
            pinboardID,
            ownerDisplayName: "Owner Mac",
            accessMode: .linkAccess,
            defaultPermission: .readOnly,
            linkToken: "single-use-share-token"
        ))

        XCTAssertEqual(token, "single-use-share-token")
        XCTAssertEqual(store.snapshot.pinboards[0].sharing?.ownerDisplayName, "Owner Mac")
        XCTAssertEqual(store.snapshot.pinboards[0].sharing?.accessMode, .linkAccess)
        XCTAssertNotNil(store.snapshot.pinboards[0].sharing?.shareLinkTokenHash)
        XCTAssertNotEqual(store.snapshot.pinboards[0].sharing?.shareLinkTokenHash, token)

        let participant = try XCTUnwrap(store.inviteParticipant(
            to: pinboardID,
            displayName: "Collaborator",
            emailAddress: "collaborator@example.com",
            permission: .readOnly
        ))

        XCTAssertEqual(store.snapshot.pinboards[0].sharing?.participants.count, 1)
        XCTAssertEqual(store.snapshot.pinboards[0].sharing?.participants.first?.permission, .readOnly)

        store.updateParticipantPermission(
            pinboardID: pinboardID,
            participantID: participant.id,
            permission: .canEdit
        )

        XCTAssertEqual(store.snapshot.pinboards[0].sharing?.participants.first?.permission, .canEdit)

        store.removeParticipant(pinboardID: pinboardID, participantID: participant.id)

        XCTAssertEqual(store.snapshot.pinboards[0].sharing?.participants, [])

        store.stopSharingPinboard(pinboardID)

        XCTAssertNil(store.snapshot.pinboards[0].sharing)
    }

    func testDisablingSharedPinboardsStopsSharingAllBoardsAndPersists() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let favoritesID = store.snapshot.pinboards[0].id
        store.createPinboard(named: "Launch")
        let launchID = store.snapshot.pinboards.last!.id
        store.configureCloudKitSync(
            containerIdentifier: "iCloud.com.example.PasteBuddy",
            keyHierarchyVersion: 1,
            capabilityConfigured: true
        )
        store.setSharedPinboardsEnabled(true)

        XCTAssertNotNil(store.sharePinboard(favoritesID, accessMode: .linkAccess, linkToken: "favorites-token"))
        _ = store.sharePinboard(launchID, defaultPermission: .canEdit)
        XCTAssertNotNil(store.snapshot.pinboards.first(where: { $0.id == launchID })?.sharing)

        store.setSharedPinboardsEnabled(false)

        XCTAssertFalse(store.snapshot.sync.isSharedPinboardsEnabled)
        XCTAssertTrue(store.snapshot.pinboards.allSatisfy { $0.sharing == nil })

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertFalse(reloaded.snapshot.sync.isSharedPinboardsEnabled)
        XCTAssertTrue(reloaded.snapshot.pinboards.allSatisfy { $0.sharing == nil })
    }

    func testSharedPinboardKeyExchangeWrapsBoardKeyForParticipant() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let pinboardID = store.snapshot.pinboards[0].id
        let keyExchangeService = PinboardShareKeyExchangeService()
        let ownerIdentity = keyExchangeService.makeIdentity()
        let participantIdentity = keyExchangeService.makeIdentity()
        let acceptedAt = Date(timeIntervalSince1970: 10_000)

        store.configureCloudKitSync(
            containerIdentifier: "iCloud.com.example.PasteBuddy",
            keyHierarchyVersion: 1,
            capabilityConfigured: true
        )
        store.setSharedPinboardsEnabled(true)

        let keyExchange = try XCTUnwrap(store.sharePinboardWithKeyExchange(
            pinboardID,
            ownerIdentity: ownerIdentity,
            ownerDisplayName: "Owner Mac",
            keyExchangeService: keyExchangeService
        ))
        let ownerBoardKey = try keyExchangeService.unwrapOwnerBoardKey(
            from: keyExchange,
            ownerIdentity: ownerIdentity
        )
        let participant = try XCTUnwrap(store.inviteParticipantWithKeyExchange(
            to: pinboardID,
            displayName: "Collaborator",
            participantPublicKeyData: participantIdentity.publicKeyData,
            ownerIdentity: ownerIdentity,
            emailAddress: "collaborator@example.com",
            permission: .canEdit,
            keyExchangeService: keyExchangeService
        ))

        XCTAssertEqual(ownerBoardKey.count, PinboardShareKeyExchangeService.boardKeyByteCount)
        XCTAssertEqual(participant.keyAgreementPublicKeyData, participantIdentity.publicKeyData)
        XCTAssertEqual(participant.boardKeyFingerprint, keyExchange.boardKeyFingerprint)
        XCTAssertNotNil(participant.wrappedBoardKey)
        XCTAssertNil(participant.acceptedAt)
        XCTAssertNotEqual(participant.wrappedBoardKey?.sealedBoardKeyData, ownerBoardKey)

        let participantBoardKey = try XCTUnwrap(store.acceptParticipantKeyExchange(
            pinboardID: pinboardID,
            participantID: participant.id,
            participantIdentity: participantIdentity,
            acceptedAt: acceptedAt,
            keyExchangeService: keyExchangeService
        ))

        XCTAssertEqual(participantBoardKey, ownerBoardKey)
        XCTAssertEqual(store.snapshot.pinboards[0].sharing?.participants.first?.acceptedAt, acceptedAt)
        XCTAssertNil(store.lastErrorMessage)

        let raw = try Data(contentsOf: harness.snapshotStore.fileURL)
        let rawString = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(rawString.contains(ownerBoardKey.base64EncodedString()))
        XCTAssertFalse(rawString.contains(participantIdentity.privateKeyData.base64EncodedString()))

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()
        let reloadedParticipant = try XCTUnwrap(reloaded.snapshot.pinboards[0].sharing?.participants.first)
        XCTAssertNotNil(reloaded.snapshot.pinboards[0].sharing?.keyExchange)
        XCTAssertNotNil(reloadedParticipant.wrappedBoardKey)
        XCTAssertEqual(reloadedParticipant.acceptedAt, acceptedAt)
    }

    func testSharedPinboardKeyExchangeRejectsWrongParticipantIdentity() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let pinboardID = store.snapshot.pinboards[0].id
        let keyExchangeService = PinboardShareKeyExchangeService()
        let ownerIdentity = keyExchangeService.makeIdentity()
        let participantIdentity = keyExchangeService.makeIdentity()
        let wrongIdentity = keyExchangeService.makeIdentity()

        store.configureCloudKitSync(
            containerIdentifier: "iCloud.com.example.PasteBuddy",
            keyHierarchyVersion: 1,
            capabilityConfigured: true
        )
        store.setSharedPinboardsEnabled(true)
        _ = try XCTUnwrap(store.sharePinboardWithKeyExchange(
            pinboardID,
            ownerIdentity: ownerIdentity,
            keyExchangeService: keyExchangeService
        ))
        let participant = try XCTUnwrap(store.inviteParticipantWithKeyExchange(
            to: pinboardID,
            displayName: "Collaborator",
            participantPublicKeyData: participantIdentity.publicKeyData,
            ownerIdentity: ownerIdentity,
            keyExchangeService: keyExchangeService
        ))

        let boardKey = store.acceptParticipantKeyExchange(
            pinboardID: pinboardID,
            participantID: participant.id,
            participantIdentity: wrongIdentity,
            keyExchangeService: keyExchangeService
        )

        XCTAssertNil(boardKey)
        XCTAssertEqual(store.lastErrorMessage, PinboardShareKeyExchangeError.recipientMismatch.localizedDescription)
        XCTAssertNil(store.snapshot.pinboards[0].sharing?.participants.first?.acceptedAt)
    }

    func testSharedPinboardInvitationPackageWrapsBoardKeyForRecipientOnly() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let pinboardID = store.snapshot.pinboards[0].id
        let secretPinboardName = "Confidential launch board \(UUID().uuidString)"
        let keyExchangeService = PinboardShareKeyExchangeService()
        let invitationService = PinboardShareInvitationService(keyExchangeService: keyExchangeService)
        let ownerIdentity = keyExchangeService.makeIdentity()
        let participantIdentity = keyExchangeService.makeIdentity()
        let createdAt = Date(timeIntervalSince1970: 20_000)
        let acceptedAt = Date(timeIntervalSince1970: 20_100)

        store.renamePinboard(pinboardID, to: secretPinboardName)
        store.configureCloudKitSync(
            containerIdentifier: "iCloud.com.example.PasteBuddy",
            keyHierarchyVersion: 1,
            capabilityConfigured: true
        )
        store.setSharedPinboardsEnabled(true)

        let keyExchange = try XCTUnwrap(store.sharePinboardWithKeyExchange(
            pinboardID,
            ownerIdentity: ownerIdentity,
            ownerDisplayName: "Owner Mac",
            keyExchangeService: keyExchangeService
        ))
        let ownerBoardKey = try keyExchangeService.unwrapOwnerBoardKey(
            from: keyExchange,
            ownerIdentity: ownerIdentity
        )
        let participant = try XCTUnwrap(store.inviteParticipantWithKeyExchange(
            to: pinboardID,
            displayName: "Collaborator",
            participantPublicKeyData: participantIdentity.publicKeyData,
            ownerIdentity: ownerIdentity,
            permission: .canEdit,
            keyExchangeService: keyExchangeService
        ))

        let package = try XCTUnwrap(store.makePinboardInvitationPackage(
            pinboardID: pinboardID,
            participantID: participant.id,
            ownerIdentity: ownerIdentity,
            ownerDisplayName: "Owner Mac",
            createdAt: createdAt,
            expiresAt: Date(timeIntervalSince1970: 30_000),
            invitationService: invitationService
        ))

        XCTAssertEqual(package.pinboardID, pinboardID)
        XCTAssertEqual(package.participantID, participant.id)
        XCTAssertEqual(package.permission, .canEdit)
        XCTAssertEqual(package.ownerIdentity.displayName, "Owner Mac")
        XCTAssertEqual(package.recipientIdentity.publicKeyData, participantIdentity.publicKeyData)
        XCTAssertEqual(package.boardKeyFingerprint, keyExchange.boardKeyFingerprint)
        XCTAssertNotEqual(package.wrappedBoardKey.sealedBoardKeyData, ownerBoardKey)

        let packageBoardKey = try invitationService.acceptInvitation(
            package,
            recipientIdentity: participantIdentity,
            now: acceptedAt
        )
        XCTAssertEqual(packageBoardKey, ownerBoardKey)

        let acceptedBoardKey = try XCTUnwrap(store.acceptPinboardInvitationPackage(
            package,
            recipientIdentity: participantIdentity,
            acceptedAt: acceptedAt,
            invitationService: invitationService
        ))
        XCTAssertEqual(acceptedBoardKey, ownerBoardKey)
        XCTAssertEqual(store.snapshot.pinboards[0].sharing?.participants.first?.acceptedAt, acceptedAt)
        XCTAssertNil(store.lastErrorMessage)

        let encodedPackage = try JSONEncoder.pasteBuddy.encode(package)
        let encodedPackageString = String(decoding: encodedPackage, as: UTF8.self)
        XCTAssertFalse(encodedPackageString.contains(ownerBoardKey.base64EncodedString()))
        XCTAssertFalse(encodedPackageString.contains(ownerIdentity.privateKeyData.base64EncodedString()))
        XCTAssertFalse(encodedPackageString.contains(participantIdentity.privateKeyData.base64EncodedString()))
        XCTAssertFalse(encodedPackageString.contains(secretPinboardName))
    }

    func testSharedPinboardInvitationPackageRejectsExpiredOrWrongRecipient() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let pinboardID = store.snapshot.pinboards[0].id
        let keyExchangeService = PinboardShareKeyExchangeService()
        let invitationService = PinboardShareInvitationService(keyExchangeService: keyExchangeService)
        let ownerIdentity = keyExchangeService.makeIdentity()
        let participantIdentity = keyExchangeService.makeIdentity()
        let wrongIdentity = keyExchangeService.makeIdentity()

        store.configureCloudKitSync(
            containerIdentifier: "iCloud.com.example.PasteBuddy",
            keyHierarchyVersion: 1,
            capabilityConfigured: true
        )
        store.setSharedPinboardsEnabled(true)
        _ = try XCTUnwrap(store.sharePinboardWithKeyExchange(
            pinboardID,
            ownerIdentity: ownerIdentity,
            keyExchangeService: keyExchangeService
        ))
        let participant = try XCTUnwrap(store.inviteParticipantWithKeyExchange(
            to: pinboardID,
            displayName: "Collaborator",
            participantPublicKeyData: participantIdentity.publicKeyData,
            ownerIdentity: ownerIdentity,
            keyExchangeService: keyExchangeService
        ))
        let package = try XCTUnwrap(store.makePinboardInvitationPackage(
            pinboardID: pinboardID,
            participantID: participant.id,
            ownerIdentity: ownerIdentity,
            createdAt: Date(timeIntervalSince1970: 10),
            expiresAt: Date(timeIntervalSince1970: 100),
            invitationService: invitationService
        ))

        let expiredBoardKey = store.acceptPinboardInvitationPackage(
            package,
            recipientIdentity: participantIdentity,
            acceptedAt: Date(timeIntervalSince1970: 101),
            invitationService: invitationService
        )
        XCTAssertNil(expiredBoardKey)
        XCTAssertEqual(store.lastErrorMessage, PinboardShareInvitationError.expiredInvitation.localizedDescription)
        XCTAssertNil(store.snapshot.pinboards[0].sharing?.participants.first?.acceptedAt)

        let wrongRecipientBoardKey = store.acceptPinboardInvitationPackage(
            package,
            recipientIdentity: wrongIdentity,
            acceptedAt: Date(timeIntervalSince1970: 50),
            invitationService: invitationService
        )
        XCTAssertNil(wrongRecipientBoardKey)
        XCTAssertEqual(store.lastErrorMessage, PinboardShareInvitationError.recipientMismatch.localizedDescription)
        XCTAssertNil(store.snapshot.pinboards[0].sharing?.participants.first?.acceptedAt)
    }

    func testSharedPinboardInvitationDeliveryFetchesOnlyRecipientPackages() async throws {
        let keyExchangeService = PinboardShareKeyExchangeService()
        let invitationService = PinboardShareInvitationService(keyExchangeService: keyExchangeService)
        let deliveryService = PinboardShareInvitationDeliveryService(
            transport: InMemoryPinboardShareInvitationTransport()
        )
        let ownerIdentity = keyExchangeService.makeIdentity()
        let participantIdentity = keyExchangeService.makeIdentity()
        let otherIdentity = keyExchangeService.makeIdentity()
        let recipientIdentity = try invitationService.publicIdentity(
            displayName: "Collaborator",
            identity: participantIdentity,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let otherRecipientIdentity = try invitationService.publicIdentity(
            displayName: "Other Mac",
            identity: otherIdentity,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let keyExchange = try keyExchangeService.setupOwnerKeyExchange(
            ownerIdentity: ownerIdentity
        ).state
        let package = try invitationService.makeInvitationPackage(
            pinboardID: UUID(),
            participantID: UUID(),
            permission: .canEdit,
            ownerIdentity: ownerIdentity,
            ownerDisplayName: "Owner Mac",
            recipientIdentity: recipientIdentity,
            keyExchange: keyExchange,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let otherPackage = try invitationService.makeInvitationPackage(
            pinboardID: UUID(),
            participantID: UUID(),
            permission: .readOnly,
            ownerIdentity: ownerIdentity,
            ownerDisplayName: "Owner Mac",
            recipientIdentity: otherRecipientIdentity,
            keyExchange: keyExchange,
            createdAt: Date(timeIntervalSince1970: 3)
        )

        let publishedIdentity = try await deliveryService.publishIdentity(recipientIdentity)
        _ = try await deliveryService.sendInvitation(package)
        _ = try await deliveryService.sendInvitation(otherPackage)

        let fetchedPackages = try await deliveryService.fetchInvitations(for: publishedIdentity)
        let otherFetchedPackages = try await deliveryService.fetchInvitations(for: otherRecipientIdentity)

        XCTAssertEqual(fetchedPackages.map(\.id), [package.id])
        XCTAssertEqual(otherFetchedPackages.map(\.id), [otherPackage.id])
    }

    func testSharedPinboardInvitationInboxRefreshStoresRecipientPackagesEncrypted() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let keyExchangeService = PinboardShareKeyExchangeService()
        let invitationService = PinboardShareInvitationService(keyExchangeService: keyExchangeService)
        let transport = InMemoryPinboardShareInvitationTransport()
        let deliveryService = PinboardShareInvitationDeliveryService(transport: transport)
        let inboxRefreshService = PinboardShareInvitationInboxRefreshService(
            deliveryService: deliveryService,
            invitationService: invitationService
        )
        let ownerIdentity = keyExchangeService.makeIdentity()
        let participantIdentity = keyExchangeService.makeIdentity()
        let otherIdentity = keyExchangeService.makeIdentity()
        let secretPinboardName = "Remote confidential board \(UUID().uuidString)"
        let keyExchangeSetup = try keyExchangeService.setupOwnerKeyExchange(
            ownerIdentity: ownerIdentity
        )
        let recipientIdentity = try invitationService.publicIdentity(
            displayName: "Collaborator",
            identity: participantIdentity,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let otherRecipientIdentity = try invitationService.publicIdentity(
            displayName: "Other",
            identity: otherIdentity,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let package = try invitationService.makeInvitationPackage(
            pinboardID: UUID(),
            participantID: UUID(),
            permission: .canEdit,
            ownerIdentity: ownerIdentity,
            ownerDisplayName: "Owner Mac",
            recipientIdentity: recipientIdentity,
            keyExchange: keyExchangeSetup.state,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let otherPackage = try invitationService.makeInvitationPackage(
            pinboardID: UUID(),
            participantID: UUID(),
            permission: .readOnly,
            ownerIdentity: ownerIdentity,
            ownerDisplayName: "Owner Mac",
            recipientIdentity: otherRecipientIdentity,
            keyExchange: keyExchangeSetup.state,
            createdAt: Date(timeIntervalSince1970: 3)
        )

        store.configureCloudKitSync(
            containerIdentifier: "iCloud.com.example.PasteBuddy",
            keyHierarchyVersion: 1,
            capabilityConfigured: true
        )
        store.setSharedPinboardsEnabled(true)
        _ = try await deliveryService.sendInvitation(package)
        _ = try await deliveryService.sendInvitation(otherPackage)

        let result = try await inboxRefreshService.refreshPendingInvitations(
            for: participantIdentity,
            displayName: "Collaborator",
            into: store,
            receivedAt: Date(timeIntervalSince1970: 4)
        )

        XCTAssertEqual(result.fetchedPackageCount, 1)
        XCTAssertEqual(result.savedEntries.map(\.id), [package.id])
        XCTAssertEqual(store.snapshot.pinboardInvitationInbox.pendingEntries.map(\.id), [package.id])
        XCTAssertEqual(store.snapshot.pinboardInvitationInbox.entries.first?.status, .pending)
        XCTAssertNil(store.lastErrorMessage)

        let raw = try Data(contentsOf: harness.snapshotStore.fileURL)
        let rawString = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(rawString.contains(keyExchangeSetup.boardKey.base64EncodedString()))
        XCTAssertFalse(rawString.contains(ownerIdentity.privateKeyData.base64EncodedString()))
        XCTAssertFalse(rawString.contains(participantIdentity.privateKeyData.base64EncodedString()))
        XCTAssertFalse(rawString.contains(secretPinboardName))

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()
        XCTAssertEqual(reloaded.snapshot.pinboardInvitationInbox.entries.map(\.id), [package.id])
        XCTAssertEqual(reloaded.snapshot.pinboardInvitationInbox.entries.first?.status, .pending)
    }

    func testAcceptPendingPinboardInvitationUpdatesInboxStatus() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let keyExchangeService = PinboardShareKeyExchangeService()
        let invitationService = PinboardShareInvitationService(keyExchangeService: keyExchangeService)
        let ownerIdentity = keyExchangeService.makeIdentity()
        let participantIdentity = keyExchangeService.makeIdentity()
        let keyExchangeSetup = try keyExchangeService.setupOwnerKeyExchange(
            ownerIdentity: ownerIdentity
        )
        let recipientIdentity = try invitationService.publicIdentity(
            displayName: "Collaborator",
            identity: participantIdentity,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let acceptedPackage = try invitationService.makeInvitationPackage(
            pinboardID: UUID(),
            participantID: UUID(),
            permission: .canEdit,
            ownerIdentity: ownerIdentity,
            ownerDisplayName: "Owner Mac",
            recipientIdentity: recipientIdentity,
            keyExchange: keyExchangeSetup.state,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let expiredPackage = try invitationService.makeInvitationPackage(
            pinboardID: UUID(),
            participantID: UUID(),
            permission: .readOnly,
            ownerIdentity: ownerIdentity,
            ownerDisplayName: "Owner Mac",
            recipientIdentity: recipientIdentity,
            keyExchange: keyExchangeSetup.state,
            createdAt: Date(timeIntervalSince1970: 3),
            expiresAt: Date(timeIntervalSince1970: 5)
        )

        store.configureCloudKitSync(
            containerIdentifier: "iCloud.com.example.PasteBuddy",
            keyHierarchyVersion: 1,
            capabilityConfigured: true
        )
        store.setSharedPinboardsEnabled(true)
        store.savePendingPinboardInvitationPackages(
            [acceptedPackage, expiredPackage],
            receivedAt: Date(timeIntervalSince1970: 4)
        )

        let acceptedBoardKey = try XCTUnwrap(store.acceptPendingPinboardInvitation(
            invitationID: acceptedPackage.id,
            recipientIdentity: participantIdentity,
            acceptedAt: Date(timeIntervalSince1970: 6),
            invitationService: invitationService
        ))
        XCTAssertEqual(acceptedBoardKey, keyExchangeSetup.boardKey)
        XCTAssertEqual(
            store.snapshot.pinboardInvitationInbox.entries.first(where: { $0.id == acceptedPackage.id })?.status,
            .accepted
        )

        let expiredBoardKey = store.acceptPendingPinboardInvitation(
            invitationID: expiredPackage.id,
            recipientIdentity: participantIdentity,
            acceptedAt: Date(timeIntervalSince1970: 6),
            invitationService: invitationService
        )
        let expiredEntry = try XCTUnwrap(
            store.snapshot.pinboardInvitationInbox.entries.first(where: { $0.id == expiredPackage.id })
        )

        XCTAssertNil(expiredBoardKey)
        XCTAssertEqual(expiredEntry.status, .expired)
        XCTAssertEqual(expiredEntry.lastErrorMessage, PinboardShareInvitationError.expiredInvitation.localizedDescription)
    }

    #if canImport(CloudKit)

    func testCloudKitPinboardShareInvitationRecordsExposeOnlyRoutingMetadataAndWrappedPackage() throws {
        let keyExchangeService = PinboardShareKeyExchangeService()
        let invitationService = PinboardShareInvitationService(keyExchangeService: keyExchangeService)
        let factory = CloudKitPinboardShareRecordFactory()
        let ownerIdentity = keyExchangeService.makeIdentity()
        let participantIdentity = keyExchangeService.makeIdentity()
        let secretPinboardName = "Board name must not be in invitation record"
        let keyExchangeSetup = try keyExchangeService.setupOwnerKeyExchange(
            ownerIdentity: ownerIdentity
        )
        let recipientIdentity = try invitationService.publicIdentity(
            displayName: "Collaborator",
            identity: participantIdentity,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let package = try invitationService.makeInvitationPackage(
            pinboardID: UUID(),
            participantID: UUID(),
            permission: .canEdit,
            ownerIdentity: ownerIdentity,
            ownerDisplayName: "Owner Mac",
            recipientIdentity: recipientIdentity,
            keyExchange: keyExchangeSetup.state,
            createdAt: Date(timeIntervalSince1970: 200),
            expiresAt: Date(timeIntervalSince1970: 300)
        )

        let identityRecord = try factory.makeIdentityRecord(from: recipientIdentity)
        XCTAssertEqual(identityRecord.recordType, CloudKitPinboardShareRecordFactory.publicIdentityRecordType)
        XCTAssertEqual(identityRecord.recordID.recordName, recipientIdentity.publicKeyFingerprint)
        XCTAssertEqual(
            identityRecord[CloudKitPinboardShareRecordFactory.publicKeyFingerprintField] as? String,
            recipientIdentity.publicKeyFingerprint
        )
        XCTAssertEqual(try factory.makePublicIdentity(from: identityRecord), recipientIdentity)

        let invitationRecord = try factory.makeInvitationRecord(from: package)
        XCTAssertEqual(invitationRecord.recordType, CloudKitPinboardShareRecordFactory.invitationRecordType)
        XCTAssertEqual(invitationRecord.recordID.recordName, package.id.uuidString)
        XCTAssertEqual(
            invitationRecord[CloudKitPinboardShareRecordFactory.recipientPublicKeyFingerprintField] as? String,
            recipientIdentity.publicKeyFingerprint
        )
        XCTAssertEqual(
            invitationRecord[CloudKitPinboardShareRecordFactory.permissionField] as? String,
            PinboardSharePermission.canEdit.rawValue
        )

        let packageData = try XCTUnwrap(
            invitationRecord[CloudKitPinboardShareRecordFactory.invitationPackageDataField] as? Data
        )
        let packageString = String(decoding: packageData, as: UTF8.self)
        XCTAssertFalse(packageString.contains(keyExchangeSetup.boardKey.base64EncodedString()))
        XCTAssertFalse(packageString.contains(ownerIdentity.privateKeyData.base64EncodedString()))
        XCTAssertFalse(packageString.contains(participantIdentity.privateKeyData.base64EncodedString()))
        XCTAssertFalse(packageString.contains(secretPinboardName))
        XCTAssertEqual(try factory.makeInvitationPackage(from: invitationRecord), package)
    }

    func testCloudKitPinboardShareInvitationNotificationHandlerRefreshesMatchingSubscriptionOnly() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let keyExchangeService = PinboardShareKeyExchangeService()
        let invitationService = PinboardShareInvitationService(keyExchangeService: keyExchangeService)
        let transport = InMemoryPinboardShareInvitationTransport()
        let deliveryService = PinboardShareInvitationDeliveryService(transport: transport)
        let handler = CloudKitPinboardShareInvitationNotificationHandler(
            deliveryService: deliveryService,
            invitationService: invitationService
        )
        let factory = CloudKitPinboardShareRecordFactory()
        let ownerIdentity = keyExchangeService.makeIdentity()
        let participantIdentity = keyExchangeService.makeIdentity()
        let otherIdentity = keyExchangeService.makeIdentity()
        let keyExchange = try keyExchangeService.setupOwnerKeyExchange(
            ownerIdentity: ownerIdentity
        ).state
        let recipientIdentity = try invitationService.publicIdentity(
            displayName: "Collaborator",
            identity: participantIdentity,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let otherRecipientIdentity = try invitationService.publicIdentity(
            displayName: "Other",
            identity: otherIdentity,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let package = try invitationService.makeInvitationPackage(
            pinboardID: UUID(),
            participantID: UUID(),
            permission: .canEdit,
            ownerIdentity: ownerIdentity,
            ownerDisplayName: "Owner Mac",
            recipientIdentity: recipientIdentity,
            keyExchange: keyExchange,
            createdAt: Date(timeIntervalSince1970: 2)
        )

        store.configureCloudKitSync(
            containerIdentifier: "iCloud.com.example.PasteBuddy",
            keyHierarchyVersion: 1,
            capabilityConfigured: true
        )
        store.setSharedPinboardsEnabled(true)
        _ = try await deliveryService.sendInvitation(package)

        let ignoredResult = try await handler.handleInvitationSubscription(
            subscriptionID: try factory.makeInvitationSubscriptionID(
                recipientPublicKeyFingerprint: otherRecipientIdentity.publicKeyFingerprint
            ),
            recipientIdentity: participantIdentity,
            displayName: "Collaborator",
            store: store,
            receivedAt: Date(timeIntervalSince1970: 3)
        )
        XCTAssertNil(ignoredResult)
        XCTAssertTrue(store.snapshot.pinboardInvitationInbox.entries.isEmpty)

        let result = try await handler.handleInvitationSubscription(
            subscriptionID: try factory.makeInvitationSubscriptionID(
                recipientPublicKeyFingerprint: recipientIdentity.publicKeyFingerprint
            ),
            recipientIdentity: participantIdentity,
            displayName: "Collaborator",
            store: store,
            receivedAt: Date(timeIntervalSince1970: 4)
        )

        XCTAssertEqual(result?.fetchedPackageCount, 1)
        XCTAssertEqual(result?.savedEntries.map(\.id), [package.id])
        XCTAssertEqual(store.snapshot.pinboardInvitationInbox.pendingEntries.map(\.id), [package.id])
    }

    func testCloudKitPinboardShareInvitationNotificationRouteRejectsMalformedSubscriptionID() throws {
        let factory = CloudKitPinboardShareRecordFactory()

        XCTAssertThrowsError(
            try factory.makeInvitationNotificationRoute(subscriptionID: "OtherSubscription.abc")
        )
        XCTAssertThrowsError(
            try factory.makeInvitationNotificationRoute(
                subscriptionID: CloudKitPinboardShareRecordFactory.invitationSubscriptionIDPrefix
            )
        )
    }
    #endif

    func testSyncedItemRespectsLocalPrivacyPreferences() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.snapshot.privacy.captureText = false

        let stored = store.addSyncedItem(ClipboardItem(
            sourceAppName: "Peer iPhone",
            deviceName: "Peer iPhone",
            contentType: .text,
            title: "Password from phone",
            payload: ClipboardPayload(text: "hunter2-super-secret")
        ))

        XCTAssertNil(stored)
        XCTAssertTrue(
            store.snapshot.items.isEmpty,
            "A text item must not enter history while text capture is disabled"
        )
    }

    #if os(macOS)

    func testEnrichLinkPreviewMetadataNotifiesForwarderWithUpgradedItem() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let thumbnail = Data([0xAA, 0xBB, 0xCC, 0xDD])
        ClipboardLinkMetadataFetcher.fetchOverrideForTesting = { _ in
            ClipboardLinkPreviewMetadata(title: "Example Domain", imageData: thumbnail)
        }
        defer { ClipboardLinkMetadataFetcher.fetchOverrideForTesting = nil }

        var forwarded: [ClipboardItem] = []
        store.onLinkPreviewMetadataEnriched = { item in
            forwarded.append(item)
        }

        let bare = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Terminal",
            deviceName: "Test Mac",
            contentType: .url,
            title: "example.com",
            payload: ClipboardPayload(urlString: "https://example.com/launch")
        ))
        XCTAssertFalse(bare.payload.hasImageAsset)

        await store.enrichLinkPreviewMetadataIfNeeded(for: bare)

        let enriched = try XCTUnwrap(store.snapshot.items.first { $0.id == bare.id })
        XCTAssertEqual(enriched.title, "Example Domain")
        XCTAssertEqual(enriched.payload.imageData, thumbnail)
        XCTAssertEqual(forwarded.map(\.id), [bare.id])
        XCTAssertEqual(forwarded.first?.payload.imageData, thumbnail,
                       "Forwarded item must carry the thumbnail so peers can merge it")
    }

    func testEnrichLinkPreviewMetadataDoesNotForwardTitleOnlyUpgrade() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        ClipboardLinkMetadataFetcher.fetchOverrideForTesting = { _ in
            ClipboardLinkPreviewMetadata(title: "Only Title", imageData: nil)
        }
        defer { ClipboardLinkMetadataFetcher.fetchOverrideForTesting = nil }

        var forwardedCount = 0
        store.onLinkPreviewMetadataEnriched = { _ in
            forwardedCount += 1
        }

        let bare = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Terminal",
            deviceName: "Test Mac",
            contentType: .url,
            title: "example.com",
            payload: ClipboardPayload(urlString: "https://example.com/title-only")
        ))

        await store.enrichLinkPreviewMetadataIfNeeded(for: bare)

        let enriched = try XCTUnwrap(store.snapshot.items.first { $0.id == bare.id })
        XCTAssertEqual(enriched.title, "Only Title")
        XCTAssertEqual(forwardedCount, 0, "Title-only enrichment should stay local until peers can merge it safely")
    }
    #endif

    func testDedupeMergesRicherLinkPreviewFromPeerResend() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let bare = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Terminal",
            deviceName: "Test Mac",
            contentType: .url,
            title: "example.com",
            payload: ClipboardPayload(urlString: "https://example.com/launch")
        ))

        // A sync peer re-sends the same link once it fetched preview metadata;
        // the item arrives with its own UUID, so only dedupe can reconcile it.
        let thumbnail = Data([0x01, 0x02, 0x03])
        var enrichedPayload = ClipboardPayload(urlString: "https://example.com/launch")
        enrichedPayload.imageData = thumbnail
        enrichedPayload.imageByteCount = thumbnail.count
        let merged = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Terminal",
            deviceName: "Peer iPhone",
            contentType: .url,
            title: "Example Domain",
            payload: enrichedPayload
        ))

        XCTAssertEqual(store.snapshot.items.count, 1)
        XCTAssertEqual(merged.id, bare.id, "Richer duplicate must merge into the existing item")
        XCTAssertEqual(merged.title, "Example Domain")
        XCTAssertEqual(merged.payload.imageData, thumbnail)
    }

    func testSyncedMetadataReplayMergesWithoutBubblingItemToTop() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let now = Date()
        let older = store.addCapturedItem(ClipboardItem(
            createdAt: now.addingTimeInterval(-120),
            updatedAt: now.addingTimeInterval(-120),
            sourceAppName: "Safari",
            deviceName: "Test Mac",
            contentType: .url,
            title: "example.com",
            payload: ClipboardPayload(urlString: "https://example.com/launch")
        ))
        let newer = store.addCapturedItem(ClipboardItem(
            createdAt: now.addingTimeInterval(-60),
            updatedAt: now.addingTimeInterval(-60),
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Fresh note",
            payload: ClipboardPayload(text: "fresh note")
        ))

        var replayPayload = ClipboardPayload(urlString: "https://example.com/launch")
        replayPayload.imageData = Data([0x0F, 0x0E])
        replayPayload.imageByteCount = 2
        let merged = store.addSyncedItem(ClipboardItem(
            id: UUID(),
            createdAt: older.createdAt,
            updatedAt: older.updatedAt,
            sourceAppName: "Peer iPhone",
            deviceName: "Peer iPhone",
            contentType: .url,
            title: "Example Domain",
            payload: replayPayload
        ))

        XCTAssertEqual(merged?.id, older.id)
        XCTAssertEqual(store.snapshot.items.map(\.id), [newer.id, older.id])
        XCTAssertEqual(store.snapshot.items.last?.payload.imageData, replayPayload.imageData)
    }

    func testSyncedRepositoryCaptureBurstAvoidsFullSynchronizeAndPreservesCaptureSemantics() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        harness.snapshotStore.storageMode = .standard

        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let repository = ClipboardItemRepository(database: database)
        let now = Date(timeIntervalSince1970: 4_000_000)
        let recurring = ClipboardItem(
            createdAt: now,
            updatedAt: now,
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Recurring",
            payload: ClipboardPayload(text: "recurring clipboard value")
        )
        let stale = ClipboardItem(
            createdAt: now.addingTimeInterval(-10),
            updatedAt: now.addingTimeInterval(-10),
            sourceAppName: "TextEdit",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Stale",
            payload: ClipboardPayload(text: "stale clipboard value")
        )
        let pinned = ClipboardItem(
            createdAt: now.addingTimeInterval(-20),
            updatedAt: now.addingTimeInterval(-20),
            sourceAppName: "Safari",
            deviceName: "Test Mac",
            contentType: .url,
            title: "Pinned",
            payload: ClipboardPayload(urlString: "https://example.com/pinned")
        )
        let smartText = Pinboard(
            name: SmartPinboardCategory.text.pinboardName,
            colorHex: SmartPinboardCategory.text.colorHex,
            itemIDs: [recurring.id, stale.id],
            createdAt: now,
            updatedAt: now
        )
        let userPinboard = Pinboard(
            name: "Keep",
            colorHex: "#4EA7FC",
            itemIDs: [pinned.id],
            createdAt: now,
            updatedAt: now
        )
        var seedSnapshot = PasteBuddySnapshot(
            items: [recurring, stale, pinned],
            pinboards: [smartText, userPinboard]
        )
        seedSnapshot.storage.maxHistoryItems = 2
        seedSnapshot.storage.retentionDays = 0
        try repository.replaceAll(with: seedSnapshot)

        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository,
            saveDebounceNanoseconds: 60_000_000_000
        )
        store.load()
        let baselineSynchronizeCount = repository.incrementalSyncInvocationCount

        let firstNew = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Terminal",
            deviceName: "Test Mac",
            contentType: .text,
            title: "First New",
            payload: ClipboardPayload(text: "first new clipboard value")
        ), maxItems: 2)
        _ = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Recurring Again",
            payload: ClipboardPayload(text: "recurring clipboard value")
        ), maxItems: 2)
        let finalNew = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Terminal",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Final New",
            payload: ClipboardPayload(text: "final new clipboard value")
        ), maxItems: 2)
        let retouched = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Recurring Last",
            payload: ClipboardPayload(text: "recurring clipboard value")
        ), maxItems: 2)

        XCTAssertEqual(retouched.id, recurring.id)
        XCTAssertGreaterThan(retouched.updatedAt, recurring.updatedAt)
        XCTAssertEqual(store.snapshot.items.map(\.id), [recurring.id, finalNew.id, pinned.id])
        XCTAssertFalse(store.snapshot.items.contains(where: { $0.id == stale.id || $0.id == firstNew.id }))

        await store.flushPendingSave()

        XCTAssertEqual(
            repository.incrementalSyncInvocationCount,
            baselineSynchronizeCount,
            "A repository-synced capture burst must use the incremental journal instead of synchronize(with:)"
        )
        let exported = try repository.exportSnapshot()
        XCTAssertEqual(exported.items.map(\.id), [recurring.id, finalNew.id, pinned.id])
        XCTAssertEqual(exported.pinboards.first(where: { $0.id == smartText.id })?.itemIDs, [recurring.id, finalNew.id])
        XCTAssertEqual(exported.pinboards.first(where: { $0.id == userPinboard.id })?.itemIDs, [pinned.id])

        let persisted = try harness.snapshotStore.load()
        XCTAssertEqual(persisted.items.map(\.id), exported.items.map(\.id))
        XCTAssertEqual(persisted.pinboards, exported.pinboards)
    }

    func testCloudImportMergesCaptureCreatedWhileRemoteFetchIsSuspended() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        let encryptionService = EncryptionService(
            service: "com.pastebuddy.cloud-import-race-tests",
            account: UUID().uuidString,
            keyID: "test-key",
            keyMaterialStore: FixedEncryptionKeyMaterialStore()
        )
        let transport = SuspendedCloudSyncRemoteTransport()
        let cloudService = CloudKitSyncService(
            transport: transport,
            builder: CloudSyncPackageBuilder(encryptor: encryptionService),
            importer: CloudSyncPackageImporter(decryptor: encryptionService)
        )
        let sync = SyncConfiguration(
            provider: .cloudKit,
            isCloudSyncEnabled: true,
            isSharedPinboardsEnabled: true,
            cloudKitContainerIdentifier: "iCloud.com.example.PasteBuddy",
            keyHierarchyVersion: 1,
            isCloudKitCapabilityConfigured: true
        )
        let initialLocal = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Local Mac",
            contentType: .text,
            title: "Initial Local",
            payload: ClipboardPayload(text: "initial local item")
        )
        let remote = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Remote Mac",
            contentType: .text,
            title: "Remote",
            payload: ClipboardPayload(text: "remote item")
        )
        _ = try await cloudService.upload(PasteBuddySnapshot(items: [remote], sync: sync))
        await transport.suspendNextFetch()

        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            saveDebounceNanoseconds: 60_000_000_000
        )
        store.snapshot = PasteBuddySnapshot(items: [initialLocal], sync: sync)
        let importTask = Task { @MainActor in
            await store.importLatestCloudSyncSnapshot(using: cloudService)
        }

        let fetchDeadline = Date().addingTimeInterval(1)
        while await !transport.fetchHasStarted(), Date() < fetchDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let didStartFetch = await transport.fetchHasStarted()
        XCTAssertTrue(didStartFetch)
        let concurrentCapture = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Terminal",
            deviceName: "Local Mac",
            contentType: .text,
            title: "Captured During Fetch",
            payload: ClipboardPayload(text: "must survive cloud import")
        ))

        await transport.resumeFetch()
        let result = await importTask.value

        XCTAssertNotNil(result)
        XCTAssertEqual(
            Set(store.snapshot.items.map(\.id)),
            Set([initialLocal.id, concurrentCapture.id, remote.id])
        )
        await store.flushPendingSave()
    }

}
