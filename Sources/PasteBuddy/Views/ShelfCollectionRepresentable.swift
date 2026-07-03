import AppKit
import SwiftUI

@MainActor
struct ShelfCollectionRepresentable<Item: Identifiable, Content: View>: NSViewRepresentable where Item.ID == UUID {
    var items: [Item]
    var selectedIDs: Set<UUID>
    var primarySelectedID: UUID?
    var itemSize: CGSize
    var interitemSpacing: CGFloat
    var scrollDirection: NSCollectionView.ScrollDirection
    var contentRevision: Int
    var previewedID: UUID?
    var onPreviewDismiss: () -> Void
    var previewPreferredEdge: NSRectEdge
    var previewContent: ((Item) -> AnyView)?
    var isSelectable: (Item) -> Bool
    var content: (Item, Bool) -> Content
    var onSelect: (UUID, NSEvent.ModifierFlags) -> Void
    var onDoubleClick: (UUID) -> Void
    var pasteboardWriter: ((Item) -> NSPasteboardWriting?)?

    init(
        items: [Item],
        selectedIDs: Set<UUID>,
        primarySelectedID: UUID?,
        itemSize: CGSize,
        interitemSpacing: CGFloat,
        scrollDirection: NSCollectionView.ScrollDirection = .horizontal,
        contentRevision: Int = 0,
        previewedID: UUID? = nil,
        onPreviewDismiss: @escaping () -> Void = {},
        previewPreferredEdge: NSRectEdge = .minX,
        previewContent: ((Item) -> AnyView)? = nil,
        isSelectable: @escaping (Item) -> Bool = { _ in true },
        @ViewBuilder content: @escaping (Item, Bool) -> Content,
        onSelect: @escaping (UUID, NSEvent.ModifierFlags) -> Void,
        onDoubleClick: @escaping (UUID) -> Void,
        pasteboardWriter: ((Item) -> NSPasteboardWriting?)? = nil
    ) {
        self.items = items
        self.selectedIDs = selectedIDs
        self.primarySelectedID = primarySelectedID
        self.itemSize = itemSize
        self.interitemSpacing = interitemSpacing
        self.scrollDirection = scrollDirection
        self.contentRevision = contentRevision
        self.previewedID = previewedID
        self.onPreviewDismiss = onPreviewDismiss
        self.previewPreferredEdge = previewPreferredEdge
        self.previewContent = previewContent
        self.isSelectable = isSelectable
        self.content = content
        self.onSelect = onSelect
        self.onDoubleClick = onDoubleClick
        self.pasteboardWriter = pasteboardWriter
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = scrollDirection
        layout.minimumInteritemSpacing = interitemSpacing
        layout.minimumLineSpacing = interitemSpacing
        layout.itemSize = itemSize
        layout.sectionInset = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)

