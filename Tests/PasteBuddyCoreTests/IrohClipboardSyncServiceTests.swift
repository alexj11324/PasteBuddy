import IrohLib
import Security
import XCTest
@testable import PasteBuddyCore

@MainActor
final class IrohClipboardSyncServiceTests: XCTestCase {
    private enum RetryTransportError: LocalizedError {
        case failed

        var errorDescription: String? { "Slimmed retry transport failed." }
    }

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

    private actor SuspendedStartOperation {
        private var callCount = 0
        private var continuation: CheckedContinuation<Void, Never>?

        func run() async {
            callCount += 1
            await withCheckedContinuation { continuation = $0 }
        }

        func waitUntilStarted() async {
            while callCount == 0 {
                await Task.yield()
            }
        }

        func finish() {
            continuation?.resume()
            continuation = nil
        }

        func calls() -> Int { callCount }
    }

    private actor CompletionRecorder {
        private var count = 0

        func record() { count += 1 }
        func value() -> Int { count }
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

    func testReceiveLoopAwaitsEnvelopeDeliveryInsteadOfSpawningPerFrameTasks() throws {
        let source = try sourceFileContents("Sources/PasteBuddyCore/Services/IrohClipboardSyncService.swift")

        XCTAssertTrue(source.contains("onEnvelopeReceived: @escaping @Sendable (IrohClipboardSyncEnvelope) async -> Void"))
        XCTAssertTrue(source.contains("await onEnvelopeReceived(envelope)"))
        XCTAssertFalse(source.contains("Task { @MainActor in\n                    self?.receive(envelope)"))
    }

    func testWireLengthReadsDoNotAssumePointerAlignment() throws {
        let source = try sourceFileContents("Sources/PasteBuddyCore/Services/IrohClipboardSyncService.swift")

        XCTAssertFalse(source.contains("rawBuffer.load(as: UInt32.self)"))
        XCTAssertEqual(
            source.components(separatedBy: "rawBuffer.loadUnaligned(as: UInt32.self)").count - 1,
            2
        )
    }

    func testWireFormatRejectsUnsupportedEnvelopeVersion() throws {
        let item = ClipboardItem(
            sourceAppName: "Unit Test",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Future envelope",
            payload: ClipboardPayload(text: "unsupported protocol")
        )
        let frame = try IrohClipboardWireFormat.encode(
            IrohClipboardSyncEnvelope(version: 2, item: item)
        )
        let lengthPrefix = Data(frame.prefix(MemoryLayout<UInt32>.size))
        let body = Data(frame.dropFirst(MemoryLayout<UInt32>.size))

        XCTAssertThrowsError(
            try IrohClipboardWireFormat.decode(lengthPrefix: lengthPrefix, body: body)
        )
    }

    func testWireFormatPreflightsObviouslyOversizedInlineBinaryBeforeJSONEncoding() {
        let inlineData = Data(repeating: 0x7A, count: IrohClipboardWireFormat.maxFrameBytes + 1)
        let item = ClipboardItem(
            sourceAppName: "Unit Test",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Oversized binary",
            payload: ClipboardPayload(imageData: inlineData)
        )
        let expectedBase64ByteCount = ((inlineData.count + 2) / 3) * 4

        XCTAssertThrowsError(
            try IrohClipboardWireFormat.encode(IrohClipboardSyncEnvelope(item: item))
        ) { error in
            XCTAssertEqual(
                error as? IrohClipboardSyncError,
                .frameTooLarge(expectedBase64ByteCount)
            )
        }
    }

    func testWireFormatPreflightsObviouslyOversizedInlineTextBeforeJSONEncoding() {
        let inlineText = String(repeating: "x", count: IrohClipboardWireFormat.maxFrameBytes + 1)
        let item = ClipboardItem(
            sourceAppName: "Unit Test",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Oversized text",
            payload: ClipboardPayload(text: inlineText)
        )

        XCTAssertThrowsError(
            try IrohClipboardWireFormat.encode(IrohClipboardSyncEnvelope(item: item))
        ) { error in
            guard case .frameTooLarge(let byteCount) = error as? IrohClipboardSyncError else {
                return XCTFail("Expected frameTooLarge, got \(error)")
            }
            XCTAssertGreaterThan(byteCount, IrohClipboardWireFormat.maxFrameBytes)
        }
    }

    func testWireFormatPreflightsOversizedItemMetadataBeforeJSONEncoding() {
        let oversizedTitle = String(repeating: "m", count: IrohClipboardWireFormat.maxFrameBytes + 1)
        let item = ClipboardItem(
            sourceAppName: "Unit Test",
            deviceName: "Test Mac",
            contentType: .text,
            title: oversizedTitle,
            payload: ClipboardPayload(text: "small payload")
        )

        XCTAssertThrowsError(
            try IrohClipboardWireFormat.encode(IrohClipboardSyncEnvelope(item: item))
        ) { error in
            guard case .frameTooLarge(let byteCount) = error as? IrohClipboardSyncError else {
                return XCTFail("Expected frameTooLarge, got \(error)")
            }
            XCTAssertGreaterThan(byteCount, IrohClipboardWireFormat.maxFrameBytes)
        }
    }

    func testWireFormatPreflightsCombinedInlineFieldsBeforeJSONEncoding() {
        let fieldSize = 5 * 1_024 * 1_024
        let text = String(repeating: "t", count: fieldSize)
        let html = String(repeating: "h", count: fieldSize)
        let item = ClipboardItem(
            sourceAppName: "Unit Test",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Combined oversized fields",
            payload: ClipboardPayload(text: text, htmlString: html)
        )

        XCTAssertThrowsError(
            try IrohClipboardWireFormat.encode(IrohClipboardSyncEnvelope(item: item))
        ) { error in
            guard case .frameTooLarge(let byteCount) = error as? IrohClipboardSyncError else {
                return XCTFail("Expected frameTooLarge, got \(error)")
            }
            XCTAssertGreaterThan(byteCount, IrohClipboardWireFormat.maxFrameBytes)
        }
    }

    func testPairingURLRoundTripsEndpointId() throws {
        let endpointId = "abcdef123456"
        let url = try XCTUnwrap(IrohClipboardSyncService.pairingURL(endpointId: endpointId))

        XCTAssertEqual(try IrohClipboardSyncService.peerEndpointId(fromPairingCode: url.absoluteString), endpointId)
        XCTAssertThrowsError(try IrohClipboardSyncService.peerEndpointId(fromPairingCode: "https://example.com/?endpoint=\(endpointId)")) { error in
            XCTAssertEqual(error as? IrohClipboardSyncError, .invalidPairingCode)
        }
    }

    func testConfiguredIncomingPeerRequiresCanonicalMatchWithoutReplacingConfiguration() {
        let defaultsSuite = "PasteBuddyIrohPeerMatch-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let expectedPeer = SecretKey.generate().public().description
        let unexpectedPeer = SecretKey.generate().public().description
        let service = IrohClipboardSyncService(defaults: defaults)
        service.peerEndpointId = "  \(expectedPeer)\n"

        XCTAssertTrue(service.authorizeIncomingPeer(expectedPeer))
        XCTAssertEqual(service.peerEndpointId, expectedPeer)
        XCTAssertFalse(service.authorizeIncomingPeer(unexpectedPeer))
        XCTAssertEqual(service.peerEndpointId, expectedPeer)
    }

    func testFirstIncomingPeerPinsCanonicalEndpointWhenNoPeerIsConfigured() {
        let defaultsSuite = "PasteBuddyIrohPeerTOFU-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let peer = SecretKey.generate().public().description
        let service = IrohClipboardSyncService(defaults: defaults)

        XCTAssertTrue(service.authorizeIncomingPeer("  \(peer)\n"))
        XCTAssertEqual(service.peerEndpointId, peer)
    }

    func testClosingReplacedSessionDoesNotClearCurrentSessionToken() {
        var state = IrohClipboardSessionState()
        let replacedToken = state.beginSession()
        let currentToken = state.beginSession()

        XCTAssertFalse(state.closeSession(token: replacedToken))
        XCTAssertEqual(state.currentToken, currentToken)
        XCTAssertTrue(state.closeSession(token: currentToken))
        XCTAssertNil(state.currentToken)
    }

    func testConcurrentStartsShareAndAwaitOneBindingOperation() async {
        let gate = IrohClipboardStartGate()
        let operation = SuspendedStartOperation()
        let completions = CompletionRecorder()
        let first = Task { @MainActor in
            await gate.run { await operation.run() }
            await completions.record()
        }
        await operation.waitUntilStarted()
        let second = Task { @MainActor in
            await gate.run { await operation.run() }
            await completions.record()
        }
        await Task.yield()

        let callsBeforeRelease = await operation.calls()
        let completionsBeforeRelease = await completions.value()
        XCTAssertEqual(callsBeforeRelease, 1)
        XCTAssertEqual(completionsBeforeRelease, 0)

        await operation.finish()
        await first.value
        await second.value
        let completionsAfterRelease = await completions.value()
        XCTAssertEqual(completionsAfterRelease, 2)
    }

    func testIdentityStoreBaseQueryIncludesOptionalAccessGroup() {
        let accessGroup = "TEAMID.com.alexjiang.PasteBuddy.shared"
        let sharedStore = IrohClipboardIdentityStore(
            service: "com.alexjiang.PasteBuddy.tests.iroh",
            account: "shared",
            accessGroup: accessGroup
        )
        let unsharedStore = IrohClipboardIdentityStore(
            service: "com.alexjiang.PasteBuddy.tests.iroh",
            account: "local"
        )

        XCTAssertEqual(sharedStore.baseQuery()[kSecAttrAccessGroup as String] as? String, accessGroup)
        XCTAssertNil(unsharedStore.baseQuery()[kSecAttrAccessGroup as String])
    }

    func testIdentityStoreSourceMigratesLegacyIdentityWithoutDeletingThroughAnUnscopedQuery() throws {
        let source = try sourceFileContents("Sources/PasteBuddyCore/Services/IrohClipboardSyncService.swift")

        XCTAssertTrue(source.contains("legacyBaseQuery"))
        XCTAssertTrue(source.contains("loadDuplicateWinner"))
        XCTAssertFalse(source.contains("deleteLegacyIdentity"))
        XCTAssertFalse(source.contains("SecItemUpdate"))
    }

    func testSharedIdentityStoreMigratesLegacyNoGroupIdentityWithoutChangingEndpoint() throws {
        let legacySecretKey = SecretKey.generate()
        let accessGroup = "TEAMID.com.alexjiang.PasteBuddy.shared"
        let keychain = IrohClipboardKeychainHarness(
            legacyData: legacySecretKey.toBytes()
        )
        let store = IrohClipboardIdentityStore(
            service: "com.alexjiang.PasteBuddy.tests.iroh.migration",
            account: "identity",
            accessGroup: accessGroup,
            keychainClient: keychain.client
        )

        let identity = try store.loadOrCreate()

        XCTAssertEqual(identity.endpointId, legacySecretKey.public().description)
        XCTAssertEqual(keychain.data(accessGroup: accessGroup), legacySecretKey.toBytes())
        XCTAssertEqual(
            keychain.data(accessGroup: nil),
            legacySecretKey.toBytes(),
            "An unscoped Keychain delete can also match the newly inserted shared-group winner"
        )
    }

    func testConcurrentIdentityCreationReturnsStoredWinnerAfterDuplicateAdd() async throws {
        let keychain = IrohClipboardKeychainHarness(initialReadMissCount: 2)
        let store = IrohClipboardIdentityStore(
            service: "com.alexjiang.PasteBuddy.tests.iroh.race",
            account: "identity",
            accessGroup: nil,
            keychainClient: keychain.client
        )

        let first = Task.detached { try store.loadOrCreate() }
        let second = Task.detached { try store.loadOrCreate() }
        let firstIdentity = try await first.value
        let secondIdentity = try await second.value
        let storedData = try XCTUnwrap(keychain.data(accessGroup: nil))
        let storedSecretKey = try SecretKey.fromBytes(bytes: storedData)

        XCTAssertEqual(firstIdentity.endpointId, secondIdentity.endpointId)
        XCTAssertEqual(firstIdentity.endpointId, storedSecretKey.public().description)
        XCTAssertEqual(keychain.addAttemptCount, 2)
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

    func testSendDoesNotRetryOversizedTextWhenThereIsNoBinaryPayloadToSlim() async {
        let defaultsSuite = "PasteBuddyIrohNoPointlessRetry-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let service = IrohClipboardSyncService(defaults: defaults)
        let item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Oversized Text",
            payload: ClipboardPayload(text: "text cannot be slimmed")
        )
        let recorder = EnvelopeAttemptRecorder()

        let result = await service.send(item) { envelope in
            _ = await recorder.record(envelope)
            throw IrohClipboardSyncError.frameTooLarge(IrohClipboardWireFormat.maxFrameBytes + 1)
        }

        XCTAssertFalse(result)
        let attemptCount = await recorder.snapshot().count
        XCTAssertEqual(attemptCount, 1)
    }

    func testSendMarksConnectionFailedWhenSlimmedRetryStillFails() async {
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
        XCTAssertEqual(
            service.connectionState,
            .failed(IrohClipboardSyncError.frameTooLarge(IrohClipboardWireFormat.maxFrameBytes + 1).localizedDescription)
        )
        XCTAssertNil(service.lastSentAt)
    }

    func testSendRecordsGenericSlimmedRetryErrorInsteadOfOriginalFrameTooLarge() async {
        let defaultsSuite = "PasteBuddyIrohRetryGenericFail-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let service = IrohClipboardSyncService(
            defaults: defaults,
            identityStore: IrohClipboardIdentityStore(
                service: "com.alexjiang.PasteBuddy.tests.iroh.\(UUID().uuidString)",
                account: "retry-generic-fail"
            )
        )
        let item = ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .mixed,
            title: "Oversized Share",
            payload: ClipboardPayload(text: "fallback", imageData: Data([0x7A]))
        )
        let recorder = EnvelopeAttemptRecorder()

