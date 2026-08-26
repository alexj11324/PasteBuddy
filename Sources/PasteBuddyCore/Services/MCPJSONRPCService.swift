import Foundation

@MainActor
public final class MCPJSONRPCService {
    private let store: PasteBuddyStore
    private let encoder: JSONEncoder

    public init(store: PasteBuddyStore) {
        self.store = store
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .secondsSince1970
        self.encoder.outputFormatting = [.sortedKeys]
    }

    /// Handles one JSON-RPC message. Notifications intentionally return no body.
    public func handle(_ data: Data) async -> Data? {
        let request: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return encoded(errorResponse(id: NSNull(), code: -32600, message: "Invalid JSON-RPC request."))
            }
            request = object
        } catch {
            return encoded(errorResponse(id: NSNull(), code: -32700, message: "Invalid JSON."))
        }

        guard request["id"] != nil else { return nil }
        return encoded(await handle(request))
    }

    private func handle(_ request: [String: Any]) async -> [String: Any] {
        let id = request["id"] ?? NSNull()
        guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
            return errorResponse(id: id, code: -32600, message: "Invalid JSON-RPC request.")
        }

        do {
            switch method {
            case "initialize":
                return successResponse(id: id, result: initializeResult())
            case "ping":
                return successResponse(id: id, result: [:])
            case "tools/list":
                return successResponse(id: id, result: ["tools": toolDefinitions()])
            case "tools/call":
                return successResponse(
                    id: id,
                    result: try await callTool(params: request["params"] as? [String: Any] ?? [:])
                )
            default:
                return errorResponse(id: id, code: -32601, message: "Method not found: \(method).")
            }
        } catch {
            return errorResponse(id: id, code: -32000, message: error.localizedDescription)
        }
    }

    private func initializeResult() -> [String: Any] {
        [
            "protocolVersion": "2025-11-25",
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": [
                "name": "pastebuddy-mcp",
                "title": "PasteBuddy Local MCP",
                "version": "0.1.0"
            ],
            "instructions": "Local-first PasteBuddy MCP server. Turn on Agent Connection in PasteBuddy Settings before calling tools."
        ]
    }

    private func toolDefinitions() -> [[String: Any]] {
        guard store.snapshot.mcp.isServerEnabled else { return [] }
        return MCPToolName.allCases
            .filter(store.snapshot.mcp.enabledTools.contains)
            .map(toolDefinition)
    }

    private func toolDefinition(_ tool: MCPToolName) -> [String: Any] {
        let emptyProperties: [String: Any] = [:]
        switch tool {
        case .searchHistory:
            return definition(
                tool,
                description: "Search local PasteBuddy history and return metadata summaries without raw clipboard payloads.",
                properties: [
                    "query": ["type": "string"],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 25]
                ],
                required: ["query"]
            )
        case .retrieveItem:
            return definition(
                tool,
                description: "Retrieve one local clipboard item payload by ID. This tool must be explicitly enabled because it can return private clipboard data.",
                properties: [
                    "itemID": ["type": "string"],
                    "includeImageData": ["type": "boolean"]
                ],
                required: ["itemID"]
            )
        case .listPinboards:
            return definition(
                tool,
                description: "List local PasteBuddy pinboards with item counts and sharing state.",
                properties: emptyProperties
            )
        case .createPinboard:
            return definition(
                tool,
                description: "Create a local PasteBuddy pinboard.",
                properties: ["name": ["type": "string"], "colorHex": ["type": "string"]],
                required: ["name"]
            )
        case .pinFirstMatch:
            return definition(
                tool,
                description: "Search local history and pin the first matching item to a pinboard.",
                properties: [
                    "query": ["type": "string"],
                    "pinboardID": ["type": "string"],
                    "pinboardName": ["type": "string"]
                ],
                required: ["query"]
            )
        }
    }

    private func definition(
        _ tool: MCPToolName,
        description: String,
        properties: [String: Any],
        required: [String] = []
    ) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "properties": properties,
            "additionalProperties": false
        ]
        if !required.isEmpty { schema["required"] = required }
        return [
            "name": tool.rawValue,
            "title": tool.displayName,
            "description": description,
            "inputSchema": schema
        ]
    }

    private func callTool(params: [String: Any]) async throws -> [String: Any] {
        guard let name = params["name"] as? String, let tool = MCPToolName(rawValue: name) else {
            throw MCPToolServiceError.missingArgument("name")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let service = MCPToolService(store: store)

        do {
            let payload: Encodable
            switch tool {
            case .searchHistory:
                payload = try service.searchHistory(
                    query: requiredString("query", in: arguments),
                    limit: intValue("limit", in: arguments) ?? 5
                )
            case .retrieveItem:
                payload = try await service.retrieveItem(
                    itemID: try requiredUUID("itemID", in: arguments),
                    includeImageData: boolValue("includeImageData", in: arguments) ?? false
                )
            case .listPinboards:
                payload = try service.listPinboards()
            case .createPinboard:
                payload = try service.createPinboard(
                    name: requiredString("name", in: arguments),
                    colorHex: arguments["colorHex"] as? String
                )
            case .pinFirstMatch:
                payload = try service.pinFirstMatch(
                    query: requiredString("query", in: arguments),
                    pinboardID: uuidValue("pinboardID", in: arguments),
                    pinboardName: arguments["pinboardName"] as? String
                )
            }
            await store.flushPendingSave()
            return ["content": [["type": "text", "text": try jsonString(payload)]]]
        } catch {
            await store.flushPendingSave()
            throw error
        }
    }

    private func requiredString(_ name: String, in arguments: [String: Any]) throws -> String {
        guard let value = arguments[name] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPToolServiceError.missingArgument(name)
        }
        return value
    }

    private func intValue(_ name: String, in arguments: [String: Any]) -> Int? {
        (arguments[name] as? NSNumber)?.intValue
    }

    private func uuidValue(_ name: String, in arguments: [String: Any]) -> UUID? {
        (arguments[name] as? String).flatMap(UUID.init(uuidString:))
    }

    private func requiredUUID(_ name: String, in arguments: [String: Any]) throws -> UUID {
        guard let value = uuidValue(name, in: arguments) else {
            throw MCPToolServiceError.missingArgument(name)
        }
        return value
    }

    private func boolValue(_ name: String, in arguments: [String: Any]) -> Bool? {
        (arguments[name] as? NSNumber)?.boolValue
    }

    private func jsonString(_ value: Encodable) throws -> String {
        String(decoding: try encoder.encode(AnyEncodable(value)), as: UTF8.self)
    }

    private func successResponse(id: Any, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func errorResponse(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private func encoded(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

private struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void

    init(_ value: Encodable) {
        encodeValue = value.encode(to:)
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}
