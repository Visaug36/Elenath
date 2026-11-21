import ElenathCore
import Foundation

/// Fixed time zones, instants and events for the Dates tests. Nothing here reads the Mac's clock, time
/// zone or locale, so the tests give the same results on every machine.
enum DatesFixture {
    static let amsterdam = TimeZone(identifier: "Europe/Amsterdam")!
    static let newYork = TimeZone(identifier: "America/New_York")!
    static let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    static let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    static let utc = TimeZone(identifier: "UTC")!

    /// When the fixture events were created: 2026-09-01 00:00 UTC.
    static let created = Date(timeIntervalSince1970: 1_788_220_800)

    /// Tuesday 6 October 2026, 13:50 in Amsterdam: the design's mock "now".
    static let now = Date(timeIntervalSince1970: 1_791_287_400)

    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func day(_ year: Int, _ month: Int, _ day: Int) -> CalendarDate {
        CalendarDate(year: year, month: month, day: day)
    }

    /// Days of October 2026.
    static func octoberDays(_ days: [Int]) -> [CalendarDate] {
        days.map { CalendarDate(year: 2026, month: 10, day: $0) }
    }

    /// The instant of a wall-clock time in `timeZone`.
    static func instant(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0,
        _ minute: Int = 0,
        in timeZone: TimeZone
    ) -> Date {
        let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        return calendar(timeZone).date(from: parts)!
    }

    /// The wall-clock time of `instant` in `timeZone`, as "HH:mm".
    static func wallClock(_ instant: Date, in timeZone: TimeZone) -> String {
        let parts = calendar(timeZone).dateComponents([.hour, .minute], from: instant)
        return String(format: "%02d:%02d", parts.hour ?? -1, parts.minute ?? -1)
    }

    static func timed(
        _ title: String,
        start: Date,
        minutes: Int,
        in timeZone: TimeZone,
        recurrence: RecurrenceRule? = nil,
        excludedDates: Set<CalendarDate> = []
    ) -> Event {
        let end = start.addingTimeInterval(TimeInterval(minutes * 60))
        return Event(
            title: title,
            timing: .timed(start: start, end: end, timeZone: timeZone),
            recurrence: recurrence,
            excludedDates: excludedDates,
            createdAt: created)
    }

    static func allDay(
        _ title: String,
        from first: CalendarDate,
        through last: CalendarDate,
        recurrence: RecurrenceRule? = nil
    ) -> Event {
        Event(title: title, timing: .allDay(start: first, end: last), recurrence: recurrence, createdAt: created)
    }

    /// The days from `first` through `last` (inclusive) in `timeZone`, as an interval.
    static func days(_ first: CalendarDate, _ last: CalendarDate, in timeZone: TimeZone) -> DateInterval {
        DateInterval(start: first.start(in: timeZone), end: last.end(in: timeZone))
    }
}
