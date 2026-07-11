import Foundation
import OSLog

public enum PasteBuddyStoreFactory {
    enum FailureReason: String, Equatable, Sendable {
        case applicationSupportDirectoryUnavailable
        case databaseURLUnavailable
        case historyLoadFailed
    }

    private static let logger = Logger(
        subsystem: "com.alexjiang.PasteBuddy",
        category: "Persistence"
    )

    @MainActor
    public static func makeDefault() throws -> PasteBuddyStore {
        try makeDefault(
            applicationSupportDirectoryResolver: {
                guard let directory = FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first else {
                    throw SnapshotStoreError.missingApplicationSupportDirectory
                }
                return directory
            },
            databaseURLResolver: PasteBuddyDatabase.defaultDatabaseURL,
            diagnostics: recordFailure
        )
    }

    @MainActor
    static func makeDefault(
        applicationSupportDirectoryResolver: () throws -> URL,
        databaseURLResolver: () throws -> URL,
        diagnostics: (FailureReason) -> Void
    ) throws -> PasteBuddyStore {
        let applicationSupportDirectory: URL
        do {
            applicationSupportDirectory = try applicationSupportDirectoryResolver()
        } catch {
            diagnostics(.applicationSupportDirectoryUnavailable)
            throw PasteBuddyPersistenceError.historyUnavailable
        }

        let databaseURL: URL
        do {
            databaseURL = try databaseURLResolver()
        } catch {
            diagnostics(.databaseURLUnavailable)
            throw PasteBuddyPersistenceError.historyUnavailable
        }

        let diskStore = EncryptedSnapshotStore.defaultStore(
            in: applicationSupportDirectory.appendingPathComponent("PasteBuddy", isDirectory: true),
            storageMode: .standard
        )
        return PasteBuddyStore(
            diskStore: diskStore,
            deferredRepositoryDatabaseURL: databaseURL,
            saveDebounceNanoseconds: PasteBuddyStore.defaultSaveDebounceNanoseconds
        )
    }

    @MainActor
    public static func makeLoadedDefault() async throws -> PasteBuddyStore {
        let store = try makeDefault()
        try await load(store)
        return store
    }

    @MainActor
    public static func load(_ store: PasteBuddyStore) async throws {
        try await load(store, diagnostics: recordFailure)
    }

    @MainActor
    static func load(
        _ store: PasteBuddyStore,
        diagnostics: (FailureReason) -> Void
    ) async throws {
        let didLoad = await store.loadAsync()
        guard didLoad, !store.isPersistenceWriteBlocked, store.lastErrorMessage == nil else {
            store.markHistoryPersistenceUnavailable()
            diagnostics(.historyLoadFailed)
            throw PasteBuddyPersistenceError.historyUnavailable
        }
    }

    private static func recordFailure(_ reason: FailureReason) {
        logger.error("History storage unavailable: \(reason.rawValue, privacy: .public)")
    }
}
