#if os(macOS)
import AppKit
import Foundation

@MainActor
public enum PasteboardWriter {
    public enum DirectPasteFallbackBehavior: Equatable, Sendable {
        case copyOnly
        case failWithoutCopying
    }

    public struct DirectPasteOptions: Equatable, Sendable {
        public static let activationWaitTimeoutDefault: TimeInterval = 0.45
        public static let pasteDispatchDelayDefault: TimeInterval = 0.06
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

    public static func copy(_ item: ClipboardItem, format: PasteFormat = .original, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        if format == .plainText {
            pasteboard.setString(plainText(for: item), forType: .string)
            return
        }

        switch item.contentType {
        case .text:
            if let text = item.payload.text {
                pasteboard.setString(text, forType: .string)
            }
            if let html = item.payload.htmlString {
                pasteboard.setString(html, forType: .html)
            }
            if let rtfData = item.payload.rtfData {
                pasteboard.setData(rtfData, forType: .rtf)
            }
        case .url:
            if let value = item.payload.urlString, let url = URL(string: value) {
                pasteboard.writeObjects([url as NSURL])
            } else if let value = item.payload.urlString {
                pasteboard.setString(value, forType: .string)
            }
        case .file:
            let urls = item.payload.allFileURLStrings.compactMap(URL.init(string:))
            if !urls.isEmpty {
                pasteboard.writeObjects(urls.map { $0 as NSURL })
            }
        case .image:
            if let data = item.payload.imageData, let image = NSImage(data: data) {
                pasteboard.writeObjects([image])
            }
        case .mixed:
            let urls = item.payload.allFileURLStrings.compactMap(URL.init(string:))
            if !urls.isEmpty {
                pasteboard.writeObjects(urls.map { $0 as NSURL })
            }
            if let data = item.payload.imageData, let image = NSImage(data: data) {
                pasteboard.writeObjects([image])
            }
            pasteboard.setString(plainText(for: item), forType: .string)
            if let html = item.payload.htmlString {
                pasteboard.setString(html, forType: .html)
            }
            if let rtfData = item.payload.rtfData {
                pasteboard.setData(rtfData, forType: .rtf)
            }
        }
    }

    public static func copy(_ items: [ClipboardItem], format: PasteFormat = .original, to pasteboard: NSPasteboard = .general) {
        guard !items.isEmpty else {
            return
        }
        if items.count == 1, let item = items.first {
            copy(item, format: format, to: pasteboard)
            return
        }

        pasteboard.clearContents()
        pasteboard.setString(plainText(for: items), forType: .string)
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
        return DirectPasteResult(outcome: outcome, itemCount: 1, format: format)
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
        return DirectPasteResult(outcome: outcome, itemCount: items.count, format: format)
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
