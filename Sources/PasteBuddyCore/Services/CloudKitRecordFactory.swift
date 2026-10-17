#if canImport(CloudKit)
import CloudKit
import Foundation

public enum CloudKitRecordFactoryError: LocalizedError {
    case envelopeEncodingFailed(Error)
    case envelopeDecodingFailed(Error)
    case invalidField(String)
    case missingField(String)
    case wrongRecordType(String)

    public var errorDescription: String? {
        switch self {
        case .envelopeEncodingFailed(let error):
            "CloudKit record could not encode encrypted payload: \(error.localizedDescription)"
        case .envelopeDecodingFailed(let error):
            "CloudKit record could not decode encrypted payload: \(error.localizedDescription)"
        case .invalidField(let field):
            "CloudKit record contains an invalid \(field) field."
        case .missingField(let field):
            "CloudKit record is missing the \(field) field."
        case .wrongRecordType(let recordType):
            "CloudKit record type \(recordType) is not a PasteBuddy encrypted snapshot."
        }
    }
}

public struct CloudKitRecordFactory: Sendable {
    public static let encryptedSnapshotRecordType = "PasteBuddyEncryptedSnapshot"
    public static let packageIDField = "packageID"
    public static let createdAtField = "createdAt"
    public static let containerIdentifierField = "containerIdentifier"
    public static let schemaVersionField = "schemaVersion"
    public static let keyHierarchyVersionField = "keyHierarchyVersion"
    public static let envelopeVersionField = "envelopeVersion"
    public static let envelopeAlgorithmField = "envelopeAlgorithm"
    public static let keyIDField = "keyID"
    /// Legacy inline bytes. CloudKit cannot change this field to an asset once
    /// a record has used it, and non-asset fields are limited to 1 MB.
    public static let encryptedSnapshotField = "encryptedSnapshot"
    public static let encryptedSnapshotAssetField = "encryptedSnapshotAsset"

    public init() {}

    public func makeRecord(from package: CloudSyncUploadPackage) throws -> CKRecord {
        try makeRecord(from: CloudSyncRemoteRecord(package: package))
    }

    public func makeRecord(from remoteRecord: CloudSyncRemoteRecord) throws -> CKRecord {
        let recordID = CKRecord.ID(recordName: remoteRecord.recordName)
        let record = CKRecord(
            recordType: Self.encryptedSnapshotRecordType,
            recordID: recordID
        )
        record[Self.packageIDField] = remoteRecord.packageID.uuidString as NSString
        record[Self.createdAtField] = remoteRecord.createdAt as NSDate
        record[Self.containerIdentifierField] = remoteRecord.containerIdentifier as NSString
        record[Self.schemaVersionField] = NSNumber(value: remoteRecord.schemaVersion)
        record[Self.keyHierarchyVersionField] = NSNumber(value: remoteRecord.keyHierarchyVersion)
        record[Self.envelopeVersionField] = NSNumber(value: remoteRecord.encryptedSnapshot.version)
        record[Self.envelopeAlgorithmField] = remoteRecord.encryptedSnapshot.algorithm as NSString
        record[Self.keyIDField] = remoteRecord.encryptedSnapshot.keyID as NSString
        let envelopeData: Data
        do {
            envelopeData = try JSONEncoder.pasteBuddy.encode(remoteRecord.encryptedSnapshot)
        } catch {
            throw CloudKitRecordFactoryError.envelopeEncodingFailed(error)
        }
        let assetURL: URL
        do {
            assetURL = try Self.writeUploadAsset(envelopeData)
        } catch {
            throw CloudKitRecordFactoryError.envelopeEncodingFailed(error)
        }
        record[Self.encryptedSnapshotAssetField] = CKAsset(fileURL: assetURL)
        return record
    }

    public static func uploadAssetURL(in record: CKRecord) -> URL? {
        (record[encryptedSnapshotAssetField] as? CKAsset)?.fileURL
    }

