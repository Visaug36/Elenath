import ElenathCore
import Foundation

/// The event editor's working copy: plain fields the form binds to, turned back into an `Event` on save.
///
/// - The form shows days and times in `displayTimeZone` (the calendar's). Timed events keep absolute
///   instants, so the event's own time zone only matters when the event is rebuilt: new events get the
///   calendar's zone, edited ones keep theirs.
/// - The end never comes before the start. Moving the date or the start time keeps the duration; an end
///   time earlier than the start time means the next day (an event past midnight).
/// - All-day events have a first and a last day (inclusive). The timed start and end are kept while the
///   all-day switch is on, so turning it off again brings them back on the chosen day.
struct EventEditorDraft: Equatable {
    var title: String
    private(set) var isAllDay: Bool
    /// Timed: absolute start and end (`end >= start`).
    private(set) var start: Date
    private(set) var end: Date
    /// All-day: the first and last day. While timed, `firstDay` is the start's day.
    private(set) var firstDay: CalendarDate
    private(set) var lastDay: CalendarDate
    var subjectID: UUID?
    var location: String
    var notes: String
    var alert: AlertOffset?
    /// nil = never repeats.
    var frequency: RecurrenceRule.Frequency?
    /// The repeat rule's last day, kept as it was.
    let until: CalendarDate?
    let displayTimeZone: TimeZone

    /// The editor's fields for `event` at `timing` (an occurrence's own timing when editing one
    /// occurrence of a series).
    init(event: Event, timing: EventTiming, displayTimeZone: TimeZone) {
        title = event.title
        subjectID = event.subjectID
        location = event.location
        notes = event.notes
        alert = event.alert
        frequency = event.recurrence?.frequency
        until = event.recurrence?.until
        self.displayTimeZone = displayTimeZone
        switch timing {
        case .timed(let start, let end, _):
            isAllDay = false
            self.start = start
            self.end = max(start, end)
            firstDay = CalendarDate(start, in: displayTimeZone)
            lastDay = firstDay
        case .allDay(let first, let last):
            isAllDay = true
            firstDay = first
            lastDay = max(first, last)
            let defaultStart = Self.date(on: first, hour: 9, minute: 0, in: displayTimeZone)
            start = defaultStart
            end = Self.calendar(displayTimeZone).date(byAdding: .hour, value: 1, to: defaultStart) ?? defaultStart
        }
    }

    // MARK: - Form bindings

    /// The all-day switch.
    var allDay: Bool {
        get { isAllDay }
        set { setAllDay(newValue) }
    }

    /// The Date field: the first day. Changing it moves the event and keeps its length.
    var startDay: Date {
        get { isAllDay ? firstDay.start(in: displayTimeZone) : start }
        set { move(to: CalendarDate(newValue, in: displayTimeZone)) }
    }

    /// The all-day end field: the last day, never before the first.
    var endDay: Date {
        get { lastDay.start(in: displayTimeZone) }
        set { lastDay = max(firstDay, CalendarDate(newValue, in: displayTimeZone)) }
    }

    /// The start time field. Changing it keeps the duration.
    var startTime: Date {
        get { start }
        set {
            let duration = max(0, end.timeIntervalSince(start))
            start = date(on: firstDay, matchingTimeOf: newValue)
            end = start.addingTimeInterval(duration)
        }
    }

    /// The end time field. A time before the start time is on the next day.
    var endTime: Date {
        get { end }
        set {
            var candidate = date(on: firstDay, matchingTimeOf: newValue)
            if candidate < start {
                candidate = date(on: firstDay.adding(days: 1), matchingTimeOf: newValue)
            }
            end = max(start, candidate)
        }
    }

    /// Seconds from start to end, for the duration hint of a timed event.
    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    /// How many days an all-day event covers.
    var dayCount: Int { firstDay.days(to: lastDay) + 1 }

    // MARK: - Building the event

    /// The timing the form describes. Timed events belong to `eventTimeZone`.
    func timing(in eventTimeZone: TimeZone) -> EventTiming {
        if isAllDay {
            return .allDay(start: firstDay, end: max(firstDay, lastDay))
        }
        return EventTiming.timed(start: start, end: max(start, end), timeZone: eventTimeZone).roundedToSeconds
    }

    /// `original` with the form's fields. An empty title becomes `fallbackTitle`. `id`, `createdAt`,
    /// `excludedDates` and `detachedFrom` are left as they were; `SeriesEditing` manages them on updates.
    func event(updating original: Event, eventTimeZone: TimeZone, fallbackTitle: String) -> Event {
        var event = original
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        event.title = trimmedTitle.isEmpty ? fallbackTitle : trimmedTitle
        event.timing = timing(in: eventTimeZone)
        event.subjectID = subjectID
        event.location = location.trimmingCharacters(in: .whitespacesAndNewlines)
        event.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        event.alert = alert
        event.recurrence = frequency.map { RecurrenceRule(frequency: $0, until: until) }
        return event
    }

    // MARK: - Private

    private mutating func setAllDay(_ on: Bool) {
        guard on != isAllDay else { return }
        if on {
            firstDay = CalendarDate(start, in: displayTimeZone)
            let lastInstant = end > start ? end.addingTimeInterval(-1) : start
            lastDay = max(firstDay, CalendarDate(lastInstant, in: displayTimeZone))
        } else {
            let length = duration
            start = date(on: firstDay, matchingTimeOf: start)
            end = start.addingTimeInterval(length)
            lastDay = firstDay
        }
        isAllDay = on
    }

    private mutating func move(to day: CalendarDate) {
        let span = max(0, firstDay.days(to: lastDay))
        let length = duration
        firstDay = day
        lastDay = day.adding(days: span)
        start = date(on: day, matchingTimeOf: start)
        end = start.addingTimeInterval(length)
    }

    /// `day` at the wall-clock hour and minute `instant` shows in the display time zone. A time that
    /// doesn't exist that day (a DST gap) moves forward, as `Calendar` does.
    private func date(on day: CalendarDate, matchingTimeOf instant: Date) -> Date {
        let time = Self.calendar(displayTimeZone).dateComponents([.hour, .minute], from: instant)
        return Self.date(on: day, hour: time.hour ?? 0, minute: time.minute ?? 0, in: displayTimeZone)
    }

    private static func date(on day: CalendarDate, hour: Int, minute: Int, in timeZone: TimeZone) -> Date {
        let parts = DateComponents(year: day.year, month: day.month, day: day.day, hour: hour, minute: minute)
        return calendar(timeZone).date(from: parts) ?? day.start(in: timeZone)
    }

    private static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
