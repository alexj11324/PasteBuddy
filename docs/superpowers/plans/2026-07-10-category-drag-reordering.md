# Category Drag Reordering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every Shelf and Side Panel collection chip draggable across collection types and persist the shared order across relaunches.

**Architecture:** Add a stable Codable collection identifier to the existing snapshot general configuration. `PasteBuddyStore` owns normalization and moves; both macOS panels render that one order and exchange a category-specific native `Transferable` payload, leaving clipboard-card drops on their existing payload type.

**Tech Stack:** Swift 6, Observation, SwiftUI `draggable`/`dropDestination`, CoreTransferable, SwiftPM/XCTest, AppKit runtime verification.

---

### Task 1: Persist and normalize one mixed collection order

**Files:**
- Modify: `Sources/PasteBuddyCore/Models/ClipboardModels.swift`
- Modify: `Sources/PasteBuddyCore/Stores/PasteBuddyStore.swift`
- Test: `Tests/PasteBuddyCoreTests/PasteBuddyStoreTests.swift`

- [ ] **Step 1: Write failing model/store tests**

Add tests that prove:

```swift
func testCollectionOrderDefaultsToBuiltInsSmartCategoriesThenExistingUserPinboards()
func testCollectionOrderRepairsDuplicatesStaleIDsAndMissingEntries()
func testMoveCollectionAcrossTypesPersistsWithoutChangingQueryRevision()
func testCreatingAndDeletingPinboardsReconcilesPersistedCollectionOrder()
```

The canonical expectation is:

```swift
[
    .history,
    .pasteStack,
    .smart(.text),
    .smart(.links),
    .smart(.images),
    .smart(.files),
    .pinboard(favoritesID)
]
```

- [ ] **Step 2: Run the tests and verify they fail**

Run:

```bash
swift test --disable-sandbox --filter 'PasteBuddyStoreTests/testCollectionOrder|PasteBuddyStoreTests/testMoveCollection|PasteBuddyStoreTests/testCreatingAndDeletingPinboardsReconciles'
```

Expected: compile failure because `ClipboardCollectionID` and store ordering APIs do not exist.

- [ ] **Step 3: Add the minimal Codable identifier and optional legacy field**

In `ClipboardModels.swift` add:

```swift
public enum ClipboardCollectionID: Hashable, Codable, Sendable, Identifiable {
    case history
    case pasteStack
    case smart(SmartPinboardCategory)
    case pinboard(UUID)

    public var id: String {
        switch self {
        case .history: "history"
        case .pasteStack: "pasteStack"
        case .smart(let category): "smart:\(category.rawValue)"
        case .pinboard(let id): "pinboard:\(id.uuidString)"
        }
    }
}
```

Add `collectionOrder: [ClipboardCollectionID]? = nil` to `GeneralConfiguration`. Keeping it optional lets synthesized `Codable` decode old snapshots without a migration or custom decoder.

- [ ] **Step 4: Add one resolver and two move APIs to the store**

Implement the shared resolver using the saved order plus a canonical list:

```swift
public var collectionOrder: [ClipboardCollectionID] {
    let canonical: [ClipboardCollectionID] = [
        .history,
        .pasteStack
    ] + SmartPinboardCategory.allCases.map(ClipboardCollectionID.smart)
      + userPinboards.map { .pinboard($0.id) }
    let valid = Set(canonical)
    var seen = Set<ClipboardCollectionID>()
    let saved = (snapshot.general.collectionOrder ?? []).filter {
        valid.contains($0) && seen.insert($0).inserted
    }
    return saved + canonical.filter { seen.insert($0).inserted }
}
```

Add:

```swift
public func moveCollection(
    _ source: ClipboardCollectionID,
    relativeTo target: ClipboardCollectionID,
    afterTarget: Bool
)

public func moveCollection(_ collection: ClipboardCollectionID, by offset: Int)
```

Both operate on `collectionOrder`, return on no-op/invalid input, assign the final array to `snapshot.general.collectionOrder`, and call the existing `save()`. The relative move removes the source before calculating the target insertion index. The offset form bounds-checks `index + offset` and delegates to the same mutation path.

