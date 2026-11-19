import Foundation

/// The design's sample data, for the `-demo` launch argument, screenshots and tests. It is never
/// mixed with the user's own library.
public enum DemoCalendar {
    /// The design's five subjects and their events, placed in the Monday-start week that contains `now`
    /// in `timeZone`, plus a few deadlines in the weeks after it. Weekly classes repeat forever, and timed
    /// events have a 10-minute alert. Every ID is fixed, so equal arguments give equal libraries and the
    /// IDs are the same for every week.
    public static func make(weekContaining now: Date, timeZone: TimeZone) -> CalendarDocument {
        let today = CalendarDate(now, in: timeZone)
        let monday = today.adding(days: -((today.weekday + 5) % 7))

        let physics = fixedID(1, 1)
        let algebra = fixedID(1, 2)
        let literature = fixedID(1, 3)
        let biology = fixedID(1, 4)
        let personal = fixedID(1, 5)
        let subjects = [
            Subject(id: physics, name: "Physics", color: .palette(.clay), keywords: ["phys"]),
            Subject(id: algebra, name: "Linear Algebra", color: .palette(.teal), keywords: ["linalg", "algebra"]),
            Subject(id: literature, name: "Literature", color: .palette(.iris), keywords: ["lit"]),
            Subject(id: biology, name: "Biology", color: .palette(.fern), keywords: ["bio"]),
            Subject(id: personal, name: "Personal", color: .palette(.rose)),
        ]

        let hall = "Hall A"
        let lab = "Lab 3"
        let room = "Room B204"
        let quizNotes = "Chapters 4–5. Bring the calculator."
        let halloween = CalendarDate(year: monday.year, month: 10, day: 31)
        let daysToHalloween = monday.days(to: halloween)
        let halloweenDay = (0..<5 * 7).contains(daysToHalloween) ? daysToHalloween : 3 * 7 + 5

        var schedule = Schedule(monday: monday, timeZone: timeZone, createdAt: monday.start(in: timeZone))
        // The week on screen. Day 0 is Monday.
        schedule.timed(1, "Linear Algebra", algebra, day: 0, (9, 0), (10, 30), weekly: true, location: hall)
        schedule.timed(2, "Linear Algebra", algebra, day: 2, (9, 0), (10, 30), weekly: true, location: hall)
        schedule.timed(3, "Linear Algebra", algebra, day: 4, (9, 0), (10, 30), weekly: true, location: hall)
        schedule.timed(4, "Biology Lab", biology, day: 0, (13, 0), (15, 0), weekly: true, location: lab)
        schedule.timed(5, "Biology Lab", biology, day: 2, (15, 0), (17, 0), weekly: true, location: lab)
        schedule.timed(6, "Study group", personal, day: 0, (16, 30), (17, 30))
        schedule.timed(7, "Literature Seminar", literature, day: 1, (9, 30), (10, 45))
        schedule.timed(8, "Literature Seminar", literature, day: 4, (11, 0), (12, 30), weekly: true)
        schedule.timed(9, "Physics Lecture", physics, day: 1, (14, 0), (15, 30), weekly: true, location: room)
        schedule.timed(10, "Physics Lecture", physics, day: 3, (14, 0), (15, 30), weekly: true, location: room)
        schedule.timed(11, "Library: essay draft", literature, day: 1, (17, 0), (18, 30))
        schedule.timed(12, "Lunch with Mara", personal, day: 2, (12, 0), (13, 0))
        schedule.timed(13, "Physics Quiz", physics, day: 3, (10, 0), (11, 0), location: room, notes: quizNotes)
        schedule.timed(14, "Office hours", algebra, day: 4, (15, 0), (16, 0))
        schedule.timed(15, "Study group", personal, day: 5, (10, 0), (12, 0))
        schedule.timed(16, "Weekly review", personal, day: 6, (16, 0), (17, 0))
        // The weeks after it.
        schedule.allDay(17, "Mara's birthday", personal, day: 7 + 2)
        schedule.allDay(18, "Essay due", literature, day: 7 + 4)
        schedule.timed(19, "Midterm", algebra, day: 2 * 7 + 2, (10, 0), (12, 0))
        schedule.allDay(20, "Lab report due", biology, day: 3 * 7 + 3)
        schedule.timed(21, "Halloween at the observatory", personal, day: halloweenDay, (20, 0), (23, 0))

        return CalendarDocument(id: fixedID(0, 1), subjects: subjects, events: schedule.events)
    }

    /// A fixed, valid version 4 UUID: 4954484C-DE30-4000-8000-00000000GGNN (group GG, number NN).
    private static func fixedID(_ group: UInt8, _ number: UInt8) -> UUID {
        UUID(uuid: (0x49, 0x54, 0x48, 0x4C, 0xDE, 0x30, 0x40, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, group, number))
    }

    /// Collects the demo events of one week.
    private struct Schedule {
        let monday: CalendarDate
        let timeZone: TimeZone
        let createdAt: Date
        var events: [Event] = []

        /// A timed event on `day` days after Monday, from `start` to `end` wall-clock time.
        mutating func timed(
            _ number: UInt8,
            _ title: String,
            _ subjectID: UUID,
            day: Int,
            _ start: (hour: Int, minute: Int),
            _ end: (hour: Int, minute: Int),
            weekly: Bool = false,
            location: String = "",
            notes: String = ""
        ) {
            let date = monday.adding(days: day)
            let startInstant = instant(on: date, at: start)
            let endInstant = instant(on: date, at: end)
            let event = Event(
                id: DemoCalendar.fixedID(2, number),
                title: title,
                timing: .timed(start: startInstant, end: endInstant, timeZone: timeZone),
                subjectID: subjectID,
                location: location,
                notes: notes,
                alert: .tenMinutes,
                recurrence: weekly ? RecurrenceRule(frequency: .weekly) : nil,
                createdAt: createdAt)
            events.append(event)
        }

        /// A one-day all-day event on `day` days after Monday.
        mutating func allDay(_ number: UInt8, _ title: String, _ subjectID: UUID, day: Int) {
            let date = monday.adding(days: day)
            let event = Event(
                id: DemoCalendar.fixedID(2, number),
                title: title,
                timing: .allDay(start: date, end: date),
                subjectID: subjectID,
                createdAt: createdAt)
            events.append(event)
        }

        /// The instant of a wall-clock time on `date` in the schedule's time zone. A time inside a DST gap
        /// moves forward, as `Calendar` resolves it.
        private func instant(on date: CalendarDate, at time: (hour: Int, minute: Int)) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            var parts = DateComponents(year: date.year, month: date.month, day: date.day)
            parts.hour = time.hour
            parts.minute = time.minute
            return calendar.date(from: parts) ?? date.start(in: timeZone)
        }
    }
}
