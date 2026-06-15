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
                    dedupe_hash TEXT NOT NULL UNIQUE,
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
        return migrator
    }
}

public final class ClipboardItemRepository: @unchecked Sendable {
    private static let metadataKey = "snapshot"
    private let database: PasteBuddyDatabase

    public init(database: PasteBuddyDatabase) {
        self.database = database
    }

    public func replaceAll(with snapshot: PasteBuddySnapshot) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM clipboard_search_fts")
            try db.execute(sql: "DELETE FROM pinboard_items")
            try db.execute(sql: "DELETE FROM pinboards")
            try db.execute(sql: "DELETE FROM item_labels")
            try db.execute(sql: "DELETE FROM clipboard_items")

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
        return try items(from: rows, db: db)
    }

    private static func fetchAllItems(db: Database) throws -> [ClipboardItem] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM clipboard_items ORDER BY snapshot_order ASC"
        )
        return try items(from: rows, db: db)
    }

    private static func fetchItem(id: UUID, db: Database) throws -> ClipboardItem? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM clipboard_items WHERE id = ?",
            arguments: [id.uuidString]
        ) else {
            return nil
        }
        return try items(from: [row], db: db).first
    }

    private static func items(from rows: [Row], db: Database) throws -> [ClipboardItem] {
        let itemIDs = rows.compactMap { row -> String? in row["id"] }
        let labelsByItemID = try fetchLabelsByItemID(itemIDs, db: db)
        return try rows.map { row in
            let idString: String = row["id"]
            guard let id = UUID(uuidString: idString) else {
                throw PasteBuddyDatabaseError.invalidStoredUUID(idString)
            }
            let payloadJSON: String = row["payload_json"]
            let ocrStateJSON: String = row["ocr_state_json"]
            let payload = try JSONDecoder.pasteBuddy.decode(ClipboardPayload.self, from: Data(payloadJSON.utf8))
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
        let payloadJSON = try jsonString(item.payload)
        let ocrStateJSON = try jsonString(item.ocrState)
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
                item.id.uuidString,
                snapshotOrder,
                item.createdAt.timeIntervalSince1970,
                item.updatedAt.timeIntervalSince1970,
                item.sourceAppName,
                item.sourceBundleIdentifier,
                item.deviceName,
                item.contentType.rawValue,
                item.title,
                item.reuseCategory.rawValue,
                item.searchDocument.dedupeHash,
                payloadJSON,
                item.searchDocument.normalizedText,
                item.payload.ocrText,
                ocrStateJSON,
                item.searchDocument.storageBytes
            ]
        )
        try replaceLabels(for: item, db: db)
        try replaceSearchIndex(for: item, db: db)
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
        let terms = query
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).replacingOccurrences(of: "\"", with: "\"\"") }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        return terms.map { "\"\($0)\"" }.joined(separator: " ")
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

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func estimatedStorageBytes(for item: ClipboardItem) -> Int {
        var estimatedBytes = 256
        estimatedBytes += item.title.utf8.count
        estimatedBytes += item.sourceAppName.utf8.count
        estimatedBytes += item.deviceName.utf8.count
        estimatedBytes += item.contentType.rawValue.utf8.count
        estimatedBytes += item.labels.reduce(0) { $0 + $1.utf8.count }
        estimatedBytes += item.reuseCategory.rawValue.utf8.count
        estimatedBytes += item.payload.text?.utf8.count ?? 0
        estimatedBytes += item.payload.htmlString?.utf8.count ?? 0
        estimatedBytes += item.payload.rtfData?.count ?? 0
        estimatedBytes += item.payload.urlString?.utf8.count ?? 0
        estimatedBytes += item.payload.allFileURLStrings.reduce(0) { $0 + $1.utf8.count }
        estimatedBytes += item.payload.imageData?.count ?? 0
        estimatedBytes += item.payload.ocrText?.utf8.count ?? 0
        return estimatedBytes
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
