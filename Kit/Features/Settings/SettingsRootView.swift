import SwiftUI

enum SettingsTab: Int, CaseIterable, Hashable, Identifiable {
    case general, shortcuts, appearance, sound, clipboard, history, about

    var id: Int { rawValue }

    var localizationKey: String {
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

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .appearance: return "eyeglasses"
        case .sound: return "speaker.wave.2"
        case .clipboard: return "clipboard"
        case .history: return "clock"
        case .about: return "info.circle"
        }
    }
}
