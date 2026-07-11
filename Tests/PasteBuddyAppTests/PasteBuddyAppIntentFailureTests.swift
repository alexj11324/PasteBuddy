#if canImport(AppIntents)
@testable import PasteBuddyCore
import XCTest
@testable import PasteBuddy

@MainActor
final class PasteBuddyAppIntentFailureTests: XCTestCase {
    func testSearchIntentFailsClosedWhenHistoryCannotLoad() async throws {
        let fixture = try await PersistenceFailureTestFixture.make()
        defer { fixture.cleanup() }
        let intent = PasteBuddySearchClipboardIntent(storeLoader: failingLoader(for: fixture.store))
        intent.query = "persisted"
        intent.limit = 5

        try await assertIntentFailsClosed(fixture) {
            _ = try await intent.perform()
        }
    }

    func testCopyIntentFailsClosedWhenHistoryCannotLoad() async throws {
        let fixture = try await PersistenceFailureTestFixture.make()
        defer { fixture.cleanup() }
        let intent = PasteBuddyCopyFirstMatchIntent(storeLoader: failingLoader(for: fixture.store))
        intent.query = "persisted"
        intent.plainText = true

        try await assertIntentFailsClosed(fixture) {
            _ = try await intent.perform()
        }
    }

    func testPasteIntentFailsClosedWhenHistoryCannotLoad() async throws {
        let fixture = try await PersistenceFailureTestFixture.make()
        defer { fixture.cleanup() }
        let intent = PasteBuddyPasteFirstMatchIntent(storeLoader: failingLoader(for: fixture.store))
        intent.query = "persisted"
        intent.plainText = true

        try await assertIntentFailsClosed(fixture) {
            _ = try await intent.perform()
        }
    }

    func testCreatePinboardIntentFailsClosedWhenHistoryCannotLoad() async throws {
        let fixture = try await PersistenceFailureTestFixture.make()
        defer { fixture.cleanup() }
        let intent = PasteBuddyCreatePinboardIntent(storeLoader: failingLoader(for: fixture.store))
        intent.name = "Must Not Be Created"
        intent.colorHex = "#FF0000"

        try await assertIntentFailsClosed(fixture) {
            _ = try await intent.perform()
        }
    }

    func testSaveToPinboardIntentFailsClosedWhenHistoryCannotLoad() async throws {
        let fixture = try await PersistenceFailureTestFixture.make()
        defer { fixture.cleanup() }
        let intent = PasteBuddySaveFirstMatchToPinboardIntent(storeLoader: failingLoader(for: fixture.store))
        intent.query = "persisted"
        intent.pinboardName = "Must Not Be Mutated"

        try await assertIntentFailsClosed(fixture) {
            _ = try await intent.perform()
        }
    }

    func testPasteIntentRevalidatesHistoryAfterTargetWait() async throws {
        try await assertPasteIntentFailsAfterTargetWait(expected: .historyLocked) { store, _ in
            store.setBiometricHistoryLockEnabled(true)
        }
    }

    func testPasteIntentRevalidatesPersistenceAfterTargetWait() async throws {
        try await assertPasteIntentFailsAfterTargetWait(expected: .historyUnavailable) { store, _ in
            store.markHistoryPersistenceUnavailable()
        }
    }

    func testPasteIntentRejectsDeletedItemAfterTargetWait() async throws {
        try await assertPasteIntentFailsAfterTargetWait(expected: .noMatchingItem) { store, item in
            store.removeItem(item.id)
        }
    }

    func testPasteIntentRejectsSameIDReplacementThatNoLongerMatchesAfterTargetWait() async throws {
        try await assertPasteIntentFailsAfterTargetWait(expected: .noMatchingItem) { store, item in
            store.snapshot.items = [ClipboardItem(
                id: item.id,
                sourceAppName: "Notes",
                deviceName: "Test Mac",
                contentType: .text,
                title: "Unrelated replacement",
                payload: ClipboardPayload(text: "current content no longer matches")
            )]
            store.save()
        }
    }

