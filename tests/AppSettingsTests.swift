import AppKit
import Foundation
import SQLite3
@testable import Kit

enum AppSettingsTests {
    private enum DefaultsKey {
        static let retention = "clipboardRetentionDays"
        static let updateHistoryAfterAction = "updateHistoryAfterAction"
        static let disabledApps = "clipboardDisabledApps"
        static let paused = "clipboardPaused"
        static let pauseUntil = "clipboardPauseUntil"
        static let switchToEnglishInputOnOpen = "switchToEnglishInputOnOpen"
        static let renderMarkdown = "renderMarkdown"
        static let imageTextSearchEnabled = "imageTextSearchEnabled"
        static let language = "appLanguage"
        static let appearance = "appAppearance"
        static let pinnedImageSize = "pinnedImageSize"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let animateMenuBarIconOnCopy = "animateMenuBarIconOnCopy"
        static let soundEffectsEnabled = "soundEffectsEnabled"
        static let copySoundEffect = "copySoundEffect"
        static let hapticFeedbackEnabled = "hapticFeedbackEnabled"
    }

    private static let defaultDisabledApps = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
    ]

    @MainActor
    static func run() async throws {
        try await defaultsAndInvalidValues()
        try await explicitFalseBooleansRoundTrip()
        try await legacyCopySoundValues()
        try await disabledApplicationsPersistence()
        try await localization()
        try await clipboardPause()
        try await appearance()
        try await retentionCommit()
    }

    @MainActor
    private static func defaultsAndInvalidValues() async throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            try TestSupport.expect(settings.clipboardRetention == .threeMonths,
                                   "Missing retention falls back to three months")
            try TestSupport.expect(settings.updateHistoryAfterAction,
                                   "Missing history update preference defaults to true")
            try TestSupport.expect(settings.clipboardDisabledApps == defaultDisabledApps,
                                   "Missing disabled apps uses the protected defaults")
            try TestSupport.expect(settings.switchToEnglishInputOnOpen == false,
                                   "Missing input switch preference defaults to false")
            try TestSupport.expect(settings.renderMarkdown,
                                   "Missing Markdown preference defaults to true")
            try TestSupport.expect(settings.imageTextSearchEnabled,
                                   "Missing image text search preference defaults to true")
            try TestSupport.expect(settings.language == .system,
                                   "Missing language defaults to system")
            try TestSupport.expect(settings.appearance == .system,
                                   "Missing appearance defaults to system")
            try TestSupport.expect(settings.pinnedImageSize == .medium,
                                   "Missing pinned image size defaults to medium")
            try TestSupport.expect(settings.showMenuBarIcon,
                                   "Missing menu bar preference defaults to true")
            try TestSupport.expect(settings.animateMenuBarIconOnCopy,
                                   "Missing menu bar animation preference defaults to true")
            try TestSupport.expect(settings.soundEffectsEnabled,
                                   "Missing sound preference defaults to true")
            try TestSupport.expect(settings.copySoundEffect == .woodTap,
                                   "Missing sound effect defaults to wood tap")
            try TestSupport.expect(settings.hapticFeedbackEnabled,
                                   "Missing haptic preference defaults to true")
            try TestSupport.expect(settings.launchAtLogin == LaunchAtLogin.isEnabled,
                                   "Launch at login reflects system state")
        }

        try withDefaults { defaults in
            defaults.set(999, forKey: DefaultsKey.retention)
            defaults.set("invalid-language", forKey: DefaultsKey.language)
            defaults.set("invalid-appearance", forKey: DefaultsKey.appearance)
            defaults.set("invalid-size", forKey: DefaultsKey.pinnedImageSize)
            defaults.set(999, forKey: DefaultsKey.copySoundEffect)
            for key in defaultTrueBooleanKeys {
                defaults.set("invalid-boolean", forKey: key)
            }
            defaults.set("invalid-boolean", forKey: DefaultsKey.switchToEnglishInputOnOpen)

            let settings = AppSettings(defaults: defaults)
            try TestSupport.expect(settings.clipboardRetention == .threeMonths,
                                   "Invalid retention falls back to three months")
            try TestSupport.expect(settings.language == .system,
                                   "Invalid language falls back to system")
            try TestSupport.expect(settings.appearance == .system,
                                   "Invalid appearance falls back to system")
            try TestSupport.expect(settings.pinnedImageSize == .medium,
                                   "Invalid pinned image size falls back to medium")
            try TestSupport.expect(settings.copySoundEffect == .woodTap,
                                   "Invalid sound effect falls back to wood tap")
            try TestSupport.expect(!settings.switchToEnglishInputOnOpen,
                                   "Invalid false-default boolean falls back to false")
            for (key, value) in defaultTrueBooleanValues(settings) {
                try TestSupport.expect(value,
                                       "Invalid \(key) boolean falls back to true")
            }
        }
    }

    @MainActor
    private static func explicitFalseBooleansRoundTrip() async throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.updateHistoryAfterAction = false
            settings.renderMarkdown = false
            settings.imageTextSearchEnabled = false
            settings.showMenuBarIcon = false
            settings.animateMenuBarIconOnCopy = false
            settings.soundEffectsEnabled = false
            settings.hapticFeedbackEnabled = false
            settings.switchToEnglishInputOnOpen = true

            let reopened = AppSettings(defaults: defaults)
            try TestSupport.expect(!reopened.updateHistoryAfterAction,
                                   "Explicit false history update preference round-trips")
            try TestSupport.expect(!reopened.renderMarkdown,
                                   "Explicit false Markdown preference round-trips")
            try TestSupport.expect(!reopened.imageTextSearchEnabled,
                                   "Explicit false image text search preference round-trips")
            try TestSupport.expect(!reopened.showMenuBarIcon,
                                   "Explicit false menu bar preference round-trips")
            try TestSupport.expect(!reopened.animateMenuBarIconOnCopy,
                                   "Explicit false menu bar animation preference round-trips")
            try TestSupport.expect(!reopened.soundEffectsEnabled,
                                   "Explicit false sound preference round-trips")
            try TestSupport.expect(!reopened.hapticFeedbackEnabled,
                                   "Explicit false haptic preference round-trips")
            try TestSupport.expect(reopened.switchToEnglishInputOnOpen,
                                   "Explicit true input switch preference round-trips")
        }
    }

    @MainActor
    private static func legacyCopySoundValues() async throws {
        try withDefaults { defaults in
            let mappings: [(Int, CopySoundEffect)] = [
                (5, .woodTap),
                (6, .doubleTap),
                (1, .crispPing),
                (3, .lowKnock),
            ]
            for (rawValue, expected) in mappings {
                defaults.set(rawValue, forKey: DefaultsKey.copySoundEffect)
                let settings = AppSettings(defaults: defaults)
                try TestSupport.expect(settings.copySoundEffect == expected,
                                       "Copy sound raw value \(rawValue) maps to \(expected)")
                try TestSupport.expect(settings.copySoundEffect.rawValue == rawValue,
                                       "Copy sound raw value \(rawValue) remains stable")
            }
        }
    }

    @MainActor
    private static func disabledApplicationsPersistence() async throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            try TestSupport.expect(settings.clipboardDisabledApps == defaultDisabledApps,
                                   "Absent disabled app value uses default apps")
        }

        try withDefaults { defaults in
            defaults.set([String](), forKey: DefaultsKey.disabledApps)
            let settings = AppSettings(defaults: defaults)
            let reopened = AppSettings(defaults: defaults)
            try TestSupport.expect(settings.clipboardDisabledApps.isEmpty,
                                   "Persisted empty disabled apps remains empty")
            try TestSupport.expect(reopened.clipboardDisabledApps.isEmpty,
                                   "Persisted empty disabled apps does not use defaults")
        }

        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.clipboardDisabledApps = ["com.example.Editor"]
            let reopened = AppSettings(defaults: defaults)
            try TestSupport.expect(reopened.clipboardDisabledApps == ["com.example.Editor"],
                                   "Disabled app changes round-trip")
        }
    }

    @MainActor
    private static func localization() async throws {
        let english = AppLanguage.english.locale
        let chinese = AppLanguage.simplifiedChinese.locale
        try TestSupport.expect(AppLocalization.string("Dark", locale: english) == "Dark",
                               "English appearance translation comes from the English resource")
        try TestSupport.expect(AppLocalization.string("Dark", locale: chinese) == "深色",
                               "Chinese appearance translation comes from the Chinese resource")
        try TestSupport.expect(AppLocalization.string("3 Months", locale: chinese) == "3 个月",
                               "Chinese retention translation comes from the Chinese resource")
        try TestSupport.expect(CopySoundEffect.crispPing.title(locale: chinese) == "清脆短叮",
                               "Chinese sound title uses its localized resource")
        let missingKey = "Missing AppSettingsTests localization key"
        try TestSupport.expect(AppLocalization.string(missingKey, locale: english) == missingKey,
                               "Missing English key falls back to the key")
        try TestSupport.expect(AppLocalization.string(
            missingKey, locale: Locale(identifier: "unsupported")) == missingKey,
                               "Unsupported locale falls back without losing the key")
    }

    @MainActor
    private static func clipboardPause() async throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            let initial = settings.savedClipboardPause
            try TestSupport.expect(!initial.isPaused && initial.until == nil,
                                   "Clipboard pause defaults to inactive")

            let until = Date(timeIntervalSince1970: 2_000_000_000)
            settings.saveClipboardPause(until: until)
            let timed = AppSettings(defaults: defaults).savedClipboardPause
            try TestSupport.expect(timed.isPaused,
                                   "Timed pause persists as paused")
            try TestSupport.expect(timed.until == until,
                                   "Timed pause persists its fixed end date")

            settings.saveClipboardPause(until: nil)
            let indefinite = AppSettings(defaults: defaults).savedClipboardPause
            try TestSupport.expect(indefinite.isPaused,
                                   "Indefinite pause persists as paused")
            try TestSupport.expect(indefinite.until == nil,
                                   "Indefinite pause removes a prior end date")
            try TestSupport.expect(defaults.object(forKey: DefaultsKey.pauseUntil) == nil,
                                   "Indefinite pause removes the stored date")

            settings.clearClipboardPause()
            let cleared = AppSettings(defaults: defaults).savedClipboardPause
            try TestSupport.expect(!cleared.isPaused && cleared.until == nil,
                                   "Clearing pause removes both persisted values")
            try TestSupport.expect(defaults.object(forKey: DefaultsKey.paused) == nil,
                                   "Clearing pause removes the paused flag")
            try TestSupport.expect(defaults.object(forKey: DefaultsKey.pauseUntil) == nil,
                                   "Clearing pause leaves no end date")
        }
    }

    @MainActor
    private static func appearance() async throws {
        _ = NSApplication.shared
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }

        try withDefaults { defaults in
            defaults.set("invalid-appearance", forKey: DefaultsKey.appearance)
            let settings = AppSettings(defaults: defaults)
            try TestSupport.expect(settings.appearance == .system,
                                   "Invalid appearance value falls back before applying")

            settings.appearance = .dark
            try TestSupport.expect(NSApp.appearance?.name == .darkAqua,
                                   "Dark appearance is applied")
            try TestSupport.expect(AppSettings(defaults: defaults).appearance == .dark,
                                   "Applied dark appearance persists")

            settings.appearance = .light
            try TestSupport.expect(NSApp.appearance?.name == .aqua,
                                   "Light appearance is applied")
            settings.appearance = .system
            try TestSupport.expect(NSApp.appearance == nil,
                                   "System appearance removes an explicit app appearance")
        }
    }

    @MainActor
    private static func retentionCommit() async throws {
        try withDefaults { defaults in
            defaults.set(ClipboardRetention.year.rawValue, forKey: DefaultsKey.retention)
            try withTemporaryDirectory { directory in
                let store = ClipboardStore(directory: directory, maintenanceInterval: 86_400)
                store.setImageTextSearchEnabled(false)
                store.maxAge = ClipboardRetention.forever.maxAge
                store.load()

                let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)
                let expiredAt = fixedNow.addingTimeInterval(-31 * 86_400)
                let boundaryAt = fixedNow.addingTimeInterval(-30 * 86_400)
                let insertedExpired = store.addText(
                    "expired", kind: .text, sourceBundleID: nil)
                let insertedBoundary = store.addText(
                    "boundary", kind: .text, sourceBundleID: nil)
                try TestSupport.expect(insertedExpired != nil,
                                       "Expired fixture is inserted")
                try TestSupport.expect(insertedBoundary != nil,
                                       "Boundary fixture is inserted")
                guard let expiredID = insertedExpired?.id,
                      let boundaryID = insertedBoundary?.id
                else {
                    throw TestError("Retention fixture identifiers were unavailable")
                }
                try setCreationTimes(
                    [expiredAt, boundaryAt],
                    in: directory)
                store.load()
                store.maxAge = ClipboardRetention.year.maxAge

                try TestSupport.expect(store.item(id: expiredID) != nil
                                       && store.item(id: boundaryID) != nil,
                                       "Both retention fixtures survive setup")

                let settings = AppSettings(defaults: defaults)
                let first = settings.changeClipboardRetention(
                    to: .month, in: store, at: fixedNow)
                guard case .confirmationRequired(let impact) = first else {
                    throw TestError("Retention shortening should require confirmation")
                }
                let expectedImpact = ClipboardStore.RetentionImpact(
                    itemCount: 1, imageCount: 0, stackItemCount: 0)
                try TestSupport.expect(impact == expectedImpact,
                                       "Retention confirmation reports the expired fixture")
                try TestSupport.expect(settings.clipboardRetention == .year,
                                       "Unconfirmed retention change leaves settings at year")
                try TestSupport.expect(
                    defaults.integer(forKey: DefaultsKey.retention) ==
                        ClipboardRetention.year.rawValue,
                    "Unconfirmed retention change leaves defaults at year")
                try TestSupport.expect(store.maxAge == ClipboardRetention.year.maxAge,
                                       "Unconfirmed retention change restores store policy")
                try TestSupport.expect(store.item(id: expiredID) != nil,
                                       "Unconfirmed retention change keeps expired history")

                let mismatch = settings.changeClipboardRetention(
                    to: .month,
                    in: store,
                    confirming: ClipboardStore.RetentionImpact(
                        itemCount: 0, imageCount: 0, stackItemCount: 0),
                    at: fixedNow)
                guard case .confirmationRequired(let mismatchImpact) = mismatch else {
                    throw TestError("A non-covering confirmation should be rejected")
                }
                try TestSupport.expect(mismatchImpact == expectedImpact,
                                       "Rejected confirmation receives the current impact")
                try TestSupport.expect(settings.clipboardRetention == .year,
                                       "Rejected confirmation does not change settings")
                try TestSupport.expect(
                    defaults.integer(forKey: DefaultsKey.retention) ==
                        ClipboardRetention.year.rawValue,
                    "Rejected confirmation does not change defaults")

                let applied = settings.changeClipboardRetention(
                    to: .month, in: store, confirming: impact, at: fixedNow)
                try TestSupport.expect(applied == .applied,
                                       "Exact confirmation applies retention")
                try TestSupport.expect(settings.clipboardRetention == .month,
                                       "Applied retention updates settings")
                try TestSupport.expect(
                    defaults.integer(forKey: DefaultsKey.retention) ==
                        ClipboardRetention.month.rawValue,
                    "Applied retention updates defaults")
                try TestSupport.expect(store.maxAge == ClipboardRetention.month.maxAge,
                                       "Applied retention updates store policy")
                try TestSupport.expect(store.item(id: expiredID) == nil,
                                       "Applied retention deletes history before the cutoff")
                try TestSupport.expect(store.item(id: boundaryID) != nil,
                                       "Applied retention keeps history at the exact cutoff")
                try TestSupport.expect(AppSettings(defaults: defaults).clipboardRetention == .month,
                                       "Applied retention persists across settings creation")
            }
        }
    }

    private static var defaultTrueBooleanKeys: [String] {
        [
            DefaultsKey.updateHistoryAfterAction,
            DefaultsKey.renderMarkdown,
            DefaultsKey.imageTextSearchEnabled,
            DefaultsKey.showMenuBarIcon,
            DefaultsKey.animateMenuBarIconOnCopy,
            DefaultsKey.soundEffectsEnabled,
            DefaultsKey.hapticFeedbackEnabled,
        ]
    }

    @MainActor
    private static func defaultTrueBooleanValues(
        _ settings: AppSettings
    ) -> [(String, Bool)] {
        [
            ("history update", settings.updateHistoryAfterAction),
            ("Markdown", settings.renderMarkdown),
            ("image text search", settings.imageTextSearchEnabled),
            ("menu bar", settings.showMenuBarIcon),
            ("menu bar animation", settings.animateMenuBarIconOnCopy),
            ("sound", settings.soundEffectsEnabled),
            ("haptic", settings.hapticFeedbackEnabled),
        ]
    }

    @MainActor
    private static func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "Kit.AppSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw TestError("Could not create an isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    @MainActor
    private static func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kit.AppSettingsTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @MainActor
    private static func setCreationTimes(_ dates: [Date], in directory: URL) throws {
        let databasePath = directory.appendingPathComponent("clipboard.sqlite3").path
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databasePath, &database, SQLITE_OPEN_READWRITE, nil)
        try TestSupport.expect(openResult == SQLITE_OK,
                               "Test database opens for fixed retention fixtures")
        guard let database else {
            throw TestError("Test database connection was unavailable")
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            database,
            "UPDATE items SET created_at = ?1, first_copied_at = ?1 WHERE text = ?2",
            -1, &statement, nil)
        try TestSupport.expect(prepareResult == SQLITE_OK,
                               "Fixed retention fixture update prepares")
        guard let statement else {
            throw TestError("Fixed retention fixture statement was unavailable")
        }
        defer { sqlite3_finalize(statement) }

        for (text, date) in zip(["expired", "boundary"], dates) {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            sqlite3_bind_text(statement, 2, text, -1, SQLITE_TRANSIENT)
            let stepResult = sqlite3_step(statement)
            try TestSupport.expect(stepResult == SQLITE_DONE,
                                   "Fixed retention fixture \(text) updates")
        }
    }

    private struct TestError: LocalizedError {
        let message: String

        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? { message }
    }
}
