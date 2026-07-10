import Foundation
import PasteBuddyCore

public enum MobileStoreFactory {
    public static let defaultAppGroupIdentifier = "group.com.alexjiang.PasteBuddy"
    public static let defaultKeychainAccessGroup = "72UN4PF4BL.com.alexjiang.PasteBuddy.shared"
    public static let persistenceDebounceNanoseconds: UInt64 = 350_000_000

    public static func appGroupDefaults(
        appGroupIdentifier: String = defaultAppGroupIdentifier
    ) -> UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    @MainActor
    public static func makeStore(
        appGroupIdentifier: String = defaultAppGroupIdentifier
    ) throws -> PasteBuddyStore {
        let diskStore = try EncryptedSnapshotStore.appGroupStore(
            groupIdentifier: appGroupIdentifier,
            keychainAccessGroup: defaultKeychainAccessGroup
        )
        return PasteBuddyStore(
            diskStore: diskStore,
            saveDebounceNanoseconds: persistenceDebounceNanoseconds
        )
    }

    @MainActor
    public static func makeIrohSyncService(
        appGroupIdentifier: String = defaultAppGroupIdentifier
    ) -> IrohClipboardSyncService {
        IrohClipboardSyncService(
            defaults: appGroupDefaults(appGroupIdentifier: appGroupIdentifier),
            identityStore: IrohClipboardIdentityStore(accessGroup: defaultKeychainAccessGroup)
        )
    }
}
