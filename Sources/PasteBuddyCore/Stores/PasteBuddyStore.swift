import CryptoKit
import Foundation
import Observation
import OSLog
#if canImport(Darwin)
import Darwin
#endif

public enum PasteBuddyPersistenceError: LocalizedError, Equatable {
    case historyUnavailable

    public var errorDescription: String? {
        PasteBuddyLocalization.string(
            "message.history_unavailable",
            defaultValue: "PasteBuddy history is unavailable because it could not be loaded or saved safely."
        )
    }
}

public struct PasteBuddyPersistenceLoadDiagnostic: Equatable, Sendable {
    public enum Stage: String, CaseIterable, Equatable, Sendable {
        case snapshotLoad
        case repositoryInitialization
        case repositoryMetadata
        case repositoryExport
        case loadApply
        case storageMigration
        case repositoryImport
    }

    public enum Reason: String, CaseIterable, Equatable, Sendable {
        case permissionDenied
        case snapshotUnreadable
        case snapshotMigration
        case database
        case staleWriter
        case cancelled
        case unknown
    }

    public let stage: Stage
    public let reason: Reason

    public init(stage: Stage, reason: Reason) {
        self.stage = stage
        self.reason = reason
    }

    static func reason(for error: Error, at stage: Stage) -> Reason {
        if error is CancellationError {
            return .cancelled
        }
        if isPermissionDenied(error) {
            return .permissionDenied
        }
        if let snapshotError = error as? SnapshotStoreError {
            switch snapshotError {
            case .unreadableStore(let underlyingError):
                return isPermissionDenied(underlyingError) ? .permissionDenied : .snapshotUnreadable
            case .legacyMigrationFailed(let underlyingError):
                return isPermissionDenied(underlyingError) ? .permissionDenied : .snapshotMigration
            case .missingApplicationSupportDirectory, .missingAppGroupContainer:
                return .unknown
            }
        }
        if let persistenceError = error as? PasteBuddyPersistenceError,
           persistenceError == .historyUnavailable {
            return .staleWriter
        }
        if error is PasteBuddyDatabaseError
            || error is PasteBuddySnapshotDatabaseMigrationError {
            return .database
        }
        switch stage {
        case .repositoryInitialization, .repositoryMetadata, .repositoryExport, .repositoryImport:
            return .database
        case .snapshotLoad, .loadApply, .storageMigration:
            return .unknown
        }
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        guard let cocoaError = error as? CocoaError else { return false }
        return cocoaError.code == .fileReadNoPermission
            || cocoaError.code == .fileWriteNoPermission
    }
}

public struct PasteBuddyFilteredItemsPage: Equatable, Sendable {
    public var items: [ClipboardItem]
    public var totalCount: Int

    public init(items: [ClipboardItem], totalCount: Int) {
        self.items = items
        self.totalCount = totalCount
    }
}

@MainActor
@Observable
public final class PasteBuddyStore {
    public var snapshot: PasteBuddySnapshot {
        didSet { bumpDataRevision() }
    }
    public var selectedScope: PasteScope {
        didSet { bumpQueryRevision() }
    }
    public var selectedItemID: UUID?
    public var selectedItemIDs: Set<UUID>
    public var searchQuery: String {
        didSet { bumpQueryRevision() }
    }
    public var lastErrorMessage: String?
    public private(set) var lastPersistenceLoadDiagnostic: PasteBuddyPersistenceLoadDiagnostic?
    public private(set) var isPersistenceWriteBlocked: Bool
    public var isPasteStackActive: Bool {
        didSet { bumpQueryRevision() }
    }
    public var pasteStackItems: [ClipboardItem] {
        didSet {
            pasteStackContentRevision &+= 1
            bumpQueryRevision()
        }
    }
    public var pasteStackDirection: PasteStackDirection {
        didSet { bumpQueryRevision() }
    }
    public var contentTypeFilter: ClipboardContentType? {
        didSet { bumpQueryRevision() }
    }
    public var sourceAppFilter: String? {
        didSet { bumpQueryRevision() }
    }
    public var deviceFilter: String? {
        didSet { bumpQueryRevision() }
    }
    public var dateFilter: ClipboardDateFilter {
        didSet { bumpQueryRevision() }
    }
    public var lastDeletedItem: DeletedClipboardItem?
    public var lastDeletedItems: [DeletedClipboardItem]
    public var lastDirectPasteResult: DirectPasteResult?
    public var requestedSettingsDestination: MacSettingsDestination?
    public var historyUnlockedAt: Date? {
        didSet { bumpQueryRevision() }
    }
    public private(set) var presentationRevision: Int
    public private(set) var dataRevision: Int
    public private(set) var queryRevision: Int
    public private(set) var repositorySyncedDataRevision: Int?

    private var diskStore: EncryptedSnapshotStore
    private let historyUnlockAuthenticator: any HistoryUnlockAuthenticating
    @ObservationIgnored private let persistenceActor: SnapshotPersistenceActor
    @ObservationIgnored private let persistenceCommitGate: PersistenceCommitGate
    @ObservationIgnored private let authorityStore: HistoryPersistenceAuthorityStore
    @ObservationIgnored private var clipboardRepository: ClipboardItemRepository?
    @ObservationIgnored private var repositorySyncActor: ClipboardRepositorySyncActor?
    @ObservationIgnored private var deferredRepositoryDatabaseURL: URL?
    @ObservationIgnored private var repositoryDatabaseURLForStandardStorage: URL?
    @ObservationIgnored private var deferredRepositoryInitializationTask: Task<(ClipboardItemRepository, Bool), Error>?
    @ObservationIgnored internal private(set) var lastDeferredRepositoryInitializationWasOnMainThreadForTesting: Bool?
    @ObservationIgnored var beforeApplyingAsyncLoadForTesting: (@MainActor @Sendable () async -> Void)?
    @ObservationIgnored var beforeCommittingHistoryStorageMigrationForTesting: (@MainActor @Sendable () async -> Void)?
    @ObservationIgnored var beforePersistingFlushSnapshotForTesting: (@MainActor @Sendable () async -> Void)?
    @ObservationIgnored var beforePersistingStandardMigrationSnapshotForTesting: (@MainActor @Sendable () async -> Void)?
    @ObservationIgnored private var presentationCache = PasteBuddyPresentationCache()
    @ObservationIgnored internal private(set) var itemByIDIndexBuildCountForTesting = 0
    @ObservationIgnored internal private(set) var dedupeIndexBuildCountForTesting = 0
    @ObservationIgnored internal private(set) var lastInMemoryPageQueryRanOnMainThreadForTesting: Bool?
    @ObservationIgnored private var captureHistoryState: PasteBuddyCaptureHistoryState?
    @ObservationIgnored private var pasteStackContentRevision: Int
    @ObservationIgnored internal private(set) var captureHotPathItemInspectionCountForTesting = 0
    @ObservationIgnored private var pendingSaveTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSaveTaskID: UUID?
    @ObservationIgnored private var persistenceGeneration: UInt64 = 0
    @ObservationIgnored private var isHistoryStorageMigrationInProgress = false
    @ObservationIgnored private let saveDebounceNanoseconds: UInt64?
    @ObservationIgnored private var dedupeIndex: [PasteBuddyDedupeKey: UUID] = [:]
    @ObservationIgnored private var dedupeIndexRevision: Int?
    @ObservationIgnored private var linkPreviewMetadataRequests: Set<UUID> = []
    @ObservationIgnored private var pendingRepositoryCaptureJournal = ClipboardRepositoryCaptureJournal()
    @ObservationIgnored private var pendingRepositoryJournalRevision: Int?
    @ObservationIgnored private var pendingRepositoryRequiresFullSync = false
    /// Fired after link-preview enrichment persists richer metadata, so hosts
    /// can forward the upgraded item to peers that cannot fetch it themselves.
    @ObservationIgnored public var onLinkPreviewMetadataEnriched: (@MainActor (ClipboardItem) -> Void)?

    private static let defaultHistoryPageLimit = 100
    static let defaultSaveDebounceNanoseconds: UInt64 = 350_000_000
    private static let maximumPersistenceStabilityAttempts = 8
    private static let persistenceLogger = Logger(
        subsystem: "com.alexjiang.PasteBuddy",
        category: "Persistence"
    )

