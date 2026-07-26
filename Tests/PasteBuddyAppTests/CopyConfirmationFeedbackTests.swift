import AppKit
import PasteBuddyCore
import UniformTypeIdentifiers
import XCTest
@testable import PasteBuddy

@MainActor
final class CopyConfirmationFeedbackTests: XCTestCase {
    func testFeedbackAppearsOnlyAfterSuccessfulPasteboardWrite() {
        var state = CopyConfirmationFeedbackState()

        XCTAssertNil(state.recordCopy(succeeded: false, itemCount: 1))
        XCTAssertNil(state.presentation)

        let presentation = state.recordCopy(succeeded: true, itemCount: 1)

        XCTAssertEqual(presentation?.itemCount, 1)
        XCTAssertEqual(state.presentation, presentation)
    }

    func testNativeCopyReceiptUsesSharedInternalCopyMarker() {
        XCTAssertEqual(
            ClipboardNativeCopyFeedbackReceipt.pasteboardType,
            PasteboardWriter.internalCopyPasteboardType
        )
    }

    func testFeedbackMessageLocalizesSingularAndPluralCounts() {
        var requestedKeys: [String] = []
        let localize: (String, String) -> String = { key, defaultValue in
            requestedKeys.append(key)
            return defaultValue
        }

        XCTAssertEqual(
            CopyConfirmationFeedbackMessage.text(itemCount: 1, localize: localize),
            "Copied 1 item"
        )
        XCTAssertEqual(
            CopyConfirmationFeedbackMessage.text(itemCount: 3, localize: localize),
            "Copied 3 items"
        )
        XCTAssertEqual(requestedKeys, [
            "format.copied_item",
            "format.copied_items",
        ])
    }

    func testFeedbackUsesEnglishAndSimplifiedChineseLocalizationResources() throws {
        let english = try localizationValues(locale: "en")
        let simplifiedChinese = try localizationValues(locale: "zh-Hans")

        XCTAssertEqual(
            CopyConfirmationFeedbackMessage.text(itemCount: 1) { key, defaultValue in
                english[key] ?? defaultValue
            },
            "Copied 1 item"
        )
        XCTAssertEqual(
            CopyConfirmationFeedbackMessage.text(itemCount: 3) { key, defaultValue in
                simplifiedChinese[key] ?? defaultValue
            },
            "已复制 3 个项目"
        )
    }

    func testRepeatedCopiesCoalesceAndOnlyLatestTimerDismisses() async throws {
        let lifecycle = CopyConfirmationFeedbackLifecycle()
        var dismissals: [Int] = []

        lifecycle.recordCopy(
            succeeded: true,
            itemCount: 1,
            dismissAfter: .milliseconds(80),
            onDismiss: { dismissals.append(1) }
        )
        try await Task.sleep(for: .milliseconds(10))
        lifecycle.recordCopy(
            succeeded: true,
            itemCount: 4,
            dismissAfter: .milliseconds(40),
            onDismiss: { dismissals.append(4) }
        )

        XCTAssertEqual(lifecycle.state.presentation?.itemCount, 4)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(lifecycle.state.presentation)
        XCTAssertEqual(dismissals, [4])
    }

    func testNativeCopyReceiptMatchesOnlyItsOwnPasteboardWrite() throws {
        let pasteboard = try XCTUnwrap(
            NSPasteboard(name: NSPasteboard.Name("PasteBuddyCopyReceipt-\(UUID().uuidString)"))
        )
        defer { pasteboard.releaseGlobally() }
        let first = ClipboardNativeCopyFeedbackReceipt()
        let second = ClipboardNativeCopyFeedbackReceipt()

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(first.data, forType: ClipboardNativeCopyFeedbackReceipt.pasteboardType))
        XCTAssertTrue(first.matches(pasteboard))
        XCTAssertFalse(second.matches(pasteboard))
    }

    func testNativeCopyReceiptRegistersOnReturnedProvider() async throws {
        let receipt = ClipboardNativeCopyFeedbackReceipt()
        let provider = NSItemProvider(object: "copied" as NSString)
        XCTAssertTrue(receipt.register(on: provider))

        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(
            ClipboardNativeCopyFeedbackReceipt.pasteboardType.rawValue
        ))
        let loaded = try await loadReceipt(from: provider)
        XCTAssertEqual(loaded, receipt.data)
    }

    func testNativeCopyReceiptFailsWhenRealProviderPayloadFails() async throws {
        let receipt = ClipboardNativeCopyFeedbackReceipt()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.tiff.identifier,
            visibility: .all
        ) { completion in
            completion(nil, CocoaError(.fileReadNoSuchFile))
            return nil
        }
        XCTAssertTrue(receipt.register(on: provider))

        do {
            _ = try await loadReceipt(from: provider)
            XCTFail("Receipt must fail when the requested clipboard payload cannot load.")
        } catch {
            XCTAssertNotNil(error as NSError)
        }
    }

    func testSharedCopyRouteReportsOnlySuccessfulWritesWithCorrectCounts() throws {
        let pasteboard = try XCTUnwrap(
            NSPasteboard(name: NSPasteboard.Name("PasteBuddyCopyFeedback-\(UUID().uuidString)"))
        )
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
        let invalidImage = ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Invalid",
            payload: ClipboardPayload(imageData: Data([0x01]))
        )
        var reportedCounts: [Int] = []

        XCTAssertTrue(ClipboardPanelCopyCoordinator.copy(
            first,
            to: pasteboard,
            reportSuccess: { reportedCounts.append($0) }
        ))
        XCTAssertTrue(ClipboardPanelCopyCoordinator.copy(
            [first, second],
            to: pasteboard,
            reportSuccess: { reportedCounts.append($0) }
        ))
        XCTAssertFalse(ClipboardPanelCopyCoordinator.copy(
            invalidImage,
            to: pasteboard,
            reportSuccess: { reportedCounts.append($0) }
        ))
        XCTAssertEqual(reportedCounts, [1, 2])
    }

    private func localizationValues(locale: String) throws -> [String: String] {
        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for _ in 0..<8 {
            let candidate = directory
                .appendingPathComponent("Sources/PasteBuddy/Resources")
                .appendingPathComponent("\(locale).lproj/Localizable.strings")
            if let values = NSDictionary(contentsOf: candidate) as? [String: String] {
                return values
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func loadReceipt(from provider: NSItemProvider) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(
                forTypeIdentifier: ClipboardNativeCopyFeedbackReceipt.pasteboardType.rawValue
            ) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }
}