        let result = await service.send(item) { envelope in
            let attemptNumber = await recorder.record(envelope)
            if attemptNumber == 1 {
                throw IrohClipboardSyncError.frameTooLarge(IrohClipboardWireFormat.maxFrameBytes + 1)
            }
            throw RetryTransportError.failed
        }

        XCTAssertFalse(result)
        XCTAssertEqual(service.connectionState, .failed("Slimmed retry transport failed."))
        XCTAssertNil(service.lastSentAt)
    }

    private func sourceFileContents(_ relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return String(decoding: try Data(contentsOf: candidate), as: UTF8.self)
            }
            directory.deleteLastPathComponent()
        }
        throw XCTSkip("Could not locate \(relativePath) from \(FileManager.default.currentDirectoryPath)")
    }
}

private final class IrohClipboardKeychainHarness: @unchecked Sendable {
    private static let legacyKey = "<legacy>"

    private let lock = NSLock()
    private var storedData: [String: Data]
    private var remainingInitialReadMisses: Int
    private var storedAddAttemptCount = 0

    init(legacyData: Data? = nil, initialReadMissCount: Int = 0) {
        storedData = legacyData.map { [Self.legacyKey: $0] } ?? [:]
        remainingInitialReadMisses = initialReadMissCount
    }

    var client: IrohClipboardKeychainClient {
        IrohClipboardKeychainClient(
            copyMatching: { [self] query in copyMatching(query) },
            add: { [self] query in add(query) }
        )
    }

    var addAttemptCount: Int {
        lock.withLock { storedAddAttemptCount }
    }

    func data(accessGroup: String?) -> Data? {
        lock.withLock { storedData[accessGroup ?? Self.legacyKey] }
    }

    private func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        lock.withLock {
            if remainingInitialReadMisses > 0 {
                remainingInitialReadMisses -= 1
                return (errSecItemNotFound, nil)
            }
            guard let data = storedData[key(for: query)] else {
                return (errSecItemNotFound, nil)
            }
            return (errSecSuccess, data)
        }
    }

    private func add(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            storedAddAttemptCount += 1
            let key = key(for: query)
            guard storedData[key] == nil else { return errSecDuplicateItem }
            guard let data = query[kSecValueData as String] as? Data else { return errSecParam }
            storedData[key] = data
            return errSecSuccess
        }
    }

    private func key(for query: [String: Any]) -> String {
        query[kSecAttrAccessGroup as String] as? String ?? Self.legacyKey
    }
}
