import Foundation
import Testing

@testable import ElenathCore

@Suite("Markdown scanner")
struct MarkdownScannerTests {
    /// The text a range covers, by UTF-16 units as the text view counts them.
    private func text(_ range: NSRange, in body: String) -> String {
        (body as NSString).substring(with: range)
    }

    private func kinds(_ body: String) -> [BlockKind] {
        MarkdownScanner.scan(body).lines.map(\.kind)
    }

    private func spans(_ body: String, _ kind: InlineKind) -> [String] {
        MarkdownScanner.scan(body).spans.filter { $0.kind == kind }.map { text($0.range, in: body) }
    }

    // MARK: Blocks

    @Test("Each line gets its block kind")
    func blockKinds() {
        let body = """
            # Title
            Some text
            continues here

            ## Second
            > a quote
            - item
            * item
              1. nested
            + [ ] task
            12) numbered

            ---
            | a | b |
            |---|---|
            ####### seven is not a heading
            #not a heading
            """
        #expect(
            kinds(body) == [
                .heading(level: 1), .paragraph, .paragraph, .blank, .heading(level: 2), .quote, .listItem(indent: 0),
                .listItem(indent: 0), .listItem(indent: 2), .listItem(indent: 0), .listItem(indent: 0), .blank,
                .thematicBreak, .table, .table, .paragraph, .paragraph,
            ])
    }

    @Test("Fenced code swallows everything until the fence closes")
    func fencedCode() {
        let body = "```swift\n# not a heading\n- [ ] not a task #nottag [[not a link]]\n```\nafter #tag\n"
        let scan = MarkdownScanner.scan(body)
        #expect(scan.lines.map(\.kind) == [.codeFence, .codeBlock, .codeBlock, .codeFence, .paragraph])
        #expect(scan.headings.isEmpty)
        #expect(scan.tasks.isEmpty)
        #expect(scan.links.isEmpty)
        #expect(scan.tags.map(\.name) == ["tag"])
        #expect(scan.lines[1].endState.isInsideFence)
        #expect(!scan.lines[3].endState.isInsideFence)
    }

    @Test("A fence closes only with its own marker, at least as long")
    func fenceMarkers() {
        #expect(kinds("````\n```\n~~~\n````\nx") == [.codeFence, .codeBlock, .codeBlock, .codeFence, .paragraph])
        #expect(kinds("~~~\n```\n~~~") == [.codeFence, .codeBlock, .codeFence])
        #expect(kinds("```a`b\nx") == [.paragraph, .paragraph])
        #expect(kinds("```\nnever closed\n\n# still code") == [.codeFence, .codeBlock, .codeBlock, .codeBlock])
    }

    @Test("Indented code, but not inside a paragraph or a list")
    func indentedCode() {
        #expect(
            kinds("text\n    still text\n\n    code\n\n    more code\nback") == [
                .paragraph, .paragraph, .blank, .codeBlock, .blank, .codeBlock, .paragraph,
            ])
        #expect(
            kinds("- item\n\n    its second paragraph\n\nplain\n\n    code") == [
                .listItem(indent: 0), .blank, .paragraph, .blank, .paragraph, .blank, .codeBlock,
            ])
        #expect(kinds("\tcode with a tab") == [.codeBlock])
        #expect(
            kinds("- a\n    - nested deep\n        - deeper") == [
                .listItem(indent: 0), .listItem(indent: 4), .listItem(indent: 8),
            ])
    }

    @Test("Thematic breaks and list items are told apart")
    func thematicBreaks() {
        #expect(
            kinds("---\n***\n_ _ _\n- - -\n--\n- -x") == [
                .thematicBreak, .thematicBreak, .thematicBreak, .thematicBreak, .paragraph, .listItem(indent: 0),
            ])
    }

    @Test("Line ranges cover the text exactly, whatever the line endings")
    func lineRanges() {
        let body = "one\r\ntwo\n\nthree\rfour\u{2029}five"
        let scan = MarkdownScanner.scan(body)
        #expect(scan.lines.map { text($0.contentRange, in: body) } == ["one", "two", "", "three", "four", "five"])
        #expect(scan.lines.map(\.range.length).reduce(0, +) == (body as NSString).length)
        var expectedStart = 0
        for line in scan.lines {
            #expect(line.range.location == expectedStart)
            expectedStart = NSMaxRange(line.range)
        }
    }

    // MARK: Headings, tasks, tags

    @Test("Headings give their level and text")
    func headings() {
        let body = "# One\n## Two with `code` ##\n###\n#### Four #tag\n"
        let scan = MarkdownScanner.scan(body)
        #expect(scan.headings.map(\.level) == [1, 2, 3, 4])
        #expect(scan.headings.map(\.text) == ["One", "Two with `code`", "", "Four #tag"])
        #expect(scan.tags.map(\.name) == ["tag"])
        #expect(text(scan.headings[1].range, in: body) == "## Two with `code` ##")
        #expect(scan.lines[0].textStart == 2)
    }

    @Test("Tasks: open and done, any marker, any indent")
    func tasks() {
        let body =
            "- [ ] Revise chapter 4\n  * [x] Done **already**\n3. [X] Numbered\n- [] not a task\n- [y] nor this\n-[ ] nor this\n- [ ]\n"
        let scan = MarkdownScanner.scan(body)
        #expect(scan.tasks.map(\.text) == ["Revise chapter 4", "Done **already**", "Numbered", ""])
        #expect(scan.tasks.map(\.isDone) == [false, true, true, false])
        #expect(scan.tasks.map { text($0.boxRange, in: body) } == ["[ ]", "[x]", "[X]", "[ ]"])
        #expect(scan.tasks.map { text($0.markRange, in: body) } == [" ", "x", "X", " "])
        #expect(text(scan.tasks[1].lineRange, in: body) == "  * [x] Done **already**")
        #expect(spans(body, .doneTask) == ["Done **already**", "Numbered"])
    }

    @Test("Tags follow the format: after whitespace, not all digits, nesting with a slash")
    func tags() {
        let body =
            "#first word #uni/physics and#not #123 #1a #żółć #日本語 (#no) #a_b-c. #x#y\n# Heading\n`#code` [[#heading]] https://e.com/#frag #🧭go"
        let scan = MarkdownScanner.scan(body)
        #expect(scan.tags.map(\.name) == ["first", "uni/physics", "1a", "żółć", "日本語", "a_b-c", "x", "🧭go"])
        #expect(scan.tags.map { text($0.range, in: body) }.first == "#first")
        #expect(text(scan.tags.last!.range, in: body) == "#🧭go")
    }

    // MARK: Inlines

    @Test("Emphasis, strong, strikethrough, highlight and code")
    func emphasis() {
        let body = "*one* **two** _three_ __four__ ~~five~~ ==six== `seven` ***eight***"
        #expect(spans(body, .emphasis) == ["one", "three", "**eight**"])
        #expect(spans(body, .strong) == ["two", "four", "eight"])
        #expect(spans(body, .strikethrough) == ["five"])
        #expect(spans(body, .highlight) == ["six"])
        #expect(spans(body, .code) == ["seven"])
    }

    @Test("What is not emphasis stays plain")
    func notEmphasis() {
        #expect(spans("snake_case_name and 2 * 3 * 4 and a ** b", .emphasis).isEmpty)
        #expect(spans("snake_case_name and 2 * 3 * 4 and a ** b", .strong).isEmpty)
        #expect(spans("\\*escaped\\*", .emphasis).isEmpty)
        #expect(spans("`*code*` and ``a ` b``", .emphasis).isEmpty)
        #expect(spans("`*code*` and ``a ` b``", .code) == ["*code*", "a ` b"])
        #expect(spans("*open only", .emphasis).isEmpty)
        #expect(spans("~one tilde~ a = b == c", .strikethrough).isEmpty)
        #expect(spans("in*word*emphasis", .emphasis) == ["word"])
        #expect(spans("**bold *and italic* inside**", .strong) == ["bold *and italic* inside"])
        #expect(spans("**bold *and italic* inside**", .emphasis) == ["and italic"])
    }

    @Test("Markers are the syntax characters and nothing else")
    func markers() {
        let body = "## **b** `c` [[L|s]] [t](u) > - \\*"
        #expect(spans(body, .marker) == ["##", "**", "**", "`", "`", "[[", "]]", "[", "]", "\\"])
        #expect(spans("> quoted *text*", .marker) == [">", "*", "*"])
        #expect(spans("- item", .marker) == ["-"])
        #expect(spans("10. item", .marker) == ["10."])
        #expect(spans("| a | b |", .marker) == ["|", "|", "|"])
        #expect(spans("|---|:-:|", .marker) == ["|---|:-:|"])
    }

    // MARK: Links

    @Test("Wiki links and embeds")
    func wikiLinks() throws {
        let body =
            "See [[Lecture 7 notes]], [[Physics/Lecture 7|the lecture]], [[Other#Heading]] and ![[diagram.png|300]]."
        let scan = MarkdownScanner.scan(body)
        let links = scan.links.compactMap { span -> WikiLink? in
            if case .wiki(let link) = span.target { return link }
            return nil
        }
        #expect(links.map(\.target) == ["Lecture 7 notes", "Physics/Lecture 7", "Other", "diagram.png"])
        #expect(links.map(\.shownText) == [nil, "the lecture", nil, "300"])
        #expect(links.map(\.heading) == [nil, nil, "Heading", nil])
        #expect(links.map(\.isEmbed) == [false, false, false, true])
        #expect(scan.links.map { text($0.range, in: body) }.last == "![[diagram.png|300]]")
        #expect(text(scan.links[1].textRange, in: body) == "Physics/Lecture 7|the lecture")
        #expect(spans(body, .link).count == 4)
    }

    @Test("What is not a wiki link")
    func notWikiLinks() {
        #expect(MarkdownScanner.scan("[[]] [[ ]] [[unclosed [single] `[[code]]`").links.isEmpty)
        #expect(MarkdownScanner.scan("[[a\n]]").links.isEmpty)
    }

    @Test("Markdown links, images and URLs")
    func markdownLinks() {
        let body =
            "[text](Other%20note.md) ![alt](Attachments/d.png \"title\") [x](<a b.md>) <https://a.example/x> https://b.example/path?q=1). (https://c.example/a_(b))"
        let scan = MarkdownScanner.scan(body)
        let targets = scan.links.map(\.target)
        #expect(
            targets == [
                .markdown(destination: "Other%20note.md", isImage: false),
                .markdown(destination: "Attachments/d.png", isImage: true),
                .markdown(destination: "a b.md", isImage: false),
                .url("https://a.example/x"),
                .url("https://b.example/path?q=1"),
                .url("https://c.example/a_(b)"),
            ])
        #expect(text(scan.links[0].textRange, in: body) == "text")
        #expect(scan.links[0].destinationRange.map { text($0, in: body) } == "Other%20note.md")
        #expect(scan.links[2].destinationRange.map { text($0, in: body) } == "a b.md")
        #expect(spans(body, .linkDestination).first == "(Other%20note.md)")
        #expect(MarkdownScanner.scan("xhttp://no [text] (not a link) [ref][1] http://").links.isEmpty)
    }

    @Test("Ranges count UTF-16 units, so they are right after emoji and accents")
    func utf16Ranges() {
        let body = "🧭🧭 é [[Note]] **b** #tag"
        let scan = MarkdownScanner.scan(body)
        #expect(text(scan.links[0].range, in: body) == "[[Note]]")
        #expect(spans(body, .strong) == ["b"])
        #expect(text(scan.tags[0].range, in: body) == "#tag")
    }

    // MARK: Incremental

    @Test("Scanning line by line with the carried state gives the same as scanning everything")
    func incremental() {
        let body = """
            # Title #tag
            Text with [[a link]] and **bold**.

            ```
            code #nottag
            ```
            - [ ] task one
                continuation

            > quote\r
            | a | b |

                indented code
            last line
            """
        let whole = MarkdownScanner.scan(body)
        var combined = MarkdownScan()
        var state = BlockState.start
        for line in whole.lines {
            let piece = MarkdownScanner.scanLines(text(line.range, in: body), offset: line.range.location, from: state)
            combined.lines += piece.lines
            combined.spans += piece.spans
            combined.headings += piece.headings
            combined.links += piece.links
            combined.tags += piece.tags
            combined.tasks += piece.tasks
            state = piece.endState
            #expect(state == line.endState)
        }
        combined.endState = state
        #expect(combined == whole)
    }

    @Test("A megabyte of text scans quickly and completely")
    func largeNote() {
        let paragraph = "A line of *ordinary* text with a [[link]] and a #tag and some more words to fill it.\n"
        let body = String(repeating: paragraph, count: 12_000)
        #expect(body.utf8.count > 1_000_000)
        let scan = MarkdownScanner.scan(body)
        #expect(scan.lines.count == 12_000)
        #expect(scan.links.count == 12_000)
        #expect(scan.tags.count == 12_000)
    }
}
