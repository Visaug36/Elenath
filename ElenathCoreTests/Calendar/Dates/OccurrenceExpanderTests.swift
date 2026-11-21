import ElenathCore
import Foundation
import Testing

struct OccurrenceExpanderTests {
    private typealias Fixture = DatesFixture

    private let amsterdam = OccurrenceExpander(displayTimeZone: DatesFixture.amsterdam)

    // MARK: - Non-repeating events

    @Test func singleEventInsideAndOutsideTheInterval() {
        let start = Fixture.instant(2026, 10, 6, 14, 0, in: Fixture.amsterdam)
        let event = Fixture.timed("Physics Lecture", start: start, minutes: 90, in: Fixture.amsterdam)
        let week = Fixture.days(Fixture.day(2026, 10, 5), Fixture.day(2026, 10, 11), in: Fixture.amsterdam)
        let found = amsterdam.occurrences(of: event, in: week)
        #expect(found.count == 1)
        #expect(found.first?.date == Fixture.day(2026, 10, 6))
        #expect(found.first?.start == start)
        #expect(found.first?.end == start.addingTimeInterval(90 * 60))

        let nextWeek = Fixture.days(Fixture.day(2026, 10, 12), Fixture.day(2026, 10, 18), in: Fixture.amsterdam)
        #expect(amsterdam.occurrences(of: event, in: nextWeek).isEmpty)
    }

    @Test func touchingTheIntervalIsNotOverlapping() {
        let start = Fixture.instant(2026, 10, 6, 14, 0, in: Fixture.amsterdam)
        let event = Fixture.timed("Lecture", start: start, minutes: 60, in: Fixture.amsterdam)
        let endsAtStart = DateInterval(start: start.addingTimeInterval(60 * 60), duration: 60 * 60)
        let startsAtEnd = DateInterval(start: start.addingTimeInterval(-60 * 60), duration: 60 * 60)
        let inside = DateInterval(start: start.addingTimeInterval(30 * 60), duration: 60)
        #expect(amsterdam.occurrences(of: event, in: endsAtStart).isEmpty)
        #expect(amsterdam.occurrences(of: event, in: startsAtEnd).isEmpty)
        #expect(amsterdam.occurrences(of: event, in: inside).count == 1)
    }

    @Test func eventsAreSortedByStartWithAllDayFirst() {
        let zone = Fixture.amsterdam
        let day = Fixture.day(2026, 10, 6)
        let late = Fixture.timed("Late", start: Fixture.instant(2026, 10, 6, 20, 0, in: zone), minutes: 30, in: zone)
        let early = Fixture.timed("Early", start: Fixture.instant(2026, 10, 6, 8, 0, in: zone), minutes: 30, in: zone)
        let atMidnight = Fixture.timed("Midnight", start: day.start(in: zone), minutes: 30, in: zone)
        let allDay = Fixture.allDay("Essay due", from: day, through: day)
        let events = [late, early, atMidnight, allDay]
        let found = amsterdam.occurrences(of: events, in: Fixture.days(day, day, in: zone))
        let titles = found.map { $0.event.title }
        #expect(titles == ["Essay due", "Midnight", "Early", "Late"])
    }

    // MARK: - Repeating timed events and DST

    @Test func weeklyLectureKeepsItsWallClockTimeWhenClocksGoBack() throws {
        // Amsterdam goes from CEST (UTC+2) to CET (UTC+1) on Sunday 25 October 2026.
        let start = Fixture.instant(2026, 10, 20, 14, 0, in: Fixture.amsterdam)
        let rule = RecurrenceRule(frequency: .weekly)
        let event = Fixture.timed("Physics Lecture", start: start, minutes: 90, in: Fixture.amsterdam, recurrence: rule)
        let range = Fixture.days(Fixture.day(2026, 10, 19), Fixture.day(2026, 11, 1), in: Fixture.amsterdam)
        let found = amsterdam.occurrences(of: event, in: range)
        let dates = found.map { $0.date }
        #expect(dates == [Fixture.day(2026, 10, 20), Fixture.day(2026, 10, 27)])
        for occurrence in found {
            #expect(Fixture.wallClock(occurrence.start, in: Fixture.amsterdam) == "14:00")
            #expect(Fixture.wallClock(occurrence.end, in: Fixture.amsterdam) == "15:30")
            #expect(occurrence.end.timeIntervalSince(occurrence.start) == TimeInterval(90 * 60))
        }
        let before = try #require(found.first)
        let after = try #require(found.last)
        #expect(Fixture.wallClock(before.start, in: Fixture.utc) == "12:00")
        #expect(Fixture.wallClock(after.start, in: Fixture.utc) == "13:00")
    }

