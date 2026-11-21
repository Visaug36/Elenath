import Foundation

/// Integer arithmetic on plain Gregorian days, for code that walks many dates (expanding repeating
/// events over thousands of events), where building a `Calendar` for every step would be too slow.
///
/// A day number counts days since 1970-01-01 on the proleptic Gregorian calendar, so consecutive days
/// differ by exactly 1. Day numbers have no time zone, just like `CalendarDate`: turning a day into an
/// instant still goes through `Calendar` with an explicit time zone.
enum OccurrenceDayMath {
    /// Days since 1970-01-01 (H. Hinnant's `days_from_civil`).
    static func number(of date: CalendarDate) -> Int {
        let year = date.month <= 2 ? date.year - 1 : date.year
        let era = floorDivide(year, 400)
        let yearOfEra = year - era * 400
        let monthFromMarch = date.month > 2 ? date.month - 3 : date.month + 9
        let dayOfYear = (153 * monthFromMarch + 2) / 5 + date.day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The day with day number `number` (H. Hinnant's `civil_from_days`).
    static func date(fromNumber number: Int) -> CalendarDate {
        let shifted = number + 719_468
        let era = floorDivide(shifted, 146_097)
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthFromMarch = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthFromMarch + 2) / 5 + 1
        let month = monthFromMarch < 10 ? monthFromMarch + 3 : monthFromMarch - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return CalendarDate(year: year, month: month, day: day)
    }

    /// Gregorian weekday of a day number: 1 = Sunday … 7 = Saturday. 1970-01-01 was a Thursday.
    static func weekday(ofNumber number: Int) -> Int {
        floorModulo(number + 4, 7) + 1
    }

    static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: return isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Months since January of year 0, so consecutive months differ by exactly 1.
    static func monthIndex(year: Int, month: Int) -> Int {
        year * 12 + month - 1
    }

    /// The year and month (1…12) of a month index.
    static func yearAndMonth(ofIndex index: Int) -> (year: Int, month: Int) {
        let year = floorDivide(index, 12)
        return (year, index - year * 12 + 1)
    }

    /// Division that rounds toward negative infinity (Swift's `/` rounds toward zero).
    static func floorDivide(_ value: Int, _ divisor: Int) -> Int {
        let quotient = value / divisor
        let hasRemainder = value % divisor != 0
        let signsDiffer = (value < 0) != (divisor < 0)
        return hasRemainder && signsDiffer ? quotient - 1 : quotient
    }

    /// The remainder of `floorDivide`, always in `0..<divisor` for a positive divisor.
    static func floorModulo(_ value: Int, _ divisor: Int) -> Int {
        value - floorDivide(value, divisor) * divisor
    }

    // MARK: - Series days

    /// Whether `rule`, for a series whose first occurrence is on `firstDay`, produces `day`. Ignores
    /// `excludedDates`. `day` must be a real day (see `CalendarDate.isValid`).
    static func isSeriesDay(_ day: CalendarDate, of rule: RecurrenceRule, firstDay: CalendarDate) -> Bool {
        let first = number(of: firstDay)
        let target = number(of: day)
        guard target >= first else { return false }
        if let until = rule.until, day > until { return false }
        switch rule.frequency {
        case .daily: return true
        case .weekly: return (target - first) % 7 == 0
        case .monthly: return day.day == firstDay.day
        }
    }

    /// Calls `body` with the day number of every day `rule` produces from day number `low` through
    /// `high` (inclusive), in order, until `body` returns false.
    ///
    /// Starts directly at the first candidate on or after `low` rather than walking from the series'
    /// first day. Days before `firstDay` and after `until` are never produced; monthly rules skip
    /// months without the day. `excludedDates` are not filtered here.
    static func forEachSeriesDay(
        of rule: RecurrenceRule,
        firstDay: CalendarDate,
        from low: Int,
        through high: Int,
        _ body: (Int) -> Bool
    ) {
        let first = number(of: firstDay)
        var last = high
        if let until = rule.until {
            last = min(last, number(of: until))
        }
        let start = max(low, first)
        guard start <= last else { return }
        switch rule.frequency {
        case .daily:
            for day in start...last {
                if !body(day) { return }
            }
        case .weekly:
            let firstCandidate = first + (start - first + 6) / 7 * 7
            for day in stride(from: firstCandidate, through: last, by: 7) {
                if !body(day) { return }
            }
        case .monthly:
            let dayOfMonth = firstDay.day
            let startDate = date(fromNumber: start)
            let lastDate = date(fromNumber: last)
            let lastIndex = monthIndex(year: lastDate.year, month: lastDate.month)
            var index = monthIndex(year: startDate.year, month: startDate.month)
            while index <= lastIndex {
                let (year, month) = yearAndMonth(ofIndex: index)
                if dayOfMonth <= daysInMonth(year: year, month: month) {
                    let day = number(of: CalendarDate(year: year, month: month, day: dayOfMonth))
                    if day >= start && day <= last && !body(day) { return }
                }
                index += 1
            }
        }
    }

    /// Whether a repeating event still has at least one date that isn't excluded. A rule without
    /// `until` always does; so does an event that doesn't repeat.
    static func seriesHasOccurrences(_ event: Event) -> Bool {
        guard let rule = event.recurrence, let until = rule.until else { return true }
        let firstDay = event.timing.startDate
        let first = number(of: firstDay)
        let last = number(of: until)
        var found = false
        forEachSeriesDay(of: rule, firstDay: firstDay, from: first, through: last) { day in
            if event.excludedDates.contains(date(fromNumber: day)) { return true }
            found = true
            return false
        }
        return found
    }
}
