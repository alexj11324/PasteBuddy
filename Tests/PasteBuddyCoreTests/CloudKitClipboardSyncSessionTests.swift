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
        let succeeded = await harness.runtime.syncOnce(
            store: harness.store,
            lastUploadedDataRevision: &lastUploadedDataRevision
        )

        XCTAssertFalse(succeeded)
        XCTAssertEqual(await harness.transport.saveCount(), 0)
        XCTAssertNil(lastUploadedDataRevision)
        XCTAssertEqual(harness.store.lastErrorMessage, CloudSyncSessionTestError.fetchFailed.localizedDescription)
    }

    func testSyncOnceReturnsFalseWhenUploadFails() async throws {
        let harness = try CloudSyncHarness()
        defer { harness.cleanup() }
        await harness.transport.setSaveError(CloudSyncSessionTestError.saveFailed)
        harness.store.addCapturedItem(
            ClipboardItem(
                sourceAppName: "Notes",
                deviceName: "Local Mac",
                contentType: .text,
                title: "Should Stay Local",
                payload: ClipboardPayload(text: "do not report success after a failed upload")
            )
        )

        var lastUploadedDataRevision: Int?
        let succeeded = await harness.runtime.syncOnce(
            store: harness.store,
            lastUploadedDataRevision: &lastUploadedDataRevision
        )

        XCTAssertFalse(succeeded)
        XCTAssertEqual(await harness.transport.saveCount(), 1)
        XCTAssertTrue(await harness.transport.records().isEmpty)
        XCTAssertNil(lastUploadedDataRevision)
        XCTAssertEqual(harness.store.lastErrorMessage, CloudSyncSessionTestError.saveFailed.localizedDescription)
    }

    func testSyncOnceUploadsWhenAnOlderErrorIsUnchanged() async throws {
        let harness = try CloudSyncHarness()
        defer { harness.cleanup() }
        var sync = harness.store.snapshot.sync
        sync.lastImportedPackageID = UUID()
        sync.lastSyncStatusMessage = "No encrypted CloudKit records found."
        harness.store.snapshot.sync = sync
        harness.store.lastErrorMessage = "Previous paste failed."
        harness.store.addCapturedItem(
            ClipboardItem(
                sourceAppName: "Notes",
                deviceName: "Local Mac",
                contentType: .text,
                title: "Local After Old Error",
                payload: ClipboardPayload(text: "an old error is not a fetch failure")
            )
        )

        var lastUploadedDataRevision: Int?
        let succeeded = await harness.runtime.syncOnce(
            store: harness.store,
            lastUploadedDataRevision: &lastUploadedDataRevision
        )

        XCTAssertTrue(succeeded)
        XCTAssertEqual(await harness.transport.saveCount(), 1)
        XCTAssertEqual(lastUploadedDataRevision, harness.store.dataRevision)
    }

    func testSnapshotOrderingUsesServerModificationTime() throws {
        let earlier = CloudKitSnapshotRevision(serverModificationDate: Date(timeIntervalSince1970: 10))
        let later = CloudKitSnapshotRevision(serverModificationDate: Date(timeIntervalSince1970: 30))
        let missing = CloudKitSnapshotRevision(serverModificationDate: nil)
        let serverDated = CloudKitSnapshotRevision(serverModificationDate: Date(timeIntervalSince1970: 20))

        XCTAssertTrue(CloudKitSnapshotRevision.prefers(later, over: earlier))
        XCTAssertFalse(CloudKitSnapshotRevision.prefers(earlier, over: later))
        XCTAssertTrue(CloudKitSnapshotRevision.prefers(earlier, over: missing))
        XCTAssertFalse(CloudKitSnapshotRevision.prefers(missing, over: serverDated))
        XCTAssertFalse(CloudKitSnapshotRevision.prefers(missing, over: missing))
        XCTAssertFalse(CloudKitSnapshotRevision.prefers(earlier, over: earlier))

        let descriptors = CloudKitSnapshotRevision.latestFirstSortDescriptors()
        XCTAssertEqual(descriptors.map(\.key), [CloudKitSnapshotRevision.serverModificationSortKey])
        XCTAssertEqual(descriptors.first?.ascending, false)
        XCTAssertNotEqual(CloudKitSnapshotRevision.serverModificationSortKey, "createdAt")

        let source = try sourceFileContents("Sources/PasteBuddyCore/Services/CloudKitSyncService.swift")
        XCTAssertTrue(source.contains("CloudKitSnapshotRevision.latestFirstSortDescriptors()"))
        XCTAssertTrue(source.contains("lhs.modificationDate"))
        XCTAssertFalse(source.contains("createdAtField, ascending: false"))
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
    static let fetchFailed = CloudSyncSessionTestError(message: "Simulated CloudKit fetch failed.")
    static let saveFailed = CloudSyncSessionTestError(message: "Simulated CloudKit save failed.")

    var message: String

    var errorDescription: String? {
        message
    }
}

private actor CloudSyncSessionTransport: CloudSyncRemoteRecordTransport {
    private var storedRecords: [CloudSyncRemoteRecord] = []
    private var fetchError: Error?
    private var saveError: Error?
    private var saves = 0

    func setFetchError(_ error: Error?) {
        fetchError = error
    }

    func setSaveError(_ error: Error?) {
        saveError = error
    }

    func save(_ record: CloudSyncRemoteRecord) async throws -> CloudSyncRemoteRecord {
        saves += 1
        if let saveError {
            throw saveError
        }
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

private func sourceFileContents(_ relativePath: String) throws -> String {
    var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    for _ in 0..<8 {
        let candidate = directory.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return String(decoding: try Data(contentsOf: candidate), as: UTF8.self)
        }
        directory.deleteLastPathComponent()
    }
    throw XCTSkip("Could not locate \(relativePath) from \(FileManager.default.currentDirectoryPath)")
}
