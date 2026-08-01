import AppKit
import Carbon
import PasteBuddyCore
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import PasteBuddy

@MainActor
final class PasteBuddyAppRuntimeTests: XCTestCase {
    func testScreenSharingPrivacyKeepsSettingsCapturableWhileHidingContentPanels() {
        XCTAssertEqual(
            PasteBuddyApp.screenSharingType(
                isProtectedContentWindow: false,
                showContent: false
            ),
            .readOnly
        )
        XCTAssertEqual(
            PasteBuddyApp.screenSharingType(
                isProtectedContentWindow: true,
                showContent: false
            ),
            .none
        )
        XCTAssertEqual(
            PasteBuddyApp.screenSharingType(
                isProtectedContentWindow: true,
                showContent: true
            ),
            .readOnly
        )
    }

    func testNestedShelfAuxiliaryWindowRequiresProtectedShelfMenuChain() {
        XCTAssertTrue(
            ClipboardShelfPanelController.shouldProtectNestedShelfAuxiliaryWindow(
                isShelfVisible: true,
                hidesShelfFromCapture: true,
                isCandidateAuxiliaryWindow: true,
                hasProtectedAuxiliaryWindow: true
            )
        )
        XCTAssertFalse(
            ClipboardShelfPanelController.shouldProtectNestedShelfAuxiliaryWindow(
                isShelfVisible: true,
                hidesShelfFromCapture: true,
                isCandidateAuxiliaryWindow: true,
                hasProtectedAuxiliaryWindow: false
            )
        )
        XCTAssertFalse(
            ClipboardShelfPanelController.shouldProtectNestedShelfAuxiliaryWindow(
                isShelfVisible: true,
                hidesShelfFromCapture: false,
                isCandidateAuxiliaryWindow: true,
                hasProtectedAuxiliaryWindow: true
            )
        )
    }

