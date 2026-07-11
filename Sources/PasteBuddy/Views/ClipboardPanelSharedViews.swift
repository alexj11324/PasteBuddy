import AppKit
import PasteBuddyCore
import SwiftUI
import VisionKit

enum ClipboardShelfGlass {
    static let defaultTintOpacity = 0.30
    static let detailSuppressionOpacity = 0.28
}

struct ClipboardTextPreview {
    static let initialCharacterLimit = 8_000

    let initialText: String
    let isTruncated: Bool

    private let fullText: String

    init(_ text: String, characterLimit: Int = Self.initialCharacterLimit) {
        let characterLimit = max(characterLimit, 0)
        let endIndex = text.index(
            text.startIndex,
            offsetBy: characterLimit,
            limitedBy: text.endIndex
        ) ?? text.endIndex

        fullText = text
        isTruncated = endIndex != text.endIndex
        initialText = isTruncated ? String(text[..<endIndex]) + "…" : text
    }

    func text(showingFullText: Bool) -> String {
        showingFullText ? fullText : initialText
    }
}

struct ShelfExpandedPreview: View {
    private static let textPreviewHeight: CGFloat = 420

    @State private var showsFullText = false
    @FocusState private var isPreviewFocused: Bool

    let item: ClipboardItem
    let imageDataProvider: @MainActor (ClipboardItem) async -> Data?
    let tint: Color
    var maxWidth: CGFloat = 640
    let onDismiss: () -> Void
    let onMove: (MoveCommandDirection) -> Void
    let onTextInput: (String) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            previewContent
        }
        .padding(14)
        .frame(width: previewFrameWidth, height: previewFrameHeight, alignment: .topLeading)
        .pasteBuddyGlassSurface(cornerRadius: 18, glassTintOpacity: 0, showsStroke: false)
        .focusable(true)
        .focused($isPreviewFocused)
        .onAppear {
            requestPreviewFocus()
        }
        .onChange(of: item.id) {
            showsFullText = false
        }
        .onMoveCommand(perform: handlePreviewMoveCommand)
        .onExitCommand(perform: onDismiss)
        .onKeyPress(phases: .down, action: handlePreviewKeyPress)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipboard-expanded-preview-\(item.id.uuidString)")
        .accessibilityLabel(localized("label.preview"))
    }

    @ViewBuilder
    private var previewContent: some View {
        switch item.presentationContentType {
        case .image:
            if item.payload.hasImageAsset {
                ShelfExpandedImagePreview(
                    item: item,
                    imageDataProvider: imageDataProvider,
                    tint: tint,
                    displaySize: imagePreviewDisplaySize
                )
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                previewText(ClipboardPlainTextRenderer.plainText(for: item))
                    .frame(height: Self.textPreviewHeight)
            }
        case .text:
            if item.contentType == .text {
                previewText(ClipboardPlainTextRenderer.plainText(for: item))
                    .frame(height: Self.textPreviewHeight)
            } else {
                previewText(ClipboardPlainTextRenderer.plainText(for: item))
                    .frame(height: Self.textPreviewHeight)
            }
        case .url, .file, .mixed:
            previewText(ClipboardPlainTextRenderer.plainText(for: item))
                .frame(height: Self.textPreviewHeight)
        }
    }

    private var previewFrameWidth: CGFloat {
        let widthLimit = previewWidthLimit
        guard let imagePreviewDisplaySize else { return widthLimit }
        return max(320, min(widthLimit, imagePreviewDisplaySize.width + 28))
    }

    private var previewFrameHeight: CGFloat {
        if let imagePreviewDisplaySize {
            return imagePreviewDisplaySize.height + 28
        }
        return Self.textPreviewHeight + 28
    }

    private var previewWidthLimit: CGFloat {
        max(320, min(maxWidth, 640))
    }

    private var imagePreviewBounds: CGSize {
        CGSize(width: max(1, previewWidthLimit - 28), height: 420)
    }

    private var imagePreviewDisplaySize: CGSize? {
        guard item.presentationContentType == .image,
              item.payload.hasImageAsset,
              let imageSize = ClipboardImageCache.imageSize(for: item) else {
            return nil
        }
        return ClipboardImageCache.fittedDisplaySize(
            for: imageSize,
            within: imagePreviewBounds
        )
    }

    private func previewText(_ text: String) -> some View {
        let preview = ClipboardTextPreview(text.isEmpty ? item.visualPreview.body : text)

        return VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(preview.text(showingFullText: showsFullText))
                    .font(.system(size: 16, design: .monospaced))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)

            if preview.isTruncated && !showsFullText {
                Button {
                    showsFullText = true
                    requestPreviewFocus()
                } label: {
                    Label("label.more", systemImage: "ellipsis")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .onMoveCommand(perform: handlePreviewMoveCommand)
        .onKeyPress(phases: .down, action: handlePreviewKeyPress)
    }

    private func requestPreviewFocus() {
        Task { @MainActor in
            await Task.yield()
            isPreviewFocused = true
        }
    }

    private func handlePreviewMoveCommand(_ direction: MoveCommandDirection) {
        onMove(direction)
        requestPreviewFocus()
    }

    private func handlePreviewKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        switch keyPress.key {
        case .space:
            guard keyPress.modifiers.isEmpty else { return .ignored }
            onDismiss()
        case .upArrow:
            guard keyPress.modifiers.isEmpty else { return .ignored }
            onMove(.up)
        case .downArrow:
            guard keyPress.modifiers.isEmpty else { return .ignored }
            onMove(.down)
        case .leftArrow:
            guard keyPress.modifiers.isEmpty else { return .ignored }
            onMove(.left)
        case .rightArrow:
            guard keyPress.modifiers.isEmpty else { return .ignored }
            onMove(.right)
        default:
            guard ClipboardPanelSearchInput.accepts(keyPress.modifiers), onTextInput(keyPress.characters) else {
                return .ignored
            }
        }
        return .handled
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}