    @Test func weeklyLectureKeepsItsWallClockTimeWhenClocksGoForward() throws {
        // Amsterdam goes from CET to CEST on Sunday 28 March 2027; seen from Tokyo the time moves.
        let start = Fixture.instant(2026, 10, 20, 14, 0, in: Fixture.amsterdam)
        let rule = RecurrenceRule(frequency: .weekly)
        let event = Fixture.timed("Physics Lecture", start: start, minutes: 90, in: Fixture.amsterdam, recurrence: rule)
        let range = Fixture.days(Fixture.day(2027, 3, 22), Fixture.day(2027, 4, 4), in: Fixture.amsterdam)
        let found = OccurrenceExpander(displayTimeZone: Fixture.tokyo).occurrences(of: event, in: range)
        let dates = found.map { $0.date }
        #expect(dates == [Fixture.day(2027, 3, 23), Fixture.day(2027, 3, 30)])
        for occurrence in found {
            #expect(Fixture.wallClock(occurrence.start, in: Fixture.amsterdam) == "14:00")
        }
        let before = try #require(found.first)
        let after = try #require(found.last)
        #expect(Fixture.wallClock(before.start, in: Fixture.tokyo) == "22:00")
        #expect(Fixture.wallClock(after.start, in: Fixture.tokyo) == "21:00")
    }

    @Test func startTimeInTheSpringForwardGapMovesForward() throws {
        // New York skips 02:00–03:00 on Sunday 14 March 2027.
        let start = Fixture.instant(2027, 3, 12, 2, 30, in: Fixture.newYork)
        let rule = RecurrenceRule(frequency: .daily)
        let event = Fixture.timed("Night lab", start: start, minutes: 30, in: Fixture.newYork, recurrence: rule)
        let range = Fixture.days(Fixture.day(2027, 3, 13), Fixture.day(2027, 3, 15), in: Fixture.newYork)
        let found = OccurrenceExpander(displayTimeZone: Fixture.newYork).occurrences(of: event, in: range)
        let dates = found.map { $0.date }
        let times = found.map { Fixture.wallClock($0.start, in: Fixture.newYork) }
        #expect(dates == [Fixture.day(2027, 3, 13), Fixture.day(2027, 3, 14), Fixture.day(2027, 3, 15)])
        #expect(times == ["02:30", "03:30", "02:30"])
        for occurrence in found {
            #expect(occurrence.end.timeIntervalSince(occurrence.start) == TimeInterval(30 * 60))
        }

        let gapDay = try #require(amsterdam.occurrence(of: event, on: Fixture.day(2027, 3, 14)))
        #expect(Fixture.wallClock(gapDay.start, in: Fixture.newYork) == "03:30")
        #expect(gapDay.start == Fixture.instant(2027, 3, 14, 7, 30, in: Fixture.utc))
    }

    @Test func seriesThatStartedYearsAgoJumpsToTheRange() throws {
        let start = Fixture.instant(2020, 1, 7, 10, 15, in: Fixture.amsterdam)
        let rule = RecurrenceRule(frequency: .weekly)
        let event = Fixture.timed("Seminar", start: start, minutes: 45, in: Fixture.amsterdam, recurrence: rule)
        let week = Fixture.days(Fixture.day(2026, 10, 5), Fixture.day(2026, 10, 11), in: Fixture.amsterdam)
        let found = amsterdam.occurrences(of: event, in: week)
        let occurrence = try #require(found.first)
        #expect(found.count == 1)
        #expect(occurrence.date == Fixture.day(2026, 10, 6))
        #expect(occurrence.start == Fixture.instant(2026, 10, 6, 10, 15, in: Fixture.amsterdam))
    }

