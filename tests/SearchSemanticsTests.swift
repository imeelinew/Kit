import AppKit
import Foundation
import SQLite3
@testable import Kit

@MainActor
enum SearchSemanticsTests {
    private enum Failure: Error {
        case database(String)
    }

    static func run() async throws {
        try titleSemantics()
        try recopyMetadataPreservation()
        try pinyinSemantics()
        try searchHighlightSemantics()
        try await customTitleAndIndexedPinyin()
        try await escapedQuerySemantics()
        try await emptyQueryFilters()
        try await exactTimestampCursorTies()
        try await residentMergeSemantics()
        try await cancellationAndUnavailableDatabase()
    }

    private static func titleSemantics() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let blankCustomTitle = ClipboardItem(
            id: UUID(), kind: .text, text: "\n\nfirst line\nsecond line",
            imagePath: nil, imageFingerprint: nil, lastCopiedAt: now,
            sourceBundleID: nil, customTitle: " \n\t ")
        try TestSupport.expect(
            blankCustomTitle.displayTitle(locale: Locale(identifier: "en")) == "first line",
            "A blank custom title falls back to the trimmed first text line")

        let trimmedCustomTitle = blankCustomTitle.withCustomTitle(" \n Named title \t ")
        try TestSupport.expect(
            trimmedCustomTitle.displayTitle(locale: Locale(identifier: "en")) == "Named title",
            "A nonblank custom title is trimmed at its outer boundaries")

        let grapheme = "👩🏽‍💻"
        let longText = String(repeating: grapheme, count: 199) + "e\u{301}z"
        let truncated = ClipboardItem(text: longText, kind: .text, sourceBundleID: nil)
        let truncatedTitle = truncated.defaultTitle(locale: Locale(identifier: "en"))
        let expectedTitle = String(repeating: grapheme, count: 199) + "e\u{301}"
        try TestSupport.expect(truncatedTitle == expectedTitle,
                               "Title truncation keeps 200 grapheme clusters intact")
        try TestSupport.expect(truncatedTitle.count == 200,
                               "Unicode title truncation counts user-visible characters")

