import Foundation
import PasteBuddyCore

@MainActor
final class PasteBuddyMCPServer {
    private let storeLoader: @MainActor @Sendable () async throws -> PasteBuddyStore
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    init(
        storeLoader: @escaping @MainActor @Sendable () async throws -> PasteBuddyStore = {
            try await PasteBuddyStoreFactory.makeLoadedDefault()
        }
    ) {
        self.storeLoader = storeLoader
    }

    func run() async {
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            guard request["id"] != nil else {
                continue
            }
            let response = await handle(request)
            write(response)
        }
    }

    func handle(_ request: [String: Any]) async -> [String: Any] {
        let id = request["id"] ?? NSNull()
        guard let method = request["method"] as? String else {
            return errorResponse(id: id, code: -32600, message: "Invalid JSON-RPC request.")
        }

        do {
            switch method {
            case "initialize":
                return successResponse(id: id, result: initializeResult())
            case "ping":
                return successResponse(id: id, result: [:])
            case "tools/list":
                return successResponse(id: id, result: ["tools": try await toolDefinitions()])
            case "tools/call":
                return successResponse(id: id, result: try await callTool(params: request["params"] as? [String: Any] ?? [:]))
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
            "capabilities": [
                "tools": [
                    "listChanged": false
                ]
            ],
            "serverInfo": [
                "name": "pastebuddy-mcp",
                "title": "PasteBuddy Local MCP",
                "version": "0.1.0"
            ],
            "instructions": "Local-first PasteBuddy MCP server. Turn on Agent Connection in PasteBuddy Settings before calling tools. Tool details are exposed here for the connected Agent, not in the user settings UI."
        ]
    }

    private func toolDefinitions() async throws -> [[String: Any]] {
        let store = try await loadStore()
        guard store.snapshot.mcp.isServerEnabled else { return [] }

        return MCPToolName.allCases
            .filter { store.snapshot.mcp.enabledTools.contains($0) }
            .map(toolDefinition(for:))
    }

    private func toolDefinition(for tool: MCPToolName) -> [String: Any] {
        switch tool {
        case .searchHistory:
            return [
                "name": tool.rawValue,
                "title": tool.displayName,
                "description": "Search local PasteBuddy history and return metadata summaries without raw clipboard payloads.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string"],
                        "limit": ["type": "integer", "minimum": 1, "maximum": 25]
                    ],
                    "required": ["query"],
                    "additionalProperties": false
                ]
            ]
        case .retrieveItem:
            return [
                "name": tool.rawValue,
                "title": tool.displayName,
                "description": "Retrieve one local clipboard item payload by ID. This tool is disabled by default and must be explicitly enabled because it can return clipboard text, URLs, file paths, OCR text, and optionally image bytes.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "itemID": ["type": "string"],
                        "includeImageData": ["type": "boolean"]
                    ],
                    "required": ["itemID"],
                    "additionalProperties": false
                ]
            ]
        case .listPinboards:
            return [
                "name": tool.rawValue,
                "title": tool.displayName,
                "description": "List local PasteBuddy pinboards with item counts and sharing state.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false
                ]
            ]
        case .createPinboard:
            return [
                "name": tool.rawValue,
                "title": tool.displayName,
                "description": "Create a local PasteBuddy pinboard.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "colorHex": ["type": "string"]
                    ],
                    "required": ["name"],
                    "additionalProperties": false
                ]
            ]
        case .pinFirstMatch:
            return [
                "name": tool.rawValue,
                "title": tool.displayName,
                "description": "Search local history and pin the first matching item to a pinboard.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string"],
                        "pinboardID": ["type": "string"],
                        "pinboardName": ["type": "string"]
                    ],
                    "required": ["query"],
                    "additionalProperties": false
                ]
            ]
        }
    }

    private func callTool(params: [String: Any]) async throws -> [String: Any] {
        guard let name = params["name"] as? String,
              let tool = MCPToolName(rawValue: name) else {
            throw MCPToolServiceError.missingArgument("name")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let store = try await loadStore()
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
                payload = try service.retrieveItem(
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

            try await store.flushPendingSaveOrThrow()
            let json = try jsonString(payload)
            return [
                "content": [
                    [
                        "type": "text",
                        "text": json
                    ]
                ]
            ]
        } catch {
            try? await store.flushPendingSaveOrThrow()
            throw error
        }
    }

    private func loadStore() async throws -> PasteBuddyStore {
        try await storeLoader()
    }

    private func requiredString(_ name: String, in arguments: [String: Any]) throws -> String {
        guard let value = arguments[name] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPToolServiceError.missingArgument(name)
        }
        return value
    }

    private func intValue(_ name: String, in arguments: [String: Any]) -> Int? {
        if let value = arguments[name] as? Int {
            return value
        }
        if let value = arguments[name] as? NSNumber {
            return value.intValue
        }
        return nil
    }

    private func uuidValue(_ name: String, in arguments: [String: Any]) -> UUID? {
        guard let value = arguments[name] as? String else { return nil }
        return UUID(uuidString: value)
    }

    private func requiredUUID(_ name: String, in arguments: [String: Any]) throws -> UUID {
        guard let value = uuidValue(name, in: arguments) else {
            throw MCPToolServiceError.missingArgument(name)
        }
        return value
    }

    private func boolValue(_ name: String, in arguments: [String: Any]) -> Bool? {
        if let value = arguments[name] as? Bool {
            return value
        }
        if let value = arguments[name] as? NSNumber {
            return value.boolValue
        }
        return nil
    }

    private func jsonString(_ value: Encodable) throws -> String {
        let data = try encoder.encode(AnyEncodable(value))
        return String(decoding: data, as: UTF8.self)
    }

    private func successResponse(id: Any, result: [String: Any]) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        ]
    }

    private func errorResponse(id: Any, code: Int, message: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": code,
                "message": message
            ]
        ]
    }

    private func write(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let line = String(data: data, encoding: .utf8) else {
            return
        }
        print(line)
        fflush(stdout)
    }
}

private struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void

    init(_ value: Encodable) {
        self.encodeValue = value.encode(to:)
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}

@main
private struct PasteBuddyMCPMain {
    @MainActor
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if !arguments.isEmpty {
            handleCommandLine(arguments)
            return
        }

        await PasteBuddyMCPServer().run()
    }

    private static func handleCommandLine(_ arguments: [String]) {
        switch arguments.first {
        case "--help", "-h":
            printUsage()
        case "--list-client-configs":
            print(MCPClientConfigurationTarget.allCases.map(\.rawValue).joined(separator: "\n"))
        case "--print-client-config":
            printClientConfiguration(arguments: Array(arguments.dropFirst()))
        default:
            writeError("Unknown option: \(arguments.first ?? "")")
            printUsage()
            Foundation.exit(2)
        }
    }

    private static func printClientConfiguration(arguments: [String]) {
        guard let clientArgument = arguments.first,
              let target = MCPClientConfigurationTarget(argument: clientArgument) else {
            writeError("Missing or unknown client. Use --list-client-configs to see supported clients.")
            Foundation.exit(2)
        }

        let options = parseOptions(Array(arguments.dropFirst()))
        let guide: MCPClientConfigurationGuide
        if let executablePath = options["executable-path"] {
            guide = MCPClientConfigurationGuideBuilder.packagedGuide(
                for: target,
                executablePath: executablePath
            )
        } else {
            guide = MCPClientConfigurationGuideBuilder.developmentGuide(
                for: target,
                packagePath: options["package-path"] ?? FileManager.default.currentDirectoryPath
            )
        }

        print("# \(guide.target.displayName) PasteBuddy MCP Configuration")
        print("")
        print("Configuration location: \(guide.configurationHint)")
        print("Command: \(guide.command)")
        print("Arguments: \(guide.arguments.isEmpty ? "(none)" : guide.arguments.joined(separator: " "))")
        if let installationCommand = guide.installationCommand {
            print("Install command: \(installationCommand)")
        }
        if let installationURL = guide.installationURL {
            print("Install link: \(installationURL)")
        }
        print("")
        print("```")
        print(guide.configurationSnippet)
        print("```")
        print("")
        print("Notes:")
        for note in guide.setupNotes {
            print("- \(note)")
        }
    }

    private static func parseOptions(_ arguments: [String]) -> [String: String] {
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                index += 1
                continue
            }
            let key = String(argument.dropFirst(2))
            if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                options[key] = arguments[index + 1]
                index += 2
            } else {
                options[key] = "true"
                index += 1
            }
        }
        return options
    }

    private static func printUsage() {
        print("""
        PasteBuddyMCP

        Usage:
          PasteBuddyMCP
          PasteBuddyMCP --list-client-configs
          PasteBuddyMCP --print-client-config <claude|claude-code|codex|cursor|vscode|windsurf|gemini|opencode|kiro|custom> [--package-path <path>]
          PasteBuddyMCP --print-client-config <client> --executable-path <path-to-PasteBuddyMCP>

        With no arguments, PasteBuddyMCP starts the local stdio MCP server.
        """)
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
