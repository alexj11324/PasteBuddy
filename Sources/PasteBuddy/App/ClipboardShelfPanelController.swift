import AppKit
import Carbon
import PasteBuddyCore
import SwiftUI

@MainActor
final class ClipboardShelfPanelController {
    private static let panelCornerRadius: CGFloat = 28

    private let store: PasteBuddyStore
    private let directPasteItem: @MainActor (ClipboardItem, PasteFormat) async -> DirectPasteResult
    private let directPasteItems: @MainActor ([ClipboardItem], PasteFormat) async -> DirectPasteResult
    private var panel: ClipboardShelfPanel?
    private var localMouseDownMonitor: Any?
    private var globalMouseDownMonitor: Any?
    private var panelResignKeyObserver: NSObjectProtocol?
    private var appResignActiveObserver: NSObjectProtocol?
    private var screenParametersObserver: NSObjectProtocol?
    private var ignoreOutsideClicksUntil: Date?

    init(
        store: PasteBuddyStore,
        directPasteItem: @escaping @MainActor (ClipboardItem, PasteFormat) async -> DirectPasteResult,
        directPasteItems: @escaping @MainActor ([ClipboardItem], PasteFormat) async -> DirectPasteResult
    ) {
        self.store = store
        self.directPasteItem = directPasteItem
        self.directPasteItems = directPasteItems
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    func toggle() {
        PasteBuddyDiagnostics.record(.shelf, "toggleRequested", detail: "visible=\(isVisible)")
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        PasteBuddyDiagnostics.record(.shelf, "showRequested")
        let panel = panel ?? makePanel()
        self.panel = panel
        ignoreOutsideClicksUntil = Date().addingTimeInterval(0.35)
        let finalFrame = bottomAttachedFrame(for: panel)
        PasteBuddyDiagnostics.record(.shelf, "frameCalculated", detail: NSStringFromRect(finalFrame))
        panel.animationBehavior = nativeWindowAnimationBehavior
        panel.setFrame(finalFrame, display: false)
        startScreenParameterMonitoring(for: panel)
        panel.orderFrontRegardless()
        panel.makeKey()
        PasteBuddyDiagnostics.record(.shelf, "orderedFront", detail: NSStringFromRect(panel.frame))
        postVoiceOverAnnouncement(NSLocalizedString("Clipboard Shelf opened", comment: ""))
        startDismissalMonitoring(for: panel)
    }

    func hideImmediately() {
        guard let panel, panel.isVisible else { return }
        PasteBuddyDiagnostics.record(.shelf, "hideImmediate")
        stopOutsideClickMonitoring()
        stopFocusMonitoring()
        stopScreenParameterMonitoring()
        panel.animationBehavior = .none
        panel.orderOut(nil)
        postVoiceOverAnnouncement(NSLocalizedString("Clipboard Shelf closed", comment: ""))
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        PasteBuddyDiagnostics.record(.shelf, "hideRequested")
        stopOutsideClickMonitoring()
        stopFocusMonitoring()
        stopScreenParameterMonitoring()
        panel.animationBehavior = nativeWindowAnimationBehavior
        panel.orderOut(nil)
        postVoiceOverAnnouncement(NSLocalizedString("Clipboard Shelf closed", comment: ""))
    }

    private func makePanel() -> ClipboardShelfPanel {
        let panel = ClipboardShelfPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 292),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let shelfTitle = NSLocalizedString("Clipboard Shelf", comment: "")
        panel.title = shelfTitle
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.animationBehavior = nativeWindowAnimationBehavior
        panel.isExcludedFromWindowsMenu = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.minSize = NSSize(width: 760, height: 250)
        panel.setAccessibilityLabel(shelfTitle)
        panel.onCancel = { [weak self] in
            self?.hide()
        }
        let hostingView = FirstMouseHostingView(
            rootView: ClipboardShelfPanelView(
                store: store,
                directPasteItem: directPasteItem,
                directPasteItems: directPasteItems,
                reloadClipboardHistory: { [store] in
                    await store.loadAsync()
                }
            ) { [weak self] in
                self?.hide()
            } onDismissImmediately: { [weak self] in
                self?.hideImmediately()
            }
        )
        hostingView.configureForRoundedTransparentPanel(cornerRadius: Self.panelCornerRadius)
        panel.contentView = hostingView
        return panel
    }

    private func bottomAttachedFrame(for panel: NSPanel) -> NSRect {
        let screen = activeScreen()
        let screenFrame = screen.frame
        let height = panelHeight(for: panel, in: screenFrame)
        return NSRect(
            x: screenFrame.minX,
            y: screenFrame.minY,
            width: screenFrame.width,
            height: height
        )
    }

