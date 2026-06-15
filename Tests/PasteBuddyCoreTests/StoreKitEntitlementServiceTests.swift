import XCTest
@testable import PasteBuddyCore

@MainActor
final class StoreKitEntitlementServiceTests: XCTestCase {
    func testProductConfigurationMapsPersonalPlansToProductIDs() {
        let configuration = StoreProductConfiguration(
            monthlyProductID: "monthly.id",
            annualProductID: "annual.id",
            lifetimeProductID: "lifetime.id",
            familyProductID: "family.id"
        )

        XCTAssertEqual(configuration.productID(for: .monthly), "monthly.id")
        XCTAssertEqual(configuration.productID(for: .annual), "annual.id")
        XCTAssertEqual(configuration.productID(for: .lifetime), "lifetime.id")
        XCTAssertEqual(configuration.productID(for: .family), "family.id")
        XCTAssertNil(configuration.productID(for: .team))
        XCTAssertEqual(configuration.plan(for: "family.id"), .family)
        XCTAssertEqual(configuration.allProductIDs, ["monthly.id", "annual.id", "lifetime.id", "family.id"])
    }

    func testEntitlementMapperSelectsHighestActiveRestoredPlan() {
        let now = Date(timeIntervalSince1970: 1_000)
        let configuration = StoreProductConfiguration(
            monthlyProductID: "monthly.id",
            annualProductID: "annual.id",
            lifetimeProductID: "lifetime.id",
            familyProductID: "family.id"
        )
        let transactions = [
            VerifiedStoreTransaction(
                productID: "monthly.id",
                purchaseDate: now.addingTimeInterval(-200),
                expirationDate: now.addingTimeInterval(100)
            ),
            VerifiedStoreTransaction(
                productID: "lifetime.id",
                purchaseDate: now.addingTimeInterval(-500)
            ),
            VerifiedStoreTransaction(
                productID: "family.id",
                purchaseDate: now.addingTimeInterval(-100),
                expirationDate: now.addingTimeInterval(-10),
                isFamilyShared: true
            )
        ]

        let entitlement = StoreEntitlementMapper.bestActiveEntitlement(
            from: transactions,
            configuration: configuration,
            restoredAt: now,
            now: now
        )

        XCTAssertEqual(entitlement?.plan, .lifetime)
        XCTAssertEqual(entitlement?.status, .active)
        XCTAssertTrue(entitlement?.unlocksAllDevicesForAccount == true)
        XCTAssertEqual(entitlement?.restoreState, .restored(now))
    }

    func testTransactionUpdateMapperRevokesAccessWhenStoreKitRevokesTransaction() {
        let now = Date(timeIntervalSince1970: 1_500)
        let configuration = StoreProductConfiguration(
            monthlyProductID: "monthly.id",
            annualProductID: "annual.id",
            lifetimeProductID: "lifetime.id",
            familyProductID: "family.id"
        )
        let transaction = VerifiedStoreTransaction(
            productID: "annual.id",
            purchaseDate: now.addingTimeInterval(-500),
            expirationDate: now.addingTimeInterval(10_000),
            revocationDate: now
        )

        let update = StoreEntitlementMapper.update(
            from: transaction,
            configuration: configuration,
            receivedAt: now
        )

        XCTAssertEqual(update?.entitlement.plan, .annual)
        XCTAssertEqual(update?.entitlement.status, .revoked)
        XCTAssertFalse(update?.entitlement.unlocksAllDevicesForAccount == true)
        XCTAssertEqual(update?.entitlement.hasFullAccess(now: now.addingTimeInterval(1)), false)
    }

    func testPurchasePersonalPlanAppliesVerifiedEntitlementAndPersistsEncryptedState() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let now = Date(timeIntervalSince1970: 2_000)
        let configuration = StoreProductConfiguration(
            monthlyProductID: "monthly.id",
            annualProductID: "annual.id",
            lifetimeProductID: "lifetime.id",
            familyProductID: "family.id"
        )
        let entitlement = EntitlementConfiguration(
            plan: .annual,
            status: .active,
            purchasedAt: now,
            currentPeriodEndsAt: now.addingTimeInterval(365 * 24 * 60 * 60),
            expiresAt: now.addingTimeInterval(365 * 24 * 60 * 60),
            unlocksAllDevicesForAccount: true
        )
        let provider = FakeStoreEntitlementProvider(purchaseOutcome: .purchased(entitlement))
        let store = PasteBuddyStore(diskStore: harness.snapshotStore)

