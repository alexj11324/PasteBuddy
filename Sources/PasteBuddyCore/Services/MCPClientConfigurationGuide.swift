import Foundation

public enum MCPClientConfigurationTarget: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case codex
    case claude
    case cursor
    case vscode
    case windsurf
    case custom

    public var id: String { rawValue }

    public init?(argument: String) {
        let normalized = argument
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")

        switch normalized {
        case "codex", "openai-codex":
            self = .codex
        case "claude", "claude-desktop":
            self = .claude
        case "cursor":
            self = .cursor
        case "vscode", "vs-code", "visual-studio-code":
            self = .vscode
        case "windsurf":
            self = .windsurf
        case "custom", "generic":
            self = .custom
        default:
            return nil
        }
    }

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Desktop"
        case .cursor: "Cursor"
        case .vscode: "VS Code"
        case .windsurf: "Windsurf"
        case .custom: "Custom MCP Client"
        }
    }

    public var configurationHint: String {
        switch self {
        case .codex:
            "~/.codex/config.toml"
        case .claude:
            "Claude Desktop MCP settings JSON"
        case .cursor:
            "Cursor MCP settings UI or project MCP JSON"
        case .vscode:
            "VS Code MCP settings"
        case .windsurf:
            "Windsurf MCP settings"
        case .custom:
            "Any MCP client that can launch a stdio server"
        }
    }
}

public struct MCPClientConfigurationGuide: Equatable, Sendable {
    public var target: MCPClientConfigurationTarget
    public var command: String
    public var arguments: [String]
    public var configurationSnippet: String
    public var configurationHint: String
    public var setupNotes: [String]

    public init(
        target: MCPClientConfigurationTarget,
        command: String,
        arguments: [String],
        configurationSnippet: String,
        configurationHint: String,
        setupNotes: [String]
    ) {
        self.target = target
        self.command = command
        self.arguments = arguments
        self.configurationSnippet = configurationSnippet
        self.configurationHint = configurationHint
        self.setupNotes = setupNotes
    }
}

public enum MCPClientConfigurationGuideBuilder {
    public static func developmentGuide(
        for target: MCPClientConfigurationTarget,
        packagePath: String
    ) -> MCPClientConfigurationGuide {
        guide(
            for: target,
            command: "swift",
            arguments: ["run", "--package-path", packagePath, "PasteBuddyMCP"],
            modeNote: "Development mode launches the SwiftPM PasteBuddyMCP target from this checkout."
        )
    }

    public static func packagedGuide(
        for target: MCPClientConfigurationTarget,
        executablePath: String
    ) -> MCPClientConfigurationGuide {
        guide(
            for: target,
            command: executablePath,
            arguments: [],
            modeNote: "Packaged mode launches the installed PasteBuddyMCP executable directly."
        )
    }

    public static func guide(
        for target: MCPClientConfigurationTarget,
        command: String,
        arguments: [String]
    ) -> MCPClientConfigurationGuide {
        guide(
            for: target,
            command: command,
            arguments: arguments,
            modeNote: "Use this command/args pair for a stdio MCP server entry."
        )
    }

    private static func guide(
        for target: MCPClientConfigurationTarget,
        command: String,
        arguments: [String],
        modeNote: String
    ) -> MCPClientConfigurationGuide {
        MCPClientConfigurationGuide(
            target: target,
            command: command,
            arguments: arguments,
            configurationSnippet: snippet(for: target, command: command, arguments: arguments),
            configurationHint: target.configurationHint,
            setupNotes: setupNotes(for: target, modeNote: modeNote)
        )
    }

    private static func setupNotes(for target: MCPClientConfigurationTarget, modeNote: String) -> [String] {
        var notes = [
            modeNote,
            "PasteBuddy MCP access is disabled by default; enable the local server and individual tools in PasteBuddy Settings.",
            "Search tools return summary metadata only. Enable Retrieve Clipboard Item separately before any client can read item payloads."
        ]

        switch target {
        case .codex:
            notes.insert("Add this TOML block under Codex MCP server configuration, then restart Codex or reload MCP servers.", at: 0)
        case .claude:
            notes.insert("Add the JSON server entry in Claude Desktop MCP settings, then restart Claude Desktop.", at: 0)
        case .cursor:
            notes.insert("Paste the JSON server entry into Cursor's MCP settings UI or project MCP configuration.", at: 0)
        case .vscode:
            notes.insert("Add the server under VS Code's MCP settings. If your extension uses a command/args UI, copy those fields instead of the JSON wrapper.", at: 0)
        case .windsurf:
            notes.insert("Add the JSON server entry in Windsurf MCP settings, then reload the IDE.", at: 0)
        case .custom:
            notes.insert("Configure your client to launch the command as a stdio MCP server with the listed arguments.", at: 0)
        }

        return notes
    }

    private static func snippet(
        for target: MCPClientConfigurationTarget,
        command: String,
        arguments: [String]
    ) -> String {
        switch target {
        case .codex:
            return """
            [mcp_servers.pastebuddy]
            command = \(tomlString(command))
            args = [\(arguments.map(tomlString).joined(separator: ", "))]
            """
        case .vscode:
            return prettyJSON([
                "mcp": [
                    "servers": [
                        "pastebuddy": serverConfiguration(command: command, arguments: arguments)
                    ]
                ]
            ])
        case .claude, .cursor, .windsurf, .custom:
            return prettyJSON([
                "mcpServers": [
                    "pastebuddy": serverConfiguration(command: command, arguments: arguments)
                ]
            ])
        }
    }

    private static func serverConfiguration(command: String, arguments: [String]) -> [String: Any] {
        if arguments.isEmpty {
            return ["command": command]
        }
        return [
            "command": command,
            "args": arguments
        ]
    }

    private static func prettyJSON(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func tomlString(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
