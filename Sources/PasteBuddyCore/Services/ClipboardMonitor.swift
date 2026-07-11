#if os(macOS)
import AppKit
import Foundation
import LinkPresentation

@MainActor
public final class ClipboardMonitor {
    private let store: PasteBuddyStore
    private let pasteboardReference: PasteboardReference
    private let recognizeText: @Sendable (Data) async throws -> String
    private let onItemCaptured: (@MainActor (ClipboardItem) -> Void)?
    private var timer: Timer?
    private var lastChangeCount: Int?
    private var pasteboardReadTask: Task<Void, Never>?
    private var needsPasteboardRepoll = false
    private var pendingCaptures: [PendingCapture?] = []
    private var nextPendingCaptureIndex = 0
    private var retainedCaptureCount = 0
    private var retainedCaptureBytes = 0
    private var captureWorkerTask: Task<Void, Never>?
    private var captureWorkerToken: UUID?
    @MainActor static var makeItemOverrideForTesting: (@Sendable () async -> ClipboardItem?)?
    var pendingCaptureBufferSlotCountForTesting: Int { pendingCaptures.count }
    var retainedCaptureCountForTesting: Int { retainedCaptureCount }
    var lastChangeCountForTesting: Int? { lastChangeCount }
    private static let maximumRetainedCaptureCount = 128
    private static let maximumRetainedCaptureBytes = 64 * 1_024 * 1_024

    public init(
        store: PasteBuddyStore,
        pasteboard: NSPasteboard = .general,
        ocrService: OCRService = OCRService(),
        recognizeText: (@Sendable (Data) async throws -> String)? = nil,
        onItemCaptured: (@MainActor (ClipboardItem) -> Void)? = nil
    ) {
        self.store = store
        let pasteboardReference = PasteboardReference(pasteboard)
        self.pasteboardReference = pasteboardReference
        self.recognizeText = recognizeText ?? { imageData in
            try await ocrService.recognizeText(in: imageData)
        }
        self.onItemCaptured = onItemCaptured
        self.lastChangeCount = nil
    }

