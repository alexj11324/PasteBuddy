import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct PinboardItemDragPayload: Codable, Transferable {
    let ids: [UUID]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pasteBuddyPinboardItemIDs)
    }
}

extension UTType {
    static let pasteBuddyPinboardItemIDs = UTType(exportedAs: "app.pastebuddy.pinboard-item-ids")
}