private struct ShelfExpandedImagePreview: View {
    let item: ClipboardItem
    let imageDataProvider: @MainActor (ClipboardItem) async -> Data?
    let tint: Color
    let displaySize: CGSize?
    @State private var liveTextImage: NSImage?
    @State private var fallbackImage: NSImage?

    var body: some View {
        ZStack {
            if let liveTextImage {
                ShelfLiveTextImagePreview(
                    image: liveTextImage,
                    analysisID: analysisID
                )
            } else if let image = fallbackImage ?? ClipboardImageCache.cachedThumbnail(for: item, maxPixelSize: maxPixelSize) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint.opacity(0.10))
                Image(systemName: "photo")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: resolvedDisplaySize.width, height: resolvedDisplaySize.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(localized("label.captured_image_preview"))
        .task(id: ClipboardImageCache.thumbnailCacheKey(for: item, maxPixelSize: maxPixelSize)) {
            let cachedImage = ClipboardImageCache.cachedThumbnail(for: item, maxPixelSize: maxPixelSize)
            liveTextImage = nil
            fallbackImage = cachedImage

            let imageData = await imageDataProvider(item)
            if let imageData, let analysisImage = NSImage(data: imageData) {
                guard !Task.isCancelled else { return }
                liveTextImage = analysisImage
                return
            }

            if let cachedImage {
                liveTextImage = cachedImage
                return
            }

            let loadedImage = await ClipboardImageCache.thumbnail(
                for: item,
                imageData: imageData,
                maxPixelSize: maxPixelSize
            )
            guard !Task.isCancelled else { return }
            liveTextImage = loadedImage
            fallbackImage = loadedImage
        }
    }

    private var maxPixelSize: Int {
        1_600
    }

    private var resolvedDisplaySize: CGSize {
        displaySize ?? CGSize(width: 612, height: 420)
    }

    private var analysisID: String {
        ClipboardImageCache.thumbnailCacheKey(
            for: item,
            maxPixelSize: maxPixelSize
        ) ?? item.id.uuidString
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}

private struct ShelfLiveTextImagePreview: NSViewRepresentable {
    let image: NSImage
    let analysisID: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ShelfLiveTextImagePreviewContainer {
        let view = ShelfLiveTextImagePreviewContainer()
        view.overlayView.delegate = context.coordinator
        context.coordinator.imageView = view.imageView
        context.coordinator.overlayView = view.overlayView
        return view
    }

    func updateNSView(_ nsView: ShelfLiveTextImagePreviewContainer, context: Context) {
        nsView.imageView.image = image
        context.coordinator.imageView = nsView.imageView
        context.coordinator.overlayView = nsView.overlayView
        context.coordinator.analyze(image: image, analysisID: analysisID)
    }

    static func dismantleNSView(_ nsView: ShelfLiveTextImagePreviewContainer, coordinator: Coordinator) {
        coordinator.cancelAnalysis()
        nsView.overlayView.analysis = nil
    }

