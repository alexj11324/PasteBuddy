import Foundation

public enum SemanticInferenceSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case pasteBuddyCloud = "pastebuddy_cloud"
    case byok
    public var id: String { rawValue }
}

public enum BYOKProviderPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case openAI = "openai"
    case gemini
    case openAICompatible = "openai_compatible"
    public var id: String { rawValue }
}

public struct BYOKProviderConfiguration: Codable, Equatable, Sendable {
    public var preset: BYOKProviderPreset
    public var baseURL: String
    public var documentModel: String
    public var embeddingModel: String
    public var organizationID: String
    public var projectID: String

    public init(
        preset: BYOKProviderPreset = .openAI,
        baseURL: String = "https://api.openai.com/v1",
        documentModel: String = "gpt-4.1-mini",
        embeddingModel: String = "text-embedding-3-small",
        organizationID: String = "",
        projectID: String = ""
    ) {
        self.preset = preset
        self.baseURL = baseURL
        self.documentModel = documentModel
        self.embeddingModel = embeddingModel
        self.organizationID = organizationID
        self.projectID = projectID
    }

    public static func defaults(for preset: BYOKProviderPreset) -> Self {
        switch preset {
        case .openAI:
            Self()
        case .gemini:
            Self(
                preset: .gemini,
                baseURL: "https://generativelanguage.googleapis.com/v1beta",
                documentModel: "gemini-2.5-flash",
                embeddingModel: "gemini-embedding-001"
            )
        case .openAICompatible:
            Self(preset: .openAICompatible, baseURL: "", documentModel: "", embeddingModel: "")
        }
    }
}

public struct SemanticIndexConfiguration: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var isPaused: Bool
    public var gatewayBaseURL: String
    public var inferenceSource: SemanticInferenceSource
    public var byok: BYOKProviderConfiguration

    public init(
        isEnabled: Bool = false,
        isPaused: Bool = false,
        gatewayBaseURL: String = "https://ai.nebula-spaces.com",
        inferenceSource: SemanticInferenceSource = .pasteBuddyCloud,
        byok: BYOKProviderConfiguration = BYOKProviderConfiguration()
    ) {
        self.isEnabled = isEnabled
        self.isPaused = isPaused
        self.gatewayBaseURL = gatewayBaseURL
        self.inferenceSource = inferenceSource
        self.byok = byok
    }

    private enum CodingKeys: String, CodingKey { case isEnabled, isPaused, gatewayBaseURL, inferenceSource, byok }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
        gatewayBaseURL = try container.decodeIfPresent(String.self, forKey: .gatewayBaseURL) ?? "https://ai.nebula-spaces.com"
        inferenceSource = try container.decodeIfPresent(SemanticInferenceSource.self, forKey: .inferenceSource) ?? .pasteBuddyCloud
        byok = try container.decodeIfPresent(BYOKProviderConfiguration.self, forKey: .byok) ?? BYOKProviderConfiguration()
    }
}

public enum AIProviderConnectionState: Equatable, Sendable {
    case idle
    case testing
    case succeeded
    case failed(String)
}

public enum SemanticIndexState: String, CaseIterable, Codable, Sendable {
    case queued
    case indexing
    case ready
    case failed
    case excluded
}

public enum SemanticIndexModality: String, CaseIterable, Codable, Sendable {
    case text
    case image
    case fileMetadata = "file_metadata"
    case mixed
}

public struct SemanticFileMetadata: Codable, Equatable, Sendable {
    public var name: String
    public var contentType: String?
    public var byteCount: Int?
    public var textContent: String?

    public init(name: String, contentType: String? = nil, byteCount: Int? = nil, textContent: String? = nil) {
        self.name = name
        self.contentType = contentType
        self.byteCount = byteCount
        self.textContent = textContent
    }
}

public struct SemanticIndexSource: Codable, Equatable, Sendable {
    public var itemID: UUID
    public var contentHash: String
    public var capturedAt: Date
    public var sourceApplicationName: String
    public var sourceBundleIdentifier: String?
    public var contentType: ClipboardContentType
    public var text: String
    public var imageDataBase64: String?
    public var imageMediaType: String?
    public var existingOCRText: String?
    public var files: [SemanticFileMetadata]

    public init(
        itemID: UUID,
        contentHash: String,
        capturedAt: Date,
        sourceApplicationName: String,
        sourceBundleIdentifier: String?,
        contentType: ClipboardContentType,
        text: String,
        imageDataBase64: String? = nil,
        imageMediaType: String? = nil,
        existingOCRText: String? = nil,
        files: [SemanticFileMetadata] = []
    ) {
        self.itemID = itemID
        self.contentHash = contentHash
        self.capturedAt = capturedAt
        self.sourceApplicationName = sourceApplicationName
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.contentType = contentType
        self.text = text
        self.imageDataBase64 = imageDataBase64
        self.imageMediaType = imageMediaType
        self.existingOCRText = existingOCRText
        self.files = files
    }
}

