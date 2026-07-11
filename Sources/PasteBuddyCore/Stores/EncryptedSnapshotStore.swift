import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum SnapshotStoreError: LocalizedError {
    case missingApplicationSupportDirectory
    case missingAppGroupContainer(String)
    case unreadableStore(Error)
    case legacyMigrationFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .missingApplicationSupportDirectory:
            "Could not locate the user Application Support directory."
        case .missingAppGroupContainer(let groupIdentifier):
            "Could not locate the app group container for \(groupIdentifier). Check the App Group entitlement."
        case .unreadableStore(let error):
            "Could not read the PasteBuddy store: \(error.localizedDescription)"
        case .legacyMigrationFailed(let error):
            "Could not migrate the legacy PasteBuddy store into current storage: \(error.localizedDescription)"
        }
    }
}

public final class EncryptedSnapshotStore: @unchecked Sendable {
    public let fileURL: URL
    public var storageMode: SnapshotStorageMode {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return storedStorageMode
        }
        set {
            stateLock.lock()
            storedStorageMode = newValue
            stateLock.unlock()
        }
    }
    public var lastLoadedStorageMode: SnapshotStorageMode? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedLastLoadedStorageMode
    }
    private let encryptionService: EncryptionService
    private let stateLock = NSLock()
    private var storedStorageMode: SnapshotStorageMode
    private var storedLastLoadedStorageMode: SnapshotStorageMode?
    private let baselineLock = NSLock()
    private var baselineRevision: UUID?
    private var hasLoadedBaseline = false

    private static let persistenceHeaderPrefix = Data("PBST2:".utf8)
    private static let persistenceHeaderLength = 43

    public init(
        fileURL: URL,
        encryptionService: EncryptionService = EncryptionService(),
        storageMode: SnapshotStorageMode = .encrypted
    ) {
        self.fileURL = fileURL
        self.encryptionService = encryptionService
        self.storedStorageMode = storageMode
        self.storedLastLoadedStorageMode = nil
    }

    public static func defaultStore(storageMode: SnapshotStorageMode = .standard) throws -> EncryptedSnapshotStore {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw SnapshotStoreError.missingApplicationSupportDirectory
        }
        let directory = base.appendingPathComponent("PasteBuddy", isDirectory: true)
        return defaultStore(in: directory, storageMode: storageMode)
    }

    public static func defaultStore(
        in directory: URL,
        storageMode: SnapshotStorageMode = .standard
    ) -> EncryptedSnapshotStore {
        EncryptedSnapshotStore(
            fileURL: directory.appendingPathComponent("clipboard.pbstore"),
            storageMode: storageMode
        )
    }

    public static func secureEnclaveProtectedDefaultStore() throws -> EncryptedSnapshotStore {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw SnapshotStoreError.missingApplicationSupportDirectory
        }
        let directory = base.appendingPathComponent("PasteBuddy", isDirectory: true)
        let fileURL = directory.appendingPathComponent("clipboard.pbenc")
        return EncryptedSnapshotStore(
            fileURL: fileURL,
            encryptionService: .secureEnclaveProtected(),
            storageMode: .encrypted
        )
    }

    public static func appGroupStore(
        groupIdentifier: String,
        filename: String = "clipboard.pbenc",
        keychainAccessGroup: String? = nil
    ) throws -> EncryptedSnapshotStore {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) else {
            throw SnapshotStoreError.missingAppGroupContainer(groupIdentifier)
        }
        let directory = containerURL.appendingPathComponent("PasteBuddy", isDirectory: true)
        return EncryptedSnapshotStore(
            fileURL: directory.appendingPathComponent(filename),
            encryptionService: EncryptionService(accessGroup: keychainAccessGroup),
            storageMode: .encrypted
        )
    }

    public func load() throws -> PasteBuddySnapshot {
        let configuredStorageMode = storageMode
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            updateBaseline(revision: nil)
            updateLastLoadedStorageMode(configuredStorageMode)
            var snapshot = PasteBuddySnapshot()
            snapshot.security.storageMode = configuredStorageMode
            return snapshot
        }
        let data: Data
        let loadedRevision: UUID?
        do {
            let persistedData = try Data(contentsOf: fileURL)
            let parsed = try Self.parsePersistedData(persistedData)
            loadedRevision = parsed.revision
            data = parsed.payload
        } catch {
            throw SnapshotStoreError.unreadableStore(error)
        }

        let envelope: EncryptedEnvelope
        do {
            envelope = try JSONDecoder.pasteBuddy.decode(EncryptedEnvelope.self, from: data)
        } catch {
            if let legacySnapshot = try? JSONDecoder.pasteBuddy.decode(PasteBuddySnapshot.self, from: data) {
                updateLastLoadedStorageMode(.standard)
                var snapshot = legacySnapshot
                snapshot.security.storageMode = .standard
                if configuredStorageMode == .encrypted {
                    do {
                        updateBaseline(revision: loadedRevision)
                        try save(snapshot)
                        updateLastLoadedStorageMode(.encrypted)
                    } catch {
                        throw SnapshotStoreError.legacyMigrationFailed(error)
                    }
                } else {
                    updateBaseline(revision: loadedRevision)
                }
                return snapshot
            }
            throw SnapshotStoreError.unreadableStore(error)
        }

        do {
            var snapshot = try encryptionService.decrypt(PasteBuddySnapshot.self, from: envelope)
            updateBaseline(revision: loadedRevision)
            updateLastLoadedStorageMode(.encrypted)
            snapshot.security.storageMode = .encrypted
            return snapshot
        } catch {
            throw SnapshotStoreError.unreadableStore(error)
        }
    }

    public func save(_ snapshot: PasteBuddySnapshot) throws {
        let persistedStorageMode = storageMode
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let itemCount = PasteBuddyPerformanceSignposts.ItemCountBucket(
            itemCount: snapshot.items.count
        )
        let encodeInterval = PasteBuddyPerformanceSignposts.begin(
            .snapshotEncode,
            itemCount: itemCount
        )
        let payload: Data
        do {
            if persistedStorageMode == .encrypted {
                var encryptedSnapshot = snapshot
                encryptedSnapshot.security.storageMode = .encrypted
                let envelope = try encryptionService.encrypt(encryptedSnapshot)
                payload = try JSONEncoder.pasteBuddy.encode(envelope)
            } else {
                var standardSnapshot = snapshot
                standardSnapshot.security.storageMode = .standard
                payload = try JSONEncoder.pasteBuddy.encode(standardSnapshot)
            }
            PasteBuddyPerformanceSignposts.end(
                encodeInterval,
                itemCount: itemCount,
                result: .succeeded
            )
        } catch {
            PasteBuddyPerformanceSignposts.end(
                encodeInterval,
                itemCount: itemCount,
                result: .failed
            )
            throw error
        }

        let persistenceInterval = PasteBuddyPerformanceSignposts.begin(
            .snapshotFsyncRename,
            itemCount: itemCount
        )
        let newRevision = UUID()
        do {
            let temporaryURL = try writeTemporaryPersistedFile(payload: payload, revision: newRevision)
            do {
                try withExclusivePersistenceLock {
                    let baseline = currentBaseline()
                    if baseline.hasLoadedBaseline {
                        guard try readCurrentPersistenceRevision() == baseline.revision else {
                            throw PasteBuddyPersistenceError.historyUnavailable
                        }
                    } else if FileManager.default.fileExists(atPath: fileURL.path) {
                        throw PasteBuddyPersistenceError.historyUnavailable
                    }
                    try replacePersistedFileAtomically(with: temporaryURL)
                    updateBaseline(revision: newRevision)
                }
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw error
            }
            updateLastLoadedStorageMode(persistedStorageMode)
            PasteBuddyPerformanceSignposts.end(
                persistenceInterval,
                itemCount: itemCount,
                result: .succeeded
            )
        } catch {
            PasteBuddyPerformanceSignposts.end(
                persistenceInterval,
                itemCount: itemCount,
                result: .failed
            )
            throw error
        }
    }

    func installRevokedTombstone() throws {
        let newRevision = UUID()
        let payload = Data("PBST-REVOKED:1\n".utf8)
        let temporaryURL = try writeTemporaryPersistedFile(payload: payload, revision: newRevision)
        do {
            try withExclusivePersistenceLock {
                let baseline = currentBaseline()
                if baseline.hasLoadedBaseline {
                    guard try readCurrentPersistenceRevision() == baseline.revision else {
                        throw PasteBuddyPersistenceError.historyUnavailable
                    }
                }
                try replacePersistedFileAtomically(with: temporaryURL)
                updateBaseline(revision: newRevision)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func currentBaseline() -> (hasLoadedBaseline: Bool, revision: UUID?) {
        baselineLock.lock()
        defer { baselineLock.unlock() }
        return (hasLoadedBaseline, baselineRevision)
    }

    private func updateBaseline(revision: UUID?) {
        baselineLock.lock()
        hasLoadedBaseline = true
        baselineRevision = revision
        baselineLock.unlock()
    }

    private func updateLastLoadedStorageMode(_ storageMode: SnapshotStorageMode) {
        stateLock.lock()
        storedLastLoadedStorageMode = storageMode
        stateLock.unlock()
    }

    private static func persistenceHeader(revision: UUID) -> Data {
        Data("PBST2:\(revision.uuidString)\n".utf8)
    }

    private static func persistenceRevision(from data: Data) throws -> UUID? {
        guard data.starts(with: persistenceHeaderPrefix) else {
            return nil
        }
        guard data.count >= persistenceHeaderLength,
              let header = String(
                data: data.prefix(persistenceHeaderLength),
                encoding: .utf8
              ),
              header.hasPrefix("PBST2:"),
              header.hasSuffix("\n"),
              let revision = UUID(uuidString: String(header.dropFirst(6).dropLast())) else {
            throw PasteBuddyPersistenceError.historyUnavailable
        }
        return revision
    }

    private static func parsePersistedData(_ data: Data) throws -> (revision: UUID?, payload: Data) {
        guard let revision = try persistenceRevision(from: data) else {
            return (nil, data)
        }
        return (revision, data.dropFirst(persistenceHeaderLength))
    }

    static func persistedPayloadForTesting(_ data: Data) throws -> Data {
        try parsePersistedData(data).payload
    }

    private func readCurrentPersistenceRevision() throws -> UUID? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: Self.persistenceHeaderLength) ?? Data()
        return try Self.persistenceRevision(from: header)
    }

    private func writeTemporaryPersistedFile(payload: Data, revision: UUID) throws -> URL {
        let directory = fileURL.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: attributes
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: temporaryURL.path
        )
        let handle = try FileHandle(forWritingTo: temporaryURL)
        do {
            try handle.write(contentsOf: Self.persistenceHeader(revision: revision))
            try handle.write(contentsOf: payload)
            try handle.synchronize()
            try handle.close()
            return temporaryURL
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func replacePersistedFileAtomically(with temporaryURL: URL) throws {
        #if canImport(Darwin)
        guard Darwin.rename(temporaryURL.path, fileURL.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        #else
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
        }
        #endif
    }

    private func withExclusivePersistenceLock<T>(_ body: () throws -> T) throws -> T {
        #if canImport(Darwin)
        let lockURL = URL(fileURLWithPath: fileURL.path + ".lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { Darwin.close(descriptor) }
        var didAcquireLock = false
        for attempt in 0..<50 {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                didAcquireLock = true
                break
            }
            guard errno == EWOULDBLOCK else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            if attempt < 49 {
                usleep(2_000)
            }
        }
        guard didAcquireLock else {
            throw PasteBuddyPersistenceError.historyUnavailable
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
        #else
        return try body()
        #endif
    }

    public func rotateEncryption(to newEncryptionService: EncryptionService) throws {
        let snapshot = try load()
        let rotatedStore = EncryptedSnapshotStore(
            fileURL: fileURL,
            encryptionService: newEncryptionService
        )
        rotatedStore.adoptBaseline(currentBaseline())
        try rotatedStore.save(snapshot)
    }

    private func adoptBaseline(_ baseline: (hasLoadedBaseline: Bool, revision: UUID?)) {
        baselineLock.lock()
        hasLoadedBaseline = baseline.hasLoadedBaseline
        baselineRevision = baseline.revision
        baselineLock.unlock()
    }
}
