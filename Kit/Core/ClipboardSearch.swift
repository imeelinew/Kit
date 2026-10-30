import Foundation
import SQLite3

struct ClipboardSearchCursor: Sendable, Equatable {
    let lastCopiedAt: Date
    let rowID: Int64
}

struct ClipboardSearchPage: Sendable {
    let items: [ClipboardItem]
    let nextCursor: ClipboardSearchCursor?
    /// A query that did not finish. Empty `items` with `failed == false` is a real zero-hit page.
    var failed = false
}

struct SearchMetadataUpdate: Sendable {
    let id: String
    let text: String
    var retryCount = 0
}

enum ClipboardSearch {
    /// Combine indexed hits with a filtered resident snapshot while pinyin indexing catches up
    static func query(
        path: String, query: String, kind: ClipboardItem.Kind?,
        stackID: ClipboardStack.ID?, after cursor: ClipboardSearchCursor?, limit: Int,
        includesImageText: Bool, residentItems: [ClipboardItem]
    ) -> ClipboardSearchPage? {
        guard let page = queryDatabase(
            path: path, query: query, kind: kind, stackID: stackID,
            after: cursor, limit: limit, includesImageText: includesImageText),
            !Task.isCancelled
        else { return nil }
        guard !residentItems.isEmpty else { return page }

        // Database hits are authoritative, only missing residents need literal or pinyin matching
        let databaseIDs = Set(page.items.map(\.id))
        var additions: [ClipboardItem] = []
        for item in residentItems {
            guard !Task.isCancelled else { return nil }
            if !databaseIDs.contains(item.id),
                item.matches(query, includeImageText: includesImageText)
            {
                additions.append(item)
            }
        }
        guard !Task.isCancelled else { return nil }
        guard !additions.isEmpty else { return page }
        return ClipboardSearchPage(
            items: displayOrder(page.items + additions), nextCursor: page.nextCursor)
    }

