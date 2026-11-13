import Foundation

/// A link from a note to one occurrence of an Ithil event: the `event` key.
public struct EventLink: Hashable, Sendable {
    public var eventID: UUID
    /// The occurrence's date, "yyyy-MM-dd".
    public var day: String

    public init(eventID: UUID, day: String) {
        self.eventID = eventID
        self.day = day
    }

    /// Reads "4954484C-DE30-4000-8000-000000000201/2026-10-06". Nil for anything else.
    public init?(string: String) {
        let parts = string.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let id = UUID(uuidString: String(parts[0])), EventLink.isDay(parts[1]) else {
            return nil
        }
        self.init(eventID: id, day: String(parts[1]))
    }

    public var string: String {
        "\(eventID.uuidString)/\(day)"
    }

    private static func isDay(_ text: Substring) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 10, bytes[4] == 0x2D, bytes[7] == 0x2D else { return false }
        return bytes.enumerated().allSatisfy { index, byte in
            index == 4 || index == 7 || (0x30...0x39).contains(byte)
        }
    }
}

/// The front matter block of a note (docs/FORMAT.md, "Front matter").
///
/// The block's text is kept exactly as it was written. Reading a key never changes it. Setting a key
/// rewrites that key's lines and nothing else: unknown keys, comments, blank lines, the order of keys and
/// how values are quoted all stay byte for byte. Setting a key to the value it already has changes
/// nothing at all. A key at its default (`kind: note`, an empty list) is removed rather than written, and
/// a new key goes at the end of the block.
public struct FrontMatter: Hashable, Sendable {
    /// The first line as written: "---" and its line ending.
    var opening: String
    /// The text between the two "---" lines, as written.
    public private(set) var rawText: String
    /// The closing line as written: "---" and its line ending, if the file had one after it.
    var closing: String
    /// What lines added by Elenath end with.
    var lineEnding: LineEnding

    /// An empty block.
    public init(lineEnding: LineEnding = .lf) {
        opening = "---" + lineEnding.string
        rawText = ""
        closing = "---" + lineEnding.string
        self.lineEnding = lineEnding
    }

    init(opening: String, rawText: String, closing: String, lineEnding: LineEnding) {
        self.opening = opening
        self.rawText = rawText
        self.closing = closing
        self.lineEnding = lineEnding
    }

    /// The whole block as it goes into the file. A closing line that ended the file gets a line ending
    /// when a body follows it.
    func written(beforeBody: Bool) -> String {
        var text = opening + rawText + closing
        if beforeBody && text.unicodeScalars.last != "\n" {
            text += lineEnding.string
        }
        return text
    }

    // MARK: - The keys Elenath understands

    /// The note's identity. Nil when there is no `id` or it isn't a UUID.
    public var id: NoteID? {
        get { scalar("id").flatMap(NoteID.init(string:)) }
        set {
            guard newValue != id else { return }
            setScalar("id", newValue?.string)
        }
    }

    /// `note` when the key is missing or holds something else; another value stays as written.
    public var kind: NoteKind {
        get { scalar("kind").flatMap { NoteKind(rawValue: $0.lowercased()) } ?? .note }
        set {
            guard newValue != kind else { return }
            setScalar("kind", newValue == .note ? nil : newValue.rawValue)
        }
    }

    /// The tags, without "#". Read from a flow list (`[a, b]`), a block list (`- a` lines) or one string
    /// with commas or spaces between the tags.
    public var tags: [String] {
        get {
            switch value("tags") {
            case .scalar(let text):
                let parts = text.split(whereSeparator: { $0 == "," || $0.isWhitespace })
                return FrontMatter.cleanedTags(parts.map(String.init))
            case .list(let items, _):
                return FrontMatter.cleanedTags(items)
            case .none:
                return []
            }
        }
        set {
            let cleaned = FrontMatter.cleanedTags(newValue)
            guard cleaned != tags else { return }
            setList("tags", cleaned.map(FrontMatter.quotedIfNeeded))
        }
    }

    /// The goals this note points at: link targets, without the brackets.
    public var goals: [String] {
        get {
            let items: [String]
            switch value("goals") {
            case .scalar(let text): items = [text]
            case .list(let list, _): items = list
            case .none: items = []
            }
            return items.map(FrontMatter.withoutLinkBrackets).filter { !$0.isEmpty }
        }
        set {
            let cleaned = newValue.map(FrontMatter.withoutLinkBrackets).filter { !$0.isEmpty }
            guard cleaned != goals else { return }
            setList("goals", cleaned.map { FrontMatter.quoted("[[\($0)]]") })
        }
    }

