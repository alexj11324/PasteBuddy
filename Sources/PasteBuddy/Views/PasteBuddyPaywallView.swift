import AppKit
import PasteBuddyCore
import SwiftUI

struct PasteBuddyPaywallView: View {
    @Bindable var store: PasteBuddyStore
    let onEntitlementActivated: @MainActor () async -> Void

    @Environment(\.dismissWindow) private var dismissWindow
    @State private var storeProducts: [StoreProductSummary] = []
    @State private var selectedProductID: String?
    @State private var isLoadingProducts = true
    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    private let provider = AppleStoreKitEntitlementProvider()
    private let productConfiguration = StoreProductConfiguration()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                accessSummary
                benefits
                products
                purchaseAction
                restoreAction
                legalTerms
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 520, idealWidth: 560, minHeight: 620, idealHeight: 700)
        .task {
            await loadProducts()
        }
    }

    private var header: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)

                Text("brand.pastebuddy_pro")
                    .font(.system(size: 26, weight: .bold, design: .rounded))

                Text("message.paywall_subtitle")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)

            Button {
                dismissWindow(id: "paywall")
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("action.close")
        }
    }

    private var accessSummary: some View {
        GroupBox {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: accessSummarySymbol)
                    .foregroundStyle(store.hasFullProductAccess ? .green : .orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(accessSummaryTitle)
                        .font(.headline)
                    Text(accessSummaryDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("label.included_with_pro")
                .font(.headline)

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                alignment: .leading,
                spacing: 10
            ) {
                PaywallBenefitRow(
                    systemImageName: "clock.arrow.circlepath",
                    titleKey: "paywall.benefit.history.title",
                    detailKey: "paywall.benefit.history.detail"
                )
                PaywallBenefitRow(
                    systemImageName: "magnifyingglass",
                    titleKey: "paywall.benefit.search.title",
                    detailKey: "paywall.benefit.search.detail"
                )
                PaywallBenefitRow(
                    systemImageName: "keyboard",
                    titleKey: "paywall.benefit.shortcuts.title",
                    detailKey: "paywall.benefit.shortcuts.detail"
                )
                PaywallBenefitRow(
                    systemImageName: "lock.shield",
                    titleKey: "paywall.benefit.privacy.title",
                    detailKey: "paywall.benefit.privacy.detail"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var products: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("label.choose_plan")
                .font(.headline)

            if isLoadingProducts {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("message.loading_app_store_products")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
            } else if storeProducts.isEmpty {
                ContentUnavailableView {
                    Label("message.store_products_unavailable.title", systemImage: "cart.badge.questionmark")
                } description: {
                    Text("message.store_products_unavailable.detail")
                } actions: {
                    Button("action.retry") {
                        Task {
                            await loadProducts()
                        }
                    }
                    .disabled(isLoadingProducts)

                    Button {
                        restorePurchases()
                    } label: {
                        HStack(spacing: 6) {
                            if isRestoring {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text("action.restore_purchases")
                        }
                    }
                    .disabled(isPurchasing || isRestoring)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                ForEach(storeProducts) { product in
                    productRow(product)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func productRow(_ product: StoreProductSummary) -> some View {
        let isSelected = selectedProductID == product.productID
        return Button {
            selectedProductID = product.productID
            statusMessage = nil
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(product.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(productTerms(for: product))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Text(product.displayPrice)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.primary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSelected ? 2 : 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var purchaseAction: some View {
        if let statusMessage {
            Label(statusMessage, systemImage: statusIsError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.callout)
                .foregroundStyle(statusIsError ? .orange : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        if let selectedProduct {
            Button {
                purchase(selectedProduct)
            } label: {
                HStack(spacing: 8) {
                    if isPurchasing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(localized("format.continue_with_plan", selectedProduct.displayName))
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isPurchasing || isRestoring)
        }
    }

    @ViewBuilder
    private var restoreAction: some View {
        if isLoadingProducts || !storeProducts.isEmpty {
            Button {
                restorePurchases()
            } label: {
                HStack(spacing: 8) {
                    if isRestoring {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("action.restore_purchases")
                }
            }
            .buttonStyle(.link)
            .disabled(isPurchasing || isRestoring)
        }
    }

    private var legalTerms: some View {
        VStack(spacing: 4) {
            Text("message.paywall_no_automatic_trial_charge")
            Text("message.paywall_app_store_confirmation")
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
    }

    private var selectedProduct: StoreProductSummary? {
        guard let selectedProductID else { return nil }
        return storeProducts.first { $0.productID == selectedProductID }
    }

    private var accessSummarySymbol: String {
        store.hasFullProductAccess ? "checkmark.seal.fill" : "lock.fill"
    }

    private var accessSummaryTitle: LocalizedStringKey {
        if store.snapshot.entitlement.isTrialActive() {
            return "label.free_trial_active"
        }
        if store.snapshot.entitlement.hasActivePaidAccess() {
            return "label.plan_active"
        }
        return "label.trial_ended"
    }

    private var accessSummaryDetail: String {
        if let end = store.snapshot.entitlement.trialEndsAt,
           store.snapshot.entitlement.isTrialActive() {
            return localized("format.free_trial_ends_at", end.formatted(date: .long, time: .shortened))
        }
        if store.snapshot.entitlement.hasActivePaidAccess() {
            return localized("format.current_plan_name", localizedPlanName(store.snapshot.entitlement.plan))
        }
        return localized("message.trial_ended_purchase_required")
    }

    private func loadProducts() async {
        isLoadingProducts = true
        statusMessage = nil
        do {
            storeProducts = try await provider.fetchProducts(configuration: productConfiguration)
                .sorted { planPriority($0.plan) < planPriority($1.plan) }
            selectedProductID = preferredProductID(in: storeProducts)
            statusIsError = false
        } catch {
            storeProducts = []
            selectedProductID = nil
            statusMessage = error.localizedDescription
            statusIsError = true
        }
        isLoadingProducts = false
    }

    private func purchase(_ product: StoreProductSummary) {
        isPurchasing = true
        statusMessage = nil
        Task {
            let outcome = await store.purchasePersonalPlan(
                product.plan,
                using: provider,
                productConfiguration: productConfiguration
            )
            switch outcome {
            case .purchased:
                guard await store.flushPendingSave() else {
                    statusMessage = localized("message.purchase_persistence_failed")
                    statusIsError = true
                    isPurchasing = false
                    return
                }
                statusMessage = localized("message.purchase_succeeded")
                statusIsError = false
                await onEntitlementActivated()
                dismissWindow(id: "paywall")
            case .pending:
                statusMessage = localized("message.purchase_pending")
                statusIsError = false
            case .userCancelled:
                statusMessage = nil
                statusIsError = false
            case nil:
                statusMessage = store.lastErrorMessage ?? localized("message.purchase_failed")
                statusIsError = true
            }
            isPurchasing = false
        }
    }

    private func restorePurchases() {
        isRestoring = true
        statusMessage = nil
        Task {
            let entitlement = await store.restorePurchases(
                using: provider,
                productConfiguration: productConfiguration
            )
            let didPersist = await store.flushPendingSave()
            guard entitlement != nil, didPersist, store.hasFullProductAccess else {
                statusMessage = store.lastErrorMessage ?? localized("message.restore_purchases_failed")
                statusIsError = true
                isRestoring = false
                return
            }
            statusMessage = localized("message.restore_purchases_succeeded")
            statusIsError = false
            await onEntitlementActivated()
            dismissWindow(id: "paywall")
            isRestoring = false
        }
    }

    private func productTerms(for product: StoreProductSummary) -> String {
        if let period = product.subscriptionPeriod {
            return localized(
                "format.paywall_subscription_terms",
                localizedPeriod(period)
            )
        }
        switch product.purchaseKind {
        case .oneTime:
            return localized("message.paywall_one_time_purchase")
        case .subscription, .unknown:
            return localized("message.paywall_terms_in_confirmation")
        }
    }

    private func localizedPeriod(_ period: StoreProductSummary.SubscriptionPeriod) -> String {
        switch period.unit {
        case .day:
            period.value == 1 ? localized("label.billing_day") : localized("format.billing_days", period.value)
        case .week:
            period.value == 1 ? localized("label.billing_week") : localized("format.billing_weeks", period.value)
        case .month:
            period.value == 1 ? localized("label.billing_month") : localized("format.billing_months", period.value)
        case .year:
            period.value == 1 ? localized("label.billing_year") : localized("format.billing_years", period.value)
        }
    }

    private func preferredProductID(in products: [StoreProductSummary]) -> String? {
        products.first(where: { $0.plan == .annual })?.productID ?? products.first?.productID
    }

    private func planPriority(_ plan: ProductAccessPlan) -> Int {
        switch plan {
        case .annual: 0
        case .monthly: 1
        case .lifetime: 2
        case .family: 3
        case .free, .trial, .team: 4
        }
    }

    private func localizedPlanName(_ plan: ProductAccessPlan) -> String {
        localized("label.\(plan.rawValue)")
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    private func localized(_ key: String, _ arguments: CVarArg...) -> String {
        String(
            format: NSLocalizedString(key, comment: ""),
            locale: Locale.current,
            arguments: arguments
        )
    }
}

private struct PaywallBenefitRow: View {
    let systemImageName: String
    let titleKey: LocalizedStringKey
    let detailKey: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImageName)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(titleKey)
                    .font(.subheadline.weight(.semibold))
                Text(detailKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
