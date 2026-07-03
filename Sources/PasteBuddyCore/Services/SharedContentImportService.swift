import Foundation

public enum SharedContentSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case iPhoneApp
    case iPadApp
    case keyboardExtension
    case shareExtension
    case actionExtension

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .iPhoneApp: "PasteBuddy iPhone"
        case .iPadApp: "PasteBuddy iPad"
        case .keyboardExtension: "PasteBuddy Keyboard"
        case .shareExtension: "PasteBuddy Share Extension"
        case .actionExtension: "PasteBuddy Action Extension"
        }
    }
}

public struct SharedContentInput: Sendable {
    public var title: String?
    public var text: String?
    public var urlString: String?
    public var fileURLString: String?
    public var imageData: Data?
    public var preferredPinboardID: UUID?
    public var source: SharedContentSource
    public var sourceBundleIdentifier: String?
    public var deviceName: String

    public init(
        title: String? = nil,
        text: String? = nil,
        urlString: String? = nil,
        fileURLString: String? = nil,
        imageData: Data? = nil,
        preferredPinboardID: UUID? = nil,
        source: SharedContentSource,
        sourceBundleIdentifier: String? = nil,
        deviceName: String
    ) {
        self.title = title
        self.text = text
        self.urlString = urlString
        self.fileURLString = fileURLString
        self.imageData = imageData
        self.preferredPinboardID = preferredPinboardID
        self.source = source
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.deviceName = deviceName
    }
}

public enum SharedContentImportError: LocalizedError, Equatable {
    case emptyContent
    case contentTypeDisabled(ClipboardContentType)
    case sensitiveTextBlocked
    case captureRuleBlocked(String)

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            "The shared content did not contain a supported text, link, file, or image payload."
        case .contentTypeDisabled(let type):
            "\(type.displayName) capture is disabled."
        case .sensitiveTextBlocked:
            "The shared content matched local sensitive-text rules and was not saved."
        case .captureRuleBlocked(let ruleName):
            "The shared content matched the local capture rule \"\(ruleName)\" and was not saved."
        }
    }
}

@MainActor
public final class SharedContentImportService {
    public init() {}

    @discardableResult
    public func importContent(_ input: SharedContentInput, into store: PasteBuddyStore) throws -> ClipboardItem {
        let item = try makeClipboardItem(from: input, privacy: store.snapshot.privacy)
        let stored = store.addCapturedItem(item)
        let pinboardID = input.preferredPinboardID ?? store.snapshot.mobile.preferredSharePinboardID
        if let pinboardID {
            store.pinItem(stored.id, to: pinboardID)
        }
        return stored
    }

    private func makeClipboardItem(
        from input: SharedContentInput,
        privacy: PrivacyConfiguration
    ) throws -> ClipboardItem {
        if let text = input.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let item = ClipboardItem(
                sourceAppName: input.source.displayName,
                sourceBundleIdentifier: input.sourceBundleIdentifier,
                deviceName: input.deviceName,
                contentType: .text,
                title: title(from: input.title, fallback: text.singleLinePreview),
                payload: ClipboardPayload(text: input.text)
            )
            try validate(item, privacy: privacy, sourceBundleIdentifier: input.sourceBundleIdentifier)
            return item
        }

        if let urlString = input.urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
           let webURLString = ClipboardPayload.normalizedWebURLString(urlString) {
            let item = ClipboardItem(
                sourceAppName: input.source.displayName,
                sourceBundleIdentifier: input.sourceBundleIdentifier,
                deviceName: input.deviceName,
                contentType: .url,
                title: title(from: input.title, fallback: webURLString),
                payload: ClipboardPayload(urlString: webURLString)
            )
            try validate(item, privacy: privacy, sourceBundleIdentifier: input.sourceBundleIdentifier)
            return item
        }

        if let fileURLString = input.fileURLString?.trimmingCharacters(in: .whitespacesAndNewlines), !fileURLString.isEmpty {
            let item = ClipboardItem(
                sourceAppName: input.source.displayName,
                sourceBundleIdentifier: input.sourceBundleIdentifier,
                deviceName: input.deviceName,
                contentType: .file,
                title: title(from: input.title, fallback: URL(string: fileURLString)?.lastPathComponent ?? "Shared File"),
                payload: ClipboardPayload(fileURLString: fileURLString)
            )
            try validate(item, privacy: privacy, sourceBundleIdentifier: input.sourceBundleIdentifier)
            return item
        }

        if let imageData = input.imageData, !imageData.isEmpty {
            let item = ClipboardItem(
                sourceAppName: input.source.displayName,
                sourceBundleIdentifier: input.sourceBundleIdentifier,
                deviceName: input.deviceName,
                contentType: .image,
                title: title(from: input.title, fallback: "Shared Image"),
                payload: ClipboardPayload(imageData: imageData),
                ocrState: privacy.runLocalOCRAfterImageCapture ? .pending(Date()) : .notNeeded
            )
            try validate(item, privacy: privacy, sourceBundleIdentifier: input.sourceBundleIdentifier)
            return item
        }

        throw SharedContentImportError.emptyContent
    }

    private func validate(
        _ item: ClipboardItem,
        privacy: PrivacyConfiguration,
        sourceBundleIdentifier: String?
    ) throws {
        let decision = privacy.captureDecision(
            for: item,
            sourceApplicationName: item.sourceAppName,
            sourceBundleIdentifier: sourceBundleIdentifier
        )
        guard let blockReason = decision.blockReason else { return }
        switch blockReason {
        case .contentTypeDisabled(let type):
            throw SharedContentImportError.contentTypeDisabled(type)
        case .sensitiveText:
            throw SharedContentImportError.sensitiveTextBlocked
        case .customCaptureRule(let rule):
            throw SharedContentImportError.captureRuleBlocked(rule.name)
        case .capturePaused, .sourceApplicationExcluded:
            throw SharedContentImportError.captureRuleBlocked(blockReason.displayName)
        }
    }

    private func title(from candidate: String?, fallback: String) -> String {
        let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed! : fallback
    }
}
