import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import SwiftUI

/// The sole keyboard gateway for the palette window. It receives key events before the current
/// first responder, so embedded AppKit views and SwiftUI focus changes cannot disable commands.
final class PalettePanel: NSPanel {
    weak var paletteViewModel: PaletteViewModel? {
        didSet {
            paletteViewModel?.onMenuOpenChanged = { [weak self] open in
                self?.setSearchCaretHidden(open)
            }
            paletteViewModel?.onSearchFocusRequested = { [weak self] in
                self?.requestSearchFocus()
            }
        }
    }

    private weak var searchField: NSTextField?
    private weak var renameField: NSTextField?
    private var pendingSearchFocusRequest: UUID?

    private static let relevantModifiers: NSEvent.ModifierFlags = [
        .command, .option, .control, .shift,
    ]

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            commitRenameIfClickIsOutside(event)
        }
        if event.type == .keyDown, route(event) { return }
        super.sendEvent(event)
    }

    private func route(_ event: NSEvent) -> Bool {
        guard let paletteViewModel else { return false }
        let keyCode = Int(event.keyCode)
        let modifiers = event.modifierFlags.intersection(Self.relevantModifiers)
        let shortcut = KeyboardShortcuts.Shortcut(event: event)

        if modifiers == .command {
            switch keyCode {
            case kVK_ANSI_N:
                return handleOnce(.newTextItem, event: event)
            case kVK_ANSI_Comma:
                return handleOnce(.settings, event: event)
            case kVK_ANSI_Q:
                return handleOnce(.quit, event: event)
            default:
                break
            }
        }

        if paletteViewModel.renamingID != nil {
            return routeRename(event, keyCode: keyCode, modifiers: modifiers)
        }

        if modifiers == .command, keyCode == kVK_Delete {
            return paletteViewModel.handle(.clearQuery)
        }

        if PaletteShortcut.actions.matches(shortcut) {
            return handleOnce(.toggleActions, event: event)
        }
        if PaletteShortcut.copyToClipboard.matches(shortcut) {
            return handleOnce(.copy, event: event)
        }
        if PaletteShortcut.rename.matches(shortcut) {
            return handleOnce(.rename, event: event)
        }
        if PaletteShortcut.pinToScreen.matches(shortcut) {
            return handleOnce(.pinToScreen, event: event)
        }
        if PaletteShortcut.togglePin.matches(shortcut) {
            return handleOnce(.togglePin, event: event)
        }
        if PaletteShortcut.showInFinder.matches(shortcut) {
            return handleOnce(.revealInFinder, event: event)
        }

        if modifiers == .command {
            switch keyCode {
            case kVK_ANSI_C, kVK_ANSI_X, kVK_ANSI_V, kVK_ANSI_A:
                if handleEditingShortcut(keyCode) { return true }
            default:
                break
            }
        }

        if modifiers.isEmpty {
            switch keyCode {
            case kVK_DownArrow:
                return paletteViewModel.handle(.move(1))
            case kVK_UpArrow:
                return paletteViewModel.handle(.move(-1))
            case kVK_Return, kVK_ANSI_KeypadEnter:
                return handleOnce(.activate, event: event)
            case kVK_Escape:
                return paletteViewModel.handle(.cancel)
            case kVK_Space:
                if paletteViewModel.canToggleQuickLook {
                    return handleOnce(.toggleQuickLook, event: event)
                }
                // At an empty query, Space is a Quick Look gesture even when the selected item
                // cannot be previewed. Swallow it instead of starting a useless blank search.
                if paletteViewModel.queryIsEmpty {
                    return true
                }
            default:
                break
            }
        }

        // An overlay menu is modal. Unsupported keys must not leak into the search editor or the
        // read-only preview behind it.
        return paletteViewModel.menuOpen
    }

    private func routeRename(
        _ event: NSEvent, keyCode: Int, modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        if modifiers == .command {
            switch keyCode {
            case kVK_ANSI_C, kVK_ANSI_X, kVK_ANSI_V, kVK_ANSI_A:
                return handleEditingShortcut(keyCode)
            default:
                break
            }
        }
        if modifiers.isEmpty {
            switch keyCode {
            case kVK_Return, kVK_ANSI_KeypadEnter:
                // Let the active NSTextField finish editing so marked text is finalized and the
                // row editor commits its actual value instead of a separately mirrored draft.
                return false
            case kVK_Escape:
                return paletteViewModel?.handle(.cancel) ?? false
            default:
                return false
            }
        }
        return false
    }

    private func handleOnce(_ command: PaletteCommand, event: NSEvent) -> Bool {
        if event.isARepeat { return true }
        return paletteViewModel?.handle(command) ?? false
    }

    func registerSearchField(_ field: NSTextField) {
        searchField = field
        schedulePendingSearchFocus()
    }

    func registerRenameField(_ field: NSTextField) {
        renameField = field
    }

    func requestSearchFocus() {
        let request = UUID()
        pendingSearchFocusRequest = request
        scheduleSearchFocus(for: request)
    }

    private func schedulePendingSearchFocus() {
        guard let request = pendingSearchFocusRequest else { return }
        scheduleSearchFocus(for: request)
    }

    private func scheduleSearchFocus(for request: UUID) {
        DispatchQueue.main.async { [weak self] in
            _ = self?.focusSearch(for: request)
        }
    }

    @discardableResult
    private func focusSearch(for request: UUID) -> Bool {
        guard pendingSearchFocusRequest == request, isVisible, isKeyWindow,
            paletteViewModel?.renamingID == nil, let searchField, searchField.isEnabled
        else { return false }
        guard makeFirstResponder(searchField) else { return false }
        pendingSearchFocusRequest = nil
        return true
    }

    private func commitRenameIfClickIsOutside(_ event: NSEvent) {
        guard let paletteViewModel, paletteViewModel.renamingID != nil,
            let renameField
        else { return }

        let frameInWindow = renameField.convert(renameField.bounds, to: nil)
        if !renameField.isHidden, frameInWindow.contains(event.locationInWindow) { return }

        if renameField.currentEditor() != nil {
            _ = makeFirstResponder(nil)
        }
        if paletteViewModel.renamingID != nil {
            paletteViewModel.commitOpenRename(renameField.stringValue)
        }
    }

    private func setSearchCaretHidden(_ hidden: Bool) {
        guard let editor = firstResponder as? NSTextView else { return }
        editor.insertionPointColor = hidden ? .clear : .textColor
        editor.updateInsertionPointStateAndRestartTimer(!hidden)
    }

    /// This accessory app has no visible Edit menu, so route standard editing commands to the
    /// active AppKit field editor ourselves.
    private func handleEditingShortcut(_ keyCode: Int) -> Bool {
        guard paletteViewModel?.menuOpen != true, let editor = firstResponder as? NSTextView else {
            return false
        }

        switch keyCode {
        case kVK_ANSI_C:
            guard editor.selectedRange().length > 0 else { return true }
            editor.copy(nil)
            if !(editor is PreviewTextView) {
                Paster.markCurrentPasteboardInternal()
            }
            return true
        case kVK_ANSI_X:
            guard editor.isEditable, editor.selectedRange().length > 0 else { return true }
            editor.cut(nil)
            Paster.markCurrentPasteboardInternal()
            return true
        case kVK_ANSI_V:
            guard editor.isEditable else { return true }
            editor.paste(nil)
            return true
        case kVK_ANSI_A:
            editor.selectAll(nil)
            return true
        default:
            return false
        }
    }

    init<Content: View>(rootView: Content, visualStyle: PaletteVisualStyle) {
        let panelSize = CGSize(width: Theme.Size.panelWidth, height: Theme.Size.panelHeight)
        super.init(
            contentRect: NSRect(
                x: 0, y: 0, width: panelSize.width, height: panelSize.height),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        acceptsMouseMovedEvents = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        isReleasedWhenClosed = false

        let frame = NSRect(
            x: 0, y: 0, width: panelSize.width, height: panelSize.height)
        let hosting = TransparentPaletteHostingView(rootView: rootView)
        hosting.frame = frame
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]

        switch visualStyle {
        case .liquid:
            let glass = NSGlassEffectView(frame: frame)
            glass.autoresizingMask = [.width, .height]
            glass.style = .regular
            glass.cornerRadius = Theme.Radius.panel
            glass.contentView = hosting

            // The glass shadow is still a rectangle. Masking the window to the same
            // corner makes those square corners transparent so the shadow follows the curve.
            let shell = NSView(frame: frame)
            shell.autoresizingMask = [.width, .height]
            shell.wantsLayer = true
            shell.layer?.backgroundColor = NSColor.clear.cgColor
            shell.layer?.cornerRadius = Theme.Radius.panel
            shell.layer?.masksToBounds = true
            shell.addSubview(glass)
            contentView = shell
        case .frosted:
            let material = NSVisualEffectView(frame: frame)
            material.autoresizingMask = [.width, .height]
            material.material = .hudWindow
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = Theme.Radius.panel
            material.layer?.masksToBounds = true
            material.addSubview(hosting)
            contentView = material
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class TransparentPaletteHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}
