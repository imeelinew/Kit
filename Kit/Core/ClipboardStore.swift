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
    var updateHistoryAfterAction = true
    private(set) var hasDeferredHistoryUpdates = false
    var maxAge: TimeInterval = ClipboardRetention.threeMonths.maxAge

    enum ImageTextIndexState: Equatable {
        case none, indexed, indexing
    }

    private(set) var imageTextSearchEnabled = true
    @Published private(set) var imageTextIndexState: ImageTextIndexState = .none

    private static let memoryWindow = 1000
    private var lastPrunedAt = Date.distantPast
    private let maintenanceInterval: TimeInterval
    private var maintenanceTask: Task<Void, Never>?
    private var blobDeletionTask: Task<Void, Never>?
    private let removeImageFile: @Sendable (URL) -> Bool

    struct RetentionImpact: Equatable {
        let itemCount: Int
        let imageCount: Int
        let stackItemCount: Int

        func covers(_ other: Self) -> Bool {
            itemCount >= other.itemCount && imageCount >= other.imageCount
                && stackItemCount >= other.stackItemCount
        }
    }

    enum RetentionChangeResult: Equatable {
        case applied
        case confirmationRequired(RetentionImpact)
        case failed
    }

    private static let itemSelection = """
        SELECT id, kind, text, image_path, created_at, source_app,
               image_fingerprint, custom_title, first_copied_at,
               ocr_text, ocr_status, ocr_version, ocr_attempts, copy_count
        FROM items
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
        guard maxAge.isFinite, maxAge >= 0, maxAge != ClipboardRetention.forever.maxAge else {
            return true
        }
        return deletedEntry.item.lastCopiedAt >= Date().addingTimeInterval(-maxAge)
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
    private var insertStackStmt: OpaquePointer?
    private var upsertMembershipStmt: OpaquePointer?
    private var deleteMembershipStmt: OpaquePointer?
    private var pendingSearchMetadata: [SearchMetadataUpdate] = []
    private var searchMetadataTask: Task<Void, Never>?
    private var imageOCRTask: Task<Void, Never>?
    private var thumbnailWarmTask: Task<Void, Never>?
    /// A snapshot of historical IDs; new captures never join a manual rebuild while search is off.
    private var imageOCRRebuildIDs: [ClipboardItem.ID]?
    private var imageTextSearchGeneration: UInt64 = 0
    private let recognizeImage: @Sendable (URL) async -> ClipboardImageOCRResult

    init(
        directory: URL? = nil,
        maintenanceInterval: TimeInterval = 3_600,
        removeImageFile: @escaping @Sendable (URL) -> Bool = ClipboardStore.removeImageFile,
        recognizeImage: @escaping @Sendable (URL) async -> ClipboardImageOCRResult =
            ClipboardImageTextRecognition.recognize
    ) {
        let base = directory ?? Self.defaultDirectory
        imagesDir = base.appendingPathComponent("images", isDirectory: true)
        deletedImagesDir = base.appendingPathComponent("deleted-images", isDirectory: true)
        dbURL = base.appendingPathComponent("clipboard.sqlite3")
        precondition(maintenanceInterval.isFinite && maintenanceInterval > 0)
        self.maintenanceInterval = maintenanceInterval
        self.removeImageFile = removeImageFile
        self.recognizeImage = recognizeImage
        // Undo is session-local. Also remove backups left by an interrupted previous run.
        try? FileManager.default.removeItem(at: deletedImagesDir)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        openDatabase()
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
        maintenanceTask?.cancel()
        blobDeletionTask?.cancel()
        imageOCRTask?.cancel()
        thumbnailWarmTask?.cancel()
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
        startMaintenanceIfNeeded()
        startImageOCRWorkerIfNeeded()
    }

    /// Called on load, periodically, and when the retention setting changes.
    @discardableResult
    func enforceLimits(at date: Date = Date()) -> Bool {
        let succeeded = prune(at: date)
        startBlobDeletionWorkerIfNeeded()
        return succeeded
    }

    /// Read the entire database without changing the policy or deleting any history.
    /// A failed query is distinct from an empty history so confirmation can fail closed.
    func retentionImpact(
        for retention: ClipboardRetention, at date: Date = Date()
    ) -> RetentionImpact? {
        guard loadStmt != nil, date.timeIntervalSince1970.isFinite else { return nil }
        if retention == .forever {
            return RetentionImpact(itemCount: 0, imageCount: 0, stackItemCount: 0)
        }
        guard let stmt = prepare("""
            SELECT COUNT(*), COALESCE(SUM(kind = 'image'), 0),
                   COALESCE(SUM(EXISTS(SELECT 1 FROM stack_items s WHERE s.item_id = items.id)), 0)
            FROM items WHERE created_at < ?
            """) else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970 - retention.maxAge)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let impact = RetentionImpact(
            itemCount: Int(sqlite3_column_int64(stmt, 0)),
            imageCount: Int(sqlite3_column_int64(stmt, 1)),
            stackItemCount: Int(sqlite3_column_int64(stmt, 2)))
        return sqlite3_step(stmt) == SQLITE_DONE ? impact : nil
    }

    /// Shorter policies require explicit approval only when existing rows would be deleted.
    /// Recheck the approved counts under the deletion transaction's write lock.
    func changeRetention(
        to retention: ClipboardRetention, confirming approvedImpact: RetentionImpact? = nil,
        at date: Date = Date()
    ) -> RetentionChangeResult {
        guard loadStmt != nil else { return .failed }
        let previousAge = maxAge
        let shortening = retention.maxAge < previousAge
        var result = RetentionChangeResult.failed
        maxAge = retention.maxAge
        let succeeded = prune(at: date) {
            guard shortening else { return true }
            guard let current = self.retentionImpact(for: retention, at: date) else { return false }
            guard current.itemCount > 0 else { return true }
            guard let approvedImpact, approvedImpact.covers(current) else {
                result = .confirmationRequired(current)
                return false
            }
            return true
        }
        guard succeeded else {
            maxAge = previousAge
            return result
        }
        startBlobDeletionWorkerIfNeeded()
        return .applied
    }

    @discardableResult
    func addText(
        _ text: String, kind: ClipboardItem.Kind, sourceBundleID: String?,
        expectedGeneration: UInt64? = nil
    ) -> ClipboardItem? {
        if let expectedGeneration, expectedGeneration != captureGeneration { return nil }
        if let existing = textItem(matching: text) {
            let updated = existing.recopied(sourceBundleID: sourceBundleID).withKind(kind)
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
            refresh(existing.recopied(sourceBundleID: sourceBundleID))
            if let url = imageURL(for: existing) { warmImageRow(url) }
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
        guard !Task.isCancelled, generation == captureGeneration, insert(item) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        warmImageRow(url)
    }

    private func warmImageRow(_ url: URL) {
        thumbnailWarmTask?.cancel()
        // Only the latest capture is warmed eagerly; older history is prepared near the viewport.
        thumbnailWarmTask = Task {
            _ = await ImageThumbnail.loadAsync(url, maxPixel: ImageThumbnail.rowMaxPixel, priority: .prefetch)
        }
    }

    func item(id: ClipboardItem.ID) -> ClipboardItem? {
        if let item = items.first(where: { $0.id == id }) { return item }
        return loadItem(id: id)
    }

    /// Raycast leaves history metadata untouched when this preference is disabled
    @discardableResult
    func recordHistoryAction(
        id: ClipboardItem.ID, at date: Date = Date(), deferPublication: Bool = false
    ) -> Bool {
        guard updateHistoryAfterAction else { return true }
        // Read persisted metadata because a previous keep-open paste may not be published yet
        guard let existing = loadItem(id: id) else { return false }
        return refresh(
            existing.recopied(at: date, sourceBundleID: existing.sourceBundleID),
            externalCapture: false, deferPublication: deferPublication)
    }

    /// Keep the visible list and preview stable until the palette closes
    func publishDeferredHistoryUpdates() {
        guard hasDeferredHistoryUpdates else { return }
        hasDeferredHistoryUpdates = false
        load()
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
        refreshImageTextIndexState()
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
        refreshImageTextIndexState()
        if let url = imageURL(for: restored) { warmImageRow(url) }
        return restored
    }

    private func transaction(_ body: () -> Bool) -> Bool {
        ClipboardSQLite.transaction(in: db, body)
    }

    private func discardDeletion() {
        guard let entry = deletedEntry else { return }
        if let backup = entry.imageBackup { try? FileManager.default.removeItem(at: backup) }
        deletedEntry = nil
    }

    func clearAll() {
        captureGeneration &+= 1
        imageTextSearchGeneration &+= 1
        searchMetadataTask?.cancel()
        imageOCRTask?.cancel()
        thumbnailWarmTask?.cancel()
        thumbnailWarmTask = nil
        imageOCRRebuildIDs = nil
        pendingSearchMetadata.removeAll()
        guard sqlite3_exec(db, "DELETE FROM items", nil, nil, nil) == SQLITE_OK else { return }
        discardDeletion()
        items = []
        sqlite3_exec(db, "DELETE FROM stack_items", nil, nil, nil)
        stackMembership.removeAll()
        try? FileManager.default.removeItem(at: imagesDir)
        ImageThumbnail.removeCachedRows(in: imagesDir)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        refreshImageTextIndexState()
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

    func removeFromStack(_ itemID: ClipboardItem.ID) -> Bool {
        guard stackMembership[itemID] != nil else { return true }
        guard deleteMembership(itemID) else { return false }
        stackMembership.removeValue(forKey: itemID)
        revision &+= 1
        return true
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
        guard stacks.contains(where: { $0.id == id }) else { return false }
        var contents: (itemIDs: Set<ClipboardItem.ID>, imageURLs: [URL])?
        guard transaction({
            contents = stackContents(id)
            guard contents != nil else { return false }
            return deleteStackRows(
                "DELETE FROM items WHERE id IN (SELECT item_id FROM stack_items WHERE stack_id = ?)",
                stackID: id)
                && deleteStackRows("DELETE FROM stack_items WHERE stack_id = ?", stackID: id)
                && deleteStackRows("DELETE FROM stacks WHERE id = ?", stackID: id)
        }), let contents
        else { return false }

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
            ImageThumbnail.removeCachedImage(for: url)
        }
        refreshImageTextIndexState()
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

    func setImageTextSearchEnabled(_ enabled: Bool) {
        guard imageTextSearchEnabled != enabled else { return }
        imageTextSearchEnabled = enabled
        imageTextSearchGeneration &+= 1
        if enabled {
            startImageOCRWorkerIfNeeded()
        } else {
            imageOCRRebuildIDs = nil
            imageOCRTask?.cancel()
        }
        revision &+= 1
    }

    func imageTextIndexImageCount() -> Int {
        guard let stmt = prepare("SELECT COUNT(*) FROM items WHERE kind = 'image'") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    @discardableResult
    func clearImageTextIndex() -> Bool {
        guard sqlite3_exec(db, """
            UPDATE items SET ocr_text = NULL, pinyin = NULL, pinyin_initials = NULL,
                             ocr_status = 'complete', ocr_version = \(ClipboardImageTextRecognition.version)
            WHERE kind = 'image' AND ocr_text IS NOT NULL
            """, nil, nil, nil) == SQLITE_OK else { return false }
        imageTextSearchGeneration &+= 1
        imageOCRTask?.cancel()
        imageOCRRebuildIDs = nil

        func cleared(_ item: ClipboardItem) -> ClipboardItem {
            guard item.kind == .image, let metadata = item.imageOCR, metadata.text != nil else {
                return item
            }
            return item.withImageOCR(ClipboardImageOCR(
                text: nil, status: .complete, version: ClipboardImageTextRecognition.version,
                attempts: metadata.attempts))
        }
        // Update the resident overlay and undo snapshot before publishing a search revision.
        if let entry = deletedEntry {
            deletedEntry = DeletedEntry(
                item: cleared(entry.item), stackID: entry.stackID, imageBackup: entry.imageBackup)
        }
        items = items.map(cleared)
        refreshImageTextIndexState()
        return true
    }

    @discardableResult
    func rebuildImageTextIndex() -> Bool {
        guard imageOCRTask == nil else { return false }
        var ids: [ClipboardItem.ID] = []
        guard transaction({
            guard let stmt = prepare("SELECT id FROM items WHERE kind = 'image' ORDER BY created_at, rowid")
            else { return false }
            defer { sqlite3_finalize(stmt) }
            var status = sqlite3_step(stmt)
            while status == SQLITE_ROW {
                if let id = ClipboardSQLite.columnString(stmt, 0).flatMap(UUID.init(uuidString:)) {
                    ids.append(id)
                }
                status = sqlite3_step(stmt)
            }
            guard status == SQLITE_DONE else { return false }
            return sqlite3_exec(db, """
                UPDATE items SET ocr_status = NULL, ocr_version = NULL, ocr_attempts = 0
                WHERE kind = 'image'
                """, nil, nil, nil) == SQLITE_OK
        }) else { return false }
        imageTextSearchGeneration &+= 1
        imageOCRRebuildIDs = ids
        startImageOCRWorkerIfNeeded()
        revision &+= 1
        return true
    }

    private func refreshImageTextIndexState() {
        let state: ImageTextIndexState
        if imageOCRTask != nil {
            state = .indexing
        } else {
            guard let stmt = prepare("SELECT EXISTS(SELECT 1 FROM items WHERE kind = 'image' AND ocr_text IS NOT NULL)")
            else { return }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return }
            state = sqlite3_column_int(stmt, 0) == 0 ? .none : .indexed
        }
        if imageTextIndexState != state { imageTextIndexState = state }
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
        let includesImageText = imageTextSearchEnabled
        let imageGeneration = imageTextSearchGeneration
        let databaseTask = Task.detached(priority: .userInitiated) {
            ClipboardSearch.queryDatabase(
                path: path, query: trimmed, kind: kind, stackID: stackID,
                after: cursor, limit: limit, includesImageText: includesImageText)
        }
        let membership = stackMembership
        let resident = cursor == nil && !trimmed.isEmpty ? items.filter {
            (kind == nil || $0.kind == kind)
                && (stackID == nil || membership[$0.id] == stackID)
        } : []
        let databasePage = await withTaskCancellationHandler {
            await databaseTask.value
        } onCancel: {
            databaseTask.cancel()
        }
        guard !Task.isCancelled, imageGeneration == imageTextSearchGeneration, let databasePage else {
            return ClipboardSearchPage(items: [], nextCursor: nil)
        }
        guard !resident.isEmpty else { return databasePage }

        // Titles, compacted pinyin, and Unicode matching still need the resident overlay.
        // Database hits are already authoritative and never need to be matched twice.
        let databaseIDs = Set(databasePage.items.map(\.id))
        let residentTask = Task.detached(priority: .userInitiated) {
            var matches: [ClipboardItem] = []
            for item in resident {
                guard !Task.isCancelled else { return [ClipboardItem]() }
                if !databaseIDs.contains(item.id),
                    item.matches(trimmed, includeImageText: includesImageText)
                {
                    matches.append(item)
                }
            }
            return matches
        }
        let residentResult = await withTaskCancellationHandler {
            await residentTask.value
        } onCancel: {
            residentTask.cancel()
        }
        guard !Task.isCancelled, imageGeneration == imageTextSearchGeneration else {
            return ClipboardSearchPage(items: [], nextCursor: nil)
        }
        guard !residentResult.isEmpty else { return databasePage }

        return ClipboardSearchPage(
            items: Self.displayOrder(databasePage.items + residentResult),
            nextCursor: databasePage.nextCursor)
    }

    func waitForSearchMetadata() async {
        await searchMetadataTask?.value
    }

    func waitForImageOCR() async {
        while let task = imageOCRTask { await task.value }
    }

    /// Query the entire history through a partial index, independent of the resident 1,000 rows.
    private func nextImageOCRItem() -> ClipboardItem? {
        if imageOCRRebuildIDs != nil, !imageTextSearchEnabled {
            while let id = imageOCRRebuildIDs?.last {
                if let item = loadItem(id: id), item.kind == .image,
                    item.imageOCR == nil || (item.imageOCR?.status == .failed
                        && (item.imageOCR?.attempts ?? 0) < ClipboardImageTextRecognition.maxAttempts)
                { return item }
                imageOCRRebuildIDs?.removeLast()
            }
            return nil
        }
        guard imageTextSearchEnabled else { return nil }
        guard let stmt = prepare("""
            \(Self.itemSelection) WHERE kind = 'image' AND
              (ocr_status IS NULL OR (ocr_status = 'failed' AND ocr_attempts < \(ClipboardImageTextRecognition.maxAttempts)))
            ORDER BY created_at DESC, rowid DESC LIMIT 1
            """)
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? ClipboardSQLite.row(stmt) : nil
    }

    private func startImageOCRWorkerIfNeeded() {
        guard imageOCRTask == nil else { return }
        guard nextImageOCRItem() != nil else {
            imageOCRRebuildIDs = nil
            refreshImageTextIndexState()
            return
        }
        let recognize = recognizeImage
        let rebuilding = imageOCRRebuildIDs != nil
        imageOCRTask = Task(priority: .utility) { [weak self] in
            var completedRebuild = false
            defer {
                self?.imageOCRTask = nil
                self?.imageOCRRebuildIDs = nil
                self?.refreshImageTextIndexState()
                if Task.isCancelled || completedRebuild { self?.startImageOCRWorkerIfNeeded() }
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
                                            generation: generation) == true
                    else { return }
                }
                // Yield between images so a large backfill cannot monopolize the app.
                try? await Task.sleep(for: .milliseconds(25))
            }
            completedRebuild = rebuilding && !Task.isCancelled
        }
        refreshImageTextIndexState()
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
        ClipboardSQLite.bindText(metadata.text, to: stmt, at: 1)
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
        refreshImageTextIndexState()
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
            if left.lastCopiedAt != right.lastCopiedAt { return left.lastCopiedAt > right.lastCopiedAt }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Copy metadata and history position commit together before feedback
    @discardableResult
    private func refresh(
        _ updated: ClipboardItem, externalCapture: Bool = true, deferPublication: Bool = false
    ) -> Bool {
        guard let stmt = refreshStmt else { return false }
        sqlite3_bind_double(stmt, 1, updated.lastCopiedAt.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, updated.sourceBundleID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, updated.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, updated.kind.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 5, Int64(updated.copyCount))
        guard stepAndReset(stmt), sqlite3_changes(db) == 1 else { return false }
        if deferPublication {
            hasDeferredHistoryUpdates = true
            return true
        }
        publishDeferredHistoryUpdates()
        // Publish one complete revision, without briefly removing the selected item.
        items = Array(([updated] + items.filter { $0.id != updated.id }).prefix(Self.memoryWindow))
        pruneIfDue()
        if externalCapture { onItemCaptured?() }
        return true
    }

    @discardableResult
    private func insert(_ item: ClipboardItem) -> Bool {
        guard let stmt = insertStmt, bindAndInsert(stmt, item) else { return false }
        publishDeferredHistoryUpdates()
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        if items.count > Self.memoryWindow { items.removeLast() }
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
        ClipboardSQLite.bindText(item.text, to: stmt, at: 3)
        sqlite3_bind_text(stmt, 4, item.imagePath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 5, item.lastCopiedAt.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 6, item.sourceBundleID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 7, item.imageFingerprint, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 8, item.customTitle, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 9, item.firstCopiedAt.timeIntervalSince1970)
        if let metadata = item.imageOCR {
            ClipboardSQLite.bindText(metadata.text, to: stmt, at: 10)
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
        sqlite3_bind_int64(stmt, 16, Int64(item.copyCount))
        return stepAndReset(stmt)
    }

    private func loadItem(id: UUID) -> ClipboardItem? {
        findItem(using: itemByIDStmt, matching: id.uuidString)
    }

    private func image(matching fingerprint: String) -> ClipboardItem? {
        findItem(using: imageByFingerprintStmt, matching: fingerprint)
    }

    private func textItem(matching text: String) -> ClipboardItem? {
        findItem(using: textByContentStmt, matching: text)
    }

    private func findItem(using stmt: OpaquePointer?, matching value: String) -> ClipboardItem? {
        guard let stmt else { return nil }
        ClipboardSQLite.bindText(value, to: stmt, at: 1)
        let item = sqlite3_step(stmt) == SQLITE_ROW ? ClipboardSQLite.row(stmt) : nil
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        return item
    }

    private func pruneIfDue() {
        let now = Date()
        guard now < lastPrunedAt || now.timeIntervalSince(lastPrunedAt) >= maintenanceInterval else {
            return
        }
        enforceLimits(at: now)
    }

    private func startMaintenanceIfNeeded() {
        guard maintenanceTask == nil else { return }
        let interval = maintenanceInterval
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.enforceLimits()
            }
        }
    }

    private func prune(at date: Date, authorize: () -> Bool = { true }) -> Bool {
        // Invalid policy values must never turn a routine cleanup into a full-history deletion.
        guard loadStmt != nil, maxAge.isFinite, maxAge >= 0,
            date.timeIntervalSince1970.isFinite else { return false }
        if maxAge == ClipboardRetention.forever.maxAge {
            lastPrunedAt = date
            return true
        }
        let cutoff = date.addingTimeInterval(-maxAge)
        guard let imagesStmt = staleImagesStmt, let deleteStmt = deleteStaleStmt else { return false }
        var expiredMemberships = Set<ClipboardItem.ID>()
        var deletedCount = 0
        guard transaction({
            guard authorize() else { return false }
            // Persist deletion work in the same transaction as the rows. A crash or filesystem
            // error after commit leaves a retryable job rather than an untracked orphan file.
            sqlite3_bind_double(imagesStmt, 1, cutoff.timeIntervalSince1970)
            guard stepAndReset(imagesStmt) else { return false }
            guard let members = prepare("""
                SELECT item_id FROM stack_items
                WHERE item_id IN (SELECT id FROM items WHERE created_at < ?)
                """) else { return false }
            defer { sqlite3_finalize(members) }
            guard let deleteMembers = prepare("""
                DELETE FROM stack_items
                WHERE item_id IN (SELECT id FROM items WHERE created_at < ?)
                """) else { return false }
            defer { sqlite3_finalize(deleteMembers) }
            sqlite3_bind_double(members, 1, cutoff.timeIntervalSince1970)
            var status = sqlite3_step(members)
            while status == SQLITE_ROW {
                if let id = ClipboardSQLite.columnString(members, 0).flatMap(UUID.init(uuidString:)) {
                    expiredMemberships.insert(id)
                }
                status = sqlite3_step(members)
            }
            guard status == SQLITE_DONE else { return false }
            sqlite3_bind_double(deleteMembers, 1, cutoff.timeIntervalSince1970)
            guard sqlite3_step(deleteMembers) == SQLITE_DONE else { return false }
            sqlite3_bind_double(deleteStmt, 1, cutoff.timeIntervalSince1970)
            guard stepAndReset(deleteStmt) else { return false }
            deletedCount = Int(sqlite3_changes(db))
            return true
        }) else { return false }
        lastPrunedAt = date
        let undoExpired = deletedEntry.map { $0.item.lastCopiedAt < cutoff } == true
        if undoExpired { discardDeletion() }
        for id in expiredMemberships { stackMembership.removeValue(forKey: id) }
        let remaining = items.filter { $0.lastCopiedAt >= cutoff }
        if remaining.count != items.count {
            items = remaining
        } else if deletedCount > 0 || undoExpired || !expiredMemberships.isEmpty {
            // Even a deletion beyond the resident window invalidates paginated search results.
            revision &+= 1
        }
        refreshImageTextIndexState()
        return true
    }

    private func startBlobDeletionWorkerIfNeeded() {
        guard blobDeletionTask == nil else { return }
        blobDeletionTask = Task { [weak self] in
            await self?.drainBlobDeletions()
        }
    }

    private func drainBlobDeletions() async {
        defer { blobDeletionTask = nil }
        var cursor: Int64 = 0
        while !Task.isCancelled {
            guard let stmt = prepare("""
                SELECT rowid, path FROM pending_blob_deletions p
                WHERE rowid > ? AND NOT EXISTS(SELECT 1 FROM items WHERE image_path = p.path)
                ORDER BY rowid LIMIT 256
                """) else { return }
            sqlite3_bind_int64(stmt, 1, cursor)
            var paths: [String] = []
            var status = sqlite3_step(stmt)
            while status == SQLITE_ROW {
                cursor = sqlite3_column_int64(stmt, 0)
                if let path = ClipboardSQLite.columnString(stmt, 1) { paths.append(path) }
                status = sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            guard status == SQLITE_DONE, !paths.isEmpty else { return }
            let directory = imagesDir
            let remove = removeImageFile
            let batch = paths
            let completed = await Task.detached(priority: .utility) {
                batch.filter { path in
                    // Revalidate immediately before deletion, including jobs restored after restart.
                    guard let url = Self.managedBlobURL(for: path, in: directory) else { return true }
                    let removed = remove(url)
                    if removed { ImageThumbnail.removeCachedImage(for: url) }
                    return removed
                }
            }.value
            guard !Task.isCancelled else { return }
            guard transaction({
                guard let done = prepare("DELETE FROM pending_blob_deletions WHERE path = ?") else {
                    return false
                }
                defer { sqlite3_finalize(done) }
                for path in completed {
                    sqlite3_bind_text(done, 1, path, -1, SQLITE_TRANSIENT)
                    guard stepAndReset(done) else { return false }
                }
                return true
            }) else { return }
            // The cursor visits each job once per pass. Failed files remain retryable without
            // blocking later batches or causing a tight retry loop.
        }
    }

    func waitForRetentionCleanup() async {
        while let task = blobDeletionTask { await task.value }
    }

    nonisolated private static func removeImageFile(at url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return true
        } catch {
            return false
        }
    }

    private func deleteBlob(_ item: ClipboardItem) {
        guard let path = item.imagePath, let url = managedBlobURL(for: path) else { return }
        try? FileManager.default.removeItem(at: url)
        ImageThumbnail.removeCachedImage(for: url)
    }

    /// Accept only regular PNG files directly owned by this store. Database paths are data, not
    /// authority to delete arbitrary files.
    private func managedBlobURL(for path: String) -> URL? {
        Self.managedBlobURL(for: path, in: imagesDir)
    }

    nonisolated private static func managedBlobURL(for path: String, in imagesDir: URL) -> URL? {
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

    private func openDatabase() {
        guard
            sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
                == SQLITE_OK,
            let db, ClipboardSQLite.prepareSchema(in: db)
        else { return }
        insertStmt = prepare(
            """
            INSERT INTO items(
              id, kind, text, image_path, created_at, source_app, image_fingerprint,
              custom_title, first_copied_at, ocr_text, ocr_status, ocr_version, ocr_attempts,
              pinyin, pinyin_initials, copy_count
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """
        )
        loadStmt = prepare(
            """
            \(Self.itemSelection) ORDER BY created_at DESC, rowid DESC LIMIT ?
            """)
        refreshStmt = prepare(
            "UPDATE items SET created_at = ?1, source_app = ?2, kind = ?4, copy_count = ?5 WHERE id = ?3")
        deleteByIDStmt = prepare("DELETE FROM items WHERE id = ?")
        staleImagesStmt = prepare(
            """
            INSERT OR IGNORE INTO pending_blob_deletions(path)
            SELECT image_path FROM items
            WHERE created_at < ? AND image_path IS NOT NULL
            """)
        deleteStaleStmt = prepare("DELETE FROM items WHERE created_at < ?")
        imageByFingerprintStmt = prepare(
            """
            \(Self.itemSelection) WHERE image_fingerprint = ? LIMIT 1
            """)
        textByContentStmt = prepare(
            """
            \(Self.itemSelection) WHERE kind != 'image' AND text = ? COLLATE BINARY
            ORDER BY created_at DESC, rowid DESC LIMIT 1
            """)
        itemByIDStmt = prepare(
            """
            \(Self.itemSelection) WHERE id = ? LIMIT 1
            """)
        insertStackStmt = prepare(
            "INSERT INTO stacks(id, name, position) VALUES(?,?,?)")
        upsertMembershipStmt = prepare(
            """
            INSERT INTO stack_items(item_id, stack_id) VALUES(?,?)
            ON CONFLICT(item_id) DO UPDATE SET stack_id = excluded.stack_id
            """)
        deleteMembershipStmt = prepare("DELETE FROM stack_items WHERE item_id = ?")
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
            insertStackStmt, upsertMembershipStmt, deleteMembershipStmt,
        ].forEach { sqlite3_finalize($0) }
        sqlite3_close_v2(db)
    }
}
