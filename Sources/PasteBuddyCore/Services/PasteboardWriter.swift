#if os(macOS)
import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
public enum PasteboardWriter {
    public enum DirectPasteFallbackBehavior: Equatable, Sendable {
        case copyOnly
        case failWithoutCopying
    }

    public struct DirectPasteOptions: Equatable, Sendable {
        public static let activationWaitTimeoutDefault: TimeInterval = 0.45
        public static let pasteDispatchDelayDefault: TimeInterval = 0
        public static let pasteDispatchDelayUserDefaultsKey = "PasteBuddyDirectPasteDelaySeconds"

        public var activationWaitTimeout: TimeInterval
        public var pasteDispatchDelay: TimeInterval
        public var fallbackBehavior: DirectPasteFallbackBehavior

        public init(
            activationWaitTimeout: TimeInterval = Self.activationWaitTimeoutDefault,
            pasteDispatchDelay: TimeInterval = Self.pasteDispatchDelayDefault,
            fallbackBehavior: DirectPasteFallbackBehavior = .copyOnly
        ) {
            self.activationWaitTimeout = max(0, min(activationWaitTimeout, 1))
            self.pasteDispatchDelay = max(0, min(pasteDispatchDelay, 2))
            self.fallbackBehavior = fallbackBehavior
        }

        public static let `default` = DirectPasteOptions()

        public var pasteOnly: DirectPasteOptions {
            DirectPasteOptions(
                activationWaitTimeout: activationWaitTimeout,
                pasteDispatchDelay: pasteDispatchDelay,
                fallbackBehavior: .failWithoutCopying
            )
        }
    }

    public static var userConfiguredDirectPasteOptions: DirectPasteOptions {
        let configuredDelay = UserDefaults.standard.object(
            forKey: DirectPasteOptions.pasteDispatchDelayUserDefaultsKey
        ) as? TimeInterval
        return DirectPasteOptions(pasteDispatchDelay: configuredDelay ?? DirectPasteOptions.pasteDispatchDelayDefault)
    }

    public static var userConfiguredPasteOnlyDirectPasteOptions: DirectPasteOptions {
        userConfiguredDirectPasteOptions.pasteOnly
    }

    @discardableResult
    public static func copy(
        _ item: ClipboardItem,
        format: PasteFormat = .original,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        pasteboard.clearContents()
        if format == .plainText {
            return pasteboard.setString(plainText(for: item), forType: .string)
        }

        var succeeded = false
        switch item.contentType {
        case .text:
            if let text = item.payload.text {
                succeeded = pasteboard.setString(text, forType: .string) || succeeded
            }
            if let html = item.payload.htmlString {
                succeeded = pasteboard.setString(html, forType: .html) || succeeded
            }
            if let rtfData = item.payload.rtfData {
                succeeded = pasteboard.setData(rtfData, forType: .rtf) || succeeded
            }
        case .url:
            if let value = item.payload.urlString, let url = URL(string: value) {
                succeeded = pasteboard.writeObjects([url as NSURL])
            } else if let value = item.payload.urlString {
                succeeded = pasteboard.setString(value, forType: .string)
            }
        case .file:
            let urls = item.payload.allFileURLStrings.compactMap(URL.init(string:))
            if !urls.isEmpty {
                succeeded = pasteboard.writeObjects(urls.map { $0 as NSURL })
            }
        case .image:
            if let data = item.payload.imageData, let image = NSImage(data: data) {
                succeeded = pasteboard.writeObjects([image])
            }
        case .mixed:
            let urls = item.payload.allFileURLStrings.compactMap(URL.init(string:))
            if !urls.isEmpty {
                succeeded = pasteboard.writeObjects(urls.map { $0 as NSURL }) || succeeded
            }
            if let data = item.payload.imageData, let image = NSImage(data: data) {
                succeeded = pasteboard.writeObjects([image]) || succeeded
            }
            succeeded = pasteboard.setString(plainText(for: item), forType: .string) || succeeded
            if let html = item.payload.htmlString {
                succeeded = pasteboard.setString(html, forType: .html) || succeeded
            }
            if let rtfData = item.payload.rtfData {
                succeeded = pasteboard.setData(rtfData, forType: .rtf) || succeeded
            }
        }
        return succeeded
    }

