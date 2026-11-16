import ElenathCore
import Foundation
import Testing

/// The index under strange notes, strange searches and a damaged database file. From the independent
/// review before 0.1.1 (docs/RELEASE_CHECKLIST.md).
@Suite("Index robustness")
struct IndexRobustnessTests {
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
            try fixture.write("The moment of inertia.\n", to: "Uni/Lecture 7.md")
            try fixture.write("Angular momentum.\n", to: "Uni/Lecture 8.md")
            try fixture.write("An app for notes.\n", to: "Ideas/App idea.md")
            indexer = fixture.indexer()
            retrieval = fixture.retrieval()
            await indexer.refreshAll()
        }

        func titles(_ text: String, from workplace: Workplace = .everywhere) async throws -> [String] {
            try await retrieval.search(SearchQuery(text: text, limit: 50), from: workplace).map(\.title).sorted()
        }

        var uniDatabase: URL {
            fixture.indexDirectory.appending(
                component: "\(uni.id.rawValue.uuidString).sqlite", directoryHint: .notDirectory)
        }
    }

    @Test("A NUL in a note doesn't cut its text short in the index")
    func nulInNote() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        let body = "before\u{0}after the unicorn\n"
        try library.fixture.write(body, to: "Uni/Odd.md")
        try await library.indexer.refresh(.space(library.uni.id))
        #expect(try await library.titles("unicorn") == ["Odd"])
        let odd = library.fixture.ref(library.uni, "Odd.md")
        #expect(try await library.retrieval.text(of: odd, from: .space(library.uni.id)) == body)
    }

    @Test("Control characters, quotes and a thousand words are just a search")
    func hostileSearches() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        #expect(try await library.titles("iner\u{0}tia") == ["Lecture 7"])
        #expect(try await library.titles("\u{1}\u{7f}inertia\u{0}") == ["Lecture 7"])
        let long = Array(repeating: "inertia", count: 1_000).joined(separator: " ")
        #expect(try await library.titles(long) == ["Lecture 7"])
        let words = (0..<1_000).map { "word\($0)" }.joined(separator: " ")
        #expect(try await library.titles(words).isEmpty)
        #expect(try await library.titles(String(repeating: "\"", count: 10_000)).count == 3)
        #expect(try await library.titles(String(repeating: "a", count: 100_000)).isEmpty)
    }

    @Test("One letter finds whole words only; two letters start words")
    func shortSearches() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        // "m" as the start of a word would be "moment" and "momentum", and nearly everything else.
        #expect(try await library.titles("m").isEmpty)
        #expect(try await library.titles("mo") == ["Lecture 7", "Lecture 8"])
        #expect(try await library.titles("an") == ["App idea", "Lecture 8"])
        // Letters inside a word count from three on.
        #expect(try await library.titles("om").isEmpty)
        #expect(try await library.titles("ome") == ["Lecture 7", "Lecture 8"])
    }

    @Test("A damaged index leaves other spaces searchable and is replaced at the next pass")
    func damagedIndex() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        #expect(try await library.titles("inertia") == ["Lecture 7"])

        // A fresh retrieval, as after a relaunch, meets a database file that is garbage.
        try Data(repeating: 0xA5, count: 8_192).write(to: library.uniDatabase)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: library.uniDatabase.path + suffix)
        }
        let retrieval = library.fixture.retrieval()
        #expect(try await retrieval.search(SearchQuery(text: "app"), from: .everywhere).map(\.title) == ["App idea"])

        // The indexer throws the damaged file away and builds the space's index again from its folder.
        let indexer = library.fixture.indexer()
        let report = try await indexer.refresh(.space(library.uni.id))
        #expect(report.added == 2)
        #expect(
            try await retrieval.search(SearchQuery(text: "inertia"), from: .everywhere).map(\.title) == ["Lecture 7"])
    }

    @Test("A retrieval lets go of a database file that was replaced")
    func replacedIndex() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        #expect(try await library.titles("inertia") == ["Lecture 7"])
        // The space's database is thrown away and made again, with a note the old file never had.
        await library.indexer.removeIndex(of: .space(library.uni.id))
        try library.fixture.write("A new lecture about torque.\n", to: "Uni/Lecture 9.md")
        try await library.indexer.refresh(.space(library.uni.id))
        #expect(try await library.titles("torque") == ["Lecture 9"])
        #expect(try await library.titles("inertia") == ["Lecture 7"])
    }
}