    final class Coordinator: NSObject, ImageAnalysisOverlayViewDelegate {
        weak var imageView: NSImageView?
        weak var overlayView: ImageAnalysisOverlayView?
        private var analysisTask: Task<Void, Never>?
        private var activeAnalysisID: String?

        func analyze(image: NSImage, analysisID: String) {
            guard ImageAnalyzer.isSupported else { return }
            guard activeAnalysisID != analysisID else { return }
            activeAnalysisID = analysisID
            analysisTask?.cancel()
            overlayView?.analysis = nil

            analysisTask = Task { @MainActor [weak self, image] in
                let configuration = ImageAnalyzer.Configuration(.text)
                do {
                    let analysis = try await ImageAnalyzer().analyze(
                        image,
                        orientation: .up,
                        configuration: configuration
                    )
                    guard !Task.isCancelled else { return }
                    self?.overlayView?.analysis = analysis
                } catch {
                    self?.overlayView?.analysis = nil
                }
            }
        }

        func cancelAnalysis() {
            analysisTask?.cancel()
            analysisTask = nil
            activeAnalysisID = nil
        }

        func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
            guard let imageView else { return .zero }
            return Self.imageContentRect(in: imageView)
        }

        func contentView(for overlayView: ImageAnalysisOverlayView) -> NSView? {
            imageView
        }

        private static func imageContentRect(in imageView: NSImageView) -> CGRect {
            let bounds = imageView.bounds
            guard let image = imageView.image,
                  image.size.width > 0,
                  image.size.height > 0,
                  bounds.width > 0,
                  bounds.height > 0 else {
                return bounds
            }

            let imageAspect = image.size.width / image.size.height
            let boundsAspect = bounds.width / bounds.height
            if imageAspect > boundsAspect {
                let width = bounds.width
                let height = width / imageAspect
                return CGRect(x: 0, y: (bounds.height - height) / 2, width: width, height: height)
            }

            let height = bounds.height
            let width = height * imageAspect
            return CGRect(x: (bounds.width - width) / 2, y: 0, width: width, height: height)
        }
    }
}

private final class ShelfLiveTextImagePreviewContainer: NSView {
    let imageView = NSImageView()
    let overlayView = ImageAnalysisOverlayView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        addSubview(imageView)

        overlayView.translatesAutoresizingMaskIntoConstraints = false
        overlayView.trackingImageView = imageView
        overlayView.preferredInteractionTypes = .automaticTextOnly
        overlayView.selectableItemsHighlighted = true
        imageView.addSubview(overlayView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlayView.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
            overlayView.topAnchor.constraint(equalTo: imageView.topAnchor),
            overlayView.bottomAnchor.constraint(equalTo: imageView.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}


struct ClipboardImageThumbnailView: View {
    let item: ClipboardItem
    let imageDataProvider: @MainActor (ClipboardItem) async -> Data?
    let tint: Color
    let contentMode: ContentMode
    let placeholderIconSize: CGFloat
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            if let image = thumbnail ?? ClipboardImageCache.cachedThumbnail(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle()
                    .fill(placeholderFill)
                Image(systemName: item.presentationContentType.systemImageName)
                    .font(.system(size: placeholderIconSize, weight: .semibold))
                    .foregroundStyle(placeholderIconTint)
            }
        }
        .task(id: ClipboardImageCache.thumbnailCacheKey(for: item)) {
            if let cachedThumbnail = ClipboardImageCache.cachedThumbnail(for: item) {
                thumbnail = cachedThumbnail
                return
            }

            let imageData = await imageDataProvider(item)
            let loadedThumbnail = await ClipboardImageCache.thumbnail(for: item, imageData: imageData)
            guard !Task.isCancelled else { return }
            if let loadedThumbnail {
                thumbnail = loadedThumbnail
            }
        }
    }

    private var placeholderFill: Color {
        item.presentationContentType == .image
            ? Color(nsColor: .controlBackgroundColor).opacity(0.42)
            : tint.opacity(0.10)
    }

    private var placeholderIconTint: Color {
        item.presentationContentType == .image
            ? Color(nsColor: .secondaryLabelColor)
            : tint
    }
}


