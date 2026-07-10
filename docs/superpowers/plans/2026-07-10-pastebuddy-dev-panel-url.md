# PasteBuddy Development Panel URL Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a stable-signing, development-only repository command that opens or toggles PasteBuddy's existing Side Panel and Shelf without using a global shortcut or opening the main window.

**Architecture:** Launch Services delivers three exact `pastebuddy-dev://panel/...` URLs to `AppDelegate`, which queues early URLs and forwards them to the existing `ClipboardShelfPanelController`. The generated development bundle alone registers the scheme, and a shell script validates the installed bundle identity and signature before invoking `/usr/bin/open -g`.

**Tech Stack:** Swift 6, SwiftUI/AppKit, macOS Launch Services, Bash, `plutil`, `codesign`, XCTest.

## Global Constraints

- The target app is `/Applications/PasteBuddy Dev.app` with bundle identifier `com.alexjiang.PasteBuddy.dev` and signing channel `development`.
- Daily development builds must remain Apple Development signed; ad-hoc signing and disabled signing remain rejected.
- Release builds must not register `pastebuddy-dev`, and release runtime identity must reject all development URLs.
- Reuse `ClipboardShelfPanelController`; do not add another window implementation or any main-window entry point.
- Accept only `pastebuddy-dev://panel/side`, `pastebuddy-dev://panel/shelf`, and `pastebuddy-dev://panel/toggle` with no user info, port, query, fragment, encoding trick, or extra path component.
- UI completion requires rebuilding `/Applications/PasteBuddy Dev.app`, verifying runtime identity, opening the real panels, and inspecting them through Computer Use and runtime window geometry.

---

### Task 1: Parse authorized commands and preserve early URL delivery

**Files:**
- Create: `Sources/PasteBuddy/App/PasteBuddyDevelopmentPanelCommand.swift`
- Modify: `Sources/PasteBuddy/App/PasteBuddyApp.swift`
- Test: `Tests/PasteBuddyAppTests/PasteBuddyAppRuntimeTests.swift`

**Interfaces:**
- Consumes: `PasteBuddyRuntimeIdentity`, `ClipboardPanelDisplayMode`, and `NSApplicationDelegate.application(_:open:)`.
- Produces: `PasteBuddyDevelopmentPanelCommand.parse(_:identity:) -> PasteBuddyDevelopmentPanelCommand?` and `AppDelegate.handleOpenURLs: (([URL]) -> Void)?`.

- [ ] **Step 1: Write failing parser and delivery tests**

Add tests that express the exact trust boundary and early-delivery contract:

```swift
func testDevelopmentPanelCommandAcceptsOnlyStableDevelopmentIdentity() throws {
    let identity = PasteBuddyRuntimeIdentity(
        bundleIdentifier: "com.alexjiang.PasteBuddy.dev",
        bundlePath: "/Applications/PasteBuddy Dev.app",
        executablePath: "/Applications/PasteBuddy Dev.app/Contents/MacOS/PasteBuddy",
        stableAppPath: "/Applications/PasteBuddy Dev.app",
        signingChannel: "development",
        codeSigningIdentity: "APPLE-DEVELOPMENT"
    )

    XCTAssertEqual(
        PasteBuddyDevelopmentPanelCommand.parse(
            try XCTUnwrap(URL(string: "pastebuddy-dev://panel/side")),
            identity: identity
        ),
        .show(.sidePanel)
    )
    XCTAssertEqual(
        PasteBuddyDevelopmentPanelCommand.parse(
            try XCTUnwrap(URL(string: "pastebuddy-dev://panel/shelf")),
            identity: identity
        ),
        .show(.shelf)
    )
    XCTAssertEqual(
        PasteBuddyDevelopmentPanelCommand.parse(
            try XCTUnwrap(URL(string: "pastebuddy-dev://panel/toggle")),
            identity: identity
        ),
        .toggle
    )

    var releaseIdentity = identity
    releaseIdentity.bundleIdentifier = "com.alexjiang.PasteBuddy"
    releaseIdentity.signingChannel = "release"
    XCTAssertNil(
        PasteBuddyDevelopmentPanelCommand.parse(
            try XCTUnwrap(URL(string: "pastebuddy-dev://panel/side")),
            identity: releaseIdentity
        )
    )

    var copiedIdentity = identity
    copiedIdentity.bundlePath = "/private/tmp/PasteBuddy Dev.app"
    XCTAssertNil(
        PasteBuddyDevelopmentPanelCommand.parse(
            try XCTUnwrap(URL(string: "pastebuddy-dev://panel/side")),
            identity: copiedIdentity
        )
    )
}

func testDevelopmentPanelCommandRejectsMalformedURLs() throws {
    let identity = PasteBuddyRuntimeIdentity(
        bundleIdentifier: "com.alexjiang.PasteBuddy.dev",
        bundlePath: "/Applications/PasteBuddy Dev.app",
        executablePath: "/Applications/PasteBuddy Dev.app/Contents/MacOS/PasteBuddy",
        stableAppPath: "/Applications/PasteBuddy Dev.app",
        signingChannel: "development",
        codeSigningIdentity: "APPLE-DEVELOPMENT"
    )
    let rejected = [
        "PASTEBUDDY-DEV://panel/side",
        "pastebuddy-dev://PANEL/side",
        "pastebuddy-dev://panel/%73ide",
        "pastebuddy-dev://panel/side/extra",
        "pastebuddy-dev://user@panel/side",
        "pastebuddy-dev://panel:7/side",
        "pastebuddy-dev://panel/side?x=1",
        "pastebuddy-dev://panel/side#fragment",
        "pastebuddy-dev://panel/unknown"
    ]

    for rawURL in rejected {
        XCTAssertNil(
            PasteBuddyDevelopmentPanelCommand.parse(
                try XCTUnwrap(URL(string: rawURL)),
                identity: identity
            ),
            rawURL
        )
    }
}

func testAppDelegateQueuesOpenURLsUntilHandlerIsInstalled() throws {
    let delegate = AppDelegate()
    let first = try XCTUnwrap(URL(string: "pastebuddy-dev://panel/side"))
    let second = try XCTUnwrap(URL(string: "pastebuddy-dev://panel/shelf"))
    var delivered: [URL] = []

    delegate.application(NSApplication.shared, open: [first, second])
    XCTAssertTrue(delivered.isEmpty)

    delegate.handleOpenURLs = { delivered.append(contentsOf: $0) }
    XCTAssertEqual(delivered, [first, second])

    delegate.handleOpenURLs = { delivered.append(contentsOf: $0) }
    XCTAssertEqual(delivered, [first, second])
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --filter 'PasteBuddyAppRuntimeTests/testDevelopmentPanelCommand|PasteBuddyAppRuntimeTests/testAppDelegateQueuesOpenURLs'
```

