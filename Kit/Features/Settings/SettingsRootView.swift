import SwiftUI

enum SettingsTab: Int, CaseIterable, Hashable, Identifiable {
    case general, shortcuts, appearance, sound, clipboard, history, about

    var id: Int { rawValue }

    var localizationKey: String.LocalizationValue {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .appearance: return "Appearance"
        case .sound: return "Sound"
        case .clipboard: return "Clipboard"
        case .history: return "History"
        case .about: return "About"
        }
    }

    /// Stable identifier for `MacAppSettingsUI` tab items.
    var tabIdentifier: String {
        switch self {
        case .general: return "general"
        case .shortcuts: return "shortcuts"
        case .appearance: return "appearance"
        case .sound: return "sound"
        case .clipboard: return "clipboard"
        case .history: return "history"
        case .about: return "about"
        }
    }

    var lucideIcon: LucideIconName {
        switch self {
        case .general: return .settings
        case .shortcuts: return .keyboard
        case .appearance: return .glasses
        case .sound: return .volume2
        case .clipboard: return .clipboard
        case .history: return .clock
        case .about: return .info
        }
    }

    var preferredPaneHeight: CGFloat {
        switch self {
        case .general: return 300
        case .shortcuts: return 800
        case .appearance: return 500
        case .sound: return 200
        case .clipboard: return 360
        case .history: return 220
        case .about: return 320
        }
    }
}
