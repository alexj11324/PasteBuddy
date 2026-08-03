import XCTest
@testable import PasteBuddyCore

@MainActor
final class StoreKitEntitlementServiceTests: XCTestCase {
    func testProductConfigurationContainsOnlyRecurringAIPlans() {
        let configuration = StoreProductConfiguration(
            byokAnnualProductID: "byok.id",
            cloudMonthlyProductID: "cloud.monthly.id",
            cloudAnnualProductID: "cloud.annual.id"
        )

        XCTAssertEqual(configuration.productID(for: .byokAnnual), "byok.id")
        XCTAssertEqual(configuration.productID(for: .cloudMonthly), "cloud.monthly.id")
        XCTAssertEqual(configuration.productID(for: .cloudAnnual), "cloud.annual.id")
        XCTAssertNil(configuration.productID(for: .free))
        XCTAssertEqual(configuration.allProductIDs, ["byok.id", "cloud.monthly.id", "cloud.annual.id"])
    }

    func testCapabilityMatrixAndExpiryFailClosed() {
        let now = Date(timeIntervalSince1970: 10_000)
        let expiry = now.addingTimeInterval(60)
        let byok = EntitlementConfiguration(
            plan: .byokAnnual, status: .active, currentPeriodEndsAt: expiry, expiresAt: expiry
        )
        let cloud = EntitlementConfiguration(
            plan: .cloudMonthly, status: .active, currentPeriodEndsAt: expiry, expiresAt: expiry
        )
        let malformed = EntitlementConfiguration(plan: .cloudAnnual, status: .active)

        XCTAssertTrue(byok.hasBYOKAccess(now: now))
        XCTAssertFalse(byok.hasCloudAccess(now: now))
        XCTAssertTrue(cloud.hasBYOKAccess(now: now))
        XCTAssertTrue(cloud.hasCloudAccess(now: now))
        XCTAssertFalse(cloud.hasBYOKAccess(now: expiry))
        XCTAssertFalse(cloud.hasCloudAccess(now: expiry))
        XCTAssertFalse(malformed.hasBYOKAccess(now: now))
        XCTAssertFalse(malformed.hasCloudAccess(now: now))
    }

    func testVerifiedTrialConfigurationUnlocksBothCapabilities() {
        let now = Date(timeIntervalSince1970: 20_000)
        let trial = EntitlementConfiguration(
            plan: .trial,
            status: .trialing,
            trialStartedAt: now,
            trialEndsAt: now.addingTimeInterval(7 * 24 * 60 * 60)
        )

        XCTAssertTrue(trial.hasBYOKAccess(now: now))
        XCTAssertTrue(trial.hasCloudAccess(now: now))
        XCTAssertFalse(trial.hasBYOKAccess(now: now.addingTimeInterval(8 * 24 * 60 * 60)))
    }

    func testRestorePrefersCloudAnnualAndRejectsMissingExpiration() {
        let now = Date(timeIntervalSince1970: 30_000)
        let configuration = StoreProductConfiguration(
            byokAnnualProductID: "byok.id",
            cloudMonthlyProductID: "cloud.monthly.id",
            cloudAnnualProductID: "cloud.annual.id"
        )
        let transactions = [
            VerifiedStoreTransaction(
                productID: "byok.id", purchaseDate: now.addingTimeInterval(-20),
                expirationDate: now.addingTimeInterval(100)
            ),
            VerifiedStoreTransaction(
                productID: "cloud.annual.id", purchaseDate: now.addingTimeInterval(-10),
                expirationDate: now.addingTimeInterval(100)
            ),
            VerifiedStoreTransaction(productID: "cloud.monthly.id", purchaseDate: now)
        ]

        let entitlement = StoreEntitlementMapper.bestActiveEntitlement(
            from: transactions, configuration: configuration, restoredAt: now, now: now
        )

        XCTAssertEqual(entitlement?.plan, .cloudAnnual)
        XCTAssertTrue(entitlement?.hasCloudAccess(now: now) == true)
        XCTAssertFalse(transactions[2].isActive(now: now))
    }

    func testPurchaseAndVerifiedUpdateAreOnlyActivationPaths() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        let now = Date(timeIntervalSince1970: 40_000)
        let expiry = now.addingTimeInterval(100)
        let purchased = EntitlementConfiguration(
            plan: .cloudMonthly, status: .active, purchasedAt: now,
            currentPeriodEndsAt: expiry, expiresAt: expiry, unlocksAllDevicesForAccount: true
        )
        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let provider = FakeStoreEntitlementProvider(purchaseOutcome: .purchased(purchased))

        let outcome = await store.purchasePersonalPlan(.cloudMonthly, using: provider)
        XCTAssertEqual(outcome, .purchased(purchased))
        XCTAssertTrue(store.snapshot.entitlement.hasCloudAccess(now: now))

        let revoked = EntitlementConfiguration(
            plan: .cloudMonthly, status: .revoked, purchasedAt: now, expiresAt: now
        )
        store.applyStoreEntitlementUpdate(StoreEntitlementUpdate(
            transaction: VerifiedStoreTransaction(
                productID: "com.pastebuddy.ai.cloud.monthly", purchaseDate: now,
                expirationDate: expiry, revocationDate: now
            ),
            entitlement: revoked,
            receivedAt: now
        ))
        XCTAssertFalse(store.snapshot.entitlement.hasBYOKAccess(now: now))
        XCTAssertFalse(store.snapshot.entitlement.hasCloudAccess(now: now))
    }

    func testLegacyNonRecurringPlanValuesMigrateToFree() throws {
        for legacy in ["monthly", "annual", "lifetime", "family"] {
            let plan = try JSONDecoder().decode(ProductAccessPlan.self, from: Data("\"\(legacy)\"".utf8))
            XCTAssertEqual(plan, .free)
        }
    }
}

private struct FakeStoreEntitlementProvider: StoreEntitlementProviding {
    var purchaseOutcome: StorePurchaseOutcome?
    var restoreEntitlement: EntitlementConfiguration?

    init(
        purchaseOutcome: StorePurchaseOutcome? = nil,
        restoreEntitlement: EntitlementConfiguration? = nil
    ) {
        self.purchaseOutcome = purchaseOutcome
        self.restoreEntitlement = restoreEntitlement
    }

    func fetchProducts(configuration: StoreProductConfiguration) async throws -> [StoreProductSummary] {
        configuration.allProductIDs.compactMap { productID in
            guard let plan = configuration.plan(for: productID) else { return nil }
            return StoreProductSummary(
                productID: productID, plan: plan, displayName: plan.displayName,
                displayPrice: "$0", isFamilyShareable: false
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
