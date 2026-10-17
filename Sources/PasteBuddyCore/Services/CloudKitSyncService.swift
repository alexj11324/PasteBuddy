import Foundation

#if canImport(CloudKit)
import CloudKit
#endif

public struct CloudSyncRemoteRecord: Codable, Equatable, Sendable {
    public var recordName: String
    public var packageID: UUID
    public var createdAt: Date
    public var containerIdentifier: String
    public var keyHierarchyVersion: Int
    public var schemaVersion: Int
    public var encryptedSnapshot: EncryptedEnvelope

    public init(
        recordName: String,
        packageID: UUID,
        createdAt: Date,
        containerIdentifier: String,
        keyHierarchyVersion: Int,
        schemaVersion: Int,
        encryptedSnapshot: EncryptedEnvelope
    ) {
        self.recordName = recordName
        self.packageID = packageID
        self.createdAt = createdAt
        self.containerIdentifier = containerIdentifier
        self.keyHierarchyVersion = keyHierarchyVersion
        self.schemaVersion = schemaVersion
        self.encryptedSnapshot = encryptedSnapshot
    }

    public init(package: CloudSyncUploadPackage) {
        self.init(
            recordName: package.id.uuidString,
            packageID: package.id,
            createdAt: package.createdAt,
            containerIdentifier: package.containerIdentifier,
            keyHierarchyVersion: package.keyHierarchyVersion,
            schemaVersion: package.schemaVersion,
            encryptedSnapshot: package.encryptedSnapshot
        )
    }

    public func makePackage() -> CloudSyncUploadPackage {
        CloudSyncUploadPackage(
            id: packageID,
            createdAt: createdAt,
            containerIdentifier: containerIdentifier,
            keyHierarchyVersion: keyHierarchyVersion,
            schemaVersion: schemaVersion,
            encryptedSnapshot: encryptedSnapshot
        )
    }
}

public protocol CloudSyncRemoteRecordTransport: Sendable {
    func save(_ record: CloudSyncRemoteRecord) async throws -> CloudSyncRemoteRecord
    func fetchLatest(limit: Int) async throws -> [CloudSyncRemoteRecord]
}

public struct CloudSyncUploadResult: Equatable, Sendable {
    public var package: CloudSyncUploadPackage
    public var record: CloudSyncRemoteRecord

    public init(package: CloudSyncUploadPackage, record: CloudSyncRemoteRecord) {
        self.package = package
        self.record = record
    }
}

public enum CloudSyncImportStatus: Sendable {
    case imported(CloudSyncDownloadResult)
    case unchanged
    case failed
}

public struct CloudSyncDownloadResult: Equatable, Sendable {
    public var snapshot: PasteBuddySnapshot
    public var report: CloudSyncMergeReport
    public var record: CloudSyncRemoteRecord

    public init(
        snapshot: PasteBuddySnapshot,
        report: CloudSyncMergeReport,
        record: CloudSyncRemoteRecord
    ) {
        self.snapshot = snapshot
        self.report = report
        self.record = record
    }
}

public final class CloudKitSyncService: @unchecked Sendable {
    private let transport: any CloudSyncRemoteRecordTransport
    private let builder: CloudSyncPackageBuilder
    private let importer: CloudSyncPackageImporter

    public init(
        transport: any CloudSyncRemoteRecordTransport,
        builder: CloudSyncPackageBuilder = CloudSyncPackageBuilder(),
        importer: CloudSyncPackageImporter = CloudSyncPackageImporter()
    ) {
        self.transport = transport
        self.builder = builder
        self.importer = importer
    }

    public func upload(
        _ snapshot: PasteBuddySnapshot,
        packageID: UUID = UUID(),
        createdAt: Date = Date()
    ) async throws -> CloudSyncUploadResult {
        let package = try builder.makeUploadPackage(
            from: snapshot,
            packageID: packageID,
            createdAt: createdAt
        )
        let savedRecord = try await transport.save(CloudSyncRemoteRecord(package: package))
        return CloudSyncUploadResult(
            package: savedRecord.makePackage(),
            record: savedRecord
        )
    }

