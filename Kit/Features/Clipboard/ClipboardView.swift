import AppKit
import SwiftUI

struct ClipboardList: View {
    let results: [ClipboardItem]
    let selectedID: ClipboardItem.ID?
    let query: String
    /// Changes only when the list should scroll (keyboard nav / reset), so mouse selection never yanks the scroll position.
    let scroll: ScrollIntent
    let hoverEnabled: Bool
    let onSelect: (ClipboardItem) -> Void
    let onActions: (ClipboardItem) -> Void
    let renamingID: ClipboardItem.ID?
    let renameDraft: String
    let onCommitRename: (String) -> Void
    @EnvironmentObject private var store: ClipboardStore
    @State private var geometry = ClipboardTableGeometry()
    @State private var scrollActivity = UUID()

    var body: some View {
        ClipboardTableRepresentable(
            results: results,
            selectedID: selectedID,
            query: query,
            scroll: scroll,
            hoverEnabled: hoverEnabled,
            store: store,
            onSelect: onSelect,
            onActions: onActions,
            renamingID: renamingID,
            renameDraft: renameDraft,
            onCommitRename: onCommitRename,
            onGeometryChange: { geometry = $0 },
            onScrollActivity: { scrollActivity = UUID() }
        )
        .edgeDissolve(state: geometry.dissolve)
        .thinScrollbar(metrics: geometry.scrollbar, scrollToken: scrollActivity)
    }
}

private struct ClipboardTableGeometry: Equatable {
    var scrollbar = ThinScrollbarMetrics()
    var dissolve = EdgeDissolveScrollState()
}

private enum ClipboardTableSection: Int, CaseIterable {
    case pinned, today, yesterday, pastSevenDays, pastThirtyDays, earlier

    var title: String {
        switch self {
        case .pinned: return "Pinned"
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .pastSevenDays: return "Past 7 Days"
        case .pastThirtyDays: return "Past 30 Days"
        case .earlier: return "Earlier"
        }
    }

    static func section(
        for item: ClipboardItem, today: Date, calendar: Calendar
    ) -> ClipboardTableSection {
        guard !item.isPinned else { return .pinned }
        let itemDay = calendar.startOfDay(for: item.createdAt)
        let elapsedDays = max(
            0, calendar.dateComponents([.day], from: itemDay, to: today).day ?? .max)
        switch elapsedDays {
        case 0: return .today
        case 1: return .yesterday
        case 2...7: return .pastSevenDays
        case 8...30: return .pastThirtyDays
        default: return .earlier
        }
    }
}

private enum ClipboardTableRow {
    case header(ClipboardTableSection)
    case item(ClipboardItem)

    var id: String {
        switch self {
        case .header(let section): return "header-\(section.rawValue)"
        case .item(let item): return item.id.uuidString
        }
    }
}

private struct ClipboardTableRepresentable: NSViewRepresentable {
    let results: [ClipboardItem]
    let selectedID: ClipboardItem.ID?
    let query: String
    let scroll: ScrollIntent
    let hoverEnabled: Bool
    let store: ClipboardStore
    let onSelect: (ClipboardItem) -> Void
    let onActions: (ClipboardItem) -> Void
    let renamingID: ClipboardItem.ID?
    let renameDraft: String
    let onCommitRename: (String) -> Void
    let onGeometryChange: (ClipboardTableGeometry) -> Void
    let onScrollActivity: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ClipboardTableContainerView {
        context.coordinator.makeContainerView()
    }

