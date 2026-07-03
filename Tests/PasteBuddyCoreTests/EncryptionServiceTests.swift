import XCTest
@testable import PasteBuddyCore
#if canImport(CloudKit)
import CloudKit
#endif

final class EncryptionServiceTests: XCTestCase {
    private func makeTemporaryStoreFile(
        filename: String = "clipboard.pbenc"
    ) throws -> URL {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("PasteBuddyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent(filename)
    }

    func testEncryptionCoverageAuditMarksCloudSyncPackagesOutsideEncryptedCoverage() {
        let report = EncryptionCoverageAudit.current

        XCTAssertEqual(report.uncoveredSurfaces, [])
        XCTAssertEqual(report.plaintextFallbackSurfaces, [.syncPackages])
        XCTAssertTrue(report.items.contains { $0.surface == .ocrMetadata })
        XCTAssertTrue(report.items.contains { $0.surface == .syncPackages })
        XCTAssertTrue(report.items.contains { $0.surface == .entitlementMetadata })
        XCTAssertTrue(report.items.contains { $0.surface == .encryptionKeyMaterial })
    }

    func testEnvelopeDoesNotContainClipboardPlaintext() throws {
        let service = EncryptionService(
            service: "com.pastebuddy.tests",
            account: UUID().uuidString,
            keyID: "test-key"
        )
        defer { try? service.deleteKeyForTesting() }

        let snapshot = PasteBuddySnapshot(items: [
            ClipboardItem(
                sourceAppName: "Unit Test",
                deviceName: "Test Mac",
                contentType: .text,
                title: "Secret title",
                payload: ClipboardPayload(text: "enterprise secret clipboard payload")
            )
        ])

        let envelope = try service.encrypt(snapshot)
        let encodedEnvelope = try JSONEncoder.pasteBuddy.encode(envelope)
        let envelopeString = String(decoding: encodedEnvelope, as: UTF8.self)

        XCTAssertFalse(envelopeString.contains("enterprise secret clipboard payload"))
        XCTAssertFalse(envelopeString.contains("Secret title"))

        let decrypted = try service.decrypt(PasteBuddySnapshot.self, from: envelope)
        XCTAssertEqual(decrypted.items.count, 1)
        XCTAssertEqual(decrypted.items[0].title, "Secret title")
        XCTAssertEqual(decrypted.items[0].payload.text, "enterprise secret clipboard payload")
        XCTAssertEqual(decrypted.privacy.excludedApplicationNames, snapshot.privacy.excludedApplicationNames)
    }

    func testSnapshotStoreWritesEncryptedPayloadOnly() throws {
        let service = EncryptionService(
            service: "com.pastebuddy.tests",
            account: UUID().uuidString,
            keyID: "test-key"
        )
        defer { try? service.deleteKeyForTesting() }

        let fileURL = try makeTemporaryStoreFile()
        let store = EncryptedSnapshotStore(fileURL: fileURL, encryptionService: service)

        let snapshot = PasteBuddySnapshot(items: [
            ClipboardItem(
                sourceAppName: "Unit Test",
                deviceName: "Test Mac",
                contentType: .text,
                title: "Migration Secret",
                payload: ClipboardPayload(text: "plaintext must not be on disk")
            )
        ])

        try store.save(snapshot)
        let raw = try Data(contentsOf: fileURL)
        let rawString = String(decoding: raw, as: UTF8.self)

        XCTAssertFalse(rawString.contains("plaintext must not be on disk"))
        XCTAssertFalse(rawString.contains("Migration Secret"))
        let loaded = try store.load()
        XCTAssertEqual(loaded.items.count, 1)
        XCTAssertEqual(loaded.items[0].title, "Migration Secret")
        XCTAssertEqual(loaded.items[0].payload.text, "plaintext must not be on disk")
        XCTAssertEqual(loaded.privacy.excludedApplicationNames, snapshot.privacy.excludedApplicationNames)
    }

    func testSnapshotStoreCanUseExplicitStandardLocalStorageWithoutKeychainEncryption() throws {
        let service = EncryptionService(
            service: "com.pastebuddy.tests",
            account: UUID().uuidString,
            keyID: "standard-key"
        )
        defer { try? service.deleteKeyForTesting() }

        let fileURL = try makeTemporaryStoreFile(filename: "clipboard.pbstore")
        let store = EncryptedSnapshotStore(
            fileURL: fileURL,
            encryptionService: service,
            storageMode: .standard
        )
        let snapshot = PasteBuddySnapshot(items: [
            ClipboardItem(
                sourceAppName: "Unit Test",
                deviceName: "Test Mac",
                contentType: .text,
                title: "Standard Storage Item",
                payload: ClipboardPayload(text: "standard local storage is explicit")
            )
        ])

        try store.save(snapshot)

        let raw = try Data(contentsOf: fileURL)
        let rawString = String(decoding: raw, as: UTF8.self)
        let loaded = try store.load()

        XCTAssertTrue(rawString.contains("Standard Storage Item"))
        XCTAssertTrue(rawString.contains("standard local storage is explicit"))
        XCTAssertEqual(loaded.security.storageMode, .standard)
        XCTAssertEqual(store.lastLoadedStorageMode, .standard)
        XCTAssertEqual(loaded.items.first?.payload.text, "standard local storage is explicit")
    }

    func testDefaultStandardStoreDoesNotAutoOpenLegacyEncryptedFile() throws {
        let legacyFileURL = try makeTemporaryStoreFile(filename: "clipboard.pbenc")
        let directory = legacyFileURL.deletingLastPathComponent()
        try Data("legacy encrypted bytes should remain untouched".utf8).write(to: legacyFileURL)

        let store = EncryptedSnapshotStore.defaultStore(in: directory, storageMode: .standard)
        let loaded = try store.load()

        XCTAssertEqual(store.fileURL.lastPathComponent, "clipboard.pbstore")
        XCTAssertEqual(store.storageMode, .standard)
        XCTAssertEqual(store.lastLoadedStorageMode, .standard)
        XCTAssertEqual(loaded.security.storageMode, .standard)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testSnapshotStoreMigratesLegacyPlaintextSnapshotIntoEncryptedEnvelope() throws {
        let service = EncryptionService(
            service: "com.pastebuddy.tests",
            account: UUID().uuidString,
            keyID: "migration-key"
        )
        defer { try? service.deleteKeyForTesting() }

        let fileURL = try makeTemporaryStoreFile()
        let legacySnapshot = PasteBuddySnapshot(items: [
            ClipboardItem(
                sourceAppName: "Legacy Import",
                deviceName: "Test Mac",
                contentType: .image,
                title: "Legacy OCR Secret",
                payload: ClipboardPayload(
                    imageData: Data([0xCA, 0xFE]),
                    ocrText: "legacy searchable OCR text"
                ),
                ocrState: .completed(Date(timeIntervalSince1970: 123))
            )
        ])
        let legacyData = try JSONEncoder.pasteBuddy.encode(legacySnapshot)
        try legacyData.write(to: fileURL, options: [.atomic])
        XCTAssertTrue(String(decoding: try Data(contentsOf: fileURL), as: UTF8.self).contains("legacy searchable OCR text"))

        let store = EncryptedSnapshotStore(fileURL: fileURL, encryptionService: service)
        let migrated = try store.load()
        let migratedRaw = try Data(contentsOf: fileURL)
        let migratedRawString = String(decoding: migratedRaw, as: UTF8.self)
        let envelope = try JSONDecoder.pasteBuddy.decode(EncryptedEnvelope.self, from: migratedRaw)

        XCTAssertEqual(migrated.items.first?.title, "Legacy OCR Secret")
        XCTAssertEqual(migrated.items.first?.payload.ocrText, "legacy searchable OCR text")
        XCTAssertEqual(envelope.keyID, "migration-key")
        XCTAssertFalse(migratedRawString.contains("Legacy OCR Secret"))
        XCTAssertFalse(migratedRawString.contains("legacy searchable OCR text"))
    }

    func testSnapshotStoreRejectsCorruptedDataWithoutLeakingPlaintextInError() throws {
        let service = EncryptionService(
            service: "com.pastebuddy.tests",
            account: UUID().uuidString,
            keyID: "corruption-key"
        )
        defer { try? service.deleteKeyForTesting() }

        let fileURL = try makeTemporaryStoreFile()
        try Data("corrupted encrypted store with sensitive phrase: payroll token".utf8)
            .write(to: fileURL, options: [.atomic])
        let store = EncryptedSnapshotStore(fileURL: fileURL, encryptionService: service)

        XCTAssertThrowsError(try store.load()) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("Could not read the PasteBuddy store"))
            XCTAssertFalse(message.contains("payroll token"))
        }
    }

