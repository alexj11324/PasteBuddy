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
            return "No PasteBuddy items matched \"\(query)\"."
        }
        let titles = items.map(\.title).joined(separator: ", ")
        return "\(items.count) PasteBuddy item(s) matched \"\(query)\": \(titles)"
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

public enum AutomationContentKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case text
    case url
    case fileURL

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .text: "Text"
        case .url: "URL"
        case .fileURL: "File URL"
        }
    }
}

public struct AutomationCreatedItemResult: Codable, Equatable, Sendable {
    public var item: AutomationItemSummary
    public var pinboard: AutomationPinboardSummary?

    public init(item: ClipboardItem, pinboard: Pinboard? = nil) {
        self.item = AutomationItemSummary(item: item)
        self.pinboard = pinboard.map(AutomationPinboardSummary.init(pinboard:))
    }

    public var displaySummary: String {
        if let pinboard {
            return "Created PasteBuddy item \"\(item.title)\" and saved it to \(pinboard.name)."
        }
        return "Created PasteBuddy item \"\(item.title)\"."
    }
}

public enum AutomationItemTransferDestination: String, CaseIterable, Codable, Identifiable, Sendable {
    case clipboard
    case frontmostApp

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .clipboard: "Clipboard"
        case .frontmostApp: "Frontmost App"
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
            return "Copied PasteBuddy item \"\(item.title)\" to the clipboard."
        case .frontmostApp:
            return "Prepared PasteBuddy item \"\(item.title)\" for insertion into the frontmost app."
        }
    }
}

public enum AutomationActionError: LocalizedError, Equatable {
    case emptyQuery
    case emptyText
    case emptyContent
    case emptyPinboardName
    case contentTypeDisabled(ClipboardContentType)
    case sensitiveTextBlocked
    case captureRuleBlocked(String)
    case noMatchingItem
    case pinboardNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .emptyQuery:
            "Enter a search query before running this PasteBuddy action."
        case .emptyText:
            "Enter text before creating a PasteBuddy item."
        case .emptyContent:
            "Enter content before creating a PasteBuddy item."
        case .emptyPinboardName:
            "Enter a pinboard name before running this PasteBuddy action."
        case .contentTypeDisabled(let type):
            "\(type.displayName) capture is disabled for PasteBuddy Shortcuts."
        case .sensitiveTextBlocked:
            "PasteBuddy blocked this action because the text looks sensitive."
        case .captureRuleBlocked(let ruleName):
            "PasteBuddy blocked this action because it matched the local capture rule \"\(ruleName)\"."
        case .noMatchingItem:
            "No matching PasteBuddy item was found."
        case .pinboardNotFound(let name):
            "No PasteBuddy pinboard named \"\(name)\" was found."
        }
    }
}

@MainActor
public final class AutomationActionService {
    private let store: PasteBuddyStore

    public init(store: PasteBuddyStore) {
        self.store = store
    }

    public func searchClipboard(query: String, limit: Int = 5) throws -> AutomationSearchResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AutomationActionError.emptyQuery }

        let cappedLimit = min(max(limit, 1), 25)
        let items = store.snapshot.items
            .filter { $0.matches(trimmed) }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(cappedLimit)
            .map(AutomationItemSummary.init(item:))

        return AutomationSearchResult(query: trimmed, items: Array(items))
    }

    public func createTextItem(text: String, title: String? = nil) throws -> AutomationItemSummary {
        try createContentItem(kind: .text, value: text, title: title).item
    }

    public func createContentItem(
        kind: AutomationContentKind,
        value: String,
        title: String? = nil,
        pinboardName: String? = nil
    ) throws -> AutomationCreatedItemResult {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            if kind == .text {
                throw AutomationActionError.emptyText
            }
            throw AutomationActionError.emptyContent
        }

        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: ClipboardItem
        switch kind {
        case .text:
            candidate = ClipboardItem(
                sourceAppName: "PasteBuddy Shortcuts",
                deviceName: PasteBuddyStore.defaultDeviceName,
                contentType: .text,
                title: trimmedTitle?.isEmpty == false ? trimmedTitle! : trimmedValue.singleLinePreview,
                payload: ClipboardPayload(text: value)
            )
        case .url:
            candidate = ClipboardItem(
                sourceAppName: "PasteBuddy Shortcuts",
                deviceName: PasteBuddyStore.defaultDeviceName,
                contentType: .url,
                title: trimmedTitle?.isEmpty == false ? trimmedTitle! : trimmedValue,
                payload: ClipboardPayload(urlString: trimmedValue)
            )
        case .fileURL:
            candidate = ClipboardItem(
                sourceAppName: "PasteBuddy Shortcuts",
                deviceName: PasteBuddyStore.defaultDeviceName,
                contentType: .file,
                title: trimmedTitle?.isEmpty == false ? trimmedTitle! : URL(string: trimmedValue)?.lastPathComponent ?? "Shortcut File",
                payload: ClipboardPayload(fileURLString: trimmedValue)
            )
        }

        try validateShortcutItem(candidate)
        let item = store.addCapturedItem(candidate)
        let pinboard = try optionalPinboard(named: pinboardName)
        if let pinboard {
            store.pinItem(item.id, to: pinboard.id)
            let updatedPinboard = store.snapshot.pinboards.first(where: { $0.id == pinboard.id }) ?? pinboard
            return AutomationCreatedItemResult(item: item, pinboard: updatedPinboard)
        }
        return AutomationCreatedItemResult(item: item)
    }

    public func createPinboard(name: String, colorHex: String? = nil) throws -> AutomationPinboardSummary {
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
    ) throws -> AutomationPinboardItemResult {
        let item = try firstMatchingItem(query: query)
        let pinboard = try pinboard(named: pinboardName)
        store.pinItem(item.id, to: pinboard.id)
        guard let updatedPinboard = store.snapshot.pinboards.first(where: { $0.id == pinboard.id }) else {
            throw AutomationActionError.pinboardNotFound(pinboard.name)
        }
        return AutomationPinboardItemResult(item: item, pinboard: updatedPinboard)
    }

    public func transferFirstMatchingItem(
        query: String,
        format: PasteFormat = .original,
        destination: AutomationItemTransferDestination = .clipboard,
        transfer: (ClipboardItem, PasteFormat) -> Void
    ) throws -> AutomationItemTransferResult {
        let item = try firstMatchingItem(query: query)
        transfer(item, format)
        return AutomationItemTransferResult(
            item: item,
            format: format,
            destination: destination
        )
    }

    public func firstMatchingItem(query: String) throws -> ClipboardItem {
        let result = try searchClipboard(query: query, limit: 1)
        guard let summary = result.items.first,
              let item = store.snapshot.items.first(where: { $0.id == summary.id }) else {
            throw AutomationActionError.noMatchingItem
        }
        return item
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

    private func optionalPinboard(named name: String?) throws -> Pinboard? {
        guard let name else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        return try pinboard(named: trimmedName)
    }

    private func validateShortcutItem(_ item: ClipboardItem) throws {
        let decision = store.snapshot.privacy.captureDecision(
            for: item,
            sourceApplicationName: item.sourceAppName
        )
        guard let blockReason = decision.blockReason else { return }
        switch blockReason {
        case .contentTypeDisabled(let type):
            throw AutomationActionError.contentTypeDisabled(type)
        case .sensitiveText:
            throw AutomationActionError.sensitiveTextBlocked
        case .customCaptureRule(let rule):
            throw AutomationActionError.captureRuleBlocked(rule.name)
        case .capturePaused, .sourceApplicationExcluded:
            throw AutomationActionError.captureRuleBlocked(blockReason.displayName)
        }
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
