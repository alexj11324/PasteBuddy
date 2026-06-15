import AppKit
import PasteBuddyCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var flushPendingSave: (() async -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationWillTerminate(_ notification: Notification) {
        PasteBuddyLifecycleFlush.flushForTermination(flushPendingSave)
    }
}

@main
struct PasteBuddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = PasteBuddyStore()
    @State private var monitor: ClipboardMonitor?
    @State private var storeLoadGate = PasteBuddyRuntimeLoadGate()
    @State private var shelfPanelController: ClipboardShelfPanelController?
    @State private var panelHotKeyController: PasteBuddyPanelHotKeyController?
    @State private var frontmostApplicationTracker = FrontmostApplicationTracker()

    init() {
        #if canImport(AppIntents)
        PasteBuddyAppShortcuts.updateAppShortcutParameters()
        #endif
    }

    var body: some Scene {
        WindowGroup("PasteBuddy", id: "main") {
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
        }
        .commands {
            CommandMenu("Clipboard") {
                Button("New Text Item") {
                    Task { @MainActor in
                        await presentNewTextItemPanel()
                    }
                }

                Button("Open Clipboard Shelf") {
                    Task { @MainActor in
                        await toggleClipboardShelf()
                    }
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])

                Divider()

                Button(localized(store.isCapturePaused ? "Resume Capture" : "Pause Capture")) {
                    store.toggleCapturePaused()
                }

                Button("Pause Capture for 15 Minutes") {
                    store.pauseCapture(for: 15 * 60)
                }

                Button("Pause Capture for 1 Hour") {
                    store.pauseCapture(for: 60 * 60)
                }

                Divider()

                Button("Clear Filters") {
                    clearSearchAndFilters()
                }
                .disabled(!canClearSearchAndFilters)

                Divider()

                Button(localized(store.isPasteStackActive ? "Stop Paste Stack" : "Activate Paste Stack")) {
                    store.togglePasteStack()
                }
                .pasteBuddyKeyboardShortcut(store.snapshot.shortcuts.activatePasteStack)

                Button("Paste Next Stack Item") {
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

                Button("Reverse Paste Stack") {
                    store.reversePasteStackDirection()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(store.pasteStackItems.isEmpty)

                Divider()

                Button("Copy PasteBuddy Item") {
                    PasteboardWriter.copy(store.selectedItemsInDisplayOrder)
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(store.selectedItemsInDisplayOrder.isEmpty)

                Button("Paste PasteBuddy Item") {
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

                Button("Copy PasteBuddy Item as Plain Text") {
                    PasteboardWriter.copy(store.selectedItemsInDisplayOrder, format: .plainText)
                }
                .keyboardShortcut("c", modifiers: [.command, .control])
                .disabled(store.selectedItemsInDisplayOrder.isEmpty)

                Button("Paste PasteBuddy Item as Plain Text") {
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
                        Button("Quick Paste \(index)") {
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
                        Button("Quick Paste \(index) as Plain Text") {
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

                Button("Undo Delete PasteBuddy Item") {
                    store.undoLastDeletion()
                }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(!store.canUndoDelete)
            }

            CommandMenu("Pinboard") {
                Button("New Pinboard") {
                    Task { @MainActor in
                        await createNewPinboard()
                    }
                }

                Divider()

                Menu("Pin Selected To") {
                    if store.snapshot.pinboards.isEmpty {
                        Button("No Pinboards Available") {}
                            .disabled(true)
                    } else {
                        ForEach(store.snapshot.pinboards) { pinboard in
                            Button("Pin to \(pinboard.name)") {
                                pinSelectedItems(to: pinboard.id)
                            }
                            .disabled(!canPinSelection)
                        }
                    }
                }
                .disabled(!canPinSelection)

                Button("Unpin from Current Pinboard") {
                    unpinSelectedItemsFromCurrentPinboard()
                }
                .disabled(!canUnpinSelectionFromCurrentPinboard)
            }
        }

        Settings {
            SettingsView(store: store)
        }

        MenuBarExtra {
            Label(localized(store.macMenuBarStatus.captureStatusLine), systemImage: store.macMenuBarStatus.systemImageName)
            Text(localized(store.macMenuBarStatus.captureDetail))
            Text(localized(store.macMenuBarStatus.launchAtLoginStatusLine))

            Divider()

            Button("Show Clipboard Shelf") {
                Task { @MainActor in
                    await toggleClipboardShelf()
                }
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])

            Button("Open PasteBuddy") {
                Task { @MainActor in
                    await openMainWindow()
                }
            }

            Menu("Open Settings") {
                ForEach(store.macMenuBarStatus.settingsDestinations) { destination in
                    Button {
                        store.requestSettingsDestination(destination)
                        openSettings()
                    } label: {
                        Label(localizedSettingsTitle(destination), systemImage: destination.systemImageName)
                    }
                }
            }

            Button(localized(store.snapshot.general.launchAtLoginEnabled ? "Disable Launch at Login" : "Enable Launch at Login")) {
                store.setLaunchAtLoginEnabled(
                    !store.snapshot.general.launchAtLoginEnabled,
                    applySystemRegistration: LaunchAtLoginService.isAvailable
                )
            }
            .disabled(!LaunchAtLoginService.isAvailable)

            Divider()

            Button(localized(store.isPasteStackActive ? "Stop Paste Stack" : "Start Paste Stack")) {
                store.togglePasteStack()
            }
            Button("Paste Next Stack Item") {
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
            .disabled(store.pasteStackItems.isEmpty)
            Divider()
            Button(localized(store.macMenuBarStatus.captureActionTitle)) {
                store.toggleCapturePaused()
            }
            Button("Pause Capture for 15 Minutes") {
                store.pauseCapture(for: 15 * 60)
            }
            Button("Pause Capture for 1 Hour") {
                store.pauseCapture(for: 60 * 60)
            }
            Divider()
            ForEach(store.snapshot.items.prefix(6)) { item in
                Button(item.title.menuBarTitle) {
                    PasteboardWriter.copy(item)
                }
            }
        } label: {
            Label(localized(store.macMenuBarStatus.title), systemImage: store.macMenuBarStatus.systemImageName)
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

    private func openMainWindow() async {
        await startRuntimeIfNeeded()
        openWindow(id: "main")
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

    private func presentNewTextItemPanel() async {
        await openMainWindow()

        let titleField = NSTextField(string: "")
        titleField.placeholderString = localized("Title")
        titleField.frame = NSRect(x: 0, y: 0, width: 460, height: 24)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 180))
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 180))
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView

        let stack = NSStackView(views: [titleField, scrollView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 460, height: 220)
        titleField.widthAnchor.constraint(equalToConstant: 460).isActive = true
        scrollView.widthAnchor.constraint(equalToConstant: 460).isActive = true
        scrollView.heightAnchor.constraint(equalToConstant: 180).isActive = true

        let alert = NSAlert()
        alert.messageText = localized("New Text Item")
        alert.informativeText = localized("Create a local encrypted PasteBuddy text item.")
        alert.accessoryView = stack
        alert.addButton(withTitle: localized("Create"))
        alert.addButton(withTitle: localized("Cancel"))

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard store.createTextItem(text: textView.string, title: titleField.stringValue) != nil else {
            NSSound.beep()
            return
        }
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
        frontmostApplicationTracker.recordCurrentFrontmostApplication()
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

        if monitor == nil {
            let createdMonitor = ClipboardMonitor(store: store)
            createdMonitor.start()
            monitor = createdMonitor
        }

        if shelfPanelController == nil {
            shelfPanelController = ClipboardShelfPanelController(
                store: store,
                directPasteItem: { item, format in
                    let hydratedItem = await store.hydratedItem(for: item)
                    return await Self.pasteItemToTarget(hydratedItem, format: format, tracker: frontmostApplicationTracker)
                },
                directPasteItems: { items, format in
                    let hydratedItems = await store.hydratedItems(for: items)
                    return await Self.pasteItemsToTarget(hydratedItems, format: format, tracker: frontmostApplicationTracker)
                }
            )
        }

        if panelHotKeyController == nil, let shelfPanelController {
            panelHotKeyController = PasteBuddyPanelHotKeyController {
                shelfPanelController.toggle()
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
        guard AccessibilityPermissionService.isTrusted else {
            return await PasteboardWriter.pasteToFrontmostAppAsync(item, format: format)
        }
        guard let target = tracker.currentExternalApplication(),
              let targetBundleIdentifier = target.bundleIdentifier else {
            PasteboardWriter.copy(item, format: format)
            return DirectPasteResult(
                outcome: .copiedOnlyNoTargetApplication,
                itemCount: 1,
                format: format
            )
        }
        return await PasteboardWriter.pasteToFrontmostAppAsync(
            item,
            format: format,
            targetBundleIdentifier: targetBundleIdentifier,
            activeApplicationBundleIdentifier: {
                tracker.frontmostApplicationBundleIdentifier()
            },
            options: PasteboardWriter.userConfiguredDirectPasteOptions,
            prepareForPaste: {
                tracker.activateLastExternalApplication()
            }
        )
    }

    private static func pasteItemsToTarget(
        _ items: [ClipboardItem],
        format: PasteFormat,
        tracker: FrontmostApplicationTracker
    ) async -> DirectPasteResult {
        guard !items.isEmpty else {
            return DirectPasteResult(outcome: .emptySelection, itemCount: 0, format: format)
        }
        guard AccessibilityPermissionService.isTrusted else {
            return await PasteboardWriter.pasteToFrontmostAppAsync(items, format: format)
        }
        guard let target = tracker.currentExternalApplication(),
              let targetBundleIdentifier = target.bundleIdentifier else {
            PasteboardWriter.copy(items, format: format)
            return DirectPasteResult(
                outcome: .copiedOnlyNoTargetApplication,
                itemCount: items.count,
                format: format
            )
        }
        return await PasteboardWriter.pasteToFrontmostAppAsync(
            items,
            format: format,
            targetBundleIdentifier: targetBundleIdentifier,
            activeApplicationBundleIdentifier: {
                tracker.frontmostApplicationBundleIdentifier()
            },
            options: PasteboardWriter.userConfiguredDirectPasteOptions,
            prepareForPaste: {
                tracker.activateLastExternalApplication()
            }
        )
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
enum PasteBuddyLifecycleFlush {
    static let terminationTimeout: TimeInterval = 0.25

    static func flushForTermination(
        _ flushPendingSave: (() async -> Void)?,
        timeout: TimeInterval = 0.25
    ) {
        guard let flushPendingSave else { return }

        var didFinish = false
        Task { @MainActor in
            await flushPendingSave()
            didFinish = true
        }

        let deadline = Date().addingTimeInterval(timeout)
        while !didFinish && Date() < deadline {
            RunLoop.current.run(
                mode: .default,
                before: min(deadline, Date().addingTimeInterval(0.01))
            )
        }
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

private extension ShortcutBinding {
    var keyEquivalent: KeyEquivalent? {
        guard let key, let character = key.first else { return nil }
        return KeyEquivalent(character)
    }
}

private extension [ShortcutModifier] {
    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if contains(.command) { result.insert(.command) }
        if contains(.option) { result.insert(.option) }
        if contains(.control) { result.insert(.control) }
        if contains(.shift) { result.insert(.shift) }
        return result
    }
}
