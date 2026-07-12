# Settings Information Architecture Implementation Plan

**Goal:** Reorganize the macOS Settings UI around user tasks and prove every exposed action has an honest functional outcome, including a packaged MCP stdio round trip.

**Constraints:** Reuse native SwiftUI controls, keep changes surgical, do not open the main/history window, keep probes in `/private/tmp`, and do not mutate live MCP client configuration.

## Task 1: Lock the new navigation contract

**Files:**
- Modify: `Tests/PasteBuddyAppTests/PasteBuddyAppRuntimeTests.swift`
- Modify: `Sources/PasteBuddy/Views/SettingsView.swift`

1. Update the focused source-contract test to require six task-based sidebar cases, direct destination routing, native grouped forms, and separated destructive storage actions.
2. Run the focused test and confirm it fails for the old five-page structure.
3. Add `.capture` and `.paste`, rename/reorder page routing, and move existing controls without changing their bindings.
4. Run the focused test and existing Settings runtime tests.

## Task 2: Refine native layout and control grouping

**Files:**
- Modify: `Sources/PasteBuddy/Views/SettingsView.swift`
- Modify only if new copy is required: `Sources/PasteBuddy/Resources/Localizable.xcstrings`
- Modify only if catalog sync requires it: localized `.strings` resources

1. Add focused assertions for primary status placement, dependent-control adjacency, and the final destructive section.
2. Keep `NavigationSplitView`, sidebar `List`, grouped `Form`, semantic labels, system symbols, and existing bindings.
3. Remove duplicated row/section labels and compress action rows using native layout only when controls form a real action set.
4. Run Settings tests, localization workflow check, and `swift test --filter LocalizationResourceTests`.

## Task 3: Package and sign the MCP executable

**Files:**
- Modify: `script/build_and_run.sh`
- Modify: `Tests/PasteBuddyAppTests/PasteBuddyAppRuntimeTests.swift`

1. Add a failing script contract test requiring `PasteBuddyMCP` to be built, copied to `Contents/MacOS`, made executable, nested-signed before the app, and verified at the installed path.
2. Update the existing build script with the minimum copy/sign/verify steps; do not add another packaging system.
3. Run the focused packaging contract test and shell syntax check.

## Task 4: Add a real MCP stdio probe

**Files:**
- Add only under temporary test location: `/private/tmp/pastebuddy_mcp_stdio_probe.py`
- Modify a formal existing test only if a durable protocol regression requires it: `Tests/PasteBuddyCoreTests/MCPClientConfigurationGuideTests.swift` or the existing MCP test file

1. Build/install `/Applications/PasteBuddy Dev.app` through the standard script.
2. Verify nested executable existence and strict deep signature.
3. In a disposable copy of app data or explicitly controlled development state, enable MCP access.
4. Launch the packaged executable and send `initialize` (`2025-11-25`), `notifications/initialized`, `tools/list`, and `tools/call` for `pastebuddy.list_pinboards` as newline-delimited JSON-RPC.
5. Assert IDs, negotiated protocol, advertised tool, non-error call result, no stderr, timeout bound, and exit `0` after stdin closes.
6. Disable access and assert an empty list plus explicit disabled error, not a crash or timeout.
7. Relaunch/reload Settings and match the newly written access-log entry by tool, timestamp, and outcome.
8. Delete the temporary probe after use.

## Task 5: Validate generated Codex configuration safely

**Files:**
- Modify if a defect is found: `Sources/PasteBuddyCore/Services/MCPClientConfigurationGuide.swift`
- Modify: `Tests/PasteBuddyCoreTests/MCPClientConfigurationGuideTests.swift`

1. Assert the packaged Codex TOML contains `[mcp_servers.pastebuddy]` and the installed nested executable path.
2. Parse/validate using an isolated temporary home/config; do not read or mutate broad `~/.codex`.
3. Validate the generated `codex mcp add` argument vector against the isolated environment.
4. Fix only concrete generation defects and rerun the MCP guide tests.

## Task 6: Automated functional matrix

**Files:**
- Prefer modifying existing focused tests in `Tests/PasteBuddyCoreTests/PasteBuddyStoreTests.swift`
- Prefer modifying existing UI contract tests in `Tests/PasteBuddyAppTests/PasteBuddyAppRuntimeTests.swift`

1. Run and extend existing tests for General, Capture, shortcuts, MCP, sync, storage, and plan state mutation/persistence only where coverage is missing.
2. Use temporary seeded history for destructive-action tests; never use the user's real history as test data.
3. Keep StoreKit success claims limited to test/sandbox evidence; otherwise verify the real unavailable/error state.
4. Run all focused suites, then full `swift test`.

## Task 7: Stable-app runtime acceptance

**Files:** none unless runtime evidence finds a defect.

1. Run `script/build_and_run.sh --verify` and record stable bundle path, bundle ID, development signing channel, `accessibilityTrusted=true`, and `stableLaunchPathMatched=true`.
2. Verify `codesign --verify --deep --strict --verbose=4`, signing requirement, and `Info.plist` for `/Applications/PasteBuddy Dev.app`, plus the nested MCP executable.
3. Open only Settings through its explicit entry point. Use Computer Use and runtime window/Accessibility geometry, never guessed coordinates.
4. Walk every page and control from the design verification matrix. Record pass, explicit unavailable state, or unresolved failure for each; do not convert unavailable external environments into success.
5. Run `script/test_card_switch_latency.sh` only if the Settings changes touch shared Shelf/card rendering code; otherwise document why it is out of scope.
6. Review `git diff`, run final relevant tests, and mark the Goal complete only if no required acceptance item remains.
