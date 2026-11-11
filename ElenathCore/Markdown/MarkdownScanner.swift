import Foundation

/// Elenath's own small Markdown scanner (docs/ARCHITECTURE.md, "Markdown").
///
/// It doesn't build a tree and it never changes the text. It reports, for every line, what kind of block
/// the line belongs to, and inside lines where the emphasis, code, links, tags and tasks are, each with
/// its range in UTF-16 units. The editor styles from that and the index reads links, tags and tasks from
/// it.
///
/// Lines are scanned one at a time with a small state carried between them, so the editor can rescan a
/// few lines after an edit instead of the whole note.
public enum MarkdownScanner {
    /// Scans a whole note body.
    public static func scan(_ body: String) -> MarkdownScan {
        scanLines(body, offset: 0, from: .start)
    }

    /// Scans `text`, which must be whole lines, starting in `state`. Every range in the result is moved
    /// by `offset`: the place of `text` in the body it was cut from.
    public static func scanLines(_ text: String, offset: Int = 0, from state: BlockState) -> MarkdownScan {
        var scanner = LineScanner(units: Array(text.utf16), offset: offset, state: state)
        scanner.run()
        return scanner.result
    }
}

private struct LineScanner {
    let units: [UInt16]
    let offset: Int
    var state: BlockState
    var result = MarkdownScan()

    init(units: [UInt16], offset: Int, state: BlockState) {
        self.units = units
        self.offset = offset
        self.state = state
    }

    // MARK: - Lines

    mutating func run() {
        var position = 0
        while position < units.count {
            var contentEnd = position
            while contentEnd < units.count, !Unit.isLineBreak(units[contentEnd]) {
                contentEnd += 1
            }
            var end = contentEnd
            if end < units.count {
                let isPair =
                    units[end] == Unit.carriageReturn && end + 1 < units.count && units[end + 1] == Unit.lineFeed
                end += isPair ? 2 : 1
            }
            scanLine(position..<contentEnd, lineEnd: end)
            position = end
        }
        result.endState = state
    }

    private mutating func scanLine(_ content: Range<Int>, lineEnd: Int) {
        var first = content.lowerBound
        var columns = 0
        while first < content.upperBound {
            if units[first] == Unit.space {
                columns += 1
            } else if units[first] == Unit.tab {
                columns += 4 - columns % 4
            } else {
                break
            }
            first += 1
        }

        let kind: BlockKind
        var textStart = content.lowerBound
        if let fence = state.fence {
            if columns < 4 && closesFence(fence, from: first, to: content.upperBound) {
                kind = .codeFence
                state.fence = nil
                state.context = .none
                state.afterBlank = false
            } else {
                kind = .codeBlock
            }
        } else if first == content.upperBound {
            kind = .blank
            if state.context == .paragraph {
                state.context = .none
            }
            state.afterBlank = true
        } else {
            (kind, textStart) = scanBlock(content, first: first, columns: columns)
            state.afterBlank = false
        }
        result.lines.append(
            LineInfo(
                range: range(content.lowerBound..<lineEnd), contentRange: range(content), kind: kind,
                textStart: offset + textStart, endState: state))
    }

    /// A line that isn't blank and isn't inside a fence. Returns its kind and where its text starts.
    private mutating func scanBlock(_ content: Range<Int>, first: Int, columns: Int) -> (BlockKind, Int) {
        let end = content.upperBound
        if columns < 4, let fence = openingFence(from: first, to: end) {
            state.fence = fence
            state.context = .none
            return (.codeFence, content.lowerBound)
        }
        if columns >= 4 && (state.context == .none || state.context == .code) {
            state.context = .code
            return (.codeBlock, content.lowerBound)
        }
        if columns < 4 {
            if let level = headingLevel(from: first, to: end) {
                state.context = .none
                return (.heading(level: level), scanHeading(content, first: first, level: level))
            }
            if isThematicBreak(from: first, to: end) {
                add(.marker, first..<end)
                state.context = .none
                return (.thematicBreak, first)
            }
            if units[first] == Unit.greaterThan {
                state.context = .none
                return (.quote, scanQuote(first: first, end: end))
            }
        }
        if columns < 4 || state.context == .list, let markerEnd = listMarkerEnd(from: first, to: end) {
            state.context = .list
            return (.listItem(indent: columns), scanListItem(content, first: first, markerEnd: markerEnd))
        }
        if columns < 4 && units[first] == Unit.pipe {
            scanTableRow(first: first, end: end)
            state.context = .none
            return (.table, first)
        }
        scanInline(first..<end)
        if !(state.context == .list && !(state.afterBlank && columns == 0)) {
            state.context = .paragraph
        }
        return (.paragraph, first)
    }

