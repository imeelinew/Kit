import AppKit
import Carbon.HIToolbox
import SwiftUI
@testable import Kit

/// Exercises native hover and keyboard routing against disposable history and a
/// controlled physical pointer, without moving the user's mouse or starting Kit.
@MainActor
enum ClipboardHoverSelectionTests {
    private static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { table(in: $0) }.first
    }

    private static func settle(_ milliseconds: Int = 300) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }

    private static func assertHighlight(in table: NSTableView) {
        table.layoutSubtreeIfNeeded()
        table.enumerateAvailableRowViews { _, row in
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? ClipboardItemCellView
            else { return }
            guard let highlight = cell.subviews.first, let layer = highlight.layer else {
                preconditionFailure("Every visible item must have a highlight layer")
            }
            let expected: Float = row == table.selectedRow ? 1 : 0
            precondition((layer.backgroundColor?.alpha ?? 0) > 0,
                         "A retained highlight must keep its fill after backing-layer recreation")
            precondition(abs(layer.cornerRadius - Theme.Radius.row) < 0.01,
                         "A recreated highlight must keep its rounded shape")
            precondition(abs(layer.opacity - expected) < 0.01,
                         "Row \(row) highlight must match selection: \(layer.opacity), expected \(expected)")
            if let presentation = layer.presentation() {
                precondition(abs(presentation.opacity - expected) < 0.01,
                             "The settled highlight must visibly match selection")
            }
        }
    }

    private static func mouseEvent(
        _ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow
    ) -> NSEvent {
        if type == .mouseEntered || type == .mouseExited {
            return NSEvent.enterExitEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                trackingNumber: 0, userData: nil)!
        }
        return NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 0)!
    }

    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kit-hover-selection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }

        for style in [PaletteVisualStyle.frosted, .liquid] {
            let store = ClipboardStore(directory: directory.appendingPathComponent("\(style)"))
            for title in ["alpha one", "alpha two", "alpha three"] {
                _ = store.addText(title, kind: .text, sourceBundleID: nil)
            }
            let core = AppCore(clipboardStore: store)
            let vm = core.palette
            var pointer = NSPoint.zero
            let window = PalettePanel(
                rootView: RootPaletteView(vm: vm, store: store, settings: core.settings),
                visualStyle: style, mouseLocation: { pointer })
            window.paletteViewModel = vm
            window.beginPresentation()
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            try await settle()
            let hosting = window.contentView!
            var table = table(in: hosting)!
            precondition(vm.searchReady && vm.results.count == 3)

            func location(for row: Int, x: CGFloat = 70) -> NSPoint {
                let rect = table.rect(ofRow: row)
                return table.convert(NSPoint(x: x, y: rect.midY), to: nil)
            }

            func movePointer(to point: NSPoint) {
                pointer = window.convertPoint(toScreen: point)
                window.sendEvent(mouseEvent(.mouseMoved, at: point, in: window))
            }

            let nativePoint = location(for: 2)
            pointer = window.convertPoint(toScreen: nativePoint)
            window.sendEvent(mouseEvent(.mouseMoved, at: nativePoint, in: window))
            precondition(vm.selectedID == vm.results[1].id,
                         "Window-dispatched movement selects a row before detachment")

            // Simulate tracking-area delivery being lost. Hover must recover on the next
            // window event, without a new capture, results refresh, or table reconstruction.
            let generation = vm.resultsGeneration
            table.trackingAreas.forEach(table.removeTrackingArea)
            movePointer(to: location(for: 3))
            precondition(vm.selectedID == vm.results[2].id,
                         "Window movement works without list tracking areas")
            try await settle()
            precondition(vm.resultsGeneration == generation)
            assertHighlight(in: table)

            for (index, query) in ["a", "al", "alp", "al", ""].enumerated() {
                let point = location(for: 2, x: 70 + CGFloat(index * 2))
                movePointer(to: point)
                precondition(vm.selectedID == vm.results[1].id, "Real movement selects the hovered item")
                vm.query = query
                try await settle()
                precondition(vm.searchReady && vm.selectedID == vm.results.first?.id,
                             "Typing/backspace/clear must keep the first result under a stationary pointer")
                // Layout can issue fresh enter/move events without physical movement.
                table.mouseEntered(with: mouseEvent(.mouseEntered, at: point, in: window))
                table.mouseMoved(with: mouseEvent(.mouseMoved, at: point, in: window))
                try await settle()
                precondition(vm.selectedID == vm.results.first?.id,
                             "Passive tracking refresh and elapsed time cannot reclaim keyboard selection")
            }

            // Cancel a menu-aim hover that was queued before typing began.
            movePointer(to: location(for: 2))
            movePointer(to: location(for: 3, x: 245))
            precondition(vm.selectedID == vm.results[1].id, "Diagonal travel defers the next hover")
            vm.query = "alpha"
            try await settle(450)
            precondition(vm.selectedID == vm.results.first?.id,
                         "A pending hover from before typing cannot override the new first result")

            // Mouse movement restores hover immediately, including within the same row.
            movePointer(to: location(for: 3, x: 243))
            precondition(vm.selectedID == vm.results[2].id, "Moving after typing restores hover")
            vm.query = "alph"
            try await settle()
            movePointer(to: location(for: 3, x: 241))
            precondition(vm.selectedID == vm.results[2].id, "Movement within a row also restores hover")

            let up = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{f700}",
                charactersIgnoringModifiers: "\u{f700}", isARepeat: false,
                keyCode: UInt16(kVK_UpArrow))!
            window.sendEvent(up)
            try await settle()
            precondition(vm.selectedID == vm.results[1].id,
                         "Arrow navigation keeps ownership while the mouse remains over another row")
            precondition(window.performKeyEquivalent(with: up))
            try await settle()
            precondition(vm.selectedID == vm.results.first?.id,
                         "The key-equivalent route also suppresses passive hover")

            vm.query = "no matching fixture"
            try await settle()
            precondition(vm.results.isEmpty && Self.table(in: hosting) == nil)
            vm.query = "alpha"
            try await settle()
            table = Self.table(in: hosting)!
            precondition(vm.selectedID == vm.results.first?.id,
                         "Keyboard ownership survives unmounting and recreating the list")
            let selectedBeforeRefresh = vm.selectedID
            _ = store.addText("alpha extra", kind: .text, sourceBundleID: nil)
            try await settle()
            precondition(vm.results.count == 4 && vm.selectedID == selectedBeforeRefresh,
                         "A background history refresh cannot rearm a stationary pointer")

            // Explicit AppKit selection and context clicks bypass hover ownership.
            // No paste target exists in this fixture.
            precondition(!vm.canPaste)
            table.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
            precondition(vm.selectedID == vm.results[2].id,
                         "Explicit row selection remains immediate while keyboard owns hover")
            table.rightMouseDown(with: mouseEvent(.rightMouseDown, at: location(for: 2), in: window))
            precondition(vm.selectedID == vm.results[1].id && vm.menuOpen,
                         "A right click still selects and opens actions immediately")
            try await settle()
            let stationaryMenuPointer = pointer
            movePointer(to: location(for: 3, x: 80))
            try await settle()
            precondition(vm.selectedID == vm.results[1].id,
                         "Window movement cannot select rows under an open menu")
            movePointer(to: window.convertPoint(fromScreen: stationaryMenuPointer))
            vm.closeMenu()
            try await settle()
            precondition(vm.selectedID == vm.results[1].id,
                         "Closing a menu does not rearm passive hover")
            assertHighlight(in: table)

            // Dismissal detaches the complete content tree before resetting the model.
            // Reopen without a history mutation, retaining the table and its existing cells.
            for cycle in 0..<8 {
                movePointer(to: location(for: 3, x: 60 + CGFloat(cycle)))
                window.alphaValue = 0
                window.orderOut(nil)
                window.contentView = nil
                vm.prepareForNextPresentation()
                hosting.layoutSubtreeIfNeeded()
                try await settle(30)
                await vm.prepare()
                window.beginPresentation()
                window.contentView = hosting
                window.alphaValue = 1
                hosting.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                window.makeKeyAndOrderFront(nil)
                try await settle()
                precondition(Self.table(in: hosting) === table,
                             "Reopening reuses the existing table")
                assertHighlight(in: table)
                movePointer(to: location(for: 2, x: 65 + CGFloat(cycle)))
                precondition(vm.selectedID == vm.results[1].id,
                             "Hover must resume after reattaching the same content")
                try await settle()
                assertHighlight(in: table)
            }

            // Backing layers are AppKit-owned and can be replaced independently of the
            // retained cell. Its fill and selection must be restored by the drawing path.
            table.enumerateAvailableRowViews { _, row in
                guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? ClipboardItemCellView, let highlight = cell.subviews.first
                else { return }
                highlight.layer = highlight.makeBackingLayer()
                highlight.needsDisplay = true
            }
            window.displayIfNeeded()
            try await settle()
            assertHighlight(in: table)
            for row in 1...3 {
                movePointer(to: location(for: row, x: 60))
                try await settle()
                precondition(table.selectedRow == row)
                assertHighlight(in: table)
            }
            for appearance in [NSAppearance.Name.darkAqua, .aqua] {
                window.appearance = NSAppearance(named: appearance)
                window.displayIfNeeded()
                try await settle()
                assertHighlight(in: table)
            }
            // Rapid movement still settles on the latest row without a stale highlight.
            movePointer(to: location(for: 1, x: 60))
            movePointer(to: location(for: 2, x: 60))
            try await settle()
            precondition(vm.selectedID == vm.results[1].id)
            assertHighlight(in: table)
            window.close()
            print("PASS: \(style): window-routed hover without tracking areas, visible highlights, recreated backing layers, light/dark appearance, repeated reattachment, typing/arrows, delayed-hover cancellation, empty results, refresh, menu shielding, clicks")
        }
    }
}
