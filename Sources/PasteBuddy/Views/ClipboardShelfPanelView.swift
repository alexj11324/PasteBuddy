import AppKit
import PasteBuddyCore
import SwiftUI
import UniformTypeIdentifiers

private enum ClipboardShelfMetrics {
    static let cardWidth: CGFloat = 240
    static let cardHeight: CGFloat = 240
    static let cardHeaderHeight: CGFloat = 58
    static let cardPreviewHeight: CGFloat = 126
    static let cardCornerRadius: CGFloat = 17
    static let searchIdleWidth: CGFloat = 208
    static let searchFocusedWidth: CGFloat = 272
    static let searchFilteredWidth: CGFloat = 310
    static let sourceAppSuggestionWidth: CGFloat = 360
    static let shelfVerticalPadding: CGFloat = 6
    static let shelfHeight: CGFloat = cardHeight + shelfVerticalPadding * 2
    static let renderLimit = 200
}

struct ClipboardShelfPanelView: View {
    private static let pasteSearchAnimation = Animation.smooth(duration: 0.36, extraBounce: 0.09)

    @Bindable var store: PasteBuddyStore
    let directPasteItem: @MainActor (ClipboardItem, PasteFormat) async -> DirectPasteResult
    let directPasteItems: @MainActor ([ClipboardItem], PasteFormat) async -> DirectPasteResult
    let reloadClipboardHistory: @MainActor () async -> Void
    let onDismiss: () -> Void
    let onDismissImmediately: () -> Void

    @FocusState private var isSearchFocused: Bool
    @State private var isShowingNewTextItem = false
    @State private var isShowingLaunchAtLoginPrompt = false
    @State private var shelfItems: [ClipboardItem] = []
    @State private var selectionAnchorID: UUID?
    @State private var selectedItemID: UUID?
    @State private var selectedItemIDs: Set<UUID> = []
    @State private var selectionSyncTask: Task<Void, Never>?
    @State private var isShelfSelectionUserOwned = false
    @State private var previewedItemID: UUID?
    @State private var isSearchRailPresented = false

    var body: some View {
        VStack(spacing: 12) {
            toolbar
            shelf
        }
        .padding(.top, 12)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .pasteBuddyBottomSheetSurface(cornerRadius: 28, showsStroke: false)
        .background(Color.clear)
        .onAppear {
            refreshShelfItems()
            isSearchRailPresented = false
            Task { @MainActor in
                await Task.yield()
                withAnimation(Self.pasteSearchAnimation) {
                    isSearchRailPresented = true
                    isSearchFocused = true
                }
            }
        }
        .onDisappear {
            selectionSyncTask?.cancel()
            selectionSyncTask = nil
            isSearchRailPresented = false
        }
        .onChange(of: store.presentationRevision) {
            refreshShelfItems()
        }
        .onMoveCommand(perform: moveSelection)
        .onExitCommand(perform: handleExitCommand)
        .background {
            ZStack {
                keyboardShortcuts
                ShelfSpaceKeyMonitor(isEnabled: !isSearchFocused) {
                    previewSelectedItem()
                }
            }
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
        .accessibilityLabel(localized("PasteBuddy clipboard shelf"))
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                searchControl
                    .layoutPriority(3)
                    .zIndex(20)

                sourceAppSuggestionRail
                    .layoutPriority(2)
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
                        Label("New Text Item", systemImage: "square.and.pencil")
                    }
                    .keyboardShortcut("n", modifiers: [.command])

                    Button {
                        let pinboard = store.createPinboard()
                        setScope(.pinboard(pinboard.id))
                    } label: {
                        Label("New Pinboard", systemImage: "plus.rectangle.on.folder")
                    }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .labelStyle(.iconOnly)
                .font(.title3.weight(.medium))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 38)
                .contentShape(Rectangle())
                .help(localized("Add item or pinboard"))

                Menu {
                    filtersMenu
                    Divider()
                    Button {
                        reloadHistory()
                    } label: {
                        Label("Reload clipboard history", systemImage: "arrow.clockwise")
                    }

                    Button {
                        store.toggleCapturePaused()
                    } label: {
                        Label(
                            localized(store.isCapturePaused ? "Resume Capture" : "Pause Capture"),
                            systemImage: store.isCapturePaused ? "play.fill" : "pause.fill"
                        )
                    }
                    .keyboardShortcut("t", modifiers: [.command])

                    Button {
                        store.undoLastDeletion()
                    } label: {
                        Label("Undo Delete", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!store.canUndoDelete)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .buttonStyle(.plain)
                .labelStyle(.iconOnly)
                .font(.title3.weight(.medium))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 38)
                .contentShape(Rectangle())
                .help(localized("More actions"))
            }
            .controlSize(.large)
            .animation(Self.pasteSearchAnimation, value: isSearchRailPresented)
            .animation(Self.pasteSearchAnimation, value: isSearchFocused)
            .animation(Self.pasteSearchAnimation, value: shouldShowSourceAppSuggestions)
            .animation(Self.pasteSearchAnimation, value: store.sourceAppFilter)
            .animation(Self.pasteSearchAnimation, value: selectedCount)

