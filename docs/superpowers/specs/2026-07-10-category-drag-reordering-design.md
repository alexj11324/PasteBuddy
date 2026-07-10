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

Use a category-specific drag payload so category reordering cannot be confused with the existing clipboard-card payload. Dropping one category on another moves the source before or after the target according to pointer position, with native drag feedback. Both panels call the same store move operation.

Reordering must not change the selected scope, run a history query, or bump query revision. Every chip exposes the existing localized move-left and move-right accessibility actions, disabled at the corresponding edge. The custom-pinboard context-menu commands call the same mixed-order move operation instead of `moveUserPinboards`; built-in and smart chips do not gain an editing context menu.

## Verification

- Model tests: legacy default order, cross-type move, duplicate/stale repair, create/delete reconciliation, persistence after reload, and no query-revision change.
- UI contract tests: Shelf and Side Panel use the shared order and the category payload while preserving card-drop rules and smart-icon restrictions.
- Runtime: build and launch `/Applications/PasteBuddy Dev.app` with stable Apple Development signing, then use Computer Use with live window geometry to drag categories in both panels and confirm the order survives relaunch.