    // MARK: - Blocks

    /// Three or more "`" or "~". A backtick fence can't have a backtick after it on its line.
    private func openingFence(from first: Int, to end: Int) -> BlockState.Fence? {
        let marker = units[first]
        guard marker == Unit.backtick || marker == Unit.tilde else { return nil }
        var index = first
        while index < end, units[index] == marker {
            index += 1
        }
        guard index - first >= 3 else { return nil }
        if marker == Unit.backtick && units[index..<end].contains(Unit.backtick) {
            return nil
        }
        return BlockState.Fence(marker: marker, length: index - first)
    }

    /// At least as many of the fence's marker as opened it, and nothing else on the line.
    private func closesFence(_ fence: BlockState.Fence, from first: Int, to end: Int) -> Bool {
        var index = first
        while index < end, units[index] == fence.marker {
            index += 1
        }
        guard index - first >= fence.length else { return false }
        return units[index..<end].allSatisfy { $0 == Unit.space || $0 == Unit.tab }
    }

    /// One to six "#" followed by a space or the end of the line.
    private func headingLevel(from first: Int, to end: Int) -> Int? {
        var index = first
        while index < end, units[index] == Unit.hash {
            index += 1
        }
        let level = index - first
        guard (1...6).contains(level), index == end || units[index] == Unit.space || units[index] == Unit.tab
        else { return nil }
        return level
    }

    private mutating func scanHeading(_ content: Range<Int>, first: Int, level: Int) -> Int {
        let end = content.upperBound
        add(.marker, first..<(first + level))
        var textStart = first + level
        while textStart < end, units[textStart] == Unit.space || units[textStart] == Unit.tab {
            textStart += 1
        }
        var textEnd = end
        while textEnd > textStart, units[textEnd - 1] == Unit.space || units[textEnd - 1] == Unit.tab {
            textEnd -= 1
        }
        // A closing run of "#" after a space is part of the marker, not of the title.
        var closing = textEnd
        while closing > textStart, units[closing - 1] == Unit.hash {
            closing -= 1
        }
        if closing < textEnd && (closing == textStart || units[closing - 1] == Unit.space) {
            add(.marker, closing..<textEnd)
            textEnd = closing
            while textEnd > textStart, units[textEnd - 1] == Unit.space || units[textEnd - 1] == Unit.tab {
                textEnd -= 1
            }
        }
        scanInline(textStart..<textEnd)
        result.headings.append(Heading(level: level, text: string(textStart..<textEnd), range: range(content)))
        return textStart
    }

    /// Three or more of "-", "*" or "_" with nothing but spaces between them.
    private func isThematicBreak(from first: Int, to end: Int) -> Bool {
        let marker = units[first]
        guard marker == Unit.hyphen || marker == Unit.asterisk || marker == Unit.underscore else { return false }
        var count = 0
        for unit in units[first..<end] {
            if unit == marker {
                count += 1
            } else if unit != Unit.space && unit != Unit.tab {
                return false
            }
        }
        return count >= 3
    }

    private mutating func scanQuote(first: Int, end: Int) -> Int {
        var index = first
        while index < end, units[index] == Unit.greaterThan {
            add(.marker, index..<(index + 1))
            index += 1
            if index < end, units[index] == Unit.space {
                index += 1
            }
        }
        scanInline(index..<end)
        return index
    }

