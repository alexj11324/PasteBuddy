import AppKit
import XCTest
@testable import PasteBuddyCore
@testable import PasteBuddyMobile

@MainActor
final class PasteboardWriterTests: XCTestCase {
    func testClipboardMonitorRunsInjectedOCRAfterImageCaptureAndStoresSearchableMetadata() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let pasteboard = try XCTUnwrap(NSPasteboard(name: NSPasteboard.Name("PasteBuddyOCR-\(UUID().uuidString)")))
        defer { pasteboard.releaseGlobally() }
        let probe = OCRProbe(outcome: .success("Visible Launch Code"))
        let monitor = ClipboardMonitor(
            store: store,
            pasteboard: pasteboard,
            recognizeText: { imageData in
                try await probe.recognize(imageData)
            }
        )
        try await prime(monitor)

        pasteboard.clearContents()
        pasteboard.writeObjects([Self.testImage()])
        monitor.pollOnce()

        let item = try await waitForOCRText("Visible Launch Code", in: store)
        let callCount = await probe.callCount()
        let lastImageByteCount = await probe.lastImageByteCount()

        XCTAssertEqual(callCount, 1)
        XCTAssertGreaterThan(lastImageByteCount, 0)
        guard case .completed = item.ocrState else {
            return XCTFail("Expected completed OCR state.")
        }

