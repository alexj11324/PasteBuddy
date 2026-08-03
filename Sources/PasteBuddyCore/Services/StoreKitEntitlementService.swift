import Foundation

#if canImport(StoreKit)
import StoreKit
#endif

public struct StoreProductConfiguration: Codable, Equatable, Sendable {
    public var byokAnnualProductID: String
    public var cloudMonthlyProductID: String
    public var cloudAnnualProductID: String

    public init(
        byokAnnualProductID: String = "com.pastebuddy.ai.byok.annual",
        cloudMonthlyProductID: String = "com.pastebuddy.ai.cloud.monthly",
        cloudAnnualProductID: String = "com.pastebuddy.ai.cloud.annual"
    ) {
        self.byokAnnualProductID = byokAnnualProductID
        self.cloudMonthlyProductID = cloudMonthlyProductID
        self.cloudAnnualProductID = cloudAnnualProductID
    }

    public var allProductIDs: [String] {
        [
            byokAnnualProductID,
            cloudMonthlyProductID,
            cloudAnnualProductID
        ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public func productID(for plan: ProductAccessPlan) -> String? {
        let productID: String
        switch plan {
        case .byokAnnual:
            productID = byokAnnualProductID
        case .cloudMonthly:
            productID = cloudMonthlyProductID
        case .cloudAnnual:
            productID = cloudAnnualProductID
        case .free, .trial, .team:
            return nil
        }

        let trimmed = productID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func plan(for productID: String) -> ProductAccessPlan? {
        let trimmed = productID.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case byokAnnualProductID:
            return .byokAnnual
        case cloudMonthlyProductID:
            return .cloudMonthly
        case cloudAnnualProductID:
            return .cloudAnnual
        default:
            return nil
        }
    }
}

public struct StoreProductSummary: Codable, Equatable, Sendable {
    public var productID: String
    public var plan: ProductAccessPlan
    public var displayName: String
    public var displayPrice: String
    public var isFamilyShareable: Bool

    public init(
        productID: String,
        plan: ProductAccessPlan,
        displayName: String,
        displayPrice: String,
        isFamilyShareable: Bool
    ) {
        self.productID = productID
        self.plan = plan
        self.displayName = displayName
        self.displayPrice = displayPrice
        self.isFamilyShareable = isFamilyShareable
    }
}

public struct VerifiedStoreTransaction: Codable, Equatable, Sendable {
    public var productID: String
    public var purchaseDate: Date
    public var expirationDate: Date?
    public var revocationDate: Date?
    public var isFamilyShared: Bool

    public init(
        productID: String,
        purchaseDate: Date,
        expirationDate: Date? = nil,
        revocationDate: Date? = nil,
        isFamilyShared: Bool = false
    ) {
        self.productID = productID
        self.purchaseDate = purchaseDate
        self.expirationDate = expirationDate
        self.revocationDate = revocationDate
        self.isFamilyShared = isFamilyShared
    }

    public func isActive(now: Date = Date()) -> Bool {
        guard revocationDate == nil else { return false }
        guard let expirationDate else { return false }
        return expirationDate > now
    }
}

public enum StorePurchaseOutcome: Equatable, Sendable {
    case purchased(EntitlementConfiguration)
    case pending
    case userCancelled
}

public struct StoreEntitlementUpdate: Equatable, Sendable {
    public var transaction: VerifiedStoreTransaction
    public var entitlement: EntitlementConfiguration
    public var receivedAt: Date

    public init(
        transaction: VerifiedStoreTransaction,
        entitlement: EntitlementConfiguration,
        receivedAt: Date
    ) {
        self.transaction = transaction
        self.entitlement = entitlement
        self.receivedAt = receivedAt
    }
}

public enum StoreEntitlementError: LocalizedError, Equatable {
    case unsupportedPlan(ProductAccessPlan)
    case missingProductIdentifier(ProductAccessPlan)
    case productNotFound(String)
    case unverifiedTransaction

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlan(let plan):
            "StoreKit purchases are only available for personal paid plans, not \(plan.displayName)."
        case .missingProductIdentifier(let plan):
            "No StoreKit product identifier is configured for \(plan.displayName)."
        case .productNotFound(let productID):
            "StoreKit product \(productID) was not returned by the App Store."
        case .unverifiedTransaction:
            "StoreKit returned an unverified transaction; entitlement was not activated."
        }
    }
}

