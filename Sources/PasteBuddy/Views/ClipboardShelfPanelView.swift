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
    static let shelfVerticalPadding: CGFloat = 6
    static let shelfHeight: CGFloat = cardHeight + shelfVerticalPadding * 2
    static let renderLimit = 200
}

struct ClipboardShelfPanelView: View {
    @Bindable var store: PasteBuddyStore
    let directPasteItem: @MainActor (ClipboardItem, PasteFormat) async -> DirectPasteResult
    let directPasteItems: @MainActor ([ClipboardItem], PasteFormat) async -> DirectPasteResult
    let reloadClipboardHistory: @MainActor () async -> Void
    let onDismiss: () -> Void

    @FocusState private var isSearchFocused: Bool
    @State private var isShowingNewTextItem = false
    @State private var isShowingLaunchAtLoginPrompt = false
    @State private var shelfItems: [ClipboardItem] = []
    @State private var selectionAnchorID: UUID?
    @State private var selectedItemID: UUID?
    @State private var selectedItemIDs: Set<UUID> = []
    @State private var selectionSyncTask: Task<Void, Never>?

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
            isSearchFocused = true
        }
        .onDisappear {
            selectionSyncTask?.cancel()
            selectionSyncTask = nil
        }
        .onChange(of: store.presentationRevision) {
            refreshShelfItems()
        }
        .onMoveCommand(perform: moveSelection)
        .onExitCommand(perform: onDismiss)
        .background {
            keyboardShortcuts
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
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search Clipboard", text: $store.searchQuery)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                        .frame(width: isSearchFocused || !store.searchQuery.isEmpty ? 190 : 128)
                        .onSubmit {
                            pasteSelected(format: store.defaultPasteFormat)
                        }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(height: 38)
                .pasteBuddyGlassSurface(cornerRadius: 19, interactive: true)

                collectionStrip

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

            if store.hasActiveFilters {
                activeFilterStrip
            }
        }
    }

    private var collectionStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ShelfCollectionChip(
                    title: localized("Clipboard"),
                    count: store.snapshot.items.count,
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

                ForEach(store.activeFilterSummaries) { descriptor in
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

        return HiddenScrollerHorizontalScrollView {
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
                            onSelect: {
                                selectItem(item)
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
                isSearchFocused = true
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
            selectOffset(-1)
        case .right, .down:
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
        store.selectedScope = scope
        refreshShelfItems()
    }

    private func clearFilter(_ descriptor: ClipboardFilterDescriptor) {
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

    private func selectItem(_ item: ClipboardItem) {
        let items = renderedShelfItems
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)

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
            let hydratedItems = await store.hydratedItems(for: items)
            let result = await directPasteItems(hydratedItems, format)
            store.recordDirectPasteResult(result)
            onDismiss()
        }
    }

    private func pasteItem(_ item: ClipboardItem, format: PasteFormat) {
        selectSingleItem(item.id)
        Task { @MainActor in
            let hydratedItem = await store.hydratedItem(for: item)
            let result = await directPasteItem(hydratedItem, format)
            store.recordDirectPasteResult(result)
            onDismiss()
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
        let ids = id.map { Set([$0]) } ?? []
        guard selectedItemID != id || selectedItemIDs != ids else { return }
        selectedItemID = id
        selectedItemIDs = ids
        selectionAnchorID = id
        scheduleStoreSelectionSync(primaryID: id, ids: ids)
    }

    private func setSelectedItemIDs(_ ids: Set<UUID>) {
        guard selectedItemIDs != ids else { return }
        selectedItemIDs = ids
        selectedItemID = shelfItems.first(where: { ids.contains($0.id) })?.id
        scheduleStoreSelectionSync(primaryID: selectedItemID, ids: ids)
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
        selectionSyncTask?.cancel()
        selectionSyncTask = nil
        let items = store.filteredItems
        shelfItems = items

        let renderedItems = Array(items.prefix(ClipboardShelfMetrics.renderLimit))
        let itemIDs = Set(renderedItems.map(\.id))
        let validSelectedIDs = store.selectedItemIDs.intersection(itemIDs)
        if !validSelectedIDs.isEmpty {
            selectedItemIDs = validSelectedIDs
            selectedItemID = renderedItems.first(where: { validSelectedIDs.contains($0.id) })?.id
            store.setSelectedItemIDs(validSelectedIDs)
            if selectionAnchorID.map({ !itemIDs.contains($0) }) == true {
                selectionAnchorID = validSelectedIDs.first
            }
        } else if let selectedID = store.selectedItemID, itemIDs.contains(selectedID) {
            selectedItemID = selectedID
            selectedItemIDs = [selectedID]
            store.selectSingleItem(selectedID)
            selectionAnchorID = selectedID
        } else {
            let firstID = renderedItems.first?.id
            selectedItemID = firstID
            selectedItemIDs = firstID.map { [$0] } ?? []
            store.selectSingleItem(firstID)
            selectionAnchorID = firstID
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
    let title: String
    let count: Int
    let systemImageName: String
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImageName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? color : .secondary)

                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(isSelected ? color : .secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background {
                            if isSelected {
                                Capsule().fill(color.opacity(0.18))
                            }
                        }
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(height: 38)
            .background {
                if isSelected {
                    Capsule().fill(.regularMaterial)
                }
            }
            .overlay {
                if isSelected {
                    Capsule().strokeBorder(color.opacity(0.95), lineWidth: 2)
                }
            }
            .shadow(color: .black.opacity(isSelected ? 0.12 : 0), radius: isSelected ? 8 : 0, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
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
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.accentColor.opacity(0.72), lineWidth: 1)
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
    let onSelect: () -> Void
    let onPaste: (PasteFormat) -> Void
    let onCopy: (PasteFormat) -> Void
    let onPin: (UUID) -> Void
    let onDelete: () -> Void

    var body: some View {
        ClipboardShelfCardVisual(item: item, imageDataProvider: imageDataProvider, isSelected: isSelected)
            .onTapGesture {
                onSelect()
            }
            .onTapGesture(count: 2) {
                onPaste(defaultPasteFormat)
            }
        .contextMenu {
            contextMenuContent
        }
        .onDrag {
            ClipboardItemDragProvider.provider(for: draggedItems)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("clipboard-shelf-card-\(item.id.uuidString)")
        .accessibilityLabel("\(item.title), \(localized(item.contentType.displayName))")
        .accessibilityValue(localized(isSelected ? "Selected" : "Not selected"))
        .accessibilityHint(localized("Press Return to paste."))
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

private struct HiddenScrollerHorizontalScrollView<Content: View>: NSViewRepresentable {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> HiddenScrollerHorizontalScrollContainer<Content> {
        HiddenScrollerHorizontalScrollContainer(rootView: content)
    }

    func updateNSView(_ nsView: HiddenScrollerHorizontalScrollContainer<Content>, context: Context) {
        nsView.rootView = content
    }
}

private final class HiddenScrollerHorizontalScrollContainer<Content: View>: NSView {
    private let scrollView = HiddenScrollerNSScrollView()
    private let hostingView: NSHostingView<Content>

    var rootView: Content {
        didSet {
            hostingView.rootView = rootView
            needsLayout = true
        }
    }

    init(rootView: Content) {
        self.rootView = rootView
        self.hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        configureScrollView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        hostingView.layoutSubtreeIfNeeded()

        let fittingSize = hostingView.fittingSize
        let documentSize = NSSize(
            width: max(bounds.width, fittingSize.width),
            height: max(bounds.height, fittingSize.height)
        )
        if hostingView.frame.size != documentSize {
            hostingView.frame = NSRect(origin: .zero, size: documentSize)
        }
        scrollView.clampHorizontalOffset()
    }

    private func configureScrollView() {
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.verticalScrollElasticity = .none
        scrollView.usesPredominantAxisScrolling = false
        scrollView.documentView = hostingView
        addSubview(scrollView)
    }
}

private final class HiddenScrollerNSScrollView: NSScrollView {
    private static let preciseScrollMultiplier: CGFloat = 1.25
    private static let wheelLineMultiplier: CGFloat = 64

    override func scrollWheel(with event: NSEvent) {
        let horizontalDelta = normalizedScrollDelta(event.scrollingDeltaX, for: event)
        let verticalDelta = normalizedScrollDelta(event.scrollingDeltaY, for: event)
        guard abs(verticalDelta) > abs(horizontalDelta), verticalDelta != 0 else {
            super.scrollWheel(with: event)
            return
        }

        scrollHorizontally(by: -verticalDelta)
    }

    private func normalizedScrollDelta(_ delta: CGFloat, for event: NSEvent) -> CGFloat {
        delta * (event.hasPreciseScrollingDeltas ? Self.preciseScrollMultiplier : Self.wheelLineMultiplier)
    }

    func clampHorizontalOffset() {
        guard let documentView else { return }

        let clipView = contentView
        let maxX = max(0, documentView.frame.width - clipView.bounds.width)
        let currentX = clipView.bounds.origin.x
        let nextX = min(max(currentX, 0), maxX)
        guard nextX != currentX else { return }

        clipView.scroll(to: NSPoint(x: nextX, y: clipView.bounds.origin.y))
        reflectScrolledClipView(clipView)
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
}

private struct ClipboardShelfCardVisual: View {
    let item: ClipboardItem
    let imageDataProvider: @MainActor (ClipboardItem) async -> Data?
    let isSelected: Bool

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(localized(item.contentType.displayName))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Text(relativeDate)
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
        .background(item.contentType.shelfTint)
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
        .overlay {
            RoundedRectangle(cornerRadius: ClipboardShelfMetrics.cardCornerRadius, style: .continuous)
                .strokeBorder(isSelected ? item.contentType.shelfTint : Color.white.opacity(0.24), lineWidth: isSelected ? 3 : 1)
        }
        .shadow(color: .black.opacity(0.10), radius: 8, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: ClipboardShelfMetrics.cardCornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var previewBody: some View {
        let preview = item.visualPreview

        if preview.prefersImageThumbnail {
            ShelfThumbnailView(item: item, imageDataProvider: imageDataProvider)
        } else {
            VStack(alignment: .leading, spacing: 9) {
                if item.contentType == .url {
                    Image(systemName: "link.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(item.contentType.shelfTint)
                }
                Text(preview.body)
                    .font(item.contentType == .text ? .callout.monospaced() : .callout)
                    .foregroundStyle(.primary)
                    .lineLimit(footerTitle == nil ? 4 : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(height: ClipboardShelfMetrics.cardPreviewHeight, alignment: .topLeading)
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
    }

    private var relativeDate: String {
        Self.relativeFormatter.localizedString(for: item.createdAt, relativeTo: Date())
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

private struct ClipboardShelfCardRenderSignature: Equatable {
    let id: UUID
    let createdAt: Date
    let updatedAt: Date
    let sourceAppName: String
    let sourceBundleIdentifier: String?
    let contentType: ClipboardContentType
    let title: String
    let ocrState: OCRState
    let textCount: Int?
    let htmlCount: Int?
    let rtfByteCount: Int?
    let urlString: String?
    let fileURLString: String?
    let fileURLStrings: [String]
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
        textCount = item.payload.text?.count
        htmlCount = item.payload.htmlString?.count
        rtfByteCount = item.payload.rtfData?.count
        urlString = item.payload.urlString
        fileURLString = item.payload.fileURLString
        fileURLStrings = item.payload.fileURLStrings
        imageByteCount = item.payload.imageData?.count
        ocrTextCount = item.payload.ocrText?.count
    }
}

private struct ShelfThumbnailView: View {
    let item: ClipboardItem
    let imageDataProvider: @MainActor (ClipboardItem) async -> Data?
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
                    .fill(item.contentType.shelfTint.opacity(0.10))
                Image(systemName: item.contentType.systemImageName)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(item.contentType.shelfTint)
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

private struct SourceApplicationIconBadge: View {
    let item: ClipboardItem

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
        .frame(width: 36, height: 36)
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

    private static func icon(forBundleIdentifier bundleIdentifier: String) -> NSImage? {
        if let image = runningApplicationIcon(bundleIdentifier: bundleIdentifier) {
            return image
        }

        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return icon(forApplicationURL: applicationURL)
    }

    private static func icon(forApplicationName appName: String) -> NSImage? {
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
                .clipShape(shape)
                .overlay(alignment: .top) {
                    if showsStroke {
                        Rectangle()
                            .fill(.white.opacity(0.30))
                            .frame(height: 1)
                    }
                }
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .clipShape(shape)
                .overlay(alignment: .top) {
                    if showsStroke {
                        Rectangle()
                            .fill(.white.opacity(0.30))
                            .frame(height: 1)
                    }
                }
        }
        #else
        self
            .background(.ultraThinMaterial, in: shape)
            .clipShape(shape)
            .overlay(alignment: .top) {
                if showsStroke {
                    Rectangle()
                        .fill(.white.opacity(0.30))
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
                .overlay {
                    if showsStroke {
                        shape.strokeBorder(.white.opacity(0.30), lineWidth: 1)
                    }
                }
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    if showsStroke {
                        shape.strokeBorder(.white.opacity(0.30), lineWidth: 1)
                    }
                }
        }
        #else
        self
            .background(.ultraThinMaterial, in: shape)
            .overlay {
                if showsStroke {
                    shape.strokeBorder(.white.opacity(0.30), lineWidth: 1)
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