        store.searchQuery = "launch code"
        XCTAssertEqual(store.filteredItems.map(\.id), [item.id])
    }

    func testClipboardMonitorRecordsOCRFailureWithoutBlockingCapture() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let pasteboard = try XCTUnwrap(NSPasteboard(name: NSPasteboard.Name("PasteBuddyOCRFailure-\(UUID().uuidString)")))
        defer { pasteboard.releaseGlobally() }
        let probe = OCRProbe(outcome: .failure("Vision unavailable"))
        let monitor = ClipboardMonitor(
            store: store,
            pasteboard: pasteboard,
            recognizeText: { imageData in
                try await probe.recognize(imageData)
            }
        )
        try await prime(monitor)

        pasteboard.clearContents()
        pasteboard.writeObjects([Self.testImage()])
        monitor.pollOnce()

        let item = try await waitForOCRFailure(in: store)
        let callCount = await probe.callCount()

        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(store.snapshot.items.map(\.id), [item.id])
        XCTAssertNil(item.payload.ocrText)
        guard case .failed(_, let message) = item.ocrState else {
            return XCTFail("Expected failed OCR state.")
        }
        XCTAssertEqual(message, "Vision unavailable")
    }

    func testClipboardMonitorSkipsOCRWhenImageOCRIsDisabled() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        store.toggleOCR()
        let pasteboard = try XCTUnwrap(NSPasteboard(name: NSPasteboard.Name("PasteBuddyOCRDisabled-\(UUID().uuidString)")))
        defer { pasteboard.releaseGlobally() }
        let probe = OCRProbe(outcome: .success("Should not scan"))
        let monitor = ClipboardMonitor(
            store: store,
            pasteboard: pasteboard,
            recognizeText: { imageData in
                try await probe.recognize(imageData)
            }
        )
        try await prime(monitor)

        pasteboard.clearContents()
        pasteboard.writeObjects([Self.testImage()])
        monitor.pollOnce()
        try await Task.sleep(nanoseconds: 100_000_000)
        let callCount = await probe.callCount()

        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(store.snapshot.items.count, 1)
        XCTAssertNil(store.snapshot.items.first?.payload.ocrText)
        XCTAssertEqual(store.snapshot.items.first?.ocrState, .notNeeded)
    }

    func testSharedPlainTextRendererUsesBestTextRepresentation() {
        let image = ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Screenshot",
            payload: ClipboardPayload(imageData: Data([0x01]), ocrText: "Recognized text")
        )
        let file = ClipboardItem(
            sourceAppName: "Finder",
            deviceName: "Test Mac",
            contentType: .file,
            title: "Report",
            payload: ClipboardPayload(fileURLString: "file:///Users/example/report.pdf")
        )

        XCTAssertEqual(ClipboardPlainTextRenderer.plainText(for: image), "Recognized text")
        XCTAssertEqual(ClipboardPlainTextRenderer.plainText(for: file), "/Users/example/report.pdf")
        XCTAssertEqual(
            ClipboardPlainTextRenderer.plainText(for: [image, file]),
            "Recognized text\n/Users/example/report.pdf"
        )
    }

    func testClipboardMonitorDoesNotCapturePrivatePasteboardURLAsLink() throws {
        let pasteboard = try XCTUnwrap(NSPasteboard(name: NSPasteboard.Name("PasteBuddyPrivateURL-\(UUID().uuidString)")))
        defer { pasteboard.releaseGlobally() }
        let token = "UCFP:6526f502-200a-44ef-a5ed-2238"

        pasteboard.clearContents()
        pasteboard.setString(token, forType: .URL)
        pasteboard.setString(token, forType: .string)

        let item = try XCTUnwrap(ClipboardMonitor.makeItem(
            from: pasteboard,
            sourceApp: "Paste",
            sourceBundleIdentifier: "com.example.Paste",
            privacy: PrivacyConfiguration(blockLikelySensitiveText: false)
        ))

        XCTAssertEqual(item.contentType, ClipboardContentType.text)
        XCTAssertEqual(item.presentationContentType, ClipboardContentType.text)
        XCTAssertNil(item.payload.urlString)
        XCTAssertNil(item.openableURL)
    }

    func testMobilePasteboardWriterIsUnavailableOutsideUIKit() {
        let item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Text",
            payload: ClipboardPayload(text: "mobile copy")
        )

        #if canImport(UIKit)
        XCTAssertTrue(MobilePasteboardWriter.copy(item))
        #else
        XCTAssertFalse(MobilePasteboardWriter.copy(item))
        #endif
    }

    func testPlainTextConversionUsesBestTextRepresentation() {
        let textItem = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Text Title",
            payload: ClipboardPayload(text: "Plain body")
        )
        let urlItem = ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Test Mac",
            contentType: .url,
            title: "Example",
            payload: ClipboardPayload(urlString: "https://example.com/path")
        )
        let fileItem = ClipboardItem(
            sourceAppName: "Finder",
            deviceName: "Test Mac",
            contentType: .file,
            title: "Report.pdf",
            payload: ClipboardPayload(fileURLString: "file:///Users/example/Report.pdf")
        )
        let imageItem = ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Screenshot",
            payload: ClipboardPayload(imageData: Data([0x01]), ocrText: "OCR text")
        )

        XCTAssertEqual(PasteboardWriter.plainText(for: textItem), "Plain body")
        XCTAssertEqual(PasteboardWriter.plainText(for: urlItem), "https://example.com/path")
        XCTAssertEqual(PasteboardWriter.plainText(for: fileItem), "/Users/example/Report.pdf")
        XCTAssertEqual(PasteboardWriter.plainText(for: imageItem), "OCR text")
    }

    func testPlainTextConversionSupportsMultipleFilesAndMixedPayloads() {
        let multiFileItem = ClipboardItem(
            sourceAppName: "Finder",
            deviceName: "Test Mac",
            contentType: .file,
            title: "Reports",
            payload: ClipboardPayload(
                fileURLString: "file:///Users/example/Report.pdf",
                fileURLStrings: [
                    "file:///Users/example/Report.pdf",
                    "file:///Users/example/Brief.txt"
                ]
            )
        )
        let mixedItem = ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Test Mac",
            contentType: .mixed,
            title: "Mixed",
            payload: ClipboardPayload(
                text: "Launch note",
                htmlString: "<strong>Launch note</strong>",
                urlString: "https://example.com/launch",
                fileURLStrings: ["file:///Users/example/Brief.txt"]
            )
        )

        XCTAssertEqual(
            PasteboardWriter.plainText(for: multiFileItem),
            "/Users/example/Report.pdf\n/Users/example/Brief.txt"
        )
        XCTAssertEqual(
            PasteboardWriter.plainText(for: mixedItem),
            "Launch note\nhttps://example.com/launch\n/Users/example/Brief.txt"
        )
    }

    func testCopyPlainTextWritesOnlyStringToPasteboard() throws {
        let pasteboard = try XCTUnwrap(NSPasteboard(name: NSPasteboard.Name("PasteBuddyPlainText-\(UUID().uuidString)")))
        defer { pasteboard.releaseGlobally() }
        let item = ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Screenshot",
            payload: ClipboardPayload(imageData: Data([0x01]), ocrText: "Copy this OCR text")
        )

        PasteboardWriter.copy(item, format: .plainText, to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "Copy this OCR text")
        XCTAssertFalse(pasteboard.types?.contains(.tiff) ?? false)
    }

    func testCopyTextPreservesRichVariantsWhenAvailable() throws {
        let pasteboard = try XCTUnwrap(NSPasteboard(name: NSPasteboard.Name("PasteBuddyRichText-\(UUID().uuidString)")))
        defer { pasteboard.releaseGlobally() }
        let rtf = Data("{\\rtf1\\ansi Rich body}".utf8)
        let item = ClipboardItem(
            sourceAppName: "Pages",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Rich",
            payload: ClipboardPayload(
                text: "Rich body",
                htmlString: "<strong>Rich body</strong>",
                rtfData: rtf
            )
        )

        PasteboardWriter.copy(item, to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "Rich body")
        XCTAssertEqual(pasteboard.string(forType: .html), "<strong>Rich body</strong>")
        XCTAssertEqual(pasteboard.data(forType: .rtf), rtf)
    }

    func testCopyMultipleFileURLsWritesReusablePasteboardObjects() throws {
        let pasteboard = try XCTUnwrap(NSPasteboard(name: NSPasteboard.Name("PasteBuddyMultiFile-\(UUID().uuidString)")))
        defer { pasteboard.releaseGlobally() }
        let item = ClipboardItem(
            sourceAppName: "Finder",
            deviceName: "Test Mac",
            contentType: .file,
            title: "Two Files",
            payload: ClipboardPayload(
                fileURLStrings: [
                    "file:///Users/example/Report.pdf",
                    "file:///Users/example/Brief.txt"
                ]
            )
        )

        PasteboardWriter.copy(item, to: pasteboard)

        let urls = try XCTUnwrap(pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])
        XCTAssertEqual(urls.map(\.lastPathComponent), ["Report.pdf", "Brief.txt"])
    }

    func testClipboardMonitorBuildsMixedPayloadWithRichTextAndMultipleFiles() throws {
        let pasteboard = try XCTUnwrap(NSPasteboard(name: NSPasteboard.Name("PasteBuddyMixedCapture-\(UUID().uuidString)")))
        defer { pasteboard.releaseGlobally() }
        let launchURL = try XCTUnwrap(URL(string: "https://example.com/launch"))
        let reportURL = try XCTUnwrap(URL(string: "file:///Users/example/Report.pdf"))
        let briefURL = try XCTUnwrap(URL(string: "file:///Users/example/Brief.txt"))
        pasteboard.clearContents()
        pasteboard.writeObjects([launchURL as NSURL, reportURL as NSURL, briefURL as NSURL])
        pasteboard.setString("Launch note", forType: .string)
        pasteboard.setString("<strong>Launch note</strong>", forType: .html)

        let item = try XCTUnwrap(ClipboardMonitor.makeItem(
            from: pasteboard,
            sourceApp: "Safari",
            sourceBundleIdentifier: "com.apple.Safari",
            privacy: PrivacyConfiguration(blockLikelySensitiveText: false)
        ))

        XCTAssertEqual(item.contentType, .mixed)
        XCTAssertEqual(item.payload.text, "Launch note")
        XCTAssertEqual(item.payload.htmlString, "<strong>Launch note</strong>")
        XCTAssertEqual(item.payload.urlString, "https://example.com/launch")
        XCTAssertEqual(item.payload.allFileURLStrings.map { URL(string: $0)?.lastPathComponent }, ["Report.pdf", "Brief.txt"])
        XCTAssertEqual(item.sourceAppName, "Safari")
        XCTAssertEqual(item.title, "Mixed Clipboard Item")
        XCTAssertTrue(item.payload.searchableText.contains("Launch note"))
        XCTAssertTrue(item.payload.searchableText.contains("https://example.com/launch"))
    }

    func testClipboardMonitorIgnoresUnsupportedPrivatePasteboardTypes() throws {
        let pasteboard = try XCTUnwrap(NSPasteboard(name: NSPasteboard.Name("PasteBuddyPrivateType-\(UUID().uuidString)")))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(Data([0x01, 0x02]), forType: NSPasteboard.PasteboardType("com.example.private-payload"))

        let item = ClipboardMonitor.makeItem(
            from: pasteboard,
            sourceApp: "Private App",
            sourceBundleIdentifier: "com.example.private",
            privacy: PrivacyConfiguration(blockLikelySensitiveText: false)
        )

        XCTAssertNil(item)
    }

    func testCopyMultipleItemsWritesDisplayOrderPlainText() throws {
        let pasteboard = try XCTUnwrap(NSPasteboard(name: NSPasteboard.Name("PasteBuddyMultiCopy-\(UUID().uuidString)")))
        defer { pasteboard.releaseGlobally() }
        let first = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "First",
            payload: ClipboardPayload(text: "first")
        )
        let second = ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Test Mac",
            contentType: .url,
            title: "Second",
            payload: ClipboardPayload(urlString: "https://example.com")
        )

        PasteboardWriter.copy([first, second], to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "first\nhttps://example.com")
    }

    func testCopyEmptySelectionLeavesPasteboardUntouched() throws {
        let pasteboard = try XCTUnwrap(NSPasteboard(name: NSPasteboard.Name("PasteBuddyEmptyCopy-\(UUID().uuidString)")))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("existing", forType: .string)

        PasteboardWriter.copy([], to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "existing")
    }

    func testDirectPasteFallbackCopiesItemAndReportsAccessibilityRequirement() throws {
        let pasteboard = try XCTUnwrap(NSPasteboard(name: NSPasteboard.Name("PasteBuddyDirectFallback-\(UUID().uuidString)")))
        defer { pasteboard.releaseGlobally() }
        let item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Reply",
            payload: ClipboardPayload(text: "copy first")
        )

        let result = PasteboardWriter.pasteToFrontmostApp(
            item,
            to: pasteboard,
            isAccessibilityTrusted: false,
            sendPasteEvent: { XCTFail("Command-V should not be sent without Accessibility trust.") }
        )

        XCTAssertEqual(result.outcome, .copiedOnlyAccessibilityRequired)
        XCTAssertEqual(result.itemCount, 1)
        XCTAssertTrue(result.needsAccessibilityPermission)
        XCTAssertEqual(pasteboard.string(forType: .string), "copy first")
    }

    func testPasteOnlyDirectPasteFailsWithoutCopyingWhenAccessibilityIsMissing() throws {
        let pasteboard = try XCTUnwrap(NSPasteboard(name: NSPasteboard.Name("PasteBuddyPasteOnlyAccessibility-\(UUID().uuidString)")))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("existing clipboard", forType: .string)
        let item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Paste Only",
            payload: ClipboardPayload(text: "must not copy")
        )

        let result = PasteboardWriter.pasteToFrontmostApp(
            item,
            to: pasteboard,
            isAccessibilityTrusted: false,
            options: PasteboardWriter.DirectPasteOptions().pasteOnly,
            sendPasteEvent: { XCTFail("Command-V should not be sent without Accessibility trust.") }
        )

        XCTAssertEqual(result.outcome, .failedAccessibilityPermissionRequired)
        XCTAssertTrue(result.needsAccessibilityPermission)
        XCTAssertTrue(result.statusMessage.contains("Paste was not sent"))
        XCTAssertFalse(result.statusMessage.localizedCaseInsensitiveContains("copied"))
        XCTAssertEqual(pasteboard.string(forType: .string), "existing clipboard")
    }

    func testDirectPasteWithAccessibilitySendsPasteEventAndReportsSuccess() throws {
        let pasteboard = try XCTUnwrap(NSPasteboard(name: NSPasteboard.Name("PasteBuddyDirectSuccess-\(UUID().uuidString)")))
        defer { pasteboard.releaseGlobally() }
        let first = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "First",
            payload: ClipboardPayload(text: "first")
        )
        let second = ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Test Mac",
            contentType: .url,
            title: "Second",
            payload: ClipboardPayload(urlString: "https://example.com")
        )
        var sentPasteEventCount = 0

        let result = PasteboardWriter.pasteToFrontmostApp(
            [first, second],
            format: .plainText,
            to: pasteboard,
            isAccessibilityTrusted: true,
            sendPasteEvent: { sentPasteEventCount += 1 }
        )

        XCTAssertEqual(result.outcome, .pastedToFrontmostApp)
        XCTAssertEqual(result.itemCount, 2)
        XCTAssertEqual(result.format, .plainText)
        XCTAssertEqual(sentPasteEventCount, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "first\nhttps://example.com")
    }

    func testDirectPastePreparesTargetBeforeSendingPasteEvent() throws {
        let pasteboard = try XCTUnwrap(NSPasteboard(name: NSPasteboard.Name("PasteBuddyDirectPrepare-\(UUID().uuidString)")))
        defer { pasteboard.releaseGlobally() }
        let item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Prepared",
            payload: ClipboardPayload(text: "prepared paste")
        )
        var preparedTarget = false
        var sentPasteEvent = false

        let result = PasteboardWriter.pasteToFrontmostApp(
            item,
            to: pasteboard,
            isAccessibilityTrusted: true,
            prepareForPaste: {
                preparedTarget = true
            },
            sendPasteEvent: {
                XCTAssertTrue(preparedTarget)
                sentPasteEvent = true
            }
        )

        XCTAssertEqual(result.outcome, .pastedToFrontmostApp)
        XCTAssertTrue(sentPasteEvent)
        XCTAssertEqual(pasteboard.string(forType: .string), "prepared paste")
    }

    func testDirectPasteDoesNotPrepareTargetWhenAccessibilityIsDenied() throws {
        let pasteboard = try XCTUnwrap(NSPasteboard(name: NSPasteboard.Name("PasteBuddyDirectNoPrepare-\(UUID().uuidString)")))
        defer { pasteboard.releaseGlobally() }
        let item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Copy Only",
            payload: ClipboardPayload(text: "copy only")
        )

        let result = PasteboardWriter.pasteToFrontmostApp(
            item,
            to: pasteboard,
            isAccessibilityTrusted: false,
            prepareForPaste: { XCTFail("Target activation should not run without Accessibility trust.") },
            sendPasteEvent: { XCTFail("Command-V should not be sent without Accessibility trust.") }
        )

        XCTAssertEqual(result.outcome, .copiedOnlyAccessibilityRequired)
        XCTAssertEqual(pasteboard.string(forType: .string), "copy only")
    }

    func testDirectPastePreparesTargetOnceForMultipleItemsBeforeSendingPasteEvent() throws {
        let pasteboard = try XCTUnwrap(NSPasteboard(name: NSPasteboard.Name("PasteBuddyDirectMultiPrepare-\(UUID().uuidString)")))
        defer { pasteboard.releaseGlobally() }
        let first = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "First",
            payload: ClipboardPayload(text: "first prepared")
        )
        let second = ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Test Mac",
            contentType: .url,
            title: "Second",
            payload: ClipboardPayload(urlString: "https://example.com/prepared")
        )
        var events: [String] = []

        let result = PasteboardWriter.pasteToFrontmostApp(
            [first, second],
            format: .plainText,
            to: pasteboard,
            isAccessibilityTrusted: true,
            prepareForPaste: { events.append("prepare") },
            sendPasteEvent: { events.append("send") }
        )

        XCTAssertEqual(result.outcome, .pastedToFrontmostApp)
        XCTAssertEqual(events, ["prepare", "send"])
        XCTAssertEqual(pasteboard.string(forType: .string), "first prepared\nhttps://example.com/prepared")
    }

    func testDirectPasteWaitsForTargetActivationBeforeSendingPasteEvent() throws {
        let pasteboard = try XCTUnwrap(NSPasteboard(name: NSPasteboard.Name("PasteBuddyDirectWait-\(UUID().uuidString)")))
        defer { pasteboard.releaseGlobally() }
        let item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Wait",
            payload: ClipboardPayload(text: "wait for active target")
        )
        let targetBundleIdentifier = "com.example.Target"
        var activeProbeCount = 0
        var sentPasteEvent = false

        let result = PasteboardWriter.pasteToFrontmostApp(
            item,
            to: pasteboard,
            isAccessibilityTrusted: true,
            targetBundleIdentifier: targetBundleIdentifier,
            activeApplicationBundleIdentifier: {
                activeProbeCount += 1
                return activeProbeCount >= 2 ? targetBundleIdentifier : "com.example.Other"
            },
            options: PasteboardWriter.DirectPasteOptions(activationWaitTimeout: 0.08),
            prepareForPaste: {},
            sendPasteEvent: {
                XCTAssertGreaterThan(activeProbeCount, 1)
                sentPasteEvent = true
            }
        )

        XCTAssertEqual(result.outcome, .pastedToFrontmostApp)
        XCTAssertTrue(sentPasteEvent)
        XCTAssertEqual(pasteboard.string(forType: .string), "wait for active target")
    }

    func testDirectPasteDefaultsWaitForActivationWithoutPasteDelay() {
        let options = PasteboardWriter.DirectPasteOptions.default

        XCTAssertGreaterThanOrEqual(options.activationWaitTimeout, 0.35)
        XCTAssertEqual(options.pasteDispatchDelay, 0)
        XCTAssertEqual(PasteboardWriter.DirectPasteOptions(pasteDispatchDelay: 0.05).pasteDispatchDelay, 0.05)
    }

    func testAsyncDirectPasteWaitsForTargetActivationWithoutBlockingMainActor() async throws {
        let pasteboard = try XCTUnwrap(NSPasteboard(name: NSPasteboard.Name("PasteBuddyAsyncDirectWait-\(UUID().uuidString)")))
        defer { pasteboard.releaseGlobally() }
        let item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Async Wait",
            payload: ClipboardPayload(text: "async wait for active target")
        )
        let targetBundleIdentifier = "com.example.AsyncTarget"
        var activeBundleIdentifier = "com.example.Other"
        var sentPasteEvent = false
        let activationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000)
            activeBundleIdentifier = targetBundleIdentifier
        }

        let result = await PasteboardWriter.pasteToFrontmostAppAsync(
            item,
            to: pasteboard,
            isAccessibilityTrusted: true,
            targetBundleIdentifier: targetBundleIdentifier,
            activeApplicationBundleIdentifier: {
                activeBundleIdentifier
            },
            options: PasteboardWriter.DirectPasteOptions(activationWaitTimeout: 0.12),
            prepareForPaste: {},
            sendPasteEvent: {
                XCTAssertEqual(activeBundleIdentifier, targetBundleIdentifier)
                sentPasteEvent = true
            }
        )
        await activationTask.value

        XCTAssertEqual(result.outcome, .pastedToFrontmostApp)
        XCTAssertTrue(sentPasteEvent)
        XCTAssertEqual(pasteboard.string(forType: .string), "async wait for active target")
    }

    func testAsyncDirectPasteValidatesAfterTargetWaitBeforeCopyingOrSending() async throws {
        let pasteboard = try XCTUnwrap(NSPasteboard(name: NSPasteboard.Name("PasteBuddyAsyncValidation-\(UUID().uuidString)")))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("existing clipboard", forType: .string)
        let item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Validate After Wait",
            payload: ClipboardPayload(text: "must never be copied")
        )
        let gate = PasteTargetWaitGate()
        var sentPasteEvent = false

        let pasteTask = Task { @MainActor in
            try await PasteboardWriter.pasteToFrontmostAppAsync(
                item,
                to: pasteboard,
                isAccessibilityTrusted: true,
                options: .default,
                waitForTargetApplication: {
                    await gate.suspend()
                    return true
                },
                resolvingItemBeforeCopy: {
                    throw PasteValidationProbeError.denied
                },
                sendPasteEvent: {
                    sentPasteEvent = true
                }
            )
        }
        await gate.waitUntilSuspended()
        await gate.resume()

        do {
            _ = try await pasteTask.value
            XCTFail("Expected paste validation to fail.")
        } catch {
            XCTAssertEqual(error as? PasteValidationProbeError, .denied)
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "existing clipboard")
        XCTAssertFalse(sentPasteEvent)
    }

    func testDirectPasteCopiesOnlyWhenTargetDoesNotBecomeActive() throws {
        let pasteboard = try XCTUnwrap(NSPasteboard(name: NSPasteboard.Name("PasteBuddyDirectNoTarget-\(UUID().uuidString)")))
        defer { pasteboard.releaseGlobally() }
        let item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "No Target",
            payload: ClipboardPayload(text: "copy without wrong paste")
        )
        var preparedTarget = false

        let result = PasteboardWriter.pasteToFrontmostApp(
            item,
            to: pasteboard,
            isAccessibilityTrusted: true,
            targetBundleIdentifier: "com.example.Target",
            activeApplicationBundleIdentifier: {
                "com.example.Other"
            },
            options: PasteboardWriter.DirectPasteOptions(activationWaitTimeout: 0.01),
            prepareForPaste: {
                preparedTarget = true
            },
            sendPasteEvent: {
                XCTFail("Command-V should not be sent when the target app is not active.")
            }
        )

        XCTAssertTrue(preparedTarget)
        XCTAssertEqual(result.outcome, .copiedOnlyNoTargetApplication)
        XCTAssertEqual(result.itemCount, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "copy without wrong paste")
    }

    func testPasteOnlyDirectPasteFailsWithoutCopyingWhenTargetDoesNotBecomeActive() throws {
        let pasteboard = try XCTUnwrap(NSPasteboard(name: NSPasteboard.Name("PasteBuddyPasteOnlyNoTarget-\(UUID().uuidString)")))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("existing clipboard", forType: .string)
        let item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Paste Only No Target",
            payload: ClipboardPayload(text: "must not copy")
        )
        var preparedTarget = false

        let result = PasteboardWriter.pasteToFrontmostApp(
            item,
            to: pasteboard,
            isAccessibilityTrusted: true,
            targetBundleIdentifier: "com.example.Target",
            activeApplicationBundleIdentifier: {
                "com.example.Other"
            },
            options: PasteboardWriter.DirectPasteOptions(activationWaitTimeout: 0.01).pasteOnly,
            prepareForPaste: {
                preparedTarget = true
            },
            sendPasteEvent: {
                XCTFail("Command-V should not be sent when the target app is not active.")
            }
        )

        XCTAssertTrue(preparedTarget)
        XCTAssertEqual(result.outcome, .failedNoTargetApplication)
        XCTAssertTrue(result.statusMessage.contains("Paste was not sent"))
        XCTAssertFalse(result.statusMessage.localizedCaseInsensitiveContains("copied"))
        XCTAssertEqual(pasteboard.string(forType: .string), "existing clipboard")
    }

    func testAsyncDirectPasteCopiesOnlyWhenTargetDoesNotBecomeActive() async throws {
        let pasteboard = try XCTUnwrap(NSPasteboard(name: NSPasteboard.Name("PasteBuddyAsyncDirectNoTarget-\(UUID().uuidString)")))
        defer { pasteboard.releaseGlobally() }
        let item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Async No Target",
            payload: ClipboardPayload(text: "async copy without wrong paste")
        )
        var preparedTarget = false

        let result = await PasteboardWriter.pasteToFrontmostAppAsync(
            item,
            to: pasteboard,
            isAccessibilityTrusted: true,
            targetBundleIdentifier: "com.example.Target",
            activeApplicationBundleIdentifier: {
                "com.example.Other"
            },
            options: PasteboardWriter.DirectPasteOptions(activationWaitTimeout: 0.01),
            prepareForPaste: {
                preparedTarget = true
            },
            sendPasteEvent: {
                XCTFail("Command-V should not be sent when the target app is not active.")
            }
        )

        XCTAssertTrue(preparedTarget)
        XCTAssertEqual(result.outcome, .copiedOnlyNoTargetApplication)
        XCTAssertEqual(result.itemCount, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "async copy without wrong paste")
    }

    func testDirectPasteHonorsDispatchDelayBeforeSendingPasteEvent() throws {
        let pasteboard = try XCTUnwrap(NSPasteboard(name: NSPasteboard.Name("PasteBuddyDirectDelay-\(UUID().uuidString)")))
        defer { pasteboard.releaseGlobally() }
        let item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Delayed",
            payload: ClipboardPayload(text: "delayed paste")
        )
        let start = Date()
        var sendDate: Date?

        let result = PasteboardWriter.pasteToFrontmostApp(
            item,
            to: pasteboard,
            isAccessibilityTrusted: true,
            options: PasteboardWriter.DirectPasteOptions(pasteDispatchDelay: 0.03),
            sendPasteEvent: {
                sendDate = Date()
            }
        )

        let elapsed = try XCTUnwrap(sendDate).timeIntervalSince(start)
        XCTAssertEqual(result.outcome, .pastedToFrontmostApp)
        XCTAssertGreaterThanOrEqual(elapsed, 0.02)
        XCTAssertEqual(pasteboard.string(forType: .string), "delayed paste")
    }

    func testAsyncDirectPasteHonorsDispatchDelayBeforeSendingPasteEvent() async throws {
        let pasteboard = try XCTUnwrap(NSPasteboard(name: NSPasteboard.Name("PasteBuddyAsyncDirectDelay-\(UUID().uuidString)")))
        defer { pasteboard.releaseGlobally() }
        let item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Async Delayed",
            payload: ClipboardPayload(text: "async delayed paste")
        )
        let start = Date()
        var sendDate: Date?

        let result = await PasteboardWriter.pasteToFrontmostAppAsync(
            item,
            to: pasteboard,
            isAccessibilityTrusted: true,
            options: PasteboardWriter.DirectPasteOptions(pasteDispatchDelay: 0.03),
            sendPasteEvent: {
                sendDate = Date()
            }
        )

        let elapsed = try XCTUnwrap(sendDate).timeIntervalSince(start)
        XCTAssertEqual(result.outcome, .pastedToFrontmostApp)
        XCTAssertGreaterThanOrEqual(elapsed, 0.02)
        XCTAssertEqual(pasteboard.string(forType: .string), "async delayed paste")
    }

    func testAsyncDirectPasteCancellationDuringDispatchDelayCopiesButDoesNotSend() async throws {
        let pasteboard = try XCTUnwrap(NSPasteboard(name: NSPasteboard.Name("PasteBuddyAsyncDirectCancelDelay-\(UUID().uuidString)")))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("existing clipboard", forType: .string)
        let item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Cancelled Delay",
            payload: ClipboardPayload(text: "copied before cancellation")
        )
        let prepared = expectation(description: "Paste preparation started")
        var sentPasteEvent = false

        let task = Task { @MainActor in
            await PasteboardWriter.pasteToFrontmostAppAsync(
                item,
                to: pasteboard,
                isAccessibilityTrusted: true,
                options: PasteboardWriter.DirectPasteOptions(pasteDispatchDelay: 0.08),
                prepareForPaste: {
                    prepared.fulfill()
                },
                sendPasteEvent: {
                    sentPasteEvent = true
                }
            )
        }

        await fulfillment(of: [prepared], timeout: 1)
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.outcome, .failedNoTargetApplication)
        XCTAssertEqual(result.itemCount, 1)
        XCTAssertFalse(sentPasteEvent)
        XCTAssertEqual(pasteboard.string(forType: .string), "copied before cancellation")
    }

    func testAsyncMultiItemDirectPasteCancellationDuringActivationWaitDoesNotCopyOrSend() async throws {
        let pasteboard = try XCTUnwrap(NSPasteboard(name: NSPasteboard.Name("PasteBuddyAsyncMultiCancelActivation-\(UUID().uuidString)")))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("existing clipboard", forType: .string)
        let items = [
            ClipboardItem(
                sourceAppName: "Notes",
                deviceName: "Test Mac",
                contentType: .text,
                title: "Cancelled One",
                payload: ClipboardPayload(text: "must not be copied one")
            ),
            ClipboardItem(
                sourceAppName: "Notes",
                deviceName: "Test Mac",
                contentType: .text,
                title: "Cancelled Two",
                payload: ClipboardPayload(text: "must not be copied two")
            )
        ]
        let prepared = expectation(description: "Paste preparation started")
        var sentPasteEvent = false

        let task = Task { @MainActor in
            await PasteboardWriter.pasteToFrontmostAppAsync(
                items,
                to: pasteboard,
                isAccessibilityTrusted: true,
                targetBundleIdentifier: "com.example.Target",
                activeApplicationBundleIdentifier: {
                    "com.example.Other"
                },
                options: PasteboardWriter.DirectPasteOptions(activationWaitTimeout: 0.08),
                prepareForPaste: {
                    prepared.fulfill()
                },
                sendPasteEvent: {
                    sentPasteEvent = true
                }
            )
        }

        await fulfillment(of: [prepared], timeout: 1)
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.outcome, .failedNoTargetApplication)
        XCTAssertEqual(result.itemCount, 2)
        XCTAssertFalse(sentPasteEvent)
        XCTAssertEqual(pasteboard.string(forType: .string), "existing clipboard")
    }

    func testDirectPasteEmptySelectionReportsNoOp() throws {
        let pasteboard = try XCTUnwrap(NSPasteboard(name: NSPasteboard.Name("PasteBuddyDirectEmpty-\(UUID().uuidString)")))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("existing", forType: .string)

        let result = PasteboardWriter.pasteToFrontmostApp(
            [],
            to: pasteboard,
            isAccessibilityTrusted: true,
            sendPasteEvent: { XCTFail("Empty selection should not send Command-V.") }
        )

        XCTAssertEqual(result.outcome, .emptySelection)
        XCTAssertEqual(result.itemCount, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "existing")
    }

    private static func testImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        NSColor.black.setFill()
        NSRect(x: 2, y: 2, width: 4, height: 4).fill()
        image.unlockFocus()
        return image
    }

    private func prime(_ monitor: ClipboardMonitor) async throws {
        XCTAssertNil(monitor.lastChangeCountForTesting)
        monitor.pollOnce()
        let deadline = Date().addingTimeInterval(1)
        while monitor.lastChangeCountForTesting == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(monitor.lastChangeCountForTesting)
    }

    private func waitForOCRText(_ expectedText: String, in store: PasteBuddyStore) async throws -> ClipboardItem {
        try await waitForOCRItem(in: store) { item in
            item.payload.ocrText == expectedText
        }
    }

    private func waitForOCRFailure(in store: PasteBuddyStore) async throws -> ClipboardItem {
        try await waitForOCRItem(in: store) { item in
            if case .failed = item.ocrState {
                return true
            }
            return false
        }
    }

    private func waitForOCRItem(
        in store: PasteBuddyStore,
        matching predicate: (ClipboardItem) -> Bool
    ) async throws -> ClipboardItem {
        for _ in 0..<20 {
            if let item = store.snapshot.items.first(where: predicate) {
                return item
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return try XCTUnwrap(store.snapshot.items.first(where: predicate))
    }
}

private enum PasteValidationProbeError: Error, Equatable {
    case denied
}

private actor PasteTargetWaitGate {
    private var isSuspended = false
    private var suspensionContinuation: CheckedContinuation<Void, Never>?
    private var observerContinuations: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        isSuspended = true
        let observers = observerContinuations
        observerContinuations.removeAll()
        observers.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            suspensionContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            observerContinuations.append(continuation)
        }
    }

    func resume() {
        suspensionContinuation?.resume()
        suspensionContinuation = nil
    }
}

private enum OCRProbeOutcome {
    case success(String)
    case failure(String)
}

private struct OCRProbeError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

private actor OCRProbe {
    private let outcome: OCRProbeOutcome
    private var calls = 0
    private var lastByteCount = 0

    init(outcome: OCRProbeOutcome) {
        self.outcome = outcome
    }

    func recognize(_ imageData: Data) async throws -> String {
        calls += 1
        lastByteCount = imageData.count
        switch outcome {
        case .success(let text):
            return text
        case .failure(let message):
            throw OCRProbeError(message: message)
        }
    }

    func callCount() -> Int {
        calls
    }

    func lastImageByteCount() -> Int {
        lastByteCount
    }
}
