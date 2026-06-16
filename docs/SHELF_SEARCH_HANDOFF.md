# Clipboard Shelf Search Handoff

Status: fixed and verified in the current working tree.

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
- The Shelf card strip is back on the AppKit-backed
  `ShelfCollectionRepresentable` / `NSCollectionView` interaction surface.
  Selection is handled at collection `mouseDown` time and only the changed
  visible cards are reconfigured, instead of routing every card through a
  SwiftUI `ScrollView` / `LazyHStack` tap gesture.
- Shelf card selection updates `ShelfInteractionModel` immediately, then
  debounces the store sync. The search focus clear now happens after local
  selection, without animating a focus handoff before the card state changes.

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
- Computer Use observed the live Shelf panel as window `剪贴板架`, with cards
  under an accessibility `集合` node and `clipboard-shelf-card-*` identifiers.
- A runtime AX/HID probe read the second card's real `AXFrame`, clicked its
  center, and Computer Use then observed that card's Details changed to
  `已选择`.
- Computer Use direct `click` remains intermittently unavailable for this panel
  with "Computer Use is not active"; do not treat that tool-side click failure
  as app behavior.

Regression notes:

- Do not reintroduce a root SwiftUI focus target just to catch keyboard events;
  it can steal AppKit first responder from the text field.
- Do not replace `ShelfCollectionRepresentable` with a pure SwiftUI horizontal
  card list. The NSCollectionView route is the latency fix for card browsing.
- Do not make Shelf card browsing synchronously update the global main-window
  selection before local Shelf selection changes. Copy, paste, preview, and
  drag should start from Shelf-local selection.
