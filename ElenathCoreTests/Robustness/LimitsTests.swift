import ElenathCore
import Foundation
import Testing

/// Huge notes and documents, and a vault's own attachments folder. From the independent review before
/// 0.1.1 (docs/RELEASE_CHECKLIST.md).
@Suite("Limits and vaults")
struct LimitsTests {
    /// A file of `size` bytes that starts with `text`. The rest is a hole, so it takes no room on disk.
    static func bigFile(at url: URL, size: Int64, startingWith text: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try Data(text.utf8).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
    }

    @Test("A note too large to open says so, and the index reads only its beginning")
    func hugeNote() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let uni = try await fixture.space("Uni")
        let size = NoteLimits.maximumOpenedBytes + 1
        try Self.bigFile(at: fixture.url("Uni/Huge.md"), size: size, startingWith: "# Huge\nA unicorn at the start.\n")
        try fixture.write("small\n", to: "Uni/Small.md")

        await #expect(throws: NoteStoreError.tooLarge) { try await fixture.notes.read(fixture.ref(uni, "Huge.md")) }
        _ = try await fixture.notes.read(fixture.ref(uni, "Small.md"))

        let indexer = fixture.indexer()
        let first = try await indexer.refresh(.space(uni.id))
        #expect(first.added == 2)
        let hits = try await fixture.retrieval().search(SearchQuery(text: "unicorn"), from: .space(uni.id))
        #expect(hits.map(\.title) == ["Huge"])
        // Only the beginning was read, and a second pass sees nothing changed.
        let text = try await fixture.retrieval().text(of: fixture.ref(uni, "Huge.md"), from: .space(uni.id))
        #expect((text?.utf8.count ?? 0) <= NoteLimits.maximumIndexedBytes)
        let second = try await indexer.refresh(.space(uni.id))
        #expect(second.unchanged == 2)
    }

    @Test("Reading a file's beginning reads no more, and never splits a character")
    func beginnings() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let url = folder.url.appending(component: "a.txt", directoryHint: .notDirectory)
        try Data("héllo wörld".utf8).write(to: url)
        let fileSystem = LocalFileSystem()
        #expect(try fileSystem.readData(at: url, upTo: 2) == Data("h".utf8) + Data([0xC3]))
        #expect(try fileSystem.readData(at: url, upTo: 1_000) == Data("héllo wörld".utf8))
        #expect(NoteLimits.droppingSplitCharacter(Data("h".utf8) + Data([0xC3])) == Data("h".utf8))
        #expect(NoteLimits.droppingSplitCharacter(Data("hé".utf8)) == Data("hé".utf8))
        let emoji = Data("a👩🏽".utf8)
        for cut in 1...emoji.count {
            let kept = NoteLimits.droppingSplitCharacter(emoji.prefix(cut))
            #expect(String(data: kept, encoding: .utf8) != nil, "\(cut)")
        }
        #expect(NoteLimits.droppingSplitCharacter(Data()) == Data())
        #expect(
            NoteLimits.droppingSplitCharacter(Data([0x80, 0x80, 0x80, 0x80, 0x80]))
                == Data([0x80, 0x80, 0x80, 0x80, 0x80]))
    }

    @Test("Text too large to be a note, and a document too large to convert, are imported as files")
    func hugeImports() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let downloads = try fixture.folder.makeDirectory("Downloads")
        let note = downloads.appending(component: "Huge.md", directoryHint: .notDirectory)
        let document = downloads.appending(component: "Huge.docx", directoryHint: .notDirectory)
        try Self.bigFile(at: note, size: NoteLimits.maximumImportedNoteBytes + 1, startingWith: "# Huge\n")
        try Self.bigFile(at: document, size: NoteLimits.maximumConvertedDocumentBytes + 1, startingWith: "PK")
        let plan = ImportPlanner.plan([note, document], fileSystem: fixture.fileSystem)
        #expect(plan.count == 2)
        for item in plan {
            guard case .file(let source) = item else {
                Issue.record("planned as \(item)")
                continue
            }
            #expect(["Huge.md", "Huge.docx"].contains(source.lastPathComponent))
        }
    }

    @Test("A vault's own Attachments folder is merged into Elenath's, and its embeds still work")
    func vaultAttachments() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let vault = try fixture.folder.makeDirectory("Downloads/Vault")
        let attachments = try fixture.folder.makeDirectory("Downloads/Vault/Attachments")
        _ = try fixture.folder.makeDirectory("Downloads/Vault/Attachments/Old")
        try Data("png".utf8).write(to: attachments.appending(component: "photo.png"))
        try Data("pdf".utf8).write(to: attachments.appending(path: "Old/scan.pdf"))
        try Data("![[photo.png]]\n".utf8).write(to: vault.appending(component: "Note.md"))

        let importer = Importer(
            noteStore: fixture.notes, converter: FakeConverter(), fileSystem: fixture.fileSystem,
            timeSource: fixture.clock, timeZone: { LibraryFixture.timeZone })
        let report = try await importer.run(
            ImportPlanner.plan([vault], fileSystem: fixture.fileSystem), into: .root, container: .inbox)
        #expect(report.failed.isEmpty)
        #expect(fixture.names(in: "Inbox/Vault/Attachments") == ["photo.png", "scan.pdf"])
        let embedded = await fixture.notes.attachmentURL(named: "photo.png", for: fixture.inbox("Vault/Note.md"))
        #expect(embedded?.lastPathComponent == "photo.png")
    }
}
