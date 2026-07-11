import Foundation

actor StandardHistoryBackend: HistoryPersistenceBackend {
    private let repository: ClipboardItemRepository
    private var latestAcceptedGeneration: UInt64 = 0

    init(repository: ClipboardItemRepository) {
        self.repository = repository
    }

    func load() throws -> HistoryPersistenceLoadResult {
        var snapshot = try repository.exportSnapshot(hydrateAssets: false)
        snapshot.security.storageMode = .standard
        return HistoryPersistenceLoadResult(snapshot: snapshot, loadedStorageMode: .standard)
    }

    func commit(
        _ snapshot: PasteBuddySnapshot,
        plan: HistoryPersistenceMutationPlan,
        generation: UInt64
    ) throws -> Bool {
        guard generation >= latestAcceptedGeneration else { return false }
        latestAcceptedGeneration = generation
        switch plan {
        case .none:
            break
        case .synchronize:
            try repository.synchronize(with: snapshot)
        case .capture(let journal, let includeMetadata):
            try repository.applyCaptureJournal(
                journal,
                metadataFrom: includeMetadata ? snapshot : nil
            )
        case .metadata:
            try repository.updateMetadata(from: snapshot)
        }
        return true
    }

    func flush() throws {}

    func eraseSensitiveData() throws {
        try repository.eraseSensitiveContent()
    }

    func replaceAll(with snapshot: PasteBuddySnapshot) throws { try repository.replaceAll(with: snapshot) }
    @discardableResult
    func synchronize(with snapshot: PasteBuddySnapshot) throws -> ClipboardRepositorySyncSummary { try repository.synchronize(with: snapshot) }
    func updateMetadata(from snapshot: PasteBuddySnapshot) throws { try repository.updateMetadata(from: snapshot) }
    func applyCaptureJournal(_ journal: ClipboardRepositoryCaptureJournal, metadataFrom snapshot: PasteBuddySnapshot? = nil) throws { try repository.applyCaptureJournal(journal, metadataFrom: snapshot) }
    func insertOrTouchItem(_ item: ClipboardItem) throws -> ClipboardItem { try repository.insertOrTouchItem(item) }
    func upsertItem(_ item: ClipboardItem, snapshotOrder: Int? = nil) throws { try repository.upsertItem(item, snapshotOrder: snapshotOrder) }
    func updateOCRText(_ text: String, for itemID: UUID) throws { try repository.updateOCRText(text, for: itemID) }
    func deleteItems(_ ids: [UUID]) throws { try repository.deleteItems(ids) }
    func upsertPinboardMemberships(_ pinboards: [Pinboard]) throws { try repository.upsertPinboardMemberships(pinboards) }
    func hydrateAssets(for item: ClipboardItem) throws -> ClipboardItem { try repository.hydrateAssets(for: item) }
    func hydrateAssets(for items: [ClipboardItem]) throws -> [ClipboardItem] { try repository.hydrateAssets(for: items) }
    func imageData(for item: ClipboardItem) throws -> Data? { try repository.imageData(for: item) }
    func rtfData(for item: ClipboardItem) throws -> Data? { try repository.rtfData(for: item) }
    func hasStoredSnapshot() throws -> Bool { try repository.hasStoredSnapshot() }
    func currentRevisionForAuthority() throws -> UUID? { try repository.currentRevisionForAuthority() }
    func compactIfNeeded() throws -> PasteBuddyDatabase.CompactionResult { try repository.compactIfNeeded() }
    func eraseSensitiveContent() throws { try repository.eraseSensitiveContent() }
    func exportSnapshot(hydrateAssets: Bool = true) throws -> PasteBuddySnapshot { try repository.exportSnapshot(hydrateAssets: hydrateAssets) }
}
