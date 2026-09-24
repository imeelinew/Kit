import Foundation
import SQLite3

struct ClipboardSearchCursor: Sendable, Equatable {
    let createdAt: Date
    let rowID: Int64
}

struct ClipboardSearchPage: Sendable {
    let items: [ClipboardItem]
    let nextCursor: ClipboardSearchCursor?
}

struct SearchMetadataUpdate: Sendable {
    let id: String
    let text: String
    var retryCount = 0
}


enum ClipboardSearch {
    static func queryDatabase(
        path: String, query: String, kind: ClipboardItem.Kind?,
        stackID: ClipboardStack.ID?, after cursor: ClipboardSearchCursor?, limit: Int
    ) -> ClipboardSearchPage? {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
            let connection
        else {
            sqlite3_close_v2(connection)
            return nil
        }
        defer { sqlite3_close_v2(connection) }
        sqlite3_busy_timeout(connection, 500)

        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"
        let usesFTS = query.count >= 3
        let textCondition: String
        if query.isEmpty {
            textCondition = "1 = 1"
        } else if usesFTS {
            textCondition = """
                (i.rowid IN (SELECT rowid FROM items_fts WHERE items_fts MATCH ?)
                 OR i.custom_title LIKE ? ESCAPE '\\')
                """
        } else {
            textCondition = """
                (i.text LIKE ? ESCAPE '\\' OR i.pinyin LIKE ? ESCAPE '\\'
                 OR i.pinyin_initials LIKE ? ESCAPE '\\'
                 OR i.custom_title LIKE ? ESCAPE '\\')
                """
        }
        let kindCondition = kind == nil ? "" : " AND i.kind = ?"
        let stackJoin = stackID == nil ? "" : "JOIN stack_items si ON si.item_id = i.id"
        let stackCondition = stackID == nil ? "" : " AND si.stack_id = ?"
        let cursorCondition = cursor == nil ? "" : """
             AND (i.created_at < ? OR (i.created_at = ? AND i.rowid < ?))
            """
        let sql = """
            SELECT i.id, i.kind, i.text, i.image_path, i.created_at, i.source_app,
                   i.image_fingerprint, i.custom_title, i.rowid
            FROM items i
            \(stackJoin)
            WHERE \(textCondition)\(kindCondition)\(stackCondition)\(cursorCondition)
            ORDER BY i.created_at DESC, i.rowid DESC
            LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var parameter: Int32 = 1
        if usesFTS {
            let match = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            sqlite3_bind_text(statement, parameter, match, -1, SQLITE_TRANSIENT)
            parameter += 1
            sqlite3_bind_text(statement, parameter, pattern, -1, SQLITE_TRANSIENT)
            parameter += 1
        } else if !query.isEmpty {
            for _ in 0..<4 {
                sqlite3_bind_text(statement, parameter, pattern, -1, SQLITE_TRANSIENT)
                parameter += 1
            }
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
            sqlite3_bind_double(statement, parameter, cursor.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, parameter + 1, cursor.createdAt.timeIntervalSince1970)
            sqlite3_bind_int64(statement, parameter + 2, cursor.rowID)
            parameter += 3
        }
        sqlite3_bind_int64(statement, parameter, sqlite3_int64(limit + 1))

        var results: [(item: ClipboardItem, cursor: ClipboardSearchCursor)] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if Task.isCancelled { return nil }
            if let item = ClipboardSQLite.row(statement) {
                results.append((
                    item: item,
                    cursor: ClipboardSearchCursor(
                        createdAt: item.createdAt,
                        rowID: sqlite3_column_int64(statement, 8))))
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { return nil }
        let hasMore = results.count > limit
        if hasMore { results.removeLast() }
        return ClipboardSearchPage(
            items: results.map(\.item),
            nextCursor: hasMore ? results.last?.cursor : nil)
    }

    static func updateMetadata(
        path: String, batch: [SearchMetadataUpdate]
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
        guard sqlite3_exec(connection, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            return false
        }
        var committed = false
        defer {
            if !committed { sqlite3_exec(connection, "ROLLBACK", nil, nil, nil) }
        }
        for entry in batch {
            guard !Task.isCancelled else { return false }
            let forms = Pinyin.searchForms(for: entry.text)
            sqlite3_bind_text(update, 1, forms.full, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(update, 2, forms.initials, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(update, 3, entry.id, -1, SQLITE_TRANSIENT)
            let status = sqlite3_step(update)
            sqlite3_reset(update)
            sqlite3_clear_bindings(update)
            guard status == SQLITE_DONE else { return false }
        }
        committed = sqlite3_exec(connection, "COMMIT", nil, nil, nil) == SQLITE_OK
        return committed
    }


}
