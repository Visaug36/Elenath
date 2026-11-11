import Foundation
import Testing

@testable import ElenathCore

@Suite("Note text")
struct NoteTextTests {
    private static let utc = TimeZone(secondsFromGMT: 0)!
    private static let plusTwo = TimeZone(secondsFromGMT: 2 * 3600)!

    /// Files of every shape: whatever is read goes back out byte for byte.
    static let roundTripSamples: [String] = [
        "",
        "Just a line",
        "Just a line\n",
        "Two\nlines\n\n\n",
        "Windows\r\nline endings\r\n",
        "Mixed\r\nendings\nin one\rfile",
        "---\n",
        "---",
        "---\n---",
        "---\n---\n",
        "---\n---\nBody",
        "---\nid: 8D2F6A1C-4B7E-4F03-A5D9-3C1E0B9F7A62\n---\nBody\n",
        "---\r\nid: 8D2F6A1C-4B7E-4F03-A5D9-3C1E0B9F7A62\r\ntags: [a, b]\r\n---\r\nBody\r\n",
        "---  \nkind: idea\n---\t\nBody",
        "---\ntags:\n  - one\n  - two\n\n# a comment\nother: {a: 1, b: [2, 3]}\n---\n\n# Title\n",
        "---\ntitle: \"Quoted: value\"   # trailing comment\naliases: ['It''s', \"x\\ty\"]\n---\ntext",
        "---\nnever closed\nid: 1\n",
        "---\nA rule, then ordinary text.\n---\nMore text\n",
        "--- not a delimiter\nkind: idea\n---\n",
        "\n---\nkind: idea\n---\nA blank line first, so no front matter\n",
        "---\nkind: idea\n----\nNot closed by four dashes\n",
        "---\nmulti: |\n  line one\n\n  line two\n---\nbody",
        "Text with a tab\tand unicode: żółć, 日本語, 🧭, e\u{301}\n",
        "---\nkey: value\n---\n---\nA rule right after the block\n",
    ]

    @Test("Whatever is read is written back byte for byte", arguments: roundTripSamples)
    func roundTrip(sample: String) throws {
        let data = Data(sample.utf8)
        #expect(try NoteText(data: data).data() == data)
        let withMark = Data([0xEF, 0xBB, 0xBF]) + data
        let note = try NoteText(data: withMark)
        #expect(note.hasByteOrderMark)
        #expect(note.data() == withMark)
    }

    @Test("Reading keys never changes the text")
    func readingChangesNothing() throws {
        let source = "---\nid: 8d2f6a1c-4b7e-4f03-a5d9-3c1e0b9f7a62\nkind: Idea\ntags: [ a , \"b c\" ]\n---\nBody"
        let note = try NoteText(data: Data(source.utf8))
        let block = try #require(note.frontMatter)
        _ = (block.id, block.kind, block.tags, block.goals, block.event, block.created(in: Self.utc))
        #expect(note.data() == Data(source.utf8))
    }

    @Test("A file that isn't UTF-8 is refused, not repaired")
    func notUTF8() {
        #expect(throws: NoteTextError.notUTF8) { try NoteText(data: Data([0x48, 0x69, 0xFF, 0xFE])) }
        #expect(throws: NoteTextError.notUTF8) { try NoteText(data: Data([0x2D, 0x2D, 0x2D, 0x0A, 0xC3, 0x28])) }
    }

    @Test("The body is everything after the block")
    func body() throws {
        let note = try NoteText(data: Data("---\nkind: goal\n---\n# Title\n\nText\n".utf8))
        #expect(note.body == "# Title\n\nText\n")
        #expect(note.kind == .goal)
        #expect(note.lineEnding == .lf)

        let windows = try NoteText(data: Data("---\r\nkind: goal\r\n---\r\nText\r\n".utf8))
        #expect(windows.body == "Text\r\n")
        #expect(windows.lineEnding == .crlf)
        #expect(windows.frontMatter?.rawText == "kind: goal\r\n")
    }

