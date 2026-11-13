import Foundation
import SQLite3

extension ClipboardStore {
    enum ImageTextIndexState: Equatable {
        case none, indexed, indexing
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
        guard let stmt = prepare("""
            SELECT COUNT(*) FROM items
            WHERE \(ClipboardSQLite.imageBackedPredicate)
            """)
        else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    @discardableResult
    func clearImageTextIndex() -> Bool {
        guard transaction({
            guard let select = prepare("""
                SELECT id, text FROM items
                WHERE \(ClipboardSQLite.imageBackedPredicate) AND ocr_text IS NOT NULL
                  AND file_urls IS NOT NULL
                """)
            else { return false }
            defer { sqlite3_finalize(select) }
            var rows: [(id: String, text: String)] = []
            var status = sqlite3_step(select)
            while status == SQLITE_ROW {
                guard let id = ClipboardSQLite.columnString(select, 0) else { return false }
                rows.append((id, ClipboardSQLite.columnString(select, 1) ?? ""))
                status = sqlite3_step(select)
            }
            guard status == SQLITE_DONE, let update = prepare("""
                UPDATE items SET ocr_text = NULL, ocr_status = 'complete',
                                 ocr_version = \(ClipboardImageTextRecognition.version),
                                 pinyin = ?, pinyin_initials = ? WHERE id = ?
                """)
            else { return false }
            defer { sqlite3_finalize(update) }
            for row in rows {
                let forms = Pinyin.searchForms(for: row.text)
                ClipboardSQLite.bindText(forms.full.isEmpty ? nil : forms.full, to: update, at: 1)
                ClipboardSQLite.bindText(forms.initials.isEmpty ? nil : forms.initials, to: update, at: 2)
                ClipboardSQLite.bindText(row.id, to: update, at: 3)
                guard stepAndReset(update) else { return false }
            }
            return ClipboardSQLite.execute("""
                UPDATE items SET ocr_text = NULL, ocr_status = 'complete',
                                 ocr_version = \(ClipboardImageTextRecognition.version),
                                 pinyin = NULL, pinyin_initials = NULL
                WHERE \(ClipboardSQLite.imageBackedPredicate) AND ocr_text IS NOT NULL
                  AND file_urls IS NULL
                """, in: db)
        }) else { return false }
        imageTextSearchGeneration &+= 1
        imageOCRTask?.cancel()
        imageOCRRebuildIDs = nil

        func cleared(_ item: ClipboardItem) -> ClipboardItem {
            guard item.hasImagePreview,
                let metadata = item.imageOCR, metadata.text != nil
            else {
                return item
            }
            return item.withImageOCR(ClipboardImageOCR(
                text: nil, status: .complete, version: ClipboardImageTextRecognition.version,
                attempts: metadata.attempts))
        }
        // Update the resident overlay and undo snapshot before publishing a search revision.
        if let entry = deletedEntry {
            deletedEntry = DeletedEntry(
                item: cleared(entry.item), stackID: entry.stackID, imageBackup: entry.imageBackup,
                fileBookmarks: entry.fileBookmarks)
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
            guard let stmt = prepare("""
                SELECT id FROM items
                WHERE \(ClipboardSQLite.imageBackedPredicate)
                ORDER BY created_at, rowid
                """)
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
            return ClipboardSQLite.execute("""
                UPDATE items SET ocr_status = NULL, ocr_version = NULL, ocr_attempts = 0
                WHERE \(ClipboardSQLite.imageBackedPredicate)
                """, in: db)
        }) else { return false }
        imageTextSearchGeneration &+= 1
        imageOCRRebuildIDs = ids
        startImageOCRWorkerIfNeeded()
        revision &+= 1
        return true
    }

