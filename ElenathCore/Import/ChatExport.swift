import Foundation

/// One message of an exported chat.
public struct ChatMessage: Hashable, Sendable {
    /// When it was sent, if the line's date could be read.
    public var sent: Date?
    public var sender: String
    /// The message's text, without the lines that only name an attached file.
    public var text: String
    /// The files that came with it, by the names they have in the export.
    public var attachmentNames: [String]

    public init(sent: Date?, sender: String, text: String, attachmentNames: [String] = []) {
        self.sent = sent
        self.sender = sender
        self.text = text
        self.attachmentNames = attachmentNames
    }
}

/// Reads the text file WhatsApp writes when a chat is exported (docs/IMPORT.md).
///
/// Both forms are read: "[10/11/2026, 14:30:05] Name: text" (iPhone) and "10/11/2026, 14:30 - Name: text"
/// (Android), with the date and time written the way the phone's region writes them.
public enum ChatExport {
    /// Whether `text` looks like an exported chat: at least two of its first lines start a message.
    public static func isChatExport(_ text: String) -> Bool {
        var seen = 0
        var headers = 0
        for line in text.split(whereSeparator: \.isNewline) where !line.allSatisfy(\.isWhitespace) {
            seen += 1
            if Header(line: String(line)) != nil {
                headers += 1
            }
            if seen == 12 {
                break
            }
        }
        return headers >= 2
    }

