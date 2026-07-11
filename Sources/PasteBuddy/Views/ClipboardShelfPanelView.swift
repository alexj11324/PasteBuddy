import AppKit
import PasteBuddyCore
import SwiftUI

private enum ClipboardShelfMetrics {
    static let cardWidth: CGFloat = 240
    static let cardHeight: CGFloat = 240
    static let cardHeaderHeight: CGFloat = 58
    static let cardPreviewHeight: CGFloat = cardHeight - cardHeaderHeight
    static let linkMetadataFooterHeight: CGFloat = 58
    static let linkMetadataImageHeight: CGFloat = cardPreviewHeight - linkMetadataFooterHeight
    static let cardCornerRadius: CGFloat = 17
    static let searchIdleWidth: CGFloat = 208
    static let searchFocusedWidth: CGFloat = 272
    static let searchFilteredWidth: CGFloat = 310
    static let sourceAppSuggestionWidth: CGFloat = 168
    static let shelfVerticalPadding: CGFloat = 6
    static let shelfHeight: CGFloat = cardHeight + shelfVerticalPadding * 2
}


private enum ClipboardShelfDisplayItem: Identifiable {
    case launchAtLoginPrompt
    case empty(title: String, detail: String, systemImageName: String)
    case loadMore
    case clipboard(ClipboardItem)

    var id: UUID {
        switch self {
        case .launchAtLoginPrompt:
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        case .empty:
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        case .loadMore:
            UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        case .clipboard(let item):
            item.id
        }
    }
}

struct ClipboardShelfPanelView: View {
    private static let basePasteSearchAnimation = Animation.smooth(duration: 0.24, extraBounce: 0)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var store: PasteBuddyStore
    let directPasteItem: @MainActor (ClipboardItem, PasteFormat) async -> DirectPasteResult
    let directPasteItems: @MainActor ([ClipboardItem], PasteFormat) async -> DirectPasteResult
    let reloadClipboardHistory: @MainActor () async -> Bool
    let onFirstPageApplied: @MainActor (PasteBuddyPerformanceSignposts.ItemCountBucket) -> Void
    let onDismiss: () -> Void
    let onDismissImmediately: () -> Void

    @FocusState private var isSearchFocused: Bool
    @FocusState private var isShelfFocused: Bool
    @State private var isShowingLaunchAtLoginPrompt = false
    @State private var panelData: ClipboardPanelDataModel
    @State private var shelfInteraction = ShelfInteractionModel()
    @State private var isSearchRailPresented = false
    @State private var relativeDateReference = Date()
    @State private var collectionMoveState = ClipboardPanelCollectionMoveState()
    @State private var collectionDragSession = ClipboardCollectionDragSession()
    @State private var collectionFrames: [ClipboardCollectionID: CGRect] = [:]

    init(
        store: PasteBuddyStore,
        directPasteItem: @escaping @MainActor (ClipboardItem, PasteFormat) async -> DirectPasteResult,
        directPasteItems: @escaping @MainActor ([ClipboardItem], PasteFormat) async -> DirectPasteResult,
        reloadClipboardHistory: @escaping @MainActor () async -> Bool,
        onFirstPageApplied: @escaping @MainActor (PasteBuddyPerformanceSignposts.ItemCountBucket) -> Void,
        onDismiss: @escaping () -> Void,
        onDismissImmediately: @escaping () -> Void
    ) {
        _store = Bindable(wrappedValue: store)
        self.directPasteItem = directPasteItem
        self.directPasteItems = directPasteItems
        self.reloadClipboardHistory = reloadClipboardHistory
        self.onFirstPageApplied = onFirstPageApplied
        self.onDismiss = onDismiss
        self.onDismissImmediately = onDismissImmediately
        _panelData = State(initialValue: ClipboardPanelDataModel(store: store))
    }

    var body: some View {
        VStack(spacing: 12) {
            toolbar
                .zIndex(1)
            shelf
                .zIndex(0)
        }
        .padding(.top, 12)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .pasteBuddyBottomSheetSurface(cornerRadius: 28, showsStroke: false)
        .background(Color.clear)
        .background(shelfKeyboardShortcuts)
        .onAppear {
            store.searchQuery = ""
            store.clearFilters()
            refreshPanel(scope: store.selectedScope)
            isSearchRailPresented = true
            Task { @MainActor in
                await Task.yield()
                setSearchFocused(false)
            }
        }
        .onDisappear {
            collectionDragSession.cancel()
            isSearchRailPresented = false
            panelData.cancel()
        }
        .onChange(of: shelfQueryState) { previous, current in
            guard collectionMoveState.requiresRefresh(from: previous, to: current) else { return }
            refreshPanel()
        }
        .onChange(of: store.searchQuery) {
            shelfInteraction.dismissPreview()
        }
        .onMoveCommand(perform: handleShelfMoveCommand)
        .onExitCommand(perform: handleExitCommand)
        .focusable(true)
        .focusEffectDisabled()
        .focused($isShelfFocused)
        .onKeyPress(phases: .down) { keyPress in
            handleShelfKeyPress(keyPress, allowsPreview: true)
        }
        .task {
            await runShelfMinuteTicker()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("label.pastebuddy_clipboard_shelf"))
    }

