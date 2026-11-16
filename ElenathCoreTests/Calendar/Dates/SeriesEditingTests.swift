import ElenathCore
import Foundation
import Testing

struct SeriesEditingTests {
    private typealias Fixture = DatesFixture

    private let zone = DatesFixture.amsterdam
    private let expander = OccurrenceExpander(displayTimeZone: DatesFixture.amsterdam)
    /// When the edits happen: Tuesday 6 October 2026, 17:20 in Amsterdam.
    private let editTime = Date(timeIntervalSince1970: 1_791_300_000)
    private let scopes: [SeriesEditing.Scope] = [.thisEvent, .allFutureEvents]

    // MARK: - Edit this event only

    @Test func editThisEventDetachesTheOccurrence() throws {
        let series = lectureSeries()
        var library = CalendarDocument(events: [series])
        let second = try occurrence(of: series, on: 13)
        let edited = edit(second, title: "Physics Lab", movedBy: 60)
        SeriesEditing.update(second, with: edited, scope: .thisEvent, in: &library, now: editTime)

        #expect(library.events.count == 2)
        let updatedSeries = try #require(library.event(withID: series.id))
        #expect(updatedSeries.excludedDates == Set([Fixture.day(2026, 10, 13)]))
        #expect(updatedSeries.recurrence == series.recurrence)
        #expect(updatedSeries.title == "Physics Lecture")
        #expect(updatedSeries.modifiedAt == editTime)

        let detached = try #require(library.events.first(where: { $0.id != series.id }))
        #expect(detached.detachedFrom == SeriesOccurrence(seriesID: series.id, date: Fixture.day(2026, 10, 13)))
        #expect(detached.recurrence == nil)
        #expect(detached.excludedDates.isEmpty)
        #expect(detached.title == "Physics Lab")
        #expect(detached.createdAt == editTime)
        #expect(detached.modifiedAt == editTime)
        #expect(detached.timing == edited.timing)

        let expected = [
            "2026-10-06 Physics Lecture",
            "2026-10-13 Physics Lab",
            "2026-10-20 Physics Lecture",
            "2026-10-27 Physics Lecture",
            "2026-11-03 Physics Lecture",
            "2026-11-10 Physics Lecture",
        ]
        #expect(schedule(library) == expected)
        let lab = try #require(expander.occurrence(of: detached, on: Fixture.day(2026, 10, 13)))
        #expect(Fixture.wallClock(lab.start, in: zone) == "15:00")
    }

    @Test func editThisEventOnAnAllDaySeries() throws {
        let series = essaySeries()
        var library = CalendarDocument(events: [series])
        let second = try #require(expander.occurrence(of: series, on: Fixture.day(2026, 10, 16)))
        var edited = series
        edited.title = "Essay extension"
        edited.timing = .allDay(start: Fixture.day(2026, 10, 18), end: Fixture.day(2026, 10, 18))
        SeriesEditing.update(second, with: edited, scope: .thisEvent, in: &library, now: editTime)

        let updatedSeries = try #require(library.event(withID: series.id))
        #expect(updatedSeries.excludedDates == Set([Fixture.day(2026, 10, 16)]))
        let detached = try #require(library.events.first(where: { $0.id != series.id }))
        #expect(detached.detachedFrom == SeriesOccurrence(seriesID: series.id, date: Fixture.day(2026, 10, 16)))
        let sunday = Fixture.day(2026, 10, 18)
        #expect(detached.timing == EventTiming.allDay(start: sunday, end: sunday))
        let expected = [
            "2026-10-09 Essay due",
            "2026-10-18 Essay extension",
            "2026-10-23 Essay due",
            "2026-10-30 Essay due",
            "2026-11-06 Essay due",
        ]
        #expect(schedule(library) == expected)
    }

