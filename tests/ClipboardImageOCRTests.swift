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
        precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK,
                     String(cString: sqlite3_errmsg(db)))
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

    static func png(_ color: NSColor = .red) -> Data {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        let rgb = color.usingColorSpace(.deviceRGB)!
        let pixel = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
            .map { UInt8(($0 * 255).rounded()) }
        for y in 0..<8 {
            for x in 0..<8 {
                let offset = y * bitmap.bytesPerRow + x * 4
                for component in 0..<4 { bitmap.bitmapData![offset + component] = pixel[component] }
            }
        }
        return bitmap.representation(using: .png, properties: [:])!
    }

    static func dbSearch(
        _ directory: URL, _ query: String, kind: ClipboardItem.Kind? = nil,
        stackID: UUID? = nil, after: ClipboardSearchCursor? = nil, limit: Int = 20
    ) -> ClipboardSearchPage {
        let page = ClipboardSearch.queryDatabase(
            path: directory.appendingPathComponent("clipboard.sqlite3").path,
            query: query, kind: kind, stackID: stackID, after: after, limit: limit)
        precondition(page != nil, "OCR search SQL succeeds")
        return page!
    }

    @MainActor
    static func searchAndLifecycle(in directory: URL) async {
        let probe = OCRProbe()
        let store = ClipboardStore(directory: directory, recognizeImage: { await probe.recognize($0) })
        store.load()
        var captures = 0
        store.onItemCaptured = { captures += 1 }
        let data = png()
        await store.addImage(data, sourceBundleID: "original")
        let original = store.items.first!
        let stack = store.createStack(name: "Saved")!
        store.assign(original.id, to: stack.id)
        let usage = Date(timeIntervalSince1970: 1_790_000_000)
        precondition(store.markUsed(id: original.id, at: usage))
        await probe.waitForCall(1)
        precondition(dbSearch(directory, "账户").items.isEmpty, "Unprocessed images have no text match")
        await probe.release(.recognized("账 户管理 ＰａｄｄｌｅＯＣＲ\nEnglish words 50%_off"))
        await store.waitForImageOCR()
        let image = store.item(id: original.id)!
        precondition(image.kind == .image && image.text == nil && image.imagePath == original.imagePath)
        precondition(abs(image.createdAt.timeIntervalSince(original.createdAt)) < 0.000001)
        precondition(image.sourceBundleID == "original" && image.lastUsedAt == usage)
        precondition(store.stackID(for: image.id) == stack.id && captures == 1)
        precondition(image.defaultTitle(locale: .current) == "Image", "OCR never changes visible image titles")
        precondition(image.imageOCR?.status == .complete && image.imageOCR?.attempts == 1)
        for query in ["账", "账户", "账户管理", "账 户", "paddleocr", "ＰａｄｄｌｅＯＣＲ",
                      "English words", "0%", "%_", "zhanghu", "zh"] {
            precondition(image.matches(query), "Resident OCR match: \(query)")
            precondition(dbSearch(directory, query).items.map(\.id) == [image.id], "Database OCR match: \(query)")
        }
        precondition(dbSearch(directory, "_x").items.isEmpty, "OCR LIKE treats wildcard characters literally")
        precondition(dbSearch(directory, "\"hi").items.isEmpty, "Quoted OCR queries cannot break MATCH")
        precondition(dbSearch(directory, "账户", kind: .text).items.isEmpty)
        precondition(dbSearch(directory, "账户", kind: .image, stackID: stack.id).items.map(\.id) == [image.id])
        let results = await store.searchAsync("账户", after: nil, limit: 10)
        precondition(results.items.map(\.id) == [image.id])

        await store.addImage(data, sourceBundleID: "recopy")
        await store.waitForImageOCR()
        let calls = await probe.calls
        precondition(calls == 1 && store.items.count == 1 && store.items.first?.id == image.id)
        precondition(store.items.first?.imageOCR == image.imageOCR, "Recopy preserves OCR and never repeats it")
        let recopied = store.items.first!
        precondition(store.remove(recopied))
        precondition(dbSearch(directory, "PaddleOCR").items.isEmpty, "Delete removes OCR index entries")
        precondition(store.undoLastDeletion()?.imageOCR == image.imageOCR)
        await store.waitForImageOCR()
        precondition(dbSearch(directory, "PaddleOCR").items.map(\.id) == [image.id])
        execute(directory, "INSERT INTO image_ocr_fts(image_ocr_fts) VALUES('integrity-check')")
        execute(directory, "INSERT INTO items_fts(items_fts, rank) VALUES('integrity-check', 1)")

        let reopened = ClipboardStore(directory: directory, recognizeImage: { _ in
            preconditionFailure("Completed images must not be recognized on restart")
        })
        reopened.load()
        await reopened.waitForImageOCR()
        precondition(reopened.item(id: image.id)?.imageOCR == image.imageOCR)
        precondition(dbSearch(directory, "zhanghu").items.map(\.id) == [image.id])
        reopened.clearAll()
        precondition(dbSearch(directory, "PaddleOCR").items.isEmpty)
        precondition(count(directory, "SELECT COUNT(*) FROM image_ocr_fts") == 0)
        print("PASS: OCR FTS/LIKE/pinyin, normalization, filters, recopy, metadata, undo, restart, clear")
    }

    @MainActor
    static func legacyBackfill(in directory: URL) async throws {
        let images = directory.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let oldID = UUID(), newID = UUID(), missingID = UUID()
        let oldURL = images.appendingPathComponent("old.png"), newURL = images.appendingPathComponent("new.png")
        try png().write(to: oldURL)
        try png(.blue).write(to: newURL)
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
            INSERT INTO items(id, kind, image_path, created_at, image_fingerprint, custom_title)
            VALUES('\(oldID)', 'image', '\(oldURL.path)', \(now - 100), NULL, 'Saved image');
            INSERT INTO items(id, kind, image_path, created_at, image_fingerprint)
            VALUES('\(newID)', 'image', '\(newURL.path)', \(now - 50), 'new');
            INSERT INTO items(id, kind, image_path, created_at, image_fingerprint)
            VALUES('\(missingID)', 'image', '\(images.appendingPathComponent("missing.png").path)', \(now - 150), NULL);
            WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x + 1 FROM n WHERE x < 1005)
            INSERT INTO items(id, kind, text, created_at)
              SELECT printf('00000000-0000-0000-0000-%012d', x), 'text',
                     'existing searchable ' || x, \(now) + x FROM n;
            INSERT INTO items_fts(items_fts) VALUES('rebuild');
            """)
        let probe = OCRProbe()
        var store: ClipboardStore? = ClipboardStore(directory: directory,
                                                     recognizeImage: { await probe.recognize($0) })
        store!.load()
        precondition(store!.items.count == 1000 && !store!.items.contains { $0.kind == .image },
                     "Historical images lie beyond the resident window")
        precondition(count(directory, "SELECT COUNT(*) FROM items_fts WHERE items_fts MATCH 'searchable'") == 1005,
                     "Schema migration leaves the existing text index intact")
        await probe.waitForCall(1)
        // New captures take priority over older historical images waiting in the database.
        await store!.addImage(png(.green), sourceBundleID: nil)
        let capturedID = store!.items.first!.id
        await probe.release(.recognized("new image searchable"))
        await probe.waitForCall(2)
        precondition(dbSearch(directory, "new image").items.first?.id == newID)
        await probe.release(.recognized("captured priority"))
        await probe.waitForCall(3)
        precondition(dbSearch(directory, "captured priority").items.first?.id == capturedID)
        // Shutdown while a historical job is in flight. It must remain pending for the next session.
        weak let releasedStore = store
        store = nil
        precondition(releasedStore == nil, "OCR does not retain the store during recognition")
        await probe.release(.recognized("must not persist after shutdown"))
        precondition(count(directory, "SELECT COUNT(*) FROM items WHERE id = '\(oldID)' AND ocr_status IS NULL") == 1)

        let resumed = ClipboardStore(directory: directory, recognizeImage: { url in
            FileManager.default.fileExists(atPath: url.path) ? .recognized("历史图片文字") : .failed
        })
        resumed.load()
        await resumed.waitForImageOCR()
        precondition(dbSearch(directory, "历史图片").items.first?.id == oldID,
                     "Backfill recognizes nonresident history after restart")
        precondition(resumed.item(id: oldID)?.customTitle == "Saved image")
        precondition(count(directory, "SELECT ocr_attempts FROM items WHERE id = '\(missingID)'") == 2,
                     "Missing images cannot cause an endless retry loop")
        precondition(count(directory, "SELECT COUNT(*) FROM items WHERE ocr_status IS NULL AND kind = 'image'") == 0)
        print("PASS: legacy migration, complete-history backfill, new-image priority, shutdown, resume, missing files")
    }

    @MainActor
    static func cancellationAndEmpty(in directory: URL) async {
        let probe = OCRProbe()
        let store = ClipboardStore(directory: directory, recognizeImage: { await probe.recognize($0) })
        await store.addImage(png(), sourceBundleID: nil)
        await probe.waitForCall(1)
        let deleted = store.items.first!
        precondition(store.remove(deleted))
        await probe.release(.recognized("deleted text"))
        await store.waitForImageOCR()
        precondition(store.items.isEmpty && dbSearch(directory, "deleted text").items.isEmpty)

        await store.addImage(png(.blue), sourceBundleID: nil)
        await probe.waitForCall(2)
        store.clearAll()
        await store.addImage(png(.green), sourceBundleID: nil)
        await probe.release(.recognized("cleared text"))
        await probe.waitForCall(3)
        await probe.release(.recognized(" \n "))
        await store.waitForImageOCR()
        let empty = store.items.first!
        precondition(empty.imageOCR?.status == .empty && empty.imageOCR?.text == nil)
        precondition(dbSearch(directory, "cleared text").items.isEmpty)
        let reopened = ClipboardStore(directory: directory, recognizeImage: { _ in
            preconditionFailure("A completed image without text is not pending")
        })
        reopened.load()
        await reopened.waitForImageOCR()
        precondition(reopened.item(id: empty.id)?.imageOCR?.status == .empty)
        print("PASS: late deletion/clear results discarded, new capture after cancellation, empty images persist")
    }

    @MainActor
    static func visionSmoke(in directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 1000, height: 180))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1000, height: 180).fill()
        ("中文图片搜索 English OCR" as NSString).draw(
            at: NSPoint(x: 30, y: 60),
            withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let data = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let store = ClipboardStore(directory: directory)
        await store.addImage(data, sourceBundleID: nil)
        await store.waitForImageOCR()
        let query = await store.searchAsync("中文图片", after: nil, limit: 10)
        precondition(query.items.count == 1 && query.items.first?.kind == .image, "Real Vision OCR finds Chinese image text")
        precondition(dbSearch(directory, "English OCR").items.count == 1, "Real Vision OCR finds English image text")
        print("PASS: real Apple Vision Chinese/English OCR through capture, persistence, and search")
    }

    @MainActor
    static func paginationAndFailures(in directory: URL) async {
        let store = ClipboardStore(directory: directory, recognizeImage: { _ in .recognized("分页图片 Shared OCR") })
        let stack = store.createStack(name: "Pages")!
        for color in [NSColor.red, .green, .blue, .black] {
            await store.addImage(png(color), sourceBundleID: nil)
            store.assign(store.items.first!.id, to: stack.id)
        }
        await store.waitForImageOCR()
        let expected = store.items.map(\.id)
        _ = store.addText("Shared OCR text", kind: .text, sourceBundleID: nil)
        var cursor: ClipboardSearchCursor?
        var found: [UUID] = []
        repeat {
            let page = dbSearch(directory, "Shared OCR", kind: .image, stackID: stack.id, after: cursor, limit: 2)
            found.append(contentsOf: page.items.map(\.id))
            cursor = page.nextCursor
        } while cursor != nil
        precondition(found == expected, "OCR images paginate without duplicates or omissions")
        precondition(dbSearch(directory, "Shared OCR").items.count == 5, "Text and OCR indexes compose")
        precondition(store.deleteStack(stack.id))
        precondition(dbSearch(directory, "Shared OCR", kind: .image).items.isEmpty)
        precondition(count(directory, "SELECT COUNT(*) FROM image_ocr_fts") == 0)

        let failures = directory.appendingPathComponent("failures")
        let probe = OCRProbe()
        let failing = ClipboardStore(directory: failures, recognizeImage: { await probe.recognize($0) })
        await failing.addImage(png(), sourceBundleID: nil)
        let image = failing.items.first!
        await probe.waitForCall(1)
        await probe.release(.failed)
        await probe.waitForCall(2)
        await probe.release(.failed)
        await failing.waitForImageOCR()
        precondition(failing.item(id: image.id)?.imageOCR?.status == .failed)
        precondition(failing.item(id: image.id)?.imageOCR?.attempts == 2)
        let reopened = ClipboardStore(directory: failures, recognizeImage: { _ in
            preconditionFailure("Exhausted recognition failures are not retried on restart")
        })
        reopened.load()
        await reopened.waitForImageOCR()

        // A recognition upgrade resets exhausted jobs and replaces their metadata in the background.
        execute(failures, "UPDATE items SET ocr_version = 0 WHERE id = '\(image.id)'")
        let upgraded = ClipboardStore(directory: failures, recognizeImage: { _ in .recognized("版本升级文字") })
        upgraded.load()
        await upgraded.waitForImageOCR()
        precondition(upgraded.item(id: image.id)?.imageOCR?.attempts == 1)
        precondition(dbSearch(failures, "版本升级").items.map(\.id) == [image.id])
        upgraded.maxAge = 0
        upgraded.enforceLimits()
        precondition(dbSearch(failures, "版本升级").items.isEmpty, "Retention removes OCR with the image")
        print("PASS: OCR pagination, mixed text/image results, Stack deletion, bounded failure retries, version upgrades, retention")
    }

    @MainActor
    static func writeRollback(in directory: URL) async {
        let probe = OCRProbe()
        let store = ClipboardStore(directory: directory, recognizeImage: { await probe.recognize($0) })
        await store.addImage(png(), sourceBundleID: nil)
        let image = store.items.first!
        await probe.waitForCall(1)
        execute(directory, """
            CREATE TRIGGER fail_ocr BEFORE UPDATE OF ocr_text ON items
              BEGIN SELECT RAISE(ABORT, 'test'); END;
            """)
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
        print("PASS: OCR write rollback, bounded database retry, pending jobs resume")
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kit-ocr-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        await searchAndLifecycle(in: root.appendingPathComponent("search"))
        try await legacyBackfill(in: root.appendingPathComponent("legacy"))
        await cancellationAndEmpty(in: root.appendingPathComponent("cancellation"))
        await paginationAndFailures(in: root.appendingPathComponent("pagination"))
        await writeRollback(in: root.appendingPathComponent("rollback"))
        try await visionSmoke(in: root.appendingPathComponent("vision"))
    }
}
