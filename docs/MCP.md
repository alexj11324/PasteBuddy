# PasteBuddy Local MCP Server

PasteBuddy includes a local stdio MCP server target named `PasteBuddyMCP`.
It is disabled by default and must be explicitly enabled in PasteBuddy Settings.

## Run

Development command:

```bash
swift run PasteBuddyMCP
```

Release/signed app packaging should point MCP clients at the installed
`PasteBuddyMCP` executable instead of a SwiftPM development command.

## Tools

- `pastebuddy.search_history`: Search local encrypted history and return item
  summaries. Raw clipboard payloads are omitted.
- `pastebuddy.retrieve_item`: Retrieve one item payload by ID after separate
  opt-in. Text, URLs, file paths, plain-text rendering, and OCR text may be
  returned; image bytes are omitted unless the call explicitly requests them.
- `pastebuddy.list_pinboards`: List pinboards, item counts, colors, and sharing
  state.
- `pastebuddy.create_pinboard`: Create a local encrypted pinboard.
- `pastebuddy.pin_first_match`: Search history and pin the first matching item
  into a pinboard.

## Privacy Model

- MCP access is off by default.
- Each MCP tool can be enabled or disabled independently.
- Revoke MCP Access disables the server and clears all enabled tools.
- The server loads PasteBuddy's local encrypted store on this Mac.
- Search responses return summary metadata only; they do not include raw text,
  image bytes, OCR text, file contents, or URL payloads.
- Search, retrieve, list-pinboard counts, and pin-first-match apply the current
  local privacy rules at read time. Items hidden by disabled content types,
  local sensitive-text blocking, source exclusions, or custom capture rules are
  not returned to MCP clients even if they already exist in encrypted history.
- `pastebuddy.retrieve_item` is disabled by default even when MCP server access
  is enabled. Turning it on is an explicit payload-access grant for this Mac.
- `pastebuddy.retrieve_item` omits image bytes by default and includes them only
  when `includeImageData` is true.
- Tool calls record local access metadata in the encrypted snapshot: tool name,
  timestamp, outcome, item/pinboard IDs, result count, and whether payload or
  image bytes were included. Queries, clipboard text, OCR text, file contents,
  URLs, and image bytes are not written to the audit log.
- No network listener is opened by the SwiftPM target. MCP communication uses
  stdio launched by the client.

## Example Client Configuration

Many MCP clients accept a command/args pair. In development, use:

```json
{
  "mcpServers": {
    "pastebuddy": {
      "command": "swift",
      "args": ["run", "--package-path", "/Users/alexjiang/Desktop/vibe/PasteBuddy", "PasteBuddyMCP"]
    }
  }
}
```

For packaged builds, replace `command` with the full path to the installed
`PasteBuddyMCP` executable and remove the SwiftPM arguments.

## Client Setup Guides

`PasteBuddyMCP` can print copy-ready setup snippets for common MCP clients:

```bash
swift run PasteBuddyMCP --print-client-config codex --package-path /Users/alexjiang/Desktop/vibe/PasteBuddy
swift run PasteBuddyMCP --print-client-config claude --package-path /Users/alexjiang/Desktop/vibe/PasteBuddy
swift run PasteBuddyMCP --print-client-config claude-code --package-path /Users/alexjiang/Desktop/vibe/PasteBuddy
swift run PasteBuddyMCP --print-client-config cursor --package-path /Users/alexjiang/Desktop/vibe/PasteBuddy
swift run PasteBuddyMCP --print-client-config vscode --package-path /Users/alexjiang/Desktop/vibe/PasteBuddy
swift run PasteBuddyMCP --print-client-config windsurf --package-path /Users/alexjiang/Desktop/vibe/PasteBuddy
swift run PasteBuddyMCP --print-client-config gemini --package-path /Users/alexjiang/Desktop/vibe/PasteBuddy
swift run PasteBuddyMCP --print-client-config opencode --package-path /Users/alexjiang/Desktop/vibe/PasteBuddy
swift run PasteBuddyMCP --print-client-config kiro --package-path /Users/alexjiang/Desktop/vibe/PasteBuddy
swift run PasteBuddyMCP --print-client-config custom --package-path /Users/alexjiang/Desktop/vibe/PasteBuddy
```

For a signed app build, point guides at the installed helper instead:

```bash
PasteBuddyMCP --print-client-config codex --executable-path /Applications/PasteBuddy.app/Contents/MacOS/PasteBuddyMCP
```

Supported client names can be listed with:

```bash
swift run PasteBuddyMCP --list-client-configs
```

Codex receives a TOML snippet for `~/.codex/config.toml`. Claude Desktop,
Claude Code, Gemini CLI, Kiro, Windsurf, and generic clients receive an
`mcpServers` JSON snippet. Cursor receives an `mcpServers` JSON snippet with an
explicit `type: "stdio"` field. VS Code receives a top-level `servers` JSON
snippet. OpenCode receives an `opencode.json`-style `mcp` object with
`type: "local"` and a command array.

PasteBuddy Settings detects known MCP-capable clients from installed `.app`
bundles, common CLI/TUI executables, and explicit config-file locations. Unknown
MCP-compatible clients remain supported through the Custom MCP Client guide,
which exposes the raw command/args pair and generic JSON.

When a detected client exposes an install entry point, Settings offers an
end-to-end action before the manual snippet:

- Codex: runs `codex mcp add pastebuddy -- ...`.
- Claude Code: runs `claude mcp add --scope user --transport stdio pastebuddy -- ...`.
- Cursor: opens the official `cursor://anysphere.cursor-deeplink/mcp/install`
  link and can run `cursor --add-mcp ...`.
- VS Code: opens the official `vscode:mcp/install` link and can run
  `code --add-mcp ...`.
- Gemini CLI: runs `gemini mcp add --scope user --transport stdio pastebuddy ...`.

Clients without a stable command-line installer, such as Claude Desktop,
Windsurf, OpenCode, Kiro, and unknown MCP clients, keep the manual import guide
as the supported path.

## Deferred Work

- Packaged signed helper location for distribution.
- Client-specific setup screenshots for Codex, Claude, Cursor, VS Code, Gemini,
  OpenCode, Kiro, and Windsurf.