        let files = [
            URL(fileURLWithPath: "/tmp/alpha.txt"),
            URL(fileURLWithPath: "/tmp/报告.md"),
        ]
        let fileItem = ClipboardItem(
            id: UUID(), kind: .file, text: files.map(\.path).joined(separator: "\n"),
            imagePath: nil, imageFingerprint: nil, fileURLs: files, lastCopiedAt: now,
            sourceBundleID: nil)
        try TestSupport.expect(
            fileItem.displayTitle(locale: Locale(identifier: "en")) == "alpha.txt, 报告.md",
            "A multi-file item joins every last path component")
        try TestSupport.expect(fileItem.typeLabel == "Files",
                               "A multi-file item uses the plural type label")
    }

    private static func recopyMetadataPreservation() throws {
        let originalID = UUID()
        let firstCopy = Date(timeIntervalSince1970: 1_600_000_000)
        let previousCopy = Date(timeIntervalSince1970: 1_700_000_000)
        let nextCopy = Date(timeIntervalSince1970: 1_800_000_000)
        let fileURL = URL(fileURLWithPath: "/tmp/preserved.png")
        let ocr = ClipboardImageOCR(
            text: "persistent OCR", status: .complete, version: 7, attempts: 2)
        let original = ClipboardItem(
            id: originalID, kind: .image, text: "fallback text",
            imagePath: fileURL.path, imageFingerprint: "fingerprint",
            fileURLs: [fileURL], lastCopiedAt: previousCopy,
            sourceBundleID: "com.example.old", customTitle: "Pinned title",
            firstCopiedAt: firstCopy, copyCount: 4, imageOCR: ocr)

        let recopied = original.recopied(at: nextCopy, sourceBundleID: "com.example.new")
        try TestSupport.expect(recopied.id == originalID && recopied.kind == .file && recopied.hasImagePreview,
                               "Recopy preserves identity and kind")
        try TestSupport.expect(
            recopied.text == original.text && recopied.imagePath == original.imagePath
                && recopied.imageFingerprint == original.imageFingerprint,
            "Recopy preserves text and image metadata")
        try TestSupport.expect(recopied.fileURLs == original.fileURLs,
                               "Recopy preserves file-backed content")
        try TestSupport.expect(
            recopied.firstCopiedAt == firstCopy
                && recopied.customTitle == original.customTitle
                && recopied.imageOCR == ocr,
            "Recopy preserves first-copy time, custom title, and OCR metadata")
        try TestSupport.expect(
            recopied.lastCopiedAt == nextCopy
                && recopied.sourceBundleID == "com.example.new"
                && recopied.copyCount == 5,
            "Recopy advances only last-copy metadata and the copy count")
    }

    private static func pinyinSemantics() throws {
        let forms = Pinyin.searchForms(for: "你好")
        try TestSupport.expect(forms.full == "nihao",
                               "Search forms contain the full Mandarin spelling")
        try TestSupport.expect(forms.initials == "nh",
                               "Search forms contain Mandarin initials")
        try TestSupport.expect(Pinyin.matches(query: "ni hao", text: "你好"),
                               "A spaced full-spelling query matches compact search forms")
        try TestSupport.expect(Pinyin.matches(query: "nh", text: "你好"),
                               "An initials query matches compact search forms")

        try TestSupport.expect(Pinyin.queryLooksLatin(" ni hao "),
                               "ASCII spelling with spaces is a valid pinyin query")
        try TestSupport.expect(!Pinyin.queryLooksLatin("chóng"),
                               "A diacritic query is not a typed pinyin query")
        try TestSupport.expect(!Pinyin.queryLooksLatin("c2"),
                               "A query containing a digit is not pinyin")
        try TestSupport.expect(!Pinyin.queryLooksLatin("hello-world"),
                               "A hyphenated query is not a typed pinyin query")

        let source = "👩‍💻你好e\u{301}中国👨‍👩‍👧‍👦"
        let nhRanges = Pinyin.matchingSourceRanges(query: "nh", text: source)
        try TestSupport.expect(
            nhRanges.count == 1
                && NSRange(nhRanges[0], in: source) == (source as NSString).range(of: "你好"),
            "Initial matching maps through emoji and combining graphemes")
        let fullRanges = Pinyin.matchingSourceRanges(query: "nihao", text: source)
        try TestSupport.expect(
            fullRanges.count == 1
                && NSRange(fullRanges[0], in: source) == (source as NSString).range(of: "你好"),
            "Full-spelling matching maps to source UTF-16 offsets")
        let zgRanges = Pinyin.matchingSourceRanges(query: "zg", text: source)
        try TestSupport.expect(
            zgRanges.count == 1
                && NSRange(zgRanges[0], in: source) == (source as NSString).range(of: "中国"),
            "Each pinyin range preserves the exact Han source slice")

        let repeated = Pinyin.matchingSourceRanges(query: "nh", text: "你好-你好")
        try TestSupport.expect(repeated.count == 2,
                               "Repeated pinyin hits produce every source range")

        let cache = Pinyin.Cache()
        let precomposed = cache.index(for: "café中")
        let decomposed = cache.index(for: "cafe\u{301}中")
        try TestSupport.expect(
            precomposed?.sourceRanges == [NSRange(location: 4, length: 1)],
            "A precomposed prefix maps Chinese to its exact UTF-16 offset")
        try TestSupport.expect(
            decomposed?.sourceRanges == [NSRange(location: 5, length: 1)],
            "A canonically equivalent source uses a distinct cache key and offset")
    }

    private static func searchHighlightSemantics() throws {
        let source = "Café CAFE cafe\u{301} CAFÉ tail"
        let ranges = SearchHighlight.matchingRanges(source: source, query: "cafe")
        try TestSupport.expect(ranges.count == 4,
                               "Literal highlighting finds every case and diacritic variant")
        let nsRanges = ranges.map { NSRange($0, in: source) }
        try TestSupport.expect(nsRanges == nsRanges.sorted { $0.location < $1.location },
                               "Repeated literal matches remain in source order")
        try TestSupport.expect(
            nsRanges.map { (source as NSString).substring(with: $0) }
                == ["Café", "CAFE", "cafe\u{301}", "CAFÉ"],
            "Case and diacritic matches preserve every source form")

        let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .semibold)
        let foreground = NSColor.systemRed
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        let tail = (source as NSString).range(of: "tail")
        let existing = NSMutableAttributedString(
            string: source,
            attributes: [
                .font: font,
                .foregroundColor: foreground,
                .paragraphStyle: paragraph,
            ])
        existing.addAttribute(
            .backgroundColor, value: NSColor.systemGreen, range: tail)

        let highlighted = SearchHighlight.applying(to: existing, query: "cafe")
        try TestSupport.expect(highlighted.string == source,
                               "Highlighting preserves the complete attributed string")
        try TestSupport.expect(highlighted !== existing,
                               "Highlighting layers onto a copied attributed string")
        for range in nsRanges {
            try TestSupport.expect(
                (highlighted.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)?
                    .fontName == font.fontName,
                "Highlighting preserves the existing font")
            try TestSupport.expect(
                (highlighted.attribute(
                    .foregroundColor, at: range.location, effectiveRange: nil) as? NSColor)?
                    .isEqual(foreground) == true,
                "Highlighting preserves the existing foreground color")
            let preservedParagraph = highlighted.attribute(
                .paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            try TestSupport.expect(
                preservedParagraph?.isEqual(paragraph) == true
                    && preservedParagraph?.lineSpacing == paragraph.lineSpacing,
                "Highlighting preserves the existing paragraph layout")
            try TestSupport.expect(
                highlighted.attribute(
                    .backgroundColor, at: range.location, effectiveRange: nil) != nil,
                "Every repeated literal range receives a search background")
        }
        try TestSupport.expect(
            (highlighted.attribute(.backgroundColor, at: tail.location, effectiveRange: nil)
                as? NSColor)?.isEqual(NSColor.systemGreen) == true,
            "Highlighting leaves existing backgrounds outside matches intact")

        let pinyinSource = "leading 你好 trailing"
        let pinyinRanges = SearchHighlight.matchingRanges(source: pinyinSource, query: "nh")
        try TestSupport.expect(
            pinyinRanges.count == 1
                && NSRange(pinyinRanges[0], in: pinyinSource)
                    == (pinyinSource as NSString).range(of: "你好"),
            "Highlight ranges include pinyin matches mapped to Han source")
    }

    private static func customTitleAndIndexedPinyin() async throws {
        let directory = try temporaryDirectory("custom-title")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory)
        let titled = try requireItem(
            store.addText("unrelated payload", kind: .text, sourceBundleID: nil),
            "The SQL title fixture is inserted")
        try execute(
            directory,
            "UPDATE items SET custom_title = 'SQL 项目' WHERE id = '\(titled.id.uuidString)'")

        let customMatches = try await collectTexts(store, query: "SQL")
        try TestSupport.expect(customMatches == ["unrelated payload"],
                               "A custom title changed by SQL is searchable through the FTS route")
        let unicodeTitleMatches = try await collectTexts(store, query: "项目")
        try TestSupport.expect(unicodeTitleMatches == ["unrelated payload"],
                               "A short Unicode query searches the SQL custom title")

        _ = try requireItem(
            store.addText("你好", kind: .text, sourceBundleID: nil),
            "The pinyin fixture is inserted")
        await store.waitForSearchMetadata()
        let fullMatches = try await collectTexts(store, query: "nihao")
        let initialMatches = try await collectTexts(store, query: "nh")
        try TestSupport.expect(fullMatches == ["你好"],
                               "The real store indexes full pinyin metadata")
        try TestSupport.expect(initialMatches == ["你好"],
                               "The real store indexes pinyin initials")
    }

    private static func escapedQuerySemantics() async throws {
        let directory = try temporaryDirectory("escaped-queries")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory)
        let short = #"short _\ % /"#
        let long = #"fts %_* /slash NOT say "alpha""#
        for text in [short, long, "plain alpha"] {
            _ = try requireItem(
                store.addText(text, kind: .text, sourceBundleID: nil),
                "The query escaping fixture is inserted")
        }

        let escapedBackslash = try await collectTexts(store, query: #"_\"#)
        try TestSupport.expect(escapedBackslash == [short],
                               "Short LIKE queries escape backslash and underscore")
        let wildcardPercent = try await collectTexts(store, query: "%")
        try TestSupport.expect(Set(wildcardPercent) == Set([short, long]),
                               "A percent query matches literal percent only")
        let wildcardUnderscore = try await collectTexts(store, query: "_")
        try TestSupport.expect(Set(wildcardUnderscore) == Set([short, long]),
                               "An underscore query matches literal underscore only")
        let slash = try await collectTexts(store, query: "/")
        try TestSupport.expect(Set(slash) == Set([short, long]),
                               "A slash query remains a literal substring")

        let longWildcard = try await collectTexts(store, query: "%_*")
        try TestSupport.expect(longWildcard == [long],
                               "A long FTS phrase treats percent underscore and star literally")
        let longSlash = try await collectTexts(store, query: "/slash")
        try TestSupport.expect(longSlash == [long],
                               "A long FTS phrase treats slash literally")
        let operatorQuery = try await collectTexts(store, query: "NOT")
        try TestSupport.expect(operatorQuery == [long],
                               "An FTS operator query is treated as a literal phrase")
        let quotedOperator = try await collectTexts(store, query: #"say "alpha""#)
        try TestSupport.expect(quotedOperator == [long],
                               "Embedded quotes are escaped without changing the query")
    }

    private static func emptyQueryFilters() async throws {
        let directory = try temporaryDirectory("empty-filters")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory)
        let text = try requireItem(
            store.addText("empty text", kind: .text, sourceBundleID: nil),
            "The text filter fixture is inserted")
        let code = try requireItem(
            store.addText("empty code", kind: .code, sourceBundleID: nil),
            "The code filter fixture is inserted")
        let stack = try requireStack(
            store.createStack(name: "Search semantics"),
            "The empty-query stack is created")
        store.assign(text.id, to: stack.id)
        store.assign(code.id, to: stack.id)

        let textMatches = try await collectTexts(
            store, query: " \n\t ", kind: .text, stackID: stack.id)
        try TestSupport.expect(textMatches == ["empty text"],
                               "A whitespace query remains empty and applies kind and stack filters")
        let stackMatches = try await collectTexts(
            store, query: "", kind: nil, stackID: stack.id)
        try TestSupport.expect(Set(stackMatches) == Set(["empty text", "empty code"]),
                               "An empty query with only a stack filter returns all members")
        let noKindMatches = try await collectTexts(
            store, query: "", kind: .image, stackID: stack.id)
        try TestSupport.expect(noKindMatches.isEmpty,
                               "An empty query with a mismatched kind returns no rows")
    }

    private static func exactTimestampCursorTies() async throws {
        let directory = try temporaryDirectory("cursor-ties")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory)
        let oldest = try requireItem(
            store.addText("tie oldest", kind: .text, sourceBundleID: nil),
            "The first cursor tie is inserted")
        let middle = try requireItem(
            store.addText("tie middle", kind: .text, sourceBundleID: nil),
            "The second cursor tie is inserted")
        let newest = try requireItem(
            store.addText("tie newest", kind: .text, sourceBundleID: nil),
            "The third cursor tie is inserted")
        let timestamp = 1_700_000_123.125
        try execute(
            directory,
            """
            UPDATE items SET created_at = \(timestamp)
            WHERE id IN (
              '\(oldest.id.uuidString)',
              '\(middle.id.uuidString)',
              '\(newest.id.uuidString)'
            )
            """)

        let first = await store.searchAsync("", after: nil, limit: 1)
        try TestSupport.expect(first.items.map(\.id) == [newest.id],
                               "Exact timestamp ties use descending row ID as the total order")
        let firstCursor = try requireCursor(
            first.nextCursor,
            "The tied first page exposes a next cursor")
        try TestSupport.expect(
            firstCursor.lastCopiedAt == Date(timeIntervalSince1970: timestamp),
            "The cursor retains the exact timestamp")

        let second = await store.searchAsync("", after: firstCursor, limit: 1)
        try TestSupport.expect(second.items.map(\.id) == [middle.id],
                               "A cursor with an exact timestamp continues at the next row ID")
        let secondCursor = try requireCursor(
            second.nextCursor,
            "The tied second page exposes a next cursor")
        let third = await store.searchAsync("", after: secondCursor, limit: 1)
        try TestSupport.expect(
            third.items.map(\.id) == [oldest.id] && third.nextCursor == nil,
            "Exact timestamp pagination returns every tied row once")
    }

    private static func residentMergeSemantics() async throws {
        let directory = try temporaryDirectory("resident-merge")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory)
        let databaseItem = try requireItem(
            store.addText("resident database hit", kind: .text, sourceBundleID: nil),
            "The resident merge database fixture is inserted")
        let timestamp = 1_700_000_456.75
        try execute(
            directory,
            "UPDATE items SET created_at = \(timestamp) WHERE id = '\(databaseItem.id.uuidString)'")
        store.load()
        let loadedDatabaseItem = try requireItem(
            store.item(id: databaseItem.id),
            "The resident merge fixture reloads from SQLite")
        let overlay = ClipboardItem(
            id: UUID(), kind: .text, text: "resident overlay hit",
            imagePath: nil, imageFingerprint: nil,
            lastCopiedAt: Date(timeIntervalSince1970: timestamp),
            sourceBundleID: nil)
        let path = directory.appendingPathComponent("clipboard.sqlite3").path

        let firstPage = ClipboardSearch.query(
            path: path, query: "resident", kind: nil, stackID: nil,
            after: nil, limit: 10, includesImageText: false,
            residentItems: [loadedDatabaseItem, overlay])
        let secondPage = ClipboardSearch.query(
            path: path, query: "resident", kind: nil, stackID: nil,
            after: nil, limit: 10, includesImageText: false,
            residentItems: [overlay, loadedDatabaseItem])
        try TestSupport.expect(firstPage != nil && secondPage != nil,
                               "Resident merge queries complete against the real store")
        try TestSupport.expect(
            firstPage?.items.map(\.id) == [loadedDatabaseItem.id, overlay.id]
                && secondPage?.items.map(\.id) == [loadedDatabaseItem.id, overlay.id],
            "Resident additions preserve database-first order for exact timestamp ties")
        try TestSupport.expect(
            firstPage?.items.count == Set(firstPage?.items.map(\.id) ?? []).count,
            "A database hit repeated in the resident snapshot is not duplicated")
    }

    private static func cancellationAndUnavailableDatabase() async throws {
        let directory = try temporaryDirectory("unavailable-database")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory)
        _ = try requireItem(
            store.addText("cancelled query", kind: .text, sourceBundleID: nil),
            "The cancellation fixture is inserted")
        let path = directory.appendingPathComponent("clipboard.sqlite3").path

        let cancelled = Task { () -> ClipboardSearchPage? in
            withUnsafeCurrentTask { $0?.cancel() }
            return ClipboardSearch.queryDatabase(
                path: path, query: "", kind: nil, stackID: nil,
                after: nil, limit: 10)
        }
        let cancelledPage = await cancelled.value
        try TestSupport.expect(cancelledPage == nil,
                               "A cancelled database query reports no partial page")

        let missingPath = directory.appendingPathComponent("missing/db.sqlite3").path
        let unavailablePage = ClipboardSearch.queryDatabase(
            path: missingPath, query: "", kind: nil, stackID: nil,
            after: nil, limit: 10)
        try TestSupport.expect(unavailablePage == nil,
                               "An unavailable database is distinct from an empty page")
    }

    private static func temporaryDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kit-search-semantics-\(label)-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func makeStore(in directory: URL) -> ClipboardStore {
        let store = ClipboardStore(directory: directory, maintenanceInterval: 86_400)
        store.setImageTextSearchEnabled(false)
        store.maxAge = ClipboardRetention.forever.maxAge
        store.load()
        return store
    }

    private static func requireItem(
        _ item: ClipboardItem?, _ message: String
    ) throws -> ClipboardItem {
        try TestSupport.expect(item != nil, message)
        guard let item else { throw Failure.database(message) }
        return item
    }

    private static func requireStack(
        _ stack: ClipboardStack?, _ message: String
    ) throws -> ClipboardStack {
        try TestSupport.expect(stack != nil, message)
        guard let stack else { throw Failure.database(message) }
        return stack
    }

    private static func requireCursor(
        _ cursor: ClipboardSearchCursor?, _ message: String
    ) throws -> ClipboardSearchCursor {
        try TestSupport.expect(cursor != nil, message)
        guard let cursor else { throw Failure.database(message) }
        return cursor
    }

    private static func collectTexts(
        _ store: ClipboardStore, query: String,
        kind: ClipboardItem.Kind? = nil, stackID: ClipboardStack.ID? = nil
    ) async throws -> [String] {
        var values: [String] = []
        var cursor: ClipboardSearchCursor?
        var pageCount = 0
        repeat {
            let page = await store.searchAsync(
                query, kind: kind, stackID: stackID, after: cursor, limit: 10)
            values.append(contentsOf: page.items.compactMap(\.text))
            cursor = page.nextCursor
            pageCount += 1
            try TestSupport.expect(pageCount < 20,
                                   "Search pagination terminates")
        } while cursor != nil
        return values
    }

    private static func execute(_ directory: URL, _ sql: String) throws {
        let path = directory.appendingPathComponent("clipboard.sqlite3").path
        var database: OpaquePointer?
        let openStatus = sqlite3_open(path, &database)
        if openStatus != SQLITE_OK {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "unknown SQLite error"
            sqlite3_close_v2(database)
            throw Failure.database("Unable to open SQLite: \(message)")
        }
        guard let database else {
            throw Failure.database("SQLite returned no connection")
        }
        defer { sqlite3_close_v2(database) }
        let status = sqlite3_exec(database, sql, nil, nil, nil)
        try TestSupport.expect(
            status == SQLITE_OK,
            "SQLite statement failed: \(String(cString: sqlite3_errmsg(database)))")
    }
}

private extension ClipboardItem {
    func withCustomTitle(_ customTitle: String) -> ClipboardItem {
        ClipboardItem(
            id: id, kind: kind, text: text, imagePath: imagePath,
            imageFingerprint: imageFingerprint, fileURLs: fileURLs, fileIsImage: fileIsImage,
            lastCopiedAt: lastCopiedAt, sourceBundleID: sourceBundleID,
            customTitle: customTitle, firstCopiedAt: firstCopiedAt,
            copyCount: copyCount, imageOCR: imageOCR)
    }
}
