import Foundation
import XCTest
@testable import PasteBuddyCore

extension PasteBuddyStoreTests {
    func testPreparedCapturePathDoesNotRebuildCurrentSearchDocumentOnMainActor() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        var item = ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Test Mac",
            contentType: .url,
            title: "Prepared capture",
            payload: ClipboardPayload(urlString: "https://example.com/prepared")
        )
        item.searchDocument.storageBytes = Int.max

        let stored = store.addCapturedItemWithCurrentSearchDocument(item)

        XCTAssertEqual(stored.searchDocument.storageBytes, Int.max)
    }

    func testAvailableFilterValuesRefreshWhenPasteStackContentsChangeAtSameCount() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.pasteStackItems = [ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "First Mac",
            contentType: .text,
            title: "First",
            payload: ClipboardPayload(text: "first")
        )]
        XCTAssertEqual(store.availableSourceApps, ["Notes"])
        XCTAssertEqual(store.availableDevices, ["First Mac"])

        store.pasteStackItems = [ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Second Mac",
            contentType: .url,
            title: "Second",
            payload: ClipboardPayload(urlString: "https://example.com")
        )]

        XCTAssertEqual(store.availableSourceApps, ["Safari"])
        XCTAssertEqual(store.availableDevices, ["Second Mac"])
    }

    func testSearchMatchesStoredOCRMetadata() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let imageItem = ClipboardItem(
            sourceAppName: "Screenshot",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Screenshot or image",
            payload: ClipboardPayload(imageData: Data([0x01, 0x02]), ocrText: "Quarterly launch checklist"),
            ocrState: .completed(Date())
        )

        store.addCapturedItem(imageItem)
        store.searchQuery = "launch checklist"

        XCTAssertEqual(store.filteredItems.map(\.id), [imageItem.id])
    }

    func testSearchAtAppMentionFiltersSourceApplications() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let codex = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Codex",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Codex Review",
            payload: ClipboardPayload(text: "repository review notes")
        ))
        let braveLaunch = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Brave Browser",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Brave Launch",
            payload: ClipboardPayload(text: "launch checklist")
        ))
        _ = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Brave Browser",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Brave Sunset",
            payload: ClipboardPayload(text: "sunset notes")
        ))
        _ = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Notes Launch",
            payload: ClipboardPayload(text: "launch checklist")
        ))

        store.searchQuery = "@Codex"
        XCTAssertEqual(store.filteredItems.map(\.id), [codex.id])

        store.searchQuery = "@Brave launch"
        XCTAssertEqual(store.filteredItems.map(\.id), [braveLaunch.id])

        store.searchQuery = "@Missing"
        XCTAssertTrue(store.filteredItems.isEmpty)
    }

    func testSourceAppSuggestionsMatchPartialInputAndApplyAsFilter() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        _ = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Paste",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Paste Item",
            payload: ClipboardPayload(text: "paste text")
        ))
        let pasteBuddy = store.addCapturedItem(ClipboardItem(
            sourceAppName: "PasteBuddy",
            deviceName: "Test Mac",
            contentType: .text,
            title: "PasteBuddy Item",
            payload: ClipboardPayload(text: "pastebuddy text")
        ))
        _ = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Brave Browser",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Brave Item",
            payload: ClipboardPayload(text: "brave text")
        ))

        XCTAssertEqual(store.sourceAppSuggestions(matching: "pa"), ["Paste", "PasteBuddy"])
        XCTAssertEqual(store.sourceAppSuggestions(matching: "@pasteb"), ["PasteBuddy"])
        XCTAssertEqual(store.sourceAppSuggestions(matching: "browser"), ["Brave Browser"])

        store.searchQuery = "pa"
        store.applySourceAppSuggestion("PasteBuddy")

        XCTAssertEqual(store.sourceAppFilter, "PasteBuddy")
        XCTAssertEqual(store.searchQuery, "")
        XCTAssertEqual(store.filteredItems.map(\.id), [pasteBuddy.id])
    }

    func testRepositoryBackedSearchAtAppMentionUsesResolvedSourceApp() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let brave = ClipboardItem(
            sourceAppName: "Brave Browser",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Brave Launch",
            payload: ClipboardPayload(text: "launch checklist")
        )
        let notes = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Notes Launch",
            payload: ClipboardPayload(text: "launch checklist")
        )
        try harness.snapshotStore.save(PasteBuddySnapshot(items: [brave, notes]))
        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let repository = ClipboardItemRepository(database: database)
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository
        )
        store.load()

        store.searchQuery = "@Brave launch"

        XCTAssertEqual(store.filteredItems.map(\.id), [brave.id])
    }

    func testMarkOCRPendingClearsCompletedStateForRerun() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let imageItem = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Screenshot",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Screenshot or image",
            payload: ClipboardPayload(imageData: Data([0x01, 0x02]), ocrText: "old garbled OCR"),
            ocrState: .completed(Date())
        ))

        store.markOCRPending(for: imageItem.id)

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()
        guard case .pending = reloaded.snapshot.items.first?.ocrState else {
            return XCTFail("Expected OCR to be pending after manual rerun.")
        }
        XCTAssertNil(reloaded.snapshot.items.first?.payload.ocrText)
    }

    func testSearchCoversTextURLsFilenamesLabelsPinboardsAndMissingOptionalMetadata() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let text = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Meeting Template",
            payload: ClipboardPayload(text: "Customer reply body")
        ))
        _ = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Test Mac",
            contentType: .url,
            title: "Launch Link",
            payload: ClipboardPayload(urlString: "https://example.com/roadmap")
        ))
        let file = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Finder",
            deviceName: "Test Mac",
            contentType: .file,
            title: "Proposal",
            payload: ClipboardPayload(fileURLString: "file:///Users/example/Brief.pdf")
        ))
        let imageWithoutOCR = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Pending Screenshot",
            payload: ClipboardPayload(imageData: Data([0xff])),
            ocrState: .failed(Date(), "Vision unavailable")
        ))
        store.setLabels(["VIP Client"], for: text.id)

        store.searchQuery = "vip client"
        XCTAssertEqual(store.filteredItems.map(\.id), [text.id])

        store.searchQuery = "roadmap"
        XCTAssertEqual(store.filteredItems.map(\.title), ["Launch Link"])

        store.searchQuery = "Brief.pdf"
        XCTAssertEqual(store.filteredItems.map(\.id), [file.id])

        store.searchQuery = "Pending Screenshot"
        XCTAssertEqual(store.filteredItems.map(\.id), [imageWithoutOCR.id])

        store.createPinboard(named: "Research")
        let pinboardID = store.snapshot.pinboards.last!.id
        store.pinItem(file.id, to: pinboardID)
        store.selectedScope = .pinboard(pinboardID)
        store.searchQuery = "Brief.pdf"

        XCTAssertEqual(store.filteredItems.map(\.id), [file.id])
    }

    func testPresentationRevisionDoesNotChangeForSelectionOnlyUpdates() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let first = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "First",
            payload: ClipboardPayload(text: "first payload")
        ))
        let second = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Test Mac",
            contentType: .url,
            title: "Second",
            payload: ClipboardPayload(urlString: "https://example.com")
        ))
        let revisionAfterContentLoad = store.presentationRevision

        store.selectSingleItem(first.id)
        store.selectSingleItem(second.id)
        store.selectSingleItem(second.id)

        XCTAssertEqual(store.presentationRevision, revisionAfterContentLoad)

        store.searchQuery = "second"

        XCTAssertGreaterThan(store.presentationRevision, revisionAfterContentLoad)
    }

    func testImageDeduplicationUsesImageBytesWhenOCRTextIsEmpty() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let first = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .image,
            title: "First Image",
            payload: ClipboardPayload(imageData: Data([0x01, 0x02]))
        ))
        let second = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Second Image",
            payload: ClipboardPayload(imageData: Data([0x03, 0x04]))
        ))
        let duplicateFirst = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .image,
            title: "First Image Again",
            payload: ClipboardPayload(imageData: Data([0x01, 0x02]))
        ))

        XCTAssertEqual(store.snapshot.items.count, 2)
        XCTAssertEqual(duplicateFirst.id, first.id)
        XCTAssertTrue(store.snapshot.items.contains(where: { $0.id == second.id }))
    }

    func testClipboardItemDecodingDefaultsMissingLabels() throws {
        let data = Data(#"{"sourceAppName":"Notes","deviceName":"Test Mac","contentType":"text","title":"Legacy","payload":{"text":"legacy body"}}"#.utf8)

        let item = try JSONDecoder().decode(ClipboardItem.self, from: data)

        XCTAssertEqual(item.title, "Legacy")
        XCTAssertEqual(item.labels, [])
        XCTAssertEqual(item.reuseCategory, .snippet)
        XCTAssertEqual(item.payload.text, "legacy body")
    }

    func testQuickPasteItemUsesCurrentVisibleOrder() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let oldDate = Calendar.current.date(byAdding: .hour, value: -2, to: Date())!
        _ = store.addCapturedItem(ClipboardItem(
            createdAt: oldDate,
            updatedAt: oldDate,
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Older",
            payload: ClipboardPayload(text: "older")
        ))
        let newer = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Newer",
            payload: ClipboardPayload(text: "newer")
        ))

        XCTAssertEqual(store.quickPasteItem(atOneBasedIndex: 1)?.id, newer.id)
        XCTAssertNil(store.quickPasteItem(atOneBasedIndex: 10))

        store.searchQuery = "older"

        XCTAssertEqual(store.quickPasteItem(atOneBasedIndex: 1)?.title, "Older")
        XCTAssertNil(store.quickPasteItem(atOneBasedIndex: 2))
    }

    func testScopedFilteredItemsDoNotMutateSelectedScope() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let oldDate = Calendar.current.date(byAdding: .hour, value: -2, to: Date())!
        let pinned = store.addCapturedItem(ClipboardItem(
            createdAt: oldDate,
            updatedAt: oldDate,
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Pinned",
            payload: ClipboardPayload(text: "pinned body")
        ))
        let newer = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Newer History",
            payload: ClipboardPayload(text: "newer body")
        ))
        let pinboard = store.createPinboard(named: "Shelf")
        store.pinItem(pinned.id, to: pinboard.id)

        let pinboardScope = PasteScope.pinboard(pinboard.id)
        XCTAssertEqual(store.selectedScope, pinboardScope)
        XCTAssertEqual(store.quickPasteItem(atOneBasedIndex: 1)?.id, pinned.id)

        let queryRevision = store.queryRevision

        XCTAssertEqual(store.filteredItems(for: .history).map(\.id), [newer.id, pinned.id])
        XCTAssertEqual(store.quickPasteItem(atOneBasedIndex: 1, in: .history)?.id, newer.id)
        XCTAssertEqual(store.selectedScope, pinboardScope)
        XCTAssertEqual(store.queryRevision, queryRevision)
    }

    func testScopedSelectionResolvesPrimaryInExplicitScopeWithoutChangingSelectedScope() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let oldDate = Calendar.current.date(byAdding: .hour, value: -2, to: Date())!
        let older = store.addCapturedItem(ClipboardItem(
            createdAt: oldDate,
            updatedAt: oldDate,
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Older",
            payload: ClipboardPayload(text: "older body")
        ))
        let newer = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Newer",
            payload: ClipboardPayload(text: "newer body")
        ))
        let pinboard = Pinboard(name: "Panel", colorHex: "#4EA7FC", itemIDs: [older.id, newer.id])
        store.snapshot.pinboards = [pinboard]
        store.selectedScope = .history

        store.setSelectedItemIDs([older.id, newer.id], in: .pinboard(pinboard.id))

        XCTAssertEqual(store.selectedScope, .history)
        XCTAssertEqual(store.selectedItemID, older.id)
        XCTAssertEqual(store.selectedItemIDs, [older.id, newer.id])
    }

    func testSelectedItemsFollowCurrentDisplayOrder() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let oldDate = Calendar.current.date(byAdding: .hour, value: -2, to: Date())!
        let first = store.addCapturedItem(ClipboardItem(
            createdAt: oldDate,
            updatedAt: oldDate,
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Older",
            payload: ClipboardPayload(text: "older")
        ))
        let second = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Newer",
            payload: ClipboardPayload(text: "newer")
        ))

        store.setSelectedItemIDs([first.id, second.id])

        XCTAssertEqual(store.selectedItemsInDisplayOrder.map(\.title), ["Newer", "Older"])
    }

    func testSelectedPasteOrderPreviewExplainsVisibleOrderAndPlainTextFallback() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let older = store.addCapturedItem(ClipboardItem(
            createdAt: Date().addingTimeInterval(-2),
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Older",
            payload: ClipboardPayload(text: "older body")
        ))
        let newer = store.addCapturedItem(ClipboardItem(
            createdAt: Date(),
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Screenshot",
            payload: ClipboardPayload(imageData: Data([0x01]), ocrText: "newer image")
        ))
        store.setSelectedItemIDs([older.id, newer.id])

        let preview = try XCTUnwrap(store.selectedPasteOrderPreview)

        XCTAssertEqual(preview.rows.map(\.id), [newer.id, older.id])
        XCTAssertEqual(preview.rows.map(\.position), [1, 2])
        XCTAssertEqual(preview.rows.map(\.contentType), [.image, .text])
        XCTAssertTrue(preview.fallbackDescription?.contains("plain text") ?? false)
        XCTAssertTrue(preview.fallbackDescription?.contains("visible order") ?? false)
    }

    func testEditTextItemUpdatesPayloadAndSearchableTextWithoutChangingTitle() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let item = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Friendly Title",
            payload: ClipboardPayload(text: "before")
        ))

        store.updateTextItem(item.id, to: "after edit")
        store.searchQuery = "after edit"

        XCTAssertEqual(store.snapshot.items.first?.title, "Friendly Title")
        XCTAssertEqual(store.snapshot.items.first?.payload.text, "after edit")
        XCTAssertEqual(store.filteredItems.map(\.id), [item.id])
    }

    func testItemLabelsAreSearchableNormalizedEncryptedAndPersisted() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let item = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Roadmap",
            payload: ClipboardPayload(text: "ordinary body")
        ))

        store.setLabels([" customer ", "Customer", "", "Launch Plan"], for: item.id)
        store.searchQuery = "launch plan"

        XCTAssertEqual(store.snapshot.items.first?.labels, ["customer", "Launch Plan"])
        XCTAssertEqual(store.filteredItems.map(\.id), [item.id])

        let rawStoreData = try Data(contentsOf: harness.snapshotStore.fileURL)
        let rawStoreText = String(decoding: rawStoreData, as: UTF8.self)
        XCTAssertFalse(rawStoreText.contains("Launch Plan"))
        XCTAssertFalse(rawStoreText.contains("customer"))

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertEqual(reloaded.snapshot.items.first?.labels, ["customer", "Launch Plan"])
    }

    func testRenamedTitlesAndLabelsPreservePayloadAppearInPinboardsAndSyncEncrypted() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let item = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Original Title",
            payload: ClipboardPayload(text: "Original copied body")
        ))
        let pinboardID = store.snapshot.pinboards[0].id
        store.pinItem(item.id, to: pinboardID)

        store.renameItem(item.id, to: "Client Launch Board")
        store.setLabels([" Important ", "Launch", "important"], for: item.id)

        let updated = try XCTUnwrap(store.snapshot.items.first)
        XCTAssertEqual(updated.title, "Client Launch Board")
        XCTAssertEqual(updated.payload.text, "Original copied body")
        XCTAssertEqual(updated.labels, ["Important", "Launch"])
        XCTAssertEqual(updated.visualPreview.headline, "Client Launch Board")

        store.searchQuery = "client launch"
        XCTAssertEqual(store.filteredItems.map(\.id), [item.id])
        store.searchQuery = "important"
        XCTAssertEqual(store.filteredItems.map(\.id), [item.id])

        store.selectedScope = .pinboard(pinboardID)
        store.searchQuery = "launch"
        XCTAssertEqual(store.filteredItems.map(\.id), [item.id])

        store.snapshot.sync = SyncConfiguration(
            provider: .cloudKit,
            isCloudSyncEnabled: true,
            cloudKitContainerIdentifier: "iCloud.com.example.PasteBuddy",
            keyHierarchyVersion: 1,
            isCloudKitCapabilityConfigured: true
        )
        let package = try CloudSyncPackageBuilder(encryptor: harness.encryptionService)
            .makeUploadPackage(from: store.snapshot)
        let packageString = String(decoding: try JSONEncoder.pasteBuddy.encode(package), as: UTF8.self)
        XCTAssertFalse(packageString.contains("Client Launch Board"))
        XCTAssertFalse(packageString.contains("Important"))
        let decrypted = try harness.encryptionService.decrypt(PasteBuddySnapshot.self, from: package.encryptedSnapshot)
        XCTAssertEqual(decrypted.items.first?.title, "Client Launch Board")
        XCTAssertEqual(decrypted.items.first?.labels, ["Important", "Launch"])
        XCTAssertEqual(decrypted.pinboards.first?.itemIDs, [item.id])

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertEqual(reloaded.snapshot.items.first?.title, "Client Launch Board")
        XCTAssertEqual(reloaded.snapshot.items.first?.labels, ["Important", "Launch"])
    }

    func testItemLabelsStayInPasteStackWhenEditedAndCanBeRemoved() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.startPasteStack()
        let item = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Stacked",
            payload: ClipboardPayload(text: "stacked body")
        ))

        store.addLabel("Reusable", to: item.id)
        XCTAssertEqual(store.pasteStackItems.first?.labels, ["Reusable"])

        store.removeLabel("reusable", from: item.id)
        XCTAssertEqual(store.snapshot.items.first?.labels, [])
        XCTAssertEqual(store.pasteStackItems.first?.labels, [])
    }

    func testReusableContentCategoryIsInferredAndSearchable() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let color = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Design",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Brand Color",
            payload: ClipboardPayload(text: "#70C1B3")
        ))
        let code = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Editor",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Swift Helper",
            payload: ClipboardPayload(text: "func makeTitle() -> String { return \"PasteBuddy\" }")
        ))
        let template = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Mail",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Reply Template",
            payload: ClipboardPayload(text: "Hi {{name}}, thanks for reaching out.")
        ))

        XCTAssertEqual(color.reuseCategory, .color)
        XCTAssertEqual(code.reuseCategory, .code)
        XCTAssertEqual(template.reuseCategory, .template)

        store.searchQuery = "code"
        XCTAssertEqual(store.filteredItems.map(\.id), [code.id])
    }

    func testReusableContentCategoryCanBeOverriddenEncryptedAndSyncedToPasteStack() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.startPasteStack()
        let item = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Reusable Note",
            payload: ClipboardPayload(text: "Reusable note body")
        ))

        store.setReuseCategory(.template, for: item.id)

        XCTAssertEqual(store.snapshot.items.first?.reuseCategory, .template)
        XCTAssertEqual(store.pasteStackItems.first?.reuseCategory, .template)

        let rawStoreData = try Data(contentsOf: harness.snapshotStore.fileURL)
        let rawStoreText = String(decoding: rawStoreData, as: UTF8.self)
        XCTAssertFalse(rawStoreText.contains("template"))
        XCTAssertFalse(rawStoreText.contains("Reusable Note"))

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertEqual(reloaded.snapshot.items.first?.reuseCategory, .template)
    }

    func testReusablePinboardSupportsMixedSnippetTemplateCodeColorAndAssetCollections() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.createPinboard(named: "Reusable Kit")
        let pinboardID = store.snapshot.pinboards.last!.id
        let richSnippet = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Pages",
            deviceName: "Test Mac",
            contentType: .text,
            title: "VIP Rich Snippet",
            payload: ClipboardPayload(
                text: "VIP launch reply",
                htmlString: "<strong>VIP launch reply</strong>",
                rtfData: Data("{\\rtf1 VIP launch reply}".utf8)
            )
        ))
        let link = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Test Mac",
            contentType: .url,
            title: "Research Link",
            payload: ClipboardPayload(urlString: "https://example.com/research")
        ))
        let imageAsset = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Launch Image Asset",
            payload: ClipboardPayload(imageData: Data([0x01, 0x02]), ocrText: "Hero asset copy"),
            ocrState: .completed(Date())
        ))
        let fileAsset = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Finder",
            deviceName: "Test Mac",
            contentType: .file,
            title: "Design Files",
            payload: ClipboardPayload(fileURLStrings: [
                "file:///Users/example/Logo.sketch",
                "file:///Users/example/Palette.ase"
            ])
        ))
        let color = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Design",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Brand Color",
            payload: ClipboardPayload(text: "#70C1B3")
        ))
        let code = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Xcode",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Badge Helper",
            payload: ClipboardPayload(text: "func makeBadge() -> String { return \"VIP\" }")
        ))
        let template = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Mail",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Reply Template",
            payload: ClipboardPayload(text: "Hi {{name}}, here is the launch update.")
        ))

        store.pinItems(
            [richSnippet.id, link.id, imageAsset.id, fileAsset.id, color.id, code.id, template.id],
            to: pinboardID
        )
        store.selectedScope = .pinboard(pinboardID)

        XCTAssertEqual(richSnippet.reuseCategory, .snippet)
        XCTAssertEqual(link.reuseCategory, .general)
        XCTAssertEqual(imageAsset.reuseCategory, .asset)
        XCTAssertEqual(fileAsset.reuseCategory, .asset)
        XCTAssertEqual(color.reuseCategory, .color)
        XCTAssertEqual(code.reuseCategory, .code)
        XCTAssertEqual(template.reuseCategory, .template)
        XCTAssertEqual(store.filteredItems.map(\.id), [
            richSnippet.id,
            link.id,
            imageAsset.id,
            fileAsset.id,
            color.id,
            code.id,
            template.id
        ])
        XCTAssertEqual(store.quickPasteItem(atOneBasedIndex: 1)?.id, richSnippet.id)

        store.searchQuery = "template"
        XCTAssertEqual(store.filteredItems.map(\.id), [template.id])
        store.searchQuery = "asset"
        XCTAssertEqual(Set(store.filteredItems.map(\.id)), Set([imageAsset.id, fileAsset.id]))

        let rawStoreText = String(decoding: try Data(contentsOf: harness.snapshotStore.fileURL), as: UTF8.self)
        XCTAssertFalse(rawStoreText.contains("VIP launch reply"))
        XCTAssertFalse(rawStoreText.contains("#70C1B3"))
        XCTAssertFalse(rawStoreText.contains("Reusable Kit"))

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()
        let reloadedPinboard = try XCTUnwrap(reloaded.snapshot.pinboards.first(where: { $0.id == pinboardID }))
        let reloadedRichSnippet = try XCTUnwrap(reloaded.snapshot.items.first(where: { $0.id == richSnippet.id }))
        let reloadedFileAsset = try XCTUnwrap(reloaded.snapshot.items.first(where: { $0.id == fileAsset.id }))

        XCTAssertEqual(reloadedPinboard.itemIDs, [
            richSnippet.id,
            link.id,
            imageAsset.id,
            fileAsset.id,
            color.id,
            code.id,
            template.id
        ])
        XCTAssertEqual(reloadedRichSnippet.payload.htmlString, "<strong>VIP launch reply</strong>")
        XCTAssertEqual(reloadedRichSnippet.payload.rtfData, Data("{\\rtf1 VIP launch reply}".utf8))
        XCTAssertEqual(reloadedFileAsset.payload.allFileURLStrings, [
            "file:///Users/example/Logo.sketch",
            "file:///Users/example/Palette.ase"
        ])
    }

    func testRemoveSelectedItemsIsUndoableAsAGroup() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let now = Date()
        let older = store.addCapturedItem(ClipboardItem(
            createdAt: now.addingTimeInterval(-1),
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Older",
            payload: ClipboardPayload(text: "older")
        ))
        let newer = store.addCapturedItem(ClipboardItem(
            createdAt: now,
            sourceAppName: "Pages",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Newer",
            payload: ClipboardPayload(text: "newer")
        ))
        let pinboardID = store.snapshot.pinboards[0].id
        store.pinItem(older.id, to: pinboardID)
        store.pinItem(newer.id, to: pinboardID)
        store.setSelectedItemIDs([older.id, newer.id])
        XCTAssertEqual(store.selectedItemsInDisplayOrder.map(\.id), [newer.id, older.id])

        store.removeSelectedItems()

        XCTAssertEqual(store.snapshot.items.map(\.id), [])
        XCTAssertEqual(store.snapshot.pinboards[0].itemIDs, [])
        XCTAssertEqual(store.lastDeletedItems.map(\.item.id), [newer.id, older.id])
        XCTAssertTrue(store.canUndoDelete)

        store.undoLastDeletion()

        XCTAssertEqual(store.snapshot.items.map(\.id), [newer.id, older.id])
        XCTAssertEqual(store.snapshot.pinboards[0].itemIDs, [newer.id, older.id])
        XCTAssertEqual(store.selectedItem?.id, newer.id)
        XCTAssertFalse(store.canUndoDelete)
    }

    func testOpenableURLIsAvailableForLinksAndFilesOnly() {
        let link = ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Test Mac",
            contentType: .url,
            title: "Example",
            payload: ClipboardPayload(urlString: "https://example.com/path")
        )
        let file = ClipboardItem(
            sourceAppName: "Finder",
            deviceName: "Test Mac",
            contentType: .file,
            title: "Report",
            payload: ClipboardPayload(fileURLString: "file:///Users/example/report.pdf")
        )
        let text = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Text",
            payload: ClipboardPayload(text: "hello")
        )

        XCTAssertEqual(link.openableURL?.absoluteString, "https://example.com/path")
        XCTAssertEqual(file.openableURL?.absoluteString, "file:///Users/example/report.pdf")
        XCTAssertNil(text.openableURL)
    }

    func testCloudKitPinboardShareInvitationSubscriptionIsSilentAndRecipientScoped() throws {
        let keyExchangeService = PinboardShareKeyExchangeService()
        let invitationService = PinboardShareInvitationService(keyExchangeService: keyExchangeService)
        let factory = CloudKitPinboardShareRecordFactory()
        let participantIdentity = keyExchangeService.makeIdentity()
        let recipientIdentity = try invitationService.publicIdentity(
            displayName: "Collaborator",
            identity: participantIdentity,
            createdAt: Date(timeIntervalSince1970: 100)
        )

        let subscription = try factory.makeInvitationSubscription(
            recipientPublicKeyFingerprint: recipientIdentity.publicKeyFingerprint
        )

        XCTAssertEqual(
            subscription.subscriptionID,
            try factory.makeInvitationSubscriptionID(
                recipientPublicKeyFingerprint: recipientIdentity.publicKeyFingerprint
            )
        )
        XCTAssertEqual(subscription.recordType, CloudKitPinboardShareRecordFactory.invitationRecordType)
        XCTAssertTrue(subscription.predicate.predicateFormat.contains(recipientIdentity.publicKeyFingerprint))
        XCTAssertTrue(subscription.notificationInfo?.shouldSendContentAvailable == true)
        XCTAssertNil(subscription.notificationInfo?.alertBody)
        XCTAssertFalse(subscription.subscriptionID.contains(participantIdentity.privateKeyData.base64EncodedString()))

        XCTAssertThrowsError(
            try factory.makeInvitationSubscription(recipientPublicKeyFingerprint: "   ")
        )
    }

    func testStructuredFiltersComposeWithKeywordSearch() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.addCapturedItem(ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Work Mac",
            contentType: .url,
            title: "Launch plan",
            payload: ClipboardPayload(urlString: "https://example.com/launch")
        ))
        store.addCapturedItem(ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Work Mac",
            contentType: .image,
            title: "Screenshot",
            payload: ClipboardPayload(imageData: Data([0x01]), ocrText: "Launch checklist")
        ))
        store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Home Mac",
            contentType: .text,
            title: "Launch notes",
            payload: ClipboardPayload(text: "Launch checklist")
        ))

        store.searchQuery = "launch"
        store.contentTypeFilter = .image
        store.sourceAppFilter = "Preview"
        store.deviceFilter = "Work Mac"

        XCTAssertEqual(store.filteredItems.map(\.title), ["Screenshot"])
    }

    func testFilterSuggestionsMatchAvailableStructuredFilters() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.addCapturedItem(ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Work Mac",
            contentType: .url,
            title: "Launch plan",
            payload: ClipboardPayload(urlString: "https://example.com/launch")
        ))
        store.addCapturedItem(ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Design iPad",
            contentType: .image,
            title: "Screenshot",
            payload: ClipboardPayload(imageData: Data([0x01]), ocrText: "Launch checklist")
        ))

        XCTAssertTrue(store.filterSuggestions(matching: "saf", limit: 20).contains {
            $0.kind == .sourceApp && $0.value == "Safari"
        })
        XCTAssertTrue(store.filterSuggestions(matching: "image", limit: 20).contains {
            $0.kind == .contentType && $0.value == ClipboardContentType.image.rawValue
        })
        XCTAssertTrue(store.filterSuggestions(matching: "ipad", limit: 20).contains {
            $0.kind == .device && $0.value == "Design iPad"
        })
        XCTAssertTrue(store.filterSuggestions(matching: "last", limit: 20).contains {
            $0.kind == .date && $0.value == ClipboardDateFilter.last7Days.rawValue
        })

        store.sourceAppFilter = "Safari"
        XCTAssertFalse(store.filterSuggestions(matching: "saf", limit: 20).contains {
            $0.kind == .sourceApp && $0.value == "Safari"
        })
    }

    func testApplyingFilterSuggestionAndClearingSingleFilterUpdatesVisibleResults() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.addCapturedItem(ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Work Mac",
            contentType: .url,
            title: "Launch plan",
            payload: ClipboardPayload(urlString: "https://example.com/launch")
        ))
        store.addCapturedItem(ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Work Mac",
            contentType: .image,
            title: "Screenshot",
            payload: ClipboardPayload(imageData: Data([0x01]), ocrText: "Launch checklist")
        ))

        let imageSuggestion = try XCTUnwrap(store.filterSuggestions(matching: "image", limit: 20).first {
            $0.kind == .contentType && $0.value == ClipboardContentType.image.rawValue
        })
        store.applyFilterSuggestion(imageSuggestion)

        XCTAssertEqual(store.contentTypeFilter, .image)
        XCTAssertEqual(store.filteredItems.map(\.title), ["Screenshot"])
        XCTAssertEqual(store.activeFilterSummaries.map(\.id), ["contentType:image"])

        store.clearFilter(.contentType)

        XCTAssertNil(store.contentTypeFilter)
        XCTAssertTrue(store.activeFilterSummaries.isEmpty)
        XCTAssertEqual(Set(store.filteredItems.map(\.title)), Set(["Launch plan", "Screenshot"]))
    }

    func testDateFilterRestrictsOldItems() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let now = Date()
        let oldDate = Calendar.current.date(byAdding: .day, value: -10, to: now)!

        store.addCapturedItem(ClipboardItem(
            createdAt: oldDate,
            updatedAt: oldDate,
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Old",
            payload: ClipboardPayload(text: "old")
        ))
        store.addCapturedItem(ClipboardItem(
            createdAt: now,
            updatedAt: now,
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Fresh",
            payload: ClipboardPayload(text: "fresh")
        ))

        store.dateFilter = .last7Days

        XCTAssertEqual(store.filteredItems.map(\.title), ["Fresh"])
    }

    func testActiveFilterSummariesExposeAllStructuredFiltersAndClearTogether() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.addCapturedItem(ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Work Mac",
            contentType: .url,
            title: "Link",
            payload: ClipboardPayload(urlString: "https://example.com")
        ))
        store.contentTypeFilter = .url
        store.sourceAppFilter = "Safari"
        store.deviceFilter = "Work Mac"
        store.dateFilter = .today

        XCTAssertTrue(store.hasActiveFilters)
        XCTAssertEqual(
            Set(store.activeFilterSummaries.map(\.kind)),
            Set([.contentType, .sourceApp, .device, .date])
        )
        XCTAssertEqual(store.filteredItems.map(\.title), ["Link"])

        store.clearFilters()

        XCTAssertFalse(store.hasActiveFilters)
        XCTAssertTrue(store.activeFilterSummaries.isEmpty)
        XCTAssertNil(store.contentTypeFilter)
        XCTAssertNil(store.sourceAppFilter)
        XCTAssertNil(store.deviceFilter)
        XCTAssertEqual(store.dateFilter, .any)
    }

    func testClearFiltersRestoresAllItems() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.addCapturedItem(ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Work Mac",
            contentType: .url,
            title: "Link",
            payload: ClipboardPayload(urlString: "https://example.com")
        ))
        store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Work Mac",
            contentType: .text,
            title: "Text",
            payload: ClipboardPayload(text: "note")
        ))

        store.contentTypeFilter = .url
        XCTAssertEqual(store.filteredItems.map(\.title), ["Link"])

        store.clearFilters()
        XCTAssertEqual(Set(store.filteredItems.map(\.title)), Set(["Link", "Text"]))
    }

    func testOCRUpdateDoesNotChangeRecopyTimestamp() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let capturedAt = Date().addingTimeInterval(-60)
        let original = store.addCapturedItem(ClipboardItem(
            createdAt: capturedAt,
            updatedAt: capturedAt,
            sourceAppName: "Screenshot",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Receipt",
            payload: ClipboardPayload(imageData: Data([0x01])),
            ocrState: .pending(capturedAt)
        ))

        store.updateOCRText("total due", for: original.id)

        XCTAssertEqual(store.snapshot.items.first?.updatedAt, original.updatedAt)
    }

    func testFilteredItemsNormalizeSearchQueryForDiacriticsAndCase() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let cafe = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Café Rendez-vous",
            payload: ClipboardPayload(text: "Café Rendez-vous at noon")
        ))
        _ = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Grocery run",
            payload: ClipboardPayload(text: "buy oat milk")
        ))

        store.searchQuery = "  CAFE rendez  "

        XCTAssertEqual(store.filteredItems.map(\.id), [cafe.id])
        XCTAssertEqual(store.filteredItemCount(for: .history), 1)
    }

    func testSearchPreservesInteriorSubstringMatches() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let item = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Beta Launch",
            payload: ClipboardPayload(text: "beta launch plan")
        ))

        store.searchQuery = "eta laun"

        XCTAssertEqual(store.filteredItems.map(\.id), [item.id])
    }

    func testRepositoryBackedSearchMatchesInMemoryResultsBeforeAndAfterFlush() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let repository = ClipboardItemRepository(database: database)
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository,
            saveDebounceNanoseconds: 60_000_000_000
        )
        let cafe = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Café Rendez-vous ✅",
            payload: ClipboardPayload(text: "Café launch checklist ✅")
        ))
        let resume = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Résumé Rocket 🚀",
            payload: ClipboardPayload(text: "Résumé rocket follow-up 🚀")
        ))
        let shortTerm = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Go Quickly",
            payload: ClipboardPayload(text: "go quickly and launch safely")
        ))
        _ = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Plain Grocery",
            payload: ClipboardPayload(text: "buy oat milk")
        ))

        let expectedIDsByQuery = [
            ("  CAFE launch  ", [cafe.id]),
            ("resume rocket", [resume.id]),
            ("go launch", [shortTerm.id]),
            ("🚀", [resume.id])
        ]

        XCTAssertNil(store.repositorySyncedDataRevision)
        for (query, expectedIDs) in expectedIDsByQuery {
            store.searchQuery = query
            XCTAssertEqual(store.filteredItems.map(\.id), expectedIDs)
        }

        await store.flushPendingSave()

        XCTAssertEqual(store.repositorySyncedDataRevision, store.dataRevision)
        for (query, expectedIDs) in expectedIDsByQuery {
            store.searchQuery = query
            XCTAssertEqual(store.filteredItems.map(\.id), expectedIDs)
            XCTAssertEqual(store.filteredItemCount(for: .history), expectedIDs.count)
        }
    }

    func testRepositoryBackedSearchPreservesInteriorSubstringMatches() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
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
            title: "Beta Launch",
            payload: ClipboardPayload(text: "beta launch plan")
        ))

        await store.flushPendingSave()
        store.searchQuery = "eta laun"

        XCTAssertEqual(store.filteredItems.map(\.id), [item.id])
        XCTAssertEqual(store.filteredItemCount(for: .history), 1)
    }

    func testSearchDocumentRefreshKeepsDedupeIndexCurrentAfterTextEditAndOCR() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let original = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Original",
            payload: ClipboardPayload(text: "alpha launch note")
        ))

        store.updateTextItem(original.id, to: "beta launch note")

        let updated = try XCTUnwrap(store.snapshot.items.first { $0.id == original.id })
        XCTAssertTrue(updated.matches("beta launch"))
        XCTAssertFalse(updated.matches("alpha launch"))

        let recapturedOldPayload = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Old Alpha",
            payload: ClipboardPayload(text: "alpha launch note")
        ))
        XCTAssertNotEqual(recapturedOldPayload.id, original.id)

        let recapturedUpdatedPayload = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Duplicate Beta",
            payload: ClipboardPayload(text: "beta launch note")
        ))
        XCTAssertEqual(recapturedUpdatedPayload.id, original.id)
        XCTAssertEqual(store.snapshot.items.count, 2)

        let image = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Screenshot",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Pending OCR",
            payload: ClipboardPayload(imageData: Data([0x01, 0x02])),
            ocrState: .pending(Date())
        ))
        XCTAssertFalse(image.matches("invoice total"))

        store.updateOCRText("Invoice total 42 dollars", for: image.id)

        let updatedImage = try XCTUnwrap(store.snapshot.items.first { $0.id == image.id })
        XCTAssertTrue(updatedImage.matches("invoice total"))
        XCTAssertEqual(updatedImage.visualPreview.body, "Invoice total 42 dollars")
    }

    func testPruneHistoryKeepsPinnedSelectionAndPasteStackMembershipConsistentAtScale() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let now = Date(timeIntervalSince1970: 3_000_000)
        let items = (0..<500).map { index in
            ClipboardItem(
                createdAt: now.addingTimeInterval(TimeInterval(-index)),
                updatedAt: now.addingTimeInterval(TimeInterval(-index)),
                sourceAppName: index.isMultiple(of: 2) ? "Notes" : "Safari",
                deviceName: "Test Mac",
                contentType: .text,
                title: "History \(index)",
                payload: ClipboardPayload(text: "body \(index)")
            )
        }
        let pinnedIDs = [items[420].id, items[450].id]
        let pinboard = Pinboard(name: "Pinned", colorHex: "#4EA7FC", itemIDs: pinnedIDs)
        let stalePasteStackItem = ClipboardItem(
            sourceAppName: "Deleted",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Deleted",
            payload: ClipboardPayload(text: "gone")
        )
        store.snapshot = PasteBuddySnapshot(items: items, pinboards: [pinboard])
        store.markHistoryUnlockedForTesting()
        store.pasteStackItems = [items[0], items[150], items[420], stalePasteStackItem]
        store.setSelectedItemIDs(Set([items[0].id, items[150].id, items[420].id, stalePasteStackItem.id]))

        store.updateMaxHistoryItems(100)

        let remainingIDs = Set(store.snapshot.items.map(\.id))
        XCTAssertTrue(pinnedIDs.allSatisfy { remainingIDs.contains($0) })
        XCTAssertFalse(remainingIDs.contains(items[150].id))
        XCTAssertTrue(store.pasteStackItems.map(\.id).allSatisfy { remainingIDs.contains($0) })
        XCTAssertTrue(store.pasteStackItems.contains(where: { $0.id == items[420].id }))
        XCTAssertFalse(store.pasteStackItems.contains(where: { $0.id == items[150].id }))
        XCTAssertFalse(store.pasteStackItems.contains(where: { $0.id == stalePasteStackItem.id }))
        XCTAssertTrue(store.selectedItemIDs.allSatisfy { remainingIDs.contains($0) })
        XCTAssertLessThanOrEqual(store.snapshot.items.filter { !pinnedIDs.contains($0.id) }.count, 100)
    }

    func testGRDBRepositoryUsesWALFTSFiltersAndPaging() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let now = Date(timeIntervalSince1970: 1_000_000)
        let olderText = ClipboardItem(
            createdAt: now.addingTimeInterval(-300),
            updatedAt: now.addingTimeInterval(-300),
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Customer Reply",
            labels: ["VIP Client"],
            payload: ClipboardPayload(text: "Reusable customer reply body")
        )
        let image = ClipboardItem(
            createdAt: now.addingTimeInterval(-120),
            updatedAt: now.addingTimeInterval(-120),
            sourceAppName: "Screenshot",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Launch Screenshot",
            payload: ClipboardPayload(
                imageData: Data([0x01, 0x02]),
                ocrText: "Quarterly launch checklist"
            ),
            ocrState: .completed(now)
        )
        let link = ClipboardItem(
            createdAt: now,
            updatedAt: now,
            sourceAppName: "Safari",
            deviceName: "iPhone",
            contentType: .url,
            title: "Roadmap",
            payload: ClipboardPayload(urlString: "https://example.com/roadmap")
        )
        let pinboard = Pinboard(
            name: "Research",
            colorHex: "#4EA7FC",
            itemIDs: [image.id, olderText.id],
            createdAt: now,
            updatedAt: now
        )
        var snapshot = PasteBuddySnapshot(
            items: [link, image, olderText],
            pinboards: [pinboard]
        )
        snapshot.general.launchAtLoginEnabled = true

        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        XCTAssertEqual(try database.journalMode().lowercased(), "wal")

        let repository = ClipboardItemRepository(database: database)
        try repository.replaceAll(with: snapshot)

        XCTAssertEqual(try repository.itemCount(), 3)
        XCTAssertEqual(try repository.fetchPage(ClipboardItemPageRequest(limit: 2)).map(\.id), [link.id, image.id])
        XCTAssertEqual(try repository.fetchPage(ClipboardItemPageRequest(limit: 2, offset: 2)).map(\.id), [olderText.id])
        XCTAssertEqual(try repository.fetchPage(ClipboardItemPageRequest(searchQuery: "launch checklist")).map(\.id), [image.id])
        XCTAssertEqual(
            try repository.fetchPage(ClipboardItemPageRequest(contentType: .url, sourceAppName: "Safari", deviceName: "iPhone")).map(\.id),
            [link.id]
        )
        XCTAssertEqual(try repository.fetchPage(ClipboardItemPageRequest(pinboardID: pinboard.id)).map(\.id), [image.id, olderText.id])
        XCTAssertEqual(try repository.availableSourceApps(), ["Notes", "Safari", "Screenshot"])
        XCTAssertEqual(try repository.availableDevices(), ["Test Mac", "iPhone"])

        let exported = try repository.exportSnapshot()
        XCTAssertEqual(exported.items.map(\.id), snapshot.items.map(\.id))
        XCTAssertEqual(exported.pinboards.map(\.itemIDs), [[image.id, olderText.id]])
        XCTAssertTrue(exported.general.launchAtLoginEnabled)
    }

    func testGRDBRepositoryOCRUpdateRefreshesFullTextIndex() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let image = ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Pending Screenshot",
            payload: ClipboardPayload(imageData: Data([0xff])),
            ocrState: .pending(Date())
        )
        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let repository = ClipboardItemRepository(database: database)

        try repository.replaceAll(with: PasteBuddySnapshot(items: [image]))

        XCTAssertTrue(try repository.fetchPage(ClipboardItemPageRequest(searchQuery: "receipt total")).isEmpty)

        try repository.updateOCRText("Receipt total 42 dollars", for: image.id)

        let matches = try repository.fetchPage(ClipboardItemPageRequest(searchQuery: "receipt total"))
        XCTAssertEqual(matches.map(\.id), [image.id])
        XCTAssertEqual(matches.first?.searchDocument.contentHash, image.searchDocument.contentHash)
        XCTAssertNotEqual(matches.first?.searchDocument.searchHash, image.searchDocument.searchHash)
        guard case .completed = matches.first?.ocrState else {
            return XCTFail("Expected the stored OCR state to be completed.")
        }
    }

    func testQueryAndPasteStackStateKeepRepositorySyncedToDataRevision() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        harness.snapshotStore.storageMode = .standard

        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let repository = ClipboardItemRepository(database: database)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let items = (0..<125).map { index in
            ClipboardItem(
                createdAt: now.addingTimeInterval(TimeInterval(-index)),
                updatedAt: now.addingTimeInterval(TimeInterval(-index)),
                sourceAppName: index.isMultiple(of: 2) ? "Notes" : "Safari",
                deviceName: "Test Mac",
                contentType: .text,
                title: "Item \(index)",
                payload: ClipboardPayload(text: index == 124 ? "sqlite-only search needle" : "body \(index)")
            )
        }
        let pinboard = Pinboard(
            name: "Repository Scope",
            colorHex: "#4EA7FC",
            itemIDs: [items[3].id, items[4].id]
        )
        try harness.snapshotStore.save(PasteBuddySnapshot(items: items, pinboards: [pinboard]))

        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository
        )
        store.load()

        let loadedDataRevision = store.dataRevision
        let loadedQueryRevision = store.queryRevision

        XCTAssertEqual(store.repositorySyncedDataRevision, loadedDataRevision)

        store.searchQuery = "sqlite-only search needle"

        XCTAssertEqual(store.dataRevision, loadedDataRevision)
        XCTAssertGreaterThan(store.queryRevision, loadedQueryRevision)
        XCTAssertEqual(store.repositorySyncedDataRevision, store.dataRevision)
        XCTAssertEqual(store.filteredItems.map(\.id), [items[124].id])

        store.searchQuery = ""
        store.contentTypeFilter = .text

        XCTAssertEqual(store.dataRevision, loadedDataRevision)
        XCTAssertEqual(store.repositorySyncedDataRevision, store.dataRevision)
        XCTAssertEqual(store.filteredItems.count, 100)
        XCTAssertEqual(store.filteredItemCount(for: .history), 125)

        store.selectedScope = .pinboard(pinboard.id)

        XCTAssertEqual(store.dataRevision, loadedDataRevision)
        XCTAssertEqual(store.repositorySyncedDataRevision, store.dataRevision)
        XCTAssertEqual(store.mainListItemsSnapshot.map(\.id), [items[3].id, items[4].id])

        store.startPasteStack()
        store.reversePasteStackDirection()

        XCTAssertEqual(store.dataRevision, loadedDataRevision)
        XCTAssertEqual(store.repositorySyncedDataRevision, store.dataRevision)

        let captured = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Terminal",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Fresh SQLite Sync",
            payload: ClipboardPayload(text: "fresh repository sync target")
        ))

        XCTAssertGreaterThan(store.dataRevision, loadedDataRevision)
        XCTAssertEqual(store.repositorySyncedDataRevision, store.dataRevision)
        XCTAssertEqual(
            try repository.fetchPage(ClipboardItemPageRequest(searchQuery: "fresh repository sync target")).map(\.id),
            [captured.id]
        )
    }

    func testHistoryMainListUsesStableFullHistoryWhenRepositoryWindowIsLimited() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        harness.snapshotStore.storageMode = .standard

        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let repository = ClipboardItemRepository(database: database)
        let now = Date(timeIntervalSince1970: 3_000_000)
        let items = (0..<125).map { index in
            ClipboardItem(
                createdAt: now.addingTimeInterval(TimeInterval(-index)),
                updatedAt: now.addingTimeInterval(TimeInterval(-index)),
                sourceAppName: "Notes",
                deviceName: "Test Mac",
                contentType: .text,
                title: "History Item \(index)",
                payload: ClipboardPayload(text: "history body \(index)")
            )
        }
        try harness.snapshotStore.save(PasteBuddySnapshot(items: items))

        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository
        )
        store.load()

        XCTAssertEqual(store.mainListItemsSnapshot.count, 125)
        XCTAssertEqual(store.mainListItemsSnapshot.first?.title, "History Item 0")
        XCTAssertEqual(store.mainListItemsSnapshot.last?.title, "History Item 124")
        XCTAssertEqual(store.filteredItems.count, 100)
        XCTAssertEqual(store.filteredItemCount(for: .history), 125)

        store.searchQuery = "history body"

        XCTAssertEqual(store.repositorySyncedDataRevision, store.dataRevision)
        XCTAssertEqual(store.mainListItemsSnapshot.count, 125)
        XCTAssertEqual(store.filteredItems.count, 100)
        XCTAssertEqual(store.filteredItemCount(for: .history), 125)

        let beyondRepositoryPageItem = items[124]
        XCTAssertFalse(store.filteredItems.contains(where: { $0.id == beyondRepositoryPageItem.id }))

        store.setSelectedItemIDs([beyondRepositoryPageItem.id])

        XCTAssertEqual(store.selectedItemID, beyondRepositoryPageItem.id)
        XCTAssertEqual(store.selectedItemsInDisplayOrder.map(\.id), [beyondRepositoryPageItem.id])
    }

    func testRepositoryBackedHistoryPagesExposeItemsBeyondTheInitialWindowWithoutGlobalScopeMutation() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let repository = ClipboardItemRepository(database: database)
        let now = Date(timeIntervalSince1970: 3_500_000)
        let items = (0..<225).map { index in
            ClipboardItem(
                createdAt: now.addingTimeInterval(TimeInterval(-index)),
                updatedAt: now.addingTimeInterval(TimeInterval(-index)),
                sourceAppName: "Notes",
                deviceName: "Test Mac",
                contentType: .text,
                title: "Paged Item \(index)",
                payload: ClipboardPayload(text: "paged history body \(index)")
            )
        }
        try harness.snapshotStore.save(PasteBuddySnapshot(items: items))
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository
        )
        store.load()
        let originalScope = store.selectedScope
        let originalQueryRevision = store.queryRevision

        let firstPage = await store.filteredItemsPageAndCount(for: .history, offset: 0, limit: 100)
        let secondPage = await store.filteredItemsPageAndCount(for: .history, offset: 100, limit: 100)
        let finalPage = await store.filteredItemsPageAndCount(for: .history, offset: 200, limit: 100)

        XCTAssertEqual(firstPage.items.map(\.id), Array(items[0..<100]).map(\.id))
        XCTAssertEqual(secondPage.items.map(\.id), Array(items[100..<200]).map(\.id))
        XCTAssertEqual(finalPage.items.map(\.id), Array(items[200..<225]).map(\.id))
        XCTAssertEqual(firstPage.totalCount, 225)
        XCTAssertEqual(secondPage.totalCount, 225)
        XCTAssertEqual(finalPage.totalCount, 225)
        XCTAssertEqual(store.selectedScope, originalScope)
        XCTAssertEqual(store.queryRevision, originalQueryRevision)
    }

    func testInMemoryHistoryPageFallbackFiltersOffMainThread() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.snapshot = PasteBuddySnapshot(items: (0..<500).map { index in
            ClipboardItem(
                sourceAppName: "Notes",
                deviceName: "Test Mac",
                contentType: .text,
                title: "Fallback \(index)",
                payload: ClipboardPayload(text: "fallback body \(index)")
            )
        })

        let page = await store.filteredItemsPageAndCount(for: .history, offset: 100, limit: 50)

        XCTAssertEqual(page.items.count, 50)
        XCTAssertEqual(page.totalCount, 500)
        XCTAssertEqual(store.lastInMemoryPageQueryRanOnMainThreadForTesting, false)
    }

    func testReadOnlyRepositorySearchPagesOffMainThreadWithoutMutatingGlobalUIState() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        harness.snapshotStore.storageMode = .standard

        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let repository = ClipboardItemRepository(database: database)
        let now = Date(timeIntervalSince1970: 3_750_000)
        let items = (0..<140).map { index in
            ClipboardItem(
                createdAt: now.addingTimeInterval(TimeInterval(-index)),
                updatedAt: now.addingTimeInterval(TimeInterval(-index)),
                sourceAppName: "Notes",
                deviceName: "Test Mac",
                contentType: .text,
                title: "Repository Needle \(index)",
                payload: ClipboardPayload(text: "repository needle body \(index)")
            )
        }
        try repository.replaceAll(with: PasteBuddySnapshot(items: items))
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository
        )
        store.load()
        store.selectedScope = .pasteStack
        store.searchQuery = "leave this UI query alone"
        let queryRevision = store.queryRevision
        let fetchCount = repository.fetchPageInvocationCount

        let page = try await store.searchItemsPage(query: "repository needle", offset: 120, limit: 5)

        XCTAssertEqual(page.map(\.id), Array(items[120..<125]).map(\.id))
        XCTAssertEqual(repository.fetchPageInvocationCount, fetchCount + 1)
        XCTAssertEqual(repository.lastAsyncFetchPageRanOnMainThreadForTesting, false)
        XCTAssertEqual(store.searchQuery, "leave this UI query alone")
        XCTAssertEqual(store.selectedScope, .pasteStack)
        XCTAssertEqual(store.queryRevision, queryRevision)

        let fallbackStore = PasteBuddyStore(diskStore: harness.snapshotStore)
        fallbackStore.snapshot = PasteBuddySnapshot(items: items)
        let fallbackPage = try await fallbackStore.searchItemsPage(
            query: "repository needle",
            offset: 120,
            limit: 5
        )
        XCTAssertEqual(
            fallbackPage.map(\.id),
            page.map(\.id)
        )
        XCTAssertEqual(fallbackStore.lastInMemoryPageQueryRanOnMainThreadForTesting, false)
    }

    func testRepositoryFallbackPreservesCanonicalSnapshotOrderInsteadOfResortingByDate() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let items = [
            ClipboardItem(
                createdAt: Date(timeIntervalSince1970: 600),
                sourceAppName: "Messages",
                deviceName: "Remote iPhone",
                contentType: .text,
                title: "Canonical 1",
                payload: ClipboardPayload(text: "canonical order match")
            ),
            ClipboardItem(
                createdAt: Date(timeIntervalSince1970: 50),
                sourceAppName: "Mail",
                deviceName: "Remote iPad",
                contentType: .text,
                title: "Canonical 2",
                payload: ClipboardPayload(text: "canonical order match")
            ),
            ClipboardItem(
                createdAt: Date(timeIntervalSince1970: 100),
                sourceAppName: "Notes",
                deviceName: "Test Mac",
                contentType: .text,
                title: "Canonical 3",
                payload: ClipboardPayload(text: "canonical order match")
            ),
            ClipboardItem(
                createdAt: Date(timeIntervalSince1970: 400),
                sourceAppName: "Safari",
                deviceName: "Test Mac",
                contentType: .text,
                title: "Canonical 4",
                payload: ClipboardPayload(text: "canonical order match")
            )
        ]
        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.snapshot = PasteBuddySnapshot(items: items)
        let expectedIDs = items.map(\.id)
        let fallbackPage = await store.filteredItemsPageAndCount(for: .history, offset: 0, limit: 10)
        let searchPage = try await store.searchItemsPage(query: "canonical order", limit: 10)

        XCTAssertEqual(store.filteredItems.map(\.id), expectedIDs)
        XCTAssertEqual(store.mainListItemsSnapshot.map(\.id), expectedIDs)
        XCTAssertEqual(fallbackPage.items.map(\.id), expectedIDs)
        XCTAssertEqual(searchPage.map(\.id), expectedIDs)
    }

    func testQuickPasteKeepsOneThroughNineLimitWithRepositoryBackedHistory() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let repository = ClipboardItemRepository(database: database)
        let now = Date(timeIntervalSince1970: 4_000_000)
        let items = (0..<125).map { index in
            ClipboardItem(
                createdAt: now.addingTimeInterval(TimeInterval(-index)),
                updatedAt: now.addingTimeInterval(TimeInterval(-index)),
                sourceAppName: "Notes",
                deviceName: "Test Mac",
                contentType: .text,
                title: "QuickPaste Item \(index)",
                payload: ClipboardPayload(text: "quick paste body \(index)")
            )
        }
        try harness.snapshotStore.save(PasteBuddySnapshot(items: items))

        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository
        )
        store.load()

        XCTAssertEqual(store.mainListItemsSnapshot.count, 125)
        XCTAssertEqual(store.quickPasteItem(atOneBasedIndex: 1)?.id, items[0].id)
        XCTAssertEqual(store.quickPasteItem(atOneBasedIndex: 9)?.id, items[8].id)
        XCTAssertNil(store.quickPasteItem(atOneBasedIndex: 10))
    }

}
