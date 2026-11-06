import Foundation
import SQLite3

extension ClipboardStore {
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
        ClipboardSQLite.bindDouble(date.timeIntervalSince1970 - retention.maxAge, to: stmt, at: 1)
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

    func pruneIfDue() {
        let now = Date()
        guard now < lastPrunedAt || now.timeIntervalSince(lastPrunedAt) >= maintenanceInterval else {
            return
        }
        enforceLimits(at: now)
    }

    func startMaintenanceIfNeeded() {
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
            ClipboardSQLite.bindDouble(cutoff.timeIntervalSince1970, to: imagesStmt, at: 1)
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
            ClipboardSQLite.bindDouble(cutoff.timeIntervalSince1970, to: members, at: 1)
            var status = sqlite3_step(members)
            while status == SQLITE_ROW {
                if let id = ClipboardSQLite.columnString(members, 0).flatMap(UUID.init(uuidString:)) {
                    expiredMemberships.insert(id)
                }
                status = sqlite3_step(members)
            }
            guard status == SQLITE_DONE else { return false }
            ClipboardSQLite.bindDouble(cutoff.timeIntervalSince1970, to: deleteMembers, at: 1)
            guard sqlite3_step(deleteMembers) == SQLITE_DONE else { return false }
            ClipboardSQLite.bindDouble(cutoff.timeIntervalSince1970, to: deleteStmt, at: 1)
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
            ClipboardSQLite.bindInt64(cursor, to: stmt, at: 1)
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
                    ClipboardSQLite.bindText(path, to: done, at: 1)
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

    nonisolated static func removeImageFile(at url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return true
        } catch {
            return false
        }
    }

    func deleteBlob(_ item: ClipboardItem) {
        guard let path = item.imagePath, let url = managedBlobURL(for: path) else { return }
        try? FileManager.default.removeItem(at: url)
        ImageThumbnail.removeCachedImage(for: url)
    }

    /// Accept only regular PNG files directly owned by this store. Database paths are data, not
    /// authority to delete arbitrary files.
    func managedBlobURL(for path: String) -> URL? {
        Self.managedBlobURL(for: path, in: imagesDir)
    }

    nonisolated static func managedBlobURL(for path: String, in imagesDir: URL) -> URL? {
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
}
