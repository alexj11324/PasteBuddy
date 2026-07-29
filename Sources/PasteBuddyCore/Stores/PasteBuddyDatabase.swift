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

enum ClipboardRepositoryItemPlacement: Sendable {
    case front
    case preserve
}

struct ClipboardRepositoryPinboardMutation: Sendable {
    var pinboard: Pinboard
    var sortOrder: Int
}

struct ClipboardRepositoryPinboardMetadataMutation: Sendable {
    var pinboard: Pinboard
    var sortOrder: Int
}

struct ClipboardRepositoryPinboardItemFrontMutation: Sendable {
    var pinboardID: UUID
    var itemID: UUID
}

struct ClipboardRepositoryCaptureMutation: Sendable {
    var item: ClipboardItem
    var placement: ClipboardRepositoryItemPlacement
    var deletedItemIDs: [UUID]
    var upsertedPinboards: [ClipboardRepositoryPinboardMutation]
    var deletedPinboardIDs: [UUID]
    var updatedPinboardMetadata: [ClipboardRepositoryPinboardMetadataMutation]
    var frontedPinboardItems: [ClipboardRepositoryPinboardItemFrontMutation]

    init(
        item: ClipboardItem,
        placement: ClipboardRepositoryItemPlacement,
        deletedItemIDs: [UUID] = [],
        upsertedPinboards: [ClipboardRepositoryPinboardMutation] = [],
        deletedPinboardIDs: [UUID] = [],
        updatedPinboardMetadata: [ClipboardRepositoryPinboardMetadataMutation] = [],
        frontedPinboardItems: [ClipboardRepositoryPinboardItemFrontMutation] = []
    ) {
        self.item = item
        self.placement = placement
        self.deletedItemIDs = deletedItemIDs
        self.upsertedPinboards = upsertedPinboards
        self.deletedPinboardIDs = deletedPinboardIDs
        self.updatedPinboardMetadata = updatedPinboardMetadata
        self.frontedPinboardItems = frontedPinboardItems
    }
}

struct ClipboardRepositoryCaptureJournal: Sendable {
    var mutations: [ClipboardRepositoryCaptureMutation]

    init(mutations: [ClipboardRepositoryCaptureMutation] = []) {
        self.mutations = mutations
    }

    var isEmpty: Bool { mutations.isEmpty }
}

public final class PasteBuddyDatabase: @unchecked Sendable {
    struct StoragePageDiagnostics: Equatable, Sendable {
        var pageCount: Int64
        var freelistCount: Int64
        var pageSize: Int64

        var freelistBytes: Int64 { freelistCount * pageSize }
        var freelistRatio: Double {
            guard pageCount > 0 else { return 0 }
            return Double(freelistCount) / Double(pageCount)
        }
    }

