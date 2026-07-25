import SwiftUI

struct ClipboardPanelPagingState<Item: Identifiable, QueryID: Equatable> where Item.ID == UUID {
    struct Request {
        let generation: Int
        let queryID: QueryID
        let offset: Int
    }

    private(set) var items: [Item] = []
    private(set) var totalCount = 0
    private(set) var queryID: QueryID?
    private var generation = 0

    var nextOffset: Int { items.count }
    var canLoadMore: Bool { items.count < totalCount }

    mutating func reset(with page: [Item], totalCount: Int, queryID: QueryID) {
        generation &+= 1
        items = page
        self.totalCount = max(totalCount, page.count)
        self.queryID = queryID
    }

    func nextPageRequest(for queryID: QueryID) -> Request? {
        guard canLoadMore, self.queryID == queryID else { return nil }
        return Request(generation: generation, queryID: queryID, offset: nextOffset)
    }

    @discardableResult
    mutating func append(
        _ page: [Item],
        totalCount: Int,
        for request: Request,
        currentQueryID: QueryID
    ) -> Bool {
        guard request.generation == generation,
              request.queryID == currentQueryID,
              queryID == currentQueryID,
              request.offset == nextOffset else {
            return false
        }
        let existingIDs = Set(items.map(\.id))
        items.append(contentsOf: page.filter { !existingIDs.contains($0.id) })
        self.totalCount = max(totalCount, items.count)
        return true
    }
}

@MainActor
struct SwiftUIShelfCollection<Item: Identifiable, Content: View, PreviewContent: View>: View where Item.ID == UUID {
    enum Direction {
        case horizontal
        case vertical
    }

    var items: [Item]
    var selectedIDs: Set<UUID>
    var primarySelectedID: UUID?
    var itemSize: CGSize
    var spacing: CGFloat
    var direction: Direction
    var previewedID: UUID?
    var previewArrowEdge: Edge
    var onPreviewDismiss: (UUID) -> Void
    var isSelectable: (Item) -> Bool
    var content: (Item, Bool) -> Content
    var previewContent: (Item) -> PreviewContent
    var dragPayload: ((Item) -> PinboardItemDragPayload?)?
    var onSelect: (UUID) -> Void
    var onDoubleClick: (UUID) -> Void
    var onLastItemAppear: () -> Void

    @State private var lastScrolledPrimarySelectedID: UUID?
    @State private var presentedPreviewID: UUID?
    @State private var previewPresentationGeneration = 0

    init(
        items: [Item],
        selectedIDs: Set<UUID>,
        primarySelectedID: UUID?,
        itemSize: CGSize,
        spacing: CGFloat,
        direction: Direction = .horizontal,
        previewedID: UUID? = nil,
        previewArrowEdge: Edge = .bottom,
        onPreviewDismiss: @escaping (UUID) -> Void = { _ in },
        isSelectable: @escaping (Item) -> Bool = { _ in true },
        @ViewBuilder content: @escaping (Item, Bool) -> Content,
        @ViewBuilder previewContent: @escaping (Item) -> PreviewContent,
        dragPayload: ((Item) -> PinboardItemDragPayload?)? = nil,
        onSelect: @escaping (UUID) -> Void,
        onDoubleClick: @escaping (UUID) -> Void,
        onLastItemAppear: @escaping () -> Void = {}
    ) {
        self.items = items
        self.selectedIDs = selectedIDs
        self.primarySelectedID = primarySelectedID
        self.itemSize = itemSize
        self.spacing = spacing
        self.direction = direction
        self.previewedID = previewedID
        self.previewArrowEdge = previewArrowEdge
        self.onPreviewDismiss = onPreviewDismiss
        self.isSelectable = isSelectable
        self.content = content
        self.previewContent = previewContent
        self.dragPayload = dragPayload
        self.onSelect = onSelect
        self.onDoubleClick = onDoubleClick
        self.onLastItemAppear = onLastItemAppear
    }

    var body: some View {
        ScrollViewReader { proxy in
            scrollBody
                .focusEffectDisabled()
                .onChange(of: primarySelectedID) {
                    scrollPrimarySelectionIfNeeded(with: proxy)
                }
                .onChange(of: previewedID) {
                    syncPresentedPreview()
                }
                .onChange(of: itemIDs) {
                    syncPresentedPreview()
                }
                .onAppear {
                    lastScrolledPrimarySelectedID = primarySelectedID
                    presentedPreviewID = validPreviewedID
                }
        }
    }

    @ViewBuilder
    private var scrollBody: some View {
        switch direction {
        case .horizontal:
            ScrollView(.horizontal) {
                LazyHStack(spacing: spacing) {
                    collectionItems
                }
                .padding(.horizontal, 4)
            }
            .scrollIndicators(.never, axes: .horizontal)
        case .vertical:
            ScrollView(.vertical) {
                LazyVStack(spacing: spacing) {
                    collectionItems
                }
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.never, axes: .vertical)
        }
    }

    private var collectionItems: some View {
        ForEach(items) { item in
            collectionItem(item)
        }
    }

    @ViewBuilder
    private func collectionItem(_ item: Item) -> some View {
        let itemID = item.id
        let selectable = isSelectable(item)
        let itemView = content(item, selectedIDs.contains(itemID) || primarySelectedID == itemID)
            .frame(width: itemSize.width, height: itemSize.height)
            .contentShape(Rectangle())
            .id(itemID)

        ZStack {
            if let payload = dragPayload?(item) {
                itemView.draggable(payload)
            } else {
                itemView
            }
        }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                guard selectable else { return }
                onDoubleClick(itemID)
            }
            .simultaneousGesture(
                TapGesture().onEnded {
                    guard selectable else { return }
                    lastScrolledPrimarySelectedID = itemID
                    onSelect(itemID)
                }
            )
            .popover(
                isPresented: presentedPreviewBinding(for: itemID),
                attachmentAnchor: .rect(.bounds),
                arrowEdge: previewArrowEdge
            ) {
                previewContent(item)
            }
            .onAppear {
                if itemID == items.last?.id {
                    onLastItemAppear()
                }
            }
    }

    private var itemIDs: [UUID] {
        items.map(\.id)
    }

    private var validPreviewedID: UUID? {
        guard let previewedID,
              items.contains(where: { $0.id == previewedID }) else {
            return nil
        }
        return previewedID
    }

    private func presentedPreviewBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: {
                presentedPreviewID == id
            },
            set: { isPresented in
                if !isPresented, presentedPreviewID == id {
                    presentedPreviewID = nil
                    onPreviewDismiss(id)
                }
            }
        )
    }

    private func scrollPrimarySelectionIfNeeded(with proxy: ScrollViewProxy) {
        guard let primarySelectedID,
              primarySelectedID != lastScrolledPrimarySelectedID,
              items.contains(where: { $0.id == primarySelectedID }) else {
            return
        }
        lastScrolledPrimarySelectedID = primarySelectedID
        proxy.scrollTo(primarySelectedID)
    }

    private func syncPresentedPreview() {
        let targetID = validPreviewedID
        guard presentedPreviewID != targetID else { return }

        previewPresentationGeneration += 1
        let generation = previewPresentationGeneration
        if presentedPreviewID != nil, targetID != nil {
            presentedPreviewID = nil
            Task { @MainActor in
                await Task.yield()
                guard previewPresentationGeneration == generation,
                      validPreviewedID == targetID else {
                    return
                }
                presentedPreviewID = targetID
            }
        } else {
            presentedPreviewID = targetID
        }
    }
}
