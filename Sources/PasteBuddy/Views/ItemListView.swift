import AppKit
import PasteBuddyCore
import SwiftUI

struct ItemListView: View {
    @Bindable var store: PasteBuddyStore
    let directPasteItem: @MainActor (ClipboardItem, PasteFormat) async -> DirectPasteResult
    let directPasteItems: @MainActor ([ClipboardItem], PasteFormat) async -> DirectPasteResult

    var body: some View {
        let items = store.mainListItemsSnapshot

        VStack(spacing: 0) {
            if store.selectedScope == .pasteStack {
                if let preview = store.pasteStackPreview {
                    PasteStackPreviewBar(preview: preview)
                    Divider()
                }
            } else if let preview = store.selectedPasteOrderPreview {
                PasteOrderPreviewBar(preview: preview)
                Divider()
            }
            List(selection: selectedIDsBinding) {
                ForEach(items) { item in
                    ClipboardItemRow(item: item, imageDataProvider: store.imageData)
                        .tag(item.id)
                        .onDrag {
                            ClipboardItemDragProvider.provider(for: draggableItems(for: item))
                        }
                        .contextMenu {
                            Button("action.copy") {
                                PasteboardWriter.copy(item)
                            }
                            Button("action.copy_as_plain_text") {
                                PasteboardWriter.copy(item, format: .plainText)
                            }
                            Button("action.paste_to_active_app") {
                                pasteItem(item, format: store.defaultPasteFormat)
                            }
                            Button("action.paste_as_plain_text") {
                                pasteItem(item, format: .plainText)
                            }
                            if let url = item.openableURL {
                                Button("action.open") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            if store.selectedScope == .pasteStack {
                                Button("action.remove_from_paste_stack") {
                                    store.removeStackItem(item.id)
                                }
                            }
                            if case .pinboard(let pinboardID) = store.selectedScope {
                                Button("action.remove_from_pinboard") {
                                    store.removeItem(item.id, fromPinboard: pinboardID)
                                }
                            }
                            Divider()
                            if case .pinboard(let currentPinboardID) = store.selectedScope {
                                ForEach(store.snapshot.pinboards.filter { $0.id != currentPinboardID }) { pinboard in
                                    Button(String(format: localized("format.move_to"), pinboard.name)) {
                                        store.movePinboardItem(item.id, from: currentPinboardID, to: pinboard.id)
                                    }
                                }
                            } else {
                                ForEach(store.snapshot.pinboards) { pinboard in
                                    Button(String(format: localized("format.pin_to"), pinboard.name)) {
                                        store.pinItem(item.id, to: pinboard.id)
                                    }
                                }
                            }
                            Divider()
                            Button("action.delete", role: .destructive) {
                                store.removeItem(item.id)
                            }
                        }
                }
                .onMove { offsets, offset in
                    if case .pinboard(let pinboardID) = store.selectedScope,
                       store.canReorderCurrentPinboard {
                        store.moveItems(inPinboard: pinboardID, fromOffsets: offsets, toOffset: offset)
                    }
                }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: emptySystemImage, description: Text(emptyDescription))
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    PasteboardWriter.copy(store.selectedItemsInDisplayOrder)
                } label: {
                    Label(copyTitle, systemImage: "doc.on.doc")
                }
                .disabled(!hasSelectedItems)

                Button {
                    pasteSelectedItems(format: store.defaultPasteFormat)
                } label: {
                    Label(pasteTitle, systemImage: "arrow.down.doc")
                }
                .disabled(!hasSelectedItems)

                Menu {
                    Button {
                        pasteSelectedItems(format: .plainText)
                    } label: {
                        Label("label.plain_text_paste", systemImage: "textformat")
                    }
                    .disabled(!hasSelectedItems)

                    Button(role: .destructive) {
                        store.removeSelectedItems()
                    } label: {
                        Label(deleteTitle, systemImage: "trash")
                    }
                    .disabled(!hasSelectedItems)

                    if store.selectedScope == .pasteStack {
                        Divider()

                        Button {
                            if let item = store.pasteNextStackItem() {
                                pasteItem(item, format: store.defaultPasteFormat)
                            }
                        } label: {
                            Label("action.paste_next", systemImage: "forward.end")
                        }
                        .disabled(store.pasteStackItems.isEmpty)

                        Button {
                            store.reversePasteStackDirection()
                        } label: {
                            Label("action.reverse", systemImage: "arrow.up.arrow.down")
                        }
                        .disabled(store.pasteStackItems.isEmpty)

                        Button(role: .destructive) {
                            store.clearPasteStack()
                        } label: {
                            Label("action.clear_stack", systemImage: "trash")
                        }
                        .disabled(store.pasteStackItems.isEmpty)
                    }
                } label: {
                    Label("label.more", systemImage: "ellipsis.circle")
                }
                .disabled(!hasSelectedItems && !hasPasteStackActions)
            }
        }
    }

    private var title: String {
        switch store.selectedScope {
        case .history:
            localized("label.history")
        case .pasteStack:
            store.isPasteStackActive ? localized("action.paste_stack_collecting") : localized("action.paste_stack")
        case .pinboard(let id):
            store.snapshot.pinboards.first(where: { $0.id == id })?.name ?? localized("label.pinboard")
        }
    }

    private func pasteItem(_ item: ClipboardItem, format: PasteFormat) {
        Task { @MainActor in
            let result = await directPasteItem(item, format)
            store.recordDirectPasteResult(result)
        }
    }

    private func pasteSelectedItems(format: PasteFormat) {
        let items = store.selectedItemsInDisplayOrder
        guard !items.isEmpty else { return }
        Task { @MainActor in
            let result = await directPasteItems(items, format)
            store.recordDirectPasteResult(result)
        }
    }

    private var selectedIDsBinding: Binding<Set<UUID>> {
        Binding(
            get: { store.selectedItemIDs },
            set: { store.setSelectedItemIDs($0) }
        )
    }

    private func draggableItems(for item: ClipboardItem) -> [ClipboardItem] {
        let selectedItems = store.selectedItemsInDisplayOrder
        if selectedItems.contains(where: { $0.id == item.id }) {
            return selectedItems
        }
        return [item]
    }

    private var copyTitle: String {
        store.hasMultipleSelectedItems ? localized("action.copy_selected") : localized("action.copy")
    }

    private var hasSelectedItems: Bool {
        !store.selectedItemsInDisplayOrder.isEmpty
    }

    private var hasPasteStackActions: Bool {
        store.selectedScope == .pasteStack && !store.pasteStackItems.isEmpty
    }

    private var pasteTitle: String {
        store.hasMultipleSelectedItems ? localized("action.paste_selected") : localized("action.paste")
    }

    private var deleteTitle: String {
        store.hasMultipleSelectedItems ? localized("action.delete_selected") : localized("action.delete")
    }

    private var reorderHint: String {
        store.canReorderCurrentPinboard ? localized("message.drag_to_reorder_items") : emptyDescription
    }

    private var emptyTitle: String {
        store.selectedScope == .pasteStack ? localized("action.paste_stack_is_empty") : localized("label.no_clipboard_items")
    }

    private var emptySystemImage: String {
        store.selectedScope == .pasteStack ? "tray" : "doc.on.clipboard"
    }

    private var emptyDescription: String {
        if store.selectedScope == .pasteStack {
            return store.isPasteStackActive ? localized("label.collecting_new_copies") : localized("label.stack_collection_paused")
        }
        return localized("message.copy_text_links_images_or_files_to")
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}

