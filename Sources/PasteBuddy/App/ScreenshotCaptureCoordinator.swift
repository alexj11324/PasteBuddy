import AppKit
import ApplicationServices
import Observation
import PasteBuddyCore
import SwiftUI

enum ScreenshotCaptureMode: String, Sendable {
    case `static`
    case long
}

enum ScreenshotCaptureCompletion {
    case copy
    case save
    case pin
    case long
}

enum ScreenshotSuggestionTarget: String, CaseIterable, Sendable {
    case uiElement
    case window
}

@MainActor
@Observable
final class ScreenshotCaptureSessionModel {
    let screenFrame: CGRect
    let backgroundImage: NSImage
    let mode: ScreenshotCaptureMode
    var selection: CGRect
    var pointer = CGPoint.zero
    var aspectLock = CaptureAspectLock.free
    var suggestionTarget = ScreenshotSuggestionTarget.uiElement
    var cornerRadius: CGFloat = 0
    var borderWidth: CGFloat = 0
    var shadowRadius: CGFloat = 0
    var showsCursor = false
    var hasManualSelection = false
    var statusMessage: String?
    var isWorking = false
    @ObservationIgnored var onComplete: (ScreenshotCaptureCompletion) -> Void
    @ObservationIgnored var onCancel: () -> Void
    @ObservationIgnored var onHover: (CGPoint) -> Void
    @ObservationIgnored var onCopyColor: (String) -> Void
    @ObservationIgnored var onRecallRegion: () -> Void

    init(
        screenFrame: CGRect,
        backgroundImage: NSImage,
        mode: ScreenshotCaptureMode,
        selection: CGRect,
        onComplete: @escaping (ScreenshotCaptureCompletion) -> Void,
        onCancel: @escaping () -> Void,
        onHover: @escaping (CGPoint) -> Void,
        onCopyColor: @escaping (String) -> Void,
        onRecallRegion: @escaping () -> Void
    ) {
        self.screenFrame = screenFrame
        self.backgroundImage = backgroundImage
        self.mode = mode
        self.selection = selection
        self.onComplete = onComplete
        self.onCancel = onCancel
        self.onHover = onHover
        self.onCopyColor = onCopyColor
        self.onRecallRegion = onRecallRegion
    }

    var localBounds: CGRect {
        CGRect(origin: .zero, size: screenFrame.size)
    }

    var selectionAppKitRect: CGRect {
        CGRect(
            x: screenFrame.minX + selection.minX,
            y: screenFrame.maxY - selection.maxY,
            width: selection.width,
            height: selection.height
        )
    }

    var colorAtPointer: ScreenPinColor? {
        guard let cgImage = backgroundImage.pasteBuddyCGImage else { return nil }
        let scaleX = CGFloat(cgImage.width) / max(screenFrame.width, 1)
        let scaleY = CGFloat(cgImage.height) / max(screenFrame.height, 1)
        let x = min(max(Int(pointer.x * scaleX), 0), cgImage.width - 1)
        let y = min(max(Int(pointer.y * scaleY), 0), cgImage.height - 1)
        guard let crop = cgImage.cropping(
            to: CGRect(x: x, y: y, width: 1, height: 1)
        ) else {
            return nil
        }
        return crop.pasteBuddyCenterPixelColor
    }

    var magnifierImage: NSImage? {
        guard let cgImage = backgroundImage.pasteBuddyCGImage else { return nil }
        let scaleX = CGFloat(cgImage.width) / max(screenFrame.width, 1)
        let scaleY = CGFloat(cgImage.height) / max(screenFrame.height, 1)
        let size = 15
        let x = min(max(Int(pointer.x * scaleX) - size / 2, 0), max(0, cgImage.width - size))
        let y = min(max(Int(pointer.y * scaleY) - size / 2, 0), max(0, cgImage.height - size))
        guard let crop = cgImage.cropping(
            to: CGRect(x: x, y: y, width: min(size, cgImage.width), height: min(size, cgImage.height))
        ) else {
            return nil
        }
        return NSImage(cgImage: crop, size: NSSize(width: 105, height: 105))
    }

