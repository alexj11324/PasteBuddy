import XCTest
@testable import PasteBuddyCore

final class ClipboardVisualPreviewTests: XCTestCase {
    func testLinkPreviewUsesHostAndOriginalURL() {
        let item = ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Test Mac",
            contentType: .url,
            title: "Paste",
            payload: ClipboardPayload(urlString: "https://pasteapp.io/help/paste-on-ipad")
        )

        let preview = item.visualPreview

        XCTAssertEqual(preview.headline, "pasteapp.io")
        XCTAssertEqual(preview.body, "https://pasteapp.io/help/paste-on-ipad")
        XCTAssertEqual(preview.detail, "Link")
        XCTAssertEqual(preview.badgeText, "Link")
    }

    func testFilePreviewShowsFirstFileAndRemainingCount() {
        let item = ClipboardItem(
            sourceAppName: "Finder",
            deviceName: "Test Mac",
            contentType: .file,
            title: "Files",
            payload: ClipboardPayload(
                fileURLString: "file:///Users/alex/Desktop/brief.pdf",
                fileURLStrings: [
                    "file:///Users/alex/Desktop/mockup.png",
                    "file:///Users/alex/Desktop/notes.txt"
                ]
            )
        )

        let preview = item.visualPreview

        XCTAssertEqual(preview.headline, "brief.pdf")
        XCTAssertEqual(preview.body, "file:///Users/alex/Desktop/brief.pdf")
        XCTAssertEqual(preview.detail, "2 more files")
        XCTAssertEqual(preview.systemImageName, "doc")
    }

    func testImagePreviewUsesOCRTextAndRequestsThumbnailWhenImageDataExists() {
        let item = ClipboardItem(
            sourceAppName: "Screenshot",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Screenshot",
            payload: ClipboardPayload(imageData: Data([0x01, 0x02, 0x03]), ocrText: "Invoice total 42 dollars"),
            ocrState: .completed(Date())
        )

        let preview = item.visualPreview

        XCTAssertEqual(preview.headline, "Screenshot")
        XCTAssertEqual(preview.body, "Invoice total 42 dollars")
        XCTAssertEqual(preview.detail, "OCR complete")
        XCTAssertTrue(preview.prefersImageThumbnail)
    }

    func testMixedPreviewSummarizesContainedTypes() {
        let item = ClipboardItem(
            sourceAppName: "Pages",
            deviceName: "Test Mac",
            contentType: .mixed,
            title: "Launch Pack",
            payload: ClipboardPayload(
                text: "Launch plan",
                urlString: "https://example.com",
                fileURLString: "file:///Users/alex/Desktop/logo.png",
                imageData: Data([0x04])
            )
        )

        let preview = item.visualPreview

        XCTAssertEqual(preview.headline, "Launch Pack")
        XCTAssertEqual(preview.body, "Launch plan https://example.com file:///Users/alex/Desktop/logo.png")
        XCTAssertEqual(preview.detail, "text, link, 1 file, image")
        XCTAssertEqual(preview.badgeText, "Mixed")
        XCTAssertTrue(preview.prefersImageThumbnail)
    }
}
