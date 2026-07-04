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
    @State private var sideItems: [ClipboardItem] = []
    @State private var sideItemTotalCount = 0
    @State private var interaction = ShelfInteractionModel()
    @State private var isShowingNewTextItem = false
    @State private var pinnedState: Bool?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.32)
            itemList
            footer
        }
        .padding(.top, 14)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .pasteBuddyBottomSheetSurface(cornerRadius: 28, showsStroke: false)
        .background(Color.clear)
        .background(sidePanelKeyboardShortcuts)
        .onAppear {
            store.searchQuery = ""
            store.clearFilters()
            sideScope = store.selectedScope
            refreshSideItems()
            Task { @MainActor in
                await Task.yield()
                setSearchFocused(false)
            }
        }
        .onDisappear {
            interaction.dismissPreview()
        }
        .onChange(of: queryState) {
            refreshSideItems()
        }
        .onChange(of: store.searchQuery) {
            interaction.dismissPreview()
        }
        .onMoveCommand(perform: handleSidePanelMoveCommand)
        .onExitCommand(perform: handleExitCommand)
        .focusable(true)
        .focusEffectDisabled()
        .focused($isListFocused)
        .onKeyPress(phases: .down) { keyPress in
            handleKeyPress(keyPress)
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

    private var sidePanelKeyboardShortcuts: some View {
        Group {
            keyboardShortcut(.leftArrow) { moveSelection(.left) }
            keyboardShortcut(.rightArrow) { moveSelection(.right) }
            keyboardShortcut(.upArrow) { moveSelection(.up) }
            keyboardShortcut(.downArrow) { moveSelection(.down) }
        }
        .disabled(isSearchFocused || interaction.previewedID != nil)
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
        }
        .padding(.leading, 12)
        .padding(.trailing, hasSearchText ? 8 : 12)
        .frame(height: 36)
        .pasteBuddyGlassSurface(cornerRadius: 18, interactive: true, showsStroke: true)
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
                }
            )
        }
    }

    private var quickFilterStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ClipboardSidePanelFilterChip(
                    title: localized("label.clipboard"),
                    systemImageName: "clock.arrow.circlepath",
                    color: store.isCapturePaused ? .orange : .blue,
                    isSelected: sideScope == .history
                ) {
                    setSideScope(.history)
                }

                ClipboardSidePanelFilterChip(
                    title: localized("action.paste_stack"),
                    systemImageName: store.isPasteStackActive ? "tray.full.fill" : "tray",
                    color: store.isPasteStackActive ? .green : .secondary,
                    isSelected: sideScope == .pasteStack
                ) {
                    setSideScope(.pasteStack)
                }

                ForEach(SmartPinboardCategory.allCases) { category in
                    ClipboardSidePanelFilterChip(
                        title: localized(category.displayName),
                        systemImageName: category.systemImageName,
                        color: Color(hex: category.colorHex) ?? .accentColor,
                        isSelected: isSmartCategorySelected(category)
                    ) {
                        selectSmartCategory(category)
                    }
                }

                ForEach(store.userPinboards) { pinboard in
                    ClipboardSidePanelFilterChip(
                        title: pinboard.name,
                        systemImageName: "pin.fill",
                        color: Color(hex: pinboard.colorHex) ?? .blue,
                        isSelected: sideScope == .pinboard(pinboard.id)
                    ) {
                        setSideScope(.pinboard(pinboard.id))
                    }
                }

                Menu {
                    Button {
                        isShowingNewTextItem = true
                    } label: {
                        Label("label.new_text_item", systemImage: "square.and.pencil")
                    }
                    Button {
                        let pinboard = store.createPinboard()
                        setSideScope(.pinboard(pinboard.id))
                    } label: {
                        Label("label.new_pinboard", systemImage: "plus.rectangle.on.folder")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .labelStyle(.iconOnly)
                .help(localized("action.add_item_or_pinboard"))
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.never, axes: .horizontal)
    }

    private var itemList: some View {
        VStack(spacing: 8) {
            if renderedItems.isEmpty {
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
                        interaction.dismissPreview(for: id)
                    },
                    isSelectable: { _ in true },
                    content: { item, isSelected in
                        ClipboardSidePanelListRow(
                            item: item,
                            imageDataProvider: store.imageData,
                            isSelected: isSelected,
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
                            pinboards: store.userPinboards
                        )
                        .frame(width: 324, height: ClipboardSidePanelMetrics.rowHeight)
                    },
                    previewContent: { item in
                        AnyView(
                            ShelfExpandedPreview(
                                item: item,
                                imageDataProvider: store.imageData,
                                tint: SourceApplicationIconResolver.themeColor(for: item, fallback: item.presentationContentType.shelfTint),
                                maxWidth: ClipboardSidePanelMetrics.previewMaxWidth,
                                onDismiss: {
                                    interaction.dismissPreview()
                                },
                                onMove: moveSelection,
                                onTextInput: beginSearch
                            )
                        )
                    },
                    dragPayload: { item in
                        PinboardItemDragPayload(
                            ids: [item.id],
                            plainText: PasteboardWriter.plainText(for: item)
                        )
                    },
                    onSelect: { id in
                        guard let item = renderedItems.first(where: { $0.id == id }) else { return }
                        selectItem(item)
                    },
                    onDoubleClick: { id in
                        guard let item = renderedItems.first(where: { $0.id == id }) else { return }
                        pasteItem(item, format: store.defaultPasteFormat)
                    }
                )
            }

        }
        .padding(.vertical, 10)
    }

    private var footer: some View {
        Text(localized("format.items", sideItemTotalCount))
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .padding(.horizontal, 4)
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
        sideItems
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
            && store.sourceAppFilter == nil
            && hasSearchText
            && !sourceAppSuggestions.isEmpty
    }

    private var emptyTitle: String {
        sideScope == .pasteStack ? localized("action.paste_stack_is_empty") : localized("label.no_clipboard_items")
    }

    private var emptySystemImage: String {
        sideScope == .pasteStack ? "tray" : "doc.on.clipboard"
    }

    private var emptyDescription: String {
        if sideScope == .pasteStack {
            return store.isPasteStackActive ? localized("message.new_copies_will_appear_here") : localized("message.start_collecting_copied_items")
        }
        return localized("message.copy_text_links_screenshots_or_files_to")
    }

    private func refreshSideItems() {
        let items = store.filteredItems(for: sideScope)
        sideItems = items
        sideItemTotalCount = store.filteredItemCount(for: sideScope)
        interaction.replaceItems(
            items,
            storeSelectedIDs: store.selectedItemIDs,
            storePrimarySelectedID: store.selectedItemID
        )
    }

    private func setSideScope(_ scope: PasteScope) {
        if sideScope != scope {
            interaction.dismissPreview()
            sideScope = scope
        }
        if store.hasActiveFilters {
            store.clearFilters()
        }
    }

    private func isSmartCategorySelected(_ category: SmartPinboardCategory) -> Bool {
        guard let pinboard = store.smartPinboard(for: category) else { return false }
        return sideScope == .pinboard(pinboard.id)
    }

    private func selectSmartCategory(_ category: SmartPinboardCategory) {
        let pinboard = store.syncSmartPinboard(for: category)
        setSideScope(.pinboard(pinboard.id))
    }

    private func selectItem(_ item: ClipboardItem) {
        PasteBuddyMotion.performInstantSelection {
            interaction.select(item.id)
        }
        setSearchFocused(false)
    }

    private func selectSingleItem(_ id: UUID?, keepsPreviewOpen: Bool = false) {
        PasteBuddyMotion.performInstantSelection {
            interaction.selectSingle(id, keepsPreviewOpen: keepsPreviewOpen)
        }
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

    private func handleSidePanelMoveCommand(_ direction: MoveCommandDirection) {
        moveSelection(direction)
        Task { @MainActor in
            await Task.yield()
            if !isSearchFocused {
                isListFocused = true
            }
        }
    }

    private func selectOffset(_ offset: Int) {
        let items = renderedItems
        guard !items.isEmpty else { return }
        let currentID = interaction.primarySelectedID ?? interaction.selectedIDs.first
        let currentIndex = currentID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        let nextIndex = min(max(currentIndex + offset, items.startIndex), items.index(before: items.endIndex))
        selectSingleItem(items[nextIndex].id, keepsPreviewOpen: interaction.previewedID != nil)
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        let modifiers = keyPress.modifiers

        if keyPress.key == .space, modifiers.isEmpty, !isSearchFocused {
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

    private func beginSearch(with characters: String) -> Bool {
        guard ClipboardPanelSearchInput.accepts(characters) else { return false }
        interaction.dismissPreview()
        store.searchQuery += characters
        setSearchFocused(true)
        return true
    }

    private func toggleSelectedItemPreview() {
        guard let item = selectedItemsInDisplayOrder.first else { return }
        setSearchFocused(false)
        if interaction.togglePreview(for: item.id) {
            selectSingleItem(item.id)
        }
    }

    private func pasteSelected(format: PasteFormat) {
        let items = selectedItemsInDisplayOrder
        guard !items.isEmpty else { return }
        let shouldDismissBeforePaste = !effectivePinned
        Task { @MainActor in
            let result = await ClipboardShelfDirectPasteCoordinator.runAfterImmediateDismissal(
                dismissBeforePaste: shouldDismissBeforePaste,
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
        let shouldDismissBeforePaste = !effectivePinned
        Task { @MainActor in
            let result = await ClipboardShelfDirectPasteCoordinator.runAfterImmediateDismissal(
                dismissBeforePaste: shouldDismissBeforePaste,
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

    private func handleExitCommand() {
        if isSearchFocused {
            if !store.searchQuery.isEmpty {
                store.searchQuery = ""
                refreshSideItems()
            }
            setSearchFocused(false)
            return
        }
        if interaction.previewedID != nil {
            interaction.dismissPreview()
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

private struct ClipboardSidePanelFilterChip: View {
    let title: String
    let systemImageName: String
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImageName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.72))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                Capsule()
                    .fill(isSelected ? Color(nsColor: .controlBackgroundColor).opacity(0.86) : Color.clear)
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

private struct ClipboardSidePanelListRow: View {
    let item: ClipboardItem
    let imageDataProvider: @MainActor (ClipboardItem) async -> Data?
    let isSelected: Bool
    let onPaste: (PasteFormat) -> Void
    let onCopy: (PasteFormat) -> Void
    let onPin: (UUID) -> Void
    let onDelete: () -> Void
    let pinboards: [Pinboard]

    var body: some View {
        HStack(spacing: 12) {
            SourceApplicationIconBadge(item: item, size: ClipboardSidePanelMetrics.thumbnailSize)
                .frame(width: ClipboardSidePanelMetrics.thumbnailSize, height: ClipboardSidePanelMetrics.thumbnailSize)

            ClipboardSidePanelContentPreview(item: item, imageDataProvider: imageDataProvider)

            Spacer(minLength: 8)

            Text(item.createdAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

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
                onPaste(.original)
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
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("clipboard-side-panel-row-\(item.id.uuidString)")
        .accessibilityLabel(item.title)
        .accessibilityValue(NSLocalizedString(isSelected ? "state.selected" : "label.not_selected", comment: ""))
    }
}

private struct ClipboardSidePanelContentPreview: View {
    let item: ClipboardItem
    let imageDataProvider: @MainActor (ClipboardItem) async -> Data?

    var body: some View {
        if item.presentationContentType == .image, item.payload.hasImageAsset {
            ClipboardSidePanelImagePreview(item: item, imageDataProvider: imageDataProvider)
        } else {
            Text(primaryText)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var primaryText: String {
        nonEmpty(item.visualPreview.body)
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
