import AppKit
import PasteBuddyCore
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardCollectionStripItem {
    let id: ClipboardCollectionID
    let title: String
    let isSelected: Bool
    let onDropPayloads: (([PinboardItemDragPayload]) -> Bool)?
    let canMoveLeft: Bool
    let canMoveRight: Bool
    let onMoveLeft: () -> Void
    let onMoveRight: () -> Void
    let action: () -> Void

    var reorderID: String { id.id }
}

struct ClipboardCollectionReorderDestination: Equatable {
    let target: ClipboardCollectionID
    let afterTarget: Bool
}

enum ClipboardCollectionNativeReorderingPolicy {
    static let environmentVariable = "PASTEBUDDY_ENABLE_SWIFTUI_CATEGORY_REORDERING"

    static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[environmentVariable] == "1"
    }
}

enum ClipboardCollectionReorderResolver {
    static func destination(
        for source: ClipboardCollectionID,
        in order: [ClipboardCollectionID],
        proposedIndex: Int
    ) -> ClipboardCollectionReorderDestination? {
        guard order.contains(source) else { return nil }
        if proposedIndex >= order.count {
            guard let target = order.last(where: { $0 != source }) else { return nil }
            return ClipboardCollectionReorderDestination(target: target, afterTarget: true)
        }
        let proposedTarget = order[proposedIndex]
        guard proposedTarget != source else { return nil }
        return ClipboardCollectionReorderDestination(
            target: proposedTarget,
            afterTarget: false
        )
    }
}

enum ClipboardCollectionStripStyle {
    case shelf
    case sidePanel

    var height: CGFloat {
        switch self {
        case .shelf: 38
        case .sidePanel: 30
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .shelf: 11
        case .sidePanel: 10
        }
    }

    var controlSize: ControlSize {
        switch self {
        case .shelf: .regular
        case .sidePanel: .small
        }
    }

    var font: NSFont {
        switch self {
        case .shelf:
            .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        case .sidePanel:
            .systemFont(ofSize: 13, weight: .semibold)
        }
    }

    func itemWidth(for title: String) -> CGFloat {
        let textWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        return max(height, textWidth + horizontalPadding * 2)
    }
}

struct ClipboardCollectionStrip: View {
    let items: [ClipboardCollectionStripItem]
    let style: ClipboardCollectionStripStyle
    let accessibilityLabel: String
    let onReorder: (ClipboardCollectionID, ClipboardCollectionID, Bool) -> Bool

    @ViewBuilder
    var body: some View {
        if #available(macOS 27.0, *), ClipboardCollectionNativeReorderingPolicy.isEnabled() {
            SwiftUIClipboardCollectionStrip(
                items: items,
                style: style,
                onReorder: onReorder
            )
            .frame(maxWidth: .infinity, minHeight: style.height, maxHeight: style.height)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityLabel)
        } else {
            AppKitClipboardCollectionStrip(
                items: items,
                style: style,
                onReorder: onReorder
            )
            .frame(maxWidth: .infinity, minHeight: style.height, maxHeight: style.height)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityLabel)
        }
    }
}

@available(macOS 27.0, *)
private struct SwiftUIClipboardCollectionStrip: View {
    let items: [ClipboardCollectionStripItem]
    let style: ClipboardCollectionStripStyle
    let onReorder: (ClipboardCollectionID, ClipboardCollectionID, Bool) -> Bool

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(items, id: \.reorderID) { item in
                    SwiftUIClipboardCollectionButton(item: item, style: style)
                }
                .reorderable()
            }
            .reorderContainer(
                for: ClipboardCollectionStripItem.self,
                itemID: \.reorderID
            ) { difference in
                apply(difference)
            }
        }
        .scrollIndicators(.never, axes: .horizontal)
    }

    private func apply(
        _ difference: ReorderDifference<
            String,
            ReorderableSingleCollectionIdentifier
        >
    ) {
        guard difference.sources.count == 1,
              let sourceReorderID = difference.sources.first,
              let source = items.first(where: { $0.reorderID == sourceReorderID })?.id else { return }
        let proposedIndex: Int
        switch difference.destination.position {
        case .before(let targetReorderID):
            guard let targetIndex = items.firstIndex(where: { $0.reorderID == targetReorderID }) else { return }
            proposedIndex = targetIndex
        case .end:
            proposedIndex = items.endIndex
        }
        guard let destination = ClipboardCollectionReorderResolver.destination(
            for: source,
            in: items.map(\.id),
            proposedIndex: proposedIndex
        ) else { return }
        _ = onReorder(source, destination.target, destination.afterTarget)
    }
}

