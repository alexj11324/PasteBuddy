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
    private var latestAcceptedGeneration: UInt64 = 0

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

    @discardableResult
    public func save(
        _ snapshot: PasteBuddySnapshot,
        storageMode: SnapshotStorageMode,
        hasAuthoritativeRepository: Bool = false,
        generation: UInt64
    ) throws -> Bool {
        guard generation >= latestAcceptedGeneration else { return false }
        latestAcceptedGeneration = generation
        guard storageMode == .encrypted || !hasAuthoritativeRepository else { return true }
        diskStore.storageMode = storageMode
        try diskStore.save(snapshot)
        return true
    }
}

struct PersistenceCommitLease: Sendable, Equatable {
    fileprivate let id: UUID
    let generation: UInt64
}

enum PersistenceCommitOutcome: Sendable {
    case abortedBeforeWrite
    case committed
    case failedAfterWrite
}

final class PersistenceCommitGate: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let generation: UInt64
        let continuation: CheckedContinuation<PersistenceCommitLease?, Never>
    }

    private let lock = NSLock()
    private var activeLease: PersistenceCommitLease?
    private var supersessionBarrierGeneration: UInt64 = 0
    private var waiters: [Waiter] = []
    private var registeredWaiterIDs: Set<UUID> = []
    private var cancelledWaiterIDs: Set<UUID> = []

    func acquire(generation: UInt64) async -> PersistenceCommitLease? {
        let waiterID = UUID()
        _ = lock.withLock {
            registeredWaiterIDs.insert(waiterID)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueueOrAcquire(
                    waiterID: waiterID,
                    generation: generation,
                    continuation: continuation
                )
            }
        } onCancel: {
            self.cancelWaiter(id: waiterID)
        }
    }

    func tryAcquireImmediately(generation: UInt64) -> PersistenceCommitLease? {
        lock.withLock {
            guard generation > supersessionBarrierGeneration,
                  activeLease == nil else {
                return nil
            }
            let lease = PersistenceCommitLease(id: UUID(), generation: generation)
            activeLease = lease
            return lease
        }
    }

    func release(_ lease: PersistenceCommitLease, outcome: PersistenceCommitOutcome) {
        var resumptions: [(CheckedContinuation<PersistenceCommitLease?, Never>, PersistenceCommitLease?)] = []
        lock.lock()
        guard activeLease == lease else {
            lock.unlock()
            return
        }
        switch outcome {
        case .abortedBeforeWrite:
            break
        case .committed, .failedAfterWrite:
            supersessionBarrierGeneration = max(
                supersessionBarrierGeneration,
                lease.generation
            )
        }
        activeLease = nil

        var remainingWaiters: [Waiter] = []
        for waiter in waiters {
            if waiter.generation <= supersessionBarrierGeneration {
                resumptions.append((waiter.continuation, nil))
            } else {
                remainingWaiters.append(waiter)
            }
        }
        waiters = remainingWaiters

        if let nextIndex = waiters.indices.max(
            by: { waiters[$0].generation < waiters[$1].generation }
        ) {
            let next = waiters.remove(at: nextIndex)
            let nextLease = PersistenceCommitLease(id: next.id, generation: next.generation)
            activeLease = nextLease
            resumptions.append((next.continuation, nextLease))
        }
        lock.unlock()

        for (continuation, result) in resumptions {
            continuation.resume(returning: result)
        }
    }

    private func enqueueOrAcquire(
        waiterID: UUID,
        generation: UInt64,
        continuation: CheckedContinuation<PersistenceCommitLease?, Never>
    ) {
        var immediateResult: PersistenceCommitLease??
        lock.lock()
        registeredWaiterIDs.remove(waiterID)
        if cancelledWaiterIDs.remove(waiterID) != nil {
            immediateResult = .some(nil)
        } else if generation <= supersessionBarrierGeneration {
            immediateResult = .some(nil)
        } else if activeLease == nil {
            let lease = PersistenceCommitLease(id: waiterID, generation: generation)
            activeLease = lease
            immediateResult = .some(lease)
        } else {
            waiters.append(
                Waiter(
                    id: waiterID,
                    generation: generation,
                    continuation: continuation
                )
            )
        }
        lock.unlock()

        if let immediateResult {
            continuation.resume(returning: immediateResult)
        }
    }

    private func cancelWaiter(id: UUID) {
        var continuation: CheckedContinuation<PersistenceCommitLease?, Never>?
        lock.lock()
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            continuation = waiters.remove(at: index).continuation
        } else if registeredWaiterIDs.contains(id) {
            cancelledWaiterIDs.insert(id)
        }
        lock.unlock()
        continuation?.resume(returning: nil)
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

    func updateMetadata(from snapshot: PasteBuddySnapshot) throws {
        try repository.updateMetadata(from: snapshot)
    }

    func applyCaptureJournal(
        _ journal: ClipboardRepositoryCaptureJournal,
        metadataFrom snapshot: PasteBuddySnapshot? = nil
    ) throws {
        try repository.applyCaptureJournal(journal, metadataFrom: snapshot)
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

    public func hydrateAssets(for items: [ClipboardItem]) throws -> [ClipboardItem] {
        try repository.hydrateAssets(for: items)
    }

    public func imageData(for item: ClipboardItem) throws -> Data? {
        try repository.imageData(for: item)
    }

    public func rtfData(for item: ClipboardItem) throws -> Data? {
        try repository.rtfData(for: item)
    }

    public func hasStoredSnapshot() throws -> Bool {
        try repository.hasStoredSnapshot()
    }

    func currentRevisionForAuthority() throws -> UUID? {
        try repository.currentRevisionForAuthority()
    }

    func eraseSensitiveContent() throws {
        try repository.eraseSensitiveContent()
    }

    public func exportSnapshot(hydrateAssets: Bool = true) throws -> PasteBuddySnapshot {
        try repository.exportSnapshot(hydrateAssets: hydrateAssets)
    }
}
