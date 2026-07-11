import Foundation
import PasteBuddyCore
import SwiftUI

struct ClipboardPanelCollectionMoveState {
    private(set) var ignoredDataRevision: Int?

    @discardableResult
    mutating func recordMove(_ moved: Bool, dataRevision: Int) -> Bool {
        if moved {
            ignoredDataRevision = dataRevision
        }
        return moved
    }

    mutating func requiresRefresh(
        from previous: ClipboardPanelQueryState,
        to current: ClipboardPanelQueryState
    ) -> Bool {
        defer { ignoredDataRevision = nil }
        guard current != previous else { return false }
        guard current.dataRevision == ignoredDataRevision else { return true }
        return current.queryRevision != previous.queryRevision
            || current.scope != previous.scope
            || current.searchQuery != previous.searchQuery
            || current.contentTypeFilter != previous.contentTypeFilter
            || current.sourceAppFilter != previous.sourceAppFilter
            || current.deviceFilter != previous.deviceFilter
            || current.dateFilter != previous.dateFilter
    }
}

struct ClipboardCollectionMove: Equatable {
    let source: ClipboardCollectionID
    let target: ClipboardCollectionID
    let afterTarget: Bool
}

struct ClipboardCollectionDragSession {
    private(set) var source: ClipboardCollectionID?
    private var originalOrder: [ClipboardCollectionID]?
    private var previewOrder: [ClipboardCollectionID]?
    private var pendingTarget: ClipboardCollectionID?
    private var pendingAfterTarget = false
    private var targetFrames: [ClipboardCollectionID: CGRect] = [:]
    private var sourceOriginX: CGFloat = 0
    private(set) var translationX: CGFloat = 0

    var isActive: Bool { source != nil }

    mutating func begin(
        source: ClipboardCollectionID,
        order: [ClipboardCollectionID],
        frames: [ClipboardCollectionID: CGRect],
        sourceOriginX: CGFloat = 0
    ) {
        guard order.contains(source) else {
            cancel()
            return
        }
        self.source = source
        originalOrder = order
        previewOrder = order
        pendingTarget = nil
        pendingAfterTarget = false
        targetFrames = frames
        self.sourceOriginX = sourceOriginX
        translationX = 0
    }

    func displayOrder(fallback: [ClipboardCollectionID]) -> [ClipboardCollectionID] {
        previewOrder ?? fallback
    }

    mutating func updateTranslation(_ translationX: CGFloat) {
        self.translationX = translationX
    }

    func visualOffset(currentSourceLayoutMinX: CGFloat) -> CGFloat {
        guard isActive else { return 0 }
        return translationX + sourceOriginX - currentSourceLayoutMinX
    }

    var pendingMove: ClipboardCollectionMove? {
        guard let source,
              let target = pendingTarget,
              previewOrder != originalOrder else {
            return nil
        }
        return ClipboardCollectionMove(
            source: source,
            target: target,
            afterTarget: pendingAfterTarget
        )
    }

    func dropTarget(at x: CGFloat) -> (collection: ClipboardCollectionID, afterTarget: Bool)? {
        guard let source, let originalOrder else { return nil }
        return originalOrder
            .filter { $0 != source }
            .compactMap { collection in
                targetFrames[collection].map { (collection, $0, abs($0.midX - x)) }
            }
            .min { $0.2 < $1.2 }
            .map { ($0.0, x >= $0.1.midX) }
    }

    @discardableResult
    mutating func previewMove(
        relativeTo target: ClipboardCollectionID,
        afterTarget: Bool
    ) -> Bool {
        guard let source,
              source != target,
              var order = previewOrder,
              let sourceIndex = order.firstIndex(of: source) else {
            return false
        }
        guard pendingTarget != target || pendingAfterTarget != afterTarget else { return false }

        order.remove(at: sourceIndex)
        guard let targetIndex = order.firstIndex(of: target) else { return false }
        order.insert(source, at: min(targetIndex + (afterTarget ? 1 : 0), order.endIndex))
        pendingTarget = target
        pendingAfterTarget = afterTarget
        guard order != previewOrder else { return false }
        previewOrder = order
        return true
    }

    mutating func cancel() {
        source = nil
        originalOrder = nil
        previewOrder = nil
        pendingTarget = nil
        pendingAfterTarget = false
        targetFrames = [:]
        sourceOriginX = 0
        translationX = 0
    }
}

