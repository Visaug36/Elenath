import ElenathCore
import Foundation
import Testing

@Suite("Index and retrieval")
struct IndexTests {
    /// A library with a few notes in two spaces that mix.
    private struct Library {
        let fixture: LibraryFixture
        let uni: Space
        let ideas: Space
        let indexer: Indexer
        let retrieval: Retrieval

        init() async throws {
            fixture = try await LibraryFixture()
            uni = try await fixture.space("Uni")
            ideas = try await fixture.space("Ideas")
            try fixture.write(
                """
                ---
                id: 00000000-0000-4000-8000-0000000000A1
                created: 2026-10-01T09:00:00Z
                kind: goal
                tags: [physics, exam]
                ---
                # Rotational motion

                The moment of inertia depends on the axis. See [[Reading list]] and [[Lecture 8|next week]].

                - [ ] Revise chapter 4
                - [x] Print the formula sheet
                - [ ] Ask about the résumé workshop #uni/physics
                """, to: "Uni/Physics/Lecture 7.md")
            try fixture.write("Angular momentum, continued. Back to [[Lecture 7]].\n", to: "Uni/Physics/Lecture 8.md")
            try fixture.write("- Feynman lectures\n- [ ] Order the textbook\n#reading\n", to: "Uni/Reading list.md")
            try fixture.write("An app for notes. Inspired by [[Uni/Reading list]] #idea\n", to: "Ideas/App idea.md")
            try fixture.write("東京都の天気は晴れです。物理学のノート。\n", to: "Ideas/Japan trip.md")
            try fixture.write("%PDF", to: "Uni/Physics/Formula sheet.pdf")
            try fixture.write("quick thought about inertia\n", to: "Inbox/Thought.md")
            try fixture.write("x", to: "Inbox/Scan.png")
            try fixture.setModified(Date(timeIntervalSince1970: 1_794_000_000), of: "Uni/Physics/Lecture 7.md")
            try fixture.setModified(Date(timeIntervalSince1970: 1_794_100_000), of: "Uni/Physics/Lecture 8.md")
            try fixture.setModified(Date(timeIntervalSince1970: 1_794_200_000), of: "Uni/Reading list.md")
            try fixture.setModified(Date(timeIntervalSince1970: 1_794_300_000), of: "Ideas/App idea.md")
            try fixture.setModified(Date(timeIntervalSince1970: 1_793_000_000), of: "Ideas/Japan trip.md")
            indexer = fixture.indexer()
            retrieval = fixture.retrieval()
            await indexer.refreshAll()
        }

        func titles(_ text: String, from workplace: Workplace = .everywhere, limit: Int = 50) async throws -> [String] {
            try await retrieval.search(SearchQuery(text: text, limit: limit), from: workplace).map(\.title)
        }
    }

    // MARK: - Indexing

    @Test("Only what changed is read again")
    func incremental() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        let fixture = library.fixture
        let container = Container.space(library.uni.id)

        var report = try await library.indexer.refresh(container)
        #expect(report.unchanged == 3)
        #expect(!report.changedAnything)

        try fixture.write("Angular momentum, rewritten.\n", to: "Uni/Physics/Lecture 8.md")
        try fixture.write("A new note\n", to: "Uni/Physics/Lecture 9.md")
        try FileManager.default.removeItem(at: fixture.url("Uni/Reading list.md"))
        report = try await library.indexer.refresh(container)
        #expect(report.updated == 1)
        #expect(report.added == 1)
        #expect(report.removed == 1)
        #expect(report.unchanged == 1)
        #expect(try await library.titles("rewritten") == ["Lecture 8"])
        #expect(try await library.titles("Feynman").isEmpty)

