import AppKit
import XCTest
@testable import PasteBuddy

final class PopoverPlacementPolicyTests: XCTestCase {
    func testChoosesPreferredSideWhenPreviewFitsOutsideContainingWindow() {
        let decision = PopoverPlacementPolicy.decision(
            preferredEdge: .minX,
            desiredContentSize: NSSize(width: 640, height: 448),
            containingWindowFrame: NSRect(x: 760, y: 80, width: 460, height: 760),
            screenFrame: NSRect(x: 0, y: 0, width: 1512, height: 982),
            margin: 12
        )

        XCTAssertEqual(decision.edge, .minX)
        XCTAssertEqual(decision.maximumContentSize, NSSize(width: 640, height: 448))
    }

    func testFallsBackToAnotherSideWhenPreferredSideWouldOverlapContainingWindow() {
        let decision = PopoverPlacementPolicy.decision(
            preferredEdge: .minX,
            desiredContentSize: NSSize(width: 640, height: 448),
            containingWindowFrame: NSRect(x: 20, y: 80, width: 460, height: 760),
            screenFrame: NSRect(x: 0, y: 0, width: 1512, height: 982),
            margin: 12
        )

        XCTAssertEqual(decision.edge, .maxX)
        XCTAssertEqual(decision.maximumContentSize, NSSize(width: 640, height: 448))
    }

    func testClampsPreviewSizeToBestNonOverlappingOutsideSpaceWhenNoSideFullyFits() {
        let decision = PopoverPlacementPolicy.decision(
            preferredEdge: .minX,
            desiredContentSize: NSSize(width: 1_000, height: 600),
            containingWindowFrame: NSRect(x: 380, y: 200, width: 440, height: 400),
            screenFrame: NSRect(x: 0, y: 0, width: 900, height: 700),
            margin: 12
        )

        XCTAssertEqual(decision.edge, .minX)
        XCTAssertEqual(decision.maximumContentSize, NSSize(width: 368, height: 600))
    }
}
