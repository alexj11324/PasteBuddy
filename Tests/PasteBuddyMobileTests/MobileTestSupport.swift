import Foundation
@testable import PasteBuddyCore

final class StoreHarness {
    let directory: URL
    let encryptionService: EncryptionService
    let snapshotStore: EncryptedSnapshotStore

    init() throws {
        directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("PasteBuddyMobileTests-\(UUID().uuidString)", isDirectory: true)
        encryptionService = EncryptionService(
            service: "com.pastebuddy.mobile-tests",
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

private final class FixedEncryptionKeyMaterialStore: EncryptionKeyMaterialStore, @unchecked Sendable {
    private let keyData: Data

    init(keyData: Data = Data(repeating: 0x5A, count: 32)) {
        self.keyData = keyData
    }

    func loadOrCreateKeyData() throws -> Data { keyData }
    func deleteStoredKeyMaterial() throws {}
}
