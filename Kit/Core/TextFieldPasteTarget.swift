import AppKit

/// A field in Kit that was editing when the clipboard panel opened. Retain its selection, not its text.
@MainActor
final class TextFieldPasteTarget {
    private weak var window: NSWindow?
    private weak var field: NSTextField?
    private var selection: NSRange

    init?(window: NSWindow?) {
        guard let window, let editor = window.firstResponder as? NSTextView,
            let field = editor.delegate as? NSTextField,
            field.currentEditor() === editor, field.isEditable, field.isEnabled
        else { return nil }
        self.window = window
        self.field = field
        selection = editor.selectedRange()
    }

    var isAvailable: Bool {
        guard let window, let field else { return false }
        return window.isVisible && field.window === window && field.isEditable && field.isEnabled
    }

    @discardableResult
    func restoreEditing(activateWindow: Bool) -> Bool {
        guard isAvailable, let window, let field else { return false }
        if activateWindow { window.makeKeyAndOrderFront(nil) }
        guard window.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView
        else { return false }
        let length = (editor.string as NSString).length
        let start = min(selection.location, length)
        editor.setSelectedRange(NSRange(location: start, length: min(selection.length, length - start)))
        return true
    }

    func paste() -> Bool {
        guard isAvailable, let field, let editor = field.currentEditor() as? NSTextView,
            window?.firstResponder === editor
        else { return false }
        editor.paste(nil)
        selection = editor.selectedRange()
        return true
    }
}
