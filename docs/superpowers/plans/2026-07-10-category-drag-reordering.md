# SwiftUI Category Reorder Interaction Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the failed AppKit category drop target with a SwiftUI move interaction that previews insertion with animation, commits once, and preserves card-copy behavior.

**Architecture:** Commits `6eedd9e` and `f0286d6` already provide the persisted mixed collection order. This slice uses one view-local drag session per panel and one shared SwiftUI `DragGesture` modifier; pointer movement changes only the preview order, while release calls the existing store move once. Clipboard-card drops remain typed SwiftUI destinations routed through `ClipboardCollectionDropTarget`.

**Tech Stack:** Swift 6, SwiftUI `DragGesture`/`dropDestination`, CoreTransferable, SwiftPM/XCTest, Computer Use.

---

### Task 1: Specify the move and live-preview contract

**Files:**
- Modify: `Tests/PasteBuddyAppTests/PasteBuddyAppRuntimeTests.swift`
- Test: `Tests/PasteBuddyAppTests/PasteBuddyAppRuntimeTests.swift`

- [ ] Add executable state tests for preview-only reorder, translated source placeholder, repeated-hover no-op, one completion result, and zero-result cancellation. Update the contract test to require the shared SwiftUI gesture modifier, midpoint frames, conditional typed card destination, and no category pasteboard payload or `ShelfCollectionChipDropTarget`.
- [ ] Run the focused test and confirm it fails against the current AppKit implementation:

```bash
swift test --disable-sandbox --scratch-path /private/tmp/pastebuddy-current-build \
  --filter PasteBuddyAppRuntimeTests.testShelfAndSideCollectionChipsUseSwiftUIAnimatedMoveReordering
```

Expected: failure because the shared SwiftUI gesture session does not exist.

### Task 2: Implement one SwiftUI gesture session

**Files:**
- Modify: `Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift`
- Modify: `Sources/PasteBuddy/Views/ClipboardSidePanelView.swift`
- Test: `Tests/PasteBuddyAppTests/PasteBuddyAppRuntimeTests.swift`

- [ ] Add a small shared `ClipboardCollectionDragSession` that records source, original order, preview order, translation, and the pending target/side. Preview moves mutate only local state; completion returns one relative move; cancellation restores the store order without saving.
- [ ] Add a shared SwiftUI `ClipboardCollectionReorderModifier`. Its `DragGesture` reads chip frames in one named coordinate space, offsets the source with the pointer, animates only changed midpoint placement, and commits one move on end.
- [ ] Remove the category `Transferable` and custom UTType so internal reordering never enters the copy/move pasteboard system. Keep Escape cancellation in both panels.
- [ ] Keep `PinboardItemDragPayload` on a separate conditional typed `dropDestination`, so Clipboard/Paste Stack/custom pinboards copy cards and smart categories register no card destination.
- [ ] Remove `ShelfCollectionChipDropTarget`, its `NSViewRepresentable`, pasteboard decoding, and temporary drag diagnostics.
- [ ] Use the preview order in both Shelf and Side Panel strips. Keep the existing `ClipboardPanelCollectionMoveState` suppression so the single persisted move does not run a list query.
- [ ] Run the focused test and both app/store suites:

```bash
swift test --disable-sandbox --scratch-path /private/tmp/pastebuddy-current-build \
  --filter PasteBuddyAppRuntimeTests
swift test --disable-sandbox --scratch-path /private/tmp/pastebuddy-current-build \
  --filter PasteBuddyStoreTests
```

Expected: all selected tests pass.

### Task 3: Verify the real signed interaction

**Files:**
- Modify only if verification exposes a defect.

- [ ] Run `git diff --check`, localization check, and the complete Swift test suite.
- [ ] Run `script/build_and_run.sh --verify`; require stable `/Applications/PasteBuddy Dev.app`, `com.alexjiang.PasteBuddy.dev`, Apple Development signing, `accessibilityTrusted=true`, and `stableLaunchPathMatched=true`.
- [ ] Open only Side Panel and Shelf. Read live window/chip frames before each Computer Use action.
- [ ] In each panel, drag Text across Paste Stack slowly: confirm no copy badge, Paste Stack animates aside before release, and Text fills the gap on release.
- [ ] Press Escape during the live preview: confirm the frame-sized gap and hidden source immediately restore, then relaunch and confirm no order was persisted.
- [ ] Relaunch and confirm order persistence; restore the user's original order afterward.
- [ ] Drag a card into Favorites and confirm copy succeeds; attempt the same on a smart category and confirm rejection/no membership or scope change.
- [ ] Inspect the final diff, commit the implementation, and rerun any gate affected by review fixes.
