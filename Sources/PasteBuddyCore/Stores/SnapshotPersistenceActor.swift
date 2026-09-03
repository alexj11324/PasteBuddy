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

    public func fetchPage(
        _ request: ClipboardItemPageRequest = ClipboardItemPageRequest()
    ) throws -> [ClipboardItem] {
        try repository.fetchPage(request)
    }

    public func fetchPageAndCount(
        _ request: ClipboardItemPageRequest = ClipboardItemPageRequest()
    ) throws -> ClipboardItemPageAndCount {
        try repository.fetchPageAndCount(request)
    }

    public func items(ids: [UUID], hydrateAssets: Bool = false) throws -> [ClipboardItem] {
        try repository.items(ids: ids, hydrateAssets: hydrateAssets)
    }

    public func updateOCRText(_ text: String, for itemID: UUID) throws {
        try repository.updateOCRText(text, for: itemID)
    }

    public func deleteItems(_ ids: [UUID]) throws {
        try repository.deleteItems(ids)
    }

    public func pruneItems(
        retentionCutoff: Date?,
        maxStorageBytes: Int,
        keepingItemIDs: Set<UUID>
    ) throws -> [UUID] {
        try repository.pruneItems(
            retentionCutoff: retentionCutoff,
            maxStorageBytes: maxStorageBytes,
            keepingItemIDs: keepingItemIDs
        )
    }

    public func upsertPinboardMemberships(_ pinboards: [Pinboard]) throws {
        try repository.upsertPinboardMemberships(pinboards)
    }

    public func synchronizePinboards(with pinboards: [Pinboard]) throws {
        try repository.synchronizePinboards(with: pinboards)
    }

    public func hydrateAssets(for item: ClipboardItem) throws -> ClipboardItem {
        try repository.hydrateAssets(for: item)
    }

    public func hydrateAssets(for items: [ClipboardItem]) throws -> [ClipboardItem] {
        try repository.hydrateAssets(for: items)
    }

    public func imageData(for item: ClipboardItem) throws -> Data? {
        try repository.imageData(for: item)
    }

    public func rtfData(for item: ClipboardItem) throws -> Data? {
        try repository.rtfData(for: item)
    }

    public func exportSnapshot(
        hydrateAssets: Bool = true,
        itemLimit: Int? = nil
    ) throws -> PasteBuddySnapshot {
        try repository.exportSnapshot(hydrateAssets: hydrateAssets, itemLimit: itemLimit)
    }

    public func saveMetadata(from snapshot: PasteBuddySnapshot) throws {
        try repository.saveMetadata(from: snapshot)
    }

    public func hasStoredSnapshot() throws -> Bool {
        try repository.hasStoredSnapshot()
    }

    public func hasStoredSettingsBehaviorMetadata() throws -> Bool {
        try repository.hasStoredSettingsBehaviorMetadata()
    }
}
