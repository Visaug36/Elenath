import ElenathCore
import Foundation
import Testing

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Files that aren't what they seem, from imports and from Finder: links that lead out of the library,
/// named pipes that would make a read wait forever, and names in a chat that point somewhere else. From
/// the independent review before 0.1.1 (docs/RELEASE_CHECKLIST.md).
@Suite("File safety")
struct FileSafetyTests {
    /// Makes a named pipe. Opening one to read waits until something writes to it, which never happens.
    static func makePipe(at url: URL) throws {
        guard mkfifo(url.path, 0o644) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    static func file(_ name: String, in folder: URL) -> URL {
        folder.appending(component: name, directoryHint: .notDirectory)
    }

    // MARK: - Named pipes

    @Test("A named pipe is recognized and never opened")
    func pipeIsNeverRead() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let pipe = Self.file("Pipe.md", in: folder.url)
        try Self.makePipe(at: pipe)
        let fileSystem = LocalFileSystem()
        let info = try #require(fileSystem.info(at: pipe))
        #expect(info.isSpecial && !info.isDirectory && !info.isSymbolicLink)
        #expect(throws: (any Error).self) { try fileSystem.readData(at: pipe) }

        let file = Self.file("Note.md", in: folder.url)
        try Data("text".utf8).write(to: file)
        #expect(fileSystem.info(at: file)?.isSpecial == false)
        #expect(try fileSystem.readData(at: file) == Data("text".utf8))
    }

    @Test("A named pipe in a space is left out of listings and the index, and reading it fails at once")
    func pipeInSpace() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let uni = try await fixture.space("Uni")
        try fixture.write("Real text\n", to: "Uni/Real.md")
        try Self.makePipe(at: fixture.url("Uni/Pipe.md"))
        try Self.makePipe(at: fixture.url("Uni/Pipe.png"))

