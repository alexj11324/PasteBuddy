import XCTest
@testable import PasteBuddyCore

@MainActor
final class MCPToolServiceTests: XCTestCase {
    func testMCPToolsAreDisabledByDefault() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let service = MCPToolService(store: store)

        XCTAssertFalse(store.snapshot.mcp.isServerEnabled)
        XCTAssertFalse(store.snapshot.mcp.enabledTools.contains(.retrieveItem))
        XCTAssertThrowsError(try service.searchHistory(query: "anything")) { error in
            XCTAssertEqual(error as? MCPToolServiceError, .serverDisabled)
        }
        XCTAssertTrue(store.snapshot.mcp.accessLog.isEmpty)
    }

    func testMCPToolLevelAccessControls() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.setMCPServerEnabled(true)
        store.setMCPTool(.listPinboards, enabled: false)
        let service = MCPToolService(store: store)

        XCTAssertNoThrow(try service.searchHistory(query: "anything"))
        XCTAssertThrowsError(try service.retrieveItem(itemID: UUID())) { error in
            XCTAssertEqual(error as? MCPToolServiceError, .toolDisabled(.retrieveItem))
        }
        XCTAssertThrowsError(try service.listPinboards()) { error in
            XCTAssertEqual(error as? MCPToolServiceError, .toolDisabled(.listPinboards))
        }
        XCTAssertEqual(store.snapshot.mcp.accessLog.first?.tool, .listPinboards)
        XCTAssertEqual(store.snapshot.mcp.accessLog.first?.outcome, .denied)
    }

    func testMCPSearchReturnsSummariesWithoutPayloads() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.setMCPServerEnabled(true)
        let item = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Roadmap",
            payload: ClipboardPayload(text: "raw clipboard payload should stay out")
        ))
        let service = MCPToolService(store: store)

        let response = try service.searchHistory(query: "roadmap")

        XCTAssertEqual(response.items.map(\.id), [item.id])
        XCTAssertTrue(response.payloadsOmitted)
        XCTAssertFalse(response.items.map(\.title).joined().contains("raw clipboard payload"))
        XCTAssertEqual(store.snapshot.mcp.accessLog.first?.tool, .searchHistory)
        XCTAssertEqual(store.snapshot.mcp.accessLog.first?.outcome, .succeeded)
        XCTAssertEqual(store.snapshot.mcp.accessLog.first?.resultCount, 1)

        let logData = try JSONEncoder().encode(store.snapshot.mcp.accessLog)
        let logJSON = String(decoding: logData, as: UTF8.self)
        XCTAssertFalse(logJSON.contains("roadmap"))
        XCTAssertFalse(logJSON.contains("raw clipboard payload"))
    }

    func testMCPRetrieveItemRequiresExplicitToolOptInAndReturnsPayload() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.setMCPServerEnabled(true)
        let item = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Launch Notes",
            payload: ClipboardPayload(text: "private launch checklist")
        ))
        let service = MCPToolService(store: store)

        XCTAssertThrowsError(try service.retrieveItem(itemID: item.id)) { error in
            XCTAssertEqual(error as? MCPToolServiceError, .toolDisabled(.retrieveItem))
        }
        XCTAssertEqual(store.snapshot.mcp.accessLog.first?.tool, .retrieveItem)
        XCTAssertEqual(store.snapshot.mcp.accessLog.first?.outcome, .denied)
        XCTAssertEqual(store.snapshot.mcp.accessLog.first?.itemID, item.id)
        XCTAssertFalse(store.snapshot.mcp.accessLog.first?.payloadIncluded ?? true)

        store.setMCPTool(.retrieveItem, enabled: true)
        let response = try service.retrieveItem(itemID: item.id)

        XCTAssertEqual(response.item.id, item.id)
        XCTAssertTrue(response.payloadIncluded)
        XCTAssertFalse(response.imageDataOmitted)
        XCTAssertEqual(response.payload.text, "private launch checklist")
        XCTAssertEqual(response.payload.plainText, "private launch checklist")
        XCTAssertEqual(store.snapshot.mcp.accessLog.first?.tool, .retrieveItem)
        XCTAssertEqual(store.snapshot.mcp.accessLog.first?.outcome, .succeeded)
        XCTAssertEqual(store.snapshot.mcp.accessLog.first?.itemID, item.id)
        XCTAssertTrue(store.snapshot.mcp.accessLog.first?.payloadIncluded ?? false)
        XCTAssertFalse(store.snapshot.mcp.accessLog.first?.imageDataIncluded ?? true)
    }

    func testMCPRetrieveItemOmitsImageBytesUnlessRequested() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.setMCPServerEnabled(true)
        store.setMCPTool(.retrieveItem, enabled: true)
        let imageData = Data([0x01, 0x02, 0x03, 0x04])
        let item = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Screenshots",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Diagram",
            payload: ClipboardPayload(imageData: imageData, ocrText: "Visible OCR text")
        ))
        let service = MCPToolService(store: store)

        let metadataOnly = try service.retrieveItem(itemID: item.id)

        XCTAssertEqual(metadataOnly.payload.ocrText, "Visible OCR text")
        XCTAssertEqual(metadataOnly.payload.imageByteCount, imageData.count)
        XCTAssertNil(metadataOnly.payload.imageDataBase64)
        XCTAssertTrue(metadataOnly.imageDataOmitted)

        let withImageData = try service.retrieveItem(itemID: item.id, includeImageData: true)

        XCTAssertEqual(withImageData.payload.imageDataBase64, imageData.base64EncodedString())
        XCTAssertFalse(withImageData.imageDataOmitted)
        XCTAssertEqual(store.snapshot.mcp.accessLog.first?.tool, .retrieveItem)
        XCTAssertEqual(store.snapshot.mcp.accessLog.first?.outcome, .succeeded)
        XCTAssertTrue(store.snapshot.mcp.accessLog.first?.payloadIncluded ?? false)
        XCTAssertTrue(store.snapshot.mcp.accessLog.first?.imageDataIncluded ?? false)
    }

    func testMCPToolsRespectCurrentPrivacyRulesWhenReadingExistingItems() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.setMCPServerEnabled(true)
        store.setMCPTool(.retrieveItem, enabled: true)
        let hidden = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Payroll Draft",
            payload: ClipboardPayload(text: "payroll adjustment draft")
        ))
        let visible = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Meeting Notes",
            payload: ClipboardPayload(text: "weekly planning notes")
        ))
        let pinboard = store.createPinboard(named: "AI Context")
        store.pinItems([hidden.id, visible.id], to: pinboard.id)
        _ = store.addCaptureRule(
            name: "No payroll MCP access",
            condition: .containsText,
            pattern: "payroll",
            contentTypes: [.text]
        )
        let service = MCPToolService(store: store)

        let hiddenSearch = try service.searchHistory(query: "payroll")
        XCTAssertTrue(hiddenSearch.items.isEmpty)
        XCTAssertEqual(store.snapshot.mcp.accessLog.first?.resultCount, 0)

        let visibleSearch = try service.searchHistory(query: "notes")
        XCTAssertEqual(visibleSearch.items.map(\.id), [visible.id])

        XCTAssertThrowsError(try service.retrieveItem(itemID: hidden.id)) { error in
            XCTAssertEqual(error as? MCPToolServiceError, .privacyBlocked("No payroll MCP access"))
        }
        XCTAssertEqual(store.snapshot.mcp.accessLog.first?.tool, .retrieveItem)
        XCTAssertEqual(store.snapshot.mcp.accessLog.first?.outcome, .denied)
        XCTAssertEqual(store.snapshot.mcp.accessLog.first?.itemID, hidden.id)
        XCTAssertFalse(store.snapshot.mcp.accessLog.first?.payloadIncluded ?? true)

        let pinboards = try service.listPinboards()
        XCTAssertEqual(pinboards.pinboards.first(where: { $0.id == pinboard.id })?.itemCount, 1)

        XCTAssertThrowsError(try service.pinFirstMatch(query: "payroll", pinboardID: pinboard.id)) { error in
            XCTAssertEqual(error as? MCPToolServiceError, .noMatchingItem)
        }
    }

    func testMCPCreatePinboardAndPinFirstMatch() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.setMCPServerEnabled(true)
        let item = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Test Mac",
            contentType: .url,
            title: "Research Link",
            payload: ClipboardPayload(urlString: "https://example.com/research")
        ))
        let service = MCPToolService(store: store)

        let created = try service.createPinboard(name: "Research", colorHex: "70c1b3")
        let pinned = try service.pinFirstMatch(query: "research", pinboardID: created.pinboard.id)

        XCTAssertEqual(created.pinboard.name, "Research")
        XCTAssertEqual(created.pinboard.colorHex, "#70C1B3")
        XCTAssertEqual(pinned.item.id, item.id)
        XCTAssertEqual(pinned.pinboard.itemCount, 1)
        XCTAssertEqual(store.snapshot.pinboards.first(where: { $0.id == created.pinboard.id })?.itemIDs, [item.id])
        XCTAssertEqual(store.snapshot.mcp.accessLog.first?.tool, .pinFirstMatch)
        XCTAssertEqual(store.snapshot.mcp.accessLog.first?.itemID, item.id)
        XCTAssertEqual(store.snapshot.mcp.accessLog.first?.pinboardID, created.pinboard.id)
    }

    func testMCPAccessLogPersistsEncryptedAndCanBeCleared() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.setMCPServerEnabled(true)
        let item = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Secret Plan",
            payload: ClipboardPayload(text: "payload must not appear in audit")
        ))
        let service = MCPToolService(store: store)

        _ = try service.searchHistory(query: "secret")

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertEqual(reloaded.snapshot.mcp.accessLog.count, 1)
        XCTAssertEqual(reloaded.snapshot.mcp.accessLog.first?.tool, .searchHistory)
        XCTAssertEqual(reloaded.snapshot.mcp.accessLog.first?.outcome, .succeeded)
        XCTAssertNil(reloaded.snapshot.mcp.accessLog.first?.itemID)
        XCTAssertFalse(reloaded.snapshot.mcp.accessLog.first?.payloadIncluded ?? true)

        let rawStoreData = try Data(contentsOf: harness.snapshotStore.fileURL)
        let rawStoreText = String(decoding: rawStoreData, as: UTF8.self)
        XCTAssertFalse(rawStoreText.contains("secret"))
        XCTAssertFalse(rawStoreText.contains("payload must not appear in audit"))
        XCTAssertFalse(rawStoreText.contains(item.title))

        reloaded.clearMCPAccessLog()
        XCTAssertTrue(reloaded.snapshot.mcp.accessLog.isEmpty)
    }

    func testMCPRevokeAccessClearsToolsAndPersists() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.setMCPServerEnabled(true)
        store.revokeMCPAccess()

        XCTAssertFalse(store.snapshot.mcp.isServerEnabled)
        XCTAssertEqual(store.snapshot.mcp.enabledTools, [])
        XCTAssertNotNil(store.snapshot.mcp.lastAccessRevokedAt)

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertFalse(reloaded.snapshot.mcp.isServerEnabled)
        XCTAssertEqual(reloaded.snapshot.mcp.enabledTools, [])
        XCTAssertNotNil(reloaded.snapshot.mcp.lastAccessRevokedAt)
    }
}
