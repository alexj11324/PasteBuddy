import Foundation
import XCTest
@testable import PasteBuddyCore

extension PasteBuddyStoreTests {
    func testDefaultStoreFactoryFailsClosedWhenApplicationSupportCannotBeResolved() {
        var diagnosticReasons: [PasteBuddyStoreFactory.FailureReason] = []

        XCTAssertThrowsError(
            try PasteBuddyStoreFactory.makeDefault(
                applicationSupportDirectoryResolver: {
                    throw StoreFactoryProbeError.sensitive("/Users/example/Library/Application Support")
                },
                databaseURLResolver: { _ in
                    XCTFail("Database resolution must not run after snapshot location failure.")
                    return URL(fileURLWithPath: "/unused/clipboard.sqlite")
                },
                diagnostics: { diagnosticReasons.append($0) }
            )
        ) { error in
            XCTAssertEqual(error as? PasteBuddyPersistenceError, .historyUnavailable)
            XCTAssertEqual(error.localizedDescription, PasteBuddyPersistenceError.historyUnavailable.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains("/Users/example"))
        }
        XCTAssertEqual(diagnosticReasons, [.applicationSupportDirectoryUnavailable])
    }

    func testDefaultStoreFactoryIsolatesStableDevelopmentIdentityFromProductionStorage() {
        let applicationSupportRoot = URL(
            fileURLWithPath: "/Users/example/Library/Application Support",
            isDirectory: true
        )

        XCTAssertEqual(
            PasteBuddyStoreFactory.persistenceContainerURL(
                in: applicationSupportRoot,
                bundleIdentifier: "com.alexjiang.PasteBuddy.dev"
            ),
            applicationSupportRoot.appendingPathComponent("PasteBuddy Dev", isDirectory: true)
        )
        XCTAssertEqual(
            PasteBuddyStoreFactory.persistenceContainerURL(
                in: applicationSupportRoot,
                bundleIdentifier: "com.alexjiang.PasteBuddy"
            ),
            applicationSupportRoot.appendingPathComponent("PasteBuddy", isDirectory: true)
        )
        XCTAssertEqual(
            PasteBuddyStoreFactory.persistenceContainerURL(
                in: applicationSupportRoot,
                bundleIdentifier: "com.alexjiang.PasteBuddy.dev.preview"
            ),
            applicationSupportRoot.appendingPathComponent("PasteBuddy", isDirectory: true)
        )
        XCTAssertEqual(
            PasteBuddyStoreFactory.persistenceContainerURL(
                in: applicationSupportRoot,
                bundleIdentifier: nil
            ),
            applicationSupportRoot.appendingPathComponent("PasteBuddy", isDirectory: true)
        )

        let developmentContainer = applicationSupportRoot.appendingPathComponent(
            "PasteBuddy Dev",
            isDirectory: true
        )
        XCTAssertEqual(
            PasteBuddyDatabase.defaultDatabaseURL(in: developmentContainer),
            developmentContainer.appendingPathComponent("clipboard.sqlite")
        )
    }

    func testDefaultStoreFactoryFailsClosedWhenDatabaseURLCannotBeResolved() {
        var diagnosticReasons: [PasteBuddyStoreFactory.FailureReason] = []

        XCTAssertThrowsError(
            try PasteBuddyStoreFactory.makeDefault(
                applicationSupportDirectoryResolver: {
                    URL(fileURLWithPath: "/unused/Application Support", isDirectory: true)
                },
                databaseURLResolver: { persistenceContainerURL in
                    XCTAssertEqual(
                        persistenceContainerURL,
                        URL(fileURLWithPath: "/unused/Application Support/PasteBuddy", isDirectory: true)
                    )
                    throw StoreFactoryProbeError.sensitive("/Users/example/Library/Application Support/PasteBuddy/clipboard.sqlite")
                },
                diagnostics: { diagnosticReasons.append($0) }
            )
        ) { error in
            XCTAssertEqual(error as? PasteBuddyPersistenceError, .historyUnavailable)
            XCTAssertEqual(error.localizedDescription, PasteBuddyPersistenceError.historyUnavailable.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains("clipboard.sqlite"))
        }
        XCTAssertEqual(diagnosticReasons, [.databaseURLUnavailable])
    }

    func testClipboardCollectionIDsHaveStableStringIDsAndLegacyGeneralConfigurationDecodes() throws {
        let pinboardID = try XCTUnwrap(UUID(uuidString: "10000000-2000-3000-4000-500000000000"))

        XCTAssertEqual(ClipboardCollectionID.history.id, "history")
        XCTAssertEqual(ClipboardCollectionID.pasteStack.id, "pasteStack")
        XCTAssertEqual(ClipboardCollectionID.smart(.links).id, "smart:links")
        XCTAssertEqual(ClipboardCollectionID.pinboard(pinboardID).id, "pinboard:\(pinboardID.uuidString)")

        let legacyData = Data(#"{"launchAtLoginEnabled":true}"#.utf8)
        let decoded = try JSONDecoder().decode(GeneralConfiguration.self, from: legacyData)

        XCTAssertTrue(decoded.launchAtLoginEnabled)
        XCTAssertNil(decoded.collectionOrder)
    }

    func testStorageSettingsPersistThroughEncryptedStore() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.updateMaxHistoryItems(250)
        store.updateRetentionDays(14)
        store.updateMaxStorageBytes(256 * 1_024 * 1_024)

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertEqual(reloaded.snapshot.storage.maxHistoryItems, 250)
        XCTAssertEqual(reloaded.snapshot.storage.retentionDays, 14)
        XCTAssertEqual(reloaded.snapshot.storage.maxStorageBytes, 256 * 1_024 * 1_024)
    }