@available(macOS 27.0, *)
private struct SwiftUIClipboardCollectionButton: View {
    let item: ClipboardCollectionStripItem
    let style: ClipboardCollectionStripStyle
    @State private var isDropTargeted = false

    @ViewBuilder
    var body: some View {
        if item.onDropPayloads != nil {
            styledButton
                .dropDestination(for: PinboardItemDragPayload.self) { payloads, _ in
                    acceptDrop(payloads)
                } isTargeted: { isDropTargeted = $0 }
        } else {
            styledButton
        }
    }

    @ViewBuilder
    private var styledButton: some View {
        if item.isSelected || isDropTargeted {
            button
                .buttonStyle(.glassProminent)
        } else {
            button
                .buttonStyle(.glass)
        }
    }

    @ViewBuilder
    private var button: some View {
        let accessibleBase = Button(item.title, action: item.action)
            .controlSize(style.controlSize)
            .lineLimit(1)
            .accessibilityIdentifier("clipboard-collection-\(item.id.id)")
            .accessibilityValue(
                item.isSelected
                    ? Text("state.selected")
                    : Text("label.not_selected")
            )

        if item.canMoveLeft && item.canMoveRight {
            accessibleBase
                .accessibilityAction(named: Text("action.move_left"), item.onMoveLeft)
                .accessibilityAction(named: Text("action.move_right"), item.onMoveRight)
        } else if item.canMoveLeft {
            accessibleBase.accessibilityAction(named: Text("action.move_left"), item.onMoveLeft)
        } else if item.canMoveRight {
            accessibleBase.accessibilityAction(named: Text("action.move_right"), item.onMoveRight)
        } else {
            accessibleBase
        }
    }

    private func acceptDrop(_ payloads: [PinboardItemDragPayload]) -> Bool {
        guard let onDropPayloads = item.onDropPayloads else { return false }
        return onDropPayloads(payloads)
    }
}

private struct ClipboardCollectionChipLabel: View {
    let title: String
    let isSelected: Bool
    let isDropTargeted: Bool
    let style: ClipboardCollectionStripStyle

    var body: some View {
        Text(title)
            .font(font)
            .foregroundStyle(foregroundStyle)
            .lineLimit(1)
            .padding(.horizontal, style.horizontalPadding)
            .frame(height: style.height)
            .background {
                if isSelected || isDropTargeted {
                    Capsule()
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .background(.regularMaterial, in: Capsule())
                }
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
            .allowsHitTesting(false)
    }

    private var font: Font {
        switch style {
        case .shelf: .callout.weight(.medium)
        case .sidePanel: .system(size: 13, weight: .semibold)
        }
    }

    private var foregroundStyle: Color {
        switch style {
        case .shelf:
            .primary
        case .sidePanel:
            isSelected ? .primary : .primary.opacity(0.72)
        }
    }
}

private struct AppKitClipboardCollectionStrip: NSViewRepresentable {
    let items: [ClipboardCollectionStripItem]
    let style: ClipboardCollectionStripStyle
    let onReorder: (ClipboardCollectionID, ClipboardCollectionID, Bool) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(items: items, style: style, onReorder: onReorder)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets()

        let collectionView = ClipboardCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.isSelectable = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            ClipboardCollectionViewItem.self,
            forItemWithIdentifier: ClipboardCollectionViewItem.reuseIdentifier
        )
        collectionView.registerForDraggedTypes([
            Coordinator.reorderPasteboardType,
            NSPasteboard.PasteboardType(UTType.pasteBuddyPinboardItemIDs.identifier),
        ])
        collectionView.setDraggingSourceOperationMask(.move, forLocal: true)
        collectionView.onDraggingExited = { [weak coordinator = context.coordinator] in
            coordinator?.clearDropTarget()
        }
        context.coordinator.collectionView = collectionView

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = collectionView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(items: items, style: style, onReorder: onReorder)
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
        static let reorderPasteboardType = NSPasteboard.PasteboardType(
            "app.pastebuddy.clipboard-collection-id"
        )

