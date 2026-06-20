import CryptoKit
import Foundation
import GRDB

public struct ClipboardItemPageRequest: Equatable, Sendable {
    public var searchQuery: String
    public var contentType: ClipboardContentType?
    public var sourceAppName: String?
    public var deviceName: String?
    public var dateFilter: ClipboardDateFilter
    public var pinboardID: UUID?
    public var limit: Int
    public var offset: Int

    public init(
        searchQuery: String = "",
        contentType: ClipboardContentType? = nil,
        sourceAppName: String? = nil,
        deviceName: String? = nil,
        dateFilter: ClipboardDateFilter = .any,
        pinboardID: UUID? = nil,
        limit: Int = 100,
        offset: Int = 0
    ) {
        self.searchQuery = searchQuery
        self.contentType = contentType
        self.sourceAppName = sourceAppName
        self.deviceName = deviceName
        self.dateFilter = dateFilter
        self.pinboardID = pinboardID
        self.limit = min(max(limit, 1), 500)
        self.offset = max(offset, 0)
    }
}

public struct ClipboardRepositorySyncSummary: Equatable, Sendable {
    public var upsertedItemCount: Int
    public var reorderedItemCount: Int
    public var deletedItemCount: Int
    public var upsertedPinboardCount: Int
    public var deletedPinboardCount: Int

    public init(
        upsertedItemCount: Int = 0,
        reorderedItemCount: Int = 0,
        deletedItemCount: Int = 0,
        upsertedPinboardCount: Int = 0,
        deletedPinboardCount: Int = 0
    ) {
        self.upsertedItemCount = upsertedItemCount
        self.reorderedItemCount = reorderedItemCount
        self.deletedItemCount = deletedItemCount
        self.upsertedPinboardCount = upsertedPinboardCount
        self.deletedPinboardCount = deletedPinboardCount
    }
}

