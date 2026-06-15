import CoreTransferable
import PasteBuddyCore
import SwiftUI
import UniformTypeIdentifiers

public struct MobileClipboardBrowserView: View {
    @Bindable private var store: PasteBuddyStore
    @State private var selectedItem: ClipboardItem?
    @State private var sharingRoute: MobilePinboardSharingRoute?
    @State private var previewRoute: MobilePreviewRoute?
    @State private var isShowingTextEntry = false

    public init(store: PasteBuddyStore) {
        self.store = store
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: scopeBinding) {
                Section("Library") {
                    Label("History", systemImage: "clock.arrow.circlepath")
                        .tag(PasteScope.history)
                    Label("Paste Stack", systemImage: "tray")
                        .tag(PasteScope.pasteStack)
                }

                Section("Pinboards") {
                    ForEach(store.snapshot.pinboards) { pinboard in
                        pinboardLabel(pinboard)
                    }
                }

                Section("Setup") {
                    NavigationLink {
                        MobileOnboardingGuidanceView(report: store.mobileGuidanceReport)
                            .navigationTitle("Mobile Setup")
                    } label: {
                        Label("Mobile Setup", systemImage: store.mobileGuidanceReport.needsUserAction ? "exclamationmark.circle" : "checkmark.circle")
                    }
                    Text(store.mobileGuidanceReport.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("PasteBuddy")
        } content: {
            VStack(spacing: 0) {
                MobileActiveFilterBar(store: store)

                List(store.filteredItems, selection: itemSelectionBinding) { item in
                    MobileClipboardItemRow(item: item)
                        .tag(Optional(item.id))
                        .draggable(MobilePinboardItemDragPayload(ids: [item.id]))
                        .contextMenu {
                            Button {
                                previewRoute = MobilePreviewRoute(item: item)
                            } label: {
                                Label("Preview", systemImage: "rectangle.expand.vertical")
                            }

                            Button {
                                MobilePasteboardWriter.copy(item)
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }

                            Button {
                                MobilePasteboardWriter.copy(item, format: .plainText)
                            } label: {
                                Label("Copy Plain Text", systemImage: "textformat")
                            }

                            if !store.snapshot.pinboards.isEmpty {
                                Divider()
                                Menu {
                                    ForEach(store.snapshot.pinboards) { pinboard in
                                        Button(pinboard.name) {
                                            store.pinItem(item.id, to: pinboard.id)
                                        }
                                    }
                                } label: {
                                    Label("Pin to Pinboard", systemImage: "pin")
                                }
                            }

                            if case .pinboard(let pinboardID) = store.selectedScope {
                                Button(role: .destructive) {
                                    store.removeItem(item.id, fromPinboard: pinboardID)
                                } label: {
                                    Label("Remove from Pinboard", systemImage: "pin.slash")
                                }
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                MobilePasteboardWriter.copy(item, format: .plainText)
                            } label: {
                                Label("Plain", systemImage: "textformat")
                            }

                            Button {
                                MobilePasteboardWriter.copy(item)
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                        }
                }
            }
            .navigationTitle(navigationTitle)
            .searchable(text: $store.searchQuery, prompt: "Search clipboard")
            .searchSuggestions {
                ForEach(store.filterSuggestions) { suggestion in
                    Button {
                        store.applyFilterSuggestion(suggestion)
                    } label: {
                        Label(suggestion.title, systemImage: suggestion.systemImageName)
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        isShowingTextEntry = true
                    } label: {
                        Label("New Text", systemImage: "square.and.pencil")
                    }

                    Menu {
                        Picker("Type", selection: $store.contentTypeFilter) {
                            Text("Any Type").tag(nil as ClipboardContentType?)
                            ForEach(ClipboardContentType.allCases) { type in
                                Text(type.displayName).tag(Optional(type))
                            }
                        }
                        Picker("Date", selection: $store.dateFilter) {
                            ForEach(ClipboardDateFilter.allCases) { filter in
                                Text(filter.displayName).tag(filter)
                            }
                        }
                        Button("Clear Filters") {
                            store.clearFilters()
                        }
                        .disabled(!store.hasActiveFilters)

                        Picker("Source App", selection: $store.sourceAppFilter) {
                            Text("Any App").tag(nil as String?)
                            ForEach(store.availableSourceApps, id: \.self) { app in
                                Text(app).tag(Optional(app))
                            }
                        }

                        Picker("Device", selection: $store.deviceFilter) {
                            Text("Any Device").tag(nil as String?)
                            ForEach(store.availableDevices, id: \.self) { device in
                                Text(device).tag(Optional(device))
                            }
                        }
                    } label: {
                        Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                    }

                    if let selectedItem {
                        Button {
                            previewRoute = MobilePreviewRoute(item: selectedItem)
                        } label: {
                            Label("Full Screen Preview", systemImage: "rectangle.expand.vertical")
                        }
                    }

                    if case .pinboard(let pinboardID) = store.selectedScope {
                        Button {
                            sharingRoute = MobilePinboardSharingRoute(id: pinboardID)
                        } label: {
                            Label("Share Pinboard", systemImage: "person.2.badge.plus")
                        }
                    }
                }
            }
        } detail: {
            if let selectedItem {
                MobileClipboardItemDetailView(item: selectedItem)
            } else {
                ContentUnavailableView("Select an Item", systemImage: "doc.on.clipboard")
            }
        }
        .sheet(item: $sharingRoute) { route in
            MobilePinboardSharingView(store: store, pinboardID: route.id)
        }
        .sheet(isPresented: $isShowingTextEntry) {
            MobileTextEntryView(store: store)
        }
        .mobilePreviewPresentation(previewRoute: $previewRoute)
    }

    private func pinboardLabel(_ pinboard: Pinboard) -> some View {
        Label(pinboard.name, systemImage: "pin")
            .tag(PasteScope.pinboard(pinboard.id))
            .dropDestination(for: MobilePinboardItemDragPayload.self) { payloads, _ in
                let itemIDs = payloads.flatMap(\.ids)
                guard !itemIDs.isEmpty else { return false }
                store.pinItems(itemIDs, to: pinboard.id)
                return true
            }
    }

    private var navigationTitle: String {
        switch store.selectedScope {
        case .history:
            "History"
        case .pasteStack:
            "Paste Stack"
        case .pinboard(let id):
            store.snapshot.pinboards.first(where: { $0.id == id })?.name ?? "Pinboard"
        }
    }

    private var scopeBinding: Binding<PasteScope?> {
        Binding(
            get: { store.selectedScope },
            set: { newValue in
                if let newValue {
                    store.selectedScope = newValue
                }
            }
        )
    }

    private var itemSelectionBinding: Binding<UUID?> {
        Binding(
            get: { selectedItem?.id ?? store.selectedItemID },
            set: { newID in
                store.selectSingleItem(newID)
                selectedItem = newID.flatMap { id in
                    store.filteredItems.first(where: { $0.id == id })
                }
            }
        )
    }
}

private struct MobilePinboardSharingRoute: Identifiable {
    let id: UUID
}

private struct MobilePreviewRoute: Identifiable {
    let item: ClipboardItem

    var id: UUID { item.id }
}

private struct MobileTextEntryView: View {
    @Bindable var store: PasteBuddyStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Content") {
                    TextField("Title", text: $title)
                    TextEditor(text: $text)
                        .frame(minHeight: 180)
                }
            }
            .navigationTitle("New Text")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = store.createTextItem(
            text: text,
            title: trimmedTitle.isEmpty ? nil : trimmedTitle,
            sourceAppName: "PasteBuddy iOS"
        )
        dismiss()
    }
}

