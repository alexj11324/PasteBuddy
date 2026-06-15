import Foundation

public struct SnapshotPersistenceLoadResult: Sendable {
    public var snapshot: PasteBuddySnapshot
    public var loadedStorageMode: SnapshotStorageMode?

    public init(snapshot: PasteBuddySnapshot, loadedStorageMode: SnapshotStorageMode?) {
        self.snapshot = snapshot
        self.loadedStorageMode = loadedStorageMode
    }
}

public actor SnapshotPersistenceActor {
    private let diskStore: EncryptedSnapshotStore

    public init(diskStore: EncryptedSnapshotStore) {
        self.diskStore = diskStore
    }

    public func load() throws -> SnapshotPersistenceLoadResult {
        let snapshot = try diskStore.load()
        return SnapshotPersistenceLoadResult(
            snapshot: snapshot,
            loadedStorageMode: diskStore.lastLoadedStorageMode
        )
    }

    public func save(_ snapshot: PasteBuddySnapshot, storageMode: SnapshotStorageMode) throws {
        diskStore.storageMode = storageMode
        try diskStore.save(snapshot)
    }
}

public actor ClipboardRepositorySyncActor {
    private let repository: ClipboardItemRepository

    public init(repository: ClipboardItemRepository) {
        self.repository = repository
    }

    public func replaceAll(with snapshot: PasteBuddySnapshot) throws {
        try repository.replaceAll(with: snapshot)
    }

    @discardableResult
    public func insertOrTouchItem(_ item: ClipboardItem) throws -> ClipboardItem {
        try repository.insertOrTouchItem(item)
    }

    public func updateOCRText(_ text: String, for itemID: UUID) throws {
        try repository.updateOCRText(text, for: itemID)
    }
}
