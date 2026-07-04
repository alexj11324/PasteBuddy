import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct PinboardItemDragPayload: Codable, Transferable {
    let ids: [UUID]
    let plainText: String

    init(ids: [UUID], plainText: String = "") {
        self.ids = ids
        self.plainText = plainText
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pasteBuddyPinboardItemIDs)
        ProxyRepresentation(exporting: \.plainText)
    }
}

extension UTType {
    static let pasteBuddyPinboardItemIDs = UTType(exportedAs: "app.pastebuddy.pinboard-item-ids")
}
