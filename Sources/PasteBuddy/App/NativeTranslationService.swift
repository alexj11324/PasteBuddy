import Foundation
import NaturalLanguage
#if canImport(Translation)
import Translation
#endif

enum NativeTranslationServiceError: LocalizedError {
    case unavailable
    case emptyText
    case unableToDetectLanguage
    case unsupportedPair

    var errorDescription: String? {
        switch self {
        case .unavailable:
            NSLocalizedString("message.native_translation_is_unavailable_on_this_version", comment: "")
        case .emptyText:
            NSLocalizedString("message.there_is_no_text_to_translate", comment: "")
        case .unableToDetectLanguage:
            NSLocalizedString("message.the_source_language_could_not_be_detected", comment: "")
        case .unsupportedPair:
            NSLocalizedString("message.this_language_pair_is_not_supported_by", comment: "")
        }
    }
}
struct NativeTranslationResult: Equatable, Sendable {
    var sourceLanguageIdentifier: String
    var targetLanguageIdentifier: String
    var sourceText: String
    var translatedText: String
}

struct NativeTranslationService: Sendable {
    static let commonTargetLanguageIdentifiers = [
        "zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "es", "it", "pt"
    ]

    func detectedLanguageIdentifier(for text: String) -> String? {
        NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
    }

    func translate(
        _ text: String,
        sourceLanguageIdentifier: String? = nil,
        targetLanguageIdentifier: String
    ) async throws -> NativeTranslationResult {
        let sourceText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty else {
            throw NativeTranslationServiceError.emptyText
        }
        guard #available(macOS 26.0, *) else {
            throw NativeTranslationServiceError.unavailable
        }
        #if canImport(Translation)
        guard let detectedSource = sourceLanguageIdentifier
            ?? detectedLanguageIdentifier(for: sourceText) else {
            throw NativeTranslationServiceError.unableToDetectLanguage
        }
        let source = Locale.Language(identifier: detectedSource)
        let target = Locale.Language(identifier: targetLanguageIdentifier)
        let availability = LanguageAvailability()
        guard await availability.status(from: source, to: target) != .unsupported else {
            throw NativeTranslationServiceError.unsupportedPair
        }
        let session = TranslationSession(installedSource: source, target: target)
        try await session.prepareTranslation()
        let response = try await session.translate(sourceText)
        return NativeTranslationResult(
            sourceLanguageIdentifier: response.sourceLanguage.minimalIdentifier,
            targetLanguageIdentifier: response.targetLanguage.minimalIdentifier,
            sourceText: response.sourceText,
            translatedText: response.targetText
        )
        #else
        throw NativeTranslationServiceError.unavailable
        #endif
    }
}
