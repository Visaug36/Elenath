import Foundation

/// Turns events into the concrete `Occurrence`s that appear in a stretch of time.
///
/// - Timed events repeat in their own time zone: a weekly 14:00 lecture stays at 14:00 wall-clock time
///   across DST changes, and keeps its duration as absolute elapsed time. A start time that doesn't
///   exist on a day (DST spring-forward gap) moves forward, as `Calendar` does.
/// - All-day events are plain dates. They are placed in `displayTimeZone`, so they keep their calendar
///   dates wherever the Mac is.
/// - Monthly events skip months without their day; `until` is inclusive; `excludedDates` are skipped.
///
/// Queries over thousands of events stay fast: non-repeating events are tested by interval overlap,
/// and repeating events jump straight to the first candidate date near the start of the range instead
/// of walking from the start of the series.
public struct OccurrenceExpander: Sendable {
    /// The time zone all-day events are placed in (normally the Mac's current time zone).
    public let displayTimeZone: TimeZone
    private let displayCalendar: Calendar

    public init(displayTimeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = displayTimeZone
        self.displayTimeZone = displayTimeZone
        self.displayCalendar = calendar
    }

    /// The occurrences of `event` that overlap `interval`, sorted by start.
    public func occurrences(of event: Event, in interval: DateInterval) -> [Occurrence] {
        occurrences(of: [event], in: interval)
    }

    /// The occurrences of `events` that overlap `interval`, sorted by start. On equal starts, all-day
    /// occurrences come first, then longer ones, then by title.
    ///
    /// An occurrence overlaps when it starts before the end of `interval` and ends after its start; a
    /// zero-length occurrence counts when it starts inside `interval`.
    public func occurrences(of events: [Event], in interval: DateInterval) -> [Occurrence] {
        let window = ExpansionWindow(
            interval: interval,
            firstDay: displayDayNumber(of: interval.start),
            lastDay: displayDayNumber(of: interval.end))
        var calendars = EventZoneCalendars(display: displayCalendar)
        var result: [Occurrence] = []
        for event in events {
            collect(event, in: window, calendars: &calendars, into: &result)
        }
        result.sort(by: Self.chronologicalOrder)
        return result
    }

    /// The occurrence of `event` whose original day is `date` (in the event's own time zone for timed
    /// events), or nil if the event doesn't happen that day or the day was excluded.
    public func occurrence(of event: Event, on date: CalendarDate) -> Occurrence? {
        guard date.isValid else { return nil }
        let number = OccurrenceDayMath.number(of: date)
        switch event.timing {
        case .timed(let start, let end, let timeZone):
            var calendars = EventZoneCalendars(display: displayCalendar)
            let pattern = TimedPattern(start: start, end: end, calendar: calendars.calendar(for: timeZone))
            guard let rule = event.recurrence else {
                guard date == pattern.firstDay else { return nil }
                return Occurrence(event: event, date: date, start: start, end: max(start, end))
            }
            guard OccurrenceDayMath.isSeriesDay(date, of: rule, firstDay: pattern.firstDay) else { return nil }
            guard !event.excludedDates.contains(date) else { return nil }
            guard let occurrenceStart = pattern.startInstant(on: date, number: number) else { return nil }
            let occurrenceEnd = occurrenceStart.addingTimeInterval(pattern.duration)
            return Occurrence(event: event, date: date, start: occurrenceStart, end: occurrenceEnd)
        case .allDay(let first, let last):
            if let rule = event.recurrence {
                guard OccurrenceDayMath.isSeriesDay(date, of: rule, firstDay: first) else { return nil }
                guard !event.excludedDates.contains(date) else { return nil }
            } else if date != first {
                return nil
            }
            return allDayOccurrence(of: event, date: date, number: number, length: allDayLength(first, last))
        }
    }

    /// The occurrences that start at or after `now` and within `horizonDays` days of it, sorted by
    /// start, at most `limit` of them. Occurrences already in progress are left out.
    public func upcoming(_ events: [Event], after now: Date, limit: Int, horizonDays: Int) -> [Occurrence] {
        guard limit > 0, horizonDays > 0,
            let horizon = displayCalendar.date(byAdding: .day, value: horizonDays, to: now)
        else { return [] }
        // Look a day ahead first and widen the window only while there are too few results.
        var windowDays = 1
        var windowEnd = now
        var starting: [Occurrence] = []
        repeat {
            windowEnd = min(displayCalendar.date(byAdding: .day, value: windowDays, to: now) ?? horizon, horizon)
            let found = occurrences(of: events, in: DateInterval(start: now, end: windowEnd))
            starting = found.filter { $0.start >= now }
            windowDays *= 4
        } while starting.count < limit && windowEnd < horizon
        return Array(starting.prefix(limit))
    }

    // MARK: - Search support

    /// How far `nextOccurrence` looks ahead, and a quarter of how far `latestOccurrence` looks back.
    static let searchHorizonDays = 8_192