    @Test func firstOccurrenceIsExactlyTheEventStart() throws {
        let start = Fixture.instant(2026, 10, 6, 9, 0, in: Fixture.tokyo)
        let event = Fixture.timed(
            "Standup", start: start, minutes: 15, in: Fixture.tokyo, recurrence: RecurrenceRule(frequency: .daily))
        let first = try #require(amsterdam.occurrence(of: event, on: Fixture.day(2026, 10, 6)))
        #expect(first.start == start)
        #expect(first.end == start.addingTimeInterval(15 * 60))
        #expect(amsterdam.occurrence(of: event, on: Fixture.day(2026, 10, 5)) == nil)
    }

    @Test func occurrenceSpanningSeveralDaysIsFoundFromALaterDay() {
        // Friday 18:00 to Monday 09:00, every week.
        let start = Fixture.instant(2026, 10, 2, 18, 0, in: Fixture.amsterdam)
        let rule = RecurrenceRule(frequency: .weekly)
        let event = Fixture.timed("Field trip", start: start, minutes: 63 * 60, in: Fixture.amsterdam, recurrence: rule)
        let monday = Fixture.days(Fixture.day(2026, 10, 12), Fixture.day(2026, 10, 12), in: Fixture.amsterdam)
        let found = amsterdam.occurrences(of: event, in: monday)
        let dates = found.map { $0.date }
        #expect(dates == [Fixture.day(2026, 10, 9)])
    }

    @Test func timedEventsAreDatedInTheirOwnTimeZone() throws {
        // 23:30 in Tokyo is still the afternoon before in Amsterdam; the occurrence keeps Tokyo's date.
        let start = Fixture.instant(2026, 10, 6, 23, 30, in: Fixture.tokyo)
        let event = Fixture.timed("Call", start: start, minutes: 30, in: Fixture.tokyo)
        let occurrence = try #require(amsterdam.occurrence(of: event, on: Fixture.day(2026, 10, 6)))
        #expect(occurrence.start == start)
        #expect(amsterdam.occurrence(of: event, on: Fixture.day(2026, 10, 7)) == nil)
    }

    // MARK: - Monthly rules, until and exclusions

    @Test func monthlyOnThe31stSkipsShorterMonths() {
        let start = Fixture.instant(2026, 1, 31, 9, 0, in: Fixture.utc)
        let rule = RecurrenceRule(frequency: .monthly)
        let event = Fixture.timed("Rent", start: start, minutes: 30, in: Fixture.utc, recurrence: rule)
        let year = Fixture.days(Fixture.day(2026, 1, 1), Fixture.day(2026, 12, 31), in: Fixture.utc)
        let found = OccurrenceExpander(displayTimeZone: Fixture.utc).occurrences(of: event, in: year)
        let dates = found.map { $0.date }
        let expected = [1, 3, 5, 7, 8, 10, 12].map { Fixture.day(2026, $0, 31) }
        #expect(dates == expected)
        for occurrence in found {
            #expect(Fixture.wallClock(occurrence.start, in: Fixture.utc) == "09:00")
        }
        #expect(amsterdam.occurrence(of: event, on: Fixture.day(2026, 4, 30)) == nil)
        #expect(amsterdam.occurrence(of: event, on: Fixture.day(2026, 2, 28)) == nil)
    }

