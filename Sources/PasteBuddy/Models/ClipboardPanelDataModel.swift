import Foundation
import Observation
import PasteBuddyCore

struct ClipboardPanelQueryState: Equatable {
    let dataRevision: Int
    let queryRevision: Int
    let scope: PasteScope
    let searchQuery: String
    let contentTypeFilter: ClipboardContentType?
    let sourceAppFilter: String?
    let deviceFilter: String?
    let dateFilter: ClipboardDateFilter
}

@MainActor
@Observable
final class ClipboardPanelDataModel {
    private(set) var scope: PasteScope
    private(set) var items: [ClipboardItem] = []
    private(set) var totalCount = 0
    private(set) var isRefreshing = false
    private(set) var isLoadingNextPage = false

    @ObservationIgnored private let store: PasteBuddyStore
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var loadNextPageTask: Task<Void, Never>?
    @ObservationIgnored private var refreshRequestState: ClipboardPanelQueryState?
    @ObservationIgnored private var requestGeneration: UInt64 = 0
    @ObservationIgnored private var nextOffset = 0
    @ObservationIgnored var beforeApplyingPageForTesting: (@MainActor @Sendable (UInt64, Int) async -> Void)?
    @ObservationIgnored private(set) var pageRequestCountForTesting = 0

    init(
        store: PasteBuddyStore,
        pageSize: Int = 100
    ) {
        self.store = store
        self.scope = store.selectedScope
        self.pageSize = max(pageSize, 1)
    }

    var canLoadNextPage: Bool {
        nextOffset < totalCount
    }

    var queryState: ClipboardPanelQueryState {
        ClipboardPanelQueryState(
            dataRevision: store.dataRevision,
            queryRevision: store.queryRevision,
            scope: scope,
            searchQuery: store.searchQuery,
            contentTypeFilter: store.contentTypeFilter,
            sourceAppFilter: store.sourceAppFilter,
            deviceFilter: store.deviceFilter,
            dateFilter: store.dateFilter
        )
    }

    func refresh(
        scope newScope: PasteScope? = nil,
        onApply: @escaping @MainActor ([ClipboardItem], Int) -> Void = { _, _ in }
    ) {
        if let newScope, scope != newScope {
            scope = newScope
        }

        let requestedState = queryState
        if refreshTask != nil, refreshRequestState == requestedState {
            return
        }

        requestGeneration &+= 1
        let generation = requestGeneration
        refreshTask?.cancel()
        loadNextPageTask?.cancel()
        loadNextPageTask = nil
        refreshRequestState = requestedState
        isRefreshing = true
        isLoadingNextPage = false
        pageRequestCountForTesting += 1
        let pageSize = pageSize

        refreshTask = Task { @MainActor [weak self, store] in
            let page = await store.filteredItemsPageAndCount(
                for: requestedState.scope,
                offset: 0,
                limit: pageSize
            )
            guard let self else { return }
            if let beforeApplyingPageForTesting {
                await beforeApplyingPageForTesting(generation, 0)
            }
            defer { finishRefresh(generation: generation) }
            guard !Task.isCancelled,
                  generation == requestGeneration,
                  queryState == requestedState else {
                return
            }

            items = Self.uniqueItems(page.items)
            nextOffset = page.items.count
            totalCount = page.totalCount
            onApply(items, page.totalCount)
        }
    }

    func loadNextPage(
        onApply: @escaping @MainActor ([ClipboardItem], Int) -> Void = { _, _ in }
    ) {
        guard !isRefreshing,
              loadNextPageTask == nil,
              canLoadNextPage else {
            return
        }

        let generation = requestGeneration
        let requestedState = queryState
        let requestedOffset = nextOffset
        isLoadingNextPage = true
        pageRequestCountForTesting += 1
        let pageSize = pageSize

        loadNextPageTask = Task { @MainActor [weak self, store] in
            let page = await store.filteredItemsPageAndCount(
                for: requestedState.scope,
                offset: requestedOffset,
                limit: pageSize
            )
            guard let self else { return }
            if let beforeApplyingPageForTesting {
                await beforeApplyingPageForTesting(generation, requestedOffset)
            }
            defer { finishLoadNextPage(generation: generation) }
            guard !Task.isCancelled,
                  generation == requestGeneration,
                  queryState == requestedState,
                  nextOffset == requestedOffset else {
                return
            }

            var existingIDs = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { existingIDs.insert($0.id).inserted })
            nextOffset = requestedOffset + page.items.count
            totalCount = page.totalCount
            onApply(items, page.totalCount)
        }
    }

    func cancel() {
        requestGeneration &+= 1
        refreshTask?.cancel()
        loadNextPageTask?.cancel()
        refreshTask = nil
        loadNextPageTask = nil
        refreshRequestState = nil
        isRefreshing = false
        isLoadingNextPage = false
    }

    private func finishRefresh(generation: UInt64) {
        guard generation == requestGeneration else { return }
        refreshTask = nil
        refreshRequestState = nil
        isRefreshing = false
    }

    private func finishLoadNextPage(generation: UInt64) {
        guard generation == requestGeneration else { return }
        loadNextPageTask = nil
        isLoadingNextPage = false
    }

    private static func uniqueItems(_ items: [ClipboardItem]) -> [ClipboardItem] {
        var seen = Set<UUID>()
        return items.filter { seen.insert($0.id).inserted }
    }
}