            if !visibleActiveFilterSummaries.isEmpty {
                activeFilterStrip
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Self.pasteSearchAnimation, value: visibleActiveFilterSummaries.count)
    }

    private var searchControl: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .scaleEffect(isSearchFocused ? 1.04 : 1.0)

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

            TextField("Search or @App", text: $store.searchQuery)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .frame(minWidth: 48)
                .onSubmit {
                    pasteSelected(format: store.defaultPasteFormat)
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: searchControlWidth, height: 38)
        .pasteBuddyGlassSurface(cornerRadius: 19, interactive: true)
        .overlay {
            Capsule()
                .strokeBorder(.primary.opacity(isSearchFocused ? 0.18 : 0.08), lineWidth: 1)
                .opacity(isSearchRailPresented ? 1 : 0)
        }
        .shadow(color: .black.opacity(isSearchFocused ? 0.12 : 0.06), radius: isSearchFocused ? 12 : 7, y: isSearchFocused ? 3 : 2)
        .scaleEffect(isSearchRailPresented ? 1 : 0.93, anchor: .leading)
        .offset(x: isSearchRailPresented ? 0 : -14, y: isSearchRailPresented ? 0 : 4)
        .opacity(isSearchRailPresented ? 1 : 0)
        .animation(Self.pasteSearchAnimation, value: searchControlWidth)
        .animation(Self.pasteSearchAnimation, value: isSearchRailPresented)
        .animation(Self.pasteSearchAnimation, value: isSearchFocused)
        .animation(Self.pasteSearchAnimation, value: store.sourceAppFilter)
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
        return ClipboardShelfMetrics.searchIdleWidth
    }

    private var hasSearchText: Bool {
        !store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sourceAppSuggestions: [String] {
        store.sourceAppSuggestions(matching: store.searchQuery, limit: 5)
    }

    private var sourceAppSuggestionStrip: some View {
        ShelfSourceAppSuggestionStrip(appNames: sourceAppSuggestions) { appName in
            store.applySourceAppSuggestion(appName)
            refreshShelfItems()
            setSearchFocused(true)
        }
        .frame(maxWidth: 360)
    }

    private var sourceAppSuggestionRail: some View {
        sourceAppSuggestionStrip
            .frame(width: sourceAppSuggestionRailWidth, height: 38, alignment: .leading)
            .opacity(shouldShowSourceAppSuggestions ? 1 : 0)
            .scaleEffect(shouldShowSourceAppSuggestions ? 1 : 0.96, anchor: .leading)
            .clipped()
            .allowsHitTesting(shouldShowSourceAppSuggestions)
            .accessibilityHidden(!shouldShowSourceAppSuggestions)
            .animation(Self.pasteSearchAnimation, value: sourceAppSuggestionRailWidth)
            .animation(Self.pasteSearchAnimation, value: shouldShowSourceAppSuggestions)
    }

    private var sourceAppSuggestionRailWidth: CGFloat {
        shouldShowSourceAppSuggestions ? ClipboardShelfMetrics.sourceAppSuggestionWidth : 0
    }

    private var shouldShowSourceAppSuggestions: Bool {
        isSearchFocused
            && store.sourceAppFilter == nil
            && !store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sourceAppSuggestions.isEmpty
    }

    private var visibleActiveFilterSummaries: [ClipboardFilterDescriptor] {
        store.activeFilterSummaries.filter { descriptor in
            !(descriptor.kind == .sourceApp && store.sourceAppFilter != nil)
        }
    }

    private var collectionStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ShelfCollectionChip(
                    title: localized("Clipboard"),
                    systemImageName: "clock.arrow.circlepath",
                    color: store.isCapturePaused ? .orange : .blue,
                    isSelected: store.selectedScope == .history
                ) {
                    setScope(.history)
                }

                ShelfCollectionChip(
                    title: localized("Paste Stack"),
                    count: store.pasteStackItems.count,
                    systemImageName: store.isPasteStackActive ? "tray.full.fill" : "tray",
                    color: store.isPasteStackActive ? .green : .secondary,
                    isSelected: store.selectedScope == .pasteStack
                ) {
                    setScope(.pasteStack)
                }

                ForEach(store.snapshot.pinboards) { pinboard in
                    ShelfCollectionChip(
                        title: pinboard.name,
                        count: pinboard.itemIDs.count,
                        systemImageName: "pin.fill",
                        color: Color(hex: pinboard.colorHex) ?? .blue,
                        isSelected: store.selectedScope == .pinboard(pinboard.id)
                    ) {
                        setScope(.pinboard(pinboard.id))
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("Clipboard collections"))
    }

    private var selectedCount: Int {
        selectedItemsInDisplayOrder.count
    }

    private var renderedShelfItems: [ClipboardItem] {
        Array(shelfItems.prefix(ClipboardShelfMetrics.renderLimit))
    }

    private var activeFilterStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Label("Active clipboard filters", systemImage: "line.3.horizontal.decrease.circle")
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
                    .help(localized("Remove clipboard filter"))
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var filtersMenu: some View {
        Menu("Filters") {
            Picker("Type", selection: $store.contentTypeFilter) {
                Text("Any Type").tag(nil as ClipboardContentType?)
                ForEach(ClipboardContentType.allCases) { type in
                    Text(localized(type.displayName)).tag(Optional(type))
                }
            }

            Picker("App", selection: $store.sourceAppFilter) {
                Text("Any App").tag(nil as String?)
                ForEach(store.availableSourceApps, id: \.self) { appName in
                    Text(appName).tag(Optional(appName))
                }
            }

            Picker("Device", selection: $store.deviceFilter) {
                Text("Any Device").tag(nil as String?)
                ForEach(store.availableDevices, id: \.self) { deviceName in
                    Text(deviceName).tag(Optional(deviceName))
                }
            }

            Picker("Date", selection: $store.dateFilter) {
                ForEach(ClipboardDateFilter.allCases) { filter in
                    Text(localized(filter.displayName)).tag(filter)
                }
            }

            Button("Clear Filters") {
                store.clearFilters()
            }
            .disabled(!store.hasActiveFilters)
        }
    }

    private var shelf: some View {
        let items = shelfItems
        let renderedItems = renderedShelfItems
        let overflowCount = max(0, items.count - renderedItems.count)
        let currentSelectedItemID = selectedItemID
        let currentSelectedItemIDs = selectedItemIDs
        let pinboards = store.snapshot.pinboards
        let defaultPasteFormat = store.defaultPasteFormat

        return ScrollView(.horizontal) {
            LazyHStack(alignment: .bottom, spacing: 20) {
                if isShowingLaunchAtLoginPrompt {
                    LaunchAtLoginShelfCard(store: store) {
                        isShowingLaunchAtLoginPrompt = false
                    }
                }

                if items.isEmpty {
                    EmptyShelfCard(
                        title: emptyTitle,
                        detail: emptyDescription,
                        systemImageName: emptySystemImage
                    )
                } else {
                    ForEach(renderedItems) { item in
                        ClipboardShelfCard(
                            item: item,
                            imageDataProvider: store.imageData,
                            draggedItems: draggableItems(for: item),
                            isSelected: currentSelectedItemIDs.contains(item.id) || currentSelectedItemID == item.id,
                            defaultPasteFormat: defaultPasteFormat,
                            pinboards: pinboards,
                            onSelect: { event in
                                selectItem(item, event: event)
                            },
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
                            },
                            isPreviewPresented: Binding(
                                get: { previewedItemID == item.id },
                                set: { isPresented in
                                    if isPresented {
                                        previewItem(item)
                                    } else if previewedItemID == item.id {
                                        previewedItemID = nil
                                    }
                                }
                            ),
                            onDismissPreview: {
                                if previewedItemID == item.id {
                                    previewedItemID = nil
                                }
                            }
                        )
                    }

                    if overflowCount > 0 {
                        ShelfOverflowStatusCard(
                            shownCount: renderedItems.count,
                            remainingCount: overflowCount
                        )
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        .overlay {
            ShelfHorizontalWheelRedirector()
        }
        .frame(height: ClipboardShelfMetrics.shelfHeight)
    }

    private var keyboardShortcuts: some View {
        HStack {
            Button("Paste Selected") {
                pasteSelected(format: store.defaultPasteFormat)
            }
            .keyboardShortcut(.return, modifiers: [])

            Button("Paste Selected as Plain Text") {
                pasteSelected(format: .plainText)
            }
            .keyboardShortcut(.return, modifiers: [.shift])

            ForEach(1...9, id: \.self) { index in
                Button("Quick Paste \(index)") {
                    guard let item = store.quickPasteItem(atOneBasedIndex: index) else { return }
                    pasteItem(item, format: store.defaultPasteFormat)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index))), modifiers: [.command])
            }

            Button("Focus Search") {
                setSearchFocused(true)
            }
            .keyboardShortcut("f", modifiers: [.command])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var emptyTitle: String {
        store.selectedScope == .pasteStack ? localized("Paste Stack is Empty") : localized("No Clipboard Items")
    }

    private var emptySystemImage: String {
        store.selectedScope == .pasteStack ? "tray" : "doc.on.clipboard"
    }

    private var emptyDescription: String {
        if store.selectedScope == .pasteStack {
            return store.isPasteStackActive ? localized("New copies will appear here.") : localized("Start collecting copied items.")
        }
        return localized("Copy text, links, screenshots, or files to fill the shelf.")
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
        let currentID = selectedItemID ?? selectedItemIDs.first
        let currentIndex = currentID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        let nextIndex = min(max(currentIndex + offset, items.startIndex), items.index(before: items.endIndex))
        selectSingleItem(items[nextIndex].id)
    }

    private func setScope(_ scope: PasteScope) {
        previewedItemID = nil
        store.selectedScope = scope
        refreshShelfItems()
    }

    private func clearFilter(_ descriptor: ClipboardFilterDescriptor) {
        previewedItemID = nil
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

    private func selectItem(_ item: ClipboardItem, event: NSEvent) {
        isShelfSelectionUserOwned = true
        deferSearchFocusClearingAfterSelection()

        let items = renderedShelfItems
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.shift),
           let anchorID = selectionAnchorID ?? selectedItemID,
           let anchorIndex = items.firstIndex(where: { $0.id == anchorID }),
           let itemIndex = items.firstIndex(where: { $0.id == item.id }) {
            let lowerBound = min(anchorIndex, itemIndex)
            let upperBound = max(anchorIndex, itemIndex)
            let ids = Set(items[lowerBound...upperBound].map(\.id))
            setSelectedItemIDs(ids)
            return
        }

        if flags.contains(.command) {
            var ids = selectedItemIDs
            if ids.contains(item.id) {
                ids.remove(item.id)
            } else {
                ids.insert(item.id)
            }
            setSelectedItemIDs(ids)
            selectionAnchorID = item.id
            return
        }

        if selectedItemIDs.count > 1, selectedItemIDs.contains(item.id) {
            selectionAnchorID = item.id
            return
        }

        selectSingleItem(item.id)
    }

    private func draggableItems(for item: ClipboardItem) -> [ClipboardItem] {
        let selectedItems = selectedItemsInDisplayOrder
        if selectedItems.contains(where: { $0.id == item.id }) {
            return selectedItems
        }
        return [item]
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
        let ids = selectedItemIDs
        guard !ids.isEmpty else {
            return selectedItemID.flatMap { id in renderedShelfItems.first { $0.id == id } }.map { [$0] } ?? []
        }
        return renderedShelfItems.filter { ids.contains($0.id) }
    }

    private func selectSingleItem(_ id: UUID?) {
        isShelfSelectionUserOwned = true
        let ids = id.map { Set([$0]) } ?? []
        guard selectedItemID != id || selectedItemIDs != ids else { return }
        if previewedItemID != id {
            previewedItemID = nil
        }
        selectedItemID = id
        selectedItemIDs = ids
        selectionAnchorID = id
        scheduleStoreSelectionSync(primaryID: id, ids: ids)
    }

    private func setSelectedItemIDs(_ ids: Set<UUID>) {
        isShelfSelectionUserOwned = true
        guard selectedItemIDs != ids else { return }
        previewedItemID = nil
        selectedItemIDs = ids
        selectedItemID = shelfItems.first(where: { ids.contains($0.id) })?.id
        scheduleStoreSelectionSync(primaryID: selectedItemID, ids: ids)
    }

    private func deferSearchFocusClearingAfterSelection() {
        guard isSearchFocused else { return }
        Task { @MainActor in
            await Task.yield()
            setSearchFocused(false)
        }
    }

    private func setSearchFocused(_ isFocused: Bool) {
        guard isSearchFocused != isFocused else { return }
        withAnimation(Self.pasteSearchAnimation) {
            isSearchFocused = isFocused
        }
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
                store.setSelectedItemIDs(ids)
            }
        }
    }

    private func previewSelectedItem() {
        guard let item = selectedItemsInDisplayOrder.first else { return }
        previewItem(item)
    }

    private func previewItem(_ item: ClipboardItem) {
        guard renderedShelfItems.contains(where: { $0.id == item.id }) else { return }
        setSearchFocused(false)
        previewedItemID = item.id
        selectSingleItem(item.id)
    }

    private func handleExitCommand() {
        if previewedItemID != nil {
            previewedItemID = nil
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
        let items = store.filteredItems
        shelfItems = items

        let renderedItems = Array(items.prefix(ClipboardShelfMetrics.renderLimit))
        let itemIDs = Set(renderedItems.map(\.id))
        if let previewedItemID, !itemIDs.contains(previewedItemID) {
            self.previewedItemID = nil
        }

        let localSelectedIDs = selectedItemIDs.intersection(itemIDs)
        let localPrimaryID = selectedItemID.flatMap { itemIDs.contains($0) ? $0 : nil }
        if isShelfSelectionUserOwned, (!localSelectedIDs.isEmpty || localPrimaryID != nil) {
            let ids = localSelectedIDs.isEmpty ? localPrimaryID.map { Set([$0]) } ?? [] : localSelectedIDs
            let primaryID = localPrimaryID.flatMap { ids.contains($0) ? $0 : nil }
                ?? renderedItems.first(where: { ids.contains($0.id) })?.id
            let didNormalizeSelection = selectedItemIDs != ids || selectedItemID != primaryID
            selectedItemIDs = ids
            selectedItemID = primaryID
            if selectionAnchorID.map({ !itemIDs.contains($0) }) == true {
                selectionAnchorID = selectedItemID
            }
            if didNormalizeSelection || selectionSyncTask != nil || !storeSelectionMatches(primaryID: primaryID, ids: ids) {
                scheduleStoreSelectionSync(primaryID: primaryID, ids: ids)
            }
            return
        }

        selectionSyncTask?.cancel()
        selectionSyncTask = nil

        let validStoreSelectedIDs = store.selectedItemIDs.intersection(itemIDs)
        if !validStoreSelectedIDs.isEmpty {
            selectedItemIDs = validStoreSelectedIDs
            selectedItemID = renderedItems.first(where: { validStoreSelectedIDs.contains($0.id) })?.id
            isShelfSelectionUserOwned = false
            if selectionAnchorID.map({ !itemIDs.contains($0) }) == true {
                selectionAnchorID = selectedItemID
            }
        } else if let selectedID = store.selectedItemID, itemIDs.contains(selectedID) {
            selectedItemID = selectedID
            selectedItemIDs = [selectedID]
            selectionAnchorID = selectedID
            isShelfSelectionUserOwned = false
        } else {
            let firstID = renderedItems.first?.id
            selectedItemID = firstID
            selectedItemIDs = firstID.map { [$0] } ?? []
            selectionAnchorID = firstID
            isShelfSelectionUserOwned = false
            scheduleStoreSelectionSync(primaryID: firstID, ids: selectedItemIDs)
        }
    }

    private func storeSelectionMatches(primaryID: UUID?, ids: Set<UUID>) -> Bool {
        if ids.count == 1 {
            return store.selectedItemIDs == ids && store.selectedItemID == primaryID
        }
        return store.selectedItemIDs == ids
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
                .help("Hide this prompt")
            }

            Spacer()

            VStack(alignment: .leading, spacing: 5) {
                Text("Open at Login")
                    .font(.headline)
                Text("Automatically start PasteBuddy when your Mac restarts.")
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
            .help(LaunchAtLoginService.isAvailable ? "Toggle launch at login" : "Launch at login is unavailable in this build")
        }
        .padding(20)
        .frame(width: 240, height: 230)
        .pasteBuddyGlassSurface(cornerRadius: 18, interactive: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Open at login")
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
                Text(localized("Showing first %d items", shownCount))
                    .font(.headline)
                    .lineLimit(2)
                Text(localized("Refine search or filters to see %d more.", remainingCount))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(20)
        .frame(width: 240, height: 230)
        .pasteBuddyGlassSurface(cornerRadius: 18, interactive: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(localized("Showing first %d clipboard items. Refine search or filters to see %d more.", shownCount, remainingCount))
    }

    private func localized(_ key: String, _ arguments: CVarArg...) -> String {
        String(
            format: NSLocalizedString(key, comment: ""),
            locale: Locale.current,
            arguments: arguments
        )
    }
}

private struct ShelfCollectionChip: View {
    private static let hoverAnimation = Animation.smooth(duration: 0.18, extraBounce: 0.04)

    let title: String
    let count: Int?
    let systemImageName: String
    let color: Color
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    init(
        title: String,
        count: Int? = nil,
        systemImageName: String,
        color: Color,
        isSelected: Bool,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.count = count
        self.systemImageName = systemImageName
        self.color = color
        self.isSelected = isSelected
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

                if let count, count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background {
                            if isSelected || isHovered {
                                Capsule().fill(.primary.opacity(0.08))
                            }
                        }
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(height: 38)
            .background {
                if isSelected || isHovered {
                    Capsule()
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(isSelected ? 0.86 : 0.64))
                        .background(.regularMaterial, in: Capsule())
                }
            }
            .shadow(
                color: .black.opacity(isSelected ? 0.07 : (isHovered ? 0.04 : 0)),
                radius: isSelected || isHovered ? 6 : 0,
                y: isSelected || isHovered ? 1 : 0
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            withAnimation(Self.hoverAnimation) {
                self.isHovered = isHovered
            }
        }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? NSLocalizedString("Selected", comment: "") : NSLocalizedString("Not selected", comment: ""))
    }

    private var iconForegroundStyle: Color {
        if isSelected {
            return .primary
        }
        return color
    }

    private var helpText: String {
        guard let count else { return title }
        return String(
            format: NSLocalizedString("%d items", comment: ""),
            locale: Locale.current,
            arguments: [count]
        )
    }
}