    /// The earliest occurrence of `event` that hasn't ended at `now` (one in progress counts), or nil.
    func nextOccurrence(of event: Event, unfinishedAt now: Date) -> Occurrence? {
        guard event.repeats else {
            let single = firstOccurrence(of: event)
            return Self.isUnfinished(single, at: now) ? single : nil
        }
        var days = 8
        while days <= Self.searchHorizonDays {
            guard let end = displayCalendar.date(byAdding: .day, value: days, to: now) else { return nil }
            let found = occurrences(of: event, in: DateInterval(start: now, end: end))
            if let next = found.first(where: { Self.isUnfinished($0, at: now) }) { return next }
            days *= 4
        }
        return nil
    }

    /// The latest occurrence of `event` that has ended by `now`, or nil.
    func latestOccurrence(of event: Event, finishedBy now: Date) -> Occurrence? {
        let first = firstOccurrence(of: event)
        guard event.repeats else {
            return Self.isUnfinished(first, at: now) ? nil : first
        }
        var days = 8
        while days <= Self.searchHorizonDays * 4 {
            guard let start = displayCalendar.date(byAdding: .day, value: -days, to: now) else { return nil }
            let found = occurrences(of: event, in: DateInterval(start: start, end: now))
            if let latest = found.last(where: { !Self.isUnfinished($0, at: now) }) { return latest }
            if start <= first.start { return nil }
            days *= 4
        }
        return nil
    }

    /// Whether `occurrence` hasn't ended at `now`: it ends later, or (zero-length) starts at or after it.
    static func isUnfinished(_ occurrence: Occurrence, at now: Date) -> Bool {
        occurrence.end > now || occurrence.start >= now
    }

    // MARK: - Ordering

