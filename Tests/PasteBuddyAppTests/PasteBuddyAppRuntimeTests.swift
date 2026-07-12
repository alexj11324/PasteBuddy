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

    func testDevelopmentPanelURLIsRegisteredAndRoutedOnlyForStableDevApp() throws {
        let appSource = try sourceFileContents("Sources/PasteBuddy/App/PasteBuddyApp.swift")
        let buildSource = try sourceFileContents("script/build_and_run.sh")
        XCTAssertTrue(sourceFileExists("script/open_dev_panel.sh"))
        guard sourceFileExists("script/open_dev_panel.sh") else { return }
        let commandSource = try sourceFileContents("script/open_dev_panel.sh")

        XCTAssertTrue(appSource.contains("appDelegate.handleOpenURLs ="))
        XCTAssertTrue(appSource.contains("PasteBuddyDevelopmentPanelCommand.parse("))
        XCTAssertTrue(appSource.contains("await toggleClipboardShelf()"))
        XCTAssertTrue(appSource.contains("await showClipboardPanelMode(mode)"))

        XCTAssertTrue(buildSource.contains("\"$SIGNING_CHANNEL\" == \"development\""))
        XCTAssertTrue(buildSource.contains("\"$BUNDLE_ID\" == \"com.alexjiang.PasteBuddy.dev\""))
        XCTAssertTrue(buildSource.contains("CFBundleURLTypes"))
        XCTAssertTrue(buildSource.contains("pastebuddy-dev"))

        XCTAssertTrue(commandSource.contains("/Applications/PasteBuddy Dev.app"))
        XCTAssertTrue(commandSource.contains("codesign --verify --deep --strict"))
        XCTAssertTrue(commandSource.contains("Authority=Apple Development:"))
        XCTAssertTrue(commandSource.contains("/usr/bin/open -g -a \"$APP_BUNDLE\" \"$url\""))
        XCTAssertFalse(commandSource.contains("osascript"))
    }

    func testDevelopmentPanelShowRefreshesTheCurrentPasteTargetBeforePresentation() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/App/PasteBuddyApp.swift")
        let functionStart = try XCTUnwrap(source.range(of: "private func showClipboardPanelMode"))
        let functionEnd = try XCTUnwrap(
            source.range(of: "\n    private func startRuntimeIfNeeded", range: functionStart.lowerBound..<source.endIndex)
        )
        let functionSource = String(source[functionStart.lowerBound..<functionEnd.lowerBound])
        let refreshTarget = try XCTUnwrap(functionSource.range(of: "frontmostApplicationTracker.recordCurrentFrontmostApplication()"))
        let showPanel = try XCTUnwrap(functionSource.range(of: "shelfPanelController?.show()"))

        XCTAssertLessThan(refreshTarget.lowerBound, showPanel.lowerBound)
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
            await gate.loadIfNeeded {
                await loader.load()
            }
            secondCallerCompleted = true
        }
        await Task.yield()

        XCTAssertFalse(secondCallerCompleted)
        let callCountBeforeRelease = await loader.callCount()
        XCTAssertEqual(callCountBeforeRelease, 1)

        await loader.release()
        await firstCaller.value
        await secondCaller.value

        XCTAssertTrue(secondCallerCompleted)
        let finalCallCount = await loader.callCount()
        XCTAssertEqual(finalCallCount, 1)
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

    func testShelfAndMobileLongTextPreviewsRequireExplicitExpansion() throws {
        let shelfSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let mobileSource = try sourceFileContents("Sources/PasteBuddyMobile/MobileClipboardBrowserView.swift")
        let shelfPreviewStart = try XCTUnwrap(shelfSource.range(of: "struct ShelfExpandedPreview"))
        let shelfImageStart = try XCTUnwrap(shelfSource.range(of: "private struct ShelfExpandedImagePreview"))
        let shelfPreviewSource = String(shelfSource[shelfPreviewStart.lowerBound..<shelfImageStart.lowerBound])
        let mobilePreviewStart = try XCTUnwrap(mobileSource.range(of: "private struct MobileClipboardItemDetailView"))
        let mobileSummaryStart = try XCTUnwrap(mobileSource.range(of: "private struct MobileVisualPreviewSummary"))
        let mobilePreviewSource = String(mobileSource[mobilePreviewStart.lowerBound..<mobileSummaryStart.lowerBound])

        XCTAssertTrue(shelfSource.contains("static let initialCharacterLimit = 8_000"))
        XCTAssertTrue(shelfPreviewSource.contains("@State private var showsFullText = false"))
        XCTAssertTrue(shelfPreviewSource.contains("ClipboardTextPreview(text.isEmpty ? item.visualPreview.body : text)"))
        XCTAssertTrue(shelfPreviewSource.contains("preview.text(showingFullText: showsFullText)"))
        XCTAssertTrue(shelfPreviewSource.contains("if preview.isTruncated && !showsFullText"))
        XCTAssertTrue(shelfPreviewSource.contains("Label(\"label.more\", systemImage: \"ellipsis\")"))
        XCTAssertFalse(shelfPreviewSource.contains("Text(text.isEmpty ? item.visualPreview.body : text)"))

        XCTAssertTrue(mobileSource.contains("static let initialCharacterLimit = 8_000"))
        XCTAssertTrue(mobilePreviewSource.contains("@State private var showsFullText = false"))
        XCTAssertTrue(mobilePreviewSource.contains("MobileClipboardTextPreview(ClipboardPlainTextRenderer.plainText(for: item))"))
        XCTAssertTrue(mobilePreviewSource.contains("textPreview.text(showingFullText: showsFullText)"))
        XCTAssertTrue(mobilePreviewSource.contains("if textPreview.isTruncated && !showsFullText"))
        XCTAssertTrue(mobilePreviewSource.contains("Label(\"label.more\", systemImage: \"ellipsis\")"))
        XCTAssertFalse(mobilePreviewSource.contains("Text(ClipboardPlainTextRenderer.plainText(for: item))"))
        XCTAssertTrue(mobilePreviewSource.contains("MobilePasteboardWriter.copy(item)"))
        XCTAssertTrue(mobilePreviewSource.contains("MobilePasteboardWriter.copy(item, format: .plainText)"))
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
        XCTAssertTrue(shelfSource.contains("dragPayload: { displayItem in"))
        XCTAssertTrue(shelfSource.contains("plainTextProvider: { ClipboardPlainTextRenderer.plainText(for: item) }"))
        XCTAssertFalse(shelfSource.contains("dragItemProvider: { displayItem in"))
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
        XCTAssertTrue(sideSource.contains("dragPayload: { item in"))
        XCTAssertTrue(sideSource.contains("plainTextProvider: { ClipboardPlainTextRenderer.plainText(for: item) }"))
        XCTAssertFalse(sideSource.contains("dragItemProvider: { item in"))
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
        XCTAssertTrue(collectionSource.contains("private func syncPresentedPreview()"))
        XCTAssertTrue(collectionSource.contains("await Task.yield()"))
        XCTAssertTrue(collectionSource.contains("onPreviewDismiss(id)"))
        XCTAssertTrue(collectionSource.contains("proxy.scrollTo(primarySelectedID)"))
        XCTAssertFalse(collectionSource.contains("anchor: .center"))
        XCTAssertFalse(collectionSource.contains("var dragItemProvider: ((Item) -> NSItemProvider?)?"))
        XCTAssertFalse(collectionSource.contains(".onDrag { provider }"))
        XCTAssertTrue(collectionSource.contains(".draggable(payload)"))
        XCTAssertTrue(collectionSource.contains("TapGesture(count: 2)"))
        XCTAssertTrue(collectionSource.contains(".simultaneousGesture("))
        XCTAssertFalse(collectionSource.contains(".exclusively(before: TapGesture())"))
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
        XCTAssertTrue(dragSource.contains("var plainText: String"))
        XCTAssertTrue(dragSource.contains("private let plainTextProvider: @Sendable () -> String"))
        XCTAssertTrue(dragSource.contains("CodableRepresentation(contentType: .pasteBuddyPinboardItemIDs)"))
        XCTAssertTrue(dragSource.contains("ProxyRepresentation(exporting: \\.plainText)"))
        XCTAssertFalse(dragSource.contains("NSItemProvider"))
        XCTAssertFalse(dragSource.contains("ClipboardItemDragProvider"))
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

    func testPointerSelectionIsImmediateWithoutRemovingDoubleClickOrDrag() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/SwiftUIShelfCollection.swift")
        let itemStart = try XCTUnwrap(source.range(of: "private func collectionItem"))
        let itemEnd = try XCTUnwrap(source.range(of: "\n    private var itemIDs", range: itemStart.lowerBound..<source.endIndex))
        let itemSource = String(source[itemStart.lowerBound..<itemEnd.lowerBound])
        let draggable = try XCTUnwrap(itemSource.range(of: "itemView.draggable(payload)"))
        let pointerSelection = try XCTUnwrap(itemSource.range(of: ".simultaneousGesture("))
        let doubleClick = try XCTUnwrap(itemSource.range(of: "onDoubleClick(itemID)"))
        let suppressScroll = try XCTUnwrap(itemSource.range(of: "lastScrolledPrimarySelectedID = itemID"))
        let select = try XCTUnwrap(itemSource.range(of: "onSelect(itemID)"))

        XCTAssertLessThan(draggable.lowerBound, pointerSelection.lowerBound)
        XCTAssertLessThan(suppressScroll.lowerBound, select.lowerBound)
        XCTAssertNotEqual(doubleClick.lowerBound, select.lowerBound)
    }

    func testCardSelectionRequestsKeyboardFocusWithoutActivatingPanelOnShow() throws {
        let controllerSource = try sourceFileContents("Sources/PasteBuddy/App/ClipboardShelfPanelController.swift")
        let shelfSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let sideSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardSidePanelView.swift")

        XCTAssertTrue(controllerSource.contains("styleMask: [.borderless, .nonactivatingPanel]"))
        XCTAssertTrue(controllerSource.contains("panel.becomesKeyOnlyIfNeeded = true"))
        let showStart = try XCTUnwrap(controllerSource.range(of: "func show()"))
        let showEnd = try XCTUnwrap(controllerSource.range(of: "\n    func hideImmediately()", range: showStart.lowerBound..<controllerSource.endIndex))
        XCTAssertFalse(String(controllerSource[showStart.lowerBound..<showEnd.lowerBound]).contains("panel.makeKey()"))
        XCTAssertTrue(controllerSource.contains("private func requestPanelKeyboardFocus()"))
        XCTAssertTrue(controllerSource.contains("panel.makeKey()"))
        XCTAssertEqual(controllerSource.components(separatedBy: "onRequestKeyboardFocus: { [weak self] in").count - 1, 2)

        let onAppearStart = try XCTUnwrap(sideSource.range(of: ".onAppear {"))
        let onAppearEnd = try XCTUnwrap(sideSource.range(of: "\n        .onDisappear", range: onAppearStart.lowerBound..<sideSource.endIndex))
        let onAppearSource = String(sideSource[onAppearStart.lowerBound..<onAppearEnd.lowerBound])
        XCTAssertTrue(onAppearSource.contains("isSearchFocused = false"))
        XCTAssertTrue(onAppearSource.contains("isListFocused = false"))
        XCTAssertFalse(onAppearSource.contains("setSearchFocused(false)"))

        for source in [shelfSource, sideSource] {
            XCTAssertTrue(source.contains("let onRequestKeyboardFocus: () -> Void"))
            let selectStart = try XCTUnwrap(source.range(of: "private func selectItem"))
            let selectEnd = try XCTUnwrap(source.range(of: "\n    private func selectSingleItem", range: selectStart.lowerBound..<source.endIndex))
            let selectSource = String(source[selectStart.lowerBound..<selectEnd.lowerBound])
            XCTAssertTrue(selectSource.contains("setSearchFocused(false)"))
            XCTAssertTrue(selectSource.contains("await Task.yield()"))
            XCTAssertTrue(selectSource.contains("onRequestKeyboardFocus()"))
        }
    }

    func testSidePanelPreviewFollowsSelectionWithoutDeferredHandoff() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardSidePanelView.swift")

        XCTAssertTrue(source.contains("selectSingleItem(items[nextIndex].id, keepsPreviewOpen: interaction.previewedID != nil)"))
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
            XCTAssertTrue(source.contains("store.searchQuery = \"\""))
            XCTAssertTrue(source.contains("store.clearFilters()"))
            XCTAssertTrue(source.contains("await Task.yield()"))
            XCTAssertTrue(source.contains("setSearchFocused(false)"))
            XCTAssertTrue(source.contains(".focusEffectDisabled()"))
            XCTAssertTrue(source.contains("if modifiers.isEmpty, !isSearchFocused"))
            XCTAssertTrue(source.contains("case .leftArrow:"))
            XCTAssertTrue(source.contains("moveSelection(.left)"))
            XCTAssertTrue(source.contains("case .rightArrow:"))
            XCTAssertTrue(source.contains("moveSelection(.right)"))
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

        XCTAssertFalse(shelfSource.contains("store.setSelectedItemIDs(ids, in: shelfScope)"))
        XCTAssertFalse(sideSource.contains("store.setSelectedItemIDs(ids, in: sideScope)"))
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
        XCTAssertFalse(shelfSource.contains("NSEvent.addLocalMonitorForEvents(matching: .keyDown)"))
        XCTAssertFalse(shelfSource.contains("event.window === self.window"))
        XCTAssertFalse(shelfSource.contains("NSEvent.removeMonitor(keyMonitor)"))
        XCTAssertTrue(controllerSource.contains("reloadPanelContent(panel)"))
        XCTAssertTrue(controllerSource.contains("hostingView.rootView = panelContentView()"))
        XCTAssertTrue(controllerSource.contains("panelPresentationID = UUID()"))
        XCTAssertTrue(controllerSource.contains(".id(panelPresentationID)"))
        XCTAssertTrue(controllerSource.contains("resetPanelPresentationState()"))
        XCTAssertTrue(controllerSource.contains("store.selectSingleItem(store.filteredItems(for: store.selectedScope).first?.id)"))
        XCTAssertTrue(controllerSource.contains("closeShelfAuxiliaryWindows()"))
        XCTAssertTrue(controllerSource.contains("for window in NSApp.windows where Self.isShelfAuxiliaryWindow(window)"))
    }

    func testShelfExpandedImagePreviewUsesAppleLiveTextInsteadOfOCRTextBox() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let previewStart = try XCTUnwrap(source.range(of: "private var previewContent"))
        let imageStart = try XCTUnwrap(source.range(of: "private struct ShelfExpandedImagePreview"))
        let nextViewStart = try XCTUnwrap(source.range(of: "private struct ClipboardShelfCardVisual"))
        let expandedPreviewStart = try XCTUnwrap(source.range(of: "struct ShelfExpandedPreview"))
        let expandedPreviewSource = String(source[expandedPreviewStart.lowerBound..<imageStart.lowerBound])
        let previewContentSource = String(source[previewStart.lowerBound..<imageStart.lowerBound])
        let imagePreviewSource = String(source[imageStart.lowerBound..<nextViewStart.lowerBound])

        XCTAssertTrue(source.contains("import VisionKit"))
        XCTAssertTrue(imagePreviewSource.contains("ShelfLiveTextImagePreview("))
        XCTAssertTrue(imagePreviewSource.contains("ImageAnalysisOverlayView"))
        XCTAssertTrue(imagePreviewSource.contains("ImageAnalyzer().analyze"))
        XCTAssertTrue(imagePreviewSource.contains("preferredInteractionTypes = .automaticTextOnly"))
        XCTAssertTrue(imagePreviewSource.contains("trackingImageView = imageView"))
        XCTAssertTrue(imagePreviewSource.contains("imageView.addSubview(overlayView)"))
        XCTAssertTrue(imagePreviewSource.contains("NSImage(data: imageData)"))
        XCTAssertTrue(imagePreviewSource.contains("liveTextImage = loadedImage"))
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
        XCTAssertTrue(source.contains("imagePreviewDisplaySize.height + 28"))
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
        XCTAssertTrue(shelfSource.contains(".frame(height: ClipboardShelfMetrics.linkMetadataFooterHeight)"))
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

    func testCollectionReorderDoesNotUseCopyPasteboardPayload() throws {
        let payloadSource = try sourceFileContents("Sources/PasteBuddy/Models/PinboardItemDragPayload.swift")
        let shelfSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")

        XCTAssertFalse(payloadSource.contains("ClipboardCollectionDragPayload"))
        XCTAssertFalse(payloadSource.contains("pasteBuddyCollectionID"))
        XCTAssertTrue(shelfSource.contains("DragGesture("))
        XCTAssertTrue(shelfSource.contains("minimumDistance: 4"))
        XCTAssertTrue(shelfSource.contains(".highPriorityGesture("))
        XCTAssertFalse(shelfSource.contains(".simultaneousGesture(\n                DragGesture("))
    }

    func testShelfAndSidePanelRenderSharedCollectionOrder() throws {
        let shelfSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let sideSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardSidePanelView.swift")

        for source in [shelfSource, sideSource] {
            XCTAssertTrue(source.contains("let collectionOrder = collectionDragSession.displayOrder(fallback: store.collectionOrder)"))
            XCTAssertTrue(source.contains("ForEach(collectionOrder) { collection in"))
            XCTAssertTrue(source.contains("collectionChip(for: collection, in: collectionOrder)"))
            XCTAssertTrue(source.contains("case .history:"))
            XCTAssertTrue(source.contains("case .pasteStack:"))
            XCTAssertTrue(source.contains("case .smart(let category):"))
            XCTAssertTrue(source.contains("case .pinboard(let id):"))
            XCTAssertTrue(source.contains("canMoveLeft: collectionOrder.first != collection"))
            XCTAssertTrue(source.contains("canMoveRight: collectionOrder.last != collection"))
            XCTAssertTrue(source.contains("onMoveLeft: { moveCollection(collection, by: -1) }"))
            XCTAssertTrue(source.contains("onMoveRight: { moveCollection(collection, by: 1) }"))
            XCTAssertFalse(source.contains("ForEach(SmartPinboardCategory.allCases)"))
            XCTAssertFalse(source.contains("ForEach(store.userPinboards)"))
        }
    }

    func testShelfCollectionChipsAcceptDraggedClipboardItems() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let stripStart = try XCTUnwrap(source.range(of: "private var collectionStrip"))
        let stripEnd = try XCTUnwrap(source.range(of: "private var selectedCount"))
        let chipStart = try XCTUnwrap(source.range(of: "private struct ShelfCollectionChip"))
        let selectedCountStart = try XCTUnwrap(source.range(of: "private struct ShelfSelectedCountChip"))
        let stripSource = String(source[stripStart.lowerBound..<stripEnd.lowerBound])
        let chipSource = String(source[chipStart.lowerBound..<selectedCountStart.lowerBound])

        XCTAssertTrue(source.contains("enum ClipboardCollectionDropTarget"))
        XCTAssertTrue(stripSource.contains("onDropPayloads: { dropItems($0, into: .history) }"))
        XCTAssertTrue(stripSource.contains("onDropPayloads: { dropItems($0, into: .pasteStack) }"))
        XCTAssertFalse(stripSource.contains("onDropPayloads: { dropItems($0, into: .smartCategory(category)) }"))
        XCTAssertTrue(stripSource.contains("onDropPayloads: { dropItems($0, into: .pinboard(pinboard.id)) }"))
        XCTAssertTrue(chipSource.contains("ClipboardCollectionReorderModifier("))
        XCTAssertTrue(source.contains("struct ClipboardCollectionCardDropModifier: ViewModifier"))
        XCTAssertTrue(source.contains("if let onDropPayloads"))
        XCTAssertTrue(source.contains("dropDestination(for: PinboardItemDragPayload.self"))
        XCTAssertFalse(source.contains("struct ShelfCollectionChipDropTarget"))
        XCTAssertFalse(source.contains("registerForDraggedTypes"))
        XCTAssertTrue(source.contains("store.pinItems(ids, to: pinboardID)"))
        XCTAssertTrue(source.contains("store.addItemsToPasteStack(ids)"))
        XCTAssertFalse(source.contains("case smartCategory(SmartPinboardCategory)"))
    }

    func testSidePanelCollectionChipsAcceptDraggedClipboardItemsWithCompactSpacing() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardSidePanelView.swift")
        let stripStart = try XCTUnwrap(source.range(of: "private var quickFilterStrip"))
        let stripEnd = try XCTUnwrap(source.range(of: "private var itemList"))
        let chipStart = try XCTUnwrap(source.range(of: "private struct ClipboardSidePanelFilterChip"))
        let rowStart = try XCTUnwrap(source.range(of: "private struct ClipboardSidePanelListRow"))
        let stripSource = String(source[stripStart.lowerBound..<stripEnd.lowerBound])
        let chipSource = String(source[chipStart.lowerBound..<rowStart.lowerBound])

        XCTAssertTrue(stripSource.contains("HStack(spacing: 5)"))
        XCTAssertTrue(stripSource.contains("onDropPayloads: { dropItems($0, into: .history) }"))
        XCTAssertTrue(stripSource.contains("onDropPayloads: { dropItems($0, into: .pasteStack) }"))
        XCTAssertFalse(stripSource.contains("onDropPayloads: { dropItems($0, into: .smartCategory(category)) }"))
        XCTAssertTrue(stripSource.contains("onDropPayloads: { dropItems($0, into: .pinboard(pinboard.id)) }"))
        XCTAssertTrue(chipSource.contains("ClipboardCollectionReorderModifier("))
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

    func testCollectionDragCompletionPersistsFinalOrderBeforeClearingPreview() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let handlerStart = try XCTUnwrap(source.range(of: "private func handleDragEnded"))
        let handlerEnd = try XCTUnwrap(
            source.range(
                of: "\n    }\n}\n\nstruct ClipboardCollectionCardDropModifier",
                range: handlerStart.lowerBound..<source.endIndex
            )
        )
        let handler = String(source[handlerStart.lowerBound..<handlerEnd.upperBound])
        let reorder = try XCTUnwrap(handler.range(of: "onReorder(move.source, move.target, move.afterTarget)"))
        let clearPreview = try XCTUnwrap(handler.range(of: "session.cancel()"))

        XCTAssertLessThan(reorder.lowerBound, clearPreview.lowerBound)
        XCTAssertFalse(handler.contains("session.complete()"))
    }

    func testCollectionReorderMeasuresStationarySlotOutsideVisualTransform() throws {
        let shelfSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let sideSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardSidePanelView.swift")
        let modifierStart = try XCTUnwrap(shelfSource.range(of: "struct ClipboardCollectionReorderModifier"))
        let modifierEnd = try XCTUnwrap(shelfSource.range(of: "struct ClipboardCollectionCardDropModifier"))
        let modifierSource = String(shelfSource[modifierStart.lowerBound..<modifierEnd.lowerBound])
        let visualEffect = try XCTUnwrap(modifierSource.range(of: ".visualEffect { content, geometry in"))
        let geometry = try XCTUnwrap(modifierSource.range(of: ".onGeometryChange("))

        XCTAssertTrue(modifierSource.contains("ZStack {"))
        XCTAssertLessThan(visualEffect.lowerBound, geometry.lowerBound)
        XCTAssertTrue(modifierSource.contains("currentSourceLayoutMinX"))
        for source in [shelfSource, sideSource] {
            XCTAssertTrue(source.contains(".scrollDisabled(collectionDragSession.isActive)"))
        }
    }

    func testDraggedCollectionVisualOffsetUsesCurrentRenderGeometry() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let modifierStart = try XCTUnwrap(source.range(of: "struct ClipboardCollectionReorderModifier"))
        let modifierEnd = try XCTUnwrap(source.range(of: "struct ClipboardCollectionCardDropModifier"))
        let modifierSource = String(source[modifierStart.lowerBound..<modifierEnd.lowerBound])

        XCTAssertTrue(modifierSource.contains(".visualEffect { content, geometry in"))
        XCTAssertTrue(modifierSource.contains("geometry.frame(in: .named(ClipboardCollectionDragCoordinateSpace.name)).minX"))
        XCTAssertFalse(modifierSource.contains("private var dragOffset"))
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

    func testShelfAndSideCollectionChipsUseSwiftUIAnimatedMoveReordering() throws {
        let shelfSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let sideSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardSidePanelView.swift")
        let shelfChipStart = try XCTUnwrap(shelfSource.range(of: "private struct ShelfCollectionChip"))
        let shelfChipEnd = try XCTUnwrap(shelfSource.range(of: "private struct ShelfSelectedCountChip"))
        let sideChipStart = try XCTUnwrap(sideSource.range(of: "private struct ClipboardSidePanelFilterChip"))
        let sideChipEnd = try XCTUnwrap(sideSource.range(of: "private struct ClipboardSidePanelListRow"))
        let shelfChipSource = String(shelfSource[shelfChipStart.lowerBound..<shelfChipEnd.lowerBound])
        let sideChipSource = String(sideSource[sideChipStart.lowerBound..<sideChipEnd.lowerBound])

        for chipSource in [shelfChipSource, sideChipSource] {
            XCTAssertTrue(chipSource.contains("let collection: ClipboardCollectionID"))
            XCTAssertTrue(chipSource.contains("let onReorder: (ClipboardCollectionID, ClipboardCollectionID, Bool) -> Bool"))
            XCTAssertTrue(chipSource.contains("ClipboardCollectionReorderModifier("))
            XCTAssertTrue(chipSource.contains("collection: collection"))
            XCTAssertTrue(chipSource.contains("onReorder: onReorder"))
            XCTAssertTrue(chipSource.contains(".accessibilityActions {"))
            XCTAssertTrue(chipSource.contains("if canMoveLeft"))
            XCTAssertTrue(chipSource.contains("if canMoveRight"))
            XCTAssertTrue(chipSource.contains("action.move_left"))
            XCTAssertTrue(chipSource.contains("action.move_right"))
        }

        XCTAssertTrue(shelfSource.contains("DragGesture("))
        XCTAssertTrue(shelfSource.contains("minimumDistance: 4"))
        XCTAssertTrue(shelfSource.contains("session.dropTarget(at: value.location.x)"))
        XCTAssertTrue(shelfSource.contains("withAnimation"))
        XCTAssertTrue(shelfSource.contains("relativeTo: target.collection"))
        XCTAssertTrue(shelfSource.contains("afterTarget: target.afterTarget"))
        XCTAssertTrue(shelfSource.contains("session.updateTranslation(value.translation.width)"))
        XCTAssertTrue(shelfSource.contains("if let move = session.pendingMove"))
        XCTAssertTrue(shelfSource.contains("session.cancel()"))
        XCTAssertTrue(shelfSource.contains("dropDestination(for: PinboardItemDragPayload.self"))
        XCTAssertTrue(shelfSource.contains("if let onDropPayloads"))
        XCTAssertFalse(shelfSource.contains("DropProposal(operation: .move)"))
        XCTAssertFalse(shelfSource.contains("dragConfiguration(.init(allowMove: true))"))
        XCTAssertFalse(shelfSource.contains("ClipboardCollectionDragPayload"))
        XCTAssertFalse(shelfSource.contains("struct ShelfCollectionChipDropTarget"))
        XCTAssertFalse(shelfSource.contains("registerForDraggedTypes"))
    }

    func testCollectionReorderHandlersDoNotSelectPanelScopes() throws {
        let shelfSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let sideSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardSidePanelView.swift")
        let shelfHandlerStart = try XCTUnwrap(shelfSource.range(of: "private func reorderCollection("))
        let shelfHandlerEnd = try XCTUnwrap(shelfSource.range(of: "private func dropItems("))
        let sideHandlerStart = try XCTUnwrap(sideSource.range(of: "private func reorderCollection("))
        let sideHandlerEnd = try XCTUnwrap(sideSource.range(of: "private func dropItems("))
        let shelfHandler = String(shelfSource[shelfHandlerStart.lowerBound..<shelfHandlerEnd.lowerBound])
        let sideHandler = String(sideSource[sideHandlerStart.lowerBound..<sideHandlerEnd.lowerBound])

        for handler in [shelfHandler, sideHandler] {
            XCTAssertTrue(handler.contains("store.moveCollection(source, relativeTo: target, afterTarget: afterTarget)"))
            XCTAssertFalse(handler.contains("selectedScope ="))
            XCTAssertFalse(handler.contains("setScope("))
            XCTAssertFalse(handler.contains("setSideScope("))
            XCTAssertFalse(handler.contains("selectSmartCategory("))
        }
        XCTAssertFalse(shelfHandler.contains("shelfScope ="))
        XCTAssertFalse(sideHandler.contains("sideScope ="))
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

    func testOnlyCustomPinboardsExposeAppearanceAndOrderEditing() throws {
        let shelfSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let sideSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardSidePanelView.swift")
        let promptSource = try sourceFileContents("Sources/PasteBuddy/Views/PinboardEditPrompt.swift")

        for source in [shelfSource, sideSource] {
            let helperStart = try XCTUnwrap(source.range(of: "@ViewBuilder\n    private func collectionChip"))
            let helperEnd = try XCTUnwrap(source.range(of: "private func createNamedPinboard"))
            let helperSource = String(source[helperStart.lowerBound..<helperEnd.lowerBound])
            let smartStart = try XCTUnwrap(helperSource.range(of: "case .smart(let category):"))
            let pinboardStart = try XCTUnwrap(helperSource.range(of: "case .pinboard(let id):"))
            let smartSource = String(helperSource[smartStart.lowerBound..<pinboardStart.lowerBound])
            let pinboardSource = String(helperSource[pinboardStart.lowerBound...])

            XCTAssertTrue(smartSource.contains("systemImageName: category.systemImageName"))
            XCTAssertFalse(smartSource.contains("onDropPayloads:"))
            XCTAssertFalse(smartSource.contains(".contextMenu"))
            XCTAssertTrue(pinboardSource.contains("systemImageName: pinboard.systemImageName ?? \"pin.fill\""))
            XCTAssertTrue(pinboardSource.contains("onDropPayloads: { dropItems($0, into: .pinboard(pinboard.id)) }"))
            XCTAssertTrue(pinboardSource.contains("CustomPinboardActionsMenu("))
            XCTAssertTrue(pinboardSource.contains("onMove: { moveCollection(collection, by: $0) }"))
            XCTAssertEqual(helperSource.components(separatedBy: ".contextMenu {").count - 1, 1)
        }
        XCTAssertTrue(promptSource.contains("Pinboard.customizableSystemImageNames"))
        XCTAssertTrue(promptSource.contains("label.edit_pinboard"))
        XCTAssertTrue(promptSource.contains("label.icon"))
        XCTAssertTrue(promptSource.contains("label.color"))
        XCTAssertTrue(promptSource.contains("store.collectionOrder.firstIndex(of: .pinboard(pinboard.id))"))
        XCTAssertTrue(promptSource.contains("store.collectionOrder.count - 1"))
        XCTAssertTrue(promptSource.contains("let onMove: (Int) -> Void"))
        XCTAssertTrue(promptSource.contains("onMove(-1)"))
        XCTAssertTrue(promptSource.contains("onMove(1)"))
        XCTAssertFalse(promptSource.contains("store.moveUserPinboards"))
        XCTAssertFalse(promptSource.contains("SmartPinboardCategory"))
    }

    func testShelfLiveTextUsesOriginalImageDataEvenWhenThumbnailIsCached() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let previewStart = try XCTUnwrap(source.range(of: "private struct ShelfExpandedImagePreview"))
        let liveTextStart = try XCTUnwrap(source.range(of: "private struct ShelfLiveTextImagePreview"))
        let previewSource = String(source[previewStart.lowerBound..<liveTextStart.lowerBound])

        XCTAssertTrue(previewSource.contains("fallbackImage = cachedImage"))
        XCTAssertTrue(previewSource.contains("let imageData = await imageDataProvider(item)"))
        XCTAssertTrue(previewSource.contains("NSImage(data: imageData)"))
        XCTAssertTrue(previewSource.contains("liveTextImage = analysisImage"))
        let originalFetch = try XCTUnwrap(previewSource.range(of: "let imageData = await imageDataProvider(item)"))
        let cachedFallback = try XCTUnwrap(previewSource.range(of: "if let cachedImage {\n                liveTextImage = cachedImage"))
        XCTAssertLessThan(originalFetch.upperBound, cachedFallback.lowerBound)
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

    func testIOSAppLoadsStoreAsynchronouslyFromFirstScreenTask() throws {
        let source = try sourceFileContents("Sources/PasteBuddyiOS/PasteBuddyiOSApp.swift")
        let initializerStart = try XCTUnwrap(source.range(of: "init()"))
        let bodyStart = try XCTUnwrap(source.range(of: "var body: some Scene"))
        let initializerSource = String(source[initializerStart.lowerBound..<bodyStart.lowerBound])
        let taskStart = try XCTUnwrap(source.range(of: ".task {"))
        let taskEnd = try XCTUnwrap(source.range(of: "await irohSync.start()"))
        let taskSource = String(source[taskStart.lowerBound..<taskEnd.upperBound])

        XCTAssertFalse(initializerSource.contains("resolvedStore.load()"))
        XCTAssertFalse(initializerSource.contains("loadAsync()"))
        XCTAssertTrue(taskSource.contains("await store.loadAsync()"))
        XCTAssertTrue(source.contains("@State private var isStoreLoaded = false"))
        XCTAssertTrue(source.contains("if isStoreLoaded"))
        XCTAssertTrue(source.contains("ProgressView()"))
        XCTAssertTrue(taskSource.contains("isStoreLoaded = true"))
    }

    func testMobileExtensionsLoadEncryptedHistoryOffTheMainThread() throws {
        let shareSource = try sourceFileContents("Sources/PasteBuddyShareAction/ShareActionViewController.swift")
        let keyboardSource = try sourceFileContents("Sources/PasteBuddyKeyboard/KeyboardViewController.swift")

        XCTAssertTrue(shareSource.contains("await resolvedStore.loadAsync()"))
        XCTAssertFalse(shareSource.contains("resolvedStore.load()"))
        XCTAssertTrue(keyboardSource.contains("await resolvedStore.loadAsync()"))
        XCTAssertFalse(keyboardSource.contains("resolvedStore.load()"))
        XCTAssertTrue(keyboardSource.contains("finishConfiguringKeyboard(with: resolvedStore)"))
    }

    func testShareActionCancelsInFlightImportWhenDoneOrRetried() throws {
        let source = try sourceFileContents("Sources/PasteBuddyShareAction/ShareActionViewController.swift")

        XCTAssertTrue(source.contains("private var importTask: Task<Void, Never>?"))
        XCTAssertTrue(source.contains("importTask?.cancel()"))
        XCTAssertTrue(source.contains("guard !Task.isCancelled else { return }"))
    }

    func testPinboardIconPickerProvidesPerIconAccessibilityDescriptions() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/PinboardEditPrompt.swift")

        XCTAssertFalse(source.contains("accessibilityDescription: nil"))
        XCTAssertTrue(source.contains("accessibilityDescription: accessibilityDescription"))
        XCTAssertTrue(source.contains("iconControl.setToolTip"))
    }

    func testIrohSyncReceiversRoutePeerItemsThroughPrivacyGate() throws {
        let macAppSource = try sourceFileContents("Sources/PasteBuddy/App/PasteBuddyApp.swift")
        let iosAppSource = try sourceFileContents("Sources/PasteBuddyiOS/PasteBuddyiOSApp.swift")
        let keyboardSource = try sourceFileContents("Sources/PasteBuddyKeyboard/KeyboardViewController.swift")

        XCTAssertTrue(macAppSource.contains("store.addSyncedItem(item)"))
        XCTAssertTrue(iosAppSource.contains("store.addSyncedItem(item)"))
        XCTAssertTrue(keyboardSource.contains("resolvedStore.addSyncedItem(item)"))
        XCTAssertTrue(iosAppSource.contains("irohSync?.reportReceivePersistenceFailure(error)"))
        XCTAssertTrue(keyboardSource.contains("syncService?.reportReceivePersistenceFailure(error)"))
        XCTAssertFalse(iosAppSource.contains("try? await store.flushPendingSaveOrThrow()"))
        XCTAssertFalse(keyboardSource.contains("try? await resolvedStore.flushPendingSaveOrThrow()"))
    }

    func testKeyboardMutationsFlushBeforeTheExtensionCanBeSuspended() throws {
        let source = try sourceFileContents("Sources/PasteBuddyMobile/MobileExtensionViews.swift")

        let pinStart = try XCTUnwrap(source.range(of: "store.pinItem(item.id, to: pinboard.id)"))
        let pinTail = String(source[pinStart.lowerBound...].prefix(400))
        XCTAssertTrue(pinTail.contains("try await store.flushPendingSaveOrThrow()"))

        let syncStart = try XCTUnwrap(source.range(of: "private func syncCurrentClipboard()"))
        let syncTail = String(source[syncStart.lowerBound...].prefix(1_500))
        XCTAssertTrue(syncTail.contains("try await store.flushPendingSaveOrThrow()"))
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
        let mcpStart = try XCTUnwrap(source.range(of: "Section(\"label.mcp_ai_tools\")"))
        let syncStart = try XCTUnwrap(source.range(of: "Section(\"action.sync_sharing\")"))
        let mcpSource = String(source[mcpStart.lowerBound..<syncStart.lowerBound])

        XCTAssertTrue(mcpSource.contains("action.enable_mcp"))
        XCTAssertTrue(mcpSource.contains("action.generate_server_config"))
        XCTAssertTrue(mcpSource.contains("action.connect_ai_tool"))
        XCTAssertTrue(mcpSource.contains("detectedMCPClientCandidates"))
        XCTAssertTrue(mcpSource.contains("supportedMCPClientCandidates"))
        XCTAssertTrue(source.contains("struct MCPClientDetector"))
        XCTAssertFalse(source.contains("MCPClientConfigurationTarget.settingsMenuTargets"))
        XCTAssertFalse(mcpSource.contains("action.shut_down_mcp_server"))
        XCTAssertTrue(mcpSource.contains("label.connected_ai_tools"))
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
        XCTAssertFalse(mcpSource.contains("127.0.0.1"))
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

    func testBuildAndRunPackagesAndSignsMCPExecutable() throws {
        let source = try sourceFileContents("script/build_and_run.sh")

        XCTAssertTrue(source.contains("MCP_EXECUTABLE_NAME=\"PasteBuddyMCP\""))
        XCTAssertTrue(source.contains("MCP_BUILD_BINARY=\"$BUILD_DIR/$MCP_EXECUTABLE_NAME\""))
        XCTAssertTrue(source.contains("MCP_APP_BINARY=\"$APP_MACOS/$MCP_EXECUTABLE_NAME\""))
        XCTAssertTrue(source.contains("\"$MCP_BUILD_BINARY\" \"$MCP_APP_BINARY\""))
        XCTAssertTrue(source.contains("codesign_binary \"$MCP_APP_BINARY\""))
        XCTAssertTrue(source.contains("codesign --verify --strict --verbose=4 \"$binary\""))
    }

    func testSettingsUsesTaskBasedNativeSidebar() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/SettingsView.swift")

        XCTAssertTrue(source.contains("NavigationSplitView"))
        XCTAssertTrue(source.contains("List(SettingsSidebarSection.allCases, selection: $selectedSettingsSection)"))
        XCTAssertTrue(source.contains(".listStyle(.sidebar)"))
        XCTAssertTrue(source.contains(".scrollContentBackground(.hidden)"))
        XCTAssertTrue(source.contains(".background(.regularMaterial)"))
        XCTAssertTrue(source.contains(".navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 230)"))
        XCTAssertTrue(source.contains(".toolbar(removing: .sidebarToggle)"))
        XCTAssertTrue(source.contains("case capture"))
        XCTAssertTrue(source.contains("case paste"))
        XCTAssertTrue(source.contains("\"label.paste_shortcuts\""))
        XCTAssertTrue(source.contains("case .privacy:"))
        XCTAssertTrue(source.contains("self = .capture"))
        XCTAssertTrue(source.contains("case .shortcuts:"))
        XCTAssertTrue(source.contains("self = .paste"))
        XCTAssertTrue(source.contains("case .sync:"))
        XCTAssertTrue(source.contains("self = .integrations"))
        XCTAssertTrue(source.contains("captureSettingsForm"))
        XCTAssertTrue(source.contains("pasteSettingsForm"))
        XCTAssertTrue(source.contains("Section(\"label.history\")"))
        XCTAssertFalse(source.contains("TabView {"))
        XCTAssertFalse(source.contains(".tabItem"))
    }

    func testCaptureRuleAppValuesUseInstalledApplicationPicker() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/SettingsView.swift")

        XCTAssertTrue(source.contains("InstalledApplicationPickerSheet"))
        XCTAssertTrue(source.contains("newCaptureRuleCondition.requiresInstalledApplication"))
        XCTAssertTrue(source.contains("newCaptureRuleCondition.rulePattern(for: application)"))
        XCTAssertTrue(source.contains("captureRulePatternForSubmit"))
        XCTAssertTrue(source.contains("showingExcludedApplicationsSheet"))
        XCTAssertTrue(source.contains("store.excludeApplication("))
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

    func testShortcutSettingsRecordKeyCombinationsInsteadOfManualToggles() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/SettingsView.swift")

        XCTAssertTrue(source.contains("ShortcutCaptureButton"))
        XCTAssertTrue(source.contains("ShortcutRecorderState"))
        XCTAssertTrue(source.contains("NSEvent.addLocalMonitorForEvents(matching: .keyDown)"))
        XCTAssertTrue(source.contains("NSEvent.removeMonitor(eventMonitor)"))
        XCTAssertTrue(source.contains("NotificationCenter.default.post(name: .pasteBuddyShortcutRecordingDidChange"))
        XCTAssertTrue(source.contains("store.setShortcutBinding("))
        XCTAssertTrue(source.contains("store.setQuickPasteModifiers(shortcut.modifiers"))
        XCTAssertFalse(source.contains("ShortcutModifierToggles"))
        XCTAssertFalse(source.contains("Toggle(modifier.displayName"))
        XCTAssertFalse(source.contains("TextField(\"label.key\""))
    }

    func testPanelHotKeyControllerPausesGlobalHotKeysWhileRecordingShortcuts() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/App/ClipboardShelfPanelController.swift")

        XCTAssertTrue(source.contains("forName: .pasteBuddyShortcutRecordingDidChange"))
        XCTAssertTrue(source.contains("registration?.setEnabled(!isRecording)"))
        XCTAssertTrue(source.contains("eventTap?.setEnabled(!isRecording)"))
        XCTAssertTrue(source.contains("ignoredDuringShortcutRecording"))
        XCTAssertTrue(source.contains("UnregisterEventHotKey(hotKeyRef)"))
        XCTAssertTrue(source.contains("CGEvent.tapEnable(tap: eventTap, enable: isEnabled)"))
    }

    func testPlansSettingsDoesNotExposeInternalPurchaseCopy() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/SettingsView.swift")
        let plansStart = try XCTUnwrap(source.range(of: "private var plansSettingsForm"))
        let pasteStart = try XCTUnwrap(source.range(of: "private var pasteSettingsForm"))
        let plansSource = String(source[plansStart.lowerBound..<pasteStart.lowerBound])

        XCTAssertTrue(plansSource.contains("action.restore_purchases"))
        XCTAssertTrue(plansSource.contains("action.view_plans"))
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
        XCTAssertTrue(plansSource.contains("restorePurchases()"))
        XCTAssertTrue(source.contains("AppleStoreKitEntitlementProvider()"))
        XCTAssertTrue(source.contains("store.restorePurchases("))
        XCTAssertTrue(source.contains("await store.flushPendingSave()"))
        XCTAssertTrue(source.contains("store.hasFullProductAccess"))
        XCTAssertTrue(source.contains("await onEntitlementActivated()"))
        XCTAssertTrue(plansSource.contains("restoreStatusMessage"))
        XCTAssertFalse(plansSource.contains("store.lastErrorMessage"))
        XCTAssertFalse(plansSource.contains("purchasePersonalPlan"))
        XCTAssertFalse(plansSource.contains("Button(\"label.monthly\")"))
        XCTAssertFalse(plansSource.contains("Button(\"label.annual\")"))
        XCTAssertFalse(plansSource.contains("Button(\"label.lifetime\")"))
        XCTAssertFalse(plansSource.contains("Button(\"label.family\")"))
        XCTAssertFalse(plansSource.contains("store.activatePersonalPlan("))
        XCTAssertFalse(plansSource.contains("store.startFreeTrial()"))
        XCTAssertFalse(plansSource.contains("markRestorePurchasesFailed"))
    }

    func testSettingsIrohConnectCannotBypassExpiredProductAccess() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/SettingsView.swift")
        let appSource = try sourceFileContents("Sources/PasteBuddy/App/PasteBuddyApp.swift")

        let connectStart = try XCTUnwrap(source.range(of: "private func connectToIrohPeer()"))
        let nextProperty = try XCTUnwrap(source.range(
            of: "\n    private var retentionDescription",
            range: connectStart.lowerBound..<source.endIndex
        ))
        let connectSource = String(source[connectStart.lowerBound..<nextProperty.lowerBound])

        XCTAssertTrue(source.contains("connectToIrohPeer()"))
        XCTAssertTrue(connectSource.contains("Task { @MainActor in"))
        XCTAssertTrue(connectSource.contains("guard store.hasFullProductAccess else"))
        XCTAssertTrue(source.contains("message.trial_ended_purchase_required"))
        XCTAssertTrue(source.contains("irohAccessStatusMessage"))
        XCTAssertTrue(connectSource.contains("await irohSync.connectToPeer()"))
        XCTAssertTrue(appSource.contains("onEntitlementActivated: handleEntitlementActivated"))
    }

    func testRuntimeStartsOneSevenDayTrialAndGatesProtectedActionsWithPaywall() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/App/PasteBuddyApp.swift")

        XCTAssertTrue(source.contains("store.refreshCurrentStoreEntitlement("))
        XCTAssertTrue(source.contains("store.startFreeTrialIfEligible(days: 7)"))
        XCTAssertTrue(source.contains("guard store.hasFullProductAccess else"))
        XCTAssertTrue(source.contains("openWindow(id: \"paywall\")"))
        XCTAssertTrue(source.contains("scheduleEntitlementExpirationIfNeeded()"))
        XCTAssertTrue(source.contains("startStoreTransactionObserverIfNeeded()"))
        XCTAssertTrue(source.contains("monitor?.stop()"))
        XCTAssertTrue(source.contains("irohSync.stop()"))
        XCTAssertFalse(source.contains("applyStoreEntitlementUpdate"))
        XCTAssertFalse(source.contains("requestSettingsDestination(.plans)"))

        let activationStart = try XCTUnwrap(source.range(of: "private func handleEntitlementActivated()"))
        let observerStart = try XCTUnwrap(source.range(
            of: "\n    private func startStoreTransactionObserverIfNeeded()",
            range: activationStart.lowerBound..<source.endIndex
        ))
        let activationSource = String(source[activationStart.lowerBound..<observerStart.lowerBound])
        XCTAssertTrue(activationSource.contains("didRefreshCurrentStoreEntitlement = true"))
        XCTAssertTrue(activationSource.contains("storeEntitlementRefreshFailed = false"))
    }

    func testRuntimeKeepsStatusEntryVisibleWhenStoreKitRefreshFails() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/App/PasteBuddyApp.swift")
        let runtimeStart = try XCTUnwrap(source.range(of: "private func startRuntimeIfNeeded"))
        let runtimeEnd = try XCTUnwrap(source.range(
            of: "\n    private func requireFullProductAccessForUserAction",
            range: runtimeStart.lowerBound..<source.endIndex
        ))
        let runtimeSource = String(source[runtimeStart.lowerBound..<runtimeEnd.lowerBound])
        let statusConfiguration = try XCTUnwrap(runtimeSource.range(of: "configureStatusItemIfNeeded()"))
        let storeKitRefresh = try XCTUnwrap(runtimeSource.range(of: "store.refreshCurrentStoreEntitlement("))

        XCTAssertLessThan(statusConfiguration.lowerBound, storeKitRefresh.lowerBound)
        XCTAssertTrue(runtimeSource.contains("guard store.snapshot.entitlement.isTrialActive() else"))
        XCTAssertTrue(runtimeSource.contains("canStartFreeTrial = false"))
        XCTAssertTrue(runtimeSource.contains("storeEntitlementRefreshFailed = true"))
    }

    func testTransactionUpdateReconcilesAccountBeforeRuntimeTransition() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/App/PasteBuddyApp.swift")
        let observerStart = try XCTUnwrap(source.range(of: "private func startStoreTransactionObserverIfNeeded"))
        let observerEnd = try XCTUnwrap(source.range(
            of: "\n    private func scheduleEntitlementExpirationIfNeeded",
            range: observerStart.lowerBound..<source.endIndex
        ))
        let observerSource = String(source[observerStart.lowerBound..<observerEnd.lowerBound])
        let refresh = try XCTUnwrap(observerSource.range(of: "store.refreshCurrentStoreEntitlement("))
        let immediateStop = try XCTUnwrap(observerSource.range(of: "if !store.hasFullProductAccess"))
        let flush = try XCTUnwrap(observerSource.range(of: "store.flushPendingSave()"))

        XCTAssertLessThan(refresh.lowerBound, immediateStop.lowerBound)
        XCTAssertLessThan(immediateStop.lowerBound, flush.lowerBound)
        XCTAssertTrue(observerSource.contains("shouldStopAfterFailedReconciliation("))
        XCTAssertTrue(observerSource.contains("observer.run("))
        XCTAssertTrue(observerSource.contains("defer { transactionObserverTask = nil }"))
        XCTAssertFalse(observerSource.contains("applyStoreEntitlementUpdate("))
    }

    func testEntitlementRuntimePolicySchedulesTrialAndPaidDeadlines() {
        let now = Date(timeIntervalSince1970: 10_000)
        let trialEnd = now.addingTimeInterval(60)
        let periodEnd = now.addingTimeInterval(120)
        let expiration = now.addingTimeInterval(180)

        XCTAssertEqual(
            PasteBuddyEntitlementRuntimePolicy.accessDeadline(for: EntitlementConfiguration(
                plan: .trial,
                status: .trialing,
                trialEndsAt: trialEnd
            )),
            trialEnd
        )
        XCTAssertEqual(
            PasteBuddyEntitlementRuntimePolicy.accessDeadline(for: EntitlementConfiguration(
                plan: .annual,
                status: .active,
                currentPeriodEndsAt: periodEnd
            )),
            periodEnd
        )
        XCTAssertEqual(
            PasteBuddyEntitlementRuntimePolicy.accessDeadline(for: EntitlementConfiguration(
                plan: .annual,
                status: .active,
                currentPeriodEndsAt: periodEnd,
                expiresAt: expiration
            )),
            periodEnd
        )
        XCTAssertNil(PasteBuddyEntitlementRuntimePolicy.accessDeadline(for: EntitlementConfiguration(
            plan: .lifetime,
            status: .active
        )))
    }

    func testEntitlementRuntimePolicyFailsClosedBeforePersistence() {
        let now = Date(timeIntervalSince1970: 20_000)
        let active = EntitlementConfiguration(
            plan: .monthly,
            status: .active,
            purchasedAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(60)
        )
        let revoked = StoreEntitlementUpdate(
            transaction: VerifiedStoreTransaction(
                productID: "monthly.id",
                purchaseDate: now.addingTimeInterval(-60),
                revocationDate: now
            ),
            entitlement: EntitlementConfiguration(
                plan: .monthly,
                status: .revoked,
                expiresAt: now
            ),
            receivedAt: now
        )
        var olderRevocation = revoked
        olderRevocation.transaction.purchaseDate = now.addingTimeInterval(-120)
        var differentPlanRevocation = revoked
        differentPlanRevocation.entitlement.plan = .annual

        XCTAssertTrue(PasteBuddyEntitlementRuntimePolicy.shouldStopAfterFailedReconciliation(
            revoked,
            cachedEntitlement: active
        ))
        XCTAssertFalse(PasteBuddyEntitlementRuntimePolicy.shouldStopAfterFailedReconciliation(
            olderRevocation,
            cachedEntitlement: active
        ))
        XCTAssertFalse(PasteBuddyEntitlementRuntimePolicy.shouldStopAfterFailedReconciliation(
            differentPlanRevocation,
            cachedEntitlement: active
        ))
        XCTAssertFalse(PasteBuddyEntitlementRuntimePolicy.canStartAfterPersistence(
            active,
            didPersist: false,
            now: now
        ))
        XCTAssertTrue(PasteBuddyEntitlementRuntimePolicy.canStartAfterPersistence(
            active,
            didPersist: true,
            now: now
        ))
    }

    func testTransactionObserverRetryPolicyIsBounded() {
        XCTAssertEqual(PasteBuddyStoreTransactionRetryPolicy.delaySeconds(afterFailure: 1), 1)
        XCTAssertEqual(PasteBuddyStoreTransactionRetryPolicy.delaySeconds(afterFailure: 2), 2)
        XCTAssertEqual(PasteBuddyStoreTransactionRetryPolicy.delaySeconds(afterFailure: 5), 16)
        XCTAssertEqual(PasteBuddyStoreTransactionRetryPolicy.delaySeconds(afterFailure: 6), 30)
        XCTAssertEqual(PasteBuddyStoreTransactionRetryPolicy.delaySeconds(afterFailure: 100), 30)
    }

    func testNativePaywallUsesDynamicStoreKitProductsAndFlushesPurchases() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/PasteBuddyPaywallView.swift")

        XCTAssertTrue(source.contains("AppleStoreKitEntitlementProvider()"))
        XCTAssertTrue(source.contains("provider.fetchProducts("))
        XCTAssertTrue(source.contains("ForEach(storeProducts)"))
        XCTAssertTrue(source.contains("product.displayPrice"))
        XCTAssertTrue(source.contains("product.subscriptionPeriod"))
        XCTAssertTrue(source.contains("LazyVGrid("))
        XCTAssertTrue(source.contains("store.purchasePersonalPlan("))
        XCTAssertTrue(source.contains("await store.flushPendingSave()"))
        XCTAssertTrue(source.contains("store.restorePurchases("))
        XCTAssertTrue(source.contains("message.store_products_unavailable.detail"))
        XCTAssertFalse(source.contains("$29.99"))
        XCTAssertFalse(source.contains("$2.99"))
        XCTAssertFalse(source.contains("store.activatePersonalPlan("))
    }

    func testIndependentEntrypointsReconcileCachedActivePaidAccessWithoutBlockingLocalTrial() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/App/PasteBuddyAppIntents.swift")
        let mcpSource = try sourceFileContents("Sources/PasteBuddyMCP/main.swift")

        XCTAssertTrue(source.contains("private func loadEntitledStore()"))
        XCTAssertTrue(source.contains("guard store.hasFullProductAccess else"))
        XCTAssertTrue(source.contains("error.product_access_required"))
        XCTAssertEqual(source.components(separatedBy: "try await loadEntitledStore()").count - 1, 5)
        for entrypointSource in [source, mcpSource] {
            XCTAssertTrue(entrypointSource.contains("plan.isPersonalPaidPlan"))
            XCTAssertTrue(entrypointSource.contains("hasActivePaidAccess()"))
            XCTAssertTrue(entrypointSource.contains("refreshCurrentStoreEntitlement("))
            XCTAssertTrue(entrypointSource.contains("flushPendingSaveOrThrow()"))
        }
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

    func testCardSwitchLatencyTrackerMeasuresRecognitionApplyAndTotalTime() throws {
        let tracker = PasteBuddyCardSwitchLatencyTracker()
        let itemID = UUID()

        let probeID = tracker.recordPointerDown(atUptimeNanoseconds: 1_000_000)
        XCTAssertEqual(
            tracker.recordSelectionRecognized(
                itemID: itemID,
                atUptimeNanoseconds: 4_000_000
            ),
            probeID
        )
        let measurement = try XCTUnwrap(
            tracker.recordSelectionApplied(
                itemID: itemID,
                atUptimeNanoseconds: 10_000_000
            )
        )

        XCTAssertEqual(measurement.probeID, probeID)
        XCTAssertEqual(measurement.recognitionMilliseconds, 3, accuracy: 0.001)
        XCTAssertEqual(measurement.applyMilliseconds, 6, accuracy: 0.001)
        XCTAssertEqual(measurement.totalMilliseconds, 9, accuracy: 0.001)
        XCTAssertNil(
            tracker.recordSelectionApplied(
                itemID: itemID,
                atUptimeNanoseconds: 11_000_000
            )
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
        XCTAssertTrue(source.contains("interaction.togglePreview"))
        XCTAssertTrue(source.contains("ShelfExpandedPreview"))
        XCTAssertTrue(source.contains("ClipboardImageThumbnailView"))
        XCTAssertTrue(source.contains(".focusEffectDisabled()"))
        XCTAssertTrue(source.contains("ClipboardShelfDirectPasteCoordinator.runAfterImmediateDismissal"))
        XCTAssertTrue(source.contains("@Environment(\\.openSettings)"))
        XCTAssertTrue(source.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertTrue(source.contains("animation: reduceMotion ? nil : .snappy(duration: 0.18)"))
        XCTAssertTrue(source.contains("withAnimation(reduceMotion ? nil : .snappy(duration: 0.18))"))
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
        XCTAssertTrue(source.contains("let collectionOrder = collectionDragSession.displayOrder(fallback: store.collectionOrder)"))
        XCTAssertTrue(source.contains("ForEach(collectionOrder) { collection in"))
        XCTAssertFalse(source.contains("ForEach(SmartPinboardCategory.allCases)"))
        XCTAssertFalse(source.contains("ForEach(store.userPinboards)"))
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
        XCTAssertTrue(controllerSource.contains("isPinned: sidePanelPinnedBinding()"))
        XCTAssertTrue(controllerSource.contains("private func sidePanelPinnedBinding() -> Binding<Bool>"))
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

    func testShelfAndSidePanelCanLoadAdditionalFilteredPages() throws {
        let shelfSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let sideSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardSidePanelView.swift")
        let storeSource = try sourceFileContents("Sources/PasteBuddyCore/Stores/PasteBuddyStore.swift")

        XCTAssertTrue(shelfSource.contains("private static let pageSize = 100"))
        XCTAssertTrue(shelfSource.contains("@State private var shelfItemTotalCount = 0"))
        XCTAssertTrue(shelfSource.contains("await store.filteredItemsPageAndCount("))
        XCTAssertTrue(shelfSource.contains("offset: requestedOffset"))
        XCTAssertTrue(shelfSource.contains("shelfItems.count < shelfItemTotalCount"))
        XCTAssertTrue(shelfSource.contains("Button(action: loadNextShelfPage)"))

        XCTAssertTrue(sideSource.contains("private static let pageSize = 100"))
        XCTAssertTrue(sideSource.contains("await store.filteredItemsPageAndCount("))
        XCTAssertTrue(sideSource.contains("offset: requestedOffset"))
        XCTAssertTrue(sideSource.contains("sideItems.count < sideItemTotalCount"))
        XCTAssertTrue(sideSource.contains("Button(action: loadNextSidePage)"))
        XCTAssertFalse(shelfSource.contains("store.filteredItemsPage(for:"))
        XCTAssertFalse(sideSource.contains("store.filteredItemsPage(for:"))
        XCTAssertFalse(sideSource.contains("store.filteredItemCount(for:"))
        XCTAssertFalse(shelfSource.contains("let items = store.filteredItems(for: shelfScope)"))
        XCTAssertFalse(sideSource.contains("let items = store.filteredItems(for: sideScope)"))
        XCTAssertFalse(shelfSource.contains("store.fullFilteredItems(for: shelfScope)"))
        XCTAssertFalse(sideSource.contains("store.fullFilteredItems(for: sideScope)"))
        XCTAssertFalse(sideSource.contains("sideItemTotalCount = items.count"))
        for source in [shelfSource, sideSource] {
            XCTAssertFalse(source.contains("renderLimit"))
            XCTAssertFalse(source.contains("overflowCount"))
            XCTAssertFalse(source.contains("format.refine_search_or_filters_to_see_more"))
        }
        XCTAssertFalse(shelfSource.contains("ShelfOverflowStatusCard"))
        XCTAssertTrue(storeSource.contains("let queryTask = Task.detached(priority: .userInitiated)"))
        XCTAssertTrue(storeSource.contains("await withTaskCancellationHandler"))
        XCTAssertTrue(storeSource.contains("queryTask.cancel()"))
        XCTAssertTrue(storeSource.contains("Task.isCancelled"))
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

    func testShelfAndSidePanelOwnNonPreviewKeyboardShortcuts() throws {
        let collectionSource = try sourceFileContents("Sources/PasteBuddy/Views/SwiftUIShelfCollection.swift")
        let shelfSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let sideSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardSidePanelView.swift")

        XCTAssertTrue(collectionSource.contains("TapGesture(count: 2)"))
        XCTAssertTrue(collectionSource.contains(".simultaneousGesture("))
        XCTAssertFalse(collectionSource.contains(".exclusively(before: TapGesture())"))
        XCTAssertFalse(collectionSource.contains(".onTapGesture {"))
        for source in [shelfSource, sideSource] {
            XCTAssertTrue(source.contains(".background(shelfKeyboardShortcuts)") || source.contains(".background(sidePanelKeyboardShortcuts)"))
            XCTAssertTrue(source.contains("keyboardShortcut(.leftArrow) { moveSelection(.left) }"))
            XCTAssertTrue(source.contains("keyboardShortcut(.rightArrow) { moveSelection(.right) }"))
            XCTAssertTrue(source.contains("keyboardShortcut(.upArrow) { moveSelection(.up) }"))
            XCTAssertTrue(source.contains("keyboardShortcut(.downArrow) { moveSelection(.down) }"))
            XCTAssertTrue(source.contains(".keyboardShortcut(key, modifiers: [])"))
        }
        XCTAssertTrue(shelfSource.contains(".disabled(isSearchFocused || shelfInteraction.previewedID != nil)"))
        XCTAssertTrue(sideSource.contains(".disabled(isSearchFocused || interaction.previewedID != nil)"))
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
