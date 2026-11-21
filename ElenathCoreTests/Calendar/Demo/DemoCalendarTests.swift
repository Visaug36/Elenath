import ElenathCore
import Foundation
import Testing

struct DemoCalendarTests {
    private static let amsterdam = TimeZone(identifier: "Europe/Amsterdam")!
    private static let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private static let utc = TimeZone(identifier: "UTC")!

    /// Tuesday 6 October 2026, 13:50 in Amsterdam: the design's mock "now".
    private static let designNow = Date(timeIntervalSince1970: 1_791_287_400)

    /// The instant of a wall-clock time in `zone`.
    private static func instant(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        in zone: TimeZone
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        return calendar.date(from: parts)!
    }

    /// "2026-10-06 14:00-15:30 Physics Lecture" for timed events (in `zone`), "2026-10-14 all day Mara's
    /// birthday" for all-day ones.
    private static func describe(_ event: Event, in zone: TimeZone) -> String {
        switch event.timing {
        case .timed(let start, let end, _):
            let day = CalendarDate(start, in: zone).isoString
            return "\(day) \(clock(start, in: zone))-\(clock(end, in: zone)) \(event.title)"
        case .allDay(let first, let last):
            let days = first == last ? first.isoString : "\(first.isoString)...\(last.isoString)"
            return "\(days) all day \(event.title)"
        }
    }

