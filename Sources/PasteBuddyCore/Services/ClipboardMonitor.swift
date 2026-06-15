#if os(macOS)
import AppKit
import CryptoKit
import Foundation

@MainActor
public final class ClipboardMonitor {
    private let store: PasteBuddyStore
    private let pasteboard: NSPasteboard
    private let recognizeText: @Sendable (Data) async throws -> String
    private var timer: Timer?
    private var lastChangeCount: Int
    private var lastFingerprint: String?

    public init(
        store: PasteBuddyStore,
        pasteboard: NSPasteboard = .general,
        ocrService: OCRService = OCRService(),
        recognizeText: (@Sendable (Data) async throws -> String)? = nil
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.recognizeText = recognizeText ?? { imageData in
            try await ocrService.recognizeText(in: imageData)
        }
        self.lastChangeCount = pasteboard.changeCount
    }

    public func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollOnce()
            }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    func pollOnce() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        let privacy = store.snapshot.privacy
        guard !privacy.isCaptureCurrentlyPaused() else { return }

        let sourceApplication = NSWorkspace.shared.frontmostApplication
        let sourceApp = sourceApplication?.localizedName ?? "Unknown"
        let bundleIdentifier = sourceApplication?.bundleIdentifier
        guard !privacy.excludesApplication(named: sourceApp, bundleIdentifier: bundleIdentifier) else { return }

        guard let item = Self.makeItem(
            from: pasteboard,
            sourceApp: sourceApp,
            sourceBundleIdentifier: bundleIdentifier,
            privacy: privacy
        ) else { return }
        let fingerprint = fingerprint(for: item)
        guard fingerprint != lastFingerprint else { return }
        lastFingerprint = fingerprint

        let storedItem = store.addCapturedItem(item)

        if item.contentType == .image,
           store.snapshot.privacy.runLocalOCRAfterImageCapture,
           let imageData = item.payload.imageData {
            Task {
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

    static func makeItem(
        from pasteboard: NSPasteboard,
        sourceApp: String,
        sourceBundleIdentifier: String?,
        privacy: PrivacyConfiguration
    ) -> ClipboardItem? {
        let deviceName = Host.current().localizedName ?? "This Mac"
        let pasteboardURLs = Self.urls(from: pasteboard)
        var urlStrings = pasteboardURLs
            .filter { !$0.isFileURL }
            .map(\.absoluteString)
        var fileURLStrings = pasteboardURLs
            .filter(\.isFileURL)
            .map(\.absoluteString)

        if let explicitURLString = pasteboard.string(forType: .URL),
           let explicitURL = URL(string: explicitURLString),
           !explicitURL.isFileURL {
            urlStrings.append(explicitURL.absoluteString)
        }
        if let explicitFileURLString = pasteboard.string(forType: .fileURL),
           let explicitFileURL = URL(string: explicitFileURLString) {
            fileURLStrings.append(explicitFileURL.absoluteString)
        }
        urlStrings = Self.normalizedStrings(urlStrings)
        fileURLStrings = Self.normalizedStrings(fileURLStrings)

        let rawText = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let htmlString = pasteboard.string(forType: .html)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let rtfData = pasteboard.data(forType: .rtf).flatMap { $0.isEmpty ? nil : $0 }
        let richTextFallback = htmlString?.pasteBuddyPlainTextFromHTML.nilIfEmpty
            ?? rtfData.flatMap(Self.plainTextFromRTF)

        var text = Self.nonDuplicateText(
            rawText ?? richTextFallback,
            urlStrings: urlStrings,
            fileURLStrings: fileURLStrings
        )
        if text == nil, urlStrings.isEmpty, fileURLStrings.isEmpty,
           let rawText,
           let url = URL(string: rawText),
           url.scheme != nil,
           url.host() != nil {
            urlStrings = [url.absoluteString]
        }

        let imageData: Data?
        if privacy.captureImages,
           let image = NSImage(pasteboard: pasteboard),
           let data = image.pasteBuddyPNGData() {
            imageData = data
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
        let contentType = Self.contentType(for: payload)
        guard let contentType, privacy.allowsCapture(of: contentType) else { return nil }

        let item = ClipboardItem(
            sourceAppName: sourceApp,
            sourceBundleIdentifier: sourceBundleIdentifier,
            deviceName: deviceName,
            contentType: contentType,
            title: Self.title(for: contentType, payload: payload),
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

    private func fingerprint(for item: ClipboardItem) -> String {
        let data = Data(item.payload.searchableText.utf8) + (item.payload.imageData ?? Data())
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func urls(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
    }

    private static func normalizedStrings(_ values: [String]) -> [String] {
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

    private static func nonDuplicateText(
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

    private static func contentType(for payload: ClipboardPayload) -> ClipboardContentType? {
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

    private static func title(for contentType: ClipboardContentType, payload: ClipboardPayload) -> String {
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

    private static func plainTextFromRTF(_ data: Data) -> String? {
        NSAttributedString(rtf: data, documentAttributes: nil)?
            .string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }
}
#endif
