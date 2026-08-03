import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
#if canImport(StoreKit)
import StoreKit
#endif

public protocol SemanticDocumentGenerating: Sendable {
    func generate(from source: SemanticIndexSource) async throws -> SemanticIndexDocument
}

public protocol SemanticEmbeddingProviding: Sendable {
    func embedDocuments(_ inputs: [SemanticEmbeddingInput]) async throws -> [SemanticEmbedding]
    func embedQuery(_ query: String) async throws -> SemanticEmbedding
}

public protocol SemanticGatewayTokenProviding: Sendable {
    func accessToken() async throws -> String?
}

public struct StaticSemanticGatewayTokenProvider: SemanticGatewayTokenProviding {
    private let token: String?

    public init(token: String?) {
        self.token = token
    }

    public func accessToken() async throws -> String? { token }
}

public actor AppStoreSemanticGatewayTokenProvider: SemanticGatewayTokenProviding {
    private let baseURL: URL
    private let session: URLSession
    private var cachedToken: String?
    private var expiresAt: Date?

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func accessToken() async throws -> String? {
        if let cachedToken, let expiresAt, expiresAt > Date().addingTimeInterval(30) {
            return cachedToken
        }
        #if canImport(StoreKit)
        let appVerification = try await AppTransaction.shared
        guard case .verified = appVerification else { throw SemanticIndexError.entitlementRequired }
        var entitlementJWS: [String] = []
        for await verification in Transaction.currentEntitlements {
            if case .verified = verification {
                entitlementJWS.append(verification.jwsRepresentation)
            }
        }
        var request = URLRequest(url: Self.endpoint(baseURL: baseURL, path: "v1/auth/storekit/exchange"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONEncoder.pasteBuddy.encode(StoreCredentialRequest(
            appTransactionJWS: appVerification.jwsRepresentation,
            entitlementTransactionJWS: entitlementJWS
        ))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let value = try? JSONDecoder.pasteBuddy.decode(StoreCredentialResponse.self, from: data),
              !value.accessToken.isEmpty else {
            throw SemanticIndexError.entitlementRequired
        }
        cachedToken = value.accessToken
        expiresAt = value.expiresAt
        return value.accessToken
        #else
        throw SemanticIndexError.entitlementRequired
        #endif
    }

    private struct StoreCredentialRequest: Codable {
        var appTransactionJWS: String
        var entitlementTransactionJWS: [String]
    }

    private struct StoreCredentialResponse: Codable {
        var accessToken: String
        var expiresAt: Date
    }

    private static func endpoint(baseURL: URL, path: String) -> URL {
        path.split(separator: "/").reduce(baseURL) { $0.appendingPathComponent(String($1)) }
    }
}

public enum SemanticIndexSourceNormalizer {
    private static let maximumTextBytes = 64 * 1024
    private static let maximumTextFileBytes = 256 * 1024
    private static let maximumFileCount = 100
    private static let maximumAggregateFileTextBytes = 512 * 1024
    private static let maximumImageBytes = 8 * 1024 * 1024
    private static let textFileExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "jsonl", "xml", "csv", "tsv", "log",
        "swift", "m", "mm", "h", "c", "cc", "cpp", "py", "js", "jsx", "ts", "tsx",
        "java", "kt", "rs", "go", "rb", "php", "sh", "zsh", "yaml", "yml", "toml",
        "ini", "sql", "css", "scss", "html", "htm"
    ]

    public static func source(from item: ClipboardItem, privacy: PrivacyConfiguration) throws -> SemanticIndexSource {
        let decision = privacy.captureDecision(
            for: item,
            sourceApplicationName: item.sourceAppName,
            sourceBundleIdentifier: item.sourceBundleIdentifier
        )
        guard decision.isAllowed else { throw SemanticIndexError.sensitiveSource }
        if let ocr = item.payload.ocrText, SensitiveContentDetector.isLikelySensitive(ocr) {
            throw SemanticIndexError.sensitiveSource
        }

        let text = boundedUTF8(
            [
                item.payload.text,
                item.payload.htmlString?.pasteBuddyPlainTextFromHTML,
                item.payload.urlString,
                item.presentationContentType == .image ? nil : item.payload.ocrText
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n"),
            maximumBytes: maximumTextBytes
        )
        guard !SensitiveContentDetector.isLikelySensitive(text) else {
            throw SemanticIndexError.sensitiveSource
        }

        let allFileURLStrings = item.payload.allFileURLStrings
        guard !allFileURLStrings.contains(where: { value in
            URL(string: value).map { SensitiveContentDetector.isLikelySensitive($0.lastPathComponent) } ?? false
        }) else {
            throw SemanticIndexError.sensitiveSource
        }
        var remainingFileTextBytes = maximumAggregateFileTextBytes
        let files = allFileURLStrings.prefix(maximumFileCount).compactMap { value in
            fileMetadata(value, remainingTextBytes: &remainingFileTextBytes)
        }
        let imageData = item.payload.imageData.flatMap(sanitizedImageData)
        guard !text.isEmpty || imageData != nil || !files.isEmpty else {
            throw SemanticIndexError.emptySource
        }
        return SemanticIndexSource(
            itemID: item.id,
            contentHash: item.searchDocument.contentHash,
            capturedAt: item.createdAt,
            sourceApplicationName: item.sourceAppName,
            sourceBundleIdentifier: item.sourceBundleIdentifier,
            contentType: item.contentType,
            text: text,
            imageDataBase64: imageData?.base64EncodedString(),
            imageMediaType: imageData == nil ? nil : "image/jpeg",
            existingOCRText: nil,
            files: files
        )
    }

    private static func sanitizedImageData(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        #if canImport(ImageIO) && canImport(UniformTypeIdentifiers)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 2048
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.84
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let encoded = output as Data
        return encoded.count <= maximumImageBytes ? encoded : nil
        #else
        return data.count <= maximumImageBytes ? data : nil
        #endif
    }

    private static func fileMetadata(_ value: String, remainingTextBytes: inout Int) -> SemanticFileMetadata? {
        guard let url = URL(string: value), url.isFileURL else { return nil }
        let name = url.lastPathComponent
        guard !SensitiveContentDetector.isLikelySensitive(name) else { return nil }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        let ext = url.pathExtension.lowercased()
        let mayReadText = textFileExtensions.contains(ext)
            && values?.isRegularFile == true
            && values?.isSymbolicLink != true
            && (values?.fileSize ?? maximumTextFileBytes + 1) <= maximumTextFileBytes
        var textContent: String?
        if mayReadText,
           remainingTextBytes > 0,
           let data = try? Data(contentsOf: url, options: .mappedIfSafe),
           data.count <= maximumTextFileBytes,
           let decoded = String(data: data, encoding: .utf8),
           !SensitiveContentDetector.isLikelySensitive(decoded) {
            textContent = boundedUTF8(decoded, maximumBytes: remainingTextBytes)
            remainingTextBytes -= textContent?.utf8.count ?? 0
        }
        #if canImport(UniformTypeIdentifiers)
        let contentType = UTType(filenameExtension: ext)?.identifier
        #else
        let contentType: String? = nil
        #endif
        return SemanticFileMetadata(
            name: name,
            contentType: contentType,
            byteCount: values?.fileSize,
            textContent: textContent
        )
    }

    private static func boundedUTF8(_ text: String, maximumBytes: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count > maximumBytes else { return trimmed }
        var bytes = 0
        var result = ""
        for scalar in trimmed.unicodeScalars {
            let count = String(scalar).utf8.count
            guard bytes + count <= maximumBytes else { break }
            bytes += count
            result.unicodeScalars.append(scalar)
        }
        return result
    }
}

public final class CloudSemanticIndexProvider: SemanticDocumentGenerating, SemanticEmbeddingProviding, @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let tokenProvider: any SemanticGatewayTokenProviding
    private let encoder = JSONEncoder.pasteBuddy
    private let decoder = JSONDecoder.pasteBuddy

    public init(
        baseURL: URL,
        session: URLSession = .shared,
        tokenProvider: any SemanticGatewayTokenProviding = StaticSemanticGatewayTokenProvider(token: nil)
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
    }

    public func generate(from source: SemanticIndexSource) async throws -> SemanticIndexDocument {
        let response: DocumentResponse = try await post(path: "v1/inference/semantic-document", body: DocumentRequest(source: source))
        guard response.document.itemID == source.itemID,
              response.document.contentHash == source.contentHash,
              response.document.promptVersion == SemanticIndexContract.promptVersion,
              !response.document.modelName.isEmpty,
              SemanticIndexContract.isValid(
                  summary: response.document.summary,
                  keywords: response.document.keywords,
                  aliases: response.document.aliases,
                  entities: response.document.entities,
                  visualTextHints: response.document.visualTextHints,
                  searchIntents: response.document.searchIntents,
                  language: response.document.language
              ) else {
            throw SemanticIndexError.malformedProviderResponse
        }
        return response.document
    }

    public func embedDocuments(_ inputs: [SemanticEmbeddingInput]) async throws -> [SemanticEmbedding] {
        let response: EmbeddingResponse = try await post(
            path: "v1/inference/embeddings/documents",
            body: EmbeddingRequest(inputs: inputs)
        )
        guard response.embeddings.count == inputs.count,
              Set(response.embeddings.map(\.id)) == Set(inputs.map(\.id)),
              Set(response.embeddings.map { $0.values.count }).count == 1,
              response.embeddings.allSatisfy({ !$0.values.isEmpty && $0.values.count <= 8192 && $0.values.allSatisfy { $0.isFinite } }) else {
            throw SemanticIndexError.malformedProviderResponse
        }
        return response.embeddings
    }

    public func embedQuery(_ query: String) async throws -> SemanticEmbedding {
        let response: QueryEmbeddingResponse = try await post(
            path: "v1/inference/embeddings/query",
            body: QueryEmbeddingRequest(query: query)
        )
        guard !response.embedding.values.isEmpty,
              response.embedding.values.count <= 8192,
              response.embedding.values.allSatisfy({ $0.isFinite }) else {
            throw SemanticIndexError.malformedProviderResponse
        }
        return response.embedding
    }

    private func post<Request: Encodable, Response: Decodable>(path: String, body: Request) async throws -> Response {
        let url = path.split(separator: "/").reduce(baseURL) { $0.appendingPathComponent(String($1)) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        if let token = try await tokenProvider.accessToken(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SemanticIndexError.malformedProviderResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 402 || http.statusCode == 403 {
                throw SemanticIndexError.entitlementRequired
            }
            throw SemanticIndexError.gatewayFailure(PasteBuddyLocalization.format(
                "message.ai_gateway_http_error",
                defaultValue: "AI gateway returned HTTP %d.",
                http.statusCode
            ))
        }
        guard let value = try? decoder.decode(Response.self, from: data) else {
            throw SemanticIndexError.malformedProviderResponse
        }
        return value
    }

    private struct DocumentRequest: Codable { var source: SemanticIndexSource }
    private struct DocumentResponse: Codable { var document: SemanticIndexDocument }
    private struct EmbeddingRequest: Codable { var inputs: [SemanticEmbeddingInput] }
    private struct EmbeddingResponse: Codable { var embeddings: [SemanticEmbedding] }
    private struct QueryEmbeddingRequest: Codable { var query: String }
    private struct QueryEmbeddingResponse: Codable { var embedding: SemanticEmbedding }
}

public actor SemanticIndexWorker {
    private let semanticRepository: SemanticIndexRepository
    private let clipboardRepository: ClipboardItemRepository
    private let documentProvider: any SemanticDocumentGenerating
    private let embeddingProvider: any SemanticEmbeddingProviding

    public init(
        semanticRepository: SemanticIndexRepository,
        clipboardRepository: ClipboardItemRepository,
        documentProvider: any SemanticDocumentGenerating,
        embeddingProvider: any SemanticEmbeddingProviding
    ) {
        self.semanticRepository = semanticRepository
        self.clipboardRepository = clipboardRepository
        self.documentProvider = documentProvider
        self.embeddingProvider = embeddingProvider
    }

    @discardableResult
    public func processNextBatch(privacy: PrivacyConfiguration, limit: Int = 2) async throws -> Int {
        let jobs = try semanticRepository.nextJobs(limit: limit)
        guard !jobs.isEmpty else { return 0 }
        let documents = try await withThrowingTaskGroup(of: (SemanticIndexJob, SemanticIndexDocument)?.self) { group in
            for job in jobs {
                group.addTask { [semanticRepository, clipboardRepository, documentProvider] in
                    do {
                        guard let item = try clipboardRepository.item(id: job.itemID) else {
                            try semanticRepository.discardStale(job: job)
                            return nil
                        }
                        guard item.searchDocument.contentHash == job.contentHash else {
                            try semanticRepository.discardStale(job: job)
                            return nil
                        }
                        let source = try SemanticIndexSourceNormalizer.source(from: item, privacy: privacy)
                        let document = try await documentProvider.generate(from: source)
                        return (job, document)
                    } catch SemanticIndexError.sensitiveSource {
                        try semanticRepository.discard(job: job, errorCode: "privacy_blocked")
                    } catch SemanticIndexError.emptySource {
                        try semanticRepository.discard(job: job, errorCode: "unsupported_content")
                    } catch {
                        try semanticRepository.markFailed(job: job, errorCode: Self.diagnosticCode(for: error))
                    }
                    return nil
                }
            }
            var values: [(SemanticIndexJob, SemanticIndexDocument)] = []
            for try await value in group {
                if let value { values.append(value) }
            }
            return values
        }
        guard !documents.isEmpty else { return jobs.count }
        let embeddings: [SemanticEmbedding]
        do {
            embeddings = try await embeddingProvider.embedDocuments(documents.map {
                SemanticEmbeddingInput(id: $0.1.itemID, text: $0.1.embeddingText)
            })
        } catch {
            for (job, _) in documents {
                try semanticRepository.markFailed(job: job, errorCode: Self.diagnosticCode(for: error))
            }
            return jobs.count
        }
        var embeddingByID: [UUID: SemanticEmbedding] = [:]
        for embedding in embeddings where embeddingByID[embedding.id] == nil {
            embeddingByID[embedding.id] = embedding
        }
        for (job, document) in documents {
            guard let embedding = embeddingByID[document.itemID] else {
                try semanticRepository.markFailed(job: job, errorCode: "embedding_missing")
                continue
            }
            do {
                try semanticRepository.commit(
                    document: document,
                    embedding: embedding,
                    jobID: job.id,
                    expectedGeneration: job.generation
                )
            } catch {
                try semanticRepository.markFailed(job: job, errorCode: Self.diagnosticCode(for: error))
            }
        }
        return jobs.count
    }

    private nonisolated static func diagnosticCode(for error: Error) -> String {
        if let semanticError = error as? SemanticIndexError {
            return "semantic_\(String(describing: semanticError))"
        }
        return String(reflecting: type(of: error))
    }
}
