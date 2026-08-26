import AppKit
import Darwin
import PasteBuddyCore
import SwiftUI

protocol PasteBuddyScreenSharingProtectedWindow: AnyObject {}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var startRuntime: (() -> Void)? {
        didSet {
            startRuntimeIfReady()
        }
    }
    var handleDevelopmentURL: ((URL) -> Void)? {
        didSet {
            guard let handleDevelopmentURL else { return }
            pendingDevelopmentURLs.forEach(handleDevelopmentURL)
            pendingDevelopmentURLs.removeAll()
        }
    }
    var flushPendingSave: (() async -> Void)?
    var screenSharingVisibilityProvider: (() -> Bool)?
    private var didFinishLaunching = false
    private var didRequestRuntimeStart = false
    private var pendingDevelopmentURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        PasteBuddyDiagnostics.recordAccessibilityTrust(
            .directPaste,
            "accessibilityTrustCheckedAtLaunch"
        )
        didFinishLaunching = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowOcclusionStateDidChange(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: nil
        )
        startRuntimeIfReady()
    }

    @objc private func windowOcclusionStateDidChange(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let isVisible = screenSharingVisibilityProvider?() else { return }
        window.sharingType = PasteBuddyApp.screenSharingType(for: window, showContent: isVisible)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        flag
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let handleDevelopmentURL else {
            pendingDevelopmentURLs.append(contentsOf: urls)
            return
        }
        urls.forEach(handleDevelopmentURL)
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
    @State private var mcpHTTPServer = PasteBuddyMCPHTTPServer()
    @State private var cloudSyncTask: Task<Void, Never>?
    @State private var transactionUpdateTask: Task<Void, Never>?

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
                panelDisplayMode: Binding(
                    get: { panelDisplayMode },
                    set: { panelDisplayMode = $0 }
                ),
                mcpHTTPServer: mcpHTTPServer,
                onCloudSyncConfigurationChanged: { isEnabled in
                    updateCloudSyncRuntime(isEnabled: isEnabled)
                }
            )
        }
        .defaultSize(width: 640, height: 560)
        .windowToolbarStyle(.unified(showsTitle: true))
    }

    private func configureAppDelegate() {
        appDelegate.startRuntime = {
            Task { @MainActor in
                await startRuntimeIfNeeded()
            }
        }
        appDelegate.handleDevelopmentURL = { url in
            guard let command = PasteBuddyDevelopmentCommand(
                url: url,
                bundleIdentifier: Bundle.main.bundleIdentifier
            ) else {
                return
            }
            Task { @MainActor in
                switch command {
                case .openPanel(let displayMode):
                    await showClipboardPanel(displayMode)
                }
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
            localized("action.pin_clipboard_to_screen"),
            systemImageName: "pin.square",
            keyEquivalent: "p",
            keyEquivalentModifierMask: [.command, .shift]
        ) {
            Task { @MainActor in
                await startRuntimeIfNeeded()
                ScreenPinController.shared.pinClipboard()
            }
        })
        menu.addItem(screenPinsMenuItem())
        menu.addItem(.separator())
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
                guard let item = store.nextPasteStackItem else { return }
                do {
                    let hydrated = try await store.hydratedItemForTransfer(item)
                    let result = if store.snapshot.settingsBehavior.pasteDestination == .clipboard {
                        Self.copyItemToClipboard(
                            hydrated,
                            format: store.defaultPasteFormat,
                            soundEffectsEnabled: store.snapshot.settingsBehavior.soundEffectsEnabled
                        )
                    } else {
                        await Self.pasteItemToTarget(
                            hydrated,
                            format: store.defaultPasteFormat,
                            tracker: frontmostApplicationTracker
                        )
                    }
                    if result.didTransferContent {
                        store.commitNextPasteStackItem(id: item.id)
                    }
                    store.recordDirectPasteResult(result)
                } catch {
                    store.lastErrorMessage = error.localizedDescription
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

    private func screenPinsMenuItem() -> NSMenuItem {
        let controller = ScreenPinController.shared
        let item = NSMenuItem(
            title: localized("label.screen_pins"),
            action: nil,
            keyEquivalent: ""
        )
        item.image = NSImage(
            systemSymbolName: "pin.square.fill",
            accessibilityDescription: localized("label.screen_pins")
        )
        let submenu = NSMenu(title: localized("label.screen_pins"))
        submenu.addItem(PasteBuddyStatusItemController.actionMenuItem(
            localized("action.show_all_pins"),
            systemImageName: "eye"
        ) {
            controller.showAll()
        })
        submenu.addItem(PasteBuddyStatusItemController.actionMenuItem(
            localized("action.hide_all_pins"),
            systemImageName: "eye.slash"
        ) {
            controller.hideAll()
        })
        submenu.addItem(PasteBuddyStatusItemController.actionMenuItem(
            localized("action.restore_recent_pin"),
            systemImageName: "arrow.uturn.backward"
        ) {
            controller.restoreMostRecent()
        })
        submenu.addItem(PasteBuddyStatusItemController.actionMenuItem(
            localized("action.save_all_pins"),
            systemImageName: "square.and.arrow.down"
        ) {
            controller.saveAll()
        })
        submenu.addItem(PasteBuddyStatusItemController.actionMenuItem(
            localized("action.close_all_pins"),
            systemImageName: "xmark.rectangle"
        ) {
            controller.closeAll()
        })
        if controller.hasRecoverableClickThroughPins {
            submenu.addItem(PasteBuddyStatusItemController.actionMenuItem(
                localized("action.disable_click_through_all_pins"),
                systemImageName: "cursorarrow.rays"
            ) {
                controller.disableClickThroughOnAllPins()
            })
        }
        submenu.addItem(.separator())
        let groupsItem = NSMenuItem(
            title: localized("label.pin_groups"),
            action: nil,
            keyEquivalent: ""
        )
        let groupsMenu = NSMenu(title: localized("label.pin_groups"))
        for group in controller.groups {
            let groupItem = PasteBuddyStatusItemController.actionMenuItem(
                group.name,
                systemImageName: "square.stack.3d.up"
            ) {
                controller.selectGroup(group.id)
            }
            groupItem.state = group.id == controller.activeGroupID ? .on : .off
            groupsMenu.addItem(groupItem)
        }
        groupsMenu.addItem(.separator())
        groupsMenu.addItem(PasteBuddyStatusItemController.actionMenuItem(
            localized("action.new_pin_group"),
            systemImageName: "plus"
        ) {
            createScreenPinGroup()
        })
        groupsItem.submenu = groupsMenu
        submenu.addItem(groupsItem)

        let translationItem = NSMenuItem(
            title: localized("label.translation_target"),
            action: nil,
            keyEquivalent: ""
        )
        let translationMenu = NSMenu(title: localized("label.translation_target"))
        let currentTarget = UserDefaults.standard.string(
            forKey: "PasteBuddyTranslationTargetLanguage"
        )
        for identifier in NativeTranslationService.commonTargetLanguageIdentifiers {
            let title = Locale.current.localizedString(forLanguageCode: identifier) ?? identifier
            let languageItem = PasteBuddyStatusItemController.actionMenuItem(title) {
                UserDefaults.standard.set(
                    identifier,
                    forKey: "PasteBuddyTranslationTargetLanguage"
                )
            }
            languageItem.state = currentTarget == identifier ? .on : .off
            translationMenu.addItem(languageItem)
        }
        translationItem.submenu = translationMenu
        submenu.addItem(translationItem)
        item.submenu = submenu
        return item
    }

    private func createScreenPinGroup() {
        let alert = NSAlert()
        alert.messageText = localized("dialog.new_pin_group")
        let field = NSTextField()
        field.placeholderString = localized("label.pin_group_name")
        field.frame.size = CGSize(width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: localized("action.create"))
        alert.addButton(withTitle: localized("action.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn,
              let group = ScreenPinController.shared.createGroup(
                  name: field.stringValue
              ) else {
            return
        }
        ScreenPinController.shared.selectGroup(group.id)
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

    private func toggleClipboardPanel(_ displayMode: ClipboardPanelDisplayMode) {
        PasteBuddyDiagnostics.record(.hotKey, "panelModeToggleRequested", detail: "mode=\(displayMode.rawValue)")
        guard let shelfPanelController else { return }
        switch ClipboardPanelHotKeyToggleDecision.resolve(
            isVisible: shelfPanelController.isVisible,
            isDismissing: shelfPanelController.isDismissing,
            currentMode: panelDisplayMode,
            requestedMode: displayMode
        ) {
        case .hide:
            shelfPanelController.hide()
        case .show(let requestedMode):
            panelDisplayMode = requestedMode
            shelfPanelController.show()
        }
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
        store.onScreenSharingVisibilityChanged = { isVisible in
            Self.applyScreenSharingVisibility(isVisible)
        }
        appDelegate.screenSharingVisibilityProvider = {
            store.snapshot.settingsBehavior.showDuringScreenSharing
        }
        Self.applyScreenSharingVisibility(store.snapshot.settingsBehavior.showDuringScreenSharing)
        if transactionUpdateTask == nil {
            let provider = AppleStoreKitEntitlementProvider()
            store.reconcileCurrentStoreEntitlement(await provider.currentEntitlement())
            transactionUpdateTask = StoreTransactionUpdateObserver(provider: provider).start(
                onUpdate: { [store] update in
                    await store.applyStoreEntitlementUpdate(update)
                },
                onError: { [store] error in
                    await store.recordStoreTransactionUpdateError(error)
                }
            )
        }
        updateCloudSyncRuntime(isEnabled: store.snapshot.sync.isCloudSyncEnabled)
        store.onMCPServerConfigurationChanged = { isEnabled in
            updateMCPHTTPRuntime(isEnabled: isEnabled)
        }
        store.onMCPAccessRevoked = {
            mcpHTTPServer.revokeAuthenticationToken()
        }
        updateMCPHTTPRuntime(isEnabled: store.snapshot.mcp.isServerEnabled)
        ScreenPinController.shared.configure(store: store)
        if PasteBuddyFeatureAvailability.irohClipboardSync {
            irohSync.onItemReceived = { [store] item in
                guard store.addSyncedItem(item) != nil else { return }
            }
            // Peers (iOS) cannot fetch link previews themselves, so re-send items
            // once enrichment upgrades them; the receiver merges via dedupe.
            store.onLinkPreviewMetadataEnriched = { [irohSync] item in
                Task { @MainActor in
                    await irohSync.sendIfConnected(item)
                }
            }
        }
        if monitor == nil {
            let createdMonitor = ClipboardMonitor(
                store: store,
                onItemCaptured: { [irohSync] item in
                    Task { @MainActor in
                        if PasteBuddyFeatureAvailability.irohClipboardSync {
                            await irohSync.sendIfConnected(item)
                        }
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
                    if store.snapshot.settingsBehavior.pasteDestination == .clipboard {
                        return Self.copyItemToClipboard(
                            item,
                            format: format,
                            soundEffectsEnabled: store.snapshot.settingsBehavior.soundEffectsEnabled
                        )
                    }
                    return await Self.pasteItemToTarget(item, format: format, tracker: frontmostApplicationTracker)
                },
                directPasteItems: { items, format in
                    if store.snapshot.settingsBehavior.pasteDestination == .clipboard {
                        return Self.copyItemsToClipboard(
                            items,
                            format: format,
                            soundEffectsEnabled: store.snapshot.settingsBehavior.soundEffectsEnabled
                        )
                    }
                    return await Self.pasteItemsToTarget(items, format: format, tracker: frontmostApplicationTracker)
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
                sidePanelShortcut: store.snapshot.shortcuts.showHidePanel,
                onSidePanel: {
                    toggleClipboardPanel(.sidePanel)
                },
                onPasteStack: {
                    store.togglePasteStack()
                },
                onShelf: {
                    toggleClipboardPanel(.shelf)
                },
                onPinClipboard: {
                    ScreenPinController.shared.pinClipboard()
                },
                onNextPinboard: {
                    Task { @MainActor in
                        await showClipboardPanel(panelDisplayMode)
                        NotificationCenter.default.post(
                            name: .pasteBuddyCyclePanelPinboard,
                            object: PinboardCycleDirection.next
                        )
                    }
                },
                onPreviousPinboard: {
                    Task { @MainActor in
                        await showClipboardPanel(panelDisplayMode)
                        NotificationCenter.default.post(
                            name: .pasteBuddyCyclePanelPinboard,
                            object: PinboardCycleDirection.previous
                        )
                    }
                },
                onQuickPaste: { index, format in
                    Task { @MainActor in
                        let oneBasedIndex = index + 1
                        if shelfPanelController?.routeQuickPasteToVisiblePanel(
                            oneBasedIndex: oneBasedIndex,
                            format: format
                        ) == true {
                            return
                        }
                        guard let item = store.quickPasteItem(atOneBasedIndex: oneBasedIndex) else { return }
                        do {
                            let hydrated = try await store.hydratedItemForTransfer(item)
                            let result = if store.snapshot.settingsBehavior.pasteDestination == .clipboard {
                                Self.copyItemToClipboard(
                                    hydrated,
                                    format: format,
                                    soundEffectsEnabled: store.snapshot.settingsBehavior.soundEffectsEnabled
                                )
                            } else {
                                await Self.pasteItemToTarget(
                                    hydrated,
                                    format: format,
                                    tracker: frontmostApplicationTracker
                                )
                            }
                            store.recordDirectPasteResult(result)
                        } catch {
                            store.lastErrorMessage = error.localizedDescription
                        }
                    }
                }
            )
            panelHotKeyController?.updateShortcuts(store.snapshot.shortcuts)
        }
        if let panelHotKeyController {
            store.onShortcutConfigurationChanged = { [weak panelHotKeyController] shortcuts in
                panelHotKeyController?.updateShortcuts(shortcuts)
            }
        }
        if PasteBuddyFeatureAvailability.irohClipboardSync,
           irohSync.connectionState != .binding {
            Task { @MainActor in
                await irohSync.start()
            }
        }
    }

    private func updateCloudSyncRuntime(isEnabled: Bool) {
        guard isEnabled else {
            cloudSyncTask?.cancel()
            cloudSyncTask = nil
            return
        }
        guard cloudSyncTask == nil,
              store.snapshot.sync.readiness.canAttemptCloudSync,
              let containerIdentifier = store.snapshot.sync.cloudKitContainerIdentifier else {
            return
        }

        let service = CloudKitSyncService(
            transport: CloudKitRemoteRecordTransport(containerIdentifier: containerIdentifier)
        )
        cloudSyncTask = Task { @MainActor in
            var lastUploadedDataRevision: Int?
            while !Task.isCancelled {
                let imported = await store.importLatestCloudSyncSnapshot(using: service)
                guard !Task.isCancelled else { return }
                guard imported != nil || store.lastErrorMessage == nil else {
                    do {
                        try await Task.sleep(for: .seconds(60))
                    } catch {
                        return
                    }
                    continue
                }
                if lastUploadedDataRevision != store.dataRevision,
                   await store.uploadCloudSyncSnapshot(using: service) != nil {
                    lastUploadedDataRevision = store.dataRevision
                }
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
            }
        }
    }

    private func updateMCPHTTPRuntime(isEnabled: Bool) {
        if isEnabled {
            mcpHTTPServer.start(store: store)
        } else {
            mcpHTTPServer.stop()
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
        let result = await PasteboardWriter.pasteToFrontmostAppAsync(
            item,
            format: format,
            targetBundleIdentifier: targetBundleIdentifier,
            activeApplicationBundleIdentifier: {
                tracker.frontmostApplicationBundleIdentifier()
            },
            options: PasteboardWriter.userConfiguredPasteOnlyDirectPasteOptions,
            prepareForPaste: {
                PasteBuddyDiagnostics.record(.directPaste, "activateTargetRequested", detail: "bundle=\(targetBundleIdentifier)")
                tracker.activateLastExternalApplication()
            }
        )
        PasteBuddyDiagnostics.record(.directPaste, "writerFinished", detail: "outcome=\(result.outcome.rawValue)")
        return result
    }

    private static func copyItemToClipboard(
        _ item: ClipboardItem,
        format: PasteFormat,
        soundEffectsEnabled: Bool
    ) -> DirectPasteResult {
        let succeeded = PasteboardWriter.copy(item, format: format)
        if succeeded, soundEffectsEnabled {
            NSSound(named: "Tink")?.play()
        }
        return DirectPasteResult(
            outcome: succeeded ? .copiedToClipboard : .failedPasteboardWrite,
            itemCount: 1,
            format: format
        )
    }

    private static func copyItemsToClipboard(
        _ items: [ClipboardItem],
        format: PasteFormat,
        soundEffectsEnabled: Bool
    ) -> DirectPasteResult {
        guard !items.isEmpty else {
            return DirectPasteResult(outcome: .emptySelection, itemCount: 0, format: format)
        }
        let succeeded = PasteboardWriter.copy(items, format: format)
        if succeeded, soundEffectsEnabled {
            NSSound(named: "Tink")?.play()
        }
        return DirectPasteResult(
            outcome: succeeded ? .copiedToClipboard : .failedPasteboardWrite,
            itemCount: items.count,
            format: format
        )
    }

    static func applyScreenSharingVisibility(_ isVisible: Bool) {
        for window in NSApp.windows {
            window.sharingType = screenSharingType(for: window, showContent: isVisible)
        }
    }

    static func screenSharingType(
        for window: NSWindow,
        showContent: Bool
    ) -> NSWindow.SharingType {
        screenSharingType(
            isProtectedContentWindow: window is PasteBuddyScreenSharingProtectedWindow,
            showContent: showContent
        )
    }

    static func screenSharingType(
        isProtectedContentWindow: Bool,
        showContent: Bool
    ) -> NSWindow.SharingType {
        guard isProtectedContentWindow else {
            return .readOnly
        }
        return showContent ? .readOnly : .none
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
        let result = await PasteboardWriter.pasteToFrontmostAppAsync(
            items,
            format: format,
            targetBundleIdentifier: targetBundleIdentifier,
            activeApplicationBundleIdentifier: {
                tracker.frontmostApplicationBundleIdentifier()
            },
            options: PasteboardWriter.userConfiguredPasteOnlyDirectPasteOptions,
            prepareForPaste: {
                PasteBuddyDiagnostics.record(.directPaste, "activateTargetRequested", detail: "bundle=\(targetBundleIdentifier)")
                tracker.activateLastExternalApplication()
            }
        )
        PasteBuddyDiagnostics.record(.directPaste, "writerFinished", detail: "outcome=\(result.outcome.rawValue)")
        return result
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

enum PasteBuddyDevelopmentCommand: Equatable {
    case openPanel(ClipboardPanelDisplayMode)

    init?(url: URL, bundleIdentifier: String?) {
        guard bundleIdentifier == "com.alexjiang.PasteBuddy.dev",
              url.scheme == "pastebuddy-dev" else {
            return nil
        }
        switch (url.host, url.path) {
        case ("panel", "/shelf"):
            self = .openPanel(.shelf)
        case ("panel", "/side-panel"):
            self = .openPanel(.sidePanel)
        default:
            return nil
        }
    }

    var displayMode: ClipboardPanelDisplayMode {
        switch self {
        case let .openPanel(displayMode):
            displayMode
        }
    }
}

@MainActor
final class PasteBuddyRuntimeLoadGate {
    private var loadTask: Task<Void, Never>?

    func loadIfNeeded(_ loadAsync: @escaping @MainActor () async -> Void) async {
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { @MainActor in
            await loadAsync()
        }
        loadTask = task
        await task.value
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
