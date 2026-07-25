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
    private var didFinishLaunching = false
    private var didRequestRuntimeStart = false

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
}

@main
struct PasteBuddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openSettings) private var openSettings
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
            SettingsView(store: store, irohSync: irohSync)
        }
    }

    private func configureAppDelegate() {
        appDelegate.startRuntime = {
            Task { @MainActor in
                await startRuntimeIfNeeded()
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
        statusItemController?.update(status: store.macMenuBarStatus)
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

    private func showClipboardPanel(_ displayMode: ClipboardPanelDisplayMode) async {
        await startRuntimeIfNeeded()
        PasteBuddyDiagnostics.record(.hotKey, "panelModeRequested", detail: "mode=\(displayMode.rawValue)")
        panelDisplayMode = displayMode
        shelfPanelController?.show()
    }

    private func startRuntimeIfNeeded() async {
        frontmostApplicationTracker.start()
        appDelegate.flushPendingSave = { [store] in
            await store.flushPendingSave()
        }

        configureStatusItemIfNeeded()
        await storeLoadGate.loadIfNeeded {
            await store.loadAsync()
        }
        irohSync.onItemReceived = { [store] item in
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
                    await Self.pasteItemToTarget(item, format: format, tracker: frontmostApplicationTracker)
                },
                directPasteItems: { items, format in
                    await Self.pasteItemsToTarget(items, format: format, tracker: frontmostApplicationTracker)
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
                onSidePanel: {
                    Task { @MainActor in
                        await showClipboardPanel(.sidePanel)
                    }
                },
                onShelf: {
                    Task { @MainActor in
                        await showClipboardPanel(.shelf)
                    }
                }
            )
        }
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

    func loadIfNeeded(_ loadAsync: () async -> Void) async {
        guard !didLoadStore else { return }
        didLoadStore = true
        await loadAsync()
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