    func testSnapshotStoreRotatesEncryptionKeyByReencryptingExistingSnapshot() throws {
        let oldService = EncryptionService(
            service: "com.pastebuddy.tests",
            account: UUID().uuidString,
            keyID: "old-key"
        )
        let newService = EncryptionService(
            service: "com.pastebuddy.tests",
            account: UUID().uuidString,
            keyID: "new-key"
        )
        defer {
            try? oldService.deleteKeyForTesting()
            try? newService.deleteKeyForTesting()
        }

        let fileURL = try makeTemporaryStoreFile()
        let oldStore = EncryptedSnapshotStore(fileURL: fileURL, encryptionService: oldService)
        let snapshot = PasteBuddySnapshot(items: [
            ClipboardItem(
                sourceAppName: "Key Rotation",
                deviceName: "Test Mac",
                contentType: .text,
                title: "Rotated Secret",
                payload: ClipboardPayload(text: "rotated payload stays encrypted")
            )
        ])
        try oldStore.save(snapshot)

        try oldStore.rotateEncryption(to: newService)

        let raw = try Data(contentsOf: fileURL)
        let rawString = String(decoding: raw, as: UTF8.self)
        let envelope = try JSONDecoder.pasteBuddy.decode(EncryptedEnvelope.self, from: raw)
        let newStore = EncryptedSnapshotStore(fileURL: fileURL, encryptionService: newService)
        let reloaded = try newStore.load()

        XCTAssertEqual(envelope.keyID, "new-key")
        XCTAssertFalse(rawString.contains("Rotated Secret"))
        XCTAssertFalse(rawString.contains("rotated payload stays encrypted"))
        XCTAssertEqual(reloaded.items.first?.payload.text, "rotated payload stays encrypted")
        XCTAssertThrowsError(try oldStore.load())
    }

