import Foundation

public enum MCPClientConfigurationTarget: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case claude
    case claudeCode = "claude-code"
    case codex
    case cursor
    case vscode
    case windsurf
    case gemini
    case opencode
    case kiro
    case custom

    public var id: String { rawValue }

    public init?(argument: String) {
        let normalized = argument
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")

        switch normalized {
        case "claude", "claude-desktop":
            self = .claude
        case "claude-code", "claudecode":
            self = .claudeCode
        case "codex", "openai-codex":
            self = .codex
        case "cursor":
            self = .cursor
        case "vscode", "vs-code", "visual-studio-code":
            self = .vscode
        case "windsurf":
            self = .windsurf
        case "gemini", "gemini-cli":
            self = .gemini
        case "opencode", "open-code":
            self = .opencode
        case "kiro":
            self = .kiro
        case "custom", "generic":
            self = .custom
        default:
            return nil
        }
    }

    public var displayName: String {
        switch self {
        case .claude: "Claude Desktop"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .vscode: "VS Code"
        case .windsurf: "Windsurf"
        case .gemini: "Gemini CLI"
        case .opencode: "OpenCode"
        case .kiro: "Kiro"
        case .custom: "Custom MCP Client"
        }
    }

    public var configurationHint: String {
        switch self {
        case .claude:
            "Claude Desktop MCP settings JSON"
        case .claudeCode:
            "Claude Code MCP settings"
        case .codex:
            "~/.codex/config.toml"
        case .cursor:
            "Cursor MCP settings UI or project MCP JSON"
        case .vscode:
            "VS Code MCP settings"
        case .windsurf:
            "~/.codeium/mcp_config.json"
        case .gemini:
            "~/.gemini/settings.json"
        case .opencode:
            "~/.config/opencode/opencode.json"
        case .kiro:
            "~/.kiro/settings/mcp.json"
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
    public var installationCommandParts: [String]?
    public var installationCommand: String?
    public var installationURL: String?

    public init(
        target: MCPClientConfigurationTarget,
        command: String,
        arguments: [String],
        configurationSnippet: String,
        configurationHint: String,
        setupNotes: [String],
        installationCommandParts: [String]? = nil,
        installationCommand: String? = nil,
        installationURL: String? = nil
    ) {
        self.target = target
        self.command = command
        self.arguments = arguments
        self.configurationSnippet = configurationSnippet
        self.configurationHint = configurationHint
        self.setupNotes = setupNotes
        self.installationCommandParts = installationCommandParts
        self.installationCommand = installationCommand
        self.installationURL = installationURL
    }
}

public enum MCPClientConfigurationGuideBuilder {
    public static func developmentGuide(
        for target: MCPClientConfigurationTarget,
        packagePath: String,
        authenticationToken: String? = nil
    ) -> MCPClientConfigurationGuide {
        guide(
            for: target,
            command: "swift",
            arguments: ["run", "--package-path", packagePath, "PasteBuddyMCP"],
            modeNote: "Development mode launches the SwiftPM PasteBuddyMCP target from this checkout.",
            authenticationToken: authenticationToken
        )
    }

    public static func packagedGuide(
        for target: MCPClientConfigurationTarget,
        executablePath: String,
        authenticationToken: String? = nil
    ) -> MCPClientConfigurationGuide {
        guide(
            for: target,
            command: executablePath,
            arguments: [],
            modeNote: "Packaged mode launches the installed PasteBuddyMCP executable directly.",
            authenticationToken: authenticationToken
        )
    }

    public static func guide(
        for target: MCPClientConfigurationTarget,
        command: String,
        arguments: [String],
        authenticationToken: String? = nil
    ) -> MCPClientConfigurationGuide {
        guide(
            for: target,
            command: command,
            arguments: arguments,
            modeNote: "Use this command/args pair for a stdio MCP server entry.",
            authenticationToken: authenticationToken
        )
    }

    private static func guide(
        for target: MCPClientConfigurationTarget,
        command: String,
        arguments: [String],
        modeNote: String,
        authenticationToken: String?
    ) -> MCPClientConfigurationGuide {
        MCPClientConfigurationGuide(
            target: target,
            command: command,
            arguments: arguments,
            configurationSnippet: snippet(
                for: target,
                command: command,
                arguments: arguments,
                authenticationToken: authenticationToken
            ),
            configurationHint: target.configurationHint,
            setupNotes: setupNotes(for: target, modeNote: modeNote),
            installationCommandParts: authenticationToken == nil
                ? installationCommandParts(for: target, command: command, arguments: arguments)
                : nil,
            installationCommand: authenticationToken == nil
                ? installationCommand(for: target, command: command, arguments: arguments)
                : nil,
            installationURL: authenticationToken == nil
                ? installationURL(for: target, command: command, arguments: arguments)
                : nil
        )
    }

    private static func setupNotes(for target: MCPClientConfigurationTarget, modeNote: String) -> [String] {
        var notes = [
            modeNote,
            "PasteBuddy MCP access is disabled by default; turn on Agent Connection in PasteBuddy Settings before connecting.",
            "PasteBuddy Settings only shows the connection switch. Tool details stay in the MCP client for the connected Agent."
        ]

        switch target {
        case .claude:
            notes.insert("Add the JSON server entry in Claude Desktop MCP settings, then restart Claude Desktop.", at: 0)
        case .claudeCode:
            notes.insert("Use Claude Code's MCP add flow or paste this server entry into Claude Code MCP settings, then reload MCP servers.", at: 0)
        case .codex:
            notes.insert("Add this TOML block under Codex MCP server configuration, then restart Codex or reload MCP servers.", at: 0)
        case .cursor:
            notes.insert("Paste the JSON server entry into Cursor's MCP settings UI or project MCP configuration.", at: 0)
        case .vscode:
            notes.insert("Add the server under VS Code's MCP settings. If your extension uses a command/args UI, copy those fields instead of the JSON wrapper.", at: 0)
        case .windsurf:
            notes.insert("Add the JSON server entry in Windsurf Settings > Tools > Add Server or View Raw Config, then refresh Cascade.", at: 0)
        case .gemini:
            notes.insert("Use gemini mcp add or add the JSON server entry under mcpServers in Gemini CLI settings.", at: 0)
        case .opencode:
            notes.insert("Add this local MCP entry under the mcp object in OpenCode config, then restart OpenCode.", at: 0)
        case .kiro:
            notes.insert("Add the JSON server entry to Kiro's user or workspace MCP configuration, then enable MCP support in Kiro settings.", at: 0)
        case .custom:
            notes.insert("Configure your client to launch the command as a stdio MCP server with the listed arguments.", at: 0)
        }

        return notes
    }

    private static func snippet(
        for target: MCPClientConfigurationTarget,
        command: String,
        arguments: [String],
        authenticationToken: String?
    ) -> String {
        switch target {
        case .codex:
            return """
            [mcp_servers.pastebuddy]
            command = \(tomlString(command))
            args = [\(arguments.map(tomlString).joined(separator: ", "))]
            \(authenticationToken.map { "env = { \(MCPAuthenticationToken.environmentVariable) = \(tomlString($0)) }" } ?? "")
            """
        case .vscode:
            return prettyJSON([
                "servers": [
                    "pastebuddy": serverConfiguration(command: command, arguments: arguments, authenticationToken: authenticationToken, includeType: true)
                ]
            ])
        case .opencode:
            var configuration: [String: Any] = [
                "type": "local",
                "command": [command] + arguments,
                "enabled": true
            ]
            if let authenticationToken {
                configuration["environment"] = [MCPAuthenticationToken.environmentVariable: authenticationToken]
            }
            return prettyJSON([
                "$schema": "https://opencode.ai/config.json",
                "mcp": [
                    "pastebuddy": configuration
                ]
            ])
        case .cursor:
            return prettyJSON([
                "mcpServers": [
                    "pastebuddy": serverConfiguration(command: command, arguments: arguments, authenticationToken: authenticationToken, includeType: true)
                ]
            ])
        case .claude, .claudeCode, .windsurf, .gemini, .kiro, .custom:
            return prettyJSON([
                "mcpServers": [
                    "pastebuddy": serverConfiguration(command: command, arguments: arguments, authenticationToken: authenticationToken)
                ]
            ])
        }
    }

    private static func installationCommand(
        for target: MCPClientConfigurationTarget,
        command: String,
        arguments: [String]
    ) -> String? {
        guard let parts = installationCommandParts(for: target, command: command, arguments: arguments) else {
            return nil
        }
        return shellCommandLine(parts)
    }

    private static func installationCommandParts(
        for target: MCPClientConfigurationTarget,
        command: String,
        arguments: [String]
    ) -> [String]? {
        switch target {
        case .codex:
            return ["codex", "mcp", "add", "pastebuddy", "--", command] + arguments
        case .claudeCode:
            return ["claude", "mcp", "add", "--scope", "user", "--transport", "stdio", "pastebuddy", "--", command] + arguments
        case .cursor:
            return ["cursor", "--add-mcp", addMCPPayload(command: command, arguments: arguments)]
        case .vscode:
            return ["code", "--add-mcp", addMCPPayload(command: command, arguments: arguments)]
        case .gemini:
            return ["gemini", "mcp", "add", "--scope", "user", "--transport", "stdio", "pastebuddy", command] + arguments
        case .claude, .windsurf, .opencode, .kiro, .custom:
            return nil
        }
    }

    private static func installationURL(
        for target: MCPClientConfigurationTarget,
        command: String,
        arguments: [String]
    ) -> String? {
        switch target {
        case .cursor:
            guard let encoded = base64JSON(serverConfiguration(command: command, arguments: arguments, includeType: true))
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                return nil
            }
            return "cursor://anysphere.cursor-deeplink/mcp/install?name=pastebuddy&config=\(encoded)"
        case .vscode:
            guard let encoded = addMCPPayload(command: command, arguments: arguments)
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                return nil
            }
            return "vscode:mcp/install?\(encoded)"
        default:
            return nil
        }
    }

    private static func addMCPPayload(command: String, arguments: [String]) -> String {
        var object = serverConfiguration(command: command, arguments: arguments, includeType: true)
        object["name"] = "pastebuddy"
        return compactJSON(object)
    }

    private static func serverConfiguration(
        command: String,
        arguments: [String],
        authenticationToken: String? = nil,
        includeType: Bool = false
    ) -> [String: Any] {
        var configuration: [String: Any] = ["command": command]
        if includeType {
            configuration["type"] = "stdio"
        }
        if let authenticationToken {
            configuration["env"] = [MCPAuthenticationToken.environmentVariable: authenticationToken]
        }
        if arguments.isEmpty {
            return configuration
        }
        configuration["args"] = arguments
        return configuration
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

    private static func compactJSON(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func base64JSON(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return ""
        }
        return data.base64EncodedString()
    }

    private static func shellCommandLine(_ parts: [String]) -> String {
        parts.map(shellQuote).joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-=/:.,")
        if value.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
