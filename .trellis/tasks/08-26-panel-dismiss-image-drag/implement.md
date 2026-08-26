# Implementation plan

1. Capture the current installed-app identity, process count, runtime panel
   frame, pin state, and before screenshots for Shelf and Side Panel.
2. Reproduce outside-click persistence and image drag failure with Computer Use
   against a real external target; do not open the main PasteBuddy window.
3. Add focused regression tests for pointer-session termination independent of
   stale drag-pasteboard contents and for inline/hydrated image providers.
4. Make the smallest shared-owner changes in
   `ClipboardShelfPanelController`, `PinboardItemDragPayload`, or
   `PasteboardWriter` justified by the reproduction.
5. Run focused tests, relevant full Swift tests, `bash -n` where applicable,
   and inspect the staged diff.
6. Commit the independently reviewable fix on `codex/integrated-delivery`.
7. Run `script/build_and_run.sh --verify`, reopen each panel via the approved
   URL path, read real frames, and repeat AC1-AC5 using Computer Use.
8. Run Trellis quality check, push the verified integrated commit, and report
   any environment-only limitation without claiming runtime success.

## Risk points

- Ending protection too early dismisses the panel during a valid cross-app
  drag.
- Ending it too late recreates the always-on-top bug.
- A provider can advertise types but still fail when the external app requests
  hydrated bytes, so both provider loading and real drop acceptance are gates.
