import AppKit
import Carbon
import PasteBuddyCore
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

private enum ClipboardShelfMetrics {
    static let cardWidth: CGFloat = 240
    static let cardHeight: CGFloat = 240
    static let cardHeaderHeight: CGFloat = 58
    static let cardPreviewHeight: CGFloat = 126
    static let cardCornerRadius: CGFloat = 17
    static let searchIdleWidth: CGFloat = 208
    static let searchFocusedWidth: CGFloat = 272
    static let searchFilteredWidth: CGFloat = 310
    static let sourceAppSuggestionWidth: CGFloat = 168
    static let shelfVerticalPadding: CGFloat = 6
    static let shelfHeight: CGFloat = cardHeight + shelfVerticalPadding * 2
    static let renderLimit = 200
}

enum ClipboardShelfGlass {
    static let defaultTintOpacity = 0.30
    static let detailSuppressionOpacity = 0.28
}

private struct ClipboardShelfQueryState: Equatable {
    let dataRevision: Int
    let queryRevision: Int
    let shelfScope: PasteScope
    let searchQuery: String
    let contentTypeFilter: ClipboardContentType?
    let sourceAppFilter: String?
    let deviceFilter: String?
    let dateFilter: ClipboardDateFilter
    let pasteStackRevision: Int
}

private enum ClipboardShelfDisplayItem: Identifiable {
    case launchAtLoginPrompt
    case empty(title: String, detail: String, systemImageName: String)
    case clipboard(ClipboardItem)
    case overflow(shownCount: Int, remainingCount: Int)

    var id: UUID {
        switch self {
        case .launchAtLoginPrompt:
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        case .empty:
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        case .clipboard(let item):
            item.id
        case .overflow:
            UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        }
    }
}

enum ClipboardPanelSearchInput {
    static func accepts(_ modifiers: SwiftUI.EventModifiers) -> Bool {
        modifiers.subtracting([.shift, .capsLock]).isEmpty
    }

    static func accepts(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        let deviceModifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        return deviceModifiers.isEmpty || deviceModifiers.subtracting([.shift, .capsLock]).isEmpty
    }

