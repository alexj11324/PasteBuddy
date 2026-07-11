import Foundation
import XCTest
@testable import PasteBuddyCore

extension PasteBuddyStoreTests {
    func testPerformanceSignpostItemCountBucketsAreBounded() {
        XCTAssertEqual(PasteBuddyPerformanceSignposts.ItemCountBucket(itemCount: nil), .unknown)
        XCTAssertEqual(PasteBuddyPerformanceSignposts.ItemCountBucket(itemCount: 0), .none)
        XCTAssertEqual(PasteBuddyPerformanceSignposts.ItemCountBucket(itemCount: 1), .single)
        XCTAssertEqual(PasteBuddyPerformanceSignposts.ItemCountBucket(itemCount: 100), .small)
        XCTAssertEqual(PasteBuddyPerformanceSignposts.ItemCountBucket(itemCount: 1_000), .medium)
        XCTAssertEqual(PasteBuddyPerformanceSignposts.ItemCountBucket(itemCount: 5_000), .large)
        XCTAssertEqual(PasteBuddyPerformanceSignposts.ItemCountBucket(itemCount: 10_000), .veryLarge)
        XCTAssertEqual(PasteBuddyPerformanceSignposts.ItemCountBucket(itemCount: 10_001), .oversized)
    }

    func testLoadedStoreFactoryFailsClosedWhenAsyncLoadFails() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        try FileManager.default.createDirectory(
            at: harness.snapshotStore.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("sensitive clipboard payload".utf8).write(to: harness.snapshotStore.fileURL)
        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        var diagnosticReasons: [PasteBuddyStoreFactory.FailureReason] = []

        do {
            try await PasteBuddyStoreFactory.load(
                store,
                diagnostics: { diagnosticReasons.append($0) }
            )
            XCTFail("A failed history load must not be treated as an empty store.")
        } catch {
            XCTAssertEqual(error as? PasteBuddyPersistenceError, .historyUnavailable)
            XCTAssertEqual(error.localizedDescription, PasteBuddyPersistenceError.historyUnavailable.localizedDescription)
        }

        XCTAssertTrue(store.isPersistenceWriteBlocked)
        XCTAssertEqual(store.lastErrorMessage, PasteBuddyPersistenceError.historyUnavailable.localizedDescription)
        XCTAssertEqual(diagnosticReasons, [.historyLoadFailed])
    }

    func testAsyncLoadClassifiesCorruptedSnapshotWithoutExposingErrorDetails() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        try FileManager.default.createDirectory(
            at: harness.snapshotStore.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("synthetic corrupted snapshot".utf8).write(to: harness.snapshotStore.fileURL)
        let store = PasteBuddyStore(diskStore: harness.snapshotStore)

        let didLoad = await store.loadAsync()

        XCTAssertFalse(didLoad)
        XCTAssertEqual(
            store.lastPersistenceLoadDiagnostic,
            PasteBuddyPersistenceLoadDiagnostic(
                stage: .snapshotLoad,
                reason: .snapshotUnreadable
            )
        )
        XCTAssertTrue(store.isPersistenceWriteBlocked)
        XCTAssertEqual(
            store.lastErrorMessage,
            PasteBuddyPersistenceError.historyUnavailable.localizedDescription
        )
    }

    func testPersistenceLoadDiagnosticsExposeOnlyFixedStageAndReasonVocabulary() {
        let requiredStages: [PasteBuddyPersistenceLoadDiagnostic.Stage] = [
            .snapshotLoad,
            .repositoryInitialization,
            .repositoryMetadata,
            .repositoryExport,
            .loadApply,
            .storageMigration,
            .repositoryImport,
        ]
        let requiredReasons: [PasteBuddyPersistenceLoadDiagnostic.Reason] = [
            .permissionDenied,
            .snapshotUnreadable,
            .snapshotMigration,
            .database,
            .staleWriter,
            .cancelled,
            .unknown,
        ]

        for stage in requiredStages {
            XCTAssertTrue(PasteBuddyPersistenceLoadDiagnostic.Stage.allCases.contains(stage))
        }
        for reason in requiredReasons {
            XCTAssertTrue(PasteBuddyPersistenceLoadDiagnostic.Reason.allCases.contains(reason))
        }
    }