enum ClipboardCollectionDragCoordinateSpace {
    static let name = "clipboard-collection-strip"
}

enum ClipboardCollectionDropTarget {
    case history
    case pasteStack
    case pinboard(UUID)

    @MainActor
    func apply(
        ids: [UUID],
        store: PasteBuddyStore,
        selectScope: (PasteScope) -> Void
    ) -> Bool {
        guard !ids.isEmpty else { return false }
        switch self {
        case .history:
            selectScope(.history)
            return true
        case .pasteStack:
            guard store.addItemsToPasteStack(ids) else { return false }
            selectScope(.pasteStack)
            return true
        case .pinboard(let pinboardID):
            store.pinItems(ids, to: pinboardID)
            selectScope(.pinboard(pinboardID))
            return true
        }
    }
}

enum ClipboardPanelSearchInput {
    static func accepts(_ modifiers: SwiftUI.EventModifiers) -> Bool {
        modifiers.subtracting([.shift, .capsLock]).isEmpty
    }

    static func accepts(_ characters: String) -> Bool {
        guard !characters.isEmpty else { return false }
        guard characters.rangeOfCharacter(from: .newlines) == nil else { return false }
        return characters.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

struct ClipboardCollectionReorderModifier: ViewModifier {
    let collection: ClipboardCollectionID
    let collectionOrder: [ClipboardCollectionID]
    @Binding var session: ClipboardCollectionDragSession
    @Binding var collectionFrames: [ClipboardCollectionID: CGRect]
    @Binding var isTargeted: Bool
    let animation: Animation?
    let onReorder: (ClipboardCollectionID, ClipboardCollectionID, Bool) -> Bool
    let onDropPayloads: (([PinboardItemDragPayload]) -> Bool)?

    func body(content: Content) -> some View {
        let currentSession = session
        let isDraggedCollection = currentSession.source == collection
        return ZStack {
            content
                .visualEffect { content, geometry in
                    content.offset(x: isDraggedCollection
                        ? currentSession.visualOffset(
                            currentSourceLayoutMinX: geometry.frame(in: .named(ClipboardCollectionDragCoordinateSpace.name)).minX
                        )
                        : 0)
                }
                .scaleEffect(session.source == collection ? 1.03 : 1)
        }
        .onGeometryChange(
            for: CGRect.self,
            of: { $0.frame(in: .named(ClipboardCollectionDragCoordinateSpace.name)) }
        ) { frame in
            guard collectionFrames[collection] != frame else { return }
            collectionFrames[collection] = frame
        }
        .highPriorityGesture(
            DragGesture(
                minimumDistance: 4,
                coordinateSpace: .named(ClipboardCollectionDragCoordinateSpace.name)
            )
            .onChanged(handleDragChanged)
            .onEnded(handleDragEnded)
        )
        .zIndex(session.source == collection ? 1 : 0)
        .modifier(ClipboardCollectionCardDropModifier(
            onDropPayloads: onDropPayloads,
            isTargeted: $isTargeted
        ))
    }

    private func handleDragChanged(_ value: DragGesture.Value) {
        guard let sourceFrame = collectionFrames[collection] else { return }
        if !session.isActive {
            session.begin(
                source: collection,
                order: collectionOrder,
                frames: collectionFrames,
                sourceOriginX: sourceFrame.minX
            )
        }
        guard session.source == collection else { return }
        session.updateTranslation(value.translation.width)
        guard let target = session.dropTarget(at: value.location.x) else { return }
        withAnimation(animation) {
            _ = session.previewMove(
                relativeTo: target.collection,
                afterTarget: target.afterTarget
            )
        }
    }

    private func handleDragEnded(_ value: DragGesture.Value) {
        guard session.source == collection else { return }
        session.updateTranslation(value.translation.width)
        if let move = session.pendingMove {
            _ = onReorder(move.source, move.target, move.afterTarget)
        }
        withAnimation(animation) {
            session.cancel()
        }
    }
}

struct ClipboardCollectionCardDropModifier: ViewModifier {
    let onDropPayloads: (([PinboardItemDragPayload]) -> Bool)?
    @Binding var isTargeted: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if let onDropPayloads {
            content.dropDestination(for: PinboardItemDragPayload.self) { payloads, _ in
                onDropPayloads(payloads)
            } isTargeted: {
                isTargeted = $0
            }
        } else {
            content
        }
    }
}