Expected: compilation fails because `PasteBuddyDevelopmentPanelCommand`, `AppDelegate.handleOpenURLs`, and `application(_:open:)` do not exist.

- [ ] **Step 3: Implement the minimal parser**

Create `PasteBuddyDevelopmentPanelCommand.swift`:

```swift
import Foundation
import PasteBuddyCore

enum PasteBuddyDevelopmentPanelCommand: Equatable {
    case show(ClipboardPanelDisplayMode)
    case toggle

    static func parse(_ url: URL, identity: PasteBuddyRuntimeIdentity) -> Self? {
        guard identity.bundleIdentifier == "com.alexjiang.PasteBuddy.dev",
              identity.signingChannel == "development",
              identity.stableAppPath == "/Applications/PasteBuddy Dev.app",
              identity.isRunningFromStablePath,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "pastebuddy-dev",
              components.host == "panel",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }

        return switch components.percentEncodedPath {
        case "/side": .show(.sidePanel)
        case "/shelf": .show(.shelf)
        case "/toggle": .toggle
        default: nil
        }
    }
}
```

- [ ] **Step 4: Implement the minimal AppDelegate queue**

Add to `AppDelegate`:

```swift
var handleOpenURLs: (([URL]) -> Void)? {
    didSet { deliverPendingOpenURLs() }
}
private var pendingOpenURLs: [URL] = []

func application(_ application: NSApplication, open urls: [URL]) {
    pendingOpenURLs.append(contentsOf: urls)
    deliverPendingOpenURLs()
}

private func deliverPendingOpenURLs() {
    guard let handleOpenURLs, !pendingOpenURLs.isEmpty else { return }
    let urls = pendingOpenURLs
    pendingOpenURLs.removeAll(keepingCapacity: true)
    handleOpenURLs(urls)
}
```

- [ ] **Step 5: Run the focused tests and verify GREEN**

Run the Step 2 command again. Expected: all selected tests pass with zero failures.

- [ ] **Step 6: Commit the isolated parser/delivery change**

```bash
git add Sources/PasteBuddy/App/PasteBuddyDevelopmentPanelCommand.swift Sources/PasteBuddy/App/PasteBuddyApp.swift Tests/PasteBuddyAppTests/PasteBuddyAppRuntimeTests.swift
git commit -m "feat: accept development panel URLs"
```

---

### Task 2: Route commands and register only the stable development bundle

**Files:**
- Modify: `Sources/PasteBuddy/App/PasteBuddyApp.swift`
- Modify: `script/build_and_run.sh`
- Create: `script/open_dev_panel.sh`
- Test: `Tests/PasteBuddyAppTests/PasteBuddyAppRuntimeTests.swift`

