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
                ? "Saved to history."
                : "Saved to history and selected pinboard."
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
    @State private var statusMessage: String?

    public init(store: PasteBuddyStore, pasteService: MobileKeyboardPasteService? = nil) {
        self.store = store
        self.pasteService = pasteService
    }

    public var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("brand.pastebuddy")
                    .font(.headline)
                Spacer()
                Text(store.snapshot.mobile.hasKeyboardFullAccess ? "label.full_access" : "label.limited")
                    .font(.caption)
                    .foregroundStyle(store.snapshot.mobile.hasKeyboardFullAccess ? .green : .secondary)
            }

            HStack {
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
                    Label(keyboardScopeTitle, systemImage: "square.grid.2x2")
                }

                Spacer()

                if store.mobileGuidanceReport.keyboardCapabilities.supportsDragAndDrop {
                    Label("label.drag", systemImage: "hand.draw")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let keyboardCard = store.mobileGuidanceReport.card(id: "keyboard-extension"),
               keyboardCard.severity == .actionRequired {
                MobileGuidanceCardRow(card: keyboardCard)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            List(store.filteredItems.prefix(20)) { item in
                Button {
                    insert(item, format: .plainText)
                } label: {
                    HStack {
                        Image(systemName: iconName(for: item))
                        VStack(alignment: .leading) {
                            Text(item.title)
                                .lineLimit(1)
                            Text(item.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(item.sourceAppName)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
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
                            ? "Copied for manual paste."
                            : "Copy is unavailable in this environment."
                    } label: {
                        Label("action.copy", systemImage: "doc.on.doc")
                    }

                    Button {
                        statusMessage = MobilePasteboardWriter.copy(item, format: .plainText)
                            ? "Copied plain text for manual paste."
                            : "Plain text copy is unavailable in this environment."
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
            .searchable(text: $store.searchQuery, prompt: "Search")
        }
        .padding(10)
    }

    private var keyboardScopeTitle: String {
        switch store.selectedScope {
        case .history:
            "History"
        case .pasteStack:
            "Paste Stack"
        case .pinboard(let id):
            store.snapshot.pinboards.first(where: { $0.id == id })?.name ?? "Pinboard"
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
