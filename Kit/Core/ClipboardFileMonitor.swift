import Foundation
import SQLite3
import UniformTypeIdentifiers

extension ClipboardStore {
    /// Access credentials belong to the history row, so deletion and retention remove them too
    func fileBookmarks(for id: ClipboardItem.ID) -> [String: Data] {
        guard let stmt = prepare("SELECT file_bookmarks FROM items WHERE id = ?") else { return [:] }
        defer { sqlite3_finalize(stmt) }
        ClipboardSQLite.bindText(id.uuidString, to: stmt, at: 1)
        guard sqlite3_step(stmt) == SQLITE_ROW,
            let bytes = sqlite3_column_blob(stmt, 0)
        else { return [:] }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
        return (try? PropertyListDecoder().decode([String: Data].self, from: data)) ?? [:]
    }

    @discardableResult
    func rememberFileBookmarks(_ bookmarks: [String: Data], for id: ClipboardItem.ID) -> Bool {
        guard !bookmarks.isEmpty else { return true }
        var merged = fileBookmarks(for: id)
        merged.merge(bookmarks) { _, fresh in fresh }
        guard let data = try? PropertyListEncoder().encode(merged),
            let stmt = prepare("UPDATE items SET file_bookmarks = ? WHERE id = ?")
        else { return false }
        defer { sqlite3_finalize(stmt) }
        ClipboardSQLite.bindBlob(data, to: stmt, at: 1)
        ClipboardSQLite.bindText(id.uuidString, to: stmt, at: 2)
        return sqlite3_step(stmt) == SQLITE_DONE && sqlite3_changes(db) == 1
    }

    /// Inspect persisted references too, so replacements made while Kit was closed invalidate OCR
    func refreshFileReferences() async {
        guard let stmt = prepare("\(ClipboardSQLite.itemSelection) WHERE file_urls IS NOT NULL AND file_is_image = 1")
        else { return }
        var references: [ClipboardItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let item = ClipboardSQLite.row(stmt) { references.append(item) }
        }
        sqlite3_finalize(stmt)
        for item in references {
            guard !Task.isCancelled else { return }
            await refreshFileReference(item)
            await Task.yield()
        }
    }

    func refreshFileReference(_ item: ClipboardItem) async {
        guard item.isFileBacked, item.hasImagePreview, let url = imageURL(for: item) else { return }
        let generation = captureGeneration
        let bookmarks = fileBookmarks(for: item.id)
        let snapshot = await Task.detached(priority: .utility) {
            let access = ClipboardFileReference.prepare(
                urls: item.fileURLs, bookmarks: bookmarks, refreshCredentials: false)
            let signature = ImageThumbnail.sourceSignature(for: url)
            let changed = ImageThumbnail.refreshFile(at: url)
            return (access.lease, signature, changed)
        }.value
        defer { withExtendedLifetime(snapshot.0) {} }
        guard !Task.isCancelled, generation == captureGeneration else { return }
        reconcileFileSource(item, signature: snapshot.1)
        startImageOCRWorkerIfNeeded()
        if snapshot.2 { NotificationCenter.default.post(name: ImageThumbnail.fileDidChange, object: nil) }
    }

    func startFileRefreshIfNeeded() {
        guard fileRefreshTask == nil else { return }
        fileRefreshTask = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                await self?.refreshFileReferences()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }

    /// Reset only derived metadata, never the historical paths or copy metadata
    @discardableResult
    func reconcileFileSource(_ item: ClipboardItem, signature: String) -> Bool {
        guard let stmt = prepare("""
            UPDATE items SET file_signature = ?, ocr_text = NULL, ocr_status = NULL,
                             ocr_version = NULL, ocr_attempts = 0, pinyin = ?, pinyin_initials = ?
            WHERE id = ? AND file_urls IS ? AND file_signature IS NOT ?
            """) else { return false }
        defer { sqlite3_finalize(stmt) }
        let forms = Self.searchForms(for: item, imageOCRText: nil)
        ClipboardSQLite.bindText(signature, to: stmt, at: 1)
        ClipboardSQLite.bindText(forms.full, to: stmt, at: 2)
        ClipboardSQLite.bindText(forms.initials, to: stmt, at: 3)
        ClipboardSQLite.bindText(item.id.uuidString, to: stmt, at: 4)
        ClipboardSQLite.bindText(ClipboardSQLite.encodedFileURLs(item.fileURLs), to: stmt, at: 5)
        ClipboardSQLite.bindText(signature, to: stmt, at: 6)
        guard sqlite3_step(stmt) == SQLITE_DONE, sqlite3_changes(db) > 0 else { return false }
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = items[index].withImageOCR(nil)
        } else { revision &+= 1 }
        return true
    }

    nonisolated static func fileSupportsImagePreview(_ urls: [URL]) -> Bool {
        guard urls.count == 1, let url = urls.first else { return false }
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey])
        guard values?.isDirectory != true else { return false }
        if values?.contentType?.conforms(to: .image) == true {
            return true
        }
        guard let type = UTType(filenameExtension: url.pathExtension),
            type.conforms(to: .image)
        else { return false }
        return true
    }
}
