import Foundation

/// How lines end in a note file.
public enum LineEnding: Hashable, Sendable {
    case lf
    case crlf

    /// The characters that end a line.
    public var string: String {
        switch self {
        case .lf: "\n"
        case .crlf: "\r\n"
        }
    }
}

public enum NoteTextError: Error, Equatable, Sendable {
    /// The file isn't valid UTF-8. It is shown read-only and never rewritten.
    case notUTF8
}

/// A note file split into its parts without losing a byte (docs/FORMAT.md, "Notes").
///
/// `try NoteText(data: d).data() == d` holds for every `d` that is valid UTF-8: the byte order mark, the
/// front matter as it was written and the body all go back out unchanged. Only what is changed through
/// this type's properties changes in the file.
public struct NoteText: Hashable, Sendable {
    /// Whether the file starts with a UTF-8 byte order mark. It is kept if it was there.
    public var hasByteOrderMark: Bool
    /// The line ending the file uses, which is what lines added by Elenath use too.
    public var lineEnding: LineEnding
    /// The block between the two "---" lines at the top, when the file has one.
    public var frontMatter: FrontMatter?
    /// Everything after the front matter: the text the editor shows.
    public var body: String

    /// Reads a note file.
    public init(data: Data) throws(NoteTextError) {
        var bytes = data[data.startIndex...]
        let hasMark = bytes.starts(with: NoteText.byteOrderMark)
        if hasMark {
            bytes = bytes.dropFirst(NoteText.byteOrderMark.count)
        }
        let ending = NoteText.lineEnding(of: bytes)
        guard let block = FrontMatterBlock.find(in: bytes) else {
            guard let text = String(validating: bytes, as: UTF8.self) else { throw .notUTF8 }
            self.init(hasByteOrderMark: hasMark, lineEnding: ending, frontMatter: nil, body: text)
            return
        }
        guard let opening = String(validating: bytes[block.opening], as: UTF8.self),
            let raw = String(validating: bytes[block.raw], as: UTF8.self),
            let closing = String(validating: bytes[block.closing], as: UTF8.self),
            let text = String(validating: bytes[block.closing.upperBound...], as: UTF8.self)
        else { throw .notUTF8 }
        guard FrontMatter.looksLikeFrontMatter(raw) else {
            // Two rules with ordinary text between them: all of it is the note.
            guard let whole = String(validating: bytes, as: UTF8.self) else { throw .notUTF8 }
            self.init(hasByteOrderMark: hasMark, lineEnding: ending, frontMatter: nil, body: whole)
            return
        }
        let frontMatter = FrontMatter(opening: opening, rawText: raw, closing: closing, lineEnding: ending)
        self.init(hasByteOrderMark: hasMark, lineEnding: ending, frontMatter: frontMatter, body: text)
    }

    /// A note as Elenath creates it: front matter with `id` and `created` (and `kind`, unless it is a
    /// plain note), LF line endings, and a body that ends with one line break.
    public init(newNoteWithID id: NoteID, created: Date, timeZone: TimeZone, kind: NoteKind = .note, body: String) {
        var block = FrontMatter(lineEnding: .lf)
        block.id = id
        block.setCreated(created, in: timeZone)
        block.kind = kind
        let endsWithLineBreak = body.unicodeScalars.last == "\n"
        self.init(
            hasByteOrderMark: false, lineEnding: .lf, frontMatter: block,
            body: body.isEmpty || endsWithLineBreak ? body : body + "\n")
    }

    /// A note with nothing but a body.
    public init(body: String) {
        var ending = LineEnding.lf
        var previous: UInt8 = 0
        for byte in body.utf8 {
            if byte == 0x0A {
                ending = previous == 0x0D ? .crlf : .lf
                break
            }
            previous = byte
        }
        self.init(hasByteOrderMark: false, lineEnding: ending, frontMatter: nil, body: body)
    }

