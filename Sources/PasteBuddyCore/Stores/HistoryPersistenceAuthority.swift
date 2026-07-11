import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum HistoryPersistenceAuthority: String, Codable, Sendable {
    case sqlite
    case standardSnapshot
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
    var source: HistoryPersistenceAuthority?
    var target: HistoryPersistenceAuthority?
    var sourceRevision: UUID?
    var targetRevision: UUID?
    var epoch: UUID

    init(
        phase: Phase,
        authority: HistoryPersistenceAuthority,
        source: HistoryPersistenceAuthority? = nil,
        target: HistoryPersistenceAuthority? = nil,
        sourceRevision: UUID? = nil,
        targetRevision: UUID? = nil,
        epoch: UUID
    ) {
        self.phase = phase
        self.authority = authority
        self.source = source
        self.target = target
        self.sourceRevision = sourceRevision
        self.targetRevision = targetRevision
        self.epoch = epoch
    }
}

enum HistoryPersistenceLeaseMode: Sendable {
    case shared
    case exclusive
}

final class HistoryPersistenceLease: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func release() {
        lock.withLock {
            guard let descriptor else { return }
            #if canImport(Darwin)
            flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            #endif
            self.descriptor = nil
        }
    }

    deinit { release() }
}

final class HistoryPersistenceAuthorityStore: @unchecked Sendable {
    let fileURL: URL
    private let lockURL: URL

    init(snapshotURL: URL) {
        fileURL = URL(fileURLWithPath: snapshotURL.path + ".authority")
        lockURL = URL(fileURLWithPath: snapshotURL.path + ".authority.lock")
    }

    func acquireLease(
        _ mode: HistoryPersistenceLeaseMode,
        wait: Bool = true
    ) throws -> HistoryPersistenceLease? {
        #if canImport(Darwin)
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let operation = (mode == .shared ? LOCK_SH : LOCK_EX) | (wait ? 0 : LOCK_NB)
        guard flock(descriptor, operation) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if !wait, code == EWOULDBLOCK { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return HistoryPersistenceLease(descriptor: descriptor)
        #else
        return HistoryPersistenceLease(descriptor: -1)
        #endif
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
        try write(HistoryPersistenceAuthorityRecord(
            phase: .stable,
            authority: authority,
            epoch: UUID()
        ))
    }

    func beginCutover(
        source: HistoryPersistenceAuthority,
        target: HistoryPersistenceAuthority,
        sourceRevision: UUID
    ) throws -> UUID {
        guard source != target else { throw PasteBuddyPersistenceError.historyUnavailable }
        let epoch = UUID()
        try write(HistoryPersistenceAuthorityRecord(
            phase: .preparing,
            authority: source,
            source: source,
            target: target,
            sourceRevision: sourceRevision,
            epoch: epoch
        ))
        return epoch
    }

    func recordTargetValidated(epoch: UUID, targetRevision: UUID) throws {
        var record = try requiredRecord(phase: .preparing, epoch: epoch)
        record.phase = .targetValidated
        record.targetRevision = targetRevision
        try write(record)
    }

    func recordSourceRevoked(epoch: UUID) throws {
        var record = try requiredRecord(phase: .targetValidated, epoch: epoch)
        guard record.targetRevision != nil else {
            throw PasteBuddyPersistenceError.historyUnavailable
        }
        record.phase = .sourceRevoked
        try write(record)
    }

    func commitStable(epoch: UUID) throws {
        let record = try requiredRecord(phase: .sourceRevoked, epoch: epoch)
        guard let target = record.target, let targetRevision = record.targetRevision else {
            throw PasteBuddyPersistenceError.historyUnavailable
        }
        try write(HistoryPersistenceAuthorityRecord(
            phase: .stable,
            authority: target,
            targetRevision: targetRevision,
            epoch: epoch
        ))
    }

    private func requiredRecord(
        phase: HistoryPersistenceAuthorityRecord.Phase,
        epoch: UUID
    ) throws -> HistoryPersistenceAuthorityRecord {
        guard let record = try load(), record.phase == phase, record.epoch == epoch else {
            throw PasteBuddyPersistenceError.historyUnavailable
        }
        return record
    }

    private func write(_ record: HistoryPersistenceAuthorityRecord) throws {
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
