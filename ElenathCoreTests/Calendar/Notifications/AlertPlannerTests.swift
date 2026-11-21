import ElenathCore
import Foundation
import Testing

struct AlertPlannerTests {
    private typealias Fixture = AlertsFixture

    private let planner = AlertPlanner(displayTimeZone: AlertsFixture.amsterdam)

    /// The identifier of the first alert planned for `event` alone, seen from `Fixture.now`.
    private func alertIdentifier(_ event: Event) -> String? {
        planner.plan(Fixture.library([event]), now: Fixture.now).first?.identifier
    }

    // MARK: - Fire dates

    @Test func defaultsMatchTheContract() {
        #expect(AlertPlanner.identifierPrefix == "elenath.alert.")
        #expect(planner.displayTimeZone == Fixture.amsterdam)
        #expect(planner.allDayAlertHour == 9)
        #expect(planner.maximumCount == 48)
        #expect(planner.horizonDays == 14)
    }

    @Test func timedAlertsFireTheirOffsetBeforeTheStart() throws {
        let start = Fixture.instant(2026, 10, 8, 14, 0, in: Fixture.amsterdam)
        let expected: [(AlertOffset, Date)] = [
            (.atStart, Fixture.instant(2026, 10, 8, 14, 0, in: Fixture.amsterdam)),
            (.tenMinutes, Fixture.instant(2026, 10, 8, 13, 50, in: Fixture.amsterdam)),
            (.oneHour, Fixture.instant(2026, 10, 8, 13, 0, in: Fixture.amsterdam)),
            (.oneDay, Fixture.instant(2026, 10, 7, 14, 0, in: Fixture.amsterdam)),
        ]
        #expect(expected.map { $0.0 } == AlertOffset.presets)
        for (offset, fireDate) in expected {
            let quiz = Fixture.timed(3, "Physics Quiz", start: start, minutes: 45, alert: offset)
            let alerts = planner.plan(Fixture.library([quiz]), now: Fixture.now)
            let alert = try #require(alerts.first)
            #expect(alerts.count == 1)
            #expect(alert.fireDate == fireDate)
            #expect(alert.fireDate == start.addingTimeInterval(-TimeInterval(offset.minutesBefore * 60)))
            #expect(alert.minutesBefore == offset.minutesBefore)
            #expect(alert.occurrence.id == Fixture.occurrenceID(3, Fixture.day(2026, 10, 8)))
            #expect(alert.occurrence.start == start)
        }
    }

    @Test func eventsWithoutAnAlertGetNone() {
        let start = Fixture.instant(2026, 10, 8, 14, 0, in: Fixture.amsterdam)
        let officeHours = Fixture.timed(1, "Office Hours", start: start, alert: nil)
        let holiday = Fixture.allDay(2, "Holiday", on: Fixture.day(2026, 10, 9), alert: nil)
        #expect(planner.plan(Fixture.library([officeHours, holiday]), now: Fixture.now).isEmpty)
        #expect(planner.plan(CalendarDocument(), now: Fixture.now).isEmpty)
    }

    @Test func allDayAlertsAreRelativeToNineOClock() throws {
        let day = Fixture.day(2026, 10, 8)
        let expected: [(AlertOffset, Date)] = [
            (.atStart, Fixture.instant(2026, 10, 8, 9, 0, in: Fixture.amsterdam)),
            (.tenMinutes, Fixture.instant(2026, 10, 8, 8, 50, in: Fixture.amsterdam)),
            (.oneHour, Fixture.instant(2026, 10, 8, 8, 0, in: Fixture.amsterdam)),
            (.oneDay, Fixture.instant(2026, 10, 7, 9, 0, in: Fixture.amsterdam)),
        ]
        for (offset, fireDate) in expected {
            let essay = Fixture.allDay(2, "Essay due", on: day, alert: offset)
            let alerts = planner.plan(Fixture.library([essay]), now: Fixture.now)
            let alert = try #require(alerts.first)
            #expect(alerts.count == 1)
            #expect(alert.fireDate == fireDate)
            #expect(alert.minutesBefore == offset.minutesBefore)
            #expect(alert.occurrence.isAllDay)
            #expect(alert.occurrence.id == Fixture.occurrenceID(2, day))
        }

        // A multi-day event alerts once, relative to its first day.
        let trip = Fixture.allDay(4, "Field trip", on: day, through: Fixture.day(2026, 10, 10), alert: .atStart)
        let tripAlerts = planner.plan(Fixture.library([trip]), now: Fixture.now)
        #expect(tripAlerts.map { $0.fireDate } == [Fixture.instant(2026, 10, 8, 9, 0, in: Fixture.amsterdam)])
    }