    @Test func editThisEventOnTheFirstOccurrence() throws {
        let series = lectureSeries()
        var library = CalendarDocument(events: [series])
        let first = try occurrence(of: series, on: 6)
        SeriesEditing.update(
            first, with: edit(first, title: "Intro lecture"), scope: .thisEvent, in: &library, now: editTime)

        let updatedSeries = try #require(library.event(withID: series.id))
        #expect(updatedSeries.excludedDates == Set([Fixture.day(2026, 10, 6)]))
        #expect(updatedSeries.timing == series.timing)
        let detached = try #require(library.events.first(where: { $0.id != series.id }))
        #expect(detached.detachedFrom == SeriesOccurrence(seriesID: series.id, date: Fixture.day(2026, 10, 6)))
        let expected = [
            "2026-10-06 Intro lecture",
            "2026-10-13 Physics Lecture",
            "2026-10-20 Physics Lecture",
            "2026-10-27 Physics Lecture",
            "2026-11-03 Physics Lecture",
            "2026-11-10 Physics Lecture",
        ]
        #expect(schedule(library) == expected)
    }

    @Test func editThisEventOnTheLastOccurrenceKeepsTheDetachedEvent() throws {
        // A series of one: detaching its only occurrence removes the series but keeps the edit.
        let series = lectureSeries(until: Fixture.day(2026, 10, 6))
        var library = CalendarDocument(events: [series])
        let only = try occurrence(of: series, on: 6)
        SeriesEditing.update(only, with: edit(only, title: "One-off"), scope: .thisEvent, in: &library, now: editTime)

        #expect(library.event(withID: series.id) == nil)
        #expect(library.events.count == 1)
        #expect(schedule(library) == ["2026-10-06 One-off"])
    }

    // MARK: - Edit all future events

    @Test func editAllFutureFromTheFirstOccurrenceEditsTheSeriesInPlace() throws {
        let series = lectureSeries(excluded: [Fixture.day(2026, 10, 20)])
        var library = CalendarDocument(events: [series])
        let first = try occurrence(of: series, on: 6)
        SeriesEditing.update(
            first, with: edit(first, title: "Physics", movedBy: 30), scope: .allFutureEvents, in: &library,
            now: editTime)

        #expect(library.events.count == 1)
        let edited = try #require(library.events.first)
        #expect(edited.id == series.id)
        #expect(edited.title == "Physics")
        #expect(edited.createdAt == series.createdAt)
        #expect(edited.modifiedAt == editTime)
        #expect(edited.excludedDates == Set([Fixture.day(2026, 10, 20)]))
        #expect(edited.recurrence == RecurrenceRule(frequency: .weekly))
        #expect(edited.detachedFrom == nil)
        let found = expander.occurrences(of: edited, in: october)
        let times = found.map { Fixture.wallClock($0.start, in: zone) }
        let dates = found.map { $0.date }
        #expect(dates == Fixture.octoberDays([6, 13, 27]))
        #expect(times == ["14:30", "14:30", "14:30"])
    }

