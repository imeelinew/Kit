import AppKit
@testable import Kit

@MainActor
enum PaletteInteractionTests {
    private static func ready(_ vm: PaletteViewModel) async throws {
        try await TestSupport.eventually("Palette search settles") { vm.searchReady }
    }

    private static func navigation(in directory: URL) async throws {
        let store = ClipboardStore(directory: directory)
        let oldest = store.addText("oldest", kind: .text, sourceBundleID: nil)!
        let code = store.addText("let value = 7", kind: .code, sourceBundleID: nil)!
        let newest = store.addText("newest", kind: .text, sourceBundleID: nil)!
        let stack = store.createStack(name: "Work")!
        store.assign(code.id, to: stack.id)
        let core = AppCore(clipboardStore: store)
        let vm = PaletteViewModel(core: core)
        try await ready(vm)
        try TestSupport.expect(vm.results.map(\.id) == [newest.id, code.id, oldest.id],
                               "Opening orders entries by latest copy")
        try TestSupport.expect(vm.selectedID == newest.id && vm.selectionIndex == 0,
                               "Opening selects the first entry")
        let nonce = vm.scrollIntent.nonce
        vm.handle(.move(1))
        try TestSupport.expect(vm.selectedID == code.id && vm.scrollIntent.kind == .follow,
                               "Keyboard navigation follows selection")
        try TestSupport.expect(vm.scrollIntent.nonce != nonce, "Repeated scroll intents have unique identity")
        vm.handle(.move(100))
        try TestSupport.expect(vm.selectedID == oldest.id, "Navigation clamps at the last result")
        vm.handle(.move(-100))
        try TestSupport.expect(vm.selectedID == newest.id, "Navigation clamps at the first result")

        var menuChanges: [Bool] = []
        vm.onMenuOpenChanged = { menuChanges.append($0) }
        vm.toggleAppMenu()
        try TestSupport.expect(vm.menuActions == [.about, .checkForUpdates, .settings, .quit],
                               "App menu exposes the expected commands")
        vm.handle(.move(100))
        try TestSupport.expect(vm.menuSelection == 3 && vm.selectedID == newest.id,
                               "Menu navigation clamps without moving list selection")
        vm.handle(.move(-100))
        try TestSupport.expect(vm.menuSelection == 0, "Menu navigation clamps at zero")
        vm.toggleTypeFilter()
        try TestSupport.expect(menuChanges == [true], "Changing menu layers keeps the menu-open state")
        vm.closeMenu()
        try TestSupport.expect(menuChanges == [true, false], "Closing emits a single menu state change")
        vm.openActions(for: UUID())
        try TestSupport.expect(!vm.menuOpen, "Unknown action targets are ignored")
        vm.openActions(for: code.id)
        try TestSupport.expect(vm.menuActions.contains(.addToStack(code)), "Stacks enable assignment actions")
        try TestSupport.expect(vm.menuActions.contains(.removeFromStack(code)), "Members expose removal actions")
        try TestSupport.expect(!vm.menuActions.contains(.pinToScreen(code)), "Text code has no image pin action")
        let assignment = vm.menuActions.firstIndex(of: .addToStack(code))!
        vm.activateMenuItem(at: assignment)
        try TestSupport.expect(vm.overlay == .actions(code.id),
                               "Assignment ignores a menu when no alternative stack exists")
        let second = store.createStack(name: "Personal")!
        vm.activateMenuItem(at: vm.menuActions.firstIndex(of: .addToStack(code))!)
        try TestSupport.expect(vm.overlay == .addToStack(code.id)
                               && vm.menuActions == [.assignToStack(code, second)],
                               "Assignment excludes the current stack")
        vm.handle(.cancel)
        try TestSupport.expect(vm.overlay == .actions(code.id), "Escape returns from assignment to item actions")
        vm.handle(.cancel)
        try TestSupport.expect(vm.overlay == .none, "Escape closes item actions")
        vm.toggleStackFilter()
        vm.openStackActions(stack)
        vm.handle(.cancel)
        try TestSupport.expect(vm.overlay == .stackFilter && vm.menuSelection == 1,
                               "Escape from stack actions restores the stack menu row")
        vm.activateMenuItem(at: -1)
        vm.activateMenuItem(at: 999)
        try TestSupport.expect(vm.overlay == .stackFilter, "Out-of-range menu activation is ignored")
        vm.closeMenu()

        for filter in ClipboardKindFilter.allCases.dropFirst() {
            vm.handle(.cycleType(1))
            try await ready(vm)
            try TestSupport.expect(vm.kindFilter == filter && vm.resultsKindFilter == filter,
                                   "Every kind filter is reachable by keyboard")
            try TestSupport.expect(vm.results.allSatisfy { $0.kind == filter.kind },
                                   "Rendered results respect the active kind filter")
        }
        vm.handle(.cycleType(1))
        try await ready(vm)
        try TestSupport.expect(vm.kindFilter == .all && vm.results.count == 3, "Type navigation wraps to all")
        vm.handle(.cycleType(-1))
        try await ready(vm)
        try TestSupport.expect(vm.kindFilter == .file, "Reverse type navigation wraps")
        vm.handle(.cycleType(1))
        vm.handle(.cycleStack(1))
        try await ready(vm)
        try TestSupport.expect(vm.stackFilter == stack.id && vm.results.map(\.id) == [code.id],
                               "Stack filters restrict the result set")
        vm.handle(.cycleStack(-1))
        try await ready(vm)
        try TestSupport.expect(vm.stackFilter == nil && vm.results.count == 3, "Reverse cycling returns to clipboard")
        vm.handle(.cycleStack(-1))
        try await ready(vm)
        try TestSupport.expect(vm.stackFilter == second.id && vm.results.isEmpty && vm.selectedID == nil,
                               "Empty stack clears selection")
        vm.handle(.cycleStack(1))
        try await ready(vm)

        vm.query = "oldest"
        try await ready(vm)
        try TestSupport.expect(vm.results.map(\.id) == [oldest.id], "A text query narrows results")
        vm.toggleTypeFilter()
        vm.handle(.clearQuery)
        try TestSupport.expect(vm.query == "oldest", "Clear-query shortcut leaves an open menu alone")
        vm.handle(.cancel)
        try TestSupport.expect(vm.query == "oldest" && !vm.menuOpen, "Escape dismisses the menu before the query")
        var focused = 0
        vm.onSearchFocusRequested = { focused += 1 }
        vm.handle(.cancel)
        try await ready(vm)
        try TestSupport.expect(vm.query.isEmpty && focused == 1, "A second Escape clears query and focuses search")
        vm.query = "   \n"
        try await ready(vm)
        try TestSupport.expect(vm.queryIsEmpty && vm.results.count == 3, "Whitespace-only query uses the full list")
        vm.prepareForNextPresentation()
        try await ready(vm)
        try TestSupport.expect(!vm.isPreviewActive && vm.preparedPreview == nil
                               && vm.scrollIntent.kind == .top && vm.query.isEmpty,
                               "Hidden reset clears preview and restores top scrolling")
        await store.waitForSearchMetadata()
    }

