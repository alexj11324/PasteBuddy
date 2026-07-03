import Foundation

public struct CloudSyncUploadPackage: Codable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var containerIdentifier: String
    public var schemaVersion: Int
    public var snapshot: PasteBuddySnapshot

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        containerIdentifier: String,
        schemaVersion: Int,
        snapshot: PasteBuddySnapshot
    ) {
        self.id = id
        self.createdAt = createdAt
        self.containerIdentifier = containerIdentifier
        self.schemaVersion = schemaVersion
        self.snapshot = snapshot
    }
}

public enum CloudSyncPackageError: LocalizedError, Equatable {
    case syncNotReady(String)
    case missingContainerIdentifier

    public var errorDescription: String? {
        switch self {
        case .syncNotReady(let reason):
            "Cloud sync package cannot be created: \(reason)"
        case .missingContainerIdentifier:
            "Cloud sync package requires a CloudKit container identifier."
        }
    }
}

public enum CloudSyncMergeEntity: String, Codable, Equatable, Sendable {
    case item
    case pinboard
}

public enum CloudSyncMergeResolution: String, Codable, Equatable, Sendable {
    case acceptedRemote
    case keptLocal
}

public struct CloudSyncMergeConflict: Codable, Equatable, Sendable {
    public var entity: CloudSyncMergeEntity
    public var id: UUID
    public var localUpdatedAt: Date
    public var remoteUpdatedAt: Date
    public var resolution: CloudSyncMergeResolution

    public init(
        entity: CloudSyncMergeEntity,
        id: UUID,
        localUpdatedAt: Date,
        remoteUpdatedAt: Date,
        resolution: CloudSyncMergeResolution
    ) {
        self.entity = entity
        self.id = id
        self.localUpdatedAt = localUpdatedAt
        self.remoteUpdatedAt = remoteUpdatedAt
        self.resolution = resolution
    }
}

public struct CloudSyncMergeReport: Codable, Equatable, Sendable {
    public var packageID: UUID
    public var importedAt: Date
    public var addedItems: Int
    public var updatedItems: Int
    public var addedPinboards: Int
    public var updatedPinboards: Int
    public var keptLocalItems: Int
    public var keptLocalPinboards: Int
    public var conflicts: [CloudSyncMergeConflict]

    public init(
        packageID: UUID,
        importedAt: Date,
        addedItems: Int = 0,
        updatedItems: Int = 0,
        addedPinboards: Int = 0,
        updatedPinboards: Int = 0,
        keptLocalItems: Int = 0,
        keptLocalPinboards: Int = 0,
        conflicts: [CloudSyncMergeConflict] = []
    ) {
        self.packageID = packageID
        self.importedAt = importedAt
        self.addedItems = addedItems
        self.updatedItems = updatedItems
        self.addedPinboards = addedPinboards
        self.updatedPinboards = updatedPinboards
        self.keptLocalItems = keptLocalItems
        self.keptLocalPinboards = keptLocalPinboards
        self.conflicts = conflicts
    }

    public var summary: String {
        "Imported CloudKit package \(packageID.uuidString): \(addedItems) new items, \(updatedItems) updated items, \(addedPinboards) new pinboards, \(updatedPinboards) updated pinboards, \(conflicts.count) conflicts."
    }
}

public enum CloudSyncImportError: LocalizedError, Equatable {
    case syncNotReady(String)
    case containerMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .syncNotReady(let reason):
            "Cloud sync package cannot be imported: \(reason)"
        case .containerMismatch(let expected, let actual):
            "Cloud sync package belongs to \(actual), but this Mac is configured for \(expected)."
        }
    }
}

public final class CloudSyncPackageBuilder: @unchecked Sendable {
    public init() {}

    public func makeUploadPackage(
        from snapshot: PasteBuddySnapshot,
        packageID: UUID = UUID(),
        createdAt: Date = Date()
    ) throws -> CloudSyncUploadPackage {
        guard snapshot.sync.readiness.canAttemptCloudSync else {
            throw CloudSyncPackageError.syncNotReady(snapshot.sync.readiness.detail)
        }
        guard let containerIdentifier = snapshot.sync.cloudKitContainerIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !containerIdentifier.isEmpty else {
            throw CloudSyncPackageError.missingContainerIdentifier
        }

        return CloudSyncUploadPackage(
            id: packageID,
            createdAt: createdAt,
            containerIdentifier: containerIdentifier,
            schemaVersion: snapshot.schemaVersion,
            snapshot: snapshot
        )
    }
}