        let outcome = await store.purchasePersonalPlan(
            .annual,
            using: provider,
            productConfiguration: configuration
        )

        XCTAssertEqual(outcome, .purchased(entitlement))
        XCTAssertEqual(store.snapshot.entitlement.plan, .annual)
        XCTAssertTrue(store.snapshot.entitlement.hasFullAccess(now: now.addingTimeInterval(60)))

        let raw = try Data(contentsOf: harness.snapshotStore.fileURL)
        let rawString = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(rawString.contains("annual.id"))
        XCTAssertFalse(rawString.contains("Annual"))
    }

    func testStoreAppliesTransactionUpdateAndPersistsEncryptedEntitlementState() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let now = Date(timeIntervalSince1970: 2_500)
        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.activatePersonalPlan(
            .annual,
            purchasedAt: now.addingTimeInterval(-100),
            currentPeriodEndsAt: now.addingTimeInterval(100)
        )
        XCTAssertTrue(store.snapshot.entitlement.hasFullAccess(now: now))

        let revokedEntitlement = EntitlementConfiguration(
            plan: .annual,
            status: .revoked,
            purchasedAt: now.addingTimeInterval(-100),
            expiresAt: now,
            unlocksAllDevicesForAccount: false
        )
        let update = StoreEntitlementUpdate(
            transaction: VerifiedStoreTransaction(
                productID: "annual.id",
                purchaseDate: now.addingTimeInterval(-100),
                revocationDate: now
            ),
            entitlement: revokedEntitlement,
            receivedAt: now
        )

        store.applyStoreEntitlementUpdate(update)

        XCTAssertEqual(store.snapshot.entitlement.status, .revoked)
        XCTAssertEqual(store.lastErrorMessage, "App Store entitlement was revoked.")
        XCTAssertFalse(store.snapshot.entitlement.hasFullAccess(now: now.addingTimeInterval(1)))

        let raw = try Data(contentsOf: harness.snapshotStore.fileURL)
        let rawString = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(rawString.contains("annual.id"))
        XCTAssertFalse(rawString.contains("revoked"))
    }

    func testRestorePurchasesActivatesRestoredEntitlementOrFailsClosed() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let restoredAt = Date(timeIntervalSince1970: 3_000)
        let restoredEntitlement = EntitlementConfiguration(
            plan: .family,
            status: .active,
            purchasedAt: restoredAt.addingTimeInterval(-100),
            currentPeriodEndsAt: restoredAt.addingTimeInterval(100),
            expiresAt: restoredAt.addingTimeInterval(100),
            isFamilySharingEnabled: true,
            unlocksAllDevicesForAccount: true,
            restoreState: .restored(restoredAt)
        )
        let restoringProvider = FakeStoreEntitlementProvider(restoreEntitlement: restoredEntitlement)
        let store = PasteBuddyStore(diskStore: harness.snapshotStore)

        let restored = await store.restorePurchases(
            using: restoringProvider,
            at: restoredAt
        )

        XCTAssertEqual(restored, restoredEntitlement)
        XCTAssertEqual(store.snapshot.entitlement.plan, .family)
        XCTAssertEqual(store.snapshot.entitlement.restoreState, .restored(restoredAt))
        let restoredOverview = store.snapshot.entitlement.personalOverview(now: restoredAt.addingTimeInterval(1))
        XCTAssertEqual(restoredOverview.accessState, "Unlocked")
        XCTAssertEqual(restoredOverview.trialState, .converted)
        XCTAssertTrue(restoredOverview.crossDeviceStatement.contains("entitled family account"))
        XCTAssertTrue(restoredOverview.restoreSummary.contains("active entitlement"))

        let failingProvider = FakeStoreEntitlementProvider(restoreEntitlement: nil)
        let failed = await store.restorePurchases(
            using: failingProvider,
            at: restoredAt.addingTimeInterval(10)
        )

        XCTAssertNil(failed)
        XCTAssertFalse(store.snapshot.entitlement.hasFullAccess(now: restoredAt.addingTimeInterval(200)))
        XCTAssertEqual(store.lastErrorMessage, "Restore did not return an active entitlement.")
        let failedOverview = store.snapshot.entitlement.personalOverview(now: restoredAt.addingTimeInterval(200))
        XCTAssertTrue(failedOverview.restoreSummary.contains("Restore failed"))
        XCTAssertTrue(failedOverview.restoreActionStatement.contains("retry with the App Store account"))
    }

    func testTransactionUpdateObserverConsumesFiniteUpdateStream() async {
        let now = Date(timeIntervalSince1970: 4_000)
        let configuration = StoreProductConfiguration(
            monthlyProductID: "monthly.id",
            annualProductID: "annual.id",
            lifetimeProductID: "lifetime.id",
            familyProductID: "family.id"
        )
        let entitlement = EntitlementConfiguration(
            plan: .monthly,
            status: .active,
            purchasedAt: now,
            currentPeriodEndsAt: now.addingTimeInterval(30 * 24 * 60 * 60),
            expiresAt: now.addingTimeInterval(30 * 24 * 60 * 60),
            unlocksAllDevicesForAccount: true
        )
        let update = StoreEntitlementUpdate(
            transaction: VerifiedStoreTransaction(
                productID: "monthly.id",
                purchaseDate: now,
                expirationDate: now.addingTimeInterval(30 * 24 * 60 * 60)
            ),
            entitlement: entitlement,
            receivedAt: now
        )
        let provider = FakeStoreEntitlementProvider(transactionUpdates: [update])
        let observer = StoreTransactionUpdateObserver(
            provider: provider,
            configuration: configuration
        )
        let collector = StoreUpdateCollector()

        let task = observer.start(
            receivedAt: { now },
            onUpdate: { update in
                await collector.append(update)
            },
            onError: { error in
                await collector.record(error)
            }
        )
        await task.value

        let collectedUpdates = await collector.collectedUpdates()
        let collectedErrors = await collector.collectedErrors()
        XCTAssertEqual(collectedUpdates, [update])
        XCTAssertEqual(collectedErrors, [])
    }
}

