import CryptoKit
import Foundation

public enum ClipboardContentType: String, CaseIterable, Codable, Identifiable, Sendable {
    case text
    case url
    case image
    case file
    case mixed

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .text: "Text"
        case .url: "Link"
        case .image: "Image"
        case .file: "File"
        case .mixed: "Mixed"
        }
    }

    public var systemImageName: String {
        switch self {
        case .text: "text.alignleft"
        case .url: "link"
        case .image: "photo"
        case .file: "doc"
        case .mixed: "square.stack.3d.up"
        }
    }
}

public enum SmartPinboardCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case text
    case links
    case images
    case files

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .text: "Text"
        case .links: "Links"
        case .images: "Images"
        case .files: "Files"
        }
    }

    public var pinboardName: String {
        "Smart: \(displayName)"
    }

    public var systemImageName: String {
        switch self {
        case .text: "text.alignleft"
        case .links: "link"
        case .images: "photo"
        case .files: "doc"
        }
    }

    public var colorHex: String {
        switch self {
        case .text: "#4EA7FC"
        case .links: "#70C1B3"
        case .images: "#B388EB"
        case .files: "#FF9F1C"
        }
    }

    public var matchedContentType: ClipboardContentType {
        switch self {
        case .text: .text
        case .links: .url
        case .images: .image
        case .files: .file
        }
    }

    public func matches(_ item: ClipboardItem) -> Bool {
        if item.contentType == .mixed {
            let hasImage = item.payload.hasImageAsset
            let hasFile = !item.payload.allFileURLStrings.isEmpty
            switch self {
            case .images:
                return hasImage
            case .files:
                return !hasImage && hasFile
            case .links:
                return !hasImage && !hasFile && item.presentationContentType == .url
            case .text:
                return !hasImage && !hasFile && item.presentationContentType == .text
            }
        }
        return item.presentationContentType == matchedContentType
    }

    public static func category(forPinboardName name: String) -> SmartPinboardCategory? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return allCases.first { $0.pinboardName == trimmed }
    }

    public static func isSmartPinboardName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return category(forPinboardName: trimmed) != nil || obsoletePinboardNames.contains(trimmed)
    }

    public static let obsoletePinboardNames: Set<String> = ["Smart: Mixed"]
}

public enum ClipboardCollectionID: Hashable, Codable, Sendable, Identifiable {
    case history
    case pasteStack
    case smart(SmartPinboardCategory)
    case pinboard(UUID)

    public var id: String {
        switch self {
        case .history:
            "history"
        case .pasteStack:
            "pasteStack"
        case .smart(let category):
            "smart:\(category.rawValue)"
        case .pinboard(let id):
            "pinboard:\(id.uuidString)"
        }
    }
}

public enum ClipboardReuseCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case general
    case snippet
    case template
    case code
    case color
    case asset

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .general: "General"
        case .snippet: "Snippet"
        case .template: "Template"
        case .code: "Code"
        case .color: "Color"
        case .asset: "Asset"
        }
    }

    public var systemImageName: String {
        switch self {
        case .general: "square.grid.2x2"
        case .snippet: "text.quote"
        case .template: "doc.text"
        case .code: "curlybraces"
        case .color: "paintpalette"
        case .asset: "shippingbox"
        }
    }
}

public enum ClipboardFilterKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case contentType
    case sourceApp
    case device
    case date

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .contentType: "Type"
        case .sourceApp: "App"
        case .device: "Device"
        case .date: "Date"
        }
    }

    public var systemImageName: String {
        switch self {
        case .contentType: "doc.text.magnifyingglass"
        case .sourceApp: "app"
        case .device: "desktopcomputer"
        case .date: "calendar"
        }
    }
}

public enum CaptureRuleCondition: String, CaseIterable, Codable, Identifiable, Sendable {
    case containsText
    case regularExpression
    case sourceApplicationName
    case sourceBundleIdentifier
    case urlHost
    case fileExtension

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .containsText: "Contains Text"
        case .regularExpression: "Regular Expression"
        case .sourceApplicationName: "Source App Name"
        case .sourceBundleIdentifier: "Source Bundle ID"
        case .urlHost: "URL Host"
        case .fileExtension: "File Extension"
        }
    }

    public var systemImageName: String {
        switch self {
        case .containsText: "text.magnifyingglass"
        case .regularExpression: "chevron.left.forwardslash.chevron.right"
        case .sourceApplicationName: "app"
        case .sourceBundleIdentifier: "number"
        case .urlHost: "link"
        case .fileExtension: "doc.badge.gearshape"
        }
    }
}

