import ElenathCore
import Foundation

/// Fixed time zones, instants and events for the Notifications tests. Nothing here reads the Mac's clock,
/// time zone or locale, and every event has a fixed ID, so identifiers and orderings are the same on every run.
enum AlertsFixture {
    static let amsterdam = DatesFixture.amsterdam
    static let newYork = DatesFixture.newYork
    static let utc = DatesFixture.utc

    /// Tuesday 6 October 2026, 13:50 in Amsterdam: the design's mock "now".
    static let now = DatesFixture.now

    /// `4954484C-A1E7-4000-8000-` followed by `number` as 12 digits.
    static func eventID(_ number: Int) -> UUID {
        let digits = String(number)
        let padded = String(repeating: "0", count: max(0, 12 - digits.count)) + digits
        return UUID(uuidString: "4954484C-A1E7-4000-8000-" + padded)!
    }

    static func occurrenceID(_ number: Int, _ date: CalendarDate) -> Occurrence.ID {
        Occurrence.ID(eventID: eventID(number), date: date)
    }

    static func day(_ year: Int, _ month: Int, _ day: Int) -> CalendarDate {
        CalendarDate(year: year, month: month, day: day)
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
        DatesFixture.instant(year, month, day, hour, minute, in: timeZone)
    }

    static func timed(
        _ number: Int,
        _ title: String,
        start: Date,
        minutes: Int = 60,
        in timeZone: TimeZone = AlertsFixture.amsterdam,
        alert: AlertOffset?,
        location: String = "",
        recurrence: RecurrenceRule? = nil,
        excludedDates: Set<CalendarDate> = [],
        detachedFrom: SeriesOccurrence? = nil
    ) -> Event {
        Event(
            id: eventID(number),
            title: title,
            timing: .timed(start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)), timeZone: timeZone),
            location: location,
            alert: alert,
            recurrence: recurrence,
            excludedDates: excludedDates,
            detachedFrom: detachedFrom,
            createdAt: DatesFixture.created)
    }

    static func allDay(
        _ number: Int,
        _ title: String,
        on first: CalendarDate,
        through last: CalendarDate? = nil,
        alert: AlertOffset?,
        recurrence: RecurrenceRule? = nil
    ) -> Event {
        Event(
            id: eventID(number),
            title: title,
            timing: .allDay(start: first, end: last ?? first),
            alert: alert,
            recurrence: recurrence,
            createdAt: DatesFixture.created)
    }

    static func library(_ events: [Event]) -> CalendarDocument {
        CalendarDocument(id: eventID(0), events: events)
    }

    static func identifiers(_ alerts: [PlannedAlert]) -> [String] {
        alerts.map { $0.identifier }
    }

    // MARK: - A small week

    /// Physics Lecture, Tuesdays 14:00–15:30 in Amsterdam since 1 September 2026, alert 10 minutes before.
    /// Seen from `now`, its next alerts are on 13 and 20 October (today's fires exactly at `now`).
    static let lecture = timed(
        1, "Physics Lecture", start: instant(2026, 9, 1, 14, 0, in: amsterdam), minutes: 90, alert: .tenMinutes,
        location: "Room B204", recurrence: RecurrenceRule(frequency: .weekly))

    /// Essay due, all day Thursday 8 October 2026, alert 1 day before (09:00 on Wednesday 7 October).
    static let essay = allDay(2, "Essay due", on: day(2026, 10, 8), alert: .oneDay)

    /// Physics Quiz, Thursday 8 October 2026 10:00 in Amsterdam, alert 1 hour before.
    static let quiz = timed(
        3, "Physics Quiz", start: instant(2026, 10, 8, 10, 0, in: amsterdam), alert: .oneHour, location: "Hall A")

    /// The quiz, renamed: its alert must be replaced.
    static var renamedQuiz: Event {
        var event = quiz
        event.title = "Physics Midterm"
        return event
    }
}
