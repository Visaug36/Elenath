import ElenathCore
import Foundation

/// Locale-aware text for events: times, days, recurrence, alerts and VoiceOver labels.
///
/// Times follow the user's locale, including its 12- or 24-hour clock, and are shown in the time zone
/// passed in. Days are formatted on the Gregorian calendar, the one Elenath's grids and folder names use,
/// so a Mac set to another calendar still sees labels that match the grid.
enum EventFormatting {
    // MARK: - Times and days

    /// "14:00" or "2:00 PM".
    static func time(_ date: Date, timeZone: TimeZone) -> String {
        let style = Date.FormatStyle(
            date: .omitted, time: .shortened, locale: .autoupdatingCurrent, calendar: calendar(timeZone),
            timeZone: timeZone)
        return style.format(date)
    }

    /// "14:00 – 15:30" or "2:00 – 3:30 PM"; "All day" for all-day events. A timed event that ends on a
    /// later day includes the dates.
    static func timeRange(_ occurrence: Occurrence, timeZone: TimeZone) -> String {
        if occurrence.isAllDay { return String(localized: "All day") }
        let start = occurrence.start
        let end = max(occurrence.start, occurrence.end)
        let style = intervalStyle(timeZone, includingDate: !endsOnStartDay(occurrence, timeZone: timeZone))
        return style.format(start..<end)
    }

    /// "Tuesday, 6 October" (or "Tuesday, October 6", as the locale has it), with the year if asked.
    static func longDate(_ day: CalendarDate, timeZone: TimeZone, includeYear: Bool = false) -> String {
        var style = dateStyle(timeZone, capitalization: .beginningOfSentence).weekday(.wide).day().month(.wide)
        if includeYear {
            style = style.year()
        }
        return style.format(day.start(in: timeZone))
    }

    /// "Tuesday, 6 October · 14:00 – 15:30". All-day events end in "All day"; a timed event that runs
    /// past midnight shows both dates instead.
    static func dayAndTime(_ occurrence: Occurrence, timeZone: TimeZone, includeYear: Bool = false) -> String {
        if occurrence.isAllDay {
            let first = occurrence.date
            let last = lastDay(ofAllDay: occurrence)
            let allDay = String(localized: "All day")
            guard last != first else {
                return joined([longDate(first, timeZone: timeZone, includeYear: includeYear), allDay])
            }
            let firstText = shortDate(first, includeYear: includeYear)
            let lastText = shortDate(last, includeYear: includeYear)
            return joined([String(localized: "\(firstText) – \(lastText)", comment: "A range of days"), allDay])
        }
        guard endsOnStartDay(occurrence, timeZone: timeZone) else {
            return timeRange(occurrence, timeZone: timeZone)
        }
        let day = CalendarDate(occurrence.start, in: timeZone)
        return joined([
            longDate(day, timeZone: timeZone, includeYear: includeYear),
            timeRange(occurrence, timeZone: timeZone),
        ])
    }

    /// The secondary line of an Up next row: "in 10 min · 14:00 · Room B204" for an event starting within
    /// the hour, "Now · until 15:30 · Room B204" for one in progress, otherwise "Today · 17:00",
    /// "Tomorrow · 09:00" or "Thursday · 10:00".
    static func upNextSubtitle(_ occurrence: Occurrence, now: Date, math: CalendarMath) -> String {
        joined(upNextParts(occurrence, now: now, math: math))
    }

    /// The parts `upNextSubtitle` joins with " · ", for callers that need them separately (VoiceOver).
    static func upNextParts(_ occurrence: Occurrence, now: Date, math: CalendarMath) -> [String] {
        let timeZone = math.timeZone
        if occurrence.isAllDay {
            let day = occurrence.start <= now ? math.today(now: now) : occurrence.date
            return [relativeDayName(day, now: now, math: math), String(localized: "All day")]
        }
        var parts: [String]
        if occurrence.start <= now, now < occurrence.end {
            let end = time(occurrence.end, timeZone: timeZone)
            parts = [String(localized: "Now"), String(localized: "until \(end)", comment: "Up next: ends at a time")]
        } else if let minutes = minutesUntil(occurrence.start, now: now), minutes <= 60 {
            let minutesText = String(localized: "in \(minutes) min", comment: "Up next: starts in N minutes")
            parts = [minutesText, time(occurrence.start, timeZone: timeZone)]
        } else {
            let day = CalendarDate(occurrence.start, in: timeZone)
            return [relativeDayName(day, now: now, math: math), time(occurrence.start, timeZone: timeZone)]
        }
        let location = occurrence.event.location.trimmingCharacters(in: .whitespacesAndNewlines)
        if !location.isEmpty {
            parts.append(location)
        }
        return parts
    }

