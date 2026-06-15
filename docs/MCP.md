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
swift run PasteBuddyMCP --print-client-config cursor --package-path /Users/alexjiang/Desktop/vibe/PasteBuddy
swift run PasteBuddyMCP --print-client-config vscode --package-path /Users/alexjiang/Desktop/vibe/PasteBuddy
swift run PasteBuddyMCP --print-client-config windsurf --package-path /Users/alexjiang/Desktop/vibe/PasteBuddy
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
Cursor, Windsurf, and generic clients receive an `mcpServers` JSON snippet.
VS Code receives an `mcp.servers` JSON wrapper, with the same command/args
fields available for extensions that store MCP servers through a UI instead.

## Deferred Work

- Packaged signed helper location for distribution.
- Client-specific setup screenshots for Codex, Claude, Cursor, VS Code, and
  Windsurf.
