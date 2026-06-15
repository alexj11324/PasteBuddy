import AppKit
import PasteBuddyCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
}

@main
struct PasteBuddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var store = PasteBuddyStore()
    @State private var monitor: ClipboardMonitor?
    @State private var didLoadStore = false
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
                    Self.pasteItemToTarget(
                        item,
                        format: format,
                        tracker: frontmostApplicationTracker
                    )
                },
                directPasteItems: { items, format in
                    Self.pasteItemsToTarget(
                        items,
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
                    startRuntimeIfNeeded()
                }
        }
        .commands {
            CommandGroup(after: .pasteboard) {
                Button("Show/Hide Clipboard Shelf") {
                    toggleClipboardShelf()
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])

                Divider()

                Button(localized(store.isPasteStackActive ? "Stop Paste Stack" : "Activate Paste Stack")) {
                    store.togglePasteStack()
                }
                .pasteBuddyKeyboardShortcut(store.snapshot.shortcuts.activatePasteStack)

                Button("Paste Next Stack Item") {
                    if let item = store.pasteNextStackItem() {
                        store.recordDirectPasteResult(
                            Self.pasteItemToTarget(
                                item,
                                format: store.defaultPasteFormat,
                                tracker: frontmostApplicationTracker
                            )
                        )
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
                    store.recordDirectPasteResult(
                        Self.pasteItemsToTarget(
                            store.selectedItemsInDisplayOrder,
                            format: store.defaultPasteFormat,
                            tracker: frontmostApplicationTracker
                        )
                    )
                }
                .disabled(store.selectedItemsInDisplayOrder.isEmpty)

                Button("Copy PasteBuddy Item as Plain Text") {
                    PasteboardWriter.copy(store.selectedItemsInDisplayOrder, format: .plainText)
                }
                .keyboardShortcut("c", modifiers: [.command, .control])
                .disabled(store.selectedItemsInDisplayOrder.isEmpty)

                Button("Paste PasteBuddy Item as Plain Text") {
                    store.recordDirectPasteResult(
                        Self.pasteItemsToTarget(
                            store.selectedItemsInDisplayOrder,
                            format: .plainText,
                            tracker: frontmostApplicationTracker
                        )
                    )
                }
                .disabled(store.selectedItemsInDisplayOrder.isEmpty)

                if store.snapshot.shortcuts.isQuickPasteEnabled {
                    Divider()

                    ForEach(1...9, id: \.self) { index in
                        Button("Quick Paste \(index)") {
                            quickPaste(index, format: store.defaultPasteFormat)
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
                            quickPaste(index, format: .plainText)
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
                toggleClipboardShelf()
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])

            Button("Open PasteBuddy") {
                openMainWindow()
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
                if let item = store.pasteNextStackItem() {
                    store.recordDirectPasteResult(
                        Self.pasteItemToTarget(
                            item,
                            format: store.defaultPasteFormat,
                            tracker: frontmostApplicationTracker
                        )
                    )
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

    private func openMainWindow() {
        startRuntimeIfNeeded()
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func toggleClipboardShelf() {
        startRuntimeIfNeeded()
        frontmostApplicationTracker.recordCurrentFrontmostApplication()
        shelfPanelController?.toggle()
    }

    private func startRuntimeIfNeeded() {
        frontmostApplicationTracker.start()

        if !didLoadStore {
            store.load()
            didLoadStore = true
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
                    Self.pasteItemToTarget(item, format: format, tracker: frontmostApplicationTracker)
                },
                directPasteItems: { items, format in
                    Self.pasteItemsToTarget(items, format: format, tracker: frontmostApplicationTracker)
                }
            )
        }

        if panelHotKeyController == nil, let shelfPanelController {
            panelHotKeyController = PasteBuddyPanelHotKeyController {
                shelfPanelController.toggle()
            }
        }
    }

    private func quickPaste(_ index: Int, format: PasteFormat) {
        guard let item = store.quickPasteItem(atOneBasedIndex: index) else { return }
        store.recordDirectPasteResult(
            Self.pasteItemToTarget(
                item,
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
    ) -> DirectPasteResult {
        guard AccessibilityPermissionService.isTrusted else {
            return PasteboardWriter.pasteToFrontmostApp(item, format: format)
        }
        guard tracker.currentExternalApplication() != nil else {
            PasteboardWriter.copy(item, format: format)
            return DirectPasteResult(
                outcome: .copiedOnlyNoTargetApplication,
                itemCount: 1,
                format: format
            )
        }
        return PasteboardWriter.pasteToFrontmostApp(
            item,
            format: format,
            prepareForPaste: {
                tracker.activateLastExternalApplication()
            }
        )
    }

    private static func pasteItemsToTarget(
        _ items: [ClipboardItem],
        format: PasteFormat,
        tracker: FrontmostApplicationTracker
    ) -> DirectPasteResult {
        guard !items.isEmpty else {
            return DirectPasteResult(outcome: .emptySelection, itemCount: 0, format: format)
        }
        guard AccessibilityPermissionService.isTrusted else {
            return PasteboardWriter.pasteToFrontmostApp(items, format: format)
        }
        guard tracker.currentExternalApplication() != nil else {
            PasteboardWriter.copy(items, format: format)
            return DirectPasteResult(
                outcome: .copiedOnlyNoTargetApplication,
                itemCount: items.count,
                format: format
            )
        }
        return PasteboardWriter.pasteToFrontmostApp(
            items,
            format: format,
            prepareForPaste: {
                tracker.activateLastExternalApplication()
            }
        )
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