public struct CaptureRule: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var condition: CaptureRuleCondition
    public var pattern: String
    public var contentTypes: Set<ClipboardContentType>
    public var isEnabled: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        condition: CaptureRuleCondition,
        pattern: String,
        contentTypes: Set<ClipboardContentType> = [],
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id
        self.name = trimmedName?.isEmpty == false ? trimmedName! : "\(condition.displayName): \(trimmedPattern.singleLinePreview)"
        self.condition = condition
        self.pattern = trimmedPattern
        self.contentTypes = contentTypes
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var scopeDescription: String {
        guard !contentTypes.isEmpty else { return "All content" }
        return contentTypes
            .sorted { $0.displayName < $1.displayName }
            .map(\.displayName)
            .joined(separator: ", ")
    }

    public func matches(_ item: ClipboardItem, sourceBundleIdentifier: String? = nil) -> Bool {
        guard isEnabled, !pattern.isEmpty else { return false }
        guard contentTypes.isEmpty || item.effectiveContentTypes.contains(where: contentTypes.contains) else {
            return false
        }

        switch condition {
        case .containsText:
            return item.captureRuleSearchText.range(
                of: pattern,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        case .regularExpression:
            return item.captureRuleSearchText.range(
                of: pattern,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        case .sourceApplicationName:
            return item.sourceAppName.range(
                of: pattern,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        case .sourceBundleIdentifier:
            let bundleIdentifier = sourceBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
            return bundleIdentifier.range(
                of: pattern,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        case .urlHost:
            return item.payload.allURLStrings.contains { value in
                guard let host = URL(string: value)?.host(percentEncoded: false) else { return false }
                return host.range(of: pattern, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        case .fileExtension:
            let normalizedPattern = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !normalizedPattern.isEmpty else { return false }
            return item.payload.allFileURLStrings.contains { value in
                guard let fileExtension = URL(string: value)?.pathExtension, !fileExtension.isEmpty else {
                    return false
                }
                return fileExtension.compare(
                    normalizedPattern,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
            }
        }
    }
}

public struct ClipboardFilterDescriptor: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var kind: ClipboardFilterKind
    public var value: String
    public var title: String
    public var subtitle: String
    public var systemImageName: String

    public var id: String { "\(kind.rawValue):\(value)" }

    public init(
        kind: ClipboardFilterKind,
        value: String,
        title: String,
        subtitle: String,
        systemImageName: String? = nil
    ) {
        self.kind = kind
        self.value = value
        self.title = title
        self.subtitle = subtitle
        self.systemImageName = systemImageName ?? kind.systemImageName
    }
}

public enum OCRState: Codable, Equatable, Sendable {
    case notNeeded
    case pending(Date)
    case completed(Date)
    case failed(Date, String)

    public var displayName: String {
        switch self {
        case .notNeeded: "Not needed"
        case .pending: "OCR pending"
        case .completed: "OCR complete"
        case .failed: "OCR failed"
        }
    }

    public var isPending: Bool {
        if case .pending = self {
            return true
        }
        return false
    }
}

public struct ClipboardPayload: Codable, Equatable, Sendable {
    public var text: String?
    public var htmlString: String?
    public var rtfData: Data?
    public var rtfAssetID: String?
    public var rtfByteCount: Int?
    public var urlString: String?
    public var fileURLString: String?
    public var fileURLStrings: [String]
    public var imageData: Data?
    public var imageAssetID: String?
    public var imageByteCount: Int?
    public var ocrText: String?

    public init(
        text: String? = nil,
        htmlString: String? = nil,
        rtfData: Data? = nil,
        rtfAssetID: String? = nil,
        rtfByteCount: Int? = nil,
        urlString: String? = nil,
        fileURLString: String? = nil,
        fileURLStrings: [String] = [],
        imageData: Data? = nil,
        imageAssetID: String? = nil,
        imageByteCount: Int? = nil,
        ocrText: String? = nil
    ) {
        self.text = text
        self.htmlString = htmlString
        self.rtfData = rtfData
        self.rtfAssetID = rtfAssetID
        self.rtfByteCount = rtfData?.count ?? rtfByteCount
        self.urlString = urlString
        self.fileURLString = fileURLString
        self.fileURLStrings = Self.normalizedFileURLStrings(
            primary: fileURLString,
            additional: fileURLStrings
        )
        self.imageData = imageData
        self.imageAssetID = imageAssetID
        self.imageByteCount = imageData?.count ?? imageByteCount
        self.ocrText = ocrText
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case htmlString
        case rtfData
        case rtfAssetID
        case rtfByteCount
        case urlString
        case fileURLString
        case fileURLStrings
        case imageData
        case imageAssetID
        case imageByteCount
        case ocrText
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        htmlString = try container.decodeIfPresent(String.self, forKey: .htmlString)
        rtfData = try container.decodeIfPresent(Data.self, forKey: .rtfData)
        rtfAssetID = try container.decodeIfPresent(String.self, forKey: .rtfAssetID)
        rtfByteCount = try container.decodeIfPresent(Int.self, forKey: .rtfByteCount) ?? rtfData?.count
        urlString = try container.decodeIfPresent(String.self, forKey: .urlString)
        fileURLString = try container.decodeIfPresent(String.self, forKey: .fileURLString)
        let decodedFileURLStrings = try container.decodeIfPresent([String].self, forKey: .fileURLStrings) ?? []
        fileURLStrings = Self.normalizedFileURLStrings(
            primary: fileURLString,
            additional: decodedFileURLStrings
        )
        imageData = try container.decodeIfPresent(Data.self, forKey: .imageData)
        imageAssetID = try container.decodeIfPresent(String.self, forKey: .imageAssetID)
        imageByteCount = try container.decodeIfPresent(Int.self, forKey: .imageByteCount) ?? imageData?.count
        ocrText = try container.decodeIfPresent(String.self, forKey: .ocrText)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(htmlString, forKey: .htmlString)
        try container.encodeIfPresent(rtfData, forKey: .rtfData)
        try container.encodeIfPresent(rtfAssetID, forKey: .rtfAssetID)
        try container.encodeIfPresent(rtfData?.count ?? rtfByteCount, forKey: .rtfByteCount)
        try container.encodeIfPresent(urlString, forKey: .urlString)
        try container.encodeIfPresent(fileURLString, forKey: .fileURLString)
        if !fileURLStrings.isEmpty {
            try container.encode(fileURLStrings, forKey: .fileURLStrings)
        }
        try container.encodeIfPresent(imageData, forKey: .imageData)
        try container.encodeIfPresent(imageAssetID, forKey: .imageAssetID)
        try container.encodeIfPresent(imageData?.count ?? imageByteCount, forKey: .imageByteCount)
        try container.encodeIfPresent(ocrText, forKey: .ocrText)
    }

    public var hasRTFAsset: Bool {
        rtfData?.isEmpty == false || rtfAssetID?.isEmpty == false || (rtfByteCount ?? 0) > 0
    }

    public var hasImageAsset: Bool {
        imageData?.isEmpty == false || imageAssetID?.isEmpty == false || (imageByteCount ?? 0) > 0
    }

    public var allFileURLStrings: [String] {
        Self.normalizedFileURLStrings(primary: fileURLString, additional: fileURLStrings)
    }

    public var allURLStrings: [String] {
        let explicitURLs = explicitURLStrings
        if !explicitURLs.isEmpty {
            return explicitURLs
        }
        return Self.detectedURLStrings(in: text ?? htmlString?.pasteBuddyPlainTextFromHTML ?? "")
    }

    public var explicitURLStrings: [String] {
        [urlString].compactMap { value in
            value.flatMap(Self.normalizedWebURLString)
        }
    }

    public var presentationURLString: String? {
        explicitURLStrings.first ?? standaloneDetectedURLString
    }

    private var standaloneDetectedURLString: String? {
        let candidateText = text ?? htmlString?.pasteBuddyPlainTextFromHTML
        guard let trimmed = candidateText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.contains(where: \.isWhitespace),
              let detected = Self.detectedURLStrings(in: trimmed).first,
              Self.normalizedURLComparisonKey(detected) == Self.normalizedURLComparisonKey(trimmed) else {
            return nil
        }
        return detected
    }

    public var primaryText: String {
        text
            ?? urlString
            ?? allFileURLStrings.first
            ?? htmlString?.pasteBuddyPlainTextFromHTML.nilIfEmpty
            ?? ""
    }

    public var searchableText: String {
        [
            text,
            htmlString?.pasteBuddyPlainTextFromHTML,
            urlString,
            allFileURLStrings.joined(separator: "\n"),
            ocrText
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func normalizedFileURLStrings(
        primary: String?,
        additional: [String]
    ) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in ([primary].compactMap { $0 } + additional) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(trimmed)
        }
        return result
    }

    public static func normalizedWebURLString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowercased = trimmed.lowercased()
        let candidate: String
        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
            candidate = trimmed
        } else if lowercased.hasPrefix("www.") {
            candidate = "https://\(trimmed)"
        } else {
            return nil
        }

        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              host.contains("."),
              let url = components.url else {
            return nil
        }
        return url.absoluteString
    }

    private static func detectedURLStrings(in value: String) -> [String] {
        value
            .split(whereSeparator: \.isWhitespace)
            .compactMap { rawToken -> String? in
                let token = rawToken.trimmingCharacters(in: CharacterSet(charactersIn: "<>()[]{}\"'"))
                    .trimmingCharacters(in: .punctuationCharacters)
                return Self.normalizedWebURLString(token)
            }
    }

    private static func normalizedURLComparisonKey(_ value: String) -> String {
        let normalized = value
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>()[]{}\"'"))
            .trimmingCharacters(in: .punctuationCharacters)
            .lowercased()
        if normalized.hasPrefix("www.") {
            return "https://\(normalized)"
        }
        return normalized
    }
}

public struct ClipboardVisualPreview: Equatable, Sendable {
    public var headline: String
    public var body: String
    public var detail: String?
    public var badgeText: String
    public var systemImageName: String
    public var prefersImageThumbnail: Bool

    public init(
        headline: String,
        body: String,
        detail: String? = nil,
        badgeText: String,
        systemImageName: String,
        prefersImageThumbnail: Bool = false
    ) {
        self.headline = headline
        self.body = body
        self.detail = detail
        self.badgeText = badgeText
        self.systemImageName = systemImageName
        self.prefersImageThumbnail = prefersImageThumbnail
    }
}

public struct ClipboardSearchDocument: Codable, Equatable, Sendable {
    public var normalizedText: String
    public var previewHeadline: String
    public var previewBody: String
    public var storageBytes: Int
    public var contentHash: String
    public var searchHash: String
    public var dedupeHash: String {
        get { contentHash }
        set { contentHash = newValue }
    }

    public init(
        normalizedText: String,
        previewHeadline: String,
        previewBody: String,
        storageBytes: Int,
        dedupeHash: String,
        contentHash: String? = nil,
        searchHash: String? = nil
    ) {
        self.normalizedText = normalizedText
        self.previewHeadline = previewHeadline
        self.previewBody = previewBody
        self.storageBytes = storageBytes
        self.contentHash = contentHash ?? dedupeHash
        self.searchHash = searchHash ?? Self.searchDocumentHash(
            normalizedText: normalizedText,
            previewHeadline: previewHeadline,
            previewBody: previewBody
        )
    }

    private enum CodingKeys: String, CodingKey {
        case normalizedText
        case previewHeadline
        case previewBody
        case storageBytes
        case dedupeHash
        case contentHash
        case searchHash
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        normalizedText = try container.decodeIfPresent(String.self, forKey: .normalizedText) ?? ""
        previewHeadline = try container.decodeIfPresent(String.self, forKey: .previewHeadline) ?? ""
        previewBody = try container.decodeIfPresent(String.self, forKey: .previewBody) ?? ""
        storageBytes = try container.decodeIfPresent(Int.self, forKey: .storageBytes) ?? 0
        let legacyDedupeHash = try container.decodeIfPresent(String.self, forKey: .dedupeHash)
        contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
            ?? legacyDedupeHash
            ?? ""
        searchHash = try container.decodeIfPresent(String.self, forKey: .searchHash)
            ?? Self.searchDocumentHash(
                normalizedText: normalizedText,
                previewHeadline: previewHeadline,
                previewBody: previewBody
            )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(normalizedText, forKey: .normalizedText)
        try container.encode(previewHeadline, forKey: .previewHeadline)
        try container.encode(previewBody, forKey: .previewBody)
        try container.encode(storageBytes, forKey: .storageBytes)
        try container.encode(contentHash, forKey: .dedupeHash)
        try container.encode(contentHash, forKey: .contentHash)
        try container.encode(searchHash, forKey: .searchHash)
    }

    public static func searchDocumentHash(
        normalizedText: String,
        previewHeadline: String,
        previewBody: String
    ) -> String {
        var hasher = SHA256()
        for value in [normalizedText, previewHeadline, previewBody] {
            hasher.update(data: Data(value.utf8))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct PasteOrderPreviewRow: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var position: Int
    public var title: String
    public var contentType: ClipboardContentType
    public var summary: String

    public init(
        id: UUID,
        position: Int,
        title: String,
        contentType: ClipboardContentType,
        summary: String
    ) {
        self.id = id
        self.position = max(1, position)
        self.title = title
        self.contentType = contentType
        self.summary = summary
    }
}

public struct PasteOrderPreview: Equatable, Sendable {
    public var rows: [PasteOrderPreviewRow]
    public var fallbackDescription: String?

    public init(items: [ClipboardItem]) {
        rows = items.enumerated().map { index, item in
            PasteOrderPreviewRow(
                id: item.id,
                position: index + 1,
                title: item.title,
                contentType: item.contentType,
                summary: item.summary
            )
        }
        fallbackDescription = items.count > 1
            ? "Multiple selected items paste as plain text in this visible order, keeping mixed content predictable."
            : nil
    }
}

public struct PasteStackPreview: Equatable, Sendable {
    public var rows: [PasteOrderPreviewRow]
    public var direction: PasteStackDirection
    public var isCollecting: Bool
    public var nextRow: PasteOrderPreviewRow?

    public init(itemsInPasteOrder: [ClipboardItem], direction: PasteStackDirection, isCollecting: Bool) {
        rows = itemsInPasteOrder.enumerated().map { index, item in
            PasteOrderPreviewRow(
                id: item.id,
                position: index + 1,
                title: item.title,
                contentType: item.contentType,
                summary: item.summary
            )
        }
        self.direction = direction
        self.isCollecting = isCollecting
        nextRow = rows.first
    }
}

public struct ClipboardItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var sourceAppName: String
    public var sourceBundleIdentifier: String?
    public var deviceName: String
    public var contentType: ClipboardContentType
    public var title: String
    public var labels: [String]
    public var reuseCategory: ClipboardReuseCategory
    public var payload: ClipboardPayload
    public var ocrState: OCRState
    public var searchDocument: ClipboardSearchDocument

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sourceAppName: String,
        sourceBundleIdentifier: String? = nil,
        deviceName: String,
        contentType: ClipboardContentType,
        title: String,
        labels: [String] = [],
        reuseCategory: ClipboardReuseCategory? = nil,
        payload: ClipboardPayload,
        ocrState: OCRState = .notNeeded
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceAppName = sourceAppName
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.deviceName = deviceName
        self.contentType = contentType
        self.title = title
        self.labels = Self.normalizedLabels(labels)
        self.reuseCategory = reuseCategory ?? Self.inferredReuseCategory(
            contentType: contentType,
            payload: payload
        )
        self.payload = payload
        self.ocrState = ocrState
        self.searchDocument = Self.makeSearchDocument(
            title: title,
            labels: self.labels,
            sourceAppName: sourceAppName,
            deviceName: deviceName,
            contentType: contentType,
            reuseCategory: self.reuseCategory,
            payload: payload,
            ocrState: ocrState
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case updatedAt
        case sourceAppName
        case sourceBundleIdentifier
        case deviceName
        case contentType
        case title
        case labels
        case reuseCategory
        case payload
        case ocrState
        case searchDocument
    }

    private struct SearchDocumentHashPresence: Decodable {
        var contentHash: String?
        var searchHash: String?

        var hasModernHashes: Bool {
            contentHash?.isEmpty == false && searchHash?.isEmpty == false
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        sourceAppName = try container.decodeIfPresent(String.self, forKey: .sourceAppName) ?? "Unknown"
        sourceBundleIdentifier = try container.decodeIfPresent(String.self, forKey: .sourceBundleIdentifier)
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName) ?? "Unknown Device"
        contentType = try container.decodeIfPresent(ClipboardContentType.self, forKey: .contentType) ?? .text
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Clipboard Item"
        labels = Self.normalizedLabels(try container.decodeIfPresent([String].self, forKey: .labels) ?? [])
        payload = try container.decodeIfPresent(ClipboardPayload.self, forKey: .payload) ?? ClipboardPayload()
        reuseCategory = try container.decodeIfPresent(ClipboardReuseCategory.self, forKey: .reuseCategory)
            ?? Self.inferredReuseCategory(contentType: contentType, payload: payload)
        ocrState = try container.decodeIfPresent(OCRState.self, forKey: .ocrState) ?? .notNeeded
        let rebuiltSearchDocument = Self.makeSearchDocument(
            title: title,
            labels: labels,
            sourceAppName: sourceAppName,
            deviceName: deviceName,
            contentType: contentType,
            reuseCategory: reuseCategory,
            payload: payload,
            ocrState: ocrState
        )
        let hashPresence = try container.decodeIfPresent(SearchDocumentHashPresence.self, forKey: .searchDocument)
        if let decodedSearchDocument = try container.decodeIfPresent(ClipboardSearchDocument.self, forKey: .searchDocument),
           hashPresence?.hasModernHashes == true {
            searchDocument = decodedSearchDocument
        } else {
            searchDocument = rebuiltSearchDocument
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(sourceAppName, forKey: .sourceAppName)
        try container.encodeIfPresent(sourceBundleIdentifier, forKey: .sourceBundleIdentifier)
        try container.encode(deviceName, forKey: .deviceName)
        try container.encode(contentType, forKey: .contentType)
        try container.encode(title, forKey: .title)
        try container.encode(Self.normalizedLabels(labels), forKey: .labels)
        try container.encode(reuseCategory, forKey: .reuseCategory)
        try container.encode(payload, forKey: .payload)
        try container.encode(ocrState, forKey: .ocrState)
        try container.encode(searchDocument, forKey: .searchDocument)
    }

    public var summary: String {
        switch contentType {
        case .text:
            searchDocument.previewBody.nilIfEmpty ?? title
        case .url:
            payload.urlString ?? title
        case .file:
            payload.allFileURLStrings.first.flatMap { URL(string: $0)?.lastPathComponent } ?? title
        case .image:
            payload.ocrText?.singleLinePreview ?? searchDocument.previewBody.nilIfEmpty ?? "Image"
        case .mixed:
            searchDocument.previewBody.nilIfEmpty ?? title
        }
    }

    public var presentationContentType: ClipboardContentType {
        let hasPresentationURL = payload.presentationURLString != nil
        let hasTextContent = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || payload.htmlString?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || payload.hasRTFAsset
        let hasFileContent = !payload.allFileURLStrings.isEmpty
        let hasLinkPreviewImage = hasPresentationURL && payload.hasImageAsset && !hasFileContent
        if hasPresentationURL,
           contentType == .url || contentType == .text || (contentType == .mixed && (hasLinkPreviewImage || !payload.hasImageAsset)) {
            return .url
        }
        if contentType == .url {
            return .text
        }
        guard contentType == .mixed else { return contentType }
        if payload.hasImageAsset {
            return .image
        }
        if !payload.allFileURLStrings.isEmpty {
            return .file
        }
        if hasTextContent {
            return .text
        }
        return .mixed
    }

    public var visualPreview: ClipboardVisualPreview {
        if presentationContentType == .url {
            return linkVisualPreview
        }
        switch contentType {
        case .text:
            let body = searchDocument.previewBody.nilIfEmpty ?? title
            let detail = payload.htmlString?.isEmpty == false || payload.hasRTFAsset ? "Rich text available" : nil
            return ClipboardVisualPreview(
                headline: searchDocument.previewHeadline.nilIfEmpty ?? title,
                body: body,
                detail: detail,
                badgeText: contentType.displayName,
                systemImageName: "text.alignleft"
            )
        case .url:
            if presentationContentType == .url {
                return linkVisualPreview
            }
            return ClipboardVisualPreview(
                headline: searchDocument.previewHeadline.nilIfEmpty ?? title,
                body: searchDocument.previewBody.nilIfEmpty ?? payload.primaryText,
                badgeText: ClipboardContentType.text.displayName,
                systemImageName: "text.alignleft"
            )
        case .file:
            let fileNames = payload.allFileURLStrings.map { value in
                URL(string: value)?.lastPathComponent.nilIfEmpty ?? value
            }
            let body = fileNames.first ?? title
            let remainingCount = max(fileNames.count - 1, 0)
            let detail = remainingCount > 0 ? "\(remainingCount) more \(remainingCount == 1 ? "file" : "files")" : nil
            return ClipboardVisualPreview(
                headline: body,
                body: payload.allFileURLStrings.first ?? body,
                detail: detail,
                badgeText: contentType.displayName,
                systemImageName: "doc"
            )
        case .image:
            let body = searchDocument.previewBody.nilIfEmpty
                ?? (ocrState.isPending ? "OCR pending" : "Image preview")
            return ClipboardVisualPreview(
                headline: searchDocument.previewHeadline.nilIfEmpty ?? title,
                body: body,
                detail: ocrState.displayName,
                badgeText: contentType.displayName,
                systemImageName: "photo",
                prefersImageThumbnail: payload.hasImageAsset
            )
        case .mixed:
            switch presentationContentType {
            case .text:
                let body = searchDocument.previewBody.nilIfEmpty ?? title
                let detail = payload.htmlString?.isEmpty == false || payload.hasRTFAsset ? "Rich text available" : nil
                return ClipboardVisualPreview(
                    headline: searchDocument.previewHeadline.nilIfEmpty ?? title,
                    body: body,
                    detail: detail,
                    badgeText: ClipboardContentType.text.displayName,
                    systemImageName: "text.alignleft"
                )
            case .url:
                let urlString = payload.presentationURLString ?? title
                let host = URL(string: urlString)?.host?.nilIfEmpty
                return ClipboardVisualPreview(
                    headline: host ?? title,
                    body: urlString,
                    detail: host == nil ? nil : "Link",
                    badgeText: ClipboardContentType.url.displayName,
                    systemImageName: "link"
                )
            case .file:
                let fileNames = payload.allFileURLStrings.map { value in
                    URL(string: value)?.lastPathComponent.nilIfEmpty ?? value
                }
                let body = fileNames.first ?? title
                let remainingCount = max(fileNames.count - 1, 0)
                let detail = remainingCount > 0 ? "\(remainingCount) more \(remainingCount == 1 ? "file" : "files")" : nil
                return ClipboardVisualPreview(
                    headline: body,
                    body: payload.allFileURLStrings.first ?? body,
                    detail: detail,
                    badgeText: ClipboardContentType.file.displayName,
                    systemImageName: "doc"
                )
            case .image:
                let body = searchDocument.previewBody.nilIfEmpty
                    ?? (ocrState.isPending ? "OCR pending" : "Image preview")
                return ClipboardVisualPreview(
                    headline: searchDocument.previewHeadline.nilIfEmpty ?? title,
                    body: body,
                    detail: ocrState.displayName,
                    badgeText: ClipboardContentType.image.displayName,
                    systemImageName: "photo",
                    prefersImageThumbnail: payload.hasImageAsset
                )
            case .mixed:
                break
            }
            let body = searchDocument.previewBody.nilIfEmpty ?? title
            var detailParts: [String] = []
            if payload.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                detailParts.append("text")
            }
            if payload.urlString?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                detailParts.append("link")
            }
            if !payload.allFileURLStrings.isEmpty {
                detailParts.append("\(payload.allFileURLStrings.count) file\(payload.allFileURLStrings.count == 1 ? "" : "s")")
            }
            if payload.hasImageAsset {
                detailParts.append("image")
            }
            return ClipboardVisualPreview(
                headline: searchDocument.previewHeadline.nilIfEmpty ?? title,
                body: body,
                detail: detailParts.isEmpty ? nil : detailParts.joined(separator: ", "),
                badgeText: contentType.displayName,
                systemImageName: "square.stack.3d.up",
                prefersImageThumbnail: payload.hasImageAsset
            )
        }
    }

    public var openableURL: URL? {
        if let presentationURLString = payload.presentationURLString {
            return URL(string: presentationURLString)
        }
        return switch contentType {
        case .url:
            payload.presentationURLString.flatMap { URL(string: $0) }
        case .file:
            payload.allFileURLStrings.first.flatMap { URL(string: $0) }
        case .mixed:
            payload.presentationURLString.flatMap { URL(string: $0) }
                ?? payload.allFileURLStrings.first.flatMap { URL(string: $0) }
        case .text, .image:
            nil
        }
    }

    public func matches(_ query: String) -> Bool {
        matchesNormalizedSearchQuery(Self.normalizedSearchQuery(query))
    }

    /// Fast path for callers filtering many items against one query: normalize
    /// once with `normalizedSearchQuery(_:)`, then reuse the result per item.
    public func matchesNormalizedSearchQuery(_ normalizedQuery: String) -> Bool {
        guard !normalizedQuery.isEmpty else { return true }
        let terms = Self.searchTokens(inNormalizedQuery: normalizedQuery)
        guard !terms.isEmpty else {
            return searchDocument.normalizedText.contains(normalizedQuery)
        }
        let documentTokens = Self.searchTokens(inNormalizedQuery: searchDocument.normalizedText)
        return terms.allSatisfy { term in
            documentTokens.contains { $0.hasPrefix(term) }
        }
    }

    public static func normalizedSearchQuery(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return normalizedSearchString(trimmed)
    }

    static func searchTokens(inNormalizedQuery normalizedQuery: String) -> [String] {
        let tokenCharacters = CharacterSet.letters.union(.decimalDigits)
        var tokens: [String] = []
        var current = String.UnicodeScalarView()

        func flushCurrentToken() {
            guard !current.isEmpty else { return }
            tokens.append(String(current))
            current.removeAll(keepingCapacity: true)
        }

        for scalar in normalizedQuery.unicodeScalars {
            if tokenCharacters.contains(scalar) {
                current.append(scalar)
            } else {
                flushCurrentToken()
            }
        }
        flushCurrentToken()
        return tokens
    }

    public var captureRuleSearchText: String {
        searchDocument.normalizedText
    }

    public var effectiveContentTypes: Set<ClipboardContentType> {
        Self.effectiveContentTypes(contentType: contentType, payload: payload)
    }

    static func effectiveContentTypes(
        contentType: ClipboardContentType,
        payload: ClipboardPayload
    ) -> Set<ClipboardContentType> {
        var types: Set<ClipboardContentType> = []
        let hasPresentationURL = payload.presentationURLString != nil
        let hasTextContent = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || payload.htmlString?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || payload.hasRTFAsset
        let hasFileContent = !payload.allFileURLStrings.isEmpty
        let hasLinkPreviewImage = hasPresentationURL && payload.hasImageAsset && !hasFileContent
        if hasLinkPreviewImage {
            types.insert(.url)
        } else if contentType != .url {
            types.insert(contentType)
        }
        if (hasTextContent && !hasLinkPreviewImage) || (contentType == .url && payload.presentationURLString == nil) {
            types.insert(.text)
        }
        if hasPresentationURL && !hasLinkPreviewImage {
            types.insert(.url)
        }
        if !payload.allFileURLStrings.isEmpty {
            types.insert(.file)
        }
        if payload.hasImageAsset && !hasLinkPreviewImage {
            types.insert(.image)
        }
        return types
    }

    private var linkVisualPreview: ClipboardVisualPreview {
        let urlString = payload.presentationURLString ?? payload.urlString ?? title
        let host = URL(string: urlString)?.host?.nilIfEmpty
        let displayTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let headline = if payload.hasImageAsset,
                          let displayTitle,
                          displayTitle != host,
                          displayTitle != urlString {
            displayTitle
        } else {
            host ?? title
        }
        return ClipboardVisualPreview(
            headline: headline,
            body: urlString,
            detail: host == nil ? nil : "Link",
            badgeText: ClipboardContentType.url.displayName,
            systemImageName: "link",
            prefersImageThumbnail: payload.hasImageAsset
        )
    }

    public static func normalizedLabels(_ labels: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for label in labels {
            let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            let key = normalized.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(normalized)
        }
        return result
    }

    public mutating func refreshSearchDocument() {
        labels = Self.normalizedLabels(labels)
        searchDocument = Self.makeSearchDocument(
            title: title,
            labels: labels,
            sourceAppName: sourceAppName,
            deviceName: deviceName,
            contentType: contentType,
            reuseCategory: reuseCategory,
            payload: payload,
            ocrState: ocrState
        )
    }

    public static func makeSearchDocument(
        title: String,
        labels: [String],
        sourceAppName: String,
        deviceName: String,
        contentType: ClipboardContentType,
        reuseCategory: ClipboardReuseCategory,
        payload: ClipboardPayload,
        ocrState: OCRState
    ) -> ClipboardSearchDocument {
        let searchablePayloadText = payload.searchableText
        let previewBody: String
        switch contentType {
        case .text:
            previewBody = payload.text?.singleLinePreview.nilIfEmpty
                ?? payload.htmlString?.pasteBuddyPlainTextFromHTML.singleLinePreview.nilIfEmpty
                ?? title
        case .url:
            previewBody = payload.urlString ?? title
        case .file:
            let fileNames = payload.allFileURLStrings.map { value in
                URL(string: value)?.lastPathComponent.nilIfEmpty ?? value
            }
            previewBody = fileNames.first ?? title
        case .image:
            previewBody = payload.ocrText?.singleLinePreview.nilIfEmpty
                ?? (ocrState.isPending ? "OCR pending" : "Image preview")
        case .mixed:
            previewBody = searchablePayloadText.singleLinePreview.nilIfEmpty ?? title
        }

        let normalizedText = normalizedSearchString([
            title,
            labels.joined(separator: " "),
            reuseCategory.displayName,
            sourceAppName,
            deviceName,
            contentType.displayName,
            searchablePayloadText
        ].joined(separator: "\n"))

        return ClipboardSearchDocument(
            normalizedText: normalizedText,
            previewHeadline: title.singleLinePreview,
            previewBody: previewBody.singleLinePreview,
            storageBytes: estimatedStorageBytes(
                title: title,
                labels: labels,
                sourceAppName: sourceAppName,
                deviceName: deviceName,
                contentType: contentType,
                reuseCategory: reuseCategory,
                payload: payload
            ),
            dedupeHash: deduplicationHash(contentType: contentType, payload: payload),
            searchHash: ClipboardSearchDocument.searchDocumentHash(
                normalizedText: normalizedText,
                previewHeadline: title.singleLinePreview,
                previewBody: previewBody.singleLinePreview
            )
        )
    }

    public static func normalizedSearchString(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    /// PasteBuddyStore maintains its dedupe index incrementally and skips
    /// rebuilds for mutations that only touch fields outside these inputs
    /// (for example `ocrText`, titles, and link-preview images).
    public static func deduplicationHash(contentType: ClipboardContentType, payload: ClipboardPayload) -> String {
        var hasher = SHA256()
        func update(_ value: String) {
            hasher.update(data: Data(value.utf8))
            hasher.update(data: Data([0]))
        }

        update(contentType.rawValue)
        update(payload.text ?? "")
        update(payload.htmlString ?? "")
        update(binaryHash(data: payload.rtfData, assetID: payload.rtfAssetID))
        update(payload.urlString ?? "")
        for fileURLString in payload.allFileURLStrings {
            update(fileURLString)
        }
        update(contentType == .url ? "" : binaryHash(data: payload.imageData, assetID: payload.imageAssetID))

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func binaryHash(data: Data?, assetID: String?) -> String {
        if let data {
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return assetID ?? ""
    }

    public static func estimatedStorageBytes(
        title: String,
        labels: [String],
        sourceAppName: String,
        deviceName: String,
        contentType: ClipboardContentType,
        reuseCategory: ClipboardReuseCategory,
        payload: ClipboardPayload
    ) -> Int {
        var estimatedBytes = 256
        estimatedBytes += title.utf8.count
        estimatedBytes += sourceAppName.utf8.count
        estimatedBytes += deviceName.utf8.count
        estimatedBytes += contentType.rawValue.utf8.count
        estimatedBytes += labels.reduce(0) { $0 + $1.utf8.count }
        estimatedBytes += reuseCategory.rawValue.utf8.count
        estimatedBytes += payload.text?.utf8.count ?? 0
        estimatedBytes += payload.htmlString?.utf8.count ?? 0
        estimatedBytes += payload.rtfData?.count ?? payload.rtfByteCount ?? 0
        estimatedBytes += payload.urlString?.utf8.count ?? 0
        estimatedBytes += payload.allFileURLStrings.reduce(0) { $0 + $1.utf8.count }
        estimatedBytes += payload.imageData?.count ?? payload.imageByteCount ?? 0
        estimatedBytes += payload.ocrText?.utf8.count ?? 0
        return estimatedBytes
    }

    public static func inferredReuseCategory(
        contentType: ClipboardContentType,
        payload: ClipboardPayload
    ) -> ClipboardReuseCategory {
        switch contentType {
        case .image, .file:
            return .asset
        case .mixed:
            if payload.hasImageAsset || !payload.allFileURLStrings.isEmpty {
                return .asset
            }
            return .general
        case .url:
            return .general
        case .text:
            let text = payload.primaryText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .general }
            if isColorLiteral(text) {
                return .color
            }
            if looksLikeTemplate(text) {
                return .template
            }
            if looksLikeCode(text) {
                return .code
            }
            return .snippet
        }
    }

    private static func isColorLiteral(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = value.lowercased()
        if lowercased.hasPrefix("rgb(")
            || lowercased.hasPrefix("rgba(")
            || lowercased.hasPrefix("hsl(")
            || lowercased.hasPrefix("hsla(") {
            return true
        }

        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        return [3, 4, 6, 8].contains(hex.count) && hex.allSatisfy(\.isHexDigit)
    }

    private static func looksLikeTemplate(_ text: String) -> Bool {
        text.contains("{{")
            || text.contains("}}")
            || text.contains("<#")
            || text.contains("#>")
            || text.contains("%@")
            || text.contains("${")
    }

    private static func looksLikeCode(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        let codeTokens = [
            "import ",
            "func ",
            "class ",
            "struct ",
            "enum ",
            "let ",
            "var ",
            "return ",
            "const ",
            "function ",
            "def ",
            "public "
        ]
        if codeTokens.contains(where: { lowercased.contains($0) }) {
            return true
        }
        return text.contains("\n") && ((text.contains("{") && text.contains("}")) || text.contains(";"))
    }
}

public struct Pinboard: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var colorHex: String
    public var itemIDs: [UUID]
    public var sharing: PinboardSharingState?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        colorHex: String,
        itemIDs: [UUID] = [],
        sharing: PinboardSharingState? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.itemIDs = itemIDs
        self.sharing = sharing
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum PinboardShareAccessMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case invitationOnly
    case linkAccess

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .invitationOnly: "Invitation Only"
        case .linkAccess: "Link Access"
        }
    }
}

