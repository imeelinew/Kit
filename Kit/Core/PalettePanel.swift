import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import SwiftUI

@MainActor
protocol PaletteHoverHandling: AnyObject {
    func clearHover()
    func mouseMoved(with event: NSEvent)
}

/// The sole keyboard gateway for the palette window. It receives key events before the current
/// first responder, so embedded AppKit views and SwiftUI focus changes cannot disable commands.
final class PalettePanel: NSPanel {
    weak var paletteViewModel: PaletteViewModel? {
        didSet {
            paletteViewModel?.onMenuOpenChanged = { [weak self] open in
                if open {
                    self?.setSearchCaretHidden(true)
                } else {
                    self?.requestSearchFocus()
                }
            }
            paletteViewModel?.onSearchFocusRequested = { [weak self] in
                self?.requestSearchFocus()
            }
            paletteViewModel?.onSearchQueryChanged = { [weak self] in
                self?.beginKeyboardSelection()
            }
        }
    }

    private let mouseLocation: () -> NSPoint
    private var hoverActivationMouseLocation: NSPoint
    private var pointerHasMoved = false
    private weak var hoverHandler: (any PaletteHoverHandling)?

    var hoverMouseLocation: NSPoint { mouseLocation() }

    func beginPresentation() {
        beginKeyboardSelection()
    }

    func registerHoverHandler(_ handler: any PaletteHoverHandling) {
        hoverHandler = handler
    }

    /// Keyboard input owns selection until the physical pointer moves again. Keep this
    /// in the panel so asynchronous results and an empty list cannot reset ownership.
    func beginKeyboardSelection() {
        hoverActivationMouseLocation = hoverMouseLocation
        pointerHasMoved = false
        hoverHandler?.clearHover()
    }

    /// A stationary pointer cannot override a presentation or keyboard selection.
    var allowsHoverSelection: Bool {
        guard isVisible else { return false }
        if !pointerHasMoved {
            let location = hoverMouseLocation
            pointerHasMoved = hypot(
                location.x - hoverActivationMouseLocation.x,
                location.y - hoverActivationMouseLocation.y) >= 1
        }
        return pointerHasMoved
    }

    private weak var searchField: NSTextField?
    private var pendingSearchFocusRequest: UUID?
    private var windowDrag: PaletteWindowDrag?

    private static let relevantModifiers: NSEvent.ModifierFlags = [
        .command, .option, .control, .shift,
    ]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown { beginKeyboardSelection() }
        // Palette commands (including deletion undo) take priority over the application's Edit menu.
        if event.type == .keyDown, route(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, isWindowDragRegion(event.locationInWindow),
            paletteViewModel?.menuOpen != true
        {
            windowDrag = PaletteWindowDrag(
                window: self, pointer: convertPoint(toScreen: event.locationInWindow))
            return
        }
        if let windowDrag {
            if event.type == .leftMouseDragged {
                windowDrag.update(pointer: convertPoint(toScreen: event.locationInWindow))
                return
            }
            if event.type == .leftMouseUp {
                windowDrag.end()
                self.windowDrag = nil
                return
            }
        }
        if event.type == .keyDown { beginKeyboardSelection() }
        if event.type == .keyDown, route(event) { return }
        if event.type == .keyDown { _ = moveSearchFocusForTyping(event) }
        super.sendEvent(event)
        // Keep movement delivery independent of tracking-area invalidation during list
        // updates and content reattachment. The table still owns hit testing and visual hover feedback.
        if event.type == .mouseMoved {
            hoverHandler?.mouseMoved(with: event)
        }
    }

    override func orderOut(_ sender: Any?) {
        windowDrag?.end()
        windowDrag = nil
        super.orderOut(sender)
    }

    private func isWindowDragRegion(_ point: CGPoint) -> Bool {
        // Keep search editing and filter controls outside the window drag surface
        let headerBottom = frame.height - Theme.Size.headerHeight - Theme.Size.headerPadding
        return point.y >= frame.height - Theme.Size.headerPadding
            || (point.y >= headerBottom && (point.x < 16 || point.x > frame.width - 16))
    }

