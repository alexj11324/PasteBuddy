import Foundation

public struct AutomationItemSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var labels: [String]
    public var reuseCategory: ClipboardReuseCategory
    public var contentType: ClipboardContentType
    public var sourceAppName: String
    public var deviceName: String
    public var createdAt: Date

    public init(item: ClipboardItem) {
        self.id = item.id
        self.title = item.title
        self.labels = item.labels
        self.reuseCategory = item.reuseCategory
        self.contentType = item.contentType
        self.sourceAppName = item.sourceAppName
        self.deviceName = item.deviceName
        self.createdAt = item.createdAt
    }
}

public struct AutomationSearchResult: Codable, Equatable, Sendable {
    public var query: String
    public var items: [AutomationItemSummary]

    public init(query: String, items: [AutomationItemSummary]) {
        self.query = query
        self.items = items
    }

    public var displaySummary: String {
        guard !items.isEmpty else {
            return PasteBuddyLocalization.format(
                "automation.search.no_matches",
                defaultValue: "No PasteBuddy items matched \"%@\".",
                query
            )
        }
        let titles = items.map(\.title).joined(separator: ", ")
        return PasteBuddyLocalization.format(
            items.count == 1 ? "automation.search.match_one" : "automation.search.match_many",
            defaultValue: items.count == 1 ? "%d PasteBuddy item matched \"%@\": %@" : "%d PasteBuddy items matched \"%@\": %@",
            items.count,
            query,
            titles
        )
    }
}

public struct AutomationPinboardSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var colorHex: String
    public var itemCount: Int

    public init(pinboard: Pinboard) {
        self.id = pinboard.id
        self.name = pinboard.name
        self.colorHex = pinboard.colorHex
        self.itemCount = pinboard.itemIDs.count
    }
}

public struct AutomationPinboardItemResult: Codable, Equatable, Sendable {
    public var item: AutomationItemSummary
    public var pinboard: AutomationPinboardSummary

    public init(item: ClipboardItem, pinboard: Pinboard) {
        self.item = AutomationItemSummary(item: item)
        self.pinboard = AutomationPinboardSummary(pinboard: pinboard)
    }
}

public enum AutomationItemTransferDestination: String, CaseIterable, Codable, Identifiable, Sendable {
    case clipboard
    case frontmostApp

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .clipboard:
            PasteBuddyLocalization.string("automation.destination.clipboard", defaultValue: "Clipboard")
        case .frontmostApp:
            PasteBuddyLocalization.string("automation.destination.frontmost_app", defaultValue: "Frontmost App")
        }
    }
}

public struct AutomationItemTransferResult: Codable, Equatable, Sendable {
    public var item: AutomationItemSummary
    public var format: PasteFormat
    public var destination: AutomationItemTransferDestination

    public init(
        item: ClipboardItem,
        format: PasteFormat,
        destination: AutomationItemTransferDestination
    ) {
        self.item = AutomationItemSummary(item: item)
        self.format = format
        self.destination = destination
    }

    public var displaySummary: String {
        switch destination {
        case .clipboard:
            return PasteBuddyLocalization.format(
                "automation.transfer.copied_to_clipboard",
                defaultValue: "Copied PasteBuddy item \"%@\" to the clipboard.",
                item.title
            )
        case .frontmostApp:
            return PasteBuddyLocalization.format(
                "automation.transfer.prepared_for_frontmost_app",
                defaultValue: "Prepared PasteBuddy item \"%@\" for insertion into the frontmost app.",
                item.title
            )
        }
    }
}

public enum AutomationActionError: LocalizedError, Equatable {
    case emptyQuery
    case emptyPinboardName
    case historyLocked
    case noMatchingItem
    case pinboardNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .emptyQuery:
            PasteBuddyLocalization.string(
                "automation.error.empty_query",
                defaultValue: "Enter a search query before running this PasteBuddy action."
            )
        case .emptyPinboardName:
            PasteBuddyLocalization.string(
                "automation.error.empty_pinboard_name",
                defaultValue: "Enter a pinboard name before running this PasteBuddy action."
            )
        case .historyLocked:
            PasteBuddyLocalization.string(
                "automation.error.history_locked",
                defaultValue: "Unlock PasteBuddy history before running this action."
            )
        case .noMatchingItem:
            PasteBuddyLocalization.string(
                "automation.error.no_matching_item",
                defaultValue: "No matching PasteBuddy item was found."
            )
        case .pinboardNotFound(let name):
            PasteBuddyLocalization.format(
                "automation.error.pinboard_not_found",
                defaultValue: "No PasteBuddy pinboard named \"%@\" was found.",
                name
            )
        }
    }
}

