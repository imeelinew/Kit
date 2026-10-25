import AppKit
@testable import Kit

@MainActor
enum DateGroupingTests {
    static func run() async throws {
        for zone in ["Asia/Taipei", "America/Los_Angeles", "UTC"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
                calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
            }
            for now in [date(2026, 3, 9), date(2026, 11, 2), date(2026, 1, 2)] {
                let grouping = ClipboardDateGrouping(now: now, calendar: calendar)
                for age in [0, 1, 2, 29, 30, 31, 365] {
                    let past = calendar.date(byAdding: .day, value: -age, to: now)!
                    let section = grouping.section(for: past)
                    let expected: ClipboardDateSection = age < 30
                        ? .day(calendar.startOfDay(for: past))
                        : .month(calendar.dateInterval(of: .month, for: past)!.start)
                    try TestSupport.expect(section == expected, "Calendar day boundary \(age) in \(zone)")
                }
                let future = calendar.date(byAdding: .day, value: 7, to: now)!
                try TestSupport.expect(grouping.section(for: future) == .day(grouping.today),
                                       "Future clock skew clamps to today")
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 23))!
        let grouping = ClipboardDateGrouping(now: now, calendar: calendar)
        let english = Locale(identifier: "en")
        let chinese = Locale(identifier: "zh-Hans")
        for (age, title) in [(0, "Today"), (1, "Yesterday"), (2, "Day Before Yesterday")] {
            let day = calendar.date(byAdding: .day, value: -age, to: grouping.today)!
            try TestSupport.expect(grouping.title(for: .day(day), locale: english) == title,
                                   "Relative English day title \(age)")
        }
        try TestSupport.expect(grouping.title(for: .day(grouping.today), locale: chinese) == "今天",
                               "Relative labels use selected localization")
        let old = calendar.date(from: DateComponents(year: 2025, month: 12, day: 1))!
        try TestSupport.expect(grouping.title(for: .month(old), locale: english).contains("2025"),
                               "Month labels include their year")
        var received: [ClipboardDateGrouping] = []
        let refresher = ClipboardDateRefresh(now: { now }, calendar: { calendar }) { received.append($0) }
        refresher.refresh()
        now = calendar.date(byAdding: .day, value: 1, to: now)!
        refresher.refresh()
        try TestSupport.expect(received.count == 2 && received[0] != received[1],
                               "Refresh recomputes grouping after midnight")
        let originalSection = grouping.section(for: grouping.today)
        try TestSupport.expect(originalSection == received[1].section(for: grouping.today)
                               && received[1].title(for: originalSection, locale: english) == "Yesterday",
                               "Midnight changes relative labels while preserving section identity")
    }
}