    /// The messages in an export, in the order they are written. Lines the app wrote itself (a notice
    /// about encryption, a deleted message, media that was left out) are dropped.
    public static func messages(from text: String, timeZone: TimeZone) -> [ChatMessage] {
        var entries: [(header: Header, lines: [String])] = []
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if let header = Header(line: line) {
                entries.append((header, [header.text]))
            } else if !entries.isEmpty {
                entries[entries.count - 1].lines.append(line)
            }
        }
        let order = DateOrder(headers: entries.map(\.header))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        var messages: [ChatMessage] = []
        for (header, lines) in entries {
            guard let sender = header.sender else { continue }
            var attachments: [String] = []
            var kept: [String] = []
            for line in lines {
                let cleaned = String(line.unicodeScalars.filter { !Header.invisible.contains($0) })
                if let name = attachmentName(in: cleaned) {
                    attachments.append(name)
                } else if !isNotice(cleaned) {
                    kept.append(cleaned)
                }
            }
            let text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty || !attachments.isEmpty else { continue }
            messages.append(
                ChatMessage(
                    sent: order.date(of: header, calendar: calendar), sender: sender, text: text,
                    attachmentNames: attachments))
        }
        return messages
    }

    /// Messages grouped into notes: one that follows the one before it within `gap` belongs to the same
    /// thought. A message without a date starts a note of its own.
    public static func notes(from messages: [ChatMessage], gap: TimeInterval) -> [[ChatMessage]] {
        var groups: [[ChatMessage]] = []
        for message in messages {
            if let previous = groups.last?.last?.sent, let sent = message.sent,
                sent.timeIntervalSince(previous) >= 0, sent.timeIntervalSince(previous) <= gap
            {
                groups[groups.count - 1].append(message)
            } else {
                groups.append([message])
            }
        }
        return groups
    }

    // MARK: - Private

    /// "<attached: name>" (iPhone) or "name (file attached)" (Android).
    private static func attachmentName(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("<attached: ") && trimmed.hasSuffix(">") {
            return String(trimmed.dropFirst("<attached: ".count).dropLast())
        }
        if trimmed.hasSuffix(" (file attached)") {
            return String(trimmed.dropLast(" (file attached)".count))
        }
        return nil
    }

    /// Lines the app writes in place of something that isn't in the export.
    private static func isNotice(_ line: String) -> Bool {
        let lowered = line.trimmingCharacters(in: .whitespaces).lowercased()
        if lowered == "<media omitted>" || lowered == "this message was deleted"
            || lowered == "you deleted this message"
        {
            return true
        }
        if lowered.hasSuffix(" omitted"), lowered.split(separator: " ").count <= 3 {
            return true  // "image omitted", "video omitted", "GIF omitted"…
        }
        return lowered.hasPrefix("messages and calls are end-to-end encrypted")
    }

    /// The start of a message: its date and time as they are written, the sender and the first line.
    private struct Header {
        static let invisible: Set<Unicode.Scalar> = ["\u{200E}", "\u{200F}", "\u{FEFF}", "\u{202A}", "\u{202C}"]

        var dateParts: [Int]
        /// Whether the first number of the date was written with four digits: a year.
        var startsWithYear: Bool
        var hour: Int
        var minute: Int
        var second: Int
        /// "am" or "pm" when the time has one.
        var meridiem: String?
        /// Nil for a line the app wrote itself, which has no sender.
        var sender: String?
        var text: String

        init?(line: String) {
            var scalars = Array(line.unicodeScalars.filter { !Header.invisible.contains($0) })[...]
            let isBracketed = scalars.first == "["
            if isBracketed {
                scalars.removeFirst()
            }
            // The date: three numbers with "/", "." or "-" between them.
            var parts: [Int] = []
            var firstLength = 0
            for position in 0..<3 {
                let digits = scalars.prefix(while: { ("0"..."9").contains($0) })
                guard !digits.isEmpty, digits.count <= 4, let value = Int(String(String.UnicodeScalarView(digits)))
                else {
                    return nil
                }
                if position == 0 {
                    firstLength = digits.count
                }
                parts.append(value)
                scalars.removeFirst(digits.count)
                if position < 2 {
                    guard let separator = scalars.first, separator == "/" || separator == "." || separator == "-" else {
                        return nil
                    }
                    scalars.removeFirst()
                }
            }
            if scalars.first == "," {
                scalars.removeFirst()
            }
            Header.skipSpaces(&scalars)
            // The time: hours, minutes and maybe seconds, maybe "am" or "pm".
            guard let hour = Header.number(&scalars, maxDigits: 2), let colon = scalars.first,
                colon == ":" || colon == "."
            else { return nil }
            scalars.removeFirst()
            guard let minute = Header.number(&scalars, maxDigits: 2) else { return nil }
            var second = 0
            if let next = scalars.first, next == ":" || next == ".", scalars.count > 1,
                ("0"..."9").contains(scalars[scalars.startIndex + 1])
            {
                scalars.removeFirst()
                second = Header.number(&scalars, maxDigits: 2) ?? 0
            }
            Header.skipSpaces(&scalars)
            var meridiem: String?
            let letters = scalars.prefix(while: { $0.properties.isAlphabetic || $0 == "." || $0 == " " })
            let word = String(String.UnicodeScalarView(letters)).lowercased().filter { $0 != "." && $0 != " " }
            if word.hasPrefix("am") || word.hasPrefix("pm") {
                meridiem = String(word.prefix(2))
                // Take what was written for it, but not the " - " or the sender that follows.
                var taken = 0
                var matched = 0
                for scalar in letters {
                    taken += 1
                    if scalar.properties.isAlphabetic {
                        matched += 1
                    }
                    if matched == 2 {
                        break
                    }
                }
                scalars.removeFirst(taken)
                if scalars.first == "." {
                    scalars.removeFirst()
                }
            }
            // What closes the header: "]" for a bracketed one, " - " otherwise.
            if isBracketed {
                guard scalars.first == "]" else { return nil }
                scalars.removeFirst()
            } else {
                Header.skipSpaces(&scalars)
                guard let dash = scalars.first, dash == "-" || dash == "–" else { return nil }
                scalars.removeFirst()
            }
            Header.skipSpaces(&scalars)
            guard hour < 24, minute < 60, second < 61 else { return nil }

            let rest = String(String.UnicodeScalarView(scalars))
            dateParts = parts
            startsWithYear = firstLength == 4
            self.hour = hour
            self.minute = minute
            self.second = min(second, 59)
            self.meridiem = meridiem
            if let separator = rest.range(of: ": ") {
                sender = String(rest[..<separator.lowerBound])
                text = String(rest[separator.upperBound...])
            } else if rest.hasSuffix(":") {
                sender = String(rest.dropLast())
                text = ""
            } else {
                sender = nil
                text = rest
            }
        }

        private static func skipSpaces(_ scalars: inout ArraySlice<Unicode.Scalar>) {
            while let first = scalars.first, first == " " || first == "\u{00A0}" || first == "\u{202F}" || first == "\t"
            {
                scalars.removeFirst()
            }
        }

        private static func number(_ scalars: inout ArraySlice<Unicode.Scalar>, maxDigits: Int) -> Int? {
            let digits = scalars.prefix(while: { ("0"..."9").contains($0) }).prefix(maxDigits)
            guard !digits.isEmpty, let value = Int(String(String.UnicodeScalarView(digits))) else { return nil }
            scalars.removeFirst(digits.count)
            return value
        }
    }

    /// Which of a date's three numbers is the day, the month and the year, worked out from the whole
    /// export: a first number above 12 can only be a day, a second one above 12 means the month comes
    /// first. When nothing tells, the day comes first, as in most of the world.
    private struct DateOrder {
        var yearFirst: Bool
        var monthFirst: Bool

        init(headers: [Header]) {
            yearFirst = headers.first?.startsWithYear ?? false
            let firstAboveTwelve = headers.contains { $0.dateParts[0] > 12 }
            let secondAboveTwelve = headers.contains { $0.dateParts[1] > 12 }
            monthFirst = !firstAboveTwelve && secondAboveTwelve
        }

        func date(of header: Header, calendar: Calendar) -> Date? {
            var parts = DateComponents()
            if yearFirst {
                parts.year = header.dateParts[0]
                parts.month = header.dateParts[1]
                parts.day = header.dateParts[2]
            } else {
                parts.day = header.dateParts[monthFirst ? 1 : 0]
                parts.month = header.dateParts[monthFirst ? 0 : 1]
                parts.year = header.dateParts[2] < 100 ? 2000 + header.dateParts[2] : header.dateParts[2]
            }
            guard let month = parts.month, let day = parts.day, (1...12).contains(month), (1...31).contains(day) else {
                return nil
            }
            var hour = header.hour
            if let meridiem = header.meridiem {
                guard (1...12).contains(hour) else { return nil }
                hour = hour % 12 + (meridiem == "pm" ? 12 : 0)
            }
            parts.hour = hour
            parts.minute = header.minute
            parts.second = header.second
            return calendar.date(from: parts)
        }
    }
}