    @Test func editAllFutureFromALaterOccurrenceSplitsTheSeries() throws {
        let series = lectureSeries(excluded: [Fixture.day(2026, 10, 13), Fixture.day(2026, 10, 27)])
        let early = makeDetached(from: series, originalDay: 13, title: "Lab (moved)", day: 14)
        let late = makeDetached(from: series, originalDay: 27, title: "Guest lecture", day: 27)
        let other = Fixture.timed("Other", start: Fixture.instant(2026, 10, 8, 9, 0, in: zone), minutes: 60, in: zone)
        var library = CalendarDocument(events: [series, early, late, other])
        let third = try occurrence(of: series, on: 20)
        SeriesEditing.update(
            third, with: edit(third, title: "Physics (B204)"), scope: .allFutureEvents, in: &library, now: editTime)

        #expect(library.events.count == 5)
        let ended = try #require(library.event(withID: series.id))
        #expect(ended.recurrence == RecurrenceRule(frequency: .weekly, until: Fixture.day(2026, 10, 19)))
        #expect(ended.excludedDates == Set([Fixture.day(2026, 10, 13)]))
        #expect(ended.title == "Physics Lecture")
        #expect(ended.modifiedAt == editTime)

        let continuation = try #require(library.events.first(where: { $0.title == "Physics (B204)" }))
        #expect(continuation.id != series.id)
        #expect(continuation.recurrence == RecurrenceRule(frequency: .weekly))
        #expect(continuation.timing.startDate == Fixture.day(2026, 10, 20))
        #expect(continuation.excludedDates == Set([Fixture.day(2026, 10, 27)]))
        #expect(continuation.detachedFrom == nil)
        #expect(continuation.createdAt == editTime)
        #expect(continuation.modifiedAt == editTime)

        // Detached events from the split on follow the new series; earlier ones stay with the old one.
        let movedLate = try #require(library.event(withID: late.id))
        let lateLink = SeriesOccurrence(seriesID: continuation.id, date: Fixture.day(2026, 10, 27))
        #expect(movedLate.detachedFrom == lateLink)
        #expect(movedLate.modifiedAt == editTime)
        #expect(library.event(withID: early.id) == early)
        #expect(library.event(withID: other.id) == other)

        let expected = [
            "2026-10-06 Physics Lecture",
            "2026-10-08 Other",
            "2026-10-14 Lab (moved)",
            "2026-10-20 Physics (B204)",
            "2026-10-27 Guest lecture",
            "2026-11-03 Physics (B204)",
            "2026-11-10 Physics (B204)",
        ]
        #expect(schedule(library) == expected)
    }

    @Test func splitLeavingNothingBeforeItRemovesTheOldSeries() throws {
        let series = lectureSeries(excluded: [Fixture.day(2026, 10, 6)])
        let moved = makeDetached(from: series, originalDay: 6, title: "Intro (moved)", day: 7)
        var library = CalendarDocument(events: [series, moved])
        let second = try occurrence(of: series, on: 13)
        SeriesEditing.update(
            second, with: edit(second, title: "Physics (B204)"), scope: .allFutureEvents, in: &library, now: editTime)

        #expect(library.event(withID: series.id) == nil)
        #expect(library.events.count == 2)
        #expect(library.event(withID: moved.id) == moved)
        let continuation = try #require(library.events.first(where: { $0.title == "Physics (B204)" }))
        #expect(continuation.timing.startDate == Fixture.day(2026, 10, 13))
        #expect(continuation.repeats)
    }

    @Test func editAllFutureCanStopTheRepeating() throws {
        let series = lectureSeries()
        var library = CalendarDocument(events: [series])
        let third = try occurrence(of: series, on: 20)
        var edited = edit(third, title: "Last lecture")
        edited.recurrence = nil
        SeriesEditing.update(third, with: edited, scope: .allFutureEvents, in: &library, now: editTime)

        let ended = try #require(library.event(withID: series.id))
        #expect(ended.recurrence?.until == Fixture.day(2026, 10, 19))
        let last = try #require(library.events.first(where: { $0.title == "Last lecture" }))
        #expect(!last.repeats)
        #expect(last.excludedDates.isEmpty)
        let expected = [
            "2026-10-06 Physics Lecture",
            "2026-10-13 Physics Lecture",
            "2026-10-20 Last lecture",
        ]
        #expect(schedule(library) == expected)
    }