    @Test func allDayAlertsKeepNineOClockAcrossTheClockChange() {
        // Amsterdam goes from CEST (UTC+2) to CET (UTC+1) at 03:00 on Sunday 25 October 2026.
        let now = Fixture.instant(2026, 10, 20, 12, 0, in: Fixture.amsterdam)
        let onTheChange = Fixture.allDay(1, "Field trip", on: Fixture.day(2026, 10, 25), alert: .oneDay)
        let afterTheChange = Fixture.allDay(2, "Lab report due", on: Fixture.day(2026, 10, 26), alert: .oneDay)
        let changeDay = Fixture.allDay(3, "Open day", on: Fixture.day(2026, 10, 25), alert: .atStart)
        let alerts = planner.plan(Fixture.library([afterTheChange, changeDay, onTheChange]), now: now)

        // Equal fire dates: the earlier occurrence comes first.
        let expectedIDs = [
            Fixture.occurrenceID(1, Fixture.day(2026, 10, 25)),
            Fixture.occurrenceID(3, Fixture.day(2026, 10, 25)),
            Fixture.occurrenceID(2, Fixture.day(2026, 10, 26)),
        ]
        #expect(alerts.map { $0.occurrence.id } == expectedIDs)
        // 09:00 CEST on Saturday, then 09:00 CET on Sunday twice.
        let expectedFireDates = [
            Fixture.instant(2026, 10, 24, 7, 0, in: Fixture.utc),
            Fixture.instant(2026, 10, 25, 8, 0, in: Fixture.utc),
            Fixture.instant(2026, 10, 25, 8, 0, in: Fixture.utc),
        ]
        let fireDates = alerts.map { $0.fireDate }
        #expect(fireDates == expectedFireDates)
        for fireDate in fireDates {
            #expect(DatesFixture.wallClock(fireDate, in: Fixture.amsterdam) == "09:00")
        }
        // "1 day before" is a calendar day: from 09:00 on the 24th to 09:00 on the 25th is 25 hours.
        #expect(expectedFireDates[1].timeIntervalSince(expectedFireDates[0]) == 25 * 60 * 60)
    }

    @Test func allDayAlertsKeepNineOClockAcrossTheClockChangeInNewYork() {
        // New York goes from EDT (UTC-4) to EST (UTC-5) at 02:00 on Sunday 1 November 2026.
        let now = Fixture.instant(2026, 10, 28, 12, 0, in: Fixture.newYork)
        let onTheChange = Fixture.allDay(1, "Midterm", on: Fixture.day(2026, 11, 1), alert: .oneDay)
        let afterTheChange = Fixture.allDay(2, "Reading day", on: Fixture.day(2026, 11, 2), alert: .oneDay)
        let newYorkPlanner = AlertPlanner(displayTimeZone: Fixture.newYork)
        let alerts = newYorkPlanner.plan(Fixture.library([afterTheChange, onTheChange]), now: now)
        let expectedFireDates = [
            Fixture.instant(2026, 10, 31, 13, 0, in: Fixture.utc),
            Fixture.instant(2026, 11, 1, 14, 0, in: Fixture.utc),
        ]
        #expect(alerts.map { $0.fireDate } == expectedFireDates)
        for alert in alerts {
            #expect(DatesFixture.wallClock(alert.fireDate, in: Fixture.newYork) == "09:00")
        }
    }

