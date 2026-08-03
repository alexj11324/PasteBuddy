#if canImport(AppIntents)
import AppIntents
import PasteBuddyCore

struct PasteBuddySearchClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Search PasteBuddy Clipboard"
    static let description = IntentDescription("Search local PasteBuddy clipboard history and return matching item titles.")

    @Parameter(title: "Query")
    var query: String

    @Parameter(title: "Result Limit")
    var limit: Int?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = PasteBuddyStore()
        await store.loadAsync()
        let service = AutomationActionService(store: store)
        let result = try service.searchClipboard(query: query, limit: limit ?? 5)
        return .result(dialog: IntentDialog(stringLiteral: result.displaySummary))
    }
}

struct PasteBuddyCopyFirstMatchIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy First PasteBuddy Match"
    static let description = IntentDescription("Find the first matching local PasteBuddy item and copy it to the clipboard.")

    @Parameter(title: "Query")
    var query: String

    @Parameter(title: "Plain Text")
    var plainText: Bool?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = PasteBuddyStore()
        await store.loadAsync()
        let service = AutomationActionService(store: store)
        let format: PasteFormat = plainText == true ? .plainText : store.defaultPasteFormat
        let item = try await store.hydratedItemForTransfer(
            service.firstMatchingItem(query: query)
        )
        PasteboardWriter.copy(item, format: format)
        let result = AutomationItemTransferResult(
            item: item,
            format: format,
            destination: .clipboard
        )
        return .result(dialog: IntentDialog(stringLiteral: result.displaySummary))
    }
}

struct PasteBuddyPasteFirstMatchIntent: AppIntent {
    static let title: LocalizedStringResource = "Paste First PasteBuddy Match"
    static let description = IntentDescription("Find the first matching local PasteBuddy item and insert it into the frontmost app.")

    @Parameter(title: "Query")
    var query: String

    @Parameter(title: "Plain Text")
    var plainText: Bool?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = PasteBuddyStore()
        await store.loadAsync()
        let service = AutomationActionService(store: store)
        let format: PasteFormat = plainText == true ? .plainText : store.defaultPasteFormat
        let item = try await store.hydratedItemForTransfer(
            service.firstMatchingItem(query: query)
        )
        let result = AutomationItemTransferResult(
            item: item,
            format: format,
            destination: .frontmostApp
        )
        let pasteResult = await PasteboardWriter.pasteToFrontmostAppAsync(item, format: format)
        return .result(dialog: IntentDialog(stringLiteral: pasteResult.statusMessage.isEmpty ? result.displaySummary : pasteResult.statusMessage))
    }
}

struct PasteBuddyCreatePinboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Create PasteBuddy Pinboard"
    static let description = IntentDescription("Create a local PasteBuddy pinboard.")

    @Parameter(title: "Name")
    var name: String

    @Parameter(title: "Color Hex")
    var colorHex: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = PasteBuddyStore()
        await store.loadAsync()
        let service = AutomationActionService(store: store)
        do {
            let pinboard = try service.createPinboard(name: name, colorHex: colorHex)
            await store.flushPendingSave()
            return .result(dialog: IntentDialog(stringLiteral: "Created PasteBuddy pinboard: \(pinboard.name)."))
        } catch {
            await store.flushPendingSave()
            throw error
        }
    }
}

struct PasteBuddySaveFirstMatchToPinboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Save PasteBuddy Match to Pinboard"
    static let description = IntentDescription("Find the first matching local PasteBuddy item and save it to a named pinboard.")

    @Parameter(title: "Query")
    var query: String

    @Parameter(title: "Pinboard Name")
    var pinboardName: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = PasteBuddyStore()
        await store.loadAsync()
        let service = AutomationActionService(store: store)
        do {
            let result = try service.pinFirstMatchingItem(query: query, toPinboardNamed: pinboardName)
            await store.flushPendingSave()
            return .result(dialog: IntentDialog(stringLiteral: "Saved \(result.item.title) to \(result.pinboard.name)."))
        } catch {
            await store.flushPendingSave()
            throw error
        }
    }
}

struct PasteBuddyAppShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .blue

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
