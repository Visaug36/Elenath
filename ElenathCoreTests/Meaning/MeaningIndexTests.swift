import ElenathCore
import Foundation
import Testing

/// Chunks and vectors in the index: made once, made again only for what changed or when a model changes,
/// left waiting when no model reads their script, and never while paused.
@Suite("Meaning: vectors in the index")
struct MeaningIndexTests {
    /// What the embedder was asked.
    actor Recorder {
        var requested: [String] = []
        var embedded = 0
        var rested = 0

        func request(_ script: String) { requested.append(script) }
        func count(_ texts: Int) { embedded += texts }
        func rest() { rested += 1 }
    }

    struct RecordingEmbedder: Embedder {
        var base = HashingEmbedder()
        let recorder: Recorder

        func models() async -> [EmbeddingModel] { await base.models() }

        func vectors(for texts: [String], with model: EmbeddingModel) async throws -> [[Float]?] {
            await recorder.count(texts.count)
            return try await base.vectors(for: texts, with: model)
        }

        func requestModel(for script: String) async { await recorder.request(script) }
        func rest() async { await recorder.rest() }
    }

    private struct Setup {
        let fixture: LibraryFixture
        let indexer: Indexer
        let uni: Container
        let recorder = Recorder()

        init() async throws {
            fixture = try await LibraryFixture()
            uni = .space(try await fixture.space("Uni").id)
            try fixture.write(
                "# Torque\n\nTorque turns things.\n\n# Momentum\n\nMomentum is conserved.", to: "Uni/Physics.md")
            try fixture.write("Bread needs flour and water.", to: "Uni/Bread.md")
            indexer = fixture.indexer()
            await indexer.refreshAll()
        }

        func useEmbedder(_ base: HashingEmbedder = HashingEmbedder()) async {
            await indexer.setEmbedder(RecordingEmbedder(base: base, recorder: recorder))
        }
    }

    @Test func everyChunkGetsOneVectorAndOnlyChangedNotesGetNewOnes() async throws {
        let setup = try await Setup()
        defer { setup.fixture.remove() }
        await setup.useEmbedder()
        #expect(try await setup.indexer.embed(setup.uni) == 3)
        #expect(try await setup.indexer.embed(setup.uni) == 0)

        try setup.fixture.write("# Torque\n\nTorque turns things around an axis.", to: "Uni/Physics.md")
        try await setup.indexer.update([ItemPath("Physics.md")!], in: setup.uni)
        #expect(try await setup.indexer.embed(setup.uni) == 1)
        #expect(await setup.recorder.embedded == 4)
    }

    @Test func aModelsNewRevisionMakesItsVectorsAgain() async throws {
        let setup = try await Setup()
        defer { setup.fixture.remove() }
        await setup.useEmbedder()
        #expect(try await setup.indexer.embed(setup.uni) == 3)
        await setup.useEmbedder(HashingEmbedder(revision: 2))
        #expect(try await setup.indexer.embed(setup.uni) == 3)
        #expect(try await setup.indexer.embed(setup.uni) == 0)
    }

    @Test func textWithoutAModelWaitsAndAsksForOne() async throws {
        let setup = try await Setup()
        defer { setup.fixture.remove() }
        try setup.fixture.write("Момент силы вращает тело.", to: "Uni/Physics in Russian.md")
        await setup.indexer.refreshAll()
        await setup.useEmbedder()
        #expect(try await setup.indexer.embed(setup.uni) == 3)
        #expect(await setup.recorder.requested == [Script.cyrillic])

        await setup.useEmbedder(HashingEmbedder(scripts: [Script.latin, Script.cyrillic]))
        #expect(try await setup.indexer.embed(setup.uni) == 1)
    }

    @Test func embeddingEverythingLetsTheModelsRest() async throws {
        let setup = try await Setup()
        defer { setup.fixture.remove() }
        await setup.useEmbedder()
        #expect(await setup.indexer.embedAll() == 3)
        #expect(await setup.recorder.rested == 1)
    }

    @Test func nothingIsEmbeddedWhilePaused() async throws {
        let setup = try await Setup()
        defer { setup.fixture.remove() }
        await setup.useEmbedder()
        await setup.indexer.pause()
        let indexer = setup.indexer
        let uni = setup.uni
        let running = Task { try await indexer.embed(uni) }
        try await Task.sleep(for: .milliseconds(400))
        #expect(await setup.recorder.embedded == 0)
        await indexer.resume()
        #expect(try await running.value == 3)
    }

    @Test func withoutAnEmbedderNothingHappens() async throws {
        let setup = try await Setup()
        defer { setup.fixture.remove() }
        #expect(try await setup.indexer.embed(setup.uni) == 0)
        #expect(await setup.indexer.embedAll() == 0)
    }
}
