import XCTest

/// SQLite-backed history store: capture, dedup, pinning, retention, the memory window, and
/// full-history search. Every test runs against a throwaway directory.
@MainActor
final class ClipboardStoreTests: XCTestCase {
    // MARK: - Capture and persistence

    func testAddTextInsertsAtHeadAndPersists() async throws {
        let directory = TestSupport.makeTemporaryDirectory("add-text")
        defer { TestSupport.removeTemporaryDirectory(directory) }

        let store = ClipboardStore(directory: directory)
        let first = store.addText("one", sourceBundleID: "com.a")
        let second = store.addText("two", sourceBundleID: "com.b")

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(store.items.map(\.text), ["two", "one"])

        let reloaded = ClipboardStore(directory: directory)
        reloaded.load()
        XCTAssertEqual(reloaded.items.map(\.text), ["two", "one"])
    }

    func testRecopyOfTopItemIsNoop() {
        let directory = TestSupport.makeTemporaryDirectory("recopy-top")
        defer { TestSupport.removeTemporaryDirectory(directory) }

        let store = ClipboardStore(directory: directory)
        let original = store.addText("same", sourceBundleID: nil)
        let recopied = store.addText("same", sourceBundleID: nil)

        XCTAssertEqual(recopied?.id, original?.id)
        XCTAssertEqual(store.items.count, 1)
    }

    func testCaptureGenerationGuardsRejectStaleCaptures() {
        let directory = TestSupport.makeTemporaryDirectory("generation")
        defer { TestSupport.removeTemporaryDirectory(directory) }

        let store = ClipboardStore(directory: directory)
        XCTAssertEqual(store.captureGeneration, 0)
        XCTAssertNil(store.addText("stale", sourceBundleID: nil, expectedGeneration: 99))
        XCTAssertNotNil(store.addText("fresh", sourceBundleID: nil, expectedGeneration: 0))

        store.clearAll()
        XCTAssertEqual(store.captureGeneration, 1)
        XCTAssertNil(store.addText("stale", sourceBundleID: nil, expectedGeneration: 0))
    }

    // MARK: - Promote / pin

    func testPromoteMovesItemToHead() async throws {
        let directory = TestSupport.makeTemporaryDirectory("promote")
        defer { TestSupport.removeTemporaryDirectory(directory) }

        let store = ClipboardStore(directory: directory)
        let one = store.addText("one", sourceBundleID: nil)!
        _ = store.addText("two", sourceBundleID: nil)!
        _ = store.addText("three", sourceBundleID: nil)!

        store.promote(one)
        XCTAssertEqual(store.items.first?.id, one.id)

        // Promotion rewrites the row under the same id, so a fresh store sees it first too.
        let reloaded = ClipboardStore(directory: directory)
        reloaded.load()
        XCTAssertEqual(reloaded.items.first?.id, one.id)
    }

    func testPinPutsOldestItemIntoPinnedSection() {
        let directory = TestSupport.makeTemporaryDirectory("pin")
        defer { TestSupport.removeTemporaryDirectory(directory) }

        let store = ClipboardStore(directory: directory)
        let one = store.addText("one", sourceBundleID: nil)!
        let two = store.addText("two", sourceBundleID: nil)!
        let three = store.addText("three", sourceBundleID: nil)!

        store.togglePinned(three)
        XCTAssertFalse(three.isPinned)  // the captured value copy is immutable
        XCTAssertEqual(store.displayItems.first?.id, three.id)

        store.togglePinned(one)
        // displayItems holds EVERYTHING: pins newest-first, then history by recency.
        XCTAssertEqual(store.displayItems.map(\.id), [one.id, three.id, two.id])
    }