public struct SemanticIndexDocument: Codable, Equatable, Sendable {
    public var itemID: UUID
    public var contentHash: String
    public var modality: SemanticIndexModality
    public var summary: String
    public var keywords: [String]
    public var aliases: [String]
    public var entities: [String]
    public var visualTextHints: [String]
    public var searchIntents: [String]
    public var language: String?
    public var modelName: String
    public var promptVersion: String
    public var indexedAt: Date

    public init(
        itemID: UUID,
        contentHash: String,
        modality: SemanticIndexModality,
        summary: String,
        keywords: [String] = [],
        aliases: [String] = [],
        entities: [String] = [],
        visualTextHints: [String] = [],
        searchIntents: [String] = [],
        language: String? = nil,
        modelName: String,
        promptVersion: String,
        indexedAt: Date = Date()
    ) {
        self.itemID = itemID
        self.contentHash = contentHash
        self.modality = modality
        self.summary = summary
        self.keywords = keywords
        self.aliases = aliases
        self.entities = entities
        self.visualTextHints = visualTextHints
        self.searchIntents = searchIntents
        self.language = language
        self.modelName = modelName
        self.promptVersion = promptVersion
        self.indexedAt = indexedAt
    }

    public var embeddingText: String {
        ([summary] + keywords + aliases + entities + visualTextHints + searchIntents)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

public struct SemanticEmbeddingInput: Codable, Equatable, Sendable {
    public var id: UUID
    public var text: String

    public init(id: UUID, text: String) {
        self.id = id
        self.text = text
    }
}

public struct SemanticEmbedding: Codable, Equatable, Sendable {
    public var id: UUID
    public var modelName: String
    public var values: [Float]

    public init(id: UUID, modelName: String, values: [Float]) {
        self.id = id
        self.modelName = modelName
        self.values = values
    }
}

public struct SemanticIndexStatistics: Codable, Equatable, Sendable {
    public var totalEligible: Int
    public var ready: Int
    public var queued: Int
    public var failed: Int
    public var suppressed: Int

    public init(totalEligible: Int = 0, ready: Int = 0, queued: Int = 0, failed: Int = 0, suppressed: Int = 0) {
        self.totalEligible = totalEligible
        self.ready = ready
        self.queued = queued
        self.failed = failed
        self.suppressed = suppressed
    }
}

public struct SemanticSearchRequest: Equatable, Sendable {
    public var query: String
    public var contentType: ClipboardContentType?
    public var sourceAppName: String?
    public var deviceName: String?
    public var dateFilter: ClipboardDateFilter
    public var pinboardID: UUID?
    public var limit: Int

    public init(
        query: String,
        contentType: ClipboardContentType? = nil,
        sourceAppName: String? = nil,
        deviceName: String? = nil,
        dateFilter: ClipboardDateFilter = .any,
        pinboardID: UUID? = nil,
        limit: Int = 100
    ) {
        self.query = query
        self.contentType = contentType
        self.sourceAppName = sourceAppName
        self.deviceName = deviceName
        self.dateFilter = dateFilter
        self.pinboardID = pinboardID
        self.limit = min(max(limit, 1), 500)
    }
}

public struct SemanticSearchHit: Codable, Equatable, Sendable {
    public var itemID: UUID
    public var fusedScore: Double
    public var semanticScore: Double?
    public var lexicalRank: Int?

    public init(itemID: UUID, fusedScore: Double, semanticScore: Double? = nil, lexicalRank: Int? = nil) {
        self.itemID = itemID
        self.fusedScore = fusedScore
        self.semanticScore = semanticScore
        self.lexicalRank = lexicalRank
    }
}

public enum SemanticSearchState: Equatable, Sendable {
    case idle
    case loading
    case applied(query: String)
    case failed(String)
}

public enum SemanticIndexError: LocalizedError, Equatable {
    case disabled
    case paused
    case entitlementRequired
    case providerConfigurationRequired
    case emptySource
    case sensitiveSource
    case notFound
    case malformedProviderResponse
    case gatewayFailure(String)

    public var errorDescription: String? {
        switch self {
        case .disabled:
            PasteBuddyLocalization.string("message.ai_search_disabled", defaultValue: "AI Search is disabled.")
        case .paused:
            PasteBuddyLocalization.string("message.ai_index_paused", defaultValue: "AI indexing is paused.")
        case .entitlementRequired:
            PasteBuddyLocalization.string("message.ai_entitlement_required", defaultValue: "An active trial or purchase is required for AI Search.")
        case .providerConfigurationRequired:
            PasteBuddyLocalization.string("message.ai_provider_configuration_required", defaultValue: "Choose an available AI provider and finish its configuration first.")
        case .emptySource:
            PasteBuddyLocalization.string("message.ai_empty_source", defaultValue: "This item has no supported content to index.")
        case .sensitiveSource:
            PasteBuddyLocalization.string("message.ai_sensitive_source", defaultValue: "PasteBuddy will not send sensitive content for AI indexing.")
        case .notFound:
            PasteBuddyLocalization.string("message.ai_index_not_found", defaultValue: "The AI index entry could not be found.")
        case .malformedProviderResponse:
            PasteBuddyLocalization.string("message.ai_provider_response", defaultValue: "The AI service returned an invalid response.")
        case .gatewayFailure(let detail):
            detail
        }
    }
}