    /// Where a list marker ends: "-", "*", "+" or up to nine digits and "." or ")", followed by a space
    /// or the end of the line.
    private func listMarkerEnd(from first: Int, to end: Int) -> Int? {
        var index = first
        let unit = units[first]
        if unit == Unit.hyphen || unit == Unit.asterisk || unit == Unit.plus {
            index += 1
        } else if Unit.isDigit(unit) {
            while index < end, Unit.isDigit(units[index]), index - first < 9 {
                index += 1
            }
            guard index < end, units[index] == Unit.period || units[index] == Unit.closeParen else { return nil }
            index += 1
        } else {
            return nil
        }
        guard index == end || units[index] == Unit.space || units[index] == Unit.tab else { return nil }
        return index
    }

    private mutating func scanListItem(_ content: Range<Int>, first: Int, markerEnd: Int) -> Int {
        let end = content.upperBound
        add(.marker, first..<markerEnd)
        var textStart = markerEnd
        while textStart < end, units[textStart] == Unit.space || units[textStart] == Unit.tab {
            textStart += 1
        }
        // A task: "[ ]", "[x]" or "[X]" and then a space or the end of the line.
        guard textStart + 3 <= end, units[textStart] == Unit.openBracket, units[textStart + 2] == Unit.closeBracket,
            textStart + 3 == end || units[textStart + 3] == Unit.space || units[textStart + 3] == Unit.tab
        else {
            scanInline(textStart..<end)
            return textStart
        }
        let mark = units[textStart + 1]
        guard mark == Unit.space || mark == Unit.lowerX || mark == Unit.upperX else {
            scanInline(textStart..<end)
            return textStart
        }
        let isDone = mark != Unit.space
        let box = textStart..<(textStart + 3)
        add(.taskBox(isDone: isDone), box)
        var taskStart = box.upperBound
        while taskStart < end, units[taskStart] == Unit.space || units[taskStart] == Unit.tab {
            taskStart += 1
        }
        if isDone {
            add(.doneTask, taskStart..<end)
        }
        scanInline(taskStart..<end)
        result.tasks.append(
            TaskSpan(
                text: string(taskStart..<end).trimmingCharacters(in: .whitespaces), isDone: isDone,
                boxRange: range(box), markRange: range((textStart + 1)..<(textStart + 2)), lineRange: range(content)))
        return taskStart
    }

    private mutating func scanTableRow(first: Int, end: Int) {
        let isDelimiterRow = units[first..<end].allSatisfy {
            $0 == Unit.pipe || $0 == Unit.hyphen || $0 == Unit.colon || $0 == Unit.space || $0 == Unit.tab
        }
        if isDelimiterRow {
            add(.marker, first..<end)
            return
        }
        var index = first
        while index < end {
            if units[index] == Unit.backslash {
                index += 2
                continue
            }
            if units[index] == Unit.pipe {
                add(.marker, index..<(index + 1))
            }
            index += 1
        }
        scanInline(first..<end)
    }

    // MARK: - Inlines

    private struct Delimiter {
        var marker: UInt16
        /// The first character of the run that is still unused.
        var start: Int
        /// How many characters of the run are still unused.
        var count: Int
        var canOpen: Bool
        var canClose: Bool
    }

    private mutating func scanInline(_ range: Range<Int>) {
        var index = range.lowerBound
        let end = range.upperBound
        var delimiters: [Delimiter] = []
        let firstSpan = result.spans.count
        defer {
            // Emphasis is paired last, so put this stretch's spans back in the order they are written.
            result.spans[firstSpan...].sort {
                ($0.range.location, -$0.range.length) < ($1.range.location, -$1.range.length)
            }
        }
        while index < end {
            let unit = units[index]
            switch unit {
            case Unit.backslash:
                if index + 1 < end, Unit.isASCIIPunctuation(units[index + 1]) {
                    add(.marker, index..<(index + 1))
                    index += 2
                } else {
                    index += 1
                }
            case Unit.backtick:
                index = scanCodeSpan(at: index, end: end)
            case Unit.exclamation:
                if index + 1 < end, units[index + 1] == Unit.openBracket,
                    let next = scanBracket(at: index + 1, bang: index, end: end)
                {
                    index = next
                } else {
                    index += 1
                }
            case Unit.openBracket:
                index = scanBracket(at: index, bang: nil, end: end) ?? index + 1
            case Unit.lessThan:
                index = scanAutolink(at: index, end: end) ?? index + 1
            case Unit.lowerH, Unit.upperH:
                index = scanBareURL(at: index, textStart: range.lowerBound, end: end) ?? index + 1
            case Unit.hash:
                index = scanTag(at: index, start: range.lowerBound, end: end) ?? index + 1
            case Unit.asterisk, Unit.underscore, Unit.tilde, Unit.equals:
                var runEnd = index
                while runEnd < end, units[runEnd] == unit {
                    runEnd += 1
                }
                if let delimiter = delimiter(marker: unit, run: index..<runEnd, in: range) {
                    delimiters.append(delimiter)
                }
                index = runEnd
            default:
                index += 1
            }
        }
        matchEmphasis(delimiters)
    }