    @Test func allDayAlertsFollowTheDisplayTimeZone() throws {
        let essay = Fixture.allDay(2, "Essay due", on: Fixture.day(2026, 10, 8), alert: .atStart)
        let library = Fixture.library([essay])
        let inAmsterdam = try #require(planner.plan(library, now: Fixture.now).first)
        let newYorkPlanner = AlertPlanner(displayTimeZone: Fixture.newYork)
        let inNewYork = try #require(newYorkPlanner.plan(library, now: Fixture.now).first)
        #expect(inAmsterdam.fireDate == Fixture.instant(2026, 10, 8, 7, 0, in: Fixture.utc))
        #expect(inNewYork.fireDate == Fixture.instant(2026, 10, 8, 13, 0, in: Fixture.utc))
        #expect(inNewYork.occurrence.id == inAmsterdam.occurrence.id)
        // The fire time moved with the zone, so the identifier changes and a sync replaces the alert.
        #expect(inNewYork.identifier != inAmsterdam.identifier)

        let earlyPlanner = AlertPlanner(displayTimeZone: Fixture.newYork, allDayAlertHour: 7)
        let early = try #require(earlyPlanner.plan(library, now: Fixture.now).first)
        #expect(early.fireDate == Fixture.instant(2026, 10, 8, 7, 0, in: Fixture.newYork))
    }

    @Test func timedAlertsDontDependOnTheDisplayTimeZone() {
        let library = Fixture.library([Fixture.quiz])
        let inAmsterdam = planner.plan(library, now: Fixture.now)
        let inNewYork = AlertPlanner(displayTimeZone: Fixture.newYork).plan(library, now: Fixture.now)
        #expect(inAmsterdam.count == 1)
        #expect(inNewYork == inAmsterdam)
    }

    // MARK: - What gets planned

    @Test func pastAlertsAreSkippedWhileTheSeriesContinues() {
        // Today's lecture alert fires at 13:50, exactly `now`, which counts as past.
        let library = Fixture.library([Fixture.lecture])
        let alerts = planner.plan(library, now: Fixture.now)
        let expectedIDs = [
            Fixture.occurrenceID(1, Fixture.day(2026, 10, 13)),
            Fixture.occurrenceID(1, Fixture.day(2026, 10, 20)),
        ]
        let expectedFireDates = [
            Fixture.instant(2026, 10, 13, 13, 50, in: Fixture.amsterdam),
            Fixture.instant(2026, 10, 20, 13, 50, in: Fixture.amsterdam),
        ]
        #expect(alerts.map { $0.occurrence.id } == expectedIDs)
        #expect(alerts.map { $0.fireDate } == expectedFireDates)

        // A minute earlier, today's alert is still ahead.
        let earlier = planner.plan(library, now: Fixture.now.addingTimeInterval(-60))
        #expect(earlier.first?.occurrence.id == Fixture.occurrenceID(1, Fixture.day(2026, 10, 6)))

        // After the alert but before the lecture starts, it stays skipped.
        let between = planner.plan(library, now: Fixture.instant(2026, 10, 6, 13, 55, in: Fixture.amsterdam))
        #expect(between.map { $0.occurrence.id } == expectedIDs)
    }

    @Test func anAllDayAlertLaterTodayIsStillPlanned() {
        // The event began at midnight, but at 08:00 its 09:00 alert is still ahead.
        let essay = Fixture.allDay(2, "Essay due", on: Fixture.day(2026, 10, 6), alert: .atStart)
        let morning = Fixture.instant(2026, 10, 6, 8, 0, in: Fixture.amsterdam)
        let alerts = planner.plan(Fixture.library([essay]), now: morning)
        #expect(alerts.map { $0.fireDate } == [Fixture.instant(2026, 10, 6, 9, 0, in: Fixture.amsterdam)])
        #expect(planner.plan(Fixture.library([essay]), now: Fixture.now).isEmpty)
    }