struct ShelfToolbarCircleIcon: View {
    let systemName: String
    @State private var isHovered = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 42, height: 38)
            .background {
                Circle()
                    .fill(.quaternary.opacity(isHovered ? 0.95 : 0))
                    .frame(width: 34, height: 34)
            }
            .overlay {
                Circle()
                    .strokeBorder(.primary.opacity(isHovered ? 0.08 : 0), lineWidth: 1)
                    .frame(width: 34, height: 34)
            }
            .contentShape(Circle())
            .onHover { isHovered = $0 }
            .accessibilityHidden(true)
    }
}

struct SourceAppSuggestionPanelPresenter: NSViewRepresentable {
    let isPresented: Bool
    let appNames: [String]
    let query: String
    let width: CGFloat
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.update(
                anchorView: nsView,
                isPresented: isPresented,
                appNames: appNames,
                query: query,
                width: width,
                onSelect: onSelect
            )
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.closeImmediately()
    }

    @MainActor
    final class Coordinator {
        private var panel: SourceAppSuggestionPanel?
        private var contentView: NativeSourceAppSuggestionView?
        private weak var parentWindow: NSWindow?
        private var parentWindowObservers: [NSObjectProtocol] = []
        private var isClosingPanel = false
        private var panelAnimationGeneration = 0

        func update(
            anchorView: NSView,
            isPresented: Bool,
            appNames: [String],
            query: String,
            width: CGFloat,
            onSelect: @escaping (String) -> Void
        ) {
            guard isPresented, !appNames.isEmpty, let window = anchorView.window, window.isVisible else {
                close(animated: true)
                return
            }

            let contentSize = NSSize(width: width, height: SourceAppSuggestionMetrics.panelHeight(for: appNames.count))
            let panel = suggestionPanel(parentWindow: window)
            let wasVisible = panel.isVisible
            isClosingPanel = false
            panelAnimationGeneration += 1
            if let contentView {
                contentView.configure(appNames: appNames, query: query, onSelect: onSelect)
            } else {
                let contentView = NativeSourceAppSuggestionView(frame: NSRect(origin: .zero, size: contentSize))
                contentView.configure(appNames: appNames, query: query, onSelect: onSelect)
                self.contentView = contentView
                panel.contentView = contentView
            }

            contentView?.frame = NSRect(origin: .zero, size: contentSize)
            panel.setContentSize(contentSize)
            let height = contentSize.height
            let anchorFrame = window.convertToScreen(anchorView.convert(anchorView.bounds, to: nil))
            let targetFrame = NSRect(
                x: anchorFrame.minX,
                y: anchorFrame.minY - height - SourceAppSuggestionMetrics.searchGap,
                width: contentSize.width,
                height: height
            )

            if panel.isVisible {
                panel.alphaValue = 1
                panel.setFrame(targetFrame, display: true)
            } else {
                panel.alphaValue = 1
                panel.setFrame(targetFrame, display: false)
                contentView?.prepareForPresentation(reduceMotion: shouldReduceMotion)
                panel.orderFrontRegardless()
                contentView?.animateIn(reduceMotion: shouldReduceMotion)
            }
            if wasVisible {
                contentView?.resetPresentation()
            }
        }

        private func suggestionPanel(parentWindow window: NSWindow) -> SourceAppSuggestionPanel {
            if let panel {
                attach(panel, to: window)
                return panel
            }

            let panel = SourceAppSuggestionPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.identifier = NSUserInterfaceItemIdentifier(ClipboardShelfWindowIdentifiers.sourceAppSuggestionPanel)
            panel.level = window.level
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isExcludedFromWindowsMenu = true
            panel.isMovable = false
            panel.ignoresMouseEvents = false
            panel.animationBehavior = .none
            self.panel = panel
            attach(panel, to: window)
            return panel
        }

        private func attach(_ panel: NSWindow, to window: NSWindow) {
            if parentWindow === window {
                panel.level = window.level
                return
            }
            if let parentWindow {
                parentWindow.removeChildWindow(panel)
            }
            stopParentWindowMonitoring()
            parentWindow = window
            window.addChildWindow(panel, ordered: .above)
            panel.level = window.level
            startParentWindowMonitoring(for: window)
        }

        private func close(animated: Bool) {
            guard let panel, panel.isVisible else { return }
            guard animated, !shouldReduceMotion, !isClosingPanel, let contentView else {
                isClosingPanel = false
                contentView?.resetPresentation()
                panel.orderOut(nil)
                return
            }
            isClosingPanel = true
            panelAnimationGeneration += 1
            let animationGeneration = panelAnimationGeneration
            contentView.animateOut(reduceMotion: shouldReduceMotion) { [weak self, weak panel] in
                Task { @MainActor [weak self, weak panel] in
                    guard let self, let panel, self.panel === panel, self.panelAnimationGeneration == animationGeneration else { return }
                    self.isClosingPanel = false
                    self.contentView?.resetPresentation()
                    panel.orderOut(nil)
                }
            }
        }

        func closeImmediately() {
            stopParentWindowMonitoring()
            isClosingPanel = false
            panelAnimationGeneration += 1
            if let panel {
                parentWindow?.removeChildWindow(panel)
                contentView?.resetPresentation()
                panel.orderOut(nil)
            }
            panel = nil
            contentView = nil
            parentWindow = nil
        }

        private func startParentWindowMonitoring(for window: NSWindow) {
            parentWindowObservers = [
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didResignKeyNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.close(animated: false)
                    }
                },
                NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.closeImmediately()
                    }
                },
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification,
                    object: window,
                    queue: .main
                ) { [weak self, weak window] _ in
                    Task { @MainActor [weak self, weak window] in
                        guard window?.isVisible != true else { return }
                        self?.close(animated: false)
                    }
                },
                NotificationCenter.default.addObserver(
                    forName: NSApplication.didResignActiveNotification,
                    object: NSApp,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.close(animated: false)
                    }
                }
            ]
        }

        private var shouldReduceMotion: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }

        private func stopParentWindowMonitoring() {
            parentWindowObservers.forEach(NotificationCenter.default.removeObserver)
            parentWindowObservers = []
        }
    }
}