        weak var collectionView: NSCollectionView?
        private var items: [ClipboardCollectionStripItem]
        private var style: ClipboardCollectionStripStyle
        private var onReorder: (ClipboardCollectionID, ClipboardCollectionID, Bool) -> Bool
        private var dropTargetID: ClipboardCollectionID?

        init(
            items: [ClipboardCollectionStripItem],
            style: ClipboardCollectionStripStyle,
            onReorder: @escaping (ClipboardCollectionID, ClipboardCollectionID, Bool) -> Bool
        ) {
            self.items = items
            self.style = style
            self.onReorder = onReorder
        }

        func update(
            items: [ClipboardCollectionStripItem],
            style: ClipboardCollectionStripStyle,
            onReorder: @escaping (ClipboardCollectionID, ClipboardCollectionID, Bool) -> Bool
        ) {
            let oldSnapshot = self.items.map(ItemSnapshot.init)
            let newSnapshot = items.map(ItemSnapshot.init)
            self.items = items
            self.style = style
            self.onReorder = onReorder
            guard let collectionView else { return }
            guard oldSnapshot != newSnapshot else {
                reconfigureVisibleItems(in: collectionView)
                return
            }
            let scrollView = collectionView.enclosingScrollView
            let visibleOrigin = scrollView?.contentView.bounds.origin
            collectionView.reloadData()
            if let scrollView, let visibleOrigin {
                scrollView.contentView.scroll(to: visibleOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        private func reconfigureVisibleItems(in collectionView: NSCollectionView) {
            for case let item as ClipboardCollectionViewItem in collectionView.visibleItems() {
                guard let indexPath = collectionView.indexPath(for: item),
                      items.indices.contains(indexPath.item) else { continue }
                let model = items[indexPath.item]
                item.configure(
                    model: model,
                    style: style,
                    isDropTargeted: dropTargetID == model.id
                )
            }
        }

        func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

        func collectionView(
            _ collectionView: NSCollectionView,
            numberOfItemsInSection section: Int
        ) -> Int {
            items.count
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            guard let item = collectionView.makeItem(
                withIdentifier: ClipboardCollectionViewItem.reuseIdentifier,
                for: indexPath
            ) as? ClipboardCollectionViewItem else {
                return NSCollectionViewItem()
            }
            let model = items[indexPath.item]
            item.configure(
                model: model,
                style: style,
                isDropTargeted: dropTargetID == model.id
            )
            return item
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> NSSize {
            let model = items[indexPath.item]
            return NSSize(width: style.itemWidth(for: model.title), height: style.height)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            didSelectItemsAt indexPaths: Set<IndexPath>
        ) {
            guard let indexPath = indexPaths.first, items.indices.contains(indexPath.item) else { return }
            items[indexPath.item].action()
            collectionView.deselectItems(at: indexPaths)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            pasteboardWriterForItemAt indexPath: IndexPath
        ) -> NSPasteboardWriting? {
            guard items.indices.contains(indexPath.item) else { return nil }
            let writer = NSPasteboardItem()
            writer.setString(items[indexPath.item].id.id, forType: Self.reorderPasteboardType)
            return writer
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            validateDrop draggingInfo: NSDraggingInfo,
            proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
            dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
        ) -> NSDragOperation {
            if sourceCollectionID(from: draggingInfo.draggingPasteboard) != nil {
                proposedDropOperation.pointee = .before
                clearDropTarget()
                return .move
            }

            guard let target = externalDropTarget(
                proposedDropIndexPath.pointee as IndexPath
            ), target.onDropPayloads != nil else {
                clearDropTarget()
                return []
            }
            proposedDropOperation.pointee = .on
            setDropTarget(target.id)
            return .copy
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            acceptDrop draggingInfo: NSDraggingInfo,
            indexPath: IndexPath,
            dropOperation: NSCollectionView.DropOperation
        ) -> Bool {
            defer { clearDropTarget() }
            if let source = sourceCollectionID(from: draggingInfo.draggingPasteboard) {
                guard let destination = ClipboardCollectionReorderResolver.destination(
                    for: source,
                    in: items.map(\.id),
                    proposedIndex: indexPath.item
                ) else {
                    return false
                }
                return onReorder(source, destination.target, destination.afterTarget)
            }

            guard dropOperation == .on,
                  let target = externalDropTarget(indexPath),
                  let onDropPayloads = target.onDropPayloads else {
                return false
            }
            let payloads = draggingInfo.draggingPasteboard.pasteboardItems?.compactMap { item in
                item.data(
                    forType: NSPasteboard.PasteboardType(
                        UTType.pasteBuddyPinboardItemIDs.identifier
                    )
                ).flatMap { try? JSONDecoder().decode(PinboardItemDragPayload.self, from: $0) }
            } ?? []
            return !payloads.isEmpty && onDropPayloads(payloads)
        }

        func clearDropTarget() {
            setDropTarget(nil)
        }

        private func setDropTarget(_ id: ClipboardCollectionID?) {
            guard dropTargetID != id else { return }
            let changedIDs = [dropTargetID, id].compactMap { $0 }
            dropTargetID = id
            guard let collectionView else { return }
            let indexPaths = Set(changedIDs.compactMap { changedID in
                items.firstIndex(where: { $0.id == changedID }).map {
                    IndexPath(item: $0, section: 0)
                }
            })
            collectionView.reloadItems(at: indexPaths)
        }

        private func sourceCollectionID(from pasteboard: NSPasteboard) -> ClipboardCollectionID? {
            guard let identifier = pasteboard.string(forType: Self.reorderPasteboardType) else {
                return nil
            }
            return items.first(where: { $0.id.id == identifier })?.id
        }

        private func externalDropTarget(
            _ indexPath: IndexPath
        ) -> ClipboardCollectionStripItem? {
            guard !items.isEmpty else { return nil }
            return items[min(indexPath.item, items.index(before: items.endIndex))]
        }
    }
}

private struct ItemSnapshot: Equatable {
    let id: ClipboardCollectionID
    let title: String
    let isSelected: Bool
    let acceptsDrop: Bool

    init(_ item: ClipboardCollectionStripItem) {
        id = item.id
        title = item.title
        isSelected = item.isSelected
        acceptsDrop = item.onDropPayloads != nil
    }
}

@MainActor
private final class ClipboardCollectionView: NSCollectionView {
    var onDraggingExited: (() -> Void)?

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onDraggingExited?()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        super.draggingEnded(sender)
        onDraggingExited?()
    }
}

@MainActor
private final class ClipboardCollectionViewItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("ClipboardCollectionViewItem")

    private var hostingView: NSHostingView<ClipboardCollectionChipLabel>?

    override func loadView() {
        view = ClipboardCollectionItemView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
    }

    func configure(
        model: ClipboardCollectionStripItem,
        style: ClipboardCollectionStripStyle,
        isDropTargeted: Bool
    ) {
        (view as? ClipboardCollectionItemView)?.activation = model.action
        let rootView = ClipboardCollectionChipLabel(
            title: model.title,
            isSelected: model.isSelected,
            isDropTargeted: isDropTargeted,
            style: style
        )
        if let hostingView {
            hostingView.rootView = rootView
        } else {
            let hostingView = NSHostingView(rootView: rootView)
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            hostingView.sizingOptions = []
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            view.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: view.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            self.hostingView = hostingView
        }

        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(model.title)
        view.setAccessibilityValue(
            model.isSelected
                ? NSLocalizedString("state.selected", comment: "")
                : NSLocalizedString("label.not_selected", comment: "")
        )
        var actions: [NSAccessibilityCustomAction] = []
        if model.canMoveLeft {
            actions.append(NSAccessibilityCustomAction(
                name: NSLocalizedString("action.move_left", comment: ""),
                handler: {
                    model.onMoveLeft()
                    return true
                }
            ))
        }
        if model.canMoveRight {
            actions.append(NSAccessibilityCustomAction(
                name: NSLocalizedString("action.move_right", comment: ""),
                handler: {
                    model.onMoveRight()
                    return true
                }
            ))
        }
        view.setAccessibilityCustomActions(actions)
    }
}

@MainActor
private final class ClipboardCollectionItemView: NSView {
    var activation: (() -> Void)?

    override func accessibilityPerformPress() -> Bool {
        guard let activation else { return false }
        activation()
        return true
    }
}
