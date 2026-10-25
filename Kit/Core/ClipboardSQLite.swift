import Foundation
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum ClipboardSQLite {
    static func transaction(in db: OpaquePointer?, _ body: () -> Bool) -> Bool {
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return false }
        if body(), sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK { return true }
        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        return false
    }

    static func prepareSchema(in db: OpaquePointer) -> Bool {
        Schema(database: db).prepare()
    }

    static func bindText(_ text: String?, to stmt: OpaquePointer, at index: Int32) {
        sqlite3_bind_text(stmt, index, text, text.map { Int32($0.utf8.count) } ?? 0, SQLITE_TRANSIENT)
    }

    static func row(_ stmt: OpaquePointer?) -> ClipboardItem? {
        guard let stmt, let idString = columnString(stmt, 0),
            let id = UUID(uuidString: idString),
            let kindString = columnString(stmt, 1),
            let storedKind = ClipboardItem.Kind(rawValue: kindString)
        else { return nil }
        let imagePath = columnString(stmt, 3)
        guard let fileURLs = decodeFileURLs(
            columnString(stmt, 14), kind: storedKind, imagePath: imagePath)
        else { return nil }
        let imageOCR: ClipboardImageOCR?
        if let status = columnString(stmt, 10).flatMap(ClipboardImageOCR.Status.init(rawValue:)) {
            imageOCR = ClipboardImageOCR(
                text: columnString(stmt, 9), status: status,
                version: Int(sqlite3_column_int(stmt, 11)),
                attempts: Int(sqlite3_column_int(stmt, 12)))
        } else {
            imageOCR = nil
        }
        return ClipboardItem(
            id: id, kind: storedKind, text: columnString(stmt, 2), imagePath: imagePath,
            imageFingerprint: columnString(stmt, 6),
            fileURLs: fileURLs,
            lastCopiedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
            sourceBundleID: columnString(stmt, 5), customTitle: columnString(stmt, 7),
            firstCopiedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)),
            copyCount: Int(sqlite3_column_int64(stmt, 13)),
            imageOCR: imageOCR)
    }

    static func encodedFileURLs(_ urls: [URL]) -> String? {
        guard let data = try? JSONEncoder().encode(urls.map(\.absoluteString)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeFileURLs(
        _ raw: String?, kind: ClipboardItem.Kind, imagePath: String?
    ) -> [URL]? {
        guard let raw else { return kind == .file ? nil : [] }
        guard let data = raw.data(using: .utf8),
            let values = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }
        var urls: [URL] = []
        urls.reserveCapacity(values.count)
        for value in values {
            guard let url = URL(string: value), url.isFileURL else { return nil }
            urls.append(url.standardizedFileURL)
        }
        if kind == .file {
            return urls.isEmpty ? nil : urls
        }
        if kind == .image, imagePath == nil {
            return urls.count == 1 ? urls : nil
        }
        if !urls.isEmpty { return nil }
        return urls
    }

    static func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return String(decoding: UnsafeBufferPointer(start: ptr, count: count), as: UTF8.self)
    }
}

extension ClipboardSQLite {
    private struct Schema {
        let database: OpaquePointer

        func prepare() -> Bool {
            execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=1000;")
                && execute(Self.coreSchema)
                && migrateCopyMetadata()
                && migrateFileURLs()
                && execute(Self.fileURLsSchema)
                && execute(Self.searchSchema)
                && migrateImageSearch()
        }

        /// The legacy created_at column stores the most recent copy time
        /// Older first-copy times and copy counts cannot be reconstructed
        private func migrateCopyMetadata() -> Bool {
            migrateColumns([
                ("first_copied_at", "REAL"), ("copy_count", "INTEGER NOT NULL DEFAULT 1"),
            ]) {
                execute("UPDATE items SET first_copied_at = created_at WHERE first_copied_at IS NULL")
            }
        }

        private func migrateImageSearch() -> Bool {
            migrateColumns([
                ("ocr_text", "TEXT"), ("ocr_status", "TEXT"), ("ocr_version", "INTEGER"),
                ("ocr_attempts", "INTEGER NOT NULL DEFAULT 0"),
            ]) {
                guard execute(Self.imageSearchSchema) else { return false }
                // Keep prior searchable text until the newer recognizer replaces it in the background
                return execute("""
                    UPDATE items SET ocr_status = NULL, ocr_version = NULL, ocr_attempts = 0
                    WHERE kind = 'image' AND image_path IS NOT NULL
                      AND ocr_version IS NOT NULL
                      AND ocr_version != \(ClipboardImageTextRecognition.version)
                    """)
            }
        }

        private func migrateFileURLs() -> Bool {
            migrateColumns([("file_urls", "TEXT")]) { true }
        }

        private func migrateColumns(
            _ definitions: [(name: String, type: String)], then body: () -> Bool
        ) -> Bool {
            guard let columns = itemColumns() else { return false }
            return ClipboardSQLite.transaction(in: database) {
                for (name, type) in definitions where !columns.contains(name) {
                    guard execute("ALTER TABLE items ADD COLUMN \(name) \(type)") else { return false }
                }
                return body()
            }
        }

