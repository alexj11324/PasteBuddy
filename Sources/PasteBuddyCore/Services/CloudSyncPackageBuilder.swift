import Foundation

public protocol EnvelopeEncrypting: Sendable {
    var keyID: String { get }

    func encrypt<T: Encodable>(_ value: T) throws -> EncryptedEnvelope
}

public protocol EnvelopeDecrypting: Sendable {
    func decrypt<T: Decodable>(_ type: T.Type, from envelope: EncryptedEnvelope) throws -> T
}

extension EncryptionService: EnvelopeEncrypting {}
extension EncryptionService: EnvelopeDecrypting {}

public struct CloudSyncUploadPackage: Codable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var containerIdentifier: String
    public var keyHierarchyVersion: Int
    public var schemaVersion: Int
    public var encryptedSnapshot: EncryptedEnvelope

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        containerIdentifier: String,
        keyHierarchyVersion: Int,
        schemaVersion: Int,
        encryptedSnapshot: EncryptedEnvelope
    ) {
        self.id = id
        self.createdAt = createdAt
        self.containerIdentifier = containerIdentifier
        self.keyHierarchyVersion = keyHierarchyVersion
        self.schemaVersion = schemaVersion
        self.encryptedSnapshot = encryptedSnapshot
    }
}

public enum CloudSyncPackageError: LocalizedError, Equatable {
    case syncNotReady(String)
    case missingContainerIdentifier
    case missingKeyHierarchy

    public var errorDescription: String? {
        switch self {
        case .syncNotReady(let reason):
            "Cloud sync package cannot be created: \(reason)"
        case .missingContainerIdentifier:
            "Cloud sync package requires a CloudKit container identifier."
        case .missingKeyHierarchy:
            "Cloud sync package requires an end-to-end key hierarchy version."
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
        "Imported encrypted package \(packageID.uuidString): \(addedItems) new items, \(updatedItems) updated items, \(addedPinboards) new pinboards, \(updatedPinboards) updated pinboards, \(conflicts.count) conflicts."
    }
}

public enum CloudSyncImportError: LocalizedError, Equatable {
    case syncNotReady(String)
    case containerMismatch(expected: String, actual: String)
    case keyHierarchyMismatch(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .syncNotReady(let reason):
            "Cloud sync package cannot be imported: \(reason)"
        case .containerMismatch(let expected, let actual):
            "Cloud sync package belongs to \(actual), but this Mac is configured for \(expected)."
        case .keyHierarchyMismatch(let expected, let actual):
            "Cloud sync package uses key hierarchy \(actual), but this Mac requires \(expected)."
        }
    }
}

public final class CloudSyncPackageBuilder: @unchecked Sendable {
    private let encryptor: any EnvelopeEncrypting

    public init(encryptor: any EnvelopeEncrypting = EncryptionService.cloudSync()) {
        self.encryptor = encryptor
    }

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
        guard let keyHierarchyVersion = snapshot.sync.keyHierarchyVersion, keyHierarchyVersion > 0 else {
            throw CloudSyncPackageError.missingKeyHierarchy
        }

        let encryptedSnapshot = try encryptor.encrypt(snapshot)
        return CloudSyncUploadPackage(
            id: packageID,
            createdAt: createdAt,
            containerIdentifier: containerIdentifier,
            keyHierarchyVersion: keyHierarchyVersion,
            schemaVersion: snapshot.schemaVersion,
            encryptedSnapshot: encryptedSnapshot
        )
    }
}

public final class CloudSyncPackageImporter: @unchecked Sendable {
    private let decryptor: any EnvelopeDecrypting

    public init(decryptor: any EnvelopeDecrypting = EncryptionService.cloudSync()) {
        self.decryptor = decryptor
    }

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
        let expectedKeyHierarchy = localSnapshot.sync.keyHierarchyVersion ?? 0
        guard expectedKeyHierarchy == package.keyHierarchyVersion else {
            throw CloudSyncImportError.keyHierarchyMismatch(
                expected: expectedKeyHierarchy,
                actual: package.keyHierarchyVersion
            )
        }

