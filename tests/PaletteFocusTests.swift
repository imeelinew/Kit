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

    /// Render the production cell over a solid background so vibrancy does not hide the ink.
    static func checkPlaceholder(_ field: NSTextField, named name: String) throws {
        let image = NSImage(size: field.bounds.size)
        field.effectiveAppearance.performAsCurrentDrawingAppearance {
            image.lockFocus()
            NSColor.textBackgroundColor.setFill()
            field.bounds.fill()
            field.cell!.drawInterior(withFrame: field.bounds, in: field)
            image.unlockFocus()
        }
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let background = bitmap.colorAt(x: bitmap.pixelsWide - 1, y: 0)!
            .usingColorSpace(.deviceRGB)!.redComponent
        var contrast: CGFloat = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let value = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!.redComponent
                contrast = max(contrast, abs(value - background))
            }
        }
        precondition(
            contrast > 0.05 && contrast < 0.45,
            "The inactive placeholder stays muted in both appearances, contrast: \(contrast)")
        if let directory = ProcessInfo.processInfo.environment["KIT_FOCUS_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])!.write(
                to: url.appendingPathComponent("\(name).png"))
        }
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

                vm.toggleStackFilter()
                try await settle()
                vm.beginStackName()
                try await settle()
                let naming = fields(in: panel.contentView!).first {
                    $0 !== search && $0.isEditable
                }!
                precondition(
                    naming.currentEditor() === panel.firstResponder, "New Stack focuses its name")
                try checkPlaceholder(search, named: "\(appearance.rawValue)-\(style)-placeholder")
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
                print(
                    "PASS: \(appearance.rawValue), \(style): Esc, search input, outside dismissal, create, rename"
                )
            }
        }
    }
}