private struct ShelfSelectedCountChip: View {
    let count: Int

    var body: some View {
        Label(String(format: NSLocalizedString("%d selected", comment: ""), count), systemImage: "checkmark.circle.fill")
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
            .accessibilityLabel(String(format: NSLocalizedString("%d selected", comment: ""), count))
    }
}

private struct ClipboardShelfCard: View {
    let item: ClipboardItem
    let imageDataProvider: @MainActor (ClipboardItem) async -> Data?
    let draggedItems: [ClipboardItem]
    let isSelected: Bool
    let defaultPasteFormat: PasteFormat
    let pinboards: [Pinboard]
    let onSelect: (NSEvent) -> Void
    let onPaste: (PasteFormat) -> Void
    let onCopy: (PasteFormat) -> Void
    let onPin: (UUID) -> Void
    let onDelete: () -> Void
    @Binding var isPreviewPresented: Bool
    let onDismissPreview: () -> Void

    var body: some View {
        ClipboardShelfCardVisual(item: item, imageDataProvider: imageDataProvider)
            .equatable()
            .overlay {
                ClipboardShelfCardSelectionRing(item: item, isSelected: isSelected)
            }
            .overlay {
                ShelfClickSurface { event in
                    onSelect(event)
                } onMouseUp: { event in
                    if event.clickCount >= 2 {
                        onPaste(defaultPasteFormat)
                    }
                }
                .accessibilityHidden(true)
            }
        .contextMenu {
            contextMenuContent
        }
        .onDrag {
            ClipboardItemDragProvider.provider(for: draggedItems)
        }
        .popover(isPresented: $isPreviewPresented, arrowEdge: .bottom) {
            ShelfExpandedPreview(
                item: item,
                imageDataProvider: imageDataProvider,
                tint: SourceApplicationIconResolver.themeColor(for: item, fallback: item.contentType.shelfTint),
                onDismiss: onDismissPreview
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("clipboard-shelf-card-\(item.id.uuidString)")
        .accessibilityLabel("\(item.title), \(localized(item.contentType.displayName))")
        .accessibilityValue(localized(isSelected ? "Selected" : "Not selected"))
        .accessibilityHint(localized("Press Space to preview. Press Return to paste."))
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Group {
            Button("Paste") {
                onPaste(defaultPasteFormat)
            }
            Button("Paste as Plain Text") {
                onPaste(.plainText)
            }
            Button("Copy") {
                onCopy(.original)
            }
            Button("Copy as Plain Text") {
                onCopy(.plainText)
            }
            if let url = item.openableURL {
                Button("Open") {
                    NSWorkspace.shared.open(url)
                }
            }
            Divider()
            Menu("Pin") {
                ForEach(pinboards) { pinboard in
                    Button(pinboard.name) {
                        onPin(pinboard.id)
                    }
                }
            }
            Button("Delete", role: .destructive) {
                onDelete()
            }
        }
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}

private struct ShelfExpandedPreview: View {
    let item: ClipboardItem
    let imageDataProvider: @MainActor (ClipboardItem) async -> Data?
    let tint: Color
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(localized("Close preview"))

                Label(localized(item.contentType.displayName), systemImage: item.contentType.systemImageName)
                    .font(.headline)
                    .lineLimit(1)

                Spacer(minLength: 12)

                SourceApplicationIconBadge(item: item, size: 24)
            }

            previewContent

            HStack(spacing: 10) {
                Text(footnote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if let url = item.openableURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Open", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(14)
        .frame(width: 560, alignment: .leading)
        .background(.regularMaterial)
        .onExitCommand(perform: onDismiss)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("Preview"))
    }

    @ViewBuilder
    private var previewContent: some View {
        switch item.contentType {
        case .image:
            VStack(alignment: .leading, spacing: 10) {
                if item.payload.hasImageAsset {
                    ShelfExpandedImagePreview(item: item, imageDataProvider: imageDataProvider, tint: tint)
                }
                if let text = item.payload.ocrText, !text.isEmpty {
                    previewText(text)
                        .frame(maxHeight: 110)
                }
            }
        case .text, .url, .file, .mixed:
            previewText(ClipboardPlainTextRenderer.plainText(for: item))
                .frame(height: 300)
        }
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
        .background(Color(nsColor: .textBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(tint.opacity(0.28), lineWidth: 1)
        }
    }

    private var footnote: String {
        switch item.contentType {
        case .image:
            if let imageSize = ClipboardImageCache.imageSize(for: item) {
                return "\(Int(imageSize.width)) x \(Int(imageSize.height))"
            }
            return localized(item.ocrState.displayName)
        case .file:
            let count = item.payload.allFileURLStrings.count
            return localized(count == 1 ? "%d file" : "%d files", count)
        default:
            return localized("%d chars", ClipboardPlainTextRenderer.plainText(for: item).count)
        }
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

private struct ShelfExpandedImagePreview: View {
    let item: ClipboardItem
    let imageDataProvider: @MainActor (ClipboardItem) async -> Data?
    let tint: Color
    @State private var image: NSImage?
    @State private var loadedImageData: Data?

    var body: some View {
        ZStack {
            if let image = image ?? ClipboardImageCache.cachedThumbnail(
                for: item,
                imageData: loadedImageData,
                maxPixelSize: maxPixelSize
            ) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 340)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint.opacity(0.10))
                Image(systemName: "photo")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 340)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(tint.opacity(0.25), lineWidth: 1)
        }
        .accessibilityLabel(localized("Captured image preview"))
        .task(id: ClipboardImageCache.thumbnailCacheKey(for: item, maxPixelSize: maxPixelSize)) {
            image = ClipboardImageCache.cachedThumbnail(
                for: item,
                imageData: loadedImageData,
                maxPixelSize: maxPixelSize
            )
            guard image == nil else { return }

            let imageData: Data?
            if let loadedImageData {
                imageData = loadedImageData
            } else {
                imageData = await imageDataProvider(item)
            }
            loadedImageData = imageData
            let loadedImage = await ClipboardImageCache.thumbnail(
                for: item,
                imageData: imageData,
                maxPixelSize: maxPixelSize
            )
            guard !Task.isCancelled else { return }
            image = loadedImage
        }
    }

    private var maxPixelSize: Int {
        1_600
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}

private struct ShelfSpaceKeyMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let onSpace: () -> Void

    func makeNSView(context: Context) -> ShelfSpaceKeyMonitorView {
        ShelfSpaceKeyMonitorView(isEnabled: isEnabled, onSpace: onSpace)
    }

    func updateNSView(_ nsView: ShelfSpaceKeyMonitorView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.onSpace = onSpace
    }
}

private final class ShelfSpaceKeyMonitorView: NSView {
    var isEnabled: Bool
    var onSpace: () -> Void
    private var localKeyDownMonitor: Any?

    init(isEnabled: Bool, onSpace: @escaping () -> Void) {
        self.isEnabled = isEnabled
        self.onSpace = onSpace
        super.init(frame: .zero)
        installMonitor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let localKeyDownMonitor {
            NSEvent.removeMonitor(localKeyDownMonitor)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installMonitor()
    }

    private func installMonitor() {
        guard localKeyDownMonitor == nil else { return }
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  self.isEnabled,
                  event.window === self.window,
                  Self.isPlainSpace(event) else {
                return event
            }

            self.onSpace()
            return nil
        }
    }

    private static func isPlainSpace(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isEmpty else { return false }
        return event.keyCode == 49 || event.charactersIgnoringModifiers == " "
    }
}

private struct ShelfClickSurface: NSViewRepresentable {
    let onMouseDown: (NSEvent) -> Void
    let onMouseUp: (NSEvent) -> Void

    func makeNSView(context: Context) -> ShelfClickNSView {
        ShelfClickNSView(onMouseDown: onMouseDown, onMouseUp: onMouseUp)
    }

    func updateNSView(_ nsView: ShelfClickNSView, context: Context) {
        nsView.onMouseDown = onMouseDown
        nsView.onMouseUp = onMouseUp
    }
}

private struct ShelfHorizontalWheelRedirector: NSViewRepresentable {
    func makeNSView(context: Context) -> ShelfHorizontalWheelRedirectorView {
        ShelfHorizontalWheelRedirectorView()
    }

    func updateNSView(_ nsView: ShelfHorizontalWheelRedirectorView, context: Context) {}
}

private final class ShelfHorizontalWheelRedirectorView: NSView {
    private static let preciseScrollMultiplier: CGFloat = 1.25
    private static let wheelLineMultiplier: CGFloat = 64

    private var localScrollMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installMonitor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let localScrollMonitor {
            NSEvent.removeMonitor(localScrollMonitor)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installMonitor()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func installMonitor() {
        guard localScrollMonitor == nil else { return }
        localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  NSApp.isActive,
                  event.window === self.window,
                  self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else {
                return event
            }

            let horizontalDelta = self.normalizedScrollDelta(event.scrollingDeltaX, for: event)
            let verticalDelta = self.normalizedScrollDelta(event.scrollingDeltaY, for: event)
            guard abs(verticalDelta) > abs(horizontalDelta), verticalDelta != 0,
                  let scrollView = self.horizontalScrollView(containing: event.locationInWindow) else {
                return event
            }

            self.scroll(scrollView, horizontallyBy: -verticalDelta)
            return nil
        }
    }

    private func normalizedScrollDelta(_ delta: CGFloat, for event: NSEvent) -> CGFloat {
        delta * (event.hasPreciseScrollingDeltas ? Self.preciseScrollMultiplier : Self.wheelLineMultiplier)
    }

    private func horizontalScrollView(containing windowPoint: NSPoint) -> NSScrollView? {
        guard let contentView = window?.contentView else { return nil }
        return firstHorizontalScrollView(containing: windowPoint, in: contentView)
    }

    private func firstHorizontalScrollView(containing windowPoint: NSPoint, in view: NSView) -> NSScrollView? {
        let point = view.convert(windowPoint, from: nil)
        guard view.bounds.contains(point) else { return nil }

        for subview in view.subviews.reversed() {
            if let scrollView = firstHorizontalScrollView(containing: windowPoint, in: subview) {
                return scrollView
            }
        }

        guard let scrollView = view as? NSScrollView,
              let documentView = scrollView.documentView,
              documentView.frame.width > scrollView.contentView.bounds.width else {
            return nil
        }
        return scrollView
    }

    private func scroll(_ scrollView: NSScrollView, horizontallyBy delta: CGFloat) {
        guard let documentView = scrollView.documentView else { return }

        let clipView = scrollView.contentView
        let maxX = max(0, documentView.frame.width - clipView.bounds.width)
        let currentX = clipView.bounds.origin.x
        let nextX = min(max(currentX + delta, 0), maxX)
        guard nextX != currentX else { return }

        clipView.scroll(to: NSPoint(x: nextX, y: clipView.bounds.origin.y))
        scrollView.reflectScrolledClipView(clipView)
    }
}

private final class ShelfClickNSView: NSView {
    var onMouseDown: (NSEvent) -> Void
    var onMouseUp: (NSEvent) -> Void
    private var localMouseMonitor: Any?
    private var isTrackingMouseDown = false

    init(onMouseDown: @escaping (NSEvent) -> Void, onMouseUp: @escaping (NSEvent) -> Void) {
        self.onMouseDown = onMouseDown
        self.onMouseUp = onMouseUp
        super.init(frame: .zero)
        installMonitor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installMonitor()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !NSApp.isActive,
              let event = window?.currentEvent,
              shouldHandleMouseDown(event) else {
            return nil
        }

        return bounds.contains(point) ? super.hitTest(point) : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard shouldHandleMouseDown(event) else { return }
        isTrackingMouseDown = true
        onMouseDown(event)
    }

    override func mouseUp(with event: NSEvent) {
        let shouldEmitMouseUp = isTrackingMouseDown && shouldHandleMouseUp(event)
        isTrackingMouseDown = false
        guard shouldEmitMouseUp else { return }
        onMouseUp(event)
    }

    private func installMonitor() {
        guard localMouseMonitor == nil else { return }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self, NSApp.isActive else {
                return event
            }

            if event.type == .leftMouseDown, self.shouldHandleMouseDown(event) {
                self.isTrackingMouseDown = true
                self.onMouseDown(event)
            } else if event.type == .leftMouseUp {
                let shouldEmitMouseUp = self.isTrackingMouseDown && self.shouldHandleMouseUp(event)
                self.isTrackingMouseDown = false
                guard shouldEmitMouseUp else {
                    return event
                }
                self.onMouseUp(event)
            }
            return event
        }
    }

    private func shouldHandleMouseDown(_ event: NSEvent) -> Bool {
        shouldHandleMouseEvent(event, expectedType: .leftMouseDown)
    }

    private func shouldHandleMouseUp(_ event: NSEvent) -> Bool {
        shouldHandleMouseEvent(event, expectedType: .leftMouseUp)
    }

    private func shouldHandleMouseEvent(_ event: NSEvent, expectedType: NSEvent.EventType) -> Bool {
        guard event.type == expectedType,
              event.window === window else {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.control) else {
            return false
        }

        let point = convert(event.locationInWindow, from: nil)
        return bounds.contains(point)
    }
}

private struct ClipboardShelfCardVisual: View {
    let item: ClipboardItem
    let imageDataProvider: @MainActor (ClipboardItem) async -> Data?
    private let renderSignature: ClipboardShelfCardRenderSignature

