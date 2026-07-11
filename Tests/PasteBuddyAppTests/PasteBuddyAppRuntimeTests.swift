import AppKit
import Carbon
import PasteBuddyCore
import XCTest
@testable import PasteBuddy

private actor SuspendedRuntimeLoader {
    private var calls = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func load() async {
        calls += 1
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func release() {
        let pendingContinuations = continuations
        continuations.removeAll()
        for continuation in pendingContinuations {
            continuation.resume()
        }
    }

    func callCount() -> Int { calls }
}

@MainActor
final class PasteBuddyAppRuntimeTests: XCTestCase {
    func testAppDelegateFallsBackToDefaultReopenWhenDockHandlerIsMissing() {
        let delegate = AppDelegate()

        XCTAssertFalse(
            delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        )
        XCTAssertTrue(
            delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true)
        )
    }

    func testDevelopmentPanelCommandAcceptsOnlyStableDevelopmentIdentity() throws {
        let identity = PasteBuddyRuntimeIdentity(
            bundleIdentifier: "com.alexjiang.PasteBuddy.dev",
            bundlePath: "/Applications/PasteBuddy Dev.app",
            executablePath: "/Applications/PasteBuddy Dev.app/Contents/MacOS/PasteBuddy",
            stableAppPath: "/Applications/PasteBuddy Dev.app",
            signingChannel: "development",
            codeSigningIdentity: "APPLE-DEVELOPMENT"
        )

        XCTAssertEqual(
            PasteBuddyDevelopmentPanelCommand.parse(
                try XCTUnwrap(URL(string: "pastebuddy-dev://panel/side")),
                identity: identity
            ),
            .show(.sidePanel)
        )
        XCTAssertEqual(
            PasteBuddyDevelopmentPanelCommand.parse(
                try XCTUnwrap(URL(string: "pastebuddy-dev://panel/shelf")),
                identity: identity
            ),
            .show(.shelf)
        )
        XCTAssertEqual(
            PasteBuddyDevelopmentPanelCommand.parse(
                try XCTUnwrap(URL(string: "pastebuddy-dev://panel/toggle")),
                identity: identity
            ),
            .toggle
        )

        var releaseIdentity = identity
        releaseIdentity.bundleIdentifier = "com.alexjiang.PasteBuddy"
        releaseIdentity.signingChannel = "release"
        XCTAssertNil(
            PasteBuddyDevelopmentPanelCommand.parse(
                try XCTUnwrap(URL(string: "pastebuddy-dev://panel/side")),
                identity: releaseIdentity
            )
        )

        var copiedIdentity = identity
        copiedIdentity.bundlePath = "/private/tmp/PasteBuddy Dev.app"
        XCTAssertNil(
            PasteBuddyDevelopmentPanelCommand.parse(
                try XCTUnwrap(URL(string: "pastebuddy-dev://panel/side")),
                identity: copiedIdentity
            )
        )
    }

    func testDevelopmentPanelCommandRejectsMalformedURLs() throws {
        let identity = PasteBuddyRuntimeIdentity(
            bundleIdentifier: "com.alexjiang.PasteBuddy.dev",
            bundlePath: "/Applications/PasteBuddy Dev.app",
            executablePath: "/Applications/PasteBuddy Dev.app/Contents/MacOS/PasteBuddy",
            stableAppPath: "/Applications/PasteBuddy Dev.app",
            signingChannel: "development",
            codeSigningIdentity: "APPLE-DEVELOPMENT"
        )
        let rejected = [
            "PASTEBUDDY-DEV://panel/side",
            "pastebuddy-dev://PANEL/side",
            "pastebuddy-dev://panel/%73ide",
            "pastebuddy-dev://panel/side/extra",
            "pastebuddy-dev://user@panel/side",
            "pastebuddy-dev://panel:7/side",
            "pastebuddy-dev://panel/side?x=1",
            "pastebuddy-dev://panel/side#fragment",
            "pastebuddy-dev://panel/unknown"
        ]

        for rawURL in rejected {
            XCTAssertNil(
                PasteBuddyDevelopmentPanelCommand.parse(
                    try XCTUnwrap(URL(string: rawURL)),
                    identity: identity
                ),
                rawURL
            )
        }
    }

    func testAppDelegateQueuesOpenURLsUntilHandlerIsInstalled() throws {
        let delegate = AppDelegate()
        let first = try XCTUnwrap(URL(string: "pastebuddy-dev://panel/side"))
        let second = try XCTUnwrap(URL(string: "pastebuddy-dev://panel/shelf"))
        var delivered: [URL] = []

        delegate.application(NSApplication.shared, open: [first, second])
        XCTAssertTrue(delivered.isEmpty)

        delegate.handleOpenURLs = { delivered.append(contentsOf: $0) }
        XCTAssertEqual(delivered, [first, second])

        delegate.handleOpenURLs = { delivered.append(contentsOf: $0) }
        XCTAssertEqual(delivered, [first, second])
    }




    func testRuntimeLoadGateInvokesAsyncLoadOnlyOnce() async {
        let gate = PasteBuddyRuntimeLoadGate()
        var loadAsyncCallCount = 0

        _ = await gate.loadIfNeeded {
            loadAsyncCallCount += 1
        }
        _ = await gate.loadIfNeeded {
            loadAsyncCallCount += 1
        }

        XCTAssertEqual(loadAsyncCallCount, 1)
    }

    func testRuntimeLoadGateSurfacesAndCachesSanitizedHistoryFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasteBuddyRuntimeLoadGateTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("clipboard.pbstore")
        try Data("private clipboard contents".utf8).write(to: fileURL)
        let store = PasteBuddyStore(
            diskStore: EncryptedSnapshotStore(fileURL: fileURL, storageMode: .standard)
        )
        let gate = PasteBuddyRuntimeLoadGate()

        let result = await gate.loadIfNeeded {
            try await PasteBuddyStoreFactory.load(store)
        }

        guard case .failure(let error) = result else {
            return XCTFail("The host lifecycle gate must surface a failed history load.")
        }
        XCTAssertEqual(error, .historyUnavailable)
        XCTAssertEqual(error.localizedDescription, PasteBuddyPersistenceError.historyUnavailable.localizedDescription)
        XCTAssertTrue(store.isPersistenceWriteBlocked)
        XCTAssertEqual(store.lastErrorMessage, error.localizedDescription)

        var secondLoadCallCount = 0
        let cachedResult = await gate.loadIfNeeded {
            secondLoadCallCount += 1
        }
        guard case .failure(let cachedError) = cachedResult else {
            return XCTFail("A failed lifecycle attempt must stay fail closed.")
        }
        XCTAssertEqual(cachedError, .historyUnavailable)
        XCTAssertEqual(secondLoadCallCount, 0)
    }

    func testRuntimeLoadGateMakesConcurrentCallersAwaitTheSameLoad() async {
        let gate = PasteBuddyRuntimeLoadGate()
        let loader = SuspendedRuntimeLoader()
        var secondCallerCompleted = false

        let firstCaller = Task { @MainActor in
            await gate.loadIfNeeded {
                await loader.load()
            }
        }
        while await loader.callCount() == 0 {
            await Task.yield()
        }

        let secondCaller = Task { @MainActor in
            _ = await gate.loadIfNeeded {
                await loader.load()
            }
            secondCallerCompleted = true
        }
        await Task.yield()

        XCTAssertFalse(secondCallerCompleted)
        let callCountBeforeRelease = await loader.callCount()
        XCTAssertEqual(callCountBeforeRelease, 1)

        await loader.release()
        _ = await firstCaller.value
        await secondCaller.value

        XCTAssertTrue(secondCallerCompleted)
        let finalCallCount = await loader.callCount()
        XCTAssertEqual(finalCallCount, 1)
    }

    func testRuntimeLoadGatePreparesLoadingStatusBeforeLoadCompletes() async {
        let gate = PasteBuddyRuntimeLoadGate()
        let loader = SuspendedRuntimeLoader()
        let probe = ShelfReloadFailureProbe()

        let loadTask = Task { @MainActor in
            await gate.loadIfNeeded(
                onLoading: {
                    probe.loadingPreparationCount += 1
                },
                {
                    await loader.load()
                }
            )
        }
        while await loader.callCount() == 0 {
            await Task.yield()
        }

        XCTAssertEqual(probe.loadingPreparationCount, 1)
        await loader.release()
        guard case .success = await loadTask.value else {
            return XCTFail("The suspended runtime load should complete after release.")
        }
    }

    func testRuntimeStateDistinguishesLoadingReadyAndUnavailable() {
        XCTAssertEqual(
            PasteBuddyRuntimeState(
                isStoreLoaded: false,
                persistenceErrorMessage: nil
            ),
            .loading
        )
        XCTAssertEqual(
            PasteBuddyRuntimeState(
                isStoreLoaded: true,
                persistenceErrorMessage: nil
            ),
            .ready
        )
        XCTAssertEqual(
            PasteBuddyRuntimeState(
                isStoreLoaded: true,
                persistenceErrorMessage: "History unavailable"
            ),
            .unavailable("History unavailable")
        )
    }

    func testLoadingStatusMenuAllowsOnlySettingsAndQuit() {
        let menu = PasteBuddyStatusItemController.restrictedMenu(
            title: "PasteBuddy",
            statusMessage: "Loading clipboard history",
            settingsTitle: "Settings",
            quitTitle: "Quit",
            onOpenSettings: {},
            onQuit: {}
        )

        XCTAssertEqual(menu.items.first?.title, "Loading clipboard history")
        XCTAssertFalse(menu.items.first?.isEnabled ?? true)
        XCTAssertEqual(
            menu.items.filter(\.isEnabled).map(\.title),
            ["Settings", "Quit"]
        )
    }

    func testIrohStopClearsReceiveCallbackAndReturnsToIdle() async {
        let defaultsSuite = "PasteBuddyIrohStopTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let service = IrohClipboardSyncService(defaults: defaults)
        service.onItemReceived = { _ in }

        await service.stop()

        XCTAssertNil(service.onItemReceived)
        XCTAssertEqual(service.connectionState, .idle)
    }

    func testFrontmostApplicationTrackerStopsAndCanRestartObservation() {
        let tracker = FrontmostApplicationTracker()

        tracker.start()
        XCTAssertTrue(tracker.isTracking)

        tracker.stop()
        XCTAssertFalse(tracker.isTracking)

        tracker.start()
        XCTAssertTrue(tracker.isTracking)
        tracker.stop()
        XCTAssertFalse(tracker.isTracking)
    }

    func testManualShelfReloadFailureMakesRuntimeUnavailableWithoutRefreshingOrMutating() async throws {
        let fixture = try await PersistenceFailureTestFixture.make()
        defer { fixture.cleanup() }
        let probe = ShelfReloadFailureProbe()
        let controller = ClipboardShelfPanelController(
            store: fixture.store,
            directPasteItem: { _, format in
                DirectPasteResult(outcome: .emptySelection, itemCount: 0, format: format)
            },
            directPasteItems: { _, format in
                DirectPasteResult(outcome: .emptySelection, itemCount: 0, format: format)
            },
            reloadStore: { store in
                try await PasteBuddyStoreFactory.load(store)
            },
            onHistoryUnavailable: { error in
                probe.runtimeState = .unavailable(error.localizedDescription)
            }
        )

        let didReload = await controller.reloadClipboardHistory()
        if didReload {
            probe.refreshCount += 1
            fixture.store.createPinboard(named: "Must Not Be Created")
        }

        XCTAssertFalse(didReload)
        XCTAssertTrue(fixture.store.isPersistenceWriteBlocked)
        XCTAssertEqual(
            probe.runtimeState,
            .unavailable(PasteBuddyPersistenceError.historyUnavailable.localizedDescription)
        )
        XCTAssertEqual(probe.refreshCount, 0)
        XCTAssertFalse(controller.isVisible)
        XCTAssertEqual(
            fixture.store.snapshot.items.map(\.id),
            fixture.snapshotItemIDsBeforeFailure
        )
        XCTAssertEqual(
            fixture.store.snapshot.pinboards.map(\.id),
            fixture.snapshotPinboardIDsBeforeFailure
        )
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), fixture.diskBytesBeforeFailure)
    }

    func testTerminationCoordinatorDefersUntilPendingSaveFlush() async {
        var didFlush = false

        let didReply = await withCheckedContinuation { continuation in
            let reply = PasteBuddyTerminationCoordinator.flushBeforeTerminating({
                didFlush = true
            }, reply: { shouldTerminate in
                continuation.resume(returning: shouldTerminate)
            })

            XCTAssertEqual(reply, .terminateLater)
        }

        XCTAssertTrue(didReply)
        XCTAssertTrue(didFlush)
    }

    func testShelfDirectPasteWaitsOneMainActorTurnAfterImmediateDismissal() async {
        var events: [String] = []

        await ClipboardShelfDirectPasteCoordinator.runAfterImmediateDismissal(
            dismiss: {
                events.append("dismiss")
                Task { @MainActor in
                    events.append("focus-restored")
                }
            },
            operation: {
                events.append("paste")
            }
        )

        XCTAssertEqual(events, ["dismiss", "focus-restored", "paste"])
    }

    func testPinnedDirectPasteCanSkipImmediateDismissal() async {
        var events: [String] = []

        await ClipboardShelfDirectPasteCoordinator.runAfterImmediateDismissal(
            dismissBeforePaste: false,
            dismiss: {
                events.append("dismiss")
            },
            operation: {
                events.append("paste")
            }
        )

        XCTAssertEqual(events, ["paste"])
    }

    func testShelfPreviewToggleDismissesAlreadyPreviewedCard() {
        let item = makeShelfItem(title: "Screenshot")
        let interaction = ShelfInteractionModel(items: [item])

        XCTAssertTrue(interaction.togglePreview(for: item.id))
        XCTAssertEqual(interaction.previewedID, item.id)

        XCTAssertFalse(interaction.togglePreview(for: item.id))
        XCTAssertNil(interaction.previewedID)
        XCTAssertEqual(interaction.primarySelectedID, item.id)
        XCTAssertEqual(interaction.selectedIDs, [item.id])
    }

    func testShelfPreviewToggleSwitchesCardsAndIgnoresMissingItems() {
        let first = makeShelfItem(title: "First")
        let second = makeShelfItem(title: "Second")
        let interaction = ShelfInteractionModel(items: [first, second])

        XCTAssertTrue(interaction.togglePreview(for: first.id))
        XCTAssertEqual(interaction.previewedID, first.id)
        XCTAssertEqual(interaction.primarySelectedID, first.id)
        XCTAssertEqual(interaction.selectedIDs, [first.id])

        XCTAssertTrue(interaction.togglePreview(for: second.id))
        XCTAssertEqual(interaction.previewedID, second.id)
        XCTAssertEqual(interaction.primarySelectedID, second.id)
        XCTAssertEqual(interaction.selectedIDs, [second.id])

        XCTAssertFalse(interaction.togglePreview(for: UUID()))
        XCTAssertEqual(interaction.previewedID, second.id)
        XCTAssertEqual(interaction.primarySelectedID, second.id)
        XCTAssertEqual(interaction.selectedIDs, [second.id])
    }

    func testShelfPreviewPresentationSelectsPreviewedCard() {
        let first = makeShelfItem(title: "First")
        let second = makeShelfItem(title: "Second")
        let interaction = ShelfInteractionModel(items: [first, second])

        XCTAssertTrue(interaction.presentPreview(for: second.id))
        XCTAssertEqual(interaction.previewedID, second.id)
        XCTAssertEqual(interaction.primarySelectedID, second.id)
        XCTAssertEqual(interaction.selectedIDs, [second.id])

        interaction.dismissPreview(for: first.id)
        XCTAssertEqual(interaction.previewedID, second.id)

        interaction.dismissPreview(for: second.id)
        XCTAssertNil(interaction.previewedID)
        XCTAssertEqual(interaction.primarySelectedID, second.id)
        XCTAssertEqual(interaction.selectedIDs, [second.id])
    }

    func testShelfPreviewCanFollowKeyboardSelectionWithoutDismissing() {
        let first = makeShelfItem(title: "First")
        let second = makeShelfItem(title: "Second")
        let interaction = ShelfInteractionModel(items: [first, second])

        XCTAssertTrue(interaction.presentPreview(for: first.id))
        interaction.selectSingle(second.id, keepsPreviewOpen: true)

        XCTAssertEqual(interaction.previewedID, second.id)
        XCTAssertEqual(interaction.primarySelectedID, second.id)
        XCTAssertEqual(interaction.selectedIDs, [second.id])
    }

    func testShelfTreatsPopoverWindowsAsAuxiliaryPreviewWindows() {
        XCTAssertTrue(ClipboardShelfPanelController.isShelfAuxiliaryWindowClassName("NSPopoverWindow"))
        XCTAssertTrue(ClipboardShelfPanelController.isShelfAuxiliaryWindowClassName("_TtC7SwiftUI19PlatformPopoverHost"))
        XCTAssertTrue(ClipboardShelfPanelController.isShelfAuxiliaryWindowClassName("NSMenuWindow"))
        XCTAssertFalse(ClipboardShelfPanelController.isShelfAuxiliaryWindowClassName("NSWindow"))
    }

    func testShelfOutsideClickPolicyIgnoresMenuBarStatusItemClick() {
        let shelfFrame = CGRect(x: 0, y: 652, width: 1512, height: 330)
        let menuBarStatusItemPoint = CGPoint(x: 1329, y: 16)
        let ordinaryOutsidePoint = CGPoint(x: 800, y: 500)

        XCTAssertFalse(
            ClipboardShelfPanelController.shouldDismissForOutsideClick(
                at: menuBarStatusItemPoint,
                panelFrame: shelfFrame,
                isShelfAuxiliaryWindowHit: false,
                isIgnoredDismissalTargetHit: true
            )
        )
        XCTAssertTrue(
            ClipboardShelfPanelController.shouldDismissForOutsideClick(
                at: ordinaryOutsidePoint,
                panelFrame: shelfFrame,
                isShelfAuxiliaryWindowHit: false,
                isIgnoredDismissalTargetHit: false
            )
        )
        XCTAssertFalse(
            ClipboardShelfPanelController.shouldDismissForOutsideClick(
                at: CGPoint(x: -1, y: -1),
                panelFrame: shelfFrame,
                isShelfAuxiliaryWindowHit: false,
                isIgnoredDismissalTargetHit: false
            )
        )
    }

    func testPinnedSidePanelDoesNotDismissForOutsideClick() {
        XCTAssertFalse(
            ClipboardShelfPanelController.shouldDismissForOutsideClick(
                at: CGPoint(x: 800, y: 500),
                panelFrame: CGRect(x: 0, y: 652, width: 1512, height: 330),
                isShelfAuxiliaryWindowHit: false,
                isIgnoredDismissalTargetHit: false,
                isPinned: true
            )
        )
    }

    func testSidePanelDisplayModeFramesAsRightAnchoredFloatingHistoryList() {
        let frame = ClipboardShelfPanelController.rightAnchoredSidePanelFrame(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 40, width: 1512, height: 900),
            preferredSize: CGSize(width: 360, height: 697)
        )

        XCTAssertEqual(frame.width, 360)
        XCTAssertEqual(frame.height, 697)
        XCTAssertEqual(frame.minX, 1138)
        XCTAssertEqual(frame.minY, 235)
    }

    func testShelfPlacementFramesAttachToFullScreenTopOrBottomEdges() {
        let screenFrame = CGRect(x: -100, y: 50, width: 1512, height: 982)
        let visibleFrame = CGRect(x: -100, y: 111, width: 1512, height: 888)
        let shelfHeight: CGFloat = 330

        XCTAssertEqual(
            ClipboardShelfPanelController.attachedFrame(
                for: .top,
                screenFrame: screenFrame,
                visibleFrame: visibleFrame,
                height: shelfHeight
            ),
            CGRect(x: -100, y: 669, width: 1512, height: 330)
        )
        XCTAssertEqual(
            ClipboardShelfPanelController.attachedFrame(
                for: .bottom,
                screenFrame: screenFrame,
                visibleFrame: visibleFrame,
                height: shelfHeight
            ),
            CGRect(x: -100, y: 50, width: 1512, height: 330)
        )
    }


    func testClipboardTextPreviewBoundsInitialTextUntilExplicitExpansion() {
        let limit = ClipboardTextPreview.initialCharacterLimit
        let fullText = String(repeating: "a", count: limit + 1)
        let preview = ClipboardTextPreview(fullText)

        XCTAssertTrue(preview.isTruncated)
        XCTAssertEqual(preview.initialText, String(repeating: "a", count: limit) + "…")
        XCTAssertEqual(preview.text(showingFullText: false), preview.initialText)
        XCTAssertEqual(preview.text(showingFullText: true), fullText)

        let textAtLimit = String(repeating: "b", count: limit)
        let previewAtLimit = ClipboardTextPreview(textAtLimit)
        XCTAssertFalse(previewAtLimit.isTruncated)
        XCTAssertEqual(previewAtLimit.initialText, textAtLimit)
    }




    func testPinboardDragPayloadDefersPlainTextRenderingUntilProxyExport() throws {
        let counter = LockedInvocationCounter()
        let item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Large drag",
            payload: ClipboardPayload(text: String(repeating: "payload ", count: 20_000))
        )
        let payload = PinboardItemDragPayload(ids: [item.id], plainTextProvider: {
            counter.increment()
            return ClipboardPlainTextRenderer.plainText(for: item)
        })

        XCTAssertEqual(counter.value, 0)
        let encoded = try JSONEncoder().encode(payload)
        XCTAssertEqual(counter.value, 0, "Encoding the internal ID payload must not render external plain text")
        XCTAssertFalse(payload.plainText.isEmpty)
        XCTAssertEqual(counter.value, 1)

        let decoded = try JSONDecoder().decode(PinboardItemDragPayload.self, from: encoded)
        XCTAssertEqual(decoded.ids, [item.id])
        XCTAssertEqual(decoded.plainText, "")
    }






    func testImagePreviewDisplaySizePreservesAspectRatioWithinBounds() {
        let portrait = ClipboardImageCache.fittedDisplaySize(
            for: NSSize(width: 720, height: 1394),
            within: CGSize(width: 72, height: 54)
        )
        XCTAssertEqual(portrait.height, 54, accuracy: 0.01)
        XCTAssertLessThan(portrait.width, 30)

        let landscape = ClipboardImageCache.fittedDisplaySize(
            for: NSSize(width: 1394, height: 720),
            within: CGSize(width: 72, height: 54)
        )
        XCTAssertEqual(landscape.width, 72, accuracy: 0.01)
        XCTAssertLessThan(landscape.height, 38)
    }








    func testCollectionDragSessionExposesPendingMoveUntilCancelled() {
        let text = ClipboardCollectionID.smart(.text)
        let initial: [ClipboardCollectionID] = [.history, .pasteStack, text]
        var session = ClipboardCollectionDragSession()

        session.begin(source: text, order: initial, frames: [:], sourceOriginX: 100)
        session.updateTranslation(40)

        XCTAssertTrue(session.previewMove(relativeTo: .pasteStack, afterTarget: false))
        XCTAssertEqual(session.displayOrder(fallback: initial), [.history, text, .pasteStack])
        XCTAssertEqual(session.displayOrder(fallback: initial).count, initial.count)
        XCTAssertTrue(session.displayOrder(fallback: initial).contains(text))
        XCTAssertEqual(session.visualOffset(currentSourceLayoutMinX: 160), -20)
        XCTAssertFalse(session.previewMove(relativeTo: .pasteStack, afterTarget: false))
        XCTAssertEqual(
            session.pendingMove,
            ClipboardCollectionMove(source: text, target: .pasteStack, afterTarget: false)
        )
        XCTAssertEqual(session.displayOrder(fallback: initial), [.history, text, .pasteStack])

        session.cancel()

        XCTAssertNil(session.pendingMove)
        XCTAssertEqual(session.displayOrder(fallback: initial), initial)
    }

    func testCollectionDragSessionCancelRestoresOriginalOrderWithoutCommit() {
        let text = ClipboardCollectionID.smart(.text)
        let initial: [ClipboardCollectionID] = [.history, .pasteStack, text]
        var session = ClipboardCollectionDragSession()

        session.begin(source: text, order: initial, frames: [:])
        XCTAssertTrue(session.previewMove(relativeTo: .history, afterTarget: false))
        XCTAssertNotEqual(session.displayOrder(fallback: initial), initial)

        session.cancel()

        XCTAssertEqual(session.displayOrder(fallback: initial), initial)
        XCTAssertNil(session.pendingMove)
    }




    func testCollectionDragTargetsUseGestureStartFramesInsteadOfAnimatedLiveFrames() throws {
        let text = ClipboardCollectionID.smart(.text)
        let links = ClipboardCollectionID.smart(.links)
        let order: [ClipboardCollectionID] = [text, .history, links, .pasteStack]
        var liveFrames: [ClipboardCollectionID: CGRect] = [
            text: CGRect(x: 0, y: 0, width: 60, height: 30),
            .history: CGRect(x: 65, y: 0, width: 100, height: 30),
            links: CGRect(x: 170, y: 0, width: 70, height: 30),
            .pasteStack: CGRect(x: 245, y: 0, width: 116, height: 30),
        ]
        var session = ClipboardCollectionDragSession()
        session.begin(source: .pasteStack, order: order, frames: liveFrames, sourceOriginX: 245)

        liveFrames[links] = CGRect(x: 300, y: 0, width: 70, height: 30)
        let linksTarget = try XCTUnwrap(session.dropTarget(at: 180))
        XCTAssertEqual(linksTarget.collection, links)
        XCTAssertFalse(linksTarget.afterTarget)
        XCTAssertTrue(session.previewMove(relativeTo: linksTarget.collection, afterTarget: linksTarget.afterTarget))
        XCTAssertEqual(session.displayOrder(fallback: order), [text, .history, .pasteStack, links])

        let historyTarget = try XCTUnwrap(session.dropTarget(at: 90))
        XCTAssertEqual(historyTarget.collection, .history)
        XCTAssertFalse(historyTarget.afterTarget)
    }



    func testCollectionMoveStateSuppressesOnlyThePersistedOrderRevisionRefresh() {
        func queryState(
            dataRevision: Int,
            queryRevision: Int = 7,
            scope: PasteScope = .history
        ) -> ClipboardPanelQueryState {
            ClipboardPanelQueryState(
                dataRevision: dataRevision,
                queryRevision: queryRevision,
                scope: scope,
                searchQuery: "",
                contentTypeFilter: nil,
                sourceAppFilter: nil,
                deviceFilter: nil,
                dateFilter: .any
            )
        }

        let previous = queryState(dataRevision: 1)
        var moveState = ClipboardPanelCollectionMoveState()

        XCTAssertTrue(moveState.recordMove(true, dataRevision: 2))
        XCTAssertFalse(moveState.requiresRefresh(from: previous, to: queryState(dataRevision: 2)))

        XCTAssertTrue(moveState.recordMove(true, dataRevision: 3))
        XCTAssertTrue(moveState.requiresRefresh(
            from: queryState(dataRevision: 2),
            to: queryState(dataRevision: 3, queryRevision: 8)
        ))

        XCTAssertTrue(moveState.recordMove(true, dataRevision: 4))
        XCTAssertTrue(moveState.requiresRefresh(
            from: queryState(dataRevision: 3),
            to: queryState(dataRevision: 4, scope: .pasteStack)
        ))

        XCTAssertFalse(moveState.recordMove(false, dataRevision: 5))
        XCTAssertTrue(moveState.requiresRefresh(
            from: queryState(dataRevision: 4),
            to: queryState(dataRevision: 5)
        ))
    }























    func testInstalledApplicationCatalogReadsAppsFromLocalBundles() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("PasteBuddyInstalledApplicationCatalog-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try makeTemporaryApp(
            at: root.appendingPathComponent("Code.app", isDirectory: true),
            displayName: "Code",
            bundleIdentifier: "com.example.code"
        )
        try makeTemporaryApp(
            at: root.appendingPathComponent("Copies/Code Copy.app", isDirectory: true),
            displayName: "Code Copy",
            bundleIdentifier: "com.example.code"
        )
        try makeTemporaryApp(
            at: root.appendingPathComponent("Utilities/No Bundle.app", isDirectory: true),
            displayName: "No Bundle",
            bundleIdentifier: nil
        )

        let applications = await InstalledApplicationCatalog(applicationDirectories: [root]).applications()

        XCTAssertEqual(applications.filter { $0.bundleIdentifier == "com.example.code" }.count, 1)
        XCTAssertTrue(applications.contains { $0.displayName == "Code" && $0.bundleIdentifier == "com.example.code" })
        XCTAssertTrue(applications.contains { $0.displayName == "No Bundle" && $0.bundleIdentifier == nil })
    }




    func testPanelHotKeyMatcherSeparatesShowHideAndShelfModeActions() {
        XCTAssertTrue(
            PasteBuddyPanelHotKeyMatcher.matches(
                keyCode: Int64(kVK_ANSI_V),
                flags: [.maskCommand, .maskShift]
            )
        )
        XCTAssertEqual(
            PasteBuddyPanelHotKeyMatcher.action(
                keyCode: Int64(kVK_ANSI_V),
                flags: [.maskCommand, .maskShift]
            ),
            .showHide
        )
        XCTAssertEqual(
            PasteBuddyPanelHotKeyMatcher.action(
                keyCode: Int64(kVK_ANSI_B),
                flags: [.maskCommand, .maskShift]
            ),
            .shelfMode
        )

        XCTAssertFalse(
            PasteBuddyPanelHotKeyMatcher.matches(
                keyCode: Int64(kVK_ANSI_B),
                flags: [.maskCommand, .maskShift]
            )
        )
        XCTAssertFalse(
            PasteBuddyPanelHotKeyMatcher.matches(
                keyCode: Int64(kVK_ANSI_V),
                flags: [.maskCommand]
            )
        )
        XCTAssertNil(
            PasteBuddyPanelHotKeyMatcher.action(
                keyCode: Int64(kVK_ANSI_B),
                flags: [.maskCommand]
            )
        )
        XCTAssertFalse(
            PasteBuddyPanelHotKeyMatcher.matches(
                keyCode: Int64(kVK_ANSI_V),
                flags: [.maskCommand, .maskShift, .maskAlternate]
            )
        )
        XCTAssertFalse(
            PasteBuddyPanelHotKeyMatcher.matches(
                keyCode: Int64(kVK_ANSI_V),
                flags: [.maskCommand, .maskShift, .maskControl]
            )
        )
    }

    func testDiagnosticsRecorderCapturesHotKeyEventsForTesting() {
        var events: [PasteBuddyDiagnosticEvent] = []
        PasteBuddyDiagnostics.installTestSink { event in
            events.append(event)
        }
        defer { PasteBuddyDiagnostics.removeTestSink() }

        PasteBuddyDiagnostics.record(.hotKey, "carbonRegistered", detail: "status=0")

        XCTAssertEqual(
            events,
            [
                PasteBuddyDiagnosticEvent(
                    category: .hotKey,
                    name: "carbonRegistered",
                    detail: "status=0"
                )
            ]
        )
    }

    func testDiagnosticsRecorderCapturesAccessibilityTrustChecksForTesting() {
        var events: [PasteBuddyDiagnosticEvent] = []
        PasteBuddyDiagnostics.installTestSink { event in
            events.append(event)
        }
        defer { PasteBuddyDiagnostics.removeTestSink() }

        PasteBuddyDiagnostics.recordAccessibilityTrust(
            .shelf,
            "accessibilityTrustCheckedBeforeShelfToggle",
            isTrusted: true
        )

        XCTAssertEqual(
            events,
            [
                PasteBuddyDiagnosticEvent(
                    category: .shelf,
                    name: "accessibilityTrustCheckedBeforeShelfToggle",
                    detail: "trusted=true"
                )
            ]
        )
    }










    func testPanelFirstPagePerformanceTrackerRejectsStaleAndDuplicateCompletion() {
        var tracker = ClipboardPanelFirstPagePerformanceTracker()
        let stalePresentation = tracker.begin()
        let activePresentation = tracker.begin()

        XCTAssertFalse(tracker.finish(presentationID: stalePresentation, itemCount: .small))
        XCTAssertTrue(tracker.finish(presentationID: activePresentation, itemCount: .medium))
        XCTAssertFalse(tracker.finish(presentationID: activePresentation, itemCount: .medium))

        let cancelledPresentation = tracker.begin()
        tracker.cancel()
        XCTAssertFalse(tracker.finish(presentationID: cancelledPresentation, itemCount: .large))
    }

    func testLaunchPerformanceTrackerStartsAndFinishesOnlyOnce() {
        let tracker = PasteBuddyLaunchPerformanceTracker()

        XCTAssertTrue(tracker.begin())
        XCTAssertFalse(tracker.begin())
        XCTAssertTrue(tracker.finish(itemCount: .medium, result: .succeeded))
        XCTAssertFalse(tracker.finish(itemCount: .medium, result: .succeeded))
    }

    func testPanelHotKeyTriggerGateRecordsSourceAndDeduplicates() {
        var events: [PasteBuddyDiagnosticEvent] = []
        PasteBuddyDiagnostics.installTestSink { event in
            events.append(event)
        }
        defer { PasteBuddyDiagnostics.removeTestSink() }

        var gate = PasteBuddyPanelHotKeyTriggerGate()
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(gate.shouldTrigger(source: .eventTap, now: now))
        XCTAssertFalse(gate.shouldTrigger(source: .carbon, now: now.addingTimeInterval(0.10)))
        XCTAssertTrue(gate.shouldTrigger(source: .carbon, now: now.addingTimeInterval(0.30)))
        XCTAssertTrue(gate.shouldTrigger(action: .shelfMode, source: .eventTap, now: now.addingTimeInterval(0.35)))
        XCTAssertFalse(gate.shouldTrigger(action: .shelfMode, source: .carbon, now: now.addingTimeInterval(0.45)))

        XCTAssertEqual(
            events.map { "\($0.category.rawValue).\($0.name):\($0.detail ?? "")" },
            [
                "hotKey.pressed:source=eventTap",
                "hotKey.ignoredDuplicate:source=carbon",
                "hotKey.pressed:source=carbon",
                "hotKey.pressed:source=eventTap",
                "hotKey.ignoredDuplicate:source=carbon"
            ]
        )
    }

    func testShelfDirectPasteCoordinatorRecordsDiagnosticBoundaries() async {
        var events: [PasteBuddyDiagnosticEvent] = []
        PasteBuddyDiagnostics.installTestSink { event in
            events.append(event)
        }
        defer { PasteBuddyDiagnostics.removeTestSink() }

        _ = await ClipboardShelfDirectPasteCoordinator.runAfterImmediateDismissal(
            dismiss: {},
            operation: {
                "done"
            }
        )

        XCTAssertEqual(
            events.map { "\($0.category.rawValue).\($0.name)" },
            [
                "directPaste.dismissImmediate",
                "directPaste.operationStarted",
                "directPaste.operationFinished"
            ]
        )
    }

    func testAppIconThemeColorUsesLargestChromaticRegion() {
        let width = 40
        let height = 40
        let image = makeTestImage(width: width, height: height) { x, _ in
            x < 30
                ? (red: 255, green: 59, blue: 48, alpha: 255)
                : (red: 0, green: 122, blue: 255, alpha: 255)
        }

        let dominantColor = AppIconThemeColorResolver.dominantColor(in: image, sampleSize: 40)
        let rgbColor = dominantColor?.usingColorSpace(.deviceRGB)

        XCTAssertNotNil(rgbColor)
        XCTAssertGreaterThan(rgbColor?.redComponent ?? 0, rgbColor?.blueComponent ?? 1)
        XCTAssertGreaterThan(rgbColor?.redComponent ?? 0, rgbColor?.greenComponent ?? 1)
    }

    func testAppIconThemeColorPrefersSaturatedBrandMarkOverMutedBackground() {
        let width = 40
        let height = 40
        let image = makeTestImage(width: width, height: height) { x, y in
            let isBrandMark = (12..<28).contains(x) && (12..<28).contains(y)
            return isBrandMark
                ? (red: 0, green: 122, blue: 255, alpha: 255)
                : (red: 130, green: 150, blue: 115, alpha: 255)
        }

        let dominantColor = AppIconThemeColorResolver.dominantColor(in: image, sampleSize: 40)
        let rgbColor = dominantColor?.usingColorSpace(.deviceRGB)

        XCTAssertNotNil(rgbColor)
        XCTAssertGreaterThan(rgbColor?.blueComponent ?? 0, rgbColor?.redComponent ?? 1)
        XCTAssertGreaterThan(rgbColor?.blueComponent ?? 0, rgbColor?.greenComponent ?? 1)
    }

    func testSourceApplicationIconResolverCachesStableMisses() {
        let cache = SourceApplicationIconResolver.LookupCache(negativeCapacity: 4)
        let counter = LockedInvocationCounter()
        let item = makeSourceIconItem(bundleIdentifier: "com.example.missing")
        let bundleLookup: (String) -> SourceApplicationIconResolver.LookupResult = { _ in
            counter.increment()
            return .missing
        }
        let nameLookup: (String) -> SourceApplicationIconResolver.LookupResult = { _ in
            XCTFail("An unknown source name should not be queried")
            return .missing
        }

        XCTAssertNil(SourceApplicationIconResolver.icon(
            for: item,
            cache: cache,
            bundleLookup: bundleLookup,
            nameLookup: nameLookup
        ))
        XCTAssertNil(SourceApplicationIconResolver.icon(
            for: item,
            cache: cache,
            bundleLookup: bundleLookup,
            nameLookup: nameLookup
        ))
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(cache.negativeEntryCount, 1)
    }

    func testSourceApplicationIconResolverBoundsNegativeCache() {
        let cache = SourceApplicationIconResolver.LookupCache(negativeCapacity: 2)
        let identifiers = ["com.example.one", "com.example.two", "com.example.three"]
        let counters = identifiers.map { _ in LockedInvocationCounter() }
        let bundleLookup: (String) -> SourceApplicationIconResolver.LookupResult = { identifier in
            if let index = identifiers.firstIndex(of: identifier) {
                counters[index].increment()
            }
            return .missing
        }
        let nameLookup: (String) -> SourceApplicationIconResolver.LookupResult = { _ in .missing }

        for identifier in identifiers {
            _ = SourceApplicationIconResolver.icon(
                for: makeSourceIconItem(bundleIdentifier: identifier),
                cache: cache,
                bundleLookup: bundleLookup,
                nameLookup: nameLookup
            )
        }
        _ = SourceApplicationIconResolver.icon(
            for: makeSourceIconItem(bundleIdentifier: identifiers[0]),
            cache: cache,
            bundleLookup: bundleLookup,
            nameLookup: nameLookup
        )

        XCTAssertEqual(counters.map(\.value), [2, 1, 1])
        XCTAssertEqual(cache.negativeEntryCount, 2)
    }

    func testSourceApplicationIconResolverDoesNotCacheTemporaryFailures() {
        let cache = SourceApplicationIconResolver.LookupCache(negativeCapacity: 4)
        let counter = LockedInvocationCounter()
        let item = makeSourceIconItem(bundleIdentifier: "com.example.permission-denied")
        let bundleLookup: (String) -> SourceApplicationIconResolver.LookupResult = { _ in
            counter.increment()
            return .temporaryFailure
        }
        let nameLookup: (String) -> SourceApplicationIconResolver.LookupResult = { _ in .missing }

        XCTAssertNil(SourceApplicationIconResolver.icon(
            for: item,
            cache: cache,
            bundleLookup: bundleLookup,
            nameLookup: nameLookup
        ))
        XCTAssertNil(SourceApplicationIconResolver.icon(
            for: item,
            cache: cache,
            bundleLookup: bundleLookup,
            nameLookup: nameLookup
        ))
        XCTAssertEqual(counter.value, 2)
        XCTAssertEqual(cache.negativeEntryCount, 0)
    }

    private func makeTestImage(
        width: Int,
        height: Int,
        pixel: (_ x: Int, _ y: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)
    ) -> NSImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let color = pixel(x, y)
                pixels[offset] = color.red
                pixels[offset + 1] = color.green
                pixels[offset + 2] = color.blue
                pixels[offset + 3] = color.alpha
            }
        }
        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider!,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    private func makeShelfItem(title: String) -> ClipboardItem {
        ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .text,
            title: title,
            payload: ClipboardPayload(text: title)
        )
    }

    private func makeSourceIconItem(bundleIdentifier: String) -> ClipboardItem {
        ClipboardItem(
            sourceAppName: "Unknown",
            sourceBundleIdentifier: bundleIdentifier,
            deviceName: "Test Mac",
            contentType: .text,
            title: "Missing icon",
            payload: ClipboardPayload(text: "Missing icon")
        )
    }

    private func makeTemporaryApp(
        at url: URL,
        displayName: String,
        bundleIdentifier: String?
    ) throws {
        let contentsURL = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        var info: [String: String] = [
            "CFBundleDisplayName": displayName,
            "CFBundleName": displayName
        ]
        if let bundleIdentifier {
            info["CFBundleIdentifier"] = bundleIdentifier
        }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
    }

}

private final class LockedInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
