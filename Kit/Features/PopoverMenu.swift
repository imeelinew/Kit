import AppKit
import QuartzCore
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
    let title: String
    /// User-entered stack names stay literal so they are not looked up as localization keys.
    var verbatimTitle: String? = nil
    var pasteTargetName: String? = nil
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
            title = "About Kit"
            icon = .symbol("info")
        case .checkForUpdates:
            title = "Check for Updates"
            icon = .symbol("arrow.triangle.2.circlepath")
            isEnabled = AppCore.shared.updateService.canCheckForUpdates
        case .settings:
            title = "Settings…"
            icon = .symbol("gearshape")
            shortcut = "⌘,"
        case .quit:
            title = "Quit Kit…"
            icon = .symbol("power")
            shortcut = "⌘Q"
            isDestructive = true
        case .paste:
            title = "Paste"
            pasteTargetName = target?.name
            icon = PopoverMenuIcon.paste(target)
            shortcut = "↵"
            isEnabled = target != nil && AppCore.shared.hasPasteTarget
        case .pasteKeepingOpen:
            title = "Paste & Keep Window Open"
            icon = PopoverMenuIcon.paste(target)
            shortcut = "⇧↵"
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
            shortcut = "⌃⌫"
        case .addToStack(let item):
            let currentStack = AppCore.shared.clipboardStore.stackID(for: item.id)
            title = currentStack == nil ? "Add to Stack" : "Move to Another Stack"
            icon = .symbol(currentStack == nil ? "rectangle.stack.badge.plus" : "arrow.left.arrow.right")
            isEnabled = AppCore.shared.clipboardStore.stacks.contains { $0.id != currentStack }
        case .removeFromStack:
            title = "Remove from Stack"
            icon = .symbol("rectangle.stack.badge.minus")
        case .assignToStack(let item, let stack):
            title = "Add to Stack"
            verbatimTitle = stack.name
            icon = nil
            isChecked = AppCore.shared.clipboardStore.stackID(for: item.id) == stack.id
        case .setKindFilter(let filter):
            title = filter.kind?.typeLabel ?? "All Types"
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
            title = "Rename…"
            icon = nil
        case .deleteStack:
            title = "Delete Stack…"
            icon = nil
            isDestructive = true
        }
    }
}

/// One bridge owns menu placement, dismissal, rows and naming inside the palette
struct PaletteMenuOverlay: NSViewRepresentable {
    let overlay: PaletteOverlay
    let items: [PopoverMenuItem]
    @Binding var selection: Int
    let stackControlWidth: CGFloat
    let namingRow: Int?
    let namingEdit: StackNameEdit?
    @Binding var namingText: String
    let reduceMotion: Bool
    let onActivate: (Int) -> Void
    let onRightClick: (Int) -> Void
    let onClose: () -> Void

    func makeNSView(context: Context) -> PaletteMenuOverlayView { PaletteMenuOverlayView() }

    func updateNSView(_ view: PaletteMenuOverlayView, context: Context) {
        view.update(
            overlay: overlay, items: items, selection: selection,
            stackControlWidth: stackControlWidth, namingRow: namingRow, namingEdit: namingEdit,
            namingText: namingText, locale: context.environment.locale, reduceMotion: reduceMotion,
            onSelect: { selection = $0 }, onActivate: onActivate,
            onRightClick: onRightClick, onNameChange: { namingText = $0 }, onClose: onClose)
    }
}