        let collectionView = ShelfCollectionView()
        collectionView.focusRingType = .none
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            ShelfCollectionViewItem<Item, Content>.self,
            forItemWithIdentifier: ShelfCollectionViewItem<Item, Content>.reuseIdentifier
        )
        collectionView.mouseDownSelectionHandler = { [weak coordinator = context.coordinator] collectionView, indexPath, event in
            coordinator?.handleMouseDownSelection(in: collectionView, indexPath: indexPath, event: event)
        }
        collectionView.doubleClickHandler = { [weak coordinator = context.coordinator] collectionView, indexPath in
            coordinator?.handleDoubleClick(in: collectionView, indexPath: indexPath)
        }
        collectionView.isSelectableIndexPath = { [weak coordinator = context.coordinator] indexPath in
            coordinator?.isSelectableItem(at: indexPath) ?? false
        }
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: true)

        let scrollView = ShelfCollectionScrollView()
        scrollView.focusRingType = .none
        scrollView.scrollDirection = scrollDirection
        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScroller = nil
        scrollView.verticalScroller = nil
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.postsBoundsChangedNotifications = true
        scrollView.horizontalScrollElasticity = scrollDirection == .horizontal ? .automatic : .none
        scrollView.verticalScrollElasticity = scrollDirection == .vertical ? .automatic : .none
        scrollView.usesPredominantAxisScrolling = scrollDirection == .vertical

        context.coordinator.collectionView = collectionView
        context.coordinator.scrollView = scrollView
        context.coordinator.parent = self
        scrollView.boundsChangedHandler = { [weak coordinator = context.coordinator] in
            coordinator?.handleBoundsChanged()
        }
        context.coordinator.syncData()
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self

        if let layout = context.coordinator.collectionView?.collectionViewLayout as? NSCollectionViewFlowLayout {
            var shouldInvalidateLayout = false
            if layout.itemSize != itemSize {
                layout.itemSize = itemSize
                shouldInvalidateLayout = true
            }
            if layout.minimumInteritemSpacing != interitemSpacing {
                layout.minimumInteritemSpacing = interitemSpacing
                shouldInvalidateLayout = true
            }
            if layout.minimumLineSpacing != interitemSpacing {
                layout.minimumLineSpacing = interitemSpacing
                shouldInvalidateLayout = true
            }
            if shouldInvalidateLayout {
                layout.invalidateLayout()
            }
        }

        context.coordinator.syncData()
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout, NSPopoverDelegate {
        var parent: ShelfCollectionRepresentable
        weak var collectionView: NSCollectionView?
        weak var scrollView: NSScrollView?

        private var lastMouseDownSelectionID: UUID?
        private var previousItemIDs: [UUID] = []
        private var previousSelectedIDs: Set<UUID> = []
        private var previousContentRevision: Int?
        private var previousPrimarySelectedID: UUID?
        private let popover = NSPopover()
        private var indexByID: [UUID: Int] = [:]

        init(_ parent: ShelfCollectionRepresentable) {
            self.parent = parent
            popover.behavior = .applicationDefined
            popover.animates = false
            super.init()
            popover.delegate = self
        }

        func syncData() {
            guard let collectionView else { return }

            let itemIDs = parent.items.map(\.id)
            let selectedIDs = effectiveSelectedIDs
            rebuildIndexIfNeeded(itemIDs: itemIDs)

            if itemIDs != previousItemIDs {
                collectionView.reloadData()
                previousItemIDs = itemIDs
                previousContentRevision = parent.contentRevision
                applySelection(to: collectionView, selectedIDs: selectedIDs)
                syncPreviewPopover(in: collectionView)
                previousSelectedIDs = selectedIDs
                return
            }

            if parent.contentRevision != previousContentRevision {
                reconfigureVisibleItems(in: collectionView)
                previousContentRevision = parent.contentRevision
            } else if selectedIDs != previousSelectedIDs {
                let changedIDs = selectedIDs.symmetricDifference(previousSelectedIDs)
                reconfigureVisibleItems(in: collectionView, limitedTo: changedIDs)
            }

            applySelection(to: collectionView, selectedIDs: selectedIDs)
            syncPreviewPopover(in: collectionView)
            previousSelectedIDs = selectedIDs
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.items.count
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            let collectionItem = collectionView.makeItem(
                withIdentifier: ShelfCollectionViewItem<Item, Content>.reuseIdentifier,
                for: indexPath
            )

            guard let shelfItem = collectionItem as? ShelfCollectionViewItem<Item, Content>,
                  let representedItem = item(at: indexPath) else {
                return collectionItem
            }

            configure(shelfItem, with: representedItem)
            return shelfItem
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> NSSize {
            parent.itemSize
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            guard let id = firstDisplayOrderedID(in: indexPaths),
                  id != lastMouseDownSelectionID else {
                lastMouseDownSelectionID = nil
                return
            }

            parent.onSelect(id, currentEventModifierFlags())
        }

        func collectionView(_ collectionView: NSCollectionView, shouldSelectItemsAt indexPaths: Set<IndexPath>) -> Set<IndexPath> {
            []
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            guard collectionView.selectionIndexPaths.isEmpty,
                  let id = firstDisplayOrderedID(in: indexPaths),
                  id != lastMouseDownSelectionID else {
                return
            }

            parent.onSelect(id, currentEventModifierFlags())
        }

        func collectionView(_ collectionView: NSCollectionView, shouldDeselectItemsAt indexPaths: Set<IndexPath>) -> Set<IndexPath> {
            []
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            pasteboardWriterForItemAt indexPath: IndexPath
        ) -> NSPasteboardWriting? {
            guard let representedItem = item(at: indexPath) else { return nil }
            return parent.pasteboardWriter?(representedItem)
        }

        func handleMouseDownSelection(in collectionView: NSCollectionView, indexPath: IndexPath, event: NSEvent) {
            guard event.type == .leftMouseDown,
                  !normalizedModifierFlags(from: event).contains(.control),
                  let item = item(at: indexPath) else {
                return
            }

            lastMouseDownSelectionID = item.id
            let nextSelection = selectionIndexPaths(afterSelecting: indexPath, event: event)
            setCollectionSelection(nextSelection, in: collectionView)
            parent.onSelect(item.id, normalizedModifierFlags(from: event))
        }

        func handleDoubleClick(in collectionView: NSCollectionView, indexPath: IndexPath) {
            guard let item = item(at: indexPath) else { return }
            parent.onDoubleClick(item.id)
        }

        func isSelectableItem(at indexPath: IndexPath) -> Bool {
            guard let item = item(at: indexPath) else { return false }
            return parent.isSelectable(item)
        }

        private var effectiveSelectedIDs: Set<UUID> {
            var selectedIDs = parent.selectedIDs
            if let primarySelectedID = parent.primarySelectedID {
                selectedIDs.insert(primarySelectedID)
            }
            return selectedIDs
        }

        private func rebuildIndexIfNeeded(itemIDs: [UUID]) {
            guard itemIDs != previousItemIDs else { return }
            indexByID = Dictionary(uniqueKeysWithValues: itemIDs.enumerated().map { ($0.element, $0.offset) })
        }

        private func configure(_ shelfItem: ShelfCollectionViewItem<Item, Content>, with representedItem: Item) {
            let isSelected = parent.selectedIDs.contains(representedItem.id) || parent.primarySelectedID == representedItem.id
            shelfItem.configure(
                item: representedItem,
                isSelected: isSelected,
                isSelectable: parent.isSelectable(representedItem),
                content: parent.content
            )
        }

        private func applySelection(to collectionView: NSCollectionView, selectedIDs: Set<UUID>) {
            let selectedIndexPaths = indexPaths(for: selectedIDs)
            if collectionView.selectionIndexPaths != selectedIndexPaths {
                setCollectionSelection(selectedIndexPaths, in: collectionView)
            }
            scrollPrimarySelectionIntoView(in: collectionView)
        }

        // Only scrolls when the primary selection actually moved: the working
        // clip-view scroll would otherwise yank the viewport back to the selected
        // row on every unrelated data refresh while the user is browsing.
        private func scrollPrimarySelectionIntoView(in collectionView: NSCollectionView) {
            let primarySelectedID = parent.primarySelectedID
            defer { previousPrimarySelectedID = primarySelectedID }
            guard let primarySelectedID,
                  primarySelectedID != previousPrimarySelectedID else { return }
            collectionView.layoutSubtreeIfNeeded()
            scrollItemIntoView(primarySelectedID, in: collectionView)
        }

        private func scrollItemIntoView(_ id: UUID, in collectionView: NSCollectionView) {
            guard let scrollView,
                  let itemFrame = itemFrameInCollectionCoordinates(for: id) else { return }
            let clipView = scrollView.contentView
            guard let origin = ShelfCollectionScrollMath.origin(
                toReveal: itemFrame,
                visibleRect: clipView.documentVisibleRect,
                documentSize: collectionView.bounds.size,
                direction: parent.scrollDirection
            ) else { return }
            clipView.scroll(to: origin)
            scrollView.reflectScrolledClipView(clipView)
        }

        private func syncPreviewPopover(in collectionView: NSCollectionView) {
            guard let previewedID = parent.previewedID,
                  parent.previewContent != nil else {
                if popover.isShown {
                    popover.close()
                }
                return
            }
            collectionView.layoutSubtreeIfNeeded()
            showOrMovePopover(for: previewedID)
        }

        private func showOrMovePopover(for id: UUID) {
            guard let scrollView,
                  let item = item(withID: id),
                  let previewContent = parent.previewContent else {
                return
            }
            let clipView = scrollView.contentView
            let anchorRect = previewAnchorRect(for: id, in: clipView)
            let content = previewContent(item)
            if let hosting = popover.contentViewController as? NSHostingController<AnyView> {
                hosting.rootView = content
            } else {
                popover.contentViewController = NSHostingController(rootView: content)
            }
            if popover.isShown {
                popover.positioningRect = anchorRect
            } else if clipView.window != nil {
                popover.show(relativeTo: anchorRect, of: clipView, preferredEdge: parent.previewPreferredEdge)
            }
        }

        func popoverDidClose(_ notification: Notification) {
            if parent.previewedID != nil {
                parent.onPreviewDismiss()
            }
        }

        func handleBoundsChanged() {
            reanchorPopoverIfNeeded()
        }

        private func reanchorPopoverIfNeeded() {
            guard popover.isShown,
                  let previewedID = parent.previewedID,
                  let scrollView else {
                return
            }
            popover.positioningRect = previewAnchorRect(for: previewedID, in: scrollView.contentView)
        }

        // The anchor must always name a spot inside the viewport: NSPopover keeps
        // pointing at a clamped edge rect while the previewed row is scrolled
        // offscreen instead of drifting over the panel or closing.
        private func previewAnchorRect(for id: UUID, in clipView: NSClipView) -> NSRect {
            guard let collectionView,
                  let itemFrame = itemFrameInCollectionCoordinates(for: id) else {
                return fallbackAnchorRect(in: clipView)
            }
            let visibleRect = collectionView.visibleRect
            var anchorFrame = itemFrame.intersection(visibleRect)
            if anchorFrame.isEmpty {
                let width = min(itemFrame.width, max(1, visibleRect.width))
                let height = min(itemFrame.height, max(1, visibleRect.height))
                anchorFrame = NSRect(
                    x: min(max(itemFrame.minX, visibleRect.minX), visibleRect.maxX - width),
                    y: min(max(itemFrame.minY, visibleRect.minY), visibleRect.maxY - height),
                    width: width,
                    height: height
                )
            }
            return collectionView.convert(anchorFrame, to: clipView)
        }

        private func fallbackAnchorRect(in clipView: NSClipView) -> NSRect {
            NSRect(x: clipView.bounds.minX, y: clipView.bounds.midY, width: 1, height: 1)
        }

        private func itemFrameInCollectionCoordinates(for id: UUID) -> NSRect? {
            guard let collectionView,
                  let indexPath = indexPath(for: id) else {
                return nil
            }
            return collectionView.layoutAttributesForItem(at: indexPath)?.frame
        }

        private func indexPath(for id: UUID) -> IndexPath? {
            guard let index = indexByID[id] else { return nil }
            return IndexPath(item: index, section: 0)
        }

        private func setCollectionSelection(_ selection: Set<IndexPath>, in collectionView: NSCollectionView) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                collectionView.selectionIndexPaths = selection
            }
        }

        private func selectionIndexPaths(afterSelecting indexPath: IndexPath, event: NSEvent) -> Set<IndexPath> {
            let flags = normalizedModifierFlags(from: event)
            let currentSelection = indexPaths(for: effectiveSelectedIDs)

            if flags.contains(.shift),
               let primarySelectedID = parent.primarySelectedID,
               let anchorIndex = indexByID[primarySelectedID] {
                let bounds = min(anchorIndex, indexPath.item)...max(anchorIndex, indexPath.item)
                return Set(bounds.map { IndexPath(item: $0, section: 0) })
            }

            if flags.contains(.command) {
                var nextSelection = currentSelection
                if nextSelection.contains(indexPath) {
                    nextSelection.remove(indexPath)
                } else {
                    nextSelection.insert(indexPath)
                }
                return nextSelection
            }

            if currentSelection.count > 1, currentSelection.contains(indexPath) {
                return currentSelection
            }
            return [indexPath]
        }

        private func indexPaths(for ids: Set<UUID>) -> Set<IndexPath> {
            Set(ids.compactMap { id in
                guard let index = indexByID[id] else { return nil }
                return IndexPath(item: index, section: 0)
            })
        }

        private func reconfigureVisibleItems(in collectionView: NSCollectionView, limitedTo changedIDs: Set<UUID>? = nil) {
            for collectionItem in collectionView.visibleItems() {
                guard let shelfItem = collectionItem as? ShelfCollectionViewItem<Item, Content>,
                      let id = collectionItem.representedObject as? UUID,
                      changedIDs?.contains(id) ?? true,
                      let representedItem = item(withID: id) else {
                    continue
                }
                configure(shelfItem, with: representedItem)
            }
        }

        private func item(at indexPath: IndexPath) -> Item? {
            guard indexPath.section == 0,
                  indexPath.item >= parent.items.startIndex,
                  indexPath.item < parent.items.endIndex else {
                return nil
            }
            return parent.items[indexPath.item]
        }

        private func item(withID id: UUID) -> Item? {
            guard let index = indexByID[id], index >= parent.items.startIndex, index < parent.items.endIndex else {
                return nil
            }
            return parent.items[index]
        }

        private func firstDisplayOrderedID(in indexPaths: Set<IndexPath>) -> UUID? {
            indexPaths
                .sorted { $0.item < $1.item }
                .compactMap { item(at: $0)?.id }
                .first
        }

        private func currentEventModifierFlags() -> NSEvent.ModifierFlags {
            guard let event = NSApp.currentEvent else { return [] }
            return normalizedModifierFlags(from: event)
        }

        private func normalizedModifierFlags(from event: NSEvent) -> NSEvent.ModifierFlags {
            event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        }
    }
}

