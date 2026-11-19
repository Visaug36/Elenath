import AppKit
import ElenathCore
import SwiftUI

/// Sizes and positions shared by the Day and Week grid: hour rows, the time gutter, event blocks and the
/// all-day strip. Vertical positions are wall-clock minutes since midnight, as `DayLayout` gives them.
enum TimeGridGeometry {
    static let gutterWidth = Metrics.timeGutterWidth
    static let hourHeight = Metrics.hourRowHeight
    static let minutesPerDay = 24 * 60
    static let gridHeight = Metrics.hourRowHeight * 24
    /// Room above midnight and below the last hour line, so the "00:00" label isn't cut off.
    static let verticalInset: CGFloat = 8
    /// Short events are drawn at least this many minutes tall.
    static let minimumBlockMinutes = 20
    /// A double-click on empty grid space starts a new event on this many minutes' grid.
    static let snapMinutes = 15
    /// Space between side-by-side blocks, and below each block.
    static let blockGap: CGFloat = 1
    /// Room kept free at the trailing edge of each day column, so there is always space to double-click.
    static let columnTrailingInset: CGFloat = 2

    /// One row of the all-day strip, and the bar inside it.
    static let allDayRowHeight: CGFloat = 22
    static let allDayBarHeight: CGFloat = 20
    static let allDayPadding: CGFloat = 3
    /// The Week view shows at most this many all-day rows; the last one then says "N more".
    static let maxAllDayRows = 3

    /// The width of one day column when the grid (gutter included) is `totalWidth` wide.
    static func columnWidth(totalWidth: CGFloat, dayCount: Int) -> CGFloat {
        max(0, (totalWidth - gutterWidth) / CGFloat(max(1, dayCount)))
    }

    /// The y position of a wall-clock minute (0…1440) in the grid.
    static func y(forMinute minute: Int) -> CGFloat {
        CGFloat(minute) / 60 * hourHeight
    }

    /// The y position of an hour line.
    static func y(forHour hour: Int) -> CGFloat {
        CGFloat(hour) * hourHeight
    }

    /// How tall a block is drawn, before the gap below it.
    static func height(of item: DayLayout.Item) -> CGFloat {
        y(forMinute: item.endMinute) - y(forMinute: item.startMinute)
    }

    /// The minute a click at `y` lands on, rounded down to 15 minutes and early enough for a new event to
    /// start that day.
    static func snappedMinute(atY y: CGFloat) -> Int {
        let minute = Int((y / hourHeight * 60).rounded(.down))
        let snapped = minute / snapMinutes * snapMinutes
        return min(max(0, snapped), minutesPerDay - snapMinutes)
    }

    /// Where an event block sits in its day column: its overlap column's share of the width, with 1 pt
    /// gaps, from its start minute to its end minute.
    static func blockFrame(for item: DayLayout.Item, columnWidth: CGFloat) -> CGRect {
        let count = CGFloat(max(1, item.columnCount))
        let usable = max(0, columnWidth - blockGap - columnTrailingInset)
        let slot = (usable + blockGap) / count
        let x = blockGap + slot * CGFloat(item.column)
        let blockHeight = max(1, height(of: item) - blockGap)
        return CGRect(x: x, y: y(forMinute: item.startMinute), width: max(0, slot - blockGap), height: blockHeight)
    }

    /// The placeholder block of a new event starting at `minute`: an hour tall, or up to midnight.
    static func draftFrame(minute: Int, columnWidth: CGFloat) -> CGRect {
        let top = y(forMinute: minute)
        let height = max(1, min(hourHeight, gridHeight - top) - blockGap)
        let width = max(0, columnWidth - blockGap - columnTrailingInset)
        return CGRect(x: blockGap, y: top, width: width, height: height)
    }

    /// Popovers open toward the middle of the grid: to the right of events in the first half of the week,
    /// to the left in the second half.
    static func popoverEdge(column: Int, dayCount: Int) -> Edge {
        column * 2 < dayCount ? .trailing : .leading
    }
}