final class PaletteMenuOverlayView: NSView {
    private var menuView: NativePopoverMenu?
    private var placement: Int?
    private var presentedOverlay: PaletteOverlay = .none
    private var presentationPending = false
    private var presentationScheduled = false
    private var stackControlWidth: CGFloat = 0
    private var onClose: (() -> Void)?
    private var open = false
    private var reduceMotion = false
    private var dismissalMonitor: Any?
    private var dismissingButton: Int?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        if let dismissalMonitor { NSEvent.removeMonitor(dismissalMonitor) }
    }

    func update(
        overlay: PaletteOverlay, items: [PopoverMenuItem], selection: Int,
        stackControlWidth: CGFloat, namingRow: Int?, namingEdit: StackNameEdit?,
        namingText: String, locale: Locale, reduceMotion: Bool,
        onSelect: @escaping (Int) -> Void, onActivate: @escaping (Int) -> Void,
        onRightClick: @escaping (Int) -> Void, onNameChange: @escaping (String) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.stackControlWidth = stackControlWidth
        self.onClose = onClose
        self.reduceMotion = reduceMotion
        open = overlay.isOpen
        layer?.backgroundColor = NSColor.black.withAlphaComponent(open ? 0.001 : 0).cgColor
        let nextPlacement: Int?
        switch overlay {
        case .none: nextPlacement = nil
        case .appMenu: nextPlacement = 0
        case .actions, .addToStack: nextPlacement = 1
        case .typeFilter: nextPlacement = 2
        case .stackFilter, .stackActions: nextPlacement = 3
        }
        let changed = overlay != presentedOverlay
        if changed, let old = menuView {
            menuView = nil
            if presentationPending {
                old.removeFromSuperview()
            } else {
                PaletteMenuTransition.animate(
                    old, appearing: false, placement: placement ?? 0, reduceMotion: reduceMotion)
            }
            presentationPending = false
        }
        presentedOverlay = overlay
        placement = nextPlacement
        guard nextPlacement != nil else { return }
        if menuView == nil {
            let menuView = NativePopoverMenu()
            menuView.alphaValue = reduceMotion ? 1 : 0
            addSubview(menuView)
            self.menuView = menuView
            presentationPending = true
        }
        menuView?.update(
            items: items, selection: selection, namingRow: namingRow, namingEdit: namingEdit,
            namingText: namingText, locale: locale, onSelect: onSelect, onActivate: onActivate,
            onRightClick: nextPlacement == 3 ? onRightClick : nil, onNameChange: onNameChange)
        needsLayout = true
        layoutSubtreeIfNeeded()
        schedulePresentation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let dismissalMonitor {
            NSEvent.removeMonitor(dismissalMonitor)
            self.dismissalMonitor = nil
        }
        dismissingButton = nil
        if window != nil {
            dismissalMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp,
                           .leftMouseDragged, .rightMouseDragged]
            ) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    self?.consumesDismissal(event) ?? false
                }
                return consumed ? nil : event
            }
        }
        schedulePresentation()
    }

    private func consumesDismissal(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        if dismissingButton == event.buttonNumber {
            switch event.type {
            case .leftMouseUp, .rightMouseUp:
                dismissingButton = nil
                return true
            case .leftMouseDragged, .rightMouseDragged:
                return true
            case .leftMouseDown, .rightMouseDown:
                dismissingButton = nil
            default:
                break
            }
        }
        guard open, event.type == .leftMouseDown || event.type == .rightMouseDown else {
            return false
        }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), menuView?.frame.contains(point) != true else { return false }
        // SwiftUI can retain the hovered button's hit target until the pointer moves
        // Own the entire outside click before routing, including the release after closing
        dismissingButton = event.buttonNumber
        onClose?()
        return true
    }

    override func layout() {
        super.layout()
        guard let menuView, let placement else { return }
        let height = menuView.menuHeight
        let top = Theme.Size.headerPadding + Theme.Size.headerHeight
        let trailing = placement == 2
            ? Theme.Spacing.md * 3 + stackControlWidth : Theme.Spacing.md * 2
        menuView.frame = NSRect(
            x: placement == 0 ? 8 : bounds.width - Theme.Size.menuWidth - (placement == 1 ? 8 : trailing),
            y: placement < 2 ? bounds.height - height - 8 : top,
            width: Theme.Size.menuWidth, height: height)
        schedulePresentation()
    }

    private func schedulePresentation() {
        guard presentationPending, !presentationScheduled, window != nil else { return }
        presentationScheduled = true
        // Representable updates can precede window attachment and the first layer layout
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { presentationScheduled = false }
            guard presentationPending, let menuView, let placement, menuView.window != nil else { return }
            needsLayout = true
            layoutSubtreeIfNeeded()
            menuView.layoutSubtreeIfNeeded()
            guard !menuView.bounds.isEmpty else { return }
            presentationPending = false
            PaletteMenuTransition.animate(
                menuView, appearing: true, placement: placement, reduceMotion: reduceMotion)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard open, let superview else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if let menuView, menuView.frame.contains(local) {
            return menuView.hitTest(local) ?? menuView
        }
        return self
    }

    override func mouseDown(with event: NSEvent) { onClose?() }
    override func rightMouseDown(with event: NSEvent) { onClose?() }

}

