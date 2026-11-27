import ElenathCore
import Foundation
import Testing

@Suite("The retrieval benchmark")
struct RetrievalBenchmarkTests {
    @Test("Every question's answer is in the demo library, and the run scores every question")
    func run() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let score = try await RetrievalBenchmark.run(
            embedder: HashingEmbedder(), extractor: nil, in: folder.child("Benchmark"),
            now: Date(timeIntervalSince1970: 1_794_321_000))
        #expect(score.asked == RetrievalBenchmark.questions.count)
        #expect(score.found + score.missed.count == score.asked)
        // Words in common are enough for the hashing embedder on some of them; the real one is measured on a Mac.
        #expect(score.found > 0)

        // Each expected title names a note or file the demo has, in a space that mixes.
        let root = folder.child("Benchmark/Library")
        var names: Set<String> = []
        let enumerator = FileManager.default.enumerator(atPath: root.path)
        while let path = enumerator?.nextObject() as? String {
            guard !path.hasPrefix("Red Cross"), !path.hasPrefix("Inbox"), !path.hasPrefix("Calendar") else { continue }
            let name = (path as NSString).lastPathComponent
            names.insert(name.hasSuffix(".md") ? String(name.dropLast(3)) : name)
        }
        for question in RetrievalBenchmark.questions {
            #expect(names.contains(question.expected), "\(question.expected)")
        }
    }

    @Test("The backlog counts the files and passages still to do, and empties as they are done")
    func backlog() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        _ = try await fixture.space("Uni")
        try fixture.write(FakeTextExtractor.pdf("The moment of inertia of a hoop"), to: "Uni/Torque.pdf")
        try fixture.write("Angular momentum is conserved.\n", to: "Uni/Lecture 8.md")
        let indexer = fixture.indexer()
        await indexer.setEmbedder(HashingEmbedder())
        await indexer.refreshAll()
        #expect(await indexer.backlog() == IndexBacklog(filesWaiting: 1, passagesWaiting: 1))
        await indexer.setTextExtractor(FakeTextExtractor())
        await indexer.readAllFiles()
        #expect(await indexer.backlog() == IndexBacklog(filesWaiting: 0, passagesWaiting: 2))
        await indexer.embedAll()
        #expect(await indexer.backlog() == IndexBacklog())
    }
}
