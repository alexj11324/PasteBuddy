import AppKit
import Carbon
import PasteBuddyCore
import QuartzCore
import SwiftUI

extension Notification.Name {
    static let pasteBuddyCopyPanelSelection = Notification.Name("PasteBuddyCopyPanelSelection")
    static let pasteBuddyPastePanelSelection = Notification.Name("PasteBuddyPastePanelSelection")
    static let pasteBuddyPanelArrowKey = Notification.Name("PasteBuddyPanelArrowKey")
    static let pasteBuddyPanelPreviewKey = Notification.Name("PasteBuddyPanelPreviewKey")
    static let pasteBuddyPanelQuickPaste = Notification.Name("PasteBuddyPanelQuickPaste")
}

@MainActor
enum ClipboardPanelPasteCommandRouter {
    static func shouldRouteSelectionPaste(firstResponder: NSResponder?) -> Bool {
        if let textView = firstResponder as? NSTextView {
            return !textView.isEditable
        }
        if let textField = firstResponder as? NSTextField {
            return !textField.isEditable || !textField.isEnabled
        }
        return true
    }

    static func forwardNativePaste(firstResponder: NSResponder?, sender: Any?) {
        if let textView = firstResponder as? NSTextView {
            textView.paste(sender)
        } else if let textField = firstResponder as? NSTextField {
            textField.selectText(sender)
            (textField.currentEditor() as? NSTextView)?.paste(sender)
        }
    }
}

struct ClipboardPanelArrowKeyCommand: Equatable {
    let offset: Int
    let extendsSelection: Bool

    static func resolve(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> ClipboardPanelArrowKeyCommand? {
        let offset: Int
        switch Int(keyCode) {
        case kVK_LeftArrow, kVK_UpArrow:
            offset = -1
        case kVK_RightArrow, kVK_DownArrow:
            offset = 1
        default:
            return nil
        }
        let modifiers = modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
        guard modifiers.isEmpty || modifiers == .shift else { return nil }
        return ClipboardPanelArrowKeyCommand(offset: offset, extendsSelection: modifiers == .shift)
    }
}

enum ClipboardPanelPreviewKeyCommand {
    static func matches(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        let modifiers = modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
        return Int(keyCode) == kVK_Space && modifiers.isEmpty
    }
}

@MainActor
final class ClipboardPanelArrowKeyRequest {
    let command: ClipboardPanelArrowKeyCommand
    private(set) var isHandled = false

    init(command: ClipboardPanelArrowKeyCommand) {
        self.command = command
    }

    func markHandled() {
        isHandled = true
    }
}

@MainActor
final class ClipboardPanelPreviewKeyRequest {
    private(set) var isHandled = false

    func markHandled() {
        isHandled = true
    }
}

@MainActor
final class ClipboardPanelQuickPasteRequest {
    let oneBasedIndex: Int
    let format: PasteFormat
    private(set) var isHandled = false

    init(oneBasedIndex: Int, format: PasteFormat) {
        self.oneBasedIndex = oneBasedIndex
        self.format = format
    }

    func markHandled() {
        isHandled = true
    }
}

@MainActor
enum ClipboardPanelCopyGate {
    struct Request {
        let generation: Int
        let pasteboardChangeCount: Int
    }

    private static var generation = 0

    static func begin(pasteboard: NSPasteboard = .general) -> Request {
        generation += 1
        return Request(generation: generation, pasteboardChangeCount: pasteboard.changeCount)
    }

    static func shouldWrite(_ request: Request, pasteboard: NSPasteboard = .general) -> Bool {
        request.generation == generation && request.pasteboardChangeCount == pasteboard.changeCount
    }
}

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

enum ClipboardPanelHotKeyToggleDecision: Equatable {
    case hide
    case show(ClipboardPanelDisplayMode)

    static func resolve(
        isVisible: Bool,
        isDismissing: Bool,
        currentMode: ClipboardPanelDisplayMode,
        requestedMode: ClipboardPanelDisplayMode
    ) -> Self {
        if isVisible, !isDismissing, currentMode == requestedMode {
            return .hide
        }
        return .show(requestedMode)
    }
}

@MainActor
final class ClipboardShelfPanelController: NSObject {
    private static let dragSessionDismissalDelayNanoseconds: UInt64 = 350_000_000
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
    private var localMouseUpMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var globalMouseDownMonitor: Any?
    private var globalMouseUpMonitor: Any?
    private var isPanelPointerSessionActive = false
    private var pointerSessionEndRetryGeneration = 0
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
        super.init()
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    var isDismissing: Bool {
        isAnimatingPanelOut
    }

