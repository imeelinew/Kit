import AppKit
import Carbon.HIToolbox
import SwiftUI

@testable import Kit

@main
@MainActor
struct PaletteFocusTests {
    static func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    static func fields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
    }

    static func key(_ code: Int, characters: String, in panel: PalettePanel) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code))!
        panel.sendEvent(event)
    }

    static func main() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kit-focus-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(directory: directory)
        let core = AppCore(clipboardStore: store)
        let vm = core.palette
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for style in [PaletteVisualStyle.frosted, .liquid] {
                vm.query = ""
                let panel = PalettePanel(
                    rootView: RootPaletteView(vm: vm, store: store, settings: core.settings),
                    visualStyle: style)
                panel.appearance = NSAppearance(named: appearance)
                panel.paletteViewModel = vm
                panel.makeKeyAndOrderFront(nil)
                defer { panel.close() }
                try await settle()
                panel.requestSearchFocus()
                try await settle()
                let search = fields(in: panel.contentView!).first {
                    $0.accessibilityLabel() != nil
                }!
                precondition(
                    search.currentEditor() === panel.firstResponder, "Opening focuses search")
                key(kVK_Space, characters: " ", in: panel)
                precondition(vm.query.isEmpty, "Space with an empty query stays a palette command")

                vm.toggleStackFilter()
                try await settle()
                vm.beginStackName()
                try await settle()
                let naming = fields(in: panel.contentView!).first {
                    $0 !== search && $0.isEditable
                }!
                precondition(
                    naming.currentEditor() === panel.firstResponder, "New Stack focuses its name")
                key(kVK_ANSI_A, characters: "a", in: panel)
                precondition(
                    vm.stackNameDraft == "a" && vm.query.isEmpty, "Typing edits only the name")
                key(kVK_Escape, characters: "\u{1b}", in: panel)
                try await settle()
                precondition(
                    !vm.isNamingStack && vm.overlay == .stackFilter, "First Esc cancels only naming"
                )
                key(kVK_Escape, characters: "\u{1b}", in: panel)
                try await settle()
                precondition(!vm.menuOpen, "Second Esc closes the menu")
                precondition(
                    search.currentEditor() === panel.firstResponder,
                    "Closing returns focus to search")
                precondition(
                    (panel.firstResponder as? NSTextView)?.insertionPointColor != .clear,
                    "The search caret is visible again")
                key(kVK_ANSI_A, characters: "a", in: panel)
                precondition(vm.query == "a", "Typing after two Esc keys searches immediately")
                key(kVK_Space, characters: " ", in: panel)
                precondition(vm.query == "a ", "Space after English text reaches search")
                key(kVK_Delete, characters: "\u{7f}", in: panel)
                precondition(vm.query == "a", "Backspace still edits English search text")

                vm.toggleStackFilter()
                vm.beginStackName()
                try await settle()
                vm.closeMenu()  // The outside-click dismissal path.
                try await settle()
                precondition(
                    search.currentEditor() === panel.firstResponder && vm.query == "a",
                    "Outside dismissal restores focus and preserves the query")

                vm.toggleStackFilter()
                vm.beginStackName()
                try await settle()
                key(kVK_Return, characters: "\r", in: panel)
                precondition(vm.isNamingStack, "An empty name stays in editing")
                vm.stackNameDraft = "Focus test \(appearance.rawValue) \(style)"
                try await settle()
                key(kVK_Return, characters: "\r", in: panel)
                try await settle()
                precondition(
                    !vm.menuOpen && search.currentEditor() === panel.firstResponder,
                    "Creating a Stack restores search focus")

                let stack = store.stacks.first { $0.id == vm.stackFilter }!
                vm.beginRename(stack)
                try await settle()
                precondition(search.currentEditor() == nil, "Renaming owns focus")
                key(kVK_Escape, characters: "\u{1b}", in: panel)
                // Consecutive Esc events also work without waiting for the view update.
                key(kVK_Escape, characters: "\u{1b}", in: panel)
                try await settle()
                precondition(
                    search.currentEditor() === panel.firstResponder,
                    "Rapid Esc from rename restores search focus")

                vm.toggleStackFilter()
                vm.beginStackName()
                vm.closeMenu()
                try await settle()
                precondition(
                    search.currentEditor() === panel.firstResponder,
                    "A dismissed naming field cannot steal focus on a later run-loop turn")
                let editor = search.currentEditor() as! NSTextView
                editor.setMarkedText(
                    "ni", selectedRange: NSRange(location: 2, length: 0),
                    replacementRange: NSRange(location: NSNotFound, length: 0))
                precondition(editor.hasMarkedText(), "Search editor holds IME composition")
                key(kVK_Escape, characters: "\u{1b}", in: panel)
                precondition(vm.query == "a", "IME Escape does not clear the search query")
                print(
                    "PASS: \(appearance.rawValue), \(style): Esc, English space, IME composition, focus and naming"
                )
            }
        }
    }
}