    @Test func excludedDatesAndDetachedEventsMatchTheCalendar() throws {
        let now = Fixture.instant(2026, 10, 5, 12, 0, in: Fixture.amsterdam)
        let tuesdays = Fixture.timed(
            1, "Physics Lecture", start: Fixture.instant(2026, 9, 1, 14, 0, in: Fixture.amsterdam), minutes: 90,
            alert: .tenMinutes, recurrence: RecurrenceRule(frequency: .weekly),
            excludedDates: [Fixture.day(2026, 10, 6), Fixture.day(2026, 10, 13)])
        // "This event only": the 6 October lecture moved to Wednesday 10:00, with a 1-hour alert.
        let movedFrom = SeriesOccurrence(seriesID: tuesdays.id, date: Fixture.day(2026, 10, 6))
        let moved = Fixture.timed(
            2, "Physics Lecture (moved)", start: Fixture.instant(2026, 10, 7, 10, 0, in: Fixture.amsterdam),
            minutes: 90, alert: .oneHour, detachedFrom: movedFrom)
        let thursdays = Fixture.timed(
            3, "Biology Seminar", start: Fixture.instant(2026, 9, 3, 9, 0, in: Fixture.amsterdam), alert: .tenMinutes,
            recurrence: RecurrenceRule(frequency: .weekly), excludedDates: [Fixture.day(2026, 10, 8)])
        // "This event only" with the alert turned off.
        let silencedFrom = SeriesOccurrence(seriesID: thursdays.id, date: Fixture.day(2026, 10, 8))
        let silenced = Fixture.timed(
            4, "Biology Seminar", start: Fixture.instant(2026, 10, 8, 9, 0, in: Fixture.amsterdam), alert: nil,
            detachedFrom: silencedFrom)
        let library = Fixture.library([tuesdays, moved, thursdays, silenced])
        let threeWeeks = AlertPlanner(displayTimeZone: Fixture.amsterdam, horizonDays: 21)
        let alerts = threeWeeks.plan(library, now: now)

        let expectedIDs = [
            Fixture.occurrenceID(2, Fixture.day(2026, 10, 7)),
            Fixture.occurrenceID(3, Fixture.day(2026, 10, 15)),
            Fixture.occurrenceID(1, Fixture.day(2026, 10, 20)),
            Fixture.occurrenceID(3, Fixture.day(2026, 10, 22)),
        ]
        let expectedFireDates = [
            Fixture.instant(2026, 10, 7, 9, 0, in: Fixture.amsterdam),
            Fixture.instant(2026, 10, 15, 8, 50, in: Fixture.amsterdam),
            Fixture.instant(2026, 10, 20, 13, 50, in: Fixture.amsterdam),
            Fixture.instant(2026, 10, 22, 8, 50, in: Fixture.amsterdam),
        ]
        #expect(alerts.map { $0.occurrence.id } == expectedIDs)
        #expect(alerts.map { $0.fireDate } == expectedFireDates)

        // Each alert is for exactly the occurrence the calendar shows.
        let expander = OccurrenceExpander(displayTimeZone: Fixture.amsterdam)
        for alert in alerts {
            let event = try #require(library.event(withID: alert.occurrence.event.id))
            #expect(expander.occurrence(of: event, on: alert.occurrence.date) == alert.occurrence)
        }
    }

    @Test func alertsBeforeTheHorizonAreFoundForEventsJustPastIt() {
        // The horizon is 14 days after `now`: 20 October, 13:50. The exams start 14.5 days after `now`.
        let examStart = Fixture.instant(2026, 10, 21, 1, 50, in: Fixture.amsterdam)
        let fourteenAndAHalfDays: TimeInterval = 14.5 * 24 * 60 * 60
        #expect(examStart.timeIntervalSince(Fixture.now) == fourteenAndAHalfDays)
        let dayBefore = Fixture.timed(1, "Exam", start: examStart, alert: .oneDay)
        let tenBefore = Fixture.timed(2, "Exam review", start: examStart, alert: .tenMinutes)
        let allDayBefore = Fixture.allDay(3, "Exam week", on: Fixture.day(2026, 10, 21), alert: .oneDay)
        let allDayOnTheDay = Fixture.allDay(4, "Exam week", on: Fixture.day(2026, 10, 21), alert: .atStart)
        let library = Fixture.library([tenBefore, allDayOnTheDay, allDayBefore, dayBefore])
        let alerts = planner.plan(library, now: Fixture.now)

        let expectedIDs = [
            Fixture.occurrenceID(1, Fixture.day(2026, 10, 21)),
            Fixture.occurrenceID(3, Fixture.day(2026, 10, 21)),
        ]
        let expectedFireDates = [
            Fixture.instant(2026, 10, 20, 1, 50, in: Fixture.amsterdam),
            Fixture.instant(2026, 10, 20, 9, 0, in: Fixture.amsterdam),
        ]
        #expect(alerts.map { $0.occurrence.id } == expectedIDs)
        #expect(alerts.map { $0.fireDate } == expectedFireDates)

        // Whether an alert is planned doesn't depend on the other events' offsets.
        #expect(planner.plan(Fixture.library([dayBefore]), now: Fixture.now).count == 1)
        #expect(planner.plan(Fixture.library([tenBefore]), now: Fixture.now).isEmpty)
    }

