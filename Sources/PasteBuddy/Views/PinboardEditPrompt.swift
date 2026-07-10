import AppKit
import PasteBuddyCore
import SwiftUI

private struct PinboardEditResult {
    let name: String
    let colorHex: String
    let systemImageName: String?
}

@MainActor
private enum PinboardEditPrompt {
    static func run(for pinboard: Pinboard) -> PinboardEditResult? {
        let nameField = NSTextField(string: pinboard.name)
        nameField.placeholderString = localized("label.name", defaultValue: "Name")
        nameField.widthAnchor.constraint(equalToConstant: 252).isActive = true

        let iconNames: [String?] = [nil] + Pinboard.customizableSystemImageNames.map(Optional.some)
        let accessibilityDescriptions = iconNames.map(accessibilityDescription(for:))
        let iconControl = NSSegmentedControl(
            images: zip(iconNames, accessibilityDescriptions).map { name, accessibilityDescription in
                NSImage(
                    systemSymbolName: name ?? "pin.fill",
                    accessibilityDescription: accessibilityDescription
                ) ?? NSImage()
            },
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        iconControl.segmentStyle = .rounded
        iconControl.selectedSegment = iconNames.firstIndex(of: pinboard.systemImageName) ?? 0
        iconControl.widthAnchor.constraint(equalToConstant: 252).isActive = true
        iconControl.setAccessibilityLabel(localized("label.icon", defaultValue: "Icon"))
        for (index, description) in accessibilityDescriptions.enumerated() {
            iconControl.setToolTip(description, forSegment: index)
        }

        let colorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 252, height: 28))
        colorWell.supportsAlpha = false
        colorWell.color = color(from: pinboard.colorHex)
        colorWell.widthAnchor.constraint(equalToConstant: 252).isActive = true

        let form = NSStackView(views: [
            row(labelKey: "label.name", defaultValue: "Name", control: nameField),
            row(labelKey: "label.icon", defaultValue: "Icon", control: iconControl),
            row(labelKey: "label.color", defaultValue: "Color", control: colorWell)
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = localized("label.edit_pinboard", defaultValue: "Edit Pinboard")
        alert.accessoryView = form
        alert.addButton(withTitle: localized("action.save", defaultValue: "Save"))
        alert.addButton(withTitle: localized("action.cancel", defaultValue: "Cancel"))
        alert.window.initialFirstResponder = nameField

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            NSSound.beep()
            return nil
        }
        return PinboardEditResult(
            name: name,
            colorHex: hexString(from: colorWell.color),
            systemImageName: iconNames[iconControl.selectedSegment]
        )
    }

    private static func row(labelKey: String, defaultValue: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: localized(labelKey, defaultValue: defaultValue))
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 52).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private static func localized(_ key: String, defaultValue: String) -> String {
        PasteBuddyLocalization.string(key, defaultValue: defaultValue)
    }

    private static func accessibilityDescription(for systemImageName: String?) -> String {
        switch systemImageName {
        case nil:
            localized("label.icon_default_pin", defaultValue: "Default pin")
        case "heart.fill":
            localized("label.icon_heart", defaultValue: "Heart")
        case "star.fill":
            localized("label.icon_star", defaultValue: "Star")
        case "bookmark.fill":
            localized("label.icon_bookmark", defaultValue: "Bookmark")
        case "folder.fill":
            localized("label.icon_folder", defaultValue: "Folder")
        case "tag.fill":
            localized("label.icon_tag", defaultValue: "Tag")
        case "tray.fill":
            localized("label.icon_tray", defaultValue: "Tray")
        case "bolt.fill":
            localized("label.icon_bolt", defaultValue: "Bolt")
        case "book.fill":
            localized("label.icon_book", defaultValue: "Book")
        default:
            localized("label.icon", defaultValue: "Icon")
        }
    }

    private static func color(from hex: String) -> NSColor {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let rgb = Int(value, radix: 16) else { return .controlAccentColor }
        return NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func hexString(from color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#4EA7FC" }
        let red = Int((rgb.redComponent * 255).rounded()).clamped(to: 0...255)
        let green = Int((rgb.greenComponent * 255).rounded()).clamped(to: 0...255)
        let blue = Int((rgb.blueComponent * 255).rounded()).clamped(to: 0...255)
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

struct CustomPinboardActionsMenu: View {
    let store: PasteBuddyStore
    let pinboard: Pinboard
    let onMove: (Int) -> Void

    var body: some View {
        Button {
            editPinboard()
        } label: {
            Label("label.edit_pinboard", systemImage: "slider.horizontal.3")
        }

        Divider()

        Button {
            moveLeft()
        } label: {
            Label("action.move_left", systemImage: "arrow.left")
        }
        .disabled(collectionIndex.map { $0 == 0 } ?? true)

        Button {
            moveRight()
        } label: {
            Label("action.move_right", systemImage: "arrow.right")
        }
        .disabled(collectionIndex.map { $0 >= store.collectionOrder.count - 1 } ?? true)
    }

    private var collectionIndex: Int? {
        store.collectionOrder.firstIndex(of: .pinboard(pinboard.id))
    }

    private func editPinboard() {
        guard let result = PinboardEditPrompt.run(for: pinboard) else { return }
        store.updatePinboardAppearance(
            pinboard.id,
            name: result.name,
            colorHex: result.colorHex,
            systemImageName: result.systemImageName
        )
    }

    private func moveLeft() {
        onMove(-1)
    }

    private func moveRight() {
        onMove(1)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
