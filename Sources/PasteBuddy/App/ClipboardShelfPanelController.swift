import AppKit
import Carbon
import PasteBuddyCore
import QuartzCore
import SwiftUI

@MainActor
final class ClipboardShelfPanelController {
    private static let panelCornerRadius: CGFloat = 28

    private let store: PasteBuddyStore
    private let directPasteItem: (ClipboardItem, PasteFormat) -> DirectPasteResult
    private let directPasteItems: ([ClipboardItem], PasteFormat) -> DirectPasteResult
    private var panel: ClipboardShelfPanel?
    private var localMouseDownMonitor: Any?
    private var globalMouseDownMonitor: Any?
    private var panelResignKeyObserver: NSObjectProtocol?
    private var appResignActiveObserver: NSObjectProtocol?
    private var screenParametersObserver: NSObjectProtocol?
    private var outsideClickEventTap: CFMachPort?
    private var outsideClickRunLoopSource: CFRunLoopSource?

    init(
        store: PasteBuddyStore,
        directPasteItem: @escaping (ClipboardItem, PasteFormat) -> DirectPasteResult,
        directPasteItems: @escaping ([ClipboardItem], PasteFormat) -> DirectPasteResult
    ) {
        self.store = store
        self.directPasteItem = directPasteItem
        self.directPasteItems = directPasteItems
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        let finalFrame = bottomAttachedFrame(for: panel)
        panel.setFrame(hiddenFrame(for: finalFrame), display: false)
        startOutsideClickMonitoring(for: panel)
        startFocusMonitoring(for: panel)
        startScreenParameterMonitoring(for: panel)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        animate(panel, to: finalFrame)
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        stopOutsideClickMonitoring()
        stopFocusMonitoring()
        stopScreenParameterMonitoring()
        let hiddenFrame = hiddenFrame(for: panel.frame)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(hiddenFrame, display: true)
        } completionHandler: {
            panel.orderOut(nil)
        }
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
        panel.animationBehavior = .none
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
        let hostingView = FirstMouseHostingView(
            rootView: ClipboardShelfPanelView(
                store: store,
                directPasteItem: directPasteItem,
                directPasteItems: directPasteItems
            ) { [weak self] in
                self?.hide()
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

    private func hiddenFrame(for frame: NSRect) -> NSRect {
        let screen = activeScreen()
        return NSRect(
            x: frame.minX,
            y: screen.frame.minY - frame.height,
            width: frame.width,
            height: frame.height
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

    private func animate(_ panel: NSPanel, to frame: NSRect) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func positionVisiblePanel(_ panel: NSPanel) {
        let finalFrame = bottomAttachedFrame(for: panel)
        if panel.isVisible {
            animate(panel, to: finalFrame)
        } else {
            panel.setFrame(finalFrame, display: false)
        }
    }

    private func startOutsideClickMonitoring(for panel: NSPanel) {
        stopOutsideClickMonitoring()

        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self, weak panel] event in
            guard let self, let panel, panel.isVisible else { return event }
            if Self.isMenuWindow(event.window) {
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

        startOutsideClickEventTap()
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
        stopOutsideClickEventTap()
    }

    private func startOutsideClickEventTap() {
        stopOutsideClickEventTap()

        let eventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: Self.outsideClickEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }

        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            return
        }

        outsideClickEventTap = eventTap
        outsideClickRunLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func stopOutsideClickEventTap() {
        if let outsideClickRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), outsideClickRunLoopSource, .commonModes)
            self.outsideClickRunLoopSource = nil
        }
        if let outsideClickEventTap {
            CFMachPortInvalidate(outsideClickEventTap)
            self.outsideClickEventTap = nil
        }
    }

    private static let outsideClickEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown,
              let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let controller = Unmanaged<ClipboardShelfPanelController>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        let location = event.location
        Task { @MainActor in
            controller.hideIfOutsideClick(atCGEventLocation: location)
        }
        return Unmanaged.passUnretained(event)
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
        if keyWindow === panel || Self.isMenuWindow(keyWindow) {
            return
        }
        hide()
    }

    private func hideIfOutsideClick(at location: CGPoint) {
        guard let panel, panel.isVisible else { return }
        if !panel.frame.contains(location) {
            hide()
        }
    }

    private func hideIfOutsideClick(atCGEventLocation location: CGPoint) {
        guard let panel, panel.isVisible else { return }
        if !panelFrameInCGCoordinates(panel).contains(location) {
            hide()
        }
    }

    private func screenLocation(for event: NSEvent) -> CGPoint {
        guard let window = event.window else {
            return NSEvent.mouseLocation
        }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private func panelFrameInCGCoordinates(_ panel: NSPanel) -> CGRect {
        let frame = panel.frame
        let screen = panel.screen ?? activeScreen()
        return CGRect(
            x: frame.minX,
            y: screen.frame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private static func isMenuWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return String(describing: type(of: window)).contains("Menu")
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
}

private final class ClipboardShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
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

@MainActor
final class PasteBuddyPanelHotKeyController {
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
        InstallEventHandler(
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

                let controller = Unmanaged<PasteBuddyPanelHotKeyController>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                Task { @MainActor in
                    controller.onToggle()
                }
                return noErr
            },
            1,
            &eventSpec,
            selfPointer,
            &eventHandler
        )
    }

    private func registerShowHideHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        let hotKeyID = EventHotKeyID(signature: pasteBuddyHotKeySignature, id: pasteBuddyShowHideHotKeyID)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}

private let pasteBuddyHotKeySignature: OSType = 0x50425348
private let pasteBuddyShowHideHotKeyID: UInt32 = 1