    public nonisolated static var defaultDeviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "This Mac"
        #else
        "This Device"
        #endif
    }

    private func bumpPresentationRevision() {
        presentationRevision &+= 1
    }

    private func bumpDataRevision() {
        dataRevision &+= 1
        bumpPresentationRevision()
    }

    private func bumpQueryRevision() {
        queryRevision &+= 1
        bumpPresentationRevision()
    }

    private func nextPersistenceGeneration() -> UInt64 {
        persistenceGeneration &+= 1
        return persistenceGeneration
    }

    public init(
        diskStore: EncryptedSnapshotStore,
        clipboardRepository: ClipboardItemRepository? = nil,
        deferredRepositoryDatabaseURL: URL? = nil,
        saveDebounceNanoseconds: UInt64? = nil,
        historyUnlockAuthenticator: any HistoryUnlockAuthenticating = SystemHistoryUnlockAuthenticator()
    ) {
        let resolvedClipboardRepository = clipboardRepository
        let resolvedDeferredRepositoryDatabaseURL = clipboardRepository == nil
            ? deferredRepositoryDatabaseURL
            : nil
        var initialSnapshot = PasteBuddySnapshot()
        initialSnapshot.security.storageMode = diskStore.storageMode
        self.diskStore = diskStore
        self.historyUnlockAuthenticator = historyUnlockAuthenticator
        self.persistenceActor = SnapshotPersistenceActor(diskStore: diskStore)
        self.persistenceCommitGate = PersistenceCommitGate()
        self.authorityStore = HistoryPersistenceAuthorityStore(snapshotURL: diskStore.fileURL)
        self.clipboardRepository = resolvedClipboardRepository
        self.repositorySyncActor = resolvedClipboardRepository.map(ClipboardRepositorySyncActor.init(repository:))
        self.deferredRepositoryDatabaseURL = resolvedDeferredRepositoryDatabaseURL
        self.repositoryDatabaseURLForStandardStorage = resolvedClipboardRepository?.fileURL ?? resolvedDeferredRepositoryDatabaseURL
        self.deferredRepositoryInitializationTask = nil
        self.lastDeferredRepositoryInitializationWasOnMainThreadForTesting = nil
        self.saveDebounceNanoseconds = saveDebounceNanoseconds
        self.snapshot = initialSnapshot
        self.selectedScope = .history
        self.selectedItemID = nil
        self.selectedItemIDs = []
        self.searchQuery = ""
        self.lastPersistenceLoadDiagnostic = nil
        self.isPersistenceWriteBlocked = false
        self.isPasteStackActive = false
        self.pasteStackItems = []
        self.pasteStackContentRevision = 0
        self.pasteStackDirection = .topToBottom
        self.contentTypeFilter = nil
        self.sourceAppFilter = nil
        self.deviceFilter = nil
        self.dateFilter = .any
        self.lastDeletedItem = nil
        self.lastDeletedItems = []
        self.lastDirectPasteResult = nil
        self.requestedSettingsDestination = nil
        self.historyUnlockedAt = nil
        self.presentationRevision = 0
        self.dataRevision = 0
        self.queryRevision = 0
        self.repositorySyncedDataRevision = nil
        self.pendingRepositoryJournalRevision = nil
    }

    public func load() {
        do {
            if let authority = try authorityStore.load() {
                guard authority.phase == .stable else {
                    throw PasteBuddyPersistenceError.historyUnavailable
                }
                if authority.authority == .sqlite {
                    guard let clipboardRepository,
                          try clipboardRepository.hasStoredSnapshot() else {
                        throw PasteBuddyPersistenceError.historyUnavailable
                    }
                    snapshot = try clipboardRepository.exportSnapshot(hydrateAssets: false)
                    snapshot.security.storageMode = .standard
                    diskStore.storageMode = .standard
                    historyUnlockedAt = snapshot.security.requiresBiometricUnlock ? nil : Date()
                    refreshDerivedDocumentsIfNeeded()
                    rebuildDedupeIndex()
                    rebuildCaptureHistoryState()
                    repositorySyncedDataRevision = dataRevision
                    clearPendingRepositoryPlan()
                    presentationCache = PasteBuddyPresentationCache()
                    isPersistenceWriteBlocked = false
                    lastErrorMessage = nil
                    selectedItemID = filteredItems.first?.id
                    selectedItemIDs = selectedItemID.map { [$0] } ?? []
                    return
                }
            }
            let diskSnapshot = try diskStore.load()
            let diskStorageMode = diskStore.lastLoadedStorageMode ?? diskSnapshot.security.storageMode
            // Once an encrypted snapshot exists it is the committed source of
            // truth. SQLite can survive a crash between the encrypted write and
            // plaintext cleanup, and must never roll that snapshot back.
            let loadedFromRepository: Bool
            if diskStorageMode == .encrypted {
                loadedFromRepository = false
            } else {
                loadedFromRepository = try clipboardRepository?.hasStoredSnapshot() == true
            }
            var loadedSnapshot: PasteBuddySnapshot
            if loadedFromRepository, let clipboardRepository {
                loadedSnapshot = try clipboardRepository.exportSnapshot(hydrateAssets: false)
            } else {
                loadedSnapshot = diskSnapshot
            }
            let resolvedStorageMode: SnapshotStorageMode = (
                diskStorageMode == .encrypted || loadedSnapshot.security.storageMode == .encrypted
            ) ? .encrypted : .standard
            if resolvedStorageMode == .encrypted {
                if loadedFromRepository, let clipboardRepository {
                    loadedSnapshot = try clipboardRepository.exportSnapshot()
                }
                loadedSnapshot.security.storageMode = .encrypted
                diskStore.storageMode = .encrypted
                try diskStore.save(loadedSnapshot)
                try removePlaintextRepositoryForEncryptedStorage()
            }
            snapshot = loadedSnapshot
            snapshot.security.storageMode = resolvedStorageMode
            diskStore.storageMode = resolvedStorageMode
            if snapshot.security.requiresBiometricUnlock {
                lockHistory()
            } else {
                historyUnlockedAt = Date()
            }
            refreshDerivedDocumentsIfNeeded()
            rebuildDedupeIndex()
            rebuildCaptureHistoryState()
            if resolvedStorageMode == .encrypted {
                repositorySyncedDataRevision = nil
            } else if loadedFromRepository {
                repositorySyncedDataRevision = dataRevision
                presentationCache = PasteBuddyPresentationCache()
            } else {
                if syncClipboardRepositoryFromSnapshot(), let clipboardRepository {
                    var lightweightSnapshot = try clipboardRepository.exportSnapshot(hydrateAssets: false)
                    lightweightSnapshot.security.storageMode = resolvedStorageMode
                    snapshot = lightweightSnapshot
                    refreshDerivedDocumentsIfNeeded()
                    rebuildDedupeIndex()
                    rebuildCaptureHistoryState()
                    repositorySyncedDataRevision = dataRevision
                    presentationCache = PasteBuddyPresentationCache()
                }
            }
            clearPendingRepositoryPlan()
            isPersistenceWriteBlocked = false
            lastErrorMessage = nil
            selectedItemID = filteredItems.first?.id
            selectedItemIDs = selectedItemID.map { [$0] } ?? []
        } catch {
            markHistoryPersistenceUnavailable()
        }
    }

    @discardableResult
    public func loadAsync() async -> Bool {
        guard !isHistoryStorageMigrationInProgress else {
            recordPersistenceLoadFailure(stage: .storageMigration, reason: .cancelled)
            return false
        }
        let revisionBeforePendingFlush = dataRevision
        if pendingSaveTask != nil {
            guard await flushPendingSave() else {
                recordPersistenceLoadFailure(
                    stage: .loadApply,
                    reason: Task.isCancelled ? .cancelled : .unknown
                )
                return false
            }
            guard dataRevision == revisionBeforePendingFlush else {
                recordPersistenceLoadFailure(stage: .loadApply, reason: .cancelled)
                return false
            }
        }
        let revisionBeforeLoad = dataRevision
        var loadStage = PasteBuddyPersistenceLoadDiagnostic.Stage.snapshotLoad
        do {
            let authority = try await Task.detached(priority: .userInitiated) { [authorityStore] in
                try authorityStore.load()
            }.value
            if let authority {
                guard authority.phase == .stable else {
                    throw PasteBuddyPersistenceError.historyUnavailable
                }
                if authority.authority == .sqlite {
                    loadStage = .repositoryInitialization
                    try await initializeDeferredRepositoryIfNeeded()
                    loadStage = .repositoryMetadata
                    guard try await repositorySyncActor?.hasStoredSnapshot() == true,
                          let repositorySyncActor else {
                        throw PasteBuddyPersistenceError.historyUnavailable
                    }
                    loadStage = .repositoryExport
                    let loadedSnapshot = try await repositorySyncActor.exportSnapshot(hydrateAssets: false)
                    guard dataRevision == revisionBeforeLoad else {
                        recordPersistenceLoadFailure(stage: .loadApply, reason: .cancelled)
                        return false
                    }
                    snapshot = loadedSnapshot
                    snapshot.security.storageMode = .standard
                    diskStore.storageMode = .standard
                    if snapshot.security.requiresBiometricUnlock {
                        lockHistory()
                    } else {
                        historyUnlockedAt = Date()
                    }
                    refreshDerivedDocumentsIfNeeded()
                    rebuildDedupeIndex()
                    rebuildCaptureHistoryState()
                    repositorySyncedDataRevision = dataRevision
                    clearPendingRepositoryPlan()
                    presentationCache = PasteBuddyPresentationCache()
                    isPersistenceWriteBlocked = false
                    lastErrorMessage = nil
                    selectedItemID = filteredItems.first?.id
                    selectedItemIDs = selectedItemID.map { [$0] } ?? []
                    lastPersistenceLoadDiagnostic = nil
                    return true
                }
            }
            let diskResult = try await persistenceActor.load()
            let diskStorageMode = diskResult.loadedStorageMode ?? diskResult.snapshot.security.storageMode
            if diskStorageMode == .encrypted {
                // Do not open plaintext residue after an encrypted commit. Keep
                // an existing deferred URL only long enough to remove it below.
                if clipboardRepository == nil,
                   let databaseURL = deferredRepositoryDatabaseURL,
                   !Self.sqliteFilesExist(at: databaseURL) {
                    deferredRepositoryDatabaseURL = nil
                }
            } else {
                loadStage = .repositoryInitialization
                try await initializeDeferredRepositoryIfNeeded()
            }
            let loadedFromRepository: Bool
            if diskStorageMode == .encrypted {
                loadedFromRepository = false
            } else {
                loadStage = .repositoryMetadata
                loadedFromRepository = try await repositorySyncActor?.hasStoredSnapshot() == true
            }
            var loadedSnapshot: PasteBuddySnapshot
            if loadedFromRepository, let repositorySyncActor {
                loadStage = .repositoryExport
                loadedSnapshot = try await repositorySyncActor.exportSnapshot(hydrateAssets: false)
            } else {
                loadedSnapshot = diskResult.snapshot
            }
            let resolvedStorageMode: SnapshotStorageMode = (
                diskStorageMode == .encrypted || loadedSnapshot.security.storageMode == .encrypted
            ) ? .encrypted : .standard
            if resolvedStorageMode == .encrypted, loadedFromRepository, let repositorySyncActor {
                loadStage = .repositoryExport
                loadedSnapshot = try await repositorySyncActor.exportSnapshot()
            }

            loadStage = .loadApply
            if let beforeApplyingAsyncLoadForTesting {
                await beforeApplyingAsyncLoadForTesting()
            }
            guard dataRevision == revisionBeforeLoad else {
                recordPersistenceLoadFailure(stage: .loadApply, reason: .cancelled)
                return false
            }

            loadedSnapshot.security.storageMode = resolvedStorageMode
            snapshot = loadedSnapshot
            diskStore.storageMode = resolvedStorageMode
            if snapshot.security.requiresBiometricUnlock {
                lockHistory()
            } else {
                historyUnlockedAt = Date()
            }
            refreshDerivedDocumentsIfNeeded()
            rebuildDedupeIndex()
            rebuildCaptureHistoryState()
            isPersistenceWriteBlocked = false
            lastErrorMessage = nil

            if resolvedStorageMode == .encrypted {
                loadStage = .storageMigration
                if repositorySyncActor != nil || clipboardRepository != nil || deferredRepositoryDatabaseURL != nil {
                    isHistoryStorageMigrationInProgress = true
                    if let beforeCommittingHistoryStorageMigrationForTesting {
                        await beforeCommittingHistoryStorageMigrationForTesting()
                    }
                    try await persistCurrentSnapshotUntilStable(storageMode: .encrypted)
                    try await removePlaintextRepositoryForEncryptedStorageAsync()
                    try await persistCurrentSnapshotUntilStable(storageMode: .encrypted)
                    isHistoryStorageMigrationInProgress = false
                }
                repositorySyncedDataRevision = nil
                clearPendingRepositoryPlan()
            } else if !loadedFromRepository, let repositorySyncActor {
                loadStage = .repositoryImport
                let revisionToSync = dataRevision
                let snapshotToSync = snapshot
                try await repositorySyncActor.synchronize(with: snapshotToSync)
                if dataRevision == revisionToSync {
                    loadStage = .repositoryExport
                    var lightweightSnapshot = try await repositorySyncActor.exportSnapshot(hydrateAssets: false)
                    if dataRevision == revisionToSync {
                        lightweightSnapshot.security.storageMode = resolvedStorageMode
                        snapshot = lightweightSnapshot
                        refreshDerivedDocumentsIfNeeded()
                        rebuildDedupeIndex()
                        rebuildCaptureHistoryState()
                        repositorySyncedDataRevision = dataRevision
                        clearPendingRepositoryPlan()
                        presentationCache = PasteBuddyPresentationCache()
                    } else {
                        repositorySyncedDataRevision = nil
                    }
                } else {
                    repositorySyncedDataRevision = nil
                }
            } else if loadedFromRepository {
                repositorySyncedDataRevision = dataRevision
                clearPendingRepositoryPlan()
                presentationCache = PasteBuddyPresentationCache()
            }
            selectedItemID = filteredItems.first?.id
            selectedItemIDs = selectedItemID.map { [$0] } ?? []
            lastPersistenceLoadDiagnostic = nil
            return true
        } catch {
            recordPersistenceLoadFailure(
                stage: loadStage,
                reason: PasteBuddyPersistenceLoadDiagnostic.reason(for: error, at: loadStage)
            )
            markHistoryPersistenceUnavailable()
            return false
        }
    }

    private func recordPersistenceLoadFailure(
        stage: PasteBuddyPersistenceLoadDiagnostic.Stage,
        reason: PasteBuddyPersistenceLoadDiagnostic.Reason
    ) {
        let diagnostic = PasteBuddyPersistenceLoadDiagnostic(stage: stage, reason: reason)
        lastPersistenceLoadDiagnostic = diagnostic
        Self.persistenceLogger.error(
            "History load failed: stage=\(diagnostic.stage.rawValue, privacy: .public) reason=\(diagnostic.reason.rawValue, privacy: .public)"
        )
    }

    func markHistoryPersistenceUnavailable() {
        isHistoryStorageMigrationInProgress = false
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        pendingSaveTaskID = nil
        repositorySyncedDataRevision = nil
        isPersistenceWriteBlocked = true
        lastErrorMessage = PasteBuddyPersistenceError.historyUnavailable.localizedDescription
    }

    nonisolated private static func sqliteFilesExist(at databaseURL: URL) -> Bool {
        let fileManager = FileManager.default
        return [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ].contains { fileManager.fileExists(atPath: $0.path) }
    }

    private func initializeDeferredRepositoryIfNeeded() async throws {
        guard clipboardRepository == nil,
              let databaseURL = deferredRepositoryDatabaseURL else {
            return
        }
        let task: Task<(ClipboardItemRepository, Bool), Error>
        if let deferredRepositoryInitializationTask {
            task = deferredRepositoryInitializationTask
        } else {
            task = Task.detached(priority: .userInitiated) {
                #if canImport(Darwin)
                let initializedOnMainThread = pthread_main_np() != 0
                #else
                let initializedOnMainThread = false
                #endif
                let repository = ClipboardItemRepository(
                    database: try PasteBuddyDatabase(fileURL: databaseURL)
                )
                return (repository, initializedOnMainThread)
            }
            deferredRepositoryInitializationTask = task
        }
        defer { deferredRepositoryInitializationTask = nil }
        let (repository, initializedOnMainThread) = try await task.value
        clipboardRepository = repository
        repositorySyncActor = ClipboardRepositorySyncActor(repository: repository)
        deferredRepositoryDatabaseURL = nil
        lastDeferredRepositoryInitializationWasOnMainThreadForTesting = initializedOnMainThread
    }

    private func removePlaintextRepositoryForEncryptedStorage() throws {
        let databaseURL = clipboardRepository?.fileURL ?? deferredRepositoryDatabaseURL
        try clipboardRepository?.eraseSensitiveContent()
        repositorySyncActor = nil
        clipboardRepository = nil
        deferredRepositoryDatabaseURL = nil
        repositorySyncedDataRevision = nil
        clearPendingRepositoryPlan()
        if let databaseURL {
            try Self.removeSQLiteFiles(at: databaseURL)
        }
    }

    private func removePlaintextRepositoryForEncryptedStorageAsync() async throws {
        let databaseURL = clipboardRepository?.fileURL ?? deferredRepositoryDatabaseURL
        if let repositorySyncActor {
            try await repositorySyncActor.eraseSensitiveContent()
        }
        self.repositorySyncActor = nil
        clipboardRepository = nil
        deferredRepositoryDatabaseURL = nil
        repositorySyncedDataRevision = nil
        clearPendingRepositoryPlan()
        if let databaseURL {
            try await Task.detached(priority: .utility) {
                try Self.removeSQLiteFiles(at: databaseURL)
            }.value
        }
    }

    nonisolated private static func removeSQLiteFiles(at databaseURL: URL) throws {
        let fileManager = FileManager.default
        for url in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    public func save() {
        guard !isPersistenceWriteBlocked else { return }
        guard !isHistoryStorageMigrationInProgress else { return }
        markRepositoryFullSyncRequired()
        guard let saveDebounceNanoseconds else {
            saveImmediately()
            return
        }
        scheduleSave(delayNanoseconds: saveDebounceNanoseconds)
    }

    private func saveAndFlush() {
        guard !isPersistenceWriteBlocked else { return }
        guard !isHistoryStorageMigrationInProgress else { return }
        markRepositoryFullSyncRequired()
        guard saveDebounceNanoseconds != nil else {
            saveImmediately()
            return
        }
        scheduleSave(delayNanoseconds: 0)
    }

    @discardableResult
    public func flushPendingSave() async -> Bool {
        do {
            return try await flushPendingSaveRespectingCancellation()
        } catch is CancellationError {
            return false
        } catch {
            isPersistenceWriteBlocked = true
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    public func flushPendingSaveOrThrow() async throws {
        guard try await flushPendingSaveRespectingCancellation() else {
            throw PasteBuddyPersistenceError.historyUnavailable
        }
    }

    private func flushPendingSaveRespectingCancellation() async throws -> Bool {
        guard !isHistoryStorageMigrationInProgress else { return false }
        guard !isPersistenceWriteBlocked else {
            pendingSaveTask?.cancel()
            pendingSaveTask = nil
            pendingSaveTaskID = nil
            return false
        }

        while true {
            while let inFlightSave = pendingSaveTask {
                pendingSaveTask = nil
                pendingSaveTaskID = nil
                inFlightSave.cancel()
                await inFlightSave.value
            }
            try Task.checkCancellation()

            let snapshotToSave = snapshot
            let dataRevisionToSync = dataRevision
            let persistenceGeneration = nextPersistenceGeneration()
            let hasRepository = repositorySyncActor != nil || clipboardRepository != nil
            let repositoryRequiresFullSync = pendingRepositoryRequiresFullSync
            let captureJournal = pendingRepositoryCaptureJournal
            let externalizationTask = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                return try Self.externalizedSnapshotForDiskPersistence(
                    snapshotToSave,
                    hasRepository: hasRepository
                )
            }
            let snapshotToPersist = try await withTaskCancellationHandler {
                try await externalizationTask.value
            } onCancel: {
                externalizationTask.cancel()
            }
            try Task.checkCancellation()
            if let beforePersistingFlushSnapshotForTesting {
                self.beforePersistingFlushSnapshotForTesting = nil
                await beforePersistingFlushSnapshotForTesting()
            }
            try Task.checkCancellation()

            guard let commitLease = await persistenceCommitGate.acquire(
                generation: persistenceGeneration
            ) else {
                try Task.checkCancellation()
                continue
            }
            do {
                try Task.checkCancellation()
            } catch {
                persistenceCommitGate.release(commitLease, outcome: .abortedBeforeWrite)
                throw error
            }

            // Cancellation is honored up to this explicit commit point. Once the
            // repository transaction starts, finish the matching snapshot write
            // as one shielded unit so cancellation cannot leave the two stores
            // at different revisions.
            let commitTask = Task {
                var crossedWriteBarrier = false
                do {
                    if let repositorySyncActor {
                        if repositoryRequiresFullSync {
                            try await repositorySyncActor.synchronize(with: snapshotToSave)
                            crossedWriteBarrier = true
                        } else if !captureJournal.isEmpty {
                            try await repositorySyncActor.applyCaptureJournal(captureJournal)
                            crossedWriteBarrier = true
                        }
                    }
                    crossedWriteBarrier = true
                    let didPersist = try await persistenceActor.save(
                        snapshotToPersist,
                        storageMode: snapshotToSave.security.storageMode,
                        hasAuthoritativeRepository: hasRepository,
                        generation: persistenceGeneration
                    )
                    guard didPersist else {
                        throw PasteBuddyPersistenceError.historyUnavailable
                    }
                    persistenceCommitGate.release(commitLease, outcome: .committed)
                    return true
                } catch {
                    persistenceCommitGate.release(
                        commitLease,
                        outcome: crossedWriteBarrier ? .failedAfterWrite : .abortedBeforeWrite
                    )
                    throw error
                }
            }
            do {
                _ = try await commitTask.value
                diskStore.storageMode = snapshotToSave.security.storageMode
                completeRepositorySave(dataRevision: dataRevisionToSync)
            } catch {
                isPersistenceWriteBlocked = true
                lastErrorMessage = error.localizedDescription
                return false
            }

            guard dataRevision == dataRevisionToSync, pendingSaveTask == nil else {
                continue
            }
            lastErrorMessage = nil
            return true
        }
    }

    public func requirePersistenceReady() throws {
        guard !isPersistenceWriteBlocked else {
            throw PasteBuddyPersistenceError.historyUnavailable
        }
    }

    private func saveImmediately() {
        guard !isPersistenceWriteBlocked else { return }
        let persistenceGeneration = nextPersistenceGeneration()
        guard let commitLease = persistenceCommitGate.tryAcquireImmediately(
            generation: persistenceGeneration
        ) else {
            scheduleSave(delayNanoseconds: 0)
            return
        }
        let snapshotToSave = snapshot
        let dataRevisionToSync = dataRevision
        let hasRepository = repositorySyncActor != nil || clipboardRepository != nil
        let repositoryWritePlanned = clipboardRepository != nil
            && (pendingRepositoryRequiresFullSync
                || !pendingRepositoryCaptureJournal.isEmpty
                || repositorySyncedDataRevision != dataRevisionToSync)
        var crossedWriteBarrier = false
        do {
            let snapshotToPersist = try Self.externalizedSnapshotForDiskPersistence(
                snapshotToSave,
                hasRepository: hasRepository
            )
            guard applyPendingRepositoryPlanImmediately(snapshot: snapshotToSave) else {
                persistenceCommitGate.release(commitLease, outcome: .abortedBeforeWrite)
                isPersistenceWriteBlocked = true
                return
            }
            crossedWriteBarrier = repositoryWritePlanned
            diskStore.storageMode = snapshotToSave.security.storageMode
            crossedWriteBarrier = true
            if snapshotToSave.security.storageMode == .encrypted || !hasRepository {
                try diskStore.save(snapshotToPersist)
            }
            persistenceCommitGate.release(commitLease, outcome: .committed)
            completeRepositorySave(dataRevision: dataRevisionToSync)
        } catch is CancellationError {
            persistenceCommitGate.release(
                commitLease,
                outcome: crossedWriteBarrier ? .failedAfterWrite : .abortedBeforeWrite
            )
            // A synchronous save can inherit cancellation from a MainActor task.
            // Preserve the mutation by handing it to an independent writer instead
            // of silently dropping the only pending persistence attempt.
            scheduleSave(delayNanoseconds: 0)
        } catch {
            persistenceCommitGate.release(
                commitLease,
                outcome: crossedWriteBarrier ? .failedAfterWrite : .abortedBeforeWrite
            )
            isPersistenceWriteBlocked = true
            lastErrorMessage = error.localizedDescription
        }
    }

    private func scheduleSave(delayNanoseconds: UInt64) {
        guard !isPersistenceWriteBlocked else { return }
        let snapshotToSave = snapshot
        let dataRevisionToSync = dataRevision
        let hasRepository = repositorySyncActor != nil || clipboardRepository != nil
        let repositoryRequiresFullSync = pendingRepositoryRequiresFullSync
        let captureJournal = pendingRepositoryCaptureJournal
        let precedingSaveTask = pendingSaveTask
        precedingSaveTask?.cancel()
        let saveTaskID = UUID()
        let persistenceGeneration = nextPersistenceGeneration()
        pendingSaveTaskID = saveTaskID
        pendingSaveTask = Task { [persistenceActor, persistenceCommitGate, repositorySyncActor] in
            // Cancellation is cooperative and an older writer may already be
            // inside repository I/O. Chain writers so a replacement can never
            // finish before (and then be overwritten by) its predecessor.
            await precedingSaveTask?.value
            guard !Task.isCancelled else { return }
            if delayNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            // Externalizing large payloads (asset hashing + search-document refresh)
            // is deliberately deferred past the debounce window and off the main
            // actor so rapid save() bursts never pay for work that gets cancelled.
            let externalizationTask = Task.detached(priority: .utility) {
                try Self.externalizedSnapshotForDiskPersistence(
                    snapshotToSave,
                    hasRepository: hasRepository
                )
            }
            let snapshotToPersist: PasteBuddySnapshot
            do {
                snapshotToPersist = try await withTaskCancellationHandler {
                    try await externalizationTask.value
                } onCancel: {
                    externalizationTask.cancel()
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard self.pendingSaveTaskID == saveTaskID else { return }
                    self.repositorySyncedDataRevision = nil
                    self.pendingSaveTask = nil
                    self.pendingSaveTaskID = nil
                    self.isPersistenceWriteBlocked = true
                    self.lastErrorMessage = error.localizedDescription
                }
                return
            }
            guard !Task.isCancelled else { return }
            guard let commitLease = await persistenceCommitGate.acquire(
                generation: persistenceGeneration
            ) else {
                return
            }
            guard !Task.isCancelled else {
                persistenceCommitGate.release(commitLease, outcome: .abortedBeforeWrite)
                return
            }
            var crossedWriteBarrier = false
            do {
                if let repositorySyncActor {
                    if repositoryRequiresFullSync {
                        try await repositorySyncActor.synchronize(with: snapshotToSave)
                        crossedWriteBarrier = true
                    } else if !captureJournal.isEmpty {
                        try await repositorySyncActor.applyCaptureJournal(captureJournal)
                        crossedWriteBarrier = true
                    }
                }
                crossedWriteBarrier = true
                let didPersist = try await persistenceActor.save(
                    snapshotToPersist,
                    storageMode: snapshotToSave.security.storageMode,
                    hasAuthoritativeRepository: hasRepository,
                    generation: persistenceGeneration
                )
                guard didPersist else {
                    throw PasteBuddyPersistenceError.historyUnavailable
                }
                persistenceCommitGate.release(commitLease, outcome: .committed)
                await MainActor.run {
                    guard self.pendingSaveTaskID == saveTaskID else { return }
                    guard self.dataRevision == dataRevisionToSync else { return }
                    self.completeRepositorySave(dataRevision: dataRevisionToSync)
                    self.pendingSaveTask = nil
                    self.pendingSaveTaskID = nil
                    self.diskStore.storageMode = snapshotToSave.security.storageMode
                    self.lastErrorMessage = nil
                }
            } catch {
                persistenceCommitGate.release(
                    commitLease,
                    outcome: crossedWriteBarrier ? .failedAfterWrite : .abortedBeforeWrite
                )
                await MainActor.run {
                    guard self.pendingSaveTaskID == saveTaskID else { return }
                    guard !Task.isCancelled else { return }
                    self.repositorySyncedDataRevision = nil
                    self.pendingSaveTask = nil
                    self.pendingSaveTaskID = nil
                    self.isPersistenceWriteBlocked = true
                    self.lastErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func saveCaptureMutation(
        _ mutation: ClipboardRepositoryCaptureMutation,
        repositoryWasCurrent: Bool
    ) {
        saveCaptureMutations([mutation], repositoryWasCurrent: repositoryWasCurrent)
    }

    private func saveCaptureMutations(
        _ mutations: [ClipboardRepositoryCaptureMutation],
        repositoryWasCurrent: Bool
    ) {
        guard !mutations.isEmpty else { return }
        guard !isPersistenceWriteBlocked else { return }
        guard !isHistoryStorageMigrationInProgress else { return }
        if clipboardRepository != nil {
            if repositoryWasCurrent, !pendingRepositoryRequiresFullSync {
                pendingRepositoryCaptureJournal.mutations.append(contentsOf: mutations)
                pendingRepositoryJournalRevision = dataRevision
            } else {
                markRepositoryFullSyncRequired()
            }
        }
        guard let saveDebounceNanoseconds else {
            saveImmediately()
            return
        }
        scheduleSave(delayNanoseconds: saveDebounceNanoseconds)
    }

    private func canAppendCaptureMutationToRepositoryJournal() -> Bool {
        guard clipboardRepository != nil, !pendingRepositoryRequiresFullSync else { return false }
        return repositorySyncedDataRevision == dataRevision
            || pendingRepositoryJournalRevision == dataRevision
    }

    private func markRepositoryFullSyncRequired() {
        guard clipboardRepository != nil else { return }
        pendingRepositoryRequiresFullSync = true
        pendingRepositoryCaptureJournal.mutations.removeAll()
        pendingRepositoryJournalRevision = dataRevision
    }

    private func clearPendingRepositoryPlan() {
        pendingRepositoryRequiresFullSync = false
        pendingRepositoryCaptureJournal.mutations.removeAll()
        pendingRepositoryJournalRevision = nil
    }

    private func completeRepositorySave(dataRevision savedDataRevision: Int) {
        guard clipboardRepository != nil, dataRevision == savedDataRevision else { return }
        repositorySyncedDataRevision = savedDataRevision
        clearPendingRepositoryPlan()
        presentationCache = PasteBuddyPresentationCache()
    }

    private func applyPendingRepositoryPlanImmediately(snapshot snapshotToSave: PasteBuddySnapshot) -> Bool {
        guard let clipboardRepository else { return true }
        do {
            if pendingRepositoryRequiresFullSync {
                try clipboardRepository.synchronize(with: snapshotToSave)
            } else if !pendingRepositoryCaptureJournal.isEmpty {
                try clipboardRepository.applyCaptureJournal(pendingRepositoryCaptureJournal)
            } else if repositorySyncedDataRevision != dataRevision {
                try clipboardRepository.synchronize(with: snapshotToSave)
            }
            return true
        } catch {
            repositorySyncedDataRevision = nil
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    public var filteredItems: [ClipboardItem] {
        let cacheKey = filteredItemsCacheKey()
        if presentationCache.filteredItemsKey == cacheKey {
            return presentationCache.filteredItems
        }

        let items = makeFilteredItems(scope: selectedScope, isHistoryAccessLocked: cacheKey.isHistoryAccessLocked)
        presentationCache.filteredItemsKey = cacheKey
        presentationCache.filteredItems = items
        return items
    }

    public var filteredItemsSnapshot: [ClipboardItem] {
        filteredItems
    }

    public func filteredItems(for scope: PasteScope) -> [ClipboardItem] {
        if scope == selectedScope {
            return filteredItems
        }
        return makeFilteredItems(scope: scope, isHistoryAccessLocked: isHistoryAccessLocked)
    }

    /// Fetches a page and its count without synchronously dispatching a GRDB
    /// read from MainActor. Shelf and side-panel rendering must use this path.
    public func filteredItemsPageAndCount(
        for scope: PasteScope,
        offset: Int,
        limit: Int = 100
    ) async -> PasteBuddyFilteredItemsPage {
        let interval = PasteBuddyPerformanceSignposts.begin(.pageAndCountQuery)
        var resultBucket = PasteBuddyPerformanceSignposts.ItemCountBucket.unknown
        var resultCode = PasteBuddyPerformanceSignposts.ResultCode.noChange
        defer {
            PasteBuddyPerformanceSignposts.end(
                interval,
                itemCount: resultBucket,
                result: resultCode
            )
        }
        lastInMemoryPageQueryRanOnMainThreadForTesting = nil
        guard !isHistoryAccessLocked, limit > 0 else {
            resultBucket = .none
            resultCode = .blocked
            return PasteBuddyFilteredItemsPage(items: [], totalCount: 0)
        }

        let resolvedOffset = max(offset, 0)
        let filters = resolvedSearchFilters()
        guard !filters.isImpossible else {
            resultBucket = .none
            return PasteBuddyFilteredItemsPage(items: [], totalCount: 0)
        }

        let pinboardID: UUID?
        switch scope {
        case .history:
            pinboardID = nil
        case .pinboard(let id):
            pinboardID = id
        case .pasteStack:
            pinboardID = nil
        }

        if let clipboardRepository,
           repositorySyncedDataRevision == dataRevision {
            let request = ClipboardItemPageRequest(
                searchQuery: filters.textQuery,
                contentType: contentTypeFilter,
                sourceAppName: filters.sourceAppName,
                deviceName: deviceFilter,
                dateFilter: dateFilter,
                pinboardID: pinboardID,
                limit: limit,
                offset: resolvedOffset
            )
            do {
                let result = try await clipboardRepository.fetchPageAndCount(request)
                resultBucket = .init(itemCount: result.totalCount)
                resultCode = .succeeded
                return PasteBuddyFilteredItemsPage(
                    items: result.items,
                    totalCount: result.totalCount
                )
            } catch is CancellationError {
                resultBucket = .none
                resultCode = .cancelled
                return PasteBuddyFilteredItemsPage(items: [], totalCount: 0)
            } catch {
                lastErrorMessage = error.localizedDescription
                resultBucket = .none
                resultCode = .failed
                return PasteBuddyFilteredItemsPage(items: [], totalCount: 0)
            }
        }

        let sourceItems: [ClipboardItem]
        let orderedItemIDs: [UUID]?
        switch scope {
        case .history:
            sourceItems = snapshot.items
            orderedItemIDs = nil
        case .pasteStack:
            sourceItems = pasteStackItemsInPasteOrder
            orderedItemIDs = nil
        case .pinboard(let id):
            guard let pinboard = snapshot.pinboards.first(where: { $0.id == id }) else {
                resultBucket = .none
                return PasteBuddyFilteredItemsPage(items: [], totalCount: 0)
            }
            sourceItems = snapshot.items
            orderedItemIDs = pinboard.itemIDs
        }
        let query = PasteBuddyInMemoryPageQuery(
            items: sourceItems,
            orderedItemIDs: orderedItemIDs,
            filters: filters,
            contentType: contentTypeFilter,
            deviceName: deviceFilter,
            dateFilter: dateFilter,
            offset: resolvedOffset,
            limit: limit
        )
        let queryTask = Task.detached(priority: .userInitiated) {
            query.execute()
        }
        let result = await withTaskCancellationHandler {
            await queryTask.value
        } onCancel: {
            queryTask.cancel()
        }
        guard !result.wasCancelled else {
            resultBucket = .none
            resultCode = .cancelled
            return PasteBuddyFilteredItemsPage(items: [], totalCount: 0)
        }
        lastInMemoryPageQueryRanOnMainThreadForTesting = result.ranOnMainThread
        resultBucket = .init(itemCount: result.page.totalCount)
        resultCode = .succeeded
        return result.page
    }

    public func searchItemsPage(
        query: String,
        offset: Int = 0,
        limit: Int
    ) async throws -> [ClipboardItem] {
        lastInMemoryPageQueryRanOnMainThreadForTesting = nil
        try requirePersistenceReady()
        guard !isHistoryAccessLocked, limit > 0 else { return [] }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }
        let resolvedOffset = max(offset, 0)
        if let clipboardRepository,
           repositorySyncedDataRevision == dataRevision {
            let page = try await clipboardRepository.fetchPageAsync(ClipboardItemPageRequest(
                searchQuery: trimmedQuery,
                limit: limit,
                offset: resolvedOffset
            ))
            try requirePersistenceReady()
            guard !isHistoryAccessLocked else { return [] }
            return page
        }
        let query = PasteBuddyInMemoryPageQuery(
            items: snapshot.items,
            orderedItemIDs: nil,
            filters: PasteBuddyResolvedSearchFilters(
                textQuery: trimmedQuery,
                sourceAppName: nil,
                isImpossible: false
            ),
            contentType: nil,
            deviceName: nil,
            dateFilter: .any,
            offset: resolvedOffset,
            limit: limit
        )
        let queryTask = Task.detached(priority: .userInitiated) {
            query.execute()
        }
        let result = await withTaskCancellationHandler {
            await queryTask.value
        } onCancel: {
            queryTask.cancel()
        }
        guard !result.wasCancelled else { throw CancellationError() }
        try requirePersistenceReady()
        guard !isHistoryAccessLocked else { return [] }
        lastInMemoryPageQueryRanOnMainThreadForTesting = result.ranOnMainThread
        return result.page.items
    }

    public func filteredItemCount(for scope: PasteScope) -> Int {
        makeFilteredItemCount(scope: scope, isHistoryAccessLocked: isHistoryAccessLocked)
    }

    public var mainListItemsSnapshot: [ClipboardItem] {
        let cacheKey = mainListItemsCacheKey()
        if presentationCache.mainListItemsKey == cacheKey {
            return presentationCache.mainListItems
        }

        let items = makeMainListItems(isHistoryAccessLocked: cacheKey.isHistoryAccessLocked)
        presentationCache.mainListItemsKey = cacheKey
        presentationCache.mainListItems = items
        return items
    }

    private func makeFilteredItems(scope: PasteScope, isHistoryAccessLocked: Bool) -> [ClipboardItem] {
        guard !isHistoryAccessLocked else { return [] }
        let scopedItems: [ClipboardItem]
        switch scope {
        case .history:
            scopedItems = snapshot.items
            let items = filtered(scopedItems)
            if clipboardRepository != nil, repositorySyncedDataRevision == dataRevision {
                return Self.page(items, offset: 0, limit: Self.defaultHistoryPageLimit)
            }
            return items
        case .pasteStack:
            return filtered(pasteStackItemsInPasteOrder)
        case .pinboard(let id):
            guard let pinboard = snapshot.pinboards.first(where: { $0.id == id }) else {
                return []
            }
            let itemByID = cachedItemByID()
            scopedItems = pinboard.itemIDs.compactMap { itemByID[$0] }
            let items = filtered(scopedItems)
            if clipboardRepository != nil, repositorySyncedDataRevision == dataRevision {
                return Self.page(items, offset: 0, limit: Self.defaultHistoryPageLimit)
            }
            return items
        }
    }

    private func makeFilteredItemCount(scope: PasteScope, isHistoryAccessLocked: Bool) -> Int {
        guard !isHistoryAccessLocked else { return 0 }
        let filters = resolvedSearchFilters()
        guard !filters.isImpossible else { return 0 }
        let normalizedQuery = ClipboardItem.normalizedSearchQuery(filters.textQuery)
        let searchTerms = ClipboardItem.searchTerms(inNormalizedQuery: normalizedQuery)

        func matches(_ item: ClipboardItem) -> Bool {
            item.matchesNormalizedSearchQuery(normalizedQuery, terms: searchTerms)
                && matchesStructuredFilters(item, sourceAppName: filters.sourceAppName)
        }

        switch scope {
        case .history:
            return snapshot.items.reduce(0) { count, item in
                count + (matches(item) ? 1 : 0)
            }
        case .pasteStack:
            return pasteStackItemsInPasteOrder.reduce(0) { count, item in
                count + (matches(item) ? 1 : 0)
            }
        case .pinboard(let id):
            guard let pinboard = snapshot.pinboards.first(where: { $0.id == id }) else {
                return 0
            }
            let itemByID = cachedItemByID()
            return pinboard.itemIDs.reduce(0) { count, itemID in
                guard let item = itemByID[itemID] else { return count }
                return count + (matches(item) ? 1 : 0)
            }
        }
    }

    private func makeMainListItems(isHistoryAccessLocked: Bool) -> [ClipboardItem] {
        guard !isHistoryAccessLocked else { return [] }
        switch selectedScope {
        case .history:
            return filtered(snapshot.items)
        case .pasteStack:
            return filtered(pasteStackItemsInPasteOrder)
        case .pinboard(let id):
            guard let pinboard = snapshot.pinboards.first(where: { $0.id == id }) else {
                return []
            }
            let itemByID = cachedItemByID()
            let scopedItems = pinboard.itemIDs.compactMap { itemByID[$0] }
            return filtered(scopedItems)
        }
    }

    public var selectedItem: ClipboardItem? {
        guard !isHistoryAccessLocked else { return nil }
        let preferredID = selectedItemID ?? selectedItemIDs.first
        guard let preferredID else { return filteredItems.first }
        return pasteStackItems.first(where: { $0.id == preferredID })
            ?? cachedItemByID()[preferredID]
    }

    public func hydratedItem(for item: ClipboardItem) async -> ClipboardItem {
        let needsImageData = item.payload.imageData == nil && item.payload.imageAssetID != nil
        let needsRTFData = item.payload.rtfData == nil && item.payload.rtfAssetID != nil
        guard needsImageData || needsRTFData else {
            return item
        }
        if let snapshotItem = cachedItemByID()[item.id] {
            let snapshotHasNeededImageData = !needsImageData || snapshotItem.payload.imageData != nil
            let snapshotHasNeededRTFData = !needsRTFData || snapshotItem.payload.rtfData != nil
            if snapshotHasNeededImageData && snapshotHasNeededRTFData {
                return snapshotItem
            }
        }
        guard let repositorySyncActor else {
            return item
        }
        do {
            return try await repositorySyncActor.hydrateAssets(for: item)
        } catch {
            lastErrorMessage = error.localizedDescription
            return item
        }
    }

    public func hydratedItems(for items: [ClipboardItem]) async -> [ClipboardItem] {
        let needsAssetHydration = items.contains { item in
            (item.payload.imageData == nil && item.payload.imageAssetID != nil)
                || (item.payload.rtfData == nil && item.payload.rtfAssetID != nil)
        }
        guard needsAssetHydration else { return items }
        guard let repositorySyncActor else { return items }
        do {
            return try await repositorySyncActor.hydrateAssets(for: items)
        } catch {
            lastErrorMessage = error.localizedDescription
            return items
        }
    }

    public func imageData(for item: ClipboardItem) async -> Data? {
        if let imageData = item.payload.imageData {
            return imageData
        }
        if let snapshotImageData = cachedItemByID()[item.id]?.payload.imageData {
            return snapshotImageData
        }
        guard let repositorySyncActor else {
            return nil
        }
        do {
            return try await repositorySyncActor.imageData(for: item)
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    public var selectedItemsInDisplayOrder: [ClipboardItem] {
        let cacheKey = selectedItemsCacheKey()
        if presentationCache.selectedItemsKey == cacheKey {
            return presentationCache.selectedItemsInDisplayOrder
        }

        let selected = selectedItemIDs
        let items: [ClipboardItem]
        if selected.isEmpty {
            items = selectedItem.map { [$0] } ?? []
        } else {
            items = mainListItemsSnapshot.filter { selected.contains($0.id) }
        }
        presentationCache.selectedItemsKey = cacheKey
        presentationCache.selectedItemsInDisplayOrder = items
        return items
    }

    public var hasMultipleSelectedItems: Bool {
        selectedItemsInDisplayOrder.count > 1
    }

    public var selectedPasteOrderPreview: PasteOrderPreview? {
        let items = selectedItemsInDisplayOrder
        guard items.count > 1 else { return nil }
        return PasteOrderPreview(items: items)
    }

    public func setSelectedItemIDs(_ ids: Set<UUID>, in scope: PasteScope? = nil) {
        let items = scope.map { filteredItems(for: $0) } ?? mainListItemsSnapshot
        let primaryID = items.first(where: { ids.contains($0.id) })?.id
        guard selectedItemIDs != ids || selectedItemID != primaryID else { return }
        selectedItemIDs = ids
        selectedItemID = primaryID
    }

    public func selectSingleItem(_ id: UUID?) {
        let ids = id.map { Set([$0]) } ?? []
        guard selectedItemID != id || selectedItemIDs != ids else { return }
        selectedItemID = id
        selectedItemIDs = ids
    }

    public var pasteStackItemsInPasteOrder: [ClipboardItem] {
        switch pasteStackDirection {
        case .topToBottom:
            pasteStackItems
        case .bottomToTop:
            pasteStackItems.reversed()
        }
    }

    public var pasteStackPreview: PasteStackPreview? {
        guard !pasteStackItems.isEmpty else { return nil }
        return PasteStackPreview(
            itemsInPasteOrder: pasteStackItemsInPasteOrder,
            direction: pasteStackDirection,
            isCollecting: isPasteStackActive
        )
    }

    public var availableSourceApps: [String] {
        availableFilterValues().sourceApps
    }

    public var availableDevices: [String] {
        availableFilterValues().devices
    }

    public var userPinboards: [Pinboard] {
        snapshot.pinboards.filter { !SmartPinboardCategory.isSmartPinboardName($0.name) }
    }

    public var collectionOrder: [ClipboardCollectionID] {
        let canonicalOrder: [ClipboardCollectionID] = [
            .history,
            .pasteStack
        ] + SmartPinboardCategory.allCases.map(ClipboardCollectionID.smart)
            + userPinboards.map { .pinboard($0.id) }
        let validCollections = Set(canonicalOrder)
        var seen: Set<ClipboardCollectionID> = []
        let savedOrder = (snapshot.general.collectionOrder ?? []).filter {
            validCollections.contains($0) && seen.insert($0).inserted
        }
        return savedOrder + canonicalOrder.filter { seen.insert($0).inserted }
    }

    @discardableResult
    public func moveCollection(
        _ source: ClipboardCollectionID,
        relativeTo target: ClipboardCollectionID,
        afterTarget: Bool
    ) -> Bool {
        guard source != target else { return false }
        var order = collectionOrder
        guard let sourceIndex = order.firstIndex(of: source) else { return false }
        let previousOrder = order
        order.remove(at: sourceIndex)
        guard let targetIndex = order.firstIndex(of: target) else { return false }
        order.insert(source, at: targetIndex + (afterTarget ? 1 : 0))
        guard order != previousOrder else { return false }
        snapshot.general.collectionOrder = order
        save()
        return true
    }

    @discardableResult
    public func moveCollection(_ collection: ClipboardCollectionID, by offset: Int) -> Bool {
        guard offset != 0 else { return false }
        let order = collectionOrder
        guard let sourceIndex = order.firstIndex(of: collection) else { return false }
        let (destinationIndex, overflow) = sourceIndex.addingReportingOverflow(offset)
        guard !overflow, order.indices.contains(destinationIndex) else { return false }
        return moveCollection(
            collection,
            relativeTo: order[destinationIndex],
            afterTarget: offset > 0
        )
    }

    public var hasActiveFilters: Bool {
        contentTypeFilter != nil || sourceAppFilter != nil || deviceFilter != nil || dateFilter != .any
    }

    public var activeFilterSummaries: [ClipboardFilterDescriptor] {
        var summaries: [ClipboardFilterDescriptor] = []
        if let contentTypeFilter {
            summaries.append(filterDescriptor(for: contentTypeFilter))
        }
        if let sourceAppFilter {
            summaries.append(filterDescriptor(kind: .sourceApp, value: sourceAppFilter))
        }
        if let deviceFilter {
            summaries.append(filterDescriptor(kind: .device, value: deviceFilter))
        }
        if dateFilter != .any {
            summaries.append(filterDescriptor(for: dateFilter))
        }
        return summaries
    }

    public var filterSuggestions: [ClipboardFilterDescriptor] {
        filterSuggestions(matching: searchQuery)
    }

    public var canReorderCurrentPinboard: Bool {
        guard case .pinboard(let pinboardID) = selectedScope,
              !isSmartPinboard(pinboardID) else { return false }
        return !hasActiveFilters && searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var canUndoDelete: Bool {
        lastDeletedItem != nil || !lastDeletedItems.isEmpty
    }

    public var syncReadiness: SyncReadiness {
        snapshot.sync.readiness
    }

    public var cloudSyncPreflightReport: CloudSyncPreflightReport {
        let key = PasteBuddyReportCacheKey(dataRevision: dataRevision)
        if presentationCache.cloudSyncPreflightReportKey == key,
           let report = presentationCache.cloudSyncPreflightReport {
            return report
        }
        let report = CloudSyncPreflightReport(configuration: snapshot.sync)
        presentationCache.cloudSyncPreflightReportKey = key
        presentationCache.cloudSyncPreflightReport = report
        return report
    }

    public var mobileGuidanceReport: MobileIntegrationGuidanceReport {
        let key = PasteBuddyReportCacheKey(dataRevision: dataRevision)
        if presentationCache.mobileGuidanceReportKey == key,
           let report = presentationCache.mobileGuidanceReport {
            return report
        }
        let report = snapshot.mobile.guidanceReport
        presentationCache.mobileGuidanceReportKey = key
        presentationCache.mobileGuidanceReport = report
        return report
    }

    public var privacyPostureReport: PrivacyPostureReport {
        let key = PasteBuddyReportCacheKey(dataRevision: dataRevision, timeBucket: Int(Date().timeIntervalSinceReferenceDate / 60))
        if presentationCache.privacyPostureReportKey == key,
           let report = presentationCache.privacyPostureReport {
            return report
        }
        let report = snapshot.privacyPostureReport()
        presentationCache.privacyPostureReportKey = key
        presentationCache.privacyPostureReport = report
        return report
    }

    public var macMenuBarStatus: MacMenuBarStatus {
        snapshot.macMenuBarStatus()
    }

    public var accessibilityLocalizationQualityReport: AccessibilityLocalizationQualityReport {
        let key = PasteBuddyReportCacheKey(dataRevision: dataRevision)
        if presentationCache.accessibilityLocalizationQualityReportKey == key,
           let report = presentationCache.accessibilityLocalizationQualityReport {
            return report
        }
        let report = snapshot.accessibilityLocalizationQualityReport()
        presentationCache.accessibilityLocalizationQualityReportKey = key
        presentationCache.accessibilityLocalizationQualityReport = report
        return report
    }

    public var defaultPasteFormat: PasteFormat {
        snapshot.paste.alwaysPasteAsPlainText ? .plainText : .original
    }

    public var hasFullProductAccess: Bool {
        snapshot.entitlement.hasFullAccess()
    }

    public var isHistoryAccessLocked: Bool {
        guard snapshot.security.requiresBiometricUnlock else { return false }
        guard let historyUnlockedAt else { return true }
        return Date().timeIntervalSince(historyUnlockedAt) > snapshot.security.biometricGracePeriodSeconds
    }

    public var historyAccessStatusLine: String {
        guard snapshot.security.requiresBiometricUnlock else {
            return "History lock is off"
        }
        return isHistoryAccessLocked ? "History locked until Touch ID unlock" : "History unlocked"
    }

    @discardableResult
    public func unlockHistoryWithTouchID(reason: String = "Unlock PasteBuddy clipboard history") async -> Bool {
        do {
            let didAuthenticate = try await historyUnlockAuthenticator.authenticate(reason: reason)
            if didAuthenticate {
                historyUnlockedAt = Date()
                lastErrorMessage = nil
                selectedItemID = filteredItems.first?.id
                selectedItemIDs = selectedItemID.map { [$0] } ?? []
            }
            return didAuthenticate
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    public func lockHistory() {
        historyUnlockedAt = nil
        selectedItemID = nil
        selectedItemIDs = []
    }

    public func markHistoryUnlockedForTesting(at date: Date = Date()) {
        historyUnlockedAt = date
    }

    internal func configureDeferredRepositoryForTesting(databaseURL: URL) {
        clipboardRepository = nil
        repositorySyncActor = nil
        deferredRepositoryDatabaseURL = databaseURL
        repositoryDatabaseURLForStandardStorage = databaseURL
        deferredRepositoryInitializationTask = nil
        lastDeferredRepositoryInitializationWasOnMainThreadForTesting = nil
    }

    internal func primeCaptureHotPathIndexesForTesting() {
        rebuildDedupeIndex()
        rebuildCaptureHistoryState()
    }

    internal func resetCaptureHotPathInspectionCountForTesting() {
        captureHotPathItemInspectionCountForTesting = 0
    }

    internal func cancelPendingSaveForTesting() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        pendingSaveTaskID = nil
        clearPendingRepositoryPlan()
    }

    public func quickPasteItem(atOneBasedIndex index: Int, in scope: PasteScope? = nil) -> ClipboardItem? {
        guard (1...9).contains(index) else { return nil }
        let items = scope.map { filteredItems(for: $0) } ?? filteredItems
        let zeroBasedIndex = index - 1
        guard items.indices.contains(zeroBasedIndex) else { return nil }
        return items[zeroBasedIndex]
    }

    public func smartPinboard(for category: SmartPinboardCategory) -> Pinboard? {
        snapshot.pinboards.first { $0.name == category.pinboardName }
    }

    public func smartPinboardItemCount(for category: SmartPinboardCategory) -> Int {
        smartPinboardItemIDs(for: category).count
    }

    public func smartPinboardItems(for category: SmartPinboardCategory, in scope: PasteScope = .history) -> [ClipboardItem] {
        filteredItems(for: scope).filter(category.matches)
    }

    @discardableResult
    public func syncSmartPinboard(for category: SmartPinboardCategory) -> Pinboard {
        removeObsoleteSmartPinboards()
        let pinboards = upsertSmartPinboards(categories: [category], createMissing: true)
        save()
        return pinboards[0]
    }

    @discardableResult
    public func syncSmartPinboards() -> [Pinboard] {
        removeObsoleteSmartPinboards()
        let pinboards = upsertSmartPinboards(categories: SmartPinboardCategory.allCases, createMissing: true)
        save()
        return pinboards
    }

    public var isCapturePaused: Bool {
        snapshot.privacy.isCaptureCurrentlyPaused()
    }

    public var activeCapturePauseUntil: Date? {
        snapshot.privacy.activePauseUntil()
    }

    public var storageUsageBytes: Int {
        storageUsageReport.estimatedBytes
    }

    public var storageUsageReport: StorageUsageReport {
        let cacheKey = PasteBuddyReportCacheKey(dataRevision: dataRevision)
        if presentationCache.storageUsageReportKey == cacheKey,
           let report = presentationCache.storageUsageReport {
            return report
        }
        let pinnedItemIDs = userPinnedItemIDs()
        let pinnedItems = snapshot.items.filter { pinnedItemIDs.contains($0.id) }
        let unpinnedItems = snapshot.items.filter { !pinnedItemIDs.contains($0.id) }
        let pinnedBytes = pinnedItems.reduce(0) { $0 + Self.estimatedStorageBytes(for: $1) }
        let unpinnedBytes = unpinnedItems.reduce(0) { $0 + Self.estimatedStorageBytes(for: $1) }
        let report = StorageUsageReport(
            itemCount: snapshot.items.count,
            pinnedItemCount: pinnedItems.count,
            unpinnedItemCount: unpinnedItems.count,
            estimatedBytes: pinnedBytes + unpinnedBytes,
            pinnedEstimatedBytes: pinnedBytes,
            unpinnedEstimatedBytes: unpinnedBytes,
            maxStorageBytes: snapshot.storage.maxStorageBytes
        )
        presentationCache.storageUsageReportKey = cacheKey
        presentationCache.storageUsageReport = report
        return report
    }

    public func clearFilters() {
        contentTypeFilter = nil
        sourceAppFilter = nil
        deviceFilter = nil
        dateFilter = .any
    }

    public func clearFilter(_ kind: ClipboardFilterKind) {
        switch kind {
        case .contentType:
            contentTypeFilter = nil
        case .sourceApp:
            sourceAppFilter = nil
        case .device:
            deviceFilter = nil
        case .date:
            dateFilter = .any
        }
    }

    public func applyFilterSuggestion(_ suggestion: ClipboardFilterDescriptor) {
        switch suggestion.kind {
        case .contentType:
            contentTypeFilter = ClipboardContentType(rawValue: suggestion.value)
        case .sourceApp:
            sourceAppFilter = suggestion.value
        case .device:
            deviceFilter = suggestion.value
        case .date:
            dateFilter = ClipboardDateFilter(rawValue: suggestion.value) ?? .any
        }
        selectSingleItem(filteredItems.first?.id)
    }

    public func filterSuggestions(matching query: String, limit: Int = 8) -> [ClipboardFilterDescriptor] {
        let normalizedQuery = Self.normalizedSuggestionQuery(query)
        let allSuggestions = availableFilterSuggestions()
        let filteredSuggestions: [ClipboardFilterDescriptor]
        if normalizedQuery.isEmpty {
            filteredSuggestions = allSuggestions
        } else {
            filteredSuggestions = allSuggestions.filter {
                $0.title.lowercased().contains(normalizedQuery)
                    || $0.subtitle.lowercased().contains(normalizedQuery)
                    || $0.kind.displayName.lowercased().contains(normalizedQuery)
            }
        }
        return Array(filteredSuggestions.prefix(max(limit, 0)))
    }

    public func sourceAppSuggestions(matching query: String, limit: Int = 6) -> [String] {
        let normalizedQuery = Self.normalizedAppSuggestionQuery(query)
        guard !normalizedQuery.isEmpty else { return [] }

        let matches = availableSourceApps.compactMap { appName -> (name: String, rank: Int)? in
            let normalizedName = Self.normalizedAppMention(appName)
            guard !normalizedName.isEmpty else { return nil }
            if normalizedName == normalizedQuery {
                return (appName, 0)
            }
            if normalizedName.hasPrefix(normalizedQuery) {
                return (appName, 1)
            }
            if normalizedName.contains(normalizedQuery) {
                return (appName, 2)
            }
            return nil
        }

        return Array(matches
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank {
                    return lhs.rank < rhs.rank
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map(\.name)
            .prefix(max(limit, 0)))
    }

    public func applySourceAppSuggestion(_ appName: String) {
        sourceAppFilter = appName
        searchQuery = ""
        selectSingleItem(filteredItems.first?.id)
    }

    @discardableResult
    public func addCapturedItem(_ item: ClipboardItem, maxItems: Int? = nil) -> ClipboardItem {
        addCapturedItem(item, maxItems: maxItems, refreshSearchDocument: true)
    }

    /// Stores an item whose search document was built from its current payload.
    /// Use this for items constructed off MainActor; payload mutations must use
    /// `addCapturedItem`, which rebuilds the document defensively.
    @discardableResult
    public func addCapturedItemWithCurrentSearchDocument(
        _ item: ClipboardItem,
        maxItems: Int? = nil
    ) -> ClipboardItem {
        addCapturedItem(item, maxItems: maxItems, refreshSearchDocument: false)
    }

    private func addCapturedItem(
        _ item: ClipboardItem,
        maxItems: Int?,
        refreshSearchDocument: Bool
    ) -> ClipboardItem {
        let interval = PasteBuddyPerformanceSignposts.begin(
            .captureApply,
            itemCount: .single
        )
        defer {
            PasteBuddyPerformanceSignposts.end(
                interval,
                itemCount: .single,
                result: .succeeded
            )
        }
        let repositoryWasCurrent = canAppendCaptureMutationToRepositoryJournal()
        prepareCaptureHistoryState()
        let storedItem: ClipboardItem
        let repositoryPlacement: ClipboardRepositoryItemPlacement
        var previousItem: ClipboardItem?
        var preparedItem = item
        if refreshSearchDocument {
            preparedItem.refreshSearchDocument()
        }
        if dedupeIndexRevision != dataRevision {
            rebuildDedupeIndex()
        }
        let newDeduplicationKey = Self.deduplicationKey(for: preparedItem)
        if let existingID = dedupeIndex[newDeduplicationKey],
           let existingIndex = snapshot.items.firstIndex(where: { $0.id == existingID }) {
            previousItem = snapshot.items[existingIndex]
            let isMetadataReplay = isLinkPreviewMetadataReplay(preparedItem, existingIndex: existingIndex)
            if !isMetadataReplay {
                snapshot.items[existingIndex].updatedAt = Date()
            }
            adoptRicherLinkPreviewMetadata(from: preparedItem, at: existingIndex)
            snapshot.items[existingIndex].refreshSearchDocumentPreservingContentHash()
            if isMetadataReplay {
                storedItem = snapshot.items[existingIndex]
                repositoryPlacement = .preserve
            } else {
                snapshot.items.move(fromOffsets: IndexSet(integer: existingIndex), toOffset: 0)
                storedItem = snapshot.items[0]
                repositoryPlacement = .front
            }
        } else {
            snapshot.items.insert(preparedItem, at: 0)
            storedItem = preparedItem
            repositoryPlacement = .front
        }
        dedupeIndex[newDeduplicationKey] = storedItem.id
        updateCaptureHistoryState(replacing: previousItem, with: storedItem)
        if isPasteStackActive {
            appendToPasteStack(storedItem)
        }
        selectSingleItem(storedItem.id)
        let pruneResult = pruneCapturedHistory(
            maxItems: maxItems,
            frontMoveCount: repositoryPlacement == .front ? 1 : 0
        )
        let pinboardChanges = updateSmartPinboardsAfterCapture(
            storedItem: storedItem,
            previousItem: previousItem,
            placement: repositoryPlacement,
            deletedItems: pruneResult.deletedItems
        )
        dedupeIndexRevision = dataRevision
        captureHistoryState?.revision = dataRevision
        saveCaptureMutation(
            ClipboardRepositoryCaptureMutation(
                item: storedItem,
                placement: repositoryPlacement,
                deletedItemIDs: pruneResult.deletedItemIDs,
                upsertedPinboards: pinboardChanges.upserts,
                deletedPinboardIDs: pinboardChanges.deletedIDs,
                updatedPinboardMetadata: pinboardChanges.metadataUpdates,
                frontedPinboardItems: pinboardChanges.frontedItems
            ),
            repositoryWasCurrent: repositoryWasCurrent
        )
        return storedItem
    }

    @discardableResult
    public func addCapturedItems(
        _ items: [ClipboardItem],
        pinboardAssignments: [UUID: UUID] = [:],
        maxItems: Int? = nil
    ) -> [ClipboardItem] {
        addCapturedItems(
            items,
            pinboardAssignments: pinboardAssignments,
            maxItems: maxItems,
            refreshSearchDocuments: true
        )
    }

    @discardableResult
    func addCapturedItemsWithCurrentSearchDocuments(
        _ items: [ClipboardItem],
        pinboardAssignments: [UUID: UUID] = [:],
        maxItems: Int? = nil
    ) -> [ClipboardItem] {
        addCapturedItems(
            items,
            pinboardAssignments: pinboardAssignments,
            maxItems: maxItems,
            refreshSearchDocuments: false
        )
    }

    private func addCapturedItems(
        _ items: [ClipboardItem],
        pinboardAssignments: [UUID: UUID],
        maxItems: Int?,
        refreshSearchDocuments: Bool
    ) -> [ClipboardItem] {
        guard !items.isEmpty else { return [] }
        let itemCount = PasteBuddyPerformanceSignposts.ItemCountBucket(
            itemCount: items.count
        )
        let interval = PasteBuddyPerformanceSignposts.begin(
            .captureApply,
            itemCount: itemCount
        )
        defer {
            PasteBuddyPerformanceSignposts.end(
                interval,
                itemCount: itemCount,
                result: .succeeded
            )
        }
        let repositoryWasCurrent = canAppendCaptureMutationToRepositoryJournal()
        prepareCaptureHistoryState()
        if dedupeIndexRevision != dataRevision {
            rebuildDedupeIndex()
        }
        let pinboardsBeforeCapture = snapshot.pinboards
        var storedItems: [ClipboardItem] = []
        storedItems.reserveCapacity(items.count)
        var mutations: [ClipboardRepositoryCaptureMutation] = []
        mutations.reserveCapacity(items.count)
        var frontMoveCount = 0

        for item in items {
            var preparedItem = item
            if refreshSearchDocuments {
                preparedItem.refreshSearchDocument()
            }
            let deduplicationKey = Self.deduplicationKey(for: preparedItem)
            let storedItem: ClipboardItem
            let placement: ClipboardRepositoryItemPlacement
            var previousItem: ClipboardItem?
            if let existingID = dedupeIndex[deduplicationKey],
               let existingIndex = snapshot.items.firstIndex(where: { $0.id == existingID }) {
                previousItem = snapshot.items[existingIndex]
                let isMetadataReplay = isLinkPreviewMetadataReplay(preparedItem, existingIndex: existingIndex)
                if !isMetadataReplay {
                    snapshot.items[existingIndex].updatedAt = Date()
                }
                adoptRicherLinkPreviewMetadata(from: preparedItem, at: existingIndex)
                snapshot.items[existingIndex].refreshSearchDocumentPreservingContentHash()
                if isMetadataReplay {
                    storedItem = snapshot.items[existingIndex]
                    placement = .preserve
                } else {
                    snapshot.items.move(fromOffsets: IndexSet(integer: existingIndex), toOffset: 0)
                    storedItem = snapshot.items[0]
                    placement = .front
                }
            } else {
                snapshot.items.insert(preparedItem, at: 0)
                storedItem = preparedItem
                placement = .front
            }
            dedupeIndex[deduplicationKey] = storedItem.id
            updateCaptureHistoryState(replacing: previousItem, with: storedItem)
            if isPasteStackActive {
                appendToPasteStack(storedItem)
            }
            if placement == .front {
                frontMoveCount += 1
            }
            storedItems.append(storedItem)
            mutations.append(ClipboardRepositoryCaptureMutation(
                item: storedItem,
                placement: placement
            ))
        }

        var assignedItemIDsByPinboard: [UUID: [UUID]] = [:]
        for (inputItem, storedItem) in zip(items, storedItems) {
            guard let pinboardID = pinboardAssignments[inputItem.id] else { continue }
            if assignedItemIDsByPinboard[pinboardID]?.contains(storedItem.id) != true {
                assignedItemIDsByPinboard[pinboardID, default: []].append(storedItem.id)
            }
        }
        let now = Date()
        for (pinboardID, assignedItemIDs) in assignedItemIDsByPinboard {
            guard let pinboardIndex = snapshot.pinboards.firstIndex(where: { $0.id == pinboardID }),
                  !isSmartPinboard(at: pinboardIndex) else {
                continue
            }
            let assignedIDSet = Set(assignedItemIDs)
            snapshot.pinboards[pinboardIndex].itemIDs.removeAll { assignedIDSet.contains($0) }
            // Match sequential capture semantics: each later capture is placed in
            // front of the previous one in both History and its assigned Pinboard.
            snapshot.pinboards[pinboardIndex].itemIDs.insert(contentsOf: assignedItemIDs.reversed(), at: 0)
            snapshot.pinboards[pinboardIndex].updatedAt = now
            captureHistoryState?.pinnedItemIDs.formUnion(assignedIDSet)
        }

        selectSingleItem(storedItems.last?.id)
        let pruneResult = pruneCapturedHistory(
            maxItems: maxItems,
            frontMoveCount: frontMoveCount
        )
        refreshExistingSmartPinboards(now: now)
        let pinboardChanges = Self.repositoryPinboardChanges(
            before: pinboardsBeforeCapture,
            after: snapshot.pinboards
        )
        let lastMutationIndex = mutations.index(before: mutations.endIndex)
        mutations[lastMutationIndex].deletedItemIDs = pruneResult.deletedItemIDs
        mutations[lastMutationIndex].upsertedPinboards = pinboardChanges.upserts
        mutations[lastMutationIndex].deletedPinboardIDs = pinboardChanges.deletedIDs
        dedupeIndexRevision = dataRevision
        captureHistoryState?.revision = dataRevision
        saveCaptureMutations(mutations, repositoryWasCurrent: repositoryWasCurrent)
        return storedItems
    }

    @discardableResult
    public func addSyncedItem(_ item: ClipboardItem, maxItems: Int? = nil) -> ClipboardItem? {
        let decision = snapshot.privacy.captureDecision(
            for: item,
            sourceApplicationName: item.sourceAppName,
            sourceBundleIdentifier: item.sourceBundleIdentifier,
            includePause: true
        )
        guard decision.isAllowed else { return nil }
        return addCapturedItem(item, maxItems: maxItems)
    }

    /// Duplicate captures of the same link arrive both locally (re-copy) and
    /// from sync peers re-sending an enriched copy. Deduplication keeps the
    /// existing item, so richer link metadata must be merged in explicitly —
    /// and only ever upgraded, never cleared by a barer duplicate.
    /// `deduplicationHash` ignores every field touched here, so the dedupe
    /// index stays valid without a rebuild.
    private func adoptRicherLinkPreviewMetadata(from incoming: ClipboardItem, at index: Int) {
        guard incoming.presentationContentType == .url,
              snapshot.items[index].presentationContentType == .url,
              !snapshot.items[index].payload.hasImageAsset,
              incoming.payload.hasImageAsset else {
            return
        }
        snapshot.items[index].title = incoming.title
        snapshot.items[index].payload.imageData = incoming.payload.imageData
        snapshot.items[index].payload.imageByteCount = incoming.payload.imageByteCount
        snapshot.items[index].payload.imageAssetID = incoming.payload.imageAssetID
    }

    private func isLinkPreviewMetadataReplay(_ incoming: ClipboardItem, existingIndex: Int) -> Bool {
        guard incoming.presentationContentType == .url,
              snapshot.items[existingIndex].presentationContentType == .url,
              incoming.createdAt == snapshot.items[existingIndex].createdAt,
              !snapshot.items[existingIndex].payload.hasImageAsset,
              incoming.payload.hasImageAsset else {
            return false
        }
        return true
    }

    public func updateOCRText(_ text: String, for itemID: UUID) {
        guard !isPersistenceWriteBlocked,
              let index = snapshot.items.firstIndex(where: { $0.id == itemID }) else { return }
        snapshot.items[index].payload.ocrText = text
        snapshot.items[index].ocrState = .completed(Date())
        snapshot.items[index].refreshSearchDocumentPreservingContentHash()
        refreshExistingSmartPinboards()
        save()
    }

    public func markOCRPending(for itemID: UUID) {
        guard !isPersistenceWriteBlocked,
              let index = snapshot.items.firstIndex(where: { $0.id == itemID }) else { return }
        snapshot.items[index].payload.ocrText = nil
        snapshot.items[index].ocrState = .pending(Date())
        snapshot.items[index].refreshSearchDocumentPreservingContentHash()
        refreshExistingSmartPinboards()
        save()
    }

    public func markOCRFailed(_ message: String, for itemID: UUID) {
        guard !isPersistenceWriteBlocked,
              let index = snapshot.items.firstIndex(where: { $0.id == itemID }) else { return }
        snapshot.items[index].ocrState = .failed(Date(), message)
        snapshot.items[index].refreshSearchDocumentPreservingContentHash()
        refreshExistingSmartPinboards()
        save()
    }

    #if os(macOS)
    public func enrichLinkPreviewMetadataIfNeeded(for item: ClipboardItem) async {
        guard !isPersistenceWriteBlocked,
              snapshot.privacy.captureImages,
              item.presentationContentType == .url,
              !item.payload.hasImageAsset,
              let urlString = item.payload.presentationURLString,
              !linkPreviewMetadataRequests.contains(item.id) else {
            return
        }

        linkPreviewMetadataRequests.insert(item.id)
        let interval = PasteBuddyPerformanceSignposts.begin(
            .linkEnrichment,
            itemCount: .single
        )
        var resultCode = PasteBuddyPerformanceSignposts.ResultCode.noChange
        defer {
            linkPreviewMetadataRequests.remove(item.id)
            PasteBuddyPerformanceSignposts.end(
                interval,
                itemCount: .single,
                result: resultCode
            )
        }

        let metadata = await ClipboardLinkMetadataFetcher.fetch(for: urlString)
        guard !isPersistenceWriteBlocked else {
            resultCode = .blocked
            return
        }
        guard let metadata,
              metadata.title != nil || metadata.imageData != nil,
              let index = snapshot.items.firstIndex(where: { $0.id == item.id }),
              !snapshot.items[index].payload.hasImageAsset else {
            return
        }

        if let title = metadata.title {
            snapshot.items[index].title = title
        }
        var didAdoptImage = false
        if let imageData = metadata.imageData {
            snapshot.items[index].payload.imageData = imageData
            snapshot.items[index].payload.imageByteCount = imageData.count
            didAdoptImage = true
        }
        snapshot.items[index].refreshSearchDocumentPreservingContentHash()
        syncPasteStackItem(snapshot.items[index])
        refreshExistingSmartPinboards()
        save()
        resultCode = .succeeded
        if didAdoptImage {
            onLinkPreviewMetadataEnriched?(snapshot.items[index])
        }
    }
    #endif

    @discardableResult
    public func createPinboard(named name: String = "New Pinboard", colorHex: String = "#7C9A92") -> Pinboard {
        let pinboard = Pinboard(
            name: Self.userPinboardName(for: name, fallback: "New Pinboard"),
            colorHex: colorHex
        )
        snapshot.pinboards.append(pinboard)
        selectedScope = .pinboard(pinboard.id)
        snapshot.general.collectionOrder = collectionOrder
        save()
        return pinboard
    }

    public func deletePinboard(_ id: UUID) {
        snapshot.pinboards.removeAll { $0.id == id }
        if selectedScope == .pinboard(id) {
            selectedScope = .history
        }
        snapshot.general.collectionOrder = collectionOrder
        save()
    }

    public func renamePinboard(_ id: UUID, to name: String) {
        guard let pinboardIndex = snapshot.pinboards.firstIndex(where: { $0.id == id }) else { return }
        guard !isSmartPinboard(at: pinboardIndex) else {
            refreshExistingSmartPinboards()
            save()
            return
        }
        snapshot.pinboards[pinboardIndex].name = Self.userPinboardName(for: name, fallback: snapshot.pinboards[pinboardIndex].name)
        snapshot.pinboards[pinboardIndex].updatedAt = Date()
        save()
    }

    public func updatePinboardColor(_ id: UUID, to colorHex: String) {
        guard let pinboardIndex = snapshot.pinboards.firstIndex(where: { $0.id == id }) else { return }
        guard !isSmartPinboard(at: pinboardIndex) else {
            refreshExistingSmartPinboards()
            save()
            return
        }
        let normalized = Self.normalizedColorHex(colorHex)
        guard !normalized.isEmpty else { return }
        snapshot.pinboards[pinboardIndex].colorHex = normalized
        snapshot.pinboards[pinboardIndex].updatedAt = Date()
        save()
    }

    public func updatePinboardAppearance(
        _ id: UUID,
        name: String,
        colorHex: String,
        systemImageName: String?
    ) {
        guard let pinboardIndex = snapshot.pinboards.firstIndex(where: { $0.id == id }) else { return }
        guard !isSmartPinboard(at: pinboardIndex) else {
            refreshExistingSmartPinboards()
            save()
            return
        }
        let normalizedIcon = systemImageName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedIcon, !Pinboard.customizableSystemImageNames.contains(normalizedIcon) {
            return
        }
        let normalizedColor = Self.normalizedColorHex(colorHex)
        guard !normalizedColor.isEmpty else { return }
        let normalizedName = Self.userPinboardName(
            for: name,
            fallback: snapshot.pinboards[pinboardIndex].name
        )
        guard snapshot.pinboards[pinboardIndex].name != normalizedName
            || snapshot.pinboards[pinboardIndex].colorHex != normalizedColor
            || snapshot.pinboards[pinboardIndex].systemImageName != normalizedIcon else {
            return
        }
        snapshot.pinboards[pinboardIndex].name = normalizedName
        snapshot.pinboards[pinboardIndex].colorHex = normalizedColor
        snapshot.pinboards[pinboardIndex].systemImageName = normalizedIcon
        snapshot.pinboards[pinboardIndex].updatedAt = Date()
        save()
    }

    public func movePinboards(fromOffsets offsets: IndexSet, toOffset offset: Int) {
        snapshot.pinboards.move(fromOffsets: offsets, toOffset: offset)
        let now = Date()
        for index in snapshot.pinboards.indices {
            snapshot.pinboards[index].updatedAt = now
        }
        save()
    }

    public func moveUserPinboards(fromOffsets offsets: IndexSet, toOffset offset: Int) {
        var reorderedUserIDs = userPinboards.map(\.id)
        guard !reorderedUserIDs.isEmpty else { return }
        reorderedUserIDs.move(fromOffsets: offsets, toOffset: offset)

        let pinboardsByID = Dictionary(uniqueKeysWithValues: snapshot.pinboards.map { ($0.id, $0) })
        var reorderedUsers = reorderedUserIDs.compactMap { pinboardsByID[$0] }
        guard reorderedUsers.count == reorderedUserIDs.count else { return }

        let now = Date()
        for index in snapshot.pinboards.indices where !isSmartPinboard(at: index) {
            guard !reorderedUsers.isEmpty else { break }
            var pinboard = reorderedUsers.removeFirst()
            pinboard.updatedAt = now
            snapshot.pinboards[index] = pinboard
        }
        save()
    }

    public func pinSelectedItem(to pinboardID: UUID) {
        guard let selectedItemID else { return }
        pinItem(selectedItemID, to: pinboardID)
    }

    public func pinItem(_ itemID: UUID, to pinboardID: UUID) {
        pinItems([itemID], to: pinboardID)
    }

    public func pinItems(_ itemIDs: [UUID], to pinboardID: UUID) {
        guard let pinboardIndex = snapshot.pinboards.firstIndex(where: { $0.id == pinboardID }) else { return }
        if isSmartPinboard(at: pinboardIndex) {
            refreshExistingSmartPinboards()
            save()
            return
        }
        let storedItemIDs = Set(snapshot.items.map(\.id))
        var seenItemIDs = Set<UUID>()
        var pinnedItemIDs: [UUID] = []
        for itemID in itemIDs where storedItemIDs.contains(itemID) {
            if seenItemIDs.insert(itemID).inserted {
                pinnedItemIDs.append(itemID)
            }
        }
        guard !pinnedItemIDs.isEmpty else { return }

        snapshot.pinboards[pinboardIndex].itemIDs.removeAll { seenItemIDs.contains($0) }
        snapshot.pinboards[pinboardIndex].itemIDs.insert(contentsOf: pinnedItemIDs, at: 0)
        snapshot.pinboards[pinboardIndex].updatedAt = Date()
        save()
    }

    public func removeItem(_ itemID: UUID, fromPinboard pinboardID: UUID) {
        guard let pinboardIndex = snapshot.pinboards.firstIndex(where: { $0.id == pinboardID }) else { return }
        guard !isSmartPinboard(at: pinboardIndex) else {
            refreshExistingSmartPinboards()
            save()
            return
        }
        let originalCount = snapshot.pinboards[pinboardIndex].itemIDs.count
        snapshot.pinboards[pinboardIndex].itemIDs.removeAll { $0 == itemID }
        guard snapshot.pinboards[pinboardIndex].itemIDs.count != originalCount else { return }
        snapshot.pinboards[pinboardIndex].updatedAt = Date()
        if selectedScope == .pinboard(pinboardID), selectedItemID == itemID {
            selectSingleItem(filteredItems.first?.id)
        }
        save()
    }

    public func movePinboardItem(_ itemID: UUID, from sourcePinboardID: UUID, to destinationPinboardID: UUID) {
        guard snapshot.items.contains(where: { $0.id == itemID }) else { return }
        guard let sourceIndex = snapshot.pinboards.firstIndex(where: { $0.id == sourcePinboardID }) else { return }
        guard let destinationIndex = snapshot.pinboards.firstIndex(where: { $0.id == destinationPinboardID }) else { return }
        guard !isSmartPinboard(at: sourceIndex), !isSmartPinboard(at: destinationIndex) else {
            refreshExistingSmartPinboards()
            save()
            return
        }

        snapshot.pinboards[sourceIndex].itemIDs.removeAll { $0 == itemID }
        if !snapshot.pinboards[destinationIndex].itemIDs.contains(itemID) {
            snapshot.pinboards[destinationIndex].itemIDs.insert(itemID, at: 0)
        }
        let now = Date()
        snapshot.pinboards[sourceIndex].updatedAt = now
        snapshot.pinboards[destinationIndex].updatedAt = now
        if selectedScope == .pinboard(sourcePinboardID), selectedItemID == itemID {
            selectSingleItem(filteredItems.first?.id)
        }
        save()
    }

    public func moveItems(inPinboard pinboardID: UUID, fromOffsets offsets: IndexSet, toOffset offset: Int) {
        guard let pinboardIndex = snapshot.pinboards.firstIndex(where: { $0.id == pinboardID }) else { return }
        guard !isSmartPinboard(at: pinboardIndex) else {
            refreshExistingSmartPinboards()
            save()
            return
        }
        snapshot.pinboards[pinboardIndex].itemIDs.move(fromOffsets: offsets, toOffset: offset)
        snapshot.pinboards[pinboardIndex].updatedAt = Date()
        save()
    }

    public func removeItem(_ id: UUID) {
        removeItems([id])
    }

    public func removeSelectedItems() {
        removeItems(selectedItemsInDisplayOrder.map(\.id))
    }

    public func removeItems(_ ids: [UUID]) {
        var seen: Set<UUID> = []
        let orderedIDs = ids.filter { id in
            guard !seen.contains(id) else { return false }
            seen.insert(id)
            return true
        }
        let requestedIDs = Set(orderedIDs)
        let itemByID = cachedItemByID()
        var userPinboardIDsByItemID: [UUID: [UUID]] = [:]
        for pinboard in snapshot.pinboards where !SmartPinboardCategory.isSmartPinboardName(pinboard.name) {
            for itemID in pinboard.itemIDs where requestedIDs.contains(itemID) {
                userPinboardIDsByItemID[itemID, default: []].append(pinboard.id)
            }
        }
        let deletedItems = orderedIDs.compactMap { id -> DeletedClipboardItem? in
            guard let item = itemByID[id] else { return nil }
            return DeletedClipboardItem(item: item, pinboardIDs: userPinboardIDsByItemID[id] ?? [])
        }
        guard !deletedItems.isEmpty else { return }

        let deletedIDs = Set(deletedItems.map(\.item.id))
        lastDeletedItem = deletedItems.first
        lastDeletedItems = deletedItems
        snapshot.items.removeAll { deletedIDs.contains($0.id) }
        pasteStackItems.removeAll { deletedIDs.contains($0.id) }
        for index in snapshot.pinboards.indices {
            snapshot.pinboards[index].itemIDs.removeAll { deletedIDs.contains($0) }
        }
        selectedItemIDs.subtract(deletedIDs)
        if selectedItemID.map(deletedIDs.contains) == true {
            selectSingleItem(filteredItems.first?.id)
        }
        refreshExistingSmartPinboards()
        save()
    }

    public func undoLastDeletion() {
        let deletedItems = lastDeletedItems.isEmpty ? lastDeletedItem.map { [$0] } ?? [] : lastDeletedItems
        guard !deletedItems.isEmpty else { return }

        for deletedItem in deletedItems.reversed() {
            if !snapshot.items.contains(where: { $0.id == deletedItem.item.id }) {
                snapshot.items.insert(deletedItem.item, at: 0)
            }
            for pinboardID in deletedItem.pinboardIDs {
                guard let index = snapshot.pinboards.firstIndex(where: { $0.id == pinboardID }) else { continue }
                if !snapshot.pinboards[index].itemIDs.contains(deletedItem.item.id) {
                    snapshot.pinboards[index].itemIDs.insert(deletedItem.item.id, at: 0)
                    snapshot.pinboards[index].updatedAt = Date()
                }
            }
        }

        let restoredSelectionID = deletedItems.first?.item.id
        self.lastDeletedItem = nil
        self.lastDeletedItems = []
        selectSingleItem(restoredSelectionID)
        refreshExistingSmartPinboards()
        save()
    }

    public func recordDirectPasteResult(_ result: DirectPasteResult) {
        lastDirectPasteResult = result
    }

    public func clearDirectPasteResult() {
        lastDirectPasteResult = nil
    }

    public func requestSettingsDestination(_ destination: MacSettingsDestination) {
        requestedSettingsDestination = destination
    }

    public func clearRequestedSettingsDestination() {
        requestedSettingsDestination = nil
    }

    public func toggleCapturePaused() {
        if isCapturePaused {
            resumeCapture()
        } else {
            pauseCaptureIndefinitely()
        }
    }

    public func pauseCaptureIndefinitely() {
        snapshot.privacy.isCapturePaused = true
        snapshot.privacy.capturePauseUntil = nil
        saveAndFlush()
    }

    public func pauseCapture(for interval: TimeInterval, now: Date = Date()) {
        snapshot.privacy.isCapturePaused = false
        snapshot.privacy.capturePauseUntil = now.addingTimeInterval(max(0, interval))
        saveAndFlush()
    }

    public func resumeCapture() {
        snapshot.privacy.isCapturePaused = false
        snapshot.privacy.capturePauseUntil = nil
        saveAndFlush()
    }

    public func toggleOCR() {
        snapshot.privacy.runLocalOCRAfterImageCapture.toggle()
        saveAndFlush()
    }

    public func toggleTextCapture() {
        snapshot.privacy.captureText.toggle()
        saveAndFlush()
    }

    public func toggleURLCapture() {
        snapshot.privacy.captureURLs.toggle()
        saveAndFlush()
    }

    public func toggleFileCapture() {
        snapshot.privacy.captureFiles.toggle()
        saveAndFlush()
    }

    public func toggleImageCapture() {
        snapshot.privacy.captureImages.toggle()
        saveAndFlush()
    }

    public func toggleSensitiveTextBlocking() {
        snapshot.privacy.blockLikelySensitiveText.toggle()
        saveAndFlush()
    }

    public func excludeCurrentApplication(named appName: String, bundleIdentifier: String? = nil) {
        excludeApplication(named: appName, bundleIdentifier: bundleIdentifier)
    }

    public func excludeApplication(named appName: String, bundleIdentifier: String? = nil) {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = false
        if !trimmed.isEmpty {
            changed = snapshot.privacy.excludedApplicationNames.insert(trimmed).inserted || changed
        }
        if let trimmedBundleIdentifier, !trimmedBundleIdentifier.isEmpty {
            changed = snapshot.privacy.excludedBundleIdentifiers.insert(trimmedBundleIdentifier).inserted || changed
        }
        if changed {
            saveAndFlush()
        }
    }

    public func removeExcludedApplication(_ appName: String) {
        snapshot.privacy.excludedApplicationNames.remove(appName)
        saveAndFlush()
    }

    public func removeExcludedBundleIdentifier(_ bundleIdentifier: String) {
        snapshot.privacy.excludedBundleIdentifiers.remove(bundleIdentifier)
        saveAndFlush()
    }

    @discardableResult
    public func addCaptureRule(
        name: String? = nil,
        condition: CaptureRuleCondition,
        pattern: String,
        contentTypes: Set<ClipboardContentType> = []
    ) -> CaptureRule? {
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPattern.isEmpty else { return nil }
        let rule = CaptureRule(
            name: name,
            condition: condition,
            pattern: trimmedPattern,
            contentTypes: contentTypes
        )
        snapshot.privacy.customCaptureRules.append(rule)
        saveAndFlush()
        return rule
    }

    public func updateCaptureRule(
        _ id: UUID,
        name: String? = nil,
        condition: CaptureRuleCondition? = nil,
        pattern: String? = nil,
        contentTypes: Set<ClipboardContentType>? = nil
    ) {
        guard let index = snapshot.privacy.customCaptureRules.firstIndex(where: { $0.id == id }) else { return }
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            snapshot.privacy.customCaptureRules[index].name = trimmed.isEmpty
                ? snapshot.privacy.customCaptureRules[index].condition.displayName
                : trimmed
        }
        if let condition {
            snapshot.privacy.customCaptureRules[index].condition = condition
        }
        if let pattern {
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            snapshot.privacy.customCaptureRules[index].pattern = trimmed
        }
        if let contentTypes {
            snapshot.privacy.customCaptureRules[index].contentTypes = contentTypes
        }
        snapshot.privacy.customCaptureRules[index].updatedAt = Date()
        saveAndFlush()
    }

    public func setCaptureRule(_ id: UUID, enabled isEnabled: Bool) {
        guard let index = snapshot.privacy.customCaptureRules.firstIndex(where: { $0.id == id }) else { return }
        snapshot.privacy.customCaptureRules[index].isEnabled = isEnabled
        snapshot.privacy.customCaptureRules[index].updatedAt = Date()
        saveAndFlush()
    }

    public func removeCaptureRule(_ id: UUID) {
        snapshot.privacy.customCaptureRules.removeAll { $0.id == id }
        saveAndFlush()
    }

    public func setAlwaysPasteAsPlainText(_ isEnabled: Bool) {
        snapshot.paste.alwaysPasteAsPlainText = isEnabled
        save()
    }

    public func setLaunchAtLoginEnabled(_ isEnabled: Bool, applySystemRegistration: Bool = true) {
        if applySystemRegistration {
            do {
                try LaunchAtLoginService.setEnabled(isEnabled)
            } catch {
                lastErrorMessage = error.localizedDescription
                return
            }
        }

        snapshot.general.launchAtLoginEnabled = isEnabled
        save()
    }

    public func setIOSPastePermissionState(_ state: IOSPastePermissionState, guidanceShownAt date: Date? = nil) {
        snapshot.mobile.pastePermissionState = state
        if let date {
            snapshot.mobile.lastPermissionGuidanceAt = date
        }
        save()
    }

    public func setKeyboardExtensionEnabled(_ isEnabled: Bool, fullAccess: Bool? = nil) {
        snapshot.mobile.isKeyboardExtensionEnabled = isEnabled
        if let fullAccess {
            snapshot.mobile.hasKeyboardFullAccess = fullAccess
        }
        if !isEnabled {
            snapshot.mobile.hasKeyboardFullAccess = false
        }
        save()
    }

    public func setShareExtensionEnabled(_ isEnabled: Bool) {
        snapshot.mobile.isShareExtensionEnabled = isEnabled
        save()
    }

    public func setActionExtensionEnabled(_ isEnabled: Bool) {
        snapshot.mobile.isActionExtensionEnabled = isEnabled
        save()
    }

    public func setPreferredMobileSharePinboard(_ pinboardID: UUID?) {
        guard let pinboardID else {
            snapshot.mobile.preferredSharePinboardID = nil
            save()
            return
        }
        guard snapshot.pinboards.contains(where: { $0.id == pinboardID }) else { return }
        snapshot.mobile.preferredSharePinboardID = pinboardID
        save()
    }

    public func startFreeTrial(days: Int = 14, now: Date = Date()) {
        let trialLength = max(days, 1)
        snapshot.entitlement = EntitlementConfiguration(
            plan: .trial,
            status: .trialing,
            trialStartedAt: now,
            trialEndsAt: Calendar.current.date(byAdding: .day, value: trialLength, to: now) ?? now.addingTimeInterval(TimeInterval(trialLength * 24 * 60 * 60)),
            unlocksAllDevicesForAccount: true,
            restoreState: snapshot.entitlement.restoreState
        )
        save()
    }

    public func cancelFreeTrial(now: Date = Date()) {
        guard snapshot.entitlement.plan == .trial else { return }
        snapshot.entitlement.status = .canceled
        snapshot.entitlement.trialCanceledAt = now
        save()
    }

    public func activatePersonalPlan(
        _ plan: ProductAccessPlan,
        purchasedAt: Date = Date(),
        currentPeriodEndsAt: Date? = nil,
        expiresAt: Date? = nil,
        familySharingEnabled: Bool = false
    ) {
        guard plan.isPersonalPaidPlan else {
            lastErrorMessage = "Personal purchases require monthly, annual, lifetime, or family plan."
            return
        }

        let resolvedFamilySharing = familySharingEnabled || plan == .family
        snapshot.entitlement = EntitlementConfiguration(
            plan: plan,
            status: .active,
            purchasedAt: purchasedAt,
            currentPeriodEndsAt: currentPeriodEndsAt,
            expiresAt: expiresAt ?? currentPeriodEndsAt,
            isFamilySharingEnabled: resolvedFamilySharing,
            unlocksAllDevicesForAccount: true,
            restoreState: snapshot.entitlement.restoreState
        )
        lastErrorMessage = nil
        save()
    }

    public func markEntitlementExpired(at date: Date = Date()) {
        snapshot.entitlement.status = .expired
        snapshot.entitlement.expiresAt = date
        save()
    }

    public func markRestorePurchasesStarted(at date: Date = Date()) {
        snapshot.entitlement.restoreState = .inProgress(date)
        save()
    }

    public func markRestorePurchasesRestored(at date: Date = Date()) {
        snapshot.entitlement.restoreState = .restored(date)
        if snapshot.entitlement.plan == .free {
            snapshot.entitlement.unlocksAllDevicesForAccount = true
        }
        save()
    }

    public func markRestorePurchasesFailed(_ message: String, at date: Date = Date()) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        snapshot.entitlement.restoreState = .failed(date, trimmed.isEmpty ? "Restore did not return an active entitlement." : trimmed)
        save()
    }

    @discardableResult
    public func purchasePersonalPlan(
        _ plan: ProductAccessPlan,
        using provider: any StoreEntitlementProviding,
        productConfiguration: StoreProductConfiguration = StoreProductConfiguration()
    ) async -> StorePurchaseOutcome? {
        do {
            let outcome = try await provider.purchase(
                plan: plan,
                configuration: productConfiguration
            )
            switch outcome {
            case .purchased(let entitlement):
                snapshot.entitlement = entitlement
                lastErrorMessage = nil
                save()
            case .pending:
                lastErrorMessage = "Purchase is pending App Store approval."
            case .userCancelled:
                lastErrorMessage = nil
            }
            return outcome
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func restorePurchases(
        using provider: any StoreEntitlementProviding,
        productConfiguration: StoreProductConfiguration = StoreProductConfiguration(),
        at date: Date = Date()
    ) async -> EntitlementConfiguration? {
        markRestorePurchasesStarted(at: date)
        do {
            guard let entitlement = try await provider.restorePurchases(
                configuration: productConfiguration,
                restoredAt: date
            ) else {
                markRestorePurchasesFailed("Restore did not return an active entitlement.", at: date)
                lastErrorMessage = "Restore did not return an active entitlement."
                return nil
            }

            snapshot.entitlement = entitlement
            snapshot.entitlement.restoreState = .restored(date)
            lastErrorMessage = nil
            save()
            return snapshot.entitlement
        } catch {
            markRestorePurchasesFailed(error.localizedDescription, at: date)
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    public func applyStoreEntitlementUpdate(_ update: StoreEntitlementUpdate) {
        snapshot.entitlement = update.entitlement
        switch update.entitlement.status {
        case .active:
            lastErrorMessage = nil
        case .revoked:
            lastErrorMessage = "App Store entitlement was revoked."
        case .expired:
            lastErrorMessage = "App Store entitlement expired."
        case .billingRetry:
            lastErrorMessage = "App Store billing retry is required."
        case .inactive, .trialing, .canceled:
            lastErrorMessage = nil
        }
        save()
    }

    public func recordStoreTransactionUpdateError(_ error: any Error) {
        lastErrorMessage = error.localizedDescription
    }

    public func configureTeamPlan(
        teamName: String,
        seatCount: Int,
        assignedSeatCount: Int,
        pricePerSeatCents: Int,
        billingCurrencyCode: String = "USD",
        singleInvoiceEnabled: Bool = true,
        managedDistributionEnabled: Bool = true,
        adminEmailAddress: String? = nil,
        now: Date = Date()
    ) {
        let trimmedName = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        let team = TeamPlanConfiguration(
            teamName: trimmedName.isEmpty ? "Team Workspace" : trimmedName,
            seatCount: seatCount,
            assignedSeatCount: assignedSeatCount,
            pricePerSeatCents: pricePerSeatCents,
            billingCurrencyCode: billingCurrencyCode,
            singleInvoiceEnabled: singleInvoiceEnabled,
            managedDistributionEnabled: managedDistributionEnabled,
            adminEmailAddress: adminEmailAddress,
            updatedAt: now
        )

        snapshot.entitlement = EntitlementConfiguration(
            plan: .team,
            status: .active,
            purchasedAt: snapshot.entitlement.purchasedAt ?? now,
            isFamilySharingEnabled: false,
            unlocksAllDevicesForAccount: true,
            restoreState: snapshot.entitlement.restoreState,
            team: team
        )
        save()
    }

    public func updateTeamSeatAssignment(_ assignedSeatCount: Int, now: Date = Date()) {
        guard var team = snapshot.entitlement.team else { return }
        team.assignedSeatCount = TeamPlanConfiguration.clampAssignedSeats(
            assignedSeatCount,
            seatCount: team.seatCount
        )
        team.updatedAt = now
        snapshot.entitlement.team = team
        save()
    }

    public func setQuickPasteShortcutsEnabled(_ isEnabled: Bool) {
        snapshot.shortcuts.isQuickPasteEnabled = isEnabled
        save()
    }

    public func setShortcutBinding(
        _ action: ShortcutAction,
        key: String?,
        modifiers: [ShortcutModifier]
    ) {
        snapshot.shortcuts.setBinding(
            ShortcutBinding(key: key, modifiers: modifiers),
            for: action
        )
        save()
    }

    public func clearShortcutBinding(_ action: ShortcutAction) {
        snapshot.shortcuts.setBinding(
            ShortcutBinding(key: nil, modifiers: snapshot.shortcuts.binding(for: action).modifiers),
            for: action
        )
        save()
    }

    public func setQuickPasteModifiers(_ modifiers: [ShortcutModifier], plainText: Bool = false) {
        if plainText {
            snapshot.shortcuts.plainTextQuickPasteModifiers = ShortcutBinding.normalizedModifiers(modifiers)
        } else {
            snapshot.shortcuts.quickPasteModifiers = ShortcutBinding.normalizedModifiers(modifiers)
        }
        save()
    }

    public func resetShortcutConfiguration() {
        snapshot.shortcuts = ShortcutConfiguration()
        save()
    }

    public func setMCPServerEnabled(_ isEnabled: Bool) {
        snapshot.mcp.isServerEnabled = isEnabled
        if isEnabled {
            snapshot.mcp.enabledTools = MCPToolName.defaultEnabledTools
        }
        save()
    }

    public func setMCPTool(_ tool: MCPToolName, enabled isEnabled: Bool) {
        if isEnabled {
            snapshot.mcp.enabledTools.insert(tool)
        } else {
            snapshot.mcp.enabledTools.remove(tool)
        }
        save()
    }

    public func recordMCPAccess(_ entry: MCPAccessLogEntry) {
        snapshot.mcp.accessLog.insert(entry, at: 0)
        if snapshot.mcp.accessLog.count > MCPConfiguration.maxAccessLogEntries {
            snapshot.mcp.accessLog = Array(snapshot.mcp.accessLog.prefix(MCPConfiguration.maxAccessLogEntries))
        }
        save()
    }

    public func clearMCPAccessLog() {
        snapshot.mcp.accessLog.removeAll()
        save()
    }

    public func revokeMCPAccess(at date: Date = Date()) {
        snapshot.mcp.isServerEnabled = false
        snapshot.mcp.enabledTools = []
        snapshot.mcp.lastAccessRevokedAt = date
        save()
    }

    public func updateMaxHistoryItems(_ value: Int) {
        snapshot.storage.maxHistoryItems = StorageConfiguration.clampMaxHistoryItems(value)
        pruneHistory()
        save()
    }

    public func updateRetentionDays(_ value: Int) {
        snapshot.storage.retentionDays = StorageConfiguration.clampRetentionDays(value)
        pruneHistory()
        save()
    }

    public func updateMaxStorageBytes(_ value: Int) {
        snapshot.storage.maxStorageBytes = StorageConfiguration.clampMaxStorageBytes(value)
        pruneHistory()
        save()
    }

    public func setHistoryEncryptionEnabled(_ isEnabled: Bool) async {
        guard !isHistoryStorageMigrationInProgress else { return }
        if isEnabled,
           snapshot.security.storageMode == .encrypted,
           clipboardRepository == nil,
           deferredRepositoryDatabaseURL == nil {
            return
        }
        isHistoryStorageMigrationInProgress = true
        defer {
            isHistoryStorageMigrationInProgress = false
        }

        let inFlightSave = pendingSaveTask
        pendingSaveTask = nil
        pendingSaveTaskID = nil
        inFlightSave?.cancel()
        await inFlightSave?.value

        guard isEnabled else {
            snapshot.security.storageMode = .standard
            do {
                if clipboardRepository == nil,
                   let databaseURL = repositoryDatabaseURLForStandardStorage {
                    deferredRepositoryDatabaseURL = databaseURL
                    try await initializeDeferredRepositoryIfNeeded()
                }
                try await persistStandardRepositoryAndSnapshotUntilStable()
                if repositorySyncActor != nil || clipboardRepository != nil {
                    try diskStore.installRevokedTombstone()
                    try authorityStore.commitStable(.sqlite)
                } else {
                    try authorityStore.clear()
                }
                isPersistenceWriteBlocked = false
                lastErrorMessage = nil
            } catch {
                isPersistenceWriteBlocked = true
                lastErrorMessage = error.localizedDescription
            }
            return
        }
        let previousStorageMode = snapshot.security.storageMode
        var didPersistEncryptedSnapshot = false
        do {
            let itemsToHydrate = snapshot.items
            var hydratedItemByID: [UUID: ClipboardItem] = [:]
            hydratedItemByID.reserveCapacity(itemsToHydrate.count)
            if let repositorySyncActor {
                let hydratedRepositorySnapshot = try await repositorySyncActor.exportSnapshot()
                hydratedItemByID = Dictionary(
                    uniqueKeysWithValues: hydratedRepositorySnapshot.items.map { ($0.id, $0) }
                )
            }
            if let beforeCommittingHistoryStorageMigrationForTesting {
                await beforeCommittingHistoryStorageMigrationForTesting()
            }
            var encryptedSnapshot = snapshot
            for index in encryptedSnapshot.items.indices {
                guard let hydratedItem = hydratedItemByID[encryptedSnapshot.items[index].id] else { continue }
                Self.adoptHydratedAssets(from: hydratedItem, into: &encryptedSnapshot.items[index])
            }
            encryptedSnapshot.security.storageMode = .encrypted
            snapshot = encryptedSnapshot

            try await persistCurrentSnapshotUntilStable(storageMode: .encrypted)
            didPersistEncryptedSnapshot = true
            try authorityStore.commitStable(.encryptedSnapshot)
            try await removePlaintextRepositoryForEncryptedStorageAsync()
            try await persistCurrentSnapshotUntilStable(storageMode: .encrypted)
            isPersistenceWriteBlocked = false
            lastErrorMessage = nil
        } catch {
            if !didPersistEncryptedSnapshot {
                diskStore.storageMode = previousStorageMode
            }
            isPersistenceWriteBlocked = true
            lastErrorMessage = error.localizedDescription
        }
    }

    nonisolated private static func adoptHydratedAssets(
        from hydratedItem: ClipboardItem,
        into currentItem: inout ClipboardItem
    ) {
        if currentItem.payload.imageData == nil,
           currentItem.payload.imageAssetID == hydratedItem.payload.imageAssetID {
            currentItem.payload.imageData = hydratedItem.payload.imageData
            currentItem.payload.imageByteCount = hydratedItem.payload.imageByteCount
        }
        if currentItem.payload.rtfData == nil,
           currentItem.payload.rtfAssetID == hydratedItem.payload.rtfAssetID {
            currentItem.payload.rtfData = hydratedItem.payload.rtfData
            currentItem.payload.rtfByteCount = hydratedItem.payload.rtfByteCount
        }
        currentItem.refreshSearchDocumentPreservingContentHash()
    }

    private func persistCurrentSnapshotUntilStable(storageMode: SnapshotStorageMode) async throws {
        for _ in 0..<Self.maximumPersistenceStabilityAttempts {
            let revisionToPersist = dataRevision
            let persistenceGeneration = nextPersistenceGeneration()
            var sourceSnapshot = snapshot
            sourceSnapshot.security.storageMode = storageMode
            let hasRepository = storageMode == .standard
                && (repositorySyncActor != nil || clipboardRepository != nil)
            let externalizationTask = Task.detached(priority: .utility) {
                try Self.externalizedSnapshotForDiskPersistence(
                    sourceSnapshot,
                    hasRepository: hasRepository
                )
            }
            let snapshotToPersist = try await withTaskCancellationHandler {
                try await externalizationTask.value
            } onCancel: {
                externalizationTask.cancel()
            }
            guard let commitLease = await persistenceCommitGate.acquire(
                generation: persistenceGeneration
            ) else {
                try Task.checkCancellation()
                continue
            }
            var writeWasAttempted = false
            do {
                try Task.checkCancellation()
                writeWasAttempted = true
                let didPersist = try await persistenceActor.save(
                    snapshotToPersist,
                    storageMode: storageMode,
                    hasAuthoritativeRepository: hasRepository,
                    generation: persistenceGeneration
                )
                guard didPersist else {
                    throw PasteBuddyPersistenceError.historyUnavailable
                }
                persistenceCommitGate.release(commitLease, outcome: .committed)
            } catch {
                persistenceCommitGate.release(
                    commitLease,
                    outcome: writeWasAttempted ? .failedAfterWrite : .abortedBeforeWrite
                )
                throw error
            }
            guard dataRevision == revisionToPersist else { continue }
            diskStore.storageMode = storageMode
            return
        }
        throw PasteBuddyPersistenceError.historyUnavailable
    }

    private func persistStandardRepositoryAndSnapshotUntilStable() async throws {
        for _ in 0..<Self.maximumPersistenceStabilityAttempts {
            let revisionToPersist = dataRevision
            let persistenceGeneration = nextPersistenceGeneration()
            var sourceSnapshot = snapshot
            sourceSnapshot.security.storageMode = .standard

            let hasRepository = repositorySyncActor != nil || clipboardRepository != nil
            let snapshotForExternalization = sourceSnapshot
            let externalizationTask = Task.detached(
                priority: .utility
            ) { [snapshotForExternalization, hasRepository] in
                try Self.externalizedSnapshotForDiskPersistence(
                    snapshotForExternalization,
                    hasRepository: hasRepository
                )
            }
            let snapshotToPersist = try await withTaskCancellationHandler {
                try await externalizationTask.value
            } onCancel: {
                externalizationTask.cancel()
            }
            guard let commitLease = await persistenceCommitGate.acquire(
                generation: persistenceGeneration
            ) else {
                try Task.checkCancellation()
                continue
            }
            var crossedWriteBarrier = false
            do {
                try Task.checkCancellation()
                if let repositorySyncActor {
                    try await repositorySyncActor.synchronize(with: sourceSnapshot)
                    crossedWriteBarrier = true
                }
                if let beforePersistingStandardMigrationSnapshotForTesting {
                    self.beforePersistingStandardMigrationSnapshotForTesting = nil
                    await beforePersistingStandardMigrationSnapshotForTesting()
                }
                crossedWriteBarrier = true
                let didPersist = try await persistenceActor.save(
                    snapshotToPersist,
                    storageMode: .standard,
                    hasAuthoritativeRepository: hasRepository,
                    generation: persistenceGeneration
                )
                guard didPersist else {
                    throw PasteBuddyPersistenceError.historyUnavailable
                }
                persistenceCommitGate.release(commitLease, outcome: .committed)
            } catch {
                persistenceCommitGate.release(
                    commitLease,
                    outcome: crossedWriteBarrier ? .failedAfterWrite : .abortedBeforeWrite
                )
                throw error
            }
            guard dataRevision == revisionToPersist else { continue }

            diskStore.storageMode = .standard
            if hasRepository {
                repositorySyncedDataRevision = revisionToPersist
                clearPendingRepositoryPlan()
                presentationCache = PasteBuddyPresentationCache()
            }
            return
        }
        throw PasteBuddyPersistenceError.historyUnavailable
    }

    public func setBiometricHistoryLockEnabled(_ isEnabled: Bool) {
        snapshot.security.requiresBiometricUnlock = isEnabled
        if isEnabled {
            lockHistory()
        } else {
            historyUnlockedAt = Date()
        }
        saveAndFlush()
    }

    public func updateBiometricGracePeriodSeconds(_ value: TimeInterval) {
        snapshot.security.biometricGracePeriodSeconds = max(0, value)
        saveAndFlush()
    }

    public func clearUnpinnedHistory() {
        clearHistory(includePinned: false)
    }

    public func clearAllHistoryIncludingPinnedItems() {
        clearHistory(includePinned: true)
    }

    public func clearHistory(includePinned: Bool) {
        if includePinned {
            snapshot.items.removeAll()
            dedupeIndex.removeAll()
            pasteStackItems.removeAll()
            for index in snapshot.pinboards.indices {
                snapshot.pinboards[index].itemIDs.removeAll()
                snapshot.pinboards[index].updatedAt = Date()
            }
            selectSingleItem(nil)
            saveAndFlush()
            return
        }

        let pinnedItemIDs = userPinnedItemIDs()
        snapshot.items.removeAll { !pinnedItemIDs.contains($0.id) }
        rebuildDedupeIndex()
        let remainingIDs = Set(snapshot.items.map(\.id))
        pasteStackItems.removeAll { item in
            !remainingIDs.contains(item.id)
        }
        selectSingleItem(filteredItems.first?.id)
        refreshExistingSmartPinboards()
        saveAndFlush()
    }

    public func configureCloudKitSync(
        containerIdentifier: String,
        keyHierarchyVersion: Int = 1,
        capabilityConfigured: Bool = false
    ) {
        let trimmedContainer = containerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContainer.isEmpty else {
            lastErrorMessage = "CloudKit sync requires a container identifier."
            return
        }
        guard keyHierarchyVersion > 0 else {
            lastErrorMessage = "CloudKit sync requires an end-to-end encryption key hierarchy."
            return
        }

        snapshot.sync.provider = .cloudKit
        snapshot.sync.isCloudSyncEnabled = true
        snapshot.sync.cloudKitContainerIdentifier = trimmedContainer
        snapshot.sync.keyHierarchyVersion = keyHierarchyVersion
        snapshot.sync.isCloudKitCapabilityConfigured = capabilityConfigured
        if snapshot.sync.readiness.canAttemptCloudSync {
            lastErrorMessage = nil
        } else {
            lastErrorMessage = snapshot.sync.readiness.detail
        }
        save()
    }

    public func disableCloudSync() {
        snapshot.sync = SyncConfiguration()
        save()
    }

    public func setSharedPinboardsEnabled(_ isEnabled: Bool) {
        guard isEnabled else {
            snapshot.sync.isSharedPinboardsEnabled = false
            for index in snapshot.pinboards.indices {
                snapshot.pinboards[index].sharing = nil
                snapshot.pinboards[index].updatedAt = Date()
            }
            save()
            return
        }
        guard snapshot.sync.readiness.canAttemptCloudSync else {
            snapshot.sync.isSharedPinboardsEnabled = false
            lastErrorMessage = "Shared pinboards require configured CloudKit sync and end-to-end encryption."
            save()
            return
        }
        snapshot.sync.isSharedPinboardsEnabled = true
        save()
    }

    public func importCloudSyncPackage(
        _ package: CloudSyncUploadPackage,
        importer: CloudSyncPackageImporter = CloudSyncPackageImporter()
    ) {
        do {
            let result = try importer.importPackage(package, into: snapshot)
            snapshot = result.snapshot
            lastErrorMessage = nil
            selectSingleItem(filteredItems.first?.id)
            save()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    public func uploadCloudSyncSnapshot(
        using service: CloudKitSyncService
    ) async -> CloudSyncUploadResult? {
        do {
            let result = try await service.upload(snapshot)
            snapshot.sync.lastSyncAt = result.package.createdAt
            snapshot.sync.lastSyncStatusMessage = "Encrypted CloudKit sync uploaded."
            lastErrorMessage = nil
            save()
            return result
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func importLatestCloudSyncSnapshot(
        using service: CloudKitSyncService
    ) async -> CloudSyncDownloadResult? {
        do {
            var mergeBaseRevision = dataRevision
            guard var result = try await service.downloadLatest(into: snapshot) else {
                snapshot.sync.lastSyncStatusMessage = PasteBuddyLocalization.string(
                    "status.cloudkit.no_encrypted_records",
                    defaultValue: "No encrypted CloudKit records found."
                )
                lastErrorMessage = nil
                save()
                return nil
            }
            while dataRevision != mergeBaseRevision {
                mergeBaseRevision = dataRevision
                guard let refreshedResult = try await service.downloadLatest(into: snapshot) else {
                    snapshot.sync.lastSyncStatusMessage = PasteBuddyLocalization.string(
                        "status.cloudkit.no_encrypted_records",
                        defaultValue: "No encrypted CloudKit records found."
                    )
                    lastErrorMessage = nil
                    save()
                    return nil
                }
                result = refreshedResult
            }
            snapshot = result.snapshot
            lastErrorMessage = nil
            selectSingleItem(filteredItems.first?.id)
            save()
            return result
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    public func markCloudSyncCompleted(at date: Date = Date()) {
        guard snapshot.sync.readiness.canAttemptCloudSync else { return }
        snapshot.sync.lastSyncAt = date
        snapshot.sync.lastSyncStatusMessage = "Encrypted CloudKit sync completed."
        save()
    }

    @discardableResult
    public func sharePinboard(
        _ pinboardID: UUID,
        ownerDisplayName: String = PasteBuddyStore.defaultDeviceName,
        accessMode: PinboardShareAccessMode = .invitationOnly,
        defaultPermission: PinboardSharePermission = .readOnly,
        linkToken: String? = nil
    ) -> String? {
        guard canManageSharedPinboards else {
            lastErrorMessage = "Shared pinboards require configured CloudKit sync, end-to-end encryption, and explicit sharing opt-in."
            return nil
        }
        guard let index = snapshot.pinboards.firstIndex(where: { $0.id == pinboardID }) else { return nil }

        let issuedToken = accessMode == .linkAccess ? (linkToken ?? Self.generateShareLinkToken()) : nil
        snapshot.pinboards[index].sharing = PinboardSharingState(
            ownerDisplayName: ownerDisplayName,
            accessMode: accessMode,
            defaultPermission: defaultPermission,
            participants: snapshot.pinboards[index].sharing?.participants ?? [],
            shareLinkTokenHash: issuedToken.map(Self.hashShareLinkToken),
            keyExchange: snapshot.pinboards[index].sharing?.keyExchange
        )
        snapshot.pinboards[index].updatedAt = Date()
        save()
        return issuedToken
    }

    @discardableResult
    public func sharePinboardWithKeyExchange(
        _ pinboardID: UUID,
        ownerIdentity: PinboardShareIdentity,
        ownerDisplayName: String = PasteBuddyStore.defaultDeviceName,
        accessMode: PinboardShareAccessMode = .invitationOnly,
        defaultPermission: PinboardSharePermission = .readOnly,
        keyExchangeService: PinboardShareKeyExchangeService = PinboardShareKeyExchangeService()
    ) -> PinboardKeyExchangeState? {
        guard canManageSharedPinboards else {
            lastErrorMessage = "Shared pinboards require configured CloudKit sync, end-to-end encryption, and explicit sharing opt-in."
            return nil
        }
        guard let index = snapshot.pinboards.firstIndex(where: { $0.id == pinboardID }) else { return nil }

        do {
            let setup = try keyExchangeService.setupOwnerKeyExchange(ownerIdentity: ownerIdentity)
            snapshot.pinboards[index].sharing = PinboardSharingState(
                ownerDisplayName: ownerDisplayName,
                accessMode: accessMode,
                defaultPermission: defaultPermission,
                participants: snapshot.pinboards[index].sharing?.participants ?? [],
                shareLinkTokenHash: snapshot.pinboards[index].sharing?.shareLinkTokenHash,
                keyExchange: setup.state
            )
            snapshot.pinboards[index].updatedAt = Date()
            lastErrorMessage = nil
            save()
            return setup.state
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    public func stopSharingPinboard(_ pinboardID: UUID) {
        guard let index = snapshot.pinboards.firstIndex(where: { $0.id == pinboardID }) else { return }
        snapshot.pinboards[index].sharing = nil
        snapshot.pinboards[index].updatedAt = Date()
        save()
    }

    @discardableResult
    public func inviteParticipant(
        to pinboardID: UUID,
        displayName: String,
        emailAddress: String? = nil,
        permission: PinboardSharePermission = .readOnly
    ) -> PinboardParticipant? {
        guard canManageSharedPinboards else {
            lastErrorMessage = "Shared pinboards require configured CloudKit sync, end-to-end encryption, and explicit sharing opt-in."
            return nil
        }
        guard let index = snapshot.pinboards.firstIndex(where: { $0.id == pinboardID }) else { return nil }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        if snapshot.pinboards[index].sharing == nil {
            snapshot.pinboards[index].sharing = PinboardSharingState(ownerDisplayName: Self.defaultDeviceName)
        }

        let participant = PinboardParticipant(
            displayName: trimmedName,
            emailAddress: emailAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
            permission: permission
        )
        snapshot.pinboards[index].sharing?.participants.append(participant)
        snapshot.pinboards[index].sharing?.updatedAt = Date()
        snapshot.pinboards[index].updatedAt = Date()
        save()
        return participant
    }

    @discardableResult
    public func inviteParticipantWithKeyExchange(
        to pinboardID: UUID,
        displayName: String,
        participantPublicKeyData: Data,
        ownerIdentity: PinboardShareIdentity,
        emailAddress: String? = nil,
        permission: PinboardSharePermission = .readOnly,
        keyExchangeService: PinboardShareKeyExchangeService = PinboardShareKeyExchangeService()
    ) -> PinboardParticipant? {
        guard canManageSharedPinboards else {
            lastErrorMessage = "Shared pinboards require configured CloudKit sync, end-to-end encryption, and explicit sharing opt-in."
            return nil
        }
        guard let index = snapshot.pinboards.firstIndex(where: { $0.id == pinboardID }) else { return nil }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        guard let keyExchange = snapshot.pinboards[index].sharing?.keyExchange else {
            lastErrorMessage = PinboardShareKeyExchangeError.missingKeyExchange.localizedDescription
            return nil
        }

        do {
            let boardKey = try keyExchangeService.unwrapOwnerBoardKey(
                from: keyExchange,
                ownerIdentity: ownerIdentity
            )
            let wrappedBoardKey = try keyExchangeService.wrapBoardKey(
                boardKey,
                recipientPublicKeyData: participantPublicKeyData
            )
            let participant = PinboardParticipant(
                displayName: trimmedName,
                emailAddress: emailAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
                permission: permission,
                keyAgreementPublicKeyData: participantPublicKeyData,
                wrappedBoardKey: wrappedBoardKey,
                boardKeyFingerprint: keyExchange.boardKeyFingerprint
            )
            snapshot.pinboards[index].sharing?.participants.append(participant)
            snapshot.pinboards[index].sharing?.updatedAt = Date()
            snapshot.pinboards[index].updatedAt = Date()
            lastErrorMessage = nil
            save()
            return participant
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    public func makePinboardInvitationPackage(
        pinboardID: UUID,
        participantID: UUID,
        ownerIdentity: PinboardShareIdentity,
        ownerDisplayName: String = PasteBuddyStore.defaultDeviceName,
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        invitationService: PinboardShareInvitationService = PinboardShareInvitationService()
    ) -> PinboardShareInvitationPackage? {
        guard let pinboard = snapshot.pinboards.first(where: { $0.id == pinboardID }),
              let sharing = pinboard.sharing,
              let keyExchange = sharing.keyExchange,
              let participant = sharing.participants.first(where: { $0.id == participantID }) else {
            return nil
        }
        guard let participantPublicKeyData = participant.keyAgreementPublicKeyData else {
            lastErrorMessage = PinboardShareKeyExchangeError.invalidPublicKey.localizedDescription
            return nil
        }

        do {
            let recipientIdentity = try invitationService.publicIdentity(
                displayName: participant.displayName,
                publicKeyData: participantPublicKeyData,
                createdAt: createdAt
            )
            lastErrorMessage = nil
            return try invitationService.makeInvitationPackage(
                pinboardID: pinboardID,
                participantID: participantID,
                permission: participant.permission,
                ownerIdentity: ownerIdentity,
                ownerDisplayName: ownerDisplayName,
                recipientIdentity: recipientIdentity,
                keyExchange: keyExchange,
                createdAt: createdAt,
                expiresAt: expiresAt
            )
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func acceptPinboardInvitationPackage(
        _ package: PinboardShareInvitationPackage,
        recipientIdentity: PinboardShareIdentity,
        acceptedAt: Date = Date(),
        invitationService: PinboardShareInvitationService = PinboardShareInvitationService()
    ) -> Data? {
        do {
            let boardKey = try invitationService.acceptInvitation(
                package,
                recipientIdentity: recipientIdentity,
                now: acceptedAt
            )
            var shouldSave = false
            if let pinboardIndex = snapshot.pinboards.firstIndex(where: { $0.id == package.pinboardID }),
               let participantIndex = snapshot.pinboards[pinboardIndex].sharing?.participants.firstIndex(where: { $0.id == package.participantID }) {
                snapshot.pinboards[pinboardIndex].sharing?.participants[participantIndex].acceptedAt = acceptedAt
                snapshot.pinboards[pinboardIndex].sharing?.updatedAt = acceptedAt
                snapshot.pinboards[pinboardIndex].updatedAt = acceptedAt
                shouldSave = true
            }
            if let inboxIndex = snapshot.pinboardInvitationInbox.entries.firstIndex(where: { $0.id == package.id }) {
                snapshot.pinboardInvitationInbox.entries[inboxIndex].status = .accepted
                snapshot.pinboardInvitationInbox.entries[inboxIndex].statusUpdatedAt = acceptedAt
                snapshot.pinboardInvitationInbox.entries[inboxIndex].lastErrorMessage = nil
                shouldSave = true
            }
            if shouldSave {
                save()
            }
            lastErrorMessage = nil
            return boardKey
        } catch {
            markPinboardInvitationPackageFailed(package.id, error: error, at: acceptedAt)
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func savePendingPinboardInvitationPackages(
        _ packages: [PinboardShareInvitationPackage],
        receivedAt: Date = Date()
    ) -> [PinboardInvitationInboxEntry] {
        guard canManageSharedPinboards else {
            lastErrorMessage = "Shared pinboards require configured CloudKit sync, end-to-end encryption, and explicit sharing opt-in."
            return []
        }
        guard !packages.isEmpty else { return [] }

        var savedEntries: [PinboardInvitationInboxEntry] = []
        for package in packages {
            if let index = snapshot.pinboardInvitationInbox.entries.firstIndex(where: { $0.id == package.id }) {
                if snapshot.pinboardInvitationInbox.entries[index].status == .pending {
                    snapshot.pinboardInvitationInbox.entries[index].package = package
                    snapshot.pinboardInvitationInbox.entries[index].receivedAt = receivedAt
                    snapshot.pinboardInvitationInbox.entries[index].lastErrorMessage = nil
                }
                savedEntries.append(snapshot.pinboardInvitationInbox.entries[index])
            } else {
                let entry = PinboardInvitationInboxEntry(
                    package: package,
                    receivedAt: receivedAt
                )
                snapshot.pinboardInvitationInbox.entries.append(entry)
                savedEntries.append(entry)
            }
        }

        snapshot.pinboardInvitationInbox.entries.sort { $0.receivedAt > $1.receivedAt }
        lastErrorMessage = nil
        save()
        return savedEntries
    }

    @discardableResult
    public func markPinboardInvitationStatus(
        invitationID: UUID,
        status: PinboardInvitationInboxStatus,
        message: String? = nil,
        updatedAt: Date = Date()
    ) -> PinboardInvitationInboxEntry? {
        guard let index = snapshot.pinboardInvitationInbox.entries.firstIndex(where: { $0.id == invitationID }) else {
            return nil
        }
        snapshot.pinboardInvitationInbox.entries[index].status = status
        snapshot.pinboardInvitationInbox.entries[index].statusUpdatedAt = updatedAt
        snapshot.pinboardInvitationInbox.entries[index].lastErrorMessage = message
        save()
        return snapshot.pinboardInvitationInbox.entries[index]
    }

    @discardableResult
    public func acceptPendingPinboardInvitation(
        invitationID: UUID,
        recipientIdentity: PinboardShareIdentity,
        acceptedAt: Date = Date(),
        invitationService: PinboardShareInvitationService = PinboardShareInvitationService()
    ) -> Data? {
        guard let entry = snapshot.pinboardInvitationInbox.entries.first(where: { $0.id == invitationID }) else {
            return nil
        }
        return acceptPinboardInvitationPackage(
            entry.package,
            recipientIdentity: recipientIdentity,
            acceptedAt: acceptedAt,
            invitationService: invitationService
        )
    }

    private func markPinboardInvitationPackageFailed(
        _ invitationID: UUID,
        error: any Error,
        at date: Date
    ) {
        guard let index = snapshot.pinboardInvitationInbox.entries.firstIndex(where: { $0.id == invitationID }) else {
            return
        }
        if let invitationError = error as? PinboardShareInvitationError, invitationError == .expiredInvitation {
            snapshot.pinboardInvitationInbox.entries[index].status = .expired
        } else {
            snapshot.pinboardInvitationInbox.entries[index].status = .rejected
        }
        snapshot.pinboardInvitationInbox.entries[index].statusUpdatedAt = date
        snapshot.pinboardInvitationInbox.entries[index].lastErrorMessage = error.localizedDescription
        save()
    }

    @discardableResult
    public func acceptParticipantKeyExchange(
        pinboardID: UUID,
        participantID: UUID,
        participantIdentity: PinboardShareIdentity,
        acceptedAt: Date = Date(),
        keyExchangeService: PinboardShareKeyExchangeService = PinboardShareKeyExchangeService()
    ) -> Data? {
        guard let pinboardIndex = snapshot.pinboards.firstIndex(where: { $0.id == pinboardID }),
              let participantIndex = snapshot.pinboards[pinboardIndex].sharing?.participants.firstIndex(where: { $0.id == participantID }),
              let participant = snapshot.pinboards[pinboardIndex].sharing?.participants[participantIndex] else {
            return nil
        }
        guard let wrappedBoardKey = participant.wrappedBoardKey else {
            lastErrorMessage = PinboardShareKeyExchangeError.missingWrappedBoardKey.localizedDescription
            return nil
        }
        guard let fingerprint = participant.boardKeyFingerprint else {
            lastErrorMessage = PinboardShareKeyExchangeError.missingKeyExchange.localizedDescription
            return nil
        }

        do {
            let boardKey = try keyExchangeService.unwrapBoardKey(
                wrappedBoardKey,
                recipientIdentity: participantIdentity
            )
            try keyExchangeService.validateBoardKey(boardKey, fingerprint: fingerprint)
            snapshot.pinboards[pinboardIndex].sharing?.participants[participantIndex].acceptedAt = acceptedAt
            snapshot.pinboards[pinboardIndex].sharing?.updatedAt = acceptedAt
            snapshot.pinboards[pinboardIndex].updatedAt = acceptedAt
            lastErrorMessage = nil
            save()
            return boardKey
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    public func updateParticipantPermission(
        pinboardID: UUID,
        participantID: UUID,
        permission: PinboardSharePermission
    ) {
        guard canManageSharedPinboards else {
            lastErrorMessage = "Shared pinboards require configured CloudKit sync, end-to-end encryption, and explicit sharing opt-in."
            return
        }
        guard let pinboardIndex = snapshot.pinboards.firstIndex(where: { $0.id == pinboardID }),
              let participantIndex = snapshot.pinboards[pinboardIndex].sharing?.participants.firstIndex(where: { $0.id == participantID }) else {
            return
        }

        snapshot.pinboards[pinboardIndex].sharing?.participants[participantIndex].permission = permission
        snapshot.pinboards[pinboardIndex].sharing?.updatedAt = Date()
        snapshot.pinboards[pinboardIndex].updatedAt = Date()
        save()
    }

    public func removeParticipant(pinboardID: UUID, participantID: UUID) {
        guard canManageSharedPinboards else {
            lastErrorMessage = "Shared pinboards require configured CloudKit sync, end-to-end encryption, and explicit sharing opt-in."
            return
        }
        guard let pinboardIndex = snapshot.pinboards.firstIndex(where: { $0.id == pinboardID }) else { return }
        snapshot.pinboards[pinboardIndex].sharing?.participants.removeAll { $0.id == participantID }
        snapshot.pinboards[pinboardIndex].sharing?.updatedAt = Date()
        snapshot.pinboards[pinboardIndex].updatedAt = Date()
        save()
    }

    public var canManageSharedPinboards: Bool {
        snapshot.sync.isSharedPinboardsEnabled && snapshot.sync.readiness.canAttemptCloudSync
    }

    private static func generateShareLinkToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func hashShareLinkToken(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func renameSelectedItem(to title: String) {
        guard let selectedItemID else { return }
        renameItem(selectedItemID, to: title)
    }

    public func renameItem(_ itemID: UUID, to title: String) {
        guard let index = snapshot.items.firstIndex(where: { $0.id == itemID }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        snapshot.items[index].title = trimmed
        snapshot.items[index].updatedAt = Date()
        snapshot.items[index].refreshSearchDocumentPreservingContentHash()
        syncPasteStackItem(snapshot.items[index])
        save()
    }

    public func setLabels(_ labels: [String], for itemID: UUID) {
        guard let index = snapshot.items.firstIndex(where: { $0.id == itemID }) else { return }
        snapshot.items[index].labels = ClipboardItem.normalizedLabels(labels)
        snapshot.items[index].updatedAt = Date()
        snapshot.items[index].refreshSearchDocumentPreservingContentHash()
        syncPasteStackItem(snapshot.items[index])
        save()
    }

    public func addLabel(_ label: String, to itemID: UUID) {
        guard let item = snapshot.items.first(where: { $0.id == itemID }) else { return }
        setLabels(item.labels + [label], for: itemID)
    }

    public func removeLabel(_ label: String, from itemID: UUID) {
        guard let item = snapshot.items.first(where: { $0.id == itemID }) else { return }
        let key = label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        setLabels(item.labels.filter {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != key
        }, for: itemID)
    }

    public func setReuseCategory(_ category: ClipboardReuseCategory, for itemID: UUID) {
        guard let index = snapshot.items.firstIndex(where: { $0.id == itemID }) else { return }
        snapshot.items[index].reuseCategory = category
        snapshot.items[index].updatedAt = Date()
        snapshot.items[index].refreshSearchDocumentPreservingContentHash()
        syncPasteStackItem(snapshot.items[index])
        save()
    }

    public func updateSelectedTextItem(to text: String) {
        guard let selectedItemID else { return }
        updateTextItem(selectedItemID, to: text)
    }

    public func updateTextItem(_ itemID: UUID, to text: String) {
        guard let index = snapshot.items.firstIndex(where: { $0.id == itemID }) else { return }
        guard snapshot.items[index].contentType == .text else { return }
        snapshot.items[index].payload.text = text
        snapshot.items[index].updatedAt = Date()
        snapshot.items[index].refreshSearchDocument()
        rebuildDedupeIndex()
        syncPasteStackItem(snapshot.items[index])
        save()
    }

    public func togglePasteStack() {
        isPasteStackActive.toggle()
        selectedScope = .pasteStack
    }

    public func startPasteStack() {
        isPasteStackActive = true
        selectedScope = .pasteStack
    }

    public func stopPasteStack() {
        isPasteStackActive = false
    }

    public func clearPasteStack() {
        pasteStackItems.removeAll()
        if selectedScope == .pasteStack {
            selectSingleItem(nil)
        }
    }

    public func reversePasteStackDirection() {
        pasteStackDirection = pasteStackDirection == .topToBottom ? .bottomToTop : .topToBottom
    }

    public func removeStackItem(_ id: UUID) {
        pasteStackItems.removeAll { $0.id == id }
        selectedItemIDs.remove(id)
        if selectedItemID == id {
            selectSingleItem(filteredItems.first?.id)
        }
    }

    public func pasteNextStackItem() -> ClipboardItem? {
        guard !pasteStackItems.isEmpty else { return nil }
        let item: ClipboardItem
        switch pasteStackDirection {
        case .topToBottom:
            item = pasteStackItems.removeFirst()
        case .bottomToTop:
            item = pasteStackItems.removeLast()
        }
        if selectedScope == .pasteStack {
            selectSingleItem(filteredItems.first?.id)
        }
        return item
    }

    @discardableResult
    public func addItemsToPasteStack(_ itemIDs: [UUID]) -> Bool {
        var seenItemIDs = Set<UUID>()
        var didAddItem = false
        let itemByID = cachedItemByID()
        for itemID in itemIDs where seenItemIDs.insert(itemID).inserted {
            guard let item = itemByID[itemID] else { continue }
            appendToPasteStack(item)
            didAddItem = true
        }
        return didAddItem
    }

    private func appendToPasteStack(_ item: ClipboardItem) {
        pasteStackItems.removeAll { $0.id == item.id }
        pasteStackItems.append(item)
    }

    private func syncPasteStackItem(_ item: ClipboardItem) {
        for stackIndex in pasteStackItems.indices where pasteStackItems[stackIndex].id == item.id {
            pasteStackItems[stackIndex] = item
        }
    }

    private func refreshDerivedDocumentsIfNeeded() {
        var changed = false
        for index in snapshot.items.indices {
            let currentDocument = snapshot.items[index].searchDocument
            snapshot.items[index].refreshSearchDocumentPreservingContentHash()
            if snapshot.items[index].searchDocument != currentDocument {
                changed = true
            }
        }
        if changed {
            presentationCache = PasteBuddyPresentationCache()
        }
    }

    private func rebuildDedupeIndex() {
        dedupeIndexBuildCountForTesting += 1
        var nextIndex: [PasteBuddyDedupeKey: UUID] = [:]
        for item in snapshot.items {
            let key = Self.deduplicationKey(for: item)
            if nextIndex[key] == nil {
                nextIndex[key] = item.id
            }
        }
        dedupeIndex = nextIndex
        dedupeIndexRevision = dataRevision
    }

    private func rebuildCaptureHistoryState() {
        let pinnedItemIDs = userPinnedItemIDs()
        var storageBytesByItemID: [UUID: Int] = [:]
        storageBytesByItemID.reserveCapacity(snapshot.items.count)
        var estimatedStorageBytes = 0
        var retentionSafeUntil: Date?
        let maxHistoryItems = snapshot.storage.maxHistoryItems
        var hasUnpinnedMaxCountOverflow = false
        for (index, item) in snapshot.items.enumerated() {
            let storageBytes = Self.estimatedStorageBytes(for: item)
            storageBytesByItemID[item.id] = storageBytes
            estimatedStorageBytes += storageBytes
            if index >= maxHistoryItems, !pinnedItemIDs.contains(item.id) {
                hasUnpinnedMaxCountOverflow = true
            }
            guard !pinnedItemIDs.contains(item.id),
                  let expiration = retentionExpiration(for: item) else {
                continue
            }
            retentionSafeUntil = min(retentionSafeUntil ?? expiration, expiration)
        }
        captureHistoryState = PasteBuddyCaptureHistoryState(
            revision: dataRevision,
            pinnedItemIDs: pinnedItemIDs,
            storageBytesByItemID: storageBytesByItemID,
            estimatedStorageBytes: estimatedStorageBytes,
            retentionSafeUntil: retentionSafeUntil,
            normalizedMaxHistoryItems: hasUnpinnedMaxCountOverflow ? nil : maxHistoryItems
        )
    }

    private func prepareCaptureHistoryState() {
        guard captureHistoryState?.revision != dataRevision else { return }
        rebuildCaptureHistoryState()
    }

    private func retentionExpiration(for item: ClipboardItem) -> Date? {
        let retentionDays = snapshot.storage.retentionDays
        guard retentionDays > 0 else { return nil }
        return Calendar.current.date(
            byAdding: .day,
            value: retentionDays,
            to: max(item.createdAt, item.updatedAt)
        )
    }

    private func updateCaptureHistoryState(
        replacing previousItem: ClipboardItem?,
        with storedItem: ClipboardItem
    ) {
        guard var state = captureHistoryState else { return }
        if let previousItem {
            state.estimatedStorageBytes -= state.storageBytesByItemID.removeValue(forKey: previousItem.id)
                ?? Self.estimatedStorageBytes(for: previousItem)
        }
        let storageBytes = Self.estimatedStorageBytes(for: storedItem)
        state.storageBytesByItemID[storedItem.id] = storageBytes
        state.estimatedStorageBytes += storageBytes
        if !state.pinnedItemIDs.contains(storedItem.id),
           let expiration = retentionExpiration(for: storedItem) {
            state.retentionSafeUntil = min(state.retentionSafeUntil ?? expiration, expiration)
        }
        captureHistoryState = state
    }

    private func pruneCapturedHistory(
        now: Date = Date(),
        maxItems: Int? = nil,
        frontMoveCount: Int
    ) -> PasteBuddyCapturePruneResult {
        guard var state = captureHistoryState else {
            let deletedIDs = pruneHistory(now: now, maxItems: maxItems)
            rebuildCaptureHistoryState()
            let deletedIDSet = Set(deletedIDs)
            return PasteBuddyCapturePruneResult(
                deletedItems: [],
                deletedItemIDs: Array(deletedIDSet)
            )
        }

        let maxHistoryItems = StorageConfiguration.clampMaxHistoryItems(
            maxItems ?? snapshot.storage.maxHistoryItems
        )
        let maxStorageBytes = StorageConfiguration.clampMaxStorageBytes(snapshot.storage.maxStorageBytes)
        var deletionIndexByID: [UUID: Int] = [:]

        func markForDeletion(_ item: ClipboardItem, at index: Int) {
            deletionIndexByID[item.id] = index
        }

        if snapshot.items.count > maxHistoryItems {
            let indicesToInspect: Range<Int>
            if state.normalizedMaxHistoryItems == maxHistoryItems, frontMoveCount > 0 {
                indicesToInspect = maxHistoryItems..<min(
                    snapshot.items.count,
                    maxHistoryItems + frontMoveCount
                )
            } else if state.normalizedMaxHistoryItems == maxHistoryItems {
                indicesToInspect = maxHistoryItems..<maxHistoryItems
            } else {
                indicesToInspect = maxHistoryItems..<snapshot.items.count
            }
            for index in indicesToInspect {
                captureHotPathItemInspectionCountForTesting += 1
                let item = snapshot.items[index]
                if !state.pinnedItemIDs.contains(item.id) {
                    markForDeletion(item, at: index)
                }
            }
        }
        state.normalizedMaxHistoryItems = maxHistoryItems

        if snapshot.storage.retentionDays > 0,
           let retentionSafeUntil = state.retentionSafeUntil,
           now > retentionSafeUntil {
            let cutoff = Calendar.current.date(
                byAdding: .day,
                value: -snapshot.storage.retentionDays,
                to: now
            )
            var nextRetentionSafeUntil: Date?
            for (index, item) in snapshot.items.enumerated() {
                captureHotPathItemInspectionCountForTesting += 1
                guard !state.pinnedItemIDs.contains(item.id) else { continue }
                let activityDate = max(item.createdAt, item.updatedAt)
                if let cutoff, activityDate < cutoff {
                    markForDeletion(item, at: index)
                } else if let expiration = retentionExpiration(for: item) {
                    nextRetentionSafeUntil = min(nextRetentionSafeUntil ?? expiration, expiration)
                }
            }
            state.retentionSafeUntil = nextRetentionSafeUntil
        }

        var projectedStorageBytes = state.estimatedStorageBytes
        for itemID in deletionIndexByID.keys {
            projectedStorageBytes -= state.storageBytesByItemID[itemID] ?? 0
        }
        if projectedStorageBytes > maxStorageBytes {
            for index in snapshot.items.indices.reversed() {
                captureHotPathItemInspectionCountForTesting += 1
                let item = snapshot.items[index]
                guard !state.pinnedItemIDs.contains(item.id),
                      deletionIndexByID[item.id] == nil else {
                    continue
                }
                markForDeletion(item, at: index)
                projectedStorageBytes -= state.storageBytesByItemID[item.id]
                    ?? Self.estimatedStorageBytes(for: item)
                if projectedStorageBytes <= maxStorageBytes {
                    break
                }
            }
        }

        guard !deletionIndexByID.isEmpty else {
            captureHistoryState = state
            return PasteBuddyCapturePruneResult()
        }

        let deletedItems = deletionIndexByID.values
            .sorted()
            .map { snapshot.items[$0] }
        for index in deletionIndexByID.values.sorted(by: >) {
            snapshot.items.remove(at: index)
        }

        let deletedItemIDs = deletedItems.map(\.id)
        let deletedIDSet = Set(deletedItemIDs)
        var didRemoveIndexedDedupeItem = false
        for item in deletedItems {
            state.estimatedStorageBytes -= state.storageBytesByItemID.removeValue(forKey: item.id) ?? 0
            let dedupeKey = Self.deduplicationKey(for: item)
            if dedupeIndex[dedupeKey] == item.id {
                dedupeIndex.removeValue(forKey: dedupeKey)
                didRemoveIndexedDedupeItem = true
            }
        }
        if didRemoveIndexedDedupeItem {
            rebuildDedupeIndex()
        }
        pasteStackItems.removeAll { deletedIDSet.contains($0.id) }
        selectedItemIDs.subtract(deletedIDSet)
        if selectedItemID.map(deletedIDSet.contains) == true {
            selectSingleItem(filteredItems.first?.id)
        }
        captureHistoryState = state
        return PasteBuddyCapturePruneResult(
            deletedItems: deletedItems,
            deletedItemIDs: deletedItemIDs
        )
    }

    private func updateSmartPinboardsAfterCapture(
        storedItem: ClipboardItem,
        previousItem: ClipboardItem?,
        placement: ClipboardRepositoryItemPlacement,
        deletedItems: [ClipboardItem],
        now: Date = Date()
    ) -> PasteBuddyCapturePinboardChanges {
        if placement == .preserve {
            let before = snapshot.pinboards
            refreshExistingSmartPinboards(now: now)
            let changes = Self.repositoryPinboardChanges(before: before, after: snapshot.pinboards)
            return PasteBuddyCapturePinboardChanges(
                upserts: changes.upserts,
                deletedIDs: changes.deletedIDs
            )
        }

        let deletedObsoleteIDs = snapshot.pinboards.compactMap { pinboard in
            SmartPinboardCategory.obsoletePinboardNames.contains(
                pinboard.name.trimmingCharacters(in: .whitespacesAndNewlines)
            ) ? pinboard.id : nil
        }
        if !deletedObsoleteIDs.isEmpty {
            let deletedIDSet = Set(deletedObsoleteIDs)
            snapshot.pinboards.removeAll { deletedIDSet.contains($0.id) }
        }

        var deletedIDsByCategory: [SmartPinboardCategory: Set<UUID>] = [:]
        for item in deletedItems {
            for category in SmartPinboardCategory.allCases where category.matches(item) {
                deletedIDsByCategory[category, default: []].insert(item.id)
            }
        }

        var metadataUpdates: [ClipboardRepositoryPinboardMetadataMutation] = []
        var frontedItems: [ClipboardRepositoryPinboardItemFrontMutation] = []
        for index in snapshot.pinboards.indices {
            guard let category = SmartPinboardCategory.category(
                forPinboardName: snapshot.pinboards[index].name
            ) else {
                continue
            }
            var changed = false
            if var categoryDeletedIDs = deletedIDsByCategory[category], !categoryDeletedIDs.isEmpty {
                while let lastID = snapshot.pinboards[index].itemIDs.last,
                      categoryDeletedIDs.remove(lastID) != nil {
                    snapshot.pinboards[index].itemIDs.removeLast()
                    changed = true
                }
                if !categoryDeletedIDs.isEmpty {
                    snapshot.pinboards[index].itemIDs.removeAll { itemID in
                        captureHotPathItemInspectionCountForTesting += 1
                        if categoryDeletedIDs.contains(itemID) {
                            changed = true
                            return true
                        }
                        return false
                    }
                }
            }

            if category.matches(storedItem), snapshot.pinboards[index].itemIDs.first != storedItem.id {
                if previousItem != nil,
                   let existingIndex = snapshot.pinboards[index].itemIDs.firstIndex(where: { itemID in
                       captureHotPathItemInspectionCountForTesting += 1
                       return itemID == storedItem.id
                   }) {
                    snapshot.pinboards[index].itemIDs.remove(at: existingIndex)
                }
                snapshot.pinboards[index].itemIDs.insert(storedItem.id, at: 0)
                frontedItems.append(ClipboardRepositoryPinboardItemFrontMutation(
                    pinboardID: snapshot.pinboards[index].id,
                    itemID: storedItem.id
                ))
                changed = true
            }
            if snapshot.pinboards[index].colorHex != category.colorHex {
                snapshot.pinboards[index].colorHex = category.colorHex
                changed = true
            }
            if changed {
                snapshot.pinboards[index].updatedAt = now
                metadataUpdates.append(ClipboardRepositoryPinboardMetadataMutation(
                    pinboard: snapshot.pinboards[index],
                    sortOrder: index
                ))
            }
        }
        return PasteBuddyCapturePinboardChanges(
            deletedIDs: deletedObsoleteIDs,
            metadataUpdates: metadataUpdates,
            frontedItems: frontedItems
        )
    }

    @discardableResult
    private func pruneHistory(now: Date = Date(), maxItems: Int? = nil) -> [UUID] {
        let previousItemCount = snapshot.items.count
        var deletedItemIDs: [UUID] = []
        let pinnedItemIDs = userPinnedItemIDs()
        let maxHistoryItems = StorageConfiguration.clampMaxHistoryItems(maxItems ?? snapshot.storage.maxHistoryItems)
        let maxStorageBytes = StorageConfiguration.clampMaxStorageBytes(snapshot.storage.maxStorageBytes)
        let cutoff = snapshot.storage.retentionDays > 0
            ? Calendar.current.date(byAdding: .day, value: -snapshot.storage.retentionDays, to: now)
            : nil

        snapshot.items = snapshot.items.enumerated().filter { index, item in
            if pinnedItemIDs.contains(item.id) {
                return true
            }
            if index >= maxHistoryItems {
                deletedItemIDs.append(item.id)
                return false
            }
            if let cutoff, max(item.createdAt, item.updatedAt) < cutoff {
                deletedItemIDs.append(item.id)
                return false
            }
            return true
        }.map(\.element)

        var estimatedBytes = snapshot.items.reduce(0) { total, item in
            total + Self.estimatedStorageBytes(for: item)
        }
        if estimatedBytes > maxStorageBytes {
            for index in snapshot.items.indices.reversed() {
                guard !pinnedItemIDs.contains(snapshot.items[index].id) else { continue }
                estimatedBytes -= Self.estimatedStorageBytes(for: snapshot.items[index])
                deletedItemIDs.append(snapshot.items[index].id)
                snapshot.items.remove(at: index)
                if estimatedBytes <= maxStorageBytes {
                    break
                }
            }
        }

        let remainingIDs = Set(snapshot.items.map(\.id))
        pasteStackItems.removeAll { stackItem in
            !remainingIDs.contains(stackItem.id)
        }
        if let selectedItemID, !remainingIDs.contains(selectedItemID) {
            selectSingleItem(filteredItems.first?.id)
        } else {
            let pasteStackIDs = Set(pasteStackItems.map(\.id))
            selectedItemIDs = Set(selectedItemIDs.filter { id in
                remainingIDs.contains(id) || pasteStackIDs.contains(id)
            })
        }
        refreshExistingSmartPinboards()
        if snapshot.items.count != previousItemCount {
            rebuildDedupeIndex()
        }
        return deletedItemIDs
    }

    private static func repositoryPinboardChanges(
        before: [Pinboard],
        after: [Pinboard]
    ) -> (upserts: [ClipboardRepositoryPinboardMutation], deletedIDs: [UUID]) {
        let beforeByID: [UUID: (pinboard: Pinboard, sortOrder: Int)] = Dictionary(
            uniqueKeysWithValues: before.enumerated().map { index, pinboard in
                (pinboard.id, (pinboard, index))
            }
        )
        let afterIDs = Set(after.map(\.id))
        let upserts = after.enumerated().compactMap { index, pinboard -> ClipboardRepositoryPinboardMutation? in
            if let previous = beforeByID[pinboard.id],
               previous.sortOrder == index,
               previous.pinboard == pinboard {
                return nil
            }
            return ClipboardRepositoryPinboardMutation(pinboard: pinboard, sortOrder: index)
        }
        let deletedIDs = before.compactMap { pinboard in
            afterIDs.contains(pinboard.id) ? nil : pinboard.id
        }
        return (upserts, deletedIDs)
    }

    private static func estimatedStorageBytes(for item: ClipboardItem) -> Int {
        item.searchDocument.storageBytes
    }

    private static func deduplicationKey(for item: ClipboardItem) -> PasteBuddyDedupeKey {
        PasteBuddyDedupeKey(contentType: item.contentType, hash: item.searchDocument.dedupeHash)
    }

    nonisolated private static func externalizedSnapshotForDiskPersistence(
        _ source: PasteBuddySnapshot,
        hasRepository: Bool
    ) throws -> PasteBuddySnapshot {
        try Task.checkCancellation()
        guard hasRepository else {
            return source
        }
        var snapshot = source
        for index in snapshot.items.indices {
            if index.isMultiple(of: 16) {
                try Task.checkCancellation()
            }
            snapshot.items[index].payload = try Self.externalizedPayload(
                snapshot.items[index].payload
            )
            snapshot.items[index].refreshSearchDocumentPreservingContentHash()
        }
        return snapshot
    }

    nonisolated private static func externalizedPayload(
        _ payload: ClipboardPayload
    ) throws -> ClipboardPayload {
        var externalized = payload
        if let rtfData = payload.rtfData, !rtfData.isEmpty {
            externalized.rtfAssetID = try sha256HexRespectingCancellation(rtfData)
            externalized.rtfByteCount = rtfData.count
            externalized.rtfData = nil
        }
        if let imageData = payload.imageData, !imageData.isEmpty {
            externalized.imageAssetID = try sha256HexRespectingCancellation(imageData)
            externalized.imageByteCount = imageData.count
            externalized.imageData = nil
        }
        return externalized
    }

    private static func needsExternalAssetHydration(_ snapshot: PasteBuddySnapshot) -> Bool {
        snapshot.items.contains { item in
            (item.payload.imageData == nil && item.payload.imageAssetID != nil)
                || (item.payload.rtfData == nil && item.payload.rtfAssetID != nil)
        }
    }

    nonisolated private static func sha256HexRespectingCancellation(
        _ data: Data
    ) throws -> String {
        var hasher = SHA256()
        let chunkSize = 1_048_576
        var chunkStart = data.startIndex
        while chunkStart < data.endIndex {
            try Task.checkCancellation()
            let chunkEnd = data.index(
                chunkStart,
                offsetBy: chunkSize,
                limitedBy: data.endIndex
            ) ?? data.endIndex
            hasher.update(data: data[chunkStart..<chunkEnd])
            chunkStart = chunkEnd
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    private func syncClipboardRepositoryFromSnapshot() -> Bool {
        guard let clipboardRepository else { return true }
        do {
            try clipboardRepository.synchronize(with: snapshot)
            repositorySyncedDataRevision = dataRevision
            clearPendingRepositoryPlan()
            presentationCache = PasteBuddyPresentationCache()
            return true
        } catch {
            repositorySyncedDataRevision = nil
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    private func filteredItemsCacheKey() -> PasteBuddyFilteredItemsCacheKey {
        PasteBuddyFilteredItemsCacheKey(
            dataRevision: dataRevision,
            queryRevision: queryRevision,
            isHistoryAccessLocked: isHistoryAccessLocked,
            dateFilterTimeBucket: dateFilterTimeBucket()
        )
    }

    private func mainListItemsCacheKey() -> PasteBuddyFilteredItemsCacheKey {
        PasteBuddyFilteredItemsCacheKey(
            dataRevision: dataRevision,
            queryRevision: queryRevision,
            isHistoryAccessLocked: isHistoryAccessLocked,
            dateFilterTimeBucket: dateFilterTimeBucket()
        )
    }

    private func cachedItemByID() -> [UUID: ClipboardItem] {
        let key = PasteBuddyReportCacheKey(dataRevision: dataRevision)
        if presentationCache.itemByIDKey == key {
            return presentationCache.itemByID
        }
        let index = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0) })
        presentationCache.itemByIDKey = key
        presentationCache.itemByID = index
        itemByIDIndexBuildCountForTesting += 1
        return index
    }

    private func selectedItemsCacheKey() -> PasteBuddySelectedItemsCacheKey {
        PasteBuddySelectedItemsCacheKey(
            filteredItemsKey: filteredItemsCacheKey(),
            selectedItemID: selectedItemID,
            selectedItemIDs: selectedItemIDs
        )
    }

    private func availableFilterValues() -> PasteBuddyAvailableFilterValues {
        let cacheKey = PasteBuddyAvailableFilterValuesCacheKey(
            dataRevision: dataRevision,
            pasteStackRevision: pasteStackContentRevision,
            isHistoryAccessLocked: isHistoryAccessLocked
        )
        if presentationCache.availableFilterValuesKey == cacheKey {
            return presentationCache.availableFilterValues
        }

        guard !cacheKey.isHistoryAccessLocked else {
            let values = PasteBuddyAvailableFilterValues()
            presentationCache.availableFilterValuesKey = cacheKey
            presentationCache.availableFilterValues = values
            return values
        }

        var sourceApps = Set<String>()
        var devices = Set<String>()
        // The full in-memory snapshot already contains these small metadata
        // fields. Reading them through GRDB from a SwiftUI body synchronously
        // dispatches to the database pool and has produced real UI hangs.
        for item in snapshot.items {
            insertNonEmpty(item.sourceAppName, into: &sourceApps)
            insertNonEmpty(item.deviceName, into: &devices)
        }
        for item in pasteStackItems {
            insertNonEmpty(item.sourceAppName, into: &sourceApps)
            insertNonEmpty(item.deviceName, into: &devices)
        }

        let values = PasteBuddyAvailableFilterValues(
            sourceApps: sourceApps.sorted(),
            devices: devices.sorted()
        )
        presentationCache.availableFilterValuesKey = cacheKey
        presentationCache.availableFilterValues = values
        return values
    }

    private func dateFilterTimeBucket() -> Int? {
        switch dateFilter {
        case .any:
            return nil
        case .today:
            let startOfDay = Calendar.current.startOfDay(for: Date())
            return Int(startOfDay.timeIntervalSinceReferenceDate / 60)
        case .last7Days:
            return Int(Date().timeIntervalSinceReferenceDate / 60)
        }
    }

    private func insertNonEmpty(_ value: String, into values: inout Set<String>) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        values.insert(trimmed)
    }

    private func filtered(_ items: [ClipboardItem]) -> [ClipboardItem] {
        let filters = resolvedSearchFilters()
        guard !filters.isImpossible else { return [] }
        let normalizedQuery = ClipboardItem.normalizedSearchQuery(filters.textQuery)
        let searchTerms = ClipboardItem.searchTerms(inNormalizedQuery: normalizedQuery)
        return items.filter { item in
            item.matchesNormalizedSearchQuery(normalizedQuery, terms: searchTerms)
                && matchesStructuredFilters(item, sourceAppName: filters.sourceAppName)
        }
    }

    nonisolated private static func page(
        _ items: [ClipboardItem],
        offset: Int,
        limit: Int
    ) -> [ClipboardItem] {
        guard offset < items.count, limit > 0 else { return [] }
        return Array(items.dropFirst(offset).prefix(limit))
    }

    private func matchesStructuredFilters(_ item: ClipboardItem, sourceAppName: String? = nil) -> Bool {
        if let contentTypeFilter, !item.effectiveContentTypes.contains(contentTypeFilter) {
            return false
        }
        if let sourceAppName = sourceAppName ?? sourceAppFilter, item.sourceAppName != sourceAppName {
            return false
        }
        if let deviceFilter, item.deviceName != deviceFilter {
            return false
        }
        if !dateFilter.contains(item.createdAt) {
            return false
        }
        return true
    }

    private func resolvedSearchFilters() -> PasteBuddyResolvedSearchFilters {
        let parts = PasteBuddySearchQueryParts.parse(searchQuery)
        let mentionedSourceApp = parts.sourceAppMention.flatMap(resolveSourceAppName)
        let mentionHasNoMatch = parts.sourceAppMention != nil && mentionedSourceApp == nil
        if mentionHasNoMatch {
            return PasteBuddyResolvedSearchFilters(textQuery: parts.textQuery, sourceAppName: nil, isImpossible: true)
        }

        if let sourceAppFilter, let mentionedSourceApp, sourceAppFilter != mentionedSourceApp {
            return PasteBuddyResolvedSearchFilters(textQuery: parts.textQuery, sourceAppName: nil, isImpossible: true)
        }

        return PasteBuddyResolvedSearchFilters(
            textQuery: parts.textQuery,
            sourceAppName: sourceAppFilter ?? mentionedSourceApp,
            isImpossible: false
        )
    }

    private func resolveSourceAppName(_ mention: String) -> String? {
        let normalizedMention = Self.normalizedAppMention(mention)
        guard !normalizedMention.isEmpty else { return nil }

        let sourceApps = availableSourceApps
        return sourceApps.first { Self.normalizedAppMention($0) == normalizedMention }
            ?? sourceApps.first { Self.normalizedAppMention($0).hasPrefix(normalizedMention) }
            ?? sourceApps.first { Self.normalizedAppMention($0).contains(normalizedMention) }
    }

    private func availableFilterSuggestions() -> [ClipboardFilterDescriptor] {
        let cacheKey = PasteBuddyFilterSuggestionsCacheKey(
            dataRevision: dataRevision,
            queryRevision: queryRevision,
            isHistoryAccessLocked: isHistoryAccessLocked
        )
        if presentationCache.filterSuggestionsKey == cacheKey {
            return presentationCache.filterSuggestions
        }

        let contentTypeSuggestions = ClipboardContentType.allCases
            .filter { $0 != contentTypeFilter }
            .map(filterDescriptor(for:))
        let sourceAppSuggestions = availableSourceApps
            .filter { $0 != sourceAppFilter }
            .map { filterDescriptor(kind: .sourceApp, value: $0) }
        let deviceSuggestions = availableDevices
            .filter { $0 != deviceFilter }
            .map { filterDescriptor(kind: .device, value: $0) }
        let dateSuggestions = ClipboardDateFilter.allCases
            .filter { $0 != .any && $0 != dateFilter }
            .map(filterDescriptor(for:))

        let suggestions = contentTypeSuggestions
            + sourceAppSuggestions
            + deviceSuggestions
            + dateSuggestions
        presentationCache.filterSuggestionsKey = cacheKey
        presentationCache.filterSuggestions = suggestions
        return suggestions
    }

    private func filterDescriptor(for contentType: ClipboardContentType) -> ClipboardFilterDescriptor {
        ClipboardFilterDescriptor(
            kind: .contentType,
            value: contentType.rawValue,
            title: "\(ClipboardFilterKind.contentType.displayName): \(contentType.displayName)",
            subtitle: "Filter clipboard items by content type"
        )
    }

    private func filterDescriptor(for dateFilter: ClipboardDateFilter) -> ClipboardFilterDescriptor {
        ClipboardFilterDescriptor(
            kind: .date,
            value: dateFilter.rawValue,
            title: "\(ClipboardFilterKind.date.displayName): \(dateFilter.displayName)",
            subtitle: "Filter clipboard items by copied date"
        )
    }

    private func filterDescriptor(kind: ClipboardFilterKind, value: String) -> ClipboardFilterDescriptor {
        let subtitle: String
        switch kind {
        case .contentType:
            subtitle = "Filter clipboard items by content type"
        case .sourceApp:
            subtitle = "Filter clipboard items by source app"
        case .device:
            subtitle = "Filter clipboard items by device"
        case .date:
            subtitle = "Filter clipboard items by copied date"
        }

        return ClipboardFilterDescriptor(
            kind: kind,
            value: value,
            title: "\(kind.displayName): \(value)",
            subtitle: subtitle
        )
    }

    private static func normalizedColorHex(_ colorHex: String) -> String {
        let raw = colorHex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .uppercased()
        guard raw.count == 6, Int(raw, radix: 16) != nil else {
            return ""
        }
        return "#\(raw)"
    }

    private static func normalizedSuggestionQuery(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("@") else {
            return trimmed.lowercased()
        }
        return String(trimmed.dropFirst()).lowercased()
    }

    private static func normalizedAppSuggestionQuery(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("@") else {
            return normalizedAppMention(trimmed)
        }
        return normalizedAppMention(String(trimmed.dropFirst()))
    }

    private static func normalizedAppMention(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
            .lowercased()
    }

    private func isSmartPinboard(_ id: UUID) -> Bool {
        guard let index = snapshot.pinboards.firstIndex(where: { $0.id == id }) else { return false }
        return isSmartPinboard(at: index)
    }

    private func isSmartPinboard(at index: Int) -> Bool {
        snapshot.pinboards.indices.contains(index)
            && SmartPinboardCategory.isSmartPinboardName(snapshot.pinboards[index].name)
    }

    private static func userPinboardName(for name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? fallback : trimmed
        guard SmartPinboardCategory.isSmartPinboardName(resolved) else { return resolved }
        return "\(resolved) Pinboard"
    }

    @discardableResult
    private func refreshExistingSmartPinboards(now: Date = Date()) -> Bool {
        let removedObsolete = removeObsoleteSmartPinboards()
        let categories = snapshot.pinboards.compactMap { SmartPinboardCategory.category(forPinboardName: $0.name) }
        guard !categories.isEmpty else { return removedObsolete }
        _ = upsertSmartPinboards(categories: categories, createMissing: false, now: now)
        return true
    }

    @discardableResult
    private func removeObsoleteSmartPinboards() -> Bool {
        let oldCount = snapshot.pinboards.count
        snapshot.pinboards.removeAll { pinboard in
            SmartPinboardCategory.obsoletePinboardNames.contains(
                pinboard.name.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return snapshot.pinboards.count != oldCount
    }

    @discardableResult
    private func upsertSmartPinboards(
        categories: [SmartPinboardCategory],
        createMissing: Bool,
        now: Date = Date()
    ) -> [Pinboard] {
        var result: [Pinboard] = []
        for category in categories {
            let itemIDs = smartPinboardItemIDs(for: category)
            if let index = snapshot.pinboards.firstIndex(where: { $0.name == category.pinboardName }) {
                if snapshot.pinboards[index].itemIDs != itemIDs
                    || snapshot.pinboards[index].colorHex != category.colorHex
                    || snapshot.pinboards[index].systemImageName != nil {
                    snapshot.pinboards[index].itemIDs = itemIDs
                    snapshot.pinboards[index].colorHex = category.colorHex
                    snapshot.pinboards[index].systemImageName = nil
                    snapshot.pinboards[index].updatedAt = now
                }
                result.append(snapshot.pinboards[index])
            } else if createMissing {
                let pinboard = Pinboard(
                    name: category.pinboardName,
                    colorHex: category.colorHex,
                    itemIDs: itemIDs,
                    createdAt: now,
                    updatedAt: now
                )
                snapshot.pinboards.append(pinboard)
                result.append(pinboard)
            }
        }
        return result
    }

    private func smartPinboardItemIDs(for category: SmartPinboardCategory) -> [UUID] {
        snapshot.items
            .filter(category.matches)
            .map(\.id)
    }

    private func userPinnedItemIDs() -> Set<UUID> {
        Set(userPinboards.flatMap(\.itemIDs))
    }
}

private struct PasteBuddySearchQueryParts: Equatable {
    var textQuery: String
    var sourceAppMention: String?

    static func parse(_ query: String) -> PasteBuddySearchQueryParts {
        let tokens = query.split(whereSeparator: { $0.isWhitespace })
        var textTokens: [String] = []
        var sourceAppMention: String?

        for token in tokens {
            let value = String(token)
            guard sourceAppMention == nil, value.hasPrefix("@") else {
                textTokens.append(value)
                continue
            }

            let mention = String(value.dropFirst())
                .trimmingCharacters(in: .punctuationCharacters)
            if !mention.isEmpty {
                sourceAppMention = mention
            }
        }

        return PasteBuddySearchQueryParts(
            textQuery: textTokens.joined(separator: " "),
            sourceAppMention: sourceAppMention
        )
    }
}

private struct PasteBuddyResolvedSearchFilters: Sendable {
    var textQuery: String
    var sourceAppName: String?
    var isImpossible: Bool
}

private struct PasteBuddyInMemoryPageQuery: Sendable {
    var items: [ClipboardItem]
    var orderedItemIDs: [UUID]?
    var filters: PasteBuddyResolvedSearchFilters
    var contentType: ClipboardContentType?
    var deviceName: String?
    var dateFilter: ClipboardDateFilter
    var offset: Int
    var limit: Int

    func execute() -> PasteBuddyInMemoryPageResult {
        let orderedItems: [ClipboardItem]
        if let orderedItemIDs {
            var itemByID: [UUID: ClipboardItem] = [:]
            itemByID.reserveCapacity(items.count)
            for (index, item) in items.enumerated() {
                if index.isMultiple(of: 64), Task.isCancelled {
                    return .cancelled(ranOnMainThread: Thread.isMainThread)
                }
                itemByID[item.id] = item
            }
            var resolvedItems: [ClipboardItem] = []
            resolvedItems.reserveCapacity(orderedItemIDs.count)
            for (index, itemID) in orderedItemIDs.enumerated() {
                if index.isMultiple(of: 64), Task.isCancelled {
                    return .cancelled(ranOnMainThread: Thread.isMainThread)
                }
                if let item = itemByID[itemID] {
                    resolvedItems.append(item)
                }
            }
            orderedItems = resolvedItems
        } else {
            orderedItems = items
        }

        let normalizedQuery = ClipboardItem.normalizedSearchQuery(filters.textQuery)
        let searchTerms = ClipboardItem.searchTerms(inNormalizedQuery: normalizedQuery)
        var pageItems: [ClipboardItem] = []
        pageItems.reserveCapacity(min(limit, orderedItems.count))
        var totalCount = 0
        for (index, item) in orderedItems.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled {
                return .cancelled(ranOnMainThread: Thread.isMainThread)
            }
            guard item.matchesNormalizedSearchQuery(normalizedQuery, terms: searchTerms) else { continue }
            if let contentType, !item.effectiveContentTypes.contains(contentType) { continue }
            if let sourceAppName = filters.sourceAppName, item.sourceAppName != sourceAppName { continue }
            if let deviceName, item.deviceName != deviceName { continue }
            guard dateFilter.contains(item.createdAt) else { continue }

            if totalCount >= offset, pageItems.count < limit {
                pageItems.append(item)
            }
            totalCount += 1
        }
        return PasteBuddyInMemoryPageResult(
            page: PasteBuddyFilteredItemsPage(items: pageItems, totalCount: totalCount),
            ranOnMainThread: Thread.isMainThread,
            wasCancelled: false
        )
    }
}

private struct PasteBuddyInMemoryPageResult: Sendable {
    var page: PasteBuddyFilteredItemsPage
    var ranOnMainThread: Bool
    var wasCancelled: Bool

    static func cancelled(ranOnMainThread: Bool) -> PasteBuddyInMemoryPageResult {
        PasteBuddyInMemoryPageResult(
            page: PasteBuddyFilteredItemsPage(items: [], totalCount: 0),
            ranOnMainThread: ranOnMainThread,
            wasCancelled: true
        )
    }
}

private struct PasteBuddyPresentationCache {
    var mainListItemsKey: PasteBuddyFilteredItemsCacheKey?
    var mainListItems: [ClipboardItem] = []
    var filteredItemsKey: PasteBuddyFilteredItemsCacheKey?
    var filteredItems: [ClipboardItem] = []
    var selectedItemsKey: PasteBuddySelectedItemsCacheKey?
    var selectedItemsInDisplayOrder: [ClipboardItem] = []
    var availableFilterValuesKey: PasteBuddyAvailableFilterValuesCacheKey?
    var availableFilterValues = PasteBuddyAvailableFilterValues()
    var filterSuggestionsKey: PasteBuddyFilterSuggestionsCacheKey?
    var filterSuggestions: [ClipboardFilterDescriptor] = []
    var itemByIDKey: PasteBuddyReportCacheKey?
    var itemByID: [UUID: ClipboardItem] = [:]
    var storageUsageReportKey: PasteBuddyReportCacheKey?
    var storageUsageReport: StorageUsageReport?
    var cloudSyncPreflightReportKey: PasteBuddyReportCacheKey?
    var cloudSyncPreflightReport: CloudSyncPreflightReport?
    var mobileGuidanceReportKey: PasteBuddyReportCacheKey?
    var mobileGuidanceReport: MobileIntegrationGuidanceReport?
    var privacyPostureReportKey: PasteBuddyReportCacheKey?
    var privacyPostureReport: PrivacyPostureReport?
    var accessibilityLocalizationQualityReportKey: PasteBuddyReportCacheKey?
    var accessibilityLocalizationQualityReport: AccessibilityLocalizationQualityReport?
}

private struct PasteBuddyFilteredItemsCacheKey: Equatable {
    var dataRevision: Int
    var queryRevision: Int
    var isHistoryAccessLocked: Bool
    var dateFilterTimeBucket: Int?
}

private struct PasteBuddySelectedItemsCacheKey: Equatable {
    var filteredItemsKey: PasteBuddyFilteredItemsCacheKey
    var selectedItemID: UUID?
    var selectedItemIDs: Set<UUID>
}

private struct PasteBuddyAvailableFilterValuesCacheKey: Equatable {
    var dataRevision: Int
    var pasteStackRevision: Int
    var isHistoryAccessLocked: Bool
}

private struct PasteBuddyFilterSuggestionsCacheKey: Equatable {
    var dataRevision: Int
    var queryRevision: Int
    var isHistoryAccessLocked: Bool
}

private struct PasteBuddyReportCacheKey: Equatable {
    var dataRevision: Int
    var timeBucket: Int?

    init(dataRevision: Int, timeBucket: Int? = nil) {
        self.dataRevision = dataRevision
        self.timeBucket = timeBucket
    }
}

private struct PasteBuddyAvailableFilterValues {
    var sourceApps: [String] = []
    var devices: [String] = []
}

private struct PasteBuddyDedupeKey: Hashable {
    var contentType: ClipboardContentType
    var hash: String
}

private struct PasteBuddyCaptureHistoryState {
    var revision: Int
    var pinnedItemIDs: Set<UUID>
    var storageBytesByItemID: [UUID: Int]
    var estimatedStorageBytes: Int
    var retentionSafeUntil: Date?
    var normalizedMaxHistoryItems: Int?
}

private struct PasteBuddyCapturePruneResult {
    var deletedItems: [ClipboardItem] = []
    var deletedItemIDs: [UUID] = []
}

private struct PasteBuddyCapturePinboardChanges {
    var upserts: [ClipboardRepositoryPinboardMutation] = []
    var deletedIDs: [UUID] = []
    var metadataUpdates: [ClipboardRepositoryPinboardMetadataMutation] = []
    var frontedItems: [ClipboardRepositoryPinboardItemFrontMutation] = []
}

public struct DeletedClipboardItem: Equatable, Sendable {
    public var item: ClipboardItem
    public var pinboardIDs: [UUID]

    public init(item: ClipboardItem, pinboardIDs: [UUID]) {
        self.item = item
        self.pinboardIDs = pinboardIDs
    }
}

extension Array {
    fileprivate mutating func move(fromOffsets offsets: IndexSet, toOffset offset: Int) {
        guard !offsets.isEmpty,
              offsets.allSatisfy(indices.contains),
              (0...count).contains(offset) else {
            return
        }
        let movingValues = offsets.map { self[$0] }
        let removedBeforeDestination = offsets.lazy.filter { $0 < offset }.count
        remove(atOffsets: offsets)
        insert(contentsOf: movingValues, at: offset - removedBeforeDestination)
    }

    fileprivate mutating func remove(atOffsets offsets: IndexSet) {
        for offset in offsets.sorted(by: >) {
            remove(at: offset)
        }
    }
}
