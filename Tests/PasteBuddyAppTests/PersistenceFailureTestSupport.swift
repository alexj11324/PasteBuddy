import Foundation
import PasteBuddyCore
@testable import PasteBuddy

@MainActor
final class ShelfReloadFailureProbe {
    var runtimeState: PasteBuddyRuntimeState = .ready
    var refreshCount = 0
    var loadingPreparationCount = 0
}

@MainActor
struct PersistenceFailureTestFixture {
    let directory: URL
    let store: PasteBuddyStore
    let snapshotItemIDsBeforeFailure: [UUID]
    let snapshotPinboardIDsBeforeFailure: [UUID]
    let diskBytesBeforeFailure: Data

    static func make() async throws -> PersistenceFailureTestFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasteBuddyPersistenceFailureTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("clipboard.pbstore")
        let diskStore = EncryptedSnapshotStore(
            fileURL: fileURL,
            storageMode: .standard
        )
        let persistedItem = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Persisted history",
            payload: ClipboardPayload(text: "must remain unchanged")
        )
        try diskStore.save(PasteBuddySnapshot(items: [persistedItem]))
        let store = PasteBuddyStore(diskStore: diskStore)
        try await PasteBuddyStoreFactory.load(store)

        let corruptedBytes = Data("corrupted persisted history".utf8)
        try corruptedBytes.write(to: fileURL, options: .atomic)

        return PersistenceFailureTestFixture(
            directory: directory,
            store: store,
            snapshotItemIDsBeforeFailure: store.snapshot.items.map(\.id),
            snapshotPinboardIDsBeforeFailure: store.snapshot.pinboards.map(\.id),
            diskBytesBeforeFailure: corruptedBytes
        )
    }

    var fileURL: URL {
        directory.appendingPathComponent("clipboard.pbstore")
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
