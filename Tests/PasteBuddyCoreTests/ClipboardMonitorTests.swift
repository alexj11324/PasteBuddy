#if os(macOS)
import AppKit
import XCTest
@testable import PasteBuddyCore

@MainActor
final class ClipboardMonitorTests: XCTestCase {
    private actor CaptureCallCounter {
        private var count = 0

        func next() -> Int {
            count += 1
            return count
        }

        func calls() -> Int {
            count
        }
    }

    override func tearDown() async throws {
        ClipboardLinkMetadataFetcher.fetchOverrideForTesting = nil
        ClipboardLinkMetadataFetcher.resetFetchStateForTesting()
        try await super.tearDown()
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
        async let third = ClipboardLinkMetadataFetcher.fetch(for: urlString)
        let concurrentResults = await [first, second, third]

        XCTAssertTrue(concurrentResults.allSatisfy { $0 == nil })
        let callsAfterConcurrentFetch = await counter.calls()
        XCTAssertEqual(callsAfterConcurrentFetch, 1)

        let retry = await ClipboardLinkMetadataFetcher.fetch(for: urlString)
        let callsAfterRetry = await counter.calls()

        XCTAssertEqual(retry?.title, "Recovered preview")
        XCTAssertEqual(callsAfterRetry, 2)
    }

    func testCapturedURLItemIsStoredWithoutWaitingForLinkMetadata() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PasteBuddyMonitorTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)

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

    func testCopiedImageStillCreatesImageHistoryItemWithOCRPending() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PasteBuddyMonitorTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 4,
            bitsPerPixel: 32
        )
        let png = try XCTUnwrap(bitmap?.representation(using: .png, properties: [:]))
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)

        let item = try XCTUnwrap(ClipboardMonitor.makeItem(
            from: pasteboard,
            sourceApp: "Preview",
            sourceBundleIdentifier: "com.apple.Preview",
            privacy: PrivacyConfiguration()
        ))

        XCTAssertEqual(item.contentType, .image)
        XCTAssertEqual(item.title, "Image")
        XCTAssertEqual(item.payload.imageData, png)
        XCTAssertTrue(item.ocrState.isPending)
    }

    func testPasteBuddyCopyDoesNotInvalidateRepositoryBackedHistory() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let database = try PasteBuddyDatabase(
            fileURL: harness.directory.appendingPathComponent("clipboard.sqlite")
        )
        let repository = ClipboardItemRepository(database: database)
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository,
            saveDebounceNanoseconds: 60_000_000_000
        )
        let item = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Existing history card",
            payload: ClipboardPayload(text: "copy without invalidating history")
        ))
        await store.flushPendingSave()
        store.markHistoryUnlockedForTesting()

        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("PasteBuddyMonitorTests-\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
        let readyRevision = store.dataRevision
        ClipboardMonitor.makeItemOverrideForTesting = { item }
        defer { ClipboardMonitor.makeItemOverrideForTesting = nil }

        XCTAssertEqual(store.filteredItemsPage(for: .history, offset: 0).map(\.id), [item.id])
        XCTAssertTrue(PasteboardWriter.copy(item, to: pasteboard))
        XCTAssertEqual(store.dataRevision, readyRevision)
        XCTAssertEqual(store.filteredItemsPage(for: .history, offset: 0).map(\.id), [item.id])
        monitor.pollOnce()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(store.dataRevision, readyRevision)
        XCTAssertEqual(store.repositorySyncedDataRevision, readyRevision)
        XCTAssertNil(store.historyQueryErrorMessage)
        XCTAssertEqual(store.filteredItemsPage(for: .history, offset: 0).map(\.id), [item.id])
    }

    func testDistinctSlowCapturesSerializeInsteadOfDroppingEarlierCopy() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PasteBuddyMonitorTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)

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

        pasteboard.clearContents()
        pasteboard.setString("second", forType: .string)
        monitor.pollOnce()

        try await waitUntil(timeout: 2) {
            store.snapshot.items.count == 2
        }

        XCTAssertEqual(store.snapshot.items.map(\.title), ["Second Screenshot", "First Screenshot"])
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
}
#endif
