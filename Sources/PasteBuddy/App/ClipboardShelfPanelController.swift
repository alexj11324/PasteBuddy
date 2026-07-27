import AppKit
import Carbon
import PasteBuddyCore
import QuartzCore
import SwiftUI

enum ClipboardShelfPlacement: String, CaseIterable, Identifiable {
    case top
    case bottom

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .top:
            "Shelf at Top"
        case .bottom:
            "Shelf at Bottom"
        }
    }

    var systemImageName: String {
        switch self {
        case .top:
            "rectangle.topthird.inset.filled"
        case .bottom:
            "rectangle.bottomthird.inset.filled"
        }
    }
}

enum ClipboardPanelDisplayMode: String, CaseIterable, Identifiable {
    case shelf
    case sidePanel

    var id: String { rawValue }

    var menuTitleKey: String {
        switch self {
        case .shelf:
            "label.clipboard_shelf"
        case .sidePanel:
            "label.side_panel"
        }
    }

    var systemImageName: String {
        switch self {
        case .shelf:
            "rectangle.bottomthird.inset.filled"
        case .sidePanel:
            "sidebar.right"
        }
    }
}

@MainActor
final class ClipboardShelfPanelController {
    private static let panelCornerRadius: CGFloat = 28
    private static let shelfEntranceDuration: CFTimeInterval = 0.18
    private static let shelfExitDuration: CFTimeInterval = 0.12
    private static let sidePanelPreferredSize = CGSize(width: 360, height: 697)
    nonisolated private static let sidePanelHorizontalInset: CGFloat = 14
    nonisolated private static let sidePanelTopInset: CGFloat = 8

    private let store: PasteBuddyStore
    private let directPasteItem: @MainActor (ClipboardItem, PasteFormat) async -> DirectPasteResult
    private let directPasteItems: @MainActor ([ClipboardItem], PasteFormat) async -> DirectPasteResult
    private let shouldIgnoreDismissalAt: @MainActor (CGPoint) -> Bool
    var displayMode: ClipboardPanelDisplayMode {
        didSet {
            guard oldValue != displayMode, let panel else { return }
            closeShelfAuxiliaryWindows()
            configurePanelForCurrentMode(panel)
            reloadPanelContent(panel)
            positionVisiblePanel(panel)
        }
    }
    var placement: ClipboardShelfPlacement {
        didSet {
            guard oldValue != placement, let panel else { return }
            positionVisiblePanel(panel)
        }
    }
    private var panel: ClipboardShelfPanel?
    private var localMouseDownMonitor: Any?
    private var globalMouseDownMonitor: Any?
    private var panelResignKeyObserver: NSObjectProtocol?
    private var appResignActiveObserver: NSObjectProtocol?
    private var screenParametersObserver: NSObjectProtocol?
    private var ignoreOutsideClicksUntil: Date?
    private var isAnimatingPanelOut = false
    private var isPinned = false
    private var panelAnimationGeneration = 0
    private var panelPresentationID = UUID()

    init(
        store: PasteBuddyStore,
        placement: ClipboardShelfPlacement = .top,
        displayMode: ClipboardPanelDisplayMode = .sidePanel,
        directPasteItem: @escaping @MainActor (ClipboardItem, PasteFormat) async -> DirectPasteResult,
        directPasteItems: @escaping @MainActor ([ClipboardItem], PasteFormat) async -> DirectPasteResult,
        shouldIgnoreDismissalAt: @escaping @MainActor (CGPoint) -> Bool = { _ in false }
    ) {
        self.store = store
        self.placement = placement
        self.displayMode = displayMode
        self.directPasteItem = directPasteItem
        self.directPasteItems = directPasteItems
        self.shouldIgnoreDismissalAt = shouldIgnoreDismissalAt
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
        closeShelfAuxiliaryWindows()
        resetPanelPresentationState()
        panelPresentationID = UUID()
        reloadPanelContent(panel)
        ignoreOutsideClicksUntil = Date().addingTimeInterval(0.35)
        let finalFrame = attachedFrame(for: panel)
        PasteBuddyDiagnostics.record(.shelf, "frameCalculated", detail: NSStringFromRect(finalFrame))
        isAnimatingPanelOut = false
        panelAnimationGeneration += 1
        panel.animationBehavior = .none
        panel.setFrame(finalFrame, display: false)
        preparePanelContentForPresentation(panel)
        startScreenParameterMonitoring(for: panel)
        panel.orderFrontRegardless()
        panel.makeKey()
        animatePanelContentIn(panel)
        PasteBuddyDiagnostics.record(.shelf, "orderedFront", detail: NSStringFromRect(panel.frame))
        postVoiceOverAnnouncement(NSLocalizedString("label.clipboard_shelf_opened", comment: ""))
        startDismissalMonitoring(for: panel)
    }

