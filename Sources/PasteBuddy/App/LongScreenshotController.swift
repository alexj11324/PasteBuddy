import AppKit
import Observation
import PasteBuddyCore
import SwiftUI

enum LongScreenshotSessionState: Equatable, Sendable {
    case stopped
    case recording
    case finished
    case failed(String)
}

@MainActor
@Observable
final class LongScreenshotSessionModel {
    var direction = LongScreenshotDirection.vertical
    var state = LongScreenshotSessionState.stopped
    var statusMessage = ""
    var previewImage: NSImage?
    var frameCount = 0
    var outputWidth = 0
    var outputHeight = 0
    var leadingCrop = 0
    var trailingCrop = 0
    @ObservationIgnored var onStart: () -> Void
    @ObservationIgnored var onStop: () -> Void
    @ObservationIgnored var onCancel: () -> Void
    @ObservationIgnored var onCopy: () -> Void
    @ObservationIgnored var onSave: () -> Void
    @ObservationIgnored var onPin: () -> Void
    @ObservationIgnored var onMoveRegion: (CGFloat) -> Void
    @ObservationIgnored var onDirectionChanged: (LongScreenshotDirection) -> Void

    init(
        onStart: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onCopy: @escaping () -> Void,
        onSave: @escaping () -> Void,
        onPin: @escaping () -> Void,
        onMoveRegion: @escaping (CGFloat) -> Void,
        onDirectionChanged: @escaping (LongScreenshotDirection) -> Void
    ) {
        self.onStart = onStart
        self.onStop = onStop
        self.onCancel = onCancel
        self.onCopy = onCopy
        self.onSave = onSave
        self.onPin = onPin
        self.onMoveRegion = onMoveRegion
        self.onDirectionChanged = onDirectionChanged
    }

    var canExport: Bool {
        frameCount > 0 && state != .recording
    }

    var maximumCrop: Int {
        max(0, (direction == .vertical ? outputHeight : outputWidth) - 1)
    }
}

@MainActor
final class LongScreenshotController {
    let store: PasteBuddyStore
    var captureRect: CGRect
    var onFinish: (() -> Void)?

    private let service = ScreenCaptureService()
    private var accumulator = LongScreenshotAccumulator(direction: .vertical)
    private var captureTask: Task<Void, Never>?
    private var controlPanel: LongScreenshotControlPanel?
    private var regionPanel: NSPanel?
    private var model: LongScreenshotSessionModel?

    init(store: PasteBuddyStore, captureRect: CGRect) {
        self.store = store
        self.captureRect = captureRect
    }

    func present() {
        let model = LongScreenshotSessionModel(
            onStart: { [weak self] in self?.start() },
            onStop: { [weak self] in self?.stop() },
            onCancel: { [weak self] in self?.cancel() },
            onCopy: { [weak self] in self?.finish(.copy) },
            onSave: { [weak self] in self?.finish(.save) },
            onPin: { [weak self] in self?.finish(.pin) },
            onMoveRegion: { [weak self] delta in self?.moveRegion(delta) },
            onDirectionChanged: { [weak self] direction in self?.setDirection(direction) }
        )
        self.model = model
        presentRegionOutline()

        let panel = LongScreenshotControlPanel(
            contentRect: controlPanelFrame(),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.setAccessibilityLabel(NSLocalizedString("label.long_screenshot_controls", comment: ""))
        panel.onCancel = { [weak self] in self?.cancel() }
        let hosting = NSHostingView(rootView: LongScreenshotControlView(model: model))
        hosting.setFrameSize(CGSize(width: 330, height: 520))
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        controlPanel = panel
        panel.orderFrontRegardless()
        PasteBuddyDiagnostics.record(
            .capture,
            "longControlsPresented",
            detail: "region=\(NSStringFromRect(captureRect))"
        )
    }

    private func start() {
        guard let model, model.state != .recording else { return }
        accumulator = LongScreenshotAccumulator(direction: model.direction)
        model.frameCount = 0
        model.outputWidth = 0
        model.outputHeight = 0
        model.leadingCrop = 0
        model.trailingCrop = 0
        model.previewImage = nil
        model.state = .recording
        model.statusMessage = NSLocalizedString("message.scroll_the_selected_region_to_continue", comment: "")
        PasteBuddyDiagnostics.record(
            .capture,
            "longStarted",
            detail: "direction=\(model.direction.rawValue) region=\(NSStringFromRect(captureRect))"
        )
        captureTask?.cancel()
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.model?.state == .recording {
                await self.captureFrame()
                do {
                    try await Task.sleep(for: .milliseconds(350))
                } catch {
                    return
                }
            }
        }
    }

