import CoreTransferable
import PasteBuddyCore
import SwiftUI
import UniformTypeIdentifiers

public struct MobileClipboardBrowserView: View {
    @Bindable private var store: PasteBuddyStore
    private let onCloudSyncConfigurationChanged: () -> Void
    @State private var sharingRoute: MobilePinboardSharingRoute?
    @State private var previewRoute: MobilePreviewRoute?

    public init(
        store: PasteBuddyStore,
        onCloudSyncConfigurationChanged: @escaping () -> Void = {}
    ) {
        self.store = store
        self.onCloudSyncConfigurationChanged = onCloudSyncConfigurationChanged
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: scopeBinding) {
                Section("label.library") {
                    Label("label.history", systemImage: "clock.arrow.circlepath")
                        .tag(PasteScope.history)
                    Label("action.paste_stack", systemImage: "tray")
                        .tag(PasteScope.pasteStack)
                }

                Section("label.pinboards") {
                    ForEach(store.snapshot.pinboards) { pinboard in
                        pinboardLabel(pinboard)
                    }
                }

                Section("label.setup") {
                    NavigationLink {
                        MobileICloudClipboardSyncView(
                            store: store,
                            onChanged: onCloudSyncConfigurationChanged
                        )
                            .navigationTitle("label.icloud_clipboard_sync")
                    } label: {
                        Label(
                            "label.icloud_clipboard_sync",
                            systemImage: store.snapshot.sync.isCloudSyncEnabled ? "icloud.fill" : "icloud"
                        )
                    }

                    NavigationLink {
                        MobileOnboardingGuidanceView(report: store.mobileGuidanceReport)
                            .navigationTitle("label.mobile_setup")
                    } label: {
                        Label("label.mobile_setup", systemImage: store.mobileGuidanceReport.needsUserAction ? "exclamationmark.circle" : "checkmark.circle")
                    }
                    Text(store.mobileGuidanceReport.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("brand.pastebuddy")
        } content: {
            VStack(spacing: 0) {
                MobileActiveFilterBar(store: store)

                List(store.filteredItems, selection: itemSelectionBinding) { item in
                    MobileClipboardItemRow(item: item)
                        .tag(Optional(item.id))
                        .draggable(MobilePinboardItemDragPayload(ids: [item.id]))
                        .contextMenu {
                            Button {
                                previewRoute = MobilePreviewRoute(id: item.id)
                            } label: {
                                Label("label.preview", systemImage: "rectangle.expand.vertical")
                            }

                            Button {
                                MobilePasteboardWriter.copy(item)
                            } label: {
                                Label("action.copy", systemImage: "doc.on.doc")
                            }

                            Button {
                                MobilePasteboardWriter.copy(item, format: .plainText)
                            } label: {
                                Label("action.copy_plain_text", systemImage: "textformat")
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
                                    Label("action.pin_to_pinboard", systemImage: "pin")
                                }
                            }

                            if case .pinboard(let pinboardID) = store.selectedScope {
                                Button(role: .destructive) {
                                    store.removeItem(item.id, fromPinboard: pinboardID)
                                } label: {
                                    Label("action.remove_from_pinboard", systemImage: "pin.slash")
                                }
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                MobilePasteboardWriter.copy(item, format: .plainText)
                            } label: {
                                Label("label.plain", systemImage: "textformat")
                            }

                            Button {
                                MobilePasteboardWriter.copy(item)
                            } label: {
                                Label("action.copy", systemImage: "doc.on.doc")
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
                    Menu {
                        Picker("label.type", selection: $store.contentTypeFilter) {
                            Text("label.any_type").tag(nil as ClipboardContentType?)
                            ForEach(ClipboardContentType.allCases) { type in
                                Text(type.displayName).tag(Optional(type))
                            }
                        }
                        Picker("label.date", selection: $store.dateFilter) {
                            ForEach(ClipboardDateFilter.allCases) { filter in
                                Text(filter.displayName).tag(filter)
                            }
                        }
                        Button("action.clear_filters") {
                            store.clearFilters()
                        }
                        .disabled(!store.hasActiveFilters)

                        Picker("label.source_app", selection: $store.sourceAppFilter) {
                            Text("label.any_app").tag(nil as String?)
                            ForEach(store.availableSourceApps, id: \.self) { app in
                                Text(app).tag(Optional(app))
                            }
                        }

                        Picker("label.device", selection: $store.deviceFilter) {
                            Text("label.any_device").tag(nil as String?)
                            ForEach(store.availableDevices, id: \.self) { device in
                                Text(device).tag(Optional(device))
                            }
                        }
                    } label: {
                        Label("label.filters", systemImage: "line.3.horizontal.decrease.circle")
                    }

                    if let selectedItem {
                        Button {
                            previewRoute = MobilePreviewRoute(id: selectedItem.id)
                        } label: {
                            Label("label.full_screen_preview", systemImage: "rectangle.expand.vertical")
                        }
                    }

                    if case .pinboard(let pinboardID) = store.selectedScope {
                        Button {
                            sharingRoute = MobilePinboardSharingRoute(id: pinboardID)
                        } label: {
                            Label("action.share_pinboard", systemImage: "person.2.badge.plus")
                        }
                    }
                }
            }
        } detail: {
            if let selectedItem {
                MobileClipboardItemDetailView(item: selectedItem)
            } else {
                ContentUnavailableView("label.select_an_item", systemImage: "doc.on.clipboard")
            }
        }
        .sheet(item: $sharingRoute) { route in
            MobilePinboardSharingView(store: store, pinboardID: route.id)
        }
        .mobilePreviewPresentation(previewRoute: $previewRoute, itemProvider: clipboardItem)
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
            get: { selectedItem?.id },
            set: { newID in
                store.selectSingleItem(newID)
            }
        )
    }

    private var selectedItem: ClipboardItem? {
        store.selectedItemID.flatMap { id in
            store.filteredItems.first { $0.id == id }
        }
    }

    private func clipboardItem(for id: UUID) -> ClipboardItem? {
        store.filteredItems.first { $0.id == id }
            ?? store.pasteStackItems.first { $0.id == id }
            ?? store.item(withID: id)
    }
}

private struct MobilePinboardSharingRoute: Identifiable {
    let id: UUID
}

private struct MobilePreviewRoute: Identifiable {
    let id: UUID
}

private struct MobileICloudClipboardSyncView: View {
    @Bindable var store: PasteBuddyStore
    let onChanged: () -> Void