private struct PasteOrderPreviewBar: View {
    let preview: PasteOrderPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("action.paste_order", systemImage: "list.number")
                    .font(.caption.weight(.semibold))
                Text("\(preview.rows.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(preview.rows) { row in
                        PasteOrderChip(row: row)
                    }
                }
            }
            .scrollIndicators(.hidden)

            if preview.fallbackDescription != nil {
                Label("message.multiple_selected_items_paste_as_plain_text", systemImage: "textformat")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("action.paste_order_preview")
    }
}

private struct PasteStackPreviewBar: View {
    let preview: PasteStackPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label("action.paste_stack", systemImage: "tray.full")
                    .font(.caption.weight(.semibold))
                Text("\(preview.rows.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("label.items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                collectionStatusLabel
                Label(directionTitle, systemImage: "arrow.up.arrow.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(preview.rows) { row in
                        PasteOrderChip(row: row)
                    }
                }
            }
            .scrollIndicators(.hidden)

            if let nextRow = preview.nextRow {
                HStack(spacing: 6) {
                    Label("label.next", systemImage: "forward.end")
                        .font(.caption.weight(.semibold))
                    Text(nextRow.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("action.paste_stack_preview")
    }

    @ViewBuilder
    private var collectionStatusLabel: some View {
        if preview.isCollecting {
            Label("label.collecting", systemImage: "record.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label("label.paused", systemImage: "pause.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var directionTitle: LocalizedStringKey {
        switch preview.direction {
        case .topToBottom:
            "Top to Bottom"
        case .bottomToTop:
            "Bottom to Top"
        }
    }
}

private struct PasteOrderChip: View {
    let row: PasteOrderPreviewRow

    var body: some View {
        HStack(spacing: 6) {
            Text("\(row.position)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor))

            Image(systemName: row.contentType.systemImageName)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(row.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: 150, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(
                format: NSLocalizedString("format.paste_item", comment: ""),
                row.position,
                row.title,
                NSLocalizedString(row.contentType.displayName, comment: "")
            )
        )
    }
}

struct ClipboardItemRow: View {
    let item: ClipboardItem
    let imageDataProvider: @MainActor (ClipboardItem) async -> Data?

    var body: some View {
        let preview = item.visualPreview

        HStack(alignment: .top, spacing: 12) {
            ClipboardPreviewTile(item: item, preview: preview, imageDataProvider: imageDataProvider)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(preview.headline)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Label(NSLocalizedString(preview.badgeText, comment: ""), systemImage: preview.systemImageName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(preview.body)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let detail = preview.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    MetadataChip(systemImageName: "app", text: item.sourceAppName)
                    MetadataChip(systemImageName: "clock", text: item.createdAt.formatted(date: .omitted, time: .shortened))
                    MetadataChip(systemImageName: "desktopcomputer", text: item.deviceName)
                }
                .lineLimit(1)

                if !item.labels.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(item.labels, id: \.self) { label in
                                MetadataChip(systemImageName: "tag", text: label)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .frame(minHeight: 76, alignment: .top)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(NSLocalizedString("message.select_to_preview_or_use_the_context", comment: ""))
    }

    private var accessibilityTitle: String {
        let contentType = NSLocalizedString(item.contentType.displayName, comment: "")
        let reuseCategory = NSLocalizedString(item.reuseCategory.displayName, comment: "")
        let labels = item.labels.isEmpty
            ? ""
            : String(format: NSLocalizedString("format.labels", comment: ""), item.labels.joined(separator: ", "))
        return "\(item.title), \(contentType), \(reuseCategory)\(labels)"
    }

    private var accessibilityValue: String {
        "\(item.sourceAppName), \(item.deviceName), \(item.createdAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct ClipboardPreviewTile: View {
    let item: ClipboardItem
    let preview: ClipboardVisualPreview
    let imageDataProvider: @MainActor (ClipboardItem) async -> Data?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(backgroundStyle)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.quaternary)
                }

            if preview.prefersImageThumbnail {
                ClipboardPreviewThumbnail(item: item, imageDataProvider: imageDataProvider)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: preview.systemImageName)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(tileText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.72)
                }
                .padding(6)
            }
        }
        .frame(width: 64, height: 56)
        .accessibilityHidden(true)
    }

    private var backgroundStyle: some ShapeStyle {
        switch item.contentType {
        case .text:
            AnyShapeStyle(Color(nsColor: .textBackgroundColor))
        case .url:
            AnyShapeStyle(Color.blue.opacity(0.10))
        case .image:
            AnyShapeStyle(Color.green.opacity(0.10))
        case .file:
            AnyShapeStyle(Color.orange.opacity(0.10))
        case .mixed:
            AnyShapeStyle(Color.purple.opacity(0.10))
        }
    }

    private var tileText: String {
        switch item.contentType {
        case .text:
            nonEmpty(item.payload.text?.singleLinePreview) ?? "Text"
        case .url:
            nonEmpty(URL(string: item.payload.urlString ?? "")?.host) ?? "Link"
        case .file:
            item.payload.allFileURLStrings.first.flatMap { nonEmpty(URL(string: $0)?.lastPathComponent) } ?? "File"
        case .image:
            "Image"
        case .mixed:
            "Mixed"
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

private struct ClipboardPreviewThumbnail: View {
    private static let maxPixelSize = 160
    let item: ClipboardItem
    let imageDataProvider: @MainActor (ClipboardItem) async -> Data?
    @State private var thumbnail: NSImage?
    @State private var loadedImageData: Data?

    var body: some View {
        ZStack {
            if let image = thumbnail ?? ClipboardImageCache.cachedThumbnail(
                for: item,
                imageData: loadedImageData,
                maxPixelSize: Self.maxPixelSize
            ) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: item.contentType.systemImageName)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 64, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
        .task(id: ClipboardImageCache.thumbnailCacheKey(for: item, maxPixelSize: Self.maxPixelSize)) {
            thumbnail = ClipboardImageCache.cachedThumbnail(
                for: item,
                imageData: loadedImageData,
                maxPixelSize: Self.maxPixelSize
            )
            guard thumbnail == nil else { return }

            let imageData: Data?
            if let loadedImageData {
                imageData = loadedImageData
            } else {
                imageData = await imageDataProvider(item)
            }
            loadedImageData = imageData
            let loadedThumbnail = await ClipboardImageCache.thumbnail(
                for: item,
                imageData: imageData,
                maxPixelSize: Self.maxPixelSize
            )
            guard !Task.isCancelled else { return }
            thumbnail = loadedThumbnail
        }
    }
}

private struct MetadataChip: View {
    let systemImageName: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImageName)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}
