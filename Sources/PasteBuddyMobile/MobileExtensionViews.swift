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
                Section("Shared Content") {
                    LabeledContent("Source") {
                        Text(input.source.displayName)
                    }
                    LabeledContent("Title") {
                        Text(input.title?.isEmpty == false ? input.title! : "Untitled")
                    }
                    Text(previewText)
                        .lineLimit(4)
                }

                Section("Destination") {
                    Picker("Pinboard", selection: $selectedPinboardID) {
                        Text("History Only").tag(nil as UUID?)
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

                Section("Extension Setup") {
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
            .navigationTitle("Save to PasteBuddy")
            .toolbar {
                Button("Save") {
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

    private func save() {
        var mutableInput = input
        mutableInput.preferredPinboardID = selectedPinboardID
        do {
            _ = try SharedContentImportService().importContent(mutableInput, into: store)
            statusMessage = selectedPinboardID == nil
                ? "Saved to encrypted history."
                : "Saved to encrypted history and selected pinboard."
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
            Section("Status") {
                Label(report.summary, systemImage: report.needsUserAction ? "exclamationmark.circle" : "checkmark.circle")
                    .foregroundStyle(report.needsUserAction ? .orange : .green)

                LabeledContent("Automatic Capture") {
                    Text(report.pastePermissionGuidance.automaticCaptureStatus.displayName)
                        .foregroundStyle(report.canAttemptAutomaticPasteCapture ? .green : .orange)
                }

                LabeledContent("Manual Imports") {
                    Text(report.canUseManualExtensionImports ? "Available" : "Optional")
                        .foregroundStyle(report.canUseManualExtensionImports ? .green : .secondary)
                }
            }

            Section("Paste Permission") {
                Text(report.pastePermissionGuidance.title)
                    .font(.subheadline.weight(.semibold))
                Text(report.pastePermissionGuidance.detail)
                    .foregroundStyle(.secondary)
                if report.pastePermissionGuidance.shouldOfferSettingsAction {
                    LabeledContent("Settings") {
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

            Section("Guidance") {
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
                Text("PasteBuddy")
                    .font(.headline)
                Spacer()
                Text(store.snapshot.mobile.hasKeyboardFullAccess ? "Full Access" : "Limited")
                    .font(.caption)
                    .foregroundStyle(store.snapshot.mobile.hasKeyboardFullAccess ? .green : .secondary)
            }

            HStack {
                Menu {
                    Button {
                        store.selectedScope = .history
                    } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                    Button {
                        store.selectedScope = .pasteStack
                    } label: {
                        Label("Paste Stack", systemImage: "tray")
                    }
                    if !store.snapshot.pinboards.isEmpty {
                        Section("Pinboards") {
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
                    Label("Drag", systemImage: "hand.draw")
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
                        Label("Insert", systemImage: "keyboard")
                    }

                    Button {
                        statusMessage = MobilePasteboardWriter.copy(item)
                            ? "Copied for manual paste."
                            : "Copy is unavailable in this environment."
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }

                    Button {
                        statusMessage = MobilePasteboardWriter.copy(item, format: .plainText)
                            ? "Copied plain text for manual paste."
                            : "Plain text copy is unavailable in this environment."
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