    func hideImmediately() {
        guard let panel, panel.isVisible else { return }
        PasteBuddyDiagnostics.record(.shelf, "hideImmediate")
        stopOutsideClickMonitoring()
        stopFocusMonitoring()
        stopScreenParameterMonitoring()
        closeShelfAuxiliaryWindows()
        isAnimatingPanelOut = false
        panelAnimationGeneration += 1
        panel.animationBehavior = .none
        resetPanelContentPresentation(panel)
        panel.orderOut(nil)
        postVoiceOverAnnouncement(NSLocalizedString("label.clipboard_shelf_closed", comment: ""))
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        guard !isAnimatingPanelOut else { return }
        PasteBuddyDiagnostics.record(.shelf, "hideRequested")
        stopOutsideClickMonitoring()
        stopFocusMonitoring()
        stopScreenParameterMonitoring()
        closeShelfAuxiliaryWindows()
        guard !shouldReduceShelfMotion else {
            panel.animationBehavior = .none
            resetPanelContentPresentation(panel)
            panel.orderOut(nil)
            postVoiceOverAnnouncement(NSLocalizedString("label.clipboard_shelf_closed", comment: ""))
            return
        }

        isAnimatingPanelOut = true
        panelAnimationGeneration += 1
        let animationGeneration = panelAnimationGeneration
        panel.animationBehavior = .none
        animatePanelContentOut(panel) { [weak self, weak panel] in
            Task { @MainActor [weak self, weak panel] in
                guard let self, let panel, self.panel === panel, self.panelAnimationGeneration == animationGeneration else { return }
                self.isAnimatingPanelOut = false
                self.resetPanelContentPresentation(panel)
                panel.orderOut(nil)
                self.postVoiceOverAnnouncement(NSLocalizedString("label.clipboard_shelf_closed", comment: ""))
            }
        }
    }

    private func makePanel() -> ClipboardShelfPanel {
        let initialSize = preferredContentSize(for: displayMode, screenFrame: activeScreen().frame)
        let panel = ClipboardShelfPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configurePanelForCurrentMode(panel)
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
        panel.ignoresMouseEvents = false
        panel.onCancel = { [weak self] in
            self?.hide()
        }
        let hostingView = FirstMouseHostingView(rootView: panelContentView())
        hostingView.configureForRoundedTransparentPanel(cornerRadius: Self.panelCornerRadius)
        panel.contentView = hostingView
        return panel
    }

    private func reloadPanelContent(_ panel: ClipboardShelfPanel) {
        guard let hostingView = panel.contentView as? FirstMouseHostingView<AnyView> else { return }
        closeShelfAuxiliaryWindows()
        hostingView.rootView = panelContentView()
        hostingView.configureForRoundedTransparentPanel(cornerRadius: Self.panelCornerRadius)
    }

    private func resetPanelPresentationState() {
        store.searchQuery = ""
        store.clearFilters()
        store.selectSingleItem(store.filteredItems(for: store.selectedScope).first?.id)
    }

    private func configurePanelForCurrentMode(_ panel: ClipboardShelfPanel) {
        let title = NSLocalizedString(displayMode.menuTitleKey, comment: "")
        panel.title = title
        panel.hasShadow = displayMode == .sidePanel
        panel.minSize = switch displayMode {
        case .shelf:
            NSSize(width: 760, height: 250)
        case .sidePanel:
            NSSize(width: 320, height: 480)
        }
        panel.setAccessibilityLabel(title)
    }

