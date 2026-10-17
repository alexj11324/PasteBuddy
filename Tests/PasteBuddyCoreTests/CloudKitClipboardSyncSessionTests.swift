import Foundation
@testable import PasteBuddyCore
import XCTest

@MainActor
final class CloudKitClipboardSyncSessionTests: XCTestCase {
    func testSyncOnceMergesRemoteClipboardAndUploadsLocalChanges() async throws {
        let harness = try CloudSyncHarness()
        defer { harness.cleanup() }
        let remoteItem = ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Remote iPad",
            contentType: .text,
            title: "Remote Clipboard",
            payload: ClipboardPayload(text: "from another device")
        )
        let remoteSnapshot = PasteBuddySnapshot(
            items: [remoteItem],
            sync: harness.store.snapshot.sync
        )
        _ = try await harness.service.upload(remoteSnapshot, createdAt: Date(timeIntervalSince1970: 20))

        harness.store.addCapturedItem(
            ClipboardItem(
                sourceAppName: "Notes",
                deviceName: "Local Mac",
                contentType: .text,
                title: "Local Clipboard",
                payload: ClipboardPayload(text: "typed on this device")
            )
        )

        var lastUploadedDataRevision: Int?
        let shouldContinue = await harness.runtime.syncOnce(
            store: harness.store,
            lastUploadedDataRevision: &lastUploadedDataRevision
        )

        XCTAssertTrue(shouldContinue)
        XCTAssertEqual(
            Set(harness.store.snapshot.items.map(\.title)),
            Set(["Remote Clipboard", "Local Clipboard"])
        )
        let records = await harness.transport.records()
        XCTAssertGreaterThanOrEqual(records.count, 2)
        let latest = try XCTUnwrap(records.max { $0.createdAt < $1.createdAt })
        let uploaded = try harness.encryptionService.decrypt(PasteBuddySnapshot.self, from: latest.encryptedSnapshot)
        XCTAssertEqual(
            Set(uploaded.items.map(\.title)),
            Set(["Remote Clipboard", "Local Clipboard"])
        )
        XCTAssertEqual(lastUploadedDataRevision, harness.store.dataRevision)
    }

    func testSyncOnceDoesNotUploadWhenImportFails() async throws {
        let harness = try CloudSyncHarness()
        defer { harness.cleanup() }
        await harness.transport.setFetchError(CloudSyncSessionTestError.fetchFailed)
        harness.store.addCapturedItem(
            ClipboardItem(
                sourceAppName: "Notes",
                deviceName: "Local Mac",
                contentType: .text,
                title: "Should Stay Local",
                payload: ClipboardPayload(text: "do not upload after a failed import")
            )
        )

        var lastUploadedDataRevision: Int?
        let shouldContinue = await harness.runtime.syncOnce(
            store: harness.store,
            lastUploadedDataRevision: &lastUploadedDataRevision
        )

        XCTAssertTrue(shouldContinue)
        XCTAssertEqual(await harness.transport.saveCount(), 0)
        XCTAssertNil(lastUploadedDataRevision)
        XCTAssertEqual(harness.store.lastErrorMessage, CloudSyncSessionTestError.fetchFailed.localizedDescription)
    }

    func testSessionStartsOnlyWhenICloudSyncIsReady() async throws {
        let harness = try CloudSyncHarness(configureSync: false)
        defer { harness.cleanup() }
        let session = CloudKitClipboardSyncSession { _ in
            harness.runtime
        }

        session.update(store: harness.store)
        XCTAssertFalse(harness.runtime.isRunning)

        harness.store.configureCloudKitSync(
            containerIdentifier: "iCloud.com.example.PasteBuddy",
            capabilityConfigured: true
        )
        session.update(store: harness.store)
        XCTAssertTrue(harness.runtime.isRunning)

        session.update(store: harness.store, allowsNetwork: false)
        XCTAssertFalse(harness.runtime.isRunning)
        session.stop()
    }
}

private struct CloudSyncSessionTestError: LocalizedError {
    static let fetchFailed = CloudSyncSessionTestError()

    var errorDescription: String? {
        "Simulated CloudKit fetch failed."
    }
}

private actor CloudSyncSessionTransport: CloudSyncRemoteRecordTransport {
    private var storedRecords: [CloudSyncRemoteRecord] = []
    private var fetchError: Error?
    private var saves = 0

    func setFetchError(_ error: Error?) {
        fetchError = error
    }

    func save(_ record: CloudSyncRemoteRecord) async throws -> CloudSyncRemoteRecord {
        saves += 1
        storedRecords.removeAll { $0.packageID == record.packageID }
        storedRecords.append(record)
        return record
    }

    func fetchLatest(limit: Int) async throws -> [CloudSyncRemoteRecord] {
        if let fetchError {
            throw fetchError
        }
        return Array(storedRecords.sorted { $0.createdAt > $1.createdAt }.prefix(max(0, limit)))
    }

    func records() -> [CloudSyncRemoteRecord] {
        storedRecords
    }

    func saveCount() -> Int {
        saves
    }
}

@MainActor
private final class CloudSyncHarness {
    let directory: URL
    let encryptionService: EncryptionService
    let transport: CloudSyncSessionTransport
    let service: CloudKitSyncService
    let runtime: CloudKitClipboardSyncRuntime
    let store: PasteBuddyStore

    init(configureSync: Bool = true) throws {
        directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("CloudKitClipboardSync-\(UUID().uuidString)", isDirectory: true)
        encryptionService = EncryptionService(
            service: "com.pastebuddy.cloud-sync-tests",
            account: UUID().uuidString,
            keyID: "test-key"
        )
        transport = CloudSyncSessionTransport()
        service = CloudKitSyncService(
            transport: transport,
            builder: CloudSyncPackageBuilder(encryptor: encryptionService),
            importer: CloudSyncPackageImporter(decryptor: encryptionService, legacyDecryptor: nil)
        )
        runtime = CloudKitClipboardSyncRuntime(service: service, pollInterval: .seconds(3600))
        let snapshotStore = EncryptedSnapshotStore(
            fileURL: directory.appendingPathComponent("clipboard.pbenc"),
            encryptionService: encryptionService,
            storageMode: .standard
        )
        store = PasteBuddyStore(diskStore: snapshotStore, saveDebounceNanoseconds: nil)
        if configureSync {
            store.configureCloudKitSync(
                containerIdentifier: "iCloud.com.example.PasteBuddy",
                capabilityConfigured: true
            )
        }
    }

    func cleanup() {
        runtime.stop()
        try? encryptionService.deleteKeyForTesting()
        try? FileManager.default.removeItem(at: directory)
    }
}
