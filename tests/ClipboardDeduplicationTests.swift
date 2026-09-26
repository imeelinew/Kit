import Foundation
import SQLite3

// UI localization and the unrelated Markdown v1 migration are outside this store-only harness.
// Legacy fixtures start at schema v1; newly created databases have no text to classify.
enum AppLocalization {
    static func string(_ key: String, locale: Locale) -> String { key }
}
enum MarkdownAttributedRenderer {
    static func isMarkdown(_ text: String) -> Bool { false }
}
enum ClipboardTextClassifier {
    static func kind(for text: String) -> ClipboardItem.Kind { .text }
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
        precondition(store.addText("新的复制", kind: .text, sourceBundleID: "fourth")?.id == a.id,
                     "Recopy searches the complete database")
        await store.waitForSearchMetadata()
        let page = await store.searchAsync("新的复制", after: nil, limit: 100)
        precondition(page.items.filter { $0.text == "新的复制" }.count == 1)

        let reopened = ClipboardStore(directory: directory)
        reopened.load()
        precondition(reopened.addText("新的复制", kind: .text, sourceBundleID: "fifth")?.id == a.id)
        precondition(reopened.stackID(for: a.id) == stack.id)
        await reopened.waitForSearchMetadata()
        print("PASS: interleaved/consecutive copies, full-history lookup, exact content, search, restart")
    }

    @MainActor
    static func migrationTests(in directory: URL) async {
        var initial: ClipboardStore? = ClipboardStore(directory: directory)
        initial?.load()
        initial = nil
        let db = database(directory)
        defer { sqlite3_close(db) }
        let older = Date().timeIntervalSince1970 - 100
        let newer = older + 50
        let namedID = UUID().uuidString
        let stackedID = UUID().uuidString
        let newestID = UUID().uuidString
        let stackID = UUID().uuidString
        execute(db, """
            INSERT INTO stacks VALUES('\(stackID)', 'Saved', 0);
            INSERT INTO items(id, kind, text, created_at, source_app, custom_title) VALUES
              ('\(namedID)', 'text', 'duplicate content', \(older), 'old', 'My title'),
              ('\(stackedID)', 'text', 'duplicate content', \(older + 1), 'old', NULL),
              ('\(newestID)', 'text', 'duplicate content', \(newer), 'new', NULL),
              ('\(UUID().uuidString)', 'text', 'plain duplicate', \(older), 'old', NULL),
              ('\(UUID().uuidString)', 'text', 'plain duplicate', \(newer), 'new', NULL),
              ('\(UUID().uuidString)', 'text', 'conflicting names', \(older), 'old', 'Name A'),
              ('\(UUID().uuidString)', 'text', 'conflicting names', \(newer), 'new', 'Name B');
            INSERT INTO stack_items VALUES('\(stackedID)', '\(stackID)');
            PRAGMA user_version = 1;
            """)
        let store = ClipboardStore(directory: directory)
        store.load()
        let matches = store.items.filter { $0.text == "duplicate content" }
        precondition(matches.count == 1)
        let keeper = matches[0]
        precondition(keeper.customTitle == "My title" && keeper.sourceBundleID == "new")
        precondition(keeper.createdAt.timeIntervalSince1970 == newer)
        precondition(store.stackID(for: keeper.id)?.uuidString == stackID)
        precondition(store.items.filter { $0.text == "plain duplicate" }.count == 1)
        precondition(store.items.filter { $0.text == "conflicting names" }.count == 2,
                     "Do not discard conflicting user names")
        precondition(scalar(db, "SELECT COUNT(*) FROM stack_items WHERE item_id NOT IN (SELECT id FROM items)") == 0)
        let search = await store.searchAsync("duplicate content", after: nil, limit: 20)
        precondition(search.items.map(\.id) == [keeper.id], "FTS must not retain deleted duplicates")
        execute(db, "INSERT INTO items_fts(items_fts, rank) VALUES('integrity-check', 1)")
        let reopened = ClipboardStore(directory: directory)
        reopened.load()
        precondition(reopened.items == store.items, "Migration is idempotent")
        precondition(reopened.addText("duplicate content", kind: .text, sourceBundleID: "recopy")?.id == keeper.id)
        print("PASS: legacy merge, latest metadata, names and stacks, conflicting names, FTS integrity, idempotency")
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        await recopyTests(in: root.appendingPathComponent("recopy"))
        await migrationTests(in: root.appendingPathComponent("migration"))
    }
}
