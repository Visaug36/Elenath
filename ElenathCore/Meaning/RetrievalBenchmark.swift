import Foundation

/// Questions about the demo library, each with the note or file it should find: how well search by meaning
/// works with this Mac's embedder, measured instead of assumed (CLAUDE.md, "The index"). The questions avoid the
/// words of what they should find, so keywords alone rarely find it. The diagnostics report runs it; the score
/// decides between embedder options.
public enum RetrievalBenchmark {
    public struct Question: Hashable, Sendable {
        public var text: String
        /// The title of the note, or the name of the file, that should be among the first results.
        public var expected: String
    }

    public struct Score: Hashable, Sendable {
        public var asked: Int
        public var found: Int
        /// The questions whose note or file wasn't among the first `topCount` results.
        public var missed: [String]
    }

    /// How far down the results the expected one may be.
    public static let topCount = 5

    /// Only about notes and files in the demo's spaces that mix, so they are asked from everywhere. Invented, like
    /// the demo library.
    public static let questions: [Question] = [
        Question(text: "Why does a figure skater spin faster with her arms pulled in?", expected: "Lecture 8 notes"),
        Question(text: "What takes the place of mass for something that turns?", expected: "Lecture 7 notes"),
        Question(text: "When do I sit the physics test?", expected: "Pass Physics 1"),
        Question(text: "The yo-yo question I can't solve", expected: "Problem set 4"),
        Question(text: "Vectors a matrix only stretches", expected: "Eigenvalues"),
        Question(text: "Books still to finish", expected: "Reading list"),
        Question(text: "A tool that tidies away what I throw at it", expected: "Notes that file themselves"),
        Question(text: "Who explains which topic to the others", expected: "Study group app"),
        Question(text: "Finding the Pole Star from home", expected: "Night sky photos"),
        Question(text: "Inertia of a ring around its centre", expected: "Formula sheet.pdf"),
    ]

    /// Writes the demo library into `folder` (empty, or not there yet), indexes it with `embedder`, and with
    /// `extractor` for its files, asks every question by meaning from everywhere, and scores the answers. Nothing
    /// outside `folder` is read or written.
    public static func run(
        embedder: any Embedder, extractor: (any TextExtractor)?, in folder: URL, now: Date = Date()
    ) async throws -> Score {
        let fileSystem = LocalFileSystem()
        let root = folder.appending(component: "Library", directoryHint: .isDirectory)
        let safety = folder.appending(component: "Safety", directoryHint: .isDirectory)
        let index = folder.appending(component: "Index", directoryHint: .isDirectory)
        try fileSystem.createDirectory(at: root)
        try await DemoLibrary.write(
            to: root, safetyDirectory: safety, now: now, timeZone: .gmt, fileSystem: fileSystem)
        let catalog = LibraryCatalog(
            root: root, safetyDirectory: safety, fileSystem: fileSystem, timeSource: FixedTimeSource(now))
        _ = try await catalog.open()
        let indexer = Indexer(catalog: catalog, indexDirectory: index, fileSystem: fileSystem, timeZone: { .gmt })
        await indexer.setTextExtractor(extractor)
        await indexer.setEmbedder(embedder)
        await indexer.refreshAll()
        await indexer.readAllFiles()
        await indexer.embedAll()
        let retrieval = Retrieval(indexDirectory: index, spaces: { await catalog.spaces() })
        await retrieval.setEmbedder(embedder)
        var score = Score(asked: 0, found: 0, missed: [])
        for question in questions {
            score.asked += 1
            let hits = try await retrieval.searchByMeaning(
                SearchQuery(text: question.text, limit: topCount), from: .everywhere)
            if hits.prefix(topCount).contains(where: { $0.title == question.expected }) {
                score.found += 1
            } else {
                score.missed.append(question.text)
            }
        }
        return score
    }
}
