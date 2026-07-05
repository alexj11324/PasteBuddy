import XCTest
@testable import PasteBuddyCore

final class MCPClientConfigurationGuideTests: XCTestCase {
    func testCodexGuideEmitsTomlConfiguration() {
        let guide = MCPClientConfigurationGuideBuilder.developmentGuide(
            for: .codex,
            packagePath: "/tmp/PasteBuddy"
        )

        XCTAssertEqual(guide.command, "swift")
        XCTAssertEqual(guide.arguments, ["run", "--package-path", "/tmp/PasteBuddy", "PasteBuddyMCP"])
        XCTAssertEqual(guide.configurationHint, "~/.codex/config.toml")
        XCTAssertTrue(guide.configurationSnippet.contains("[mcp_servers.pastebuddy]"))
        XCTAssertTrue(guide.configurationSnippet.contains("command = \"swift\""))
        XCTAssertTrue(guide.configurationSnippet.contains("\"--package-path\""))
        XCTAssertTrue(guide.configurationSnippet.contains("\"/tmp/PasteBuddy\""))
        XCTAssertFalse(guide.configurationSnippet.contains("mcpServers"))
    }

    func testJSONClientGuideEmitsMCPServersConfiguration() throws {
        let guide = MCPClientConfigurationGuideBuilder.developmentGuide(
            for: .claudeCode,
            packagePath: "/tmp/PasteBuddy"
        )

        let root = try jsonObject(guide.configurationSnippet)
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        let pastebuddy = try XCTUnwrap(servers["pastebuddy"] as? [String: Any])

        XCTAssertEqual(pastebuddy["command"] as? String, "swift")
        XCTAssertEqual(pastebuddy["args"] as? [String], ["run", "--package-path", "/tmp/PasteBuddy", "PasteBuddyMCP"])
        XCTAssertTrue(guide.setupNotes.contains { $0.contains("disabled by default") })
        XCTAssertEqual(guide.configurationHint, "Claude Code MCP settings")
    }

    func testVSCodeGuideUsesServersWrapperAndInstallCommand() throws {
        let guide = MCPClientConfigurationGuideBuilder.developmentGuide(
            for: .vscode,
            packagePath: "/tmp/PasteBuddy"
        )

        let root = try jsonObject(guide.configurationSnippet)
        let servers = try XCTUnwrap(root["servers"] as? [String: Any])
        let pastebuddy = try XCTUnwrap(servers["pastebuddy"] as? [String: Any])

        XCTAssertEqual(pastebuddy["type"] as? String, "stdio")
        XCTAssertEqual(pastebuddy["command"] as? String, "swift")
        XCTAssertEqual(pastebuddy["args"] as? [String], ["run", "--package-path", "/tmp/PasteBuddy", "PasteBuddyMCP"])
        XCTAssertTrue(guide.installationCommand?.contains("code --add-mcp") == true)
        XCTAssertTrue(guide.installationCommand?.contains("\"name\":\"pastebuddy\"") == true)
        XCTAssertEqual(guide.installationCommandParts?.first, "code")
        XCTAssertTrue(guide.installationURL?.hasPrefix("vscode:mcp/install?") == true)
    }

    func testCursorGuideIncludesOfficialInstallLink() {
        let guide = MCPClientConfigurationGuideBuilder.developmentGuide(
            for: .cursor,
            packagePath: "/tmp/PasteBuddy"
        )

        XCTAssertEqual(guide.installationCommandParts.map { Array($0.prefix(2)) }, ["cursor", "--add-mcp"])
        XCTAssertTrue(guide.installationURL?.hasPrefix("cursor://anysphere.cursor-deeplink/mcp/install?name=pastebuddy&config=") == true)
    }