    @Test func splitThatMovesTheSeriesToAnotherDayTakesItsExclusionsAlong() throws {
        // 27 October was replaced by a guest lecture and 3 November was cancelled. From 20 October on,
        // the lecture moves to Wednesday: neither may come back on the Wednesday after.
        let series = lectureSeries(excluded: [Fixture.day(2026, 10, 27), Fixture.day(2026, 11, 3)])
        let late = makeDetached(from: series, originalDay: 27, title: "Guest lecture", day: 27)
        var library = CalendarDocument(events: [series, late])
        let third = try occurrence(of: series, on: 20)
        let edited = edit(third, title: "Physics (Wednesday)", movedBy: 24 * 60)
        SeriesEditing.update(third, with: edited, scope: .allFutureEvents, in: &library, now: editTime)

        let continuation = try #require(library.events.first(where: { $0.title == "Physics (Wednesday)" }))
        #expect(continuation.timing.startDate == Fixture.day(2026, 10, 21))
        #expect(continuation.excludedDates == Set([Fixture.day(2026, 10, 28), Fixture.day(2026, 11, 4)]))
        let movedLate = try #require(library.event(withID: late.id))
        #expect(movedLate.detachedFrom == SeriesOccurrence(seriesID: continuation.id, date: Fixture.day(2026, 10, 28)))
        let expected = [
            "2026-10-06 Physics Lecture",
            "2026-10-13 Physics Lecture",
            "2026-10-21 Physics (Wednesday)",
            "2026-10-27 Guest lecture",
        ]
        #expect(schedule(library) == expected)
    }

    @Test func splitOfAMonthlySeriesMovesExclusionsByMonths() throws {
        // On the 20th of every month; February 2027 was cancelled. From January on it moves to the 10th
        // of the following month, so the cancelled one is now 10 March.
        let start = Fixture.instant(2026, 10, 20, 10, 0, in: zone)
        let monthly = Fixture.timed(
            "Seminar", start: start, minutes: 60, in: zone, recurrence: RecurrenceRule(frequency: .monthly),
            excludedDates: [Fixture.day(2027, 2, 20)])
        var library = CalendarDocument(events: [monthly])
        let january = try #require(expander.occurrence(of: monthly, on: Fixture.day(2027, 1, 20)))
        let edited = edit(january, title: "Seminar (new day)", movedBy: 21 * 24 * 60)
        SeriesEditing.update(january, with: edited, scope: .allFutureEvents, in: &library, now: editTime)

        let continuation = try #require(library.events.first(where: { $0.title == "Seminar (new day)" }))
        #expect(continuation.timing.startDate == Fixture.day(2027, 2, 10))
        #expect(continuation.excludedDates == Set([Fixture.day(2027, 3, 10)]))
        let range = Fixture.days(Fixture.day(2027, 1, 1), Fixture.day(2027, 4, 30), in: zone)
        let dates = expander.occurrences(of: library.events, in: range).map { $0.date }
        #expect(dates == [Fixture.day(2027, 2, 10), Fixture.day(2027, 4, 10)])
    }

    @Test func editAllFutureFromTheFirstOccurrenceToAnotherDayMovesExclusions() throws {
        let series = lectureSeries(excluded: [Fixture.day(2026, 10, 13), Fixture.day(2026, 10, 27)])
        let early = makeDetached(from: series, originalDay: 13, title: "Lab (moved)", day: 14)
        var library = CalendarDocument(events: [series, early])
        let first = try occurrence(of: series, on: 6)
        let edited = edit(first, title: "Physics", movedBy: 24 * 60)
        SeriesEditing.update(first, with: edited, scope: .allFutureEvents, in: &library, now: editTime)

        let moved = try #require(library.event(withID: series.id))
        #expect(moved.timing.startDate == Fixture.day(2026, 10, 7))
        #expect(moved.excludedDates == Set([Fixture.day(2026, 10, 14), Fixture.day(2026, 10, 28)]))
        let relinked = try #require(library.event(withID: early.id))
        #expect(relinked.detachedFrom == SeriesOccurrence(seriesID: series.id, date: Fixture.day(2026, 10, 14)))
        #expect(relinked.modifiedAt == editTime)
        let expected = [
            "2026-10-07 Physics",
            "2026-10-14 Lab (moved)",
            "2026-10-21 Physics",
            "2026-11-04 Physics",
        ]
        #expect(schedule(library) == expected)
    }

