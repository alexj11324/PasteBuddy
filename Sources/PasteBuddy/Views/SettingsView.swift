import AppKit
import CoreImage
import Foundation
import PasteBuddyCore
import SwiftUI

struct SettingsView: View {
    @Bindable var store: PasteBuddyStore
    @Bindable var irohSync: IrohClipboardSyncService
    @State private var newCaptureRuleName = ""
    @State private var newCaptureRulePattern = ""
    @State private var newCaptureRuleCondition: CaptureRuleCondition = .containsText
    @State private var newCaptureRuleContentType: ClipboardContentType?
    @State private var newCaptureRuleApplication: InstalledApplication?
    @State private var showingCaptureRuleApplicationPicker = false
    @State private var showingExcludedApplicationsSheet = false
    @State private var showingMCPAdvancedSettings = false
    @State private var destructiveConfirmation: SettingsDestructiveAction?
    @State private var selectedSettingsSection: SettingsSidebarSection? = .general
    @State private var selectedMCPClient: MCPClientConfigurationTarget?
    @State private var mcpClientCandidates: [MCPClientCandidate] = []
    @State private var isRunningMCPClientInstall = false
    @State private var mcpStatusMessage: String?

    var body: some View {
        settingsSplitView
            .frame(minWidth: 860, idealWidth: 1040, minHeight: 640, idealHeight: 760)
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
            .sheet(isPresented: $showingExcludedApplicationsSheet) {
                ExcludedApplicationsSheet(store: store)
            }
            .sheet(isPresented: $showingMCPAdvancedSettings) {
                MCPAdvancedSettingsSheet(store: store)
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
            .sheet(isPresented: $showingCaptureRuleApplicationPicker) {
                InstalledApplicationPickerSheet(
                    requiresBundleIdentifier: newCaptureRuleCondition == .sourceBundleIdentifier
                ) { application in
                    newCaptureRuleApplication = application
                    newCaptureRulePattern = newCaptureRuleCondition.rulePattern(for: application)
                }
            }
    }

    private var settingsSplitView: some View {
        NavigationSplitView {
            List(SettingsSidebarSection.allCases, selection: $selectedSettingsSection) { section in
                Label {
                    Text(section.titleKey)
                } icon: {
                    Image(systemName: section.systemImageName)
                }
                .tag(section)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(.regularMaterial)
            .navigationTitle("label.settings")
        } detail: {
            selectedSettingsDetail
                .navigationTitle(effectiveSettingsSection.titleKey)
        }
        .toolbar(removing: .sidebarToggle)
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var selectedSettingsDetail: some View {
        switch effectiveSettingsSection {
        case .general:
            generalSettingsForm
        case .storage:
            storageSettingsForm
        case .plans:
            plansSettingsForm
        case .shortcuts:
            shortcutsSettingsForm
        case .integrations:
            integrationsSettingsForm
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

    private var generalSettingsForm: some View {
        Form {
            if let destination = store.requestedSettingsDestination {
                Section("label.settings_entry_point") {
                    Label(localizedSettingsTitle(destination), systemImage: destination.systemImageName)

                    Button("action.clear_settings_focus") {
                        store.clearRequestedSettingsDestination()
                    }
                }
            }

            Section("label.general") {
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { store.snapshot.general.launchAtLoginEnabled },
                        set: { store.setLaunchAtLoginEnabled($0) }
                    )
                )
                .disabled(!LaunchAtLoginService.isAvailable)

                LabeledContent("label.menu_bar") {
                    Text("label.visible")
                }

                if let error = store.lastErrorMessage {
                    Text(error)
                        .foregroundStyle(.orange)
                }
            }

            Section("label.capture") {
                Toggle(
                    store.isCapturePaused ? "Capture is paused" : "Capture is active",
                    isOn: Binding(
                        get: { !store.isCapturePaused },
                        set: { isActive in
                            if isActive {
                                store.resumeCapture()
                            } else {
                                store.pauseCaptureIndefinitely()
                            }
                        }
                    )
                )

                if let pauseUntil = store.activeCapturePauseUntil {
                    Text(localized("format.capture_resumes_at", pauseUntil.formatted(date: .omitted, time: .shortened)))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("action.pause_15m") {
                        store.pauseCapture(for: 15 * 60)
                    }

                    Button("action.pause_1h") {
                        store.pauseCapture(for: 60 * 60)
                    }

                    Button("action.resume") {
                        store.resumeCapture()
                    }
                    .disabled(!store.isCapturePaused)
                }

                Toggle(
                    "Capture text",
                    isOn: Binding(
                        get: { store.snapshot.privacy.captureText },
                        set: { _ in store.toggleTextCapture() }
                    )
                )
                Toggle(
                    "Capture links",
                    isOn: Binding(
                        get: { store.snapshot.privacy.captureURLs },
                        set: { _ in store.toggleURLCapture() }
                    )
                )
                Toggle(
                    "Capture files",
                    isOn: Binding(
                        get: { store.snapshot.privacy.captureFiles },
                        set: { _ in store.toggleFileCapture() }
                    )
                )
                Toggle(
                    "label.capture_images",
                    isOn: Binding(
                        get: { store.snapshot.privacy.captureImages },
                        set: { _ in store.toggleImageCapture() }
                    )
                )
                Toggle(
                    "Block likely sensitive text locally",
                    isOn: Binding(
                        get: { store.snapshot.privacy.blockLikelySensitiveText },
                        set: { _ in store.toggleSensitiveTextBlocking() }
                    )
                )
                Toggle(
                    "Run local Apple OCR after image capture",
                    isOn: Binding(
                        get: { store.snapshot.privacy.runLocalOCRAfterImageCapture },
                        set: { _ in store.toggleOCR() }
                    )
                )
                .disabled(!store.snapshot.privacy.captureImages)
            }

            Section("label.excluded_apps") {
                LabeledContent("label.excluded_apps") {
                    Button("action.manage_apps") {
                        showingExcludedApplicationsSheet = true
                    }
                }
            }

            Section("label.custom_capture_rules") {
                if store.snapshot.privacy.customCaptureRules.isEmpty {
                    Text("label.no_custom_capture_rules")
                        .foregroundStyle(.secondary)
                }

                ForEach(store.snapshot.privacy.customCaptureRules) { rule in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label(rule.name, systemImage: rule.condition.systemImageName)
                            Spacer()
                            Toggle(
                                "Enabled",
                                isOn: Binding(
                                    get: {
                                        store.snapshot.privacy.customCaptureRules
                                            .first(where: { $0.id == rule.id })?
                                            .isEnabled ?? false
                                    },
                                    set: { store.setCaptureRule(rule.id, enabled: $0) }
                                )
                            )
                            .labelsHidden()

                            Button("action.remove", role: .destructive) {
                                store.removeCaptureRule(rule.id)
                            }
                        }

                        Text(localized("format.value", localized(rule.condition.displayName), rule.pattern))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(rule.scopeDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                TextField("label.rule_name", text: $newCaptureRuleName)

                Picker("label.rule_type", selection: $newCaptureRuleCondition) {
                    ForEach(CaptureRuleCondition.allCases) { condition in
                        Text(condition.displayName).tag(condition)
                    }
                }
                .onChange(of: newCaptureRuleCondition) { _, condition in
                    if condition.requiresInstalledApplication {
                        newCaptureRulePattern = condition.rulePattern(for: newCaptureRuleApplication)
                    } else {
                        newCaptureRuleApplication = nil
                    }
                }

                Picker("label.type", selection: $newCaptureRuleContentType) {
                    Text("label.any_type").tag(Optional<ClipboardContentType>.none)
                    ForEach(ClipboardContentType.allCases) { contentType in
                        Text(localized(contentType.displayName)).tag(Optional(contentType))
                    }
                }

                if newCaptureRuleCondition.requiresInstalledApplication {
                    LabeledContent("label.source_app") {
                        Button {
                            showingCaptureRuleApplicationPicker = true
                        } label: {
                            HStack(spacing: 8) {
                                if let application = newCaptureRuleApplication {
                                    InstalledApplicationIcon(application: application)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(application.displayName)
                                        if let bundleIdentifier = application.bundleIdentifier {
                                            Text(bundleIdentifier)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                } else {
                                    Text("label.no_app_selected")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                } else {
                    TextField("label.rule_pattern", text: $newCaptureRulePattern)
                }

                Button("action.add_rule") {
                    let contentTypes = newCaptureRuleContentType.map { Set([$0]) } ?? []
                    if store.addCaptureRule(
                        name: newCaptureRuleName,
                        condition: newCaptureRuleCondition,
                        pattern: captureRulePatternForSubmit,
                        contentTypes: contentTypes
                    ) != nil {
                        newCaptureRuleName = ""
                        newCaptureRulePattern = ""
                        newCaptureRuleCondition = .containsText
                        newCaptureRuleContentType = nil
                        newCaptureRuleApplication = nil
                    }
                }
                .disabled(captureRulePatternForSubmit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            }
            .formStyle(.grouped)
            .scenePadding()
    }

    private var storageSettingsForm: some View {
            Form {
            Section("label.storage_security") {
                LabeledContent("label.storage_mode") {
                    Text(localized(store.snapshot.security.storageMode.displayName))
                }

                Toggle(
                    "Require Touch ID to unlock history",
                    isOn: Binding(
                        get: { store.snapshot.security.requiresBiometricUnlock },
                        set: { store.setBiometricHistoryLockEnabled($0) }
                    )
                )

                LabeledContent("label.history_lock") {
                    Text(localized(store.historyAccessStatusLine))
                }

                Stepper(
                    value: Binding(
                        get: { Int(store.snapshot.security.biometricGracePeriodSeconds) },
                        set: { store.updateBiometricGracePeriodSeconds(TimeInterval($0)) }
                    ),
                    in: 0...300,
                    step: 15
                ) {
                    Text(localized("format.touch_id_grace_period_seconds", Int(store.snapshot.security.biometricGracePeriodSeconds)))
                }
                .disabled(!store.snapshot.security.requiresBiometricUnlock)

                HStack {
                    Button("action.unlock_history") {
                        Task {
                            await store.unlockHistoryWithTouchID()
                        }
                    }
                    .disabled(!store.snapshot.security.requiresBiometricUnlock || !store.isHistoryAccessLocked)

                    Button("action.lock_history") {
                        store.lockHistory()
                    }
                    .disabled(!store.snapshot.security.requiresBiometricUnlock || store.isHistoryAccessLocked)
                }
            }

            Section("label.storage_retention") {
                let storageReport = store.storageUsageReport
                LabeledContent("label.estimated_history_size") {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(storageReport.estimatedBytes), countStyle: .file))
                }
                LabeledContent("label.pinned_history_size") {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(storageReport.pinnedEstimatedBytes), countStyle: .file))
                }
                LabeledContent("label.unpinned_history_size") {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(storageReport.unpinnedEstimatedBytes), countStyle: .file))
                }
                LabeledContent("label.items") {
                    Text(localized("format.items", storageReport.itemCount))
                }
                ProgressView(value: storageReport.usageFraction) {
                    Text("label.storage_limit")
                } currentValueLabel: {
                    Text(storageLimitDescription)
                }

                Stepper(
                    value: Binding(
                        get: { store.snapshot.storage.maxStorageBytes / (1_024 * 1_024) },
                        set: { store.updateMaxStorageBytes($0 * 1_024 * 1_024) }
                    ),
                    in: 1...102_400,
                    step: 50
                ) {
                    Text(localized("format.use_up_to", storageLimitDescription))
                }

                Stepper(
                    value: Binding(
                        get: { store.snapshot.storage.retentionDays },
                        set: { store.updateRetentionDays($0) }
                    ),
                    in: 0...730,
                    step: 7
                ) {
                    Text(retentionDescription)
                }

                Button("action.clear_unpinned_history", role: .destructive) {
                    destructiveConfirmation = .clearUnpinnedHistory
                }

                Button("action.clear_all_history_including_pinned", role: .destructive) {
                    destructiveConfirmation = .clearAllHistory
                }
            }

            Section("action.paste") {
                Toggle(
                    "Paste as plain text by default",
                    isOn: Binding(
                        get: { store.snapshot.paste.alwaysPasteAsPlainText },
                        set: { store.setAlwaysPasteAsPlainText($0) }
                    )
                )
            }
            }
            .formStyle(.grouped)
            .scenePadding()
    }

    private var plansSettingsForm: some View {
            Form {
            Section("label.plan") {
                LabeledContent("label.current_plan") {
                    Text(localizedPlanName(for: store.snapshot.entitlement.plan))
                }

                if let trialEndsAt = store.snapshot.entitlement.trialEndsAt {
                    LabeledContent("label.trial_ends") {
                        Text(trialEndsAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }

                if let currentPeriodEndsAt = store.snapshot.entitlement.currentPeriodEndsAt {
                    LabeledContent("label.renews_or_expires") {
                        Text(currentPeriodEndsAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }

                HStack {
                    Button("action.start_trial") {
                        store.startFreeTrial()
                    }

                    Button("action.cancel_trial") {
                        store.cancelFreeTrial()
                    }
                    .disabled(!store.snapshot.entitlement.isTrialActive())
                }

                HStack {
                    Button("label.monthly") {
                        store.activatePersonalPlan(.monthly, currentPeriodEndsAt: oneMonthFromNow)
                    }

                    Button("label.annual") {
                        store.activatePersonalPlan(.annual, currentPeriodEndsAt: oneYearFromNow)
                    }

                    Button("label.lifetime") {
                        store.activatePersonalPlan(.lifetime)
                    }

                    Button("label.family") {
                        store.activatePersonalPlan(.family, currentPeriodEndsAt: oneYearFromNow)
                    }
                }

                Button("action.restore_purchases") {
                    let now = Date()
                    store.markRestorePurchasesStarted(at: now)
                    store.markRestorePurchasesFailed("Restore purchases is not available in this build.", at: now)
                }

            }
            }
            .formStyle(.grouped)
            .scenePadding()
    }

    private var shortcutsSettingsForm: some View {
            Form {
            Section("label.shortcuts") {
                Toggle(
                    "action.enable_quick_paste_1_9",
                    isOn: Binding(
                        get: { store.snapshot.shortcuts.isQuickPasteEnabled },
                        set: { store.setQuickPasteShortcutsEnabled($0) }
                    )
                )

                LabeledContent("label.quick_paste") {
                    Text(store.snapshot.shortcuts.quickPasteDisplayName)
                }

                LabeledContent("label.plain_text_quick_paste") {
                    Text(store.snapshot.shortcuts.plainTextQuickPasteDisplayName)
                }

                ShortcutModifierEditorRow(
                    store: store,
                    title: "label.quick_paste_modifiers",
                    plainText: false
                )

                ShortcutModifierEditorRow(
                    store: store,
                    title: "label.plain_text_quick_paste_modifiers",
                    plainText: true
                )

                ForEach(ShortcutAction.allCases) { action in
                    ShortcutBindingEditorRow(store: store, action: action)
                }

                Button("label.reset_shortcuts") {
                    store.resetShortcutConfiguration()
                }
            }
            }
            .formStyle(.grouped)
            .scenePadding()
    }

    private var integrationsSettingsForm: some View {
            Form {
            Section("label.mcp_ai_tools") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(
                                "action.enable_mcp",
                                isOn: Binding(
                                    get: { store.snapshot.mcp.isServerEnabled },
                                    set: { store.setMCPServerEnabled($0) }
                                )
                            )
                            .font(.headline)

                            Text("message.mcp_allows_ai_apps_to_connect")
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Label(
                            store.snapshot.mcp.isServerEnabled ? "state.enabled" : "state.off",
                            systemImage: store.snapshot.mcp.isServerEnabled ? "checkmark.circle.fill" : "pause.circle"
                        )
                        .foregroundStyle(store.snapshot.mcp.isServerEnabled ? .green : .secondary)
                    }

                    Divider()

                    HStack(spacing: 8) {
                        Circle()
                            .fill(store.snapshot.mcp.isServerEnabled ? .green : .secondary)
                            .frame(width: 8, height: 8)

                        Text(mcpServerCommandSummary)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)

                        Spacer()

                        Button {
                            copyMCPServerCommand(for: .custom)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("action.copy_server_command")

                        Button("label.advanced_ellipsis") {
                            showingMCPAdvancedSettings = true
                        }
                    }

                    HStack(spacing: 10) {
                        Button("action.generate_server_config") {
                            selectedMCPClient = .custom
                        }

                        Menu {
                            if detectedMCPClientCandidates.isEmpty {
                                Text("message.no_detected_mcp_clients")
                            } else {
                                Section("label.detected_ai_tools") {
                                    ForEach(detectedMCPClientCandidates) { candidate in
                                        Button {
                                            selectedMCPClient = candidate.target
                                        } label: {
                                            Label(candidate.displayName, systemImage: candidate.target.systemImageName)
                                        }
                                    }
                                }
                            }

                            Section("label.supported_ai_tools") {
                                ForEach(supportedMCPClientCandidates) { candidate in
                                    Button {
                                        selectedMCPClient = candidate.target
                                    } label: {
                                        Label(candidate.displayName, systemImage: candidate.target.systemImageName)
                                    }
                                }
                            }

                            Divider()

                            Button {
                                reloadMCPClientCandidates()
                            } label: {
                                Label("action.refresh_detected_ai_tools", systemImage: "arrow.clockwise")
                            }

                            Button {
                                selectedMCPClient = .custom
                            } label: {
                                Label("action.custom_ai_tool", systemImage: "wrench.and.screwdriver")
                            }
                        } label: {
                            Label("action.connect_ai_tool", systemImage: "plus.circle")
                        }

                        Spacer()

                        Button("action.shut_down_mcp_server", role: .destructive) {
                            shutdownMCPServer()
                        }
                        .disabled(!store.snapshot.mcp.isServerEnabled)
                    }

                    Text(mcpClientDetectionSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let mcpStatusMessage {
                        Text(mcpStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("label.connected_ai_tools") {
                if let latestAccess = store.snapshot.mcp.accessLog.first {
                    LabeledContent("label.local_mcp_client") {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(latestAccess.accessedAt.formatted(date: .abbreviated, time: .shortened))
                            Text(localized("format.mcp_access_count", store.snapshot.mcp.accessLog.count))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("message.no_connected_ai_tools_yet")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .multilineTextAlignment(.center)
                }
            }

            Section("action.sync_sharing") {
                LabeledContent("label.mode") {
                    Text(localized(store.snapshot.sync.provider.displayName))
                }

                LabeledContent("label.readiness") {
                    Text(localized(store.syncReadiness.displayName))
                        .foregroundStyle(syncStatusColor)
                }

                if let lastSyncAt = store.snapshot.sync.lastSyncAt {
                    LabeledContent("label.last_sync") {
                        Text(lastSyncAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }

                if let lastImportedPackageID = store.snapshot.sync.lastImportedPackageID {
                    LabeledContent("label.last_imported_package") {
                        Text(String(lastImportedPackageID.uuidString.prefix(8)) + "...")
                    }
                }

                if store.snapshot.sync.lastSyncConflictCount > 0 {
                    LabeledContent("label.last_conflicts") {
                        Text("\(store.snapshot.sync.lastSyncConflictCount)")
                            .foregroundStyle(.orange)
                    }
                }

                Toggle(
                    "label.shared_pinboards",
                    isOn: Binding(
                        get: { store.snapshot.sync.isSharedPinboardsEnabled },
                        set: { store.setSharedPinboardsEnabled($0) }
                    )
                )
                .disabled(!store.syncReadiness.canAttemptCloudSync)

                if store.snapshot.sync.provider != .none {
                    Button("label.reset_to_local_only") {
                        store.disableCloudSync()
                    }
                }

                Text(syncReadinessDetail)
                    .foregroundStyle(.secondary)

                if let statusMessage = store.snapshot.sync.lastSyncStatusMessage {
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                }

            }

            Section("label.iroh_clipboard_sync") {
                LabeledContent("label.status") {
                    Text(irohStatusText)
                        .foregroundStyle(irohStatusColor)
                }

                if !irohSync.endpointId.isEmpty {
                    LabeledContent("label.this_device") {
                        Text(irohSync.endpointId)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                if let pairingURL = irohSync.pairingURL {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 12) {
                            IrohPairingQRCodeView(value: pairingURL.absoluteString)
                                .frame(width: 132, height: 132)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("message.scan_pairing_qr_from_iphone")
                                    .foregroundStyle(.secondary)
                                Text(pairingURL.absoluteString)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                Button("action.copy_pairing_link") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(pairingURL.absoluteString, forType: .string)
                                }
                            }
                        }
                    }
                }

                TextField("label.peer_endpoint_id", text: $irohSync.peerEndpointId)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())

                HStack {
                    Button("action.connect") {
                        Task { await irohSync.connectToPeer() }
                    }
                    .disabled(irohSync.peerEndpointId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("action.send_latest_clipboard_item") {
                        if let item = store.snapshot.items.first {
                            Task { await irohSync.send(item) }
                        }
                    }
                    .disabled(!irohSync.connectionState.isConnected || store.snapshot.items.isEmpty)
                }

                if let lastReceivedTitle = irohSync.lastReceivedTitle {
                    Text(localized("format.last_received_item", lastReceivedTitle))
                        .foregroundStyle(.secondary)
                }

                Text("message.iroh_clipboard_sync_local_peer")
                    .foregroundStyle(.secondary)
            }

            Section("label.direct_paste") {
                LabeledContent("label.accessibility_access") {
                    Text(AccessibilityPermissionService.isTrusted ? "state.enabled" : "state.required")
                        .foregroundStyle(AccessibilityPermissionService.isTrusted ? .green : .orange)
                }

                Button("action.request_accessibility_access") {
                    AccessibilityPermissionService.requestTrustPrompt()
                }

                if let result = store.lastDirectPasteResult {
                    LabeledContent("label.last_direct_paste") {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(result.statusMessage)
                            if let guidance = result.permissionGuidance {
                                Text(guidance.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            }
            .formStyle(.grouped)
            .scenePadding()
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
        case .clearUnpinnedHistory:
            store.clearUnpinnedHistory()
        case .clearAllHistory:
            store.clearAllHistoryIncludingPinnedItems()
        }
    }

    private var captureRulePatternForSubmit: String {
        guard newCaptureRuleCondition.requiresInstalledApplication else {
            return newCaptureRulePattern
        }
        return newCaptureRuleCondition.rulePattern(for: newCaptureRuleApplication)
    }

    private var syncStatusColor: Color {
        switch store.syncReadiness {
        case .localOnly: .secondary
        case .blocked: .orange
        case .ready: .green
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

    private var mcpServerCommandSummary: String {
        commandSummary(for: mcpClientGuide(for: .custom))
    }

    private var detectedMCPClientCandidates: [MCPClientCandidate] {
        mcpClientCandidates.filter(\.isDetected)
    }

    private var supportedMCPClientCandidates: [MCPClientCandidate] {
        mcpClientCandidates.filter { !$0.isDetected }
    }

    private var mcpClientDetectionSummary: String {
        guard !detectedMCPClientCandidates.isEmpty else {
            return localized("message.no_detected_mcp_clients")
        }
        let names = detectedMCPClientCandidates
            .map(\.displayName)
            .joined(separator: ", ")
        return localized("format.detected_mcp_clients", names)
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
                executablePath: packagedMCPExecutablePath
            )
        }
        return MCPClientConfigurationGuideBuilder.developmentGuide(
            for: target,
            packagePath: developmentPackagePath
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

    private func shutdownMCPServer() {
        store.setMCPServerEnabled(false)
        mcpStatusMessage = localized("message.mcp_server_shut_down")
    }

    private func commandSummary(for guide: MCPClientConfigurationGuide) -> String {
        ([guide.command] + guide.arguments).joined(separator: " ")
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var syncReadinessDetail: String {
        switch store.syncReadiness {
        case .blocked(let requirements):
            localized(
                "format.cloud_sync_blocked_until",
                requirements.map { localized($0.displayName) }.joined(separator: ", ")
            )
        case .localOnly, .ready:
            localized(store.syncReadiness.detail)
        }
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

    private func localizedSettingsTitle(_ destination: MacSettingsDestination) -> String {
        localized("format.settings", localized(destination.displayName))
    }

    private var personalOverview: PersonalEntitlementOverview {
        store.snapshot.entitlement.personalOverview()
    }

    private func localizedPlanName(for plan: ProductAccessPlan) -> String {
        switch plan {
        case .free:
            localized("label.free")
        case .trial:
            localized("label.trial")
        case .monthly:
            localized("label.monthly")
        case .annual:
            localized("label.annual")
        case .lifetime:
            localized("label.lifetime")
        case .family:
            localized("label.family")
        case .team:
            localized("label.team")
        }
    }

    private var oneMonthFromNow: Date {
        Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date().addingTimeInterval(30 * 24 * 60 * 60)
    }

    private var oneYearFromNow: Date {
        Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date().addingTimeInterval(365 * 24 * 60 * 60)
    }

    private var retentionDescription: String {
        if store.snapshot.storage.keepsHistoryForever {
            return localized("label.keep_history_forever")
        }
        return localized("format.keep_normal_history_for_days", store.snapshot.storage.retentionDays)
    }

    private var storageLimitDescription: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(store.snapshot.storage.maxStorageBytes),
            countStyle: .file
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

            ScrollView {
                Text(guide.configurationSnippet)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 160)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

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
        .frame(width: 680)
        .frame(minHeight: 500)
    }

    private var commandSummary: String {
        ([guide.command] + guide.arguments).joined(separator: " ")
    }
}

private struct MCPAdvancedSettingsSheet: View {
    @Bindable var store: PasteBuddyStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("label.mcp_advanced")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("action.close") {
                    dismiss()
                }
            }

            Toggle(
                "action.enable_mcp",
                isOn: Binding(
                    get: { store.snapshot.mcp.isServerEnabled },
                    set: { store.setMCPServerEnabled($0) }
                )
            )

            VStack(alignment: .leading, spacing: 10) {
                Text("label.mcp_tools")
                    .font(.headline)

                ForEach(MCPToolName.allCases) { tool in
                    Toggle(
                        tool.settingsTitleKey,
                        isOn: Binding(
                            get: { store.snapshot.mcp.enabledTools.contains(tool) },
                            set: { store.setMCPTool(tool, enabled: $0) }
                        )
                    )
                }
            }

            Text("message.retrieve_item_requires_explicit_mcp_opt_in")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            LabeledContent("label.last_mcp_access") {
                if let latestAccess = store.snapshot.mcp.accessLog.first {
                    Text(latestAccess.accessedAt.formatted(date: .abbreviated, time: .shortened))
                } else {
                    Text("state.none")
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("action.clear_mcp_access_log") {
                    store.clearMCPAccessLog()
                }
                .disabled(store.snapshot.mcp.accessLog.isEmpty)

                Button("action.revoke_mcp_access", role: .destructive) {
                    store.revokeMCPAccess()
                }
                .disabled(!store.snapshot.mcp.isServerEnabled && store.snapshot.mcp.enabledTools.isEmpty)

                Spacer()
            }
        }
        .padding(24)
        .frame(width: 560)
        .frame(minHeight: 460)
    }
}

private struct ExcludedApplicationsSheet: View {
    @Bindable var store: PasteBuddyStore
    @Environment(\.dismiss) private var dismiss
    @State private var applications: [InstalledApplication] = []
    @State private var selectedRowID: String?
    @State private var showingApplicationPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("label.excluded_apps")
                .font(.title2.weight(.semibold))

            VStack(spacing: 0) {
                HStack {
                    Text("label.app")
                        .font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                Divider()

                ZStack {
                    List(selection: $selectedRowID) {
                        ForEach(excludedRows) { row in
                            ExcludedApplicationRowView(row: row)
                                .tag(row.id)
                        }
                    }
                    .listStyle(.plain)

                    if excludedRows.isEmpty {
                        Text("label.no_excluded_apps")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                Rectangle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            }

            HStack(spacing: 12) {
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

                Button("action.close") {
                    dismiss()
                }
            }
        }
        .padding(28)
        .frame(width: 720, height: 520)
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

private struct IrohPairingQRCodeView: View {
    let value: String

    var body: some View {
        if let image = qrImage {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(8)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.secondary.opacity(0.2), lineWidth: 1)
                }
        }
    }

    private var qrImage: NSImage? {
        guard let data = value.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else { return nil }
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let representation = NSCIImageRep(ciImage: scaledImage)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
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

private extension CaptureRuleCondition {
    var requiresInstalledApplication: Bool {
        self == .sourceApplicationName || self == .sourceBundleIdentifier
    }

    func rulePattern(for application: InstalledApplication?) -> String {
        guard let application else { return "" }
        switch self {
        case .sourceApplicationName:
            return application.displayName
        case .sourceBundleIdentifier:
            return application.bundleIdentifier ?? ""
        case .containsText, .regularExpression, .urlHost, .fileExtension:
            return ""
        }
    }
}

private enum SettingsSidebarSection: String, CaseIterable, Identifiable, Hashable {
    case general
    case storage
    case plans
    case shortcuts
    case integrations

    init(_ destination: MacSettingsDestination) {
        switch destination {
        case .general, .privacy:
            self = .general
        case .storage:
            self = .storage
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
        case .storage:
            "label.storage"
        case .plans:
            "label.plans"
        case .shortcuts:
            "label.shortcuts"
        case .integrations:
            "label.integrations"
        }
    }

    var systemImageName: String {
        switch self {
        case .general:
            "gearshape"
        case .storage:
            "externaldrive"
        case .plans:
            "creditcard"
        case .shortcuts:
            "keyboard"
        case .integrations:
            "point.3.connected.trianglepath.dotted"
        }
    }
}

private enum SettingsDestructiveAction {
    case clearUnpinnedHistory
    case clearAllHistory

    var title: String {
        switch self {
        case .clearUnpinnedHistory:
            NSLocalizedString("dialog.clear_unpinned_history", comment: "")
        case .clearAllHistory:
            NSLocalizedString("dialog.clear_all_history", comment: "")
        }
    }

    var message: String {
        switch self {
        case .clearUnpinnedHistory:
            NSLocalizedString("message.this_removes_every_unpinned_clipboard_item_from", comment: "")
        case .clearAllHistory:
            NSLocalizedString("message.this_removes_all_local_clipboard_history_including", comment: "")
        }
    }

    var confirmationButtonTitle: String {
        switch self {
        case .clearUnpinnedHistory:
            NSLocalizedString("action.clear_unpinned_history", comment: "")
        case .clearAllHistory:
            NSLocalizedString("action.clear_all_history", comment: "")
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

private extension MCPToolName {
    var settingsTitleKey: LocalizedStringKey {
        switch self {
        case .searchHistory:
            "mcp.tool.search_history"
        case .retrieveItem:
            "mcp.tool.retrieve_item"
        case .listPinboards:
            "mcp.tool.list_pinboards"
        case .createPinboard:
            "mcp.tool.create_pinboard"
        case .pinFirstMatch:
            "mcp.tool.pin_first_match"
        }
    }
}

private struct ShortcutBindingEditorRow: View {
    @Bindable var store: PasteBuddyStore
    let action: ShortcutAction

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                LabeledContent(action.displayName) {
                    ShortcutCaptureButton(displayName: currentBinding.displayName) { shortcut in
                        store.setShortcutBinding(
                            action,
                            key: shortcut.key,
                            modifiers: shortcut.modifiers
                        )
                    }
                }
                Button("action.clear_shortcut") {
                    store.clearShortcutBinding(action)
                }
                .disabled(!currentBinding.isEnabled)
            }
        }
    }

    private var currentBinding: ShortcutBinding {
        store.snapshot.shortcuts.binding(for: action)
    }
}

private struct ShortcutModifierEditorRow: View {
    @Bindable var store: PasteBuddyStore
    let title: String
    let plainText: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(localized(title)) {
                ShortcutCaptureButton(displayName: displayName) { shortcut in
                    store.setQuickPasteModifiers(shortcut.modifiers, plainText: plainText)
                }
            }
        }
    }

    private var modifiers: [ShortcutModifier] {
        plainText
            ? store.snapshot.shortcuts.plainTextQuickPasteModifiers
            : store.snapshot.shortcuts.quickPasteModifiers
    }

    private var displayName: String {
        let normalized = ShortcutBinding.normalizedModifiers(modifiers)
        guard !normalized.isEmpty else { return localized("label.digits_only") }
        return normalized.map(\.displayName).joined()
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}

private struct RecordedShortcut {
    let key: String
    let modifiers: [ShortcutModifier]

    init?(event: NSEvent) {
        guard let key = event.charactersIgnoringModifiers?.first else {
            return nil
        }
        self.key = String(key).lowercased()
        modifiers = event.shortcutModifiers
    }
}

private struct ShortcutCaptureButton: View {
    let displayName: String
    let onCapture: (RecordedShortcut) -> Void
    @StateObject private var recorder = ShortcutRecorderState()

    var body: some View {
        Button {
            recorder.start(onCapture: onCapture)
        } label: {
            Text(recorder.isRecording ? "…" : displayName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(recorder.isRecording ? .white : .secondary)
                .lineLimit(1)
                .frame(minWidth: 76, alignment: .trailing)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(recorder.isRecording ? Color.accentColor : Color.clear)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(recorder.isRecording ? 0.7 : 0), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .onDisappear { recorder.stop() }
        .accessibilityLabel(displayName)
    }
}

@MainActor
private final class ShortcutRecorderState: ObservableObject {
    @Published var isRecording = false
    private var eventMonitor: Any?
    private static weak var activeRecorder: ShortcutRecorderState?

    func start(onCapture: @escaping (RecordedShortcut) -> Void) {
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
                NSSound.beep()
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