    func updateNSView(_ containerView: ClipboardTableContainerView, context: Context) {
        context.coordinator.update(
            results: results,
            selectedID: selectedID,
            query: query,
            scroll: scroll,
            hoverEnabled: hoverEnabled,
            locale: context.environment.locale,
            store: store,
            onSelect: onSelect,
            onActions: onActions,
            renamingID: renamingID,
            renameDraft: renameDraft,
            onCommitRename: onCommitRename,
            onGeometryChange: onGeometryChange,
            onScrollActivity: onScrollActivity
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        private var rows: [ClipboardTableRow] = []
        private var selectedID: ClipboardItem.ID?
        private var query = ""
        private var locale = Locale.current
        private weak var store: ClipboardStore?
        private var onSelect: ((ClipboardItem) -> Void)?
        private var onActions: ((ClipboardItem) -> Void)?
        private var onCommitRename: ((String) -> Void)?
        private var onGeometryChange: ((ClipboardTableGeometry) -> Void)?
        private var onScrollActivity: (() -> Void)?
        private var renamingID: ClipboardItem.ID?
        private var renameDraft = ""
        private var editingID: ClipboardItem.ID?
        private var boundsToken: NotificationToken?
        private weak var hostedContainerView: ClipboardTableContainerView?
        private var lastScroll: ScrollIntent?
        private var applyingSelection = false
        private var lastGeometry = ClipboardTableGeometry()
        private var lastBoundsOrigin: NSPoint?

        private let itemIdentifier = NSUserInterfaceItemIdentifier("ClipboardItemCell")
        private let headerIdentifier = NSUserInterfaceItemIdentifier("ClipboardHeaderCell")

        func makeContainerView() -> ClipboardTableContainerView {
            let tableView = ClipboardTableView()
            tableView.headerView = nil
            tableView.backgroundColor = .clear
            tableView.usesAlternatingRowBackgroundColors = false
            tableView.style = .plain
            tableView.rowSizeStyle = .custom
            tableView.gridStyleMask = []
            tableView.intercellSpacing = .zero
            tableView.selectionHighlightStyle = .none
            tableView.allowsMultipleSelection = false
            tableView.allowsEmptySelection = false
            tableView.focusRingType = .none
            tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            tableView.dataSource = self
            tableView.delegate = self
            tableView.onRightClick = { [weak self] row in self?.rightClicked(row) }

            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Clipboard"))
            column.resizingMask = .autoresizingMask
            tableView.addTableColumn(column)

            let scrollView = ClipboardTableScrollView()
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsets(
                top: Theme.Spacing.xs,
                left: 0,
                bottom: Theme.Spacing.md,
                right: 0
            )
            scrollView.contentView.drawsBackground = false
            scrollView.documentView = tableView
            scrollView.onGeometryChange = { [weak self] scrolling in
                self?.reportGeometry(scrolling: scrolling)
            }
            scrollView.contentView.postsBoundsChangedNotifications = true
            let token = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.boundsChanged(scrollView.contentView.bounds.origin) }
            }
            boundsToken = NotificationToken(token, center: .default)

            let containerView = ClipboardTableContainerView(scrollView: scrollView)
            containerView.renameField.delegate = self
            containerView.onLayout = { [weak self] in self?.positionRenameEditor() }
            hostedContainerView = containerView
            return containerView
        }

        func update(
            results: [ClipboardItem], selectedID: ClipboardItem.ID?, query: String,
            scroll: ScrollIntent, hoverEnabled: Bool, locale: Locale, store: ClipboardStore,
            onSelect: @escaping (ClipboardItem) -> Void,
            onActions: @escaping (ClipboardItem) -> Void,
            renamingID: ClipboardItem.ID?,
            renameDraft: String,
            onCommitRename: @escaping (String) -> Void,
            onGeometryChange: @escaping (ClipboardTableGeometry) -> Void,
            onScrollActivity: @escaping () -> Void
        ) {
            guard let tableView = tableView else { return }
            if !hoverEnabled {
                tableView.hoverEnabled = false
            }
            self.store = store
            self.onSelect = onSelect
            self.onActions = onActions
            self.renamingID = renamingID
            self.renameDraft = renameDraft
            self.onCommitRename = onCommitRename
            self.onGeometryChange = onGeometryChange
            self.onScrollActivity = onScrollActivity

            let newRows = Self.makeRows(results)
            let contentChanged = rows.map(\.id) != newRows.map(\.id)
            let titleChanged = zip(rows, newRows).contains { lhs, rhs in
                switch (lhs, rhs) {
                case (.item(let old), .item(let new)):
                    return old.customTitle != new.customTitle
                default:
                    return false
                }
            }
            let appearanceChanged = self.query != query || self.locale != locale
            rows = newRows
            self.query = query
            self.locale = locale

            let reloadRequired = contentChanged || titleChanged || appearanceChanged
            let wasApplyingSelection = applyingSelection
            if reloadRequired {
                // AppKit temporarily chooses the first selectable row during reload. Suppress
                // that implementation-detail callback until the model selection is restored.
                tableView.clearHover()
                applyingSelection = true
                tableView.reloadData()
            }
            applySelection(selectedID, to: tableView)
            applyingSelection = wasApplyingSelection

            if lastScroll != scroll {
                lastScroll = scroll
                apply(scroll, selectedID: selectedID, to: tableView)
            }
            syncInlineRename(in: tableView)
            tableView.hoverEnabled = hoverEnabled
            tableView.refreshHover()
            reportGeometry(scrolling: false)
        }

        private var tableView: ClipboardTableView? {
            hostedContainerView?.tableView
        }

        private static func makeRows(_ results: [ClipboardItem]) -> [ClipboardTableRow] {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            var grouped: [ClipboardTableSection: [ClipboardItem]] = [:]
            for item in results {
                let section = ClipboardTableSection.section(
                    for: item, today: today, calendar: calendar)
                grouped[section, default: []].append(item)
            }

            var rows: [ClipboardTableRow] = []
            for section in ClipboardTableSection.allCases {
                guard let items = grouped[section], !items.isEmpty else { continue }
                rows.append(.header(section))
                rows.append(contentsOf: items.map(ClipboardTableRow.item))
            }
            return rows
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            guard renamingID == nil else { return false }
            guard rows.indices.contains(row), case .item = rows[row] else { return false }
            return true
        }

