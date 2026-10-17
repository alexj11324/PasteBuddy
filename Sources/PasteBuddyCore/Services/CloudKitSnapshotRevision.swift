import Foundation

/// Orders encrypted clipboard snapshots by CloudKit's server modification time.
/// A client `createdAt` is not a revision: a clock set ahead would permanently
/// outrank every later snapshot.
public struct CloudKitSnapshotRevision: Equatable, Sendable {
    /// CKQuery accepts the special key `modificationDate`. That is CloudKit's
    /// server modification time, not the raw system field `___modTime`.
    public static let serverModificationSortKey = "modificationDate"

    public var serverModificationDate: Date?

    public init(serverModificationDate: Date?) {
        self.serverModificationDate = serverModificationDate
    }

    public static func latestFirstSortDescriptors() -> [NSSortDescriptor] {
        [NSSortDescriptor(key: serverModificationSortKey, ascending: false)]
    }

    /// A record with a server modification date outranks one without one.
    /// Equal server dates and two missing dates do not invent an order from the client clock.
    public static func prefers(
        _ lhs: CloudKitSnapshotRevision,
        over rhs: CloudKitSnapshotRevision
    ) -> Bool {
        switch (lhs.serverModificationDate, rhs.serverModificationDate) {
        case let (left?, right?):
            return left > right
        case (.some, .none):
            return true
        case (.none, .some), (.none, .none):
            return false
        }
    }
}