// NSCollectionView.scrollToItems(at:scrollPosition:) with the nearest-edge
// positions is unreliable for offscreen rows in this scroll-view configuration,
// so selection-follow scrolling computes the clip origin directly instead.
enum ShelfCollectionScrollMath {
    static func origin(
        toReveal itemFrame: NSRect,
        visibleRect: NSRect,
        documentSize: NSSize,
        direction: NSCollectionView.ScrollDirection
    ) -> NSPoint? {
        var origin = visibleRect.origin
        if direction == .vertical {
            if itemFrame.minY < visibleRect.minY {
                origin.y = itemFrame.minY
            } else if itemFrame.maxY > visibleRect.maxY {
                origin.y = itemFrame.maxY - visibleRect.height
            }
            origin.y = min(max(0, origin.y), max(0, documentSize.height - visibleRect.height))
        } else {
            if itemFrame.minX < visibleRect.minX {
                origin.x = itemFrame.minX
            } else if itemFrame.maxX > visibleRect.maxX {
                origin.x = itemFrame.maxX - visibleRect.width
            }
            origin.x = min(max(0, origin.x), max(0, documentSize.width - visibleRect.width))
        }
        return origin == visibleRect.origin ? nil : origin
    }
}

private final class ShelfCollectionScrollView: NSScrollView {
    var scrollDirection: NSCollectionView.ScrollDirection = .horizontal
    var boundsChangedHandler: (() -> Void)?