    private init(hasByteOrderMark: Bool, lineEnding: LineEnding, frontMatter: FrontMatter?, body: String) {
        self.hasByteOrderMark = hasByteOrderMark
        self.lineEnding = lineEnding
        self.frontMatter = frontMatter
        self.body = body
    }

    /// The file's bytes.
    public func data() -> Data {
        var result = Data()
        if hasByteOrderMark {
            result.append(contentsOf: NoteText.byteOrderMark)
        }
        if let frontMatter {
            result.append(Data(frontMatter.written(beforeBody: !body.isEmpty).utf8))
        }
        result.append(Data(body.utf8))
        return result
    }

    /// The note's kind, `.note` without front matter.
    public var kind: NoteKind {
        frontMatter?.kind ?? .note
    }

    /// The note's id, when its front matter has one.
    public var id: NoteID? {
        frontMatter?.id
    }

    /// Gives the note an `id`, and a `created` date if it has none: what the first edit of a note that
    /// came from elsewhere does. A note that has an id keeps it, and so does a note whose `id` is
    /// something other than a UUID (another tool's id is never overwritten). Returns whether anything
    /// changed.
    @discardableResult
    public mutating func addIdentity(id: NoteID, created: Date, timeZone: TimeZone) -> Bool {
        var block = frontMatter ?? FrontMatter(lineEnding: lineEnding)
        guard !block.hasKey("id") else { return false }
        block.id = id
        if !block.hasKey("created") {
            block.setCreated(created, in: timeZone)
        }
        frontMatter = block
        return true
    }

    // MARK: - Private

    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// CRLF when the first line ends with it, otherwise LF.
    private static func lineEnding(of bytes: Data.SubSequence) -> LineEnding {
        guard let lineFeed = bytes.firstIndex(of: 0x0A) else { return .lf }
        return lineFeed > bytes.startIndex && bytes[lineFeed - 1] == 0x0D ? .crlf : .lf
    }
}

/// Where a front matter block is in a file's bytes.
struct FrontMatterBlock {
    /// The first line, "---" with its line ending.
    var opening: Range<Data.Index>
    /// The lines between the two "---" lines.
    var raw: Range<Data.Index>
    /// The closing "---" line with its line ending, if it has one.
    var closing: Range<Data.Index>

    /// The block at the start of `bytes`: a first line that is exactly "---" and the next line that is.
    /// Nil when the file doesn't start with one or it is never closed.
    static func find(in bytes: Data.SubSequence) -> FrontMatterBlock? {
        guard let first = line(in: bytes, from: bytes.startIndex), first.end > first.contentEnd,
            isDelimiter(bytes[bytes.startIndex..<first.contentEnd])
        else { return nil }
        var start = first.end
        while let next = line(in: bytes, from: start) {
            if isDelimiter(bytes[start..<next.contentEnd]) {
                return FrontMatterBlock(
                    opening: bytes.startIndex..<first.end, raw: first.end..<start, closing: start..<next.end)
            }
            start = next.end
        }
        return nil
    }

    /// The line that starts at `start`: where its text ends and where the next line starts. Nil at the
    /// end of the file.
    private static func line(
        in bytes: Data.SubSequence, from start: Data.Index
    ) -> (contentEnd: Data.Index, end: Data.Index)? {
        guard start < bytes.endIndex else { return nil }
        guard let lineFeed = bytes[start...].firstIndex(of: 0x0A) else { return (bytes.endIndex, bytes.endIndex) }
        let contentEnd = lineFeed > start && bytes[lineFeed - 1] == 0x0D ? lineFeed - 1 : lineFeed
        return (contentEnd, lineFeed + 1)
    }

    /// "---", with nothing after it but spaces or tabs.
    private static func isDelimiter(_ content: Data.SubSequence) -> Bool {
        guard content.count >= 3, content.prefix(3).allSatisfy({ $0 == 0x2D }) else { return false }
        return content.dropFirst(3).allSatisfy { $0 == 0x20 || $0 == 0x09 }
    }
}