    public func downloadLatest(
        into snapshot: PasteBuddySnapshot,
        importedAt: Date = Date()
    ) async throws -> CloudSyncDownloadResult? {
        guard let latestRecord = try await transport.fetchLatest(limit: 1).first else {
            return nil
        }
        guard latestRecord.packageID != snapshot.sync.lastImportedPackageID else {
            return nil
        }

        let result = try importer.importPackage(
            latestRecord.makePackage(),
            into: snapshot,
            importedAt: importedAt
        )
        return CloudSyncDownloadResult(
            snapshot: result.snapshot,
            report: result.report,
            record: latestRecord
        )
    }
}

#if canImport(CloudKit)
public final class CloudKitRemoteRecordTransport: CloudSyncRemoteRecordTransport, @unchecked Sendable {
    private let database: CKDatabase
    private let factory: CloudKitRecordFactory

    public init(
        containerIdentifier: String,
        databaseScope: CKDatabase.Scope = .private,
        factory: CloudKitRecordFactory = CloudKitRecordFactory()
    ) {
        let container = CKContainer(identifier: containerIdentifier)
        switch databaseScope {
        case .private:
            database = container.privateCloudDatabase
        case .public:
            database = container.publicCloudDatabase
        case .shared:
            database = container.sharedCloudDatabase
        @unknown default:
            database = container.privateCloudDatabase
        }
        self.factory = factory
    }

    public init(
        database: CKDatabase,
        factory: CloudKitRecordFactory = CloudKitRecordFactory()
    ) {
        self.database = database
        self.factory = factory
    }

    public func save(_ record: CloudSyncRemoteRecord) async throws -> CloudSyncRemoteRecord {
        let ckRecord = try factory.makeRecord(from: record)
        let uploadURL = CloudKitRecordFactory.uploadAssetURL(in: ckRecord)
        do {
            _ = try await saveRecord(ckRecord)
            CloudKitRecordFactory.discardUploadAsset(at: uploadURL)
            return record
        } catch {
            CloudKitRecordFactory.discardUploadAsset(at: uploadURL)
            throw error
        }
    }

    public func fetchLatest(limit: Int = 1) async throws -> [CloudSyncRemoteRecord] {
        let query = CKQuery(
            recordType: CloudKitRecordFactory.encryptedSnapshotRecordType,
            predicate: NSPredicate(value: true)
        )
        query.sortDescriptors = CloudKitSnapshotRevision.latestFirstSortDescriptors()
        let records = try await perform(query, limit: limit)
        return try records.map { try factory.makeRemoteRecord(from: $0) }
    }

    private func saveRecord(_ record: CKRecord) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { continuation in
            database.save(record) { savedRecord, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let savedRecord {
                    continuation.resume(returning: savedRecord)
                } else {
                    continuation.resume(throwing: CloudKitRecordFactoryError.invalidField("savedRecord"))
                }
            }
        }
    }

    private func perform(_ query: CKQuery, limit: Int) async throws -> [CKRecord] {
        guard limit > 0 else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            database.fetch(
                withQuery: query,
                inZoneWith: nil,
                desiredKeys: nil,
                resultsLimit: limit
            ) { result in
                switch result {
                case .success(let response):
                    do {
                        let records = try response.matchResults.map { _, recordResult in
                            try recordResult.get()
                        }
                        let sortedRecords = records.sorted { lhs, rhs in
                            CloudKitSnapshotRevision.prefers(
                                CloudKitSnapshotRevision(serverModificationDate: lhs.modificationDate),
                                over: CloudKitSnapshotRevision(serverModificationDate: rhs.modificationDate)
                            )
                        }
                        continuation.resume(returning: sortedRecords)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

}
#endif