    func testPersistenceLoadDiagnosticClassifiesWrappedCocoaNoPermissionError() {
        let error = SnapshotStoreError.unreadableStore(
            CocoaError(.fileReadNoPermission)
        )

        XCTAssertEqual(
            PasteBuddyPersistenceLoadDiagnostic.reason(for: error, at: .snapshotLoad),
            .permissionDenied
        )
    }

    func testPersistenceLoadDiagnosticClassifiesOnlyFixedFailureReasons() {
        let genericError = NSError(domain: "PasteBuddySyntheticTestError", code: 1)

        XCTAssertEqual(
            PasteBuddyPersistenceLoadDiagnostic.reason(
                for: SnapshotStoreError.legacyMigrationFailed(genericError),
                at: .snapshotLoad
            ),
            .snapshotMigration
        )
        XCTAssertEqual(
            PasteBuddyPersistenceLoadDiagnostic.reason(for: CancellationError(), at: .loadApply),
            .cancelled
        )
        XCTAssertEqual(
            PasteBuddyPersistenceLoadDiagnostic.reason(
                for: PasteBuddyPersistenceError.historyUnavailable,
                at: .storageMigration
            ),
            .staleWriter
        )
        XCTAssertEqual(
            PasteBuddyPersistenceLoadDiagnostic.reason(for: genericError, at: .repositoryMetadata),
            .database
        )
        XCTAssertEqual(
            PasteBuddyPersistenceLoadDiagnostic.reason(for: genericError, at: .loadApply),
            .unknown
        )
    }

    func testSuccessfulAsyncLoadClearsPreviousPersistenceLoadDiagnostic() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        try FileManager.default.createDirectory(
            at: harness.snapshotStore.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("synthetic corrupted snapshot".utf8).write(to: harness.snapshotStore.fileURL)
        let store = PasteBuddyStore(diskStore: harness.snapshotStore)

        let failedLoad = await store.loadAsync()
        XCTAssertFalse(failedLoad)
        XCTAssertNotNil(store.lastPersistenceLoadDiagnostic)

        try FileManager.default.removeItem(at: harness.snapshotStore.fileURL)
        try harness.snapshotStore.save(PasteBuddySnapshot())
        let successfulLoad = await store.loadAsync()

        XCTAssertTrue(successfulLoad)
        XCTAssertNil(store.lastPersistenceLoadDiagnostic)
        XCTAssertFalse(store.isPersistenceWriteBlocked)
        XCTAssertNil(store.lastErrorMessage)
    }

