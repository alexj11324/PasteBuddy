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

    func testCreateTextItemRespectsSensitiveTextBlocking() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let service = AutomationActionService(store: store)

        XCTAssertThrowsError(try service.createTextItem(text: "api_key = sk_live_51ABCDEF0123456789")) { error in
            XCTAssertEqual(error as? AutomationActionError, .sensitiveTextBlocked)
        }

        let summary = try service.createTextItem(text: "Reusable support reply", title: "Support Reply")

        XCTAssertEqual(summary.title, "Support Reply")
        XCTAssertEqual(store.snapshot.items.first?.payload.text, "Reusable support reply")
    }

    func testCreateTextItemRespectsCustomCaptureRules() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        _ = store.addCaptureRule(
            name: "Shortcuts payroll block",
            condition: .containsText,
            pattern: "payroll",
            contentTypes: [.text]
        )
        let service = AutomationActionService(store: store)

        XCTAssertThrowsError(try service.createTextItem(text: "payroll draft")) { error in
            XCTAssertEqual(error as? AutomationActionError, .captureRuleBlocked("Shortcuts payroll block"))
        }

        XCTAssertTrue(store.snapshot.items.isEmpty)
    }

    func testCreateContentItemSupportsURLFileAndOptionalPinboard() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let service = AutomationActionService(store: store)
        let pinboard = try service.createPinboard(name: "Reading List")

        let urlResult = try service.createContentItem(
            kind: .url,
            value: "https://example.com/post",
            title: "Example Post",
            pinboardName: "reading list"
        )
        let fileResult = try service.createContentItem(
            kind: .fileURL,
            value: "file:///Users/example/Brief.pdf",
            title: nil
        )

        XCTAssertEqual(urlResult.item.title, "Example Post")
        XCTAssertEqual(urlResult.item.contentType, .url)
        XCTAssertEqual(urlResult.pinboard?.id, pinboard.id)
        XCTAssertEqual(urlResult.displaySummary, "Created PasteBuddy item \"Example Post\" and saved it to Reading List.")
        XCTAssertEqual(fileResult.item.title, "Brief.pdf")
        XCTAssertEqual(fileResult.item.contentType, .file)
        XCTAssertNil(fileResult.pinboard)
        XCTAssertEqual(store.snapshot.pinboards.first(where: { $0.id == pinboard.id })?.itemIDs, [urlResult.item.id])
    }

    func testCreateContentItemRespectsDisabledTypesAndSensitiveRules() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let service = AutomationActionService(store: store)

        store.toggleURLCapture()
        XCTAssertThrowsError(try service.createContentItem(kind: .url, value: "https://example.com")) { error in
            XCTAssertEqual(error as? AutomationActionError, .contentTypeDisabled(.url))
        }

        XCTAssertThrowsError(try service.createContentItem(kind: .text, value: "api_key = sk_live_51ABCDEF0123456789")) { error in
            XCTAssertEqual(error as? AutomationActionError, .sensitiveTextBlocked)
        }

        XCTAssertTrue(store.snapshot.items.isEmpty)
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
}