    /// A code span: a run of backticks closed by a run of the same length on the same line. Returns
    /// where scanning goes on.
    private mutating func scanCodeSpan(at start: Int, end: Int) -> Int {
        var openEnd = start
        while openEnd < end, units[openEnd] == Unit.backtick {
            openEnd += 1
        }
        let length = openEnd - start
        var index = openEnd
        while index < end {
            guard units[index] == Unit.backtick else {
                index += 1
                continue
            }
            var runEnd = index
            while runEnd < end, units[runEnd] == Unit.backtick {
                runEnd += 1
            }
            if runEnd - index == length {
                add(.marker, start..<openEnd)
                add(.code, openEnd..<index)
                add(.marker, index..<runEnd)
                return runEnd
            }
            index = runEnd
        }
        return openEnd
    }

    /// A wiki link, an embed, a Markdown link or an image that starts with the "[" at `open` (with a "!"
    /// at `bang` in front of it). Returns where scanning goes on, or nil when there is no link here.
    private mutating func scanBracket(at open: Int, bang: Int?, end: Int) -> Int? {
        let start = bang ?? open
        if open + 1 < end, units[open + 1] == Unit.openBracket,
            let next = scanWikiLink(start: start, open: open, end: end)
        {
            return next
        }
        return scanMarkdownLink(start: start, open: open, isImage: bang != nil, end: end)
    }

    private mutating func scanWikiLink(start: Int, open: Int, end: Int) -> Int? {
        let innerStart = open + 2
        var index = innerStart
        while index < end {
            let unit = units[index]
            if unit == Unit.openBracket {
                return nil
            }
            if unit == Unit.closeBracket {
                break
            }
            index += 1
        }
        guard index + 1 < end, units[index + 1] == Unit.closeBracket,
            let link = WikiLink(inner: string(innerStart..<index), isEmbed: start != open)
        else { return nil }
        add(.marker, start..<innerStart)
        add(.link, innerStart..<index)
        add(.marker, index..<(index + 2))
        result.links.append(
            LinkSpan(
                target: .wiki(link), range: range(start..<(index + 2)), textRange: range(innerStart..<index),
                destinationRange: nil))
        return index + 2
    }

    private mutating func scanMarkdownLink(start: Int, open: Int, isImage: Bool, end: Int) -> Int? {
        // The text: up to the "]" that closes this "[".
        var depth = 0
        var close = open + 1
        while close < end {
            let unit = units[close]
            if unit == Unit.backslash {
                close += 2
                continue
            }
            if unit == Unit.openBracket {
                depth += 1
            } else if unit == Unit.closeBracket {
                if depth == 0 {
                    break
                }
                depth -= 1
            }
            close += 1
        }
        guard close + 1 < end, units[close] == Unit.closeBracket, units[close + 1] == Unit.openParen else { return nil }

        // The destination: up to the ")" that closes the "(".
        depth = 0
        var parenClose = close + 2
        while parenClose < end {
            let unit = units[parenClose]
            if unit == Unit.backslash {
                parenClose += 2
                continue
            }
            if unit == Unit.openParen {
                depth += 1
            } else if unit == Unit.closeParen {
                if depth == 0 {
                    break
                }
                depth -= 1
            }
            parenClose += 1
        }
        guard parenClose < end, units[parenClose] == Unit.closeParen else { return nil }

        var destination = (close + 2)..<parenClose
        while destination.lowerBound < destination.upperBound, units[destination.lowerBound] == Unit.space {
            destination = (destination.lowerBound + 1)..<destination.upperBound
        }
        if destination.lowerBound < destination.upperBound, units[destination.lowerBound] == Unit.lessThan,
            let closing = units[destination].firstIndex(of: Unit.greaterThan)
        {
            destination = (destination.lowerBound + 1)..<closing
        } else if let space = units[destination].firstIndex(where: { $0 == Unit.space || $0 == Unit.tab }) {
            // A title in quotes may follow the destination.
            destination = destination.lowerBound..<space
        }

        add(.marker, start..<(open + 1))
        add(.link, (open + 1)..<close)
        add(.marker, close..<(close + 1))
        add(.linkDestination, (close + 1)..<(parenClose + 1))
        result.links.append(
            LinkSpan(
                target: .markdown(destination: string(destination), isImage: isImage),
                range: range(start..<(parenClose + 1)), textRange: range((open + 1)..<close),
                destinationRange: range(destination)))
        return parenClose + 1
    }

