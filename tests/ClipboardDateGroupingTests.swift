import AppKit
import SwiftUI
@testable import Kit

@MainActor @Observable
private final class DateGroupingFixture {
    var grouping: ClipboardDateGrouping
    var locale = Locale(identifier: "zh-Hans")
    var items: [ClipboardItem] = []
    var generation: UInt64 = 0
    var selectedID: ClipboardItem.ID?
    var hasMore = false
    var query = ""
    var hoverEnabled = false
    var scroll = ScrollIntent(kind: .top)
    var selectionCallbacks = 0
    let store: ClipboardStore

    init(grouping: ClipboardDateGrouping, directory: URL) {
        self.grouping = grouping
        store = ClipboardStore(directory: directory)
    }

    func replace(_ items: [ClipboardItem]) {
        self.items = items
        generation &+= 1
    }
}

private struct DateGroupingFixtureView: View {
    let fixture: DateGroupingFixture

    var body: some View {
        ClipboardList(
            results: fixture.items, resultsGeneration: fixture.generation,
            dateGrouping: fixture.grouping, hasMoreResults: fixture.hasMore,
            selectedID: fixture.selectedID, query: fixture.query, scroll: fixture.scroll,
            hoverEnabled: fixture.hoverEnabled, store: fixture.store,
            onSelect: { fixture.selectedID = $0.id; fixture.selectionCallbacks += 1 },
            onActivate: { _ in }, onActions: { _ in }, onLoadMore: {})
            .environment(\.locale, fixture.locale)
    }
}

@MainActor
enum ClipboardDateGroupingTests {
    private static func calendar(_ zone: String = "Asia/Taipei") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12,
                             calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private static func day(_ age: Int, in grouping: ClipboardDateGrouping) -> Date {
        grouping.calendar.date(byAdding: .day, value: -age, to: grouping.today)!
    }

    private static func rules() {
        let calendar = calendar()
        let grouping = ClipboardDateGrouping(now: date(2026, 10, 4, calendar: calendar), calendar: calendar)
        let chinese = Locale(identifier: "zh-Hans")
        let english = Locale(identifier: "en")
        for (age, title) in [(0, "今天"), (1, "昨天"), (2, "前天"), (3, "10月1日"), (29, "9月5日")] {
            let section = grouping.section(for: day(age, in: grouping))
            precondition(section == .day(day(age, in: grouping)))
            precondition(grouping.title(for: section, locale: chinese) == title,
                         "Chinese day header: \(age), \(grouping.title(for: section, locale: chinese))")
        }
        let month = grouping.section(for: day(30, in: grouping))
        precondition(month == .month(date(2026, 9, 1, hour: 0, calendar: calendar)))
        precondition(grouping.title(for: month, locale: chinese) == "2026年9月")
        precondition(grouping.section(for: date(2026, 9, 2, calendar: calendar)) == month,
                     "All older entries in the same month share a single header identity")
        precondition(grouping.title(for: month, locale: english) == "September 2026")
        precondition(grouping.title(for: .day(grouping.today), locale: english) == "Today")
        precondition(grouping.title(for: .day(day(2, in: grouping)), locale: english) == "Day Before Yesterday")
        precondition(grouping.section(for: date(2026, 10, 5, calendar: calendar)) == .day(grouping.today),
                     "A future timestamp is grouped with today")

        let january = ClipboardDateGrouping(now: date(2026, 1, 5, calendar: calendar), calendar: calendar)
        precondition(january.title(for: january.section(for: date(2025, 12, 31, calendar: calendar)),
                                   locale: chinese) == "2025年12月31日")
        precondition(january.title(for: january.section(for: date(2025, 12, 1, calendar: calendar)),
                                   locale: chinese) == "2025年12月")
        let leap = ClipboardDateGrouping(now: date(2024, 3, 1, calendar: calendar), calendar: calendar)
        precondition(leap.title(for: leap.section(for: date(2024, 2, 29, calendar: calendar)),
                                locale: chinese) == "昨天")
        precondition(leap.title(for: leap.section(for: date(2024, 2, 28, calendar: calendar)),
                                locale: chinese) == "前天")
        let next = ClipboardDateGrouping(now: day(-1, in: grouping), calendar: calendar)
        precondition(next.section(for: grouping.today) == grouping.section(for: grouping.today),
                     "Midnight changes a label without changing its actual-day identity")

        let newYork = Self.calendar("America/New_York")
        for (month, today, yesterday) in [(3, 9, 8), (11, 2, 1)] {
            let grouping = ClipboardDateGrouping(now: date(2026, month, today, hour: 0, calendar: newYork),
                                                 calendar: newYork)
            precondition(grouping.title(for: grouping.section(for: date(2026, month, yesterday, hour: 0, calendar: newYork)),
                                       locale: english) == "Yesterday", "DST days use calendar arithmetic")
        }
        let reference = date(2026, 10, 4, hour: 12, calendar: Self.calendar("UTC"))
        let captured = date(2026, 10, 3, hour: 22, calendar: Self.calendar("UTC"))
        let taipei = ClipboardDateGrouping(now: reference, calendar: calendar)
        let losAngeles = ClipboardDateGrouping(now: reference, calendar: Self.calendar("America/Los_Angeles"))
        precondition(taipei.title(for: taipei.section(for: captured), locale: english) == "Today")
        precondition(losAngeles.title(for: losAngeles.section(for: captured), locale: english) == "Yesterday")
        print("PASS: local-day and monthly headers, 29/30-day boundary, Chinese/English, cross-year, leap day, DST, time zones and stable day identity")
    }