public enum PinboardSharePermission: String, CaseIterable, Codable, Identifiable, Sendable {
    case readOnly
    case canEdit

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .readOnly: "Read Only"
        case .canEdit: "Can Edit"
        }
    }
}

public struct PinboardParticipant: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var displayName: String
    public var emailAddress: String?
    public var permission: PinboardSharePermission
    public var invitedAt: Date
    public var acceptedAt: Date?
    public var keyAgreementPublicKeyData: Data?
    public var wrappedBoardKey: PinboardWrappedBoardKey?
    public var boardKeyFingerprint: String?

    public init(
        id: UUID = UUID(),
        displayName: String,
        emailAddress: String? = nil,
        permission: PinboardSharePermission = .readOnly,
        invitedAt: Date = Date(),
        acceptedAt: Date? = nil,
        keyAgreementPublicKeyData: Data? = nil,
        wrappedBoardKey: PinboardWrappedBoardKey? = nil,
        boardKeyFingerprint: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.emailAddress = emailAddress
        self.permission = permission
        self.invitedAt = invitedAt
        self.acceptedAt = acceptedAt
        self.keyAgreementPublicKeyData = keyAgreementPublicKeyData
        self.wrappedBoardKey = wrappedBoardKey
        self.boardKeyFingerprint = boardKeyFingerprint
    }
}

public struct PinboardWrappedBoardKey: Codable, Equatable, Sendable {
    public var version: Int
    public var algorithm: String
    public var recipientPublicKeyData: Data
    public var ephemeralPublicKeyData: Data
    public var sealedBoardKeyData: Data

    public init(
        version: Int = 1,
        algorithm: String = "Curve25519.HKDF-SHA256.AES-GCM",
        recipientPublicKeyData: Data,
        ephemeralPublicKeyData: Data,
        sealedBoardKeyData: Data
    ) {
        self.version = version
        self.algorithm = algorithm
        self.recipientPublicKeyData = recipientPublicKeyData
        self.ephemeralPublicKeyData = ephemeralPublicKeyData
        self.sealedBoardKeyData = sealedBoardKeyData
    }
}

public struct PinboardKeyExchangeState: Codable, Equatable, Sendable {
    public var version: Int
    public var boardKeyFingerprint: String
    public var ownerPublicKeyData: Data
    public var ownerWrappedBoardKey: PinboardWrappedBoardKey
    public var createdAt: Date

    public init(
        version: Int = 1,
        boardKeyFingerprint: String,
        ownerPublicKeyData: Data,
        ownerWrappedBoardKey: PinboardWrappedBoardKey,
        createdAt: Date = Date()
    ) {
        self.version = version
        self.boardKeyFingerprint = boardKeyFingerprint
        self.ownerPublicKeyData = ownerPublicKeyData
        self.ownerWrappedBoardKey = ownerWrappedBoardKey
        self.createdAt = createdAt
    }
}

public struct PinboardSharingState: Codable, Equatable, Sendable {
    public var ownerDisplayName: String
    public var accessMode: PinboardShareAccessMode
    public var defaultPermission: PinboardSharePermission
    public var participants: [PinboardParticipant]
    public var shareLinkTokenHash: String?
    public var keyExchange: PinboardKeyExchangeState?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        ownerDisplayName: String,
        accessMode: PinboardShareAccessMode = .invitationOnly,
        defaultPermission: PinboardSharePermission = .readOnly,
        participants: [PinboardParticipant] = [],
        shareLinkTokenHash: String? = nil,
        keyExchange: PinboardKeyExchangeState? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.ownerDisplayName = ownerDisplayName
        self.accessMode = accessMode
        self.defaultPermission = defaultPermission
        self.participants = participants
        self.shareLinkTokenHash = shareLinkTokenHash
        self.keyExchange = keyExchange
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum PinboardInvitationInboxStatus: String, Codable, Equatable, Sendable {
    case pending
    case accepted
    case rejected
    case expired
}

public struct PinboardInvitationInboxEntry: Identifiable, Codable, Equatable, Sendable {
    public var package: PinboardShareInvitationPackage
    public var receivedAt: Date
    public var status: PinboardInvitationInboxStatus
    public var statusUpdatedAt: Date?
    public var lastErrorMessage: String?

    public var id: UUID { package.id }

    public init(
        package: PinboardShareInvitationPackage,
        receivedAt: Date = Date(),
        status: PinboardInvitationInboxStatus = .pending,
        statusUpdatedAt: Date? = nil,
        lastErrorMessage: String? = nil
    ) {
        self.package = package
        self.receivedAt = receivedAt
        self.status = status
        self.statusUpdatedAt = statusUpdatedAt
        self.lastErrorMessage = lastErrorMessage
    }
}

public struct PinboardInvitationInbox: Codable, Equatable, Sendable {
    public var entries: [PinboardInvitationInboxEntry]

    public init(entries: [PinboardInvitationInboxEntry] = []) {
        self.entries = entries
    }

    public var pendingEntries: [PinboardInvitationInboxEntry] {
        entries.filter { $0.status == .pending }
    }
}

public struct GeneralConfiguration: Codable, Equatable, Sendable {
    public var launchAtLoginEnabled: Bool
    public var collectionOrder: [ClipboardCollectionID]?

    public init(
        launchAtLoginEnabled: Bool = false,
        collectionOrder: [ClipboardCollectionID]? = nil
    ) {
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.collectionOrder = collectionOrder
    }
}

public enum ProductAccessPlan: String, CaseIterable, Codable, Identifiable, Sendable {
    case free
    case trial
    case byokAnnual = "byok_annual"
    case cloudMonthly = "cloud_monthly"
    case cloudAnnual = "cloud_annual"
    case team

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .free: PasteBuddyLocalization.string("label.plan_free", defaultValue: "Free")
        case .trial: PasteBuddyLocalization.string("label.plan_free_trial", defaultValue: "Free Trial")
        case .byokAnnual: PasteBuddyLocalization.string("label.plan_byok_annual", defaultValue: "BYOK Annual")
        case .cloudMonthly: PasteBuddyLocalization.string("label.plan_cloud_monthly", defaultValue: "Cloud Monthly")
        case .cloudAnnual: PasteBuddyLocalization.string("label.plan_cloud_annual", defaultValue: "Cloud Annual")
        case .team: PasteBuddyLocalization.string("label.plan_team", defaultValue: "Team")
        }
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "monthly", "annual", "lifetime", "family":
            self = .free
        default:
            guard let plan = Self(rawValue: value) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Unknown PasteBuddy access plan: \(value)"
                )
            }
            self = plan
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var isPersonalPaidPlan: Bool {
        switch self {
        case .byokAnnual, .cloudMonthly, .cloudAnnual:
            true
        case .free, .trial, .team:
            false
        }
    }
}

public enum EntitlementStatus: String, CaseIterable, Codable, Identifiable, Sendable {
    case inactive
    case trialing
    case active
    case canceled
    case expired
    case billingRetry
    case revoked

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .inactive: "Inactive"
        case .trialing: "Trialing"
        case .active: "Active"
        case .canceled: "Canceled"
        case .expired: "Expired"
        case .billingRetry: "Billing Retry"
        case .revoked: "Revoked"
        }
    }
}

public enum RestorePurchasesState: Codable, Equatable, Sendable {
    case notStarted
    case inProgress(Date)
    case restored(Date)
    case failed(Date, String)

    public var displayName: String {
        switch self {
        case .notStarted: "Not Started"
        case .inProgress: "Restoring"
        case .restored: "Restored"
        case .failed: "Restore Failed"
        }
    }
}

public struct TeamPlanConfiguration: Codable, Equatable, Sendable {
    public var teamName: String
    public var seatCount: Int
    public var assignedSeatCount: Int
    public var pricePerSeatCents: Int
    public var billingCurrencyCode: String
    public var singleInvoiceEnabled: Bool
    public var managedDistributionEnabled: Bool
    public var adminEmailAddress: String?
    public var updatedAt: Date?

    public init(
        teamName: String = "",
        seatCount: Int = 1,
        assignedSeatCount: Int = 1,
        pricePerSeatCents: Int = 1_200,
        billingCurrencyCode: String = "USD",
        singleInvoiceEnabled: Bool = true,
        managedDistributionEnabled: Bool = true,
        adminEmailAddress: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.teamName = teamName
        self.seatCount = Self.clampSeatCount(seatCount)
        self.assignedSeatCount = Self.clampAssignedSeats(assignedSeatCount, seatCount: self.seatCount)
        self.pricePerSeatCents = max(0, pricePerSeatCents)
        self.billingCurrencyCode = Self.normalizedCurrencyCode(billingCurrencyCode)
        self.singleInvoiceEnabled = singleInvoiceEnabled
        self.managedDistributionEnabled = managedDistributionEnabled
        self.adminEmailAddress = adminEmailAddress?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.updatedAt = updatedAt
    }

