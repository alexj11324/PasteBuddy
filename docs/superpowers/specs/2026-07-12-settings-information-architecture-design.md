# PasteBuddy Settings Information Architecture Design

## Goal

Make every setting easier to find and operate without changing its product semantics. Completion requires functional evidence for every settings group, not only a successful build or attractive screenshots.

## Decision

Use a native macOS task-based sidebar with grouped `Form` content. This keeps platform behavior, accessibility, localization, and keyboard navigation while fixing the current information hierarchy.

Alternatives considered:

1. Keep the current five pages and only adjust spacing. Smallest diff, but it leaves Capture buried in General and Direct Paste buried in Integrations.
2. Use custom cards and a dashboard-style overview. Visually distinctive, but adds controls and styling without improving the underlying tasks.
3. Reorganize the native sidebar by user task. Recommended: it fixes discoverability with existing SwiftUI controls and no new design system.

## Navigation

Use six sidebar destinations in this order:

1. **General** — launch at login, menu bar status, and surfaced runtime errors.
2. **Capture** — active/paused state, temporary pause actions, captured content types, sensitive-text filtering, OCR, excluded apps, and custom capture rules.
3. **Paste & Shortcuts** — quick paste, shortcut recording, reset action, Accessibility status/request, and the latest direct-paste result.
4. **Integrations** — MCP/AI connection, connected-client activity, cloud/shared pinboards, and Iroh device pairing.
5. **Storage** — encryption/history lock, usage, retention limits, and destructive history actions.
6. **Plans** — current entitlement dates, navigation to the dedicated paywall, and a real StoreKit restore action with scoped, persisted success/error feedback. Product selection belongs in the paywall, not in Settings as bare purchase buttons.

Existing external destinations map directly: `.privacy` to Capture, `.shortcuts` to Paste & Shortcuts, `.sync` to Integrations, `.storage` to Storage, and `.general` to General.

## Layout and UI

- Keep `NavigationSplitView`, the native sidebar list, grouped forms, semantic labels, and system symbols.
- Give each detail page a short title and optional one-line description; do not repeat the same label as both section title and row label.
- Put the primary enable/status control first in each page.
- Keep dependent controls adjacent and disabled when their prerequisite is off.
- Put destructive actions in a final section, visually separated from limits and usage information.
- Replace multi-button horizontal rows that compress poorly with `ControlGroup` only where the actions are a true set; otherwise allow native vertical form rows.
- Preserve all existing localization keys and use semantic keys for any new visible copy.
- Do not add custom cards, gradients, animations, preferences search, or a new component layer.

## MCP Functional Contract

The MCP section must describe real state rather than implying a daemon is running. PasteBuddy uses a client-launched stdio server, so the setting means that MCP access is allowed when a client launches the packaged executable.

Acceptance requires:

1. Enabling Agent Connection persists and exposes the default allowed tools.
2. Disabling it makes `tools/list` empty or tool calls fail with the explicit disabled error, according to the existing protocol contract.
3. The build/install script packages and signs `PasteBuddyMCP` at `/Applications/PasteBuddy Dev.app/Contents/MacOS/PasteBuddyMCP`; `codesign --verify --deep --strict` covers the nested executable and the generated configuration points to that existing path.
4. A real stdio probe launches that packaged executable and sends newline-delimited JSON-RPC: `initialize` with the server-supported protocol version `2025-11-25`, verifies `initialize.result.protocolVersion == "2025-11-25"`, sends `notifications/initialized`, `tools/list`, then the non-mutating `tools/call` for the exact registered name `pastebuddy.list_pinboards`. It asserts matching response IDs, a non-error result, no unexpected stderr, and exit status `0` after stdin closes; timeout, signal termination, and nonzero exit are separate failures.
5. With access disabled, the same probe asserts the documented disabled behavior: an empty tool list and an explicit disabled error for a direct tool call. It must not accept a timeout, crash, or missing response as disabled behavior.
6. The successful call writes a new access-log entry containing the expected tool, timestamp, and outcome. Because the app and MCP process own independent stores, runtime acceptance must explicitly reload settings data or relaunch only the app/settings scene, then match the newly created entry rather than any historical entry.
7. Generated Codex TOML must contain `[mcp_servers.pastebuddy]`, the packaged command path, and its arguments. Parse the fragment with a TOML parser or validate it through Codex using an isolated temporary config/home; never scan or mutate the user's broad `~/.codex` tree. Validate the generated `codex mcp add` argument vector in the same isolated environment, not by copying a string or modifying the live config.

