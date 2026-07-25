import AppKit
import Carbon
import PasteBuddyCore
import XCTest
@testable import PasteBuddy

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
        XCTAssertTrue(shelfSource.contains("plainText: PasteboardWriter.plainText(for: item)"))
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
        XCTAssertTrue(sideSource.contains("plainText: PasteboardWriter.plainText(for: item)"))
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
        XCTAssertTrue(dragSource.contains("let plainText: String"))
        XCTAssertTrue(dragSource.contains("CodableRepresentation(contentType: .pasteBuddyPinboardItemIDs)"))
        XCTAssertTrue(dragSource.contains("ProxyRepresentation(exporting: \\.plainText)"))
        XCTAssertFalse(dragSource.contains("NSItemProvider"))
        XCTAssertFalse(dragSource.contains("ClipboardItemDragProvider"))
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
        XCTAssertTrue(controllerSource.contains("ClipboardPanelArrowKeyCommand.resolve("))
        XCTAssertTrue(controllerSource.contains("NotificationCenter.default.post(name: .pasteBuddyPanelArrowKey"))

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
        XCTAssertTrue(mcpSource.contains("action.shut_down_mcp_server"))
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

        XCTAssertTrue(source.contains("NavigationSplitView"))
        XCTAssertTrue(source.contains("List(SettingsSidebarSection.allCases, selection: $selectedSettingsSection)"))
        XCTAssertTrue(source.contains(".listStyle(.sidebar)"))
        XCTAssertTrue(source.contains(".scrollContentBackground(.hidden)"))
        XCTAssertTrue(source.contains(".background(.regularMaterial)"))
        XCTAssertTrue(source.contains(".toolbar(removing: .sidebarToggle)"))
        XCTAssertTrue(source.contains("case .sync:"))
        XCTAssertTrue(source.contains("self = .integrations"))
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
        let shortcutsStart = try XCTUnwrap(source.range(of: "private var shortcutsSettingsForm"))
        let plansSource = String(source[plansStart.lowerBound..<shortcutsStart.lowerBound])

        XCTAssertTrue(plansSource.contains("action.restore_purchases"))
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
        let draggable = try XCTUnwrap(itemSource.range(of: "itemView.draggable(payload)"))
        let doubleTap = try XCTUnwrap(itemSource.range(of: ".onTapGesture(count: 2)"))
        let doubleClick = try XCTUnwrap(itemSource.range(of: "onDoubleClick(itemID)"))
        let simultaneousTap = try XCTUnwrap(itemSource.range(of: ".simultaneousGesture("))
        let suppressScroll = try XCTUnwrap(itemSource.range(of: "lastScrolledPrimarySelectedID = itemID"))
        let select = try XCTUnwrap(itemSource.range(of: "onSelect(itemID)"))
        let popover = try XCTUnwrap(itemSource.range(of: ".popover("))

        XCTAssertLessThan(draggable.lowerBound, doubleTap.lowerBound)
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

    private func makeShelfItem(title: String) -> ClipboardItem {
        ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .text,
            title: title,
            payload: ClipboardPayload(text: title)
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