private final class SourceAppSuggestionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private enum SourceAppSuggestionMetrics {
    static let rowHeight: CGFloat = 32
    static let iconSize: CGFloat = 18
    static let titleFontSize: CGFloat = 14
    static let horizontalPadding: CGFloat = 10
    static let titleSpacing: CGFloat = 8
    static let verticalPadding: CGFloat = 5
    static let searchGap: CGFloat = 2
    static let entranceDuration: CFTimeInterval = 0.12
    static let exitDuration: CFTimeInterval = 0.08

    static func panelHeight(for rowCount: Int) -> CGFloat {
        CGFloat(max(rowCount, 0)) * rowHeight + verticalPadding * 2
    }
}

private final class NativeSourceAppSuggestionView: NSVisualEffectView {
    private let stackView = NSStackView()
    private var onSelect: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func prepareForPresentation(reduceMotion: Bool) {
        guard !reduceMotion, let layer else {
            resetPresentation()
            return
        }
        layer.removeAllAnimations()
        layer.opacity = 0
        layer.transform = CATransform3DMakeTranslation(0, 5, 0)
    }

    func animateIn(reduceMotion: Bool) {
        guard !reduceMotion, let layer else {
            resetPresentation()
            return
        }
        layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setAnimationDuration(SourceAppSuggestionMetrics.entranceDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.18, 0.86, 0.24, 1))
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    func animateOut(reduceMotion: Bool, completion: @escaping () -> Void) {
        guard !reduceMotion, let layer else {
            completion()
            return
        }
        layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setAnimationDuration(SourceAppSuggestionMetrics.exitDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.32, 0, 0.67, 0))
        CATransaction.setCompletionBlock(completion)
        layer.opacity = 0
        layer.transform = CATransform3DMakeTranslation(0, 3, 0)
        CATransaction.commit()
    }

    func resetPresentation() {
        guard let layer else { return }
        layer.removeAllAnimations()
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
    }

    func configure(appNames: [String], query: String, onSelect: @escaping (String) -> Void) {
        self.onSelect = onSelect
        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for appName in appNames {
            let row = NativeSourceAppSuggestionRow(appName: appName, query: query)
            row.target = self
            row.action = #selector(selectSuggestion(_:))
            row.heightAnchor.constraint(equalToConstant: SourceAppSuggestionMetrics.rowHeight).isActive = true
            stackView.addArrangedSubview(row)
        }
    }

    private func configureView() {
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        layer?.borderWidth = 1

        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.distribution = .fill
        stackView.spacing = 0
        stackView.edgeInsets = NSEdgeInsets(
            top: SourceAppSuggestionMetrics.verticalPadding,
            left: 0,
            bottom: SourceAppSuggestionMetrics.verticalPadding,
            right: 0
        )
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        setAccessibilityLabel(NSLocalizedString("label.app_suggestions", comment: ""))
    }

    @objc private func selectSuggestion(_ sender: NativeSourceAppSuggestionRow) {
        onSelect?(sender.appName)
    }
}

