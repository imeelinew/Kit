import Foundation
import SQLite3
@testable import Kit

@MainActor
enum ClipboardRetentionSettingsTests {
    private static func execute(_ directory: URL, _ sql: String) {
        var db: OpaquePointer?
        precondition(sqlite3_open(directory.appendingPathComponent("clipboard.sqlite3").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    static func run() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kit-retention-settings-\(UUID())")
        let suite = "com.eli.Kit.tests.retention.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(ClipboardRetention.year.rawValue, forKey: "clipboardRetentionDays")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        await deferredHistoryTests(in: directory.appendingPathComponent("deferred-history"))
        let settings = AppSettings(defaults: defaults)
        let store = ClipboardStore(directory: directory)
        store.maxAge = settings.clipboardRetention.maxAge
        store.load()
        let original = store.addText("saved for a year", kind: .text, sourceBundleID: nil)!
        execute(directory, "UPDATE items SET created_at = \(Date().addingTimeInterval(-2 * 86_400).timeIntervalSince1970) WHERE id = '\(original.id)'")
        store.load()
        let one = ClipboardStore.RetentionImpact(itemCount: 1, imageCount: 0, stackItemCount: 0)
        precondition(settings.changeClipboardRetention(to: .day, in: store) == .confirmationRequired(one), "Deleting history needs consent")
        precondition(store.item(id: original.id) != nil, "Cancelling a shorter policy leaves history intact")

        let newerExpired = store.addText("expired during confirmation", kind: .text, sourceBundleID: nil)!
        execute(directory, "UPDATE items SET created_at = \(Date().addingTimeInterval(-2 * 86_400).timeIntervalSince1970) WHERE id = '\(newerExpired.id)'")
        store.load()
        let two = ClipboardStore.RetentionImpact(itemCount: 2, imageCount: 0, stackItemCount: 0)
        precondition(settings.changeClipboardRetention(to: .day, in: store, confirming: one) == .confirmationRequired(two), "Growing counts need renewed consent")
        precondition(store.item(id: original.id) != nil && store.item(id: newerExpired.id) != nil)
        precondition(settings.changeClipboardRetention(to: .day, in: store, confirming: two) == .applied)
        precondition(store.item(id: original.id) == nil && store.item(id: newerExpired.id) == nil)
        await store.waitForRetentionCleanup()
        precondition(AppSettings(defaults: defaults).clipboardRetention == .day, "Only a confirmed change persists")
        precondition(settings.changeClipboardRetention(to: .year, in: store) == .applied)

        let failure = store.addText("preserved on database failure", kind: .text, sourceBundleID: nil)!
        execute(directory, """
            UPDATE items SET created_at = \(Date().addingTimeInterval(-2 * 86_400).timeIntervalSince1970) WHERE id = '\(failure.id)';
            CREATE TRIGGER fail_retention_setting BEFORE DELETE ON items BEGIN SELECT RAISE(ABORT, 'injected failure'); END;
            """)
        precondition(settings.changeClipboardRetention(to: .day, in: store, confirming: one) == .failed)
        precondition(settings.clipboardRetention == .year && store.maxAge == ClipboardRetention.year.maxAge && store.item(id: failure.id) != nil,
                     "A failed change rolls back the policy and preserves history")
        execute(directory, "DROP TRIGGER fail_retention_setting")
        print("PASS: destructive-change consent, cancellation, growing-count reconfirmation, persistence and rollback on failure")
    }

    private static func deferredHistoryTests(in directory: URL) async {
        let store = ClipboardStore(directory: directory)
        let core = AppCore(clipboardStore: store)
        let older = store.addText("earlier copy", kind: .text, sourceBundleID: "source")!
        let newer = store.addText("later copy", kind: .text, sourceBundleID: "source")!
        let vm = core.palette
        await vm.prepare()
        precondition(vm.results.map(\.id) == [newer.id, older.id])
        precondition(store.recordHistoryAction(id: older.id, deferPublication: true))
        precondition(store.updateKind(id: newer.id, to: .code))
        await vm.prepare()
        precondition(vm.results.map(\.id) == [newer.id, older.id], "Background metadata must not reorder a keep-open paste")
        store.publishDeferredHistoryUpdates()
        await vm.prepare()
        precondition(vm.results.map(\.id) == [older.id, newer.id])
        precondition(vm.results.first?.copyCount == 2)
        print("PASS: deferred history stays stable through background revisions and publishes on close")
    }
}
