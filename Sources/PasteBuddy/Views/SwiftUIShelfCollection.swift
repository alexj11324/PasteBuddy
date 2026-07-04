import SwiftUI

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
        onDoubleClick: @escaping (UUID) -> Void
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
            .scrollIndicators(.hidden)
        case .vertical:
            ScrollView(.vertical) {
                LazyVStack(spacing: spacing) {
                    collectionItems
                }
            }
            .scrollIndicators(.hidden)
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
        let itemContent = content(item, selectedIDs.contains(itemID) || primarySelectedID == itemID)
            .frame(width: itemSize.width, height: itemSize.height)
            .contentShape(Rectangle())

        let itemView = Group {
            if selectable {
                Button {
                    onSelect(itemID)
                } label: {
                    itemContent
                }
                .buttonStyle(.plain)
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        onDoubleClick(itemID)
                    }
                )
            } else {
                itemContent
            }
        }
            .id(itemID)
            .popover(
                isPresented: presentedPreviewBinding(for: itemID),
                attachmentAnchor: .rect(.bounds),
                arrowEdge: previewArrowEdge
            ) {
                previewContent(item)
            }

        if let payload = dragPayload?(item) {
            itemView.draggable(payload)
        } else {
            itemView
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