    @discardableResult
    public static func copy(
        _ items: [ClipboardItem],
        format: PasteFormat = .original,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        guard !items.isEmpty else {
            return false
        }
        if items.count == 1, let item = items.first {
            return copy(item, format: format, to: pasteboard)
        }

        pasteboard.clearContents()
        return pasteboard.setString(plainText(for: items), forType: .string)
    }

    public static func itemProviders(
        for items: [ClipboardItem],
        hydrate: @escaping @MainActor (ClipboardItem) async -> ClipboardItem
    ) -> [NSItemProvider] {
        guard items.count == 1, let item = items.first else {
            return items.isEmpty ? [] : [NSItemProvider(object: plainText(for: items) as NSString)]
        }
        return itemProviders(for: item, hydrate: hydrate)
    }

    @discardableResult
    public static func pasteToFrontmostApp(
        _ item: ClipboardItem,
        format: PasteFormat = .original,
        to pasteboard: NSPasteboard = .general,
        isAccessibilityTrusted: Bool = AccessibilityPermissionService.isTrusted,
        targetBundleIdentifier: String? = nil,
        activeApplicationBundleIdentifier: (() -> String?)? = nil,
        options: DirectPasteOptions = .default,
        prepareForPaste: (() -> Void)? = nil,
        sendPasteEvent: (() -> Void)? = nil
    ) -> DirectPasteResult {
        guard isAccessibilityTrusted else {
            return copyFallbackResult(
                item,
                format: format,
                to: pasteboard,
                outcome: .copiedOnlyAccessibilityRequired,
                options: options
            )
        }
        prepareForPaste?()
        guard waitForTargetApplicationIfNeeded(
            targetBundleIdentifier: targetBundleIdentifier,
            activeApplicationBundleIdentifier: activeApplicationBundleIdentifier,
            timeout: options.activationWaitTimeout
        ) else {
            return copyFallbackResult(
                item,
                format: format,
                to: pasteboard,
                outcome: .copiedOnlyNoTargetApplication,
                options: options
            )
        }
        copy(item, format: format, to: pasteboard)
        waitBeforePasteEvent(options.pasteDispatchDelay)
        if let sendPasteEvent {
            sendPasteEvent()
        } else {
            sendCommandV()
        }
        return DirectPasteResult(outcome: .pastedToFrontmostApp, itemCount: 1, format: format)
    }

    @discardableResult
    public static func pasteToFrontmostAppAsync(
        _ item: ClipboardItem,
        format: PasteFormat = .original,
        to pasteboard: NSPasteboard = .general,
        isAccessibilityTrusted: Bool = AccessibilityPermissionService.isTrusted,
        targetBundleIdentifier: String? = nil,
        activeApplicationBundleIdentifier: (() -> String?)? = nil,
        options: DirectPasteOptions = .default,
        prepareForPaste: (() -> Void)? = nil,
        sendPasteEvent: (() -> Void)? = nil
    ) async -> DirectPasteResult {
        guard isAccessibilityTrusted else {
            return copyFallbackResult(
                item,
                format: format,
                to: pasteboard,
                outcome: .copiedOnlyAccessibilityRequired,
                options: options
            )
        }
        prepareForPaste?()
        guard await waitForTargetApplicationIfNeededAsync(
            targetBundleIdentifier: targetBundleIdentifier,
            activeApplicationBundleIdentifier: activeApplicationBundleIdentifier,
            timeout: options.activationWaitTimeout
        ) else {
            return copyFallbackResult(
                item,
                format: format,
                to: pasteboard,
                outcome: .copiedOnlyNoTargetApplication,
                options: options
            )
        }
        copy(item, format: format, to: pasteboard)
        await waitBeforePasteEventAsync(options.pasteDispatchDelay)
        if let sendPasteEvent {
            sendPasteEvent()
        } else {
            sendCommandV()
        }
        return DirectPasteResult(outcome: .pastedToFrontmostApp, itemCount: 1, format: format)
    }

