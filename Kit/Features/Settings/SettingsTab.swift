enum SettingsTab: Int, CaseIterable, Hashable, Identifiable {
    case general, appearance, sound, clipboard, shortcuts, about

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

    /// Lucide icons in the asset catalog. Names follow lucide.dev.
    var iconAsset: String {
        switch self {
        case .general: return "lucide-settings"
        case .shortcuts: return "lucide-keyboard"
        case .appearance: return "lucide-sun-moon"
        case .sound: return "lucide-volume-2"
        case .clipboard: return "lucide-clipboard"
        case .about: return "lucide-info"
        }
    }
}
