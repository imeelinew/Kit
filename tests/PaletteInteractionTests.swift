import AppKit
import Darwin
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

    private static func previewCopyAvailability(in directory: URL) async throws {
        ClipboardPreviewPayload.purge()
        defer { ClipboardPreviewPayload.purge() }

        let sourceDirectory = directory.appendingPathComponent("preview-sources", isDirectory: true)
        let staleURL = sourceDirectory.appendingPathComponent("missing.txt")
        let partialAvailableURL = sourceDirectory.appendingPathComponent("partial-available.txt")
        let partialMissingURL = sourceDirectory.appendingPathComponent("partial-missing.txt")
        let readyURL = sourceDirectory.appendingPathComponent("ready.txt")
        try write(Data("missing".utf8), to: staleURL)
        try write(Data("available".utf8), to: partialAvailableURL)
        try write(Data("missing".utf8), to: partialMissingURL)
        try write(Data("ready".utf8), to: readyURL)

        let store = ClipboardStore(
            directory: directory.appendingPathComponent("store", isDirectory: true),
            maintenanceInterval: 86_400)
        store.setImageTextSearchEnabled(false)
        guard let stale = store.addFiles([staleURL], sourceBundleID: nil),
              let partial = store.addFiles(
                [partialAvailableURL, partialMissingURL], sourceBundleID: nil),
              let readyItem = store.addFiles([readyURL], sourceBundleID: nil)
        else {
            throw TestSupport.Failure(description: "Preview file fixtures enter the isolated store")
        }
        let partialURLs = partial.fileURLs
        try FileManager.default.removeItem(at: staleURL)
        try FileManager.default.removeItem(at: partialMissingURL)

        let core = AppCore(clipboardStore: store)
        let vm = PaletteViewModel(core: core)
        try await ready(vm)

        vm.select(stale.id)
        guard let selectedStale = vm.selectedItem else {
            throw TestSupport.Failure(description: "The stale fixture becomes the current palette item")
        }
        let stalePayload = await ClipboardPreviewPayload.load(
            for: selectedStale, imageURL: nil, store: store)
        vm.acceptPreview(stalePayload)
        try TestSupport.expect(
            stalePayload.details.contentState == .notFound
                && stalePayload.availableFileCount == 0
                && vm.preparedPreview === stalePayload
                && vm.copyableFileCount(for: selectedStale) == 0
                && !vm.canCopy(selectedStale),
            "A selected file item disables copy only after every file is confirmed missing"
        )

        vm.select(readyItem.id)
        guard let selectedReady = vm.selectedItem else {
            throw TestSupport.Failure(description: "The ready fixture becomes the current palette item")
        }
        try TestSupport.expect(
            vm.preparedPreview == nil && vm.copyableFileCount(for: selectedReady) == nil
                && vm.canCopy(selectedReady),
            "A pending current preview does not disable a new file item"
        )
        vm.acceptPreview(stalePayload)
        try TestSupport.expect(
            vm.preparedPreview == nil && vm.canCopy(selectedReady),
            "An asynchronously accepted payload from the prior selection cannot disable the current item"
        )

        let readyPayload = await ClipboardPreviewPayload.load(
            for: selectedReady, imageURL: nil, store: store)
        vm.acceptPreview(readyPayload)
        try TestSupport.expect(
            vm.preparedPreview === readyPayload
                && readyPayload.availableFileCount == 1
                && vm.copyableFileCount(for: selectedReady) == 1
                && vm.canCopy(selectedReady),
            "The current ready payload enables copying its available file"
        )

        try write(Data("replacement ready contents".utf8), to: readyURL)
        guard let currentReady = vm.selectedItem else {
            throw TestSupport.Failure(description: "The ready fixture remains selected for version refresh")
        }
        let refreshedPayload = await ClipboardPreviewPayload.load(
            for: currentReady, imageURL: nil, store: store)
        vm.select(selectedStale.id)
        vm.select(readyItem.id)
        vm.acceptPreview(readyPayload)
        try TestSupport.expect(
            !readyPayload.matches(currentReady) && vm.preparedPreview == nil,
            "A payload from the prior source version cannot replace the current selection"
        )
        vm.acceptPreview(refreshedPayload)
        try TestSupport.expect(
            vm.preparedPreview === refreshedPayload
                && vm.copyableFileCount(for: currentReady) == 1,
            "The payload for the refreshed source version becomes current"
        )

        vm.select(partial.id)
        guard let selectedPartial = vm.selectedItem else {
            throw TestSupport.Failure(description: "The partial fixture becomes the current palette item")
        }
        let partialPayload = await ClipboardPreviewPayload.load(
            for: selectedPartial, imageURL: nil, store: store)
        vm.acceptPreview(partialPayload)
        try TestSupport.expect(
            partialPayload.details.fileAvailability == [.available, .missing]
                && partialPayload.availableFileCount == 1
                && vm.copyableFileCount(for: selectedPartial) == 1
                && vm.canCopy(selectedPartial),
            "A partially available group copies its one surviving file"
        )
        try TestSupport.expect(
            store.item(id: partial.id)?.fileURLs == partialURLs && partialURLs.count == 2,
            "Partial file availability preserves both original history paths"
        )
        await store.waitForSearchMetadata()
    }

    private static func permissionSensitiveCopy(in directory: URL) async throws {
        guard geteuid() != 0 else { return }
        ClipboardPreviewPayload.purge()
        defer { ClipboardPreviewPayload.purge() }

        let sourceDirectory = directory.appendingPathComponent("permission-sources", isDirectory: true)
        let source = sourceDirectory.appendingPathComponent("restricted.txt")
        try write(Data("restricted".utf8), to: source)
        let store = ClipboardStore(
            directory: directory.appendingPathComponent("store", isDirectory: true),
            maintenanceInterval: 86_400)
        store.setImageTextSearchEnabled(false)
        guard let item = store.addFiles([source], sourceBundleID: nil) else {
            throw TestSupport.Failure(description: "The permission fixture enters the isolated store")
        }

        var metadata = stat()
        guard stat(source.path, &metadata) == 0 else {
            throw TestSupport.Failure(description: "The permission fixture metadata is available")
        }
        let originalMode = metadata.st_mode & 0o777
        guard chmod(source.path, 0o000) == 0 else {
            throw TestSupport.Failure(description: "The permission fixture removes read access")
        }
        defer { _ = chmod(source.path, originalMode) }
        guard case .needsPermission = ClipboardFileAccess.availability(of: source) else {
            return
        }

        let core = AppCore(clipboardStore: store)
        let vm = PaletteViewModel(core: core)
        try await ready(vm)
        vm.select(item.id)
        guard let selectedItem = vm.selectedItem else {
            throw TestSupport.Failure(description: "The permission fixture becomes the current palette item")
        }
        let payload = await ClipboardPreviewPayload.load(
            for: selectedItem, imageURL: nil, store: store)
        vm.acceptPreview(payload)
        try TestSupport.expect(
            payload.details.fileAvailability == [.needsPermission]
                && payload.details.contentState == .unavailablePreview
                && payload.requiresFilePermission
                && payload.availableFileCount == 0,
            "A real permission denial is reported separately from a missing file"
        )
        try TestSupport.expect(
            vm.copyableFileCount(for: selectedItem) == nil && vm.canCopy(selectedItem),
            "A permission-sensitive item stays actionable so authorization can be requested"
        )
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

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func run() async throws {
        try await TestSupport.withTemporaryDirectory { root in
            try await navigation(in: root.appendingPathComponent("navigation"))
            try await naming(in: root.appendingPathComponent("naming"))
            try await previewCopyAvailability(in: root.appendingPathComponent("preview-copy"))
            try await permissionSensitiveCopy(in: root.appendingPathComponent("permission-copy"))
            try await paginationAndRaces(in: root.appendingPathComponent("pagination"))
        }
    }
}