    func resize(width: CGFloat, height: CGFloat) {
        selection = CaptureSelectionGeometry.resized(
            selection,
            width: width,
            height: height,
            in: localBounds,
            aspectLock: aspectLock
        )
        hasManualSelection = true
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 53:
            onCancel()
        case 36:
            onComplete(.copy)
        case 8:
            if modifiers.contains(.shift) {
                onComplete(.copy)
            } else if let color = colorAtPointer {
                onCopyColor(color.hexString)
            }
        case 15:
            onRecallRegion()
        case 50:
            showsCursor.toggle()
        case 123, 124, 125, 126:
            let dx: CGFloat = event.keyCode == 123 ? -1 : event.keyCode == 124 ? 1 : 0
            let dy: CGFloat = event.keyCode == 125 ? 1 : event.keyCode == 126 ? -1 : 0
            if modifiers.contains(.shift) {
                selection = CaptureSelectionGeometry.resizedEdge(
                    selection,
                    dx: dx,
                    dy: dy,
                    grow: false,
                    in: localBounds
                )
            } else if modifiers.contains(.control) {
                selection = CaptureSelectionGeometry.resizedEdge(
                    selection,
                    dx: dx,
                    dy: dy,
                    grow: true,
                    in: localBounds
                )
            } else {
                selection = CaptureSelectionGeometry.moved(selection, dx: dx, dy: dy, in: localBounds)
            }
            hasManualSelection = true
        default:
            return false
        }
        return true
    }
}

@MainActor
final class ScreenshotCaptureCoordinator {
    private enum PersistenceKey {
        static let recentRegions = "PasteBuddyScreenshotRecentRegions"
    }

    private let store: PasteBuddyStore
    private let service = ScreenCaptureService()
    private var overlayPanel: ScreenshotCaptureOverlayPanel?
    private var presentationTask: Task<Void, Never>?
    private var model: ScreenshotCaptureSessionModel?
    private var longCaptureController: LongScreenshotController?
    private var recentRegionIndex = 0

    init(store: PasteBuddyStore) {
        self.store = store
    }