public final class PasteBuddyDatabase: @unchecked Sendable {
    public let fileURL: URL
    private let pool: DatabasePool

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var configuration = Configuration()
        configuration.label = "PasteBuddyDatabase"
        pool = try DatabasePool(path: fileURL.path, configuration: configuration)

        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        try Self.migrator.migrate(pool)
    }

    public static func defaultDatabaseURL() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw SnapshotStoreError.missingApplicationSupportDirectory
        }
        return base
            .appendingPathComponent("PasteBuddy", isDirectory: true)
            .appendingPathComponent("clipboard.sqlite")
    }

    public func journalMode() throws -> String {
        try pool.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? ""
        }
    }

    fileprivate func read<T>(_ block: (Database) throws -> T) throws -> T {
        try pool.read(block)
    }

    fileprivate func write<T>(_ block: (Database) throws -> T) throws -> T {
        try pool.write(block)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("create clipboard database") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS clipboard_items (
                    id TEXT PRIMARY KEY,
                    snapshot_order INTEGER NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    source_app_name TEXT NOT NULL,
                    source_bundle_identifier TEXT,
                    device_name TEXT NOT NULL,
                    content_type TEXT NOT NULL,
                    title TEXT NOT NULL,
                    reuse_category TEXT NOT NULL,
                    dedupe_hash TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    searchable_text TEXT,
                    ocr_text TEXT,
                    ocr_state_json TEXT NOT NULL,
                    byte_count INTEGER NOT NULL DEFAULT 0,
                    thumbnail_asset_id TEXT,
                    full_asset_id TEXT
                )
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS item_labels (
                    item_id TEXT NOT NULL REFERENCES clipboard_items(id) ON DELETE CASCADE,
                    label TEXT NOT NULL,
                    normalized_label TEXT NOT NULL,
                    sort_order INTEGER NOT NULL,
                    PRIMARY KEY(item_id, normalized_label)
                )
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS pinboards (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    color_hex TEXT NOT NULL,
                    sort_order INTEGER NOT NULL,
                    sharing_json TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS pinboard_items (
                    pinboard_id TEXT NOT NULL REFERENCES pinboards(id) ON DELETE CASCADE,
                    item_id TEXT NOT NULL REFERENCES clipboard_items(id) ON DELETE CASCADE,
                    sort_order INTEGER NOT NULL,
                    PRIMARY KEY(pinboard_id, item_id)
                )
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS assets (
                    id TEXT PRIMARY KEY,
                    sha256 TEXT NOT NULL UNIQUE,
                    kind TEXT NOT NULL,
                    path TEXT NOT NULL,
                    data BLOB,
                    byte_count INTEGER NOT NULL,
                    encrypted INTEGER NOT NULL,
                    created_at REAL NOT NULL,
                    last_used_at REAL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS snapshot_metadata (
                    key TEXT PRIMARY KEY,
                    value_json TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_search_fts
                USING fts5(
                    item_id UNINDEXED,
                    title,
                    labels,
                    source_app_name,
                    device_name,
                    content_type,
                    searchable_text,
                    ocr_text
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_items_created_at ON clipboard_items(created_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_items_type_created ON clipboard_items(content_type, created_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_items_source_created ON clipboard_items(source_app_name, created_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_items_device_created ON clipboard_items(device_name, created_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_items_dedupe ON clipboard_items(dedupe_hash)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_pinboard_items_order ON pinboard_items(pinboard_id, sort_order)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_assets_sha256 ON assets(sha256)")
        }
        migrator.registerMigration("add binary asset payloads") { db in
            let assetColumns = try db.columns(in: "assets").map(\.name)
            if !assetColumns.contains("data") {
                try db.execute(sql: "ALTER TABLE assets ADD COLUMN data BLOB")
            }
            try migrateInlinePayloadAssets(db: db)
        }
        migrator.registerMigration("allow duplicate item dedupe hashes") { db in
            try removeClipboardItemsDedupeUniqueConstraintIfNeeded(db: db)
        }
        return migrator
    }

    private static let clipboardItemColumnList = """
        id, snapshot_order, created_at, updated_at, source_app_name,
        source_bundle_identifier, device_name, content_type, title,
        reuse_category, dedupe_hash, payload_json, searchable_text,
        ocr_text, ocr_state_json, byte_count, thumbnail_asset_id, full_asset_id
        """

    private static func removeClipboardItemsDedupeUniqueConstraintIfNeeded(db: Database) throws {
        guard let createSQL = try String.fetchOne(
            db,
            sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'clipboard_items'"
        ),
              createSQL.localizedCaseInsensitiveContains("dedupe_hash TEXT NOT NULL UNIQUE") else {
            return
        }

        try db.execute(sql: "DROP TABLE IF EXISTS pastebuddy_item_labels_backup")
        try db.execute(sql: "DROP TABLE IF EXISTS pastebuddy_pinboard_items_backup")
        try db.execute(sql: "CREATE TEMP TABLE pastebuddy_item_labels_backup AS SELECT * FROM item_labels")
        try db.execute(sql: "CREATE TEMP TABLE pastebuddy_pinboard_items_backup AS SELECT * FROM pinboard_items")

        try db.execute(sql: "DROP TABLE item_labels")
        try db.execute(sql: "DROP TABLE pinboard_items")
        try db.execute(sql: "ALTER TABLE clipboard_items RENAME TO clipboard_items_dedupe_unique")
        try db.execute(sql: """
            CREATE TABLE clipboard_items (
                id TEXT PRIMARY KEY,
                snapshot_order INTEGER NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                source_app_name TEXT NOT NULL,
                source_bundle_identifier TEXT,
                device_name TEXT NOT NULL,
                content_type TEXT NOT NULL,
                title TEXT NOT NULL,
                reuse_category TEXT NOT NULL,
                dedupe_hash TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                searchable_text TEXT,
                ocr_text TEXT,
                ocr_state_json TEXT NOT NULL,
                byte_count INTEGER NOT NULL DEFAULT 0,
                thumbnail_asset_id TEXT,
                full_asset_id TEXT
            )
            """)
        try db.execute(sql: """
            INSERT INTO clipboard_items (\(clipboardItemColumnList))
            SELECT \(clipboardItemColumnList)
            FROM clipboard_items_dedupe_unique
            """)
        try db.execute(sql: "DROP TABLE clipboard_items_dedupe_unique")

        try db.execute(sql: """
            CREATE TABLE item_labels (
                item_id TEXT NOT NULL REFERENCES clipboard_items(id) ON DELETE CASCADE,
                label TEXT NOT NULL,
                normalized_label TEXT NOT NULL,
                sort_order INTEGER NOT NULL,
                PRIMARY KEY(item_id, normalized_label)
            )
            """)
        try db.execute(sql: """
            INSERT INTO item_labels (item_id, label, normalized_label, sort_order)
            SELECT item_id, label, normalized_label, sort_order
            FROM pastebuddy_item_labels_backup
            """)
        try db.execute(sql: """
            CREATE TABLE pinboard_items (
                pinboard_id TEXT NOT NULL REFERENCES pinboards(id) ON DELETE CASCADE,
                item_id TEXT NOT NULL REFERENCES clipboard_items(id) ON DELETE CASCADE,
                sort_order INTEGER NOT NULL,
                PRIMARY KEY(pinboard_id, item_id)
            )
            """)
        try db.execute(sql: """
            INSERT INTO pinboard_items (pinboard_id, item_id, sort_order)
            SELECT pinboard_id, item_id, sort_order
            FROM pastebuddy_pinboard_items_backup
            """)
        try db.execute(sql: "DROP TABLE pastebuddy_item_labels_backup")
        try db.execute(sql: "DROP TABLE pastebuddy_pinboard_items_backup")

        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_items_created_at ON clipboard_items(created_at DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_items_type_created ON clipboard_items(content_type, created_at DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_items_source_created ON clipboard_items(source_app_name, created_at DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_items_device_created ON clipboard_items(device_name, created_at DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_items_dedupe ON clipboard_items(dedupe_hash)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_pinboard_items_order ON pinboard_items(pinboard_id, sort_order)")
    }

    private static func migrateInlinePayloadAssets(db: Database) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT id, payload_json FROM clipboard_items")
        for row in rows {
            let id: String = row["id"]
            let payloadJSON: String = row["payload_json"]
            var payload = try JSONDecoder.pasteBuddy.decode(ClipboardPayload.self, from: Data(payloadJSON.utf8))
            var changed = false

            if let rtfData = payload.rtfData, !rtfData.isEmpty {
                let assetID = try migrateAsset(data: rtfData, kind: "rtf", db: db)
                payload.rtfAssetID = assetID
                payload.rtfByteCount = rtfData.count
                payload.rtfData = nil
                changed = true
            }
            if let imageData = payload.imageData, !imageData.isEmpty {
                let assetID = try migrateAsset(data: imageData, kind: "image", db: db)
                payload.imageAssetID = assetID
                payload.imageByteCount = imageData.count
                payload.imageData = nil
                changed = true
            }

            if changed {
                try db.execute(
                    sql: "UPDATE clipboard_items SET payload_json = ? WHERE id = ?",
                    arguments: [String(decoding: try JSONEncoder.pasteBuddy.encode(payload), as: UTF8.self), id]
                )
            }
        }
    }

    private static func migrateAsset(data: Data, kind: String, db: Database) throws -> String {
        let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let now = Date().timeIntervalSince1970
        try db.execute(
            sql: """
                INSERT INTO assets (
                    id, sha256, kind, path, data, byte_count, encrypted, created_at, last_used_at
                )
                VALUES (?, ?, ?, '', ?, ?, 0, ?, ?)
                ON CONFLICT(sha256) DO UPDATE SET
                    kind = excluded.kind,
                    data = excluded.data,
                    byte_count = excluded.byte_count,
                    last_used_at = excluded.last_used_at
                """,
            arguments: [
                sha256,
                sha256,
                kind,
                data,
                data.count,
                now,
                now
            ]
        )
        return sha256
    }

    func payloadJSONForTesting(itemID: UUID) throws -> String {
        try read { db in
            try String.fetchOne(
                db,
                sql: "SELECT payload_json FROM clipboard_items WHERE id = ?",
                arguments: [itemID.uuidString]
            ) ?? ""
        }
    }

    func assetRowsForTesting() throws -> [StoredClipboardAssetForTesting] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, kind, byte_count, data FROM assets ORDER BY kind, id"
            )
            return rows.map { row in
                StoredClipboardAssetForTesting(
                    id: row["id"],
                    kind: row["kind"],
                    byteCount: row["byte_count"],
                    data: row["data"] ?? Data()
                )
            }
        }
    }
}

struct StoredClipboardAssetForTesting: Equatable {
    var id: String
    var kind: String
    var byteCount: Int
    var data: Data
}

public final class ClipboardItemRepository: @unchecked Sendable {
    private static let metadataKey = "snapshot"
    private let database: PasteBuddyDatabase
    private let instrumentationLock = NSLock()
    private var _replaceAllInvocationCount = 0
    private var _incrementalSyncInvocationCount = 0

    internal var replaceAllInvocationCount: Int {
        instrumentationLock.lock()
        defer { instrumentationLock.unlock() }
        return _replaceAllInvocationCount
    }

    internal var incrementalSyncInvocationCount: Int {
        instrumentationLock.lock()
        defer { instrumentationLock.unlock() }
        return _incrementalSyncInvocationCount
    }

    public init(database: PasteBuddyDatabase) {
        self.database = database
    }

    public func replaceAll(with snapshot: PasteBuddySnapshot) throws {
        incrementReplaceAllInvocationCount()
        try database.write { db in
            try db.execute(sql: "DELETE FROM clipboard_search_fts")
            try db.execute(sql: "DELETE FROM pinboard_items")
            try db.execute(sql: "DELETE FROM pinboards")
            try db.execute(sql: "DELETE FROM item_labels")
            try db.execute(sql: "DELETE FROM clipboard_items")
            try db.execute(sql: "DELETE FROM assets")

            for (index, item) in snapshot.items.enumerated() {
                try Self.upsert(item: item, snapshotOrder: index, db: db)
            }
            for (index, pinboard) in snapshot.pinboards.enumerated() {
                try Self.insert(pinboard: pinboard, sortOrder: index, db: db)
            }
            try Self.saveMetadata(StoredSnapshotMetadata(snapshot: snapshot), db: db)
        }
    }

    @discardableResult
    public func synchronize(with snapshot: PasteBuddySnapshot) throws -> ClipboardRepositorySyncSummary {
        incrementIncrementalSyncInvocationCount()
        return try database.write { db in
            var summary = ClipboardRepositorySyncSummary()
            let existingItems = try Self.fetchItemSyncRecords(db: db)
            let snapshotItemIDs = Set(snapshot.items.map(\.id))
            let deletedItemIDs = existingItems.keys.filter { !snapshotItemIDs.contains($0) }
            if !deletedItemIDs.isEmpty {
                try Self.deleteItems(deletedItemIDs, db: db)
                summary.deletedItemCount = deletedItemIDs.count
            }

            for (index, item) in snapshot.items.enumerated() {
                if let existing = existingItems[item.id] {
                    if try Self.itemContentMatches(existing, item: item) {
                        if existing.snapshotOrder != index {
                            try Self.updateSnapshotOrder(itemID: item.id, snapshotOrder: index, db: db)
                            summary.reorderedItemCount += 1
                        }
                    } else {
                        try Self.upsert(item: item, snapshotOrder: index, db: db)
                        summary.upsertedItemCount += 1
                    }
                } else {
                    try Self.upsert(item: item, snapshotOrder: index, db: db)
                    summary.upsertedItemCount += 1
                }
            }

            let existingPinboards = try Self.fetchPinboardSyncRecords(db: db)
            let snapshotPinboardIDs = Set(snapshot.pinboards.map(\.id))
            let deletedPinboardIDs = existingPinboards.keys.filter { !snapshotPinboardIDs.contains($0) }
            if !deletedPinboardIDs.isEmpty {
                try Self.deletePinboards(deletedPinboardIDs, db: db)
                summary.deletedPinboardCount = deletedPinboardIDs.count
            }

            for (index, pinboard) in snapshot.pinboards.enumerated() {
                if let existing = existingPinboards[pinboard.id],
                   try Self.pinboardMatches(existing, pinboard: pinboard, sortOrder: index) {
                    continue
                }
                try Self.insert(pinboard: pinboard, sortOrder: index, db: db)
                summary.upsertedPinboardCount += 1
            }

            try Self.saveMetadata(StoredSnapshotMetadata(snapshot: snapshot), db: db)
            return summary
        }
    }

    private func incrementReplaceAllInvocationCount() {
        instrumentationLock.lock()
        defer { instrumentationLock.unlock() }
        _replaceAllInvocationCount += 1
    }

    private func incrementIncrementalSyncInvocationCount() {
        instrumentationLock.lock()
        defer { instrumentationLock.unlock() }
        _incrementalSyncInvocationCount += 1
    }

    @discardableResult
    public func insertOrTouchItem(_ item: ClipboardItem) throws -> ClipboardItem {
        try database.write { db in
            let dedupeHash = item.searchDocument.dedupeHash
            if let existingIDString = try String.fetchOne(
                db,
                sql: "SELECT id FROM clipboard_items WHERE content_type = ? AND dedupe_hash = ? LIMIT 1",
                arguments: [item.contentType.rawValue, dedupeHash]
            ),
               let existingID = UUID(uuidString: existingIDString) {
                let now = Date()
                try db.execute(
                    sql: "UPDATE clipboard_items SET updated_at = ? WHERE id = ?",
                    arguments: [now.timeIntervalSince1970, existingIDString]
                )
                return try Self.fetchItem(id: existingID, db: db) ?? item
            }

            let nextOrder = (try Int.fetchOne(db, sql: "SELECT COALESCE(MIN(snapshot_order), 0) - 1 FROM clipboard_items") ?? 0)
            try Self.upsert(item: item, snapshotOrder: nextOrder, db: db)
            return item
        }
    }

    public func upsertItem(_ item: ClipboardItem, snapshotOrder: Int? = nil) throws {
        try database.write { db in
            let resolvedOrder: Int
            if let snapshotOrder {
                resolvedOrder = snapshotOrder
            } else {
                resolvedOrder = try Self.nextSnapshotOrder(db: db)
            }
            try Self.upsert(item: item, snapshotOrder: resolvedOrder, db: db)
        }
    }

    public func updateOCRText(_ text: String, for itemID: UUID) throws {
        try database.write { db in
            guard var item = try Self.fetchItem(id: itemID, db: db) else { return }
            item.payload.ocrText = text
            item.ocrState = .completed(Date())
            item.updatedAt = Date()
            let snapshotOrder = try Int.fetchOne(
                db,
                sql: "SELECT snapshot_order FROM clipboard_items WHERE id = ?",
                arguments: [itemID.uuidString]
            ) ?? 0
            try Self.upsert(item: item, snapshotOrder: snapshotOrder, db: db)
        }
    }

    public func deleteItems(_ ids: [UUID]) throws {
        try database.write { db in
            try Self.deleteItems(ids, db: db)
        }
    }

    public func upsertPinboardMemberships(_ pinboards: [Pinboard]) throws {
        try database.write { db in
            for pinboard in pinboards {
                let sortOrder = try Int.fetchOne(
                    db,
                    sql: "SELECT sort_order FROM pinboards WHERE id = ?",
                    arguments: [pinboard.id.uuidString]
                ) ?? Self.nextPinboardSortOrder(db: db)
                try Self.insert(pinboard: pinboard, sortOrder: sortOrder, db: db)
            }
        }
    }

    public func deletePinboards(_ ids: [UUID]) throws {
        try database.write { db in
            try Self.deletePinboards(ids, db: db)
        }
    }

    public func fetchPage(_ request: ClipboardItemPageRequest = ClipboardItemPageRequest()) throws -> [ClipboardItem] {
        try database.read { db in
            try Self.fetchPage(request, db: db)
        }
    }

    public func itemCount() throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clipboard_items") ?? 0
        }
    }

    public func availableSourceApps() throws -> [String] {
        try database.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT source_app_name
                    FROM clipboard_items
                    WHERE TRIM(source_app_name) <> ''
                    ORDER BY source_app_name
                    """
            )
        }
    }

    public func availableDevices() throws -> [String] {
        try database.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT device_name
                    FROM clipboard_items
                    WHERE TRIM(device_name) <> ''
                    ORDER BY device_name
                    """
            )
        }
    }

    public func exportSnapshot() throws -> PasteBuddySnapshot {
        try database.read { db in
            let metadata = try Self.fetchMetadata(db: db)
            let items = try Self.fetchAllItems(db: db)
            let pinboards = try Self.fetchAllPinboards(db: db)
            return metadata.snapshot(items: items, pinboards: pinboards)
        }
    }

    public func hydrateAssets(for item: ClipboardItem) throws -> ClipboardItem {
        try database.read { db in
            var hydratedItem = item
            try Self.hydrateAssetData(in: &hydratedItem.payload, db: db)
            hydratedItem.refreshSearchDocument()
            return hydratedItem
        }
    }

    public func imageData(for item: ClipboardItem) throws -> Data? {
        if let imageData = item.payload.imageData {
            return imageData
        }
        guard let assetID = item.payload.imageAssetID else {
            return nil
        }
        return try database.read { db in
            try Self.fetchAssetData(id: assetID, db: db).data
        }
    }

    public func rtfData(for item: ClipboardItem) throws -> Data? {
        if let rtfData = item.payload.rtfData {
            return rtfData
        }
        guard let assetID = item.payload.rtfAssetID else {
            return nil
        }
        return try database.read { db in
            try Self.fetchAssetData(id: assetID, db: db).data
        }
    }

    private struct ItemSyncRecord {
        var id: UUID
        var snapshotOrder: Int
        var createdAt: Double
        var updatedAt: Double
        var sourceAppName: String
        var sourceBundleIdentifier: String?
        var deviceName: String
        var contentType: String
        var title: String
        var reuseCategory: String
        var dedupeHash: String
        var payloadJSON: String
        var searchableText: String?
        var ocrText: String?
        var ocrStateJSON: String
        var labels: [String]
    }

    private struct PinboardSyncRecord {
        var id: UUID
        var name: String
        var colorHex: String
        var sortOrder: Int
        var sharingJSON: String?
        var createdAt: Double
        var updatedAt: Double
        var itemIDs: [UUID]
    }

    private static func fetchPage(_ request: ClipboardItemPageRequest, db: Database) throws -> [ClipboardItem] {
        var joins: [String] = []
        var predicates: [String] = []
        var arguments = StatementArguments()

        if let pinboardID = request.pinboardID {
            joins.append("JOIN pinboard_items pbi ON pbi.item_id = ci.id")
            predicates.append("pbi.pinboard_id = ?")
            arguments += [pinboardID.uuidString]
        }

        let trimmedSearch = request.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty, let ftsQuery = ftsQuery(for: trimmedSearch) {
            joins.append("JOIN clipboard_search_fts ON clipboard_search_fts.item_id = ci.id")
            predicates.append("clipboard_search_fts MATCH ?")
            arguments += [ftsQuery]
        }

        if let contentType = request.contentType {
            predicates.append("ci.content_type = ?")
            arguments += [contentType.rawValue]
        }
        if let sourceAppName = request.sourceAppName?.trimmingCharacters(in: .whitespacesAndNewlines), !sourceAppName.isEmpty {
            predicates.append("ci.source_app_name = ?")
            arguments += [sourceAppName]
        }
        if let deviceName = request.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines), !deviceName.isEmpty {
            predicates.append("ci.device_name = ?")
            arguments += [deviceName]
        }
        switch request.dateFilter {
        case .any:
            break
        case .today:
            let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
            predicates.append("ci.created_at >= ?")
            arguments += [startOfDay]
        case .last7Days:
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            predicates.append("ci.created_at >= ?")
            arguments += [cutoff.timeIntervalSince1970]
        }

        let whereClause = predicates.isEmpty ? "" : "WHERE \(predicates.joined(separator: " AND "))"
        let orderClause = request.pinboardID == nil ? "ci.created_at DESC" : "pbi.sort_order ASC"
        arguments += [request.limit, request.offset]

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT ci.*
                FROM clipboard_items ci
                \(joins.joined(separator: "\n"))
                \(whereClause)
                ORDER BY \(orderClause)
                LIMIT ? OFFSET ?
                """,
            arguments: arguments
        )
        return try items(from: rows, db: db, hydrateAssets: false)
    }

    private static func fetchItemSyncRecords(db: Database) throws -> [UUID: ItemSyncRecord] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, snapshot_order, created_at, updated_at, source_app_name,
                    source_bundle_identifier, device_name, content_type, title,
                    reuse_category, dedupe_hash, payload_json, searchable_text,
                    ocr_text, ocr_state_json
                FROM clipboard_items
                """
        )
        let itemIDStrings: [String] = rows.map { row in row["id"] }
        let labelsByItemID = try fetchLabelsByItemID(itemIDStrings, db: db)
        var records: [UUID: ItemSyncRecord] = [:]
        for row in rows {
            let idString: String = row["id"]
            guard let id = UUID(uuidString: idString) else {
                throw PasteBuddyDatabaseError.invalidStoredUUID(idString)
            }
            records[id] = ItemSyncRecord(
                id: id,
                snapshotOrder: row["snapshot_order"],
                createdAt: row["created_at"],
                updatedAt: row["updated_at"],
                sourceAppName: row["source_app_name"],
                sourceBundleIdentifier: row["source_bundle_identifier"],
                deviceName: row["device_name"],
                contentType: row["content_type"],
                title: row["title"],
                reuseCategory: row["reuse_category"],
                dedupeHash: row["dedupe_hash"],
                payloadJSON: row["payload_json"],
                searchableText: row["searchable_text"],
                ocrText: row["ocr_text"],
                ocrStateJSON: row["ocr_state_json"],
                labels: labelsByItemID[idString] ?? []
            )
        }
        return records
    }

    private static func fetchPinboardSyncRecords(db: Database) throws -> [UUID: PinboardSyncRecord] {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM pinboards")
        var records: [UUID: PinboardSyncRecord] = [:]
        for row in rows {
            let idString: String = row["id"]
            guard let id = UUID(uuidString: idString) else {
                throw PasteBuddyDatabaseError.invalidStoredUUID(idString)
            }
            let itemIDStrings = try String.fetchAll(
                db,
                sql: """
                    SELECT item_id
                    FROM pinboard_items
                    WHERE pinboard_id = ?
                    ORDER BY sort_order ASC
                    """,
                arguments: [idString]
            )
            records[id] = PinboardSyncRecord(
                id: id,
                name: row["name"],
                colorHex: row["color_hex"],
                sortOrder: row["sort_order"],
                sharingJSON: row["sharing_json"],
                createdAt: row["created_at"],
                updatedAt: row["updated_at"],
                itemIDs: itemIDStrings.compactMap(UUID.init(uuidString:))
            )
        }
        return records
    }

    private static func itemContentMatches(_ record: ItemSyncRecord, item: ClipboardItem) throws -> Bool {
        var storedItem = item
        let databasePayload = payloadForDatabase(from: item.payload)
        storedItem.payload = databasePayload
        storedItem.refreshSearchDocument()
        let payloadJSON = try jsonString(databasePayload)
        let ocrStateJSON = try jsonString(storedItem.ocrState)
        return nearlyEqual(record.createdAt, item.createdAt.timeIntervalSince1970)
            && nearlyEqual(record.updatedAt, item.updatedAt.timeIntervalSince1970)
            && record.sourceAppName == item.sourceAppName
            && record.sourceBundleIdentifier == item.sourceBundleIdentifier
            && record.deviceName == item.deviceName
            && record.contentType == item.contentType.rawValue
            && record.title == item.title
            && record.reuseCategory == item.reuseCategory.rawValue
            && record.dedupeHash == storedItem.searchDocument.contentHash
            && record.payloadJSON == payloadJSON
            && record.searchableText == storedItem.searchDocument.normalizedText
            && record.ocrText == storedItem.payload.ocrText
            && record.ocrStateJSON == ocrStateJSON
            && record.labels == ClipboardItem.normalizedLabels(item.labels)
    }

    private static func pinboardMatches(_ record: PinboardSyncRecord, pinboard: Pinboard, sortOrder: Int) throws -> Bool {
        let sharingJSON = try pinboard.sharing.map(jsonString)
        return record.name == pinboard.name
            && record.colorHex == pinboard.colorHex
            && record.sortOrder == sortOrder
            && record.sharingJSON == sharingJSON
            && nearlyEqual(record.createdAt, pinboard.createdAt.timeIntervalSince1970)
            && nearlyEqual(record.updatedAt, pinboard.updatedAt.timeIntervalSince1970)
            && record.itemIDs == pinboard.itemIDs
    }

    private static func nearlyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.000_001
    }

    private static func fetchAllItems(db: Database) throws -> [ClipboardItem] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM clipboard_items ORDER BY snapshot_order ASC"
        )
        return try items(from: rows, db: db, hydrateAssets: true)
    }

    private static func fetchItem(id: UUID, db: Database) throws -> ClipboardItem? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM clipboard_items WHERE id = ?",
            arguments: [id.uuidString]
        ) else {
            return nil
        }
        return try items(from: [row], db: db, hydrateAssets: true).first
    }

    private static func items(from rows: [Row], db: Database, hydrateAssets: Bool) throws -> [ClipboardItem] {
        let itemIDs = rows.compactMap { row -> String? in row["id"] }
        let labelsByItemID = try fetchLabelsByItemID(itemIDs, db: db)
        return try rows.map { row in
            let idString: String = row["id"]
            guard let id = UUID(uuidString: idString) else {
                throw PasteBuddyDatabaseError.invalidStoredUUID(idString)
            }
            let payloadJSON: String = row["payload_json"]
            let ocrStateJSON: String = row["ocr_state_json"]
            var payload = try JSONDecoder.pasteBuddy.decode(ClipboardPayload.self, from: Data(payloadJSON.utf8))
            if hydrateAssets {
                try hydrateAssetData(in: &payload, db: db)
            }
            let ocrState = try JSONDecoder.pasteBuddy.decode(OCRState.self, from: Data(ocrStateJSON.utf8))
            let contentTypeRaw: String = row["content_type"]
            let reuseCategoryRaw: String = row["reuse_category"]
            return ClipboardItem(
                id: id,
                createdAt: Date(timeIntervalSince1970: row["created_at"]),
                updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
                sourceAppName: row["source_app_name"],
                sourceBundleIdentifier: row["source_bundle_identifier"],
                deviceName: row["device_name"],
                contentType: ClipboardContentType(rawValue: contentTypeRaw) ?? .text,
                title: row["title"],
                labels: labelsByItemID[idString] ?? [],
                reuseCategory: ClipboardReuseCategory(rawValue: reuseCategoryRaw) ?? .general,
                payload: payload,
                ocrState: ocrState
            )
        }
    }

    private static func fetchLabelsByItemID(_ itemIDs: [String], db: Database) throws -> [String: [String]] {
        guard !itemIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: itemIDs.count).joined(separator: ",")
        var arguments = StatementArguments()
        for itemID in itemIDs {
            arguments += [itemID]
        }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT item_id, label
                FROM item_labels
                WHERE item_id IN (\(placeholders))
                ORDER BY item_id, sort_order
                """,
            arguments: arguments
        )

        var labelsByItemID: [String: [String]] = [:]
        for row in rows {
            let itemID: String = row["item_id"]
            let label: String = row["label"]
            labelsByItemID[itemID, default: []].append(label)
        }
        return labelsByItemID
    }

    private static func fetchAllPinboards(db: Database) throws -> [Pinboard] {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM pinboards ORDER BY sort_order ASC")
        var pinboards: [Pinboard] = []
        for row in rows {
            let idString: String = row["id"]
            guard let id = UUID(uuidString: idString) else {
                throw PasteBuddyDatabaseError.invalidStoredUUID(idString)
            }
            let sharingJSON: String? = row["sharing_json"]
            let sharing = try sharingJSON.map {
                try JSONDecoder.pasteBuddy.decode(PinboardSharingState.self, from: Data($0.utf8))
            }
            let itemIDStrings = try String.fetchAll(
                db,
                sql: """
                    SELECT item_id
                    FROM pinboard_items
                    WHERE pinboard_id = ?
                    ORDER BY sort_order ASC
                    """,
                arguments: [idString]
            )
            let itemIDs = itemIDStrings.compactMap(UUID.init(uuidString:))
            pinboards.append(Pinboard(
                id: id,
                name: row["name"],
                colorHex: row["color_hex"],
                itemIDs: itemIDs,
                sharing: sharing,
                createdAt: Date(timeIntervalSince1970: row["created_at"]),
                updatedAt: Date(timeIntervalSince1970: row["updated_at"])
            ))
        }
        return pinboards
    }

    private static func upsert(item: ClipboardItem, snapshotOrder: Int, db: Database) throws {
        var storedItem = item
        let databasePayload = try strippedPayloadForDatabase(from: item.payload, db: db)
        storedItem.payload = databasePayload
        storedItem.refreshSearchDocument()
        let payloadJSON = try jsonString(databasePayload)
        let ocrStateJSON = try jsonString(storedItem.ocrState)
        try db.execute(
            sql: """
                INSERT INTO clipboard_items (
                    id, snapshot_order, created_at, updated_at, source_app_name,
                    source_bundle_identifier, device_name, content_type, title,
                    reuse_category, dedupe_hash, payload_json, searchable_text,
                    ocr_text, ocr_state_json, byte_count, thumbnail_asset_id, full_asset_id
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL)
                ON CONFLICT(id) DO UPDATE SET
                    snapshot_order = excluded.snapshot_order,
                    created_at = excluded.created_at,
                    updated_at = excluded.updated_at,
                    source_app_name = excluded.source_app_name,
                    source_bundle_identifier = excluded.source_bundle_identifier,
                    device_name = excluded.device_name,
                    content_type = excluded.content_type,
                    title = excluded.title,
                    reuse_category = excluded.reuse_category,
                    dedupe_hash = excluded.dedupe_hash,
                    payload_json = excluded.payload_json,
                    searchable_text = excluded.searchable_text,
                    ocr_text = excluded.ocr_text,
                    ocr_state_json = excluded.ocr_state_json,
                    byte_count = excluded.byte_count
                """,
            arguments: [
                storedItem.id.uuidString,
                snapshotOrder,
                storedItem.createdAt.timeIntervalSince1970,
                storedItem.updatedAt.timeIntervalSince1970,
                storedItem.sourceAppName,
                storedItem.sourceBundleIdentifier,
                storedItem.deviceName,
                storedItem.contentType.rawValue,
                storedItem.title,
                storedItem.reuseCategory.rawValue,
                storedItem.searchDocument.contentHash,
                payloadJSON,
                storedItem.searchDocument.normalizedText,
                storedItem.payload.ocrText,
                ocrStateJSON,
                storedItem.searchDocument.storageBytes
            ]
        )
        try replaceLabels(for: storedItem, db: db)
        try replaceSearchIndex(for: storedItem, db: db)
    }

    private static func strippedPayloadForDatabase(from payload: ClipboardPayload, db: Database) throws -> ClipboardPayload {
        let databasePayload = payloadForDatabase(from: payload)
        if let rtfData = payload.rtfData, !rtfData.isEmpty {
            try storeAsset(data: rtfData, kind: "rtf", db: db)
        }
        if let imageData = payload.imageData, !imageData.isEmpty {
            try storeAsset(data: imageData, kind: "image", db: db)
        }
        return databasePayload
    }

    private static func payloadForDatabase(from payload: ClipboardPayload) -> ClipboardPayload {
        var databasePayload = payload
        if let rtfData = payload.rtfData, !rtfData.isEmpty {
            databasePayload.rtfAssetID = sha256Hex(rtfData)
            databasePayload.rtfByteCount = rtfData.count
        }
        if let imageData = payload.imageData, !imageData.isEmpty {
            databasePayload.imageAssetID = sha256Hex(imageData)
            databasePayload.imageByteCount = imageData.count
        }
        databasePayload.rtfData = nil
        databasePayload.imageData = nil
        return databasePayload
    }

    private static func storeAsset(data: Data, kind: String, db: Database) throws {
        let sha256 = sha256Hex(data)
        let now = Date().timeIntervalSince1970
        try db.execute(
            sql: """
                INSERT INTO assets (
                    id, sha256, kind, path, data, byte_count, encrypted, created_at, last_used_at
                )
                VALUES (?, ?, ?, '', ?, ?, 0, ?, ?)
                ON CONFLICT(sha256) DO UPDATE SET
                    kind = excluded.kind,
                    data = excluded.data,
                    byte_count = excluded.byte_count,
                    last_used_at = excluded.last_used_at
                """,
            arguments: [
                sha256,
                sha256,
                kind,
                data,
                data.count,
                now,
                now
            ]
        )
    }

    private static func hydrateAssetData(in payload: inout ClipboardPayload, db: Database) throws {
        if payload.rtfData == nil, let assetID = payload.rtfAssetID {
            let asset = try fetchAssetData(id: assetID, db: db)
            payload.rtfData = asset.data
            payload.rtfByteCount = asset.byteCount
        }
        if payload.imageData == nil, let assetID = payload.imageAssetID {
            let asset = try fetchAssetData(id: assetID, db: db)
            payload.imageData = asset.data
            payload.imageByteCount = asset.byteCount
        }
    }

    private static func fetchAssetData(id: String, db: Database) throws -> (data: Data?, byteCount: Int?) {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT data, byte_count FROM assets WHERE id = ?",
            arguments: [id]
        ) else {
            return (nil, nil)
        }
        let data: Data? = row["data"]
        let byteCount: Int? = row["byte_count"]
        return (data, byteCount)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func replaceLabels(for item: ClipboardItem, db: Database) throws {
        try db.execute(sql: "DELETE FROM item_labels WHERE item_id = ?", arguments: [item.id.uuidString])
        for (index, label) in ClipboardItem.normalizedLabels(item.labels).enumerated() {
            try db.execute(
                sql: """
                    INSERT INTO item_labels (item_id, label, normalized_label, sort_order)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [
                    item.id.uuidString,
                    label,
                    label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current),
                    index
                ]
            )
        }
    }

    private static func replaceSearchIndex(for item: ClipboardItem, db: Database) throws {
        try db.execute(sql: "DELETE FROM clipboard_search_fts WHERE item_id = ?", arguments: [item.id.uuidString])
        try db.execute(
            sql: """
                INSERT INTO clipboard_search_fts (
                    item_id, title, labels, source_app_name, device_name,
                    content_type, searchable_text, ocr_text
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                item.id.uuidString,
                item.title,
                item.labels.joined(separator: " "),
                item.sourceAppName,
                item.deviceName,
                item.contentType.displayName,
                item.searchDocument.normalizedText,
                item.payload.ocrText
            ]
        )
    }

    private static func updateSnapshotOrder(itemID: UUID, snapshotOrder: Int, db: Database) throws {
        try db.execute(
            sql: "UPDATE clipboard_items SET snapshot_order = ? WHERE id = ?",
            arguments: [snapshotOrder, itemID.uuidString]
        )
    }

    private static func deleteItems(_ ids: [UUID], db: Database) throws {
        guard !ids.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var arguments = StatementArguments()
        for id in ids {
            arguments += [id.uuidString]
        }
        try db.execute(
            sql: "DELETE FROM clipboard_search_fts WHERE item_id IN (\(placeholders))",
            arguments: arguments
        )

        var itemArguments = StatementArguments()
        for id in ids {
            itemArguments += [id.uuidString]
        }
        try db.execute(
            sql: "DELETE FROM clipboard_items WHERE id IN (\(placeholders))",
            arguments: itemArguments
        )
    }

    private static func deletePinboards(_ ids: [UUID], db: Database) throws {
        guard !ids.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var arguments = StatementArguments()
        for id in ids {
            arguments += [id.uuidString]
        }
        try db.execute(
            sql: "DELETE FROM pinboards WHERE id IN (\(placeholders))",
            arguments: arguments
        )
    }

    private static func nextSnapshotOrder(db: Database) throws -> Int {
        (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(snapshot_order), -1) + 1 FROM clipboard_items") ?? 0)
    }

    private static func nextPinboardSortOrder(db: Database) throws -> Int {
        (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM pinboards") ?? 0)
    }

    private static func insert(pinboard: Pinboard, sortOrder: Int, db: Database) throws {
        let sharingJSON = try pinboard.sharing.map(jsonString)
        try db.execute(
            sql: """
                INSERT INTO pinboards (
                    id, name, color_hex, sort_order, sharing_json, created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    color_hex = excluded.color_hex,
                    sort_order = excluded.sort_order,
                    sharing_json = excluded.sharing_json,
                    created_at = excluded.created_at,
                    updated_at = excluded.updated_at
                """,
            arguments: [
                pinboard.id.uuidString,
                pinboard.name,
                pinboard.colorHex,
                sortOrder,
                sharingJSON,
                pinboard.createdAt.timeIntervalSince1970,
                pinboard.updatedAt.timeIntervalSince1970
            ]
        )
        try db.execute(sql: "DELETE FROM pinboard_items WHERE pinboard_id = ?", arguments: [pinboard.id.uuidString])
        for (index, itemID) in pinboard.itemIDs.enumerated() {
            try db.execute(
                sql: """
                    INSERT INTO pinboard_items (pinboard_id, item_id, sort_order)
                    VALUES (?, ?, ?)
                    """,
                arguments: [pinboard.id.uuidString, itemID.uuidString, index]
            )
        }
    }

    private static func saveMetadata(_ metadata: StoredSnapshotMetadata, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO snapshot_metadata (key, value_json)
                VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json
                """,
            arguments: [metadataKey, try jsonString(metadata)]
        )
    }

    private static func fetchMetadata(db: Database) throws -> StoredSnapshotMetadata {
        guard let value = try String.fetchOne(
            db,
            sql: "SELECT value_json FROM snapshot_metadata WHERE key = ?",
            arguments: [metadataKey]
        ) else {
            return StoredSnapshotMetadata(snapshot: PasteBuddySnapshot())
        }
        return try JSONDecoder.pasteBuddy.decode(StoredSnapshotMetadata.self, from: Data(value.utf8))
    }

    private static func jsonString<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder.pasteBuddy.encode(value), as: UTF8.self)
    }

    private static func ftsQuery(for query: String) -> String? {
        let normalizedQuery = ClipboardItem.normalizedSearchString(query)
        let terms = ftsTokens(in: normalizedQuery)
        guard !terms.isEmpty else { return nil }
        return terms.map { "\($0)*" }.joined(separator: " ")
    }

    private static func ftsTokens(in normalizedQuery: String) -> [String] {
        let tokenCharacters = CharacterSet.letters.union(.decimalDigits)
        var tokens: [String] = []
        var current = String.UnicodeScalarView()

        func flushCurrentToken() {
            guard !current.isEmpty else { return }
            tokens.append(String(current))
            current.removeAll(keepingCapacity: true)
        }

        for scalar in normalizedQuery.unicodeScalars {
            if tokenCharacters.contains(scalar) {
                current.append(scalar)
            } else {
                flushCurrentToken()
            }
        }
        flushCurrentToken()
        return tokens
    }

}