    @Test func monthlyOnThe29thSkipsFebruaryOnlyInNonLeapYears() {
        let start = Fixture.instant(2026, 1, 29, 16, 0, in: Fixture.amsterdam)
        let rule = RecurrenceRule(frequency: .monthly)
        let event = Fixture.timed("Book club", start: start, minutes: 60, in: Fixture.amsterdam, recurrence: rule)
        let february2026 = Fixture.days(Fixture.day(2026, 2, 1), Fixture.day(2026, 2, 28), in: Fixture.amsterdam)
        let february2027 = Fixture.days(Fixture.day(2027, 2, 1), Fixture.day(2027, 2, 28), in: Fixture.amsterdam)
        let winter2028 = Fixture.days(Fixture.day(2028, 1, 1), Fixture.day(2028, 3, 31), in: Fixture.amsterdam)
        #expect(amsterdam.occurrences(of: event, in: february2026).isEmpty)
        #expect(amsterdam.occurrences(of: event, in: february2027).isEmpty)
        let dates = amsterdam.occurrences(of: event, in: winter2028).map { $0.date }
        #expect(dates == [Fixture.day(2028, 1, 29), Fixture.day(2028, 2, 29), Fixture.day(2028, 3, 29)])
    }

    @Test func untilIsInclusive() {
        let start = Fixture.instant(2026, 10, 5, 8, 0, in: Fixture.amsterdam)
        let daily = Fixture.timed(
            "Exam week", start: start, minutes: 60, in: Fixture.amsterdam,
            recurrence: RecurrenceRule(frequency: .daily, until: Fixture.day(2026, 10, 9)))
        let october = Fixture.days(Fixture.day(2026, 10, 1), Fixture.day(2026, 10, 31), in: Fixture.amsterdam)
        let dailyDates = amsterdam.occurrences(of: daily, in: october).map { $0.date }
        #expect(dailyDates == Fixture.octoberDays(Array(5...9)))

        let weekly = Fixture.timed(
            "Tutorial", start: start.addingTimeInterval(24 * 60 * 60), minutes: 60, in: Fixture.amsterdam,
            recurrence: RecurrenceRule(frequency: .weekly, until: Fixture.day(2026, 10, 20)))
        let weeklyDates = amsterdam.occurrences(of: weekly, in: october).map { $0.date }
        #expect(weeklyDates == Fixture.octoberDays([6, 13, 20]))
        #expect(amsterdam.occurrence(of: weekly, on: Fixture.day(2026, 10, 20)) != nil)
        #expect(amsterdam.occurrence(of: weekly, on: Fixture.day(2026, 10, 27)) == nil)
    }

    @Test func excludedDatesAreSkipped() {
        let start = Fixture.instant(2026, 10, 6, 14, 0, in: Fixture.amsterdam)
        let event = Fixture.timed(
            "Physics Lecture", start: start, minutes: 90, in: Fixture.amsterdam,
            recurrence: RecurrenceRule(frequency: .weekly), excludedDates: [Fixture.day(2026, 10, 13)])
        let october = Fixture.days(Fixture.day(2026, 10, 1), Fixture.day(2026, 10, 31), in: Fixture.amsterdam)
        let dates = amsterdam.occurrences(of: event, in: october).map { $0.date }
        #expect(dates == Fixture.octoberDays([6, 20, 27]))
        #expect(amsterdam.occurrence(of: event, on: Fixture.day(2026, 10, 13)) == nil)
        #expect(amsterdam.occurrence(of: event, on: Fixture.day(2026, 10, 20)) != nil)
    }

    @Test func occurrenceOnADayTheRuleDoesNotProduce() {
        let start = Fixture.instant(2026, 10, 6, 14, 0, in: Fixture.amsterdam)
        let weekly = Fixture.timed(
            "Lecture", start: start, minutes: 90, in: Fixture.amsterdam, recurrence: RecurrenceRule(frequency: .weekly))
        #expect(amsterdam.occurrence(of: weekly, on: Fixture.day(2026, 10, 7)) == nil)
        #expect(amsterdam.occurrence(of: weekly, on: Fixture.day(2026, 9, 29)) == nil)
        #expect(amsterdam.occurrence(of: weekly, on: Fixture.day(2026, 2, 30)) == nil)
        let single = Fixture.timed("Once", start: start, minutes: 90, in: Fixture.amsterdam)
        #expect(amsterdam.occurrence(of: single, on: Fixture.day(2026, 10, 6)) != nil)
        #expect(amsterdam.occurrence(of: single, on: Fixture.day(2026, 10, 13)) == nil)
    }

