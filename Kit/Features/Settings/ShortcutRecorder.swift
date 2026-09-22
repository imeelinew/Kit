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
    static let paletteRename = Self(
        "paletteRename",
        default: .init(.r, modifiers: [.command])
    )
    static let palettePinToScreen = Self("palettePinToScreen")
    static let paletteTogglePin = Self(
        "paletteTogglePin",
        default: .init(.p, modifiers: [.command])
    )
    static let paletteShowInFinder = Self("paletteShowInFinder")
    static let pinnedImageClose = Self(
        "pinnedImageClose",
        default: .init(.w, modifiers: [.command])
    )
    static let pinnedImageCloseAll = Self(
        "pinnedImageCloseAll",
        default: .init(.w, modifiers: [.command, .option])
    )
    static let pinnedImageDismiss = Self(
        "pinnedImageDismiss",
        default: .init(.escape)
    )
    static let pinnedImageCopy = Self(
        "pinnedImageCopy",
        default: .init(.c, modifiers: [.command])
    )
    static let pinnedImageZoomIn = Self(
        "pinnedImageZoomIn",
        default: .init(.equal, modifiers: [.command, .shift])
    )
    static let pinnedImageZoomOut = Self(
        "pinnedImageZoomOut",
        default: .init(.minus, modifiers: [.command])
    )
    static let pinnedImageResetSize = Self(
        "pinnedImageResetSize",
        default: .init(.zero, modifiers: [.command])
    )
    static let hidePinnedCards = Self(
        "hidePinnedCards",
        default: .init(.h, modifiers: [.command, .shift])
    )
}

enum PaletteShortcut {
    case actions
    case copyToClipboard
    case rename
    case pinToScreen
    case togglePin
    case showInFinder

    private static let actionsName = local(.paletteActions)
    private static let copyToClipboardName = local(.paletteCopyToClipboard)
    private static let renameName = local(.paletteRename)
    private static let pinToScreenName = local(.palettePinToScreen)
    private static let togglePinName = local(.paletteTogglePin)
    private static let showInFinderName = local(.paletteShowInFinder)

    var name: KeyboardShortcuts.Name {
        switch self {
        case .actions: Self.actionsName
        case .copyToClipboard: Self.copyToClipboardName
        case .rename: Self.renameName
        case .pinToScreen: Self.pinToScreenName
        case .togglePin: Self.togglePinName
        case .showInFinder: Self.showInFinderName
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
    case dismiss
    case copy
    case zoomIn
    case zoomOut
    case resetSize

    private static let closeName = local(.pinnedImageClose)
    private static let closeAllName = local(.pinnedImageCloseAll)
    private static let dismissName = local(.pinnedImageDismiss)
    private static let copyName = local(.pinnedImageCopy)
    private static let zoomInName = local(.pinnedImageZoomIn)
    private static let zoomOutName = local(.pinnedImageZoomOut)
    private static let resetSizeName = local(.pinnedImageResetSize)

    var name: KeyboardShortcuts.Name {
        switch self {
        case .close: Self.closeName
        case .closeAll: Self.closeAllName
        case .dismiss: Self.dismissName
        case .copy: Self.copyName
        case .zoomIn: Self.zoomInName
        case .zoomOut: Self.zoomOutName
        case .resetSize: Self.resetSizeName
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
            PreferencesRow(label: "Show Paste") {
                KeyboardShortcuts.Recorder(for: .toggleClipboard)
            }

            PreferencesDivider()

            PreferencesSectionHeader(title: "Palette")

            shortcutRow("Actions", shortcut: .actions)
            shortcutRow("Copy to Clipboard", shortcut: .copyToClipboard)
            shortcutRow("Rename", shortcut: .rename)
            shortcutRow("Pin to Screen", shortcut: .pinToScreen)
            shortcutRow("Pin Entry", shortcut: .togglePin)
            shortcutRow("Show in Finder", shortcut: .showInFinder)

            PreferencesDivider()

            PreferencesSectionHeader(title: "Pinned Images")

            pinnedImageShortcutRow("Close Pinned Image", shortcut: .close)
            pinnedImageShortcutRow("Close All Pinned Images", shortcut: .closeAll)
            pinnedImageShortcutRow("Dismiss Pinned Image", shortcut: .dismiss)
            pinnedImageShortcutRow("Copy Pinned Image", shortcut: .copy)
            pinnedImageShortcutRow("Zoom In Pinned Image", shortcut: .zoomIn)
            pinnedImageShortcutRow("Zoom Out Pinned Image", shortcut: .zoomOut)
            pinnedImageShortcutRow("Fit Pinned Image to Screen", shortcut: .resetSize)

            PreferencesRow(label: "Hide Pinned Cards") {
                KeyboardShortcuts.Recorder(for: .hidePinnedCards)
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
