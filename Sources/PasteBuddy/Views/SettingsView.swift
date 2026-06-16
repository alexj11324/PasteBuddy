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

    private var runtimeIdentity: PasteBuddyRuntimeIdentity {
        PasteBuddyRuntimeIdentityService.current
    }

    var body: some View {
        TabView {
            Form {
            if let destination = store.requestedSettingsDestination {
                Section("Settings Entry Point") {
                    Label(localizedSettingsTitle(destination), systemImage: destination.systemImageName)

                    Text("Opened from the menu bar. The related settings section is available below without starting a clipboard workflow.")
                        .foregroundStyle(.secondary)

                    Button("Clear Settings Focus") {
                        store.clearRequestedSettingsDestination()
                    }
                }
            }

            Section("General") {
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { store.snapshot.general.launchAtLoginEnabled },
                        set: { store.setLaunchAtLoginEnabled($0) }
                    )
                )
                .disabled(!LaunchAtLoginService.isAvailable)

                LabeledContent("Menu Bar") {
                    Text("Visible")
                }

                if let error = store.lastErrorMessage {
                    Text(error)
                        .foregroundStyle(.orange)
                }
            }

            Section("Capture") {
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
                    Text(localized("Capture resumes at %@.", pauseUntil.formatted(date: .omitted, time: .shortened)))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Pause 15m") {
                        store.pauseCapture(for: 15 * 60)
                    }

                    Button("Pause 1h") {
                        store.pauseCapture(for: 60 * 60)
                    }

                    Button("Resume") {
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

            Section("Privacy Scope") {
                LabeledContent("Capture Status") {
                    Text(store.privacyPostureReport.captureStatus.displayName)
                        .foregroundStyle(store.privacyPostureReport.captureStatus.isPaused ? .orange : .green)
                }

                Text(store.privacyPostureReport.captureStatus.detail)
                    .foregroundStyle(.secondary)

                LabeledContent("Protected Surfaces") {
                    Text(protectedSurfaceSummary)
                        .multilineTextAlignment(.trailing)
                }

                LabeledContent("Disabled Types") {
                    Text(disabledContentTypeSummary)
                }

                LabeledContent("Excluded Apps") {
                    Text(excludedApplicationSummary)
                }

                LabeledContent("Active Rules") {
                    Text("\(store.privacyPostureReport.activeCustomCaptureRuleCount)")
                }

                LabeledContent("Sensitive Text") {
                        Text(localized(store.privacyPostureReport.sensitiveTextBlockingEnabled ? "Blocked locally" : "Allowed"))
                        .foregroundStyle(store.privacyPostureReport.sensitiveTextBlockingEnabled ? .green : .orange)
                }

                Text(store.privacyPostureReport.coverageStatement)
                    .foregroundStyle(.secondary)

                Text(store.privacyPostureReport.localBoundaryStatement)
                    .foregroundStyle(.secondary)

                Text(store.privacyPostureReport.syncBoundaryStatement)
                    .foregroundStyle(.secondary)

                Text(store.privacyPostureReport.vendorServerStatement)
                    .foregroundStyle(.secondary)

                Text(store.privacyPostureReport.mcpBoundaryStatement)
                    .foregroundStyle(.secondary)
            }

            Section("Excluded Apps") {
                ForEach(Array(store.snapshot.privacy.excludedApplicationNames).sorted(), id: \.self) { appName in
                    HStack {
                        Text(appName)
                        Spacer()
                        Button("Remove") {
                            store.removeExcludedApplication(appName)
                        }
                    }
                }

                ForEach(Array(store.snapshot.privacy.excludedBundleIdentifiers).sorted(), id: \.self) { bundleIdentifier in
                    HStack {
                        Text(bundleIdentifier)
                        Spacer()
                        Button("Remove") {
                            store.removeExcludedBundleIdentifier(bundleIdentifier)
                        }
                    }
                }
            }

            Section("Custom Capture Rules") {
                if store.snapshot.privacy.customCaptureRules.isEmpty {
                    Text("No custom capture rules")
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

                            Button("Remove", role: .destructive) {
                                store.removeCaptureRule(rule.id)
                            }
                        }

                        Text(localized("%@: %@", localized(rule.condition.displayName), rule.pattern))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(rule.scopeDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                TextField("Rule Name", text: $newCaptureRuleName)

                Picker("Rule Type", selection: $newCaptureRuleCondition) {
                    ForEach(CaptureRuleCondition.allCases) { condition in
                        Text(condition.displayName).tag(condition)
                    }
                }

                Picker("Type", selection: $newCaptureRuleContentType) {
                    Text("Any Type").tag(Optional<ClipboardContentType>.none)
                    ForEach(ClipboardContentType.allCases) { contentType in
                        Text(localized(contentType.displayName)).tag(Optional(contentType))
                    }
                }

                TextField("Rule Pattern", text: $newCaptureRulePattern)

                Button("Add Rule") {
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

                Text("Custom rules run locally before capture and are stored inside the encrypted snapshot.")
                    .foregroundStyle(.secondary)
            }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("General", systemImage: "gearshape")
            }

            Form {
            Section("Storage Security") {
                LabeledContent("Storage Mode") {
                    Text(store.snapshot.security.storageMode.displayName)
                }

                Toggle(
                    "Encrypt clipboard history at rest",
                    isOn: Binding(
                        get: { store.snapshot.security.storageMode == .encrypted },
                        set: { store.setHistoryEncryptionEnabled($0) }
                    )
                )

                Text(store.snapshot.security.storageMode.detail)
                    .foregroundStyle(.secondary)

                Toggle(
                    "Require Touch ID to unlock history",
                    isOn: Binding(
                        get: { store.snapshot.security.requiresBiometricUnlock },
                        set: { store.setBiometricHistoryLockEnabled($0) }
                    )
                )

                LabeledContent("History Lock") {
                    Text(store.historyAccessStatusLine)
                }

                Stepper(
                    value: Binding(
                        get: { Int(store.snapshot.security.biometricGracePeriodSeconds) },
                        set: { store.updateBiometricGracePeriodSeconds(TimeInterval($0)) }
                    ),
                    in: 0...300,
                    step: 15
                ) {
                    Text(localized("Touch ID grace period: %d seconds", Int(store.snapshot.security.biometricGracePeriodSeconds)))
                }
                .disabled(!store.snapshot.security.requiresBiometricUnlock)

                HStack {
                    Button("Unlock History") {
                        Task {
                            await store.unlockHistoryWithTouchID()
                        }
                    }
                    .disabled(!store.snapshot.security.requiresBiometricUnlock || !store.isHistoryAccessLocked)

                    Button("Lock History") {
                        store.lockHistory()
                    }
                    .disabled(!store.snapshot.security.requiresBiometricUnlock || store.isHistoryAccessLocked)
                }

                Text("Touch ID protects access to the history UI without tying normal app launch to a Keychain password prompt. Encrypted mode is optional; when enabled, PasteBuddy stores the local encryption key separately in Keychain and never stores the key beside encrypted clipboard data.")
                    .foregroundStyle(.secondary)
            }

            Section("Storage & Retention") {
                let storageReport = store.storageUsageReport
                LabeledContent("Estimated History Size") {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(storageReport.estimatedBytes), countStyle: .file))
                }
                LabeledContent("Pinned History Size") {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(storageReport.pinnedEstimatedBytes), countStyle: .file))
                }
                LabeledContent("Unpinned History Size") {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(storageReport.unpinnedEstimatedBytes), countStyle: .file))
                }
                ProgressView(value: storageReport.usageFraction) {
                    Text("Storage Limit")
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
                    Text(localized("Keep up to %d items", store.snapshot.storage.maxHistoryItems))
                }

                Stepper(
                    value: Binding(
                        get: { store.snapshot.storage.maxStorageBytes / (1_024 * 1_024) },
                        set: { store.updateMaxStorageBytes($0 * 1_024 * 1_024) }
                    ),
                    in: 1...102_400,
                    step: 50
                ) {
                    Text(localized("Use up to %@", storageLimitDescription))
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

                Button("Clear Unpinned History", role: .destructive) {
                    destructiveConfirmation = .clearUnpinnedHistory
                }

                Button("Clear All History Including Pinned Items", role: .destructive) {
                    destructiveConfirmation = .clearAllHistory
                }

                Text("Pinned items are preserved when normal history expires, storage limits prune old content, or unpinned history is cleared. Use the explicit all-history action to remove pinned item memberships too.")
                    .foregroundStyle(.secondary)
            }

            Section("Paste") {
                Toggle(
                    "Paste as plain text by default",
                    isOn: Binding(
                        get: { store.snapshot.paste.alwaysPasteAsPlainText },
                        set: { store.setAlwaysPasteAsPlainText($0) }
                    )
                )

                Text("Per-item copy and paste menus still let you choose original format or plain text for a single action.")
                    .foregroundStyle(.secondary)
            }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Storage", systemImage: "externaldrive")
            }

            Form {
            Section("Plan") {
                LabeledContent("Current Plan") {
                    Text(personalOverview.planName)
                }

                LabeledContent("Status") {
                    Text(personalOverview.statusName)
                        .foregroundStyle(entitlementStatusColor)
                }

                LabeledContent("Access") {
                    Text(personalOverview.accessState)
                        .foregroundStyle(store.hasFullProductAccess ? .green : .secondary)
                }

                LabeledContent("Trial") {
                    Text(personalOverview.trialState.displayName)
                }

                Text(personalOverview.trialSummary)
                    .foregroundStyle(.secondary)

                Text(personalOverview.trialOutcomeStatement)
                    .foregroundStyle(.secondary)

                Label("Device Unlock", systemImage: "macbook.and.iphone")
                Text(personalOverview.crossDeviceStatement)
                    .foregroundStyle(.secondary)

                if let trialEndsAt = store.snapshot.entitlement.trialEndsAt {
                    LabeledContent("Trial Ends") {
                        Text(trialEndsAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }

                if let currentPeriodEndsAt = store.snapshot.entitlement.currentPeriodEndsAt {
                    LabeledContent("Renews Or Expires") {
                        Text(currentPeriodEndsAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }

                HStack {
                    Button("Start Trial") {
                        store.startFreeTrial()
                    }

                    Button("Cancel Trial") {
                        store.cancelFreeTrial()
                    }
                    .disabled(!store.snapshot.entitlement.isTrialActive())
                }

                HStack {
                    Button("Monthly") {
                        store.activatePersonalPlan(.monthly, currentPeriodEndsAt: oneMonthFromNow)
                    }

                    Button("Annual") {
                        store.activatePersonalPlan(.annual, currentPeriodEndsAt: oneYearFromNow)
                    }

                    Button("Lifetime") {
                        store.activatePersonalPlan(.lifetime)
                    }

                    Button("Family") {
                        store.activatePersonalPlan(.family, currentPeriodEndsAt: oneYearFromNow)
                    }
                }

                LabeledContent("Restore") {
                    Text(personalOverview.restoreSummary)
                }

                Text(personalOverview.restoreActionStatement)
                    .foregroundStyle(.secondary)

                Button("Restore Purchases") {
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

                Text("StoreKit 2 purchase and restore adapters are available in core; this SwiftPM debug UI still uses local plan simulation until a signed App Store target supplies production product IDs.")
                    .foregroundStyle(.secondary)
            }

            Section("Team Plan") {
                TextField(
                    "Team Name",
                    text: Binding(
                        get: { teamPlan.teamName },
                        set: { newValue in configureTeamPlan { $0.teamName = newValue } }
                    )
                )

                TextField(
                    "Admin Email",
                    text: Binding(
                        get: { teamPlan.adminEmailAddress ?? "" },
                        set: { newValue in configureTeamPlan { $0.adminEmailAddress = newValue } }
                    )
                )

                Stepper(
                    value: Binding(
                        get: { teamPlan.seatCount },
                        set: { newValue in configureTeamPlan { $0.seatCount = newValue } }
                    ),
                    in: 1...500,
                    step: 1
                ) {
                    Text(localized("Seats: %d", teamPlan.seatCount))
                }

                Stepper(
                    value: Binding(
                        get: { teamPlan.assignedSeatCount },
                        set: { newValue in configureTeamPlan { $0.assignedSeatCount = newValue } }
                    ),
                    in: 0...max(teamPlan.seatCount, 1),
                    step: 1
                ) {
                    Text(localized("Assigned: %d", teamPlan.assignedSeatCount))
                }

                Stepper(
                    value: Binding(
                        get: { teamPlan.pricePerSeatCents },
                        set: { newValue in configureTeamPlan { $0.pricePerSeatCents = newValue } }
                    ),
                    in: 0...50_000,
                    step: 100
                ) {
                    Text(localized("Per Seat: %@", formatCents(teamPlan.pricePerSeatCents, currencyCode: teamPlan.billingCurrencyCode)))
                }

                Toggle(
                    "Single Invoice",
                    isOn: Binding(
                        get: { teamPlan.singleInvoiceEnabled },
                        set: { newValue in configureTeamPlan { $0.singleInvoiceEnabled = newValue } }
                    )
                )

                Toggle(
                    "Managed Distribution",
                    isOn: Binding(
                        get: { teamPlan.managedDistributionEnabled },
                        set: { newValue in configureTeamPlan { $0.managedDistributionEnabled = newValue } }
                    )
                )

                LabeledContent("Monthly Invoice") {
                    Text(formatCents(teamPlan.monthlyInvoiceCents, currencyCode: teamPlan.billingCurrencyCode))
                }

                LabeledContent("Available Seats") {
                    Text("\(teamPlan.availableSeatCount)")
                }

                Divider()

                Text(teamPlan.overview.purchasePositioning)
                    .foregroundStyle(.secondary)

                Text(teamPlan.overview.primaryValueStatement)
                    .foregroundStyle(.secondary)

                LabeledContent("Seat State") {
                    Text(teamPlan.overview.seatSummary)
                }

                LabeledContent("Admin") {
                    Text(teamPlan.overview.adminSummary)
                }

                LabeledContent("Billing") {
                    Text(teamPlan.overview.billingSummary)
                }

                LabeledContent("Distribution") {
                    Text(teamPlan.overview.distributionSummary)
                }

                ForEach(teamPlan.overview.valuePropositions) { value in
                    Label(value.title, systemImage: value.systemImageName)
                    Text(value.detail)
                        .foregroundStyle(.secondary)
                }
            }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Plans", systemImage: "creditcard")
            }

            Form {
            Section("Shortcuts") {
                Toggle(
                    "Enable Quick Paste 1-9",
                    isOn: Binding(
                        get: { store.snapshot.shortcuts.isQuickPasteEnabled },
                        set: { store.setQuickPasteShortcutsEnabled($0) }
                    )
                )

                LabeledContent("Quick Paste") {
                    Text(store.snapshot.shortcuts.quickPasteDisplayName)
                }

                LabeledContent("Plain Text Quick Paste") {
                    Text(store.snapshot.shortcuts.plainTextQuickPasteDisplayName)
                }

                ShortcutModifierEditorRow(
                    store: store,
                    title: "Quick Paste Modifiers",
                    plainText: false
                )

                ShortcutModifierEditorRow(
                    store: store,
                    title: "Plain Text Quick Paste Modifiers",
                    plainText: true
                )

                ForEach(ShortcutAction.allCases) { action in
                    ShortcutBindingEditorRow(store: store, action: action)
                }

                Button("Reset Shortcuts") {
                    store.resetShortcutConfiguration()
                }

                Text("Cleared shortcuts remain available from menus but no keyboard equivalent is registered. System-wide show/hide registration is kept in configuration for signed app builds.")
                    .foregroundStyle(.secondary)
            }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Shortcuts", systemImage: "keyboard")
            }

            Form {
            Section("MCP") {
                Toggle(
                    "Enable local MCP server access",
                    isOn: Binding(
                        get: { store.snapshot.mcp.isServerEnabled },
                        set: { store.setMCPServerEnabled($0) }
                    )
                )

                ForEach(MCPToolName.allCases) { tool in
                    Toggle(
                        tool.displayName,
                        isOn: Binding(
                            get: { store.snapshot.mcp.enabledTools.contains(tool) },
                            set: { store.setMCPTool(tool, enabled: $0) }
                        )
                    )
                    .disabled(!store.snapshot.mcp.isServerEnabled)
                }

                Button("Revoke MCP Access", role: .destructive) {
                    destructiveConfirmation = .revokeMCPAccess
                }
                .disabled(!store.snapshot.mcp.isServerEnabled && store.snapshot.mcp.enabledTools.isEmpty)

                if let revokedAt = store.snapshot.mcp.lastAccessRevokedAt {
                    Text(localized("Last revoked at %@.", revokedAt.formatted(date: .abbreviated, time: .shortened)))
                        .foregroundStyle(.secondary)
                }

                if let latestAccess = store.snapshot.mcp.accessLog.first {
                    LabeledContent("Last MCP Access") {
                        Text("\(latestAccess.tool.displayName) - \(latestAccess.outcome.displayName)")
                    }
                    LabeledContent("Last MCP Access Time") {
                        Text(latestAccess.accessedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }

                Button("Clear MCP Audit Log", role: .destructive) {
                    destructiveConfirmation = .clearMCPAuditLog
                }
                .disabled(store.snapshot.mcp.accessLog.isEmpty)

                Text("MCP is local-only and disabled by default. Search results omit clipboard payloads; Retrieve Clipboard Item is a separate opt-in tool for payload access.")
                    .foregroundStyle(.secondary)
            }

            Section("Sync & Sharing") {
                LabeledContent("Mode") {
                    Text(store.snapshot.sync.provider.displayName)
                }

                LabeledContent("Readiness") {
                    Text(store.syncReadiness.displayName)
                        .foregroundStyle(syncStatusColor)
                }

                LabeledContent("Preflight") {
                    Text(store.cloudSyncPreflightReport.summary)
                        .foregroundStyle(syncPreflightSummaryColor)
                }

                if let lastSyncAt = store.snapshot.sync.lastSyncAt {
                    LabeledContent("Last Sync") {
                        Text(lastSyncAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }

                if let lastImportedPackageID = store.snapshot.sync.lastImportedPackageID {
                    LabeledContent("Last Imported Package") {
                        Text(String(lastImportedPackageID.uuidString.prefix(8)) + "...")
                    }
                }

                if store.snapshot.sync.lastSyncConflictCount > 0 {
                    LabeledContent("Last Conflicts") {
                        Text("\(store.snapshot.sync.lastSyncConflictCount)")
                            .foregroundStyle(.orange)
                    }
                }

                Toggle(
                    "Shared Pinboards",
                    isOn: Binding(
                        get: { store.snapshot.sync.isSharedPinboardsEnabled },
                        set: { store.setSharedPinboardsEnabled($0) }
                    )
                )
                .disabled(!store.syncReadiness.canAttemptCloudSync)

                if store.snapshot.sync.provider != .none {
                    Button("Reset to Local Only") {
                        store.disableCloudSync()
                    }
                }

                Text(store.syncReadiness.detail)
                    .foregroundStyle(.secondary)

                if let statusMessage = store.snapshot.sync.lastSyncStatusMessage {
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                }

                ForEach(store.cloudSyncPreflightReport.findings) { finding in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(finding.severity.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(preflightSeverityColor(finding.severity))
                            Text(finding.title)
                                .font(.subheadline.weight(.semibold))
                        }
                        Text(finding.detail)
                            .foregroundStyle(.secondary)
                        Text(finding.recoveryAction)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(finding.severity.displayName): \(finding.title)")
                    .accessibilityValue("\(finding.detail) \(finding.recoveryAction)")
                }

                Text("CloudKit upload code must be wired only after the signed app has an iCloud container entitlement and an end-to-end key hierarchy. Plaintext fallback is not supported.")
                    .foregroundStyle(.secondary)
            }

            Section("Direct Paste") {
                LabeledContent("Accessibility Access") {
                    Text(AccessibilityPermissionService.isTrusted ? "Enabled" : "Required")
                        .foregroundStyle(AccessibilityPermissionService.isTrusted ? .green : .orange)
                }

                Button("Request Accessibility Access") {
                    AccessibilityPermissionService.requestTrustPrompt()
                }

                LabeledContent("Stable Launch Path") {
                    Text(runtimeIdentity.isRunningFromStablePath ? "Matched" : "Not matched")
                        .foregroundStyle(runtimeIdentity.isRunningFromStablePath ? .green : .orange)
                }

                LabeledContent("Bundle Identifier") {
                    diagnosticText(runtimeIdentity.bundleIdentifier)
                }

                LabeledContent("Bundle Path") {
                    diagnosticText(runtimeIdentity.bundlePath)
                }

                LabeledContent("Executable Path") {
                    diagnosticText(runtimeIdentity.executablePath)
                }

                LabeledContent("Expected App Path") {
                    diagnosticText(runtimeIdentity.stableAppPath)
                }

                LabeledContent("Signing Channel") {
                    diagnosticText(runtimeIdentity.signingChannel)
                }

                LabeledContent("Signing Identity") {
                    diagnosticText(runtimeIdentity.codeSigningIdentity)
                }

                if let result = store.lastDirectPasteResult {
                    LabeledContent("Last Direct Paste") {
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

                Text("Direct paste copies the selected item first, then sends Command-V only when macOS Accessibility access is granted.")
                    .foregroundStyle(.secondary)
            }

            Section("Quality Bar") {
                Text(store.accessibilityLocalizationQualityReport.summary)
                    .foregroundStyle(.secondary)

                LabeledContent("Supported Locales") {
                    Text(store.accessibilityLocalizationQualityReport.supportedLocaleIdentifiers.joined(separator: ", "))
                }

                ForEach(store.accessibilityLocalizationQualityReport.findings) { finding in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label(finding.area.displayName, systemImage: finding.area.systemImageName)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(finding.status.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(qualityStatusColor(finding.status))
                        }

                        Text(finding.title)
                            .font(.caption.weight(.semibold))
                        Text(finding.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(finding.coveredSurfaces.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(finding.area.displayName): \(finding.title)")
                    .accessibilityValue("\(finding.status.displayName). \(finding.detail)")
                }

                LabeledContent("Localization") {
                    Text(store.accessibilityLocalizationQualityReport.localizationReadyStatement)
                }

                LabeledContent("Manual Release Audit") {
                    Text(store.accessibilityLocalizationQualityReport.releaseAuditStatement)
                }
            }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Integrations", systemImage: "point.3.connected.trianglepath.dotted")
            }
        }
        .scenePadding()
        .frame(minWidth: 620, idealWidth: 700, minHeight: 760, idealHeight: 840)
        .confirmationDialog(
            destructiveConfirmation?.title ?? NSLocalizedString("Confirm Action", comment: ""),
            isPresented: isShowingDestructiveConfirmation,
            titleVisibility: .visible
        ) {
            if let destructiveConfirmation {
                Button(destructiveConfirmation.confirmationButtonTitle, role: .destructive) {
                    performDestructiveAction(destructiveConfirmation)
                    self.destructiveConfirmation = nil
                }
            }
            Button("Cancel", role: .cancel) {
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

    private func diagnosticText(_ value: String) -> some View {
        Text(value)
            .font(.caption.monospaced())
            .textSelection(.enabled)
    }

    private func performDestructiveAction(_ action: SettingsDestructiveAction) {
        switch action {
        case .clearUnpinnedHistory:
            store.clearUnpinnedHistory()
        case .clearAllHistory:
            store.clearAllHistoryIncludingPinnedItems()
        case .revokeMCPAccess:
            store.revokeMCPAccess()
        case .clearMCPAuditLog:
            store.clearMCPAccessLog()
        }
    }

    private var protectedSurfaceSummary: String {
        store.privacyPostureReport.protectedSurfaces
            .map(\.displayName)
            .sorted()
            .joined(separator: ", ")
    }

    private var disabledContentTypeSummary: String {
        let disabled = store.privacyPostureReport.disabledContentTypes
            .map(\.displayName)
            .sorted()
        return disabled.isEmpty ? localized("None") : disabled.map { localized($0) }.joined(separator: ", ")
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

    private var syncPreflightSummaryColor: Color {
        if store.cloudSyncPreflightReport.hasBlockers {
            return .orange
        }
        if store.cloudSyncPreflightReport.findings.contains(where: { $0.severity == .warning }) {
            return .orange
        }
        return store.syncReadiness == .ready ? .green : .secondary
    }

    private func preflightSeverityColor(_ severity: CloudSyncDiagnosticSeverity) -> Color {
        switch severity {
        case .info: .secondary
        case .warning, .blocker: .orange
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

    private func qualityStatusColor(_ status: AccessibilityQualityStatus) -> Color {
        switch status {
        case .implemented:
            .green
        case .manualAuditRequired:
            .orange
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
        localized("%@ Settings", localized(destination.displayName))
    }

    private var personalOverview: PersonalEntitlementOverview {
        store.snapshot.entitlement.personalOverview()
    }

    private var teamPlan: TeamPlanConfiguration {
        store.snapshot.entitlement.team ?? TeamPlanConfiguration()
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
            return localized("Keep history forever")
        }
        return localized("Keep normal history for %d days", store.snapshot.storage.retentionDays)
    }

    private var storageLimitDescription: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(store.snapshot.storage.maxStorageBytes),
            countStyle: .file
        )
    }

    private func configureTeamPlan(_ update: (inout TeamPlanConfiguration) -> Void) {
        var team = teamPlan
        update(&team)
        store.configureTeamPlan(
            teamName: team.teamName,
            seatCount: team.seatCount,
            assignedSeatCount: team.assignedSeatCount,
            pricePerSeatCents: team.pricePerSeatCents,
            billingCurrencyCode: team.billingCurrencyCode,
            singleInvoiceEnabled: team.singleInvoiceEnabled,
            managedDistributionEnabled: team.managedDistributionEnabled,
            adminEmailAddress: team.adminEmailAddress
        )
    }

    private func formatCents(_ cents: Int, currencyCode: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        return formatter.string(from: NSNumber(value: Double(cents) / 100)) ?? "\(currencyCode) \(Double(cents) / 100)"
    }
}

private enum SettingsDestructiveAction {
    case clearUnpinnedHistory
    case clearAllHistory
    case revokeMCPAccess
    case clearMCPAuditLog

    var title: String {
        switch self {
        case .clearUnpinnedHistory:
            NSLocalizedString("Clear Unpinned History?", comment: "")
        case .clearAllHistory:
            NSLocalizedString("Clear All History?", comment: "")
        case .revokeMCPAccess:
            NSLocalizedString("Revoke MCP Access?", comment: "")
        case .clearMCPAuditLog:
            NSLocalizedString("Clear MCP Audit Log?", comment: "")
        }
    }

    var message: String {
        switch self {
        case .clearUnpinnedHistory:
            NSLocalizedString("This removes every unpinned clipboard item from local history. Pinned items stay available.", comment: "")
        case .clearAllHistory:
            NSLocalizedString("This removes all local clipboard history, including pinned item memberships. This action cannot be undone.", comment: "")
        case .revokeMCPAccess:
            NSLocalizedString("This disables local MCP access and clears enabled MCP tools until you turn them on again.", comment: "")
        case .clearMCPAuditLog:
            NSLocalizedString("This permanently clears the local MCP access log.", comment: "")
        }
    }

    var confirmationButtonTitle: String {
        switch self {
        case .clearUnpinnedHistory:
            NSLocalizedString("Clear Unpinned History", comment: "")
        case .clearAllHistory:
            NSLocalizedString("Clear All History", comment: "")
        case .revokeMCPAccess:
            NSLocalizedString("Revoke MCP Access", comment: "")
        case .clearMCPAuditLog:
            NSLocalizedString("Clear MCP Audit Log", comment: "")
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
                Button("Clear Shortcut") {
                    store.clearShortcutBinding(action)
                }
                .disabled(!currentBinding.isEnabled)
            }

            TextField("Key", text: Binding(
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
            LabeledContent(title) {
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
        guard !normalized.isEmpty else { return "Digits only" }
        return normalized.map(\.displayName).joined(separator: "+")
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
