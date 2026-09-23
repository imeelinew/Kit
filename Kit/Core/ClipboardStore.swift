import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct ClipboardItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case text, code, link, image

        /// Localization key for the stored kind. The Information panel uses `displayKind`.
        var typeLabel: String {
            switch self {
            case .text: "Plain Text"
            case .code: "Code"
            case .link: "Link"
            case .image: "Image"
            }
        }
    }

    /// User-visible type, including Markdown detected by the existing classifiers.
    enum DisplayKind: Equatable, Sendable {
        case text, markdown, code, link, image

        var typeLabel: String {
            switch self {
            case .text: Kind.text.typeLabel
            case .markdown: "Markdown"
            case .code: Kind.code.typeLabel
            case .link: Kind.link.typeLabel
            case .image: Kind.image.typeLabel
            }
        }

        /// Same rules as the Information "Type" row: stored kind, with Markdown overlay for text/code.
        static func classify(kind: Kind, text: String?) -> DisplayKind {
            switch kind {
            case .image:
                return .image
            case .link:
                return .link
            case .text:
                if let text, MarkdownAttributedRenderer.isMarkdown(text) { return .markdown }
                return .text
            case .code:
                if let text, ClipboardTextClassifier.isMarkdownArticle(text) { return .markdown }
                return .code
            }
        }
    }

    let id: UUID
    let kind: Kind
    let text: String?
    /// Absolute path to the image owned by this store.
    let imagePath: String?
    /// SHA-256 of canonical visible pixels. Text rows leave it nil.
    let imageFingerprint: String?
    let createdAt: Date
    /// Bundle ID of the app frontmost when the copy was captured (see `ClipboardManager.poll`).
    let sourceBundleID: String?
    let pinnedAt: Date?
    /// User-assigned list title. Nil means the visible title is derived from the copied content.
    let customTitle: String?

    /// User-visible type shown in the Information panel and used by the type filter.
    var displayKind: DisplayKind {
        DisplayKind.classify(kind: kind, text: text)
    }

    init(text: String, sourceBundleID: String?) {
        self.init(
            id: UUID(), kind: ClipboardTextClassifier.kind(for: text), text: text,
            imagePath: nil, imageFingerprint: nil, createdAt: Date(),
            sourceBundleID: sourceBundleID)
    }

    init(imagePath: String, imageFingerprint: String, sourceBundleID: String?) {
        self.init(
            id: UUID(), kind: .image, text: nil, imagePath: imagePath,
            imageFingerprint: imageFingerprint, createdAt: Date(), sourceBundleID: sourceBundleID)
    }

    fileprivate init(
        id: UUID, kind: Kind, text: String?, imagePath: String?, imageFingerprint: String?,
        createdAt: Date, sourceBundleID: String?, pinnedAt: Date? = nil,
        customTitle: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.imagePath = imagePath
        self.imageFingerprint = imageFingerprint
        self.createdAt = createdAt
        self.sourceBundleID = sourceBundleID
        self.pinnedAt = pinnedAt
        self.customTitle = customTitle
    }

    /// Copy with the two fields the store rewrites in place; the pin is stated outright because every rewrite either stamps it or drops the row back into the history.
    func with(createdAt: Date? = nil, pinnedAt: Date?) -> ClipboardItem {
        ClipboardItem(
            id: id, kind: kind, text: text, imagePath: imagePath,
            imageFingerprint: imageFingerprint, createdAt: createdAt ?? self.createdAt,
            sourceBundleID: sourceBundleID, pinnedAt: pinnedAt, customTitle: customTitle)
    }

    func withCustomTitle(_ customTitle: String?) -> ClipboardItem {
        ClipboardItem(
            id: id, kind: kind, text: text, imagePath: imagePath,
            imageFingerprint: imageFingerprint, createdAt: createdAt,
            sourceBundleID: sourceBundleID, pinnedAt: pinnedAt, customTitle: customTitle)
    }

    /// A repeated image is the same entry with a fresh copy time and source application.
    func refreshed(sourceBundleID: String?) -> ClipboardItem {
        ClipboardItem(
            id: id, kind: kind, text: text, imagePath: imagePath,
            imageFingerprint: imageFingerprint, createdAt: Date(),
            sourceBundleID: sourceBundleID, pinnedAt: pinnedAt, customTitle: customTitle)
    }

    /// Visible list/card title: a persisted custom name, otherwise the first line of text or "Image".
    func displayTitle(locale: Locale) -> String {
        if let customTitle {
            let trimmed = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return defaultTitle(locale: locale)
    }

    func defaultTitle(locale: Locale) -> String {
        switch kind {
        case .image:
            return String(localized: "Image", locale: locale)
        case .text, .code, .link:
            let text = String((text ?? "").prefix(200)).trimmingCharacters(
                in: .whitespacesAndNewlines)
            let lineEnd = text.firstIndex(where: { $0.isNewline }) ?? text.endIndex
            return String(text[..<lineEnd])
        }
    }

    /// Case-insensitive literal or pinyin match for resident and pinned entries.
    /// Latin-letter queries also match Mandarin pinyin (full spelling or initials) so `nihao` / `nh` can find `你好`.
    func matches(_ query: String) -> Bool {
        if matches(query, in: customTitle) { return true }
        guard let text else { return false }
        return matches(query, in: text)
    }

    private func matches(_ query: String, in text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        if text.localizedCaseInsensitiveContains(query) { return true }
        guard Pinyin.queryLooksLatin(query) else { return false }
        return Pinyin.matches(query: query, text: text)
    }
}

/// Mandarin romanization helpers for clipboard search (Foundation/`CFStringTransform` only).
enum Pinyin {
    struct SearchForms: Sendable {
        let full: String
        let initials: String
    }

