import AppKit
import PasteBuddyCore
import SwiftUI
import UniformTypeIdentifiers

enum ClipboardCollectionDropTarget {
    case history
    case pasteStack
    case smartCategory(SmartPinboardCategory)
    case pinboard(UUID)
}

// Both panels render this exact strip, so collection entries, icons, colors,
// selection semantics, and drag-drop targets cannot drift between the shelf
// and the side panel.
struct ClipboardCollectionStrip: View {
    @Bindable var store: PasteBuddyStore
    let selectedScope: PasteScope
    let onSelectScope: (PasteScope) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ShelfCollectionChip(
                    title: localized("label.clipboard"),
                    systemImageName: "clock.arrow.circlepath",
                    color: store.isCapturePaused ? .orange : .blue,
                    isSelected: selectedScope == .history,
                    onDropPayloads: { dropItems($0, into: .history) }
                ) {
                    onSelectScope(.history)
                }

                ShelfCollectionChip(
                    title: localized("action.paste_stack"),
                    systemImageName: store.isPasteStackActive ? "tray.full.fill" : "tray",
                    color: store.isPasteStackActive ? .green : .secondary,
                    isSelected: selectedScope == .pasteStack,
                    onDropPayloads: { dropItems($0, into: .pasteStack) }
                ) {
                    onSelectScope(.pasteStack)
                }

                ForEach(SmartPinboardCategory.allCases) { category in
                    ShelfCollectionChip(
                        title: localized(category.displayName),
                        systemImageName: category.systemImageName,
                        color: Color(hex: category.colorHex) ?? .accentColor,
                        isSelected: isSmartCategorySelected(category),
                        onDropPayloads: { dropItems($0, into: .smartCategory(category)) }
                    ) {
                        selectSmartCategory(category)
                    }
                }

                ForEach(store.userPinboards) { pinboard in
                    ShelfCollectionChip(
                        title: pinboard.name,
                        systemImageName: "pin.fill",
                        color: Color(hex: pinboard.colorHex) ?? .blue,
                        isSelected: selectedScope == .pinboard(pinboard.id),
                        onDropPayloads: { dropItems($0, into: .pinboard(pinboard.id)) }
                    ) {
                        onSelectScope(.pinboard(pinboard.id))
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("label.clipboard_collections"))
    }

    private func isSmartCategorySelected(_ category: SmartPinboardCategory) -> Bool {
        guard let pinboard = store.smartPinboard(for: category) else { return false }
        return selectedScope == .pinboard(pinboard.id)
    }

    private func selectSmartCategory(_ category: SmartPinboardCategory) {
        let pinboard = store.syncSmartPinboard(for: category)
        onSelectScope(.pinboard(pinboard.id))
    }

    private func dropItems(_ payloads: [PinboardItemDragPayload], into target: ClipboardCollectionDropTarget) -> Bool {
        let ids = droppedItemIDs(from: payloads)
        guard !ids.isEmpty else { return false }

        switch target {
        case .history:
            onSelectScope(.history)
            return true
        case .pasteStack:
            guard store.addItemsToPasteStack(ids) else { return false }
            onSelectScope(.pasteStack)
            return true
        case .smartCategory(let category):
            guard ids.contains(where: { id in
                store.snapshot.items.first(where: { $0.id == id }).map(category.matches) == true
            }) else {
                return false
            }
            selectSmartCategory(category)
            return true
        case .pinboard(let pinboardID):
            store.pinItems(ids, to: pinboardID)
            onSelectScope(.pinboard(pinboardID))
            return true
        }
    }

    private func droppedItemIDs(from payloads: [PinboardItemDragPayload]) -> [UUID] {
        var seen = Set<UUID>()
        return payloads.flatMap(\.ids).filter { seen.insert($0).inserted }
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}

struct ShelfCollectionChip: View {
    private static let hoverAnimation = Animation.smooth(duration: 0.18, extraBounce: 0.04)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let systemImageName: String
    let color: Color
    let isSelected: Bool
    var onDropPayloads: (([PinboardItemDragPayload]) -> Bool)?
    let action: () -> Void
    @State private var isHovered = false
    @State private var isDropTargeted = false

    init(
        title: String,
        systemImageName: String,
        color: Color,
        isSelected: Bool,
        onDropPayloads: (([PinboardItemDragPayload]) -> Bool)? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImageName = systemImageName
        self.color = color
        self.isSelected = isSelected
        self.onDropPayloads = onDropPayloads
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImageName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(iconForegroundStyle)

                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(height: 38)
            .background {
                if isSelected || isHovered || isDropTargeted {
                    Capsule()
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(isSelected || isDropTargeted ? 0.86 : 0.64))
                        .background(.regularMaterial, in: Capsule())
                }
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .overlay {
            if let onDropPayloads {
                ShelfCollectionChipDropTarget(
                    isTargeted: $isDropTargeted,
                    onDropPayloads: onDropPayloads
                )
                .clipShape(Capsule())
            }
        }
        .onHover { isHovered in
            withAnimation(reduceMotion ? nil : Self.hoverAnimation) {
                self.isHovered = isHovered
            }
        }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? NSLocalizedString("state.selected", comment: "") : NSLocalizedString("label.not_selected", comment: ""))
    }

    private var iconForegroundStyle: Color {
        if isSelected {
            return .primary
        }
        return color
    }

    private var helpText: String {
        title
    }
}

struct ShelfCollectionChipDropTarget: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let onDropPayloads: ([PinboardItemDragPayload]) -> Bool

    func makeNSView(context: Context) -> DropView {
        let view = DropView()
        view.onTargeted = { isTargeted in
            self.isTargeted = isTargeted
        }
        view.onDropPayloads = onDropPayloads
        return view
    }

    func updateNSView(_ nsView: DropView, context: Context) {
        nsView.onTargeted = { isTargeted in
            self.isTargeted = isTargeted
        }
        nsView.onDropPayloads = onDropPayloads
    }

    final class DropView: NSView {
        var onTargeted: (Bool) -> Void = { _ in }
        var onDropPayloads: ([PinboardItemDragPayload]) -> Bool = { _ in false }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([Self.payloadPasteboardType])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = window?.currentEvent ?? NSApp.currentEvent,
                  event.type == .leftMouseDragged else {
                return nil
            }
            return super.hitTest(point)
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard canAccept(sender) else { return [] }
            onTargeted(true)
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            canAccept(sender) ? .copy : []
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            onTargeted(false)
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            onTargeted(false)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let payloads = payloads(from: sender.draggingPasteboard)
            guard !payloads.isEmpty else { return false }
            onTargeted(false)
            return onDropPayloads(payloads)
        }

        private func canAccept(_ sender: NSDraggingInfo) -> Bool {
            !payloads(from: sender.draggingPasteboard).isEmpty
        }

        private func payloads(from pasteboard: NSPasteboard) -> [PinboardItemDragPayload] {
            var payloads: [PinboardItemDragPayload] = []
            for item in pasteboard.pasteboardItems ?? [] {
                guard let data = item.data(forType: Self.payloadPasteboardType),
                      let payload = try? JSONDecoder().decode(PinboardItemDragPayload.self, from: data) else {
                    continue
                }
                payloads.append(payload)
            }
            if payloads.isEmpty,
               let data = pasteboard.data(forType: Self.payloadPasteboardType),
               let payload = try? JSONDecoder().decode(PinboardItemDragPayload.self, from: data) {
                payloads.append(payload)
            }
            return payloads
        }

        private static let payloadPasteboardType = NSPasteboard.PasteboardType(UTType.pasteBuddyPinboardItemIDs.identifier)
    }
}
