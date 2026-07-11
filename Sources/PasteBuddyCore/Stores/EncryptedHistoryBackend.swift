import Foundation

actor EncryptedHistoryBackend: HistoryPersistenceBackend {
    private let diskStore: EncryptedSnapshotStore
    private var latestAcceptedGeneration: UInt64 = 0

    init(diskStore: EncryptedSnapshotStore) {
        self.diskStore = diskStore
    }

    func load() throws -> HistoryPersistenceLoadResult {
        let snapshot = try diskStore.load()
        return HistoryPersistenceLoadResult(
            snapshot: snapshot,
            loadedStorageMode: diskStore.lastLoadedStorageMode ?? snapshot.security.storageMode
        )
    }

    func commit(
        _ snapshot: PasteBuddySnapshot,
        plan: HistoryPersistenceMutationPlan,
        generation: UInt64
    ) throws -> Bool {
        guard generation >= latestAcceptedGeneration else { return false }
        latestAcceptedGeneration = generation
        diskStore.storageMode = snapshot.security.storageMode
        try diskStore.save(snapshot)
        return true
    }

    func flush() throws {}

    func eraseSensitiveData() throws {
        try diskStore.installRevokedTombstone()
    }
}
