import AppKit
import PasteBuddyCore
import SwiftUI

struct SidebarView: View {
    @Bindable var store: PasteBuddyStore
    let currentExternalApplication: () -> ExternalApplicationIdentity?
    @State private var renameDraft: PinboardRenameDraft?
    @State private var deleteDraft: PinboardDeleteDraft?
    @State private var sharingDraft: PinboardSharingDraft?
    @State private var dropTargetPinboardID: UUID?
    @State private var privacyActionMessage: String?
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        List(selection: $store.selectedScope) {
            Section {
                Label("Clipboard History", systemImage: "clock.arrow.circlepath")
                    .tag(PasteScope.history)
            }

            Section("Paste Stack") {
                Label(
                    pasteStackTitle,
                    systemImage: store.isPasteStackActive ? "tray.full.fill" : "tray"
                )
                .tag(PasteScope.pasteStack)

                Button {
                    store.togglePasteStack()
                } label: {
                    Label(
                        localized(store.isPasteStackActive ? "Stop Collecting" : "Start Collecting"),
                        systemImage: store.isPasteStackActive ? "stop.circle" : "play.circle"
                    )
                }

                Button {
                    store.reversePasteStackDirection()
                } label: {
                    Label(localized(store.pasteStackDirection.displayName), systemImage: "arrow.up.arrow.down")
                }
                .disabled(store.pasteStackItems.isEmpty)
            }

            Section("Pinboards") {
                ForEach(store.snapshot.pinboards) { pinboard in
                    Label(pinboard.name, systemImage: "pin.fill")
                        .foregroundStyle(differentiateWithoutColor ? Color.primary : (Color(hex: pinboard.colorHex) ?? .primary))
                        .tag(PasteScope.pinboard(pinboard.id))
                        .dropDestination(for: PinboardItemDragPayload.self) { payloads, _ in
                            let itemIDs = payloads.flatMap(\.ids)
                            guard !itemIDs.isEmpty else { return false }
                            store.pinItems(itemIDs, to: pinboard.id)
                            return true
                        } isTargeted: { isTargeted in
                            if isTargeted {
                                dropTargetPinboardID = pinboard.id
                            } else if dropTargetPinboardID == pinboard.id {
                                dropTargetPinboardID = nil
                            }
                        }
                        .background {
                            if dropTargetPinboardID == pinboard.id {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(.tint.opacity(0.16))
                            }
                        }
                        .accessibilityHint("Drop clipboard items here to pin them.")
                        .accessibilityLabel(localized("Pinboard %@", pinboard.name))
                        .accessibilityValue(localized("Color %@", pinboard.colorHex))
                        .contextMenu {
                            Button("Edit Pinboard") {
                                renameDraft = PinboardRenameDraft(id: pinboard.id, name: pinboard.name, colorHex: pinboard.colorHex)
                            }
                            Button("Share Pinboard") {
                                sharingDraft = PinboardSharingDraft(id: pinboard.id)
                            }
                            Button("Delete Pinboard", role: .destructive) {
                                deleteDraft = PinboardDeleteDraft(
                                    id: pinboard.id,
                                    name: pinboard.name
                                )
                            }
                        }
                }
                .onMove { offsets, offset in
                    store.movePinboards(fromOffsets: offsets, toOffset: offset)
                }
            }

            Section("Filters") {
                Menu {
                    Picker(localized("Type"), selection: $store.contentTypeFilter) {
                        Text(localized("Any Type")).tag(nil as ClipboardContentType?)
                        ForEach(ClipboardContentType.allCases) { type in
                            Text(localized(type.displayName)).tag(Optional(type))
                        }
                    }
                } label: {
                    SidebarFilterRow(
                        title: localized("Type"),
                        value: contentTypeFilterTitle,
                        systemImageName: "doc.text.magnifyingglass",
                        isActive: store.contentTypeFilter != nil
                    )
                }

                Menu {
                    Picker(localized("App"), selection: $store.sourceAppFilter) {
                        Text(localized("Any App")).tag(nil as String?)
                        ForEach(store.availableSourceApps, id: \.self) { appName in
                            Text(appName).tag(Optional(appName))
                        }
                    }
                } label: {
                    SidebarFilterRow(
                        title: localized("App"),
                        value: store.sourceAppFilter ?? localized("Any App"),
                        systemImageName: "app",
                        isActive: store.sourceAppFilter != nil
                    )
                }

                Menu {
                    Picker(localized("Device"), selection: $store.deviceFilter) {
                        Text(localized("Any Device")).tag(nil as String?)
                        ForEach(store.availableDevices, id: \.self) { deviceName in
                            Text(deviceName).tag(Optional(deviceName))
                        }
                    }
                } label: {
                    SidebarFilterRow(
                        title: localized("Device"),
                        value: store.deviceFilter ?? localized("Any Device"),
                        systemImageName: "desktopcomputer",
                        isActive: store.deviceFilter != nil
                    )
                }

                Menu {
                    Picker(localized("Date"), selection: $store.dateFilter) {
                        ForEach(ClipboardDateFilter.allCases) { filter in
                            Text(localized(filter.displayName)).tag(filter)
                        }
                    }
                } label: {
                    SidebarFilterRow(
                        title: localized("Date"),
                        value: localized(store.dateFilter.displayName),
                        systemImageName: "calendar",
                        isActive: store.dateFilter != .any
                    )
                }

                if store.hasActiveFilters {
                    Button {
                        store.clearFilters()
                    } label: {
                        Label(localized("Clear Filters"), systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }

            Section("Privacy") {
                Button {
                    store.toggleCapturePaused()
                } label: {
                    Label(store.isCapturePaused ? "Capture Paused" : "Capture Active", systemImage: store.isCapturePaused ? "pause.circle.fill" : "checkmark.shield.fill")
                }

                Button {
                    guard let application = currentExternalApplication() else {
                        privacyActionMessage = localized("No external app is available to exclude.")
                        return
                    }
                    store.excludeApplication(
                        named: application.localizedName,
                        bundleIdentifier: application.bundleIdentifier
                    )
                    privacyActionMessage = localized("Excluded %@.", application.localizedName)
                } label: {
                    Label("Exclude Current App", systemImage: "eye.slash")
                }

                if let privacyActionMessage {
                    Text(privacyActionMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .sheet(item: $renameDraft) { draft in
            RenamePinboardSheet(name: draft.name, colorHex: draft.colorHex) { newName, colorHex in
                store.renamePinboard(draft.id, to: newName)
                store.updatePinboardColor(draft.id, to: colorHex)
                renameDraft = nil
            } onCancel: {
                renameDraft = nil
            }
        }
        .sheet(item: $sharingDraft) { draft in
            PinboardSharingSheet(store: store, pinboardID: draft.id) {
                sharingDraft = nil
            }
        }
        .confirmationDialog(
            "Delete Pinboard?",
            isPresented: Binding(
                get: { deleteDraft != nil },
                set: { isPresented in
                    if !isPresented {
                        deleteDraft = nil
                    }
                }
            ),
            presenting: deleteDraft
        ) { draft in
            Button("Delete Pinboard", role: .destructive) {
                store.deletePinboard(draft.id)
                deleteDraft = nil
            }
            Button("Cancel", role: .cancel) {
                deleteDraft = nil
            }
        } message: { _ in
            Text("Items stay in clipboard history. Only this pinboard collection is removed.")
        }
    }

    private var pasteStackTitle: String {
        if store.pasteStackItems.isEmpty {
            return localized("Paste Stack")
        }
        return localized("Paste Stack (%d)", store.pasteStackItems.count)
    }

    private var contentTypeFilterTitle: String {
        guard let contentTypeFilter = store.contentTypeFilter else {
            return localized("Any Type")
        }
        return localized(contentTypeFilter.displayName)
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

private struct SidebarFilterRow: View {
    let title: String
    let value: String
    let systemImageName: String
    let isActive: Bool

    var body: some View {
        Label {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Text(value)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: systemImageName)
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct PinboardRenameDraft: Identifiable {
    let id: UUID
    let name: String
    let colorHex: String
}

private struct PinboardDeleteDraft: Identifiable {
    let id: UUID
    let name: String
}

private struct PinboardSharingDraft: Identifiable {
    let id: UUID
}

private struct RenamePinboardSheet: View {
    @State var name: String
    @State var colorHex: String
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    let onSave: (String, String) -> Void
    let onCancel: () -> Void

    private let colors = ["#4EA7FC", "#7C9A92", "#F25F5C", "#FFE066", "#70C1B3", "#B388EB", "#FF9F1C"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Pinboard")
                .font(.headline)

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    onSave(name, colorHex)
                }

            HStack(spacing: 10) {
                ForEach(colors, id: \.self) { hex in
                    Button {
                        colorHex = hex
                    } label: {
                        Circle()
                            .fill(Color(hex: hex) ?? .accentColor)
                            .frame(width: 22, height: 22)
                            .overlay {
                                if colorHex.uppercased() == hex {
                                    ZStack {
                                        Circle()
                                            .stroke(.primary, lineWidth: 2)
                                        if differentiateWithoutColor {
                                            Image(systemName: "checkmark")
                                                .font(.caption2.weight(.bold))
                                                .foregroundStyle(.primary)
                                        }
                                    }
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(format: NSLocalizedString("Pinboard color %@", comment: ""), hex))
                    .accessibilityValue(NSLocalizedString(colorHex.uppercased() == hex ? "Selected" : "Not selected", comment: ""))
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                Button("Save") {
                    onSave(name, colorHex)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

extension Color {
    init?(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let int = Int(value, radix: 16) else {
            return nil
        }
        let red = Double((int >> 16) & 0xFF) / 255.0
        let green = Double((int >> 8) & 0xFF) / 255.0
        let blue = Double(int & 0xFF) / 255.0
        self.init(red: red, green: green, blue: blue)
    }
}
