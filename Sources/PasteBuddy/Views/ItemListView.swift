import AppKit
import PasteBuddyCore
import SwiftUI

struct ItemListView: View {
    @Bindable var store: PasteBuddyStore
    let directPasteItem: (ClipboardItem, PasteFormat) -> DirectPasteResult
    let directPasteItems: ([ClipboardItem], PasteFormat) -> DirectPasteResult

    var body: some View {
        VStack(spacing: 0) {
            FilterBarView(store: store)
            Divider()
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
                ForEach(store.filteredItems) { item in
                    ClipboardItemRow(item: item)
                        .tag(item.id)
                        .onDrag {
                            ClipboardItemDragProvider.provider(for: draggableItems(for: item))
                        }
                        .contextMenu {
                            Button("Copy") {
                                PasteboardWriter.copy(item)
                            }
                            Button("Copy as Plain Text") {
                                PasteboardWriter.copy(item, format: .plainText)
                            }
                            Button("Paste to Active App") {
                                store.recordDirectPasteResult(
                                    directPasteItem(item, store.defaultPasteFormat)
                                )
                            }
                            Button("Paste as Plain Text") {
                                store.recordDirectPasteResult(
                                    directPasteItem(item, .plainText)
                                )
                            }
                            if let url = item.openableURL {
                                Button("Open") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            if store.selectedScope == .pasteStack {
                                Button("Remove from Paste Stack") {
                                    store.removeStackItem(item.id)
                                }
                            }
                            if case .pinboard(let pinboardID) = store.selectedScope {
                                Button("Remove from Pinboard") {
                                    store.removeItem(item.id, fromPinboard: pinboardID)
                                }
                            }
                            Divider()
                            if case .pinboard(let currentPinboardID) = store.selectedScope {
                                ForEach(store.snapshot.pinboards.filter { $0.id != currentPinboardID }) { pinboard in
                                    Button(String(format: localized("Move to %@"), pinboard.name)) {
                                        store.movePinboardItem(item.id, from: currentPinboardID, to: pinboard.id)
                                    }
                                }
                            } else {
                                ForEach(store.snapshot.pinboards) { pinboard in
                                    Button(String(format: localized("Pin to %@"), pinboard.name)) {
                                        store.pinItem(item.id, to: pinboard.id)
                                    }
                                }
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
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
            if store.filteredItems.isEmpty {
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
                    store.recordDirectPasteResult(
                        directPasteItems(store.selectedItemsInDisplayOrder, store.defaultPasteFormat)
                    )
                } label: {
                    Label(pasteTitle, systemImage: "arrow.down.doc")
                }
                .disabled(!hasSelectedItems)

                Menu {
                    Button {
                        store.recordDirectPasteResult(
                            directPasteItems(store.selectedItemsInDisplayOrder, .plainText)
                        )
                    } label: {
                        Label("Plain Text Paste", systemImage: "textformat")
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
                                store.recordDirectPasteResult(
                                    directPasteItem(item, store.defaultPasteFormat)
                                )
                            }
                        } label: {
                            Label("Paste Next", systemImage: "forward.end")
                        }
                        .disabled(store.pasteStackItems.isEmpty)

                        Button {
                            store.reversePasteStackDirection()
                        } label: {
                            Label("Reverse", systemImage: "arrow.up.arrow.down")
                        }
                        .disabled(store.pasteStackItems.isEmpty)

                        Button(role: .destructive) {
                            store.clearPasteStack()
                        } label: {
                            Label("Clear Stack", systemImage: "trash")
                        }
                        .disabled(store.pasteStackItems.isEmpty)
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .disabled(!hasSelectedItems && !hasPasteStackActions)
            }
        }
    }

    private var title: String {
        switch store.selectedScope {
        case .history:
            localized("History")
        case .pasteStack:
            store.isPasteStackActive ? localized("Paste Stack - Collecting") : localized("Paste Stack")
        case .pinboard(let id):
            store.snapshot.pinboards.first(where: { $0.id == id })?.name ?? localized("Pinboard")
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
        store.hasMultipleSelectedItems ? localized("Copy Selected") : localized("Copy")
    }

    private var hasSelectedItems: Bool {
        !store.selectedItemsInDisplayOrder.isEmpty
    }

    private var hasPasteStackActions: Bool {
        store.selectedScope == .pasteStack && !store.pasteStackItems.isEmpty
    }

    private var pasteTitle: String {
        store.hasMultipleSelectedItems ? localized("Paste Selected") : localized("Paste")
    }

    private var deleteTitle: String {
        store.hasMultipleSelectedItems ? localized("Delete Selected") : localized("Delete")
    }

    private var reorderHint: String {
        store.canReorderCurrentPinboard ? localized("Drag to reorder items.") : emptyDescription
    }

    private var emptyTitle: String {
        store.selectedScope == .pasteStack ? localized("Paste Stack is Empty") : localized("No Clipboard Items")
    }

    private var emptySystemImage: String {
        store.selectedScope == .pasteStack ? "tray" : "doc.on.clipboard"
    }

    private var emptyDescription: String {
        if store.selectedScope == .pasteStack {
            return store.isPasteStackActive ? localized("Collecting new copies") : localized("Stack collection paused")
        }
        return localized("Copy text, links, images, or files to start building local history.")
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
                Label("Paste Order", systemImage: "list.number")
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
                Label("Multiple selected items paste as plain text in this visible order, keeping mixed content predictable.", systemImage: "textformat")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Paste order preview")
    }
}

private struct PasteStackPreviewBar: View {
    let preview: PasteStackPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label("Paste Stack", systemImage: "tray.full")
                    .font(.caption.weight(.semibold))
                Text("\(preview.rows.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Items")
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
                    Label("Next", systemImage: "forward.end")
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
        .accessibilityLabel("Paste stack preview")
    }

    @ViewBuilder
    private var collectionStatusLabel: some View {
        if preview.isCollecting {
            Label("Collecting", systemImage: "record.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label("Paused", systemImage: "pause.circle")
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
                format: NSLocalizedString("Paste item %d, %@, %@", comment: ""),
                row.position,
                row.title,
                NSLocalizedString(row.contentType.displayName, comment: "")
            )
        )
    }
}

struct ClipboardItemRow: View {
    let item: ClipboardItem

    var body: some View {
        let preview = item.visualPreview

        HStack(alignment: .top, spacing: 12) {
            ClipboardPreviewTile(item: item, preview: preview)

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
        .accessibilityHint(NSLocalizedString("Select to preview or use the context menu for copy, paste, pin, and delete actions.", comment: ""))
    }

    private var accessibilityTitle: String {
        let contentType = NSLocalizedString(item.contentType.displayName, comment: "")
        let reuseCategory = NSLocalizedString(item.reuseCategory.displayName, comment: "")
        let labels = item.labels.isEmpty
            ? ""
            : String(format: NSLocalizedString(", labels: %@", comment: ""), item.labels.joined(separator: ", "))
        return "\(item.title), \(contentType), \(reuseCategory)\(labels)"
    }

    private var accessibilityValue: String {
        "\(item.sourceAppName), \(item.deviceName), \(item.createdAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct ClipboardPreviewTile: View {
    let item: ClipboardItem
    let preview: ClipboardVisualPreview

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(backgroundStyle)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.quaternary)
                }

            if preview.prefersImageThumbnail,
               let data = item.payload.imageData,
               let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
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