        func selectionShouldChange(in tableView: NSTableView) -> Bool {
            renamingID == nil
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let tableView = notification.object as? NSTableView else {
                return
            }
            if let renamingID {
                applySelection(renamingID, to: tableView)
                return
            }
            let row = tableView.selectedRow
            guard rows.indices.contains(row), case .item(let item) = rows[row] else { return }
            selectedID = item.id
            updateVisibleSelection(in: tableView)
            onSelect?(item)
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row) else { return 0 }
            switch rows[row] {
            case .item: return 36
            case .header: return row == 0 ? 24 : 32
            }
        }

        func tableView(
            _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
        ) -> NSView? {
            guard rows.indices.contains(row) else { return nil }
            switch rows[row] {
            case .header(let section):
                let view =
                    tableView.makeView(withIdentifier: headerIdentifier, owner: self)
                        as? ClipboardSectionCellView ?? ClipboardSectionCellView()
                view.identifier = headerIdentifier
                view.configure(
                    title: Self.localized(section.title, locale: locale), isFirst: row == 0)
                return view
            case .item(let item):
                let view =
                    tableView.makeView(withIdentifier: itemIdentifier, owner: self)
                        as? ClipboardItemCellView ?? ClipboardItemCellView()
                view.identifier = itemIdentifier
                view.configure(
                    item: item,
                    selected: item.id == selectedID,
                    query: query,
                    imageURL: store?.imageURL(for: item),
                    locale: locale
                )
                view.setTitleHidden(item.id == editingID)
                return view
            }
        }

        private func rightClicked(_ row: Int) {
            guard renamingID == nil, let tableView, rows.indices.contains(row),
                case .item(let item) = rows[row]
            else {
                return
            }
            applyingSelection = true
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            applyingSelection = false
            selectedID = item.id
            updateVisibleSelection(in: tableView)
            onActions?(item)
        }

        private func rowIndex(for id: ClipboardItem.ID) -> Int? {
            rows.firstIndex {
                if case .item(let item) = $0 { return item.id == id }
                return false
            }
        }

        private func itemCell(at row: Int, in tableView: NSTableView, makeIfNecessary: Bool)
            -> ClipboardItemCellView?
        {
            tableView.view(atColumn: 0, row: row, makeIfNecessary: makeIfNecessary)
                as? ClipboardItemCellView
        }

        private func syncInlineRename(in tableView: NSTableView) {
            guard let renamingID else {
                endInlineRename()
                return
            }
            if editingID == renamingID {
                positionRenameEditor()
                return
            }
            beginInlineRename(renamingID)
        }

        private func beginInlineRename(_ id: ClipboardItem.ID) {
            guard let containerView = hostedContainerView, let tableView,
                let row = rowIndex(for: id)
            else { return }

            tableView.scrollRowToVisible(row)
            editingID = id
            containerView.renameField.stringValue = renameDraft
            positionRenameEditor()

            DispatchQueue.main.async { [weak self, weak containerView] in
                guard let self, let containerView, self.editingID == id,
                    self.renamingID == id
                else { return }
                self.positionRenameEditor()
                containerView.window?.makeFirstResponder(containerView.renameField)
                containerView.renameField.currentEditor()?.selectAll(nil)
            }
        }

        private func endInlineRename() {
            editingID = nil
            if let containerView = hostedContainerView {
                containerView.renameField.isHidden = true
                if containerView.renameField.currentEditor() != nil {
                    containerView.window?.makeFirstResponder(nil)
                }
            }
            guard let tableView else { return }
            tableView.enumerateAvailableRowViews { _, row in
                (tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? ClipboardItemCellView)?.setTitleHidden(false)
            }
        }

        private func positionRenameEditor() {
            guard let id = editingID, renamingID == id,
                let containerView = hostedContainerView, let tableView,
                let row = rowIndex(for: id)
            else {
                hostedContainerView?.renameField.isHidden = true
                return
            }

            tableView.layoutSubtreeIfNeeded()
            guard let cell = itemCell(at: row, in: tableView, makeIfNecessary: true) else {
                containerView.renameField.isHidden = true
                return
            }
            cell.layoutSubtreeIfNeeded()
            cell.setTitleHidden(true)
            containerView.renameField.frame = cell.titleFrame(in: containerView).insetBy(
                dx: -4, dy: -2)
            containerView.renameField.isHidden = false
        }

        func controlTextDidChange(_ obj: Notification) {
            guard editingID != nil, let field = obj.object as? NSTextField,
                field === hostedContainerView?.renameField
            else { return }
            renameDraft = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField,
                field === hostedContainerView?.renameField
            else { return }
            commitInlineRename(field.stringValue)
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)),
                control === hostedContainerView?.renameField
            else { return false }
            commitInlineRename(textView.string)
            return true
        }

        private func commitInlineRename(_ title: String) {
            guard let id = editingID, renamingID == id else { return }
            editingID = nil
            onCommitRename?(title)
        }

        private func applySelection(_ id: ClipboardItem.ID?, to tableView: NSTableView) {
            selectedID = id
            let row = rows.firstIndex {
                if case .item(let item) = $0 { return item.id == id }
                return false
            }
            let wasApplyingSelection = applyingSelection
            applyingSelection = true
            if let row {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            } else {
                // Keep click behavior single-selected while still permitting the intentional
                // no-selection state used when the palette first opens.
                tableView.allowsEmptySelection = true
                tableView.deselectAll(nil)
                tableView.allowsEmptySelection = false
            }
            applyingSelection = wasApplyingSelection
            updateVisibleSelection(in: tableView)
        }

        private func updateVisibleSelection(in tableView: NSTableView) {
            tableView.enumerateAvailableRowViews { _, row in
                guard self.rows.indices.contains(row), case .item(let item) = self.rows[row]
                else { return }
                (tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? ClipboardItemCellView)?.setSelected(item.id == self.selectedID)
            }
        }

        private func apply(
            _ scroll: ScrollIntent, selectedID: ClipboardItem.ID?, to tableView: NSTableView
        ) {
            switch scroll.kind {
            case .top:
                scrollToTop(tableView)
            case .follow:
                if selectedID == resultsFirstItemID {
                    scrollToTop(tableView)
                } else if let row = rows.firstIndex(where: {
                    if case .item(let item) = $0 { return item.id == selectedID }
                    return false
                }) {
                    tableView.scrollRowToVisible(row)
                }
            }
        }

        private var resultsFirstItemID: ClipboardItem.ID? {
            rows.compactMap {
                if case .item(let item) = $0 { return item.id }
                return nil
            }.first
        }

        private func scrollToTop(_ tableView: NSTableView) {
            guard let scrollView = tableView.enclosingScrollView else { return }
            let clip = scrollView.contentView
            clip.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
            scrollView.reflectScrolledClipView(clip)
        }

        private func reportGeometry(scrolling: Bool) {
            guard let tableView, let scrollView = tableView.enclosingScrollView else { return }
            let viewport = scrollView.contentView.bounds.height
            let content =
                tableView.bounds.height + scrollView.contentInsets.top
                + scrollView.contentInsets.bottom
            let maxOffset = max(0, content - viewport)
            let offset = min(
                maxOffset,
                max(0, scrollView.contentView.bounds.minY + scrollView.contentInsets.top)
            )
            let geometry = ClipboardTableGeometry(
                scrollbar: ThinScrollbarMetrics(
                    offset: offset, insetTop: 0, content: content, viewport: viewport),
                dissolve: EdgeDissolveScrollState(
                    top: offset, bottom: max(0, maxOffset - offset),
                    canScroll: content > viewport + 1)
            )
            guard geometry != lastGeometry || scrolling else { return }
            lastGeometry = geometry
            let geometryCallback = onGeometryChange
            let activityCallback = scrolling ? onScrollActivity : nil
            DispatchQueue.main.async {
                geometryCallback?(geometry)
                activityCallback?()
            }
        }

        private func boundsChanged(_ origin: NSPoint) {
            let scrolling = lastBoundsOrigin.map { $0 != origin } ?? false
            lastBoundsOrigin = origin
            positionRenameEditor()
            tableView?.refreshHover()
            reportGeometry(scrolling: scrolling)
        }

        private static func localized(_ title: String, locale: Locale) -> String {
            switch title {
            case "Pinned": return String(localized: "Pinned", locale: locale)
            case "Today": return String(localized: "Today", locale: locale)
            case "Yesterday": return String(localized: "Yesterday", locale: locale)
            case "Past 7 Days": return String(localized: "Past 7 Days", locale: locale)
            case "Past 30 Days": return String(localized: "Past 30 Days", locale: locale)
            default: return String(localized: "Earlier", locale: locale)
            }
        }
    }
}

