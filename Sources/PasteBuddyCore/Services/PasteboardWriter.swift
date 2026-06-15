#if os(macOS)
import AppKit
import Foundation

@MainActor
public enum PasteboardWriter {
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
        prepareForPaste: (() -> Void)? = nil,
        sendPasteEvent: (() -> Void)? = nil
    ) -> DirectPasteResult {
        copy(item, format: format, to: pasteboard)
        guard isAccessibilityTrusted else {
            return DirectPasteResult(
                outcome: .copiedOnlyAccessibilityRequired,
                itemCount: 1,
                format: format
            )
        }
        prepareForPaste?()
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
                prepareForPaste: prepareForPaste,
                sendPasteEvent: sendPasteEvent
            )
        }
        copy(items, format: format, to: pasteboard)
        guard isAccessibilityTrusted else {
            return DirectPasteResult(
                outcome: .copiedOnlyAccessibilityRequired,
                itemCount: items.count,
                format: format
            )
        }
        prepareForPaste?()
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
