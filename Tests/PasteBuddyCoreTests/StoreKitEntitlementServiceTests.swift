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

    func testProductSummaryCarriesAppStoreBillingTerms() {
        let summary = StoreProductSummary(
            productID: "annual.id",
            plan: .annual,
            displayName: "Annual",
            displayPrice: "$49.99",
            isFamilyShareable: false,
            purchaseKind: .subscription,
            subscriptionPeriod: .init(value: 1, unit: .year)
        )

        XCTAssertEqual(summary.purchaseKind, .subscription)
        XCTAssertEqual(summary.subscriptionPeriod, .init(value: 1, unit: .year))
        XCTAssertEqual(summary.displayPrice, "$49.99")
    }

    func testCurrentStoreEntitlementIsAppliedBeforeTrialEligibilityAndPersists() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        let now = Date(timeIntervalSince1970: 2_000)
        let entitlement = EntitlementConfiguration(
            plan: .annual,
            status: .active,
            purchasedAt: now.addingTimeInterval(-100),
            currentPeriodEndsAt: now.addingTimeInterval(10_000),
            expiresAt: now.addingTimeInterval(10_000),
            unlocksAllDevicesForAccount: true
        )
        let provider = FakeStoreEntitlementProvider(currentEntitlement: entitlement)
        let store = PasteBuddyStore(diskStore: harness.snapshotStore)

        let refreshed = try await store.refreshCurrentStoreEntitlement(using: provider, at: now)

        XCTAssertEqual(refreshed?.plan, .annual)
        XCTAssertFalse(store.startFreeTrialIfEligible(days: 7, now: now))
        let didPersist = await store.flushPendingSave()
        XCTAssertTrue(didPersist)

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()
        XCTAssertEqual(reloaded.snapshot.entitlement.plan, .annual)
        XCTAssertTrue(reloaded.snapshot.entitlement.hasFullAccess(now: now))
    }

    func testCurrentEntitlementReconcileClearsCachedPaidAccessWithoutRestartingUsedTrial() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        let trialStartedAt = Date(timeIntervalSince1970: 10_000)
        let checkedAt = trialStartedAt.addingTimeInterval(24 * 60 * 60)
        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        XCTAssertTrue(store.startFreeTrialIfEligible(days: 7, now: trialStartedAt))
        let trialEndsAt = try XCTUnwrap(store.snapshot.entitlement.trialEndsAt)

        let paidEntitlement = EntitlementConfiguration(
            plan: .lifetime,
            status: .active,
            purchasedAt: checkedAt,
            unlocksAllDevicesForAccount: true
        )
        _ = try await store.refreshCurrentStoreEntitlement(
            using: FakeStoreEntitlementProvider(currentEntitlement: paidEntitlement),
            at: checkedAt
        )

        XCTAssertEqual(store.snapshot.entitlement.trialStartedAt, trialStartedAt)
        XCTAssertEqual(store.snapshot.entitlement.trialEndsAt, trialEndsAt)
        XCTAssertTrue(store.snapshot.entitlement.hasFullAccess(now: checkedAt))

        let noEntitlement = try await store.refreshCurrentStoreEntitlement(
            using: FakeStoreEntitlementProvider(currentEntitlement: nil),
            at: checkedAt.addingTimeInterval(60)
        )

        XCTAssertNil(noEntitlement)
        XCTAssertEqual(store.snapshot.entitlement.plan, .free)
        XCTAssertEqual(store.snapshot.entitlement.status, .inactive)
        XCTAssertEqual(store.snapshot.entitlement.trialStartedAt, trialStartedAt)
        XCTAssertEqual(store.snapshot.entitlement.trialEndsAt, trialEndsAt)
        XCTAssertFalse(store.snapshot.entitlement.hasFullAccess(now: checkedAt.addingTimeInterval(60)))
        XCTAssertFalse(store.startFreeTrialIfEligible(days: 7, now: checkedAt.addingTimeInterval(60)))
        let didPersist = await store.flushPendingSave()
        XCTAssertTrue(didPersist)

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()
        XCTAssertEqual(reloaded.snapshot.entitlement.plan, .free)
        XCTAssertEqual(reloaded.snapshot.entitlement.trialStartedAt, trialStartedAt)
        XCTAssertEqual(reloaded.snapshot.entitlement.trialEndsAt, trialEndsAt)
        XCTAssertFalse(reloaded.startFreeTrialIfEligible(days: 7, now: checkedAt.addingTimeInterval(120)))
    }

    func testCurrentEntitlementQueryFailureDoesNotClearCachedPaidAccess() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        let now = Date(timeIntervalSince1970: 12_000)
        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.snapshot.entitlement = EntitlementConfiguration(
            plan: .annual,
            status: .active,
            purchasedAt: now.addingTimeInterval(-100),
            currentPeriodEndsAt: now.addingTimeInterval(10_000),
            expiresAt: now.addingTimeInterval(10_000),
            unlocksAllDevicesForAccount: true
        )

        do {
            _ = try await store.refreshCurrentStoreEntitlement(
                using: FakeStoreEntitlementProvider(currentEntitlementShouldFail: true),
                at: now
            )
            XCTFail("Expected StoreKit verification failure")
        } catch {
            XCTAssertEqual(error as? StoreEntitlementError, .unverifiedTransaction)
        }

        XCTAssertEqual(store.snapshot.entitlement.plan, .annual)
        XCTAssertEqual(store.snapshot.entitlement.status, .active)
        XCTAssertTrue(store.snapshot.entitlement.hasFullAccess(now: now))
        XCTAssertEqual(
            store.lastErrorMessage,
            StoreEntitlementError.unverifiedTransaction.localizedDescription
        )
    }

    func testSuccessfulEmptyCurrentEntitlementsDoesNotMutateLocalTrial() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        let now = Date(timeIntervalSince1970: 13_000)
        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        XCTAssertTrue(store.startFreeTrialIfEligible(days: 7, now: now))
        let trial = store.snapshot.entitlement

        let result = try await store.refreshCurrentStoreEntitlement(
            using: FakeStoreEntitlementProvider(currentEntitlement: nil),
            at: now.addingTimeInterval(60)
        )

        XCTAssertNil(result)
        XCTAssertEqual(store.snapshot.entitlement, trial)
        XCTAssertTrue(store.snapshot.entitlement.hasFullAccess(now: now.addingTimeInterval(60)))
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
                expirationDate: now.addingTimeInterval(100),
                revocationDate: now.addingTimeInterval(-10)
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

    func testFullAccountReconcileIgnoresOldRevocationWhenNewerSamePlanTransactionIsActive() {
        let now = Date(timeIntervalSince1970: 1_250)
        let configuration = StoreProductConfiguration(annualProductID: "annual.id")
        let entitlement = StoreEntitlementMapper.bestActiveEntitlement(
            from: [
                VerifiedStoreTransaction(
                    productID: "annual.id",
                    purchaseDate: now.addingTimeInterval(-1_000),
                    expirationDate: now.addingTimeInterval(-500),
                    revocationDate: now.addingTimeInterval(-400)
                ),
                VerifiedStoreTransaction(
                    productID: "annual.id",
                    purchaseDate: now.addingTimeInterval(-100),
                    expirationDate: now.addingTimeInterval(10_000)
                )
            ],
            configuration: configuration,
            restoredAt: now,
            now: now
        )

        XCTAssertEqual(entitlement?.plan, .annual)
        XCTAssertEqual(entitlement?.status, .active)
        XCTAssertEqual(entitlement?.purchasedAt, now.addingTimeInterval(-100))
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
        let trialStartedAt = now.addingTimeInterval(-100)
        XCTAssertTrue(store.startFreeTrialIfEligible(days: 7, now: trialStartedAt))
        let trialEndsAt = try XCTUnwrap(store.snapshot.entitlement.trialEndsAt)

        let outcome = await store.purchasePersonalPlan(
            .annual,
            using: provider,
            productConfiguration: configuration
        )

        XCTAssertEqual(outcome, .purchased(entitlement))
        XCTAssertEqual(store.snapshot.entitlement.plan, .annual)
        XCTAssertTrue(store.snapshot.entitlement.hasFullAccess(now: now.addingTimeInterval(60)))
        XCTAssertEqual(store.snapshot.entitlement.trialStartedAt, trialStartedAt)
        XCTAssertEqual(store.snapshot.entitlement.trialEndsAt, trialEndsAt)

        let raw = try Data(contentsOf: harness.snapshotStore.fileURL)
        let rawString = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(rawString.contains("annual.id"))
        XCTAssertFalse(rawString.contains("Annual"))
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
        let trialStartedAt = restoredAt.addingTimeInterval(-1_000)
        XCTAssertTrue(store.startFreeTrialIfEligible(days: 7, now: trialStartedAt))
        let trialEndsAt = try XCTUnwrap(store.snapshot.entitlement.trialEndsAt)

        let restored = await store.restorePurchases(
            using: restoringProvider,
            at: restoredAt
        )

        XCTAssertEqual(restored?.plan, restoredEntitlement.plan)
        XCTAssertEqual(store.snapshot.entitlement.plan, .family)
        XCTAssertEqual(store.snapshot.entitlement.restoreState, .restored(restoredAt))
        XCTAssertEqual(store.snapshot.entitlement.trialStartedAt, trialStartedAt)
        XCTAssertEqual(store.snapshot.entitlement.trialEndsAt, trialEndsAt)
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

    func testTransactionUpdateObserverReportsRetryableFailure() async {
        let provider = FakeStoreEntitlementProvider(transactionUpdateFails: true)
        let observer = StoreTransactionUpdateObserver(provider: provider)
        let collector = StoreUpdateCollector()

        let shouldRetry = await observer.run(
            onUpdate: { update in
                await collector.append(update)
            },
            onError: { error in
                await collector.record(error)
            }
        )

        XCTAssertTrue(shouldRetry)
        let collectedErrors = await collector.collectedErrors()
        XCTAssertEqual(collectedErrors, [TestStoreError.transactionUpdates.localizedDescription])
    }
}