    enum CompactionResult: Equatable, Sendable {
        case notNeeded
        case compacted
        case deferred
    }

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
        return defaultDatabaseURL(
            in: base.appendingPathComponent("PasteBuddy", isDirectory: true)
        )
    }

    static func defaultDatabaseURL(in persistenceContainerURL: URL) -> URL {
        persistenceContainerURL.appendingPathComponent("clipboard.sqlite")
    }

    public func journalMode() throws -> String {
        try pool.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? ""
        }
    }

    func storagePageDiagnostics() throws -> StoragePageDiagnostics {
        try pool.read { db in
            StoragePageDiagnostics(
                pageCount: try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0,
                freelistCount: try Int64.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0,
                pageSize: try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
            )
        }
    }

    func compactIfNeeded(
        minimumFreelistBytes: Int64 = 32 * 1_024 * 1_024,
        minimumFreelistRatio: Double = 0.20
    ) throws -> CompactionResult {
        let diagnostics = try storagePageDiagnostics()
        guard diagnostics.freelistBytes > minimumFreelistBytes,
              diagnostics.freelistRatio >= minimumFreelistRatio else {
            return .notNeeded
        }
        do {
            try pool.writeWithoutTransaction { db in
                try db.execute(sql: "VACUUM")
                _ = try Row.fetchAll(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            }
            return .compacted
        } catch let error as DatabaseError
            where error.resultCode == .SQLITE_BUSY || error.resultCode == .SQLITE_LOCKED {
            return .deferred
        }
    }

    func hasRevokedTombstone() throws -> Bool {
        try pool.read { db in
            let value = try String.fetchOne(
                db,
                sql: "SELECT value_json FROM snapshot_metadata WHERE key = ?",
                arguments: ["snapshot"]
            )
            return value == "PBDB-REVOKED:1"
        }
    }

    func clearRevokedTombstoneForCutover() throws {
        try pool.write { db in
            try db.execute(
                sql: "DELETE FROM snapshot_metadata WHERE key = ? AND value_json = ?",
                arguments: ["snapshot", "PBDB-REVOKED:1"]
            )
        }
    }

    func eraseSensitiveContent(
        validating validation: (Database) throws -> Void,
        preservingRevision preserveRevision: (Database) throws -> Void
    ) throws {
        try pool.write { db in
            try validation(db)
            try db.execute(sql: "PRAGMA secure_delete = ON")
            try db.execute(sql: "DELETE FROM clipboard_search_fts")
            try db.execute(sql: "DELETE FROM pinboard_items")
            try db.execute(sql: "DELETE FROM item_labels")
            try db.execute(sql: "DELETE FROM pinboards")
            try db.execute(sql: "DELETE FROM clipboard_items")
            try db.execute(sql: "DELETE FROM assets")
            try db.execute(sql: "DELETE FROM snapshot_metadata")
            try preserveRevision(db)
        }
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
            _ = try Row.fetchAll(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    fileprivate func read<T>(_ block: (Database) throws -> T) throws -> T {
        try pool.read(block)
    }

    fileprivate func read<T: Sendable>(
        _ block: @Sendable (Database) throws -> T
    ) async throws -> T {
        try await pool.read(block)
    }

    fileprivate func write<T>(_ block: (Database) throws -> T) throws -> T {
        let interval = PasteBuddyPerformanceSignposts.begin(.repositoryCommit)
        do {
            let result = try pool.write(block)
            PasteBuddyPerformanceSignposts.end(interval, result: .succeeded)
            return result
        } catch {
            PasteBuddyPerformanceSignposts.end(interval, result: .failed)
            throw error
        }
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
                    system_image_name TEXT,
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
            try createTrigramSearchIndex(db: db)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_items_created_at ON clipboard_items(created_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_items_snapshot_order ON clipboard_items(snapshot_order ASC, id ASC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_items_type_created ON clipboard_items(content_type, created_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_items_source_created ON clipboard_items(source_app_name, created_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_items_device_created ON clipboard_items(device_name, created_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_items_dedupe ON clipboard_items(dedupe_hash)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_pinboard_items_order ON pinboard_items(pinboard_id, sort_order)")
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
        migrator.registerMigration("use trigram substring search") { db in
            let schema = try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE name = 'clipboard_search_fts'"
            ) ?? ""
            guard !schema.contains("tokenize='trigram'") else { return }

            try db.execute(sql: "DROP TABLE IF EXISTS clipboard_search_fts")
            try createTrigramSearchIndex(db: db)
            try db.execute(sql: """
                INSERT INTO clipboard_search_fts (rowid, item_id, searchable_text)
                SELECT rowid, id, COALESCE(searchable_text, '')
                FROM clipboard_items
                """)
        }
        migrator.registerMigration("align search index rowids") { db in
            try db.execute(sql: "DELETE FROM clipboard_search_fts")
            try db.execute(sql: """
                INSERT INTO clipboard_search_fts (rowid, item_id, searchable_text)
                SELECT rowid, id, COALESCE(searchable_text, '')
                FROM clipboard_items
                """)
        }
        migrator.registerMigration("add indexed asset references") { db in
            let columns = Set(try db.columns(in: "clipboard_items").map(\.name))
            if !columns.contains("image_asset_id") {
                try db.execute(sql: "ALTER TABLE clipboard_items ADD COLUMN image_asset_id TEXT")
            }
            if !columns.contains("rtf_asset_id") {
                try db.execute(sql: "ALTER TABLE clipboard_items ADD COLUMN rtf_asset_id TEXT")
            }
            try db.execute(sql: """
                UPDATE clipboard_items
                SET image_asset_id = json_extract(payload_json, '$.imageAssetID'),
                    rtf_asset_id = json_extract(payload_json, '$.rtfAssetID')
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_items_image_asset ON clipboard_items(image_asset_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_items_rtf_asset ON clipboard_items(rtf_asset_id)")
        }
        migrator.registerMigration("index canonical snapshot order") { db in
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_items_snapshot_order ON clipboard_items(snapshot_order ASC, id ASC)")
        }
        migrator.registerMigration("index effective content types") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS item_effective_content_types (
                    item_id TEXT NOT NULL REFERENCES clipboard_items(id) ON DELETE CASCADE,
                    content_type TEXT NOT NULL,
                    PRIMARY KEY(item_id, content_type)
                )
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_item_effective_content_types_lookup
                ON item_effective_content_types(content_type, item_id)
                """)

            let rows = try Row.fetchCursor(db, sql: "SELECT id, content_type, payload_json FROM clipboard_items")
            while let row = try rows.next() {
                let itemID: String = row["id"]
                let rawContentType: String = row["content_type"]
                let payloadJSON: String = row["payload_json"]
                let payload = try JSONDecoder.pasteBuddy.decode(ClipboardPayload.self, from: Data(payloadJSON.utf8))
                let contentType = ClipboardContentType(rawValue: rawContentType) ?? .text
                try replaceEffectiveContentTypes(
                    itemID: itemID,
                    contentTypes: ClipboardItem.effectiveContentTypes(contentType: contentType, payload: payload),
                    db: db
                )
            }
        }
        migrator.registerMigration("remove redundant asset sha index") { db in
            // `assets.sha256` is UNIQUE, so SQLite already maintains an
            // autoindex. Keeping a second identical index only adds write and
            // disk cost.
            try db.execute(sql: "DROP INDEX IF EXISTS idx_assets_sha256")
        }
        migrator.registerMigration("add custom pinboard icons") { db in
            let columns = Set(try db.columns(in: "pinboards").map(\.name))
            if !columns.contains("system_image_name") {
                try db.execute(sql: "ALTER TABLE pinboards ADD COLUMN system_image_name TEXT")
            }
        }
        migrator.registerMigration("reclaim orphaned clipboard assets") { db in
            try db.execute(sql: """
                DELETE FROM assets
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM clipboard_items
                    WHERE image_asset_id = assets.id
                       OR rtf_asset_id = assets.id
                       OR thumbnail_asset_id = assets.id
                       OR full_asset_id = assets.id
                )
                """)

            let hasMetadata = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM snapshot_metadata WHERE key = ?)",
                arguments: [ClipboardItemRepository.metadataKey]
            ) ?? false
            guard hasMetadata else { return }

            var metadata = try ClipboardItemRepository.fetchMetadata(db: db)
            metadata.repositoryRevision = UUID()
            try ClipboardItemRepository.saveMetadata(metadata, db: db)
        }
        migrator.registerMigration("repair authoritative asset references") { db in
            try db.execute(sql: """
                UPDATE clipboard_items
                SET image_asset_id = json_extract(payload_json, '$.imageAssetID'),
                    rtf_asset_id = json_extract(payload_json, '$.rtfAssetID')
                WHERE image_asset_id IS NOT json_extract(payload_json, '$.imageAssetID')
                   OR rtf_asset_id IS NOT json_extract(payload_json, '$.rtfAssetID')
                """)

            let metadataValue = try String.fetchOne(
                db,
                sql: "SELECT value_json FROM snapshot_metadata WHERE key = ?",
                arguments: [ClipboardItemRepository.metadataKey]
            )
            guard metadataValue != nil, metadataValue != "PBDB-REVOKED:1" else { return }

            var metadata = try ClipboardItemRepository.fetchMetadata(db: db)
            metadata.repositoryRevision = UUID()
            try ClipboardItemRepository.saveMetadata(metadata, db: db)
        }
        return migrator
    }

    private static func createTrigramSearchIndex(db: Database) throws {
        try db.execute(sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_search_fts
            USING fts5(
                item_id UNINDEXED,
                searchable_text,
                tokenize='trigram'
            )
            """)
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
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_items_snapshot_order ON clipboard_items(snapshot_order ASC, id ASC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_items_type_created ON clipboard_items(content_type, created_at DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_items_source_created ON clipboard_items(source_app_name, created_at DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_items_device_created ON clipboard_items(device_name, created_at DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_items_dedupe ON clipboard_items(dedupe_hash)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_pinboard_items_order ON pinboard_items(pinboard_id, sort_order)")
    }

    private static func migrateInlinePayloadAssets(db: Database) throws {
        let batchSize = 64
        var lastID = ""
        while true {
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, payload_json
                    FROM clipboard_items
                    WHERE id > ?
                    ORDER BY id
                    LIMIT ?
                    """,
                arguments: [lastID, batchSize]
            )
            guard !rows.isEmpty else { return }

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
            lastID = rows[rows.count - 1]["id"]
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

    fileprivate static func replaceEffectiveContentTypes(
        itemID: String,
        contentTypes: Set<ClipboardContentType>,
        db: Database
    ) throws {
        try db.execute(
            sql: "DELETE FROM item_effective_content_types WHERE item_id = ?",
            arguments: [itemID]
        )
        for contentType in contentTypes.sorted(by: { $0.rawValue < $1.rawValue }) {
            try db.execute(
                sql: "INSERT INTO item_effective_content_types (item_id, content_type) VALUES (?, ?)",
                arguments: [itemID, contentType.rawValue]
            )
        }
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
    fileprivate static let metadataKey = "snapshot"
    private let database: PasteBuddyDatabase
    private let instrumentationLock = NSLock()
    private var _replaceAllInvocationCount = 0
    private var _incrementalSyncInvocationCount = 0
    private var _fetchPageInvocationCount = 0
    private var _captureJournalInvocationCount = 0
    private var _lastAsyncFetchPageRanOnMainThreadForTesting: Bool?
    private var _beforeReturningAsyncFetchPageForTesting: (@Sendable () async -> Void)?
    private var expectedRepositoryRevision: UUID?
    private var hasLoadedRepositoryRevision = false
    private var repositoryBaselineEpoch: UInt64 = 0
    internal var beforeAdoptingExportRevisionForTesting: (() -> Void)?

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

    internal var fetchPageInvocationCount: Int {
        instrumentationLock.lock()
        defer { instrumentationLock.unlock() }
        return _fetchPageInvocationCount
    }

    internal var lastAsyncFetchPageRanOnMainThreadForTesting: Bool? {
        instrumentationLock.withLock {
            _lastAsyncFetchPageRanOnMainThreadForTesting
        }
    }

    internal var beforeReturningAsyncFetchPageForTesting: (@Sendable () async -> Void)? {
        get {
            instrumentationLock.withLock {
                _beforeReturningAsyncFetchPageForTesting
            }
        }
        set {
            instrumentationLock.withLock {
                _beforeReturningAsyncFetchPageForTesting = newValue
            }
        }
    }

    internal var captureJournalInvocationCount: Int {
        instrumentationLock.lock()
        defer { instrumentationLock.unlock() }
        return _captureJournalInvocationCount
    }

    public init(database: PasteBuddyDatabase) {
        self.database = database
    }

    var fileURL: URL { database.fileURL }

    func eraseSensitiveContent() throws {
        let expectedRevision = repositoryRevisionBaseline()
        try database.eraseSensitiveContent(
            validating: { db in
                try Self.validateRepositoryRevision(expectedRevision, db: db)
            },
            preservingRevision: { db in
                try db.execute(
                    sql: "INSERT INTO snapshot_metadata (key, value_json) VALUES (?, ?)",
                    arguments: ["snapshot", "PBDB-REVOKED:1"]
                )
            }
        )
        updateExpectedRepositoryRevision(nil)
    }

    func currentRevisionForAuthority() throws -> UUID? {
        try database.read { db in
            try Self.fetchMetadata(db: db).repositoryRevision
        }
    }

    func compactIfNeeded() throws -> PasteBuddyDatabase.CompactionResult {
        try database.compactIfNeeded()
    }

    func hasRevokedTombstone() throws -> Bool {
        try database.hasRevokedTombstone()
    }

    func clearRevokedTombstoneForCutover() throws {
        try database.clearRevokedTombstoneForCutover()
        updateExpectedRepositoryRevision(nil)
    }

    public func replaceAll(with snapshot: PasteBuddySnapshot) throws {
        incrementReplaceAllInvocationCount()
        let expectedRevision = repositoryRevisionBaseline()
        let newRevision = UUID()
        try database.write { db in
            try Self.validateRepositoryRevision(expectedRevision, db: db)
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
            try Self.saveMetadata(
                StoredSnapshotMetadata(snapshot: snapshot, repositoryRevision: newRevision),
                db: db
            )
        }
        updateExpectedRepositoryRevision(newRevision)
    }

    @discardableResult
    public func synchronize(with snapshot: PasteBuddySnapshot) throws -> ClipboardRepositorySyncSummary {
        incrementIncrementalSyncInvocationCount()
        let expectedRevision = repositoryRevisionBaseline()
        let newRevision = UUID()
        let summary = try database.write { db in
            try Self.validateRepositoryRevision(expectedRevision, db: db)
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

            try Self.saveMetadata(
                StoredSnapshotMetadata(snapshot: snapshot, repositoryRevision: newRevision),
                db: db
            )
            return summary
        }
        updateExpectedRepositoryRevision(newRevision)
        return summary
    }

    func updateMetadata(from snapshot: PasteBuddySnapshot) throws {
        let expectedRevision = repositoryRevisionBaseline()
        let newRevision = UUID()
        try database.write { db in
            try Self.validateRepositoryRevision(expectedRevision, db: db)
            try Self.saveMetadata(
                StoredSnapshotMetadata(snapshot: snapshot, repositoryRevision: newRevision),
                db: db
            )
        }
        updateExpectedRepositoryRevision(newRevision)
    }

    func applyCaptureJournal(
        _ journal: ClipboardRepositoryCaptureJournal,
        metadataFrom snapshot: PasteBuddySnapshot? = nil
    ) throws {
        guard !journal.isEmpty else { return }
        instrumentationLock.lock()
        _captureJournalInvocationCount += 1
        instrumentationLock.unlock()
        let expectedRevision = repositoryRevisionBaseline()
        let newRevision = UUID()
        try database.write { db in
            try Self.validateRepositoryRevision(expectedRevision, db: db)
            for mutation in journal.mutations {
                try Self.upsertCapturedItem(
                    mutation.item,
                    placement: mutation.placement,
                    db: db
                )
                try Self.deleteItems(mutation.deletedItemIDs, db: db)
                try Self.deletePinboards(mutation.deletedPinboardIDs, db: db)
                for pinboardMutation in mutation.upsertedPinboards {
                    try Self.insert(
                        pinboard: pinboardMutation.pinboard,
                        sortOrder: pinboardMutation.sortOrder,
                        db: db
                    )
                }
                for metadataMutation in mutation.updatedPinboardMetadata {
                    try Self.upsertPinboardMetadata(
                        pinboard: metadataMutation.pinboard,
                        sortOrder: metadataMutation.sortOrder,
                        db: db
                    )
                }
                for membershipMutation in mutation.frontedPinboardItems {
                    try Self.movePinboardItemToFront(
                        pinboardID: membershipMutation.pinboardID,
                        itemID: membershipMutation.itemID,
                        db: db
                    )
                }
            }
            var metadata: StoredSnapshotMetadata
            if let snapshot {
                metadata = StoredSnapshotMetadata(
                    snapshot: snapshot,
                    repositoryRevision: newRevision
                )
            } else {
                metadata = try Self.fetchMetadata(db: db)
            }
            metadata.repositoryRevision = newRevision
            try Self.saveMetadata(metadata, db: db)
        }
        updateExpectedRepositoryRevision(newRevision)
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

    private func repositoryRevisionBaseline() -> (hasLoaded: Bool, revision: UUID?) {
        instrumentationLock.lock()
        defer { instrumentationLock.unlock() }
        return (hasLoadedRepositoryRevision, expectedRepositoryRevision)
    }

    private func repositoryBaselineObservationEpoch() -> UInt64 {
        instrumentationLock.lock()
        defer { instrumentationLock.unlock() }
        return repositoryBaselineEpoch
    }

    private func updateExpectedRepositoryRevision(
        _ revision: UUID?,
        ifObservationEpochMatches expectedEpoch: UInt64? = nil
    ) {
        instrumentationLock.lock()
        if let expectedEpoch, repositoryBaselineEpoch != expectedEpoch {
            instrumentationLock.unlock()
            return
        }
        hasLoadedRepositoryRevision = true
        expectedRepositoryRevision = revision
        repositoryBaselineEpoch &+= 1
        instrumentationLock.unlock()
    }

    private static func validateRepositoryRevision(
        _ expected: (hasLoaded: Bool, revision: UUID?),
        db: Database
    ) throws {
        if !expected.hasLoaded {
            let hasStoredMetadata = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM snapshot_metadata WHERE key = ?)",
                arguments: [metadataKey]
            ) ?? false
            guard !hasStoredMetadata else {
                throw PasteBuddyPersistenceError.historyUnavailable
            }
            return
        }
        let currentRevision = try fetchMetadata(db: db).repositoryRevision
        guard currentRevision == expected.revision else {
            throw PasteBuddyPersistenceError.historyUnavailable
        }
    }

    private func writeWithRepositoryRevision<T>(
        _ updates: (Database) throws -> T
    ) throws -> T {
        let expectedRevision = repositoryRevisionBaseline()
        let newRevision = UUID()
        let result = try database.write { db in
            try Self.validateRepositoryRevision(expectedRevision, db: db)
            let result = try updates(db)
            var metadata = try Self.fetchMetadata(db: db)
            metadata.repositoryRevision = newRevision
            try Self.saveMetadata(metadata, db: db)
            return result
        }
        updateExpectedRepositoryRevision(newRevision)
        return result
    }

    private func writeWithRepositoryRevisionIfChanged(
        _ updates: (Database) throws -> Bool
    ) throws {
        let expectedRevision = repositoryRevisionBaseline()
        let newRevision = UUID()
        let didChange = try database.write { db in
            try Self.validateRepositoryRevision(expectedRevision, db: db)
            guard try updates(db) else { return false }
            var metadata = try Self.fetchMetadata(db: db)
            metadata.repositoryRevision = newRevision
            try Self.saveMetadata(metadata, db: db)
            return true
        }
        if didChange {
            updateExpectedRepositoryRevision(newRevision)
        }
    }

    @discardableResult
    public func insertOrTouchItem(_ item: ClipboardItem) throws -> ClipboardItem {
        try writeWithRepositoryRevision { db in
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
        try writeWithRepositoryRevision { db in
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
        try writeWithRepositoryRevisionIfChanged { db in
            guard var item = try Self.fetchItem(id: itemID, db: db) else { return false }
            item.payload.ocrText = text
            item.ocrState = .completed(Date())
            item.updatedAt = Date()
            let snapshotOrder = try Int.fetchOne(
                db,
                sql: "SELECT snapshot_order FROM clipboard_items WHERE id = ?",
                arguments: [itemID.uuidString]
            ) ?? 0
            try Self.upsert(item: item, snapshotOrder: snapshotOrder, db: db)
            return true
        }
    }

    public func deleteItems(_ ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try writeWithRepositoryRevisionIfChanged { db in
            guard try Self.containsAnyStoredID(ids, table: "clipboard_items", db: db) else {
                return false
            }
            try Self.deleteItems(ids, db: db)
            return true
        }
    }

    public func upsertPinboardMemberships(_ pinboards: [Pinboard]) throws {
        guard !pinboards.isEmpty else { return }
        try writeWithRepositoryRevision { db in
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
        guard !ids.isEmpty else { return }
        try writeWithRepositoryRevisionIfChanged { db in
            guard try Self.containsAnyStoredID(ids, table: "pinboards", db: db) else {
                return false
            }
            try Self.deletePinboards(ids, db: db)
            return true
        }
    }

    public func fetchPage(_ request: ClipboardItemPageRequest = ClipboardItemPageRequest()) throws -> [ClipboardItem] {
        instrumentationLock.lock()
        _fetchPageInvocationCount += 1
        instrumentationLock.unlock()
        return try database.read { db in
            try Self.fetchPage(request, db: db)
        }
    }

    public func fetchPageAsync(
        _ request: ClipboardItemPageRequest = ClipboardItemPageRequest()
    ) async throws -> [ClipboardItem] {
        instrumentationLock.withLock {
            _fetchPageInvocationCount += 1
            _lastAsyncFetchPageRanOnMainThreadForTesting = nil
        }
        let result = try await database.read { db in
            (
                items: try Self.fetchPage(request, db: db),
                ranOnMainThread: Thread.isMainThread
            )
        }
        let beforeReturning = instrumentationLock.withLock {
            _beforeReturningAsyncFetchPageForTesting
        }
        await beforeReturning?()
        try Task.checkCancellation()
        instrumentationLock.withLock {
            _lastAsyncFetchPageRanOnMainThreadForTesting = result.ranOnMainThread
        }
        return result.items
    }

    public func fetchPageAndCount(
        _ request: ClipboardItemPageRequest = ClipboardItemPageRequest()
    ) async throws -> (items: [ClipboardItem], totalCount: Int) {
        instrumentationLock.withLock {
            _fetchPageInvocationCount += 1
        }
        return try await database.read { db in
            (
                items: try Self.fetchPage(request, db: db),
                totalCount: try Self.itemCount(request, db: db)
            )
        }
    }

    public func itemCount() throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clipboard_items") ?? 0
        }
    }

    public func itemCount(_ request: ClipboardItemPageRequest) throws -> Int {
        try database.read { db in
            try Self.itemCount(request, db: db)
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

    public func hasStoredSnapshot() throws -> Bool {
        let observationEpoch = repositoryBaselineObservationEpoch()
        let result = try database.read { db in
            let exists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM snapshot_metadata WHERE key = ?)",
                arguments: [Self.metadataKey]
            ) ?? false
            let revision = exists ? try Self.fetchMetadata(db: db).repositoryRevision : nil
            return (exists, revision)
        }
        updateExpectedRepositoryRevision(result.1, ifObservationEpochMatches: observationEpoch)
        return result.0
    }

    public func exportSnapshot(hydrateAssets: Bool = true) throws -> PasteBuddySnapshot {
        let observationEpoch = repositoryBaselineObservationEpoch()
        let result = try database.read { db in
            let metadata = try Self.fetchMetadata(db: db)
            let items = try Self.fetchAllItems(db: db, hydrateAssets: hydrateAssets)
            let pinboards = try Self.fetchAllPinboards(db: db)
            return (metadata.snapshot(items: items, pinboards: pinboards), metadata.repositoryRevision)
        }
        beforeAdoptingExportRevisionForTesting?()
        updateExpectedRepositoryRevision(result.1, ifObservationEpochMatches: observationEpoch)
        return result.0
    }

    public func hydrateAssets(for item: ClipboardItem) throws -> ClipboardItem {
        try database.read { db in
            var hydratedItem = item
            try Self.hydrateAssetData(in: &hydratedItem.payload, db: db)
            hydratedItem.refreshSearchDocumentPreservingContentHash()
            return hydratedItem
        }
    }

    public func hydrateAssets(for items: [ClipboardItem]) throws -> [ClipboardItem] {
        try database.read { db in
            let assetIDs = items.flatMap { item in
                [item.payload.rtfAssetID, item.payload.imageAssetID].compactMap { $0 }
            }
            let assetsByID = try Self.fetchAssetData(ids: assetIDs, db: db)
            return items.map { item in
                let needsImageData = item.payload.imageData == nil && item.payload.imageAssetID != nil
                let needsRTFData = item.payload.rtfData == nil && item.payload.rtfAssetID != nil
                guard needsImageData || needsRTFData else { return item }
                var hydratedItem = item
                Self.hydrateAssetData(in: &hydratedItem.payload, assetsByID: assetsByID)
                hydratedItem.refreshSearchDocumentPreservingContentHash()
                return hydratedItem
            }
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
        var systemImageName: String?
        var sortOrder: Int
        var sharingJSON: String?
        var createdAt: Double
        var updatedAt: Double
        var itemIDs: [UUID]
    }

    private struct ClipboardItemQueryParts {
        var joins: [String] = []
        var predicates: [String] = []
        var arguments = StatementArguments()
    }

    private static func queryParts(for request: ClipboardItemPageRequest) -> ClipboardItemQueryParts {
        var query = ClipboardItemQueryParts()

        if let pinboardID = request.pinboardID {
            query.joins.append("JOIN pinboard_items pbi ON pbi.item_id = ci.id")
            query.predicates.append("pbi.pinboard_id = ?")
            query.arguments += [pinboardID.uuidString]
        }

        let trimmedSearch = request.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            let normalizedSearch = ClipboardItem.normalizedSearchQuery(trimmedSearch)
            let searchTerms = ClipboardItem.searchTerms(inNormalizedQuery: normalizedSearch)
            let indexedTerms = searchTerms.filter { $0.count >= 3 }
            if let ftsQuery = trigramSearchQuery(
                for: normalizedSearch,
                searchTerms: searchTerms,
                indexedTerms: indexedTerms
            ) {
                query.joins.append("JOIN clipboard_search_fts ON clipboard_search_fts.rowid = ci.rowid")
                query.predicates.append("clipboard_search_fts MATCH ?")
                query.arguments += [ftsQuery]
                for shortTerm in searchTerms where shortTerm.count < 3 {
                    query.predicates.append("INSTR(COALESCE(ci.searchable_text, ''), ?) > 0")
                    query.arguments += [shortTerm]
                }
            } else if searchTerms.count > 1 {
                for term in searchTerms {
                    query.predicates.append("INSTR(COALESCE(ci.searchable_text, ''), ?) > 0")
                    query.arguments += [term]
                }
            } else {
                query.predicates.append("INSTR(COALESCE(ci.searchable_text, ''), ?) > 0")
                query.arguments += [normalizedSearch]
            }
        }

        if let contentType = request.contentType {
            query.joins.append("JOIN item_effective_content_types iect ON iect.item_id = ci.id")
            query.predicates.append("iect.content_type = ?")
            query.arguments += [contentType.rawValue]
        }
        if let sourceAppName = request.sourceAppName?.trimmingCharacters(in: .whitespacesAndNewlines), !sourceAppName.isEmpty {
            query.predicates.append("ci.source_app_name = ?")
            query.arguments += [sourceAppName]
        }
        if let deviceName = request.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines), !deviceName.isEmpty {
            query.predicates.append("ci.device_name = ?")
            query.arguments += [deviceName]
        }
        switch request.dateFilter {
        case .any:
            break
        case .today:
            let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
            query.predicates.append("ci.created_at >= ?")
            query.arguments += [startOfDay]
        case .last7Days:
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            query.predicates.append("ci.created_at >= ?")
            query.arguments += [cutoff.timeIntervalSince1970]
        }

        return query
    }

    private static func itemCount(_ request: ClipboardItemPageRequest, db: Database) throws -> Int {
        let query = queryParts(for: request)
        let whereClause = query.predicates.isEmpty ? "" : "WHERE \(query.predicates.joined(separator: " AND "))"
        return try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*)
                FROM clipboard_items ci
                \(query.joins.joined(separator: "\n"))
                \(whereClause)
                """,
            arguments: query.arguments
        ) ?? 0
    }

    private static func fetchPage(_ request: ClipboardItemPageRequest, db: Database) throws -> [ClipboardItem] {
        let query = queryParts(for: request)
        let whereClause = query.predicates.isEmpty ? "" : "WHERE \(query.predicates.joined(separator: " AND "))"
        let orderClause = request.pinboardID == nil
            ? "ci.snapshot_order ASC, ci.id ASC"
            : "pbi.sort_order ASC, ci.id ASC"
        var arguments = query.arguments
        arguments += [request.limit, request.offset]

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT ci.*
                FROM clipboard_items ci
                \(query.joins.joined(separator: "\n"))
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
        let itemIDsByPinboard = try fetchPinboardItemIDsByPinboard(db: db)
        var records: [UUID: PinboardSyncRecord] = [:]
        for row in rows {
            let idString: String = row["id"]
            guard let id = UUID(uuidString: idString) else {
                throw PasteBuddyDatabaseError.invalidStoredUUID(idString)
            }
            records[id] = PinboardSyncRecord(
                id: id,
                name: row["name"],
                colorHex: row["color_hex"],
                systemImageName: row["system_image_name"],
                sortOrder: row["sort_order"],
                sharingJSON: row["sharing_json"],
                createdAt: row["created_at"],
                updatedAt: row["updated_at"],
                itemIDs: itemIDsByPinboard[idString] ?? []
            )
        }
        return records
    }

    private static func itemContentMatches(_ record: ItemSyncRecord, item: ClipboardItem) throws -> Bool {
        var storedItem = item
        let databasePayload = payloadForDatabase(from: item.payload)
        storedItem.payload = databasePayload
        storedItem.refreshSearchDocumentPreservingContentHash()
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
            && record.systemImageName == pinboard.systemImageName
            && record.sortOrder == sortOrder
            && record.sharingJSON == sharingJSON
            && nearlyEqual(record.createdAt, pinboard.createdAt.timeIntervalSince1970)
            && nearlyEqual(record.updatedAt, pinboard.updatedAt.timeIntervalSince1970)
            && record.itemIDs == pinboard.itemIDs
    }

    private static func nearlyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.000_001
    }

    private static func fetchAllItems(db: Database, hydrateAssets: Bool = true) throws -> [ClipboardItem] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM clipboard_items ORDER BY snapshot_order ASC"
        )
        return try items(from: rows, db: db, hydrateAssets: hydrateAssets)
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
        var payloads = try rows.map { row in
            let payloadJSON: String = row["payload_json"]
            return try JSONDecoder.pasteBuddy.decode(ClipboardPayload.self, from: Data(payloadJSON.utf8))
        }
        if hydrateAssets {
            let assetIDs = payloads.flatMap { payload in
                [payload.rtfAssetID, payload.imageAssetID].compactMap { $0 }
            }
            let assetsByID = try fetchAssetData(ids: assetIDs, db: db)
            for index in payloads.indices {
                hydrateAssetData(in: &payloads[index], assetsByID: assetsByID)
            }
        }

        return try rows.enumerated().map { index, row in
            let idString: String = row["id"]
            guard let id = UUID(uuidString: idString) else {
                throw PasteBuddyDatabaseError.invalidStoredUUID(idString)
            }
            let ocrStateJSON: String = row["ocr_state_json"]
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
                payload: payloads[index],
                ocrState: ocrState
            )
        }
    }

    private static func fetchLabelsByItemID(_ itemIDs: [String], db: Database) throws -> [String: [String]] {
        guard !itemIDs.isEmpty else { return [:] }
        var labelsByItemID: [String: [String]] = [:]
        for batch in argumentBatches(itemIDs) {
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let rows = try Row.fetchCursor(
                db,
                sql: """
                    SELECT item_id, label
                    FROM item_labels
                    WHERE item_id IN (\(placeholders))
                    ORDER BY item_id, sort_order
                    """,
                arguments: StatementArguments(batch)
            )
            while let row = try rows.next() {
                let itemID: String = row["item_id"]
                let label: String = row["label"]
                labelsByItemID[itemID, default: []].append(label)
            }
        }
        return labelsByItemID
    }

    private static func fetchAllPinboards(db: Database) throws -> [Pinboard] {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM pinboards ORDER BY sort_order ASC")
        let itemIDsByPinboard = try fetchPinboardItemIDsByPinboard(db: db)
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
            pinboards.append(Pinboard(
                id: id,
                name: row["name"],
                colorHex: row["color_hex"],
                systemImageName: row["system_image_name"],
                itemIDs: itemIDsByPinboard[idString] ?? [],
                sharing: sharing,
                createdAt: Date(timeIntervalSince1970: row["created_at"]),
                updatedAt: Date(timeIntervalSince1970: row["updated_at"])
            ))
        }
        return pinboards
    }

    private static func fetchPinboardItemIDsByPinboard(db: Database) throws -> [String: [UUID]] {
        let rows = try Row.fetchCursor(
            db,
            sql: """
                SELECT pinboard_id, item_id
                FROM pinboard_items
                ORDER BY pinboard_id, sort_order ASC
                """
        )
        var itemIDsByPinboard: [String: [UUID]] = [:]
        while let row = try rows.next() {
            let pinboardID: String = row["pinboard_id"]
            let itemIDString: String = row["item_id"]
            guard let itemID = UUID(uuidString: itemIDString) else {
                throw PasteBuddyDatabaseError.invalidStoredUUID(itemIDString)
            }
            itemIDsByPinboard[pinboardID, default: []].append(itemID)
        }
        return itemIDsByPinboard
    }

    private static func upsert(item: ClipboardItem, snapshotOrder: Int, db: Database) throws {
        let previousAssetIDs = try referencedAssetIDs(forItemIDs: [item.id], db: db)
        var storedItem = item
        let databasePayload = try strippedPayloadForDatabase(from: item.payload, db: db)
        storedItem.payload = databasePayload
        storedItem.refreshSearchDocumentPreservingContentHash()
        let payloadJSON = try jsonString(databasePayload)
        let ocrStateJSON = try jsonString(storedItem.ocrState)
        try db.execute(
            sql: """
                INSERT INTO clipboard_items (
                    id, snapshot_order, created_at, updated_at, source_app_name,
                    source_bundle_identifier, device_name, content_type, title,
                    reuse_category, dedupe_hash, payload_json, searchable_text,
                    ocr_text, ocr_state_json, byte_count, thumbnail_asset_id, full_asset_id,
                    image_asset_id, rtf_asset_id
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?)
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
                    byte_count = excluded.byte_count,
                    image_asset_id = excluded.image_asset_id,
                    rtf_asset_id = excluded.rtf_asset_id
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
                storedItem.searchDocument.storageBytes,
                storedItem.payload.imageAssetID,
                storedItem.payload.rtfAssetID
            ]
        )
        try PasteBuddyDatabase.replaceEffectiveContentTypes(
            itemID: storedItem.id.uuidString,
            contentTypes: storedItem.effectiveContentTypes,
            db: db
        )
        try replaceLabels(for: storedItem, db: db)
        try replaceSearchIndex(for: storedItem, db: db)
        try deleteUnreferencedAssets(previousAssetIDs, db: db)
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

    private struct StoredAssetData {
        var data: Data?
        var byteCount: Int?
    }

    private static func fetchAssetData(ids: [String], db: Database) throws -> [String: StoredAssetData] {
        let uniqueIDs = Array(Set(ids))
        guard !uniqueIDs.isEmpty else { return [:] }

        var assetsByID: [String: StoredAssetData] = [:]
        assetsByID.reserveCapacity(uniqueIDs.count)
        for batch in argumentBatches(uniqueIDs) {
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let rows = try Row.fetchCursor(
                db,
                sql: "SELECT id, data, byte_count FROM assets WHERE id IN (\(placeholders))",
                arguments: StatementArguments(batch)
            )
            while let row = try rows.next() {
                let id: String = row["id"]
                assetsByID[id] = StoredAssetData(
                    data: row["data"],
                    byteCount: row["byte_count"]
                )
            }
        }
        return assetsByID
    }

    private static func hydrateAssetData(
        in payload: inout ClipboardPayload,
        assetsByID: [String: StoredAssetData]
    ) {
        if payload.rtfData == nil,
           let assetID = payload.rtfAssetID,
           let asset = assetsByID[assetID] {
            payload.rtfData = asset.data
            payload.rtfByteCount = asset.byteCount
        }
        if payload.imageData == nil,
           let assetID = payload.imageAssetID,
           let asset = assetsByID[assetID] {
            payload.imageData = asset.data
            payload.imageByteCount = asset.byteCount
        }
    }

    private static func argumentBatches(_ values: [String], maximumCount: Int = 400) -> [[String]] {
        guard !values.isEmpty else { return [] }
        return stride(from: 0, to: values.count, by: maximumCount).map { start in
            Array(values[start..<min(start + maximumCount, values.count)])
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
        guard let rowID = try Int64.fetchOne(
            db,
            sql: "SELECT rowid FROM clipboard_items WHERE id = ?",
            arguments: [item.id.uuidString]
        ) else {
            throw PasteBuddyDatabaseError.missingStoredItem(item.id)
        }
        try db.execute(sql: "DELETE FROM clipboard_search_fts WHERE rowid = ?", arguments: [rowID])
        try db.execute(
            sql: """
                INSERT INTO clipboard_search_fts (rowid, item_id, searchable_text)
                VALUES (?, ?, ?)
                """,
            arguments: [
                rowID,
                item.id.uuidString,
                item.searchDocument.normalizedText
            ]
        )
    }

    private static func trigramSearchQuery(
        for normalizedQuery: String,
        searchTerms: [String],
        indexedTerms: [String]
    ) -> String? {
        guard normalizedQuery.count >= 3,
              searchTerms.count <= 1 || !indexedTerms.isEmpty else {
            return nil
        }
        let exactPhrase = ftsPhrase(normalizedQuery)
        guard searchTerms.count > 1 else { return exactPhrase }
        let allTerms = indexedTerms.map(ftsPhrase).joined(separator: " AND ")
        return "\(exactPhrase) OR (\(allTerms))"
    }

    private static func ftsPhrase(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func updateSnapshotOrder(itemID: UUID, snapshotOrder: Int, db: Database) throws {
        try db.execute(
            sql: "UPDATE clipboard_items SET snapshot_order = ? WHERE id = ?",
            arguments: [snapshotOrder, itemID.uuidString]
        )
    }

    private static func upsertCapturedItem(
        _ item: ClipboardItem,
        placement: ClipboardRepositoryItemPlacement,
        db: Database
    ) throws {
        let existingOrder = try Int.fetchOne(
            db,
            sql: "SELECT snapshot_order FROM clipboard_items WHERE id = ?",
            arguments: [item.id.uuidString]
        )
        let snapshotOrder: Int
        switch placement {
        case .front:
            snapshotOrder = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MIN(snapshot_order), 0) - 1 FROM clipboard_items"
            ) ?? -1
        case .preserve:
            snapshotOrder = try existingOrder ?? nextSnapshotOrder(db: db)
        }
        try upsert(item: item, snapshotOrder: snapshotOrder, db: db)
    }

    private static func deleteItems(_ ids: [UUID], db: Database) throws {
        guard !ids.isEmpty else { return }
        let deletedAssetIDs = try referencedAssetIDs(forItemIDs: ids, db: db)
        for batch in argumentBatches(ids.map(\.uuidString)) {
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            try db.execute(
                sql: """
                    DELETE FROM clipboard_search_fts
                    WHERE rowid IN (
                        SELECT rowid FROM clipboard_items WHERE id IN (\(placeholders))
                    )
                    """,
                arguments: StatementArguments(batch)
            )
            try db.execute(
                sql: "DELETE FROM clipboard_items WHERE id IN (\(placeholders))",
                arguments: StatementArguments(batch)
            )
        }
        try deleteUnreferencedAssets(deletedAssetIDs, db: db)
    }

    private static func containsAnyStoredID(
        _ ids: [UUID],
        table: String,
        db: Database
    ) throws -> Bool {
        guard !ids.isEmpty else { return false }
        precondition(table == "clipboard_items" || table == "pinboards")
        for batch in argumentBatches(ids.map(\.uuidString)) {
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let exists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE id IN (\(placeholders)))",
                arguments: StatementArguments(batch)
            ) ?? false
            if exists { return true }
        }
        return false
    }

    private static func referencedAssetIDs(forItemIDs ids: [UUID], db: Database) throws -> [String] {
        guard !ids.isEmpty else { return [] }
        var assetIDs: Set<String> = []
        for batch in argumentBatches(ids.map(\.uuidString)) {
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            var arguments = StatementArguments(batch)
            arguments += StatementArguments(batch)
            assetIDs.formUnion(try String.fetchAll(
                db,
                sql: """
                    SELECT image_asset_id AS asset_id
                    FROM clipboard_items
                    WHERE id IN (\(placeholders)) AND image_asset_id IS NOT NULL
                    UNION
                    SELECT rtf_asset_id AS asset_id
                    FROM clipboard_items
                    WHERE id IN (\(placeholders)) AND rtf_asset_id IS NOT NULL
                    """,
                arguments: arguments
            ))
        }
        return Array(assetIDs)
    }

    private static func deleteUnreferencedAssets(_ assetIDs: [String], db: Database) throws {
        guard !assetIDs.isEmpty else { return }
        let uniqueAssetIDs = Array(Set(assetIDs))
        for batch in argumentBatches(uniqueAssetIDs) {
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            try db.execute(sql: """
                DELETE FROM assets
                WHERE id IN (\(placeholders))
                  AND NOT EXISTS (
                    SELECT 1
                    FROM clipboard_items
                    WHERE image_asset_id = assets.id OR rtf_asset_id = assets.id
                  )
                """, arguments: StatementArguments(batch))
        }
    }

    private static func deletePinboards(_ ids: [UUID], db: Database) throws {
        guard !ids.isEmpty else { return }
        for batch in argumentBatches(ids.map(\.uuidString)) {
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            try db.execute(
                sql: "DELETE FROM pinboards WHERE id IN (\(placeholders))",
                arguments: StatementArguments(batch)
            )
        }
    }

    private static func nextSnapshotOrder(db: Database) throws -> Int {
        (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(snapshot_order), -1) + 1 FROM clipboard_items") ?? 0)
    }

    private static func nextPinboardSortOrder(db: Database) throws -> Int {
        (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM pinboards") ?? 0)
    }

    private static func insert(pinboard: Pinboard, sortOrder: Int, db: Database) throws {
        try upsertPinboardMetadata(pinboard: pinboard, sortOrder: sortOrder, db: db)
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

    private static func upsertPinboardMetadata(pinboard: Pinboard, sortOrder: Int, db: Database) throws {
        let sharingJSON = try pinboard.sharing.map(jsonString)
        try db.execute(
            sql: """
                INSERT INTO pinboards (
                    id, name, color_hex, system_image_name, sort_order, sharing_json, created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    color_hex = excluded.color_hex,
                    system_image_name = excluded.system_image_name,
                    sort_order = excluded.sort_order,
                    sharing_json = excluded.sharing_json,
                    created_at = excluded.created_at,
                    updated_at = excluded.updated_at
                """,
            arguments: [
                pinboard.id.uuidString,
                pinboard.name,
                pinboard.colorHex,
                pinboard.systemImageName,
                sortOrder,
                sharingJSON,
                pinboard.createdAt.timeIntervalSince1970,
                pinboard.updatedAt.timeIntervalSince1970
            ]
        )
    }

    private static func movePinboardItemToFront(pinboardID: UUID, itemID: UUID, db: Database) throws {
        let sortOrder = try Int.fetchOne(
            db,
            sql: "SELECT COALESCE(MIN(sort_order), 0) - 1 FROM pinboard_items WHERE pinboard_id = ?",
            arguments: [pinboardID.uuidString]
        ) ?? -1
        try db.execute(
            sql: """
                INSERT INTO pinboard_items (pinboard_id, item_id, sort_order)
                VALUES (?, ?, ?)
                ON CONFLICT(pinboard_id, item_id) DO UPDATE SET sort_order = excluded.sort_order
                """,
            arguments: [pinboardID.uuidString, itemID.uuidString, sortOrder]
        )
    }

    fileprivate static func saveMetadata(_ metadata: StoredSnapshotMetadata, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO snapshot_metadata (key, value_json)
                VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json
                """,
            arguments: [metadataKey, try jsonString(metadata)]
        )
    }

    fileprivate static func fetchMetadata(db: Database) throws -> StoredSnapshotMetadata {
        guard let value = try String.fetchOne(
            db,
            sql: "SELECT value_json FROM snapshot_metadata WHERE key = ?",
            arguments: [metadataKey]
        ) else {
            return StoredSnapshotMetadata(
                snapshot: PasteBuddySnapshot(),
                repositoryRevision: nil
            )
        }
        return try JSONDecoder.pasteBuddy.decode(StoredSnapshotMetadata.self, from: Data(value.utf8))
    }

    private static func jsonString<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder.pasteBuddy.encode(value), as: UTF8.self)
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
    private let authorityStore: HistoryPersistenceAuthorityStore
    private let fileManager: FileManager

    public init(
        snapshotStore: EncryptedSnapshotStore,
        repository: ClipboardItemRepository,
        fileManager: FileManager = .default
    ) {
        self.snapshotStore = snapshotStore
        self.repository = repository
        self.authorityStore = HistoryPersistenceAuthorityStore(snapshotURL: snapshotStore.fileURL)
        self.fileManager = fileManager
    }

    func recoverInterruptedCutover() throws -> HistoryPersistenceAuthorityRecord? {
        guard var record = try authorityStore.load(), record.phase != .stable else {
            return try authorityStore.load()
        }
        switch record.phase {
        case .preparing:
            guard let source = record.source, let target = record.target else {
                throw PasteBuddyPersistenceError.historyUnavailable
            }
            if target == .sqlite,
               source == .standardSnapshot || source == .encryptedSnapshot {
                guard try snapshotStore.currentRevisionForAuthority() == record.sourceRevision else {
                    throw PasteBuddyPersistenceError.historyUnavailable
                }
                let snapshot = try snapshotStore.load()
                _ = try repository.hasStoredSnapshot()
                try repository.replaceAll(with: snapshot)
                guard let targetRevision = try repository.currentRevisionForAuthority() else {
                    throw PasteBuddyPersistenceError.historyUnavailable
                }
                try authorityStore.recordTargetValidated(
                    epoch: record.epoch,
                    targetRevision: targetRevision
                )
                try snapshotStore.installRevokedTombstone()
                try authorityStore.recordSourceRevoked(epoch: record.epoch)
                try authorityStore.commitStable(epoch: record.epoch)
            } else if source == .sqlite, target == .encryptedSnapshot {
                _ = try repository.exportSnapshot(hydrateAssets: false)
                guard try repository.currentRevisionForAuthority() == record.sourceRevision else {
                    throw PasteBuddyPersistenceError.historyUnavailable
                }
                try snapshotStore.installRevokedTombstone()
                try authorityStore.commitStable(.sqlite)
            } else {
                throw PasteBuddyPersistenceError.historyUnavailable
            }
        case .targetValidated:
            guard let source = record.source, let target = record.target else {
                throw PasteBuddyPersistenceError.historyUnavailable
            }
            if target == .sqlite,
               source == .standardSnapshot || source == .encryptedSnapshot {
                guard try snapshotStore.currentRevisionForAuthority() == record.sourceRevision else {
                    throw PasteBuddyPersistenceError.historyUnavailable
                }
                try snapshotStore.installRevokedTombstone()
            } else if source == .sqlite, target == .encryptedSnapshot {
                _ = try repository.exportSnapshot(hydrateAssets: false)
                guard try repository.currentRevisionForAuthority() == record.sourceRevision else {
                    throw PasteBuddyPersistenceError.historyUnavailable
                }
                try repository.eraseSensitiveContent()
            } else {
                throw PasteBuddyPersistenceError.historyUnavailable
            }
            try authorityStore.recordSourceRevoked(epoch: record.epoch)
            try authorityStore.commitStable(epoch: record.epoch)
        case .sourceRevoked:
            try authorityStore.commitStable(epoch: record.epoch)
        case .stable:
            break
        }
        record = try authorityStore.load() ?? record
        return record
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
    case missingStoredItem(UUID)

    public var errorDescription: String? {
        switch self {
        case .invalidStoredUUID(let value):
            PasteBuddyLocalization.format(
                "error.database.invalid_stored_uuid",
                defaultValue: "PasteBuddy database contains an invalid UUID: %@",
                value
            )
        case .missingStoredItem(let id):
            PasteBuddyLocalization.format(
                "error.database.missing_stored_item",
                defaultValue: "PasteBuddy database could not index missing clipboard item: %@",
                id.uuidString
            )
        }
    }
}

private struct StoredSnapshotMetadata: Codable, Equatable, Sendable {
    var repositoryRevision: UUID?
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

    init(snapshot: PasteBuddySnapshot, repositoryRevision: UUID? = UUID()) {
        self.repositoryRevision = repositoryRevision
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
