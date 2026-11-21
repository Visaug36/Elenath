import ElenathCore
import Foundation
import Testing

struct CalendarMathTests {
    private typealias Fixture = DatesFixture

    private let sundayStart = CalendarMath(timeZone: DatesFixture.amsterdam, firstWeekday: 1)
    private let mondayStart = CalendarMath(timeZone: DatesFixture.amsterdam, firstWeekday: 2)
    private let saturdayStart = CalendarMath(timeZone: DatesFixture.amsterdam, firstWeekday: 7)

    // MARK: - Weeks

    @Test func weekStartingOnSunday() {
        let week = sundayStart.week(containing: Fixture.day(2026, 10, 6))
        let expected = (4...10).map { Fixture.day(2026, 10, $0) }
        let weekdays = week.map { $0.weekday }
        #expect(week == expected)
        #expect(weekdays == [1, 2, 3, 4, 5, 6, 7])
    }

    @Test func weekStartingOnMonday() {
        let week = mondayStart.week(containing: Fixture.day(2026, 10, 6))
        let expected = (5...11).map { Fixture.day(2026, 10, $0) }
        let weekdays = week.map { $0.weekday }
        #expect(week == expected)
        #expect(weekdays == [2, 3, 4, 5, 6, 7, 1])
    }

    @Test func weekStartingOnSaturday() {
        let week = saturdayStart.week(containing: Fixture.day(2026, 10, 6))
        let expected = (3...9).map { Fixture.day(2026, 10, $0) }
        let weekdays = week.map { $0.weekday }
        #expect(week == expected)
        #expect(weekdays == [7, 1, 2, 3, 4, 5, 6])
    }

    @Test func weekContainingItsFirstAndLastDay() {
        let monday = Fixture.day(2026, 10, 5)
        let sunday = Fixture.day(2026, 10, 11)
        #expect(mondayStart.week(containing: monday).first == monday)
        #expect(mondayStart.week(containing: sunday).first == monday)
        #expect(mondayStart.week(containing: sunday).last == sunday)
        #expect(sundayStart.week(containing: sunday).first == sunday)
    }

    @Test func weekAcrossTheYearEnd() {
        // 1 January 2027 is a Friday.
        let week = mondayStart.week(containing: Fixture.day(2027, 1, 1))
        #expect(week.first == Fixture.day(2026, 12, 28))
        #expect(week.last == Fixture.day(2027, 1, 3))
    }

    @Test func weekdayOrderFollowsTheFirstWeekday() {
        #expect(sundayStart.weekdayOrder() == [1, 2, 3, 4, 5, 6, 7])
        #expect(mondayStart.weekdayOrder() == [2, 3, 4, 5, 6, 7, 1])
        #expect(saturdayStart.weekdayOrder() == [7, 1, 2, 3, 4, 5, 6])
    }

    @Test func calendarIsGregorianWithTheSettings() {
        let calendar = mondayStart.calendar
        #expect(calendar.identifier == Calendar.Identifier.gregorian)
        #expect(calendar.firstWeekday == 2)
        #expect(calendar.timeZone == DatesFixture.amsterdam)
    }

    @Test func firstWeekdayOutsideTheRangeWraps() {
        #expect(CalendarMath(timeZone: Fixture.utc, firstWeekday: 8).firstWeekday == 1)
        #expect(CalendarMath(timeZone: Fixture.utc, firstWeekday: 0).firstWeekday == 7)
    }

    // MARK: - Month grids

    @Test func februaryNonLeapYearStartingMidWeek() {
        // 1 February 2026 is a Sunday: the last column of a Monday-first grid.
        let grid = mondayStart.monthGrid(year: 2026, month: 2)
        #expect(grid.count == 35)
        #expect(grid.first == Fixture.day(2026, 1, 26))
        #expect(grid.last == Fixture.day(2026, 3, 1))
    }