    static func accepts(_ characters: String) -> Bool {
        guard !characters.isEmpty else { return false }
        guard characters.rangeOfCharacter(from: .newlines) == nil else { return false }
        return characters.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

struct ClipboardShelfPanelView: View {
    private static let basePasteSearchAnimation = Animation.smooth(duration: 0.24, extraBounce: 0)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var store: PasteBuddyStore
    let directPasteItem: @MainActor (ClipboardItem, PasteFormat) async -> DirectPasteResult
    let directPasteItems: @MainActor ([ClipboardItem], PasteFormat) async -> DirectPasteResult
    let reloadClipboardHistory: @MainActor () async -> Void
    let onDismiss: () -> Void
    let onDismissImmediately: () -> Void

    @FocusState private var isSearchFocused: Bool
    @FocusState private var isShelfFocused: Bool
    @State private var isShowingNewTextItem = false
    @State private var isShowingLaunchAtLoginPrompt = false
    @State private var shelfItems: [ClipboardItem] = []
    @State private var shelfOverflowCount = 0
    @State private var shelfInteraction = ShelfInteractionModel()
    @State private var selectionSyncTask: Task<Void, Never>?
    @State private var isSearchRailPresented = false
    @State private var relativeDateReference = Date()
    @State private var shelfScope: PasteScope = .history

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
        .onAppear {
            store.searchQuery = ""
            store.clearFilters()
            shelfScope = store.selectedScope
            refreshShelfItems()
            isSearchRailPresented = true
            Task { @MainActor in
                await Task.yield()
                setSearchFocused(false)
            }
        }
        .onDisappear {
            selectionSyncTask?.cancel()
            selectionSyncTask = nil
            isSearchRailPresented = false
        }
        .onChange(of: shelfQueryState) {
            refreshShelfItems()
        }
        .onChange(of: store.searchQuery) {
            shelfInteraction.dismissPreview()
        }
        .onMoveCommand(perform: moveSelection)
        .onExitCommand(perform: handleExitCommand)
        .focusable(true)
        .focused($isShelfFocused)
        .onKeyPress(phases: .down) { keyPress in
            handleShelfKeyPress(keyPress, allowsPreview: true)
        }
        .task {
            await runShelfMinuteTicker()
        }
        .sheet(isPresented: $isShowingNewTextItem) {
            NewTextItemSheet { title, text in
                guard store.createTextItem(text: text, title: title) != nil else {
                    return store.lastErrorMessage ?? "PasteBuddy could not create this item."
                }
                isShowingNewTextItem = false
                return nil
            } onCancel: {
                isShowingNewTextItem = false
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("label.pastebuddy_clipboard_shelf"))
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
                        isShowingNewTextItem = true
                    } label: {
                        Label("label.new_text_item", systemImage: "square.and.pencil")
                    }
                    .keyboardShortcut("n", modifiers: [.command])

                    Button {
                        let pinboard = store.createPinboard()
                        setScope(.pinboard(pinboard.id))
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
                    refreshShelfItems()
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
                    refreshShelfItems()
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
                    refreshShelfItems()
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
        ClipboardCollectionStrip(store: store, selectedScope: shelfScope) { scope in
            setScope(scope)
        }
    }

    private var selectedCount: Int {
        selectedItemsInDisplayOrder.count
    }

    private var renderedShelfItems: [ClipboardItem] {
        Array(shelfItems.prefix(ClipboardShelfMetrics.renderLimit))
    }

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
        if shelfOverflowCount > 0 {
            items.append(.overflow(shownCount: renderedShelfItems.count, remainingCount: shelfOverflowCount))
        }
        return items
    }

    private var shelfQueryState: ClipboardShelfQueryState {
        ClipboardShelfQueryState(
            dataRevision: store.dataRevision,
            queryRevision: store.queryRevision,
            shelfScope: shelfScope,
            searchQuery: store.searchQuery,
            contentTypeFilter: store.contentTypeFilter,
            sourceAppFilter: store.sourceAppFilter,
            deviceFilter: store.deviceFilter,
            dateFilter: store.dateFilter,
            pasteStackRevision: store.pasteStackItems.count
        )
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
        .scrollIndicators(.hidden)
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

        return ShelfCollectionRepresentable(
            items: shelfDisplayItems,
            selectedIDs: shelfInteraction.selectedIDs,
            primarySelectedID: shelfInteraction.primarySelectedID,
            itemSize: CGSize(width: ClipboardShelfMetrics.cardWidth, height: ClipboardShelfMetrics.shelfHeight),
            interitemSpacing: 20,
            contentRevision: store.dataRevision &+ store.queryRevision &+ shelfOverflowCount &+ relativeDateMinuteBucket,
            previewedID: shelfInteraction.previewedID,
            onPreviewDismiss: {
                shelfInteraction.dismissPreview()
            },
            previewPreferredEdge: .maxY,
            previewContent: { displayItem in
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
        } onSelect: { id, modifiers in
            guard let item = renderedShelfItems.first(where: { $0.id == id }) else { return }
            selectItem(item, modifiers: modifiers)
        } onDoubleClick: { id in
            guard let item = renderedShelfItems.first(where: { $0.id == id }) else { return }
            pasteItem(item, format: defaultPasteFormat)
        } pasteboardWriter: { displayItem in
            pasteboardWriter(for: displayItem)
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
            case .clipboard(let item):
                ClipboardShelfCard(
                    item: item,
                    imageDataProvider: store.imageData,
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
            case .overflow(let shownCount, let remainingCount):
                VStack {
                    Spacer(minLength: 0)
                    ShelfOverflowStatusCard(
                        shownCount: shownCount,
                        remainingCount: remainingCount
                    )
                }
                .frame(width: ClipboardShelfMetrics.cardWidth, height: ClipboardShelfMetrics.shelfHeight, alignment: .bottom)
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
        shelfScope = scope
    }

    private func syncSmartPinboardsAndShowFirst() {
        let pinboards = store.syncSmartPinboards()
        if let firstPinboardID = pinboards.first?.id {
            setScope(.pinboard(firstPinboardID))
        }
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
        refreshShelfItems()
    }

    private func selectItem(_ item: ClipboardItem, modifiers: NSEvent.ModifierFlags) {
        PasteBuddyMotion.performInstantSelection {
            shelfInteraction.select(item.id, modifiers: modifiers)
        }
        scheduleStoreSelectionSync(
            primaryID: shelfInteraction.primarySelectedID,
            ids: shelfInteraction.selectedIDs
        )
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
            await reloadClipboardHistory()
            refreshShelfItems()
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
        scheduleStoreSelectionSync(primaryID: shelfInteraction.primarySelectedID, ids: shelfInteraction.selectedIDs)
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

    private func scheduleStoreSelectionSync(primaryID: UUID?, ids: Set<UUID>) {
        selectionSyncTask?.cancel()
        let store = store
        selectionSyncTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 45_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            if ids.count == 1 {
                store.selectSingleItem(primaryID)
            } else {
                store.setSelectedItemIDs(ids, in: shelfScope)
            }
        }
    }

    private func toggleSelectedItemPreview() {
        guard let item = selectedItemsInDisplayOrder.first else { return }
        setSearchFocused(false)
        if shelfInteraction.togglePreview(for: item.id) {
            selectSingleItem(item.id)
        }
    }

    private func handleExitCommand() {
        if isSearchFocused {
            if !store.searchQuery.isEmpty {
                store.searchQuery = ""
                refreshShelfItems()
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

    private func refreshShelfItems() {
        let items = store.filteredItems(for: shelfScope)
        shelfItems = items
        shelfOverflowCount = max(0, items.count - ClipboardShelfMetrics.renderLimit)

        let renderedItems = Array(items.prefix(ClipboardShelfMetrics.renderLimit))
        shelfInteraction.replaceItems(
            renderedItems,
            storeSelectedIDs: store.selectedItemIDs,
            storePrimarySelectedID: store.selectedItemID
        )

        if !storeSelectionMatches(primaryID: shelfInteraction.primarySelectedID, ids: shelfInteraction.selectedIDs) {
            scheduleStoreSelectionSync(
                primaryID: shelfInteraction.primarySelectedID,
                ids: shelfInteraction.selectedIDs
            )
        }
    }

    private func storeSelectionMatches(primaryID: UUID?, ids: Set<UUID>) -> Bool {
        if ids.count == 1 {
            return store.selectedItemIDs == ids && store.selectedItemID == primaryID
        }
        return store.selectedItemIDs == ids
    }

    private func pasteboardWriter(for displayItem: ClipboardShelfDisplayItem) -> NSPasteboardWriting? {
        guard case .clipboard(let item) = displayItem else { return nil }
        let pasteboardItem = NSPasteboardItem()
        if let payloadData = try? JSONEncoder().encode(PinboardItemDragPayload(ids: [item.id])) {
            pasteboardItem.setData(
                payloadData,
                forType: NSPasteboard.PasteboardType(UTType.pasteBuddyPinboardItemIDs.identifier)
            )
        }
        pasteboardItem.setString(PasteboardWriter.plainText(for: item), forType: .string)
        if let value = item.payload.presentationURLString {
            pasteboardItem.setString(value, forType: .URL)
        }
        if let value = item.payload.allFileURLStrings.first {
            pasteboardItem.setString(value, forType: .fileURL)
        }
        if let data = item.payload.imageData {
            pasteboardItem.setData(data, forType: .png)
        }
        return pasteboardItem
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

private struct ShelfOverflowStatusCard: View {
    let shownCount: Int
    let remainingCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 5) {
                Text(localized("format.showing_first_items", shownCount))
                    .font(.headline)
                    .lineLimit(2)
                Text(localized("format.refine_search_or_filters_to_see_more", remainingCount))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(20)
        .frame(width: 240, height: 230)
        .pasteBuddyGlassSurface(cornerRadius: 18, interactive: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(localized("format.showing_first_clipboard_items_refine_search_or", shownCount, remainingCount))
    }

    private func localized(_ key: String, _ arguments: CVarArg...) -> String {
        String(
            format: NSLocalizedString(key, comment: ""),
            locale: Locale.current,
            arguments: arguments
        )
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

struct ShelfExpandedPreview: View {
    private static let textPreviewHeight: CGFloat = 420

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
        .background {
            ShelfPreviewKeyboardHandler(onDismiss: onDismiss, onMove: onMove, onTextInput: onTextInput)
                .frame(width: 0, height: 0)
        }
        .onMoveCommand(perform: onMove)
        .onExitCommand(perform: onDismiss)
        .onKeyPress(phases: .down) { keyPress in
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
        ScrollView {
            Text(text.isEmpty ? item.visualPreview.body : text)
                .font(.system(size: 16, design: .monospaced))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(12)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}

private struct ShelfPreviewKeyboardHandler: NSViewRepresentable {
    let onDismiss: () -> Void
    let onMove: (MoveCommandDirection) -> Void
    let onTextInput: (String) -> Bool

    func makeNSView(context: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.onKeyDown = handleKeyDown
        return view
    }

    func updateNSView(_ nsView: KeyCatcherView, context: Context) {
        nsView.onKeyDown = handleKeyDown
        nsView.startMonitoring()
        nsView.focusSelf()
    }

    static func dismantleNSView(_ nsView: KeyCatcherView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard ClipboardPanelSearchInput.accepts(event.modifierFlags) else { return false }

        switch Int(event.keyCode) {
        case kVK_Space:
            onDismiss()
        case kVK_UpArrow:
            onMove(.up)
        case kVK_DownArrow:
            onMove(.down)
        case kVK_LeftArrow:
            onMove(.left)
        case kVK_RightArrow:
            onMove(.right)
        default:
            guard let characters = event.characters else { return false }
            return onTextInput(characters)
        }
        return true
    }

    final class KeyCatcherView: NSView {
        var onKeyDown: ((NSEvent) -> Bool)?
        private var keyMonitor: Any?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                stopMonitoring()
                return
            }
            startMonitoring()
            focusSelf()
        }

        func focusSelf() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        }

        func stopMonitoring() {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
        }

        func startMonitoring() {
            guard window != nil else { return }
            stopMonitoring()
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window else {
                    return event
                }
                return self.onKeyDown?(event) == true ? nil : event
            }
        }

        override func keyDown(with event: NSEvent) {
            if onKeyDown?(event) == true {
                return
            }
            super.keyDown(with: event)
        }
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
            fallbackImage = cachedImage

            let imageData = await imageDataProvider(item)

            if let imageData, let image = NSImage(data: imageData) {
                guard !Task.isCancelled else { return }
                liveTextImage = image
                fallbackImage = image
                return
            }

            guard cachedImage == nil else { return }
            let loadedImage = await ClipboardImageCache.thumbnail(
                for: item,
                imageData: imageData,
                maxPixelSize: maxPixelSize
            )
            guard !Task.isCancelled else { return }
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

private struct ClipboardShelfCardVisual: View {
    let item: ClipboardItem
    let imageDataProvider: @MainActor (ClipboardItem) async -> Data?
    let relativeDateReference: Date
    private let renderSignature: ClipboardShelfCardRenderSignature

    init(
        item: ClipboardItem,
        imageDataProvider: @escaping @MainActor (ClipboardItem) async -> Data?,
        relativeDateReference: Date
    ) {
        self.item = item
        self.imageDataProvider = imageDataProvider
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
            footer
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

        if preview.prefersImageThumbnail {
            ShelfThumbnailView(item: item, imageDataProvider: imageDataProvider, tint: cardTint)
        } else if item.presentationContentType == .url {
            ShelfLinkPreviewCardBody(preview: preview, tint: cardTint)
        } else {
            VStack(alignment: .leading, spacing: 9) {
                Text(preview.body)
                    .font(item.presentationContentType == .text ? .callout.monospaced() : .callout)
                    .foregroundStyle(.primary)
                    .lineLimit(footerTitle == nil ? 4 : 3)
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

    private var footer: some View {
        VStack(alignment: .leading, spacing: footerTitle == nil ? 0 : 4) {
            if let footerTitle {
                Text(footerTitle)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }
            HStack {
                Text(item.sourceAppName)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(footnote)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background {
            Rectangle()
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.95))
        }
        .background(.regularMaterial)
    }

    private func relativeDate(relativeTo date: Date) -> String {
        Self.relativeFormatter.localizedString(for: item.createdAt, relativeTo: date)
    }

    private var footerTitle: String? {
        let headline = item.visualPreview.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !headline.isEmpty else { return nil }

        switch item.presentationContentType {
        case .text:
            return nil
        case .url, .image, .file, .mixed:
            return headline
        }
    }

    private var footnote: String {
        switch item.presentationContentType {
        case .image:
            if let imageSize = ClipboardImageCache.imageSize(for: item) {
                return "\(Int(imageSize.width)) x \(Int(imageSize.height))"
            }
            return localized(item.ocrState.displayName)
        case .file:
            let count = item.payload.allFileURLStrings.count
            return localized(count == 1 ? "format.file" : "format.files", count)
        case .text, .url, .mixed:
            return localized("format.chars", presentationCharacterCount)
        }
    }

    private var presentationCharacterCount: Int {
        item.payload.text?.count
            ?? item.payload.urlString?.count
            ?? item.payload.ocrText?.count
            ?? item.searchDocument.normalizedText.count
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
    let ocrState: OCRState
    let previewHeadline: String
    let previewBody: String
    let previewSearchHash: String
    let textCount: Int?
    let htmlCount: Int?
    let rtfAssetID: String?
    let rtfByteCount: Int?
    let urlString: String?
    let fileURLString: String?
    let fileURLStrings: [String]
    let imageAssetID: String?
    let imageByteCount: Int?
    let ocrTextCount: Int?
    let relativeDateMinuteBucket: Int

    init(item: ClipboardItem, relativeDateReference: Date) {
        id = item.id
        createdAt = item.createdAt
        updatedAt = item.updatedAt
        sourceAppName = item.sourceAppName
        sourceBundleIdentifier = item.sourceBundleIdentifier
        contentType = item.contentType
        title = item.title
        ocrState = item.ocrState
        previewHeadline = item.searchDocument.previewHeadline
        previewBody = item.searchDocument.previewBody
        previewSearchHash = item.searchDocument.searchHash
        textCount = item.payload.text?.count
        htmlCount = item.payload.htmlString?.count
        rtfAssetID = item.payload.rtfAssetID
        rtfByteCount = item.payload.rtfData?.count ?? item.payload.rtfByteCount
        urlString = item.payload.urlString
        fileURLString = item.payload.fileURLString
        fileURLStrings = item.payload.fileURLStrings
        imageAssetID = item.payload.imageAssetID
        imageByteCount = item.payload.imageData?.count ?? item.payload.imageByteCount
        ocrTextCount = item.payload.ocrText?.count
        relativeDateMinuteBucket = Int(relativeDateReference.timeIntervalSinceReferenceDate / 60)
    }
}

private struct ShelfLinkPreviewCardBody: View {
    let preview: ClipboardVisualPreview
    let tint: Color

    var body: some View {
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
                    .fill(tint.opacity(0.10))
                Image(systemName: item.presentationContentType.systemImageName)
                    .font(.system(size: placeholderIconSize, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .task(id: ClipboardImageCache.thumbnailCacheKey(for: item)) {
            thumbnail = ClipboardImageCache.cachedThumbnail(for: item)
            guard thumbnail == nil else { return }

            let imageData = await imageDataProvider(item)
            let loadedThumbnail = await ClipboardImageCache.thumbnail(for: item, imageData: imageData)
            guard !Task.isCancelled else { return }
            thumbnail = loadedThumbnail
        }
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
    // Wrapper so failed lookups are cached too: an unresolvable source app
    // (uninstalled, synced from another device) must not re-run LaunchServices
    // and filesystem probes on every render pass.
    private final class CachedIconLookup {
        let image: NSImage?

        init(image: NSImage?) {
            self.image = image
        }
    }

    private static let cache = NSCache<NSString, CachedIconLookup>()
    private static var appLaunchObserver: NSObjectProtocol?

    static func icon(for item: ClipboardItem) -> NSImage? {
        if let bundleIdentifier = normalized(item.sourceBundleIdentifier),
           let image = cachedIcon(forKey: "bundle:\(bundleIdentifier)", lookup: {
               icon(forBundleIdentifier: bundleIdentifier)
           }) {
            return image
        }

        guard let appName = normalized(item.sourceAppName) else { return nil }
        return icon(forApplicationName: appName)
    }

    private static func cachedIcon(forKey key: String, lookup: () -> NSImage?) -> NSImage? {
        installAppLaunchObserverIfNeeded()
        let cacheKey = key as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached.image
        }
        let image = lookup()
        cache.setObject(CachedIconLookup(image: image), forKey: cacheKey)
        return image
    }

    // A newly launched app can turn a previously failed lookup into a hit, so
    // cached misses only stay valid until the running-application set grows.
    private static func installAppLaunchObserverIfNeeded() {
        guard appLaunchObserver == nil else { return }
        appLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                cache.removeAllObjects()
            }
        }
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

    private static func icon(forBundleIdentifier bundleIdentifier: String) -> NSImage? {
        if let image = runningApplicationIcon(bundleIdentifier: bundleIdentifier) {
            return image
        }

        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return icon(forApplicationURL: applicationURL)
    }

    static func icon(forApplicationName appName: String) -> NSImage? {
        guard let appName = normalized(appName) else { return nil }
        return cachedIcon(forKey: "name:\(appName.lowercased())", lookup: {
            resolveIcon(forApplicationName: appName)
        })
    }

    private static func resolveIcon(forApplicationName appName: String) -> NSImage? {
        if let image = runningApplicationIcon(appName: appName) {
            return image
        }

        let fileManager = FileManager.default
        let appFileName = appName.hasSuffix(".app") ? appName : "\(appName).app"

        for directory in applicationSearchDirectories {
            let candidate = directory.appendingPathComponent(appFileName, isDirectory: true)
            if fileManager.fileExists(atPath: candidate.path) {
                return icon(forApplicationURL: candidate)
            }
        }

        return nil
    }

    private static let applicationSearchDirectories: [URL] = {
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
    }()

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
