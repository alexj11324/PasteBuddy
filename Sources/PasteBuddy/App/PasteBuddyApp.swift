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

enum PasteBuddyRuntimeState: Equatable {
    case loading
    case ready
    case unavailable(String)

    init(isStoreLoaded: Bool, persistenceErrorMessage: String?) {
        if let persistenceErrorMessage {
            self = .unavailable(persistenceErrorMessage)
        } else if isStoreLoaded {
            self = .ready
        } else {
            self = .loading
        }
    }

    var isReady: Bool {
        self == .ready
    }
}

@MainActor
final class PasteBuddyLaunchPerformanceTracker {
    private var didStart = false
    private var didFinish = false
    private var interval: PasteBuddyPerformanceSignposts.Interval?

    @discardableResult
    func begin() -> Bool {
        guard !didStart else { return false }
        didStart = true
        interval = PasteBuddyPerformanceSignposts.begin(.appLaunchToStoreReady)
        return true
    }

    @discardableResult
    func finish(
        itemCount: PasteBuddyPerformanceSignposts.ItemCountBucket = .unknown,
        result: PasteBuddyPerformanceSignposts.ResultCode
    ) -> Bool {
        guard didStart, !didFinish else { return false }
        didFinish = true
        let interval = interval
        self.interval = nil
        PasteBuddyPerformanceSignposts.end(
            interval,
            itemCount: itemCount,
            result: result
        )
        return true
    }
}

