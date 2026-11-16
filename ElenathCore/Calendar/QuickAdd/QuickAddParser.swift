import Foundation

/// Turns one line of text, such as "physics quiz thursday 10am", into a `QuickAddDraft`: the date and
/// time (found with `NSDataDetector`), a subject (matched by name or keyword) and a tidy title.
///
/// `NSDataDetector` reads relative words ("thursday", "tomorrow") against the real clock, in the Mac's
/// current time zone, so `now` should be the real current time. A detected wall-clock time ("10am") is
/// kept as that wall-clock time in `timeZone`, which is normally the Mac's current time zone as well.
public struct QuickAddParser: Sendable {
    /// The subjects Quick Add can match. Between equally good matches, the earlier subject wins.
    public let subjects: [Subject]
    /// The time zone of the drafts' timed events, and the one that decides "today".
    public let timeZone: TimeZone
    /// How long a timed event lasts when the text gives no end.
    public let defaultDuration: TimeInterval
    /// The alert for timed drafts. All-day drafts get none.
    public let defaultAlert: AlertOffset?
    private let subjectNeedles: [SubjectNeedle]

    public init(subjects: [Subject], timeZone: TimeZone, defaultDuration: TimeInterval, defaultAlert: AlertOffset?) {
        var needles: [SubjectNeedle] = []
        for subject in subjects {
            for word in [subject.name] + subject.keywords {
                let text = QuickAddParser.words(in: word).joined(separator: " ")
                if !text.isEmpty {
                    needles.append(SubjectNeedle(subjectID: subject.id, text: text))
                }
            }
        }
        self.subjects = subjects
        self.timeZone = timeZone
        self.defaultDuration = max(0, defaultDuration)
        self.defaultAlert = defaultAlert
        self.subjectNeedles = needles
    }

    /// What `text` describes, or nil when it is blank.
    ///
    /// - The first date `NSDataDetector` finds sets the timing. Its text is highlighted and removed from
    ///   the title, together with a connector word right before it ("at", "on", "from", "by"…). Without a
    ///   time of day ("10am", "14:30", "noon"…) it becomes an all-day event on that date. A detected
    ///   duration ("from 2pm to 4pm") sets the end; otherwise the event lasts `defaultDuration`. When
    ///   nothing is detected, the draft is an all-day event today.
    /// - The longest subject name or keyword found as whole words, ignoring case and diacritics, sets the
    ///   subject; on a tie the one that comes first in the text wins. The word stays in the title.
    /// - A title typed without capitals becomes title case ("lunch with mara" → "Lunch with Mara").
    ///   Anything with a capital letter is kept as typed.
    public func parse(_ text: String, now: Date) -> QuickAddDraft? {
        guard text.contains(where: { !$0.isWhitespace }) else { return nil }
        let detection = Self.detectedDate(in: text)
        let typedTitle = Self.cleanedTitle(text, removing: detection?.range)
        let subjectMatch = bestSubjectMatch(in: typedTitle)
        let title = typedTitle.contains(where: { $0.isUppercase }) ? typedTitle : Self.titleCased(typedTitle)
        let timing: EventTiming
        if let detection {
            timing = eventTiming(for: detection)
        } else {
            let today = CalendarDate(now, in: timeZone)
            timing = .allDay(start: today, end: today)
        }
        let hasTime = detection?.hasTime ?? false
        return QuickAddDraft(
            title: title,
            timing: timing,
            subjectID: subjectMatch?.subjectID,
            matchedKeyword: subjectMatch?.typedText,
            highlightedRanges: detection.map { [$0.nsRange] } ?? [],
            alert: hasTime ? defaultAlert : nil,
            hasDate: detection != nil,
            hasTime: hasTime)
    }

    /// The event to add for `draft`, created at `now`. A draft without a title gets `fallbackTitle`
    /// (the app's localized "New Event").
    public func makeEvent(from draft: QuickAddDraft, fallbackTitle: String, now: Date) -> Event {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return Event(
            title: title.isEmpty ? fallbackTitle : title,
            timing: draft.timing,
            subjectID: draft.subjectID,
            alert: draft.alert,
            createdAt: now)
    }

    // MARK: - Dates and times

    /// The first date `NSDataDetector` finds in some text.
    private struct DetectedDate {
        var nsRange: NSRange
        var range: Range<String.Index>
        var date: Date
        var duration: TimeInterval
        /// Set only when the text names a time zone.
        var timeZone: TimeZone?
        var hasTime: Bool
    }

    private static func detectedDate(in text: String) -> DetectedDate? {
        #if canImport(Darwin)
            return detectedDateWithDataDetector(in: text)
        #else
            // Only Apple's Foundation finds dates in text. Elsewhere (the Linux build of the core) no date
            // is found, and a draft is an all-day event today.
            return nil
        #endif
    }

