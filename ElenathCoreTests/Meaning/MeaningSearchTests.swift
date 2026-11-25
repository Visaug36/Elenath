import ElenathCore
import Foundation
import Testing

/// Search by meaning fused with keyword search, and related notes, with the stand-in embedder: texts that
/// share words are close.
@Suite("Meaning: search and related notes")
struct MeaningSearchTests {
    private struct Library {
        let fixture: LibraryFixture
        let uni: Space
        let ideas: Space
        let indexer: Indexer
        let retrieval: Retrieval

        init(embedder: HashingEmbedder? = HashingEmbedder()) async throws {
            fixture = try await LibraryFixture()
            uni = try await fixture.space("Uni")
            ideas = try await fixture.space("Ideas")
            try fixture.write(
                "---\ntags: [physics]\n---\n# Rotation\n\nMomentum is conserved when no torque acts on a spinning wheel.\n",
                to: "Uni/Physics/Momentum.md")
            try fixture.write(
                "# Angular momentum\n\nAngular momentum and torque of a spinning wheel. See [[Momentum]].\n",
                to: "Uni/Physics/Angular.md")
            try fixture.write("# Bread\n\nFlour, water, salt and a slow rise overnight.\n", to: "Ideas/Bread.md")
            try fixture.write(
                "---\nkind: idea\n---\nA spinning wheel that keeps its momentum, as a toy.\n", to: "Ideas/Toy.md")
            indexer = fixture.indexer()
            retrieval = fixture.retrieval()
            await indexer.refreshAll()
            if let embedder {
                await indexer.setEmbedder(embedder)
                await retrieval.setEmbedder(embedder)
                await indexer.embedAll()
            }
        }

        func titles(_ text: String, _ build: (inout SearchQuery) -> Void = { _ in }) async throws -> [String] {
            var query = SearchQuery(text: text, limit: 20)
            build(&query)
            return try await retrieval.searchByMeaning(query, from: .everywhere).map(\.title)
        }
    }

    @Test func meaningFindsWhatEveryWordWouldMiss() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        // Keyword search wants every word; "conserved wheel momentum toy" is in no single note.
        let keyword = try await library.retrieval.search(
            SearchQuery(text: "conserved wheel momentum toy", limit: 20), from: .everywhere)
        #expect(keyword.isEmpty)
        let found = try await library.titles("conserved wheel momentum toy")
        #expect(Set(found.prefix(3)) == ["Momentum", "Toy", "Angular"])
        #expect(!found.contains("Bread"))
    }

    @Test func aNoteBothRankingsFindComesFirst() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        let found = try await library.titles("spinning wheel")
        #expect(found.count >= 3)
        // Every one has both words; the meaning ranking breaks the tie.
        #expect(Set(found) == ["Momentum", "Angular", "Toy"])
    }

    @Test func shortQuestionsAndNoEmbedderAreKeywordSearch() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        for text in ["sp", "", "Тест кириллицей"] {
            let query = SearchQuery(text: text, limit: 20)
            let keyword = try await library.retrieval.search(query, from: .everywhere)
            #expect(try await library.retrieval.searchByMeaning(query, from: .everywhere) == keyword, "\(text)")
        }
        let without = try await Library(embedder: nil)
        defer { without.fixture.remove() }
        let query = SearchQuery(text: "conserved wheel momentum toy", limit: 20)
        #expect(try await without.retrieval.searchByMeaning(query, from: .everywhere).isEmpty)
    }

    @Test func filtersHoldForMeaningToo() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        #expect(try await library.titles("conserved wheel momentum toy") { $0.kind = .idea } == ["Toy"])
        #expect(try await library.titles("conserved wheel momentum toy") { $0.tag = "physics" } == ["Momentum"])
        #expect(
            try await library.titles("conserved wheel momentum toy") { $0.space = library.ideas.id } == ["Toy"])
        let inFolder = try await library.titles("conserved wheel momentum toy") {
            $0.space = library.uni.id
            $0.folder = ItemPath("Physics")
        }
        #expect(Set(inFolder) == ["Momentum", "Angular"])
    }

    @Test func relatedNotesShareMeaningAndLeaveOutLinkedOnes() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        let toy = NoteRef(container: .space(library.ideas.id), path: ItemPath("Toy.md")!)
        let related = try await library.retrieval.related(to: toy, from: .everywhere, limit: 5).map(\.title)
        #expect(related.first == "Momentum" || related.first == "Angular")
        #expect(Set(related) == ["Momentum", "Angular"])
        #expect(!related.contains("Toy") && !related.contains("Bread"))

        // "Angular" links to "Momentum": neither is related to the other, they are linked already.
        let angular = NoteRef(container: .space(library.uni.id), path: ItemPath("Physics/Angular.md")!)
        let fromAngular = try await library.retrieval.related(to: angular, from: .everywhere, limit: 5).map(\.title)
        #expect(fromAngular == ["Toy"])
        let momentum = NoteRef(container: .space(library.uni.id), path: ItemPath("Physics/Momentum.md")!)
        #expect(try await library.retrieval.related(to: momentum, from: .everywhere, limit: 5).map(\.title) == ["Toy"])
        #expect(try await library.retrieval.related(to: toy, from: .everywhere, limit: 0).isEmpty)
    }

    @Test func relatedNotesFollowTheChangedText() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        let bread = NoteRef(container: .space(library.ideas.id), path: ItemPath("Bread.md")!)
        #expect(try await library.retrieval.related(to: bread, from: .everywhere, limit: 5).isEmpty)
        try library.fixture.write("Bread rises like a spinning wheel keeps its momentum.\n", to: "Ideas/Bread.md")
        try await library.indexer.update([ItemPath("Bread.md")!], in: .space(library.ideas.id))
        try await library.indexer.embed(.space(library.ideas.id))
        #expect(!(try await library.retrieval.related(to: bread, from: .everywhere, limit: 5)).isEmpty)
    }
}
