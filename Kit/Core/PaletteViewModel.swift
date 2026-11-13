import AppKit
import Observation
import SwiftUI

struct PasteTarget: Equatable {
    let name: String
    let iconPath: String?

    init?(app: NSRunningApplication?) {
        guard let app, !app.isTerminated else { return nil }
        guard let name = app.localizedName ?? app.executableURL?.lastPathComponent else { return nil }
        self.name = name
        if let bundleURL = app.bundleURL {
            iconPath = bundleURL.path
        } else if let bundleID = app.bundleIdentifier,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            iconPath = url.path
        } else if let execURL = app.executableURL {
            iconPath = execURL.path
        } else {
            iconPath = nil
        }
    }

    var pasteTitle: LocalizedStringKey { "Paste to \(name)" }
}

enum PaletteOverlay: Equatable {
    case none
    case actions(ClipboardItem.ID)
    case appMenu
    case typeFilter
    case stackFilter
    case stackActions(ClipboardStack.ID)
    case addToStack(ClipboardItem.ID)

    var isOpen: Bool { self != .none }
}

enum StackNameEdit: Equatable {
    case create
    case rename(ClipboardStack.ID)
}

enum PaletteCommand: Equatable {
    case move(Int)
    case activate
    case pasteKeepingOpen
    case copy
    case delete
    case undoDelete
    case cancel
    case toggleActions
    case pinToScreen
    case revealInFinder
    case cycleStack(Int)
    case cycleType(Int)
    case clearQuery
    case settings
    case quit
}

enum PaletteMenuAction: Equatable {
    case about
    case checkForUpdates
    case settings
    case quit
    case paste(ClipboardItem)
    case pasteKeepingOpen(ClipboardItem)
    case copy(ClipboardItem)
    case pinToScreen(ClipboardItem)
    case revealInFinder(ClipboardItem)
    case delete(ClipboardItem)
    case addToStack(ClipboardItem)
    case assignToStack(ClipboardItem, ClipboardStack)
    case removeFromStack(ClipboardItem)
    case setKindFilter(ClipboardKindFilter)
    /// `nil` is the clipboard, which shows every item.
    case setStackFilter(ClipboardStack?)
    case newStack
    case renameStack(ClipboardStack)
    case deleteStack(ClipboardStack)
}

extension ClipboardItem.Kind {
    var symbolName: String {
        switch self {
        case .text: "text.menu"
        case .markdown: "number"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .link: "link"
        case .path: "point.topleft.down.to.point.bottomright.curvepath"
        case .image: "photo"
        case .file: "doc"
        }
    }
}

enum ClipboardKindFilter: Equatable, CaseIterable {
    case all, text, markdown, code, link, path, image, file

    var title: LocalizedStringKey {
        LocalizedStringKey(kind?.typeLabel ?? "All Types")
    }

    var symbolName: String {
        kind?.symbolName ?? "list.bullet"
    }

    var kind: ClipboardItem.Kind? {
        switch self {
        case .all: nil
        case .text: .text
        case .markdown: .markdown
        case .code: .code
        case .link: .link
        case .path: .path
        case .image: .image
        case .file: .file
        }
    }
}