public protocol StoreEntitlementProviding: Sendable {
    func fetchProducts(configuration: StoreProductConfiguration) async throws -> [StoreProductSummary]
    func purchase(
        plan: ProductAccessPlan,
        configuration: StoreProductConfiguration
    ) async throws -> StorePurchaseOutcome
    func restorePurchases(
        configuration: StoreProductConfiguration,
        restoredAt: Date
    ) async throws -> EntitlementConfiguration?
}

public protocol StoreTransactionUpdateProviding: Sendable {
    func entitlementUpdates(
        configuration: StoreProductConfiguration,
        receivedAt: @Sendable @escaping () -> Date
    ) -> AsyncThrowingStream<StoreEntitlementUpdate, Error>
}

public final class StoreTransactionUpdateObserver: @unchecked Sendable {
    private let provider: any StoreTransactionUpdateProviding
    private let configuration: StoreProductConfiguration

    public init(
        provider: any StoreTransactionUpdateProviding,
        configuration: StoreProductConfiguration = StoreProductConfiguration()
    ) {
        self.provider = provider
        self.configuration = configuration
    }

    public func start(
        receivedAt: @Sendable @escaping () -> Date = { Date() },
        onUpdate: @escaping @Sendable (StoreEntitlementUpdate) async -> Void,
        onError: @escaping @Sendable (any Error) async -> Void
    ) -> Task<Void, Never> {
        Task {
            do {
                for try await update in provider.entitlementUpdates(
                    configuration: configuration,
                    receivedAt: receivedAt
                ) {
                    await onUpdate(update)
                }
            } catch {
                await onError(error)
            }
        }
    }
}

public enum StoreEntitlementMapper {
    public static func entitlement(
        from transaction: VerifiedStoreTransaction,
        plan: ProductAccessPlan,
        restoreState: RestorePurchasesState = .notStarted,
        now: Date = Date()
    ) -> EntitlementConfiguration {
        let status: EntitlementStatus
        if transaction.revocationDate != nil {
            status = .revoked
        } else if transaction.expirationDate.map({ $0 <= now }) ?? true {
            status = .expired
        } else {
            status = .active
        }

        let currentPeriodEndsAt = transaction.expirationDate
        return EntitlementConfiguration(
            plan: plan,
            status: status,
            purchasedAt: transaction.purchaseDate,
            currentPeriodEndsAt: currentPeriodEndsAt,
            expiresAt: transaction.expirationDate ?? transaction.revocationDate,
            isFamilySharingEnabled: false,
            unlocksAllDevicesForAccount: status == .active,
            restoreState: restoreState
        )
    }

    public static func bestActiveEntitlement(
        from transactions: [VerifiedStoreTransaction],
        configuration: StoreProductConfiguration,
        restoredAt: Date,
        now: Date = Date()
    ) -> EntitlementConfiguration? {
        transactions
            .filter { $0.isActive(now: now) }
            .compactMap { transaction -> (ProductAccessPlan, VerifiedStoreTransaction)? in
                guard let plan = configuration.plan(for: transaction.productID) else { return nil }
                return (plan, transaction)
            }
            .sorted { lhs, rhs in
                let lhsPriority = planPriority(lhs.0)
                let rhsPriority = planPriority(rhs.0)
                if lhsPriority == rhsPriority {
                    return lhs.1.purchaseDate > rhs.1.purchaseDate
                }
                return lhsPriority > rhsPriority
            }
            .first
            .map { plan, transaction in
                entitlement(
                    from: transaction,
                    plan: plan,
                    restoreState: .restored(restoredAt),
                    now: now
                )
            }
    }

    public static func update(
        from transaction: VerifiedStoreTransaction,
        configuration: StoreProductConfiguration,
        receivedAt: Date = Date()
    ) -> StoreEntitlementUpdate? {
        guard let plan = configuration.plan(for: transaction.productID) else {
            return nil
        }
        let entitlement = entitlement(
            from: transaction,
            plan: plan,
            now: receivedAt
        )
        return StoreEntitlementUpdate(
            transaction: transaction,
            entitlement: entitlement,
            receivedAt: receivedAt
        )
    }

    private static func planPriority(_ plan: ProductAccessPlan) -> Int {
        switch plan {
        case .cloudAnnual:
            3
        case .cloudMonthly:
            2
        case .byokAnnual:
            1
        case .free, .trial, .team:
            0
        }
    }
}

