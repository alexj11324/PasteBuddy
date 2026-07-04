import PasteBuddyCore
import SwiftUI

public struct MobileShareImportView: View {
    @Bindable private var store: PasteBuddyStore
    private let input: SharedContentInput
    @State private var selectedPinboardID: UUID?
    @State private var statusMessage: String?

    public init(store: PasteBuddyStore, input: SharedContentInput) {
        self.store = store
        self.input = input
        self._selectedPinboardID = State(initialValue: input.preferredPinboardID ?? store.snapshot.mobile.preferredSharePinboardID)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("label.shared_content") {
                    LabeledContent("label.source") {
                        Text(input.source.displayName)
                    }
                    LabeledContent("label.title") {
                        Text(displayTitle)
                    }
                    Text(previewText)
                        .lineLimit(4)
                }

                Section("label.destination") {
                    Picker("label.pinboard", selection: $selectedPinboardID) {
                        Text("label.history_only").tag(nil as UUID?)
                        ForEach(store.snapshot.pinboards) { pinboard in
                            Text(pinboard.name).tag(Optional(pinboard.id))
                        }
                    }
                }

                if let statusMessage {
                    Section {
                        Text(statusMessage)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("label.extension_setup") {
                    Text(store.mobileGuidanceReport.summary)
                        .foregroundStyle(store.mobileGuidanceReport.needsUserAction ? .orange : .secondary)
                    Text(store.mobileGuidanceReport.shareActionCapabilities.favoriteReorderGuidance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let card = store.mobileGuidanceReport.card(id: input.source == .actionExtension ? "action-extension" : "share-extension") {
                        MobileGuidanceCardRow(card: card)
                    }
                }
            }
            .navigationTitle("action.save_to_pastebuddy")
            .toolbar {
                Button("action.save") {
                    save()
                }
            }
        }
    }

    private var previewText: String {
        input.text
            ?? input.urlString
            ?? input.fileURLString
            ?? (input.imageData?.isEmpty == false ? "Image data" : "No preview")
    }

    private var displayTitle: String {
        guard let title = input.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return PasteBuddyLocalization.string("label.untitled", defaultValue: "Untitled")
        }
        return title
    }

