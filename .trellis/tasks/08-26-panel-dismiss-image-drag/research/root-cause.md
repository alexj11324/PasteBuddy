# Root-cause research

## Panel lifecycle

`ClipboardShelfPanelController.endPanelPointerSession()` currently keeps the
session active while either the primary button is pressed or the named `.drag`
pasteboard contains types. The pasteboard is not a real-time drag lifecycle
signal and can remain populated after mouse-up. The scheduled 50 ms retry can
therefore repeat indefinitely, leaving `isPanelPointerSessionActive=true`.
Both outside-click and focus-loss dismissal deliberately refuse to close while
that flag is true, which explains the persistent always-on-top panel.

Two recovery gaps amplify the issue: a later outside mouse-down does not clear
a stale session before evaluating dismissal, and forced monitor teardown resets
the Boolean without restoring the panel's `.transient` collection behavior.
Presentation also has a broad 350 ms click-away ignore window; runtime evidence
must determine whether it independently drops legitimate early outside clicks.

## Image provider

Shelf and Side Panel both call `PinboardItemDragPayload.itemProvider` at drag
start. `PasteboardWriter` advertises PNG, TIFF, `NSImage`, and PNG-file
representations for inline image bytes, and asynchronous equivalents for an
`imageAssetID` that requires hydration. Runtime verification must distinguish a
payload failure from the lifecycle failure that dismisses or strands the source
panel during a cross-app drag.

## Minimal correction hypothesis

Use the physical primary-button state as the sole continuation signal for the
pointer session. After the button is released, clear protection, restore
transient collection behavior, and then apply lost-focus dismissal. If live
drag still fails after that correction, instrument the provider's advertised
and requested representations before changing transfer formats.
