import Foundation

/// What kind of block a line belongs to.
public enum BlockKind: Hashable, Sendable {
    case paragraph
    case heading(level: Int)
    case quote
    /// A list item's first line. `indent` is how far in it starts, in columns.
    case listItem(indent: Int)
    /// The line that opens or closes a fenced code block.
    case codeFence
    /// A line of code, in a fenced or an indented block.
    case codeBlock
    case table
    case thematicBreak
    case blank
}

/// What the scanner carries from one line to the next. The editor keeps the state at the end of every
/// line, so after an edit it rescans from the first changed line only until the state matches again.
public struct BlockState: Hashable, Sendable {
    /// The state at the start of a note.
    public static let start = BlockState()

    /// The fence of the code block the next line is in, if it is in one.
    var fence: Fence?
    var context: Context = .none
    /// Whether the last line was blank (or there was none).
    var afterBlank = true

    struct Fence: Hashable, Sendable {
        /// "`" or "~" as a UTF-16 unit.
        var marker: UInt16
        var length: Int
    }

    enum Context: UInt8, Sendable {
        /// Nothing is open.
        case none
        /// The last line was paragraph text, so an indented line continues it.
        case paragraph
        /// A list is open: indented lines are its text, not code.
        case list
        /// An indented code block is open.
        case code
    }

    /// Whether the next line is inside a fenced code block.
    public var isInsideFence: Bool {
        fence != nil
    }
}

/// One line of a note.
public struct LineInfo: Hashable, Sendable {
    /// The line with its line ending.
    public var range: NSRange
    /// The line without its line ending.
    public var contentRange: NSRange
    public var kind: BlockKind
    /// Where the line's own text starts, after its indent and its block marker ("# ", "> ", "- [ ] ").
    public var textStart: Int
    /// The scanner's state after this line.
    public var endState: BlockState
}

/// What a stretch of text inside a line is.
public enum InlineKind: Hashable, Sendable {
    /// Syntax characters ("**", "[[", "#" of a heading…). They stay in the text and are shown dimmed.
    case marker
    case emphasis
    case strong
    case strikethrough
    case highlight
    case code
    /// The visible part of a link: the inside of a wiki link, the text of a Markdown link, a bare URL.
    case link
    /// The "(destination)" of a Markdown link.
    case linkDestination
    case tag
    /// The "[ ]" or "[x]" of a task.
    case taskBox(isDone: Bool)
    /// The text of a task that is done.
    case doneTask
}

public struct InlineSpan: Hashable, Sendable {
    public var range: NSRange
    public var kind: InlineKind

    public init(range: NSRange, kind: InlineKind) {
        self.range = range
        self.kind = kind
    }
}

public struct Heading: Hashable, Sendable {
    public var level: Int
    public var text: String
    /// The heading's line, without its line ending.
    public var range: NSRange
}

/// A link of any kind, with where it is.
public struct LinkSpan: Hashable, Sendable {
    public enum Target: Hashable, Sendable {
        /// `[[Title]]` or `![[file]]`.
        case wiki(WikiLink)
        /// `[text](destination)` or `![alt](destination)`.
        case markdown(destination: String, isImage: Bool)
        /// A bare URL or `<https://…>`.
        case url(String)
    }

    public var target: Target
    /// The whole link as written, brackets included.
    public var range: NSRange
    /// The part a reader sees as the link.
    public var textRange: NSRange
    /// For a Markdown link, where its destination is written.
    public var destinationRange: NSRange?
}

public struct TagSpan: Hashable, Sendable {
    /// The tag without "#".
    public var name: String
    /// The tag with its "#".
    public var range: NSRange
}

public struct TaskSpan: Hashable, Sendable {
    /// The task's text, without the box.
    public var text: String
    public var isDone: Bool
    /// The three characters "[ ]" or "[x]".
    public var boxRange: NSRange
    /// The one character between the brackets: ticking a task changes only this.
    public var markRange: NSRange
    /// The task's line, without its line ending.
    public var lineRange: NSRange
}

/// What the scanner found. Every range is in UTF-16 units, the unit the text view uses.
public struct MarkdownScan: Hashable, Sendable {
    public var lines: [LineInfo] = []
    public var spans: [InlineSpan] = []
    public var headings: [Heading] = []
    public var links: [LinkSpan] = []
    public var tags: [TagSpan] = []
    public var tasks: [TaskSpan] = []
    /// The state after the last line.
    public var endState: BlockState = .start
}