    func testAppDelegateFallsBackToDefaultReopenWhenDockHandlerIsMissing() {
        let delegate = AppDelegate()

        XCTAssertFalse(
            delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        )
        XCTAssertTrue(
            delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true)
        )
    }

    func testDevelopmentCommandAcceptsOnlyStablePanelURLs() throws {
        let shelf = try XCTUnwrap(PasteBuddyDevelopmentCommand(
            url: URL(string: "pastebuddy-dev://panel/shelf")!,
            bundleIdentifier: "com.alexjiang.PasteBuddy.dev"
        ))
        let sidePanel = try XCTUnwrap(PasteBuddyDevelopmentCommand(
            url: URL(string: "pastebuddy-dev://panel/side-panel")!,
            bundleIdentifier: "com.alexjiang.PasteBuddy.dev"
        ))
        XCTAssertEqual(shelf.displayMode.rawValue, ClipboardPanelDisplayMode.shelf.rawValue)
        XCTAssertEqual(sidePanel.displayMode.rawValue, ClipboardPanelDisplayMode.sidePanel.rawValue)
        XCTAssertNil(PasteBuddyDevelopmentCommand(
            url: URL(string: "pastebuddy-dev://panel/shelf")!,
            bundleIdentifier: "com.alexjiang.PasteBuddy"
        ))
        XCTAssertNil(PasteBuddyDevelopmentCommand(
            url: URL(string: "pastebuddy-dev://panel/unknown")!,
            bundleIdentifier: "com.alexjiang.PasteBuddy.dev"
        ))
        XCTAssertNil(PasteBuddyDevelopmentCommand(
            url: URL(string: "https://panel/shelf")!,
            bundleIdentifier: "com.alexjiang.PasteBuddy.dev"
        ))
        XCTAssertNil(PasteBuddyDevelopmentCommand(
            url: URL(string: "pastebuddy-dev://capture/static")!,
            bundleIdentifier: "com.alexjiang.PasteBuddy.dev"
        ))
        XCTAssertNil(PasteBuddyDevelopmentCommand(
            url: URL(string: "pastebuddy-dev://capture/long")!,
            bundleIdentifier: "com.alexjiang.PasteBuddy.dev"
        ))
        XCTAssertNil(PasteBuddyDevelopmentCommand(
            url: URL(string: "pastebuddy-dev://capture/pin-clipboard")!,
            bundleIdentifier: "com.alexjiang.PasteBuddy.dev"
        ))
    }

    func testDevelopmentPanelURLWaitsForTheAppDelegateHandler() {
        let delegate = AppDelegate()
        let url = URL(string: "pastebuddy-dev://panel/shelf")!
        var handledURLs: [URL] = []

        delegate.application(NSApplication.shared, open: [url])
        XCTAssertTrue(handledURLs.isEmpty)

        delegate.handleDevelopmentURL = { handledURLs.append($0) }
        XCTAssertEqual(handledURLs, [url])
    }

    func testDevelopmentControlsReuseTheInstalledDevAppWithoutBuildingOrInstalling() throws {
        let appSource = try sourceFileContents("Sources/PasteBuddy/App/PasteBuddyApp.swift")
        let buildScript = try sourceFileContents("script/build_and_run.sh")
        let openMode = try XCTUnwrap(buildScript.range(of: "--open-panel|open-panel)"))
        let signingSetup = try XCTUnwrap(buildScript.range(of: "CODESIGN_KEYCHAIN=\"$(resolve_code_sign_keychain)\""))
        let build = try XCTUnwrap(buildScript.range(of: "swift build"))

        XCTAssertLessThan(openMode.lowerBound, signingSetup.lowerBound)
        XCTAssertLessThan(openMode.lowerBound, build.lowerBound)
        XCTAssertTrue(buildScript.contains(
            "/usr/bin/open -a \"$STABLE_DEVELOPMENT_BUNDLE\" \"pastebuddy-dev://panel/$panel\""
        ))
        XCTAssertTrue(buildScript.contains("wait_for_single_installed_app"))
        XCTAssertTrue(buildScript.contains("PasteBuddySourceBranch"))
        XCTAssertTrue(buildScript.contains("PasteBuddySourceCommit"))
        XCTAssertTrue(buildScript.contains(
            "The development control may target only $STABLE_DEVELOPMENT_BUNDLE."
        ))
        XCTAssertTrue(buildScript.contains("Stable development app does not match the current integrated commit"))
        XCTAssertTrue(buildScript.contains("shelf|side-panel)"))
        XCTAssertTrue(buildScript.contains("CFBundleURLTypes"))
        XCTAssertTrue(buildScript.contains("\"CFBundleURLSchemes\":[\"pastebuddy-dev\"]"))
        XCTAssertFalse(buildScript.contains("--open-capture"))
        XCTAssertFalse(buildScript.contains("NSScreenCaptureUsageDescription"))
        XCTAssertFalse(buildScript.contains("/usr/bin/open \"pastebuddy-dev://panel/$panel\""))
        XCTAssertFalse(buildScript.contains("/usr/bin/open -n \"pastebuddy-dev://panel/$panel\""))
        XCTAssertTrue(appSource.contains("func application(_ application: NSApplication, open urls: [URL])"))
        XCTAssertTrue(appSource.contains("case .openPanel(let displayMode):"))
        XCTAssertFalse(appSource.contains("ScreenshotCapture"))
        XCTAssertFalse(appSource.contains("action.capture_screenshot"))
    }

    func testBuildAndRunCopiesXcode27CompiledLocalizationsIntoMainBundle() throws {
        let buildScript = try sourceFileContents("script/build_and_run.sh")
        let localizationScript = try sourceFileContents("script/copy_compiled_localizations.sh")

        XCTAssertTrue(buildScript.contains(
            "[[ -d \"$RESOURCE_BUNDLE\" ]] || die \"Missing SwiftPM resource bundle"
        ))
        XCTAssertTrue(buildScript.contains(
            "\"$ROOT_DIR/script/copy_compiled_localizations.sh\" \"$RESOURCE_BUNDLE\" \"$APP_RESOURCES\""
        ))
        XCTAssertTrue(localizationScript.contains("\"$RESOURCE_BUNDLE/Contents/Resources\""))
        XCTAssertTrue(localizationScript.contains("for locale in en zh-Hans"))
        XCTAssertTrue(localizationScript.contains("Missing compiled $locale localization"))
    }

    func testDockIconStaysHiddenForMenuBarRuntimeAndSettings() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/App/PasteBuddyApp.swift")
        let buildScript = try sourceFileContents("script/build_and_run.sh")
        let launchStart = try XCTUnwrap(source.range(of: "func applicationDidFinishLaunching"))
        let launchEnd = try XCTUnwrap(source.range(of: "func applicationShouldHandleReopen"))
        let launchSource = String(source[launchStart.lowerBound..<launchEnd.lowerBound])
        let settingsStart = try XCTUnwrap(source.range(of: "Settings {"))
        let settingsEnd = try XCTUnwrap(source.range(of: "private func configureAppDelegate()"))
        let settingsSource = String(source[settingsStart.lowerBound..<settingsEnd.lowerBound])

        XCTAssertTrue(buildScript.contains("<key>LSUIElement</key>\n  <true/>"))
        XCTAssertTrue(launchSource.contains("NSApp.setActivationPolicy(.accessory)"))
        XCTAssertFalse(launchSource.contains("NSApp.setActivationPolicy(.regular)"))
        XCTAssertFalse(settingsSource.contains("NSApp.setActivationPolicy(.regular)"))
    }

    func testPinAndOnboardingSymbolsExistOnTheSupportedSystem() {
        let symbols = [
            "doc.on.clipboard",
            "hand.raised.fill",
            "accessibility",
            "text.viewfinder",
            "character.bubble",
            "checkmark.circle.fill",
            "exclamationmark.triangle.fill",
            "lock.open.fill",
            "shield",
            "calendar",
            "calendar.badge.clock",
            "infinity",
            "person.2.fill",
            "arrow.clockwise",
            "arrow.right",
            "xmark",
            "pin.square",
            "pin.square.fill",
            "eye",
            "eye.slash",
            "arrow.uturn.backward",
            "square.and.arrow.down",
            "xmark.rectangle",
            "cursorarrow.rays",
            "square.stack.3d.up",
            "photo",
        ]

        for symbol in symbols {
            XCTAssertNotNil(
                NSImage(systemSymbolName: symbol, accessibilityDescription: symbol),
                "Missing SF Symbol: \(symbol)"
            )
        }
    }

    func testRuntimeLoadGateInvokesAsyncLoadOnlyOnce() async {
        let gate = PasteBuddyRuntimeLoadGate()
        var loadAsyncCallCount = 0

        await gate.loadIfNeeded {
            loadAsyncCallCount += 1
        }
        await gate.loadIfNeeded {
            loadAsyncCallCount += 1
        }

        XCTAssertEqual(loadAsyncCallCount, 1)
    }

    func testRuntimeLoadGateCoalescesConcurrentCallersUntilLoadCompletes() async {
        let gate = PasteBuddyRuntimeLoadGate()
        var loadAsyncCallCount = 0
        var releaseLoad: CheckedContinuation<Void, Never>?
        var secondCallerReturned = false

        let first = Task { @MainActor in
            await gate.loadIfNeeded {
                loadAsyncCallCount += 1
                await withCheckedContinuation { releaseLoad = $0 }
            }
        }
        await Task.yield()
        let second = Task { @MainActor in
            await gate.loadIfNeeded {
                loadAsyncCallCount += 1
            }
            secondCallerReturned = true
        }
        await Task.yield()

        XCTAssertEqual(loadAsyncCallCount, 1)
        XCTAssertFalse(secondCallerReturned)
        releaseLoad?.resume()
        await first.value
        await second.value
        XCTAssertTrue(secondCallerReturned)
    }

    func testStatusItemIsInstalledBeforeHistoryLoadCanSuspendRuntimeStartup() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/App/PasteBuddyApp.swift")
        let runtimeStart = try XCTUnwrap(source.range(of: "private func startRuntimeIfNeeded() async"))
        let runtimeSource = source[runtimeStart.lowerBound...]
        let statusItem = try XCTUnwrap(runtimeSource.range(of: "configureStatusItemIfNeeded()"))
        let historyLoad = try XCTUnwrap(runtimeSource.range(of: "await storeLoadGate.loadIfNeeded"))

        XCTAssertLessThan(statusItem.lowerBound, historyLoad.lowerBound)
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

    func testDirectPasteUsesWriterOwnedFocusLifecycle() throws {
        let appSource = try sourceFileContents("Sources/PasteBuddy/App/PasteBuddyApp.swift")

        XCTAssertTrue(appSource.contains("targetBundleIdentifier: targetBundleIdentifier"))
        XCTAssertTrue(appSource.contains("activeApplicationBundleIdentifier: {\n                tracker.frontmostApplicationBundleIdentifier()"))
        XCTAssertTrue(appSource.contains("prepareForPaste: {\n                PasteBuddyDiagnostics.record(.directPaste, \"activateTargetRequested\""))
        XCTAssertFalse(appSource.contains("guard await tracker.waitForActivation("))
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

    func testSharedPanelPagingStateReachesAll501ItemsWithoutDuplicates() throws {
        let items = (0..<501).map { index in
            ClipboardItem(
                sourceAppName: "Notes",
                deviceName: "Test Mac",
                contentType: .text,
                title: "Paged \(index)",
                payload: ClipboardPayload(text: "payload \(index)")
            )
        }
        var paging = ClipboardPanelPagingState<ClipboardItem, Int>()

        paging.reset(
            with: Array(items.prefix(100)),
            totalCount: items.count,
            queryID: 1
        )
        XCTAssertEqual(paging.items.count, 100)
        XCTAssertTrue(paging.canLoadMore)

        for offset in stride(from: 100, to: items.count, by: 100) {
            let request = try XCTUnwrap(paging.nextPageRequest(for: 1))
            XCTAssertEqual(request.offset, offset)
            XCTAssertTrue(paging.append(
                Array(items.dropFirst(offset).prefix(100)),
                totalCount: items.count,
                for: request,
                currentQueryID: 1
            ))
        }

        XCTAssertEqual(paging.items.map(\.id), items.map(\.id))
        XCTAssertFalse(paging.canLoadMore)
        XCTAssertEqual(paging.nextOffset, 501)
    }

    func testSharedPanelPagingRejectsOldQueryResponseAfterReset() throws {
        let items = (0..<200).map { index in
            ClipboardItem(
                sourceAppName: "Notes",
                deviceName: "Test Mac",
                contentType: .text,
                title: "Query \(index)",
                payload: ClipboardPayload(text: "payload \(index)")
            )
        }
        var paging = ClipboardPanelPagingState<ClipboardItem, Int>()
        paging.reset(with: Array(items.prefix(100)), totalCount: 200, queryID: 1)
        let oldRequest = try XCTUnwrap(paging.nextPageRequest(for: 1))

        paging.reset(with: Array(items.prefix(20)), totalCount: 20, queryID: 2)

        XCTAssertNil(paging.nextPageRequest(for: 1))
        XCTAssertFalse(paging.append(
            Array(items.dropFirst(100)),
            totalCount: 200,
            for: oldRequest,
            currentQueryID: 2
        ))
        XCTAssertEqual(paging.items.map(\.id), Array(items.prefix(20)).map(\.id))
    }

    func testBothPanelModesLoadSubsequentPagesThroughSharedPagingState() throws {
        let shelfSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let sideSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardSidePanelView.swift")

        for source in [shelfSource, sideSource] {
            XCTAssertTrue(source.contains("@State private var paging = ClipboardPanelPagingState<ClipboardItem,"))
            XCTAssertTrue(source.contains("store.filteredItemsPage("))
            XCTAssertTrue(source.contains("paging.nextPageRequest(for:"))
            XCTAssertTrue(source.contains("for: request,"))
            XCTAssertTrue(source.contains("paging.canLoadMore"))
        }
        XCTAssertTrue(shelfSource.contains("onLastItemAppear:"))
        XCTAssertTrue(sideSource.contains("onLastItemAppear:"))
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

    func testShelfShiftSelectionExtendsFromTheExistingAnchor() {
        let first = makeShelfItem(title: "First")
        let second = makeShelfItem(title: "Second")
        let third = makeShelfItem(title: "Third")
        let interaction = ShelfInteractionModel(items: [first, second, third])

        interaction.selectSingle(first.id)
        interaction.extendSelection(by: 1)
        XCTAssertEqual(interaction.selectedIDs, [first.id, second.id])
        XCTAssertEqual(interaction.primarySelectedID, second.id)

        interaction.extendSelection(by: 1)
        XCTAssertEqual(interaction.selectedIDs, [first.id, second.id, third.id])
        XCTAssertEqual(interaction.primarySelectedID, third.id)
        XCTAssertEqual(interaction.selectionAnchorID, first.id)

        interaction.extendSelection(by: -1)
        XCTAssertEqual(interaction.selectedIDs, [first.id, second.id])
        interaction.extendSelection(by: -1)
        interaction.extendSelection(by: -1)
        XCTAssertEqual(interaction.selectedIDs, [first.id])

        interaction.selectSingle(third.id)
        interaction.extendSelection(by: -1)
        XCTAssertEqual(interaction.selectedIDs, [second.id, third.id])
        XCTAssertEqual(interaction.primarySelectedID, second.id)
        XCTAssertEqual(interaction.selectionAnchorID, third.id)
    }

    func testShelfAndSidePanelRouteShiftArrowToRangeSelection() throws {
        let controllerSource = try sourceFileContents("Sources/PasteBuddy/App/ClipboardShelfPanelController.swift")
        for path in [
            "Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift",
            "Sources/PasteBuddy/Views/ClipboardSidePanelView.swift",
        ] {
            let source = try sourceFileContents(path)
            XCTAssertTrue(source.contains("NotificationCenter.default.publisher(for: .pasteBuddyPanelArrowKey)"))
            XCTAssertTrue(source.contains("handlePanelArrowKey(request)"))
            XCTAssertTrue(source.contains("extendSelection(by:"))
            XCTAssertFalse(source.contains("keyboardShortcut(.downArrow"))
            XCTAssertFalse(source.contains(".onMoveCommand(perform: handleShelfMoveCommand)"))
            XCTAssertFalse(source.contains(".onMoveCommand(perform: handleSidePanelMoveCommand)"))
        }
        XCTAssertTrue(controllerSource.contains("NSEvent.addLocalMonitorForEvents(matching: .keyDown)"))
        XCTAssertTrue(controllerSource.contains("event.window === panel"))
        XCTAssertTrue(controllerSource.contains("return request.isHandled ? nil : event"))
        XCTAssertTrue(controllerSource.contains("NSEvent.removeMonitor(localKeyDownMonitor)"))
    }

    func testClipboardPanelArrowKeyCommandUsesExactEventModifiers() {
        XCTAssertEqual(
            ClipboardPanelArrowKeyCommand.resolve(
                keyCode: UInt16(kVK_DownArrow),
                modifierFlags: [.function, .numericPad]
            ),
            ClipboardPanelArrowKeyCommand(offset: 1, extendsSelection: false)
        )
        XCTAssertEqual(
            ClipboardPanelArrowKeyCommand.resolve(
                keyCode: UInt16(kVK_UpArrow),
                modifierFlags: [.shift, .function]
            ),
            ClipboardPanelArrowKeyCommand(offset: -1, extendsSelection: true)
        )
        XCTAssertNil(
            ClipboardPanelArrowKeyCommand.resolve(
                keyCode: UInt16(kVK_RightArrow),
                modifierFlags: [.command]
            )
        )
        XCTAssertNil(
            ClipboardPanelArrowKeyCommand.resolve(
                keyCode: UInt16(kVK_ANSI_A),
                modifierFlags: []
            )
        )

        let request = ClipboardPanelArrowKeyRequest(
            command: ClipboardPanelArrowKeyCommand(offset: 1, extendsSelection: true)
        )
        XCTAssertFalse(request.isHandled)
        request.markHandled()
        XCTAssertTrue(request.isHandled)
    }

    func testClipboardPanelSpaceKeyRoutesPreviewAtTheWindowLevel() throws {
        XCTAssertTrue(
            ClipboardPanelPreviewKeyCommand.matches(
                keyCode: UInt16(kVK_Space),
                modifierFlags: []
            )
        )
        XCTAssertTrue(
            ClipboardPanelPreviewKeyCommand.matches(
                keyCode: UInt16(kVK_Space),
                modifierFlags: [.capsLock, .function, .numericPad]
            )
        )
        XCTAssertFalse(
            ClipboardPanelPreviewKeyCommand.matches(
                keyCode: UInt16(kVK_Space),
                modifierFlags: [.command]
            )
        )
        XCTAssertFalse(
            ClipboardPanelPreviewKeyCommand.matches(
                keyCode: UInt16(kVK_Return),
                modifierFlags: []
            )
        )

        let request = ClipboardPanelPreviewKeyRequest()
        XCTAssertFalse(request.isHandled)
        request.markHandled()
        XCTAssertTrue(request.isHandled)

        let controllerSource = try sourceFileContents("Sources/PasteBuddy/App/ClipboardShelfPanelController.swift")
        XCTAssertTrue(controllerSource.contains("ClipboardPanelPreviewKeyCommand.matches("))
        XCTAssertTrue(controllerSource.contains("NotificationCenter.default.post(name: .pasteBuddyPanelPreviewKey"))
        for path in [
            "Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift",
            "Sources/PasteBuddy/Views/ClipboardSidePanelView.swift",
        ] {
            let source = try sourceFileContents(path)
            XCTAssertTrue(source.contains("NotificationCenter.default.publisher(for: .pasteBuddyPanelPreviewKey)"))
            XCTAssertTrue(source.contains("toggleSelectedItemPreview()"))
            XCTAssertTrue(source.contains("!isSearchFocused"))
            XCTAssertTrue(source.contains("request.markHandled()"))
        }
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
    }

    func testPinnedShelfAndSidePanelDoNotDismissForOutsideClick() {
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

    func testBothPanelModesUseSharedPinStateAndPinnedPastePolicy() throws {
        let controllerSource = try sourceFileContents("Sources/PasteBuddy/App/ClipboardShelfPanelController.swift")
        let sources = try [
            sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift"),
            sourceFileContents("Sources/PasteBuddy/Views/ClipboardSidePanelView.swift")
        ]

        XCTAssertEqual(controllerSource.components(separatedBy: "isPinned: panelPinnedBinding()").count - 1, 2)
        XCTAssertTrue(controllerSource.contains("private func panelPinnedBinding() -> Binding<Bool>"))
        XCTAssertTrue(controllerSource.contains("guard !isPinned else { return }"))
        for source in sources {
            XCTAssertTrue(source.contains("@Binding var isPinned: Bool"))
            XCTAssertTrue(source.contains("setPinned(!effectivePinned)"))
            XCTAssertTrue(source.contains("ShelfToolbarCircleIcon(systemName: effectivePinned ? \"pin.fill\" : \"pin\")"))
            XCTAssertTrue(source.contains("let shouldDismissBeforePaste = !effectivePinned"))
            XCTAssertTrue(source.contains("dismissBeforePaste: shouldDismissBeforePaste"))
        }
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

    func testShelfPlacementFramesStayInsideVisibleFrameAtTopOrBottom() {
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
            CGRect(x: -100, y: 111, width: 1512, height: 330)
        )
    }

    @MainActor
    func testApplyingShelfFrameKeepsHostingContentInsidePanelBounds() {
        let frame = CGRect(x: -1512, y: -215, width: 1512, height: 350)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(
            rootView: VStack {
                Text("Header")
                Spacer()
                Text("Footer")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("shelf-geometry-probe")
        )
        panel.contentView?.setFrameSize(CGSize(width: 1512, height: 440))
        panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.frame, frame)
        XCTAssertEqual(panel.contentView?.frame.height, 440)

        ClipboardShelfPanelController.applyPanelFrame(frame, to: panel, display: false)

        XCTAssertEqual(panel.frame, frame)
        XCTAssertEqual(panel.contentView?.frame, CGRect(origin: .zero, size: frame.size))
        XCTAssertTrue(panel.accessibilityFrame().contains(panel.contentView?.accessibilityFrame() ?? .null))
    }

    func testShelfLayoutPolicyContainsEveryRegionAndCardAcrossDisplays() {
        let shelfSource = try? sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let controllerSource = try? sourceFileContents("Sources/PasteBuddy/App/ClipboardShelfPanelController.swift")
        XCTAssertTrue(shelfSource?.contains(".onChange(of: visibleActiveFilterSummaries.count)") == true)
        XCTAssertTrue(shelfSource?.contains("onLayoutChange()") == true)
        XCTAssertTrue(controllerSource?.contains("self.positionVisiblePanel(panel)") == true)

        let displays: [(frame: CGRect, visible: CGRect)] = [
            (
                CGRect(x: 0, y: 0, width: 1440, height: 900),
                CGRect(x: 0, y: 25, width: 1440, height: 850)
            ),
            (
                CGRect(x: -1920, y: -120, width: 1920, height: 1080),
                CGRect(x: -1920, y: -80, width: 1920, height: 1010)
            ),
            (
                CGRect(x: -1512, y: -278, width: 1512, height: 982),
                CGRect(x: -1512, y: -215, width: 1512, height: 887)
            ),
            (
                CGRect(x: 1440, y: 0, width: 2560, height: 1440),
                CGRect(x: 1440, y: 24, width: 2560, height: 1370)
            )
        ]
        let backingScales: [CGFloat] = [1, 2, 3]
        let contentTypes = ClipboardContentType.allCases
        let requiredHeight = ClipboardShelfMetrics.requiredPanelHeight(showsActiveFilters: true)

        for display in displays {
            for placement in [ClipboardShelfPlacement.top, .bottom] {
                let panel = ClipboardShelfPanelController.attachedFrame(
                    for: placement,
                    screenFrame: display.frame,
                    visibleFrame: display.visible,
                    height: requiredHeight
                )
                XCTAssertTrue(display.visible.contains(panel))

                let localBounds = CGRect(origin: .zero, size: panel.size)
                let regions = ClipboardShelfMetrics.verticalRegions(
                    in: localBounds,
                    showsActiveFilters: true
                )
                XCTAssertNotNil(regions)
                guard let regions else { continue }

                XCTAssertTrue(localBounds.contains(regions.header))
                XCTAssertTrue(localBounds.contains(regions.shelf))
                XCTAssertTrue(localBounds.contains(regions.footer))
                XCTAssertLessThanOrEqual(regions.shelf.maxY, regions.header.minY)
                XCTAssertLessThanOrEqual(regions.footer.maxY, regions.shelf.minY)
                XCTAssertEqual(regions.shelf.height, ClipboardShelfMetrics.shelfHeight)

                for scale in backingScales {
                    for _ in contentTypes {
                        let card = CGRect(
                            x: 0,
                            y: regions.shelf.midY - ClipboardShelfMetrics.cardHeight / 2,
                            width: ClipboardShelfMetrics.cardWidth,
                            height: ClipboardShelfMetrics.cardHeight
                        )
                        XCTAssertTrue(regions.shelf.contains(card))
                        XCTAssertEqual(
                            (card.minY - regions.shelf.minY) * scale,
                            (regions.shelf.maxY - card.maxY) * scale,
                            accuracy: 0.001
                        )
                    }
                }

                for imageSize in [
                    CGSize(width: 1600, height: 900),
                    CGSize(width: 900, height: 1600),
                    CGSize(width: 1200, height: 1200)
                ] {
                    let fitted = ClipboardImagePreviewLayout.aspectFitFrame(
                        for: imageSize,
                        in: CGRect(
                            x: 0,
                            y: 0,
                            width: ClipboardShelfMetrics.cardWidth,
                            height: ClipboardShelfMetrics.cardPreviewHeight
                        )
                    )
                    XCTAssertTrue(
                        CGRect(
                            x: 0,
                            y: 0,
                            width: ClipboardShelfMetrics.cardWidth,
                            height: ClipboardShelfMetrics.cardPreviewHeight
                        ).contains(fitted)
                    )
                    XCTAssertEqual(fitted.width / fitted.height, imageSize.width / imageSize.height, accuracy: 0.001)
                }
            }
        }
    }

    func testShelfAndSidePanelShareSourceFilterStateAndTokenSemantics() throws {
        let shelf = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let side = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardSidePanelView.swift")
        let sources = [shelf, side]
        let sharedRequirements = [
            "ClipboardSourceAppFilterToken(appName: sourceAppFilter)",
            "store.applySourceAppSuggestion(appName)",
            "store.clearSourceAppFilter()",
            "ClipboardPanelFiltersMenu(store: store)",
            "store.selectedScope = scope",
            "store.selectSingleItem(item.id)",
            "ClipboardPanelHistoryAvailability.visibleItems(",
            "PinboardItemDragPayload.itemProvider(",
            "ShelfExpandedPreview("
        ]

        for source in sources {
            for requirement in sharedRequirements {
                XCTAssertTrue(source.contains(requirement), "Missing shared panel semantic: \(requirement)")
            }
            XCTAssertFalse(source.contains("store.searchQuery = \"\"\\n            store.clearFilters()"))
        }
        XCTAssertEqual(
            sources.filter { $0.contains("struct ClipboardSourceAppFilterToken: View") }.count,
            1
        )

        let parityMatrix: [(semantic: String, shelf: [String], side: [String])] = [
            ("search", ["$store.searchQuery", "action.clear_search"], ["$store.searchQuery", "action.clear_search"]),
            ("scope/category", ["SmartPinboardCategory.allCases", "store.userPinboards", ".pasteStack"], ["SmartPinboardCategory.allCases", "store.userPinboards", ".pasteStack"]),
            ("selection/keyboard", ["selectOffset(request.command.offset)", "handleShelfKeyPress"], ["selectOffset(request.command.offset)", "handleKeyPress"]),
            ("metadata", ["SourceApplicationIconBadge", "HistoryCardTimestampAdapter.presentation"], ["SourceApplicationIconBadge", "HistoryCardTimestampAdapter.presentation"]),
            ("context actions", ["action.paste", "action.copy", "action.pin_to_screen", "action.delete"], ["action.paste", "action.copy", "action.pin_to_screen", "action.delete"]),
            ("paste/drag", ["onDoubleClick:", "directPasteItem", "PinboardItemDragPayload.itemProvider"], ["onDoubleClick:", "directPasteItem", "PinboardItemDragPayload.itemProvider"]),
            ("preview", ["ShelfExpandedPreview(", "ClipboardPreparedPreview.prepare("], ["ShelfExpandedPreview(", "ClipboardPreparedPreview.prepare("]),
            ("paging/count", ["loadNextShelfPage()", "paging.totalCount"], ["loadNextSidePage()", "paging.totalCount"]),
            ("loading/error", ["isHistoryQueryTransitioning", "historyQueryErrorMessage"], ["isHistoryQueryTransitioning", "historyQueryErrorMessage"]),
            ("pin/dismiss", ["setPinned(!effectivePinned)", "onDismissImmediately"], ["setPinned(!effectivePinned)", "onDismissImmediately"]),
            ("accessibility", [".accessibilityLabel(", "NSLocalizedString"], [".accessibilityLabel(", "NSLocalizedString"])
        ]
        for row in parityMatrix {
            for token in row.shelf {
                XCTAssertTrue(shelf.contains(token), "Shelf parity missing \(row.semantic): \(token)")
            }
            for token in row.side {
                XCTAssertTrue(side.contains(token), "Side parity missing \(row.semantic): \(token)")
            }
        }
    }

    func testSourceAppSuggestionPanelExposesRowsAndRoutesPointerAccessibilityAndKeyboardSelection() throws {
        var selectedApps: [String] = []
        let view = NativeSourceAppSuggestionView(
            frame: CGRect(
                x: 0,
                y: 0,
                width: 220,
                height: SourceAppSuggestionMetrics.panelHeight(for: 3)
            )
        )
        view.configure(appNames: ["Paste", "PasteBuddy", "Preview"], query: "Paste") {
            selectedApps.append($0)
        }
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.accessibilityRole(), .list)
        XCTAssertEqual(view.accessibilityIdentifier(), "source-app-suggestions")
        let rows = try XCTUnwrap(view.accessibilityChildren() as? [NativeSourceAppSuggestionRow])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map { $0.accessibilityRole() }, [.row, .row, .row])
        XCTAssertEqual(rows.map { $0.accessibilityLabel() }, ["Paste", "PasteBuddy", "Preview"])
        XCTAssertEqual(
            rows.map { $0.accessibilityIdentifier() },
            ["source-app-suggestion-Paste", "source-app-suggestion-PasteBuddy", "source-app-suggestion-Preview"]
        )

        for (index, row) in rows.enumerated() {
            XCTAssertEqual(row.frame.width, 220)
            let rowCenter = row.convert(
                CGPoint(x: row.bounds.midX, y: row.bounds.midY),
                to: view
            )
            XCTAssertTrue(row === view.hitTest(rowCenter))
            XCTAssertTrue(row.accessibilityPerformPress())
            XCTAssertEqual(selectedApps.last, ["Paste", "PasteBuddy", "Preview"][index])
        }
        XCTAssertTrue(view === view.hitTest(CGPoint(x: 110, y: 1)))
        XCTAssertTrue(view === view.hitTest(CGPoint(x: 110, y: view.bounds.maxY - 1)))
        XCTAssertNil(view.hitTest(CGPoint(x: -1, y: 1)))

        view.moveSelection(by: 1)
        view.activateSelectedSuggestion()
        XCTAssertEqual(selectedApps.last, "PasteBuddy")
        view.moveSelection(by: 10)
        view.activateSelectedSuggestion()
        XCTAssertEqual(selectedApps.last, "Preview")

        XCTAssertEqual(
            SourceAppSuggestionKeyCommand.resolve(specialKey: .upArrow, keyCode: 0, modifierFlags: []),
            .move(offset: -1)
        )
        XCTAssertEqual(
            SourceAppSuggestionKeyCommand.resolve(specialKey: .downArrow, keyCode: 0, modifierFlags: []),
            .move(offset: 1)
        )
        XCTAssertEqual(
            SourceAppSuggestionKeyCommand.resolve(specialKey: .carriageReturn, keyCode: 0, modifierFlags: []),
            .select
        )
        XCTAssertEqual(
            SourceAppSuggestionKeyCommand.resolve(specialKey: nil, keyCode: 53, modifierFlags: []),
            .dismiss
        )
        XCTAssertNil(
            SourceAppSuggestionKeyCommand.resolve(specialKey: .downArrow, keyCode: 0, modifierFlags: .command)
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let anchor = NSView(frame: NSRect(x: 20, y: 160, width: 220, height: 38))
        window.contentView = anchor
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        var dismissed = false
        let coordinator = SourceAppSuggestionPanelPresenter.Coordinator()
        coordinator.update(
            anchorView: anchor,
            isPresented: true,
            appNames: ["Paste", "PasteBuddy", "Preview"],
            query: "Paste",
            width: 220,
            onSelect: { selectedApps.append($0) },
            onDismiss: { dismissed = true }
        )
        XCTAssertTrue(coordinator.isKeyboardMonitoring)
        coordinator.handleKeyboardCommand(.move(offset: 1))
        coordinator.handleKeyboardCommand(.select)
        XCTAssertEqual(selectedApps.last, "PasteBuddy")
        coordinator.handleKeyboardCommand(.dismiss)
        XCTAssertTrue(dismissed)
        XCTAssertFalse(coordinator.isKeyboardMonitoring)
        coordinator.update(
            anchorView: anchor,
            isPresented: true,
            appNames: ["Paste", "PasteBuddy", "Preview"],
            query: "Paste",
            width: 220,
            onSelect: { selectedApps.append($0) },
            onDismiss: { dismissed = true }
        )
        XCTAssertTrue(coordinator.isKeyboardMonitoring)
        coordinator.closeImmediately()
        XCTAssertFalse(coordinator.isKeyboardMonitoring)
    }

    func testShelfExpandedPreviewKeepsKeyboardSelectionAndOmitsChrome() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let previewStart = try XCTUnwrap(source.range(of: "struct ShelfExpandedPreview"))
        let imageStart = try XCTUnwrap(source.range(of: "private struct ShelfExpandedImagePreview"))
        let previewSource = String(source[previewStart.lowerBound..<imageStart.lowerBound])

        XCTAssertFalse(source.contains("import Carbon"))
        XCTAssertFalse(source.contains("private struct ShelfPreviewKeyboardHandler"))
        XCTAssertFalse(source.contains("window?.makeFirstResponder(self)"))
        XCTAssertFalse(source.contains("case kVK_DownArrow:"))
        XCTAssertTrue(previewSource.contains("@FocusState private var isPreviewFocused"))
        XCTAssertTrue(previewSource.contains(".focusable(true)"))
        XCTAssertTrue(previewSource.contains(".focused($isPreviewFocused)"))
        XCTAssertTrue(previewSource.contains("await Task.yield()"))
        XCTAssertTrue(previewSource.contains("isPreviewFocused = true"))
        XCTAssertFalse(previewSource.contains(".onMoveCommand(perform: onMove)"))
        XCTAssertTrue(previewSource.contains(".onMoveCommand(perform: handlePreviewMoveCommand)"))
        XCTAssertTrue(previewSource.contains("private func handlePreviewMoveCommand(_ direction: MoveCommandDirection)"))
        XCTAssertTrue(previewSource.contains("requestPreviewFocus()"))
        XCTAssertTrue(previewSource.contains(".onKeyPress(phases: .down, action: handlePreviewKeyPress)"))
        XCTAssertTrue(previewSource.contains("private func handlePreviewKeyPress(_ keyPress: KeyPress) -> KeyPress.Result"))
        XCTAssertTrue(previewSource.contains("case .upArrow:"))
        XCTAssertTrue(previewSource.contains("case .downArrow:"))
        XCTAssertTrue(previewSource.contains("clipboard-expanded-preview-"))
        XCTAssertTrue(previewSource.contains(".pasteBuddyGlassSurface(cornerRadius: 18, glassTintOpacity: 0, showsStroke: false)"))
        XCTAssertTrue(previewSource.contains("previewText(ClipboardPlainTextRenderer.plainText(for: item))"))
        XCTAssertFalse(previewSource.contains("Label(localized(item.presentationContentType.displayName)"))
        XCTAssertFalse(previewSource.contains("SourceApplicationIconBadge(item: item, size: 24)"))
        XCTAssertFalse(previewSource.contains("Text(footnote)"))
        XCTAssertFalse(previewSource.contains("item.openableURL"))
        XCTAssertFalse(previewSource.contains("TextEditor(text:"))
        XCTAssertFalse(previewSource.contains(".textSelection(.enabled)"))
        XCTAssertFalse(previewSource.contains("onSaveText"))
        XCTAssertFalse(previewSource.contains("Button(\"action.save_text\")"))
        XCTAssertFalse(previewSource.contains("strokeBorder(tint.opacity"))
        XCTAssertFalse(previewSource.contains("Color(nsColor: .textBackgroundColor)"))
        XCTAssertFalse(previewSource.contains(".background(.regularMaterial)"))
        XCTAssertTrue(previewSource.contains(".scrollContentBackground(.hidden)"))
    }

    func testShelfCardsOmitBottomMetadataFooter() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let cardStart = try XCTUnwrap(source.range(of: "private struct ClipboardShelfCardVisual"))
        let selectionRingStart = try XCTUnwrap(source.range(of: "private struct ClipboardShelfCardSelectionRing"))
        let cardSource = String(source[cardStart.lowerBound..<selectionRingStart.lowerBound])

        XCTAssertTrue(source.contains("static let cardPreviewHeight: CGFloat = cardHeight - cardHeaderHeight"))
        XCTAssertFalse(cardSource.contains("footer"))
        XCTAssertFalse(cardSource.contains("Text(item.sourceAppName)"))
        XCTAssertFalse(cardSource.contains("Text(footnote)"))
        XCTAssertFalse(cardSource.contains("footerTitle"))
        XCTAssertFalse(cardSource.contains("item.ocrState.displayName"))
        XCTAssertFalse(cardSource.contains("format.chars"))
    }

    func testPreviewPresentationUsesSwiftUICollectionPopoverForShelfAndSidePanel() throws {
        let shelfSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let sideSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardSidePanelView.swift")
        let collectionSource = try sourceFileContents("Sources/PasteBuddy/Views/SwiftUIShelfCollection.swift")
        let dragSource = try sourceFileContents("Sources/PasteBuddy/Models/PinboardItemDragPayload.swift")

        let shelfCardStart = try XCTUnwrap(shelfSource.range(of: "private struct ClipboardShelfCard: View"))
        let shelfPreviewStart = try XCTUnwrap(shelfSource.range(of: "struct ShelfExpandedPreview"))
        let shelfCardSource = String(shelfSource[shelfCardStart.lowerBound..<shelfPreviewStart.lowerBound])

        let sideRowStart = try XCTUnwrap(sideSource.range(of: "private struct ClipboardSidePanelListRow: View"))
        let sidePreviewStart = try XCTUnwrap(sideSource.range(of: "private struct ClipboardSidePanelContentPreview"))
        let sideRowSource = String(sideSource[sideRowStart.lowerBound..<sidePreviewStart.lowerBound])

        XCTAssertTrue(shelfSource.contains("previewedID: shelfInteraction.previewedID"))
        XCTAssertTrue(shelfSource.contains("SwiftUIShelfCollection("))
        XCTAssertTrue(shelfSource.contains("direction: .horizontal"))
        XCTAssertTrue(shelfSource.contains("previewArrowEdge: .bottom"))
        XCTAssertTrue(shelfSource.contains("shelfInteraction.dismissPreview(for: id)"))
        XCTAssertTrue(shelfSource.contains("previewContent: { displayItem in"))
        XCTAssertTrue(shelfSource.contains("ClipboardPreparedPreview.prepare(\n                item: item,\n                hydrateItem: store.hydratedItem"))
        XCTAssertTrue(shelfSource.contains("dragItemProvider: { displayItem in"))
        XCTAssertTrue(shelfSource.contains("PinboardItemDragPayload.itemProvider("))
        XCTAssertFalse(shelfSource.contains("dragPayload: { displayItem in"))
        XCTAssertFalse(shelfSource.contains("ShelfCollectionRepresentable"))
        XCTAssertFalse(shelfSource.contains("previewPreferredEdge: .maxY"))
        XCTAssertFalse(shelfSource.contains(".popover(isPresented: isShelfPreviewPresented"))
        XCTAssertFalse(shelfSource.contains("private var previewedShelfItem"))
        XCTAssertFalse(shelfCardSource.contains(".popover("))
        XCTAssertFalse(shelfCardSource.contains("@Binding var isPreviewPresented"))

        XCTAssertTrue(sideSource.contains("previewedID: interaction.previewedID"))
        XCTAssertTrue(sideSource.contains("SwiftUIShelfCollection("))
        XCTAssertTrue(sideSource.contains("direction: .vertical"))
        XCTAssertTrue(sideSource.contains("previewArrowEdge: .trailing"))
        XCTAssertTrue(sideSource.contains("interaction.dismissPreview(for: id)"))
        XCTAssertFalse(sideSource.contains("ShelfCollectionRepresentable"))
        XCTAssertFalse(sideSource.contains("previewPreferredEdge: .minX"))
        XCTAssertFalse(sideSource.contains("previewAvoidsContainingWindowOverlap: true"))
        XCTAssertTrue(sideSource.contains("maxWidth: ClipboardSidePanelMetrics.previewMaxWidth"))
        XCTAssertTrue(sideSource.contains("previewContent: { item in"))
        XCTAssertTrue(sideSource.contains("ClipboardPreparedPreview.prepare(\n                item: item,\n                hydrateItem: store.hydratedItem"))
        XCTAssertTrue(sideSource.contains("dragItemProvider: { item in"))
        XCTAssertTrue(sideSource.contains("PinboardItemDragPayload.itemProvider("))
        XCTAssertFalse(sideSource.contains("dragPayload: { item in"))
        XCTAssertFalse(sideSource.contains("private var previewedSideItem: ClipboardItem?"))
        XCTAssertFalse(sideSource.contains("private func sidePreview(_ item: ClipboardItem) -> some View"))
        XCTAssertFalse(sideSource.contains("if let item = previewedSideItem"))
        XCTAssertTrue(collectionSource.contains("ScrollViewReader"))
        XCTAssertTrue(collectionSource.contains("ScrollView(.horizontal)"))
        XCTAssertTrue(collectionSource.contains("LazyHStack(spacing: spacing)"))
        XCTAssertTrue(collectionSource.contains("ScrollView(.vertical)"))
        XCTAssertTrue(collectionSource.contains("LazyVStack(spacing: spacing)"))
        XCTAssertTrue(collectionSource.contains(".popover("))
        XCTAssertTrue(collectionSource.contains("attachmentAnchor: .rect(.bounds)"))
        XCTAssertTrue(collectionSource.contains("isPresented: presentedPreviewBinding(for: itemID)"))
        XCTAssertTrue(collectionSource.contains("@State private var presentedPreviewID"))
        XCTAssertTrue(collectionSource.contains(".id(\"\\(itemID.uuidString):\\(previewPresentationGeneration)\")"))
        XCTAssertTrue(collectionSource.contains("private func syncPresentedPreview()"))
        XCTAssertTrue(collectionSource.contains("await Task.yield()"))
        XCTAssertGreaterThanOrEqual(
            collectionSource.components(separatedBy: "previewPresentationGeneration &+= 1").count - 1,
            2
        )
        XCTAssertTrue(collectionSource.contains("onPreviewDismiss(id)"))
        XCTAssertTrue(collectionSource.contains("proxy.scrollTo(primarySelectedID)"))
        XCTAssertFalse(collectionSource.contains("anchor: .center"))
        XCTAssertTrue(collectionSource.contains("var dragItemProvider: ((Item) -> NSItemProvider?)?"))
        XCTAssertTrue(collectionSource.contains(".onDrag { provider }"))
        XCTAssertFalse(collectionSource.contains(".draggable(payload)"))
        XCTAssertTrue(collectionSource.contains(".onTapGesture(count: 2)"))
        XCTAssertTrue(collectionSource.contains(".simultaneousGesture("))
        XCTAssertFalse(collectionSource.contains(".onTapGesture {"))
        XCTAssertFalse(collectionSource.contains("NSViewRepresentable"))
        XCTAssertFalse(collectionSource.contains("NSCollectionView"))
        XCTAssertFalse(collectionSource.contains("NSScrollView"))
        XCTAssertFalse(collectionSource.contains("NSPopover"))
        XCTAssertFalse(collectionSource.contains("NSPanel"))
        XCTAssertFalse(collectionSource.contains("NSEvent"))
        XCTAssertFalse(collectionSource.contains("positioningRect"))
        XCTAssertFalse(collectionSource.contains("ShelfExternalPreviewPanel"))
        XCTAssertFalse(collectionSource.contains("ShelfExternalPreviewArrow"))
        XCTAssertFalse(collectionSource.contains("NSPanel"))
        XCTAssertFalse(sideSource.contains(".popover(isPresented: previewPresentationBinding"))
        XCTAssertFalse(sideSource.contains("private func previewPresentationBinding"))
        XCTAssertFalse(sideSource.contains(".popover(isPresented: isPreviewPresented, arrowEdge: .trailing)"))
        XCTAssertFalse(sideSource.contains("private var previewedItem: ClipboardItem?"))
        XCTAssertFalse(sideRowSource.contains(".popover("))
        XCTAssertFalse(sideRowSource.contains("@Binding var isPreviewPresented"))
        XCTAssertTrue(dragSource.contains("struct PinboardItemDragPayload: Codable, Transferable"))
        XCTAssertTrue(dragSource.contains("import CoreTransferable"))
        XCTAssertTrue(dragSource.contains("CodableRepresentation(contentType: .pasteBuddyPinboardItemIDs)"))
        XCTAssertTrue(dragSource.contains("PasteboardWriter.itemProviders(for: [item], hydrate: hydrate)"))
        XCTAssertTrue(dragSource.contains("provider.registerDataRepresentation("))
        XCTAssertFalse(dragSource.contains("ProxyRepresentation"))
        XCTAssertFalse(dragSource.contains("ClipboardItemDragProvider"))
    }

    func testImageCardDragProviderPublishesNativeImageBeforePlainTextFallback() async throws {
        let image = makeTestImage(width: 2, height: 2) { _, _ in
            (red: 0, green: 122, blue: 255, alpha: 255)
        }
        let item = ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Copied image",
            payload: ClipboardPayload(imageData: try XCTUnwrap(image.tiffRepresentation))
        )
        let provider = try XCTUnwrap(PinboardItemDragPayload.itemProvider(for: item) { $0 })
        let identifiers = provider.registeredTypeIdentifiers

        let imageIndex = try XCTUnwrap(identifiers.firstIndex(of: UTType.tiff.identifier))
        let internalIndex = try XCTUnwrap(
            identifiers.firstIndex(of: UTType.pasteBuddyPinboardItemIDs.identifier)
        )
        let textIndex = try XCTUnwrap(
            identifiers.firstIndex(of: UTType.utf8PlainText.identifier)
        )
        XCTAssertLessThan(imageIndex, internalIndex)
        XCTAssertLessThan(internalIndex, textIndex)
        XCTAssertFalse(identifiers.contains(UTType.plainText.identifier))
        let fallbackData = try await loadData(
            from: provider,
            typeIdentifier: UTType.utf8PlainText.identifier
        )
        XCTAssertEqual(String(decoding: fallbackData, as: UTF8.self), "Copied image")

        let payloadData = try await loadData(
            from: provider,
            typeIdentifier: UTType.pasteBuddyPinboardItemIDs.identifier
        )
        XCTAssertEqual(
            try JSONDecoder().decode(PinboardItemDragPayload.self, from: payloadData).ids,
            [item.id]
        )
        let textItem = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Copied text",
            payload: ClipboardPayload(text: "plain drag payload")
        )
        let textProvider = try XCTUnwrap(PinboardItemDragPayload.itemProvider(for: textItem) { $0 })
        XCTAssertTrue(textProvider.canLoadObject(ofClass: NSString.self))
    }

    func testMultiFileCardDragPreservesAllPathsThroughExistingTextRepresentation() async throws {
        let firstURL = URL(fileURLWithPath: "/private/tmp/first-drag-file.txt")
        let secondURL = URL(fileURLWithPath: "/private/tmp/second-drag-file.txt")
        let item = ClipboardItem(
            sourceAppName: "Finder",
            deviceName: "Test Mac",
            contentType: .file,
            title: "Two files",
            payload: ClipboardPayload(
                fileURLStrings: [firstURL.absoluteString, secondURL.absoluteString]
            )
        )
        let provider = try XCTUnwrap(PinboardItemDragPayload.itemProvider(for: item) { $0 })
        let textData = try await loadData(
            from: provider,
            typeIdentifier: UTType.utf8PlainText.identifier
        )
        let text = String(decoding: textData, as: UTF8.self)

        XCTAssertTrue(text.contains(firstURL.path))
        XCTAssertTrue(text.contains(secondURL.path))
    }

    func testSidePanelPreviewFollowsSelectionWithoutDeferredHandoff() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardSidePanelView.swift")

        XCTAssertTrue(source.contains("selectSingleItem(nextItem.id)"))
        XCTAssertTrue(source.contains("prepareAndPresentPreview(for: nextItem)"))
        XCTAssertTrue(source.contains("interaction.selectSingle(id, keepsPreviewOpen: keepsPreviewOpen)"))
        XCTAssertFalse(source.contains("pendingPreviewSelectionID"))
        XCTAssertFalse(source.contains("previewScrollTargetID"))
        XCTAssertFalse(source.contains("cancelPreviewFollow"))
    }

    func testPanelModesShareDefaultSelectionAndTypeToSearchScaffold() throws {
        let shelfSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let sideSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardSidePanelView.swift")
        let controllerSource = try sourceFileContents("Sources/PasteBuddy/App/ClipboardShelfPanelController.swift")

        for source in [shelfSource, sideSource] {
            XCTAssertFalse(source.contains("store.searchQuery = \"\"\\n            store.clearFilters()"))
            XCTAssertTrue(source.contains("await Task.yield()"))
            XCTAssertTrue(source.contains("setSearchFocused(false)"))
            XCTAssertTrue(source.contains(".focusEffectDisabled()"))
            XCTAssertTrue(source.contains("NotificationCenter.default.publisher(for: .pasteBuddyPanelArrowKey)"))
            XCTAssertTrue(source.contains("private func handlePanelArrowKey(_ request: ClipboardPanelArrowKeyRequest)"))
            XCTAssertTrue(source.contains("selectOffset(request.command.offset)"))
            XCTAssertFalse(source.contains(".onMoveCommand(perform: moveSelection)"))
            XCTAssertTrue(source.contains("ClipboardPanelSearchInput.accepts(modifiers)"))
            XCTAssertTrue(source.contains("beginSearch(with: keyPress.characters)"))
            XCTAssertTrue(source.contains("ClipboardPanelSearchInput.accepts(characters)"))
            XCTAssertTrue(source.contains("store.searchQuery += characters"))
            XCTAssertTrue(source.contains("setSearchFocused(true)"))
            XCTAssertTrue(source.contains("onTextInput: beginSearch"))
            XCTAssertTrue(source.contains(".onChange(of: store.searchQuery)"))
            XCTAssertFalse(source.contains("previewFirstRenderedItem"))
            XCTAssertFalse(source.contains("previewsFirstItemWhenIdle"))
        }
        XCTAssertTrue(controllerSource.contains("private func resetPanelPresentationState()"))
        XCTAssertTrue(controllerSource.contains("store.searchQuery = \"\""))
        XCTAssertTrue(controllerSource.contains("store.clearFilters()"))
        XCTAssertTrue(controllerSource.contains("ClipboardPanelArrowKeyCommand.resolve("))
        XCTAssertTrue(controllerSource.contains("NotificationCenter.default.post(name: .pasteBuddyPanelArrowKey"))

        XCTAssertTrue(shelfSource.contains("store.setSelectedItemIDs("))
        XCTAssertTrue(sideSource.contains("store.setSelectedItemIDs("))
        XCTAssertTrue(shelfSource.contains("primaryID: shelfInteraction.primarySelectedID"))
        XCTAssertTrue(sideSource.contains("primaryID: interaction.primarySelectedID"))
        XCTAssertFalse(shelfSource.contains("scheduleStoreSelectionSync"))
        XCTAssertFalse(sideSource.contains("scheduleStoreSelectionSync"))
        XCTAssertFalse(shelfSource.contains("selectionSyncTask"))
        XCTAssertFalse(sideSource.contains("selectionSyncTask"))
        XCTAssertTrue(shelfSource.contains("refreshShelfItems()"))
        XCTAssertTrue(sideSource.contains("refreshSideItems()"))
        XCTAssertTrue(shelfSource.contains("struct SourceAppSuggestionPanelPresenter"))
        XCTAssertFalse(shelfSource.contains("private struct SourceAppSuggestionPanelPresenter"))
        XCTAssertTrue(shelfSource.contains("SourceAppSuggestionPanelPresenter("))
        XCTAssertFalse(shelfSource.contains("guard nextIndex != currentIndex else { return }"))
        XCTAssertFalse(sideSource.contains("guard nextIndex != currentIndex else { return }"))
        XCTAssertTrue(sideSource.contains("SourceAppSuggestionPanelPresenter("))
        XCTAssertTrue(sideSource.contains("sourceAppSuggestions(matching: store.searchQuery, limit: 3)"))
        XCTAssertTrue(sideSource.contains("store.applySourceAppSuggestion(appName)"))
        XCTAssertTrue(shelfSource.contains("enum ClipboardPanelSearchInput"))
        XCTAssertTrue(shelfSource.contains("modifiers.subtracting([.shift, .capsLock]).isEmpty"))
        XCTAssertTrue(shelfSource.contains("characters.rangeOfCharacter(from: .controlCharacters) == nil"))
        XCTAssertTrue(shelfSource.contains("let onTextInput: (String) -> Bool"))
        XCTAssertTrue(shelfSource.contains(".onKeyPress(phases: .down)"))
        XCTAssertTrue(shelfSource.contains("ClipboardPanelSearchInput.accepts(keyPress.modifiers)"))
        XCTAssertTrue(shelfSource.contains("onTextInput(keyPress.characters)"))
        XCTAssertFalse(shelfSource.contains("ShelfPreviewKeyboardHandler(onDismiss: onDismiss, onMove: onMove, onTextInput: onTextInput)"))
        XCTAssertFalse(shelfSource.contains("ClipboardPanelSearchInput.accepts(event.modifierFlags)"))
        XCTAssertEqual(
            shelfSource.components(separatedBy: "NSEvent.addLocalMonitorForEvents(matching: .keyDown)").count - 1,
            1
        )
        XCTAssertTrue(shelfSource.contains("event.window === self.parentWindow"))
        XCTAssertTrue(shelfSource.contains("NSEvent.removeMonitor(keyDownMonitor)"))
        XCTAssertTrue(controllerSource.contains("reloadPanelContent(panel)"))
        XCTAssertTrue(controllerSource.contains("hostingView.rootView = panelContentView()"))
        XCTAssertTrue(controllerSource.contains("panelPresentationID = UUID()"))
        XCTAssertTrue(controllerSource.contains(".id(panelPresentationID)"))
        XCTAssertTrue(controllerSource.contains("resetPanelPresentationState()"))
        XCTAssertTrue(controllerSource.contains("store.selectSingleItem(store.filteredItems(for: store.selectedScope).first?.id)"))
        XCTAssertTrue(controllerSource.contains("closeShelfAuxiliaryWindows()"))
        XCTAssertTrue(controllerSource.contains("for window in NSApp.windows where Self.isShelfAuxiliaryWindow(window)"))
    }

    func testShelfExpandedImagePreviewHydratesFullAssetAndOwnsContextualOCR() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let sideSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardSidePanelView.swift")
        let settingsSource = try sourceFileContents("Sources/PasteBuddy/Views/SettingsView.swift")
        let previewStart = try XCTUnwrap(source.range(of: "private var previewContent"))
        let imageStart = try XCTUnwrap(source.range(of: "private struct ShelfExpandedImagePreview"))
        let nextViewStart = try XCTUnwrap(source.range(of: "private struct ClipboardShelfCardVisual"))
        let expandedPreviewStart = try XCTUnwrap(source.range(of: "struct ShelfExpandedPreview"))
        let persistentShelfSource = String(source[..<expandedPreviewStart.lowerBound])
        let expandedPreviewSource = String(source[expandedPreviewStart.lowerBound..<imageStart.lowerBound])
        let previewContentSource = String(source[previewStart.lowerBound..<imageStart.lowerBound])
        let imagePreviewSource = String(source[imageStart.lowerBound..<nextViewStart.lowerBound])

        XCTAssertTrue(source.contains("import VisionKit"))
        XCTAssertTrue(imagePreviewSource.contains("ShelfLiveTextImagePreview("))
        XCTAssertTrue(imagePreviewSource.contains("ImageAnalysisOverlayView"))
        XCTAssertTrue(imagePreviewSource.contains("ImageAnalyzer().analyze"))
        XCTAssertTrue(imagePreviewSource.contains("analysis.hasResults(for: .text)"))
        XCTAssertTrue(imagePreviewSource.contains("preferredInteractionTypes = .textSelection"))
        XCTAssertTrue(imagePreviewSource.contains("trackingImageView = imageView"))
        XCTAssertTrue(imagePreviewSource.contains("imageView.addSubview(overlayView)"))
        XCTAssertTrue(imagePreviewSource.contains("selectableItemsHighlighted = true"))
        XCTAssertTrue(source.contains("struct ClipboardPreparedPreview"))
        XCTAssertTrue(source.contains("let hydrated = await hydrateItem(item)"))
        XCTAssertTrue(source.contains("NSImage(data: data)"))
        XCTAssertTrue(source.contains("var isPresentable: Bool"))
        XCTAssertTrue(source.contains("message.image_data_unavailable_for_preview"))
        XCTAssertFalse(expandedPreviewSource.contains("ProgressView(localized(\"state.loading_image\"))"))
        XCTAssertFalse(expandedPreviewSource.contains("await hydrateItemProvider(item)"))
        XCTAssertFalse(expandedPreviewSource.contains("cachedThumbnail(for: item"))
        XCTAssertTrue(imagePreviewSource.contains("Label(localized(\"action.recognize_text\"), systemImage: \"text.viewfinder\")"))
        XCTAssertFalse(imagePreviewSource.contains("OCRService().analyze"))
        XCTAssertFalse(imagePreviewSource.contains("ClipboardImagePreviewOCRResultView"))
        XCTAssertFalse(imagePreviewSource.contains("ClipboardImagePreviewOCR.copyRecognizedText"))
        XCTAssertFalse(imagePreviewSource.contains(".popover(isPresented:"))
        XCTAssertTrue(imagePreviewSource.contains(".textSelection(.enabled)"))
        XCTAssertEqual(
            imagePreviewSource.components(separatedBy: "liveTextActivation += 1").count - 1,
            1
        )
        XCTAssertFalse(persistentShelfSource.contains("action.recognize_text"))
        XCTAssertFalse(previewContentSource.contains("action.recognize_text"))
        XCTAssertFalse(sideSource.contains("action.recognize_text"))
        XCTAssertFalse(sideSource.contains("text.viewfinder"))
        XCTAssertFalse(sideSource.contains("ClipboardImagePreviewOCR"))
        XCTAssertFalse(sideSource.contains("updateOCRText"))
        XCTAssertFalse(settingsSource.contains("Label(localized(\"action.recognize_text\")"))
        XCTAssertFalse(settingsSource.contains("text.viewfinder"))
        XCTAssertTrue(source.contains("private var previewFrameWidth: CGFloat"))
        XCTAssertTrue(source.contains("private static let textPreviewHeight: CGFloat = 420"))
        XCTAssertTrue(source.contains(".frame(width: previewFrameWidth, height: previewFrameHeight, alignment: .topLeading)"))
        XCTAssertTrue(source.contains(".background(.regularMaterial)"))
        XCTAssertTrue(source.contains("var maxWidth: CGFloat = 640"))
        XCTAssertTrue(source.contains("max(320, min(maxWidth, 640))"))
        XCTAssertTrue(source.contains("private var imagePreviewBounds: CGSize"))
        XCTAssertTrue(source.contains("CGSize(width: max(1, previewWidthLimit - 28), height: 420)"))
        XCTAssertTrue(source.contains(".frame(height: Self.textPreviewHeight)"))
        XCTAssertTrue(source.contains(".frame(maxWidth: .infinity, alignment: .center)"))
        XCTAssertTrue(source.contains("imagePreviewDisplaySize.height + Self.imageActionAreaHeight + 28"))
        XCTAssertFalse(source.contains("private static let previewContentHeight"))
        XCTAssertTrue(source.contains("private var imagePreviewDisplaySize: CGSize?"))
        XCTAssertFalse(expandedPreviewSource.contains("private var isImageAssetPreview: Bool"))
        XCTAssertFalse(expandedPreviewSource.contains("if !isImageAssetPreview"))
        XCTAssertTrue(imagePreviewSource.contains("let displaySize: CGSize?"))
        XCTAssertTrue(imagePreviewSource.contains(".frame(width: resolvedDisplaySize.width, height: resolvedDisplaySize.height)"))
        XCTAssertFalse(imagePreviewSource.contains("strokeBorder(tint.opacity"))
        XCTAssertTrue(source.contains("ClipboardImageCache.fittedDisplaySize("))
        XCTAssertFalse(source.contains("import QuickLookUI"))
        XCTAssertFalse(imagePreviewSource.contains("QLPreviewView"))
        XCTAssertFalse(imagePreviewSource.contains("ShelfQuickLookPreviewFileStore"))
        XCTAssertFalse(imagePreviewSource.contains("ShelfQuickLookPreviews"))
        XCTAssertFalse(imagePreviewSource.contains("data.write(to:"))
        XCTAssertFalse(imagePreviewSource.contains(".frame(maxWidth: .infinity)"))
        XCTAssertFalse(previewContentSource.contains("if let text = item.payload.ocrText"))
        XCTAssertFalse(previewContentSource.contains("previewText(text)"))
        XCTAssertFalse(expandedPreviewSource.contains("\\(Int(imageSize.width)) x \\(Int(imageSize.height))"))
        XCTAssertFalse(imagePreviewSource.contains("TextEditor(text:"))
        XCTAssertFalse(imagePreviewSource.contains("Button(\"action.save_text\")"))
        XCTAssertFalse(imagePreviewSource.contains("ocrText"))
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

    func testImagePreviewAspectFitsWideTallPortraitAndLandscapeOnResize() {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 420)
        for imageSize in [
            CGSize(width: 4_000, height: 500),
            CGSize(width: 500, height: 4_000),
            CGSize(width: 1_080, height: 1_920),
            CGSize(width: 1_920, height: 1_080),
        ] {
            let frame = ClipboardImagePreviewLayout.aspectFitFrame(for: imageSize, in: bounds)
            XCTAssertTrue(bounds.insetBy(dx: -0.01, dy: -0.01).contains(frame))
            XCTAssertEqual(frame.width / frame.height, imageSize.width / imageSize.height, accuracy: 0.001)
            XCTAssertTrue(
                abs(frame.width - bounds.width) < 0.01 || abs(frame.height - bounds.height) < 0.01
            )
        }

        let resizedBounds = CGRect(x: 0, y: 0, width: 320, height: 180)
        let resized = ClipboardImagePreviewLayout.aspectFitFrame(
            for: CGSize(width: 1_080, height: 1_920),
            in: resizedBounds
        )
        XCTAssertTrue(resizedBounds.insetBy(dx: -0.01, dy: -0.01).contains(resized))
        XCTAssertEqual(
            resized.width / resized.height,
            CGFloat(1_080) / CGFloat(1_920),
            accuracy: 0.001
        )
    }

    func testImagePreviewHydratesRendersDismissesAndReopensPersistedAsset() async throws {
        let imageData = try XCTUnwrap(
            makeTestImage(width: 48, height: 32) { _, _ in
                (red: 25, green: 115, blue: 230, alpha: 255)
            }.tiffRepresentation
        )
        let lightweightItem = ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Persisted image",
            payload: ClipboardPayload(
                imageAssetID: "persisted-image",
                imageByteCount: imageData.count
            )
        )
        var hydratedItem = lightweightItem
        hydratedItem.payload.imageData = imageData
        var hydrationCount = 0

        for _ in 1...2 {
            let preparedPreview = await ClipboardPreparedPreview.prepare(
                item: lightweightItem
            ) { _ in
                hydrationCount += 1
                return hydratedItem
            }
            XCTAssertTrue(preparedPreview.isPresentable)
            XCTAssertNotNil(preparedPreview.image)
            XCTAssertNil(preparedPreview.imageLoadError)
            let preview = ShelfExpandedPreview(
                preparedPreview: preparedPreview,
                onDismiss: {},
                onMove: { _ in },
                onTextInput: { _ in false }
            )
            let hostingView = NSHostingView(rootView: preview)
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 520))
            hostingView.frame = container.bounds
            hostingView.autoresizingMask = NSView.AutoresizingMask.width.union(.height)
            container.addSubview(hostingView)
            let window = NSWindow(
                contentRect: container.bounds,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.contentView = container
            container.layoutSubtreeIfNeeded()

            for _ in 0..<5 {
                await Task.yield()
                container.layoutSubtreeIfNeeded()
            }
            XCTAssertTrue(containsRenderedImage(in: hostingView))

            window.contentView = NSView()
            await Task.yield()
        }

        XCTAssertEqual(hydrationCount, 2)
    }

    func testImagePreviewPreparationGatesPresentationOnHydratedImageOrExplicitError() async throws {
        let imageData = try XCTUnwrap(
            makeTestImage(width: 32, height: 24) { _, _ in
                (red: 12, green: 90, blue: 180, alpha: 255)
            }.tiffRepresentation
        )
        let lightweightItem = ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Repository image",
            payload: ClipboardPayload(imageAssetID: "repository-image")
        )
        var hydratedItem = lightweightItem
        hydratedItem.payload.imageData = imageData

        let ready = await ClipboardPreparedPreview.prepare(item: lightweightItem) { _ in hydratedItem }
        XCTAssertTrue(ready.isPresentable)
        XCTAssertNotNil(ready.image)
        XCTAssertNil(ready.imageLoadError)

        let failed = await ClipboardPreparedPreview.prepare(item: lightweightItem) { $0 }
        XCTAssertTrue(failed.isPresentable)
        XCTAssertNil(failed.image)
        XCTAssertFalse(try XCTUnwrap(failed.imageLoadError).isEmpty)

        let requestID = UUID()
        XCTAssertTrue(
            ready.canPresent(
                requestID: requestID,
                currentRequestID: requestID,
                selectedItemID: lightweightItem.id
            )
        )
        XCTAssertFalse(
            ready.canPresent(
                requestID: requestID,
                currentRequestID: UUID(),
                selectedItemID: lightweightItem.id
            )
        )
        XCTAssertFalse(
            ready.canPresent(
                requestID: requestID,
                currentRequestID: requestID,
                selectedItemID: UUID()
            )
        )

        for path in [
            "Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift",
            "Sources/PasteBuddy/Views/ClipboardSidePanelView.swift",
        ] {
            let source = try sourceFileContents(path)
            let toggle = try XCTUnwrap(source.range(of: "private func toggleSelectedItemPreview()"))
            let prepareCall = try XCTUnwrap(
                source.range(of: "prepareAndPresentPreview(for: item)", range: toggle.lowerBound..<source.endIndex)
            )
            let singleSelection = try XCTUnwrap(
                source.range(of: "selectSingleItem(item.id)", range: toggle.lowerBound..<prepareCall.lowerBound)
            )
            XCTAssertLessThan(singleSelection.lowerBound, prepareCall.lowerBound)
            let prepare = try XCTUnwrap(source.range(of: "let prepared = await ClipboardPreparedPreview.prepare("))
            let assign = try XCTUnwrap(source.range(of: "preparedPreview = prepared", range: prepare.lowerBound..<source.endIndex))
            let present = try XCTUnwrap(source.range(of: ".presentPreview(for: item.id)", range: assign.lowerBound..<source.endIndex))
            XCTAssertLessThan(prepare.lowerBound, assign.lowerBound)
            XCTAssertLessThan(assign.lowerBound, present.lowerBound)
        }
    }

    func testShelfImageCardsFitEntireThumbnailWithoutCropping() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let start = try XCTUnwrap(source.range(of: "private struct ShelfThumbnailView"))
        let end = try XCTUnwrap(source.range(of: "struct ClipboardImageThumbnailView"))
        let thumbnailSource = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(thumbnailSource.contains("contentMode: .fit"))
        XCTAssertFalse(thumbnailSource.contains("contentMode: .fill"))
    }

    func testShelfLinkCardsUsePersistedMetadataPreviewWithoutViewFetch() throws {
        let shelfSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let monitorSource = try sourceFileContents("Sources/PasteBuddyCore/Services/ClipboardMonitor.swift")
        let storeSource = try sourceFileContents("Sources/PasteBuddyCore/Stores/PasteBuddyStore.swift")

        XCTAssertFalse(shelfSource.contains("import LinkPresentation"))
        XCTAssertTrue(shelfSource.contains("if item.presentationContentType == .url {"))
        XCTAssertTrue(shelfSource.contains("ShelfLinkPreviewCardBody("))
        XCTAssertTrue(shelfSource.contains("item: item,"))
        XCTAssertTrue(shelfSource.contains("imageDataProvider: imageDataProvider,"))
        XCTAssertTrue(shelfSource.contains("linkMetadataProvider: linkMetadataProvider,"))
        XCTAssertTrue(shelfSource.contains(".task(id: item.id)"))
        XCTAssertTrue(shelfSource.contains("await linkMetadataProvider(item)"))
        XCTAssertTrue(shelfSource.contains("} else if preview.prefersImageThumbnail {"))
        XCTAssertTrue(shelfSource.contains("ShelfThumbnailView(item: item, imageDataProvider: imageDataProvider, tint: cardTint)"))
        XCTAssertTrue(shelfSource.contains("contentMode: .fit"))
        XCTAssertTrue(shelfSource.contains("static let linkMetadataImageHeight: CGFloat = cardPreviewHeight - linkMetadataFooterHeight"))
        XCTAssertTrue(shelfSource.contains(".frame(height: ClipboardShelfMetrics.linkMetadataImageHeight)"))
        XCTAssertTrue(shelfSource.contains(
            ".frame(height: ClipboardShelfMetrics.linkMetadataFooterHeight, alignment: .leading)\n        .background(Color.black.opacity(0.78))"
        ))
        XCTAssertFalse(shelfSource.contains(
            "metadataFooter\n                        .frame(height: ClipboardShelfMetrics.linkMetadataFooterHeight)"
        ))
        XCTAssertTrue(shelfSource.contains("private var metadataFooter: some View"))
        XCTAssertTrue(shelfSource.contains("Text(preview.headline)"))
        XCTAssertTrue(shelfSource.contains("Text(preview.body)"))
        XCTAssertFalse(shelfSource.contains("LPMetadataProvider"))
        XCTAssertFalse(shelfSource.contains("startFetchingMetadata"))
        XCTAssertFalse(shelfSource.contains(".task(id: url?.absoluteString)"))

        XCTAssertTrue(monitorSource.contains("import LinkPresentation"))
        XCTAssertTrue(monitorSource.contains("public enum ClipboardLinkMetadataFetcher"))
        XCTAssertTrue(monitorSource.contains("LPMetadataProvider().startFetchingMetadata(for: url)"))
        XCTAssertTrue(monitorSource.contains("metadata.imageProvider ?? metadata.iconProvider"))
        // Capture must never block on the network: the monitor only kicks off the
        // store's idempotent enrichment after the item is already persisted.
        XCTAssertFalse(monitorSource.contains("await ClipboardLinkMetadataFetcher.fetch"))
        XCTAssertTrue(monitorSource.contains("enrichLinkPreviewMetadataIfNeeded(for: storedItem)"))
        XCTAssertTrue(storeSource.contains("linkPreviewMetadataRequests"))
        XCTAssertTrue(storeSource.contains("enrichLinkPreviewMetadataIfNeeded(for item: ClipboardItem)"))
        XCTAssertTrue(storeSource.contains("ClipboardLinkMetadataFetcher.fetch(for: urlString)"))
        XCTAssertTrue(storeSource.contains("snapshot.items[index].payload.imageData = imageData"))
        XCTAssertTrue(storeSource.contains("snapshot.items[index].payload.imageByteCount = imageData.count"))
        XCTAssertFalse(shelfSource.contains("LinkPreviewCache.preview(for:"))
        XCTAssertFalse(shelfSource.contains("LinkPreviewCache.cachedPreview(for:"))
        XCTAssertFalse(sourceFileExists("Sources/PasteBuddy/Models/LinkPreviewCache.swift"))
    }

    func testMobileShareUntitledFallbackResolvesLocalizationBeforeText() throws {
        let source = try sourceFileContents("Sources/PasteBuddyMobile/MobileExtensionViews.swift")

        XCTAssertTrue(source.contains("Text(displayTitle)"))
        XCTAssertTrue(source.contains("PasteBuddyLocalization.string(\"label.untitled\", defaultValue: \"Untitled\")"))
        XCTAssertFalse(source.contains("Text(input.title?.isEmpty == false ? input.title! : \"label.untitled\")"))
    }

    func testShelfCollectionChipsDoNotRenderItemCounts() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let stripStart = try XCTUnwrap(source.range(of: "private var collectionStrip"))
        let stripEnd = try XCTUnwrap(source.range(of: "private var selectedCount"))
        let chipStart = try XCTUnwrap(source.range(of: "private struct ShelfCollectionChip"))
        let selectedCountStart = try XCTUnwrap(source.range(of: "private struct ShelfSelectedCountChip"))
        let stripSource = String(source[stripStart.lowerBound..<stripEnd.lowerBound])
        let chipSource = String(source[chipStart.lowerBound..<selectedCountStart.lowerBound])

        XCTAssertFalse(stripSource.contains("count:"))
        XCTAssertFalse(chipSource.contains("let count"))
        XCTAssertFalse(chipSource.contains("Text(\"\\(count)\")"))
        XCTAssertTrue(chipSource.contains("private var helpText: String"))
    }

    func testShelfCollectionChipsAcceptDraggedClipboardItems() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let stripStart = try XCTUnwrap(source.range(of: "private var collectionStrip"))
        let stripEnd = try XCTUnwrap(source.range(of: "private var selectedCount"))
        let chipStart = try XCTUnwrap(source.range(of: "private struct ShelfCollectionChip"))
        let selectedCountStart = try XCTUnwrap(source.range(of: "private struct ShelfSelectedCountChip"))
        let stripSource = String(source[stripStart.lowerBound..<stripEnd.lowerBound])
        let chipSource = String(source[chipStart.lowerBound..<selectedCountStart.lowerBound])

        XCTAssertTrue(source.contains("private enum ShelfCollectionDropTarget"))
        XCTAssertTrue(stripSource.contains("onDropPayloads: { dropItems($0, into: .pasteStack) }"))
        XCTAssertTrue(stripSource.contains("onDropPayloads: { dropItems($0, into: .smartCategory(category)) }"))
        XCTAssertTrue(stripSource.contains("onDropPayloads: { dropItems($0, into: .pinboard(pinboard.id)) }"))
        XCTAssertTrue(chipSource.contains("ShelfCollectionChipDropTarget("))
        XCTAssertTrue(source.contains("private struct ShelfCollectionChipDropTarget: NSViewRepresentable"))
        XCTAssertTrue(source.contains("registerForDraggedTypes([Self.payloadPasteboardType])"))
        XCTAssertTrue(source.contains("override func performDragOperation(_ sender: NSDraggingInfo) -> Bool"))
        XCTAssertTrue(source.contains("store.pinItems(ids, to: pinboardID)"))
        XCTAssertTrue(source.contains("store.addItemsToPasteStack(ids)"))
        XCTAssertTrue(source.contains("store.snapshot.items.first(where: { $0.id == id }).map(category.matches) == true"))
    }

    func testShelfCollectionChipDoesNotRenderRectangularShadowOutsideCapsule() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let chipStart = try XCTUnwrap(source.range(of: "private struct ShelfCollectionChip"))
        let selectedCountStart = try XCTUnwrap(source.range(of: "private struct ShelfSelectedCountChip"))
        let chipSource = String(source[chipStart.lowerBound..<selectedCountStart.lowerBound])

        XCTAssertTrue(chipSource.contains(".clipShape(Capsule())"))
        XCTAssertFalse(chipSource.contains(".shadow("))
    }

    func testIrohSyncForwardsEnrichedLinkMetadataToPeers() throws {
        let appSource = try sourceFileContents("Sources/PasteBuddy/App/PasteBuddyApp.swift")

        XCTAssertTrue(appSource.contains("store.onLinkPreviewMetadataEnriched = { [irohSync] item in"))
        XCTAssertTrue(appSource.contains("await irohSync.sendIfConnected(item)"))
    }

    func testIrohSyncReceiversRoutePeerItemsThroughPrivacyGate() throws {
        let macAppSource = try sourceFileContents("Sources/PasteBuddy/App/PasteBuddyApp.swift")
        let iosAppSource = try sourceFileContents("Sources/PasteBuddyiOS/PasteBuddyiOSApp.swift")
        let keyboardSource = try sourceFileContents("Sources/PasteBuddyKeyboard/KeyboardViewController.swift")

        XCTAssertTrue(macAppSource.contains("store.addSyncedItem(item)"))
        XCTAssertTrue(iosAppSource.contains("store.addSyncedItem(item)"))
        XCTAssertTrue(keyboardSource.contains("resolvedStore.addSyncedItem(item)"))
    }

    func testMenuBarStatusItemOwnsClickableMenuInsteadOfSwiftUIMenuBarExtra() throws {
        let appSource = try sourceFileContents("Sources/PasteBuddy/App/PasteBuddyApp.swift")
        let statusItemSource = try sourceFileContents("Sources/PasteBuddy/App/PasteBuddyStatusItemController.swift")

        XCTAssertFalse(appSource.contains("MenuBarExtra"))
        XCTAssertFalse(appSource.contains("handleDockIconReopen"))
        XCTAssertTrue(appSource.contains("statusItemController = PasteBuddyStatusItemController"))
        XCTAssertTrue(statusItemSource.contains("primaryAction"))
        XCTAssertTrue(statusItemSource.contains("func menuNeedsUpdate(_ menu: NSMenu)"))
        XCTAssertTrue(statusItemSource.contains("menu.removeAllItems()"))
        XCTAssertTrue(statusItemSource.contains("menu.addItem(item)"))
        XCTAssertTrue(statusItemSource.contains("keyEquivalentModifierMask"))
        XCTAssertFalse(statusItemSource.contains("statusItem.popUpMenu(menu)"))
    }

    func testMenuBarStatusItemDoesNotExposeDirectMainWindowOpenAction() throws {
        let appSource = try sourceFileContents("Sources/PasteBuddy/App/PasteBuddyApp.swift")
        let menuStart = try XCTUnwrap(appSource.range(of: "private func makeStatusItemMenu()"))
        let menuEnd = try XCTUnwrap(appSource.range(of: "private func toggleClipboardShelf()"))
        let menuSource = String(appSource[menuStart.lowerBound..<menuEnd.lowerBound])

        XCTAssertFalse(appSource.contains(#"WindowGroup("PasteBuddy""#))
        XCTAssertFalse(appSource.contains("ContentView("))
        XCTAssertFalse(appSource.contains("mainWindowScene"))
        XCTAssertFalse(appSource.contains("MainWindowLaunchGuard"))
        XCTAssertFalse(appSource.contains("MainWindowLaunchCoordinator"))
        XCTAssertFalse(menuSource.contains("Open PasteBuddy"))
        XCTAssertFalse(menuSource.contains("openMainWindow()"))
        XCTAssertFalse(menuSource.contains("openWindow(id: \"main\""))
    }

    func testMainHistoryWindowInterfaceFilesAreRemoved() {
        for removedPath in [
            "Sources/PasteBuddy/Views/ContentView.swift",
            "Sources/PasteBuddy/Views/SidebarView.swift",
            "Sources/PasteBuddy/Views/ItemListView.swift",
            "Sources/PasteBuddy/Views/ItemDetailView.swift",
            "Sources/PasteBuddy/Views/PinboardSharingSheet.swift",
            "Sources/PasteBuddy/Models/ClipboardItemDragProvider.swift"
        ] {
            XCTAssertThrowsError(try sourceFileContents(removedPath))
        }
    }

    func testStatusItemMenuKeepsPanelModeSettingsLoginAndPasteStackActions() throws {
        let appSource = try sourceFileContents("Sources/PasteBuddy/App/PasteBuddyApp.swift")
        let menuStart = try XCTUnwrap(appSource.range(of: "private func makeStatusItemMenu()"))
        let menuEnd = try XCTUnwrap(appSource.range(of: "private func toggleClipboardShelf()"))
        let menuSource = String(appSource[menuStart.lowerBound..<menuEnd.lowerBound])

        XCTAssertTrue(menuSource.contains("action.disable_launch_at_login"))
        XCTAssertTrue(menuSource.contains("action.enable_launch_at_login"))
        XCTAssertTrue(menuSource.contains("label.panel_style"))
        XCTAssertTrue(menuSource.contains("ClipboardPanelDisplayMode.allCases"))
        XCTAssertTrue(menuSource.contains("panelDisplayMode = mode"))
        XCTAssertTrue(menuSource.contains("keyEquivalent: mode == .shelf ? \"b\" : \"\""))
        XCTAssertTrue(menuSource.contains("keyEquivalentModifierMask: mode == .shelf ? [.command, .shift] : nil"))
        XCTAssertTrue(menuSource.contains("action.open_settings"))
        XCTAssertTrue(menuSource.contains("keyEquivalent: \",\""))
        XCTAssertTrue(menuSource.contains("keyEquivalentModifierMask: .command"))
        XCTAssertTrue(menuSource.contains("action.start_paste_stack"))
        XCTAssertTrue(menuSource.contains("action.stop_paste_stack"))
        XCTAssertTrue(menuSource.contains("action.paste_next_stack_item"))
        XCTAssertTrue(menuSource.contains("action.quit_app"))
        XCTAssertTrue(menuSource.contains("keyEquivalent: \"q\""))
        XCTAssertTrue(menuSource.contains("NSApp.terminate(nil)"))
        XCTAssertFalse(menuSource.contains("disabledMenuItem"))
        XCTAssertFalse(menuSource.contains("captureStatusLine"))
        XCTAssertFalse(menuSource.contains("captureDetail"))
        XCTAssertFalse(menuSource.contains("launchAtLoginStatusLine"))
        XCTAssertFalse(menuSource.contains("action.show_hide_panel"))
        XCTAssertFalse(menuSource.contains("label.shelf_position"))
        XCTAssertFalse(menuSource.contains("action.pause_capture"))
        XCTAssertFalse(menuSource.contains("action.pause_capture_for_15_minutes"))
        XCTAssertFalse(menuSource.contains("action.pause_capture_for_1_hour"))
        XCTAssertFalse(menuSource.contains("recentItems"))
        XCTAssertFalse(menuSource.contains("menuBarTitle"))
    }

    func testStatusItemMenuExposesPanelStyleButNotShelfPlacementChooser() throws {
        let appSource = try sourceFileContents("Sources/PasteBuddy/App/PasteBuddyApp.swift")
        let controllerSource = try sourceFileContents("Sources/PasteBuddy/App/ClipboardShelfPanelController.swift")
        let menuStart = try XCTUnwrap(appSource.range(of: "private func makeStatusItemMenu()"))
        let menuEnd = try XCTUnwrap(appSource.range(of: "private func toggleClipboardShelf()"))
        let menuSource = String(appSource[menuStart.lowerBound..<menuEnd.lowerBound])

        XCTAssertTrue(appSource.contains(#"@AppStorage("clipboardPanelDisplayMode")"#))
        XCTAssertTrue(appSource.contains("ClipboardPanelDisplayMode.sidePanel.rawValue"))
        XCTAssertTrue(appSource.contains("shelfPanelController?.displayMode = panelDisplayMode"))
        XCTAssertTrue(appSource.contains(#"@AppStorage("clipboardShelfPlacement")"#))
        XCTAssertTrue(appSource.contains("shelfPanelController?.placement = shelfPlacement"))
        XCTAssertTrue(controllerSource.contains("case sidePanel"))
        XCTAssertTrue(controllerSource.contains("label.side_panel"))
        XCTAssertTrue(menuSource.contains("label.panel_style"))
        XCTAssertTrue(menuSource.contains("ClipboardPanelDisplayMode.allCases"))
        XCTAssertTrue(menuSource.contains("panelDisplayMode = mode"))
        XCTAssertTrue(menuSource.contains("keyEquivalent: mode == .shelf ? \"b\" : \"\""))
        XCTAssertTrue(menuSource.contains("keyEquivalentModifierMask: mode == .shelf ? [.command, .shift] : nil"))
        XCTAssertFalse(menuSource.contains("label.shelf_position"))
        XCTAssertFalse(menuSource.contains("shelfPlacementMenu"))
    }

    func testStatusItemLeftClickRunsPrimaryActionAndKeepsMenuOnSecondaryClick() throws {
        let appSource = try sourceFileContents("Sources/PasteBuddy/App/PasteBuddyApp.swift")
        let statusItemSource = try sourceFileContents("Sources/PasteBuddy/App/PasteBuddyStatusItemController.swift")

        XCTAssertTrue(statusItemSource.contains("button.target = self"))
        XCTAssertTrue(statusItemSource.contains("button.sendAction(on: [.leftMouseUp, .rightMouseUp])"))
        XCTAssertTrue(statusItemSource.contains("handleStatusItemClick"))
        XCTAssertTrue(statusItemSource.contains("primaryAction()"))
        XCTAssertTrue(statusItemSource.contains("showStatusMenu()"))
        XCTAssertTrue(statusItemSource.contains("event?.type == .rightMouseUp"))
        XCTAssertTrue(statusItemSource.contains("event?.modifierFlags.contains(.control)"))
        XCTAssertTrue(appSource.contains("primaryAction:"))
        XCTAssertTrue(appSource.contains("await toggleClipboardShelf()"))
    }

    func testMCPSettingsExposeConnectionMenuAndAdvancedControls() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/SettingsView.swift")
        let mcpStart = try XCTUnwrap(source.range(of: "private var integrationSettings"))
        let subscriptionStart = try XCTUnwrap(source.range(of: "private var subscriptionSettings"))
        let mcpSource = String(source[mcpStart.lowerBound..<subscriptionStart.lowerBound])

        XCTAssertTrue(mcpSource.contains("label.enable_mcp"))
        XCTAssertTrue(mcpSource.contains("message.mcp_local_connection"))
        XCTAssertTrue(mcpSource.contains("action.connect_ai_tool"))
        XCTAssertTrue(mcpSource.contains("action.agent_privacy_and_access"))
        XCTAssertTrue(mcpSource.contains("mcpClientCandidates"))
        XCTAssertTrue(source.contains("struct MCPClientDetector"))
        XCTAssertTrue(mcpSource.contains("label.connected_ai_tools"))
        XCTAssertTrue(mcpSource.contains("PasteBuddyMCPHTTPServer.endpoint"))
        XCTAssertTrue(source.contains("struct MCPClientConfigurationSheet"))
        XCTAssertTrue(source.contains("struct MCPClientCommandRunner"))
        XCTAssertTrue(source.contains("runMCPInstallationCommand"))
        XCTAssertTrue(source.contains("openMCPInstallationURL"))
        XCTAssertTrue(source.contains("action.run_install_command"))
        XCTAssertTrue(source.contains("struct MCPAdvancedSettingsSheet"))
        XCTAssertTrue(source.contains("ForEach(MCPToolName.allCases)"))
        XCTAssertTrue(source.contains("setMCPTool(tool, enabled: $0)"))
        XCTAssertTrue(source.contains("action.revoke_mcp_access"))
        XCTAssertTrue(source.contains("message.retrieve_item_requires_explicit_mcp_opt_in"))
        let advancedStart = try XCTUnwrap(source.range(of: "private struct MCPAdvancedSettingsSheet"))
        let toggleLabelStart = try XCTUnwrap(source.range(of: "private struct SettingsToggleLabel"))
        let advancedSource = String(source[advancedStart.lowerBound..<toggleLabelStart.lowerBound])
        XCTAssertFalse(advancedSource.contains("action.enable_mcp"))
        XCTAssertEqual(PasteBuddyMCPHTTPServer.endpoint, "http://127.0.0.1:18789/mcp")
    }

    func testSettingsDoesNotExposeLocalHistoryEncryptionToggle() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/SettingsView.swift")

        XCTAssertFalse(source.contains("Encrypt clipboard history at rest"))
        XCTAssertFalse(source.contains("setHistoryEncryptionEnabled"))
    }

    func testPushTestFlightFetchRefreshesRemoteTrackingBranchBeforeAheadCheck() throws {
        let source = try sourceFileContents("script/push_testflight.sh")

        XCTAssertTrue(
            source.contains(#"git fetch "$REMOTE" "+refs/heads/$BRANCH:refs/remotes/$REMOTE/$BRANCH" --tags"#)
        )
        XCTAssertFalse(source.contains(#"git fetch "$REMOTE" "$BRANCH" --tags"#))
    }

    func testBuildAndRunRestrictsSigningLookupToConfiguredKeychain() throws {
        let source = try sourceFileContents("script/build_and_run.sh")

        XCTAssertTrue(source.contains("PASTEBUDDY_CODESIGN_KEYCHAIN"))
        XCTAssertTrue(source.contains("security default-keychain -d user"))
        XCTAssertTrue(source.contains("security find-identity -v -p codesigning \"$CODESIGN_KEYCHAIN\""))
        XCTAssertTrue(source.contains("codesign_args+=(--keychain \"$CODESIGN_KEYCHAIN\")"))
        XCTAssertFalse(source.contains("security find-identity -v -p codesigning 2>/dev/null"))
        XCTAssertFalse(source.contains("unlock-keychain"))
        XCTAssertFalse(source.contains("set-key-partition-list"))
    }

    func testBuildAndRunProtectsStableAppBehindCoordinatedSingleInstanceInstall() throws {
        let source = try sourceFileContents("script/build_and_run.sh")

        XCTAssertTrue(source.contains("INTEGRATION_BRANCH=\"codex/integrated-delivery\""))
        XCTAssertTrue(source.contains("Refusing to install an uncommitted source state"))
        XCTAssertTrue(source.contains("PasteBuddySourceBranch"))
        XCTAssertTrue(source.contains("PasteBuddySourceCommit"))
        XCTAssertTrue(source.contains("lsappinfo info -only bundleID"))
        XCTAssertTrue(source.contains("runningInstanceCount=1"))
        XCTAssertTrue(source.contains("/usr/bin/chflags uchg"))
        XCTAssertTrue(source.contains("run_coordinated_install_gate_tests"))
        XCTAssertTrue(source.contains("run_required_test_filter PasteBuddyAppRuntimeTests/testShelfSingleClickSelectionIsImmediateAndOnlyDoubleClickPastes"))
        XCTAssertTrue(source.contains("run_required_test_filter PasteBuddyAppRuntimeTests/testClipboardPanelArrowKeyCommandUsesExactEventModifiers"))
        XCTAssertTrue(source.contains("run_required_test_filter PasteBuddyAppRuntimeTests/testClipboardPanelsUseNativeCopyCommandForTheirLocalSelection"))
        XCTAssertTrue(source.contains("run_required_test_filter PasteBuddyAppRuntimeTests/testBothPanelModesShareNativeCommandVPasteRoute"))
        XCTAssertTrue(source.contains("run_required_test_filter PasteBuddyAppRuntimeTests/testSharedPanelPagingStateReachesAll501ItemsWithoutDuplicates"))
        XCTAssertTrue(source.contains("run_required_test_filter PasteBuddyAppRuntimeTests/testSharedPanelPagingRejectsOldQueryResponseAfterReset"))
        XCTAssertTrue(source.contains("run_required_test_filter PasteBuddyStoreTests/testCaptureAndSyncRetainItem501AcrossSaveAndRelaunch"))
        XCTAssertTrue(source.contains("run_required_test_filter PasteBuddyStoreTests/testPanelPagingMakesAll501RepositoryItemsReachableWithFiltersAndScopes"))
        XCTAssertTrue(source.contains("run_required_test_filter PasteBuddyStoreTests/testStorageConfigurationDropsLegacyCountCapWithoutChangingAgePolicy"))
        XCTAssertTrue(source.contains("run_required_test_filter PasteBuddyStoreTests/testRepositoryPagingUsesUniqueTieBreakerForEqualTimestamps"))
        XCTAssertTrue(source.contains("run_required_test_filter PasteBuddyStoreTests/testRepositoryPagingUsesEffectiveContentTypeAcrossMultipleBoundaries"))
        XCTAssertTrue(source.contains("run_required_test_filter PasteBuddyStoreTests/testConfiguredStaleRepositoryFailsClosedWithoutSnapshotFallback"))
        XCTAssertTrue(source.contains("run_required_test_filter PasteBuddyStoreTests/testRepositorySyncReadinessAdvancesQueryRevisionAndReloadsHistory"))
        XCTAssertTrue(source.contains("run_required_test_filter PasteBuddyStoreTests/testFlushDoesNotMarkRepositoryCurrentWhenSnapshotChangesDuringSync"))
        XCTAssertTrue(source.contains("run_required_test_filter PasteBuddyStoreTests/testSharedImportRetainsItem501AcrossSaveAndRelaunch"))
        XCTAssertTrue(source.contains("run_required_test_filter PasteBuddyStoreTests/testSnapshotDatabaseMigratorRetainsItem501"))
        XCTAssertTrue(source.contains("run_required_test_filter PasteBuddyStoreTests/testEffectiveContentTypesMigrationBackfillsLegacySQLiteAcross501Rows"))
        XCTAssertTrue(source.contains("run_required_test_filter PasteBuddyStoreTests/testRepositorySyncRepairsStaleEffectiveContentTypes"))
        XCTAssertTrue(source.contains("run_required_test_filter PasteBuddyStoreTests/testInMemoryStoreDoesNotTruncateHistoryAtRepositoryPageSize"))
        XCTAssertTrue(source.contains("run_required_test_filter PasteBuddyAppRuntimeTests/testBothClipboardPanelsShowRepositoryQueryFailure"))
        XCTAssertTrue(source.contains("run_required_test_filter PasteBuddyAppRuntimeTests/testSharedPanelHistoryAvailabilityFailsClosed"))
        XCTAssertTrue(source.contains("run_required_test_filter HistoryCardTimestampFormatterTests"))
        XCTAssertTrue(source.contains("run_required_test_filter PasteboardWriterTests/testNativeCopyCommand"))
        XCTAssertTrue(source.contains("run_required_test_filter PasteboardWriterTests/testDirectPaste"))
        XCTAssertTrue(source.contains("run_required_test_filter PasteBuddyAppRuntimeTests/testPanelWindowOwnsNativePasteResponder"))
        XCTAssertTrue(source.contains("Required integration test filter matched no XCTest cases"))
        XCTAssertFalse(source.contains("/usr/bin/open -n"))
    }

    func testBothClipboardPanelsShowRepositoryQueryFailure() throws {
        for path in [
            "Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift",
            "Sources/PasteBuddy/Views/ClipboardSidePanelView.swift"
        ] {
            let source = try sourceFileContents(path)
            XCTAssertTrue(source.contains("store.historyQueryErrorMessage"), path)
            XCTAssertTrue(source.contains("ClipboardPanelHistoryAvailability.visibleItems"), path)
            XCTAssertTrue(source.contains("ClipboardPanelHistoryAvailability.allowsActions"), path)
            XCTAssertTrue(source.contains("\"exclamationmark.triangle\""), path)
        }
    }

    func testBothClipboardPanelsUseNeutralLoadingInsteadOfUnavailableOrZeroDuringRepositoryTransition() throws {
        let shelfSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let sideSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardSidePanelView.swift")

        for source in [shelfSource, sideSource] {
            XCTAssertTrue(source.contains("store.isHistoryQueryTransitioning"))
            XCTAssertTrue(source.contains("ProgressView()"))
            XCTAssertTrue(source.contains("sideScope != .pasteStack") || source.contains("shelfScope != .pasteStack"))
        }
        XCTAssertTrue(shelfSource.contains("case loading"))
        XCTAssertTrue(sideSource.contains("if paging.items.isEmpty, store.isHistoryQueryTransitioning"))
    }

    func testSharedPanelHistoryAvailabilityFailsClosed() {
        let item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Previously loaded item",
            payload: ClipboardPayload(text: "must not remain actionable")
        )

        XCTAssertTrue(ClipboardPanelHistoryAvailability.visibleItems(
            [item],
            scope: .history,
            errorMessage: "Repository unavailable"
        ).isEmpty)
        XCTAssertTrue(ClipboardPanelHistoryAvailability.visibleItems(
            [item],
            scope: .pinboard(UUID()),
            errorMessage: "Repository unavailable"
        ).isEmpty)
        XCTAssertEqual(ClipboardPanelHistoryAvailability.visibleItems(
            [item],
            scope: .pasteStack,
            errorMessage: "Repository unavailable"
        ).map(\.id), [item.id])
        XCTAssertEqual(ClipboardPanelHistoryAvailability.visibleItems(
            [item],
            scope: .history,
            errorMessage: nil
        ).map(\.id), [item.id])
        XCTAssertFalse(ClipboardPanelHistoryAvailability.allowsActions(
            scope: .history,
            errorMessage: "Repository unavailable"
        ))
        XCTAssertFalse(ClipboardPanelHistoryAvailability.allowsActions(
            scope: .pinboard(UUID()),
            errorMessage: "Repository unavailable"
        ))
        XCTAssertTrue(ClipboardPanelHistoryAvailability.allowsActions(
            scope: .pasteStack,
            errorMessage: "Repository unavailable"
        ))
    }

    func testSettingsUsesSidebarSplitViewInsteadOfToolbarTabs() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/SettingsView.swift")
        let appSource = try sourceFileContents("Sources/PasteBuddy/App/PasteBuddyApp.swift")
        let generalStart = try XCTUnwrap(source.range(of: "private var generalSettings"))
        let privacyStart = try XCTUnwrap(source.range(of: "private var privacySettings"))
        let shortcutsStart = try XCTUnwrap(source.range(of: "private var shortcutSettings"))
        let generalSource = String(source[generalStart.lowerBound..<privacyStart.lowerBound])
        let privacySource = String(source[privacyStart.lowerBound..<shortcutsStart.lowerBound])

        XCTAssertTrue(source.contains("NavigationSplitView"))
        XCTAssertTrue(source.contains(".toolbarBackgroundVisibility(.visible, for: .windowToolbar)"))
        XCTAssertTrue(source.contains(".toolbarBackground(.visible, for: .windowToolbar)"))
        XCTAssertFalse(source.contains(".toolbarBackgroundVisibility(.hidden, for: .windowToolbar)"))
        XCTAssertFalse(source.contains(".toolbarBackground(.hidden, for: .windowToolbar)"))
        XCTAssertTrue(source.contains("List(SettingsSidebarSection.allCases, selection: $selectedSettingsSection)"))
        XCTAssertTrue(source.contains(".listStyle(.sidebar)"))
        XCTAssertTrue(source.contains(".scrollContentBackground(.hidden)"))
        XCTAssertTrue(source.contains(".navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 200)"))
        XCTAssertFalse(source.contains("import AppKit"))
        XCTAssertFalse(source.contains("NSViewRepresentable"))
        XCTAssertFalse(source.contains("NSWindow"))
        XCTAssertFalse(source.contains("NSToolbar"))
        XCTAssertFalse(source.contains("SettingsWindowChromeConfigurator"))
        XCTAssertFalse(source.contains("SettingsToolbarConfiguration"))
        XCTAssertTrue(appSource.contains(".windowToolbarStyle(.unified(showsTitle: true))"))
        XCTAssertFalse(source.contains("ToolbarItem(placement: .navigation)"))
        XCTAssertFalse(source.contains(".navigationTitle(\"label.settings\")"))
        XCTAssertTrue(source.contains(".navigationTitle(effectiveSettingsSection.titleKey)"))
        XCTAssertTrue(appSource.contains(".defaultSize(width: 640, height: 560)"))
        XCTAssertTrue(source.contains(".frame(width: 640, height: 560)"))
        let sidebarToggleRemoval = try XCTUnwrap(source.range(of: ".toolbar(removing: .sidebarToggle)"))
        XCTAssertLessThan(sidebarToggleRemoval.lowerBound, generalStart.lowerBound)
        XCTAssertTrue(source.contains("SliderTick(0)"))
        XCTAssertTrue(source.contains("SliderTick(4)"))
        XCTAssertTrue(source.contains("label: {\n                        EmptyView()"))
        XCTAssertTrue(source.contains("onEditingChanged: retentionSliderEditingChanged\n                )\n                .labelsHidden()"))
        XCTAssertTrue(source.contains("if retentionSliderIsEditing"))
        XCTAssertTrue(source.contains("Text(retentionOption.localizedTitle)\n                        .frame(maxWidth: .infinity, alignment: .center)"))
        XCTAssertTrue(source.contains(".frame(height: 22)\n                        .accessibilityHidden(true)"))
        XCTAssertTrue(source.contains("retentionLabelPosition(in width: CGFloat)"))
        XCTAssertTrue(source.contains("case privacy"))
        XCTAssertTrue(source.contains("case .privacy:"))
        XCTAssertTrue(source.contains("self = .privacy"))
        XCTAssertTrue(source.contains("case .sync:"))
        XCTAssertTrue(source.contains("self = .integrations"))
        XCTAssertTrue(source.contains("Image(\"mcp-brand-base\", bundle: .module)"))
        XCTAssertTrue(source.contains("Image(\"mcp-brand-inset\", bundle: .module)"))
        XCTAssertTrue(source.contains(".renderingMode(.template)"))
        XCTAssertTrue(source.contains(".foregroundStyle(isSelected ? Color.white : Color.accentColor)"))
        XCTAssertFalse(source.contains("\"paperclip\""))
        XCTAssertTrue(generalSource.contains("label.launch_at_login"))
        XCTAssertTrue(generalSource.contains("label.panel_style"))
        XCTAssertTrue(generalSource.contains("action.paste_as_plain_text_by"))
        XCTAssertTrue(generalSource.contains("label.keep_history"))
        XCTAssertTrue(generalSource.contains("label.iroh_clipboard_sync"))
        XCTAssertTrue(privacySource.contains("label.show_during_screen_sharing"))
        XCTAssertTrue(privacySource.contains("label.capture_images"))
        XCTAssertTrue(privacySource.contains("label.storage_security"))
        XCTAssertTrue(appSource.contains("panelDisplayMode: Binding("))
        XCTAssertFalse(source.contains("TabView {"))
        XCTAssertFalse(source.contains(".tabItem"))
    }

    func testRetentionSliderSupportsIntermediateDurations() {
        XCTAssertEqual(SettingsRetentionOption.closest(toDays: 14).days, 14)
        XCTAssertEqual(SettingsRetentionOption.closest(toDays: 21).days, 21)
        XCTAssertEqual(SettingsRetentionOption.closest(toDays: 60).days, 60)
        XCTAssertEqual(SettingsRetentionOption.closest(toDays: 120).days, 120)
        XCTAssertEqual(SettingsRetentionOption.closest(toDays: 150).days, 150)
        XCTAssertEqual(SettingsRetentionOption.closest(toDays: 0).days, 0)
    }

    func testCaptureRuleAppValuesUseInstalledApplicationPicker() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/SettingsView.swift")
        let iconSource = try sourceFileContents("Sources/PasteBuddy/Views/InstalledApplicationIcon.swift")

        XCTAssertTrue(source.contains("InstalledApplicationPickerSheet"))
        XCTAssertTrue(source.contains(".frame(width: 480, height: 420)"))
        XCTAssertFalse(source.contains(".frame(width: 560, height: 560)"))
        XCTAssertTrue(iconSource.contains("import QuickLookThumbnailing"))
        XCTAssertTrue(iconSource.contains("representationTypes: [.icon]"))
        XCTAssertTrue(iconSource.contains("representation.cgImage"))
        XCTAssertTrue(source.contains("SettingsPrivacyRuleMode"))
        XCTAssertTrue(source.contains(".pickerStyle(.segmented)"))
        XCTAssertTrue(source.contains("label.ignore_remote_clipboard"))
        XCTAssertTrue(source.contains("label.flatten_large_excel_clipboard"))
        XCTAssertTrue(source.contains("setMaximumClipboardSizeMegabytes"))
        XCTAssertTrue(source.contains("store.excludeApplication("))
    }

    func testInstalledApplicationCatalogReadsAppsFromLocalBundles() throws {
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

        let applications = InstalledApplicationCatalog(applicationDirectories: [root]).applications()

        XCTAssertEqual(applications.filter { $0.bundleIdentifier == "com.example.code" }.count, 1)
        XCTAssertTrue(applications.contains { $0.displayName == "Code" && $0.bundleIdentifier == "com.example.code" })
        XCTAssertTrue(applications.contains { $0.displayName == "No Bundle" && $0.bundleIdentifier == nil })
    }

    func testShortcutSettingsRecordKeyCombinationsInsteadOfManualToggles() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/SettingsView.swift")
        let bindingRowStart = try XCTUnwrap(source.range(of: "private struct SettingsShortcutRow"))
        let modifierRowStart = try XCTUnwrap(source.range(of: "private struct SettingsModifierShortcutRow"))
        let bindingRowSource = String(source[bindingRowStart.lowerBound..<modifierRowStart.lowerBound])

        XCTAssertTrue(source.contains("ShortcutCaptureButton"))
        XCTAssertTrue(source.contains("ShortcutRecorderState"))
        XCTAssertTrue(source.contains("NSEvent.addLocalMonitorForEvents(matching: .keyDown)"))
        XCTAssertTrue(source.contains("NSEvent.removeMonitor(eventMonitor)"))
        XCTAssertTrue(source.contains("NotificationCenter.default.post(name: .pasteBuddyShortcutRecordingDidChange"))
        XCTAssertTrue(source.contains("store.setShortcutBinding("))
        XCTAssertTrue(source.contains("store.setQuickPasteModifiers("))
        XCTAssertTrue(bindingRowSource.contains("onClear: currentBinding.isEnabled"))
        XCTAssertFalse(bindingRowSource.contains("Button(\"action.clear_shortcut\")"))
        XCTAssertTrue(source.contains("action.reset_all_shortcuts"))
        XCTAssertTrue(source.contains("destructiveConfirmation = .resetShortcuts"))
        XCTAssertTrue(source.contains("state.recording_shortcut"))
        XCTAssertTrue(source.contains("message.press_key_combination_to_record"))
        XCTAssertTrue(source.contains("event.keyCode == 53"))
        XCTAssertTrue(source.contains("Image(systemName: \"xmark\")"))
        XCTAssertTrue(source.contains("message.shortcut_binding_rejected"))
        XCTAssertTrue(source.contains("action: .showNextPinboard"))
        XCTAssertTrue(source.contains("action: .showPreviousPinboard"))
        XCTAssertFalse(source.contains("ShortcutModifierToggles"))
        XCTAssertFalse(source.contains("Toggle(modifier.displayName"))
        XCTAssertFalse(source.contains("TextField(\"label.key\""))
    }

    func testPrivacySettingsUsesNativeSelectionForExcludedApplications() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/SettingsView.swift")

        XCTAssertTrue(source.contains("List(selection: $selectedRowID)"))
        XCTAssertTrue(source.contains("store.removeExcludedApplication(name)"))
        XCTAssertTrue(source.contains("store.removeExcludedBundleIdentifier(bundleIdentifier)"))
        XCTAssertTrue(source.contains(".disabled(selectedRowID == nil)"))
    }

    func testPrivacySettingsKeepsStorageGrowthVisibleWithoutAnItemCap() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/SettingsView.swift")
        let privacyStart = try XCTUnwrap(source.range(of: "private var privacySettings"))
        let shortcutsStart = try XCTUnwrap(source.range(of: "private var shortcutSettings"))
        let privacySource = String(source[privacyStart.lowerBound..<shortcutsStart.lowerBound])

        XCTAssertTrue(privacySource.contains("label.require_touch_id_for_history"))
        XCTAssertTrue(privacySource.contains("label.storage_usage"))
        XCTAssertTrue(privacySource.contains("storageUsageReport.itemCount"))
        XCTAssertTrue(privacySource.contains("storageUsageReport.estimatedBytes"))
        XCTAssertFalse(privacySource.contains("maxHistoryItems"))
        XCTAssertTrue(source.contains("destructiveConfirmation = .reduceRetentionDays(value)"))
        XCTAssertTrue(source.contains("case .reduceRetentionDays(let days):"))
    }

    func testPanelHotKeyControllerPausesGlobalHotKeysWhileRecordingShortcuts() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/App/ClipboardShelfPanelController.swift")

        XCTAssertTrue(source.contains("forName: .pasteBuddyShortcutRecordingDidChange"))
        XCTAssertTrue(source.contains("setHotKeySourcesEnabled(!isRecording)"))
        XCTAssertTrue(source.contains("registration?.setEnabled(isEnabled)"))
        XCTAssertTrue(source.contains("eventTap?.setEnabled(isEnabled)"))
        XCTAssertTrue(source.contains("ignoredDuringShortcutRecording"))
        XCTAssertTrue(source.contains("UnregisterEventHotKey(hotKeyRef)"))
        XCTAssertTrue(source.contains("CGEvent.tapEnable(tap: eventTap, enable: isEnabled)"))
    }

    func testSubscriptionSettingsUsesVerifiedStoreKitInfrastructure() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/SettingsView.swift")
        let plansStart = try XCTUnwrap(source.range(of: "private var subscriptionSettings"))
        let bindingsStart = try XCTUnwrap(source.range(of: "private var launchAtLoginBinding"))
        let plansSource = String(source[plansStart.lowerBound..<bindingsStart.lowerBound])

        XCTAssertTrue(plansSource.contains("action.restore_purchases"))
        XCTAssertTrue(plansSource.contains("AppleStoreKitEntitlementProvider()"))
        XCTAssertTrue(plansSource.contains("fetchProducts()"))
        XCTAssertFalse(plansSource.contains("displayPrice"))
        XCTAssertTrue(plansSource.contains("lifetimeProduct == nil"))
        XCTAssertTrue(plansSource.contains("await store.flushPendingSave()"))
        XCTAssertFalse(plansSource.contains("action.start_trial"))
        XCTAssertFalse(plansSource.contains("action.cancel_trial"))
        XCTAssertFalse(plansSource.contains("store.activatePersonalPlan"))
        XCTAssertFalse(plansSource.contains("markRestorePurchasesFailed"))
        XCTAssertFalse(plansSource.contains("statusName"))
        XCTAssertFalse(plansSource.contains("accessState"))
        XCTAssertFalse(plansSource.contains("trialState.displayName"))
        XCTAssertFalse(plansSource.contains("trialSummary"))
        XCTAssertFalse(plansSource.contains("trialOutcomeStatement"))
        XCTAssertFalse(plansSource.contains("crossDeviceStatement"))
        XCTAssertFalse(plansSource.contains("label.device_unlock"))
        XCTAssertFalse(plansSource.contains("restoreActionStatement"))
        XCTAssertFalse(plansSource.contains("purchaseOptions"))
        XCTAssertFalse(plansSource.contains("billingSafetyStatement"))
        XCTAssertFalse(plansSource.contains("StoreKit restore"))
        XCTAssertFalse(plansSource.contains("option.detail"))
        XCTAssertFalse(plansSource.contains("option.unlockSummary"))
    }

    func testIntegrationSettingsUsesRealMCPConfigurationActions() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/SettingsView.swift")
        let integrationsStart = try XCTUnwrap(source.range(of: "private var integrationSettings"))
        let subscriptionStart = try XCTUnwrap(source.range(of: "private var subscriptionSettings"))
        let integrationsSource = String(source[integrationsStart.lowerBound..<subscriptionStart.lowerBound])

        XCTAssertTrue(integrationsSource.contains("store.setMCPServerEnabled"))
        XCTAssertTrue(integrationsSource.contains("mcpClientCandidates"))
        XCTAssertTrue(integrationsSource.contains("selectedMCPClient = candidate.target"))
        XCTAssertTrue(integrationsSource.contains("action.connect_ai_tool"))
    }

    func testMCPStdioExecutableProxiesToTheRunningAppWithoutOpeningAStore() throws {
        let source = try sourceFileContents("Sources/PasteBuddyMCP/main.swift")

        XCTAssertTrue(source.contains("PASTEBUDDY_MCP_TOKEN") || source.contains("MCPAuthenticationToken.environmentVariable"))
        XCTAssertTrue(source.contains("http://127.0.0.1:18789/mcp"))
        XCTAssertTrue(source.contains("URLSession.shared.data(for: request)"))
        XCTAssertFalse(source.contains("PasteBuddyStore()"))
        XCTAssertFalse(source.contains("loadAsync()"))
        XCTAssertFalse(source.contains("flushPendingSave()"))
    }

    func testStableBundlePackagesMCPAndCloudKitRuntimeCapabilities() throws {
        let settingsSource = try sourceFileContents("Sources/PasteBuddy/Views/SettingsView.swift")
        let appSource = try sourceFileContents("Sources/PasteBuddy/App/PasteBuddyApp.swift")
        let buildSource = try sourceFileContents("script/build_and_run.sh")
        let entitlements = try sourceFileContents("Support/Entitlements/PasteBuddy.entitlements")

        XCTAssertTrue(settingsSource.contains("Contents/MacOS/PasteBuddyMCP"))
        XCTAssertTrue(buildSource.contains("MCP_BUILD_BINARY"))
        XCTAssertTrue(buildSource.contains("$APP_MACOS/PasteBuddyMCP"))
        XCTAssertTrue(buildSource.contains("--entitlements"))
        XCTAssertTrue(entitlements.contains("iCloud.com.alexjiang.PasteBuddy"))
        XCTAssertTrue(appSource.contains("CloudKitRemoteRecordTransport"))
        XCTAssertTrue(appSource.contains("importLatestCloudSyncSnapshot"))
        XCTAssertTrue(appSource.contains("uploadCloudSyncSnapshot"))
    }

    func testPanelHotKeyMatcherSeparatesSidePanelAndShelfActions() {
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
            .sidePanel
        )
        XCTAssertEqual(
            PasteBuddyPanelHotKeyMatcher.action(
                keyCode: Int64(kVK_ANSI_S),
                flags: [.maskCommand, .maskShift]
            ),
            .shelf
        )
        for conflictingBinding in [
            ShortcutBinding(
                key: nil,
                modifiers: [.command, .shift],
                keyCode: UInt16(kVK_ANSI_S)
            ),
            ShortcutBinding(
                key: "g",
                modifiers: [.command, .shift],
                keyCode: UInt16(kVK_ANSI_S)
            ),
        ] {
            XCTAssertEqual(
                PasteBuddyPanelHotKeyMatcher.action(
                    keyCode: Int64(kVK_ANSI_S),
                    flags: [.maskCommand, .maskShift],
                    sidePanelShortcut: conflictingBinding
                ),
                .shelf
            )
        }
        XCTAssertEqual(
            PasteBuddyPanelHotKeyMatcher.action(
                keyCode: Int64(kVK_ANSI_S),
                flags: [.maskCommand, .maskShift],
                sidePanelShortcut: ShortcutBinding(
                    key: "s",
                    modifiers: [.command, .shift],
                    keyCode: UInt16(kVK_ANSI_S)
                )
            ),
            .shelf
        )
        XCTAssertNil(
            PasteBuddyPanelHotKeyMatcher.action(
                keyCode: Int64(kVK_ANSI_G),
                flags: [],
                sidePanelShortcut: ShortcutBinding(
                    key: "g",
                    modifiers: [],
                    keyCode: UInt16(kVK_ANSI_G)
                )
            )
        )
        XCTAssertEqual(
            PasteBuddyPanelHotKeyMatcher.action(
                keyCode: Int64(kVK_ANSI_2),
                flags: [.maskCommand, .maskShift]
            ),
            nil
        )
        XCTAssertEqual(
            PasteBuddyPanelHotKeyMatcher.action(
                keyCode: Int64(kVK_ANSI_P),
                flags: [.maskCommand, .maskShift]
            ),
            .pinClipboard
        )

        XCTAssertFalse(
            PasteBuddyPanelHotKeyMatcher.matches(
                keyCode: Int64(kVK_ANSI_S),
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
                flags: [.maskCommand, .maskShift]
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

    func testConfiguredPanelHotKeyIsDispatchableAtLaunchAndAfterSettingsChange() {
        let launchBinding = ShortcutConfiguration().showHidePanel
        XCTAssertEqual(
            PasteBuddyPanelHotKeyMatcher.action(
                keyCode: Int64(kVK_ANSI_V),
                flags: [.maskCommand, .maskShift],
                sidePanelShortcut: launchBinding
            ),
            .sidePanel
        )

        let changedBinding = ShortcutBinding(
            key: "g",
            modifiers: [.command, .option],
            keyCode: UInt16(kVK_ANSI_G)
        )
        XCTAssertEqual(
            PasteBuddyPanelHotKeyMatcher.action(
                keyCode: Int64(kVK_ANSI_G),
                flags: [.maskCommand, .maskAlternate],
                sidePanelShortcut: changedBinding
            ),
            .sidePanel
        )
        XCTAssertNil(
            PasteBuddyPanelHotKeyMatcher.action(
                keyCode: Int64(kVK_ANSI_V),
                flags: [.maskCommand, .maskShift],
                sidePanelShortcut: changedBinding
            )
        )
        XCTAssertEqual(
            PasteBuddyPanelHotKeyMatcher.action(
                keyCode: Int64(kVK_ANSI_S),
                flags: [.maskCommand, .maskShift],
                sidePanelShortcut: changedBinding
            ),
            .shelf
        )
    }

    func testPinboardCycleHotKeysAndLocalScopeWrapping() {
        let shortcuts = ShortcutConfiguration()
        XCTAssertEqual(
            PasteBuddyPanelHotKeyMatcher.action(
                keyCode: Int64(kVK_RightArrow),
                flags: [.maskCommand],
                nextPinboardShortcut: shortcuts.showNextPinboard,
                previousPinboardShortcut: shortcuts.showPreviousPinboard
            ),
            .nextPinboard
        )
        XCTAssertEqual(
            PasteBuddyPanelHotKeyMatcher.action(
                keyCode: Int64(kVK_LeftArrow),
                flags: [.maskCommand],
                nextPinboardShortcut: shortcuts.showNextPinboard,
                previousPinboardShortcut: shortcuts.showPreviousPinboard
            ),
            .previousPinboard
        )
        XCTAssertEqual(
            PasteBuddyPanelHotKeyMatcher.action(
                keyCode: Int64(kVK_ANSI_1),
                flags: [.maskCommand, .maskControl]
            ),
            .quickPaste(index: 0, format: .original)
        )
        XCTAssertEqual(
            PasteBuddyPanelHotKeyMatcher.action(
                keyCode: Int64(kVK_ANSI_9),
                flags: [.maskShift, .maskControl]
            ),
            .quickPaste(index: 8, format: .plainText)
        )
        XCTAssertEqual(
            PasteBuddyPanelHotKeyMatcher.action(
                keyCode: Int64(kVK_ANSI_C),
                flags: [.maskCommand, .maskShift]
            ),
            .pasteStack
        )

        let first = UUID()
        let second = UUID()
        XCTAssertEqual(
            PinboardCycleSelection.destination(
                from: .history,
                pinboardIDs: [first, second],
                direction: .next
            ),
            .pinboard(first)
        )
        XCTAssertEqual(
            PinboardCycleSelection.destination(
                from: .pinboard(second),
                pinboardIDs: [first, second],
                direction: .next
            ),
            .pinboard(first)
        )
        XCTAssertEqual(
            PinboardCycleSelection.destination(
                from: .pinboard(first),
                pinboardIDs: [first, second],
                direction: .previous
            ),
            .pinboard(second)
        )
    }

    func testRuntimeInstallsConfiguredHotKeysBeforeStartingNetworkSync() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/App/PasteBuddyApp.swift")
        let syncSource = try sourceFileContents("Sources/PasteBuddyCore/Services/IrohClipboardSyncService.swift")
        let runtimeStart = try XCTUnwrap(source.range(of: "private func startRuntimeIfNeeded() async"))
        let runtimeSource = source[runtimeStart.lowerBound...]
        let hotKeyInstallation = try XCTUnwrap(runtimeSource.range(of: "panelHotKeyController = PasteBuddyPanelHotKeyController("))
        let networkStart = try XCTUnwrap(
            runtimeSource.range(of: "Task { @MainActor in\n                await irohSync.start()")
        )

        XCTAssertLessThan(hotKeyInstallation.lowerBound, networkStart.lowerBound)
        XCTAssertTrue(runtimeSource.contains("sidePanelShortcut: store.snapshot.shortcuts.showHidePanel"))
        XCTAssertTrue(runtimeSource.contains("store.onShortcutConfigurationChanged"))
        XCTAssertTrue(runtimeSource.contains("irohSync.connectionState != .binding"))
        XCTAssertTrue(syncSource.contains("guard endpoint == nil, connectionState != .binding else { return }"))
    }

    func testImagePreviewRejectsStaleAsyncResultsAfterDismissOrItemChange() throws {
        for path in [
            "Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift",
            "Sources/PasteBuddy/Views/ClipboardSidePanelView.swift",
        ] {
            let source = try sourceFileContents(path)
            XCTAssertTrue(source.contains("let requestID = UUID()"))
            XCTAssertTrue(source.contains("!Task.isCancelled,"))
            XCTAssertTrue(source.contains("prepared.canPresent("))
            XCTAssertTrue(source.contains("currentRequestID: previewRequestID"))
            XCTAssertTrue(source.contains("previewRequestID = nil"))
        }
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

    func testShelfGlassSurfacesUseNativeTintWithoutStackedBase() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let bottomSheetStart = try XCTUnwrap(source.range(of: "func pasteBuddyBottomSheetSurface"))
        let glassSurfaceStart = try XCTUnwrap(source.range(of: "func pasteBuddyGlassSurface"))
        let bottomSheetSurface = String(source[bottomSheetStart.lowerBound..<glassSurfaceStart.lowerBound])
        let nativeGlassStart = try XCTUnwrap(bottomSheetSurface.range(of: "if #available(macOS 26.0, *)"))
        let fallbackStart = try XCTUnwrap(bottomSheetSurface.range(of: "} else {"))
        let nativeGlassBranch = String(bottomSheetSurface[nativeGlassStart.lowerBound..<fallbackStart.lowerBound])
        let glassSurface = String(source[glassSurfaceStart.lowerBound...])
        let smallNativeStart = try XCTUnwrap(glassSurface.range(of: "if #available(macOS 26.0, *)"))
        let smallFallbackStart = try XCTUnwrap(glassSurface.range(of: "} else {"))
        let smallNativeGlassBranch = String(glassSurface[smallNativeStart.lowerBound..<smallFallbackStart.lowerBound])

        XCTAssertFalse(source.contains("PasteBuddyGlassContainer"))
        XCTAssertFalse(source.contains("@State private var glassTintOpacity"))
        XCTAssertFalse(source.contains("ShelfGlassOpacityControl"))
        XCTAssertFalse(source.contains("Slider(value: $opacity"))
        XCTAssertFalse(source.contains("glassTintOpacity: glassTintOpacity"))
        XCTAssertTrue(source.contains("static let defaultTintOpacity = 0.30"))
        XCTAssertTrue(source.contains("static let detailSuppressionOpacity = 0.28"))
        XCTAssertTrue(source.contains("glassTintOpacity: Double = ClipboardShelfGlass.defaultTintOpacity"))
        XCTAssertTrue(source.contains("let tintOpacity = min(max(glassTintOpacity, 0), 1)"))
        XCTAssertTrue(nativeGlassBranch.contains(".fill(.thickMaterial)"))
        XCTAssertTrue(nativeGlassBranch.contains("ClipboardShelfGlass.detailSuppressionOpacity"))
        XCTAssertTrue(nativeGlassBranch.contains(".glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(tintOpacity)), in: shape)"))
        XCTAssertFalse(nativeGlassBranch.contains(".background"))
        XCTAssertFalse(bottomSheetSurface.contains("opacity(0.82)"))
        XCTAssertTrue(smallNativeGlassBranch.contains("Glass.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(tintOpacity)).interactive()"))
        XCTAssertFalse(smallNativeGlassBranch.contains(".background"))
    }

    func testPanelHostingViewDoesNotAddSecondRoundedClip() throws {
        let controllerSource = try sourceFileContents("Sources/PasteBuddy/App/ClipboardShelfPanelController.swift")

        XCTAssertTrue(controllerSource.contains("hostingView.configureForTransparentPanel()"))
        XCTAssertFalse(controllerSource.contains("configureForRoundedTransparentPanel"))
        XCTAssertFalse(controllerSource.contains("layer?.cornerRadius"))
        XCTAssertFalse(controllerSource.contains("layer?.masksToBounds"))
    }

    func testClipboardSidePanelReusesShelfGlassAndActions() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardSidePanelView.swift")
        let controllerSource = try sourceFileContents("Sources/PasteBuddy/App/ClipboardShelfPanelController.swift")
        let shelfSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")

        XCTAssertTrue(source.contains("struct ClipboardSidePanelView"))
        XCTAssertTrue(source.contains(".pasteBuddyBottomSheetSurface(cornerRadius: 28"))
        XCTAssertTrue(source.contains("ShelfToolbarCircleIcon"))
        XCTAssertTrue(source.contains("ShelfInteractionModel"))
        XCTAssertTrue(source.contains("SwiftUIShelfCollection"))
        XCTAssertTrue(source.contains("direction: .vertical"))
        XCTAssertFalse(source.contains("ShelfCollectionRepresentable"))
        XCTAssertTrue(source.contains("clipboard-side-panel-row-"))
        XCTAssertTrue(source.contains("prepareAndPresentPreview(for: item)"))
        XCTAssertTrue(source.contains("ShelfExpandedPreview"))
        XCTAssertTrue(source.contains("ClipboardImageThumbnailView"))
        XCTAssertTrue(source.contains("linkMetadataProvider: { item in"))
        XCTAssertTrue(source.contains("await store.enrichLinkPreviewMetadataIfNeeded(for: item)"))
        XCTAssertTrue(source.contains("item.visualPreview.prefersImageThumbnail"))
        XCTAssertTrue(source.contains("nonEmpty(item.visualPreview.headline)"))
        XCTAssertTrue(source.contains(".focusEffectDisabled()"))
        XCTAssertTrue(source.contains("ClipboardShelfDirectPasteCoordinator.runAfterImmediateDismissal"))
        XCTAssertTrue(source.contains("@Environment(\\.openSettings)"))
        XCTAssertTrue(source.contains("store.clearRequestedSettingsDestination()"))
        XCTAssertTrue(source.contains("onDismissImmediately()"))
        XCTAssertTrue(source.contains("openSettings()"))
        XCTAssertTrue(source.contains("NSApp.activate(ignoringOtherApps: true)"))
        XCTAssertFalse(source.contains("NSApp.setActivationPolicy(.regular)"))
        XCTAssertTrue(source.contains("ShelfToolbarCircleIcon(systemName: \"gearshape\")"))
        XCTAssertFalse(source.contains("store.toggleCapturePaused()"))
        XCTAssertFalse(source.contains("store.undoLastDeletion()"))
        XCTAssertTrue(source.contains("localized(\"label.clipboard\")"))
        XCTAssertTrue(source.contains("localized(\"action.paste_stack\")"))
        XCTAssertTrue(source.contains("ForEach(SmartPinboardCategory.allCases)"))
        XCTAssertTrue(source.contains("ForEach(store.userPinboards)"))
        XCTAssertTrue(source.contains("store.syncSmartPinboard(for: category)"))
        XCTAssertTrue(source.contains("setSideScope(.pinboard(pinboard.id))"))
        XCTAssertTrue(source.contains("NewPinboardNamePrompt.run()"))
        XCTAssertFalse(source.contains("@State private var isShowingNewPinboardSheet"))
        XCTAssertFalse(source.contains("NewPinboardSheet"))
        XCTAssertFalse(source.contains("NewTextItemSheet"))
        XCTAssertFalse(source.contains("label.new_text_item"))
        XCTAssertFalse(source.contains("label.today"))
        XCTAssertFalse(source.contains("label.filters"))
        XCTAssertFalse(source.contains("action.reload_clipboard_history"))
        XCTAssertTrue(source.contains("@Binding var isPinned: Bool"))
        XCTAssertFalse(source.contains("@State private var isPinnedVisual"))
        XCTAssertTrue(source.contains("@State private var pinnedState: Bool?"))
        XCTAssertTrue(source.contains("private var effectivePinned: Bool"))
        XCTAssertTrue(source.contains("private func setPinned(_ value: Bool)"))
        XCTAssertTrue(source.contains("setPinned(!effectivePinned)"))
        XCTAssertTrue(source.contains("ShelfToolbarCircleIcon(systemName: effectivePinned ? \"pin.fill\" : \"pin\")"))
        XCTAssertTrue(source.contains("let shouldDismissBeforePaste = !effectivePinned"))
        XCTAssertTrue(source.contains("dismissBeforePaste: shouldDismissBeforePaste"))
        XCTAssertFalse(source.contains("isPinned.toggle()"))
        XCTAssertTrue(source.contains("ClipboardImageCache.fittedDisplaySize("))
        XCTAssertTrue(source.contains(".frame(width: previewSize.width, height: previewSize.height)"))
        XCTAssertTrue(controllerSource.contains("isPinned: panelPinnedBinding()"))
        XCTAssertTrue(controllerSource.contains("private func panelPinnedBinding() -> Binding<Bool>"))
        XCTAssertFalse(source.contains(".frame(width: 72, height: 54)"))
        XCTAssertFalse(source.contains("square.grid.2x2"))
        XCTAssertFalse(source.contains("onTapGesture(count: 2)"))
        XCTAssertTrue(controllerSource.contains("ClipboardSidePanelView("))
        XCTAssertTrue(shelfSource.contains("enum ClipboardShelfGlass"))
        XCTAssertTrue(shelfSource.contains("struct ShelfToolbarCircleIcon"))
        XCTAssertTrue(shelfSource.contains("NewPinboardNamePrompt.run()"))
        XCTAssertFalse(shelfSource.contains("NewPinboardSheet"))
        XCTAssertFalse(shelfSource.contains("NewTextItemSheet"))
        XCTAssertFalse(shelfSource.contains("label.new_text_item"))
        XCTAssertTrue(shelfSource.contains("struct ClipboardImageThumbnailView"))
        XCTAssertTrue(shelfSource.contains("private var placeholderFill: Color"))
        XCTAssertTrue(shelfSource.contains("Color(nsColor: .controlBackgroundColor).opacity(0.42)"))
        XCTAssertTrue(shelfSource.contains("private var placeholderIconTint: Color"))
        XCTAssertTrue(shelfSource.contains("Color(nsColor: .secondaryLabelColor)"))
        XCTAssertTrue(shelfSource.contains("extension View"))

        let quickFilterStart = try XCTUnwrap(source.range(of: "private var quickFilterStrip"))
        let itemListStart = try XCTUnwrap(source.range(of: "private var itemList"))
        let quickFilterSource = String(source[quickFilterStart.lowerBound..<itemListStart.lowerBound])
        let scrollEnd = try XCTUnwrap(quickFilterSource.range(of: ".scrollIndicators(.never, axes: .horizontal)"))
        let addButtonStart = try XCTUnwrap(quickFilterSource.range(of: "Button {\n                createNamedPinboard()"))

        XCTAssertLessThan(scrollEnd.upperBound, addButtonStart.lowerBound)

        let promptSource = try sourceFileContents("Sources/PasteBuddy/Views/NewPinboardNamePrompt.swift")
        XCTAssertTrue(promptSource.contains("NSAlert()"))
        XCTAssertTrue(promptSource.contains("alert.runModal()"))
    }

    func testSwiftUIShelfCollectionHasNoAppKitCollectionBridge() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/SwiftUIShelfCollection.swift")

        XCTAssertTrue(source.contains("struct SwiftUIShelfCollection"))
        XCTAssertTrue(source.contains("ScrollViewReader"))
        XCTAssertTrue(source.contains("ScrollView(.horizontal)"))
        XCTAssertTrue(source.contains("ScrollView(.vertical)"))
        XCTAssertTrue(source.contains(".focusEffectDisabled()"))
        XCTAssertFalse(source.contains("NSViewRepresentable"))
        XCTAssertFalse(source.contains("NSCollectionView"))
        XCTAssertFalse(source.contains("NSScrollView"))
        XCTAssertFalse(source.contains("focusRingType"))
    }

    func testSwiftUIShelfCollectionSuppressesVisibleScrollers() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/SwiftUIShelfCollection.swift")

        XCTAssertTrue(source.contains(".scrollIndicators(.never, axes: .horizontal)"))
        XCTAssertTrue(source.contains(".scrollIndicators(.never, axes: .vertical)"))
        XCTAssertTrue(source.contains(".padding(.horizontal, 2)"))
        XCTAssertFalse(source.contains(".scrollIndicators(.hidden)"))
        XCTAssertFalse(source.contains("NSScroller"))
    }

    func testShelfAndSidePanelAuxiliaryScrollViewsSuppressVisibleScrollers() throws {
        let shelfSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let sideSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardSidePanelView.swift")

        XCTAssertEqual(shelfSource.components(separatedBy: ".scrollIndicators(.never, axes: .horizontal)").count - 1, 2)
        XCTAssertTrue(sideSource.contains(".scrollIndicators(.never, axes: .horizontal)"))
        XCTAssertFalse(shelfSource.contains(".scrollIndicators(.hidden)"))
        XCTAssertFalse(sideSource.contains(".scrollIndicators(.hidden)"))
    }

    func testShelfAndSidePanelUsePagedLocalSelectionLists() throws {
        let shelfSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let sideSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardSidePanelView.swift")

        XCTAssertTrue(shelfSource.contains("let items = store.filteredItemsPage(for: shelfScope, offset: 0)"))
        XCTAssertTrue(sideSource.contains("let items = store.filteredItemsPage(for: sideScope, offset: 0)"))
        XCTAssertTrue(sideSource.contains("totalCount: store.filteredItemCount(for: sideScope)"))
        XCTAssertFalse(shelfSource.contains("store.fullFilteredItems(for: shelfScope)"))
        XCTAssertFalse(sideSource.contains("store.fullFilteredItems(for: sideScope)"))
        XCTAssertFalse(sideSource.contains("totalCount: items.count"))
        for source in [shelfSource, sideSource] {
            XCTAssertFalse(source.contains("renderLimit"))
            XCTAssertFalse(source.contains("overflowCount"))
            XCTAssertFalse(source.contains("format.refine_search_or_filters_to_see_more"))
        }
        XCTAssertFalse(shelfSource.contains("ShelfOverflowStatusCard"))
    }

    func testSwiftUIShelfCollectionScrollsPrimarySelectionIntoView() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/SwiftUIShelfCollection.swift")

        XCTAssertTrue(source.contains(".onChange(of: primarySelectedID)"))
        XCTAssertTrue(source.contains("primarySelectedID != lastScrolledPrimarySelectedID"))
        XCTAssertTrue(source.contains("items.contains(where: { $0.id == primarySelectedID })"))
        XCTAssertTrue(source.contains("proxy.scrollTo(primarySelectedID)"))
        XCTAssertFalse(source.contains("anchor: .center"))
        XCTAssertFalse(source.contains("withAnimation(.smooth"))
        XCTAssertFalse(source.contains("ShelfCollectionScrollMath.origin("))
        XCTAssertFalse(source.contains("collectionView.scrollToItems("))
    }

    func testShelfAndSidePanelUseLifecycleScopedModifierAwareArrowOwner() throws {
        let collectionSource = try sourceFileContents("Sources/PasteBuddy/Views/SwiftUIShelfCollection.swift")
        let shelfSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let sideSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardSidePanelView.swift")
        let controllerSource = try sourceFileContents("Sources/PasteBuddy/App/ClipboardShelfPanelController.swift")

        XCTAssertTrue(collectionSource.contains(".onTapGesture(count: 2)"))
        XCTAssertTrue(collectionSource.contains(".simultaneousGesture("))
        XCTAssertTrue(collectionSource.contains("TapGesture().onEnded"))
        XCTAssertFalse(collectionSource.contains(".onTapGesture {"))
        for source in [shelfSource, sideSource] {
            XCTAssertTrue(source.contains("private func handlePanelArrowKey(_ request: ClipboardPanelArrowKeyRequest)"))
            XCTAssertTrue(source.contains("guard !isSearchFocused"))
            XCTAssertTrue(source.contains("previewedID == nil"))
            XCTAssertTrue(source.contains("request.markHandled()"))
            XCTAssertFalse(source.contains("shelfKeyboardShortcuts"))
            XCTAssertFalse(source.contains("sidePanelKeyboardShortcuts"))
        }
        XCTAssertTrue(controllerSource.contains("private var localKeyDownMonitor: Any?"))
        XCTAssertTrue(controllerSource.contains("startPanelKeyMonitoring(for: panel)"))
        XCTAssertTrue(controllerSource.contains("stopPanelKeyMonitoring()"))
    }

    func testShelfSingleClickSelectionIsImmediateAndOnlyDoubleClickPastes() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/SwiftUIShelfCollection.swift")
        let agents = try sourceFileContents("AGENTS.md")
        let itemStart = try XCTUnwrap(source.range(of: "private func collectionItem"))
        let itemEnd = try XCTUnwrap(source.range(of: "\n    private var itemIDs", range: itemStart.lowerBound..<source.endIndex))
        let itemSource = String(source[itemStart.lowerBound..<itemEnd.lowerBound])
        let dragProvider = try XCTUnwrap(itemSource.range(of: "itemView.onDrag { provider }"))
        let doubleTap = try XCTUnwrap(itemSource.range(of: ".onTapGesture(count: 2)"))
        let doubleClick = try XCTUnwrap(itemSource.range(of: "onDoubleClick(itemID)"))
        let simultaneousTap = try XCTUnwrap(itemSource.range(of: ".simultaneousGesture("))
        let suppressScroll = try XCTUnwrap(itemSource.range(of: "lastScrolledPrimarySelectedID = itemID"))
        let select = try XCTUnwrap(itemSource.range(of: "onSelect(itemID)"))
        let popover = try XCTUnwrap(itemSource.range(of: ".popover("))

        XCTAssertLessThan(dragProvider.lowerBound, doubleTap.lowerBound)
        XCTAssertLessThan(doubleTap.lowerBound, doubleClick.lowerBound)
        XCTAssertLessThan(doubleClick.lowerBound, simultaneousTap.lowerBound)
        XCTAssertLessThan(simultaneousTap.lowerBound, suppressScroll.lowerBound)
        XCTAssertLessThan(suppressScroll.lowerBound, select.lowerBound)
        XCTAssertLessThan(select.lowerBound, popover.lowerBound)
        XCTAssertFalse(itemSource.contains(".onTapGesture {"))
        XCTAssertFalse(itemSource.contains(".exclusively(before: TapGesture())"))
        XCTAssertTrue(agents.contains("Shelf / Side Panel 卡片必须单击立即选中，只有双击执行粘贴"))
    }

    func testClipboardPanelsUseNativeCopyCommandForTheirLocalSelection() throws {
        let shelfSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let sideSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardSidePanelView.swift")
        let controllerSource = try sourceFileContents("Sources/PasteBuddy/App/ClipboardShelfPanelController.swift")

        for source in [shelfSource, sideSource] {
            XCTAssertTrue(source.contains(".onCopyCommand {"))
            XCTAssertTrue(source.contains("ClipboardPanelCopyCoordinator.itemProviders("))
            XCTAssertTrue(source.contains("await store.hydratedItem(for: item)"))
            XCTAssertTrue(source.contains(".onReceive(NotificationCenter.default.publisher(for: .pasteBuddyCopyPanelSelection))"))
            XCTAssertTrue(source.contains("let request = ClipboardPanelCopyGate.begin()"))
            XCTAssertTrue(source.contains("let hydratedItems = await store.hydratedItems(for: items)"))
            XCTAssertTrue(source.contains("guard ClipboardPanelCopyGate.shouldWrite(request) else { return }"))
            XCTAssertTrue(source.contains("ClipboardPanelCopyCoordinator.copy(hydratedItems, sourceWindow: sourceWindow)"))
            XCTAssertFalse(source.contains("PasteboardWriter.copy(hydratedItems)"))
            XCTAssertFalse(source.contains("characters == \"c\""))
        }
        XCTAssertTrue(controllerSource.contains("@objc func copy(_ sender: Any?)"))
        XCTAssertTrue(controllerSource.contains("NotificationCenter.default.post(name: .pasteBuddyCopyPanelSelection, object: self)"))
        XCTAssertFalse(controllerSource.contains("performKeyEquivalent"))
    }

    func testPanelCopyGateRejectsStaleRequestsAndExternalPasteboardChanges() throws {
        let pasteboard = try XCTUnwrap(
            NSPasteboard(name: NSPasteboard.Name("PasteBuddyPanelCopyGate-\(UUID().uuidString)"))
        )
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()

        let first = ClipboardPanelCopyGate.begin(pasteboard: pasteboard)
        let second = ClipboardPanelCopyGate.begin(pasteboard: pasteboard)

        XCTAssertFalse(ClipboardPanelCopyGate.shouldWrite(first, pasteboard: pasteboard))
        XCTAssertTrue(ClipboardPanelCopyGate.shouldWrite(second, pasteboard: pasteboard))

        pasteboard.clearContents()
        pasteboard.setString("newer external copy", forType: .string)
        XCTAssertFalse(ClipboardPanelCopyGate.shouldWrite(second, pasteboard: pasteboard))
    }

    func testPanelPasteCommandRoutesCardsButPreservesEditableFieldPaste() {
        let editableFieldEditor = NSTextView()
        editableFieldEditor.isEditable = true
        let editableField = NSTextField()
        editableField.isEditable = true
        editableField.isEnabled = true
        let noneditableText = NSTextView()
        noneditableText.isEditable = false

        XCTAssertFalse(
            ClipboardPanelPasteCommandRouter.shouldRouteSelectionPaste(
                firstResponder: editableFieldEditor
            )
        )
        XCTAssertFalse(
            ClipboardPanelPasteCommandRouter.shouldRouteSelectionPaste(
                firstResponder: editableField
            )
        )
        XCTAssertTrue(
            ClipboardPanelPasteCommandRouter.shouldRouteSelectionPaste(
                firstResponder: noneditableText
            )
        )
        XCTAssertTrue(
            ClipboardPanelPasteCommandRouter.shouldRouteSelectionPaste(
                firstResponder: NSView()
            )
        )
    }

    func testPanelWindowOwnsNativePasteResponder() {
        let panel = ClipboardShelfPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let routed = expectation(description: "Panel routes paste through the shared selection notification")
        let observer = NotificationCenter.default.addObserver(
            forName: .pasteBuddyPastePanelSelection,
            object: panel,
            queue: nil
        ) { _ in
            routed.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        panel.paste(nil)

        XCTAssertTrue(panel.responds(to: #selector(ClipboardShelfPanel.paste(_:))))
        wait(for: [routed], timeout: 0.1)
    }

    func testPanelPasteGateRejectsStaleAsyncSelection() {
        let first = ClipboardPanelPasteGate.begin()
        let second = ClipboardPanelPasteGate.begin()

        XCTAssertFalse(ClipboardPanelPasteGate.shouldPaste(first))
        XCTAssertTrue(ClipboardPanelPasteGate.shouldPaste(second))
    }

    func testBothPanelModesShareNativeCommandVPasteRoute() throws {
        let shelfSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let sideSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardSidePanelView.swift")
        let controllerSource = try sourceFileContents("Sources/PasteBuddy/App/ClipboardShelfPanelController.swift")

        for source in [shelfSource, sideSource] {
            XCTAssertTrue(source.contains("NotificationCenter.default.publisher(for: .pasteBuddyPastePanelSelection)"))
            XCTAssertTrue(source.contains("pasteSelected(format: store.defaultPasteFormat)"))
            XCTAssertTrue(source.contains("let request = ClipboardPanelPasteGate.begin()"))
            XCTAssertTrue(source.contains("guard ClipboardPanelPasteGate.shouldPaste(request) else { return nil }"))
        }
        XCTAssertTrue(controllerSource.contains("@objc func paste(_ sender: Any?)"))
        XCTAssertTrue(controllerSource.contains("ClipboardPanelPasteCommandRouter.shouldRouteSelectionPaste"))
        XCTAssertTrue(controllerSource.contains("ClipboardPanelPasteCommandRouter.forwardNativePaste"))
        XCTAssertTrue(controllerSource.contains("NotificationCenter.default.post(name: .pasteBuddyPastePanelSelection"))
    }

    func testSwiftUIShelfCollectionUsesSwiftUIPopover() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/SwiftUIShelfCollection.swift")

        XCTAssertTrue(source.contains(".popover("))
        XCTAssertTrue(source.contains("isPresented: presentedPreviewBinding(for: itemID)"))
        XCTAssertTrue(source.contains("attachmentAnchor: .rect(.bounds)"))
        XCTAssertTrue(source.contains("arrowEdge: previewArrowEdge"))
        XCTAssertTrue(source.contains("presentedPreviewID == id"))
        XCTAssertTrue(source.contains("presentedPreviewID = nil"))
        XCTAssertTrue(source.contains("await Task.yield()"))
        XCTAssertTrue(source.contains("onPreviewDismiss(id)"))
        XCTAssertFalse(source.contains("positioningRect"))
        XCTAssertFalse(source.contains("reanchorPopoverIfNeeded"))
        XCTAssertFalse(source.contains("RunLoop.main.perform"))
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
        XCTAssertTrue(gate.shouldTrigger(action: .shelf, source: .eventTap, now: now.addingTimeInterval(0.35)))
        XCTAssertFalse(gate.shouldTrigger(action: .shelf, source: .carbon, now: now.addingTimeInterval(0.45)))

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

    func testPanelDirectPasteRechecksTargetAndKeepsConfiguredFocusSettlementDelay() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/App/PasteBuddyApp.swift")
        let shelfSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let sideSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardSidePanelView.swift")

        XCTAssertEqual(
            source.components(separatedBy: "targetBundleIdentifier: targetBundleIdentifier").count - 1,
            2
        )
        XCTAssertEqual(
            source.components(
                separatedBy: "tracker.frontmostApplicationBundleIdentifier()"
            ).count - 1,
            2
        )
        XCTAssertEqual(
            source.components(
                separatedBy: "options: PasteboardWriter.userConfiguredPasteOnlyDirectPasteOptions"
            ).count - 1,
            2
        )
        XCTAssertFalse(source.contains("pasteDispatchDelay: 0"))
        for panelSource in [shelfSource, sideSource] {
            XCTAssertGreaterThanOrEqual(
                panelSource.components(separatedBy: "ClipboardPanelPasteGate.begin()").count - 1,
                2
            )
            XCTAssertGreaterThanOrEqual(
                panelSource.components(
                    separatedBy: "ClipboardPanelPasteGate.shouldPaste(request)"
                ).count - 1,
                2
            )
        }
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

    private func loadData(from provider: NSItemProvider, typeIdentifier: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: CocoaError(.fileReadUnknown))
                }
            }
        }
    }

    private func containsRenderedImage(in view: NSView) -> Bool {
        if let imageView = view as? NSImageView, imageView.image != nil {
            return true
        }
        return view.subviews.contains(where: containsRenderedImage)
    }

    private func makeShelfItem(
        title: String,
        contentType: ClipboardContentType = .text
    ) -> ClipboardItem {
        ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: contentType,
            title: title,
            payload: contentType == .image
                ? ClipboardPayload(imageData: Data([0x01]))
                : ClipboardPayload(text: title)
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

    private func sourceFileContents(_ relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return String(decoding: try Data(contentsOf: candidate), as: UTF8.self)
            }
            directory.deleteLastPathComponent()
        }
        throw XCTSkip("Could not locate \(relativePath) from \(FileManager.default.currentDirectoryPath)")
    }

    private func sourceFileExists(_ relativePath: String) -> Bool {
        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return true
            }
            directory.deleteLastPathComponent()
        }
        return false
    }
}
