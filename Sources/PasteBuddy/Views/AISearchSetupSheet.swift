import Foundation
import PasteBuddyCore
import SwiftUI

struct AISearchSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Bindable var store: PasteBuddyStore
    @State private var products: [StoreProductSummary] = []
    @State private var isLoadingProducts = false
    @State private var purchasingPlan: ProductAccessPlan?
    @State private var configuration: BYOKProviderConfiguration
    @State private var documentAPIKey = ""
    @State private var embeddingAPIKey = ""
    @State private var showsAdvancedSettings = false
    @State private var productError: String?
    @State private var pendingSource: SemanticInferenceSource?
    @State private var pendingBYOKSave = false

    init(store: PasteBuddyStore) {
        self.store = store
        _configuration = State(initialValue: store.snapshot.semanticIndex.byok)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("label.ai_search")
                        .font(.title2.bold())
                    Text("message.ai_setup_summary")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    planSection
                    if store.hasBYOKAccess {
                        sourceSection
                    }
                    if store.snapshot.semanticIndex.inferenceSource == .byok
                        || store.hasAnyConfiguredBYOKKey {
                        byokSection
                    }
                    if store.hasBYOKAccess || store.hasAnyConfiguredBYOKKey {
                        privacySection
                    }
                }
                .padding(20)
            }

            Divider()
            HStack {
                if let message = statusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(statusIsFailure ? .red : .secondary)
                }
                Spacer()
                Button("action.cancel") { dismiss() }
                if store.canRunConfiguredAISource {
                    Button("action.enable_ai_search") {
                        store.setSemanticIndexEnabled(true)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
        }
        .frame(width: 580, height: 620)
        .task {
            normalizeInferenceSource()
            await loadProducts()
        }
        .confirmationDialog(
            "label.confirm_ai_reindex",
            isPresented: Binding(
                get: { pendingSource != nil || pendingBYOKSave },
                set: { if !$0 { pendingSource = nil; pendingBYOKSave = false } }
            ),
            titleVisibility: .visible
        ) {
            Button("action.reindex_and_continue") {
                if let source = pendingSource {
                    store.setSemanticInferenceSource(source)
                } else if pendingBYOKSave {
                    saveBYOKConfiguration()
                }
                pendingSource = nil
                pendingBYOKSave = false
            }
            Button("action.cancel", role: .cancel) {
                pendingSource = nil
                pendingBYOKSave = false
            }
        } message: {
            Text("message.ai_reindex_required")
        }
    }

    private var planSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("label.choose_ai_plan", systemImage: "lock.open.fill")
                .font(.headline)
            Text("message.ai_plan_comparison")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(products, id: \.productID) { product in
                HStack(spacing: 12) {
                    Image(systemName: symbol(for: product.plan))
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: product.displayName).fontWeight(.semibold)
                        Text(planDetail(product.plan)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(verbatim: product.displayPrice).fontWeight(.medium)
                    Button {
                        Task { await purchase(product.plan) }
                    } label: {
                        Text(purchaseActionKey(for: product.plan))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(purchasingPlan != nil || isCurrentPlan(product.plan))
                }
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if isLoadingProducts { ProgressView().controlSize(.small) }
            if !isLoadingProducts, products.isEmpty {
                HStack {
                    Label("message.ai_products_unavailable", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("action.retry") { Task { await loadProducts() } }
                }
            }
            Button("action.restore_purchases") {
                Task {
                    _ = await store.restorePurchases(using: AppleStoreKitEntitlementProvider())
                    normalizeInferenceSource()
                    await loadProducts()
                }
            }
            .buttonStyle(.link)
            if store.hasBYOKAccess {
                Button("action.manage_app_store_subscription") {
                    if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                        openURL(url)
                    }
                }
                .buttonStyle(.link)
            }
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("label.ai_inference_source", systemImage: "arrow.triangle.branch")
                .font(.headline)
            Picker("label.ai_inference_source", selection: Binding(
                get: { store.snapshot.semanticIndex.inferenceSource },
                set: { source in
                    if source != store.snapshot.semanticIndex.inferenceSource,
                       store.semanticIndexStatistics.ready > 0 {
                        pendingSource = source
                    } else {
                        store.setSemanticInferenceSource(source)
                    }
                }
            )) {
                if store.hasCloudAIAccess {
                    Text("label.pastebuddy_cloud").tag(SemanticInferenceSource.pasteBuddyCloud)
                }
                if store.hasBYOKAccess {
                    Text("label.bring_your_own_key").tag(SemanticInferenceSource.byok)
                }
            }
            .pickerStyle(.segmented)
            Text(sourceDetailKey)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var byokSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("label.configure_byok", systemImage: "key.fill").font(.headline)
            Picker("label.document_provider", selection: $configuration.preset) {
                providerChoices
            }
            .onChange(of: configuration.preset) { _, preset in
                let defaults = BYOKProviderConfiguration.defaults(for: preset)
                configuration.baseURL = defaults.baseURL
                configuration.documentModel = defaults.documentModel
                configuration.organizationID = defaults.organizationID
                configuration.projectID = defaults.projectID
                documentAPIKey = ""
            }
            SecureField("label.document_api_key", text: $documentAPIKey)
                .textFieldStyle(.roundedBorder)
            Picker("label.embedding_provider", selection: $configuration.embeddingPreset) {
                providerChoices
            }
            .onChange(of: configuration.embeddingPreset) { _, preset in
                let defaults = BYOKProviderConfiguration.defaults(for: preset)
                configuration.embeddingBaseURL = defaults.embeddingBaseURL
                configuration.embeddingModel = defaults.embeddingModel
                embeddingAPIKey = ""
            }
            if !rolesShareEndpoint {
                SecureField("label.embedding_api_key", text: $embeddingAPIKey)
                    .textFieldStyle(.roundedBorder)
            }
            DisclosureGroup("label.advanced_settings", isExpanded: $showsAdvancedSettings) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    settingsRow("label.document_base_url", text: $configuration.baseURL)
                    settingsRow("label.multimodal_model", text: $configuration.documentModel)
                    settingsRow("label.embedding_base_url", text: $configuration.embeddingBaseURL)
                    settingsRow("label.embedding_model", text: $configuration.embeddingModel)
                    if configuration.preset != .gemini {
                        settingsRow("label.organization_id", text: $configuration.organizationID)
                        settingsRow("label.project_id", text: $configuration.projectID)
                    }
                }
                .padding(.top, 8)
            }
            HStack {
                Button("action.test_and_save") {
                    if configuration != store.snapshot.semanticIndex.byok,
                       store.semanticIndexStatistics.ready > 0 {
                        pendingBYOKSave = true
                    } else {
                        saveBYOKConfiguration()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !hasDocumentCredential
                        || !hasEmbeddingCredential
                        || store.aiProviderConnectionState == .testing
                        || !store.hasBYOKAccess
                )
                if store.hasBYOKAPIKey(role: .document, configuration: configuration) {
                    Button(role: .destructive) {
                        store.deleteBYOKAPIKey(
                            role: .document,
                            configuration: configuration
                        )
                    } label: {
                        if rolesShareEndpoint {
                            Text("action.delete_api_key")
                        } else {
                            Text("action.delete_document_api_key")
                        }
                    }
                }
                if !rolesShareEndpoint,
                   store.hasBYOKAPIKey(role: .embedding, configuration: configuration) {
                    Button("action.delete_embedding_api_key", role: .destructive) {
                        store.deleteBYOKAPIKey(
                            role: .embedding,
                            configuration: configuration
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var providerChoices: some View {
        Text("label.provider_openai").tag(BYOKProviderPreset.openAI)
        Text("label.provider_gemini").tag(BYOKProviderPreset.gemini)
        Text("label.provider_openai_compatible").tag(BYOKProviderPreset.openAICompatible)
        Text("label.provider_sub2api").tag(BYOKProviderPreset.sub2API)
        Text("label.provider_openrouter").tag(BYOKProviderPreset.openRouter)
    }

    private var hasDocumentCredential: Bool {
        !documentAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || store.hasBYOKAPIKey(role: .document, configuration: configuration)
    }

    private var hasEmbeddingCredential: Bool {
        if rolesShareEndpoint { return hasDocumentCredential }
        return !embeddingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || store.hasBYOKAPIKey(role: .embedding, configuration: configuration)
    }

    private var rolesShareEndpoint: Bool {
        configuration.preset == configuration.embeddingPreset
            && normalizedBaseURL(configuration.baseURL) == normalizedBaseURL(configuration.embeddingBaseURL)
    }

    private func normalizedBaseURL(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private var privacySection: some View {
        Label {
            Text(privacyDetailKey)
                .font(.caption)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "hand.raised.fill").accessibilityHidden(true)
        }
    }

    private func settingsRow(_ key: LocalizedStringKey, text: Binding<String>) -> some View {
        GridRow { Text(key); TextField("", text: text).textFieldStyle(.roundedBorder) }
    }

    private var statusMessage: String? {
        if let productError { return productError }
        switch store.aiProviderConnectionState {
        case .idle: return nil
        case .testing: return localized("state.testing_connection")
        case .succeeded: return localized("message.ai_connection_succeeded")
        case .failed(let message): return message
        }
    }

    private var sourceDetailKey: LocalizedStringKey {
        store.snapshot.semanticIndex.inferenceSource == .pasteBuddyCloud
            ? "message.ai_cloud_source_detail"
            : "message.ai_byok_source_detail"
    }

    private var privacyDetailKey: LocalizedStringKey {
        store.snapshot.semanticIndex.inferenceSource == .pasteBuddyCloud && store.hasCloudAIAccess
            ? "message.ai_search_local_storage_boundary"
            : "message.ai_byok_privacy_boundary"
    }

    private var statusIsFailure: Bool {
        if productError != nil { return true }
        if case .failed = store.aiProviderConnectionState { return true }
        return false
    }

    private func loadProducts() async {
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            products = try await AppleStoreKitEntitlementProvider().fetchProducts().sorted {
                planOrder($0.plan) < planOrder($1.plan)
            }
            productError = nil
        } catch { productError = error.localizedDescription }
    }

    private func purchase(_ plan: ProductAccessPlan) async {
        purchasingPlan = plan
        defer { purchasingPlan = nil }
        _ = await store.purchasePersonalPlan(plan, using: AppleStoreKitEntitlementProvider())
        normalizeInferenceSource()
        await store.flushPendingSave()
    }

    private func saveBYOKConfiguration() {
        Task {
            if await store.testAndSaveBYOKConfiguration(
                configuration,
                documentAPIKey: documentAPIKey,
                embeddingAPIKey: embeddingAPIKey
            ) {
                documentAPIKey = ""
                embeddingAPIKey = ""
            }
        }
    }

    private func normalizeInferenceSource() {
        if !store.hasCloudAIAccess,
           store.snapshot.semanticIndex.inferenceSource == .pasteBuddyCloud,
           store.hasBYOKAccess {
            store.setSemanticInferenceSource(.byok)
        }
    }

    private func symbol(for plan: ProductAccessPlan) -> String {
        switch plan {
        case .byokAnnual: "key.fill"
        case .cloudMonthly: "calendar"
        case .cloudAnnual: "calendar.badge.clock"
        default: "lock.open.fill"
        }
    }

    private func planOrder(_ plan: ProductAccessPlan) -> Int {
        switch plan {
        case .byokAnnual: 0
        case .cloudMonthly: 1
        case .cloudAnnual: 2
        default: 3
        }
    }

    private func isCurrentPlan(_ plan: ProductAccessPlan) -> Bool {
        store.snapshot.entitlement.plan == plan
            && store.snapshot.entitlement.hasActivePaidAccess()
    }

    private func purchaseActionKey(for plan: ProductAccessPlan) -> LocalizedStringKey {
        isCurrentPlan(plan) ? "action.current_plan" : "action.subscribe"
    }

    private func planDetail(_ plan: ProductAccessPlan) -> LocalizedStringKey {
        switch plan {
        case .byokAnnual: "message.byok_annual_detail"
        case .cloudMonthly: "message.cloud_monthly_detail"
        case .cloudAnnual: "message.cloud_annual_detail"
        default: "message.ai_plan_comparison"
        }
    }

    private func localized(_ key: String) -> String { NSLocalizedString(key, comment: "") }
}