    init(
        item: ClipboardItem,
        imageDataProvider: @escaping @MainActor (ClipboardItem) async -> Data?
    ) {
        self.item = item
        self.imageDataProvider = imageDataProvider
        self.renderSignature = ClipboardShelfCardRenderSignature(item: item)
    }

    private var cardTint: Color {
        SourceApplicationIconResolver.themeColor(for: item, fallback: item.contentType.shelfTint)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(localized(item.contentType.displayName))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                TimelineView(.periodic(from: Date(), by: 60)) { timeline in
                    Text(relativeDate(relativeTo: timeline.date))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white.opacity(0.82))
                }
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
        } else {
            VStack(alignment: .leading, spacing: 9) {
                if item.contentType == .url {
                    Image(systemName: "link.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(cardTint)
                }
                Text(preview.body)
                    .font(item.contentType == .text ? .callout.monospaced() : .callout)
                    .foregroundStyle(.primary)
                    .lineLimit(footerTitle == nil ? 4 : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(height: ClipboardShelfMetrics.cardPreviewHeight, alignment: .topLeading)
            .background {
                Rectangle()
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.22))
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
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.18))
        }
        .background(.regularMaterial)
    }

    private func relativeDate(relativeTo date: Date) -> String {
        Self.relativeFormatter.localizedString(for: item.createdAt, relativeTo: date)
    }

    private var footerTitle: String? {
        let headline = item.visualPreview.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !headline.isEmpty else { return nil }

        switch item.contentType {
        case .text, .mixed:
            return nil
        case .url, .image, .file:
            return headline
        }
    }

    private var footnote: String {
        switch item.contentType {
        case .image:
            if let imageSize = ClipboardImageCache.imageSize(for: item) {
                return "\(Int(imageSize.width)) x \(Int(imageSize.height))"
            }
            return localized(item.ocrState.displayName)
        case .file:
            let count = item.payload.allFileURLStrings.count
            return localized(count == 1 ? "%d file" : "%d files", count)
        default:
            let count = ClipboardPlainTextRenderer.plainText(for: item).count
            return localized("%d chars", count)
        }
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
    static func == (lhs: ClipboardShelfCardVisual, rhs: ClipboardShelfCardVisual) -> Bool {
        lhs.renderSignature == rhs.renderSignature
    }
}