    private var shelfKeyboardShortcuts: some View {
        Group {
            keyboardShortcut(.leftArrow) { moveSelection(.left) }
            keyboardShortcut(.rightArrow) { moveSelection(.right) }
            keyboardShortcut(.upArrow) { moveSelection(.up) }
            keyboardShortcut(.downArrow) { moveSelection(.down) }
        }
        .disabled(isSearchFocused || shelfInteraction.previewedID != nil)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func keyboardShortcut(_ key: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Color.clear
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: [])
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                searchControl
                    .layoutPriority(3)
                    .zIndex(20)

                collectionStrip
                    .layoutPriority(1)

                if selectedCount > 1 {
                    ShelfSelectedCountChip(count: selectedCount)
                }

                Menu {
                    Button {
                        createNamedPinboard()
                    } label: {
                        Label("label.new_pinboard", systemImage: "plus.rectangle.on.folder")
                    }
                    .keyboardShortcut("n", modifiers: [.command, .shift])

                    Button {
                        syncSmartPinboardsAndShowFirst()
                    } label: {
                        Label("action.sync_smart_pinboards", systemImage: "wand.and.stars")
                    }
                } label: {
                    ShelfToolbarCircleIcon(systemName: "plus")
                }
                .buttonStyle(.plain)
                .labelStyle(.iconOnly)
                .help(localized("action.add_item_or_pinboard"))

                Menu {
                    filtersMenu
                    Divider()
                    Button {
                        reloadHistory()
                    } label: {
                        Label("action.reload_clipboard_history", systemImage: "arrow.clockwise")
                    }

                    Button {
                        store.toggleCapturePaused()
                    } label: {
                        Label(
                            localized(store.isCapturePaused ? "action.resume_capture" : "action.pause_capture"),
                            systemImage: store.isCapturePaused ? "play.fill" : "pause.fill"
                        )
                    }
                    .keyboardShortcut("t", modifiers: [.command])

                    Button {
                        store.undoLastDeletion()
                    } label: {
                        Label("action.undo_delete", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!store.canUndoDelete)
                } label: {
                    ShelfToolbarCircleIcon(systemName: "ellipsis")
                }
                .buttonStyle(.plain)
                .labelStyle(.iconOnly)
                .help(localized("label.more_actions"))
            }
            .controlSize(.large)
            .animation(pasteSearchAnimation, value: isSearchRailPresented)
            .animation(pasteSearchAnimation, value: isSearchFocused)
            .animation(pasteSearchAnimation, value: store.sourceAppFilter)
            .animation(pasteSearchAnimation, value: selectedCount)

            if !visibleActiveFilterSummaries.isEmpty {
                activeFilterStrip
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(pasteSearchAnimation, value: visibleActiveFilterSummaries.count)
    }

    private var searchControl: some View {
        HStack(spacing: 8) {
            if let sourceAppFilter = store.sourceAppFilter {
                ShelfSourceAppToken(appName: sourceAppFilter) {
                    store.sourceAppFilter = nil
                    refreshPanel()
                    setSearchFocused(true)
                }
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.86, anchor: .leading).combined(with: .opacity),
                    removal: .scale(scale: 0.92, anchor: .leading).combined(with: .opacity)
                ))
            }

            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isSearchFocused ? .primary : .secondary)
                .accessibilityHidden(true)

            TextField("", text: $store.searchQuery, prompt: Text(localized("label.search_or_app")))
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($isSearchFocused)
                .frame(minWidth: 48)
                .accessibilityIdentifier("clipboard-shelf-search-field")
                .accessibilityLabel(localized("label.search_or_app"))
                .onKeyPress(phases: .down) { keyPress in
                    handleShelfKeyPress(keyPress, allowsPreview: false)
                }
                .onSubmit {
                    pasteSelected(format: store.defaultPasteFormat)
                }

            if hasSearchText {
                Button {
                    store.searchQuery = ""
                    refreshPanel()
                    setSearchFocused(true)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .labelStyle(.iconOnly)
                .help(localized("action.clear_search"))
                .accessibilityLabel(localized("action.clear_search"))
                .transition(.scale(scale: 0.86).combined(with: .opacity))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, hasSearchText ? 8 : 12)
        .padding(.vertical, 8)
        .frame(width: searchControlWidth, height: 38)
        .contentShape(Capsule())
        .onTapGesture {
            setSearchFocused(true)
        }
        .pasteBuddyGlassSurface(cornerRadius: 19, interactive: true)
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .strokeBorder(
                    isSearchFocused ? Color.accentColor.opacity(0.70) : .primary.opacity(0.08),
                    lineWidth: isSearchFocused ? 1.5 : 1
                )
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(isSearchFocused ? 0.11 : 0.06), radius: isSearchFocused ? 10 : 6, y: isSearchFocused ? 3 : 2)
        .background {
            SourceAppSuggestionPanelPresenter(
                isPresented: shouldShowSourceAppSuggestions,
                appNames: sourceAppSuggestions,
                query: store.searchQuery,
                width: ClipboardShelfMetrics.sourceAppSuggestionWidth,
                onSelect: { appName in
                    store.applySourceAppSuggestion(appName)
                    refreshPanel()
                }
            )
        }
        .animation(pasteSearchAnimation, value: searchControlWidth)
        .animation(pasteSearchAnimation, value: isSearchRailPresented)
        .animation(pasteSearchAnimation, value: isSearchFocused)
        .animation(pasteSearchAnimation, value: store.sourceAppFilter)
    }

    private var searchControlWidth: CGFloat {
        guard isSearchRailPresented else {
            return ClipboardShelfMetrics.searchIdleWidth
        }
        if store.sourceAppFilter != nil {
            return ClipboardShelfMetrics.searchFilteredWidth
        }
        if isSearchFocused || hasSearchText {
            return ClipboardShelfMetrics.searchFocusedWidth
        }
        return ClipboardShelfMetrics.searchFocusedWidth
    }

    private var hasSearchText: Bool {
        !store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sourceAppSuggestions: [String] {
        store.sourceAppSuggestions(matching: store.searchQuery, limit: 3)
    }

    private var shouldShowSourceAppSuggestions: Bool {
        isSearchFocused
            && store.sourceAppFilter == nil
            && !store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sourceAppSuggestions.isEmpty
    }

    private var pasteSearchAnimation: Animation? {
        reduceMotion ? nil : Self.basePasteSearchAnimation
    }

    private var visibleActiveFilterSummaries: [ClipboardFilterDescriptor] {
        store.activeFilterSummaries.filter { descriptor in
            !(descriptor.kind == .sourceApp && store.sourceAppFilter != nil)
        }
    }

    private var collectionStrip: some View {
        let collectionOrder = collectionDragSession.displayOrder(fallback: store.collectionOrder)
        return ScrollView(.horizontal) {
            HStack(spacing: 5) {
                ForEach(collectionOrder) { collection in
                    collectionChip(for: collection, in: collectionOrder)
                }
            }
            .coordinateSpace(name: ClipboardCollectionDragCoordinateSpace.name)
            .padding(.vertical, 1)
        }
        .scrollIndicators(.never, axes: .horizontal)
        .scrollDisabled(collectionDragSession.isActive)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("label.clipboard_collections"))
    }

    @ViewBuilder
    private func collectionChip(
        for collection: ClipboardCollectionID,
        in collectionOrder: [ClipboardCollectionID]
    ) -> some View {
        switch collection {
        case .history:
            ShelfCollectionChip(
                collection: collection,
                collectionOrder: collectionOrder,
                dragSession: $collectionDragSession,
                collectionFrames: $collectionFrames,
                title: localized("label.clipboard"),
                systemImageName: "clock.arrow.circlepath",
                color: store.isCapturePaused ? .orange : .blue,
                isSelected: shelfScope == .history,
                onDropPayloads: { dropItems($0, into: .history) },
                onReorder: reorderCollection,
                canMoveLeft: collectionOrder.first != collection,
                canMoveRight: collectionOrder.last != collection,
                onMoveLeft: { moveCollection(collection, by: -1) },
                onMoveRight: { moveCollection(collection, by: 1) }
            ) {
                setScope(.history)
            }
        case .pasteStack:
            ShelfCollectionChip(
                collection: collection,
                collectionOrder: collectionOrder,
                dragSession: $collectionDragSession,
                collectionFrames: $collectionFrames,
                title: localized("action.paste_stack"),
                systemImageName: store.isPasteStackActive ? "tray.full.fill" : "tray",
                color: store.isPasteStackActive ? .green : .secondary,
                isSelected: shelfScope == .pasteStack,
                onDropPayloads: { dropItems($0, into: .pasteStack) },
                onReorder: reorderCollection,
                canMoveLeft: collectionOrder.first != collection,
                canMoveRight: collectionOrder.last != collection,
                onMoveLeft: { moveCollection(collection, by: -1) },
                onMoveRight: { moveCollection(collection, by: 1) }
            ) {
                setScope(.pasteStack)
            }
        case .smart(let category):
            ShelfCollectionChip(
                collection: collection,
                collectionOrder: collectionOrder,
                dragSession: $collectionDragSession,
                collectionFrames: $collectionFrames,
                title: localized(category.displayName),
                systemImageName: category.systemImageName,
                color: Color(hex: category.colorHex) ?? .accentColor,
                isSelected: isSmartCategorySelected(category),
                onReorder: reorderCollection,
                canMoveLeft: collectionOrder.first != collection,
                canMoveRight: collectionOrder.last != collection,
                onMoveLeft: { moveCollection(collection, by: -1) },
                onMoveRight: { moveCollection(collection, by: 1) }
            ) {
                selectSmartCategory(category)
            }
        case .pinboard(let id):
            if let pinboard = store.userPinboards.first(where: { $0.id == id }) {
                ShelfCollectionChip(
                    collection: collection,
                    collectionOrder: collectionOrder,
                    dragSession: $collectionDragSession,
                    collectionFrames: $collectionFrames,
                    title: pinboard.name,
                    systemImageName: pinboard.systemImageName ?? "pin.fill",
                    color: Color(hex: pinboard.colorHex) ?? .blue,
                    isSelected: shelfScope == .pinboard(pinboard.id),
                    onDropPayloads: { dropItems($0, into: .pinboard(pinboard.id)) },
                    onReorder: reorderCollection,
                    canMoveLeft: collectionOrder.first != collection,
                    canMoveRight: collectionOrder.last != collection,
                    onMoveLeft: { moveCollection(collection, by: -1) },
                    onMoveRight: { moveCollection(collection, by: 1) }
                ) {
                    setScope(.pinboard(pinboard.id))
                }
                .contextMenu {
                    CustomPinboardActionsMenu(
                        store: store,
                        pinboard: pinboard,
                        onMove: { moveCollection(collection, by: $0) }
                    )
                }
            }
        }
    }

    private func createNamedPinboard() {
        guard let name = NewPinboardNamePrompt.run() else { return }
        let pinboard = store.createPinboard(named: name)
        setScope(.pinboard(pinboard.id))
    }

    private var selectedCount: Int {
        selectedItemsInDisplayOrder.count
    }

    private var renderedShelfItems: [ClipboardItem] {
        panelData.items
    }

    private var shelfItems: [ClipboardItem] { panelData.items }
    private var shelfItemTotalCount: Int { panelData.totalCount }
    private var shelfScope: PasteScope { panelData.scope }

    private var shelfDisplayItems: [ClipboardShelfDisplayItem] {
        if isShowingLaunchAtLoginPrompt {
            return [.launchAtLoginPrompt]
        }
        if shelfItems.isEmpty {
            return [
                .empty(
                    title: emptyTitle,
                    detail: emptyDescription,
                    systemImageName: emptySystemImage
                )
            ]
        }

        var items = renderedShelfItems.map(ClipboardShelfDisplayItem.clipboard)
        if panelData.canLoadNextPage {
            items.append(.loadMore)
        }
        return items
    }

    private var shelfQueryState: ClipboardPanelQueryState {
        panelData.queryState
    }

    private var relativeDateMinuteBucket: Int {
        Int(relativeDateReference.timeIntervalSinceReferenceDate / 60)
    }

    private var activeFilterStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Label("label.active_clipboard_filters", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(visibleActiveFilterSummaries) { descriptor in
                    Button {
                        clearFilter(descriptor)
                    } label: {
                        Label(descriptor.title, systemImage: "xmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
                    .help(localized("action.remove_clipboard_filter"))
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.never, axes: .horizontal)
    }

    @ViewBuilder
    private var filtersMenu: some View {
        Menu("label.filters") {
            Picker("label.type", selection: $store.contentTypeFilter) {
                Text("label.any_type").tag(nil as ClipboardContentType?)
                ForEach(ClipboardContentType.allCases) { type in
                    Text(localized(type.displayName)).tag(Optional(type))
                }
            }

            Picker("label.app", selection: $store.sourceAppFilter) {
                Text("label.any_app").tag(nil as String?)
                ForEach(store.availableSourceApps, id: \.self) { appName in
                    Text(appName).tag(Optional(appName))
                }
            }

            Picker("label.device", selection: $store.deviceFilter) {
                Text("label.any_device").tag(nil as String?)
                ForEach(store.availableDevices, id: \.self) { deviceName in
                    Text(deviceName).tag(Optional(deviceName))
                }
            }

            Picker("label.date", selection: $store.dateFilter) {
                ForEach(ClipboardDateFilter.allCases) { filter in
                    Text(localized(filter.displayName)).tag(filter)
                }
            }

            Button("action.clear_filters") {
                store.clearFilters()
            }
            .disabled(!store.hasActiveFilters)
        }
    }

    private var shelf: some View {
        let pinboards = store.userPinboards
        let defaultPasteFormat = store.defaultPasteFormat

        return SwiftUIShelfCollection(
            items: shelfDisplayItems,
            selectedIDs: shelfInteraction.selectedIDs,
            primarySelectedID: shelfInteraction.primarySelectedID,
            itemSize: CGSize(width: ClipboardShelfMetrics.cardWidth, height: ClipboardShelfMetrics.shelfHeight),
            spacing: 20,
            direction: .horizontal,
            previewedID: shelfInteraction.previewedID,
            previewArrowEdge: .bottom,
            onPreviewDismiss: { id in
                shelfInteraction.dismissPreview(for: id)
            },
            isSelectable: { displayItem in
                if case .clipboard = displayItem {
                    return true
                }
                return false
            }
        ) { displayItem, isSelected in
            shelfDisplayItem(
                displayItem,
                isSelected: isSelected,
                defaultPasteFormat: defaultPasteFormat,
                pinboards: pinboards
            )
            .frame(
                width: ClipboardShelfMetrics.cardWidth,
                height: ClipboardShelfMetrics.shelfHeight,
                alignment: .bottom
            )
        } previewContent: { displayItem in
            guard case .clipboard(let item) = displayItem else {
                return AnyView(EmptyView())
            }
            return AnyView(
                ShelfExpandedPreview(
                    item: item,
                    imageDataProvider: store.imageData,
                    tint: SourceApplicationIconResolver.themeColor(for: item, fallback: item.presentationContentType.shelfTint),
                    onDismiss: {
                        shelfInteraction.dismissPreview()
                    },
                    onMove: moveSelection,
                    onTextInput: beginSearch
                )
            )
        } dragPayload: { displayItem in
            guard case .clipboard(let item) = displayItem else { return nil }
            return PinboardItemDragPayload(
                ids: [item.id],
                plainTextProvider: { ClipboardPlainTextRenderer.plainText(for: item) }
            )
        } onSelect: { id in
            guard let item = renderedShelfItems.first(where: { $0.id == id }) else { return }
            selectItem(item)
        } onDoubleClick: { id in
            guard let item = renderedShelfItems.first(where: { $0.id == id }) else { return }
            pasteItem(item, format: defaultPasteFormat)
        }
        .frame(height: ClipboardShelfMetrics.shelfHeight)
    }

    @ViewBuilder
    private func shelfDisplayItem(
        _ displayItem: ClipboardShelfDisplayItem,
        isSelected: Bool,
        defaultPasteFormat: PasteFormat,
        pinboards: [Pinboard]
    ) -> some View {
            switch displayItem {
            case .launchAtLoginPrompt:
                VStack {
                    Spacer(minLength: 0)
                    LaunchAtLoginShelfCard(store: store) {
                        isShowingLaunchAtLoginPrompt = false
                    }
                }
                .frame(width: ClipboardShelfMetrics.cardWidth, height: ClipboardShelfMetrics.shelfHeight, alignment: .bottom)
            case .empty(let title, let detail, let systemImageName):
                VStack {
                    Spacer(minLength: 0)
                    EmptyShelfCard(
                        title: title,
                        detail: detail,
                        systemImageName: systemImageName
                    )
                }
                .frame(width: ClipboardShelfMetrics.cardWidth, height: ClipboardShelfMetrics.shelfHeight, alignment: .bottom)
            case .loadMore:
                VStack {
                    Spacer(minLength: 0)
                    Button(action: loadNextPanelPage) {
                        EmptyShelfCard(
                            title: localized("label.more"),
                            detail: localized("format.items", max(shelfItemTotalCount - shelfItems.count, 0)),
                            systemImageName: "ellipsis.circle"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(localized("label.more"))
                }
                .frame(width: ClipboardShelfMetrics.cardWidth, height: ClipboardShelfMetrics.shelfHeight, alignment: .bottom)
            case .clipboard(let item):
                ClipboardShelfCard(
                    item: item,
                    imageDataProvider: store.imageData,
                    linkMetadataProvider: { item in
                        await store.enrichLinkPreviewMetadataIfNeeded(for: item)
                    },
                    isSelected: isSelected,
                    relativeDateReference: relativeDateReference,
                    defaultPasteFormat: defaultPasteFormat,
                    pinboards: pinboards,
                    onPaste: { format in
                        pasteItem(item, format: format)
                    },
                    onCopy: { format in
                        copyItem(item, format: format)
                    },
                    onPin: { pinboardID in
                        store.pinItem(item.id, to: pinboardID)
                    },
                    onDelete: {
                        store.removeItem(item.id)
                    }
                )
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
        }

    private var emptyTitle: String {
        shelfScope == .pasteStack ? localized("action.paste_stack_is_empty") : localized("label.no_clipboard_items")
    }

    private var emptySystemImage: String {
        shelfScope == .pasteStack ? "tray" : "doc.on.clipboard"
    }

    private var emptyDescription: String {
        if shelfScope == .pasteStack {
            return store.isPasteStackActive ? localized("message.new_copies_will_appear_here") : localized("message.start_collecting_copied_items")
        }
        return localized("message.copy_text_links_screenshots_or_files_to")
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        switch direction {
        case .left, .up:
            setSearchFocused(false)
            selectOffset(-1)
        case .right, .down:
            setSearchFocused(false)
            selectOffset(1)
        @unknown default:
            break
        }
    }

    private func handleShelfMoveCommand(_ direction: MoveCommandDirection) {
        moveSelection(direction)
        Task { @MainActor in
            await Task.yield()
            if !isSearchFocused {
                isShelfFocused = true
            }
        }
    }

    private func selectOffset(_ offset: Int) {
        let items = renderedShelfItems
        guard !items.isEmpty else { return }
        let currentID = shelfInteraction.primarySelectedID ?? shelfInteraction.selectedIDs.first
        let currentIndex = currentID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        let nextIndex = min(max(currentIndex + offset, items.startIndex), items.index(before: items.endIndex))
        selectSingleItem(items[nextIndex].id, keepsPreviewOpen: shelfInteraction.previewedID != nil)
    }

    private func setScope(_ scope: PasteScope) {
        guard shelfScope != scope else { return }
        shelfInteraction.dismissPreview()
        refreshPanel(scope: scope)
    }

    private func isSmartCategorySelected(_ category: SmartPinboardCategory) -> Bool {
        guard let pinboard = store.smartPinboard(for: category) else { return false }
        return shelfScope == .pinboard(pinboard.id)
    }

    private func selectSmartCategory(_ category: SmartPinboardCategory) {
        let pinboard = store.syncSmartPinboard(for: category)
        setScope(.pinboard(pinboard.id))
    }

    private func syncSmartPinboardsAndShowFirst() {
        let pinboards = store.syncSmartPinboards()
        if let firstPinboardID = pinboards.first?.id {
            setScope(.pinboard(firstPinboardID))
        }
    }

    private func reorderCollection(
        _ source: ClipboardCollectionID,
        relativeTo target: ClipboardCollectionID,
        afterTarget: Bool
    ) -> Bool {
        collectionMoveState.recordMove(
            store.moveCollection(source, relativeTo: target, afterTarget: afterTarget),
            dataRevision: store.dataRevision
        )
    }

    private func moveCollection(_ collection: ClipboardCollectionID, by offset: Int) {
        collectionMoveState.recordMove(
            store.moveCollection(collection, by: offset),
            dataRevision: store.dataRevision
        )
    }

    private func dropItems(_ payloads: [PinboardItemDragPayload], into target: ClipboardCollectionDropTarget) -> Bool {
        let ids = droppedItemIDs(from: payloads)
        return target.apply(ids: ids, store: store, selectScope: setScope)
    }

    private func droppedItemIDs(from payloads: [PinboardItemDragPayload]) -> [UUID] {
        var seen = Set<UUID>()
        return payloads.flatMap(\.ids).filter { seen.insert($0).inserted }
    }

    private func clearFilter(_ descriptor: ClipboardFilterDescriptor) {
        shelfInteraction.dismissPreview()
        switch descriptor.kind {
        case .contentType:
            store.contentTypeFilter = nil
        case .sourceApp:
            store.sourceAppFilter = nil
        case .device:
            store.deviceFilter = nil
        case .date:
            store.dateFilter = .any
        }
        refreshPanel()
    }

    private func selectItem(_ item: ClipboardItem) {
        PasteBuddyMotion.performInstantSelection {
            shelfInteraction.select(item.id)
        }
        setSearchFocused(false)
    }

    private func pasteSelected(format: PasteFormat) {
        let items = selectedItemsInDisplayOrder
        guard !items.isEmpty else { return }
        Task { @MainActor in
            let result = await ClipboardShelfDirectPasteCoordinator.runAfterImmediateDismissal(
                dismiss: onDismissImmediately
            ) {
                let hydratedItems = await store.hydratedItems(for: items)
                return await directPasteItems(hydratedItems, format)
            }
            store.recordDirectPasteResult(result)
        }
    }

    private func pasteItem(_ item: ClipboardItem, format: PasteFormat) {
        selectSingleItem(item.id)
        Task { @MainActor in
            let result = await ClipboardShelfDirectPasteCoordinator.runAfterImmediateDismissal(
                dismiss: onDismissImmediately
            ) {
                let hydratedItem = await store.hydratedItem(for: item)
                return await directPasteItem(hydratedItem, format)
            }
            store.recordDirectPasteResult(result)
        }
    }

    private func copyItem(_ item: ClipboardItem, format: PasteFormat) {
        Task { @MainActor in
            let hydratedItem = await store.hydratedItem(for: item)
            PasteboardWriter.copy(hydratedItem, format: format)
        }
    }

    private func reloadHistory() {
        Task { @MainActor in
            guard await reloadClipboardHistory() else { return }
            refreshPanel()
        }
    }

    private var selectedItemsInDisplayOrder: [ClipboardItem] {
        let ids = shelfInteraction.selectedIDs
        guard !ids.isEmpty else {
            return shelfInteraction.primarySelectedID.flatMap { id in renderedShelfItems.first { $0.id == id } }.map { [$0] } ?? []
        }
        return renderedShelfItems.filter { ids.contains($0.id) }
    }

    private func selectSingleItem(_ id: UUID?, keepsPreviewOpen: Bool = false) {
        PasteBuddyMotion.performInstantSelection {
            shelfInteraction.selectSingle(id, keepsPreviewOpen: keepsPreviewOpen)
        }
    }

    private func setSearchFocused(_ isFocused: Bool) {
        guard isFocused else {
            self.isSearchFocused = false
            self.isShelfFocused = true
            return
        }
        self.isShelfFocused = false
        withAnimation(pasteSearchAnimation) {
            self.isSearchFocused = isFocused
        }
    }

    private func handleShelfKeyPress(_ keyPress: KeyPress, allowsPreview: Bool) -> KeyPress.Result {
        let modifiers = keyPress.modifiers

        if keyPress.key == .space, modifiers.isEmpty, allowsPreview, !isSearchFocused {
            toggleSelectedItemPreview()
            return .handled
        }

        if modifiers.isEmpty, !isSearchFocused {
            switch keyPress.key {
            case .upArrow:
                moveSelection(.up)
                return .handled
            case .downArrow:
                moveSelection(.down)
                return .handled
            case .leftArrow:
                moveSelection(.left)
                return .handled
            case .rightArrow:
                moveSelection(.right)
                return .handled
            default:
                break
            }
        }

        if keyPress.key == .return {
            if modifiers.isEmpty {
                pasteSelected(format: store.defaultPasteFormat)
                return .handled
            }
            if modifiers == .shift {
                pasteSelected(format: .plainText)
                return .handled
            }
        }

        if modifiers == .command {
            let characters = keyPress.characters.lowercased()
            if characters == "f" {
                setSearchFocused(true)
                return .handled
            }
            if let index = Int(characters), (1...9).contains(index),
               let item = store.quickPasteItem(atOneBasedIndex: index, in: shelfScope) {
                pasteItem(item, format: store.defaultPasteFormat)
                return .handled
            }
        }

        if ClipboardPanelSearchInput.accepts(modifiers), !isSearchFocused, beginSearch(with: keyPress.characters) {
            return .handled
        }

        return .ignored
    }

    private func beginSearch(with characters: String) -> Bool {
        guard ClipboardPanelSearchInput.accepts(characters) else { return false }
        shelfInteraction.dismissPreview()
        store.searchQuery += characters
        setSearchFocused(true)
        return true
    }

    private func toggleSelectedItemPreview() {
        guard let item = selectedItemsInDisplayOrder.first else { return }
        setSearchFocused(false)
        if shelfInteraction.togglePreview(for: item.id) {
            selectSingleItem(item.id)
        }
    }

    private func handleExitCommand() {
        if collectionDragSession.isActive {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                collectionDragSession.cancel()
            }
            return
        }
        if isSearchFocused {
            if !store.searchQuery.isEmpty {
                store.searchQuery = ""
                refreshPanel()
            }
            setSearchFocused(false)
            return
        }
        if shelfInteraction.previewedID != nil {
            shelfInteraction.dismissPreview()
            return
        }
        onDismiss()
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    private func localized(_ key: String, _ arguments: CVarArg...) -> String {
        String(
            format: NSLocalizedString(key, comment: ""),
            locale: Locale.current,
            arguments: arguments
        )
    }

    private func refreshPanel(scope: PasteScope? = nil) {
        let interaction = shelfInteraction
        let store = store
        let onFirstPageApplied = onFirstPageApplied
        panelData.refresh(scope: scope) { items, totalCount in
            interaction.replaceItems(
                items,
                storeSelectedIDs: store.selectedItemIDs,
                storePrimarySelectedID: store.selectedItemID
            )
            onFirstPageApplied(.init(itemCount: totalCount))
        }
    }

    private func loadNextPanelPage() {
        let interaction = shelfInteraction
        let store = store
        panelData.loadNextPage { items, _ in
            interaction.replaceItems(
                items,
                storeSelectedIDs: store.selectedItemIDs,
                storePrimarySelectedID: store.selectedItemID
            )
        }
    }

    private func runShelfMinuteTicker() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            relativeDateReference = Date()
        }
    }
}

private struct LaunchAtLoginShelfCard: View {
    @Bindable var store: PasteBuddyStore
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "power")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: store.snapshot.general.launchAtLoginEnabled ? "checkmark.circle.fill" : "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(store.snapshot.general.launchAtLoginEnabled ? .green : .secondary)
                .help("action.hide_this_prompt")
            }

            Spacer()

            VStack(alignment: .leading, spacing: 5) {
                Text("action.open_at_login")
                    .font(.headline)
                Text("message.automatically_start_pastebuddy_when_your_mac_restarts")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Button(launchAtLoginButtonTitle) {
                store.setLaunchAtLoginEnabled(
                    !store.snapshot.general.launchAtLoginEnabled,
                    applySystemRegistration: LaunchAtLoginService.isAvailable
                )
            }
            .disabled(!LaunchAtLoginService.isAvailable)
            .pasteBuddyGlassButton()
            .help(LaunchAtLoginService.isAvailable ? "action.toggle_launch_at_login" : "message.launch_at_login_is_unavailable_in_this")
        }
        .padding(20)
        .frame(width: 240, height: 230)
        .pasteBuddyGlassSurface(cornerRadius: 18, interactive: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("action.open_at_login.a7a8de0b")
    }

    private var launchAtLoginButtonTitle: String {
        if !LaunchAtLoginService.isAvailable {
            return "Unavailable"
        }
        return store.snapshot.general.launchAtLoginEnabled ? "Enabled" : "Enable"
    }
}

