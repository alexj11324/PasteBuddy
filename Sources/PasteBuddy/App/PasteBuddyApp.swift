import AppKit
import Darwin
import PasteBuddyCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var flushPendingSave: (() async -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        PasteBuddyDiagnostics.recordAccessibilityTrust(
            .directPaste,
            "accessibilityTrustCheckedAtLaunch"
        )
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
}

private enum MainWindowPresentation: String, Codable, Hashable {
    case manual
}

@main
struct PasteBuddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("clipboardShelfPlacement") private var shelfPlacementRawValue = ClipboardShelfPlacement.top.rawValue
    @State private var store = PasteBuddyStore()
    @State private var monitor: ClipboardMonitor?
    @State private var storeLoadGate = PasteBuddyRuntimeLoadGate()
    @State private var shelfPanelController: ClipboardShelfPanelController?
    @State private var panelHotKeyController: PasteBuddyPanelHotKeyController?
    @State private var statusItemController: PasteBuddyStatusItemController?
    @State private var frontmostApplicationTracker = FrontmostApplicationTracker()
    @State private var isShowingNewTextItem = false
    @State private var mainWindowLaunchCoordinator = MainWindowLaunchCoordinator()

    init() {
        Self.printRuntimeDiagnosticsIfNeeded()
        _ = PasteBuddySentryBootstrap.startIfConfigured()
        #if canImport(AppIntents)
        PasteBuddyAppShortcuts.updateAppShortcutParameters()
        #endif
    }

    var body: some Scene {
        mainWindowScene

        Settings {
            SettingsView(store: store)
        }
    }

    private var mainWindowScene: some Scene {
        WindowGroup("PasteBuddy", id: "main", for: MainWindowPresentation.self) { _ in
            ContentView(
                store: store,
                directPasteItem: { item, format in
                    let hydratedItem = await store.hydratedItem(for: item)
                    return await Self.pasteItemToTarget(
                        hydratedItem,
                        format: format,
                        tracker: frontmostApplicationTracker
                    )
                },
                directPasteItems: { items, format in
                    let hydratedItems = await store.hydratedItems(for: items)
                    return await Self.pasteItemsToTarget(
                        hydratedItems,
                        format: format,
                        tracker: frontmostApplicationTracker
                    )
                },
                isShowingNewTextItem: $isShowingNewTextItem,
                currentExternalApplication: {
                    frontmostApplicationTracker.currentExternalApplication()
                }
            )
                .frame(minWidth: 980, minHeight: 620)
                .task {
                    await startRuntimeIfNeeded()
                }
                .onChange(of: scenePhase) { _, phase in
                    flushPendingSaveIfNeeded(for: phase)
                }
                .background {
                    MainWindowLaunchGuard(coordinator: mainWindowLaunchCoordinator)
                        .frame(width: 0, height: 0)
                }
        }
        .commands {
            CommandMenu("label.clipboard") {
                Button("label.new_text_item") {
                    Task { @MainActor in
                        await presentNewTextItemSheet()
                    }
                }

                Button("action.open_clipboard_shelf") {
                    Task { @MainActor in
                        await toggleClipboardShelf()
                    }
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])

                Divider()

                Button(localized(store.isCapturePaused ? "action.resume_capture" : "action.pause_capture")) {
                    store.toggleCapturePaused()
                }

                Button("action.pause_capture_for_15_minutes") {
                    store.pauseCapture(for: 15 * 60)
                }

                Button("action.pause_capture_for_1_hour") {
                    store.pauseCapture(for: 60 * 60)
                }

                Divider()

                Button("action.clear_filters") {
                    clearSearchAndFilters()
                }
                .disabled(!canClearSearchAndFilters)

                Divider()

                Button(localized(store.isPasteStackActive ? "action.stop_paste_stack" : "label.activate_paste_stack")) {
                    store.togglePasteStack()
                }
                .pasteBuddyKeyboardShortcut(store.snapshot.shortcuts.activatePasteStack)

                Button("action.paste_next_stack_item") {
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
                }
                .pasteBuddyKeyboardShortcut(store.snapshot.shortcuts.pasteNextStackItem)
                .disabled(store.pasteStackItems.isEmpty)

                Button("action.reverse_paste_stack") {
                    store.reversePasteStackDirection()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(store.pasteStackItems.isEmpty)

                Divider()

                Button("action.copy_pastebuddy_item") {
                    PasteboardWriter.copy(store.selectedItemsInDisplayOrder)
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(store.selectedItemsInDisplayOrder.isEmpty)

                Button("action.paste_pastebuddy_item") {
                    Task { @MainActor in
                        let items = store.selectedItemsInDisplayOrder
                        store.recordDirectPasteResult(
                            await Self.pasteItemsToTarget(
                                items,
                                format: store.defaultPasteFormat,
                                tracker: frontmostApplicationTracker
                            )
                        )
                    }
                }
                .disabled(store.selectedItemsInDisplayOrder.isEmpty)

                Button("action.copy_pastebuddy_item_as_plain") {
                    PasteboardWriter.copy(store.selectedItemsInDisplayOrder, format: .plainText)
                }
                .keyboardShortcut("c", modifiers: [.command, .control])
                .disabled(store.selectedItemsInDisplayOrder.isEmpty)

                Button("action.paste_pastebuddy_item_as_plain") {
                    Task { @MainActor in
                        let items = store.selectedItemsInDisplayOrder
                        store.recordDirectPasteResult(
                            await Self.pasteItemsToTarget(
                                items,
                                format: .plainText,
                                tracker: frontmostApplicationTracker
                            )
                        )
                    }
                }
                .disabled(store.selectedItemsInDisplayOrder.isEmpty)

                if store.snapshot.shortcuts.isQuickPasteEnabled {
                    Divider()

                    ForEach(1...9, id: \.self) { index in
                        Button(localized("format.quick_paste_index", index)) {
                            Task { @MainActor in
                                await quickPaste(index, format: store.defaultPasteFormat)
                            }
                        }
                        .keyboardShortcut(
                            digitKeyEquivalent(index),
                            modifiers: store.snapshot.shortcuts.quickPasteModifiers.eventModifiers
                        )
                        .disabled(store.quickPasteItem(atOneBasedIndex: index) == nil)
                    }

                    Divider()

                    ForEach(1...9, id: \.self) { index in
                        Button(localized("format.quick_paste_index_as_plain_text", index)) {
                            Task { @MainActor in
                                await quickPaste(index, format: .plainText)
                            }
                        }
                        .keyboardShortcut(
                            digitKeyEquivalent(index),
                            modifiers: store.snapshot.shortcuts.plainTextQuickPasteModifiers.eventModifiers
                        )
                        .disabled(store.quickPasteItem(atOneBasedIndex: index) == nil)
                    }
                }

                Button("action.undo_delete_pastebuddy_item") {
                    store.undoLastDeletion()
                }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(!store.canUndoDelete)
            }

            CommandMenu("label.pinboard") {
                Button("label.new_pinboard") {
                    Task { @MainActor in
                        await createNewPinboard()
                    }
                }

                Divider()

                Menu("action.pin_selected_to") {
                    if store.snapshot.pinboards.isEmpty {
                        Button("label.no_pinboards_available") {}
                            .disabled(true)
                    } else {
                        ForEach(store.snapshot.pinboards) { pinboard in
                            Button(localized("format.pin_to", pinboard.name)) {
                                pinSelectedItems(to: pinboard.id)
                            }
                            .disabled(!canPinSelection)
                        }
                    }
                }
                .disabled(!canPinSelection)

                Button("action.unpin_from_current_pinboard") {
                    unpinSelectedItemsFromCurrentPinboard()
                }
                .disabled(!canUnpinSelectionFromCurrentPinboard)
            }
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

    private var shelfPlacement: ClipboardShelfPlacement {
        get {
            ClipboardShelfPlacement(rawValue: shelfPlacementRawValue) ?? .top
        }
        nonmutating set {
            shelfPlacementRawValue = newValue.rawValue
            shelfPanelController?.placement = newValue
        }
    }

    private func configureStatusItemIfNeeded() {
        if statusItemController == nil {
            statusItemController = PasteBuddyStatusItemController(
                menuProvider: {
                    makeStatusItemMenu()
                }
            )
        }
        updateStatusItem()
    }

    private func updateStatusItem() {
        statusItemController?.update(status: store.macMenuBarStatus)
    }

    private func makeStatusItemMenu() -> NSMenu {
        let status = store.macMenuBarStatus
        let menu = NSMenu(title: "brand.pastebuddy")
        menu.addItem(PasteBuddyStatusItemController.disabledMenuItem(
            localized(status.captureStatusLine),
            systemImageName: status.systemImageName
        ))
        menu.addItem(PasteBuddyStatusItemController.disabledMenuItem(localized(status.captureDetail)))
        menu.addItem(PasteBuddyStatusItemController.disabledMenuItem(localized(status.launchAtLoginStatusLine)))
        menu.addItem(.separator())

        let shelfTitle = shelfPanelController?.isVisible == true ? "action.hide_clipboard_shelf" : "action.show_clipboard_shelf"
        menu.addItem(PasteBuddyStatusItemController.actionMenuItem(
            localized(shelfTitle),
            systemImageName: "rectangle.bottomthird.inset.filled"
        ) {
            Task { @MainActor in
                await toggleClipboardShelf()
            }
        })

        let shelfPlacementItem = NSMenuItem(title: localized("label.shelf_position"), action: nil, keyEquivalent: "")
        shelfPlacementItem.image = NSImage(
            systemSymbolName: shelfPlacement.systemImageName,
            accessibilityDescription: localized("label.shelf_position")
        )
        let shelfPlacementMenu = NSMenu(title: localized("label.shelf_position"))

        let topPlacementItem = PasteBuddyStatusItemController.actionMenuItem(
            localized("label.shelf_at_top"),
            systemImageName: ClipboardShelfPlacement.top.systemImageName
        ) {
            shelfPlacement = .top
        }
        topPlacementItem.state = shelfPlacement == .top ? .on : .off
        shelfPlacementMenu.addItem(topPlacementItem)

        let bottomPlacementItem = PasteBuddyStatusItemController.actionMenuItem(
            localized("label.shelf_at_bottom"),
            systemImageName: ClipboardShelfPlacement.bottom.systemImageName
        ) {
            shelfPlacement = .bottom
        }
        bottomPlacementItem.state = shelfPlacement == .bottom ? .on : .off
        shelfPlacementMenu.addItem(bottomPlacementItem)

        shelfPlacementItem.submenu = shelfPlacementMenu
        menu.addItem(shelfPlacementItem)

        let settingsItem = NSMenuItem(title: localized("action.open_settings"), action: nil, keyEquivalent: "")
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: localized("action.open_settings"))
        let settingsMenu = NSMenu(title: localized("action.open_settings"))
        for destination in status.settingsDestinations {
            settingsMenu.addItem(PasteBuddyStatusItemController.actionMenuItem(
                localizedSettingsTitle(destination),
                systemImageName: destination.systemImageName
            ) {
                store.requestSettingsDestination(destination)
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            })
        }
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

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
            localized(status.captureActionTitle),
            systemImageName: store.isCapturePaused ? "play.fill" : "pause.fill"
        ) {
            store.toggleCapturePaused()
            updateStatusItem()
        })
        menu.addItem(PasteBuddyStatusItemController.actionMenuItem(
            localized("action.pause_capture_for_15_minutes"),
            systemImageName: "timer"
        ) {
            store.pauseCapture(for: 15 * 60)
            updateStatusItem()
        })
        menu.addItem(PasteBuddyStatusItemController.actionMenuItem(
            localized("action.pause_capture_for_1_hour"),
            systemImageName: "timer"
        ) {
            store.pauseCapture(for: 60 * 60)
            updateStatusItem()
        })

        let recentItems = Array(store.snapshot.items.prefix(6))
        if !recentItems.isEmpty {
            menu.addItem(.separator())
            for item in recentItems {
                menu.addItem(PasteBuddyStatusItemController.actionMenuItem(
                    item.title.menuBarTitle,
                    systemImageName: item.presentationContentType.systemImageName
                ) {
                    PasteboardWriter.copy(item)
                })
            }
        }
        return menu
    }

    private func openMainWindow() async {
        await startRuntimeIfNeeded()
        mainWindowLaunchCoordinator.allowNextMainWindowPresentation()
        openWindow(id: "main", value: MainWindowPresentation.manual)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var canClearSearchAndFilters: Bool {
        store.hasActiveFilters || !store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canPinSelection: Bool {
        !store.selectedItemsInDisplayOrder.isEmpty && !store.snapshot.pinboards.isEmpty
    }

    private var canUnpinSelectionFromCurrentPinboard: Bool {
        guard case .pinboard(let pinboardID) = store.selectedScope,
              let pinboard = store.snapshot.pinboards.first(where: { $0.id == pinboardID })
        else {
            return false
        }
        let selectedIDs = Set(store.selectedItemsInDisplayOrder.map(\.id))
        return !selectedIDs.isEmpty && !Set(pinboard.itemIDs).isDisjoint(with: selectedIDs)
    }

    private func flushPendingSaveIfNeeded(for phase: ScenePhase) {
        guard phase == .inactive || phase == .background else { return }
        Task { @MainActor in
            await store.flushPendingSave()
        }
    }

    private func presentNewTextItemSheet() async {
        await openMainWindow()
        isShowingNewTextItem = true
    }

    private func createNewPinboard() async {
        await openMainWindow()
        store.createPinboard()
    }

    private func clearSearchAndFilters() {
        store.searchQuery = ""
        store.clearFilters()
    }

    private func pinSelectedItems(to pinboardID: UUID) {
        let itemIDs = store.selectedItemsInDisplayOrder.map(\.id)
        guard !itemIDs.isEmpty else { return }
        store.pinItems(itemIDs, to: pinboardID)
    }

    private func unpinSelectedItemsFromCurrentPinboard() {
        guard case .pinboard(let pinboardID) = store.selectedScope else { return }
        for itemID in store.selectedItemsInDisplayOrder.map(\.id) {
            store.removeItem(itemID, fromPinboard: pinboardID)
        }
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

    private func startRuntimeIfNeeded() async {
        frontmostApplicationTracker.start()
        appDelegate.flushPendingSave = { [store] in
            await store.flushPendingSave()
        }

        await storeLoadGate.loadIfNeeded {
            await store.loadAsync()
        }
        configureStatusItemIfNeeded()

        if monitor == nil {
            let createdMonitor = ClipboardMonitor(store: store)
            createdMonitor.start()
            monitor = createdMonitor
        }

        if shelfPanelController == nil {
            let statusController = statusItemController
            shelfPanelController = ClipboardShelfPanelController(
                store: store,
                placement: shelfPlacement,
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
        shelfPanelController?.placement = shelfPlacement

        if panelHotKeyController == nil, shelfPanelController != nil {
            panelHotKeyController = PasteBuddyPanelHotKeyController {
                Task { @MainActor in
                    await toggleClipboardShelf()
                }
            }
        }
    }

    private func quickPaste(_ index: Int, format: PasteFormat) async {
        guard let item = store.quickPasteItem(atOneBasedIndex: index) else { return }
        let hydratedItem = await store.hydratedItem(for: item)
        store.recordDirectPasteResult(
            await Self.pasteItemToTarget(
                hydratedItem,
                format: format,
                tracker: frontmostApplicationTracker
            )
        )
    }

    private func digitKeyEquivalent(_ index: Int) -> KeyEquivalent {
        KeyEquivalent(Character(String(index)))
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
private final class MainWindowLaunchCoordinator {
    private var shouldAllowNextMainWindowPresentation = false
    private var didSuppressAutomaticLaunchWindow = false

    func allowNextMainWindowPresentation() {
        shouldAllowNextMainWindowPresentation = true
    }

    func shouldSuppressMainWindow(_ window: NSWindow) -> Bool {
        if shouldAllowNextMainWindowPresentation {
            shouldAllowNextMainWindowPresentation = false
            return false
        }
        guard !didSuppressAutomaticLaunchWindow else {
            return false
        }
        didSuppressAutomaticLaunchWindow = true
        PasteBuddyDiagnostics.record(.directPaste, "suppressedAutomaticMainWindow", detail: window.title)
        return true
    }
}

private struct MainWindowLaunchGuard: NSViewRepresentable {
    let coordinator: MainWindowLaunchCoordinator

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        scheduleSuppressionCheck(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        scheduleSuppressionCheck(for: nsView)
    }

    private func scheduleSuppressionCheck(for view: NSView) {
        Task { @MainActor [weak view] in
            await Task.yield()
            guard let window = view?.window,
                  coordinator.shouldSuppressMainWindow(window)
            else {
                return
            }
            window.orderOut(nil)
            window.close()
        }
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

private extension View {
    @ViewBuilder
    func pasteBuddyKeyboardShortcut(_ binding: ShortcutBinding) -> some View {
        if let keyEquivalent = binding.keyEquivalent {
            keyboardShortcut(keyEquivalent, modifiers: binding.modifiers.eventModifiers)
        } else {
            self
        }
    }
}

private extension Array where Element == ShortcutModifier {
    var eventModifiers: EventModifiers {
        reduce(into: EventModifiers()) { result, modifier in
            switch modifier {
            case .command:
                result.insert(.command)
            case .option:
                result.insert(.option)
            case .shift:
                result.insert(.shift)
            case .control:
                result.insert(.control)
            }
        }
    }
}

private extension ShortcutBinding {
    var keyEquivalent: KeyEquivalent? {
        guard let key, let character = key.first else { return nil }
        return KeyEquivalent(character)
    }
}
