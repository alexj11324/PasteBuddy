import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
public final class PasteBuddyStore {
    public var snapshot: PasteBuddySnapshot {
        didSet { bumpPresentationRevision() }
    }
    public var selectedScope: PasteScope {
        didSet { bumpPresentationRevision() }
    }
    public var selectedItemID: UUID?
    public var selectedItemIDs: Set<UUID>
    public var searchQuery: String {
        didSet { bumpPresentationRevision() }
    }
    public var lastErrorMessage: String?
    public var isPasteStackActive: Bool
    public var pasteStackItems: [ClipboardItem] {
        didSet { bumpPresentationRevision() }
    }
    public var pasteStackDirection: PasteStackDirection {
        didSet { bumpPresentationRevision() }
    }
    public var contentTypeFilter: ClipboardContentType? {
        didSet { bumpPresentationRevision() }
    }
    public var sourceAppFilter: String? {
        didSet { bumpPresentationRevision() }
    }
    public var deviceFilter: String? {
        didSet { bumpPresentationRevision() }
    }
    public var dateFilter: ClipboardDateFilter {
        didSet { bumpPresentationRevision() }
    }
    public var lastDeletedItem: DeletedClipboardItem?
    public var lastDeletedItems: [DeletedClipboardItem]
    public var lastDirectPasteResult: DirectPasteResult?
    public var requestedSettingsDestination: MacSettingsDestination?
    public var historyUnlockedAt: Date? {
        didSet { bumpPresentationRevision() }
    }
    public private(set) var presentationRevision: Int

    private var diskStore: EncryptedSnapshotStore
    private let historyUnlockAuthenticator: any HistoryUnlockAuthenticating

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

    public init(
        diskStore: EncryptedSnapshotStore? = nil,
        historyUnlockAuthenticator: any HistoryUnlockAuthenticating = SystemHistoryUnlockAuthenticator()
    ) {
        let resolvedDiskStore: EncryptedSnapshotStore
        if let diskStore {
            resolvedDiskStore = diskStore
        } else {
            do {
                resolvedDiskStore = try EncryptedSnapshotStore.defaultStore(storageMode: .standard)
            } catch {
                resolvedDiskStore = EncryptedSnapshotStore(
                    fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("PasteBuddy")
                        .appendingPathComponent("clipboard.pbstore"),
                    storageMode: .standard
                )
            }
        }
        var initialSnapshot = PasteBuddySnapshot()
        initialSnapshot.security.storageMode = resolvedDiskStore.storageMode
        self.diskStore = resolvedDiskStore
        self.historyUnlockAuthenticator = historyUnlockAuthenticator
        self.snapshot = initialSnapshot
        self.selectedScope = .history
        self.selectedItemID = nil
        self.selectedItemIDs = []
        self.searchQuery = ""
        self.isPasteStackActive = false
        self.pasteStackItems = []
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
    }