    func testCodexClaudeCodeAndGeminiGuidesEmitClientAddCommands() {
        let codex = MCPClientConfigurationGuideBuilder.developmentGuide(
            for: .codex,
            packagePath: "/tmp/PasteBuddy"
        )
        let claudeCode = MCPClientConfigurationGuideBuilder.developmentGuide(
            for: .claudeCode,
            packagePath: "/tmp/PasteBuddy"
        )
        let gemini = MCPClientConfigurationGuideBuilder.developmentGuide(
            for: .gemini,
            packagePath: "/tmp/PasteBuddy"
        )

        XCTAssertTrue(codex.installationCommand?.hasPrefix("codex mcp add pastebuddy -- swift") == true)
        XCTAssertTrue(claudeCode.installationCommand?.hasPrefix("claude mcp add --scope user --transport stdio pastebuddy -- swift") == true)
        XCTAssertTrue(gemini.installationCommand?.hasPrefix("gemini mcp add --scope user --transport stdio pastebuddy swift") == true)
    }

    func testOpenCodeGuideUsesLocalMCPObjectWithCommandArray() throws {
        let guide = MCPClientConfigurationGuideBuilder.developmentGuide(
            for: .opencode,
            packagePath: "/tmp/PasteBuddy"
        )

        let root = try jsonObject(guide.configurationSnippet)
        let mcp = try XCTUnwrap(root["mcp"] as? [String: Any])
        let pastebuddy = try XCTUnwrap(mcp["pastebuddy"] as? [String: Any])

        XCTAssertEqual(root["$schema"] as? String, "https://opencode.ai/config.json")
        XCTAssertEqual(pastebuddy["type"] as? String, "local")
        XCTAssertEqual(pastebuddy["enabled"] as? Bool, true)
        XCTAssertEqual(pastebuddy["command"] as? [String], ["swift", "run", "--package-path", "/tmp/PasteBuddy", "PasteBuddyMCP"])
    }

    func testKiroAndGeminiGuidesUseMCPServersConfiguration() throws {
        for target in [MCPClientConfigurationTarget.kiro, .gemini] {
            let guide = MCPClientConfigurationGuideBuilder.developmentGuide(
                for: target,
                packagePath: "/tmp/PasteBuddy"
            )

            let root = try jsonObject(guide.configurationSnippet)
            let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
            let pastebuddy = try XCTUnwrap(servers["pastebuddy"] as? [String: Any])

            XCTAssertEqual(pastebuddy["command"] as? String, "swift")
            XCTAssertEqual(pastebuddy["args"] as? [String], ["run", "--package-path", "/tmp/PasteBuddy", "PasteBuddyMCP"])
        }
    }

    func testPackagedGuideUsesInstalledExecutableWithoutSwiftPackageArguments() throws {
        let guide = MCPClientConfigurationGuideBuilder.packagedGuide(
            for: .cursor,
            executablePath: "/Applications/PasteBuddy.app/Contents/MacOS/PasteBuddyMCP"
        )

        let root = try jsonObject(guide.configurationSnippet)
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        let pastebuddy = try XCTUnwrap(servers["pastebuddy"] as? [String: Any])

        XCTAssertEqual(guide.arguments, [])
        XCTAssertEqual(pastebuddy["command"] as? String, "/Applications/PasteBuddy.app/Contents/MacOS/PasteBuddyMCP")
        XCTAssertNil(pastebuddy["args"])
        XCTAssertFalse(guide.configurationSnippet.contains("--package-path"))
    }

    func testTargetArgumentAliases() {
        XCTAssertEqual(MCPClientConfigurationTarget(argument: "openai-codex"), .codex)
        XCTAssertEqual(MCPClientConfigurationTarget(argument: "claude-desktop"), .claude)
        XCTAssertEqual(MCPClientConfigurationTarget(argument: "claude-code"), .claudeCode)
        XCTAssertEqual(MCPClientConfigurationTarget.claudeCode.rawValue, "claude-code")
        XCTAssertEqual(MCPClientConfigurationTarget(argument: "vs-code"), .vscode)
        XCTAssertEqual(MCPClientConfigurationTarget(argument: "gemini-cli"), .gemini)
        XCTAssertEqual(MCPClientConfigurationTarget(argument: "open-code"), .opencode)
        XCTAssertEqual(MCPClientConfigurationTarget(argument: "kiro"), .kiro)
        XCTAssertEqual(MCPClientConfigurationTarget(argument: "generic"), .custom)
        XCTAssertNil(MCPClientConfigurationTarget(argument: "unknown"))
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