/// Trackpad haptics for palette interactions. No-ops on hardware without a
/// haptic trackpad (mice, older MacBooks).
@MainActor
enum PaletteHaptics {
    /// One alignment tick when the pointer crosses a row, or a row crosses
    /// the viewport edge during two-finger scrolling.
    static func tick() {
        guard AppCore.shared.settings.hapticFeedbackEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

/// The palette's single interaction state machine. AppKit keyboard events and SwiftUI mouse
/// actions both enter here, so commands do not depend on whichever embedded view is first responder.
@MainActor
@Observable
final class PaletteViewModel {
    private struct SearchRequest: Equatable {
        let query: String
        let kind: ClipboardKindFilter
        let stackID: ClipboardStack.ID?
    }

    var query = "" {
        didSet { queryChanged() }
    }
    private(set) var kindFilter: ClipboardKindFilter = .all
    /// `nil` shows the whole clipboard. A stack id shows only items in that stack.
    private(set) var stackFilter: ClipboardStack.ID?
    var stackNameEdit: StackNameEdit?
    var stackNameDraft = ""

    var isNamingStack: Bool { stackNameEdit != nil }

    var stackFilterTitle: String {
        if let stackFilter,
            let stack = core.clipboardStore.stacks.first(where: { $0.id == stackFilter })
        {
            return stack.name
        }
        return AppLocalization.string("Clipboard", locale: core.settings.language.locale)
    }
    private(set) var results: [ClipboardItem] = []
    private(set) var resultsKindFilter: ClipboardKindFilter = .all
    private(set) var resultsStackFilter: ClipboardStack.ID?
    private(set) var resultsGeneration: UInt64 = 0
    var hasMoreResults: Bool { nextCursor != nil }
    private(set) var selectedID: ClipboardItem.ID? {
        didSet {
            if oldValue != selectedID {
                imageQuickLookOpen = false
                ImageQuickLook.close()
            }
            if preparedPreview?.itemID != selectedID { preparedPreview = nil }
        }
    }
    private(set) var preparedPreview: ClipboardPreviewPayload?
    private(set) var isPreviewActive = false
    private(set) var searchReady = true
    private(set) var scrollIntent = ScrollIntent(kind: .top)
    var pasteTarget: PasteTarget?
    var imageQuickLookOpen = false
    private(set) var overlay: PaletteOverlay = .none {
        didSet {
            if overlay.isOpen {
                imageQuickLookOpen = false
                ImageQuickLook.close()
            }
            if overlay != .stackFilter {
                stackNameEdit = nil
                stackNameDraft = ""
            }
            if oldValue.isOpen != overlay.isOpen {
                onMenuOpenChanged?(overlay.isOpen)
            }
        }
    }
    var menuSelection = 0

    @ObservationIgnored var onMenuOpenChanged: ((Bool) -> Void)?
    @ObservationIgnored var onSearchFocusRequested: (() -> Void)?
    @ObservationIgnored var onSearchQueryChanged: (() -> Void)?

    @ObservationIgnored private unowned let core: AppCore
    private static let pageSize = 160
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var normalizedQuery = ""
    private var nextCursor: ClipboardSearchCursor?
    @ObservationIgnored private var loadedPageCount = 1
    @ObservationIgnored private var pendingRestoredItemID: ClipboardItem.ID?
    @ObservationIgnored private var isBatchingSearchUpdates = false
    private var deletionWasLastEdit = false
    @ObservationIgnored private var revisionObserver: ObservationToken?

    init(core: AppCore) {
        self.core = core
        revisionObserver = core.clipboardStore.observeRevision { [weak self] in
            guard let self, !self.isBatchingSearchUpdates,
                !self.core.clipboardStore.hasDeferredHistoryUpdates
            else { return }
            refreshResults(resetSelection: !searchReady, blockCommands: false)
        }
        refreshResults(resetSelection: true, blockCommands: true)
    }

    var menuOpen: Bool { overlay.isOpen }

    private var searchRequest: SearchRequest {
        SearchRequest(query: normalizedQuery, kind: kindFilter, stackID: stackFilter)
    }

    private func searchIsCurrent(_ request: SearchRequest) -> Bool {
        !Task.isCancelled && searchRequest == request
    }

    // Keep routing to deletion undo after it is consumed. A second Command-Z must
    // not fall through to an older text edit; typing/naming still owns text undo.
    var prefersDeletionUndo: Bool { deletionWasLastEdit }

    var selectionIndex: Int {
        guard let selectedID,
            let index = results.firstIndex(where: { $0.id == selectedID })
        else { return 0 }
        return index
    }

    var selectedItem: ClipboardItem? {
        guard let selectedID else { return nil }
        return results.first { $0.id == selectedID }
    }

    /// Accept only the current selection and source version, including asynchronous completions
    func acceptPreview(_ payload: ClipboardPreviewPayload) {
        guard let item = selectedItem, payload.matches(item) else { return }
        if preparedPreview !== payload { preparedPreview = payload }
    }

    private func currentPreview(for item: ClipboardItem) -> ClipboardPreviewPayload? {
        if let preparedPreview, preparedPreview.matches(item) { return preparedPreview }
        return ClipboardPreviewPayload.cached(for: item)
    }

    func copyableFileCount(for item: ClipboardItem) -> Int? {
        guard item.isFileBacked, let payload = currentPreview(for: item),
            !payload.requiresFilePermission, !payload.details.fileAvailability.contains(.unavailable)
        else { return nil }
        return payload.availableFileCount
    }

    func canCopy(_ item: ClipboardItem) -> Bool {
        if item.hasImagePreview,
            currentPreview(for: item)?.details.contentState == .notFound
        { return false }
        guard let count = copyableFileCount(for: item) else { return true }
        return count > 0
    }

    var canPaste: Bool {
        pasteTarget != nil && core.hasPasteTarget
    }

    var menuActions: [PaletteMenuAction] {
        switch overlay {
        case .none:
            return []
        case .appMenu:
            return [.about, .checkForUpdates, .settings, .quit]
        case .actions(let id):
            guard let item = item(withID: id) else { return [] }
            var actions: [PaletteMenuAction] = [
                .paste(item),
                .pasteKeepingOpen(item),
                .copy(item),
            ]
            if item.hasImagePreview {
                actions.append(.pinToScreen(item))
            }
            if item.hasImagePreview || item.kind == .file || item.kind == .path {
                actions.append(.revealInFinder(item))
            }
            let currentStack = core.clipboardStore.stackID(for: item.id)
            if core.clipboardStore.stacks.contains(where: { $0.id != currentStack }) {
                actions.append(.addToStack(item))
            }
            if currentStack != nil {
                actions.append(.removeFromStack(item))
            }
            actions.append(.delete(item))
            return actions
        case .typeFilter:
            return ClipboardKindFilter.allCases.map(PaletteMenuAction.setKindFilter)
        case .stackFilter:
            var actions: [PaletteMenuAction] = [.setStackFilter(nil)]
            actions.append(contentsOf: core.clipboardStore.stacks.map { .setStackFilter($0) })
            actions.append(.newStack)
            return actions
        case .addToStack(let id):
            guard let item = item(withID: id) else { return [] }
            let currentStack = core.clipboardStore.stackID(for: id)
            return core.clipboardStore.stacks.filter { $0.id != currentStack }
                .map { .assignToStack(item, $0) }
        case .stackActions(let id):
            guard let stack = core.clipboardStore.stacks.first(where: { $0.id == id }) else {
                return []
            }
            return [.renameStack(stack), .deleteStack(stack)]
        }
    }

    func openStackActions(at index: Int) {
        let actions = menuActions
        guard actions.indices.contains(index),
            case .setStackFilter(let stack) = actions[index],
            let stack
        else { return }
        openStackActions(stack)
    }

    func openStackActions(_ stack: ClipboardStack) {
        openMenu(.stackActions(stack.id))
    }

    /// Reset while hidden so clearing a previous search does not delay the next shortcut.
    func prepareForNextPresentation() {
        isPreviewActive = false
        preparedPreview = nil
        resetPresentationState()
        scrollIntent = ScrollIntent(kind: .top)
        if searchReady { selectedID = results.first?.id }
    }

    private func resetPresentationState() {
        if overlay != .none { overlay = .none }
        if menuSelection != 0 { menuSelection = 0 }
        imageQuickLookOpen = false
        if !query.isEmpty { query = "" }
    }

    private func selectFirstResult() {
        let firstID = results.first?.id
        if selectedID != firstID { selectedID = firstID }
        let payload = results.first.flatMap { ClipboardPreviewPayload.cached(for: $0) }
        if preparedPreview !== payload { preparedPreview = payload }
    }

    func prepare() async {
        resetPresentationState()

        // A revision can replace either the search or the first item while its image loads.
        // Hold the prepared payload strongly until SwiftUI has consumed the first frame.
        while !Task.isCancelled {
            while let task = searchTask {
                await task.value
                guard !Task.isCancelled else { return }
            }
            selectFirstResult()
            guard let item = selectedItem else {
                preparedPreview = nil
                isPreviewActive = true
                return
            }
            let payload = await ClipboardPreviewPayload.load(
                for: item, imageURL: core.clipboardStore.imageURL(for: item), store: core.clipboardStore)
            guard !Task.isCancelled else { return }
            guard searchTask == nil, results.first?.id == item.id else { continue }
            if preparedPreview !== payload { preparedPreview = payload }
            isPreviewActive = true
            return
        }
    }

    func select(_ id: ClipboardItem.ID, follow: Bool = false) {
        selectedID = id
        imageQuickLookOpen = false
        if follow { scrollIntent = ScrollIntent(kind: .follow) }
    }

    func toggleImageQuickLook(for itemID: ClipboardItem.ID) {
        guard selectedID == itemID, searchReady, !menuOpen, selectedItem?.hasImagePreview == true else { return }
        imageQuickLookOpen.toggle()
    }

    func openActions(for id: ClipboardItem.ID) {
        guard searchReady, item(withID: id) != nil else { return }
        select(id)
        openMenu(.actions(id))
    }

    func toggleAppMenu() {
        openMenu(overlay == .appMenu ? .none : .appMenu)
    }

    func toggleTypeFilter() {
        if overlay == .typeFilter {
            closeMenu()
        } else {
            openMenu(
                .typeFilter,
                selection: ClipboardKindFilter.allCases.firstIndex(of: kindFilter) ?? 0)
        }
    }

    func toggleStackFilter() {
        if overlay == .stackFilter {
            closeMenu()
        } else {
            openMenu(.stackFilter, selection: stackMenuSelection(stackFilter))
        }
    }

    private func stackMenuSelection(_ stackID: ClipboardStack.ID?) -> Int {
        core.clipboardStore.stacks.firstIndex { $0.id == stackID }.map { $0 + 1 } ?? 0
    }

    private func openMenu(_ menu: PaletteOverlay, selection: Int = 0) {
        overlay = menu
        menuSelection = selection
    }

    func closeMenu() {
        overlay = .none
        menuSelection = 0
    }

    /// Esc removes only the front menu. A menu opened from another menu returns there.
    private func dismissMenuLayer() {
        switch overlay {
        case .stackActions(let id):
            openMenu(.stackFilter, selection: stackMenuSelection(id))
        case .addToStack(let id):
            overlay = .actions(id)
            let selection = menuActions.firstIndex {
                if case .addToStack = $0 { return true }
                return false
            }
            menuSelection = selection ?? 0
        default:
            closeMenu()
        }
    }

    func activateMenuItem(at index: Int) {
        let actions = menuActions
        guard actions.indices.contains(index) else { return }
        perform(actions[index])
    }

    @discardableResult
    func handle(_ command: PaletteCommand) -> Bool {
        switch command {
        case .move(let delta):
            if menuOpen {
                moveMenu(delta)
            } else {
                moveSelection(delta)
            }
        case .activate:
            if menuOpen {
                activateMenuItem(at: menuSelection)
            } else if searchReady, canPaste, let item = selectedItem, canCopy(item) {
                core.paste(item)
            }
        case .pasteKeepingOpen:
            guard searchReady, canPaste, !isNamingStack, let item = actionTarget, canCopy(item) else { return true }
            perform(.pasteKeepingOpen(item))
        case .copy:
            guard searchReady, let item = actionTarget else { return true }
            perform(.copy(item))
        case .delete:
            guard searchReady, !isNamingStack, let item = actionTarget else { return true }
            perform(.delete(item))
        case .undoDelete:
            guard !isNamingStack else { return true }
            undoDeletion()
        case .cancel:
            if imageQuickLookOpen {
                imageQuickLookOpen = false
                ImageQuickLook.close()
            } else if menuOpen {
                dismissMenuLayer()
            } else if !queryIsEmpty {
                query = ""
                onSearchFocusRequested?()
            } else {
                core.hidePalette()
            }
        case .toggleActions:
            guard searchReady, let id = selectedID else { return true }
            if overlay == .actions(id) {
                closeMenu()
            } else {
                openMenu(.actions(id))
            }
        case .pinToScreen:
            guard searchReady, let item = actionTarget, item.hasImagePreview else { return true }
            perform(.pinToScreen(item))
        case .revealInFinder:
            guard searchReady, let item = actionTarget,
                item.hasImagePreview || item.kind == .file || item.kind == .path else { return true }
            perform(.revealInFinder(item))
        case .cycleStack(let delta):
            cycleStack(by: delta)
        case .cycleType(let delta):
            cycleType(by: delta)
        case .clearQuery:
            guard !menuOpen else { return true }
            if !queryIsEmpty { query = "" }
        case .settings:
            perform(.settings)
        case .quit:
            perform(.quit)
        }
        return true
    }

    var queryIsEmpty: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var actionTarget: ClipboardItem? {
        switch overlay {
        case .actions(let id):
            return item(withID: id)
        case .none:
            return selectedItem
        case .appMenu, .typeFilter, .stackFilter, .stackActions, .addToStack:
            return nil
        }
    }

    private func item(withID id: ClipboardItem.ID) -> ClipboardItem? {
        core.clipboardStore.items.first { $0.id == id }
            ?? results.first { $0.id == id }
    }

    private func moveSelection(_ delta: Int) {
        guard searchReady, !results.isEmpty else { return }
        let next: Int
        if let selectedID, let current = results.firstIndex(where: { $0.id == selectedID }) {
            next = min(max(current + delta, 0), results.count - 1)
        } else {
            next = delta < 0 ? results.count - 1 : 0
        }
        selectedID = results[next].id
        imageQuickLookOpen = false
        ImageQuickLook.close()
        scrollIntent = ScrollIntent(kind: .follow)
    }

    private func moveMenu(_ delta: Int) {
        let count = menuActions.count
        guard count > 0 else { return }
        menuSelection = min(max(menuSelection + delta, 0), count - 1)
    }

    private func perform(_ action: PaletteMenuAction) {
        switch action {
        case .about:
            closeMenu()
            core.showAbout()
        case .checkForUpdates:
            closeMenu()
            core.checkForUpdates()
        case .settings:
            closeMenu()
            core.showSettings()
        case .quit:
            closeMenu()
            core.requestQuit()
        case .paste(let item):
            guard canPaste, canCopy(item) else { return }
            closeMenu()
            core.paste(item)
        case .pasteKeepingOpen(let item):
            guard canPaste, canCopy(item) else { return }
            closeMenu()
            core.pasteKeepingWindowOpen(item)
        case .copy(let item):
            guard canCopy(item) else { return }
            closeMenu()
            core.copyToClipboard(item)
        case .pinToScreen(let item):
            guard item.hasImagePreview else { return }
            closeMenu()
            core.pinToScreen(item)
        case .revealInFinder(let item):
            closeMenu()
            core.revealClipboardItem(item)
        case .addToStack(let item):
            openMenu(.addToStack(item.id))
        case .assignToStack(let item, let stack):
            closeMenu()
            core.clipboardStore.assign(item.id, to: stack.id)
        case .removeFromStack(let item):
            closeMenu()
            if !core.clipboardStore.removeFromStack(item.id) { NSSound.beep() }
        case .delete(let item):
            closeMenu()
            let removedIndex = selectionIndex
            imageQuickLookOpen = false
            ImageQuickLook.close()
            guard core.clipboardStore.remove(item) else {
                NSSound.beep()
                return
            }
            deletionWasLastEdit = true
            results.removeAll { $0.id == item.id }
            resultsGeneration &+= 1
            if results.isEmpty {
                selectedID = nil
            } else {
                selectedID = results[min(removedIndex, results.count - 1)].id
            }
        case .setKindFilter(let filter):
            closeMenu()
            applyKindFilter(filter)
            onSearchFocusRequested?()
        case .setStackFilter(let stack):
            closeMenu()
            applyStackFilter(stack?.id)
            onSearchFocusRequested?()
        case .newStack:
            beginStackName()
        case .renameStack(let stack):
            beginRename(stack)
        case .deleteStack(let stack):
            confirmDelete(stack)
        }
    }

    private func undoDeletion() {
        guard core.clipboardStore.canUndoDeletion else { return }
        isBatchingSearchUpdates = true
        defer { isBatchingSearchUpdates = false }
        guard let restored = core.clipboardStore.undoLastDeletion() else {
            NSSound.beep()
            return
        }
        closeMenu()
        imageQuickLookOpen = false
        ImageQuickLook.close()
        if !normalizedQuery.isEmpty,
            !restored.matches(
                normalizedQuery, includeImageText: core.clipboardStore.imageTextSearchEnabled)
        {
            query = ""
        }
        if let kind = kindFilter.kind, restored.kind != kind { kindFilter = .all }
        if let stackFilter, core.clipboardStore.stackID(for: restored.id) != stackFilter {
            self.stackFilter = nil
        }
        pendingRestoredItemID = restored.id
        deletionWasLastEdit = true
        refreshResults(resetSelection: false, blockCommands: true)
    }

    func beginStackName() {
        guard overlay == .stackFilter else { return }
        stackNameEdit = .create
        stackNameDraft = ""
    }

    func beginRename(_ stack: ClipboardStack) {
        stackNameDraft = stack.name
        stackNameEdit = .rename(stack.id)
        openMenu(.stackFilter, selection: stackMenuSelection(stack.id))
    }

    func cancelStackName() {
        guard stackNameEdit != nil else { return }
        stackNameEdit = nil
        stackNameDraft = ""
    }

    func commitStackName() {
        guard let edit = stackNameEdit else { return }
        let name = stackNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch edit {
        case .create:
            guard let stack = core.clipboardStore.createStack(name: name) else { return }
            closeMenu()
            applyStackFilter(stack.id)
        case .rename(let id):
            guard core.clipboardStore.renameStack(id, to: name) else { return }
            closeMenu()
            onSearchFocusRequested?()
        }
    }

    private func confirmDelete(_ stack: ClipboardStack) {
        let locale = core.settings.language.locale
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: AppLocalization.string("Delete Stack %@?", locale: locale),
            locale: locale,
            stack.name
        )
        alert.informativeText = AppLocalization.string(
            "Items in this stack will also be deleted. This can't be undone.", locale: locale)
        alert.addButton(withTitle: AppLocalization.string("Delete", locale: locale))
        alert.addButton(withTitle: AppLocalization.string("Cancel", locale: locale))
        alert.buttons.first?.hasDestructiveAction = true
        guard core.runModalAlert(alert) == .alertFirstButtonReturn else { return }
        guard core.clipboardStore.deleteStack(stack.id) else { return }
        closeMenu()
        if stackFilter == stack.id {
            applyStackFilter(nil)
        }
    }

    /// Clipboard is the first stop, then stacks in menu order. The list wraps.
    private func cycleStack(by delta: Int) {
        let stacks = core.clipboardStore.stacks
        let count = stacks.count + 1
        guard count > 1, delta != 0 else { return }
        let current = stackFilter.flatMap { id in
            stacks.firstIndex(where: { $0.id == id }).map { $0 + 1 }
        } ?? 0
        let next = ((current + delta) % count + count) % count
        guard next != current else { return }
        closeMenu()
        applyStackFilter(next == 0 ? nil : stacks[next - 1].id)
        onSearchFocusRequested?()
    }

    /// All Types is the first stop, then each kind in menu order. The list wraps.
    private func cycleType(by delta: Int) {
        let destinations = ClipboardKindFilter.allCases
        guard destinations.count > 1, delta != 0 else { return }
        let current = destinations.firstIndex(of: kindFilter) ?? 0
        let count = destinations.count
        let next = ((current + delta) % count + count) % count
        guard next != current else { return }
        closeMenu()
        applyKindFilter(destinations[next])
        onSearchFocusRequested?()
    }

    private func applyStackFilter(_ stackID: ClipboardStack.ID?) {
        guard stackFilter != stackID else { return }
        stackFilter = stackID
        searchCriteriaChanged()
    }

    private func applyKindFilter(_ filter: ClipboardKindFilter) {
        guard kindFilter != filter else { return }
        kindFilter = filter
        searchCriteriaChanged()
    }

    private func queryChanged() {
        normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        onSearchQueryChanged?()
        deletionWasLastEdit = false
        closeMenu()
        if !isBatchingSearchUpdates { searchCriteriaChanged() }
    }

    private func searchCriteriaChanged() {
        pendingRestoredItemID = nil
        imageQuickLookOpen = false
        ImageQuickLook.close()
        scrollIntent = ScrollIntent(kind: .top)
        refreshResults(resetSelection: true, blockCommands: true)
    }

    private func refreshResults(resetSelection: Bool, blockCommands: Bool) {
        searchTask?.cancel()
        nextCursor = nil
        if resetSelection { loadedPageCount = 1 }
        if blockCommands { searchReady = false }

        let request = searchRequest
        let pageLimit = Self.pageSize * loadedPageCount
        let startingPageCount = loadedPageCount
        let restoredID = pendingRestoredItemID
        searchTask = Task { [weak self] in
            guard let self else { return }
            if restoredID != nil { await core.clipboardStore.waitForSearchMetadata() }
            guard self.searchIsCurrent(request) else { return }
            var page = await core.clipboardStore.searchAsync(
                request.query, kind: request.kind.kind, stackID: request.stackID,
                after: nil, limit: pageLimit)
            if page.failed {
                self.keepCurrentResultsAfterFailedSearch(request)
                return
            }
            var pageCount = startingPageCount
            // An undo may reveal an older search result after the user changed filters.
            // Load through that entry so selection and subsequent pagination stay coherent.
            if let restoredID {
                var restoredResults = page.items
                var seen = Set(restoredResults.map(\.id))
                while !restoredResults.contains(where: { $0.id == restoredID }),
                    let cursor = page.nextCursor, !Task.isCancelled
                {
                    page = await core.clipboardStore.searchAsync(
                        request.query, kind: request.kind.kind, stackID: request.stackID,
                        after: cursor, limit: Self.pageSize)
                    if page.failed {
                        self.keepCurrentResultsAfterFailedSearch(request)
                        return
                    }
                    restoredResults.append(
                        contentsOf: page.items.filter { seen.insert($0.id).inserted })
                    pageCount += 1
                }
                page = ClipboardSearchPage(items: restoredResults, nextCursor: page.nextCursor)
            }
            guard self.searchIsCurrent(request) else { return }
            nextCursor = page.nextCursor
            loadedPageCount = pageCount
            applyResults(page.items, resetSelection: resetSelection)
            if let restoredID, pendingRestoredItemID == restoredID {
                pendingRestoredItemID = nil
                if results.contains(where: { $0.id == restoredID }) {
                    selectedID = restoredID
                    scrollIntent = ScrollIntent(kind: .follow)
                }
            }
            searchTask = nil
        }
    }

    func loadMoreResults() {
        guard searchReady, let initialCursor = nextCursor, searchTask == nil else { return }
        let request = searchRequest
        searchTask = Task { [weak self] in
            guard let self else { return }
            var cursor = initialCursor
            var seen = Set(results.map(\.id))
            while true {
                let page = await core.clipboardStore.searchAsync(
                    request.query, kind: request.kind.kind, stackID: request.stackID,
                    after: cursor, limit: Self.pageSize)
                guard self.searchIsCurrent(request), self.nextCursor == cursor else { return }
                if page.failed { break }
                nextCursor = page.nextCursor
                loadedPageCount += 1
                let additions = page.items.filter { seen.insert($0.id).inserted }
                if !additions.isEmpty {
                    results.append(contentsOf: additions)
                    resultsGeneration &+= 1
                    break
                }
                guard let next = page.nextCursor else { break }
                cursor = next
            }
            searchTask = nil
        }
    }

    /// A database error is not an empty history. Leave the visible page in place when this search is still current.
    private func keepCurrentResultsAfterFailedSearch(_ request: SearchRequest) {
        guard searchIsCurrent(request) else { return }
        searchReady = true
        searchTask = nil
    }

    private func applyResults(
        _ newResults: [ClipboardItem], resetSelection: Bool
    ) {
        // Preserve the user's current selection, including navigation performed while the
        // background query was running, rather than restoring its request-time snapshot.
        let priorID = selectedID
        let priorIndex = selectionIndex
        resultsKindFilter = kindFilter
        resultsStackFilter = stackFilter
        results = newResults
        resultsGeneration &+= 1
        searchReady = true

        guard !newResults.isEmpty else {
            selectedID = nil
            closeMenu()
            return
        }
        if resetSelection {
            selectedID = newResults[0].id
        } else if let priorID, newResults.contains(where: { $0.id == priorID }) {
            selectedID = priorID
        } else if priorID == nil {
            selectedID = nil
        } else {
            let index = min(priorIndex, newResults.count - 1)
            selectedID = newResults[index].id
        }

        switch overlay {
        case .actions(let id), .addToStack(let id):
            if !newResults.contains(where: { $0.id == id }) {
                closeMenu()
            }
        case .none, .appMenu, .typeFilter, .stackFilter, .stackActions:
            break
        }
    }
}
