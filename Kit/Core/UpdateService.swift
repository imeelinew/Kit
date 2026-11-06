import AppKit
import Observation
import Sparkle

private let versionHistoryURL = URL(string: "https://imeelinew.github.io/Kit/site/version-history.html")!
private let versionHistoryEnglishURL = URL(string: "https://imeelinew.github.io/Kit/site/version-history.en.html")!

/// Gives the no-update alert its "Version History" button and opens the published change log.
/// Sparkle calls these on the main thread; hopping keeps the nonisolated protocol requirement honest.
private final class VersionHistoryDriver: NSObject, SPUStandardUserDriverDelegate {
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func standardUserDriverShouldShowVersionHistory(for item: SUAppcastItem) -> Bool {
        true
    }

    func standardUserDriverShowVersionHistory(for item: SUAppcastItem) {
        let settings = self.settings
        Task { @MainActor in
            NSWorkspace.shared.open(Self.pageURL(for: settings.language))
        }
    }

    /// The change log is published in both of Kit's languages; `.system` follows the resolved bundle.
    private static func pageURL(for language: AppLanguage) -> URL {
        let code: String
        switch language {
        case .simplifiedChinese: code = "zh-Hans"
        case .english: code = "en"
        case .system: code = Bundle.main.preferredLocalizations.first ?? "en"
        }
        return code.hasPrefix("zh") ? versionHistoryURL : versionHistoryEnglishURL
    }
}

/// Owns Sparkle for the lifetime of the app and exposes only the controls used by Kit's UI.
/// Sparkle persists its own preferences; Kit deliberately does not duplicate them in AppSettings.
@MainActor
@Observable
final class UpdateService {
    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = false

    /// Sparkle references its user driver delegate weakly, so Kit has to keep it alive here.
    @ObservationIgnored private let versionHistoryDriver: VersionHistoryDriver
    @ObservationIgnored private let updaterController: SPUStandardUpdaterController
    @ObservationIgnored private var canCheckObserver: NSKeyValueObservation?
    @ObservationIgnored private var autoCheckObserver: NSKeyValueObservation?

    init(settings: AppSettings) {
        let versionHistoryDriver = VersionHistoryDriver(settings: settings)
        self.versionHistoryDriver = versionHistoryDriver
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: versionHistoryDriver
        )

        let updater = updaterController.updater
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        canCheckObserver = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.canCheckForUpdates = self.updaterController.updater.canCheckForUpdates
            }
        }
        autoCheckObserver = updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.automaticallyChecksForUpdates = self.updaterController.updater.automaticallyChecksForUpdates
            }
        }
    }

    func start() {
        updaterController.startUpdater()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        updaterController.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        let updater = updaterController.updater
        guard updater.automaticallyChecksForUpdates != enabled else { return }
        updater.automaticallyChecksForUpdates = enabled
    }
}