private enum TestStoreError: LocalizedError {
    case transactionUpdates

    var errorDescription: String? { "Transaction updates failed." }
}

private struct FakeStoreEntitlementProvider: StoreEntitlementProviding {
    var currentEntitlement: EntitlementConfiguration?
    var currentEntitlementShouldFail: Bool
    var purchaseOutcome: StorePurchaseOutcome?
    var restoreEntitlement: EntitlementConfiguration?
    var transactionUpdates: [StoreEntitlementUpdate]
    var transactionUpdateFails: Bool

    init(
        currentEntitlement: EntitlementConfiguration? = nil,
        currentEntitlementShouldFail: Bool = false,
        purchaseOutcome: StorePurchaseOutcome? = nil,
        restoreEntitlement: EntitlementConfiguration? = nil,
        transactionUpdates: [StoreEntitlementUpdate] = [],
        transactionUpdateFails: Bool = false
    ) {
        self.currentEntitlement = currentEntitlement
        self.currentEntitlementShouldFail = currentEntitlementShouldFail
        self.purchaseOutcome = purchaseOutcome
        self.restoreEntitlement = restoreEntitlement
        self.transactionUpdates = transactionUpdates
        self.transactionUpdateFails = transactionUpdateFails
    }

    func currentEntitlement(
        configuration: StoreProductConfiguration,
        checkedAt: Date
    ) async throws -> EntitlementConfiguration? {
        if currentEntitlementShouldFail {
            throw StoreEntitlementError.unverifiedTransaction
        }
        return currentEntitlement
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
            if transactionUpdateFails {
                continuation.finish(throwing: TestStoreError.transactionUpdates)
                return
            }
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