    @Test func editAllFutureWithoutRepeatingTurnsDetachedEventsIntoOrdinaryOnes() throws {
        let series = lectureSeries(excluded: [Fixture.day(2026, 10, 27)])
        let late = makeDetached(from: series, originalDay: 27, title: "Guest lecture", day: 27)
        var library = CalendarDocument(events: [series, late])
        let third = try occurrence(of: series, on: 20)
        var edited = edit(third, title: "Last lecture")
        edited.recurrence = nil
        SeriesEditing.update(third, with: edited, scope: .allFutureEvents, in: &library, now: editTime)

        let unlinked = try #require(library.event(withID: late.id))
        #expect(unlinked.detachedFrom == nil)
        #expect(unlinked.title == "Guest lecture")
        let expected = [
            "2026-10-06 Physics Lecture",
            "2026-10-13 Physics Lecture",
            "2026-10-20 Last lecture",
            "2026-10-27 Guest lecture",
        ]
        #expect(schedule(library) == expected)
    }

    @Test func editAllFutureOnAnAllDaySeries() throws {
        let series = essaySeries()
        var library = CalendarDocument(events: [series])
        let third = try #require(expander.occurrence(of: series, on: Fixture.day(2026, 10, 23)))
        var edited = series
        edited.title = "Essay (new format)"
        edited.timing = .allDay(start: Fixture.day(2026, 10, 23), end: Fixture.day(2026, 10, 23))
        SeriesEditing.update(third, with: edited, scope: .allFutureEvents, in: &library, now: editTime)

        let ended = try #require(library.event(withID: series.id))
        #expect(ended.recurrence?.until == Fixture.day(2026, 10, 22))
        let expected = [
            "2026-10-09 Essay due",
            "2026-10-16 Essay due",
            "2026-10-23 Essay (new format)",
            "2026-10-30 Essay (new format)",
            "2026-11-06 Essay (new format)",
        ]
        #expect(schedule(library) == expected)
    }

    // MARK: - Editing events that don't repeat

    @Test func editingANonRepeatingEventReplacesItByID() throws {
        for scope in scopes {
            let start = Fixture.instant(2026, 10, 8, 9, 0, in: zone)
            let event = Fixture.timed("Essay draft", start: start, minutes: 60, in: zone)
            let other = Fixture.timed("Other", start: start, minutes: 30, in: zone)
            var library = CalendarDocument(events: [event, other])
            let single = try #require(expander.occurrence(of: event, on: Fixture.day(2026, 10, 8)))
            let edited = edit(single, title: "Essay final", movedBy: 120)
            SeriesEditing.update(single, with: edited, scope: scope, in: &library, now: editTime)

            #expect(library.events.count == 2)
            let replaced = try #require(library.events.first)
            #expect(replaced.id == event.id)
            #expect(replaced.title == "Essay final")
            #expect(replaced.timing == edited.timing)
            #expect(replaced.createdAt == event.createdAt)
            #expect(replaced.modifiedAt == editTime)
            #expect(replaced.detachedFrom == nil)
            #expect(library.events.last == other)
        }
    }

    @Test func editingADetachedEventReplacesItByID() throws {
        for scope in scopes {
            let series = lectureSeries(excluded: [Fixture.day(2026, 10, 13)])
            let moved = makeDetached(from: series, originalDay: 13, title: "Lab (moved)", day: 14)
            var library = CalendarDocument(events: [series, moved])
            let single = try #require(expander.occurrence(of: moved, on: Fixture.day(2026, 10, 14)))
            SeriesEditing.update(
                single, with: edit(single, title: "Lab (room change)"), scope: scope, in: &library, now: editTime)

            #expect(library.events.count == 2)
            #expect(library.event(withID: series.id) == series)
            let replaced = try #require(library.event(withID: moved.id))
            #expect(replaced.title == "Lab (room change)")
            #expect(replaced.detachedFrom == moved.detachedFrom)
            #expect(replaced.modifiedAt == editTime)
        }
    }

