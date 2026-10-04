import AppKit

/// Header identity is the actual local day/month, never a relative label such as "Today".
enum ClipboardDateSection: Hashable, Sendable {
    case day(Date)
    case month(Date)

    var start: Date {
        switch self {
        case .day(let date), .month(let date): date
        }
    }
}

struct ClipboardDateGrouping: Equatable, Sendable {
    let today: Date
    let calendar: Calendar

    init(now: Date = Date(), calendar: Calendar = .current) {
        self.calendar = calendar
        today = calendar.startOfDay(for: now)
    }

    static var current: Self { Self() }

    func section(for date: Date) -> ClipboardDateSection {
        let day = min(calendar.startOfDay(for: date), today)
        let age = calendar.dateComponents([.day], from: day, to: today).day ?? .max
        if age < 30 { return .day(day) }
        return .month(calendar.dateInterval(of: .month, for: day)!.start)
    }

    func title(for section: ClipboardDateSection, locale: Locale) -> String {
        if case .day(let day) = section {
            switch calendar.dateComponents([.day], from: day, to: today).day {
            case 0: return AppLocalization.string("Today", locale: locale)
            case 1: return AppLocalization.string("Yesterday", locale: locale)
            case 2: return AppLocalization.string("Day Before Yesterday", locale: locale)
            default: break
            }
        }
        var format = Date.FormatStyle(
            date: .omitted, time: .omitted, locale: locale,
            calendar: calendar, timeZone: calendar.timeZone).month(.wide)
        switch section {
        case .day(let day):
            format = format.day()
            if calendar.component(.year, from: day) != calendar.component(.year, from: today)
                || calendar.component(.era, from: day) != calendar.component(.era, from: today)
            {
                format = format.year()
            }
        case .month:
            format = format.year()
        }
        return section.start.formatted(format)
    }
}

/// Reconcile local-day labels after midnight, clock/time-zone changes, and waking from sleep.
/// Calendar arithmetic handles short/long DST days instead of assuming 24-hour intervals.
@MainActor
final class ClipboardDateRefresh {
    private let now: () -> Date
    private let calendar: () -> Calendar
    private let onChange: (ClipboardDateGrouping) -> Void
    private var timer: Timer?
    private var observers: [NotificationToken] = []

    init(now: @escaping () -> Date = Date.init, calendar: @escaping () -> Calendar = { .current },
         onChange: @escaping (ClipboardDateGrouping) -> Void) {
        self.now = now
        self.calendar = calendar
        self.onChange = onChange
    }

    isolated deinit { timer?.invalidate() }

    func start() {
        guard observers.isEmpty else { return }
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange,
                     .NSSystemClockDidChange, NSLocale.currentLocaleDidChangeNotification] {
            observe(name, center: .default)
        }
        observe(NSWorkspace.didWakeNotification, center: NSWorkspace.shared.notificationCenter)
        refresh()
    }

    private func observe(_ name: Notification.Name, center: NotificationCenter) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        observers.append(NotificationToken(token, center: center))
    }

    func refresh() {
        let calendar = calendar()
        let now = now()
        let grouping = ClipboardDateGrouping(now: now, calendar: calendar)
        onChange(grouping)
        timer?.invalidate()
        guard let midnight = calendar.date(byAdding: .day, value: 1, to: grouping.today) else { return }
        let timer = Timer(timeInterval: max(midnight.timeIntervalSince(now), 0.01), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