    public var availableSeatCount: Int {
        max(0, seatCount - assignedSeatCount)
    }

    public var monthlyInvoiceCents: Int {
        seatCount * pricePerSeatCents
    }

    public var monthlyInvoiceDisplay: String {
        "\(billingCurrencyCode) \(String(format: "%.2f", Double(monthlyInvoiceCents) / 100))"
    }

    public var displayName: String {
        let trimmed = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Team Workspace" : trimmed
    }

    public static func clampSeatCount(_ value: Int) -> Int {
        min(max(value, 1), 10_000)
    }

    public static func clampAssignedSeats(_ value: Int, seatCount: Int) -> Int {
        min(max(value, 0), clampSeatCount(seatCount))
    }

    public static func normalizedCurrencyCode(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return normalized.isEmpty ? "USD" : String(normalized.prefix(3))
    }

    public var overview: TeamPlanOverview {
        TeamPlanOverview(team: self)
    }
}

public struct TeamPlanValueProposition: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var systemImageName: String

    public init(id: String, title: String, detail: String, systemImageName: String) {
        self.id = id
        self.title = title
        self.detail = detail
        self.systemImageName = systemImageName
    }
}

public struct TeamPlanOverview: Codable, Equatable, Sendable {
    public var teamName: String
    public var adminSummary: String
    public var seatSummary: String
    public var billingSummary: String
    public var distributionSummary: String
    public var primaryValueStatement: String
    public var purchasePositioning: String
    public var valuePropositions: [TeamPlanValueProposition]

    public init(team: TeamPlanConfiguration) {
        teamName = team.displayName
        adminSummary = team.adminEmailAddress.map { "Admin: \($0)" } ?? "Admin email not set"
        seatSummary = "\(team.assignedSeatCount)/\(team.seatCount) seats assigned, \(team.availableSeatCount) available"
        billingSummary = team.singleInvoiceEnabled
            ? "Single invoice enabled at \(team.monthlyInvoiceDisplay) per month."
            : "Per-seat billing represented at \(team.monthlyInvoiceDisplay) per month."
        distributionSummary = team.managedDistributionEnabled
            ? "Managed distribution enabled for team deployment."
            : "Managed distribution is off; members install individually."
        primaryValueStatement = "Team plans center on shared pinboards for reusable ideas, links, files, images, and snippets that stay in sync for collaborators."
        purchasePositioning = PasteBuddyLocalization.string(
            "message.team_purchase_positioning",
            defaultValue: "Team is a business plan distinct from personal BYOK and Cloud subscriptions, with seat billing and admin-visible license state."
        )
        valuePropositions = [
            TeamPlanValueProposition(
                id: "shared-pinboards",
                title: "Shared pinboards",
                detail: "Collect team ideas, links, files, images, and reusable snippets in shared boards.",
                systemImageName: "pin.2"
            ),
            TeamPlanValueProposition(
                id: "stay-in-sync",
                title: "Stay in sync",
            detail: "Keep shared clipboard collections aligned across team devices when CloudKit sync and sharing are configured.",
                systemImageName: "arrow.triangle.2.circlepath"
            ),
            TeamPlanValueProposition(
                id: "admin-seat-state",
                title: "Admin seat state",
                detail: "Show total seats, assigned seats, available seats, admin contact, invoice mode, and distribution mode before a full admin console exists.",
                systemImageName: "person.3"
            )
        ]
    }
}

public enum TrialReminderState: String, CaseIterable, Codable, Identifiable, Sendable {
    case notStarted
    case active
    case endingSoon
    case canceled
    case ended
    case converted

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .notStarted: "Not Started"
        case .active: "Active"
        case .endingSoon: "Ending Soon"
        case .canceled: "Canceled"
        case .ended: "Ended"
        case .converted: "Converted"
        }
    }
}

public struct PersonalPurchaseOption: Codable, Equatable, Identifiable, Sendable {
    public var plan: ProductAccessPlan
    public var title: String
    public var detail: String
    public var unlockSummary: String
    public var includesFamilySharing: Bool

    public var id: String { plan.id }

    public init(
        plan: ProductAccessPlan,
        title: String,
        detail: String,
        unlockSummary: String,
        includesFamilySharing: Bool = false
    ) {
        self.plan = plan
        self.title = title
        self.detail = detail
        self.unlockSummary = unlockSummary
        self.includesFamilySharing = includesFamilySharing
    }
}

public struct PersonalEntitlementOverview: Codable, Equatable, Sendable {
    public var planName: String
    public var statusName: String
    public var accessState: String
    public var trialState: TrialReminderState
    public var trialSummary: String
    public var trialOutcomeStatement: String
    public var crossDeviceStatement: String
    public var restoreSummary: String
    public var restoreActionStatement: String
    public var purchaseOptions: [PersonalPurchaseOption]
    public var billingSafetyStatement: String

    public init(entitlement: EntitlementConfiguration, now: Date = Date()) {
        planName = entitlement.plan.displayName
        statusName = entitlement.status.displayName
        accessState = entitlement.hasFullAccess(now: now) ? "Unlocked" : "Limited"
        trialState = Self.trialState(for: entitlement, now: now)
        trialSummary = Self.trialSummary(for: entitlement, state: trialState, now: now)
        trialOutcomeStatement = Self.trialOutcomeStatement(for: entitlement, state: trialState)
        crossDeviceStatement = Self.crossDeviceStatement(for: entitlement, now: now)
        restoreSummary = Self.restoreSummary(for: entitlement, now: now)
        restoreActionStatement = Self.restoreActionStatement(for: entitlement)
        purchaseOptions = Self.allPurchaseOptions
        billingSafetyStatement = "PasteBuddy stores entitlement status only. Payment details stay with the App Store."
    }

    private static let allPurchaseOptions: [PersonalPurchaseOption] = [
        PersonalPurchaseOption(
            plan: .byokAnnual,
            title: PasteBuddyLocalization.string("label.plan_byok_annual", defaultValue: "BYOK Annual"),
            detail: PasteBuddyLocalization.string("message.byok_annual_option_detail", defaultValue: "Annual subscription for AI Search using your own provider keys."),
            unlockSummary: PasteBuddyLocalization.string("message.byok_annual_unlock", defaultValue: "Unlocks BYOK while the subscription remains active.")
        ),
        PersonalPurchaseOption(
            plan: .cloudMonthly,
            title: PasteBuddyLocalization.string("label.plan_cloud_monthly", defaultValue: "Cloud Monthly"),
            detail: PasteBuddyLocalization.string("message.cloud_monthly_option_detail", defaultValue: "Monthly subscription with PasteBuddy Cloud inference and BYOK."),
            unlockSummary: PasteBuddyLocalization.string("message.cloud_subscription_unlock", defaultValue: "Unlocks Cloud and BYOK while the subscription remains active.")
        ),
        PersonalPurchaseOption(
            plan: .cloudAnnual,
            title: PasteBuddyLocalization.string("label.plan_cloud_annual", defaultValue: "Cloud Annual"),
            detail: PasteBuddyLocalization.string("message.cloud_annual_option_detail", defaultValue: "Annual subscription with PasteBuddy Cloud inference and BYOK."),
            unlockSummary: PasteBuddyLocalization.string("message.cloud_subscription_unlock", defaultValue: "Unlocks Cloud and BYOK while the subscription remains active.")
        )
    ]

    private static func trialState(for entitlement: EntitlementConfiguration, now: Date) -> TrialReminderState {
        if entitlement.plan.isPersonalPaidPlan && entitlement.status == .active {
            return .converted
        }

        guard entitlement.plan == .trial || entitlement.trialStartedAt != nil || entitlement.trialEndsAt != nil else {
            return .notStarted
        }

        if entitlement.status == .canceled || entitlement.trialCanceledAt != nil {
            return .canceled
        }

        guard entitlement.status == .trialing, let trialEndsAt = entitlement.trialEndsAt else {
            return .ended
        }

        guard trialEndsAt > now else {
            return .ended
        }

        return daysRemaining(until: trialEndsAt, now: now) <= 3 ? .endingSoon : .active
    }

    private static func trialSummary(
        for entitlement: EntitlementConfiguration,
        state: TrialReminderState,
        now: Date
    ) -> String {
        switch state {
        case .notStarted:
            return "No trial has started."
        case .active, .endingSoon:
            guard let trialEndsAt = entitlement.trialEndsAt else {
                return state == .endingSoon ? "Trial is ending soon." : "Trial is active."
            }
            let days = daysRemaining(until: trialEndsAt, now: now)
            let unit = days == 1 ? "day" : "days"
            return state == .endingSoon
                ? "Trial ending soon: \(days) \(unit) remaining."
                : "Trial active: \(days) \(unit) remaining."
        case .canceled:
            return "Trial canceled. Access is back at the free level until a paid personal plan is active."
        case .ended:
            return "Trial ended. Access is back at the free level until a paid personal plan is active."
        case .converted:
            return "Trial converted to \(entitlement.plan.displayName)."
        }
    }

    private static func trialOutcomeStatement(
        for entitlement: EntitlementConfiguration,
        state: TrialReminderState
    ) -> String {
        switch state {
        case .active, .endingSoon:
            return PasteBuddyLocalization.string("message.ai_trial_end_outcome", defaultValue: "When the trial ends, PasteBuddy keeps local data and locks AI inference unless an active BYOK or Cloud subscription is available.")
        case .canceled:
            return PasteBuddyLocalization.string("message.ai_trial_canceled_outcome", defaultValue: "Canceled trials stop granting AI access; users can still activate a BYOK or Cloud subscription later.")
        case .ended:
            return "Ended trials do not delete local clipboard data; they only stop granting paid access."
        case .converted:
            return "The active \(entitlement.plan.displayName) entitlement replaces trial access while StoreKit reports it as valid."
        case .notStarted:
            return "Starting a trial grants temporary full access and shows the end state before a paid personal plan is required."
        }
    }

    private static func crossDeviceStatement(for entitlement: EntitlementConfiguration, now: Date) -> String {
        if entitlement.hasActivePaidAccess(now: now), entitlement.unlocksAllDevicesForAccount {
            if entitlement.isFamilySharingEnabled {
                return "This \(entitlement.plan.displayName) entitlement unlocks the same paid feature set on Mac, iPhone, and iPad for the entitled family account."
            }
            return "This \(entitlement.plan.displayName) entitlement unlocks the same paid feature set on Mac, iPhone, and iPad for the same user."
        }

        if entitlement.isTrialActive(now: now), entitlement.unlocksAllDevicesForAccount {
            return "Trial access is modeled across Mac, iPhone, and iPad for the same user until the trial ends."
        }

        return "No active paid entitlement is verified yet. Mac, iPhone, and iPad stay in limited mode until a personal plan or restored purchase is active."
    }

    private static func restoreSummary(for entitlement: EntitlementConfiguration, now: Date) -> String {
        switch entitlement.restoreState {
        case .notStarted:
            return "Restore has not been run on this device."
        case .inProgress:
            return "Restore is checking StoreKit for a verified purchase."
        case .restored:
            return entitlement.hasFullAccess(now: now)
                ? "Restore completed and an active entitlement is available on this device."
                : "Restore completed, but no active paid entitlement is available."
        case .failed(_, let message):
            return "Restore failed: \(message)"
        }
    }

    private static func restoreActionStatement(for entitlement: EntitlementConfiguration) -> String {
        switch entitlement.restoreState {
        case .notStarted:
            return "Use Restore Purchases after reinstalling PasteBuddy or moving to a new Mac, iPhone, or iPad."
        case .inProgress:
            return "Paid features stay limited until StoreKit returns a verified active entitlement."
        case .restored:
            return "Restored purchases can unlock all supported devices for the same user when StoreKit returns an active personal entitlement."
        case .failed:
            return "No entitlement was unlocked; retry with the App Store account that purchased PasteBuddy."
        }
    }

    private static func daysRemaining(until endDate: Date, now: Date) -> Int {
        max(0, Int((endDate.timeIntervalSince(now) / (24 * 60 * 60)).rounded(.up)))
    }
}

public struct EntitlementConfiguration: Codable, Equatable, Sendable {
    public var plan: ProductAccessPlan
    public var status: EntitlementStatus
    public var trialStartedAt: Date?
    public var trialEndsAt: Date?
    public var trialCanceledAt: Date?
    public var purchasedAt: Date?
    public var currentPeriodEndsAt: Date?
    public var expiresAt: Date?
    public var isFamilySharingEnabled: Bool
    public var unlocksAllDevicesForAccount: Bool
    public var restoreState: RestorePurchasesState
    public var team: TeamPlanConfiguration?

    public init(
        plan: ProductAccessPlan = .free,
        status: EntitlementStatus = .inactive,
        trialStartedAt: Date? = nil,
        trialEndsAt: Date? = nil,
        trialCanceledAt: Date? = nil,
        purchasedAt: Date? = nil,
        currentPeriodEndsAt: Date? = nil,
        expiresAt: Date? = nil,
        isFamilySharingEnabled: Bool = false,
        unlocksAllDevicesForAccount: Bool = false,
        restoreState: RestorePurchasesState = .notStarted,
        team: TeamPlanConfiguration? = nil
    ) {
        self.plan = plan
        self.status = status
        self.trialStartedAt = trialStartedAt
        self.trialEndsAt = trialEndsAt
        self.trialCanceledAt = trialCanceledAt
        self.purchasedAt = purchasedAt
        self.currentPeriodEndsAt = currentPeriodEndsAt
        self.expiresAt = expiresAt
        self.isFamilySharingEnabled = isFamilySharingEnabled
        self.unlocksAllDevicesForAccount = unlocksAllDevicesForAccount
        self.restoreState = restoreState
        self.team = team
    }

    public func isTrialActive(now: Date = Date()) -> Bool {
        guard plan == .trial, status == .trialing, trialCanceledAt == nil, let trialEndsAt else {
            return false
        }
        return trialEndsAt > now
    }

    public func hasActivePaidAccess(now: Date = Date()) -> Bool {
        guard status == .active else { return false }
        switch plan {
        case .byokAnnual, .cloudMonthly, .cloudAnnual:
            guard let endDate = expiresAt ?? currentPeriodEndsAt else { return false }
            return endDate > now
        case .team:
            return team != nil
        case .free, .trial:
            return false
        }
    }

    public func hasFullAccess(now: Date = Date()) -> Bool {
        (plan == .team && hasActivePaidAccess(now: now)) || hasBYOKAccess(now: now)
    }

    public func hasBYOKAccess(now: Date = Date()) -> Bool {
        if isTrialActive(now: now) { return true }
        guard plan == .byokAnnual || plan == .cloudMonthly || plan == .cloudAnnual else { return false }
        return hasActivePaidAccess(now: now)
    }

    public func hasCloudAccess(now: Date = Date()) -> Bool {
        if isTrialActive(now: now) { return true }
        guard hasActivePaidAccess(now: now) else { return false }
        return plan == .cloudMonthly || plan == .cloudAnnual
    }

    public var accessSummary: String {
        if let team, plan == .team {
            return "\(team.displayName): \(team.assignedSeatCount)/\(team.seatCount) seats assigned"
        }
        if isFamilySharingEnabled {
            return "\(plan.displayName), Family Sharing"
        }
        if unlocksAllDevicesForAccount {
            return "\(plan.displayName), all devices"
        }
        return plan.displayName
    }

    public var teamOverview: TeamPlanOverview? {
        guard plan == .team, let team else { return nil }
        return team.overview
    }

    public func personalOverview(now: Date = Date()) -> PersonalEntitlementOverview {
        PersonalEntitlementOverview(entitlement: self, now: now)
    }
}