    /// The order occurrences are listed in: by start; on equal starts all-day first, then the longer
    /// one, then by title, then by event ID and date, so the order never depends on the input order.
    static func chronologicalOrder(_ lhs: Occurrence, _ rhs: Occurrence) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
        if lhs.end != rhs.end { return lhs.end > rhs.end }
        if lhs.event.title != rhs.event.title { return lhs.event.title < rhs.event.title }
        if lhs.event.id != rhs.event.id { return lhs.event.id.uuidString < rhs.event.id.uuidString }
        return lhs.date < rhs.date
    }

    /// Whether `start..<end` overlaps `interval`. A zero-length span counts when it starts inside.
    static func overlaps(start: Date, end: Date, _ interval: DateInterval) -> Bool {
        if end > start {
            return start < interval.end && end > interval.start
        }
        return start >= interval.start && start < interval.end
    }

    // MARK: - Expansion

    /// A query interval plus its first and last day in the display time zone, as day numbers.
    private struct ExpansionWindow {
        let interval: DateInterval
        let firstDay: Int
        let lastDay: Int
    }

    /// What all occurrences of a timed event share: the wall-clock start time in the event's own time
    /// zone and the absolute duration.
    private struct TimedPattern {
        let calendar: Calendar
        let firstStart: Date
        let duration: TimeInterval
        let firstDay: CalendarDate
        let firstNumber: Int
        let hour: Int
        let minute: Int
        let second: Int

        /// `calendar` is a Gregorian calendar in the event's own time zone.
        init(start: Date, end: Date, calendar: Calendar) {
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
            let firstDay = CalendarDate(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
            self.calendar = calendar
            self.firstStart = start
            self.duration = max(0, end.timeIntervalSince(start))
            self.firstDay = firstDay
            self.firstNumber = OccurrenceDayMath.number(of: firstDay)
            self.hour = parts.hour ?? 0
            self.minute = parts.minute ?? 0
            self.second = parts.second ?? 0
        }

        /// The start of the occurrence on `day` (day number `number`): the series' wall-clock start time
        /// on that day in the event's time zone. A time inside a DST gap moves forward, as `Calendar`
        /// resolves it. The first occurrence is exactly the event's own start.
        func startInstant(on day: CalendarDate, number: Int) -> Date? {
            if number == firstNumber { return firstStart }
            let parts = DateComponents(
                year: day.year, month: day.month, day: day.day, hour: hour, minute: minute, second: second)
            return calendar.date(from: parts)
        }

        /// The day number of the day `instant` falls on in the event's time zone.
        func dayNumber(of instant: Date) -> Int {
            let parts = calendar.dateComponents([.year, .month, .day], from: instant)
            let day = CalendarDate(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
            return OccurrenceDayMath.number(of: day)
        }
    }

    /// Gregorian calendars by event time zone, built once per query instead of once per event (making a
    /// `Calendar` is far slower than using one).
    private struct EventZoneCalendars {
        private var byZone: [TimeZone: Calendar]

        init(display: Calendar) {
            byZone = [display.timeZone: display]
        }

        mutating func calendar(for timeZone: TimeZone) -> Calendar {
            if let cached = byZone[timeZone] { return cached }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            byZone[timeZone] = calendar
            return calendar
        }
    }

    private func collect(
        _ event: Event,
        in window: ExpansionWindow,
        calendars: inout EventZoneCalendars,
        into result: inout [Occurrence]
    ) {
        switch event.timing {
        case .timed(let start, let end, let timeZone):
            guard let rule = event.recurrence else {
                let finish = max(start, end)
                guard Self.overlaps(start: start, end: finish, window.interval) else { return }
                let date = CalendarDate(start, in: timeZone)
                result.append(Occurrence(event: event, date: date, start: start, end: finish))
                return
            }
            // No occurrence starts before the series does.
            guard start < window.interval.end else { return }
            let pattern = TimedPattern(start: start, end: end, calendar: calendars.calendar(for: timeZone))
            collectTimedSeries(event, rule: rule, pattern: pattern, window: window, into: &result)
        case .allDay(let first, let last):
            let length = allDayLength(first, last)
            guard let rule = event.recurrence else {
                let firstNumber = OccurrenceDayMath.number(of: first)
                // Cheap test on day numbers first; a spare day on each side covers any time zone offset.
                guard firstNumber + length >= window.firstDay - 1, firstNumber <= window.lastDay + 1 else { return }
                let occurrence = allDayOccurrence(of: event, date: first, number: firstNumber, length: length)
                if Self.overlaps(start: occurrence.start, end: occurrence.end, window.interval) {
                    result.append(occurrence)
                }
                return
            }
            collectAllDaySeries(event, rule: rule, first: first, length: length, window: window, into: &result)
        }
    }

    private func collectTimedSeries(
        _ event: Event,
        rule: RecurrenceRule,
        pattern: TimedPattern,
        window: ExpansionWindow,
        into result: inout [Occurrence]
    ) {
        let interval = window.interval
        // An occurrence overlaps when it starts in (interval.start - duration) ..< interval.end. A spare
        // day on each side absorbs DST shifts of the start time.
        let low = pattern.dayNumber(of: interval.start.addingTimeInterval(-pattern.duration)) - 1
        let high = pattern.dayNumber(of: interval.end) + 1
        OccurrenceDayMath.forEachSeriesDay(of: rule, firstDay: pattern.firstDay, from: low, through: high) { number in
            let day = OccurrenceDayMath.date(fromNumber: number)
            if event.excludedDates.contains(day) { return true }
            guard let start = pattern.startInstant(on: day, number: number) else { return true }
            let end = start.addingTimeInterval(pattern.duration)
            if Self.overlaps(start: start, end: end, interval) {
                result.append(Occurrence(event: event, date: day, start: start, end: end))
            }
            return true
        }
    }

    private func collectAllDaySeries(
        _ event: Event,
        rule: RecurrenceRule,
        first: CalendarDate,
        length: Int,
        window: ExpansionWindow,
        into result: inout [Occurrence]
    ) {
        // An occurrence on day k covers k ... k + length. A spare day on each side covers the offset
        // between the display time zone and the interval's.
        let low = window.firstDay - length - 1
        let high = window.lastDay + 1
        OccurrenceDayMath.forEachSeriesDay(of: rule, firstDay: first, from: low, through: high) { number in
            let day = OccurrenceDayMath.date(fromNumber: number)
            guard !event.excludedDates.contains(day) else { return true }
            let occurrence = allDayOccurrence(of: event, date: day, number: number, length: length)
            if Self.overlaps(start: occurrence.start, end: occurrence.end, window.interval) {
                result.append(occurrence)
            }
            return true
        }
    }

    /// The event's first occurrence, whether or not its day is excluded.
    private func firstOccurrence(of event: Event) -> Occurrence {
        switch event.timing {
        case .timed(let start, let end, let timeZone):
            return Occurrence(event: event, date: CalendarDate(start, in: timeZone), start: start, end: max(start, end))
        case .allDay(let first, let last):
            let number = OccurrenceDayMath.number(of: first)
            return allDayOccurrence(of: event, date: first, number: number, length: allDayLength(first, last))
        }
    }

    /// An all-day occurrence starting on day number `number` and lasting `length` more days, from the
    /// start of its first day to the end of its last day in the display time zone.
    private func allDayOccurrence(of event: Event, date: CalendarDate, number: Int, length: Int) -> Occurrence {
        Occurrence(
            event: event, date: date, start: startOfDisplayDay(number: number),
            end: startOfDisplayDay(number: number + length + 1))
    }

    /// Days after the first that an all-day event lasts (0 for a one-day event).
    private func allDayLength(_ first: CalendarDate, _ last: CalendarDate) -> Int {
        max(0, OccurrenceDayMath.number(of: last) - OccurrenceDayMath.number(of: first))
    }

    /// The first instant of a day in the display time zone, like `CalendarDate.start(in:)`.
    private func startOfDisplayDay(number: Int) -> Date {
        let day = OccurrenceDayMath.date(fromNumber: number)
        let noon = DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)
        guard let instant = displayCalendar.date(from: noon) else { return day.start(in: displayTimeZone) }
        return displayCalendar.startOfDay(for: instant)
    }

    /// The day number of the day `instant` falls on in the display time zone.
    private func displayDayNumber(of instant: Date) -> Int {
        let parts = displayCalendar.dateComponents([.year, .month, .day], from: instant)
        let day = CalendarDate(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
        return OccurrenceDayMath.number(of: day)
    }
}