    /// `<scheme:something>` with no spaces in it.
    private mutating func scanAutolink(at open: Int, end: Int) -> Int? {
        var index = open + 1
        guard index < end, Unit.isASCIILetter(units[index]) else { return nil }
        while index < end,
            Unit.isASCIILetter(units[index]) || Unit.isDigit(units[index]) || units[index] == Unit.plus
                || units[index] == Unit.period || units[index] == Unit.hyphen
        {
            index += 1
        }
        guard index < end, units[index] == Unit.colon, index - open > 2 else { return nil }
        while index < end, units[index] != Unit.greaterThan {
            if Unit.isWhitespace(units[index]) || units[index] == Unit.lessThan {
                return nil
            }
            index += 1
        }
        guard index < end else { return nil }
        add(.marker, open..<(open + 1))
        add(.link, (open + 1)..<index)
        add(.marker, index..<(index + 1))
        result.links.append(
            LinkSpan(
                target: .url(string((open + 1)..<index)), range: range(open..<(index + 1)),
                textRange: range((open + 1)..<index), destinationRange: nil))
        return index + 1
    }

    /// "http://…" or "https://…" in running text, without the punctuation that ends a sentence.
    private mutating func scanBareURL(at start: Int, textStart: Int, end: Int) -> Int? {
        if start > textStart, Unit.isASCIILetter(units[start - 1]) || Unit.isDigit(units[start - 1]) {
            return nil
        }
        var index = start
        for expected in LineScanner.httpPrefix {
            guard index < end, units[index] | 0x20 == expected else { return nil }
            index += 1
        }
        if index < end, units[index] | 0x20 == Unit.lowerS {
            index += 1
        }
        for expected in LineScanner.schemeSeparator {
            guard index < end, units[index] == expected else { return nil }
            index += 1
        }
        let hostStart = index
        while index < end, !Unit.isWhitespace(units[index]), units[index] != Unit.lessThan,
            units[index] != Unit.greaterThan
        {
            index += 1
        }
        // Punctuation at the end belongs to the sentence, and so does a ")" that nothing opened.
        while index > hostStart {
            let last = units[index - 1]
            if LineScanner.trailingPunctuation.contains(last) {
                index -= 1
            } else if last == Unit.closeParen {
                let opened = units[start..<index].filter { $0 == Unit.openParen }.count
                let closed = units[start..<index].filter { $0 == Unit.closeParen }.count
                guard closed > opened else { break }
                index -= 1
            } else {
                break
            }
        }
        guard index > hostStart else { return nil }
        add(.link, start..<index)
        result.links.append(
            LinkSpan(
                target: .url(string(start..<index)), range: range(start..<index), textRange: range(start..<index),
                destinationRange: nil))
        return index
    }