public struct PrivacyConfiguration: Codable, Equatable, Sendable {
    public var isCapturePaused: Bool
    public var capturePauseUntil: Date?
    public var excludedApplicationNames: Set<String>
    public var excludedBundleIdentifiers: Set<String>
    public var captureText: Bool
    public var captureURLs: Bool
    public var captureFiles: Bool
    public var captureImages: Bool
    public var blockLikelySensitiveText: Bool
    public var runLocalOCRAfterImageCapture: Bool
    public var customCaptureRules: [CaptureRule]

    public static let defaultExcludedApplicationNames: Set<String> = ["1Password", "Passwords", "Keychain Access"]
    public static let defaultExcludedBundleIdentifiers: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "com.bitwarden.desktop"
    ]

    public init(
        isCapturePaused: Bool = false,
        capturePauseUntil: Date? = nil,
        excludedApplicationNames: Set<String> = PrivacyConfiguration.defaultExcludedApplicationNames,
        excludedBundleIdentifiers: Set<String> = PrivacyConfiguration.defaultExcludedBundleIdentifiers,
        captureText: Bool = true,
        captureURLs: Bool = true,
        captureFiles: Bool = true,
        captureImages: Bool = true,
        blockLikelySensitiveText: Bool = true,
        runLocalOCRAfterImageCapture: Bool = true,
        customCaptureRules: [CaptureRule] = []
    ) {
        self.isCapturePaused = isCapturePaused
        self.capturePauseUntil = capturePauseUntil
        self.excludedApplicationNames = excludedApplicationNames
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
        self.captureText = captureText
        self.captureURLs = captureURLs
        self.captureFiles = captureFiles
        self.captureImages = captureImages
        self.blockLikelySensitiveText = blockLikelySensitiveText
        self.runLocalOCRAfterImageCapture = runLocalOCRAfterImageCapture
        self.customCaptureRules = customCaptureRules
    }

    public func isCaptureCurrentlyPaused(now: Date = Date()) -> Bool {
        isCapturePaused || activePauseUntil(now: now) != nil
    }

    public func activePauseUntil(now: Date = Date()) -> Date? {
        guard let capturePauseUntil, capturePauseUntil > now else { return nil }
        return capturePauseUntil
    }

    public func allowsCapture(of contentType: ClipboardContentType) -> Bool {
        switch contentType {
        case .text:
            captureText
        case .url:
            captureURLs
        case .file:
            captureFiles
        case .image:
            captureImages
        case .mixed:
            captureText || captureURLs || captureFiles || captureImages
        }
    }

    public func blocksLikelySensitiveText(_ text: String) -> Bool {
        blockLikelySensitiveText && SensitiveContentDetector.isLikelySensitive(text)
    }

    public func blockingCaptureRule(
        for item: ClipboardItem,
        sourceBundleIdentifier: String? = nil
    ) -> CaptureRule? {
        customCaptureRules.first { rule in
            rule.matches(item, sourceBundleIdentifier: sourceBundleIdentifier)
        }
    }

    public func excludesApplication(named appName: String, bundleIdentifier: String?) -> Bool {
        let trimmedName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty, excludedApplicationNames.contains(trimmedName) {
            return true
        }

        let trimmedBundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedBundleIdentifier, !trimmedBundleIdentifier.isEmpty {
            return excludedBundleIdentifiers.contains(trimmedBundleIdentifier)
        }

        return false
    }

    private enum CodingKeys: String, CodingKey {
        case isCapturePaused
        case capturePauseUntil
        case excludedApplicationNames
        case excludedBundleIdentifiers
        case captureText
        case captureURLs
        case captureFiles
        case captureImages
        case blockLikelySensitiveText
        case runLocalOCRAfterImageCapture
        case customCaptureRules
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isCapturePaused = try container.decodeIfPresent(Bool.self, forKey: .isCapturePaused) ?? false
        capturePauseUntil = try container.decodeIfPresent(Date.self, forKey: .capturePauseUntil)
        excludedApplicationNames = try container.decodeIfPresent(Set<String>.self, forKey: .excludedApplicationNames) ?? Self.defaultExcludedApplicationNames
        excludedBundleIdentifiers = try container.decodeIfPresent(Set<String>.self, forKey: .excludedBundleIdentifiers) ?? Self.defaultExcludedBundleIdentifiers
        captureText = try container.decodeIfPresent(Bool.self, forKey: .captureText) ?? true
        captureURLs = try container.decodeIfPresent(Bool.self, forKey: .captureURLs) ?? true
        captureFiles = try container.decodeIfPresent(Bool.self, forKey: .captureFiles) ?? true
        captureImages = try container.decodeIfPresent(Bool.self, forKey: .captureImages) ?? true
        blockLikelySensitiveText = try container.decodeIfPresent(Bool.self, forKey: .blockLikelySensitiveText) ?? true
        runLocalOCRAfterImageCapture = try container.decodeIfPresent(Bool.self, forKey: .runLocalOCRAfterImageCapture) ?? true
        customCaptureRules = try container.decodeIfPresent([CaptureRule].self, forKey: .customCaptureRules) ?? []
    }
}

public enum PrivacyCaptureBlockReason: Equatable, Sendable {
    case capturePaused(until: Date?)
    case sourceApplicationExcluded(name: String, bundleIdentifier: String?)
    case contentTypeDisabled(ClipboardContentType)
    case sensitiveText
    case customCaptureRule(CaptureRule)

    public var displayName: String {
        switch self {
        case .capturePaused:
            "Capture Paused"
        case .sourceApplicationExcluded:
            "Excluded App"
        case .contentTypeDisabled(let type):
            "\(type.displayName) Disabled"
        case .sensitiveText:
            "Sensitive Text"
        case .customCaptureRule(let rule):
            rule.name
        }
    }

    public var userMessage: String {
        switch self {
        case .capturePaused(let until):
            if until != nil {
                return "Capture is paused until the selected time."
            }
            return "Capture is paused until you resume it."
        case .sourceApplicationExcluded(let name, let bundleIdentifier):
            let app = name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? bundleIdentifier ?? "this app"
            return "PasteBuddy did not save content from \(app) because it is excluded locally."
        case .contentTypeDisabled(let type):
            return "\(type.displayName) capture is disabled in PasteBuddy privacy settings."
        case .sensitiveText:
            return "PasteBuddy blocked this item because the text looks sensitive."
        case .customCaptureRule(let rule):
            return "PasteBuddy blocked this item because it matched the local capture rule \"\(rule.name)\"."
        }
    }
}

public struct PrivacyCaptureDecision: Equatable, Sendable {
    public var blockReason: PrivacyCaptureBlockReason?

    public init(blockReason: PrivacyCaptureBlockReason? = nil) {
        self.blockReason = blockReason
    }

    public var isAllowed: Bool {
        blockReason == nil
    }

    public var userMessage: String {
        blockReason?.userMessage ?? "Allowed by local privacy rules."
    }
}

public extension PrivacyConfiguration {
    func captureDecision(
        for item: ClipboardItem,
        sourceApplicationName: String? = nil,
        sourceBundleIdentifier: String? = nil,
        includePause: Bool = false,
        now: Date = Date()
    ) -> PrivacyCaptureDecision {
        if includePause, isCaptureCurrentlyPaused(now: now) {
            return PrivacyCaptureDecision(blockReason: .capturePaused(until: activePauseUntil(now: now)))
        }

        if let sourceApplicationName,
           excludesApplication(named: sourceApplicationName, bundleIdentifier: sourceBundleIdentifier) {
            return PrivacyCaptureDecision(
                blockReason: .sourceApplicationExcluded(name: sourceApplicationName, bundleIdentifier: sourceBundleIdentifier)
            )
        }

        guard allowsCapture(of: item.contentType) else {
            return PrivacyCaptureDecision(blockReason: .contentTypeDisabled(item.contentType))
        }

        if blocksLikelySensitiveText(item.payload.searchableText) {
            return PrivacyCaptureDecision(blockReason: .sensitiveText)
        }

        if let rule = blockingCaptureRule(for: item, sourceBundleIdentifier: sourceBundleIdentifier) {
            return PrivacyCaptureDecision(blockReason: .customCaptureRule(rule))
        }

        return PrivacyCaptureDecision()
    }
}

public enum SyncProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case none
    case cloudKit

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: "Local Only"
        case .cloudKit: "CloudKit"
        }
    }
}

public enum SyncRequirement: String, CaseIterable, Codable, Equatable, Sendable {
    case explicitCloudSyncOptIn
    case cloudKitContainerIdentifier
    case endToEndKeyHierarchy
    case cloudKitCapability

    public var displayName: String {
        switch self {
        case .explicitCloudSyncOptIn: "Explicit CloudKit sync opt-in"
        case .cloudKitContainerIdentifier: "CloudKit container identifier"
        case .endToEndKeyHierarchy: "End-to-end encryption key hierarchy"
        case .cloudKitCapability: "Signed app with CloudKit capability"
        }
    }
}

public enum SyncReadiness: Equatable, Sendable {
    case localOnly
    case blocked([SyncRequirement])
    case ready

    public var canAttemptCloudSync: Bool {
        self == .ready
    }

    public var displayName: String {
        switch self {
        case .localOnly: "Local only"
        case .blocked: "Setup required"
        case .ready: "CloudKit sync ready"
        }
    }

    public var detail: String {
        switch self {
        case .localOnly:
            "Sync is off. Clipboard data stays on this Mac."
        case .blocked(let requirements):
            "Cloud sync is blocked until: \(requirements.map(\.displayName).joined(separator: ", "))."
        case .ready:
            "CloudKit sync is ready to use private iCloud records."
        }
    }
}

public enum CloudSyncDiagnosticSeverity: String, CaseIterable, Codable, Equatable, Sendable {
    case info
    case warning
    case blocker

    public var displayName: String {
        switch self {
        case .info: "Info"
        case .warning: "Warning"
        case .blocker: "Action required"
        }
    }
}

public struct CloudSyncDiagnosticFinding: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var severity: CloudSyncDiagnosticSeverity
    public var title: String
    public var detail: String
    public var recoveryAction: String

    public init(
        id: String,
        severity: CloudSyncDiagnosticSeverity,
        title: String,
        detail: String,
        recoveryAction: String
    ) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
        self.recoveryAction = recoveryAction
    }
}

public struct CloudSyncPreflightReport: Equatable, Sendable {
    public var readiness: SyncReadiness
    public var findings: [CloudSyncDiagnosticFinding]

    public init(configuration: SyncConfiguration) {
        readiness = configuration.readiness
        findings = Self.makeFindings(for: configuration, readiness: readiness)
    }

    public var canAttemptCloudSync: Bool {
        readiness.canAttemptCloudSync && !hasBlockers
    }

    public var hasBlockers: Bool {
        findings.contains { $0.severity == .blocker }
    }

    public var summary: String {
        if case .localOnly = readiness {
            return "Local only: CloudKit sync is disabled."
        }
        let blockers = findings.filter { $0.severity == .blocker }.count
        if blockers > 0 {
            return "CloudKit sync is blocked by \(blockers) required setup item\(blockers == 1 ? "" : "s")."
        }
        let warnings = findings.filter { $0.severity == .warning }.count
        if warnings > 0 {
            return "Encrypted CloudKit sync is ready with \(warnings) warning\(warnings == 1 ? "" : "s")."
        }
        return "Encrypted CloudKit sync is ready."
    }

    private static func makeFindings(
        for configuration: SyncConfiguration,
        readiness: SyncReadiness
    ) -> [CloudSyncDiagnosticFinding] {
        var findings: [CloudSyncDiagnosticFinding] = []

        switch readiness {
        case .localOnly:
            findings.append(CloudSyncDiagnosticFinding(
                id: "cloud-sync-local-only",
                severity: .info,
                title: "CloudKit sync is off",
                detail: "Clipboard history, OCR metadata, images, files, and pinboards remain on this device.",
                recoveryAction: "Enable CloudKit sync only when the user explicitly wants cross-device iCloud access."
            ))
        case .blocked(let requirements):
            findings.append(contentsOf: requirements.map(finding(for:)))
        case .ready:
            findings.append(CloudSyncDiagnosticFinding(
                id: "cloud-sync-ready",
                severity: .info,
                title: "CloudKit sync can run",
                detail: "Readiness gates are satisfied for the user's private iCloud database.",
                recoveryAction: "Upload and download private CloudKit snapshot records."
            ))
        }

        if configuration.isSharedPinboardsEnabled, !readiness.canAttemptCloudSync {
            findings.append(CloudSyncDiagnosticFinding(
                id: "shared-pinboards-blocked",
                severity: .blocker,
                title: "Shared pinboards need ready CloudKit sync",
                detail: "Invitation packages and shared pinboard metadata must not be sent before CloudKit is ready.",
                recoveryAction: "Finish CloudKit container and signing setup before enabling shared pinboards."
            ))
        }

        if configuration.lastSyncConflictCount > 0 {
            findings.append(CloudSyncDiagnosticFinding(
                id: "last-sync-conflicts",
                severity: .warning,
                title: "Last sync reported merge conflicts",
                detail: "\(configuration.lastSyncConflictCount) item or pinboard conflict\(configuration.lastSyncConflictCount == 1 ? " was" : "s were") resolved by timestamp.",
                recoveryAction: "Review recently changed history items and pinboards before uploading another package."
            ))
        }

        if readiness.canAttemptCloudSync, configuration.lastSyncAt == nil {
            findings.append(CloudSyncDiagnosticFinding(
                id: "first-sync-pending",
                severity: .warning,
                title: "First CloudKit sync has not completed",
                detail: "The configuration is ready, but this device has not recorded a successful upload or import yet.",
                recoveryAction: "Run the first upload/download after signed CloudKit account access is available."
            ))
        }

        return findings
    }

    private static func finding(for requirement: SyncRequirement) -> CloudSyncDiagnosticFinding {
        switch requirement {
        case .explicitCloudSyncOptIn:
            CloudSyncDiagnosticFinding(
                id: "missing-explicit-cloudkit-opt-in",
                severity: .blocker,
                title: "Explicit CloudKit opt-in missing",
                detail: "Cloud sync must remain local-only until the user enables it.",
                recoveryAction: "Enable CloudKit sync from Settings after explaining that records are stored in the user's private iCloud database."
            )
        case .cloudKitContainerIdentifier:
            CloudSyncDiagnosticFinding(
                id: "missing-cloudkit-container",
                severity: .blocker,
                title: "CloudKit container identifier missing",
                detail: "The app cannot address the user's private iCloud database without a configured container.",
                recoveryAction: "Configure the signed app target with the PasteBuddy iCloud container identifier."
            )
        case .endToEndKeyHierarchy:
            CloudSyncDiagnosticFinding(
                id: "missing-end-to-end-key-hierarchy",
                severity: .blocker,
                title: "End-to-end key hierarchy missing",
                detail: "Encrypted sync packages require a positive key hierarchy version.",
                recoveryAction: "Provision or migrate the local key hierarchy before creating CloudKit packages."
            )
        case .cloudKitCapability:
            CloudSyncDiagnosticFinding(
                id: "missing-cloudkit-capability",
                severity: .blocker,
                title: "Signed CloudKit capability not verified",
                detail: "The SwiftPM build can model sync, but production CloudKit access needs signed entitlements.",
                recoveryAction: "Add iCloud/CloudKit entitlements to the app target and verify account access in a signed build."
            )
        }
    }
}

public struct SyncConfiguration: Codable, Equatable, Sendable {
    public var provider: SyncProvider
    public var isCloudSyncEnabled: Bool
    public var isSharedPinboardsEnabled: Bool
    public var cloudKitContainerIdentifier: String?
    public var keyHierarchyVersion: Int?
    public var isCloudKitCapabilityConfigured: Bool
    public var lastSyncAt: Date?
    public var lastImportedPackageID: UUID?
    public var lastSyncConflictCount: Int
    public var lastSyncStatusMessage: String?

