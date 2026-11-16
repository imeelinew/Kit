enum SettingsTab: Int, CaseIterable, Hashable, Identifiable {
    case general, appearance, clipboard, sound, shortcuts, about

    var id: Int { rawValue }

    var localizationKey: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .appearance: return "Appearance"
        case .sound: return "Sound & Haptics"
        case .clipboard: return "Clipboard"
        case .about: return "About"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .appearance: return "sun.max"
        case .sound: return "speaker.wave.2"
        case .clipboard: return "clipboard"
        case .about: return "info.circle"
        }
    }
}