    /// "#tag" after the start of the text or whitespace: letters, digits, "_", "-" and "/", with at
    /// least one character that isn't a digit.
    private mutating func scanTag(at hash: Int, start: Int, end: Int) -> Int? {
        guard hash == start || Unit.isWhitespace(units[hash - 1]) else { return nil }
        var index = hash + 1
        var hasNonDigit = false
        while index < end, let (found, length) = scalar(at: index, end: end), Unit.isTagScalar(found) {
            if !(found.isASCII && Unit.isDigit(UInt16(found.value))) {
                hasNonDigit = true
            }
            index += length
        }
        guard index > hash + 1, hasNonDigit else { return nil }
        add(.tag, hash..<index)
        result.tags.append(TagSpan(name: string((hash + 1)..<index), range: range(hash..<index)))
        return index
    }

    /// A run of "*", "_", "~" or "=" as something that may open or close emphasis, by what is on either
    /// side of it. Nil when it can do neither.
    private func delimiter(marker: UInt16, run: Range<Int>, in range: Range<Int>) -> Delimiter? {
        let before: UInt16? = run.lowerBound > range.lowerBound ? units[run.lowerBound - 1] : nil
        let after: UInt16? = run.upperBound < range.upperBound ? units[run.upperBound] : nil
        let spaceBefore = before.map(Unit.isWhitespace) ?? true
        let spaceAfter = after.map(Unit.isWhitespace) ?? true
        let punctuationBefore = before.map(Unit.isPunctuation) ?? false
        let punctuationAfter = after.map(Unit.isPunctuation) ?? false
        let leftFlanking = !spaceAfter && (!punctuationAfter || spaceBefore || punctuationBefore)
        let rightFlanking = !spaceBefore && (!punctuationBefore || spaceAfter || punctuationAfter)

        var canOpen: Bool
        var canClose: Bool
        switch marker {
        case Unit.asterisk:
            canOpen = leftFlanking
            canClose = rightFlanking
        case Unit.underscore:
            // Not inside a word: snake_case_names stay as they are.
            canOpen = leftFlanking && (!rightFlanking || punctuationBefore)
            canClose = rightFlanking && (!leftFlanking || punctuationAfter)
        default:
            guard run.count >= 2 else { return nil }
            canOpen = !spaceAfter
            canClose = !spaceBefore
        }
        guard canOpen || canClose else { return nil }
        return Delimiter(marker: marker, start: run.lowerBound, count: run.count, canOpen: canOpen, canClose: canClose)
    }

    /// Pairs closers with the nearest opener of the same kind, as CommonMark does.
    private mutating func matchEmphasis(_ delimiters: [Delimiter]) {
        var openers: [Delimiter] = []
        for delimiter in delimiters {
            var closer = delimiter
            let isPair = closer.marker == Unit.tilde || closer.marker == Unit.equals
            while closer.canClose && closer.count > 0 {
                guard
                    let position = openers.lastIndex(where: {
                        $0.marker == closer.marker && $0.canOpen && (!isPair || $0.count >= 2)
                    })
                else { break }
                if isPair && closer.count < 2 {
                    break
                }
                var opener = openers[position]
                let used = isPair || (opener.count >= 2 && closer.count >= 2) ? 2 : 1
                let openStart = opener.start + opener.count - used
                let kind: InlineKind
                switch closer.marker {
                case Unit.tilde: kind = .strikethrough
                case Unit.equals: kind = .highlight
                default: kind = used == 2 ? .strong : .emphasis
                }
                add(.marker, openStart..<(openStart + used))
                add(kind, (openStart + used)..<closer.start)
                add(.marker, closer.start..<(closer.start + used))
                opener.count -= used
                closer.start += used
                closer.count -= used
                openers.removeSubrange((position + 1)...)
                if opener.count == 0 {
                    openers.remove(at: position)
                } else {
                    openers[position] = opener
                }
            }
            if closer.count > 0 && closer.canOpen {
                openers.append(closer)
            }
        }
    }

    // MARK: - Helpers

    private static let httpPrefix: [UInt16] = Array("http".utf16)
    private static let schemeSeparator: [UInt16] = Array("://".utf16)
    private static let trailingPunctuation: Set<UInt16> = Set(".,;:!?'\"*_~".utf16)

    private mutating func add(_ kind: InlineKind, _ range: Range<Int>) {
        guard !range.isEmpty else { return }
        result.spans.append(InlineSpan(range: self.range(range), kind: kind))
    }

