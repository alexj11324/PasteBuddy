import AppKit
import XCTest
@testable import PasteBuddy

final class ShelfCollectionScrollMathTests: XCTestCase {
    private let documentSize = NSSize(width: 340, height: 2000)
    private let viewport = NSRect(x: 0, y: 300, width: 340, height: 400)

    func testRevealsRowBelowViewportByAligningItsBottomEdge() {
        let itemFrame = NSRect(x: 4, y: 900, width: 324, height: 82)

        let origin = ShelfCollectionScrollMath.origin(
            toReveal: itemFrame,
            visibleRect: viewport,
            documentSize: documentSize,
            direction: .vertical
        )

        XCTAssertEqual(origin, NSPoint(x: 0, y: 982 - 400))
    }

    func testRevealsRowAboveViewportByAligningItsTopEdge() {
        let itemFrame = NSRect(x: 4, y: 100, width: 324, height: 82)

        let origin = ShelfCollectionScrollMath.origin(
            toReveal: itemFrame,
            visibleRect: viewport,
            documentSize: documentSize,
            direction: .vertical
        )

        XCTAssertEqual(origin, NSPoint(x: 0, y: 100))
    }

    func testReturnsNilWhenRowIsAlreadyFullyVisible() {
        let itemFrame = NSRect(x: 4, y: 400, width: 324, height: 82)

        XCTAssertNil(
            ShelfCollectionScrollMath.origin(
                toReveal: itemFrame,
                visibleRect: viewport,
                documentSize: documentSize,
                direction: .vertical
            )
        )
    }

    func testRevealsPartiallyVisibleRowAtViewportBottom() {
        let itemFrame = NSRect(x: 4, y: 660, width: 324, height: 82)

        let origin = ShelfCollectionScrollMath.origin(
            toReveal: itemFrame,
            visibleRect: viewport,
            documentSize: documentSize,
            direction: .vertical
        )

        XCTAssertEqual(origin, NSPoint(x: 0, y: 742 - 400))
    }

    func testClampsToDocumentEndForLastRow() {
        let itemFrame = NSRect(x: 4, y: 1950, width: 324, height: 82)

        let origin = ShelfCollectionScrollMath.origin(
            toReveal: itemFrame,
            visibleRect: viewport,
            documentSize: documentSize,
            direction: .vertical
        )

        XCTAssertEqual(origin, NSPoint(x: 0, y: 2000 - 400))
    }

    func testClampsToDocumentStartForFirstRow() {
        let itemFrame = NSRect(x: 4, y: 0, width: 324, height: 82)

        let origin = ShelfCollectionScrollMath.origin(
            toReveal: itemFrame,
            visibleRect: viewport,
            documentSize: documentSize,
            direction: .vertical
        )

        XCTAssertEqual(origin, NSPoint(x: 0, y: 0))
    }

    func testReturnsNilWhenViewportAlreadyShowsWholeShortList() {
        let shortDocument = NSSize(width: 340, height: 300)
        let fullViewport = NSRect(x: 0, y: 0, width: 340, height: 400)
        let itemFrame = NSRect(x: 4, y: 200, width: 324, height: 82)

        XCTAssertNil(
            ShelfCollectionScrollMath.origin(
                toReveal: itemFrame,
                visibleRect: fullViewport,
                documentSize: shortDocument,
                direction: .vertical
            )
        )
    }

    func testRevealsCardOutsideViewportHorizontally() {
        let horizontalViewport = NSRect(x: 100, y: 0, width: 600, height: 200)
        let horizontalDocument = NSSize(width: 3000, height: 200)
        let itemFrame = NSRect(x: 900, y: 0, width: 180, height: 200)

        let origin = ShelfCollectionScrollMath.origin(
            toReveal: itemFrame,
            visibleRect: horizontalViewport,
            documentSize: horizontalDocument,
            direction: .horizontal
        )

        XCTAssertEqual(origin, NSPoint(x: 1080 - 600, y: 0))
    }
}
