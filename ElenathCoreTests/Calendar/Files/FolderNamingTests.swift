import ElenathCore
import Foundation
import Testing

/// Fixed time zones and events for the folder-naming tests. Nothing reads the Mac's clock or time zone.
private enum FolderNamingFixture {
    static let amsterdam = TimeZone(identifier: "Europe/Amsterdam")!
    static let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    static let newYork = TimeZone(identifier: "America/New_York")!
    static let created = Date(timeIntervalSince1970: 1_788_220_800)

    static func day(_ year: Int, _ month: Int, _ day: Int) -> CalendarDate {
        CalendarDate(year: year, month: month, day: day)
    }

    static func instant(_ day: CalendarDate, _ hour: Int, _ minute: Int, in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = DateComponents(year: day.year, month: day.month, day: day.day, hour: hour, minute: minute)
        return calendar.date(from: parts)!
    }

    static func timed(
        _ title: String,
        on day: CalendarDate,
        at hour: Int,
        _ minute: Int,
        in timeZone: TimeZone,
        recurrence: RecurrenceRule? = nil
    ) -> Event {
        let start = instant(day, hour, minute, in: timeZone)
        return Event(
            title: title,
            timing: .timed(start: start, end: start.addingTimeInterval(90 * 60), timeZone: timeZone),
            recurrence: recurrence,
            createdAt: created)
    }

    static func allDay(_ title: String, from first: CalendarDate, through last: CalendarDate) -> Event {
        Event(title: title, timing: .allDay(start: first, end: last), createdAt: created)
    }

    /// The occurrence of `event` on `date`, placed for a Mac in `displayTimeZone`.
    static func occurrence(of event: Event, on date: CalendarDate, displayedIn zone: TimeZone) -> Occurrence {
        OccurrenceExpander(displayTimeZone: zone).occurrence(of: event, on: date)!
    }
}

struct FolderNamingTests {
    private typealias Fixture = FolderNamingFixture

    // MARK: - Sanitizing

    @Test func slashesAndColonsBecomeHyphens() {
        #expect(FolderNaming.sanitizedTitle("Physics 1/2: Waves") == "Physics 1-2- Waves")
        #expect(FolderNaming.sanitizedTitle("a/b/c") == "a-b-c")
        #expect(FolderNaming.sanitizedTitle("10:30 review") == "10-30 review")
    }

    @Test func leadingDotsAreRemovedSoTheFolderIsNeverHidden() {
        #expect(FolderNaming.sanitizedTitle(".hidden") == "hidden")
        #expect(FolderNaming.sanitizedTitle("...notes") == "notes")
        #expect(FolderNaming.sanitizedTitle(". . . spaced") == "spaced")
        #expect(FolderNaming.sanitizedTitle("  .indented") == "indented")
        #expect(FolderNaming.sanitizedTitle(".\u{0301}combined") == "combined")
        #expect(FolderNaming.sanitizedTitle("Chapter 1.2 notes") == "Chapter 1.2 notes")
    }

    @Test func nothingLeftGivesTheFallbackTitle() {
        #expect(FolderNaming.fallbackTitle == "Event")
        #expect(FolderNaming.sanitizedTitle("") == "Event")
        #expect(FolderNaming.sanitizedTitle(".") == "Event")
        #expect(FolderNaming.sanitizedTitle("..") == "Event")
        #expect(FolderNaming.sanitizedTitle(". .") == "Event")
        #expect(FolderNaming.sanitizedTitle("   ") == "Event")
        #expect(FolderNaming.sanitizedTitle("\n\t\r") == "Event")
    }

    @Test func trailingDotsAndSpacesAreRemoved() {
        #expect(FolderNaming.sanitizedTitle("Essay due...") == "Essay due")
        #expect(FolderNaming.sanitizedTitle("Lab . ") == "Lab")
        #expect(FolderNaming.sanitizedTitle("v1.0 release.") == "v1.0 release")
    }

    @Test func controlCharactersAndLineBreaksBecomeSpaces() {
        #expect(FolderNaming.sanitizedTitle("Lab\nReport") == "Lab Report")
        #expect(FolderNaming.sanitizedTitle("Lab\r\nReport") == "Lab Report")
        #expect(FolderNaming.sanitizedTitle("Tab\tSeparated") == "Tab Separated")
        #expect(FolderNaming.sanitizedTitle("Null\u{0}Byte") == "Null Byte")
        #expect(FolderNaming.sanitizedTitle("Bell\u{7}Ring") == "Bell Ring")
        #expect(FolderNaming.sanitizedTitle("Delete\u{7F}Key") == "Delete Key")
        #expect(FolderNaming.sanitizedTitle("Line\u{2028}Separator") == "Line Separator")
        #expect(FolderNaming.sanitizedTitle("Paragraph\u{2029}Separator") == "Paragraph Separator")
        #expect(FolderNaming.sanitizedTitle("\u{1B}[31mEscaped") == "[31mEscaped")
    }