    private func panelContentView() -> AnyView {
        switch displayMode {
        case .shelf:
            AnyView(
                ClipboardShelfPanelView(
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
                .id(panelPresentationID)
            )
        case .sidePanel:
            AnyView(
                ClipboardSidePanelView(
                    store: store,
                    isPinned: sidePanelPinnedBinding(),
                    directPasteItem: directPasteItem,
                    directPasteItems: directPasteItems
                ) { [weak self] in
                    self?.hide()
                } onDismissImmediately: { [weak self] in
                    self?.hideImmediately()
                }
                .id(panelPresentationID)
            )
        }
    }

    private func preparePanelContentForPresentation(_ panel: NSPanel) {
        guard !shouldReduceShelfMotion, let layer = panel.contentView?.layer else {
            resetPanelContentPresentation(panel)
            return
        }
        layer.removeAllAnimations()
        layer.opacity = 0
        layer.transform = CATransform3DMakeTranslation(0, -14, 0)
    }

    private func animatePanelContentIn(_ panel: NSPanel) {
        guard !shouldReduceShelfMotion, let layer = panel.contentView?.layer else {
            resetPanelContentPresentation(panel)
            return
        }
        layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.shelfEntranceDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.18, 0.86, 0.24, 1))
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    private func animatePanelContentOut(_ panel: NSPanel, completion: @escaping () -> Void) {
        guard let layer = panel.contentView?.layer else {
            completion()
            return
        }
        layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.shelfExitDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.32, 0, 0.67, 0))
        CATransaction.setCompletionBlock(completion)
        layer.opacity = 0
        layer.transform = CATransform3DMakeTranslation(0, -10, 0)
        CATransaction.commit()
    }

    private func resetPanelContentPresentation(_ panel: NSPanel) {
        guard let layer = panel.contentView?.layer else { return }
        layer.removeAllAnimations()
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
    }

    private func attachedFrame(for panel: NSPanel) -> NSRect {
        let screen = activeScreen()
        let screenFrame = screen.frame
        switch displayMode {
        case .shelf:
            let height = panelHeight(for: panel, in: screenFrame)
            return Self.attachedFrame(
                for: placement,
                screenFrame: screenFrame,
                visibleFrame: screen.visibleFrame,
                height: height
            )
        case .sidePanel:
            let preferredSize = preferredContentSize(for: .sidePanel, screenFrame: screenFrame)
            panel.contentView?.setFrameSize(preferredSize)
            panel.contentView?.layoutSubtreeIfNeeded()
            return Self.rightAnchoredSidePanelFrame(
                screenFrame: screenFrame,
                visibleFrame: screen.visibleFrame,
                preferredSize: preferredSize
            )
        }
    }

    nonisolated static func attachedFrame(
        for placement: ClipboardShelfPlacement,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        height: CGFloat
    ) -> CGRect {
        let resolvedHeight = min(max(height, 0), screenFrame.height)
        let y = switch placement {
        case .top:
            max(screenFrame.minY, min(visibleFrame.maxY, screenFrame.maxY) - resolvedHeight)
        case .bottom:
            screenFrame.minY
        }
        return CGRect(
            x: screenFrame.minX,
            y: y,
            width: screenFrame.width,
            height: resolvedHeight
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

    private func preferredContentSize(for displayMode: ClipboardPanelDisplayMode, screenFrame: NSRect) -> NSSize {
        switch displayMode {
        case .shelf:
            NSSize(width: screenFrame.width, height: 292)
        case .sidePanel:
            NSSize(
                width: min(Self.sidePanelPreferredSize.width, max(320, screenFrame.width - Self.sidePanelHorizontalInset * 2)),
                height: min(Self.sidePanelPreferredSize.height, max(480, screenFrame.height - Self.sidePanelTopInset * 2))
            )
        }
    }

    nonisolated static func rightAnchoredSidePanelFrame(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        preferredSize: CGSize
    ) -> CGRect {
        let width = min(max(preferredSize.width, 320), max(320, screenFrame.width - sidePanelHorizontalInset * 2))
        let height = min(max(preferredSize.height, 480), max(480, screenFrame.height - sidePanelTopInset * 2))
        let rightEdge = min(screenFrame.maxX, visibleFrame.maxX)
        let topEdge = min(screenFrame.maxY, visibleFrame.maxY) - sidePanelTopInset
        let x = max(screenFrame.minX + sidePanelHorizontalInset, rightEdge - width - sidePanelHorizontalInset)
        let y = max(screenFrame.minY + sidePanelTopInset, topEdge - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func positionVisiblePanel(_ panel: NSPanel) {
        let finalFrame = attachedFrame(for: panel)
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
                self?.hideIfAppLostFocus()
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
        guard !isPinned else { return }
        if shouldIgnoreDismissalAt(NSEvent.mouseLocation) {
            return
        }
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
        if Self.shouldDismissForOutsideClick(
            at: location,
            panelFrame: panel.frame,
            isShelfAuxiliaryWindowHit: shelfAuxiliaryWindowContains(location),
            isIgnoredDismissalTargetHit: shouldIgnoreDismissalAt(location),
            isPinned: isPinned
        ) {
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
        return isShelfAuxiliaryWindowClassName(String(describing: type(of: window)))
    }

    static func isShelfAuxiliaryWindowClassName(_ className: String) -> Bool {
        className.contains("Menu") || className.contains("Popover")
    }

    static func shouldDismissForOutsideClick(
        at location: CGPoint,
        panelFrame: CGRect,
        isShelfAuxiliaryWindowHit: Bool,
        isIgnoredDismissalTargetHit: Bool,
        isPinned: Bool = false
    ) -> Bool {
        guard !isPinned else { return false }
        guard !isIgnoredDismissalTargetHit else { return false }
        return !panelFrame.contains(location) && !isShelfAuxiliaryWindowHit
    }

    private func hideIfAppLostFocus() {
        guard !isPinned else { return }
        hideImmediately()
    }

    private func sidePanelPinnedBinding() -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.isPinned ?? false },
            set: { [weak self] value in
                self?.setPinned(value)
            }
        )
    }

    private func setPinned(_ value: Bool) {
        guard isPinned != value else { return }
        isPinned = value
        PasteBuddyDiagnostics.record(.shelf, "pinChanged", detail: "pinned=\(value)")
    }

    private func shelfAuxiliaryWindowContains(_ location: CGPoint) -> Bool {
        NSApp.windows.contains { window in
            window.isVisible
                && Self.isShelfAuxiliaryWindow(window)
                && window.frame.contains(location)
        }
    }

    private func closeShelfAuxiliaryWindows() {
        for window in NSApp.windows where Self.isShelfAuxiliaryWindow(window) {
            window.orderOut(nil)
        }
    }

    private var shouldReduceShelfMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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
    private let onSidePanel: @MainActor () -> Void
    private let onShelf: @MainActor () -> Void
    private var registration: PasteBuddyCarbonHotKeyRegistration?
    private var eventTap: PasteBuddyPanelHotKeyEventTap?
    private var triggerGate = PasteBuddyPanelHotKeyTriggerGate()
    private var shortcutRecordingObserver: NSObjectProtocol?
    private var isShortcutRecordingActive = false

    init(
        onSidePanel: @escaping @MainActor () -> Void,
        onShelf: @escaping @MainActor () -> Void
    ) {
        self.onSidePanel = onSidePanel
        self.onShelf = onShelf
        let handler: @MainActor (PasteBuddyPanelHotKeyAction, PasteBuddyPanelHotKeySource) -> Void = { [weak self] action, source in
            self?.trigger(action: action, source: source)
        }
        eventTap = PasteBuddyPanelHotKeyEventTap(onAction: { action in handler(action, .eventTap) })
        registration = PasteBuddyCarbonHotKeyRegistration(onAction: { action in handler(action, .carbon) })
        shortcutRecordingObserver = NotificationCenter.default.addObserver(
            forName: .pasteBuddyShortcutRecordingDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let isRecording = notification.object as? Bool ?? false
            Task { @MainActor [weak self] in
                self?.setShortcutRecordingActive(isRecording)
            }
        }
    }

    private func trigger(action: PasteBuddyPanelHotKeyAction, source: PasteBuddyPanelHotKeySource) {
        guard !isShortcutRecordingActive else {
            PasteBuddyDiagnostics.record(.hotKey, "ignoredDuringShortcutRecording", detail: "source=\(source.rawValue)")
            return
        }
        guard triggerGate.shouldTrigger(action: action, source: source) else { return }
        switch action {
        case .sidePanel:
            onSidePanel()
        case .shelf:
            onShelf()
        }
    }

    private func setShortcutRecordingActive(_ isRecording: Bool) {
        guard isShortcutRecordingActive != isRecording else { return }
        isShortcutRecordingActive = isRecording
        registration?.setEnabled(!isRecording)
        eventTap?.setEnabled(!isRecording)
    }
}

enum PasteBuddyPanelHotKeyAction: String, Sendable {
    case sidePanel
    case shelf
}

enum PasteBuddyPanelHotKeySource: String, Sendable {
    case carbon
    case eventTap
}

struct PasteBuddyPanelHotKeyTriggerGate {
    private var lastTriggerDateByAction: [PasteBuddyPanelHotKeyAction: Date] = [:]
    var duplicateInterval: TimeInterval = 0.25

    mutating func shouldTrigger(source: PasteBuddyPanelHotKeySource, now: Date = Date()) -> Bool {
        shouldTrigger(action: .sidePanel, source: source, now: now)
    }

    mutating func shouldTrigger(
        action: PasteBuddyPanelHotKeyAction,
        source: PasteBuddyPanelHotKeySource,
        now: Date = Date()
    ) -> Bool {
        if let lastTriggerDate = lastTriggerDateByAction[action],
           now.timeIntervalSince(lastTriggerDate) < duplicateInterval {
            PasteBuddyDiagnostics.record(.hotKey, "ignoredDuplicate", detail: "source=\(source.rawValue)")
            return false
        }
        lastTriggerDateByAction[action] = now
        PasteBuddyDiagnostics.record(.hotKey, "pressed", detail: "source=\(source.rawValue)")
        return true
    }
}

private final class PasteBuddyCarbonHotKeyRegistration {
    private let onAction: @MainActor (PasteBuddyPanelHotKeyAction) -> Void
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?

    init(onAction: @escaping @MainActor (PasteBuddyPanelHotKeyAction) -> Void) {
        self.onAction = onAction
        installEventHandler()
        registerHotKeys()
    }

    deinit {
        unregisterHotKeys()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    func setEnabled(_ isEnabled: Bool) {
        if isEnabled {
            registerHotKeys()
        } else {
            unregisterHotKeys()
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
                      let action = PasteBuddyCarbonHotKeyRegistration.action(for: hotKeyID.id) else {
                    return noErr
                }

                let registration = Unmanaged<PasteBuddyCarbonHotKeyRegistration>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                registration.handlePressedHotKey(action)
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

    private func registerHotKeys() {
        unregisterHotKeys()
        registerHotKey(id: pasteBuddySidePanelHotKeyID, keyCode: UInt32(kVK_ANSI_V))
        registerHotKey(id: pasteBuddyShelfHotKeyID, keyCode: UInt32(kVK_ANSI_S))
    }

    private func registerHotKey(id: UInt32, keyCode: UInt32) {
        let hotKeyID = EventHotKeyID(signature: pasteBuddyHotKeySignature, id: id)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        PasteBuddyDiagnostics.record(.hotKey, "carbonRegistered", detail: "id=\(id) status=\(status)")
        if status == noErr, let hotKeyRef {
            hotKeyRefs[id] = hotKeyRef
        }
    }

    private func unregisterHotKeys() {
        for hotKeyRef in hotKeyRefs.values {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()
    }

    private func handlePressedHotKey(_ action: PasteBuddyPanelHotKeyAction) {
        Task { @MainActor [onAction] in
            onAction(action)
        }
    }

    private static func action(for hotKeyID: UInt32) -> PasteBuddyPanelHotKeyAction? {
        switch hotKeyID {
        case pasteBuddySidePanelHotKeyID:
            return .sidePanel
        case pasteBuddyShelfHotKeyID:
            return .shelf
        default:
            return nil
        }
    }
}

final class PasteBuddyPanelHotKeyEventTap {
    private let onAction: @MainActor (PasteBuddyPanelHotKeyAction) -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(onAction: @escaping @MainActor (PasteBuddyPanelHotKeyAction) -> Void) {
        self.onAction = onAction
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

    func setEnabled(_ isEnabled: Bool) {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: isEnabled)
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
        guard let action = PasteBuddyPanelHotKeyMatcher.action(keyCode: keyCode, flags: event.flags) else {
            return Unmanaged.passUnretained(event)
        }

        PasteBuddyDiagnostics.record(.hotKey, "eventTapMatched", detail: "keyCode=\(keyCode) action=\(action.rawValue)")
        Task { @MainActor [onAction] in
            onAction(action)
        }
        return nil
    }
}

enum PasteBuddyPanelHotKeyMatcher {
    static func matches(keyCode: Int64, flags: CGEventFlags) -> Bool {
        action(keyCode: keyCode, flags: flags) == .sidePanel
    }

    static func action(keyCode: Int64, flags: CGEventFlags) -> PasteBuddyPanelHotKeyAction? {
        guard flags.contains(.maskCommand),
              flags.contains(.maskShift),
              !flags.contains(.maskAlternate),
              !flags.contains(.maskControl) else {
            return nil
        }
        switch keyCode {
        case Int64(kVK_ANSI_V):
            return .sidePanel
        case Int64(kVK_ANSI_S):
            return .shelf
        default:
            return nil
        }
    }
}

private let pasteBuddyHotKeySignature: OSType = 0x50425348
private let pasteBuddySidePanelHotKeyID: UInt32 = 1
private let pasteBuddyShelfHotKeyID: UInt32 = 2
