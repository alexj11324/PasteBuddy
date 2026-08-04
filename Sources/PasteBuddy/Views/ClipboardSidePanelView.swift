import AppKit
import PasteBuddyCore
import SwiftUI

private enum ClipboardSidePanelMetrics {
    static let rowHeight: CGFloat = 82
    static let thumbnailSize: CGFloat = 42
    static let previewMaxWidth: CGFloat = 640
    static let sourceAppSuggestionWidth: CGFloat = 220
}

private struct ClipboardSidePanelQueryState: Equatable {
    let dataRevision: Int
    let queryRevision: Int
    let scope: PasteScope
    let searchQuery: String
    let contentTypeFilter: ClipboardContentType?
    let sourceAppFilter: String?
    let deviceFilter: String?
    let dateFilter: ClipboardDateFilter
    let pasteStackRevision: Int
}

struct ClipboardSidePanelView: View {
    @Environment(\.openSettings) private var openSettings
    @Bindable var store: PasteBuddyStore
    @Binding var isPinned: Bool
    let directPasteItem: @MainActor (ClipboardItem, PasteFormat) async -> DirectPasteResult
    let directPasteItems: @MainActor ([ClipboardItem], PasteFormat) async -> DirectPasteResult
    let onDismiss: () -> Void
    let onDismissImmediately: () -> Void

