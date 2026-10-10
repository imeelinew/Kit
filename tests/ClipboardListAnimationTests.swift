import AppKit
import SwiftUI
@testable import Kit

/// Hosts the production list against a temporary store. Never launches Kit's app lifecycle.
@MainActor @Observable
private final class ListFixture {
    var items: [ClipboardItem] = []
    var generation: UInt64 = 0
    var resultsKindFilter: ClipboardKindFilter = .all
    var selectedID: ClipboardItem.ID?
    var hasMore = false
    var scroll = ScrollIntent(kind: .top)
    var query = ""
    var selectionCallbacks = 0
    let store: ClipboardStore

    init(directory: URL) {
        store = ClipboardStore(directory: directory)
        store.load()
    }

    func update(_ items: [ClipboardItem]) {
        self.items = items
        selectedID = items.first?.id
        generation &+= 1
    }
}

private struct FixtureView: View {
    let fixture: ListFixture

    var body: some View {
        ClipboardList(
            results: fixture.items, resultsGeneration: fixture.generation,
            resultsKindFilter: fixture.resultsKindFilter,
            hasMoreResults: fixture.hasMore, selectedID: fixture.selectedID,
            query: fixture.query, scroll: fixture.scroll, hoverEnabled: false,
            store: fixture.store,
            onSelect: { _ in fixture.selectionCallbacks += 1 },
            onActivate: { _ in }, onActions: { _ in }, onLoadMore: {})
    }
}

@main
struct ClipboardListAnimationTests {
    @MainActor
    static func settle(_ duration: TimeInterval = 0.03) {
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
    }