    @Test func februaryThatFitsInFourWeeksGetsAFifth() {
        // With Sunday first, February 2026 is exactly four rows; the grid still has five.
        let grid = sundayStart.monthGrid(year: 2026, month: 2)
        #expect(grid.count == 35)
        #expect(grid.first == Fixture.day(2026, 2, 1))
        #expect(grid[27] == Fixture.day(2026, 2, 28))
        #expect(grid.last == Fixture.day(2026, 3, 7))
    }

    @Test func februaryLeapYear() {
        // 1 February 2028 is a Tuesday, and 2028 is a leap year.
        let monday = mondayStart.monthGrid(year: 2028, month: 2)
        #expect(monday.count == 35)
        #expect(monday.first == Fixture.day(2028, 1, 31))
        #expect(monday.contains(Fixture.day(2028, 2, 29)))
        #expect(monday.last == Fixture.day(2028, 3, 5))

        let sunday = sundayStart.monthGrid(year: 2028, month: 2)
        #expect(sunday.count == 35)
        #expect(sunday.first == Fixture.day(2028, 1, 30))
        #expect(sunday.last == Fixture.day(2028, 3, 4))
    }

    @Test func monthStartingOnTheFirstWeekday() {
        // 1 June 2026 is a Monday.
        let grid = mondayStart.monthGrid(year: 2026, month: 6)
        #expect(grid.count == 35)
        #expect(grid.first == Fixture.day(2026, 6, 1))
        #expect(grid.last == Fixture.day(2026, 7, 5))
    }

    @Test func monthNeedingSixWeeks() {
        // 1 August 2026 is a Saturday, and August has 31 days.
        let grid = mondayStart.monthGrid(year: 2026, month: 8)
        #expect(grid.count == 42)
        #expect(grid.first == Fixture.day(2026, 7, 27))
        #expect(grid.last == Fixture.day(2026, 9, 6))
    }

    @Test func octoberWithEachFirstWeekday() {
        let monday = mondayStart.monthGrid(year: 2026, month: 10)
        #expect(monday.count == 35)
        #expect(monday.first == Fixture.day(2026, 9, 28))
        #expect(monday.last == Fixture.day(2026, 11, 1))

        let sunday = sundayStart.monthGrid(year: 2026, month: 10)
        #expect(sunday.first == Fixture.day(2026, 9, 27))
        #expect(sunday.last == Fixture.day(2026, 10, 31))

        // 1 May 2026 is a Friday: six rows when weeks start on Saturday.
        let saturday = saturdayStart.monthGrid(year: 2026, month: 5)
        #expect(saturday.count == 42)
        #expect(saturday.first == Fixture.day(2026, 4, 25))
        #expect(saturday.last == Fixture.day(2026, 6, 5))
    }

    @Test func monthOutsideOneToTwelveRollsOver() {
        #expect(mondayStart.monthGrid(year: 2026, month: 13) == mondayStart.monthGrid(year: 2027, month: 1))
        #expect(mondayStart.monthGrid(year: 2026, month: 0) == mondayStart.monthGrid(year: 2025, month: 12))
    }

    /// Checks every grid from 2024 through 2030 for every first weekday against `Calendar` (through
    /// `CalendarDate.adding(days:)` and `Calendar.range(of:in:for:)`).
    @Test func everyGridIsWholeConsecutiveWeeksCoveringTheMonth() throws {
        let utcCalendar = Fixture.calendar(Fixture.utc)
        for firstWeekday in 1...7 {
            let math = CalendarMath(timeZone: Fixture.utc, firstWeekday: firstWeekday)
            for year in 2024...2030 {
                for month in 1...12 {
                    let grid = math.monthGrid(year: year, month: month)
                    let first = Fixture.day(year, month, 1)
                    let days = try #require(utcCalendar.range(of: .day, in: .month, for: first.start(in: Fixture.utc)))
                    let last = Fixture.day(year, month, days.count)
                    #expect(grid.count == 35 || grid.count == 42)
                    #expect(grid.first?.weekday == firstWeekday)
                    #expect(grid.prefix(7).contains(first))
                    #expect(grid.contains(last))
                    // A sixth row only when the month needs it.
                    #expect(grid.count == 35 || grid.suffix(7).contains(last))
                    let gridStart = try #require(grid.first)
                    let consecutive = (0..<grid.count).map { gridStart.adding(days: $0) }
                    #expect(grid == consecutive)
                }
            }
        }
    }