    func testSecureEnclaveWrappedKeyStoreRoundTripsKeyMaterialWhenAvailable() throws {
        let keyStore = SecureEnclaveWrappedKeyStore(
            service: "com.pastebuddy.tests.secure-enclave",
            account: UUID().uuidString
        )
        defer { try? keyStore.deleteStoredKeyMaterial() }

        do {
            let firstKey = try keyStore.loadOrCreateKeyData()
            let wrappedKey = try XCTUnwrap(keyStore.loadWrappedKeyDataForTesting())
            let secondKey = try keyStore.loadOrCreateKeyData()

            XCTAssertEqual(firstKey.count, 32)
            XCTAssertEqual(secondKey, firstKey)
            XCTAssertNil(wrappedKey.range(of: firstKey))
        } catch EncryptionServiceError.secureEnclaveUnavailable(let reason) {
            throw XCTSkip("Secure Enclave is unavailable in this environment: \(reason)")
        }
    }

    func testSecureEnclaveProtectedEncryptionServiceEncryptsSnapshotWhenAvailable() throws {
        let service = EncryptionService.secureEnclaveProtected(
            service: "com.pastebuddy.tests.secure-enclave",
            account: UUID().uuidString,
            keyID: "secure-enclave-test-key"
        )
        defer { try? service.deleteKeyForTesting() }

        let snapshot = PasteBuddySnapshot(items: [
            ClipboardItem(
                sourceAppName: "Unit Test",
                deviceName: "Test Mac",
                contentType: .text,
                title: "Secure Enclave Secret",
                payload: ClipboardPayload(text: "wrapped key encryption payload")
            )
        ])

        do {
            let envelope = try service.encrypt(snapshot)
            let envelopeData = try JSONEncoder.pasteBuddy.encode(envelope)
            let envelopeString = String(decoding: envelopeData, as: UTF8.self)

            XCTAssertEqual(envelope.keyID, "secure-enclave-test-key")
            XCTAssertFalse(envelopeString.contains("Secure Enclave Secret"))
            XCTAssertFalse(envelopeString.contains("wrapped key encryption payload"))

            let decrypted = try service.decrypt(PasteBuddySnapshot.self, from: envelope)
            XCTAssertEqual(decrypted.items.first?.title, "Secure Enclave Secret")
            XCTAssertEqual(decrypted.items.first?.payload.text, "wrapped key encryption payload")
        } catch EncryptionServiceError.secureEnclaveUnavailable(let reason) {
            throw XCTSkip("Secure Enclave is unavailable in this environment: \(reason)")
        }
    }