    // MARK: - All-day events

    @Test func allDayEventsKeepTheirDatesInEveryTimeZone() throws {
        let day = Fixture.day(2026, 10, 6)
        let event = Fixture.allDay("Mara's birthday", from: day, through: day)
        for zone in [Fixture.tokyo, Fixture.losAngeles, Fixture.amsterdam, Fixture.utc] {
            let expander = OccurrenceExpander(displayTimeZone: zone)
            let week = Fixture.days(Fixture.day(2026, 10, 5), Fixture.day(2026, 10, 11), in: zone)
            let found = expander.occurrences(of: event, in: week)
            let occurrence = try #require(found.first)
            #expect(found.count == 1)
            #expect(occurrence.date == day)
            #expect(occurrence.start == day.start(in: zone))
            #expect(occurrence.end == day.end(in: zone))
            #expect(CalendarDate(occurrence.start, in: zone) == day)
            #expect(expander.occurrences(of: event, in: Fixture.days(day, day, in: zone)).count == 1)
            let nextDay = day.adding(days: 1)
            #expect(expander.occurrences(of: event, in: Fixture.days(nextDay, nextDay, in: zone)).isEmpty)
        }
    }

    @Test func repeatingAllDayEventsKeepTheirDatesInEveryTimeZone() {
        // Every Friday from 9 October 2026.
        let friday = Fixture.day(2026, 10, 9)
        let weekly = RecurrenceRule(frequency: .weekly)
        let event = Fixture.allDay("Essay due", from: friday, through: friday, recurrence: weekly)
        for zone in [Fixture.tokyo, Fixture.losAngeles] {
            let expander = OccurrenceExpander(displayTimeZone: zone)
            let october = Fixture.days(Fixture.day(2026, 10, 1), Fixture.day(2026, 10, 31), in: zone)
            let found = expander.occurrences(of: event, in: october)
            let dates = found.map { $0.date }
            let shownDays = found.map { CalendarDate($0.start, in: zone) }
            #expect(dates == Fixture.octoberDays([9, 16, 23, 30]))
            #expect(shownDays == dates)
        }
    }

    @Test func multiDayAllDayEvent() throws {
        let event = Fixture.allDay("Conference", from: Fixture.day(2026, 10, 6), through: Fixture.day(2026, 10, 8))
        let occurrence = try #require(amsterdam.occurrence(of: event, on: Fixture.day(2026, 10, 6)))
        #expect(occurrence.start == Fixture.day(2026, 10, 6).start(in: Fixture.amsterdam))
        #expect(occurrence.end == Fixture.day(2026, 10, 8).end(in: Fixture.amsterdam))
        for dayOfMonth in 5...9 {
            let day = Fixture.day(2026, 10, dayOfMonth)
            let found = amsterdam.occurrences(of: event, in: Fixture.days(day, day, in: Fixture.amsterdam))
            let expectedCount = (6...8).contains(dayOfMonth) ? 1 : 0
            #expect(found.count == expectedCount)
        }
        #expect(amsterdam.occurrence(of: event, on: Fixture.day(2026, 10, 7)) == nil)
    }

    @Test func repeatingMultiDayAllDayEventReachingIntoTheRange() {
        // Saturday to Monday, every week from 3 October 2026.
        let event = Fixture.allDay(
            "Weekend away", from: Fixture.day(2026, 10, 3), through: Fixture.day(2026, 10, 5),
            recurrence: RecurrenceRule(frequency: .weekly))
        let week = Fixture.days(Fixture.day(2026, 10, 5), Fixture.day(2026, 10, 11), in: Fixture.amsterdam)
        let dates = amsterdam.occurrences(of: event, in: week).map { $0.date }
        #expect(dates == [Fixture.day(2026, 10, 3), Fixture.day(2026, 10, 10)])
    }

    // MARK: - Upcoming

