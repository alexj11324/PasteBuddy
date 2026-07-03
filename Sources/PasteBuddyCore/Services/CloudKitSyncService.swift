import Foundation

#if canImport(CloudKit)
import CloudKit
#endif

public struct CloudSyncRemoteRecord: Codable, Equatable, Sendable {
    public var recordName: String
    public var packageID: UUID
    public var createdAt: Date
    public var containerIdentifier: String
    public var schemaVersion: Int
    public var snapshot: PasteBuddySnapshot

    public init(
        recordName: String,
        packageID: UUID,
        createdAt: Date,
        containerIdentifier: String,
        schemaVersion: Int,
        snapshot: PasteBuddySnapshot
    ) {
        self.recordName = recordName
        self.packageID = packageID
        self.createdAt = createdAt
        self.containerIdentifier = containerIdentifier
        self.schemaVersion = schemaVersion
        self.snapshot = snapshot
    }

    public init(package: CloudSyncUploadPackage) {
        self.init(
            recordName: package.id.uuidString,
            packageID: package.id,
            createdAt: package.createdAt,
            containerIdentifier: package.containerIdentifier,
            schemaVersion: package.schemaVersion,
            snapshot: package.snapshot
        )
    }

    public func makePackage() -> CloudSyncUploadPackage {
        CloudSyncUploadPackage(
            id: packageID,
            createdAt: createdAt,
            containerIdentifier: containerIdentifier,
            schemaVersion: schemaVersion,
            snapshot: snapshot
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
        let savedRecord = try await saveRecord(factory.makeRecord(from: record))
        return try factory.makeRemoteRecord(from: savedRecord)
    }

    public func fetchLatest(limit: Int = 1) async throws -> [CloudSyncRemoteRecord] {
        let query = CKQuery(
            recordType: CloudKitRecordFactory.snapshotRecordType,
            predicate: NSPredicate(value: true)
        )
        query.sortDescriptors = [
            NSSortDescriptor(key: CloudKitRecordFactory.createdAtField, ascending: false)
        ]
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
                        let sortedRecords = records.sorted {
                            Self.createdAt(from: $0) > Self.createdAt(from: $1)
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

    private static func createdAt(from record: CKRecord) -> Date {
        if let date = record[CloudKitRecordFactory.createdAtField] as? Date {
            return date
        }
        if let date = record[CloudKitRecordFactory.createdAtField] as? NSDate {
            return date as Date
        }
        return .distantPast
    }
}
#endif