/// How events are drawn wherever the calendar shows them: dimmed once they are over, and with a full-color
/// border when Increase Contrast is on.
@MainActor
enum CalendarEventStyle {
    /// Events that ended before now are drawn at this opacity.
    static func opacity(for occurrence: Occurrence, now: Date, contrast: ColorSchemeContrast) -> Double {
        guard occurrence.end < now else { return 1 }
        return contrast == .increased ? 0.7 : 0.55
    }

    static func border(for subject: Subject?, scheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        if contrast == .increased {
            return SubjectStyle.color(for: subject)
        }
        return SubjectStyle.border(for: subject, scheme: scheme)
    }

    /// Events are buttons to VoiceOver; the selected one says so.
    static func traits(isSelected: Bool) -> AccessibilityTraits {
        isSelected ? [.isButton, .isSelected] : [.isButton]
    }
}

/// Labels the calendar grids need beyond `EventFormatting`. Days are formatted on the Gregorian calendar
/// in the user's locale, like the rest of Elenath.
enum CalendarGridLabels {
    /// "Mon".
    static func shortWeekday(_ day: CalendarDate) -> String {
        dateStyle().weekday(.abbreviated).format(day.start(in: utc))
    }

    /// "Mon" for a Gregorian weekday (1 = Sunday … 7 = Saturday).
    static func shortWeekdaySymbol(_ weekday: Int) -> String {
        let symbols = gregorian.shortStandaloneWeekdaySymbols
        guard symbols.indices.contains(weekday - 1) else { return "" }
        return symbols[weekday - 1]
    }

    /// "1 Oct" (or "Oct 1", as the locale has it), for the first day of a month in the month grid.
    static func dayAndShortMonth(_ day: CalendarDate) -> String {
        dateStyle().day().month(.abbreviated).format(day.start(in: utc))
    }

    /// The 24 labels of the time gutter: "00:00" … "23:00", or "12:00 AM" … in a 12-hour locale.
    static func hourLabels() -> [String] {
        let calendar = gregorian
        let fallback = Date(timeIntervalSinceReferenceDate: 0)
        var labels: [String] = []
        for hour in 0..<24 {
            let date = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour)) ?? fallback
            labels.append(EventFormatting.time(date, timeZone: utc))
        }
        return labels
    }

    private static let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current

    private static var gregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .autoupdatingCurrent
        calendar.timeZone = utc
        return calendar
    }

    private static func dateStyle() -> Date.FormatStyle {
        Date.FormatStyle(
            locale: .autoupdatingCurrent, calendar: gregorian, timeZone: utc, capitalizationContext: .standalone)
    }
}

/// Which days an occurrence covers, for placing it on the grids.
enum CalendarGridDays {
    /// The last day an all-day occurrence covers (its first day for a one-day event).
    static func lastDay(ofAllDay occurrence: Occurrence) -> CalendarDate {
        guard case .allDay(let start, let end) = occurrence.event.timing else { return occurrence.date }
        return occurrence.date.adding(days: max(0, start.days(to: end)))
    }

    /// The days an occurrence touches: an all-day event's plain dates, or a timed event's days in
    /// `calendar`'s time zone (an end at midnight doesn't reach into the next day).
    static func coveredDays(_ occurrence: Occurrence, calendar: Calendar) -> ClosedRange<CalendarDate> {
        if occurrence.isAllDay {
            return occurrence.date...max(occurrence.date, lastDay(ofAllDay: occurrence))
        }
        let first = day(of: occurrence.start, calendar: calendar)
        guard occurrence.end > occurrence.start else { return first...first }
        let last = day(of: occurrence.end.addingTimeInterval(-1), calendar: calendar)
        return first...max(first, last)
    }

    /// The day `instant` falls on in `calendar`'s time zone.
    static func day(of instant: Date, calendar: Calendar) -> CalendarDate {
        let parts = calendar.dateComponents([.year, .month, .day], from: instant)
        return CalendarDate(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }
}

/// Tells a single click from the second click of a double-click, so one tap handler can do both. A
/// separate double-tap gesture would delay every single click until the double-click interval passed.
enum CalendarClick {
    @MainActor
    static func isDoubleClick() -> Bool {
        guard let event = NSApp.currentEvent else { return false }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            return event.clickCount >= 2
        default:
            return false
        }
    }
}
