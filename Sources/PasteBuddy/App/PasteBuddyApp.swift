import AppKit
import Darwin
import PasteBuddyCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var startRuntime: (() -> Void)? {
        didSet {
            startRuntimeIfReady()
        }
    }
    var flushPendingSave: (() async -> Void)?
    var handleOpenURLs: (([URL]) -> Void)? {
        didSet { deliverPendingOpenURLs() }
    }
    private var didFinishLaunching = false
    private var didRequestRuntimeStart = false
    private var pendingOpenURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        PasteBuddyDiagnostics.recordAccessibilityTrust(
            .directPaste,
            "accessibilityTrustCheckedAtLaunch"
        )
        didFinishLaunching = true
        startRuntimeIfReady()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        flag
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        pendingOpenURLs.append(contentsOf: urls)
        deliverPendingOpenURLs()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        PasteBuddyTerminationCoordinator.flushBeforeTerminating(
            flushPendingSave,
            reply: { shouldTerminate in
                sender.reply(toApplicationShouldTerminate: shouldTerminate)
            }
        )
    }

    private func startRuntimeIfReady() {
        guard didFinishLaunching, !didRequestRuntimeStart, let startRuntime else {
            return
        }
        didRequestRuntimeStart = true
        startRuntime()
    }

    private func deliverPendingOpenURLs() {
        guard let handleOpenURLs, !pendingOpenURLs.isEmpty else { return }
        let urls = pendingOpenURLs
        pendingOpenURLs.removeAll(keepingCapacity: true)
        handleOpenURLs(urls)
    }
}

