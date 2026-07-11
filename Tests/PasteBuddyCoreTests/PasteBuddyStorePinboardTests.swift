import Foundation
import XCTest
@testable import PasteBuddyCore

extension PasteBuddyStoreTests {
    func testPinnedItemsSurviveHistoryRetentionPruning() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let pinned = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Pinned",
            payload: ClipboardPayload(text: "keep me")
        )
        let recent = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Recent",
            payload: ClipboardPayload(text: "new item")
        )

        store.addCapturedItem(pinned)
        let pinboardID = store.snapshot.pinboards[0].id
        store.selectedItemID = pinned.id
        store.pinSelectedItem(to: pinboardID)
        store.addCapturedItem(recent, maxItems: 1)

        XCTAssertTrue(store.snapshot.items.contains(where: { $0.id == pinned.id }))
        XCTAssertTrue(store.snapshot.items.contains(where: { $0.id == recent.id }))
        XCTAssertEqual(store.snapshot.pinboards[0].itemIDs, [pinned.id])
    }

    func testPinboardRenameAndRemovalKeepHistoryItem() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.createPinboard(named: "Launch")
        let pinboardID = store.snapshot.pinboards.last!.id
        let item = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Launch Note",
            payload: ClipboardPayload(text: "Keep the history copy")
        ))

        store.pinItem(item.id, to: pinboardID)
        store.renamePinboard(pinboardID, to: "Launch Assets")
        store.removeItem(item.id, fromPinboard: pinboardID)

        XCTAssertTrue(store.snapshot.items.contains(where: { $0.id == item.id }))
        XCTAssertEqual(store.snapshot.pinboards.first(where: { $0.id == pinboardID })?.name, "Launch Assets")
        XCTAssertEqual(store.snapshot.pinboards.first(where: { $0.id == pinboardID })?.itemIDs, [])

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertTrue(reloaded.snapshot.items.contains(where: { $0.id == item.id }))
        XCTAssertEqual(reloaded.snapshot.pinboards.first(where: { $0.id == pinboardID })?.name, "Launch Assets")
        XCTAssertEqual(reloaded.snapshot.pinboards.first(where: { $0.id == pinboardID })?.itemIDs, [])
    }

    func testPinboardRecolorAndReorderPersistThroughEncryptedStore() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let favoritesID = store.snapshot.pinboards[0].id
        store.createPinboard(named: "Research")
        let researchID = store.snapshot.pinboards.last!.id
        store.createPinboard(named: "Launch")
        let launchID = store.snapshot.pinboards.last!.id

        store.updatePinboardColor(researchID, to: "f25f5c")
        store.movePinboards(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        XCTAssertEqual(store.snapshot.pinboards.map(\.id), [launchID, favoritesID, researchID])
        XCTAssertEqual(store.snapshot.pinboards.first(where: { $0.id == researchID })?.colorHex, "#F25F5C")

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
        XCTAssertFalse(packageString.contains("Research"))
        XCTAssertFalse(packageString.contains("Launch"))
        let decrypted = try harness.encryptionService.decrypt(PasteBuddySnapshot.self, from: package.encryptedSnapshot)
        XCTAssertEqual(decrypted.pinboards.map(\.id), [launchID, favoritesID, researchID])
        XCTAssertEqual(decrypted.pinboards.first(where: { $0.id == researchID })?.colorHex, "#F25F5C")

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertEqual(reloaded.snapshot.pinboards.map(\.id), [launchID, favoritesID, researchID])
        XCTAssertEqual(reloaded.snapshot.pinboards.first(where: { $0.id == researchID })?.colorHex, "#F25F5C")
    }

    func testCollectionOrderDefaultsToCanonicalMixedOrderWithoutMutatingSnapshot() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let first = Pinboard(name: "First", colorHex: "#4EA7FC")
        let second = Pinboard(name: "Second", colorHex: "#70C1B3")
        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.snapshot = PasteBuddySnapshot(pinboards: [first, second])

        XCTAssertNil(store.snapshot.general.collectionOrder)
        XCTAssertEqual(store.collectionOrder, [
            .history,
            .pasteStack,
            .smart(.text),
            .smart(.links),
            .smart(.images),
            .smart(.files),
            .pinboard(first.id),
            .pinboard(second.id)
        ])
        XCTAssertNil(store.snapshot.general.collectionOrder)
    }

    func testCollectionOrderRepairsSavedDuplicatesStaleIDsAndMissingEntries() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let first = Pinboard(name: "First", colorHex: "#4EA7FC")
        let second = Pinboard(name: "Second", colorHex: "#70C1B3")
        let staleID = UUID()
        let savedOrder: [ClipboardCollectionID] = [
            .pinboard(second.id),
            .smart(.images),
            .pinboard(staleID),
            .smart(.images),
            .history,
            .pinboard(second.id)
        ]
        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.snapshot = PasteBuddySnapshot(pinboards: [first, second])
        store.snapshot.general.collectionOrder = savedOrder

        XCTAssertEqual(store.collectionOrder, [
            .pinboard(second.id),
            .smart(.images),
            .history,
            .pasteStack,
            .smart(.text),
            .smart(.links),
            .smart(.files),
            .pinboard(first.id)
        ])
        XCTAssertEqual(store.snapshot.general.collectionOrder, savedOrder)
    }

    func testCrossTypeCollectionMovePersistsWithoutChangingQueryRevision() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let favoritesID = store.snapshot.pinboards[0].id
        let queryRevision = store.queryRevision

        XCTAssertTrue(store.moveCollection(
            .pinboard(favoritesID),
            relativeTo: .smart(.links),
            afterTarget: false
        ))
        XCTAssertEqual(store.queryRevision, queryRevision)
        XCTAssertEqual(store.collectionOrder, [
            .history,
            .pasteStack,
            .smart(.text),
            .pinboard(favoritesID),
            .smart(.links),
            .smart(.images),
            .smart(.files)
        ])

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertEqual(reloaded.collectionOrder, store.collectionOrder)
    }

    func testCollectionMoveRejectsInvalidAndOutOfBoundsDestinations() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let favoritesID = store.snapshot.pinboards[0].id
        let stale = ClipboardCollectionID.pinboard(UUID())
        let originalOrder = store.collectionOrder

        XCTAssertFalse(store.moveCollection(.history, relativeTo: .history, afterTarget: true))
        XCTAssertFalse(store.moveCollection(stale, relativeTo: .history, afterTarget: true))
        XCTAssertFalse(store.moveCollection(.history, relativeTo: stale, afterTarget: true))
        XCTAssertFalse(store.moveCollection(.history, by: -1))
        XCTAssertFalse(store.moveCollection(.pinboard(favoritesID), by: 1))
        XCTAssertFalse(store.moveCollection(.history, by: 0))
        XCTAssertEqual(store.collectionOrder, originalOrder)

        XCTAssertTrue(store.moveCollection(.pasteStack, by: -1))
        XCTAssertEqual(Array(store.collectionOrder.prefix(2)), [.pasteStack, .history])
    }

    func testCreatingAndDeletingCustomPinboardsImmediatelyReconcilesStoredCollectionOrder() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let favoritesID = store.snapshot.pinboards[0].id
        XCTAssertTrue(store.moveCollection(.pinboard(favoritesID), relativeTo: .pasteStack, afterTarget: true))

        let created = store.createPinboard(named: "Research")

        XCTAssertEqual(store.snapshot.general.collectionOrder, [
            .history,
            .pasteStack,
            .pinboard(favoritesID),
            .smart(.text),
            .smart(.links),
            .smart(.images),
            .smart(.files),
            .pinboard(created.id)
        ])

        store.deletePinboard(favoritesID)

        XCTAssertEqual(store.snapshot.general.collectionOrder, [
            .history,
            .pasteStack,
            .smart(.text),
            .smart(.links),
            .smart(.images),
            .smart(.files),
            .pinboard(created.id)
        ])
    }

    func testUserPinboardReorderKeepsSmartPinboardsOutOfDisplayedOffsets() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let favoritesID = store.snapshot.pinboards[0].id
        let smartLinksID = store.syncSmartPinboard(for: .links).id
        store.createPinboard(named: "Research")
        let researchID = store.snapshot.pinboards.last!.id
        store.createPinboard(named: "Launch")
        let launchID = store.snapshot.pinboards.last!.id

        XCTAssertEqual(store.snapshot.pinboards.map(\.id), [favoritesID, smartLinksID, researchID, launchID])
        XCTAssertEqual(store.userPinboards.map(\.id), [favoritesID, researchID, launchID])

        store.moveUserPinboards(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        XCTAssertEqual(store.userPinboards.map(\.id), [launchID, favoritesID, researchID])
        XCTAssertEqual(store.snapshot.pinboards.map(\.id), [launchID, smartLinksID, favoritesID, researchID])
    }

    func testUserPinboardReorderMovesRightByOneUsingSwiftUIInsertionOffsets() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let favoritesID = store.snapshot.pinboards[0].id
        let researchID = store.createPinboard(named: "Research").id
        let launchID = store.createPinboard(named: "Launch").id

        store.moveUserPinboards(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertEqual(store.userPinboards.map(\.id), [researchID, favoritesID, launchID])

        store.moveUserPinboards(fromOffsets: IndexSet(integer: 1), toOffset: 3)
        XCTAssertEqual(store.userPinboards.map(\.id), [researchID, launchID, favoritesID])
    }

    func testCustomPinboardIconCanBeEditedButSmartCategoryIconRemainsSystemOwned() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let favoritesID = store.snapshot.pinboards[0].id
        let smartLinksID = store.syncSmartPinboard(for: .links).id

        store.updatePinboardAppearance(
            favoritesID,
            name: "Favorites",
            colorHex: "#4EA7FC",
            systemImageName: "heart.fill"
        )
        store.updatePinboardAppearance(
            smartLinksID,
            name: "Reading",
            colorHex: "#FFFFFF",
            systemImageName: "star.fill"
        )
        store.updatePinboardAppearance(
            favoritesID,
            name: "Favorites",
            colorHex: "#4EA7FC",
            systemImageName: "not.an.allowed.symbol"
        )

        XCTAssertEqual(store.snapshot.pinboards.first(where: { $0.id == favoritesID })?.systemImageName, "heart.fill")
        XCTAssertNil(store.snapshot.pinboards.first(where: { $0.id == smartLinksID })?.systemImageName)

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()
        XCTAssertEqual(reloaded.snapshot.pinboards.first(where: { $0.id == favoritesID })?.systemImageName, "heart.fill")
        XCTAssertNil(reloaded.snapshot.pinboards.first(where: { $0.id == smartLinksID })?.systemImageName)
    }

    func testLegacyPinboardWithoutCustomIconStillDecodes() throws {
        let encoded = try JSONEncoder.pasteBuddy.encode(Pinboard(name: "Favorites", colorHex: "#4EA7FC"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "systemImageName")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder.pasteBuddy.decode(Pinboard.self, from: legacyData)

        XCTAssertEqual(decoded.name, "Favorites")
        XCTAssertNil(decoded.systemImageName)
    }

    func testPinboardItemReorderControlsDisplayOrder() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let pinboardID = store.snapshot.pinboards[0].id
        let first = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "First",
            payload: ClipboardPayload(text: "first")
        ))
        let second = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Second",
            payload: ClipboardPayload(text: "second")
        ))

        store.pinItem(first.id, to: pinboardID)
        store.pinItem(second.id, to: pinboardID)
        store.selectedScope = .pinboard(pinboardID)

        XCTAssertEqual(store.filteredItems.map(\.title), ["Second", "First"])

        store.moveItems(inPinboard: pinboardID, fromOffsets: IndexSet(integer: 1), toOffset: 0)

        XCTAssertEqual(store.snapshot.pinboards[0].itemIDs, [first.id, second.id])
        XCTAssertEqual(store.filteredItems.map(\.title), ["First", "Second"])
    }

    func testSmartPinboardsCreateRefreshAndDoNotProtectHistoryRetention() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let text = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Note",
            payload: ClipboardPayload(text: "plain text")
        ))
        let textWithURL = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Messages",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Text With URL",
            payload: ClipboardPayload(text: "www.example.com/research")
        ))
        let link = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Test Mac",
            contentType: .url,
            title: "Link",
            payload: ClipboardPayload(urlString: "https://example.com/research")
        ))
        let file = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Finder",
            deviceName: "Test Mac",
            contentType: .file,
            title: "Report",
            payload: ClipboardPayload(fileURLString: "file:///Users/example/Report.pdf")
        ))

        let smartPinboards = store.syncSmartPinboards()

        XCTAssertEqual(smartPinboards.count, SmartPinboardCategory.allCases.count)
        XCTAssertEqual(store.smartPinboard(for: .text)?.itemIDs, [text.id])
        XCTAssertEqual(store.smartPinboard(for: .links)?.itemIDs, [link.id, textWithURL.id])
        XCTAssertEqual(store.smartPinboard(for: .files)?.itemIDs, [file.id])
        XCTAssertTrue(store.userPinboards.allSatisfy { !SmartPinboardCategory.isSmartPinboardName($0.name) })

        let newerLink = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Test Mac",
            contentType: .url,
            title: "New Link",
            payload: ClipboardPayload(urlString: "https://example.com/new")
        ))

        XCTAssertEqual(store.smartPinboard(for: .links)?.itemIDs, [newerLink.id, link.id, textWithURL.id])

        store.updateMaxHistoryItems(1)

        XCTAssertEqual(store.snapshot.items.map(\.id), [newerLink.id])
        XCTAssertEqual(store.smartPinboard(for: .links)?.itemIDs, [newerLink.id])
        XCTAssertEqual(store.smartPinboard(for: .files)?.itemIDs, [])
    }

    func testSmartPinboardsDoNotExposeMixedAndRouteMixedAssetsToConcreteCategories() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let obsoleteMixedPinboard = Pinboard(
            name: "Smart: Mixed",
            colorHex: "#7C9A92",
            itemIDs: [],
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        store.snapshot.pinboards.append(obsoleteMixedPinboard)

        let mixedImage = store.addCapturedItem(ClipboardItem(
            sourceAppName: "PixPin",
            deviceName: "Test Mac",
            contentType: .mixed,
            title: "Screenshot with metadata",
            payload: ClipboardPayload(
                text: "Screenshot metadata",
                imageData: Data([0x01, 0x02]),
                ocrText: "Detected text"
            )
        ))
        let mixedFile = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Finder",
            deviceName: "Test Mac",
            contentType: .mixed,
            title: "File with note",
            payload: ClipboardPayload(
                text: "Attachment note",
                fileURLString: "file:///Users/example/Brief.pdf"
            )
        ))
        let mixedImageWithURL = store.addCapturedItem(ClipboardItem(
            sourceAppName: "PixPin",
            deviceName: "Test Mac",
            contentType: .mixed,
            title: "Screenshot with link metadata",
            payload: ClipboardPayload(
                text: "Screenshot metadata",
                urlString: "https://example.com/research",
                imageData: Data([0x03, 0x04]),
                ocrText: "Detected text"
            )
        ))

        let smartPinboards = store.syncSmartPinboards()

        XCTAssertFalse(SmartPinboardCategory.allCases.map(\.displayName).contains("Mixed"))
        XCTAssertEqual(smartPinboards.count, 4)
        XCTAssertEqual(store.smartPinboard(for: .images)?.itemIDs, [mixedImageWithURL.id, mixedImage.id])
        XCTAssertEqual(store.smartPinboard(for: .files)?.itemIDs, [mixedFile.id])
        XCTAssertFalse(SmartPinboardCategory.links.matches(mixedImageWithURL))
        XCTAssertFalse(store.snapshot.pinboards.contains { $0.name == "Smart: Mixed" })
        XCTAssertFalse(store.userPinboards.contains { $0.name == "Smart: Mixed" })
    }

    func testSmartPinboardReservedNamesAndDerivedBoardsCannotBeMutatedManually() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let reservedNamePinboard = store.createPinboard(named: SmartPinboardCategory.links.pinboardName)

        XCTAssertFalse(SmartPinboardCategory.isSmartPinboardName(reservedNamePinboard.name))
        XCTAssertTrue(store.userPinboards.contains { $0.id == reservedNamePinboard.id })

        store.renamePinboard(reservedNamePinboard.id, to: SmartPinboardCategory.images.pinboardName)
        let renamedUserPinboard = try XCTUnwrap(store.snapshot.pinboards.first { $0.id == reservedNamePinboard.id })
        XCTAssertFalse(SmartPinboardCategory.isSmartPinboardName(renamedUserPinboard.name))

        let link = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Messages",
            deviceName: "Test Mac",
            contentType: .url,
            title: "Link",
            payload: ClipboardPayload(urlString: "https://example.com/research")
        ))
        let text = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Note",
            payload: ClipboardPayload(text: "plain text")
        ))
        let smartLinks = store.syncSmartPinboard(for: .links)

        store.selectedScope = .pinboard(smartLinks.id)
        XCTAssertFalse(store.canReorderCurrentPinboard)

        store.renamePinboard(smartLinks.id, to: "Reading")
        store.updatePinboardColor(smartLinks.id, to: "#FFFFFF")
        store.removeItem(link.id, fromPinboard: smartLinks.id)
        store.moveItems(inPinboard: smartLinks.id, fromOffsets: IndexSet(integer: 0), toOffset: 0)
        store.pinItem(text.id, to: smartLinks.id)

        let refreshedSmartLinks = try XCTUnwrap(store.smartPinboard(for: .links))
        XCTAssertEqual(refreshedSmartLinks.name, SmartPinboardCategory.links.pinboardName)
        XCTAssertEqual(refreshedSmartLinks.colorHex, SmartPinboardCategory.links.colorHex)
        XCTAssertEqual(refreshedSmartLinks.itemIDs, [link.id])
    }

    func testMoveItemBetweenPinboardsRemovesSourceAndPreservesHistory() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let sourceID = store.snapshot.pinboards[0].id
        store.createPinboard(named: "Destination")
        let destinationID = store.snapshot.pinboards.last!.id
        let item = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Move Me",
            payload: ClipboardPayload(text: "move me")
        ))
        store.pinItem(item.id, to: sourceID)

        store.movePinboardItem(item.id, from: sourceID, to: destinationID)

        XCTAssertTrue(store.snapshot.items.contains(where: { $0.id == item.id }))
        XCTAssertEqual(store.snapshot.pinboards.first(where: { $0.id == sourceID })?.itemIDs, [])
        XCTAssertEqual(store.snapshot.pinboards.first(where: { $0.id == destinationID })?.itemIDs, [item.id])
    }

    func testBatchPinningSupportsDropOrderAndDoesNotDuplicateExistingItems() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let pinboardID = store.snapshot.pinboards[0].id
        let now = Date()
        let older = store.addCapturedItem(ClipboardItem(
            createdAt: now.addingTimeInterval(-2),
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Older",
            payload: ClipboardPayload(text: "older")
        ))
        let newer = store.addCapturedItem(ClipboardItem(
            createdAt: now.addingTimeInterval(-1),
            sourceAppName: "Pages",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Newer",
            payload: ClipboardPayload(text: "newer")
        ))
        let existing = store.addCapturedItem(ClipboardItem(
            createdAt: now,
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Existing",
            payload: ClipboardPayload(imageData: Data([0x01]))
        ))
        store.pinItem(existing.id, to: pinboardID)
        store.setSelectedItemIDs([older.id, newer.id])

        store.pinItems(store.selectedItemsInDisplayOrder.map(\.id), to: pinboardID)
        store.pinItems([newer.id, older.id, newer.id], to: pinboardID)

        XCTAssertEqual(store.snapshot.pinboards[0].itemIDs, [newer.id, older.id, existing.id])

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertEqual(reloaded.snapshot.pinboards[0].itemIDs, [newer.id, older.id, existing.id])
    }

    func testBulkCaptureKeepsHistoryAndAssignedPinboardInTheSameNewestFirstOrder() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let pinboardID = store.snapshot.pinboards[0].id
        let inputs = (0..<3).map { index in
            ClipboardItem(
                sourceAppName: "Share Extension",
                deviceName: "Test iPhone",
                contentType: .text,
                title: "Imported \(index)",
                payload: ClipboardPayload(text: "bulk capture \(index)")
            )
        }
        let assignments = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, pinboardID) })

        let storedItems = store.addCapturedItems(inputs, pinboardAssignments: assignments)
        let expectedNewestFirst = storedItems.reversed().map(\.id)

        XCTAssertEqual(store.snapshot.items.prefix(3).map(\.id), expectedNewestFirst)
        XCTAssertEqual(store.snapshot.pinboards[0].itemIDs, expectedNewestFirst)
    }

    func testRetentionPrunesOldUnpinnedItemsButKeepsPinnedItems() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let oldDate = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let oldPinned = store.addCapturedItem(ClipboardItem(
            createdAt: oldDate,
            updatedAt: oldDate,
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Old Pinned",
            payload: ClipboardPayload(text: "old pinned")
        ))
        let oldUnpinned = store.addCapturedItem(ClipboardItem(
            createdAt: oldDate,
            updatedAt: oldDate,
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Old Unpinned",
            payload: ClipboardPayload(text: "old unpinned")
        ))
        let fresh = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Fresh",
            payload: ClipboardPayload(text: "fresh")
        ))
        let pinboardID = store.snapshot.pinboards[0].id
        store.pinItem(oldPinned.id, to: pinboardID)

        store.updateRetentionDays(7)

        XCTAssertTrue(store.snapshot.items.contains(where: { $0.id == oldPinned.id }))
        XCTAssertFalse(store.snapshot.items.contains(where: { $0.id == oldUnpinned.id }))
        XCTAssertTrue(store.snapshot.items.contains(where: { $0.id == fresh.id }))
    }

    func testClearUnpinnedHistoryPreservesPinnedItems() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let pinned = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Pinned",
            payload: ClipboardPayload(text: "pinned")
        ))
        let unpinned = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Unpinned",
            payload: ClipboardPayload(text: "unpinned")
        ))
        store.pinItem(pinned.id, to: store.snapshot.pinboards[0].id)

        store.clearUnpinnedHistory()

        XCTAssertTrue(store.snapshot.items.contains(where: { $0.id == pinned.id }))
        XCTAssertFalse(store.snapshot.items.contains(where: { $0.id == unpinned.id }))
        XCTAssertEqual(store.snapshot.pinboards[0].itemIDs, [pinned.id])
    }

    func testClearAllHistoryIncludingPinnedItemsRequiresExplicitAction() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let pinned = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Pinned",
            payload: ClipboardPayload(text: "pinned")
        ))
        _ = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Unpinned",
            payload: ClipboardPayload(text: "unpinned")
        ))
        store.pinItem(pinned.id, to: store.snapshot.pinboards[0].id)

        store.clearHistory(includePinned: true)

        XCTAssertTrue(store.snapshot.items.isEmpty)
        XCTAssertEqual(store.snapshot.pinboards[0].itemIDs, [])
        XCTAssertNil(store.selectedItemID)
    }

    func testStorageLimitPrunesOldUnpinnedItemsButPreservesPinnedItems() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let oldPinned = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Pinned Large",
            payload: ClipboardPayload(imageData: Data(repeating: 0x01, count: 400_000))
        ))
        _ = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Older Large",
            payload: ClipboardPayload(imageData: Data(repeating: 0x02, count: 600_000))
        ))
        let newest = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Newest Large",
            payload: ClipboardPayload(imageData: Data(repeating: 0x03, count: 300_000))
        ))
        store.pinItem(oldPinned.id, to: store.snapshot.pinboards[0].id)

        store.updateMaxStorageBytes(1 * 1_024 * 1_024)

        XCTAssertTrue(store.snapshot.items.contains(where: { $0.id == oldPinned.id }))
        XCTAssertTrue(store.snapshot.items.contains(where: { $0.id == newest.id }))
        XCTAssertEqual(store.snapshot.items.count, 2)
        XCTAssertLessThanOrEqual(store.storageUsageReport.estimatedBytes, store.snapshot.storage.maxStorageBytes)
    }

    func testStorageUsageReportBreaksOutPinnedUnpinnedAndRichPayloadBytes() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let pinned = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Pages",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Rich Pinned",
            payload: ClipboardPayload(
                text: "rich body",
                htmlString: "<strong>rich body</strong>",
                rtfData: Data("{\\rtf1 rich body}".utf8)
            )
        ))
        _ = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Finder",
            deviceName: "Test Mac",
            contentType: .file,
            title: "Files",
            payload: ClipboardPayload(
                fileURLStrings: [
                    "file:///Users/example/Report.pdf",
                    "file:///Users/example/Brief.txt"
                ]
            )
        ))
        store.pinItem(pinned.id, to: store.snapshot.pinboards[0].id)

        let report = store.storageUsageReport

        XCTAssertEqual(report.itemCount, 2)
        XCTAssertEqual(report.pinnedItemCount, 1)
        XCTAssertEqual(report.unpinnedItemCount, 1)
        XCTAssertGreaterThan(report.pinnedEstimatedBytes, "rich body".utf8.count)
        XCTAssertGreaterThan(report.unpinnedEstimatedBytes, "file:///Users/example/Report.pdf".utf8.count)
        XCTAssertEqual(report.estimatedBytes, report.pinnedEstimatedBytes + report.unpinnedEstimatedBytes)
        XCTAssertFalse(report.isOverLimit)
    }

    func testUndoDeletionRestoresItemAndPinboardMembership() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let item = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Restore Me",
            payload: ClipboardPayload(text: "restore me")
        ))
        let pinboardID = store.snapshot.pinboards[0].id
        store.pinItem(item.id, to: pinboardID)

        store.removeItem(item.id)

        XCTAssertFalse(store.snapshot.items.contains(where: { $0.id == item.id }))
        XCTAssertEqual(store.snapshot.pinboards[0].itemIDs, [])
        XCTAssertTrue(store.canUndoDelete)

        store.undoLastDeletion()

        XCTAssertTrue(store.snapshot.items.contains(where: { $0.id == item.id }))
        XCTAssertEqual(store.snapshot.pinboards[0].itemIDs, [item.id])
        XCTAssertFalse(store.canUndoDelete)
        XCTAssertEqual(store.selectedItem?.id, item.id)
    }

    func testPasteStackCollectsCopiesAndPastesTopToBottom() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let first = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "First",
            payload: ClipboardPayload(text: "first")
        )
        let second = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Second",
            payload: ClipboardPayload(text: "second")
        )

        store.startPasteStack()
        store.addCapturedItem(first)
        store.addCapturedItem(second)

        XCTAssertEqual(store.pasteStackItems.map(\.title), ["First", "Second"])
        XCTAssertEqual(store.pasteNextStackItem()?.title, "First")
        XCTAssertEqual(store.pasteNextStackItem()?.title, "Second")
        XCTAssertTrue(store.pasteStackItems.isEmpty)
    }

    func testPasteStackCanReversePasteDirection() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.startPasteStack()
        store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "First",
            payload: ClipboardPayload(text: "first")
        ))
        store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Second",
            payload: ClipboardPayload(text: "second")
        ))

        store.reversePasteStackDirection()

        XCTAssertEqual(store.pasteStackItemsInPasteOrder.map(\.title), ["Second", "First"])
        XCTAssertEqual(store.pasteNextStackItem()?.title, "Second")
        XCTAssertEqual(store.pasteNextStackItem()?.title, "First")
    }

    func testPasteStackCanAcceptExistingItemsByID() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let first = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "First",
            payload: ClipboardPayload(text: "first")
        ))
        let second = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Second",
            payload: ClipboardPayload(text: "second")
        ))

        XCTAssertTrue(store.addItemsToPasteStack([second.id, first.id, second.id, UUID()]))
        XCTAssertEqual(store.pasteStackItems.map(\.title), ["Second", "First"])
        XCTAssertFalse(store.addItemsToPasteStack([UUID()]))
        XCTAssertEqual(store.pasteStackItems.map(\.title), ["Second", "First"])
    }

    func testPasteStackPreviewTracksDirectionManualRemovalAndAutomaticRemoval() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.startPasteStack()
        let first = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "First",
            payload: ClipboardPayload(text: "first")
        ))
        store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Second",
            payload: ClipboardPayload(text: "second")
        ))
        let third = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Third",
            payload: ClipboardPayload(text: "third")
        ))

        XCTAssertEqual(store.pasteStackPreview?.rows.map(\.title), ["First", "Second", "Third"])
        XCTAssertEqual(store.pasteStackPreview?.nextRow?.title, "First")
        XCTAssertEqual(store.pasteStackPreview?.direction, .topToBottom)
        XCTAssertEqual(store.pasteStackPreview?.isCollecting, true)

        store.reversePasteStackDirection()
        XCTAssertEqual(store.pasteStackPreview?.rows.map(\.title), ["Third", "Second", "First"])
        XCTAssertEqual(store.pasteStackPreview?.nextRow?.title, "Third")

        store.removeStackItem(third.id)
        XCTAssertEqual(store.pasteStackPreview?.rows.map(\.title), ["Second", "First"])
        XCTAssertEqual(store.pasteNextStackItem()?.title, "Second")
        XCTAssertEqual(store.pasteStackPreview?.rows.map(\.title), ["First"])

        store.removeStackItem(first.id)
        XCTAssertNil(store.pasteStackPreview)
    }

    func testPasteStackIsTemporaryWhileHistoryPersistsEncrypted() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.startPasteStack()
        store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Temporary stack item",
            payload: ClipboardPayload(text: "stored in history but not stack")
        ))

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertTrue(reloaded.pasteStackItems.isEmpty)
        XCTAssertEqual(reloaded.snapshot.items.map(\.title), ["Temporary stack item"])
    }

    func testJustRecopiedItemSurvivesRetentionPrune() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.snapshot.storage.retentionDays = 30
        let old = Date().addingTimeInterval(-31 * 24 * 3600)
        store.snapshot.items = [ClipboardItem(
            createdAt: old,
            updatedAt: old,
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Old Note",
            payload: ClipboardPayload(text: "keep me around")
        )]

        let bumped = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Old Note",
            payload: ClipboardPayload(text: "keep me around")
        ))

        XCTAssertTrue(
            store.snapshot.items.contains { $0.id == bumped.id },
            "An item copied seconds ago must not be retention-pruned"
        )
    }

}