    func testLoadedStoreFactoryFailsClosedWhenInitialLoadIsAbortedByConcurrentMutation() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        let persistedItem = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Persisted history",
            payload: ClipboardPayload(text: "must not be replaced")
        )
        try harness.snapshotStore.save(PasteBuddySnapshot(items: [persistedItem]))
        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let loadGate = SuspendedStoreLoadGate()
        store.beforeApplyingAsyncLoadForTesting = {
            await loadGate.suspend()
        }
        var diagnosticReasons: [PasteBuddyStoreFactory.FailureReason] = []

        let loadTask = Task { @MainActor () -> Error? in
            do {
                try await PasteBuddyStoreFactory.load(
                    store,
                    diagnostics: { diagnosticReasons.append($0) }
                )
                return nil
            } catch {
                return error
            }
        }
        while await !loadGate.hasSuspended() {
            await Task.yield()
        }
        store.snapshot.general.launchAtLoginEnabled = true
        await loadGate.resume()

        let error = await loadTask.value
        XCTAssertEqual(error as? PasteBuddyPersistenceError, .historyUnavailable)
        XCTAssertEqual(diagnosticReasons, [.historyLoadFailed])
        XCTAssertTrue(store.isPersistenceWriteBlocked)
        XCTAssertEqual(store.lastErrorMessage, PasteBuddyPersistenceError.historyUnavailable.localizedDescription)
        XCTAssertEqual(
            store.lastPersistenceLoadDiagnostic,
            PasteBuddyPersistenceLoadDiagnostic(stage: .loadApply, reason: .cancelled)
        )
        XCTAssertTrue(store.snapshot.items.isEmpty, "An aborted initial load must not masquerade as loaded history.")
        XCTAssertEqual(try harness.snapshotStore.load().items.map(\.id), [persistedItem.id])
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
        _ = await reloadTask.value
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
        let didReload = await reloadTask.value

        XCTAssertFalse(didReload)
        XCTAssertEqual(
            store.lastPersistenceLoadDiagnostic,
            PasteBuddyPersistenceLoadDiagnostic(stage: .loadApply, reason: .cancelled)
        )
        XCTAssertEqual(store.snapshot.items.map(\.id), [concurrentCapture.id, firstCapture.id, existing.id])
        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()
        XCTAssertEqual(reloaded.snapshot.items.map(\.id), [concurrentCapture.id, firstCapture.id, existing.id])
    }

    func testAsyncLoadRecordsCancelledDiagnosticWhenPendingFlushIsCancelled() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        try harness.snapshotStore.save(PasteBuddySnapshot())
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            saveDebounceNanoseconds: 60_000_000_000
        )
        store.load()
        _ = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Tests",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Pending Before Cancelled Load",
            payload: ClipboardPayload(text: "synthetic pending capture")
        ))
        let flushGate = SuspendedStoreLoadGate()
        store.beforePersistingFlushSnapshotForTesting = {
            await flushGate.suspend()
        }

        let loadTask = Task { @MainActor in
            await store.loadAsync()
        }
        while await !flushGate.hasSuspended() {
            await Task.yield()
        }
        loadTask.cancel()
        await flushGate.resume()
        let didLoad = await loadTask.value

        XCTAssertFalse(didLoad)
        XCTAssertEqual(
            store.lastPersistenceLoadDiagnostic,
            PasteBuddyPersistenceLoadDiagnostic(stage: .loadApply, reason: .cancelled)
        )
    }

    func testCancellingFlushBeforeCommitDoesNotPersistPendingCapture() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        harness.snapshotStore.storageMode = .standard
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.snapshotStore.fileURL.path))
    }

    func testCancelledSynchronousSaveSchedulesIndependentRetry() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        harness.snapshotStore.storageMode = .standard
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
            if repositoryContainsItem {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertTrue(try repository.exportSnapshot().items.contains { $0.id == item.id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.snapshotStore.fileURL.path))
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
        let overlappingLoad = await store.loadAsync()

        XCTAssertFalse(overlappingLoad)
        XCTAssertEqual(
            store.lastPersistenceLoadDiagnostic,
            PasteBuddyPersistenceLoadDiagnostic(stage: .storageMigration, reason: .cancelled)
        )
        let concurrentCapture = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Messages",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Encrypted Reload Capture",
            payload: ClipboardPayload(text: "must survive encrypted cleanup")
        ))
        await cleanupGate.resume()
        _ = await loadTask.value

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

    func testSensitiveContentDetectorBlocksLikelySecretsButAllowsNormalText() {
        XCTAssertTrue(SensitiveContentDetector.isLikelySensitive("api_key = sk_live_51ABCDEF0123456789"))
        XCTAssertTrue(SensitiveContentDetector.isLikelySensitive("One-time code: 483920"))
        XCTAssertTrue(SensitiveContentDetector.isLikelySensitive("card 4111 1111 1111 1111"))
        XCTAssertFalse(SensitiveContentDetector.isLikelySensitive("Quarterly launch checklist and copy notes"))
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

    func testRepositoryBackedStoreHydratesSQLiteAssetsOnDemandAfterReload() async throws {
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

        XCTAssertFalse(FileManager.default.fileExists(atPath: standardSnapshotStore.fileURL.path))
        XCTAssertEqual(try repository.exportSnapshot().items.map(\.id), [captured.id])

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

    @MainActor
    func testStandardRepositorySaveDoesNotWriteSnapshotFile() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let databaseURL = harness.directory.appendingPathComponent("sqlite-authority.sqlite")
        let repository = ClipboardItemRepository(database: try PasteBuddyDatabase(fileURL: databaseURL))
        let snapshotURL = harness.directory.appendingPathComponent("obsolete-standard.pbstore")
        let snapshotStore = EncryptedSnapshotStore(fileURL: snapshotURL, storageMode: .standard)
        let store = PasteBuddyStore(
            diskStore: snapshotStore,
            clipboardRepository: repository
        )

        let item = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "SQLite Authority",
            payload: ClipboardPayload(text: "standard mode belongs in SQLite")
        ))
        let didFlush = await store.flushPendingSave()
        XCTAssertTrue(didFlush)

        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))
        XCTAssertEqual(try repository.exportSnapshot().items.map(\.id), [item.id])
    }

    func testHistoryAuthorityLeaseSerializesCutoverAgainstNormalPersistence() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        let first = HistoryPersistenceAuthorityStore(snapshotURL: harness.snapshotStore.fileURL)
        let second = HistoryPersistenceAuthorityStore(snapshotURL: harness.snapshotStore.fileURL)

        let exclusive = try XCTUnwrap(first.acquireLease(.exclusive, wait: false))
        XCTAssertNil(try second.acquireLease(.shared, wait: false))
        XCTAssertNil(try second.acquireLease(.exclusive, wait: false))
        exclusive.release()

        let shared = try XCTUnwrap(second.acquireLease(.shared, wait: false))
        shared.release()
    }

    func testHistoryAuthorityCutoverRequiresOrderedEpochTransitions() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        let authority = HistoryPersistenceAuthorityStore(snapshotURL: harness.snapshotStore.fileURL)
        let sourceRevision = UUID()
        let targetRevision = UUID()

        let epoch = try authority.beginCutover(
            source: .encryptedSnapshot,
            target: .sqlite,
            sourceRevision: sourceRevision
        )
        XCTAssertEqual(try authority.load()?.phase, .preparing)
        XCTAssertThrowsError(
            try authority.recordTargetValidated(epoch: UUID(), targetRevision: targetRevision)
        )

        try authority.recordTargetValidated(epoch: epoch, targetRevision: targetRevision)
        XCTAssertEqual(try authority.load()?.phase, .targetValidated)
        try authority.recordSourceRevoked(epoch: epoch)
        XCTAssertEqual(try authority.load()?.phase, .sourceRevoked)
        try authority.commitStable(epoch: epoch)
        XCTAssertEqual(
            try authority.load(),
            HistoryPersistenceAuthorityRecord(
                phase: .stable,
                authority: .sqlite,
                source: nil,
                target: nil,
                sourceRevision: nil,
                targetRevision: targetRevision,
                epoch: epoch
            )
        )
    }

    @MainActor
    func testStandardSettingsOnlySaveUpdatesMetadataWithoutItemSynchronization() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        harness.snapshotStore.storageMode = .standard
        let repository = ClipboardItemRepository(
            database: try PasteBuddyDatabase(
                fileURL: harness.directory.appendingPathComponent("metadata-only.sqlite")
            )
        )
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository,
            saveDebounceNanoseconds: 60_000_000_000
        )
        _ = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Keep",
            payload: ClipboardPayload(text: "do not rescan me")
        ))
        let didFlushCapture = await store.flushPendingSave()
        XCTAssertTrue(didFlushCapture)
        let baselineSyncCount = repository.incrementalSyncInvocationCount

        store.setAlwaysPasteAsPlainText(true)
        let didFlushSetting = await store.flushPendingSave()
        XCTAssertTrue(didFlushSetting)

        XCTAssertEqual(repository.incrementalSyncInvocationCount, baselineSyncCount)
        XCTAssertTrue(try repository.exportSnapshot().paste.alwaysPasteAsPlainText)
        XCTAssertEqual(try repository.exportSnapshot().items.count, 1)
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

}