**Interfaces:**
- Consumes: `PasteBuddyDevelopmentPanelCommand.parse`, `toggleClipboardShelf()`, `ClipboardShelfPanelController.show()`, and generated `Info.plist` identity keys.
- Produces: `handleDevelopmentPanelURLs(_:)`, development-only `CFBundleURLTypes`, and `script/open_dev_panel.sh side|shelf|toggle`.

- [ ] **Step 1: Write the failing integration contract test**

```swift
func testDevelopmentPanelURLIsRegisteredAndRoutedOnlyForStableDevApp() throws {
    let appSource = try sourceFileContents("Sources/PasteBuddy/App/PasteBuddyApp.swift")
    let buildSource = try sourceFileContents("script/build_and_run.sh")
    let commandSource = try sourceFileContents("script/open_dev_panel.sh")

    XCTAssertTrue(appSource.contains("appDelegate.handleOpenURLs ="))
    XCTAssertTrue(appSource.contains("PasteBuddyDevelopmentPanelCommand.parse("))
    XCTAssertTrue(appSource.contains("await toggleClipboardShelf()"))
    XCTAssertTrue(appSource.contains("await showClipboardPanelMode(mode)"))

    XCTAssertTrue(buildSource.contains("\"$SIGNING_CHANNEL\" == \"development\""))
    XCTAssertTrue(buildSource.contains("\"$BUNDLE_ID\" == \"com.alexjiang.PasteBuddy.dev\""))
    XCTAssertTrue(buildSource.contains("CFBundleURLTypes"))
    XCTAssertTrue(buildSource.contains("pastebuddy-dev"))

    XCTAssertTrue(commandSource.contains("/Applications/PasteBuddy Dev.app"))
    XCTAssertTrue(commandSource.contains("codesign --verify --deep --strict"))
    XCTAssertTrue(commandSource.contains("Authority=Apple Development:"))
    XCTAssertTrue(commandSource.contains("/usr/bin/open -g -a \"$APP_BUNDLE\" \"$url\""))
    XCTAssertFalse(commandSource.contains("osascript"))
}
```

- [ ] **Step 2: Run the contract test and verify RED**

Run:

```bash
swift test --filter PasteBuddyAppRuntimeTests/testDevelopmentPanelURLIsRegisteredAndRoutedOnlyForStableDevApp
```

Expected: the test fails because `script/open_dev_panel.sh` and the routing/registration strings are absent.

- [ ] **Step 3: Route accepted URLs through existing controller methods**

Extend `configureAppDelegate()` and add the shared show helper:

```swift
private func configureAppDelegate() {
    appDelegate.startRuntime = {
        Task { @MainActor in
            await startRuntimeIfNeeded()
        }
    }
    appDelegate.handleOpenURLs = { urls in
        Task { @MainActor in
            await handleDevelopmentPanelURLs(urls)
        }
    }
}

private func handleDevelopmentPanelURLs(_ urls: [URL]) async {
    for url in urls {
        guard let command = PasteBuddyDevelopmentPanelCommand.parse(
            url,
            identity: PasteBuddyRuntimeIdentityService.current
        ) else {
            PasteBuddyDiagnostics.record(.shelf, "developmentURLRejected")
            continue
        }

        PasteBuddyDiagnostics.record(.shelf, "developmentURLAccepted")
        switch command {
        case .show(let mode):
            await showClipboardPanelMode(mode)
        case .toggle:
            await toggleClipboardShelf()
        }
    }
}

private func showClipboardShelfMode() async {
    await showClipboardPanelMode(.shelf)
}

private func showClipboardPanelMode(_ mode: ClipboardPanelDisplayMode) async {
    await startRuntimeIfNeeded()
    PasteBuddyDiagnostics.record(.hotKey, "\(mode.rawValue)ModeRequested")
    panelDisplayMode = mode
    shelfPanelController?.placement = shelfPlacement
    shelfPanelController?.show()
}
```

- [ ] **Step 4: Register the scheme before signing only for the exact dev identity**

Immediately after the generated plist heredoc in `script/build_and_run.sh`, add:

```bash
if [[ "$SIGNING_CHANNEL" == "development" && "$BUNDLE_ID" == "com.alexjiang.PasteBuddy.dev" ]]; then
  /usr/bin/plutil -insert CFBundleURLTypes -json '[{"CFBundleURLName":"com.alexjiang.PasteBuddy.dev.panel","CFBundleURLSchemes":["pastebuddy-dev"]}]' "$INFO_PLIST"
fi
```

- [ ] **Step 5: Add the validating repository command**

