import Foundation
import Security
@testable import PasteBuddyCore
import XCTest

private final class CleanupAttemptCounter: @unchecked Sendable {
    var value = 0
}

@MainActor
final class LegacyClipboardPairingResidueCleanupTests: XCTestCase {
    func testCleanupRemovesPeerEndpointFromProcessAndGroupDefaultsOnce() {
        let processSuite = "pastebuddy.tests.legacy-pairing.process.\(UUID().uuidString)"
        let groupSuite = "pastebuddy.tests.legacy-pairing.group.\(UUID().uuidString)"
        let processDefaults = UserDefaults(suiteName: processSuite)!
        let groupDefaults = UserDefaults(suiteName: groupSuite)!
        defer {
            processDefaults.removePersistentDomain(forName: processSuite)
            groupDefaults.removePersistentDomain(forName: groupSuite)
        }

        let service = "pastebuddy.tests.legacy-pairing.\(UUID().uuidString)"
        processDefaults.set(
            "endpoint-should-disappear",
            forKey: LegacyClipboardPairingResidueCleanup.peerEndpointDefaultsKey
        )
        groupDefaults.set(
            "group-endpoint-should-disappear",
            forKey: LegacyClipboardPairingResidueCleanup.peerEndpointDefaultsKey
        )
        processDefaults.set("keep-me", forKey: "pastebuddy.tests.unrelated")

        LegacyClipboardPairingResidueCleanup.removeLeftoverStateIfNeeded(
            processDefaults: processDefaults,
            additionalDefaults: [groupDefaults],
            keychainService: service,
            keychainAccount: LegacyClipboardPairingResidueCleanup.keychainAccount,
            deleteKeychain: { _, _ in true }
        )

        XCTAssertNil(processDefaults.string(forKey: LegacyClipboardPairingResidueCleanup.peerEndpointDefaultsKey))
        XCTAssertNil(groupDefaults.string(forKey: LegacyClipboardPairingResidueCleanup.peerEndpointDefaultsKey))
        XCTAssertEqual(processDefaults.string(forKey: "pastebuddy.tests.unrelated"), "keep-me")
        XCTAssertTrue(processDefaults.bool(forKey: LegacyClipboardPairingResidueCleanup.completionDefaultsKey))

        processDefaults.set(
            "planted-after-cleanup",
            forKey: LegacyClipboardPairingResidueCleanup.peerEndpointDefaultsKey
        )
        LegacyClipboardPairingResidueCleanup.removeLeftoverStateIfNeeded(
            processDefaults: processDefaults,
            additionalDefaults: [groupDefaults],
            keychainService: service,
            keychainAccount: LegacyClipboardPairingResidueCleanup.keychainAccount
        )
        XCTAssertEqual(
            processDefaults.string(forKey: LegacyClipboardPairingResidueCleanup.peerEndpointDefaultsKey),
            "planted-after-cleanup"
        )
    }

    func testCleanupRetriesWhenKeychainDeleteFails() {
        let suiteName = "pastebuddy.tests.legacy-pairing.retry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("endpoint-should-disappear", forKey: LegacyClipboardPairingResidueCleanup.peerEndpointDefaultsKey)

        LegacyClipboardPairingResidueCleanup.removeLeftoverStateIfNeeded(
            processDefaults: defaults,
            additionalDefaults: [],
            keychainService: "unused-service",
            keychainAccount: "unused-account",
            deleteKeychain: { _, _ in false }
        )

        XCTAssertNil(defaults.string(forKey: LegacyClipboardPairingResidueCleanup.peerEndpointDefaultsKey))
        XCTAssertFalse(defaults.bool(forKey: LegacyClipboardPairingResidueCleanup.completionDefaultsKey))

        let attempts = CleanupAttemptCounter()
        LegacyClipboardPairingResidueCleanup.removeLeftoverStateIfNeeded(
            processDefaults: defaults,
            additionalDefaults: [],
            keychainService: "unused-service",
            keychainAccount: "unused-account",
            deleteKeychain: { _, _ in
                attempts.value += 1
                return true
            }
        )

        XCTAssertEqual(attempts.value, 1)
        XCTAssertTrue(defaults.bool(forKey: LegacyClipboardPairingResidueCleanup.completionDefaultsKey))
    }

    func testCleanupDeletesGenericPassword() throws {
        let suiteName = "pastebuddy.tests.legacy-pairing.keychain.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let service = "pastebuddy.tests.legacy-pairing.\(UUID().uuidString)"
        let account = LegacyClipboardPairingResidueCleanup.keychainAccount
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ] as CFDictionary)
        }

        let secret = Data("retired-pairing-secret".utf8)
        let addStatus = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: secret
        ] as CFDictionary, nil)
        try XCTSkipUnless(addStatus == errSecSuccess, "Keychain is unavailable (\(addStatus)).")

        defaults.set("paired-endpoint", forKey: LegacyClipboardPairingResidueCleanup.peerEndpointDefaultsKey)
        LegacyClipboardPairingResidueCleanup.removeLeftoverStateIfNeeded(
            processDefaults: defaults,
            additionalDefaults: [],
            keychainService: service,
            keychainAccount: account
        )

        XCTAssertNil(defaults.string(forKey: LegacyClipboardPairingResidueCleanup.peerEndpointDefaultsKey))
        XCTAssertTrue(defaults.bool(forKey: LegacyClipboardPairingResidueCleanup.completionDefaultsKey))
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ] as CFDictionary, &item)
        XCTAssertEqual(status, errSecItemNotFound)

        XCTAssertEqual(LegacyClipboardPairingResidueCleanup.keychainService, "com.alexjiang.PasteBuddy.iroh")
        XCTAssertEqual(LegacyClipboardPairingResidueCleanup.keychainAccount, "clipboard-sync-secret-key")
        XCTAssertEqual(
            LegacyClipboardPairingResidueCleanup.peerEndpointDefaultsKey,
            "pastebuddy.iroh.peerEndpointId"
        )
        XCTAssertEqual(
            LegacyClipboardPairingResidueCleanup.appGroupSuiteName,
            "group.com.alexjiang.PasteBuddy"
        )
    }
}
