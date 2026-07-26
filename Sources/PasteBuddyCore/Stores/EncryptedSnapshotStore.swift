import Foundation

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
    public var storageMode: SnapshotStorageMode
    public private(set) var lastLoadedStorageMode: SnapshotStorageMode?
    private let encryptionService: EncryptionService

    public init(
        fileURL: URL,
        encryptionService: EncryptionService = EncryptionService(),
        storageMode: SnapshotStorageMode = .encrypted
    ) {
        self.fileURL = fileURL
        self.encryptionService = encryptionService
        self.storageMode = storageMode
    }

    public static func defaultStore(storageMode: SnapshotStorageMode = .standard) throws -> EncryptedSnapshotStore {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw SnapshotStoreError.missingApplicationSupportDirectory
        }
        let directory = base.appendingPathComponent(
            persistenceDirectoryName(bundleIdentifier: Bundle.main.bundleIdentifier),
            isDirectory: true
        )
        return defaultStore(in: directory, storageMode: storageMode)
    }

    static func persistenceDirectoryName(bundleIdentifier: String?) -> String {
        bundleIdentifier == "com.alexjiang.PasteBuddy.dev" ? "PasteBuddy Dev" : "PasteBuddy"
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
        filename: String = "clipboard.pbenc"
    ) throws -> EncryptedSnapshotStore {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) else {
            throw SnapshotStoreError.missingAppGroupContainer(groupIdentifier)
        }
        let directory = containerURL.appendingPathComponent("PasteBuddy", isDirectory: true)
        return EncryptedSnapshotStore(
            fileURL: directory.appendingPathComponent(filename),
            storageMode: .encrypted
        )
    }

    public func load() throws -> PasteBuddySnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            lastLoadedStorageMode = storageMode
            var snapshot = PasteBuddySnapshot()
            snapshot.security.storageMode = storageMode
            return snapshot
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw SnapshotStoreError.unreadableStore(error)
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            if attributes[.protectionKey] as? FileProtectionType == .complete {
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: fileURL.path
                )
            }
        } catch {
            NSLog("PasteBuddy loaded its store but could not update file protection: %@", error.localizedDescription)
        }

        let envelope: EncryptedEnvelope
        do {
            envelope = try JSONDecoder.pasteBuddy.decode(EncryptedEnvelope.self, from: data)
        } catch {
            if let legacySnapshot = try? JSONDecoder.pasteBuddy.decode(PasteBuddySnapshot.self, from: data) {
                lastLoadedStorageMode = .standard
                var snapshot = legacySnapshot
                snapshot.security.storageMode = .standard
                if storageMode == .encrypted {
                    do {
                        try save(snapshot)
                        lastLoadedStorageMode = .encrypted
                    } catch {
                        throw SnapshotStoreError.legacyMigrationFailed(error)
                    }
                }
                return snapshot
            }
            throw SnapshotStoreError.unreadableStore(error)
        }

        do {
            var snapshot = try encryptionService.decrypt(PasteBuddySnapshot.self, from: envelope)
            lastLoadedStorageMode = .encrypted
            snapshot.security.storageMode = .encrypted
            return snapshot
        } catch {
            throw SnapshotStoreError.unreadableStore(error)
        }
    }

    public func save(_ snapshot: PasteBuddySnapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data: Data
        if storageMode == .encrypted {
            var encryptedSnapshot = snapshot
            encryptedSnapshot.security.storageMode = .encrypted
            let envelope = try encryptionService.encrypt(encryptedSnapshot)
            data = try JSONEncoder.pasteBuddy.encode(envelope)
        } else {
            var standardSnapshot = snapshot
            standardSnapshot.security.storageMode = .standard
            data = try JSONEncoder.pasteBuddy.encode(standardSnapshot)
        }
        do {
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // Some macOS locations reject file-protection writes. Encrypted mode remains AES-GCM protected.
            try data.write(to: fileURL, options: [.atomic])
        }
        lastLoadedStorageMode = storageMode
    }

    public func rotateEncryption(to newEncryptionService: EncryptionService) throws {
        let snapshot = try load()
        let rotatedStore = EncryptedSnapshotStore(
            fileURL: fileURL,
            encryptionService: newEncryptionService
        )
        try rotatedStore.save(snapshot)
    }
}
