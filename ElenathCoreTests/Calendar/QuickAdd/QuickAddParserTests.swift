import ElenathCore
import Foundation
import Testing

// Finding dates in text needs Apple's Foundation (NSDataDetector): these run on CI's Macs.
#if canImport(Darwin)
    /// Quick Add parsing of text without dates or times, so nothing here depends on the Mac's clock, time
    /// zone or locale. The tests that go through NSDataDetector are in QuickAddDateDetectionTests.
    struct QuickAddParserTests {
        private typealias Fixture = QuickAddFixture

        private let tokyoParser = QuickAddFixture.parser(timeZone: QuickAddFixture.tokyo)

        // MARK: - Blank input and no date

        @Test func blankInputGivesNoDraft() {
            #expect(tokyoParser.parse("", now: Fixture.fixedNow) == nil)
            #expect(tokyoParser.parse("   ", now: Fixture.fixedNow) == nil)
            #expect(tokyoParser.parse(" \n\t ", now: Fixture.fixedNow) == nil)
        }

        @Test func noDateMeansAllDayTodayInTheParsersTimeZone() throws {
            let tokyoDraft = try #require(tokyoParser.parse("call mom", now: Fixture.fixedNow))
            let tokyoToday = CalendarDate(year: 2026, month: 10, day: 7)
            #expect(tokyoDraft.timing == .allDay(start: tokyoToday, end: tokyoToday))
            #expect(!tokyoDraft.hasDate)
            #expect(!tokyoDraft.hasTime)
            #expect(tokyoDraft.highlightedRanges.isEmpty)
            #expect(tokyoDraft.alert == nil)
            #expect(tokyoDraft.title == "Call Mom")

            let newYorkParser = Fixture.parser(timeZone: Fixture.newYork)
            let newYorkDraft = try #require(newYorkParser.parse("call mom", now: Fixture.fixedNow))
            let newYorkToday = CalendarDate(year: 2026, month: 10, day: 6)
            #expect(newYorkDraft.timing == .allDay(start: newYorkToday, end: newYorkToday))
        }

        // MARK: - Subjects

        @Test func subjectNameMatchesAsTyped() throws {
            let draft = try #require(tokyoParser.parse("physics homework", now: Fixture.fixedNow))
            #expect(draft.subjectID == Fixture.physics.id)
            #expect(draft.matchedKeyword == "physics")
            #expect(draft.title == "Physics Homework")

            let shouted = try #require(tokyoParser.parse("PHYSICS exam", now: Fixture.fixedNow))
            #expect(shouted.subjectID == Fixture.physics.id)
            #expect(shouted.matchedKeyword == "PHYSICS")
        }

        @Test func keywordsMatchTheirSubject() throws {
            let bio = try #require(tokyoParser.parse("bio lab", now: Fixture.fixedNow))
            #expect(bio.subjectID == Fixture.biology.id)
            #expect(bio.matchedKeyword == "bio")
            #expect(bio.title == "Bio Lab")

            let linalg = try #require(tokyoParser.parse("linalg problem set", now: Fixture.fixedNow))
            #expect(linalg.subjectID == Fixture.linearAlgebra.id)
            #expect(linalg.matchedKeyword == "linalg")
        }

        @Test func subjectsMatchWholeWordsOnly() throws {
            let therapy = try #require(tokyoParser.parse("physical therapy", now: Fixture.fixedNow))
            #expect(therapy.subjectID == nil)
            #expect(therapy.matchedKeyword == nil)
            #expect(therapy.title == "Physical Therapy")

            let biome = try #require(tokyoParser.parse("biome walk, literally", now: Fixture.fixedNow))
            #expect(biome.subjectID == nil)

            let punctuated = try #require(tokyoParser.parse("notes (phys)", now: Fixture.fixedNow))
            #expect(punctuated.subjectID == Fixture.physics.id)
            #expect(punctuated.matchedKeyword == "phys")
        }

        @Test func longestMatchWins() throws {
            let linear = Subject(name: "Linear", color: .palette(.clay))
            for subjects in [[linear, Fixture.linearAlgebra], [Fixture.linearAlgebra, linear]] {
                let parser = Fixture.parser(subjects: subjects, timeZone: Fixture.tokyo)
                let draft = try #require(parser.parse("linear algebra review", now: Fixture.fixedNow))
                #expect(draft.subjectID == Fixture.linearAlgebra.id)
                #expect(draft.matchedKeyword == "linear algebra")
                #expect(draft.title == "Linear Algebra Review")
            }
            let bothParser = Fixture.parser(subjects: [linear, Fixture.linearAlgebra], timeZone: Fixture.tokyo)
            let onlyLinear = try #require(bothParser.parse("linear regression", now: Fixture.fixedNow))
            #expect(onlyLinear.subjectID == linear.id)
            #expect(onlyLinear.matchedKeyword == "linear")
        }

        @Test func multiWordNamesMatchAcrossExtraSpaces() throws {
            let draft = try #require(tokyoParser.parse("linear    algebra", now: Fixture.fixedNow))
            #expect(draft.subjectID == Fixture.linearAlgebra.id)
            #expect(draft.matchedKeyword == "linear algebra")
            #expect(draft.title == "Linear Algebra")
        }

        @Test func equallyLongMatchesPreferTheFirstInTheText() throws {
            let bioFirst = try #require(tokyoParser.parse("bio notes for lit class", now: Fixture.fixedNow))
            #expect(bioFirst.subjectID == Fixture.biology.id)
            #expect(bioFirst.matchedKeyword == "bio")

            let litFirst = try #require(tokyoParser.parse("lit notes for bio class", now: Fixture.fixedNow))
            #expect(litFirst.subjectID == Fixture.literature.id)
            #expect(litFirst.matchedKeyword == "lit")
        }

        @Test func matchingIgnoresCaseAndDiacritics() throws {
            let biologia = Subject(name: "Biología", color: .palette(.fern))
            let parser = Fixture.parser(subjects: [biologia], timeZone: Fixture.tokyo)

            let plain = try #require(parser.parse("biologia homework", now: Fixture.fixedNow))
            #expect(plain.subjectID == biologia.id)
            #expect(plain.matchedKeyword == "biologia")

            let accented = try #require(parser.parse("BIOLOGÍA homework", now: Fixture.fixedNow))
            #expect(accented.subjectID == biologia.id)
            #expect(accented.matchedKeyword == "BIOLOGÍA")
            #expect(accented.title == "BIOLOGÍA homework")

            let cafe = Subject(name: "Cafe", color: .palette(.rose))
            let reverse = Fixture.parser(subjects: [cafe], timeZone: Fixture.tokyo)
            let typed = try #require(reverse.parse("café with friends", now: Fixture.fixedNow))
            #expect(typed.subjectID == cafe.id)
            #expect(typed.matchedKeyword == "café")
        }

        @Test func noSubjectsMeansNoMatch() throws {
            let parser = Fixture.parser(subjects: [], timeZone: Fixture.tokyo)
            let draft = try #require(parser.parse("physics homework", now: Fixture.fixedNow))
            #expect(draft.subjectID == nil)
            #expect(draft.matchedKeyword == nil)
        }

        // MARK: - Titles

        @Test func lowercaseTitlesBecomeTitleCase() throws {
            let cases: [(typed: String, title: String)] = [
                ("lunch with mara", "Lunch with Mara"),
                ("physics quiz", "Physics Quiz"),
                ("the art of war", "The Art of War"),
                ("of mice and men", "Of Mice and Men"),
                ("essay (draft)", "Essay (Draft)"),
                ("  study   group , ", "Study Group"),
                ("review, outline.", "Review, Outline"),
            ]
            for (typed, title) in cases {
                let draft = try #require(tokyoParser.parse(typed, now: Fixture.fixedNow))
                #expect(draft.title == title, "typed \"\(typed)\"")
            }
        }

        @Test func titlesWithCapitalsAreKeptAsTyped() throws {
            let cases = ["Physics quiz", "iPad setup", "BIO lab", "Call with the TA"]
            for typed in cases {
                let draft = try #require(tokyoParser.parse(typed, now: Fixture.fixedNow))
                #expect(draft.title == typed)
            }
        }

        // MARK: - Making the event

        @Test func makeEventCopiesTheDraft() throws {
            let draft = try #require(tokyoParser.parse("bio lab", now: Fixture.fixedNow))
            let event = tokyoParser.makeEvent(from: draft, fallbackTitle: "New Event", now: Fixture.fixedNow)
            #expect(event.title == "Bio Lab")
            #expect(event.timing == draft.timing)
            #expect(event.subjectID == Fixture.biology.id)
            #expect(event.alert == nil)
            #expect(event.recurrence == nil)
            #expect(event.location.isEmpty)
            #expect(event.notes.isEmpty)
            #expect(event.createdAt == Fixture.fixedNow)
            #expect(event.modifiedAt == Fixture.fixedNow)
        }

        @Test func makeEventUsesTheFallbackForAnEmptyTitle() {
            let start = Fixture.fixedNow.addingTimeInterval(2 * 60 * 60)
            let timing = EventTiming.timed(
                start: start, end: start.addingTimeInterval(60 * 60), timeZone: Fixture.tokyo)
            for title in ["", "   "] {
                let draft = QuickAddDraft(title: title, timing: timing, alert: .oneHour, hasDate: true, hasTime: true)
                let event = tokyoParser.makeEvent(from: draft, fallbackTitle: "New Event", now: Fixture.fixedNow)
                #expect(event.title == "New Event")
                #expect(event.timing == timing)
                #expect(event.alert == .oneHour)
                #expect(event.subjectID == nil)
            }
        }

        @Test func makeEventTrimsTheTitle() {
            let today = CalendarDate(year: 2026, month: 10, day: 7)
            let draft = QuickAddDraft(title: "  Essay  ", timing: .allDay(start: today, end: today))
            let event = tokyoParser.makeEvent(from: draft, fallbackTitle: "New Event", now: Fixture.fixedNow)
            #expect(event.title == "Essay")
        }
    }
#endif