    /// Deletes only files this factory wrote for an upload. CloudKit's downloaded
    /// asset cache lives outside that directory and must stay in place.
    public static func discardUploadAsset(at fileURL: URL?) {
        guard let fileURL, isManagedUploadAsset(fileURL) else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    public func makeRemoteRecord(from record: CKRecord) throws -> CloudSyncRemoteRecord {
        guard record.recordType == Self.encryptedSnapshotRecordType else {
            throw CloudKitRecordFactoryError.wrongRecordType(record.recordType)
        }

        let packageIDString = try stringField(Self.packageIDField, in: record)
        guard let packageID = UUID(uuidString: packageIDString) else {
            throw CloudKitRecordFactoryError.invalidField(Self.packageIDField)
        }
        let encryptedSnapshotData = try encryptedSnapshotData(in: record)
        let encryptedSnapshot: EncryptedEnvelope
        do {
            encryptedSnapshot = try JSONDecoder.pasteBuddy.decode(
                EncryptedEnvelope.self,
                from: encryptedSnapshotData
            )
        } catch {
            throw CloudKitRecordFactoryError.envelopeDecodingFailed(error)
        }

        return CloudSyncRemoteRecord(
            recordName: record.recordID.recordName,
            packageID: packageID,
            createdAt: try dateField(Self.createdAtField, in: record),
            containerIdentifier: try stringField(Self.containerIdentifierField, in: record),
            keyHierarchyVersion: try intField(Self.keyHierarchyVersionField, in: record),
            schemaVersion: try intField(Self.schemaVersionField, in: record),
            encryptedSnapshot: encryptedSnapshot
        )
    }

    private func stringField(_ field: String, in record: CKRecord) throws -> String {
        guard let value = record[field] else {
            throw CloudKitRecordFactoryError.missingField(field)
        }
        if let string = value as? String {
            return string
        }
        if let string = value as? NSString {
            return string as String
        }
        throw CloudKitRecordFactoryError.invalidField(field)
    }

    private func intField(_ field: String, in record: CKRecord) throws -> Int {
        guard let value = record[field] else {
            throw CloudKitRecordFactoryError.missingField(field)
        }
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        throw CloudKitRecordFactoryError.invalidField(field)
    }

    private func dateField(_ field: String, in record: CKRecord) throws -> Date {
        guard let value = record[field] else {
            throw CloudKitRecordFactoryError.missingField(field)
        }
        if let date = value as? Date {
            return date
        }
        if let date = value as? NSDate {
            return date as Date
        }
        throw CloudKitRecordFactoryError.invalidField(field)
    }

    private func encryptedSnapshotData(in record: CKRecord) throws -> Data {
        if let asset = record[Self.encryptedSnapshotAssetField] as? CKAsset {
            guard let fileURL = asset.fileURL else {
                throw CloudKitRecordFactoryError.missingField(Self.encryptedSnapshotAssetField)
            }
            do {
                return try Data(contentsOf: fileURL)
            } catch {
                throw CloudKitRecordFactoryError.envelopeDecodingFailed(error)
            }
        }

        guard let value = record[Self.encryptedSnapshotField] else {
            throw CloudKitRecordFactoryError.missingField(Self.encryptedSnapshotAssetField)
        }
        if let data = value as? Data {
            return data
        }
        if let data = value as? NSData {
            return data as Data
        }
        throw CloudKitRecordFactoryError.invalidField(Self.encryptedSnapshotField)
    }

    private static func writeUploadAsset(_ data: Data) throws -> URL {
        let directory = uploadAssetDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("snapshot-\(UUID().uuidString).ckasset")
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private static func uploadAssetDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PasteBuddyCloudKitUploads", isDirectory: true)
    }

    private static func isManagedUploadAsset(_ fileURL: URL) -> Bool {
        let managedRoot = uploadAssetDirectory().standardizedFileURL.resolvingSymlinksInPath()
        let candidate = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        return candidate.path.hasPrefix(managedRoot.path + "/")
    }
}
#endif