    func testCloudSyncPackageRejectsBlockedSyncConfiguration() throws {
        let builder = CloudSyncPackageBuilder()
        let snapshot = PasteBuddySnapshot(items: [
            ClipboardItem(
                sourceAppName: "Unit Test",
                deviceName: "Test Mac",
                contentType: .text,
                title: "Blocked Secret",
                payload: ClipboardPayload(text: "blocked sync must not upload")
            )
        ])

        XCTAssertThrowsError(try builder.makeUploadPackage(from: snapshot)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Cloud sync package cannot be created"))
        }
    }

    func testCloudSyncPackageContainsSnapshotPayload() throws {
        let builder = CloudSyncPackageBuilder()
        let secretItem = ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Quarterly Screenshot Secret",
            payload: ClipboardPayload(
                imageData: Data([0x01, 0x02, 0x03]),
                ocrText: "OCR private launch phrase"
            ),
            ocrState: .completed(Date())
        )
        let pinboard = Pinboard(
            name: "Sensitive Board Name",
            colorHex: "#4EA7FC",
            itemIDs: [secretItem.id]
        )
        let snapshot = PasteBuddySnapshot(
            items: [secretItem],
            pinboards: [pinboard],
            sync: SyncConfiguration(
                provider: .cloudKit,
                isCloudSyncEnabled: true,
                cloudKitContainerIdentifier: "iCloud.com.example.PasteBuddy",
                isCloudKitCapabilityConfigured: true
            )
        )

        let package = try builder.makeUploadPackage(from: snapshot)
        let encodedPackage = try JSONEncoder.pasteBuddy.encode(package)
        let packageString = String(decoding: encodedPackage, as: UTF8.self)

        XCTAssertTrue(packageString.contains("Quarterly Screenshot Secret"))
        XCTAssertTrue(packageString.contains("OCR private launch phrase"))
        XCTAssertTrue(packageString.contains("Sensitive Board Name"))
        XCTAssertEqual(package.containerIdentifier, "iCloud.com.example.PasteBuddy")