private struct ClipboardShelfCardSelectionRing: View {
    let item: ClipboardItem
    let isSelected: Bool

    private var cardTint: Color {
        SourceApplicationIconResolver.themeColor(for: item, fallback: item.contentType.shelfTint)
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

    init(item: ClipboardItem) {
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
    }
}

private struct ShelfThumbnailView: View {
    let item: ClipboardItem
    let imageDataProvider: @MainActor (ClipboardItem) async -> Data?
    let tint: Color
    @State private var thumbnail: NSImage?
    @State private var loadedImageData: Data?

    var body: some View {
        ZStack {
            if let image = thumbnail ?? ClipboardImageCache.cachedThumbnail(for: item, imageData: loadedImageData) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(tint.opacity(0.10))
                Image(systemName: item.contentType.systemImageName)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(height: ClipboardShelfMetrics.cardPreviewHeight)
        .frame(maxWidth: .infinity)
        .clipped()
        .task(id: ClipboardImageCache.thumbnailCacheKey(for: item)) {
            thumbnail = ClipboardImageCache.cachedThumbnail(for: item, imageData: loadedImageData)
            guard thumbnail == nil else { return }

            let imageData: Data?
            if let loadedImageData {
                imageData = loadedImageData
            } else {
                imageData = await imageDataProvider(item)
            }
            loadedImageData = imageData
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
            .help(NSLocalizedString("Clear app filter", comment: ""))
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(appName)
    }
}

private struct ShelfSourceAppSuggestionStrip: View {
    let appNames: [String]
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(appNames, id: \.self) { appName in
                    Button {
                        onSelect(appName)
                    } label: {
                        HStack(spacing: 6) {
                            SourceApplicationIconImage(appName: appName, size: 18)
                            Text(appName)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .background(.regularMaterial, in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
        .frame(height: 38)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("App suggestions", comment: ""))
    }
}

private struct SourceApplicationIconImage: View {
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

private struct SourceApplicationIconBadge: View {
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
                Image(systemName: item.contentType.systemImageName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(item.contentType.shelfTint)
            }
        }
        .frame(width: size, height: size)
        .help(item.sourceAppName)
        .accessibilityLabel(item.sourceAppName)
    }
}

@MainActor
private enum SourceApplicationIconResolver {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for item: ClipboardItem) -> NSImage? {
        if let bundleIdentifier = normalized(item.sourceBundleIdentifier) {
            let cacheKey = "bundle:\(bundleIdentifier)" as NSString
            if let cached = cache.object(forKey: cacheKey) {
                return cached
            }
            if let image = icon(forBundleIdentifier: bundleIdentifier) {
                cache.setObject(image, forKey: cacheKey)
                return image
            }
        }

        guard let appName = normalized(item.sourceAppName) else { return nil }
        let cacheKey = "name:\(appName.lowercased())" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }
        guard let image = icon(forApplicationName: appName) else { return nil }
        cache.setObject(image, forKey: cacheKey)
        return image
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
            ?? (hasKnownSource(for: item) ? genericApplicationIcon() : nil)
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
        if let image = runningApplicationIcon(appName: appName) {
            return image
        }

        let fileManager = FileManager.default
        let appFileName = appName.hasSuffix(".app") ? appName : "\(appName).app"
        let searchDirectories = applicationSearchDirectories()

        for directory in searchDirectories {
            let candidate = directory.appendingPathComponent(appFileName, isDirectory: true)
            if fileManager.fileExists(atPath: candidate.path) {
                return icon(forApplicationURL: candidate)
            }
        }

        return nil
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

private struct PasteBuddyGlassContainer<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private extension View {
    @ViewBuilder
    func pasteBuddyBottomSheetSurface(cornerRadius: CGFloat, showsStroke: Bool = true) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self
                .glassEffect(.regular, in: shape)
                .background {
                    shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.28))
                }
                .clipShape(shape)
                .overlay(alignment: .top) {
                    if showsStroke {
                        Rectangle()
                            .fill(.white.opacity(0.42))
                            .frame(height: 1)
                    }
                }
        } else {
            self
                .background(.thinMaterial, in: shape)
                .background {
                    shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.16))
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
                shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.16))
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
    func pasteBuddyGlassSurface(cornerRadius: CGFloat, interactive: Bool = false, showsStroke: Bool = true) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self
                .glassEffect((interactive ? Glass.regular.interactive() : .regular), in: shape)
                .background {
                    shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.22))
                }
                .overlay {
                    if showsStroke {
                        shape.strokeBorder(.white.opacity(0.40), lineWidth: 1)
                    }
                }
        } else {
            self
                .background(.thinMaterial, in: shape)
                .background {
                    shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.12))
                }
                .overlay {
                    if showsStroke {
                        shape.strokeBorder(.white.opacity(0.40), lineWidth: 1)
                    }
                }
        }
        #else
        self
            .background(.thinMaterial, in: shape)
            .background {
                shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.12))
            }
            .overlay {
                if showsStroke {
                    shape.strokeBorder(.white.opacity(0.40), lineWidth: 1)
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

private extension ClipboardContentType {
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