    func start(mode: ScreenshotCaptureMode = .static, delay: Duration = .zero) {
        guard overlayPanel == nil, presentationTask == nil else { return }
        if !service.isAuthorized {
            guard service.requestAuthorization() else {
                showError(ScreenCaptureServiceError.permissionRequired)
                return
            }
        }
        PasteBuddyDiagnostics.record(
            .capture,
            "requested",
            detail: "mode=\(mode.rawValue) delay=\(delay)"
        )
        presentationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.presentationTask = nil }
            do {
                if delay > .zero {
                    try await Task.sleep(for: delay)
                }
                try await self.presentOverlay(mode: mode)
            } catch is CancellationError {
                return
            } catch {
                self.showError(error)
            }
        }
    }

    private func presentOverlay(mode: ScreenshotCaptureMode) async throws {
        let mouse = NSEvent.mouseLocation
        guard let geometry = service.displayGeometry(containingAppKit: mouse) else {
            throw ScreenCaptureServiceError.noDisplay
        }
        let screenshot = try await service.capture(
            quartzRect: geometry.quartzFrame,
            showsCursor: false
        )
        let background = NSImage(cgImage: screenshot, size: geometry.appKitFrame.size)
        let initialSelection = recalledRegions().first.map { appKitRect in
            localRect(fromAppKit: appKitRect, screenFrame: geometry.appKitFrame)
        } ?? CGRect(
            x: geometry.appKitFrame.width * 0.2,
            y: geometry.appKitFrame.height * 0.2,
            width: geometry.appKitFrame.width * 0.6,
            height: geometry.appKitFrame.height * 0.6
        )
        let model = ScreenshotCaptureSessionModel(
            screenFrame: geometry.appKitFrame,
            backgroundImage: background,
            mode: mode,
            selection: CaptureSelectionGeometry.clamped(
                initialSelection,
                to: CGRect(origin: .zero, size: geometry.appKitFrame.size)
            ),
            onComplete: { [weak self] completion in
                self?.complete(completion)
            },
            onCancel: { [weak self] in
                self?.cancel()
            },
            onHover: { [weak self] point in
                self?.updateSuggestedSelection(at: point)
            },
            onCopyColor: { [weak self] color in
                self?.copyColor(color)
            },
            onRecallRegion: { [weak self] in
                self?.recallNextRegion()
            }
        )
        self.model = model
        let panel = ScreenshotCaptureOverlayPanel(
            contentRect: geometry.appKitFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .black
        panel.isOpaque = true
        panel.hasShadow = false
        panel.setAccessibilityLabel(NSLocalizedString("label.screenshot_capture_overlay", comment: ""))
        panel.onKeyDown = { [weak model] event in
            model?.handleKey(event) == true
        }
        panel.contentView = NSHostingView(rootView: ScreenshotCaptureOverlayView(model: model))
        overlayPanel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        PasteBuddyDiagnostics.record(
            .capture,
            "overlayPresented",
            detail: "screen=\(NSStringFromRect(geometry.appKitFrame))"
        )
    }

    private func updateSuggestedSelection(at point: CGPoint) {
        guard let model else { return }
        model.pointer = point
        guard !model.hasManualSelection else { return }
        let appKitPoint = CGPoint(
            x: model.screenFrame.minX + point.x,
            y: model.screenFrame.maxY - point.y
        )
        let suggestedRect = switch model.suggestionTarget {
        case .uiElement:
            accessibilityElementRect(atAppKit: appKitPoint, screenFrame: model.screenFrame)
                ?? windowRect(atAppKit: appKitPoint, screenFrame: model.screenFrame)
        case .window:
            windowRect(atAppKit: appKitPoint, screenFrame: model.screenFrame)
        }
        if let rect = suggestedRect {
            model.selection = CaptureSelectionGeometry.clamped(
                localRect(fromAppKit: rect, screenFrame: model.screenFrame),
                to: model.localBounds
            )
        }
    }

    private func complete(_ completion: ScreenshotCaptureCompletion) {
        guard let model, !model.isWorking else { return }
        if completion == .long || model.mode == .long {
            remember(model.selectionAppKitRect)
            let rect = model.selectionAppKitRect
            dismissOverlay()
            let controller = LongScreenshotController(store: store, captureRect: rect)
            longCaptureController = controller
            controller.onFinish = { [weak self] in
                self?.longCaptureController = nil
            }
            controller.present()
            return
        }

        model.isWorking = true
        let selection = model.selectionAppKitRect
        let style = CapturedImageStyle(
            cornerRadius: model.cornerRadius,
            borderWidth: model.borderWidth,
            shadowRadius: model.shadowRadius
        )
        let showsCursor = model.showsCursor
        dismissOverlay(keepModel: true)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let quartzRect = try self.service.quartzRect(fromAppKit: selection)
                let captured = try await self.service.capture(
                    quartzRect: quartzRect,
                    showsCursor: showsCursor
                )
                let rendered = try CapturedImageRenderer.render(captured, style: style)
                let item = try CapturedImageHistoryWriter(store: self.store).storeImage(
                    rendered,
                    titleKey: "label.screenshot"
                )
                self.remember(selection)
                switch completion {
                case .copy:
                    ClipboardPanelCopyCoordinator.copy(item)
                case .save:
                    try self.saveImage(item)
                case .pin:
                    ScreenPinController.shared.pin(item, preferredFrame: selection)
                case .long:
                    break
                }
                PasteBuddyDiagnostics.record(
                    .capture,
                    "completed",
                    detail: "action=\(String(describing: completion)) size=\(rendered.width)x\(rendered.height)"
                )
            } catch {
                self.showError(error)
            }
            self.model = nil
        }
    }

    private func saveImage(_ item: ClipboardItem) throws {
        guard let data = item.payload.imageData else {
            throw ScreenCaptureServiceError.imageEncodingFailed
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(item.title).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try data.write(to: url, options: .atomic)
    }

    private func copyColor(_ color: String) {
        let item = ClipboardItem(
            sourceAppName: NSLocalizedString("source.pastebuddy_color_picker", comment: ""),
            sourceBundleIdentifier: Bundle.main.bundleIdentifier,
            deviceName: Host.current().localizedName
                ?? NSLocalizedString("label.this_mac", comment: ""),
            contentType: .text,
            title: color,
            payload: ClipboardPayload(text: color)
        )
        ClipboardPanelCopyCoordinator.copy(store.addCapturedItem(item), sourceWindow: overlayPanel)
    }

    private func recallNextRegion() {
        guard let model else { return }
        let regions = recalledRegions().filter { $0.intersects(model.screenFrame) }
        guard !regions.isEmpty else { return }
        recentRegionIndex = (recentRegionIndex + 1) % regions.count
        model.selection = CaptureSelectionGeometry.clamped(
            localRect(fromAppKit: regions[recentRegionIndex], screenFrame: model.screenFrame),
            to: model.localBounds
        )
        model.hasManualSelection = true
    }

    private func remember(_ rect: CGRect) {
        var regions = recalledRegions()
        regions.removeAll { $0.equalTo(rect) }
        regions.insert(rect, at: 0)
        let data = try? JSONEncoder().encode(Array(regions.prefix(10)))
        UserDefaults.standard.set(data, forKey: PersistenceKey.recentRegions)
        recentRegionIndex = 0
    }

    private func recalledRegions() -> [CGRect] {
        guard let data = UserDefaults.standard.data(forKey: PersistenceKey.recentRegions) else {
            return []
        }
        return (try? JSONDecoder().decode([CGRect].self, from: data)) ?? []
    }

    private func accessibilityElementRect(atAppKit point: CGPoint, screenFrame: CGRect) -> CGRect? {
        guard AccessibilityPermissionService.isTrusted,
              let geometry = service.displayGeometry(containingAppKit: point) else {
            return nil
        }
        let quartzPoint = geometry.quartzRect(
            fromAppKit: CGRect(origin: point, size: CGSize(width: 1, height: 1))
        ).origin
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(),
            Float(quartzPoint.x),
            Float(quartzPoint.y),
            &element
        ) == .success,
              let element,
              let quartzRect = elementFrame(element) else {
            return nil
        }
        let appKitRect = geometry.appKitRect(fromQuartz: quartzRect)
        guard screenFrame.intersects(appKitRect) else { return nil }
        return appKitRect.intersection(screenFrame)
    }

    private func elementFrame(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
              AXUIElementCopyAttributeValue(
                  element,
                  kAXSizeAttribute as CFString,
                  &sizeValue
              ) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.width >= CaptureSelectionGeometry.minimumSize.width,
              size.height >= CaptureSelectionGeometry.minimumSize.height else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func windowRect(atAppKit point: CGPoint, screenFrame: CGRect) -> CGRect? {
        guard let geometry = service.displayGeometry(containingAppKit: point) else { return nil }
        let quartzPoint = geometry.quartzRect(
            fromAppKit: CGRect(origin: point, size: CGSize(width: 1, height: 1))
        ).origin
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) != ownPID,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: NSNumber],
                  let x = bounds["X"]?.doubleValue,
                  let y = bounds["Y"]?.doubleValue,
                  let width = bounds["Width"]?.doubleValue,
                  let height = bounds["Height"]?.doubleValue else {
                continue
            }
            let quartzRect = CGRect(x: x, y: y, width: width, height: height)
            guard
                  quartzRect.width >= CaptureSelectionGeometry.minimumSize.width,
                  quartzRect.height >= CaptureSelectionGeometry.minimumSize.height else {
                continue
            }
            guard quartzRect.contains(quartzPoint) else { continue }
            return geometry.appKitRect(fromQuartz: quartzRect).intersection(screenFrame)
        }
        return nil
    }

    private func localRect(fromAppKit rect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.minX - screenFrame.minX,
            y: screenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private func cancel() {
        PasteBuddyDiagnostics.record(.capture, "cancelled")
        dismissOverlay()
    }

    private func dismissOverlay(keepModel: Bool = false) {
        overlayPanel?.orderOut(nil)
        overlayPanel = nil
        if !keepModel {
            model = nil
        }
    }

    private func showError(_ error: Error) {
        PasteBuddyDiagnostics.record(.capture, "failed", detail: error.localizedDescription)
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}

private final class ScreenshotCaptureOverlayPanel: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true {
            super.keyDown(with: event)
        }
    }
}