    @FocusState private var isSearchFocused: Bool
    @FocusState private var isListFocused: Bool
    @State private var sideScope: PasteScope = .history
    @State private var paging = ClipboardPanelPagingState<ClipboardItem, ClipboardSidePanelQueryState>()
    @State private var interaction = ShelfInteractionModel()
    @State private var preparedPreview: ClipboardPreparedPreview?
    @State private var previewRequestID: UUID?
    @State private var pinnedState: Bool?
    @State private var timestampReference = Date()
    @State private var showingAISetup = false
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.32)
            itemList
        }
        .padding(.top, 14)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .pasteBuddyBottomSheetSurface(cornerRadius: 28, showsStroke: false)
        .background(Color.clear)
        .sheet(isPresented: $showingAISetup) {
            AISearchSetupSheet(store: store)
        }
        .onAppear {
            sideScope = store.selectedScope
            refreshSideItems()
            Task { @MainActor in
                await Task.yield()
                setSearchFocused(false)
            }
        }
        .onDisappear {
            dismissPreparedPreview()
        }
        .onChange(of: queryState) {
            refreshSideItems()
        }
        .onChange(of: store.searchQuery) {
            dismissPreparedPreview()
        }
        .onExitCommand(perform: handleExitCommand)
        .focusable(true)
        .focusEffectDisabled()
        .focused($isListFocused)
        .onCopyCommand {
            let items = selectedItemsInDisplayOrder
            return ClipboardPanelCopyCoordinator.itemProviders(
                for: items,
                sourceWindow: NSApp.keyWindow
            ) { item in
                await store.hydratedItem(for: item)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pasteBuddyCopyPanelSelection)) { _ in
            copySelectedItems()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pasteBuddyPastePanelSelection)) { _ in
            pasteSelected(format: store.defaultPasteFormat)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pasteBuddyCyclePanelPinboard)) { notification in
            guard let direction = notification.object as? PinboardCycleDirection else { return }
            cyclePinboard(direction)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pasteBuddyPanelArrowKey)) { notification in
            guard let request = notification.object as? ClipboardPanelArrowKeyRequest else { return }
            handlePanelArrowKey(request)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pasteBuddyPanelPreviewKey)) { notification in
            guard let request = notification.object as? ClipboardPanelPreviewKeyRequest,
                  !isSearchFocused else { return }
            toggleSelectedItemPreview()
            request.markHandled()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pasteBuddyPanelQuickPaste)) { notification in
            guard let request = notification.object as? ClipboardPanelQuickPasteRequest,
                  ClipboardPanelHistoryAvailability.allowsActions(
                      scope: sideScope,
                      errorMessage: store.historyQueryErrorMessage
                  ),
                  let item = store.quickPasteItem(
                      atOneBasedIndex: request.oneBasedIndex,
                      in: sideScope
                  ) else { return }
            request.markHandled()
            pasteItem(item, format: request.format)
        }
        .onKeyPress(phases: .down) { keyPress in
            handleKeyPress(keyPress)
        }
        .task {
            await HistoryCardTimestampTicker.run {
                timestampReference = $0
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("label.pastebuddy_clipboard_shelf"))
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    setPinned(!effectivePinned)
                } label: {
                    ShelfToolbarCircleIcon(systemName: effectivePinned ? "pin.fill" : "pin")
                        .rotationEffect(.degrees(45))
                }
                .buttonStyle(.plain)
                .labelStyle(.iconOnly)
                .help(localized("action.pin"))
                .accessibilityLabel(localized("action.pin"))

                searchControl
                    .layoutPriority(1)

                ClipboardPanelFiltersMenu(store: store)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .frame(width: 30, height: 30)

                Button {
                    store.clearRequestedSettingsDestination()
                    onDismissImmediately()
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    ShelfToolbarCircleIcon(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .labelStyle(.iconOnly)
                .help(localized("action.open_settings"))
                .accessibilityLabel(localized("action.open_settings"))
            }

            quickFilterStrip
        }
    }

    private var searchControl: some View {
        HStack(spacing: 7) {
            if let sourceAppFilter = store.sourceAppFilter {
                ClipboardSourceAppFilterToken(appName: sourceAppFilter) {
                    store.clearSourceAppFilter()
                    refreshSideItems()
                    setSearchFocused(true)
                }
            }

            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isSearchFocused ? .primary : .secondary)

            TextField("", text: $store.searchQuery, prompt: Text(localized("label.search_or_app")))
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .focused($isSearchFocused)
                .onTapGesture {
                    setSearchFocused(true)
                }
                .accessibilityIdentifier("clipboard-side-panel-search-field")
                .accessibilityLabel(localized("label.search_or_app"))

            if hasSearchText {
                Button {
                    store.searchQuery = ""
                    setSearchFocused(true)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(localized("action.clear_search"))
            }

            Button {
                if store.snapshot.semanticIndex.isEnabled && store.canRunConfiguredAISource {
                    Task { @MainActor in
                        await store.runSemanticSearch(scope: sideScope)
                        refreshSideItems()
                    }
                } else {
                    showingAISetup = true
                }
            } label: {
                if store.semanticSearchState == .loading {
                    ProgressView().controlSize(.small)
                } else if case .failed = store.semanticSearchState {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Image(systemName: "sparkles")
                }
            }
            .buttonStyle(.plain)
            .disabled(!hasSearchText)
            .help(localized("action.ai_search"))
            .accessibilityLabel(localized("action.ai_search"))
        }
        .padding(.leading, 12)
        .padding(.trailing, hasSearchText ? 8 : 12)
        .frame(height: 36)
        .pasteBuddyNativeGlass()
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture {
            setSearchFocused(true)
        }
        .background {
            SourceAppSuggestionPanelPresenter(
                isPresented: shouldShowSourceAppSuggestions,
                appNames: sourceAppSuggestions,
                query: store.searchQuery,
                width: ClipboardSidePanelMetrics.sourceAppSuggestionWidth,
                onSelect: { appName in
                    store.applySourceAppSuggestion(appName)
                    refreshSideItems()
                },
                onDismiss: {
                    setSearchFocused(false)
                }
            )
        }
    }

    private var quickFilterStrip: some View {
        let collectionOrder = store.collectionOrder.filter { $0 != .pasteStack }
        return HStack(spacing: 8) {
            ClipboardCollectionStrip(
                items: collectionOrder.compactMap {
                    collectionStripItem(for: $0, in: collectionOrder)
                },
                style: .sidePanel,
                accessibilityLabel: localized("label.clipboard_collections"),
                onReorder: reorderCollection
            )

                if case .applied = store.semanticSearchState,
                   store.semanticSearchScope == sideScope {
                    Button {
                        store.invalidateSemanticSearch()
                        refreshSideItems()
                    } label: {
                        Label("label.ai_results_applied", systemImage: "sparkles")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .help(localized("action.return_to_standard_search"))
                }

                if case .failed(let message) = store.semanticSearchState {
                    Button {
                        if store.canRunConfiguredAISource {
                            Task { @MainActor in
                                await store.runSemanticSearch(scope: sideScope)
                                refreshSideItems()
                            }
                        } else {
                            showingAISetup = true
                        }
                    } label: {
                        Label("label.ai_search_failed", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .help(message)
                }

                Button {
                    createNamedPinboard()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .labelStyle(.iconOnly)
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .help(localized("label.new_pinboard"))
                .accessibilityLabel(localized("label.new_pinboard"))
            }
            .padding(.vertical, 1)
        }
    }

    private func collectionStripItem(
        for collection: ClipboardCollectionID,
        in collectionOrder: [ClipboardCollectionID]
    ) -> ClipboardCollectionStripItem? {
        let canMoveLeft = collectionOrder.first != collection
        let canMoveRight = collectionOrder.last != collection
        let moveLeft = { moveCollection(collection, in: collectionOrder, by: -1) }
        let moveRight = { moveCollection(collection, in: collectionOrder, by: 1) }

        switch collection {
        case .history:
            return ClipboardCollectionStripItem(
                id: collection,
                title: localized("label.clipboard"),
                isSelected: sideScope == .history,
                onDropPayloads: nil,
                canMoveLeft: canMoveLeft,
                canMoveRight: canMoveRight,
                onMoveLeft: moveLeft,
                onMoveRight: moveRight,
                action: { setSideScope(.history) }
            )
        case .pasteStack:
            return nil
        case .smart(let category):
            return ClipboardCollectionStripItem(
                id: collection,
                title: localized(category.displayName),
                isSelected: isSmartCategorySelected(category),
                onDropPayloads: nil,
                canMoveLeft: canMoveLeft,
                canMoveRight: canMoveRight,
                onMoveLeft: moveLeft,
                onMoveRight: moveRight,
                action: { selectSmartCategory(category) }
            )
        case .pinboard(let id):
            guard let pinboard = store.userPinboards.first(where: { $0.id == id }) else {
                return nil
            }
            return ClipboardCollectionStripItem(
                id: collection,
                title: pinboard.name,
                isSelected: sideScope == .pinboard(pinboard.id),
                onDropPayloads: nil,
                canMoveLeft: canMoveLeft,
                canMoveRight: canMoveRight,
                onMoveLeft: moveLeft,
                onMoveRight: moveRight,
                action: { setSideScope(.pinboard(pinboard.id)) }
            )
        }
    }

    private func createNamedPinboard() {
        guard let name = NewPinboardNamePrompt.run() else { return }
        let pinboard = store.createPinboard(named: name)
        setSideScope(.pinboard(pinboard.id))
    }

    private var itemList: some View {
        VStack(spacing: 8) {
            if renderedItems.isEmpty, store.isHistoryQueryTransitioning, sideScope != .pasteStack {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: 280)
                    .accessibilityLabel(localized("label.clipboard"))
                    .accessibilityValue(localized("state.connecting"))
            } else if renderedItems.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: emptySystemImage,
                    description: Text(emptyDescription)
                )
                .frame(maxWidth: .infinity, minHeight: 280)
            } else {
                SwiftUIShelfCollection(
                    items: renderedItems,
                    selectedIDs: interaction.selectedIDs,
                    primarySelectedID: interaction.primarySelectedID,
                    itemSize: CGSize(width: 324, height: ClipboardSidePanelMetrics.rowHeight),
                    spacing: 10,
                    direction: .vertical,
                    previewedID: interaction.previewedID,
                    previewArrowEdge: .trailing,
                    onPreviewDismiss: { id in
                        dismissPreparedPreview(for: id)
                    },
                    isSelectable: { _ in true },
                    content: { item, isSelected in
                        ClipboardSidePanelListRow(
                            item: item,
                            imageDataProvider: store.imageData,
                            linkMetadataProvider: { item in
                                await store.enrichLinkPreviewMetadataIfNeeded(for: item)
                            },
                            isSelected: isSelected,
                            timestampReference: timestampReference,
                            defaultPasteFormat: store.defaultPasteFormat,
                            onPaste: { format in
                                pasteItem(item, format: format)
                            },
                            onCopy: { format in
                                copyItem(item, format: format)
                            },
                            onPin: { pinboardID in
                                store.pinItem(item.id, to: pinboardID)
                            },
                            onScreenPin: {
                                Task { @MainActor in
                                    ScreenPinController.shared.pin(
                                        await store.hydratedItem(for: item)
                                    )
                                }
                            },
                            isExcludedFromAISearch: store.isExcludedFromSemanticIndex(item.id),
                            onToggleAISearchIndex: {
                                store.toggleSemanticIndexExclusion(for: item)
                                refreshSideItems()
                            },
                            onDelete: {
                                store.removeItem(item.id)
                            },
                            pinboards: store.userPinboards
                        )
                        .frame(width: 324, height: ClipboardSidePanelMetrics.rowHeight)
                    },
                    previewContent: { item in
                        guard let preparedPreview,
                              preparedPreview.item.id == item.id else {
                            return AnyView(EmptyView())
                        }
                        return AnyView(
                            ShelfExpandedPreview(
                                preparedPreview: preparedPreview,
                                maxWidth: ClipboardSidePanelMetrics.previewMaxWidth,
                                onDismiss: {
                                    dismissPreparedPreview()
                                },
                                onMove: moveSelection,
                                onTextInput: beginSearch
                            )
                        )
                    },
                    dragItemProvider: { item in
                        PinboardItemDragPayload.itemProvider(
                            for: item,
                            hydrate: store.hydratedItem
                        )
                    },
                    onSelect: { id in
                        guard let item = renderedItems.first(where: { $0.id == id }) else { return }
                        selectItem(item)
                    },
                    onDoubleClick: { id in
                        guard let item = renderedItems.first(where: { $0.id == id }) else { return }
                        pasteItem(item, format: store.defaultPasteFormat)
                    },
                    onLastItemAppear: {
                        loadNextSidePage()
                    }
                )
            }

        }
        .padding(.vertical, 10)
    }

    private var queryState: ClipboardSidePanelQueryState {
        ClipboardSidePanelQueryState(
            dataRevision: store.dataRevision,
            queryRevision: store.queryRevision,
            scope: sideScope,
            searchQuery: store.searchQuery,
            contentTypeFilter: store.contentTypeFilter,
            sourceAppFilter: store.sourceAppFilter,
            deviceFilter: store.deviceFilter,
            dateFilter: store.dateFilter,
            pasteStackRevision: store.pasteStackItems.count
        )
    }

    private var renderedItems: [ClipboardItem] {
        ClipboardPanelHistoryAvailability.visibleItems(
            paging.items,
            scope: sideScope,
            errorMessage: store.historyQueryErrorMessage
        )
    }

    private var selectedItemsInDisplayOrder: [ClipboardItem] {
        let ids = interaction.selectedIDs
        guard !ids.isEmpty else {
            return interaction.primarySelectedID.flatMap { id in renderedItems.first { $0.id == id } }.map { [$0] } ?? []
        }
        return renderedItems.filter { ids.contains($0.id) }
    }

    private var effectivePinned: Bool {
        pinnedState ?? isPinned
    }

    private func setPinned(_ value: Bool) {
        pinnedState = value
        isPinned = value
    }

    private var hasSearchText: Bool {
        !store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sourceAppSuggestions: [String] {
        store.sourceAppSuggestions(matching: store.searchQuery, limit: 3)
    }

    private var shouldShowSourceAppSuggestions: Bool {
        isSearchFocused
            && hasSearchText
            && !sourceAppSuggestions.isEmpty
    }

    private var emptyTitle: String {
        if sideScope != .pasteStack, let error = store.historyQueryErrorMessage {
            return error
        }
        return sideScope == .pasteStack ? localized("action.paste_stack_is_empty") : localized("label.no_clipboard_items")
    }

    private var emptySystemImage: String {
        if sideScope != .pasteStack, store.historyQueryErrorMessage != nil {
            return "exclamationmark.triangle"
        }
        return sideScope == .pasteStack ? "tray" : "doc.on.clipboard"
    }

    private var emptyDescription: String {
        if sideScope != .pasteStack, store.historyQueryErrorMessage != nil {
            return ""
        }
        if sideScope == .pasteStack {
            return store.isPasteStackActive ? localized("message.new_copies_will_appear_here") : localized("message.start_collecting_copied_items")
        }
        return localized("message.copy_text_links_images_or_files_to")
    }

    private func refreshSideItems() {
        let queryID = queryState
        let items = store.filteredItemsPage(for: sideScope, offset: 0)
        paging.reset(
            with: items,
            totalCount: store.filteredItemCount(for: sideScope),
            queryID: queryID
        )
        interaction.replaceItems(
            items,
            storeSelectedIDs: store.selectedItemIDs,
            storePrimarySelectedID: store.selectedItemID
        )
    }

    private func loadNextSidePage() {
        guard paging.canLoadMore else { return }
        let queryID = queryState
        guard let request = paging.nextPageRequest(for: queryID) else { return }
        let page = store.filteredItemsPage(
            for: sideScope,
            offset: request.offset
        )
        guard !page.isEmpty else { return }
        guard paging.append(
            page,
            totalCount: store.filteredItemCount(for: sideScope),
            for: request,
            currentQueryID: queryState
        ) else { return }
        interaction.replaceItems(
            paging.items,
            storeSelectedIDs: store.selectedItemIDs,
            storePrimarySelectedID: store.selectedItemID
        )
    }

    private func setSideScope(_ scope: PasteScope) {
        if sideScope != scope {
            dismissPreparedPreview()
            sideScope = scope
        }
    }

    private func cyclePinboard(_ direction: PinboardCycleDirection) {
        guard let destination = PinboardCycleSelection.destination(
            from: sideScope,
            pinboardIDs: store.userPinboards.map(\.id),
            direction: direction
        ) else { return }
        dismissPreparedPreview()
        sideScope = destination
    }

    private func isSmartCategorySelected(_ category: SmartPinboardCategory) -> Bool {
        guard let pinboard = store.smartPinboard(for: category) else { return false }
        return sideScope == .pinboard(pinboard.id)
    }

    private func selectSmartCategory(_ category: SmartPinboardCategory) {
        let pinboard = store.syncSmartPinboard(for: category)
        setSideScope(.pinboard(pinboard.id))
    }

    private func reorderCollection(
        _ source: ClipboardCollectionID,
        relativeTo target: ClipboardCollectionID,
        afterTarget: Bool
    ) -> Bool {
        store.moveCollection(source, relativeTo: target, afterTarget: afterTarget)
    }

    private func moveCollection(
        _ collection: ClipboardCollectionID,
        in visibleOrder: [ClipboardCollectionID],
        by offset: Int
    ) {
        guard let sourceIndex = visibleOrder.firstIndex(of: collection) else { return }
        let destinationIndex = sourceIndex + offset
        guard visibleOrder.indices.contains(destinationIndex) else { return }
        _ = store.moveCollection(
            collection,
            relativeTo: visibleOrder[destinationIndex],
            afterTarget: offset > 0
        )
    }

    private func selectItem(_ item: ClipboardItem) {
        PasteBuddyMotion.performInstantSelection {
            interaction.select(item.id)
        }
        store.selectSingleItem(item.id)
        setSearchFocused(false)
    }

    private func selectSingleItem(_ id: UUID?, keepsPreviewOpen: Bool = false) {
        PasteBuddyMotion.performInstantSelection {
            interaction.selectSingle(id, keepsPreviewOpen: keepsPreviewOpen)
        }
        store.selectSingleItem(id)
    }

    private func setSearchFocused(_ isFocused: Bool) {
        isSearchFocused = isFocused
        isListFocused = !isFocused
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        switch direction {
        case .up, .left:
            selectOffset(-1)
        case .down, .right:
            selectOffset(1)
        @unknown default:
            break
        }
    }

    private func selectOffset(_ offset: Int) {
        let items = renderedItems
        guard !items.isEmpty else { return }
        let keepsPreviewOpen = interaction.previewedID != nil
        let currentID = interaction.primarySelectedID ?? interaction.selectedIDs.first
        let currentIndex = currentID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        let nextIndex = min(max(currentIndex + offset, items.startIndex), items.index(before: items.endIndex))
        let nextItem = items[nextIndex]
        selectSingleItem(nextItem.id)
        if keepsPreviewOpen {
            prepareAndPresentPreview(for: nextItem)
        }
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        let modifiers = keyPress.modifiers

        if keyPress.key == .space, modifiers.isEmpty, !isSearchFocused {
            toggleSelectedItemPreview()
            return .handled
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
               ClipboardPanelHistoryAvailability.allowsActions(
                   scope: sideScope,
                   errorMessage: store.historyQueryErrorMessage
               ),
               let item = store.quickPasteItem(atOneBasedIndex: index, in: sideScope) {
                pasteItem(item, format: store.defaultPasteFormat)
                return .handled
            }
        }

        if ClipboardPanelSearchInput.accepts(modifiers), !isSearchFocused, beginSearch(with: keyPress.characters) {
            return .handled
        }

        return .ignored
    }

    private func handlePanelArrowKey(_ request: ClipboardPanelArrowKeyRequest) {
        guard !isSearchFocused, interaction.previewedID == nil else { return }
        if request.command.extendsSelection {
            interaction.extendSelection(by: request.command.offset)
            store.setSelectedItemIDs(
                interaction.selectedIDs,
                primaryID: interaction.primarySelectedID,
                in: sideScope
            )
        } else {
            selectOffset(request.command.offset)
        }
        request.markHandled()
    }

    private func beginSearch(with characters: String) -> Bool {
        guard ClipboardPanelSearchInput.accepts(characters) else { return false }
        dismissPreparedPreview()
        store.searchQuery += characters
        setSearchFocused(true)
        return true
    }

    private func toggleSelectedItemPreview() {
        guard let item = selectedItemsInDisplayOrder.first else { return }
        setSearchFocused(false)
        if interaction.previewedID == item.id {
            dismissPreparedPreview()
        } else {
            selectSingleItem(item.id)
            prepareAndPresentPreview(for: item)
        }
    }

    private func prepareAndPresentPreview(for item: ClipboardItem) {
        dismissPreparedPreview()
        let requestID = UUID()
        previewRequestID = requestID
        Task { @MainActor in
            let prepared = await ClipboardPreparedPreview.prepare(
                item: item,
                hydrateItem: store.hydratedItem
            )
            guard !Task.isCancelled,
                  prepared.canPresent(
                    requestID: requestID,
                    currentRequestID: previewRequestID,
                    selectedItemID: interaction.primarySelectedID
                  ) else { return }
            preparedPreview = prepared
            interaction.presentPreview(for: item.id)
        }
    }

    private func dismissPreparedPreview(for id: UUID? = nil) {
        guard id == nil || interaction.previewedID == id else { return }
        interaction.dismissPreview(for: id)
        previewRequestID = nil
        preparedPreview = nil
    }

    private func pasteSelected(format: PasteFormat) {
        let items = selectedItemsInDisplayOrder
        guard !items.isEmpty else { return }
        let shouldDismissBeforePaste = !effectivePinned
        let request = ClipboardPanelPasteGate.begin()
        Task { @MainActor in
            let result: DirectPasteResult? = await ClipboardShelfDirectPasteCoordinator.runAfterImmediateDismissal(
                dismissBeforePaste: shouldDismissBeforePaste,
                dismiss: onDismissImmediately
            ) {
                let hydratedItems = await store.hydratedItems(for: items)
                guard ClipboardPanelPasteGate.shouldPaste(request) else { return nil }
                return await directPasteItems(hydratedItems, format)
            }
            if let result {
                store.recordDirectPasteResult(result)
            }
        }
    }

    private func pasteItem(_ item: ClipboardItem, format: PasteFormat) {
        selectSingleItem(item.id)
        let shouldDismissBeforePaste = !effectivePinned
        let request = ClipboardPanelPasteGate.begin()
        Task { @MainActor in
            let result: DirectPasteResult? = await ClipboardShelfDirectPasteCoordinator.runAfterImmediateDismissal(
                dismissBeforePaste: shouldDismissBeforePaste,
                dismiss: onDismissImmediately
            ) {
                let hydratedItem = await store.hydratedItem(for: item)
                guard ClipboardPanelPasteGate.shouldPaste(request) else { return nil }
                return await directPasteItem(hydratedItem, format)
            }
            if let result {
                store.recordDirectPasteResult(result)
            }
        }
    }

    private func copyItem(_ item: ClipboardItem, format: PasteFormat) {
        let sourceWindow = NSApp.keyWindow
        Task { @MainActor in
            let hydratedItem = await store.hydratedItem(for: item)
            ClipboardPanelCopyCoordinator.copy(
                hydratedItem,
                format: format,
                sourceWindow: sourceWindow
            )
        }
    }

    private func copySelectedItems() {
        let items = selectedItemsInDisplayOrder
        guard !items.isEmpty else { return }
        let sourceWindow = NSApp.keyWindow
        let request = ClipboardPanelCopyGate.begin()
        Task { @MainActor in
            let hydratedItems = await store.hydratedItems(for: items)
            guard ClipboardPanelCopyGate.shouldWrite(request) else { return }
            ClipboardPanelCopyCoordinator.copy(hydratedItems, sourceWindow: sourceWindow)
        }
    }

    private func handleExitCommand() {
        if isSearchFocused {
            if store.sourceAppFilter != nil {
                store.clearSourceAppFilter()
                refreshSideItems()
                setSearchFocused(true)
                return
            }
            if !store.searchQuery.isEmpty {
                store.searchQuery = ""
                refreshSideItems()
            }
            setSearchFocused(false)
            return
        }
        if interaction.previewedID != nil {
            dismissPreparedPreview()
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

}

private struct ClipboardSidePanelListRow: View {
    let item: ClipboardItem
    let imageDataProvider: @MainActor (ClipboardItem) async -> Data?
    let linkMetadataProvider: @MainActor (ClipboardItem) async -> Void
    let isSelected: Bool
    let timestampReference: Date
    let defaultPasteFormat: PasteFormat
    let onPaste: (PasteFormat) -> Void
    let onCopy: (PasteFormat) -> Void
    let onPin: (UUID) -> Void
    let onScreenPin: () -> Void
    let isExcludedFromAISearch: Bool
    let onToggleAISearchIndex: () -> Void
    let onDelete: () -> Void
    let pinboards: [Pinboard]

    var body: some View {
        let formatter = HistoryCardTimestampFormatter(
            now: { timestampReference }
        )
        let timestamp = HistoryCardTimestampAdapter.presentation(
            for: item.createdAt,
            formatter: formatter
        )

        HStack(spacing: 12) {
            SourceApplicationIconBadge(item: item, size: ClipboardSidePanelMetrics.thumbnailSize)
                .frame(width: ClipboardSidePanelMetrics.thumbnailSize, height: ClipboardSidePanelMetrics.thumbnailSize)

            ClipboardSidePanelContentPreview(
                item: item,
                imageDataProvider: imageDataProvider,
                linkMetadataProvider: linkMetadataProvider
            )

            Spacer(minLength: 8)

            Text(timestamp.visibleText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .layoutPriority(1)

            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: ClipboardSidePanelMetrics.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(isSelected ? 0.82 : 0.44))
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.90) : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
        }
        .contextMenu {
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
            Button("action.pin_to_screen") {
                onScreenPin()
            }
            Menu("action.pin") {
                ForEach(pinboards) { pinboard in
                    Button(pinboard.name) {
                        onPin(pinboard.id)
                    }
                }
            }
            Button(
                isExcludedFromAISearch
                    ? LocalizedStringKey("action.add_to_ai_search")
                    : LocalizedStringKey("action.remove_from_ai_search")
            ) {
                onToggleAISearchIndex()
            }
            Button("action.delete", role: .destructive) {
                onDelete()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("clipboard-side-panel-row-\(item.id.uuidString)")
        .accessibilityLabel(
            "\(item.title), \(NSLocalizedString(item.presentationContentType.displayName, comment: "")), \(timestamp.accessibilityText)"
        )
        .accessibilityValue(NSLocalizedString(isSelected ? "state.selected" : "label.not_selected", comment: ""))
        .accessibilityHint(NSLocalizedString("message.press_space_to_preview_press_return_to", comment: ""))
    }

}

private struct ClipboardSidePanelContentPreview: View {
    let item: ClipboardItem
    let imageDataProvider: @MainActor (ClipboardItem) async -> Data?
    let linkMetadataProvider: @MainActor (ClipboardItem) async -> Void

    var body: some View {
        if item.presentationContentType == .image, item.payload.hasImageAsset {
            ClipboardSidePanelImagePreview(item: item, imageDataProvider: imageDataProvider)
        } else {
            HStack(spacing: 10) {
                if item.presentationContentType == .url, item.visualPreview.prefersImageThumbnail {
                    ClipboardSidePanelImagePreview(item: item, imageDataProvider: imageDataProvider)
                }
                Text(primaryText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task(id: item.id) {
                guard item.presentationContentType == .url,
                      !item.visualPreview.prefersImageThumbnail else { return }
                await linkMetadataProvider(item)
            }
        }
    }

    private var primaryText: String {
        (item.presentationContentType == .url ? nonEmpty(item.visualPreview.headline) : nil)
            ?? nonEmpty(item.visualPreview.body)
            ?? nonEmpty(item.summary)
            ?? NSLocalizedString(item.presentationContentType.displayName, comment: "")
    }

    private func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct ClipboardSidePanelImagePreview: View {
    let item: ClipboardItem
    let imageDataProvider: @MainActor (ClipboardItem) async -> Data?

    var body: some View {
        let previewSize = ClipboardImageCache.fittedDisplaySize(
            for: ClipboardImageCache.imageSize(for: item),
            within: CGSize(width: 72, height: 54)
        )

        ClipboardImageThumbnailView(
            item: item,
            imageDataProvider: imageDataProvider,
            tint: item.presentationContentType.shelfTint,
            contentMode: .fit,
            placeholderIconSize: 18
        )
        .frame(width: previewSize.width, height: previewSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
        }
    }
}