        XCTAssertEqual(package.snapshot.items.first?.title, "Quarterly Screenshot Secret")
        XCTAssertEqual(package.snapshot.items.first?.payload.ocrText, "OCR private launch phrase")
        XCTAssertEqual(package.snapshot.pinboards.first?.name, "Sensitive Board Name")
    }

    func testCloudKitSyncServiceUploadsSnapshotRemoteRecord() async throws {
        let transport = InMemoryCloudSyncRemoteTransport()
        let syncService = CloudKitSyncService(transport: transport)
        let snapshot = PasteBuddySnapshot(
            items: [
                ClipboardItem(
                    sourceAppName: "Preview",
                    deviceName: "Test Mac",
                    contentType: .image,
                    title: "Service Upload Secret",
                    payload: ClipboardPayload(
                        imageData: Data([0x05, 0x06]),
                        ocrText: "OCR hidden remote phrase"
                    ),
                    ocrState: .completed(Date(timeIntervalSince1970: 20))
                )
            ],
            sync: readySyncConfiguration()
        )

        let packageID = UUID()
        let result = try await syncService.upload(
            snapshot,
            packageID: packageID,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let savedRecords = await transport.snapshotRecords()
        let encodedRecord = try JSONEncoder.pasteBuddy.encode(try XCTUnwrap(savedRecords.first))
        let recordString = String(decoding: encodedRecord, as: UTF8.self)

        XCTAssertEqual(result.record.packageID, packageID)
        XCTAssertEqual(savedRecords.count, 1)
        XCTAssertTrue(recordString.contains("Service Upload Secret"))
        XCTAssertTrue(recordString.contains("OCR hidden remote phrase"))

        XCTAssertEqual(result.record.snapshot.items.first?.title, "Service Upload Secret")
        XCTAssertEqual(result.record.snapshot.items.first?.payload.ocrText, "OCR hidden remote phrase")
    }

    func testCloudKitSyncServiceDownloadsAndMergesLatestSnapshotRecord() async throws {
        let transport = InMemoryCloudSyncRemoteTransport()
        let syncService = CloudKitSyncService(transport: transport)
        let localItem = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Local Mac",
            contentType: .text,
            title: "Local Download Base",
            payload: ClipboardPayload(text: "local payload")
        )
        let remoteItem = ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Remote iPad",
            contentType: .url,
            title: "Remote Download Secret",
            payload: ClipboardPayload(urlString: "https://example.com/sync")
        )
        let sync = readySyncConfiguration()
        let localSnapshot = PasteBuddySnapshot(items: [localItem], sync: sync)
        let remoteSnapshot = PasteBuddySnapshot(items: [remoteItem], sync: sync)

        let upload = try await syncService.upload(
            remoteSnapshot,
            createdAt: Date(timeIntervalSince1970: 30)
        )
        let maybeDownload = try await syncService.downloadLatest(
            into: localSnapshot,
            importedAt: Date(timeIntervalSince1970: 40)
        )
        let download = try XCTUnwrap(maybeDownload)

        XCTAssertEqual(download.record.packageID, upload.record.packageID)
        XCTAssertEqual(Set(download.snapshot.items.map(\.id)), Set([localItem.id, remoteItem.id]))
        XCTAssertEqual(download.report.addedItems, 1)
        XCTAssertEqual(download.snapshot.sync.lastImportedPackageID, upload.record.packageID)
    }

    func testCloudKitSyncServiceRejectsBlockedReadinessBeforeRemoteSave() async throws {
        let transport = InMemoryCloudSyncRemoteTransport()
        let syncService = CloudKitSyncService(transport: transport)
        let snapshot = PasteBuddySnapshot(items: [
            ClipboardItem(
                sourceAppName: "Notes",
                deviceName: "Test Mac",
                contentType: .text,
                title: "Blocked Service Secret",
                payload: ClipboardPayload(text: "blocked upload should never hit transport")
            )
        ])

        do {
            _ = try await syncService.upload(snapshot)
            XCTFail("Blocked sync should throw before saving a remote record.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Cloud sync package cannot be created"))
        }

        let savedRecords = await transport.snapshotRecords()
        XCTAssertTrue(savedRecords.isEmpty)
    }

    func testPrivateCloudKitSyncUploadsSnapshotRecordsAndMergesHistoryPinboardsWithRecoveryState() async throws {
        let transport = InMemoryCloudSyncRemoteTransport()
        let syncService = CloudKitSyncService(transport: transport)
        let sync = readySyncConfiguration()
        let sharedItemID = UUID()
        let sharedPinboardID = UUID()
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let localOnlyItem = ClipboardItem(
            createdAt: newer,
            updatedAt: newer,
            sourceAppName: "Notes",
            deviceName: "Local Mac",
            contentType: .text,
            title: "Local Offline Note",
            payload: ClipboardPayload(text: "local offline payload")
        )
        let localConflictItem = ClipboardItem(
            id: sharedItemID,
            createdAt: older,
            updatedAt: older,
            sourceAppName: "Notes",
            deviceName: "Local Mac",
            contentType: .text,
            title: "Local Stale Item",
            payload: ClipboardPayload(text: "older local value")
        )
        let remoteConflictItem = ClipboardItem(
            id: sharedItemID,
            createdAt: older,
            updatedAt: newer,
            sourceAppName: "Pages",
            deviceName: "Remote iPad",
            contentType: .text,
            title: "Remote Fresh Item",
            payload: ClipboardPayload(text: "newer remote value")
        )
        let remoteOnlyItem = ClipboardItem(
            createdAt: newer.addingTimeInterval(10),
            updatedAt: newer.addingTimeInterval(10),
            sourceAppName: "Safari",
            deviceName: "Remote iPhone",
            contentType: .url,
            title: "Remote Research Link",
            payload: ClipboardPayload(urlString: "https://example.com/private-sync")
        )
        let localPinboard = Pinboard(
            id: sharedPinboardID,
            name: "Local Board Wins",
            colorHex: "#4EA7FC",
            itemIDs: [localOnlyItem.id],
            createdAt: older,
            updatedAt: newer
        )
        let remotePinboard = Pinboard(
            id: sharedPinboardID,
            name: "Remote Board Loses",
            colorHex: "#70C1B3",
            itemIDs: [remoteOnlyItem.id],
            createdAt: older,
            updatedAt: older
        )
        let remoteOnlyPinboard = Pinboard(
            name: "Remote Research Board",
            colorHex: "#F25F5C",
            itemIDs: [remoteOnlyItem.id],
            createdAt: newer,
            updatedAt: newer
        )
        let localSnapshot = PasteBuddySnapshot(
            items: [localOnlyItem, localConflictItem],
            pinboards: [localPinboard],
            privacy: PrivacyConfiguration(captureText: false),
            sync: sync
        )
        let remoteSnapshot = PasteBuddySnapshot(
            items: [remoteConflictItem, remoteOnlyItem],
            pinboards: [remotePinboard, remoteOnlyPinboard],
            privacy: PrivacyConfiguration(captureText: true),
            sync: sync
        )

        let emptyDownload = try await syncService.downloadLatest(into: localSnapshot)
        XCTAssertNil(emptyDownload)

        let upload = try await syncService.upload(
            remoteSnapshot,
            packageID: UUID(),
            createdAt: Date(timeIntervalSince1970: 3_000)
        )
        let savedRecords = await transport.snapshotRecords()
        let savedRecord = try XCTUnwrap(savedRecords.first)
        let encodedRecord = try JSONEncoder.pasteBuddy.encode(savedRecord)
        let recordString = String(decoding: encodedRecord, as: UTF8.self)

        XCTAssertEqual(savedRecord.containerIdentifier, "iCloud.com.example.PasteBuddy")
        XCTAssertTrue(recordString.contains("Remote Fresh Item"))
        XCTAssertTrue(recordString.contains("newer remote value"))
        XCTAssertTrue(recordString.contains("Remote Research Board"))

        let maybeDownload = try await syncService.downloadLatest(
            into: localSnapshot,
            importedAt: Date(timeIntervalSince1970: 4_000)
        )
        let download = try XCTUnwrap(maybeDownload)

        XCTAssertEqual(download.record.packageID, upload.record.packageID)
        XCTAssertEqual(Set(download.snapshot.items.map(\.id)), Set([localOnlyItem.id, sharedItemID, remoteOnlyItem.id]))
        XCTAssertEqual(download.snapshot.items.first(where: { $0.id == sharedItemID })?.title, "Remote Fresh Item")
        XCTAssertEqual(download.snapshot.pinboards.first(where: { $0.id == sharedPinboardID })?.name, "Local Board Wins")
        XCTAssertTrue(download.snapshot.pinboards.contains(where: { $0.id == remoteOnlyPinboard.id }))
        XCTAssertFalse(download.snapshot.privacy.captureText)
        XCTAssertEqual(download.report.addedItems, 1)
        XCTAssertEqual(download.report.updatedItems, 1)
        XCTAssertEqual(download.report.addedPinboards, 1)
        XCTAssertEqual(download.report.keptLocalPinboards, 1)
        XCTAssertEqual(download.report.conflicts.count, 2)
        XCTAssertEqual(download.snapshot.sync.lastImportedPackageID, upload.record.packageID)
        XCTAssertEqual(download.snapshot.sync.lastSyncConflictCount, 2)
        XCTAssertTrue(download.snapshot.sync.lastSyncStatusMessage?.contains("Imported CloudKit package") == true)
    }

    func testCloudSyncImportMergesHistoryAndPinboardsWithoutOverwritingLocalPrivacy() throws {
        let localItem = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Local Mac",
            contentType: .text,
            title: "Local Only",
            payload: ClipboardPayload(text: "local item")
        )
        let remoteItem = ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Remote Mac",
            contentType: .url,
            title: "Remote Link",
            payload: ClipboardPayload(urlString: "https://example.com")
        )
        let remotePinboard = Pinboard(
            name: "Remote Research",
            colorHex: "#70C1B3",
            itemIDs: [remoteItem.id],
            sharing: PinboardSharingState(ownerDisplayName: "Remote Mac")
        )
        let sync = readySyncConfiguration()
        let localSnapshot = PasteBuddySnapshot(
            items: [localItem],
            privacy: PrivacyConfiguration(captureText: false),
            sync: sync
        )
        let remoteSnapshot = PasteBuddySnapshot(
            items: [remoteItem],
            pinboards: [remotePinboard],
            privacy: PrivacyConfiguration(captureText: true),
            sync: sync
        )
        let package = try CloudSyncPackageBuilder()
            .makeUploadPackage(from: remoteSnapshot)

        let result = try CloudSyncPackageImporter()
            .importPackage(package, into: localSnapshot)

        XCTAssertEqual(Set(result.snapshot.items.map(\.id)), Set([localItem.id, remoteItem.id]))
        XCTAssertEqual(result.snapshot.pinboards.first(where: { $0.id == remotePinboard.id })?.sharing?.ownerDisplayName, "Remote Mac")
        XCTAssertFalse(result.snapshot.privacy.captureText)
        XCTAssertEqual(result.snapshot.sync.lastImportedPackageID, package.id)
        XCTAssertEqual(result.report.addedItems, 1)
        XCTAssertEqual(result.report.addedPinboards, 1)
    }

    func testCloudSyncImportKeepsNewerLocalConflictAndRejectsWrongContainer() throws {
        let itemID = UUID()
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let localItem = ClipboardItem(
            id: itemID,
            createdAt: older,
            updatedAt: newer,
            sourceAppName: "Notes",
            deviceName: "Local Mac",
            contentType: .text,
            title: "Local Wins",
            payload: ClipboardPayload(text: "newer local")
        )
        let remoteItem = ClipboardItem(
            id: itemID,
            createdAt: older,
            updatedAt: older,
            sourceAppName: "Notes",
            deviceName: "Remote Mac",
            contentType: .text,
            title: "Remote Loses",
            payload: ClipboardPayload(text: "older remote")
        )
        let sync = readySyncConfiguration()
        let localSnapshot = PasteBuddySnapshot(items: [localItem], sync: sync)
        let remoteSnapshot = PasteBuddySnapshot(items: [remoteItem], sync: sync)
        let package = try CloudSyncPackageBuilder()
            .makeUploadPackage(from: remoteSnapshot)

        let result = try CloudSyncPackageImporter()
            .importPackage(package, into: localSnapshot)

        XCTAssertEqual(result.snapshot.items.first?.title, "Local Wins")
        XCTAssertEqual(result.report.conflicts.first?.resolution, .keptLocal)
        XCTAssertEqual(result.snapshot.sync.lastSyncConflictCount, 1)

        var wrongContainerPackage = package
        wrongContainerPackage.containerIdentifier = "iCloud.com.example.Other"

        XCTAssertThrowsError(
            try CloudSyncPackageImporter().importPackage(wrongContainerPackage, into: localSnapshot)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("configured for iCloud.com.example.PasteBuddy"))
        }
    }

    #if canImport(CloudKit)
    func testCloudKitRecordContainsSnapshotPayload() throws {
        let snapshot = PasteBuddySnapshot(
            items: [
                ClipboardItem(
                    sourceAppName: "Notes",
                    deviceName: "Test Mac",
                    contentType: .text,
                    title: "CloudKit Record Secret",
                    payload: ClipboardPayload(text: "record payload must stay encrypted")
                )
            ],
            sync: SyncConfiguration(
                provider: .cloudKit,
                isCloudSyncEnabled: true,
                cloudKitContainerIdentifier: "iCloud.com.example.PasteBuddy",
                isCloudKitCapabilityConfigured: true
            )
        )
        let package = try CloudSyncPackageBuilder()
            .makeUploadPackage(from: snapshot)
        let record = try CloudKitRecordFactory().makeRecord(from: package)

        XCTAssertEqual(record.recordType, CloudKitRecordFactory.snapshotRecordType)
        XCTAssertEqual(
            record[CloudKitRecordFactory.containerIdentifierField] as? String,
            "iCloud.com.example.PasteBuddy"
        )

        let snapshotData = try XCTUnwrap(record[CloudKitRecordFactory.snapshotField] as? Data)
        let snapshotString = String(decoding: snapshotData, as: UTF8.self)

        XCTAssertTrue(snapshotString.contains("CloudKit Record Secret"))
        XCTAssertTrue(snapshotString.contains("record payload must stay encrypted"))

        let decodedSnapshot = try JSONDecoder.pasteBuddy.decode(PasteBuddySnapshot.self, from: snapshotData)
        let remoteRecord = try CloudKitRecordFactory().makeRemoteRecord(from: record)
        let roundTrippedPackage = remoteRecord.makePackage()

        XCTAssertEqual(decodedSnapshot.items.first?.title, "CloudKit Record Secret")
        XCTAssertEqual(decodedSnapshot.items.first?.payload.text, "record payload must stay encrypted")
        XCTAssertEqual(remoteRecord.packageID, package.id)
        XCTAssertEqual(roundTrippedPackage.containerIdentifier, "iCloud.com.example.PasteBuddy")
        XCTAssertEqual(roundTrippedPackage.snapshot.items.first?.title, package.snapshot.items.first?.title)
        XCTAssertEqual(roundTrippedPackage.snapshot.items.first?.payload.text, package.snapshot.items.first?.payload.text)
    }
    #endif
}

private actor InMemoryCloudSyncRemoteTransport: CloudSyncRemoteRecordTransport {
    private var records: [CloudSyncRemoteRecord] = []

    func save(_ record: CloudSyncRemoteRecord) async throws -> CloudSyncRemoteRecord {
        records.removeAll { $0.packageID == record.packageID }
        records.append(record)
        return record
    }

    func fetchLatest(limit: Int) async throws -> [CloudSyncRemoteRecord] {
        Array(records.sorted { $0.createdAt > $1.createdAt }.prefix(max(0, limit)))
    }

    func snapshotRecords() -> [CloudSyncRemoteRecord] {
        records
    }
}

private func readySyncConfiguration() -> SyncConfiguration {
    SyncConfiguration(
        provider: .cloudKit,
        isCloudSyncEnabled: true,
        isSharedPinboardsEnabled: true,
        cloudKitContainerIdentifier: "iCloud.com.example.PasteBuddy",
        isCloudKitCapabilityConfigured: true
    )
}