    private func range(_ range: Range<Int>) -> NSRange {
        NSRange(location: offset + range.lowerBound, length: range.count)
    }

    private func string(_ range: Range<Int>) -> String {
        String(decoding: units[range], as: UTF16.self)
    }

    /// The scalar at `index` and how many units it takes. Nil for half of a surrogate pair.
    private func scalar(at index: Int, end: Int) -> (Unicode.Scalar, Int)? {
        let unit = units[index]
        if UTF16.isLeadSurrogate(unit) {
            guard index + 1 < end, UTF16.isTrailSurrogate(units[index + 1]) else { return nil }
            let value = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(units[index + 1]) - 0xDC00)
            return Unicode.Scalar(value).map { ($0, 2) }
        }
        return Unicode.Scalar(UInt32(unit)).map { ($0, 1) }
    }
}

/// UTF-16 units the scanner looks for, and the classes of characters it tells apart.
private enum Unit {
    static let tab: UInt16 = 0x09
    static let lineFeed: UInt16 = 0x0A
    static let carriageReturn: UInt16 = 0x0D
    static let space: UInt16 = 0x20
    static let exclamation: UInt16 = 0x21
    static let hash: UInt16 = 0x23
    static let openParen: UInt16 = 0x28
    static let closeParen: UInt16 = 0x29
    static let asterisk: UInt16 = 0x2A
    static let plus: UInt16 = 0x2B
    static let hyphen: UInt16 = 0x2D
    static let period: UInt16 = 0x2E
    static let colon: UInt16 = 0x3A
    static let lessThan: UInt16 = 0x3C
    static let equals: UInt16 = 0x3D
    static let greaterThan: UInt16 = 0x3E
    static let upperH: UInt16 = 0x48
    static let upperX: UInt16 = 0x58
    static let openBracket: UInt16 = 0x5B
    static let backslash: UInt16 = 0x5C
    static let closeBracket: UInt16 = 0x5D
    static let underscore: UInt16 = 0x5F
    static let backtick: UInt16 = 0x60
    static let lowerH: UInt16 = 0x68
    static let lowerS: UInt16 = 0x73
    static let lowerX: UInt16 = 0x78
    static let pipe: UInt16 = 0x7C
    static let tilde: UInt16 = 0x7E

    /// What ends a paragraph in a text view: LF, CR, CRLF and the paragraph separator.
    static func isLineBreak(_ unit: UInt16) -> Bool {
        unit == lineFeed || unit == carriageReturn || unit == 0x2029
    }

    static func isDigit(_ unit: UInt16) -> Bool {
        (0x30...0x39).contains(unit)
    }

    static func isASCIILetter(_ unit: UInt16) -> Bool {
        (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
    }

    static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == space || unit == tab || unit == lineFeed || unit == carriageReturn || unit == 0xA0 || unit == 0x3000
            || (0x2000...0x200A).contains(unit)
    }

    static func isASCIIPunctuation(_ unit: UInt16) -> Bool {
        (0x21...0x2F).contains(unit) || (0x3A...0x40).contains(unit) || (0x5B...0x60).contains(unit)
            || (0x7B...0x7E).contains(unit)
    }

    static func isPunctuation(_ unit: UInt16) -> Bool {
        isASCIIPunctuation(unit) || (0x2010...0x2027).contains(unit) || (0x3001...0x3003).contains(unit)
            || (0x3008...0x3011).contains(unit) || unit == 0xA1 || unit == 0xAB || unit == 0xBB || unit == 0xBF
    }

    /// What a tag is made of: letters and digits of any script, "_", "-" and "/", and emoji.
    static func isTagScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII {
            let unit = UInt16(scalar.value)
            return isASCIILetter(unit) || isDigit(unit) || unit == underscore || unit == hyphen || unit == 0x2F
        }
        let properties = scalar.properties
        if properties.isAlphabetic || properties.isEmojiPresentation || scalar.value == 0xFE0F || scalar.value == 0x200D
        {
            return true
        }
        switch properties.generalCategory {
        case .decimalNumber, .nonspacingMark, .spacingMark:
            return true
        default:
            return false
        }
    }
}
