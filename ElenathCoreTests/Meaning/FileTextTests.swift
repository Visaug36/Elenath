import Foundation
import Testing

@testable import ElenathCore

@Suite("The text of PDFs, pictures and event files")
struct FileTextTests {
    // MARK: - Kinds and limits

    @Test("A file's kind comes from its extension")
    func kinds() {
        #expect(FileTextKind(fileName: "Slides.pdf") == .pdf)
        #expect(FileTextKind(fileName: "Slides.PDF") == .pdf)
        #expect(FileTextKind(fileName: "Board.jpeg") == .picture)
        #expect(FileTextKind(fileName: "IMG_0001.HEIC") == .picture)
        #expect(FileTextKind(fileName: "Rota.txt") == .plainText)
        #expect(FileTextKind(fileName: "Draft.md") == .plainText)
        #expect(FileTextKind(fileName: ".hidden.pdf") == nil)
        #expect(FileTextKind(fileName: "archive.zip") == nil)
        #expect(FileTextKind(fileName: "README") == nil)
        #expect(FileTextKind(fileName: ".pdf") == nil)
    }

    @Test("Text is kept to its limits: the first pages, and a page cut at a character")
    func limits() {
        let many = ExtractedText(pages: (1...300).map { "page \($0)" }, isPaged: true).limited()
        #expect(many.pages.count == FileTextLimits.maximumPages)
        let budget = FileTextLimits.maximumTextBytes
        // "é" is two bytes, and the budget ends between them: the half is dropped, not kept as garbage.
        let big = String(repeating: "a", count: budget - 1) + "é" + "tail"
        let cut = ExtractedText(pages: [big, "never read"], isPaged: true).limited()
        #expect(cut.pages.count == 1)
        #expect(cut.pages[0].utf8.count == budget - 1)
        #expect(cut.pages[0].unicodeScalars.allSatisfy { $0 == "a" })
        #expect(ExtractedText.plainText(Data([0x68, 0x69, 0xFF, 0x21])).pages == ["hi\u{FFFD}!"])
        #expect(!ExtractedText(pages: [" \n\t"], isPaged: false).hasText)
    }

    // MARK: - Files in a space

    /// A space with a PDF, a picture in an attachments folder, a text file and a file that isn't the PDF its name
    /// says, indexed and read with the fake extractor.
    private struct Library {
        let fixture: LibraryFixture
        let uni: Space
        let indexer: Indexer
        let retrieval: Retrieval
        let extractor: FakeTextExtractor

        init(extractor: FakeTextExtractor = FakeTextExtractor()) async throws {
            fixture = try await LibraryFixture()
            uni = try await fixture.space("Uni")
            try fixture.write("Notes about levers.\n\n![[Whiteboard.png]]\n", to: "Uni/Physics/Lecture 7.md")
            try fixture.write(
                FakeTextExtractor.pdf("Levers and pulleys", "The moment of inertia of a hoop"),
                to: "Uni/Physics/Torque.pdf")
            try fixture.write(
                FakeTextExtractor.picture("Free body diagram of a ladder"), to: "Uni/Physics/Attachments/Whiteboard.png"
            )
            try fixture.write("Pendulum period: two pi root l over g\n", to: "Uni/Physics/Formulas.txt")
            try fixture.write("not a pdf at all", to: "Uni/Broken.pdf")
            self.extractor = extractor
            indexer = fixture.indexer()
            retrieval = fixture.retrieval()
            await indexer.setTextExtractor(extractor)
            await indexer.refreshAll()
            await indexer.readAllFiles()
        }

        func hits(_ text: String, folder: String? = nil) async throws -> [SearchHit] {
            let query = SearchQuery(
                text: text, space: folder == nil ? nil : uni.id, folder: folder.flatMap { ItemPath($0) })
            return try await retrieval.search(query, from: .everywhere)
        }

        func file(_ path: String) -> SearchHit.Item {
            .file(.space(uni.id), ItemPath(path)!)
        }
    }

