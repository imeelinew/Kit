import AppKit
import Combine
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

    var isMenu: Bool {
        switch self {
        case .actions, .appMenu, .typeFilter, .stackFilter, .stackActions, .addToStack: return true
        default: return false
        }
    }
}

enum StackNameEdit: Equatable {
    case create
    case rename(ClipboardStack.ID)
}

enum PaletteCommand: Equatable {
    case move(Int)
    case activate
    case copy
    case cancel
    case toggleActions
    case pinToScreen
    case revealInFinder
    case toggleQuickLook
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
    case setKindFilter(ClipboardKindFilter)
    /// `nil` is the clipboard, which shows every item.
    case setStackFilter(ClipboardStack?)
    case newStack
    case renameStack(ClipboardStack)
    case deleteStack(ClipboardStack)
}

extension ClipboardItem.DisplayKind {
    var symbolName: String {
        switch self {
        case .text: "textformat"
        case .markdown: "number"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .link: "link"
        case .image: "photo"
        }
    }
}

enum ClipboardKindFilter: Equatable, CaseIterable {
    case all, text, markdown, code, link, image

    var title: LocalizedStringKey {
        LocalizedStringKey(displayKind?.typeLabel ?? "All Types")
    }

    var symbolName: String {
        displayKind?.symbolName ?? "list.bullet"
    }

    var displayKind: ClipboardItem.DisplayKind? {
        switch self {
        case .all: nil
        case .text: .text
        case .markdown: .markdown
        case .code: .code
        case .link: .link
        case .image: .image
        }
    }
}

/// The palette's single interaction state machine. AppKit keyboard events and SwiftUI mouse
/// actions both enter here, so commands do not depend on whichever embedded view is first responder.
@MainActor
final class PaletteViewModel: ObservableObject {
    @Published var query = "" {
        didSet { queryChanged() }
    }
    @Published private(set) var kindFilter: ClipboardKindFilter = .all
    /// `nil` shows the whole clipboard. A stack id shows only items in that stack.
    @Published private(set) var stackFilter: ClipboardStack.ID?
    @Published var stackNameEdit: StackNameEdit?
    @Published var stackNameDraft = ""

    var isNamingStack: Bool { stackNameEdit != nil }

    var stackFilterTitle: String {
        if let stackFilter,
            let stack = core.clipboardStore.stacks.first(where: { $0.id == stackFilter })
        {
            return stack.name
        }
        return String(localized: "Clipboard")
    }
    @Published private(set) var results: [ClipboardItem] = []
    @Published private(set) var selectedID: ClipboardItem.ID?
    @Published private(set) var searchReady = true
    @Published var resetToken = UUID()
    @Published var followToken = UUID()
    @Published var pasteTarget: PasteTarget?
    @Published var imageQuickLookOpen = false
    @Published private(set) var overlay: PaletteOverlay = .none {
        didSet {
            if overlay.isOpen {
                imageQuickLookOpen = false
                ImageQuickLook.close()
            }
            if overlay != .stackFilter {
                stackNameEdit = nil
                stackNameDraft = ""
            }
            if oldValue.isMenu != overlay.isMenu {
                onMenuOpenChanged?(overlay.isMenu)
            }
        }
    }
    @Published var menuSelection = 0

    var onMenuOpenChanged: ((Bool) -> Void)?
    var onSearchFocusRequested: (() -> Void)?

    private unowned let core: AppCore
    private var searchTask: Task<Void, Never>?
    private var revisionObserver: AnyCancellable?

