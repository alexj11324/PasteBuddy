import Foundation
import PasteBuddyCore

public struct MobileShareActionImportResult: Equatable, Sendable {
    public var importedItems: [ClipboardItem]
    public var targetPinboardID: UUID?
    public var source: SharedContentSource

    public init(
        importedItems: [ClipboardItem],
        targetPinboardID: UUID?,
        source: SharedContentSource
    ) {
        self.importedItems = importedItems
        self.targetPinboardID = targetPinboardID
        self.source = source
    }

    public var statusMessage: String {
        let count = importedItems.count
        return targetPinboardID == nil
            ? PasteBuddyLocalization.format(
                "mobile.share_action.import_result_history",
                defaultValue: "Saved %d item(s) to history.",
                count
            )
            : PasteBuddyLocalization.format(
                "mobile.share_action.import_result_history_and_pinboard",
                defaultValue: "Saved %d item(s) to history and selected pinboard.",
                count
            )
    }
}

public enum MobileShareActionExtensionService {
    @MainActor
    public static func importSupportedContent(
        from providers: [NSItemProvider],
        into store: PasteBuddyStore,
        configuration: MobileItemProviderImportConfiguration = MobileItemProviderImportConfiguration()
    ) async throws -> MobileShareActionImportResult {
        let requestedPinboardID = configuration.preferredPinboardID
            ?? store.snapshot.mobile.preferredSharePinboardID
        let targetPinboardID = requestedPinboardID.flatMap { pinboardID in
            store.snapshot.pinboards.contains(where: { $0.id == pinboardID }) ? pinboardID : nil
        }
        var resolvedConfiguration = configuration
        resolvedConfiguration.preferredPinboardID = targetPinboardID

        let inputs = try await MobileItemProviderAdapter.supportedInputs(
            from: providers,
            configuration: resolvedConfiguration
        )
        let service = SharedContentImportService()
        let importedItems = try inputs.map { input in
            try service.importContent(input, into: store)
        }
        return MobileShareActionImportResult(
            importedItems: importedItems,
            targetPinboardID: targetPinboardID,
            source: configuration.source
        )
    }
}
