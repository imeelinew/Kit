import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let toggleClipboard = Self(
        "toggleClipboard",
        default: .init(.w, modifiers: [.option])
    )
    static let paletteActions = Self(
        "paletteActions",
        default: .init(.k, modifiers: [.command])
    )
    static let paletteCopyToClipboard = Self(
        "paletteCopyToClipboard",
        default: .init(.return, modifiers: [.command])
    )
    static let palettePinToScreen = Self("palettePinToScreen")
    static let paletteShowInFinder = Self("paletteShowInFinder")
    static let paletteShowNextStack = Self(
        "paletteShowNextStack",
        default: .init(.downArrow, modifiers: [.option])
    )
    static let paletteShowPreviousStack = Self(
        "paletteShowPreviousStack",
        default: .init(.upArrow, modifiers: [.option])
    )
    static let pinnedImageClose = Self(
        "pinnedImageClose",
        default: .init(.w, modifiers: [.command])
    )
    static let pinnedImageCloseAll = Self(
        "pinnedImageCloseAll",
        default: .init(.w, modifiers: [.command, .option])
    )
    static let pinnedImageCopy = Self(
        "pinnedImageCopy",
        default: .init(.c, modifiers: [.command])
    )
    static let hidePinnedCards = Self(
        "hidePinnedCards",
        default: .init(.h, modifiers: [.command, .shift])
    )
}

enum PaletteShortcut {
    case actions
    case copyToClipboard
    case pinToScreen
    case showInFinder
    case showNextStack
    case showPreviousStack

    private static let actionsName = local(.paletteActions)
    private static let copyToClipboardName = local(.paletteCopyToClipboard)
    private static let pinToScreenName = local(.palettePinToScreen)
    private static let showInFinderName = local(.paletteShowInFinder)
    private static let showNextStackName = local(.paletteShowNextStack)
    private static let showPreviousStackName = local(.paletteShowPreviousStack)

    var name: KeyboardShortcuts.Name {
        switch self {
        case .actions: Self.actionsName
        case .copyToClipboard: Self.copyToClipboardName
        case .pinToScreen: Self.pinToScreenName
        case .showInFinder: Self.showInFinderName
        case .showNextStack: Self.showNextStackName
        case .showPreviousStack: Self.showPreviousStackName
        }
    }

    var shortcut: KeyboardShortcuts.Shortcut? {
        KeyboardShortcuts.getShortcut(for: name)
    }

    @MainActor
    var displayString: String? {
        shortcut?.description.replacingOccurrences(of: "↩", with: "↵")
    }

    func matches(_ eventShortcut: KeyboardShortcuts.Shortcut?) -> Bool {
        guard let eventShortcut, let shortcut else { return false }
        return eventShortcut == shortcut
    }

    private static func local(
        _ name: KeyboardShortcuts.Name
    ) -> KeyboardShortcuts.Name {
        KeyboardShortcuts.disable(name)
        return name
    }
}

enum PinnedImageShortcut {
    case close
    case closeAll
    case copy

    private static let closeName = local(.pinnedImageClose)
    private static let closeAllName = local(.pinnedImageCloseAll)
    private static let copyName = local(.pinnedImageCopy)

    var name: KeyboardShortcuts.Name {
        switch self {
        case .close: Self.closeName
        case .closeAll: Self.closeAllName
        case .copy: Self.copyName
        }
    }

    func matches(_ eventShortcut: KeyboardShortcuts.Shortcut?) -> Bool {
        guard let eventShortcut, let shortcut = KeyboardShortcuts.getShortcut(for: name) else {
            return false
        }
        return eventShortcut == shortcut
    }

    private static func local(
        _ name: KeyboardShortcuts.Name
    ) -> KeyboardShortcuts.Name {
        KeyboardShortcuts.disable(name)
        return name
    }
}

private struct LocalShortcutRecorder: View {
    let name: KeyboardShortcuts.Name

    var body: some View {
        KeyboardShortcuts.Recorder(for: name) { _ in
            KeyboardShortcuts.disable(name)
        }
        .onAppear {
            KeyboardShortcuts.disable(name)
        }
    }
}

struct ShortcutsSettingsView: View {
    var body: some View {
        PreferencesForm {
            Section {
                PreferencesRow(label: "Show Kit") {
                    KeyboardShortcuts.Recorder(for: .toggleClipboard)
                }
            }

            Section("Palette") {
                shortcutRow("Actions", shortcut: .actions)
                shortcutRow("Copy to Clipboard", shortcut: .copyToClipboard)
                shortcutRow("Pin to Screen", shortcut: .pinToScreen)
                shortcutRow("Show in Finder", shortcut: .showInFinder)
                shortcutRow("Show Next Stack", shortcut: .showNextStack)
                shortcutRow("Show Previous Stack", shortcut: .showPreviousStack)
            }

            Section("Pinned Images") {
                pinnedImageShortcutRow("Close Pinned Image", shortcut: .close)
                pinnedImageShortcutRow("Close All Pinned Images", shortcut: .closeAll)
                pinnedImageShortcutRow("Copy Pinned Image", shortcut: .copy)

                PreferencesRow(label: "Hide Pinned Cards") {
                    KeyboardShortcuts.Recorder(for: .hidePinnedCards)
                }
            }
        }
    }

    private func shortcutRow(
        _ label: LocalizedStringKey,
        shortcut: PaletteShortcut
    ) -> some View {
        PreferencesRow(label: label) {
            LocalShortcutRecorder(name: shortcut.name)
        }
    }

    private func pinnedImageShortcutRow(
        _ label: LocalizedStringKey,
        shortcut: PinnedImageShortcut
    ) -> some View {
        PreferencesRow(label: label) {
            LocalShortcutRecorder(name: shortcut.name)
        }
    }
}