    @Test func whitespaceRunsCollapseAndEndsAreTrimmed() {
        #expect(FolderNaming.sanitizedTitle("  Physics    Lecture  ") == "Physics Lecture")
        #expect(FolderNaming.sanitizedTitle("Non\u{A0}\u{A0}breaking") == "Non breaking")
        #expect(FolderNaming.sanitizedTitle("a \n\t b") == "a b")
    }

    @Test func ordinaryTitlesAreKeptAsTyped() {
        #expect(FolderNaming.sanitizedTitle("Mara's birthday 🎂") == "Mara's birthday 🎂")
        #expect(FolderNaming.sanitizedTitle("Café ☕️ with Ana") == "Café ☕️ with Ana")
        #expect(FolderNaming.sanitizedTitle("数学の授業") == "数学の授業")
        #expect(FolderNaming.sanitizedTitle("Q&A (week 6) – #1, 50%!") == "Q&A (week 6) – #1, 50%!")
        let family = "👩‍👩‍👧‍👦 Family dinner"
        #expect(FolderNaming.sanitizedTitle(family) == family)
    }

    // MARK: - Length

    @Test func longTitlesAreCutToEightyCharacters() {
        #expect(FolderNaming.maximumTitleLength == 80)
        let result = FolderNaming.sanitizedTitle(String(repeating: "a", count: 100))
        #expect(result == String(repeating: "a", count: 80))
    }

    @Test func cuttingKeepsAnEmojiAtTheLimitWhole() {
        let family: Character = "👩‍👩‍👧‍👦"
        let thumbs: Character = "👍🏽"
        let first = FolderNaming.sanitizedTitle(String(repeating: "a", count: 79) + String(family) + "bcd")
        #expect(first.count == 80)
        #expect(first.last == family)
        #expect(first.unicodeScalars.count == 86)

        let second = FolderNaming.sanitizedTitle(String(repeating: "b", count: 79) + String(thumbs) + "!")
        #expect(second.count == 80)
        #expect(second.last == thumbs)
    }

    @Test func cuttingKeepsCombiningCharactersWithTheirLetters() {
        let accented = "e\u{0301}"
        let result = FolderNaming.sanitizedTitle(String(repeating: accented, count: 90))
        #expect(result.count == 80)
        #expect(result.unicodeScalars.count == 160)
        #expect(result == String(repeating: accented, count: 80))
    }

    @Test func cuttingTrimsWhatEndsUpAtTheEnd() {
        let spaced = String(repeating: "a", count: 79) + " b"
        #expect(FolderNaming.sanitizedTitle(spaced) == String(repeating: "a", count: 79))
        let dotted = String(repeating: "c", count: 78) + ". d"
        #expect(FolderNaming.sanitizedTitle(dotted) == String(repeating: "c", count: 78))
    }

    @Test func wideCharactersStayWithinTheFileNameLimit() {
        // A folder name is "HH.mm " + title + at most " 999", and a file name holds 255 bytes.
        let prefixAndSuffixBytes = "14.00 ".utf8.count + " 999".utf8.count
        let moons = FolderNaming.sanitizedTitle(String(repeating: "🌙", count: 80))
        let onlyMoons = moons.allSatisfy { $0 == "🌙" }
        #expect(!moons.isEmpty)
        #expect(moons.count <= 80)
        #expect(onlyMoons)
        #expect(moons.utf8.count <= 255 - prefixAndSuffixBytes)

        // One Hangul syllable spelled as three jamo: one Character, nine bytes.
        let syllable = "\u{1112}\u{1161}\u{11AB}"
        let hangul = FolderNaming.sanitizedTitle(String(repeating: syllable, count: 80))
        #expect(!hangul.isEmpty)
        #expect(hangul.unicodeScalars.count % 3 == 0)
        #expect(hangul == String(repeating: syllable, count: hangul.unicodeScalars.count / 3))
        #expect(hangul.utf8.count <= 255 - prefixAndSuffixBytes)
    }

    // MARK: - Folder names

    @Test func timedFoldersUseTheEventsOwnTimeZone() {
        // A 14:00 lecture in Amsterdam, on a Mac set to Tokyo (where it is 21:00).
        let lecture = Fixture.timed("Physics Lecture", on: Fixture.day(2026, 10, 6), at: 14, 0, in: Fixture.amsterdam)
        let occurrence = Fixture.occurrence(of: lecture, on: Fixture.day(2026, 10, 6), displayedIn: Fixture.tokyo)
        #expect(FolderNaming.dayFolderName(for: occurrence) == "2026-10-06")
        #expect(FolderNaming.eventFolderName(for: occurrence) == "14.00 Physics Lecture")
        #expect(FolderNaming.relativePath(for: occurrence) == "2026-10-06/14.00 Physics Lecture")
    }