private struct ShelfCollectionChip: View {
    private static let hoverAnimation = Animation.smooth(duration: 0.18, extraBounce: 0.04)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let collection: ClipboardCollectionID
    let collectionOrder: [ClipboardCollectionID]
    @Binding var dragSession: ClipboardCollectionDragSession
    @Binding var collectionFrames: [ClipboardCollectionID: CGRect]
    let title: String
    let systemImageName: String
    let color: Color
    let isSelected: Bool
    var onDropPayloads: (([PinboardItemDragPayload]) -> Bool)?
    let onReorder: (ClipboardCollectionID, ClipboardCollectionID, Bool) -> Bool
    let canMoveLeft: Bool
    let canMoveRight: Bool
    let onMoveLeft: () -> Void
    let onMoveRight: () -> Void
    let action: () -> Void
    @State private var isHovered = false
    @State private var isDropTargeted = false

    init(
        collection: ClipboardCollectionID,
        collectionOrder: [ClipboardCollectionID],
        dragSession: Binding<ClipboardCollectionDragSession>,
        collectionFrames: Binding<[ClipboardCollectionID: CGRect]>,
        title: String,
        systemImageName: String,
        color: Color,
        isSelected: Bool,
        onDropPayloads: (([PinboardItemDragPayload]) -> Bool)? = nil,
        onReorder: @escaping (ClipboardCollectionID, ClipboardCollectionID, Bool) -> Bool,
        canMoveLeft: Bool,
        canMoveRight: Bool,
        onMoveLeft: @escaping () -> Void,
        onMoveRight: @escaping () -> Void,
        action: @escaping () -> Void
    ) {
        self.collection = collection
        self.collectionOrder = collectionOrder
        _dragSession = dragSession
        _collectionFrames = collectionFrames
        self.title = title
        self.systemImageName = systemImageName
        self.color = color
        self.isSelected = isSelected
        self.onDropPayloads = onDropPayloads
        self.onReorder = onReorder
        self.canMoveLeft = canMoveLeft
        self.canMoveRight = canMoveRight
        self.onMoveLeft = onMoveLeft
        self.onMoveRight = onMoveRight
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImageName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(iconForegroundStyle)

                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(height: 38)
            .background {
                if isSelected || isHovered || isDropTargeted {
                    Capsule()
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(isSelected || isDropTargeted ? 0.86 : 0.64))
                        .background(.regularMaterial, in: Capsule())
                }
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(
            ClipboardCollectionReorderModifier(
                collection: collection,
                collectionOrder: collectionOrder,
                session: $dragSession,
                collectionFrames: $collectionFrames,
                isTargeted: $isDropTargeted,
                animation: reduceMotion ? nil : .snappy(duration: 0.18),
                onReorder: onReorder,
                onDropPayloads: onDropPayloads
            )
        )
        .onHover { isHovered in
            withAnimation(reduceMotion ? nil : Self.hoverAnimation) {
                self.isHovered = isHovered
            }
        }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? NSLocalizedString("state.selected", comment: "") : NSLocalizedString("label.not_selected", comment: ""))
        .accessibilityActions {
            if canMoveLeft {
                Button(NSLocalizedString("action.move_left", comment: ""), action: onMoveLeft)
            }
            if canMoveRight {
                Button(NSLocalizedString("action.move_right", comment: ""), action: onMoveRight)
            }
        }
    }

    private var iconForegroundStyle: Color {
        if isSelected {
            return .primary
        }
        return color
    }

    private var helpText: String {
        title
    }
}