    func routeQuickPasteToVisiblePanel(oneBasedIndex: Int, format: PasteFormat) -> Bool {
        guard isVisible else { return false }
        let request = ClipboardPanelQuickPasteRequest(oneBasedIndex: oneBasedIndex, format: format)
        NotificationCenter.default.post(name: .pasteBuddyPanelQuickPaste, object: request)
        return request.isHandled
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
        panel.sharingType = store.snapshot.settingsBehavior.showDuringScreenSharing ? .readOnly : .none
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
        Self.applyPanelFrame(finalFrame, to: panel, display: false)
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
        stopPanelKeyMonitoring()
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
        stopPanelKeyMonitoring()
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
        applyCollectionBehavior(to: panel)
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
        hostingView.configureForTransparentPanel()
        panel.contentView = hostingView
        return panel
    }

    private func reloadPanelContent(_ panel: ClipboardShelfPanel) {
        guard let hostingView = panel.contentView as? FirstMouseHostingView<AnyView> else { return }
        closeShelfAuxiliaryWindows()
        hostingView.rootView = panelContentView()
        hostingView.configureForTransparentPanel()
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
                    isPinned: panelPinnedBinding(),
                    directPasteItem: directPasteItem,
                    directPasteItems: directPasteItems,
                    reloadClipboardHistory: { [store] in
                        await store.loadAsync()
                    },
                    onLayoutChange: { [weak self] in
                        guard let self, let panel = self.panel, panel.isVisible else { return }
                        self.positionVisiblePanel(panel)
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
                    isPinned: panelPinnedBinding(),
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
            let height = panelHeight(for: panel, in: screen.visibleFrame)
            return Self.attachedFrame(
                for: placement,
                screenFrame: screenFrame,
                visibleFrame: screen.visibleFrame,
                height: height
            )
        case .sidePanel:
            let preferredSize = preferredContentSize(for: .sidePanel, screenFrame: screen.visibleFrame)
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
        let usableFrame = visibleFrame.intersection(screenFrame)
        let resolvedFrame = usableFrame.isNull || usableFrame.isEmpty ? screenFrame : usableFrame
        let resolvedHeight = min(max(height, 0), resolvedFrame.height)
        let y = switch placement {
        case .top:
            resolvedFrame.maxY - resolvedHeight
        case .bottom:
            resolvedFrame.minY
        }
        return CGRect(
            x: resolvedFrame.minX,
            y: y,
            width: resolvedFrame.width,
            height: resolvedHeight
        )
    }

    private func panelHeight(for panel: NSPanel, in visibleFrame: NSRect) -> CGFloat {
        let minimumHeight = min(
            ClipboardShelfMetrics.requiredPanelHeight(showsActiveFilters: false),
            visibleFrame.height
        )
        let maximumHeight = max(minimumHeight, min(visibleFrame.height, 440))
        panel.contentView?.setFrameSize(NSSize(width: visibleFrame.width, height: maximumHeight))
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
        let usableFrame = visibleFrame.intersection(screenFrame)
        let resolvedFrame = usableFrame.isNull || usableFrame.isEmpty ? screenFrame : usableFrame
        let availableWidth = max(0, resolvedFrame.width - sidePanelHorizontalInset * 2)
        let availableHeight = max(0, resolvedFrame.height - sidePanelTopInset * 2)
        let width = min(max(preferredSize.width, 320), availableWidth)
        let height = min(max(preferredSize.height, 480), availableHeight)
        let x = resolvedFrame.maxX - sidePanelHorizontalInset - width
        let y = resolvedFrame.maxY - sidePanelTopInset - height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func positionVisiblePanel(_ panel: NSPanel) {
        let finalFrame = attachedFrame(for: panel)
        Self.applyPanelFrame(finalFrame, to: panel, display: panel.isVisible)
    }

    static func applyPanelFrame(_ frame: NSRect, to panel: NSPanel, display: Bool) {
        panel.setFrame(frame, display: display)
        panel.contentView?.setFrameSize(frame.size)
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    private func startDismissalMonitoring(for panel: NSPanel) {
        startOutsideClickMonitoring(for: panel)
        startPanelKeyMonitoring(for: panel)
        startFocusMonitoring(for: panel)
    }

    private func startPanelKeyMonitoring(for panel: NSPanel) {
        stopPanelKeyMonitoring()
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak panel] event in
            guard let panel, panel.isVisible, event.window === panel else {
                return event
            }
            if let command = ClipboardPanelArrowKeyCommand.resolve(
                      keyCode: event.keyCode,
                      modifierFlags: event.modifierFlags
                  ) {
                let request = ClipboardPanelArrowKeyRequest(command: command)
                NotificationCenter.default.post(name: .pasteBuddyPanelArrowKey, object: request)
                return request.isHandled ? nil : event
            }
            guard ClipboardPanelPreviewKeyCommand.matches(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags
            ) else {
                return event
            }
            let request = ClipboardPanelPreviewKeyRequest()
            NotificationCenter.default.post(name: .pasteBuddyPanelPreviewKey, object: request)
            return request.isHandled ? nil : event
        }
    }

    private func stopPanelKeyMonitoring() {
        guard let localKeyDownMonitor else { return }
        NSEvent.removeMonitor(localKeyDownMonitor)
        self.localKeyDownMonitor = nil
    }

    private func startOutsideClickMonitoring(for panel: NSPanel) {
        stopOutsideClickMonitoring()

        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self, weak panel] event in
            guard let self, let panel, panel.isVisible else { return event }
            if event.type == .leftMouseDown, event.window === panel {
                self.beginPanelPointerSession()
            }
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

        localMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.endPanelPointerSession()
            return event
        }

        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            self?.endPanelPointerSession()
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
        if let localMouseUpMonitor {
            NSEvent.removeMonitor(localMouseUpMonitor)
            self.localMouseUpMonitor = nil
        }
        if let globalMouseUpMonitor {
            NSEvent.removeMonitor(globalMouseUpMonitor)
            self.globalMouseUpMonitor = nil
        }
        isPanelPointerSessionActive = false
        pointerSessionEndRetryGeneration &+= 1
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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(auxiliaryWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil,
        )

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
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
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
        if let keyWindow, Self.isShelfAuxiliaryWindow(keyWindow) {
            keyWindow.sharingType = panel.sharingType
            return
        }
        guard Self.shouldDismissForLostFocus(
            isPinned: isPinned,
            isDragSessionActive: isPanelPointerSessionActive
        ) else { return }
        if shouldIgnoreDismissalAt(NSEvent.mouseLocation) {
            return
        }
        if keyWindow === panel {
            return
        }
        hide()
    }

