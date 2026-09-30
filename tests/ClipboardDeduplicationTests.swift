import AppKit
import SQLite3

enum AppLocalization {
    static func string(_ key: String, locale: Locale) -> String { key }
}

@main
struct ClipboardDeduplicationTests {
    static func database(_ directory: URL) -> OpaquePointer {
        var db: OpaquePointer?
        precondition(sqlite3_open(directory.appendingPathComponent("clipboard.sqlite3").path, &db) == SQLITE_OK)
        return db!
    }

    static func execute(_ db: OpaquePointer, _ sql: String) {
        precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK,
                     String(cString: sqlite3_errmsg(db)))
    }

    static func scalar(_ db: OpaquePointer, _ sql: String) -> Int {
        var stmt: OpaquePointer?
        precondition(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        precondition(sqlite3_step(stmt) == SQLITE_ROW)
        return Int(sqlite3_column_int64(stmt, 0))
    }

    @MainActor
    static func recopyTests(in directory: URL) async {
        let store = ClipboardStore(directory: directory)
        store.load()
        let a = store.addText("新的复制", kind: .text, sourceBundleID: "first")!
        let stack = store.createStack(name: "Saved")!
        store.assign(a.id, to: stack.id)
        _ = store.addText("这确实是一次新的复制。", kind: .text, sourceBundleID: "other")
        let b = store.items.first!
        let revision = store.revision
        let again = store.addText("新的复制", kind: .text, sourceBundleID: "second")!
        precondition(again.id == a.id && store.items.count == 2, "A → B → A reuses A")
        precondition(store.items.map(\.id) == [a.id, b.id])
        precondition(again.createdAt >= a.createdAt && again.sourceBundleID == "second")
        precondition(store.stackID(for: a.id) == stack.id)
        precondition(store.revision == revision + 1, "Recopy publishes one complete update")
        let top = store.addText("新的复制", kind: .text, sourceBundleID: "third")!
        precondition(top.id == a.id && store.items.count == 2 && top.sourceBundleID == "third")

        // Switching classifiers must replace the old verdict on a recopy, including on disk.
        let reclassified = store.addText("新的复制", kind: .code, sourceBundleID: "AI")!
        precondition(reclassified.id == a.id && reclassified.kind == .code)
        let db = database(directory)
        precondition(scalar(db, "SELECT COUNT(*) FROM items WHERE id = '\(a.id.uuidString)' AND kind = 'code'") == 1)
        _ = store.addText("新的复制", kind: .text, sourceBundleID: "local")
        precondition(store.item(id: a.id)?.kind == .text)
        precondition(scalar(db, "SELECT COUNT(*) FROM items WHERE id = '\(a.id.uuidString)' AND kind = 'text'") == 1)
        sqlite3_close(db)

        // Exact contents, not visible first lines or normalized whitespace, determine identity.
        let different = ["新的复制 ", "新的复制\n", "Case", "case", "same\nA", "same\nB",
                         "nul\0A", "nul\0B", "é", "e\u{301}"]
        let ids = different.map { store.addText($0, kind: .text, sourceBundleID: nil)!.id }
        precondition(Set(ids).count == different.count)
        for (text, id) in zip(different, ids) {
            precondition(store.addText(text, kind: .text, sourceBundleID: nil)?.id == id)
        }
        for index in 0..<1_005 {
            _ = store.addText("history-\(index)", kind: .text, sourceBundleID: nil)
        }
        precondition(!store.items.contains { $0.id == a.id }, "Fixture exceeds resident window")
        let usage = Date(timeIntervalSince1970: 1_790_000_000)
        let priorOrder = store.items.map(\.id)
        precondition(store.markUsed(id: a.id, at: usage))
        precondition(store.items.map(\.id) == priorOrder, "Using a nonresident item never brings it to the top")
        let oldPage = await store.searchAsync("新的复制", after: nil, limit: 100)
        precondition(oldPage.items.first { $0.id == a.id }?.lastUsedAt == usage,
                     "Search loads usage metadata outside the resident window")
        precondition(store.addText("新的复制", kind: .text, sourceBundleID: "fourth")?.id == a.id,
                     "Recopy searches the complete database")
        precondition(store.item(id: a.id)?.lastUsedAt == usage, "External recopy preserves usage metadata")
        await store.waitForSearchMetadata()
        let page = await store.searchAsync("新的复制", after: nil, limit: 100)
        precondition(page.items.filter { $0.text == "新的复制" }.count == 1)

        let reopened = ClipboardStore(directory: directory)
        reopened.load()
        precondition(reopened.addText("新的复制", kind: .text, sourceBundleID: "fifth")?.id == a.id)
        precondition(reopened.stackID(for: a.id) == stack.id)
        precondition(reopened.item(id: a.id)?.lastUsedAt == usage, "Usage survives restart and recopy")
        await reopened.waitForSearchMetadata()
        print("PASS: interleaved/consecutive copies, full-history lookup, exact content, search, restart")
    }

    @MainActor
    static func usageMigrationTests(in directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let captured = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 60)
        let db = database(directory)
        defer { sqlite3_close(db) }
        // The existing schema has no usage column. Migration must preserve its history as-is.
        execute(db, """
            CREATE TABLE items(
              id TEXT NOT NULL UNIQUE, kind TEXT NOT NULL, text TEXT, image_path TEXT,
              created_at REAL NOT NULL, source_app TEXT, image_fingerprint TEXT,
              custom_title TEXT, pinyin TEXT, pinyin_initials TEXT
            );
            INSERT INTO items(id, kind, text, created_at, source_app, custom_title)
            VALUES('\(id)', 'text', 'saved entry', \(captured.timeIntervalSince1970), 'original', 'Saved');
            """)
        let store = ClipboardStore(directory: directory)
        store.load()
        let original = store.item(id: id)!
        precondition(original.createdAt == captured && original.lastUsedAt == nil)
        precondition(original.sourceBundleID == "original" && original.customTitle == "Saved")
        let stack = store.createStack(name: "Saved")!
        store.assign(id, to: stack.id)
        let newest = store.addText("newer entry", kind: .text, sourceBundleID: "other")!
        var captures = 0
        store.onItemCaptured = { captures += 1 }
        let usage = captured.addingTimeInterval(60)
        let revision = store.revision
        precondition(store.markUsed(id: id, at: usage))
        let used = store.item(id: id)!
        precondition(used == original.used(at: usage))
        precondition(store.items.map(\.id) == [newest.id, id] && store.stackID(for: id) == stack.id)
        precondition(store.revision == revision + 1 && captures == 0, "Usage publishes metadata without capture feedback")
        let page = await store.searchAsync("", after: nil, limit: 1)
        let next = await store.searchAsync("", after: page.nextCursor, limit: 1)
        precondition(page.items.first?.id == newest.id && next.items.first?.id == id)
        precondition(next.items.first?.lastUsedAt == usage, "Usage does not change pagination or ordering")
        precondition(store.updateKind(id: id, to: .code))
        precondition(store.item(id: id)?.lastUsedAt == usage && captures == 0)

        let reopened = ClipboardStore(directory: directory)
        reopened.load()
        precondition(reopened.item(id: id)?.lastUsedAt == usage, "Migration is repeatable and usage persists")
        precondition(reopened.item(id: id)?.kind == .code && reopened.stackID(for: id) == stack.id)
        precondition(reopened.remove(reopened.item(id: id)!))
        precondition(reopened.undoLastDeletion()?.lastUsedAt == usage, "Deletion undo preserves usage")

        let beforeFailure = store.item(id: id)!
        let failureRevision = store.revision
        execute(db, "CREATE TRIGGER fail_usage BEFORE UPDATE OF last_used_at ON items BEGIN SELECT RAISE(ABORT, 'test'); END")
        precondition(!store.markUsed(id: id, at: usage.addingTimeInterval(1)))
        precondition(store.item(id: id) == beforeFailure && store.revision == failureRevision && captures == 0)
        execute(db, "DROP TRIGGER fail_usage")
        precondition(!store.markUsed(id: UUID()), "Missing rows cannot be recreated by usage updates")

        // Usage is informational: the approved scope does not extend retention.
        reopened.maxAge = 30
        reopened.enforceLimits()
        precondition(reopened.item(id: id) == nil && reopened.item(id: newest.id) != nil)
        print("PASS: legacy migration, usage persistence, pagination, metadata, undo, failed update, unchanged retention")
    }

    @MainActor
    static func captureFeedbackTests(in directory: URL) async {
        let store = ClipboardStore(directory: directory)
        store.load()
        var captures = 0
        store.onItemCaptured = { captures += 1 }
        let text = store.addText("feedback", kind: .text, sourceBundleID: "first")!
        precondition(captures == 1)
        _ = store.addText("feedback", kind: .text, sourceBundleID: "second")
        precondition(captures == 2 && store.items.count == 1, "Repeated text gets one capture feedback")
        precondition(store.markUsed(id: text.id) && captures == 2, "Usage does not emit capture feedback")
        precondition(store.updateKind(id: text.id, to: .code) && captures == 2)
        _ = store.addText("ignored", kind: .text, sourceBundleID: nil,
                          expectedGeneration: store.captureGeneration + 1)
        precondition(captures == 2, "Rejected captures stay silent")

        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<2 { for y in 0..<2 { bitmap.setColor(.red, atX: x, y: y) } }
        let data = bitmap.representation(using: .png, properties: [:])!
        await store.addImage(data, sourceBundleID: "image")
        let image = store.items.first!
        precondition(captures == 3 && image.kind == .image)
        precondition(store.markUsed(id: image.id))
        let usage = store.item(id: image.id)!.lastUsedAt!
        await store.addImage(data, sourceBundleID: "image-again")
        precondition(captures == 4 && store.items.count == 2 && store.items.first?.id == image.id)
        precondition(abs(store.item(id: image.id)!.lastUsedAt!.timeIntervalSince(usage)) < 0.000001)
        precondition(store.remove(store.item(id: image.id)!) && store.undoLastDeletion() != nil)
        precondition(captures == 4, "Restoring a row is not a capture")

        let db = database(directory)
        defer { sqlite3_close(db) }
        execute(db, "CREATE TRIGGER fail_capture BEFORE UPDATE OF created_at ON items BEGIN SELECT RAISE(ABORT, 'test'); END")
        precondition(store.addText("feedback", kind: .text, sourceBundleID: nil) == nil)
        await store.addImage(data, sourceBundleID: nil)
        precondition(captures == 4, "Failed text and image refreshes stay silent")
        execute(db, "DROP TRIGGER fail_capture")
        execute(db, "CREATE TRIGGER fail_insert BEFORE INSERT ON items BEGIN SELECT RAISE(ABORT, 'test'); END")
        precondition(store.addText("failed new capture", kind: .text, sourceBundleID: nil) == nil)
        precondition(captures == 4, "Failed inserts stay silent")
        print("PASS: text/image capture feedback, silent usage/classification/undo, rejected and failed captures")
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        await recopyTests(in: root.appendingPathComponent("recopy"))
        try await usageMigrationTests(in: root.appendingPathComponent("usage"))
        await captureFeedbackTests(in: root.appendingPathComponent("feedback"))
    }
}