    var body: some View {
        Form {
            Section {
                Toggle("label.enable_icloud_sync", isOn: cloudSyncBinding)
                if let status = store.snapshot.sync.lastSyncStatusMessage ?? store.lastErrorMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("message.icloud_clipboard_sync_private_database")
            }
        }
    }

    private var cloudSyncBinding: Binding<Bool> {
        Binding(
            get: { store.snapshot.sync.isCloudSyncEnabled },
            set: { isEnabled in
                CloudKitClipboardSyncSession.setEnabled(isEnabled, on: store)
                onChanged()
            }
        )
    }
}

private extension View {
    @ViewBuilder
    func mobilePreviewPresentation(
        previewRoute: Binding<MobilePreviewRoute?>,
        itemProvider: @escaping (UUID) -> ClipboardItem?
    ) -> some View {
        #if os(iOS)
        fullScreenCover(item: previewRoute) { route in
            if let item = itemProvider(route.id) {
                MobilePreviewNavigation(item: item, previewRoute: previewRoute)
            } else {
                Color.clear
                    .task { previewRoute.wrappedValue = nil }
            }
        }
        #else
        sheet(item: previewRoute) { route in
            if let item = itemProvider(route.id) {
                MobilePreviewNavigation(item: item, previewRoute: previewRoute)
            } else {
                Color.clear
                    .task { previewRoute.wrappedValue = nil }
            }
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
                        Button("action.done") {
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
                        .accessibilityLabel(String(format: NSLocalizedString("format.remove", comment: ""), summary.title))
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(.bar)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("label.active_clipboard_filters")
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
                        Text("label.type")
                            .foregroundStyle(.secondary)
                        Text(item.contentType.displayName)
                    }
                    GridRow {
                        Text("label.source")
                            .foregroundStyle(.secondary)
                        Text(item.sourceAppName)
                    }
                    GridRow {
                        Text("label.device")
                            .foregroundStyle(.secondary)
                        Text(item.deviceName)
                    }
                    GridRow {
                        Text("label.category")
                            .foregroundStyle(.secondary)
                        Text(item.reuseCategory.displayName)
                    }
                    if !item.labels.isEmpty {
                        GridRow {
                            Text("label.labels")
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
                        Label("action.copy", systemImage: "doc.on.doc")
                    }

                    Button {
                        MobilePasteboardWriter.copy(item, format: .plainText)
                    } label: {
                        Label("label.plain_text", systemImage: "textformat")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("label.preview")
    }
}

private struct MobileVisualPreviewSummary: View {
    let item: ClipboardItem

    var body: some View {
        let preview = item.visualPreview
        VStack(alignment: .leading, spacing: 6) {
            Label(NSLocalizedString(preview.badgeText, comment: ""), systemImage: preview.systemImageName)
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
