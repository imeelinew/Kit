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

    private final class ComputationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var entered = false
        private let releaseSignal = DispatchSemaphore(value: 0)

        var hasEntered: Bool { lock.withLock { entered } }

        func pause() {
            lock.withLock { entered = true }
            precondition(releaseSignal.wait(timeout: .now() + 10) == .success,
                         "Metadata computation gate times out instead of hanging")
        }

        func release() { releaseSignal.signal() }
    }

    @MainActor
    private static func waitForGate(_ gate: ComputationGate) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !gate.hasEntered, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        expect(gate.hasEntered, "The metadata worker reaches the controlled computation")
    }

    @MainActor
    static func metadataWriteContention(in directory: URL) async throws {
        let store = ClipboardStore(directory: directory)
        let first = store.addText("first seed", kind: .text, sourceBundleID: nil)!
        let second = store.addText("second seed", kind: .text, sourceBundleID: nil)!
        let database = directory.appendingPathComponent("clipboard.sqlite3").path
        let batch = [SearchMetadataUpdate(id: first.id.uuidString, text: "你好"),
                     SearchMetadataUpdate(id: second.id.uuidString, text: "中国")]
        let firstGate = ComputationGate()
        let secondGate = ComputationGate()
        defer { firstGate.release(); secondGate.release() }
        let worker = Task.detached {
            ClipboardSearch.updateMetadata(path: database, batch: batch) { text in
                (text == "你好" ? firstGate : secondGate).pause()
                return Pinyin.searchForms(for: text)
            }
        }
        defer { worker.cancel() }

        try await waitForGate(firstGate)
        expect(store.addText("copy during first computation", kind: .text, sourceBundleID: nil) != nil,
               "A fresh capture is saved while the first pinyin computation is paused")
        firstGate.release()
        try await waitForGate(secondGate)
        expect(collectDB(database, query: "nihao", limit: 10) == ["first seed"],
               "The first index update commits before the next computation starts")
        expect(store.addText("copy during second computation", kind: .text, sourceBundleID: nil) != nil,
               "Later entries do not keep a batch-wide lock that drops fresh captures")

        worker.cancel()
        secondGate.release()
        let cancelled = await worker.value
        expect(!cancelled, "Cancellation stops the remaining metadata write")
        expect(collectDB(database, query: "zhongguo", limit: 10).isEmpty,
               "Cancelled computation never publishes its index update")
        let replay = await Task.detached {
            ClipboardSearch.updateMetadata(path: database, batch: batch)
        }.value
        expect(replay, "A partially committed batch can be retried")
        expect(collectDB(database, query: "nihao", limit: 10) == ["first seed"],
               "Replaying a committed row preserves its FTS index without duplicates")
        expect(collectDB(database, query: "zhongguo", limit: 10) == ["second seed"],
               "Retry completes the remaining row's pinyin index")
        print("PASS: captures during pinyin computation, per-row commits, cancellation and replay")
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kit-search-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        await paginationTests(in: root.appendingPathComponent("pagination"))
        await filterTests(in: root.appendingPathComponent("filters"))
        try await metadataWriteContention(in: root.appendingPathComponent("metadata-contention"))
        print("PASS: FTS/LIKE routing, query escaping, cursor pagination, kind and stack filters")
    }
}
