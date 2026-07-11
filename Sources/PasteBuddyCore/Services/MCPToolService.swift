import Foundation

public struct MCPPinboardSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var colorHex: String
    public var itemCount: Int
    public var isShared: Bool

    public init(pinboard: Pinboard, visibleItemIDs: Set<UUID>? = nil) {
        self.id = pinboard.id
        self.name = pinboard.name
        self.colorHex = pinboard.colorHex
        if let visibleItemIDs {
            self.itemCount = pinboard.itemIDs.filter(visibleItemIDs.contains).count
        } else {
            self.itemCount = pinboard.itemIDs.count
        }
        self.isShared = pinboard.sharing != nil
    }
}

public struct MCPHistorySearchResponse: Codable, Equatable, Sendable {
    public var query: String
    public var items: [AutomationItemSummary]
    public var payloadsOmitted: Bool

    public init(query: String, items: [AutomationItemSummary], payloadsOmitted: Bool = true) {
        self.query = query
        self.items = items
        self.payloadsOmitted = payloadsOmitted
    }
}

public struct MCPClipboardItemPayload: Codable, Equatable, Sendable {
    public var text: String?
    public var urlString: String?
    public var fileURLString: String?
    public var plainText: String
    public var ocrText: String?
    public var imageByteCount: Int?
    public var imageDataBase64: String?

    public init(item: ClipboardItem, includeImageData: Bool = false) {
        self.text = item.payload.text
        self.urlString = item.payload.urlString
        self.fileURLString = item.payload.fileURLString
        self.plainText = ClipboardPlainTextRenderer.plainText(for: item)
        self.ocrText = item.payload.ocrText
        self.imageByteCount = item.payload.imageData?.count
        self.imageDataBase64 = includeImageData ? item.payload.imageData?.base64EncodedString() : nil
    }
}

public struct MCPClipboardItemResponse: Codable, Equatable, Sendable {
    public var item: AutomationItemSummary
    public var payload: MCPClipboardItemPayload
    public var payloadIncluded: Bool
    public var imageDataOmitted: Bool

    public init(item: ClipboardItem, includeImageData: Bool = false) {
        self.item = AutomationItemSummary(item: item)
        self.payload = MCPClipboardItemPayload(item: item, includeImageData: includeImageData)
        self.payloadIncluded = true
        self.imageDataOmitted = item.payload.imageData != nil && !includeImageData
    }
}

public struct MCPPinboardListResponse: Codable, Equatable, Sendable {
    public var pinboards: [MCPPinboardSummary]
}

public struct MCPPinboardMutationResponse: Codable, Equatable, Sendable {
    public var pinboard: MCPPinboardSummary
}

public struct MCPPinFirstMatchResponse: Codable, Equatable, Sendable {
    public var item: AutomationItemSummary
    public var pinboard: MCPPinboardSummary
}

public enum MCPToolServiceError: LocalizedError, Equatable {
    case serverDisabled
    case toolDisabled(MCPToolName)
    case historyLocked
    case missingArgument(String)
    case invalidPinboard
    case noMatchingItem
    case privacyBlocked(String)

    public var errorDescription: String? {
        switch self {
        case .serverDisabled:
            "PasteBuddy MCP access is disabled. Enable it in Settings before connecting an MCP client."
        case .toolDisabled(let tool):
            "\(tool.displayName) is disabled for MCP clients."
        case .historyLocked:
            PasteBuddyLocalization.string(
                "mcp.error.history_locked",
                defaultValue: "Unlock PasteBuddy history before using MCP clipboard tools."
            )
        case .missingArgument(let name):
            "Missing required argument: \(name)."
        case .invalidPinboard:
            "No matching pinboard was found."
        case .noMatchingItem:
            "No matching clipboard item was found."
        case .privacyBlocked(let reason):
            "PasteBuddy privacy rules blocked MCP access to this item: \(reason)."
        }
    }
}

@MainActor
public final class MCPToolService {
    private let store: PasteBuddyStore

    public init(store: PasteBuddyStore) {
        self.store = store
    }

