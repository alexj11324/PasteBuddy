import AppKit
import Foundation
import PasteBuddyCore
import SwiftUI

struct SettingsView: View {
    @Bindable var store: PasteBuddyStore
    @Bindable var irohSync: IrohClipboardSyncService
    @Binding var panelDisplayMode: ClipboardPanelDisplayMode
    @Bindable var mcpHTTPServer: PasteBuddyMCPHTTPServer
    let onCloudSyncConfigurationChanged: (Bool) -> Void
    @State private var destructiveConfirmation: SettingsDestructiveAction?
    @State private var selectedSettingsSection: SettingsSidebarSection? = .general
    @State private var selectedMCPClient: MCPClientConfigurationTarget?
    @State private var showingMCPAdvancedSettings = false
    @State private var mcpClientCandidates: [MCPClientCandidate] = []
    @State private var isRunningMCPClientInstall = false
    @State private var mcpStatusMessage: String?
    @State private var isRestoringPurchases = false
    @State private var isPurchasingLifetimePlan = false
    @State private var lifetimeProduct: StoreProductSummary?
    @State private var subscriptionProductErrorMessage: String?
    @State private var launchAtLoginErrorMessage: String?
    @State private var retentionSliderDraft: Double?

    var body: some View {
        settingsSplitView
            .frame(minWidth: 640, idealWidth: 640, minHeight: 592, idealHeight: 592)
            .onAppear {
                applyRequestedSettingsDestination()
                reloadMCPClientCandidates()
            }
            .onChange(of: store.requestedSettingsDestination?.rawValue) { _, _ in
                applyRequestedSettingsDestination()
            }
            .confirmationDialog(
                destructiveConfirmation?.title ?? NSLocalizedString("label.confirm_action", comment: ""),
                isPresented: isShowingDestructiveConfirmation,
                titleVisibility: .visible
            ) {
                if let destructiveConfirmation {
                    Button(destructiveConfirmation.confirmationButtonTitle, role: .destructive) {
                        performDestructiveAction(destructiveConfirmation)
                        self.destructiveConfirmation = nil
                    }
                }
                Button("action.cancel", role: .cancel) {
                    destructiveConfirmation = nil
                }
            } message: {
                if let destructiveConfirmation {
                    Text(destructiveConfirmation.message)
                }
            }
            .sheet(item: $selectedMCPClient) { target in
                MCPClientConfigurationSheet(
                    guide: mcpClientGuide(for: target),
                    isRunningInstallation: isRunningMCPClientInstall,
                    statusMessage: mcpStatusMessage,
                    onRunInstallationCommand: {
                        runMCPInstallationCommand(for: target)
                    },
                    onOpenInstallationURL: {
                        openMCPInstallationURL(for: target)
                    },
                    onCopyConfiguration: {
                        copyMCPConfiguration(for: target)
                    },
                    onCopyCommand: {
                        copyMCPServerCommand(for: target)
                    },
                    onCopyInstallationCommand: {
                        copyMCPInstallationCommand(for: target)
                    },
                    onCopyInstallationURL: {
                        copyMCPInstallationURL(for: target)
                    }
                )
            }
            .sheet(isPresented: $showingMCPAdvancedSettings) {
                MCPAdvancedSettingsSheet(store: store)
            }
    }