    public init(
        provider: SyncProvider = .none,
        isCloudSyncEnabled: Bool = false,
        isSharedPinboardsEnabled: Bool = false,
        cloudKitContainerIdentifier: String? = nil,
        keyHierarchyVersion: Int? = nil,
        isCloudKitCapabilityConfigured: Bool = false,
        lastSyncAt: Date? = nil,
        lastImportedPackageID: UUID? = nil,
        lastSyncConflictCount: Int = 0,
        lastSyncStatusMessage: String? = nil
    ) {
        self.provider = provider
        self.isCloudSyncEnabled = isCloudSyncEnabled
        self.isSharedPinboardsEnabled = isSharedPinboardsEnabled
        self.cloudKitContainerIdentifier = cloudKitContainerIdentifier
        self.keyHierarchyVersion = keyHierarchyVersion
        self.isCloudKitCapabilityConfigured = isCloudKitCapabilityConfigured
        self.lastSyncAt = lastSyncAt
        self.lastImportedPackageID = lastImportedPackageID
        self.lastSyncConflictCount = lastSyncConflictCount
        self.lastSyncStatusMessage = lastSyncStatusMessage
    }

    public var allowsPlaintextFallback: Bool {
        false
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case isCloudSyncEnabled
        case isSharedPinboardsEnabled
        case cloudKitContainerIdentifier
        case keyHierarchyVersion
        case isCloudKitCapabilityConfigured
        case lastSyncAt
        case lastImportedPackageID
        case lastSyncConflictCount
        case lastSyncStatusMessage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(SyncProvider.self, forKey: .provider) ?? .none
        isCloudSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .isCloudSyncEnabled) ?? false
        isSharedPinboardsEnabled = try container.decodeIfPresent(Bool.self, forKey: .isSharedPinboardsEnabled) ?? false
        cloudKitContainerIdentifier = try container.decodeIfPresent(String.self, forKey: .cloudKitContainerIdentifier)
        keyHierarchyVersion = try container.decodeIfPresent(Int.self, forKey: .keyHierarchyVersion)
        isCloudKitCapabilityConfigured = try container.decodeIfPresent(Bool.self, forKey: .isCloudKitCapabilityConfigured) ?? false
        lastSyncAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncAt)
        lastImportedPackageID = try container.decodeIfPresent(UUID.self, forKey: .lastImportedPackageID)
        lastSyncConflictCount = try container.decodeIfPresent(Int.self, forKey: .lastSyncConflictCount) ?? 0
        lastSyncStatusMessage = try container.decodeIfPresent(String.self, forKey: .lastSyncStatusMessage)
    }

    public var readiness: SyncReadiness {
        if provider == .none, !isCloudSyncEnabled, !isSharedPinboardsEnabled {
            return .localOnly
        }

        var missing: [SyncRequirement] = []
        if provider != .cloudKit || !isCloudSyncEnabled {
            missing.append(.explicitCloudSyncOptIn)
        }
        if cloudKitContainerIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            missing.append(.cloudKitContainerIdentifier)
        }
        if keyHierarchyVersion ?? 0 < 1 {
            missing.append(.endToEndKeyHierarchy)
        }
        if !isCloudKitCapabilityConfigured {
            missing.append(.cloudKitCapability)
        }

        return missing.isEmpty ? .ready : .blocked(missing)
    }
}

public struct StorageConfiguration: Codable, Equatable, Sendable {
    public var retentionDays: Int
    public var maxStorageBytes: Int

    public init(
        retentionDays: Int = 90,
        maxStorageBytes: Int = 512 * 1_024 * 1_024
    ) {
        self.retentionDays = Self.clampRetentionDays(retentionDays)
        self.maxStorageBytes = Self.clampMaxStorageBytes(maxStorageBytes)
    }

    private enum CodingKeys: String, CodingKey {
        case retentionDays
        case maxStorageBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        retentionDays = Self.clampRetentionDays(
            try container.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 90
        )
        maxStorageBytes = Self.clampMaxStorageBytes(
            try container.decodeIfPresent(Int.self, forKey: .maxStorageBytes) ?? 512 * 1_024 * 1_024
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(retentionDays, forKey: .retentionDays)
        try container.encode(maxStorageBytes, forKey: .maxStorageBytes)
    }

    public var keepsHistoryForever: Bool {
        retentionDays == 0
    }

    public static func clampRetentionDays(_ value: Int) -> Int {
        min(max(value, 0), 3_650)
    }

    public static func clampMaxStorageBytes(_ value: Int) -> Int {
        min(max(value, 1 * 1_024 * 1_024), 100 * 1_024 * 1_024 * 1_024)
    }
}

public struct StorageUsageReport: Codable, Equatable, Sendable {
    public var itemCount: Int
    public var pinnedItemCount: Int
    public var unpinnedItemCount: Int
    public var estimatedBytes: Int
    public var pinnedEstimatedBytes: Int
    public var unpinnedEstimatedBytes: Int
    public var maxStorageBytes: Int

    public init(
        itemCount: Int,
        pinnedItemCount: Int,
        unpinnedItemCount: Int,
        estimatedBytes: Int,
        pinnedEstimatedBytes: Int,
        unpinnedEstimatedBytes: Int,
        maxStorageBytes: Int
    ) {
        self.itemCount = itemCount
        self.pinnedItemCount = pinnedItemCount
        self.unpinnedItemCount = unpinnedItemCount
        self.estimatedBytes = estimatedBytes
        self.pinnedEstimatedBytes = pinnedEstimatedBytes
        self.unpinnedEstimatedBytes = unpinnedEstimatedBytes
        self.maxStorageBytes = StorageConfiguration.clampMaxStorageBytes(maxStorageBytes)
    }

    public var usageFraction: Double {
        guard maxStorageBytes > 0 else { return 0 }
        return min(Double(estimatedBytes) / Double(maxStorageBytes), 1)
    }

    public var isOverLimit: Bool {
        estimatedBytes > maxStorageBytes
    }
}

public struct PasteConfiguration: Codable, Equatable, Sendable {
    public var alwaysPasteAsPlainText: Bool

    public init(alwaysPasteAsPlainText: Bool = false) {
        self.alwaysPasteAsPlainText = alwaysPasteAsPlainText
    }
}

public enum PasteDestination: String, CaseIterable, Codable, Identifiable, Sendable {
    case activeApplication
    case clipboard

    public var id: String { rawValue }
}

public struct SettingsBehaviorConfiguration: Codable, Equatable, Sendable {
    public var pasteDestination: PasteDestination
    public var soundEffectsEnabled: Bool
    public var showDuringScreenSharing: Bool
    public var generateLinkPreviews: Bool
    public var ignoreTransientContent: Bool
    public var ignoreRemoteClipboardContent: Bool
    public var ignoreConcealedContent: Bool
    public var ignoreAutoGeneratedContent: Bool
    public var ignoreWhitespaceOnlyContent: Bool
    public var convertLargeExcelContentToPlainText: Bool
    public var maximumClipboardSizeMegabytes: Double

    public init(
        pasteDestination: PasteDestination = .activeApplication,
        soundEffectsEnabled: Bool = true,
        showDuringScreenSharing: Bool = false,
        generateLinkPreviews: Bool = true,
        ignoreTransientContent: Bool = true,
        ignoreRemoteClipboardContent: Bool = true,
        ignoreConcealedContent: Bool = true,
        ignoreAutoGeneratedContent: Bool = true,
        ignoreWhitespaceOnlyContent: Bool = true,
        convertLargeExcelContentToPlainText: Bool = true,
        maximumClipboardSizeMegabytes: Double = 0
    ) {
        self.pasteDestination = pasteDestination
        self.soundEffectsEnabled = soundEffectsEnabled
        self.showDuringScreenSharing = showDuringScreenSharing
        self.generateLinkPreviews = generateLinkPreviews
        self.ignoreTransientContent = ignoreTransientContent
        self.ignoreRemoteClipboardContent = ignoreRemoteClipboardContent
        self.ignoreConcealedContent = ignoreConcealedContent
        self.ignoreAutoGeneratedContent = ignoreAutoGeneratedContent
        self.ignoreWhitespaceOnlyContent = ignoreWhitespaceOnlyContent
        self.convertLargeExcelContentToPlainText = convertLargeExcelContentToPlainText
        self.maximumClipboardSizeMegabytes = max(0, maximumClipboardSizeMegabytes)
    }

    private enum CodingKeys: String, CodingKey {
        case pasteDestination
        case soundEffectsEnabled
        case showDuringScreenSharing
        case generateLinkPreviews
        case ignoreTransientContent
        case ignoreRemoteClipboardContent
        case ignoreConcealedContent
        case ignoreAutoGeneratedContent
        case ignoreWhitespaceOnlyContent
        case convertLargeExcelContentToPlainText
        case maximumClipboardSizeMegabytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pasteDestination = try container.decodeIfPresent(PasteDestination.self, forKey: .pasteDestination)
            ?? .activeApplication
        soundEffectsEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundEffectsEnabled) ?? true
        showDuringScreenSharing = try container.decodeIfPresent(Bool.self, forKey: .showDuringScreenSharing) ?? false
        generateLinkPreviews = try container.decodeIfPresent(Bool.self, forKey: .generateLinkPreviews) ?? true
        ignoreTransientContent = try container.decodeIfPresent(Bool.self, forKey: .ignoreTransientContent) ?? true
        ignoreRemoteClipboardContent = try container.decodeIfPresent(Bool.self, forKey: .ignoreRemoteClipboardContent) ?? true
        ignoreConcealedContent = try container.decodeIfPresent(Bool.self, forKey: .ignoreConcealedContent) ?? true
        ignoreAutoGeneratedContent = try container.decodeIfPresent(Bool.self, forKey: .ignoreAutoGeneratedContent) ?? true
        ignoreWhitespaceOnlyContent = try container.decodeIfPresent(Bool.self, forKey: .ignoreWhitespaceOnlyContent) ?? true
        convertLargeExcelContentToPlainText = try container.decodeIfPresent(
            Bool.self,
            forKey: .convertLargeExcelContentToPlainText
        ) ?? true
        let decodedMaximumSize = try container.decodeIfPresent(
            Double.self,
            forKey: .maximumClipboardSizeMegabytes
        ) ?? 0
        maximumClipboardSizeMegabytes = decodedMaximumSize.isFinite ? max(0, decodedMaximumSize) : 0
    }
}

public enum PasteFormat: String, Codable, Equatable, Sendable {
    case original
    case plainText
}

public enum DirectPasteOutcome: String, Codable, Sendable {
    case pastedToFrontmostApp
    case copiedToClipboard
    case failedAccessibilityPermissionRequired
    case failedNoTargetApplication
    case failedPasteboardWrite
    case copiedOnlyAccessibilityRequired
    case copiedOnlyNoTargetApplication
    case emptySelection

    public var displayName: String {
        switch self {
        case .pastedToFrontmostApp: "Paste sent to active app"
        case .copiedToClipboard:
            PasteBuddyLocalization.string(
                "message.copied_to_clipboard_title",
                defaultValue: "Copied to clipboard"
            )
        case .failedAccessibilityPermissionRequired: "Paste failed - Accessibility access required"
        case .failedNoTargetApplication: "Paste failed - no target app available"
        case .failedPasteboardWrite:
            PasteBuddyLocalization.string(
                "message.direct_paste_clipboard_payload_unavailable_title",
                defaultValue: "Paste failed - clipboard payload unavailable"
            )
        case .copiedOnlyAccessibilityRequired: "Copied only - Accessibility access required"
        case .copiedOnlyNoTargetApplication: "Copied only - no target app available"
        case .emptySelection: "No PasteBuddy items selected"
        }
    }
}

public struct DirectPastePermissionGuidance: Codable, Equatable, Sendable {
    public var title: String
    public var detail: String
    public var actionTitle: String

    public init(
        title: String = "Accessibility access required for automatic paste",
        detail: String = "PasteBuddy copied your selection. macOS requires Accessibility access before PasteBuddy can send Command-V into the active app. You can paste manually now with Command-V, or grant access to enable direct paste.",
        actionTitle: String = "Request Accessibility Access"
    ) {
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
    }
}

public struct DirectPasteResult: Codable, Equatable, Sendable {
    public var outcome: DirectPasteOutcome
    public var itemCount: Int
    public var format: PasteFormat
    public var occurredAt: Date

    public init(
        outcome: DirectPasteOutcome,
        itemCount: Int,
        format: PasteFormat,
        occurredAt: Date = Date()
    ) {
        self.outcome = outcome
        self.itemCount = max(0, itemCount)
        self.format = format
        self.occurredAt = occurredAt
    }

    public var needsAccessibilityPermission: Bool {
        outcome == .copiedOnlyAccessibilityRequired || outcome == .failedAccessibilityPermissionRequired
    }

    public var didTransferContent: Bool {
        switch outcome {
        case .pastedToFrontmostApp, .copiedToClipboard, .copiedOnlyAccessibilityRequired,
             .copiedOnlyNoTargetApplication:
            true
        case .failedAccessibilityPermissionRequired, .failedNoTargetApplication,
             .failedPasteboardWrite, .emptySelection:
            false
        }
    }

    public var permissionGuidance: DirectPastePermissionGuidance? {
        switch outcome {
        case .copiedOnlyAccessibilityRequired:
            DirectPastePermissionGuidance()
        case .failedAccessibilityPermissionRequired:
            DirectPastePermissionGuidance(
                title: "Accessibility access required for direct paste",
                detail: "macOS requires Accessibility access before PasteBuddy can send Command-V into the active app. PasteBuddy did not modify the clipboard.",
                actionTitle: "Request Accessibility Access"
            )
        case .pastedToFrontmostApp, .copiedToClipboard, .failedNoTargetApplication, .failedPasteboardWrite,
             .copiedOnlyNoTargetApplication, .emptySelection:
            nil
        }
    }

    public var statusMessage: String {
        switch outcome {
        case .pastedToFrontmostApp:
            itemCount == 1 ? "Pasted 1 item to the active app." : "Pasted \(itemCount) items to the active app."
        case .copiedToClipboard:
            itemCount == 1
                ? PasteBuddyLocalization.string(
                    "message.copied_one_item_to_clipboard",
                    defaultValue: "Copied 1 item to the clipboard."
                )
                : PasteBuddyLocalization.format(
                    "format.copied_items_to_clipboard",
                    defaultValue: "Copied %d items to the clipboard.",
                    itemCount
                )
        case .failedAccessibilityPermissionRequired:
            itemCount == 1
                ? "Paste was not sent. Grant Accessibility access to paste automatically."
                : "Paste was not sent for \(itemCount) items. Grant Accessibility access to paste automatically."
        case .failedNoTargetApplication:
            itemCount == 1
                ? "Paste was not sent. Focus a target app before using direct paste."
                : "Paste was not sent for \(itemCount) items. Focus a target app before using direct paste."
        case .failedPasteboardWrite:
            itemCount == 1
                ? PasteBuddyLocalization.string(
                    "message.direct_paste_clipboard_payload_unavailable",
                    defaultValue: "Paste was not sent because the clipboard payload was unavailable."
                )
                : PasteBuddyLocalization.format(
                    "format.direct_paste_clipboard_payloads_unavailable",
                    defaultValue: "Paste was not sent for %d items because the clipboard payload was unavailable.",
                    itemCount
                )
        case .copiedOnlyAccessibilityRequired:
            itemCount == 1
                ? "Copied 1 item. Grant Accessibility access to paste automatically."
                : "Copied \(itemCount) items. Grant Accessibility access to paste automatically."
        case .copiedOnlyNoTargetApplication:
            itemCount == 1
                ? "Copied 1 item. Focus a target app before using direct paste."
                : "Copied \(itemCount) items. Focus a target app before using direct paste."
        case .emptySelection:
            "Select at least one clipboard item before direct paste."
        }
    }
}

public enum ShortcutModifier: String, CaseIterable, Codable, Sendable {
    case command
    case option
    case shift
    case control

    public var sortOrder: Int {
        switch self {
        case .control: 0
        case .option: 1
        case .shift: 2
        case .command: 3
        }
    }

    public var displayName: String {
        switch self {
        case .command: "⌘"
        case .option: "⌥"
        case .shift: "⇧"
        case .control: "⌃"
        }
    }
}

