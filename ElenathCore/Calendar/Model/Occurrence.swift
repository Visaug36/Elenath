import Foundation

/// One concrete appearance of an event on the calendar. A non-repeating event has exactly one; a
/// repeating event has one per date its rule produces (minus `excludedDates`).
public struct Occurrence: Identifiable, Hashable, Sendable {
    public struct ID: Hashable, Sendable {
        public var eventID: UUID
        /// The occurrence's original day in the event's own time zone (the series key).
        public var date: CalendarDate

        public init(eventID: UUID, date: CalendarDate) {
            self.eventID = eventID
            self.date = date
        }
    }

    public var event: Event
    /// The occurrence's original day in the event's own time zone. For all-day events, the first day.
    public var date: CalendarDate
    /// Absolute start. For all-day events: the start of `date` in the display time zone.
    public var start: Date
    /// Absolute end (exclusive). For all-day events: the end of the last day in the display time zone.
    public var end: Date

    public init(event: Event, date: CalendarDate, start: Date, end: Date) {
        self.event = event
        self.date = date
        self.start = start
        self.end = end
    }

    public var id: ID { ID(eventID: event.id, date: date) }
    public var isAllDay: Bool { event.isAllDay }
    public var interval: DateInterval { DateInterval(start: start, end: max(start, end)) }
}