    @discardableResult
    public static func pasteToFrontmostApp(
        _ items: [ClipboardItem],
        format: PasteFormat = .original,
        to pasteboard: NSPasteboard = .general,
        isAccessibilityTrusted: Bool = AccessibilityPermissionService.isTrusted,
        targetBundleIdentifier: String? = nil,
        activeApplicationBundleIdentifier: (() -> String?)? = nil,
        options: DirectPasteOptions = .default,
        prepareForPaste: (() -> Void)? = nil,
        sendPasteEvent: (() -> Void)? = nil
    ) -> DirectPasteResult {
        guard !items.isEmpty else {
            return DirectPasteResult(outcome: .emptySelection, itemCount: 0, format: format)
        }
        if items.count == 1, let item = items.first {
            return pasteToFrontmostApp(
                item,
                format: format,
                to: pasteboard,
                isAccessibilityTrusted: isAccessibilityTrusted,
                targetBundleIdentifier: targetBundleIdentifier,
                activeApplicationBundleIdentifier: activeApplicationBundleIdentifier,
                options: options,
                prepareForPaste: prepareForPaste,
                sendPasteEvent: sendPasteEvent
            )
        }
        guard isAccessibilityTrusted else {
            return copyFallbackResult(
                items,
                format: format,
                to: pasteboard,
                outcome: .copiedOnlyAccessibilityRequired,
                options: options
            )
        }
        prepareForPaste?()
        guard waitForTargetApplicationIfNeeded(
            targetBundleIdentifier: targetBundleIdentifier,
            activeApplicationBundleIdentifier: activeApplicationBundleIdentifier,
            timeout: options.activationWaitTimeout
        ) else {
            return copyFallbackResult(
                items,
                format: format,
                to: pasteboard,
                outcome: .copiedOnlyNoTargetApplication,
                options: options
            )
        }
        copy(items, format: format, to: pasteboard)
        waitBeforePasteEvent(options.pasteDispatchDelay)
        if let sendPasteEvent {
            sendPasteEvent()
        } else {
            sendCommandV()
        }
        return DirectPasteResult(outcome: .pastedToFrontmostApp, itemCount: items.count, format: format)
    }

    @discardableResult
    public static func pasteToFrontmostAppAsync(
        _ items: [ClipboardItem],
        format: PasteFormat = .original,
        to pasteboard: NSPasteboard = .general,
        isAccessibilityTrusted: Bool = AccessibilityPermissionService.isTrusted,
        targetBundleIdentifier: String? = nil,
        activeApplicationBundleIdentifier: (() -> String?)? = nil,
        options: DirectPasteOptions = .default,
        prepareForPaste: (() -> Void)? = nil,
        sendPasteEvent: (() -> Void)? = nil
    ) async -> DirectPasteResult {
        guard !items.isEmpty else {
            return DirectPasteResult(outcome: .emptySelection, itemCount: 0, format: format)
        }
        if items.count == 1, let item = items.first {
            return await pasteToFrontmostAppAsync(
                item,
                format: format,
                to: pasteboard,
                isAccessibilityTrusted: isAccessibilityTrusted,
                targetBundleIdentifier: targetBundleIdentifier,
                activeApplicationBundleIdentifier: activeApplicationBundleIdentifier,
                options: options,
                prepareForPaste: prepareForPaste,
                sendPasteEvent: sendPasteEvent
            )
        }
        guard isAccessibilityTrusted else {
            return copyFallbackResult(
                items,
                format: format,
                to: pasteboard,
                outcome: .copiedOnlyAccessibilityRequired,
                options: options
            )
        }
        prepareForPaste?()
        guard await waitForTargetApplicationIfNeededAsync(
            targetBundleIdentifier: targetBundleIdentifier,
            activeApplicationBundleIdentifier: activeApplicationBundleIdentifier,
            timeout: options.activationWaitTimeout
        ) else {
            return copyFallbackResult(
                items,
                format: format,
                to: pasteboard,
                outcome: .copiedOnlyNoTargetApplication,
                options: options
            )
        }
        copy(items, format: format, to: pasteboard)
        await waitBeforePasteEventAsync(options.pasteDispatchDelay)
        if let sendPasteEvent {
            sendPasteEvent()
        } else {
            sendCommandV()
        }
        return DirectPasteResult(outcome: .pastedToFrontmostApp, itemCount: items.count, format: format)
    }

    public static func plainText(for item: ClipboardItem) -> String {
        ClipboardPlainTextRenderer.plainText(for: item)
    }

    public static func plainText(for items: [ClipboardItem]) -> String {
        ClipboardPlainTextRenderer.plainText(for: items)
    }