    @Test func upcomingListsTheNextOccurrencesInOrder() {
        // Tuesday 6 October 2026, 13:50 in Amsterdam.
        let now = Fixture.now
        let zone = Fixture.amsterdam
        let later = Self.hour("Later today", Fixture.instant(2026, 10, 6, 17, 0, in: zone))
        let earlier = Self.hour("Yesterday", Fixture.instant(2026, 10, 5, 9, 0, in: zone))
        let running = Self.hour("Running", Fixture.instant(2026, 10, 6, 13, 0, in: zone))
        let tomorrow = Self.hour("Tomorrow", Fixture.instant(2026, 10, 7, 9, 0, in: zone))
        let farAway = Self.hour("Far away", Fixture.instant(2027, 1, 4, 9, 0, in: zone))
        // Thursdays at 10:00 since 3 September.
        let lecture = Fixture.timed(
            "Lecture", start: Fixture.instant(2026, 9, 3, 10, 0, in: zone), minutes: 90, in: zone,
            recurrence: RecurrenceRule(frequency: .weekly))
        let events = [farAway, lecture, tomorrow, running, earlier, later]

        let firstThree = amsterdam.upcoming(events, after: now, limit: 3, horizonDays: 14)
        let firstTitles = firstThree.map { $0.event.title }
        #expect(firstTitles == ["Later today", "Tomorrow", "Lecture"])
        #expect(firstThree.last?.date == Fixture.day(2026, 10, 8))

        let all = amsterdam.upcoming(events, after: now, limit: 10, horizonDays: 14)
        let titles = all.map { $0.event.title }
        let allStartLater = all.allSatisfy { $0.start >= now }
        #expect(titles == ["Later today", "Tomorrow", "Lecture", "Lecture"])
        #expect(allStartLater)

        #expect(amsterdam.upcoming(events, after: now, limit: 0, horizonDays: 14).isEmpty)
        #expect(amsterdam.upcoming(events, after: now, limit: 5, horizonDays: 0).isEmpty)
        let year = amsterdam.upcoming(events, after: now, limit: 100, horizonDays: 366)
        let yearTitles = year.map { $0.event.title }
        #expect(yearTitles.contains("Far away"))
    }

    @Test func upcomingStopsAtTheLimitForFrequentSeries() {
        let zone = Fixture.amsterdam
        let daily = Fixture.timed(
            "Daily", start: Fixture.instant(2026, 1, 1, 7, 0, in: zone), minutes: 15, in: zone,
            recurrence: RecurrenceRule(frequency: .daily))
        let found = amsterdam.upcoming([daily], after: Fixture.now, limit: 5, horizonDays: 365)
        let dates = found.map { $0.date }
        #expect(dates == Fixture.octoberDays(Array(7...11)))
    }

    // MARK: - 5,000 events

    /// Expands one week of 5,000 generated events (500 repeating) and compares the result with a
    /// slow reference that walks every series from its first day.
    @Test func fiveThousandEventsMatchTheReferenceExpansion() {
        let events = Self.generatedEvents(count: 5_000)
        let repeatingCount = events.filter { $0.repeats }.count
        #expect(repeatingCount == 500)
        // The week of 19–25 October 2026, when Amsterdam's clocks go back.
        let week = Fixture.days(Fixture.day(2026, 10, 19), Fixture.day(2026, 10, 25), in: Fixture.amsterdam)
        let found = amsterdam.occurrences(of: events, in: week)
        var reference: [Occurrence] = []
        for event in events {
            reference += Self.referenceOccurrences(of: event, in: week, displayTimeZone: Fixture.amsterdam)
        }
        let isSorted = zip(found, found.dropFirst()).allSatisfy { $0.start <= $1.start }
        let repeatingFound = found.filter { $0.event.repeats }.count
        let allDayFound = found.filter { $0.isAllDay }.count
        #expect(found.count == reference.count)
        #expect(Set(found) == Set(reference))
        #expect(isSorted)
        #expect(repeatingFound > 0)
        #expect(allDayFound > 0)
    }