    #if canImport(Darwin)
        private static func detectedDateWithDataDetector(in text: String) -> DetectedDate? {
            let types = NSTextCheckingResult.CheckingType.date.rawValue
            guard let detector = try? NSDataDetector(types: types) else { return nil }
            let searchRange = NSRange(location: 0, length: text.utf16.count)
            for match in detector.matches(in: text, options: [], range: searchRange) {
                guard var date = match.date, let matched = Range(match.range, in: text) else { continue }
                var duration = match.duration
                var timeZone = match.timeZone
                let range = trimmingLeadWords(of: matched, in: text)
                if range != matched {
                    // "due friday" reads as a deadline (now until Friday). Read the date phrase on its own instead.
                    let phrase = String(text[range])
                    let phraseRange = NSRange(location: 0, length: phrase.utf16.count)
                    let alone = detector.firstMatch(in: phrase, options: [], range: phraseRange)
                    if let alone, let aloneDate = alone.date {
                        date = aloneDate
                        duration = alone.duration
                        timeZone = alone.timeZone
                    } else if duration > 0 {
                        date = date.addingTimeInterval(duration)
                        duration = 0
                    }
                }
                return DetectedDate(
                    nsRange: NSRange(range, in: text),
                    range: range,
                    date: date,
                    duration: duration,
                    timeZone: timeZone,
                    hasTime: mentionsTimeOfDay(String(text[range])))
            }
            return nil
        }
    #endif

    /// Words NSDataDetector folds into a date phrase ("due friday") that belong to the title instead.
    private static let titleWordsBeforeDate: Set<String> = ["due"]

    /// `range` without leading words from `titleWordsBeforeDate`, so "essay due friday" keeps "due".
    private static func trimmingLeadWords(of range: Range<String.Index>, in text: String) -> Range<String.Index> {
        var start = range.lowerBound
        while start < range.upperBound {
            let rest = text[start..<range.upperBound]
            guard let space = rest.firstIndex(where: { $0.isWhitespace }) else { break }
            let word = rest[rest.startIndex..<space].lowercased()
            guard titleWordsBeforeDate.contains(word) else { break }
            guard let next = rest[space...].firstIndex(where: { !$0.isWhitespace }) else { break }
            start = next
        }
        return start..<range.upperBound
    }

    private func eventTiming(for detection: DetectedDate) -> EventTiming {
        // NSDataDetector reads the text in the Mac's current time zone, unless the text names another one.
        // A named zone keeps the detected instant; otherwise the wall-clock time moves to `timeZone`.
        let readingZone = detection.timeZone ?? TimeZone.current
        guard detection.hasTime else {
            let day = CalendarDate(detection.date, in: readingZone)
            return .allDay(start: day, end: day)
        }
        let namesZone = readingZone.identifier != TimeZone.current.identifier
        let start = namesZone ? detection.date : sameWallClock(as: detection.date, in: readingZone)
        let duration = detection.duration > 0 ? detection.duration : defaultDuration
        return .timed(start: start, end: start.addingTimeInterval(duration), timeZone: timeZone)
    }

    /// The instant in `timeZone` with the wall-clock date and time that `date` has in `source`.
    private func sameWallClock(as date: Date, in source: TimeZone) -> Date {
        guard source.identifier != timeZone.identifier else { return date }
        let units: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        let parts = Self.gregorian(source).dateComponents(units, from: date)
        return Self.gregorian(timeZone).date(from: parts) ?? date
    }

    /// Wording that names a time of day: "10am", "10:30 p.m.", "14:30", "14.30", "noon", "midnight",
    /// "7 o'clock", "at 9", "in 20 minutes". A date without any of these ("friday", "next week") is
    /// all-day.
    private static let timeOfDayPatterns: [String] = [
        #"(?<![\d.:])\d{1,2}(?:[:.]\d{2})?\s*(?:a\.?m\.?|p\.?m\.?)(?![a-z])"#,
        #"(?<![\d.:])\d{1,2}[:.]\d{2}(?![.:]?\d)"#,
        #"\b(?:noon|midday|midnight)\b"#,
        #"\b\d{1,2}\s*o['’]?clock\b"#,
        #"\bat\s+\d{1,2}\b"#,
        #"\bin\s+(?:\d+|an?|half an)\s*(?:minutes?|mins?|hours?|hrs?)\b"#,
    ]