    private func panelHeight(for panel: NSPanel, in screenFrame: NSRect) -> CGFloat {
        let minimumHeight = min(236, screenFrame.height)
        let maximumHeight = max(minimumHeight, min(screenFrame.height * 0.36, 360))
        panel.contentView?.setFrameSize(NSSize(width: screenFrame.width, height: maximumHeight))
        panel.contentView?.layoutSubtreeIfNeeded()

        let fittingHeight = panel.contentView?.fittingSize.height ?? 0
        let preferredHeight = fittingHeight > 0 && fittingHeight.isFinite ? fittingHeight : 260
        return min(max(preferredHeight, minimumHeight), maximumHeight)
    }

    private func positionVisiblePanel(_ panel: NSPanel) {
        let finalFrame = bottomAttachedFrame(for: panel)
        panel.setFrame(finalFrame, display: panel.isVisible)
    }

    private func startDismissalMonitoring(for panel: NSPanel) {
        startOutsideClickMonitoring(for: panel)
        startFocusMonitoring(for: panel)
    }

    private func startOutsideClickMonitoring(for panel: NSPanel) {
        stopOutsideClickMonitoring()

        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self, weak panel] event in
            guard let self, let panel, panel.isVisible else { return event }
            if Self.isShelfAuxiliaryWindow(event.window) {
                return event
            }
            self.hideIfOutsideClick(at: self.screenLocation(for: event))
            return event
        }

        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self, weak panel] _ in
            guard let self, let panel, panel.isVisible else { return }
            self.hideIfOutsideClick(at: NSEvent.mouseLocation)
        }
    }

    private func stopOutsideClickMonitoring() {
        if let localMouseDownMonitor {
            NSEvent.removeMonitor(localMouseDownMonitor)
            self.localMouseDownMonitor = nil
        }
        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
            self.globalMouseDownMonitor = nil
        }
    }

    private func startFocusMonitoring(for panel: NSPanel) {
        stopFocusMonitoring()

        panelResignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hideIfPanelLostFocus()
            }
        }

        appResignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hide()
            }
        }
    }

    private func stopFocusMonitoring() {
        if let panelResignKeyObserver {
            NotificationCenter.default.removeObserver(panelResignKeyObserver)
            self.panelResignKeyObserver = nil
        }
        if let appResignActiveObserver {
            NotificationCenter.default.removeObserver(appResignActiveObserver)
            self.appResignActiveObserver = nil
        }
    }

    private func startScreenParameterMonitoring(for panel: NSPanel) {
        stopScreenParameterMonitoring()
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: NSApp,
            queue: .main
        ) { [weak self, weak panel] _ in
            Task { @MainActor [weak self, weak panel] in
                guard let panel else { return }
                self?.positionVisiblePanel(panel)
            }
        }
    }

    private func stopScreenParameterMonitoring() {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
    }

    private func hideIfPanelLostFocus() {
        guard let panel, panel.isVisible else { return }
        let keyWindow = NSApp.keyWindow
        if keyWindow === panel || Self.isShelfAuxiliaryWindow(keyWindow) {
            return
        }
        hide()
    }

    private func hideIfOutsideClick(at location: CGPoint) {
        guard let panel, panel.isVisible else { return }
        if let ignoreOutsideClicksUntil, Date() < ignoreOutsideClicksUntil {
            return
        }
        ignoreOutsideClicksUntil = nil
        if !panel.frame.contains(location) {
            hide()
        }
    }

    private func screenLocation(for event: NSEvent) -> CGPoint {
        guard let window = event.window else {
            return NSEvent.mouseLocation
        }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private static func isShelfAuxiliaryWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        if window.identifier?.rawValue == ClipboardShelfWindowIdentifiers.sourceAppSuggestionPanel {
            return true
        }
        return String(describing: type(of: window)).contains("Menu")
    }

    private var shouldReduceShelfMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var nativeWindowAnimationBehavior: NSWindow.AnimationBehavior {
        shouldReduceShelfMotion ? .none : .utilityWindow
    }

    private func postVoiceOverAnnouncement(_ message: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSNumber(value: NSAccessibilityPriorityLevel.medium.rawValue)
            ]
        )
    }

    private func activeScreen() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { screen in
            NSMouseInRect(mouseLocation, screen.frame, false)
        }) {
            return screen
        }
        if let mainScreen = NSScreen.main {
            return mainScreen
        }
        return NSScreen.screens[0]
    }

    private func screen(containing frame: NSRect) -> NSScreen? {
        let bestMatch = NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(frame).area < rhs.frame.intersection(frame).area
        }
        guard let bestMatch, bestMatch.frame.intersection(frame).area > 0 else {
            return nil
        }
        return bestMatch
    }
}