private struct ShelfSelectedCountChip: View {
    let count: Int

    var body: some View {
        Label(String(format: NSLocalizedString("format.selected", comment: ""), count), systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(height: 38)
            .background {
                Capsule()
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.82))
                    .background(.regularMaterial, in: Capsule())
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(format: NSLocalizedString("format.selected", comment: ""), count))
    }
}

private struct ClipboardShelfCard: View {
    let item: ClipboardItem
    let imageDataProvider: @MainActor (ClipboardItem) async -> Data?
    let linkMetadataProvider: @MainActor (ClipboardItem) async -> Void
    let isSelected: Bool
    let relativeDateReference: Date
    let defaultPasteFormat: PasteFormat
    let pinboards: [Pinboard]
    let onPaste: (PasteFormat) -> Void
    let onCopy: (PasteFormat) -> Void
    let onPin: (UUID) -> Void
    let onDelete: () -> Void

    var body: some View {
        ClipboardShelfCardVisual(
            item: item,
            imageDataProvider: imageDataProvider,
            linkMetadataProvider: linkMetadataProvider,
            relativeDateReference: relativeDateReference
        )
            .equatable()
            .overlay {
                ClipboardShelfCardSelectionRing(item: item, isSelected: isSelected)
        }
        .contextMenu {
            contextMenuContent
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("clipboard-shelf-card-\(item.id.uuidString)")
        .accessibilityLabel("\(item.title), \(localized(item.presentationContentType.displayName))")
        .accessibilityValue(localized(isSelected ? "state.selected" : "label.not_selected"))
        .accessibilityHint(localized("message.press_space_to_preview_press_return_to"))
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Group {
            Button("action.paste") {
                onPaste(defaultPasteFormat)
            }
            Button("action.paste_as_plain_text") {
                onPaste(.plainText)
            }
            Button("action.copy") {
                onCopy(.original)
            }
            Button("action.copy_as_plain_text") {
                onCopy(.plainText)
            }
            if let url = item.openableURL {
                Button("action.open") {
                    NSWorkspace.shared.open(url)
                }
            }
            Divider()
            Menu("action.pin") {
                ForEach(pinboards) { pinboard in
                    Button(pinboard.name) {
                        onPin(pinboard.id)
                    }
                }
            }
            Button("action.delete", role: .destructive) {
                onDelete()
            }
        }
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}

private struct ClipboardShelfCardVisual: View {
    let item: ClipboardItem
    let imageDataProvider: @MainActor (ClipboardItem) async -> Data?
    let linkMetadataProvider: @MainActor (ClipboardItem) async -> Void
    let relativeDateReference: Date
    private let renderSignature: ClipboardShelfCardRenderSignature

    init(
        item: ClipboardItem,
        imageDataProvider: @escaping @MainActor (ClipboardItem) async -> Data?,
        linkMetadataProvider: @escaping @MainActor (ClipboardItem) async -> Void,
        relativeDateReference: Date
    ) {
        self.item = item
        self.imageDataProvider = imageDataProvider
        self.linkMetadataProvider = linkMetadataProvider
        self.relativeDateReference = relativeDateReference
        self.renderSignature = ClipboardShelfCardRenderSignature(
            item: item,
            relativeDateReference: relativeDateReference
        )
    }

    private var cardTint: Color {
        SourceApplicationIconResolver.themeColor(for: item, fallback: item.presentationContentType.shelfTint)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(localized(item.presentationContentType.displayName))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Text(relativeDate(relativeTo: relativeDateReference))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white.opacity(0.82))
            }
            Spacer()
            SourceApplicationIconBadge(item: item)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .frame(height: ClipboardShelfMetrics.cardHeaderHeight)
        .background(cardTint)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            previewBody
        }
        .frame(width: ClipboardShelfMetrics.cardWidth, height: ClipboardShelfMetrics.cardHeight)
        .background {
            RoundedRectangle(cornerRadius: ClipboardShelfMetrics.cardCornerRadius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: ClipboardShelfMetrics.cardCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 8, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: ClipboardShelfMetrics.cardCornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var previewBody: some View {
        let preview = item.visualPreview

        if item.presentationContentType == .url {
            ShelfLinkPreviewCardBody(
                item: item,
                preview: preview,
                imageDataProvider: imageDataProvider,
                linkMetadataProvider: linkMetadataProvider,
                tint: cardTint
            )
        } else if preview.prefersImageThumbnail {
            ShelfThumbnailView(item: item, imageDataProvider: imageDataProvider, tint: cardTint)
        } else {
            VStack(alignment: .leading, spacing: 9) {
                Text(preview.body)
                    .font(item.presentationContentType == .text ? .callout.monospaced() : .callout)
                    .foregroundStyle(.primary)
                    .lineLimit(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(height: ClipboardShelfMetrics.cardPreviewHeight, alignment: .topLeading)
            .background {
                Rectangle()
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.94))
            }
            .background(.regularMaterial)
        }
    }

    private func relativeDate(relativeTo date: Date) -> String {
        Self.relativeFormatter.localizedString(for: item.createdAt, relativeTo: date)
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

extension ClipboardShelfCardVisual: Equatable {
    nonisolated static func == (lhs: ClipboardShelfCardVisual, rhs: ClipboardShelfCardVisual) -> Bool {
        lhs.renderSignature == rhs.renderSignature
    }
}

private struct ClipboardShelfCardSelectionRing: View {
    let item: ClipboardItem
    let isSelected: Bool

    private var cardTint: Color {
        SourceApplicationIconResolver.themeColor(for: item, fallback: item.presentationContentType.shelfTint)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: ClipboardShelfMetrics.cardCornerRadius, style: .continuous)
            .strokeBorder(isSelected ? cardTint : Color.white.opacity(0.24), lineWidth: isSelected ? 3 : 1)
    }
}

private struct ClipboardShelfCardRenderSignature: Equatable {
    let id: UUID
    let createdAt: Date
    let updatedAt: Date
    let sourceAppName: String
    let sourceBundleIdentifier: String?
    let contentType: ClipboardContentType
    let title: String
    let previewHeadline: String
    let previewBody: String
    let previewSearchHash: String
    let rtfAssetID: String?
    let imageAssetID: String?
    let imageByteCount: Int?
    let relativeDateMinuteBucket: Int

    init(item: ClipboardItem, relativeDateReference: Date) {
        id = item.id
        createdAt = item.createdAt
        updatedAt = item.updatedAt
        sourceAppName = item.sourceAppName
        sourceBundleIdentifier = item.sourceBundleIdentifier
        contentType = item.contentType
        title = item.title
        previewHeadline = item.searchDocument.previewHeadline
        previewBody = item.searchDocument.previewBody
        previewSearchHash = item.searchDocument.searchHash
        rtfAssetID = item.payload.rtfAssetID
        imageAssetID = item.payload.imageAssetID
        imageByteCount = item.payload.imageData?.count ?? item.payload.imageByteCount
        relativeDateMinuteBucket = Int(relativeDateReference.timeIntervalSinceReferenceDate / 60)
    }
}

private struct ShelfLinkPreviewCardBody: View {
    let item: ClipboardItem
    let preview: ClipboardVisualPreview
    let imageDataProvider: @MainActor (ClipboardItem) async -> Data?
    let linkMetadataProvider: @MainActor (ClipboardItem) async -> Void
    let tint: Color

    var body: some View {
        Group {
            if preview.prefersImageThumbnail {
                VStack(spacing: 0) {
                    ClipboardImageThumbnailView(
                        item: item,
                        imageDataProvider: imageDataProvider,
                        tint: tint,
                        contentMode: .fit,
                        placeholderIconSize: 30
                    )
                    .background(Color(nsColor: .textBackgroundColor))
                    .frame(height: ClipboardShelfMetrics.linkMetadataImageHeight)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    metadataFooter
                        .frame(height: ClipboardShelfMetrics.linkMetadataFooterHeight)
                }
                .frame(height: ClipboardShelfMetrics.cardPreviewHeight)
                .frame(maxWidth: .infinity)
                .clipped()
            } else {
                ZStack(alignment: .bottomLeading) {
                    Rectangle()
                        .fill(tint.opacity(0.10))
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "link.circle.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(tint)
                        Text(preview.headline)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text(preview.body)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(height: ClipboardShelfMetrics.cardPreviewHeight)
                .frame(maxWidth: .infinity)
                .clipped()
            }
        }
        .task(id: item.id) {
            guard !preview.prefersImageThumbnail else { return }
            await linkMetadataProvider(item)
        }
    }

    @MainActor
    private var metadataFooter: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(preview.headline)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(preview.body)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.78))
    }
}

private struct ShelfThumbnailView: View {
    let item: ClipboardItem
    let imageDataProvider: @MainActor (ClipboardItem) async -> Data?
    let tint: Color

    var body: some View {
        ClipboardImageThumbnailView(
            item: item,
            imageDataProvider: imageDataProvider,
            tint: tint,
            contentMode: .fill,
            placeholderIconSize: 30
        )
        .frame(height: ClipboardShelfMetrics.cardPreviewHeight)
        .frame(maxWidth: .infinity)
        .clipped()
    }
}

private struct ShelfSourceAppToken: View {
    let appName: String
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            SourceApplicationIconImage(appName: appName, size: 18)
            Text(appName)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("action.clear_app_filter", comment: ""))
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(appName)
    }
}

private struct EmptyShelfCard: View {
    let title: String
    let detail: String
    let systemImageName: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImageName)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .padding(20)
        .frame(width: 240, height: 210)
        .pasteBuddyGlassSurface(cornerRadius: 18, interactive: true)
    }
}