public enum ShortcutAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case showHidePanel
    case activatePasteStack
    case showNextPinboard
    case showPreviousPinboard
    case pasteNextStackItem
    case pasteSelectedItem
    case pasteSelectedPlainText

    public var id: String { rawValue }

    public func sharesShortcutScope(with other: ShortcutAction) -> Bool {
        isGlobalHotKey == other.isGlobalHotKey
    }

    private var isGlobalHotKey: Bool {
        switch self {
        case .showHidePanel, .activatePasteStack, .showNextPinboard, .showPreviousPinboard:
            true
        case .pasteNextStackItem, .pasteSelectedItem, .pasteSelectedPlainText:
            false
        }
    }

    public var displayName: String {
        switch self {
        case .showHidePanel: "Show/Hide Panel"
        case .activatePasteStack:
            PasteBuddyLocalization.string("label.activate_paste_stack", defaultValue: "Activate Paste Stack")
        case .showNextPinboard:
            PasteBuddyLocalization.string("label.show_next_pinboard", defaultValue: "Show Next Pinboard")
        case .showPreviousPinboard:
            PasteBuddyLocalization.string("label.show_previous_pinboard", defaultValue: "Show Previous Pinboard")
        case .pasteNextStackItem: "Paste Next Stack Item"
        case .pasteSelectedItem: "Paste Selected"
        case .pasteSelectedPlainText: "Paste Selected Plain Text"
        }
    }
}

public struct ShortcutBinding: Codable, Equatable, Sendable {
    public var key: String?
    public var modifiers: [ShortcutModifier]
    public var keyCode: UInt16?

    public init(key: String?, modifiers: [ShortcutModifier], keyCode: UInt16? = nil) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            self.key = String(trimmed.prefix(1)).lowercased()
        } else {
            self.key = nil
        }
        self.modifiers = Self.normalizedModifiers(modifiers)
        self.keyCode = keyCode
    }

    public var isEnabled: Bool {
        key?.isEmpty == false
    }

    public var isValidUserShortcut: Bool {
        guard isEnabled else { return true }
        let normalizedModifiers = Self.normalizedModifiers(modifiers)
        guard !normalizedModifiers.isEmpty,
              normalizedModifiers.contains(.command) || normalizedModifiers.contains(.control) else {
            return false
        }
        return !normalizedModifiers.contains(.command)
            || ![UInt16(12), UInt16(13)].contains(effectivePhysicalKeyCode)
    }

    public var isValidShowHidePanelShortcut: Bool {
        guard isValidUserShortcut else { return false }
        guard isEnabled else { return true }
        guard Self.normalizedModifiers(modifiers).count >= 2 else { return false }
        return !conflictsWithFixedProductShortcut
    }

    public var conflictsWithFixedProductShortcut: Bool {
        Self.normalizedModifiers(modifiers) == [.shift, .command]
            && [UInt16(1), UInt16(35)].contains(effectivePhysicalKeyCode)
    }

    public func conflicts(with other: ShortcutBinding) -> Bool {
        guard isEnabled, other.isEnabled,
              Self.normalizedModifiers(modifiers) == Self.normalizedModifiers(other.modifiers) else {
            return false
        }
        if let effectivePhysicalKeyCode, let otherKeyCode = other.effectivePhysicalKeyCode {
            return effectivePhysicalKeyCode == otherKeyCode
        }
        return key == other.key
    }

    public var effectivePhysicalKeyCode: UInt16? {
        keyCode ?? key.flatMap { Self.legacyANSIKeyCodes[$0] }
    }

    public var displayName: String {
        guard let key, !key.isEmpty else { return "Not set" }
        let keyDisplayName = switch effectivePhysicalKeyCode {
        case 123: "←"
        case 124: "→"
        default: key.uppercased()
        }
        return (Self.normalizedModifiers(modifiers).map(\.displayName) + [keyDisplayName]).joined()
    }

    public static func normalizedModifiers(_ modifiers: [ShortcutModifier]) -> [ShortcutModifier] {
        Array(Set(modifiers)).sorted { $0.sortOrder < $1.sortOrder }
    }

    private static let legacyANSIKeyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]
}

public struct ShortcutConfiguration: Codable, Equatable, Sendable {
    public var isQuickPasteEnabled: Bool
    public var showHidePanel: ShortcutBinding
    public var activatePasteStack: ShortcutBinding
    public var showNextPinboard: ShortcutBinding
    public var showPreviousPinboard: ShortcutBinding
    public var pasteNextStackItem: ShortcutBinding
    public var pasteSelectedItem: ShortcutBinding
    public var pasteSelectedPlainText: ShortcutBinding
    public var quickPasteModifiers: [ShortcutModifier]
    public var plainTextQuickPasteModifiers: [ShortcutModifier]

    public init(
        isQuickPasteEnabled: Bool = true,
        showHidePanel: ShortcutBinding = ShortcutBinding(key: "v", modifiers: [.command, .shift]),
        activatePasteStack: ShortcutBinding = ShortcutBinding(key: "c", modifiers: [.command, .shift]),
        showNextPinboard: ShortcutBinding = ShortcutBinding(key: "→", modifiers: [.command], keyCode: 124),
        showPreviousPinboard: ShortcutBinding = ShortcutBinding(key: "←", modifiers: [.command], keyCode: 123),
        pasteNextStackItem: ShortcutBinding = ShortcutBinding(key: "v", modifiers: [.command, .option]),
        pasteSelectedItem: ShortcutBinding = ShortcutBinding(key: "v", modifiers: [.command, .shift]),
        pasteSelectedPlainText: ShortcutBinding = ShortcutBinding(key: "v", modifiers: [.command, .control]),
        quickPasteModifiers: [ShortcutModifier] = [.command, .control],
        plainTextQuickPasteModifiers: [ShortcutModifier] = [.shift, .control]
    ) {
        self.isQuickPasteEnabled = isQuickPasteEnabled
        self.showHidePanel = showHidePanel
        self.activatePasteStack = activatePasteStack
        self.showNextPinboard = showNextPinboard
        self.showPreviousPinboard = showPreviousPinboard
        self.pasteNextStackItem = pasteNextStackItem
        self.pasteSelectedItem = pasteSelectedItem
        self.pasteSelectedPlainText = pasteSelectedPlainText
        self.quickPasteModifiers = ShortcutBinding.normalizedModifiers(quickPasteModifiers)
        self.plainTextQuickPasteModifiers = ShortcutBinding.normalizedModifiers(plainTextQuickPasteModifiers)
    }

    public var quickPasteDisplayName: String {
        modifiersDisplayName(quickPasteModifiers, digitRange: "1-9")
    }

    public var plainTextQuickPasteDisplayName: String {
        modifiersDisplayName(plainTextQuickPasteModifiers, digitRange: "1-9")
    }

    public func binding(for action: ShortcutAction) -> ShortcutBinding {
        switch action {
        case .showHidePanel: showHidePanel
        case .activatePasteStack: activatePasteStack
        case .showNextPinboard: showNextPinboard
        case .showPreviousPinboard: showPreviousPinboard
        case .pasteNextStackItem: pasteNextStackItem
        case .pasteSelectedItem: pasteSelectedItem
        case .pasteSelectedPlainText: pasteSelectedPlainText
        }
    }

    public mutating func setBinding(_ binding: ShortcutBinding, for action: ShortcutAction) {
        switch action {
        case .showHidePanel:
            showHidePanel = binding
        case .activatePasteStack:
            activatePasteStack = binding
        case .showNextPinboard:
            showNextPinboard = binding
        case .showPreviousPinboard:
            showPreviousPinboard = binding
        case .pasteNextStackItem:
            pasteNextStackItem = binding
        case .pasteSelectedItem:
            pasteSelectedItem = binding
        case .pasteSelectedPlainText:
            pasteSelectedPlainText = binding
        }
    }

    private func modifiersDisplayName(_ modifiers: [ShortcutModifier], digitRange: String) -> String {
        (ShortcutBinding.normalizedModifiers(modifiers).reversed().map(\.displayName) + [digitRange]).joined()
    }

    private enum CodingKeys: String, CodingKey {
        case isQuickPasteEnabled
        case showHidePanel
        case activatePasteStack
        case showNextPinboard
        case showPreviousPinboard
        case pasteNextStackItem
        case pasteSelectedItem
        case pasteSelectedPlainText
        case quickPasteModifiers
        case plainTextQuickPasteModifiers
    }

    public init(from decoder: Decoder) throws {
        let defaults = ShortcutConfiguration()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isQuickPasteEnabled = try container.decodeIfPresent(Bool.self, forKey: .isQuickPasteEnabled)
            ?? defaults.isQuickPasteEnabled
        showHidePanel = try container.decodeIfPresent(ShortcutBinding.self, forKey: .showHidePanel)
            ?? defaults.showHidePanel
        activatePasteStack = try container.decodeIfPresent(ShortcutBinding.self, forKey: .activatePasteStack)
            ?? defaults.activatePasteStack
        showNextPinboard = try container.decodeIfPresent(ShortcutBinding.self, forKey: .showNextPinboard)
            ?? defaults.showNextPinboard
        showPreviousPinboard = try container.decodeIfPresent(ShortcutBinding.self, forKey: .showPreviousPinboard)
            ?? defaults.showPreviousPinboard
        pasteNextStackItem = try container.decodeIfPresent(ShortcutBinding.self, forKey: .pasteNextStackItem)
            ?? defaults.pasteNextStackItem
        pasteSelectedItem = try container.decodeIfPresent(ShortcutBinding.self, forKey: .pasteSelectedItem)
            ?? defaults.pasteSelectedItem
        pasteSelectedPlainText = try container.decodeIfPresent(ShortcutBinding.self, forKey: .pasteSelectedPlainText)
            ?? defaults.pasteSelectedPlainText
        quickPasteModifiers = ShortcutBinding.normalizedModifiers(
            try container.decodeIfPresent([ShortcutModifier].self, forKey: .quickPasteModifiers)
                ?? defaults.quickPasteModifiers
        )
        plainTextQuickPasteModifiers = ShortcutBinding.normalizedModifiers(
            try container.decodeIfPresent(
                [ShortcutModifier].self,
                forKey: .plainTextQuickPasteModifiers
            ) ?? defaults.plainTextQuickPasteModifiers
        )
        if !Self.isSafeQuickPasteModifierFamily(quickPasteModifiers) {
            quickPasteModifiers = defaults.quickPasteModifiers
        }
        if !Self.isSafeQuickPasteModifierFamily(plainTextQuickPasteModifiers)
            || plainTextQuickPasteModifiers == quickPasteModifiers {
            plainTextQuickPasteModifiers = defaults.plainTextQuickPasteModifiers
        }
        for action in ShortcutAction.allCases {
            let binding = binding(for: action)
            guard binding.key.flatMap(Int.init).map({ (1...9).contains($0) }) == true,
                  ShortcutBinding.normalizedModifiers(binding.modifiers) == quickPasteModifiers
                    || ShortcutBinding.normalizedModifiers(binding.modifiers) == plainTextQuickPasteModifiers else { continue }
            setBinding(defaults.binding(for: action), for: action)
        }
    }

    private static func isSafeQuickPasteModifierFamily(_ modifiers: [ShortcutModifier]) -> Bool {
        modifiers.contains(.command) || modifiers.contains(.control)
    }
}

public enum MCPToolName: String, CaseIterable, Codable, Identifiable, Sendable {
    case searchHistory = "pastebuddy.search_history"
    case retrieveItem = "pastebuddy.retrieve_item"
    case listPinboards = "pastebuddy.list_pinboards"
    case createPinboard = "pastebuddy.create_pinboard"
    case pinFirstMatch = "pastebuddy.pin_first_match"
    case semanticSearchHistory = "pastebuddy.semantic_search_history"

    public var id: String { rawValue }

    public static var defaultEnabledTools: Set<MCPToolName> {
        [.searchHistory, .listPinboards, .createPinboard, .pinFirstMatch]
    }

    public var displayName: String {
        switch self {
        case .searchHistory: "Search Clipboard History"
        case .retrieveItem: "Retrieve Clipboard Item"
        case .listPinboards: "List Pinboards"
        case .createPinboard: "Create Pinboard"
        case .pinFirstMatch: "Pin First Matching Item"
        case .semanticSearchHistory:
            PasteBuddyLocalization.string(
                "mcp.semantic_search_history",
                defaultValue: "Semantic Search History"
            )
        }
    }
}

public enum MCPAccessOutcome: String, CaseIterable, Codable, Equatable, Sendable {
    case succeeded
    case denied
    case failed

    public var displayName: String {
        switch self {
        case .succeeded: "Succeeded"
        case .denied: "Denied"
        case .failed: "Failed"
        }
    }
}

public struct MCPAccessLogEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var accessedAt: Date
    public var tool: MCPToolName
    public var outcome: MCPAccessOutcome
    public var itemID: UUID?
    public var pinboardID: UUID?
    public var resultCount: Int?
    public var payloadIncluded: Bool
    public var imageDataIncluded: Bool

    public init(
        id: UUID = UUID(),
        accessedAt: Date = Date(),
        tool: MCPToolName,
        outcome: MCPAccessOutcome,
        itemID: UUID? = nil,
        pinboardID: UUID? = nil,
        resultCount: Int? = nil,
        payloadIncluded: Bool = false,
        imageDataIncluded: Bool = false
    ) {
        self.id = id
        self.accessedAt = accessedAt
        self.tool = tool
        self.outcome = outcome
        self.itemID = itemID
        self.pinboardID = pinboardID
        self.resultCount = resultCount
        self.payloadIncluded = payloadIncluded
        self.imageDataIncluded = imageDataIncluded
    }
}

public struct MCPConfiguration: Codable, Equatable, Sendable {
    public static let maxAccessLogEntries = 50

    public var isServerEnabled: Bool
    public var enabledTools: Set<MCPToolName>
    public var lastAccessRevokedAt: Date?
    public var accessLog: [MCPAccessLogEntry]

    public init(
        isServerEnabled: Bool = false,
        enabledTools: Set<MCPToolName> = MCPToolName.defaultEnabledTools,
        lastAccessRevokedAt: Date? = nil,
        accessLog: [MCPAccessLogEntry] = []
    ) {
        self.isServerEnabled = isServerEnabled
        self.enabledTools = enabledTools
        self.lastAccessRevokedAt = lastAccessRevokedAt
        self.accessLog = Array(accessLog.prefix(Self.maxAccessLogEntries))
    }

    private enum CodingKeys: String, CodingKey {
        case isServerEnabled
        case enabledTools
        case lastAccessRevokedAt
        case accessLog
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isServerEnabled = try container.decodeIfPresent(Bool.self, forKey: .isServerEnabled) ?? false
        let decodedTools = try container.decodeIfPresent(Set<MCPToolName>.self, forKey: .enabledTools) ?? MCPToolName.defaultEnabledTools
        enabledTools = Self.migratedEnabledTools(decodedTools)
        lastAccessRevokedAt = try container.decodeIfPresent(Date.self, forKey: .lastAccessRevokedAt)
        accessLog = Array((try container.decodeIfPresent([MCPAccessLogEntry].self, forKey: .accessLog) ?? []).prefix(Self.maxAccessLogEntries))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isServerEnabled, forKey: .isServerEnabled)
        try container.encode(enabledTools, forKey: .enabledTools)
        try container.encodeIfPresent(lastAccessRevokedAt, forKey: .lastAccessRevokedAt)
        try container.encode(Array(accessLog.prefix(Self.maxAccessLogEntries)), forKey: .accessLog)
    }

    public func isToolEnabled(_ tool: MCPToolName) -> Bool {
        isServerEnabled && enabledTools.contains(tool)
    }

    private static func migratedEnabledTools(_ tools: Set<MCPToolName>) -> Set<MCPToolName> {
        tools == Set(MCPToolName.allCases) ? MCPToolName.defaultEnabledTools : tools
    }
}

public enum SnapshotStorageMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case standard
    case encrypted

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .standard:
            "Standard Local Storage"
        case .encrypted:
            "Legacy Protected Storage"
        }
    }

    public var detail: String {
        switch self {
        case .standard:
            "Stores PasteBuddy history in the local Application Support folder."
        case .encrypted:
            "Legacy protected store support is kept only so older data can be migrated back to standard local storage."
        }
    }

    public var isEncrypted: Bool {
        self == .encrypted
    }
}

public struct SecurityConfiguration: Codable, Equatable, Sendable {
    public var storageMode: SnapshotStorageMode
    public var requiresBiometricUnlock: Bool
    public var biometricGracePeriodSeconds: TimeInterval