public struct PasteBuddySnapshotDatabaseMigrationReport: Equatable, Sendable {
    public var itemCount: Int
    public var pinboardCount: Int
    public var backupURL: URL?

    public init(itemCount: Int, pinboardCount: Int, backupURL: URL?) {
        self.itemCount = itemCount
        self.pinboardCount = pinboardCount
        self.backupURL = backupURL
    }
}

public enum PasteBuddySnapshotDatabaseMigrationError: LocalizedError, Equatable {
    case importedItemCountMismatch(expected: Int, actual: Int)
    case importedItemIDsMismatch
    case importedPinboardIDsMismatch

    public var errorDescription: String? {
        switch self {
        case .importedItemCountMismatch(let expected, let actual):
            "SQLite migration imported \(actual) clipboard items, expected \(expected)."
        case .importedItemIDsMismatch:
            "SQLite migration imported a different set of clipboard item IDs."
        case .importedPinboardIDsMismatch:
            "SQLite migration imported a different set of pinboard IDs."
        }
    }
}

public final class PasteBuddySnapshotDatabaseMigrator: @unchecked Sendable {
    private let snapshotStore: EncryptedSnapshotStore
    private let repository: ClipboardItemRepository
    private let fileManager: FileManager

    public init(
        snapshotStore: EncryptedSnapshotStore,
        repository: ClipboardItemRepository,
        fileManager: FileManager = .default
    ) {
        self.snapshotStore = snapshotStore
        self.repository = repository
        self.fileManager = fileManager
    }

