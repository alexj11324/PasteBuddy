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
start. The card UI chooses `presentationContentType`, while `PasteboardWriter`
currently chooses the provider from raw `contentType`. A mixed item with an
image is rendered as an image card but gets a text-first provider containing
OCR text; external apps may therefore accept text instead of the image.

`PasteboardWriter` advertises PNG, TIFF, `NSImage`, and PNG-file representations
for inline image bytes, and asynchronous equivalents for an `imageAssetID`.
Those asynchronous representations currently call the hydration closure
independently, while `PinboardItemDragPayload` also starts and discards a
fire-and-forget hydration. This creates avoidable races on the lightweight
repository items used by Shelf and Side Panel.

## Minimal correction hypothesis

Use the physical primary-button state as the sole continuation signal for the
pointer session. After the button is released, clear protection, restore
transient collection behavior, and then apply lost-focus dismissal. For an
image-presented card, publish a pure image provider and share one lazy
hydration task across all requested image representations.
