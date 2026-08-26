import CoreTransferable
import Foundation
import PasteBuddyCore
import UniformTypeIdentifiers

struct PinboardItemDragPayload: Codable, Transferable {
    let ids: [UUID]

    init(ids: [UUID]) {
        self.ids = ids
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pasteBuddyPinboardItemIDs)
    }

    @MainActor
    static func itemProvider(
        for item: ClipboardItem,
        hydrate: @escaping @MainActor (ClipboardItem) async -> ClipboardItem
    ) -> NSItemProvider? {
        let providers = PasteboardWriter.itemProviders(
            for: [item],
            preferredContentType: item.presentationContentType,
            hydrate: hydrate
        )
        guard !providers.isEmpty,
              let payload = try? JSONEncoder().encode(Self(ids: [item.id])) else {
            return nil
        }
        let provider = providers.count == 1
            ? providers[0]
            : NSItemProvider(object: PasteboardWriter.plainText(for: item) as NSString)
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.pasteBuddyPinboardItemIDs.identifier,
            visibility: .all
        ) { completion in
            completion(payload, nil)
            return nil
        }
        if item.presentationContentType != .image,
           !provider.registeredTypeIdentifiers.contains(UTType.utf8PlainText.identifier) {
            let text = Data(PasteboardWriter.plainText(for: item).utf8)
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.utf8PlainText.identifier,
                visibility: .all
            ) { completion in
                completion(text, nil)
                return nil
            }
        }
        return provider
    }
}

extension UTType {
    static let pasteBuddyPinboardItemIDs = UTType(exportedAs: "app.pastebuddy.pinboard-item-ids")
}