    init(core: AppCore) {
        self.core = core
        revisionObserver = core.clipboardStore.$revision
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                refreshResults(resetSelection: !searchReady, blockCommands: false)
            }
    }

    var menuOpen: Bool { overlay.isMenu }

    /// At an empty query, Space is reserved for Quick Look instead of starting blank search text.
    var canToggleQuickLook: Bool {
        !menuOpen && queryIsEmpty && selectedItem?.kind == .image
    }

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
            if item.kind == .image {
                actions.append(.pinToScreen(item))
                actions.append(.revealInFinder(item))
            }
            if !core.clipboardStore.stacks.isEmpty {
                actions.append(.addToStack(item))
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
            return core.clipboardStore.stacks.map { .assignToStack(item, $0) }
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
        stackNameEdit = nil
        overlay = .stackActions(stack.id)
        menuSelection = 0
    }

    func prepare() {
        searchTask?.cancel()
        overlay = .none
        menuSelection = 0
        imageQuickLookOpen = false
        query = ""
        // Opening the palette leaves selection entirely to pointer or keyboard intent.
        selectedID = nil
    }

    func select(_ id: ClipboardItem.ID, follow: Bool = false) {
        selectedID = id
        imageQuickLookOpen = false
        if follow { followToken = UUID() }
    }

    func openActions(for id: ClipboardItem.ID) {
        guard searchReady, item(withID: id) != nil else { return }
        select(id)
        overlay = .actions(id)
        menuSelection = 0
    }

    func toggleAppMenu() {
        overlay = overlay == .appMenu ? .none : .appMenu
        menuSelection = 0
    }

    func toggleTypeFilter() {
        if overlay == .typeFilter {
            overlay = .none
            menuSelection = 0
        } else {
            overlay = .typeFilter
            menuSelection = ClipboardKindFilter.allCases.firstIndex(of: kindFilter) ?? 0
        }
    }

    func toggleStackFilter() {
        if overlay == .stackFilter {
            overlay = .none
            menuSelection = 0
        } else {
            overlay = .stackFilter
            if let stackFilter,
                let index = core.clipboardStore.stacks.firstIndex(where: { $0.id == stackFilter })
            {
                menuSelection = index + 1
            } else {
                menuSelection = 0
            }
        }
    }

    func closeMenu() {
        overlay = .none
        menuSelection = 0
    }

    /// Esc removes only the front menu. A menu opened from another menu returns there.
    private func dismissMenuLayer() {
        switch overlay {
        case .stackActions(let id):
            overlay = .stackFilter
            if let index = core.clipboardStore.stacks.firstIndex(where: { $0.id == id }) {
                menuSelection = index + 1
            } else {
                menuSelection = 0
            }
        case .addToStack(let id):
            overlay = .actions(id)
            menuSelection = menuActions.firstIndex {
                if case .addToStack = $0 { return true }
                return false
            } ?? 0
        default:
            overlay = .none
            menuSelection = 0
        }
    }

    func activateMenuItem(at index: Int) {
        let actions = menuActions
        guard actions.indices.contains(index) else { return }
        switch actions[index] {
        case .paste, .pasteKeepingOpen:
            guard canPaste else { return }
        default:
            break
        }
        if case .newStack = actions[index] {
            beginStackName()
            return
        }
        if case .addToStack(let item) = actions[index] {
            overlay = .addToStack(item.id)
            menuSelection = 0
            return
        }
        if case .deleteStack = actions[index] {
            perform(actions[index])
            return
        }
        overlay = .none
        menuSelection = 0
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
            } else if searchReady, canPaste, let item = selectedItem {
                core.paste(item)
            }
        case .copy:
            guard searchReady, let item = actionTarget else { return true }
            overlay = .none
            core.copyToClipboard(item)
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
            overlay = overlay == .actions(id) ? .none : .actions(id)
            menuSelection = 0
        case .pinToScreen:
            guard searchReady, let item = actionTarget, item.kind == .image else { return true }
            overlay = .none
            core.pinToScreen(item)
        case .revealInFinder:
            guard searchReady, let item = actionTarget, item.kind == .image else { return true }
            overlay = .none
            core.revealClipboardImage(item)
        case .toggleQuickLook:
            guard canToggleQuickLook else { return menuOpen }
            imageQuickLookOpen.toggle()
        case .clearQuery:
            guard !menuOpen else { return true }
            if !queryIsEmpty { query = "" }
        case .settings:
            overlay = .none
            core.showSettings()
        case .quit:
            overlay = .none
            core.requestQuit()
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
        followToken = UUID()
    }

    private func moveMenu(_ delta: Int) {
        let count = menuActions.count
        guard count > 0 else { return }
        menuSelection = min(max(menuSelection + delta, 0), count - 1)
    }

    private func perform(_ action: PaletteMenuAction) {
        switch action {
        case .about:
            core.showAbout()
        case .checkForUpdates:
            core.checkForUpdates()
        case .settings:
            core.showSettings()
        case .quit:
            core.requestQuit()
        case .paste(let item):
            core.paste(item)
        case .pasteKeepingOpen(let item):
            core.pasteKeepingWindowOpen(item)
        case .copy(let item):
            core.copyToClipboard(item)
        case .pinToScreen(let item):
            guard item.kind == .image else { return }
            core.pinToScreen(item)
        case .revealInFinder(let item):
            core.revealClipboardImage(item)
        case .addToStack(let item):
            overlay = .addToStack(item.id)
            menuSelection = 0
        case .assignToStack(let item, let stack):
            core.clipboardStore.assign(item.id, to: stack.id)
        case .delete(let item):
            let removedIndex = selectionIndex
            core.clipboardStore.remove(item)
            results.removeAll { $0.id == item.id }
            if results.isEmpty {
                selectedID = nil
            } else {
                selectedID = results[min(removedIndex, results.count - 1)].id
            }
        case .setKindFilter(let filter):
            applyKindFilter(filter)
            onSearchFocusRequested?()
        case .setStackFilter(let stack):
            applyStackFilter(stack?.id)
            onSearchFocusRequested?()
        case .newStack:
            break
        case .renameStack(let stack):
            beginRename(stack)
        case .deleteStack(let stack):
            confirmDelete(stack)
        }
    }

    func beginStackName() {
        guard overlay == .stackFilter else { return }
        stackNameEdit = .create
        stackNameDraft = ""
    }

    func beginRename(_ stack: ClipboardStack) {
        stackNameDraft = stack.name
        stackNameEdit = .rename(stack.id)
        overlay = .stackFilter
        if let index = core.clipboardStore.stacks.firstIndex(where: { $0.id == stack.id }) {
            menuSelection = index + 1
        }
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
            stackNameEdit = nil
            stackNameDraft = ""
            overlay = .none
            menuSelection = 0
            applyStackFilter(stack.id)
        case .rename(let id):
            guard core.clipboardStore.renameStack(id, to: name) else { return }
            stackNameEdit = nil
            stackNameDraft = ""
            overlay = .none
            menuSelection = 0
            onSearchFocusRequested?()
        }
    }

    private func confirmDelete(_ stack: ClipboardStack) {
        let locale = core.settings.language.locale
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: String(localized: "Delete Stack %@?", locale: locale),
            locale: locale,
            stack.name
        )
        alert.informativeText = String(
            localized: "Items in this stack return to the clipboard.",
            locale: locale
        )
        alert.addButton(withTitle: String(localized: "Delete", locale: locale))
        alert.addButton(withTitle: String(localized: "Cancel", locale: locale))
        alert.buttons.first?.hasDestructiveAction = true
        guard core.runModalAlert(alert) == .alertFirstButtonReturn else { return }
        overlay = .none
        menuSelection = 0
        core.clipboardStore.deleteStack(stack.id)
        if stackFilter == stack.id {
            applyStackFilter(nil)
        }
    }

    private func applyStackFilter(_ stackID: ClipboardStack.ID?) {
        guard stackFilter != stackID else { return }
        stackFilter = stackID
        imageQuickLookOpen = false
        ImageQuickLook.close()
        resetToken = UUID()
        refreshResults(resetSelection: true, blockCommands: true)
    }

    private func applyKindFilter(_ filter: ClipboardKindFilter) {
        guard kindFilter != filter else { return }
        kindFilter = filter
        imageQuickLookOpen = false
        ImageQuickLook.close()
        resetToken = UUID()
        refreshResults(resetSelection: true, blockCommands: true)
    }

    private func queryChanged() {
        overlay = .none
        menuSelection = 0
        imageQuickLookOpen = false
        ImageQuickLook.close()
        resetToken = UUID()
        refreshResults(resetSelection: true, blockCommands: true)
    }

    private func refreshResults(resetSelection: Bool, blockCommands: Bool) {
        searchTask?.cancel()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let priorID = selectedID
        let priorIndex = selectionIndex
        if blockCommands { searchReady = false }

        let stackID = stackFilter
        if query.isEmpty && kindFilter == .all {
            applyResults(
                scoped(core.clipboardStore.displayItems, to: stackID),
                resetSelection: resetSelection,
                priorID: priorID,
                priorIndex: priorIndex)
            return
        }

        let filter = kindFilter
        searchTask = Task { [weak self] in
            guard let self else { return }
            let matches = await core.clipboardStore.searchAsync(
                query, displayKind: filter.displayKind)
            guard !Task.isCancelled,
                self.query.trimmingCharacters(in: .whitespacesAndNewlines) == query,
                self.kindFilter == filter,
                self.stackFilter == stackID
            else { return }
            applyResults(
                self.scoped(matches, to: stackID),
                resetSelection: resetSelection,
                priorID: priorID,
                priorIndex: priorIndex)
        }
    }

    private func scoped(_ items: [ClipboardItem], to stackID: ClipboardStack.ID?) -> [ClipboardItem] {
        guard let stackID else { return items }
        return items.filter { core.clipboardStore.stackID(for: $0.id) == stackID }
    }

    private func applyResults(
        _ newResults: [ClipboardItem], resetSelection: Bool,
        priorID: ClipboardItem.ID?, priorIndex: Int
    ) {
        results = newResults
        searchReady = true

        guard !newResults.isEmpty else {
            selectedID = nil
            overlay = .none
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
                overlay = .none
            }
        case .none, .appMenu, .typeFilter, .stackFilter, .stackActions:
            break
        }
    }
}
