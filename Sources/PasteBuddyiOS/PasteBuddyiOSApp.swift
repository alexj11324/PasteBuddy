import PasteBuddyCore
import PasteBuddyMobile
import SwiftUI

@main
struct PasteBuddyiOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: PasteBuddyStore?
    @State private var irohSync: IrohClipboardSyncService
    @State private var isStoreLoaded = false
    @State private var storeLoadErrorMessage: String?

    init() {
        do {
            let resolvedStore = try MobileStoreFactory.makeStore()
            _store = State(initialValue: resolvedStore)
            _storeLoadErrorMessage = State(initialValue: nil)
        } catch {
            _store = State(initialValue: nil)
            _storeLoadErrorMessage = State(initialValue: error.localizedDescription)
        }
        _irohSync = State(initialValue: MobileStoreFactory.makeIrohSyncService())
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let storeLoadErrorMessage {
                    ContentUnavailableView(
                        "mobile.error.history_unavailable_title",
                        systemImage: "exclamationmark.lock",
                        description: Text(storeLoadErrorMessage)
                    )
                } else if isStoreLoaded, let store {
                    MobileClipboardBrowserView(store: store, irohSync: irohSync)
                } else {
                    ProgressView()
                }
            }
            .task {
                guard !isStoreLoaded, storeLoadErrorMessage == nil, let store else { return }
                await store.loadAsync()
                guard !store.isPersistenceWriteBlocked else {
                    storeLoadErrorMessage = store.lastErrorMessage
                        ?? PasteBuddyLocalization.string(
                            "mobile.error.history_load_failed",
                            defaultValue: "PasteBuddy could not load encrypted history."
                        )
                    return
                }
                irohSync.onItemReceived = { [store, weak irohSync] item in
                    guard !store.isPersistenceWriteBlocked else { return }
                    guard let storedItem = store.addSyncedItem(item) else { return }
                    do {
                        try await store.flushPendingSaveOrThrow()
                    } catch {
                        irohSync?.reportReceivePersistenceFailure(error)
                        storeLoadErrorMessage = error.localizedDescription
                        return
                    }
                    MobilePasteboardWriter.copy(storedItem)
                }
                isStoreLoaded = true
                await irohSync.start()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase != .active, let store else { return }
                Task { @MainActor in
                    do {
                        try await store.flushPendingSaveOrThrow()
                    } catch {
                        storeLoadErrorMessage = error.localizedDescription
                    }
                }
            }
        }
    }
}
