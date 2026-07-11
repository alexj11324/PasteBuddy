#if canImport(AppIntents)
import PasteBuddyCore
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

    private func failingLoader(for store: PasteBuddyStore) -> PasteBuddyAppIntentStoreLoader {
        PasteBuddyAppIntentStoreLoader {
            try await PasteBuddyStoreFactory.load(store)
            return store
        }
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
#endif