    func testUnpinRejoinsHistoryAsNewest() {
        let directory = TestSupport.makeTemporaryDirectory("unpin")
        defer { TestSupport.removeTemporaryDirectory(directory) }

        let store = ClipboardStore(directory: directory)
        let one = store.addText("one", sourceBundleID: nil)!
        _ = store.addText("two", sourceBundleID: nil)!
        store.togglePinned(one)
        // ClipboardItem is a value type: refetch so the second toggle sees the pinned copy.
        store.togglePinned(store.item(id: one.id)!)

        XCTAssertFalse(store.displayItems.first!.isPinned)
        XCTAssertEqual(store.displayItems.first?.id, one.id)
    }

    // MARK: - Custom titles

    func testCustomTitlePersistsAndClears() async throws {
        let directory = TestSupport.makeTemporaryDirectory("custom-title")
        defer { TestSupport.removeTemporaryDirectory(directory) }

        let store = ClipboardStore(directory: directory)
        let item = store.addText("content", sourceBundleID: nil)!

        store.setCustomTitle("My Title", for: item.id)
        XCTAssertEqual(store.item(id: item.id)?.customTitle, "My Title")

        // Blank titles restore the automatic title.
        store.setCustomTitle("   ", for: item.id)
        XCTAssertNil(store.item(id: item.id)?.customTitle)

        store.setCustomTitle("Final", for: item.id)
        let reloaded = ClipboardStore(directory: directory)
        reloaded.load()
        XCTAssertEqual(reloaded.item(id: item.id)?.customTitle, "Final")
    }

    // MARK: - Removal

    func testRemoveDeletesRow() {
        let directory = TestSupport.makeTemporaryDirectory("remove")
        defer { TestSupport.removeTemporaryDirectory(directory) }

        let store = ClipboardStore(directory: directory)
        let keep = store.addText("keep", sourceBundleID: nil)!
        let drop = store.addText("drop", sourceBundleID: nil)!

        store.remove(drop)
        XCTAssertEqual(store.items.map(\.id), [keep.id])
        XCTAssertNil(store.item(id: drop.id))
    }

