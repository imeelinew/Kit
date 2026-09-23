import SwiftUI

/// A menu row's optional leading glyph: an SF Symbol, or a real app icon drawn from `IconCache`.
enum PopoverMenuIcon: Equatable {
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
    /// User-entered stack names stay literal so they are not looked up as localization keys.
    var verbatimTitle: String? = nil
    let icon: PopoverMenuIcon?
    var shortcut: String? = nil
    var isDestructive: Bool = false
    var isEnabled = true
    var isChecked = false

    @MainActor
    init(
        action: PaletteMenuAction,
        target: PasteTarget?,
        kindFilter: ClipboardKindFilter = .all,
        stackFilter: ClipboardStack.ID? = nil
    ) {
        switch action {
        case .about:
            title = "About Paste"
            icon = nil
        case .checkForUpdates:
            title = "Check for Updates"
            icon = nil
            isEnabled = AppCore.shared.updateService.canCheckForUpdates
        case .settings:
            title = "Settings"
            icon = nil
            shortcut = "⌘,"
        case .quit:
            title = "Quit Paste"
            icon = nil
            shortcut = "⌘Q"
            isDestructive = true
        case .paste:
            title = target?.pasteTitle ?? "Paste"
            icon = PopoverMenuIcon.paste(target)
            shortcut = "↵"
            isEnabled = target != nil && AppCore.shared.hasPasteTarget
        case .pasteKeepingOpen:
            title = "Paste & Keep Window Open"
            icon = PopoverMenuIcon.paste(target)
            isEnabled = target != nil && AppCore.shared.hasPasteTarget
        case .copy:
            title = "Copy to Clipboard"
            icon = .symbol("doc.on.doc")
            shortcut = PaletteShortcut.copyToClipboard.displayString
        case .pinToScreen:
            title = "Pin to Screen"
            icon = .symbol("pin")
            shortcut = PaletteShortcut.pinToScreen.displayString
        case .revealInFinder:
            title = "Show in Finder"
            icon = .symbol("folder")
            shortcut = PaletteShortcut.showInFinder.displayString
        case .delete:
            title = "Delete Entry"
            icon = .symbol("trash")
            isDestructive = true
        case .addToStack:
            title = "Add to Stack"
            icon = nil
        case .assignToStack(let item, let stack):
            title = "Add to Stack"
            verbatimTitle = stack.name
            icon = nil
            isChecked = AppCore.shared.clipboardStore.stackID(for: item.id) == stack.id
        case .setKindFilter(let filter):
            title = filter.title
            icon = .symbol(filter.symbolName)
            isChecked = filter == kindFilter
        case .setStackFilter(let stack):
            if let stack {
                title = "Add to Stack"
                verbatimTitle = stack.name
                icon = nil
                isChecked = stackFilter == stack.id
            } else {
                title = "Clipboard"
                icon = .symbol("clock.arrow.circlepath")
                isChecked = stackFilter == nil
            }
        case .newStack:
            title = "New Stack"
            icon = .symbol("plus")
        case .renameStack:
            title = "Rename"
            icon = nil
        case .deleteStack:
            title = "Delete Stack…"
            icon = nil
            isDestructive = true
        }
    }
}

/// In-window overlay menu (not a system popover), anchored to a palette corner so it stays clipped inside the panel, with a stock Liquid Glass surface. Data-driven so `selection` can highlight a row for keyboard navigation; `onActivate(index)` is the single path fired by both a click and Return.
struct PopoverMenu: View {
    let items: [PopoverMenuItem]
    @Binding var selection: Int
    let onActivate: (Int) -> Void
    var onRightClick: ((Int) -> Void)? = nil
    var namingText: Binding<String>? = nil
    var namingRow: Int? = nil
    var namingSelectsAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Index-as-id is stable because a menu's rows never reorder while it is open, and the index is what selection/activation address.
            let reservesIconSpace = items.contains { $0.icon != nil }
            ForEach(items.indices, id: \.self) { index in
                if let namingText, index == namingRow {
                    StackNameRow(text: namingText, selectAll: namingSelectsAll)
                } else {
                    PopoverMenuRow(
                        item: items[index],
                        selected: index == selection,
                        reservesIconSpace: reservesIconSpace,
                        onHover: { selection = index },
                        onActivate: { onActivate(index) },
                        onRightClick: onRightClick.map { handler in { handler(index) } }
                    )
                    .disabled(!items[index].isEnabled)
                }
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

/// Replaces the「新建 Stack」row with a field. Return and Esc are handled by the palette panel.
private struct StackNameRow: View {
    @Binding var text: String
    var selectAll: Bool

    var body: some View {
        StackNameField(text: $text, selectAll: selectAll)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StackNameField: NSViewRepresentable {
    @Binding var text: String
    var selectAll: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selectAll: selectAll)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = String(localized: "Name")
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .preferredFont(forTextStyle: .body)
        field.textColor = .labelColor
        field.delegate = context.coordinator
        field.cell?.sendsActionOnEndEditing = false
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text {
            field.stringValue = text
        }
        // The click that opens this field restores the search field after mouseUp.
        // Take first responder on the next turn, once that restoration has finished.
        guard !context.coordinator.didFocus, !context.coordinator.focusScheduled else { return }
        context.coordinator.focusScheduled = true
        DispatchQueue.main.async {
            context.coordinator.focusScheduled = false
            guard !context.coordinator.didFocus, let window = field.window else { return }
            guard window.makeFirstResponder(field) else { return }
            context.coordinator.didFocus = true
            if let editor = window.fieldEditor(true, for: field) as? NSTextView {
                editor.insertionPointColor = .textColor
                if context.coordinator.selectAll {
                    editor.selectAll(nil)
                }
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var selectAll: Bool
        var didFocus = false
        var focusScheduled = false

        init(text: Binding<String>, selectAll: Bool) {
            self.text = text
            self.selectAll = selectAll
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
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
    var onRightClick: (() -> Void)? = nil

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: Theme.Spacing.sm) {
                if let icon = item.icon {
                    switch icon {
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
                Group {
                    if let verbatimTitle = item.verbatimTitle {
                        Text(verbatim: verbatimTitle)
                    } else {
                        Text(item.title)
                    }
                }
                .font(Theme.Typography.menuRow)
                .foregroundStyle(item.isDestructive ? Color.red : Color.primary)
                Spacer(minLength: Theme.Spacing.sm)
                if item.isChecked {
                    Image(systemName: "checkmark")
                        .font(Theme.Typography.menuIcon)
                        .foregroundStyle(.secondary)
                        .frame(width: Theme.Size.menuIcon, height: Theme.Size.menuIcon)
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
        .overlay {
            if let onRightClick {
                StackRowRightClick(action: onRightClick)
            }
        }
    }
}

/// Lets a left click reach the SwiftUI button, and handles a right click itself.
private struct StackRowRightClick: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> RightClickView {
        let view = RightClickView()
        view.action = action
        return view
    }

    func updateNSView(_ view: RightClickView, context: Context) {
        view.action = action
    }

    final class RightClickView: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(point) else { return nil }
            let rightButton = NSEvent.pressedMouseButtons & (1 << 1) != 0
            return rightButton ? self : nil
        }

        override func rightMouseDown(with event: NSEvent) {
            action?()
        }
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
