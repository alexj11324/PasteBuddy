import Foundation
import Security

/// Deletes pairing state left by the removed clipboard transport.
///
/// Upgraded installs can still have a generic-password item whose service is
/// `com.alexjiang.PasteBuddy.iroh` and account is `clipboard-sync-secret-key`,
/// plus `pastebuddy.iroh.peerEndpointId` in standard defaults (macOS) or the
/// shared app-group defaults (iOS and extensions). Each process has its own
/// default keychain, so every former participant runs this once.
@MainActor
public enum LegacyClipboardPairingResidueCleanup {
    public static let peerEndpointDefaultsKey = "pastebuddy.iroh.peerEndpointId"
    public static let keychainService = "com.alexjiang.PasteBuddy.iroh"
    public static let keychainAccount = "clipboard-sync-secret-key"
    public static let appGroupSuiteName = "group.com.alexjiang.PasteBuddy"
    public static let completionDefaultsKey = "pastebuddy.legacyClipboardPairingResidueCleared"

    public static func removeLeftoverStateIfNeeded(
        processDefaults: UserDefaults = .standard,
        additionalDefaults: [UserDefaults]? = nil,
        keychainService: String = keychainService,
        keychainAccount: String = keychainAccount,
        deleteKeychain: (@MainActor (String, String) -> Bool)? = nil
    ) {
        guard processDefaults.bool(forKey: completionDefaultsKey) == false else {
            return
        }

        let keychainCleared = deleteKeychain?(keychainService, keychainAccount)
            ?? deleteKeychainItem(service: keychainService, account: keychainAccount)
        let stores = additionalDefaults ?? defaultAdditionalDefaults(excluding: processDefaults)
        removePeerEndpoint(from: processDefaults)
        for store in stores {
            removePeerEndpoint(from: store)
        }
        guard keychainCleared else { return }
        processDefaults.set(true, forKey: completionDefaultsKey)
    }

    public static func deleteKeychainItem(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func defaultAdditionalDefaults(excluding processDefaults: UserDefaults) -> [UserDefaults] {
        guard let suite = UserDefaults(suiteName: appGroupSuiteName), suite !== processDefaults else {
            return []
        }
        return [suite]
    }

    private static func removePeerEndpoint(from defaults: UserDefaults) {
        guard defaults.object(forKey: peerEndpointDefaultsKey) != nil else { return }
        defaults.removeObject(forKey: peerEndpointDefaultsKey)
    }
}
