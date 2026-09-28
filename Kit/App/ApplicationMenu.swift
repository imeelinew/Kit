import AppKit
import Combine

/// Install the standard editing commands required by AppKit field editors in our manual app lifecycle.
@MainActor
final class ApplicationMenu: NSObject, NSMenuItemValidation {
    private var languageObserver: AnyCancellable?

    func install() {
        languageObserver = AppCore.shared.settings.$language.sink { [weak self] language in
            self?.build(locale: language.locale)
        }
    }

    private func build(locale: Locale) {
        let mainMenu = NSMenu()
        let appMenu = NSMenu(title: "Kit")
        let editMenu = NSMenu(title: AppLocalization.string("Edit", locale: locale))
        for menu in [appMenu, editMenu] {
            let item = NSMenuItem()
            item.submenu = menu
            mainMenu.addItem(item)
        }

        func add(
            _ title: String, action: Selector, key: String?, to menu: NSMenu,
            target: AnyObject? = nil, modifiers: NSEvent.ModifierFlags = .command
        ) {
            let item = NSMenuItem(
                title: AppLocalization.string(title, locale: locale),
                action: action, keyEquivalent: key ?? "")
            item.target = target
            item.keyEquivalentModifierMask = modifiers
            menu.addItem(item)
        }

        // The menu bar only exists while the settings window is key, so there is no
        // Settings item; About routes to the settings window's About page.
        add("About Kit", action: #selector(about(_:)), key: nil, to: appMenu, target: self)
        appMenu.addItem(.separator())
        add("Quit Kit…", action: #selector(quit(_:)), key: "q", to: appMenu, target: self)

        add("Undo", action: Selector(("undo:")), key: "z", to: editMenu)
        add("Redo", action: Selector(("redo:")), key: "z", to: editMenu, modifiers: [.command, .shift])
        editMenu.addItem(.separator())
        add("Cut", action: #selector(cutText(_:)), key: "x", to: editMenu, target: self)
        add("Copy", action: #selector(copyText(_:)), key: "c", to: editMenu, target: self)
        add("Paste", action: #selector(NSText.paste(_:)), key: "v", to: editMenu)
        editMenu.addItem(.separator())
        add("Delete to Beginning of Line", action: #selector(NSResponder.deleteToBeginningOfLine(_:)),
            key: "\u{8}", to: editMenu)
        add("Select All", action: #selector(NSText.selectAll(_:)), key: "a", to: editMenu)
        NSApp.mainMenu = mainMenu
    }

    private var editor: NSTextView? { NSApp.keyWindow?.firstResponder as? NSTextView }

    @objc private func copyText(_ sender: Any?) {
        guard let editor, editor.selectedRange().length > 0 else { return }
        if editor.delegate is NSSecureTextField {
            // API keys intentionally support copying the selection while retaining secure entry.
            // One write declares the string together with every sensitive marker, so other
            // clipboard managers conceal it and Kit's own policy skips it without the
            // second pasteboard change a post-hoc marker would need.
            let value = editor.string as NSString
            let selection = editor.selectedRange()
            guard NSMaxRange(selection) <= value.length else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.declareTypes(
                [.string] + Array(ClipboardCapturePolicy.sensitiveTypes)
                    + [ClipboardCapturePolicy.internalType],
                owner: nil)
            pasteboard.setString(value.substring(with: selection), forType: .string)
        } else {
            editor.copy(sender)
            Paster.markCurrentPasteboardInternal()
        }
    }

    @objc private func cutText(_ sender: Any?) {
        guard let editor, editor.isEditable, editor.selectedRange().length > 0 else { return }
        copyText(sender)
        editor.deleteBackward(sender)
    }

    @objc private func about(_ sender: Any?) { AppCore.shared.showSettings(tab: .about) }

    @objc private func quit(_ sender: Any?) { AppCore.shared.requestQuit() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copyText(_:)):
            return (editor?.selectedRange().length ?? 0) > 0
        case #selector(cutText(_:)):
            return editor?.isEditable == true && (editor?.selectedRange().length ?? 0) > 0
        default:
            return true
        }
    }
}