    @MainActor
    static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { table(in: $0) }.first
    }

    @MainActor
    static func hasKindFade(in view: NSView) -> Bool {
        view.layer?.animation(forKey: "transition") != nil
            || view.subviews.contains { hasKindFade(in: $0) }
    }

    @MainActor
    static func assertRowGeometry(_ table: NSTableView) {
        table.layoutSubtreeIfNeeded()
        table.enumerateAvailableRowViews { view, row in
            let expected = table.rect(ofRow: row)
            precondition(abs(view.frame.minY - expected.minY) < 0.5,
                         "Visible row \(row) must sit at its logical position")
            precondition(abs(view.frame.height - expected.height) < 0.5,
                         "Visible row \(row) must use its logical height")
            if let presentation = view.layer?.presentation() {
                precondition(abs(presentation.frame.minY - expected.minY) < 0.5,
                             "Settled presentation row \(row) must match its logical position")
            }
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) {
                let cellFrame = table.convert(cell.bounds, from: cell)
                precondition(abs(cellFrame.minY - expected.minY) < 0.5,
                             "Cell content \(row) must sit inside its logical row")
                if let layer = cell.layer, let presentation = layer.presentation() {
                    precondition(abs(presentation.frame.minY - layer.frame.minY) < 0.5,
                                 "Cell content \(row) must not keep an insertion slide offset")
                }
            }
        }
    }

    /// Typing publishes highlights before SQLite results arrive; both frames must stay motionless.
    @MainActor
    static func searchTypingTests(in directory: URL) {
        let fixture = ListFixture(directory: directory)
        let today = Calendar.current.startOfDay(for: Date()).addingTimeInterval(60)
        let kinds: [ClipboardItem.Kind] = [.image, .text, .markdown, .code, .link, .path]
        let matching = kinds.map { kind in
            ClipboardItem(
                id: UUID(), kind: kind, text: kind == .image ? nil : "你好世界",
                imagePath: nil, imageFingerprint: nil, createdAt: today,
                sourceBundleID: nil, imageOCR: kind == .image ? ClipboardImageOCR(
                    text: "你好世界", status: .complete, version: 1, attempts: 1) : nil)
        }
        let distractors = (0..<6).map { index in
            ClipboardItem(text: "其他内容 \(index)", kind: .text, sourceBundleID: nil)
        }
        let original = zip(distractors, matching).flatMap { [$0.0, $0.1] }
        fixture.update(original)
        fixture.hasMore = true
        let window = PalettePanel(
            rootView: FixtureView(fixture: fixture).frame(width: 290, height: 520),
            visualStyle: .frosted)
        defer { window.close() }
        let hosting = window.contentView!
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        settle()
        let table = table(in: hosting)!

        // Capture surviving cells so a highlight refresh cannot replace their thumbnails or labels.
        var retained: [UUID: NSView] = [:]
        for row in 0..<table.numberOfRows {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true)
                as? ClipboardItemCellView
            else { continue }
            let itemIndex = row - 1
            if original.indices.contains(itemIndex) {
                retained[original[itemIndex].id] = cell
            }
        }

        // First frame: input/highlight changes and the old pagination footer disappears.
        fixture.query = "n"
        fixture.hasMore = false
        fixture.scroll = ScrollIntent(kind: .top)
        settle()
        assertRowGeometry(table)
        // Second frame: results narrow after the query value has already reached the table.
        fixture.update(matching)
        settle()
        assertRowGeometry(table)
        for (index, item) in matching.enumerated() {
            let cell = table.view(atColumn: 0, row: index + 1, makeIfNecessary: true)!
            precondition(cell === retained[item.id], "Search refinement preserves retained \(item.kind) cells")
        }

        // Subsequent pinyin characters remove more rows; each async result must settle immediately.
        var remaining = matching
        for query in ["ni", "nih", "niha", "nihao", "nh"] {
            fixture.query = query
            fixture.scroll = ScrollIntent(kind: .top)
            settle()
            if remaining.count > 1 { remaining.removeLast() }
            fixture.update(remaining)
            settle()
            assertRowGeometry(table)
            precondition(table.view(atColumn: 0, row: 1, makeIfNecessary: true) === retained[matching[0].id],
                         "OCR image cell remains stable across pinyin characters")
        }

        // Literal queries use the same asynchronous update path for every content kind.
        fixture.query = "你好"
        fixture.scroll = ScrollIntent(kind: .top)
        settle()
        fixture.update(matching)
        settle()
        assertRowGeometry(table)
        fixture.query = "你好世界"
        fixture.scroll = ScrollIntent(kind: .top)
        settle()
        fixture.update([matching[1], matching[3], matching[5]])
        settle()
        assertRowGeometry(table)
        print("PASS: asynchronous pinyin/literal typing, OCR and every text kind, stable retained cells, no row slide")
    }

    @MainActor
    static func thumbnailScrollTests(in directory: URL) async throws {
        let fixture = ListFixture(directory: directory)
        fixture.store.setImageTextSearchEnabled(false)
        let data = autoreleasepool { () -> Data in
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 4000, pixelsHigh: 2500, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)!
            memset(bitmap.bitmapData!, 190, bitmap.bytesPerRow * bitmap.pixelsHigh)
            return bitmap.representation(using: .png, properties: [:])!
        }
        let urls = (0..<50).map { directory.appendingPathComponent("images/scroll-\($0).png") }
        for url in urls { try data.write(to: url) }
        let items = urls.map { ClipboardItem(imagePath: $0.path,
            imageFingerprint: $0.lastPathComponent, sourceBundleID: nil) }
        fixture.update(items)
        let hosting = NSHostingView(rootView: FixtureView(fixture: fixture))
        let frame = NSRect(x: -10000, y: -10000, width: 300, height: 200)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        let table = table(in: hosting)!

        func symbol(in view: NSView) -> NSImageView? {
            if let image = view as? NSImageView { return image }
            return view.subviews.lazy.compactMap { symbol(in: $0) }.first
        }
        func visibleImages() -> [ClipboardItemCellView] {
            let range = table.rows(in: table.visibleRect)
            guard range.location != NSNotFound else { return [] }
            return (range.location..<NSMaxRange(range)).compactMap { row in
                let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ClipboardItemCellView
                return cell?.displayedKind == .image ? cell : nil
            }
        }
        func waitForImages(_ condition: () -> Bool) async {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !condition() {
                precondition(ContinuousClock.now < deadline, "Visible row thumbnails must finish after scrolling stops")
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        await waitForImages {
            !visibleImages().isEmpty && visibleImages().allSatisfy { symbol(in: $0)?.isHidden == true }
        }
        await waitForImages { ImageThumbnail.cached(urls[4], maxPixel: ImageThumbnail.rowMaxPixel) != nil }
        precondition(ImageThumbnail.cached(urls[49], maxPixel: ImageThumbnail.rowMaxPixel) == nil,
                     "Viewport prefetch must not decode the full history")
        if let cell = visibleImages().first {
            let range = table.rows(in: table.visibleRect)
            let itemRow = (range.location..<NSMaxRange(range)).first {
                table.view(atColumn: 0, row: $0, makeIfNecessary: false) === cell
            }!
            // All fixtures share today's first header, so item rows begin at 1.
            let item = items[itemRow - 1]
            ImageThumbnail.purgeRowMemory()
            cell.configure(item: item, selected: false, query: "",
                imageURL: fixture.store.imageURL(for: item), locale: .current)
            precondition(symbol(in: cell)?.isHidden == true,
                         "Reconfiguring the same item preserves its image even after memory eviction")
        }
        let previews = (20..<24).map { index in Task {
            let image = await ImageThumbnail.loadAsync(urls[index], maxPixel: 900)
            return image != nil
        } }
        let clip = table.enclosingScrollView!.contentView
        for offset in [700, 1500, 2600, 500, 0] {
            clip.scroll(to: NSPoint(x: 0, y: offset))
            table.enclosingScrollView!.reflectScrolledClipView(clip)
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(3))
        }
        let stopped = ContinuousClock.now
        await waitForImages {
            !visibleImages().isEmpty && visibleImages().allSatisfy { symbol(in: $0)?.isHidden == true }
        }
        let recovery = stopped.duration(to: .now)
        for preview in previews {
            let succeeded = await preview.value
            precondition(succeeded)
        }
        print("PASS: native table rapid forward/reverse scrolling, bounded neighbor prefetch, retained images, concurrent previews; stopped recovery=\(recovery)")
    }

    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let bundleID = Bundle.main.bundleIdentifier!
        precondition(bundleID.hasPrefix("com.eli.Kit.tests.clipboard-list."),
                     "The list harness requires an isolated bundle identity")
        if CommandLine.arguments.contains("--preview-lifecycle-only") {
            try await ClipboardPreviewLifecycleTests.run()
            return
        }
        if CommandLine.arguments.contains("--hover-only") {
            try await ClipboardHoverSelectionTests.run()
            return
        }
        if CommandLine.arguments.contains("--retention-only") {
            await ClipboardRetentionSettingsTests.run()
            return
        }
        if CommandLine.arguments.contains("--date-groups-only") {
            try await ClipboardDateGroupingTests.run()
            return
        }
        if CommandLine.arguments.contains("--thumbnails-only") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kit-thumbnail-ui-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            try await ImageDecodeCoordinatorTests.run()
            try await ClipboardRowThumbnailTests.run()
            try await thumbnailScrollTests(in: directory)
            return
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kit-list-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = ListFixture(directory: directory)
        let today = Calendar.current.startOfDay(for: Date()).addingTimeInterval(60)
        func item(_ name: String, daysAgo: Int = 0) -> ClipboardItem {
            ClipboardItem(
                id: UUID(), kind: .text, text: name, imagePath: nil, imageFingerprint: nil,
                createdAt: Calendar.current.date(byAdding: .day, value: -daysAgo, to: today)!,
                sourceBundleID: nil)
        }
        let a = item("A"), b = item("B"), c = item("C", daysAgo: 1)
        let d = item("D", daysAgo: 2)
        fixture.update([a, b, c, d])
        let window = PalettePanel(
            rootView: FixtureView(fixture: fixture).frame(width: 290, height: 520),
            visualStyle: .frosted)
        let hosting = window.contentView!
        hosting.layoutSubtreeIfNeeded()
        settle()
        let table = table(in: hosting)!
        precondition(table.numberOfRows == 7, "Four entries and three date headers")

        // A late TypeSafe verdict must update the existing row in place. The test
        // window stays hidden, so Reduce Motion and offscreen updates are immediate.
        let refinedCell = table.view(atColumn: 0, row: 1, makeIfNecessary: true)
            as! ClipboardItemCellView
        precondition(refinedCell.displayedKind == .text)
        fixture.update([a.withKind(.code), b, c, d])
        settle()
        precondition(table.view(atColumn: 0, row: 1, makeIfNecessary: true) === refinedCell)
        precondition(refinedCell.displayedKind == .code)
        precondition(table.numberOfRows == 7 && table.selectedRow == 1)
        fixture.update([a.withKind(.markdown), b, c, d])
        settle()
        precondition(refinedCell.displayedKind == .markdown,
                     "Consecutive verdicts update the same cell without a full reload")

        // AI starts at plain text. A pagination refresh can accompany its verdict;
        // preserve the visible cell and the actual Core Animation transition.
        fixture.hasMore = true
        fixture.update([a, b, c, d])
        settle()
        window.orderFront(nil)
        settle()
        let aiCell = table.view(atColumn: 0, row: 1, makeIfNecessary: true)
            as! ClipboardItemCellView
        fixture.hasMore = false
        fixture.query = "A" // A simultaneous highlight change disables row animation.
        fixture.update([a.withKind(.link), b, c, d])
        settle()
        precondition(table.view(atColumn: 0, row: 1, makeIfNecessary: true) === aiCell,
                     "Pagination changes must preserve the AI-classified cell")
        precondition(aiCell.displayedKind == .link)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            precondition(hasKindFade(in: aiCell), "Visible AI verdict must animate")
        }
        settle(0.3)
        fixture.scroll = ScrollIntent(kind: .top)
        fixture.update([a.withKind(.path), b, c, d])
        settle()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            precondition(hasKindFade(in: aiCell), "Scroll intents must not suppress the type fade")
        }
        window.orderOut(nil)

        fixture.update([b, c, d])
        settle()
        precondition(table.numberOfRows == 6 && table.selectedRow == 1)
        let survivingCell = table.view(atColumn: 0, row: 1, makeIfNecessary: true)
        fixture.update([b, c, d]) // The store republishes while the removal is animating.
        settle()
        precondition(table.view(atColumn: 0, row: 1, makeIfNecessary: true) === survivingCell,
                     "Identical asynchronous results must preserve the surviving cell")

        fixture.update([c, d]) // Delete again before the first animation completes.
        settle()
        precondition(table.numberOfRows == 4 && table.selectedRow == 1)
        precondition(table.rect(ofRow: 0).height == 24, "Promoted date header uses first-row height")
        fixture.update([d])
        settle()
        precondition(table.numberOfRows == 2 && table.selectedRow == 1)

        fixture.hasMore = true
        fixture.update([d, item("E", daysAgo: 2)])
        settle()
        precondition(table.numberOfRows == 4, "Refill inserts an entry and pagination footer")
        fixture.hasMore = false
        fixture.update([d])
        settle()
        precondition(table.numberOfRows == 2, "Pagination footer can disappear during deletion")

        fixture.query = "no match"
        fixture.scroll = ScrollIntent(kind: .top)
        fixture.update([])
        settle()
        precondition(table.numberOfRows == 0 && table.selectedRow == -1)
        fixture.query = ""
        fixture.update([a, b])
        settle()
        fixture.update([])
        settle(0.25)
        precondition(table.numberOfRows == 0 && table.selectedRow == -1,
                     "Deleting the last entries clears selection")
        precondition(fixture.selectionCallbacks == 0, "Updates never publish transient AppKit selections")

        // A single restore still animates, and its follow scroll waits for row frames.
        let many = (0..<30).map { item("scroll row \($0)") }
        fixture.update(many)
        window.orderFront(nil)
        settle(0.3)
        fixture.selectedID = many.last!.id
        fixture.scroll = ScrollIntent(kind: .follow)
        settle(0.1)
        precondition(!table.visibleRect.intersects(table.rect(ofRow: 0)))
        fixture.update([item("restored")] + many)
        fixture.scroll = ScrollIntent(kind: .follow)
        settle()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            precondition(!table.visibleRect.intersects(table.rect(ofRow: 0)),
                         "The single restore retains its insertion animation and deferred scroll")
        }
        settle(0.4)
        precondition(table.visibleRect.intersects(table.rect(ofRow: 0)))
        assertRowGeometry(table)

        // Type switches fade the viewport even when row diffs are too large to animate.
        let container = table.enclosingScrollView!.superview!
        container.layer?.speed = 0
        let replacement = (0..<40).map { item("filtered \($0)") }
        fixture.resultsKindFilter = .text
        fixture.update(replacement)
        fixture.scroll = ScrollIntent(kind: .top)
        settle()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            precondition(container.layer?.animation(forKey: "transition") != nil,
                         "Large type-filter replacements have a viewport transition")
        }
        container.layer?.speed = 1
        settle(0.3)
        assertRowGeometry(table)
        container.layer?.speed = 0
        fixture.resultsKindFilter = .all
        fixture.update([])
        settle()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            precondition(container.layer?.animation(forKey: "transition") != nil,
                         "Switching to empty results also transitions")
        }
        container.layer?.speed = 1
        precondition(table.numberOfRows == 0)
        settle(0.3)
        window.close()
        print("PASS: kind refinement, deletion, single animated restore, date headers, async refresh, pagination, empty results")
        searchTypingTests(in: directory.appendingPathComponent("typing"))
        try await ClipboardDateGroupingTests.run()
        try await ClipboardSearchGeometryTests.run()
        try await ClipboardHoverSelectionTests.run()
        try await ClipboardUndoTests.run()
        await ClipboardRetentionSettingsTests.run()
        ClipboardTextClassifierTests.run()
        await ClipboardPreviewTests.run()
        try await ImageSearchHighlightTests.run()
        try await ClipboardPreviewLifecycleTests.run()
        try await ImageDecodeCoordinatorTests.run()
        try await ClipboardRowThumbnailTests.run()
        try await thumbnailScrollTests(in: directory.appendingPathComponent("image-scroll"))
    }
}