    private static func naming(in directory: URL) async throws {
        let store = ClipboardStore(directory: directory)
        let item = store.addText("member", kind: .text, sourceBundleID: nil)!
        let core = AppCore(clipboardStore: store)
        let vm = PaletteViewModel(core: core)
        try await ready(vm)
        vm.beginStackName()
        try TestSupport.expect(!vm.isNamingStack, "New stack naming requires the stack menu")
        vm.toggleStackFilter()
        vm.beginStackName()
        vm.stackNameDraft = " \n "
        vm.commitStackName()
        try TestSupport.expect(vm.isNamingStack && store.stacks.isEmpty, "Blank stack names keep the editor open")
        vm.handle(.delete)
        try TestSupport.expect(store.item(id: item.id) != nil, "Naming suppresses item deletion")
        vm.stackNameDraft = "  项目  "
        vm.commitStackName()
        try await ready(vm)
        let stack = store.stacks.first!
        try TestSupport.expect(stack.name == "项目" && vm.stackFilter == stack.id && !vm.menuOpen,
                               "Committing trims the name and selects the new stack")
        vm.beginRename(stack)
        try TestSupport.expect(vm.stackNameDraft == "项目" && vm.overlay == .stackFilter,
                               "Rename opens the stack menu with the current name")
        vm.stackNameDraft = "Renamed"
        vm.commitStackName()
        try TestSupport.expect(store.stacks.first?.name == "Renamed" && vm.stackFilterTitle == "Renamed",
                               "Renaming updates the selected stack title")
        vm.toggleStackFilter()
        vm.beginStackName()
        vm.stackNameDraft = "Discard"
        vm.cancelStackName()
        try TestSupport.expect(!vm.isNamingStack && vm.stackNameDraft.isEmpty && store.stacks.count == 1,
                               "Cancelling a stack name does not write storage")
        vm.closeMenu()
        await store.waitForSearchMetadata()
    }