    func testGeneralSettingsPersistThroughEncryptedStore() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.setLaunchAtLoginEnabled(true, applySystemRegistration: false)

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertTrue(reloaded.snapshot.general.launchAtLoginEnabled)

        reloaded.setLaunchAtLoginEnabled(false, applySystemRegistration: false)

        XCTAssertFalse(reloaded.snapshot.general.launchAtLoginEnabled)
    }

    func testMacMenuBarStatusReflectsCapturePauseState() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        var status = store.macMenuBarStatus

        XCTAssertEqual(status.title, "PasteBuddy Active")
        XCTAssertEqual(status.systemImageName, "doc.on.clipboard")

        store.pauseCaptureIndefinitely()
        status = store.macMenuBarStatus

        XCTAssertEqual(status.title, "PasteBuddy Paused")
        XCTAssertEqual(status.systemImageName, "pause.circle.fill")

        store.requestSettingsDestination(.privacy)
        XCTAssertEqual(store.requestedSettingsDestination, .privacy)
        store.clearRequestedSettingsDestination()
        XCTAssertNil(store.requestedSettingsDestination)
    }

    func testPastePlainTextDefaultPersistsThroughEncryptedStore() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        XCTAssertEqual(store.defaultPasteFormat, .original)

        store.setAlwaysPasteAsPlainText(true)

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertTrue(reloaded.snapshot.paste.alwaysPasteAsPlainText)
        XCTAssertEqual(reloaded.defaultPasteFormat, .plainText)
    }

    func testDirectPasteResultIsTransientUIState() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let result = DirectPasteResult(
            outcome: .copiedOnlyAccessibilityRequired,
            itemCount: 2,
            format: .plainText,
            occurredAt: Date(timeIntervalSince1970: 10)
        )

        store.recordDirectPasteResult(result)

        XCTAssertEqual(store.lastDirectPasteResult, result)
        XCTAssertTrue(store.lastDirectPasteResult?.statusMessage.contains("Grant Accessibility access") ?? false)
        let guidance = try XCTUnwrap(store.lastDirectPasteResult?.permissionGuidance)
        XCTAssertEqual(guidance.actionTitle, "Request Accessibility Access")
        XCTAssertTrue(guidance.detail.contains("copied your selection"))
        XCTAssertTrue(guidance.detail.contains("Command-V"))

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertNil(reloaded.lastDirectPasteResult)

        store.clearDirectPasteResult()

        XCTAssertNil(store.lastDirectPasteResult)
    }

    func testShortcutConfigurationPersistsAndResets() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        XCTAssertEqual(store.snapshot.shortcuts.quickPasteDisplayName, "⌥⌘1-9")
        XCTAssertEqual(store.snapshot.shortcuts.plainTextQuickPasteDisplayName, "⌃⌥⌘1-9")

        store.setQuickPasteShortcutsEnabled(false)

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertFalse(reloaded.snapshot.shortcuts.isQuickPasteEnabled)

        reloaded.resetShortcutConfiguration()

        XCTAssertTrue(reloaded.snapshot.shortcuts.isQuickPasteEnabled)
        XCTAssertEqual(reloaded.snapshot.shortcuts.showHidePanel.displayName, "⇧⌘V")
    }

    func testShortcutCustomizationPersistsAndSupportsClearedBindings() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)

        store.setShortcutBinding(
            .pasteSelectedItem,
            key: "p",
            modifiers: [.shift, .command, .command]
        )
        store.clearShortcutBinding(.pasteSelectedPlainText)
        store.setQuickPasteModifiers([.control, .command])
        store.setQuickPasteModifiers([.shift], plainText: true)

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertEqual(reloaded.snapshot.shortcuts.pasteSelectedItem.key, "p")
        XCTAssertEqual(reloaded.snapshot.shortcuts.pasteSelectedItem.modifiers, [.shift, .command])
        XCTAssertEqual(reloaded.snapshot.shortcuts.pasteSelectedItem.displayName, "⇧⌘P")
        XCTAssertFalse(reloaded.snapshot.shortcuts.pasteSelectedPlainText.isEnabled)
        XCTAssertEqual(reloaded.snapshot.shortcuts.pasteSelectedPlainText.displayName, "Not set")
        XCTAssertEqual(reloaded.snapshot.shortcuts.quickPasteModifiers, [.control, .command])
        XCTAssertEqual(reloaded.snapshot.shortcuts.plainTextQuickPasteModifiers, [.shift])
    }

    func testShortcutBindingNormalizesWhitespaceKeyAndModifierOrder() {
        let binding = ShortcutBinding(
            key: "  Return  ",
            modifiers: [.shift, .command, .option, .command]
        )

        XCTAssertEqual(binding.key, "r")
        XCTAssertEqual(binding.modifiers, [.option, .shift, .command])
        XCTAssertEqual(binding.displayName, "⌥⇧⌘R")

        var legacyOrderedBinding = ShortcutBinding(key: "v", modifiers: [])
        legacyOrderedBinding.modifiers = [.command, .shift]
        XCTAssertEqual(legacyOrderedBinding.displayName, "⇧⌘V")

        let cleared = ShortcutBinding(key: "   ", modifiers: [.control])

        XCTAssertNil(cleared.key)
        XCTAssertFalse(cleared.isEnabled)
        XCTAssertEqual(cleared.displayName, "Not set")
    }

    func testFreeTrialLifecyclePersistsThroughEncryptedStore() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let now = Date(timeIntervalSince1970: 1_000)

        store.startFreeTrial(days: 14, now: now)

        XCTAssertEqual(store.snapshot.entitlement.plan, .trial)
        XCTAssertEqual(store.snapshot.entitlement.status, .trialing)
        XCTAssertTrue(store.snapshot.entitlement.isTrialActive(now: now.addingTimeInterval(60)))
        XCTAssertTrue(store.snapshot.entitlement.hasFullAccess(now: now.addingTimeInterval(60)))
        let activeOverview = store.snapshot.entitlement.personalOverview(now: now.addingTimeInterval(60))
        XCTAssertEqual(activeOverview.trialState, .active)
        XCTAssertTrue(activeOverview.trialSummary.contains("14 days remaining"))
        XCTAssertTrue(activeOverview.trialOutcomeStatement.contains("When the trial ends"))
        XCTAssertTrue(activeOverview.trialOutcomeStatement.contains("limited mode"))
        XCTAssertTrue(activeOverview.crossDeviceStatement.contains("Mac, iPhone, and iPad"))
        XCTAssertEqual(activeOverview.purchaseOptions.map(\.plan), [.monthly, .annual, .lifetime, .family])
        XCTAssertTrue(activeOverview.billingSafetyStatement.contains("Payment details stay with the App Store"))

        let endingSoonOverview = store.snapshot.entitlement.personalOverview(now: now.addingTimeInterval(12 * 24 * 60 * 60))
        XCTAssertEqual(endingSoonOverview.trialState, .endingSoon)

        let endedOverview = store.snapshot.entitlement.personalOverview(now: now.addingTimeInterval(15 * 24 * 60 * 60))
        XCTAssertEqual(endedOverview.trialState, .ended)
        XCTAssertTrue(endedOverview.trialSummary.contains("Trial ended"))
        XCTAssertTrue(endedOverview.trialOutcomeStatement.contains("do not delete local clipboard data"))

        store.cancelFreeTrial(now: now.addingTimeInterval(120))

        XCTAssertEqual(store.snapshot.entitlement.status, .canceled)
        XCTAssertFalse(store.snapshot.entitlement.hasFullAccess(now: now.addingTimeInterval(180)))
        let canceledOverview = store.snapshot.entitlement.personalOverview(now: now.addingTimeInterval(180))
        XCTAssertEqual(canceledOverview.trialState, .canceled)
        XCTAssertTrue(canceledOverview.trialSummary.contains("Trial canceled"))

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertEqual(reloaded.snapshot.entitlement.plan, .trial)
        XCTAssertEqual(reloaded.snapshot.entitlement.status, .canceled)
        let trialCanceledAt = try XCTUnwrap(reloaded.snapshot.entitlement.trialCanceledAt)
        XCTAssertEqual(trialCanceledAt.timeIntervalSince1970, now.addingTimeInterval(120).timeIntervalSince1970, accuracy: 0.001)
    }

    func testPaidPlansUnlockAllDevicesAndCanExpire() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let now = Date()
        let renewal = now.addingTimeInterval(30 * 24 * 60 * 60)

        store.activatePersonalPlan(.monthly, purchasedAt: now, currentPeriodEndsAt: renewal)

        XCTAssertEqual(store.snapshot.entitlement.plan, .monthly)
        XCTAssertEqual(store.snapshot.entitlement.status, .active)
        XCTAssertTrue(store.snapshot.entitlement.unlocksAllDevicesForAccount)
        XCTAssertTrue(store.snapshot.entitlement.hasActivePaidAccess(now: now.addingTimeInterval(60)))
        let activeOverview = store.snapshot.entitlement.personalOverview(now: now.addingTimeInterval(60))
        XCTAssertEqual(activeOverview.accessState, "Unlocked")
        XCTAssertEqual(activeOverview.trialState, .converted)
        XCTAssertTrue(activeOverview.crossDeviceStatement.contains("same paid feature set"))
        XCTAssertTrue(activeOverview.crossDeviceStatement.contains("Mac, iPhone, and iPad"))

        store.markEntitlementExpired(at: now.addingTimeInterval(120))

        XCTAssertEqual(store.snapshot.entitlement.status, .expired)
        XCTAssertFalse(store.snapshot.entitlement.hasFullAccess(now: now.addingTimeInterval(180)))
        let expiredOverview = store.snapshot.entitlement.personalOverview(now: now.addingTimeInterval(180))
        XCTAssertEqual(expiredOverview.accessState, "Limited")
        XCTAssertTrue(expiredOverview.crossDeviceStatement.contains("No active paid entitlement"))
    }

    func testRestorePurchasesStatePersistsThroughEncryptedStore() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let startedAt = Date()
        let restoredAt = startedAt.addingTimeInterval(30)

        store.markRestorePurchasesStarted(at: startedAt)
        let restoringOverview = store.snapshot.entitlement.personalOverview(now: startedAt.addingTimeInterval(1))
        XCTAssertTrue(restoringOverview.restoreSummary.contains("checking StoreKit"))
        XCTAssertTrue(restoringOverview.restoreActionStatement.contains("verified active entitlement"))

        store.markRestorePurchasesRestored(at: restoredAt)

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        if case .restored(let date) = reloaded.snapshot.entitlement.restoreState {
            XCTAssertEqual(date.timeIntervalSince1970, restoredAt.timeIntervalSince1970, accuracy: 0.001)
        } else {
            XCTFail("Expected restored purchase state.")
        }

        let restoredOverview = reloaded.snapshot.entitlement.personalOverview(now: restoredAt.addingTimeInterval(1))
        XCTAssertTrue(restoredOverview.restoreSummary.contains("Restore completed"))
        XCTAssertTrue(restoredOverview.restoreActionStatement.contains("Mac, iPhone, or iPad") || restoredOverview.restoreActionStatement.contains("supported devices"))
    }

    func testSecuritySettingsToggleEncryptionAndTouchIDHistoryLock() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        harness.snapshotStore.storageMode = .standard
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            historyUnlockAuthenticator: FakeHistoryUnlockAuthenticator(result: true)
        )

        store.addCapturedItem(ClipboardItem(
            sourceAppName: "Unit Test",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Visible Secret",
            payload: ClipboardPayload(text: "clipboard content")
        ))

        XCTAssertEqual(store.snapshot.security.storageMode, .standard)
        XCTAssertFalse(store.snapshot.security.requiresBiometricUnlock)
        XCTAssertEqual(store.filteredItems.map(\.title), ["Visible Secret"])

        store.setBiometricHistoryLockEnabled(true)

        XCTAssertTrue(store.snapshot.security.requiresBiometricUnlock)
        XCTAssertTrue(store.isHistoryAccessLocked)
        XCTAssertTrue(store.filteredItems.isEmpty)
        XCTAssertEqual(store.historyAccessStatusLine, "History locked until Touch ID unlock")

        let didUnlock = await store.unlockHistoryWithTouchID()

        XCTAssertTrue(didUnlock)
        XCTAssertFalse(store.isHistoryAccessLocked)
        XCTAssertEqual(store.filteredItems.map(\.title), ["Visible Secret"])

        await store.setHistoryEncryptionEnabled(true)

        XCTAssertEqual(store.snapshot.security.storageMode, .encrypted)
        XCTAssertEqual(harness.snapshotStore.storageMode, .encrypted)
        let encryptedRaw = String(decoding: try Data(contentsOf: harness.snapshotStore.fileURL), as: UTF8.self)
        XCTAssertFalse(encryptedRaw.contains("Visible Secret"))
        XCTAssertFalse(encryptedRaw.contains("clipboard content"))

        await store.setHistoryEncryptionEnabled(false)

        XCTAssertEqual(store.snapshot.security.storageMode, .standard)
        XCTAssertEqual(harness.snapshotStore.storageMode, .standard)
        let standardRaw = String(decoding: try Data(contentsOf: harness.snapshotStore.fileURL), as: UTF8.self)
        XCTAssertTrue(standardRaw.contains("Visible Secret"))
        XCTAssertTrue(standardRaw.contains("clipboard content"))
    }

    func testIdempotentEncryptionEnableDoesNotCancelPendingEncryptedSave() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        harness.snapshotStore.storageMode = .encrypted
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            saveDebounceNanoseconds: 60_000_000_000
        )
        let pendingItem = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Pending Encrypted Item",
            payload: ClipboardPayload(text: "pending encrypted payload")
        ))

        await store.setHistoryEncryptionEnabled(true)
        let didFlush = await store.flushPendingSave()

        XCTAssertTrue(didFlush)
        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()
        XCTAssertEqual(reloaded.snapshot.items.map(\.id), [pendingItem.id])
    }

    func testEnablingEncryptionRemovesPlaintextRepositoryAndPreservesBinaryAssets() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let databaseURL = harness.directory.appendingPathComponent("clipboard.sqlite")
        let repository = ClipboardItemRepository(database: try PasteBuddyDatabase(fileURL: databaseURL))
        harness.snapshotStore.storageMode = .standard
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository
        )
        let imageData = Data(repeating: 0xAB, count: 8_192)
        let rtfData = Data("{\\rtf1 encrypted repository migration}".utf8)
        let item = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .mixed,
            title: "Repository Plaintext Secret",
            payload: ClipboardPayload(
                text: "repository plaintext body",
                rtfData: rtfData,
                imageData: imageData,
                ocrText: "repository plaintext OCR"
            )
        ))

        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))

        await store.setHistoryEncryptionEnabled(true)

        XCTAssertFalse(store.isPersistenceWriteBlocked, store.lastErrorMessage ?? "")
        XCTAssertEqual(store.snapshot.security.storageMode, .encrypted)
        for url in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Plaintext repository residue: \(url.path)")
        }
        let rawEnvelope = String(decoding: try Data(contentsOf: harness.snapshotStore.fileURL), as: UTF8.self)
        XCTAssertFalse(rawEnvelope.contains("Repository Plaintext Secret"))
        XCTAssertFalse(rawEnvelope.contains("repository plaintext body"))

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()
        let reloadedItem = try XCTUnwrap(reloaded.snapshot.items.first(where: { $0.id == item.id }))
        XCTAssertEqual(reloadedItem.payload.imageData, imageData)
        XCTAssertEqual(reloadedItem.payload.rtfData, rtfData)

        await store.setHistoryEncryptionEnabled(false)

        XCTAssertFalse(store.isPersistenceWriteBlocked, store.lastErrorMessage ?? "")
        XCTAssertEqual(store.snapshot.security.storageMode, .standard)
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
        let restoredRepository = ClipboardItemRepository(
            database: try PasteBuddyDatabase(fileURL: databaseURL)
        )
        let restoredItem = try XCTUnwrap(restoredRepository.exportSnapshot().items.first(where: { $0.id == item.id }))
        XCTAssertEqual(restoredItem.payload.imageData, imageData)
        XCTAssertEqual(restoredItem.payload.rtfData, rtfData)
    }

    func testDisablingEncryptionResynchronizesRepositoryAfterCaptureDuringDiskPersistence() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let databaseURL = harness.directory.appendingPathComponent("disable-encryption-race.sqlite")
        let repository = ClipboardItemRepository(database: try PasteBuddyDatabase(fileURL: databaseURL))
        harness.snapshotStore.storageMode = .standard
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository,
            saveDebounceNanoseconds: 60_000_000_000
        )
        _ = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Before Encryption Disable",
            payload: ClipboardPayload(text: "before encryption disable")
        ))
        let didFlushSeed = await store.flushPendingSave()
        XCTAssertTrue(didFlushSeed)
        await store.setHistoryEncryptionEnabled(true)
        XCTAssertEqual(store.snapshot.security.storageMode, .encrypted)

        let persistenceGate = SuspendedStoreLoadGate()
        store.beforePersistingStandardMigrationSnapshotForTesting = {
            await persistenceGate.suspend()
        }
        let disableTask = Task { @MainActor in
            await store.setHistoryEncryptionEnabled(false)
        }
        while await !persistenceGate.hasSuspended() {
            await Task.yield()
        }
        let concurrentCapture = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Messages",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Captured While Disabling Encryption",
            payload: ClipboardPayload(text: "must reach both standard stores")
        ))
        await persistenceGate.resume()
        await disableTask.value

        XCTAssertFalse(store.isPersistenceWriteBlocked, store.lastErrorMessage ?? "")
        XCTAssertEqual(store.snapshot.security.storageMode, .standard)
        let authorityStore = HistoryPersistenceAuthorityStore(snapshotURL: harness.snapshotStore.fileURL)
        let authority = try XCTUnwrap(authorityStore.load())
        XCTAssertEqual(authority.phase, .stable)
        XCTAssertEqual(authority.authority, .sqlite)
        XCTAssertNotNil(authority.targetRevision)
        let legacySnapshotReader = EncryptedSnapshotStore(
            fileURL: harness.snapshotStore.fileURL,
            encryptionService: harness.encryptionService,
            storageMode: .standard
        )
        XCTAssertThrowsError(try legacySnapshotReader.load())
        let restoredRepository = ClipboardItemRepository(
            database: try PasteBuddyDatabase(fileURL: databaseURL)
        )
        XCTAssertTrue(try restoredRepository.exportSnapshot().items.contains(where: { $0.id == concurrentCapture.id }))
        let reloaded = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: restoredRepository
        )
        reloaded.load()
        XCTAssertTrue(reloaded.snapshot.items.contains(where: { $0.id == concurrentCapture.id }))
    }

    func testEncryptionMigrationPreservesCaptureCreatedWhileHydrationIsSuspended() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        harness.snapshotStore.storageMode = .standard
        let databaseURL = harness.directory.appendingPathComponent("clipboard.sqlite")
        let repository = ClipboardItemRepository(database: try PasteBuddyDatabase(fileURL: databaseURL))
        let store = PasteBuddyStore(
            diskStore: harness.snapshotStore,
            clipboardRepository: repository,
            saveDebounceNanoseconds: 60_000_000_000
        )
        _ = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Before Migration",
            payload: ClipboardPayload(text: "before migration secret")
        ))
        let didFlushSeed = await store.flushPendingSave()
        XCTAssertTrue(didFlushSeed)

        let migrationGate = SuspendedStoreLoadGate()
        store.beforeCommittingHistoryStorageMigrationForTesting = {
            await migrationGate.suspend()
        }
        let migrationTask = Task { @MainActor in
            await store.setHistoryEncryptionEnabled(true)
        }
        while await !migrationGate.hasSuspended() {
            await Task.yield()
        }
        let concurrentCapture = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Terminal",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Captured During Migration",
            payload: ClipboardPayload(text: "capture during migration secret")
        ))

        await migrationGate.resume()
        await migrationTask.value
        store.beforeCommittingHistoryStorageMigrationForTesting = nil

        XCTAssertFalse(store.isPersistenceWriteBlocked, store.lastErrorMessage ?? "")
        XCTAssertEqual(store.snapshot.security.storageMode, .encrypted)
        XCTAssertTrue(store.snapshot.items.contains(where: { $0.id == concurrentCapture.id }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))
        let encryptedRaw = String(
            decoding: try Data(contentsOf: harness.snapshotStore.fileURL),
            as: UTF8.self
        )
        XCTAssertFalse(encryptedRaw.contains("Captured During Migration"))
        XCTAssertFalse(encryptedRaw.contains("capture during migration secret"))

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()
        XCTAssertTrue(reloaded.snapshot.items.contains(where: { $0.id == concurrentCapture.id }))
    }

    func testStoreLoadPreservesLegacyEncryptedSnapshotStorageMode() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let legacyItem = ClipboardItem(
            sourceAppName: "Unit Test",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Legacy Secret",
            payload: ClipboardPayload(text: "legacy encrypted content")
        )
        var legacySnapshot = PasteBuddySnapshot(items: [legacyItem])
        legacySnapshot.security.storageMode = .encrypted
        harness.snapshotStore.storageMode = .encrypted
        try harness.snapshotStore.save(legacySnapshot)

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.load()

        XCTAssertEqual(store.snapshot.security.storageMode, .encrypted)
        XCTAssertEqual(harness.snapshotStore.storageMode, .encrypted)
        XCTAssertEqual(store.filteredItems.map(\.title), ["Legacy Secret"])

        store.addCapturedItem(ClipboardItem(
            sourceAppName: "Unit Test",
            deviceName: "Test Mac",
            contentType: .text,
            title: "New Encrypted Item",
            payload: ClipboardPayload(text: "new encrypted content")
        ))

        let encryptedRaw = String(decoding: try Data(contentsOf: harness.snapshotStore.fileURL), as: UTF8.self)
        XCTAssertFalse(encryptedRaw.contains("legacy encrypted content"))
        XCTAssertFalse(encryptedRaw.contains("new encrypted content"))
    }

    func testTeamPlanSeatBillingMetadataPersistsThroughEncryptedStore() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)

        store.configureTeamPlan(
            teamName: "Acme Design",
            seatCount: 12,
            assignedSeatCount: 5,
            pricePerSeatCents: 1_500,
            billingCurrencyCode: "usd",
            singleInvoiceEnabled: true,
            managedDistributionEnabled: true,
            adminEmailAddress: "admin@example.com"
        )

        XCTAssertEqual(store.snapshot.entitlement.plan, .team)
        XCTAssertEqual(store.snapshot.entitlement.status, .active)
        XCTAssertTrue(store.snapshot.entitlement.hasFullAccess())
        XCTAssertEqual(store.snapshot.entitlement.team?.displayName, "Acme Design")
        XCTAssertEqual(store.snapshot.entitlement.team?.billingCurrencyCode, "USD")
        XCTAssertEqual(store.snapshot.entitlement.team?.monthlyInvoiceCents, 18_000)
        XCTAssertEqual(store.snapshot.entitlement.team?.availableSeatCount, 7)
        XCTAssertTrue(store.snapshot.entitlement.team?.singleInvoiceEnabled == true)
        XCTAssertTrue(store.snapshot.entitlement.team?.managedDistributionEnabled == true)
        XCTAssertFalse(store.snapshot.entitlement.plan.isPersonalPaidPlan)

        let overview = try XCTUnwrap(store.snapshot.entitlement.teamOverview)
        XCTAssertEqual(overview.teamName, "Acme Design")
        XCTAssertEqual(overview.adminSummary, "Admin: admin@example.com")
        XCTAssertEqual(overview.seatSummary, "5/12 seats assigned, 7 available")
        XCTAssertTrue(overview.billingSummary.contains("Single invoice"))
        XCTAssertTrue(overview.billingSummary.contains("USD 180.00"))
        XCTAssertTrue(overview.distributionSummary.contains("Managed distribution enabled"))
        XCTAssertTrue(overview.primaryValueStatement.contains("shared pinboards"))
        XCTAssertTrue(overview.primaryValueStatement.contains("ideas, links, files"))
        XCTAssertTrue(overview.purchasePositioning.contains("distinct from personal"))
        XCTAssertTrue(overview.purchasePositioning.contains("seat billing"))
        XCTAssertEqual(
            overview.valuePropositions.map(\.id),
            ["shared-pinboards", "stay-in-sync", "admin-seat-state"]
        )

        store.updateTeamSeatAssignment(20)

        XCTAssertEqual(store.snapshot.entitlement.team?.assignedSeatCount, 12)
        XCTAssertEqual(store.snapshot.entitlement.team?.availableSeatCount, 0)

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertEqual(reloaded.snapshot.entitlement.plan, .team)
        XCTAssertEqual(reloaded.snapshot.entitlement.team?.assignedSeatCount, 12)
        XCTAssertEqual(reloaded.snapshot.entitlement.team?.adminEmailAddress, "admin@example.com")
    }

    func testSnapshotDecodingDefaultsMissingEntitlement() throws {
        let data = Data(#"{"schemaVersion":1}"#.utf8)

        let snapshot = try JSONDecoder().decode(PasteBuddySnapshot.self, from: data)

        XCTAssertEqual(snapshot.entitlement.plan, .free)
        XCTAssertEqual(snapshot.entitlement.status, .inactive)
        XCTAssertFalse(snapshot.entitlement.hasFullAccess())
    }

    func testPrivacySettingsPersistThroughEncryptedStore() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.toggleCapturePaused()
        store.toggleOCR()
        store.toggleTextCapture()
        store.toggleURLCapture()
        store.toggleFileCapture()
        store.toggleImageCapture()
        store.toggleSensitiveTextBlocking()
        store.excludeCurrentApplication(named: "Password Vault", bundleIdentifier: "com.example.password-vault")

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertTrue(reloaded.snapshot.privacy.isCapturePaused)
        XCTAssertFalse(reloaded.snapshot.privacy.runLocalOCRAfterImageCapture)
        XCTAssertFalse(reloaded.snapshot.privacy.captureText)
        XCTAssertFalse(reloaded.snapshot.privacy.captureURLs)
        XCTAssertFalse(reloaded.snapshot.privacy.captureFiles)
        XCTAssertFalse(reloaded.snapshot.privacy.captureImages)
        XCTAssertFalse(reloaded.snapshot.privacy.blockLikelySensitiveText)
        XCTAssertTrue(reloaded.snapshot.privacy.excludedApplicationNames.contains("Password Vault"))
        XCTAssertTrue(reloaded.snapshot.privacy.excludedBundleIdentifiers.contains("com.example.password-vault"))
    }

    func testCustomCaptureRulesPersistEncryptedAndCanBeToggled() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let rule = try XCTUnwrap(store.addCaptureRule(
            name: "Payroll drafts",
            condition: .containsText,
            pattern: "do-not-save-payroll",
            contentTypes: [.text]
        ))

        store.setCaptureRule(rule.id, enabled: false)

        let raw = try Data(contentsOf: harness.snapshotStore.fileURL)
        let rawString = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(rawString.contains("Payroll drafts"))
        XCTAssertFalse(rawString.contains("do-not-save-payroll"))

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertEqual(reloaded.snapshot.privacy.customCaptureRules.count, 1)
        XCTAssertEqual(reloaded.snapshot.privacy.customCaptureRules[0].name, "Payroll drafts")
        XCTAssertEqual(reloaded.snapshot.privacy.customCaptureRules[0].condition, .containsText)
        XCTAssertEqual(reloaded.snapshot.privacy.customCaptureRules[0].pattern, "do-not-save-payroll")
        XCTAssertEqual(reloaded.snapshot.privacy.customCaptureRules[0].contentTypes, [.text])
        XCTAssertFalse(reloaded.snapshot.privacy.customCaptureRules[0].isEnabled)

        reloaded.removeCaptureRule(rule.id)

        XCTAssertTrue(reloaded.snapshot.privacy.customCaptureRules.isEmpty)
    }

    func testTimedCapturePauseExpiresAndResumeClearsPauseUntil() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let now = Date()

        store.pauseCapture(for: 15 * 60, now: now)

        XCTAssertFalse(store.snapshot.privacy.isCapturePaused)
        XCTAssertTrue(store.snapshot.privacy.isCaptureCurrentlyPaused(now: now.addingTimeInterval(60)))
        XCTAssertFalse(store.snapshot.privacy.isCaptureCurrentlyPaused(now: now.addingTimeInterval(16 * 60)))

        store.resumeCapture()

        XCTAssertFalse(store.isCapturePaused)
        XCTAssertNil(store.snapshot.privacy.capturePauseUntil)
    }

    func testPrivacyPostureReportCoversSurfacesBoundariesAndPausedState() {
        let now = Date()
        let pauseUntil = now.addingTimeInterval(900)
        let payrollRule = CaptureRule(
            name: "Payroll",
            condition: .containsText,
            pattern: "payroll",
            contentTypes: [.text]
        )
        var snapshot = PasteBuddySnapshot()
        snapshot.privacy = PrivacyConfiguration(
            capturePauseUntil: pauseUntil,
            captureText: false,
            customCaptureRules: [payrollRule]
        )
        snapshot.sync = SyncConfiguration(
            provider: .cloudKit,
            isCloudSyncEnabled: true,
            cloudKitContainerIdentifier: "iCloud.com.example.PasteBuddy",
            isCloudKitCapabilityConfigured: true
        )
        snapshot.mcp = MCPConfiguration(isServerEnabled: true, enabledTools: [.searchHistory])

        let report = snapshot.privacyPostureReport(now: now)

        XCTAssertEqual(report.captureStatus, .pausedUntil(pauseUntil))
        XCTAssertEqual(report.protectedSurfaces, Set(PrivacyProtectedSurface.allCases))
        XCTAssertEqual(report.disabledContentTypes, [.text])
        XCTAssertEqual(report.activeCustomCaptureRuleCount, 1)
        XCTAssertTrue(report.sensitiveTextBlockingEnabled)
        XCTAssertTrue(report.coverageStatement.contains("history"))
        XCTAssertTrue(report.coverageStatement.contains("pinboards"))
        XCTAssertTrue(report.coverageStatement.contains("Shortcuts"))
        XCTAssertTrue(report.coverageStatement.contains("keyboard"))
        XCTAssertTrue(report.coverageStatement.contains("MCP"))
        XCTAssertEqual(report.localBoundaryStatement, "message.clipboard_payloads_screenshots_ocr_metadata_thumbnails_privacy")
        XCTAssertTrue(report.syncBoundaryStatement.contains("private iCloud"))
        XCTAssertFalse(report.syncBoundaryStatement.contains("encrypted records"))
        XCTAssertTrue(report.vendorServerStatement.contains("does not send clipboard payloads to vendor servers"))
        XCTAssertTrue(report.mcpBoundaryStatement.contains("MCP Agent connection is on"))
    }

    func testPrivacyConfigurationCaptureRules() {
        let privacy = PrivacyConfiguration(
            captureText: false,
            captureURLs: false,
            captureFiles: false,
            captureImages: false
        )

        XCTAssertFalse(privacy.allowsCapture(of: .text))
        XCTAssertFalse(privacy.allowsCapture(of: .url))
        XCTAssertFalse(privacy.allowsCapture(of: .file))
        XCTAssertFalse(privacy.allowsCapture(of: .image))
    }

    func testPrivacyConfigurationExcludesSensitiveAppsByBundleIdentifier() {
        let privacy = PrivacyConfiguration()

        XCTAssertTrue(privacy.excludesApplication(named: "Renamed Vault", bundleIdentifier: "com.1password.1password"))
        XCTAssertTrue(privacy.excludesApplication(named: "Passwords", bundleIdentifier: nil))
        XCTAssertFalse(privacy.excludesApplication(named: "Notes", bundleIdentifier: "com.apple.Notes"))
    }

    func testCustomCaptureRulesMatchTextSourceBundleURLAndFiles() {
        let textRule = CaptureRule(
            name: "Internal payroll",
            condition: .containsText,
            pattern: "payroll",
            contentTypes: [.text]
        )
        let bundleRule = CaptureRule(
            name: "Private browser",
            condition: .sourceBundleIdentifier,
            pattern: "com.private.browser"
        )
        let urlRule = CaptureRule(
            name: "Staging host",
            condition: .urlHost,
            pattern: "staging.example.com",
            contentTypes: [.url]
        )
        let fileRule = CaptureRule(
            name: "Raw keys",
            condition: .fileExtension,
            pattern: ".pem",
            contentTypes: [.file]
        )
        let regexRule = CaptureRule(
            name: "Ticket IDs",
            condition: .regularExpression,
            pattern: #"INC-\d{4}"#
        )
        let privacy = PrivacyConfiguration(customCaptureRules: [
            textRule,
            bundleRule,
            urlRule,
            fileRule,
            regexRule
        ])

        let text = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Comp Plan",
            payload: ClipboardPayload(text: "Payroll draft")
        )
        let url = ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Test Mac",
            contentType: .url,
            title: "Staging",
            payload: ClipboardPayload(urlString: "https://staging.example.com/admin")
        )
        let file = ClipboardItem(
            sourceAppName: "Finder",
            deviceName: "Test Mac",
            contentType: .file,
            title: "Key",
            payload: ClipboardPayload(fileURLString: "file:///Users/test/key.pem")
        )
        let ticket = ClipboardItem(
            sourceAppName: "Messages",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Incident",
            payload: ClipboardPayload(text: "INC-4821 needs review")
        )
        let allowed = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Lunch",
            payload: ClipboardPayload(text: "menu")
        )

        XCTAssertEqual(privacy.blockingCaptureRule(for: text)?.id, textRule.id)
        XCTAssertEqual(privacy.blockingCaptureRule(for: allowed, sourceBundleIdentifier: "com.private.browser")?.id, bundleRule.id)
        XCTAssertEqual(privacy.blockingCaptureRule(for: url)?.id, urlRule.id)
        XCTAssertEqual(privacy.blockingCaptureRule(for: file)?.id, fileRule.id)
        XCTAssertEqual(privacy.blockingCaptureRule(for: ticket)?.id, regexRule.id)
        XCTAssertNil(privacy.blockingCaptureRule(for: allowed, sourceBundleIdentifier: "com.apple.Notes"))
    }

    func testStorageUsageReportUsesPrecomputedBytesAndInvalidatesAfterMutation() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        var item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Cached Bytes",
            payload: ClipboardPayload(text: String(repeating: "large ", count: 200))
        )
        item.searchDocument.storageBytes = 1_234
        store.snapshot = PasteBuddySnapshot(items: [item])

        let cachedReport = store.storageUsageReport
        let repeatedReport = store.storageUsageReport

        XCTAssertEqual(cachedReport, repeatedReport)
        XCTAssertEqual(cachedReport.estimatedBytes, 1_234)

        store.updateTextItem(item.id, to: String(repeating: "updated ", count: 400))

        let updatedItem = try XCTUnwrap(store.snapshot.items.first { $0.id == item.id })
        let updatedReport = store.storageUsageReport
        XCTAssertEqual(updatedReport.estimatedBytes, updatedItem.searchDocument.storageBytes)
        XCTAssertGreaterThan(updatedReport.estimatedBytes, cachedReport.estimatedBytes)
    }

}