private final class ClipboardShelfPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    func configureForRoundedTransparentPanel(cornerRadius: CGFloat) {
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private extension NSRect {
    var area: CGFloat {
        guard !isNull else { return 0 }
        return width * height
    }
}

@MainActor
final class PasteBuddyPanelHotKeyController {
    private let onToggle: @MainActor () -> Void
    private var registration: PasteBuddyCarbonHotKeyRegistration?
    private var eventTap: PasteBuddyPanelHotKeyEventTap?
    private var triggerGate = PasteBuddyPanelHotKeyTriggerGate()

    init(onToggle: @escaping @MainActor () -> Void) {
        self.onToggle = onToggle
        let handler: @MainActor (PasteBuddyPanelHotKeySource) -> Void = { [weak self] source in
            self?.triggerToggle(source: source)
        }
        eventTap = PasteBuddyPanelHotKeyEventTap(onToggle: { handler(.eventTap) })
        registration = PasteBuddyCarbonHotKeyRegistration(onToggle: { handler(.carbon) })
    }

    private func triggerToggle(source: PasteBuddyPanelHotKeySource) {
        guard triggerGate.shouldTrigger(source: source) else { return }
        onToggle()
    }
}

enum PasteBuddyPanelHotKeySource: String, Sendable {
    case carbon
    case eventTap
}

struct PasteBuddyPanelHotKeyTriggerGate {
    private var lastTriggerDate: Date?
    var duplicateInterval: TimeInterval = 0.25

    mutating func shouldTrigger(source: PasteBuddyPanelHotKeySource, now: Date = Date()) -> Bool {
        if let lastTriggerDate, now.timeIntervalSince(lastTriggerDate) < duplicateInterval {
            PasteBuddyDiagnostics.record(.hotKey, "ignoredDuplicate", detail: "source=\(source.rawValue)")
            return false
        }
        lastTriggerDate = now
        PasteBuddyDiagnostics.record(.hotKey, "pressed", detail: "source=\(source.rawValue)")
        return true
    }
}

private final class PasteBuddyCarbonHotKeyRegistration {
    private let onToggle: @MainActor () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    init(onToggle: @escaping @MainActor () -> Void) {
        self.onToggle = onToggle
        installEventHandler()
        registerShowHideHotKey()
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    private func installEventHandler() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let eventRef, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr,
                      hotKeyID.signature == pasteBuddyHotKeySignature,
                      hotKeyID.id == pasteBuddyShowHideHotKeyID else {
                    return noErr
                }

                let registration = Unmanaged<PasteBuddyCarbonHotKeyRegistration>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                registration.handlePressedHotKey()
                return noErr
            },
            1,
            &eventSpec,
            selfPointer,
            &eventHandler
        )
        PasteBuddyDiagnostics.record(.hotKey, "carbonHandlerInstalled", detail: "status=\(status)")
        guard status == noErr else {
            eventHandler = nil
            return
        }
    }

    private func registerShowHideHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        let hotKeyID = EventHotKeyID(signature: pasteBuddyHotKeySignature, id: pasteBuddyShowHideHotKeyID)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        PasteBuddyDiagnostics.record(.hotKey, "carbonRegistered", detail: "status=\(status)")
        guard status == noErr else {
            hotKeyRef = nil
            return
        }
    }

    private func handlePressedHotKey() {
        Task { @MainActor [onToggle] in
            onToggle()
        }
    }
}

final class PasteBuddyPanelHotKeyEventTap {
    private let onToggle: @MainActor () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(onToggle: @escaping @MainActor () -> Void) {
        self.onToggle = onToggle
        installEventTap()
    }

    deinit {
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }

    private func installEventTap() {
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userData in
                guard let userData else {
                    return Unmanaged.passUnretained(event)
                }
                let eventTap = Unmanaged<PasteBuddyPanelHotKeyEventTap>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                return eventTap.handle(type: type, event: event)
            },
            userInfo: selfPointer
        ) else {
            PasteBuddyDiagnostics.record(.hotKey, "eventTapInstallFailed")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        PasteBuddyDiagnostics.record(.hotKey, "eventTapInstalled")
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            PasteBuddyDiagnostics.record(.hotKey, "eventTapReenabled", detail: "type=\(type.rawValue)")
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard PasteBuddyPanelHotKeyMatcher.matches(keyCode: keyCode, flags: event.flags) else {
            return Unmanaged.passUnretained(event)
        }

        PasteBuddyDiagnostics.record(.hotKey, "eventTapMatched", detail: "keyCode=\(keyCode)")
        Task { @MainActor [onToggle] in
            onToggle()
        }
        return nil
    }
}

enum PasteBuddyPanelHotKeyMatcher {
    static func matches(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard keyCode == Int64(kVK_ANSI_V),
              flags.contains(.maskCommand),
              flags.contains(.maskShift),
              !flags.contains(.maskAlternate),
              !flags.contains(.maskControl)
        else {
            return false
        }
        return true
    }
}

private let pasteBuddyHotKeySignature: OSType = 0x50425348
private let pasteBuddyShowHideHotKeyID: UInt32 = 1
