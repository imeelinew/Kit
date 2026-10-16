import Foundation
import SQLite3

// UI localization and the unrelated Markdown v1 migration are outside this store-only harness.
enum AppLocalization {
    static func string(_ key: String, locale: Locale) -> String { key }
}
enum MarkdownAttributedRenderer {
    static func isMarkdown(_ text: String) -> Bool { false }
}
enum ClipboardTextClassifier {
    static func kind(for text: String) -> ClipboardItem.Kind { .text }
}

/// Run with scripts/test-clipboard-search.sh. Exercises query routing (FTS vs LIKE),
/// cursor pagination, and combined kind/stack filters against a real SQLite store.
@main
struct ClipboardSearchTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    /// Page through the database with cursors and return the full text sequence.
    static func collectDB(
        _ database: String, query: String, kind: ClipboardItem.Kind? = nil,
        stackID: ClipboardStack.ID? = nil, limit: Int
    ) -> [String] {
        var texts: [String] = []
        var cursor: ClipboardSearchCursor?
        var pages = 0
        repeat {
            guard let page = ClipboardSearch.queryDatabase(
                path: database, query: query, kind: kind, stackID: stackID,
                after: cursor, limit: limit)
            else { preconditionFailure("Query failed: \(query)") }
            texts.append(contentsOf: page.items.compactMap(\.text))
            cursor = page.nextCursor
            pages += 1
            expect(pages < 50, "Pagination terminates")
        } while cursor != nil
        return texts
    }

    @MainActor
    static func paginationTests(in directory: URL) async {
        let store = ClipboardStore(directory: directory)
        store.load()
        for index in 0..<25 {
            expect(store.addText("item \(String(format: "%02d", index))", kind: .text, sourceBundleID: nil) != nil,
                   "Fixture insert succeeds")
        }
        let newestFirst = (0..<25).map { "item \(String(format: "%02d", 24 - $0))" }
        let database = directory.appendingPathComponent("clipboard.sqlite3").path

        expect(collectDB(database, query: "item", limit: 7) == newestFirst,
               "Cursor pagination returns every result exactly once, newest first")

        expect(collectDB(database, query: "it", limit: 10) == newestFirst,
               "Two-character queries match via LIKE")

        _ = store.addText("50%_off sale", kind: .text, sourceBundleID: nil)
        expect(collectDB(database, query: "0%", limit: 5) == ["50%_off sale"],
               "LIKE wildcards in queries are escaped")
    }

    @MainActor
    static func filterTests(in directory: URL) async {
        let store = ClipboardStore(directory: directory)
        store.load()
        for index in 0..<10 {
            _ = store.addText("kz \(String(format: "%02d", index))", kind: .code, sourceBundleID: nil)
        }
        let database = directory.appendingPathComponent("clipboard.sqlite3").path

        expect(collectDB(database, query: "kz", kind: .text, limit: 10).isEmpty,
               "A non-matching kind excludes everything")

        let stack = store.createStack(name: "FilterProbe")!
        let kzItems = store.items.filter { $0.text?.hasPrefix("kz") == true }
        store.assign(kzItems[0].id, to: stack.id)
        store.assign(kzItems[1].id, to: stack.id)
        expect(collectDB(database, query: "kz", kind: .code, stackID: stack.id, limit: 10)
                == [kzItems[0].text, kzItems[1].text],
               "Query, kind, and stack filters compose")
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kit-search-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        await paginationTests(in: root.appendingPathComponent("pagination"))
        await filterTests(in: root.appendingPathComponent("filters"))
        print("PASS: FTS/LIKE routing, query escaping, cursor pagination, kind and stack filters")
    }
}