        private func itemColumns() -> Set<String>? {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, "PRAGMA table_info(items)", -1, &statement, nil) == SQLITE_OK,
                let statement
            else { return nil }
            var columns = Set<String>()
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                if let name = ClipboardSQLite.columnString(statement, 1) { columns.insert(name) }
                status = sqlite3_step(statement)
            }
            return status == SQLITE_DONE ? columns : nil
        }

        private func execute(_ sql: String) -> Bool {
            sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
        }

        private static let coreSchema = """
            CREATE TABLE IF NOT EXISTS items(
              id TEXT NOT NULL UNIQUE,
              kind TEXT NOT NULL,
              text TEXT,
              image_path TEXT,
              created_at REAL NOT NULL,
              source_app TEXT,
              image_fingerprint TEXT,
              custom_title TEXT,
              first_copied_at REAL,
              copy_count INTEGER NOT NULL DEFAULT 1,
              pinyin TEXT,
              pinyin_initials TEXT,
              ocr_text TEXT,
              ocr_status TEXT,
              ocr_version INTEGER,
              ocr_attempts INTEGER NOT NULL DEFAULT 0,
              file_urls TEXT
            );
            CREATE INDEX IF NOT EXISTS items_created_at ON items(created_at);
            CREATE INDEX IF NOT EXISTS items_kind ON items(kind);
            CREATE INDEX IF NOT EXISTS items_text_content
              ON items(text, created_at DESC) WHERE kind != 'image';
            CREATE UNIQUE INDEX IF NOT EXISTS items_image_fingerprint
              ON items(image_fingerprint) WHERE image_fingerprint IS NOT NULL;
            CREATE INDEX IF NOT EXISTS items_image_path
              ON items(image_path) WHERE image_path IS NOT NULL;
            CREATE TABLE IF NOT EXISTS stacks(
              id TEXT NOT NULL UNIQUE,
              name TEXT NOT NULL,
              position INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS stack_items(
              item_id TEXT NOT NULL UNIQUE,
              stack_id TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS stack_items_stack_id
              ON stack_items(stack_id, item_id);
            CREATE TABLE IF NOT EXISTS pending_blob_deletions(
              path TEXT NOT NULL PRIMARY KEY
            );
            """

        private static let fileURLsSchema = """
            CREATE INDEX IF NOT EXISTS items_text_source
              ON items(text, source_app)
              WHERE text IS NOT NULL AND kind != 'image' AND file_urls IS NULL;
            CREATE INDEX IF NOT EXISTS items_file_source
              ON items(file_urls, source_app) WHERE file_urls IS NOT NULL;
            CREATE INDEX IF NOT EXISTS items_owned_image
              ON items(created_at) WHERE kind = 'image' AND image_path IS NOT NULL;
            """

        private static let searchSchema = """
            CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
              text, pinyin, pinyin_initials,
              content='items', content_rowid='rowid', tokenize='trigram'
            );
            CREATE TRIGGER IF NOT EXISTS items_ai AFTER INSERT ON items BEGIN
              INSERT INTO items_fts(rowid, text, pinyin, pinyin_initials)
              VALUES(new.rowid, new.text, new.pinyin, new.pinyin_initials);
            END;
            CREATE TRIGGER IF NOT EXISTS items_ad AFTER DELETE ON items BEGIN
              INSERT INTO items_fts(items_fts, rowid, text, pinyin, pinyin_initials)
              VALUES('delete', old.rowid, old.text, old.pinyin, old.pinyin_initials);
            END;
            CREATE TRIGGER IF NOT EXISTS items_au
            AFTER UPDATE OF text, pinyin, pinyin_initials ON items BEGIN
              INSERT INTO items_fts(items_fts, rowid, text, pinyin, pinyin_initials)
              VALUES('delete', old.rowid, old.text, old.pinyin, old.pinyin_initials);
              INSERT INTO items_fts(rowid, text, pinyin, pinyin_initials)
              VALUES(new.rowid, new.text, new.pinyin, new.pinyin_initials);
            END;
            """

        /// Separate OCR index preserves the existing text index during the one-time schema upgrade.
        private static let imageSearchSchema = """
            CREATE VIRTUAL TABLE IF NOT EXISTS image_ocr_fts USING fts5(
              ocr_text, tokenize='trigram'
            );
            CREATE TRIGGER IF NOT EXISTS image_ocr_ai AFTER INSERT ON items
            WHEN new.ocr_text IS NOT NULL BEGIN
              INSERT INTO image_ocr_fts(rowid, ocr_text) VALUES(new.rowid, new.ocr_text);
            END;
            CREATE TRIGGER IF NOT EXISTS image_ocr_ad AFTER DELETE ON items
            WHEN old.ocr_text IS NOT NULL BEGIN
              DELETE FROM image_ocr_fts WHERE rowid = old.rowid;
            END;
            CREATE TRIGGER IF NOT EXISTS image_ocr_au AFTER UPDATE OF ocr_text ON items BEGIN
              DELETE FROM image_ocr_fts WHERE rowid = old.rowid;
              INSERT INTO image_ocr_fts(rowid, ocr_text)
              SELECT new.rowid, new.ocr_text WHERE new.ocr_text IS NOT NULL;
            END;
            CREATE INDEX IF NOT EXISTS items_pending_ocr ON items(created_at)
              WHERE kind = 'image' AND image_path IS NOT NULL AND
                (ocr_status IS NULL OR (ocr_status = 'failed' AND ocr_attempts < \(ClipboardImageTextRecognition.maxAttempts)));
            """
    }
}