    @Test func editThatChangesNothingKeepsTheLibrary() throws {
        let start = Fixture.instant(2026, 10, 8, 9, 0, in: zone)
        let single = Fixture.timed("Essay draft", start: start, minutes: 60, in: zone)
        let series = lectureSeries()
        let library = CalendarDocument(events: [single, series])
        var edited = library

        let singleOccurrence = try #require(expander.occurrence(of: single, on: Fixture.day(2026, 10, 8)))
        SeriesEditing.update(singleOccurrence, with: single, scope: .thisEvent, in: &edited, now: editTime)
        let first = try occurrence(of: series, on: 6)
        SeriesEditing.update(first, with: series, scope: .allFutureEvents, in: &edited, now: editTime)
        #expect(edited == library)
    }

    @Test func editOfAnEventThatIsGoneIsIgnored() throws {
        let series = lectureSeries()
        let start = Fixture.instant(2026, 10, 8, 9, 0, in: zone)
        let unrelated = Fixture.timed("Other", start: start, minutes: 60, in: zone)
        let library = CalendarDocument(events: [unrelated])
        var edited = library
        let second = try occurrence(of: series, on: 13)
        for scope in scopes {
            SeriesEditing.update(second, with: edit(second, title: "Gone"), scope: scope, in: &edited, now: editTime)
            SeriesEditing.delete(second, scope: scope, from: &edited)
        }
        #expect(edited == library)
    }

    // MARK: - Delete

    @Test func deleteThisEventExcludesTheDate() throws {
        let series = lectureSeries()
        var library = CalendarDocument(events: [series])
        let target = try occurrence(of: series, on: 13)
        SeriesEditing.delete(target, scope: .thisEvent, from: &library)

        let updated = try #require(library.event(withID: series.id))
        #expect(updated.excludedDates == Set([Fixture.day(2026, 10, 13)]))
        #expect(updated.recurrence == series.recurrence)
        let expected = [
            "2026-10-06 Physics Lecture",
            "2026-10-20 Physics Lecture",
            "2026-10-27 Physics Lecture",
            "2026-11-03 Physics Lecture",
            "2026-11-10 Physics Lecture",
        ]
        #expect(schedule(library) == expected)
    }

    @Test func deleteThisEventOnTheFirstOccurrence() throws {
        let series = lectureSeries()
        var library = CalendarDocument(events: [series])
        let first = try occurrence(of: series, on: 6)
        SeriesEditing.delete(first, scope: .thisEvent, from: &library)

        let updated = try #require(library.event(withID: series.id))
        #expect(updated.excludedDates == Set([Fixture.day(2026, 10, 6)]))
        #expect(schedule(library).first == "2026-10-13 Physics Lecture")
        #expect(schedule(library).count == 5)
    }

    @Test func deleteThisEventLeavingNoOccurrencesRemovesTheSeries() throws {
        // Two lectures; the first was moved to Wednesday, and now the second is deleted.
        let series = lectureSeries(until: Fixture.day(2026, 10, 13), excluded: [Fixture.day(2026, 10, 6)])
        let moved = makeDetached(from: series, originalDay: 6, title: "Intro (moved)", day: 7)
        var library = CalendarDocument(events: [series, moved])
        let target = try occurrence(of: series, on: 13)
        SeriesEditing.delete(target, scope: .thisEvent, from: &library)

        #expect(library.event(withID: series.id) == nil)
        #expect(library.events == [moved])
    }

    @Test func deleteAllFutureEndsTheSeriesTheDayBefore() throws {
        let series = lectureSeries(excluded: [Fixture.day(2026, 10, 13), Fixture.day(2026, 10, 27)])
        let early = makeDetached(from: series, originalDay: 13, title: "Lab (moved)", day: 14)
        let late = makeDetached(from: series, originalDay: 27, title: "Guest lecture", day: 27)
        let other = Fixture.timed("Other", start: Fixture.instant(2026, 10, 29, 9, 0, in: zone), minutes: 60, in: zone)
        var library = CalendarDocument(events: [series, early, late, other])
        let target = try occurrence(of: series, on: 20)
        SeriesEditing.delete(target, scope: .allFutureEvents, from: &library)

        let ended = try #require(library.event(withID: series.id))
        #expect(ended.recurrence == RecurrenceRule(frequency: .weekly, until: Fixture.day(2026, 10, 19)))
        #expect(ended.excludedDates == Set([Fixture.day(2026, 10, 13)]))
        #expect(library.event(withID: late.id) == nil)
        #expect(library.event(withID: early.id) == early)
        #expect(library.event(withID: other.id) == other)
        let expected = [
            "2026-10-06 Physics Lecture",
            "2026-10-14 Lab (moved)",
            "2026-10-29 Other",
        ]
        #expect(schedule(library) == expected)
    }