    /// The Ithil event occurrence this note belongs to.
    public var event: EventLink? {
        get { scalar("event").flatMap(EventLink.init(string:)) }
        set {
            guard newValue != event else { return }
            setScalar("event", newValue?.string)
        }
    }

    /// When the note was created: an ISO 8601 date, or date and time. A value without a time zone is
    /// read in `timeZone`; a date without a time is the start of that day.
    public func created(in timeZone: TimeZone) -> Date? {
        scalar("created").flatMap { TimestampText.date(from: $0, defaultTimeZone: timeZone) }
    }

    /// Writes `created` as local time with its offset, such as "2026-11-10T14:30:00+02:00". Nil removes
    /// the key.
    public mutating func setCreated(_ date: Date?, in timeZone: TimeZone) {
        guard date != created(in: timeZone) else { return }
        setScalar("created", date.map { TimestampText.string(from: $0, in: timeZone) })
    }

    /// Whether the block has a top-level key with this name, whatever its value.
    public func hasKey(_ key: String) -> Bool {
        parsed().entries.contains { $0.key == key }
    }

    /// The top-level keys in the order they are written.
    public var keys: [String] {
        parsed().entries.map(\.key)
    }

    // MARK: - Recognizing a block

    /// Whether the text between two "---" lines is front matter and not ordinary text between two rules:
    /// every line is blank, a comment, a `key:` line, a list item or an indented continuation, and there
    /// is at least one key unless the block is empty.
    static func looksLikeFrontMatter(_ rawText: String) -> Bool {
        var hasKey = false
        var hasText = false
        for line in lines(of: rawText) {
            let content = self.content(of: line)
            guard let first = content.unicodeScalars.first(where: { $0 != " " && $0 != "\t" }) else { continue }
            hasText = true
            if keyAndRest(of: content) != nil {
                hasKey = true
            } else if !(isIndented(content) || first == "#" || isListItem(content)) {
                return false
            }
        }
        return hasKey || !hasText
    }

    // MARK: - Reading

    private struct Entry {
        var key: String
        /// The entry's lines in the block: its `key:` line and the indented or list lines after it.
        var lines: Range<Int>
        /// What follows "key:" on its line.
        var rest: String
    }

    private enum Value {
        case scalar(String)
        /// A list's items, and for a block list what each item line starts with ("  - ").
        case list([String], itemPrefix: String?)
    }

    private func parsed() -> (lines: [String], entries: [Entry]) {
        let lines = FrontMatter.lines(of: rawText)
        var entries: [Entry] = []
        var index = 0
        while index < lines.count {
            guard let (key, rest) = FrontMatter.keyAndRest(of: FrontMatter.content(of: lines[index])) else {
                index += 1
                continue
            }
            var end = index + 1
            while end < lines.count {
                let content = FrontMatter.content(of: lines[end])
                guard FrontMatter.isIndented(content) || FrontMatter.isListItem(content) else { break }
                guard content.unicodeScalars.contains(where: { $0 != " " && $0 != "\t" }) else { break }
                end += 1
            }
            entries.append(Entry(key: key, lines: index..<end, rest: rest))
            index = end
        }
        return (lines, entries)
    }

    /// The value of the first entry with this key. Nil when the key is missing or has no value.
    private func value(_ key: String) -> Value? {
        let (lines, entries) = parsed()
        guard let entry = entries.first(where: { $0.key == key }) else { return nil }
        let rest = entry.rest.trimmingCharacters(in: .whitespaces)
        let continuation = lines[entry.lines].dropFirst().map(FrontMatter.content(of:))
        if rest.hasPrefix("[") {
            let whole = ([rest] + continuation.map { $0.trimmingCharacters(in: .whitespaces) }).joined(separator: " ")
            return .list(YAMLText.flowItems(whole), itemPrefix: nil)
        }
        if YAMLText.scalar(rest).isEmpty {
            let items = continuation.filter(FrontMatter.isListItem)
            guard let first = items.first else { return nil }
            let indent = String(first.unicodeScalars.prefix(while: { $0 == " " || $0 == "\t" }))
            return .list(
                items.map { YAMLText.scalar(FrontMatter.listItemText($0)) }, itemPrefix: indent + "- ")
        }
        return .scalar(YAMLText.scalar(rest))
    }