    @Test func fiveThousandEventsExpandQuickly() {
        let events = Self.generatedEvents(count: 5_000)
        let month = Fixture.days(Fixture.day(2026, 9, 28), Fixture.day(2026, 11, 8), in: Fixture.amsterdam)
        var count = 0
        // A deliberately generous bound: this guards against accidental quadratic behaviour, not speed.
        let elapsed = ContinuousClock().measure {
            count = amsterdam.occurrences(of: events, in: month).count
        }
        #expect(count > 0)
        #expect(elapsed < Duration.seconds(5))
    }

    // MARK: - Helpers

    /// A one-hour event in Amsterdam.
    private static func hour(_ title: String, _ start: Date) -> Event {
        Fixture.timed(title, start: start, minutes: 60, in: Fixture.amsterdam)
    }

    /// Deterministic events around October 2026: every tenth repeats (daily, weekly or monthly, some
    /// with `until` or excluded dates), every seventh is all-day, a few last several days.
    private static func generatedEvents(count: Int) -> [Event] {
        let zones = [Fixture.amsterdam, Fixture.newYork, Fixture.tokyo, Fixture.utc, Fixture.losAngeles]
        let frequencies: [RecurrenceRule.Frequency] = [.daily, .weekly, .monthly]
        let base = Fixture.day(2026, 10, 20)
        var events: [Event] = []
        for index in 0..<count {
            let zone = zones[index % zones.count]
            let repeats = index % 10 == 0
            let offset = repeats ? -((index * 37) % 400) : (index * 53) % 900 - 450
            let first = base.adding(days: offset)
            var rule: RecurrenceRule?
            var excluded: Set<CalendarDate> = []
            if repeats {
                rule = RecurrenceRule(frequency: frequencies[(index / 10) % 3])
                if (index / 10) % 4 == 1 {
                    rule?.until = base.adding(days: (index % 9) - 4)
                }
                if (index / 10) % 5 == 2 {
                    excluded = [base.adding(days: 1), base.adding(days: 3), first]
                }
            }
            let event: Event
            if index % 7 == 3 {
                let last = first.adding(days: index % 13 == 0 ? 3 : 0)
                event = Event(
                    title: "All-day \(index)", timing: .allDay(start: first, end: last), recurrence: rule,
                    excludedDates: excluded, createdAt: Fixture.created)
            } else {
                let hour = (index * 7) % 24
                let minute = (index * 13) % 4 * 15
                let start = Fixture.instant(first.year, first.month, first.day, hour, minute, in: zone)
                let minutes = index % 97 == 0 ? 3 * 24 * 60 : (index % 5 + 1) * 30
                event = Fixture.timed(
                    "Event \(index)", start: start, minutes: minutes, in: zone, recurrence: rule,
                    excludedDates: excluded)
            }
            events.append(event)
        }
        return events
    }

    /// A slow but obviously correct expansion: walks every series occurrence by occurrence from its
    /// first day, using only `Calendar` and `CalendarDate`.
    private static func referenceOccurrences(
        of event: Event,
        in interval: DateInterval,
        displayTimeZone: TimeZone
    ) -> [Occurrence] {
        func overlaps(_ start: Date, _ end: Date) -> Bool {
            if end > start {
                return start < interval.end && end > interval.start
            }
            return start >= interval.start && start < interval.end
        }
        var result: [Occurrence] = []
        switch event.timing {
        case .timed(let start, let end, let timeZone):
            let calendar = Fixture.calendar(timeZone)
            let firstDay = CalendarDate(start, in: timeZone)
            let clock = calendar.dateComponents([.hour, .minute, .second], from: start)
            let duration = end.timeIntervalSince(start)
            for day in seriesDays(of: event, from: firstDay) {
                let parts = DateComponents(
                    year: day.year, month: day.month, day: day.day, hour: clock.hour, minute: clock.minute,
                    second: clock.second)
                let occurrenceStart = day == firstDay ? start : calendar.date(from: parts)!
                if occurrenceStart >= interval.end { break }
                let occurrenceEnd = occurrenceStart.addingTimeInterval(duration)
                if overlaps(occurrenceStart, occurrenceEnd) {
                    result.append(Occurrence(event: event, date: day, start: occurrenceStart, end: occurrenceEnd))
                }
            }
        case .allDay(let first, let last):
            let length = first.days(to: last)
            for day in seriesDays(of: event, from: first) {
                let occurrenceStart = day.start(in: displayTimeZone)
                if occurrenceStart >= interval.end { break }
                let occurrenceEnd = day.adding(days: length).end(in: displayTimeZone)
                if overlaps(occurrenceStart, occurrenceEnd) {
                    result.append(Occurrence(event: event, date: day, start: occurrenceStart, end: occurrenceEnd))
                }
            }
        }
        return result
    }

