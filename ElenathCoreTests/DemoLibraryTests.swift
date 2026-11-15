import ElenathCore
import Foundation
import Testing

@Suite("Demo library")
struct DemoLibraryTests {
    static let now = Date(timeIntervalSince1970: 1_794_321_000)
    static let utc = TimeZone(secondsFromGMT: 0)!

    private func write(into folder: TempFolder, _ name: String) async throws -> (root: URL, snapshot: LibrarySnapshot) {
        let root = try folder.makeDirectory(name)
        let snapshot = try await DemoLibrary.write(
            to: root, safetyDirectory: folder.child("\(name)-safety"), now: Self.now, timeZone: Self.utc,
            fileSystem: LocalFileSystem())
        return (root, snapshot)
    }

    /// Every file under a folder, by its path from there, hidden ones included.
    private func files(under root: URL) -> [String: Data] {
        var result: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(atPath: root.path)
        while let path = enumerator?.nextObject() as? String {
            let url = root.appending(path: path)
            if !LocalFileSystem().isDirectory(at: url), let data = try? Data(contentsOf: url) {
                result[path] = data
            }
        }
        return result
    }

    @Test("Three spaces, one of them sealed, and an Inbox with captures")
    func shape() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let (root, snapshot) = try await write(into: folder, "Demo")
        #expect(snapshot.spaces.map(\.name) == ["Uni", "Red Cross", "Ideas"])
        #expect(snapshot.spaces.map(\.isSealed) == [false, true, false])
        #expect(snapshot.spaces.first?.keywords == ["uni", "lecture", "exam"])
        #expect(TestFiles.names(in: root.appending(path: "Inbox")).count == 4)
        #expect(TestFiles.exists(root.appending(path: "Uni/Physics/Lecture 7 notes.md")))
        #expect(TestFiles.exists(root.appending(path: "Red Cross/First aid course/Session 3 - Bleeding and shock.md")))
    }

    @Test("Equal arguments give equal libraries, byte for byte")
    func deterministic() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let first = try await write(into: folder, "One")
        let second = try await write(into: folder, "Two")
        #expect(files(under: first.root) == files(under: second.root))
        #expect(first.snapshot.id == second.snapshot.id)
        #expect(first.snapshot.spaces.map(\.id) == second.snapshot.spaces.map(\.id))
    }

    @Test("Every link in it leads somewhere, and nothing links across the seal")
    func links() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let (root, snapshot) = try await write(into: folder, "Demo")
        let catalog = LibraryCatalog(
            root: root, safetyDirectory: folder.child("Demo-safety"), fileSystem: LocalFileSystem(),
            timeSource: FixedTimeSource(Self.now))
        _ = try await catalog.open()
        let index = folder.child("Index")
        let indexer = Indexer(
            catalog: catalog, indexDirectory: index, fileSystem: LocalFileSystem(), timeZone: { Self.utc })
        await indexer.refreshAll()
        let retrieval = Retrieval(indexDirectory: index, spaces: { await catalog.spaces() })

        var checked = 0
        for space in snapshot.spaces {
            for hit in try await retrieval.recentNotes(from: .space(space.id), limit: 100)
            where hit.note.container == .space(space.id) {
                let body = try #require(try await retrieval.text(of: hit.note, from: .space(space.id)))
                for span in MarkdownScanner.scan(body).links {
                    guard case .wiki(let link) = span.target else { continue }
                    let resolution = try await retrieval.resolve(link, from: hit.note)
                    guard case .resolved(let target) = resolution else {
                        Issue.record("\(link.written) in \(hit.title) doesn't resolve")
                        continue
                    }
                    checked += 1
                    if space.isSealed {
                        #expect(target.container == .space(space.id))
                    }
                }
            }
        }
        #expect(checked >= 10)
        // The goal has its notes pointing at it.
        let uni = try #require(snapshot.spaces.first)
        let goal = NoteRef(container: .space(uni.id), path: ItemPath("Pass Physics 1.md")!)
        #expect(try await retrieval.backlinks(to: goal).map(\.source.title) == ["Lecture 7 notes"])
        #expect(try await retrieval.openTasks(from: .everywhere, limit: 100).count == 10)
        #expect(try await retrieval.inboxCount() == 4)
        // What was changed last comes first.
        #expect(
            try await retrieval.recentNotes(from: .everywhere, limit: 2).map(\.title) == [
                "Lecture 8 notes", "Lecture 7 notes",
            ])
    }
}
