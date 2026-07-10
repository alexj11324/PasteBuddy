import Foundation
import PasteBuddyCore
import UniformTypeIdentifiers

public enum MobileItemProviderAdapterError: LocalizedError, Equatable {
    case emptyProviders
    case unsupportedContent
    case unreadableContent(String)
    case loadTimedOut(String)
    case batchLoadTimedOut
    case tooManyProviders(limit: Int)
    case batchPayloadTooLarge(limitBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyProviders:
            PasteBuddyLocalization.string(
                "mobile.error.no_shared_content",
                defaultValue: "No shared content was provided."
            )
        case .unsupportedContent:
            PasteBuddyLocalization.string(
                "mobile.error.unsupported_shared_content",
                defaultValue: "The shared content did not include text, a URL, a file URL, or image data."
            )
        case .unreadableContent(let typeIdentifier):
            PasteBuddyLocalization.format(
                "mobile.error.unreadable_shared_content",
                defaultValue: "The shared content for %@ could not be read.",
                typeIdentifier
            )
        case .loadTimedOut:
            PasteBuddyLocalization.string(
                "mobile.error.provider_load_timed_out",
                defaultValue: "The shared content took too long to load."
            )
        case .batchLoadTimedOut:
            PasteBuddyLocalization.string(
                "mobile.error.provider_batch_timed_out",
                defaultValue: "The shared content batch took too long to load."
            )
        case .tooManyProviders(let limit):
            PasteBuddyLocalization.format(
                "mobile.error.too_many_shared_items",
                defaultValue: "Too many shared items were provided (limit: %d).",
                limit
            )
        case .batchPayloadTooLarge(let limitBytes):
            PasteBuddyLocalization.format(
                "mobile.error.shared_batch_too_large",
                defaultValue: "The shared content is too large to import safely (limit: %d MB).",
                max(limitBytes / (1_024 * 1_024), 1)
            )
        }
    }
}

public struct MobileItemProviderImportConfiguration: Sendable {
    public var preferredPinboardID: UUID?
    public var source: SharedContentSource
    public var deviceName: String
    public var loadTimeout: Duration
    public var batchTimeout: Duration
    public var maxProviderCount: Int
    public var maxConcurrentProviderLoads: Int
    public var maxTotalLoadedBytes: Int
    public var imageSafetyPolicy: MobileImageSafetyPolicy

    public init(
        preferredPinboardID: UUID? = nil,
        source: SharedContentSource = .shareExtension,
        deviceName: String = PasteBuddyStore.defaultDeviceName,
        loadTimeout: Duration = .seconds(5),
        batchTimeout: Duration = .seconds(10),
        maxProviderCount: Int = 32,
        maxConcurrentProviderLoads: Int = 2,
        maxTotalLoadedBytes: Int = 64 * 1_024 * 1_024,
        imageSafetyPolicy: MobileImageSafetyPolicy = .default
    ) {
        self.preferredPinboardID = preferredPinboardID
        self.source = source
        self.deviceName = deviceName
        self.loadTimeout = loadTimeout
        self.batchTimeout = batchTimeout
        self.maxProviderCount = min(max(maxProviderCount, 1), 256)
        self.maxConcurrentProviderLoads = min(max(maxConcurrentProviderLoads, 1), 8)
        self.maxTotalLoadedBytes = max(maxTotalLoadedBytes, 1)
        self.imageSafetyPolicy = imageSafetyPolicy
    }
}