    private static func itemProviders(
        for item: ClipboardItem,
        hydrate: @escaping @MainActor (ClipboardItem) async -> ClipboardItem
    ) -> [NSItemProvider] {
        switch item.contentType {
        case .text:
            return [textProvider(for: item, hydrate: hydrate)]
        case .url:
            if let value = item.payload.urlString, let url = URL(string: value) {
                return [NSItemProvider(object: url as NSURL)]
            }
        case .file:
            let providers = item.payload.allFileURLStrings
                .compactMap(URL.init(string:))
                .map { NSItemProvider(object: $0 as NSURL) }
            if !providers.isEmpty {
                return providers
            }
        case .image:
            if let provider = imageProvider(for: item, hydrate: hydrate) {
                return [provider]
            }
        case .mixed:
            var providers = item.payload.allFileURLStrings
                .compactMap(URL.init(string:))
                .map { NSItemProvider(object: $0 as NSURL) }
            let provider = textProvider(for: item, hydrate: hydrate)
            registerImageRepresentation(for: item, on: provider, hydrate: hydrate)
            providers.insert(provider, at: 0)
            return providers
        }
        return [NSItemProvider(object: plainText(for: item) as NSString)]
    }

    private static func textProvider(
        for item: ClipboardItem,
        hydrate: @escaping @MainActor (ClipboardItem) async -> ClipboardItem
    ) -> NSItemProvider {
        let provider = NSItemProvider(object: plainText(for: item) as NSString)
        if let html = item.payload.htmlString {
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.html.identifier,
                visibility: .all
            ) { completion in
                completion(Data(html.utf8), nil)
                return nil
            }
        }
        if let rtfData = item.payload.rtfData {
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.rtf.identifier,
                visibility: .all
            ) { completion in
                completion(rtfData, nil)
                return nil
            }
        } else if item.payload.rtfAssetID != nil {
            registerHydratedDataRepresentation(
                UTType.rtf,
                for: item,
                on: provider,
                hydrate: hydrate,
                data: \.payload.rtfData
            )
        }
        return provider
    }

    private static func imageProvider(
        for item: ClipboardItem,
        hydrate: @escaping @MainActor (ClipboardItem) async -> ClipboardItem
    ) -> NSItemProvider? {
        if let data = item.payload.imageData, let image = NSImage(data: data) {
            return NSItemProvider(object: image)
        }
        guard item.payload.imageAssetID != nil else { return nil }
        let provider = NSItemProvider()
        registerImageRepresentation(for: item, on: provider, hydrate: hydrate)
        return provider
    }

    private static func registerImageRepresentation(
        for item: ClipboardItem,
        on provider: NSItemProvider,
        hydrate: @escaping @MainActor (ClipboardItem) async -> ClipboardItem
    ) {
        if let data = item.payload.imageData,
           let tiffData = NSImage(data: data)?.tiffRepresentation {
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.tiff.identifier,
                visibility: .all
            ) { completion in
                completion(tiffData, nil)
                return nil
            }
        } else if item.payload.imageAssetID != nil {
            registerHydratedDataRepresentation(
                UTType.tiff,
                for: item,
                on: provider,
                hydrate: hydrate
            ) { hydratedItem in
                hydratedItem.payload.imageData.flatMap { NSImage(data: $0)?.tiffRepresentation }
            }
        }
    }

    private static func registerHydratedDataRepresentation(
        _ type: UTType,
        for item: ClipboardItem,
        on provider: NSItemProvider,
        hydrate: @escaping @MainActor (ClipboardItem) async -> ClipboardItem,
        data: @escaping @MainActor (ClipboardItem) -> Data?
    ) {
        provider.registerDataRepresentation(
            forTypeIdentifier: type.identifier,
            visibility: .all
        ) { completion in
            let progress = Progress(totalUnitCount: 1)
            Task { @MainActor in
                if let hydratedData = data(await hydrate(item)) {
                    completion(hydratedData, nil)
                } else {
                    completion(nil, CocoaError(.fileReadNoSuchFile))
                }
                progress.completedUnitCount = 1
            }
            return progress
        }
    }

    private static func copyFallbackResult(
        _ item: ClipboardItem,
        format: PasteFormat,
        to pasteboard: NSPasteboard,
        outcome: DirectPasteOutcome,
        options: DirectPasteOptions
    ) -> DirectPasteResult {
        if options.fallbackBehavior == .copyOnly {
            copy(item, format: format, to: pasteboard)
        }
        return DirectPasteResult(
            outcome: fallbackOutcome(for: outcome, options: options),
            itemCount: 1,
            format: format
        )
    }

    private static func copyFallbackResult(
        _ items: [ClipboardItem],
        format: PasteFormat,
        to pasteboard: NSPasteboard,
        outcome: DirectPasteOutcome,
        options: DirectPasteOptions
    ) -> DirectPasteResult {
        if options.fallbackBehavior == .copyOnly {
            copy(items, format: format, to: pasteboard)
        }
        return DirectPasteResult(
            outcome: fallbackOutcome(for: outcome, options: options),
            itemCount: items.count,
            format: format
        )
    }

    private static func fallbackOutcome(
        for copyOutcome: DirectPasteOutcome,
        options: DirectPasteOptions
    ) -> DirectPasteOutcome {
        guard options.fallbackBehavior == .failWithoutCopying else {
            return copyOutcome
        }
        switch copyOutcome {
        case .copiedOnlyAccessibilityRequired:
            return .failedAccessibilityPermissionRequired
        case .copiedOnlyNoTargetApplication:
            return .failedNoTargetApplication
        case .pastedToFrontmostApp, .failedAccessibilityPermissionRequired, .failedNoTargetApplication, .emptySelection:
            return copyOutcome
        }
    }

    private static func waitForTargetApplicationIfNeeded(
        targetBundleIdentifier: String?,
        activeApplicationBundleIdentifier: (() -> String?)?,
        timeout: TimeInterval
    ) -> Bool {
        guard let targetBundleIdentifier = normalizedBundleIdentifier(targetBundleIdentifier),
              let activeApplicationBundleIdentifier
        else {
            return true
        }

        let deadline = Date().addingTimeInterval(max(0, timeout))
        repeat {
            if normalizedBundleIdentifier(activeApplicationBundleIdentifier()) == targetBundleIdentifier {
                return true
            }
            guard Date() < deadline else { break }
            sleepBriefly(until: min(deadline, Date().addingTimeInterval(0.005)))
        } while true

        return normalizedBundleIdentifier(activeApplicationBundleIdentifier()) == targetBundleIdentifier
    }

    private static func waitForTargetApplicationIfNeededAsync(
        targetBundleIdentifier: String?,
        activeApplicationBundleIdentifier: (() -> String?)?,
        timeout: TimeInterval
    ) async -> Bool {
        guard let targetBundleIdentifier = normalizedBundleIdentifier(targetBundleIdentifier),
              let activeApplicationBundleIdentifier
        else {
            return true
        }

        let deadline = Date().addingTimeInterval(max(0, timeout))
        repeat {
            if normalizedBundleIdentifier(activeApplicationBundleIdentifier()) == targetBundleIdentifier {
                return true
            }
            guard Date() < deadline else { break }
            await sleepAsync(until: min(deadline, Date().addingTimeInterval(0.005)))
        } while true

        return normalizedBundleIdentifier(activeApplicationBundleIdentifier()) == targetBundleIdentifier
    }

    private static func waitBeforePasteEvent(_ delay: TimeInterval) {
        guard delay > 0 else { return }
        let deadline = Date().addingTimeInterval(delay)
        repeat {
            sleepBriefly(until: min(deadline, Date().addingTimeInterval(0.005)))
        } while Date() < deadline
    }

    private static func waitBeforePasteEventAsync(_ delay: TimeInterval) async {
        guard delay > 0 else { return }
        let deadline = Date().addingTimeInterval(delay)
        repeat {
            await sleepAsync(until: min(deadline, Date().addingTimeInterval(0.005)))
        } while Date() < deadline
    }

    private static func sleepBriefly(until deadline: Date) {
        let interval = deadline.timeIntervalSinceNow
        guard interval > 0 else { return }
        Thread.sleep(forTimeInterval: interval)
    }

    private static func sleepAsync(until deadline: Date) async {
        let interval = deadline.timeIntervalSinceNow
        guard interval > 0 else { return }
        try? await Task.sleep(nanoseconds: nanoseconds(for: interval))
    }

    private static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        UInt64(max(0, interval) * 1_000_000_000)
    }

    private static func normalizedBundleIdentifier(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    private static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
#endif
