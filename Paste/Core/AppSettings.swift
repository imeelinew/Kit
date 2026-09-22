import AppKit
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case simplifiedChinese

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Follow System"
        case .english: return "English"
        case .simplifiedChinese: return "Simplified Chinese"
        }
    }

    var locale: Locale {
        switch self {
        case .system: return .autoupdatingCurrent
        case .english: return Locale(identifier: "en")
        case .simplifiedChinese: return Locale(identifier: "zh-Hans")
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Follow System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

enum PinnedImageSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    var longestEdge: CGFloat {
        switch self {
        case .small: return 360
        case .medium: return 480
        case .large: return 640
        }
    }
}

enum PinnedTextSize {
    static let minimum: CGFloat = 9
    static let maximum: CGFloat = 24
    static let step: CGFloat = 1
    static let defaultValue: CGFloat = 13

    static func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, minimum), maximum)
    }
}

enum CopySoundEffect: Int, CaseIterable, Identifiable {
    case one = 1
    case two = 2
    case three = 3
    case four = 4

    var id: Int { rawValue }

    var title: String { "音效\(rawValue)" }

    var resourceName: String { "sound-effect-\(rawValue)" }
}

enum PinnedWindowOpacity {
    static let minimum: Double = 50
    static let maximum: Double = 100
    static let defaultValue: Double = 100

    static func clamped(_ value: Double) -> Double {
        min(max(value, minimum), maximum)
    }

    static func alpha(from percent: Double) -> CGFloat {
        CGFloat(clamped(percent) / 100)
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard
    private var reconcilingLaunchAtLogin = false

    private enum Key {
        static let clipboardRetention = "clipboardRetentionDays"
        static let clipboardDisabledApps = "clipboardDisabledApps"
        static let launchAtLogin = "launchAtLogin"
        static let switchToEnglishInputOnOpen = "switchToEnglishInputOnOpen"
        static let renderMarkdown = "renderMarkdown"
        static let language = "appLanguage"
        static let appearance = "appAppearance"
        static let pinnedImageSize = "pinnedImageSize"
        static let pinnedTextSize = "pinnedTextSize"
        static let pinnedWindowOpacity = "pinnedWindowOpacity"
        static let pinnedWindowBlur = "pinnedWindowBlur"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let animateMenuBarIconOnCopy = "animateMenuBarIconOnCopy"
        static let soundEffectsEnabled = "soundEffectsEnabled"
        static let copySoundEffect = "copySoundEffect"
    }

    @Published var clipboardRetention: ClipboardRetention {
        didSet { defaults.set(clipboardRetention.rawValue, forKey: Key.clipboardRetention) }
    }

    @Published var clipboardDisabledApps: [String] {
        didSet { defaults.set(clipboardDisabledApps, forKey: Key.clipboardDisabledApps) }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard !reconcilingLaunchAtLogin else { return }
            let actual = LaunchAtLogin.set(launchAtLogin)
            defaults.set(actual, forKey: Key.launchAtLogin)
            guard actual != launchAtLogin else { return }
            reconcilingLaunchAtLogin = true
            launchAtLogin = actual
            reconcilingLaunchAtLogin = false
        }
    }

    /// When enabled, opening the palette selects the English keyboard so pinyin search can be typed directly.
    @Published var switchToEnglishInputOnOpen: Bool {
        didSet { defaults.set(switchToEnglishInputOnOpen, forKey: Key.switchToEnglishInputOnOpen) }
    }

    @Published var renderMarkdown: Bool {
        didSet { defaults.set(renderMarkdown, forKey: Key.renderMarkdown) }
    }

    @Published var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: Key.language) }
    }

    @Published var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Key.appearance)
            appearance.apply()
        }
    }

    @Published var pinnedImageSize: PinnedImageSize {
        didSet { defaults.set(pinnedImageSize.rawValue, forKey: Key.pinnedImageSize) }
    }

    /// Shared by every pinned Markdown and code card and persisted as the next card's default.
    @Published var pinnedTextSize: CGFloat {
        didSet { defaults.set(Double(pinnedTextSize), forKey: Key.pinnedTextSize) }
    }

    /// Visible alpha of every pinned card, stored as 50...100 so 100 keeps today's fully opaque look.
    @Published var pinnedWindowOpacity: Double {
        didSet { defaults.set(pinnedWindowOpacity, forKey: Key.pinnedWindowOpacity) }
    }

    /// When enabled, pinned cards use a vibrancy material so the desktop shows through as blur.
    @Published var pinnedWindowBlur: Bool {
        didSet { defaults.set(pinnedWindowBlur, forKey: Key.pinnedWindowBlur) }
    }

    @Published var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) }
    }

    @Published var animateMenuBarIconOnCopy: Bool {
        didSet { defaults.set(animateMenuBarIconOnCopy, forKey: Key.animateMenuBarIconOnCopy) }
    }

    @Published var soundEffectsEnabled: Bool {
        didSet { defaults.set(soundEffectsEnabled, forKey: Key.soundEffectsEnabled) }
    }

    @Published var copySoundEffect: CopySoundEffect {
        didSet { defaults.set(copySoundEffect.rawValue, forKey: Key.copySoundEffect) }
    }

    var pinnedWindowAlpha: CGFloat {
        PinnedWindowOpacity.alpha(from: pinnedWindowOpacity)
    }

    init() {
        clipboardRetention =
            ClipboardRetention(rawValue: defaults.integer(forKey: Key.clipboardRetention))
            ?? .threeMonths
        clipboardDisabledApps =
            defaults.stringArray(forKey: Key.clipboardDisabledApps)
            ?? ["com.apple.keychainaccess", "com.apple.Passwords"]
        launchAtLogin = LaunchAtLogin.isEnabled
        switchToEnglishInputOnOpen = defaults.bool(forKey: Key.switchToEnglishInputOnOpen)
        renderMarkdown = defaults.object(forKey: Key.renderMarkdown) as? Bool ?? true
        language =
            defaults.string(forKey: Key.language).flatMap(AppLanguage.init(rawValue:)) ?? .system
        appearance =
            defaults.string(forKey: Key.appearance).flatMap(AppAppearance.init(rawValue:))
            ?? .system
        pinnedImageSize =
            defaults.string(forKey: Key.pinnedImageSize).flatMap(PinnedImageSize.init(rawValue:))
            ?? .medium
        pinnedTextSize = PinnedTextSize.clamped(
            defaults.object(forKey: Key.pinnedTextSize) == nil
                ? PinnedTextSize.defaultValue
                : CGFloat(defaults.double(forKey: Key.pinnedTextSize))
        )
        pinnedWindowOpacity = PinnedWindowOpacity.clamped(
            defaults.object(forKey: Key.pinnedWindowOpacity) == nil
                ? PinnedWindowOpacity.defaultValue
                : defaults.double(forKey: Key.pinnedWindowOpacity)
        )
        pinnedWindowBlur = defaults.bool(forKey: Key.pinnedWindowBlur)
        showMenuBarIcon = defaults.object(forKey: Key.showMenuBarIcon) as? Bool ?? true
        animateMenuBarIconOnCopy =
            defaults.object(forKey: Key.animateMenuBarIconOnCopy) as? Bool ?? true
        soundEffectsEnabled = defaults.object(forKey: Key.soundEffectsEnabled) as? Bool ?? true
        copySoundEffect =
            defaults.object(forKey: Key.copySoundEffect) == nil
            ? .one
            : CopySoundEffect(rawValue: defaults.integer(forKey: Key.copySoundEffect)) ?? .one
    }
}
