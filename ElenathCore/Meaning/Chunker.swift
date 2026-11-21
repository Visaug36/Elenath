import Foundation

/// A stretch of a note, a PDF page or a picture's text: what one vector stands for.
public struct Chunk: Hashable, Sendable {
    /// The heading path above it in a note ("Lecture 7", "Torque"); empty for pages and pictures.
    public var headings: [String]
    /// The source text of `range`, exactly as it is there (Markdown markers included).
    public var text: String
    /// In UTF-16 units of the note's text, or of the page's.
    public var range: NSRange
    /// The 1-based page of a PDF; nil for notes and pictures.
    public var page: Int?

    public init(headings: [String], text: String, range: NSRange, page: Int? = nil) {
        self.headings = headings
        self.text = text
        self.range = range
        self.page = page
    }

    /// What the embedder reads: the heading path in front of the text, so a paragraph keeps its topic.
    public var embeddingText: String {
        headings.isEmpty ? text : headings.joined(separator: " › ") + " — " + text
    }
}

/// Cuts notes and pages into chunks (docs/ARCHITECTURE.md, "Meaning › Chunks"), in time linear in the text.
///
/// - A note follows its Markdown structure: each ATX heading starts a chunk, and paragraphs gather until
///   about `targetCharacters`. A paragraph longer than `maximumCharacters` is cut at a sentence's end near the
///   target, else at a space, else where it must; a code block is kept whole up to the maximum and cut at
///   line ends beyond it. A section that is only a heading makes no chunk of its own; its heading stays in
///   the path of what follows.
/// - Pages (PDFs) never share a chunk; a long page is cut like a paragraph.
/// - Characters are UTF-16 units, as the ranges are; a cut never splits a surrogate pair.
public enum Chunker {
    /// About 250 tokens at 4 characters a token.
    public static let targetCharacters = 1_000
    /// Under the embedder's sequence length, so a chunk is rarely cut short by the model.
    public static let maximumCharacters = 1_600

    /// The chunks of a note's text.
    public static func chunks(ofNote text: String) -> [Chunk] {
        let units = Array(text.utf16)
        var builder = Builder(units: units, page: nil)
        var headings: [(level: Int, title: String)] = []
        var paragraph: Range<Int>? = nil
        var fence: Fence? = nil
        var fenceStart = 0

        func endParagraph() {
            if let current = paragraph {
                builder.add(current, cutting: .sentences)
                paragraph = nil
            }
        }

        var lineStart = 0
        while lineStart < units.count {
            var lineEnd = lineStart
            while lineEnd < units.count, units[lineEnd] != newline {
                lineEnd += 1
            }
            let next = lineEnd < units.count ? lineEnd + 1 : lineEnd
            let line = lineStart..<lineEnd
            defer { lineStart = next }

            if let open = fence {
                if Fence.closes(open, units: units, line: line) {
                    builder.add(fenceStart..<lineEnd, cutting: .lines)
                    fence = nil
                }
                continue
            }
            if let open = Fence.opening(units: units, line: line) {
                endParagraph()
                fence = open
                fenceStart = lineStart
                continue
            }
            if let heading = Heading.parse(units: units, line: line) {
                endParagraph()
                while let last = headings.last, last.level >= heading.level {
                    headings.removeLast()
                }
                headings.append((heading.level, heading.title))
                builder.startSection(headings: headings.map(\.title), at: line)
                continue
            }
            if isBlank(units: units, line: line) {
                endParagraph()
                continue
            }
            paragraph = (paragraph?.lowerBound ?? lineStart)..<lineEnd
        }
        if fence != nil {
            // A code block that never closes runs to the end.
            builder.add(fenceStart..<units.count, cutting: .lines)
        }
        endParagraph()
        return builder.finish()
    }

    /// The chunks of text by pages (a PDF's): `page` is 1-based, and ranges are in each page's own text.
    public static func chunks(ofPages pages: [String]) -> [Chunk] {
        var chunks: [Chunk] = []
        for (index, page) in pages.enumerated() {
            let units = Array(page.utf16)
            guard let range = trimmed(0..<units.count, units: units) else { continue }
            var builder = Builder(units: units, page: index + 1)
            builder.add(range, cutting: .sentences)
            chunks += builder.finish()
        }
        return chunks
    }

    // MARK: - Building

    fileprivate enum Cut {
        /// At a sentence's end, else a space: paragraphs and pages.
        case sentences
        /// At a line's end: code.
        case lines
    }

    private struct Builder {
        let units: [UInt16]
        let page: Int?
        private(set) var chunks: [Chunk] = []
        private var start = 0
        private var end = 0
        private var headings: [String] = []
        private var hasBody = false
        /// Where the pending heading line starts, when the section has no body yet.
        private var headingStart: Int? = nil

        init(units: [UInt16], page: Int?) {
            self.units = units
            self.page = page
        }

        /// A heading starts a section: what was gathered becomes a chunk.
        mutating func startSection(headings: [String], at line: Range<Int>) {
            close()
            self.headings = headings
            headingStart = line.lowerBound
            start = line.lowerBound
            end = line.upperBound
        }

        mutating func add(_ block: Range<Int>, cutting: Cut) {
            guard let block = Chunker.trimmed(block, units: units) else { return }
            if block.count > Chunker.maximumCharacters {
                // A long block becomes chunks of its own; the section's heading line, if nothing followed it
                // yet, goes with the first.
                let first = hasBody ? block.lowerBound : (headingStart ?? block.lowerBound)
                close()
                emitPieces(of: first..<block.upperBound, cutting: cutting)
                return
            }
            if hasBody, block.upperBound - start > Chunker.targetCharacters {
                close()
            }
            if !hasBody {
                start = headingStart ?? block.lowerBound
                hasBody = true
            }
            end = block.upperBound
        }