    /// Every day a series produces from its first day, minus excluded dates, up to `until` or the end
    /// of 2026 (well past every range the tests query). A non-repeating event produces its first day.
    private static func seriesDays(of event: Event, from firstDay: CalendarDate) -> [CalendarDate] {
        guard let rule = event.recurrence else { return [firstDay] }
        let horizon = Fixture.day(2026, 12, 31)
        let last = min(rule.until ?? horizon, horizon)
        var days: [CalendarDate] = []
        var step = 0
        while true {
            let day: CalendarDate
            switch rule.frequency {
            case .daily:
                day = firstDay.adding(days: step)
            case .weekly:
                day = firstDay.adding(days: 7 * step)
            case .monthly:
                let month = (firstDay.month - 1 + step) % 12 + 1
                let year = firstDay.year + (firstDay.month - 1 + step) / 12
                day = Fixture.day(year, month, firstDay.day)
            }
            step += 1
            if day > last { break }
            if day.isValid && !event.excludedDates.contains(day) {
                days.append(day)
            }
        }
        return days
    }

    // MARK: - Events that last for years (found in the review for 0.2.0)

    /// A repeating event whose occurrences last for centuries (a hand-edited or damaged events.json): a
    /// week of it costs a year's worth of occurrences at most, never the whole series.
    @Test func aRepeatingEventThatLastsForCenturiesStaysCheap() throws {
        let week = Fixture.days(Fixture.day(2026, 10, 5), Fixture.day(2026, 10, 11), in: Fixture.amsterdam)
        let forever = Fixture.allDay(
            "Forever", from: Fixture.day(1, 1, 1), through: Fixture.day(9999, 12, 31),
            recurrence: RecurrenceRule(frequency: .daily))
        let longTimed = Fixture.timed(
            "Millennia", start: Fixture.instant(1000, 1, 1, 9, 0, in: Fixture.utc), minutes: 2000 * 365 * 24 * 60,
            in: Fixture.utc, recurrence: RecurrenceRule(frequency: .daily))
        let weekly = Fixture.allDay(
            "Ages", from: Fixture.day(26, 1, 5), through: Fixture.day(2026, 12, 20),
            recurrence: RecurrenceRule(frequency: .weekly))
        let month = Fixture.days(Fixture.day(2026, 9, 28), Fixture.day(2026, 11, 8), in: Fixture.amsterdam)
        let started = ContinuousClock.now
        for (event, range) in [(forever, week), (longTimed, week), (weekly, month)] {
            let found = amsterdam.occurrences(of: event, in: range)
            // The latest occurrences that started before the range, and those that start in it.
            #expect(found.count <= OccurrenceExpander.maximumSpanningOccurrences + 43, "\(event.title)")
            #expect(!found.isEmpty, "\(event.title)")
        }
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    /// Long but sensible repeating events still show while they last: of a monthly event lasting 200 days,
    /// a December week holds the seven occurrences that started from June on.
    @Test func occurrencesThatStartedMonthsAgoStillShow() throws {
        let rota = Fixture.allDay(
            "Rota", from: Fixture.day(2026, 1, 1), through: Fixture.day(2026, 7, 19),
            recurrence: RecurrenceRule(frequency: .monthly))
        let december = Fixture.days(Fixture.day(2026, 12, 7), Fixture.day(2026, 12, 13), in: Fixture.amsterdam)
        let found = amsterdam.occurrences(of: rota, in: december)
        #expect(found.map(\.date) == (6...12).map { Fixture.day(2026, $0, 1) })
    }
}
