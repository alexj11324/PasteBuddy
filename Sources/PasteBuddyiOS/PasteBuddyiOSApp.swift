import PasteBuddyCore
import PasteBuddyMobile
import SwiftUI

@main
struct PasteBuddyiOSApp: App {
    @State private var store: PasteBuddyStore
    @State private var irohSync: IrohClipboardSyncService

    init() {
        let resolvedStore = MobileStoreFactory.makeStore()
        resolvedStore.load()
        _store = State(initialValue: resolvedStore)
        _irohSync = State(initialValue: MobileStoreFactory.makeIrohSyncService())
    }

    var body: some Scene {
        WindowGroup {
            MobileClipboardBrowserView(store: store, irohSync: irohSync)
                .task {
                    irohSync.onItemReceived = { [store] item in
                        guard let storedItem = store.addSyncedItem(item) else { return }
                        MobilePasteboardWriter.copy(storedItem)
                    }
                    await irohSync.start()
                }
        }
    }
}