    @Test func lateEventsKeepTheirOwnDay() {
        // 20:05 in Amsterdam on 6 October is already 03:05 on 7 October in Tokyo.
        let study = Fixture.timed("Study Group", on: Fixture.day(2026, 10, 6), at: 20, 5, in: Fixture.amsterdam)
        let occurrence = Fixture.occurrence(of: study, on: Fixture.day(2026, 10, 6), displayedIn: Fixture.tokyo)
        #expect(FolderNaming.relativePath(for: occurrence) == "2026-10-06/20.05 Study Group")
    }

    @Test func timesAreTwentyFourHourAndZeroPadded() {
        let cases: [(hour: Int, minute: Int, prefix: String)] = [
            (0, 0, "00.00"),
            (9, 5, "09.05"),
            (12, 30, "12.30"),
            (23, 59, "23.59"),
        ]
        for (hour, minute, prefix) in cases {
            let event = Fixture.timed("Lab", on: Fixture.day(2026, 10, 7), at: hour, minute, in: Fixture.newYork)
            let occurrence = Fixture.occurrence(of: event, on: Fixture.day(2026, 10, 7), displayedIn: Fixture.tokyo)
            #expect(FolderNaming.eventFolderName(for: occurrence) == "\(prefix) Lab")
            #expect(FolderNaming.dayFolderName(for: occurrence) == "2026-10-07")
        }
    }

    @Test func allDayFoldersHaveNoTimePrefix() {
        let day = Fixture.day(2026, 10, 14)
        let birthday = Fixture.allDay("Mara's birthday", from: day, through: day)
        for zone in [Fixture.amsterdam, Fixture.tokyo, Fixture.newYork] {
            let occurrence = Fixture.occurrence(of: birthday, on: day, displayedIn: zone)
            #expect(FolderNaming.dayFolderName(for: occurrence) == "2026-10-14")
            #expect(FolderNaming.eventFolderName(for: occurrence) == "Mara's birthday")
            #expect(FolderNaming.relativePath(for: occurrence) == "2026-10-14/Mara's birthday")
        }
    }

    @Test func multiDayAllDayEventsUseTheirFirstDay() {
        let trip = Fixture.allDay("Field Trip", from: Fixture.day(2026, 10, 9), through: Fixture.day(2026, 10, 11))
        let occurrence = Fixture.occurrence(of: trip, on: Fixture.day(2026, 10, 9), displayedIn: Fixture.newYork)
        #expect(FolderNaming.relativePath(for: occurrence) == "2026-10-09/Field Trip")
    }

    @Test func titlesAreSanitizedInFolderNames() {
        let lab = Fixture.timed("Lab: Optics/Lenses", on: Fixture.day(2026, 10, 8), at: 9, 0, in: Fixture.amsterdam)
        let labOccurrence = Fixture.occurrence(of: lab, on: Fixture.day(2026, 10, 8), displayedIn: Fixture.amsterdam)
        #expect(FolderNaming.eventFolderName(for: labOccurrence) == "09.00 Lab- Optics-Lenses")

        let untitled = Fixture.timed("  ", on: Fixture.day(2026, 10, 8), at: 9, 0, in: Fixture.amsterdam)
        let untitledOccurrence = Fixture.occurrence(
            of: untitled, on: Fixture.day(2026, 10, 8), displayedIn: Fixture.amsterdam)
        #expect(FolderNaming.eventFolderName(for: untitledOccurrence) == "09.00 Event")

        let hidden = Fixture.allDay("..", from: Fixture.day(2026, 10, 8), through: Fixture.day(2026, 10, 8))
        let hiddenOccurrence = Fixture.occurrence(of: hidden, on: Fixture.day(2026, 10, 8), displayedIn: Fixture.tokyo)
        #expect(FolderNaming.relativePath(for: hiddenOccurrence) == "2026-10-08/Event")
    }

    @Test func eachRepeatingOccurrenceGetsItsOwnPath() {
        // Weekly at 14:00 in Amsterdam, across the end of summer time on 25 October.
        let weekly = RecurrenceRule(frequency: .weekly)
        let lecture = Fixture.timed(
            "Physics Lecture", on: Fixture.day(2026, 10, 6), at: 14, 0, in: Fixture.amsterdam, recurrence: weekly)
        let october = DateInterval(
            start: Fixture.day(2026, 10, 1).start(in: Fixture.amsterdam),
            end: Fixture.day(2026, 11, 1).start(in: Fixture.amsterdam))
        let occurrences = OccurrenceExpander(displayTimeZone: Fixture.tokyo).occurrences(of: lecture, in: october)
        let paths = occurrences.map { FolderNaming.relativePath(for: $0) }
        let expected = [
            "2026-10-06/14.00 Physics Lecture",
            "2026-10-13/14.00 Physics Lecture",
            "2026-10-20/14.00 Physics Lecture",
            "2026-10-27/14.00 Physics Lecture",
        ]
        #expect(paths == expected)
    }
}