    override var horizontalScroller: NSScroller? {
        get { nil }
        set { super.horizontalScroller = nil }
    }

    override var verticalScroller: NSScroller? {
        get { nil }
        set { super.verticalScroller = nil }
    }

    override var hasHorizontalScroller: Bool {
        get { false }
        set { super.hasHorizontalScroller = false }
    }

    override var hasVerticalScroller: Bool {
        get { false }
        set { super.hasVerticalScroller = false }
    }

    override var autohidesScrollers: Bool {
        get { true }
        set { super.autohidesScrollers = true }
    }

    override func scrollWheel(with event: NSEvent) {
        guard scrollDirection == .horizontal else {
            super.scrollWheel(with: event)
            hideScrollers()
            return
        }
        guard event.scrollingDeltaX == 0, event.scrollingDeltaY != 0 else {
            super.scrollWheel(with: event)
            hideScrollers()
            return
        }

        scrollHorizontally(by: -normalizedScrollDelta(event.scrollingDeltaY, for: event))
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        hideScrollers()
        boundsChangedHandler?()
    }

    override func tile() {
        super.tile()
        hideScrollers()
    }

    private func normalizedScrollDelta(_ delta: CGFloat, for event: NSEvent) -> CGFloat {
        delta * (event.hasPreciseScrollingDeltas ? 1.25 : 64)
    }

