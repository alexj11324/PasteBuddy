import AppKit
import Foundation
import Observation
import PasteBuddyCore

@MainActor
@Observable
final class ShelfInteractionModel {
    var items: [ClipboardItem] {
        didSet {
            guard !isReplacingItems else { return }
            reconcileSelectionAfterItemsChange()
        }
    }
    var selectedIDs: Set<UUID>
    var primarySelectedID: UUID?
    var selectionAnchorID: UUID?
    var previewedID: UUID?

    @ObservationIgnored private var isReplacingItems = false

    init(
        items: [ClipboardItem] = [],
        selectedIDs: Set<UUID> = [],
        primarySelectedID: UUID? = nil,
        selectionAnchorID: UUID? = nil,
        previewedID: UUID? = nil
    ) {
        self.items = items
        self.selectedIDs = selectedIDs
        self.primarySelectedID = primarySelectedID
        self.selectionAnchorID = selectionAnchorID
        self.previewedID = previewedID
        reconcileSelectionAfterItemsChange()
    }

    func select(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        guard items.contains(where: { $0.id == id }) else { return }

        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift),
           let anchorID = selectionAnchorID ?? primarySelectedID,
           let anchorIndex = itemIndex(for: anchorID),
           let clickedIndex = itemIndex(for: id) {
            let bounds = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
            setSelectedIDs(Set(items[bounds].map(\.id)))
            return
        }

        if flags.contains(.command) {
            var ids = selectedIDs
            if ids.contains(id) {
                ids.remove(id)
            } else {
                ids.insert(id)
            }
            setSelectedIDs(ids, anchorID: id)
            return
        }

        if selectedIDs.count > 1, selectedIDs.contains(id) {
            selectionAnchorID = id
            return
        }

        selectSingle(id)
    }

    func selectSingle(_ id: UUID?) {
        let ids = id.map { Set([$0]) } ?? []
        guard primarySelectedID != id || selectedIDs != ids else { return }
        selectedIDs = ids
        primarySelectedID = id
        selectionAnchorID = id
        clearPreviewUnlessSelected()
    }

    func setSelectedIDs(_ ids: Set<UUID>, anchorID: UUID? = nil) {
        let validIDs = ids.intersection(itemIDs)
        let primaryID = firstItemID(in: validIDs)
        guard selectedIDs != validIDs || primarySelectedID != primaryID else {
            if let anchorID {
                selectionAnchorID = anchorID
            }
            return
        }
        selectedIDs = validIDs
        primarySelectedID = primaryID
        if let anchorID {
            selectionAnchorID = anchorID
        }
        clearPreviewUnlessSelected()
    }

    @discardableResult
    func presentPreview(for id: UUID) -> Bool {
        guard itemIDs.contains(id) else { return false }
        selectSingle(id)
        previewedID = id
        return true
    }

    @discardableResult
    func togglePreview(for id: UUID) -> Bool {
        guard itemIDs.contains(id) else { return false }
        if previewedID == id {
            previewedID = nil
            return false
        }
        selectSingle(id)
        previewedID = id
        return true
    }

    func dismissPreview(for id: UUID? = nil) {
        guard id == nil || previewedID == id else { return }
        previewedID = nil
    }

    func replaceItems(
        _ newItems: [ClipboardItem],
        storeSelectedIDs: Set<UUID> = [],
        storePrimarySelectedID: UUID? = nil
    ) {
        let validIDs = Set(newItems.map(\.id))
        let localSelectedIDs = selectedIDs.intersection(validIDs)
        let localPrimaryID = primarySelectedID.flatMap { validIDs.contains($0) ? $0 : nil }

        isReplacingItems = true
        items = newItems
        isReplacingItems = false

        if !localSelectedIDs.isEmpty || localPrimaryID != nil {
            let ids = localSelectedIDs.isEmpty ? localPrimaryID.map { Set([$0]) } ?? [] : localSelectedIDs
            applySelection(ids, primaryID: normalizedPrimaryID(localPrimaryID, in: ids))
            reconcilePreviewAndAnchor()
            return
        }

        let validStoreSelectedIDs = storeSelectedIDs.intersection(validIDs)
        if !validStoreSelectedIDs.isEmpty {
            applySelection(validStoreSelectedIDs, primaryID: firstItemID(in: validStoreSelectedIDs))
        } else if let storePrimarySelectedID, validIDs.contains(storePrimarySelectedID) {
            applySelection([storePrimarySelectedID], primaryID: storePrimarySelectedID)
        } else {
            selectFallbackItem()
        }
        reconcilePreviewAndAnchor()
    }

    private var itemIDs: Set<UUID> {
        Set(items.map(\.id))
    }

    private func reconcileSelectionAfterItemsChange() {
        let validIDs = itemIDs
        let ids = selectedIDs.intersection(validIDs)
        if !ids.isEmpty {
            applySelection(ids, primaryID: normalizedPrimaryID(primarySelectedID, in: ids))
        } else if let primarySelectedID, validIDs.contains(primarySelectedID) {
            applySelection([primarySelectedID], primaryID: primarySelectedID)
        } else {
            selectFallbackItem()
        }
        reconcilePreviewAndAnchor()
    }

    private func selectFallbackItem() {
        if let firstID = items.first?.id {
            applySelection([firstID], primaryID: firstID)
        } else {
            applySelection([], primaryID: nil)
        }
    }

    private func applySelection(_ ids: Set<UUID>, primaryID: UUID?) {
        selectedIDs = ids
        primarySelectedID = primaryID
    }

    private func reconcilePreviewAndAnchor() {
        if let previewedID, !itemIDs.contains(previewedID) {
            self.previewedID = nil
        }
        if selectionAnchorID.map({ !itemIDs.contains($0) }) == true {
            selectionAnchorID = primarySelectedID
        }
    }

    private func clearPreviewUnlessSelected() {
        guard let previewedID else { return }
        if !selectedIDs.contains(previewedID) {
            self.previewedID = nil
        }
    }

    private func normalizedPrimaryID(_ candidate: UUID?, in ids: Set<UUID>) -> UUID? {
        if let candidate, ids.contains(candidate) {
            return candidate
        }
        return firstItemID(in: ids)
    }

    private func firstItemID(in ids: Set<UUID>) -> UUID? {
        items.first { ids.contains($0.id) }?.id
    }

    private func itemIndex(for id: UUID) -> Int? {
        items.firstIndex { $0.id == id }
    }
}
