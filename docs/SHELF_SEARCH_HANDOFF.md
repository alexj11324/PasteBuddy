# Clipboard Shelf Search Handoff

Status: blocked for follow-up debugging.

Current branch state contains a partial rewrite of the Clipboard Shelf search
control:

- Removed the custom `NSSearchField` bridge from `ClipboardShelfPanelView`.
- Rebuilt the shelf search control as a SwiftUI `TextField` inside the existing
  Liquid Glass surface helper.
- Changed the shelf panel from `.nonactivatingPanel` to `.borderless` and call
  `NSApp.activate(ignoringOtherApps: true)` before `panel.makeKey()`.
- Added a focus retry path that toggles the SwiftUI `@FocusState` false/true
  when search focus is requested while SwiftUI already thinks it is focused.
- Added localized "Clear search" strings.

Verified:

- `swift build -Xswiftc -swift-version -Xswiftc 6 --quiet` passed.
- `swift test --filter Search` passed: 17 tests, 0 failures.
- `script/build_and_run.sh --install` installed
  `/Applications/PasteBuddy Dev.app`.
- Runtime diagnostics reported:
  `accessibilityTrusted=true`,
  `stableLaunchPathMatched=true`,
  `bundleIdentifier=com.alexjiang.PasteBuddy.dev`.

Known remaining problem:

- The Clipboard Shelf search field is still not focusable by real click.
- AX sees the shelf field:
  `AXTextField`, identifier `clipboard-shelf-search-field`,
  frame approximately `x=16 y=664 w=272 h=38`.
- System Events / HID probes clicking the AX-derived center and typing did not
  change the field value; AX continued to report `focused=false`.
- The main window toolbar search still appears separately as the system
  `.searchable` search field (`AXSearchField`). The broken field is the custom
  bottom Shelf field only.

Likely next areas to inspect:

- SwiftUI `TextField` focus inside `NSHostingView` hosted by a borderless
  `NSPanel`.
- Whether the root `.focusable().focused($isShelfKeyboardFocused)` steals focus
  back from the search field.
- Hit testing around the glass/stroke layers and the `SourceAppSuggestionPanel`
  background presenter.
- Whether the shelf needs a small AppKit focus shim while keeping the visible
  search UI in SwiftUI, or whether the shelf panel must become a standard
  toolbar-backed window to use Apple's true `.searchable` Liquid Glass search.