@main
struct PasteBuddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @AppStorage("clipboardPanelDisplayMode") private var panelDisplayModeRawValue = ClipboardPanelDisplayMode.sidePanel.rawValue
    @AppStorage("clipboardShelfPlacement") private var shelfPlacementRawValue = ClipboardShelfPlacement.top.rawValue
    @State private var store = PasteBuddyStore()
    @State private var monitor: ClipboardMonitor?
    @State private var storeLoadGate = PasteBuddyRuntimeLoadGate()
    @State private var shelfPanelController: ClipboardShelfPanelController?
    @State private var panelHotKeyController: PasteBuddyPanelHotKeyController?
    @State private var statusItemController: PasteBuddyStatusItemController?
    @State private var frontmostApplicationTracker = FrontmostApplicationTracker()
    @State private var irohSync = IrohClipboardSyncService()
    @State private var entitlementExpirationTask: Task<Void, Never>?
    @State private var transactionObserverTask: Task<Void, Never>?
    @State private var didRefreshCurrentStoreEntitlement = false
    @State private var storeEntitlementRefreshFailed = false

    init() {
        Self.printRuntimeDiagnosticsIfNeeded()
        _ = PasteBuddySentryBootstrap.startIfConfigured()
        #if canImport(AppIntents)
        PasteBuddyAppShortcuts.updateAppShortcutParameters()
        #endif
    }

    var body: some Scene {
        let _ = configureAppDelegate()
        Settings {
            SettingsView(
                store: store,
                irohSync: irohSync,
                onOpenPaywall: presentPaywall,
                onEntitlementActivated: handleEntitlementActivated
            )
        }

        Window("brand.pastebuddy_pro", id: "paywall") {
            PasteBuddyPaywallView(
                store: store,
                onEntitlementActivated: handleEntitlementActivated
            )
        }
        .defaultSize(width: 560, height: 700)
        .windowResizability(.contentSize)
    }

    private func configureAppDelegate() {
        appDelegate.startRuntime = {
            Task { @MainActor in
                await startRuntimeIfNeeded()
            }
        }
        appDelegate.handleOpenURLs = { urls in
            Task { @MainActor in
                await handleDevelopmentPanelURLs(urls)
            }
        }
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    private var shelfPlacement: ClipboardShelfPlacement {
        get {
            ClipboardShelfPlacement(rawValue: shelfPlacementRawValue) ?? .top
        }
        nonmutating set {
            shelfPlacementRawValue = newValue.rawValue
            shelfPanelController?.placement = newValue
        }
    }

    private var panelDisplayMode: ClipboardPanelDisplayMode {
        get {
            ClipboardPanelDisplayMode(rawValue: panelDisplayModeRawValue) ?? .sidePanel
        }
        nonmutating set {
            panelDisplayModeRawValue = newValue.rawValue
            shelfPanelController?.displayMode = newValue
            updateStatusItem()
        }
    }

    private func configureStatusItemIfNeeded() {
        if statusItemController == nil {
            statusItemController = PasteBuddyStatusItemController(
                menuProvider: {
                    makeStatusItemMenu()
                },
                primaryAction: {
                    Task { @MainActor in
                        await toggleClipboardShelf()
                    }
                }
            )
        }
        updateStatusItem()
    }

    private func updateStatusItem() {
        var status = store.macMenuBarStatus
        if storeEntitlementRefreshFailed {
            status.title = "status.plan_required"
            status.systemImageName = "lock.fill"
        }
        statusItemController?.update(status: status)
    }

    private func makeStatusItemMenu() -> NSMenu {
        let menu = NSMenu(title: localized("brand.pastebuddy"))
        menu.addItem(PasteBuddyStatusItemController.actionMenuItem(
            localized(store.snapshot.general.launchAtLoginEnabled ? "action.disable_launch_at_login" : "action.enable_launch_at_login"),
            systemImageName: "poweron",
            enabled: LaunchAtLoginService.isAvailable
        ) {
            store.setLaunchAtLoginEnabled(
                !store.snapshot.general.launchAtLoginEnabled,
                applySystemRegistration: LaunchAtLoginService.isAvailable
            )
            updateStatusItem()
        })

        let panelStyleItem = NSMenuItem(title: localized("label.panel_style"), action: nil, keyEquivalent: "")
        panelStyleItem.image = NSImage(
            systemSymbolName: panelDisplayMode.systemImageName,
            accessibilityDescription: localized("label.panel_style")
        )
        let panelStyleMenu = NSMenu(title: localized("label.panel_style"))
        for mode in ClipboardPanelDisplayMode.allCases {
            let item = PasteBuddyStatusItemController.actionMenuItem(
                localized(mode.menuTitleKey),
                systemImageName: mode.systemImageName,
                keyEquivalent: mode == .shelf ? "b" : "",
                keyEquivalentModifierMask: mode == .shelf ? [.command, .shift] : nil
            ) {
                panelDisplayMode = mode
            }
            item.state = panelDisplayMode == mode ? .on : .off
            panelStyleMenu.addItem(item)
        }
        panelStyleItem.submenu = panelStyleMenu
        menu.addItem(panelStyleItem)

        menu.addItem(PasteBuddyStatusItemController.actionMenuItem(
            localized("action.open_settings"),
            systemImageName: "gearshape",
            keyEquivalent: ",",
            keyEquivalentModifierMask: .command
        ) {
            store.clearRequestedSettingsDestination()
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        })

        if storeEntitlementRefreshFailed || !store.snapshot.entitlement.hasActivePaidAccess() {
            menu.addItem(PasteBuddyStatusItemController.actionMenuItem(
                localized("action.view_plans"),
                systemImageName: "creditcard"
            ) {
                presentPaywall()
            })
        }

        menu.addItem(.separator())
        menu.addItem(PasteBuddyStatusItemController.actionMenuItem(
            localized(store.isPasteStackActive ? "action.stop_paste_stack" : "action.start_paste_stack"),
            systemImageName: store.isPasteStackActive ? "stop.fill" : "play.fill"
        ) {
            Task { @MainActor in
                await startRuntimeIfNeeded()
                guard requireFullProductAccessForUserAction() else { return }
                store.togglePasteStack()
            }
        })

        menu.addItem(PasteBuddyStatusItemController.actionMenuItem(
            localized("action.paste_next_stack_item"),
            systemImageName: "text.insert",
            enabled: !store.pasteStackItems.isEmpty
        ) {
            Task { @MainActor in
                await startRuntimeIfNeeded()
                guard requireFullProductAccessForUserAction() else { return }
                if let item = store.pasteNextStackItem() {
                    store.recordDirectPasteResult(
                        await Self.pasteItemToTarget(
                            item,
                            format: store.defaultPasteFormat,
                            tracker: frontmostApplicationTracker
                        )
                    )
                }
            }
        })

        menu.addItem(.separator())
        menu.addItem(PasteBuddyStatusItemController.actionMenuItem(
            localized("action.quit_app"),
            systemImageName: "power",
            keyEquivalent: "q",
            keyEquivalentModifierMask: .command
        ) {
            NSApp.terminate(nil)
        })
        return menu
    }

    private func toggleClipboardShelf() async {
        await startRuntimeIfNeeded()
        guard requireFullProductAccessForUserAction() else { return }
        PasteBuddyDiagnostics.recordAccessibilityTrust(
            .shelf,
            "accessibilityTrustCheckedBeforeShelfToggle"
        )
        frontmostApplicationTracker.recordCurrentFrontmostApplication()
        if let target = frontmostApplicationTracker.currentExternalApplication() {
            PasteBuddyDiagnostics.record(
                .hotKey,
                "targetRecordedBeforeShelfToggle",
                detail: "bundle=\(target.bundleIdentifier ?? "nil") name=\(target.localizedName)"
            )
        } else {
            PasteBuddyDiagnostics.record(.hotKey, "targetMissingBeforeShelfToggle")
        }
        shelfPanelController?.toggle()
    }

    private func handleDevelopmentPanelURLs(_ urls: [URL]) async {
        for url in urls {
            guard let command = PasteBuddyDevelopmentPanelCommand.parse(
                url,
                identity: PasteBuddyRuntimeIdentityService.current
            ) else {
                PasteBuddyDiagnostics.record(.shelf, "developmentURLRejected")
                continue
            }

            PasteBuddyDiagnostics.record(.shelf, "developmentURLAccepted")
            switch command {
            case .show(let mode):
                await showClipboardPanelMode(mode)
            case .toggle:
                await toggleClipboardShelf()
            }
        }
    }

    private func showClipboardShelfMode() async {
        await showClipboardPanelMode(.shelf)
    }

    private func showClipboardPanelMode(_ mode: ClipboardPanelDisplayMode) async {
        await startRuntimeIfNeeded()
        guard requireFullProductAccessForUserAction() else { return }
        frontmostApplicationTracker.recordCurrentFrontmostApplication()
        PasteBuddyDiagnostics.record(.hotKey, "\(mode.rawValue)ModeRequested")
        panelDisplayMode = mode
        shelfPanelController?.placement = shelfPlacement
        shelfPanelController?.show()
    }

    private func startRuntimeIfNeeded() async {
        appDelegate.flushPendingSave = { [store] in
            await store.flushPendingSave()
        }

        await storeLoadGate.loadIfNeeded {
            await store.loadAsync()
        }
        configureStatusItemIfNeeded()
        var canStartFreeTrial = didRefreshCurrentStoreEntitlement
        if !didRefreshCurrentStoreEntitlement {
            do {
                _ = try await store.refreshCurrentStoreEntitlement(
                    using: AppleStoreKitEntitlementProvider()
                )
                guard await store.flushPendingSave() else {
                    storeEntitlementRefreshFailed = true
                    updateStatusItem()
                    PasteBuddyDiagnostics.record(.lifecycle, "currentEntitlementPersistenceFailed")
                    return
                }
                didRefreshCurrentStoreEntitlement = true
                storeEntitlementRefreshFailed = false
                canStartFreeTrial = true
                updateStatusItem()
            } catch {
                store.recordStoreTransactionUpdateError(error)
                PasteBuddyDiagnostics.record(
                    .lifecycle,
                    "currentEntitlementRefreshFailed",
                    detail: error.localizedDescription
                )
                canStartFreeTrial = false
                guard store.snapshot.entitlement.isTrialActive() else {
                    storeEntitlementRefreshFailed = true
                    stopProtectedRuntime()
                    return
                }
                storeEntitlementRefreshFailed = false
                updateStatusItem()
            }
        }
        if canStartFreeTrial, store.startFreeTrialIfEligible(days: 7) {
            guard await store.flushPendingSave() else {
                PasteBuddyDiagnostics.record(.lifecycle, "freeTrialPersistenceFailed")
                return
            }
        }
        if store.expireFreeTrialIfNeeded() {
            _ = await store.flushPendingSave()
        }
        startStoreTransactionObserverIfNeeded()
        scheduleEntitlementExpirationIfNeeded()
        guard !store.isPersistenceWriteBlocked else {
            PasteBuddyDiagnostics.record(
                .lifecycle,
                "runtimeStartBlockedByHistoryLoadFailure",
                detail: store.lastErrorMessage
            )
            return
        }
        guard store.hasFullProductAccess else {
            stopProtectedRuntime()
            return
        }
        frontmostApplicationTracker.start()
        irohSync.onItemReceived = { [store] item in
            guard !store.isPersistenceWriteBlocked else { return }
            _ = store.addSyncedItem(item)
        }
        // Peers (iOS) cannot fetch link previews themselves, so re-send items
        // once enrichment upgrades them; the receiver merges via dedupe.
        store.onLinkPreviewMetadataEnriched = { [irohSync] item in
            Task { @MainActor in
                await irohSync.sendIfConnected(item)
            }
        }
        await irohSync.start()

        if monitor == nil {
            let createdMonitor = ClipboardMonitor(
                store: store,
                onItemCaptured: { [irohSync] item in
                    Task { @MainActor in
                        await irohSync.sendIfConnected(item)
                    }
                }
            )
            createdMonitor.start()
            monitor = createdMonitor
        }

        if shelfPanelController == nil {
            let statusController = statusItemController
            shelfPanelController = ClipboardShelfPanelController(
                store: store,
                placement: shelfPlacement,
                displayMode: panelDisplayMode,
                directPasteItem: { item, format in
                    let hydratedItem = await store.hydratedItem(for: item)
                    return await Self.pasteItemToTarget(hydratedItem, format: format, tracker: frontmostApplicationTracker)
                },
                directPasteItems: { items, format in
                    let hydratedItems = await store.hydratedItems(for: items)
                    return await Self.pasteItemsToTarget(hydratedItems, format: format, tracker: frontmostApplicationTracker)
                },
                shouldIgnoreDismissalAt: { point in
                    statusController?.containsScreenPoint(point) == true
                }
            )
        }
        shelfPanelController?.displayMode = panelDisplayMode
        shelfPanelController?.placement = shelfPlacement

        if panelHotKeyController == nil, shelfPanelController != nil {
            panelHotKeyController = PasteBuddyPanelHotKeyController(
                onToggle: {
                    Task { @MainActor in
                        await toggleClipboardShelf()
                    }
                },
                onShelfMode: {
                    Task { @MainActor in
                        await showClipboardShelfMode()
                    }
                }
            )
        }
    }

    private func requireFullProductAccessForUserAction() -> Bool {
        guard !storeEntitlementRefreshFailed, store.hasFullProductAccess else {
            presentPaywall()
            return false
        }
        return true
    }

    private func presentPaywall() {
        shelfPanelController?.hide()
        openWindow(id: "paywall")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleEntitlementActivated() async {
        // Purchase and restore callbacks reach this point only after StoreKit
        // verification and durable persistence have both succeeded.
        didRefreshCurrentStoreEntitlement = true
        storeEntitlementRefreshFailed = false
        entitlementExpirationTask?.cancel()
        entitlementExpirationTask = nil
        updateStatusItem()
        await startRuntimeIfNeeded()
    }

    private func startStoreTransactionObserverIfNeeded() {
        guard transactionObserverTask == nil else { return }
        let observer = StoreTransactionUpdateObserver(
            provider: AppleStoreKitEntitlementProvider()
        )
        transactionObserverTask = Task { @MainActor in
            defer { transactionObserverTask = nil }
            var failureCount = 0

            while !Task.isCancelled {
                let shouldRetry = await observer.run(
                    onUpdate: { update in
                        do {
                            _ = try await store.refreshCurrentStoreEntitlement(
                                using: AppleStoreKitEntitlementProvider()
                            )
                            await MainActor.run {
                                scheduleEntitlementExpirationIfNeeded()
                                updateStatusItem()
                                if !store.hasFullProductAccess {
                                    stopProtectedRuntime()
                                }
                            }
                            let didPersist = await store.flushPendingSave()
                            await MainActor.run {
                                if didPersist {
                                    didRefreshCurrentStoreEntitlement = true
                                }
                                storeEntitlementRefreshFailed = !didPersist
                                updateStatusItem()
                                if PasteBuddyEntitlementRuntimePolicy.canStartAfterPersistence(
                                    store.snapshot.entitlement,
                                    didPersist: didPersist
                                ) {
                                    Task { @MainActor in
                                        await startRuntimeIfNeeded()
                                    }
                                } else {
                                    if !didPersist {
                                        PasteBuddyDiagnostics.record(
                                            .lifecycle,
                                            "storeEntitlementPersistenceFailed"
                                        )
                                    }
                                    stopProtectedRuntime()
                                }
                            }
                        } catch {
                            await MainActor.run {
                                store.recordStoreTransactionUpdateError(error)
                                PasteBuddyDiagnostics.record(
                                    .lifecycle,
                                    "storeEntitlementReconciliationFailed",
                                    detail: error.localizedDescription
                                )
                                if PasteBuddyEntitlementRuntimePolicy.shouldStopAfterFailedReconciliation(
                                    update,
                                    cachedEntitlement: store.snapshot.entitlement
                                ) {
                                    didRefreshCurrentStoreEntitlement = false
                                    storeEntitlementRefreshFailed = true
                                    stopProtectedRuntime()
                                }
                            }
                        }
                    },
                    onError: { error in
                        await MainActor.run {
                            store.recordStoreTransactionUpdateError(error)
                            PasteBuddyDiagnostics.record(
                                .lifecycle,
                                "storeTransactionObserverFailed",
                                detail: error.localizedDescription
                            )
                        }
                    }
                )

                guard shouldRetry, !Task.isCancelled else { return }
                failureCount += 1
                let retryDelay = PasteBuddyStoreTransactionRetryPolicy.delaySeconds(
                    afterFailure: failureCount
                )
                PasteBuddyDiagnostics.record(
                    .lifecycle,
                    "storeTransactionObserverRetryScheduled",
                    detail: "attempt=\(failureCount) delaySeconds=\(retryDelay)"
                )
                do {
                    try await Task.sleep(for: .seconds(retryDelay))
                } catch {
                    return
                }
            }
        }
    }

    private func scheduleEntitlementExpirationIfNeeded() {
        entitlementExpirationTask?.cancel()
        entitlementExpirationTask = nil
        guard let deadline = PasteBuddyEntitlementRuntimePolicy.accessDeadline(
            for: store.snapshot.entitlement
        ) else { return }

        let delay = deadline.timeIntervalSinceNow
        guard delay > 0 else {
            handleEntitlementDeadline(deadline)
            return
        }

        entitlementExpirationTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            handleEntitlementDeadline(deadline)
        }
    }

    private func handleEntitlementDeadline(_ deadline: Date) {
        guard PasteBuddyEntitlementRuntimePolicy.accessDeadline(
            for: store.snapshot.entitlement
        ) == deadline else {
            scheduleEntitlementExpirationIfNeeded()
            return
        }

        let now = Date()
        guard deadline <= now else {
            scheduleEntitlementExpirationIfNeeded()
            return
        }

        let didChange: Bool
        if store.snapshot.entitlement.plan == .trial {
            didChange = store.expireFreeTrialIfNeeded(now: now)
        } else if store.snapshot.entitlement.status == .active {
            store.markEntitlementExpired(at: deadline)
            didChange = true
        } else {
            didChange = false
        }

        if didChange {
            Task { @MainActor in
                _ = await store.flushPendingSave()
            }
        }
        if store.snapshot.entitlement.hasFullAccess(now: now) {
            scheduleEntitlementExpirationIfNeeded()
        } else {
            PasteBuddyDiagnostics.record(.lifecycle, "entitlementDeadlineReached")
            stopProtectedRuntime()
        }
    }

    private func stopProtectedRuntime() {
        monitor?.stop()
        monitor = nil
        irohSync.stop()
        shelfPanelController?.hide()
        updateStatusItem()
    }

    private static func pasteItemToTarget(
        _ item: ClipboardItem,
        format: PasteFormat,
        tracker: FrontmostApplicationTracker
    ) async -> DirectPasteResult {
        PasteBuddyDiagnostics.record(.directPaste, "singleItemRequested", detail: "format=\(format.rawValue)")
        let isAccessibilityTrusted = AccessibilityPermissionService.isTrusted
        PasteBuddyDiagnostics.record(
            .directPaste,
            "accessibilityTrustChecked",
            detail: "trusted=\(isAccessibilityTrusted)"
        )
        guard isAccessibilityTrusted else {
            PasteBuddyDiagnostics.record(.directPaste, "accessibilityMissing")
            return DirectPasteResult(
                outcome: .failedAccessibilityPermissionRequired,
                itemCount: 1,
                format: format
            )
        }
        guard let target = tracker.currentExternalApplication(),
              let targetBundleIdentifier = target.bundleIdentifier else {
            PasteBuddyDiagnostics.record(.directPaste, "targetMissing")
            return DirectPasteResult(
                outcome: .failedNoTargetApplication,
                itemCount: 1,
                format: format
            )
        }
        PasteBuddyDiagnostics.record(
            .directPaste,
            "targetSelected",
            detail: "bundle=\(targetBundleIdentifier) name=\(target.localizedName)"
        )
        let options = notificationDrivenDirectPasteOptions()
        let requestedActivation = tracker.activateLastExternalApplication()
        PasteBuddyDiagnostics.record(
            .directPaste,
            "activateTargetRequested",
            detail: "bundle=\(targetBundleIdentifier) requested=\(requestedActivation)"
        )
        guard await tracker.waitForActivation(
            of: targetBundleIdentifier,
            timeout: options.activationWaitTimeout
        ) else {
            PasteBuddyDiagnostics.record(.directPaste, "targetActivationTimedOut", detail: "bundle=\(targetBundleIdentifier)")
            return DirectPasteResult(
                outcome: .failedNoTargetApplication,
                itemCount: 1,
                format: format
            )
        }
        let result = await PasteboardWriter.pasteToFrontmostAppAsync(
            item,
            format: format,
            options: options
        )
        PasteBuddyDiagnostics.record(.directPaste, "writerFinished", detail: "outcome=\(result.outcome.rawValue)")
        return result
    }

    private static func pasteItemsToTarget(
        _ items: [ClipboardItem],
        format: PasteFormat,
        tracker: FrontmostApplicationTracker
    ) async -> DirectPasteResult {
        PasteBuddyDiagnostics.record(.directPaste, "multiItemRequested", detail: "count=\(items.count) format=\(format.rawValue)")
        guard !items.isEmpty else {
            PasteBuddyDiagnostics.record(.directPaste, "emptySelection")
            return DirectPasteResult(outcome: .emptySelection, itemCount: 0, format: format)
        }
        let isAccessibilityTrusted = AccessibilityPermissionService.isTrusted
        PasteBuddyDiagnostics.record(
            .directPaste,
            "accessibilityTrustChecked",
            detail: "trusted=\(isAccessibilityTrusted)"
        )
        guard isAccessibilityTrusted else {
            PasteBuddyDiagnostics.record(.directPaste, "accessibilityMissing")
            return DirectPasteResult(
                outcome: .failedAccessibilityPermissionRequired,
                itemCount: items.count,
                format: format
            )
        }
        guard let target = tracker.currentExternalApplication(),
              let targetBundleIdentifier = target.bundleIdentifier else {
            PasteBuddyDiagnostics.record(.directPaste, "targetMissing")
            return DirectPasteResult(
                outcome: .failedNoTargetApplication,
                itemCount: items.count,
                format: format
            )
        }
        PasteBuddyDiagnostics.record(
            .directPaste,
            "targetSelected",
            detail: "bundle=\(targetBundleIdentifier) name=\(target.localizedName)"
        )
        let options = notificationDrivenDirectPasteOptions()
        let requestedActivation = tracker.activateLastExternalApplication()
        PasteBuddyDiagnostics.record(
            .directPaste,
            "activateTargetRequested",
            detail: "bundle=\(targetBundleIdentifier) requested=\(requestedActivation)"
        )
        guard await tracker.waitForActivation(
            of: targetBundleIdentifier,
            timeout: options.activationWaitTimeout
        ) else {
            PasteBuddyDiagnostics.record(.directPaste, "targetActivationTimedOut", detail: "bundle=\(targetBundleIdentifier)")
            return DirectPasteResult(
                outcome: .failedNoTargetApplication,
                itemCount: items.count,
                format: format
            )
        }
        let result = await PasteboardWriter.pasteToFrontmostAppAsync(
            items,
            format: format,
            options: options
        )
        PasteBuddyDiagnostics.record(.directPaste, "writerFinished", detail: "outcome=\(result.outcome.rawValue)")
        return result
    }

    private static func notificationDrivenDirectPasteOptions() -> PasteboardWriter.DirectPasteOptions {
        let configured = PasteboardWriter.userConfiguredPasteOnlyDirectPasteOptions
        return PasteboardWriter.DirectPasteOptions(
            activationWaitTimeout: configured.activationWaitTimeout,
            pasteDispatchDelay: 0,
            fallbackBehavior: .failWithoutCopying
        )
    }

    private static func printRuntimeDiagnosticsIfNeeded() {
        guard CommandLine.arguments.contains("--print-runtime-diagnostics") else {
            return
        }

        let identity = PasteBuddyRuntimeIdentityService.current
        print("accessibilityTrusted=\(AccessibilityPermissionService.isTrusted)")
        print("stableLaunchPathMatched=\(identity.isRunningFromStablePath)")
        print("bundleIdentifier=\(identity.bundleIdentifier)")
        print("bundlePath=\(identity.bundlePath)")
        print("executablePath=\(identity.executablePath)")
        print("expectedAppPath=\(identity.stableAppPath)")
        print("signingChannel=\(identity.signingChannel)")
        print("signingIdentity=\(identity.codeSigningIdentity)")
        let sentryConfiguration = PasteBuddySentryConfiguration.make()
        print("sentryConfigured=\(sentryConfiguration != nil)")
        print("sentryEnvironment=\(sentryConfiguration?.environment ?? "not-configured")")
        Darwin.exit(EXIT_SUCCESS)
    }
}

