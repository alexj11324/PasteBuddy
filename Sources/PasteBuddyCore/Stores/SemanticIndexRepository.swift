import Foundation
import GRDB
#if canImport(Accelerate)
import Accelerate
#endif

public struct SemanticIndexJob: Equatable, Sendable {
    public var id: String
    public var itemID: UUID
    public var contentHash: String
    public var attemptCount: Int
    public var generation: Int
}

public final class SemanticIndexRepository: @unchecked Sendable {
    private let database: PasteBuddyDatabase

    public init(database: PasteBuddyDatabase) {
        self.database = database
    }

    public func statistics() throws -> SemanticIndexStatistics {
        try database.read { db in
            SemanticIndexStatistics(
                totalEligible: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clipboard_items") ?? 0,
                ready: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM semantic_index_documents WHERE status = ?", arguments: [SemanticIndexState.ready.rawValue]) ?? 0,
                queued: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM semantic_index_outbox WHERE state IN (?, ?)", arguments: [SemanticIndexState.queued.rawValue, SemanticIndexState.indexing.rawValue]) ?? 0,
                failed: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM semantic_index_documents WHERE status = ?", arguments: [SemanticIndexState.failed.rawValue]) ?? 0,
                suppressed: (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM semantic_index_suppressions") ?? 0)
                    + (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM semantic_index_documents WHERE status = ?", arguments: [SemanticIndexState.excluded.rawValue]) ?? 0)
            )
        }
    }

    public func enqueueBackfill() throws {
        let now = Date().timeIntervalSince1970
        try database.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO semantic_index_outbox(
                    id, item_id, content_hash, priority, state, attempt_count,
                    next_attempt_at, created_at, updated_at
                )
                SELECT lower(hex(randomblob(16))), ci.id, ci.dedupe_hash,
                       CAST(ci.created_at AS INTEGER), ?, 0, ?, ?, ?
                FROM clipboard_items ci
                LEFT JOIN semantic_index_documents sid ON sid.item_id = ci.id
                LEFT JOIN semantic_index_suppressions sis ON sis.item_id = ci.id
                WHERE sis.item_id IS NULL
                  AND (sid.item_id IS NULL OR sid.content_hash <> ci.dedupe_hash)
                """, arguments: [SemanticIndexState.queued.rawValue, now, now, now])
        }
    }

    public func retryFailures() throws {
        let now = Date().timeIntervalSince1970
        try database.write { db in
            try db.execute(sql: """
                UPDATE semantic_index_outbox
                SET state = ?, next_attempt_at = ?, updated_at = ?
                WHERE state = ?
                """, arguments: [
                    SemanticIndexState.queued.rawValue, now, now, SemanticIndexState.failed.rawValue
                ])
        }
    }

    @discardableResult
    public func enqueue(itemID: UUID, contentHash: String, priority: Int = 0) throws -> UUID? {
        try database.write { db in
            let suppressed = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM semantic_index_suppressions WHERE item_id = ?)",
                arguments: [itemID.uuidString]
            ) ?? false
            guard !suppressed else { return nil }
            let id = UUID()
            let now = Date().timeIntervalSince1970
            try db.execute(sql: """
                INSERT INTO semantic_index_outbox(
                    id, item_id, content_hash, priority, state, attempt_count,
                    next_attempt_at, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?)
                ON CONFLICT(item_id, content_hash) DO UPDATE SET
                    priority = MAX(priority, excluded.priority),
                    state = ?,
                    next_attempt_at = excluded.next_attempt_at,
                    updated_at = excluded.updated_at
                """, arguments: [
                    id.uuidString, itemID.uuidString, contentHash, priority,
                    SemanticIndexState.queued.rawValue, now, now, now,
                    SemanticIndexState.queued.rawValue
                ])
            return id
        }
    }

    public func nextJobs(limit: Int = 2, now: Date = Date()) throws -> [SemanticIndexJob] {
        try database.write { db in
            let generation = try Self.currentGeneration(db)
            try db.execute(sql: """
                UPDATE semantic_index_outbox
                SET state = ?, next_attempt_at = ?, updated_at = ?
                WHERE state = ? AND updated_at <= ?
                """, arguments: [
                    SemanticIndexState.queued.rawValue,
                    now.timeIntervalSince1970,
                    now.timeIntervalSince1970,
                    SemanticIndexState.indexing.rawValue,
                    now.addingTimeInterval(-5 * 60).timeIntervalSince1970
                ])
            let rows = try Row.fetchAll(db, sql: """
                SELECT sio.id, sio.item_id, sio.content_hash, sio.attempt_count
                FROM semantic_index_outbox sio
                JOIN clipboard_items ci ON ci.id = sio.item_id
                LEFT JOIN semantic_index_suppressions sis ON sis.item_id = sio.item_id
                WHERE sio.state IN (?, ?)
                  AND sio.next_attempt_at <= ?
                  AND sis.item_id IS NULL
                ORDER BY sio.priority DESC, ci.created_at DESC
                LIMIT ?
                """, arguments: [SemanticIndexState.queued.rawValue, SemanticIndexState.failed.rawValue, now.timeIntervalSince1970, min(max(limit, 1), 16)])
            var jobs: [SemanticIndexJob] = []
            for row in rows {
                let idString: String = row["id"]
                let itemIDString: String = row["item_id"]
                let contentHash: String = row["content_hash"]
                let attemptCount: Int = row["attempt_count"]
                guard let itemID = UUID(uuidString: itemIDString) else { continue }
                try db.execute(
                    sql: "UPDATE semantic_index_outbox SET state = ?, updated_at = ? WHERE id = ?",
                    arguments: [SemanticIndexState.indexing.rawValue, now.timeIntervalSince1970, idString]
                )
                jobs.append(SemanticIndexJob(
                    id: idString,
                    itemID: itemID,
                    contentHash: contentHash,
                    attemptCount: attemptCount,
                    generation: generation
                ))
            }
            return jobs
        }
    }

    public func commit(
        document: SemanticIndexDocument,
        embedding: SemanticEmbedding,
        jobID: String,
        expectedGeneration: Int
    ) throws {
        guard embedding.id == document.itemID,
              !embedding.values.isEmpty,
              embedding.values.count <= 8_192,
              embedding.values.allSatisfy({ $0.isFinite && Float16($0).isFinite }) else {
            throw SemanticIndexError.malformedProviderResponse
        }
        let halfValues = embedding.values.map(Float16.init)
        let blob = halfValues.withUnsafeBufferPointer { buffer -> Data in
            guard let address = buffer.baseAddress else { return Data() }
            return Data(bytes: address, count: buffer.count * MemoryLayout<Float16>.stride)
        }
        try database.write { db in
            if try Self.currentGeneration(db) != expectedGeneration
                || !Self.isActiveJob(
                    db,
                    jobID: jobID,
                    itemID: document.itemID,
                    contentHash: document.contentHash
                ) {
                return
            }
            guard let currentHash = try String.fetchOne(db, sql: "SELECT dedupe_hash FROM clipboard_items WHERE id = ?", arguments: [document.itemID.uuidString]),
                  currentHash == document.contentHash else {
                try db.execute(sql: "DELETE FROM semantic_index_outbox WHERE id = ?", arguments: [jobID])
                return
            }
            try db.execute(sql: """
                INSERT INTO semantic_index_documents(
                    item_id, content_hash, modality, summary, keywords_json,
                    aliases_json, entities_json, visual_text_hints_json,
                    search_intents_json, language, model_name, prompt_version,
                    status, indexed_at, last_error_code
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                ON CONFLICT(item_id) DO UPDATE SET
                    content_hash = excluded.content_hash,
                    modality = excluded.modality,
                    summary = excluded.summary,
                    keywords_json = excluded.keywords_json,
                    aliases_json = excluded.aliases_json,
                    entities_json = excluded.entities_json,
                    visual_text_hints_json = excluded.visual_text_hints_json,
                    search_intents_json = excluded.search_intents_json,
                    language = excluded.language,
                    model_name = excluded.model_name,
                    prompt_version = excluded.prompt_version,
                    status = excluded.status,
                    indexed_at = excluded.indexed_at,
                    last_error_code = NULL
                """, arguments: [
                    document.itemID.uuidString, document.contentHash, document.modality.rawValue,
                    document.summary, try Self.json(document.keywords), try Self.json(document.aliases),
                    try Self.json(document.entities), try Self.json(document.visualTextHints),
                    try Self.json(document.searchIntents), document.language, document.modelName,
                    document.promptVersion, SemanticIndexState.ready.rawValue,
                    document.indexedAt.timeIntervalSince1970
                ])
            try db.execute(sql: """
                INSERT INTO semantic_index_embeddings(item_id, model_name, dimensions, vector_blob, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(item_id) DO UPDATE SET
                    model_name = excluded.model_name,
                    dimensions = excluded.dimensions,
                    vector_blob = excluded.vector_blob,
                    updated_at = excluded.updated_at
                """, arguments: [document.itemID.uuidString, embedding.modelName, halfValues.count, blob, document.indexedAt.timeIntervalSince1970])
            try db.execute(sql: "DELETE FROM semantic_index_fts WHERE item_id = ?", arguments: [document.itemID.uuidString])
            try db.execute(sql: """
                INSERT INTO semantic_index_fts(
                    item_id, summary, keywords, aliases, entities, visual_text_hints, search_intents
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    document.itemID.uuidString, document.summary,
                    document.keywords.joined(separator: " "), document.aliases.joined(separator: " "),
                    document.entities.joined(separator: " "), document.visualTextHints.joined(separator: " "),
                    document.searchIntents.joined(separator: " ")
                ])
            try db.execute(sql: "DELETE FROM semantic_index_outbox WHERE id = ?", arguments: [jobID])
        }
    }

    public func markFailed(job: SemanticIndexJob, errorCode: String, now: Date = Date()) throws {
        let nextAttempt = now.addingTimeInterval(min(pow(2, Double(job.attemptCount + 1)) * 30, 6 * 60 * 60))
        try database.write { db in
            guard try Self.currentGeneration(db) == job.generation,
                  try Self.isActiveJob(db, job: job) else { return }
            try db.execute(sql: """
                INSERT INTO semantic_index_documents(
                    item_id, content_hash, modality, summary, keywords_json, aliases_json,
                    entities_json, visual_text_hints_json, search_intents_json, model_name,
                    prompt_version, status, last_error_code
                ) VALUES (?, ?, ?, '', '[]', '[]', '[]', '[]', '[]', '', '', ?, ?)
                ON CONFLICT(item_id) DO UPDATE SET status = excluded.status, last_error_code = excluded.last_error_code
                """, arguments: [job.itemID.uuidString, job.contentHash, SemanticIndexModality.mixed.rawValue, SemanticIndexState.failed.rawValue, errorCode])
            try db.execute(sql: """
                UPDATE semantic_index_outbox
                SET state = ?, attempt_count = attempt_count + 1, next_attempt_at = ?, updated_at = ?
                WHERE id = ?
                """, arguments: [SemanticIndexState.failed.rawValue, nextAttempt.timeIntervalSince1970, now.timeIntervalSince1970, job.id])
        }
    }

    public func discard(job: SemanticIndexJob, errorCode: String) throws {
        try database.write { db in
            guard try Self.currentGeneration(db) == job.generation,
                  try Self.isActiveJob(db, job: job) else { return }
            try db.execute(sql: "DELETE FROM semantic_index_fts WHERE item_id = ?", arguments: [job.itemID.uuidString])
            try db.execute(sql: "DELETE FROM semantic_index_embeddings WHERE item_id = ?", arguments: [job.itemID.uuidString])
            try db.execute(sql: """
                INSERT INTO semantic_index_documents(
                    item_id, content_hash, modality, summary, keywords_json, aliases_json,
                    entities_json, visual_text_hints_json, search_intents_json, model_name,
                    prompt_version, status, last_error_code
                ) VALUES (?, ?, ?, '', '[]', '[]', '[]', '[]', '[]', '', '', ?, ?)
                ON CONFLICT(item_id) DO UPDATE SET status = excluded.status, last_error_code = excluded.last_error_code
                """, arguments: [job.itemID.uuidString, job.contentHash, SemanticIndexModality.mixed.rawValue, SemanticIndexState.excluded.rawValue, errorCode])
            try db.execute(sql: "DELETE FROM semantic_index_outbox WHERE id = ?", arguments: [job.id])
        }
    }

    public func discardStale(job: SemanticIndexJob) throws {
        try database.write { db in
            guard try Self.currentGeneration(db) == job.generation else { return }
            try db.execute(sql: "DELETE FROM semantic_index_outbox WHERE id = ?", arguments: [job.id])
        }
    }

    public func suppress(itemID: UUID, reason: String = "user_removed") throws {
        try database.write { db in
            let now = Date().timeIntervalSince1970
            try db.execute(sql: "INSERT OR REPLACE INTO semantic_index_suppressions(item_id, reason, created_at) VALUES (?, ?, ?)", arguments: [itemID.uuidString, reason, now])
            try db.execute(sql: "DELETE FROM semantic_index_fts WHERE item_id = ?", arguments: [itemID.uuidString])
            try db.execute(sql: "DELETE FROM semantic_index_embeddings WHERE item_id = ?", arguments: [itemID.uuidString])
            try db.execute(sql: "DELETE FROM semantic_index_documents WHERE item_id = ?", arguments: [itemID.uuidString])
            try db.execute(sql: "DELETE FROM semantic_index_outbox WHERE item_id = ?", arguments: [itemID.uuidString])
        }
    }

    public func reindex(itemID: UUID, contentHash: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM semantic_index_suppressions WHERE item_id = ?", arguments: [itemID.uuidString])
        }
        _ = try enqueue(itemID: itemID, contentHash: contentHash, priority: Int.max)
    }

    public func isSuppressed(itemID: UUID) throws -> Bool {
        try database.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM semantic_index_suppressions WHERE item_id = ?)", arguments: [itemID.uuidString]) ?? false
        }
    }

    public func deleteAll() throws {
        try database.write { db in
            try Self.advanceGeneration(db)
            try db.execute(sql: "DELETE FROM semantic_index_fts")
            try db.execute(sql: "DELETE FROM semantic_index_embeddings")
            try db.execute(sql: "DELETE FROM semantic_index_documents")
            try db.execute(sql: "DELETE FROM semantic_index_outbox")
            try db.execute(sql: "DELETE FROM semantic_query_embeddings")
            try db.execute(sql: "DELETE FROM semantic_index_suppressions")
        }
    }

    public func resetForRebuild() throws {
        try database.write { db in
            try Self.advanceGeneration(db)
            try db.execute(sql: "DELETE FROM semantic_index_fts")
            try db.execute(sql: "DELETE FROM semantic_index_embeddings")
            try db.execute(sql: "DELETE FROM semantic_index_documents")
            try db.execute(sql: "DELETE FROM semantic_index_outbox")
            try db.execute(sql: "DELETE FROM semantic_query_embeddings")
        }
    }

    public func semanticRankedItemIDs(request: SemanticSearchRequest, queryEmbedding: SemanticEmbedding) throws -> [(UUID, Double)] {
        guard !queryEmbedding.values.isEmpty else { return [] }
        if request.allowedItemIDs?.isEmpty == true { return [] }
        return try database.read { db in
            var joins = ["JOIN semantic_index_embeddings sie ON sie.item_id = ci.id"]
            var predicates = ["sid.status = ?", "sie.model_name = ?"]
            var arguments: StatementArguments = [SemanticIndexState.ready.rawValue, queryEmbedding.modelName]
            if let pinboardID = request.pinboardID {
                joins.append("JOIN pinboard_items pbi ON pbi.item_id = ci.id")
                predicates.append("pbi.pinboard_id = ?")
                arguments += [pinboardID.uuidString]
            }
            if let type = request.contentType {
                predicates.append("INSTR(ci.effective_content_types, ?) > 0")
                arguments += [",\(type.rawValue),"]
            }
            if let source = request.sourceAppName, !source.isEmpty {
                predicates.append("ci.source_app_name = ?")
                arguments += [source]
            }
            if let device = request.deviceName, !device.isEmpty {
                predicates.append("ci.device_name = ?")
                arguments += [device]
            }
            switch request.dateFilter {
            case .any:
                break
            case .today:
                predicates.append("ci.created_at >= ?")
                arguments += [Calendar.current.startOfDay(for: Date()).timeIntervalSince1970]
            case .last7Days:
                arguments += [Calendar.current.date(byAdding: .day, value: -7, to: Date())?.timeIntervalSince1970 ?? 0]
                predicates.append("ci.created_at >= ?")
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT ci.id, sie.dimensions, sie.vector_blob
                FROM clipboard_items ci
                JOIN semantic_index_documents sid ON sid.item_id = ci.id
                \(joins.joined(separator: "\n"))
                WHERE \(predicates.joined(separator: " AND "))
                """, arguments: arguments)
            return rows.compactMap { row -> (UUID, Double)? in
                let idString: String = row["id"]
                let dimensions: Int = row["dimensions"]
                let blob: Data = row["vector_blob"]
                guard let id = UUID(uuidString: idString),
                      request.allowedItemIDs?.contains(id) != false,
                      dimensions == queryEmbedding.values.count else { return nil }
                let vector = Self.floatVector(from: blob, dimensions: dimensions)
                guard vector.count == dimensions, vector.allSatisfy({ $0.isFinite }) else { return nil }
                return (id, Self.cosine(queryEmbedding.values, vector))
            }
            .sorted { $0.1 > $1.1 }
            .prefix(request.limit)
            .map { $0 }
        }
    }

    private static func currentGeneration(_ db: Database) throws -> Int {
        try Int.fetchOne(
            db,
            sql: "SELECT integer_value FROM semantic_index_control WHERE key = 'generation'"
        ) ?? 0
    }

    private static func advanceGeneration(_ db: Database) throws {
        try db.execute(sql: """
            UPDATE semantic_index_control
            SET integer_value = integer_value + 1
            WHERE key = 'generation'
            """)
    }

    private static func isActiveJob(_ db: Database, job: SemanticIndexJob) throws -> Bool {
        try isActiveJob(
            db,
            jobID: job.id,
            itemID: job.itemID,
            contentHash: job.contentHash
        )
    }

    private static func isActiveJob(
        _ db: Database,
        jobID: String,
        itemID: UUID,
        contentHash: String
    ) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(
                SELECT 1
                FROM semantic_index_outbox sio
                WHERE sio.id = ?
                  AND sio.item_id = ?
                  AND sio.content_hash = ?
                  AND NOT EXISTS (
                      SELECT 1
                      FROM semantic_index_suppressions sis
                      WHERE sis.item_id = sio.item_id
                  )
            )
            """, arguments: [jobID, itemID.uuidString, contentHash]) == true
    }

    public func semanticLexicalItemIDs(request: SemanticSearchRequest) throws -> [UUID] {
        guard let matchQuery = Self.ftsMatchQuery(request.query) else { return [] }
        if request.allowedItemIDs?.isEmpty == true { return [] }
        return try database.read { db in
            var joins: [String] = []
            var predicates = ["sid.status = ?", "semantic_index_fts MATCH ?"]
            var arguments: StatementArguments = [SemanticIndexState.ready.rawValue, matchQuery]
            if let pinboardID = request.pinboardID {
                joins.append("JOIN pinboard_items pbi ON pbi.item_id = ci.id")
                predicates.append("pbi.pinboard_id = ?")
                arguments += [pinboardID.uuidString]
            }
            if let type = request.contentType {
                predicates.append("INSTR(ci.effective_content_types, ?) > 0")
                arguments += [",\(type.rawValue),"]
            }
            if let source = request.sourceAppName, !source.isEmpty {
                predicates.append("ci.source_app_name = ?")
                arguments += [source]
            }
            if let device = request.deviceName, !device.isEmpty {
                predicates.append("ci.device_name = ?")
                arguments += [device]
            }
            switch request.dateFilter {
            case .any:
                break
            case .today:
                predicates.append("ci.created_at >= ?")
                arguments += [Calendar.current.startOfDay(for: Date()).timeIntervalSince1970]
            case .last7Days:
                predicates.append("ci.created_at >= ?")
                arguments += [Calendar.current.date(byAdding: .day, value: -7, to: Date())?.timeIntervalSince1970 ?? 0]
            }
            let limitClause: String
            if request.allowedItemIDs == nil {
                arguments += [request.limit]
                limitClause = "LIMIT ?"
            } else {
                limitClause = ""
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT ci.id
                FROM semantic_index_fts
                JOIN semantic_index_documents sid ON sid.item_id = semantic_index_fts.item_id
                JOIN clipboard_items ci ON ci.id = sid.item_id
                \(joins.joined(separator: "\n"))
                WHERE \(predicates.joined(separator: " AND "))
                ORDER BY bm25(semantic_index_fts)
                \(limitClause)
                """, arguments: arguments)
            return rows.compactMap { row -> UUID? in
                let value: String = row["id"]
                guard let id = UUID(uuidString: value),
                      request.allowedItemIDs?.contains(id) != false else { return nil }
                return id
            }.prefix(request.limit).map { $0 }
        }
    }

    public func cachedQueryEmbedding(queryHash: String, now: Date = Date()) throws -> SemanticEmbedding? {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM semantic_query_embeddings WHERE query_hash = ? AND expires_at > ?", arguments: [queryHash, now.timeIntervalSince1970]) else { return nil }
            let dimensions: Int = row["dimensions"]
            let blob: Data = row["vector_blob"]
            let values = Self.floatVector(from: blob, dimensions: dimensions)
            guard !values.isEmpty, values.allSatisfy({ $0.isFinite }) else { return nil }
            return SemanticEmbedding(id: UUID(), modelName: row["model_name"], values: values)
        }
    }

    public func cacheQueryEmbedding(_ embedding: SemanticEmbedding, queryHash: String, now: Date = Date()) throws {
        guard !embedding.values.isEmpty,
              embedding.values.count <= 8_192,
              embedding.values.allSatisfy({ $0.isFinite && Float16($0).isFinite }) else {
            throw SemanticIndexError.malformedProviderResponse
        }
        let halfValues = embedding.values.map(Float16.init)
        let blob = halfValues.withUnsafeBufferPointer { buffer -> Data in
            guard let address = buffer.baseAddress else { return Data() }
            return Data(bytes: address, count: buffer.count * MemoryLayout<Float16>.stride)
        }
        try database.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO semantic_query_embeddings(
                    query_hash, model_name, dimensions, vector_blob, last_used_at, expires_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [queryHash, embedding.modelName, halfValues.count, blob, now.timeIntervalSince1970, now.addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970])
            try db.execute(sql: "DELETE FROM semantic_query_embeddings WHERE expires_at <= ?", arguments: [now.timeIntervalSince1970])
            try db.execute(sql: """
                DELETE FROM semantic_query_embeddings
                WHERE query_hash NOT IN (
                    SELECT query_hash FROM semantic_query_embeddings ORDER BY last_used_at DESC LIMIT 500
                )
                """)
        }
    }

    private static func floatVector(from data: Data, dimensions: Int) -> [Float] {
        guard data.count == dimensions * MemoryLayout<Float16>.stride else { return [] }
        return data.withUnsafeBytes { rawBuffer in
            let values = rawBuffer.bindMemory(to: Float16.self)
            return values.map(Float.init)
        }
    }

    private static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -1 }
        #if canImport(Accelerate)
        let dot = Double(vDSP.dot(lhs, rhs))
        let lhsMagnitude = Double(vDSP.sumOfSquares(lhs))
        let rhsMagnitude = Double(vDSP.sumOfSquares(rhs))
        #else
        var dot: Double = 0
        var lhsMagnitude: Double = 0
        var rhsMagnitude: Double = 0
        for (left, right) in zip(lhs, rhs) {
            let leftValue = Double(left)
            let rightValue = Double(right)
            dot += leftValue * rightValue
            lhsMagnitude += leftValue * leftValue
            rhsMagnitude += rightValue * rightValue
        }
        #endif
        guard lhsMagnitude > 0, rhsMagnitude > 0 else { return -1 }
        return dot / (sqrt(lhsMagnitude) * sqrt(rhsMagnitude))
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder.pasteBuddy.encode(value), as: UTF8.self)
    }

    private static func ftsMatchQuery(_ rawQuery: String) -> String? {
        let terms = rawQuery
            .split { $0.isWhitespace || $0.isPunctuation }
            .map(String.init)
            .filter { $0.count >= 3 }
            .prefix(12)
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
        guard !terms.isEmpty else { return nil }
        return terms.joined(separator: " OR ")
    }
}