    @Test func deleteAllFutureFromTheFirstOccurrenceDeletesTheSeriesAndItsDetachedEvents() throws {
        let series = lectureSeries(excluded: [Fixture.day(2026, 10, 13), Fixture.day(2026, 10, 27)])
        let early = makeDetached(from: series, originalDay: 13, title: "Lab (moved)", day: 14)
        let late = makeDetached(from: series, originalDay: 27, title: "Guest lecture", day: 27)
        let other = Fixture.timed("Other", start: Fixture.instant(2026, 10, 29, 9, 0, in: zone), minutes: 60, in: zone)
        var library = CalendarDocument(events: [series, early, late, other])
        let target = try occurrence(of: series, on: 6)
        SeriesEditing.delete(target, scope: .allFutureEvents, from: &library)

        #expect(library.events == [other])
    }

    @Test func deleteAllFutureLeavingNoOccurrencesRemovesTheSeries() throws {
        let series = lectureSeries(excluded: [Fixture.day(2026, 10, 6)])
        let moved = makeDetached(from: series, originalDay: 6, title: "Intro (moved)", day: 7)
        var library = CalendarDocument(events: [series, moved])
        let target = try occurrence(of: series, on: 13)
        SeriesEditing.delete(target, scope: .allFutureEvents, from: &library)

        #expect(library.events == [moved])
    }

    @Test func deleteAllFutureOnAMonthlySeriesKeepsEarlierMonths() throws {
        // On the 31st of every month from 31 October 2026: the next one is 31 December.
        let start = Fixture.instant(2026, 10, 31, 18, 0, in: zone)
        let monthly = Fixture.timed(
            "Pay rent", start: start, minutes: 15, in: zone, recurrence: RecurrenceRule(frequency: .monthly))
        var library = CalendarDocument(events: [monthly])
        let december = try #require(expander.occurrence(of: monthly, on: Fixture.day(2026, 12, 31)))
        SeriesEditing.delete(december, scope: .allFutureEvents, from: &library)

        let ended = try #require(library.event(withID: monthly.id))
        #expect(ended.recurrence?.until == Fixture.day(2026, 12, 30))
        let range = Fixture.days(Fixture.day(2026, 10, 1), Fixture.day(2027, 12, 31), in: zone)
        let dates = expander.occurrences(of: library.events, in: range).map { $0.date }
        #expect(dates == [Fixture.day(2026, 10, 31)])
    }

    @Test func deletingANonRepeatingEventRemovesIt() throws {
        for scope in scopes {
            let start = Fixture.instant(2026, 10, 8, 9, 0, in: zone)
            let event = Fixture.timed("Essay draft", start: start, minutes: 60, in: zone)
            let other = Fixture.timed("Other", start: start, minutes: 30, in: zone)
            var library = CalendarDocument(events: [event, other])
            let single = try #require(expander.occurrence(of: event, on: Fixture.day(2026, 10, 8)))
            SeriesEditing.delete(single, scope: scope, from: &library)
            #expect(library.events == [other])
        }
    }

    @Test func deletingADetachedEventKeepsItsDateExcluded() throws {
        for scope in scopes {
            let series = lectureSeries(excluded: [Fixture.day(2026, 10, 13)])
            let moved = makeDetached(from: series, originalDay: 13, title: "Lab (moved)", day: 14)
            var library = CalendarDocument(events: [series, moved])
            let single = try #require(expander.occurrence(of: moved, on: Fixture.day(2026, 10, 14)))
            SeriesEditing.delete(single, scope: scope, from: &library)

            #expect(library.events == [series])
            let dates = schedule(library)
            #expect(!dates.contains("2026-10-13 Physics Lecture"))
        }
    }

