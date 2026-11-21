import Foundation

/// How much of the calendar the main window shows at once.
public enum CalendarSpan: Hashable, CaseIterable, Sendable {
    case day, week, month
}

/// How a day relates to today, for labels such as "Today · 17:00" or "Thursday · 10:00".
public enum RelativeDay: Hashable, Sendable {
    case yesterday, today, tomorrow
    /// 2…6 days ahead. Gregorian weekday: 1 = Sunday … 7 = Saturday.
    case laterThisWeek(weekday: Int)
    /// Any other day, shown as a date.
    case other(CalendarDate)
}

/// Calendar arithmetic for the views (weeks, month grids, navigation) in one time zone and with the
/// user's first weekday.
///
/// Days are `CalendarDate`s, which have no time zone. Instants are produced only through `Calendar` in
/// `timeZone`, so DST changes, leap years and month lengths are handled.
public struct CalendarMath: Sendable {
    public let timeZone: TimeZone
    /// 1 = Sunday … 7 = Saturday. Values outside 1…7 wrap around (8 is Sunday).
    public let firstWeekday: Int
    private let gregorian: Calendar

    public init(timeZone: TimeZone, firstWeekday: Int) {
        let weekday = OccurrenceDayMath.floorModulo(firstWeekday - 1, 7) + 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = weekday
        self.timeZone = timeZone
        self.firstWeekday = weekday
        self.gregorian = calendar
    }

    /// A Gregorian calendar with `timeZone` and `firstWeekday` set.
    public var calendar: Calendar { gregorian }

    /// The day `now` falls on in `timeZone`.
    public func today(now: Date) -> CalendarDate {
        CalendarDate(now, in: timeZone)
    }

    /// The 7 days of the week that contains `date`, starting on `firstWeekday`.
    public func week(containing date: CalendarDate) -> [CalendarDate] {
        let start = weekStart(ofNumber: OccurrenceDayMath.number(of: date))
        return (0..<7).map { OccurrenceDayMath.date(fromNumber: start + $0) }
    }

    /// The days of a month view: whole weeks, from the week that contains the 1st through the week that
    /// contains the last day. Always 35 or 42 days (a February that fits in exactly 4 weeks gets a
    /// fifth). `month` may lie outside 1…12: 13 is January of the following year.
    public func monthGrid(year: Int, month: Int) -> [CalendarDate] {
        let index = OccurrenceDayMath.monthIndex(year: year, month: month)
        let (gridYear, gridMonth) = OccurrenceDayMath.yearAndMonth(ofIndex: index)
        let first = OccurrenceDayMath.number(of: CalendarDate(year: gridYear, month: gridMonth, day: 1))
        let start = weekStart(ofNumber: first)
        let shownDays = first - start + OccurrenceDayMath.daysInMonth(year: gridYear, month: gridMonth)
        let weeks = max(5, (shownDays + 6) / 7)
        return (0..<(weeks * 7)).map { OccurrenceDayMath.date(fromNumber: start + $0) }
    }

    /// Gregorian weekdays in display order, starting with `firstWeekday`: `[2, 3, 4, 5, 6, 7, 1]` when
    /// the week starts on Monday.
    public func weekdayOrder() -> [Int] {
        (0..<7).map { (firstWeekday - 1 + $0) % 7 + 1 }
    }

    /// From the start of `first` to the end of `last` in `timeZone`. The order of the two days doesn't
    /// matter.
    public func interval(from first: CalendarDate, through last: CalendarDate) -> DateInterval {
        let start = min(first, last).start(in: timeZone)
        let end = max(first, last).end(in: timeZone)
        return DateInterval(start: start, end: max(start, end))
    }

    /// The days the main window shows for `span` around `date`: the day itself, its week, or its month
    /// grid.
    public func visibleDays(for span: CalendarSpan, around date: CalendarDate) -> [CalendarDate] {
        switch span {
        case .day: return [date]
        case .week: return week(containing: date)
        case .month: return monthGrid(year: date.year, month: date.month)
        }
    }

    /// `date` moved by `count` days, weeks or months (negative moves back). Moving by months keeps the
    /// day of the month when the target month has it and otherwise uses its last day, so 31 January
    /// plus one month is 28 (or 29) February.
    public func step(_ date: CalendarDate, by span: CalendarSpan, count: Int) -> CalendarDate {
        let number = OccurrenceDayMath.number(of: date)
        switch span {
        case .day:
            return OccurrenceDayMath.date(fromNumber: number + count)
        case .week:
            return OccurrenceDayMath.date(fromNumber: number + 7 * count)
        case .month:
            let index = OccurrenceDayMath.monthIndex(year: date.year, month: date.month) + count
            let (year, month) = OccurrenceDayMath.yearAndMonth(ofIndex: index)
            let day = min(date.day, OccurrenceDayMath.daysInMonth(year: year, month: month))
            return CalendarDate(year: year, month: month, day: day)
        }
    }

    /// How `date` relates to `today`. Days 2…6 ahead are `laterThisWeek`, named by their weekday.
    public func relativeDay(_ date: CalendarDate, today: CalendarDate) -> RelativeDay {
        let number = OccurrenceDayMath.number(of: date)
        switch number - OccurrenceDayMath.number(of: today) {
        case 0: return .today
        case 1: return .tomorrow
        case -1: return .yesterday
        case 2...6: return .laterThisWeek(weekday: OccurrenceDayMath.weekday(ofNumber: number))
        default: return .other(date)
        }
    }

    /// The wall-clock time of `instant` in `timeZone`, in minutes since midnight (`hh * 60 + mm`).
    public func minutesOfDay(_ instant: Date) -> Int {
        let parts = gregorian.dateComponents([.hour, .minute], from: instant)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// The day number of the first day of the week containing day number `number`.
    private func weekStart(ofNumber number: Int) -> Int {
        let daysIntoWeek = OccurrenceDayMath.floorModulo(OccurrenceDayMath.weekday(ofNumber: number) - firstWeekday, 7)
        return number - daysIntoWeek
    }
}
