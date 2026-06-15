import PasteBuddyCore
import PasteBuddyMobile
import SwiftUI

@main
struct PasteBuddyiOSApp: App {
    @State private var store: PasteBuddyStore

    init() {
        let resolvedStore = MobileStoreFactory.makeStore()
        resolvedStore.load()
        _store = State(initialValue: resolvedStore)
    }

    var body: some Scene {
        WindowGroup {
            MobileClipboardBrowserView(store: store)
        }
    }
}
