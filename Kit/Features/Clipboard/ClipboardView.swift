import AppKit
import QuartzCore
import SwiftUI

struct ClipboardList: View {
    let results: [ClipboardItem]
    let resultsGeneration: UInt64
    var resultsKindFilter: ClipboardKindFilter = .all
    var resultsStackFilter: ClipboardStack.ID? = nil
    var dateGrouping: ClipboardDateGrouping? = nil
    let hasMoreResults: Bool
    let selectedID: ClipboardItem.ID?
    let query: String
    /// Changes only when the list should scroll (keyboard nav / reset), so mouse selection never yanks the scroll position.
    let scroll: ScrollIntent
    let interactionEnabled: Bool
    let store: ClipboardStore
    let onSelect: (ClipboardItem) -> Void
    let onActivate: (ClipboardItem) -> Void
    let onActions: (ClipboardItem) -> Void
    let onLoadMore: () -> Void

    var body: some View {
        ClipboardTableRepresentable(
            results: results,
            resultsGeneration: resultsGeneration,
            resultsKindFilter: resultsKindFilter,
            resultsStackFilter: resultsStackFilter,
            dateGrouping: dateGrouping,
            hasMoreResults: hasMoreResults,
            selectedID: selectedID,
            query: query,
            scroll: scroll,
            interactionEnabled: interactionEnabled,
            store: store,
            onSelect: onSelect,
            onActivate: onActivate,
            onActions: onActions,
            onLoadMore: onLoadMore
        )
    }
}

private struct ClipboardTableGeometry: Equatable {
    var offset: CGFloat = 0
    var content: CGFloat = 0
    var viewport: CGFloat = 0
}

private enum ClipboardTableRow: Equatable {
    case header(ClipboardDateSection)
    case item(ClipboardItem)
    case more

    enum ID: Hashable {
        case header(ClipboardDateSection)
        case item(ClipboardItem.ID)
        case more
    }

    var id: ID {
        switch self {
        case .header(let section): .header(section)
        case .item(let item): .item(item.id)
        case .more: .more
        }
    }
}

private struct ClipboardTableRepresentable: NSViewRepresentable {
    let results: [ClipboardItem]
    let resultsGeneration: UInt64
    var resultsKindFilter: ClipboardKindFilter = .all
    var resultsStackFilter: ClipboardStack.ID? = nil
    var dateGrouping: ClipboardDateGrouping?
    let hasMoreResults: Bool
    let selectedID: ClipboardItem.ID?
    let query: String
    let scroll: ScrollIntent
    let interactionEnabled: Bool
    let store: ClipboardStore
    let onSelect: (ClipboardItem) -> Void
    let onActivate: (ClipboardItem) -> Void
    let onActions: (ClipboardItem) -> Void
    let onLoadMore: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ClipboardTableContainerView {
        let container = context.coordinator.makeContainerView()
        return container
    }

    static func dismantleNSView(_ nsView: ClipboardTableContainerView, coordinator: Coordinator) {
        coordinator.stopThumbnailPrefetch()
    }

