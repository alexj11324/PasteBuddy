# Clipboard Shelf Search Handoff

Status: fixed in the current working tree.

Summary:

- The bottom Clipboard Shelf search field is a SwiftUI `TextField` inside the
  existing Liquid Glass surface helper. It is not the main window toolbar
  `.searchable` field.
- The root cause was the Shelf root view also being a SwiftUI focus owner:
  `.focusable().focused($isShelfKeyboardFocused)` competed with the search
  field's own `@FocusState`, so SwiftUI could believe the search field was
  focused while AppKit's real first responder was not the text field.
- The fix removes the root focus owner, removes the false/true focus retry, and
  keeps only the search field's focus state.
- Shelf card selection is now local to `ShelfInteractionModel`; it no longer
  schedules delayed writes back to `store.selectedItemID` on each click. This
  prevents card browsing in the Shelf from forcing the main window list/detail
  views to refresh.

Verified:

- `swift build -Xswiftc -swift-version -Xswiftc 6 --quiet` passed.
- `swift test --filter Search` passed: 17 tests, 0 failures.
- `script/build_and_run.sh --install` installed
  `/Applications/PasteBuddy Dev.app`.
- Runtime diagnostics reported:
  `accessibilityTrusted=true`,
  `stableLaunchPathMatched=true`,
  `bundleIdentifier=com.alexjiang.PasteBuddy.dev`.
- Accessibility verification on `/Applications/PasteBuddy Dev.app` showed
  `clipboard-shelf-search-field` with `focused=true`.
- Typing `brave` into the open Shelf changed the Shelf field AX value to
  `brave`.
- Computer Use can observe the Shelf panel and card accessibility state, but its
  click action currently reports "Computer Use is not active" for this panel; do
  not treat that tool click failure as app behavior.

Regression notes:

- Do not reintroduce a root SwiftUI focus target just to catch keyboard events;
  it can steal AppKit first responder from the text field.
- Do not make Shelf card browsing update the global main-window selection on
  every click. Copy, paste, preview, and drag should use Shelf-local selection.