    private static func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        return view.subviews.lazy.compactMap { textField(in: $0) }.first
    }

    private static func headers(_ table: NSTableView, locale: Locale) -> [String] {
        let more = AppLocalization.string("Scroll for more", locale: locale)
        return (0..<table.numberOfRows).compactMap { row in
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? ClipboardSectionCellView,
                  let title = textField(in: cell)?.stringValue, title != more else { return nil }
            return title
        }
    }

    private static func row(_ title: String, in table: NSTableView) -> Int {
        (0..<table.numberOfRows).first { index in
            guard let cell = table.view(atColumn: 0, row: index, makeIfNecessary: true) as? ClipboardItemCellView
            else { return false }
            return textField(in: cell)?.stringValue == title
        }!
    }

    private static func settle() async throws {
        try await Task.sleep(for: .milliseconds(150))
    }

    private static func nativeList(in directory: URL) async throws {
        let calendar = calendar()
        let grouping = ClipboardDateGrouping(now: date(2026, 10, 4, calendar: calendar), calendar: calendar)
        func item(_ title: String, at date: Date) -> ClipboardItem {
            ClipboardItem(id: UUID(), kind: .text, text: title, imagePath: nil, imageFingerprint: nil,
                          createdAt: date, sourceBundleID: nil)
        }
        let daily = (0..<40).map { item("Day \($0)", at: day($0, in: grouping)) }
        let august = item("August", at: date(2026, 8, 15, calendar: calendar))
        let previousYear = item("Previous year", at: date(2025, 12, 5, calendar: calendar))
        let fixture = DateGroupingFixture(grouping: grouping, directory: directory)
        fixture.replace(Array(daily.prefix(33)))
        fixture.selectedID = daily[32].id
        fixture.hasMore = true
        var pointer = NSPoint.zero
        let window = PalettePanel(rootView: DateGroupingFixtureView(fixture: fixture).frame(width: 290, height: 300),
                                  visualStyle: .frosted, mouseLocation: { pointer })
        let hosting = window.contentView!
        window.orderFront(nil)
        defer { window.close() }
        try await settle()
        let table = ClipboardListAnimationTests.table(in: hosting)!
        let initial = headers(table, locale: fixture.locale)
        precondition(initial.count == 31 && initial.prefix(4) == ["今天", "昨天", "前天", "10月1日"],
                     "Initial native headers: \(initial)")
        precondition(initial.suffix(2) == ["9月5日", "2026年9月"])

        fixture.replace(daily + [august, previousYear])
        fixture.hasMore = false
        try await settle()
        let paginated = headers(table, locale: fixture.locale)
        precondition(paginated.filter { $0 == "2026年9月" }.count == 1,
                     "Appending another page merges entries into the existing month header")
        precondition(paginated.suffix(3) == ["2026年9月", "2026年8月", "2025年12月"])
        precondition(Set(paginated).count == paginated.count, "Pagination creates no duplicate headers")

        let clip = table.enclosingScrollView!.contentView
        let oldRow = row("Day 32", in: table)
        clip.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: oldRow).minY + 7))
        table.enclosingScrollView!.reflectScrolledClipView(clip)
        try await settle()
        let oldOffset = table.rect(ofRow: oldRow).minY - table.visibleRect.minY
        let oldOrigin = clip.bounds.origin
        let oldFrame = table.rect(ofRow: oldRow)
        fixture.grouping = ClipboardDateGrouping(now: day(-1, in: grouping), calendar: calendar)
        try await settle()
        let newRow = row("Day 32", in: table)
        precondition(abs(table.rect(ofRow: newRow).minY - table.visibleRect.minY - oldOffset) < 0.5,
                     "Midnight viewport: old row \(oldRow), frame \(oldFrame), origin \(oldOrigin), offset \(oldOffset); new row \(newRow), frame \(table.rect(ofRow: newRow)), origin \(clip.bounds.origin), visible \(table.visibleRect)")
        precondition(table.selectedRow == newRow && fixture.selectedID == daily[32].id)
        precondition(fixture.selectionCallbacks == 0, "Date regrouping emits no intermediate selections")
        precondition(headers(table, locale: fixture.locale).prefix(3) == ["昨天", "前天", "10月2日"])
        ClipboardListAnimationTests.assertRowGeometry(table)

        // Remove a header between the viewport anchor and the hovered item. That puts a
        // different item under the stationary pointer, which must not claim selection.
        fixture.grouping = grouping
        fixture.hoverEnabled = true
        try await settle()
        clip.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: row("Day 28", in: table)).minY + 7))
        table.enclosingScrollView!.reflectScrolledClipView(clip)
        try await settle()
        let pointerInWindow = table.convert(
            NSPoint(x: 70, y: table.rect(ofRow: row("Day 32", in: table)).midY), to: nil)
        pointer = window.convertPoint(toScreen: pointerInWindow)
        table.mouseMoved(with: NSEvent.mouseEvent(
            with: .mouseMoved, location: pointerInWindow, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 0, pressure: 0)!)
        precondition(fixture.selectedID == daily[32].id)
        let callbacks = fixture.selectionCallbacks
        fixture.grouping = ClipboardDateGrouping(now: day(-1, in: grouping), calendar: calendar)
        try await settle()
        precondition(table.row(at: table.convert(pointerInWindow, from: nil)) == row("Day 33", in: table))
        table.mouseEntered(with: NSEvent.enterExitEvent(
            with: .mouseEntered, location: pointerInWindow, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            trackingNumber: 0, userData: nil)!)
        try await settle()
        precondition(fixture.selectedID == daily[32].id && fixture.selectionCallbacks == callbacks,
                     "Passive tracking after a date regroup cannot select the new item under the pointer")
        let moved = NSPoint(x: pointerInWindow.x + 2, y: pointerInWindow.y)
        pointer = window.convertPoint(toScreen: moved)
        table.mouseMoved(with: NSEvent.mouseEvent(
            with: .mouseMoved, location: moved, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 0, pressure: 0)!)
        precondition(fixture.selectedID == daily[33].id, "Physical movement restores hover after date regrouping")

        fixture.hoverEnabled = false
        fixture.grouping = grouping
        fixture.query = "filtered"
        fixture.scroll = ScrollIntent(kind: .top)
        fixture.replace([daily[1], daily[29], daily[32], august])
        fixture.selectedID = daily[1].id
        try await settle()
        precondition(headers(table, locale: fixture.locale) == ["昨天", "9月5日", "2026年9月", "2026年8月"],
                     "Search results show only occupied day/month groups in reverse chronological order")
        precondition(table.selectedRow == 1)
        fixture.locale = Locale(identifier: "en")
        try await settle()
        precondition(headers(table, locale: fixture.locale).first == "Yesterday")
        precondition(headers(table, locale: fixture.locale).suffix(2) == ["September 2026", "August 2026"])
        ClipboardListAnimationTests.assertRowGeometry(table)
        print("PASS: native date headers, pagination merge, midnight labels/month merge, stable selection/viewport, filtered results and language changes")
    }

    private static func clockNotifications() async throws {
        var calendar = calendar()
        var now = date(2026, 10, 4, calendar: calendar)
        var updates: [ClipboardDateGrouping] = []
        weak var released: ClipboardDateRefresh?
        do {
            let refresh = ClipboardDateRefresh(now: { now }, calendar: { calendar }, onChange: { updates.append($0) })
            released = refresh
            refresh.start()
            precondition(updates.count == 1)
            now = calendar.date(byAdding: .day, value: 1, to: now)!
            NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
            try await settle()
            precondition(updates.last?.today == calendar.startOfDay(for: now), "Day-change notification refreshes labels")
            calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
            NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
            try await settle()
            precondition(updates.last?.calendar.timeZone == calendar.timeZone)
            now = calendar.date(byAdding: .day, value: 3, to: now)!
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
            try await settle()
            precondition(updates.last?.today == calendar.startOfDay(for: now), "Wake reconciles days elapsed during sleep")
            now = calendar.date(byAdding: .day, value: -1, to: now)!
            NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)
            try await settle()
            precondition(updates.last?.today == calendar.startOfDay(for: now), "A backwards clock change also reconciles labels")
        }
        precondition(released == nil, "Timers and notification blocks do not retain their owner")
        let count = updates.count
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        try await settle()
        precondition(updates.count == count, "Dismantling the list removes date observations")
        print("PASS: midnight/time-zone/clock/wake refresh and timer/observer lifecycle")
    }

    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kit-date-groups-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        rules()
        try await nativeList(in: directory)
        try await clockNotifications()
    }
}