    func refreshImageTextIndexState() {
        let state: ImageTextIndexState
        if imageOCRTask != nil {
            state = .indexing
        } else {
            guard let stmt = prepare("""
                SELECT EXISTS(
                    SELECT 1 FROM items
                    WHERE \(ClipboardSQLite.imageBackedPredicate) AND ocr_text IS NOT NULL
                )
                """)
            else { return }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return }
            state = sqlite3_column_int(stmt, 0) == 0 ? .none : .indexed
        }
        if imageTextIndexState != state { imageTextIndexState = state }
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
                if let item = loadItem(id: id), item.hasImagePreview,
                    item.imageOCR == nil || (item.imageOCR?.status == .failed
                        && (item.imageOCR?.attempts ?? 0) < ClipboardImageTextRecognition.maxAttempts)
                { return item }
                imageOCRRebuildIDs?.removeLast()
            }
            return nil
        }
        guard imageTextSearchEnabled else { return nil }
        guard let stmt = prepare("""
            \(ClipboardSQLite.itemSelection) WHERE \(ClipboardSQLite.imageBackedPredicate) AND
              (ocr_status IS NULL OR (ocr_status = 'failed' AND ocr_attempts < \(ClipboardImageTextRecognition.maxAttempts)))
            ORDER BY created_at DESC, rowid DESC LIMIT 1
            """)
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? ClipboardSQLite.row(stmt) : nil
    }

    func startImageOCRWorkerIfNeeded() {
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
            while !Task.isCancelled, var item = self?.nextImageOCRItem() {
                guard let generation = self?.captureGeneration else { return }
                let result: ClipboardImageOCRResult
                var sourceSignature: String?
                var access: FileAccessLease?
                if let url = self?.imageURL(for: item) {
                    if item.isFileBacked {
                        let bookmarks = self?.fileBookmarks(for: item.id) ?? [:]
                        let source = item
                        let snapshot = await Task.detached(priority: .utility) {
                            let prepared = ClipboardFileReference.prepare(
                                urls: source.fileURLs, bookmarks: bookmarks, refreshCredentials: false)
                            return (prepared.lease, ImageThumbnail.sourceSignature(for: url))
                        }.value
                        guard !Task.isCancelled, self?.captureGeneration == generation else { return }
                        access = snapshot.0
                        sourceSignature = snapshot.1
                        self?.reconcileFileSource(item, signature: snapshot.1)
                        guard let current = self?.loadItem(id: item.id), self?.hasSameOCRSource(current, as: item) == true
                        else { continue }
                        item = current
                    }
                    if !item.isFileBacked || access != nil {
                        result = await recognize(url)
                    } else { result = .failed }
                    if let sourceSignature {
                        let currentSignature = await Task.detached(priority: .utility) {
                            ImageThumbnail.sourceSignature(for: url)
                        }.value
                        guard !Task.isCancelled else { return }
                        if currentSignature != sourceSignature {
                            self?.reconcileFileSource(item, signature: currentSignature)
                            try? await Task.sleep(for: .milliseconds(25))
                            continue
                        }
                    }
                } else {
                    result = .failed
                }
                defer { withExtendedLifetime(access) {} }
                guard !Task.isCancelled else { return }
                let recognizedItem = item
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
                            attempts: (recognizedItem.imageOCR?.attempts ?? 0) + 1),
                        Self.searchForms(for: recognizedItem, imageOCRText: text))
                }.value
                guard !Task.isCancelled else { return }
                if self?.saveImageOCR(metadata.0, forms: metadata.1, for: item,
                                      generation: generation, sourceSignature: sourceSignature) != true {
                    guard let self, let current = self.item(id: item.id) else { continue }
                    guard self.hasSameOCRSource(current, as: item) else { continue }
                    // Retry a transient database lock once, without running recognition again.
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    guard self.saveImageOCR(metadata.0, forms: metadata.1, for: item,
                                           generation: generation, sourceSignature: sourceSignature) == true
                    else {
                        guard let current = self.item(id: item.id) else { continue }
                        guard self.hasSameOCRSource(current, as: item) else { continue }
                        return
                    }
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
        for item: ClipboardItem, generation: UInt64, sourceSignature: String? = nil
    ) -> Bool {
        guard generation == captureGeneration, let stmt = prepare("""
            UPDATE items SET ocr_text = ?, ocr_status = ?, ocr_version = ?, ocr_attempts = ?,
                             pinyin = ?, pinyin_initials = ?
            WHERE id = ? AND \(ClipboardSQLite.imageBackedPredicate)
              AND created_at = ? AND copy_count = ?
              AND image_path IS ? AND image_fingerprint IS ? AND file_urls IS ?
              AND file_signature IS ?
            """)
        else { return false }
        defer { sqlite3_finalize(stmt) }
        ClipboardSQLite.bindText(metadata.text, to: stmt, at: 1)
        ClipboardSQLite.bindText(metadata.status.rawValue, to: stmt, at: 2)
        ClipboardSQLite.bindInt(metadata.version, to: stmt, at: 3)
        ClipboardSQLite.bindInt(metadata.attempts, to: stmt, at: 4)
        ClipboardSQLite.bindText(forms.full, to: stmt, at: 5)
        ClipboardSQLite.bindText(forms.initials, to: stmt, at: 6)
        ClipboardSQLite.bindText(item.id.uuidString, to: stmt, at: 7)
        ClipboardSQLite.bindDouble(item.lastCopiedAt.timeIntervalSince1970, to: stmt, at: 8)
        ClipboardSQLite.bindInt64(Int64(item.copyCount), to: stmt, at: 9)
        ClipboardSQLite.bindText(item.imagePath, to: stmt, at: 10)
        ClipboardSQLite.bindText(item.imageFingerprint, to: stmt, at: 11)
        ClipboardSQLite.bindText(
            item.isFileBacked ? ClipboardSQLite.encodedFileURLs(item.fileURLs) : nil,
            to: stmt, at: 12)
        ClipboardSQLite.bindText(sourceSignature, to: stmt, at: 13)
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

    private func hasSameOCRSource(_ current: ClipboardItem, as captured: ClipboardItem) -> Bool {
        // Compare the epoch values stored by SQLite, which can round Date precision
        current.id == captured.id && current.hasImagePreview
            && current.lastCopiedAt.timeIntervalSince1970 == captured.lastCopiedAt.timeIntervalSince1970
            && current.copyCount == captured.copyCount
            && current.imagePath == captured.imagePath
            && current.imageFingerprint == captured.imageFingerprint
            && current.fileURLs == captured.fileURLs
    }

    func scheduleSearchMetadataUpdate(for item: ClipboardItem) {
        guard item.kind != .image, !item.isFileBacked,
            let text = item.text, Pinyin.containsHan(text)
        else { return }
        pendingSearchMetadata.append(
            SearchMetadataUpdate(id: item.id.uuidString, text: text))
        startSearchMetadataWorkerIfNeeded()
    }

    nonisolated static func searchForms(
        for item: ClipboardItem, imageOCRText: String?
    ) -> Pinyin.SearchForms {
        let text: String
        if item.hasImagePreview {
            text = [item.text, imageOCRText].compactMap { $0 }.joined(separator: "\n")
        } else {
            // Large text entries build their pinyin metadata on the background queue
            text = item.isFileBacked ? (item.text ?? "") : ""
        }
        return Pinyin.searchForms(for: text)
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
            let worker = Task.detached(priority: .utility) {
                ClipboardSearch.updateMetadata(path: path, batch: batch)
            }
            let updated = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
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
}