    /// True when `query` is ASCII letters/spaces/apostrophes — the shape of typed pinyin.
    static func queryLooksLatin(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var sawLetter = false
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                guard scalar.value <= 127 else { return false }
                sawLetter = true
            } else if !(CharacterSet.whitespaces.contains(scalar) || scalar == "'") {
                return false
            }
        }
        return sawLetter
    }

    fileprivate static func matches(query: String, text: String) -> Bool {
        !matchingSourceRanges(query: query, text: text).isEmpty
    }

    /// Source-character ranges whose Mandarin pinyin (full spelling or initials) contains `query`.
    static func matchingSourceRanges(query: String, text: String) -> [Range<String.Index>] {
        let q = compact(query)
        guard !q.isEmpty else { return [] }

        let syllables = syllables(of: text)
        guard !syllables.isEmpty else { return [] }

        var ranges = rangesMatching(
            query: q, syllables: syllables,
            token: \.compact)
        if ranges.isEmpty {
            ranges = rangesMatching(
                query: q, syllables: syllables,
                token: \.initial)
        }
        return ranges
    }

    private static func romanize(_ text: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        return (mutable as String).lowercased()
    }

    /// Persistent search terms contain only Han characters. Latin text already has a literal FTS
    /// path, so excluding it avoids thousands of unnecessary Core Foundation transforms for the
    /// overwhelmingly common English query.
    fileprivate static func searchForms(for text: String) -> SearchForms {
        var full = ""
        var initials = ""
        for character in text where containsHan(character) {
            let syllable = compact(romanize(String(character)))
            guard !syllable.isEmpty else { continue }
            full += syllable
            initials.append(syllable.first!)
        }
        return SearchForms(full: full, initials: initials)
    }

    fileprivate static func containsHan(_ text: String) -> Bool {
        text.contains(where: containsHan)
    }

    private struct Syllable {
        let range: Range<String.Index>
        let compact: String
        let initial: String
    }

    private static func syllables(of text: String) -> [Syllable] {
        var result: [Syllable] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            let unit = String(text[index..<next])
            guard containsHan(text[index]) else {
                index = next
                continue
            }
            let romanized = compact(romanize(unit))
            if !romanized.isEmpty {
                result.append(
                    Syllable(
                        range: index..<next,
                        compact: romanized,
                        initial: String(romanized.prefix(1))))
            }
            index = next
        }
        return result
    }

    private static func rangesMatching(
        query: String, syllables: [Syllable],
        token: KeyPath<Syllable, String>
    ) -> [Range<String.Index>] {
        var concat = ""
        var map: [Int] = []
        for (syllableIndex, syllable) in syllables.enumerated() {
            let piece = syllable[keyPath: token]
            guard !piece.isEmpty else { continue }
            for _ in piece {
                map.append(syllableIndex)
            }
            concat += piece
        }
        guard !concat.isEmpty, !map.isEmpty else { return [] }

        var ranges: [Range<String.Index>] = []
        var searchStart = concat.startIndex
        while searchStart < concat.endIndex,
            let match = concat.range(of: query, range: searchStart..<concat.endIndex)
        {
            let lowerOffset = concat.distance(from: concat.startIndex, to: match.lowerBound)
            let upperOffset = concat.distance(from: concat.startIndex, to: match.upperBound) - 1
            guard map.indices.contains(lowerOffset), map.indices.contains(upperOffset) else { break }
            let start = syllables[map[lowerOffset]].range.lowerBound
            let end = syllables[map[upperOffset]].range.upperBound
            ranges.append(start..<end)
            searchStart = match.upperBound
        }
        return ranges
    }

    private static func compact(_ string: String) -> String {
        string.lowercased().filter(\.isLetter)
    }

    private static func containsHan(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                0x20000...0x2FA1F:
                return true
            default:
                return false
            }
        }
    }
}

/// How long clipboard history is kept before pruning; raw value is the age in days persisted to UserDefaults, and `forever` is -1 so an unset key (0) falls through to the default.
enum ClipboardRetention: Int, CaseIterable, Identifiable, Sendable {
    case day = 1
    case week = 7
    case month = 30
    case threeMonths = 90
    case sixMonths = 180
    case year = 365
    case forever = -1

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .day: return "1 Day"
        case .week: return "1 Week"
        case .month: return "1 Month"
        case .threeMonths: return "3 Months"
        case .sixMonths: return "6 Months"
        case .year: return "1 Year"
        case .forever: return "Forever"
        }
    }

    var maxAge: TimeInterval {
        self == .forever ? .greatestFiniteMagnitude : TimeInterval(rawValue) * 86_400
    }
}

/// A named group. An item belongs to at most one stack.
struct ClipboardStack: Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    var name: String
}

/// SQLite-backed clipboard history (rows + trigram FTS5 index in `clipboard.sqlite3`, image blobs on disk).
@MainActor
final class ClipboardStore: ObservableObject {
    /// Newest-first, pins included in place. Every pinned row remains resident however old it is.
    @Published private(set) var items: [ClipboardItem] = [] {
        didSet {
            orderedCache = nil
            revision &+= 1
        }
    }
    @Published private(set) var revision: UInt64 = 0
    /// Named stacks. Empty until creation is wired up.
    @Published private(set) var stacks: [ClipboardStack] = []
    /// Item id to the single stack that owns it.
    private var stackMembership: [ClipboardItem.ID: ClipboardStack.ID] = [:]
    /// Fired after a new history row is inserted, not on recopy-of-top or image refresh.
    var onItemInserted: (() -> Void)?
    private(set) var captureGeneration: UInt64 = 0
    var maxAge: TimeInterval = ClipboardRetention.threeMonths.maxAge

    /// Memoized display order, invalidated on mutation.
    private var orderedCache: [ClipboardItem]?

    private static let memoryWindow = 1000

    private static let coreSchema = """
        CREATE TABLE IF NOT EXISTS items(
          id TEXT NOT NULL UNIQUE,
          kind TEXT NOT NULL,
          text TEXT,
          image_path TEXT,
          created_at REAL NOT NULL,
          source_app TEXT,
          pinned_at REAL,
          image_fingerprint TEXT,
          custom_title TEXT,
          pinyin TEXT,
          pinyin_initials TEXT
        );
        CREATE INDEX IF NOT EXISTS items_created_at ON items(created_at);
        CREATE INDEX IF NOT EXISTS items_pinned_at
          ON items(pinned_at) WHERE pinned_at IS NOT NULL;
        CREATE UNIQUE INDEX IF NOT EXISTS items_image_fingerprint
          ON items(image_fingerprint) WHERE image_fingerprint IS NOT NULL;
        CREATE TABLE IF NOT EXISTS stacks(
          id TEXT NOT NULL UNIQUE,
          name TEXT NOT NULL,
          position INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS stack_items(
          item_id TEXT NOT NULL UNIQUE,
          stack_id TEXT NOT NULL
        );
        """

