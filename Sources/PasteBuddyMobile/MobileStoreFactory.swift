import Foundation
import PasteBuddyCore

public enum MobileStoreFactory {
    public static let defaultAppGroupIdentifier = "group.com.alexjiang.PasteBuddy"

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
}
