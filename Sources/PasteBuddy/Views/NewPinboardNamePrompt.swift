import AppKit

enum NewPinboardNamePrompt {
    @MainActor
    static func run() -> String? {
        while true {
            let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            nameField.placeholderString = NSLocalizedString("label.name", comment: "")

            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = NSLocalizedString("label.new_pinboard", comment: "")
            alert.accessoryView = nameField
            alert.addButton(withTitle: NSLocalizedString("action.save", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("action.cancel", comment: ""))
            alert.window.initialFirstResponder = nameField

            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return nil }

            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return name
            }
            NSSound.beep()
        }
    }
}
