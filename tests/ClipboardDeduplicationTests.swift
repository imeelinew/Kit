import Foundation
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

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        await recopyTests(in: root.appendingPathComponent("recopy"))
    }
}
