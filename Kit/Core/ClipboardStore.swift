import Foundation
import Observation
import SQLite3

@MainActor
final class ObservationToken {
    private let cancel: () -> Void

    init(_ cancel: @escaping () -> Void) {
        self.cancel = cancel
    }

    isolated deinit {
        cancel()
    }
}

/// SQLite-backed clipboard history (rows + trigram FTS5 index in `clipboard.sqlite3`, image blobs on disk).
@MainActor
@Observable
final class ClipboardStore {
    /// The most recent in-memory history window; older rows are queried from SQLite.
    var items: [ClipboardItem] = [] {
        didSet { revision &+= 1 }
    }
    var revision: UInt64 = 0 {
        didSet { notifyRevisionObservers() }
    }
    /// Named stacks shown in the palette.
    var stacks: [ClipboardStack] = []
    var imageTextIndexState: ImageTextIndexState = .none

    /// Item id to the single stack that owns it.
    @ObservationIgnored var stackMembership: [ClipboardItem.ID: ClipboardStack.ID] = [:]
    /// Fired after a successful external capture, including recopies of existing content.
    @ObservationIgnored var onItemCaptured: (() -> Void)?
    @ObservationIgnored private(set) var captureGeneration: UInt64 = 0
    @ObservationIgnored var updateHistoryAfterAction = true
    @ObservationIgnored private(set) var hasDeferredHistoryUpdates = false
    @ObservationIgnored var maxAge: TimeInterval = ClipboardRetention.threeMonths.maxAge
    @ObservationIgnored var imageTextSearchEnabled = true

    static let memoryWindow = 1000
    @ObservationIgnored var lastPrunedAt = Date.distantPast
    @ObservationIgnored let maintenanceInterval: TimeInterval
    @ObservationIgnored var maintenanceTask: Task<Void, Never>?
    @ObservationIgnored var blobDeletionTask: Task<Void, Never>?
    @ObservationIgnored let removeImageFile: @Sendable (URL) -> Bool

    @ObservationIgnored let imagesDir: URL
    @ObservationIgnored let deletedImagesDir: URL
    @ObservationIgnored let dbURL: URL

    struct DeletedEntry {
        let item: ClipboardItem
        let stackID: ClipboardStack.ID?
        let imageBackup: URL?
        let fileBookmarks: [String: Data]
    }
    // A successful deletion replaces this slot; a successful restore consumes it.
    @ObservationIgnored var deletedEntry: DeletedEntry?

    var canUndoDeletion: Bool {
        guard let deletedEntry else { return false }
        guard maxAge.isFinite, maxAge >= 0, maxAge != ClipboardRetention.forever.maxAge else {
            return true
        }
        return deletedEntry.item.lastCopiedAt >= Date().addingTimeInterval(-maxAge)
    }

    @ObservationIgnored var db: OpaquePointer?
    @ObservationIgnored var insertStmt: OpaquePointer?
    @ObservationIgnored var loadStmt: OpaquePointer?
    @ObservationIgnored var refreshStmt: OpaquePointer?
    @ObservationIgnored var refreshImageOCRStmt: OpaquePointer?
    @ObservationIgnored var deleteByIDStmt: OpaquePointer?
    @ObservationIgnored var staleImagesStmt: OpaquePointer?
    @ObservationIgnored var deleteStaleStmt: OpaquePointer?
    @ObservationIgnored var imageByFingerprintStmt: OpaquePointer?
    @ObservationIgnored var textByContentStmt: OpaquePointer?
    @ObservationIgnored var fileByContentStmt: OpaquePointer?
    @ObservationIgnored var itemByIDStmt: OpaquePointer?
    @ObservationIgnored var insertStackStmt: OpaquePointer?
    @ObservationIgnored var upsertMembershipStmt: OpaquePointer?
    @ObservationIgnored var deleteMembershipStmt: OpaquePointer?
    @ObservationIgnored var pendingSearchMetadata: [SearchMetadataUpdate] = []
    @ObservationIgnored var searchMetadataTask: Task<Void, Never>?
    @ObservationIgnored var imageOCRTask: Task<Void, Never>?
    @ObservationIgnored var fileRefreshTask: Task<Void, Never>?
    @ObservationIgnored var thumbnailWarmTask: Task<Void, Never>?
    /// A snapshot of historical IDs; new captures never join a manual rebuild while search is off.
    @ObservationIgnored var imageOCRRebuildIDs: [ClipboardItem.ID]?
    @ObservationIgnored var imageTextSearchGeneration: UInt64 = 0
    @ObservationIgnored let recognizeImage: @Sendable (URL) async -> ClipboardImageOCRResult
    @ObservationIgnored private var revisionObservers: [UUID: () -> Void] = [:]

