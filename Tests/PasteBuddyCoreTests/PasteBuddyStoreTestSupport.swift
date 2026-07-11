import XCTest
@testable import PasteBuddyCore

#if canImport(CloudKit)
import CloudKit
#endif

@MainActor
final class PasteBuddyStoreTests: XCTestCase {
}
enum StoreFactoryProbeError: LocalizedError {
    case sensitive(String)

    var errorDescription: String? {
        switch self {
        case .sensitive(let value): value
        }
    }
}

final class StoreHarness {
    let directory: URL
    let encryptionService: EncryptionService
    let snapshotStore: EncryptedSnapshotStore

    init() throws {
        directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("PasteBuddyStoreTests-\(UUID().uuidString)", isDirectory: true)
        encryptionService = EncryptionService(
            service: "com.pastebuddy.store-tests",
            account: UUID().uuidString,
            keyID: "test-key",
            keyMaterialStore: FixedEncryptionKeyMaterialStore()
        )
        snapshotStore = EncryptedSnapshotStore(
            fileURL: directory.appendingPathComponent("clipboard.pbenc"),
            encryptionService: encryptionService
        )
    }

    func cleanup() {
        try? encryptionService.deleteKeyForTesting()
        try? FileManager.default.removeItem(at: directory)
    }
}

struct FakeHistoryUnlockAuthenticator: HistoryUnlockAuthenticating {
    var result: Bool

    func authenticate(reason: String) async throws -> Bool {
        result
    }
}

actor InMemoryPinboardShareInvitationTransport: PinboardShareInvitationTransport {
    private var identitiesByFingerprint: [String: PinboardSharePublicIdentity] = [:]
    private var packages: [PinboardShareInvitationPackage] = []

    func publishIdentity(_ identity: PinboardSharePublicIdentity) async throws -> PinboardSharePublicIdentity {
        identitiesByFingerprint[identity.publicKeyFingerprint] = identity
        return identity
    }

    func saveInvitation(_ package: PinboardShareInvitationPackage) async throws -> PinboardShareInvitationPackage {
        packages.removeAll { $0.id == package.id }
        packages.append(package)
        return package
    }

    func fetchInvitations(recipientPublicKeyFingerprint: String) async throws -> [PinboardShareInvitationPackage] {
        packages
            .filter { $0.recipientIdentity.publicKeyFingerprint == recipientPublicKeyFingerprint }
            .sorted { $0.createdAt < $1.createdAt }
    }
}

actor SuspendedCloudSyncRemoteTransport: CloudSyncRemoteRecordTransport {
    private var records: [CloudSyncRemoteRecord] = []
    private var shouldSuspendNextFetch = false
    private var didStartFetch = false
    private var fetchContinuation: CheckedContinuation<Void, Never>?

    func save(_ record: CloudSyncRemoteRecord) async throws -> CloudSyncRemoteRecord {
        records.removeAll { $0.packageID == record.packageID }
        records.append(record)
        return record
    }

    func fetchLatest(limit: Int) async throws -> [CloudSyncRemoteRecord] {
        if shouldSuspendNextFetch {
            shouldSuspendNextFetch = false
            didStartFetch = true
            await withCheckedContinuation { continuation in
                fetchContinuation = continuation
            }
        }
        return Array(records.sorted { $0.createdAt > $1.createdAt }.prefix(max(limit, 0)))
    }

    func suspendNextFetch() {
        shouldSuspendNextFetch = true
        didStartFetch = false
    }

    func fetchHasStarted() -> Bool { didStartFetch }

    func resumeFetch() {
        fetchContinuation?.resume()
        fetchContinuation = nil
    }
}

actor SuspendedStoreLoadGate {
    private var suspended = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        suspended = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasSuspended() -> Bool { suspended }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

actor RepositorySearchSuspensionGate {
    private let suspendOnInvocation: Int
    private var invocationCount = 0
    private var isSuspended = false
    private var suspensionContinuation: CheckedContinuation<Void, Never>?
    private var observerContinuations: [CheckedContinuation<Void, Never>] = []

    init(suspendOnInvocation: Int = 1) {
        self.suspendOnInvocation = suspendOnInvocation
    }

    func suspendIfNeeded() async {
        invocationCount += 1
        guard invocationCount == suspendOnInvocation else { return }
        isSuspended = true
        let observers = observerContinuations
        observerContinuations.removeAll()
        observers.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            suspensionContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            observerContinuations.append(continuation)
        }
    }

    func resume() {
        suspensionContinuation?.resume()
        suspensionContinuation = nil
    }
}

func nonmatchingReplacement(for item: ClipboardItem) -> ClipboardItem {
    ClipboardItem(
        id: item.id,
        sourceAppName: "Notes",
        deviceName: "Test Mac",
        contentType: .text,
        title: "Unrelated replacement",
        payload: ClipboardPayload(text: "current content no longer matches")
    )
}

final class FixedEncryptionKeyMaterialStore: EncryptionKeyMaterialStore, @unchecked Sendable {
    private let keyData: Data

    init(keyData: Data = Data(repeating: 0x5A, count: 32)) {
        self.keyData = keyData
    }

    func loadOrCreateKeyData() throws -> Data { keyData }
    func deleteStoredKeyMaterial() throws {}
}