    @Test("A PDF is found by the words of one of its pages, and the hit says which page")
    func pdfPages() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        let hoop = try #require(try await library.hits("hoop").first)
        #expect(hoop.item == library.file("Physics/Torque.pdf"))
        #expect(hoop.title == "Torque.pdf")
        #expect(hoop.page == 2)
        #expect(hoop.snippet.text.contains("hoop"))
        #expect(hoop.snippet.marks.count == 1)
        #expect(try await library.hits("pulleys").first?.page == 1)
        // Words on two different pages are no match for one page.
        #expect(try await library.hits("pulleys hoop").isEmpty)
        // Inside a word, as for notes.
        #expect(try await library.hits("ertia").first?.item == library.file("Physics/Torque.pdf"))
    }

    @Test("A picture in an attachments folder is found by its text and its name; the folder is no folder of notes")
    func attachments() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        let whiteboard = library.file("Physics/Attachments/Whiteboard.png")
        let byText = try await library.hits("ladder")
        #expect(byText.map(\.item) == [whiteboard])
        #expect(byText.first?.page == nil)
        #expect(try await library.hits("whiteboard").contains { $0.item == whiteboard })
        #expect(try await library.hits("ladder", folder: "Physics").map(\.item) == [whiteboard])
        #expect(try await library.hits("ladder", folder: "Biology").isEmpty)
        #expect(
            try await library.retrieval.folders(of: .space(library.uni.id), from: .everywhere) == [ItemPath("Physics")!]
        )
        // A tag or a kind narrows a search to notes.
        #expect(try await library.retrieval.search(SearchQuery(text: "ladder", kind: .note), from: .everywhere).isEmpty)
    }

    @Test("Text files are read without an extractor; PDFs and pictures wait for one")
    func plainTextWithoutExtractor() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let uni = try await fixture.space("Uni")
        try fixture.write("Pendulum period: two pi root l over g\n", to: "Uni/Formulas.txt")
        try fixture.write(FakeTextExtractor.pdf("The moment of inertia of a hoop"), to: "Uni/Torque.pdf")
        let indexer = fixture.indexer()
        let retrieval = fixture.retrieval()
        await indexer.refreshAll()
        #expect(await indexer.readAllFiles() == 1)
        let found = try await retrieval.search(SearchQuery(text: "pendulum"), from: .everywhere)
        #expect(found.map(\.item) == [.file(.space(uni.id), ItemPath("Formulas.txt")!)])
        #expect(try await retrieval.search(SearchQuery(text: "hoop"), from: .everywhere).isEmpty)
        await indexer.setTextExtractor(FakeTextExtractor())
        #expect(await indexer.readAllFiles() == 1)
        #expect(try await retrieval.search(SearchQuery(text: "hoop"), from: .everywhere).count == 1)
    }

    @Test("Only files that changed are read again, and a file that left keeps nothing behind")
    func incremental() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        #expect(library.extractor.askedNames.sorted() == ["Broken.pdf", "Torque.pdf", "Whiteboard.png"])
        await library.indexer.refreshAll()
        #expect(await library.indexer.readAllFiles() == 0)
        // The broken file isn't asked about again either.
        #expect(library.extractor.askedNames.count == 3)

        try library.fixture.write(FakeTextExtractor.pdf("A new first page about gears"), to: "Uni/Physics/Torque.pdf")
        await library.indexer.refreshAll()
        #expect(await library.indexer.readAllFiles() == 1)
        #expect(try await library.hits("hoop").isEmpty)
        #expect(try await library.hits("gears").map(\.item) == [library.file("Physics/Torque.pdf")])

        try FileManager.default.removeItem(at: library.fixture.url("Uni/Physics/Attachments/Whiteboard.png"))
        await library.indexer.refreshAll()
        #expect(try await library.hits("ladder").isEmpty)
        #expect(
            try await !library.hits("whiteboard").contains {
                $0.item == library.file("Physics/Attachments/Whiteboard.png")
            })
    }

    @Test("What was read of a file that changed meanwhile is thrown away, and the file is read again")
    func changedWhileRead() async throws {
        let once = Once()
        let extractor = FakeTextExtractor { url in
            if once.first() {
                try? Data(FakeTextExtractor.pdf("New words about lenses and mirrors").utf8).write(to: url)
            }
        }
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let uni = try await fixture.space("Uni")
        try fixture.write(FakeTextExtractor.pdf("Old words about magnets"), to: "Uni/Optics.pdf")
        let indexer = fixture.indexer()
        let retrieval = fixture.retrieval()
        await indexer.setTextExtractor(extractor)
        await indexer.refreshAll()
        #expect(try await indexer.readFiles(.space(uni.id)) == 0)
        #expect(try await retrieval.search(SearchQuery(text: "magnets"), from: .everywhere).isEmpty)
        await indexer.refreshAll()
        #expect(try await indexer.readFiles(.space(uni.id)) == 1)
        #expect(try await retrieval.search(SearchQuery(text: "lenses"), from: .everywhere).count == 1)
    }

    @Test("A reading that takes too long is given up, and isn't tried again until the file changes")
    func timeout() async throws {
        let extractor = FakeTextExtractor(hanging: ["Torque.pdf"])
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let uni = try await fixture.space("Uni")
        try fixture.write(FakeTextExtractor.pdf("The moment of inertia of a hoop"), to: "Uni/Torque.pdf")
        try fixture.write(FakeTextExtractor.picture("Free body diagram of a ladder"), to: "Uni/Ladder.png")
        let indexer = fixture.indexer()
        let retrieval = fixture.retrieval()
        await indexer.setTextExtractor(extractor)
        await indexer.setReadingTimeout(.milliseconds(200))
        await indexer.refreshAll()
        let started = Date()
        // The picture after it is read all the same, long before the hanging call would return.
        #expect(try await indexer.readFiles(.space(uni.id)) == 1)
        #expect(Date().timeIntervalSince(started) < 4)
        #expect(try await indexer.readFiles(.space(uni.id)) == 0)
        #expect(extractor.askedNames.filter { $0 == "Torque.pdf" }.count == 1)

        extractor.stopHanging()
        try fixture.write(FakeTextExtractor.pdf("The moment of inertia of a hoop, again"), to: "Uni/Torque.pdf")
        await indexer.refreshAll()
        #expect(try await indexer.readFiles(.space(uni.id)) == 1)
        #expect(try await retrieval.search(SearchQuery(text: "hoop"), from: .everywhere).count == 1)
    }

    @Test("A file whose reading was started twice and never finished isn't tried a third time")
    func crashGuard() async throws {
        let extractor = FakeTextExtractor(hanging: ["Torque.pdf"])
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let uni = try await fixture.space("Uni")
        try fixture.write(FakeTextExtractor.pdf("The moment of inertia of a hoop"), to: "Uni/Torque.pdf")
        let indexer = fixture.indexer()
        await indexer.setTextExtractor(extractor)
        await indexer.refreshAll()
        // Twice the pass is stopped while the reading hangs, as when Elenath quits or crashes mid-reading.
        for round in 1...2 {
            let pass = Task { try await indexer.readFiles(.space(uni.id)) }
            for _ in 0..<500 where extractor.askedNames.count < round {
                try await Task.sleep(for: .milliseconds(10))
            }
            pass.cancel()
            _ = await pass.result
        }
        #expect(extractor.askedNames == ["Torque.pdf", "Torque.pdf"])
        #expect(try await indexer.readFiles(.space(uni.id)) == 0)
        #expect(extractor.askedNames.count == 2)
    }

    // MARK: - Meaning

    @Test("Meaning search and related notes find files, and leave out the files a note embeds")
    func filesByMeaning() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        try library.fixture.write(
            FakeTextExtractor.picture("Free body diagram of a ladder against a wall"), to: "Uni/Physics/Ladder.png")
        try library.fixture.write("Free body diagram of a ladder, leaning.\n", to: "Uni/Physics/Ladders.md")
        await library.indexer.refreshAll()
        await library.indexer.readAllFiles()
        await library.indexer.setEmbedder(HashingEmbedder())
        await library.retrieval.setEmbedder(HashingEmbedder())
        await library.indexer.embedAll()

        let meaning = try await library.retrieval.searchByMeaning(
            SearchQuery(text: "inertia of a hoop"), from: .everywhere)
        let torque = try #require(meaning.first { $0.item == library.file("Physics/Torque.pdf") })
        #expect(torque.page == 2)

        let note = NoteRef(container: .space(library.uni.id), path: ItemPath("Physics/Ladders.md")!)
        let related = try await library.retrieval.related(to: note, from: .everywhere, limit: 10)
        #expect(related.contains { $0.item == library.file("Physics/Ladder.png") })
        #expect(related.contains { $0.item == library.file("Physics/Attachments/Whiteboard.png") })
        // Lecture 7 embeds the whiteboard: it isn't offered as related to it.
        let lecture = NoteRef(container: .space(library.uni.id), path: ItemPath("Physics/Lecture 7.md")!)
        let fromLecture = try await library.retrieval.related(to: lecture, from: .everywhere, limit: 10)
        #expect(!fromLecture.contains { $0.item == library.file("Physics/Attachments/Whiteboard.png") })
    }

    // MARK: - Event files

    @Test("Event files are indexed into their subject's home, follow it when it moves, and go nowhere without one")
    func eventFiles() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let uni = try await fixture.space("Uni")
        let ideas = try await fixture.space("Ideas")
        let store = fixture.calendarStore()
        _ = try await store.load()
        let lectures = Subject(name: "Lectures", color: .palette(.teal))
        var settings = CalendarSettings()
        settings.setHome(SubjectHome(space: uni.id, folder: ItemPath("Physics")!), forSubject: lectures.id)
        try await fixture.catalog.saveCalendarSettings(settings)
        let start = CalendarFixtures.lectureStart
        let lecture = Event(
            title: "Physics", timing: .timed(start: start, end: start.addingTimeInterval(3600), timeZone: .gmt),
            subjectID: lectures.id)
        let dentist = Event(
            title: "Dentist",
            timing: .timed(start: start.addingTimeInterval(7200), end: start.addingTimeInterval(9000), timeZone: .gmt))
        let calendar = CalendarDocument(subjects: [lectures], events: [lecture, dentist])
        try await store.save(calendar)
        let occurrence = CalendarFixtures.firstOccurrence(of: lecture)
        let lectureFolder = try await store.eventFolders.ensureFolder(for: occurrence)
        try Data(FakeTextExtractor.pdf("Slides on angular momentum").utf8).write(
            to: lectureFolder.appending(component: "Slides.pdf"))
        let dentistFolder = try await store.eventFolders.ensureFolder(
            for: CalendarFixtures.firstOccurrence(of: dentist))
        try Data(FakeTextExtractor.pdf("A walrus questionnaire").utf8).write(
            to: dentistFolder.appending(component: "Form.pdf"))

        func homes() async -> [EventFolderHome] {
            let reach = CalendarReach(
                workplace: .everywhere, spaces: await fixture.catalog.spaces(),
                settings: await fixture.catalog.calendarSettings())
            return reach.indexedHomes(
                of: await store.eventFolders.markedFolders(), in: calendar,
                calendarFolder: LibraryLayout.calendarFolder(in: fixture.root))
        }
        let found = await homes()
        #expect(found.count == 1)
        let home = try #require(found.first)
        #expect(home.space == uni.id)
        #expect(home.homeFolder == ItemPath("Physics")!)
        #expect(home.occurrence == EventLink(occurrence))
        #expect(home.folder.components.count == 2)

        let indexer = fixture.indexer()
        let retrieval = fixture.retrieval()
        await indexer.setTextExtractor(FakeTextExtractor())
        await indexer.setEventFolders(found)
        await indexer.refreshAll()
        await indexer.readAllFiles()
        let slides = try #require(home.folder.appending("Slides.pdf"))
        func items(_ text: String, folder: String? = nil) async throws -> [SearchHit.Item] {
            let query = SearchQuery(
                text: text, space: folder == nil ? nil : uni.id, folder: folder.flatMap { ItemPath($0) })
            return try await retrieval.search(query, from: .everywhere).map(\.item)
        }
        #expect(try await items("angular") == [.eventFile(.space(uni.id), EventLink(occurrence), slides)])
        #expect(try await items("slides") == [.eventFile(.space(uni.id), EventLink(occurrence), slides)])
        // Found in its home's folder, as the event's notes are.
        #expect(try await items("angular", folder: "Physics").count == 1)
        #expect(try await items("angular", folder: "Biology").isEmpty)
        // The event without a home has its files indexed nowhere.
        #expect(try await items("walrus").isEmpty)
        #expect(try await items("form").isEmpty)

        // The subject's home moves to Ideas: the files leave Uni and arrive there.
        settings.setHome(SubjectHome(space: ideas.id), forSubject: lectures.id)
        try await fixture.catalog.saveCalendarSettings(settings)
        await indexer.setEventFolders(await homes())
        // Uni no longer has the text; Ideas has the file by its name until its text is read there.
        #expect(try await items("angular").isEmpty)
        #expect(try await items("slides") == [.eventFile(.space(ideas.id), EventLink(occurrence), slides)])
        await indexer.readAllFiles()
        #expect(try await items("angular") == [.eventFile(.space(ideas.id), EventLink(occurrence), slides)])

        // Without a home, nowhere; a refresh doesn't bring them back.
        settings.setHome(nil, forSubject: lectures.id)
        try await fixture.catalog.saveCalendarSettings(settings)
        await indexer.setEventFolders(await homes())
        await indexer.refreshAll()
        #expect(try await items("angular").isEmpty)
        #expect(try await items("slides").isEmpty)
    }

    @Test("Event folders outside the calendar folder, or claimed by no event, are indexed nowhere")
    func strayEventFolders() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let uni = try await fixture.space("Uni")
        let lectures = Subject(name: "Lectures", color: .palette(.teal))
        var settings = CalendarSettings()
        settings.setHome(SubjectHome(space: uni.id), forSubject: lectures.id)
        let start = CalendarFixtures.lectureStart
        let lecture = Event(
            title: "Physics", timing: .timed(start: start, end: start.addingTimeInterval(3600), timeZone: .gmt),
            subjectID: lectures.id)
        let calendar = CalendarDocument(subjects: [lectures], events: [lecture])
        let occurrence = CalendarFixtures.firstOccurrence(of: lecture).id
        let calendarFolder = LibraryLayout.calendarFolder(in: fixture.root)
        let reach = CalendarReach(workplace: .space(uni.id), spaces: await fixture.catalog.spaces(), settings: settings)
        let elsewhere = fixture.root.deletingLastPathComponent().appending(
            component: "Elsewhere/2026-10-06/14.00 Physics")
        let unknown = Occurrence.ID(eventID: UUID(), date: occurrence.date)
        let inside = calendarFolder.appending(component: "2026-10-06/14.00 Physics")
        let homes = reach.indexedHomes(
            of: [occurrence: elsewhere, unknown: inside], in: calendar, calendarFolder: calendarFolder)
        #expect(homes.isEmpty)
        #expect(
            reach.indexedHomes(of: [occurrence: inside], in: calendar, calendarFolder: calendarFolder).map(\.space)
                == [uni.id])
    }
}

/// True the first time only, from any thread.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func first() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