#if canImport(StoreKit)
public final class AppleStoreKitEntitlementProvider: StoreEntitlementProviding, StoreTransactionUpdateProviding, @unchecked Sendable {
    public init() {}

    public func fetchProducts(
        configuration: StoreProductConfiguration = StoreProductConfiguration()
    ) async throws -> [StoreProductSummary] {
        let products = try await Product.products(for: configuration.allProductIDs)
        return products.compactMap { product in
            guard let plan = configuration.plan(for: product.id) else { return nil }
            return StoreProductSummary(
                productID: product.id,
                plan: plan,
                displayName: product.displayName,
                displayPrice: product.displayPrice,
                isFamilyShareable: product.isFamilyShareable
            )
        }
    }

    public func purchase(
        plan: ProductAccessPlan,
        configuration: StoreProductConfiguration = StoreProductConfiguration()
    ) async throws -> StorePurchaseOutcome {
        guard plan.isPersonalPaidPlan else {
            throw StoreEntitlementError.unsupportedPlan(plan)
        }
        guard let productID = configuration.productID(for: plan) else {
            throw StoreEntitlementError.missingProductIdentifier(plan)
        }
        guard let product = try await Product.products(for: [productID]).first else {
            throw StoreEntitlementError.productNotFound(productID)
        }

        switch try await product.purchase() {
        case .success(let verification):
            let transaction = try verifiedTransaction(from: verification)
            await transaction.finish()
            let verified = VerifiedStoreTransaction(transaction: transaction)
            return .purchased(StoreEntitlementMapper.entitlement(
                from: verified,
                plan: plan,
                now: Date()
            ))
        case .pending:
            return .pending
        case .userCancelled:
            return .userCancelled
        @unknown default:
            return .pending
        }
    }

    public func restorePurchases(
        configuration: StoreProductConfiguration = StoreProductConfiguration(),
        restoredAt: Date = Date()
    ) async throws -> EntitlementConfiguration? {
        try await AppStore.sync()
        let products = try await Product.products(for: configuration.allProductIDs)
        var transactions: [VerifiedStoreTransaction] = []

        for product in products {
            guard let verification = await product.latestTransaction else { continue }
            let transaction = try verifiedTransaction(from: verification)
            transactions.append(VerifiedStoreTransaction(transaction: transaction))
        }

        return StoreEntitlementMapper.bestActiveEntitlement(
            from: transactions,
            configuration: configuration,
            restoredAt: restoredAt,
            now: restoredAt
        )
    }

    public func currentEntitlement(
        configuration: StoreProductConfiguration = StoreProductConfiguration(),
        now: Date = Date()
    ) async -> EntitlementConfiguration? {
        var transactions: [VerifiedStoreTransaction] = []
        for await verification in Transaction.currentEntitlements {
            guard case .verified(let transaction) = verification else { continue }
            transactions.append(VerifiedStoreTransaction(transaction: transaction))
        }
        return StoreEntitlementMapper.bestActiveEntitlement(
            from: transactions,
            configuration: configuration,
            restoredAt: now,
            now: now
        )
    }

    public func entitlementUpdates(
        configuration: StoreProductConfiguration = StoreProductConfiguration(),
        receivedAt: @Sendable @escaping () -> Date = { Date() }
    ) -> AsyncThrowingStream<StoreEntitlementUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for await verification in Transaction.updates {
                    guard case .verified(let transaction) = verification else { continue }
                    guard let update = StoreEntitlementMapper.update(
                        from: VerifiedStoreTransaction(transaction: transaction),
                        configuration: configuration,
                        receivedAt: receivedAt()
                    ) else {
                        await transaction.finish()
                        continue
                    }
                    continuation.yield(update)
                    await transaction.finish()
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func verifiedTransaction(
        from result: VerificationResult<Transaction>
    ) throws -> Transaction {
        switch result {
        case .verified(let transaction):
            return transaction
        case .unverified:
            throw StoreEntitlementError.unverifiedTransaction
        }
    }
}

extension VerifiedStoreTransaction {
    public init(transaction: Transaction) {
        self.init(
            productID: transaction.productID,
            purchaseDate: transaction.purchaseDate,
            expirationDate: transaction.expirationDate,
            revocationDate: transaction.revocationDate,
            isFamilyShared: transaction.ownershipType == .familyShared
        )
    }
}
#endif
