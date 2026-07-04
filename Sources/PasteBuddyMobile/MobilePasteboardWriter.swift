import Foundation
import PasteBuddyCore

#if canImport(UIKit)
import UIKit
#endif

@MainActor
public enum MobilePasteboardWriter {
    public static func currentClipboardItem(deviceName: String = PasteBuddyStore.defaultDeviceName) -> ClipboardItem? {
        #if canImport(UIKit)
        if let url = UIPasteboard.general.url {
            let urlString = url.absoluteString
            return ClipboardItem(
                sourceAppName: "iPhone Clipboard",
                deviceName: deviceName,
                contentType: .url,
                title: urlString.singleLinePreview,
                payload: ClipboardPayload(text: urlString, urlString: urlString)
            )
        }
        if let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            if let urlString = ClipboardPayload.normalizedWebURLString(text) {
                return ClipboardItem(
                    sourceAppName: "iPhone Clipboard",
                    deviceName: deviceName,
                    contentType: .url,
                    title: urlString.singleLinePreview,
                    payload: ClipboardPayload(text: text, urlString: urlString)
                )
            }
            return ClipboardItem(
                sourceAppName: "iPhone Clipboard",
                deviceName: deviceName,
                contentType: .text,
                title: text.singleLinePreview,
                payload: ClipboardPayload(text: text)
            )
        }
        if let image = UIPasteboard.general.image,
           let imageData = image.pngData() {
            return ClipboardItem(
                sourceAppName: "iPhone Clipboard",
                deviceName: deviceName,
                contentType: .image,
                title: PasteBuddyLocalization.string("label.image", defaultValue: "Image"),
                payload: ClipboardPayload(imageData: imageData)
            )
        }
        #endif
        return nil
    }

    @discardableResult
    public static func copy(_ item: ClipboardItem, format: PasteFormat = .original) -> Bool {
        #if canImport(UIKit)
        switch item.contentType {
        case .text:
            UIPasteboard.general.string = format == .plainText
                ? ClipboardPlainTextRenderer.plainText(for: item)
                : item.payload.text
        case .url:
            if format == .plainText {
                UIPasteboard.general.string = ClipboardPlainTextRenderer.plainText(for: item)
            } else if let value = item.payload.urlString, let url = URL(string: value) {
                UIPasteboard.general.url = url
            } else {
                UIPasteboard.general.string = item.payload.urlString
            }
        case .file:
            UIPasteboard.general.string = ClipboardPlainTextRenderer.plainText(for: item)
        case .image:
            if format == .plainText {
                UIPasteboard.general.string = ClipboardPlainTextRenderer.plainText(for: item)
            } else if let imageData = item.payload.imageData, let image = UIImage(data: imageData) {
                UIPasteboard.general.image = image
            }
        case .mixed:
            UIPasteboard.general.string = ClipboardPlainTextRenderer.plainText(for: item)
        }
        return true
        #else
        return false
        #endif
    }

    @discardableResult
    public static func copy(_ items: [ClipboardItem], format: PasteFormat = .original) -> Bool {
        guard !items.isEmpty else { return false }
        if items.count == 1, let item = items.first {
            return copy(item, format: format)
        }
        #if canImport(UIKit)
        UIPasteboard.general.string = ClipboardPlainTextRenderer.plainText(for: items)
        return true
        #else
        return false
        #endif
    }
}