    init(
        directory: URL? = nil,
        maintenanceInterval: TimeInterval = 3_600,
        removeImageFile: @escaping @Sendable (URL) -> Bool = ClipboardStore.removeImageFile,
        recognizeImage: @escaping @Sendable (URL) async -> ClipboardImageOCRResult =
            ClipboardImageTextRecognition.recognize
    ) {
        let base = directory ?? Self.defaultDirectory
        imagesDir = base.appendingPathComponent("images", isDirectory: true)
        ImageThumbnail.registerManagedImageDirectory(imagesDir)
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
        fileRefreshTask?.cancel()
        maintenanceTask?.cancel()
        blobDeletionTask?.cancel()
        imageOCRTask?.cancel()
        thumbnailWarmTask?.cancel()
        closeDatabase()
        try? FileManager.default.removeItem(at: deletedImagesDir)
    }

    func observeRevision(_ handler: @escaping () -> Void) -> ObservationToken {
        let id = UUID()
        revisionObservers[id] = handler
        return ObservationToken { [weak self] in
            self?.revisionObservers.removeValue(forKey: id)
        }
    }

    private func notifyRevisionObservers() {
        for observer in revisionObservers.values {
            observer()
        }
    }

    func load() {
        loadStackState()
        guard let stmt = loadStmt else { return }
        ClipboardSQLite.bindInt(Self.memoryWindow, to: stmt, at: 1)
        var loaded: [ClipboardItem] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            if let item = ClipboardSQLite.row(stmt) { loaded.append(item) }
            status = sqlite3_step(stmt)
        }
        ClipboardSQLite.reset(stmt)
        guard status == SQLITE_DONE else { return }
        items = loaded
        // Age passes while the app isn't running; insert-time pruning alone can't catch that.
        enforceLimits()
        startMaintenanceIfNeeded()
        startFileRefreshIfNeeded()
        startImageOCRWorkerIfNeeded()
    }

    @discardableResult
    func addText(
        _ text: String, kind: ClipboardItem.Kind, sourceBundleID: String?,
        expectedGeneration: UInt64? = nil
    ) -> ClipboardItem? {
        if let expectedGeneration, expectedGeneration != captureGeneration { return nil }
        if let existing = textItem(matching: text, sourceBundleID: sourceBundleID) {
            let updated = existing.recopied(sourceBundleID: sourceBundleID).withKind(kind)
            return refresh(updated) ? updated : nil
        }
        let item = ClipboardItem(text: text, kind: kind, sourceBundleID: sourceBundleID)
        return insert(item) ? item : nil
    }

    @discardableResult
    func addFiles(
        _ fileURLs: [URL], sourceBundleID: String?, expectedGeneration: UInt64? = nil,
        fileIsImage: Bool? = nil
    ) -> ClipboardItem? {
        if let expectedGeneration, expectedGeneration != captureGeneration { return nil }
        guard fileURLs.allSatisfy(\.isFileURL) else { return nil }
        let normalizedURLs = fileURLs.map(\.standardizedFileURL)
        guard !normalizedURLs.isEmpty else { return nil }
        for url in normalizedURLs {
            ImageThumbnail.invalidateFile(at: url)
        }
        let supportsImage = fileIsImage ?? Self.fileSupportsImagePreview(normalizedURLs)
        startFileRefreshIfNeeded()
        if let existing = fileItem(matching: normalizedURLs, sourceBundleID: sourceBundleID) {
            let resetImageOCR = existing.hasImagePreview || supportsImage
            var updated = existing.recopied(sourceBundleID: sourceBundleID).withFileImagePreview(supportsImage)
            if resetImageOCR { updated = updated.withImageOCR(nil) }
            guard refresh(updated, resetImageOCR: resetImageOCR) else { return nil }
            if supportsImage {
                if let url = imageURL(for: updated) { warmImageRow(url) }
                startImageOCRWorkerIfNeeded()
                refreshImageTextIndexState()
            }
            return updated
        }
        let item = ClipboardItem(
            id: UUID(), kind: .file,
            text: normalizedURLs.map(\.path).joined(separator: "\n"),
            imagePath: nil, imageFingerprint: nil, fileURLs: normalizedURLs, fileIsImage: supportsImage,
            lastCopiedAt: Date(), sourceBundleID: sourceBundleID)
        guard insert(item) else { return nil }
        return item
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
        let entry = DeletedEntry(
            item: item, stackID: stackMembership[item.id], imageBackup: backup,
            fileBookmarks: fileBookmarks(for: item.id))
        let deleted = transaction {
            ClipboardSQLite.bindText(item.id.uuidString, to: stmt, at: 1)
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
            ?? (!entry.item.fileURLs.isEmpty
                ? fileItem(
                    matching: entry.item.fileURLs,
                    sourceBundleID: entry.item.sourceBundleID)
                : entry.item.text.flatMap {
                    textItem(matching: $0, sourceBundleID: entry.item.sourceBundleID)
                })
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
            if existing == nil, !entry.fileBookmarks.isEmpty,
                !rememberFileBookmarks(entry.fileBookmarks, for: restored.id)
            { return false }
            if let stackID, !writeMembership(restored.id, stackID: stackID) { return false }
            return true
        }) else {
            if let copiedImage { try? FileManager.default.removeItem(at: copiedImage) }
            return nil
        }
        discardDeletion()
        if let stackID { stackMembership[restored.id] = stackID }
        items = Array(ClipboardSearch.displayOrder(
            [restored] + items.filter { $0.id != restored.id }).prefix(Self.memoryWindow))
        if existing == nil {
            scheduleSearchMetadataUpdate(for: restored)
            startImageOCRWorkerIfNeeded()
        }
        refreshImageTextIndexState()
        if let url = imageURL(for: restored) { warmImageRow(url) }
        return restored
    }

    func transaction(_ body: () -> Bool) -> Bool {
        ClipboardSQLite.transaction(in: db, body)
    }

    func discardDeletion() {
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
        guard ClipboardSQLite.execute("DELETE FROM items", in: db) else { return }
        discardDeletion()
        ClipboardSQLite.execute("DELETE FROM stack_items", in: db)
        stackMembership.removeAll()
        items = []
        try? FileManager.default.removeItem(at: imagesDir)
        ImageThumbnail.removeCachedRows(in: imagesDir)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        refreshImageTextIndexState()
    }

    func imageURL(for item: ClipboardItem) -> URL? {
        if item.fileIsImage, item.fileURLs.count == 1 {
            return item.fileURLs[0]
        }
        guard let path = item.imagePath else { return nil }
        return managedBlobURL(for: path)
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
        let membership = stackMembership
        let resident = cursor == nil && !trimmed.isEmpty ? items.filter {
            (kind == nil || $0.kind == kind)
                && (stackID == nil || membership[$0.id] == stackID)
        } : []
        let searchTask = Task.detached(priority: .userInitiated) {
            ClipboardSearch.query(
                path: path, query: trimmed, kind: kind, stackID: stackID,
                after: cursor, limit: limit, includesImageText: includesImageText,
                residentItems: resident)
        }
        let page = await withTaskCancellationHandler {
            await searchTask.value
        } onCancel: {
            searchTask.cancel()
        }
        guard !Task.isCancelled, imageGeneration == imageTextSearchGeneration, let page else {
            return ClipboardSearchPage(items: [], nextCursor: nil, failed: true)
        }
        return page
    }

    // MARK: - Internal / Private Helpers

    /// Copy metadata and history position commit together before feedback
    @discardableResult
    private func refresh(
        _ updated: ClipboardItem, externalCapture: Bool = true, deferPublication: Bool = false,
        resetImageOCR: Bool = false
    ) -> Bool {
        guard let stmt = resetImageOCR ? refreshImageOCRStmt : refreshStmt else { return false }
        ClipboardSQLite.bindDouble(updated.lastCopiedAt.timeIntervalSince1970, to: stmt, at: 1)
        ClipboardSQLite.bindText(updated.sourceBundleID, to: stmt, at: 2)
        ClipboardSQLite.bindText(updated.id.uuidString, to: stmt, at: 3)
        ClipboardSQLite.bindText(updated.kind.rawValue, to: stmt, at: 4)
        ClipboardSQLite.bindInt64(Int64(updated.copyCount), to: stmt, at: 5)
        ClipboardSQLite.bindInt(updated.fileIsImage ? 1 : 0, to: stmt, at: 8)
        if resetImageOCR {
            let forms = Self.searchForms(for: updated, imageOCRText: updated.imageOCR?.text)
            ClipboardSQLite.bindText(forms.full, to: stmt, at: 6)
            ClipboardSQLite.bindText(forms.initials, to: stmt, at: 7)
        }
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
        if item.hasImagePreview { startImageOCRWorkerIfNeeded() }
        onItemCaptured?()
        return true
    }

    @discardableResult
    private func bindAndInsert(_ stmt: OpaquePointer, _ item: ClipboardItem) -> Bool {
        ClipboardSQLite.bindText(item.id.uuidString, to: stmt, at: 1)
        ClipboardSQLite.bindText(item.kind.rawValue, to: stmt, at: 2)
        ClipboardSQLite.bindText(item.text, to: stmt, at: 3)
        ClipboardSQLite.bindText(item.imagePath, to: stmt, at: 4)
        ClipboardSQLite.bindDouble(item.lastCopiedAt.timeIntervalSince1970, to: stmt, at: 5)
        ClipboardSQLite.bindText(item.sourceBundleID, to: stmt, at: 6)
        ClipboardSQLite.bindText(item.imageFingerprint, to: stmt, at: 7)
        ClipboardSQLite.bindText(item.customTitle, to: stmt, at: 8)
        ClipboardSQLite.bindDouble(item.firstCopiedAt.timeIntervalSince1970, to: stmt, at: 9)
        if let metadata = item.imageOCR {
            ClipboardSQLite.bindText(metadata.text, to: stmt, at: 10)
            ClipboardSQLite.bindText(metadata.status.rawValue, to: stmt, at: 11)
            ClipboardSQLite.bindInt(metadata.version, to: stmt, at: 12)
            ClipboardSQLite.bindInt(metadata.attempts, to: stmt, at: 13)
        } else {
            for column: Int32 in 10...12 { ClipboardSQLite.bindNull(to: stmt, at: column) }
            ClipboardSQLite.bindInt(0, to: stmt, at: 13)
        }
        let forms = Self.searchForms(for: item, imageOCRText: item.imageOCR?.text)
        ClipboardSQLite.bindText(forms.full, to: stmt, at: 14)
        ClipboardSQLite.bindText(forms.initials, to: stmt, at: 15)
        ClipboardSQLite.bindInt64(Int64(item.copyCount), to: stmt, at: 16)
        if item.isFileBacked {
            ClipboardSQLite.bindText(
                ClipboardSQLite.encodedFileURLs(item.fileURLs), to: stmt, at: 17)
        } else {
            ClipboardSQLite.bindNull(to: stmt, at: 17)
        }
        ClipboardSQLite.bindInt(item.fileIsImage ? 1 : 0, to: stmt, at: 18)
        return stepAndReset(stmt)
    }

    func loadItem(id: UUID) -> ClipboardItem? {
        findItem(using: itemByIDStmt, matching: id.uuidString)
    }

    private func image(matching fingerprint: String) -> ClipboardItem? {
        findItem(using: imageByFingerprintStmt, matching: fingerprint)
    }

    private func textItem(matching text: String, sourceBundleID: String?) -> ClipboardItem? {
        guard let stmt = textByContentStmt else { return nil }
        ClipboardSQLite.bindText(text, to: stmt, at: 1)
        ClipboardSQLite.bindText(sourceBundleID, to: stmt, at: 2)
        let item = sqlite3_step(stmt) == SQLITE_ROW ? ClipboardSQLite.row(stmt) : nil
        ClipboardSQLite.reset(stmt)
        return item
    }

    private func fileItem(
        matching fileURLs: [URL], sourceBundleID: String?
    ) -> ClipboardItem? {
        guard let stmt = fileByContentStmt,
            let encodedURLs = ClipboardSQLite.encodedFileURLs(fileURLs)
        else { return nil }
        ClipboardSQLite.bindText(encodedURLs, to: stmt, at: 1)
        ClipboardSQLite.bindText(sourceBundleID, to: stmt, at: 2)
        let item = sqlite3_step(stmt) == SQLITE_ROW ? ClipboardSQLite.row(stmt) : nil
        ClipboardSQLite.reset(stmt)
        return item
    }

    private func findItem(using stmt: OpaquePointer?, matching value: String) -> ClipboardItem? {
        guard let stmt else { return nil }
        ClipboardSQLite.bindText(value, to: stmt, at: 1)
        let item = sqlite3_step(stmt) == SQLITE_ROW ? ClipboardSQLite.row(stmt) : nil
        ClipboardSQLite.reset(stmt)
        return item
    }

    private func openDatabase() {
        guard
            sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
                == SQLITE_OK,
            let db
        else {
            ClipboardSQLite.logFailure(db, operation: "open clipboard database")
            return
        }
        guard ClipboardSQLite.prepareSchema(in: db) else { return }
        insertStmt = prepare(
            """
            INSERT INTO items(
              id, kind, text, image_path, created_at, source_app, image_fingerprint,
              custom_title, first_copied_at, ocr_text, ocr_status, ocr_version, ocr_attempts,
              pinyin, pinyin_initials, copy_count, file_urls, file_is_image
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """
        )
        loadStmt = prepare(
            """
            \(ClipboardSQLite.itemSelection) ORDER BY created_at DESC, rowid DESC LIMIT ?
            """)
        refreshStmt = prepare(
            "UPDATE items SET created_at = ?1, source_app = ?2, kind = ?4, copy_count = ?5, file_is_image = ?8 WHERE id = ?3")
        refreshImageOCRStmt = prepare(
            """
            UPDATE items SET created_at = ?1, source_app = ?2, kind = ?4, copy_count = ?5,
                             ocr_text = NULL, ocr_status = NULL, ocr_version = NULL,
                             ocr_attempts = 0, pinyin = ?6, pinyin_initials = ?7, file_is_image = ?8
            WHERE id = ?3
            """)
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
            \(ClipboardSQLite.itemSelection) WHERE image_fingerprint = ? LIMIT 1
            """)
        textByContentStmt = prepare(
            """
            \(ClipboardSQLite.itemSelection) WHERE kind != 'image'
              AND file_urls IS NULL AND text = ? COLLATE BINARY AND source_app IS ?
            ORDER BY created_at DESC, rowid DESC LIMIT 1
            """)
        fileByContentStmt = prepare(
            """
            \(ClipboardSQLite.itemSelection) WHERE file_urls = ? AND source_app IS ?
            ORDER BY created_at DESC, rowid DESC LIMIT 1
            """)
        itemByIDStmt = prepare(
            """
            \(ClipboardSQLite.itemSelection) WHERE id = ? LIMIT 1
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

    func prepare(_ sql: String) -> OpaquePointer? {
        ClipboardSQLite.prepare(sql, in: db)
    }

    @discardableResult
    func stepAndReset(_ stmt: OpaquePointer) -> Bool {
        ClipboardSQLite.stepAndReset(stmt)
    }

    private func closeDatabase() {
        [
            insertStmt, loadStmt, refreshStmt, refreshImageOCRStmt, deleteByIDStmt,
            staleImagesStmt, deleteStaleStmt, imageByFingerprintStmt, textByContentStmt,
            fileByContentStmt, itemByIDStmt,
            insertStackStmt, upsertMembershipStmt, deleteMembershipStmt,
        ].forEach { sqlite3_finalize($0) }
        sqlite3_close_v2(db)
    }
}
