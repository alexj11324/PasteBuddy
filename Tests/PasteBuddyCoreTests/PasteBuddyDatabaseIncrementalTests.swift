import SQLite3
import Dispatch
import XCTest
@testable import PasteBuddyCore

final class PasteBuddyDatabaseIncrementalTests: XCTestCase {
    func testConditionalCompactionVacuumRunsOnlyWhenThresholdsAreMet() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        let database = try PasteBuddyDatabase(
            fileURL: harness.directory.appendingPathComponent("conditional-vacuum.sqlite")
        )
        let repository = ClipboardItemRepository(database: database)
        let item = ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Large disposable asset",
            payload: ClipboardPayload(imageData: Data(repeating: 0xA5, count: 2_000_000))
        )
        try repository.replaceAll(with: PasteBuddySnapshot(items: [item]))
        try repository.replaceAll(with: PasteBuddySnapshot())
        let before = try database.storagePageDiagnostics()
        XCTAssertGreaterThan(before.freelistBytes, 0)

        XCTAssertEqual(
            try database.compactIfNeeded(minimumFreelistBytes: Int64.max, minimumFreelistRatio: 1),
            .notNeeded
        )
        XCTAssertEqual(
            try database.compactIfNeeded(minimumFreelistBytes: 1, minimumFreelistRatio: 0),
            .compacted
        )
        XCTAssertEqual(try database.storagePageDiagnostics().freelistCount, 0)
    }
    func testRepositoryPersistsOptionalCustomPinboardIcon() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let repository = ClipboardItemRepository(
            database: try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        )
        var pinboard = Pinboard(
            name: "Favorites",
            colorHex: "#4EA7FC",
            systemImageName: "heart.fill"
        )
        try repository.replaceAll(with: PasteBuddySnapshot(pinboards: [pinboard]))

        XCTAssertEqual(try repository.exportSnapshot().pinboards.first?.systemImageName, "heart.fill")

        pinboard.systemImageName = nil
        pinboard.updatedAt = Date()
        _ = try repository.synchronize(with: PasteBuddySnapshot(pinboards: [pinboard]))

        XCTAssertNil(try repository.exportSnapshot().pinboards.first?.systemImageName)
    }

    func testRepositoryIncrementallyUpsertsDeletesUpdatesOCRAndPinboardMemberships() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let repository = ClipboardItemRepository(database: database)
        let now = Date(timeIntervalSince1970: 2_500_000)
        var note = ClipboardItem(
            createdAt: now,
            updatedAt: now,
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Draft",
            payload: ClipboardPayload(text: "first body")
        )
        let stale = ClipboardItem(
            createdAt: now.addingTimeInterval(-10),
            updatedAt: now.addingTimeInterval(-10),
            sourceAppName: "Safari",
            deviceName: "Test Mac",
            contentType: .url,
            title: "Stale Link",
            payload: ClipboardPayload(urlString: "https://example.com/stale")
        )
        let image = ClipboardItem(
            createdAt: now.addingTimeInterval(10),
            updatedAt: now.addingTimeInterval(10),
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Pending Receipt",
            payload: ClipboardPayload(imageData: Data([0x01])),
            ocrState: .pending(now)
        )
        let pinboard = Pinboard(
            name: "Research",
            colorHex: "#4EA7FC",
            itemIDs: [note.id],
            createdAt: now,
            updatedAt: now
        )
        try repository.replaceAll(with: PasteBuddySnapshot(items: [note, stale], pinboards: [pinboard]))

        note.payload.text = "second body"
        note.updatedAt = now.addingTimeInterval(20)
        note.refreshSearchDocument()
        try repository.upsertItem(note, snapshotOrder: 0)
        try repository.upsertItem(image, snapshotOrder: 1)
        try repository.deleteItems([stale.id])
        try repository.updateOCRText("Receipt total 42 dollars", for: image.id)

        var updatedPinboard = pinboard
        updatedPinboard.itemIDs = [image.id, note.id]
        updatedPinboard.updatedAt = now.addingTimeInterval(30)
        try repository.upsertPinboardMemberships([updatedPinboard])

        XCTAssertEqual(try repository.itemCount(), 2)
        XCTAssertEqual(
            try repository.fetchPage(ClipboardItemPageRequest(searchQuery: "second body")).map(\.id),
            [note.id]
        )
        XCTAssertTrue(try repository.fetchPage(ClipboardItemPageRequest(searchQuery: "first body")).isEmpty)
        XCTAssertTrue(try repository.fetchPage(ClipboardItemPageRequest(searchQuery: "stale")).isEmpty)
        XCTAssertEqual(
            try repository.fetchPage(ClipboardItemPageRequest(searchQuery: "receipt total")).map(\.id),
            [image.id]
        )
        XCTAssertEqual(
            try repository.fetchPage(ClipboardItemPageRequest(pinboardID: pinboard.id)).map(\.id),
            [image.id, note.id]
        )
    }

    func testRepositorySearchUsesNormalizedInteriorSubstrings() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let repository = ClipboardItemRepository(database: database)
        let item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Cafe Roadmap",
            labels: ["VIP Client"],
            payload: ClipboardPayload(text: "Quarterly launch checklist lives in Brief.pdf")
        )
        try repository.replaceAll(with: PasteBuddySnapshot(items: [item]))

        XCTAssertEqual(
            try repository.fetchPage(ClipboardItemPageRequest(searchQuery: "CAF road")).map(\.id),
            [item.id]
        )
        XCTAssertEqual(
            try repository.fetchPage(ClipboardItemPageRequest(searchQuery: "brief.pd")).map(\.id),
            [item.id]
        )
        XCTAssertEqual(
            try repository.fetchPage(ClipboardItemPageRequest(searchQuery: "vip cli")).map(\.id),
            [item.id]
        )
        XCTAssertEqual(
            try repository.fetchPage(ClipboardItemPageRequest(searchQuery: "oadmap")).map(\.id),
            [item.id]
        )
    }

    func testRepositoryCountsAllFilteredMatchesBeyondThePageLimit() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let repository = ClipboardItemRepository(database: database)
        let matchingItems = (0..<150).map { index in
            ClipboardItem(
                sourceAppName: "Notes",
                deviceName: "Test Mac",
                contentType: .text,
                title: "Indexed match \(index)",
                payload: ClipboardPayload(text: "blue team performance target \(index)")
            )
        }
        let nonMatchingItem = ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Test Mac",
            contentType: .url,
            title: "Unrelated",
            payload: ClipboardPayload(urlString: "https://example.com")
        )
        try repository.replaceAll(with: PasteBuddySnapshot(items: matchingItems + [nonMatchingItem]))

        let request = ClipboardItemPageRequest(
            searchQuery: "performance target",
            contentType: .text,
            sourceAppName: "Notes",
            limit: 25
        )
        XCTAssertEqual(try repository.fetchPage(request).count, 25)
        XCTAssertEqual(try repository.itemCount(request), 150)
    }

    func testRepositoryContentTypeFilteringMatchesEffectiveContentTypesForMixedPayloads() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let repository = ClipboardItemRepository(database: database)
        var mixedTextAndImage = ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .mixed,
            title: "Text and image",
            payload: ClipboardPayload(text: "caption", imageData: Data([0x01]))
        )
        let text = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Text",
            payload: ClipboardPayload(text: "body")
        )
        let mixedTextAndFile = ClipboardItem(
            sourceAppName: "Finder",
            deviceName: "Test Mac",
            contentType: .mixed,
            title: "Text and file",
            payload: ClipboardPayload(text: "attachment", fileURLString: "file:///tmp/report.pdf")
        )
        let mixedLinkPreview = ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Test Mac",
            contentType: .mixed,
            title: "Link preview",
            payload: ClipboardPayload(
                text: "https://example.com",
                urlString: "https://example.com",
                imageData: Data([0x02])
            )
        )
        let image = ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Image",
            payload: ClipboardPayload(imageData: Data([0x03]))
        )
        let items = [mixedTextAndImage, text, mixedTextAndFile, mixedLinkPreview, image]
        try repository.replaceAll(with: PasteBuddySnapshot(items: items))

        for contentType in ClipboardContentType.allCases {
            let expectedIDs = items.filter { $0.effectiveContentTypes.contains(contentType) }.map(\.id)
            let request = ClipboardItemPageRequest(contentType: contentType)
            XCTAssertEqual(try repository.fetchPage(request).map(\.id), expectedIDs, contentType.rawValue)
            XCTAssertEqual(try repository.itemCount(request), expectedIDs.count, contentType.rawValue)
        }

        let expectedTextIDs = items.filter { $0.effectiveContentTypes.contains(.text) }.map(\.id)
        XCTAssertEqual(
            try repository.fetchPage(ClipboardItemPageRequest(contentType: .text, limit: 1, offset: 1)).map(\.id),
            Array(expectedTextIDs.dropFirst().prefix(1))
        )

        mixedTextAndImage.payload = ClipboardPayload(
            text: "https://swift.org",
            urlString: "https://swift.org",
            imageData: Data([0x04])
        )
        mixedTextAndImage.refreshSearchDocument()
        try repository.upsertItem(mixedTextAndImage, snapshotOrder: 0)

        XCTAssertFalse(mixedTextAndImage.effectiveContentTypes.contains(.image))
        XCTAssertFalse(
            try repository.fetchPage(ClipboardItemPageRequest(contentType: .image)).map(\.id)
                .contains(mixedTextAndImage.id)
        )
        XCTAssertTrue(
            try repository.fetchPage(ClipboardItemPageRequest(contentType: .url)).map(\.id)
                .contains(mixedTextAndImage.id)
        )
    }

    func testEffectiveContentTypeMigrationBackfillsExistingMixedItems() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let databaseURL = harness.directory.appendingPathComponent("clipboard.sqlite")
        let mixedItem = ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .mixed,
            title: "Existing mixed item",
            payload: ClipboardPayload(text: "caption", imageData: Data([0x01]))
        )
        do {
            let database = try PasteBuddyDatabase(fileURL: databaseURL)
            try ClipboardItemRepository(database: database).replaceAll(
                with: PasteBuddySnapshot(items: [mixedItem])
            )
        }

        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &connection, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let sqlite = try XCTUnwrap(connection)
        defer { sqlite3_close(sqlite) }
        XCTAssertEqual(
            sqlite3_exec(
                sqlite,
                "DROP TABLE item_effective_content_types; DELETE FROM grdb_migrations WHERE identifier = 'index effective content types'",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )

        let migratedRepository = ClipboardItemRepository(database: try PasteBuddyDatabase(fileURL: databaseURL))
        XCTAssertEqual(
            try migratedRepository.fetchPage(ClipboardItemPageRequest(contentType: .text)).map(\.id),
            [mixedItem.id]
        )
        XCTAssertEqual(
            try migratedRepository.fetchPage(ClipboardItemPageRequest(contentType: .image)).map(\.id),
            [mixedItem.id]
        )
    }

    func testRepositorySearchIndexUsesTrigramTokenization() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let databaseURL = harness.directory.appendingPathComponent("clipboard.sqlite")
        _ = try PasteBuddyDatabase(fileURL: databaseURL)

        var connection: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(databaseURL.path, &connection, SQLITE_OPEN_READONLY, nil),
            SQLITE_OK
        )
        guard let connection else { return }
        defer { sqlite3_close(connection) }

        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                connection,
                "SELECT sql FROM sqlite_master WHERE name = 'clipboard_search_fts'",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        guard let statement else { return }
        defer { sqlite3_finalize(statement) }

        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        guard let schemaText = sqlite3_column_text(statement, 0) else {
            return XCTFail("Missing clipboard_search_fts schema")
        }
        let schema = String(
            cString: UnsafeRawPointer(schemaText).assumingMemoryBound(to: CChar.self)
        )
        XCTAssertTrue(schema.contains("tokenize='trigram'"), schema)
    }

    func testSearchIndexKeepsFTSRowIDsAlignedForIndexedUpdatesAndDeletes() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let databaseURL = harness.directory.appendingPathComponent("clipboard.sqlite")
        let database = try PasteBuddyDatabase(fileURL: databaseURL)
        let repository = ClipboardItemRepository(database: database)
        let first = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "First",
            payload: ClipboardPayload(text: "alpha search document")
        )
        var second = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Second",
            payload: ClipboardPayload(text: "beta search document")
        )
        let third = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Third",
            payload: ClipboardPayload(text: "gamma search document")
        )
        try repository.replaceAll(with: PasteBuddySnapshot(items: [first, second, third]))

        second.payload.text = "updated beta search document"
        second.refreshSearchDocument()
        try repository.upsertItem(second, snapshotOrder: 1)

        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &connection, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        guard let connection else { return }
        defer { sqlite3_close(connection) }

        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                connection,
                "SELECT COUNT(*) FROM clipboard_items ci JOIN clipboard_search_fts fts ON fts.rowid = ci.rowid AND fts.item_id = ci.id",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        guard let statement else { return }
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 3)

        try repository.deleteItems([second.id])
        XCTAssertTrue(try repository.fetchPage(ClipboardItemPageRequest(searchQuery: "updated beta")).isEmpty)
    }

    func testRepositorySynchronizesDistinctItemsWithSameDedupeHash() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let repository = ClipboardItemRepository(database: database)
        let now = Date(timeIntervalSince1970: 2_600_000)
        let first = ClipboardItem(
            createdAt: now,
            updatedAt: now,
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "First",
            payload: ClipboardPayload(text: "same payload")
        )
        let second = ClipboardItem(
            createdAt: now.addingTimeInterval(10),
            updatedAt: now.addingTimeInterval(10),
            sourceAppName: "TextEdit",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Second",
            payload: ClipboardPayload(text: "same payload")
        )
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.searchDocument.dedupeHash, second.searchDocument.dedupeHash)

        try repository.synchronize(with: PasteBuddySnapshot(items: [first]))
        try repository.synchronize(with: PasteBuddySnapshot(items: [second, first]))

        XCTAssertEqual(try repository.itemCount(), 2)
        XCTAssertEqual(try repository.exportSnapshot().items.map(\.id), [second.id, first.id])
    }

    func testRepositoryDeletesOnlyAssetsNoLongerReferencedByAnyItem() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let repository = ClipboardItemRepository(database: database)
        let sharedImage = Data(repeating: 0x41, count: 256)
        let uniqueImage = Data(repeating: 0x42, count: 256)
        let firstShared = ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Shared one",
            payload: ClipboardPayload(imageData: sharedImage)
        )
        let secondShared = ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Shared two",
            payload: ClipboardPayload(imageData: sharedImage)
        )
        let unique = ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Unique",
            payload: ClipboardPayload(imageData: uniqueImage)
        )
        try repository.replaceAll(with: PasteBuddySnapshot(items: [unique, secondShared, firstShared]))
        XCTAssertEqual(try database.assetRowsForTesting().count, 2)

        let externalizedItems = try repository.fetchPage()
        XCTAssertTrue(externalizedItems.allSatisfy { $0.payload.imageData == nil })
        let hydratedItems = try repository.hydrateAssets(for: externalizedItems)
        XCTAssertEqual(hydratedItems.map(\.payload.imageData), [uniqueImage, sharedImage, sharedImage])

        try repository.deleteItems([unique.id])
        XCTAssertEqual(try database.assetRowsForTesting().map(\.data), [sharedImage])

        try repository.deleteItems([firstShared.id])
        XCTAssertEqual(try database.assetRowsForTesting().map(\.data), [sharedImage])

        try repository.deleteItems([secondShared.id])
        XCTAssertTrue(try database.assetRowsForTesting().isEmpty)
    }

    func testOrphanAssetMigrationDeletesOnlyUnreferencedAssetsAndIsIdempotent() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let databaseURL = harness.directory.appendingPathComponent("orphan-assets.sqlite")
        let database = try PasteBuddyDatabase(fileURL: databaseURL)
        let repository = ClipboardItemRepository(database: database)
        let sharedImage = Data(repeating: 0x41, count: 256)
        let sharedRTF = Data("{\\rtf1 shared}".utf8)
        let firstImage = ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Shared image one",
            payload: ClipboardPayload(imageData: sharedImage)
        )
        let secondImage = ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Shared image two",
            payload: ClipboardPayload(imageData: sharedImage)
        )
        let rtfItem = ClipboardItem(
            sourceAppName: "TextEdit",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Shared RTF",
            payload: ClipboardPayload(text: "shared", rtfData: sharedRTF)
        )
        try repository.replaceAll(with: PasteBuddySnapshot(items: [firstImage, secondImage, rtfItem]))
        let storedItems = Dictionary(uniqueKeysWithValues: try repository.fetchPage().map { ($0.id, $0) })
        let sharedImageAssetID = try XCTUnwrap(storedItems[firstImage.id]?.payload.imageAssetID)
        let rtfAssetID = try XCTUnwrap(storedItems[rtfItem.id]?.payload.rtfAssetID)
        XCTAssertEqual(storedItems[secondImage.id]?.payload.imageAssetID, sharedImageAssetID)

        try executeSQLite(
            """
            INSERT INTO assets (id, sha256, kind, path, data, byte_count, encrypted, created_at)
            VALUES
                ('legacy-thumbnail', 'legacy-thumbnail-sha', 'image', '', X'0102', 2, 0, 0),
                ('legacy-full', 'legacy-full-sha', 'image', '', X'0304', 2, 0, 0),
                ('orphan-image', 'orphan-image-sha', 'image', '', X'0506', 2, 0, 0),
                ('orphan-rtf', 'orphan-rtf-sha', 'rtf', '', X'0708', 2, 0, 0);
            UPDATE clipboard_items
            SET thumbnail_asset_id = 'legacy-thumbnail'
            WHERE id = '\(firstImage.id.uuidString)';
            UPDATE clipboard_items
            SET full_asset_id = 'legacy-full'
            WHERE id = '\(rtfItem.id.uuidString)';
            DELETE FROM grdb_migrations
            WHERE identifier = 'reclaim orphaned clipboard assets';
            """,
            at: databaseURL
        )
        XCTAssertEqual(try unreferencedAssetCount(at: databaseURL), 2)

        let migratedDatabase = try PasteBuddyDatabase(fileURL: databaseURL)
        XCTAssertEqual(try unreferencedAssetCount(at: databaseURL), 0)
        let migratedAssets = try migratedDatabase.assetRowsForTesting()
        XCTAssertEqual(Set(migratedAssets.map(\.id)), [
            sharedImageAssetID,
            rtfAssetID,
            "legacy-thumbnail",
            "legacy-full"
        ])

        let hydrated = try ClipboardItemRepository(database: migratedDatabase).exportSnapshot()
        XCTAssertEqual(hydrated.items.first(where: { $0.id == firstImage.id })?.payload.imageData, sharedImage)
        XCTAssertEqual(hydrated.items.first(where: { $0.id == secondImage.id })?.payload.imageData, sharedImage)
        XCTAssertEqual(hydrated.items.first(where: { $0.id == rtfItem.id })?.payload.rtfData, sharedRTF)

        let reopenedDatabase = try PasteBuddyDatabase(fileURL: databaseURL)
        XCTAssertEqual(try reopenedDatabase.assetRowsForTesting(), migratedAssets)
    }

    func testOrphanAssetMigrationInvalidatesRepositoryLoadedBeforeMigration() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let databaseURL = harness.directory.appendingPathComponent("orphan-assets-stale-writer.sqlite")
        let staleRepository = ClipboardItemRepository(
            database: try PasteBuddyDatabase(fileURL: databaseURL)
        )
        let seed = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Pre-migration baseline",
            payload: ClipboardPayload(text: "pre-migration baseline")
        )
        try staleRepository.replaceAll(with: PasteBuddySnapshot(items: [seed]))
        _ = try staleRepository.exportSnapshot()
        try executeSQLite(
            "DELETE FROM grdb_migrations WHERE identifier = 'reclaim orphaned clipboard assets'",
            at: databaseURL
        )

        let migratedRepository = ClipboardItemRepository(
            database: try PasteBuddyDatabase(fileURL: databaseURL)
        )
        let staleItem = ClipboardItem(
            sourceAppName: "Mail",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Stale write",
            payload: ClipboardPayload(text: "stale write")
        )
        XCTAssertThrowsError(
            try staleRepository.synchronize(with: PasteBuddySnapshot(items: [staleItem, seed]))
        ) { error in
            XCTAssertEqual(error as? PasteBuddyPersistenceError, .historyUnavailable)
        }

        var migratedSnapshot = try migratedRepository.exportSnapshot()
        let currentItem = ClipboardItem(
            sourceAppName: "Messages",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Current write",
            payload: ClipboardPayload(text: "current write")
        )
        migratedSnapshot.items.insert(currentItem, at: 0)
        XCTAssertNoThrow(try migratedRepository.synchronize(with: migratedSnapshot))
    }

    func testOrphanAssetMigrationDoesNotCreateMetadataWhenNoneExists() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let databaseURL = harness.directory.appendingPathComponent("orphan-assets-no-metadata.sqlite")
        _ = try PasteBuddyDatabase(fileURL: databaseURL)
        try executeSQLite(
            "DELETE FROM grdb_migrations WHERE identifier = 'reclaim orphaned clipboard assets'",
            at: databaseURL
        )

        _ = try PasteBuddyDatabase(fileURL: databaseURL)

        XCTAssertEqual(
            try sqliteScalarInt(
                "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = 'reclaim orphaned clipboard assets'",
                at: databaseURL
            ),
            1
        )
        XCTAssertEqual(
            try sqliteScalarInt("SELECT COUNT(*) FROM snapshot_metadata", at: databaseURL),
            0
        )
    }

    func testAssetReferenceColumnsAreIndexedForTargetedGarbageCollection() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let databaseURL = harness.directory.appendingPathComponent("clipboard.sqlite")
        _ = try PasteBuddyDatabase(fileURL: databaseURL)

        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &connection, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        guard let connection else { return }
        defer { sqlite3_close(connection) }

        var columnsStatement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(connection, "PRAGMA table_info(clipboard_items)", -1, &columnsStatement, nil), SQLITE_OK)
        guard let columnsStatement else { return }
        var columnNames: Set<String> = []
        while sqlite3_step(columnsStatement) == SQLITE_ROW {
            if let name = sqlite3_column_text(columnsStatement, 1) {
                columnNames.insert(String(cString: name))
            }
        }
        sqlite3_finalize(columnsStatement)
        XCTAssertTrue(columnNames.contains("image_asset_id"))
        XCTAssertTrue(columnNames.contains("rtf_asset_id"))

        var indexesStatement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                connection,
                "SELECT name FROM sqlite_master WHERE type = 'index' AND name IN ('idx_items_image_asset', 'idx_items_rtf_asset') ORDER BY name",
                -1,
                &indexesStatement,
                nil
            ),
            SQLITE_OK
        )
        guard let indexesStatement else { return }
        defer { sqlite3_finalize(indexesStatement) }
        var indexNames: [String] = []
        while sqlite3_step(indexesStatement) == SQLITE_ROW {
            if let name = sqlite3_column_text(indexesStatement, 0) {
                indexNames.append(String(cString: name))
            }
        }
        XCTAssertEqual(indexNames, ["idx_items_image_asset", "idx_items_rtf_asset"])
    }

    func testCaptureJournalAppliesOrderedItemAndPinboardMutationsInOneTransaction() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let repository = ClipboardItemRepository(database: database)
        let now = Date(timeIntervalSince1970: 2_800_000)
        var recurring = ClipboardItem(
            createdAt: now,
            updatedAt: now,
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Recurring",
            payload: ClipboardPayload(text: "recurring value")
        )
        let stale = ClipboardItem(
            createdAt: now.addingTimeInterval(-10),
            updatedAt: now.addingTimeInterval(-10),
            sourceAppName: "TextEdit",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Stale",
            payload: ClipboardPayload(text: "stale value")
        )
        let pinned = ClipboardItem(
            createdAt: now.addingTimeInterval(-20),
            updatedAt: now.addingTimeInterval(-20),
            sourceAppName: "Safari",
            deviceName: "Test Mac",
            contentType: .url,
            title: "Pinned",
            payload: ClipboardPayload(urlString: "https://example.com/pinned")
        )
        let smartText = Pinboard(
            name: SmartPinboardCategory.text.pinboardName,
            colorHex: SmartPinboardCategory.text.colorHex,
            itemIDs: [recurring.id, stale.id]
        )
        let userPinboard = Pinboard(name: "Keep", colorHex: "#4EA7FC", itemIDs: [pinned.id])
        try repository.replaceAll(with: PasteBuddySnapshot(
            items: [recurring, stale, pinned],
            pinboards: [smartText, userPinboard]
        ))

        let fresh = ClipboardItem(
            sourceAppName: "Terminal",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Fresh",
            payload: ClipboardPayload(text: "fresh value")
        )
        var smartWithFresh = smartText
        smartWithFresh.itemIDs = [fresh.id, recurring.id]
        recurring.updatedAt = now.addingTimeInterval(30)
        var finalSmart = smartText
        finalSmart.itemIDs = [recurring.id]
        let journal = ClipboardRepositoryCaptureJournal(mutations: [
            ClipboardRepositoryCaptureMutation(
                item: fresh,
                placement: .front,
                deletedItemIDs: [stale.id],
                upsertedPinboards: [
                    ClipboardRepositoryPinboardMutation(pinboard: smartWithFresh, sortOrder: 0)
                ]
            ),
            ClipboardRepositoryCaptureMutation(
                item: recurring,
                placement: .front,
                deletedItemIDs: [fresh.id],
                upsertedPinboards: [
                    ClipboardRepositoryPinboardMutation(pinboard: finalSmart, sortOrder: 0),
                    ClipboardRepositoryPinboardMutation(pinboard: userPinboard, sortOrder: 1)
                ]
            )
        ])

        try repository.applyCaptureJournal(journal)

        XCTAssertEqual(repository.incrementalSyncInvocationCount, 0)
        let exported = try repository.exportSnapshot()
        XCTAssertEqual(exported.items.map(\.id), [recurring.id, pinned.id])
        XCTAssertEqual(exported.pinboards.first(where: { $0.id == smartText.id })?.itemIDs, [recurring.id])
        XCTAssertEqual(exported.pinboards.first(where: { $0.id == userPinboard.id })?.itemIDs, [pinned.id])
    }

    func testCaptureJournalFrontPlacementDoesNotRewriteExistingSnapshotOrders() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let databaseURL = harness.directory.appendingPathComponent("clipboard.sqlite")
        let database = try PasteBuddyDatabase(fileURL: databaseURL)
        let repository = ClipboardItemRepository(database: database)
        let first = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "First",
            payload: ClipboardPayload(text: "first value")
        )
        var second = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Second",
            payload: ClipboardPayload(text: "second value")
        )
        let third = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Third",
            payload: ClipboardPayload(text: "third value")
        )
        try repository.replaceAll(with: PasteBuddySnapshot(items: [first, second, third]))
        let initialOrders = try snapshotOrders(at: databaseURL)

        let fresh = ClipboardItem(
            sourceAppName: "Terminal",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Fresh",
            payload: ClipboardPayload(text: "fresh value")
        )
        try repository.applyCaptureJournal(ClipboardRepositoryCaptureJournal(mutations: [
            ClipboardRepositoryCaptureMutation(item: fresh, placement: .front)
        ]))

        let ordersAfterInsert = try snapshotOrders(at: databaseURL)
        XCTAssertEqual(ordersAfterInsert[first.id], initialOrders[first.id])
        XCTAssertEqual(ordersAfterInsert[second.id], initialOrders[second.id])
        XCTAssertEqual(ordersAfterInsert[third.id], initialOrders[third.id])
        XCTAssertLessThan(
            try XCTUnwrap(ordersAfterInsert[fresh.id]),
            try XCTUnwrap(initialOrders.values.min())
        )

        second.updatedAt = Date(timeIntervalSince1970: 3_000_000)
        try repository.applyCaptureJournal(ClipboardRepositoryCaptureJournal(mutations: [
            ClipboardRepositoryCaptureMutation(item: second, placement: .front)
        ]))

        let ordersAfterRecopy = try snapshotOrders(at: databaseURL)
        XCTAssertEqual(ordersAfterRecopy[first.id], ordersAfterInsert[first.id])
        XCTAssertEqual(ordersAfterRecopy[third.id], ordersAfterInsert[third.id])
        XCTAssertEqual(ordersAfterRecopy[fresh.id], ordersAfterInsert[fresh.id])
        XCTAssertLessThan(
            try XCTUnwrap(ordersAfterRecopy[second.id]),
            try XCTUnwrap(ordersAfterInsert.values.min())
        )
        XCTAssertEqual(try repository.exportSnapshot().items.map(\.id), [second.id, fresh.id, first.id, third.id])
    }

    func testPagedHistoryUsesStableSnapshotOrderAfterRecopyWithEqualCreationDates() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let repository = ClipboardItemRepository(database: database)
        let createdAt = Date(timeIntervalSince1970: 3_100_000)
        var items = (0..<5).map { index in
            ClipboardItem(
                createdAt: createdAt,
                updatedAt: createdAt,
                sourceAppName: "Notes",
                deviceName: "Test Mac",
                contentType: .text,
                title: "Equal Date \(index)",
                payload: ClipboardPayload(text: "equal date body \(index)")
            )
        }
        try repository.replaceAll(with: PasteBuddySnapshot(items: items))

        items[4].updatedAt = createdAt.addingTimeInterval(10)
        try repository.applyCaptureJournal(ClipboardRepositoryCaptureJournal(mutations: [
            ClipboardRepositoryCaptureMutation(item: items[4], placement: .front)
        ]))

        let firstPage = try repository.fetchPage(ClipboardItemPageRequest(limit: 2, offset: 0))
        let secondPage = try repository.fetchPage(ClipboardItemPageRequest(limit: 2, offset: 2))
        let thirdPage = try repository.fetchPage(ClipboardItemPageRequest(limit: 2, offset: 4))
        let pagedIDs = (firstPage + secondPage + thirdPage).map(\.id)

        XCTAssertEqual(pagedIDs, [items[4].id, items[0].id, items[1].id, items[2].id, items[3].id])
        XCTAssertEqual(Set(pagedIDs).count, items.count)
    }

    @MainActor
    func testStoreOrdinarySaveSynchronizesRepositoryIncrementallyWithoutReplaceAll() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let repository = ClipboardItemRepository(database: database)
        let standardSnapshotStore = EncryptedSnapshotStore(
            fileURL: harness.directory.appendingPathComponent("clipboard-standard.pbstore"),
            storageMode: .standard
        )
        let store = PasteBuddyStore(
            diskStore: standardSnapshotStore,
            clipboardRepository: repository
        )

        let captured = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Terminal",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Fresh SQLite Sync",
            payload: ClipboardPayload(text: "fresh repository sync target")
        ))

        XCTAssertEqual(repository.replaceAllInvocationCount, 0)
        XCTAssertEqual(repository.incrementalSyncInvocationCount, 1)
        XCTAssertEqual(
            try repository.fetchPage(ClipboardItemPageRequest(searchQuery: "fresh repo")).map(\.id),
            [captured.id]
        )
    }

    func testRepositoryRejectsStaleFullSyncFromIndependentInstance() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let databaseURL = harness.directory.appendingPathComponent("cross-store-cas.sqlite")
        let firstRepository = ClipboardItemRepository(
            database: try PasteBuddyDatabase(fileURL: databaseURL)
        )
        let secondRepository = ClipboardItemRepository(
            database: try PasteBuddyDatabase(fileURL: databaseURL)
        )
        let seed = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Shared Baseline",
            payload: ClipboardPayload(text: "shared repository baseline")
        )
        try firstRepository.replaceAll(with: PasteBuddySnapshot(items: [seed]))
        _ = try firstRepository.exportSnapshot()
        _ = try secondRepository.exportSnapshot()

        let current = ClipboardItem(
            sourceAppName: "Messages",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Current Repository Writer",
            payload: ClipboardPayload(text: "current repository writer")
        )
        try firstRepository.synchronize(with: PasteBuddySnapshot(items: [current, seed]))

        let stale = ClipboardItem(
            sourceAppName: "Mail",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Stale Repository Writer",
            payload: ClipboardPayload(text: "must not replace current repository")
        )
        XCTAssertThrowsError(
            try secondRepository.synchronize(with: PasteBuddySnapshot(items: [stale, seed]))
        )
        XCTAssertEqual(try firstRepository.exportSnapshot().items.map(\.id), [current.id, seed.id])
    }

    func testRepositoryEraseInstallsIncompatibleTombstoneAgainstLegacyWriters() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let databaseURL = harness.directory.appendingPathComponent("erase-revision-tombstone.sqlite")
        let emptyObserver = ClipboardItemRepository(
            database: try PasteBuddyDatabase(fileURL: databaseURL)
        )
        let writer = ClipboardItemRepository(
            database: try PasteBuddyDatabase(fileURL: databaseURL)
        )
        XCTAssertFalse(try emptyObserver.hasStoredSnapshot())
        let sensitiveItem = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Erased Secret",
            payload: ClipboardPayload(text: "must stay erased")
        )
        try writer.replaceAll(with: PasteBuddySnapshot(items: [sensitiveItem]))
        try writer.eraseSensitiveContent()

        XCTAssertThrowsError(
            try emptyObserver.synchronize(with: PasteBuddySnapshot(items: [sensitiveItem]))
        )
        let verifier = ClipboardItemRepository(
            database: try PasteBuddyDatabase(fileURL: databaseURL)
        )
        XCTAssertThrowsError(try verifier.exportSnapshot())
    }

    func testRepositoryNoOpMutationsDoNotInvalidateIndependentBaseline() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let databaseURL = harness.directory.appendingPathComponent("no-op-revision.sqlite")
        let firstRepository = ClipboardItemRepository(
            database: try PasteBuddyDatabase(fileURL: databaseURL)
        )
        let secondRepository = ClipboardItemRepository(
            database: try PasteBuddyDatabase(fileURL: databaseURL)
        )
        let item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Stable Revision",
            payload: ClipboardPayload(text: "stable revision")
        )
        let snapshot = PasteBuddySnapshot(items: [item])
        try firstRepository.replaceAll(with: snapshot)
        _ = try secondRepository.exportSnapshot()

        try firstRepository.updateOCRText("missing", for: UUID())
        try firstRepository.deleteItems([])
        try firstRepository.deleteItems([UUID()])
        try firstRepository.upsertPinboardMemberships([])
        try firstRepository.deletePinboards([])
        try firstRepository.deletePinboards([UUID()])

        XCTAssertNoThrow(try secondRepository.synchronize(with: snapshot))
    }

    func testAsyncRepositoryPageReadPropagatesCancellationAfterSuspension() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let repository = ClipboardItemRepository(
            database: try PasteBuddyDatabase(
                fileURL: harness.directory.appendingPathComponent("cancelled-page.sqlite")
            )
        )
        let item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Cancellation Needle",
            payload: ClipboardPayload(text: "cancelled asynchronous repository page")
        )
        try repository.replaceAll(with: PasteBuddySnapshot(items: [item]))
        let gate = RepositorySearchSuspensionGate()
        repository.beforeReturningAsyncFetchPageForTesting = {
            await gate.suspendIfNeeded()
        }

        let fetchTask = Task {
            try await repository.fetchPageAsync(
                ClipboardItemPageRequest(searchQuery: "needle")
            )
        }
        await gate.waitUntilSuspended()
        fetchTask.cancel()
        await gate.resume()

        do {
            _ = try await fetchTask.value
            XCTFail("Expected cancellation after the repository read completed.")
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }
    }

    func testConcurrentOlderExportCannotRegressRepositoryBaseline() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let repository = ClipboardItemRepository(
            database: try PasteBuddyDatabase(
                fileURL: harness.directory.appendingPathComponent("baseline-epoch.sqlite")
            )
        )
        let seed = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Epoch Seed",
            payload: ClipboardPayload(text: "epoch seed")
        )
        try repository.replaceAll(with: PasteBuddySnapshot(items: [seed]))
        _ = try repository.exportSnapshot()

        let readCompleted = DispatchSemaphore(value: 0)
        let allowAdoption = DispatchSemaphore(value: 0)
        repository.beforeAdoptingExportRevisionForTesting = {
            readCompleted.signal()
            allowAdoption.wait()
        }
        let olderExport = Task.detached {
            try repository.exportSnapshot()
        }
        XCTAssertEqual(readCompleted.wait(timeout: .now() + 2), .success)

        let concurrentItem = ClipboardItem(
            sourceAppName: "Messages",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Concurrent Revision",
            payload: ClipboardPayload(text: "concurrent revision")
        )
        try repository.synchronize(with: PasteBuddySnapshot(items: [concurrentItem, seed]))
        allowAdoption.signal()
        _ = try await olderExport.value
        repository.beforeAdoptingExportRevisionForTesting = nil

        let finalItem = ClipboardItem(
            sourceAppName: "Mail",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Final Revision",
            payload: ClipboardPayload(text: "final revision")
        )
        XCTAssertNoThrow(
            try repository.synchronize(
                with: PasteBuddySnapshot(items: [finalItem, concurrentItem, seed])
            )
        )
    }

    private func snapshotOrders(at databaseURL: URL) throws -> [UUID: Int64] {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &connection, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let database = try XCTUnwrap(connection)
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(database, "SELECT id, snapshot_order FROM clipboard_items", -1, &statement, nil),
            SQLITE_OK
        )
        let query = try XCTUnwrap(statement)
        defer { sqlite3_finalize(query) }

        var orders: [UUID: Int64] = [:]
        while sqlite3_step(query) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(query, 0),
                  let id = UUID(uuidString: String(cString: idText)) else {
                continue
            }
            orders[id] = sqlite3_column_int64(query, 1)
        }
        return orders
    }

    private func executeSQLite(_ sql: String, at databaseURL: URL) throws {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let connection else {
            throw NSError(domain: "PasteBuddyDatabaseIncrementalTests", code: 1)
        }
        defer { sqlite3_close(connection) }

        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "SQLite error \(result)"
            sqlite3_free(errorMessage)
            throw NSError(
                domain: "PasteBuddyDatabaseIncrementalTests",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    private func unreferencedAssetCount(at databaseURL: URL) throws -> Int {
        try sqliteScalarInt(
            """
            SELECT COUNT(*)
            FROM assets
            WHERE NOT EXISTS (
                SELECT 1
                FROM clipboard_items
                WHERE image_asset_id = assets.id
                   OR rtf_asset_id = assets.id
                   OR thumbnail_asset_id = assets.id
                   OR full_asset_id = assets.id
            )
            """,
            at: databaseURL
        )
    }

    private func sqliteScalarInt(_ sql: String, at databaseURL: URL) throws -> Int {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let connection else {
            throw NSError(domain: "PasteBuddyDatabaseIncrementalTests", code: 2)
        }
        defer { sqlite3_close(connection) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            connection,
            sql,
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
              let statement else {
            throw NSError(domain: "PasteBuddyDatabaseIncrementalTests", code: 3)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "PasteBuddyDatabaseIncrementalTests", code: 4)
        }
        return Int(sqlite3_column_int(statement, 0))
    }

}