    private static func paginationAndRaces(in directory: URL) async throws {
        let store = ClipboardStore(directory: directory)
        for index in 0..<325 {
            _ = store.addText("page item \(index)", kind: .text, sourceBundleID: nil)
        }
        await store.waitForSearchMetadata()
        let core = AppCore(clipboardStore: store)
        let vm = PaletteViewModel(core: core)
        try await ready(vm)
        try TestSupport.expect(vm.results.count == 160 && vm.hasMoreResults, "Initial load is bounded to one page")
        let first = vm.selectedID
        vm.loadMoreResults()
        vm.loadMoreResults()
        try await TestSupport.eventually("Second page finishes") { vm.results.count == 320 }
        try TestSupport.expect(vm.selectedID == first && Set(vm.results.map(\.id)).count == 320,
                               "Concurrent page requests neither duplicate entries nor move selection")
        vm.loadMoreResults()
        try await TestSupport.eventually("Final page finishes") { !vm.hasMoreResults }
        try TestSupport.expect(vm.results.count == 325 && vm.results.map(\.id) == store.items.map(\.id),
                               "Pagination returns the entire ordered history exactly once")
        vm.query = "page item 1"
        vm.query = "page item 2"
        vm.query = "page item 324"
        try await ready(vm)
        try TestSupport.expect(vm.results.map(\.text) == ["page item 324"],
                               "Only the latest rapid query can publish its results")
        vm.query = "no matches"
        vm.handle(.delete)
        try TestSupport.expect(store.items.count == 325, "Pending search blocks destructive commands")
        try await ready(vm)
        try TestSupport.expect(vm.results.isEmpty && vm.selectedID == nil, "No matches clear the stale selection")
        vm.query = ""
        try await ready(vm)
        vm.loadMoreResults()
        vm.query = "page item 324"
        try await ready(vm)
        try TestSupport.expect(vm.results.count == 1 && !vm.hasMoreResults,
                               "A stale page cannot append results after criteria change")
        vm.query = ""
        try await ready(vm)
        let selected = vm.results[10]
        vm.select(selected.id)
        let added = store.addText("fresh arrival", kind: .text, sourceBundleID: nil)!
        try await TestSupport.eventually("Store revision refreshes results") { vm.results.first?.id == added.id }
        try TestSupport.expect(vm.selectedID == selected.id, "Capture refresh preserves an existing selection")
        vm.openActions(for: selected.id)
        vm.handle(.delete)
        try await TestSupport.eventually("Deleted row disappears") { !vm.results.contains { $0.id == selected.id } }
        try TestSupport.expect(vm.prefersDeletionUndo, "Delete takes ownership of undo routing")
        vm.query = "fresh arrival"
        try await ready(vm)
        try TestSupport.expect(!vm.prefersDeletionUndo, "Typing returns undo ownership to the search editor")
        vm.handle(.undoDelete)
        try await ready(vm)
        try TestSupport.expect(vm.query.isEmpty && vm.selectedID == selected.id,
                               "Undo clears an incompatible query and selects the restored entry")
        await store.waitForSearchMetadata()
    }

    static func run() async throws {
        try await TestSupport.withTemporaryDirectory { root in
            try await navigation(in: root.appendingPathComponent("navigation"))
            try await naming(in: root.appendingPathComponent("naming"))
            try await paginationAndRaces(in: root.appendingPathComponent("pagination"))
        }
    }
}
