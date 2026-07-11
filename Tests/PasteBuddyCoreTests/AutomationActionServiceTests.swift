import XCTest
@testable import PasteBuddyCore

@MainActor
final class AutomationActionServiceTests: XCTestCase {
    func testSearchReturnsSummariesWithoutClipboardPayload() async throws {
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

        let result = try await service.searchClipboard(query: "launch")

        XCTAssertEqual(result.items.map(\.id), [item.id])
        XCTAssertEqual(result.items.first?.title, "Launch Plan")
        XCTAssertFalse(result.displaySummary.contains("confidential launch payload"))
    }

    func testSearchUsesRepositoryWithoutMutatingGlobalUIQueryState() async throws {
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

        let result = try await service.searchClipboard(query: "automation needle")

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

    func testPinFirstMatchingItemActionSavesResultToNamedPinboard() async throws {
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

        let result = try await service.pinFirstMatchingItem(query: "brief", toPinboardNamed: "research")

        XCTAssertEqual(result.item.id, item.id)
        XCTAssertEqual(result.pinboard.id, pinboard.id)
        XCTAssertEqual(result.pinboard.itemCount, 1)
        XCTAssertEqual(store.snapshot.pinboards.first(where: { $0.id == pinboard.id })?.itemIDs, [item.id])
    }

    func testPinFirstMatchingItemActionReportsMissingPinboard() async throws {
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

        do {
            _ = try await service.pinFirstMatchingItem(query: "meeting", toPinboardNamed: "Missing")
            XCTFail("Expected missing pinboard error.")
        } catch {
            XCTAssertEqual(error as? AutomationActionError, .pinboardNotFound("Missing"))
        }
    }

    func testFirstMatchingItemSupportsCopyIntentLookup() async throws {
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

        let matchingItem = try await service.firstMatchingItem(query: "docs")
        XCTAssertEqual(matchingItem.id, item.id)
        do {
            _ = try await service.firstMatchingItem(query: "missing")
            XCTFail("Expected no matching item error.")
        } catch {
            XCTAssertEqual(error as? AutomationActionError, .noMatchingItem)
        }
    }

    func testTransferFirstMatchingItemCopiesWithoutReturningPayload() async throws {
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

        let result = try await service.transferFirstMatchingItem(
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

    func testSuspendedTransferFailsClosedWhenHistoryLocksBeforeSearchReturns() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        harness.snapshotStore.storageMode = .standard

        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let repository = ClipboardItemRepository(database: database)
        let item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Lock During Search",
            payload: ClipboardPayload(text: "lock race needle")
        )
        try repository.replaceAll(with: PasteBuddySnapshot(items: [item]))
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository
        )
        store.load()
        let service = AutomationActionService(store: store)
        let gate = RepositorySearchSuspensionGate()
        repository.beforeReturningAsyncFetchPageForTesting = {
            await gate.suspendIfNeeded()
        }
        var transferCallCount = 0

        let transferTask = Task { @MainActor in
            try await service.transferFirstMatchingItem(query: "needle") { _, _ in
                transferCallCount += 1
            }
        }
        await gate.waitUntilSuspended()
        store.setBiometricHistoryLockEnabled(true)
        await gate.resume()

        do {
            _ = try await transferTask.value
            XCTFail("Expected locked history error.")
        } catch {
            XCTAssertEqual(error as? AutomationActionError, .historyLocked)
        }
        XCTAssertEqual(transferCallCount, 0)
    }

    func testSuspendedSearchFailsClosedWhenPersistenceBecomesUnavailable() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        harness.snapshotStore.storageMode = .standard

        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let repository = ClipboardItemRepository(database: database)
        let item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Unavailable During Search",
            payload: ClipboardPayload(text: "unavailable race needle")
        )
        try repository.replaceAll(with: PasteBuddySnapshot(items: [item]))
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository
        )
        store.load()
        let service = AutomationActionService(store: store)
        let gate = RepositorySearchSuspensionGate()
        repository.beforeReturningAsyncFetchPageForTesting = {
            await gate.suspendIfNeeded()
        }

        let searchTask = Task { @MainActor in
            try await service.searchClipboard(query: "needle")
        }
        await gate.waitUntilSuspended()
        store.markHistoryPersistenceUnavailable()
        await gate.resume()

        do {
            _ = try await searchTask.value
            XCTFail("Expected unavailable history error.")
        } catch {
            XCTAssertEqual(error as? PasteBuddyPersistenceError, .historyUnavailable)
        }
    }

    func testLockedHistoryRejectsAutomationItemAccessWithoutInvokingTransfer() async throws {
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

        let operations: [@MainActor () async throws -> Void] = [
            { _ = try await service.searchClipboard(query: "locked") },
            { _ = try await service.firstMatchingItem(query: "locked") },
            { _ = try await service.pinFirstMatchingItem(query: "locked", toPinboardNamed: "Private") },
            {
                _ = try await service.transferFirstMatchingItem(query: "locked") { _, _ in
                    transferCallCount += 1
                }
            }
        ]

        for operation in operations {
            do {
                try await operation()
                XCTFail("Expected locked history error.")
            } catch {
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

    func testBlockedPersistenceRejectsAutomationReadsAndMutations() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        try harness.snapshotStore.save(PasteBuddySnapshot())
        try Data("not a valid PasteBuddy store".utf8).write(to: harness.snapshotStore.fileURL)
        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.load()
        let service = AutomationActionService(store: store)

        XCTAssertTrue(store.isPersistenceWriteBlocked)
        do {
            _ = try await service.searchClipboard(query: "anything")
            XCTFail("Expected unavailable history error.")
        } catch {
            XCTAssertEqual(error as? PasteBuddyPersistenceError, .historyUnavailable)
        }
        XCTAssertThrowsError(try service.createPinboard(name: "Must Not Succeed")) { error in
            XCTAssertEqual(error as? PasteBuddyPersistenceError, .historyUnavailable)
        }
        XCTAssertFalse(store.snapshot.pinboards.contains(where: { $0.name == "Must Not Succeed" }))
    }
}