    private func scrollHorizontally(by delta: CGFloat) {
        guard let documentView else { return }

        let clipView = contentView
        let maxX = max(0, documentView.frame.width - clipView.bounds.width)
        let currentX = clipView.bounds.origin.x
        let nextX = min(max(currentX + delta, 0), maxX)
        guard nextX != currentX else { return }

        clipView.scroll(to: NSPoint(x: nextX, y: clipView.bounds.origin.y))
        reflectScrolledClipView(clipView)
    }

    private func hideScrollers() {
        horizontalScroller?.isHidden = true
        verticalScroller?.isHidden = true
    }
}

private final class ShelfCollectionView: NSCollectionView {
    var mouseDownSelectionHandler: ((NSCollectionView, IndexPath, NSEvent) -> Void)?
    var doubleClickHandler: ((NSCollectionView, IndexPath) -> Void)?
    var isSelectableIndexPath: ((IndexPath) -> Bool)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        routeMouseDownSelection(with: event)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        routeDoubleClick(with: event)
    }

    override var isFlipped: Bool {
        true
    }

    @discardableResult
    func handleMouseDownFromDescendant(_ event: NSEvent) -> Bool {
        guard routeMouseDownSelection(with: event) else { return false }
        super.mouseDown(with: event)
        return true
    }

    @discardableResult
    func handleMouseUpFromDescendant(_ event: NSEvent) -> Bool {
        guard shouldRouteShelfMouseEvent(event) else { return false }
        super.mouseUp(with: event)
        routeDoubleClick(with: event)
        return true
    }

    @discardableResult
    private func routeMouseDownSelection(with event: NSEvent) -> Bool {
        guard shouldRouteShelfMouseEvent(event),
              let indexPath = indexPathForShelfItem(at: convert(event.locationInWindow, from: nil)) else {
            return false
        }
        mouseDownSelectionHandler?(self, indexPath, event)
        return true
    }

    @discardableResult
    private func routeDoubleClick(with event: NSEvent) -> Bool {
        guard event.clickCount >= 2,
              shouldRouteShelfMouseEvent(event),
              let indexPath = indexPathForShelfItem(at: convert(event.locationInWindow, from: nil)) else {
            return false
        }
        doubleClickHandler?(self, indexPath)
        return true
    }

    private func indexPathForShelfItem(at point: NSPoint) -> IndexPath? {
        guard bounds.contains(point) else { return nil }
        let visibleRect = self.visibleRect
        return collectionViewLayout?
            .layoutAttributesForElements(in: visibleRect)
            .filter { $0.representedElementCategory == .item }
            .compactMap { attributes -> (attributes: NSCollectionViewLayoutAttributes, indexPath: IndexPath)? in
                guard let indexPath = attributes.indexPath else { return nil }
                return (attributes, indexPath)
            }
            .sorted { $0.indexPath.item < $1.indexPath.item }
            .first { attributes, indexPath in
                attributes.frame.contains(point)
                    && (isSelectableIndexPath?(indexPath) ?? true)
            }?
            .indexPath
    }

    private func shouldRouteShelfMouseEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            break
        default:
            return false
        }
        guard event.window == nil || event.window === window else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return !flags.contains(.control)
    }
}

