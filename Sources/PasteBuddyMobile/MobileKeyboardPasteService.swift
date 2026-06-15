import Foundation
import PasteBuddyCore

public enum MobileKeyboardPasteOutcome: String, Codable, Equatable, Sendable {
    case insertedText
    case fullAccessRequired
    case noTextAvailable
    case insertionFailed
    case emptySelection

    public var displayName: String {
        switch self {
        case .insertedText: "Inserted text"
        case .fullAccessRequired: "Full Access required"
        case .noTextAvailable: "No text available"
        case .insertionFailed: "Insertion failed"
        case .emptySelection: "No item selected"
        }
    }
}

public struct MobileKeyboardFullAccessExplanation: Codable, Equatable, Sendable {
    public var title: String
    public var detail: String
    public var actionTitle: String

    public init(
        title: String = "Enable Full Access for PasteBuddy Keyboard",
        detail: String = MobileKeyboardExtensionCapabilities().fullAccessPrivacyExplanation,
        actionTitle: String = "Open Keyboard Settings"
    ) {
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
    }
}

public struct MobileKeyboardPasteResult: Equatable, Sendable {
    public var outcome: MobileKeyboardPasteOutcome
    public var format: PasteFormat
    public var characterCount: Int
    public var fullAccessExplanation: MobileKeyboardFullAccessExplanation?

    public init(
        outcome: MobileKeyboardPasteOutcome,
        format: PasteFormat,
        characterCount: Int = 0,
        fullAccessExplanation: MobileKeyboardFullAccessExplanation? = nil
    ) {
        self.outcome = outcome
        self.format = format
        self.characterCount = max(0, characterCount)
        self.fullAccessExplanation = fullAccessExplanation
    }

    public var statusMessage: String {
        switch outcome {
        case .insertedText:
            return "Inserted \(characterCount) character\(characterCount == 1 ? "" : "s")."
        case .fullAccessRequired:
            return fullAccessExplanation?.title ?? "Keyboard Full Access is required."
        case .noTextAvailable:
            return "This item has no text representation the keyboard can insert."
        case .insertionFailed:
            return "The host app did not accept inserted text."
        case .emptySelection:
            return "Select a saved item before inserting from the keyboard."
        }
    }
}

public struct MobileKeyboardPasteService {
    private let insertTextHandler: @MainActor (String) -> Bool

    public init(insertTextHandler: @escaping @MainActor (String) -> Bool) {
        self.insertTextHandler = insertTextHandler
    }

    @MainActor
    public func paste(
        _ item: ClipboardItem?,
        format: PasteFormat = .plainText,
        configuration: MobileIntegrationConfiguration
    ) -> MobileKeyboardPasteResult {
        guard let item else {
            return MobileKeyboardPasteResult(outcome: .emptySelection, format: format)
        }

        if configuration.isKeyboardExtensionEnabled && !configuration.hasKeyboardFullAccess {
            return MobileKeyboardPasteResult(
                outcome: .fullAccessRequired,
                format: format,
                fullAccessExplanation: MobileKeyboardFullAccessExplanation()
            )
        }

        let text = ClipboardPlainTextRenderer.plainText(for: item)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return MobileKeyboardPasteResult(outcome: .noTextAvailable, format: format)
        }

        let inserted = insertTextHandler(text)
        return MobileKeyboardPasteResult(
            outcome: inserted ? .insertedText : .insertionFailed,
            format: format,
            characterCount: text.count
        )
    }
}
