import XCTest
@testable import PasteBuddyCore

#if canImport(CloudKit)
import CloudKit
#endif

@MainActor
final class PasteBuddyStoreTests: XCTestCase {
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

    func testFailedLoadBlocksWritesThatWouldOverwriteEncryptedHistory() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let fileURL = harness.directory.appendingPathComponent("shared.pbenc")
        let writerService = EncryptionService(
            service: "com.pastebuddy.tests.load-writer",
            account: UUID().uuidString,
            keyMaterialStore: FixedEncryptionKeyMaterialStore(keyData: Data(repeating: 0x11, count: 32))
        )
        let wrongReaderService = EncryptionService(
            service: "com.pastebuddy.tests.load-reader",
            account: UUID().uuidString,
            keyMaterialStore: FixedEncryptionKeyMaterialStore(keyData: Data(repeating: 0x22, count: 32))
        )
        defer {
            try? writerService.deleteKeyForTesting()
            try? wrongReaderService.deleteKeyForTesting()
        }

        let writerDiskStore = EncryptedSnapshotStore(
            fileURL: fileURL,
            encryptionService: writerService
        )
        let writer = PasteBuddyStore(diskStore: writerDiskStore)
        let original = writer.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Must survive",
            payload: ClipboardPayload(text: "encrypted history")
        ))
        let encryptedBeforeFailedLoad = try Data(contentsOf: fileURL)

        let wrongReaderDiskStore = EncryptedSnapshotStore(
            fileURL: fileURL,
            encryptionService: wrongReaderService
        )
        let wrongReader = PasteBuddyStore(diskStore: wrongReaderDiskStore)
        wrongReader.load()

        XCTAssertTrue(wrongReader.isPersistenceWriteBlocked)
        XCTAssertThrowsError(try wrongReaderDiskStore.save(PasteBuddySnapshot()))
        wrongReader.setShareExtensionEnabled(true)
        XCTAssertEqual(try Data(contentsOf: fileURL), encryptedBeforeFailedLoad)
        XCTAssertEqual(try writerDiskStore.load().items.map(\.id), [original.id])
    }

    func testAsyncLoadPrefersCommittedRepositoryOverStaleTextSnapshot() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        harness.snapshotStore.storageMode = .standard

        let now = Date()
        let first = ClipboardItem(
            createdAt: now.addingTimeInterval(-1),
            updatedAt: now.addingTimeInterval(-1),
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Persisted in both",
            payload: ClipboardPayload(text: "first")
        )
        let committedOnlyToDatabase = ClipboardItem(
            createdAt: now,
            updatedAt: now,
            sourceAppName: "Terminal",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Committed before crash",
            payload: ClipboardPayload(text: "second")
        )
        try harness.snapshotStore.save(PasteBuddySnapshot(items: [first]))
        let database = try PasteBuddyDatabase(
            fileURL: harness.directory.appendingPathComponent("clipboard.sqlite")
        )
        let repository = ClipboardItemRepository(database: database)
        try repository.replaceAll(with: PasteBuddySnapshot(items: [committedOnlyToDatabase, first]))
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository
        )

        await store.loadAsync()

        XCTAssertEqual(store.snapshot.items.map(\.id), [committedOnlyToDatabase.id, first.id])
        XCTAssertEqual(try repository.itemCount(), 2)
    }

    func testAsyncLoadInitializesDeferredRepositoryOffMainActor() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        harness.snapshotStore.storageMode = .standard

        let databaseURL = harness.directory.appendingPathComponent("deferred-clipboard.sqlite")
        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.configureDeferredRepositoryForTesting(databaseURL: databaseURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))

        await store.loadAsync()

        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
        XCTAssertEqual(store.lastDeferredRepositoryInitializationWasOnMainThreadForTesting, false)
        XCTAssertNotNil(store.repositorySyncedDataRevision)
    }

    func testAsyncReloadDoesNotOverwriteCaptureCreatedWhileLoadIsSuspended() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let existing = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Existing Before Reload",
            payload: ClipboardPayload(text: "existing before reload")
        )
        try harness.snapshotStore.save(PasteBuddySnapshot(items: [existing]))
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            saveDebounceNanoseconds: 60_000_000_000
        )
        store.load()
        let loadGate = SuspendedStoreLoadGate()
        store.beforeApplyingAsyncLoadForTesting = {
            await loadGate.suspend()
        }

        let reloadTask = Task { @MainActor in
            await store.loadAsync()
        }
        while await !loadGate.hasSuspended() {
            await Task.yield()
        }
        let concurrentCapture = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Terminal",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Captured During Reload",
            payload: ClipboardPayload(text: "must survive suspended reload")
        ))

        await loadGate.resume()
        await reloadTask.value
        store.beforeApplyingAsyncLoadForTesting = nil

        XCTAssertEqual(store.snapshot.items.map(\.id), [concurrentCapture.id, existing.id])
        await store.flushPendingSave()

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()
        XCTAssertEqual(reloaded.snapshot.items.map(\.id), [concurrentCapture.id, existing.id])
    }

    func testAsyncReloadFlushesPendingDebouncedCaptureBeforeReadingDisk() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let existing = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Existing Before Pending Reload",
            payload: ClipboardPayload(text: "existing before pending reload")
        )
        try harness.snapshotStore.save(PasteBuddySnapshot(items: [existing]))
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            saveDebounceNanoseconds: 60_000_000_000
        )
        store.load()
        let pendingCapture = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Terminal",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Pending Before Reload",
            payload: ClipboardPayload(text: "pending capture must be flushed")
        ))

        await store.loadAsync()

        XCTAssertFalse(store.isPersistenceWriteBlocked, store.lastErrorMessage ?? "")
        XCTAssertEqual(store.snapshot.items.map(\.id), [pendingCapture.id, existing.id])
        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()
        XCTAssertEqual(reloaded.snapshot.items.map(\.id), [pendingCapture.id, existing.id])
    }

    func testAsyncReloadDoesNotOverwriteCaptureCreatedDuringPendingFlush() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let existing = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Existing Before Flush Race",
            payload: ClipboardPayload(text: "existing before flush race")
        )
        try harness.snapshotStore.save(PasteBuddySnapshot(items: [existing]))
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            saveDebounceNanoseconds: 60_000_000_000
        )
        store.load()
        let firstCapture = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Terminal",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Pending Before Flush",
            payload: ClipboardPayload(text: "pending before flush")
        ))
        let flushGate = SuspendedStoreLoadGate()
        store.beforePersistingFlushSnapshotForTesting = {
            await flushGate.suspend()
        }

        let reloadTask = Task { @MainActor in
            await store.loadAsync()
        }
        while await !flushGate.hasSuspended() {
            await Task.yield()
        }
        let concurrentCapture = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Messages",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Captured During Flush",
            payload: ClipboardPayload(text: "capture created during flush")
        ))
        await flushGate.resume()
        await reloadTask.value

        XCTAssertEqual(store.snapshot.items.map(\.id), [concurrentCapture.id, firstCapture.id, existing.id])
        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()
        XCTAssertEqual(reloaded.snapshot.items.map(\.id), [concurrentCapture.id, firstCapture.id, existing.id])
    }

    func testCancellingFlushBeforeCommitDoesNotPersistPendingCapture() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        harness.snapshotStore.storageMode = .standard
        try harness.snapshotStore.save(PasteBuddySnapshot())
        let repository = ClipboardItemRepository(
            database: try PasteBuddyDatabase(
                fileURL: harness.directory.appendingPathComponent("cancelled-flush.sqlite")
            )
        )
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository,
            saveDebounceNanoseconds: 60_000_000_000
        )
        store.load()
        _ = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Share Extension",
            deviceName: "Test iPhone",
            contentType: .text,
            title: "Cancelled Before Commit",
            payload: ClipboardPayload(text: "must not reach durable history")
        ))

        let commitGate = SuspendedStoreLoadGate()
        store.beforePersistingFlushSnapshotForTesting = {
            await commitGate.suspend()
        }
        let flushTask = Task { @MainActor in
            try await store.flushPendingSaveOrThrow()
        }
        while await !commitGate.hasSuspended() {
            await Task.yield()
        }

        flushTask.cancel()
        await commitGate.resume()

        do {
            try await flushTask.value
            XCTFail("Expected cancellation before the persistence commit point.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(store.isPersistenceWriteBlocked)
        XCTAssertTrue(try repository.exportSnapshot().items.isEmpty)
        XCTAssertTrue(try harness.snapshotStore.load().items.isEmpty)
    }

    func testOlderFlushCannotRollRepositoryBackAfterNewerFlushCommits() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        harness.snapshotStore.storageMode = .standard
        try harness.snapshotStore.save(PasteBuddySnapshot())
        let repository = ClipboardItemRepository(
            database: try PasteBuddyDatabase(
                fileURL: harness.directory.appendingPathComponent("ordered-flush.sqlite")
            )
        )
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository,
            saveDebounceNanoseconds: 60_000_000_000
        )
        store.load()
        let first = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Older Flush",
            payload: ClipboardPayload(text: "older generation")
        ))
        store.save()

        let olderFlushGate = SuspendedStoreLoadGate()
        store.beforePersistingFlushSnapshotForTesting = {
            await olderFlushGate.suspend()
        }
        let olderFlush = Task { @MainActor in
            try await store.flushPendingSaveOrThrow()
        }
        while await !olderFlushGate.hasSuspended() {
            await Task.yield()
        }

        let second = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Messages",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Newer Flush",
            payload: ClipboardPayload(text: "newer generation")
        ))
        store.save()
        try await store.flushPendingSaveOrThrow()
        let repositorySyncCountAfterNewerFlush = repository.incrementalSyncInvocationCount

        await olderFlushGate.resume()
        try await olderFlush.value

        XCTAssertEqual(
            repository.incrementalSyncInvocationCount,
            repositorySyncCountAfterNewerFlush,
            "A superseded flush must be rejected before it can rewrite the repository."
        )
        XCTAssertEqual(
            Set(try repository.exportSnapshot().items.map(\.id)),
            Set([first.id, second.id])
        )
        let reloaded = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository
        )
        reloaded.load()
        XCTAssertEqual(Set(reloaded.snapshot.items.map(\.id)), Set([first.id, second.id]))
    }

    func testSynchronousSaveSupersedesOlderSuspendedFlush() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        harness.snapshotStore.storageMode = .standard
        try harness.snapshotStore.save(PasteBuddySnapshot())
        let repository = ClipboardItemRepository(
            database: try PasteBuddyDatabase(
                fileURL: harness.directory.appendingPathComponent("ordered-sync-save.sqlite")
            )
        )
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository,
            saveDebounceNanoseconds: nil
        )
        store.load()
        let first = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Older synchronous snapshot",
            payload: ClipboardPayload(text: "older generation")
        ))

        let olderFlushGate = SuspendedStoreLoadGate()
        store.beforePersistingFlushSnapshotForTesting = {
            await olderFlushGate.suspend()
        }
        let olderFlush = Task { @MainActor in
            try await store.flushPendingSaveOrThrow()
        }
        while await !olderFlushGate.hasSuspended() {
            await Task.yield()
        }

        let second = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Messages",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Newer synchronous snapshot",
            payload: ClipboardPayload(text: "newer generation")
        ))
        let repositorySyncCountAfterSynchronousSave = repository.incrementalSyncInvocationCount

        await olderFlushGate.resume()
        try await olderFlush.value

        XCTAssertEqual(
            repository.incrementalSyncInvocationCount,
            repositorySyncCountAfterSynchronousSave,
            "A superseded async flush must not roll back a newer synchronous save."
        )
        XCTAssertEqual(
            Set(try repository.exportSnapshot().items.map(\.id)),
            Set([first.id, second.id])
        )
        XCTAssertEqual(
            Set(try harness.snapshotStore.load().items.map(\.id)),
            Set([first.id, second.id])
        )
    }

    func testCancelledSynchronousSaveSchedulesIndependentRetry() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        harness.snapshotStore.storageMode = .standard
        try harness.snapshotStore.save(PasteBuddySnapshot())
        let repository = ClipboardItemRepository(
            database: try PasteBuddyDatabase(
                fileURL: harness.directory.appendingPathComponent("cancelled-sync-save.sqlite")
            )
        )
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository,
            saveDebounceNanoseconds: nil
        )
        store.load()
        let item = ClipboardItem(
            sourceAppName: "Share Extension",
            deviceName: "Test iPhone",
            contentType: .text,
            title: "Retry cancelled synchronous save",
            payload: ClipboardPayload(text: "must still become durable")
        )
        let mutationGate = SuspendedStoreLoadGate()
        let mutationTask = Task { @MainActor in
            await mutationGate.suspend()
            _ = store.addCapturedItem(item)
        }
        while await !mutationGate.hasSuspended() {
            await Task.yield()
        }

        mutationTask.cancel()
        await mutationGate.resume()
        await mutationTask.value

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            let repositoryContainsItem = try repository.exportSnapshot().items.contains {
                $0.id == item.id
            }
            let snapshotContainsItem = try harness.snapshotStore.load().items.contains {
                $0.id == item.id
            }
            if repositoryContainsItem, snapshotContainsItem {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertTrue(try repository.exportSnapshot().items.contains { $0.id == item.id })
        XCTAssertTrue(try harness.snapshotStore.load().items.contains { $0.id == item.id })
        XCTAssertFalse(store.isPersistenceWriteBlocked)
    }

    func testPersistenceCommitGateRejectsCompletedOlderGeneration() async throws {
        let gate = PersistenceCommitGate()
        let acquiredNewerLease = await gate.acquire(generation: 2)
        let newerLease = try XCTUnwrap(acquiredNewerLease)

        gate.release(newerLease, outcome: .committed)

        let olderLease = await gate.acquire(generation: 1)
        XCTAssertNil(olderLease)
    }

    func testPersistenceCommitGateRejectsOlderGenerationAfterFailedWrite() async throws {
        let gate = PersistenceCommitGate()
        let acquiredNewerLease = await gate.acquire(generation: 2)
        let newerLease = try XCTUnwrap(acquiredNewerLease)

        gate.release(newerLease, outcome: .failedAfterWrite)

        let olderLease = await gate.acquire(generation: 1)
        XCTAssertNil(olderLease)
        let latestLease = await gate.acquire(generation: 3)
        let unwrappedLatestLease = try XCTUnwrap(latestLease)
        gate.release(unwrappedLatestLease, outcome: .abortedBeforeWrite)
    }

    func testPersistenceCommitGateAllowsOlderGenerationAfterPrewriteAbort() async throws {
        let gate = PersistenceCommitGate()
        let acquiredNewerLease = await gate.acquire(generation: 2)
        let newerLease = try XCTUnwrap(acquiredNewerLease)

        gate.release(newerLease, outcome: .abortedBeforeWrite)

        let olderLease = await gate.acquire(generation: 1)
        let unwrappedOlderLease = try XCTUnwrap(olderLease)
        gate.release(unwrappedOlderLease, outcome: .abortedBeforeWrite)
    }

    func testEncryptedAsyncLoadPreservesCaptureCreatedDuringRepositoryCleanup() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        harness.snapshotStore.storageMode = .encrypted
        let committedEncryptedItem = ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Committed Encrypted Item",
            payload: ClipboardPayload(imageData: Data(repeating: 0x7B, count: 4_096))
        )
        try harness.snapshotStore.save(PasteBuddySnapshot(items: [committedEncryptedItem]))
        let databaseURL = harness.directory.appendingPathComponent("encrypted-reload.sqlite")
        let repository = ClipboardItemRepository(database: try PasteBuddyDatabase(fileURL: databaseURL))
        let stalePlaintextItem = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Stale Plaintext Repository Item",
            payload: ClipboardPayload(text: "must not roll encrypted history back")
        )
        try repository.replaceAll(with: PasteBuddySnapshot(items: [stalePlaintextItem]))
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository,
            saveDebounceNanoseconds: 60_000_000_000
        )
        let cleanupGate = SuspendedStoreLoadGate()
        store.beforeCommittingHistoryStorageMigrationForTesting = {
            await cleanupGate.suspend()
        }

        let loadTask = Task { @MainActor in
            await store.loadAsync()
        }
        while await !cleanupGate.hasSuspended() {
            await Task.yield()
        }
        let concurrentCapture = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Messages",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Encrypted Reload Capture",
            payload: ClipboardPayload(text: "must survive encrypted cleanup")
        ))
        await cleanupGate.resume()
        await loadTask.value

        XCTAssertFalse(store.isPersistenceWriteBlocked, store.lastErrorMessage ?? "")
        XCTAssertEqual(store.snapshot.items.map(\.id), [concurrentCapture.id, committedEncryptedItem.id])
        XCTAssertFalse(store.snapshot.items.contains(where: { $0.id == stalePlaintextItem.id }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))
        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()
        XCTAssertEqual(reloaded.snapshot.items.map(\.id), [concurrentCapture.id, committedEncryptedItem.id])
        XCTAssertEqual(reloaded.snapshot.items.last?.payload.imageData, committedEncryptedItem.payload.imageData)
    }

    func testEncryptedAsyncLoadDoesNotCreateAnEmptyPlaintextRepository() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        harness.snapshotStore.storageMode = .encrypted
        try harness.snapshotStore.save(PasteBuddySnapshot(items: [ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Encrypted Only",
            payload: ClipboardPayload(text: "encrypted only history")
        )]))
        let databaseURL = harness.directory.appendingPathComponent("must-not-be-created.sqlite")
        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.configureDeferredRepositoryForTesting(databaseURL: databaseURL)

        await store.loadAsync()

        XCTAssertFalse(store.isPersistenceWriteBlocked, store.lastErrorMessage ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))
        XCTAssertNil(store.lastDeferredRepositoryInitializationWasOnMainThreadForTesting)
    }

    func testPersistenceActorRejectsLateOlderGeneration() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let actor = SnapshotPersistenceActor(diskStore: harness.snapshotStore)
        let older = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Older Generation",
            payload: ClipboardPayload(text: "older generation")
        )
        let newer = ClipboardItem(
            sourceAppName: "Messages",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Newer Generation",
            payload: ClipboardPayload(text: "newer generation")
        )

        let didSaveNewer = try await actor.save(
            PasteBuddySnapshot(items: [newer]),
            storageMode: .encrypted,
            generation: 2
        )
        let didSaveOlder = try await actor.save(
            PasteBuddySnapshot(items: [older]),
            storageMode: .encrypted,
            generation: 1
        )
        XCTAssertTrue(didSaveNewer)
        XCTAssertFalse(didSaveOlder)
        XCTAssertEqual(try harness.snapshotStore.load().items.map(\.id), [newer.id])
    }

    func testEncryptedSnapshotStoreRejectsStaleWriterFromIndependentStoreInstance() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let firstStore = harness.snapshotStore
        let secondStore = EncryptedSnapshotStore(
            fileURL: firstStore.fileURL,
            encryptionService: harness.encryptionService,
            storageMode: .encrypted
        )
        let seed = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Shared Baseline",
            payload: ClipboardPayload(text: "shared baseline")
        )
        try firstStore.save(PasteBuddySnapshot(items: [seed]))
        let persistedData = try Data(contentsOf: firstStore.fileURL)
        XCTAssertTrue(persistedData.starts(with: Data("PBST2:".utf8)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstStore.fileURL.path + ".revision"))
        let unloadedStore = EncryptedSnapshotStore(
            fileURL: firstStore.fileURL,
            encryptionService: harness.encryptionService,
            storageMode: .encrypted
        )
        XCTAssertThrowsError(try unloadedStore.save(PasteBuddySnapshot()))
        _ = try firstStore.load()
        _ = try secondStore.load()

        let current = ClipboardItem(
            sourceAppName: "Messages",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Current Writer",
            payload: ClipboardPayload(text: "current writer wins")
        )
        try firstStore.save(PasteBuddySnapshot(items: [current, seed]))

        let stale = ClipboardItem(
            sourceAppName: "Mail",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Stale Writer",
            payload: ClipboardPayload(text: "must not overwrite current history")
        )
        XCTAssertThrowsError(try secondStore.save(PasteBuddySnapshot(items: [stale, seed])))
        XCTAssertEqual(try firstStore.load().items.map(\.id), [current.id, seed.id])
    }

    func testImmediateSaveBlocksWhenRepositoryRejectsStaleWriter() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        harness.snapshotStore.storageMode = .standard
        let databaseURL = harness.directory.appendingPathComponent("immediate-save-cas.sqlite")
        let storeRepository = ClipboardItemRepository(
            database: try PasteBuddyDatabase(fileURL: databaseURL)
        )
        let concurrentRepository = ClipboardItemRepository(
            database: try PasteBuddyDatabase(fileURL: databaseURL)
        )
        let seed = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Shared Baseline",
            payload: ClipboardPayload(text: "shared baseline")
        )
        try storeRepository.replaceAll(with: PasteBuddySnapshot(items: [seed]))
        _ = try concurrentRepository.exportSnapshot()

        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: storeRepository
        )
        store.load()

        let current = ClipboardItem(
            sourceAppName: "Messages",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Current Repository Writer",
            payload: ClipboardPayload(text: "current repository writer")
        )
        try concurrentRepository.synchronize(with: PasteBuddySnapshot(items: [current, seed]))

        _ = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Mail",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Rejected Stale Capture",
            payload: ClipboardPayload(text: "must not look durably saved")
        ))

        XCTAssertTrue(store.isPersistenceWriteBlocked)
        XCTAssertNotNil(store.lastErrorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.snapshotStore.fileURL.path))
        XCTAssertEqual(try concurrentRepository.exportSnapshot().items.map(\.id), [current.id, seed.id])
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

    func testDuplicateCapturedItemMovesExistingItemToTopWithoutCreatingNewHistory() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let original = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Original",
            payload: ClipboardPayload(text: "same payload")
        ))
        let other = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Test Mac",
            contentType: .url,
            title: "Other",
            payload: ClipboardPayload(urlString: "https://example.com")
        ))

        let recaptured = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Duplicate",
            payload: ClipboardPayload(text: "same payload")
        ))

        XCTAssertEqual(store.snapshot.items.count, 2)
        XCTAssertEqual(recaptured.id, original.id)
        XCTAssertEqual(store.snapshot.items.map(\.id), [original.id, other.id])
        XCTAssertEqual(store.selectedItemID, original.id)
        XCTAssertGreaterThanOrEqual(recaptured.updatedAt, original.updatedAt)
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

    func testDuplicateLegacyDedupeKeysReuseNewestItemWithoutRebuildingIndexPerCapture() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let now = Date()
        let newest = ClipboardItem(
            createdAt: now,
            updatedAt: now,
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Newest Legacy Duplicate",
            payload: ClipboardPayload(text: "duplicate legacy value")
        )
        let oldest = ClipboardItem(
            createdAt: now.addingTimeInterval(-60),
            updatedAt: now.addingTimeInterval(-60),
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Oldest Legacy Duplicate",
            payload: ClipboardPayload(text: "duplicate legacy value")
        )
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            saveDebounceNanoseconds: 60_000_000_000
        )
        store.snapshot = PasteBuddySnapshot(items: [newest, oldest])
        store.primeCaptureHotPathIndexesForTesting()
        let baselineIndexBuildCount = store.dedupeIndexBuildCountForTesting

        let firstCapture = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Mail",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Duplicate Capture One",
            payload: ClipboardPayload(text: "duplicate legacy value")
        ))
        let secondCapture = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Messages",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Duplicate Capture Two",
            payload: ClipboardPayload(text: "duplicate legacy value")
        ))
        store.cancelPendingSaveForTesting()

        XCTAssertEqual(firstCapture.id, newest.id)
        XCTAssertEqual(secondCapture.id, newest.id)
        XCTAssertEqual(store.dedupeIndexBuildCountForTesting, baselineIndexBuildCount)
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

    func testClipboardCollectionIDsHaveStableStringIDsAndLegacyGeneralConfigurationDecodes() throws {
        let pinboardID = try XCTUnwrap(UUID(uuidString: "10000000-2000-3000-4000-500000000000"))

        XCTAssertEqual(ClipboardCollectionID.history.id, "history")
        XCTAssertEqual(ClipboardCollectionID.pasteStack.id, "pasteStack")
        XCTAssertEqual(ClipboardCollectionID.smart(.links).id, "smart:links")
        XCTAssertEqual(ClipboardCollectionID.pinboard(pinboardID).id, "pinboard:\(pinboardID.uuidString)")

        let legacyData = Data(#"{"launchAtLoginEnabled":true}"#.utf8)
        let decoded = try JSONDecoder().decode(GeneralConfiguration.self, from: legacyData)

        XCTAssertTrue(decoded.launchAtLoginEnabled)
        XCTAssertNil(decoded.collectionOrder)
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

    func testEmbeddedTextURLsStayTextButWholeTextURLsAreLinks() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let note = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Plain Note",
            payload: ClipboardPayload(text: "regular note body")
        ))
        let pastedURL = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Messages",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Message With URL",
            payload: ClipboardPayload(text: "Read this: https://example.com/research")
        ))
        let copiedURLText = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Brave Browser",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Pasted URL",
            payload: ClipboardPayload(text: "https://example.com/research")
        ))
        let copiedURLMixed = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Brave Browser",
            deviceName: "Test Mac",
            contentType: .mixed,
            title: "https://example.com/research",
            payload: ClipboardPayload(text: "https://example.com/research")
        ))
        let explicitLink = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Test Mac",
            contentType: .url,
            title: "Research Link",
            payload: ClipboardPayload(urlString: "https://example.com/research")
        ))
        let privatePasteboardToken = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Paste",
            deviceName: "Test Mac",
            contentType: .url,
            title: "UCFP:6526f502-200a-44ef-a5ed-2238",
            payload: ClipboardPayload(urlString: "UCFP:6526f502-200a-44ef-a5ed-2238")
        ))

        XCTAssertFalse(SmartPinboardCategory.links.matches(note))
        XCTAssertTrue(SmartPinboardCategory.text.matches(pastedURL))
        XCTAssertFalse(SmartPinboardCategory.links.matches(pastedURL))
        XCTAssertFalse(SmartPinboardCategory.text.matches(copiedURLText))
        XCTAssertTrue(SmartPinboardCategory.links.matches(copiedURLText))
        XCTAssertFalse(SmartPinboardCategory.text.matches(copiedURLMixed))
        XCTAssertTrue(SmartPinboardCategory.links.matches(copiedURLMixed))
        XCTAssertTrue(SmartPinboardCategory.links.matches(explicitLink))
        XCTAssertTrue(SmartPinboardCategory.text.matches(privatePasteboardToken))
        XCTAssertFalse(SmartPinboardCategory.links.matches(privatePasteboardToken))

        store.contentTypeFilter = .url

        XCTAssertEqual(store.filteredItems.map(\.id), [explicitLink.id, copiedURLMixed.id, copiedURLText.id])
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

    func testStorageSettingsPersistThroughEncryptedStore() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.updateMaxHistoryItems(250)
        store.updateRetentionDays(14)
        store.updateMaxStorageBytes(256 * 1_024 * 1_024)

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertEqual(reloaded.snapshot.storage.maxHistoryItems, 250)
        XCTAssertEqual(reloaded.snapshot.storage.retentionDays, 14)
        XCTAssertEqual(reloaded.snapshot.storage.maxStorageBytes, 256 * 1_024 * 1_024)
    }

    func testGeneralSettingsPersistThroughEncryptedStore() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.setLaunchAtLoginEnabled(true, applySystemRegistration: false)

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertTrue(reloaded.snapshot.general.launchAtLoginEnabled)

        reloaded.setLaunchAtLoginEnabled(false, applySystemRegistration: false)

        XCTAssertFalse(reloaded.snapshot.general.launchAtLoginEnabled)
    }

    func testMacMenuBarStatusReflectsCapturePauseState() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        var status = store.macMenuBarStatus

        XCTAssertEqual(status.title, "PasteBuddy Active")
        XCTAssertEqual(status.systemImageName, "doc.on.clipboard")

        store.pauseCaptureIndefinitely()
        status = store.macMenuBarStatus

        XCTAssertEqual(status.title, "PasteBuddy Paused")
        XCTAssertEqual(status.systemImageName, "pause.circle.fill")

        store.requestSettingsDestination(.privacy)
        XCTAssertEqual(store.requestedSettingsDestination, .privacy)
        store.clearRequestedSettingsDestination()
        XCTAssertNil(store.requestedSettingsDestination)
    }

    func testPastePlainTextDefaultPersistsThroughEncryptedStore() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        XCTAssertEqual(store.defaultPasteFormat, .original)

        store.setAlwaysPasteAsPlainText(true)

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertTrue(reloaded.snapshot.paste.alwaysPasteAsPlainText)
        XCTAssertEqual(reloaded.defaultPasteFormat, .plainText)
    }

    func testDirectPasteResultIsTransientUIState() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let result = DirectPasteResult(
            outcome: .copiedOnlyAccessibilityRequired,
            itemCount: 2,
            format: .plainText,
            occurredAt: Date(timeIntervalSince1970: 10)
        )

        store.recordDirectPasteResult(result)

        XCTAssertEqual(store.lastDirectPasteResult, result)
        XCTAssertTrue(store.lastDirectPasteResult?.statusMessage.contains("Grant Accessibility access") ?? false)
        let guidance = try XCTUnwrap(store.lastDirectPasteResult?.permissionGuidance)
        XCTAssertEqual(guidance.actionTitle, "Request Accessibility Access")
        XCTAssertTrue(guidance.detail.contains("copied your selection"))
        XCTAssertTrue(guidance.detail.contains("Command-V"))

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertNil(reloaded.lastDirectPasteResult)

        store.clearDirectPasteResult()

        XCTAssertNil(store.lastDirectPasteResult)
    }

    func testShortcutConfigurationPersistsAndResets() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        XCTAssertEqual(store.snapshot.shortcuts.quickPasteDisplayName, "⌥⌘1-9")
        XCTAssertEqual(store.snapshot.shortcuts.plainTextQuickPasteDisplayName, "⌃⌥⌘1-9")

        store.setQuickPasteShortcutsEnabled(false)

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertFalse(reloaded.snapshot.shortcuts.isQuickPasteEnabled)

        reloaded.resetShortcutConfiguration()

        XCTAssertTrue(reloaded.snapshot.shortcuts.isQuickPasteEnabled)
        XCTAssertEqual(reloaded.snapshot.shortcuts.showHidePanel.displayName, "⇧⌘V")
    }

    func testShortcutCustomizationPersistsAndSupportsClearedBindings() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)

        store.setShortcutBinding(
            .pasteSelectedItem,
            key: "p",
            modifiers: [.shift, .command, .command]
        )
        store.clearShortcutBinding(.pasteSelectedPlainText)
        store.setQuickPasteModifiers([.control, .command])
        store.setQuickPasteModifiers([.shift], plainText: true)

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertEqual(reloaded.snapshot.shortcuts.pasteSelectedItem.key, "p")
        XCTAssertEqual(reloaded.snapshot.shortcuts.pasteSelectedItem.modifiers, [.shift, .command])
        XCTAssertEqual(reloaded.snapshot.shortcuts.pasteSelectedItem.displayName, "⇧⌘P")
        XCTAssertFalse(reloaded.snapshot.shortcuts.pasteSelectedPlainText.isEnabled)
        XCTAssertEqual(reloaded.snapshot.shortcuts.pasteSelectedPlainText.displayName, "Not set")
        XCTAssertEqual(reloaded.snapshot.shortcuts.quickPasteModifiers, [.control, .command])
        XCTAssertEqual(reloaded.snapshot.shortcuts.plainTextQuickPasteModifiers, [.shift])
    }

    func testShortcutBindingNormalizesWhitespaceKeyAndModifierOrder() {
        let binding = ShortcutBinding(
            key: "  Return  ",
            modifiers: [.shift, .command, .option, .command]
        )

        XCTAssertEqual(binding.key, "r")
        XCTAssertEqual(binding.modifiers, [.option, .shift, .command])
        XCTAssertEqual(binding.displayName, "⌥⇧⌘R")

        var legacyOrderedBinding = ShortcutBinding(key: "v", modifiers: [])
        legacyOrderedBinding.modifiers = [.command, .shift]
        XCTAssertEqual(legacyOrderedBinding.displayName, "⇧⌘V")

        let cleared = ShortcutBinding(key: "   ", modifiers: [.control])

        XCTAssertNil(cleared.key)
        XCTAssertFalse(cleared.isEnabled)
        XCTAssertEqual(cleared.displayName, "Not set")
    }

    func testFreeTrialLifecyclePersistsThroughEncryptedStore() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let now = Date(timeIntervalSince1970: 1_000)

        store.startFreeTrial(days: 14, now: now)

        XCTAssertEqual(store.snapshot.entitlement.plan, .trial)
        XCTAssertEqual(store.snapshot.entitlement.status, .trialing)
        XCTAssertTrue(store.snapshot.entitlement.isTrialActive(now: now.addingTimeInterval(60)))
        XCTAssertTrue(store.snapshot.entitlement.hasFullAccess(now: now.addingTimeInterval(60)))
        let activeOverview = store.snapshot.entitlement.personalOverview(now: now.addingTimeInterval(60))
        XCTAssertEqual(activeOverview.trialState, .active)
        XCTAssertTrue(activeOverview.trialSummary.contains("14 days remaining"))
        XCTAssertTrue(activeOverview.trialOutcomeStatement.contains("When the trial ends"))
        XCTAssertTrue(activeOverview.trialOutcomeStatement.contains("limited mode"))
        XCTAssertTrue(activeOverview.crossDeviceStatement.contains("Mac, iPhone, and iPad"))
        XCTAssertEqual(activeOverview.purchaseOptions.map(\.plan), [.monthly, .annual, .lifetime, .family])
        XCTAssertTrue(activeOverview.billingSafetyStatement.contains("Payment details stay with the App Store"))

        let endingSoonOverview = store.snapshot.entitlement.personalOverview(now: now.addingTimeInterval(12 * 24 * 60 * 60))
        XCTAssertEqual(endingSoonOverview.trialState, .endingSoon)

        let endedOverview = store.snapshot.entitlement.personalOverview(now: now.addingTimeInterval(15 * 24 * 60 * 60))
        XCTAssertEqual(endedOverview.trialState, .ended)
        XCTAssertTrue(endedOverview.trialSummary.contains("Trial ended"))
        XCTAssertTrue(endedOverview.trialOutcomeStatement.contains("do not delete local clipboard data"))

        store.cancelFreeTrial(now: now.addingTimeInterval(120))

        XCTAssertEqual(store.snapshot.entitlement.status, .canceled)
        XCTAssertFalse(store.snapshot.entitlement.hasFullAccess(now: now.addingTimeInterval(180)))
        let canceledOverview = store.snapshot.entitlement.personalOverview(now: now.addingTimeInterval(180))
        XCTAssertEqual(canceledOverview.trialState, .canceled)
        XCTAssertTrue(canceledOverview.trialSummary.contains("Trial canceled"))

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertEqual(reloaded.snapshot.entitlement.plan, .trial)
        XCTAssertEqual(reloaded.snapshot.entitlement.status, .canceled)
        let trialCanceledAt = try XCTUnwrap(reloaded.snapshot.entitlement.trialCanceledAt)
        XCTAssertEqual(trialCanceledAt.timeIntervalSince1970, now.addingTimeInterval(120).timeIntervalSince1970, accuracy: 0.001)
    }

    func testPaidPlansUnlockAllDevicesAndCanExpire() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let now = Date()
        let renewal = now.addingTimeInterval(30 * 24 * 60 * 60)

        store.activatePersonalPlan(.monthly, purchasedAt: now, currentPeriodEndsAt: renewal)

        XCTAssertEqual(store.snapshot.entitlement.plan, .monthly)
        XCTAssertEqual(store.snapshot.entitlement.status, .active)
        XCTAssertTrue(store.snapshot.entitlement.unlocksAllDevicesForAccount)
        XCTAssertTrue(store.snapshot.entitlement.hasActivePaidAccess(now: now.addingTimeInterval(60)))
        let activeOverview = store.snapshot.entitlement.personalOverview(now: now.addingTimeInterval(60))
        XCTAssertEqual(activeOverview.accessState, "Unlocked")
        XCTAssertEqual(activeOverview.trialState, .converted)
        XCTAssertTrue(activeOverview.crossDeviceStatement.contains("same paid feature set"))
        XCTAssertTrue(activeOverview.crossDeviceStatement.contains("Mac, iPhone, and iPad"))

        store.markEntitlementExpired(at: now.addingTimeInterval(120))

        XCTAssertEqual(store.snapshot.entitlement.status, .expired)
        XCTAssertFalse(store.snapshot.entitlement.hasFullAccess(now: now.addingTimeInterval(180)))
        let expiredOverview = store.snapshot.entitlement.personalOverview(now: now.addingTimeInterval(180))
        XCTAssertEqual(expiredOverview.accessState, "Limited")
        XCTAssertTrue(expiredOverview.crossDeviceStatement.contains("No active paid entitlement"))
    }

    func testRestorePurchasesStatePersistsThroughEncryptedStore() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let startedAt = Date()
        let restoredAt = startedAt.addingTimeInterval(30)

        store.markRestorePurchasesStarted(at: startedAt)
        let restoringOverview = store.snapshot.entitlement.personalOverview(now: startedAt.addingTimeInterval(1))
        XCTAssertTrue(restoringOverview.restoreSummary.contains("checking StoreKit"))
        XCTAssertTrue(restoringOverview.restoreActionStatement.contains("verified active entitlement"))

        store.markRestorePurchasesRestored(at: restoredAt)

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        if case .restored(let date) = reloaded.snapshot.entitlement.restoreState {
            XCTAssertEqual(date.timeIntervalSince1970, restoredAt.timeIntervalSince1970, accuracy: 0.001)
        } else {
            XCTFail("Expected restored purchase state.")
        }

        let restoredOverview = reloaded.snapshot.entitlement.personalOverview(now: restoredAt.addingTimeInterval(1))
        XCTAssertTrue(restoredOverview.restoreSummary.contains("Restore completed"))
        XCTAssertTrue(restoredOverview.restoreActionStatement.contains("Mac, iPhone, or iPad") || restoredOverview.restoreActionStatement.contains("supported devices"))
    }

    func testSecuritySettingsToggleEncryptionAndTouchIDHistoryLock() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        harness.snapshotStore.storageMode = .standard
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            historyUnlockAuthenticator: FakeHistoryUnlockAuthenticator(result: true)
        )

        store.addCapturedItem(ClipboardItem(
            sourceAppName: "Unit Test",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Visible Secret",
            payload: ClipboardPayload(text: "clipboard content")
        ))

        XCTAssertEqual(store.snapshot.security.storageMode, .standard)
        XCTAssertFalse(store.snapshot.security.requiresBiometricUnlock)
        XCTAssertEqual(store.filteredItems.map(\.title), ["Visible Secret"])

        store.setBiometricHistoryLockEnabled(true)

        XCTAssertTrue(store.snapshot.security.requiresBiometricUnlock)
        XCTAssertTrue(store.isHistoryAccessLocked)
        XCTAssertTrue(store.filteredItems.isEmpty)
        XCTAssertEqual(store.historyAccessStatusLine, "History locked until Touch ID unlock")

        let didUnlock = await store.unlockHistoryWithTouchID()

        XCTAssertTrue(didUnlock)
        XCTAssertFalse(store.isHistoryAccessLocked)
        XCTAssertEqual(store.filteredItems.map(\.title), ["Visible Secret"])

        await store.setHistoryEncryptionEnabled(true)

        XCTAssertEqual(store.snapshot.security.storageMode, .encrypted)
        XCTAssertEqual(harness.snapshotStore.storageMode, .encrypted)
        let encryptedRaw = String(decoding: try Data(contentsOf: harness.snapshotStore.fileURL), as: UTF8.self)
        XCTAssertFalse(encryptedRaw.contains("Visible Secret"))
        XCTAssertFalse(encryptedRaw.contains("clipboard content"))

        await store.setHistoryEncryptionEnabled(false)

        XCTAssertEqual(store.snapshot.security.storageMode, .standard)
        XCTAssertEqual(harness.snapshotStore.storageMode, .standard)
        let standardRaw = String(decoding: try Data(contentsOf: harness.snapshotStore.fileURL), as: UTF8.self)
        XCTAssertTrue(standardRaw.contains("Visible Secret"))
        XCTAssertTrue(standardRaw.contains("clipboard content"))
    }

    func testIdempotentEncryptionEnableDoesNotCancelPendingEncryptedSave() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        harness.snapshotStore.storageMode = .encrypted
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            saveDebounceNanoseconds: 60_000_000_000
        )
        let pendingItem = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Pending Encrypted Item",
            payload: ClipboardPayload(text: "pending encrypted payload")
        ))

        await store.setHistoryEncryptionEnabled(true)
        let didFlush = await store.flushPendingSave()

        XCTAssertTrue(didFlush)
        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()
        XCTAssertEqual(reloaded.snapshot.items.map(\.id), [pendingItem.id])
    }

    func testEnablingEncryptionRemovesPlaintextRepositoryAndPreservesBinaryAssets() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let databaseURL = harness.directory.appendingPathComponent("clipboard.sqlite")
        let repository = ClipboardItemRepository(database: try PasteBuddyDatabase(fileURL: databaseURL))
        harness.snapshotStore.storageMode = .standard
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository
        )
        let imageData = Data(repeating: 0xAB, count: 8_192)
        let rtfData = Data("{\\rtf1 encrypted repository migration}".utf8)
        let item = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .mixed,
            title: "Repository Plaintext Secret",
            payload: ClipboardPayload(
                text: "repository plaintext body",
                rtfData: rtfData,
                imageData: imageData,
                ocrText: "repository plaintext OCR"
            )
        ))

        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))

        await store.setHistoryEncryptionEnabled(true)

        XCTAssertFalse(store.isPersistenceWriteBlocked, store.lastErrorMessage ?? "")
        XCTAssertEqual(store.snapshot.security.storageMode, .encrypted)
        for url in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Plaintext repository residue: \(url.path)")
        }
        let rawEnvelope = String(decoding: try Data(contentsOf: harness.snapshotStore.fileURL), as: UTF8.self)
        XCTAssertFalse(rawEnvelope.contains("Repository Plaintext Secret"))
        XCTAssertFalse(rawEnvelope.contains("repository plaintext body"))

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()
        let reloadedItem = try XCTUnwrap(reloaded.snapshot.items.first(where: { $0.id == item.id }))
        XCTAssertEqual(reloadedItem.payload.imageData, imageData)
        XCTAssertEqual(reloadedItem.payload.rtfData, rtfData)

        await store.setHistoryEncryptionEnabled(false)

        XCTAssertFalse(store.isPersistenceWriteBlocked, store.lastErrorMessage ?? "")
        XCTAssertEqual(store.snapshot.security.storageMode, .standard)
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
        let restoredRepository = ClipboardItemRepository(
            database: try PasteBuddyDatabase(fileURL: databaseURL)
        )
        let restoredItem = try XCTUnwrap(restoredRepository.exportSnapshot().items.first(where: { $0.id == item.id }))
        XCTAssertEqual(restoredItem.payload.imageData, imageData)
        XCTAssertEqual(restoredItem.payload.rtfData, rtfData)
    }

    func testDisablingEncryptionResynchronizesRepositoryAfterCaptureDuringDiskPersistence() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let databaseURL = harness.directory.appendingPathComponent("disable-encryption-race.sqlite")
        let repository = ClipboardItemRepository(database: try PasteBuddyDatabase(fileURL: databaseURL))
        harness.snapshotStore.storageMode = .standard
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository,
            saveDebounceNanoseconds: 60_000_000_000
        )
        _ = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Before Encryption Disable",
            payload: ClipboardPayload(text: "before encryption disable")
        ))
        let didFlushSeed = await store.flushPendingSave()
        XCTAssertTrue(didFlushSeed)
        await store.setHistoryEncryptionEnabled(true)
        XCTAssertEqual(store.snapshot.security.storageMode, .encrypted)

        let persistenceGate = SuspendedStoreLoadGate()
        store.beforePersistingStandardMigrationSnapshotForTesting = {
            await persistenceGate.suspend()
        }
        let disableTask = Task { @MainActor in
            await store.setHistoryEncryptionEnabled(false)
        }
        while await !persistenceGate.hasSuspended() {
            await Task.yield()
        }
        let concurrentCapture = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Messages",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Captured While Disabling Encryption",
            payload: ClipboardPayload(text: "must reach both standard stores")
        ))
        await persistenceGate.resume()
        await disableTask.value

        XCTAssertFalse(store.isPersistenceWriteBlocked, store.lastErrorMessage ?? "")
        XCTAssertEqual(store.snapshot.security.storageMode, .standard)
        let restoredRepository = ClipboardItemRepository(
            database: try PasteBuddyDatabase(fileURL: databaseURL)
        )
        XCTAssertTrue(try restoredRepository.exportSnapshot().items.contains(where: { $0.id == concurrentCapture.id }))
        let reloaded = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: restoredRepository
        )
        reloaded.load()
        XCTAssertTrue(reloaded.snapshot.items.contains(where: { $0.id == concurrentCapture.id }))
    }

    func testEncryptionMigrationPreservesCaptureCreatedWhileHydrationIsSuspended() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        harness.snapshotStore.storageMode = .standard
        let databaseURL = harness.directory.appendingPathComponent("clipboard.sqlite")
        let repository = ClipboardItemRepository(database: try PasteBuddyDatabase(fileURL: databaseURL))
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository,
            saveDebounceNanoseconds: 60_000_000_000
        )
        _ = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Before Migration",
            payload: ClipboardPayload(text: "before migration secret")
        ))
        let didFlushSeed = await store.flushPendingSave()
        XCTAssertTrue(didFlushSeed)

        let migrationGate = SuspendedStoreLoadGate()
        store.beforeCommittingHistoryStorageMigrationForTesting = {
            await migrationGate.suspend()
        }
        let migrationTask = Task { @MainActor in
            await store.setHistoryEncryptionEnabled(true)
        }
        while await !migrationGate.hasSuspended() {
            await Task.yield()
        }
        let concurrentCapture = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Terminal",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Captured During Migration",
            payload: ClipboardPayload(text: "capture during migration secret")
        ))

        await migrationGate.resume()
        await migrationTask.value
        store.beforeCommittingHistoryStorageMigrationForTesting = nil

        XCTAssertFalse(store.isPersistenceWriteBlocked, store.lastErrorMessage ?? "")
        XCTAssertEqual(store.snapshot.security.storageMode, .encrypted)
        XCTAssertTrue(store.snapshot.items.contains(where: { $0.id == concurrentCapture.id }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))
        let encryptedRaw = String(
            decoding: try Data(contentsOf: harness.snapshotStore.fileURL),
            as: UTF8.self
        )
        XCTAssertFalse(encryptedRaw.contains("Captured During Migration"))
        XCTAssertFalse(encryptedRaw.contains("capture during migration secret"))

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()
        XCTAssertTrue(reloaded.snapshot.items.contains(where: { $0.id == concurrentCapture.id }))
    }

    func testStoreLoadPreservesLegacyEncryptedSnapshotStorageMode() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let legacyItem = ClipboardItem(
            sourceAppName: "Unit Test",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Legacy Secret",
            payload: ClipboardPayload(text: "legacy encrypted content")
        )
        var legacySnapshot = PasteBuddySnapshot(items: [legacyItem])
        legacySnapshot.security.storageMode = .encrypted
        harness.snapshotStore.storageMode = .encrypted
        try harness.snapshotStore.save(legacySnapshot)

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.load()

        XCTAssertEqual(store.snapshot.security.storageMode, .encrypted)
        XCTAssertEqual(harness.snapshotStore.storageMode, .encrypted)
        XCTAssertEqual(store.filteredItems.map(\.title), ["Legacy Secret"])

        store.addCapturedItem(ClipboardItem(
            sourceAppName: "Unit Test",
            deviceName: "Test Mac",
            contentType: .text,
            title: "New Encrypted Item",
            payload: ClipboardPayload(text: "new encrypted content")
        ))

        let encryptedRaw = String(decoding: try Data(contentsOf: harness.snapshotStore.fileURL), as: UTF8.self)
        XCTAssertFalse(encryptedRaw.contains("legacy encrypted content"))
        XCTAssertFalse(encryptedRaw.contains("new encrypted content"))
    }

    func testTeamPlanSeatBillingMetadataPersistsThroughEncryptedStore() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)

        store.configureTeamPlan(
            teamName: "Acme Design",
            seatCount: 12,
            assignedSeatCount: 5,
            pricePerSeatCents: 1_500,
            billingCurrencyCode: "usd",
            singleInvoiceEnabled: true,
            managedDistributionEnabled: true,
            adminEmailAddress: "admin@example.com"
        )

        XCTAssertEqual(store.snapshot.entitlement.plan, .team)
        XCTAssertEqual(store.snapshot.entitlement.status, .active)
        XCTAssertTrue(store.snapshot.entitlement.hasFullAccess())
        XCTAssertEqual(store.snapshot.entitlement.team?.displayName, "Acme Design")
        XCTAssertEqual(store.snapshot.entitlement.team?.billingCurrencyCode, "USD")
        XCTAssertEqual(store.snapshot.entitlement.team?.monthlyInvoiceCents, 18_000)
        XCTAssertEqual(store.snapshot.entitlement.team?.availableSeatCount, 7)
        XCTAssertTrue(store.snapshot.entitlement.team?.singleInvoiceEnabled == true)
        XCTAssertTrue(store.snapshot.entitlement.team?.managedDistributionEnabled == true)
        XCTAssertFalse(store.snapshot.entitlement.plan.isPersonalPaidPlan)

        let overview = try XCTUnwrap(store.snapshot.entitlement.teamOverview)
        XCTAssertEqual(overview.teamName, "Acme Design")
        XCTAssertEqual(overview.adminSummary, "Admin: admin@example.com")
        XCTAssertEqual(overview.seatSummary, "5/12 seats assigned, 7 available")
        XCTAssertTrue(overview.billingSummary.contains("Single invoice"))
        XCTAssertTrue(overview.billingSummary.contains("USD 180.00"))
        XCTAssertTrue(overview.distributionSummary.contains("Managed distribution enabled"))
        XCTAssertTrue(overview.primaryValueStatement.contains("shared pinboards"))
        XCTAssertTrue(overview.primaryValueStatement.contains("ideas, links, files"))
        XCTAssertTrue(overview.purchasePositioning.contains("distinct from personal"))
        XCTAssertTrue(overview.purchasePositioning.contains("seat billing"))
        XCTAssertEqual(
            overview.valuePropositions.map(\.id),
            ["shared-pinboards", "stay-in-sync", "admin-seat-state"]
        )

        store.updateTeamSeatAssignment(20)

        XCTAssertEqual(store.snapshot.entitlement.team?.assignedSeatCount, 12)
        XCTAssertEqual(store.snapshot.entitlement.team?.availableSeatCount, 0)

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertEqual(reloaded.snapshot.entitlement.plan, .team)
        XCTAssertEqual(reloaded.snapshot.entitlement.team?.assignedSeatCount, 12)
        XCTAssertEqual(reloaded.snapshot.entitlement.team?.adminEmailAddress, "admin@example.com")
    }

    func testSnapshotDecodingDefaultsMissingEntitlement() throws {
        let data = Data(#"{"schemaVersion":1}"#.utf8)

        let snapshot = try JSONDecoder().decode(PasteBuddySnapshot.self, from: data)

        XCTAssertEqual(snapshot.entitlement.plan, .free)
        XCTAssertEqual(snapshot.entitlement.status, .inactive)
        XCTAssertFalse(snapshot.entitlement.hasFullAccess())
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

    func testBulkIDMutationsReuseOneSnapshotItemIndex() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let items = (0..<80).map { index in
            ClipboardItem(
                sourceAppName: "Notes",
                deviceName: "Test Mac",
                contentType: .text,
                title: "Indexed Item \(index)",
                payload: ClipboardPayload(text: "indexed item body \(index)")
            )
        }
        let pinboard = Pinboard(
            name: "Indexed",
            colorHex: "#4EA7FC",
            itemIDs: items.map(\.id)
        )
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            saveDebounceNanoseconds: 60_000_000_000
        )
        store.snapshot = PasteBuddySnapshot(items: items, pinboards: [pinboard])
        let baselineBuildCount = store.itemByIDIndexBuildCountForTesting

        XCTAssertTrue(store.addItemsToPasteStack([items[79].id, items[2].id, items[79].id, UUID()]))
        XCTAssertEqual(store.pasteStackItems.map(\.id), [items[79].id, items[2].id])
        XCTAssertEqual(store.itemByIDIndexBuildCountForTesting, baselineBuildCount + 1)

        XCTAssertTrue(store.addItemsToPasteStack([items[40].id]))
        XCTAssertEqual(store.itemByIDIndexBuildCountForTesting, baselineBuildCount + 1)

        store.removeItems([items[79].id, items[2].id, items[79].id, UUID()])

        XCTAssertEqual(store.lastDeletedItems.map(\.item.id), [items[79].id, items[2].id])
        XCTAssertEqual(store.lastDeletedItems.map(\.pinboardIDs), [[pinboard.id], [pinboard.id]])
        XCTAssertEqual(store.itemByIDIndexBuildCountForTesting, baselineBuildCount + 1)
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

    func testPrivacySettingsPersistThroughEncryptedStore() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.toggleCapturePaused()
        store.toggleOCR()
        store.toggleTextCapture()
        store.toggleURLCapture()
        store.toggleFileCapture()
        store.toggleImageCapture()
        store.toggleSensitiveTextBlocking()
        store.excludeCurrentApplication(named: "Password Vault", bundleIdentifier: "com.example.password-vault")

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertTrue(reloaded.snapshot.privacy.isCapturePaused)
        XCTAssertFalse(reloaded.snapshot.privacy.runLocalOCRAfterImageCapture)
        XCTAssertFalse(reloaded.snapshot.privacy.captureText)
        XCTAssertFalse(reloaded.snapshot.privacy.captureURLs)
        XCTAssertFalse(reloaded.snapshot.privacy.captureFiles)
        XCTAssertFalse(reloaded.snapshot.privacy.captureImages)
        XCTAssertFalse(reloaded.snapshot.privacy.blockLikelySensitiveText)
        XCTAssertTrue(reloaded.snapshot.privacy.excludedApplicationNames.contains("Password Vault"))
        XCTAssertTrue(reloaded.snapshot.privacy.excludedBundleIdentifiers.contains("com.example.password-vault"))
    }

    func testCustomCaptureRulesPersistEncryptedAndCanBeToggled() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let rule = try XCTUnwrap(store.addCaptureRule(
            name: "Payroll drafts",
            condition: .containsText,
            pattern: "do-not-save-payroll",
            contentTypes: [.text]
        ))

        store.setCaptureRule(rule.id, enabled: false)

        let raw = try Data(contentsOf: harness.snapshotStore.fileURL)
        let rawString = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(rawString.contains("Payroll drafts"))
        XCTAssertFalse(rawString.contains("do-not-save-payroll"))

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertEqual(reloaded.snapshot.privacy.customCaptureRules.count, 1)
        XCTAssertEqual(reloaded.snapshot.privacy.customCaptureRules[0].name, "Payroll drafts")
        XCTAssertEqual(reloaded.snapshot.privacy.customCaptureRules[0].condition, .containsText)
        XCTAssertEqual(reloaded.snapshot.privacy.customCaptureRules[0].pattern, "do-not-save-payroll")
        XCTAssertEqual(reloaded.snapshot.privacy.customCaptureRules[0].contentTypes, [.text])
        XCTAssertFalse(reloaded.snapshot.privacy.customCaptureRules[0].isEnabled)

        reloaded.removeCaptureRule(rule.id)

        XCTAssertTrue(reloaded.snapshot.privacy.customCaptureRules.isEmpty)
    }

    func testTimedCapturePauseExpiresAndResumeClearsPauseUntil() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let now = Date()

        store.pauseCapture(for: 15 * 60, now: now)

        XCTAssertFalse(store.snapshot.privacy.isCapturePaused)
        XCTAssertTrue(store.snapshot.privacy.isCaptureCurrentlyPaused(now: now.addingTimeInterval(60)))
        XCTAssertFalse(store.snapshot.privacy.isCaptureCurrentlyPaused(now: now.addingTimeInterval(16 * 60)))

        store.resumeCapture()

        XCTAssertFalse(store.isCapturePaused)
        XCTAssertNil(store.snapshot.privacy.capturePauseUntil)
    }

    func testPrivacyPostureReportCoversSurfacesBoundariesAndPausedState() {
        let now = Date()
        let pauseUntil = now.addingTimeInterval(900)
        let payrollRule = CaptureRule(
            name: "Payroll",
            condition: .containsText,
            pattern: "payroll",
            contentTypes: [.text]
        )
        var snapshot = PasteBuddySnapshot()
        snapshot.privacy = PrivacyConfiguration(
            capturePauseUntil: pauseUntil,
            captureText: false,
            customCaptureRules: [payrollRule]
        )
        snapshot.sync = SyncConfiguration(
            provider: .cloudKit,
            isCloudSyncEnabled: true,
            cloudKitContainerIdentifier: "iCloud.com.example.PasteBuddy",
            isCloudKitCapabilityConfigured: true
        )
        snapshot.mcp = MCPConfiguration(isServerEnabled: true, enabledTools: [.searchHistory])

        let report = snapshot.privacyPostureReport(now: now)

        XCTAssertEqual(report.captureStatus, .pausedUntil(pauseUntil))
        XCTAssertEqual(report.protectedSurfaces, Set(PrivacyProtectedSurface.allCases))
        XCTAssertEqual(report.disabledContentTypes, [.text])
        XCTAssertEqual(report.activeCustomCaptureRuleCount, 1)
        XCTAssertTrue(report.sensitiveTextBlockingEnabled)
        XCTAssertTrue(report.coverageStatement.contains("history"))
        XCTAssertTrue(report.coverageStatement.contains("pinboards"))
        XCTAssertTrue(report.coverageStatement.contains("Shortcuts"))
        XCTAssertTrue(report.coverageStatement.contains("keyboard"))
        XCTAssertTrue(report.coverageStatement.contains("MCP"))
        XCTAssertEqual(report.localBoundaryStatement, "message.clipboard_payloads_screenshots_ocr_metadata_thumbnails_privacy")
        XCTAssertTrue(report.syncBoundaryStatement.contains("private iCloud"))
        XCTAssertFalse(report.syncBoundaryStatement.contains("encrypted records"))
        XCTAssertTrue(report.vendorServerStatement.contains("does not send clipboard payloads to vendor servers"))
        XCTAssertTrue(report.mcpBoundaryStatement.contains("MCP Agent connection is on"))
    }

    func testPrivacyConfigurationCaptureRules() {
        let privacy = PrivacyConfiguration(
            captureText: false,
            captureURLs: false,
            captureFiles: false,
            captureImages: false
        )

        XCTAssertFalse(privacy.allowsCapture(of: .text))
        XCTAssertFalse(privacy.allowsCapture(of: .url))
        XCTAssertFalse(privacy.allowsCapture(of: .file))
        XCTAssertFalse(privacy.allowsCapture(of: .image))
    }

    func testSensitiveContentDetectorBlocksLikelySecretsButAllowsNormalText() {
        XCTAssertTrue(SensitiveContentDetector.isLikelySensitive("api_key = sk_live_51ABCDEF0123456789"))
        XCTAssertTrue(SensitiveContentDetector.isLikelySensitive("One-time code: 483920"))
        XCTAssertTrue(SensitiveContentDetector.isLikelySensitive("card 4111 1111 1111 1111"))
        XCTAssertFalse(SensitiveContentDetector.isLikelySensitive("Quarterly launch checklist and copy notes"))
    }

    func testPrivacyConfigurationExcludesSensitiveAppsByBundleIdentifier() {
        let privacy = PrivacyConfiguration()

        XCTAssertTrue(privacy.excludesApplication(named: "Renamed Vault", bundleIdentifier: "com.1password.1password"))
        XCTAssertTrue(privacy.excludesApplication(named: "Passwords", bundleIdentifier: nil))
        XCTAssertFalse(privacy.excludesApplication(named: "Notes", bundleIdentifier: "com.apple.Notes"))
    }

    func testCustomCaptureRulesMatchTextSourceBundleURLAndFiles() {
        let textRule = CaptureRule(
            name: "Internal payroll",
            condition: .containsText,
            pattern: "payroll",
            contentTypes: [.text]
        )
        let bundleRule = CaptureRule(
            name: "Private browser",
            condition: .sourceBundleIdentifier,
            pattern: "com.private.browser"
        )
        let urlRule = CaptureRule(
            name: "Staging host",
            condition: .urlHost,
            pattern: "staging.example.com",
            contentTypes: [.url]
        )
        let fileRule = CaptureRule(
            name: "Raw keys",
            condition: .fileExtension,
            pattern: ".pem",
            contentTypes: [.file]
        )
        let regexRule = CaptureRule(
            name: "Ticket IDs",
            condition: .regularExpression,
            pattern: #"INC-\d{4}"#
        )
        let privacy = PrivacyConfiguration(customCaptureRules: [
            textRule,
            bundleRule,
            urlRule,
            fileRule,
            regexRule
        ])

        let text = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Comp Plan",
            payload: ClipboardPayload(text: "Payroll draft")
        )
        let url = ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Test Mac",
            contentType: .url,
            title: "Staging",
            payload: ClipboardPayload(urlString: "https://staging.example.com/admin")
        )
        let file = ClipboardItem(
            sourceAppName: "Finder",
            deviceName: "Test Mac",
            contentType: .file,
            title: "Key",
            payload: ClipboardPayload(fileURLString: "file:///Users/test/key.pem")
        )
        let ticket = ClipboardItem(
            sourceAppName: "Messages",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Incident",
            payload: ClipboardPayload(text: "INC-4821 needs review")
        )
        let allowed = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Lunch",
            payload: ClipboardPayload(text: "menu")
        )

        XCTAssertEqual(privacy.blockingCaptureRule(for: text)?.id, textRule.id)
        XCTAssertEqual(privacy.blockingCaptureRule(for: allowed, sourceBundleIdentifier: "com.private.browser")?.id, bundleRule.id)
        XCTAssertEqual(privacy.blockingCaptureRule(for: url)?.id, urlRule.id)
        XCTAssertEqual(privacy.blockingCaptureRule(for: file)?.id, fileRule.id)
        XCTAssertEqual(privacy.blockingCaptureRule(for: ticket)?.id, regexRule.id)
        XCTAssertNil(privacy.blockingCaptureRule(for: allowed, sourceBundleIdentifier: "com.apple.Notes"))
    }

    func testSyncDefaultsToLocalOnlyWithoutPlaintextFallback() {
        let sync = PasteBuddySnapshot().sync

        XCTAssertEqual(sync.provider, .none)
        XCTAssertFalse(sync.isCloudSyncEnabled)
        XCTAssertFalse(sync.isSharedPinboardsEnabled)
        XCTAssertFalse(sync.allowsPlaintextFallback)
        XCTAssertEqual(sync.readiness, .localOnly)
        XCTAssertFalse(sync.readiness.canAttemptCloudSync)
    }

    func testCloudSyncRequiresEncryptedCloudKitConfiguration() {
        var sync = SyncConfiguration(
            provider: .cloudKit,
            isCloudSyncEnabled: true,
            cloudKitContainerIdentifier: "iCloud.com.example.PasteBuddy"
        )

        XCTAssertEqual(sync.readiness, .blocked([.endToEndKeyHierarchy, .cloudKitCapability]))
        XCTAssertFalse(sync.readiness.canAttemptCloudSync)

        sync.isCloudKitCapabilityConfigured = true

        XCTAssertEqual(sync.readiness, .blocked([.endToEndKeyHierarchy]))
        XCTAssertFalse(sync.readiness.canAttemptCloudSync)

        sync.keyHierarchyVersion = 1

        XCTAssertEqual(sync.readiness, .ready)
        XCTAssertTrue(sync.readiness.canAttemptCloudSync)
        XCTAssertFalse(sync.allowsPlaintextFallback)
    }

    func testCloudSyncPreflightExplainsLocalOnlyModeAndEncryptionBoundary() {
        let report = CloudSyncPreflightReport(configuration: PasteBuddySnapshot().sync)

        XCTAssertEqual(report.readiness, .localOnly)
        XCTAssertFalse(report.canAttemptCloudSync)
        XCTAssertFalse(report.hasBlockers)
        XCTAssertEqual(report.summary, "Local only: CloudKit sync is disabled.")
        XCTAssertTrue(report.findings.contains { $0.id == "cloud-sync-local-only" })
    }

    func testCloudSyncPreflightReportsMissingRequirementsAndSharedPinboardBlocker() {
        let sync = SyncConfiguration(
            provider: .cloudKit,
            isCloudSyncEnabled: true,
            isSharedPinboardsEnabled: true
        )

        let report = CloudSyncPreflightReport(configuration: sync)

        XCTAssertEqual(
            report.readiness,
            .blocked([.cloudKitContainerIdentifier, .endToEndKeyHierarchy, .cloudKitCapability])
        )
        XCTAssertFalse(report.canAttemptCloudSync)
        XCTAssertTrue(report.hasBlockers)
        XCTAssertEqual(report.summary, "CloudKit sync is blocked by 4 required setup items.")
        XCTAssertTrue(report.findings.contains { $0.id == "missing-cloudkit-container" })
        XCTAssertTrue(report.findings.contains { $0.id == "missing-end-to-end-key-hierarchy" })
        XCTAssertTrue(report.findings.contains { $0.id == "missing-cloudkit-capability" })
        XCTAssertTrue(report.findings.contains { $0.id == "shared-pinboards-blocked" })
    }

    func testCloudSyncPreflightWarnsWhenReadyButFirstSyncOrConflictReviewIsPending() {
        var sync = SyncConfiguration(
            provider: .cloudKit,
            isCloudSyncEnabled: true,
            cloudKitContainerIdentifier: "iCloud.com.example.PasteBuddy",
            keyHierarchyVersion: 1,
            isCloudKitCapabilityConfigured: true,
            lastSyncConflictCount: 2
        )

        var report = CloudSyncPreflightReport(configuration: sync)

        XCTAssertEqual(report.readiness, .ready)
        XCTAssertTrue(report.canAttemptCloudSync)
        XCTAssertFalse(report.hasBlockers)
        XCTAssertEqual(report.summary, "Encrypted CloudKit sync is ready with 2 warnings.")
        XCTAssertTrue(report.findings.contains { $0.id == "cloud-sync-ready" })
        XCTAssertTrue(report.findings.contains { $0.id == "first-sync-pending" })
        XCTAssertTrue(report.findings.contains { $0.id == "last-sync-conflicts" })

        sync.lastSyncAt = Date()
        sync.lastSyncConflictCount = 0
        report = CloudSyncPreflightReport(configuration: sync)

        XCTAssertEqual(report.summary, "Encrypted CloudKit sync is ready.")
        XCTAssertFalse(report.findings.contains { $0.severity == .warning })
    }

    func testSharedPinboardsRequireReadyEncryptedSync() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.setSharedPinboardsEnabled(true)

        XCTAssertFalse(store.snapshot.sync.isSharedPinboardsEnabled)
        XCTAssertEqual(store.lastErrorMessage, "Shared pinboards require configured CloudKit sync and end-to-end encryption.")

        store.configureCloudKitSync(
            containerIdentifier: "iCloud.com.example.PasteBuddy",
            keyHierarchyVersion: 1,
            capabilityConfigured: true
        )
        store.setSharedPinboardsEnabled(true)

        XCTAssertEqual(store.snapshot.sync.readiness, .ready)
        XCTAssertTrue(store.snapshot.sync.isSharedPinboardsEnabled)

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertEqual(reloaded.snapshot.sync.readiness, .ready)
        XCTAssertTrue(reloaded.snapshot.sync.isSharedPinboardsEnabled)
        XCTAssertFalse(reloaded.snapshot.sync.allowsPlaintextFallback)
    }

    func testSharedPinboardParticipantManagementRequiresEncryptedSync() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let pinboardID = store.snapshot.pinboards[0].id

        XCTAssertNil(store.sharePinboard(pinboardID))
        XCTAssertNil(store.snapshot.pinboards[0].sharing)

        store.configureCloudKitSync(
            containerIdentifier: "iCloud.com.example.PasteBuddy",
            keyHierarchyVersion: 1,
            capabilityConfigured: true
        )
        store.setSharedPinboardsEnabled(true)

        let token = try XCTUnwrap(store.sharePinboard(
            pinboardID,
            ownerDisplayName: "Owner Mac",
            accessMode: .linkAccess,
            defaultPermission: .readOnly,
            linkToken: "single-use-share-token"
        ))

        XCTAssertEqual(token, "single-use-share-token")
        XCTAssertEqual(store.snapshot.pinboards[0].sharing?.ownerDisplayName, "Owner Mac")
        XCTAssertEqual(store.snapshot.pinboards[0].sharing?.accessMode, .linkAccess)
        XCTAssertNotNil(store.snapshot.pinboards[0].sharing?.shareLinkTokenHash)
        XCTAssertNotEqual(store.snapshot.pinboards[0].sharing?.shareLinkTokenHash, token)

        let participant = try XCTUnwrap(store.inviteParticipant(
            to: pinboardID,
            displayName: "Collaborator",
            emailAddress: "collaborator@example.com",
            permission: .readOnly
        ))

        XCTAssertEqual(store.snapshot.pinboards[0].sharing?.participants.count, 1)
        XCTAssertEqual(store.snapshot.pinboards[0].sharing?.participants.first?.permission, .readOnly)

        store.updateParticipantPermission(
            pinboardID: pinboardID,
            participantID: participant.id,
            permission: .canEdit
        )

        XCTAssertEqual(store.snapshot.pinboards[0].sharing?.participants.first?.permission, .canEdit)

        store.removeParticipant(pinboardID: pinboardID, participantID: participant.id)

        XCTAssertEqual(store.snapshot.pinboards[0].sharing?.participants, [])

        store.stopSharingPinboard(pinboardID)

        XCTAssertNil(store.snapshot.pinboards[0].sharing)
    }

    func testDisablingSharedPinboardsStopsSharingAllBoardsAndPersists() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let favoritesID = store.snapshot.pinboards[0].id
        store.createPinboard(named: "Launch")
        let launchID = store.snapshot.pinboards.last!.id
        store.configureCloudKitSync(
            containerIdentifier: "iCloud.com.example.PasteBuddy",
            keyHierarchyVersion: 1,
            capabilityConfigured: true
        )
        store.setSharedPinboardsEnabled(true)

        XCTAssertNotNil(store.sharePinboard(favoritesID, accessMode: .linkAccess, linkToken: "favorites-token"))
        _ = store.sharePinboard(launchID, defaultPermission: .canEdit)
        XCTAssertNotNil(store.snapshot.pinboards.first(where: { $0.id == launchID })?.sharing)

        store.setSharedPinboardsEnabled(false)

        XCTAssertFalse(store.snapshot.sync.isSharedPinboardsEnabled)
        XCTAssertTrue(store.snapshot.pinboards.allSatisfy { $0.sharing == nil })

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertFalse(reloaded.snapshot.sync.isSharedPinboardsEnabled)
        XCTAssertTrue(reloaded.snapshot.pinboards.allSatisfy { $0.sharing == nil })
    }

    func testSharedPinboardKeyExchangeWrapsBoardKeyForParticipant() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let pinboardID = store.snapshot.pinboards[0].id
        let keyExchangeService = PinboardShareKeyExchangeService()
        let ownerIdentity = keyExchangeService.makeIdentity()
        let participantIdentity = keyExchangeService.makeIdentity()
        let acceptedAt = Date(timeIntervalSince1970: 10_000)

        store.configureCloudKitSync(
            containerIdentifier: "iCloud.com.example.PasteBuddy",
            keyHierarchyVersion: 1,
            capabilityConfigured: true
        )
        store.setSharedPinboardsEnabled(true)

        let keyExchange = try XCTUnwrap(store.sharePinboardWithKeyExchange(
            pinboardID,
            ownerIdentity: ownerIdentity,
            ownerDisplayName: "Owner Mac",
            keyExchangeService: keyExchangeService
        ))
        let ownerBoardKey = try keyExchangeService.unwrapOwnerBoardKey(
            from: keyExchange,
            ownerIdentity: ownerIdentity
        )
        let participant = try XCTUnwrap(store.inviteParticipantWithKeyExchange(
            to: pinboardID,
            displayName: "Collaborator",
            participantPublicKeyData: participantIdentity.publicKeyData,
            ownerIdentity: ownerIdentity,
            emailAddress: "collaborator@example.com",
            permission: .canEdit,
            keyExchangeService: keyExchangeService
        ))

        XCTAssertEqual(ownerBoardKey.count, PinboardShareKeyExchangeService.boardKeyByteCount)
        XCTAssertEqual(participant.keyAgreementPublicKeyData, participantIdentity.publicKeyData)
        XCTAssertEqual(participant.boardKeyFingerprint, keyExchange.boardKeyFingerprint)
        XCTAssertNotNil(participant.wrappedBoardKey)
        XCTAssertNil(participant.acceptedAt)
        XCTAssertNotEqual(participant.wrappedBoardKey?.sealedBoardKeyData, ownerBoardKey)

        let participantBoardKey = try XCTUnwrap(store.acceptParticipantKeyExchange(
            pinboardID: pinboardID,
            participantID: participant.id,
            participantIdentity: participantIdentity,
            acceptedAt: acceptedAt,
            keyExchangeService: keyExchangeService
        ))

        XCTAssertEqual(participantBoardKey, ownerBoardKey)
        XCTAssertEqual(store.snapshot.pinboards[0].sharing?.participants.first?.acceptedAt, acceptedAt)
        XCTAssertNil(store.lastErrorMessage)

        let raw = try Data(contentsOf: harness.snapshotStore.fileURL)
        let rawString = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(rawString.contains(ownerBoardKey.base64EncodedString()))
        XCTAssertFalse(rawString.contains(participantIdentity.privateKeyData.base64EncodedString()))

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()
        let reloadedParticipant = try XCTUnwrap(reloaded.snapshot.pinboards[0].sharing?.participants.first)
        XCTAssertNotNil(reloaded.snapshot.pinboards[0].sharing?.keyExchange)
        XCTAssertNotNil(reloadedParticipant.wrappedBoardKey)
        XCTAssertEqual(reloadedParticipant.acceptedAt, acceptedAt)
    }

    func testSharedPinboardKeyExchangeRejectsWrongParticipantIdentity() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let pinboardID = store.snapshot.pinboards[0].id
        let keyExchangeService = PinboardShareKeyExchangeService()
        let ownerIdentity = keyExchangeService.makeIdentity()
        let participantIdentity = keyExchangeService.makeIdentity()
        let wrongIdentity = keyExchangeService.makeIdentity()

        store.configureCloudKitSync(
            containerIdentifier: "iCloud.com.example.PasteBuddy",
            keyHierarchyVersion: 1,
            capabilityConfigured: true
        )
        store.setSharedPinboardsEnabled(true)
        _ = try XCTUnwrap(store.sharePinboardWithKeyExchange(
            pinboardID,
            ownerIdentity: ownerIdentity,
            keyExchangeService: keyExchangeService
        ))
        let participant = try XCTUnwrap(store.inviteParticipantWithKeyExchange(
            to: pinboardID,
            displayName: "Collaborator",
            participantPublicKeyData: participantIdentity.publicKeyData,
            ownerIdentity: ownerIdentity,
            keyExchangeService: keyExchangeService
        ))

        let boardKey = store.acceptParticipantKeyExchange(
            pinboardID: pinboardID,
            participantID: participant.id,
            participantIdentity: wrongIdentity,
            keyExchangeService: keyExchangeService
        )

        XCTAssertNil(boardKey)
        XCTAssertEqual(store.lastErrorMessage, PinboardShareKeyExchangeError.recipientMismatch.localizedDescription)
        XCTAssertNil(store.snapshot.pinboards[0].sharing?.participants.first?.acceptedAt)
    }

    func testSharedPinboardInvitationPackageWrapsBoardKeyForRecipientOnly() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let pinboardID = store.snapshot.pinboards[0].id
        let secretPinboardName = "Confidential launch board \(UUID().uuidString)"
        let keyExchangeService = PinboardShareKeyExchangeService()
        let invitationService = PinboardShareInvitationService(keyExchangeService: keyExchangeService)
        let ownerIdentity = keyExchangeService.makeIdentity()
        let participantIdentity = keyExchangeService.makeIdentity()
        let createdAt = Date(timeIntervalSince1970: 20_000)
        let acceptedAt = Date(timeIntervalSince1970: 20_100)

        store.renamePinboard(pinboardID, to: secretPinboardName)
        store.configureCloudKitSync(
            containerIdentifier: "iCloud.com.example.PasteBuddy",
            keyHierarchyVersion: 1,
            capabilityConfigured: true
        )
        store.setSharedPinboardsEnabled(true)

        let keyExchange = try XCTUnwrap(store.sharePinboardWithKeyExchange(
            pinboardID,
            ownerIdentity: ownerIdentity,
            ownerDisplayName: "Owner Mac",
            keyExchangeService: keyExchangeService
        ))
        let ownerBoardKey = try keyExchangeService.unwrapOwnerBoardKey(
            from: keyExchange,
            ownerIdentity: ownerIdentity
        )
        let participant = try XCTUnwrap(store.inviteParticipantWithKeyExchange(
            to: pinboardID,
            displayName: "Collaborator",
            participantPublicKeyData: participantIdentity.publicKeyData,
            ownerIdentity: ownerIdentity,
            permission: .canEdit,
            keyExchangeService: keyExchangeService
        ))

        let package = try XCTUnwrap(store.makePinboardInvitationPackage(
            pinboardID: pinboardID,
            participantID: participant.id,
            ownerIdentity: ownerIdentity,
            ownerDisplayName: "Owner Mac",
            createdAt: createdAt,
            expiresAt: Date(timeIntervalSince1970: 30_000),
            invitationService: invitationService
        ))

        XCTAssertEqual(package.pinboardID, pinboardID)
        XCTAssertEqual(package.participantID, participant.id)
        XCTAssertEqual(package.permission, .canEdit)
        XCTAssertEqual(package.ownerIdentity.displayName, "Owner Mac")
        XCTAssertEqual(package.recipientIdentity.publicKeyData, participantIdentity.publicKeyData)
        XCTAssertEqual(package.boardKeyFingerprint, keyExchange.boardKeyFingerprint)
        XCTAssertNotEqual(package.wrappedBoardKey.sealedBoardKeyData, ownerBoardKey)

        let packageBoardKey = try invitationService.acceptInvitation(
            package,
            recipientIdentity: participantIdentity,
            now: acceptedAt
        )
        XCTAssertEqual(packageBoardKey, ownerBoardKey)

        let acceptedBoardKey = try XCTUnwrap(store.acceptPinboardInvitationPackage(
            package,
            recipientIdentity: participantIdentity,
            acceptedAt: acceptedAt,
            invitationService: invitationService
        ))
        XCTAssertEqual(acceptedBoardKey, ownerBoardKey)
        XCTAssertEqual(store.snapshot.pinboards[0].sharing?.participants.first?.acceptedAt, acceptedAt)
        XCTAssertNil(store.lastErrorMessage)

        let encodedPackage = try JSONEncoder.pasteBuddy.encode(package)
        let encodedPackageString = String(decoding: encodedPackage, as: UTF8.self)
        XCTAssertFalse(encodedPackageString.contains(ownerBoardKey.base64EncodedString()))
        XCTAssertFalse(encodedPackageString.contains(ownerIdentity.privateKeyData.base64EncodedString()))
        XCTAssertFalse(encodedPackageString.contains(participantIdentity.privateKeyData.base64EncodedString()))
        XCTAssertFalse(encodedPackageString.contains(secretPinboardName))
    }

    func testSharedPinboardInvitationPackageRejectsExpiredOrWrongRecipient() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let pinboardID = store.snapshot.pinboards[0].id
        let keyExchangeService = PinboardShareKeyExchangeService()
        let invitationService = PinboardShareInvitationService(keyExchangeService: keyExchangeService)
        let ownerIdentity = keyExchangeService.makeIdentity()
        let participantIdentity = keyExchangeService.makeIdentity()
        let wrongIdentity = keyExchangeService.makeIdentity()

        store.configureCloudKitSync(
            containerIdentifier: "iCloud.com.example.PasteBuddy",
            keyHierarchyVersion: 1,
            capabilityConfigured: true
        )
        store.setSharedPinboardsEnabled(true)
        _ = try XCTUnwrap(store.sharePinboardWithKeyExchange(
            pinboardID,
            ownerIdentity: ownerIdentity,
            keyExchangeService: keyExchangeService
        ))
        let participant = try XCTUnwrap(store.inviteParticipantWithKeyExchange(
            to: pinboardID,
            displayName: "Collaborator",
            participantPublicKeyData: participantIdentity.publicKeyData,
            ownerIdentity: ownerIdentity,
            keyExchangeService: keyExchangeService
        ))
        let package = try XCTUnwrap(store.makePinboardInvitationPackage(
            pinboardID: pinboardID,
            participantID: participant.id,
            ownerIdentity: ownerIdentity,
            createdAt: Date(timeIntervalSince1970: 10),
            expiresAt: Date(timeIntervalSince1970: 100),
            invitationService: invitationService
        ))

        let expiredBoardKey = store.acceptPinboardInvitationPackage(
            package,
            recipientIdentity: participantIdentity,
            acceptedAt: Date(timeIntervalSince1970: 101),
            invitationService: invitationService
        )
        XCTAssertNil(expiredBoardKey)
        XCTAssertEqual(store.lastErrorMessage, PinboardShareInvitationError.expiredInvitation.localizedDescription)
        XCTAssertNil(store.snapshot.pinboards[0].sharing?.participants.first?.acceptedAt)

        let wrongRecipientBoardKey = store.acceptPinboardInvitationPackage(
            package,
            recipientIdentity: wrongIdentity,
            acceptedAt: Date(timeIntervalSince1970: 50),
            invitationService: invitationService
        )
        XCTAssertNil(wrongRecipientBoardKey)
        XCTAssertEqual(store.lastErrorMessage, PinboardShareInvitationError.recipientMismatch.localizedDescription)
        XCTAssertNil(store.snapshot.pinboards[0].sharing?.participants.first?.acceptedAt)
    }

    func testSharedPinboardInvitationDeliveryFetchesOnlyRecipientPackages() async throws {
        let keyExchangeService = PinboardShareKeyExchangeService()
        let invitationService = PinboardShareInvitationService(keyExchangeService: keyExchangeService)
        let deliveryService = PinboardShareInvitationDeliveryService(
            transport: InMemoryPinboardShareInvitationTransport()
        )
        let ownerIdentity = keyExchangeService.makeIdentity()
        let participantIdentity = keyExchangeService.makeIdentity()
        let otherIdentity = keyExchangeService.makeIdentity()
        let recipientIdentity = try invitationService.publicIdentity(
            displayName: "Collaborator",
            identity: participantIdentity,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let otherRecipientIdentity = try invitationService.publicIdentity(
            displayName: "Other Mac",
            identity: otherIdentity,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let keyExchange = try keyExchangeService.setupOwnerKeyExchange(
            ownerIdentity: ownerIdentity
        ).state
        let package = try invitationService.makeInvitationPackage(
            pinboardID: UUID(),
            participantID: UUID(),
            permission: .canEdit,
            ownerIdentity: ownerIdentity,
            ownerDisplayName: "Owner Mac",
            recipientIdentity: recipientIdentity,
            keyExchange: keyExchange,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let otherPackage = try invitationService.makeInvitationPackage(
            pinboardID: UUID(),
            participantID: UUID(),
            permission: .readOnly,
            ownerIdentity: ownerIdentity,
            ownerDisplayName: "Owner Mac",
            recipientIdentity: otherRecipientIdentity,
            keyExchange: keyExchange,
            createdAt: Date(timeIntervalSince1970: 3)
        )

        let publishedIdentity = try await deliveryService.publishIdentity(recipientIdentity)
        _ = try await deliveryService.sendInvitation(package)
        _ = try await deliveryService.sendInvitation(otherPackage)

        let fetchedPackages = try await deliveryService.fetchInvitations(for: publishedIdentity)
        let otherFetchedPackages = try await deliveryService.fetchInvitations(for: otherRecipientIdentity)

        XCTAssertEqual(fetchedPackages.map(\.id), [package.id])
        XCTAssertEqual(otherFetchedPackages.map(\.id), [otherPackage.id])
    }

    func testSharedPinboardInvitationInboxRefreshStoresRecipientPackagesEncrypted() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let keyExchangeService = PinboardShareKeyExchangeService()
        let invitationService = PinboardShareInvitationService(keyExchangeService: keyExchangeService)
        let transport = InMemoryPinboardShareInvitationTransport()
        let deliveryService = PinboardShareInvitationDeliveryService(transport: transport)
        let inboxRefreshService = PinboardShareInvitationInboxRefreshService(
            deliveryService: deliveryService,
            invitationService: invitationService
        )
        let ownerIdentity = keyExchangeService.makeIdentity()
        let participantIdentity = keyExchangeService.makeIdentity()
        let otherIdentity = keyExchangeService.makeIdentity()
        let secretPinboardName = "Remote confidential board \(UUID().uuidString)"
        let keyExchangeSetup = try keyExchangeService.setupOwnerKeyExchange(
            ownerIdentity: ownerIdentity
        )
        let recipientIdentity = try invitationService.publicIdentity(
            displayName: "Collaborator",
            identity: participantIdentity,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let otherRecipientIdentity = try invitationService.publicIdentity(
            displayName: "Other",
            identity: otherIdentity,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let package = try invitationService.makeInvitationPackage(
            pinboardID: UUID(),
            participantID: UUID(),
            permission: .canEdit,
            ownerIdentity: ownerIdentity,
            ownerDisplayName: "Owner Mac",
            recipientIdentity: recipientIdentity,
            keyExchange: keyExchangeSetup.state,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let otherPackage = try invitationService.makeInvitationPackage(
            pinboardID: UUID(),
            participantID: UUID(),
            permission: .readOnly,
            ownerIdentity: ownerIdentity,
            ownerDisplayName: "Owner Mac",
            recipientIdentity: otherRecipientIdentity,
            keyExchange: keyExchangeSetup.state,
            createdAt: Date(timeIntervalSince1970: 3)
        )

        store.configureCloudKitSync(
            containerIdentifier: "iCloud.com.example.PasteBuddy",
            keyHierarchyVersion: 1,
            capabilityConfigured: true
        )
        store.setSharedPinboardsEnabled(true)
        _ = try await deliveryService.sendInvitation(package)
        _ = try await deliveryService.sendInvitation(otherPackage)

        let result = try await inboxRefreshService.refreshPendingInvitations(
            for: participantIdentity,
            displayName: "Collaborator",
            into: store,
            receivedAt: Date(timeIntervalSince1970: 4)
        )

        XCTAssertEqual(result.fetchedPackageCount, 1)
        XCTAssertEqual(result.savedEntries.map(\.id), [package.id])
        XCTAssertEqual(store.snapshot.pinboardInvitationInbox.pendingEntries.map(\.id), [package.id])
        XCTAssertEqual(store.snapshot.pinboardInvitationInbox.entries.first?.status, .pending)
        XCTAssertNil(store.lastErrorMessage)

        let raw = try Data(contentsOf: harness.snapshotStore.fileURL)
        let rawString = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(rawString.contains(keyExchangeSetup.boardKey.base64EncodedString()))
        XCTAssertFalse(rawString.contains(ownerIdentity.privateKeyData.base64EncodedString()))
        XCTAssertFalse(rawString.contains(participantIdentity.privateKeyData.base64EncodedString()))
        XCTAssertFalse(rawString.contains(secretPinboardName))

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()
        XCTAssertEqual(reloaded.snapshot.pinboardInvitationInbox.entries.map(\.id), [package.id])
        XCTAssertEqual(reloaded.snapshot.pinboardInvitationInbox.entries.first?.status, .pending)
    }

    func testAcceptPendingPinboardInvitationUpdatesInboxStatus() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let keyExchangeService = PinboardShareKeyExchangeService()
        let invitationService = PinboardShareInvitationService(keyExchangeService: keyExchangeService)
        let ownerIdentity = keyExchangeService.makeIdentity()
        let participantIdentity = keyExchangeService.makeIdentity()
        let keyExchangeSetup = try keyExchangeService.setupOwnerKeyExchange(
            ownerIdentity: ownerIdentity
        )
        let recipientIdentity = try invitationService.publicIdentity(
            displayName: "Collaborator",
            identity: participantIdentity,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let acceptedPackage = try invitationService.makeInvitationPackage(
            pinboardID: UUID(),
            participantID: UUID(),
            permission: .canEdit,
            ownerIdentity: ownerIdentity,
            ownerDisplayName: "Owner Mac",
            recipientIdentity: recipientIdentity,
            keyExchange: keyExchangeSetup.state,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let expiredPackage = try invitationService.makeInvitationPackage(
            pinboardID: UUID(),
            participantID: UUID(),
            permission: .readOnly,
            ownerIdentity: ownerIdentity,
            ownerDisplayName: "Owner Mac",
            recipientIdentity: recipientIdentity,
            keyExchange: keyExchangeSetup.state,
            createdAt: Date(timeIntervalSince1970: 3),
            expiresAt: Date(timeIntervalSince1970: 5)
        )

        store.configureCloudKitSync(
            containerIdentifier: "iCloud.com.example.PasteBuddy",
            keyHierarchyVersion: 1,
            capabilityConfigured: true
        )
        store.setSharedPinboardsEnabled(true)
        store.savePendingPinboardInvitationPackages(
            [acceptedPackage, expiredPackage],
            receivedAt: Date(timeIntervalSince1970: 4)
        )

        let acceptedBoardKey = try XCTUnwrap(store.acceptPendingPinboardInvitation(
            invitationID: acceptedPackage.id,
            recipientIdentity: participantIdentity,
            acceptedAt: Date(timeIntervalSince1970: 6),
            invitationService: invitationService
        ))
        XCTAssertEqual(acceptedBoardKey, keyExchangeSetup.boardKey)
        XCTAssertEqual(
            store.snapshot.pinboardInvitationInbox.entries.first(where: { $0.id == acceptedPackage.id })?.status,
            .accepted
        )

        let expiredBoardKey = store.acceptPendingPinboardInvitation(
            invitationID: expiredPackage.id,
            recipientIdentity: participantIdentity,
            acceptedAt: Date(timeIntervalSince1970: 6),
            invitationService: invitationService
        )
        let expiredEntry = try XCTUnwrap(
            store.snapshot.pinboardInvitationInbox.entries.first(where: { $0.id == expiredPackage.id })
        )

        XCTAssertNil(expiredBoardKey)
        XCTAssertEqual(expiredEntry.status, .expired)
        XCTAssertEqual(expiredEntry.lastErrorMessage, PinboardShareInvitationError.expiredInvitation.localizedDescription)
    }

    #if canImport(CloudKit)
    func testCloudKitPinboardShareInvitationRecordsExposeOnlyRoutingMetadataAndWrappedPackage() throws {
        let keyExchangeService = PinboardShareKeyExchangeService()
        let invitationService = PinboardShareInvitationService(keyExchangeService: keyExchangeService)
        let factory = CloudKitPinboardShareRecordFactory()
        let ownerIdentity = keyExchangeService.makeIdentity()
        let participantIdentity = keyExchangeService.makeIdentity()
        let secretPinboardName = "Board name must not be in invitation record"
        let keyExchangeSetup = try keyExchangeService.setupOwnerKeyExchange(
            ownerIdentity: ownerIdentity
        )
        let recipientIdentity = try invitationService.publicIdentity(
            displayName: "Collaborator",
            identity: participantIdentity,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let package = try invitationService.makeInvitationPackage(
            pinboardID: UUID(),
            participantID: UUID(),
            permission: .canEdit,
            ownerIdentity: ownerIdentity,
            ownerDisplayName: "Owner Mac",
            recipientIdentity: recipientIdentity,
            keyExchange: keyExchangeSetup.state,
            createdAt: Date(timeIntervalSince1970: 200),
            expiresAt: Date(timeIntervalSince1970: 300)
        )

        let identityRecord = try factory.makeIdentityRecord(from: recipientIdentity)
        XCTAssertEqual(identityRecord.recordType, CloudKitPinboardShareRecordFactory.publicIdentityRecordType)
        XCTAssertEqual(identityRecord.recordID.recordName, recipientIdentity.publicKeyFingerprint)
        XCTAssertEqual(
            identityRecord[CloudKitPinboardShareRecordFactory.publicKeyFingerprintField] as? String,
            recipientIdentity.publicKeyFingerprint
        )
        XCTAssertEqual(try factory.makePublicIdentity(from: identityRecord), recipientIdentity)

        let invitationRecord = try factory.makeInvitationRecord(from: package)
        XCTAssertEqual(invitationRecord.recordType, CloudKitPinboardShareRecordFactory.invitationRecordType)
        XCTAssertEqual(invitationRecord.recordID.recordName, package.id.uuidString)
        XCTAssertEqual(
            invitationRecord[CloudKitPinboardShareRecordFactory.recipientPublicKeyFingerprintField] as? String,
            recipientIdentity.publicKeyFingerprint
        )
        XCTAssertEqual(
            invitationRecord[CloudKitPinboardShareRecordFactory.permissionField] as? String,
            PinboardSharePermission.canEdit.rawValue
        )

        let packageData = try XCTUnwrap(
            invitationRecord[CloudKitPinboardShareRecordFactory.invitationPackageDataField] as? Data
        )
        let packageString = String(decoding: packageData, as: UTF8.self)
        XCTAssertFalse(packageString.contains(keyExchangeSetup.boardKey.base64EncodedString()))
        XCTAssertFalse(packageString.contains(ownerIdentity.privateKeyData.base64EncodedString()))
        XCTAssertFalse(packageString.contains(participantIdentity.privateKeyData.base64EncodedString()))
        XCTAssertFalse(packageString.contains(secretPinboardName))
        XCTAssertEqual(try factory.makeInvitationPackage(from: invitationRecord), package)
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

    func testCloudKitPinboardShareInvitationNotificationHandlerRefreshesMatchingSubscriptionOnly() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let keyExchangeService = PinboardShareKeyExchangeService()
        let invitationService = PinboardShareInvitationService(keyExchangeService: keyExchangeService)
        let transport = InMemoryPinboardShareInvitationTransport()
        let deliveryService = PinboardShareInvitationDeliveryService(transport: transport)
        let handler = CloudKitPinboardShareInvitationNotificationHandler(
            deliveryService: deliveryService,
            invitationService: invitationService
        )
        let factory = CloudKitPinboardShareRecordFactory()
        let ownerIdentity = keyExchangeService.makeIdentity()
        let participantIdentity = keyExchangeService.makeIdentity()
        let otherIdentity = keyExchangeService.makeIdentity()
        let keyExchange = try keyExchangeService.setupOwnerKeyExchange(
            ownerIdentity: ownerIdentity
        ).state
        let recipientIdentity = try invitationService.publicIdentity(
            displayName: "Collaborator",
            identity: participantIdentity,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let otherRecipientIdentity = try invitationService.publicIdentity(
            displayName: "Other",
            identity: otherIdentity,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let package = try invitationService.makeInvitationPackage(
            pinboardID: UUID(),
            participantID: UUID(),
            permission: .canEdit,
            ownerIdentity: ownerIdentity,
            ownerDisplayName: "Owner Mac",
            recipientIdentity: recipientIdentity,
            keyExchange: keyExchange,
            createdAt: Date(timeIntervalSince1970: 2)
        )

        store.configureCloudKitSync(
            containerIdentifier: "iCloud.com.example.PasteBuddy",
            keyHierarchyVersion: 1,
            capabilityConfigured: true
        )
        store.setSharedPinboardsEnabled(true)
        _ = try await deliveryService.sendInvitation(package)

        let ignoredResult = try await handler.handleInvitationSubscription(
            subscriptionID: try factory.makeInvitationSubscriptionID(
                recipientPublicKeyFingerprint: otherRecipientIdentity.publicKeyFingerprint
            ),
            recipientIdentity: participantIdentity,
            displayName: "Collaborator",
            store: store,
            receivedAt: Date(timeIntervalSince1970: 3)
        )
        XCTAssertNil(ignoredResult)
        XCTAssertTrue(store.snapshot.pinboardInvitationInbox.entries.isEmpty)

        let result = try await handler.handleInvitationSubscription(
            subscriptionID: try factory.makeInvitationSubscriptionID(
                recipientPublicKeyFingerprint: recipientIdentity.publicKeyFingerprint
            ),
            recipientIdentity: participantIdentity,
            displayName: "Collaborator",
            store: store,
            receivedAt: Date(timeIntervalSince1970: 4)
        )

        XCTAssertEqual(result?.fetchedPackageCount, 1)
        XCTAssertEqual(result?.savedEntries.map(\.id), [package.id])
        XCTAssertEqual(store.snapshot.pinboardInvitationInbox.pendingEntries.map(\.id), [package.id])
    }

    func testCloudKitPinboardShareInvitationNotificationRouteRejectsMalformedSubscriptionID() throws {
        let factory = CloudKitPinboardShareRecordFactory()

        XCTAssertThrowsError(
            try factory.makeInvitationNotificationRoute(subscriptionID: "OtherSubscription.abc")
        )
        XCTAssertThrowsError(
            try factory.makeInvitationNotificationRoute(
                subscriptionID: CloudKitPinboardShareRecordFactory.invitationSubscriptionIDPrefix
            )
        )
    }
    #endif

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

    func testDebouncedSaveDefersDiskWriteUntilFlush() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            saveDebounceNanoseconds: 60_000_000_000
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.snapshotStore.fileURL.path))

        let first = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "First",
            payload: ClipboardPayload(text: "first pending save")
        ))
        let second = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Test Mac",
            contentType: .url,
            title: "Second",
            payload: ClipboardPayload(urlString: "https://example.com/pending")
        ))

        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.snapshotStore.fileURL.path))

        await store.flushPendingSave()

        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.snapshotStore.fileURL.path))

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertEqual(reloaded.snapshot.items.map(\.id), [second.id, first.id])
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

    func testSyncedItemRespectsLocalPrivacyPreferences() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.snapshot.privacy.captureText = false

        let stored = store.addSyncedItem(ClipboardItem(
            sourceAppName: "Peer iPhone",
            deviceName: "Peer iPhone",
            contentType: .text,
            title: "Password from phone",
            payload: ClipboardPayload(text: "hunter2-super-secret")
        ))

        XCTAssertNil(stored)
        XCTAssertTrue(
            store.snapshot.items.isEmpty,
            "A text item must not enter history while text capture is disabled"
        )
    }

    #if os(macOS)
    func testEnrichLinkPreviewMetadataNotifiesForwarderWithUpgradedItem() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let thumbnail = Data([0xAA, 0xBB, 0xCC, 0xDD])
        ClipboardLinkMetadataFetcher.fetchOverrideForTesting = { _ in
            ClipboardLinkPreviewMetadata(title: "Example Domain", imageData: thumbnail)
        }
        defer { ClipboardLinkMetadataFetcher.fetchOverrideForTesting = nil }

        var forwarded: [ClipboardItem] = []
        store.onLinkPreviewMetadataEnriched = { item in
            forwarded.append(item)
        }

        let bare = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Terminal",
            deviceName: "Test Mac",
            contentType: .url,
            title: "example.com",
            payload: ClipboardPayload(urlString: "https://example.com/launch")
        ))
        XCTAssertFalse(bare.payload.hasImageAsset)

        await store.enrichLinkPreviewMetadataIfNeeded(for: bare)

        let enriched = try XCTUnwrap(store.snapshot.items.first { $0.id == bare.id })
        XCTAssertEqual(enriched.title, "Example Domain")
        XCTAssertEqual(enriched.payload.imageData, thumbnail)
        XCTAssertEqual(forwarded.map(\.id), [bare.id])
        XCTAssertEqual(forwarded.first?.payload.imageData, thumbnail,
                       "Forwarded item must carry the thumbnail so peers can merge it")
    }

    func testEnrichLinkPreviewMetadataDoesNotForwardTitleOnlyUpgrade() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        ClipboardLinkMetadataFetcher.fetchOverrideForTesting = { _ in
            ClipboardLinkPreviewMetadata(title: "Only Title", imageData: nil)
        }
        defer { ClipboardLinkMetadataFetcher.fetchOverrideForTesting = nil }

        var forwardedCount = 0
        store.onLinkPreviewMetadataEnriched = { _ in
            forwardedCount += 1
        }

        let bare = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Terminal",
            deviceName: "Test Mac",
            contentType: .url,
            title: "example.com",
            payload: ClipboardPayload(urlString: "https://example.com/title-only")
        ))

        await store.enrichLinkPreviewMetadataIfNeeded(for: bare)

        let enriched = try XCTUnwrap(store.snapshot.items.first { $0.id == bare.id })
        XCTAssertEqual(enriched.title, "Only Title")
        XCTAssertEqual(forwardedCount, 0, "Title-only enrichment should stay local until peers can merge it safely")
    }
    #endif

    func testDedupeMergesRicherLinkPreviewFromPeerResend() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let bare = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Terminal",
            deviceName: "Test Mac",
            contentType: .url,
            title: "example.com",
            payload: ClipboardPayload(urlString: "https://example.com/launch")
        ))

        // A sync peer re-sends the same link once it fetched preview metadata;
        // the item arrives with its own UUID, so only dedupe can reconcile it.
        let thumbnail = Data([0x01, 0x02, 0x03])
        var enrichedPayload = ClipboardPayload(urlString: "https://example.com/launch")
        enrichedPayload.imageData = thumbnail
        enrichedPayload.imageByteCount = thumbnail.count
        let merged = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Terminal",
            deviceName: "Peer iPhone",
            contentType: .url,
            title: "Example Domain",
            payload: enrichedPayload
        ))

        XCTAssertEqual(store.snapshot.items.count, 1)
        XCTAssertEqual(merged.id, bare.id, "Richer duplicate must merge into the existing item")
        XCTAssertEqual(merged.title, "Example Domain")
        XCTAssertEqual(merged.payload.imageData, thumbnail)
    }

    func testDedupeKeepsExistingThumbnailWhenBareDuplicateArrives() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let thumbnail = Data([0x0A, 0x0B])
        var enrichedPayload = ClipboardPayload(urlString: "https://example.com/launch")
        enrichedPayload.imageData = thumbnail
        enrichedPayload.imageByteCount = thumbnail.count
        let enriched = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Test Mac",
            contentType: .url,
            title: "Example Domain",
            payload: enrichedPayload
        ))

        let bumped = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Terminal",
            deviceName: "Test Mac",
            contentType: .url,
            title: "example.com",
            payload: ClipboardPayload(urlString: "https://example.com/launch")
        ))

        XCTAssertEqual(store.snapshot.items.count, 1)
        XCTAssertEqual(bumped.id, enriched.id)
        XCTAssertEqual(bumped.payload.imageData, thumbnail, "A barer re-copy must never clear existing metadata")
        XCTAssertEqual(bumped.title, "Example Domain")
    }

    func testSyncedMetadataReplayMergesWithoutBubblingItemToTop() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let now = Date()
        let older = store.addCapturedItem(ClipboardItem(
            createdAt: now.addingTimeInterval(-120),
            updatedAt: now.addingTimeInterval(-120),
            sourceAppName: "Safari",
            deviceName: "Test Mac",
            contentType: .url,
            title: "example.com",
            payload: ClipboardPayload(urlString: "https://example.com/launch")
        ))
        let newer = store.addCapturedItem(ClipboardItem(
            createdAt: now.addingTimeInterval(-60),
            updatedAt: now.addingTimeInterval(-60),
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Fresh note",
            payload: ClipboardPayload(text: "fresh note")
        ))

        var replayPayload = ClipboardPayload(urlString: "https://example.com/launch")
        replayPayload.imageData = Data([0x0F, 0x0E])
        replayPayload.imageByteCount = 2
        let merged = store.addSyncedItem(ClipboardItem(
            id: UUID(),
            createdAt: older.createdAt,
            updatedAt: older.updatedAt,
            sourceAppName: "Peer iPhone",
            deviceName: "Peer iPhone",
            contentType: .url,
            title: "Example Domain",
            payload: replayPayload
        ))

        XCTAssertEqual(merged?.id, older.id)
        XCTAssertEqual(store.snapshot.items.map(\.id), [newer.id, older.id])
        XCTAssertEqual(store.snapshot.items.last?.payload.imageData, replayPayload.imageData)
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

    func testFlushPersistsExternalizedAssetsToDiskWhenRepositoryEnabled() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let repository = ClipboardItemRepository(database: database)
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository,
            saveDebounceNanoseconds: 60_000_000_000
        )

        let imageBytes = Data((0 ..< 4_096).map { UInt8($0 % 251) })
        store.addCapturedItem(ClipboardItem(
            sourceAppName: "Screenshot",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Big Screenshot",
            payload: ClipboardPayload(imageData: imageBytes)
        ))

        await store.flushPendingSave()

        let persisted = try harness.snapshotStore.load()
        let persistedPayload = try XCTUnwrap(persisted.items.first?.payload)
        XCTAssertNil(persistedPayload.imageData, "Disk snapshot must externalize image bytes into the repository")
        XCTAssertNotNil(persistedPayload.imageAssetID)
        XCTAssertEqual(persistedPayload.imageByteCount, imageBytes.count)

        // The in-memory item keeps its bytes so the UI never re-hydrates for recents.
        XCTAssertEqual(store.snapshot.items.first?.payload.imageData, imageBytes)
    }

    func testExternalizedAssetHashingAcceptsDataSlicesWithNonzeroStartIndex() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let repository = ClipboardItemRepository(
            database: try PasteBuddyDatabase(
                fileURL: harness.directory.appendingPathComponent("sliced-asset.sqlite")
            )
        )
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository,
            saveDebounceNanoseconds: 60_000_000_000
        )
        let rawBytes = Data([0x00, 0x01, 0x89, 0x50, 0x4E, 0x47])
        let slicedBytes: Data = rawBytes[2...]
        XCTAssertNotEqual(slicedBytes.startIndex, 0)
        store.addCapturedItem(ClipboardItem(
            sourceAppName: "Screenshot",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Sliced image bytes",
            payload: ClipboardPayload(imageData: slicedBytes)
        ))

        let didFlush = await store.flushPendingSave()
        XCTAssertTrue(didFlush)

        let persistedPayload = try XCTUnwrap(harness.snapshotStore.load().items.first?.payload)
        XCTAssertNil(persistedPayload.imageData)
        XCTAssertNotNil(persistedPayload.imageAssetID)
        XCTAssertEqual(persistedPayload.imageByteCount, slicedBytes.count)
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

    func testStorageUsageReportUsesPrecomputedBytesAndInvalidatesAfterMutation() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        var item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Cached Bytes",
            payload: ClipboardPayload(text: String(repeating: "large ", count: 200))
        )
        item.searchDocument.storageBytes = 1_234
        store.snapshot = PasteBuddySnapshot(items: [item])

        let cachedReport = store.storageUsageReport
        let repeatedReport = store.storageUsageReport

        XCTAssertEqual(cachedReport, repeatedReport)
        XCTAssertEqual(cachedReport.estimatedBytes, 1_234)

        store.updateTextItem(item.id, to: String(repeating: "updated ", count: 400))

        let updatedItem = try XCTUnwrap(store.snapshot.items.first { $0.id == item.id })
        let updatedReport = store.storageUsageReport
        XCTAssertEqual(updatedReport.estimatedBytes, updatedItem.searchDocument.storageBytes)
        XCTAssertGreaterThan(updatedReport.estimatedBytes, cachedReport.estimatedBytes)
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

    func testGRDBRepositoryStoresImageAndRTFAssetsOutsidePayloadJSONAndKeepsPagesLightweight() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let imageData = Data(repeating: 0x7A, count: 16_384)
        let rtfData = Data("{\\rtf1\\ansi VIP launch reply}".utf8)
        let item = ClipboardItem(
            sourceAppName: "Pages",
            deviceName: "Test Mac",
            contentType: .mixed,
            title: "Launch Asset",
            payload: ClipboardPayload(
                text: "Launch copy",
                htmlString: "<p>Launch copy</p>",
                rtfData: rtfData,
                imageData: imageData,
                ocrText: "Hero screenshot OCR"
            ),
            ocrState: .completed(Date(timeIntervalSince1970: 100))
        )
        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let repository = ClipboardItemRepository(database: database)

        try repository.replaceAll(with: PasteBuddySnapshot(items: [item]))

        let payloadJSON = try database.payloadJSONForTesting(itemID: item.id)
        XCTAssertFalse(payloadJSON.contains("imageData"))
        XCTAssertFalse(payloadJSON.contains("rtfData"))
        XCTAssertFalse(payloadJSON.contains(imageData.base64EncodedString()))
        XCTAssertFalse(payloadJSON.contains(rtfData.base64EncodedString()))

        let assetRows = try database.assetRowsForTesting()
        XCTAssertEqual(Set(assetRows.map(\.kind)), Set(["image", "rtf"]))
        XCTAssertEqual(Set(assetRows.map(\.byteCount)), Set([imageData.count, rtfData.count]))
        XCTAssertTrue(assetRows.contains { $0.data == imageData })
        XCTAssertTrue(assetRows.contains { $0.data == rtfData })

        let pageItem = try XCTUnwrap(repository.fetchPage().first)
        XCTAssertNil(pageItem.payload.imageData)
        XCTAssertNil(pageItem.payload.rtfData)
        XCTAssertNotNil(pageItem.payload.imageAssetID)
        XCTAssertNotNil(pageItem.payload.rtfAssetID)
        XCTAssertEqual(pageItem.payload.imageByteCount, imageData.count)
        XCTAssertEqual(pageItem.payload.rtfByteCount, rtfData.count)
        XCTAssertTrue(pageItem.matches("hero screenshot"))

        let exportedItem = try XCTUnwrap(repository.exportSnapshot().items.first)
        XCTAssertEqual(exportedItem.payload.imageData, imageData)
        XCTAssertEqual(exportedItem.payload.rtfData, rtfData)
        XCTAssertTrue(exportedItem.matches("hero screenshot"))
    }

    func testStoreHydratesRepositoryBackedLightweightAssetsForPreviewAndPaste() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        harness.snapshotStore.storageMode = .standard

        let imageData = Data(repeating: 0x32, count: 8_192)
        let rtfData = Data("{\\rtf1 asset backed copy}".utf8)
        let item = ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .mixed,
            title: "Asset Backed",
            payload: ClipboardPayload(
                text: "Asset backed body",
                rtfData: rtfData,
                imageData: imageData,
                ocrText: "Asset OCR"
            ),
            ocrState: .completed(Date(timeIntervalSince1970: 200))
        )
        let snapshot = PasteBuddySnapshot(items: [item])
        try harness.snapshotStore.save(snapshot)

        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let repository = ClipboardItemRepository(database: database)
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository
        )
        store.load()

        let lightweightItem = try XCTUnwrap(store.filteredItems.first)
        XCTAssertNil(lightweightItem.payload.imageData)
        XCTAssertNil(lightweightItem.payload.rtfData)
        XCTAssertNotNil(lightweightItem.payload.imageAssetID)
        XCTAssertNotNil(lightweightItem.payload.rtfAssetID)

        let baselineIndexBuildCount = store.itemByIDIndexBuildCountForTesting
        let hydratedImageData = await store.imageData(for: lightweightItem)
        XCTAssertEqual(hydratedImageData, imageData)

        let hydratedItem = await store.hydratedItem(for: lightweightItem)
        XCTAssertEqual(hydratedItem.payload.imageData, imageData)
        XCTAssertEqual(hydratedItem.payload.rtfData, rtfData)
        XCTAssertTrue(hydratedItem.matches("asset ocr"))
        XCTAssertEqual(
            store.itemByIDIndexBuildCountForTesting,
            baselineIndexBuildCount + 1,
            "Repeated asset hydration must reuse one revision-scoped item index instead of scanning history."
        )
    }

    func testRepositoryBackedStoreWritesAssetReferencesToDiskSnapshotAndHydratesOnDemandAfterReload() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let imageData = Data(repeating: 0x51, count: 12_288)
        let rtfData = Data("{\\rtf1 disk stripped asset}".utf8)
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
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .mixed,
            title: "Disk Asset",
            payload: ClipboardPayload(
                text: "Disk asset body",
                rtfData: rtfData,
                imageData: imageData,
                ocrText: "Disk OCR"
            ),
            ocrState: .completed(Date(timeIntervalSince1970: 300))
        ))

        let persistedData = try Data(contentsOf: standardSnapshotStore.fileURL)
        let persistedString = String(decoding: persistedData, as: UTF8.self)
        XCTAssertFalse(persistedString.contains("imageData"))
        XCTAssertFalse(persistedString.contains("rtfData"))
        XCTAssertFalse(persistedString.contains(imageData.base64EncodedString()))
        XCTAssertFalse(persistedString.contains(rtfData.base64EncodedString()))

        let diskSnapshot = try standardSnapshotStore.load()
        let diskItem = try XCTUnwrap(diskSnapshot.items.first)
        XCTAssertEqual(diskItem.id, captured.id)
        XCTAssertNil(diskItem.payload.imageData)
        XCTAssertNil(diskItem.payload.rtfData)
        XCTAssertNotNil(diskItem.payload.imageAssetID)
        XCTAssertNotNil(diskItem.payload.rtfAssetID)

        let reloaded = PasteBuddyStore(
            diskStore: standardSnapshotStore,
            clipboardRepository: repository
        )
        reloaded.load()

        let reloadedItem = try XCTUnwrap(reloaded.snapshot.items.first)
        XCTAssertNil(reloadedItem.payload.imageData)
        XCTAssertNil(reloadedItem.payload.rtfData)
        XCTAssertTrue(reloadedItem.matches("disk ocr"))
        let hydratedItem = await reloaded.hydratedItem(for: reloadedItem)
        XCTAssertEqual(hydratedItem.payload.imageData, imageData)
        XCTAssertEqual(hydratedItem.payload.rtfData, rtfData)
    }

    func testGRDBRepositoryMigratesLegacySnapshotInlineAssetsIntoAssetRows() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let imageData = Data(repeating: 0x44, count: 4_096)
        let rtfData = Data("{\\rtf1 legacy rich body}".utf8)
        let legacySnapshotJSON = Data("""
        {
          "items": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "createdAt": 100,
              "updatedAt": 100,
              "sourceAppName": "Preview",
              "deviceName": "Test Mac",
              "contentType": "mixed",
              "title": "Legacy Inline Asset",
              "payload": {
                "text": "Legacy searchable body",
                "rtfData": "\(rtfData.base64EncodedString())",
                "imageData": "\(imageData.base64EncodedString())",
                "ocrText": "Legacy OCR words"
              },
              "ocrState": {
                "completed": {
                  "_0": 100
                }
              }
            }
          ],
          "pinboards": []
        }
        """.utf8)
        let snapshot = try JSONDecoder.pasteBuddy.decode(PasteBuddySnapshot.self, from: legacySnapshotJSON)
        let legacyItem = try XCTUnwrap(snapshot.items.first)
        XCTAssertEqual(legacyItem.payload.imageData, imageData)
        XCTAssertEqual(legacyItem.payload.rtfData, rtfData)

        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let repository = ClipboardItemRepository(database: database)

        try repository.replaceAll(with: snapshot)

        let payloadJSON = try database.payloadJSONForTesting(itemID: legacyItem.id)
        XCTAssertFalse(payloadJSON.contains("imageData"))
        XCTAssertFalse(payloadJSON.contains("rtfData"))
        XCTAssertEqual(try database.assetRowsForTesting().count, 2)

        let exportedItem = try XCTUnwrap(repository.exportSnapshot().items.first)
        XCTAssertEqual(exportedItem.payload.imageData, imageData)
        XCTAssertEqual(exportedItem.payload.rtfData, rtfData)
        XCTAssertTrue(exportedItem.matches("legacy ocr"))
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

    func testSnapshotDatabaseMigratorBacksUpImportsAndValidatesSnapshot() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Migrated Note",
            labels: ["Migration"],
            payload: ClipboardPayload(text: "move this into sqlite")
        )
        let pinboard = Pinboard(
            name: "Migrated Board",
            colorHex: "#4EA7FC",
            itemIDs: [item.id]
        )
        var snapshot = PasteBuddySnapshot(items: [item], pinboards: [pinboard])
        snapshot.security.requiresBiometricUnlock = true
        try harness.snapshotStore.save(snapshot)

        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let repository = ClipboardItemRepository(database: database)
        let migrator = PasteBuddySnapshotDatabaseMigrator(
            snapshotStore: harness.snapshotStore,
            repository: repository
        )

        let report = try migrator.migrateFromSnapshot()

        XCTAssertEqual(report.itemCount, 1)
        XCTAssertEqual(report.pinboardCount, 1)
        let backupURL = try XCTUnwrap(report.backupURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        let exported = try repository.exportSnapshot()
        XCTAssertEqual(exported.items.map(\.id), [item.id])
        XCTAssertEqual(exported.pinboards.map(\.id), [pinboard.id])
        XCTAssertEqual(exported.pinboards.first?.itemIDs, [item.id])
        XCTAssertTrue(exported.security.requiresBiometricUnlock)
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

    func testReadOnlyRepositorySearchPagesWithoutMutatingGlobalUIState() throws {
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

        let page = try store.searchItems(query: "repository needle", offset: 120, limit: 5)

        XCTAssertEqual(page.map(\.id), Array(items[120..<125]).map(\.id))
        XCTAssertEqual(repository.fetchPageInvocationCount, fetchCount + 1)
        XCTAssertEqual(store.searchQuery, "leave this UI query alone")
        XCTAssertEqual(store.selectedScope, .pasteStack)
        XCTAssertEqual(store.queryRevision, queryRevision)

        let fallbackStore = PasteBuddyStore(diskStore: harness.snapshotStore)
        fallbackStore.snapshot = PasteBuddySnapshot(items: items)
        XCTAssertEqual(
            try fallbackStore.searchItems(query: "repository needle", offset: 120, limit: 5).map(\.id),
            page.map(\.id)
        )
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

        XCTAssertEqual(store.filteredItems.map(\.id), expectedIDs)
        XCTAssertEqual(store.mainListItemsSnapshot.map(\.id), expectedIDs)
        XCTAssertEqual(fallbackPage.items.map(\.id), expectedIDs)
        XCTAssertEqual(try store.searchItems(query: "canonical order", limit: 10).map(\.id), expectedIDs)
    }

    func testSyncedRepositoryCaptureBurstAvoidsFullSynchronizeAndPreservesCaptureSemantics() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        harness.snapshotStore.storageMode = .standard

        let database = try PasteBuddyDatabase(fileURL: harness.directory.appendingPathComponent("clipboard.sqlite"))
        let repository = ClipboardItemRepository(database: database)
        let now = Date(timeIntervalSince1970: 4_000_000)
        let recurring = ClipboardItem(
            createdAt: now,
            updatedAt: now,
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Recurring",
            payload: ClipboardPayload(text: "recurring clipboard value")
        )
        let stale = ClipboardItem(
            createdAt: now.addingTimeInterval(-10),
            updatedAt: now.addingTimeInterval(-10),
            sourceAppName: "TextEdit",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Stale",
            payload: ClipboardPayload(text: "stale clipboard value")
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
            itemIDs: [recurring.id, stale.id],
            createdAt: now,
            updatedAt: now
        )
        let userPinboard = Pinboard(
            name: "Keep",
            colorHex: "#4EA7FC",
            itemIDs: [pinned.id],
            createdAt: now,
            updatedAt: now
        )
        var seedSnapshot = PasteBuddySnapshot(
            items: [recurring, stale, pinned],
            pinboards: [smartText, userPinboard]
        )
        seedSnapshot.storage.maxHistoryItems = 2
        seedSnapshot.storage.retentionDays = 0
        try repository.replaceAll(with: seedSnapshot)

        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository,
            saveDebounceNanoseconds: 60_000_000_000
        )
        store.load()
        let baselineSynchronizeCount = repository.incrementalSyncInvocationCount

        let firstNew = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Terminal",
            deviceName: "Test Mac",
            contentType: .text,
            title: "First New",
            payload: ClipboardPayload(text: "first new clipboard value")
        ), maxItems: 2)
        _ = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Recurring Again",
            payload: ClipboardPayload(text: "recurring clipboard value")
        ), maxItems: 2)
        let finalNew = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Terminal",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Final New",
            payload: ClipboardPayload(text: "final new clipboard value")
        ), maxItems: 2)
        let retouched = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Recurring Last",
            payload: ClipboardPayload(text: "recurring clipboard value")
        ), maxItems: 2)

        XCTAssertEqual(retouched.id, recurring.id)
        XCTAssertGreaterThan(retouched.updatedAt, recurring.updatedAt)
        XCTAssertEqual(store.snapshot.items.map(\.id), [recurring.id, finalNew.id, pinned.id])
        XCTAssertFalse(store.snapshot.items.contains(where: { $0.id == stale.id || $0.id == firstNew.id }))

        await store.flushPendingSave()

        XCTAssertEqual(
            repository.incrementalSyncInvocationCount,
            baselineSynchronizeCount,
            "A repository-synced capture burst must use the incremental journal instead of synchronize(with:)"
        )
        let exported = try repository.exportSnapshot()
        XCTAssertEqual(exported.items.map(\.id), [recurring.id, finalNew.id, pinned.id])
        XCTAssertEqual(exported.pinboards.first(where: { $0.id == smartText.id })?.itemIDs, [recurring.id, finalNew.id])
        XCTAssertEqual(exported.pinboards.first(where: { $0.id == userPinboard.id })?.itemIDs, [pinned.id])

        let persisted = try harness.snapshotStore.load()
        XCTAssertEqual(persisted.items.map(\.id), exported.items.map(\.id))
        XCTAssertEqual(persisted.pinboards, exported.pinboards)
    }

    func testCaptureHotPathInspectsBoundedItemsAtFiveAndTenThousandHistoryEntries() throws {
        for historyCount in [5_000, 10_000] {
            let harness = try StoreHarness()
            defer { harness.cleanup() }

            let now = Date(timeIntervalSince1970: 5_000_000)
            let pinnedTailCount = min(1_000, historyCount / 5)
            let maxHistoryItems = historyCount - pinnedTailCount
            let unpinnedItems = (0..<maxHistoryItems).map { index in
                ClipboardItem(
                    createdAt: now.addingTimeInterval(TimeInterval(-index)),
                    updatedAt: now.addingTimeInterval(TimeInterval(-index)),
                    sourceAppName: "Notes",
                    deviceName: "Test Mac",
                    contentType: .text,
                    title: "History \(index)",
                    payload: ClipboardPayload(text: "capture hot path history \(index)")
                )
            }
            let pinnedItems = (0..<pinnedTailCount).map { index in
                ClipboardItem(
                    createdAt: now.addingTimeInterval(TimeInterval(-maxHistoryItems - index)),
                    updatedAt: now.addingTimeInterval(TimeInterval(-maxHistoryItems - index)),
                    sourceAppName: "Safari",
                    deviceName: "Test Mac",
                    contentType: .url,
                    title: "Pinned \(index)",
                    payload: ClipboardPayload(urlString: "https://example.com/pinned/\(index)")
                )
            }
            let items = unpinnedItems + pinnedItems
            let smartText = Pinboard(
                name: SmartPinboardCategory.text.pinboardName,
                colorHex: SmartPinboardCategory.text.colorHex,
                itemIDs: unpinnedItems.map(\.id)
            )
            let userPinboard = Pinboard(
                name: "Pinned Tail",
                colorHex: "#4EA7FC",
                itemIDs: pinnedItems.map(\.id)
            )
            var snapshot = PasteBuddySnapshot(items: items, pinboards: [smartText, userPinboard])
            snapshot.storage = StorageConfiguration(
                maxHistoryItems: maxHistoryItems,
                retentionDays: 0,
                maxStorageBytes: 100 * 1_024 * 1_024 * 1_024
            )
            let store = PasteBuddyStore(
                diskStore: harness.snapshotStore,
                saveDebounceNanoseconds: 60_000_000_000
            )
            store.snapshot = snapshot
            store.primeCaptureHotPathIndexesForTesting()
            store.resetCaptureHotPathInspectionCountForTesting()

            let clock = ContinuousClock()
            let startedAt = clock.now
            let captured = store.addCapturedItem(ClipboardItem(
                createdAt: now.addingTimeInterval(1),
                updatedAt: now.addingTimeInterval(1),
                sourceAppName: "Terminal",
                deviceName: "Test Mac",
                contentType: .text,
                title: "Newest",
                payload: ClipboardPayload(text: "newest bounded capture")
            ))
            let elapsed = startedAt.duration(to: clock.now)
            let elapsedMilliseconds = Double(elapsed.components.seconds) * 1_000
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
            store.cancelPendingSaveForTesting()

            XCTAssertEqual(store.snapshot.items.count, historyCount)
            XCTAssertEqual(store.snapshot.items.first?.id, captured.id)
            XCTAssertFalse(store.snapshot.items.contains(where: { $0.id == unpinnedItems.last?.id }))
            XCTAssertEqual(store.snapshot.pinboards[0].itemIDs.count, maxHistoryItems)
            XCTAssertEqual(store.snapshot.pinboards[0].itemIDs.first, captured.id)
            XCTAssertEqual(store.snapshot.pinboards[1].itemIDs, pinnedItems.map(\.id))
            XCTAssertLessThanOrEqual(
                store.captureHotPathItemInspectionCountForTesting,
                8,
                "Capture at \(historyCount) items should not rescan the full history or Smart Pinboard."
            )
            XCTAssertLessThan(
                elapsedMilliseconds,
                500,
                "A single \(historyCount)-item capture took \(elapsedMilliseconds) ms."
            )
            print("PasteBuddy capture hot path \(historyCount) items: \(elapsedMilliseconds) ms")
        }
    }

    func testCloudImportMergesCaptureCreatedWhileRemoteFetchIsSuspended() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        let encryptionService = EncryptionService(
            service: "com.pastebuddy.cloud-import-race-tests",
            account: UUID().uuidString,
            keyID: "test-key",
            keyMaterialStore: FixedEncryptionKeyMaterialStore()
        )
        let transport = SuspendedCloudSyncRemoteTransport()
        let cloudService = CloudKitSyncService(
            transport: transport,
            builder: CloudSyncPackageBuilder(encryptor: encryptionService),
            importer: CloudSyncPackageImporter(decryptor: encryptionService)
        )
        let sync = SyncConfiguration(
            provider: .cloudKit,
            isCloudSyncEnabled: true,
            isSharedPinboardsEnabled: true,
            cloudKitContainerIdentifier: "iCloud.com.example.PasteBuddy",
            keyHierarchyVersion: 1,
            isCloudKitCapabilityConfigured: true
        )
        let initialLocal = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Local Mac",
            contentType: .text,
            title: "Initial Local",
            payload: ClipboardPayload(text: "initial local item")
        )
        let remote = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Remote Mac",
            contentType: .text,
            title: "Remote",
            payload: ClipboardPayload(text: "remote item")
        )
        _ = try await cloudService.upload(PasteBuddySnapshot(items: [remote], sync: sync))
        await transport.suspendNextFetch()

        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            saveDebounceNanoseconds: 60_000_000_000
        )
        store.snapshot = PasteBuddySnapshot(items: [initialLocal], sync: sync)
        let importTask = Task { @MainActor in
            await store.importLatestCloudSyncSnapshot(using: cloudService)
        }

        let fetchDeadline = Date().addingTimeInterval(1)
        while await !transport.fetchHasStarted(), Date() < fetchDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let didStartFetch = await transport.fetchHasStarted()
        XCTAssertTrue(didStartFetch)
        let concurrentCapture = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Terminal",
            deviceName: "Local Mac",
            contentType: .text,
            title: "Captured During Fetch",
            payload: ClipboardPayload(text: "must survive cloud import")
        ))

        await transport.resumeFetch()
        let result = await importTask.value

        XCTAssertNotNil(result)
        XCTAssertEqual(
            Set(store.snapshot.items.map(\.id)),
            Set([initialLocal.id, concurrentCapture.id, remote.id])
        )
        await store.flushPendingSave()
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

