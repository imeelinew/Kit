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
        precondition(settings.updateHistoryAfterAction, "History updates are enabled by default")
        settings.updateHistoryAfterAction = false
        precondition(!AppSettings(defaults: defaults).updateHistoryAfterAction, "The disabled preference survives restart")
        settings.updateHistoryAfterAction = true
        precondition(AppSettings(defaults: defaults).updateHistoryAfterAction, "The enabled preference survives restart")
        let store = ClipboardStore(directory: directory)
        store.setImageTextSearchEnabled(false)
        store.maxAge = settings.clipboardRetention.maxAge
        store.load()
        let original = store.addText("saved for a year", kind: .text, sourceBundleID: nil)!
        execute(directory, "UPDATE items SET created_at = \(Date().addingTimeInterval(-2 * 86_400).timeIntervalSince1970) WHERE id = '\(original.id)'")
        store.load()
        let originalRevision = store.revision
        let one = ClipboardStore.RetentionImpact(itemCount: 1, imageCount: 0, stackItemCount: 0)
        precondition(settings.changeClipboardRetention(to: .day, in: store) == .confirmationRequired(one))
        precondition(settings.clipboardRetention == .year && store.maxAge == ClipboardRetention.year.maxAge)
        precondition(defaults.integer(forKey: "clipboardRetentionDays") == 365)
        precondition(store.item(id: original.id) != nil && store.revision == originalRevision,
                     "Requesting or cancelling a shorter policy preserves both history and persisted settings")

        let newerExpired = store.addText("expired during confirmation", kind: .text, sourceBundleID: nil)!
        execute(directory, "UPDATE items SET created_at = \(Date().addingTimeInterval(-2 * 86_400).timeIntervalSince1970) WHERE id = '\(newerExpired.id)'")
        let two = ClipboardStore.RetentionImpact(itemCount: 2, imageCount: 0, stackItemCount: 0)
        precondition(settings.changeClipboardRetention(to: .day, in: store, confirming: one) == .confirmationRequired(two))
        precondition(settings.clipboardRetention == .year && store.maxAge == ClipboardRetention.year.maxAge)
        precondition(defaults.integer(forKey: "clipboardRetentionDays") == 365)
        precondition(store.item(id: original.id) != nil && store.item(id: newerExpired.id) != nil,
                     "Growing deletion counts need renewed consent before any deletion")
        store.load()
        precondition(settings.changeClipboardRetention(to: .day, in: store, confirming: two) == .applied)
        precondition(settings.clipboardRetention == .day && store.maxAge == ClipboardRetention.day.maxAge)
        precondition(defaults.integer(forKey: "clipboardRetentionDays") == 1)
        precondition(store.item(id: original.id) == nil && store.item(id: newerExpired.id) == nil)
        await store.waitForRetentionCleanup()
        precondition(AppSettings(defaults: defaults).clipboardRetention == .day,
                     "Only a successful confirmed change survives restart")

        precondition(settings.changeClipboardRetention(to: .forever, in: store) == .applied,
                     "Extending to Forever needs no confirmation")
        precondition(settings.changeClipboardRetention(to: .year, in: store) == .applied,
                     "An empty history applies a shorter policy without confirmation")
        precondition(defaults.integer(forKey: "clipboardRetentionDays") == 365)
        let recent = store.addText("recent history stays", kind: .text, sourceBundleID: nil)!
        precondition(settings.changeClipboardRetention(to: .month, in: store) == .applied,
                     "Nonempty history also skips confirmation when no rows expire")
        precondition(defaults.integer(forKey: "clipboardRetentionDays") == 30)
        precondition(store.item(id: recent.id) != nil)
        precondition(settings.changeClipboardRetention(to: .year, in: store) == .applied)

        let failure = store.addText("preserved on database failure", kind: .text, sourceBundleID: nil)!
        execute(directory, """
            UPDATE items SET created_at = \(Date().addingTimeInterval(-2 * 86_400).timeIntervalSince1970)
            WHERE id = '\(failure.id)';
            CREATE TRIGGER fail_retention_setting BEFORE DELETE ON items
            BEGIN SELECT RAISE(ABORT, 'injected failure'); END;
            """)
        store.load()
        precondition(settings.changeClipboardRetention(to: .day, in: store) == .confirmationRequired(one))
        precondition(settings.changeClipboardRetention(to: .day, in: store, confirming: one) == .failed)
        precondition(settings.clipboardRetention == .year && store.maxAge == ClipboardRetention.year.maxAge)
        precondition(defaults.integer(forKey: "clipboardRetentionDays") == 365)
        precondition(store.item(id: failure.id) != nil && AppSettings(defaults: defaults).clipboardRetention == .year)
        execute(directory, "DROP TRIGGER fail_retention_setting")
        await store.waitForRetentionCleanup()
        print("PASS: destructive-change consent, cancellation, growing-count reconfirmation, persistence, Forever, zero-deletion changes without confirmation, failure rollback and restart")
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
        precondition(vm.results.map(\.id) == [newer.id, older.id],
                     "Background metadata must not reorder a keep-open paste")
        store.publishDeferredHistoryUpdates()
        await vm.prepare()
        precondition(vm.results.map(\.id) == [older.id, newer.id])
        precondition(vm.results.first?.copyCount == 2)
        core.settings.updateHistoryAfterAction = false
        precondition(!store.updateHistoryAfterAction, "Changing settings immediately reaches the store")
        core.settings.updateHistoryAfterAction = true
        precondition(store.updateHistoryAfterAction)
        print("PASS: deferred history stays stable through background revisions, publishes on close, live setting updates")
    }
}
