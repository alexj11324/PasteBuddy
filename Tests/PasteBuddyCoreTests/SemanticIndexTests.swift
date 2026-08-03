import XCTest
@testable import PasteBuddyCore

final class SemanticIndexTests: XCTestCase {
    @MainActor
    func testBYOKCapabilityRequiresSubscriptionAndDeviceCredential() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        let credentials = FakeAIProviderCredentialStore(keys: [.openAI: "test-key"])
        let store = PasteBuddyStore(diskStore: harness.snapshotStore, aiCredentialStore: credentials)
        let now = Date()
        store.applyStoreEntitlement(EntitlementConfiguration(
            plan: .byokAnnual,
            status: .active,
            currentPeriodEndsAt: now.addingTimeInterval(60),
            expiresAt: now.addingTimeInterval(60)
        ))
        store.setSemanticInferenceSource(.byok)

        XCTAssertTrue(store.hasBYOKAccess)
        XCTAssertFalse(store.hasCloudAIAccess)
        XCTAssertTrue(store.canRunConfiguredAISource)

        store.deleteBYOKAPIKey(for: .openAI)
        XCTAssertFalse(store.canRunConfiguredAISource)
    }

    func testImageSourceUsesMultimodalBytesWithoutSendingOCRText() throws {
        let item = ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Diagram",
            payload: ClipboardPayload(
                imageData: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="),
                ocrText: "optional local OCR"
            )
        )

        let source = try SemanticIndexSourceNormalizer.source(from: item, privacy: PrivacyConfiguration())

        XCTAssertNotNil(source.imageDataBase64)
        XCTAssertNil(source.existingOCRText)
        XCTAssertFalse(source.text.contains("optional local OCR"))
    }

    func testAutomaticQueueCommitSearchSuppressionAndReindexStayLocal() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let clipboard = ClipboardItemRepository(database: database)
        let semantic = SemanticIndexRepository(database: database)
        let item = ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Architecture sketch",
            payload: ClipboardPayload(imageData: Data([0x01, 0x02]))
        )
        var snapshot = PasteBuddySnapshot(items: [item])
        snapshot.semanticIndex.isEnabled = true
        try clipboard.synchronize(with: snapshot)

        let job = try XCTUnwrap(semantic.nextJobs(limit: 1).first)
        XCTAssertEqual(job.itemID, item.id)
        let document = SemanticIndexDocument(
            itemID: item.id,
            contentHash: item.searchDocument.contentHash,
            modality: .image,
            summary: "A local-first semantic search architecture diagram",
            keywords: ["semantic search", "clipboard"],
            modelName: "test-vision",
            promptVersion: "test-v1"
        )
        try semantic.commit(
            document: document,
            embedding: SemanticEmbedding(id: item.id, modelName: "test-embedding", values: [1, 0]),
            jobID: job.id
        )

        let request = SemanticSearchRequest(query: "architecture")
        XCTAssertEqual(
            try semantic.semanticRankedItemIDs(
                request: request,
                queryEmbedding: SemanticEmbedding(id: UUID(), modelName: "test-embedding", values: [1, 0])
            ).first?.0,
            item.id
        )
        XCTAssertEqual(try semantic.semanticLexicalItemIDs(request: request).first, item.id)
        try semantic.suppress(itemID: item.id)
        XCTAssertTrue(try semantic.isSuppressed(itemID: item.id))
        XCTAssertTrue(try semantic.semanticRankedItemIDs(
            request: request,
            queryEmbedding: SemanticEmbedding(id: UUID(), modelName: "test-embedding", values: [1, 0])
        ).isEmpty)

        try semantic.reindex(itemID: item.id, contentHash: item.searchDocument.contentHash)
        XCTAssertFalse(try semantic.isSuppressed(itemID: item.id))
        XCTAssertEqual(try semantic.nextJobs(limit: 1).first?.itemID, item.id)
        try semantic.suppress(itemID: item.id)
        try semantic.resetForRebuild()
        XCTAssertTrue(try semantic.isSuppressed(itemID: item.id), "A rebuild must preserve explicit per-item exclusions")
    }

    func testDeletingClipboardItemCascadesThroughSemanticIndex() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let clipboard = ClipboardItemRepository(database: database)
        let semantic = SemanticIndexRepository(database: database)
        let item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Deployment note",
            payload: ClipboardPayload(text: "deploy the gateway without persistence")
        )
        try clipboard.replaceAll(with: PasteBuddySnapshot(items: [item]))
        _ = try semantic.enqueue(itemID: item.id, contentHash: item.searchDocument.contentHash)
        try clipboard.deleteItems([item.id])
        XCTAssertEqual(try semantic.statistics().queued, 0)
        XCTAssertEqual(try semantic.statistics().ready, 0)
    }

    func testStaleOutboxJobIsDroppedWithoutCreatingAnExclusion() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let clipboard = ClipboardItemRepository(database: database)
        let semantic = SemanticIndexRepository(database: database)
        let item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Changing note",
            payload: ClipboardPayload(text: "new content")
        )
        try clipboard.replaceAll(with: PasteBuddySnapshot(items: [item]))
        _ = try semantic.enqueue(itemID: item.id, contentHash: "stale-hash")
        let job = try XCTUnwrap(semantic.nextJobs(limit: 1).first)

        try semantic.discardStale(job: job)

        XCTAssertEqual(try semantic.statistics().queued, 0)
        XCTAssertEqual(try semantic.statistics().suppressed, 0)
        XCTAssertFalse(try semantic.isSuppressed(itemID: item.id))
    }

    func testSourceRevisionImmediatelyInvalidatesOldDerivedDataWhilePaused() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let clipboard = ClipboardItemRepository(database: database)
        let semantic = SemanticIndexRepository(database: database)
        var item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Draft",
            payload: ClipboardPayload(text: "old content")
        )
        var snapshot = PasteBuddySnapshot(items: [item])
        snapshot.semanticIndex.isEnabled = true
        try clipboard.synchronize(with: snapshot)
        let job = try XCTUnwrap(semantic.nextJobs(limit: 1).first)
        try semantic.commit(
            document: SemanticIndexDocument(
                itemID: item.id,
                contentHash: item.searchDocument.contentHash,
                modality: .text,
                summary: "old searchable concept",
                modelName: "test",
                promptVersion: "test"
            ),
            embedding: SemanticEmbedding(id: item.id, modelName: "test", values: [1, 0]),
            jobID: job.id
        )

        item.payload.text = "new content"
        item.updatedAt = item.updatedAt.addingTimeInterval(1)
        item.refreshSearchDocument()
        snapshot.items = [item]
        snapshot.semanticIndex.isPaused = true
        try clipboard.synchronize(with: snapshot)

        XCTAssertEqual(try semantic.statistics().ready, 0)
        XCTAssertEqual(try semantic.statistics().queued, 0)
        XCTAssertTrue(try semantic.semanticLexicalItemIDs(request: SemanticSearchRequest(query: "old searchable")).isEmpty)
        try semantic.enqueueBackfill()
        XCTAssertEqual(try semantic.nextJobs(limit: 1).first?.contentHash, item.searchDocument.contentHash)
    }
}

private final class FakeAIProviderCredentialStore: AIProviderCredentialStoring, @unchecked Sendable {
    private var keys: [BYOKProviderPreset: String]

    init(keys: [BYOKProviderPreset: String] = [:]) {
        self.keys = keys
    }

    func apiKey(for provider: BYOKProviderPreset) throws -> String? { keys[provider] }
    func saveAPIKey(_ apiKey: String, for provider: BYOKProviderPreset) throws { keys[provider] = apiKey }
    func deleteAPIKey(for provider: BYOKProviderPreset) throws { keys[provider] = nil }
}
