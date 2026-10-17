import PasteBuddyCore
import PasteBuddyMobile
import SwiftUI

@main
struct PasteBuddyiOSApp: App {
    @State private var store: PasteBuddyStore
    @State private var cloudSync = CloudKitClipboardSyncSession()

    init() {
        let resolvedStore = MobileStoreFactory.makeStore()
        resolvedStore.load()
        _store = State(initialValue: resolvedStore)
    }

    var body: some Scene {
        WindowGroup {
            MobileClipboardBrowserView(store: store) {
                cloudSync.update(store: store)
            }
                .task {
                    cloudSync.update(store: store)
                }
        }
    }
}
