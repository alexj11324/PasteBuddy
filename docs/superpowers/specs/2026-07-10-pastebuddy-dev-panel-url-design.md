# PasteBuddy Development Panel URL Design

## Purpose

PasteBuddy development verification currently depends on global keyboard shortcuts or a menu-bar click to open the Shelf and Side Panel. Those paths are unreliable for automated local verification and make it hard to reopen the exact transient panel after every rebuild. Add a repository-owned command that asks the already-running, stably signed development app to show or toggle a panel without opening the main window.

## Goals

- Support `pastebuddy-dev://panel/side`, `pastebuddy-dev://panel/shelf`, and `pastebuddy-dev://panel/toggle`.
- Provide a repository script with `side`, `shelf`, and `toggle` subcommands.
- Deliver commands to the existing `/Applications/PasteBuddy Dev.app` process through Launch Services.
- Reuse `ClipboardShelfPanelController`; do not create another window or panel implementation.
- Keep the URL scheme unregistered and the command handler inert in release builds.
- Preserve the stable Apple Development signing and TCC identity enforced by `script/build_and_run.sh`.

## Non-goals

- No command for opening the main/history window.
- No general-purpose automation or remote-control API.
- No socket, HTTP server, XPC service, Darwin notification protocol, or background helper.
- No release-app URL scheme.
- No weakening of the repository hook that rejects ad-hoc or disabled signing.

## Architecture

### Development URL command

Add `PasteBuddyDevelopmentPanelCommand` as a small, pure parser and authorization boundary. It accepts a URL and a `PasteBuddyRuntimeIdentity` and returns one of:

- `.show(.sidePanel)` for `pastebuddy-dev://panel/side`
- `.show(.shelf)` for `pastebuddy-dev://panel/shelf`
- `.toggle` for `pastebuddy-dev://panel/toggle`

The parser accepts only the exact lower-case scheme, host, and single path component. It rejects user info, ports, query strings, fragments, extra path components, and unknown commands.

Authorization requires all of the following runtime facts:

- bundle identifier is exactly `com.alexjiang.PasteBuddy.dev`;
- signing channel is exactly `development`;
- `PasteBuddyRuntimeIdentity.isRunningFromStablePath` is true;
- stable app path is `/Applications/PasteBuddy Dev.app`.

This is defense in depth. Launch Services registration limits discovery to the development bundle, while the runtime gate prevents a copied, release, or identity-overridden app from honoring the command.

### App lifecycle delivery

`AppDelegate.application(_:open:)` receives URLs from Launch Services. Because a URL may arrive while the SwiftUI app is still wiring its runtime, `AppDelegate` queues pending URLs until a handler closure is installed, then drains them once in arrival order.

`PasteBuddyApp` installs the handler alongside its existing runtime-start callback. For each authorized command it:

1. awaits `startRuntimeIfNeeded()`;
2. aborts if persistence startup is blocked or the panel controller is unavailable;
3. for `side` or `shelf`, updates the existing panel mode and calls `show()`;
4. for `toggle`, calls the existing controller's `toggle()` in the current mode.

The route records a diagnostic event for accepted and rejected commands. It does not activate or create the main window.

### Development-only bundle registration

`script/build_and_run.sh` continues generating the macOS `Info.plist`. It adds `CFBundleURLTypes` only when both conditions hold:

- `PASTEBUDDY_SIGNING_CHANNEL=development`;
- bundle identifier is `com.alexjiang.PasteBuddy.dev`.

The registered scheme is only `pastebuddy-dev`. Release builds and development builds with an overridden identity contain no registration. URL metadata is inserted before the existing stable signing step, so the final signed bundle remains internally consistent.

### Repository command

Add `script/open_dev_panel.sh` with this interface:

```text
script/open_dev_panel.sh side
script/open_dev_panel.sh shelf
script/open_dev_panel.sh toggle
```

Before calling Launch Services, the script verifies:

- `/Applications/PasteBuddy Dev.app` exists;
- its `Info.plist` has the exact development bundle identifier, signing channel, stable path, and URL scheme;
- `codesign --verify --deep --strict` succeeds;
- the signature is not ad-hoc and has a Team ID.

It then executes `/usr/bin/open -g -a "/Applications/PasteBuddy Dev.app" "pastebuddy-dev://panel/<command>"`. Unknown or missing arguments fail with usage text and exit status 2. Missing, stale, incorrectly signed, or incorrectly identified bundles fail before sending a URL and tell the developer to run `script/build_and_run.sh --verify`.

## Files and Responsibilities

- `Sources/PasteBuddy/App/PasteBuddyDevelopmentPanelCommand.swift`: exact URL parser and runtime identity authorization.
- `Sources/PasteBuddy/App/PasteBuddyApp.swift`: AppDelegate URL queue and routing into the existing runtime/controller.
- `script/build_and_run.sh`: development-only `CFBundleURLTypes` generation.
- `script/open_dev_panel.sh`: stable-bundle validation and `open -g` invocation.
- `Tests/PasteBuddyAppTests/PasteBuddyAppRuntimeTests.swift`: parser, authorization, queueing, routing-source, and build-script release-isolation regressions.

## Error Handling

- Invalid or unauthorized URLs are ignored by the app after a diagnostic record; they never fall back to another action.
- Runtime or persistence failure does not open a partial panel and remains visible through existing error diagnostics.
- The shell command fails fast on every identity or signing mismatch.
- There is no fallback to a global shortcut, ad-hoc signing, a bare executable, or a temporary `.app` path.

## Verification

### Automated

- Parser tests cover every valid command and malformed URL class.
- Identity tests cover release channel, wrong bundle identifier, copied bundle path, and wrong stable path.
- AppDelegate tests prove URLs arriving before handler installation are delivered once and in order.
- Source/build tests prove the release path does not register `pastebuddy-dev` and the repository script validates the stable bundle before invoking `open`.
- `bash -n script/open_dev_panel.sh` and the relevant Swift test filter pass.
- The full Swift test suite and `git diff --check` pass.

### Real app

1. Run `script/build_and_run.sh --verify`.
2. Confirm `accessibilityTrusted=true`, `stableLaunchPathMatched=true`, `bundleIdentifier=com.alexjiang.PasteBuddy.dev`, `signingChannel=development`, and an Apple Development identity.
3. Inspect `Info.plist` and run `codesign --verify --deep --strict --verbose=4` on `/Applications/PasteBuddy Dev.app`.
4. Run `script/open_dev_panel.sh side`, obtain the real Side Panel frame through Accessibility or `CGWindowListCopyWindowInfo`, and visually inspect the live panel with Computer Use.
5. Repeat for `shelf`; run `toggle` twice and verify the existing panel closes and reopens without a main window appearing.

## Acceptance Criteria

- All three repository commands control the expected existing transient panel.
- Commands work after rebuilding and relaunching the stable development app.
- Release metadata has no `pastebuddy-dev` scheme and release runtime identity rejects the URLs.
- Invalid input fails visibly and never triggers an unrelated UI action.
- The installed development app remains stably Apple Development signed and retains Accessibility trust.
- No command opens or adds an entry point to the main PasteBuddy window.