private final class ClipboardTableContainerView: NSView {
    let scrollView: ClipboardTableScrollView
    let renameField = NSTextField(frame: .zero)
    var onLayout: (() -> Void)?

    var tableView: ClipboardTableView? {
        scrollView.documentView as? ClipboardTableView
    }

    init(scrollView: ClipboardTableScrollView) {
        self.scrollView = scrollView
        super.init(frame: .zero)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        renameField.font = .preferredFont(forTextStyle: .body)
        renameField.textColor = .labelColor
        renameField.isBordered = false
        renameField.isBezeled = false
        renameField.isEditable = true
        renameField.isSelectable = true
        renameField.drawsBackground = true
        renameField.backgroundColor = .controlBackgroundColor
        renameField.focusRingType = .exterior
        renameField.cell?.usesSingleLineMode = true
        renameField.cell?.wraps = false
        renameField.cell?.isScrollable = true
        renameField.wantsLayer = true
        renameField.layer?.cornerRadius = 4
        renameField.layer?.cornerCurve = .continuous
        renameField.isHidden = true
        addSubview(renameField)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        (window as? PalettePanel)?.registerRenameField(renameField)
    }

    override func layout() {
        super.layout()
        onLayout?()
    }
}

private final class ClipboardTableScrollView: NSScrollView {
    var onGeometryChange: ((Bool) -> Void)?

