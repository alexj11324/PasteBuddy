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
        case .insertedText:
            PasteBuddyLocalization.string("mobile.keyboard_paste.outcome.inserted_text", defaultValue: "Inserted text")
        case .fullAccessRequired:
            PasteBuddyLocalization.string("mobile.keyboard_paste.outcome.full_access_required", defaultValue: "Full Access required")
        case .noTextAvailable:
            PasteBuddyLocalization.string("mobile.keyboard_paste.outcome.no_text_available", defaultValue: "No text available")
        case .insertionFailed:
            PasteBuddyLocalization.string("mobile.keyboard_paste.outcome.insertion_failed", defaultValue: "Insertion failed")
        case .emptySelection:
            PasteBuddyLocalization.string("mobile.keyboard_paste.outcome.empty_selection", defaultValue: "No item selected")
        }
    }
}

public struct MobileKeyboardFullAccessExplanation: Codable, Equatable, Sendable {
    public var title: String
    public var detail: String
    public var actionTitle: String

    public init(
        title: String = PasteBuddyLocalization.string("mobile.keyboard_full_access_explanation.title", defaultValue: "Enable Full Access for PasteBuddy Keyboard"),
        detail: String = MobileKeyboardExtensionCapabilities().fullAccessPrivacyExplanation,
        actionTitle: String = PasteBuddyLocalization.string("mobile.keyboard_full_access_explanation.action_title", defaultValue: "Open Keyboard Settings")
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
            return PasteBuddyLocalization.format(
                "mobile.keyboard_paste.status_inserted_characters",
                defaultValue: "Inserted %d character(s).",
                characterCount
            )
        case .fullAccessRequired:
            return fullAccessExplanation?.title
                ?? PasteBuddyLocalization.string(
                    "mobile.keyboard_paste.status_full_access_required",
                    defaultValue: "Keyboard Full Access is required."
                )
        case .noTextAvailable:
            return PasteBuddyLocalization.string(
                "mobile.keyboard_paste.status_no_text_available",
                defaultValue: "This item has no text representation the keyboard can insert."
            )
        case .insertionFailed:
            return PasteBuddyLocalization.string(
                "mobile.keyboard_paste.status_insertion_failed",
                defaultValue: "The host app did not accept inserted text."
            )
        case .emptySelection:
            return PasteBuddyLocalization.string(
                "mobile.keyboard_paste.status_empty_selection",
                defaultValue: "Select a saved item before inserting from the keyboard."
            )
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
