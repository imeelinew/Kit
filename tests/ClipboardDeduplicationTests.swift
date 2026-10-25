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

    @MainActor
    static func recopyTests(in directory: URL) async {
        let store = ClipboardStore(directory: directory)
        store.load()
        let a = store.addText("新的复制", kind: .text, sourceBundleID: "first")!
        let stack = store.createStack(name: "Saved")!
        store.assign(a.id, to: stack.id)
        _ = store.addText("这确实是一次新的复制。", kind: .text, sourceBundleID: "other")
        let differentSource = store.addText("新的复制", kind: .text, sourceBundleID: "second")!
        precondition(differentSource.id != a.id && store.items.count == 3,
                     "The same text from a different source remains separate")
        precondition(store.item(id: a.id) == a,
                     "A different source does not change the original entry")
        let again = store.addText("新的复制", kind: .text, sourceBundleID: "first")!
        precondition(again.id == a.id && store.items.count == 3, "A → B → A from the same source reuses A")
        precondition(again.lastCopiedAt >= a.lastCopiedAt && again.sourceBundleID == "first"
                     && abs(again.firstCopiedAt.timeIntervalSince(a.firstCopiedAt)) < 0.000001
                     && again.copyCount == 2)
        precondition(store.stackID(for: a.id) == stack.id,
                     "Same-source recopy preserves stack membership")

        let nilSource = store.addText("nil source", kind: .text, sourceBundleID: nil)!
        let nilSourceAgain = store.addText("nil source", kind: .text, sourceBundleID: nil)!
        precondition(nilSourceAgain.id == nilSource.id && nilSourceAgain.copyCount == 2,
                     "Text without a source deduplicates with other text without a source")

        // Exact contents, not visible first lines or normalized whitespace, determine identity.
        let different = ["新的复制 ", "新的复制\n", "Case", "case", "same\nA", "same\nB",
                         "nul\0A", "nul\0B", "é", "e\u{301}"]
        let ids = different.map { store.addText($0, kind: .text, sourceBundleID: nil)!.id }
        precondition(Set(ids).count == different.count)
        for (text, id) in zip(different, ids) {
            precondition(store.addText(text, kind: .text, sourceBundleID: nil)?.id == id)
        }

        let before = store.item(id: a.id)!
        let reopened = ClipboardStore(directory: directory)
        reopened.load()
        let restarted = reopened.addText("新的复制", kind: .text, sourceBundleID: "first")!
        precondition(restarted.id == a.id && reopened.items.count == store.items.count,
                     "Same-source recopy after restart reuses the original without adding an entry")
        precondition(restarted.copyCount == before.copyCount + 1
                     && restarted.firstCopiedAt == before.firstCopiedAt,
                     "Same-source recopy after restart advances the count and preserves the first time")
        precondition(reopened.stackID(for: a.id) == stack.id)
        print("PASS: same-source recopy, source isolation, nil-source identity, exact bytes, metadata and restart")
    }

    @MainActor
    static func historyActionTests(in directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let captured = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 60)
        let db = database(directory)
        defer { sqlite3_close(db) }
        execute(db, """
            CREATE TABLE items(
              id TEXT NOT NULL UNIQUE, kind TEXT NOT NULL, text TEXT, image_path TEXT,
              created_at REAL NOT NULL, source_app TEXT, image_fingerprint TEXT,
              custom_title TEXT, pinyin TEXT, pinyin_initials TEXT, last_used_at REAL
            );
            INSERT INTO items(id, kind, text, created_at, source_app, custom_title, last_used_at)
            VALUES('\(id)', 'text', 'saved entry', \(captured.timeIntervalSince1970),
                   'original', 'Saved', \(captured.addingTimeInterval(30).timeIntervalSince1970));
            """)
        let store = ClipboardStore(directory: directory)
        store.load()
        let original = store.item(id: id)!
        precondition(original.firstCopiedAt == captured && original.lastCopiedAt == captured)
        precondition(original.copyCount == 1 && original.sourceBundleID == "original")
        let newest = store.addText("newer entry", kind: .text, sourceBundleID: "other")!
        store.updateHistoryAfterAction = false
        let revision = store.revision
        precondition(store.recordHistoryAction(id: id))
        precondition(store.item(id: id) == original && store.revision == revision,
                     "Disabled action leaves all metadata unchanged")
        store.updateHistoryAfterAction = true
        let usage = Date()
        precondition(store.recordHistoryAction(id: id, at: usage, deferPublication: true))
        precondition(store.item(id: id) == original, "Keep-open action leaves the visible preview unchanged")
        precondition(store.recordHistoryAction(id: id, at: usage.addingTimeInterval(1), deferPublication: true))
        store.publishDeferredHistoryUpdates()
        let copied = store.item(id: id)!
        precondition(copied.firstCopiedAt == captured && copied.copyCount == 3)
        precondition(copied.sourceBundleID == "original" && copied.customTitle == "Saved")
        precondition(store.items.map(\.id) == [id, newest.id], "Published reuse moves the entry to the top")
        let reopened = ClipboardStore(directory: directory)
        reopened.load()
        precondition(reopened.item(id: id)?.copyCount == 3 && reopened.items.first?.id == id)
        precondition(reopened.item(id: id)?.firstCopiedAt == captured, "Migration is repeatable")
        print("PASS: legacy migration, preference on/off, deferred repeated pastes, restart")
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        await recopyTests(in: root.appendingPathComponent("recopy"))
        try await historyActionTests(in: root.appendingPathComponent("usage"))
    }
}