/// Every overlay menu uses the same reversible opacity and scale transition
@MainActor
private enum PaletteMenuTransition {
    static func animate(_ view: NSView, appearing: Bool, placement: Int, reduceMotion: Bool) {
        guard view.window != nil, !reduceMotion, let layer = view.layer else {
            view.alphaValue = appearing ? 1 : 0
            if !appearing { view.removeFromSuperview() }
            return
        }
        let scale = Theme.Motion.menuScale
        let anchor = CGPoint(x: placement == 0 ? 0 : view.bounds.width,
                             y: placement < 2 ? view.bounds.height : 0)
        let pivot = CGPoint(x: anchor.x - layer.anchorPoint.x * view.bounds.width,
                            y: anchor.y - layer.anchorPoint.y * view.bounds.height)
        var small = CATransform3DMakeTranslation(pivot.x * (1 - scale), pivot.y * (1 - scale), 0)
        small = CATransform3DScale(small, scale, scale, 1)
        let presentation = layer.presentation()
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = appearing ? 0 : (presentation?.opacity ?? 1)
        opacity.toValue = appearing ? 1 : 0
        let transform = CABasicAnimation(keyPath: "transform")
        transform.fromValue = NSValue(caTransform3D:
            appearing ? small : (presentation?.transform ?? CATransform3DIdentity))
        transform.toValue = NSValue(caTransform3D: appearing ? CATransform3DIdentity : small)
        let transition = CAAnimationGroup()
        opacity.duration = Theme.Motion.menuDuration
        transform.duration = Theme.Motion.menuDuration
        transition.animations = [opacity, transform]
        transition.duration = Theme.Motion.menuDuration
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock {
            DispatchQueue.main.async {
                if !appearing { view.removeFromSuperview() }
            }
        }
        // Final model values prevent a flash when the explicit animation is removed
        view.alphaValue = appearing ? 1 : 0
        layer.transform = appearing ? CATransform3DIdentity : small
        layer.add(transition, forKey: "paletteMenuTransition")
        CATransaction.commit()
    }
}

private final class NativePopoverMenu: NSGlassEffectView {
    private let rowsView = FlippedMenuView()
    private var rows: [NativeMenuRow] = []
    private var nameRow: NativeStackNameRow?
    private var namingEdit: StackNameEdit?
    private var namingRow: Int?
    override var isFlipped: Bool { true }

    var menuHeight: CGFloat {
        Theme.Spacing.sm * 2 + rows.enumerated().reduce(CGFloat.zero) { result, entry in
            result + (entry.offset == namingRow ? NativeStackNameRow.rowHeight : entry.element.rowHeight)
        } + CGFloat(max(0, rows.count - 1))
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        style = .regular
        cornerRadius = Theme.Radius.menuPanel
        wantsLayer = true
        contentView = rowsView
        setAccessibilityElement(true)
        setAccessibilityRole(.menu)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(
        items: [PopoverMenuItem], selection: Int, namingRow: Int?, namingEdit: StackNameEdit?,
        namingText: String, locale: Locale, onSelect: @escaping (Int) -> Void,
        onActivate: @escaping (Int) -> Void, onRightClick: ((Int) -> Void)?,
        onNameChange: @escaping (String) -> Void
    ) {
        if rows.count != items.count {
            rows.forEach { $0.removeFromSuperview() }
            rows = items.map { _ in
                let row = NativeMenuRow()
                rowsView.addSubview(row)
                return row
            }
        }
        let reservesIcons = items.contains { $0.icon != nil }
        for (index, item) in items.enumerated() {
            let row = rows[index]
            row.configure(item: item, locale: locale, reservesIcons: reservesIcons)
            row.selected = index == selection
            row.onHover = { onSelect(index) }
            row.onActivate = { onActivate(index) }
            row.onRightClick = onRightClick.map { handler in { handler(index) } }
            row.isHidden = index == namingRow
        }
        if self.namingEdit != namingEdit || self.namingRow != namingRow {
            nameRow?.removeFromSuperview()
            nameRow = nil
            if namingRow != nil {
                let row = NativeStackNameRow()
                rowsView.addSubview(row)
                nameRow = row
            }
        }
        self.namingEdit = namingEdit
        self.namingRow = namingRow
        nameRow?.update(text: namingText, edit: namingEdit, locale: locale, onChange: onNameChange)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var y = Theme.Spacing.sm
        for (index, row) in rows.enumerated() {
            let height = index == namingRow ? NativeStackNameRow.rowHeight : row.rowHeight
            let rect = NSRect(x: Theme.Spacing.sm, y: y,
                              width: bounds.width - Theme.Spacing.sm * 2, height: height)
            row.frame = rect
            if index == namingRow { nameRow?.frame = rect }
            y += height + 1
        }
    }
}

private final class FlippedMenuView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
}