    override func layout() {
        super.layout()
        onGeometryChange?(false)
    }
}

private final class ClipboardTableView: NSTableView {
    private static let hoverIntentDelay: Duration = .milliseconds(200)

    var onRightClick: ((Int) -> Void)?
    var hoverEnabled = true {
        didSet {
            guard hoverEnabled != oldValue else { return }
            if hoverEnabled {
                refreshHover()
            } else {
                clearHover()
            }
        }
    }

    private var hoveredRow: Int?
    private var hoverTrackingArea: NSTrackingArea?
    private var lastPointerLocation: NSPoint?
    private var pendingHoverRow: Int?
    private var pendingHoverTask: Task<Void, Never>?

    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearHover()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            clearHover()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return }
        onRightClick?(row)
    }

    func refreshHover() {
        guard hoverEnabled, let window else {
            clearHover()
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard visibleRect.contains(point) else {
            clearHover()
            return
        }
        updateHover(at: point)
    }

    func clearHover() {
        hoveredRow = nil
        lastPointerLocation = nil
        cancelPendingHover()
    }

    private func updateHover(at point: NSPoint) {
        guard hoverEnabled, pointerHitsTable(at: point) else {
            clearHover()
            return
        }
        let previousPoint = lastPointerLocation
        if pendingHoverRow == row(at: point),
            let previousPoint,
            abs(previousPoint.x - point.x) < 0.5,
            abs(previousPoint.y - point.y) < 0.5
        {
            return
        }
        lastPointerLocation = point

        let row = row(at: point)
        guard row >= 0,
            view(atColumn: 0, row: row, makeIfNecessary: false) is ClipboardItemCellView
        else {
            cancelPendingHover()
            return
        }

        // A click or keyboard command may have selected the row before the next pointer event.
        // Fold that state back into hover tracking instead of starting an obsolete intent delay.
        if selectedRow == row {
            hoveredRow = row
            cancelPendingHover()
            return
        }
        guard hoveredRow != row else { return }

        if hoveredRow != nil,
            let previousPoint,
            isMovingTowardDetails(from: previousPoint, to: point)
        {
            scheduleHoverSelection(for: row)
            return
        }
        activateHoverSelection(for: row, at: point)
    }

    /// The previous pointer position and the visible detail-facing edge form a menu-aim triangle.
    /// Crossing sibling rows inside this corridor is treated as transit toward the preview, not as
    /// an intent to select them.
    private func isMovingTowardDetails(from start: NSPoint, to end: NSPoint) -> Bool {
        guard end.x > start.x + 0.5, start.x < visibleRect.maxX else { return false }
        let upperRight = NSPoint(x: visibleRect.maxX, y: visibleRect.minY)
        let lowerRight = NSPoint(x: visibleRect.maxX, y: visibleRect.maxY)
        return Self.point(end, isInsideTriangleWith: start, upperRight, lowerRight)
    }

    private static func point(
        _ point: NSPoint, isInsideTriangleWith first: NSPoint, _ second: NSPoint, _ third: NSPoint
    ) -> Bool {
        func signedArea(_ lhs: NSPoint, _ rhs: NSPoint, _ anchor: NSPoint) -> CGFloat {
            (lhs.x - anchor.x) * (rhs.y - anchor.y)
                - (rhs.x - anchor.x) * (lhs.y - anchor.y)
        }

        let firstSign = signedArea(point, first, second)
        let secondSign = signedArea(point, second, third)
        let thirdSign = signedArea(point, third, first)
        let hasNegative = firstSign < 0 || secondSign < 0 || thirdSign < 0
        let hasPositive = firstSign > 0 || secondSign > 0 || thirdSign > 0
        return !(hasNegative && hasPositive)
    }

    private func scheduleHoverSelection(for row: Int) {
        pendingHoverTask?.cancel()
        pendingHoverRow = row
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.hoverIntentDelay)
            guard !Task.isCancelled else { return }
            self?.activatePendingHoverSelection(for: row)
        }
        pendingHoverTask = task
    }

    private func activatePendingHoverSelection(for row: Int) {
        guard pendingHoverRow == row else { return }
        pendingHoverRow = nil
        pendingHoverTask = nil
        guard hoverEnabled, let window else { return }

        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard visibleRect.contains(point), pointerHitsTable(at: point), self.row(at: point) == row,
            view(atColumn: 0, row: row, makeIfNecessary: false) is ClipboardItemCellView
        else { return }
        activateHoverSelection(for: row, at: point)
    }

    private func activateHoverSelection(for row: Int, at point: NSPoint) {
        cancelPendingHover()
        hoveredRow = row
        lastPointerLocation = point
        if selectedRow != row {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    private func cancelPendingHover() {
        pendingHoverTask?.cancel()
        pendingHoverTask = nil
        pendingHoverRow = nil
    }

    /// Tracking areas receive movement even when a SwiftUI overlay is visually above this AppKit
    /// view. Verify the window's real hit-test target so menus and rename controls cannot leak
    /// hover into rows underneath them.
    private func pointerHitsTable(at point: NSPoint) -> Bool {
        guard let contentView = window?.contentView else { return false }
        let pointInWindow = convert(point, to: nil)
        let pointInContent = contentView.convert(pointInWindow, from: nil)
        var hitView = contentView.hitTest(pointInContent)
        while let view = hitView {
            if view === self { return true }
            hitView = view.superview
        }
        return false
    }
}

private final class ClipboardSectionCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private var topConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let size = NSFont.preferredFont(forTextStyle: .subheadline).pointSize
        titleLabel.font = .systemFont(ofSize: size, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        topConstraint = titleLabel.topAnchor.constraint(equalTo: topAnchor)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            topConstraint,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, isFirst: Bool) {
        titleLabel.stringValue = title
        topConstraint.constant = isFirst ? Theme.Spacing.xs : Theme.Spacing.sectionSpacing
    }
}

