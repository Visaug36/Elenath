import ElenathCore
import Foundation
import Testing

struct DayLayoutTests {
    private typealias Fixture = DatesFixture

    private let zone = DatesFixture.amsterdam
    private let tuesday = DatesFixture.day(2026, 10, 6)

    @Test func threeOverlappingEventsGetThreeColumns() {
        let first = occurrence("A", 9, 0, minutes: 60)
        let second = occurrence("B", 9, 30, minutes: 60)
        let third = occurrence("C", 9, 45, minutes: 75)
        let later = occurrence("D", 13, 0, minutes: 60)
        let items = DayLayout.layout([later, third, first, second], on: tuesday, timeZone: zone, minimumMinutes: 15)
        let titles = items.map { $0.occurrence.event.title }
        let columns = items.map { $0.column }
        let counts = items.map { $0.columnCount }
        #expect(titles == ["A", "B", "C", "D"])
        #expect(columns == [0, 1, 2, 0])
        #expect(counts == [3, 3, 3, 1])
    }

    @Test func groupNeedsOnlyAsManyColumnsAsOverlapAtOnce() {
        // A and C don't overlap, but both overlap B: one group, two columns, C reuses A's column.
        let first = occurrence("A", 9, 0, minutes: 60)
        let second = occurrence("B", 9, 30, minutes: 90)
        let third = occurrence("C", 10, 0, minutes: 90)
        let items = DayLayout.layout([first, second, third], on: tuesday, timeZone: zone, minimumMinutes: 15)
        let columns = items.map { $0.column }
        let counts = items.map { $0.columnCount }
        #expect(columns == [0, 1, 0])
        #expect(counts == [2, 2, 2])
    }

    @Test func backToBackEventsDoNotOverlap() {
        let first = occurrence("A", 9, 0, minutes: 60)
        let second = occurrence("B", 10, 0, minutes: 60)
        let items = DayLayout.layout([first, second], on: tuesday, timeZone: zone, minimumMinutes: 15)
        let columns = items.map { $0.column }
        let counts = items.map { $0.columnCount }
        #expect(columns == [0, 0])
        #expect(counts == [1, 1])
    }

    @Test func positionsAreWallClockMinutes() throws {
        let lecture = occurrence("Physics Lecture", 14, 0, minutes: 90)
        let items = DayLayout.layout([lecture], on: tuesday, timeZone: zone, minimumMinutes: 15)
        let item = try #require(items.first)
        #expect(item.startMinute == 14 * 60)
        #expect(item.endMinute == 15 * 60 + 30)
        #expect(!item.continuesBefore)
        #expect(!item.continuesAfter)
        #expect(item.column == 0)
        #expect(item.columnCount == 1)
    }

    @Test func shortEventsGetTheMinimumHeight() throws {
        let short = occurrence("Quick call", 10, 0, minutes: 5)
        let lastMinutes = occurrence("Late reminder", 23, 55, minutes: 5)
        let items = DayLayout.layout([short, lastMinutes], on: tuesday, timeZone: zone, minimumMinutes: 30)
        let first = try #require(items.first)
        let last = try #require(items.last)
        #expect(first.startMinute == 10 * 60)
        #expect(first.endMinute == 10 * 60 + 30)
        // Near midnight the block moves up rather than past the end of the day.
        #expect(last.startMinute == 24 * 60 - 30)
        #expect(last.endMinute == 24 * 60)
    }

    @Test func overlapIsJudgedOnTheDrawnBlocks() {
        // A lasts 5 minutes but is drawn 30 minutes tall, so B (10 minutes later) goes beside it.
        let first = occurrence("A", 10, 0, minutes: 5)
        let second = occurrence("B", 10, 10, minutes: 60)
        let items = DayLayout.layout([first, second], on: tuesday, timeZone: zone, minimumMinutes: 30)
        let columns = items.map { $0.column }
        #expect(columns == [0, 1])
    }

    @Test func eventCrossingMidnightIsSplitAcrossBothDays() throws {
        // 22:00 on Tuesday to 02:00 on Wednesday.
        let party = occurrence("Party", 22, 0, minutes: 4 * 60)
        let wednesday = tuesday.adding(days: 1)

        let first = try #require(DayLayout.layout([party], on: tuesday, timeZone: zone, minimumMinutes: 15).first)
        #expect(first.startMinute == 22 * 60)
        #expect(first.endMinute == 24 * 60)
        #expect(!first.continuesBefore)
        #expect(first.continuesAfter)

        let second = try #require(DayLayout.layout([party], on: wednesday, timeZone: zone, minimumMinutes: 15).first)
        #expect(second.startMinute == 0)
        #expect(second.endMinute == 2 * 60)
        #expect(second.continuesBefore)
        #expect(!second.continuesAfter)

        let thursday = tuesday.adding(days: 2)
        #expect(DayLayout.layout([party], on: thursday, timeZone: zone, minimumMinutes: 15).isEmpty)
    }

