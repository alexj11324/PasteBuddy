import XCTest
import Vision
@testable import PasteBuddyCore

final class OCRServiceTests: XCTestCase {
    func testConfiguredVNRecognizeTextRequestUsesCurrentRevisionAndChineseEnglishOnly() throws {
        let request = try OCRService.configuredVNRecognizeTextRequest()
        let supportedLanguages = try request.supportedRecognitionLanguages()
        let expectedLanguages = OCRService.preferredRecognitionLanguageIdentifiers.filter {
            supportedLanguages.contains($0)
        }

        XCTAssertEqual(request.revision, VNRecognizeTextRequest.currentRevision)
        XCTAssertEqual(request.recognitionLevel, .accurate)
        XCTAssertTrue(request.usesLanguageCorrection)
        if #available(macOS 13.0, iOS 16.0, tvOS 16.0, *) {
            XCTAssertFalse(request.automaticallyDetectsLanguage)
        }
        XCTAssertEqual(request.recognitionLanguages, expectedLanguages)
        XCTAssertFalse(request.recognitionLanguages.contains("ja-JP"))
        XCTAssertFalse(request.recognitionLanguages.contains("ko-KR"))
        XCTAssertFalse(request.recognitionLanguages.contains("ru-RU"))
    }

    func testPreferredLiveTextLocalesFiltersToChineseAndEnglishInPriorityOrder() {
        #if canImport(VisionKit)
        let locales = OCRService.preferredLiveTextLocales(
            from: ["ja-JP", "en-US", "zh-Hant", "ko-KR", "zh-Hans", "ru-RU"]
        )

        XCTAssertEqual(locales, ["zh-Hans", "zh-Hant", "en-US"])
        #endif
    }

    func testOCRSanitizerDropsNonChineseEnglishScriptsFromCandidates() {
        XCTAssertEqual(
            OCRService.sanitizedRecognizedTranscript("预览 Preview\nカメラ\n相册 Photos 한글\nВерсия 1.2"),
            "预览 Preview\n相册 Photos\n1.2"
        )
        XCTAssertEqual(
            OCRService.preferredRecognizedText(from: ["H\u{0435}llo 版本", "Hello 版本"]),
            "Hello 版本"
        )
        XCTAssertNil(OCRService.sanitizedRecognizedLine("カメラ 한글"))
    }
}