    func updateNSView(_ containerView: ClipboardTableContainerView, context: Context) {
        context.coordinator.update(
            results: results,
            resultsGeneration: resultsGeneration,
            resultsKindFilter: resultsKindFilter,
            resultsStackFilter: resultsStackFilter,
            dateGrouping: dateGrouping,
            hasMoreResults: hasMoreResults,
            selectedID: selectedID,
            query: query,
            scroll: scroll,
            interactionEnabled: interactionEnabled,
            locale: context.environment.locale,
            store: store,
            onSelect: onSelect,
            onActivate: onActivate,
            onActions: onActions,
            onLoadMore: onLoadMore
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
        private var lastResultsKindFilter: ClipboardKindFilter?
        private var lastResultsStackFilter: ClipboardStack.ID?
        private var onActivate: ((ClipboardItem) -> Void)?
        private var onActions: ((ClipboardItem) -> Void)?
        private var onLoadMore: (() -> Void)?
        private var boundsToken: NotificationToken?
        private var fileDidChangeToken: NotificationToken?
        private var fileStatusRefreshTask: Task<Void, Never>?
        private weak var hostedContainerView: ClipboardTableContainerView?
        private var lastScroll: ScrollIntent?
        private var pendingScrollApply: DispatchWorkItem?
        private var applyingSelection = false
        private var lastGeometry = ClipboardTableGeometry()
        private var lastBoundsOrigin: NSPoint?
        private let thumbnailPrefetcher = ImageThumbnail.RowPrefetcher()
        private var thumbnailPrefetchQueued = false
        private var thumbnailPrefetchStopped = false
        private var scrollingDown = true
        private var hoverRefreshQueued = false
        private var hoverRefreshGeneration: UInt64 = 0
        private var regroupingDates = false
        private var lastResultsGeneration: UInt64?
        private var queryChangedSinceResults = false
        private var lastHasMoreResults = false
        private var hapticRow = -1
        private var suppressScrollHaptics = false
        private var dateGrouping = ClipboardDateGrouping.current
        private var dateGroupingIsOverridden = false
        private lazy var dateRefresh = ClipboardDateRefresh { [weak self] grouping in
            self?.refreshDateGrouping(grouping)
        }

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
            tableView.onClick = { [weak self] id, wasSelected in
                self?.clicked(id, wasSelected: wasSelected)
            }
            tableView.onRightClick = { [weak self] row in self?.rightClicked(row) }
            tableView.itemIDAtRow = { [weak self] row in
                guard let self, self.rows.indices.contains(row),
                    case .item(let item) = self.rows[row] else { return nil }
                return item.id
            }

            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Clipboard"))
            column.resizingMask = .autoresizingMask
            tableView.addTableColumn(column)

            let scrollView = ClipboardTableScrollView()
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            // Hiding the scroller does not disable horizontal rubber-banding.
            scrollView.horizontalScrollElasticity = .none
            scrollView.verticalScrollElasticity = .allowed
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsets(
                top: Theme.Spacing.xs,
                left: 0,
                bottom: Theme.Spacing.md,
                right: 0
            )
            scrollView.contentView.drawsBackground = false
            scrollView.installDocumentView(tableView)
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
            installFileChangeObserver()

            let containerView = ClipboardTableContainerView(scrollView: scrollView)
            hostedContainerView = containerView
            dateRefresh.start()
            return containerView
        }

        func update(
            results: [ClipboardItem], resultsGeneration: UInt64,
            resultsKindFilter: ClipboardKindFilter, resultsStackFilter: ClipboardStack.ID?,
            dateGrouping: ClipboardDateGrouping?,
            hasMoreResults: Bool,
            selectedID: ClipboardItem.ID?, query: String,
            scroll: ScrollIntent, interactionEnabled: Bool, locale: Locale, store: ClipboardStore,
            onSelect: @escaping (ClipboardItem) -> Void,
            onActivate: @escaping (ClipboardItem) -> Void,
            onActions: @escaping (ClipboardItem) -> Void,
            onLoadMore: @escaping () -> Void
        ) {
            guard let tableView = tableView else { return }
            if !interactionEnabled {
                tableView.interactionEnabled = false
            }
            self.store = store
            self.onSelect = onSelect
            self.onActivate = onActivate
            self.onActions = onActions
            self.onLoadMore = onLoadMore

            let resultsChanged = lastResultsGeneration != resultsGeneration
            let grouping = dateGrouping ?? .current
            let dateChanged = self.dateGrouping != grouping
            regroupingDates = dateChanged
            defer { regroupingDates = false }
            if dateChanged { cancelQueuedHoverRefresh() }
            dateGroupingIsOverridden = dateGrouping != nil
            let viewport = dateChanged && lastScroll == scroll ? captureViewport(in: tableView) : nil
            self.dateGrouping = grouping
            let contentChanged = resultsChanged
                || lastHasMoreResults != hasMoreResults || dateChanged
            let appearanceChanged = self.query != query || self.locale != locale || dateChanged
            if self.query != query { queryChangedSinceResults = true }
            let filterChanged = lastResultsKindFilter != nil
                && (lastResultsKindFilter != resultsKindFilter
                    || lastResultsStackFilter != resultsStackFilter)
            lastResultsKindFilter = resultsKindFilter
            lastResultsStackFilter = resultsStackFilter
            let previousRows = rows
            if contentChanged {
                rebuildRows(results, hasMoreResults: hasMoreResults)
                lastResultsGeneration = resultsGeneration
                lastHasMoreResults = hasMoreResults
            }
            self.query = query
            self.locale = locale
            self.selectedID = selectedID

            let wasApplyingSelection = applyingSelection
            var animatedRows = false
            if contentChanged {
                // Suppress AppKit's intermediate selections until the model is restored.
                tableView.clearHover()
                applyingSelection = true
                if filterChanged {
                    // Fade the entire viewport, including large replacements and empty results.
                    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                        let container = hostedContainerView
                    {
                        let transition = CATransition()
                        transition.type = .fade
                        transition.duration = Theme.Motion.contentDuration
                        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        container.layer?.add(transition, forKey: "transition")
                    }
                    tableView.reloadData()
                } else if dateChanged {
                    // Day-to-month regrouping moves headers across rows of a different height.
                    // Commit that layout together before restoring the viewport anchor.
                    if previousRows != rows { tableView.reloadData() }
                } else {
                    animatedRows = updateRows(
                        from: previousRows, in: tableView,
                        animate: !appearanceChanged && !queryChangedSinceResults
                            && (lastScroll == scroll || scroll.kind == .follow)
                            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                }
                if appearanceChanged { updateVisibleText(in: tableView) }
            } else if appearanceChanged {
                updateVisibleText(in: tableView)
            }
            // Input/highlights arrive before asynchronous search results. Pagination-only
            // updates must not consume this flag and let the later results slide the rows.
            if resultsChanged { queryChangedSinceResults = false }
            applySelection(selectedID, to: tableView)
            applyingSelection = wasApplyingSelection
            if let viewport { restoreViewport(viewport, in: tableView) }

            if lastScroll != scroll {
                lastScroll = scroll
                // Scrolling while row frames still animate leaves the animating rows offset
                // from their logical positions, so a scroll paired with an animated edit
                // waits for the animation; rapid undos replace the pending scroll.
                pendingScrollApply?.cancel()
                if animatedRows {
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, let tableView = self.tableView else { return }
                        self.apply(scroll, selectedID: self.selectedID, to: tableView)
                    }
                    pendingScrollApply = work
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + Theme.Motion.contentDuration + 0.05, execute: work)
                } else {
                    apply(scroll, selectedID: selectedID, to: tableView)
                }
            }
            tableView.interactionEnabled = interactionEnabled
            if !dateChanged { queueHoverRefresh() }
            reportGeometry(scrolling: false)
        }

