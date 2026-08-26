# Design: panel dismissal and image drag

## Boundary

Keep lifecycle ownership in `ClipboardShelfPanelController` and drag payload
ownership in `PasteboardWriter` / `PinboardItemDragPayload`. Shelf and Side
Panel remain consumers of the same mechanisms.

## Lifecycle contract

The physical primary-button state is the authoritative signal that an in-panel
pointer session is still active. The drag pasteboard is payload storage, not a
lifecycle owner, because its types can remain populated after mouse-up.

An unpinned panel therefore follows this state machine:

1. Left mouse-down inside the panel begins a protected pointer session.
2. While the primary button is physically pressed, focus loss cannot dismiss.
3. After mouse-up, a short main-actor retry observes the released button,
   clears protection, restores transient collection behavior, then applies the
   normal lost-focus dismissal policy.
4. Pinned state bypasses dismissal but never owns drag-session completion.

Opening-event protection uses the existing exact ignored-target geometry. It
does not use a blanket timer that would swallow a legitimate fast click-away.

## Image transfer contract

The drag-start closure must follow `presentationContentType`, because that is
the content the card promises to the user. A mixed item presented as an image
must therefore return one image provider without OCR/title plain-text or file
providers that let an external app choose the wrong payload.

That provider must already advertise PNG, TIFF, `NSImage`, and PNG-file
representations. Repository-backed content may load bytes asynchronously
inside those registered representations, but all representations share one
lazy hydration task for the lifetime of that provider. Provider-level tests
cover inline, mixed-image, and hydrated items; runtime acceptance proves an
external app accepts the payload.

## Compatibility and rollback

No schema or stored-data changes. A rollback is the focused implementation
commit. Existing text/file drag and direct-paste paths remain untouched.