    public func start() {
        guard timer == nil else { return }
        pollOnce()
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollOnce()
            }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        pasteboardReadTask?.cancel()
        pasteboardReadTask = nil
        needsPasteboardRepoll = false
        captureWorkerTask?.cancel()
        captureWorkerTask = nil
        captureWorkerToken = nil
        pendingCaptures.removeAll()
        nextPendingCaptureIndex = 0
        retainedCaptureCount = 0
        retainedCaptureBytes = 0
    }

    func pollOnce() {
        guard pasteboardReadTask == nil else {
            needsPasteboardRepoll = true
            return
        }

        let privacy = store.snapshot.privacy
        let sourceApplication = NSWorkspace.shared.frontmostApplication
        let sourceApp = sourceApplication?.localizedName ?? "Unknown"
        let bundleIdentifier = sourceApplication?.bundleIdentifier
        let shouldCapture = !store.isPersistenceWriteBlocked
            && !privacy.isCaptureCurrentlyPaused()
            && !privacy.excludesApplication(named: sourceApp, bundleIdentifier: bundleIdentifier)

        let pasteboardReference = pasteboardReference
        let expectedChangeCount = lastChangeCount
        let captureImages = privacy.captureImages
        pasteboardReadTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Self.readPasteboard(
                    reference: pasteboardReference,
                    expectedChangeCount: expectedChangeCount,
                    shouldCapture: shouldCapture,
                    captureImages: captureImages
                )
            }.value
            guard !Task.isCancelled else { return }

            self?.handlePasteboardReadResult(
                result,
                sourceApp: sourceApp,
                bundleIdentifier: bundleIdentifier
            )
        }
    }

    private func handlePasteboardReadResult(
        _ result: PasteboardReadResult,
        sourceApp: String,
        bundleIdentifier: String?
    ) {
        pasteboardReadTask = nil
        defer {
            if needsPasteboardRepoll {
                needsPasteboardRepoll = false
                pollOnce()
            }
        }
        guard let previousChangeCount = lastChangeCount else {
            lastChangeCount = result.changeCount
            return
        }
        lastChangeCount = result.changeCount
        guard result.changeCount != previousChangeCount,
              let pasteboardSnapshot = result.snapshot else { return }

        let currentPrivacy = store.snapshot.privacy
        guard !store.isPersistenceWriteBlocked,
              !currentPrivacy.isCaptureCurrentlyPaused(),
              !currentPrivacy.excludesApplication(
                  named: sourceApp,
                  bundleIdentifier: bundleIdentifier
              ) else {
            return
        }

        let pendingCapture = PendingCapture(
            snapshot: pasteboardSnapshot,
            sourceApp: sourceApp,
            sourceBundleIdentifier: bundleIdentifier,
            privacy: currentPrivacy
        )
        guard enqueue(pendingCapture) else { return }
        startCaptureWorkerIfNeeded()
    }

    private func enqueue(_ capture: PendingCapture) -> Bool {
        let captureBytes = capture.estimatedByteCount
        guard captureBytes <= Self.maximumRetainedCaptureBytes else {
            recordBackpressureError()
            return false
        }
        var droppedCapture = false
        while retainedCaptureCount >= Self.maximumRetainedCaptureCount
            || retainedCaptureBytes + captureBytes > Self.maximumRetainedCaptureBytes {
            guard dropOldestQueuedCapture() else {
                recordBackpressureError()
                return false
            }
            droppedCapture = true
        }
        pendingCaptures.append(capture)
        retainedCaptureCount += 1
        retainedCaptureBytes += captureBytes
        if droppedCapture {
            recordBackpressureError()
        }
        return true
    }

    private func recordBackpressureError() {
        guard !store.isPersistenceWriteBlocked else { return }
        store.lastErrorMessage = PasteBuddyLocalization.string(
            "message.clipboard_capture_backlog_full",
            defaultValue: "Clipboard capture paused briefly because incoming content exceeded the safe memory budget."
        )
    }

    private func dropOldestQueuedCapture() -> Bool {
        guard let index = pendingCaptures.indices.first(where: {
            $0 >= nextPendingCaptureIndex && pendingCaptures[$0] != nil
        }), let dropped = pendingCaptures[index] else {
            return false
        }
        pendingCaptures[index] = nil
        retainedCaptureCount = max(retainedCaptureCount - 1, 0)
        retainedCaptureBytes = max(retainedCaptureBytes - dropped.estimatedByteCount, 0)
        while nextPendingCaptureIndex < pendingCaptures.count,
              pendingCaptures[nextPendingCaptureIndex] == nil {
            nextPendingCaptureIndex += 1
        }
        compactProcessedCaptureSlotsIfNeeded()
        return true
    }

    private func startCaptureWorkerIfNeeded() {
        guard captureWorkerTask == nil else { return }
        let workerToken = UUID()
        captureWorkerToken = workerToken
        captureWorkerTask = Task { [weak self] in
            await self?.drainPendingCaptures(workerToken: workerToken)
        }
    }

    private func drainPendingCaptures(workerToken: UUID) async {
        defer {
            if captureWorkerToken == workerToken {
                pendingCaptures.removeAll(keepingCapacity: true)
                nextPendingCaptureIndex = 0
                captureWorkerTask = nil
                captureWorkerToken = nil
            }
        }

        while !Task.isCancelled, nextPendingCaptureIndex < pendingCaptures.count {
            guard let capture = pendingCaptures[nextPendingCaptureIndex] else {
                nextPendingCaptureIndex += 1
                compactProcessedCaptureSlotsIfNeeded()
                continue
            }
            // Release potentially large pasteboard Data as soon as this worker
            // owns the capture instead of retaining every processed snapshot
            // until a continuously active worker eventually becomes idle.
            pendingCaptures[nextPendingCaptureIndex] = nil
            nextPendingCaptureIndex += 1
            compactProcessedCaptureSlotsIfNeeded()
            let captureBytes = capture.estimatedByteCount
            let item = await makeCapturedItem(
                from: capture.snapshot,
                sourceApp: capture.sourceApp,
                sourceBundleIdentifier: capture.sourceBundleIdentifier,
                privacy: capture.privacy
            )
            if captureWorkerToken == workerToken {
                retainedCaptureCount = max(retainedCaptureCount - 1, 0)
                retainedCaptureBytes = max(retainedCaptureBytes - captureBytes, 0)
            }
            guard !Task.isCancelled, captureWorkerToken == workerToken else { return }
            guard let item else { continue }
            let currentPrivacy = store.snapshot.privacy
            guard !store.isPersistenceWriteBlocked,
                  !currentPrivacy.isCaptureCurrentlyPaused(),
                  !currentPrivacy.excludesApplication(
                      named: capture.sourceApp,
                      bundleIdentifier: capture.sourceBundleIdentifier
                  ) else {
                continue
            }

            // `makeCapturedItem` constructs the item off the main actor and its
            // search document already matches the payload. Rebuilding it here
            // would repeat HTML normalization and SHA256 hashing on MainActor.
            let storedItem = store.addCapturedItemWithCurrentSearchDocument(item)
            onItemCaptured?(storedItem)
            Task {
                await store.enrichLinkPreviewMetadataIfNeeded(for: storedItem)
            }

            if item.contentType == .image,
               store.snapshot.privacy.runLocalOCRAfterImageCapture,
               let imageData = item.payload.imageData {
                Task { [recognizeText] in
                    do {
                        let text = try await recognizeText(imageData)
                        await MainActor.run {
                            self.store.updateOCRText(text, for: storedItem.id)
                        }
                    } catch {
                        await MainActor.run {
                            self.store.markOCRFailed(error.localizedDescription, for: storedItem.id)
                        }
                    }
                }
            }
        }
    }

    private func compactProcessedCaptureSlotsIfNeeded() {
        let compactionThreshold = 64
        guard nextPendingCaptureIndex >= compactionThreshold,
              nextPendingCaptureIndex >= pendingCaptures.count - nextPendingCaptureIndex else {
            return
        }
        pendingCaptures.removeFirst(nextPendingCaptureIndex)
        nextPendingCaptureIndex = 0
    }

    private func makeCapturedItem(
        from snapshot: PasteboardSnapshot,
        sourceApp: String,
        sourceBundleIdentifier: String?,
        privacy: PrivacyConfiguration
    ) async -> ClipboardItem? {
        if let makeItemOverrideForTesting = Self.makeItemOverrideForTesting {
            return await makeItemOverrideForTesting()
        }
        return await Task.detached(priority: .userInitiated) {
            Self.makeItemFromSnapshot(
                snapshot,
                sourceApp: sourceApp,
                sourceBundleIdentifier: sourceBundleIdentifier,
                privacy: privacy
            )
        }.value
    }

    static func makeItem(
        from pasteboard: NSPasteboard,
        sourceApp: String,
        sourceBundleIdentifier: String?,
        privacy: PrivacyConfiguration
    ) -> ClipboardItem? {
        makeItemFromSnapshot(
            snapshot(from: pasteboard, captureImages: privacy.captureImages),
            sourceApp: sourceApp,
            sourceBundleIdentifier: sourceBundleIdentifier,
            privacy: privacy
        )
    }

    nonisolated private struct PasteboardReference: Sendable {
        enum Kind: Sendable {
            case general
            case named(String)
        }

        let kind: Kind

        init(_ pasteboard: NSPasteboard) {
            kind = pasteboard.name == .general ? .general : .named(pasteboard.name.rawValue)
        }

        func makePasteboard() -> NSPasteboard {
            switch kind {
            case .general:
                return .general
            case .named(let name):
                return NSPasteboard(name: .init(name))
            }
        }
    }

    private struct PasteboardReadResult: Sendable {
        var changeCount: Int
        var snapshot: PasteboardSnapshot?
    }

    private struct PasteboardSnapshot: Sendable {
        var urls: [URL]
        var explicitURLString: String?
        var explicitFileURLString: String?
        var rawText: String?
        var htmlString: String?
        var rtfData: Data?
        var imageData: Data?
        var imageDataIsPNG: Bool

        var estimatedByteCount: Int {
            urls.reduce(0) { $0 + $1.absoluteString.utf8.count }
                + (explicitURLString?.utf8.count ?? 0)
                + (explicitFileURLString?.utf8.count ?? 0)
                + (rawText?.utf8.count ?? 0)
                + (htmlString?.utf8.count ?? 0)
                + (rtfData?.count ?? 0)
                + (imageData?.count ?? 0)
        }
    }

    private struct PendingCapture {
        var snapshot: PasteboardSnapshot
        var sourceApp: String
        var sourceBundleIdentifier: String?
        var privacy: PrivacyConfiguration

        var estimatedByteCount: Int {
            snapshot.estimatedByteCount
                + sourceApp.utf8.count
                + (sourceBundleIdentifier?.utf8.count ?? 0)
        }
    }

    nonisolated private static func readPasteboard(
        reference: PasteboardReference,
        expectedChangeCount: Int?,
        shouldCapture: Bool,
        captureImages: Bool
    ) -> PasteboardReadResult {
        let pasteboard = reference.makePasteboard()
        let changeCount = pasteboard.changeCount
        guard let expectedChangeCount,
              changeCount != expectedChangeCount,
              shouldCapture else {
            return PasteboardReadResult(changeCount: changeCount, snapshot: nil)
        }
        guard pasteboard.availableType(from: [PasteboardWriter.internalWriteMarkerType]) == nil else {
            return PasteboardReadResult(changeCount: changeCount, snapshot: nil)
        }
        return PasteboardReadResult(
            changeCount: changeCount,
            snapshot: snapshot(from: pasteboard, captureImages: captureImages)
        )
    }

    nonisolated private static func snapshot(
        from pasteboard: NSPasteboard,
        captureImages: Bool
    ) -> PasteboardSnapshot {
        let pngData = captureImages ? pasteboard.data(forType: .png).flatMap { $0.isEmpty ? nil : $0 } : nil
        let tiffData = captureImages && pngData == nil ? pasteboard.data(forType: .tiff).flatMap { $0.isEmpty ? nil : $0 } : nil
        return PasteboardSnapshot(
            urls: urls(from: pasteboard),
            explicitURLString: pasteboard.string(forType: .URL),
            explicitFileURLString: pasteboard.string(forType: .fileURL),
            rawText: pasteboard.string(forType: .string),
            htmlString: pasteboard.string(forType: .html),
            rtfData: pasteboard.data(forType: .rtf).flatMap { $0.isEmpty ? nil : $0 },
            imageData: pngData ?? tiffData,
            imageDataIsPNG: pngData != nil
        )
    }

    nonisolated private static func makeItemFromSnapshot(
        _ snapshot: PasteboardSnapshot,
        sourceApp: String,
        sourceBundleIdentifier: String?,
        privacy: PrivacyConfiguration
    ) -> ClipboardItem? {
        let deviceName = Host.current().localizedName ?? "This Mac"
        var urlStrings = snapshot.urls
            .compactMap { url in
                url.isFileURL ? nil : ClipboardPayload.normalizedWebURLString(url.absoluteString)
            }
        var fileURLStrings = snapshot.urls
            .filter(\.isFileURL)
            .map(\.absoluteString)

        if let explicitURLString = snapshot.explicitURLString,
           let webURLString = ClipboardPayload.normalizedWebURLString(explicitURLString) {
            urlStrings.append(webURLString)
        }
        if let explicitFileURLString = snapshot.explicitFileURLString,
           let explicitFileURL = URL(string: explicitFileURLString) {
            fileURLStrings.append(explicitFileURL.absoluteString)
        }
        urlStrings = normalizedStrings(urlStrings)
        fileURLStrings = normalizedStrings(fileURLStrings)

        let rawText = snapshot.rawText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let htmlString = snapshot.htmlString?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let rtfData = snapshot.rtfData
        let richTextFallback = htmlString?.pasteBuddyPlainTextFromHTML.nilIfEmpty
            ?? rtfData.flatMap(plainTextFromRTF)

        var text = nonDuplicateText(
            rawText ?? richTextFallback,
            urlStrings: urlStrings,
            fileURLStrings: fileURLStrings
        )
        if urlStrings.isEmpty, fileURLStrings.isEmpty,
           let candidateText = text,
           let webURLString = ClipboardPayload.normalizedWebURLString(candidateText) {
            urlStrings = [webURLString]
            text = nil
        }

        let imageData: Data?
        if privacy.captureImages, let sourceData = snapshot.imageData {
            imageData = snapshot.imageDataIsPNG ? sourceData : pngData(fromImageData: sourceData)
        } else {
            imageData = nil
        }

        if !privacy.captureText {
            text = nil
        }
        if !privacy.captureURLs {
            urlStrings = []
        }
        if !privacy.captureFiles {
            fileURLStrings = []
        }

        let payload = ClipboardPayload(
            text: text,
            htmlString: privacy.captureText ? htmlString : nil,
            rtfData: privacy.captureText ? rtfData : nil,
            urlString: urlStrings.first,
            fileURLString: fileURLStrings.first,
            fileURLStrings: fileURLStrings,
            imageData: imageData
        )
        let contentType = contentType(for: payload)
        guard let contentType, privacy.allowsCapture(of: contentType) else { return nil }

        let item = ClipboardItem(
            sourceAppName: sourceApp,
            sourceBundleIdentifier: sourceBundleIdentifier,
            deviceName: deviceName,
            contentType: contentType,
            title: title(for: contentType, payload: payload),
            payload: payload,
            ocrState: imageData != nil && privacy.runLocalOCRAfterImageCapture ? .pending(Date()) : .notNeeded
        )
        let decision = privacy.captureDecision(
            for: item,
            sourceApplicationName: sourceApp,
            sourceBundleIdentifier: sourceBundleIdentifier
        )
        return decision.isAllowed ? item : nil
    }

    nonisolated private static func pngData(fromImageData data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        return image.pasteBuddyPNGData()
    }

    nonisolated private static func urls(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
    }

    nonisolated private static func normalizedStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(trimmed)
        }
        return result
    }

    nonisolated private static func nonDuplicateText(
        _ candidate: String?,
        urlStrings: [String],
        fileURLStrings: [String]
    ) -> String? {
        guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty else {
            return nil
        }
        let knownRepresentations = urlStrings + fileURLStrings + fileURLStrings.compactMap { URL(string: $0)?.path }
        let candidateKey = candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let isDuplicate = knownRepresentations.contains {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == candidateKey
        }
        return isDuplicate ? nil : candidate
    }

    nonisolated private static func contentType(for payload: ClipboardPayload) -> ClipboardContentType? {
        var types: [ClipboardContentType] = []
        if payload.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || payload.htmlString?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || payload.rtfData?.isEmpty == false {
            types.append(.text)
        }
        if !payload.allURLStrings.isEmpty {
            types.append(.url)
        }
        if !payload.allFileURLStrings.isEmpty {
            types.append(.file)
        }
        if payload.imageData?.isEmpty == false {
            types.append(.image)
        }
        guard !types.isEmpty else { return nil }
        return types.count == 1 ? types[0] : .mixed
    }

    nonisolated private static func title(for contentType: ClipboardContentType, payload: ClipboardPayload) -> String {
        switch contentType {
        case .text:
            return payload.primaryText.singleLinePreview
        case .url:
            if let value = payload.urlString, let url = URL(string: value) {
                return url.host(percentEncoded: false) ?? value.singleLinePreview
            }
            return "Link"
        case .file:
            if payload.allFileURLStrings.count > 1 {
                return "\(payload.allFileURLStrings.count) Files"
            }
            return payload.allFileURLStrings.first
                .flatMap { URL(string: $0)?.lastPathComponent }
                ?? "File"
        case .image:
            return "Screenshot or image"
        case .mixed:
            return "Mixed Clipboard Item"
        }
    }

    nonisolated private static func plainTextFromRTF(_ data: Data) -> String? {
        NSAttributedString(rtf: data, documentAttributes: nil)?
            .string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }
}