    @Test func eventEndingAtMidnightStaysOnItsDay() throws {
        let evening = occurrence("Evening", 23, 0, minutes: 60)
        let item = try #require(DayLayout.layout([evening], on: tuesday, timeZone: zone, minimumMinutes: 15).first)
        #expect(item.endMinute == 24 * 60)
        #expect(!item.continuesAfter)
        let wednesday = tuesday.adding(days: 1)
        #expect(DayLayout.layout([evening], on: wednesday, timeZone: zone, minimumMinutes: 15).isEmpty)
    }

    @Test func allDayAndOtherDaysAreLeftOut() {
        let allDay = Occurrence(
            event: Fixture.allDay("Essay due", from: tuesday, through: tuesday), date: tuesday,
            start: tuesday.start(in: zone), end: tuesday.end(in: zone))
        let monday = Fixture.instant(2026, 10, 5, 9, 0, in: zone)
        let otherDay = Self.makeOccurrence(of: Fixture.timed("Monday", start: monday, minutes: 60, in: zone))
        let items = DayLayout.layout([allDay, otherDay], on: tuesday, timeZone: zone, minimumMinutes: 15)
        #expect(items.isEmpty)
    }

    @Test func dayWhenClocksGoBackUsesWallClockMinutes() throws {
        // On Sunday 25 October 2026 Amsterdam's 03:00 becomes 02:00: 01:00 to 05:00 is five hours long.
        let sunday = Fixture.day(2026, 10, 25)
        let start = Fixture.instant(2026, 10, 25, 1, 0, in: zone)
        let night = Self.makeOccurrence(of: Fixture.timed("Night shift", start: start, minutes: 5 * 60, in: zone))
        let item = try #require(DayLayout.layout([night], on: sunday, timeZone: zone, minimumMinutes: 15).first)
        #expect(item.startMinute == 60)
        #expect(item.endMinute == 5 * 60)
    }

    @Test func dayWhenClocksGoForwardUsesWallClockMinutes() throws {
        // On Sunday 28 March 2027 Amsterdam's 02:00 becomes 03:00: 01:00 to 04:00 is two hours long.
        let sunday = Fixture.day(2027, 3, 28)
        let start = Fixture.instant(2027, 3, 28, 1, 0, in: zone)
        let night = Self.makeOccurrence(of: Fixture.timed("Night shift", start: start, minutes: 2 * 60, in: zone))
        let item = try #require(DayLayout.layout([night], on: sunday, timeZone: zone, minimumMinutes: 15).first)
        #expect(item.startMinute == 60)
        #expect(item.endMinute == 4 * 60)
        #expect(!item.continuesBefore)
        #expect(!item.continuesAfter)
    }

    @Test func eventLongerThanADayFillsTheMiddleDay() throws {
        // Monday 20:00 to Wednesday 08:00.
        let start = Fixture.instant(2026, 10, 5, 20, 0, in: zone)
        let trip = Self.makeOccurrence(of: Fixture.timed("Field trip", start: start, minutes: 36 * 60, in: zone))
        let item = try #require(DayLayout.layout([trip], on: tuesday, timeZone: zone, minimumMinutes: 15).first)
        #expect(item.startMinute == 0)
        #expect(item.endMinute == 24 * 60)
        #expect(item.continuesBefore)
        #expect(item.continuesAfter)
    }

    @Test func layoutIsTheSameInAnyTimeZoneForThatZonesDay() throws {
        // The same instant drawn on Tokyo's calendar: 14:00 in Amsterdam is 21:00 in Tokyo.
        let lecture = occurrence("Physics Lecture", 14, 0, minutes: 90)
        let items = DayLayout.layout([lecture], on: tuesday, timeZone: Fixture.tokyo, minimumMinutes: 15)
        let item = try #require(items.first)
        #expect(item.startMinute == 21 * 60)
        #expect(item.endMinute == 22 * 60 + 30)
    }

    // MARK: - Helpers

    /// A non-repeating occurrence on Tuesday 6 October 2026 at a wall-clock time in Amsterdam.
    private func occurrence(_ title: String, _ hour: Int, _ minute: Int, minutes: Int) -> Occurrence {
        let start = Fixture.instant(2026, 10, 6, hour, minute, in: zone)
        return Self.makeOccurrence(of: Fixture.timed(title, start: start, minutes: minutes, in: zone))
    }

    private static func makeOccurrence(of event: Event) -> Occurrence {
        guard case .timed(let start, let end, let timeZone) = event.timing else {
            fatalError("Expected a timed event")
        }
        return Occurrence(event: event, date: CalendarDate(start, in: timeZone), start: start, end: end)
    }
}
