import Foundation
import PasteBuddyCore

public enum MobileStoreFactoryError: LocalizedError, Equatable {
    case appGroupDefaultsUnavailable

    public var errorDescription: String? {
        PasteBuddyPersistenceError.historyUnavailable.localizedDescription
    }
}

public enum MobileStoreFactory {
    public static let defaultAppGroupIdentifier = "group.com.alexjiang.PasteBuddy"
    public static let defaultKeychainAccessGroup = "72UN4PF4BL.com.alexjiang.PasteBuddy.shared"
    public static let persistenceDebounceNanoseconds: UInt64 = 350_000_000

    public static func appGroupDefaults(
        appGroupIdentifier: String = defaultAppGroupIdentifier
    ) throws -> UserDefaults {
        try appGroupDefaults(
            appGroupIdentifier: appGroupIdentifier,
            suiteResolver: UserDefaults.init(suiteName:)
        )
    }

    static func appGroupDefaults(
        appGroupIdentifier: String,
        suiteResolver: (String) -> UserDefaults?
    ) throws -> UserDefaults {
        guard let defaults = suiteResolver(appGroupIdentifier) else {
            throw MobileStoreFactoryError.appGroupDefaultsUnavailable
        }
        return defaults
    }

    @MainActor
    public static func makeStore(
        appGroupIdentifier: String = defaultAppGroupIdentifier
    ) throws -> PasteBuddyStore {
        try makeStore(
            appGroupIdentifier: appGroupIdentifier,
            appGroupStore: { groupIdentifier, keychainAccessGroup in
                try EncryptedSnapshotStore.appGroupStore(
                    groupIdentifier: groupIdentifier,
                    keychainAccessGroup: keychainAccessGroup
                )
            }
        )
    }

    @MainActor
    static func makeStore(
        appGroupIdentifier: String,
        appGroupStore: (String, String) throws -> EncryptedSnapshotStore
    ) throws -> PasteBuddyStore {
        let diskStore = try appGroupStore(appGroupIdentifier, defaultKeychainAccessGroup)
        return PasteBuddyStore(
            diskStore: diskStore,
            saveDebounceNanoseconds: persistenceDebounceNanoseconds
        )
    }

    @MainActor
    public static func makeIrohSyncService(
        appGroupIdentifier: String = defaultAppGroupIdentifier
    ) throws -> IrohClipboardSyncService {
        try makeIrohSyncService(
            appGroupIdentifier: appGroupIdentifier,
            suiteResolver: UserDefaults.init(suiteName:)
        )
    }

    @MainActor
    static func makeIrohSyncService(
        appGroupIdentifier: String,
        suiteResolver: (String) -> UserDefaults?
    ) throws -> IrohClipboardSyncService {
        IrohClipboardSyncService(
            defaults: try appGroupDefaults(
                appGroupIdentifier: appGroupIdentifier,
                suiteResolver: suiteResolver
            ),
            identityStore: IrohClipboardIdentityStore(accessGroup: defaultKeychainAccessGroup)
        )
    }
}