    public func load() {
        do {
            snapshot = try diskStore.load()
            if let loadedStorageMode = diskStore.lastLoadedStorageMode {
                snapshot.security.storageMode = loadedStorageMode
                diskStore.storageMode = loadedStorageMode
            } else {
                diskStore.storageMode = snapshot.security.storageMode
            }
            if snapshot.security.requiresBiometricUnlock {
                lockHistory()
            } else {
                historyUnlockedAt = Date()
            }
            selectedItemID = filteredItems.first?.id
            selectedItemIDs = selectedItemID.map { [$0] } ?? []
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    public func save() {
        do {
            diskStore.storageMode = snapshot.security.storageMode
            try diskStore.save(snapshot)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    public var filteredItems: [ClipboardItem] {
        guard !isHistoryAccessLocked else { return [] }
        let scopedItems: [ClipboardItem]
        switch selectedScope {
        case .history:
            scopedItems = snapshot.items
            return filtered(scopedItems).sorted { $0.createdAt > $1.createdAt }
        case .pasteStack:
            return filtered(pasteStackItemsInPasteOrder)
        case .pinboard(let id):
            guard let pinboard = snapshot.pinboards.first(where: { $0.id == id }) else {
                return []
            }
            let itemByID = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0) })
            scopedItems = pinboard.itemIDs.compactMap { itemByID[$0] }
            return filtered(scopedItems)
        }
    }

    public var selectedItem: ClipboardItem? {
        guard !isHistoryAccessLocked else { return nil }
        let preferredID = selectedItemID ?? selectedItemIDs.first
        guard let preferredID else { return filteredItems.first }
        return pasteStackItems.first(where: { $0.id == preferredID })
            ?? snapshot.items.first(where: { $0.id == preferredID })
    }

    public var selectedItemsInDisplayOrder: [ClipboardItem] {
        let selected = selectedItemIDs
        guard !selected.isEmpty else {
            return selectedItem.map { [$0] } ?? []
        }
        return filteredItems.filter { selected.contains($0.id) }
    }

    public var hasMultipleSelectedItems: Bool {
        selectedItemsInDisplayOrder.count > 1
    }

    public var selectedPasteOrderPreview: PasteOrderPreview? {
        let items = selectedItemsInDisplayOrder
        guard items.count > 1 else { return nil }
        return PasteOrderPreview(items: items)
    }

    public func setSelectedItemIDs(_ ids: Set<UUID>) {
        guard selectedItemIDs != ids else { return }
        selectedItemIDs = ids
        selectedItemID = filteredItems.first(where: { ids.contains($0.id) })?.id
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
        guard !isHistoryAccessLocked else { return [] }
        return Array(Set((snapshot.items + pasteStackItems).map(\.sourceAppName)))
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted()
    }

    public var availableDevices: [String] {
        guard !isHistoryAccessLocked else { return [] }
        return Array(Set((snapshot.items + pasteStackItems).map(\.deviceName)))
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted()
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
        guard case .pinboard = selectedScope else { return false }
        return !hasActiveFilters && searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var canUndoDelete: Bool {
        lastDeletedItem != nil || !lastDeletedItems.isEmpty
    }

    public var syncReadiness: SyncReadiness {
        snapshot.sync.readiness
    }

    public var cloudSyncPreflightReport: CloudSyncPreflightReport {
        CloudSyncPreflightReport(configuration: snapshot.sync)
    }

    public var mobileGuidanceReport: MobileIntegrationGuidanceReport {
        snapshot.mobile.guidanceReport
    }

    public var privacyPostureReport: PrivacyPostureReport {
        snapshot.privacyPostureReport()
    }

    public var macMenuBarStatus: MacMenuBarStatus {
        snapshot.macMenuBarStatus()
    }

    public var accessibilityLocalizationQualityReport: AccessibilityLocalizationQualityReport {
        snapshot.accessibilityLocalizationQualityReport()
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

    public func quickPasteItem(atOneBasedIndex index: Int) -> ClipboardItem? {
        guard (1...9).contains(index) else { return nil }
        let items = filteredItems
        let zeroBasedIndex = index - 1
        guard items.indices.contains(zeroBasedIndex) else { return nil }
        return items[zeroBasedIndex]
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
        let pinnedItemIDs = Set(snapshot.pinboards.flatMap(\.itemIDs))
        let pinnedItems = snapshot.items.filter { pinnedItemIDs.contains($0.id) }
        let unpinnedItems = snapshot.items.filter { !pinnedItemIDs.contains($0.id) }
        let pinnedBytes = pinnedItems.reduce(0) { $0 + Self.estimatedStorageBytes(for: $1) }
        let unpinnedBytes = unpinnedItems.reduce(0) { $0 + Self.estimatedStorageBytes(for: $1) }
        return StorageUsageReport(
            itemCount: snapshot.items.count,
            pinnedItemCount: pinnedItems.count,
            unpinnedItemCount: unpinnedItems.count,
            estimatedBytes: pinnedBytes + unpinnedBytes,
            pinnedEstimatedBytes: pinnedBytes,
            unpinnedEstimatedBytes: unpinnedBytes,
            maxStorageBytes: snapshot.storage.maxStorageBytes
        )
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
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

    @discardableResult
    public func addCapturedItem(_ item: ClipboardItem, maxItems: Int? = nil) -> ClipboardItem {
        let storedItem: ClipboardItem
        let newDeduplicationKey = Self.deduplicationKey(for: item)
        if let existingIndex = snapshot.items.firstIndex(where: {
            $0.contentType == item.contentType && Self.deduplicationKey(for: $0) == newDeduplicationKey
        }) {
            snapshot.items[existingIndex].updatedAt = Date()
            snapshot.items.move(fromOffsets: IndexSet(integer: existingIndex), toOffset: 0)
            storedItem = snapshot.items[0]
        } else {
            snapshot.items.insert(item, at: 0)
            storedItem = item
        }
        if isPasteStackActive {
            appendToPasteStack(storedItem)
        }
        selectSingleItem(storedItem.id)
        pruneHistory(maxItems: maxItems)
        save()
        return storedItem
    }

    @discardableResult
    public func createTextItem(
        text: String,
        title: String? = nil,
        sourceAppName: String = "PasteBuddy",
        deviceName: String = PasteBuddyStore.defaultDeviceName
    ) -> ClipboardItem? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = ClipboardItem(
            sourceAppName: sourceAppName,
            deviceName: deviceName,
            contentType: .text,
            title: trimmedTitle?.isEmpty == false ? trimmedTitle! : trimmedText.singleLinePreview,
            payload: ClipboardPayload(text: text)
        )
        let decision = snapshot.privacy.captureDecision(
            for: item,
            sourceApplicationName: sourceAppName,
            sourceBundleIdentifier: nil
        )
        guard decision.isAllowed else {
            lastErrorMessage = decision.userMessage
            return nil
        }
        let created = addCapturedItem(item)
        if case .pinboard(let pinboardID) = selectedScope {
            pinItem(created.id, to: pinboardID)
        }
        lastErrorMessage = nil
        return created
    }

    public func updateOCRText(_ text: String, for itemID: UUID) {
        guard let index = snapshot.items.firstIndex(where: { $0.id == itemID }) else { return }
        snapshot.items[index].payload.ocrText = text
        snapshot.items[index].ocrState = .completed(Date())
        snapshot.items[index].updatedAt = Date()
        save()
    }

    public func markOCRPending(for itemID: UUID) {
        guard let index = snapshot.items.firstIndex(where: { $0.id == itemID }) else { return }
        snapshot.items[index].payload.ocrText = nil
        snapshot.items[index].ocrState = .pending(Date())
        snapshot.items[index].updatedAt = Date()
        save()
    }

    public func markOCRFailed(_ message: String, for itemID: UUID) {
        guard let index = snapshot.items.firstIndex(where: { $0.id == itemID }) else { return }
        snapshot.items[index].ocrState = .failed(Date(), message)
        snapshot.items[index].updatedAt = Date()
        save()
    }

    @discardableResult
    public func createPinboard(named name: String = "New Pinboard", colorHex: String = "#7C9A92") -> Pinboard {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let pinboard = Pinboard(name: trimmed.isEmpty ? "New Pinboard" : trimmed, colorHex: colorHex)
        snapshot.pinboards.append(pinboard)
        selectedScope = .pinboard(pinboard.id)
        save()
        return pinboard
    }

    public func deletePinboard(_ id: UUID) {
        snapshot.pinboards.removeAll { $0.id == id }
        if selectedScope == .pinboard(id) {
            selectedScope = .history
        }
        save()
    }

    public func renamePinboard(_ id: UUID, to name: String) {
        guard let pinboardIndex = snapshot.pinboards.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        snapshot.pinboards[pinboardIndex].name = trimmed
        snapshot.pinboards[pinboardIndex].updatedAt = Date()
        save()
    }

    public func updatePinboardColor(_ id: UUID, to colorHex: String) {
        guard let pinboardIndex = snapshot.pinboards.firstIndex(where: { $0.id == id }) else { return }
        let normalized = Self.normalizedColorHex(colorHex)
        guard !normalized.isEmpty else { return }
        snapshot.pinboards[pinboardIndex].colorHex = normalized
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

    public func pinSelectedItem(to pinboardID: UUID) {
        guard let selectedItemID else { return }
        pinItem(selectedItemID, to: pinboardID)
    }

    public func pinItem(_ itemID: UUID, to pinboardID: UUID) {
        pinItems([itemID], to: pinboardID)
    }

    public func pinItems(_ itemIDs: [UUID], to pinboardID: UUID) {
        guard let pinboardIndex = snapshot.pinboards.firstIndex(where: { $0.id == pinboardID }) else { return }
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
        let deletedItems = orderedIDs.compactMap { id -> DeletedClipboardItem? in
            guard let item = snapshot.items.first(where: { $0.id == id }) else { return nil }
            let pinboardIDs = snapshot.pinboards
                .filter { $0.itemIDs.contains(id) }
                .map(\.id)
            return DeletedClipboardItem(item: item, pinboardIDs: pinboardIDs)
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
        save()
    }

    public func pauseCapture(for interval: TimeInterval, now: Date = Date()) {
        snapshot.privacy.isCapturePaused = false
        snapshot.privacy.capturePauseUntil = now.addingTimeInterval(max(0, interval))
        save()
    }

    public func resumeCapture() {
        snapshot.privacy.isCapturePaused = false
        snapshot.privacy.capturePauseUntil = nil
        save()
    }

    public func toggleOCR() {
        snapshot.privacy.runLocalOCRAfterImageCapture.toggle()
        save()
    }

    public func toggleTextCapture() {
        snapshot.privacy.captureText.toggle()
        save()
    }

    public func toggleURLCapture() {
        snapshot.privacy.captureURLs.toggle()
        save()
    }

    public func toggleFileCapture() {
        snapshot.privacy.captureFiles.toggle()
        save()
    }

    public func toggleImageCapture() {
        snapshot.privacy.captureImages.toggle()
        save()
    }

    public func toggleSensitiveTextBlocking() {
        snapshot.privacy.blockLikelySensitiveText.toggle()
        save()
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
            save()
        }
    }

    public func removeExcludedApplication(_ appName: String) {
        snapshot.privacy.excludedApplicationNames.remove(appName)
        save()
    }

    public func removeExcludedBundleIdentifier(_ bundleIdentifier: String) {
        snapshot.privacy.excludedBundleIdentifiers.remove(bundleIdentifier)
        save()
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
        save()
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
        save()
    }

    public func setCaptureRule(_ id: UUID, enabled isEnabled: Bool) {
        guard let index = snapshot.privacy.customCaptureRules.firstIndex(where: { $0.id == id }) else { return }
        snapshot.privacy.customCaptureRules[index].isEnabled = isEnabled
        snapshot.privacy.customCaptureRules[index].updatedAt = Date()
        save()
    }

    public func removeCaptureRule(_ id: UUID) {
        snapshot.privacy.customCaptureRules.removeAll { $0.id == id }
        save()
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

    public func setHistoryEncryptionEnabled(_ isEnabled: Bool) {
        snapshot.security.storageMode = isEnabled ? .encrypted : .standard
        diskStore.storageMode = snapshot.security.storageMode
        save()
    }

    public func setBiometricHistoryLockEnabled(_ isEnabled: Bool) {
        snapshot.security.requiresBiometricUnlock = isEnabled
        if isEnabled {
            lockHistory()
        } else {
            historyUnlockedAt = Date()
        }
        save()
    }

    public func updateBiometricGracePeriodSeconds(_ value: TimeInterval) {
        snapshot.security.biometricGracePeriodSeconds = max(0, value)
        save()
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
            pasteStackItems.removeAll()
            for index in snapshot.pinboards.indices {
                snapshot.pinboards[index].itemIDs.removeAll()
                snapshot.pinboards[index].updatedAt = Date()
            }
            selectSingleItem(nil)
            save()
            return
        }

        let pinnedItemIDs = Set(snapshot.pinboards.flatMap(\.itemIDs))
        snapshot.items.removeAll { !pinnedItemIDs.contains($0.id) }
        pasteStackItems.removeAll { item in
            !snapshot.items.contains(where: { $0.id == item.id })
        }
        selectSingleItem(filteredItems.first?.id)
        save()
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
            guard let result = try await service.downloadLatest(into: snapshot) else {
                snapshot.sync.lastSyncStatusMessage = "No encrypted CloudKit records found."
                lastErrorMessage = nil
                save()
                return nil
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
        syncPasteStackItem(snapshot.items[index])
        save()
    }

    public func setLabels(_ labels: [String], for itemID: UUID) {
        guard let index = snapshot.items.firstIndex(where: { $0.id == itemID }) else { return }
        snapshot.items[index].labels = ClipboardItem.normalizedLabels(labels)
        snapshot.items[index].updatedAt = Date()
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

    private func appendToPasteStack(_ item: ClipboardItem) {
        pasteStackItems.removeAll { $0.id == item.id }
        pasteStackItems.append(item)
    }

    private func syncPasteStackItem(_ item: ClipboardItem) {
        for stackIndex in pasteStackItems.indices where pasteStackItems[stackIndex].id == item.id {
            pasteStackItems[stackIndex] = item
        }
    }

    private func pruneHistory(now: Date = Date(), maxItems: Int? = nil) {
        let pinnedItemIDs = Set(snapshot.pinboards.flatMap(\.itemIDs))
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
                return false
            }
            if let cutoff, item.createdAt < cutoff {
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
                snapshot.items.remove(at: index)
                if estimatedBytes <= maxStorageBytes {
                    break
                }
            }
        }

        pasteStackItems.removeAll { stackItem in
            !snapshot.items.contains(where: { $0.id == stackItem.id })
        }
        if let selectedItemID, !snapshot.items.contains(where: { $0.id == selectedItemID }) {
            selectSingleItem(filteredItems.first?.id)
        } else {
            selectedItemIDs = Set(selectedItemIDs.filter { id in
                snapshot.items.contains(where: { $0.id == id }) || pasteStackItems.contains(where: { $0.id == id })
            })
        }
    }

    private static func estimatedStorageBytes(for item: ClipboardItem) -> Int {
        var estimatedBytes = 256
        estimatedBytes += item.title.utf8.count
        estimatedBytes += item.sourceAppName.utf8.count
        estimatedBytes += item.deviceName.utf8.count
        estimatedBytes += item.contentType.rawValue.utf8.count
        estimatedBytes += item.labels.reduce(0) { total, label in
            total + label.utf8.count
        }
        estimatedBytes += item.reuseCategory.rawValue.utf8.count
        estimatedBytes += item.payload.text?.utf8.count ?? 0
        estimatedBytes += item.payload.htmlString?.utf8.count ?? 0
        estimatedBytes += item.payload.rtfData?.count ?? 0
        estimatedBytes += item.payload.urlString?.utf8.count ?? 0
        estimatedBytes += item.payload.allFileURLStrings.reduce(0) { total, fileURLString in
            total + fileURLString.utf8.count
        }
        estimatedBytes += item.payload.imageData?.count ?? 0
        estimatedBytes += item.payload.ocrText?.utf8.count ?? 0
        return estimatedBytes
    }

    private static func deduplicationKey(for item: ClipboardItem) -> String {
        var hasher = SHA256()
        func update(_ value: String) {
            hasher.update(data: Data(value.utf8))
            hasher.update(data: Data([0]))
        }
        func update(_ data: Data?) {
            if let data {
                hasher.update(data: data)
            }
            hasher.update(data: Data([0]))
        }

        update(item.contentType.rawValue)
        update(item.payload.text ?? "")
        update(item.payload.htmlString ?? "")
        update(item.payload.rtfData)
        update(item.payload.urlString ?? "")
        for fileURLString in item.payload.allFileURLStrings {
            update(fileURLString)
        }
        update(item.payload.imageData)
        update(item.payload.ocrText ?? "")

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func filtered(_ items: [ClipboardItem]) -> [ClipboardItem] {
        items.filter { item in
            item.matches(searchQuery) && matchesStructuredFilters(item)
        }
    }

    private func matchesStructuredFilters(_ item: ClipboardItem) -> Bool {
        if let contentTypeFilter, item.contentType != contentTypeFilter {
            return false
        }
        if let sourceAppFilter, item.sourceAppName != sourceAppFilter {
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

    private func availableFilterSuggestions() -> [ClipboardFilterDescriptor] {
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

        return contentTypeSuggestions
            + sourceAppSuggestions
            + deviceSuggestions
            + dateSuggestions
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
        let movingValues = offsets.map { self[$0] }
        remove(atOffsets: offsets)
        insert(contentsOf: movingValues, at: offset)
    }

    fileprivate mutating func remove(atOffsets offsets: IndexSet) {
        for offset in offsets.sorted(by: >) {
            remove(at: offset)
        }
    }
}
