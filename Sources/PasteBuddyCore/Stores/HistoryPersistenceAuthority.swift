import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum HistoryPersistenceAuthority: String, Codable, Sendable {
    case sqlite
    case encryptedSnapshot
}

struct HistoryPersistenceAuthorityRecord: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case stable
        case preparing
        case targetValidated
        case sourceRevoked
    }

    var phase: Phase
    var authority: HistoryPersistenceAuthority
    var epoch: UUID
}

final class HistoryPersistenceAuthorityStore: @unchecked Sendable {
    let fileURL: URL

    init(snapshotURL: URL) {
        fileURL = URL(fileURLWithPath: snapshotURL.path + ".authority")
    }

    func load() throws -> HistoryPersistenceAuthorityRecord? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            return try JSONDecoder.pasteBuddy.decode(
                HistoryPersistenceAuthorityRecord.self,
                from: Data(contentsOf: fileURL)
            )
        } catch {
            throw PasteBuddyPersistenceError.historyUnavailable
        }
    }

    func commitStable(_ authority: HistoryPersistenceAuthority) throws {
        let record = HistoryPersistenceAuthorityRecord(
            phase: .stable,
            authority: authority,
            epoch: UUID()
        )
        let data = try JSONEncoder.pasteBuddy.encode(record)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: temporaryURL)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            #if canImport(Darwin)
            guard Darwin.rename(temporaryURL.path, fileURL.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let directoryDescriptor = Darwin.open(directory.path, O_RDONLY)
            guard directoryDescriptor >= 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            defer { Darwin.close(directoryDescriptor) }
            guard Darwin.fsync(directoryDescriptor) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            #else
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
            }
            #endif
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