@MainActor
public enum MobileItemProviderAdapter {
    public static func firstSupportedInput(
        from providers: [NSItemProvider],
        configuration: MobileItemProviderImportConfiguration = MobileItemProviderImportConfiguration()
    ) async throws -> SharedContentInput {
        guard !providers.isEmpty else {
            throw MobileItemProviderAdapterError.emptyProviders
        }

        let loadedByteBudget = MobileLoadedByteBudget(
            limitBytes: configuration.maxTotalLoadedBytes
        )
        for provider in providers {
            if let input = try await input(
                from: provider,
                configuration: configuration,
                loadedByteBudget: loadedByteBudget
            ) {
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
        guard providers.count <= configuration.maxProviderCount else {
            throw MobileItemProviderAdapterError.tooManyProviders(
                limit: configuration.maxProviderCount
            )
        }

        let batchLoader = MobileItemProviderBatchLoader(
            providers: providers,
            configuration: configuration
        )
        let inputs = try await withThrowingTaskGroup(
            of: [SharedContentInput].self,
            returning: [SharedContentInput].self
        ) { group in
            group.addTask {
                try await batchLoader.supportedInputs()
            }
            group.addTask {
                try await Task.sleep(for: configuration.batchTimeout)
                throw MobileItemProviderAdapterError.batchLoadTimedOut
            }
            guard let result = try await group.next() else {
                throw MobileItemProviderAdapterError.unsupportedContent
            }
            group.cancelAll()
            return result
        }

        guard !inputs.isEmpty else {
            throw MobileItemProviderAdapterError.unsupportedContent
        }
        return inputs
    }

    fileprivate static func loadSupportedInputs(
        from providers: [NSItemProvider],
        configuration: MobileItemProviderImportConfiguration
    ) async throws -> [SharedContentInput] {
        let loader = MobileItemProviderBatchLoader(
            providers: providers,
            configuration: configuration
        )
        let inputs = try await withThrowingTaskGroup(
            of: (index: Int, input: SharedContentInput?).self,
            returning: [SharedContentInput].self
        ) { group in
            let maximumConcurrentLoads = min(
                configuration.maxConcurrentProviderLoads,
                providers.count
            )
            let initialTaskCount = maximumConcurrentLoads
            for index in 0..<initialTaskCount {
                group.addTask {
                    (
                        index,
                        try await loader.input(at: index)
                    )
                }
            }

            var orderedInputs = Array<SharedContentInput?>(
                repeating: nil,
                count: providers.count
            )
            var activeTaskCount = initialTaskCount
            var nextIndex = initialTaskCount
            while activeTaskCount > 0,
                  let (index, input) = try await group.next() {
                activeTaskCount -= 1
                orderedInputs[index] = input
                while activeTaskCount < maximumConcurrentLoads,
                      nextIndex < providers.count {
                    let scheduledIndex = nextIndex
                    nextIndex += 1
                    activeTaskCount += 1
                    group.addTask {
                        (
                            scheduledIndex,
                            try await loader.input(at: scheduledIndex)
                        )
                    }
                }
            }
            return orderedInputs.compactMap { $0 }
        }
        return inputs
    }

    fileprivate static func input(
        from provider: NSItemProvider,
        configuration: MobileItemProviderImportConfiguration,
        loadedByteBudget: MobileLoadedByteBudget
    ) async throws -> SharedContentInput? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let fileURLString = try await loadStringOrURL(
               from: provider,
               type: .fileURL,
               timeout: configuration.loadTimeout,
               loadedByteBudget: loadedByteBudget
           ) {
            let input = SharedContentInput(
                title: provider.suggestedName,
                fileURLString: fileURLString,
                preferredPinboardID: configuration.preferredPinboardID,
                source: configuration.source,
                deviceName: configuration.deviceName
            )
            try loadedByteBudget.reserve(input.nonPayloadEstimatedLoadedByteCount)
            return input
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let urlString = try await loadStringOrURL(
               from: provider,
               type: .url,
               timeout: configuration.loadTimeout,
               loadedByteBudget: loadedByteBudget
           ) {
            let input = SharedContentInput(
                title: provider.suggestedName,
                urlString: urlString,
                preferredPinboardID: configuration.preferredPinboardID,
                source: configuration.source,
                deviceName: configuration.deviceName
            )
            try loadedByteBudget.reserve(input.nonPayloadEstimatedLoadedByteCount)
            return input
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
           let data = try await loadImageData(
               from: provider,
               type: .image,
               timeout: configuration.loadTimeout,
               imageSafetyPolicy: configuration.imageSafetyPolicy,
               loadedByteBudget: loadedByteBudget
           ) {
            let imageSafetyPolicy = configuration.imageSafetyPolicy
            _ = try await Task.detached(priority: .utility) {
                try imageSafetyPolicy.validate(data)
            }.value
            let input = SharedContentInput(
                title: provider.suggestedName,
                imageData: data,
                preferredPinboardID: configuration.preferredPinboardID,
                source: configuration.source,
                deviceName: configuration.deviceName
            )
            try loadedByteBudget.reserve(input.nonPayloadEstimatedLoadedByteCount)
            return input
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = try await loadStringOrURL(
               from: provider,
               type: .plainText,
               timeout: configuration.loadTimeout,
               loadedByteBudget: loadedByteBudget
           ) {
            let input = SharedContentInput(
                title: provider.suggestedName,
                text: text,
                preferredPinboardID: configuration.preferredPinboardID,
                source: configuration.source,
                deviceName: configuration.deviceName
            )
            try loadedByteBudget.reserve(input.nonPayloadEstimatedLoadedByteCount)
            return input
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier),
           let text = try await loadStringOrURL(
               from: provider,
               type: .text,
               timeout: configuration.loadTimeout,
               loadedByteBudget: loadedByteBudget
           ) {
            let input = SharedContentInput(
                title: provider.suggestedName,
                text: text,
                preferredPinboardID: configuration.preferredPinboardID,
                source: configuration.source,
                deviceName: configuration.deviceName
            )
            try loadedByteBudget.reserve(input.nonPayloadEstimatedLoadedByteCount)
            return input
        }

        return nil
    }

    private static func loadStringOrURL(
        from provider: NSItemProvider,
        type: UTType,
        timeout: Duration,
        loadedByteBudget: MobileLoadedByteBudget
    ) async throws -> String? {
        try await loadValue(typeIdentifier: type.identifier, timeout: timeout) { completion in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let url else {
                    completion(.success(nil))
                    return
                }
                do {
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    guard values.isRegularFile == true, let fileSize = values.fileSize else {
                        throw MobileItemProviderAdapterError.unreadableContent(type.identifier)
                    }
                    try loadedByteBudget.reserve(fileSize)
                    do {
                        let string = try String(contentsOf: url, encoding: .utf8)
                        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !normalized.isEmpty else {
                            loadedByteBudget.release(fileSize)
                            completion(.success(nil))
                            return
                        }
                        try loadedByteBudget.replaceReservation(
                            releasing: fileSize,
                            reserving: normalized.utf8.count
                        )
                        completion(.success(normalized))
                    } catch {
                        loadedByteBudget.release(fileSize)
                        throw error
                    }
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    private static func loadImageData(
        from provider: NSItemProvider,
        type: UTType,
        timeout: Duration,
        imageSafetyPolicy: MobileImageSafetyPolicy,
        loadedByteBudget: MobileLoadedByteBudget
    ) async throws -> Data? {
        try await loadBoundedFileData(
            from: provider,
            type: type,
            timeout: timeout,
            loadedByteBudget: loadedByteBudget,
            validateByteCount: imageSafetyPolicy.validateCompressedByteCount
        )
    }

    private static func loadBoundedFileData(
        from provider: NSItemProvider,
        type: UTType,
        timeout: Duration,
        loadedByteBudget: MobileLoadedByteBudget,
        validateByteCount: @escaping @Sendable (Int) throws -> Void = { _ in }
    ) async throws -> Data? {
        try await loadValue(typeIdentifier: type.identifier, timeout: timeout) { completion in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let url else {
                    completion(.success(nil))
                    return
                }
                do {
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    guard values.isRegularFile == true, let fileSize = values.fileSize else {
                        throw MobileItemProviderAdapterError.unreadableContent(type.identifier)
                    }
                    try validateByteCount(fileSize)
                    try loadedByteBudget.reserve(fileSize)
                    do {
                        let data = try Data(contentsOf: url, options: .mappedIfSafe)
                        try validateByteCount(data.count)
                        try loadedByteBudget.replaceReservation(
                            releasing: fileSize,
                            reserving: data.count
                        )
                        completion(.success(data))
                    } catch {
                        loadedByteBudget.release(fileSize)
                        throw error
                    }
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    private static func loadValue<Value: Sendable>(
        typeIdentifier: String,
        timeout: Duration,
        start: (@escaping @Sendable (Result<Value?, Error>) -> Void) -> Progress?
    ) async throws -> Value? {
        let (stream, continuation) = AsyncThrowingStream<Value?, Error>.makeStream()
        let loadState = MobileProviderLoadState()
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard loadState.cancel() else { return }
            continuation.finish(
                throwing: MobileItemProviderAdapterError.loadTimedOut(typeIdentifier)
            )
        }
        continuation.onTermination = { @Sendable termination in
            timeoutTask.cancel()
            if case .cancelled = termination {
                _ = loadState.cancel()
            }
        }
        let progress = start { result in
            guard loadState.complete() else { return }
            switch result {
            case .success(let value):
                continuation.yield(value)
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
        if let progress {
            loadState.install(progress)
        }

        return try await withTaskCancellationHandler {
            for try await value in stream {
                return value
            }
            return nil
        } onCancel: {
            guard loadState.cancel() else { return }
            continuation.finish(throwing: CancellationError())
        }
    }

}

@MainActor
private final class MobileItemProviderBatchLoader {
    private let providers: [NSItemProvider]
    private let configuration: MobileItemProviderImportConfiguration
    private let loadedByteBudget: MobileLoadedByteBudget

    init(
        providers: [NSItemProvider],
        configuration: MobileItemProviderImportConfiguration
    ) {
        self.providers = providers
        self.configuration = configuration
        self.loadedByteBudget = MobileLoadedByteBudget(
            limitBytes: configuration.maxTotalLoadedBytes
        )
    }

    func input(at index: Int) async throws -> SharedContentInput? {
        try await MobileItemProviderAdapter.input(
            from: providers[index],
            configuration: configuration,
            loadedByteBudget: loadedByteBudget
        )
    }

    func supportedInputs() async throws -> [SharedContentInput] {
        try await MobileItemProviderAdapter.loadSupportedInputs(
            from: providers,
            configuration: configuration
        )
    }

}

private final class MobileLoadedByteBudget: @unchecked Sendable {
    private let limitBytes: Int
    private let lock = NSLock()
    private var reservedBytes = 0

    init(limitBytes: Int) {
        self.limitBytes = limitBytes
    }

    func reserve(_ byteCount: Int) throws {
        guard byteCount >= 0 else {
            throw MobileItemProviderAdapterError.batchPayloadTooLarge(limitBytes: limitBytes)
        }
        try lock.withLock {
            guard byteCount <= limitBytes - reservedBytes else {
                throw MobileItemProviderAdapterError.batchPayloadTooLarge(limitBytes: limitBytes)
            }
            reservedBytes += byteCount
        }
    }

    func replaceReservation(releasing oldByteCount: Int, reserving newByteCount: Int) throws {
        try lock.withLock {
            let remainingBytes = reservedBytes - oldByteCount
            guard oldByteCount >= 0,
                  newByteCount >= 0,
                  remainingBytes >= 0,
                  newByteCount <= limitBytes - remainingBytes else {
                throw MobileItemProviderAdapterError.batchPayloadTooLarge(limitBytes: limitBytes)
            }
            reservedBytes = remainingBytes + newByteCount
        }
    }

    func release(_ byteCount: Int) {
        guard byteCount > 0 else { return }
        lock.withLock {
            reservedBytes = max(reservedBytes - byteCount, 0)
        }
    }
}

private final class MobileProviderLoadState: @unchecked Sendable {
    private enum Termination {
        case pending
        case completed
        case cancelled
    }

    private let lock = NSLock()
    private var termination = Termination.pending
    private var progress: Progress?

    func install(_ progress: Progress) {
        lock.lock()
        switch termination {
        case .pending:
            self.progress = progress
            lock.unlock()
        case .completed:
            lock.unlock()
        case .cancelled:
            lock.unlock()
            progress.cancel()
        }
    }

    func complete() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .pending = termination else { return false }
        termination = .completed
        progress = nil
        return true
    }

    func cancel() -> Bool {
        lock.lock()
        guard case .pending = termination else {
            lock.unlock()
            return false
        }
        termination = .cancelled
        let progress = self.progress
        self.progress = nil
        lock.unlock()

        progress?.cancel()
        return true
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension SharedContentInput {
    var estimatedLoadedByteCount: Int {
        [title, text, urlString, fileURLString, sourceBundleIdentifier, deviceName]
            .compactMap { $0 }
            .reduce(imageData?.count ?? 0) { partialResult, value in
                let byteCount = value.utf8.count
                guard byteCount <= Int.max - partialResult else { return Int.max }
                return partialResult + byteCount
            }
    }

    var nonPayloadEstimatedLoadedByteCount: Int {
        [title, sourceBundleIdentifier, deviceName]
            .compactMap { $0 }
            .reduce(0) { partialResult, value in
                let byteCount = value.utf8.count
                guard byteCount <= Int.max - partialResult else { return Int.max }
                return partialResult + byteCount
            }
    }
}