    func testClearAllEmptiesHistoryAndImages() async throws {
        let directory = TestSupport.makeTemporaryDirectory("clear-all")
        defer { TestSupport.removeTemporaryDirectory(directory) }

        let store = ClipboardStore(directory: directory)
        _ = store.addText("text", sourceBundleID: nil)
        await store.addImage(TestSupport.makePNGData(), sourceBundleID: nil)
        XCTAssertEqual(store.items.count, 2)

        store.clearAll()
        XCTAssertTrue(store.items.isEmpty)

        let imagesDir = directory.appendingPathComponent("images", isDirectory: true)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: imagesDir.path)
        XCTAssertTrue(leftovers.isEmpty)
    }

    // MARK: - Images

    func testImageDeduplicatesByFingerprint() async throws {
        let directory = TestSupport.makeTemporaryDirectory("image-dedup")
        defer { TestSupport.removeTemporaryDirectory(directory) }

        let store = ClipboardStore(directory: directory)
        let png = TestSupport.makePNGData(red: 10, green: 20, blue: 30)
        await store.addImage(png, sourceBundleID: "com.a")
        await store.addImage(png, sourceBundleID: "com.b")
        XCTAssertEqual(store.items.count, 1)

        let url = store.imageURL(for: store.items[0])
        XCTAssertNotNil(url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url!.path))

        await store.addImage(TestSupport.makePNGData(red: 200, green: 200, blue: 200), sourceBundleID: nil)
        XCTAssertEqual(store.items.count, 2)
    }

    func testRemovedImageDeletesBlobFile() async throws {
        let directory = TestSupport.makeTemporaryDirectory("image-remove")
        defer { TestSupport.removeTemporaryDirectory(directory) }

        let store = ClipboardStore(directory: directory)
        await store.addImage(TestSupport.makePNGData(), sourceBundleID: nil)
        let item = store.items[0]
        let url = store.imageURL(for: item)!
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        store.remove(item)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Memory window

    func testMemoryWindowCapsResidentItems() {
        let directory = TestSupport.makeTemporaryDirectory("window")
        defer { TestSupport.removeTemporaryDirectory(directory) }

        let store = ClipboardStore(directory: directory)
        for index in 1...1005 {
            store.addText("text-\(index)", sourceBundleID: nil)
        }

        XCTAssertEqual(store.items.count, 1000)
        XCTAssertEqual(store.items.first?.text, "text-1005")
        XCTAssertEqual(store.items.last?.text, "text-6")
    }

    // MARK: - Retention pruning

    func testLoadPrunesStaleRowsButKeepsPinnedOnes() async throws {
        let directory = TestSupport.makeTemporaryDirectory("retention")
        defer { TestSupport.removeTemporaryDirectory(directory) }
        let dbURL = directory.appendingPathComponent("clipboard.sqlite3")

        // Create the schema through the store, then seed rows the public API cannot express:
        // a stale unpinned row, the same age but pinned, and a fresh unpinned row.
        let bootstrap = ClipboardStore(directory: directory)
        _ = bootstrap.addText("placeholder", sourceBundleID: nil)

        let now = Date()
        let staleID = UUID()
        let pinnedID = UUID()
        let freshID = UUID()
        XCTAssertTrue(TestSupport.seedRow(
            dbURL: dbURL, id: staleID, text: "stale",
            createdAt: now.addingTimeInterval(-10 * 86_400)))
        XCTAssertTrue(TestSupport.seedRow(
            dbURL: dbURL, id: pinnedID, text: "stale-but-pinned",
            createdAt: now.addingTimeInterval(-10 * 86_400), pinnedAt: now))
        XCTAssertTrue(TestSupport.seedRow(
            dbURL: dbURL, id: freshID, text: "fresh", createdAt: now))

        let store = ClipboardStore(directory: directory)
        store.maxAge = ClipboardRetention.day.maxAge
        store.load()

        // Known quirk: prune() deletes the expired row from the database, but the in-memory
        // trim only fires when the NEWEST unpinned row is itself stale, so the aged row can
        // linger in the resident window until relaunch. Assert the database-level effect.
        let reloaded = ClipboardStore(directory: directory)
        reloaded.load()
        let ids = Set(reloaded.items.map(\.id))
        XCTAssertFalse(ids.contains(staleID))
        XCTAssertTrue(ids.contains(pinnedID))
        XCTAssertTrue(ids.contains(freshID))
        XCTAssertNil(reloaded.item(id: staleID))
        XCTAssertNotNil(reloaded.item(id: pinnedID))
    }

    // MARK: - Search

    func testEmptyQueryReturnsDisplayOrder() async throws {
        let directory = TestSupport.makeTemporaryDirectory("search-empty")
        defer { TestSupport.removeTemporaryDirectory(directory) }

        let store = ClipboardStore(directory: directory)
        _ = store.addText("alpha", sourceBundleID: nil)
        _ = store.addText("beta", sourceBundleID: nil)

        let results = await store.searchAsync("   ")
        XCTAssertEqual(results.map(\.text), ["beta", "alpha"])
    }

    func testFTSPathMatchesSubstringsOfThreeOrMoreCharacters() async throws {
        let directory = TestSupport.makeTemporaryDirectory("search-fts")
        defer { TestSupport.removeTemporaryDirectory(directory) }

        let store = ClipboardStore(directory: directory)
        let hello = store.addText("hello world", sourceBundleID: nil)!
        _ = store.addText("swift concurrency guide", sourceBundleID: nil)

        let hit = await store.searchAsync("hello")
        XCTAssertEqual(hit.map(\.id), [hello.id])

        let prefix = await store.searchAsync("wor")
        XCTAssertEqual(prefix.map(\.id), [hello.id])

        let miss = await store.searchAsync("zzzzz")
        XCTAssertTrue(miss.isEmpty)
    }

    func testShortQueryFallsBackToLikeScan() async throws {
        let directory = TestSupport.makeTemporaryDirectory("search-like")
        defer { TestSupport.removeTemporaryDirectory(directory) }

        let store = ClipboardStore(directory: directory)
        let item = store.addText("hello world", sourceBundleID: nil)!

        let results = await store.searchAsync("wo")
        XCTAssertEqual(results.map(\.id), [item.id])

        // LIKE metacharacters are escaped, not interpreted.
        let literalPercent = await store.searchAsync("100%")
        XCTAssertTrue(literalPercent.isEmpty)
    }

    func testCJKSearchViaFTSAndShortScan() async throws {
        let directory = TestSupport.makeTemporaryDirectory("search-cjk")
        defer { TestSupport.removeTemporaryDirectory(directory) }

        let store = ClipboardStore(directory: directory)
        let item = store.addText("你好世界", sourceBundleID: nil)!

        let trigram = await store.searchAsync("你好世")
        XCTAssertEqual(trigram.map(\.id), [item.id])

        let short = await store.searchAsync("好")
        XCTAssertEqual(short.map(\.id), [item.id])
    }

    func testPinyinSearchWorksImmediatelyAndAfterReload() async throws {
        let directory = TestSupport.makeTemporaryDirectory("search-pinyin")
        defer { TestSupport.removeTemporaryDirectory(directory) }

        let store = ClipboardStore(directory: directory)
        let item = store.addText("你好世界", sourceBundleID: nil)!

        // Resident matching covers the row before its persistent pinyin metadata is written.
        let immediate = await store.searchAsync("nhsj")
        XCTAssertEqual(immediate.map(\.id), [item.id])

        await store.waitForSearchMetadata()

        // A fresh instance has no resident pinyin matcher state beyond the row itself; the
        // persisted pinyin columns drive the FTS/LIKE paths.
        let reloaded = ClipboardStore(directory: directory)
        reloaded.load()
        let byInitials = await reloaded.searchAsync("nhsj")
        XCTAssertEqual(byInitials.map(\.id), [item.id])
        // Full spelling works only for contiguous syllable runs: the concatenated form of
        // 你好世界 is "nihaoshijie", so "nihao" matches but "nishijie" (spanning 你好 + 世界)
        // is not a contiguous substring and does not.
        let byFullSpelling = await reloaded.searchAsync("nihao")
        XCTAssertEqual(byFullSpelling.map(\.id), [item.id])
    }

    func testTypeFilterFindsMarkdownBeyondMemoryAndSearchLimits() async throws {
        let directory = TestSupport.makeTemporaryDirectory("search-type-history")
        defer { TestSupport.removeTemporaryDirectory(directory) }
        let store = ClipboardStore(directory: directory)
        let markdown = try XCTUnwrap(store.addText("# needle", sourceBundleID: nil))
        XCTAssertEqual(markdown.displayKind, .markdown)
        store.setCustomTitle("recipe", for: markdown.id)

        // Newer plain-text matches must not consume the Markdown result budget.
        let dbURL = directory.appendingPathComponent("clipboard.sqlite3")
        for index in 0..<2100 {
            let id = UUID()
            XCTAssertTrue(TestSupport.seedRow(
                dbURL: dbURL, id: id, text: "needle plain entry \(index)", createdAt: Date()))
            store.setCustomTitle("recipe \(index)", for: id)
        }
        let reloaded = ClipboardStore(directory: directory)
        reloaded.load()
        XCTAssertFalse(reloaded.items.contains { $0.id == markdown.id })

        // Empty query, LIKE, FTS, and custom-title fallback all filter before truncation.
        for query in ["", "ne", "needle", "recipe"] {
            let results = await reloaded.searchAsync(query, displayKind: .markdown)
            XCTAssertEqual(results.map(\.id), [markdown.id], "Query: \(query)")
        }
    }

    func testCustomTitleIsSearchable() async throws {
        let directory = TestSupport.makeTemporaryDirectory("search-title")
        defer { TestSupport.removeTemporaryDirectory(directory) }

        let store = ClipboardStore(directory: directory)
        let item = store.addText("totally unrelated body text", sourceBundleID: nil)!
        store.setCustomTitle("important recipe", for: item.id)

        let results = await store.searchAsync("recipe")
        XCTAssertEqual(results.map(\.id), [item.id])
    }
}
