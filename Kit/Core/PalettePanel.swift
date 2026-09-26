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

    private var presentationMouseLocation = NSEvent.mouseLocation
    private var pointerHasMoved = false

    func beginPresentation() {
        presentationMouseLocation = NSEvent.mouseLocation
        pointerHasMoved = false
    }

    /// Ordering a window under a stationary pointer is not a selection gesture.
    var allowsHoverSelection: Bool {
        guard isVisible else { return false }
        if !pointerHasMoved {
            let location = NSEvent.mouseLocation
            pointerHasMoved = hypot(
                location.x - presentationMouseLocation.x,
                location.y - presentationMouseLocation.y) >= 1
        }
        return pointerHasMoved
    }

    private weak var searchField: NSTextField?
    private var pendingSearchFocusRequest: UUID?

    private static let relevantModifiers: NSEvent.ModifierFlags = [
        .command, .option, .control, .shift,
    ]

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, route(event) { return }
        super.sendEvent(event)
    }

    private func route(_ event: NSEvent) -> Bool {
        guard let paletteViewModel else { return false }
        let keyCode = Int(event.keyCode)
        let modifiers = event.modifierFlags.intersection(Self.relevantModifiers)
        if let handled = routeStackNaming(
            keyCode: keyCode, modifiers: modifiers, viewModel: paletteViewModel)
        {
            return handled
        }
        let shortcut = KeyboardShortcuts.Shortcut(event: event)

        if modifiers == .command {
            switch keyCode {
            case kVK_ANSI_Comma:
                return handleOnce(.settings, event: event)
            case kVK_ANSI_Q:
                return handleOnce(.quit, event: event)
            default:
                break
            }
        }

        if modifiers == .command, keyCode == kVK_Delete {
            return paletteViewModel.handle(.clearQuery)
        }

        // Backspace is a fixed entry command only when it cannot erase search text.
        // Naming fields are routed above, and IME composition belongs to the editor.
        if modifiers.isEmpty, keyCode == kVK_Delete {
            if !paletteViewModel.menuOpen {
                if let editor = firstResponder as? NSTextView, editor.hasMarkedText() {
                    return false
                }
                guard paletteViewModel.query.isEmpty else { return false }
            }
            return handleOnce(.delete, event: event)
        }

        if PaletteShortcut.actions.matches(shortcut) {
            return handleOnce(.toggleActions, event: event)
        }
        if PaletteShortcut.copyToClipboard.matches(shortcut) {
            return handleOnce(.copy, event: event)
        }
        if PaletteShortcut.pinToScreen.matches(shortcut) {
            return handleOnce(.pinToScreen, event: event)
        }
        if PaletteShortcut.showInFinder.matches(shortcut) {
            return handleOnce(.revealInFinder, event: event)
        }
        if PaletteShortcut.showNextStack.matches(shortcut) {
            return paletteViewModel.handle(.cycleStack(1))
        }
        if PaletteShortcut.showPreviousStack.matches(shortcut) {
            return paletteViewModel.handle(.cycleStack(-1))
        }
        if PaletteShortcut.showNextType.matches(shortcut) {
            return paletteViewModel.handle(.cycleType(1))
        }
        if PaletteShortcut.showPreviousType.matches(shortcut) {
            return paletteViewModel.handle(.cycleType(-1))
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

    /// `true` consumes the key, `false` lets the stack name field see it, `nil` is not naming.
    private func routeStackNaming(
        keyCode: Int, modifiers: NSEvent.ModifierFlags, viewModel: PaletteViewModel
    ) -> Bool? {
        guard viewModel.isNamingStack else { return nil }
        if modifiers.isEmpty {
            switch keyCode {
            case kVK_Escape:
                viewModel.cancelStackName()
                return true
            case kVK_Return, kVK_ANSI_KeypadEnter:
                viewModel.commitStackName()
                return true
            case kVK_UpArrow, kVK_DownArrow:
                return true
            default:
                return false
            }
        }
        if modifiers == .command {
            switch keyCode {
            case kVK_ANSI_C, kVK_ANSI_X, kVK_ANSI_V, kVK_ANSI_A:
                return handleEditingShortcut(keyCode)
            default:
                return nil
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

    func requestSearchFocus() {
        let request = UUID()
        pendingSearchFocusRequest = request
        if !focusSearch(for: request) { scheduleSearchFocus(for: request) }
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
        guard paletteViewModel?.isNamingStack != true else {
            pendingSearchFocusRequest = nil
            return false
        }
        guard pendingSearchFocusRequest == request, isVisible, isKeyWindow,
            let searchField, searchField.isEnabled
        else { return false }
        guard makeFirstResponder(searchField) else { return false }
        pendingSearchFocusRequest = nil
        return true
    }

    private func setSearchCaretHidden(_ hidden: Bool) {
        guard let editor = firstResponder as? NSTextView else { return }
        editor.insertionPointColor = hidden ? .clear : .textColor
        editor.updateInsertionPointStateAndRestartTimer(!hidden)
    }

    /// This accessory app has no visible Edit menu, so route standard editing commands to the
    /// active AppKit field editor ourselves.
    private func handleEditingShortcut(_ keyCode: Int) -> Bool {
        guard paletteViewModel?.menuOpen != true || paletteViewModel?.isNamingStack == true,
            let editor = firstResponder as? NSTextView
        else {
            return false
        }

        switch keyCode {
        case kVK_ANSI_C:
            guard editor.selectedRange().length > 0 else { return true }
            editor.copy(nil)
            Paster.markCurrentPasteboardInternal()
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

            // The material's rounded layer does not clip the window's rectangular shadow.
            // Match the shell that keeps Liquid Glass's corners transparent.
            let shell = NSView(frame: frame)
            shell.autoresizingMask = [.width, .height]
            shell.wantsLayer = true
            shell.layer?.backgroundColor = NSColor.clear.cgColor
            shell.layer?.cornerRadius = Theme.Radius.panel
            shell.layer?.masksToBounds = true
            shell.addSubview(material)
            contentView = shell
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class TransparentPaletteHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}
