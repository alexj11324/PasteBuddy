import XCTest
@testable import PasteBuddyCore

@MainActor
final class MCPToolServiceTests: XCTestCase {
    func testJSONRPCServiceUsesTheInjectedLiveStore() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.setMCPServerEnabled(true)
        _ = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Live MCP item",
            payload: ClipboardPayload(text: "live store payload")
        ))
        let service = MCPJSONRPCService(store: store)
        let request = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"pastebuddy.search_history","arguments":{"query":"Live MCP"}}}"#.utf8)

        let handledResponse = await service.handle(request)
        let responseData = try XCTUnwrap(handledResponse)
        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])

        XCTAssertTrue((content.first?["text"] as? String)?.contains("Live MCP item") == true)
        XCTAssertEqual(store.snapshot.mcp.accessLog.first?.tool, .searchHistory)
        XCTAssertEqual(store.snapshot.mcp.accessLog.first?.resultCount, 1)
    }

    func testMCPServerIsDisabledByDefault() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let service = MCPToolService(store: store)

        XCTAssertFalse(store.snapshot.mcp.isServerEnabled)
        XCTAssertEqual(store.snapshot.mcp.enabledTools, MCPToolName.defaultEnabledTools)
        XCTAssertThrowsError(try service.searchHistory(query: "anything")) { error in
            XCTAssertEqual(error as? MCPToolServiceError, .serverDisabled)
        }
        XCTAssertTrue(store.snapshot.mcp.accessLog.isEmpty)
    }

    func testMCPAgentConnectionEnablesStandardToolsWithoutPayloadRetrieval() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.setMCPServerEnabled(true)

        XCTAssertTrue(store.snapshot.mcp.isServerEnabled)
        XCTAssertEqual(store.snapshot.mcp.enabledTools, MCPToolName.defaultEnabledTools)
        XCTAssertTrue(store.snapshot.mcp.enabledTools.contains(.searchHistory))
        XCTAssertTrue(store.snapshot.mcp.enabledTools.contains(.listPinboards))
        XCTAssertFalse(store.snapshot.mcp.enabledTools.contains(.retrieveItem))
    }

    func testLegacyAllToolsConfigurationMigratesPayloadRetrievalBackToOptIn() throws {
        let legacy = MCPConfiguration(
            isServerEnabled: true,
            enabledTools: Set(MCPToolName.allCases)
        )
        let data = try JSONEncoder().encode(legacy)

        let decoded = try JSONDecoder().decode(MCPConfiguration.self, from: data)

        XCTAssertEqual(decoded.enabledTools, MCPToolName.defaultEnabledTools)
        XCTAssertFalse(decoded.enabledTools.contains(.retrieveItem))
    }

    func testMCPToolLevelAccessControls() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.setMCPServerEnabled(true)
        store.setMCPTool(.retrieveItem, enabled: false)
        store.setMCPTool(.listPinboards, enabled: false)
        let service = MCPToolService(store: store)

        XCTAssertNoThrow(try service.searchHistory(query: "anything"))
        await XCTAssertThrowsErrorAsync(try await service.retrieveItem(itemID: UUID())) { error in
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
        store.setMCPTool(.retrieveItem, enabled: true)
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

    func testMCPRetrieveItemReturnsPayloadAfterAgentConnectionIsAllowed() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.setMCPServerEnabled(true)
        store.setMCPTool(.retrieveItem, enabled: true)
        let item = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Launch Notes",
            payload: ClipboardPayload(text: "private launch checklist")
        ))
        let service = MCPToolService(store: store)

        let response = try await service.retrieveItem(itemID: item.id)

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

    func testMCPRetrieveItemOmitsImageBytesUnlessRequested() async throws {
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

        let metadataOnly = try await service.retrieveItem(itemID: item.id)

        XCTAssertEqual(metadataOnly.payload.ocrText, "Visible OCR text")
        XCTAssertEqual(metadataOnly.payload.imageByteCount, imageData.count)
        XCTAssertNil(metadataOnly.payload.imageDataBase64)
        XCTAssertTrue(metadataOnly.imageDataOmitted)

        let withImageData = try await service.retrieveItem(itemID: item.id, includeImageData: true)

        XCTAssertEqual(withImageData.payload.imageDataBase64, imageData.base64EncodedString())
        XCTAssertFalse(withImageData.imageDataOmitted)
        XCTAssertEqual(store.snapshot.mcp.accessLog.first?.tool, .retrieveItem)
        XCTAssertEqual(store.snapshot.mcp.accessLog.first?.outcome, .succeeded)
        XCTAssertTrue(store.snapshot.mcp.accessLog.first?.payloadIncluded ?? false)
        XCTAssertTrue(store.snapshot.mcp.accessLog.first?.imageDataIncluded ?? false)
    }

    func testMCPRetrieveRechecksPrivacyAfterHydration() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.setMCPServerEnabled(true)
        store.setMCPTool(.retrieveItem, enabled: true)
        let item = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Images",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Hydrated image",
            payload: ClipboardPayload(imageData: Data([0x01]))
        ))
        _ = store.addCaptureRule(
            name: "Block hydrated secret",
            condition: .containsText,
            pattern: "hydrated secret",
            contentTypes: [.image]
        )
        let service = MCPToolService(store: store) { item in
            var hydrated = item
            hydrated.payload.ocrText = "hydrated secret"
            hydrated.refreshSearchDocument()
            return hydrated
        }

        await XCTAssertThrowsErrorAsync(
            try await service.retrieveItem(itemID: item.id, includeImageData: true)
        ) { error in
            XCTAssertEqual(error as? MCPToolServiceError, .privacyBlocked("Block hydrated secret"))
        }
    }

    func testMCPRetrieveItemHydratesImageBytesAfterRepositoryBackedRelaunch() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let imageData = Data(repeating: 0x6D, count: 24_576)
        let repository = ClipboardItemRepository(
            database: try PasteBuddyDatabase(
                fileURL: harness.directory.appendingPathComponent("clipboard.sqlite")
            )
        )
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository
        )
        store.setMCPServerEnabled(true)
        store.setMCPTool(.retrieveItem, enabled: true)
        let item = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Screenshots",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Repository Diagram",
            payload: ClipboardPayload(imageData: imageData, ocrText: "repository image")
        ))
        await store.flushPendingSave()

        let reloaded = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository
        )
        await reloaded.loadAsync()
        let lightweightItem = try XCTUnwrap(reloaded.snapshot.items.first { $0.id == item.id })
        XCTAssertNil(lightweightItem.payload.imageData)
        reloaded.setMCPTool(.retrieveItem, enabled: true)

        let service = MCPToolService(store: reloaded)
        let metadataOnly = try await service.retrieveItem(itemID: item.id)
        XCTAssertEqual(metadataOnly.payload.imageByteCount, imageData.count)
        XCTAssertNil(metadataOnly.payload.imageDataBase64)
        XCTAssertTrue(metadataOnly.imageDataOmitted)

        let withImageData = try await service.retrieveItem(
            itemID: item.id,
            includeImageData: true
        )
        XCTAssertEqual(withImageData.payload.imageDataBase64, imageData.base64EncodedString())
        XCTAssertFalse(withImageData.imageDataOmitted)
    }

    func testMCPToolsRespectCurrentPrivacyRulesWhenReadingExistingItems() async throws {
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

        await XCTAssertThrowsErrorAsync(try await service.retrieveItem(itemID: hidden.id)) { error in
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

    func testMCPPrivacyRulesReceiveSourceBundleIdentifier() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.setMCPServerEnabled(true)
        store.setMCPTool(.retrieveItem, enabled: true)
        let item = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Vault",
            sourceBundleIdentifier: "com.example.vault",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Bundle protected",
            payload: ClipboardPayload(text: "bundle protected content")
        ))
        _ = store.addCaptureRule(
            name: "Block Vault Bundle",
            condition: .sourceBundleIdentifier,
            pattern: "com.example.vault",
            contentTypes: [.text]
        )
        let service = MCPToolService(store: store)

        XCTAssertTrue(try service.searchHistory(query: "Bundle protected").items.isEmpty)
        await XCTAssertThrowsErrorAsync(try await service.retrieveItem(itemID: item.id)) { error in
            XCTAssertEqual(error as? MCPToolServiceError, .privacyBlocked("Block Vault Bundle"))
        }
    }

    func testMCPSemanticSearchBackfillsVisibleResultsAfterPrivacyFiltering() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let clipboard = ClipboardItemRepository(database: database)
        let semantic = SemanticIndexRepository(database: database)
        let blockedItems = (0..<125).map { index in
            ClipboardItem(
                sourceAppName: "Blocked App",
                deviceName: "Test Mac",
                contentType: .text,
                title: "Blocked \(index)",
                payload: ClipboardPayload(text: "blocked private content \(index)")
            )
        }
        let visibleItem = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Visible semantic result",
            payload: ClipboardPayload(text: "permitted content")
        )
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: clipboard,
            semanticIndexRepository: semantic
        )
        store.snapshot.items = blockedItems + [visibleItem]
        store.snapshot.semanticIndex.isEnabled = true
        store.snapshot.entitlement = EntitlementConfiguration(
            plan: .cloudAnnual,
            status: .active,
            currentPeriodEndsAt: Date().addingTimeInterval(60),
            expiresAt: Date().addingTimeInterval(60)
        )
        store.setMCPServerEnabled(true)
        store.setMCPTool(.semanticSearchHistory, enabled: true)
        _ = store.addCaptureRule(
            name: "Block private MCP items",
            condition: .containsText,
            pattern: "blocked private content",
            contentTypes: [.text]
        )
        try clipboard.replaceAll(with: store.snapshot)
        while true {
            let jobs = try semantic.nextJobs(limit: 16)
            guard !jobs.isEmpty else { break }
            for job in jobs {
                let isVisible = job.itemID == visibleItem.id
                try semantic.commit(
                    document: SemanticIndexDocument(
                        itemID: job.itemID,
                        contentHash: job.contentHash,
                        modality: .text,
                        summary: "needle semantic concept",
                        modelName: "test",
                        promptVersion: "test"
                    ),
                    embedding: SemanticEmbedding(
                        id: job.itemID,
                        modelName: "test",
                        values: isVisible ? [0.8, 0.2] : [1, 0]
                    ),
                    jobID: job.id,
                    expectedGeneration: job.generation
                )
            }
        }
        let service = MCPToolService(
            store: store,
            hydrateItem: { $0 },
            semanticEmbeddingProvider: FixedSemanticEmbeddingProvider(values: [1, 0])
        )

        let response = try await service.semanticSearchHistory(query: "needle", limit: 1)

        XCTAssertEqual(response.items.map(\.id), [visibleItem.id])
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
        var revokeCallbacks = 0
        store.onMCPAccessRevoked = { revokeCallbacks += 1 }
        store.setMCPServerEnabled(true)
        store.revokeMCPAccess()

        XCTAssertFalse(store.snapshot.mcp.isServerEnabled)
        XCTAssertEqual(store.snapshot.mcp.enabledTools, [])
        XCTAssertNotNil(store.snapshot.mcp.lastAccessRevokedAt)
        XCTAssertEqual(revokeCallbacks, 1)

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertFalse(reloaded.snapshot.mcp.isServerEnabled)
        XCTAssertEqual(reloaded.snapshot.mcp.enabledTools, [])
        XCTAssertNotNil(reloaded.snapshot.mcp.lastAccessRevokedAt)
    }

    func testRetrieveRechecksPermissionAfterHydration() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.setMCPServerEnabled(true)
        store.setMCPTool(.retrieveItem, enabled: true)
        let item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Hydration race",
            payload: ClipboardPayload(text: "secret")
        )
        _ = store.addCapturedItem(item)
        let service = MCPToolService(store: store) { item in
            store.revokeMCPAccess()
            return item
        }

        await XCTAssertThrowsErrorAsync(try await service.retrieveItem(itemID: item.id, includeImageData: true)) {
            XCTAssertEqual($0 as? MCPToolServiceError, .serverDisabled)
        }
    }
}

private struct FixedSemanticEmbeddingProvider: SemanticEmbeddingProviding {
    var values: [Float]

    func embedDocuments(_ inputs: [SemanticEmbeddingInput]) async throws -> [SemanticEmbedding] {
        inputs.map { SemanticEmbedding(id: $0.id, modelName: "test", values: values) }
    }

    func embedQuery(_ query: String) async throws -> SemanticEmbedding {
        SemanticEmbedding(id: UUID(), modelName: "test", values: values)
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @MainActor @autoclosure () async throws -> T,
    _ handler: @MainActor (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw.", file: file, line: line)
    } catch {
        handler(error)
    }
}
