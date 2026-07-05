import XCTest
@testable import PasteBuddyCore

@MainActor
final class IrohClipboardSyncServiceTests: XCTestCase {
    private actor EnvelopeAttemptRecorder {
        private var attempts: [IrohClipboardSyncEnvelope] = []

        func record(_ envelope: IrohClipboardSyncEnvelope) -> Int {
            attempts.append(envelope)
            return attempts.count
        }

        func snapshot() -> [IrohClipboardSyncEnvelope] {
            attempts
        }
    }

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

    func testPairingURLRoundTripsEndpointId() throws {
        let endpointId = "abcdef123456"
        let url = try XCTUnwrap(IrohClipboardSyncService.pairingURL(endpointId: endpointId))

        XCTAssertEqual(try IrohClipboardSyncService.peerEndpointId(fromPairingCode: url.absoluteString), endpointId)
        XCTAssertThrowsError(try IrohClipboardSyncService.peerEndpointId(fromPairingCode: "https://example.com/?endpoint=\(endpointId)")) { error in
            XCTAssertEqual(error as? IrohClipboardSyncError, .invalidPairingCode)
        }
    }

    func testSlimmedFrameRetryDropsBinaryPayloadAndEncodes() throws {
        let oversized = ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .mixed,
            title: "Oversized Share",
            payload: ClipboardPayload(
                text: "fallback text survives",
                rtfData: Data(repeating: 0x52, count: 512),
                imageData: Data(repeating: 0x7A, count: IrohClipboardWireFormat.maxFrameBytes + 1_024)
            )
        )

        XCTAssertThrowsError(try IrohClipboardWireFormat.encode(IrohClipboardSyncEnvelope(item: oversized))) { error in
            guard case .frameTooLarge = error as? IrohClipboardSyncError else {
                return XCTFail("Expected frameTooLarge, got \(error)")
            }
        }

        let slimmed = IrohClipboardSyncService.slimmedItemForFrameRetry(from: oversized)
        XCTAssertNil(slimmed.payload.imageData)
        XCTAssertNil(slimmed.payload.rtfData)
        XCTAssertNotNil(try IrohClipboardWireFormat.encode(IrohClipboardSyncEnvelope(item: slimmed)))
    }

    func testSendRetriesFrameTooLargeWithSlimmedPayloadWithoutFailingConnection() async {
        let defaultsSuite = "PasteBuddyIrohRetry-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let service = IrohClipboardSyncService(
            defaults: defaults,
            identityStore: IrohClipboardIdentityStore(
                service: "com.alexjiang.PasteBuddy.tests.iroh.\(UUID().uuidString)",
                account: "retry"
            )
        )
        let item = ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .mixed,
            title: "Oversized Share",
            payload: ClipboardPayload(
                text: "fallback text survives",
                imageData: Data(repeating: 0x7A, count: 1_024)
            )
        )

        let recorder = EnvelopeAttemptRecorder()
        let result = await service.send(item) { envelope in
            let attemptNumber = await recorder.record(envelope)
            if attemptNumber == 1 {
                throw IrohClipboardSyncError.frameTooLarge(IrohClipboardWireFormat.maxFrameBytes + 1)
            }
        }
        let attempts = await recorder.snapshot()

        XCTAssertTrue(result)
        XCTAssertEqual(attempts.count, 2)
        XCTAssertNotNil(attempts.first?.item.payload.imageData)
        XCTAssertNil(attempts.last?.item.payload.imageData)
        XCTAssertEqual(service.connectionState, .idle)
        XCTAssertNotNil(service.lastSentAt)
    }

    func testSendDoesNotMarkConnectionFailedWhenSlimmedRetryStillFails() async {
        let defaultsSuite = "PasteBuddyIrohRetryFail-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let service = IrohClipboardSyncService(
            defaults: defaults,
            identityStore: IrohClipboardIdentityStore(
                service: "com.alexjiang.PasteBuddy.tests.iroh.\(UUID().uuidString)",
                account: "retry-fail"
            )
        )
        let item = ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .mixed,
            title: "Oversized Share",
            payload: ClipboardPayload(
                text: "fallback text survives",
                imageData: Data(repeating: 0x7A, count: 1_024)
            )
        )

        let result = await service.send(item) { _ in
            throw IrohClipboardSyncError.frameTooLarge(IrohClipboardWireFormat.maxFrameBytes + 1)
        }

        XCTAssertFalse(result)
        XCTAssertEqual(service.connectionState, .idle)
        XCTAssertNil(service.lastSentAt)
    }
}