    @Test func theCapKeepsTheNearestAlerts() {
        // Four daily classes from tomorrow: 55 alerts fire within 14 days.
        var classes: [Event] = []
        for (index, hour) in [8, 10, 12, 16].enumerated() {
            let start = Fixture.instant(2026, 10, 7, hour, 0, in: Fixture.amsterdam)
            let daily = RecurrenceRule(frequency: .daily)
            let event = Fixture.timed(index + 1, "Class \(hour)", start: start, alert: .tenMinutes, recurrence: daily)
            classes.append(event)
        }
        let library = Fixture.library(classes)
        let uncapped = AlertPlanner(displayTimeZone: Fixture.amsterdam, maximumCount: 1_000)
        let everything = uncapped.plan(library, now: Fixture.now)
        let capped = planner.plan(library, now: Fixture.now)
        #expect(everything.count == 55)
        #expect(capped.count == 48)
        #expect(capped == Array(everything.prefix(48)))
        let fireDates = everything.map { $0.fireDate }
        #expect(fireDates == fireDates.sorted())
        let noRoom = AlertPlanner(displayTimeZone: Fixture.amsterdam, maximumCount: 0)
        #expect(noRoom.plan(library, now: Fixture.now).isEmpty)
    }

    @Test func theCapKeepsTheEarliestFireDatesNotTheEarliestStarts() {
        // Starts: tutorial, lab, exam. Alerts: tutorial 09:00, exam 10:00 (a day before), lab 11:50.
        let examStart = Fixture.instant(2026, 10, 9, 10, 0, in: Fixture.amsterdam)
        let labStart = Fixture.instant(2026, 10, 8, 12, 0, in: Fixture.amsterdam)
        let tutorialStart = Fixture.instant(2026, 10, 8, 9, 0, in: Fixture.amsterdam)
        let exam = Fixture.timed(1, "Exam", start: examStart, alert: .oneDay)
        let lab = Fixture.timed(2, "Lab", start: labStart, alert: .tenMinutes)
        let tutorial = Fixture.timed(3, "Tutorial", start: tutorialStart, alert: .atStart)
        let two = AlertPlanner(displayTimeZone: Fixture.amsterdam, maximumCount: 2)
        let alerts = two.plan(Fixture.library([exam, lab, tutorial]), now: Fixture.now)
        let expectedIDs = [
            Fixture.occurrenceID(3, Fixture.day(2026, 10, 8)),
            Fixture.occurrenceID(1, Fixture.day(2026, 10, 9)),
        ]
        #expect(alerts.map { $0.occurrence.id } == expectedIDs)
    }

    @Test func tiesAreOrderedByStartThenIdentifier() throws {
        let ten = Fixture.instant(2026, 10, 8, 10, 0, in: Fixture.amsterdam)
        let tutorial = Fixture.timed(1, "Tutorial", start: ten, alert: .atStart)
        let lab = Fixture.timed(2, "Lab", start: ten.addingTimeInterval(10 * 60), alert: .tenMinutes)
        let officeHours = Fixture.timed(3, "Office Hours", start: ten, alert: .atStart)
        let alerts = planner.plan(Fixture.library([lab, officeHours, tutorial]), now: Fixture.now)
        let expectedIDs = [
            Fixture.occurrenceID(1, Fixture.day(2026, 10, 8)),
            Fixture.occurrenceID(3, Fixture.day(2026, 10, 8)),
            Fixture.occurrenceID(2, Fixture.day(2026, 10, 8)),
        ]
        try #require(alerts.count == 3)
        #expect(alerts.map { $0.fireDate } == [ten, ten, ten])
        #expect(alerts.map { $0.occurrence.id } == expectedIDs)
        #expect(alerts[0].identifier < alerts[1].identifier)
        #expect(planner.plan(Fixture.library([tutorial, lab, officeHours]), now: Fixture.now) == alerts)
    }