@main
struct PasteBuddyApp: App {
    private static let launchPerformanceTracker = PasteBuddyLaunchPerformanceTracker()

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openSettings) private var openSettings
    @AppStorage("clipboardPanelDisplayMode") private var panelDisplayModeRawValue = ClipboardPanelDisplayMode.sidePanel.rawValue
    @AppStorage("clipboardShelfPlacement") private var shelfPlacementRawValue = ClipboardShelfPlacement.top.rawValue
    @State private var store: PasteBuddyStore?
    @State private var isStoreLoaded = false
    @State private var persistenceErrorMessage: String?
    @State private var monitor: ClipboardMonitor?
    @State private var storeLoadGate = PasteBuddyRuntimeLoadGate()
    @State private var shelfPanelController: ClipboardShelfPanelController?
    @State private var panelHotKeyController: PasteBuddyPanelHotKeyController?
    @State private var statusItemController: PasteBuddyStatusItemController?
    @State private var frontmostApplicationTracker = FrontmostApplicationTracker()
    @State private var irohSync = IrohClipboardSyncService()

    init() {
        Self.launchPerformanceTracker.begin()
        do {
            _store = State(initialValue: try PasteBuddyStoreFactory.makeDefault())
            _persistenceErrorMessage = State(initialValue: nil)
        } catch {
            _store = State(initialValue: nil)
            _persistenceErrorMessage = State(
                initialValue: PasteBuddyPersistenceError.historyUnavailable.localizedDescription
            )
        }
        Self.printRuntimeDiagnosticsIfNeeded()
        _ = PasteBuddySentryBootstrap.startIfConfigured()
        #if canImport(AppIntents)
        PasteBuddyAppShortcuts.updateAppShortcutParameters()
        #endif
    }

    var body: some Scene {
        let _ = configureAppDelegate()
        Settings {
            switch runtimeState {
            case .unavailable(let message):
                PasteBuddyHistoryUnavailableView(
                    message: message
                )
            case .ready:
                if let store {
                    SettingsView(store: store, irohSync: irohSync)
                }
            case .loading:
                ProgressView(localized("message.loading_clipboard_history"))
                    .frame(minWidth: 520, minHeight: 320)
            }
        }
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

    private var runtimeState: PasteBuddyRuntimeState {
        PasteBuddyRuntimeState(
            isStoreLoaded: isStoreLoaded,
            persistenceErrorMessage: persistenceErrorMessage
        )
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
                        if !runtimeState.isReady || store == nil {
                            openSettings()
                            NSApp.activate(ignoringOtherApps: true)
                        } else {
                            await toggleClipboardShelf()
                        }
                    }
                }
            )
        }
        updateStatusItem()
    }

    private func updateStatusItem() {
        switch runtimeState {
        case .ready:
            guard let store else { return }
            statusItemController?.update(status: store.macMenuBarStatus)
        case .loading:
            statusItemController?.updateLoading(
                message: localized("message.loading_clipboard_history")
            )
        case .unavailable(let message):
            statusItemController?.updateUnavailable(message: message)
        }
    }

    private func makeRestrictedStatusItemMenu(message: String) -> NSMenu {
        PasteBuddyStatusItemController.restrictedMenu(
            title: localized("brand.pastebuddy"),
            statusMessage: message,
            settingsTitle: localized("action.open_settings"),
            quitTitle: localized("action.quit_app"),
            onOpenSettings: {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )
    }

    private func makeStatusItemMenu() -> NSMenu {
        guard runtimeState.isReady, let store else {
            let message = switch runtimeState {
            case .loading:
                localized("message.loading_clipboard_history")
            case .unavailable(let message):
                message
            case .ready:
                PasteBuddyPersistenceError.historyUnavailable.localizedDescription
            }
            return makeRestrictedStatusItemMenu(message: message)
        }
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

        menu.addItem(.separator())
        menu.addItem(PasteBuddyStatusItemController.actionMenuItem(
            localized(store.isPasteStackActive ? "action.stop_paste_stack" : "action.start_paste_stack"),
            systemImageName: store.isPasteStackActive ? "stop.fill" : "play.fill"
        ) {
            store.togglePasteStack()
        })

        menu.addItem(PasteBuddyStatusItemController.actionMenuItem(
            localized("action.paste_next_stack_item"),
            systemImageName: "text.insert",
            enabled: !store.pasteStackItems.isEmpty
        ) {
            Task { @MainActor in
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
        guard runtimeState.isReady else { return }
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
        guard runtimeState.isReady else { return }
        frontmostApplicationTracker.recordCurrentFrontmostApplication()
        PasteBuddyDiagnostics.record(.hotKey, "\(mode.rawValue)ModeRequested")
        panelDisplayMode = mode
        shelfPanelController?.placement = shelfPlacement
        shelfPanelController?.show()
    }

    private func startRuntimeIfNeeded() async {
        if case .unavailable = runtimeState {
            finishLaunchPerformanceSignpost(result: .failed)
            configureStatusItemIfNeeded()
            PasteBuddyDiagnostics.record(
                .lifecycle,
                "runtimeStartBlockedByUnavailableHistory"
            )
            return
        }
        guard let store else {
            finishLaunchPerformanceSignpost(result: .failed)
            configureStatusItemIfNeeded()
            PasteBuddyDiagnostics.record(
                .lifecycle,
                "runtimeStartBlockedByHistoryConstructionFailure"
            )
            return
        }
        let loadResult = await storeLoadGate.loadIfNeeded(
            onLoading: {
                configureStatusItemIfNeeded()
            },
            {
                try await PasteBuddyStoreFactory.load(store)
            }
        )
        if case .failure(let error) = loadResult {
            await transitionToHistoryUnavailable(error)
        } else {
            isStoreLoaded = true
            persistenceErrorMessage = nil
            updateStatusItem()
            finishLaunchPerformanceSignpost(
                itemCount: .init(itemCount: store.snapshot.items.count),
                result: .succeeded
            )
        }
        guard case .success = loadResult else {
            finishLaunchPerformanceSignpost(result: .failed)
            PasteBuddyDiagnostics.record(
                .lifecycle,
                "runtimeStartBlockedByHistoryLoadFailure",
                detail: "historyLoadFailed"
            )
            return
        }
        frontmostApplicationTracker.start()
        appDelegate.flushPendingSave = { [store] in
            await store.flushPendingSave()
        }
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
            let shouldStartClipboardMonitor = PasteBuddyClipboardMonitoringPolicy.shouldStartMonitor(
                disableForDevelopmentVerification: Bundle.main.object(
                    forInfoDictionaryKey: PasteBuddyClipboardMonitoringPolicy.infoDictionaryKey
                ) as? Bool == true,
                identity: PasteBuddyRuntimeIdentityService.current
            )
            if shouldStartClipboardMonitor {
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
            } else {
                PasteBuddyDiagnostics.record(
                    .lifecycle,
                    "clipboardMonitorDisabledForDevelopmentVerification"
                )
            }
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
                },
                onHistoryUnavailable: { error in
                    await transitionToHistoryUnavailable(error)
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

    private func finishLaunchPerformanceSignpost(
        itemCount: PasteBuddyPerformanceSignposts.ItemCountBucket = .unknown,
        result: PasteBuddyPerformanceSignposts.ResultCode
    ) {
        Self.launchPerformanceTracker.finish(
            itemCount: itemCount,
            result: result
        )
    }

    private func transitionToHistoryUnavailable(_ error: PasteBuddyPersistenceError) async {
        isStoreLoaded = false
        persistenceErrorMessage = error.localizedDescription
        monitor?.stop()
        monitor = nil
        frontmostApplicationTracker.stop()
        shelfPanelController?.hideImmediately()
        shelfPanelController = nil
        panelHotKeyController = nil
        irohSync.onItemReceived = nil
        store?.onLinkPreviewMetadataEnriched = nil
        appDelegate.flushPendingSave = nil
        updateStatusItem()
        await irohSync.stop()
        PasteBuddyDiagnostics.record(
            .lifecycle,
            "runtimeTransitionedToUnavailableHistory",
            detail: "historyUnavailable"
        )
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

private struct PasteBuddyHistoryUnavailableView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.lock")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(minWidth: 520, minHeight: 320)
    }
}

@MainActor
final class PasteBuddyRuntimeLoadGate {
    private var completedResult: Result<Void, PasteBuddyPersistenceError>?
    private var inFlightLoad: Task<Result<Void, PasteBuddyPersistenceError>, Never>?

    func loadIfNeeded(
        onLoading: @escaping @MainActor () -> Void = {},
        _ loadAsync: @escaping @MainActor @Sendable () async throws -> Void
    ) async -> Result<Void, PasteBuddyPersistenceError> {
        if let completedResult {
            return completedResult
        }
        if let inFlightLoad {
            return await inFlightLoad.value
        }

        onLoading()
        let task = Task { @MainActor () -> Result<Void, PasteBuddyPersistenceError> in
            do {
                try await loadAsync()
                return .success(())
            } catch {
                return .failure(.historyUnavailable)
            }
        }
        inFlightLoad = task
        let result = await task.value
        inFlightLoad = nil
        completedResult = result
        return result
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

private extension String {
    var menuBarTitle: String {
        let preview = singleLinePreview
        if preview.count <= 30 {
            return preview
        }
        return String(preview.prefix(27)) + "..."
    }
}
