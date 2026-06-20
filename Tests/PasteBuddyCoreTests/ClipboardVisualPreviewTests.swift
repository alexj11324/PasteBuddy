import XCTest
@testable import PasteBuddyCore

final class ClipboardVisualPreviewTests: XCTestCase {
    func testSearchDocumentPrecomputesNormalizedTextPreviewBytesAndDedupeHash() {
        let rtf = Data("{\\rtf1\\ansi Launch body}".utf8)
        let item = ClipboardItem(
            sourceAppName: "Pages",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Résumé Template",
            labels: ["VIP Client"],
            payload: ClipboardPayload(
                htmlString: "<p>Résumé <strong>Launch</strong></p>",
                rtfData: rtf
            )
        )

        XCTAssertTrue(item.matches("resume launch"))
        XCTAssertTrue(item.searchDocument.normalizedText.contains("vip client"))
        XCTAssertTrue(item.visualPreview.body.contains("Launch"))
        XCTAssertEqual(
            item.searchDocument.storageBytes,
            ClipboardItem.estimatedStorageBytes(
                title: item.title,
                labels: item.labels,
                sourceAppName: item.sourceAppName,
                deviceName: item.deviceName,
                contentType: item.contentType,
                reuseCategory: item.reuseCategory,
                payload: item.payload
            )
        )
        XCTAssertEqual(
            item.searchDocument.dedupeHash,
            ClipboardItem.deduplicationHash(contentType: item.contentType, payload: item.payload)
        )
        XCTAssertEqual(item.searchDocument.dedupeHash, item.searchDocument.contentHash)
        XCTAssertFalse(item.searchDocument.searchHash.isEmpty)
    }

    func testContentHashIgnoresOCRAndSearchOnlyMetadataWhileSearchHashTracksOCR() {
        let imageData = Data([0x01, 0x02, 0x03, 0x04])
        let pending = ClipboardItem(
            sourceAppName: "Screenshot",
            deviceName: "Test Mac",
            contentType: .image,
            title: "Pending OCR",
            labels: ["Inbox"],
            reuseCategory: .asset,
            payload: ClipboardPayload(imageData: imageData),
            ocrState: .pending(Date(timeIntervalSince1970: 100))
        )
        let completed = ClipboardItem(
            sourceAppName: "Preview",
            deviceName: "Alex iPhone",
            contentType: .image,
            title: "Receipt",
            labels: ["Finance"],
            reuseCategory: .general,
            payload: ClipboardPayload(imageData: imageData, ocrText: "Receipt total 42 dollars"),
            ocrState: .completed(Date(timeIntervalSince1970: 200))
        )

        XCTAssertEqual(pending.searchDocument.contentHash, completed.searchDocument.contentHash)
        XCTAssertEqual(pending.searchDocument.dedupeHash, pending.searchDocument.contentHash)
        XCTAssertNotEqual(pending.searchDocument.searchHash, completed.searchDocument.searchHash)
        XCTAssertTrue(completed.searchDocument.normalizedText.contains("receipt total"))
    }

    func testLegacyDecodedItemRebuildsMissingSearchDocument() throws {
        let legacyJSON = Data("""
        {
          "sourceAppName": "Notes",
          "deviceName": "Test Mac",
          "contentType": "text",
          "title": "Legacy Note",
          "labels": ["Archive"],
          "payload": {
            "text": "Legacy searchable body"
          }
        }
        """.utf8)

        let item = try JSONDecoder().decode(ClipboardItem.self, from: legacyJSON)

        XCTAssertTrue(item.matches("legacy searchable"))
        XCTAssertTrue(item.matches("archive"))
        XCTAssertEqual(item.visualPreview.headline, "Legacy Note")
        XCTAssertEqual(item.visualPreview.body, "Legacy searchable body")
        XCTAssertGreaterThan(item.searchDocument.storageBytes, "Legacy searchable body".utf8.count)
        XCTAssertFalse(item.searchDocument.dedupeHash.isEmpty)
    }

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

