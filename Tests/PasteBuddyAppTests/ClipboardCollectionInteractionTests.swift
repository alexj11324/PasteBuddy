import PasteBuddyCore
import XCTest
@testable import PasteBuddy

@MainActor
final class ClipboardCollectionInteractionTests: XCTestCase {
    func testDragPreviewAndCancelRestoreOriginalOrder() {
        let text = ClipboardCollectionID.smart(.text)
        let original: [ClipboardCollectionID] = [.history, .pasteStack, text]
        var session = ClipboardCollectionDragSession()

        session.begin(source: text, order: original, frames: [:], sourceOriginX: 100)
        session.updateTranslation(40)

        XCTAssertTrue(session.previewMove(relativeTo: .pasteStack, afterTarget: false))
        XCTAssertEqual(session.displayOrder(fallback: original), [.history, text, .pasteStack])
        XCTAssertEqual(session.visualOffset(currentSourceLayoutMinX: 160), -20)
        XCTAssertEqual(
            session.pendingMove,
            ClipboardCollectionMove(source: text, target: .pasteStack, afterTarget: false)
        )

        session.cancel()
        XCTAssertEqual(session.displayOrder(fallback: original), original)
        XCTAssertNil(session.pendingMove)
    }

    func testDropTargetsUseGeometryCapturedAtDragStart() throws {
        let text = ClipboardCollectionID.smart(.text)
        let links = ClipboardCollectionID.smart(.links)
        let order: [ClipboardCollectionID] = [text, .history, links, .pasteStack]
        var frames: [ClipboardCollectionID: CGRect] = [
            text: CGRect(x: 0, y: 0, width: 60, height: 30),
            .history: CGRect(x: 65, y: 0, width: 100, height: 30),
            links: CGRect(x: 170, y: 0, width: 70, height: 30),
            .pasteStack: CGRect(x: 245, y: 0, width: 116, height: 30),
        ]
        var session = ClipboardCollectionDragSession()
        session.begin(source: .pasteStack, order: order, frames: frames, sourceOriginX: 245)

        frames[links] = CGRect(x: 300, y: 0, width: 70, height: 30)
        let target = try XCTUnwrap(session.dropTarget(at: 180))

        XCTAssertEqual(target.collection, links)
        XCTAssertFalse(target.afterTarget)
    }

    func testMoveStateSuppressesOnlyItsOwnPersistedDataRevision() {
        let previous = queryState(dataRevision: 1)
        var state = ClipboardPanelCollectionMoveState()

        XCTAssertTrue(state.recordMove(true, dataRevision: 2))
        XCTAssertFalse(state.requiresRefresh(from: previous, to: queryState(dataRevision: 2)))

        XCTAssertTrue(state.recordMove(true, dataRevision: 3))
        XCTAssertTrue(state.requiresRefresh(
            from: queryState(dataRevision: 2),
            to: queryState(dataRevision: 3, queryRevision: 8)
        ))
    }

    private func queryState(
        dataRevision: Int,
        queryRevision: Int = 7
    ) -> ClipboardPanelQueryState {
        ClipboardPanelQueryState(
            dataRevision: dataRevision,
            queryRevision: queryRevision,
            scope: .history,
            searchQuery: "",
            contentTypeFilter: nil,
            sourceAppFilter: nil,
            deviceFilter: nil,
            dateFilter: .any
        )
    }
}
