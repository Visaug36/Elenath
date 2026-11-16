import ElenathCore
import Foundation
import Testing

// Finding dates in text needs Apple's Foundation (NSDataDetector): these run on CI's Macs.
#if canImport(Darwin)
    /// Quick Add parsing of dates and times. These go through NSDataDetector, which reads relative words
    /// ("thursday", "tomorrow") against the real clock in the Mac's current time zone. So, unlike every
    /// other test, they use the real current date and `TimeZone.current`, and compute their expectations
    /// from that same clock.
    struct QuickAddDateDetectionTests {
        private let zone = TimeZone.current
        private let now = Date()

        private var calendar: Calendar { QuickAddFixture.calendar(zone) }

        private var parser: QuickAddParser { QuickAddFixture.parser(timeZone: zone) }

        /// Whole days from today to the day `date` falls on, in the current time zone.
        private func daysFromToday(to date: Date) -> Int {
            let today = calendar.startOfDay(for: now)
            let day = calendar.startOfDay(for: date)
            return calendar.dateComponents([.day], from: today, to: day).day ?? -1
        }

        @Test func physicsQuizThursdayAtTen() throws {
            let text = "physics quiz thursday 10am"
            let draft = try #require(parser.parse(text, now: now))
            #expect(draft.title == "Physics Quiz")
            #expect(draft.subjectID == QuickAddFixture.physics.id)
            #expect(draft.matchedKeyword == "physics")
            #expect(draft.hasDate)
            #expect(draft.hasTime)
            #expect(draft.alert == .tenMinutes)
            #expect(draft.timing.timeZone?.identifier == zone.identifier)

            let interval = try #require(QuickAddFixture.interval(of: draft.timing))
            #expect(calendar.component(.weekday, from: interval.start) == 5)
            #expect(calendar.component(.hour, from: interval.start) == 10)
            #expect(calendar.component(.minute, from: interval.start) == 0)
            #expect(interval.duration == 60 * 60)
            #expect((0...7).contains(daysFromToday(to: interval.start)))

            let highlight = try #require(draft.highlightedRanges.first)
            let dateText = (text as NSString).range(of: "thursday 10am")
            #expect(highlight.location <= dateText.location)
            #expect(NSMaxRange(highlight) >= NSMaxRange(dateText))
            #expect(highlight.location >= (text as NSString).range(of: "quiz").location + 4)
        }

        @Test func essayDueFridayIsAllDay() throws {
            let draft = try #require(parser.parse("essay due friday", now: now))
            #expect(draft.title == "Essay Due")
            #expect(draft.hasDate)
            #expect(!draft.hasTime)
            #expect(draft.alert == nil)

            let span = try #require(QuickAddFixture.allDaySpan(of: draft.timing))
            #expect(span.first == span.last)
            #expect(span.first.weekday == 6)
            #expect((0...7).contains(CalendarDate(now, in: zone).days(to: span.first)))
        }

        /// A capital letter in the date ("Friday") doesn't count as a capital in the title.
        @Test func capitalizedDateWordStillGivesATitleCaseTitle() throws {
            let text = "bio exam Friday"
            let draft = try #require(parser.parse(text, now: now))
            #expect(draft.title == "Bio Exam")
            #expect(draft.subjectID == QuickAddFixture.biology.id)
            #expect(draft.matchedKeyword == "bio")
            #expect(!draft.hasTime)

            let span = try #require(QuickAddFixture.allDaySpan(of: draft.timing))
            #expect(span.first.weekday == 6)
            let highlight = try #require(draft.highlightedRanges.first)
            let dateText = (text as NSString).range(of: "Friday")
            #expect(highlight.location <= dateText.location)
            #expect(NSMaxRange(highlight) >= NSMaxRange(dateText))
        }

        /// Text that is only a date and time leaves an empty title; the event gets the fallback title.
        @Test func dateOnlyTextGivesAnEmptyTitle() throws {
            let draft = try #require(parser.parse("tomorrow 3pm", now: now))
            #expect(draft.title.isEmpty)
            #expect(draft.hasDate)
            #expect(draft.hasTime)
            #expect(draft.subjectID == nil)
            let interval = try #require(QuickAddFixture.interval(of: draft.timing))
            #expect(daysFromToday(to: interval.start) == 1)
            #expect(calendar.component(.hour, from: interval.start) == 15)

            let event = parser.makeEvent(from: draft, fallbackTitle: "New Event", now: now)
            #expect(event.title == "New Event")
            #expect(event.timing == draft.timing.roundedToSeconds)
            #expect(event.alert == .tenMinutes)
        }

        /// A connector left dangling after the date is dropped too.
        @Test func trailingConnectorIsDropped() throws {
            let draft = try #require(parser.parse("call mom tomorrow at", now: now))
            #expect(draft.title == "Call Mom")
            #expect(draft.hasDate)
            let span = try #require(QuickAddFixture.allDaySpan(of: draft.timing))
            #expect(CalendarDate(now, in: zone).days(to: span.first) == 1)
        }

        @Test func lunchWithMaraTomorrowKeepsTheTitleAsTyped() throws {
            let text = "Lunch with Mara tomorrow at 12:30"
            let draft = try #require(parser.parse(text, now: now))
            #expect(draft.title == "Lunch with Mara")
            #expect(draft.subjectID == nil)
            #expect(draft.hasTime)

            let interval = try #require(QuickAddFixture.interval(of: draft.timing))
            #expect(daysFromToday(to: interval.start) == 1)
            #expect(calendar.component(.hour, from: interval.start) == 12)
            #expect(calendar.component(.minute, from: interval.start) == 30)
            #expect(interval.duration == 60 * 60)

            let highlight = try #require(draft.highlightedRanges.first)
            let timeText = (text as NSString).range(of: "12:30")
            #expect(highlight.location <= timeText.location)
            #expect(NSMaxRange(highlight) >= NSMaxRange(timeText))
        }

        @Test func connectorBeforeTheTimeIsDropped() throws {
            let noAlert = QuickAddFixture.parser(timeZone: zone, defaultAlert: nil)
            let draft = try #require(noAlert.parse("dinner at 7pm", now: now))
            #expect(draft.title == "Dinner")
            #expect(draft.hasTime)
            #expect(draft.alert == nil)
            let interval = try #require(QuickAddFixture.interval(of: draft.timing))
            #expect(calendar.component(.hour, from: interval.start) == 19)
            #expect(calendar.component(.minute, from: interval.start) == 0)
        }

        /// NSDataDetector reports a duration for some ranges ("from 2pm to 4pm"), but whether it does can
        /// vary between macOS versions. So the two-hour end is required only when the detector itself
        /// reports a duration for this text; otherwise the default hour applies.
        @Test func meetingFromTwoToFour() throws {
            let text = "meeting from 2pm to 4pm"
            let draft = try #require(parser.parse(text, now: now))
            #expect(draft.hasTime)
            let interval = try #require(QuickAddFixture.interval(of: draft.timing))
            #expect(calendar.component(.hour, from: interval.start) == 14)

            let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
            let match = detector.firstMatch(
                in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
            if let match, match.duration > 0 {
                #expect(interval.duration == 2 * 60 * 60)
                #expect(draft.title == "Meeting")
            } else {
                #expect(interval.duration == 60 * 60)
            }
        }

        /// A detected wall-clock time stays that wall-clock time in the parser's own time zone.
        @Test func wallClockTimeMovesToTheParsersTimeZone() throws {
            let otherZone = zone.identifier == "Asia/Tokyo" ? QuickAddFixture.newYork : QuickAddFixture.tokyo
            let otherParser = QuickAddFixture.parser(timeZone: otherZone)
            let draft = try #require(otherParser.parse("dinner at 7pm", now: now))
            #expect(draft.timing.timeZone?.identifier == otherZone.identifier)
            let interval = try #require(QuickAddFixture.interval(of: draft.timing))
            let otherCalendar = QuickAddFixture.calendar(otherZone)
            #expect(otherCalendar.component(.hour, from: interval.start) == 19)
            #expect(otherCalendar.component(.minute, from: interval.start) == 0)
        }
    }
#endif