    /// The key's value when it is a single value, not a list.
    private func scalar(_ key: String) -> String? {
        guard case .scalar(let text) = value(key), !text.isEmpty else { return nil }
        return text
    }

    // MARK: - Writing

    private mutating func setScalar(_ key: String, _ value: String?) {
        replaceEntry(key, with: value.map { ["\(key): \($0)" + lineEnding.string] } ?? [])
    }

    /// Writes a list the way the key was written before: as a block list if it was one, otherwise as a
    /// flow list. An empty list removes the key.
    private mutating func setList(_ key: String, _ items: [String]) {
        guard !items.isEmpty else {
            replaceEntry(key, with: [])
            return
        }
        if case .list(_, let itemPrefix?) = value(key) {
            let lines = ["\(key):" + lineEnding.string] + items.map { itemPrefix + $0 + lineEnding.string }
            replaceEntry(key, with: lines)
        } else {
            replaceEntry(key, with: ["\(key): [\(items.joined(separator: ", "))]" + lineEnding.string])
        }
    }

    /// Puts `newLines` where the key's lines are, or at the end of the block when the key is new. If the
    /// key is written more than once, the later ones go, so the block has one value for it.
    private mutating func replaceEntry(_ key: String, with newLines: [String]) {
        var (lines, entries) = parsed()
        entries = entries.filter { $0.key == key }
        if let first = entries.first {
            for duplicate in entries.dropFirst().reversed() {
                lines.removeSubrange(duplicate.lines)
            }
            lines.replaceSubrange(first.lines, with: newLines)
        } else if !newLines.isEmpty {
            if let last = lines.last, last.unicodeScalars.last != "\n" {
                lines[lines.count - 1] = last + lineEnding.string
            }
            lines.append(contentsOf: newLines)
        }
        rawText = lines.joined()
    }

    // MARK: - Lines

