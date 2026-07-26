import XCTest
@testable import PasteBuddy
import PasteBuddyCore

final class ScreenPinModelsTests: XCTestCase {
    func testPinKindResolvesImageFilesColorLatexAndText() {
        XCTAssertEqual(ScreenPinKind.resolve(item: item(payload: ClipboardPayload(imageData: Data([1])))), .image)
        XCTAssertEqual(
            ScreenPinKind.resolve(item: item(payload: ClipboardPayload(fileURLString: "file:///tmp/a.txt"))),
            .files
        )
        XCTAssertEqual(ScreenPinKind.resolve(item: item(payload: ClipboardPayload(text: "#29B8DB"))), .color)
        XCTAssertEqual(
            ScreenPinKind.resolve(item: item(payload: ClipboardPayload(text: "$$x^2$$"))),
            .latex
        )
        XCTAssertEqual(ScreenPinKind.resolve(item: item(payload: ClipboardPayload(text: "notes"))), .text)
    }

    func testColorParserSupportsDocumentedFormats() {
        XCTAssertEqual(ScreenPinColor.parse("#29B8DB")?.hexString, "#29B8DB")
        XCTAssertEqual(ScreenPinColor.parse("rgb(41, 184, 219)")?.hexString, "#29B8DB")
        XCTAssertEqual(ScreenPinColor.parse("41, 184, 219")?.hexString, "#29B8DB")
        XCTAssertEqual(ScreenPinColor.parse("orange")?.hexString, "#FFA500")
        XCTAssertNil(ScreenPinColor.parse("rgb(999, 0, 0)"))
    }

    func testCloseRestoreAndDestroyHaveDistinctHistorySemantics() throws {
        let group = ScreenPinGroup(name: "Default")
        var registry = ScreenPinRegistry(groups: [group], activeGroupID: group.id)
        let state = ScreenPinState(
            itemID: UUID(),
            kind: .text,
            title: "Reference",
            frame: CGRect(x: 10, y: 20, width: 200, height: 100),
            groupID: group.id
        )
        registry.add(state)

        XCTAssertEqual(registry.close(id: state.id, at: Date(timeIntervalSince1970: 100))?.id, state.id)
        XCTAssertTrue(registry.activePins.isEmpty)
        XCTAssertEqual(registry.recentlyClosed.map(\.id), [state.id])

        XCTAssertEqual(registry.restoreMostRecent()?.id, state.id)
        XCTAssertEqual(registry.activePins.map(\.id), [state.id])
        XCTAssertTrue(registry.recentlyClosed.isEmpty)

        registry.destroy(id: state.id)
        XCTAssertTrue(registry.activePins.isEmpty)
        XCTAssertTrue(registry.recentlyClosed.isEmpty)
    }

    func testGroupsAreUniqueAndSwitchWithoutMovingPins() throws {
        let initial = ScreenPinGroup(name: "Default")
        var registry = ScreenPinRegistry(groups: [initial], activeGroupID: initial.id)
        let research = try XCTUnwrap(registry.createGroup(name: "Research", colorHex: "#4EA7FC"))
        XCTAssertNil(registry.createGroup(name: "research"))
        XCTAssertTrue(registry.selectGroup(research.id))
        XCTAssertEqual(registry.activeGroupID, research.id)
        XCTAssertEqual(registry.groups.count, 2)
    }

    private func item(payload: ClipboardPayload) -> ClipboardItem {
        ClipboardItem(
            sourceAppName: "Test",
            deviceName: "Mac",
            contentType: payload.hasImageAsset ? .image : .text,
            title: "Item",
            payload: payload
        )
    }
}