private struct FakeStoreEntitlementProvider: StoreEntitlementProviding {
    var purchaseOutcome: StorePurchaseOutcome?
    var restoreEntitlement: EntitlementConfiguration?
    var transactionUpdates: [StoreEntitlementUpdate]

    init(
        purchaseOutcome: StorePurchaseOutcome? = nil,
        restoreEntitlement: EntitlementConfiguration? = nil,
        transactionUpdates: [StoreEntitlementUpdate] = []
    ) {
        self.purchaseOutcome = purchaseOutcome
        self.restoreEntitlement = restoreEntitlement
        self.transactionUpdates = transactionUpdates
    }

    func fetchProducts(configuration: StoreProductConfiguration) async throws -> [StoreProductSummary] {
        configuration.allProductIDs.compactMap { productID in
            guard let plan = configuration.plan(for: productID) else { return nil }
            return StoreProductSummary(
                productID: productID,
                plan: plan,
                displayName: plan.displayName,
                displayPrice: "$0",
                isFamilyShareable: plan == .family
            )
        }
    }

    func purchase(
        plan: ProductAccessPlan,
        configuration: StoreProductConfiguration
    ) async throws -> StorePurchaseOutcome {
        guard let purchaseOutcome else {
            throw StoreEntitlementError.productNotFound(configuration.productID(for: plan) ?? plan.rawValue)
        }
        return purchaseOutcome
    }

    func restorePurchases(
        configuration: StoreProductConfiguration,
        restoredAt: Date
    ) async throws -> EntitlementConfiguration? {
        restoreEntitlement
    }
}

extension FakeStoreEntitlementProvider: StoreTransactionUpdateProviding {
    func entitlementUpdates(
        configuration: StoreProductConfiguration,
        receivedAt: @Sendable @escaping () -> Date
    ) -> AsyncThrowingStream<StoreEntitlementUpdate, Error> {
        AsyncThrowingStream { continuation in
            for update in transactionUpdates {
                continuation.yield(update)
            }
            continuation.finish()
        }
    }
}

private actor StoreUpdateCollector {
    private var updates: [StoreEntitlementUpdate] = []
    private var errors: [String] = []

    func append(_ update: StoreEntitlementUpdate) {
        updates.append(update)
    }

    func record(_ error: any Error) {
        errors.append(error.localizedDescription)
    }

    func collectedUpdates() -> [StoreEntitlementUpdate] {
        updates
    }

    func collectedErrors() -> [String] {
        errors
    }
}
