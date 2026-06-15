import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct MobilePinboardItemDragPayload: Codable, Transferable {
    let ids: [UUID]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pasteBuddyMobilePinboardItemIDs)
    }
}

extension UTType {
    static let pasteBuddyMobilePinboardItemIDs = UTType(exportedAs: "app.pastebuddy.mobile-pinboard-item-ids")
}