    private static let searchSchema = """
        CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
          text, pinyin, pinyin_initials,
          content='items', content_rowid='rowid', tokenize='trigram'
        );
        CREATE TRIGGER IF NOT EXISTS items_ai AFTER INSERT ON items BEGIN
          INSERT INTO items_fts(rowid, text, pinyin, pinyin_initials)
          VALUES(new.rowid, new.text, new.pinyin, new.pinyin_initials);
        END;
        CREATE TRIGGER IF NOT EXISTS items_ad AFTER DELETE ON items BEGIN
          INSERT INTO items_fts(items_fts, rowid, text, pinyin, pinyin_initials)
          VALUES('delete', old.rowid, old.text, old.pinyin, old.pinyin_initials);
        END;
        CREATE TRIGGER IF NOT EXISTS items_au
        AFTER UPDATE OF text, pinyin, pinyin_initials ON items BEGIN
          INSERT INTO items_fts(items_fts, rowid, text, pinyin, pinyin_initials)
          VALUES('delete', old.rowid, old.text, old.pinyin, old.pinyin_initials);
          INSERT INTO items_fts(rowid, text, pinyin, pinyin_initials)
          VALUES(new.rowid, new.text, new.pinyin, new.pinyin_initials);
        END;
        """

    private let imagesDir: URL
    private let dbURL: URL
    private var db: OpaquePointer?
    private var insertStmt: OpaquePointer?
    private var loadStmt: OpaquePointer?
    private var windowFloorStmt: OpaquePointer?
    private var deleteByIDStmt: OpaquePointer?
    private var staleImagesStmt: OpaquePointer?
    private var deleteStaleStmt: OpaquePointer?
    private var imageByFingerprintStmt: OpaquePointer?
    private var itemByIDStmt: OpaquePointer?
    private var insertStackStmt: OpaquePointer?
    private var upsertMembershipStmt: OpaquePointer?
    private var deleteMembershipStmt: OpaquePointer?
    private var pendingSearchMetadata: [SearchMetadataUpdate] = []
    private var searchMetadataTask: Task<Void, Never>?

    private struct SearchMetadataUpdate: Sendable {
        let id: String
        let text: String
        var retryCount = 0
    }

    /// Tests pass a throwaway directory so a harness run can never reach real history.
    init(directory: URL? = nil) {
        let base = directory ?? Self.defaultDirectory
        imagesDir = base.appendingPathComponent("images", isDirectory: true)
        dbURL = base.appendingPathComponent("clipboard.sqlite3")
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        _ = openDatabase()
    }

    private static var defaultDirectory: URL {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            preconditionFailure("Paste requires a bundle identifier")
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
    }

    // Isolated so teardown may touch the main-actor statement/db pointers; AppCore only ever releases the store on the main actor, so no hop.
    isolated deinit {
        closeDatabase()
    }

