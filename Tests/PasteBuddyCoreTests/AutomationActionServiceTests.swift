import XCTest
@testable import PasteBuddyCore

@MainActor
final class AutomationActionServiceTests: XCTestCase {
    func testSearchReturnsSummariesWithoutClipboardPayload() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let item = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Launch Plan",
            payload: ClipboardPayload(text: "confidential launch payload")
        ))
        let service = AutomationActionService(store: store)

        let result = try service.searchClipboard(query: "launch")

        XCTAssertEqual(result.items.map(\.id), [item.id])
        XCTAssertEqual(result.items.first?.title, "Launch Plan")
        XCTAssertFalse(result.displaySummary.contains("confidential launch payload"))
    }

    func testSearchUsesRepositoryWithoutMutatingGlobalUIQueryState() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        harness.snapshotStore.storageMode = .standard

        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let repository = ClipboardItemRepository(database: database)
        let item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Repository Automation Match",
            payload: ClipboardPayload(text: "repository automation needle")
        )
        try repository.replaceAll(with: PasteBuddySnapshot(items: [item]))
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository
        )
        store.load()
        store.selectedScope = .pasteStack
        store.searchQuery = "visible UI query"
        let queryRevision = store.queryRevision
        let fetchCount = repository.fetchPageInvocationCount
        let service = AutomationActionService(store: store)

        let result = try service.searchClipboard(query: "automation needle")

        XCTAssertEqual(result.items.map(\.id), [item.id])
        XCTAssertEqual(repository.fetchPageInvocationCount, fetchCount + 1)
        XCTAssertEqual(store.searchQuery, "visible UI query")
        XCTAssertEqual(store.selectedScope, .pasteStack)
        XCTAssertEqual(store.queryRevision, queryRevision)
    }

    func testCreatePinboardActionNormalizesColorAndRejectsEmptyName() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let service = AutomationActionService(store: store)

        XCTAssertThrowsError(try service.createPinboard(name: "   ")) { error in
            XCTAssertEqual(error as? AutomationActionError, .emptyPinboardName)
        }

        let pinboard = try service.createPinboard(name: "Launch Clips", colorHex: "70c1b3")

        XCTAssertEqual(pinboard.name, "Launch Clips")
        XCTAssertEqual(pinboard.colorHex, "#70C1B3")
        XCTAssertEqual(pinboard.itemCount, 0)
        XCTAssertEqual(store.snapshot.pinboards.first(where: { $0.id == pinboard.id })?.name, "Launch Clips")
    }

    func testPinFirstMatchingItemActionSavesResultToNamedPinboard() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let service = AutomationActionService(store: store)
        let pinboard = try service.createPinboard(name: "Research")
        let item = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Test Mac",
            contentType: .url,
            title: "Research Brief",
            payload: ClipboardPayload(urlString: "https://example.com/research")
        ))

        let result = try service.pinFirstMatchingItem(query: "brief", toPinboardNamed: "research")

        XCTAssertEqual(result.item.id, item.id)
        XCTAssertEqual(result.pinboard.id, pinboard.id)
        XCTAssertEqual(result.pinboard.itemCount, 1)
        XCTAssertEqual(store.snapshot.pinboards.first(where: { $0.id == pinboard.id })?.itemIDs, [item.id])
    }

    func testPinFirstMatchingItemActionReportsMissingPinboard() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let service = AutomationActionService(store: store)
        _ = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Meeting Note",
            payload: ClipboardPayload(text: "Pin this later")
        ))

        XCTAssertThrowsError(try service.pinFirstMatchingItem(query: "meeting", toPinboardNamed: "Missing")) { error in
            XCTAssertEqual(error as? AutomationActionError, .pinboardNotFound("Missing"))
        }
    }

    func testFirstMatchingItemSupportsCopyIntentLookup() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let item = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Test Mac",
            contentType: .url,
            title: "Docs",
            payload: ClipboardPayload(urlString: "https://example.com/docs")
        ))
        let service = AutomationActionService(store: store)

        XCTAssertEqual(try service.firstMatchingItem(query: "docs").id, item.id)
        XCTAssertThrowsError(try service.firstMatchingItem(query: "missing")) { error in
            XCTAssertEqual(error as? AutomationActionError, .noMatchingItem)
        }
    }

    func testTransferFirstMatchingItemCopiesWithoutReturningPayload() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let item = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Private Reply",
            payload: ClipboardPayload(text: "secret payload body")
        ))
        let service = AutomationActionService(store: store)
        var transferredItemID: UUID?
        var transferredFormat: PasteFormat?

        let result = try service.transferFirstMatchingItem(
            query: "private",
            format: .plainText,
            destination: .clipboard
        ) { item, format in
            transferredItemID = item.id
            transferredFormat = format
        }

        XCTAssertEqual(transferredItemID, item.id)
        XCTAssertEqual(transferredFormat, .plainText)
        XCTAssertEqual(result.item.id, item.id)
        XCTAssertEqual(result.destination, .clipboard)
        XCTAssertEqual(result.format, .plainText)
        XCTAssertFalse(result.displaySummary.contains("secret payload body"))
    }

    func testLockedHistoryRejectsAutomationItemAccessWithoutInvokingTransfer() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        _ = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Locked Secret",
            payload: ClipboardPayload(text: "must remain inaccessible")
        ))
        let service = AutomationActionService(store: store)
        _ = try service.createPinboard(name: "Private")
        store.setBiometricHistoryLockEnabled(true)
        var transferCallCount = 0

        let operations: [() throws -> Void] = [
            { _ = try service.searchClipboard(query: "locked") },
            { _ = try service.firstMatchingItem(query: "locked") },
            { _ = try service.pinFirstMatchingItem(query: "locked", toPinboardNamed: "Private") },
            {
                _ = try service.transferFirstMatchingItem(query: "locked") { _, _ in
                    transferCallCount += 1
                }
            }
        ]

        for operation in operations {
            XCTAssertThrowsError(try operation()) { error in
                XCTAssertEqual(
                    error.localizedDescription,
                    "Unlock PasteBuddy history before running this action."
                )
            }
        }
        XCTAssertEqual(transferCallCount, 0)
        XCTAssertEqual(
            store.snapshot.pinboards.first(where: { $0.name == "Private" })?.itemIDs,
            []
        )
    }

    func testBlockedPersistenceRejectsAutomationReadsAndMutations() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        try harness.snapshotStore.save(PasteBuddySnapshot())
        try Data("not a valid PasteBuddy store".utf8).write(to: harness.snapshotStore.fileURL)
        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.load()
        let service = AutomationActionService(store: store)

        XCTAssertTrue(store.isPersistenceWriteBlocked)
        XCTAssertThrowsError(try service.searchClipboard(query: "anything")) { error in
            XCTAssertEqual(error as? PasteBuddyPersistenceError, .historyUnavailable)
        }
        XCTAssertThrowsError(try service.createPinboard(name: "Must Not Succeed")) { error in
            XCTAssertEqual(error as? PasteBuddyPersistenceError, .historyUnavailable)
        }
        XCTAssertFalse(store.snapshot.pinboards.contains(where: { $0.name == "Must Not Succeed" }))
    }
}
