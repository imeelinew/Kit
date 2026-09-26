import AppKit
import SwiftUI

struct ClipboardList: View {
    let results: [ClipboardItem]
    let resultsGeneration: UInt64
    let hasMoreResults: Bool
    let selectedID: ClipboardItem.ID?
    let query: String
    /// Changes only when the list should scroll (keyboard nav / reset), so mouse selection never yanks the scroll position.
    let scroll: ScrollIntent
    let hoverEnabled: Bool
    let store: ClipboardStore
    let onSelect: (ClipboardItem) -> Void
    let onActivate: (ClipboardItem) -> Void
    let onActions: (ClipboardItem) -> Void
    let onLoadMore: () -> Void
    @State private var geometry = ClipboardTableGeometry()
    @State private var scrollActivity = UUID()

    var body: some View {
        ClipboardTableRepresentable(
            results: results,
            resultsGeneration: resultsGeneration,
            hasMoreResults: hasMoreResults,
            selectedID: selectedID,
            query: query,
            scroll: scroll,
            hoverEnabled: hoverEnabled,
            store: store,
            onSelect: onSelect,
            onActivate: onActivate,
            onActions: onActions,
            onLoadMore: onLoadMore,
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
    case today, yesterday, pastSevenDays, pastThirtyDays, earlier

    var title: String {
        switch self {
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
    case more
}

private struct ClipboardTableRepresentable: NSViewRepresentable {
    let results: [ClipboardItem]
    let resultsGeneration: UInt64
    let hasMoreResults: Bool
    let selectedID: ClipboardItem.ID?
    let query: String
    let scroll: ScrollIntent
    let hoverEnabled: Bool
    let store: ClipboardStore
    let onSelect: (ClipboardItem) -> Void
    let onActivate: (ClipboardItem) -> Void
    let onActions: (ClipboardItem) -> Void
    let onLoadMore: () -> Void
    let onGeometryChange: (ClipboardTableGeometry) -> Void
    let onScrollActivity: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ClipboardTableContainerView {
        context.coordinator.makeContainerView()
    }

    func updateNSView(_ containerView: ClipboardTableContainerView, context: Context) {
        context.coordinator.update(
            results: results,
            resultsGeneration: resultsGeneration,
            hasMoreResults: hasMoreResults,
            selectedID: selectedID,
            query: query,
            scroll: scroll,
            hoverEnabled: hoverEnabled,
            locale: context.environment.locale,
            store: store,
            onSelect: onSelect,
            onActivate: onActivate,
            onActions: onActions,
            onLoadMore: onLoadMore,
            onGeometryChange: onGeometryChange,
            onScrollActivity: onScrollActivity
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var rows: [ClipboardTableRow] = []
        private var itemRowIndex: [ClipboardItem.ID: Int] = [:]
        private var selectedID: ClipboardItem.ID?
        private var query = ""
        private var locale = Locale.current
        private weak var store: ClipboardStore?
        private var onSelect: ((ClipboardItem) -> Void)?
        private var onActivate: ((ClipboardItem) -> Void)?
        private var onActions: ((ClipboardItem) -> Void)?
        private var onLoadMore: (() -> Void)?
        private var onGeometryChange: ((ClipboardTableGeometry) -> Void)?
        private var onScrollActivity: (() -> Void)?
        private var boundsToken: NotificationToken?
        private weak var hostedContainerView: ClipboardTableContainerView?
        private var lastScroll: ScrollIntent?
        private var applyingSelection = false
        private var lastGeometry = ClipboardTableGeometry()
        private var lastBoundsOrigin: NSPoint?
        private var hoverRefreshQueued = false
        private var lastResultsGeneration: UInt64?
        private var lastHasMoreResults = false
        private var hapticRow = -1
        private var suppressScrollHaptics = false

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
            tableView.target = self
            tableView.action = #selector(clicked(_:))
            tableView.onRightClick = { [weak self] row in self?.rightClicked(row) }
            tableView.isItemRow = { [weak self] row in
                guard let self, self.rows.indices.contains(row) else { return false }
                if case .item = self.rows[row] { return true }
                return false
            }

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
            hostedContainerView = containerView
            return containerView
        }

        func update(
            results: [ClipboardItem], resultsGeneration: UInt64, hasMoreResults: Bool,
            selectedID: ClipboardItem.ID?, query: String,
            scroll: ScrollIntent, hoverEnabled: Bool, locale: Locale, store: ClipboardStore,
            onSelect: @escaping (ClipboardItem) -> Void,
            onActivate: @escaping (ClipboardItem) -> Void,
            onActions: @escaping (ClipboardItem) -> Void,
            onLoadMore: @escaping () -> Void,
            onGeometryChange: @escaping (ClipboardTableGeometry) -> Void,
            onScrollActivity: @escaping () -> Void
        ) {
            guard let tableView = tableView else { return }
            if !hoverEnabled {
                tableView.hoverEnabled = false
            }
            self.store = store
            self.onSelect = onSelect
            self.onActivate = onActivate
            self.onActions = onActions
            self.onLoadMore = onLoadMore
            self.onGeometryChange = onGeometryChange
            self.onScrollActivity = onScrollActivity

            let contentChanged = lastResultsGeneration != resultsGeneration
                || lastHasMoreResults != hasMoreResults
            let appearanceChanged = self.query != query || self.locale != locale
            if contentChanged {
                rows = Self.makeRows(results, hasMoreResults: hasMoreResults)
                itemRowIndex = Dictionary(uniqueKeysWithValues: rows.enumerated().compactMap {
                    index, row in
                    guard case .item(let item) = row else { return nil }
                    return (item.id, index)
                })
                lastResultsGeneration = resultsGeneration
                lastHasMoreResults = hasMoreResults
            }
            self.query = query
            self.locale = locale

            let wasApplyingSelection = applyingSelection
            if contentChanged {
                // AppKit temporarily chooses the first selectable row during reload. Suppress
                // that implementation-detail callback until the model selection is restored.
                tableView.clearHover()
                applyingSelection = true
                tableView.reloadData()
            } else if appearanceChanged {
                updateVisibleText(in: tableView)
            }
            applySelection(selectedID, to: tableView)
            applyingSelection = wasApplyingSelection

            if lastScroll != scroll {
                lastScroll = scroll
                apply(scroll, selectedID: selectedID, to: tableView)
            }
            tableView.hoverEnabled = hoverEnabled
            queueHoverRefresh()
            reportGeometry(scrolling: false)
        }

        private var tableView: ClipboardTableView? {
            hostedContainerView?.tableView
        }

        private func updateVisibleText(in tableView: ClipboardTableView) {
            let visibleRows = tableView.rows(in: tableView.visibleRect)
            guard visibleRows.location != NSNotFound else { return }
            for row in visibleRows.location..<NSMaxRange(visibleRows) {
                guard rows.indices.contains(row),
                    let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                else { continue }
                switch rows[row] {
                case .header(let section):
                    (view as? ClipboardSectionCellView)?.configure(
                        title: Self.localized(section.title, locale: locale), isFirst: row == 0)
                case .item(let item):
                    (view as? ClipboardItemCellView)?.updateTitle(
                        item: item, query: query, locale: locale)
                case .more:
                    (view as? ClipboardSectionCellView)?.configure(
                        title: AppLocalization.string("Scroll for more", locale: locale),
                        isFirst: false)
                }
            }
        }

        private static func makeRows(
            _ results: [ClipboardItem], hasMoreResults: Bool
        ) -> [ClipboardTableRow] {
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
            if hasMoreResults { rows.append(.more) }
            return rows
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            guard rows.indices.contains(row), case .item = rows[row] else { return false }
            return true
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let tableView = notification.object as? NSTableView else {
                return
            }
            let row = tableView.selectedRow
            guard rows.indices.contains(row), case .item(let item) = rows[row] else { return }
            selectedID = item.id
            updateVisibleSelection(in: tableView)
            PaletteHaptics.tick()
            onSelect?(item)
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row) else { return 0 }
            switch rows[row] {
            case .item(let item): return ClipboardItemCellView.rowHeight(for: item)
            case .header: return row == 0 ? 24 : 32
            case .more: return 32
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
                return view
            case .more:
                let view =
                    tableView.makeView(withIdentifier: headerIdentifier, owner: self)
                        as? ClipboardSectionCellView ?? ClipboardSectionCellView()
                view.identifier = headerIdentifier
                view.configure(
                    title: AppLocalization.string("Scroll for more", locale: locale),
                    isFirst: false)
                return view
            }
        }

        @objc private func clicked(_ tableView: NSTableView) {
            // Activation belongs to the table's click action, never its selection delegate:
            // hovering and keyboard navigation also change selection.
            let row = tableView.clickedRow
            guard rows.indices.contains(row), case .item(let item) = rows[row],
                NSApp.currentEvent?.modifierFlags.contains(.control) != true,
                (NSApp.currentEvent?.clickCount ?? 1) == 1
            else { return }
            onActivate?(item)
        }

        private func rightClicked(_ row: Int) {
            guard let tableView, rows.indices.contains(row),
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

        private func applySelection(_ id: ClipboardItem.ID?, to tableView: NSTableView) {
            selectedID = id
            let row = id.flatMap { itemRowIndex[$0] }
            let wasApplyingSelection = applyingSelection
            applyingSelection = true
            if let row {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            } else {
                // Empty results can have no selection; clicks remain single-selected.
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
            // Programmatic scrolls must not play the scrolling ratchet.
            suppressScrollHaptics = true
            defer { suppressScrollHaptics = false }
            switch scroll.kind {
            case .top:
                scrollToTop(tableView)
            case .follow:
                if selectedID == resultsFirstItemID {
                    scrollToTop(tableView)
                } else if let selectedID, let row = itemRowIndex[selectedID] {
                    tableView.scrollRowToVisible(row)
                }
            }
        }

        private var resultsFirstItemID: ClipboardItem.ID? {
            for row in rows {
                if case .item(let item) = row { return item.id }
            }
            return nil
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
            if !rows.isEmpty, maxOffset - offset < viewport {
                onLoadMore?()
            }
        }

        private func boundsChanged(_ origin: NSPoint) {
            let scrolling = lastBoundsOrigin.map { $0 != origin } ?? false
            lastBoundsOrigin = origin
            queueHoverRefresh()
            scrollHaptic()
            reportGeometry(scrolling: scrolling)
        }

        /// One tick per row boundary crossing the viewport edge. Quiet while hover selection
        /// is following the pointer over rows (its selection ticks already speak) and while
        /// the scroll came from keyboard navigation or a list reset.
        private func scrollHaptic() {
            guard let tableView else { return }
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.location != NSNotFound else { return }
            defer { hapticRow = visible.location }
            guard !suppressScrollHaptics, hapticRow >= 0, hapticRow != visible.location,
                !tableView.pointerDrivesSelection
            else { return }
            PaletteHaptics.tick()
        }

        private func queueHoverRefresh() {
            guard !hoverRefreshQueued else { return }
            hoverRefreshQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.hoverRefreshQueued = false
                self.tableView?.refreshHover()
            }
        }

        private static func localized(_ title: String, locale: Locale) -> String {
            switch title {
            case "Today": return AppLocalization.string("Today", locale: locale)
            case "Yesterday": return AppLocalization.string("Yesterday", locale: locale)
            case "Past 7 Days": return AppLocalization.string("Past 7 Days", locale: locale)
            case "Past 30 Days": return AppLocalization.string("Past 30 Days", locale: locale)
            default: return AppLocalization.string("Earlier", locale: locale)
            }
        }
    }
}

private final class ClipboardTableContainerView: NSView {
    let scrollView: ClipboardTableScrollView

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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
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
    var isItemRow: ((Int) -> Bool)?
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
    private var lastScreenMouseLocation: NSPoint?
    private var pendingHoverRow: Int?
    private var pendingHoverTask: Task<Void, Never>?

    override var acceptsFirstResponder: Bool { false }

    /// Hover selection is armed over rows: scrolling feedback defers to its selection ticks.
    var pointerDrivesSelection: Bool {
        guard let panel = window as? PalettePanel, panel.allowsHoverSelection,
            let isItemRow
        else { return false }
        let point = convert(panel.mouseLocationOutsideOfEventStream, from: nil)
        guard visibleRect.contains(point) else { return false }
        let row = row(at: point)
        return row >= 0 && isItemRow(row)
    }

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
        lastScreenMouseLocation = NSEvent.mouseLocation
        updateHover(at: convert(event.locationInWindow, from: nil), pointerMoved: false)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let mouseLocation = NSEvent.mouseLocation
        let pointerMoved = lastScreenMouseLocation.map {
            hypot(mouseLocation.x - $0.x, mouseLocation.y - $0.y) >= 0.5
        } ?? true
        lastScreenMouseLocation = mouseLocation
        updateHover(at: convert(event.locationInWindow, from: nil), pointerMoved: pointerMoved)
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

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
        } else {
            super.mouseDown(with: event)
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
        lastScreenMouseLocation = NSEvent.mouseLocation
        updateHover(at: point, pointerMoved: false)
    }

    func clearHover() {
        hoveredRow = nil
        lastPointerLocation = nil
        lastScreenMouseLocation = nil
        cancelPendingHover()
    }

    private func updateHover(at point: NSPoint, pointerMoved: Bool) {
        guard hoverEnabled, window?.isVisible == true,
            (window as? PalettePanel)?.allowsHoverSelection != false,
            pointerHitsTable(at: point)
        else {
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
        guard row >= 0, isItemRow?(row) == true else {
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

        if pointerMoved, hoveredRow != nil,
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
            isItemRow?(row) == true
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
    /// view. Verify the window's real hit-test target so menus cannot leak
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