public struct ClipboardLinkPreviewMetadata: Sendable {
    public var title: String?
    public var imageData: Data?

    public init(title: String? = nil, imageData: Data? = nil) {
        self.title = title
        self.imageData = imageData
    }
}

public enum ClipboardLinkMetadataFetcher {
    /// Test seam: production always fetches through LinkPresentation.
    @MainActor public static var fetchOverrideForTesting: ((String) async -> ClipboardLinkPreviewMetadata?)?
    @MainActor private static var inFlightRequests: [String: Task<ClipboardLinkPreviewMetadata?, Never>] = [:]
    @MainActor private static var failedFetchDates: [String: Date] = [:]
    private static let failedFetchRetryInterval: TimeInterval = 15 * 60
    private static let failedFetchCapacity = 256

    @MainActor
    public static func fetch(for urlString: String) async -> ClipboardLinkPreviewMetadata? {
        let now = Date()
        if let failedAt = failedFetchDates[urlString],
           now.timeIntervalSince(failedAt) < failedFetchRetryInterval {
            return nil
        }
        if let request = inFlightRequests[urlString] {
            return await request.value
        }

        let request = Task { @MainActor in
            await fetchUncached(for: urlString)
        }
        inFlightRequests[urlString] = request
        let metadata = await request.value
        inFlightRequests.removeValue(forKey: urlString)
        if metadata == nil {
            recordFailedFetch(for: urlString, at: Date())
        } else {
            failedFetchDates.removeValue(forKey: urlString)
        }
        return metadata
    }

