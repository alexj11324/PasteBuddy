#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import Foundation
import ImageIO
import Vision
#if canImport(VisionKit)
import VisionKit
#endif

public enum OCRServiceError: LocalizedError {
    case unreadableImage
    case missingCGImage

    public var errorDescription: String? {
        switch self {
        case .unreadableImage:
            "The image data could not be read."
        case .missingCGImage:
            "The image could not be converted for OCR."
        }
    }
}

public struct OCRService: Sendable {
    static let preferredRecognitionLanguageIdentifiers = ["zh-Hans", "zh-Hant", "en-US"]

    public init() {}

    public func recognizeText(in imageData: Data) async throws -> String {
        try await Task.detached(priority: .utility) {
            let cgImage = try Self.makeCGImage(from: imageData)

            #if canImport(VisionKit)
            if let liveText = try? await Self.recognizeTextWithLiveText(in: cgImage),
               !liveText.isEmpty {
                return liveText
            }
            #endif

            if #available(macOS 15.0, iOS 18.0, tvOS 18.0, *) {
                return try await Self.recognizeTextWithModernVision(in: cgImage)
            }
            return try Self.recognizeTextWithVNRecognizeTextRequest(in: cgImage)
        }.value
    }

    #if canImport(VisionKit)
    private static func recognizeTextWithLiveText(in cgImage: CGImage) async throws -> String? {
        guard ImageAnalyzer.isSupported else { return nil }

        var configuration = ImageAnalyzer.Configuration(.text)
        configuration.locales = preferredLiveTextLocales(
            from: ImageAnalyzer.supportedTextRecognitionLanguages
        )
        let analysis = try await ImageAnalyzer().analyze(
            cgImage,
            orientation: .up,
            configuration: configuration
        )
        let transcript = sanitizedRecognizedTranscript(analysis.transcript)
        return transcript.isEmpty ? nil : transcript
    }

    static func preferredLiveTextLocales(from supportedLocales: [String]) -> [String] {
        let supported = Set(supportedLocales)
        return preferredRecognitionLanguageIdentifiers.filter { supported.contains($0) }
    }
    #endif

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, *)
    private static func recognizeTextWithModernVision(in cgImage: CGImage) async throws -> String {
        var request = RecognizeTextRequest(.revision3)
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = false
        request.recognitionLanguages = preferredLocaleLanguages.filter {
            request.supportedRecognitionLanguages.contains($0)
        }

        let observations = try await request.perform(on: cgImage)
        return joinedRecognizedLines(observations.compactMap { observation in
            preferredRecognizedText(from: observation.topCandidates(3).map(\.string))
        })
    }

    private static func recognizeTextWithVNRecognizeTextRequest(in cgImage: CGImage) throws -> String {
        let request = try configuredVNRecognizeTextRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        let lines = request.results?.compactMap { observation in
            preferredRecognizedText(from: observation.topCandidates(3).map(\.string))
        } ?? []
        return joinedRecognizedLines(lines)
    }

    static func configuredVNRecognizeTextRequest() throws -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequest.currentRevision
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if #available(macOS 13.0, iOS 16.0, tvOS 16.0, *) {
            request.automaticallyDetectsLanguage = false
        }
        let supportedLanguages = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = preferredRecognitionLanguageIdentifiers.filter {
            supportedLanguages.contains($0)
        }
        return request
    }

    private static var preferredLocaleLanguages: [Locale.Language] {
        preferredRecognitionLanguageIdentifiers.map { Locale.Language(identifier: $0) }
    }

    static func preferredRecognizedText(from candidates: [String]) -> String? {
        candidates
            .compactMap { candidate -> (text: String, retainedRatio: Double)? in
                guard let sanitized = sanitizedRecognizedLine(candidate) else {
                    return nil
                }
                let originalCount = candidate.unicodeScalars.filter { !$0.properties.isWhitespace }.count
                let retainedCount = sanitized.unicodeScalars.filter { !$0.properties.isWhitespace }.count
                let ratio = originalCount == 0 ? 0 : Double(retainedCount) / Double(originalCount)
                return (sanitized, ratio)
            }
            .max { lhs, rhs in
                if lhs.retainedRatio == rhs.retainedRatio {
                    return lhs.text.count < rhs.text.count
                }
                return lhs.retainedRatio < rhs.retainedRatio
            }?
            .text
    }

    static func sanitizedRecognizedLine(_ line: String) -> String? {
        var scalars = String.UnicodeScalarView()
        for scalar in line.unicodeScalars where isAllowedOCRScalar(scalar) {
            scalars.append(scalar)
        }
        let sanitized = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty,
              sanitized.unicodeScalars.contains(where: isPreferredContentScalar)
        else {
            return nil
        }
        return sanitized
    }

    static func sanitizedRecognizedTranscript(_ transcript: String) -> String {
        joinedRecognizedLines(
            transcript
                .components(separatedBy: .newlines)
                .compactMap(sanitizedRecognizedLine)
        )
    }

    private static func joinedRecognizedLines(_ lines: [String]) -> String {
        lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func isAllowedOCRScalar(_ scalar: Unicode.Scalar) -> Bool {
        if isPreferredContentScalar(scalar) || scalar.properties.isWhitespace {
            return true
        }
        if isCJKPunctuation(scalar) || isFullwidthASCIIScalar(scalar) {
            return true
        }
        switch scalar.properties.generalCategory {
        case .dashPunctuation,
             .openPunctuation,
             .closePunctuation,
             .initialPunctuation,
             .finalPunctuation,
             .connectorPunctuation,
             .otherPunctuation,
             .mathSymbol,
             .currencySymbol:
            return true
        default:
            return false
        }
    }

    private static func isPreferredContentScalar(_ scalar: Unicode.Scalar) -> Bool {
        isASCIIAlphanumeric(scalar) || isCJKIdeograph(scalar) || isFullwidthAlphanumeric(scalar)
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        (0x30...0x39).contains(scalar.value)
            || (0x41...0x5A).contains(scalar.value)
            || (0x61...0x7A).contains(scalar.value)
    }

    private static func isFullwidthAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        (0xFF10...0xFF19).contains(scalar.value)
            || (0xFF21...0xFF3A).contains(scalar.value)
            || (0xFF41...0xFF5A).contains(scalar.value)
    }

    private static func isFullwidthASCIIScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0xFF01...0xFF5E).contains(scalar.value)
            || (0xFFE0...0xFFE6).contains(scalar.value)
    }

    private static func isCJKPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        (0x3000...0x303F).contains(scalar.value)
    }

    private static func isCJKIdeograph(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x4DBF).contains(scalar.value)
            || (0x4E00...0x9FFF).contains(scalar.value)
            || (0xF900...0xFAFF).contains(scalar.value)
            || (0x20000...0x2EBEF).contains(scalar.value)
            || (0x30000...0x323AF).contains(scalar.value)
    }

    private static func makeCGImage(from imageData: Data) throws -> CGImage {
        #if os(macOS)
        guard let image = NSImage(data: imageData) else {
            throw OCRServiceError.unreadableImage
        }
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw OCRServiceError.missingCGImage
        }
        return cgImage
        #elseif canImport(UIKit)
        guard let image = UIImage(data: imageData) else {
            throw OCRServiceError.unreadableImage
        }
        guard let cgImage = image.cgImage else {
            throw OCRServiceError.missingCGImage
        }
        return cgImage
        #else
        throw OCRServiceError.unreadableImage
        #endif
    }
}
