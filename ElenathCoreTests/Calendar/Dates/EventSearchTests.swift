import ElenathCore
import Foundation
import Testing

struct EventSearchTests {
    private typealias Fixture = DatesFixture

    private let zone = DatesFixture.amsterdam
    private let expander = OccurrenceExpander(displayTimeZone: DatesFixture.amsterdam)

    // MARK: - Matching

    @Test func matchingIgnoresCaseAndDiacritics() {
        let cafe = event("Study session at Café Noir")
        #expect(EventSearch.matches(cafe, query: "cafe"))
        #expect(EventSearch.matches(cafe, query: "CAFÉ"))
        #expect(EventSearch.matches(cafe, query: "noir"))
        #expect(EventSearch.matches(event("cafe meetup"), query: "Café"))
        #expect(!EventSearch.matches(cafe, query: "coffee"))
    }

    @Test func everyTermMustMatchSomewhere() {
        let lecture = event("Physics Lecture", location: "Room B204", notes: "Bring chapter 3 notes")
        #expect(EventSearch.matches(lecture, query: "physics lecture"))
        #expect(EventSearch.matches(lecture, query: "physics b204"))
        #expect(EventSearch.matches(lecture, query: "  chapter   PHYSICS  "))
        #expect(!EventSearch.matches(lecture, query: "physics chemistry"))
    }

    @Test func locationAndNotesAreSearched() {
        let lecture = event("Physics Lecture", location: "Room B204", notes: "Bring chapter 3 notes")
        #expect(EventSearch.matches(lecture, query: "b204"))
        #expect(EventSearch.matches(lecture, query: "chapter"))
        #expect(EventSearch.matches(lecture, query: "room"))
        #expect(!EventSearch.matches(lecture, query: "B205"))
    }

    @Test func termsMatchInsideWords() {
        let lecture = event("Linear Algebra")
        #expect(EventSearch.matches(lecture, query: "alg"))
        #expect(EventSearch.matches(lecture, query: "near"))
    }

    @Test func blankQueryMatchesEverythingButFindsNothing() {
        let lecture = event("Physics Lecture")
        #expect(EventSearch.matches(lecture, query: ""))
        #expect(EventSearch.matches(lecture, query: "   "))
        let library = CalendarDocument(events: [lecture])
        #expect(EventSearch.search(library, query: " ", now: Fixture.now, expander: expander).isEmpty)
    }

    // MARK: - Searching

    @Test func upcomingRowsComeFirstThenPastOnesMostRecentFirst() {
        // Now is Tuesday 6 October 2026, 13:50 in Amsterdam.
        let longAgo = event("Essay A", on: 20, of: 9)
        let lastWeek = event("Essay B", on: 1, of: 10)
        let thursday = event("Essay C", on: 8, of: 10)
        let tomorrow = event("Essay D", on: 7, of: 10)
        let unrelated = event("Physics Lecture", on: 7, of: 10)
        let library = CalendarDocument(events: [longAgo, thursday, unrelated, lastWeek, tomorrow])
        let found = EventSearch.search(library, query: "essay", now: Fixture.now, expander: expander)
        let titles = found.map { $0.event.title }
        #expect(titles == ["Essay D", "Essay C", "Essay B", "Essay A"])
    }

    @Test func repeatingEventShowsItsNextOccurrenceOnce() throws {
        // Tuesdays at 14:00 since 1 September; now is 13:50 on a Tuesday.
        let lecture = Fixture.timed(
            "Physics Lecture", start: Fixture.instant(2026, 9, 1, 14, 0, in: zone), minutes: 90, in: zone,
            recurrence: RecurrenceRule(frequency: .weekly))
        let library = CalendarDocument(events: [lecture])
        let found = EventSearch.search(library, query: "physics", now: Fixture.now, expander: expander)
        let row = try #require(found.first)
        #expect(found.count == 1)
        #expect(row.date == Fixture.day(2026, 10, 6))
        #expect(row.start == Fixture.instant(2026, 10, 6, 14, 0, in: zone))
    }

    @Test func occurrenceInProgressCountsAsUpcoming() throws {
        // 13:00–14:00 on the day; now is 13:50.
        let running = Fixture.timed(
            "Lab session", start: Fixture.instant(2026, 10, 6, 13, 0, in: zone), minutes: 60, in: zone)
        let past = event("Lab report", on: 5, of: 10)
        let library = CalendarDocument(events: [past, running])
        let found = EventSearch.search(library, query: "lab", now: Fixture.now, expander: expander)
        let titles = found.map { $0.event.title }
        #expect(titles == ["Lab session", "Lab report"])
    }

    @Test func finishedSeriesShowsItsLatestOccurrence() throws {
        // Tuesdays from 4 August through 15 September 2026.
        let summer = Fixture.timed(
            "Summer course", start: Fixture.instant(2026, 8, 4, 10, 0, in: zone), minutes: 60, in: zone,
            recurrence: RecurrenceRule(frequency: .weekly, until: Fixture.day(2026, 9, 15)))
        let library = CalendarDocument(events: [summer])
        let found = EventSearch.search(library, query: "summer", now: Fixture.now, expander: expander)
        let row = try #require(found.first)
        #expect(found.count == 1)
        #expect(row.date == Fixture.day(2026, 9, 15))
    }

    @Test func seriesThatStartedLongAgoShowsItsLatestOccurrence() throws {
        // Daily from 2015 through 2016: the search looks back far enough to find the last one.
        let old = Fixture.timed(
            "Old routine", start: Fixture.instant(2015, 3, 1, 7, 0, in: zone), minutes: 30, in: zone,
            recurrence: RecurrenceRule(frequency: .daily, until: Fixture.day(2016, 12, 31)))
        let library = CalendarDocument(events: [old])
        let found = EventSearch.search(library, query: "routine", now: Fixture.now, expander: expander)
        let row = try #require(found.first)
        #expect(row.date == Fixture.day(2016, 12, 31))
    }

    @Test func searchFindsAllDayEvents() {
        let friday = Fixture.day(2026, 10, 9)
        let birthday = Fixture.allDay("Mara's birthday", from: friday, through: friday)
        let library = CalendarDocument(events: [birthday, event("Birthday gift shopping", on: 8, of: 10)])
        let found = EventSearch.search(library, query: "birthday", now: Fixture.now, expander: expander)
        let titles = found.map { $0.event.title }
        #expect(titles == ["Birthday gift shopping", "Mara's birthday"])
    }

    // MARK: - Helpers

    private func event(_ title: String, location: String = "", notes: String = "") -> Event {
        let start = Fixture.instant(2026, 10, 6, 9, 0, in: zone)
        var made = Fixture.timed(title, start: start, minutes: 60, in: zone)
        made.location = location
        made.notes = notes
        return made
    }

    /// A one-hour event at 10:00 in Amsterdam on `day` of `month` 2026.
    private func event(_ title: String, on day: Int, of month: Int) -> Event {
        Fixture.timed(title, start: Fixture.instant(2026, month, day, 10, 0, in: zone), minutes: 60, in: zone)
    }
}