    private func route(_ event: NSEvent) -> Bool {
        guard let paletteViewModel else { return false }
        // Candidate selection and composition keys belong to the active input method.
        if let editor = firstResponder as? NSTextView, editor.hasMarkedText() {
            return false
        }
        let keyCode = Int(event.keyCode)
        let modifiers = event.modifierFlags.intersection(Self.relevantModifiers)
        if let handled = routeStackNaming(
            keyCode: keyCode, modifiers: modifiers, viewModel: paletteViewModel)
        {
            return handled
        }
        let shortcut = KeyboardShortcuts.Shortcut(event: event)

        if modifiers == .shift, keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter {
            return handleOnce(.pasteKeepingOpen, event: event)
        }

        if modifiers == .command, keyCode == kVK_ANSI_Z {
            if event.isARepeat { return true }
            if !paletteViewModel.menuOpen {
                if let editor = firstResponder as? NSTextView, editor.hasMarkedText() {
                    return false
                }
                if !paletteViewModel.prefersDeletionUndo, undoTextEdit() { return true }
            }
            return paletteViewModel.handle(.undoDelete)
        }

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

        // The action menu's Delete row: fixed at Control-Backspace, not user-recordable.
        if modifiers == .control, keyCode == kVK_Delete {
            return handleOnce(.delete, event: event)
        }

        if modifiers == .command, keyCode == kVK_ANSI_C,
            canCopySelectedText(viewModel: paletteViewModel),
            copySelectedText()
        {
            return true
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
            case kVK_ANSI_Z:
                _ = undoTextEdit()
                return true
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
        setSearchCaretHidden(paletteViewModel?.menuOpen == true)
        return true
    }

    private func setSearchCaretHidden(_ hidden: Bool) {
        guard let editor = searchField?.currentEditor() as? NSTextView,
            firstResponder === editor
        else { return }
        editor.insertionPointColor = hidden ? .clear : .textColor
        editor.updateInsertionPointStateAndRestartTimer(!hidden)
    }

    /// Search edits take precedence after typing; a just-deleted entry takes precedence
    /// even when it was deleted from filtered results with the search editor focused.
    private func undoTextEdit() -> Bool {
        guard let editor = firstResponder as? NSTextView, editor.isEditable,
            !editor.hasMarkedText(), let manager = editor.undoManager, manager.canUndo
        else { return false }
        manager.undo()
        return true
    }

    /// Keep palette editing behind its modal actions and identify copied text as Kit content
    private func handleEditingShortcut(_ keyCode: Int) -> Bool {
        guard paletteViewModel?.menuOpen != true || paletteViewModel?.isNamingStack == true,
            let editor = firstResponder as? NSTextView
        else {
            return false
        }

        switch keyCode {
        case kVK_ANSI_C:
            return copySelectedText()
        case kVK_ANSI_X:
            guard editor.isEditable, editor.selectedRange().length > 0 else { return true }
            let pasteboard = NSPasteboard.general
            let previousChangeCount = pasteboard.changeCount
            editor.cut(nil)
            if pasteboard.changeCount != previousChangeCount {
                Paster.markCurrentPasteboardSelection()
            }
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

    private func canCopySelectedText(viewModel: PaletteViewModel) -> Bool {
        guard !viewModel.menuOpen || viewModel.isNamingStack else { return false }
        guard let editor = firstResponder as? NSTextView else { return false }
        guard (editor as? PreviewTextView)?.canCopyCurrentSelection != false else {
            return false
        }
        return editor.selectedRange().length > 0
    }

    @discardableResult
    private func copySelectedText() -> Bool {
        guard paletteViewModel?.menuOpen != true || paletteViewModel?.isNamingStack == true,
            let editor = firstResponder as? NSTextView,
            (editor as? PreviewTextView)?.canCopyCurrentSelection != false,
            editor.selectedRange().length > 0
        else { return false }

        let pasteboard = NSPasteboard.general
        let previousChangeCount = pasteboard.changeCount
        editor.copy(nil)
        if pasteboard.changeCount != previousChangeCount {
            Paster.markCurrentPasteboardSelection()
        }
        return true
    }

    private func moveSearchFocusForTyping(_ event: NSEvent) -> Bool {
        guard paletteViewModel?.menuOpen != true,
            paletteViewModel?.isNamingStack != true,
            firstResponder is PreviewTextView || firstResponder === self,
            startsSearchTyping(event),
            let searchField,
            searchField.isEnabled
        else { return false }

        guard makeFirstResponder(searchField) else { return false }
        pendingSearchFocusRequest = nil
        setSearchCaretHidden(false)
        return true
    }

    /// A dead key can begin with an empty or control character, so fall back to the layout's
    /// unmodified key while still rejecting navigation and function-key private-use scalars
    private func startsSearchTyping(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control]).isEmpty else {
            return false
        }
        if let characters = event.characters,
            characters.unicodeScalars.contains(where: Self.isFunctionKeyScalar)
        {
            return false
        }
        let candidates = [event.characters, event.charactersIgnoringModifiers]
        return candidates.contains { text in
            guard let text, !text.isEmpty else { return false }
            return text.unicodeScalars.allSatisfy(Self.isPrintableTypingScalar)
        }
    }

    private static func isPrintableTypingScalar(_ scalar: Unicode.Scalar) -> Bool {
        !CharacterSet.controlCharacters.contains(scalar)
            && !isFunctionKeyScalar(scalar)
    }

    private static func isFunctionKeyScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0xF700...0xF8FF).contains(Int(scalar.value))
    }

    init<Content: View>(
        rootView: Content,
        mouseLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation }
    ) {
        self.mouseLocation = mouseLocation
        hoverActivationMouseLocation = mouseLocation()
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

        let glass = NSGlassEffectView(frame: frame)
        glass.autoresizingMask = [.width, .height]
        glass.style = .regular
        glass.cornerRadius = Theme.Radius.panel
        glass.contentView = hosting

        // Clip the window corners so its shadow follows the glass surface
        let shell = NSView(frame: frame)
        shell.autoresizingMask = [.width, .height]
        shell.wantsLayer = true
        shell.layer?.backgroundColor = NSColor.clear.cgColor
        shell.layer?.cornerRadius = Theme.Radius.panel
        shell.layer?.masksToBounds = true
        shell.addSubview(glass)
        contentView = shell
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class TransparentPaletteHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}
