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
    public func synchronize(with snapshot: PasteBuddySnapshot) throws -> ClipboardRepositorySyncSummary {
        try repository.synchronize(with: snapshot)
    }

    @discardableResult
    public func insertOrTouchItem(_ item: ClipboardItem) throws -> ClipboardItem {
        try repository.insertOrTouchItem(item)
    }

    public func upsertItem(_ item: ClipboardItem, snapshotOrder: Int? = nil) throws {
        try repository.upsertItem(item, snapshotOrder: snapshotOrder)
    }

    public func updateOCRText(_ text: String, for itemID: UUID) throws {
        try repository.updateOCRText(text, for: itemID)
    }

    public func deleteItems(_ ids: [UUID]) throws {
        try repository.deleteItems(ids)
    }

    public func upsertPinboardMemberships(_ pinboards: [Pinboard]) throws {
        try repository.upsertPinboardMemberships(pinboards)
    }

    public func hydrateAssets(for item: ClipboardItem) throws -> ClipboardItem {
        try repository.hydrateAssets(for: item)
    }

    public func imageData(for item: ClipboardItem) throws -> Data? {
        try repository.imageData(for: item)
    }

    public func rtfData(for item: ClipboardItem) throws -> Data? {
        try repository.rtfData(for: item)
    }

    public func exportSnapshot() throws -> PasteBuddySnapshot {
        try repository.exportSnapshot()
    }
}