    // MARK: - Identifiers

    @Test func identifiersAreTheSameOnEveryMac() throws {
        let lecture = Fixture.timed(
            1, "Physics Lecture", start: Fixture.instant(2026, 10, 6, 14, 0, in: Fixture.amsterdam), minutes: 90,
            alert: .tenMinutes, location: "Room B204")
        let essay = Fixture.allDay(2, "Essay due", on: Fixture.day(2026, 10, 8), alert: .atStart)
        let now = Fixture.instant(2026, 10, 5, 12, 0, in: Fixture.amsterdam)
        let alerts = planner.plan(Fixture.library([essay, lecture]), now: now)
        // The hashes were computed independently with 64-bit FNV-1a over the fields. Swift's `Hasher`
        // is seeded randomly per process, so an identifier made with it would differ on every run.
        let expected = [
            "elenath.alert.4954484C-A1E7-4000-8000-000000000001.2026-10-06.10.c2ff46446ba4031c",
            "elenath.alert.4954484C-A1E7-4000-8000-000000000002.2026-10-08.0.7169c1122c3729bc",
        ]
        #expect(Fixture.identifiers(alerts) == expected)
        let occurrence = try #require(alerts.first?.occurrence)
        #expect(planner.identifier(for: occurrence, minutesBefore: 10) == expected[0])
    }

    @Test func identifiersAreStableAcrossPlanners() {
        let library = Fixture.library([Fixture.lecture, Fixture.essay, Fixture.quiz])
        let first = planner.plan(library, now: Fixture.now)
        let otherPlanner = AlertPlanner(displayTimeZone: TimeZone(identifier: "Europe/Amsterdam")!, maximumCount: 10)
        let second = otherPlanner.plan(library, now: Fixture.now)
        #expect(first.count == 4)
        #expect(Fixture.identifiers(second) == Fixture.identifiers(first))
        #expect(Set(Fixture.identifiers(first)).count == first.count)
        // An hour later the same alerts are ahead, with the same identifiers.
        let later = planner.plan(library, now: Fixture.now.addingTimeInterval(60 * 60))
        #expect(Fixture.identifiers(later) == Fixture.identifiers(first))
    }

    @Test func identifiersChangeWhenWhatTheAlertShowsChanges() throws {
        let start = Fixture.instant(2026, 10, 8, 10, 0, in: Fixture.amsterdam)
        let original = try #require(alertIdentifier(Fixture.quiz))

        var renamed = Fixture.quiz
        renamed.title = "Physics Midterm"
        var relocated = Fixture.quiz
        relocated.location = "Hall B"
        var moved = Fixture.quiz
        let quarterPast = start.addingTimeInterval(15 * 60)
        let hourLater = quarterPast.addingTimeInterval(60 * 60)
        moved.timing = .timed(start: quarterPast, end: hourLater, timeZone: Fixture.amsterdam)
        var lengthened = Fixture.quiz
        lengthened.timing = .timed(start: start, end: start.addingTimeInterval(90 * 60), timeZone: Fixture.amsterdam)
        var realerted = Fixture.quiz
        realerted.alert = .tenMinutes
        var madeAllDay = Fixture.quiz
        madeAllDay.timing = .allDay(start: Fixture.day(2026, 10, 8), end: Fixture.day(2026, 10, 8))
        let changed = [renamed, relocated, moved, lengthened, realerted, madeAllDay].map { alertIdentifier($0) }
        for identifier in changed {
            #expect(identifier != nil)
            #expect(identifier != original)
        }
        #expect(Set(changed).count == changed.count)

        // Things the alert doesn't show keep the identifier.
        var annotated = Fixture.quiz
        annotated.notes = "Bring a calculator"
        var regrouped = Fixture.quiz
        regrouped.subjectID = Fixture.eventID(99)
        var touched = Fixture.quiz
        touched.modifiedAt = Fixture.now
        for unchanged in [annotated, regrouped, touched] {
            #expect(alertIdentifier(unchanged) == original)
        }
    }

