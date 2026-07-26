import XCTest
import Vision
@testable import PasteBuddyCore

final class OCRServiceTests: XCTestCase {
    func testConfiguredVNRecognizeTextRequestUsesCurrentRevisionAndSystemSupportedLanguages() throws {
        let request = try OCRService.configuredVNRecognizeTextRequest()
        let supportedLanguages = try request.supportedRecognitionLanguages()
        let expectedLanguages = OCRService.recognitionLanguageIdentifiers(from: supportedLanguages)

        XCTAssertEqual(request.revision, VNRecognizeTextRequest.currentRevision)
        XCTAssertEqual(request.recognitionLevel, .accurate)
        XCTAssertTrue(request.usesLanguageCorrection)
        if #available(macOS 13.0, iOS 16.0, tvOS 16.0, *) {
            XCTAssertTrue(request.automaticallyDetectsLanguage)
        }
        XCTAssertEqual(request.recognitionLanguages, expectedLanguages)
    }

    func testRecognitionLanguagesPreferSystemLocalesAndDeduplicateLanguageFamilies() {
        XCTAssertEqual(
            OCRService.recognitionLanguageIdentifiers(
                from: ["en-US", "zh-Hans", "ja-JP", "fr-FR"],
                preferredLanguages: ["ja-JP", "fr-CA", "ja"]
            ),
            ["ja-JP", "fr-FR", "zh-Hans", "en-US"]
        )
    }

    func testPreferredLiveTextLocalesUseSystemLanguagesWithFallbacks() {
        #if canImport(VisionKit)
        let locales = OCRService.preferredLiveTextLocales(
            from: ["ja-JP", "en-US", "zh-Hant", "ko-KR", "zh-Hans", "ru-RU"]
        )

        XCTAssertFalse(locales.isEmpty)
        XCTAssertTrue(Set(locales).isSubset(of: [
            "ja-JP", "en-US", "zh-Hant", "ko-KR", "zh-Hans", "ru-RU"
        ]))
        #endif
    }

    func testOCRSanitizerRetainsMultilingualSystemText() {
        XCTAssertEqual(
            OCRService.sanitizedRecognizedTranscript("预览 Preview\nカメラ\n相册 Photos 한글\nВерсия 1.2"),
            "预览 Preview\nカメラ\n相册 Photos 한글\nВерсия 1.2"
        )
        XCTAssertEqual(
            OCRService.preferredRecognizedText(from: ["H\u{0435}llo 版本", "Hello 版本"]),
            "H\u{0435}llo 版本"
        )
        XCTAssertEqual(OCRService.sanitizedRecognizedLine("カメラ 한글"), "カメラ 한글")
    }

    func testStructuredAnalysisModelsExposeTranscriptAndSafeBarcodeURL() {
        let analysis = OCRAnalysis(
            textObservations: [
                OCRTextObservation(
                    text: "Hello",
                    normalizedBoundingBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1)
                ),
                OCRTextObservation(
                    text: "世界",
                    normalizedBoundingBox: CGRect(x: 0.1, y: 0.05, width: 0.2, height: 0.1)
                ),
            ],
            barcodes: [
                OCRBarcodeObservation(
                    payload: "https://example.com",
                    symbology: "QR",
                    normalizedBoundingBox: .zero
                ),
                OCRBarcodeObservation(
                    payload: "javascript:alert(1)",
                    symbology: "QR",
                    normalizedBoundingBox: .zero
                ),
            ],
            supportedRecognitionLanguages: ["en-US", "zh-Hans"]
        )

        XCTAssertEqual(analysis.transcript, "Hello\n世界")
        XCTAssertEqual(analysis.barcodes[0].url?.absoluteString, "https://example.com")
        XCTAssertNil(analysis.barcodes[1].url)
    }
}