        let listing = try await fixture.catalog.listing(of: .root, in: .space(uni.id))
        #expect(listing.notes.map(\.title) == ["Real"])
        #expect(listing.files.isEmpty)
        let indexer = fixture.indexer()
        await indexer.refreshAll()
        let found = try await fixture.retrieval().search(SearchQuery(text: "real", limit: 10), from: .everywhere)
        #expect(found.map(\.title) == ["Real"])
        await #expect(throws: (any Error).self) { try await fixture.notes.read(fixture.ref(uni, "Pipe.md")) }
        #expect(await fixture.notes.attachmentURL(named: "Pipe.png", for: fixture.ref(uni, "Real.md")) == nil)
    }

    @Test("A dropped named pipe is skipped, on its own and inside a folder")
    func pipeInImport() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let downloads = try fixture.folder.makeDirectory("Downloads")
        let notes = try fixture.folder.makeDirectory("Downloads/Notes")
        try Data("kept".utf8).write(to: Self.file("Kept.md", in: notes))
        try Self.makePipe(at: Self.file("Inner pipe.md", in: notes))
        try Self.makePipe(at: Self.file("Pipe.txt", in: downloads))

        let plan = ImportPlanner.plan([notes, Self.file("Pipe.txt", in: downloads)], fileSystem: fixture.fileSystem)
        guard case .skipped(_, let reason) = plan.last else {
            Issue.record("the pipe was planned as \(String(describing: plan.last))")
            return
        }
        #expect(reason == .special)
        let importer = Importer(
            noteStore: fixture.notes, converter: FakeConverter(), fileSystem: fixture.fileSystem,
            timeSource: fixture.clock, timeZone: { LibraryFixture.timeZone })
        let report = try await importer.run(plan, into: .root, container: .inbox)
        #expect(report.notes.map(\.title) == ["Kept"])
        #expect(fixture.names(in: "Inbox/Notes") == ["Kept.md"])
    }

    // MARK: - Links

    @Test("Copying a folder leaves out the links and pipes inside it, and a link itself is refused")
    func copiedFolderHasNoLinks() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let root = try folder.makeDirectory("Library")
        let destination = try folder.makeDirectory("Library/Space")
        let secret = Self.file("secret.txt", in: folder.url)
        try Data("SECRET".utf8).write(to: secret)
        let source = try folder.makeDirectory("Dropped")
        let inner = try folder.makeDirectory("Dropped/Inner")
        try Data("a".utf8).write(to: Self.file("a.txt", in: source))
        try Data("b".utf8).write(to: Self.file("b.txt", in: inner))
        try FileManager.default.createSymbolicLink(
            at: Self.file("secret link.txt", in: source), withDestinationURL: secret)
        try FileManager.default.createSymbolicLink(at: Self.file("outside", in: inner), withDestinationURL: folder.url)
        try Self.makePipe(at: Self.file("pipe", in: source))

        let fileSystem = LocalFileSystem()
        let copies = try await FileCopier.copy([source], into: destination, root: root, fileSystem: fileSystem)
        let copy = try #require(copies.first)
        #expect(TestFiles.names(in: copy).sorted() == ["Inner", "a.txt"])
        #expect(TestFiles.names(in: copy.appending(component: "Inner", directoryHint: .isDirectory)) == ["b.txt"])

        let link = Self.file("secret link.txt", in: source)
        await #expect(throws: FileCopyError.unusableSource("secret link.txt")) {
            try await FileCopier.copy([link], into: destination, root: root, fileSystem: fileSystem)
        }
        await #expect(throws: FileCopyError.unusableSource("pipe")) {
            try await FileCopier.copy(
                [Self.file("pipe", in: source)], into: destination, root: root, fileSystem: fileSystem)
        }
        // Nothing half-copied is left behind.
        #expect(TestFiles.names(in: destination) == ["Dropped"])
    }

    @Test("A folder deeper than Elenath copies is refused, not copied in part")
    func deepFolder() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let root = try folder.makeDirectory("Library")
        let destination = try folder.makeDirectory("Library/Space")
        let path = (0...FileCopier.maximumFolderDepth).map { "d\($0)" }.joined(separator: "/")
        _ = try folder.makeDirectory("Deep/" + path)
        await #expect(throws: (any Error).self) {
            try await FileCopier.copy(
                [folder.child("Deep")], into: destination, root: root, fileSystem: LocalFileSystem())
        }
        #expect(TestFiles.names(in: destination).isEmpty)
    }

    @Test("A settings folder or backups folder that is a link is refused, and nothing it leads to changes")
    func linkedSettingsFolder() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let clock = TestClock(Date(timeIntervalSince1970: 1_794_321_000))
        func store(_ owner: URL) -> DocumentStore<LibraryDocument> {
            DocumentStore(
                owner: owner, metadataFolderName: ".elenath", safetyDirectory: folder.child("Safety"),
                knownDocumentID: nil, fileSystem: LocalFileSystem(), timeSource: clock, backupInterval: 3600,
                maxBackups: 10)
        }
        // Someone else's settings, which must never be read or written through a link.
        let other = try folder.makeDirectory("Other")
        let document = LibraryDocument(id: LibraryID(), spaces: [], settings: [:])
        try await store(other).create(document)
        let otherSettings = other.appending(path: ".elenath/library.json", directoryHint: .notDirectory)
        let before = try Data(contentsOf: otherSettings)

        let library = try folder.makeDirectory("Library")
        try FileManager.default.createSymbolicLink(
            at: library.appending(component: ".elenath", directoryHint: .isDirectory),
            withDestinationURL: other.appending(component: ".elenath", directoryHint: .isDirectory))
        let linked = store(library)
        await #expect(throws: (any Error).self) { try await linked.load() }
        await #expect(throws: (any Error).self) { try await linked.save(document, backingUpNewVersion: true) }
        await #expect(throws: (any Error).self) { try await linked.create(document) }
        #expect(try Data(contentsOf: otherSettings) == before)
        #expect(!FileManager.default.fileExists(atPath: other.appending(path: ".elenath/backups").path))

        // A real settings folder whose backups folder is a link.
        let second = try folder.makeDirectory("Second")
        try await store(second).create(document)
        let elsewhere = try folder.makeDirectory("Elsewhere")
        try FileManager.default.createSymbolicLink(
            at: second.appending(path: ".elenath/backups", directoryHint: .isDirectory), withDestinationURL: elsewhere)
        await #expect(throws: (any Error).self) { try await store(second).save(document, backingUpNewVersion: true) }
        #expect(TestFiles.names(in: elsewhere).isEmpty)
    }

    // MARK: - Chat exports

    @Test("A chat's attachment names can't reach files outside the export")
    func chatAttachmentsStayInside() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let downloads = try fixture.folder.makeDirectory("Downloads")
        try Data("SECRET".utf8).write(to: Self.file("secret.jpg", in: downloads))
        let export = try fixture.folder.makeDirectory("Downloads/WhatsApp Chat - Me")
        try Data("real".utf8).write(to: Self.file("real.jpg", in: export))
        try Data("hidden".utf8).write(to: Self.file(".hidden.jpg", in: export))
        try FileManager.default.createSymbolicLink(
            at: Self.file("link.jpg", in: export), withDestinationURL: Self.file("secret.jpg", in: downloads))
        try Self.makePipe(at: Self.file("pipe.jpg", in: export))
        _ = try fixture.folder.makeDirectory("Downloads/WhatsApp Chat - Me/folder.jpg")
        let names = [
            "../secret.jpg", downloads.path + "/secret.jpg", "link.jpg", ".hidden.jpg", "pipe.jpg", "folder.jpg",
        ]
        let lines = (names + ["real.jpg"]).enumerated().map { index, name in
            "[10/11/2026, 14:30:0\(index)] Me: \u{200E}<attached: \(name)>"
        }
        try Data(lines.joined(separator: "\n").utf8).write(to: Self.file("_chat.txt", in: export))

        let importer = Importer(
            noteStore: fixture.notes, converter: FakeConverter(), fileSystem: fixture.fileSystem,
            timeSource: fixture.clock, timeZone: { LibraryFixture.timeZone })
        let report = try await importer.run(
            ImportPlanner.plan([export], fileSystem: fixture.fileSystem), into: .root, container: .inbox)
        #expect(report.failed.isEmpty)
        #expect(fixture.names(in: "Inbox/Attachments") == ["real.jpg"])
        let text = try #require(report.notes.first.map { try fixture.read("Inbox/\($0.path)") })
        for name in names {
            #expect(text.contains("(\(name) was not in the export)"), "\(name)")
        }
        #expect(text.contains("![[real.jpg]]"))
        // Nothing in the library holds the secret.
        let everything = FileManager.default.enumerator(at: fixture.root, includingPropertiesForKeys: nil)
        while let url = everything?.nextObject() as? URL {
            if let data = try? Data(contentsOf: url) {
                #expect(!String(decoding: data, as: UTF8.self).contains("SECRET"), "\(url.lastPathComponent)")
            }
        }
    }
}