        // A file that was only touched is not rewritten in the index.
        try fixture.setModified(Date(timeIntervalSince1970: 1_794_400_000), of: "Uni/Physics/Lecture 9.md")
        report = try await library.indexer.refresh(container)
        #expect(report.updated == 0)
        #expect(report.unchanged == 3)
    }

    @Test("A file renamed or moved outside Elenath is the same note")
    func movesAreRecognized() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        let fixture = library.fixture
        let container = Container.space(library.uni.id)

        // By id: renamed and edited at once.
        let lecture = try fixture.read("Uni/Physics/Lecture 7.md")
        try FileManager.default.removeItem(at: fixture.url("Uni/Physics/Lecture 7.md"))
        try fixture.write(lecture + "\nOne more line.\n", to: "Uni/Rotation.md")
        // By file identity: moved into a folder, no id.
        try FileManager.default.createDirectory(at: fixture.url("Uni/Books"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: fixture.url("Uni/Reading list.md"), to: fixture.url("Uni/Books/To read.md"))

        let report = try await library.indexer.refresh(container)
        #expect(
            Set(report.moved) == [
                NoteMove(
                    from: fixture.ref(library.uni, "Physics/Lecture 7.md"), to: fixture.ref(library.uni, "Rotation.md")),
                NoteMove(
                    from: fixture.ref(library.uni, "Reading list.md"), to: fixture.ref(library.uni, "Books/To read.md")),
            ])
        #expect(report.added == 0)
        #expect(report.removed == 0)
        #expect(try await library.titles("inertia", from: .space(library.uni.id)) == ["Rotation"])
    }

    @Test("Updating one note after a save, and dropping one that is gone")
    func update() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        let fixture = library.fixture
        let container = Container.space(library.uni.id)

        try fixture.write("Entropy and the second law\n", to: "Uni/Physics/Lecture 8.md")
        try FileManager.default.removeItem(at: fixture.url("Uni/Reading list.md"))
        let report = try await library.indexer.update(
            [ItemPath("Physics/Lecture 8.md")!, ItemPath("Reading list.md")!, ItemPath("Physics/Attachments/x.md")!],
            in: container)
        #expect(report.updated == 1)
        #expect(report.removed == 1)
        #expect(try await library.titles("entropy") == ["Lecture 8"])
        #expect(try await library.titles("Feynman").isEmpty)
    }

    @Test("A rebuilt index holds the same as before")
    func rebuild() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        let before = try await library.titles("lecture")
        let report = try await library.indexer.rebuild(.space(library.uni.id))
        #expect(report.added == 3)
        #expect(try await library.titles("lecture") == before)
    }

    @Test("A paused indexer waits")
    func pause() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        try library.fixture.write("Added while paused: thermodynamics\n", to: "Uni/New.md")
        await library.indexer.pause()
        #expect(await library.indexer.status().isPaused)
        let indexer = library.indexer
        let container = Container.space(library.uni.id)
        let pass = Task { try await indexer.refresh(container) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await library.titles("thermodynamics").isEmpty)
        await library.indexer.resume()
        #expect(try await pass.value.added == 1)
        #expect(try await library.titles("thermodynamics") == ["New"])
    }

    // MARK: - Search

    @Test("Every word must match, the last as the start of a word, and titles count most")
    func search() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        #expect(try await library.titles("inertia") == ["Lecture 7"])
        #expect(try await library.titles("moment iner") == ["Lecture 7"])
        #expect(try await library.titles("moment nothing").isEmpty)
        // "Lecture" is in two titles and in one text: the titles come first, the newer one before the older.
        #expect(try await library.titles("lecture").prefix(2) == ["Lecture 8", "Lecture 7"])
        // Diacritics and case are folded.
        #expect(try await library.titles("RESUME workshop") == ["Lecture 7"])
        // Front matter tags are found too.
        #expect(try await library.titles("exam") == ["Lecture 7"])
        // Characters that mean something to the search engine are just text.
        #expect(try await library.titles("\"moment (of) inertia*") == ["Lecture 7"])
        #expect(try await library.titles("AND OR NOT -") == [])
    }

    @Test("Snippets mark what matched")
    func snippets() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        let hit = try #require(
            try await library.retrieval.search(SearchQuery(text: "inertia"), from: .everywhere).first)
        let marked = hit.snippet.marks.map { (hit.snippet.text as NSString).substring(with: $0) }
        #expect(marked == ["inertia"])
        #expect(!hit.snippet.text.contains("\n"))
        #expect(hit.matchedTerms == ["inertia"])
        #expect(hit.item == .note(library.fixture.ref(library.uni, "Physics/Lecture 7.md")))
    }

    @Test("Text without spaces between words, and letters inside words, are found")
    func substrings() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        #expect(try await library.titles("東京都") == ["Japan trip"])
        #expect(try await library.titles("天気") == ["Japan trip"])
        #expect(try await library.titles("ysics").contains("Japan trip") == false)
        #expect(try await library.titles("omentu") == ["Lecture 8"])
        let hit = try #require(try await library.retrieval.search(SearchQuery(text: "物理学"), from: .everywhere).first)
        #expect(hit.snippet.marks.map { (hit.snippet.text as NSString).substring(with: $0) } == ["物理学"])
    }

    @Test("Filters: space, folder, tag, kind and date")
    func filters() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        let retrieval = library.retrieval
        func titles(_ query: SearchQuery, from workplace: Workplace = .everywhere) async throws -> [String] {
            try await retrieval.search(query, from: workplace).map(\.title)
        }
        #expect(try await titles(SearchQuery(text: "", space: library.ideas.id)) == ["App idea", "Japan trip"])
        #expect(
            try await titles(SearchQuery(text: "", folder: ItemPath("Physics")), from: .space(library.uni.id))
                == ["Lecture 8", "Lecture 7"])
        #expect(
            try await titles(SearchQuery(text: "lecture", space: library.uni.id, folder: ItemPath("Physics"))).count
                == 2)
        // A folder without a space to look in names nothing.
        #expect(try await titles(SearchQuery(text: "", folder: ItemPath("Physics"))).isEmpty)
        #expect(try await titles(SearchQuery(text: "", tag: "uni")) == ["Lecture 7"])
        #expect(try await titles(SearchQuery(text: "", tag: "PHYSICS")) == ["Lecture 7"])
        #expect(try await titles(SearchQuery(text: "", kind: .goal)) == ["Lecture 7"])
        #expect(
            try await titles(SearchQuery(text: "", modifiedAfter: Date(timeIntervalSince1970: 1_794_150_000)))
                == ["App idea", "Reading list"])
        #expect(
            try await titles(SearchQuery(text: "", modifiedBefore: Date(timeIntervalSince1970: 1_793_500_000)))
                == ["Japan trip"])
        #expect(try await titles(SearchQuery(text: "", limit: 2)) == ["App idea", "Reading list"])
    }

    @Test("Files that aren't notes are found by name")
    func fileNames() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        let hits = try await library.retrieval.search(SearchQuery(text: "formula"), from: .everywhere)
        #expect(hits.map(\.title) == ["Lecture 7", "Formula sheet.pdf"])
        #expect(hits.last?.item == .file(.space(library.uni.id), ItemPath("Physics/Formula sheet.pdf")!))
        #expect(hits.last?.snippet.text == "Physics")
    }

    // MARK: - Lists

    @Test("Titles for jumping and for [[ : those that start with the text first")
    func titles() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        let retrieval = library.retrieval
        #expect(
            try await retrieval.titles(matching: "lec", from: .everywhere, limit: 10).map(\.title) == [
                "Lecture 8", "Lecture 7",
            ])
        #expect(
            try await retrieval.titles(matching: "list", from: .everywhere, limit: 10).map(\.title) == ["Reading list"])
        #expect(try await retrieval.titles(matching: "i", from: .everywhere, limit: 10).first?.title == "App idea")
        #expect(
            try await retrieval.titles(matching: "", from: .everywhere, limit: 2).map(\.title) == [
                "App idea", "Reading list",
            ])
        #expect(try await retrieval.titles(matching: "thought", from: .inbox, limit: 10).map(\.title) == ["Thought"])
    }

    @Test("Tags, with nesting, and the notes that have them")
    func tags() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        let retrieval = library.retrieval
        let tags = try await retrieval.tags(from: .everywhere)
        #expect(tags.map(\.tag) == ["exam", "idea", "physics", "reading", "uni/physics"])
        #expect(tags.map(\.count) == [1, 1, 1, 1, 1])
        #expect(try await retrieval.notes(tagged: "uni", from: .everywhere).map(\.title) == ["Lecture 7"])
        #expect(try await retrieval.notes(tagged: "Reading", from: .everywhere).map(\.title) == ["Reading list"])
        #expect(try await retrieval.notes(tagged: "phys", from: .everywhere).isEmpty)
    }

    @Test("Open tasks, recent notes and the notes of a folder")
    func lists() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        let retrieval = library.retrieval
        let tasks = try await retrieval.openTasks(from: .everywhere, limit: 10)
        #expect(
            tasks.map(\.text) == [
                "Order the textbook", "Revise chapter 4", "Ask about the résumé workshop #uni/physics",
            ])
        #expect(tasks.map(\.note.title) == ["Reading list", "Lecture 7", "Lecture 7"])
        let lecture = try library.fixture.read("Uni/Physics/Lecture 7.md")
        let body = try NoteText(data: Data(lecture.utf8)).body as NSString
        #expect(body.substring(with: NSRange(location: tasks[1].location, length: 3)) == "[ ]")

        #expect(
            try await retrieval.recentNotes(from: .everywhere, limit: 3).map(\.title) == [
                "App idea", "Reading list", "Lecture 8",
            ])
        let folder = try await retrieval.notes(in: ItemPath("Physics")!, of: .space(library.uni.id))
        #expect(folder.map(\.title) == ["Lecture 7", "Lecture 8"])
        #expect(folder.first?.kind == .goal)
        #expect(folder.first?.preview.hasPrefix("Rotational motion The moment of inertia") == true)
        #expect(folder.first?.created == Date(timeIntervalSince1970: 1_790_845_200))
        #expect(try await retrieval.inboxCount() == 2)
    }

    // MARK: - Links

    @Test("Links resolve and backlinks come back, across spaces that mix")
    func links() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        let fixture = library.fixture
        let retrieval = library.retrieval
        let lecture7 = fixture.ref(library.uni, "Physics/Lecture 7.md")
        let reading = fixture.ref(library.uni, "Reading list.md")
        let idea = fixture.ref(library.ideas, "App idea.md")

        #expect(
            try await retrieval.resolve(WikiLink(target: "Lecture 8"), from: lecture7)
                == .resolved(fixture.ref(library.uni, "Physics/Lecture 8.md")))
        #expect(try await retrieval.resolve(WikiLink(target: "App idea"), from: lecture7) == .resolved(idea))
        #expect(try await retrieval.resolve(WikiLink(target: "Thought"), from: lecture7) == .unresolved)

        let backlinks = try await retrieval.backlinks(to: reading)
        #expect(backlinks.map(\.source.title) == ["Lecture 7", "App idea"])
        #expect(backlinks.first?.context.contains("See [[Reading list]]") == true)
        let body = try NoteText(data: Data(try fixture.read("Uni/Physics/Lecture 7.md").utf8)).body as NSString
        #expect(body.substring(with: try #require(backlinks.first).range) == "[[Reading list]]")
        #expect(try await retrieval.linkingNotes(to: reading) == [lecture7, idea])
        #expect(try await retrieval.backlinks(to: idea).isEmpty)
    }

    @Test("After a rename in Finder, the notes that linked to the note are found, and their links repaired")
    func linksToANoteMovedOutside() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        let fixture = library.fixture
        let retrieval = library.retrieval
        let uni = library.uni
        let lecture7 = fixture.ref(uni, "Physics/Lecture 7.md")
        let idea = fixture.ref(library.ideas, "App idea.md")
        let old = fixture.ref(uni, "Reading list.md")
        let new = fixture.ref(uni, "Books/To read.md")
        try FileManager.default.createDirectory(at: fixture.url("Uni/Books"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: fixture.url("Uni/Reading list.md"), to: fixture.url("Uni/Books/To read.md"))
        let report = try await library.indexer.refresh(.space(uni.id))
        #expect(report.moved == [NoteMove(from: old, to: new)])

        // The links no longer reach the note, so its backlinks can't find them; judged as they were, they can.
        #expect(try await retrieval.linkingNotes(to: new).isEmpty)
        let linking = try await retrieval.linkingNotes(toMoved: report.moved)
        #expect(Set(linking) == [lecture7, idea])

        // Repaired as the app repairs them, the links reach the note again.
        func file(_ note: NoteRef) -> String {
            (note.container == .space(uni.id) ? "Uni/" : "Ideas/") + note.path.description
        }
        let after = try await retrieval.linkContext(for: .space(uni.id))
        let before = after.moving(new, to: old)
        var texts: [NoteRef: NoteText] = [:]
        for note in linking {
            texts[note] = try NoteText(data: Data(try fixture.read(file(note)).utf8))
        }
        let edits = LinkRewriter.edits(
            forMoving: [old: new], notes: linking.map { ($0, texts[$0]!.body) }, before: before.resolver,
            after: after.resolver)
        for (note, noteEdits) in Dictionary(grouping: edits, by: \.note) {
            var text = try #require(texts[note])
            text.body = LinkRewriter.apply(noteEdits, to: text.body)
            try text.data().write(to: fixture.url(file(note)))
        }
        await library.indexer.refreshAll()
        #expect(Set(try await retrieval.linkingNotes(to: new)) == [lecture7, idea])
        #expect(try await retrieval.linkingNotes(toMoved: report.moved).isEmpty)
    }

    @Test("A folder renamed in Finder: links between its notes are found, named by where the notes were")
    func linksBetweenNotesMovedOutside() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        let fixture = library.fixture
        let uni = library.uni
        try FileManager.default.moveItem(at: fixture.url("Uni/Physics"), to: fixture.url("Uni/Mechanics"))
        let report = try await library.indexer.refresh(.space(uni.id))
        #expect(
            Set(report.moved) == [
                NoteMove(
                    from: fixture.ref(uni, "Physics/Lecture 7.md"), to: fixture.ref(uni, "Mechanics/Lecture 7.md")),
                NoteMove(
                    from: fixture.ref(uni, "Physics/Lecture 8.md"), to: fixture.ref(uni, "Mechanics/Lecture 8.md")),
            ])
        #expect(
            Set(try await library.retrieval.linkingNotes(toMoved: report.moved)) == [
                fixture.ref(uni, "Physics/Lecture 7.md"), fixture.ref(uni, "Physics/Lecture 8.md"),
            ])
        #expect(try await library.retrieval.linkingNotes(toMoved: []).isEmpty)
    }

    @Test("Backlinks find a link to a note whose title has # in it")
    func backlinksToHashTitle() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let uni = try await fixture.space("Uni")
        try fixture.write("About C#.\n", to: "Uni/C# notes.md")
        try fixture.write("See [[C# notes]].\n", to: "Uni/Linker.md")
        await fixture.indexer().refreshAll()
        let retrieval = fixture.retrieval()
        let target = fixture.ref(uni, "C# notes.md")
        #expect(
            try await retrieval.resolve(
                WikiLink(inner: "C# notes", isEmbed: false)!, from: fixture.ref(uni, "Linker.md"))
                == .resolved(target))
        #expect(try await retrieval.backlinks(to: target).count == 1)
        #expect(try await retrieval.linkingNotes(to: target) == [fixture.ref(uni, "Linker.md")])
    }

    @Test("The link context follows the index: a new note resolves as soon as it is indexed")
    func linkContextIsFresh() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        let fixture = library.fixture
        let lecture7 = fixture.ref(library.uni, "Physics/Lecture 7.md")
        #expect(try await library.retrieval.resolve(WikiLink(target: "Lab report"), from: lecture7) == .unresolved)
        try fixture.write("Results\n", to: "Uni/Lab report.md")
        try await library.indexer.refresh(.space(library.uni.id))
        #expect(
            try await library.retrieval.resolve(WikiLink(target: "Lab report"), from: lecture7)
                == .resolved(fixture.ref(library.uni, "Lab report.md")))
        let context = try await library.retrieval.linkContext(for: .space(library.uni.id))
        #expect(context.catalog.count == 6)
        #expect(Set(context.spaceNames.values) == ["Uni", "Ideas"])
    }

    @Test("A note's text and its row, and a duplicated file")
    func oneNote() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        let fixture = library.fixture
        let retrieval = library.retrieval
        let lecture8 = fixture.ref(library.uni, "Physics/Lecture 8.md")
        #expect(
            try await retrieval.text(of: lecture8, from: .everywhere)
                == "Angular momentum, continued. Back to [[Lecture 7]].\n")
        #expect(try await retrieval.text(of: lecture8, from: .inbox) == nil)
        #expect(try await retrieval.note(lecture8)?.title == "Lecture 8")
        #expect(try await retrieval.note(fixture.ref(library.uni, "Nope.md")) == nil)

        // A copy made in Finder carries the same id. The one created later is the duplicate.
        let original = try fixture.read("Uni/Physics/Lecture 7.md")
        try fixture.write(
            original.replacingOccurrences(of: "2026-10-01", with: "2026-10-02"), to: "Uni/Physics/Lecture 7 copy.md")
        try await library.indexer.refresh(.space(library.uni.id))
        #expect(try await retrieval.hasDuplicatedIdentity(fixture.ref(library.uni, "Physics/Lecture 7 copy.md")))
        #expect(try await !retrieval.hasDuplicatedIdentity(fixture.ref(library.uni, "Physics/Lecture 7.md")))
        #expect(try await !retrieval.hasDuplicatedIdentity(lecture8))
    }

    @Test("Filing destinations name every space and the folders of those that aren't sealed")
    func filingDestinations() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        let destinations = await library.retrieval.filingDestinations()
        #expect(destinations.map(\.name) == ["Uni", "Ideas"])
        #expect(destinations.first?.folders == [ItemPath("Physics")!])
    }

    @Test("Ten thousand notes: search answers at once")
    func scale() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let big = try await fixture.space("Big")
        let words = ["entropy", "momentum", "inertia", "voltage", "enzyme", "syntax", "theorem", "glacier"]
        for number in 0..<10_000 {
            let word = words[number % words.count]
            try fixture.write(
                "# Note \(number)\nSome text about \(word) and number\(number), with a [[Note \(number / 2)]] link. #\(word)\n",
                to: "Big/Folder \(number % 50)/Note \(number).md")
        }
        let indexer = fixture.indexer()
        let retrieval = fixture.retrieval()
        let report = try await indexer.refresh(.space(big.id))
        #expect(report.added == 10_000)

        let clock = ContinuousClock()
        var hits: [SearchHit] = []
        let elapsed = try await clock.measure {
            hits = try await retrieval.search(SearchQuery(text: "entropy numb", limit: 20), from: .space(big.id))
        }
        #expect(hits.count == 20)
        // The target on an M1 is 100 ms. This bound is loose so that a busy CI runner doesn't fail it.
        #expect(elapsed < .seconds(2))
        #expect(
            try await retrieval.search(SearchQuery(text: "number4242"), from: .everywhere).map(\.title) == ["Note 4242"]
        )
        #expect(try await retrieval.backlinks(to: fixture.ref(big, "Folder 0/Note 100.md")).count == 2)
    }
}