    @Test func parsingAnIdentifierGivesBackTheOccurrence() throws {
        let library = Fixture.library([Fixture.lecture, Fixture.essay, Fixture.quiz])
        let alerts = planner.plan(library, now: Fixture.now)
        #expect(alerts.count == 4)
        for alert in alerts {
            let parsed = AlertPlanner.parse(identifier: alert.identifier)
            #expect(parsed?.eventID == alert.occurrence.event.id)
            #expect(parsed?.date == alert.occurrence.date)
        }

        // A hand-edited offset of any size still makes an identifier that parses.
        let occurrence = try #require(alerts.first?.occurrence)
        let farAhead = planner.identifier(for: occurrence, minutesBefore: 5_000_000_000)
        #expect(AlertPlanner.parse(identifier: farAhead)?.eventID == occurrence.event.id)

        let golden = "elenath.alert.4954484C-A1E7-4000-8000-000000000001.2026-10-06.10.c2ff46446ba4031c"
        let parsed = AlertPlanner.parse(identifier: golden)
        #expect(parsed?.eventID == Fixture.eventID(1))
        #expect(parsed?.date == Fixture.day(2026, 10, 6))
    }

    @Test func parsingRejectsIdentifiersNotMadeByElenath() {
        let foreign = [
            "",
            "elenath.alert.",
            "com.example.reminder.42",
            "ITHIL.ALERT.4954484C-A1E7-4000-8000-000000000001.2026-10-06.10.c2ff46446ba4031c",
            "x.elenath.alert.4954484C-A1E7-4000-8000-000000000001.2026-10-06.10.c2ff46446ba4031c",
            "elenath.alert.not-a-uuid.2026-10-06.10.c2ff46446ba4031c",
            // Ithil's own alerts are Ithil's: Elenath never takes them for its own.
            "ithil.alert.4954484C-A1E7-4000-8000-000000000001.2026-10-06.10.c2ff46446ba4031c",
            "elenath.alert.4954484C-A1E7-4000-8000-000000000001.2026-02-30.10.c2ff46446ba4031c",
            "elenath.alert.4954484C-A1E7-4000-8000-000000000001.06-10-2026.10.c2ff46446ba4031c",
            "elenath.alert.4954484C-A1E7-4000-8000-000000000001.2026-10-06.-10.c2ff46446ba4031c",
            "elenath.alert.4954484C-A1E7-4000-8000-000000000001.2026-10-06.ten.c2ff46446ba4031c",
            "elenath.alert.4954484C-A1E7-4000-8000-000000000001.2026-10-06.+10.c2ff46446ba4031c",
            "elenath.alert.4954484C-A1E7-4000-8000-000000000001.2026-10-06.99999999999999999999.c2ff46446ba4031c",
            "elenath.alert.4954484C-A1E7-4000-8000-000000000001.2026-10-06..c2ff46446ba4031c",
            "elenath.alert.4954484C-A1E7-4000-8000-000000000001.2026-10-06.10",
            "elenath.alert.4954484C-A1E7-4000-8000-000000000001.2026-10-06.10.c2ff46446ba4031",
            "elenath.alert.4954484C-A1E7-4000-8000-000000000001.2026-10-06.10.C2FF46446BA4031C",
            "elenath.alert.4954484C-A1E7-4000-8000-000000000001.2026-10-06.10.c2ff46446ba4031g",
            "elenath.alert.4954484C-A1E7-4000-8000-000000000001.2026-10-06.10.c2ff46446ba4031c.extra",
        ]
        for identifier in foreign {
            #expect(AlertPlanner.parse(identifier: identifier)?.eventID == nil, "\(identifier)")
        }
    }
}
