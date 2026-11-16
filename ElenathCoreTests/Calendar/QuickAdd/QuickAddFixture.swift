import ElenathCore
import Foundation

/// Subjects, time zones and helpers for the Quick Add tests.
enum QuickAddFixture {
    static let physics = Subject(name: "Physics", color: .palette(.clay), keywords: ["phys"])
    static let linearAlgebra = Subject(name: "Linear Algebra", color: .palette(.teal), keywords: ["linalg", "algebra"])
    static let literature = Subject(name: "Literature", color: .palette(.iris), keywords: ["lit"])
    static let biology = Subject(name: "Biology", color: .palette(.fern), keywords: ["bio"])
    static let personal = Subject(name: "Personal", color: .palette(.rose))
    static let subjects = [physics, linearAlgebra, literature, biology, personal]

    static let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    static let newYork = TimeZone(identifier: "America/New_York")!

    /// Tuesday 6 October 2026, 23:30 UTC: already Wednesday morning in Tokyo, still Tuesday evening in
    /// New York.
    static let fixedNow = Date(timeIntervalSince1970: 1_791_329_400)

    static func parser(
        subjects: [Subject] = QuickAddFixture.subjects,
        timeZone: TimeZone,
        defaultAlert: AlertOffset? = .tenMinutes
    ) -> QuickAddParser {
        QuickAddParser(subjects: subjects, timeZone: timeZone, defaultDuration: 60 * 60, defaultAlert: defaultAlert)
    }

    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// The span of a timed draft, or nil for an all-day one.
    static func interval(of timing: EventTiming) -> DateInterval? {
        guard case .timed(let start, let end, _) = timing else { return nil }
        return DateInterval(start: start, end: max(start, end))
    }

    /// The first and last day of an all-day draft, or nil for a timed one.
    static func allDaySpan(of timing: EventTiming) -> AllDaySpan? {
        guard case .allDay(let first, let last) = timing else { return nil }
        return AllDaySpan(first: first, last: last)
    }

    struct AllDaySpan: Equatable {
        var first: CalendarDate
        var last: CalendarDate
    }
}