@MainActor
public final class AutomationActionService {
    private let store: PasteBuddyStore

    public init(store: PasteBuddyStore) {
        self.store = store
    }

    public func searchClipboard(query: String, limit: Int = 5) async throws -> AutomationSearchResult {
        try requireReadableHistory()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AutomationActionError.emptyQuery }

        let cappedLimit = min(max(limit, 1), 25)
        let page = try await store.searchItemsPage(query: trimmed, limit: cappedLimit)
        try requireReadableHistory()
        let items = currentItems(from: page)
            .map(AutomationItemSummary.init(item:))

        return AutomationSearchResult(query: trimmed, items: items)
    }

    public func createPinboard(name: String, colorHex: String? = nil) throws -> AutomationPinboardSummary {
        try store.requirePersistenceReady()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw AutomationActionError.emptyPinboardName }
        let pinboard = store.createPinboard(
            named: trimmedName,
            colorHex: normalizedColorHex(colorHex) ?? "#7C9A92"
        )
        return AutomationPinboardSummary(pinboard: pinboard)
    }

    public func pinFirstMatchingItem(
        query: String,
        toPinboardNamed pinboardName: String
    ) async throws -> AutomationPinboardItemResult {
        let matchedItem = try await firstMatchingItem(query: query)
        try requireReadableHistory()
        guard let item = store.snapshot.items.first(where: { $0.id == matchedItem.id }) else {
            throw AutomationActionError.noMatchingItem
        }
        let pinboard = try pinboard(named: pinboardName)
        store.pinItem(item.id, to: pinboard.id)
        try requireReadableHistory()
        guard let updatedPinboard = store.snapshot.pinboards.first(where: { $0.id == pinboard.id }) else {
            throw AutomationActionError.pinboardNotFound(pinboard.name)
        }
        guard updatedPinboard.itemIDs.contains(item.id) else {
            throw AutomationActionError.noMatchingItem
        }
        return AutomationPinboardItemResult(item: item, pinboard: updatedPinboard)
    }

    public func transferFirstMatchingItem(
        query: String,
        format: PasteFormat = .original,
        destination: AutomationItemTransferDestination = .clipboard,
        transfer: (ClipboardItem, PasteFormat) -> Void
    ) async throws -> AutomationItemTransferResult {
        let matchedItem = try await firstMatchingItem(query: query)
        try requireReadableHistory()
        guard let item = store.snapshot.items.first(where: { $0.id == matchedItem.id }) else {
            throw AutomationActionError.noMatchingItem
        }
        transfer(item, format)
        return AutomationItemTransferResult(
            item: item,
            format: format,
            destination: destination
        )
    }

    public func firstMatchingItem(query: String) async throws -> ClipboardItem {
        let result = try await searchClipboard(query: query, limit: 1)
        try requireReadableHistory()
        guard let summary = result.items.first,
              let item = store.snapshot.items.first(where: { $0.id == summary.id }) else {
            throw AutomationActionError.noMatchingItem
        }
        return item
    }

    private func requireReadableHistory() throws {
        try store.requirePersistenceReady()
        guard !store.isHistoryAccessLocked else { throw AutomationActionError.historyLocked }
    }

    private func currentItems(from candidates: [ClipboardItem]) -> [ClipboardItem] {
        var currentItemsByID: [UUID: ClipboardItem] = [:]
        currentItemsByID.reserveCapacity(store.snapshot.items.count)
        for item in store.snapshot.items {
            currentItemsByID[item.id] = item
        }
        return candidates.compactMap { currentItemsByID[$0.id] }
    }

    private func pinboard(named name: String) throws -> Pinboard {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw AutomationActionError.emptyPinboardName }
        guard let pinboard = store.snapshot.pinboards.first(where: {
            $0.name.compare(trimmedName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else {
            throw AutomationActionError.pinboardNotFound(trimmedName)
        }
        return pinboard
    }

    private func normalizedColorHex(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        return "#\(hex.uppercased())"
    }
}