        private var tableView: ClipboardTableView? {
            hostedContainerView?.tableView
        }

        private func rebuildRows(_ results: [ClipboardItem], hasMoreResults: Bool) {
            rows = Self.makeRows(results, hasMoreResults: hasMoreResults, grouping: dateGrouping)
            itemRowIndex = Dictionary(uniqueKeysWithValues: rows.enumerated().compactMap { index, row in
                guard case .item(let item) = row else { return nil }
                return (item.id, index)
            })
        }

        private struct ViewportAnchor {
            let itemID: ClipboardItem.ID
            let offset: CGFloat
        }

        private func captureViewport(in tableView: NSTableView) -> ViewportAnchor? {
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.location != NSNotFound else { return nil }
            for row in visible.location..<NSMaxRange(visible) {
                guard rows.indices.contains(row), case .item(let item) = rows[row] else { continue }
                return ViewportAnchor(itemID: item.id,
                    offset: tableView.rect(ofRow: row).minY - tableView.visibleRect.minY)
            }
            return nil
        }

        private func restoreViewport(_ anchor: ViewportAnchor, in tableView: NSTableView) {
            guard let row = itemRowIndex[anchor.itemID], let scrollView = tableView.enclosingScrollView else { return }
            let wasSuppressing = suppressScrollHaptics
            suppressScrollHaptics = true
            defer { suppressScrollHaptics = wasSuppressing }
            let clip = scrollView.contentView
            // AppKit may expose intermediate row rects while it retiles after edits. Derive
            // the final offset from the same heights supplied to its delegate instead.
            let itemTop = (0..<row).reduce(CGFloat.zero) { $0 + rowHeight(at: $1) }
            let contentHeight = (0..<rows.count).reduce(CGFloat.zero) { $0 + rowHeight(at: $1) }
            let top = -scrollView.contentInsets.top
            let bottom = max(top, contentHeight + scrollView.contentInsets.bottom - clip.bounds.height)
            let offset = min(bottom, max(top, itemTop - anchor.offset))
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: offset))
            scrollView.reflectScrolledClipView(clip)
        }

        private func refreshDateGrouping(_ grouping: ClipboardDateGrouping) {
            guard !dateGroupingIsOverridden, grouping != dateGrouping, let tableView else { return }
            let viewport = captureViewport(in: tableView)
            let results = rows.compactMap { row -> ClipboardItem? in
                guard case .item(let item) = row else { return nil }
                return item
            }
            let previousRows = rows
            let wasApplying = applyingSelection
            applyingSelection = true
            regroupingDates = true
            defer { applyingSelection = wasApplying; regroupingDates = false }
            cancelQueuedHoverRefresh()
            tableView.clearHover()
            dateGrouping = grouping
            rebuildRows(results, hasMoreResults: lastHasMoreResults)
            if previousRows != rows { tableView.reloadData() }
            updateVisibleText(in: tableView)
            applySelection(selectedID, to: tableView)
            if let viewport { restoreViewport(viewport, in: tableView) }
            reportGeometry(scrolling: false)
        }

        /// Returns whether the update ran as an animated row edit (callers must not scroll
        /// the table until that animation has settled).
        @discardableResult
        private func updateRows(
            from previousRows: [ClipboardTableRow], in tableView: ClipboardTableView,
            animate: Bool
        ) -> Bool {
            // The asynchronous store refresh often republishes exactly the same rows after
            // a deletion. Reloading here would interrupt the animation already in flight.
            guard previousRows != rows else { return false }
            let difference = rows.map(\.id).difference(from: previousRows.map(\.id))
            let oldRowsByID = Dictionary(uniqueKeysWithValues: previousRows.map { ($0.id, $0) })
            let retainedContentUnchanged = rows.allSatisfy { row in
                guard let oldRow = oldRowsByID[row.id] else { return true }
                return oldRow == row
            }
            // Preserve retained cells for small edits even when row animation is disabled.
            // Large replacements and page loads still reload immediately.
            guard !previousRows.isEmpty, !rows.isEmpty,
                !difference.isEmpty, difference.count <= 32, retainedContentUnchanged
            else {
                tableView.reloadData()
                return false
            }
            var removals = IndexSet()
            var insertions = IndexSet()
            for change in difference {
                switch change {
                case .remove(let index, _, _): removals.insert(index)
                case .insert(let index, _, _): insertions.insert(index)
                }
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animate ? Theme.Motion.contentDuration : 0
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                tableView.beginUpdates()
                tableView.removeRows(
                    at: removals, withAnimation: animate ? [.effectFade, .slideUp] : [])
                tableView.insertRows(
                    at: insertions, withAnimation: animate ? [.effectFade, .slideDown] : [])
                tableView.endUpdates()
                // Removing an entire date group promotes the next header to the shorter
                // first-header layout; update both its height and its text inset.
                if previousRows.first?.id != rows.first?.id {
                    tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: 0))
                }
                updateVisibleText(in: tableView)
            }
            return animate
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
                        title: dateGrouping.title(for: section, locale: locale), isFirst: row == 0,
                        centered: true)
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

        private func installFileChangeObserver() {
            guard fileDidChangeToken == nil else { return }
            let token = NotificationCenter.default.addObserver(
                forName: ImageThumbnail.fileDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVisibleThumbnails() }
            }
            fileDidChangeToken = NotificationToken(token, center: .default)
            fileStatusRefreshTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    self?.refreshVisibleThumbnails()
                }
            }
        }

        isolated deinit { fileStatusRefreshTask?.cancel() }

        private func refreshVisibleThumbnails() {
            guard let tableView, tableView.window?.isVisible == true else { return }
            let visibleRows = tableView.rows(in: tableView.visibleRect)
            guard visibleRows.location != NSNotFound else { return }
            for row in visibleRows.location..<NSMaxRange(visibleRows) {
                guard rows.indices.contains(row), case .item(let item) = rows[row],
                    let view = tableView.view(
                        atColumn: 0, row: row, makeIfNecessary: false) as? ClipboardItemCellView
                else { continue }
                view.refreshThumbnail(item: item, imageURL: store?.imageURL(for: item), store: store)
            }
        }

        private static func makeRows(
            _ results: [ClipboardItem], hasMoreResults: Bool, grouping: ClipboardDateGrouping
        ) -> [ClipboardTableRow] {
            var grouped: [ClipboardDateSection: [ClipboardItem]] = [:]
            for item in results {
                let section = grouping.section(for: item.lastCopiedAt)
                grouped[section, default: []].append(item)
            }

            var rows: [ClipboardTableRow] = []
            for section in grouped.keys.sorted(by: { $0.start > $1.start }) {
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
            if (tableView as? ClipboardTableView)?.hoveredRow != row { PaletteHaptics.tick() }
            onSelect?(item)
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            rowHeight(at: row)
        }

        private func rowHeight(at row: Int) -> CGFloat {
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
                    title: dateGrouping.title(for: section, locale: locale), isFirst: row == 0,
                    centered: true)
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
                    locale: locale, store: store
                )
                view.setHovered((tableView as? ClipboardTableView)?.hoveredRow == row, animated: false)
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

        private func clicked(_ id: ClipboardItem.ID, wasSelected: Bool) {
            guard let tableView, let row = itemRowIndex[id],
                case .item(let item) = rows[row] else { return }
            // Decide from the selection at mouse-down, before this click can change it
            if wasSelected, selectedID == id {
                onActivate?(item)
            } else {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
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
            queueThumbnailPrefetch()
            let viewport = scrollView.contentView.bounds.height
            let content =
                tableView.bounds.height + scrollView.contentInsets.top
                + scrollView.contentInsets.bottom
            let maxOffset = max(0, content - viewport)
            let offset = min(
                maxOffset,
                max(0, scrollView.contentView.bounds.minY + scrollView.contentInsets.top)
            )
            let geometry = ClipboardTableGeometry(offset: offset, content: content, viewport: viewport)
            guard geometry != lastGeometry || scrolling else { return }
            lastGeometry = geometry
            if !rows.isEmpty, maxOffset - offset < viewport {
                onLoadMore?()
            }
        }

        private func boundsChanged(_ origin: NSPoint) {
            let scrolling = lastBoundsOrigin.map { $0 != origin } ?? false
            if let previous = lastBoundsOrigin, previous.y != origin.y {
                scrollingDown = origin.y > previous.y
            }
            lastBoundsOrigin = origin
            queueHoverRefresh()
            scrollHaptic()
            reportGeometry(scrolling: scrolling)
        }

        func stopThumbnailPrefetch() {
            thumbnailPrefetchStopped = true
            thumbnailPrefetcher.cancel()
        }

        private func queueThumbnailPrefetch() {
            guard !thumbnailPrefetchStopped, !thumbnailPrefetchQueued else { return }
            thumbnailPrefetchQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.thumbnailPrefetchQueued = false
                guard !self.thumbnailPrefetchStopped, let tableView = self.tableView,
                    tableView.window?.isVisible == true, tableView.visibleRect.height > 0
                else { self.thumbnailPrefetcher.cancel(); return }
                let visible = tableView.rows(in: tableView.visibleRect)
                guard visible.location != NSNotFound else { self.thumbnailPrefetcher.cancel(); return }
                let last = min(self.rows.count, NSMaxRange(visible))
                let first = min(last, visible.location)
                guard last > first else { self.thumbnailPrefetcher.cancel(); return }
                // One viewport in the scrolling direction, with a small reverse buffer.
                // Cap the number of images even for unusually tall windows.
                let count = min(12, last - first)
                let start = max(0, first - (self.scrollingDown ? 2 : count))
                let end = min(self.rows.count, last + (self.scrollingDown ? count : 2))
                let ahead = self.scrollingDown
                    ? Array(last..<end) : Array((start..<first).reversed())
                let behind = self.scrollingDown
                    ? Array((start..<first).reversed()) : Array(last..<end)
                let indexes = ahead + behind
                let urls = indexes.compactMap { index -> URL? in
                    guard !NSLocationInRange(index, visible), case .item(let item) = self.rows[index],
                        item.kind == .image else { return nil }
                    return self.store?.imageURL(for: item)
                }
                self.thumbnailPrefetcher.update(Array(urls.prefix(12)))
            }
        }

        /// One tick per row boundary crossing the viewport edge, except during programmatic scrolls
        private func scrollHaptic() {
            guard let tableView else { return }
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.location != NSNotFound else { return }
            defer { hapticRow = visible.location }
            guard !suppressScrollHaptics, !applyingSelection, hapticRow >= 0, hapticRow != visible.location
            else { return }
            PaletteHaptics.tick()
        }

        private func queueHoverRefresh() {
            guard !regroupingDates, !hoverRefreshQueued else { return }
            hoverRefreshQueued = true
            let generation = hoverRefreshGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.hoverRefreshGeneration else { return }
                self.hoverRefreshQueued = false
                self.tableView?.refreshHover(animated: false)
            }
        }

        private func cancelQueuedHoverRefresh() {
            hoverRefreshGeneration &+= 1
            hoverRefreshQueued = false
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
        wantsLayer = true

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

private final class ClipboardTableScrollView: KitScrollView {
    var onGeometryChange: ((Bool) -> Void)?

    override func layout() {
        super.layout()
        onGeometryChange?(false)
    }
}

private final class ClipboardTableView: NSTableView, PaletteHoverHandling {
    var onClick: ((ClipboardItem.ID, Bool) -> Void)?
    var onRightClick: ((Int) -> Void)?
    var itemIDAtRow: ((Int) -> ClipboardItem.ID?)?
    var interactionEnabled = true {
        didSet {
            guard interactionEnabled != oldValue else { return }
            if interactionEnabled {
                refreshHover(animated: false)
            } else {
                clearHover()
            }
        }
    }

    private(set) var hoveredRow: Int?
    private var hoverTrackingArea: NSTrackingArea?
    private var lastScreenMouseLocation: NSPoint?

    override var acceptsFirstResponder: Bool { false }

    private var screenMouseLocation: NSPoint {
        (window as? PalettePanel)?.hoverMouseLocation ?? NSEvent.mouseLocation
    }

    private func pointerLocation(in window: NSWindow) -> NSPoint {
        convert(window.convertPoint(fromScreen: screenMouseLocation), from: nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            // The panel delivers movement independently of table layout updates
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updatePointerHover(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updatePointerHover(with: event)
    }

    private func updatePointerHover(with event: NSEvent) {
        let location = screenMouseLocation
        let moved = lastScreenMouseLocation.map {
            hypot(location.x - $0.x, location.y - $0.y) >= 0.5
        } ?? true
        lastScreenMouseLocation = location
        updateHover(at: convert(event.locationInWindow, from: nil), animated: moved, haptic: moved)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearHover()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        (window as? PalettePanel)?.registerHoverHandler(self)
        if window == nil { clearHover() }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard interactionEnabled, let window, let id = itemIDAtRow?(row) else { return }
        let wasSelected = itemIDAtRow?(selectedRow) == id
        // Track a complete click without AppKit selecting before activation is decided
        // Stable identity prevents a row replacement during the press from activating another item
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp {
                let point = convert(next.locationInWindow, from: nil)
                if interactionEnabled, visibleRect.contains(point), pointerHitsTable(at: point),
                    itemIDAtRow?(self.row(at: point)) == id
                {
                    onClick?(id, wasSelected)
                }
                return
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard interactionEnabled else { return }
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard itemIDAtRow?(row) != nil else { return }
        onRightClick?(row)
    }

    func refreshHover(animated: Bool = false) {
        guard interactionEnabled, let window else {
            clearHover(animated: animated)
            return
        }
        lastScreenMouseLocation = screenMouseLocation
        updateHover(at: pointerLocation(in: window), animated: animated, haptic: false)
    }

    func clearHover() {
        clearHover(animated: true)
    }

    private func clearHover(animated: Bool) {
        setHoveredRow(nil, animated: animated, haptic: false)
        lastScreenMouseLocation = nil
    }

    private func updateHover(at point: NSPoint, animated: Bool, haptic: Bool) {
        guard interactionEnabled, window?.isVisible == true,
            (window as? PalettePanel)?.allowsHoverSelection != false,
            visibleRect.contains(point), pointerHitsTable(at: point)
        else {
            clearHover(animated: animated)
            return
        }
        let row = row(at: point)
        setHoveredRow(itemIDAtRow?(row) == nil ? nil : row, animated: animated, haptic: haptic)
    }

    private func setHoveredRow(_ row: Int?, animated: Bool, haptic: Bool) {
        guard hoveredRow != row else { return }
        let previous = hoveredRow
        hoveredRow = row
        if let previous {
            (view(atColumn: 0, row: previous, makeIfNecessary: false) as? ClipboardItemCellView)?
                .setHovered(false, animated: animated)
        }
        if let row {
            (view(atColumn: 0, row: row, makeIfNecessary: false) as? ClipboardItemCellView)?
                .setHovered(true, animated: animated)
            if haptic { PaletteHaptics.tick() }
        }
    }

    /// Overlays must block hover feedback for the rows underneath them
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