private final class NativeSourceAppSuggestionRow: NSControl {
    let appName: String
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var isHoverHighlighted = false {
        didSet {
            needsDisplay = true
        }
    }

    init(appName: String, query: String) {
        self.appName = appName
        super.init(frame: .zero)
        configureView(query: query)
    }

    required init?(coder: NSCoder) {
        self.appName = ""
        super.init(coder: coder)
        configureView(query: "")
    }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        isHoverHighlighted = true
    }

    override func mouseExited(with event: NSEvent) {
        isHoverHighlighted = false
    }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHoverHighlighted else { return }
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 7, dy: 3), xRadius: 8, yRadius: 8).fill()
    }

    private func configureView(query: String) {
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        iconView.image = SourceApplicationIconResolver.icon(forApplicationName: appName)
            ?? SourceApplicationIconResolver.genericApplicationIcon()
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.attributedStringValue = title(for: appName, query: query)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(iconView)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SourceAppSuggestionMetrics.horizontalPadding),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: SourceAppSuggestionMetrics.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: SourceAppSuggestionMetrics.iconSize),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: SourceAppSuggestionMetrics.titleSpacing),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -SourceAppSuggestionMetrics.horizontalPadding),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        setAccessibilityLabel(appName)
    }

    private func title(for appName: String, query: String) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: SourceAppSuggestionMetrics.titleFontSize)
        let result = NSMutableAttributedString(
            string: appName,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor
            ]
        )
        let normalizedQuery = normalizedSuggestionQuery(query)
        guard !normalizedQuery.isEmpty,
              let range = appName.range(
                of: normalizedQuery,
                options: [.caseInsensitive, .diacriticInsensitive, .anchored]
              ) else {
            return result
        }
        let suffixRange = NSRange(range.upperBound..., in: appName)
        result.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: suffixRange)
        return result
    }

    private func normalizedSuggestionQuery(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
    }
}

struct SourceApplicationIconImage: View {
    let appName: String
    let size: CGFloat