    public init(
        storageMode: SnapshotStorageMode = .standard,
        requiresBiometricUnlock: Bool = false,
        biometricGracePeriodSeconds: TimeInterval = 30
    ) {
        self.storageMode = storageMode
        self.requiresBiometricUnlock = requiresBiometricUnlock
        self.biometricGracePeriodSeconds = max(0, biometricGracePeriodSeconds)
    }

    public var securitySummary: String {
        if requiresBiometricUnlock {
            return "\(storageMode.displayName), Touch ID lock enabled"
        }
        return storageMode.displayName
    }
}

public struct PasteBuddySnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var items: [ClipboardItem]
    public var pinboards: [Pinboard]
    public var general: GeneralConfiguration
    public var entitlement: EntitlementConfiguration
    public var mobile: MobileIntegrationConfiguration
    public var privacy: PrivacyConfiguration
    public var sync: SyncConfiguration
    public var pinboardInvitationInbox: PinboardInvitationInbox
    public var storage: StorageConfiguration
    public var paste: PasteConfiguration
    public var settingsBehavior: SettingsBehaviorConfiguration
    public var shortcuts: ShortcutConfiguration
    public var mcp: MCPConfiguration
    public var semanticIndex: SemanticIndexConfiguration
    public var security: SecurityConfiguration

    public init(
        schemaVersion: Int = 1,
        items: [ClipboardItem] = [],
        pinboards: [Pinboard] = [Pinboard(name: "Favorites", colorHex: "#4EA7FC")],
        general: GeneralConfiguration = GeneralConfiguration(),
        entitlement: EntitlementConfiguration = EntitlementConfiguration(),
        mobile: MobileIntegrationConfiguration = MobileIntegrationConfiguration(),
        privacy: PrivacyConfiguration = PrivacyConfiguration(),
        sync: SyncConfiguration = SyncConfiguration(),
        pinboardInvitationInbox: PinboardInvitationInbox = PinboardInvitationInbox(),
        storage: StorageConfiguration = StorageConfiguration(),
        paste: PasteConfiguration = PasteConfiguration(),
        settingsBehavior: SettingsBehaviorConfiguration = SettingsBehaviorConfiguration(),
        shortcuts: ShortcutConfiguration = ShortcutConfiguration(),
        mcp: MCPConfiguration = MCPConfiguration(),
        semanticIndex: SemanticIndexConfiguration = SemanticIndexConfiguration(),
        security: SecurityConfiguration = SecurityConfiguration()
    ) {
        self.schemaVersion = schemaVersion
        self.items = items
        self.pinboards = pinboards
        self.general = general
        self.entitlement = entitlement
        self.mobile = mobile
        self.privacy = privacy
        self.sync = sync
        self.pinboardInvitationInbox = pinboardInvitationInbox
        self.storage = storage
        self.paste = paste
        self.settingsBehavior = settingsBehavior
        self.shortcuts = shortcuts
        self.mcp = mcp
        self.semanticIndex = semanticIndex
        self.security = security
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case items
        case pinboards
        case general
        case entitlement
        case mobile
        case privacy
        case sync
        case pinboardInvitationInbox
        case storage
        case paste
        case settingsBehavior
        case shortcuts
        case mcp
        case semanticIndex
        case security
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        items = try container.decodeIfPresent([ClipboardItem].self, forKey: .items) ?? []
        pinboards = try container.decodeIfPresent([Pinboard].self, forKey: .pinboards) ?? [Pinboard(name: "Favorites", colorHex: "#4EA7FC")]
        general = try container.decodeIfPresent(GeneralConfiguration.self, forKey: .general) ?? GeneralConfiguration()
        entitlement = try container.decodeIfPresent(EntitlementConfiguration.self, forKey: .entitlement) ?? EntitlementConfiguration()
        mobile = try container.decodeIfPresent(MobileIntegrationConfiguration.self, forKey: .mobile) ?? MobileIntegrationConfiguration()
        privacy = try container.decodeIfPresent(PrivacyConfiguration.self, forKey: .privacy) ?? PrivacyConfiguration()
        sync = try container.decodeIfPresent(SyncConfiguration.self, forKey: .sync) ?? SyncConfiguration()
        pinboardInvitationInbox = try container.decodeIfPresent(PinboardInvitationInbox.self, forKey: .pinboardInvitationInbox) ?? PinboardInvitationInbox()
        storage = try container.decodeIfPresent(StorageConfiguration.self, forKey: .storage) ?? StorageConfiguration()
        paste = try container.decodeIfPresent(PasteConfiguration.self, forKey: .paste) ?? PasteConfiguration()
        settingsBehavior = try container.decodeIfPresent(
            SettingsBehaviorConfiguration.self,
            forKey: .settingsBehavior
        ) ?? SettingsBehaviorConfiguration()
        shortcuts = try container.decodeIfPresent(ShortcutConfiguration.self, forKey: .shortcuts) ?? ShortcutConfiguration()
        mcp = try container.decodeIfPresent(MCPConfiguration.self, forKey: .mcp) ?? MCPConfiguration()
        semanticIndex = try container.decodeIfPresent(SemanticIndexConfiguration.self, forKey: .semanticIndex) ?? SemanticIndexConfiguration()
        security = try container.decodeIfPresent(SecurityConfiguration.self, forKey: .security) ?? SecurityConfiguration()
    }
}

public enum PrivacyCaptureStatus: Equatable, Sendable {
    case active
    case pausedIndefinitely
    case pausedUntil(Date)

    public var isPaused: Bool {
        switch self {
        case .active:
            false
        case .pausedIndefinitely, .pausedUntil:
            true
        }
    }
}

public enum PrivacyProtectedSurface: String, CaseIterable, Codable, Identifiable, Sendable {
    case automaticClipboardCapture
    case pinboards
    case search
    case shortcuts
    case keyboardExtension
    case shareActionExtensions
    case mcpAccess

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automaticClipboardCapture:
            "Automatic Clipboard Capture"
        case .pinboards:
            "Pinboards"
        case .search:
            "Search"
        case .shortcuts:
            "Shortcuts"
        case .keyboardExtension:
            "Keyboard Extension"
        case .shareActionExtensions:
            "Share and Action Extensions"
        case .mcpAccess:
            "MCP Access"
        }
    }
}

public struct PrivacyPostureReport: Equatable, Sendable {
    public var captureStatus: PrivacyCaptureStatus
    public var protectedSurfaces: Set<PrivacyProtectedSurface>
    public var disabledContentTypes: [ClipboardContentType]
    public var excludedApplicationCount: Int
    public var excludedBundleIdentifierCount: Int
    public var activeCustomCaptureRuleCount: Int
    public var sensitiveTextBlockingEnabled: Bool
    public var localBoundaryStatement: String
    public var syncBoundaryStatement: String
    public var vendorServerStatement: String
    public var mcpBoundaryStatement: String
    public var coverageStatement: String

    public init(snapshot: PasteBuddySnapshot, now: Date = Date()) {
        let privacy = snapshot.privacy
        if let pauseUntil = privacy.activePauseUntil(now: now) {
            captureStatus = .pausedUntil(pauseUntil)
        } else if privacy.isCapturePaused {
            captureStatus = .pausedIndefinitely
        } else {
            captureStatus = .active
        }

        protectedSurfaces = Set(PrivacyProtectedSurface.allCases)
        disabledContentTypes = ClipboardContentType.allCases.filter { !privacy.allowsCapture(of: $0) }
        excludedApplicationCount = privacy.excludedApplicationNames.count
        excludedBundleIdentifierCount = privacy.excludedBundleIdentifiers.count
        activeCustomCaptureRuleCount = privacy.customCaptureRules.filter(\.isEnabled).count
        sensitiveTextBlockingEnabled = privacy.blockLikelySensitiveText
        localBoundaryStatement = "message.clipboard_payloads_images_ocr_metadata_thumbnails_privacy"
        vendorServerStatement = "PasteBuddy does not send clipboard payloads to vendor servers for capture, search, OCR, keyboard insertion, Shortcuts, or local MCP access."
        mcpBoundaryStatement = snapshot.mcp.isServerEnabled
            ? "MCP Agent connection is on. Connected local Agents can use PasteBuddy on this Mac."
            : "MCP Agent connection is off. Local Agents cannot connect to PasteBuddy."

        if snapshot.sync.provider == .cloudKit {
            syncBoundaryStatement = "CloudKit sync uses your private iCloud account."
        } else {
            syncBoundaryStatement = "Sync is local-only."
        }
        coverageStatement = "The same local privacy boundary covers history, pinboards, search, Shortcuts, keyboard insertion, Share/Action imports, and MCP access."
    }
}

public extension PasteBuddySnapshot {
    func privacyPostureReport(now: Date = Date()) -> PrivacyPostureReport {
        PrivacyPostureReport(snapshot: self, now: now)
    }
}

public enum AccessibilityQualityArea: String, CaseIterable, Codable, Identifiable, Sendable {
    case voiceOver
    case dynamicType
    case appearance
    case nonColorStatus
    case localization

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .voiceOver:
            "VoiceOver"
        case .dynamicType:
            "Larger Text"
        case .appearance:
            "Appearance"
        case .nonColorStatus:
            "Not Color Only"
        case .localization:
            "Localization"
        }
    }

    public var systemImageName: String {
        switch self {
        case .voiceOver:
            "accessibility"
        case .dynamicType:
            "textformat.size"
        case .appearance:
            "circle.lefthalf.filled"
        case .nonColorStatus:
            "checkmark.seal"
        case .localization:
            "globe"
        }
    }
}

public enum AccessibilityQualityStatus: String, CaseIterable, Codable, Identifiable, Sendable {
    case implemented
    case manualAuditRequired

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .implemented:
            "Implemented"
        case .manualAuditRequired:
            "Manual Audit Required"
        }
    }
}

public struct AccessibilityQualityFinding: Codable, Equatable, Identifiable, Sendable {
    public var area: AccessibilityQualityArea
    public var status: AccessibilityQualityStatus
    public var title: String
    public var detail: String
    public var coveredSurfaces: [String]

    public var id: String { area.id }

    public init(
        area: AccessibilityQualityArea,
        status: AccessibilityQualityStatus,
        title: String,
        detail: String,
        coveredSurfaces: [String]
    ) {
        self.area = area
        self.status = status
        self.title = title
        self.detail = detail
        self.coveredSurfaces = coveredSurfaces
    }
}

public struct AccessibilityLocalizationQualityReport: Codable, Equatable, Sendable {
    public var summary: String
    public var supportedLocaleIdentifiers: [String]
    public var findings: [AccessibilityQualityFinding]
    public var localizationReadyStatement: String
    public var releaseAuditStatement: String

    public init() {
        summary = "Core clipboard workflows have code-level accessibility labels, semantic appearance, non-color status cues, and localization resources for English and Simplified Chinese."
        supportedLocaleIdentifiers = ["en", "zh-Hans"]
        localizationReadyStatement = "English and Simplified Chinese String Catalog entries and SwiftPM compatibility resources keep matching key sets, with priority Mac, mobile, filtering, Settings, MCP, sync, extension, and monetization strings covered by tests."
        releaseAuditStatement = "Before App Store release, run a manual VoiceOver, Larger Text, high-contrast, and localized-layout pass on signed Mac, iPhone, iPad, keyboard, Share, and Action extension targets."
        findings = [
            AccessibilityQualityFinding(
                area: .voiceOver,
                status: .implemented,
                title: "Core workflows expose spoken labels",
                detail: "History rows combine title, content type, reuse category, labels, source app, device, and copied time; filters, previews, pinboards, Settings controls, direct-paste guidance, and mobile rows expose explicit labels or combined values.",
                coveredSurfaces: ["History", "Pinboards", "Search", "Settings", "Mobile", "Extensions"]
            ),
            AccessibilityQualityFinding(
                area: .dynamicType,
                status: .implemented,
                title: "Text can scale in dense layouts",
                detail: "Settings uses flexible min/ideal sizing, compact tiles use stable dimensions and minimum scale factors, and rows prefer semantic fonts with line limits instead of fixed text-only controls.",
                coveredSurfaces: ["Settings", "History Rows", "Paste Stack", "Preview Tiles"]
            ),
            AccessibilityQualityFinding(
                area: .appearance,
                status: .implemented,
                title: "Light, dark, and contrast-friendly styling",
                detail: "Mac and mobile views use system colors, semantic foreground styles, materials, and SF Symbols so appearance follows platform Light/Dark and high-contrast settings.",
                coveredSurfaces: ["Mac App", "Menu Bar", "Mobile Browser", "Settings"]
            ),
            AccessibilityQualityFinding(
                area: .nonColorStatus,
                status: .implemented,
                title: "Status is not communicated by color alone",
                detail: "Capture, sync, entitlement, restore, privacy, pinboard, and paste statuses include text labels or icons; pinboard color choices expose selected values and add a checkmark when Differentiate Without Color is enabled.",
                coveredSurfaces: ["Pinboards", "Capture", "Sync", "Plan", "Privacy", "Direct Paste"]
            ),
            AccessibilityQualityFinding(
                area: .localization,
                status: .implemented,
                title: "Priority strings are localization-ready",
                detail: "English and Simplified Chinese resources cover priority user-facing strings for Mac, mobile, filtering, Settings, MCP, sync, extension setup, accessibility prompts, and monetization state.",
                coveredSurfaces: ["Mac", "Mobile", "Extensions", "MCP", "Sync", "Monetization"]
            )
        ]
    }

    public var hasReleaseBlockers: Bool {
        false
    }
}

public extension PasteBuddySnapshot {
    func accessibilityLocalizationQualityReport() -> AccessibilityLocalizationQualityReport {
        AccessibilityLocalizationQualityReport()
    }
}

public enum MacSettingsDestination: String, CaseIterable, Codable, Identifiable, Sendable {
    case general
    case shortcuts
    case privacy
    case sync
    case storage

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .general:
            "General"
        case .shortcuts:
            "Shortcuts"
        case .privacy:
            "Privacy"
        case .sync:
            "Sync"
        case .storage:
            "Storage"
        }
    }

    public var systemImageName: String {
        switch self {
        case .general:
            "gearshape"
        case .shortcuts:
            "command"
        case .privacy:
            "hand.raised"
        case .sync:
            "icloud"
        case .storage:
            "externaldrive"
        }
    }
}

public struct MacMenuBarStatus: Equatable, Sendable {
    public var title: String
    public var systemImageName: String

    public init(snapshot: PasteBuddySnapshot, now: Date = Date()) {
        let privacyReport = snapshot.privacyPostureReport(now: now)
        title = privacyReport.captureStatus.isPaused ? "PasteBuddy Paused" : "PasteBuddy Active"
        systemImageName = privacyReport.captureStatus.isPaused ? "pause.circle.fill" : "doc.on.clipboard"
    }
}

public extension PasteBuddySnapshot {
    func macMenuBarStatus(now: Date = Date()) -> MacMenuBarStatus {
        MacMenuBarStatus(snapshot: self, now: now)
    }
}

public enum PasteStackDirection: String, CaseIterable, Codable, Sendable {
    case topToBottom
    case bottomToTop

    public var displayName: String {
        switch self {
        case .topToBottom: "Top to Bottom"
        case .bottomToTop: "Bottom to Top"
        }
    }
}

public enum ClipboardDateFilter: String, CaseIterable, Identifiable, Sendable {
    case any
    case today
    case last7Days

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .any: "Any Date"
        case .today: "Today"
        case .last7Days: "Last 7 Days"
        }
    }

    public func contains(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .any:
            true
        case .today:
            calendar.isDate(date, inSameDayAs: now)
        case .last7Days:
            date >= calendar.date(byAdding: .day, value: -7, to: now) ?? now
        }
    }
}

public enum PasteScope: Hashable, Sendable {
    case history
    case pasteStack
    case pinboard(UUID)
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    public var singleLinePreview: String {
        let collapsed = split(whereSeparator: \.isNewline).joined(separator: " ")
        if collapsed.count <= 120 {
            return collapsed
        }
        return String(collapsed.prefix(117)) + "..."
    }

    public var pasteBuddyPlainTextFromHTML: String {
        replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
