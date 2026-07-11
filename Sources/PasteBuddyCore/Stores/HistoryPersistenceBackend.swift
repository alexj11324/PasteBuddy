import Foundation

struct HistoryPersistenceLoadResult: Sendable {
    var snapshot: PasteBuddySnapshot
    var loadedStorageMode: SnapshotStorageMode
}

enum HistoryPersistenceMutationPlan: Sendable {
    case none
    case synchronize
    case capture(ClipboardRepositoryCaptureJournal, includeMetadata: Bool)
    case metadata
}

protocol HistoryPersistenceBackend: Actor {
    func load() throws -> HistoryPersistenceLoadResult
    func commit(
        _ snapshot: PasteBuddySnapshot,
        plan: HistoryPersistenceMutationPlan,
        generation: UInt64
    ) throws -> Bool
    func flush() throws
    func eraseSensitiveData() throws
}