    var body: some View {
        let image = SourceApplicationIconResolver.icon(forApplicationName: appName)
            ?? SourceApplicationIconResolver.genericApplicationIcon()
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct SourceApplicationIconBadge: View {
    let item: ClipboardItem
    let size: CGFloat

    init(item: ClipboardItem, size: CGFloat = 36) {
        self.item = item
        self.size = size
    }

    var body: some View {
        ZStack {
            if let image = SourceApplicationIconResolver.icon(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else if SourceApplicationIconResolver.hasKnownSource(for: item) {
                Image(nsImage: SourceApplicationIconResolver.genericApplicationIcon())
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: item.presentationContentType.systemImageName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(item.presentationContentType.shelfTint)
            }
        }
        .frame(width: size, height: size)
        .help(item.sourceAppName)
        .accessibilityLabel(item.sourceAppName)
    }
}

@MainActor
enum SourceApplicationIconResolver {
    enum LookupResult {
        case icon(NSImage)
        case missing
        case temporaryFailure
    }

    final class LookupCache {
        private let icons = NSCache<NSString, NSImage>()
        private let negativeCapacity: Int
        private var negativeKeys: Set<String> = []
        private var negativeOrder: [String] = []

        var negativeEntryCount: Int {
            negativeKeys.count
        }

        init(negativeCapacity: Int) {
            self.negativeCapacity = max(negativeCapacity, 0)
        }

        fileprivate func icon(for key: String) -> NSImage? {
            icons.object(forKey: key as NSString)
        }

        fileprivate func isKnownMissing(_ key: String) -> Bool {
            negativeKeys.contains(key)
        }

        fileprivate func store(_ image: NSImage, for key: String) {
            icons.setObject(image, forKey: key as NSString)
            negativeKeys.remove(key)
            negativeOrder.removeAll { $0 == key }
        }

        fileprivate func recordMissing(_ key: String) {
            guard negativeCapacity > 0, negativeKeys.insert(key).inserted else { return }
            negativeOrder.append(key)
            if negativeOrder.count > negativeCapacity {
                negativeKeys.remove(negativeOrder.removeFirst())
            }
        }
    }

    private static let cache = LookupCache(negativeCapacity: 256)

    static func icon(for item: ClipboardItem) -> NSImage? {
        icon(
            for: item,
            cache: cache,
            bundleLookup: lookupIcon(forBundleIdentifier:),
            nameLookup: lookupIcon(forApplicationName:)
        )
    }

    static func icon(
        for item: ClipboardItem,
        cache: LookupCache,
        bundleLookup: (String) -> LookupResult,
        nameLookup: (String) -> LookupResult
    ) -> NSImage? {
        if let bundleIdentifier = normalized(item.sourceBundleIdentifier) {
            if let image = resolvedIcon(
                cacheKey: "bundle:\(bundleIdentifier)",
                lookupValue: bundleIdentifier,
                cache: cache,
                lookup: bundleLookup
            ) {
                return image
            }
        }

        guard let appName = normalized(item.sourceAppName) else { return nil }
        return resolvedIcon(
            cacheKey: "name:\(appName.lowercased())",
            lookupValue: appName,
            cache: cache,
            lookup: nameLookup
        )
    }

    static func hasKnownSource(for item: ClipboardItem) -> Bool {
        normalized(item.sourceBundleIdentifier) != nil || normalized(item.sourceAppName) != nil
    }

    static func genericApplicationIcon() -> NSImage {
        ClipboardImageCache.genericAppIcon()
    }

    static func themeColor(for item: ClipboardItem, fallback: Color) -> Color {
        let key = colorCacheKey(for: item)
        let sourceIcon = icon(for: item)
        return AppIconThemeColorResolver.themeColor(for: sourceIcon, cacheKey: key, fallback: fallback)
    }

    private static func lookupIcon(forBundleIdentifier bundleIdentifier: String) -> LookupResult {
        if let image = runningApplicationIcon(bundleIdentifier: bundleIdentifier) {
            return .icon(image)
        }

        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return .missing
        }
        return .icon(icon(forApplicationURL: applicationURL))
    }

    static func icon(forApplicationName appName: String) -> NSImage? {
        guard let appName = normalized(appName) else { return nil }
        return resolvedIcon(
            cacheKey: "name:\(appName.lowercased())",
            lookupValue: appName,
            cache: cache,
            lookup: lookupIcon(forApplicationName:)
        )
    }

    private static func lookupIcon(forApplicationName appName: String) -> LookupResult {
        if let image = runningApplicationIcon(appName: appName) {
            return .icon(image)
        }

        let fileManager = FileManager.default
        let appFileName = appName.hasSuffix(".app") ? appName : "\(appName).app"
        let searchDirectories = applicationSearchDirectories()

        for directory in searchDirectories {
            let candidate = directory.appendingPathComponent(appFileName, isDirectory: true)
            if fileManager.fileExists(atPath: candidate.path) {
                return .icon(icon(forApplicationURL: candidate))
            }
        }

        return .missing
    }

    private static func resolvedIcon(
        cacheKey: String,
        lookupValue: String,
        cache: LookupCache,
        lookup: (String) -> LookupResult
    ) -> NSImage? {
        if let image = cache.icon(for: cacheKey) {
            return image
        }
        guard !cache.isKnownMissing(cacheKey) else { return nil }

        switch lookup(lookupValue) {
        case .icon(let image):
            cache.store(image, for: cacheKey)
            return image
        case .missing:
            cache.recordMissing(cacheKey)
            return nil
        case .temporaryFailure:
            return nil
        }
    }

    private static func applicationSearchDirectories() -> [URL] {
        let fileManager = FileManager.default
        let domains: [FileManager.SearchPathDomainMask] = [.userDomainMask, .localDomainMask, .systemDomainMask]
        var directories = domains.flatMap { fileManager.urls(for: .applicationDirectory, in: $0) }
        directories += directories.map { $0.appendingPathComponent("Utilities", isDirectory: true) }

        var seen = Set<String>()
        return directories.filter { directory in
            let path = directory.standardizedFileURL.path
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }

    private static func icon(forApplicationURL url: URL) -> NSImage {
        icon(from: NSWorkspace.shared.icon(forFile: url.path))
    }

    private static func colorCacheKey(for item: ClipboardItem) -> String {
        if let bundleIdentifier = normalized(item.sourceBundleIdentifier) {
            return "bundle:\(bundleIdentifier)"
        }
        if let appName = normalized(item.sourceAppName) {
            return "name:\(appName.lowercased())"
        }
        return "contentType:\(item.contentType.rawValue)"
    }

    private static func runningApplicationIcon(bundleIdentifier: String? = nil, appName: String? = nil) -> NSImage? {
        NSWorkspace.shared.runningApplications
            .first { application in
                if let bundleIdentifier, application.bundleIdentifier == bundleIdentifier {
                    return true
                }
                if let appName,
                   let localizedName = normalized(application.localizedName),
                   localizedName.caseInsensitiveCompare(appName) == .orderedSame {
                    return true
                }
                return false
            }?
            .icon
            .map(icon(from:))
    }

    private static func icon(from image: NSImage) -> NSImage {
        let image = image.copy() as? NSImage ?? image
        image.size = NSSize(width: 64, height: 64)
        return image
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed != "Unknown" else {
            return nil
        }
        return trimmed
    }
}


extension View {
    @ViewBuilder
    func pasteBuddyBottomSheetSurface(
        cornerRadius: CGFloat,
        glassTintOpacity: Double = ClipboardShelfGlass.defaultTintOpacity,
        showsStroke: Bool = true
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let tintOpacity = min(max(glassTintOpacity, 0), 1)
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            ZStack {
                // Add a stronger system blur before glass sampling so background text collapses into color.
                shape
                    .fill(.thickMaterial)
                    .allowsHitTesting(false)
                shape
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(ClipboardShelfGlass.detailSuppressionOpacity))
                    .allowsHitTesting(false)
                self
            }
                .glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(tintOpacity)), in: shape)
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(.white.opacity(showsStroke ? 0.20 : 0.14), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .top) {
                    if showsStroke {
                        Rectangle()
                            .fill(.white.opacity(0.42))
                            .frame(height: 1)
                    } else {
                        Rectangle()
                            .fill(.white.opacity(0.10))
                            .frame(height: 1)
                    }
                }
        } else {
            self
                .background(.thinMaterial, in: shape)
                .background {
                    shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.86))
                }
                .clipShape(shape)
                .overlay(alignment: .top) {
                    if showsStroke {
                        Rectangle()
                            .fill(.white.opacity(0.42))
                            .frame(height: 1)
                    }
                }
        }
        #else
        self
            .background(.thinMaterial, in: shape)
            .background {
                shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.86))
            }
            .clipShape(shape)
            .overlay(alignment: .top) {
                if showsStroke {
                    Rectangle()
                        .fill(.white.opacity(0.42))
                        .frame(height: 1)
                }
            }
        #endif
    }

    @ViewBuilder
    func pasteBuddyGlassSurface(
        cornerRadius: CGFloat,
        glassTintOpacity: Double = ClipboardShelfGlass.defaultTintOpacity,
        interactive: Bool = false,
        showsStroke: Bool = true
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let tintOpacity = min(max(glassTintOpacity, 0), 1)
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self
                .glassEffect(
                    (
                        interactive
                        ? Glass.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(tintOpacity)).interactive()
                        : Glass.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(tintOpacity))
                    ),
                    in: shape
                )
                .overlay {
                    if showsStroke {
                        shape.strokeBorder(.white.opacity(0.40), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                }
        } else {
            self
                .background(.thinMaterial, in: shape)
                .background {
                    shape.fill(Color(nsColor: .windowBackgroundColor).opacity(interactive ? 0.66 : 0.58))
                }
                .overlay {
                    if showsStroke {
                        shape.strokeBorder(.white.opacity(0.40), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                }
        }
        #else
        self
            .background(.thinMaterial, in: shape)
            .background {
                shape.fill(Color(nsColor: .windowBackgroundColor).opacity(interactive ? 0.66 : 0.58))
            }
            .overlay {
                if showsStroke {
                    shape.strokeBorder(.white.opacity(0.40), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
        #endif
    }

    @ViewBuilder
    func pasteBuddyGlassButton() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.borderless)
        }
        #else
        self.buttonStyle(.borderless)
        #endif
    }
}

extension ClipboardContentType {
    var shelfTint: Color {
        switch self {
        case .text:
            Color(red: 0.12, green: 0.48, blue: 1.00)
        case .url:
            Color(red: 0.24, green: 0.78, blue: 0.30)
        case .image:
            Color(red: 1.00, green: 0.34, blue: 0.46)
        case .file:
            Color(red: 1.00, green: 0.68, blue: 0.02)
        case .mixed:
            Color(red: 0.58, green: 0.48, blue: 0.98)
        }
    }
}