        let remoteSnapshot = try decryptor.decrypt(PasteBuddySnapshot.self, from: package.encryptedSnapshot)
        var merged = localSnapshot
        var report = CloudSyncMergeReport(packageID: package.id, importedAt: importedAt)

        let itemIDRemaps = mergeItems(from: remoteSnapshot.items, into: &merged, report: &report)
        mergePinboards(from: remoteSnapshot.pinboards, into: &merged, itemIDRemaps: itemIDRemaps, report: &report)

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
    ) -> [UUID: UUID] {
        var itemIDRemaps: [UUID: UUID] = [:]
        var dedupeIndex: [CloudSyncItemDedupeKey: UUID] = [:]
        for item in snapshot.items {
            dedupeIndex[Self.deduplicationKey(for: item)] = item.id
        }

        for originalRemoteItem in remoteItems {
            var remoteItem = originalRemoteItem
            remoteItem.refreshSearchDocument()
            guard let localIndex = snapshot.items.firstIndex(where: { $0.id == remoteItem.id }) else {
                let remoteDedupeKey = Self.deduplicationKey(for: remoteItem)
                if let localID = dedupeIndex[remoteDedupeKey],
                   let duplicateIndex = snapshot.items.firstIndex(where: { $0.id == localID }) {
                    itemIDRemaps[remoteItem.id] = localID
                    let localItem = snapshot.items[duplicateIndex]
                    if remoteItem.updatedAt > localItem.updatedAt {
                        remoteItem.id = localID
                        snapshot.items[duplicateIndex] = remoteItem
                        report.updatedItems += 1
                        report.conflicts.append(CloudSyncMergeConflict(
                            entity: .item,
                            id: localID,
                            localUpdatedAt: localItem.updatedAt,
                            remoteUpdatedAt: remoteItem.updatedAt,
                            resolution: .acceptedRemote
                        ))
                    } else {
                        report.keptLocalItems += 1
                        report.conflicts.append(CloudSyncMergeConflict(
                            entity: .item,
                            id: localID,
                            localUpdatedAt: localItem.updatedAt,
                            remoteUpdatedAt: remoteItem.updatedAt,
                            resolution: .keptLocal
                        ))
                    }
                    continue
                }
                snapshot.items.append(remoteItem)
                dedupeIndex[remoteDedupeKey] = remoteItem.id
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
            dedupeIndex[Self.deduplicationKey(for: snapshot.items[localIndex])] = snapshot.items[localIndex].id
        }
        snapshot.items.sort { $0.createdAt > $1.createdAt }
        return itemIDRemaps
    }

    private func mergePinboards(
        from remotePinboards: [Pinboard],
        into snapshot: inout PasteBuddySnapshot,
        itemIDRemaps: [UUID: UUID],
        report: inout CloudSyncMergeReport
    ) {
        for originalRemotePinboard in remotePinboards {
            let remotePinboard = Self.remappedPinboard(originalRemotePinboard, itemIDRemaps: itemIDRemaps)
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

    private static func deduplicationKey(for item: ClipboardItem) -> CloudSyncItemDedupeKey {
        var item = item
        item.refreshSearchDocument()
        return CloudSyncItemDedupeKey(contentType: item.contentType, hash: item.searchDocument.dedupeHash)
    }

    private static func remappedPinboard(_ pinboard: Pinboard, itemIDRemaps: [UUID: UUID]) -> Pinboard {
        guard !itemIDRemaps.isEmpty else { return pinboard }
        var pinboard = pinboard
        var seen: Set<UUID> = []
        pinboard.itemIDs = pinboard.itemIDs.compactMap { itemID in
            let remappedID = itemIDRemaps[itemID] ?? itemID
            return seen.insert(remappedID).inserted ? remappedID : nil
        }
        return pinboard
    }
}

private struct CloudSyncItemDedupeKey: Hashable {
    var contentType: ClipboardContentType
    var hash: String
}
