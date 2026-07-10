import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct PinboardItemDragPayload: Codable, Transferable {
    let ids: [UUID]
    private let plainTextProvider: @Sendable () -> String

    var plainText: String {
        plainTextProvider()
    }

    init(
        ids: [UUID],
        plainTextProvider: @escaping @Sendable () -> String = { "" }
    ) {
        self.ids = ids
        self.plainTextProvider = plainTextProvider
    }

    private enum CodingKeys: String, CodingKey {
        case ids
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ids = try container.decode([UUID].self, forKey: .ids)
        plainTextProvider = { "" }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ids, forKey: .ids)
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pasteBuddyPinboardItemIDs)
        ProxyRepresentation(exporting: \.plainText)
    }
}

extension UTType {
    static let pasteBuddyPinboardItemIDs = UTType(exportedAs: "app.pastebuddy.pinboard-item-ids")
}