    @Test("Ordinary text between two rules is not front matter")
    func rulesAreNotFrontMatter() throws {
        let prose = "---\nA rule, then ordinary text.\n---\nMore text\n"
        #expect(try NoteText(data: Data(prose.utf8)).frontMatter == nil)
        #expect(try NoteText(data: Data(prose.utf8)).body == prose)

        let heading = "---\n# Only a heading\n---\n"
        #expect(try NoteText(data: Data(heading.utf8)).frontMatter == nil)

        let unclosed = "---\nkind: idea\n"
        #expect(try NoteText(data: Data(unclosed.utf8)).frontMatter == nil)

        let keysWithSpaces = "---\ndate created: 2024-01-05\n---\n"
        #expect(try NoteText(data: Data(keysWithSpaces.utf8)).frontMatter != nil)
    }

    @Test("A new note has an id, a created date and a body that ends with a line break")
    func newNote() throws {
        let id = NoteID(UUID(uuidString: "8D2F6A1C-4B7E-4F03-A5D9-3C1E0B9F7A62")!)
        let created = Date(timeIntervalSince1970: 1_794_313_800)  // 2026-11-10 12:30:00 UTC
        let note = NoteText(newNoteWithID: id, created: created, timeZone: Self.plusTwo, kind: .idea, body: "Hello")
        let expected =
            "---\nid: 8D2F6A1C-4B7E-4F03-A5D9-3C1E0B9F7A62\ncreated: 2026-11-10T14:30:00+02:00\nkind: idea\n---\nHello\n"
        #expect(String(decoding: note.data(), as: UTF8.self) == expected)

        let plain = NoteText(newNoteWithID: id, created: created, timeZone: Self.utc, body: "")
        #expect(
            String(decoding: plain.data(), as: UTF8.self)
                == "---\nid: 8D2F6A1C-4B7E-4F03-A5D9-3C1E0B9F7A62\ncreated: 2026-11-10T12:30:00Z\n---\n")

        let read = try NoteText(data: note.data())
        #expect(read.frontMatter?.id == id)
        #expect(read.frontMatter?.created(in: Self.utc) == created)
        #expect(read.kind == .idea)
        #expect(read.body == "Hello\n")
    }

    @Test("The first edit of a note from elsewhere adds an id and a created date, and nothing else")
    func addIdentity() throws {
        let id = NoteID(UUID(uuidString: "8D2F6A1C-4B7E-4F03-A5D9-3C1E0B9F7A62")!)
        let created = Date(timeIntervalSince1970: 1_794_313_800)

        var bare = try NoteText(data: Data("# Title\r\nText\r\n".utf8))
        let addedToBare = bare.addIdentity(id: id, created: created, timeZone: Self.utc)
        #expect(addedToBare)
        #expect(
            String(decoding: bare.data(), as: UTF8.self)
                == "---\r\nid: 8D2F6A1C-4B7E-4F03-A5D9-3C1E0B9F7A62\r\ncreated: 2026-11-10T12:30:00Z\r\n---\r\n# Title\r\nText\r\n"
        )
        let addedAgain = bare.addIdentity(id: NoteID(), created: created, timeZone: Self.utc)
        #expect(!addedAgain)

        var withBlock = try NoteText(data: Data("---\ntitle: Mine\ncreated: last spring\n---\nText".utf8))
        let addedToBlock = withBlock.addIdentity(id: id, created: created, timeZone: Self.utc)
        #expect(addedToBlock)
        #expect(
            String(decoding: withBlock.data(), as: UTF8.self)
                == "---\ntitle: Mine\ncreated: last spring\nid: 8D2F6A1C-4B7E-4F03-A5D9-3C1E0B9F7A62\n---\nText")

        // Another tool's id is not a UUID. It is never overwritten.
        var foreign = try NoteText(data: Data("---\nid: 202611101430\n---\nText".utf8))
        let addedToForeign = foreign.addIdentity(id: id, created: created, timeZone: Self.utc)
        #expect(!addedToForeign)
        #expect(String(decoding: foreign.data(), as: UTF8.self) == "---\nid: 202611101430\n---\nText")
    }

    @Test("A closing line that ended the file gets a line ending when a body is added")
    func bodyAfterBlockAtEndOfFile() throws {
        var note = try NoteText(data: Data("---\nkind: idea\n---".utf8))
        #expect(note.body.isEmpty)
        note.body = "Now with text"
        #expect(String(decoding: note.data(), as: UTF8.self) == "---\nkind: idea\n---\nNow with text")
    }
}

@Suite("Front matter")
struct FrontMatterTests {
    private static let utc = TimeZone(secondsFromGMT: 0)!

