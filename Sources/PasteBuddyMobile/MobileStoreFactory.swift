import Foundation
import PasteBuddyCore

public enum MobileStoreFactory {
    public static let defaultAppGroupIdentifier = "group.com.alexjiang.PasteBuddy"

    public static func appGroupDefaults(
        appGroupIdentifier: String = defaultAppGroupIdentifier
    ) -> UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    @MainActor
    public static func makeStore(
        appGroupIdentifier: String = defaultAppGroupIdentifier,
        fallbackToDefaultStore: Bool = true
    ) -> PasteBuddyStore {
        do {
            let diskStore = try EncryptedSnapshotStore.appGroupStore(groupIdentifier: appGroupIdentifier)
            return PasteBuddyStore(diskStore: diskStore)
        } catch {
            guard fallbackToDefaultStore else {
                return PasteBuddyStore()
            }
            return PasteBuddyStore()
        }
    }

    @MainActor
    public static func makeIrohSyncService(
        appGroupIdentifier: String = defaultAppGroupIdentifier
    ) -> IrohClipboardSyncService {
        IrohClipboardSyncService(defaults: appGroupDefaults(appGroupIdentifier: appGroupIdentifier))
    }
}