    private func failingLoader(for store: PasteBuddyStore) -> PasteBuddyAppIntentStoreLoader {
        PasteBuddyAppIntentStoreLoader {
            try await PasteBuddyStoreFactory.load(store)
            return store
        }
    }

    private func assertPasteIntentFailsAfterTargetWait(
        expected: PasteIntentRaceExpectedError,
        mutation: @MainActor (PasteBuddyStore, ClipboardItem) -> Void
    ) async throws {
        let fixture = try PasteIntentRaceFixture.make()
        defer { fixture.cleanup() }
        let gate = PasteIntentTargetWaitGate()
        var pastedItemID: UUID?
        let intent = PasteBuddyPasteFirstMatchIntent(
            storeLoader: PasteBuddyAppIntentStoreLoader { fixture.store },
            pasteOperation: { _, format, resolveCurrentItem in
                await gate.suspend()
                let item = try resolveCurrentItem()
                pastedItemID = item.id
                return DirectPasteResult(
                    outcome: .pastedToFrontmostApp,
                    itemCount: 1,
                    format: format
                )
            }
        )
        intent.query = "needle"
        intent.plainText = true

        let pasteTask = Task { @MainActor in
            _ = try await intent.perform()
        }
        await gate.waitUntilSuspended()
        mutation(fixture.store, fixture.item)
        await gate.resume()

        do {
            try await pasteTask.value
            XCTFail("Expected paste intent validation to fail after target wait.")
        } catch {
            switch expected {
            case .historyLocked:
                XCTAssertEqual(error as? AutomationActionError, .historyLocked)
            case .historyUnavailable:
                XCTAssertEqual(error as? PasteBuddyPersistenceError, .historyUnavailable)
            case .noMatchingItem:
                XCTAssertEqual(error as? AutomationActionError, .noMatchingItem)
            }
        }
        XCTAssertNil(pastedItemID)
    }

    private func assertIntentFailsClosed(
        _ fixture: PersistenceFailureTestFixture,
        operation: @MainActor () async throws -> Void
    ) async throws {
        do {
            try await operation()
            XCTFail("The intent must reject unavailable history before performing its action.")
        } catch {
            XCTAssertEqual(error as? PasteBuddyPersistenceError, .historyUnavailable)
            XCTAssertEqual(
                error.localizedDescription,
                PasteBuddyPersistenceError.historyUnavailable.localizedDescription
            )
        }

        XCTAssertTrue(fixture.store.isPersistenceWriteBlocked)
        XCTAssertEqual(
            fixture.store.snapshot.items.map(\.id),
            fixture.snapshotItemIDsBeforeFailure
        )
        XCTAssertEqual(
            fixture.store.snapshot.pinboards.map(\.id),
            fixture.snapshotPinboardIDsBeforeFailure
        )
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), fixture.diskBytesBeforeFailure)
    }
}

private enum PasteIntentRaceExpectedError {
    case historyLocked
    case historyUnavailable
    case noMatchingItem
}

@MainActor
private struct PasteIntentRaceFixture {
    let directory: URL
    let store: PasteBuddyStore
    let item: ClipboardItem

    static func make() throws -> PasteIntentRaceFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasteBuddyIntentRaceTests-\(UUID().uuidString)", isDirectory: true)
        let diskStore = EncryptedSnapshotStore(
            fileURL: directory.appendingPathComponent("clipboard.pbstore"),
            storageMode: .standard
        )
        let item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Original item",
            payload: ClipboardPayload(text: "intent race needle")
        )
        try diskStore.save(PasteBuddySnapshot(items: [item]))
        let store = PasteBuddyStore(diskStore: diskStore)
        store.load()
        return PasteIntentRaceFixture(directory: directory, store: store, item: item)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor PasteIntentTargetWaitGate {
    private var isSuspended = false
    private var suspensionContinuation: CheckedContinuation<Void, Never>?
    private var observerContinuations: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        isSuspended = true
        let observers = observerContinuations
        observerContinuations.removeAll()
        observers.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            suspensionContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            observerContinuations.append(continuation)
        }
    }

    func resume() {
        suspensionContinuation?.resume()
        suspensionContinuation = nil
    }
}
#endif
