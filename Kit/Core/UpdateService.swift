import AppKit
import Combine
import Sparkle

private let versionHistoryURL = URL(string: "https://imeelinew.github.io/Kit/version-history.html")!
private let versionHistoryEnglishURL = URL(string: "https://imeelinew.github.io/Kit/version-history.en.html")!

/// Gives the no-update alert its "Version History" button and opens the published change log.
/// Sparkle calls these on the main thread; hopping keeps the nonisolated protocol requirement honest.
private final class VersionHistoryDriver: NSObject, SPUStandardUserDriverDelegate {
    func standardUserDriverShouldShowVersionHistory(for item: SUAppcastItem) -> Bool {
        true
    }

    func standardUserDriverShowVersionHistory(for item: SUAppcastItem) {
        Task { @MainActor in
            NSWorkspace.shared.open(Self.pageURL(for: AppCore.shared.settings.language))
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
final class UpdateService: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false

    /// Sparkle references its user driver delegate weakly, so Kit has to keep it alive here.
    private let versionHistoryDriver: VersionHistoryDriver
    private let updaterController: SPUStandardUpdaterController

    init() {
        let versionHistoryDriver = VersionHistoryDriver()
        self.versionHistoryDriver = versionHistoryDriver
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: versionHistoryDriver
        )

        let updater = updaterController.updater
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$automaticallyChecksForUpdates)
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