After custom pinboard creation or deletion, assign `snapshot.general.collectionOrder = collectionOrder` before the existing save so the stored array immediately appends or removes the ID.

- [ ] **Step 5: Run the focused tests**

Run the Step 2 command.

Expected: all selected tests pass; the persistence test reloads a new `PasteBuddyStore` and sees the same mixed order.

- [ ] **Step 6: Commit the model/store slice**

```bash
git add Sources/PasteBuddyCore/Models/ClipboardModels.swift Sources/PasteBuddyCore/Stores/PasteBuddyStore.swift Tests/PasteBuddyCoreTests/PasteBuddyStoreTests.swift
git commit -m "feat: persist collection chip order"
```

### Task 2: Render and drag the shared order in both panels

**Files:**
- Modify: `Sources/PasteBuddy/Models/PinboardItemDragPayload.swift`
- Modify: `Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift`
- Modify: `Sources/PasteBuddy/Views/ClipboardSidePanelView.swift`
- Modify: `Sources/PasteBuddy/Views/PinboardEditPrompt.swift`
- Test: `Tests/PasteBuddyAppTests/PasteBuddyAppRuntimeTests.swift`

- [ ] **Step 1: Write failing UI contract tests**

Add/adjust source-contract tests that require:

```swift
XCTAssertTrue(shelfSource.contains("ForEach(store.collectionOrder)"))
XCTAssertTrue(sideSource.contains("ForEach(store.collectionOrder)"))
XCTAssertTrue(payloadSource.contains("struct ClipboardCollectionDragPayload"))
XCTAssertTrue(payloadSource.contains("pasteBuddyCollectionID"))
XCTAssertTrue(shelfSource.contains("dropDestination(for: ClipboardCollectionDragPayload.self"))
XCTAssertTrue(sideSource.contains("dropDestination(for: ClipboardCollectionDragPayload.self"))
XCTAssertTrue(promptSource.contains("store.moveCollection"))
XCTAssertFalse(promptSource.contains("store.moveUserPinboards"))
```

Keep existing assertions that smart categories have no item-drop closure or edit menu and custom pinboards retain `ShelfCollectionChipDropTarget` card drops.

- [ ] **Step 2: Run the UI tests and verify they fail**

```bash
swift test --disable-sandbox --filter 'PasteBuddyAppRuntimeTests/test.*Collection|PasteBuddyAppRuntimeTests/testOnlyCustomPinboards'
```

Expected: failures for the missing category payload and shared-order rendering.

- [ ] **Step 3: Add a category-specific native drag payload**

In `PinboardItemDragPayload.swift`, add `import PasteBuddyCore`, then add:

```swift
struct ClipboardCollectionDragPayload: Codable, Transferable {
    let collection: ClipboardCollectionID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pasteBuddyCollectionID)
    }
}

extension UTType {
    static let pasteBuddyCollectionID = UTType(exportedAs: "app.pastebuddy.collection-id")
}
```

Do not add a plaintext proxy. This keeps category drags distinct from `PinboardItemDragPayload` and prevents accidental card imports.

- [ ] **Step 4: Render `store.collectionOrder` in Shelf**

Replace the four fixed groups in `collectionStrip` with `ForEach(store.collectionOrder)` and a `@ViewBuilder` switch:

```swift
@ViewBuilder
private func collectionChip(for collection: ClipboardCollectionID) -> some View {
    switch collection {
    case .history: /* existing Clipboard chip */
    case .pasteStack: /* existing Paste Stack chip */
    case .smart(let category): /* existing smart chip, no card drop/edit menu */
    case .pinboard(let id): /* existing custom chip/drop/edit menu when ID resolves */
    }
}
```

Pass the collection ID and move closures into `ShelfCollectionChip`. Attach `.draggable(ClipboardCollectionDragPayload(collection: collectionID))`. Add a `GeometryReader` inside the existing capsule overlay and attach:

```swift
.dropDestination(for: ClipboardCollectionDragPayload.self) { payloads, location in
    guard let source = payloads.first?.collection else { return false }
    return onReorder(source, collectionID, location.x >= proxy.size.width / 2)
} isTargeted: { isCollectionDropTargeted = $0 }
```

