import ElenathCore
import Foundation
import Testing

/// Hostile, huge and malformed input (CLAUDE.md, "Quality bar"): nothing may crash, hang or blow up.
///
/// The random inputs come from a generator with a fixed seed, so a failure is the same on every run.
/// Time limits are generous, because CI runs Debug builds; the scaling checks catch work that grows
/// faster than the input (a 16× larger input may take at most 40× as long).
@Suite("Hostile input")
struct HostileInputTests {
    /// SplitMix64: small, fast and the same on every platform.
    struct Generator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func int(_ range: Range<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.count))
        }

        mutating func pick<T>(_ items: [T]) -> T {
            items[int(0..<items.count)]
        }

        mutating func bytes(_ count: Int) -> Data {
            Data((0..<count).map { _ in UInt8(truncatingIfNeeded: next()) })
        }
    }

    /// The pieces Markdown, links, tags, tasks and front matter are made of, and some that break things.
    static let pieces = [
        "[[", "]]", "[", "]", "(", ")", "|", "#", "`", "```", "~~~", "*", "**", "_", "-", "- [ ] ", "- [x] ", "> ",
        "\n", "\r\n", "\r", "\t", "  ", " ", ":", "!", "![[", "^", "\\", "\u{0}", "\u{202E}", "👩🏽‍🔬", "e\u{301}",
        "---\n", "|---|", "#tag", "#", "[x](", "](", "http://", "mailto:", "<", "&", "%", "\"", "'", "word", "ש",
        "1. ", "    ", "id: ", "tags: [", "{", "}", "\u{FEFF}", "\u{2028}", "\u{D7FF}",
    ]

    static func hostileText(_ generator: inout Generator, pieces count: Int) -> String {
        var text = ""
        for _ in 0..<count {
            text += generator.pick(pieces)
        }
        return text
    }

    /// How long `body` takes.
    static func time(_ body: () -> Void) -> Duration {
        let clock = ContinuousClock()
        let start = clock.now
        body()
        return clock.now - start
    }

    /// The shortest of a few runs of `body`: a busy runner slows a run down, never speeds it up.
    static func bestTime(of runs: Int = 3, _ body: () -> Void) -> Duration {
        (0..<runs).map { _ in time(body) }.min() ?? .zero
    }

    /// Runs `make(n)` through `body` at a sixteenth of `size` and at full size: the full size must finish
    /// in `limit`, and take at most 40 times as long as the sixteenth. Linear work takes about 16 times
    /// as long, work that grows with n^1.5 about 64 times and quadratic work 256 times. Each size is timed
    /// at its best of three runs, and runs under 100 ms are too short to judge.
    static func expectLinear(
        _ name: String, size: Int, limit: Duration = .seconds(20), make: (Int) -> String, _ body: (String) -> Void
    ) {
        let small = make(size / 16)
        let large = make(size)
        let full = time { body(large) }
        #expect(full < limit, "\(name): \(full) for \(size)")
        if full >= limit || full <= .milliseconds(100) {
            return
        }
        let sixteenth = bestTime { body(small) }
        let bestFull = min(full, bestTime(of: 2) { body(large) })
        #expect(
            bestFull < sixteenth * 40, "\(name): \(sixteenth) for \(size / 16), \(bestFull) for \(size)")
    }

    // MARK: - Markdown

    @Test("The Markdown scanner survives random hostile notes, and every range stays inside the text")
    func scannerRandom() {
        var generator = Generator(state: 0xE1E7_A7_0001)
        for _ in 0..<800 {
            let text = HostileInputTests.hostileText(&generator, pieces: generator.int(0..<300))
            let scan = MarkdownScanner.scan(text)
            let length = (text as NSString).length
            var ranges: [NSRange] = scan.lines.map(\.range)
            ranges += scan.spans.map(\.range)
            ranges += scan.links.map(\.range)
            ranges += scan.tags.map(\.range)
            ranges += scan.tasks.map(\.boxRange)
            ranges += scan.tasks.map(\.markRange)
            ranges += scan.headings.map(\.range)
            let inside = ranges.allSatisfy { $0.location >= 0 && NSMaxRange($0) <= length }
            #expect(inside, "a range outside the text of \(text.debugDescription)")
        }
    }

    @Test("Pathological notes are scanned in time that grows with their size, not faster")
    func scannerPathological() {
        let cases: [(String, (Int) -> String)] = [
            ("open links", { String(repeating: "[[", count: $0) }),
            ("brackets", { String(repeating: "[", count: $0) }),
            ("stars", { String(repeating: "*", count: $0) }),
            ("backticks", { String(repeating: "`", count: $0) }),
            ("embeds", { String(repeating: "![[a|", count: $0 / 2) }),
            ("one long line", { String(repeating: "word ", count: $0 / 2) }),
            (
                "table",
                { "|" + String(repeating: " cell |", count: $0 / 4) + "\n|" + String(repeating: "---|", count: $0 / 4) }
            ),
            ("quotes", { String(repeating: ">", count: $0) + " deep" }),
            (
                "indents",
                { (0..<($0 / 20)).map { String(repeating: " ", count: $0 % 200) + "- item" }.joined(separator: "\n") }
            ),
            ("fences", { String(repeating: "```\n", count: $0 / 4) }),
            ("hashes", { String(repeating: "#", count: $0) + " title" }),
            ("tags", { String(repeating: "#t", count: $0 / 2) }),
            ("links", { String(repeating: "[a](b) ", count: $0 / 7) }),
            ("unclosed links", { String(repeating: "[a](", count: $0 / 4) }),
            ("nested brackets", { String(repeating: "[", count: $0 / 2) + String(repeating: "]", count: $0 / 2) }),
            ("closing parentheses", { "http://a" + String(repeating: ")", count: $0) }),
            (
                "stars and underscores",
                { String(repeating: "*a ", count: $0 / 6) + String(repeating: "a_ ", count: $0 / 6) }
            ),
            (
                "backtick runs",
                { size in
                    var text = ""
                    var length = 1
                    while text.utf16.count + length < size {
                        text += String(repeating: "`", count: length) + " "
                        length += 1
                    }
                    return text
                }
            ),
        ]
        for (name, make) in cases {
            HostileInputTests.expectLinear(name, size: 200_000, make: make) { text in
                _ = MarkdownScanner.scan(text)
            }
        }
    }

    // MARK: - Note files and front matter

    @Test("Random bytes are a note or a clean error, and a note's bytes come back unchanged")
    func noteTextRandomBytes() {
        var generator = Generator(state: 0xB17E_5)
        let prefixes = [Data(), Data([0xEF, 0xBB, 0xBF]), Data("---\n".utf8), Data("---\r\nid: x\r\n---\r\n".utf8)]
        for _ in 0..<2_000 {
            var data = generator.pick(prefixes)
            if generator.int(0..<2) == 0 {
                data += generator.bytes(generator.int(0..<200))
            } else {
                data += Data(HostileInputTests.hostileText(&generator, pieces: generator.int(0..<80)).utf8)
            }
            guard let text = try? NoteText(data: data) else { continue }
            #expect(text.data() == data, "bytes changed for \(Array(data.prefix(40)))")
            _ = text.kind
            _ = text.id
            _ = text.frontMatter?.tags
            _ = text.frontMatter?.event
        }
    }

    @Test("Front matter that is huge, deeply nested or never closed is read without trouble")
    func frontMatterHostile() throws {
        let blocks = [
            "---\n" + (0..<10_000).map { "key\($0): value \($0)" }.joined(separator: "\n") + "\n---\nBody\n",
            "---\ntags: " + String(repeating: "[", count: 20_000) + "\n---\nBody\n",
            "---\ntags: " + String(repeating: "{a: ", count: 5_000) + "\n---\nBody\n",
            "---\nid: \"" + String(repeating: "\\\"", count: 20_000) + "\n---\nBody\n",
            "---\n" + String(repeating: "  nested:\n", count: 20_000) + "---\nBody\n",
            "---\nid: 1\ntags: [a, b]\n" + String(repeating: "key: value\n", count: 20_000),
            "---\n" + String(repeating: ":", count: 50_000) + "\n---\n",
            "---\ntags: [" + String(repeating: "a, ", count: 50_000) + "]\n---\n",
        ]
        for block in blocks {
            let data = Data(block.utf8)
            let duration = HostileInputTests.time {
                if let text = try? NoteText(data: data) {
                    #expect(text.data() == data)
                    _ = text.frontMatter?.tags
                    _ = text.id
                    _ = text.kind
                }
            }
            #expect(duration < .seconds(20))
        }
    }

    // MARK: - Chats, links and names

    @Test("A chat export of broken lines is read in time, and messages keep only what they said")
    func chatExportHostile() {
        var generator = Generator(state: 0xC4A7)
        let templates = [
            "10/11/2026, 09:01 - Me: ", "[10/11/2026, 09:02:03] Me: ", "99/99/9999, 99:99 - Me: ", "1/1/1, 0:0 - : ",
            "10/11/2026, 09:01 - ", "‎", "\u{200E}10/11/2026, 09:01 - Me: ‎", "<attached: ", " (file attached)",
        ]
        let text = (0..<50_000).map { _ in
            generator.pick(templates) + HostileInputTests.hostileText(&generator, pieces: generator.int(0..<8))
        }.joined(separator: "\n")
        let duration = HostileInputTests.time {
            _ = ChatExport.isChatExport(text)
            let messages = ChatExport.messages(from: text, timeZone: TimeZone(identifier: "Europe/Amsterdam")!)
            _ = ChatExport.notes(from: messages, gap: 300)
        }
        #expect(duration < .seconds(30))
    }

    @Test("Link text of any shape is a link or nothing, never a crash")
    func wikiLinksRandom() {
        var generator = Generator(state: 0x11_4C)
        for _ in 0..<5_000 {
            let inner = HostileInputTests.hostileText(&generator, pieces: generator.int(0..<20))
            if let link = WikiLink(inner: inner, isEmbed: generator.int(0..<2) == 0) {
                _ = link.target
                _ = link.targetComponents
            }
        }
    }

    @Test("Any title becomes a safe name, and any path is a safe path or none")
    func namesRandom() {
        var generator = Generator(state: 0x5AFE)
        for _ in 0..<5_000 {
            let title = HostileInputTests.hostileText(&generator, pieces: generator.int(0..<60))
            let name = NameSanitizer.sanitizedTitle(title)
            #expect(!name.isEmpty)
            #expect(!name.contains("/") && !name.contains(":"))
            #expect(!name.hasPrefix("."))
            #expect(name.utf8.count <= 255)
            let path =
                generator.pick(["", "/", "../", "./", "a/../", "a//b/", "~/", "."])
                + HostileInputTests.hostileText(&generator, pieces: generator.int(0..<10))
            if let parsed = ItemPath(path) {
                for component in parsed.components {
                    #expect(!component.isEmpty && component != "." && component != "..")
                }
            }
        }
    }

    // MARK: - Settings files

    @Test("A settings file nested deeper than Elenath writes is refused before it is parsed")
    func settingsDepth() {
        func nested(_ depth: Int) -> Data {
            Data((String(repeating: "[", count: depth) + String(repeating: "]", count: depth)).utf8)
        }
        #expect(DocumentCodec.isSafeToParse(nested(DocumentCodec.maximumDepth)))
        #expect(!DocumentCodec.isSafeToParse(nested(DocumentCodec.maximumDepth + 1)))
        // Brackets inside strings, escaped quotes included, are text.
        let quoted = "{\"a\": \"" + String(repeating: "[{", count: 1_000) + "\\\" [[[\"}"
        #expect(DocumentCodec.isSafeToParse(Data(quoted.utf8)))
        #expect(!DocumentCodec.isSafeToParse(Data(count: DocumentCodec.maximumByteCount + 1)))
    }

    @Test("library.json and space.json that are garbage, huge or deeply nested are refused cleanly")
    func settingsHostile() {
        var generator = Generator(state: 0x15_0A)
        var documents = [
            String(repeating: "[", count: 100_000),
            String(repeating: "{\"a\":", count: 50_000),
            "{\"schemaVersion\": 1, \"id\": \"5F0C1B7E-3A0D-4B0E-9C59-0F5B6E1D2A31\", \"settings\": "
                + String(repeating: "{\"a\":", count: 50_000) + "1" + String(repeating: "}", count: 50_000) + "}",
            "{\"schemaVersion\": 1e400}",
            "{\"schemaVersion\": 1, \"id\": \"" + String(repeating: "x", count: 1_000_000) + "\"}",
            "{\"schemaVersion\": 1, \"schemaVersion\": 2}",
            "\u{FEFF}{\"schemaVersion\": -1}",
        ].map { Data($0.utf8) }
        for _ in 0..<500 {
            documents.append(generator.bytes(generator.int(0..<300)))
        }
        for data in documents {
            let duration = HostileInputTests.time {
                _ = try? DocumentCodec.decode(LibraryDocument.self, from: data)
                _ = try? DocumentCodec.decode(SpaceDocument.self, from: data)
            }
            #expect(duration < .seconds(20))
        }
    }
}