public final class CloudSyncPackageImporter: @unchecked Sendable {
    public init() {}

    public func importPackage(
        _ package: CloudSyncUploadPackage,
        into localSnapshot: PasteBuddySnapshot,
        importedAt: Date = Date()
    ) throws -> (snapshot: PasteBuddySnapshot, report: CloudSyncMergeReport) {
        guard localSnapshot.sync.readiness.canAttemptCloudSync else {
            throw CloudSyncImportError.syncNotReady(localSnapshot.sync.readiness.detail)
        }
        let expectedContainer = localSnapshot.sync.cloudKitContainerIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard expectedContainer == package.containerIdentifier else {
            throw CloudSyncImportError.containerMismatch(
                expected: expectedContainer,
                actual: package.containerIdentifier
            )
        }

        let remoteSnapshot = package.snapshot
        var merged = localSnapshot
        var report = CloudSyncMergeReport(packageID: package.id, importedAt: importedAt)

        mergeItems(from: remoteSnapshot.items, into: &merged, report: &report)
        mergePinboards(from: remoteSnapshot.pinboards, into: &merged, report: &report)

        merged.sync.lastSyncAt = importedAt
        merged.sync.lastImportedPackageID = package.id
        merged.sync.lastSyncConflictCount = report.conflicts.count
        merged.sync.lastSyncStatusMessage = report.summary

        return (merged, report)
    }

    private func mergeItems(
        from remoteItems: [ClipboardItem],
        into snapshot: inout PasteBuddySnapshot,
        report: inout CloudSyncMergeReport
    ) {
        for remoteItem in remoteItems {
            guard let localIndex = snapshot.items.firstIndex(where: { $0.id == remoteItem.id }) else {
                snapshot.items.append(remoteItem)
                report.addedItems += 1
                continue
            }

            let localItem = snapshot.items[localIndex]
            guard localItem != remoteItem else { continue }

            if remoteItem.updatedAt > localItem.updatedAt {
                snapshot.items[localIndex] = remoteItem
                report.updatedItems += 1
                report.conflicts.append(CloudSyncMergeConflict(
                    entity: .item,
                    id: remoteItem.id,
                    localUpdatedAt: localItem.updatedAt,
                    remoteUpdatedAt: remoteItem.updatedAt,
                    resolution: .acceptedRemote
                ))
            } else {
                report.keptLocalItems += 1
                report.conflicts.append(CloudSyncMergeConflict(
                    entity: .item,
                    id: remoteItem.id,
                    localUpdatedAt: localItem.updatedAt,
                    remoteUpdatedAt: remoteItem.updatedAt,
                    resolution: .keptLocal
                ))
            }
        }
        snapshot.items.sort { $0.createdAt > $1.createdAt }
    }

    private func mergePinboards(
        from remotePinboards: [Pinboard],
        into snapshot: inout PasteBuddySnapshot,
        report: inout CloudSyncMergeReport
    ) {
        for remotePinboard in remotePinboards {
            guard let localIndex = snapshot.pinboards.firstIndex(where: { $0.id == remotePinboard.id }) else {
                snapshot.pinboards.append(remotePinboard)
                report.addedPinboards += 1
                continue
            }

            let localPinboard = snapshot.pinboards[localIndex]
            guard localPinboard != remotePinboard else { continue }

            if remotePinboard.updatedAt > localPinboard.updatedAt {
                snapshot.pinboards[localIndex] = remotePinboard
                report.updatedPinboards += 1
                report.conflicts.append(CloudSyncMergeConflict(
                    entity: .pinboard,
                    id: remotePinboard.id,
                    localUpdatedAt: localPinboard.updatedAt,
                    remoteUpdatedAt: remotePinboard.updatedAt,
                    resolution: .acceptedRemote
                ))
            } else {
                report.keptLocalPinboards += 1
                report.conflicts.append(CloudSyncMergeConflict(
                    entity: .pinboard,
                    id: remotePinboard.id,
                    localUpdatedAt: localPinboard.updatedAt,
                    remoteUpdatedAt: remotePinboard.updatedAt,
                    resolution: .keptLocal
                ))
            }
        }
    }
}