    private static func clock(_ instant: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: instant)
        return String(format: "%02d:%02d", parts.hour ?? -1, parts.minute ?? -1)
    }

    private static func designLibrary() -> CalendarDocument {
        DemoCalendar.make(weekContaining: designNow, timeZone: amsterdam)
    }

    // MARK: - Subjects

    @Test func hasTheDesignsFiveSubjects() {
        let library = Self.designLibrary()
        #expect(library.subjects.map(\.name) == ["Physics", "Linear Algebra", "Literature", "Biology", "Personal"])
        let colors: [SubjectColor] = [
            .palette(.clay),
            .palette(.teal),
            .palette(.iris),
            .palette(.fern),
            .palette(.rose),
        ]
        #expect(library.subjects.map(\.color) == colors)
        #expect(library.subjects.map(\.keywords) == [["phys"], ["linalg", "algebra"], ["lit"], ["bio"], []])
        #expect(Set(library.subjects.map(\.id)).count == 5)
    }

    @Test func everyEventHasAKnownSubjectAndAUniqueID() {
        let library = Self.designLibrary()
        #expect(library.events.count == 21)
        for event in library.events {
            #expect(library.subject(withID: event.subjectID) != nil, "\(event.title) has no subject")
        }
        #expect(Set(library.events.map(\.id)).count == library.events.count)
    }

    // MARK: - The design's week

    @Test func physicsLecturesRepeatWeeklyInRoomB204() throws {
        let library = Self.designLibrary()
        let physics = try #require(library.subjects.first { $0.name == "Physics" })
        let lectures = library.events.filter { $0.title == "Physics Lecture" }
        #expect(lectures.count == 2)
        for lecture in lectures {
            #expect(lecture.location == "Room B204")
            #expect(lecture.recurrence == RecurrenceRule(frequency: .weekly))
            #expect(lecture.alert == .tenMinutes)
            #expect(lecture.subjectID == physics.id)
        }
        let described = lectures.map { Self.describe($0, in: Self.amsterdam) }
        #expect(described == ["2026-10-06 14:00-15:30 Physics Lecture", "2026-10-08 14:00-15:30 Physics Lecture"])
    }

    @Test func weeklyClassesStartInTheWeekOfNow() {
        let library = Self.designLibrary()
        let weekly = library.events.filter { $0.repeats }
        for event in weekly {
            #expect(event.recurrence == RecurrenceRule(frequency: .weekly))
            #expect(event.excludedDates.isEmpty)
        }
        let described = weekly.map { Self.describe($0, in: Self.amsterdam) }.sorted()
        let expected = [
            "2026-10-05 09:00-10:30 Linear Algebra",
            "2026-10-05 13:00-15:00 Biology Lab",
            "2026-10-06 14:00-15:30 Physics Lecture",
            "2026-10-07 09:00-10:30 Linear Algebra",
            "2026-10-07 15:00-17:00 Biology Lab",
            "2026-10-08 14:00-15:30 Physics Lecture",
            "2026-10-09 09:00-10:30 Linear Algebra",
            "2026-10-09 11:00-12:30 Literature Seminar",
        ]
        #expect(described == expected)
        let algebra = weekly.filter { $0.title == "Linear Algebra" }
        #expect(algebra.allSatisfy { $0.location == "Hall A" })
        let labs = weekly.filter { $0.title == "Biology Lab" }
        #expect(labs.allSatisfy { $0.location == "Lab 3" })
    }

    @Test func oneOffEventsFallOnTheRightDaysAndTimes() {
        let library = Self.designLibrary()
        let described = library.events.filter { !$0.repeats }.map { Self.describe($0, in: Self.amsterdam) }.sorted()
        let expected = [
            "2026-10-05 16:30-17:30 Study group",
            "2026-10-06 09:30-10:45 Literature Seminar",
            "2026-10-06 17:00-18:30 Library: essay draft",
            "2026-10-07 12:00-13:00 Lunch with Mara",
            "2026-10-08 10:00-11:00 Physics Quiz",
            "2026-10-09 15:00-16:00 Office hours",
            "2026-10-10 10:00-12:00 Study group",
            "2026-10-11 16:00-17:00 Weekly review",
            "2026-10-14 all day Mara's birthday",
            "2026-10-16 all day Essay due",
            "2026-10-21 10:00-12:00 Midterm",
            "2026-10-29 all day Lab report due",
            "2026-10-31 20:00-23:00 Halloween at the observatory",
        ]
        #expect(described == expected)
    }

    @Test func eventsCarryTheDesignsDetails() throws {
        let library = Self.designLibrary()
        let quiz = try #require(library.events.first { $0.title == "Physics Quiz" })
        #expect(quiz.location == "Room B204")
        #expect(quiz.notes == "Chapters 4–5. Bring the calculator.")
        #expect(quiz.alert == .tenMinutes)
        #expect(library.subject(withID: quiz.subjectID)?.name == "Physics")

        let subjectNames = library.events.map { event in
            "\(event.title): \(library.subject(withID: event.subjectID)?.name ?? "none")"
        }
        #expect(subjectNames.contains("Office hours: Linear Algebra"))
        #expect(subjectNames.contains("Library: essay draft: Literature"))
        #expect(subjectNames.contains("Lab report due: Biology"))
        #expect(subjectNames.contains("Mara's birthday: Personal"))
        #expect(subjectNames.contains("Midterm: Linear Algebra"))
    }

    @Test func timedEventsUseTheGivenTimeZoneAndHaveAnAlert() {
        for zone in [Self.amsterdam, Self.tokyo] {
            let library = DemoCalendar.make(weekContaining: Self.designNow, timeZone: zone)
            for event in library.events {
                if event.isAllDay {
                    #expect(event.alert == nil)
                } else {
                    #expect(event.timing.timeZone?.identifier == zone.identifier)
                    #expect(event.alert == .tenMinutes)
                }
            }
        }
    }

    // MARK: - Placing the week

    @Test func weekStartsOnTheMondayOfNow() {
        let sundayNight = Self.instant(2026, 10, 11, 23, 30, in: Self.amsterdam)
        let mondayMorning = Self.instant(2026, 10, 5, 0, 10, in: Self.amsterdam)
        for now in [sundayNight, mondayMorning, Self.designNow] {
            let library = DemoCalendar.make(weekContaining: now, timeZone: Self.amsterdam)
            #expect(library == Self.designLibrary())
        }
    }

    @Test func weekFollowsTheGivenTimeZone() throws {
        // Sunday 11 October 2026, 20:00 UTC is already Monday 12 October, 05:00 in Tokyo.
        let now = Self.instant(2026, 10, 11, 20, 0, in: Self.utc)
        let utcLibrary = DemoCalendar.make(weekContaining: now, timeZone: Self.utc)
        let tokyoLibrary = DemoCalendar.make(weekContaining: now, timeZone: Self.tokyo)
        let utcLecture = try #require(utcLibrary.events.first { $0.title == "Physics Lecture" })
        let tokyoLecture = try #require(tokyoLibrary.events.first { $0.title == "Physics Lecture" })
        #expect(Self.describe(utcLecture, in: Self.utc) == "2026-10-06 14:00-15:30 Physics Lecture")
        #expect(Self.describe(tokyoLecture, in: Self.tokyo) == "2026-10-13 14:00-15:30 Physics Lecture")
    }

    @Test func wallClockTimesHoldAcrossTheDSTChange() throws {
        // Amsterdam leaves summer time on Sunday 25 October 2026.
        let now = Self.instant(2026, 10, 27, 9, 0, in: Self.amsterdam)
        let library = DemoCalendar.make(weekContaining: now, timeZone: Self.amsterdam)
        let lecture = try #require(library.events.first { $0.title == "Physics Lecture" })
        #expect(Self.describe(lecture, in: Self.amsterdam) == "2026-10-27 14:00-15:30 Physics Lecture")
        guard case .timed(let start, let end, _) = lecture.timing else {
            Issue.record("The lecture should be a timed event")
            return
        }
        #expect(end.timeIntervalSince(start) == 90 * 60)
    }

    /// Ithil's demo always called it Halloween; Elenath's demo week is in November, where a Halloween on a
    /// Saturday in December looked like a mistake, so away from October 31 it is a night at the observatory.
    @Test func theObservatoryEveningIsOnHalloweenOrOnASaturdayWhenOctober31IsFarAway() throws {
        let cases: [(now: Date, expected: String)] = [
            (Self.designNow, "2026-10-31 20:00-23:00 Halloween at the observatory"),
            (
                Self.instant(2026, 10, 1, 12, 0, in: Self.amsterdam),
                "2026-10-31 20:00-23:00 Halloween at the observatory"
            ),
            (Self.instant(2026, 9, 1, 12, 0, in: Self.amsterdam), "2026-09-26 20:00-23:00 Night at the observatory"),
            (Self.instant(2026, 12, 2, 12, 0, in: Self.amsterdam), "2026-12-26 20:00-23:00 Night at the observatory"),
        ]
        for (now, expected) in cases {
            let library = DemoCalendar.make(weekContaining: now, timeZone: Self.amsterdam)
            let evening = try #require(library.events.first { $0.title.hasSuffix("at the observatory") })
            #expect(Self.describe(evening, in: Self.amsterdam) == expected)
        }
    }

    // MARK: - Stability

    @Test func idsAreStableAcrossCalls() {
        let first = Self.designLibrary()
        let second = Self.designLibrary()
        #expect(first == second)

        let laterNow = Self.instant(2027, 3, 15, 9, 0, in: Self.tokyo)
        let later = DemoCalendar.make(weekContaining: laterNow, timeZone: Self.tokyo)
        #expect(later.id == first.id)
        #expect(later.subjects == first.subjects)
        #expect(later.events.map(\.id) == first.events.map(\.id))
        #expect(later.events.map(\.subjectID) == first.events.map(\.subjectID))
    }
}