If the implementation cannot prove one of these states, the UI must show an honest unavailable/error state instead of success.

## Verification Matrix

Each control is verified at the narrowest real level that can prove its contract:

| Group | State/action check | Persistence check | Real app check |
|---|---|---|---|
| General | launch-at-login toggles the real login item when available; menu-bar row reports runtime state; plain-text default changes paste behavior | reload app and confirm persisted preference | unavailable login service and store errors remain visible |
| Capture | active toggle, 15-minute/1-hour pause, resume, six capture/privacy toggles, excluded-app add/remove, rule add/enable/disable/remove | reload app and match each stored value | OCR is disabled when image capture is off; invalid/incomplete rules cannot be added; capture behavior follows the selected types |
| Paste & Shortcuts | quick-paste enable, both modifier editors, every `ShortcutAction`, reset, Accessibility request, direct-paste result | reload app and match bindings | record a real shortcut and perform a real direct paste from the stable signed app; permission denial/trust is shown honestly and no repeated automatic prompt is used |
| MCP | enable/disable, generated configurations, detected-client refresh, advanced tool toggles, and revoke | cross-process snapshot reload | packaged signed stdio probe completes initialize/list/call; disabled response and new access-log entry are asserted |
| Sync | provider/readiness, shared pinboards, reset local-only, Iroh peer field/connect/send, pairing link copy | reload app and match persisted state where applicable | use a real configured peer/cloud test environment when available; otherwise verify the explicit unavailable/blocked state and do not claim successful sync or pairing |
| Storage | Touch ID requirement, lock/unlock, grace period, item/byte/day limits, clear-unpinned, clear-all | reload app and match stored values | biometric unavailable/denied states are explicit; seed disposable temporary history and prove each confirmed destructive action affects only its documented set |
| Plan | display current plan/dates and run StoreKit restore | flush and reload the store before reporting restore success | never trigger production purchases from Settings; verify StoreKit restore success/failure with test providers and show a scoped runtime error when the live App Store returns no entitlement |
| Paywall | start one persisted 7-day local trial only after checking current StoreKit entitlements; hard-gate protected runtime and MCP access after expiry | persist trial start/end, verified purchases, restores, renewals, revocations, and expiration before changing access | open a separate native paywall only after an explicit user action; display only `Product.products` results and App Store prices/periods; show an honest unavailable state when App Store Connect has no matching products |

Automated checks cover routing, state mutation, persistence, configuration generation, MCP protocol behavior, and localization. Runtime acceptance uses `script/build_and_run.sh --verify` and `/Applications/PasteBuddy Dev.app`, records `accessibilityTrusted=true`, `stableLaunchPathMatched=true`, bundle identifier/path, signing channel, nested MCP signature, and then uses Computer Use on the real Settings UI. Window/control coordinates come from runtime `NSWindow`, Accessibility, or `CGWindowListCopyWindowInfo` geometry; screenshots alone and guessed coordinates are not acceptance. The settings window is opened only through the explicit Settings entry point; the main/history window is not opened.

## Scope

This change may reorganize `SettingsView`, add the selected native Product Design paywall, enforce the existing entitlement model, extend focused tests, and update the existing build/package/signing path needed to embed and verify `PasteBuddyMCP`. It does not redesign the main window, add settings search, change storage formats, install MCP configuration into live user tools, invent App Store prices, or add dependencies. The paywall uses the selected native detail direction and never uses browser mockups for implementation acceptance.
