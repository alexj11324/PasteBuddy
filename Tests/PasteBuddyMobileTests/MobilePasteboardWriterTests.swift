import XCTest
@testable import PasteBuddyCore
@testable import PasteBuddyMobile

@MainActor
final class MobilePasteboardWriterTests: XCTestCase {
    func testMobilePasteboardWriterIsUnavailableOutsideUIKit() {
        let item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Text",
            payload: ClipboardPayload(text: "mobile copy")
        )

        #if canImport(UIKit)
        XCTAssertTrue(MobilePasteboardWriter.copy(item))
        #else
        XCTAssertFalse(MobilePasteboardWriter.copy(item))
        #endif
    }
}