    @MainActor
    private static func fetchUncached(for urlString: String) async -> ClipboardLinkPreviewMetadata? {
        if let fetchOverrideForTesting {
            return await fetchOverrideForTesting(urlString)
        }
        guard let url = URL(string: urlString) else { return nil }
        do {
            let metadata = try await LPMetadataProvider().startFetchingMetadata(for: url)
            let imageData = await (metadata.imageProvider ?? metadata.iconProvider)?.pasteBuddyPNGData()
            return ClipboardLinkPreviewMetadata(
                title: nonEmpty(metadata.title),
                imageData: imageData
            )
        } catch {
            return nil
        }
    }

    @MainActor
    private static func recordFailedFetch(for urlString: String, at date: Date) {
        if failedFetchDates.count >= failedFetchCapacity,
           failedFetchDates[urlString] == nil,
           let oldestURL = failedFetchDates.min(by: { $0.value < $1.value })?.key {
            failedFetchDates.removeValue(forKey: oldestURL)
        }
        failedFetchDates[urlString] = date
    }

    @MainActor
    static func resetFetchStateForTesting() {
        for request in inFlightRequests.values {
            request.cancel()
        }
        inFlightRequests.removeAll()
        failedFetchDates.removeAll()
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

private extension NSItemProvider {
    @MainActor
    func pasteBuddyPNGData() async -> Data? {
        await withCheckedContinuation { continuation in
            loadObject(ofClass: NSImage.self) { object, _ in
                continuation.resume(returning: (object as? NSImage)?.pasteBuddyPNGData())
            }
        }
    }
}
#endif
