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
            ? historyStatusMessage(count: count)
            : pinboardStatusMessage(count: count)
    }

    private func historyStatusMessage(count: Int) -> String {
        PasteBuddyLocalization.format(
            count == 1 ? "mobile.share_action.import_result_history_one" : "mobile.share_action.import_result_history",
            defaultValue: count == 1 ? "Saved %d item to history." : "Saved %d items to history.",
            count
        )
    }

    private func pinboardStatusMessage(count: Int) -> String {
        PasteBuddyLocalization.format(
            count == 1 ? "mobile.share_action.import_result_history_and_pinboard_one" : "mobile.share_action.import_result_history_and_pinboard",
            defaultValue: count == 1 ? "Saved %d item to history and selected pinboard." : "Saved %d items to history and selected pinboard.",
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
        try Task.checkCancellation()
        let service = SharedContentImportService()
        let importedItems = try await service.importContentsAsync(inputs, into: store)
        try Task.checkCancellation()
        try await store.flushPendingSaveOrThrow()
        try Task.checkCancellation()
        return MobileShareActionImportResult(
            importedItems: importedItems,
            targetPinboardID: targetPinboardID,
            source: configuration.source
        )
    }
}
