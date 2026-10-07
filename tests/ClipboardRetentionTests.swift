import Foundation
import SQLite3

// Keep this harness isolated from app settings and the user's live history.
enum AppLocalization {
    static func string(_ key: String, locale: Locale) -> String { key }
}

@main
struct ClipboardRetentionTests {
    static func execute(_ directory: URL, _ sql: String) {
        var db: OpaquePointer?
        precondition(sqlite3_open(directory.appendingPathComponent("clipboard.sqlite3").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK,
                     String(cString: sqlite3_errmsg(db)))
    }

    static func count(_ directory: URL, _ sql: String) -> Int {
        var db: OpaquePointer?
        precondition(sqlite3_open(directory.appendingPathComponent("clipboard.sqlite3").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        precondition(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        precondition(sqlite3_step(stmt) == SQLITE_ROW)
        return Int(sqlite3_column_int64(stmt, 0))
    }

    static func age(_ id: UUID, in directory: URL, at date: Date) {
        execute(directory, "UPDATE items SET created_at = \(date.timeIntervalSince1970) WHERE id = '\(id)'")
    }

    @MainActor
    static func store(_ directory: URL, interval: TimeInterval = 3_600) -> ClipboardStore {
        let store = ClipboardStore(directory: directory, maintenanceInterval: interval)
        store.setImageTextSearchEnabled(false)
        store.maxAge = ClipboardRetention.forever.maxAge
        store.load()
        return store
    }

    @MainActor
    static func policyBoundaries(in directory: URL) async {
        let now = Date()
        for retention in ClipboardRetention.allCases where retention != .forever {
            let testDirectory = directory.appendingPathComponent(String(retention.rawValue))
            let store = store(testDirectory)
            let older = store.addText("older", kind: .text, sourceBundleID: nil)!
            let boundary = store.addText("boundary", kind: .text, sourceBundleID: nil)!
            let newer = store.addText("newer", kind: .text, sourceBundleID: nil)!
            let cutoff = now.addingTimeInterval(-retention.maxAge)
            age(older.id, in: testDirectory, at: cutoff.addingTimeInterval(-1))
            age(boundary.id, in: testDirectory, at: cutoff)
            age(newer.id, in: testDirectory, at: cutoff.addingTimeInterval(1))
            store.load()
            precondition(store.retentionImpact(for: retention, at: now)?.itemCount == 1)
            store.maxAge = retention.maxAge
            precondition(store.enforceLimits(at: now))
            precondition(store.item(id: older.id) == nil)
            precondition(store.item(id: boundary.id) != nil && store.item(id: newer.id) != nil)
            precondition(store.enforceLimits(at: now), "Repeating cleanup is safe")
            await store.waitForRetentionCleanup()
        }
        let foreverDirectory = directory.appendingPathComponent("forever")
        let forever = store(foreverDirectory)
        let ancient = forever.addText("ancient", kind: .text, sourceBundleID: nil)!
        age(ancient.id, in: foreverDirectory, at: Date(timeIntervalSince1970: -1_000_000))
        forever.load()
        precondition(forever.item(id: ancient.id) != nil)
        for invalid in [-1.0, .nan, .infinity] {
            forever.maxAge = invalid
            precondition(!forever.enforceLimits(at: now))
            precondition(count(foreverDirectory, "SELECT COUNT(*) FROM items") == 1)
        }
        await forever.waitForRetentionCleanup()
        print("PASS: every finite policy, exact cutoff, idempotence, Forever, invalid-policy safety")
    }

    @MainActor
    static func fullHistoryPreviewAndRevision(in directory: URL) async {
        let store = store(directory)
        let stack = store.createStack(name: "Saved")!
        let oldImage = directory.appendingPathComponent("images/old.png")
        try! Data([1, 2, 3]).write(to: oldImage)
        let imageID = UUID()
        let now = Date()
        let old = now.addingTimeInterval(-31 * 86_400).timeIntervalSince1970
        execute(directory, """
            INSERT INTO items(id, kind, image_path, created_at, ocr_text, ocr_status, ocr_version)
            VALUES('\(imageID)', 'image', '\(oldImage.path)', \(old), 'oldimage needle', 'complete', 1);
            WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x + 1 FROM n WHERE x < 1005)
            INSERT INTO items(id, kind, text, created_at)
            SELECT printf('00000000-0000-0000-0000-%012d', x), 'text', 'oldtext needle', \(old) FROM n;
            """)
        store.assign(imageID, to: stack.id)
        for index in 0..<1000 {
            _ = store.addText("recent \(index)", kind: .text, sourceBundleID: nil)
        }
        store.load()
        precondition(store.items.count == 1000 && !store.items.contains { $0.id == imageID })
        let revision = store.revision
        let impact = store.retentionImpact(for: .day, at: now)
        precondition(impact == .init(itemCount: 1006, imageCount: 1, stackItemCount: 1))
        precondition(store.retentionImpact(for: .year, at: now)?.itemCount == 0)
        precondition(store.retentionImpact(for: .forever, at: now)?.itemCount == 0)
        precondition(store.revision == revision && FileManager.default.fileExists(atPath: oldImage.path),
                     "Preview is read-only across the entire database")
        store.maxAge = ClipboardRetention.day.maxAge
        precondition(store.enforceLimits(at: now))
        precondition(store.revision > revision, "Deleting only nonresident rows invalidates search")
        precondition(count(directory, "SELECT COUNT(*) FROM items") == 1000)
        precondition(count(directory, "SELECT COUNT(*) FROM stack_items") == 0)
        precondition(store.stackID(for: imageID) == nil && store.stacks == [stack])
        precondition(count(directory, "SELECT COUNT(*) FROM items_fts WHERE items_fts MATCH 'needle'") == 0)
        precondition(count(directory, "SELECT COUNT(*) FROM image_ocr_fts") == 0)
        await store.waitForRetentionCleanup()
        precondition(!FileManager.default.fileExists(atPath: oldImage.path))
        precondition(count(directory, "SELECT COUNT(*) FROM pending_blob_deletions") == 0)
        print("PASS: full-history preview, nonresident revision, Stack cleanup, text/OCR indexes, owned image deletion")
    }

    @MainActor
    static func rollbackAndRetry(in directory: URL) async {
        let store = store(directory)
        let now = Date()
        let stale = store.addText("rollback needle", kind: .text, sourceBundleID: nil)!
        let stack = store.createStack(name: "Saved")!
        store.assign(stale.id, to: stack.id)
        age(stale.id, in: directory, at: now.addingTimeInterval(-2 * 86_400))
        store.load()
        let undo = store.addText("undo", kind: .text, sourceBundleID: nil)!
        precondition(store.remove(undo))
        let imagePath = directory.appendingPathComponent("images/rollback.png")
        try! Data([1]).write(to: imagePath)
        let imageID = UUID()
        execute(directory, """
            INSERT INTO items(id, kind, image_path, created_at)
            VALUES('\(imageID)', 'image', '\(imagePath.path)', 0);
            CREATE TRIGGER fail_retention BEFORE DELETE ON items
            BEGIN SELECT RAISE(ABORT, 'injected failure'); END;
            """)
        // A failed prune must not suppress the next due capture's retry for an hour.
        precondition(store.enforceLimits(at: now.addingTimeInterval(-3_601)))
        store.maxAge = ClipboardRetention.day.maxAge
        let revision = store.revision
        precondition(!store.enforceLimits(at: now))
        precondition(store.item(id: stale.id) != nil && store.stackID(for: stale.id) == stack.id)
        precondition(count(directory, "SELECT COUNT(*) FROM stack_items") == 1)
        precondition(count(directory, "SELECT COUNT(*) FROM pending_blob_deletions") == 0)
        precondition(count(directory, "SELECT COUNT(*) FROM items_fts WHERE items_fts MATCH 'needle'") == 1)
        precondition(store.revision == revision && store.canUndoDeletion)
        precondition(FileManager.default.fileExists(atPath: imagePath.path))
        execute(directory, "DROP TRIGGER fail_retention")
        _ = store.addText("retry capture", kind: .text, sourceBundleID: nil)
        precondition(store.item(id: stale.id) == nil && store.stackID(for: stale.id) == nil)
        await store.waitForRetentionCleanup()
        precondition(!FileManager.default.fileExists(atPath: imagePath.path))
        precondition(store.undoLastDeletion()?.id == undo.id)
        print("PASS: rollback preserves rows, files, Stack state, FTS and undo; next capture retries")
    }

    @MainActor
    static func persistentRecovery(in directory: URL) async {
        var first: ClipboardStore? = ClipboardStore(directory: directory, removeImageFile: { _ in false })
        first!.setImageTextSearchEnabled(false)
        first!.maxAge = ClipboardRetention.forever.maxAge
        first!.load()
        let path = directory.appendingPathComponent("images/retry.png")
        try! Data([1]).write(to: path)
        execute(directory, "INSERT INTO items(id, kind, image_path, created_at) VALUES('\(UUID())', 'image', '\(path.path)', 0)")
        first!.maxAge = ClipboardRetention.day.maxAge
        precondition(first!.enforceLimits())
        await first!.waitForRetentionCleanup()
        precondition(count(directory, "SELECT COUNT(*) FROM items") == 0)
        precondition(count(directory, "SELECT COUNT(*) FROM pending_blob_deletions") == 1)
        precondition(FileManager.default.fileExists(atPath: path.path))
        first = nil
        let recovered = store(directory)
        await recovered.waitForRetentionCleanup()
        precondition(!FileManager.default.fileExists(atPath: path.path))
        precondition(count(directory, "SELECT COUNT(*) FROM pending_blob_deletions") == 0)
        execute(directory, "INSERT INTO pending_blob_deletions(path) VALUES('\(path.path)')")
        precondition(recovered.enforceLimits())
        await recovered.waitForRetentionCleanup()
        precondition(count(directory, "SELECT COUNT(*) FROM pending_blob_deletions") == 0,
                     "An already removed file completes an interrupted job")
        print("PASS: failed file deletion, persisted restart recovery, already missing file")
    }

    @MainActor
    static func pathSafety(in directory: URL) async {
        let store = store(directory)
        let outside = directory.appendingPathComponent("outside.png")
        let link = directory.appendingPathComponent("images/link.png")
        let folder = directory.appendingPathComponent("images/folder.png")
        let shared = directory.appendingPathComponent("images/shared.png")
        try! Data([1]).write(to: outside)
        try! Data([2]).write(to: shared)
        try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for path in [outside.path, link.path, folder.path, directory.appendingPathComponent("images/../outside.png").path, shared.path] {
            execute(directory, "INSERT INTO items(id, kind, image_path, created_at) VALUES('\(UUID())', 'image', '\(path)', 0)")
        }
        let liveID = UUID()
        execute(directory, "INSERT INTO items(id, kind, image_path, created_at) VALUES('\(liveID)', 'image', '\(shared.path)', \(Date().timeIntervalSince1970))")
        store.maxAge = ClipboardRetention.day.maxAge
        precondition(store.enforceLimits())
        await store.waitForRetentionCleanup()
        precondition(FileManager.default.fileExists(atPath: outside.path))
        precondition(FileManager.default.fileExists(atPath: link.path))
        precondition(FileManager.default.fileExists(atPath: folder.path))
        precondition(FileManager.default.fileExists(atPath: shared.path), "A live row still owns this file")
        precondition(count(directory, "SELECT COUNT(*) FROM pending_blob_deletions") == 1)
        age(liveID, in: directory, at: Date(timeIntervalSince1970: 0))
        precondition(store.enforceLimits())
        await store.waitForRetentionCleanup()
        precondition(!FileManager.default.fileExists(atPath: shared.path))
        precondition(count(directory, "SELECT COUNT(*) FROM pending_blob_deletions") == 0)
        print("PASS: outside paths, traversal, symlinks, directories and shared live blobs are protected")
    }

    @MainActor
    static func failedJobDoesNotBlockLaterBatches(in directory: URL) async {
        let store = ClipboardStore(directory: directory, removeImageFile: { url in
            if url.lastPathComponent == "0.png" { return false }
            do { try FileManager.default.removeItem(at: url); return true } catch { return false }
        })
        store.setImageTextSearchEnabled(false)
        store.maxAge = ClipboardRetention.forever.maxAge
        // More than one worker batch, with a permanently failing first job.
        for index in 0..<300 {
            let path = directory.appendingPathComponent("images/\(index).png")
            try! Data([1]).write(to: path)
            execute(directory, "INSERT INTO pending_blob_deletions(path) VALUES('\(path.path)')")
        }
        store.load()
        await store.waitForRetentionCleanup()
        precondition(count(directory, "SELECT COUNT(*) FROM pending_blob_deletions") == 1)
        precondition(FileManager.default.fileExists(atPath: directory.appendingPathComponent("images/0.png").path))
        precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("images/299.png").path))
        print("PASS: one failed file never starves later cleanup batches")
    }

    @MainActor
    static func confirmationCoverage(in directory: URL) async {
        let store = store(directory)
        let stack = store.createStack(name: "Saved")!
        let id = UUID()
        let age = Date().addingTimeInterval(-2 * 86_400).timeIntervalSince1970
        execute(directory, "INSERT INTO items(id, kind, created_at) VALUES('\(id)', 'image', \(age))")
        store.assign(id, to: stack.id)
        let actual = ClipboardStore.RetentionImpact(itemCount: 1, imageCount: 1, stackItemCount: 1)
        precondition(store.changeRetention(to: .day) == .confirmationRequired(actual))
        for insufficient in [
            ClipboardStore.RetentionImpact(itemCount: 0, imageCount: 1, stackItemCount: 1),
            ClipboardStore.RetentionImpact(itemCount: 2, imageCount: 0, stackItemCount: 1),
            ClipboardStore.RetentionImpact(itemCount: 2, imageCount: 1, stackItemCount: 0),
        ] {
            precondition(store.changeRetention(to: .day, confirming: insufficient) == .confirmationRequired(actual))
            precondition(store.maxAge == ClipboardRetention.forever.maxAge && store.item(id: id) != nil)
        }
        precondition(store.changeRetention(to: .day, confirming: actual) == .applied)
        precondition(store.item(id: id) == nil && store.stackID(for: id) == nil)
        await store.waitForRetentionCleanup()
        print("PASS: confirmation independently covers total entries, images and Stack entries")
    }

    @MainActor
    static func periodicCleanup(in directory: URL) async {
        let store = store(directory, interval: 0.05)
        let stale = store.addText("periodic", kind: .text, sourceBundleID: nil)!
        age(stale.id, in: directory, at: Date(timeIntervalSince1970: 0))
        store.load()
        store.maxAge = ClipboardRetention.day.maxAge
        let deadline = Date().addingTimeInterval(3)
        while store.item(id: stale.id) != nil && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        precondition(store.item(id: stale.id) == nil, "No new captures are required for expiration")
        await store.waitForRetentionCleanup()
        print("PASS: periodic expiration without new captures")
    }

    @MainActor
    static func unavailableDatabase(in directory: URL) async {
        try! Data([1]).write(to: directory)
        let store = ClipboardStore(directory: directory)
        precondition(store.retentionImpact(for: .day) == nil)
        precondition(store.retentionImpact(for: .forever) == nil)
        precondition(!store.enforceLimits())
        await store.waitForRetentionCleanup()
        print("PASS: unavailable database never reports a successful empty preview or cleanup")
    }

    @MainActor
    static func performanceProbe(in directory: URL) async {
        let store = store(directory)
        execute(directory, """
            BEGIN;
            WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x + 1 FROM n WHERE x < 50000)
            INSERT INTO items(id, kind, text, created_at)
            SELECT printf('00000000-0000-0000-0000-%012d', x), 'text',
                   'historical clipboard entry for retention performance', 0 FROM n;
            COMMIT;
            """)
        store.load()
        let previewStart = Date()
        precondition(store.retentionImpact(for: .day)?.itemCount == 50000)
        let previewDuration = Date().timeIntervalSince(previewStart)
        store.maxAge = ClipboardRetention.day.maxAge
        let deletionStart = Date()
        precondition(store.enforceLimits())
        let deletionDuration = Date().timeIntervalSince(deletionStart)
        precondition(count(directory, "SELECT COUNT(*) FROM items") == 0)
        await store.waitForRetentionCleanup()
        print(String(format: "PROBE: 50000 text rows, preview %.3fs, main-actor deletion %.3fs", previewDuration, deletionDuration))
    }

    @MainActor
    static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kit-retention-\(UUID())")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        if CommandLine.arguments.contains("--benchmark") {
            await performanceProbe(in: root.appendingPathComponent("performance"))
            return
        }
        await policyBoundaries(in: root.appendingPathComponent("policies"))
        await fullHistoryPreviewAndRevision(in: root.appendingPathComponent("full-history"))
        await rollbackAndRetry(in: root.appendingPathComponent("rollback"))
        await persistentRecovery(in: root.appendingPathComponent("recovery"))
        await pathSafety(in: root.appendingPathComponent("paths"))
        await failedJobDoesNotBlockLaterBatches(in: root.appendingPathComponent("batches"))
        await confirmationCoverage(in: root.appendingPathComponent("consent"))
        await periodicCleanup(in: root.appendingPathComponent("periodic"))
        await unavailableDatabase(in: root.appendingPathComponent("unavailable"))
    }
}