    private static func mentionsTimeOfDay(_ text: String) -> Bool {
        timeOfDayPatterns.contains { pattern in
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private static func gregorian(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    // MARK: - Title

    /// Connector words dropped when they come right before the date ("dinner at 7pm" → "dinner").
    private static let connectorsBeforeDate: Set<String> = [
        "at",
        "on",
        "from",
        "by",
        "until",
        "till",
        "@",
    ]

    /// Connector words dropped when they are all that follows the date ("call mom tomorrow at").
    private static let connectorsAfterDate: Set<String> = [
        "at",
        "on",
        "from",
        "by",
        "until",
        "till",
        "to",
        "@",
        "-",
        "–",
    ]

    /// Punctuation dropped where the date was cut out ("quiz, friday, room 4" → "quiz, room 4").
    private static let junctionPunctuation: Set<Character> = [",", ";"]

    /// Punctuation trimmed from both ends of the title.
    private static let edgePunctuation: Set<Character> = [
        ",",
        ";",
        ":",
        ".",
        "-",
        "–",
        "—",
        "@",
        "·",
        "|",
        "/",
    ]

    /// Words title case keeps lowercase unless they come first.
    private static let titleCaseSmallWords: Set<String> = [
        "a",
        "an",
        "and",
        "as",
        "at",
        "but",
        "by",
        "for",
        "from",
        "in",
        "of",
        "on",
        "or",
        "the",
        "to",
        "with",
    ]

    /// `text` without the detected date text and a dangling connector next to it, with runs of
    /// whitespace collapsed and stray punctuation trimmed from both ends.
    private static func cleanedTitle(_ text: String, removing dateRange: Range<String.Index>?) -> String {
        guard let dateRange else { return trimmingEdges(words(in: text).joined(separator: " ")) }
        var before = words(in: String(text[..<dateRange.lowerBound]))
        var after = words(in: String(text[dateRange.upperBound...]))
        if let last = before.last, connectorsBeforeDate.contains(last.lowercased()) {
            before.removeLast()
        }
        if after.count == 1, let only = after.first, connectorsAfterDate.contains(only.lowercased()) {
            after.removeAll()
        }
        if !before.isEmpty, let first = after.first {
            let stripped = String(first.drop(while: { junctionPunctuation.contains($0) }))
            if stripped.isEmpty {
                after.removeFirst()
            } else {
                after[0] = stripped
            }
        }
        return trimmingEdges((before + after).joined(separator: " "))
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
    }

    private static func trimmingEdges(_ text: String) -> String {
        var slice = Substring(text)
        while let first = slice.first, first.isWhitespace || edgePunctuation.contains(first) {
            slice = slice.dropFirst()
        }
        while let last = slice.last, last.isWhitespace || edgePunctuation.contains(last) {
            slice = slice.dropLast()
        }
        return String(slice)
    }

    /// "lunch with mara" → "Lunch with Mara": every word capitalized except small words after the first.
    private static func titleCased(_ title: String) -> String {
        var result: [String] = []
        for (index, word) in words(in: title).enumerated() {
            let bare = word.trimmingCharacters(in: .punctuationCharacters)
            if index > 0 && titleCaseSmallWords.contains(bare) {
                result.append(word)
            } else {
                result.append(capitalizingFirstLetter(word))
            }
        }
        return result.joined(separator: " ")
    }

    /// The word with its first letter uppercased, after any leading punctuation ("(draft)" → "(Draft)").
    /// Words that start with a digit ("2nd") are kept as they are.
    private static func capitalizingFirstLetter(_ word: String) -> String {
        guard let index = word.firstIndex(where: { $0.isLetter || $0.isNumber }), word[index].isLetter else {
            return word
        }
        return String(word[..<index]) + word[index].uppercased() + String(word[word.index(after: index)...])
    }

    // MARK: - Subjects

    /// A subject's name or keyword, with whitespace collapsed.
    private struct SubjectNeedle: Sendable {
        var subjectID: UUID
        var text: String
    }

    private struct SubjectMatch {
        var subjectID: UUID
        /// The matched words as typed.
        var typedText: String
        var start: String.Index
        var length: Int
    }

    private func bestSubjectMatch(in title: String) -> SubjectMatch? {
        var best: SubjectMatch?
        for needle in subjectNeedles {
            guard let range = Self.wholeWordRange(of: needle.text, in: title) else { continue }
            let candidate = SubjectMatch(
                subjectID: needle.subjectID,
                typedText: String(title[range]),
                start: range.lowerBound,
                length: title.distance(from: range.lowerBound, to: range.upperBound))
            if let current = best, !Self.isBetter(candidate, than: current) { continue }
            best = candidate
        }
        return best
    }

    /// Longer matches win; between equally long ones, the one earlier in the text.
    private static func isBetter(_ candidate: SubjectMatch, than current: SubjectMatch) -> Bool {
        if candidate.length != current.length { return candidate.length > current.length }
        return candidate.start < current.start
    }

    /// The first place `needle` appears in `text` as whole words, ignoring case and diacritics.
    private static func wholeWordRange(of needle: String, in text: String) -> Range<String.Index>? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var searchStart = text.startIndex
        while searchStart < text.endIndex {
            guard let found = text.range(of: needle, options: options, range: searchStart..<text.endIndex) else {
                return nil
            }
            if isWholeWord(found, in: text) { return found }
            searchStart = text.index(after: found.lowerBound)
        }
        return nil
    }

    private static func isWholeWord(_ range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex, isWordCharacter(text[text.index(before: range.lowerBound)]) {
            return false
        }
        if range.upperBound < text.endIndex, isWordCharacter(text[range.upperBound]) {
            return false
        }
        return true
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