    @discardableResult
    public func migrateFromSnapshot(createBackup: Bool = true) throws -> PasteBuddySnapshotDatabaseMigrationReport {
        let snapshot = try snapshotStore.load()
        let backupURL = try createBackup ? backupSnapshotIfPresent() : nil

        try repository.replaceAll(with: snapshot)

        let exported = try repository.exportSnapshot()
        try validate(exported: exported, matches: snapshot)

        return PasteBuddySnapshotDatabaseMigrationReport(
            itemCount: snapshot.items.count,
            pinboardCount: snapshot.pinboards.count,
            backupURL: backupURL
        )
    }

    private func backupSnapshotIfPresent() throws -> URL? {
        guard fileManager.fileExists(atPath: snapshotStore.fileURL.path) else { return nil }
        let backupURL = snapshotStore.fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(snapshotStore.fileURL.lastPathComponent + ".sqlite-migration-backup")
        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }
        try fileManager.copyItem(at: snapshotStore.fileURL, to: backupURL)
        return backupURL
    }

    private func validate(exported: PasteBuddySnapshot, matches snapshot: PasteBuddySnapshot) throws {
        guard exported.items.count == snapshot.items.count else {
            throw PasteBuddySnapshotDatabaseMigrationError.importedItemCountMismatch(
                expected: snapshot.items.count,
                actual: exported.items.count
            )
        }
        guard Set(exported.items.map(\.id)) == Set(snapshot.items.map(\.id)) else {
            throw PasteBuddySnapshotDatabaseMigrationError.importedItemIDsMismatch
        }
        guard Set(exported.pinboards.map(\.id)) == Set(snapshot.pinboards.map(\.id)) else {
            throw PasteBuddySnapshotDatabaseMigrationError.importedPinboardIDsMismatch
        }
    }
}