private final class NativeStackNameRow: NSView, NSTextFieldDelegate {
    private let field = NSTextField(string: "")
    private var onChange: ((String) -> Void)?
    private var didFocus = false
    private var focusScheduled = false
    static var rowHeight: CGFloat { ceil(NSFont.preferredFont(forTextStyle: .body).ascender - NSFont.preferredFont(forTextStyle: .body).descender + NSFont.preferredFont(forTextStyle: .body).leading) + 16 }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .preferredFont(forTextStyle: .body)
        field.textColor = .labelColor
        field.delegate = self
        field.cell?.sendsActionOnEndEditing = false
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(text: String, edit: StackNameEdit?, locale: Locale, onChange: @escaping (String) -> Void) {
        self.onChange = onChange
        field.placeholderString = AppLocalization.string("Name", locale: locale)
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() != true, field.stringValue != text {
            field.stringValue = text
        }
        guard !didFocus, !focusScheduled else { return }
        focusScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            focusScheduled = false
            guard !didFocus, let window, (window as? PalettePanel)?.paletteViewModel?.isNamingStack == true,
                  window.makeFirstResponder(field) else { return }
            didFocus = true
            if let editor = window.fieldEditor(true, for: field) as? NSTextView {
                editor.insertionPointColor = .textColor
                if case .rename = edit { editor.selectAll(nil) }
            }
        }
    }

    override func layout() {
        super.layout()
        field.frame = bounds.insetBy(dx: 8, dy: 8)
    }

    func controlTextDidChange(_ notification: Notification) { onChange?(field.stringValue) }
}