    public func searchHistory(query: String, limit: Int = 5) async throws -> MCPHistorySearchResponse {
        do {
            try require(.searchHistory)
            try requireHistoryUnlocked()
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw MCPToolServiceError.missingArgument("query") }
            let cappedLimit = min(max(limit, 1), 25)
            let items = try await visibleItems(matching: trimmed, limit: cappedLimit)
                .map(AutomationItemSummary.init(item:))
            recordAccess(tool: .searchHistory, outcome: .succeeded, resultCount: items.count)
            return MCPHistorySearchResponse(query: trimmed, items: items)
        } catch {
            recordFailure(tool: .searchHistory, error: error)
            throw error
        }
    }

    public func retrieveItem(itemID: UUID, includeImageData: Bool = false) throws -> MCPClipboardItemResponse {
        do {
            try require(.retrieveItem)
            try requireHistoryUnlocked()
            guard let item = store.snapshot.items.first(where: { $0.id == itemID }) else {
                throw MCPToolServiceError.noMatchingItem
            }
            try requireMCPVisible(item)
            let response = MCPClipboardItemResponse(item: item, includeImageData: includeImageData)
            recordAccess(
                tool: .retrieveItem,
                outcome: .succeeded,
                itemID: item.id,
                payloadIncluded: response.payloadIncluded,
                imageDataIncluded: response.payload.imageDataBase64 != nil
            )
            return response
        } catch {
            recordFailure(tool: .retrieveItem, error: error, itemID: itemID)
            throw error
        }
    }

    public func listPinboards() throws -> MCPPinboardListResponse {
        do {
            try require(.listPinboards)
            try requireHistoryUnlocked()
            let visibleItemIDs = Set(store.snapshot.items.filter(isMCPVisible).map(\.id))
            let pinboards = store.snapshot.pinboards.map {
                MCPPinboardSummary(pinboard: $0, visibleItemIDs: visibleItemIDs)
            }
            recordAccess(tool: .listPinboards, outcome: .succeeded, resultCount: pinboards.count)
            return MCPPinboardListResponse(pinboards: pinboards)
        } catch {
            recordFailure(tool: .listPinboards, error: error)
            throw error
        }
    }

    public func createPinboard(name: String, colorHex: String? = nil) throws -> MCPPinboardMutationResponse {
        do {
            try require(.createPinboard)
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { throw MCPToolServiceError.missingArgument("name") }
            let pinboard = store.createPinboard(
                named: trimmedName,
                colorHex: normalizedColorHex(colorHex) ?? "#7C9A92"
            )
            recordAccess(tool: .createPinboard, outcome: .succeeded, pinboardID: pinboard.id)
            return MCPPinboardMutationResponse(pinboard: MCPPinboardSummary(pinboard: pinboard))
        } catch {
            recordFailure(tool: .createPinboard, error: error)
            throw error
        }
    }

    public func pinFirstMatch(query: String, pinboardID: UUID? = nil, pinboardName: String? = nil) async throws -> MCPPinFirstMatchResponse {
        do {
            try require(.pinFirstMatch)
            try requireHistoryUnlocked()
            let item = try await firstVisibleMatchingItem(query: query)
            guard let pinboard = resolvePinboard(id: pinboardID, name: pinboardName) else {
                throw MCPToolServiceError.invalidPinboard
            }
            store.pinItem(item.id, to: pinboard.id)
            guard let updatedPinboard = store.snapshot.pinboards.first(where: { $0.id == pinboard.id }) else {
                throw MCPToolServiceError.invalidPinboard
            }
            recordAccess(tool: .pinFirstMatch, outcome: .succeeded, itemID: item.id, pinboardID: pinboard.id)
            return MCPPinFirstMatchResponse(
                item: AutomationItemSummary(item: item),
                pinboard: MCPPinboardSummary(pinboard: updatedPinboard)
            )
        } catch {
            recordFailure(tool: .pinFirstMatch, error: error, pinboardID: pinboardID)
            throw error
        }
    }

    private func require(_ tool: MCPToolName) throws {
        try store.requirePersistenceReady()
        guard store.snapshot.mcp.isServerEnabled else {
            throw MCPToolServiceError.serverDisabled
        }
        guard store.snapshot.mcp.enabledTools.contains(tool) else {
            throw MCPToolServiceError.toolDisabled(tool)
        }
    }

    private func requireHistoryUnlocked() throws {
        guard !store.isHistoryAccessLocked else {
            throw MCPToolServiceError.historyLocked
        }
    }

    private func firstVisibleMatchingItem(query: String) async throws -> ClipboardItem {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MCPToolServiceError.missingArgument("query") }
        guard let item = try await visibleItems(matching: trimmed, limit: 1).first else {
            throw MCPToolServiceError.noMatchingItem
        }
        return item
    }

    private func visibleItems(matching query: String, limit: Int) async throws -> [ClipboardItem] {
        let resolvedLimit = max(limit, 0)
        guard resolvedLimit > 0 else { return [] }
        let pageSize = max(resolvedLimit, 25)
        var offset = 0
        var visibleItems: [ClipboardItem] = []
        while visibleItems.count < resolvedLimit {
            let page = try await store.searchItemsPage(query: query, offset: offset, limit: pageSize)
            guard !page.isEmpty else { break }
            for item in page where isMCPVisible(item) {
                visibleItems.append(item)
                if visibleItems.count == resolvedLimit {
                    break
                }
            }
            offset += page.count
            if page.count < pageSize {
                break
            }
        }
        return visibleItems
    }

    private func isMCPVisible(_ item: ClipboardItem) -> Bool {
        mcpVisibilityDecision(for: item).isAllowed
    }

    private func requireMCPVisible(_ item: ClipboardItem) throws {
        let decision = mcpVisibilityDecision(for: item)
        guard let blockReason = decision.blockReason else { return }
        throw MCPToolServiceError.privacyBlocked(blockReason.displayName)
    }

    private func mcpVisibilityDecision(for item: ClipboardItem) -> PrivacyCaptureDecision {
        store.snapshot.privacy.captureDecision(
            for: item,
            sourceApplicationName: item.sourceAppName
        )
    }

    private func recordFailure(
        tool: MCPToolName,
        error: Error,
        itemID: UUID? = nil,
        pinboardID: UUID? = nil
    ) {
        if error is PasteBuddyPersistenceError {
            return
        }
        if let serviceError = error as? MCPToolServiceError, serviceError == .serverDisabled {
            return
        }
        let outcome: MCPAccessOutcome
        if let serviceError = error as? MCPToolServiceError, case .toolDisabled = serviceError {
            outcome = .denied
        } else if let serviceError = error as? MCPToolServiceError, case .privacyBlocked = serviceError {
            outcome = .denied
        } else if let serviceError = error as? MCPToolServiceError, serviceError == .historyLocked {
            outcome = .denied
        } else {
            outcome = .failed
        }
        recordAccess(tool: tool, outcome: outcome, itemID: itemID, pinboardID: pinboardID)
    }

    private func recordAccess(
        tool: MCPToolName,
        outcome: MCPAccessOutcome,
        itemID: UUID? = nil,
        pinboardID: UUID? = nil,
        resultCount: Int? = nil,
        payloadIncluded: Bool = false,
        imageDataIncluded: Bool = false
    ) {
        store.recordMCPAccess(MCPAccessLogEntry(
            tool: tool,
            outcome: outcome,
            itemID: itemID,
            pinboardID: pinboardID,
            resultCount: resultCount,
            payloadIncluded: payloadIncluded,
            imageDataIncluded: imageDataIncluded
        ))
    }

    private func resolvePinboard(id: UUID?, name: String?) -> Pinboard? {
        if let id, let pinboard = store.snapshot.pinboards.first(where: { $0.id == id }) {
            return pinboard
        }
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedName, !trimmedName.isEmpty {
            return store.snapshot.pinboards.first {
                $0.name.compare(trimmedName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
        }
        return store.snapshot.pinboards.first
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
