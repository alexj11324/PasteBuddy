#if canImport(AppIntents)
import AppIntents
import PasteBuddyCore

extension AutomationContentKind: AppEnum {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "PasteBuddy Content Type"

    public static var caseDisplayRepresentations: [AutomationContentKind: DisplayRepresentation] = [
        .text: "Text",
        .url: "URL",
        .fileURL: "File URL"
    ]
}

struct PasteBuddySearchClipboardIntent: AppIntent {
    static var title: LocalizedStringResource = "Search PasteBuddy Clipboard"
    static var description = IntentDescription("Search local PasteBuddy clipboard history and return matching item titles.")

    @Parameter(title: "Query")
    var query: String

    @Parameter(title: "Result Limit")
    var limit: Int?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = PasteBuddyStore()
        store.load()
        let service = AutomationActionService(store: store)
        let result = try service.searchClipboard(query: query, limit: limit ?? 5)
        return .result(dialog: IntentDialog(stringLiteral: result.displaySummary))
    }
}

struct PasteBuddyCreateTextItemIntent: AppIntent {
    static var title: LocalizedStringResource = "Create PasteBuddy Text Item"
    static var description = IntentDescription("Create a local encrypted PasteBuddy text item.")

    @Parameter(title: "Text")
    var text: String

    @Parameter(title: "Title")
    var title: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = PasteBuddyStore()
        store.load()
        let service = AutomationActionService(store: store)
        let summary = try service.createTextItem(text: text, title: title)
        return .result(dialog: IntentDialog(stringLiteral: "Created PasteBuddy item: \(summary.title)."))
    }
}

struct PasteBuddyCopyFirstMatchIntent: AppIntent {
    static var title: LocalizedStringResource = "Copy First PasteBuddy Match"
    static var description = IntentDescription("Find the first matching local PasteBuddy item and copy it to the clipboard.")

    @Parameter(title: "Query")
    var query: String

    @Parameter(title: "Plain Text")
    var plainText: Bool?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = PasteBuddyStore()
        store.load()
        let service = AutomationActionService(store: store)
        let result = try service.transferFirstMatchingItem(
            query: query,
            format: plainText == true ? .plainText : store.defaultPasteFormat,
            destination: .clipboard
        ) { item, format in
            PasteboardWriter.copy(item, format: format)
        }
        return .result(dialog: IntentDialog(stringLiteral: result.displaySummary))
    }
}

struct PasteBuddyPasteFirstMatchIntent: AppIntent {
    static var title: LocalizedStringResource = "Paste First PasteBuddy Match"
    static var description = IntentDescription("Find the first matching local PasteBuddy item and insert it into the frontmost app.")

    @Parameter(title: "Query")
    var query: String

    @Parameter(title: "Plain Text")
    var plainText: Bool?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = PasteBuddyStore()
        store.load()
        let service = AutomationActionService(store: store)
        var pasteResult: DirectPasteResult?
        let result = try service.transferFirstMatchingItem(
            query: query,
            format: plainText == true ? .plainText : store.defaultPasteFormat,
            destination: .frontmostApp
        ) { item, format in
            pasteResult = PasteboardWriter.pasteToFrontmostApp(item, format: format)
        }
        return .result(dialog: IntentDialog(stringLiteral: pasteResult?.statusMessage ?? result.displaySummary))
    }
}

struct PasteBuddyCreatePinboardIntent: AppIntent {
    static var title: LocalizedStringResource = "Create PasteBuddy Pinboard"
    static var description = IntentDescription("Create a local encrypted PasteBuddy pinboard.")

    @Parameter(title: "Name")
    var name: String

    @Parameter(title: "Color Hex")
    var colorHex: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = PasteBuddyStore()
        store.load()
        let service = AutomationActionService(store: store)
        let pinboard = try service.createPinboard(name: name, colorHex: colorHex)
        return .result(dialog: IntentDialog(stringLiteral: "Created PasteBuddy pinboard: \(pinboard.name)."))
    }
}

struct PasteBuddyCreateContentItemIntent: AppIntent {
    static var title: LocalizedStringResource = "Create PasteBuddy Content Item"
    static var description = IntentDescription("Create a local encrypted PasteBuddy text, URL, or file URL item and optionally save it to a pinboard.")

    @Parameter(title: "Content Type")
    var contentKind: AutomationContentKind

    @Parameter(title: "Content")
    var value: String

    @Parameter(title: "Title")
    var title: String?

    @Parameter(title: "Pinboard Name")
    var pinboardName: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = PasteBuddyStore()
        store.load()
        let service = AutomationActionService(store: store)
        let result = try service.createContentItem(
            kind: contentKind,
            value: value,
            title: title,
            pinboardName: pinboardName
        )
        return .result(dialog: IntentDialog(stringLiteral: result.displaySummary))
    }
}

struct PasteBuddySaveFirstMatchToPinboardIntent: AppIntent {
    static var title: LocalizedStringResource = "Save PasteBuddy Match to Pinboard"
    static var description = IntentDescription("Find the first matching local PasteBuddy item and save it to a named pinboard.")

    @Parameter(title: "Query")
    var query: String

    @Parameter(title: "Pinboard Name")
    var pinboardName: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = PasteBuddyStore()
        store.load()
        let service = AutomationActionService(store: store)
        let result = try service.pinFirstMatchingItem(query: query, toPinboardNamed: pinboardName)
        return .result(dialog: IntentDialog(stringLiteral: "Saved \(result.item.title) to \(result.pinboard.name)."))
    }
}

struct PasteBuddyAppShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PasteBuddySearchClipboardIntent(),
            phrases: [
                "Search \(.applicationName) clipboard",
                "Find in \(.applicationName)"
            ],
            shortTitle: "Search Clipboard",
            systemImageName: "magnifyingglass"
        )

        AppShortcut(
            intent: PasteBuddyCreateTextItemIntent(),
            phrases: [
                "Create \(.applicationName) text item",
                "Save text to \(.applicationName)"
            ],
            shortTitle: "Create Text",
            systemImageName: "square.and.pencil"
        )

        AppShortcut(
            intent: PasteBuddyCopyFirstMatchIntent(),
            phrases: [
                "Copy from \(.applicationName)",
                "Copy first \(.applicationName) match"
            ],
            shortTitle: "Copy Match",
            systemImageName: "doc.on.clipboard"
        )

        AppShortcut(
            intent: PasteBuddyPasteFirstMatchIntent(),
            phrases: [
                "Paste from \(.applicationName)",
                "Insert first \(.applicationName) match"
            ],
            shortTitle: "Paste Match",
            systemImageName: "text.insert"
        )

        AppShortcut(
            intent: PasteBuddyCreatePinboardIntent(),
            phrases: [
                "Create \(.applicationName) pinboard",
                "Make a \(.applicationName) collection"
            ],
            shortTitle: "Create Pinboard",
            systemImageName: "pin"
        )

        AppShortcut(
            intent: PasteBuddyCreateContentItemIntent(),
            phrases: [
                "Create \(.applicationName) content item",
                "Save content to \(.applicationName)"
            ],
            shortTitle: "Create Content",
            systemImageName: "doc.badge.plus"
        )

        AppShortcut(
            intent: PasteBuddySaveFirstMatchToPinboardIntent(),
            phrases: [
                "Save \(.applicationName) match to pinboard",
                "Pin first \(.applicationName) match"
            ],
            shortTitle: "Pin Match",
            systemImageName: "pin.fill"
        )
    }
}
#endif