    func testWholeTextURLPresentsAsLinkPreview() {
        let item = ClipboardItem(
            sourceAppName: "Brave Browser",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Copied URL",
            payload: ClipboardPayload(text: "https://github.com/hypooo/app-store-price")
        )

        let preview = item.visualPreview

        XCTAssertEqual(item.presentationContentType, .url)
        XCTAssertEqual(preview.headline, "github.com")
        XCTAssertEqual(preview.body, "https://github.com/hypooo/app-store-price")
        XCTAssertEqual(preview.detail, "Link")
        XCTAssertEqual(preview.badgeText, "Link")
        XCTAssertEqual(preview.systemImageName, "link")
        XCTAssertEqual(item.openableURL?.absoluteString, "https://github.com/hypooo/app-store-price")
    }

    func testStandaloneWWWTextPresentsAsNormalizedLinkPreview() {
        let item = ClipboardItem(
            sourceAppName: "Brave Browser",
            deviceName: "Test Mac",
            contentType: .text,
            title: "Copied URL",
            payload: ClipboardPayload(text: "www.example.com/research")
        )

        let preview = item.visualPreview

        XCTAssertEqual(item.presentationContentType, .url)
        XCTAssertEqual(preview.headline, "www.example.com")
        XCTAssertEqual(preview.body, "https://www.example.com/research")
        XCTAssertEqual(preview.detail, "Link")
        XCTAssertEqual(preview.badgeText, "Link")
        XCTAssertEqual(preview.systemImageName, "link")
        XCTAssertEqual(item.openableURL?.absoluteString, "https://www.example.com/research")
    }

    func testMixedTextOnlyURLPresentsAsLinkPreview() {
        let item = ClipboardItem(
            sourceAppName: "Brave Browser",
            deviceName: "Test Mac",
            contentType: .mixed,
            title: "https://github.com/hypooo/app-store-price",
            payload: ClipboardPayload(text: "https://github.com/hypooo/app-store-price")
        )

        let preview = item.visualPreview

        XCTAssertEqual(item.presentationContentType, .url)
        XCTAssertEqual(preview.headline, "github.com")
        XCTAssertEqual(preview.body, "https://github.com/hypooo/app-store-price")
        XCTAssertEqual(preview.detail, "Link")
        XCTAssertEqual(preview.badgeText, "Link")
        XCTAssertEqual(preview.systemImageName, "link")
        XCTAssertEqual(item.openableURL?.absoluteString, "https://github.com/hypooo/app-store-price")
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

    func testMixedImagePayloadPresentsAsImagePreview() {
        let item = ClipboardItem(
            sourceAppName: "PixPin",
            deviceName: "Test Mac",
            contentType: .mixed,
            title: "Screenshot with metadata",
            payload: ClipboardPayload(
                text: "Screenshot metadata",
                imageData: Data([0x09, 0x08, 0x07]),
                ocrText: "Screenshot OCR"
            ),
            ocrState: .completed(Date())
        )

        let preview = item.visualPreview

        XCTAssertEqual(item.presentationContentType, .image)
        XCTAssertEqual(preview.badgeText, "Image")
        XCTAssertEqual(preview.systemImageName, "photo")
        XCTAssertTrue(preview.prefersImageThumbnail)
    }

    func testMixedPreviewWithImageAndFilePrefersImagePresentation() {
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

        XCTAssertEqual(item.presentationContentType, .image)
        XCTAssertEqual(preview.headline, "Launch Pack")
        XCTAssertEqual(preview.body, "Launch plan https://example.com file:///Users/alex/Desktop/logo.png")
        XCTAssertEqual(preview.detail, "Not needed")
        XCTAssertEqual(preview.badgeText, "Image")
        XCTAssertEqual(preview.systemImageName, "photo")
        XCTAssertTrue(preview.prefersImageThumbnail)
    }
}
