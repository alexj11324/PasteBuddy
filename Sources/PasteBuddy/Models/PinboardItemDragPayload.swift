import AppKit
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct PinboardItemDragPayload: Codable, Transferable {
    let ids: [UUID]
    let plainText: String
    private let exportsImage: Bool
    private let imageDataProvider: @MainActor @Sendable () async -> Data?

    init(
        ids: [UUID],
        plainText: String = "",
        exportsImage: Bool = false,
        imageDataProvider: @escaping @MainActor @Sendable () async -> Data? = { nil }
    ) {
        self.ids = ids
        self.plainText = plainText
        self.exportsImage = exportsImage
        self.imageDataProvider = imageDataProvider
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .tiff) { payload in
            guard let data = await payload.imageDataProvider(),
                  let tiffData = NSImage(data: data)?.tiffRepresentation else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return tiffData
        }
        .exportingCondition(\.exportsImage)
        CodableRepresentation(contentType: .pasteBuddyPinboardItemIDs)
        ProxyRepresentation(exporting: \.plainText)
    }

    private enum CodingKeys: String, CodingKey {
        case ids
        case plainText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ids = try container.decode([UUID].self, forKey: .ids)
        plainText = try container.decodeIfPresent(String.self, forKey: .plainText) ?? ""
        exportsImage = false
        imageDataProvider = { nil }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ids, forKey: .ids)
        try container.encode(plainText, forKey: .plainText)
    }
}

extension UTType {
    static let pasteBuddyPinboardItemIDs = UTType(exportedAs: "app.pastebuddy.pinboard-item-ids")
}
