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

- [ ] AC1: With Shelf unpinned, clicking a point proven outside its runtime
  frame dismisses it; repeat for Side Panel.
- [ ] AC2: Switching to an external app without dragging dismisses either
  unpinned panel.
- [ ] AC3: With the panel pinned, the same outside click does not dismiss it.
- [ ] AC4: Dragging an inline image card to a real external rich-text/image drop
  target inserts the image and the panel closes only after the drag completes.
- [ ] AC5: Repeat AC4 with a repository-backed image whose bytes require
  hydration.
- [ ] AC6: Focused lifecycle/provider tests, full relevant Swift tests, and
  `script/build_and_run.sh --verify` pass for the final integrated commit.
- [ ] AC7: Runtime diagnostics show one process from
  `/Applications/PasteBuddy Dev.app`, bundle `com.alexjiang.PasteBuddy.dev`,
  stable source commit, Apple Development signing, and
  `accessibilityTrusted=true`.

## Out of Scope

- New panel layouts, visual redesign, new drag formats, screenshot capture, or
  changes to the main window.
- Changing the pinned-panel product policy.

## Open Questions

None. The requested behavior and the repository's shared pin/dismissal
invariants determine the expected result.
