# Category Drag Reordering Design

## Goal

Let users drag every collection chip in the Shelf and Side Panel to a new position. The order includes Clipboard, Paste Stack, smart categories, and custom pinboards, and survives relaunch.

## Scope

- Both Shelf and Side Panel render the same persisted order.
- All collection chips are reorderable across collection types.
- The plus button is not part of the order.
- Card-to-collection drops remain unchanged: cards can be dropped into Clipboard, Paste Stack, or a custom pinboard, but not a smart category.
- Smart-category icons remain system-owned. Only custom pinboards expose name, color, and icon editing.

## Model

Add one small Codable collection identifier with four cases: history, paste stack, `SmartPinboardCategory`, and custom pinboard UUID. Store an array of these identifiers in the existing `GeneralConfiguration`.

The store exposes one resolved order. Resolution removes duplicates and stale custom-pinboard IDs, preserves valid saved entries, and appends missing entries in this exact canonical order: history, paste stack, `SmartPinboardCategory.allCases`, then custom pinboards in their existing `snapshot.pinboards` order. Legacy snapshots without an order therefore keep the current layout without migration work.

An explicit move updates the stored array and calls the existing save pipeline. Creating a custom pinboard appends it; deleting one removes it. No second UserDefaults or view-local source of truth is introduced.

## Interaction

Category reordering stays entirely inside SwiftUI with `DragGesture`; it never creates a pasteboard payload or system drag session, so macOS cannot present the copy badge. Card drops remain a separate typed `dropDestination` with `.copy` semantics. No `NSViewRepresentable` or custom AppKit dragging destination remains in this path.

Each panel owns a view-local drag session containing the source, original order, preview order, translation, and pending target side. Every chip reports its frame in the strip coordinate space. While the source gesture moves, the nearest target midpoint updates the preview inside `withAnimation`; the source chip is offset with the pointer while its layout slot remains, so adjacent chips move aside and expose the insertion gap. Gesture end yields one relative move, commits it to `PasteBuddyStore`, then clears the preview. Escape cancels the local session without persistence. Card membership stays in the existing `ClipboardCollectionDropTarget`.

Reordering must not change the selected scope, run a history query, or bump query revision. Every chip exposes the existing localized move-left and move-right accessibility actions, disabled at the corresponding edge. The custom-pinboard context-menu commands call the same mixed-order move operation instead of `moveUserPinboards`; built-in and smart chips do not gain an editing context menu.

## Verification

- Model tests: legacy default order, cross-type move, duplicate/stale repair, create/delete reconciliation, persistence after reload, and no query-revision change.
- Executable state tests: preview-only movement keeps the transparent source placeholder in the array, repeated target/side updates are no-ops, completion yields one move and clears state, and cancellation yields no move and restores the original display order.
- UI contract tests: Shelf and Side Panel use the shared SwiftUI gesture modifier, midpoint frames, one final commit, no category pasteboard payload or AppKit drop target, and preserve card-drop rules and smart-icon restrictions.
- Runtime: build and launch `/Applications/PasteBuddy Dev.app` with stable Apple Development signing, then use Computer Use with live window geometry to verify the category cursor has no copy badge, neighboring chips animate aside before release, category order changes in both panels and survives relaunch, a card still copies into a custom pinboard, and a smart category rejects card drops.