    // MARK: - Recurrence and alerts

    /// "Every day", "Every Tuesday" or "Every month on the 6th", plus ", until 18 Dec 2026" when the series
    /// ends. nil for events that don't repeat. The weekday and day of the month come from the event's
    /// start in its own time zone.
    static func recurrence(_ event: Event, timeZone: TimeZone) -> String? {
        guard let rule = event.recurrence else { return nil }
        let first = event.timing.startDate
        let base: String
        switch rule.frequency {
        case .daily:
            base = String(localized: "Every day")
        case .weekly:
            let weekday = weekdayName(first, capitalization: .middleOfSentence)
            base = String(localized: "Every \(weekday)", comment: "Repeats weekly on a weekday")
        case .monthly:
            let day = ordinal(first.day)
            base = String(localized: "Every month on the \(day)", comment: "Repeats monthly; an ordinal like 6th")
        }
        guard let until = rule.until else { return base }
        let untilText = shortDate(until, includeYear: true)
        return String(localized: "\(base), until \(untilText)", comment: "A repeat rule that ends on a day")
    }

    /// "At time of event", "10 minutes before", "1 hour before", "1 day before", "N hours before", … or
    /// "None" when there is no alert.
    static func alert(_ alert: AlertOffset?) -> String {
        guard let alert else { return String(localized: "None", comment: "No alert") }
        let minutes = alert.minutesBefore
        let minutesPerDay = 24 * 60
        if minutes == 0 {
            return String(localized: "At time of event")
        }
        if minutes % minutesPerDay == 0 {
            let days = minutes / minutesPerDay
            return days == 1 ? String(localized: "1 day before") : String(localized: "\(days) days before")
        }
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? String(localized: "1 hour before") : String(localized: "\(hours) hours before")
        }
        return minutes == 1 ? String(localized: "1 minute before") : String(localized: "\(minutes) minutes before")
    }

    // MARK: - VoiceOver

    /// "Physics Lecture, 2:00 PM to 3:30 PM", or "Essay due, all day".
    static func accessibilityLabel(_ occurrence: Occurrence, timeZone: TimeZone) -> String {
        let title = displayTitle(occurrence.event)
        if occurrence.isAllDay {
            return String(localized: "\(title), all day", comment: "VoiceOver: an all-day event")
        }
        let start = time(occurrence.start, timeZone: timeZone)
        let end = time(occurrence.end, timeZone: timeZone)
        return String(localized: "\(title), \(start) to \(end)", comment: "VoiceOver: an event and its times")
    }

    /// Parts joined with commas, for VoiceOver ("Physics Lecture, in 10 min, 14:00").
    static func spokenJoined(_ parts: [String]) -> String {
        guard var result = parts.first else { return "" }
        for part in parts.dropFirst() {
            result = String(localized: "\(result), \(part)", comment: "Joins parts of a VoiceOver label")
        }
        return result
    }

    // MARK: - Helpers for other views

    /// The event's title, or "New Event" when it has none.
    static func displayTitle(_ event: Event) -> String {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? String(localized: "New Event") : title
    }

    /// The day an occurrence appears on in the calendar: its start day in `timeZone`, or for all-day
    /// events their (time-zone-free) first day.
    static func displayDay(of occurrence: Occurrence, timeZone: TimeZone) -> CalendarDate {
        occurrence.isAllDay ? occurrence.date : CalendarDate(occurrence.start, in: timeZone)
    }

    /// Parts joined with " · ", as in "Today · 17:00".
    static func joined(_ parts: [String]) -> String {
        guard var result = parts.first else { return "" }
        for part in parts.dropFirst() {
            result = String(localized: "\(result) · \(part)", comment: "Joins parts of an event's description")
        }
        return result
    }

    /// "October" (the standalone month name, for titles).
    static func monthName(_ day: CalendarDate) -> String {
        dateStyle(utc, capitalization: .standalone).month(.wide).format(day.start(in: utc))
    }

    /// "2026".
    static func year(_ day: CalendarDate) -> String {
        dateStyle(utc, capitalization: .standalone).year().format(day.start(in: utc))
    }

    /// "October 2026", for the window title.
    static func monthAndYear(_ day: CalendarDate) -> String {
        dateStyle(utc, capitalization: .standalone).month(.wide).year().format(day.start(in: utc))
    }

    /// "Mon 12 Oct" (or "Mon, Oct 12"), with the year if asked.
    /// "Thu": the day's abbreviated weekday, for Quick Capture's event line.
    static func weekdayAbbreviation(_ day: CalendarDate) -> String {
        dateStyle(utc, capitalization: .standalone).weekday(.abbreviated).format(day.start(in: utc))
    }

    /// The title of a note made for an occurrence ("Notes for this lecture"): "Physics Lecture 12 Nov".
    static func noteTitle(for occurrence: Occurrence, timeZone: TimeZone) -> String {
        let day = displayDay(of: occurrence, timeZone: timeZone)
        return "\(displayTitle(occurrence.event)) \(shortDate(day))"
    }

    static func shortDate(_ day: CalendarDate, includeYear: Bool = false) -> String {
        let base = dateStyle(utc, capitalization: .beginningOfSentence)
        var style = base.weekday(.abbreviated).day().month(.abbreviated)
        if includeYear {
            style = style.year()
        }
        return style.format(day.start(in: utc))
    }

    /// The narrow weekday initial for a Gregorian weekday (1 = Sunday … 7 = Saturday): "M", "T", …
    static func veryShortWeekdaySymbol(_ weekday: Int) -> String {
        let symbols = calendar(utc).veryShortStandaloneWeekdaySymbols
        guard symbols.indices.contains(weekday - 1) else { return "" }
        return symbols[weekday - 1]
    }

    // MARK: - Private

    private static let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current

    private static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .autoupdatingCurrent
        calendar.timeZone = timeZone
        return calendar
    }

    private static func dateStyle(
        _ timeZone: TimeZone,
        capitalization: FormatStyleCapitalizationContext
    ) -> Date.FormatStyle {
        Date.FormatStyle(
            locale: .autoupdatingCurrent, calendar: calendar(timeZone), timeZone: timeZone,
            capitalizationContext: capitalization)
    }

    private static func intervalStyle(_ timeZone: TimeZone, includingDate: Bool) -> Date.IntervalFormatStyle {
        if includingDate {
            return Date.IntervalFormatStyle(
                date: .abbreviated, time: .shortened, locale: .autoupdatingCurrent, calendar: calendar(timeZone),
                timeZone: timeZone)
        }
        return Date.IntervalFormatStyle(
            date: .omitted, time: .shortened, locale: .autoupdatingCurrent, calendar: calendar(timeZone),
            timeZone: timeZone)
    }

    /// Whether a timed occurrence ends on the day it starts (an end at the following midnight counts).
    private static func endsOnStartDay(_ occurrence: Occurrence, timeZone: TimeZone) -> Bool {
        guard occurrence.end > occurrence.start else { return true }
        let lastInstant = occurrence.end.addingTimeInterval(-1)
        return CalendarDate(occurrence.start, in: timeZone) == CalendarDate(lastInstant, in: timeZone)
    }

    /// The last day an all-day occurrence covers (its first day for one-day events).
    private static func lastDay(ofAllDay occurrence: Occurrence) -> CalendarDate {
        guard case .allDay(let start, let end) = occurrence.event.timing else { return occurrence.date }
        return occurrence.date.adding(days: max(0, start.days(to: end)))
    }

    /// Whole minutes until `start`, rounded up; nil once it has started.
    private static func minutesUntil(_ start: Date, now: Date) -> Int? {
        let seconds = start.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        return Int((seconds / 60).rounded(.up))
    }

    private static func relativeDayName(_ day: CalendarDate, now: Date, math: CalendarMath) -> String {
        let today = math.today(now: now)
        switch math.relativeDay(day, today: today) {
        case .yesterday: return String(localized: "Yesterday")
        case .today: return String(localized: "Today")
        case .tomorrow: return String(localized: "Tomorrow")
        case .laterThisWeek: return weekdayName(day, capitalization: .beginningOfSentence)
        case .other(let date): return shortDate(date, includeYear: date.year != today.year)
        }
    }

    private static func weekdayName(_ day: CalendarDate, capitalization: FormatStyleCapitalizationContext) -> String {
        dateStyle(utc, capitalization: capitalization).weekday(.wide).format(day.start(in: utc))
    }

    private static func ordinal(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: number)) ?? String(number)
    }
}
