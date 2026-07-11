import Foundation
import OSLog

/// Local Instruments metadata is limited to the fixed operation, item-count
/// bucket, and result enums below. Never add arbitrary detail/string overloads
/// or clipboard/OCR text, URLs, filenames/paths, queries, IDs, endpoint/peer
/// IDs, error descriptions, asset identifiers, or encryption keys.
public enum PasteBuddyPerformanceSignposts {
    public enum Operation: Sendable {
        case appLaunchToStoreReady
        case pasteboardRead
        case captureApply
        case pageAndCountQuery
        case repositoryCommit
        case snapshotEncode
        case snapshotFsyncRename
        case shelfShowToFirstPage
        case ocrEnrichment
        case linkEnrichment
        case irohIdentityLoad
        case irohEndpointBind
    }

    public enum ItemCountBucket: Int, Equatable, Sendable {
        case unknown = 0
        case none = 1
        case single = 2
        case small = 3
        case medium = 4
        case large = 5
        case veryLarge = 6
        case oversized = 7

        public init(itemCount: Int?) {
            guard let itemCount, itemCount >= 0 else {
                self = .unknown
                return
            }
            self = switch itemCount {
            case 0: .none
            case 1: .single
            case 2...100: .small
            case 101...1_000: .medium
            case 1_001...5_000: .large
            case 5_001...10_000: .veryLarge
            default: .oversized
            }
        }
    }

    public enum ResultCode: Int, Sendable {
        case succeeded = 0
        case noChange = 1
        case cancelled = 2
        case failed = 3
        case blocked = 4
    }

    public final class Interval: @unchecked Sendable {
        fileprivate let operation: Operation
        private let lock = NSLock()
        private var state: OSSignpostIntervalState?

        fileprivate init(operation: Operation, state: OSSignpostIntervalState) {
            self.operation = operation
            self.state = state
        }

        // OSSignpostIntervalState is single-consume. Shared Interval references
        // all pass through this gate, so cancellation and completion can race safely.
        fileprivate func consumeState() -> OSSignpostIntervalState? {
            lock.lock()
            defer { lock.unlock() }
            defer { state = nil }
            return state
        }
    }

    private static let signposter = OSSignposter(
        subsystem: "com.alexjiang.PasteBuddy",
        category: .pointsOfInterest
    )

    public static func begin(
        _ operation: Operation,
        itemCount: ItemCountBucket = .unknown
    ) -> Interval? {
        guard signposter.isEnabled else { return nil }
        let id = signposter.makeSignpostID()
        let state: OSSignpostIntervalState = switch operation {
        case .appLaunchToStoreReady:
            signposter.beginInterval("AppLaunchToStoreReady", id: id, "items=\(itemCount.rawValue, privacy: .public)")
        case .pasteboardRead:
            signposter.beginInterval("PasteboardRead", id: id, "items=\(itemCount.rawValue, privacy: .public)")
        case .captureApply:
            signposter.beginInterval("CaptureApply", id: id, "items=\(itemCount.rawValue, privacy: .public)")
        case .pageAndCountQuery:
            signposter.beginInterval("PageAndCountQuery", id: id, "items=\(itemCount.rawValue, privacy: .public)")
        case .repositoryCommit:
            signposter.beginInterval("RepositoryCommit", id: id, "items=\(itemCount.rawValue, privacy: .public)")
        case .snapshotEncode:
            signposter.beginInterval("SnapshotEncode", id: id, "items=\(itemCount.rawValue, privacy: .public)")
        case .snapshotFsyncRename:
            signposter.beginInterval("SnapshotFsyncRename", id: id, "items=\(itemCount.rawValue, privacy: .public)")
        case .shelfShowToFirstPage:
            signposter.beginInterval("ShelfShowToFirstPage", id: id, "items=\(itemCount.rawValue, privacy: .public)")
        case .ocrEnrichment:
            signposter.beginInterval("OCREnrichment", id: id, "items=\(itemCount.rawValue, privacy: .public)")
        case .linkEnrichment:
            signposter.beginInterval("LinkEnrichment", id: id, "items=\(itemCount.rawValue, privacy: .public)")
        case .irohIdentityLoad:
            signposter.beginInterval("IrohIdentityLoad", id: id, "items=\(itemCount.rawValue, privacy: .public)")
        case .irohEndpointBind:
            signposter.beginInterval("IrohEndpointBind", id: id, "items=\(itemCount.rawValue, privacy: .public)")
        }
        return Interval(operation: operation, state: state)
    }

    public static func end(
        _ interval: Interval?,
        itemCount: ItemCountBucket = .unknown,
        result: ResultCode
    ) {
        guard let interval, let state = interval.consumeState() else { return }
        switch interval.operation {
        case .appLaunchToStoreReady:
            signposter.endInterval("AppLaunchToStoreReady", state, "items=\(itemCount.rawValue, privacy: .public) result=\(result.rawValue, privacy: .public)")
        case .pasteboardRead:
            signposter.endInterval("PasteboardRead", state, "items=\(itemCount.rawValue, privacy: .public) result=\(result.rawValue, privacy: .public)")
        case .captureApply:
            signposter.endInterval("CaptureApply", state, "items=\(itemCount.rawValue, privacy: .public) result=\(result.rawValue, privacy: .public)")
        case .pageAndCountQuery:
            signposter.endInterval("PageAndCountQuery", state, "items=\(itemCount.rawValue, privacy: .public) result=\(result.rawValue, privacy: .public)")
        case .repositoryCommit:
            signposter.endInterval("RepositoryCommit", state, "items=\(itemCount.rawValue, privacy: .public) result=\(result.rawValue, privacy: .public)")
        case .snapshotEncode:
            signposter.endInterval("SnapshotEncode", state, "items=\(itemCount.rawValue, privacy: .public) result=\(result.rawValue, privacy: .public)")
        case .snapshotFsyncRename:
            signposter.endInterval("SnapshotFsyncRename", state, "items=\(itemCount.rawValue, privacy: .public) result=\(result.rawValue, privacy: .public)")
        case .shelfShowToFirstPage:
            signposter.endInterval("ShelfShowToFirstPage", state, "items=\(itemCount.rawValue, privacy: .public) result=\(result.rawValue, privacy: .public)")
        case .ocrEnrichment:
            signposter.endInterval("OCREnrichment", state, "items=\(itemCount.rawValue, privacy: .public) result=\(result.rawValue, privacy: .public)")
        case .linkEnrichment:
            signposter.endInterval("LinkEnrichment", state, "items=\(itemCount.rawValue, privacy: .public) result=\(result.rawValue, privacy: .public)")
        case .irohIdentityLoad:
            signposter.endInterval("IrohIdentityLoad", state, "items=\(itemCount.rawValue, privacy: .public) result=\(result.rawValue, privacy: .public)")
        case .irohEndpointBind:
            signposter.endInterval("IrohEndpointBind", state, "items=\(itemCount.rawValue, privacy: .public) result=\(result.rawValue, privacy: .public)")
        }
    }
}