    func load() {
        loadStackState()
        guard let stmt = loadStmt else { return }
        sqlite3_bind_int64(stmt, 1, windowFloor())
        var loaded: [ClipboardItem] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            if let item = Self.row(stmt) { loaded.append(item) }
            status = sqlite3_step(stmt)
        }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        guard status == SQLITE_DONE else { return }
        items = loaded
        // Age passes while the app isn't running; insert-time pruning alone can't catch that.
        enforceLimits()
    }

    /// Called on load and when the retention setting changes.
    func enforceLimits() {
        prune()
    }

    /// Rowid of the oldest unpinned row the in-memory window keeps — the floor `loadStmt` reads from. 0 (no floor, load everything) when the history is shorter than the window.
    private func windowFloor() -> sqlite3_int64 {
        guard let stmt = windowFloorStmt else { return 0 }
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        sqlite3_bind_int(stmt, 1, Int32(Self.memoryWindow - 1))
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0
    }

    @discardableResult
    func addText(
        _ text: String, sourceBundleID: String?, expectedGeneration: UInt64? = nil
    ) -> ClipboardItem? {
        if let expectedGeneration, expectedGeneration != captureGeneration { return nil }
        if items.first?.kind != .image, items.first?.text == text { return items.first }
        let item = ClipboardItem(text: text, sourceBundleID: sourceBundleID)
        return insert(item) ? item : nil
    }

    func addImage(
        _ data: Data, sourceBundleID: String?, expectedGeneration: UInt64? = nil
    ) async {
        let generation = expectedGeneration ?? captureGeneration
        guard !Task.isCancelled, generation == captureGeneration else { return }
        let fingerprint = await Task.detached(priority: .utility) {
            ImageFingerprint.digest(data: data)
        }.value
        guard !Task.isCancelled, generation == captureGeneration else { return }
        if let existing = image(matching: fingerprint) {
            reinsert(existing.refreshed(sourceBundleID: sourceBundleID))
            return
        }
        let url = imagesDir.appendingPathComponent(UUID().uuidString + ".png")
        let item = ClipboardItem(
            imagePath: url.path, imageFingerprint: fingerprint,
            sourceBundleID: sourceBundleID)
        let wrote = await Task.detached(priority: .utility) {
            (try? data.write(to: url, options: .atomic)) != nil
        }.value
        guard wrote else { return }
        guard !Task.isCancelled, generation == captureGeneration else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard insert(item) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
    }

    /// Move an item to the top of history after it is used.
    func promote(_ item: ClipboardItem) {
        guard items.first?.id != item.id else { return }
        // An asynchronous paste may finish after the item or its stack was deleted.
        guard let stored = loadItem(id: item.id) else { return }
        reinsert(stored.with(createdAt: Date(), pinnedAt: nil))
    }

    func item(id: ClipboardItem.ID) -> ClipboardItem? {
        if let item = items.first(where: { $0.id == id }) { return item }
        return loadItem(id: id)
    }

    func remove(_ item: ClipboardItem) {
        guard let stmt = deleteByIDStmt else { return }
        sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, SQLITE_TRANSIENT)
        guard stepAndReset(stmt) else { return }
        items.removeAll { $0.id == item.id }
        deleteMembership(item.id)
        deleteBlob(item)
    }

    func clearAll() {
        captureGeneration &+= 1
        searchMetadataTask?.cancel()
        pendingSearchMetadata.removeAll()
        guard sqlite3_exec(db, "DELETE FROM items", nil, nil, nil) == SQLITE_OK else { return }
        items = []
        sqlite3_exec(db, "DELETE FROM stack_items", nil, nil, nil)
        stackMembership.removeAll()
        try? FileManager.default.removeItem(at: imagesDir)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
    }

    func imageURL(for item: ClipboardItem) -> URL? {
        guard let path = item.imagePath else { return nil }
        return managedBlobURL(for: path)
    }

    var displayItems: [ClipboardItem] { orderedItems }

    func stackID(for itemID: ClipboardItem.ID) -> ClipboardStack.ID? {
        stackMembership[itemID]
    }

    /// Moves an item into `stackID`, leaving any stack it was in before.
    func assign(_ itemID: ClipboardItem.ID, to stackID: ClipboardStack.ID) {
        guard stacks.contains(where: { $0.id == stackID }) else { return }
        guard stackMembership[itemID] != stackID else { return }
        guard writeMembership(itemID, stackID: stackID) else { return }
        stackMembership[itemID] = stackID
        revision &+= 1
    }

    func createStack(name: String) -> ClipboardStack? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let stmt = insertStackStmt else { return nil }
        let stack = ClipboardStack(id: UUID(), name: trimmed)
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_text(stmt, 1, stack.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, trimmed, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 3, sqlite3_int64(stacks.count))
        guard stepAndReset(stmt) else { return nil }
        stacks.append(stack)
        return stack
    }

    func renameStack(_ id: ClipboardStack.ID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = stacks.firstIndex(where: { $0.id == id }) else {
            return false
        }
        if stacks[index].name == trimmed { return true }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "UPDATE stacks SET name = ? WHERE id = ?", -1, &stmt, nil)
            == SQLITE_OK, let stmt
        else { return false }
        sqlite3_bind_text(stmt, 1, trimmed, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, id.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        stacks[index].name = trimmed
        return true
    }

    /// Remove a stack together with every history row assigned to it.
    @discardableResult
    func deleteStack(_ id: ClipboardStack.ID) -> Bool {
        guard stacks.contains(where: { $0.id == id }),
            sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK
        else { return false }
        var committed = false
        defer {
            if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        }

        guard let contents = stackContents(id),
            deleteStackRows(
                "DELETE FROM items WHERE id IN (SELECT item_id FROM stack_items WHERE stack_id = ?)",
                stackID: id),
            deleteStackRows("DELETE FROM stack_items WHERE stack_id = ?", stackID: id),
            deleteStackRows("DELETE FROM stacks WHERE id = ?", stackID: id),
            sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK
        else { return false }
        committed = true

        stacks.removeAll { $0.id == id }
        stackMembership = stackMembership.filter { $0.value != id }
        let remaining = items.filter { !contents.itemIDs.contains($0.id) }
        if remaining.count != items.count {
            items = remaining
        } else {
            revision &+= 1
        }
        for url in contents.imageURLs {
            try? FileManager.default.removeItem(at: url)
        }
        return true
    }

    private func stackContents(
        _ id: ClipboardStack.ID
    ) -> (itemIDs: Set<ClipboardItem.ID>, imageURLs: [URL])? {
        guard let stmt = prepare(
            """
            SELECT i.id, i.image_path FROM items i
            JOIN stack_items s ON s.item_id = i.id
            WHERE s.stack_id = ?
            """)
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT) == SQLITE_OK
        else { return nil }

        var itemIDs = Set<ClipboardItem.ID>()
        var imageURLs: [URL] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            if let idString = Self.columnString(stmt, 0), let itemID = UUID(uuidString: idString) {
                itemIDs.insert(itemID)
            }
            if let path = Self.columnString(stmt, 1), let url = managedBlobURL(for: path) {
                imageURLs.append(url)
            }
            status = sqlite3_step(stmt)
        }
        return status == SQLITE_DONE ? (itemIDs, imageURLs) : nil
    }

    private func deleteStackRows(_ sql: String, stackID: ClipboardStack.ID) -> Bool {
        guard let stmt = prepare(sql) else { return false }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_text(stmt, 1, stackID.uuidString, -1, SQLITE_TRANSIENT) == SQLITE_OK
        else { return false }
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func loadStackState() {
        stacks = []
        stackMembership = [:]
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(
            db, "SELECT id, name FROM stacks ORDER BY position, rowid", -1, &stmt, nil
        ) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let idString = Self.columnString(stmt, 0),
                    let id = UUID(uuidString: idString),
                    let name = Self.columnString(stmt, 1)
                {
                    stacks.append(ClipboardStack(id: id, name: name))
                }
            }
        }
        sqlite3_finalize(stmt)
        stmt = nil
        sqlite3_exec(
            db, "DELETE FROM stack_items WHERE item_id NOT IN (SELECT id FROM items)",
            nil, nil, nil)
        if sqlite3_prepare_v2(
            db, "SELECT item_id, stack_id FROM stack_items", -1, &stmt, nil
        ) == SQLITE_OK {
            let known = Set(stacks.map(\.id))
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let itemString = Self.columnString(stmt, 0),
                    let itemID = UUID(uuidString: itemString),
                    let stackString = Self.columnString(stmt, 1),
                    let stackID = UUID(uuidString: stackString),
                    known.contains(stackID)
                else { continue }
                stackMembership[itemID] = stackID
            }
        }
        sqlite3_finalize(stmt)
    }

    private func writeMembership(_ itemID: ClipboardItem.ID, stackID: ClipboardStack.ID) -> Bool {
        guard let stmt = upsertMembershipStmt else { return false }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_text(stmt, 1, itemID.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, stackID.uuidString, -1, SQLITE_TRANSIENT)
        return stepAndReset(stmt)
    }

    private func deleteMembership(_ itemID: ClipboardItem.ID) {
        stackMembership.removeValue(forKey: itemID)
        guard let stmt = deleteMembershipStmt else { return }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_text(stmt, 1, itemID.uuidString, -1, SQLITE_TRANSIENT)
        _ = stepAndReset(stmt)
    }

    /// Full-history search for the UI. SQLite work and resident pinyin matching both run outside the
    /// main actor; cancellation discards an obsolete keystroke's result before it reaches SwiftUI.
    func searchAsync(
        _ query: String, displayKind: ClipboardItem.DisplayKind? = nil
    ) async -> [ClipboardItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty || displayKind != nil else { return orderedItems }

        let resident = items
        let path = dbURL.path
        let databaseTask = Task.detached(priority: .userInitiated) {
            () -> [ClipboardItem] in
            guard !Task.isCancelled else { return [] }
            return Self.queryDatabase(
                path: path, query: q, displayKind: displayKind) ?? []
        }
        let residentTask = Task.detached(priority: .userInitiated) {
            () -> [ClipboardItem] in
            guard !Task.isCancelled else { return [] }
            return resident.filter {
                (q.isEmpty || $0.matches(q))
                    && (displayKind == nil || $0.displayKind == displayKind)
            }
        }
        let (databaseResult, residentResult) = await withTaskCancellationHandler {
            await (databaseTask.value, residentTask.value)
        } onCancel: {
            databaseTask.cancel()
            residentTask.cancel()
        }
        guard !Task.isCancelled else { return [] }

        var seen = Set<ClipboardItem.ID>()
        var matches: [ClipboardItem] = []
        for item in databaseResult where seen.insert(item.id).inserted {
            matches.append(item)
        }
        // Newly captured rows may still be waiting for their persistent pinyin metadata; merge the
        // resident window so they remain searchable immediately.
        for item in residentResult where seen.insert(item.id).inserted {
            matches.append(item)
        }
        return Self.displayOrder(matches)
    }

    private nonisolated static func queryDatabase(
        path: String, query: String, displayKind: ClipboardItem.DisplayKind?
    ) -> [ClipboardItem]? {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
            let connection
        else {
            sqlite3_close_v2(connection)
            return nil
        }
        defer { sqlite3_close_v2(connection) }
        sqlite3_busy_timeout(connection, 500)

        let usesFTS = query.count >= 3
        let sql = query.isEmpty
            ? """
              SELECT id, kind, text, image_path, created_at, source_app, pinned_at,
                     image_fingerprint, custom_title
              FROM items ORDER BY rowid DESC
              """
            : usesFTS
            ? """
              SELECT i.id, i.kind, i.text, i.image_path, i.created_at, i.source_app,
                     i.pinned_at, i.image_fingerprint, i.custom_title
              FROM items_fts f JOIN items i ON i.rowid = f.rowid
              WHERE items_fts MATCH ? ORDER BY f.rowid DESC
              """
            : """
              SELECT id, kind, text, image_path, created_at, source_app, pinned_at,
                     image_fingerprint, custom_title
              FROM items
              WHERE text LIKE ? ESCAPE '\\' OR pinyin LIKE ? ESCAPE '\\'
                 OR pinyin_initials LIKE ? ESCAPE '\\'
                 OR custom_title LIKE ? ESCAPE '\\'
              ORDER BY rowid DESC
              """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"

        if usesFTS {
            let match = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            sqlite3_bind_text(statement, 1, match, -1, SQLITE_TRANSIENT)
        } else if !query.isEmpty {
            for index in 1...4 {
                sqlite3_bind_text(statement, Int32(index), pattern, -1, SQLITE_TRANSIENT)
            }
        }

        // Count accepted types rather than truncating candidates in SQL. Markdown is
        // derived from content and cannot be filtered by the stored kind alone.
        var results: [ClipboardItem] = []
        var seen = Set<UUID>()
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if Task.isCancelled { return nil }
            if let item = row(statement),
                displayKind == nil || item.displayKind == displayKind,
                seen.insert(item.id).inserted
            {
                results.append(item)
                if results.count == 2000 { break }
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE || results.count == 2000 else { return nil }

        if usesFTS {
            let titleMatches = queryCustomTitles(
                connection: connection, pattern: pattern, displayKind: displayKind)
            guard let titleMatches else { return nil }
            for item in titleMatches where seen.insert(item.id).inserted {
                results.append(item)
            }
        }
        return results
    }

    func waitForSearchMetadata() async {
        await searchMetadataTask?.value
    }

    private func scheduleSearchMetadataUpdate(for item: ClipboardItem) {
        guard let text = item.text, Pinyin.containsHan(text) else { return }
        pendingSearchMetadata.append(
            SearchMetadataUpdate(id: item.id.uuidString, text: text))
        startSearchMetadataWorkerIfNeeded()
    }

    private func startSearchMetadataWorkerIfNeeded() {
        guard searchMetadataTask == nil, !pendingSearchMetadata.isEmpty else { return }
        searchMetadataTask = Task { [weak self] in
            await self?.drainSearchMetadataQueue()
        }
    }

    private func drainSearchMetadataQueue() async {
        defer {
            searchMetadataTask = nil
            startSearchMetadataWorkerIfNeeded()
        }
        while !Task.isCancelled, !pendingSearchMetadata.isEmpty {
            let batch = pendingSearchMetadata
            pendingSearchMetadata.removeAll(keepingCapacity: true)
            let path = dbURL.path
            let updated = await Task.detached(priority: .utility) {
                Self.updateSearchMetadata(path: path, batch: batch)
            }.value
            guard !Task.isCancelled else { return }
            if updated {
                revision &+= 1
            } else {
                let retry = batch.compactMap { entry -> SearchMetadataUpdate? in
                    guard entry.retryCount == 0 else { return nil }
                    var entry = entry
                    entry.retryCount += 1
                    return entry
                }
                pendingSearchMetadata.insert(contentsOf: retry, at: 0)
                if !retry.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            }
        }
    }

    private nonisolated static func updateSearchMetadata(
        path: String, batch: [SearchMetadataUpdate]
    ) -> Bool {
        var connection: OpaquePointer?
        guard
            sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
            let connection
        else {
            sqlite3_close_v2(connection)
            return false
        }
        defer { sqlite3_close_v2(connection) }
        sqlite3_busy_timeout(connection, 1000)
        var update: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                connection,
                "UPDATE items SET pinyin = ?, pinyin_initials = ? WHERE id = ?", -1, &update,
                nil) == SQLITE_OK,
            let update
        else {
            sqlite3_finalize(update)
            return false
        }
        defer { sqlite3_finalize(update) }
        guard sqlite3_exec(connection, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            return false
        }
        var committed = false
        defer {
            if !committed { sqlite3_exec(connection, "ROLLBACK", nil, nil, nil) }
        }
        for entry in batch {
            guard !Task.isCancelled else { return false }
            let forms = Pinyin.searchForms(for: entry.text)
            sqlite3_bind_text(update, 1, forms.full, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(update, 2, forms.initials, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(update, 3, entry.id, -1, SQLITE_TRANSIENT)
            let status = sqlite3_step(update)
            sqlite3_reset(update)
            sqlite3_clear_bindings(update)
            guard status == SQLITE_DONE else { return false }
        }
        committed = sqlite3_exec(connection, "COMMIT", nil, nil, nil) == SQLITE_OK
        return committed
    }

    // MARK: - Private

    private var orderedItems: [ClipboardItem] {
        if let orderedCache { return orderedCache }
        let result = Self.displayOrder(items)
        orderedCache = result
        return result
    }

    /// One canonical order for the normal list and every search path: newest copy first.
    /// Original offsets make exact timestamp ties stable.
    private nonisolated static func displayOrder(_ values: [ClipboardItem]) -> [ClipboardItem] {
        values.enumerated().sorted { lhs, rhs in
            let left = lhs.element
            let right = rhs.element
            if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Rewrite a row under the same id so it leads the history: stored order is rowid, so this is a delete + re-insert, and the fresh `createdAt` keeps the date buckets descending. The image blob is never touched.
    private func reinsert(_ updated: ClipboardItem) {
        guard let deleteStmt = deleteByIDStmt, let insertStmt else { return }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return }
        var committed = false
        defer {
            if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        }
        sqlite3_bind_text(deleteStmt, 1, updated.id.uuidString, -1, SQLITE_TRANSIENT)
        guard stepAndReset(deleteStmt), bindAndInsert(insertStmt, updated) else { return }
        committed = sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK
        guard committed else { return }
        // Array ops also cover items surfaced by FTS from beyond the in-memory window.
        items.removeAll { $0.id == updated.id }
        items.insert(updated, at: 0)
        trimWindow()
        scheduleSearchMetadataUpdate(for: updated)
    }

    /// Cap the in-memory window.
    private func trimWindow() {
        guard items.count > Self.memoryWindow else { return }
        items.removeLast()
    }

    @discardableResult
    private func insert(_ item: ClipboardItem) -> Bool {
        guard let stmt = insertStmt, bindAndInsert(stmt, item) else { return false }
        items.insert(item, at: 0)
        trimWindow()
        prune()
        scheduleSearchMetadataUpdate(for: item)
        onItemInserted?()
        return true
    }

    @discardableResult
    private func bindAndInsert(_ stmt: OpaquePointer, _ item: ClipboardItem) -> Bool {
        sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, item.kind.rawValue, -1, SQLITE_TRANSIENT)
        if let text = item.text {
            sqlite3_bind_text(stmt, 3, text, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        if let path = item.imagePath {
            sqlite3_bind_text(stmt, 4, path, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        sqlite3_bind_double(stmt, 5, item.createdAt.timeIntervalSince1970)
        if let source = item.sourceBundleID {
            sqlite3_bind_text(stmt, 6, source, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        if let pinnedAt = item.pinnedAt {
            sqlite3_bind_double(stmt, 7, pinnedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        if let fingerprint = item.imageFingerprint {
            sqlite3_bind_text(stmt, 8, fingerprint, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        if let customTitle = item.customTitle {
            sqlite3_bind_text(stmt, 9, customTitle, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 9)
        }
        return stepAndReset(stmt)
    }

    private func loadItem(id: UUID) -> ClipboardItem? {
        guard let stmt = itemByIDStmt else { return nil }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        let status = sqlite3_step(stmt)
        let item = status == SQLITE_ROW ? Self.row(stmt) : nil
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        return status == SQLITE_ROW || status == SQLITE_DONE ? item : nil
    }

    private nonisolated static func queryCustomTitles(
        connection: OpaquePointer, pattern: String, displayKind: ClipboardItem.DisplayKind?
    ) -> [ClipboardItem]? {
        let sql = """
            SELECT id, kind, text, image_path, created_at, source_app, pinned_at,
                   image_fingerprint, custom_title
            FROM items
            WHERE custom_title LIKE ? ESCAPE '\\'
            ORDER BY rowid DESC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, pattern, -1, SQLITE_TRANSIENT)
        var results: [ClipboardItem] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if Task.isCancelled { return nil }
            if let item = row(statement), displayKind == nil || item.displayKind == displayKind {
                results.append(item)
                if results.count == 200 { break }
            }
            status = sqlite3_step(statement)
        }
        return status == SQLITE_DONE || results.count == 200 ? results : nil
    }

    private func image(matching fingerprint: String) -> ClipboardItem? {
        guard let stmt = imageByFingerprintStmt else { return nil }
        sqlite3_bind_text(stmt, 1, fingerprint, -1, SQLITE_TRANSIENT)
        let status = sqlite3_step(stmt)
        let item = status == SQLITE_ROW ? Self.row(stmt) : nil
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        return status == SQLITE_ROW || status == SQLITE_DONE ? item : nil
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-maxAge)
        guard let imagesStmt = staleImagesStmt, let deleteStmt = deleteStaleStmt else { return }
        sqlite3_bind_double(imagesStmt, 1, cutoff.timeIntervalSince1970)
        var stalePaths: [String] = []
        var status = sqlite3_step(imagesStmt)
        while status == SQLITE_ROW {
            if let path = Self.columnString(imagesStmt, 0) { stalePaths.append(path) }
            status = sqlite3_step(imagesStmt)
        }
        sqlite3_reset(imagesStmt)
        sqlite3_clear_bindings(imagesStmt)
        guard status == SQLITE_DONE else { return }
        sqlite3_bind_double(deleteStmt, 1, cutoff.timeIntervalSince1970)
        guard stepAndReset(deleteStmt) else { return }
        // A retention cut can strand hundreds of files; delete them off the main actor so capture-time prune doesn't hitch.
        let staleURLs = stalePaths.compactMap(managedBlobURL(for:))
        if !staleURLs.isEmpty {
            Task.detached(priority: .utility) {
                for url in staleURLs {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        if items.last.map({ $0.createdAt < cutoff }) == true {
            items.removeAll { $0.createdAt < cutoff }
        }
    }

    private func deleteBlob(_ item: ClipboardItem) {
        guard let path = item.imagePath, let url = managedBlobURL(for: path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Accept only regular PNG files directly owned by this store. Database paths are data, not
    /// authority to delete arbitrary files.
    private func managedBlobURL(for path: String) -> URL? {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        let directory = imagesDir.standardizedFileURL
        guard candidate.pathExtension.lowercased() == "png",
            candidate.deletingLastPathComponent() == directory,
            candidate.resolvingSymlinksInPath().deletingLastPathComponent()
                == directory.resolvingSymlinksInPath()
        else { return nil }
        if let values = try? candidate.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        {
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        }
        return candidate
    }

    private func openDatabase() -> Bool {
        guard
            sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
                == SQLITE_OK,
            sqlite3_exec(
                db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=1000;",
                nil, nil, nil) == SQLITE_OK,
            sqlite3_exec(db, Self.coreSchema, nil, nil, nil) == SQLITE_OK
        else { return false }
        guard sqlite3_exec(db, Self.searchSchema, nil, nil, nil) == SQLITE_OK else { return false }
        ensureCustomTitleColumn()
        insertStmt = prepare(
            """
            INSERT INTO items(
              id, kind, text, image_path, created_at, source_app, pinned_at, image_fingerprint,
              custom_title
            ) VALUES(?,?,?,?,?,?,?,?,?)
            """
        )
        loadStmt = prepare(
            """
            SELECT id, kind, text, image_path, created_at, source_app, pinned_at,
                   image_fingerprint, custom_title
            FROM items WHERE rowid >= ? ORDER BY rowid DESC
            """)
        windowFloorStmt = prepare(
            "SELECT rowid FROM items ORDER BY rowid DESC LIMIT 1 OFFSET ?")
        deleteByIDStmt = prepare("DELETE FROM items WHERE id = ?")
        staleImagesStmt = prepare(
            """
            SELECT image_path FROM items
            WHERE created_at < ? AND image_path IS NOT NULL
            """)
        deleteStaleStmt = prepare("DELETE FROM items WHERE created_at < ?")
        imageByFingerprintStmt = prepare(
            """
            SELECT id, kind, text, image_path, created_at, source_app, pinned_at,
                   image_fingerprint, custom_title
            FROM items WHERE image_fingerprint = ? LIMIT 1
            """)
        itemByIDStmt = prepare(
            """
            SELECT id, kind, text, image_path, created_at, source_app, pinned_at,
                   image_fingerprint, custom_title
            FROM items WHERE id = ? LIMIT 1
            """)
        insertStackStmt = prepare(
            "INSERT INTO stacks(id, name, position) VALUES(?,?,?)")
        upsertMembershipStmt = prepare(
            """
            INSERT INTO stack_items(item_id, stack_id) VALUES(?,?)
            ON CONFLICT(item_id) DO UPDATE SET stack_id = excluded.stack_id
            """)
        deleteMembershipStmt = prepare("DELETE FROM stack_items WHERE item_id = ?")
        return insertStmt != nil && loadStmt != nil && windowFloorStmt != nil
            && deleteByIDStmt != nil && staleImagesStmt != nil
            && deleteStaleStmt != nil && imageByFingerprintStmt != nil
            && itemByIDStmt != nil
    }

    private func ensureCustomTitleColumn() {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(items)", -1, &stmt, nil) == SQLITE_OK else {
            return
        }
        var hasColumn = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = Self.columnString(stmt, 1), name == "custom_title" {
                hasColumn = true
                break
            }
        }
        guard !hasColumn else { return }
        sqlite3_exec(db, "ALTER TABLE items ADD COLUMN custom_title TEXT", nil, nil, nil)
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        return stmt
    }

    @discardableResult
    private func stepAndReset(_ stmt: OpaquePointer) -> Bool {
        let status = sqlite3_step(stmt)
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        return status == SQLITE_DONE
    }

    private func closeDatabase() {
        [
            insertStmt, loadStmt, windowFloorStmt, deleteByIDStmt,
            staleImagesStmt, deleteStaleStmt, imageByFingerprintStmt, itemByIDStmt,
            insertStackStmt, upsertMembershipStmt, deleteMembershipStmt,
        ].forEach { sqlite3_finalize($0) }
        insertStmt = nil
        loadStmt = nil
        windowFloorStmt = nil
        deleteByIDStmt = nil
        staleImagesStmt = nil
        deleteStaleStmt = nil
        imageByFingerprintStmt = nil
        itemByIDStmt = nil
        insertStackStmt = nil
        upsertMembershipStmt = nil
        deleteMembershipStmt = nil
        sqlite3_close_v2(db)
        db = nil
    }

    private nonisolated static func row(_ stmt: OpaquePointer?) -> ClipboardItem? {
        guard let idString = columnString(stmt, 0), let id = UUID(uuidString: idString),
            let kindString = columnString(stmt, 1),
            let storedKind = ClipboardItem.Kind(rawValue: kindString)
        else { return nil }
        return ClipboardItem(
            id: id, kind: storedKind, text: columnString(stmt, 2), imagePath: columnString(stmt, 3),
            imageFingerprint: columnString(stmt, 7),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
            sourceBundleID: columnString(stmt, 5), pinnedAt: columnDate(stmt, 6),
            customTitle: columnString(stmt, 8))
    }

    private nonisolated static func columnDate(_ stmt: OpaquePointer?, _ index: Int32) -> Date? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, index))
    }

    private nonisolated static func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return String(decoding: UnsafeBufferPointer(start: ptr, count: count), as: UTF8.self)
    }
}

/// Conservative classification for clipboard text. Whole-string http(s) URLs classify as links;
/// strong syntax forms classify as code on their own; weaker punctuation signals must combine,
/// keeping prose and ordinary messages as text. Code blocks and inline code inside Markdown are
/// ignored so an AI answer explaining source stays text. Only a bounded prefix is inspected for
/// code so a large copy cannot stall capture.
enum ClipboardTextClassifier {
    private static let sampleLimit = 12_000
    /// Opening fence, optional info string, body, then a matching closing fence.
    private static let closedFenceRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?m)^[ \t]{0,3}(`{3,}|~{3,})[^\n]*\n[\s\S]*?^[ \t]{0,3}\1[ \t]*$"#
    )
    private static let openFenceRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?m)^[ \t]{0,3}(`{3,}|~{3,})"#
    )
    private static let inlineCodeRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?s)(?<!`)(`+)(?!`).*?(?<!`)\1(?!`)"#
    )

    static func kind(for text: String) -> ClipboardItem.Kind {
        if isLink(text) { return .link }
        return isCode(text) ? .code : .text
    }

    /// A Markdown document that embeds source, not a source file. Used to render rows that were
    /// captured as `.code` before fenced examples were excluded from classification.
    static func isMarkdownArticle(_ text: String) -> Bool {
        MarkdownAttributedRenderer.isMarkdown(text) && !isCode(text)
    }

    /// Whole clipboard string is a single http(s) URL (no surrounding prose).
    private static func isLink(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return false }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https", url.host != nil
        else { return false }
        return true
    }

    private static func isCode(_ text: String) -> Bool {
        let sample = String(text.prefix(sampleLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard sample.count >= 4 else { return false }

        if sample.hasPrefix("#!") { return true }
        if isJSONObject(sample) { return true }
        if isStandaloneFencedBlock(sample) { return true }

        let body = strippingMarkdownCode(sample)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count >= 4 else { return false }

        let strongSyntax = #"(?m)^\s*(?:(?:import\s+.+(?:\s+from\s+)?[\"'<])|(?:export\s+(?:default\s+)?)|(?:(?:const|let|var)\s+[A-Za-z_$][A-Za-z0-9_$]*\s*(?::[^=\n]+)?=)|(?:(?:func|function|def|class|struct|enum|protocol|extension|interface|type|fn)\s+[A-Za-z_][A-Za-z0-9_]*)|(?:(?:public|private|protected|internal|open|static|final|pub)\s+(?:class|struct|enum|func|fn|let|var|const)\b)|(?:#include\s*[<\"])|(?:(?:SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER)\b.+\b(?:FROM|INTO|TABLE|SET)\b))"#
        if matches(strongSyntax, in: body) { return true }

        let standaloneCall = #"^\s*[A-Za-z_$][A-Za-z0-9_$]*(?:\.[A-Za-z_$][A-Za-z0-9_$]*)*\s*\([^\n]*\)\s*;?\s*$"#
        if matches(standaloneCall, in: body) { return true }

        let markup = #"(?s)<[A-Za-z][^>]*>.*</[A-Za-z][^>]*>"#
        if matches(markup, in: body) { return true }

        var score = 0
        if body.contains("{") && body.contains("}") { score += 1 }
        if body.contains("=>") || body.contains("::") || body.contains("?.") { score += 1 }
        if matches(#"(?m);\s*$"#, in: body) { score += 1 }
        if matches(#"\b(?:return|await|throw|guard|switch|case|while|foreach|impl|lambda)\b"#, in: body) {
            score += 1
        }
        if matches(#"(?m)^\s{2,}\S+"#, in: body) && body.contains("\n") { score += 1 }
        if matches(#"\b[A-Za-z_$][A-Za-z0-9_$]*\s*\([^\n)]*\)"#, in: body) {
            score += 1
        }
        return score >= 3
    }

    /// A copy that is only a fenced block (including the fences) is source, not an article.
    private static func isStandaloneFencedBlock(_ sample: String) -> Bool {
        guard sample.hasPrefix("```") || sample.hasPrefix("~~~") else { return false }
        return strippingFencedCodeBlocks(sample)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    /// Inline snippets such as `return () => {}` are prose examples and must not contribute code
    /// punctuation or keywords to the whole-document score.
    private static func strippingMarkdownCode(_ text: String) -> String {
        let withoutFences = strippingFencedCodeBlocks(text)
        guard let inlineCodeRegex else { return withoutFences }
        return inlineCodeRegex.stringByReplacingMatches(
            in: withoutFences,
            range: NSRange(withoutFences.startIndex..., in: withoutFences),
            withTemplate: " "
        )
    }

    /// Drop closed fences, then a trailing unclosed opener (the 12k prefix may cut mid-block).
    private static func strippingFencedCodeBlocks(_ text: String) -> String {
        let full = NSRange(text.startIndex..., in: text)
        var result = text
        if let closedFenceRegex {
            result = closedFenceRegex.stringByReplacingMatches(
                in: result, range: full, withTemplate: "\n")
        }
        if let openFenceRegex {
            let remaining = NSRange(result.startIndex..., in: result)
            if let match = openFenceRegex.firstMatch(in: result, range: remaining),
                let start = Range(match.range, in: result)
            {
                result = String(result[..<start.lowerBound])
            }
        }
        return result
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isJSONObject(_ text: String) -> Bool {
        guard let first = text.first, first == "{" || first == "[", let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
        else { return false }
        return object is [String: Any] || object is [Any]
    }
}
