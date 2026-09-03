import CoreTransferable
import PasteBuddyCore
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS) && canImport(VisionKit)
import VisionKit
#endif

public struct MobileClipboardBrowserView: View {
    @Bindable private var store: PasteBuddyStore
    private let irohSync: IrohClipboardSyncService?
    @State private var sharingRoute: MobilePinboardSharingRoute?
    @State private var previewRoute: MobilePreviewRoute?

    public init(store: PasteBuddyStore, irohSync: IrohClipboardSyncService? = nil) {
        self.store = store
        self.irohSync = PasteBuddyFeatureAvailability.irohClipboardSync ? irohSync : nil
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
                    if let irohSync {
                        NavigationLink {
                            MobileIrohClipboardSyncView(store: store, irohSync: irohSync)
                                .navigationTitle("label.iroh_clipboard_sync")
                        } label: {
                            Label("label.iroh_clipboard_sync", systemImage: irohSync.connectionState.isConnected ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
                        }
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

private struct MobileIrohClipboardSyncView: View {
    @Bindable var store: PasteBuddyStore
    @Bindable var irohSync: IrohClipboardSyncService
    @State private var isShowingPairingScanner = false
    @State private var pairingStatusMessage: String?

    var body: some View {
        Form {
            Section("label.this_device") {
                Text(irohSync.endpointId.isEmpty ? NSLocalizedString("state.binding", comment: "") : irohSync.endpointId)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }

            Section("label.pair_this_mac") {
                #if os(iOS) && canImport(VisionKit)
                Button("action.scan_pairing_qr") {
                    isShowingPairingScanner = true
                }
                .disabled(!IrohPairingScannerView.isAvailable)
                #endif

                Text("message.scan_pairing_qr_from_mac")
                    .foregroundStyle(.secondary)

                if let pairingStatusMessage {
                    Text(pairingStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("label.peer_endpoint_id") {
                TextField("label.peer_endpoint_id", text: $irohSync.peerEndpointId)
                    .font(.system(.caption, design: .monospaced))

                Button("action.connect") {
                    Task { await irohSync.connectToPeer() }
                }
                .disabled(irohSync.peerEndpointId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section("label.actions") {
                Button("action.sync_current_clipboard") {
                    if let item = MobilePasteboardWriter.currentClipboardItem() {
                        let storedItem = store.addCapturedItem(item)
                        Task { await irohSync.send(storedItem) }
                    }
                }
                .disabled(!irohSync.connectionState.isConnected)

                if let selectedItem = store.selectedItem {
                    Button("action.send_selected_item") {
                        Task { await irohSync.send(selectedItem) }
                    }
                    .disabled(!irohSync.connectionState.isConnected)
                }
            }

            Section("label.status") {
                Text(statusText)
                if let lastReceivedTitle = irohSync.lastReceivedTitle {
                    Text(String(format: NSLocalizedString("format.last_received_item", comment: ""), lastReceivedTitle))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { await irohSync.start() }
        #if os(iOS) && canImport(VisionKit)
        .sheet(isPresented: $isShowingPairingScanner) {
            IrohPairingScannerView { code in
                isShowingPairingScanner = false
                applyPairingCode(code)
            }
        }
        #endif
    }

    private var statusText: String {
        switch irohSync.connectionState {
        case .idle:
            NSLocalizedString("state.off", comment: "")
        case .binding:
            NSLocalizedString("state.binding", comment: "")
        case .ready:
            NSLocalizedString("state.ready", comment: "")
        case .connecting:
            NSLocalizedString("state.connecting", comment: "")
        case .connected(let peerShortId):
            String(format: NSLocalizedString("format.connected_to_peer", comment: ""), peerShortId)
        case .failed(let message):
            message
        }
    }

    private func applyPairingCode(_ code: String) {
        do {
            try irohSync.applyPairingCode(code)
            pairingStatusMessage = NSLocalizedString("message.pairing_qr_saved", comment: "")
            Task { await irohSync.connectToPeer() }
        } catch {
            pairingStatusMessage = error.localizedDescription
        }
    }
}

#if os(iOS) && canImport(VisionKit)
private struct IrohPairingScannerView: UIViewControllerRepresentable {
    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCode: (String) -> Void
        private var hasMatchedCode = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            handle(addedItems.first)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            handle(item)
        }

        private func handle(_ item: RecognizedItem?) {
            guard !hasMatchedCode,
                  case .barcode(let barcode) = item,
                  let payload = barcode.payloadStringValue else { return }
            hasMatchedCode = true
            onCode(payload)
        }
    }
}
#endif

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