    @objc private func auxiliaryWindowDidBecomeKey(_ notification: Notification) {
        guard let panel, let candidate = notification.object as? NSWindow else { return }
        let hasProtectedAuxiliaryWindow = NSApp.windows.contains { window in
            window !== candidate
                && window.isVisible
                && Self.isShelfAuxiliaryWindow(window)
                && window.sharingType == .none
        }
        guard Self.shouldProtectNestedShelfAuxiliaryWindow(
            isShelfVisible: panel.isVisible,
            hidesShelfFromCapture: panel.sharingType == .none,
            isCandidateAuxiliaryWindow: Self.isShelfAuxiliaryWindow(candidate),
            hasProtectedAuxiliaryWindow: hasProtectedAuxiliaryWindow
        ) else { return }
        candidate.sharingType = .none
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
            isPinned: isPinned,
            isDragSessionActive: isPanelPointerSessionActive
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
        isPinned: Bool = false,
        isDragSessionActive: Bool = false
    ) -> Bool {
        guard !isPinned else { return false }
        guard !isDragSessionActive else { return false }
        guard !isIgnoredDismissalTargetHit else { return false }
        return !panelFrame.contains(location) && !isShelfAuxiliaryWindowHit
    }

    static func shouldKeepPointerSession(
        primaryButtonPressed: Bool,
        dragPasteboardHasItems: Bool
    ) -> Bool {
        primaryButtonPressed || dragPasteboardHasItems
    }

    static func shouldDismissForLostFocus(
        isPinned: Bool,
        isDragSessionActive: Bool
    ) -> Bool {
        !isPinned && !isDragSessionActive
    }

    static func panelCollectionBehavior(
        isPinned: Bool,
        isDragSessionActive: Bool
    ) -> NSWindow.CollectionBehavior {
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if !isPinned && !isDragSessionActive {
            behavior.insert(.transient)
        }
        return behavior
    }

    static func shouldProtectNestedShelfAuxiliaryWindow(
        isShelfVisible: Bool,
        hidesShelfFromCapture: Bool,
        isCandidateAuxiliaryWindow: Bool,
        hasProtectedAuxiliaryWindow: Bool
    ) -> Bool {
        isShelfVisible
            && hidesShelfFromCapture
            && isCandidateAuxiliaryWindow
            && hasProtectedAuxiliaryWindow
    }

    private func hideIfAppLostFocus() {
        guard Self.shouldDismissForLostFocus(
            isPinned: isPinned,
            isDragSessionActive: isPanelPointerSessionActive
        ) else { return }
        hideImmediately()
    }

    private func beginPanelPointerSession() {
        guard !isPanelPointerSessionActive else { return }
        isPanelPointerSessionActive = true
        if let panel {
            applyCollectionBehavior(to: panel)
        }
    }

    private func endPanelPointerSession() {
        guard isPanelPointerSessionActive else { return }
        if Self.shouldKeepPointerSession(
            primaryButtonPressed: (NSEvent.pressedMouseButtons & (1 << 0)) != 0,
            dragPasteboardHasItems: !(NSPasteboard(name: .drag).types ?? []).isEmpty
        ) {
            schedulePointerSessionEndRetry()
            return
        }
        pointerSessionEndRetryGeneration &+= 1
        isPanelPointerSessionActive = false
        if let panel {
            applyCollectionBehavior(to: panel)
        }
        guard Self.shouldDismissForLostFocus(
            isPinned: isPinned,
            isDragSessionActive: false
        ) else { return }
        dismissAfterPointerSessionIfNeeded()
    }