    /// `text` as lines, each with its line ending.
    private static func lines(of text: String) -> [String] {
        var result: [String] = []
        var current: [UInt8] = []
        for byte in text.utf8 {
            current.append(byte)
            if byte == 0x0A {
                result.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty {
            result.append(String(decoding: current, as: UTF8.self))
        }
        return result
    }

    /// A line without its line ending.
    private static func content(of line: String) -> String {
        var scalars = line.unicodeScalars[...]
        if scalars.last == "\n" {
            scalars.removeLast()
        }
        if scalars.last == "\r" {
            scalars.removeLast()
        }
        return String(scalars)
    }

    private static func isIndented(_ content: String) -> Bool {
        content.unicodeScalars.first == " " || content.unicodeScalars.first == "\t"
    }

    /// "- item", at any indent.
    private static func isListItem(_ content: String) -> Bool {
        let trimmed = content.unicodeScalars.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmed.first == "-" else { return false }
        let after = trimmed.dropFirst().first
        return after == nil || after == " " || after == "\t"
    }

    /// What follows the "- " of a list item line.
    private static func listItemText(_ content: String) -> String {
        let trimmed = content.unicodeScalars.drop(while: { $0 == " " || $0 == "\t" })
        return String(String.UnicodeScalarView(trimmed.dropFirst()))
    }

    /// A top-level `key: value` line taken apart. Nil for anything else: an indented line, a list item,
    /// a comment, or text without a colon followed by a space or the end of the line.
    private static func keyAndRest(of content: String) -> (key: String, rest: String)? {
        guard let first = content.unicodeScalars.first, first != " ", first != "\t", first != "#",
            !isListItem(content)
        else { return nil }
        var searchStart = content.startIndex
        while let colon = content[searchStart...].firstIndex(of: ":") {
            let after = content.index(after: colon)
            if after == content.endIndex || content[after] == " " || content[after] == "\t" {
                let key = YAMLText.scalar(String(content[..<colon]))
                return key.isEmpty ? nil : (key, String(content[after...]))
            }
            searchStart = after
        }
        return nil
    }

    // MARK: - Values

    /// Tags as they are kept: trimmed, without "#", without empty ones, without repeats (compared
    /// without regard to case), in their order.
    private static func cleanedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in tags {
            var cleaned = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            while cleaned.hasPrefix("#") {
                cleaned.removeFirst()
            }
            if !cleaned.isEmpty, seen.insert(NameSanitizer.key(cleaned)).inserted {
                result.append(cleaned)
            }
        }
        return result
    }

    /// "[[Pass Physics 1]]" gives "Pass Physics 1". One pair of brackets goes too: an unquoted link in a
    /// flow list reads as a nested list.
    private static func withoutLinkBrackets(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<2 where result.hasPrefix("[") && result.hasSuffix("]") && result.count >= 2 {
            result = String(result.dropFirst().dropLast())
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `value` as a YAML value: plain when it is made of letters, digits, "_", "-" and "/" and can't be
    /// read as a number, a boolean or null; otherwise in double quotes.
    private static func quotedIfNeeded(_ value: String) -> String {
        let isPlain =
            !value.isEmpty
            && value.unicodeScalars.allSatisfy { scalar in
                if scalar == "_" || scalar == "-" || scalar == "/" {
                    return true
                }
                switch scalar.properties.generalCategory {
                case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                    .nonspacingMark, .spacingMark, .decimalNumber:
                    return true
                default:
                    return false
                }
            }
        let reserved = ["true", "false", "null", "yes", "no", "on", "off"]
        let first = value.unicodeScalars.first
        if isPlain && !reserved.contains(value.lowercased()) && Double(value) == nil && first != "-" && first != "/" {
            return value
        }
        return quoted(value)
    }

    private static func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

/// The small part of YAML that front matter uses: plain and quoted values, and flow lists.
enum YAMLText {
    /// The text of one value: quotes removed and escapes applied, or a plain value without its comment.
    static func scalar(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var scalars = Array(trimmed.unicodeScalars)[...]
        guard let first = scalars.first else { return "" }
        if first == "\"" {
            scalars.removeFirst()
            return doubleQuoted(&scalars)
        }
        if first == "'" {
            scalars.removeFirst()
            return singleQuoted(&scalars)
        }
        if first == "#" {
            return ""
        }
        // A plain value ends where a comment starts: "#" after whitespace.
        var result = String.UnicodeScalarView()
        var previous: Unicode.Scalar = "x"
        for scalar in scalars {
            if scalar == "#" && (previous == " " || previous == "\t") {
                break
            }
            result.append(scalar)
            previous = scalar
        }
        return String(result).trimmingCharacters(in: .whitespaces)
    }

    /// The items of a flow list such as `[a, "b, c", [[d]]]`. Text that isn't a list gives no items.
    static func flowItems(_ text: String) -> [String] {
        var scalars = Array(text.trimmingCharacters(in: .whitespaces).unicodeScalars)[...]
        guard scalars.first == "[" else { return [] }
        scalars.removeFirst()
        var items: [String] = []
        var current = String.UnicodeScalarView()
        var depth = 0

        func finishItem() {
            let item = String(current).trimmingCharacters(in: .whitespaces)
            if !item.isEmpty {
                items.append(scalar(item))
            }
            current = String.UnicodeScalarView()
        }

        while let next = scalars.first {
            scalars.removeFirst()
            switch next {
            case "\"":
                // Kept quoted until the item is finished, so a comma inside doesn't split it.
                current.append(contentsOf: "\"".unicodeScalars)
                var closed = false
                while let inner = scalars.first {
                    scalars.removeFirst()
                    current.append(inner)
                    if inner == "\\", let escaped = scalars.first {
                        scalars.removeFirst()
                        current.append(escaped)
                    } else if inner == "\"" {
                        closed = true
                        break
                    }
                }
                if !closed {
                    current.append("\"")
                }
            case "'":
                current.append("'")
                while let inner = scalars.first {
                    scalars.removeFirst()
                    current.append(inner)
                    if inner == "'" {
                        if scalars.first == "'" {
                            scalars.removeFirst()
                            current.append("'")
                        } else {
                            break
                        }
                    }
                }
            case "[", "{":
                depth += 1
                current.append(next)
            case "]", "}":
                if depth == 0 {
                    finishItem()
                    return items
                }
                depth -= 1
                current.append(next)
            case ",":
                if depth == 0 {
                    finishItem()
                } else {
                    current.append(next)
                }
            default:
                current.append(next)
            }
        }
        finishItem()
        return items
    }

    private static func doubleQuoted(_ scalars: inout ArraySlice<Unicode.Scalar>) -> String {
        var result = String.UnicodeScalarView()
        while let next = scalars.first {
            scalars.removeFirst()
            if next == "\"" {
                break
            }
            guard next == "\\", let escaped = scalars.first else {
                result.append(next)
                continue
            }
            scalars.removeFirst()
            switch escaped {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "0": result.append("\0")
            case "u", "x", "U":
                let length = escaped == "x" ? 2 : (escaped == "u" ? 4 : 8)
                let digits = String(String.UnicodeScalarView(scalars.prefix(length)))
                if digits.unicodeScalars.count == length, let value = UInt32(digits, radix: 16),
                    let scalar = Unicode.Scalar(value)
                {
                    scalars.removeFirst(length)
                    result.append(scalar)
                } else {
                    result.append("\\")
                    result.append(escaped)
                }
            default: result.append(escaped)
            }
        }
        return String(result)
    }

    private static func singleQuoted(_ scalars: inout ArraySlice<Unicode.Scalar>) -> String {
        var result = String.UnicodeScalarView()
        while let next = scalars.first {
            scalars.removeFirst()
            if next == "'" {
                guard scalars.first == "'" else { break }
                scalars.removeFirst()
            }
            result.append(next)
        }
        return String(result)
    }
}

/// ISO 8601 dates as front matter holds them.
enum TimestampText {
    /// "2026-11-10T14:30:00+02:00": the local time in `timeZone` with its offset, or "Z" for UTC.
    static func string(from date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let time = String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        let offset = timeZone.secondsFromGMT(for: date)
        guard offset != 0 else { return "\(day)T\(time)Z" }
        let minutes = abs(offset) / 60
        let zone = String(format: "%02d:%02d", minutes / 60, minutes % 60)
        return "\(day)T\(time)\(offset < 0 ? "-" : "+")\(zone)"
    }

    /// Reads "yyyy-MM-dd", optionally followed by "T" or a space and "HH:mm", "HH:mm:ss" or
    /// "HH:mm:ss.fff", optionally followed by a zone ("Z", "+02", "+0200" or "+02:00"). Without a zone
    /// the time is in `defaultTimeZone`.
    static func date(from text: String, defaultTimeZone: TimeZone) -> Date? {
        var reader = Reader(bytes: Array(text.trimmingCharacters(in: .whitespaces).utf8))
        guard let year = reader.number(digits: 4), reader.take("-"), let month = reader.number(digits: 2),
            reader.take("-"), let day = reader.number(digits: 2), (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        var zone = defaultTimeZone
        if !reader.isAtEnd {
            guard reader.take("T") || reader.take("t") || reader.take(" "), let hour = reader.number(digits: 2),
                reader.take(":"), let minute = reader.number(digits: 2), hour < 24, minute < 60
            else { return nil }
            parts.hour = hour
            parts.minute = minute
            if reader.take(":") {
                guard let second = reader.number(digits: 2), second <= 60 else { return nil }
                parts.second = min(second, 59)
                if reader.take(".") || reader.take(",") {
                    reader.skipDigits()
                }
            }
            _ = reader.take(" ")
            if reader.take("Z") || reader.take("z") {
                zone = TimeZone(secondsFromGMT: 0) ?? defaultTimeZone
            } else if let sign = reader.sign() {
                guard let hours = reader.number(digits: 2), hours <= 23 else { return nil }
                _ = reader.take(":")
                let minutes = reader.isAtEnd ? 0 : reader.number(digits: 2)
                guard let minutes, minutes < 60,
                    let fixed = TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
                else { return nil }
                zone = fixed
            }
            guard reader.isAtEnd else { return nil }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: parts)
    }

    private struct Reader {
        var bytes: [UInt8]
        var index = 0

        var isAtEnd: Bool { index >= bytes.count }

        mutating func take(_ character: Character) -> Bool {
            guard index < bytes.count, let value = character.asciiValue, bytes[index] == value else { return false }
            index += 1
            return true
        }

        /// Exactly `digits` digits as a number.
        mutating func number(digits: Int) -> Int? {
            guard index + digits <= bytes.count else { return nil }
            var value = 0
            for byte in bytes[index..<(index + digits)] {
                guard (0x30...0x39).contains(byte) else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            index += digits
            return value
        }

        mutating func skipDigits() {
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                index += 1
            }
        }

        /// +1 or -1 for a sign, which is taken.
        mutating func sign() -> Int? {
            if take("+") {
                return 1
            }
            if take("-") {
                return -1
            }
            return nil
        }
    }
}
