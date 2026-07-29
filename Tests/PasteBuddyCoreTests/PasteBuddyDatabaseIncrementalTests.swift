import XCTest
@testable import PasteBuddyCore

final class PasteBuddyDatabaseIncrementalTests: XCTestCase {
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
}
