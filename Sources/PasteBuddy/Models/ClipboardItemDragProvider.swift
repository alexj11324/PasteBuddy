import AppKit
import Foundation
import PasteBuddyCore
import UniformTypeIdentifiers

@MainActor
enum ClipboardItemDragProvider {
    static func provider(for items: [ClipboardItem]) -> NSItemProvider {
        let provider = baseProvider(for: items)
        registerPinboardPayload(on: provider, ids: items.map(\.id))
        registerPlainText(on: provider, text: PasteboardWriter.plainText(for: items))

        if items.count == 1, let item = items.first {
            registerRichRepresentations(on: provider, item: item)
        }

        return provider
    }

    private static func baseProvider(for items: [ClipboardItem]) -> NSItemProvider {
        guard items.count == 1, let item = items.first else {
            return NSItemProvider(object: PasteboardWriter.plainText(for: items) as NSString)
        }

        switch item.contentType {
        case .image, .mixed:
            if let data = item.payload.imageData, let image = NSImage(data: data) {
                return NSItemProvider(object: image)
            }
        case .url:
            if let value = item.payload.urlString, let url = URL(string: value) {
                return NSItemProvider(object: url as NSURL)
            }
        case .file:
            if let value = item.payload.allFileURLStrings.first,
               let url = URL(string: value),
               let provider = NSItemProvider(contentsOf: url) {
                return provider
            }
        case .text:
            break
        }

        return NSItemProvider(object: PasteboardWriter.plainText(for: item) as NSString)
    }

    private static func registerPinboardPayload(on provider: NSItemProvider, ids: [UUID]) {
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.pasteBuddyPinboardItemIDs.identifier,
            visibility: .all
        ) { completion in
            do {
                completion(try JSONEncoder().encode(PinboardItemDragPayload(ids: ids)), nil)
            } catch {
                completion(nil, error)
            }
            return nil
        }
    }

    private static func registerPlainText(on provider: NSItemProvider, text: String) {
        guard let data = text.data(using: .utf8) else { return }
        provider.registerObject(text as NSString, visibility: .all)
        for type in [UTType.utf8PlainText, .plainText, .text] {
            provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
        }
    }

    private static func registerRichRepresentations(on provider: NSItemProvider, item: ClipboardItem) {
        if let value = item.payload.urlString, let url = URL(string: value) {
            provider.registerObject(url as NSURL, visibility: .all)
        }

        if let htmlString = item.payload.htmlString,
           let data = htmlString.data(using: .utf8) {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.html.identifier, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
        }

        if let rtfData = item.payload.rtfData {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.rtf.identifier, visibility: .all) { completion in
                completion(rtfData, nil)
                return nil
            }
        }
    }
}
