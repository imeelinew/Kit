import AppKit
import SwiftUI
@testable import Kit

/// Hosts the production list against a temporary store. Never launches Kit's app lifecycle.
@MainActor @Observable
private final class ListFixture {
    var items: [ClipboardItem] = []
    var generation: UInt64 = 0
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
    static func main() throws {
        _ = NSApplication.shared
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
        let hosting = NSHostingView(rootView: FixtureView(fixture: fixture))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 290, height: 520),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        settle()
        let table = table(in: hosting)!
        precondition(table.numberOfRows == 7, "Four entries and three date headers")

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
        window.close()
        print("PASS: animated deletion, rapid deletion, date headers, async refresh, pagination, empty results")
    }
}
