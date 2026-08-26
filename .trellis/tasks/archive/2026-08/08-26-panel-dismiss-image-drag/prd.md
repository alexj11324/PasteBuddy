# Fix panel dismissal and image drag

## Goal

Restore the native transient-panel behavior of Shelf and Side Panel while
making image cards reliably draggable into external macOS applications.

## Background

- The user reports that the visible clipboard panel remains above other apps
  after clicking elsewhere and that image cards cannot be dragged out to paste.
- Both modes share `ClipboardShelfPanelController` and
  `SwiftUIShelfCollection`.
- Commit `6f8ae2c` introduced a pointer-session guard so an unpinned panel would
  survive app deactivation during a drag. The current implementation also
  treats any non-empty `.drag` pasteboard as an active session, although that
  pasteboard can outlive the physical mouse drag.

## Requirements

- R1: When the shared panel is unpinned, a real click outside its runtime frame
  or activation of another app without an active drag must dismiss it.
- R2: When the shared panel is pinned, outside clicks and app deactivation must
  not dismiss it; the existing explicit close behavior remains unchanged.
- R3: Starting a legitimate drag inside Shelf or Side Panel must keep the
  unpinned panel alive until the physical drag ends, without leaving a stale
  always-on-top state afterward.
- R4: An image card with inline or repository-backed image data must publish a
  usable PNG/TIFF/image-object/file representation at drag start and be
  accepted by an external macOS drop target.
- R5: Text, URL, file, mixed-content, selection, double-click paste, pin state,
  paging, and main-window behavior must remain unchanged.
- R6: The fix must apply to both Shelf and Side Panel through their shared
  owners; it must not introduce a second panel instance or open the main window.

## Acceptance Criteria

- [x] AC1: With Shelf unpinned, clicking a point proven outside its runtime
  frame dismisses it; repeat for Side Panel.
- [x] AC2: Switching to an external app without dragging dismisses either
  unpinned panel.
- [x] AC3: With the panel pinned, the same outside click does not dismiss it.
- [ ] AC4: Dragging an inline image card to a real external rich-text/image drop
  target inserts the image and the panel closes only after the drag completes.
- [x] AC5: Repeat AC4 with a repository-backed image whose bytes require
  hydration.
- [x] AC6: Focused lifecycle/provider tests, full relevant Swift tests, and
  `script/build_and_run.sh --verify` pass for the final integrated commit.
- [x] AC7: Runtime diagnostics show one process from
  `/Applications/PasteBuddy Dev.app`, bundle `com.alexjiang.PasteBuddy.dev`,
  stable source commit, Apple Development signing, and
  `accessibilityTrusted=true`.

## Verification Notes

- Final signed runtime validation used the measured Shelf frame
  `(0, 595, 1512, 324)` and Side Panel frame `(1138, 41, 360, 697)`.
  Both unpinned modes disappeared from `CGWindowListCopyWindowInfo` after an
  inside click followed by external-app activation. The pinned path remained
  visible in the same scenario before unpinning. Computer Use targets events
  to one app and cannot make a background-app click become the system-global
  activation click, so the equivalent focus-loss path and the focused
  outside-frame decision tests provide the final AC1 evidence.
- A real mixed image card was dragged from Shelf into TextEdit; TextEdit
  reported `A[附带的图像]` and an attachment element. The authoritative SQLite
  row had a non-null `image_asset_id`, proving the drop loaded repository-backed
  bytes.
- Standard storage contained no row with an image effective content type and a
  null `image_asset_id`, so a real installed-app inline-image fixture was not
  available without mutating user history. Inline PNG/TIFF/NSImage/file
  representations are covered by the focused provider regression tests; AC4
  remains unchecked rather than overstating runtime evidence.

## Out of Scope

- New panel layouts, visual redesign, new drag formats, screenshot capture, or
  changes to the main window.
- Changing the pinned-panel product policy.

## Open Questions

None. The requested behavior and the repository's shared pin/dismissal
invariants determine the expected result.
