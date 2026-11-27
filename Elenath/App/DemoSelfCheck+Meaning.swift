import ElenathCore
import Foundation

/// The crash check's steps for 0.3, with the runner's real PDFKit, Vision and embedder: files' text is read and
/// found, an event file only where its home space may be read, related notes stay on their side of the seal,
/// and pausing holds back the background passes.
extension DemoSelfCheck {
    func readFilesAndFindMeaning() async throws {
        guard let services = model.services, let uni = model.spaces.first(where: { $0.name == "Uni" }),
            let redCross = model.spaces.first(where: { $0.name == "Red Cross" })
        else { throw Failure(description: "the demo's spaces are missing") }
        try await waitForBackground("the files to be read") { $0.filesWaiting == 0 }
        let retrieval = services.retrieval
        func hits(_ text: String, from workplace: Workplace) async throws -> [SearchHit] {
            try await retrieval.search(SearchQuery(text: text, limit: 50), from: workplace)
        }
        func isEventFile(_ hit: SearchHit) -> Bool {
            if case .eventFile = hit.item { true } else { false }
        }

        // A PDF beside the notes, by the words of its second page.
        let sheet = SearchHit.Item.file(.space(uni.id), ItemPath("Physics/Formula sheet.pdf")!)
        guard let hoop = try await hits("hoop", from: .everywhere).first(where: { $0.item == sheet }), hoop.page == 2
        else { throw Failure(description: "the formula sheet's second page wasn't found by its text") }
        // A photo in a lecture's attachments, read by Vision.
        let photo = SearchHit.Item.file(.space(uni.id), ItemPath("Physics/Attachments/Whiteboard - torque.png")!)
        var foundPhoto = false
        for word in ["wrench", "handle", "force"] where !foundPhoto {
            foundPhoto = try await hits(word, from: .everywhere).contains { $0.item == photo }
        }
        guard foundPhoto else { throw Failure(description: "the whiteboard photo's text wasn't recognized") }
        // An event file in its home space's index: the lecture's slides, by their text.
        guard try await hits("inertia", from: .space(uni.id)).contains(where: isEventFile) else {
            throw Failure(description: "the lecture's slides weren't found by their text")
        }
        // The shift's rota is homed in the sealed space: found inside it, by its text and its name, and nowhere else.
        guard try await hits("harbour", from: .space(redCross.id)).contains(where: isEventFile) else {
            throw Failure(description: "the sealed shift's file wasn't found inside its space")
        }
        for workplace: Workplace in [.everywhere, .space(uni.id), .inbox] {
            for word in ["harbour", "rota"] {
                if try await hits(word, from: workplace).contains(where: isEventFile) {
                    throw Failure(description: "the sealed shift's file was found from \(workplace) by \"\(word)\"")
                }
            }
        }

        // Meaning, when this Mac has an embedding model.
        let lecture = NoteRef(container: .space(uni.id), path: ItemPath("Physics/Lecture 7 notes.md")!)
        if model.meaningScripts?.isEmpty ?? true {
            say("SELF-CHECK note: no embedding model on this Mac; search by meaning and related notes are off")
        } else {
            try await waitForBackground("the passages to get their meaning") { $0.passagesWaiting == 0 }
            let related = try await retrieval.related(to: lecture, from: .space(uni.id), limit: 5)
            for hit in related where Self.container(of: hit.item) == .space(redCross.id) {
                throw Failure(description: "a note related to a lecture came from the sealed space")
            }
            say("SELF-CHECK note: related to Lecture 7: \(related.map(\.title))")
            let fused = try await retrieval.searchByMeaning(
                SearchQuery(text: "why a spinning skater speeds up", limit: 10), from: .everywhere)
            say("SELF-CHECK note: by meaning, a spinning skater: \(fused.prefix(3).map(\.title))")
        }
        // The note shows its Related section; search shows both passes.
        model.open(lecture)
        try await settle(seconds: 1)
        model.searchText = "inertia"
        try await settle(seconds: 1)
        model.searchText = ""
        try await settle()

        // Pausing holds back the background passes; resuming lets them go on.
        model.setIndexingPaused(true)
        try await waitForIndexer("pause") { $0.isPaused }
        model.setIndexingPaused(false)
        try await waitForIndexer("resume") { !$0.isPaused }

        // The diagnostics report, the retrieval benchmark included, runs on the demo and names no note.
        let report = await Diagnostics.run(model: model)
        for line in report.split(separator: "\n") where line.contains("benchmark") || line.contains("Files:") {
            say("SELF-CHECK note: \(line.trimmingCharacters(in: .whitespaces))")
        }
    }

    private static func container(of item: SearchHit.Item) -> Container {
        switch item {
        case .note(let note): note.container
        case .file(let container, _): container
        case .eventFile(let container, _, _): container
        }
    }

    /// Waits until the background pass has stopped and the backlog is as `done` says.
    private func waitForBackground(_ what: String, _ done: (IndexBacklog) -> Bool) async throws {
        guard let services = model.services else { return }
        let deadline = ContinuousClock.now + .seconds(180)
        while true {
            let backlog = await services.indexer.backlog()
            if done(backlog) && model.backgroundIndexing == nil {
                return
            }
            guard ContinuousClock.now < deadline else {
                throw Failure(description: "timed out waiting for \(what): \(backlog)")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private func waitForIndexer(_ what: String, _ condition: (IndexStatus) -> Bool) async throws {
        guard let services = model.services else { return }
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(await services.indexer.status()) {
            guard ContinuousClock.now < deadline else { throw Failure(description: "the index didn't \(what)") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
