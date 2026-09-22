import SwiftUI

/// A menu row's optional leading glyph: a Lucide vector icon, an SF Symbol fallback, or a real app icon drawn from `IconCache`.
enum PopoverMenuIcon: Equatable {
    case lucide(LucideIconName)
    case symbol(String)
    case file(path: String)

    /// Target app icon for paste rows; returns nil when unknown without any fallback icon.
    static func paste(_ target: PasteTarget?) -> PopoverMenuIcon? {
        guard let path = target?.iconPath, FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return .file(path: path)
    }
}

/// Display metadata derived from the same semantic action the palette state machine executes.
struct PopoverMenuItem {
    let title: LocalizedStringKey
    let icon: PopoverMenuIcon?
    var shortcut: String? = nil
    var isDestructive: Bool = false
    var isEnabled = true
    var isChecked = false

    @MainActor
    init(action: PaletteMenuAction, target: PasteTarget?, kindFilter: ClipboardKindFilter = .all) {
        switch action {
        case .about:
            title = "About Paste"
            icon = .lucide(.info)
        case .checkForUpdates:
            title = "Check for Updates"
            icon = .lucide(.refreshCw)
            isEnabled = AppCore.shared.updateService.canCheckForUpdates
        case .settings:
            title = "Settings"
            icon = .lucide(.settings)
            shortcut = "⌘,"
        case .quit:
            title = "Quit Paste"
            icon = .lucide(.power)
            shortcut = "⌘Q"
            isDestructive = true
        case .paste:
            title = target?.pasteTitle ?? "Paste"
            icon = PopoverMenuIcon.paste(target)
            shortcut = "↵"
        case .pasteKeepingOpen:
            title = "Paste & Keep Window Open"
            icon = PopoverMenuIcon.paste(target)
        case .copy:
            title = "Copy to Clipboard"
            icon = .lucide(.copy)
            shortcut = PaletteShortcut.copyToClipboard.displayString
        case .rename:
            title = "Rename"
            icon = .lucide(.pencil)
            shortcut = PaletteShortcut.rename.displayString
        case .pinToScreen:
            title = "Pin to Screen"
            icon = .lucide(.pin)
            shortcut = PaletteShortcut.pinToScreen.displayString
        case .togglePin(let item):
            title = item.isPinned ? "Unpin Entry" : "Pin Entry"
            icon = .lucide(item.isPinned ? .bookmarkMinus : .bookmark)
            shortcut = PaletteShortcut.togglePin.displayString
        case .revealInFinder:
            title = "Show in Finder"
            icon = .lucide(.folder)
            shortcut = PaletteShortcut.showInFinder.displayString
        case .delete:
            title = "Delete Entry"
            icon = .lucide(.trash2)
            isDestructive = true
        case .setKindFilter(let filter):
            title = filter.title
            icon = .lucide(filter.icon)
            isChecked = filter == kindFilter
        }
    }
}

/// In-window overlay menu (not a system popover), anchored to a palette corner so it stays clipped inside the panel, with a stock Liquid Glass surface. Data-driven so `selection` can highlight a row for keyboard navigation; `onActivate(index)` is the single path fired by both a click and Return.
struct PopoverMenu: View {
    let items: [PopoverMenuItem]
    @Binding var selection: Int
    let onActivate: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Index-as-id is stable because a menu's rows never reorder while it is open, and the index is what selection/activation address.
            let reservesIconSpace = items.contains { $0.icon != nil }
            ForEach(items.indices, id: \.self) { index in
                PopoverMenuRow(
                    item: items[index],
                    selected: index == selection,
                    reservesIconSpace: reservesIconSpace,
                    onHover: { selection = index },
                    onActivate: { onActivate(index) }
                )
                .disabled(!items[index].isEnabled)
            }
        }
        .padding(Theme.Spacing.sm)
        .frame(width: Theme.Size.menuWidth)
        // Tahoe glass carries its own elevation/shadow; a hand-tuned drop shadow on top reads heavy and non-native, so we let the glass own it.
        .glassEffect(
            .regular, in: RoundedRectangle(cornerRadius: Theme.Radius.menuPanel, style: .continuous)
        )
    }
}

/// A single menu row: optional leading icon, label, and optional trailing shortcut glyph. Highlight is selection-driven (hover reports up so keyboard and mouse converge on one highlight), so there is never more than one active row.
private struct PopoverMenuRow: View {
    let item: PopoverMenuItem
    let selected: Bool
    /// When any row in the menu has an icon, empty rows keep a blank slot so labels stay column-aligned.
    var reservesIconSpace: Bool = false
    /// Fired when the cursor enters the row so the owner can move selection here — keyboard and mouse then share one highlight.
    let onHover: () -> Void
    let onActivate: () -> Void

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: Theme.Spacing.sm) {
                if let icon = item.icon {
                    switch icon {
                    case .lucide(let name):
                        LucideIcon(name: name)
                            .foregroundStyle(item.isDestructive ? Color.red : Color.secondary)
                    case .symbol(let name):
                        Image(systemName: name)
                            .font(Theme.Typography.menuIcon)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(item.isDestructive ? Color.red : Color.secondary)
                            .frame(width: Theme.Size.menuIcon, height: Theme.Size.menuIcon)
                    case .file(let path):
                        MenuFileIcon(path: path)
                    }
                } else if reservesIconSpace {
                    Color.clear
                        .frame(width: Theme.Size.menuIcon, height: Theme.Size.menuIcon)
                }
                Text(item.title)
                    .font(Theme.Typography.menuRow)
                    .foregroundStyle(item.isDestructive ? Color.red : Color.primary)
                Spacer(minLength: Theme.Spacing.sm)
                if item.isChecked {
                    LucideIcon(name: .check)
                        .foregroundStyle(.secondary)
                } else if let shortcut = item.shortcut {
                    HStack(spacing: Theme.Spacing.xxs) {
                        ForEach(Array(shortcut.enumerated()), id: \.offset) { _, glyph in
                            KeyCapChip(text: String(glyph), style: .outline)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.menuRow, style: .continuous)
                    .fill(
                        selected ? Theme.Colors.menuHover : Color.clear
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { if $0 { onHover() } }
    }
}

/// App icon for a menu row or bar control: renders directly from `IconCache`
/// so the paste target paints deterministically on the very first frame without flicker or async cancellation.
struct MenuFileIcon: View {
    let path: String

    var body: some View {
        let image = IconCache.icon(forFile: path)
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .frame(width: Theme.Size.menuIcon, height: Theme.Size.menuIcon)
    }
}