    // MARK: - Intervals and visible days

    @Test func intervalCoversWholeDaysInTheTimeZone() {
        let interval = mondayStart.interval(from: Fixture.day(2026, 10, 5), through: Fixture.day(2026, 10, 11))
        #expect(interval.start == Fixture.instant(2026, 10, 5, in: Fixture.amsterdam))
        #expect(interval.end == Fixture.instant(2026, 10, 12, in: Fixture.amsterdam))
        #expect(interval.duration == TimeInterval(7 * 24 * 60 * 60))
    }

    @Test func intervalAcrossTheClocksGoingBackIsAnHourLonger() {
        // Amsterdam goes from CEST to CET on Sunday 25 October 2026.
        let interval = mondayStart.interval(from: Fixture.day(2026, 10, 19), through: Fixture.day(2026, 10, 25))
        #expect(interval.duration == TimeInterval((7 * 24 + 1) * 60 * 60))
    }

    @Test func intervalAcceptsTheDaysInEitherOrder() {
        let forward = mondayStart.interval(from: Fixture.day(2026, 10, 5), through: Fixture.day(2026, 10, 6))
        let backward = mondayStart.interval(from: Fixture.day(2026, 10, 6), through: Fixture.day(2026, 10, 5))
        #expect(forward == backward)
    }

    @Test func visibleDaysForEachSpan() {
        let date = Fixture.day(2026, 10, 6)
        #expect(mondayStart.visibleDays(for: .day, around: date) == [date])
        #expect(mondayStart.visibleDays(for: .week, around: date) == mondayStart.week(containing: date))
        #expect(mondayStart.visibleDays(for: .month, around: date) == mondayStart.monthGrid(year: 2026, month: 10))
    }

    // MARK: - Stepping

    @Test func stepByDaysAcrossMonthAndYearEnds() {
        #expect(mondayStart.step(Fixture.day(2026, 10, 31), by: .day, count: 1) == Fixture.day(2026, 11, 1))
        #expect(mondayStart.step(Fixture.day(2026, 12, 31), by: .day, count: 1) == Fixture.day(2027, 1, 1))
        #expect(mondayStart.step(Fixture.day(2028, 2, 28), by: .day, count: 1) == Fixture.day(2028, 2, 29))
        #expect(mondayStart.step(Fixture.day(2026, 3, 1), by: .day, count: -1) == Fixture.day(2026, 2, 28))
        #expect(mondayStart.step(Fixture.day(2026, 10, 6), by: .day, count: 0) == Fixture.day(2026, 10, 6))
    }

    @Test func stepByWeeks() {
        #expect(mondayStart.step(Fixture.day(2026, 10, 6), by: .week, count: 1) == Fixture.day(2026, 10, 13))
        #expect(mondayStart.step(Fixture.day(2026, 10, 6), by: .week, count: -1) == Fixture.day(2026, 9, 29))
        #expect(mondayStart.step(Fixture.day(2026, 12, 29), by: .week, count: 1) == Fixture.day(2027, 1, 5))
    }

    @Test func stepByMonthsClampsToTheMonthEnd() {
        #expect(mondayStart.step(Fixture.day(2026, 1, 31), by: .month, count: 1) == Fixture.day(2026, 2, 28))
        #expect(mondayStart.step(Fixture.day(2028, 1, 31), by: .month, count: 1) == Fixture.day(2028, 2, 29))
        #expect(mondayStart.step(Fixture.day(2026, 3, 31), by: .month, count: -1) == Fixture.day(2026, 2, 28))
        #expect(mondayStart.step(Fixture.day(2026, 5, 31), by: .month, count: 1) == Fixture.day(2026, 6, 30))
        #expect(mondayStart.step(Fixture.day(2026, 1, 31), by: .month, count: 2) == Fixture.day(2026, 3, 31))
    }