    private func stop() {
        captureTask?.cancel()
        captureTask = nil
        guard let model, model.state == .recording else { return }
        model.state = model.frameCount > 0 ? .finished : .stopped
        model.statusMessage = model.frameCount > 0
            ? NSLocalizedString("message.capture_stopped_crop_copy_save_or_pin", comment: "")
            : NSLocalizedString("message.no_frames_were_captured", comment: "")
        PasteBuddyDiagnostics.record(
            .capture,
            "longStopped",
            detail: "frames=\(model.frameCount) size=\(model.outputWidth)x\(model.outputHeight)"
        )
    }

    private func captureFrame() async {
        guard let model, model.state == .recording else { return }
        do {
            let quartzRect = try service.quartzRect(fromAppKit: captureRect)
            let image = try await service.capture(
                quartzRect: quartzRect,
                showsCursor: false
            )
            guard !Task.isCancelled, model.state == .recording else { return }
            let match = try accumulator.append(image)
            switch match {
            case .matched(let overlap, let score):
                model.frameCount = accumulator.segments.count
                model.outputWidth = accumulator.width
                model.outputHeight = accumulator.height
                model.previewImage = NSImage(
                    cgImage: image,
                    size: CGSize(width: image.width, height: image.height)
                )
                model.statusMessage = String(
                    format: NSLocalizedString("format.long_capture_match", comment: ""),
                    overlap,
                    score
                )
                PasteBuddyDiagnostics.record(
                    .capture,
                    "longFrameMatched",
                    detail: "frame=\(model.frameCount) overlap=\(overlap) score=\(score)"
                )
            case .noMovement:
                model.statusMessage = NSLocalizedString("message.scroll_the_selected_region_to_continue", comment: "")
            case .ambiguous(let score):
                fail(
                    String(
                        format: NSLocalizedString("message.the_scrolling_overlap_is_ambiguous_score_2f", comment: ""),
                        score
                    )
                )
            case .noMatch(let score):
                fail(
                    String(
                        format: NSLocalizedString("message.the_next_frame_could_not_be_matched", comment: ""),
                        score ?? -1
                    )
                )
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        captureTask?.cancel()
        captureTask = nil
        model?.state = .failed(message)
        model?.statusMessage = message
        PasteBuddyDiagnostics.record(.capture, "longFailed", detail: message)
    }

    private func setDirection(_ direction: LongScreenshotDirection) {
        guard let model, model.state != .recording else { return }
        model.direction = direction
        accumulator = LongScreenshotAccumulator(direction: direction)
        model.previewImage = nil
        model.frameCount = 0
        model.outputWidth = 0
        model.outputHeight = 0
        model.leadingCrop = 0
        model.trailingCrop = 0
        model.state = .stopped
    }

    private func moveRegion(_ delta: CGFloat) {
        guard let model else { return }
        switch model.direction {
        case .vertical:
            captureRect.origin.y += delta
        case .horizontal:
            captureRect.origin.x += delta
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(captureRect) }) {
            captureRect = CaptureSelectionGeometry.clamped(
                captureRect,
                to: screen.frame,
                preservingSize: true
            )
        }
        regionPanel?.setFrame(captureRect, display: true)
        PasteBuddyDiagnostics.record(
            .capture,
            "longRegionMoved",
            detail: NSStringFromRect(captureRect)
        )
    }

    private func finish(_ action: ScreenshotCaptureCompletion) {
        guard let model, model.canExport else { return }
        do {
            let image = try accumulator.renderedImage(
                leadingCrop: model.leadingCrop,
                trailingCrop: model.trailingCrop
            )
            let item = try CapturedImageHistoryWriter(store: store).storeImage(
                image,
                titleKey: "label.long_screenshot"
            )
            switch action {
            case .copy:
                ClipboardPanelCopyCoordinator.copy(item, sourceWindow: controlPanel)
            case .save:
                try save(item)
            case .pin:
                ScreenPinController.shared.pin(item)
            case .long:
                break
            }
            PasteBuddyDiagnostics.record(
                .capture,
                "longCompleted",
                detail: "action=\(String(describing: action)) size=\(image.width)x\(image.height)"
            )
            close()
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func save(_ item: ClipboardItem) throws {
        guard let data = item.payload.imageData else {
            throw ScreenCaptureServiceError.imageEncodingFailed
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(item.title).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try data.write(to: url, options: .atomic)
    }

    private func cancel() {
        PasteBuddyDiagnostics.record(.capture, "longCancelled")
        close()
    }

    private func close() {
        captureTask?.cancel()
        captureTask = nil
        controlPanel?.orderOut(nil)
        regionPanel?.orderOut(nil)
        controlPanel = nil
        regionPanel = nil
        model = nil
        onFinish?()
    }

    private func presentRegionOutline() {
        let panel = NSPanel(
            contentRect: captureRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView:
            Rectangle()
                .stroke(.green, style: StrokeStyle(lineWidth: 3, dash: [7, 4]))
                .background(.clear)
                .accessibilityHidden(true)
        )
        regionPanel = panel
        panel.orderFrontRegardless()
    }

    private func controlPanelFrame() -> CGRect {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(captureRect) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let size = CGSize(width: 330, height: 520)
        let visible = screen.visibleFrame
        let preferredX = captureRect.maxX + 14
        let x = preferredX + size.width <= visible.maxX
            ? preferredX
            : max(visible.minX, captureRect.minX - size.width - 14)
        let y = min(max(captureRect.midY - size.height / 2, visible.minY), visible.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

private final class LongScreenshotControlPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

private struct LongScreenshotControlView: View {
    @Bindable var model: LongScreenshotSessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("label.long_screenshot", systemImage: "rectangle.expand.vertical")
                    .font(.headline)
                Spacer()
                Button {
                    model.onCancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("action.cancel"))
            }

            Picker("label.capture_direction", selection: directionBinding) {
                Text("label.vertical").tag(LongScreenshotDirection.vertical)
                Text("label.horizontal").tag(LongScreenshotDirection.horizontal)
            }
            .pickerStyle(.segmented)
            .disabled(model.state == .recording)

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.black.opacity(0.18))
                if let preview = model.previewImage {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(6)
                } else {
                    ContentUnavailableView(
                        "label.long_capture_preview",
                        systemImage: "rectangle.dashed"
                    )
                }
            }
            .frame(height: 220)
            .accessibilityLabel(Text("label.long_capture_preview"))

            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(statusColor)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(
                String(
                    format: NSLocalizedString("format.long_capture_progress", comment: ""),
                    model.frameCount,
                    model.outputWidth,
                    model.outputHeight
                )
            )
            .font(.caption.monospacedDigit())

            if model.canExport {
                HStack {
                    Stepper(
                        "label.crop_leading",
                        value: $model.leadingCrop,
                        in: 0...max(0, model.maximumCrop - model.trailingCrop)
                    )
                    Stepper(
                        "label.crop_trailing",
                        value: $model.trailingCrop,
                        in: 0...max(0, model.maximumCrop - model.leadingCrop)
                    )
                }
                .font(.caption)
            }

            HStack {
                Button {
                    model.onMoveRegion(-10)
                } label: {
                    Image(systemName: model.direction == .vertical ? "arrow.up" : "arrow.left")
                }
                .accessibilityLabel(Text("action.move_capture_region_backward"))
                Button {
                    model.onMoveRegion(10)
                } label: {
                    Image(systemName: model.direction == .vertical ? "arrow.down" : "arrow.right")
                }
                .accessibilityLabel(Text("action.move_capture_region_forward"))
                Spacer()
                if model.state == .recording {
                    Button("action.stop") {
                        model.onStop()
                    }
                } else {
                    Button("action.start") {
                        model.onStart()
                    }
                }
            }

            HStack {
                Button("action.pin_to_screen") {
                    model.onPin()
                }
                Button("action.save") {
                    model.onSave()
                }
                Button("action.copy") {
                    model.onCopy()
                }
            }
            .disabled(!model.canExport)
        }
        .padding(14)
        .frame(width: 330)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.18))
        }
    }

    private var directionBinding: Binding<LongScreenshotDirection> {
        Binding(
            get: { model.direction },
            set: { model.onDirectionChanged($0) }
        )
    }

    private var statusColor: Color {
        if case .failed = model.state {
            return .red
        }
        if model.state == .recording {
            return .green
        }
        return .secondary
    }
}
