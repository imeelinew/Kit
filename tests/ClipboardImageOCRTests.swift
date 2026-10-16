import AppKit
import SQLite3

enum AppLocalization {
    static func string(_ key: String, locale: Locale) -> String { key }
}

actor OCRProbe {
    private(set) var calls = 0
    private var waiting: [CheckedContinuation<ClipboardImageOCRResult, Never>] = []

    func recognize(_ url: URL) async -> ClipboardImageOCRResult {
        calls += 1
        return await withCheckedContinuation { waiting.append($0) }
    }

    func release(_ result: ClipboardImageOCRResult) {
        precondition(!waiting.isEmpty)
        waiting.removeFirst().resume(returning: result)
    }

    func waitForCall(_ count: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while calls < count, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        precondition(calls == count, "OCR worker starts exactly one recognition at a time")
    }
}

@main
struct ClipboardImageOCRTests {
    static func execute(_ directory: URL, _ sql: String) {
        var db: OpaquePointer?
        precondition(sqlite3_open(directory.appendingPathComponent("clipboard.sqlite3").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, String(cString: sqlite3_errmsg(db)))
    }

    static func count(_ directory: URL, _ sql: String) -> Int {
        var db: OpaquePointer?
        precondition(sqlite3_open(directory.appendingPathComponent("clipboard.sqlite3").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        precondition(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        precondition(sqlite3_step(stmt) == SQLITE_ROW)
        return Int(sqlite3_column_int64(stmt, 0))
    }

    static func png() -> Data {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        let pixel: [UInt8] = [255, 0, 0, 255]
        for y in 0..<8 {
            for x in 0..<8 {
                let offset = y * bitmap.bytesPerRow + x * 4
                for component in 0..<4 { bitmap.bitmapData![offset + component] = pixel[component] }
            }
        }
        return bitmap.representation(using: .png, properties: [:])!
    }

    static func dbSearch(_ directory: URL, _ query: String) -> ClipboardSearchPage {
        let page = ClipboardSearch.queryDatabase(path: directory.appendingPathComponent("clipboard.sqlite3").path,
                                                 query: query, kind: nil, stackID: nil, after: nil, limit: 20)
        precondition(page != nil, "OCR search SQL succeeds")
        return page!
    }

    @MainActor
    static func searchAndLifecycle(in directory: URL) async {
        let probe = OCRProbe()
        let store = ClipboardStore(directory: directory, recognizeImage: { await probe.recognize($0) })
        store.load()
        await store.addImage(png(), sourceBundleID: nil)
        let image = store.items.first!
        await probe.waitForCall(1)
        precondition(dbSearch(directory, "账户").items.isEmpty, "Unprocessed images have no text match")
        await probe.release(.recognized("账 户管理 ＰａｄｄｌｅＯＣＲ\nEnglish words 50%_off"))
        await store.waitForImageOCR()
        let ocr = store.item(id: image.id)!
        precondition(ocr.kind == .image && ocr.text == nil && ocr.imagePath == image.imagePath)
        for query in ["账 户", "zhanghu", "paddleocr", "English words"] {
            precondition(dbSearch(directory, query).items.map(\.id) == [image.id], "Database OCR match: \(query)")
        }
        precondition(store.remove(ocr))
        precondition(dbSearch(directory, "PaddleOCR").items.isEmpty, "Delete removes OCR index entries")
        precondition(store.undoLastDeletion()?.imageOCR == ocr.imageOCR)
        await store.waitForImageOCR()
        precondition(dbSearch(directory, "PaddleOCR").items.map(\.id) == [image.id])
        let reopened = ClipboardStore(directory: directory, recognizeImage: { _ in
            preconditionFailure("Completed images must not be recognized on restart")
        })
        reopened.load()
        await reopened.waitForImageOCR()
        precondition(reopened.item(id: image.id)?.imageOCR == ocr.imageOCR)
        print("PASS: OCR text search, deletion, undo, restart")
    }

    @MainActor
    static func legacyBackfill(in directory: URL) async throws {
        let images = directory.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let oldID = UUID(), missingID = UUID()
        let oldURL = images.appendingPathComponent("old.png")
        try png().write(to: oldURL)
        let now = Date().timeIntervalSince1970
        execute(directory, """
            CREATE TABLE items(
              id TEXT NOT NULL UNIQUE, kind TEXT NOT NULL, text TEXT, image_path TEXT,
              created_at REAL NOT NULL, source_app TEXT, image_fingerprint TEXT,
              custom_title TEXT, last_used_at REAL, pinyin TEXT, pinyin_initials TEXT
            );
            CREATE VIRTUAL TABLE items_fts USING fts5(
              text, pinyin, pinyin_initials, content='items', content_rowid='rowid', tokenize='trigram'
            );
            INSERT INTO items(id, kind, image_path, created_at, image_fingerprint)
            VALUES('\(oldID)', 'image', '\(oldURL.path)', \(now - 100), NULL);
            INSERT INTO items(id, kind, image_path, created_at, image_fingerprint)
            VALUES('\(missingID)', 'image', '\(images.appendingPathComponent("missing.png").path)', \(now - 150), NULL);
            INSERT INTO items(id, kind, text, created_at) VALUES('\(UUID())', 'text', 'existing searchable', \(now));
            INSERT INTO items_fts(items_fts) VALUES('rebuild');
            """)
        let resumed = ClipboardStore(directory: directory, recognizeImage: {
            FileManager.default.fileExists(atPath: $0.path) ? .recognized("历史图片文字") : .failed
        })
        resumed.load()
        await resumed.waitForImageOCR()
        precondition(dbSearch(directory, "历史图片").items.first?.id == oldID)
        precondition(count(directory, "SELECT COUNT(*) FROM items_fts WHERE items_fts MATCH 'searchable'") == 1,
                     "Schema migration leaves the existing text index intact")
        precondition(count(directory, "SELECT ocr_attempts FROM items WHERE id = '\(missingID)'") == 2,
                     "Missing images cannot cause an endless retry loop")
        print("PASS: legacy schema migration, image backfill after restart, missing-file retry bound")
    }

    @MainActor
    static func writeRollback(in directory: URL) async {
        let probe = OCRProbe()
        let store = ClipboardStore(directory: directory, recognizeImage: { await probe.recognize($0) })
        await store.addImage(png(), sourceBundleID: nil)
        let image = store.items.first!
        await probe.waitForCall(1)
        execute(directory, "CREATE TRIGGER fail_ocr BEFORE UPDATE OF ocr_text ON items BEGIN SELECT RAISE(ABORT, 'test'); END;")
        await probe.release(.recognized("transaction searchable"))
        await store.waitForImageOCR()
        precondition(store.item(id: image.id)?.imageOCR == nil)
        precondition(dbSearch(directory, "transaction").items.isEmpty)
        precondition(count(directory, "SELECT COUNT(*) FROM image_ocr_fts") == 0,
                     "Failed writes cannot leave a partial OCR index")
        execute(directory, "DROP TRIGGER fail_ocr")
        store.load()
        await probe.waitForCall(2)
        await probe.release(.recognized("transaction searchable"))
        await store.waitForImageOCR()
        precondition(dbSearch(directory, "transaction").items.map(\.id) == [image.id])
        print("PASS: OCR write rollback, bounded retry, pending jobs resume")
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kit-ocr-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        await searchAndLifecycle(in: root.appendingPathComponent("search"))
        try await legacyBackfill(in: root.appendingPathComponent("legacy"))
        await writeRollback(in: root.appendingPathComponent("rollback"))
    }
}