private extension View {
    @ViewBuilder
    func mobilePreviewPresentation(previewRoute: Binding<MobilePreviewRoute?>) -> some View {
        #if os(iOS)
        fullScreenCover(item: previewRoute) { route in
            MobilePreviewNavigation(item: route.item, previewRoute: previewRoute)
        }
        #else
        sheet(item: previewRoute) { route in
            MobilePreviewNavigation(item: route.item, previewRoute: previewRoute)
        }
        #endif
    }
}

private struct MobilePreviewNavigation: View {
    let item: ClipboardItem
    @Binding var previewRoute: MobilePreviewRoute?

    var body: some View {
        NavigationStack {
            MobileClipboardItemDetailView(item: item, isFullScreen: true)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            previewRoute = nil
                        }
                    }
                }
        }
    }
}

private struct MobileActiveFilterBar: View {
    @Bindable var store: PasteBuddyStore

    var body: some View {
        if !store.activeFilterSummaries.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.activeFilterSummaries) { summary in
                        Button {
                            store.clearFilter(summary.kind)
                        } label: {
                            Label(summary.title, systemImage: "xmark.circle.fill")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(summary.title)")
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(.bar)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Active clipboard filters")
        }
    }
}

private struct MobileClipboardItemRow: View {
    let item: ClipboardItem

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(item.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Label(item.reuseCategory.displayName, systemImage: item.reuseCategory.systemImageName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !item.labels.isEmpty {
                    Text(item.labels.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(item.sourceAppName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        } icon: {
            Image(systemName: iconName)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(item.sourceAppName)
    }

    private var accessibilityTitle: String {
        let labels = item.labels.isEmpty ? "" : ", labels: \(item.labels.joined(separator: ", "))"
        return "\(item.title), \(item.contentType.displayName), \(item.reuseCategory.displayName)\(labels)"
    }

    private var iconName: String {
        switch item.contentType {
        case .text: "text.alignleft"
        case .url: "link"
        case .image: "photo"
        case .file: "doc"
        case .mixed: "square.stack.3d.up"
        }
    }
}

private struct MobileClipboardItemDetailView: View {
    let item: ClipboardItem
    var isFullScreen = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(item.title)
                    .font(isFullScreen ? .largeTitle.bold() : .title2.bold())
                    .lineLimit(3)

                MobileVisualPreviewSummary(item: item)

                Text(ClipboardPlainTextRenderer.plainText(for: item))
                    .font(.body)
                    .textSelection(.enabled)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Type")
                            .foregroundStyle(.secondary)
                        Text(item.contentType.displayName)
                    }
                    GridRow {
                        Text("Source")
                            .foregroundStyle(.secondary)
                        Text(item.sourceAppName)
                    }
                    GridRow {
                        Text("Device")
                            .foregroundStyle(.secondary)
                        Text(item.deviceName)
                    }
                    GridRow {
                        Text("Category")
                            .foregroundStyle(.secondary)
                        Text(item.reuseCategory.displayName)
                    }
                    if !item.labels.isEmpty {
                        GridRow {
                            Text("Labels")
                                .foregroundStyle(.secondary)
                            Text(item.labels.joined(separator: ", "))
                        }
                    }
                }
                .font(.callout)

                HStack(spacing: 12) {
                    Button {
                        MobilePasteboardWriter.copy(item)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }

                    Button {
                        MobilePasteboardWriter.copy(item, format: .plainText)
                    } label: {
                        Label("Plain Text", systemImage: "textformat")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("Preview")
    }
}

private struct MobileVisualPreviewSummary: View {
    let item: ClipboardItem

    var body: some View {
        let preview = item.visualPreview
        VStack(alignment: .leading, spacing: 6) {
            Label(preview.badgeText, systemImage: preview.systemImageName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(preview.headline)
                .font(.headline)
            Text(preview.body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let detail = preview.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