private final class ClipboardItemCellView: NSTableCellView {
    private let highlightView = NSView()
    private let thumbnailView = ClipboardThumbnailView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var selected = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = Theme.Radius.row
        highlightView.layer?.cornerCurve = .continuous
        highlightView.translatesAutoresizingMaskIntoConstraints = false

        thumbnailView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.cell?.wraps = false
        titleLabel.cell?.isScrollable = false
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = titleLabel

        addSubview(highlightView)
        addSubview(thumbnailView)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            highlightView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            highlightView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            highlightView.topAnchor.constraint(equalTo: topAnchor),
            highlightView.bottomAnchor.constraint(equalTo: bottomAnchor),

            thumbnailView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            thumbnailView.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnailView.widthAnchor.constraint(equalToConstant: Theme.Size.rowIcon),
            thumbnailView.heightAnchor.constraint(equalToConstant: Theme.Size.rowIcon),

            titleLabel.leadingAnchor.constraint(
                equalTo: thumbnailView.trailingAnchor, constant: Theme.Spacing.lg),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -16),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.heightAnchor.constraint(lessThanOrEqualToConstant: Theme.Size.rowIcon),
        ])
        updateSelectionColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        titleLabel.isHidden = false
        thumbnailView.prepareForReuse()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSelectionColor()
        thumbnailView.refreshAppearance()
    }

    func configure(
        item: ClipboardItem, selected: Bool, query: String, imageURL: URL?, locale: Locale
    ) {
        self.selected = selected
        updateSelectionColor()
        titleLabel.attributedStringValue = SearchHighlight.nsAttributed(
            item.displayTitle(locale: locale),
            query: query,
            font: .preferredFont(forTextStyle: .body))
        thumbnailView.configure(item: item, imageURL: imageURL)
    }

    func setTitleHidden(_ hidden: Bool) {
        titleLabel.isHidden = hidden
    }

    func titleFrame(in view: NSView) -> NSRect {
        titleLabel.convert(titleLabel.bounds, to: view)
    }

    func setSelected(_ selected: Bool) {
        guard self.selected != selected else { return }
        self.selected = selected
        updateSelectionColor()
    }

    private func updateSelectionColor() {
        highlightView.layer?.backgroundColor =
            selected ? NSColor.labelColor.withAlphaComponent(0.10).cgColor : NSColor.clear.cgColor
    }
}

private final class ClipboardThumbnailView: NSView {
    /// Well above the 48 device pixels needed by the 24pt row slot on a 2× display, leaving enough
    /// source detail for high-quality final downsampling.
    private static let imageMaxPixel: CGFloat = 128
    private static let markdownCache = NSCache<NSUUID, NSNumber>()

    private let symbolView = NSImageView()
    private var representedID: ClipboardItem.ID?
    private var loadTask: Task<Void, Never>?
    private var displayedImage: NSImage?
    private var placeholder: LucideIconName = .image

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.thumbnail
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspectFill

        symbolView.imageScaling = .scaleProportionallyDown
        symbolView.contentTintColor = .secondaryLabelColor
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(symbolView)

