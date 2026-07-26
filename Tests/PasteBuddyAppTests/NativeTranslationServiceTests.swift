import XCTest
@testable import PasteBuddy

final class NativeTranslationServiceTests: XCTestCase {
    func testLanguageDetectionAndSupportedTargetListAreDeterministic() {
        let service = NativeTranslationService()

        XCTAssertEqual(service.detectedLanguageIdentifier(for: "This is an English sentence."), "en")
        XCTAssertTrue(NativeTranslationService.commonTargetLanguageIdentifiers.contains("zh-Hans"))
        XCTAssertTrue(NativeTranslationService.commonTargetLanguageIdentifiers.contains("en"))
        XCTAssertEqual(
            Set(NativeTranslationService.commonTargetLanguageIdentifiers).count,
            NativeTranslationService.commonTargetLanguageIdentifiers.count
        )
    }

    func testEmptyTranslationFailsBeforeAvailabilityOrDownloadChecks() async {
        do {
            _ = try await NativeTranslationService().translate(
                " \n ",
                targetLanguageIdentifier: "en"
            )
            XCTFail("Expected empty input to fail")
        } catch let error as NativeTranslationServiceError {
            guard case .emptyText = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
