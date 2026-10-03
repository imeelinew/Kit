import Foundation
import Combine
import SQLite3

/// SQLite-backed clipboard history (rows + trigram FTS5 index in `clipboard.sqlite3`, image blobs on disk).
@MainActor
final class ClipboardStore: ObservableObject {
    /// The most recent in-memory history window; older rows are queried from SQLite.
    @Published private(set) var items: [ClipboardItem] = [] {
        didSet { revision &+= 1 }
    }
    @Published private(set) var revision: UInt64 = 0
    /// Named stacks shown in the palette.
    @Published private(set) var stacks: [ClipboardStack] = []
    /// Item id to the single stack that owns it.
    private var stackMembership: [ClipboardItem.ID: ClipboardStack.ID] = [:]
    /// Fired after a successful external capture, including recopies of existing content.
    var onItemCaptured: (() -> Void)?
    private(set) var captureGeneration: UInt64 = 0
    var maxAge: TimeInterval = ClipboardRetention.threeMonths.maxAge

    private static let memoryWindow = 1000
    private var lastPrunedAt = Date.distantPast

    private static let coreSchema = """
        CREATE TABLE IF NOT EXISTS items(
          id TEXT NOT NULL UNIQUE,
          kind TEXT NOT NULL,
          text TEXT,
          image_path TEXT,
          created_at REAL NOT NULL,
          source_app TEXT,
          image_fingerprint TEXT,
          custom_title TEXT,
          last_used_at REAL,
          pinyin TEXT,
          pinyin_initials TEXT,
          ocr_text TEXT,
          ocr_status TEXT,
          ocr_version INTEGER,
          ocr_attempts INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS items_created_at ON items(created_at);
        CREATE INDEX IF NOT EXISTS items_kind ON items(kind);
        CREATE INDEX IF NOT EXISTS items_text_content
          ON items(text, created_at DESC) WHERE kind != 'image';
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
        CREATE INDEX IF NOT EXISTS stack_items_stack_id
          ON stack_items(stack_id, item_id);
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

    /// Separate OCR index preserves the existing text index during the one-time schema upgrade.
    private static let imageSearchSchema = """
        CREATE VIRTUAL TABLE IF NOT EXISTS image_ocr_fts USING fts5(
          ocr_text, tokenize='trigram'
        );
        CREATE TRIGGER IF NOT EXISTS image_ocr_ai AFTER INSERT ON items
        WHEN new.ocr_text IS NOT NULL BEGIN
          INSERT INTO image_ocr_fts(rowid, ocr_text) VALUES(new.rowid, new.ocr_text);
        END;
        CREATE TRIGGER IF NOT EXISTS image_ocr_ad AFTER DELETE ON items
        WHEN old.ocr_text IS NOT NULL BEGIN
          DELETE FROM image_ocr_fts WHERE rowid = old.rowid;
        END;
        CREATE TRIGGER IF NOT EXISTS image_ocr_au AFTER UPDATE OF ocr_text ON items BEGIN
          DELETE FROM image_ocr_fts WHERE rowid = old.rowid;
          INSERT INTO image_ocr_fts(rowid, ocr_text)
          SELECT new.rowid, new.ocr_text WHERE new.ocr_text IS NOT NULL;
        END;
        CREATE INDEX IF NOT EXISTS items_pending_ocr ON items(created_at)
          WHERE kind = 'image' AND
            (ocr_status IS NULL OR (ocr_status = 'failed' AND ocr_attempts < \(ClipboardImageTextRecognition.maxAttempts)));
        """

    private let imagesDir: URL
    private let deletedImagesDir: URL
    private let dbURL: URL
    private struct DeletedEntry {
        let item: ClipboardItem
        let stackID: ClipboardStack.ID?
        let imageBackup: URL?
    }
    // A successful deletion replaces this slot; a successful restore consumes it.
    private var deletedEntry: DeletedEntry?

    var canUndoDeletion: Bool {
        guard let deletedEntry else { return false }
        return deletedEntry.item.createdAt >= Date().addingTimeInterval(-maxAge)
    }
    private var db: OpaquePointer?
    private var insertStmt: OpaquePointer?
    private var loadStmt: OpaquePointer?
    private var refreshStmt: OpaquePointer?
    private var deleteByIDStmt: OpaquePointer?
    private var staleImagesStmt: OpaquePointer?
    private var deleteStaleStmt: OpaquePointer?
    private var imageByFingerprintStmt: OpaquePointer?
    private var textByContentStmt: OpaquePointer?
    private var itemByIDStmt: OpaquePointer?
    private var updateKindStmt: OpaquePointer?
    private var markUsedStmt: OpaquePointer?
    private var insertStackStmt: OpaquePointer?
    private var upsertMembershipStmt: OpaquePointer?
    private var deleteMembershipStmt: OpaquePointer?
    private var pendingSearchMetadata: [SearchMetadataUpdate] = []
    private var searchMetadataTask: Task<Void, Never>?
    private var imageOCRTask: Task<Void, Never>?
    private let recognizeImage: @Sendable (URL) async -> ClipboardImageOCRResult

    init(
        directory: URL? = nil,
        recognizeImage: @escaping @Sendable (URL) async -> ClipboardImageOCRResult =
            ClipboardImageTextRecognition.recognize
    ) {
        let base = directory ?? Self.defaultDirectory
        imagesDir = base.appendingPathComponent("images", isDirectory: true)
        deletedImagesDir = base.appendingPathComponent("deleted-images", isDirectory: true)
        dbURL = base.appendingPathComponent("clipboard.sqlite3")
        self.recognizeImage = recognizeImage
        // Undo is session-local. Also remove backups left by an interrupted previous run.
        try? FileManager.default.removeItem(at: deletedImagesDir)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        _ = openDatabase()
    }

    private static var defaultDirectory: URL {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            preconditionFailure("Kit requires a bundle identifier")
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
    }

    // Isolated so teardown may touch the main-actor statement/db pointers; AppCore only ever releases the store on the main actor, so no hop.
    isolated deinit {
        imageOCRTask?.cancel()
        closeDatabase()
        try? FileManager.default.removeItem(at: deletedImagesDir)
    }

    func load() {
        loadStackState()
        guard let stmt = loadStmt else { return }
        sqlite3_bind_int(stmt, 1, Int32(Self.memoryWindow))
        var loaded: [ClipboardItem] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            if let item = ClipboardSQLite.row(stmt) { loaded.append(item) }
            status = sqlite3_step(stmt)
        }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        guard status == SQLITE_DONE else { return }
        items = loaded
        // Age passes while the app isn't running; insert-time pruning alone can't catch that.
        enforceLimits()
        startImageOCRWorkerIfNeeded()
    }

    /// Called on load and when the retention setting changes.
    func enforceLimits() {
        prune()
    }

    @discardableResult
    func addText(
        _ text: String, kind: ClipboardItem.Kind, sourceBundleID: String?,
        expectedGeneration: UInt64? = nil
    ) -> ClipboardItem? {
        if let expectedGeneration, expectedGeneration != captureGeneration { return nil }
        if let existing = textItem(matching: text) {
            let updated = existing.refreshed(sourceBundleID: sourceBundleID).withKind(kind)
            return refresh(updated) ? updated : nil
        }
        let item = ClipboardItem(text: text, kind: kind, sourceBundleID: sourceBundleID)
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
            refresh(existing.refreshed(sourceBundleID: sourceBundleID))
            startImageOCRWorkerIfNeeded()
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

    func item(id: ClipboardItem.ID) -> ClipboardItem? {
        if let item = items.first(where: { $0.id == id }) { return item }
        return loadItem(id: id)
    }

    /// Update usage metadata in place without treating reuse as an external capture.
    @discardableResult
    func markUsed(id: ClipboardItem.ID, at date: Date = Date()) -> Bool {
        guard let stmt = markUsedStmt else { return false }
        sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, id.uuidString, -1, SQLITE_TRANSIENT)
        guard stepAndReset(stmt), sqlite3_changes(db) == 1 else { return false }
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index] = items[index].used(at: date)
        } else {
            revision &+= 1
        }
        return true
    }

    /// Re-grade an existing row's kind (async TypeSafe classification). The row id is stable across
    /// recopies of the same content, so a late answer lands on the right item or on nothing if
    /// the item was deleted in the meantime.
    @discardableResult
    func updateKind(id: ClipboardItem.ID, to kind: ClipboardItem.Kind) -> Bool {
        guard let stmt = updateKindStmt else { return false }
        sqlite3_bind_text(stmt, 1, kind.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, id.uuidString, -1, SQLITE_TRANSIENT)
        guard stepAndReset(stmt), sqlite3_changes(db) == 1 else { return false }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return true }
        guard items[index].kind != kind else { return true }
        items[index] = items[index].withKind(kind)
        return true
    }

    @discardableResult
    func remove(_ item: ClipboardItem) -> Bool {
        guard let item = self.item(id: item.id), let stmt = deleteByIDStmt else { return false }
        var backup: URL?
        if item.imagePath != nil {
            guard let imageURL = imageURL(for: item) else { return false }
            let destination = deletedImagesDir.appendingPathComponent(UUID().uuidString + ".png")
            do {
                try FileManager.default.createDirectory(at: deletedImagesDir, withIntermediateDirectories: true)
                // Keep the live image intact until the database transaction commits.
                try FileManager.default.copyItem(at: imageURL, to: destination)
                backup = destination
            } catch {
                return false
            }
        }
        let entry = DeletedEntry(item: item, stackID: stackMembership[item.id], imageBackup: backup)
        let deleted = transaction {
            sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, SQLITE_TRANSIENT)
            return stepAndReset(stmt) && sqlite3_changes(db) == 1 && deleteMembership(item.id)
        }
        guard deleted else {
            if let backup { try? FileManager.default.removeItem(at: backup) }
            return false
        }
        discardDeletion()
        deletedEntry = entry
        stackMembership.removeValue(forKey: item.id)
        deleteBlob(item)
        items.removeAll { $0.id == item.id }
        return true
    }

    /// Restore original metadata without treating undo as a new clipboard capture.
    /// A newer copy of the same content wins; undo never creates a duplicate or overwrites it.
    @discardableResult
    func undoLastDeletion() -> ClipboardItem? {
        guard canUndoDeletion else {
            discardDeletion()
            return nil
        }
        guard let entry = deletedEntry, let stmt = insertStmt else { return nil }
        let existing = item(id: entry.item.id)
            ?? entry.item.text.flatMap { textItem(matching: $0) }
            ?? entry.item.imageFingerprint.flatMap { image(matching: $0) }
        let restored = existing ?? entry.item
        let stackID = stackMembership[restored.id]
            ?? entry.stackID.flatMap { id in stacks.contains { $0.id == id } ? id : nil }

        var copiedImage: URL?
        if existing == nil, let backup = entry.imageBackup {
            guard let destination = imageURL(for: restored) else { return nil }
            if !FileManager.default.fileExists(atPath: destination.path) {
                do {
                    try FileManager.default.copyItem(at: backup, to: destination)
                    copiedImage = destination
                } catch {
                    return nil
                }
            }
        }
        guard transaction({
            if existing == nil, !bindAndInsert(stmt, restored) { return false }
            if let stackID, !writeMembership(restored.id, stackID: stackID) { return false }
            return true
        }) else {
            if let copiedImage { try? FileManager.default.removeItem(at: copiedImage) }
            return nil
        }
        discardDeletion()
        if let stackID { stackMembership[restored.id] = stackID }
        items = Array(Self.displayOrder(
            [restored] + items.filter { $0.id != restored.id }).prefix(Self.memoryWindow))
        if existing == nil {
            scheduleSearchMetadataUpdate(for: restored)
            startImageOCRWorkerIfNeeded()
        }
        return restored
    }

    private func transaction(_ body: () -> Bool) -> Bool {
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return false }
        if body(), sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK { return true }
        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        return false
    }

    private func discardDeletion() {
        guard let entry = deletedEntry else { return }
        if let backup = entry.imageBackup { try? FileManager.default.removeItem(at: backup) }
        deletedEntry = nil
    }

    func clearAll() {
        captureGeneration &+= 1
        searchMetadataTask?.cancel()
        imageOCRTask?.cancel()
        pendingSearchMetadata.removeAll()
        guard sqlite3_exec(db, "DELETE FROM items", nil, nil, nil) == SQLITE_OK else { return }
        discardDeletion()
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
        revision &+= 1
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
        revision &+= 1
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

        if deletedEntry?.stackID == id { discardDeletion() }
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
            if let idString = ClipboardSQLite.columnString(stmt, 0), let itemID = UUID(uuidString: idString) {
                itemIDs.insert(itemID)
            }
            if let path = ClipboardSQLite.columnString(stmt, 1), let url = managedBlobURL(for: path) {
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
                if let idString = ClipboardSQLite.columnString(stmt, 0),
                    let id = UUID(uuidString: idString),
                    let name = ClipboardSQLite.columnString(stmt, 1)
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
                guard let itemString = ClipboardSQLite.columnString(stmt, 0),
                    let itemID = UUID(uuidString: itemString),
                    let stackString = ClipboardSQLite.columnString(stmt, 1),
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

    private func deleteMembership(_ itemID: ClipboardItem.ID) -> Bool {
        guard let stmt = deleteMembershipStmt else { return false }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_text(stmt, 1, itemID.uuidString, -1, SQLITE_TRANSIENT)
        return stepAndReset(stmt)
    }

    /// Query the complete history in pages. All filters run in SQLite before the page limit.
    /// The resident overlay keeps newly captured Han text searchable while its pinyin index is written.
    func searchAsync(
        _ query: String, kind: ClipboardItem.Kind? = nil,
        stackID: ClipboardStack.ID? = nil,
        after cursor: ClipboardSearchCursor?, limit: Int
    ) async -> ClipboardSearchPage {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = dbURL.path
        let databaseTask = Task.detached(priority: .userInitiated) {
            ClipboardSearch.queryDatabase(
                path: path, query: trimmed, kind: kind, stackID: stackID,
                after: cursor, limit: limit)
        }
        let resident = cursor == nil && !trimmed.isEmpty ? items : []
        let membership = stackMembership
        let residentTask = Task.detached(priority: .userInitiated) {
            resident.filter {
                $0.matches(trimmed)
                    && (kind == nil || $0.kind == kind)
                    && (stackID == nil || membership[$0.id] == stackID)
            }
        }
        let (databasePage, residentResult) = await withTaskCancellationHandler {
            await (databaseTask.value, residentTask.value)
        } onCancel: {
            databaseTask.cancel()
            residentTask.cancel()
        }
        guard !Task.isCancelled, let databasePage else {
            return ClipboardSearchPage(items: [], nextCursor: nil)
        }
        guard !residentResult.isEmpty else { return databasePage }

        var seen = Set<ClipboardItem.ID>()
        let merged = (databasePage.items + residentResult).filter { seen.insert($0.id).inserted }
        return ClipboardSearchPage(
            items: Self.displayOrder(merged), nextCursor: databasePage.nextCursor)
    }

    func waitForSearchMetadata() async {
        await searchMetadataTask?.value
    }

    func waitForImageOCR() async {
        await imageOCRTask?.value
    }

    /// Query the entire history through a partial index, independent of the resident 1,000 rows.
    private func nextImageOCRItem() -> ClipboardItem? {
        guard let stmt = prepare("""
            SELECT id, kind, text, image_path, created_at, source_app,
                   image_fingerprint, custom_title, last_used_at,
                   ocr_text, ocr_status, ocr_version, ocr_attempts
            FROM items WHERE kind = 'image' AND
              (ocr_status IS NULL OR (ocr_status = 'failed' AND ocr_attempts < \(ClipboardImageTextRecognition.maxAttempts)))
            ORDER BY created_at DESC, rowid DESC LIMIT 1
            """)
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? ClipboardSQLite.row(stmt) : nil
    }

    private func startImageOCRWorkerIfNeeded() {
        guard imageOCRTask == nil, nextImageOCRItem() != nil else { return }
        let recognize = recognizeImage
        imageOCRTask = Task(priority: .utility) { [weak self] in
            defer {
                self?.imageOCRTask = nil
                if Task.isCancelled { self?.startImageOCRWorkerIfNeeded() }
            }
            while !Task.isCancelled, let item = self?.nextImageOCRItem() {
                guard let generation = self?.captureGeneration else { return }
                let result: ClipboardImageOCRResult
                if let url = self?.imageURL(for: item) {
                    result = await recognize(url)
                } else {
                    result = .failed
                }
                guard !Task.isCancelled else { return }
                let metadata = await Task.detached(priority: .utility) {
                    let text: String?
                    let status: ClipboardImageOCR.Status
                    switch result {
                    case .recognized(let recognized):
                        let normalized = ClipboardImageTextRecognition.normalizedText(recognized)
                        text = normalized.isEmpty ? nil : normalized
                        status = normalized.isEmpty ? .empty : .complete
                    case .failed:
                        text = nil
                        status = .failed
                    }
                    return (
                        ClipboardImageOCR(
                            text: text, status: status,
                            version: ClipboardImageTextRecognition.version,
                            attempts: (item.imageOCR?.attempts ?? 0) + 1),
                        Pinyin.searchForms(for: text ?? ""))
                }.value
                guard !Task.isCancelled else { return }
                if self?.saveImageOCR(metadata.0, forms: metadata.1, for: item,
                                      generation: generation) != true,
                    self?.item(id: item.id) != nil
                {
                    // Retry a transient database lock once, without running recognition again.
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    guard self?.saveImageOCR(metadata.0, forms: metadata.1, for: item,
                                            generation: generation) == true else { return }
                }
                // Yield between images so a large backfill cannot monopolize the app.
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    private func saveImageOCR(
        _ metadata: ClipboardImageOCR, forms: Pinyin.SearchForms,
        for item: ClipboardItem, generation: UInt64
    ) -> Bool {
        guard generation == captureGeneration, let stmt = prepare("""
            UPDATE items SET ocr_text = ?, ocr_status = ?, ocr_version = ?, ocr_attempts = ?,
                             pinyin = ?, pinyin_initials = ?
            WHERE id = ? AND kind = 'image' AND image_path IS ? AND image_fingerprint IS ?
            """)
        else { return false }
        defer { sqlite3_finalize(stmt) }
        if let text = metadata.text {
            sqlite3_bind_text(stmt, 1, text, Int32(text.utf8.count), SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        sqlite3_bind_text(stmt, 2, metadata.status.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(metadata.version))
        sqlite3_bind_int(stmt, 4, Int32(metadata.attempts))
        sqlite3_bind_text(stmt, 5, forms.full, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 6, forms.initials, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 7, item.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 8, item.imagePath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 9, item.imageFingerprint, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE, sqlite3_changes(db) == 1 else { return false }
        if let index = items.firstIndex(where: { $0.id == item.id }),
            let updated = loadItem(id: item.id)
        {
            items[index] = updated
        } else {
            revision &+= 1
        }
        return true
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
                ClipboardSearch.updateMetadata(path: path, batch: batch)
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

    // MARK: - Private

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

    /// Only a new external copy refreshes history; reusing an item never calls this path.
    @discardableResult
    private func refresh(_ updated: ClipboardItem) -> Bool {
        guard let stmt = refreshStmt else { return false }
        sqlite3_bind_double(stmt, 1, updated.createdAt.timeIntervalSince1970)
        if let source = updated.sourceBundleID {
            sqlite3_bind_text(stmt, 2, source, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        sqlite3_bind_text(stmt, 3, updated.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, updated.kind.rawValue, -1, SQLITE_TRANSIENT)
        guard stepAndReset(stmt) else { return false }
        // Publish one complete revision, without briefly removing the selected item.
        items = Array(([updated] + items.filter { $0.id != updated.id }).prefix(Self.memoryWindow))
        onItemCaptured?()
        return true
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
        pruneIfDue()
        scheduleSearchMetadataUpdate(for: item)
        if item.kind == .image { startImageOCRWorkerIfNeeded() }
        onItemCaptured?()
        return true
    }

    @discardableResult
    private func bindAndInsert(_ stmt: OpaquePointer, _ item: ClipboardItem) -> Bool {
        sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, item.kind.rawValue, -1, SQLITE_TRANSIENT)
        if let text = item.text {
            sqlite3_bind_text(stmt, 3, text, Int32(text.utf8.count), SQLITE_TRANSIENT)
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
        if let fingerprint = item.imageFingerprint {
            sqlite3_bind_text(stmt, 7, fingerprint, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        if let customTitle = item.customTitle {
            sqlite3_bind_text(stmt, 8, customTitle, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        if let lastUsedAt = item.lastUsedAt {
            sqlite3_bind_double(stmt, 9, lastUsedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 9)
        }
        if let metadata = item.imageOCR {
            if let text = metadata.text {
                sqlite3_bind_text(stmt, 10, text, Int32(text.utf8.count), SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 10)
            }
            sqlite3_bind_text(stmt, 11, metadata.status.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 12, Int32(metadata.version))
            sqlite3_bind_int(stmt, 13, Int32(metadata.attempts))
        } else {
            for column: Int32 in 10...12 { sqlite3_bind_null(stmt, column) }
            sqlite3_bind_int(stmt, 13, 0)
        }
        let forms = Pinyin.searchForms(for: item.imageOCR?.text ?? "")
        sqlite3_bind_text(stmt, 14, forms.full, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 15, forms.initials, -1, SQLITE_TRANSIENT)
        return stepAndReset(stmt)
    }

    private func loadItem(id: UUID) -> ClipboardItem? {
        guard let stmt = itemByIDStmt else { return nil }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        let status = sqlite3_step(stmt)
        let item = status == SQLITE_ROW ? ClipboardSQLite.row(stmt) : nil
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        return status == SQLITE_ROW || status == SQLITE_DONE ? item : nil
    }

    private func image(matching fingerprint: String) -> ClipboardItem? {
        guard let stmt = imageByFingerprintStmt else { return nil }
        sqlite3_bind_text(stmt, 1, fingerprint, -1, SQLITE_TRANSIENT)
        let status = sqlite3_step(stmt)
        let item = status == SQLITE_ROW ? ClipboardSQLite.row(stmt) : nil
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        return status == SQLITE_ROW || status == SQLITE_DONE ? item : nil
    }

    private func textItem(matching text: String) -> ClipboardItem? {
        guard let stmt = textByContentStmt else { return nil }
        sqlite3_bind_text(stmt, 1, text, Int32(text.utf8.count), SQLITE_TRANSIENT)
        let status = sqlite3_step(stmt)
        let item = status == SQLITE_ROW ? ClipboardSQLite.row(stmt) : nil
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        return item
    }

    private func pruneIfDue() {
        guard Date().timeIntervalSince(lastPrunedAt) >= 3_600 else { return }
        prune()
    }

    private func prune() {
        lastPrunedAt = Date()
        let cutoff = Date().addingTimeInterval(-maxAge)
        if let deletedEntry, deletedEntry.item.createdAt < cutoff { discardDeletion() }
        guard let imagesStmt = staleImagesStmt, let deleteStmt = deleteStaleStmt else { return }
        sqlite3_bind_double(imagesStmt, 1, cutoff.timeIntervalSince1970)
        var stalePaths: [String] = []
        var status = sqlite3_step(imagesStmt)
        while status == SQLITE_ROW {
            if let path = ClipboardSQLite.columnString(imagesStmt, 0) { stalePaths.append(path) }
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
        guard migrateUsageMetadata(),
            sqlite3_exec(db, Self.searchSchema, nil, nil, nil) == SQLITE_OK,
            migrateImageSearch()
        else { return false }
        insertStmt = prepare(
            """
            INSERT INTO items(
              id, kind, text, image_path, created_at, source_app, image_fingerprint,
              custom_title, last_used_at, ocr_text, ocr_status, ocr_version, ocr_attempts,
              pinyin, pinyin_initials
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """
        )
        loadStmt = prepare(
            """
            SELECT id, kind, text, image_path, created_at, source_app,
                   image_fingerprint, custom_title, last_used_at,
                   ocr_text, ocr_status, ocr_version, ocr_attempts
            FROM items ORDER BY created_at DESC, rowid DESC LIMIT ?
            """)
        refreshStmt = prepare(
            "UPDATE items SET created_at = ?1, source_app = ?2, kind = ?4 WHERE id = ?3")
        deleteByIDStmt = prepare("DELETE FROM items WHERE id = ?")
        staleImagesStmt = prepare(
            """
            SELECT image_path FROM items
            WHERE created_at < ? AND image_path IS NOT NULL
            """)
        deleteStaleStmt = prepare("DELETE FROM items WHERE created_at < ?")
        imageByFingerprintStmt = prepare(
            """
            SELECT id, kind, text, image_path, created_at, source_app,
                   image_fingerprint, custom_title, last_used_at,
                   ocr_text, ocr_status, ocr_version, ocr_attempts
            FROM items WHERE image_fingerprint = ? LIMIT 1
            """)
        textByContentStmt = prepare(
            """
            SELECT id, kind, text, image_path, created_at, source_app,
                   image_fingerprint, custom_title, last_used_at,
                   ocr_text, ocr_status, ocr_version, ocr_attempts
            FROM items WHERE kind != 'image' AND text = ? COLLATE BINARY
            ORDER BY created_at DESC, rowid DESC LIMIT 1
            """)
        itemByIDStmt = prepare(
            """
            SELECT id, kind, text, image_path, created_at, source_app,
                   image_fingerprint, custom_title, last_used_at,
                   ocr_text, ocr_status, ocr_version, ocr_attempts
            FROM items WHERE id = ? LIMIT 1
            """)
        updateKindStmt = prepare("UPDATE items SET kind = ? WHERE id = ?")
        markUsedStmt = prepare("UPDATE items SET last_used_at = ? WHERE id = ?")
        insertStackStmt = prepare(
            "INSERT INTO stacks(id, name, position) VALUES(?,?,?)")
        upsertMembershipStmt = prepare(
            """
            INSERT INTO stack_items(item_id, stack_id) VALUES(?,?)
            ON CONFLICT(item_id) DO UPDATE SET stack_id = excluded.stack_id
            """)
        deleteMembershipStmt = prepare("DELETE FROM stack_items WHERE item_id = ?")
        return insertStmt != nil && loadStmt != nil && refreshStmt != nil
            && deleteByIDStmt != nil && staleImagesStmt != nil
            && deleteStaleStmt != nil && imageByFingerprintStmt != nil
            && itemByIDStmt != nil && textByContentStmt != nil
            && updateKindStmt != nil && markUsedStmt != nil
    }

    /// Existing captures keep their metadata; past usage cannot be reconstructed.
    private func migrateUsageMetadata() -> Bool {
        guard let stmt = prepare("PRAGMA table_info(items)") else { return false }
        defer { sqlite3_finalize(stmt) }
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            if ClipboardSQLite.columnString(stmt, 1) == "last_used_at" { return true }
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else { return false }
        return sqlite3_exec(db, "ALTER TABLE items ADD COLUMN last_used_at REAL", nil, nil, nil)
            == SQLITE_OK
    }

    private func migrateImageSearch() -> Bool {
        guard let stmt = prepare("PRAGMA table_info(items)") else { return false }
        var columns = Set<String>()
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            if let name = ClipboardSQLite.columnString(stmt, 1) { columns.insert(name) }
            status = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        guard status == SQLITE_DONE else { return false }
        return transaction {
            for (name, type) in [
                ("ocr_text", "TEXT"), ("ocr_status", "TEXT"), ("ocr_version", "INTEGER"),
                ("ocr_attempts", "INTEGER NOT NULL DEFAULT 0"),
            ] where !columns.contains(name) {
                guard sqlite3_exec(db, "ALTER TABLE items ADD COLUMN \(name) \(type)",
                                   nil, nil, nil) == SQLITE_OK else { return false }
            }
            guard sqlite3_exec(db, Self.imageSearchSchema, nil, nil, nil) == SQLITE_OK else {
                return false
            }
            // Keep prior searchable text until the newer recognizer replaces it in the background.
            return sqlite3_exec(db, """
                UPDATE items SET ocr_status = NULL, ocr_version = NULL, ocr_attempts = 0
                WHERE kind = 'image' AND ocr_version IS NOT NULL
                  AND ocr_version != \(ClipboardImageTextRecognition.version)
                """, nil, nil, nil) == SQLITE_OK
        }
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
            insertStmt, loadStmt, refreshStmt, deleteByIDStmt,
            staleImagesStmt, deleteStaleStmt, imageByFingerprintStmt, textByContentStmt, itemByIDStmt,
            updateKindStmt, markUsedStmt, insertStackStmt, upsertMembershipStmt, deleteMembershipStmt,
        ].forEach { sqlite3_finalize($0) }
        insertStmt = nil
        loadStmt = nil
        refreshStmt = nil
        deleteByIDStmt = nil
        staleImagesStmt = nil
        deleteStaleStmt = nil
        imageByFingerprintStmt = nil
        textByContentStmt = nil
        itemByIDStmt = nil
        updateKindStmt = nil
        markUsedStmt = nil
        insertStackStmt = nil
        upsertMembershipStmt = nil
        deleteMembershipStmt = nil
        sqlite3_close_v2(db)
        db = nil
    }
}
