#if os(macOS)
import AppKit
import XCTest
@testable import PasteBuddyCore

@MainActor
final class ClipboardMonitorTests: XCTestCase {
    private final class SlowPasteboardDataProvider: NSObject, NSPasteboardItemDataProvider {
        func pasteboard(
            _ pasteboard: NSPasteboard?,
            item: NSPasteboardItem,
            provideDataForType type: NSPasteboard.PasteboardType
        ) {
            Thread.sleep(forTimeInterval: 0.4)
            item.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: type)
        }
    }

    private actor CaptureCallCounter {
        private var count = 0

        func next() -> Int {
            count += 1
            return count
        }

        func calls() -> Int { count }
    }

    private actor SuspendedCaptureFactory {
        private var callCount = 0
        private var isReleased = false
        private var continuation: CheckedContinuation<Void, Never>?

        func makeItem() async -> ClipboardItem? {
            callCount += 1
            let callNumber = callCount
            if !isReleased {
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                }
            }
            return ClipboardItem(
                sourceAppName: "Preview",
                deviceName: "Test Mac",
                contentType: .text,
                title: "Queued Capture \(callNumber)",
                payload: ClipboardPayload(text: "queued capture \(callNumber)")
            )
        }

        func release() {
            isReleased = true
            continuation?.resume()
            continuation = nil
        }

        func calls() -> Int { callCount }
    }

    private actor PrefixCaptureFactory {
        private let suspendedCall: Int
        private var callCount = 0
        private var continuation: CheckedContinuation<Void, Never>?

        init(suspendedCall: Int) {
            self.suspendedCall = suspendedCall
        }

        func makeItem() async -> ClipboardItem? {
            callCount += 1
            if callCount == suspendedCall {
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                }
            }
            return nil
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }

        func calls() -> Int { callCount }
    }

    override func setUp() async throws {
        try await super.setUp()
        ClipboardLinkMetadataFetcher.resetFetchStateForTesting()
    }

    override func tearDown() async throws {
        ClipboardLinkMetadataFetcher.fetchOverrideForTesting = nil
        ClipboardLinkMetadataFetcher.resetFetchStateForTesting()
        try await super.tearDown()
    }

    func testPollOnceDoesNotBlockMainActorWhilePasteboardSnapshotIsRead() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        let pasteboard = NSPasteboard(name: .init("PasteBuddySlowRead-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardMonitor(
            store: PasteBuddyStore(diskStore: harness.snapshotStore),
            pasteboard: pasteboard
        )
        try await prime(monitor)
        let provider = SlowPasteboardDataProvider()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.png])
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let clock = ContinuousClock()

        let elapsed = clock.measure {
            monitor.pollOnce()
        }

        XCTAssertLessThan(
            elapsed,
            .milliseconds(150),
            "Pasteboard XPC and payload reads must not block the main actor."
        )
        try await Task.sleep(for: .milliseconds(450))
        monitor.stop()
    }

    func testPausedClipboardChangesAreDiscardedBeforeCaptureResumes() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.snapshot.privacy.excludedApplicationNames = []
        store.snapshot.privacy.excludedBundleIdentifiers = []
        let pasteboard = NSPasteboard(name: .init("PasteBuddyPausedBaseline-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
        try await prime(monitor)

        store.pauseCaptureIndefinitely()
        pasteboard.clearContents()
        pasteboard.setString("must stay discarded", forType: .string)
        monitor.pollOnce()
        try await waitUntil { monitor.lastChangeCountForTesting == pasteboard.changeCount }

        store.resumeCapture()
        monitor.pollOnce()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(store.snapshot.items.isEmpty)

        pasteboard.clearContents()
        pasteboard.setString("capture after resume", forType: .string)
        monitor.pollOnce()
        try await waitUntil { store.snapshot.items.count == 1 }
        XCTAssertEqual(store.snapshot.items.first?.payload.text, "capture after resume")
    }

    func testPausingWhileSlowPasteboardReadIsInFlightPreventsCommit() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.snapshot.privacy.excludedApplicationNames = []
        store.snapshot.privacy.excludedBundleIdentifiers = []
        let pasteboard = NSPasteboard(name: .init("PasteBuddyPauseRace-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
        try await prime(monitor)
        let provider = SlowPasteboardDataProvider()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.png])
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))

        monitor.pollOnce()
        store.pauseCaptureIndefinitely()
        try await Task.sleep(for: .milliseconds(550))

        XCTAssertTrue(store.snapshot.items.isEmpty)
        monitor.stop()
    }

    func testLinkMetadataFailuresRetryWhileConcurrentRequestsShareOneFetch() async {
        let urlString = "https://metadata-retry.example/preview"
        let counter = CaptureCallCounter()
        ClipboardLinkMetadataFetcher.fetchOverrideForTesting = { _ in
            let call = await counter.next()
            try? await Task.sleep(nanoseconds: 50_000_000)
            return call == 1
                ? nil
                : ClipboardLinkPreviewMetadata(title: "Recovered preview")
        }

        async let first = ClipboardLinkMetadataFetcher.fetch(for: urlString)
        async let second = ClipboardLinkMetadataFetcher.fetch(for: urlString)
        let concurrentResults = await [first, second]
        let callsAfterConcurrentFetch = await counter.calls()

        XCTAssertTrue(concurrentResults.allSatisfy { $0 == nil })
        XCTAssertEqual(callsAfterConcurrentFetch, 1, "Concurrent requests for one URL must share one metadata fetch")

        let retry = await ClipboardLinkMetadataFetcher.fetch(for: urlString)
        let callsAfterRetry = await counter.calls()

        XCTAssertEqual(retry?.title, "Recovered preview")
        XCTAssertEqual(callsAfterRetry, 2, "A transient failure must not suppress the next preview attempt")
    }

    func testCapturedURLItemIsStoredWithoutWaitingForLinkMetadata() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PasteBuddyMonitorTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
        try await prime(monitor)

        pasteboard.clearContents()
        // TEST-NET-1 (RFC 5737) is guaranteed unroutable, so any link-metadata
        // fetch on the capture path hangs instead of finishing quickly.
        pasteboard.setString("https://192.0.2.1/pastebuddy-latency-probe", forType: .string)

        monitor.pollOnce()

        let deadline = Date().addingTimeInterval(2)
        while store.snapshot.items.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(store.snapshot.items.count, 1, "URL capture must not wait for link metadata")
        XCTAssertEqual(store.snapshot.items.first?.contentType, .url)
        XCTAssertEqual(store.snapshot.items.first?.payload.urlString, "https://192.0.2.1/pastebuddy-latency-probe")
    }

    func testRecopyingSameTextBumpsExistingItemInsteadOfDuplicating() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PasteBuddyMonitorTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
        try await prime(monitor)

        pasteboard.clearContents()
        pasteboard.setString("repeated clipboard payload", forType: .string)
        monitor.pollOnce()
        try await waitUntil { store.snapshot.items.count == 1 }
        let firstCapture = try XCTUnwrap(store.snapshot.items.first)

        // A fresh declareTypes/setString cycle bumps changeCount just like a real re-copy.
        pasteboard.clearContents()
        pasteboard.setString("repeated clipboard payload", forType: .string)
        monitor.pollOnce()
        try await waitUntil {
            store.snapshot.items.count == 1 && store.snapshot.items[0].updatedAt > firstCapture.updatedAt
        }

        XCTAssertEqual(store.snapshot.items.count, 1, "Re-copying identical content must dedupe, not duplicate")
        XCTAssertEqual(store.snapshot.items.first?.id, firstCapture.id)
    }

    func testPasteBuddyPasteboardWritesAreNotCapturedAsUserRecopies() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PasteBuddyInternalWrite-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
        try await prime(monitor)
        let item = ClipboardItem(
            sourceAppName: "PasteBuddy",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Existing history item",
            payload: ClipboardPayload(text: "must not be recaptured")
        )

        PasteboardWriter.copy(item, to: pasteboard)
        monitor.pollOnce()
        try await waitUntil { monitor.lastChangeCountForTesting == pasteboard.changeCount }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(store.snapshot.items.isEmpty)
    }

    func testDistinctSlowCapturesSerializeInsteadOfDroppingEarlierCopy() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PasteBuddyMonitorTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
        try await prime(monitor)

        let counter = CaptureCallCounter()
        ClipboardMonitor.makeItemOverrideForTesting = {
            let callCount = await counter.next()
            if callCount == 1 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                return ClipboardItem(
                    sourceAppName: "Preview",
                    deviceName: "Test Mac",
                    contentType: .image,
                    title: "First Screenshot",
                    payload: ClipboardPayload(imageData: Data([0x01])),
                    ocrState: .notNeeded
                )
            }
            return ClipboardItem(
                sourceAppName: "Preview",
                deviceName: "Test Mac",
                contentType: .image,
                title: "Second Screenshot",
                payload: ClipboardPayload(imageData: Data([0x02])),
                ocrState: .notNeeded
            )
        }
        defer { ClipboardMonitor.makeItemOverrideForTesting = nil }

        pasteboard.clearContents()
        pasteboard.setString("first", forType: .string)
        monitor.pollOnce()

        let firstReadDeadline = Date().addingTimeInterval(1)
        while await counter.calls() == 0, Date() < firstReadDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let firstReadCount = await counter.calls()
        XCTAssertEqual(firstReadCount, 1)

        pasteboard.clearContents()
        pasteboard.setString("second", forType: .string)
        monitor.pollOnce()

        try await waitUntil(timeout: 2) {
            store.snapshot.items.count == 2
        }

        XCTAssertEqual(store.snapshot.items.map(\.title), ["Second Screenshot", "First Screenshot"])
    }

    func testStopCancelsInFlightCaptureAndDropsAllQueuedEvents() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.snapshot.privacy.excludedApplicationNames = []
        store.snapshot.privacy.excludedBundleIdentifiers = []
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PasteBuddyMonitorTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
        try await prime(monitor)
        let captures = SuspendedCaptureFactory()
        ClipboardMonitor.makeItemOverrideForTesting = {
            await captures.makeItem()
        }
        defer { ClipboardMonitor.makeItemOverrideForTesting = nil }

        pasteboard.clearContents()
        pasteboard.setString("first", forType: .string)
        monitor.pollOnce()

        let startDeadline = Date().addingTimeInterval(1)
        while await captures.calls() == 0, Date() < startDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let callsBeforeQueueing = await captures.calls()
        XCTAssertEqual(callsBeforeQueueing, 1, "The first capture must be in flight before later events are queued")
        guard callsBeforeQueueing == 1 else { return }

        for value in ["second", "third"] {
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
            monitor.pollOnce()
        }

        monitor.stop()
        await captures.release()
        try await Task.sleep(nanoseconds: 200_000_000)

        let captureCalls = await captures.calls()
        XCTAssertEqual(captureCalls, 1, "Queued events must share one cancellable serial worker")
        XCTAssertTrue(store.snapshot.items.isEmpty, "Stopping must prevent every pre-stop capture from being saved")
    }

    func testSerialCaptureWorkerReleasesProcessedSnapshotsWhileBacklogRemains() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.snapshot.privacy.excludedApplicationNames = []
        store.snapshot.privacy.excludedBundleIdentifiers = []
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PasteBuddyMonitorBufferTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
        try await prime(monitor)
        let captures = PrefixCaptureFactory(suspendedCall: 81)
        ClipboardMonitor.makeItemOverrideForTesting = {
            await captures.makeItem()
        }
        defer { ClipboardMonitor.makeItemOverrideForTesting = nil }

        for index in 0..<100 {
            pasteboard.clearContents()
            pasteboard.setString("queued \(index)", forType: .string)
            monitor.pollOnce()

            let readDeadline = Date().addingTimeInterval(1)
            if index <= 80 {
                while await captures.calls() < index + 1, Date() < readDeadline {
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
            } else {
                let expectedRetainedCount = index - 79
                while monitor.retainedCaptureCountForTesting < expectedRetainedCount,
                      Date() < readDeadline {
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
            }
        }

        let deadline = Date().addingTimeInterval(2)
        while await captures.calls() < 81, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let captureCallCount = await captures.calls()
        XCTAssertEqual(captureCallCount, 81)
        XCTAssertLessThanOrEqual(
            monitor.pendingCaptureBufferSlotCountForTesting,
            36,
            "Processed image snapshots must not remain retained behind a suspended queue item."
        )

        monitor.stop()
        await captures.release()
    }

    func testCaptureBacklogRetainsAtMostBoundedNumberOfPasteboardSnapshots() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.snapshot.privacy.excludedApplicationNames = []
        store.snapshot.privacy.excludedBundleIdentifiers = []
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PasteBuddyMonitorBackpressureTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
        try await prime(monitor)
        let captures = SuspendedCaptureFactory()
        ClipboardMonitor.makeItemOverrideForTesting = {
            await captures.makeItem()
        }
        defer { ClipboardMonitor.makeItemOverrideForTesting = nil }

        pasteboard.clearContents()
        pasteboard.setString("in flight", forType: .string)
        monitor.pollOnce()
        let startDeadline = Date().addingTimeInterval(1)
        while await captures.calls() == 0, Date() < startDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let didStartCapture = await captures.calls() == 1
        XCTAssertTrue(didStartCapture)
        guard didStartCapture else { return }

        for index in 0..<128 {
            pasteboard.clearContents()
            pasteboard.setString("queued \(index)", forType: .string)
            monitor.pollOnce()

            let expectedRetainedCount = min(index + 2, 128)
            let readDeadline = Date().addingTimeInterval(1)
            while (monitor.retainedCaptureCountForTesting < expectedRetainedCount
                    || (index == 127 && store.lastErrorMessage == nil)),
                  Date() < readDeadline {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
        }

        XCTAssertLessThanOrEqual(monitor.retainedCaptureCountForTesting, 128)
        XCTAssertEqual(
            store.lastErrorMessage,
            "Clipboard capture paused briefly because incoming content exceeded the safe memory budget."
        )

        monitor.stop()
        await captures.release()
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func prime(_ monitor: ClipboardMonitor) async throws {
        XCTAssertNil(monitor.lastChangeCountForTesting)
        monitor.pollOnce()
        try await waitUntil { monitor.lastChangeCountForTesting != nil }
    }
}
#endif