private final class NativeMenuRow: NSControl {
    private var title = ""
    private var icon: NSImage?
    private var symbol = false
    private var shortcut: [String] = []
    private var checked = false
    private var destructive = false
    private var reservesIcons = false
    var selected = false { didSet { if oldValue != selected { needsDisplay = true } } }
    var onHover: (() -> Void)?
    var onActivate: (() -> Void)?
    var onRightClick: (() -> Void)?
    private var didTick = false
    private var lastPointerLocation = NSEvent.mouseLocation
    private let rowFont = NSFont.preferredFont(forTextStyle: .body)
    private let capFont = NSFont.preferredFont(forTextStyle: .caption1)
    var rowHeight: CGFloat {
        max(ceil(rowFont.ascender - rowFont.descender + rowFont.leading), reservesIcons ? Theme.Size.menuIcon : 0,
            !shortcut.isEmpty ? Theme.Size.keyCap : 0) + Theme.Spacing.md * 2
    }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    func configure(item: PopoverMenuItem, locale: Locale, reservesIcons: Bool) {
        if let verbatim = item.verbatimTitle { title = verbatim }
        else if let target = item.pasteTargetName {
            title = String(format: AppLocalization.string("Paste to %@", locale: locale), target)
        } else { title = AppLocalization.string(item.title, locale: locale) }
        self.reservesIcons = reservesIcons
        destructive = item.isDestructive
        isEnabled = item.isEnabled
        checked = item.isChecked
        shortcut = item.shortcut.map { $0.map(String.init) } ?? []
        switch item.icon {
        case .symbol(let name):
            let configuration = NSImage.SymbolConfiguration(pointSize: rowFont.pointSize, weight: .regular)
                .applying(.init(hierarchicalColor: destructive ? .systemRed : .secondaryLabelColor))
            icon = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            symbol = true
        case .file(let path): icon = IconCache.icon(forFile: path); symbol = false
        case nil: icon = nil; symbol = false
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(title)
        setAccessibilityValue(checked ? "✓" : nil)
        setAccessibilityEnabled(isEnabled)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if selected {
            NSColor.labelColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: Theme.Radius.menuRow, yRadius: Theme.Radius.menuRow).fill()
        }
        let opacity: CGFloat = isEnabled ? 1 : 0.5
        if let icon {
            let rect = NSRect(x: 8, y: (bounds.height - 20) / 2, width: 20, height: 20)
            if symbol {
                // Symbol images retain their configured hierarchy when drawn at their natural aspect ratio
                let size = icon.size
                let scale = min(1, rect.width / size.width, rect.height / size.height)
                let fitted = NSRect(x: rect.midX - size.width * scale / 2, y: rect.midY - size.height * scale / 2,
                                    width: size.width * scale, height: size.height * scale)
                icon.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: opacity,
                          respectFlipped: true, hints: nil)
            } else {
                icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: opacity,
                          respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            }
        }
        var trailing = bounds.width - 8
        if checked {
            let image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: rowFont.pointSize, weight: .regular)
                    .applying(.init(hierarchicalColor: .secondaryLabelColor)))
            if let image {
                image.draw(in: NSRect(x: trailing - 10 - image.size.width / 2,
                    y: (bounds.height - image.size.height) / 2, width: image.size.width, height: image.size.height),
                    from: .zero, operation: .sourceOver, fraction: opacity, respectFlipped: true, hints: nil)
            }
            trailing -= 26
        } else {
            for glyph in shortcut.reversed() {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: capFont, .foregroundColor: NSColor.labelColor.withAlphaComponent(0.60 * opacity)]
                let size = (glyph as NSString).size(withAttributes: attributes)
                let width = max(18, size.width + 8)
                let rect = NSRect(x: trailing - width, y: (bounds.height - 18) / 2, width: width, height: 18)
                NSColor.labelColor.withAlphaComponent(0.20 * opacity).setStroke()
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5.5, yRadius: 5.5)
                path.lineWidth = 1
                path.stroke()
                (glyph as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2,
                    y: rect.midY - size.height / 2 + (glyph == "↵" ? 1.1 : 0)), withAttributes: attributes)
                trailing -= width + 2
            }
            if !shortcut.isEmpty { trailing -= 4 }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let leading: CGFloat = reservesIcons ? 34 : 8
        let height = ceil(rowFont.ascender - rowFont.descender + rowFont.leading)
        (title as NSString).draw(in: NSRect(x: leading, y: (bounds.height - height) / 2,
            width: max(0, trailing - leading), height: height), withAttributes: [
                .font: rowFont, .foregroundColor: (destructive ? NSColor.systemRed : .labelColor).withAlphaComponent(opacity),
                .paragraphStyle: paragraph])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hover(event) }
    override func mouseMoved(with event: NSEvent) { hover(event) }
    override func mouseExited(with event: NSEvent) {
        didTick = false
        lastPointerLocation = NSEvent.mouseLocation
    }

    private func hover(_ event: NSEvent) {
        guard isEnabled else { return }
        onHover?()
        let location = NSEvent.mouseLocation
        guard !didTick, location != lastPointerLocation,
              event.type == .mouseMoved || event.type == .mouseEntered,
              let panel = event.window as? PalettePanel, panel.allowsHoverSelection else { return }
        didTick = true
        PaletteHaptics.tick()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.modifierFlags.contains(.control) { onRightClick?(); return }
        guard let window else { return }
        // Match a plain button by activating only when the pointer is released inside the row
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp {
                if bounds.contains(convert(next.locationInWindow, from: nil)) { onActivate?() }
                return
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) { if isEnabled { onRightClick?() } }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onActivate?()
        return true
    }
}

/// App icons outside the menu keep the existing SwiftUI bar rendering
struct MenuFileIcon: View {
    let path: String

    var body: some View {
        Image(nsImage: IconCache.icon(forFile: path))
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .frame(width: Theme.Size.menuIcon, height: Theme.Size.menuIcon)
    }
}
