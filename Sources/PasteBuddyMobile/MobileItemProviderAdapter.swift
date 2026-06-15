import Foundation
import PasteBuddyCore
import UniformTypeIdentifiers

public enum MobileItemProviderAdapterError: LocalizedError, Equatable {
    case emptyProviders
    case unsupportedContent
    case unreadableContent(String)

    public var errorDescription: String? {
        switch self {
        case .emptyProviders:
            "No shared content was provided."
        case .unsupportedContent:
            "The shared content did not include text, a URL, a file URL, or image data."
        case .unreadableContent(let typeIdentifier):
            "The shared content for \(typeIdentifier) could not be read."
        }
    }
}

public struct MobileItemProviderImportConfiguration: Sendable {
    public var preferredPinboardID: UUID?
    public var source: SharedContentSource
    public var deviceName: String

    public init(
        preferredPinboardID: UUID? = nil,
        source: SharedContentSource = .shareExtension,
        deviceName: String = PasteBuddyStore.defaultDeviceName
    ) {
        self.preferredPinboardID = preferredPinboardID
        self.source = source
        self.deviceName = deviceName
    }
}

public enum MobileItemProviderAdapter {
    public static func firstSupportedInput(
        from providers: [NSItemProvider],
        configuration: MobileItemProviderImportConfiguration = MobileItemProviderImportConfiguration()
    ) async throws -> SharedContentInput {
        guard !providers.isEmpty else {
            throw MobileItemProviderAdapterError.emptyProviders
        }

        for provider in providers {
            if let input = try await input(from: provider, configuration: configuration) {
                return input
            }
        }

        throw MobileItemProviderAdapterError.unsupportedContent
    }

    public static func supportedInputs(
        from providers: [NSItemProvider],
        configuration: MobileItemProviderImportConfiguration = MobileItemProviderImportConfiguration()
    ) async throws -> [SharedContentInput] {
        guard !providers.isEmpty else {
            throw MobileItemProviderAdapterError.emptyProviders
        }

        var inputs: [SharedContentInput] = []
        for provider in providers {
            if let input = try await input(from: provider, configuration: configuration) {
                inputs.append(input)
            }
        }

        guard !inputs.isEmpty else {
            throw MobileItemProviderAdapterError.unsupportedContent
        }
        return inputs
    }

    private static func input(
        from provider: NSItemProvider,
        configuration: MobileItemProviderImportConfiguration
    ) async throws -> SharedContentInput? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let fileURLString = try await loadStringOrURL(from: provider, type: .fileURL) {
            return SharedContentInput(
                title: provider.suggestedName,
                fileURLString: fileURLString,
                preferredPinboardID: configuration.preferredPinboardID,
                source: configuration.source,
                deviceName: configuration.deviceName
            )
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let urlString = try await loadStringOrURL(from: provider, type: .url) {
            return SharedContentInput(
                title: provider.suggestedName,
                urlString: urlString,
                preferredPinboardID: configuration.preferredPinboardID,
                source: configuration.source,
                deviceName: configuration.deviceName
            )
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
           let data = try await loadData(from: provider, type: .image) {
            return SharedContentInput(
                title: provider.suggestedName,
                imageData: data,
                preferredPinboardID: configuration.preferredPinboardID,
                source: configuration.source,
                deviceName: configuration.deviceName
            )
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = try await loadStringOrURL(from: provider, type: .plainText) {
            return SharedContentInput(
                title: provider.suggestedName,
                text: text,
                preferredPinboardID: configuration.preferredPinboardID,
                source: configuration.source,
                deviceName: configuration.deviceName
            )
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier),
           let text = try await loadStringOrURL(from: provider, type: .text) {
            return SharedContentInput(
                title: provider.suggestedName,
                text: text,
                preferredPinboardID: configuration.preferredPinboardID,
                source: configuration.source,
                deviceName: configuration.deviceName
            )
        }

        return nil
    }

    private static func loadStringOrURL(from provider: NSItemProvider, type: UTType) async throws -> String? {
        let item = try await loadItem(from: provider, typeIdentifier: type.identifier)
        if let string = item as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        if let url = item as? URL {
            return url.absoluteString
        }
        if let data = item as? Data, let string = String(data: data, encoding: .utf8) {
            return string.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        if let nsString = item as? NSString {
            return (nsString as String).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        if let nsURL = item as? NSURL {
            return nsURL.absoluteString
        }
        return nil
    }

    private static func loadData(from provider: NSItemProvider, type: UTType) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }

    private static func loadItem(from provider: NSItemProvider, typeIdentifier: String) async throws -> NSSecureCoding? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: item)
                }
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
