import AppKit
import Carbon.HIToolbox
import SwiftUI
@testable import Kit

private struct UndoListView: View {
    let vm: PaletteViewModel
    let store: ClipboardStore

    var body: some View {
        ClipboardList(
            results: vm.results, resultsGeneration: vm.resultsGeneration,
            hasMoreResults: vm.hasMoreResults, selectedID: vm.selectedID,
            query: vm.query, scroll: vm.scrollIntent, hoverEnabled: false, store: store,
            onSelect: { vm.select($0.id) }, onActivate: { _ in }, onActions: { _ in },
            onLoadMore: { vm.loadMoreResults() })
        .frame(width: Theme.Size.clipboardListWidth)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
enum SingleDeletionUndoTests {
    private static func delete(in panel: PalettePanel) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "\u{7f}",
            charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: UInt16(kVK_Delete))!
        panel.sendEvent(event)
    }

    static func run() async throws {
        for style in [PaletteVisualStyle.frosted, .liquid] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("kit-single-undo-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = ClipboardStore(directory: directory)
            store.load()
            for index in 0..<50 {
                _ = store.addText("undo row \(index)", kind: .text, sourceBundleID: nil)
            }
            await store.waitForSearchMetadata()
            let core = AppCore(clipboardStore: store)
            let vm = core.palette
            await ClipboardUndoTests.ready(vm)
            let panel = PalettePanel(rootView: UndoListView(vm: vm, store: store), visualStyle: style)
            panel.paletteViewModel = vm
            panel.makeKeyAndOrderFront(nil)
            defer { panel.close() }
            try await Task.sleep(for: .milliseconds(100))
            let table = ClipboardListAnimationTests.table(in: panel.contentView!)!

            for _ in 0..<3 {
                let before = vm.results
                var removed: [ClipboardItem] = []
                for _ in 0..<3 {
                    let target = vm.results.first!
                    removed.append(target)
                    vm.select(target.id)
                    delete(in: panel)
                    await ClipboardUndoTests.ready(vm)
                    try await Task.sleep(for: .milliseconds(16))
                }
                try await Task.sleep(for: .milliseconds(300))
                vm.select(vm.results.last!.id, follow: true)
                try await Task.sleep(for: .milliseconds(50))

                ClipboardUndoTests.commandZ(panel)
                let revision = store.revision
                let generation = vm.resultsGeneration
                let scroll = vm.scrollIntent
                ClipboardUndoTests.commandZ(panel) // Also no-op while restoration is pending.
                precondition(store.revision == revision && vm.resultsGeneration == generation
                             && vm.scrollIntent == scroll)
                await ClipboardUndoTests.ready(vm)
                try await Task.sleep(for: .milliseconds(300))
                let latest = removed.last!
                precondition(vm.selectedID == latest.id)
                precondition(vm.results.map(\.id) == before.dropFirst(2).map(\.id),
                             "Only the latest of three deletions can return")
                precondition(removed.dropLast().allSatisfy { store.item(id: $0.id) == nil })
                precondition(!store.canUndoDeletion)
                ClipboardListAnimationTests.assertRowGeometry(table)
                let cell = table.view(atColumn: 0, row: table.selectedRow, makeIfNecessary: true)
                    as? ClipboardItemCellView
                precondition(cell?.textField?.stringValue == latest.text)

                let settledGeneration = vm.resultsGeneration
                let settledScroll = vm.scrollIntent
                for _ in 0..<5 { ClipboardUndoTests.commandZ(panel) }
                precondition(vm.resultsGeneration == settledGeneration && vm.scrollIntent == settledScroll,
                             "Repeated Command-Z after the single restore does nothing")
            }
            print("PASS: \(style), latest-deletion-only, pending/settled second-undo no-op, fresh deletion rearms undo")
        }
    }
}