public enum PasteBuddyDatabaseError: LocalizedError, Equatable {
    case invalidStoredUUID(String)

    public var errorDescription: String? {
        switch self {
        case .invalidStoredUUID(let value):
            "PasteBuddy database contains an invalid UUID: \(value)"
        }
    }
}

private struct StoredSnapshotMetadata: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var general: GeneralConfiguration
    var entitlement: EntitlementConfiguration
    var mobile: MobileIntegrationConfiguration
    var privacy: PrivacyConfiguration
    var sync: SyncConfiguration
    var pinboardInvitationInbox: PinboardInvitationInbox
    var storage: StorageConfiguration
    var paste: PasteConfiguration
    var shortcuts: ShortcutConfiguration
    var mcp: MCPConfiguration
    var security: SecurityConfiguration

    init(snapshot: PasteBuddySnapshot) {
        schemaVersion = snapshot.schemaVersion
        general = snapshot.general
        entitlement = snapshot.entitlement
        mobile = snapshot.mobile
        privacy = snapshot.privacy
        sync = snapshot.sync
        pinboardInvitationInbox = snapshot.pinboardInvitationInbox
        storage = snapshot.storage
        paste = snapshot.paste
        shortcuts = snapshot.shortcuts
        mcp = snapshot.mcp
        security = snapshot.security
    }

    func snapshot(items: [ClipboardItem], pinboards: [Pinboard]) -> PasteBuddySnapshot {
        PasteBuddySnapshot(
            schemaVersion: schemaVersion,
            items: items,
            pinboards: pinboards,
            general: general,
            entitlement: entitlement,
            mobile: mobile,
            privacy: privacy,
            sync: sync,
            pinboardInvitationInbox: pinboardInvitationInbox,
            storage: storage,
            paste: paste,
            shortcuts: shortcuts,
            mcp: mcp,
            security: security
        )
    }
}