Create executable `script/open_dev_panel.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="/Applications/PasteBuddy Dev.app"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'usage: %s {side|shelf|toggle}\n' "${0##*/}" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
command="$1"
case "$command" in
  side|shelf|toggle) ;;
  *) usage ;;
esac

[[ -d "$APP_BUNDLE" && -f "$INFO_PLIST" ]] || die "Missing $APP_BUNDLE; run script/build_and_run.sh --verify first."

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST" 2>/dev/null || true
}

[[ "$(plist_value CFBundleIdentifier)" == "com.alexjiang.PasteBuddy.dev" ]] || die "Unexpected development bundle identifier."
[[ "$(plist_value PasteBuddySigningChannel)" == "development" ]] || die "Unexpected signing channel."
[[ "$(plist_value PasteBuddyStableAppPath)" == "$APP_BUNDLE" ]] || die "Unexpected stable app path."
[[ "$(plist_value CFBundleURLTypes:0:CFBundleURLSchemes:0)" == "pastebuddy-dev" ]] || die "Development URL scheme is not registered; rebuild the app."

/usr/bin/codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE" >/dev/null
signature_details="$(/usr/bin/codesign -dvvv "$APP_BUNDLE" 2>&1)"
[[ "$signature_details" == *"Authority=Apple Development:"* ]] || die "PasteBuddy Dev.app is not Apple Development signed."
[[ "$signature_details" != *"Signature=adhoc"* ]] || die "PasteBuddy Dev.app is ad-hoc signed."
[[ "$signature_details" != *"TeamIdentifier=not set"* ]] || die "PasteBuddy Dev.app has no Team ID."

url="pastebuddy-dev://panel/$command"
/usr/bin/open -g -a "$APP_BUNDLE" "$url"
```

Then run:

```bash
chmod +x script/open_dev_panel.sh
```

- [ ] **Step 6: Verify GREEN and shell syntax**

Run:

```bash
swift test --filter PasteBuddyAppRuntimeTests/testDevelopmentPanelURLIsRegisteredAndRoutedOnlyForStableDevApp
bash -n script/build_and_run.sh
bash -n script/open_dev_panel.sh
```

Expected: test passes; both shell syntax checks exit 0.

- [ ] **Step 7: Commit the completed command path**

```bash
git add Sources/PasteBuddy/App/PasteBuddyApp.swift script/build_and_run.sh script/open_dev_panel.sh Tests/PasteBuddyAppTests/PasteBuddyAppRuntimeTests.swift
git commit -m "feat: add stable development panel command"
```

---

### Task 3: Verify the signed installed app and real panels

**Files:**
- Verify: `/Applications/PasteBuddy Dev.app`
- Verify: `script/open_dev_panel.sh`

**Interfaces:**
- Consumes: the built development app and all three command subcommands.
- Produces: build/test/signing/runtime/window evidence for final completion audit.

- [ ] **Step 1: Run automated regression checks**

```bash
swift test --disable-sandbox
python3 script/localization_catalog_workflow.py check
git diff --check
```

Expected: all Swift tests pass, localization reports `status=ok`, and diff check exits 0.

- [ ] **Step 2: Build and launch the stable development app**

```bash
script/build_and_run.sh --verify
```

Expected output includes:

```text
accessibilityTrusted=true
stableLaunchPathMatched=true
bundleIdentifier=com.alexjiang.PasteBuddy.dev
bundlePath=/Applications/PasteBuddy Dev.app
signingChannel=development
```

- [ ] **Step 3: Inspect bundle metadata and signature**

```bash
plutil -p '/Applications/PasteBuddy Dev.app/Contents/Info.plist'
codesign --verify --deep --strict --verbose=4 '/Applications/PasteBuddy Dev.app'
codesign -dvvv -r- '/Applications/PasteBuddy Dev.app'
```

Expected: URL scheme is `pastebuddy-dev`, signature verification succeeds, authority is Apple Development, and Team ID is set.

- [ ] **Step 4: Exercise real Side Panel, Shelf, and toggle behavior**

```bash
script/open_dev_panel.sh side
script/open_dev_panel.sh shelf
script/open_dev_panel.sh toggle
script/open_dev_panel.sh toggle
```

After each command, read actual `NSWindow`/Accessibility or `CGWindowListCopyWindowInfo` geometry and visually inspect the panel through Computer Use. Expected: Side Panel and Shelf use the existing panel frames, toggle closes and reopens, and no main window appears.

- [ ] **Step 5: Audit release isolation without mutating the installed release app**

Confirm the runtime parser tests reject release identity and inspect `script/build_and_run.sh` to ensure `CFBundleURLTypes` insertion is guarded by both the development channel and exact `.dev` bundle identifier. Do not overwrite `/Applications/PasteBuddy.app` merely to prove metadata isolation.