final class StoreHarness {
    let directory: URL
    let encryptionService: EncryptionService
    let snapshotStore: EncryptedSnapshotStore

    init() throws {
        directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("PasteBuddyStoreTests-\(UUID().uuidString)", isDirectory: true)
        encryptionService = EncryptionService(
            service: "com.pastebuddy.store-tests",
            account: UUID().uuidString,
            keyID: "test-key",
            keyMaterialStore: FixedEncryptionKeyMaterialStore()
        )
        snapshotStore = EncryptedSnapshotStore(
            fileURL: directory.appendingPathComponent("clipboard.pbenc"),
            encryptionService: encryptionService
        )
    }

    func cleanup() {
        try? encryptionService.deleteKeyForTesting()
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct FakeHistoryUnlockAuthenticator: HistoryUnlockAuthenticating {
    var result: Bool

    func authenticate(reason: String) async throws -> Bool {
        result
    }
}

private actor InMemoryPinboardShareInvitationTransport: PinboardShareInvitationTransport {
    private var identitiesByFingerprint: [String: PinboardSharePublicIdentity] = [:]
    private var packages: [PinboardShareInvitationPackage] = []

    func publishIdentity(_ identity: PinboardSharePublicIdentity) async throws -> PinboardSharePublicIdentity {
        identitiesByFingerprint[identity.publicKeyFingerprint] = identity
        return identity
    }

    func saveInvitation(_ package: PinboardShareInvitationPackage) async throws -> PinboardShareInvitationPackage {
        packages.removeAll { $0.id == package.id }
        packages.append(package)
        return package
    }

    func fetchInvitations(recipientPublicKeyFingerprint: String) async throws -> [PinboardShareInvitationPackage] {
        packages
            .filter { $0.recipientIdentity.publicKeyFingerprint == recipientPublicKeyFingerprint }
            .sorted { $0.createdAt < $1.createdAt }
    }
}

private actor SuspendedCloudSyncRemoteTransport: CloudSyncRemoteRecordTransport {
    private var records: [CloudSyncRemoteRecord] = []
    private var shouldSuspendNextFetch = false
    private var didStartFetch = false
    private var fetchContinuation: CheckedContinuation<Void, Never>?

    func save(_ record: CloudSyncRemoteRecord) async throws -> CloudSyncRemoteRecord {
        records.removeAll { $0.packageID == record.packageID }
        records.append(record)
        return record
    }

    func fetchLatest(limit: Int) async throws -> [CloudSyncRemoteRecord] {
        if shouldSuspendNextFetch {
            shouldSuspendNextFetch = false
            didStartFetch = true
            await withCheckedContinuation { continuation in
                fetchContinuation = continuation
            }
        }
        return Array(records.sorted { $0.createdAt > $1.createdAt }.prefix(max(limit, 0)))
    }

    func suspendNextFetch() {
        shouldSuspendNextFetch = true
        didStartFetch = false
    }

    func fetchHasStarted() -> Bool { didStartFetch }

    func resumeFetch() {
        fetchContinuation?.resume()
        fetchContinuation = nil
    }
}

private actor SuspendedStoreLoadGate {
    private var suspended = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        suspended = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasSuspended() -> Bool { suspended }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private final class FixedEncryptionKeyMaterialStore: EncryptionKeyMaterialStore, @unchecked Sendable {
    private let keyData: Data

    init(keyData: Data = Data(repeating: 0x5A, count: 32)) {
        self.keyData = keyData
    }

    func loadOrCreateKeyData() throws -> Data { keyData }
    func deleteStoredKeyMaterial() throws {}
}