        mutating func finish() -> [Chunk] {
            close()
            return chunks
        }

        private mutating func close() {
            if hasBody {
                append(start..<end)
            }
            hasBody = false
            headingStart = nil
        }

        private mutating func emitPieces(of range: Range<Int>, cutting: Cut) {
            var pieceStart = range.lowerBound
            while range.upperBound - pieceStart > Chunker.maximumCharacters {
                let cut = cutPoint(from: pieceStart, limit: range.upperBound, cutting: cutting)
                append(pieceStart..<cut)
                pieceStart = cut
                while pieceStart < range.upperBound, Chunker.isWhitespace(units[pieceStart]) {
                    pieceStart += 1
                }
            }
            if pieceStart < range.upperBound {
                append(pieceStart..<range.upperBound)
            }
        }

        /// Where to end a piece that starts at `from`: after a sentence's end (or a line's, for code) between
        /// half the target and the maximum, latest first; else at a space; else at the maximum.
        private func cutPoint(from: Int, limit: Int, cutting: Cut) -> Int {
            let latest = min(from + Chunker.maximumCharacters, limit)
            let earliest = from + Chunker.targetCharacters / 2
            var index = latest - 1
            while index > earliest {
                switch cutting {
                case .lines:
                    if units[index] == Chunker.newline {
                        return index + 1
                    }
                case .sentences:
                    if Chunker.isWhitespace(units[index]), Chunker.endsSentence(units[index - 1]) {
                        return index + 1
                    }
                }
                index -= 1
            }
            index = latest - 1
            while index > earliest {
                if Chunker.isWhitespace(units[index]) {
                    return index + 1
                }
                index -= 1
            }
            // A low surrogate belongs with the high one before it.
            return UTF16.isTrailSurrogate(units[latest - 1]) || !UTF16.isTrailSurrogate(units[latest])
                ? latest : latest - 1
        }

        private mutating func append(_ range: Range<Int>) {
            guard let range = Chunker.trimmed(range, units: units) else { return }
            let text = String(decoding: units[range], as: UTF16.self)
            chunks.append(
                Chunk(
                    headings: headings, text: text,
                    range: NSRange(location: range.lowerBound, length: range.count), page: page))
        }
    }

    // MARK: - Lines

    private struct Heading {
        var level: Int
        var title: String

        /// An ATX heading: up to three spaces, one to six "#", then a space or the end of the line.
        static func parse(units: [UInt16], line: Range<Int>) -> Heading? {
            var index = line.lowerBound
            var indent = 0
            while index < line.upperBound, units[index] == space, indent < 3 {
                index += 1
                indent += 1
            }
            var level = 0
            while index < line.upperBound, units[index] == hash {
                level += 1
                index += 1
            }
            guard (1...6).contains(level), index == line.upperBound || isWhitespace(units[index]) else { return nil }
            var titleEnd = line.upperBound
            // A closing run of "#" isn't part of the title.
            while titleEnd > index, isWhitespace(units[titleEnd - 1]) || units[titleEnd - 1] == hash {
                titleEnd -= 1
            }
            let title = String(decoding: units[index..<max(index, titleEnd)], as: UTF16.self)
                .trimmingCharacters(in: .whitespaces)
            return Heading(level: level, title: title)
        }
    }

    private struct Fence {
        var character: UInt16
        var count: Int

        /// "```" or "~~~" (three or more), after up to three spaces.
        static func opening(units: [UInt16], line: Range<Int>) -> Fence? {
            var index = line.lowerBound
            var indent = 0
            while index < line.upperBound, units[index] == space, indent < 3 {
                index += 1
                indent += 1
            }
            guard index < line.upperBound, units[index] == backtick || units[index] == tilde else { return nil }
            let character = units[index]
            var count = 0
            while index < line.upperBound, units[index] == character {
                count += 1
                index += 1
            }
            return count >= 3 ? Fence(character: character, count: count) : nil
        }

        /// A line of only the same character, at least as many, closes the block.
        static func closes(_ fence: Fence, units: [UInt16], line: Range<Int>) -> Bool {
            guard let found = opening(units: units, line: line), found.character == fence.character,
                found.count >= fence.count
            else { return false }
            var index = line.lowerBound
            while index < line.upperBound, units[index] == space || units[index] == fence.character {
                index += 1
            }
            return isBlank(units: units, line: index..<line.upperBound)
        }
    }

    // MARK: - Characters

    fileprivate static let newline: UInt16 = 0x0A
    private static let space: UInt16 = 0x20
    private static let hash: UInt16 = 0x23
    private static let backtick: UInt16 = 0x60
    private static let tilde: UInt16 = 0x7E

    fileprivate static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == space || unit == newline || unit == 0x09 || unit == 0x0D || unit == 0xA0 || unit == 0x3000
    }

    fileprivate static func endsSentence(_ unit: UInt16) -> Bool {
        // . ! ? and their full-width forms, and the ideographic full stop.
        [0x2E, 0x21, 0x3F, 0xFF0E, 0xFF01, 0xFF1F, 0x3002].contains(unit)
    }

    private static func isBlank(units: [UInt16], line: Range<Int>) -> Bool {
        line.allSatisfy { isWhitespace(units[$0]) }
    }

    /// `range` without whitespace at either end, or nil when nothing else is in it.
    fileprivate static func trimmed(_ range: Range<Int>, units: [UInt16]) -> Range<Int>? {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, isWhitespace(units[lower]) {
            lower += 1
        }
        while upper > lower, isWhitespace(units[upper - 1]) {
            upper -= 1
        }
        return lower < upper ? lower..<upper : nil
    }
}