    private func save() {
        var mutableInput = input
        mutableInput.preferredPinboardID = selectedPinboardID
        do {
            _ = try SharedContentImportService().importContent(mutableInput, into: store)
            statusMessage = selectedPinboardID == nil
                ? PasteBuddyLocalization.string(
                    "mobile.share_action.saved_to_history",
                    defaultValue: "Saved to history."
                )
                : PasteBuddyLocalization.string(
                    "mobile.share_action.saved_to_history_and_pinboard",
                    defaultValue: "Saved to history and selected pinboard."
                )
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

public struct MobileOnboardingGuidanceView: View {
    private let report: MobileIntegrationGuidanceReport

    public init(report: MobileIntegrationGuidanceReport) {
        self.report = report
    }

    public var body: some View {
        List {
            Section("label.status") {
                Label(report.summary, systemImage: report.needsUserAction ? "exclamationmark.circle" : "checkmark.circle")
                    .foregroundStyle(report.needsUserAction ? .orange : .green)

                LabeledContent("label.automatic_capture") {
                    Text(report.pastePermissionGuidance.automaticCaptureStatus.displayName)
                        .foregroundStyle(report.canAttemptAutomaticPasteCapture ? .green : .orange)
                }

                LabeledContent("label.manual_imports") {
                    Text(report.canUseManualExtensionImports ? "state.available" : "state.optional")
                        .foregroundStyle(report.canUseManualExtensionImports ? .green : .secondary)
                }
            }

            Section("action.paste_permission") {
                Text(report.pastePermissionGuidance.title)
                    .font(.subheadline.weight(.semibold))
                Text(report.pastePermissionGuidance.detail)
                    .foregroundStyle(.secondary)
                if report.pastePermissionGuidance.shouldOfferSettingsAction {
                    LabeledContent("label.settings") {
                        Text(report.pastePermissionGuidance.settingsPath)
                    }
                }
                Text(report.pastePermissionGuidance.manualWorkflowMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(report.pastePermissionGuidance.darkPatternGuardrail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("label.guidance") {
                ForEach(report.cards) { card in
                    MobileGuidanceCardRow(card: card)
                }
            }
        }
    }
}

private struct MobileGuidanceCardRow: View {
    let card: MobileGuidanceCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: iconName)
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title)
                        .font(.subheadline.weight(.semibold))
                    Text(card.surface.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(card.severity.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
            }

            Text(card.detail)
                .foregroundStyle(.secondary)

            ForEach(card.actions) { action in
                Label(action.title, systemImage: action.isPrimary ? "arrow.right.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(action.isPrimary ? .primary : .secondary)
                Text(action.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(card.severity.displayName): \(card.title)")
        .accessibilityValue(card.detail)
    }

    private var color: Color {
        switch card.severity {
        case .ready: .green
        case .optional: .secondary
        case .actionRequired: .orange
        }
    }

    private var iconName: String {
        switch card.severity {
        case .ready: "checkmark.circle"
        case .optional: "circle"
        case .actionRequired: "exclamationmark.circle"
        }
    }
}

public struct MobileKeyboardHistoryView: View {
    @Bindable private var store: PasteBuddyStore
    private let pasteService: MobileKeyboardPasteService?
    private let irohSync: IrohClipboardSyncService?
    private let onDeleteBackward: (() -> Void)?
    private let onInsertReturn: (() -> Void)?
    private let onAdvanceToNextInputMode: (() -> Void)?
    @State private var statusMessage: String?

    public init(
        store: PasteBuddyStore,
        pasteService: MobileKeyboardPasteService? = nil,
        irohSync: IrohClipboardSyncService? = nil,
        onDeleteBackward: (() -> Void)? = nil,
        onInsertReturn: (() -> Void)? = nil,
        onAdvanceToNextInputMode: (() -> Void)? = nil
    ) {
        self.store = store
        self.pasteService = pasteService
        self.irohSync = irohSync
        self.onDeleteBackward = onDeleteBackward
        self.onInsertReturn = onInsertReturn
        self.onAdvanceToNextInputMode = onAdvanceToNextInputMode
    }

    public var body: some View {
        VStack(spacing: 10) {
            keyboardHeader

            if let keyboardCard = store.mobileGuidanceReport.card(id: "keyboard-extension"),
               keyboardCard.severity == .actionRequired {
                MobileGuidanceCardRow(card: keyboardCard)
            }

            if let irohSync {
                MobileKeyboardIrohSyncStrip(
                    store: store,
                    irohSync: irohSync,
                    statusMessage: $statusMessage
                )
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            keyboardItemTray
            keyboardActionRow
        }
        .padding(10)
    }

    private var keyboardHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)

            Menu {
                Button {
                    store.selectedScope = .history
                } label: {
                    Label("label.history", systemImage: "clock.arrow.circlepath")
                }
                Button {
                    store.selectedScope = .pasteStack
                } label: {
                    Label("action.paste_stack", systemImage: "tray")
                }
                if !store.snapshot.pinboards.isEmpty {
                    Section("label.pinboards") {
                        ForEach(store.snapshot.pinboards) { pinboard in
                            Button {
                                store.selectedScope = .pinboard(pinboard.id)
                            } label: {
                                Label(pinboard.name, systemImage: "pin")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text(keyboardScopeTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            Text(store.snapshot.mobile.hasKeyboardFullAccess ? "label.full_access" : "label.limited")
                .font(.caption.weight(.semibold))
                .foregroundStyle(store.snapshot.mobile.hasKeyboardFullAccess ? .green : .secondary)
        }
    }

    private var keyboardItemTray: some View {
        let items = Array(store.filteredItems.prefix(12))
        return Group {
            if items.isEmpty {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.secondary.opacity(0.10))
                    .frame(height: 104)
                    .overlay {
                        Text("message.no_items_match_current_filters")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(items) { item in
                            MobileKeyboardClipboardCard(item: item) {
                                insert(item, format: .plainText)
                            }
                            .draggable(ClipboardPlainTextRenderer.plainText(for: item))
                            .contextMenu {
                                Button {
                                    insert(item, format: .plainText)
                                } label: {
                                    Label("action.insert", systemImage: "keyboard")
                                }

                                Button {
                                    statusMessage = MobilePasteboardWriter.copy(item)
                                        ? PasteBuddyLocalization.string("mobile.keyboard_paste.status_copied_manual", defaultValue: "Copied for manual paste.")
                                        : PasteBuddyLocalization.string("mobile.keyboard_paste.status_copy_unavailable", defaultValue: "Copy is unavailable in this environment.")
                                } label: {
                                    Label("action.copy", systemImage: "doc.on.doc")
                                }

                                Button {
                                    statusMessage = MobilePasteboardWriter.copy(item, format: .plainText)
                                        ? PasteBuddyLocalization.string("mobile.keyboard_paste.status_copied_plain_text", defaultValue: "Copied plain text for manual paste.")
                                        : PasteBuddyLocalization.string("mobile.keyboard_paste.status_plain_text_copy_unavailable", defaultValue: "Plain text copy is unavailable in this environment.")
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
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var keyboardActionRow: some View {
        HStack(spacing: 8) {
            Button {
                onAdvanceToNextInputMode?()
            } label: {
                Image(systemName: "globe")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(onAdvanceToNextInputMode == nil)

            Capsule()
                .fill(.secondary.opacity(0.10))
                .frame(height: 34)
                .overlay(alignment: .leading) {
                    Text(statusMessage ?? keyboardScopeTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                }

            Button {
                onDeleteBackward?()
            } label: {
                Image(systemName: "delete.left")
                    .frame(width: 42, height: 34)
            }
            .buttonStyle(.bordered)
            .disabled(onDeleteBackward == nil)

            Button {
                onInsertReturn?()
            } label: {
                Image(systemName: "return")
                    .frame(width: 52, height: 34)
            }
            .buttonStyle(.borderedProminent)
            .disabled(onInsertReturn == nil)
        }
    }

    private var keyboardScopeTitle: String {
        switch store.selectedScope {
        case .history:
            PasteBuddyLocalization.string("label.clipboard", defaultValue: "Clipboard")
        case .pasteStack:
            PasteBuddyLocalization.string("action.paste_stack", defaultValue: "Paste Stack")
        case .pinboard(let id):
            store.snapshot.pinboards.first(where: { $0.id == id })?.name
                ?? PasteBuddyLocalization.string("label.pinboard", defaultValue: "Pinboard")
        }
    }

    private func insert(_ item: ClipboardItem, format: PasteFormat) {
        guard let pasteService else {
            statusMessage = MobilePasteboardWriter.copy(item, format: format)
                ? "Copied for manual paste."
                : "Keyboard insertion is unavailable in this environment."
            return
        }
        let result = pasteService.paste(item, format: format, configuration: store.snapshot.mobile)
        statusMessage = result.statusMessage
    }

    private func iconName(for item: ClipboardItem) -> String {
        switch item.contentType {
        case .text: "text.alignleft"
        case .url: "link"
        case .image: "photo"
        case .file: "doc"
        case .mixed: "square.stack.3d.up"
        }
    }
}

private struct MobileKeyboardIrohSyncStrip: View {
    @Bindable var store: PasteBuddyStore
    @Bindable var irohSync: IrohClipboardSyncService
    @Binding var statusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(irohStatusText, systemImage: irohStatusIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(irohStatusColor)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Button {
                    connect()
                } label: {
                    Image(systemName: "bolt.horizontal.circle")
                        .frame(width: 30, height: 28)
                }
                .buttonStyle(.bordered)
                .disabled(!canUseSyncNetwork || trimmedPeerEndpointId.isEmpty)

                Button {
                    syncCurrentClipboard()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .frame(width: 34, height: 28)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canUseSyncNetwork || trimmedPeerEndpointId.isEmpty)
            }

            if !canUseSyncNetwork {
                Text("mobile.keyboard_sync.full_access_required")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if trimmedPeerEndpointId.isEmpty {
                Text("mobile.keyboard_sync.configure_peer_in_app")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var canUseSyncNetwork: Bool {
        store.snapshot.mobile.hasKeyboardFullAccess
    }

    private var trimmedPeerEndpointId: String {
        irohSync.peerEndpointId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func connect() {
        Task { @MainActor in
            await irohSync.connectToPeer()
        }
    }

    private func syncCurrentClipboard() {
        guard let item = MobilePasteboardWriter.currentClipboardItem() else {
            statusMessage = PasteBuddyLocalization.string(
                "mobile.keyboard_sync.no_clipboard_item",
                defaultValue: "No current clipboard item is available."
            )
            return
        }
        let storedItem = store.addCapturedItem(item)
        Task { @MainActor in
            if !irohSync.connectionState.isConnected {
                await irohSync.connectToPeer()
            }
            statusMessage = await irohSync.send(storedItem)
                ? PasteBuddyLocalization.string(
                    "mobile.keyboard_sync.sent_current_clipboard",
                    defaultValue: "Synced current clipboard."
                )
                : PasteBuddyLocalization.string(
                    "mobile.keyboard_sync.send_failed",
                    defaultValue: "Clipboard sync failed."
                )
        }
    }

    private var irohStatusText: String {
        switch irohSync.connectionState {
        case .idle:
            PasteBuddyLocalization.string("state.idle", defaultValue: "Idle")
        case .binding:
            PasteBuddyLocalization.string("state.binding", defaultValue: "Binding")
        case .ready:
            PasteBuddyLocalization.string("state.ready", defaultValue: "Ready")
        case .connecting:
            PasteBuddyLocalization.string("state.connecting", defaultValue: "Connecting")
        case .connected(let peerShortId):
            PasteBuddyLocalization.format("format.connected_to_peer", defaultValue: "Connected to %@", peerShortId)
        case .failed(let message):
            message
        }
    }

    private var irohStatusIcon: String {
        switch irohSync.connectionState {
        case .connected:
            "bolt.horizontal.circle.fill"
        case .failed:
            "exclamationmark.triangle"
        case .connecting, .binding:
            "bolt.horizontal.circle"
        case .idle, .ready:
            "bolt.horizontal"
        }
    }

    private var irohStatusColor: Color {
        switch irohSync.connectionState {
        case .connected:
            .green
        case .failed:
            .orange
        case .connecting, .binding:
            .secondary
        case .idle, .ready:
            .secondary
        }
    }
}

private struct MobileKeyboardClipboardCard: View {
    let item: ClipboardItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: iconName)
                        .foregroundStyle(.blue)
                    Text(item.contentType.displayName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(relativeAge)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(item.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .frame(width: 134, height: 118, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.secondary.opacity(0.16), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
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

    private var relativeAge: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: item.createdAt, relativeTo: Date())
    }
}
