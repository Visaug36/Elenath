import ElenathCore
import Foundation
import Testing

@Suite("Moving a library")
struct LibraryMoveTests {
    @Test("Spaces, the Inbox and .elenath move; loose files stay")
    func move() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        _ = try await fixture.space("Uni")
        try fixture.write("note", to: "Uni/Physics/Lecture.md")
        try fixture.write("capture", to: "Inbox/Thought.md")
        try fixture.write("loose", to: "readme.txt")
        let destination = fixture.folder.child("Elsewhere/Elenath")

        try LibraryMove.move(from: fixture.root, to: destination, fileSystem: LocalFileSystem())
        #expect(TestFiles.names(in: destination) == [".elenath", "Inbox", "Uni"])
        #expect(TestFiles.names(in: fixture.root) == ["readme.txt"])
        let moved = destination.appending(path: "Uni/Physics/Lecture.md")
        #expect(String(decoding: try Data(contentsOf: moved), as: UTF8.self) == "note")

        // The library opens in its new place.
        let catalog = LibraryCatalog(
            root: destination, safetyDirectory: fixture.safety, fileSystem: LocalFileSystem(), timeSource: fixture.clock
        )
        #expect(try await catalog.open().spaces.map(\.name) == ["Uni"])
    }

    @Test("A destination with something in it, or inside the library, is refused and nothing moves")
    func refused() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        _ = try await fixture.space("Uni")
        let occupied = try fixture.folder.makeDirectory("Occupied")
        try Data("x".utf8).write(to: occupied.appending(component: "file.txt"))
        #expect(throws: CocoaError.self) {
            try LibraryMove.move(from: fixture.root, to: occupied, fileSystem: LocalFileSystem())
        }
        #expect(throws: CocoaError.self) {
            try LibraryMove.move(
                from: fixture.root, to: fixture.root.appending(path: "Uni/Inside"), fileSystem: LocalFileSystem())
        }
        #expect(TestFiles.names(in: fixture.root) == [".elenath", "Inbox", "Uni"])
        #expect(TestFiles.names(in: occupied) == ["file.txt"])
    }

    @Test("When one item can't move, everything moved so far goes back")
    func rollback() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        _ = try await fixture.space("Alpha")
        _ = try await fixture.space("Beta")
        let destination = try fixture.folder.makeDirectory("New")
        let failing = FailingMoveFileSystem(failingName: "Beta")
        #expect(throws: CocoaError.self) {
            try LibraryMove.move(from: fixture.root, to: destination, fileSystem: failing)
        }
        #expect(TestFiles.names(in: fixture.root) == [".elenath", "Alpha", "Beta", "Inbox"])
        #expect(TestFiles.names(in: destination).isEmpty)
    }
}

/// A real file system that refuses to move one item, as a locked folder would.
private struct FailingMoveFileSystem: FileSystem {
    let failingName: String
    let base = LocalFileSystem()

    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    func isDirectory(at url: URL) -> Bool { base.isDirectory(at: url) }
    func contentsOfDirectory(at url: URL) throws -> [URL] { try base.contentsOfDirectory(at: url) }
    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
    func readData(at url: URL) throws -> Data { try base.readData(at: url) }
    func writeAtomically(_ data: Data, to url: URL) throws { try base.writeAtomically(data, to: url) }
    func copyItem(at source: URL, to destination: URL) throws { try base.copyItem(at: source, to: destination) }

    func moveItem(at source: URL, to destination: URL) throws {
        if source.lastPathComponent == failingName {
            throw CocoaError(.fileWriteNoPermission)
        }
        try base.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws { try base.removeItem(at: url) }
    func trashItem(at url: URL) throws { try base.trashItem(at: url) }
    func modificationDate(at url: URL) -> Date? { base.modificationDate(at: url) }
    func info(at url: URL) -> FileInfo? { base.info(at: url) }
}
