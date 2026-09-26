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
/// Pagination is asserted through ClipboardSearch.queryDatabase directly: searchAsync
/// merges the resident window into the first page, which flattens cursor boundaries by design.
@main
struct ClipboardSearchTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func execute(_ directory: URL, _ sql: String) {
        var db: OpaquePointer?
        precondition(sqlite3_open(directory.appendingPathComponent("clipboard.sqlite3").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
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

        // FTS path (>= 3 chars): exact newest-first order, stable across page boundaries.
        expect(collectDB(database, query: "item", limit: 7) == newestFirst,
               "Cursor pagination returns every result exactly once, newest first")

        // Ties on created_at break by rowid, so equal-timestamp pages stay ordered.
        expect(collectDB(database, query: "", limit: 6) == newestFirst,
               "Empty queries page through the whole history newest first")

        // Short queries take the LIKE path over text, pinyin, initials, and titles.
        expect(collectDB(database, query: "it", limit: 10) == newestFirst,
               "Two-character queries match via LIKE")

        _ = store.addText("50%_off sale", kind: .text, sourceBundleID: nil)
        expect(collectDB(database, query: "0%", limit: 5) == ["50%_off sale"],
               "LIKE wildcards in queries are escaped")

        let titled = store.addText("titled entry", kind: .text, sourceBundleID: nil)!
        execute(directory, "UPDATE items SET custom_title = '超市清单' WHERE id = '\(titled.id)'")
        store.load()
        expect(collectDB(database, query: "超市", limit: 5) == ["titled entry"],
               "Custom titles match short Han queries")

        // A malformed FTS phrase must degrade to no results, not crash the reader.
        expect(collectDB(database, query: "\"hi", limit: 5).isEmpty,
               "Malformed FTS queries fail closed")

        // searchAsync layer: trimming, and the resident merge that fills the first page.
        let padded = await store.searchAsync(" item \n", after: nil, limit: 7)
        expect(padded.items.compactMap(\.text) == newestFirst,
               "Queries are trimmed and the resident merge completes the first page")
        expect(padded.nextCursor != nil, "The cursor still reports older database rows")

        // The merge fills page one beyond the cursor; the next page resumes at the database
        // cursor, and the view layer dedupes the overlap when appending.
        let exactPage = await store.searchAsync("item", after: padded.nextCursor, limit: 7)
        expect(exactPage.items.compactMap(\.text) == Array(newestFirst[7..<14]),
               "Cursored pages resume exactly where the database cursor left off")

        let malformed = await store.searchAsync("\"hi", after: nil, limit: 5)
        expect(malformed.items.isEmpty && malformed.nextCursor == nil,
               "Malformed queries degrade to an empty page at the store layer too")
    }

    @MainActor
    static func filterTests(in directory: URL) async {
        let store = ClipboardStore(directory: directory)
        store.load()
        for index in 0..<3 {
            expect(store.addText("csnip \(index)", kind: .code, sourceBundleID: nil) != nil,
                   "Code fixture insert succeeds")
        }
        for index in 0..<10 {
            expect(store.addText("kz \(String(format: "%02d", index))", kind: .code, sourceBundleID: nil) != nil,
                   "Pagination fixture insert succeeds")
        }
        let database = directory.appendingPathComponent("clipboard.sqlite3").path

        expect(collectDB(database, query: "csnip", kind: .code, limit: 10)
                == ["csnip 2", "csnip 1", "csnip 0"],
               "Kind filters restrict FTS results")
        expect(collectDB(database, query: "kz", kind: .text, limit: 10).isEmpty,
               "A non-matching kind excludes everything")

        // Cursor pagination stays correct while a kind filter is active.
        let kzNewestFirst = (0..<10).map { "kz \(String(format: "%02d", 9 - $0))" }
        expect(collectDB(database, query: "kz", kind: .code, limit: 4) == kzNewestFirst,
               "Kind-filtered pagination returns every code result exactly once")

        let stack = store.createStack(name: "FilterProbe")!
        let kzItems = store.items.filter { $0.text?.hasPrefix("kz") == true }
        expect(kzItems.count == 10, "Stack fixtures are resident")
        store.assign(kzItems[0].id, to: stack.id)
        store.assign(kzItems[1].id, to: stack.id)
        expect(collectDB(database, query: "", stackID: stack.id, limit: 10)
                == [kzItems[0].text, kzItems[1].text],
               "Stack filters restrict to members, newest first")
        expect(collectDB(database, query: "kz", kind: .code, stackID: stack.id, limit: 10)
                == [kzItems[0].text, kzItems[1].text],
               "Query, kind, and stack filters compose")
        expect(collectDB(database, query: "csnip", stackID: stack.id, limit: 10).isEmpty,
               "Stack members outside the query stay hidden")
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kit-search-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        await paginationTests(in: root.appendingPathComponent("pagination"))
        await filterTests(in: root.appendingPathComponent("filters"))
        print("PASS: FTS/LIKE routing, escaping, titles, cursor pagination, kind/stack filters")
    }
}
