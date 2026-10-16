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
            let subdirectory = directory.appendingPathComponent(String(retention.rawValue))
            let store = store(subdirectory)
            let older = store.addText("older", kind: .text, sourceBundleID: nil)!
            let boundary = store.addText("boundary", kind: .text, sourceBundleID: nil)!
            let cutoff = now.addingTimeInterval(-retention.maxAge)
            age(older.id, in: subdirectory, at: cutoff.addingTimeInterval(-1))
            age(boundary.id, in: subdirectory, at: cutoff)
            store.load()
            store.maxAge = retention.maxAge
            precondition(store.enforceLimits(at: now))
            precondition(store.item(id: older.id) == nil && store.item(id: boundary.id) != nil)
        }
        let foreverDirectory = directory.appendingPathComponent("forever")
        let forever = store(foreverDirectory)
        let ancient = forever.addText("ancient", kind: .text, sourceBundleID: nil)!
        age(ancient.id, in: foreverDirectory, at: Date(timeIntervalSince1970: -1_000_000))
        forever.load()
        precondition(forever.item(id: ancient.id) != nil)
        for maxAge in [-1.0, .nan, .infinity] {
            forever.maxAge = maxAge
            precondition(!forever.enforceLimits(at: now) && forever.item(id: ancient.id) != nil)
        }
        print("PASS: rows strictly older than each finite policy cutoff expire while the exact-cutoff row and Forever rows survive, and invalid policies delete nothing")
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
        let imagePath = directory.appendingPathComponent("images/rollback.png")
        try! Data([1]).write(to: imagePath)
        execute(directory, """
            INSERT INTO items(id, kind, image_path, created_at) VALUES('\(UUID())', 'image', '\(imagePath.path)', 0);
            CREATE TRIGGER fail_retention BEFORE DELETE ON items
            BEGIN SELECT RAISE(ABORT, 'injected failure'); END;
            """)
        precondition(store.enforceLimits(at: now.addingTimeInterval(-3_601)))
        store.maxAge = ClipboardRetention.day.maxAge
        let revision = store.revision
        precondition(!store.enforceLimits(at: now))
        precondition(store.item(id: stale.id) != nil && store.stackID(for: stale.id) == stack.id)
        precondition(store.revision == revision)
        precondition(FileManager.default.fileExists(atPath: imagePath.path))
        execute(directory, "DROP TRIGGER fail_retention")
        _ = store.addText("retry capture", kind: .text, sourceBundleID: nil)
        precondition(store.item(id: stale.id) == nil && store.stackID(for: stale.id) == nil)
        await store.waitForRetentionCleanup()
        precondition(!FileManager.default.fileExists(atPath: imagePath.path))
        print("PASS: a failed prune rolls back rows, Stack state, revision and files, and the next capture retries")
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
        precondition(FileManager.default.fileExists(atPath: path.path))
        first = nil
        let recovered = store(directory)
        await recovered.waitForRetentionCleanup()
        precondition(!FileManager.default.fileExists(atPath: path.path))
        print("PASS: a failed file deletion is persisted and retried after a restart")
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
        precondition([outside, link, folder, shared].allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
                     "Outside paths, traversal, symlinks, directories and a shared live blob are protected")
        age(liveID, in: directory, at: Date(timeIntervalSince1970: 0))
        precondition(store.enforceLimits())
        await store.waitForRetentionCleanup()
        precondition(!FileManager.default.fileExists(atPath: shared.path))
        print("PASS: outside paths, traversal, symlinks and directories are never deleted, and a shared blob survives until its last row expires")
    }

    @MainActor
    static func confirmationCoverage(in directory: URL) async {
        let store = store(directory)
        let stack = store.createStack(name: "Saved")!
        let id = UUID()
        let created = Date().addingTimeInterval(-2 * 86_400).timeIntervalSince1970
        execute(directory, "INSERT INTO items(id, kind, created_at) VALUES('\(id)', 'image', \(created))")
        store.assign(id, to: stack.id)
        let actual = ClipboardStore.RetentionImpact(itemCount: 1, imageCount: 1, stackItemCount: 1)
        precondition(store.changeRetention(to: .day) == .confirmationRequired(actual))
        precondition(store.changeRetention(to: .day, confirming: ClipboardStore.RetentionImpact(itemCount: 2, imageCount: 1, stackItemCount: 0)) == .confirmationRequired(actual))
        precondition(store.maxAge == ClipboardRetention.forever.maxAge && store.item(id: id) != nil)
        let revision = store.revision
        precondition(store.changeRetention(to: .day, confirming: actual) == .applied)
        precondition(store.item(id: id) == nil && store.stackID(for: id) == nil && store.revision > revision)
        print("PASS: a retention change needs confirmation covering entries, images and Stack entries, nothing is deleted until the exact impact is confirmed, and the applied deletion invalidates search")
    }

    @MainActor
    static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kit-retention-\(UUID())")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        await policyBoundaries(in: root.appendingPathComponent("policies"))
        await rollbackAndRetry(in: root.appendingPathComponent("rollback"))
        await persistentRecovery(in: root.appendingPathComponent("recovery"))
        await pathSafety(in: root.appendingPathComponent("paths"))
        await confirmationCoverage(in: root.appendingPathComponent("consent"))
    }
}
