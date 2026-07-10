import Foundation
import PasteBuddyCore
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

@MainActor
public enum MobilePasteboardWriter {
    enum CopyRepresentation {
        case string(String)
        case url(URL)
        case imageData(Data, typeIdentifier: String)
    }

    public static func currentClipboardItem(deviceName: String = PasteBuddyStore.defaultDeviceName) async -> ClipboardItem? {
        #if canImport(UIKit)
        if let url = UIPasteboard.general.url {
            let urlString = url.absoluteString
            return await Task.detached(priority: .userInitiated) {
                ClipboardItem(
                    sourceAppName: "iPhone Clipboard",
                    deviceName: deviceName,
                    contentType: .url,
                    title: urlString.singleLinePreview,
                    payload: ClipboardPayload(text: urlString, urlString: urlString)
                )
            }.value
        }
        if let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return await Task.detached(priority: .userInitiated) {
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
            }.value
        }
        if let pasteboardType = UIPasteboard.general.types.first(where: { typeIdentifier in
            UTType(typeIdentifier)?.conforms(to: .image) == true
        }),
           let imageData = UIPasteboard.general.data(forPasteboardType: pasteboardType) {
            let imageSafetyPolicy = MobileImageSafetyPolicy.default
            return await Task.detached(priority: .userInitiated) {
                guard (try? imageSafetyPolicy.validate(imageData)) != nil else { return nil }
                return ClipboardItem(
                    sourceAppName: "iPhone Clipboard",
                    deviceName: deviceName,
                    contentType: .image,
                    title: PasteBuddyLocalization.string("label.image", defaultValue: "Image"),
                    payload: ClipboardPayload(imageData: imageData)
                )
            }.value
        }
        #endif
        return nil
    }

    @discardableResult
    public static func copy(_ item: ClipboardItem, format: PasteFormat = .original) -> Bool {
        #if canImport(UIKit)
        guard let representation = copyRepresentation(for: item, format: format) else {
            return false
        }
        switch representation {
        case .string(let value):
            UIPasteboard.general.string = value
        case .url(let url):
            UIPasteboard.general.url = url
        case .imageData(let data, let typeIdentifier):
            UIPasteboard.general.setData(data, forPasteboardType: typeIdentifier)
        }
        return true
        #else
        return false
        #endif
    }

    static func copyRepresentation(
        for item: ClipboardItem,
        format: PasteFormat
    ) -> CopyRepresentation? {
        if format == .plainText {
            return .string(ClipboardPlainTextRenderer.plainText(for: item))
        }

        switch item.contentType {
        case .text:
            return item.payload.text.map(CopyRepresentation.string)
        case .url:
            guard let value = item.payload.urlString else { return nil }
            if let url = URL(string: value) {
                return .url(url)
            }
            return .string(value)
        case .file, .mixed:
            return .string(ClipboardPlainTextRenderer.plainText(for: item))
        case .image:
            guard let data = item.payload.imageData,
                  let typeIdentifier = try? MobileImageSafetyPolicy.default.validate(data) else {
                return nil
            }
            return .imageData(data, typeIdentifier: typeIdentifier)
        }
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