    @Test func deleteAllFutureOnAnAllDaySeries() throws {
        let series = essaySeries()
        var library = CalendarDocument(events: [series])
        let third = try #require(expander.occurrence(of: series, on: Fixture.day(2026, 10, 23)))
        SeriesEditing.delete(third, scope: .allFutureEvents, from: &library)

        let ended = try #require(library.event(withID: series.id))
        #expect(ended.recurrence?.until == Fixture.day(2026, 10, 22))
        #expect(schedule(library) == ["2026-10-09 Essay due", "2026-10-16 Essay due"])
    }

    @Test func deleteThisEventOnAnAllDaySeries() throws {
        let series = essaySeries()
        var library = CalendarDocument(events: [series])
        let second = try #require(expander.occurrence(of: series, on: Fixture.day(2026, 10, 16)))
        SeriesEditing.delete(second, scope: .thisEvent, from: &library)
        let expected = [
            "2026-10-09 Essay due",
            "2026-10-23 Essay due",
            "2026-10-30 Essay due",
            "2026-11-06 Essay due",
        ]
        #expect(schedule(library) == expected)
    }

    // MARK: - Helpers

    private var october: DateInterval {
        Fixture.days(Fixture.day(2026, 10, 1), Fixture.day(2026, 10, 31), in: zone)
    }

    /// "Physics Lecture", Tuesdays 14:00–15:30 in Amsterdam from 6 October 2026.
    private func lectureSeries(until: CalendarDate? = nil, excluded: Set<CalendarDate> = []) -> Event {
        Fixture.timed(
            "Physics Lecture", start: Fixture.instant(2026, 10, 6, 14, 0, in: zone), minutes: 90, in: zone,
            recurrence: RecurrenceRule(frequency: .weekly, until: until), excludedDates: excluded)
    }

    /// "Essay due", all day every Friday from 9 October 2026.
    private func essaySeries() -> Event {
        let friday = Fixture.day(2026, 10, 9)
        let weekly = RecurrenceRule(frequency: .weekly)
        return Fixture.allDay("Essay due", from: friday, through: friday, recurrence: weekly)
    }

    /// A one-hour event at 16:00 on `day` October that replaces the series' occurrence of `originalDay`.
    private func makeDetached(from series: Event, originalDay: Int, title: String, day: Int) -> Event {
        let start = Fixture.instant(2026, 10, day, 16, 0, in: zone)
        var event = Fixture.timed(title, start: start, minutes: 60, in: zone)
        event.detachedFrom = SeriesOccurrence(seriesID: series.id, date: Fixture.day(2026, 10, originalDay))
        return event
    }

    /// The occurrence of `event` on `day` October 2026.
    private func occurrence(of event: Event, on day: Int) throws -> Occurrence {
        try #require(expander.occurrence(of: event, on: Fixture.day(2026, 10, day)))
    }

    /// `occurrence` as the editor hands it back: its event with a new title and the occurrence's own
    /// timing, moved by `minutes`.
    private func edit(_ occurrence: Occurrence, title: String, movedBy minutes: Int = 0) -> Event {
        let shift = TimeInterval(minutes * 60)
        var copy = occurrence.event
        copy.title = title
        copy.timing = .timed(
            start: occurrence.start.addingTimeInterval(shift), end: occurrence.end.addingTimeInterval(shift),
            timeZone: zone)
        return copy
    }

    /// What the calendar shows from 1 October through 10 November 2026: "yyyy-MM-dd Title" per
    /// occurrence, in order.
    private func schedule(_ library: CalendarDocument) -> [String] {
        let range = Fixture.days(Fixture.day(2026, 10, 1), Fixture.day(2026, 11, 10), in: zone)
        return expander.occurrences(of: library.events, in: range).map { "\($0.date) \($0.event.title)" }
    }
}
