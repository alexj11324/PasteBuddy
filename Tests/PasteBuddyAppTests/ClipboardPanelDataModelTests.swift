import PasteBuddyCore
import XCTest
@testable import PasteBuddy

@MainActor
final class ClipboardPanelDataModelTests: XCTestCase {
    func testCancelPreventsSuspendedRefreshFromApplying() async throws {
        let harness = try PanelModelHarness(items: [makeItem("one")])
        defer { harness.cleanup() }
        let gate = PanelPageApplicationGate(blockedCall: 1)
        let model = ClipboardPanelDataModel(store: harness.store, pageSize: 1)
        model.beforeApplyingPageForTesting = { _, _ in await gate.arrive() }

        model.refresh()
        await gate.waitUntilBlocked()
        model.cancel()
        await gate.release()
        await settleTasks()

        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.isRefreshing)
        XCTAssertFalse(model.isLoadingNextPage)
    }

    func testRapidQueryChangeRejectsOlderResult() async throws {
        let old = makeItem("old result")
        let new = makeItem("new result")
        let harness = try PanelModelHarness(items: [old, new])
        defer { harness.cleanup() }
        harness.store.searchQuery = "old"
        let gate = PanelPageApplicationGate(blockedCall: 1)
        let model = ClipboardPanelDataModel(store: harness.store, pageSize: 10)
        model.beforeApplyingPageForTesting = { _, _ in await gate.arrive() }

        model.refresh()
        await gate.waitUntilBlocked()
        harness.store.searchQuery = "new"
        model.refresh()
        await waitUntilIdle(model)

        XCTAssertEqual(model.items.map(\.id), [new.id])

        await gate.release()
        await settleTasks()
        XCTAssertEqual(model.items.map(\.id), [new.id])
    }

    func testDuplicateLoadMoreRequestsCoalesce() async throws {
        let harness = try PanelModelHarness(items: [makeItem("one"), makeItem("two")])
        defer { harness.cleanup() }
        let model = ClipboardPanelDataModel(store: harness.store, pageSize: 1)
        model.refresh()
        await waitUntilIdle(model)
        let gate = PanelPageApplicationGate(blockedCall: 1)
        model.beforeApplyingPageForTesting = { _, offset in
            if offset > 0 { await gate.arrive() }
        }

        model.loadNextPage()
        model.loadNextPage()
        await gate.waitUntilBlocked()

        XCTAssertEqual(model.pageRequestCountForTesting, 2)
        XCTAssertTrue(model.isLoadingNextPage)

        await gate.release()
        await waitUntilIdle(model)
        XCTAssertEqual(model.items.count, 2)
    }

    func testDuplicateIDsAreRejectedWithoutStallingPagination() async throws {
        let first = makeItem("one")
        let final = makeItem("two")
        let harness = try PanelModelHarness(items: [first, first, final])
        defer { harness.cleanup() }
        let model = ClipboardPanelDataModel(store: harness.store, pageSize: 1)

        model.refresh()
        await waitUntilIdle(model)
        model.loadNextPage()
        await waitUntilIdle(model)

        XCTAssertEqual(model.items.map(\.id), [first.id])
        XCTAssertTrue(model.canLoadNextPage)

        model.loadNextPage()
        await waitUntilIdle(model)
        XCTAssertEqual(model.items.map(\.id), [first.id, final.id])
    }

    func testScopeBrowsingIsLocalAndIndependentWithoutBumpingStoreQueryRevision() async throws {
        let harness = try PanelModelHarness(items: [makeItem("one")])
        defer { harness.cleanup() }
        let shelfModel = ClipboardPanelDataModel(store: harness.store, pageSize: 1)
        let sideModel = ClipboardPanelDataModel(store: harness.store, pageSize: 1)
        let originalScope = harness.store.selectedScope
        let originalQueryRevision = harness.store.queryRevision

        shelfModel.refresh(scope: .pasteStack)
        await waitUntilIdle(shelfModel)

        XCTAssertEqual(shelfModel.scope, .pasteStack)
        XCTAssertEqual(sideModel.scope, originalScope)
        XCTAssertEqual(harness.store.selectedScope, originalScope)
        XCTAssertEqual(harness.store.queryRevision, originalQueryRevision)
    }

    private func waitUntilIdle(
        _ model: ClipboardPanelDataModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<2_000 {
            if !model.isRefreshing && !model.isLoadingNextPage { return }
            await Task.yield()
        }
        XCTFail("Clipboard panel model did not become idle.", file: file, line: line)
    }

    private func settleTasks() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func makeItem(_ text: String) -> ClipboardItem {
        ClipboardItem(
            sourceAppName: "Tests",
            deviceName: "Test Mac",
            contentType: .text,
            title: text,
            payload: ClipboardPayload(text: text)
        )
    }
}

@MainActor
private final class PanelModelHarness {
    let directory: URL
    let store: PasteBuddyStore

    init(items: [ClipboardItem]) throws {
        directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("PasteBuddyPanelModelTests-\(UUID().uuidString)", isDirectory: true)
        let diskStore = EncryptedSnapshotStore(
            fileURL: directory.appendingPathComponent("clipboard.pbstore"),
            storageMode: .standard
        )
        store = PasteBuddyStore(diskStore: diskStore)
        store.snapshot.items = items
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor PanelPageApplicationGate {
    private let blockedCall: Int
    private var callCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    init(blockedCall: Int) {
        self.blockedCall = blockedCall
    }

    func arrive() async {
        callCount += 1
        guard callCount == blockedCall else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilBlocked() async {
        while continuation == nil { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
