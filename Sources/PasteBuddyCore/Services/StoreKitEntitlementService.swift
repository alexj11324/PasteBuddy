import Foundation

#if canImport(StoreKit)
import StoreKit
#endif

public struct StoreProductConfiguration: Codable, Equatable, Sendable {
    public var monthlyProductID: String
    public var annualProductID: String
    public var lifetimeProductID: String
    public var familyProductID: String

    public init(
        monthlyProductID: String = "com.pastebuddy.subscription.monthly",
        annualProductID: String = "com.pastebuddy.subscription.annual",
        lifetimeProductID: String = "",
        familyProductID: String = ""
    ) {
        self.monthlyProductID = monthlyProductID
        self.annualProductID = annualProductID
        self.lifetimeProductID = lifetimeProductID
        self.familyProductID = familyProductID
    }

    public var allProductIDs: [String] {
        [
            monthlyProductID,
            annualProductID,
            lifetimeProductID,
            familyProductID
        ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public func productID(for plan: ProductAccessPlan) -> String? {
        let productID: String
        switch plan {
        case .monthly:
            productID = monthlyProductID
        case .annual:
            productID = annualProductID
        case .lifetime:
            productID = lifetimeProductID
        case .family:
            productID = familyProductID
        case .free, .trial, .team:
            return nil
        }

        let trimmed = productID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func plan(for productID: String) -> ProductAccessPlan? {
        let trimmed = productID.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case monthlyProductID:
            return .monthly
        case annualProductID:
            return .annual
        case lifetimeProductID:
            return .lifetime
        case familyProductID:
            return .family
        default:
            return nil
        }
    }
}

public struct StoreProductSummary: Codable, Equatable, Identifiable, Sendable {
    public enum PurchaseKind: String, Codable, Equatable, Sendable {
        case subscription
        case oneTime
        case unknown
    }

    public struct SubscriptionPeriod: Codable, Equatable, Sendable {
        public enum Unit: String, Codable, Equatable, Sendable {
            case day
            case week
            case month
            case year
        }

        public var value: Int
        public var unit: Unit

        public init(value: Int, unit: Unit) {
            self.value = value
            self.unit = unit
        }
    }

    public var productID: String
    public var plan: ProductAccessPlan
    public var displayName: String
    public var displayPrice: String
    public var isFamilyShareable: Bool
    public var purchaseKind: PurchaseKind
    public var subscriptionPeriod: SubscriptionPeriod?

    public var id: String { productID }

    public init(
        productID: String,
        plan: ProductAccessPlan,
        displayName: String,
        displayPrice: String,
        isFamilyShareable: Bool,
        purchaseKind: PurchaseKind = .unknown,
        subscriptionPeriod: SubscriptionPeriod? = nil
    ) {
        self.productID = productID
        self.plan = plan
        self.displayName = displayName
        self.displayPrice = displayPrice
        self.isFamilyShareable = isFamilyShareable
        self.purchaseKind = purchaseKind
        self.subscriptionPeriod = subscriptionPeriod
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
        return expirationDate.map { $0 > now } ?? true
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
    /// `nil` is authoritative: StoreKit was checked successfully and returned no active entitlement.
    func currentEntitlement(
        configuration: StoreProductConfiguration,
        checkedAt: Date
    ) async throws -> EntitlementConfiguration?
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
            _ = await run(
                receivedAt: receivedAt,
                onUpdate: onUpdate,
                onError: onError
            )
        }
    }

    /// Returns `true` only when observation failed and can be retried.
    @discardableResult
    public func run(
        receivedAt: @Sendable @escaping () -> Date = { Date() },
        onUpdate: @escaping @Sendable (StoreEntitlementUpdate) async -> Void,
        onError: @escaping @Sendable (any Error) async -> Void
    ) async -> Bool {
        do {
            for try await update in provider.entitlementUpdates(
                configuration: configuration,
                receivedAt: receivedAt
            ) {
                guard !Task.isCancelled else { return false }
                await onUpdate(update)
            }
            return false
        } catch {
            guard !Task.isCancelled else { return false }
            await onError(error)
            return true
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
        } else if transaction.expirationDate.map({ $0 <= now }) ?? false {
            status = .expired
        } else {
            status = .active
        }

        let currentPeriodEndsAt = plan == .monthly || plan == .annual || plan == .family
            ? transaction.expirationDate
            : nil
        return EntitlementConfiguration(
            plan: plan,
            status: status,
            purchasedAt: transaction.purchaseDate,
            currentPeriodEndsAt: currentPeriodEndsAt,
            expiresAt: transaction.expirationDate ?? transaction.revocationDate,
            isFamilySharingEnabled: transaction.isFamilyShared || plan == .family,
            unlocksAllDevicesForAccount: status == .active,
            restoreState: restoreState
        )
    }

    public static func bestActiveEntitlement(
        from transactions: [VerifiedStoreTransaction],
        configuration: StoreProductConfiguration,
        restoredAt: Date,
        now: Date = Date(),
        restoreState: RestorePurchasesState? = nil
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
                    restoreState: restoreState ?? .restored(restoredAt),
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
        case .lifetime:
            4
        case .family:
            3
        case .annual:
            2
        case .monthly:
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
                isFamilyShareable: product.isFamilyShareable,
                purchaseKind: product.subscription == nil ? .oneTime : .subscription,
                subscriptionPeriod: product.subscription.flatMap { subscription in
                    let period = subscription.subscriptionPeriod
                    let unit: StoreProductSummary.SubscriptionPeriod.Unit
                    switch period.unit {
                    case .day:
                        unit = .day
                    case .week:
                        unit = .week
                    case .month:
                        unit = .month
                    case .year:
                        unit = .year
                    @unknown default:
                        return nil
                    }
                    return StoreProductSummary.SubscriptionPeriod(
                        value: period.value,
                        unit: unit
                    )
                }
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

    public func currentEntitlement(
        configuration: StoreProductConfiguration = StoreProductConfiguration(),
        checkedAt: Date = Date()
    ) async throws -> EntitlementConfiguration? {
        var transactions: [VerifiedStoreTransaction] = []
        for await verification in Transaction.currentEntitlements {
            let transaction = try verifiedTransaction(from: verification)
            transactions.append(VerifiedStoreTransaction(transaction: transaction))
        }
        return StoreEntitlementMapper.bestActiveEntitlement(
            from: transactions,
            configuration: configuration,
            restoredAt: checkedAt,
            now: checkedAt,
            restoreState: .notStarted
        )
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

    public func entitlementUpdates(
        configuration: StoreProductConfiguration = StoreProductConfiguration(),
        receivedAt: @Sendable @escaping () -> Date = { Date() }
    ) -> AsyncThrowingStream<StoreEntitlementUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for await verification in Transaction.updates {
                        let transaction = try verifiedTransaction(from: verification)
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
                } catch {
                    continuation.finish(throwing: error)
                }
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
