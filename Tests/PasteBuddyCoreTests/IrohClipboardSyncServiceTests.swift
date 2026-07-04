import XCTest
@testable import PasteBuddyCore

final class IrohClipboardSyncServiceTests: XCTestCase {
    func testWireFormatRoundTripsClipboardItem() throws {
        let item = ClipboardItem(
            sourceAppName: "Unit Test",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Hello",
            payload: ClipboardPayload(text: "Hello from iroh")
        )
        let frame = try IrohClipboardWireFormat.encode(IrohClipboardSyncEnvelope(item: item))
        let lengthPrefix = frame.prefix(MemoryLayout<UInt32>.size)
        let body = frame.dropFirst(MemoryLayout<UInt32>.size)

        let decoded = try IrohClipboardWireFormat.decode(lengthPrefix: Data(lengthPrefix), body: Data(body))

        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.item.id, item.id)
        XCTAssertEqual(decoded.item.payload.text, "Hello from iroh")
    }

    func testWireFormatRejectsLengthMismatch() throws {
        var length = UInt32(4).littleEndian
        let lengthPrefix = Data(bytes: &length, count: MemoryLayout<UInt32>.size)

        XCTAssertThrowsError(try IrohClipboardWireFormat.decode(lengthPrefix: lengthPrefix, body: Data([1, 2, 3])))
    }
}