        NSLayoutConstraint.activate([
            symbolView.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 14),
            symbolView.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        refreshAppearance()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let image = displayedImage, image.size.width > 0, image.size.height > 0 else {
            return
        }
        let factor = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * factor, height: image.size.height * factor)
        let destination = NSRect(
            x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
            width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: destination, from: .zero, operation: .copy, fraction: 1,
            respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    func configure(item: ClipboardItem, imageURL: URL?) {
        loadTask?.cancel()
        representedID = item.id
        displayedImage = nil

        switch item.kind {
        case .text:
            showDisplayKind(.text)
            loadMarkdownIfNeeded(item, stored: .text)
        case .code:
            showDisplayKind(.code)
            loadMarkdownIfNeeded(item, stored: .code)
        case .link:
            showDisplayKind(.link)
        case .image:
            showDisplayKind(.image)
            guard let imageURL else { return }
            if let cached = ImageThumbnail.cached(
                imageURL, maxPixel: Self.imageMaxPixel)
            {
                showImage(cached)
                return
            }
            let id = item.id
            loadTask = Task { @MainActor [weak self] in
                let image = await ImageThumbnail.loadAsync(
                    imageURL, maxPixel: Self.imageMaxPixel)
                guard !Task.isCancelled, let self, representedID == id, let image else { return }
                showImage(image)
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        representedID = nil
        displayedImage = nil
        showDisplayKind(.image)
    }

    func refreshAppearance() {
        guard let displayedImage else {
            showLucide(placeholder)
            return
        }
        showImage(displayedImage)
    }

    private func loadMarkdownIfNeeded(_ item: ClipboardItem, stored: ClipboardItem.DisplayKind) {
        guard let source = item.text, !source.isEmpty else { return }
        let cacheKey = item.id as NSUUID
        if let cached = Self.markdownCache.object(forKey: cacheKey) {
            if cached.boolValue { showDisplayKind(.markdown) }
            return
        }
        let id = item.id
        loadTask = Task { @MainActor [weak self] in
            let kind = await Task.detached(priority: .utility) {
                ClipboardItem.DisplayKind.classify(kind: item.kind, text: source)
            }.value
            Self.markdownCache.setObject(NSNumber(value: kind == .markdown), forKey: cacheKey)
            guard !Task.isCancelled, let self, representedID == id else { return }
            showDisplayKind(kind == .markdown ? .markdown : stored)
        }
    }

    private func showDisplayKind(_ kind: ClipboardItem.DisplayKind) {
        showLucide(kind.lucideIcon)
    }

    private func showLucide(_ name: LucideIconName) {
        placeholder = name
        displayedImage = nil
        layer?.contents = nil
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        needsDisplay = true
        symbolView.isHidden = false
        symbolView.image = name.templateImage(pointSize: 14)
    }

    private func showImage(_ image: NSImage) {
        displayedImage = image
        symbolView.isHidden = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.contents = nil
        needsDisplay = true
    }
}

/// Renders a downsampled clipboard thumbnail, decoding misses off the main thread (cache hits resolve on the first tick, misses show `placeholder`); `content` styles the loaded image per site.
private struct AsyncThumbnail<Content: View, Placeholder: View>: View {
    let url: URL?
    let maxPixel: CGFloat
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                content(Image(nsImage: image))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            if let hit = ImageThumbnail.cached(url, maxPixel: maxPixel) {
                image = hit
                return
            }
            image = nil  // show the placeholder while a new image decodes
            let loaded = await ImageThumbnail.loadAsync(url, maxPixel: maxPixel)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

struct ClipboardPreview: View {
    /// The preview pane is ~460pt wide (panel 750 − list 290); 900px keeps it crisp at 2× Retina without over-decoding.
    private static let previewMaxPixel: CGFloat = 900

    let item: ClipboardItem?
    var query: String = ""
    @EnvironmentObject private var store: ClipboardStore
    @EnvironmentObject private var vm: PaletteViewModel
    @ObservedObject private var settings = AppCore.shared.settings
    @State private var codeRendersAsMarkdown = false

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: 0) {
                content(for: item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                ClipboardInfoSection(item: item, imageURL: store.imageURL(for: item))
            }
            .padding(.horizontal, 12)
            .task(id: item.id) {
                await refreshCodeMarkdown(item)
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func content(for item: ClipboardItem) -> some View {
        switch item.kind {
        case .text:
            if settings.renderMarkdown {
                MarkdownPreview(source: item.text ?? "", query: query)
            } else {
                SelectableAttributedText(
                    attributed: SearchHighlight.attributed(item.text ?? "", query: query)
                )
            }
        case .link:
            SelectableAttributedText(
                attributed: SearchHighlight.attributed(item.text ?? "", query: query)
            )
        case .code:
            if settings.renderMarkdown, codeRendersAsMarkdown {
                MarkdownPreview(source: item.text ?? "", query: query)
            } else {
                CodePreview(code: item.text ?? "", query: query)
            }
        case .image:
            let imageURL = store.imageURL(for: item)
            AsyncThumbnail(url: imageURL, maxPixel: Self.previewMaxPixel) {
                image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .strokeBorder(Theme.Colors.cardStroke, lineWidth: 1)
                    )
            } placeholder: {
                Image(systemName: "photo").font(.system(.largeTitle))
                    .symbolRenderingMode(.hierarchical).foregroundStyle(.tertiary)
            }
            // Anchor to the thumbnail's fitted bounds, not the full preview pane, so the
            // NSPopover arrow points at the image and placement can avoid covering it.
            .overlay {
                ImageQuickLookAnchor(
                    url: imageURL,
                    isPresented: Binding(
                        get: { vm.imageQuickLookOpen },
                        set: { vm.imageQuickLookOpen = $0 }
                    )
                )
                .allowsHitTesting(false)
            }
        }
    }

    private func refreshCodeMarkdown(_ item: ClipboardItem) async {
        guard item.kind == .code, let text = item.text, !text.isEmpty else {
            codeRendersAsMarkdown = false
            return
        }
        let renders = await Task.detached(priority: .utility) {
            ClipboardTextClassifier.isMarkdownArticle(text)
        }.value
        guard !Task.isCancelled else { return }
        codeRendersAsMarkdown = renders
    }
}

/// The "Information" block under the preview (label/value rows split by hairlines); disk- or full-text-touching details are gathered off the main actor per selection so clicking huge entries never hitches.
private struct ClipboardInfoSection: View {
    let item: ClipboardItem
    let imageURL: URL?

    @State private var details = Details()
    @ObservedObject private var settings = AppCore.shared.settings

    private struct Details: Equatable, Sendable {
        var typeLabel: String?
        var characters: Int?
        var words: Int?
        var pixelSize: CGSize?
        var fileBytes: Int?
    }

    private struct InfoRow: Identifiable {
        let label: String
        let value: String
        var localizesValue = false
        var icon: NSImage?
        var id: String { label }
    }

    /// Relative day name plus exact time ("Today at 1:22:57 AM"); shared because `DateFormatter` is expensive to build.
    @MainActor private static let copiedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Information")
                .font(Theme.Typography.sectionHeader)
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                let rows = self.rows
                ForEach(rows) { row in
                    if row.id != rows.first?.id { Divider() }
                    HStack(spacing: Theme.Spacing.sm) {
                        Text(LocalizedStringKey(row.label)).foregroundStyle(.secondary)
                        Spacer(minLength: Theme.Spacing.lg)
                        if let icon = row.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 20, height: 20)
                        }
                        Group {
                            if row.localizesValue {
                                Text(LocalizedStringKey(row.value))
                            } else {
                                Text(row.value)
                            }
                        }
                        .lineLimit(1)
                        .truncationMode(.middle)
                    }
                    .font(.callout)
                    .padding(.vertical, Theme.Spacing.sm)
                }
            }
        }
        .padding(.top, Theme.Spacing.xl)
        .task(id: item.id) { await loadDetails() }
    }

    private var rows: [InfoRow] {
        var rows: [InfoRow] = []
        if let source {
            rows.append(InfoRow(label: "Source", value: source.name, icon: source.icon))
        }
        rows.append(
            InfoRow(
                label: "Type",
                value: details.typeLabel ?? item.kind.typeLabel,
                localizesValue: true))
        switch item.kind {
        case .text, .code, .link:
            if let characters = details.characters {
                rows.append(
                    InfoRow(
                        label: "Characters",
                        value: characters.formatted(
                            .number.locale(settings.language.locale))))
            }
            if let words = details.words {
                rows.append(
                    InfoRow(
                        label: "Words",
                        value: words.formatted(.number.locale(settings.language.locale))))
            }
        case .image:
            if let size = details.pixelSize {
                rows.append(
                    InfoRow(label: "Dimensions", value: "\(Int(size.width))×\(Int(size.height))"))
            }
            if let bytes = details.fileBytes {
                rows.append(
                    InfoRow(
                        label: "Size",
                        value: Int64(bytes).formatted(
                            .byteCount(style: .file).locale(settings.language.locale))))
            }
        }
        Self.copiedFormatter.locale = settings.language.locale
        rows.append(
            InfoRow(label: "Copied", value: Self.copiedFormatter.string(from: item.createdAt)))
        return rows
    }

    /// Source app name + icon from the recorded bundle ID; the Launch Services lookup is a quick main-thread call and the icon comes from the shared `IconCache`.
    private var source: (name: String, icon: NSImage)? {
        guard let bundleID = item.sourceBundleID,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return (url.deletingPathExtension().lastPathComponent, IconCache.icon(forFile: url.path))
    }

    private func loadDetails() async {
        let text = item.text
        let url = imageURL
        let loaded = await Task.detached(priority: .userInitiated) {
            var details = Details()
            details.typeLabel = ClipboardItem.DisplayKind.classify(
                kind: item.kind, text: text
            ).typeLabel
            if let text {
                details.characters = text.count
                details.words = Self.wordCount(text)
            }
            if let url {
                details.pixelSize = ImageThumbnail.pixelSize(of: url)
                details.fileBytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            }
            return details
        }.value
        guard !Task.isCancelled else { return }
        details = loaded
    }

    /// Single pass over scalars — `split(whereSeparator:)` would allocate a substring per word, which matters for a multi-MB copy.
    private nonisolated static func wordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            let separator = CharacterSet.whitespacesAndNewlines.contains(scalar)
            if !separator && !inWord { count += 1 }
            inWord = !separator
        }
        return count
    }
}
