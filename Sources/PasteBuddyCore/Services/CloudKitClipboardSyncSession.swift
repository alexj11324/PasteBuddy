import Foundation

/// Polls the existing encrypted CloudKit snapshot path. macOS, iOS, and the
/// extensions that already participate in clipboard sync share this session.
@MainActor
public final class CloudKitClipboardSyncRuntime {
    public static let defaultPollInterval: Duration = .seconds(60)

    private let service: CloudKitSyncService
    private let pollInterval: Duration
    private var task: Task<Void, Never>?

    public init(
        service: CloudKitSyncService,
        pollInterval: Duration = CloudKitClipboardSyncRuntime.defaultPollInterval
    ) {
        self.service = service
        self.pollInterval = pollInterval
    }

    public var isRunning: Bool {
        task != nil
    }

    public func update(store: PasteBuddyStore, isEnabled: Bool) {
        guard isEnabled else {
            stop()
            return
        }
        guard task == nil,
              store.snapshot.sync.readiness.canAttemptCloudSync,
              store.snapshot.sync.cloudKitContainerIdentifier != nil else {
            return
        }

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var lastUploadedDataRevision: Int?
            while !Task.isCancelled {
                let shouldContinue = await self.syncOnce(
                    store: store,
                    lastUploadedDataRevision: &lastUploadedDataRevision
                )
                guard shouldContinue, !Task.isCancelled else { return }
                do {
                    try await Task.sleep(for: self.pollInterval)
                } catch {
                    return
                }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Imports the latest private snapshot, then uploads when local data changed.
    /// A failed import keeps the loop alive so the next pass can retry.
    @discardableResult
    public func syncOnce(
        store: PasteBuddyStore,
        lastUploadedDataRevision: inout Int?
    ) async -> Bool {
        let imported = await store.importLatestCloudSyncSnapshot(using: service)
        guard !Task.isCancelled else { return false }
        guard imported != nil || store.lastErrorMessage == nil else {
            return true
        }
        if lastUploadedDataRevision != store.dataRevision,
           await store.uploadCloudSyncSnapshot(using: service) != nil {
            lastUploadedDataRevision = store.dataRevision
        }
        return !Task.isCancelled
    }
}

@MainActor
public final class CloudKitClipboardSyncSession {
    public static let containerIdentifier = "iCloud.com.alexjiang.PasteBuddy"
    public static let capabilityInfoDictionaryKey = "PasteBuddyCloudKitCapabilityConfigured"

    private var runtime: CloudKitClipboardSyncRuntime?
    private var activeContainerIdentifier: String?
    private let makeRuntime: @MainActor (String) -> CloudKitClipboardSyncRuntime

    public init(makeRuntime: @escaping @MainActor (String) -> CloudKitClipboardSyncRuntime) {
        self.makeRuntime = makeRuntime
    }

    #if canImport(CloudKit)
    public convenience init() {
        self.init { containerIdentifier in
            CloudKitClipboardSyncRuntime(
                service: CloudKitSyncService(
                    transport: CloudKitRemoteRecordTransport(containerIdentifier: containerIdentifier)
                )
            )
        }
    }
    #endif

    public static var isCapabilityConfigured: Bool {
        Bundle.main.object(forInfoDictionaryKey: capabilityInfoDictionaryKey) as? Bool == true
    }

    public static func setEnabled(_ isEnabled: Bool, on store: PasteBuddyStore) {
        if isEnabled {
            let existing = store.snapshot.sync.cloudKitContainerIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedContainer = (existing?.isEmpty == false ? existing : nil) ?? Self.containerIdentifier
            store.configureCloudKitSync(
                containerIdentifier: resolvedContainer,
                capabilityConfigured: isCapabilityConfigured
            )
        } else {
            store.disableCloudSync()
        }
    }

    public func update(store: PasteBuddyStore, allowsNetwork: Bool = true) {
        guard allowsNetwork, let containerIdentifier = readyContainerIdentifier(in: store) else {
            runtime?.stop()
            runtime = nil
            activeContainerIdentifier = nil
            return
        }
        if runtime == nil || activeContainerIdentifier != containerIdentifier {
            runtime?.stop()
            runtime = makeRuntime(containerIdentifier)
            activeContainerIdentifier = containerIdentifier
        }
        runtime?.update(store: store, isEnabled: true)
    }

    @discardableResult
    public func syncNow(store: PasteBuddyStore, allowsNetwork: Bool = true) async -> Bool {
        guard allowsNetwork, let containerIdentifier = readyContainerIdentifier(in: store) else {
            return false
        }
        if runtime == nil || activeContainerIdentifier != containerIdentifier {
            runtime?.stop()
            runtime = makeRuntime(containerIdentifier)
            activeContainerIdentifier = containerIdentifier
        }
        guard let runtime else { return false }
        var lastUploadedDataRevision: Int?
        return await runtime.syncOnce(
            store: store,
            lastUploadedDataRevision: &lastUploadedDataRevision
        )
    }

    public func stop() {
        runtime?.stop()
        runtime = nil
        activeContainerIdentifier = nil
    }

    private func readyContainerIdentifier(in store: PasteBuddyStore) -> String? {
        guard store.snapshot.sync.isCloudSyncEnabled,
              store.snapshot.sync.readiness.canAttemptCloudSync,
              let containerIdentifier = store.snapshot.sync.cloudKitContainerIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !containerIdentifier.isEmpty else {
            return nil
        }
        return containerIdentifier
    }
}