private struct ScreenshotCaptureOverlayView: View {
    @Bindable var model: ScreenshotCaptureSessionModel
    @State private var dragStart: CGPoint?
    @State private var manualWidth = ""
    @State private var manualHeight = ""

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Image(nsImage: model.backgroundImage)
                    .resizable()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(selectionGesture)
                    .onTapGesture(count: 2) {
                        model.onComplete(.copy)
                    }
                selectionShade(size: proxy.size)
                selectionBorder
                magnifier
                controls
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    model.pointer = point
                    model.onHover(point)
                case .ended:
                    break
                }
            }
            .onAppear {
                manualWidth = "\(Int(model.selection.width))"
                manualHeight = "\(Int(model.selection.height))"
            }
            .onChange(of: model.selection) {
                manualWidth = "\(Int(model.selection.width))"
                manualHeight = "\(Int(model.selection.height))"
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("label.screenshot_capture_overlay", comment: ""))
    }

    private func selectionShade(size: CGSize) -> some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: size))
            path.addRoundedRect(
                in: model.selection,
                cornerSize: CGSize(width: model.cornerRadius, height: model.cornerRadius)
            )
        }
        .fill(.black.opacity(0.48), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    private var selectionBorder: some View {
        RoundedRectangle(cornerRadius: model.cornerRadius)
            .strokeBorder(.white, lineWidth: max(1, model.borderWidth))
            .frame(width: model.selection.width, height: model.selection.height)
            .position(x: model.selection.midX, y: model.selection.midY)
            .shadow(
                color: .black.opacity(model.shadowRadius > 0 ? 0.65 : 0),
                radius: min(model.shadowRadius, 12)
            )
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var magnifier: some View {
        if let image = model.magnifierImage, let color = model.colorAtPointer {
            VStack(spacing: 3) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 105, height: 105)
                    .overlay {
                        Rectangle()
                            .stroke(.white, lineWidth: 1)
                        Rectangle()
                            .stroke(.red, lineWidth: 1)
                            .frame(width: 7, height: 7)
                    }
                Text(color.hexString)
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
            }
            .padding(6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .position(
                x: min(model.pointer.x + 78, model.screenFrame.width - 70),
                y: min(model.pointer.y + 88, model.screenFrame.height - 80)
            )
            .allowsHitTesting(false)
            .accessibilityLabel(
                String(
                    format: NSLocalizedString("format.color", comment: ""),
                    color.hexString
                )
            )
        }
    }

    private var controls: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Picker("label.selection_target", selection: suggestionTargetBinding) {
                    Text("label.ui_element").tag(ScreenshotSuggestionTarget.uiElement)
                    Text("label.window").tag(ScreenshotSuggestionTarget.window)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                Picker("", selection: aspectBinding) {
                    Text("label.aspect_free").tag(0)
                    Text("label.aspect_square").tag(1)
                    Text("label.aspect_current").tag(2)
                }
                .labelsHidden()
                .frame(width: 130)
                TextField("label.width", text: $manualWidth)
                    .frame(width: 58)
                    .onSubmit { applyManualSize() }
                Text("×")
                TextField("label.height", text: $manualHeight)
                    .frame(width: 58)
                    .onSubmit { applyManualSize() }
                Stepper(
                    NSLocalizedString("label.corner_radius", comment: ""),
                    value: $model.cornerRadius,
                    in: 0...64,
                    step: 2
                )
                    .frame(width: 120)
                Toggle("label.cursor", isOn: $model.showsCursor)
                    .toggleStyle(.button)
                Toggle("label.border", isOn: borderBinding)
                    .toggleStyle(.button)
                Toggle("label.shadow", isOn: shadowBinding)
                    .toggleStyle(.button)
                Button("action.copy_color") {
                    if let color = model.colorAtPointer {
                        model.onCopyColor(color.hexString)
                    }
                }
                Button("action.recall_region") {
                    model.onRecallRegion()
                }
                if model.mode == .static {
                    Button("action.long_screenshot") {
                        model.onComplete(.long)
                    }
                    Button("action.pin_to_screen") {
                        model.onComplete(.pin)
                    }
                }
                Button("action.save") {
                    model.onComplete(.save)
                }
                Button("action.copy") {
                    model.onComplete(.copy)
                }
                .keyboardShortcut(.return, modifiers: [])
                Button("action.cancel") {
                    model.onCancel()
                }
            }
            .controlSize(.small)
            .padding(10)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 24)
    }

    private var selectionGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = value.startLocation
                }
                model.selection = CaptureSelectionGeometry.selection(
                    from: dragStart ?? value.startLocation,
                    to: value.location,
                    in: model.localBounds,
                    aspectLock: model.aspectLock
                )
                model.hasManualSelection = true
            }
            .onEnded { _ in
                dragStart = nil
            }
    }

    private var aspectBinding: Binding<Int> {
        Binding(
            get: {
                switch model.aspectLock {
                case .free: 0
                case .square: 1
                case .ratio: 2
                }
            },
            set: { value in
                switch value {
                case 1:
                    model.aspectLock = .square
                case 2:
                    model.aspectLock = .ratio(
                        model.selection.width / max(model.selection.height, 1)
                    )
                default:
                    model.aspectLock = .free
                }
            }
        )
    }

    private var suggestionTargetBinding: Binding<ScreenshotSuggestionTarget> {
        Binding(
            get: { model.suggestionTarget },
            set: {
                model.suggestionTarget = $0
                model.hasManualSelection = false
                model.onHover(model.pointer)
            }
        )
    }

    private var borderBinding: Binding<Bool> {
        Binding(
            get: { model.borderWidth > 0 },
            set: { model.borderWidth = $0 ? 2 : 0 }
        )
    }

    private var shadowBinding: Binding<Bool> {
        Binding(
            get: { model.shadowRadius > 0 },
            set: { model.shadowRadius = $0 ? 14 : 0 }
        )
    }

    private func applyManualSize() {
        guard let width = Double(manualWidth),
              let height = Double(manualHeight) else {
            return
        }
        model.resize(width: width, height: height)
    }
}

private extension NSImage {
    var pasteBuddyCGImage: CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

private extension CGImage {
    var pasteBuddyCenterPixelColor: ScreenPinColor? {
        var pixel = [UInt8](repeating: 0, count: 4)
        let rendered = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.draw(self, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard rendered else { return nil }
        return ScreenPinColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: CGFloat(pixel[3]) / 255
        )
    }
}
