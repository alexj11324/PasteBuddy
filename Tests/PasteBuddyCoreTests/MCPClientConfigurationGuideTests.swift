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
            for: .claude,
            packagePath: "/tmp/PasteBuddy"
        )

        let root = try jsonObject(guide.configurationSnippet)
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        let pastebuddy = try XCTUnwrap(servers["pastebuddy"] as? [String: Any])

        XCTAssertEqual(pastebuddy["command"] as? String, "swift")
        XCTAssertEqual(pastebuddy["args"] as? [String], ["run", "--package-path", "/tmp/PasteBuddy", "PasteBuddyMCP"])
        XCTAssertTrue(guide.setupNotes.contains { $0.contains("disabled by default") })
    }

    func testVSCodeGuideUsesMCPServersWrapper() throws {
        let guide = MCPClientConfigurationGuideBuilder.developmentGuide(
            for: .vscode,
            packagePath: "/tmp/PasteBuddy"
        )

        let root = try jsonObject(guide.configurationSnippet)
        let mcp = try XCTUnwrap(root["mcp"] as? [String: Any])
        let servers = try XCTUnwrap(mcp["servers"] as? [String: Any])
        let pastebuddy = try XCTUnwrap(servers["pastebuddy"] as? [String: Any])

        XCTAssertEqual(pastebuddy["command"] as? String, "swift")
        XCTAssertEqual(pastebuddy["args"] as? [String], ["run", "--package-path", "/tmp/PasteBuddy", "PasteBuddyMCP"])
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
        XCTAssertEqual(MCPClientConfigurationTarget(argument: "vs-code"), .vscode)
        XCTAssertEqual(MCPClientConfigurationTarget(argument: "generic"), .custom)
        XCTAssertNil(MCPClientConfigurationTarget(argument: "unknown"))
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