private final class ShelfCollectionViewItem<Item: Identifiable, Content: View>: NSCollectionViewItem where Item.ID == UUID {
    static var reuseIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("ShelfCollectionViewItem-\(String(describing: Item.self))-\(String(describing: Content.self))")
    }

    private var hostingView: ShelfCollectionHostingView<Content>?

    override func loadView() {
        view = ShelfCollectionItemContainerView()
    }

    func configure(
        item: Item,
        isSelected: Bool,
        isSelectable: Bool,
        content: (Item, Bool) -> Content
    ) {
        representedObject = item.id
        if let containerView = view as? ShelfCollectionItemContainerView {
            containerView.routesShelfMouseEvents = isSelectable
        }

        let rootView = content(item, isSelected)
        if let hostingView {
            hostingView.rootView = rootView
            hostingView.routesShelfMouseEvents = isSelectable
        } else {
            let hostingView = ShelfCollectionHostingView(rootView: rootView)
            hostingView.routesShelfMouseEvents = isSelectable
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            hostingView.setContentHuggingPriority(.defaultLow, for: .horizontal)
            hostingView.setContentHuggingPriority(.defaultLow, for: .vertical)
            view.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: view.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            self.hostingView = hostingView
        }
    }
}

private final class ShelfCollectionItemContainerView: NSView {
    var routesShelfMouseEvents = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard routesShelfMouseEvents,
              enclosingShelfCollectionView?.handleMouseDownFromDescendant(event) == true else {
            super.mouseDown(with: event)
            return
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard routesShelfMouseEvents,
              enclosingShelfCollectionView?.handleMouseUpFromDescendant(event) == true else {
            super.mouseUp(with: event)
            return
        }
    }
}

private final class ShelfCollectionHostingView<Content: View>: NSHostingView<Content> {
    var routesShelfMouseEvents = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard routesShelfMouseEvents,
              bounds.contains(point),
              let event = window?.currentEvent ?? NSApp.currentEvent,
              shouldHandleShelfSelectionEvent(event) else {
            return super.hitTest(point)
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard routesShelfMouseEvents,
              enclosingShelfCollectionView?.handleMouseDownFromDescendant(event) == true else {
            super.mouseDown(with: event)
            return
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard routesShelfMouseEvents,
              enclosingShelfCollectionView?.handleMouseUpFromDescendant(event) == true else {
            super.mouseUp(with: event)
            return
        }
    }
}

private extension NSView {
    var enclosingShelfCollectionView: ShelfCollectionView? {
        var view = superview
        while let currentView = view {
            if let collectionView = currentView as? ShelfCollectionView {
                return collectionView
            }
            view = currentView.superview
        }
        return nil
    }

    func shouldHandleShelfSelectionEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            break
        default:
            return false
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return !flags.contains(.control)
    }
}