    private func parse(_ raw: String) throws -> FrontMatter {
        try #require(try NoteText(data: Data("---\n\(raw)---\n".utf8)).frontMatter)
    }

    @Test("The six keys are read in every form they are written in")
    func reading() throws {
        let block = try parse(
            """
            id: 8d2f6a1c-4b7e-4f03-a5d9-3c1e0b9f7a62
            created: 2026-11-10T14:30:00+02:00
            kind: idea
            tags: [physics, "exam prep", '#uni/year1']
            goals: ["[[Pass Physics 1]]", "[[Thesis|the thesis]]"]
            event: 4954484C-DE30-4000-8000-000000000201/2026-10-06

            """)
        #expect(block.id?.string == "8D2F6A1C-4B7E-4F03-A5D9-3C1E0B9F7A62")
        #expect(block.created(in: Self.utc) == Date(timeIntervalSince1970: 1_794_313_800))
        #expect(block.kind == .idea)
        #expect(block.tags == ["physics", "exam prep", "uni/year1"])
        #expect(block.goals == ["Pass Physics 1", "Thesis|the thesis"])
        #expect(block.event?.day == "2026-10-06")
        #expect(block.event?.eventID == UUID(uuidString: "4954484C-DE30-4000-8000-000000000201"))
        #expect(block.keys == ["id", "created", "kind", "tags", "goals", "event"])
    }

    @Test("Tags as a block list, a string, or with comments")
    func tagForms() throws {
        #expect(try parse("tags:\n  - one\n  - \"two words\"\n  - '#three'\n").tags == ["one", "two words", "three"])
        #expect(try parse("tags:\n- one\n- two\n").tags == ["one", "two"])
        #expect(try parse("tags: one, two three\n").tags == ["one", "two", "three"])
        #expect(try parse("tags: [one, two] # both\n").tags == ["one", "two"])
        #expect(try parse("tags: [One, one, ONE, two]\n").tags == ["One", "two"])
        #expect(try parse("tags:\n").tags.isEmpty)
        #expect(try parse("tags: # nothing yet\n").tags.isEmpty)
        #expect(try parse("tags: [a,\n  b]\n").tags == ["a", "b"])
        #expect(try parse("meta:\n  tags: [nested]\n").tags.isEmpty)
    }

    @Test("Goals with or without quotes")
    func goalForms() throws {
        #expect(try parse("goals:\n  - \"[[Pass Physics 1]]\"\n").goals == ["Pass Physics 1"])
        #expect(try parse("goals: [[Pass Physics 1]]\n").goals == ["Pass Physics 1"])
        #expect(try parse("goals: \"[[Pass Physics 1]]\"\n").goals == ["Pass Physics 1"])
    }

    @Test("Values that can't be read are missing, never guessed")
    func unreadableValues() throws {
        let block = try parse("id: not-a-uuid\nkind: journal\ncreated: yesterday\nevent: nothing\n")
        #expect(block.id == nil)
        #expect(block.kind == .note)
        #expect(block.created(in: Self.utc) == nil)
        #expect(block.event == nil)
        #expect(block.hasKey("id"))
    }