    /// One canonical order for the normal list and every search path: newest copy first.
    /// Original offsets make exact timestamp ties stable.
    static func displayOrder(_ values: [ClipboardItem]) -> [ClipboardItem] {
        values.enumerated().sorted { lhs, rhs in
            let left = lhs.element
            let right = rhs.element
            if left.lastCopiedAt != right.lastCopiedAt { return left.lastCopiedAt > right.lastCopiedAt }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    static func queryDatabase(
        path: String, query: String, kind: ClipboardItem.Kind?,
        stackID: ClipboardStack.ID?, after cursor: ClipboardSearchCursor?, limit: Int,
        includesImageText: Bool = true
    ) -> ClipboardSearchPage? {
        guard !Task.isCancelled else { return nil }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
            let connection
        else {
            ClipboardSQLite.logFailure(connection, operation: "open search database")
            sqlite3_close_v2(connection)
            return nil
        }
        defer { sqlite3_close_v2(connection) }
        sqlite3_busy_timeout(connection, 500)
        // Interrupt cancelled scans inside sqlite3_step, including no-result short queries.
        sqlite3_progress_handler(connection, 1000, { _ in Task.isCancelled ? 1 : 0 }, nil)

        let predicate = textPredicate(query: query, includesImageText: includesImageText)
        let validatesFileImageText = !includesImageText && !query.isEmpty
        let kindCondition = kind == nil ? "" : " AND i.kind = ?"
        let stackJoin = stackID == nil ? "" : "JOIN stack_items si ON si.item_id = i.id"
        let stackCondition = stackID == nil ? "" : " AND si.stack_id = ?"
        let cursorCondition = cursor == nil ? "" : """
             AND (i.created_at < ? OR (i.created_at = ? AND i.rowid < ?))
            """
        let sql = """
            SELECT i.id, i.kind, i.text, i.image_path, i.created_at, i.source_app,
                   i.image_fingerprint, i.custom_title, i.first_copied_at,
                   i.ocr_text, i.ocr_status, i.ocr_version, i.ocr_attempts, i.copy_count,
                   i.file_urls, i.file_is_image, i.rowid
            FROM items i
            \(stackJoin)
            WHERE \(predicate.sql)\(kindCondition)\(stackCondition)\(cursorCondition)
            ORDER BY i.created_at DESC, i.rowid DESC
            LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            ClipboardSQLite.logFailure(connection, operation: "prepare search")
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var parameter: Int32 = 1
        for value in predicate.bindings {
            sqlite3_bind_text(statement, parameter, value, -1, SQLITE_TRANSIENT)
            parameter += 1
        }
        if let kind {
            sqlite3_bind_text(statement, parameter, kind.rawValue, -1, SQLITE_TRANSIENT)
            parameter += 1
        }
        if let stackID {
            sqlite3_bind_text(statement, parameter, stackID.uuidString, -1, SQLITE_TRANSIENT)
            parameter += 1
        }
        if let cursor {
            sqlite3_bind_double(statement, parameter, cursor.lastCopiedAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, parameter + 1, cursor.lastCopiedAt.timeIntervalSince1970)
            sqlite3_bind_int64(statement, parameter + 2, cursor.rowID)
            parameter += 3
        }
        // OCR pinyin shares this index with paths, so disabled OCR needs candidate validation
        // Apply the page limit after validation to avoid truncating later genuine matches
        sqlite3_bind_int64(statement, parameter, validatesFileImageText ? -1 : sqlite3_int64(limit + 1))

        var results: [(item: ClipboardItem, cursor: ClipboardSearchCursor)] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if Task.isCancelled { return nil }
            if let item = ClipboardSQLite.row(statement) {
                if !validatesFileImageText || !item.fileIsImage
                    || item.matches(query, includeImageText: false)
                {
                    results.append((
                        item: item,
                        cursor: ClipboardSearchCursor(
                            lastCopiedAt: item.lastCopiedAt,
                            rowID: sqlite3_column_int64(statement, 16))))
                    if results.count > limit { break }
                }
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE || (status == SQLITE_ROW && results.count > limit) else {
            if status != SQLITE_INTERRUPT {
                ClipboardSQLite.logFailure(connection, operation: "search step")
            }
            return nil
        }
        let hasMore = results.count > limit
        if hasMore { results.removeLast() }
        return ClipboardSearchPage(
            items: results.map(\.item),
            nextCursor: hasMore ? results.last?.cursor : nil)
    }

    private static func textPredicate(
        query: String, includesImageText: Bool
    ) -> (sql: String, bindings: [String]) {
        guard !query.isEmpty else { return ("1 = 1", []) }

        let pattern = containsPattern(query)
        let usesFTS = query.count >= 3
        var contentCondition: String
        var bindings: [String] = []
        if usesFTS {
            contentCondition = "i.rowid IN (SELECT rowid FROM items_fts WHERE items_fts MATCH ?)"
            bindings.append(ftsPhrase(query))
        } else {
            contentCondition = """
                (i.text LIKE ? ESCAPE '\\' OR i.pinyin LIKE ? ESCAPE '\\'
                 OR i.pinyin_initials LIKE ? ESCAPE '\\')
                """
            bindings.append(contentsOf: [pattern, pattern, pattern])
        }
        // OCR pinyin also lives in the common text index, custom titles remain searchable
        if !includesImageText {
            contentCondition = """
                (i.kind != 'image' AND \(contentCondition))
                """
        }
        var conditions = [contentCondition]
        if includesImageText {
            let imageQuery = ClipboardImageTextRecognition.normalizedText(query)
            if usesFTS && imageQuery.count >= 3 {
                conditions.append("i.rowid IN (SELECT rowid FROM image_ocr_fts WHERE image_ocr_fts MATCH ?)")
                bindings.append(ftsPhrase(imageQuery))
            } else {
                conditions.append("i.ocr_text LIKE ? ESCAPE '\\'")
                bindings.append(containsPattern(imageQuery))
            }
        }
        conditions.append("i.custom_title LIKE ? ESCAPE '\\'")
        bindings.append(pattern)
        return ("(" + conditions.joined(separator: " OR ") + ")", bindings)
    }

    private static func containsPattern(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    private static func ftsPhrase(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func updateMetadata(
        path: String, batch: [SearchMetadataUpdate],
        makeSearchForms: @Sendable (String) -> Pinyin.SearchForms = { Pinyin.searchForms(for: $0) }
    ) -> Bool {
        var connection: OpaquePointer?
        guard
            sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
            let connection
        else {
            sqlite3_close_v2(connection)
            return false
        }
        defer { sqlite3_close_v2(connection) }
        sqlite3_busy_timeout(connection, 1000)
        var update: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                connection,
                "UPDATE items SET pinyin = ?, pinyin_initials = ? WHERE id = ?", -1, &update,
                nil) == SQLITE_OK,
            let update
        else {
            sqlite3_finalize(update)
            return false
        }
        defer { sqlite3_finalize(update) }
        // Compute without a write transaction, then autocommit each row independently
        // A failed or cancelled batch can be replayed because these updates are idempotent
        for entry in batch {
            guard !Task.isCancelled else { return false }
            let forms = makeSearchForms(entry.text)
            guard !Task.isCancelled else { return false }
            sqlite3_bind_text(update, 1, forms.full, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(update, 2, forms.initials, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(update, 3, entry.id, -1, SQLITE_TRANSIENT)
            let status = sqlite3_step(update)
            sqlite3_reset(update)
            sqlite3_clear_bindings(update)
            guard status == SQLITE_DONE else { return false }
        }
        return !Task.isCancelled
    }
}