    private var settingsSplitView: some View {
        NavigationSplitView {
            List(SettingsSidebarSection.allCases, selection: $selectedSettingsSection) { section in
                SettingsSidebarLabel(section: section)
                .tag(section)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 200)
            .navigationTitle("label.settings")
        } detail: {
            selectedSettingsDetail
                .navigationTitle(effectiveSettingsSection.titleKey)
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var selectedSettingsDetail: some View {
        switch effectiveSettingsSection {
        case .general:
            generalSettings
        case .privacy:
            privacySettings
        case .shortcuts:
            shortcutSettings
        case .integrations:
            integrationSettings
        case .subscription:
            subscriptionSettings
        }
    }

    private var effectiveSettingsSection: SettingsSidebarSection {
        selectedSettingsSection ?? .general
    }

    private func applyRequestedSettingsDestination() {
        guard let destination = store.requestedSettingsDestination else {
            selectedSettingsSection = selectedSettingsSection ?? .general
            return
        }
        selectedSettingsSection = SettingsSidebarSection(destination)
    }

    private var generalSettings: some View {
        Form {
            Section {
                Toggle("label.launch_at_login", isOn: launchAtLoginBinding)
                    .disabled(!LaunchAtLoginService.isAvailable)
                if let launchAtLoginErrorMessage {
                    Text(launchAtLoginErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("label.background_running", isOn: backgroundRunningBinding)
                Toggle("label.enable_icloud_sync", isOn: cloudSyncBinding)
                if store.snapshot.sync.isCloudSyncEnabled,
                   let status = store.snapshot.sync.lastSyncStatusMessage ?? store.lastErrorMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("label.sound_effects", isOn: soundEffectsBinding)
            }

            Section("label.paste_items") {
                Picker("label.paste_destination", selection: pasteDestinationBinding) {
                    Text("label.paste_to_current_application").tag(PasteDestination.activeApplication)
                    Text("label.paste_to_clipboard").tag(PasteDestination.clipboard)
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)

                Text("message.direct_paste_to_current_application")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(
                    "action.paste_as_plain_text_by",
                    isOn: Binding(
                        get: { store.snapshot.paste.alwaysPasteAsPlainText },
                        set: { store.setAlwaysPasteAsPlainText($0) }
                    )
                )
            }

            Section("label.keep_history") {
                retentionSlider

                Picker("label.panel_style", selection: $panelDisplayMode) {
                    Text("label.clipboard_shelf").tag(ClipboardPanelDisplayMode.shelf)
                    Text("label.side_panel").tag(ClipboardPanelDisplayMode.sidePanel)
                }
                .pickerStyle(.radioGroup)
            }

            Section("label.iroh_clipboard_sync") {
                LabeledContent("label.status") {
                    Text(irohStatusText)
                        .foregroundStyle(irohStatusColor)
                }
                TextField("label.peer_endpoint_id", text: $irohSync.peerEndpointId)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scenePadding()
    }

    @ViewBuilder
    private var retentionSlider: some View {
        if #available(macOS 26.0, *) {
            Slider(
                value: retentionSliderBinding,
                in: 0...4,
                label: { EmptyView() },
                currentValueLabel: { Text(retentionOption.localizedTitle) },
                ticks: {
                    SliderTick("label.day", 0)
                    SliderTick("label.week", 1)
                    SliderTick("label.month", 2)
                    SliderTick("label.year", 3)
                    SliderTick("label.forever", 4)
                },
                onEditingChanged: retentionSliderEditingChanged
            )
            .frame(maxWidth: .infinity)
            .accessibilityLabel(Text("label.keep_history"))
            .accessibilityValue(Text(retentionOption.localizedTitle))
        } else {
            VStack(spacing: 6) {
                Slider(
                    value: retentionSliderBinding,
                    in: 0...4,
                    onEditingChanged: retentionSliderEditingChanged
                )
                HStack {
                    ForEach(SettingsRetentionAnchor.allCases) { anchor in
                        Text(anchor.titleKey)
                            .frame(maxWidth: .infinity, alignment: anchor.alignment)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(retentionOption.localizedTitle)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel(Text("label.keep_history"))
            .accessibilityValue(Text(retentionOption.localizedTitle))
        }
    }

    private var privacySettings: some View {
        Form {
            Section {
                Toggle(isOn: showDuringScreenSharingBinding) {
                    SettingsToggleLabel(
                        titleKey: "label.show_during_screen_sharing",
                        detailKey: "message.show_during_screen_sharing"
                    )
                }
                Toggle(isOn: generateLinkPreviewsBinding) {
                    SettingsToggleLabel(
                        titleKey: "label.generate_link_previews",
                        detailKey: "message.generate_link_previews"
                    )
                }
            }

            Section("label.content_filtering") {
                Toggle(
                    isOn: Binding(
                        get: { store.snapshot.privacy.blockLikelySensitiveText },
                        set: { _ in store.toggleSensitiveTextBlocking() }
                    )
                ) {
                    SettingsToggleLabel(
                        titleKey: "label.ignore_sensitive_content",
                        detailKey: "message.ignore_sensitive_content"
                    )
                }
                Toggle(isOn: ignoreTransientContentBinding) {
                    SettingsToggleLabel(
                        titleKey: "label.ignore_transient_content",
                        detailKey: "message.ignore_transient_content"
                    )
                }
            }

            Section {
                SettingsPrivacyRules(store: store)
            }

            Section("label.capture_and_privacy") {
                Toggle("label.capture_enabled", isOn: backgroundRunningBinding)
                Toggle("label.capture_text", isOn: captureTextBinding)
                Toggle("label.capture_links", isOn: captureURLsBinding)
                Toggle("label.capture_files", isOn: captureFilesBinding)
                Toggle("label.capture_images", isOn: captureImagesBinding)
                Toggle("label.run_local_ocr_after_image_capture", isOn: ocrBinding)
                    .disabled(!store.snapshot.privacy.captureImages)
            }

            Section("label.storage_security") {
                Toggle(
                    "label.require_touch_id_for_history",
                    isOn: Binding(
                        get: { store.snapshot.security.requiresBiometricUnlock },
                        set: { store.setBiometricHistoryLockEnabled($0) }
                    )
                )
                LabeledContent("label.storage_usage") {
                    Text(localized("format.items", store.storageUsageReport.itemCount))
                    Text(ByteCountFormatter.string(
                        fromByteCount: Int64(store.storageUsageReport.estimatedBytes),
                        countStyle: .file
                    ))
                    .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scenePadding()
    }

    private var shortcutSettings: some View {
        Form {
            Section {
                SettingsShortcutRow(store: store, titleKey: "action.launch_paste", action: .showHidePanel)
                SettingsShortcutRow(store: store, titleKey: "label.activate_paste_stack", action: .activatePasteStack)
            }
            Section {
                SettingsShortcutRow(store: store, titleKey: "label.show_next_pinboard", action: .showNextPinboard)
                SettingsShortcutRow(store: store, titleKey: "label.show_previous_pinboard", action: .showPreviousPinboard)
            }
            Section {
                SettingsModifierShortcutRow(store: store, titleKey: "label.quick_paste", plainText: false)
                SettingsModifierShortcutRow(store: store, titleKey: "label.plain_text_mode", plainText: true)
            }
            Section {
                HStack {
                    Spacer()
                    Button("action.reset_all_shortcuts") {
                        destructiveConfirmation = .resetShortcuts
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scenePadding()
    }

    private var integrationSettings: some View {
        Form {
            Section {
                Toggle(
                    isOn: Binding(
                        get: { store.snapshot.mcp.isServerEnabled },
                        set: { store.setMCPServerEnabled($0) }
                    )
                ) {
                    SettingsToggleLabel(
                        titleKey: "label.enable_mcp",
                        detailKey: "message.mcp_local_connection"
                    )
                }
                Label(
                    mcpHTTPServer.status == .listening
                        ? "label.mcp_server_enabled"
                        : "label.mcp_server_disabled",
                    systemImage: "circle.fill"
                )
                    .font(.caption)
                    .foregroundStyle(mcpHTTPServer.status == .listening ? .green : .secondary)
                    .textSelection(.enabled)
                Text(PasteBuddyMCPHTTPServer.endpoint)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                if case .failed(let message) = mcpHTTPServer.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("label.connected_ai_tools") {
                if let latestAccess = mcpHTTPServer.lastClientActivityAt
                    ?? store.snapshot.mcp.accessLog.first?.accessedAt {
                    LabeledContent("label.local_mcp_client") {
                        Text(latestAccess.formatted(date: .abbreviated, time: .shortened))
                    }
                } else {
                    Text("message.no_connected_ai_tools_yet")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                Menu {
                    ForEach(mcpClientCandidates) { candidate in
                        Button(candidate.displayName) {
                            selectedMCPClient = candidate.target
                        }
                    }
                    Divider()
                    Button("action.custom_ai_tool") {
                        selectedMCPClient = .custom
                    }
                    Divider()
                    Button("action.agent_privacy_and_access") {
                        showingMCPAdvancedSettings = true
                    }
                } label: {
                    Text("action.connect_ai_tool")
                }
                .disabled(mcpHTTPServer.configurationToken == nil)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scenePadding()
    }

    private var subscriptionSettings: some View {
        VStack(spacing: 12) {
            Text("message.lifetime_productivity")
                .font(.system(size: 28, weight: .bold))
            Text(subscriptionStatusKey)
                .foregroundStyle(.secondary)
            Button("action.get_started") {
                isPurchasingLifetimePlan = true
                Task {
                    _ = await store.purchasePersonalPlan(
                        .lifetime,
                        using: AppleStoreKitEntitlementProvider()
                    )
                    await store.flushPendingSave()
                    isPurchasingLifetimePlan = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                isPurchasingLifetimePlan
                    || lifetimeProduct == nil
                    || (store.snapshot.entitlement.plan == .lifetime
                        && store.snapshot.entitlement.status == .active)
            )
            Button("action.restore_purchases") {
                isRestoringPurchases = true
                Task {
                    _ = await store.restorePurchases(using: AppleStoreKitEntitlementProvider())
                    await store.flushPendingSave()
                    isRestoringPurchases = false
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(isRestoringPurchases)
            if let statusMessage = restoreStatusMessage ?? subscriptionProductErrorMessage ?? store.lastErrorMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 76)
        .task {
            await loadLifetimeProduct()
        }
    }

    private func loadLifetimeProduct() async {
        do {
            lifetimeProduct = try await AppleStoreKitEntitlementProvider()
                .fetchProducts()
                .first(where: { $0.plan == .lifetime })
            subscriptionProductErrorMessage = nil
        } catch {
            lifetimeProduct = nil
            subscriptionProductErrorMessage = error.localizedDescription
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { store.snapshot.general.launchAtLoginEnabled },
            set: { isEnabled in
                store.setLaunchAtLoginEnabled(isEnabled)
                launchAtLoginErrorMessage = store.snapshot.general.launchAtLoginEnabled == isEnabled
                    ? nil
                    : store.lastErrorMessage
            }
        )
    }

    private var backgroundRunningBinding: Binding<Bool> {
        Binding(
            get: { !store.isCapturePaused },
            set: { $0 ? store.resumeCapture() : store.pauseCaptureIndefinitely() }
        )
    }

    private var cloudSyncBinding: Binding<Bool> {
        Binding(
            get: { store.snapshot.sync.isCloudSyncEnabled },
            set: { isEnabled in
                if isEnabled {
                    store.configureCloudKitSync(
                        containerIdentifier: store.snapshot.sync.cloudKitContainerIdentifier
                            ?? "iCloud.com.alexjiang.PasteBuddy",
                        capabilityConfigured: Bundle.main.object(
                            forInfoDictionaryKey: "PasteBuddyCloudKitCapabilityConfigured"
                        ) as? Bool == true
                    )
                } else {
                    store.disableCloudSync()
                }
                onCloudSyncConfigurationChanged(isEnabled)
            }
        )
    }

    private var captureTextBinding: Binding<Bool> {
        Binding(get: { store.snapshot.privacy.captureText }, set: { _ in store.toggleTextCapture() })
    }

    private var captureURLsBinding: Binding<Bool> {
        Binding(get: { store.snapshot.privacy.captureURLs }, set: { _ in store.toggleURLCapture() })
    }

    private var captureFilesBinding: Binding<Bool> {
        Binding(get: { store.snapshot.privacy.captureFiles }, set: { _ in store.toggleFileCapture() })
    }

    private var captureImagesBinding: Binding<Bool> {
        Binding(get: { store.snapshot.privacy.captureImages }, set: { _ in store.toggleImageCapture() })
    }

    private var ocrBinding: Binding<Bool> {
        Binding(
            get: { store.snapshot.privacy.runLocalOCRAfterImageCapture },
            set: { _ in store.toggleOCR() }
        )
    }

    private var retentionSliderBinding: Binding<Double> {
        Binding(
            get: { retentionSliderDraft ?? retentionOption.position },
            set: { value in
                retentionSliderDraft = SettingsRetentionOption.closest(toPosition: value).position
            }
        )
    }

    private var retentionOption: SettingsRetentionOption {
        if let retentionSliderDraft {
            return SettingsRetentionOption.closest(toPosition: retentionSliderDraft)
        }
        return SettingsRetentionOption.closest(toDays: store.snapshot.storage.retentionDays)
    }

    private func retentionSliderEditingChanged(_ isEditing: Bool) {
        if isEditing {
            retentionSliderDraft = retentionOption.position
        } else if let retentionSliderDraft {
            let option = SettingsRetentionOption.closest(toPosition: retentionSliderDraft)
            self.retentionSliderDraft = nil
            requestRetentionDaysChange(option.days)
        }
    }

    private var pasteDestinationBinding: Binding<PasteDestination> {
        Binding(
            get: { store.snapshot.settingsBehavior.pasteDestination },
            set: { store.setPasteDestination($0) }
        )
    }

    private var soundEffectsBinding: Binding<Bool> {
        Binding(
            get: { store.snapshot.settingsBehavior.soundEffectsEnabled },
            set: { store.setSoundEffectsEnabled($0) }
        )
    }

    private var showDuringScreenSharingBinding: Binding<Bool> {
        Binding(
            get: { store.snapshot.settingsBehavior.showDuringScreenSharing },
            set: { store.setShowDuringScreenSharing($0) }
        )
    }

    private var generateLinkPreviewsBinding: Binding<Bool> {
        Binding(
            get: { store.snapshot.settingsBehavior.generateLinkPreviews },
            set: { store.setGenerateLinkPreviews($0) }
        )
    }

    private var ignoreTransientContentBinding: Binding<Bool> {
        Binding(
            get: { store.snapshot.settingsBehavior.ignoreTransientContent },
            set: { store.setIgnoreTransientContent($0) }
        )
    }

    private var subscriptionStatusKey: LocalizedStringKey {
        store.snapshot.entitlement.plan.isPersonalPaidPlan
            ? "message.subscription_active"
            : "message.not_subscribed"
    }

    private var isShowingDestructiveConfirmation: Binding<Bool> {
        Binding(
            get: { destructiveConfirmation != nil },
            set: { isPresented in
                if !isPresented {
                    destructiveConfirmation = nil
                }
            }
        )
    }

    private func performDestructiveAction(_ action: SettingsDestructiveAction) {
        switch action {
        case .reduceRetentionDays(let days):
            store.updateRetentionDays(days)
        case .resetShortcuts:
            store.resetShortcutConfiguration()
        }
    }

    private func requestRetentionDaysChange(_ value: Int) {
        let value = StorageConfiguration.clampRetentionDays(value)
        let current = store.snapshot.storage.retentionDays
        let removesHistory = value != 0 && (current == 0 || value < current)
        if removesHistory {
            destructiveConfirmation = .reduceRetentionDays(value)
        } else {
            store.updateRetentionDays(value)
        }
    }

    private var irohStatusText: String {
        switch irohSync.connectionState {
        case .idle:
            localized("state.off")
        case .binding:
            localized("state.binding")
        case .ready:
            localized("state.ready")
        case .connecting:
            localized("state.connecting")
        case .connected(let peerShortId):
            localized("format.connected_to_peer", peerShortId)
        case .failed(let message):
            message
        }
    }

    private var irohStatusColor: Color {
        switch irohSync.connectionState {
        case .connected:
            .green
        case .failed:
            .orange
        default:
            .secondary
        }
    }

    private func reloadMCPClientCandidates() {
        mcpClientCandidates = MCPClientDetector().candidates(
            applications: InstalledApplicationCatalog().applications()
        )
    }

    private func mcpClientGuide(for target: MCPClientConfigurationTarget) -> MCPClientConfigurationGuide {
        if FileManager.default.isExecutableFile(atPath: packagedMCPExecutablePath) {
            return MCPClientConfigurationGuideBuilder.packagedGuide(
                for: target,
                executablePath: packagedMCPExecutablePath,
                authenticationToken: mcpHTTPServer.configurationToken
            )
        }
        return MCPClientConfigurationGuideBuilder.developmentGuide(
            for: target,
            packagePath: developmentPackagePath,
            authenticationToken: mcpHTTPServer.configurationToken
        )
    }

    private var packagedMCPExecutablePath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/PasteBuddyMCP")
            .path
    }

    private var developmentPackagePath: String {
        let sourcePath = #filePath
        if let range = sourcePath.range(of: "/Sources/PasteBuddy/") {
            return String(sourcePath[..<range.lowerBound])
        }
        return FileManager.default.currentDirectoryPath
    }

    private func copyMCPConfiguration(for target: MCPClientConfigurationTarget) {
        let guide = mcpClientGuide(for: target)
        copyToPasteboard(guide.configurationSnippet)
        mcpStatusMessage = localized("format.copied_mcp_configuration_for", target.displayName)
    }

    private func copyMCPServerCommand(for target: MCPClientConfigurationTarget) {
        let guide = mcpClientGuide(for: target)
        copyToPasteboard(commandSummary(for: guide))
        mcpStatusMessage = localized("format.copied_mcp_server_command_for", target.displayName)
    }

    private func runMCPInstallationCommand(for target: MCPClientConfigurationTarget) {
        let guide = mcpClientGuide(for: target)
        guard let parts = guide.installationCommandParts, !parts.isEmpty else { return }
        isRunningMCPClientInstall = true
        mcpStatusMessage = localized("format.installing_mcp_client", target.displayName)

        let resolvedParts = MCPClientDetector().resolvedCommandParts(parts, for: target)
        let searchPath = MCPClientDetector().shellSearchPath
        Task {
            let result = await MCPClientCommandRunner.run(parts: resolvedParts, searchPath: searchPath)
            await MainActor.run {
                isRunningMCPClientInstall = false
                if result.exitCode == 0 {
                    mcpStatusMessage = localized("format.added_mcp_client", target.displayName)
                } else {
                    let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    mcpStatusMessage = localized(
                        "format.mcp_client_install_failed",
                        target.displayName,
                        detail.isEmpty ? localized("label.unknown_error") : detail
                    )
                }
            }
        }
    }

    private func openMCPInstallationURL(for target: MCPClientConfigurationTarget) {
        guard let urlString = mcpClientGuide(for: target).installationURL,
              let url = URL(string: urlString) else {
            return
        }
        NSWorkspace.shared.open(url)
        mcpStatusMessage = localized("format.opened_mcp_install_link_for", target.displayName)
    }

    private func copyMCPInstallationCommand(for target: MCPClientConfigurationTarget) {
        guard let command = mcpClientGuide(for: target).installationCommand else { return }
        copyToPasteboard(command)
        mcpStatusMessage = localized("format.copied_mcp_install_command_for", target.displayName)
    }

    private func copyMCPInstallationURL(for target: MCPClientConfigurationTarget) {
        guard let url = mcpClientGuide(for: target).installationURL else { return }
        copyToPasteboard(url)
        mcpStatusMessage = localized("format.copied_mcp_install_link_for", target.displayName)
    }

    private func commandSummary(for guide: MCPClientConfigurationGuide) -> String {
        ([guide.command] + guide.arguments).joined(separator: " ")
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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

    private var restoreStatusMessage: String? {
        if isRestoringPurchases {
            return localized("state.restoring_purchases")
        }
        return switch store.snapshot.entitlement.restoreState {
        case .notStarted:
            nil
        case .inProgress:
            localized("state.restoring_purchases")
        case .restored:
            store.lastErrorMessage ?? localized("state.purchases_restored")
        case .failed(_, let message):
            message
        }
    }

}

private struct MCPAdvancedSettingsSheet: View {
    @Bindable var store: PasteBuddyStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("action.agent_privacy_and_access") {
                    ForEach(MCPToolName.allCases) { tool in
                        Toggle(
                            tool.displayName,
                            isOn: Binding(
                                get: { store.snapshot.mcp.isToolEnabled(tool) },
                                set: { store.setMCPTool(tool, enabled: $0) }
                            )
                        )
                    }
                    Text("message.retrieve_item_requires_explicit_mcp_opt_in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("action.revoke_mcp_access", role: .destructive) {
                        store.revokeMCPAccess()
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("action.agent_privacy_and_access")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.done") { dismiss() }
                }
            }
        }
        .frame(width: 520, height: 420)
    }
}

private struct SettingsSidebarLabel: View {
    let section: SettingsSidebarSection

    var body: some View {
        Label {
            Text(section.titleKey)
        } icon: {
            if section == .integrations {
                MCPBrandIcon()
            } else if let systemImageName = section.systemImageName {
                Image(systemName: systemImageName)
                    .accessibilityHidden(true)
            }
        }
        .font(.system(size: 13))
        .frame(height: 32)
        .accessibilityLabel(Text(section.titleKey))
    }
}

private struct MCPBrandIcon: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Image("mcp-brand-base", bundle: .module)
                    .resizable()
                    .renderingMode(.template)
                Image("mcp-brand-inset", bundle: .module)
                    .resizable()
                    .renderingMode(.template)
                    .frame(
                        width: geometry.size.width * 0.665,
                        height: geometry.size.height * 0.598
                    )
                    .offset(
                        x: geometry.size.width * 0.011,
                        y: geometry.size.height * -0.062
                    )
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

private struct SettingsToggleLabel: View {
    let titleKey: LocalizedStringKey
    let detailKey: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(titleKey)
            Text(detailKey)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SettingsShortcutRow: View {
    @Bindable var store: PasteBuddyStore
    let titleKey: LocalizedStringKey
    let action: ShortcutAction
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent {
                ShortcutCaptureButton(
                    displayName: currentBinding.isEnabled ? currentBinding.displayName : localized("label.not_set"),
                    soundEffectsEnabled: store.snapshot.settingsBehavior.soundEffectsEnabled,
                    onClear: currentBinding.isEnabled ? { store.clearShortcutBinding(action) } : nil
                ) { shortcut in
                    validationMessage = store.setShortcutBinding(
                        action,
                        key: shortcut.key,
                        modifiers: shortcut.modifiers,
                        keyCode: shortcut.keyCode
                    ) ? nil : localized("message.shortcut_binding_rejected")
                }
            } label: {
                Text(titleKey)
            }
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                .foregroundStyle(.red)
            }
        }
    }

    private var currentBinding: ShortcutBinding {
        store.snapshot.shortcuts.binding(for: action)
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}

private struct SettingsModifierShortcutRow: View {
    @Bindable var store: PasteBuddyStore
    let titleKey: LocalizedStringKey
    let plainText: Bool
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent {
                ShortcutCaptureButton(
                    displayName: displayName,
                    soundEffectsEnabled: store.snapshot.settingsBehavior.soundEffectsEnabled
                ) { shortcut in
                    validationMessage = store.setQuickPasteModifiers(
                        shortcut.modifiers,
                        plainText: plainText
                    ) ? nil : NSLocalizedString("message.shortcut_binding_rejected", comment: "")
                }
            } label: {
                Text(titleKey)
            }
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var displayName: String {
        let modifiers = plainText
            ? store.snapshot.shortcuts.plainTextQuickPasteModifiers
            : store.snapshot.shortcuts.quickPasteModifiers
        let normalized = ShortcutBinding.normalizedModifiers(modifiers)
        guard !normalized.isEmpty else {
            return NSLocalizedString("label.digits_only", comment: "")
        }
        return normalized.reversed().map(\.displayName).joined()
    }
}

private enum SettingsRetentionAnchor: Int, CaseIterable, Identifiable {
    case day
    case week
    case month
    case year
    case forever

    var id: Int { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .day: "label.day"
        case .week: "label.week"
        case .month: "label.month"
        case .year: "label.year"
        case .forever: "label.forever"
        }
    }

    var alignment: Alignment {
        switch self {
        case .day: .leading
        case .forever: .trailing
        case .week, .month, .year: .center
        }
    }

}

struct SettingsRetentionOption: Equatable {
    let days: Int
    let position: Double
    private let components: DateComponents?

    static let all: [Self] =
        (1...6).map { option(days: $0, position: Double($0 - 1) / 6, day: $0) }
        + (1...3).map { option(days: $0 * 7, position: 1 + Double($0 - 1) / 3, week: $0) }
        + (1...11).map { option(days: $0 * 30, position: 2 + Double($0 - 1) / 11, month: $0) }
        + (1...10).map { option(days: $0 * 365, position: 3 + Double($0 - 1) / 10, year: $0) }
        + [Self(days: 0, position: 4, components: nil)]

    var localizedTitle: String {
        guard let components else {
            return NSLocalizedString("label.forever", comment: "")
        }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        return formatter.string(from: components) ?? NSLocalizedString("label.forever", comment: "")
    }

    static func closest(toDays days: Int) -> Self {
        if days == 0 { return all[all.count - 1] }
        return all.dropLast().min { abs($0.days - days) < abs($1.days - days) } ?? all[0]
    }

    static func closest(toPosition position: Double) -> Self {
        all.min { abs($0.position - position) < abs($1.position - position) } ?? all[0]
    }

    private static func option(
        days: Int,
        position: Double,
        day: Int? = nil,
        week: Int? = nil,
        month: Int? = nil,
        year: Int? = nil
    ) -> Self {
        Self(
            days: days,
            position: position,
            components: DateComponents(year: year, month: month, day: day, weekOfMonth: week)
        )
    }
}

private struct MCPClientConfigurationSheet: View {
    var guide: MCPClientConfigurationGuide
    var isRunningInstallation: Bool
    var statusMessage: String?
    var onRunInstallationCommand: () -> Void
    var onOpenInstallationURL: () -> Void
    var onCopyConfiguration: () -> Void
    var onCopyCommand: () -> Void
    var onCopyInstallationCommand: () -> Void
    var onCopyInstallationURL: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(guide.target.displayName, systemImage: guide.target.systemImageName)
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("action.close") {
                    dismiss()
                }
            }

            Text("message.paste_mcp_config_into_ai_tool")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("label.configuration_location") {
                    Text(guide.configurationHint)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }

                LabeledContent("label.server_command") {
                    Text(commandSummary)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            if guide.installationCommand != nil || guide.installationURL != nil {
                Text("label.client_install")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    if let installationCommand = guide.installationCommand {
                        LabeledContent("label.install_command") {
                            Text(installationCommand)
                                .font(.caption.monospaced())
                                .lineLimit(3)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }

                    if let installationURL = guide.installationURL {
                        LabeledContent("label.install_link") {
                            Text(installationURL)
                                .font(.caption.monospaced())
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                }

                HStack {
                    if guide.installationCommandParts != nil {
                        Button {
                            onRunInstallationCommand()
                        } label: {
                            Text(
                                isRunningInstallation
                                    ? LocalizedStringKey("state.installing")
                                    : LocalizedStringKey("action.run_install_command")
                            )
                        }
                        .disabled(isRunningInstallation)
                        .keyboardShortcut(.defaultAction)
                    }

                    if guide.installationURL != nil {
                        Button("action.open_install_link") {
                            onOpenInstallationURL()
                        }
                    }

                    Spacer()
                }
            }

            Text("label.import_configuration")
                .font(.headline)

            TextEditor(text: .constant(guide.configurationSnippet))
                .font(.caption.monospaced())
            .frame(minHeight: 160)

            HStack {
                Button("action.copy_import_configuration") {
                    onCopyConfiguration()
                }
                .keyboardShortcut(guide.installationCommandParts == nil ? .defaultAction : nil)

                Button("action.copy_server_command") {
                    onCopyCommand()
                }

                if guide.installationCommand != nil {
                    Button("action.copy_install_command") {
                        onCopyInstallationCommand()
                    }
                }

                if guide.installationURL != nil {
                    Button("action.copy_install_link") {
                        onCopyInstallationURL()
                    }
                }

                Spacer()
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 600)
        .frame(minHeight: 500)
    }

    private var commandSummary: String {
        ([guide.command] + guide.arguments).joined(separator: " ")
    }
}

private enum SettingsPrivacyRuleMode: String, CaseIterable, Identifiable {
    case applications
    case otherRules

    var id: String { rawValue }
}

private struct SettingsPrivacyRules: View {
    @Bindable var store: PasteBuddyStore
    @State private var applications: [InstalledApplication] = []
    @State private var selectedRowID: String?
    @State private var showingApplicationPicker = false
    @State private var mode: SettingsPrivacyRuleMode = .applications

    var body: some View {
        VStack(spacing: 12) {
            Picker("label.ignore_applications", selection: $mode) {
                Text("label.by_app").tag(SettingsPrivacyRuleMode.applications)
                Text("label.other_rules").tag(SettingsPrivacyRuleMode.otherRules)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 258)

            switch mode {
            case .applications:
                applicationRules
            case .otherRules:
                otherRules
            }
        }
        .onAppear(perform: loadApplications)
        .sheet(isPresented: $showingApplicationPicker) {
            InstalledApplicationPickerSheet { application in
                store.excludeApplication(
                    named: application.displayName,
                    bundleIdentifier: application.bundleIdentifier
                )
                selectedRowID = nil
                loadApplications()
            }
        }
    }

    private var applicationRules: some View {
        VStack(spacing: 10) {
            Text("message.ignore_applications")
                .font(.headline)

            List(selection: $selectedRowID) {
                ForEach(excludedRows) { row in
                    ExcludedApplicationRowView(row: row)
                        .tag(row.id)
                }
            }
            .listStyle(.bordered)
            .frame(height: 150)

            HStack(spacing: 8) {
                Button {
                    showingApplicationPicker = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("action.add_app")

                Button {
                    removeSelectedRow()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selectedRowID == nil)
                .accessibilityLabel("action.remove")
                Spacer()
            }
        }
    }

    private var otherRules: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("label.ignore_remote_clipboard", isOn: behaviorBinding(
                get: \.ignoreRemoteClipboardContent,
                set: store.setIgnoreRemoteClipboardContent
            ))
            Toggle("label.ignore_concealed_clipboard", isOn: behaviorBinding(
                get: \.ignoreConcealedContent,
                set: store.setIgnoreConcealedContent
            ))
            Toggle("label.ignore_auto_generated_clipboard", isOn: behaviorBinding(
                get: \.ignoreAutoGeneratedContent,
                set: store.setIgnoreAutoGeneratedContent
            ))
            Toggle("label.ignore_whitespace_clipboard", isOn: behaviorBinding(
                get: \.ignoreWhitespaceOnlyContent,
                set: store.setIgnoreWhitespaceOnlyContent
            ))
            Toggle("label.flatten_large_excel_clipboard", isOn: behaviorBinding(
                get: \.convertLargeExcelContentToPlainText,
                set: store.setConvertLargeExcelContentToPlainText
            ))
            HStack {
                Text("label.ignore_clipboard_larger_than")
                TextField(
                    "",
                    value: Binding(
                        get: { store.snapshot.settingsBehavior.maximumClipboardSizeMegabytes },
                        set: { store.setMaximumClipboardSizeMegabytes($0) }
                    ),
                    format: .number.precision(.fractionLength(1))
                )
                .frame(width: 76)
                .accessibilityLabel(Text("label.ignore_clipboard_larger_than"))
                Text("label.megabytes")
            }
            Text("message.zero_disables_size_filter")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func behaviorBinding(
        get: KeyPath<SettingsBehaviorConfiguration, Bool>,
        set: @escaping (Bool) -> Void
    ) -> Binding<Bool> {
        Binding(
            get: { store.snapshot.settingsBehavior[keyPath: get] },
            set: { value in set(value) }
        )
    }

    private var excludedRows: [ExcludedApplicationListRow] {
        var unmatchedNames = store.snapshot.privacy.excludedApplicationNames
        var unmatchedBundleIdentifiers = store.snapshot.privacy.excludedBundleIdentifiers
        var rows: [ExcludedApplicationListRow] = []

        for application in applications {
            let matchedName = unmatchedNames.remove(application.displayName)
            let matchedBundleIdentifier = application.bundleIdentifier.flatMap {
                unmatchedBundleIdentifiers.remove($0)
            }

            if matchedName != nil || matchedBundleIdentifier != nil {
                rows.append(
                    ExcludedApplicationListRow(
                        application: application,
                        name: matchedName,
                        bundleIdentifier: matchedBundleIdentifier
                    )
                )
            }
        }

        rows += unmatchedNames.map {
            ExcludedApplicationListRow(application: nil, name: $0, bundleIdentifier: nil)
        }
        rows += unmatchedBundleIdentifiers.map {
            ExcludedApplicationListRow(application: nil, name: nil, bundleIdentifier: $0)
        }

        return rows.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private func loadApplications() {
        applications = InstalledApplicationCatalog().applications()
    }

    private func removeSelectedRow() {
        guard let selectedRowID,
              let row = excludedRows.first(where: { $0.id == selectedRowID }) else {
            return
        }
        if let name = row.name {
            store.removeExcludedApplication(name)
        }
        if let bundleIdentifier = row.bundleIdentifier {
            store.removeExcludedBundleIdentifier(bundleIdentifier)
        }
        self.selectedRowID = nil
    }
}

private struct InstalledApplicationPickerSheet: View {
    var requiresBundleIdentifier = false
    let onSelect: (InstalledApplication) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var applications: [InstalledApplication] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("label.installed_apps")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("action.close") {
                    dismiss()
                }
            }

            TextField("label.search_apps", text: $searchText)
                .textFieldStyle(.roundedBorder)

            ZStack {
                List(filteredApplications) { application in
                    Button {
                        guard !requiresBundleIdentifier || application.bundleIdentifier != nil else {
                            return
                        }
                        onSelect(application)
                        dismiss()
                    } label: {
                        InstalledApplicationPickerRow(application: application)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(requiresBundleIdentifier && application.bundleIdentifier == nil)
                }
                .listStyle(.plain)

                if filteredApplications.isEmpty {
                    Text(applications.isEmpty ? "message.no_installed_apps_found" : "message.no_matching_apps")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .frame(width: 560, height: 560)
        .onAppear {
            if applications.isEmpty {
                applications = InstalledApplicationCatalog().applications()
            }
        }
    }

    private var filteredApplications: [InstalledApplication] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return applications }
        return applications.filter { application in
            application.displayName.localizedCaseInsensitiveContains(query)
                || application.bundleIdentifier?.localizedCaseInsensitiveContains(query) == true
        }
    }
}

private struct InstalledApplicationPickerRow: View {
    var application: InstalledApplication

    var body: some View {
        HStack(spacing: 10) {
            InstalledApplicationIcon(application: application)
            VStack(alignment: .leading, spacing: 2) {
                Text(application.displayName)
                if let bundleIdentifier = application.bundleIdentifier {
                    Text(bundleIdentifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ExcludedApplicationRowView: View {
    var row: ExcludedApplicationListRow

    var body: some View {
        HStack(spacing: 10) {
            InstalledApplicationIcon(application: row.application)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName)
                if let detail = row.detailText {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct InstalledApplicationIcon: View {
    var application: InstalledApplication?

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .frame(width: 24, height: 24)
    }

    private var icon: NSImage {
        let image = application
            .map { NSWorkspace.shared.icon(forFile: $0.url.path) }
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
        image.size = NSSize(width: 24, height: 24)
        return image
    }
}

private struct ExcludedApplicationListRow: Identifiable, Hashable {
    var application: InstalledApplication?
    var name: String?
    var bundleIdentifier: String?

    var id: String {
        [
            name.map { "name:\($0)" },
            bundleIdentifier.map { "bundle:\($0)" },
            application.map { "path:\($0.url.standardizedFileURL.path)" }
        ]
            .compactMap(\.self)
            .joined(separator: "|")
    }

    var displayName: String {
        application?.displayName ?? name ?? bundleIdentifier ?? ""
    }

    var detailText: String? {
        bundleIdentifier ?? application?.bundleIdentifier
    }
}

private enum SettingsSidebarSection: String, CaseIterable, Identifiable, Hashable {
    case general
    case privacy
    case shortcuts
    case integrations
    case subscription

    init(_ destination: MacSettingsDestination) {
        switch destination {
        case .general:
            self = .general
        case .privacy:
            self = .privacy
        case .storage:
            self = .privacy
        case .shortcuts:
            self = .shortcuts
        case .sync:
            self = .integrations
        }
    }

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .general:
            "label.general"
        case .privacy:
            "label.privacy"
        case .shortcuts:
            "label.keyboard_shortcuts"
        case .integrations:
            "label.mcp_ai_tools"
        case .subscription:
            "label.subscription"
        }
    }

    var systemImageName: String? {
        switch self {
        case .general:
            "gearshape"
        case .privacy:
            "hand.raised"
        case .shortcuts:
            "keyboard"
        case .integrations:
            nil
        case .subscription:
            "shield"
        }
    }
}

private enum SettingsDestructiveAction {
    case reduceRetentionDays(Int)
    case resetShortcuts

    var title: String {
        switch self {
        case .reduceRetentionDays:
            NSLocalizedString("dialog.reduce_history_retention", comment: "")
        case .resetShortcuts:
            NSLocalizedString("dialog.reset_all_shortcuts", comment: "")
        }
    }

    var message: String {
        switch self {
        case .reduceRetentionDays(let days):
            String(
                format: NSLocalizedString("format.reducing_retention_may_remove_history", comment: ""),
                locale: Locale.current,
                days
            )
        case .resetShortcuts:
            NSLocalizedString("message.resetting_shortcuts_restores_every_default", comment: "")
        }
    }

    var confirmationButtonTitle: String {
        switch self {
        case .reduceRetentionDays:
            NSLocalizedString("action.apply_storage_limit", comment: "")
        case .resetShortcuts:
            NSLocalizedString("action.reset_all_shortcuts", comment: "")
        }
    }
}

private struct MCPClientCandidate: Identifiable, Hashable {
    var target: MCPClientConfigurationTarget
    var displayName: String
    var isDetected: Bool

    var id: String {
        target.id
    }
}

private struct MCPClientDetector {
    private struct KnownClient {
        var target: MCPClientConfigurationTarget
        var bundleIdentifiers: Set<String> = []
        var applicationNames: Set<String> = []
        var executableNames: Set<String> = []
        var homeRelativeConfigurationPaths: Set<String> = []
    }

    var fileManager: FileManager = .default

    func candidates(applications: [InstalledApplication]) -> [MCPClientCandidate] {
        supportedClients.map { client in
            MCPClientCandidate(
                target: client.target,
                displayName: client.target.displayName,
                isDetected: isDetected(client, applications: applications)
            )
        }
    }

    var shellSearchPath: String {
        executableSearchPaths.joined(separator: ":")
    }

    func resolvedCommandParts(_ parts: [String], for target: MCPClientConfigurationTarget) -> [String] {
        guard let commandName = parts.first else { return parts }
        let resolvedCommand = preferredExecutablePath(for: target, commandName: commandName)
            ?? executablePath(named: commandName)
            ?? commandName
        return [resolvedCommand] + parts.dropFirst()
    }

    private func preferredExecutablePath(for target: MCPClientConfigurationTarget, commandName: String) -> String? {
        let path: String?
        switch target {
        case .vscode where commandName == "code":
            path = "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
        case .cursor where commandName == "cursor":
            path = "/Applications/Cursor.app/Contents/Resources/app/bin/cursor"
        default:
            path = nil
        }
        guard let path, fileManager.isExecutableFile(atPath: path) else {
            return nil
        }
        return path
    }

    private var supportedClients: [KnownClient] {
        [
            KnownClient(
                target: .claude,
                bundleIdentifiers: ["com.anthropic.claudefordesktop"],
                applicationNames: ["Claude"],
                homeRelativeConfigurationPaths: ["Library/Application Support/Claude/claude_desktop_config.json"]
            ),
            KnownClient(
                target: .claudeCode,
                executableNames: ["claude"],
                homeRelativeConfigurationPaths: [".claude.json"]
            ),
            KnownClient(
                target: .codex,
                bundleIdentifiers: ["com.openai.codex"],
                applicationNames: ["Codex"],
                executableNames: ["codex"],
                homeRelativeConfigurationPaths: [".codex/config.toml"]
            ),
            KnownClient(
                target: .cursor,
                bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"],
                applicationNames: ["Cursor"],
                executableNames: ["cursor"],
                homeRelativeConfigurationPaths: [".cursor/mcp.json"]
            ),
            KnownClient(
                target: .vscode,
                bundleIdentifiers: ["com.microsoft.VSCode"],
                applicationNames: ["Visual Studio Code"]
            ),
            KnownClient(
                target: .windsurf,
                bundleIdentifiers: ["com.exafunction.windsurf", "com.codeium.windsurf"],
                applicationNames: ["Windsurf"],
                executableNames: ["windsurf"],
                homeRelativeConfigurationPaths: [".codeium/mcp_config.json", ".codeium/windsurf/mcp_config.json"]
            ),
            KnownClient(
                target: .gemini,
                executableNames: ["gemini"],
                homeRelativeConfigurationPaths: [".gemini/settings.json"]
            ),
            KnownClient(
                target: .opencode,
                bundleIdentifiers: ["ai.opencode.desktop"],
                applicationNames: ["OpenCode"],
                executableNames: ["opencode"],
                homeRelativeConfigurationPaths: [".config/opencode/opencode.json"]
            ),
            KnownClient(
                target: .kiro,
                bundleIdentifiers: ["com.amazon.codewhisperer"],
                applicationNames: ["Kiro", "Kiro CLI"],
                executableNames: ["kiro"],
                homeRelativeConfigurationPaths: [".kiro/settings/mcp.json"]
            )
        ]
    }

    private func isDetected(_ client: KnownClient, applications: [InstalledApplication]) -> Bool {
        applications.contains { application in
            matches(application, client: client)
        } || client.executableNames.contains { executableExists(named: $0) }
            || client.homeRelativeConfigurationPaths.contains { homeRelativePathExists($0) }
    }

    private func matches(_ application: InstalledApplication, client: KnownClient) -> Bool {
        if let bundleIdentifier = application.bundleIdentifier,
           client.bundleIdentifiers.contains(bundleIdentifier) {
            return true
        }
        return client.applicationNames.contains { name in
            application.displayName.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    private func executableExists(named name: String) -> Bool {
        executablePath(named: name) != nil
    }

    private func executablePath(named name: String) -> String? {
        executableSearchPaths
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
            .first { fileManager.isExecutableFile(atPath: $0) }
    }

    private func homeRelativePathExists(_ relativePath: String) -> Bool {
        let path = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(relativePath)
            .path
        return fileManager.fileExists(atPath: path)
    }

    private var executableSearchPaths: [String] {
        let homePath = fileManager.homeDirectoryForCurrentUser.path
        let commonPaths = [
            "\(homePath)/.local/bin",
            "\(homePath)/.npm-global/bin",
            "\(homePath)/.opencode/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        let environmentPaths = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        var seen = Set<String>()
        return (environmentPaths + commonPaths).filter { seen.insert($0).inserted }
    }
}

private struct MCPClientCommandRunner {
    struct Result {
        var exitCode: Int32
        var output: String
    }

    static func run(parts: [String], searchPath: String) async -> Result {
        await Task.detached(priority: .userInitiated) {
            guard let command = parts.first else {
                return Result(exitCode: 2, output: "Missing command")
            }

            let process = Process()
            if command.contains("/") {
                process.executableURL = URL(fileURLWithPath: command)
                process.arguments = Array(parts.dropFirst())
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = parts
            }

            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = searchPath
            process.environment = environment

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
                process.waitUntilExit()
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(decoding: outputData + errorData, as: UTF8.self)
                return Result(exitCode: process.terminationStatus, output: output)
            } catch {
                return Result(exitCode: 1, output: error.localizedDescription)
            }
        }.value
    }
}

private extension MCPClientConfigurationTarget {
    var systemImageName: String {
        switch self {
        case .claude:
            "sparkles"
        case .claudeCode:
            "terminal"
        case .codex:
            "chevron.left.forwardslash.chevron.right"
        case .cursor:
            "cube"
        case .vscode:
            "keyboard"
        case .windsurf:
            "wind"
        case .gemini:
            "sparkles"
        case .opencode:
            "terminal"
        case .kiro:
            "hammer"
        case .custom:
            "wrench.and.screwdriver"
        }
    }
}

private struct RecordedShortcut {
    let key: String
    let modifiers: [ShortcutModifier]
    let keyCode: UInt16

    init?(event: NSEvent) {
        guard let key = event.charactersIgnoringModifiers?.first else {
            return nil
        }
        self.key = String(key).lowercased()
        modifiers = event.shortcutModifiers
        keyCode = event.keyCode
    }
}

private struct ShortcutCaptureButton: View {
    let displayName: String
    let soundEffectsEnabled: Bool
    var onClear: (() -> Void)?
    let onCapture: (RecordedShortcut) -> Void
    @StateObject private var recorder = ShortcutRecorderState()

    var body: some View {
        HStack(spacing: 4) {
            Button {
                recorder.start(soundEffectsEnabled: soundEffectsEnabled, onCapture: onCapture)
            } label: {
                Text(recorder.isRecording ? "…" : displayName)
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if let onClear {
                Button(action: onClear) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("action.clear_shortcut"))
            }
        }
        .onDisappear { recorder.stop() }
        .accessibilityLabel(
            recorder.isRecording
                ? NSLocalizedString("state.recording_shortcut", comment: "")
                : displayName
        )
        .accessibilityHint(
            recorder.isRecording
                ? NSLocalizedString("message.press_key_combination_to_record", comment: "")
                : NSLocalizedString("action.record_shortcut", comment: "")
        )
    }
}

@MainActor
private final class ShortcutRecorderState: ObservableObject {
    @Published var isRecording = false
    private var eventMonitor: Any?
    private static weak var activeRecorder: ShortcutRecorderState?

    func start(
        soundEffectsEnabled: Bool,
        onCapture: @escaping (RecordedShortcut) -> Void
    ) {
        Self.activeRecorder?.stop()
        Self.activeRecorder = self
        stop()
        isRecording = true
        NotificationCenter.default.post(name: .pasteBuddyShortcutRecordingDidChange, object: true)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                self.stop()
                return nil
            }
            guard let shortcut = RecordedShortcut(event: event) else {
                if soundEffectsEnabled {
                    NSSound.beep()
                }
                return nil
            }
            onCapture(shortcut)
            self.stop()
            return nil
        }
    }

    func stop() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        isRecording = false
        if Self.activeRecorder === self {
            Self.activeRecorder = nil
        }
        NotificationCenter.default.post(name: .pasteBuddyShortcutRecordingDidChange, object: false)
    }
}

extension Notification.Name {
    static let pasteBuddyShortcutRecordingDidChange = Notification.Name("PasteBuddyShortcutRecordingDidChange")
}

private extension NSEvent {
    var shortcutModifiers: [ShortcutModifier] {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: [ShortcutModifier] = []
        if flags.contains(.command) { modifiers.append(.command) }
        if flags.contains(.option) { modifiers.append(.option) }
        if flags.contains(.shift) { modifiers.append(.shift) }
        if flags.contains(.control) { modifiers.append(.control) }
        return ShortcutBinding.normalizedModifiers(modifiers)
    }
}