    @Test("Setting a key rewrites its lines and nothing else")
    func settingOneKey() throws {
        var block = try parse(
            "# my notes\ntitle:   \"Kept: as is\"\nkind: idea   # was a thought\n\ntags: [a, b]\nzeta: {x: 1}\n")
        block.kind = .goal
        #expect(block.rawText == "# my notes\ntitle:   \"Kept: as is\"\nkind: goal\n\ntags: [a, b]\nzeta: {x: 1}\n")
        block.tags = ["a", "b", "exam prep"]
        #expect(
            block.rawText
                == "# my notes\ntitle:   \"Kept: as is\"\nkind: goal\n\ntags: [a, b, \"exam prep\"]\nzeta: {x: 1}\n")
        block.kind = .note
        #expect(block.rawText == "# my notes\ntitle:   \"Kept: as is\"\n\ntags: [a, b, \"exam prep\"]\nzeta: {x: 1}\n")
        block.tags = []
        #expect(block.rawText == "# my notes\ntitle:   \"Kept: as is\"\n\nzeta: {x: 1}\n")
    }

    @Test("Setting a key to what it already holds changes nothing, however it was written")
    func settingTheSameValue() throws {
        let raw =
            "kind:   IDEA\ntags:   [ \"a\" ,b ]\ngoals:\n    - '[[G]]'\nid: 8d2f6a1c-4b7e-4f03-a5d9-3c1e0b9f7a62\n"
        var block = try parse(raw)
        block.kind = .idea
        block.tags = ["a", "b"]
        block.goals = ["G"]
        block.id = NoteID(UUID(uuidString: "8D2F6A1C-4B7E-4F03-A5D9-3C1E0B9F7A62")!)
        block.event = nil
        #expect(block.rawText == raw)
    }

    @Test("A block list stays a block list, with its indent")
    func blockListsKeepTheirStyle() throws {
        var block = try parse("tags:\n    - one\n    - two\nafter: x\n")
        block.tags = ["one", "three"]
        #expect(block.rawText == "tags:\n    - one\n    - three\nafter: x\n")

        var goals = try parse("goals:\n- \"[[A]]\"\n")
        goals.goals = ["A", "B"]
        #expect(goals.rawText == "goals:\n- \"[[A]]\"\n- \"[[B]]\"\n")
    }

    @Test("New keys go at the end, in the file's line ending")
    func newKeys() throws {
        var note = try NoteText(data: Data("---\r\ntitle: T\r\n---\r\nBody".utf8))
        note.frontMatter?.tags = ["x"]
        note.frontMatter?.event = EventLink(
            eventID: UUID(uuidString: "4954484C-DE30-4000-8000-000000000201")!, day: "2026-10-06")
        #expect(
            String(decoding: note.data(), as: UTF8.self)
                == "---\r\ntitle: T\r\ntags: [x]\r\nevent: 4954484C-DE30-4000-8000-000000000201/2026-10-06\r\n---\r\nBody"
        )
    }

    @Test("Values that YAML would read as something else are quoted")
    func quoting() throws {
        var block = FrontMatter()
        block.tags = ["plain", "uni/physics", "true", "2026", "with space", "a,b", "q\"uote", "żółć", "-dash"]
        #expect(
            block.rawText
                == "tags: [plain, uni/physics, \"true\", \"2026\", \"with space\", \"a,b\", \"q\\\"uote\", żółć, \"-dash\"]\n"
        )
        #expect(
            block.tags == ["plain", "uni/physics", "true", "2026", "with space", "a,b", "q\"uote", "żółć", "-dash"])
    }

    @Test("A key written twice ends up with one value")
    func duplicateKeys() throws {
        var block = try parse("kind: idea\nx: 1\nkind: goal\n")
        #expect(block.kind == .idea)
        block.kind = .goal
        #expect(block.rawText == "kind: goal\nx: 1\n")
    }

    @Test(
        "Created dates in the forms people write",
        arguments: [
            ("2026-11-10", 1_794_268_800.0),
            ("2026-11-10T12:30", 1_794_313_800.0),
            ("2026-11-10 12:30:00", 1_794_313_800.0),
            ("2026-11-10T12:30:00Z", 1_794_313_800.0),
            ("2026-11-10T12:30:00.250Z", 1_794_313_800.0),
            ("2026-11-10T14:30:00+02:00", 1_794_313_800.0),
            ("2026-11-10T14:30:00+0200", 1_794_313_800.0),
            ("2026-11-10T07:30:00-05", 1_794_313_800.0),
            ("2026-11-10 14:30:00 +02:00", 1_794_313_800.0),
            ("\"2026-11-10T12:30:00Z\"", 1_794_313_800.0),
        ])
    func createdForms(text: String, seconds: Double) throws {
        let block = try parse("created: \(text)\n")
        #expect(block.created(in: Self.utc) == Date(timeIntervalSince1970: seconds))
    }

    @Test("A date without a zone is read in the given time zone")
    func createdInLocalTime() throws {
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let block = try parse("created: 2026-11-10\n")
        // Midnight in New York is 05:00 UTC in November.
        #expect(block.created(in: newYork) == Date(timeIntervalSince1970: 1_794_268_800 + 5 * 3600))
        #expect(try parse("created: 2026-13-40\n").created(in: Self.utc) == nil)
        #expect(try parse("created: 2026-11-10T25:00\n").created(in: Self.utc) == nil)
    }
}
