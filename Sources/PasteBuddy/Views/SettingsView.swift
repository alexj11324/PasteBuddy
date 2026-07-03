import Foundation
import PasteBuddyCore
import SwiftUI

struct SettingsView: View {
    @Bindable var store: PasteBuddyStore
    @State private var newCaptureRuleName = ""
    @State private var newCaptureRulePattern = ""
    @State private var newCaptureRuleCondition: CaptureRuleCondition = .containsText
    @State private var newCaptureRuleContentType: ClipboardContentType?
    @State private var destructiveConfirmation: SettingsDestructiveAction?

    var body: some View {
        TabView {
            Form {
            if let destination = store.requestedSettingsDestination {
                Section("label.settings_entry_point") {
                    Label(localizedSettingsTitle(destination), systemImage: destination.systemImageName)

                    Text("message.opened_from_the_menu_bar_the_related")
                        .foregroundStyle(.secondary)

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
                    "Capture images and screenshots",
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

            Section("label.privacy_scope") {
                LabeledContent("label.capture_status") {
                    Text(localized(store.privacyPostureReport.captureStatus.displayName))
                        .foregroundStyle(store.privacyPostureReport.captureStatus.isPaused ? .orange : .green)
                }

                Text(localized(store.privacyPostureReport.captureStatus.detail))
                    .foregroundStyle(.secondary)

                LabeledContent("label.protected_surfaces") {
                    Text(protectedSurfaceSummary)
                        .multilineTextAlignment(.trailing)
                }

                LabeledContent("label.disabled_types") {
                    Text(disabledContentTypeSummary)
                }

                LabeledContent("label.excluded_apps") {
                    Text(excludedApplicationSummary)
                }

                LabeledContent("label.active_rules") {
                    Text("\(store.privacyPostureReport.activeCustomCaptureRuleCount)")
                }

                LabeledContent("label.sensitive_text") {
                        Text(localized(store.privacyPostureReport.sensitiveTextBlockingEnabled ? "label.blocked_locally" : "label.allowed"))
                        .foregroundStyle(store.privacyPostureReport.sensitiveTextBlockingEnabled ? .green : .orange)
                }

                Text(localized(store.privacyPostureReport.coverageStatement))
                    .foregroundStyle(.secondary)

                Text(localized(store.privacyPostureReport.localBoundaryStatement))
                    .foregroundStyle(.secondary)

                Text(localized(store.privacyPostureReport.syncBoundaryStatement))
                    .foregroundStyle(.secondary)

                Text(localized(store.privacyPostureReport.vendorServerStatement))
                    .foregroundStyle(.secondary)

                Text(localized(store.privacyPostureReport.mcpBoundaryStatement))
                    .foregroundStyle(.secondary)
            }

            Section("label.excluded_apps") {
                ForEach(Array(store.snapshot.privacy.excludedApplicationNames).sorted(), id: \.self) { appName in
                    HStack {
                        Text(appName)
                        Spacer()
                        Button("action.remove") {
                            store.removeExcludedApplication(appName)
                        }
                    }
                }

                ForEach(Array(store.snapshot.privacy.excludedBundleIdentifiers).sorted(), id: \.self) { bundleIdentifier in
                    HStack {
                        Text(bundleIdentifier)
                        Spacer()
                        Button("action.remove") {
                            store.removeExcludedBundleIdentifier(bundleIdentifier)
                        }
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

                Picker("label.type", selection: $newCaptureRuleContentType) {
                    Text("label.any_type").tag(Optional<ClipboardContentType>.none)
                    ForEach(ClipboardContentType.allCases) { contentType in
                        Text(localized(contentType.displayName)).tag(Optional(contentType))
                    }
                }

                TextField("label.rule_pattern", text: $newCaptureRulePattern)

                Button("action.add_rule") {
                    let contentTypes = newCaptureRuleContentType.map { Set([$0]) } ?? []
                    if store.addCaptureRule(
                        name: newCaptureRuleName,
                        condition: newCaptureRuleCondition,
                        pattern: newCaptureRulePattern,
                        contentTypes: contentTypes
                    ) != nil {
                        newCaptureRuleName = ""
                        newCaptureRulePattern = ""
                        newCaptureRuleCondition = .containsText
                        newCaptureRuleContentType = nil
                    }
                }
                .disabled(newCaptureRulePattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Text("message.custom_rules_run_locally_before_capture_and")
                    .foregroundStyle(.secondary)
            }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("label.general", systemImage: "gearshape")
            }

            Form {
            Section("label.storage_security") {
                LabeledContent("label.storage_mode") {
                    Text(localized(store.snapshot.security.storageMode.displayName))
                }

                Text(localized(store.snapshot.security.storageMode.detail))
                    .foregroundStyle(.secondary)

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

                Text("message.touch_id_protects_access_to_the_history")
                    .foregroundStyle(.secondary)
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
                ProgressView(value: storageReport.usageFraction) {
                    Text("label.storage_limit")
                } currentValueLabel: {
                    Text(storageLimitDescription)
                }

                Stepper(
                    value: Binding(
                        get: { store.snapshot.storage.maxHistoryItems },
                        set: { store.updateMaxHistoryItems($0) }
                    ),
                    in: 50...5_000,
                    step: 50
                ) {
                    Text(localized("format.keep_up_to_items", store.snapshot.storage.maxHistoryItems))
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

                Text("message.pinned_items_are_preserved_when_normal_history")
                    .foregroundStyle(.secondary)
            }

            Section("action.paste") {
                Toggle(
                    "Paste as plain text by default",
                    isOn: Binding(
                        get: { store.snapshot.paste.alwaysPasteAsPlainText },
                        set: { store.setAlwaysPasteAsPlainText($0) }
                    )
                )

                Text("message.per_item_copy_and_paste_menus_still")
                    .foregroundStyle(.secondary)
            }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("label.storage", systemImage: "externaldrive")
            }

            Form {
            Section("label.plan") {
                LabeledContent("label.current_plan") {
                    Text(personalOverview.planName)
                }

                LabeledContent("label.status") {
                    Text(personalOverview.statusName)
                        .foregroundStyle(entitlementStatusColor)
                }

                LabeledContent("label.access") {
                    Text(personalOverview.accessState)
                        .foregroundStyle(store.hasFullProductAccess ? .green : .secondary)
                }

                LabeledContent("label.trial") {
                    Text(personalOverview.trialState.displayName)
                }

                Text(personalOverview.trialSummary)
                    .foregroundStyle(.secondary)

                Text(personalOverview.trialOutcomeStatement)
                    .foregroundStyle(.secondary)

                Label("label.device_unlock", systemImage: "macbook.and.iphone")
                Text(personalOverview.crossDeviceStatement)
                    .foregroundStyle(.secondary)

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

                LabeledContent("action.restore") {
                    Text(personalOverview.restoreSummary)
                }

                Text(personalOverview.restoreActionStatement)
                    .foregroundStyle(.secondary)

                Button("action.restore_purchases") {
                    let now = Date()
                    store.markRestorePurchasesStarted(at: now)
                    store.markRestorePurchasesFailed("StoreKit restore requires a signed App Store build.", at: now)
                }

                Divider()

                ForEach(personalOverview.purchaseOptions) { option in
                    Label(option.title, systemImage: personalPlanSystemImage(for: option.plan))
                    Text(option.detail)
                        .foregroundStyle(.secondary)
                    Text(option.unlockSummary)
                        .foregroundStyle(.secondary)
                }

                Text(personalOverview.billingSafetyStatement)
                    .foregroundStyle(.secondary)

            }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("label.plans", systemImage: "creditcard")
            }

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

                Text("message.cleared_shortcuts_remain_available_from_menus_but")
                    .foregroundStyle(.secondary)
            }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("label.shortcuts", systemImage: "keyboard")
            }

            Form {
            Section("label.agent_connection") {
                Toggle(
                    "action.allow_local_agent_connection",
                    isOn: Binding(
                        get: { store.snapshot.mcp.isServerEnabled },
                        set: { store.setMCPServerEnabled($0) }
                    )
                )

                LabeledContent("label.agent_connection_status") {
                    Label(
                        store.snapshot.mcp.isServerEnabled ? "label.allowed" : "state.off",
                        systemImage: store.snapshot.mcp.isServerEnabled ? "checkmark.circle.fill" : "pause.circle"
                    )
                    .foregroundStyle(store.snapshot.mcp.isServerEnabled ? .green : .secondary)
                }

                Text("message.agent_connection_runs_on_this_mac")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("message.agent_connection_step_1")
                    Text("message.agent_connection_step_2")
                    Text("message.swift_run_pastebuddymcp_print_client_config_codex")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text("message.agent_connection_step_3")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if store.snapshot.mcp.isServerEnabled {
                    Text("message.agent_connection_is_ready")
                        .foregroundStyle(.secondary)
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

                Text("message.direct_paste_copies_the_selected_item_first")
                    .foregroundStyle(.secondary)
            }

            }
            .formStyle(.grouped)
            .tabItem {
                Label("label.integrations", systemImage: "point.3.connected.trianglepath.dotted")
            }
        }
        .scenePadding()
        .frame(minWidth: 620, idealWidth: 700, minHeight: 760, idealHeight: 840)
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

    private var protectedSurfaceSummary: String {
        store.privacyPostureReport.protectedSurfaces
            .map { localized($0.displayName) }
            .sorted()
            .joined(separator: ", ")
    }

    private var disabledContentTypeSummary: String {
        let disabled = store.privacyPostureReport.disabledContentTypes
            .map(\.displayName)
            .sorted()
        return disabled.isEmpty ? localized("label.none") : disabled.map { localized($0) }.joined(separator: ", ")
    }

    private var excludedApplicationSummary: String {
        let report = store.privacyPostureReport
        return localized(
            "%d names, %d bundle IDs",
            report.excludedApplicationCount,
            report.excludedBundleIdentifierCount
        )
    }

    private var syncStatusColor: Color {
        switch store.syncReadiness {
        case .localOnly: .secondary
        case .blocked: .orange
        case .ready: .green
        }
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

    private var entitlementStatusColor: Color {
        switch store.snapshot.entitlement.status {
        case .active, .trialing:
            .green
        case .billingRetry, .canceled:
            .orange
        case .inactive, .expired, .revoked:
            .secondary
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

    private func personalPlanSystemImage(for plan: ProductAccessPlan) -> String {
        switch plan {
        case .monthly:
            "calendar"
        case .annual:
            "calendar.badge.clock"
        case .lifetime:
            "infinity"
        case .family:
            "person.2"
        case .free, .trial, .team:
            "checkmark.seal"
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

private struct ShortcutBindingEditorRow: View {
    @Bindable var store: PasteBuddyStore
    let action: ShortcutAction

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                LabeledContent(action.displayName) {
                    Text(currentBinding.displayName)
                }
                Button("action.clear_shortcut") {
                    store.clearShortcutBinding(action)
                }
                .disabled(!currentBinding.isEnabled)
            }

            TextField("label.key", text: Binding(
                get: { currentBinding.key ?? "" },
                set: { newValue in
                    store.setShortcutBinding(
                        action,
                        key: newValue,
                        modifiers: currentBinding.modifiers
                    )
                }
            ))
            .textFieldStyle(.roundedBorder)

            ShortcutModifierToggles(
                modifiers: currentBinding.modifiers,
                onChange: { modifiers in
                    store.setShortcutBinding(
                        action,
                        key: currentBinding.key,
                        modifiers: modifiers
                    )
                }
            )
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
                Text(displayName)
            }

            ShortcutModifierToggles(modifiers: modifiers) { updated in
                store.setQuickPasteModifiers(updated, plainText: plainText)
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
        return normalized.map(\.displayName).joined(separator: "+")
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}

private struct ShortcutModifierToggles: View {
    let modifiers: [ShortcutModifier]
    let onChange: ([ShortcutModifier]) -> Void

    var body: some View {
        HStack {
            ForEach(ShortcutModifier.allCases, id: \.self) { modifier in
                Toggle(modifier.displayName, isOn: Binding(
                    get: { modifiers.contains(modifier) },
                    set: { isEnabled in
                        var updated = modifiers
                        if isEnabled {
                            updated.append(modifier)
                        } else {
                            updated.removeAll { $0 == modifier }
                        }
                        onChange(ShortcutBinding.normalizedModifiers(updated))
                    }
                ))
                .toggleStyle(.checkbox)
            }
        }
    }
}