The existing AppKit overlay remains registered only for `.pasteBuddyPinboardItemIDs`, so card drops and category drops keep separate paths. Highlight the capsule when either drop path targets it.

- [ ] **Step 5: Render the same order and drag behavior in Side Panel**

Apply the same `ForEach(store.collectionOrder)` switch to `quickFilterStrip` and the same category payload/drop logic to `ClipboardSidePanelFilterChip`. Keep its compact visual metrics and its existing card-drop overlay.

Both views call:

```swift
store.moveCollection(source, relativeTo: target, afterTarget: afterTarget)
```

No drag handler may assign `selectedScope`, `shelfScope`, or `sideScope`.

- [ ] **Step 6: Preserve pointer and accessibility alternatives**

Add conditional localized accessibility actions for every chip using existing keys `action.move_left` and `action.move_right`; omit the action at its corresponding edge. Update `CustomPinboardActionsMenu` so its buttons call `store.moveCollection(.pinboard(pinboard.id), by: -1/+1)` and disable using the mixed order index. Built-in and smart chips receive no edit context menu.

- [ ] **Step 7: Run focused app and store tests**

```bash
swift test --disable-sandbox --filter PasteBuddyAppRuntimeTests
swift test --disable-sandbox --filter PasteBuddyStoreTests
```

Expected: both suites pass, including existing card-drop, smart-category, custom-icon, and query-revision regressions.

- [ ] **Step 8: Commit the UI slice**

```bash
git add Sources/PasteBuddy/Models/PinboardItemDragPayload.swift Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift Sources/PasteBuddy/Views/ClipboardSidePanelView.swift Sources/PasteBuddy/Views/PinboardEditPrompt.swift Tests/PasteBuddyAppTests/PasteBuddyAppRuntimeTests.swift
git commit -m "feat: reorder collection chips by dragging"
```

### Task 3: Verify the complete branch on real signed products

**Files:**
- Modify only if verification exposes a defect.

- [ ] **Step 1: Run repository gates**

```bash
git diff --check
python3 script/localization_catalog_workflow.py check
swift test --disable-sandbox
```

Expected: localization status `ok`; all tests pass except the two environment-dependent Secure Enclave skips.

- [ ] **Step 2: Compile the signed iOS simulator product**

Run the normal simulator build without `CODE_SIGNING_ALLOWED=NO`. If Desktop file coordination stalls, copy the exact tracked/untracked working files to `/private/tmp` and build the same project there:

```bash
xcodebuild -project PasteBuddyiOS.xcodeproj -scheme PasteBuddyiOS -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -derivedDataPath /private/tmp/pastebuddy-ios-deriveddata build
```

Expected: `** BUILD SUCCEEDED **` for the app and all extensions.

- [ ] **Step 3: Install and verify the stable macOS development identity**

```bash
script/build_and_run.sh --verify
codesign --verify --deep --strict --verbose=4 "/Applications/PasteBuddy Dev.app"
codesign -dvvv -r- "/Applications/PasteBuddy Dev.app"
```

Expected diagnostics: `accessibilityTrusted=true`, `stableLaunchPathMatched=true`, bundle `com.alexjiang.PasteBuddy.dev`, path `/Applications/PasteBuddy Dev.app`, and `signingChannel=development` with Apple Development signing.

- [ ] **Step 4: Verify real drag behavior with Computer Use**

Open only the approved Side Panel/Shelf via `script/open_dev_panel.sh`. Read live window and chip frames before each interaction. With Computer Use:

1. Drag Clipboard after a smart category and confirm both panels show the new order.
2. Relaunch the stable app and confirm the order remains.
3. Drag a clipboard card into Favorites and confirm it appears there.
4. Open Favorites editing and confirm name/color/icon controls remain.
5. Right-click a smart category and confirm no editing menu appears.
6. Select an image and press Space; confirm the preview opens and Apple Live Text analyzes the original image.

Do not open the main history window and do not use guessed coordinates.

- [ ] **Step 5: Inspect and commit any verification-only fixes**

```bash
git status --short
git diff --check
```

If fixes were needed, run the affected gates again and commit only those fixes. Otherwise leave the two feature commits unchanged.