    @Test func stepByMonthsAcrossYears() {
        #expect(mondayStart.step(Fixture.day(2026, 12, 15), by: .month, count: 1) == Fixture.day(2027, 1, 15))
        #expect(mondayStart.step(Fixture.day(2027, 1, 15), by: .month, count: -1) == Fixture.day(2026, 12, 15))
        #expect(mondayStart.step(Fixture.day(2026, 10, 6), by: .month, count: 12) == Fixture.day(2027, 10, 6))
        #expect(mondayStart.step(Fixture.day(2026, 10, 6), by: .month, count: -22) == Fixture.day(2024, 12, 6))
        #expect(mondayStart.step(Fixture.day(2028, 2, 29), by: .month, count: 12) == Fixture.day(2029, 2, 28))
    }

    // MARK: - Relative days

    @Test func relativeDays() {
        let today = Fixture.day(2026, 10, 6)
        let math = mondayStart
        #expect(math.relativeDay(today, today: today) == RelativeDay.today)
        #expect(math.relativeDay(Fixture.day(2026, 10, 7), today: today) == RelativeDay.tomorrow)
        #expect(math.relativeDay(Fixture.day(2026, 10, 5), today: today) == RelativeDay.yesterday)
        // Thursday 8 October and Monday 12 October.
        #expect(math.relativeDay(Fixture.day(2026, 10, 8), today: today) == RelativeDay.laterThisWeek(weekday: 5))
        #expect(math.relativeDay(Fixture.day(2026, 10, 12), today: today) == RelativeDay.laterThisWeek(weekday: 2))
        let weekLater = Fixture.day(2026, 10, 13)
        let twoDaysAgo = Fixture.day(2026, 10, 4)
        #expect(math.relativeDay(weekLater, today: today) == RelativeDay.other(weekLater))
        #expect(math.relativeDay(twoDaysAgo, today: today) == RelativeDay.other(twoDaysAgo))
    }

    @Test func relativeDaysAcrossMonthAndYearEnds() {
        // 1 November 2026 is a Sunday; 1 January 2027 a Friday.
        let math = mondayStart
        let october = Fixture.day(2026, 10, 30)
        #expect(math.relativeDay(Fixture.day(2026, 11, 1), today: october) == RelativeDay.laterThisWeek(weekday: 1))
        let newYearsEve = Fixture.day(2026, 12, 31)
        #expect(math.relativeDay(Fixture.day(2027, 1, 1), today: newYearsEve) == RelativeDay.tomorrow)
        #expect(math.relativeDay(newYearsEve, today: Fixture.day(2027, 1, 1)) == RelativeDay.yesterday)
    }

    // MARK: - Today and minutes

    @Test func todayDependsOnTheTimeZone() {
        // 23:30 UTC on 6 October is already 7 October in Tokyo, and still 6 October in Los Angeles.
        let instant = Fixture.instant(2026, 10, 6, 23, 30, in: Fixture.utc)
        let tokyo = CalendarMath(timeZone: Fixture.tokyo, firstWeekday: 2)
        let losAngeles = CalendarMath(timeZone: Fixture.losAngeles, firstWeekday: 1)
        let utc = CalendarMath(timeZone: Fixture.utc, firstWeekday: 1)
        #expect(tokyo.today(now: instant) == Fixture.day(2026, 10, 7))
        #expect(losAngeles.today(now: instant) == Fixture.day(2026, 10, 6))
        #expect(utc.today(now: instant) == Fixture.day(2026, 10, 6))
    }

    @Test func minutesOfDayUsesTheWallClock() {
        #expect(mondayStart.minutesOfDay(Fixture.now) == 13 * 60 + 50)
        #expect(CalendarMath(timeZone: Fixture.newYork, firstWeekday: 1).minutesOfDay(Fixture.now) == 7 * 60 + 50)
        let midnight = Fixture.instant(2026, 10, 7, in: Fixture.amsterdam)
        #expect(mondayStart.minutesOfDay(midnight) == 0)
    }
}