@MainActor
final class PasteBuddyRuntimeLoadGate {
    private var didLoadStore = false
    private var inFlightLoad: Task<Void, Never>?

    func loadIfNeeded(
        _ loadAsync: @escaping @MainActor @Sendable () async -> Void
    ) async {
        guard !didLoadStore else { return }
        if let inFlightLoad {
            await inFlightLoad.value
            return
        }

        let task = Task { @MainActor in
            await loadAsync()
        }
        inFlightLoad = task
        await task.value
        inFlightLoad = nil
        didLoadStore = true
    }
}

@MainActor
enum PasteBuddyTerminationCoordinator {
    static func flushBeforeTerminating(
        _ flushPendingSave: (() async -> Void)?,
        reply: @escaping (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        guard let flushPendingSave else { return .terminateNow }

        Task { @MainActor in
            await flushPendingSave()
            reply(true)
        }
        return .terminateLater
    }
}

enum PasteBuddyEntitlementRuntimePolicy {
    static func accessDeadline(for entitlement: EntitlementConfiguration) -> Date? {
        if entitlement.plan == .trial {
            return entitlement.trialEndsAt
        }
        return [entitlement.currentPeriodEndsAt, entitlement.expiresAt]
            .compactMap { $0 }
            .min()
    }

    static func shouldStopAfterFailedReconciliation(
        _ update: StoreEntitlementUpdate,
        cachedEntitlement: EntitlementConfiguration
    ) -> Bool {
        guard !update.entitlement.hasFullAccess(now: update.receivedAt),
              update.entitlement.plan == cachedEntitlement.plan else {
            return false
        }
        guard let cachedPurchaseDate = cachedEntitlement.purchasedAt else {
            return true
        }
        return update.transaction.purchaseDate >= cachedPurchaseDate
    }

    static func canStartAfterPersistence(
        _ entitlement: EntitlementConfiguration,
        didPersist: Bool,
        now: Date = Date()
    ) -> Bool {
        didPersist && entitlement.hasFullAccess(now: now)
    }
}

enum PasteBuddyStoreTransactionRetryPolicy {
    static func delaySeconds(afterFailure failureCount: Int) -> TimeInterval {
        let exponent = min(max(failureCount - 1, 0), 5)
        return TimeInterval(min(1 << exponent, 30))
    }
}

private extension String {
    var menuBarTitle: String {
        let preview = singleLinePreview
        if preview.count <= 30 {
            return preview
        }
        return String(preview.prefix(27)) + "..."
    }
}