    private func schedulePointerSessionEndRetry() {
        pointerSessionEndRetryGeneration &+= 1
        let generation = pointerSessionEndRetryGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let self, self.pointerSessionEndRetryGeneration == generation else { return }
            self.endPanelPointerSession()
        }
    }

    private func dismissAfterPointerSessionIfNeeded() {
        if NSApp.isActive {
            hideIfPanelLostFocus()
            return
        }
        let generation = panelAnimationGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.dragSessionDismissalDelayNanoseconds)
            guard let self, self.panelAnimationGeneration == generation else { return }
            guard Self.shouldDismissForLostFocus(
                isPinned: self.isPinned,
                isDragSessionActive: self.isPanelPointerSessionActive
            ) else { return }
            if NSApp.isActive {
                self.hideIfPanelLostFocus()
            } else {
                self.hideImmediately()
            }
        }
    }

    private func applyCollectionBehavior(to panel: NSPanel) {
        panel.collectionBehavior = Self.panelCollectionBehavior(
            isPinned: isPinned,
            isDragSessionActive: isPanelPointerSessionActive
        )
    }

    private func panelPinnedBinding() -> Binding<Bool> {
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
        if let panel {
            applyCollectionBehavior(to: panel)
        }
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

final class ClipboardShelfPanel: NSPanel, PasteBuddyScreenSharingProtectedWindow {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    @objc func paste(_ sender: Any?) {
        guard ClipboardPanelPasteCommandRouter.shouldRouteSelectionPaste(
            firstResponder: firstResponder
        ) else {
            ClipboardPanelPasteCommandRouter.forwardNativePaste(
                firstResponder: firstResponder,
                sender: sender
            )
            return
        }
        NotificationCenter.default.post(name: .pasteBuddyPastePanelSelection, object: self)
    }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    @objc func copy(_ sender: Any?) {
        NotificationCenter.default.post(name: .pasteBuddyCopyPanelSelection, object: self)
    }

    func configureForTransparentPanel() {
        wantsLayer = true
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
    private var sidePanelShortcut: ShortcutBinding
    private var pasteStackShortcut: ShortcutBinding
    private var nextPinboardShortcut: ShortcutBinding
    private var previousPinboardShortcut: ShortcutBinding
    private var quickPasteModifiers: [ShortcutModifier]
    private var plainTextQuickPasteModifiers: [ShortcutModifier]
    private var isQuickPasteEnabled: Bool
    private let onSidePanel: @MainActor () -> Void
    private let onPasteStack: @MainActor () -> Void
    private let onShelf: @MainActor () -> Void
    private let onPinClipboard: @MainActor () -> Void
    private let onNextPinboard: @MainActor () -> Void
    private let onPreviousPinboard: @MainActor () -> Void
    private let onQuickPaste: @MainActor (Int, PasteFormat) -> Void
    private var registration: PasteBuddyCarbonHotKeyRegistration?
    private var eventTap: PasteBuddyPanelHotKeyEventTap?
    private var triggerGate = PasteBuddyPanelHotKeyTriggerGate()
    private var shortcutRecordingObserver: NSObjectProtocol?
    private var isShortcutRecordingActive = false

    init(
        sidePanelShortcut: ShortcutBinding = ShortcutConfiguration().showHidePanel,
        onSidePanel: @escaping @MainActor () -> Void,
        onPasteStack: @escaping @MainActor () -> Void,
        onShelf: @escaping @MainActor () -> Void,
        onPinClipboard: @escaping @MainActor () -> Void,
        onNextPinboard: @escaping @MainActor () -> Void,
        onPreviousPinboard: @escaping @MainActor () -> Void,
        onQuickPaste: @escaping @MainActor (Int, PasteFormat) -> Void
    ) {
        let defaults = ShortcutConfiguration()
        self.sidePanelShortcut = Self.validatedSidePanelShortcut(sidePanelShortcut)
        pasteStackShortcut = defaults.activatePasteStack
        nextPinboardShortcut = defaults.showNextPinboard
        previousPinboardShortcut = defaults.showPreviousPinboard
        quickPasteModifiers = defaults.quickPasteModifiers
        plainTextQuickPasteModifiers = defaults.plainTextQuickPasteModifiers
        isQuickPasteEnabled = defaults.isQuickPasteEnabled
        self.onSidePanel = onSidePanel
        self.onPasteStack = onPasteStack
        self.onShelf = onShelf
        self.onPinClipboard = onPinClipboard
        self.onNextPinboard = onNextPinboard
        self.onPreviousPinboard = onPreviousPinboard
        self.onQuickPaste = onQuickPaste
        let handler: @MainActor (PasteBuddyPanelHotKeyAction, PasteBuddyPanelHotKeySource) -> Void = { [weak self] action, source in
            self?.trigger(action: action, source: source)
        }
        installHotKeySources(handler: handler)
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

    func updateSidePanelShortcut(_ shortcut: ShortcutBinding) {
        let validatedShortcut = Self.validatedSidePanelShortcut(shortcut)
        guard sidePanelShortcut != validatedShortcut else { return }
        sidePanelShortcut = validatedShortcut
        registration = nil
        eventTap = nil
        let handler: @MainActor (PasteBuddyPanelHotKeyAction, PasteBuddyPanelHotKeySource) -> Void = { [weak self] action, source in
            self?.trigger(action: action, source: source)
        }
        installHotKeySources(handler: handler)
        if isShortcutRecordingActive {
            setHotKeySourcesEnabled(false)
        }
        PasteBuddyDiagnostics.record(.hotKey, "configurationUpdated", detail: "sidePanel=\(validatedShortcut.displayName)")
    }

    func updateShortcuts(_ shortcuts: ShortcutConfiguration) {
        let validatedSidePanelShortcut = Self.validatedSidePanelShortcut(shortcuts.showHidePanel)
        guard sidePanelShortcut != validatedSidePanelShortcut
                || pasteStackShortcut != shortcuts.activatePasteStack
                || nextPinboardShortcut != shortcuts.showNextPinboard
                || previousPinboardShortcut != shortcuts.showPreviousPinboard
                || quickPasteModifiers != shortcuts.quickPasteModifiers
                || plainTextQuickPasteModifiers != shortcuts.plainTextQuickPasteModifiers
                || isQuickPasteEnabled != shortcuts.isQuickPasteEnabled else { return }
        sidePanelShortcut = validatedSidePanelShortcut
        pasteStackShortcut = shortcuts.activatePasteStack
        nextPinboardShortcut = shortcuts.showNextPinboard
        previousPinboardShortcut = shortcuts.showPreviousPinboard
        quickPasteModifiers = shortcuts.quickPasteModifiers
        plainTextQuickPasteModifiers = shortcuts.plainTextQuickPasteModifiers
        isQuickPasteEnabled = shortcuts.isQuickPasteEnabled
        registration = nil
        eventTap = nil
        let handler: @MainActor (PasteBuddyPanelHotKeyAction, PasteBuddyPanelHotKeySource) -> Void = { [weak self] action, source in
            self?.trigger(action: action, source: source)
        }
        installHotKeySources(handler: handler)
        if isShortcutRecordingActive {
            setHotKeySourcesEnabled(false)
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
        case .pasteStack:
            onPasteStack()
        case .shelf:
            onShelf()
        case .pinClipboard:
            onPinClipboard()
        case .nextPinboard:
            onNextPinboard()
        case .previousPinboard:
            onPreviousPinboard()
        case .quickPaste(let index, let format):
            onQuickPaste(index, format)
        }
    }

    private func setShortcutRecordingActive(_ isRecording: Bool) {
        guard isShortcutRecordingActive != isRecording else { return }
        isShortcutRecordingActive = isRecording
        setHotKeySourcesEnabled(!isRecording)
    }

    private func installHotKeySources(
        handler: @escaping @MainActor (PasteBuddyPanelHotKeyAction, PasteBuddyPanelHotKeySource) -> Void
    ) {
        eventTap = PasteBuddyPanelHotKeyEventTap(
            sidePanelShortcut: sidePanelShortcut,
            pasteStackShortcut: pasteStackShortcut,
            nextPinboardShortcut: nextPinboardShortcut,
            previousPinboardShortcut: previousPinboardShortcut,
            quickPasteModifiers: quickPasteModifiers,
            plainTextQuickPasteModifiers: plainTextQuickPasteModifiers,
            isQuickPasteEnabled: isQuickPasteEnabled,
            onAction: { action in handler(action, .eventTap) }
        )
        registration = PasteBuddyCarbonHotKeyRegistration(
            sidePanelShortcut: sidePanelShortcut,
            pasteStackShortcut: pasteStackShortcut,
            nextPinboardShortcut: nextPinboardShortcut,
            previousPinboardShortcut: previousPinboardShortcut,
            quickPasteModifiers: quickPasteModifiers,
            plainTextQuickPasteModifiers: plainTextQuickPasteModifiers,
            isQuickPasteEnabled: isQuickPasteEnabled,
            onAction: { action in handler(action, .carbon) }
        )
        PasteBuddyDiagnostics.record(.hotKey, "configurationApplied", detail: "sidePanel=\(sidePanelShortcut.displayName)")
    }

    private func setHotKeySourcesEnabled(_ isEnabled: Bool) {
        registration?.setEnabled(isEnabled)
        eventTap?.setEnabled(isEnabled)
    }

    private static func validatedSidePanelShortcut(_ shortcut: ShortcutBinding) -> ShortcutBinding {
        let effectiveKeyCode = PasteBuddyPanelHotKeyMatcher.keyCode(for: shortcut)
        let conflictsWithFixedHotKey =
            PasteBuddyPanelHotKeyMatcher.carbonModifiers(for: shortcut) == UInt32(cmdKey | shiftKey)
            && effectiveKeyCode.map {
                [UInt32(kVK_ANSI_S), UInt32(kVK_ANSI_P)].contains($0)
            } == true
        guard shortcut.isValidShowHidePanelShortcut, !conflictsWithFixedHotKey else {
            PasteBuddyDiagnostics.record(.hotKey, "configurationRejected", detail: "sidePanel=\(shortcut.displayName)")
            return ShortcutConfiguration().showHidePanel
        }
        return shortcut
    }
}

enum PasteBuddyPanelHotKeyAction: Hashable, Sendable {
    case sidePanel
    case pasteStack
    case shelf
    case pinClipboard
    case nextPinboard
    case previousPinboard
    case quickPaste(index: Int, format: PasteFormat)

    var diagnosticName: String {
        switch self {
        case .sidePanel: "sidePanel"
        case .pasteStack: "pasteStack"
        case .shelf: "shelf"
        case .pinClipboard: "pinClipboard"
        case .nextPinboard: "nextPinboard"
        case .previousPinboard: "previousPinboard"
        case .quickPaste(let index, let format): "quickPaste.\(index).\(format.rawValue)"
        }
    }
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
    private let sidePanelShortcut: ShortcutBinding
    private let pasteStackShortcut: ShortcutBinding
    private let nextPinboardShortcut: ShortcutBinding
    private let previousPinboardShortcut: ShortcutBinding
    private let quickPasteModifiers: [ShortcutModifier]
    private let plainTextQuickPasteModifiers: [ShortcutModifier]
    private let isQuickPasteEnabled: Bool
    private let onAction: @MainActor (PasteBuddyPanelHotKeyAction) -> Void
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?

    init(
        sidePanelShortcut: ShortcutBinding,
        pasteStackShortcut: ShortcutBinding,
        nextPinboardShortcut: ShortcutBinding,
        previousPinboardShortcut: ShortcutBinding,
        quickPasteModifiers: [ShortcutModifier],
        plainTextQuickPasteModifiers: [ShortcutModifier],
        isQuickPasteEnabled: Bool,
        onAction: @escaping @MainActor (PasteBuddyPanelHotKeyAction) -> Void
    ) {
        self.sidePanelShortcut = sidePanelShortcut
        self.pasteStackShortcut = pasteStackShortcut
        self.nextPinboardShortcut = nextPinboardShortcut
        self.previousPinboardShortcut = previousPinboardShortcut
        self.quickPasteModifiers = quickPasteModifiers
        self.plainTextQuickPasteModifiers = plainTextQuickPasteModifiers
        self.isQuickPasteEnabled = isQuickPasteEnabled
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
        registerHotKey(
            id: pasteBuddySidePanelHotKeyID,
            keyCode: PasteBuddyPanelHotKeyMatcher.keyCode(for: sidePanelShortcut),
            modifiers: PasteBuddyPanelHotKeyMatcher.carbonModifiers(for: sidePanelShortcut)
        )
        registerHotKey(
            id: pasteBuddyPasteStackHotKeyID,
            keyCode: PasteBuddyPanelHotKeyMatcher.keyCode(for: pasteStackShortcut),
            modifiers: PasteBuddyPanelHotKeyMatcher.carbonModifiers(for: pasteStackShortcut)
        )
        registerHotKey(id: pasteBuddyShelfHotKeyID, keyCode: UInt32(kVK_ANSI_S))
        registerHotKey(id: pasteBuddyPinClipboardHotKeyID, keyCode: UInt32(kVK_ANSI_P))
        registerHotKey(
            id: pasteBuddyNextPinboardHotKeyID,
            keyCode: PasteBuddyPanelHotKeyMatcher.keyCode(for: nextPinboardShortcut),
            modifiers: PasteBuddyPanelHotKeyMatcher.carbonModifiers(for: nextPinboardShortcut)
        )
        if isQuickPasteEnabled {
            for (offset, keyCode) in PasteBuddyPanelHotKeyMatcher.digitKeyCodes.enumerated() {
                registerHotKey(
                    id: pasteBuddyQuickPasteHotKeyIDBase + UInt32(offset),
                    keyCode: UInt32(keyCode),
                    modifiers: PasteBuddyPanelHotKeyMatcher.carbonModifiers(for: quickPasteModifiers)
                )
                registerHotKey(
                    id: pasteBuddyPlainTextQuickPasteHotKeyIDBase + UInt32(offset),
                    keyCode: UInt32(keyCode),
                    modifiers: PasteBuddyPanelHotKeyMatcher.carbonModifiers(for: plainTextQuickPasteModifiers)
                )
            }
        }
        registerHotKey(
            id: pasteBuddyPreviousPinboardHotKeyID,
            keyCode: PasteBuddyPanelHotKeyMatcher.keyCode(for: previousPinboardShortcut),
            modifiers: PasteBuddyPanelHotKeyMatcher.carbonModifiers(for: previousPinboardShortcut)
        )
    }

    private func registerHotKey(
        id: UInt32,
        keyCode: UInt32?,
        modifiers: UInt32 = UInt32(cmdKey | shiftKey)
    ) {
        guard let keyCode else {
            PasteBuddyDiagnostics.record(.hotKey, "carbonRegistrationSkipped", detail: "id=\(id)")
            return
        }
        let hotKeyID = EventHotKeyID(signature: pasteBuddyHotKeySignature, id: id)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
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
        case pasteBuddyPasteStackHotKeyID:
            return .pasteStack
        case pasteBuddyShelfHotKeyID:
            return .shelf
        case pasteBuddyPinClipboardHotKeyID:
            return .pinClipboard
        case pasteBuddyNextPinboardHotKeyID:
            return .nextPinboard
        case pasteBuddyPreviousPinboardHotKeyID:
            return .previousPinboard
        case pasteBuddyQuickPasteHotKeyIDBase..<(pasteBuddyQuickPasteHotKeyIDBase + 9):
            return .quickPaste(index: Int(hotKeyID - pasteBuddyQuickPasteHotKeyIDBase), format: .original)
        case pasteBuddyPlainTextQuickPasteHotKeyIDBase..<(pasteBuddyPlainTextQuickPasteHotKeyIDBase + 9):
            return .quickPaste(index: Int(hotKeyID - pasteBuddyPlainTextQuickPasteHotKeyIDBase), format: .plainText)
        default:
            return nil
        }
    }
}

final class PasteBuddyPanelHotKeyEventTap {
    private let sidePanelShortcut: ShortcutBinding
    private let pasteStackShortcut: ShortcutBinding
    private let nextPinboardShortcut: ShortcutBinding
    private let previousPinboardShortcut: ShortcutBinding
    private let quickPasteModifiers: [ShortcutModifier]
    private let plainTextQuickPasteModifiers: [ShortcutModifier]
    private let isQuickPasteEnabled: Bool
    private let onAction: @MainActor (PasteBuddyPanelHotKeyAction) -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(
        sidePanelShortcut: ShortcutBinding,
        pasteStackShortcut: ShortcutBinding,
        nextPinboardShortcut: ShortcutBinding,
        previousPinboardShortcut: ShortcutBinding,
        quickPasteModifiers: [ShortcutModifier],
        plainTextQuickPasteModifiers: [ShortcutModifier],
        isQuickPasteEnabled: Bool,
        onAction: @escaping @MainActor (PasteBuddyPanelHotKeyAction) -> Void
    ) {
        self.sidePanelShortcut = sidePanelShortcut
        self.pasteStackShortcut = pasteStackShortcut
        self.nextPinboardShortcut = nextPinboardShortcut
        self.previousPinboardShortcut = previousPinboardShortcut
        self.quickPasteModifiers = quickPasteModifiers
        self.plainTextQuickPasteModifiers = plainTextQuickPasteModifiers
        self.isQuickPasteEnabled = isQuickPasteEnabled
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
        guard let action = PasteBuddyPanelHotKeyMatcher.action(
            keyCode: keyCode,
            flags: event.flags,
            sidePanelShortcut: sidePanelShortcut,
            pasteStackShortcut: pasteStackShortcut,
            nextPinboardShortcut: nextPinboardShortcut,
            previousPinboardShortcut: previousPinboardShortcut,
            quickPasteModifiers: quickPasteModifiers,
            plainTextQuickPasteModifiers: plainTextQuickPasteModifiers,
            isQuickPasteEnabled: isQuickPasteEnabled
        ) else {
            return Unmanaged.passUnretained(event)
        }

        PasteBuddyDiagnostics.record(.hotKey, "eventTapMatched", detail: "keyCode=\(keyCode) action=\(action.diagnosticName)")
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

    static func action(
        keyCode: Int64,
        flags: CGEventFlags,
        sidePanelShortcut: ShortcutBinding = ShortcutConfiguration().showHidePanel,
        pasteStackShortcut: ShortcutBinding = ShortcutConfiguration().activatePasteStack,
        nextPinboardShortcut: ShortcutBinding = ShortcutConfiguration().showNextPinboard,
        previousPinboardShortcut: ShortcutBinding = ShortcutConfiguration().showPreviousPinboard,
        quickPasteModifiers: [ShortcutModifier] = ShortcutConfiguration().quickPasteModifiers,
        plainTextQuickPasteModifiers: [ShortcutModifier] = ShortcutConfiguration().plainTextQuickPasteModifiers,
        isQuickPasteEnabled: Bool = ShortcutConfiguration().isQuickPasteEnabled
    ) -> PasteBuddyPanelHotKeyAction? {
        if relevantFlags(flags) == [.maskCommand, .maskShift] {
            switch keyCode {
            case Int64(kVK_ANSI_S):
                return .shelf
            case Int64(kVK_ANSI_P):
                return .pinClipboard
            default:
                break
            }
        }
        if sidePanelShortcut.isValidShowHidePanelShortcut,
           let sidePanelKeyCode = Self.keyCode(for: sidePanelShortcut),
           keyCode == Int64(sidePanelKeyCode),
           relevantFlags(flags) == eventFlags(for: sidePanelShortcut) {
            return .sidePanel
        }
        if let pasteStackKeyCode = Self.keyCode(for: pasteStackShortcut),
           keyCode == Int64(pasteStackKeyCode),
           relevantFlags(flags) == eventFlags(for: pasteStackShortcut) {
            return .pasteStack
        }
        if let nextPinboardKeyCode = Self.keyCode(for: nextPinboardShortcut),
           keyCode == Int64(nextPinboardKeyCode),
           relevantFlags(flags) == eventFlags(for: nextPinboardShortcut) {
            return .nextPinboard
        }
        if let previousPinboardKeyCode = Self.keyCode(for: previousPinboardShortcut),
           keyCode == Int64(previousPinboardKeyCode),
           relevantFlags(flags) == eventFlags(for: previousPinboardShortcut) {
            return .previousPinboard
        }
        if isQuickPasteEnabled,
           let index = digitKeyCodes.firstIndex(of: Int(keyCode)) {
            if relevantFlags(flags) == eventFlags(for: quickPasteModifiers) {
                return .quickPaste(index: index, format: .original)
            }
            if relevantFlags(flags) == eventFlags(for: plainTextQuickPasteModifiers) {
                return .quickPaste(index: index, format: .plainText)
            }
        }
        return nil
    }

    static let digitKeyCodes = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
    ]

    static func keyCode(for shortcut: ShortcutBinding) -> UInt32? {
        guard shortcut.isEnabled else { return nil }
        return shortcut.effectivePhysicalKeyCode.map(UInt32.init)
    }

    static func carbonModifiers(for shortcut: ShortcutBinding) -> UInt32 {
        shortcut.modifiers.reduce(into: UInt32(0)) { result, modifier in
            switch modifier {
            case .command: result |= UInt32(cmdKey)
            case .option: result |= UInt32(optionKey)
            case .shift: result |= UInt32(shiftKey)
            case .control: result |= UInt32(controlKey)
            }
        }
    }

    static func carbonModifiers(for modifiers: [ShortcutModifier]) -> UInt32 {
        ShortcutBinding(key: "1", modifiers: modifiers).modifiers.reduce(into: UInt32(0)) { result, modifier in
            switch modifier {
            case .command: result |= UInt32(cmdKey)
            case .option: result |= UInt32(optionKey)
            case .shift: result |= UInt32(shiftKey)
            case .control: result |= UInt32(controlKey)
            }
        }
    }

    private static func eventFlags(for shortcut: ShortcutBinding) -> CGEventFlags {
        shortcut.modifiers.reduce(into: CGEventFlags()) { result, modifier in
            switch modifier {
            case .command: result.insert(.maskCommand)
            case .option: result.insert(.maskAlternate)
            case .shift: result.insert(.maskShift)
            case .control: result.insert(.maskControl)
            }
        }
    }

    private static func eventFlags(for modifiers: [ShortcutModifier]) -> CGEventFlags {
        ShortcutBinding(key: "1", modifiers: modifiers).modifiers.reduce(into: CGEventFlags()) { result, modifier in
            switch modifier {
            case .command: result.insert(.maskCommand)
            case .option: result.insert(.maskAlternate)
            case .shift: result.insert(.maskShift)
            case .control: result.insert(.maskControl)
            }
        }
    }

    private static func relevantFlags(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection([.maskCommand, .maskAlternate, .maskShift, .maskControl])
    }

}

private let pasteBuddyHotKeySignature: OSType = 0x50425348
private let pasteBuddySidePanelHotKeyID: UInt32 = 1
private let pasteBuddyPasteStackHotKeyID: UInt32 = 3
private let pasteBuddyShelfHotKeyID: UInt32 = 2
private let pasteBuddyPinClipboardHotKeyID: UInt32 = 4
private let pasteBuddyNextPinboardHotKeyID: UInt32 = 5
private let pasteBuddyPreviousPinboardHotKeyID: UInt32 = 6
private let pasteBuddyQuickPasteHotKeyIDBase: UInt32 = 20
private let pasteBuddyPlainTextQuickPasteHotKeyIDBase: UInt32 = 40

enum PinboardCycleDirection: Sendable {
    case next
    case previous
}

enum PinboardCycleSelection {
    static func destination(
        from currentScope: PasteScope,
        pinboardIDs: [UUID],
        direction: PinboardCycleDirection
    ) -> PasteScope? {
        guard !pinboardIDs.isEmpty else { return nil }
        let currentIndex: Int? = if case .pinboard(let id) = currentScope {
            pinboardIDs.firstIndex(of: id)
        } else {
            nil
        }
        let nextIndex: Int
        switch (currentIndex, direction) {
        case (.none, .next): nextIndex = 0
        case (.none, .previous): nextIndex = pinboardIDs.index(before: pinboardIDs.endIndex)
        case (.some(let index), .next): nextIndex = (index + 1) % pinboardIDs.count
        case (.some(let index), .previous): nextIndex = (index - 1 + pinboardIDs.count) % pinboardIDs.count
        }
        return .pinboard(pinboardIDs[nextIndex])
    }
}

extension Notification.Name {
    static let pasteBuddyCyclePanelPinboard = Notification.Name("PasteBuddyCyclePanelPinboard")
}
