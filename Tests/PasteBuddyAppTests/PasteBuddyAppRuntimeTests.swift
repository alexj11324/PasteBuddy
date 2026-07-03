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

        XCTAssertTrue(source.contains("import Carbon"))
        XCTAssertTrue(source.contains("private struct ShelfPreviewKeyboardHandler"))
        XCTAssertTrue(source.contains("window?.makeFirstResponder(self)"))
        XCTAssertTrue(source.contains("case kVK_DownArrow:"))
        XCTAssertTrue(previewSource.contains(".onMoveCommand(perform: onMove)"))
        XCTAssertTrue(previewSource.contains("case .upArrow:"))
        XCTAssertTrue(previewSource.contains("case .downArrow:"))
        XCTAssertTrue(previewSource.contains("clipboard-expanded-preview-"))
        XCTAssertTrue(previewSource.contains("previewText(ClipboardPlainTextRenderer.plainText(for: item))"))
        XCTAssertFalse(previewSource.contains("Label(localized(item.presentationContentType.displayName)"))
        XCTAssertFalse(previewSource.contains("SourceApplicationIconBadge(item: item, size: 24)"))
        XCTAssertFalse(previewSource.contains("Text(footnote)"))
        XCTAssertFalse(previewSource.contains("item.openableURL"))
        XCTAssertFalse(previewSource.contains("TextEditor(text:"))
        XCTAssertFalse(previewSource.contains("onSaveText"))
        XCTAssertFalse(previewSource.contains("Button(\"action.save_text\")"))
    }

    func testPreviewPresentationUsesNativeCollectionPopoverForShelfAndSidePanel() throws {
        let shelfSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let sideSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardSidePanelView.swift")
        let collectionSource = try sourceFileContents("Sources/PasteBuddy/Views/ShelfCollectionRepresentable.swift")

        let shelfCardStart = try XCTUnwrap(shelfSource.range(of: "private struct ClipboardShelfCard: View"))
        let shelfPreviewStart = try XCTUnwrap(shelfSource.range(of: "struct ShelfExpandedPreview"))
        let shelfCardSource = String(shelfSource[shelfCardStart.lowerBound..<shelfPreviewStart.lowerBound])

        let sideRowStart = try XCTUnwrap(sideSource.range(of: "private struct ClipboardSidePanelListRow: View"))
        let sidePreviewStart = try XCTUnwrap(sideSource.range(of: "private struct ClipboardSidePanelContentPreview"))
        let sideRowSource = String(sideSource[sideRowStart.lowerBound..<sidePreviewStart.lowerBound])

        XCTAssertTrue(shelfSource.contains("previewedID: shelfInteraction.previewedID"))
        XCTAssertTrue(shelfSource.contains("previewPreferredEdge: .maxY"))
        XCTAssertTrue(shelfSource.contains("previewContent: { displayItem in"))
        XCTAssertFalse(shelfSource.contains(".popover(isPresented: isShelfPreviewPresented"))
        XCTAssertFalse(shelfSource.contains("private var previewedShelfItem"))
        XCTAssertFalse(shelfCardSource.contains(".popover("))
        XCTAssertFalse(shelfCardSource.contains("@Binding var isPreviewPresented"))

        XCTAssertTrue(sideSource.contains("previewedID: interaction.previewedID"))
        XCTAssertTrue(sideSource.contains("previewPreferredEdge: .minX"))
        XCTAssertTrue(sideSource.contains("previewAvoidsContainingWindowOverlap: true"))
        XCTAssertTrue(sideSource.contains("maxWidth: ClipboardSidePanelMetrics.previewMaxWidth"))
        XCTAssertTrue(sideSource.contains("previewContent: { item in"))
        XCTAssertFalse(sideSource.contains("private var previewedSideItem: ClipboardItem?"))
        XCTAssertFalse(sideSource.contains("private func sidePreview(_ item: ClipboardItem) -> some View"))
        XCTAssertFalse(sideSource.contains("if let item = previewedSideItem"))
        XCTAssertTrue(collectionSource.contains("private let popover = NSPopover()"))
        XCTAssertTrue(collectionSource.contains("static func dismantleNSView"))
        XCTAssertTrue(collectionSource.contains("coordinator.closePreviewPopover()"))
        XCTAssertTrue(collectionSource.contains("popover.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: anchor.preferredEdge)"))
        XCTAssertTrue(collectionSource.contains("var previewAvoidsContainingWindowOverlap: Bool"))
        XCTAssertTrue(collectionSource.contains("windowEdgePreviewAnchor(for: id, desiredContentSize: desiredContentSize, in: clipView)"))
        XCTAssertTrue(collectionSource.contains("PopoverPlacementPolicy.decision("))
        XCTAssertTrue(collectionSource.contains("containingWindowFrame: window.frame"))
        XCTAssertTrue(collectionSource.contains("let window = clipView.window"))
        XCTAssertTrue(collectionSource.contains("NSRect(x: clipView.bounds.minX"))
        XCTAssertTrue(collectionSource.contains("layoutAttributesForItem(at: indexPath)?.frame"))
        XCTAssertTrue(collectionSource.contains("collectionView.convert(anchorFrame, to: clipView)"))
        XCTAssertFalse(collectionSource.contains("ShelfExternalPreviewPanel"))
        XCTAssertFalse(collectionSource.contains("ShelfExternalPreviewArrow"))
        XCTAssertFalse(collectionSource.contains("NSPanel"))
        XCTAssertFalse(sideSource.contains(".popover(isPresented: previewPresentationBinding"))
        XCTAssertFalse(sideSource.contains("private func previewPresentationBinding"))
        XCTAssertFalse(sideSource.contains(".popover(isPresented: isPreviewPresented, arrowEdge: .trailing)"))
        XCTAssertFalse(sideSource.contains("private var previewedItem: ClipboardItem?"))
        XCTAssertFalse(sideRowSource.contains(".popover("))
        XCTAssertFalse(sideRowSource.contains("@Binding var isPreviewPresented"))
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
            XCTAssertTrue(source.contains("ClipboardPanelSearchInput.accepts(modifiers)"))
            XCTAssertTrue(source.contains("beginSearch(with: keyPress.characters)"))
            XCTAssertTrue(source.contains("ClipboardPanelSearchInput.accepts(characters)"))
            XCTAssertTrue(source.contains("store.searchQuery += characters"))
            XCTAssertTrue(source.contains("setSearchFocused(true)"))
            XCTAssertTrue(source.contains("onTextInput: beginSearch"))
            XCTAssertFalse(source.contains("previewFirstRenderedItem"))
            XCTAssertFalse(source.contains("previewsFirstItemWhenIdle"))
        }

        XCTAssertTrue(shelfSource.contains("refreshShelfItems()"))
        XCTAssertTrue(sideSource.contains("refreshSideItems()"))
        XCTAssertTrue(shelfSource.contains("struct SourceAppSuggestionPanelPresenter"))
        XCTAssertFalse(shelfSource.contains("private struct SourceAppSuggestionPanelPresenter"))
        XCTAssertTrue(shelfSource.contains("SourceAppSuggestionPanelPresenter("))
        XCTAssertTrue(sideSource.contains("SourceAppSuggestionPanelPresenter("))
        XCTAssertTrue(sideSource.contains("sourceAppSuggestions(matching: store.searchQuery, limit: 3)"))
        XCTAssertTrue(sideSource.contains("store.applySourceAppSuggestion(appName)"))
        XCTAssertTrue(shelfSource.contains("enum ClipboardPanelSearchInput"))
        XCTAssertTrue(shelfSource.contains("modifiers.subtracting([.shift, .capsLock]).isEmpty"))
        XCTAssertTrue(shelfSource.contains("characters.rangeOfCharacter(from: .controlCharacters) == nil"))
        XCTAssertTrue(shelfSource.contains("let onTextInput: (String) -> Bool"))
        XCTAssertTrue(shelfSource.contains("ShelfPreviewKeyboardHandler(onDismiss: onDismiss, onMove: onMove, onTextInput: onTextInput)"))
        XCTAssertTrue(shelfSource.contains("ClipboardPanelSearchInput.accepts(event.modifierFlags)"))
        XCTAssertTrue(shelfSource.contains("return onTextInput(characters)"))
        XCTAssertTrue(shelfSource.contains("NSEvent.addLocalMonitorForEvents(matching: .keyDown)"))
        XCTAssertTrue(shelfSource.contains("event.window === self.window"))
        XCTAssertTrue(shelfSource.contains("NSEvent.removeMonitor(keyMonitor)"))
        XCTAssertTrue(shelfSource.contains("nsView.startMonitoring()"))
        XCTAssertTrue(shelfSource.contains("nsView.focusSelf()"))
        XCTAssertTrue(controllerSource.contains("reloadPanelContent(panel)"))
        XCTAssertTrue(controllerSource.contains("hostingView.rootView = panelContentView()"))
        XCTAssertTrue(controllerSource.contains("panelPresentationID = UUID()"))
        XCTAssertTrue(controllerSource.contains(".id(panelPresentationID)"))
        XCTAssertTrue(controllerSource.contains("resetPanelPresentationState()"))
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

    func testShelfLinkCardsDoNotFetchRemoteMetadataByDefault() throws {
        let shelfSource = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")

        XCTAssertTrue(shelfSource.contains("ShelfLinkPreviewCardBody(preview: preview, tint: cardTint)"))
        XCTAssertTrue(shelfSource.contains("Image(systemName: \"link.circle.fill\")"))
        XCTAssertFalse(shelfSource.contains("LinkPreviewCache.preview(for:"))
        XCTAssertFalse(shelfSource.contains("LinkPreviewCache.cachedPreview(for:"))
        XCTAssertFalse(sourceFileExists("Sources/PasteBuddy/Models/LinkPreviewCache.swift"))
        XCTAssertFalse(shelfSource.contains("LPMetadataProvider"))
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

    func testShelfCollectionChipDoesNotRenderRectangularShadowOutsideCapsule() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let chipStart = try XCTUnwrap(source.range(of: "private struct ShelfCollectionChip"))
        let selectedCountStart = try XCTUnwrap(source.range(of: "private struct ShelfSelectedCountChip"))
        let chipSource = String(source[chipStart.lowerBound..<selectedCountStart.lowerBound])

        XCTAssertTrue(chipSource.contains(".clipShape(Capsule())"))
        XCTAssertFalse(chipSource.contains(".shadow("))
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

    func testMCPSettingsShowAgentConnectionWithoutToolDetails() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/SettingsView.swift")
        let mcpStart = try XCTUnwrap(source.range(of: "Section(\"label.agent_connection\")"))
        let syncStart = try XCTUnwrap(source.range(of: "Section(\"action.sync_sharing\")"))
        let mcpSource = String(source[mcpStart.lowerBound..<syncStart.lowerBound])

        XCTAssertTrue(mcpSource.contains("action.allow_local_agent_connection"))
        XCTAssertTrue(mcpSource.contains("label.agent_connection_status"))
        XCTAssertTrue(mcpSource.contains("message.agent_connection_runs_on_this_mac"))
        XCTAssertTrue(mcpSource.contains("message.swift_run_pastebuddymcp_print_client_config_codex"))
        XCTAssertFalse(mcpSource.contains("ForEach(MCPToolName.allCases)"))
        XCTAssertFalse(mcpSource.contains("setMCPTool"))
        XCTAssertFalse(mcpSource.contains("label.last_mcp_access"))
        XCTAssertFalse(mcpSource.contains("action.revoke_mcp_access"))
        XCTAssertFalse(mcpSource.contains("message.tool_selections_are_saved_and_take_effect"))
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
        XCTAssertTrue(source.contains("ShelfCollectionRepresentable"))
        XCTAssertTrue(source.contains("scrollDirection: .vertical"))
        XCTAssertTrue(source.contains("clipboard-side-panel-row-"))
        XCTAssertTrue(source.contains("interaction.togglePreview"))
        XCTAssertTrue(source.contains("ShelfExpandedPreview"))
        XCTAssertTrue(source.contains("ClipboardImageThumbnailView"))
        XCTAssertTrue(source.contains(".focusEffectDisabled()"))
        XCTAssertTrue(source.contains("ClipboardShelfDirectPasteCoordinator.runAfterImmediateDismissal"))
        XCTAssertTrue(source.contains("dismissBeforePaste: !isPinned"))
        XCTAssertTrue(source.contains("@Environment(\\.openSettings)"))
        XCTAssertTrue(source.contains("store.clearRequestedSettingsDestination()"))
        XCTAssertTrue(source.contains("onDismissImmediately()"))
        XCTAssertTrue(source.contains("openSettings()"))
        XCTAssertTrue(source.contains("NSApp.activate(ignoringOtherApps: true)"))
        XCTAssertTrue(source.contains("ShelfToolbarCircleIcon(systemName: \"gearshape\")"))
        XCTAssertFalse(source.contains("store.toggleCapturePaused()"))
        XCTAssertFalse(source.contains("store.undoLastDeletion()"))
        XCTAssertTrue(source.contains("label.all"))
        XCTAssertTrue(source.contains("label.today"))
        XCTAssertFalse(source.contains("label.filters"))
        XCTAssertFalse(source.contains("action.reload_clipboard_history"))
        XCTAssertTrue(source.contains("@Binding var isPinned: Bool"))
        XCTAssertTrue(source.contains("@State private var isPinnedVisual = false"))
        XCTAssertTrue(source.contains("isPinnedVisual = isPinned"))
        XCTAssertTrue(source.contains("isPinnedVisual.toggle()"))
        XCTAssertTrue(source.contains("isPinned = isPinnedVisual"))
        XCTAssertTrue(source.contains("ShelfToolbarCircleIcon(systemName: isPinnedVisual ? \"pin.fill\" : \"pin\")"))
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
        XCTAssertTrue(shelfSource.contains("struct ClipboardImageThumbnailView"))
        XCTAssertTrue(shelfSource.contains("extension View"))
    }

    func testShelfCollectionSuppressesRectangularFocusRing() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/ShelfCollectionRepresentable.swift")

        XCTAssertTrue(source.contains("collectionView.focusRingType = .none"))
        XCTAssertTrue(source.contains("scrollView.focusRingType = .none"))
        XCTAssertTrue(source.contains("var scrollDirection: NSCollectionView.ScrollDirection"))
    }

    func testShelfCollectionScrollViewSuppressesVisibleScrollers() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/ShelfCollectionRepresentable.swift")

        XCTAssertTrue(source.contains("scrollView.hasHorizontalScroller = false"))
        XCTAssertTrue(source.contains("scrollView.horizontalScroller = nil"))
        XCTAssertTrue(source.contains("override var horizontalScroller: NSScroller?"))
        XCTAssertTrue(source.contains("set { super.horizontalScroller = nil }"))
        XCTAssertTrue(source.contains("override var hasHorizontalScroller: Bool"))
        XCTAssertTrue(source.contains("get { false }"))
        XCTAssertTrue(source.contains("override var autohidesScrollers: Bool"))
        XCTAssertTrue(source.contains("hideScrollers()"))
        XCTAssertTrue(source.contains("horizontalScroller?.isHidden = true"))
    }

    func testShelfCollectionScrollsPrimarySelectionIntoView() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/ShelfCollectionRepresentable.swift")

        XCTAssertTrue(source.contains("scrollPrimarySelectionIntoView(in: collectionView)"))
        XCTAssertTrue(source.contains("primarySelectedID != previousPrimarySelectedID"))
        XCTAssertTrue(source.contains("ShelfCollectionScrollMath.origin("))
        XCTAssertTrue(source.contains("clipView.scroll(to: origin)"))
        XCTAssertTrue(source.contains("scrollView.reflectScrolledClipView(clipView)"))
        XCTAssertFalse(source.contains("collectionView.scrollToItems("))
    }

    func testShelfCollectionKeepsPreviewPopoverAnchoredWhileScrolling() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/ShelfCollectionRepresentable.swift")

        XCTAssertTrue(source.contains("func handleBoundsChanged()"))
        XCTAssertTrue(source.contains("reanchorPopoverIfNeeded()"))
        XCTAssertTrue(source.contains("itemFrame.intersection(visibleRect)"))
        XCTAssertTrue(source.contains("boundsChangedHandler?()"))
        XCTAssertFalse(source.contains("scrollTargetID"))
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
