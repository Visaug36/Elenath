import ElenathCore
import Foundation
import Testing

/// Stands in for the app's AppKit converter: the "text" of a document is its bytes.
struct FakeConverter: DocumentConverting {
    func markdown(from url: URL) throws -> String {
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        if text.contains("BROKEN") {
            throw CocoaError(.fileReadCorruptFile)
        }
        return "Converted: " + text
    }
}

@Suite("Import")
struct ImportTests {
    private struct Drop {
        let fixture: LibraryFixture
        let uni: Space
        let downloads: URL
        let importer: Importer

        init() async throws {
            fixture = try await LibraryFixture()
            uni = try await fixture.space("Uni")
            downloads = try fixture.folder.makeDirectory("Downloads")
            importer = Importer(
                noteStore: fixture.notes, converter: FakeConverter(), fileSystem: fixture.fileSystem,
                timeSource: fixture.clock, timeZone: { LibraryFixture.timeZone })
        }

        @discardableResult
        func file(_ path: String, _ text: String) throws -> URL {
            let url = downloads.appending(path: path, directoryHint: .notDirectory)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            try Data(text.utf8).write(to: url)
            return url
        }

        func plan(_ names: [String]) -> [ImportItem] {
            ImportPlanner.plan(names.map { downloads.appending(path: $0) }, fileSystem: fixture.fileSystem)
        }
    }

    @Test("The plan: notes, documents, files, folders, and what is left out")
    func plan() async throws {
        let drop = try await Drop()
        defer { drop.fixture.remove() }
        let note = try drop.file("Old notes.md", "# Old")
        let text = try drop.file("todo.TXT", "buy milk")
        let word = try drop.file("Essay.docx", "word")
        let pdf = try drop.file("Slides.pdf", "%PDF")
        try drop.file("Vault/.obsidian/app.json", "{}")
        try drop.file("Vault/Daily/2026-11-10.md", "day")
        try drop.file("Vault/image 10.png", "png")
        try drop.file("Vault/image 9.png", "png")
        try drop.file(".DS_Store", "x")
        try FileManager.default.createSymbolicLink(
            at: drop.downloads.appending(component: "link.md"), withDestinationURL: note)

        let plan = drop.plan([
            "Old notes.md", "todo.TXT", "Essay.docx", "Slides.pdf", "Vault", ".DS_Store", "link.md", "gone.md",
        ])
        #expect(
            plan.map(describe) == [
                "note Old notes.md as Old notes", "note todo.TXT as todo", "document Essay.docx as Essay",
                "file Slides.pdf",
                "folder Vault [skipped .obsidian (hidden), folder Daily [note 2026-11-10.md as 2026-11-10], "
                    + "file image 9.png, file image 10.png]",
                "skipped .DS_Store (hidden)", "skipped link.md (symbolicLink)", "skipped gone.md (unreadable)",
            ])
        _ = (text, word, pdf)
        #expect(ImportPlanner.count(plan) == 7)
    }

    /// A plan item in a line, by file name: URLs differ in a trailing slash from one platform to the next.
    private func describe(_ item: ImportItem) -> String {
        switch item {
        case .note(let source, let title): "note \(source.lastPathComponent) as \(title)"
        case .document(let source, let title): "document \(source.lastPathComponent) as \(title)"
        case .chatExport(let source): "chat \(source.lastPathComponent)"
        case .file(let source): "file \(source.lastPathComponent)"
        case .folder(let name, let items): "folder \(name) [\(items.map(describe).joined(separator: ", "))]"
        case .skipped(let source, let reason): "skipped \(source.lastPathComponent) (\(reason))"
        }
    }

    @Test("Everything is copied, folders keep their shape, and the originals stay")
    func run() async throws {
        let drop = try await Drop()
        defer { drop.fixture.remove() }
        let original = "---\ntitle: kept\n---\n# Old\r\nwith its own line endings\r\n"
        try drop.file("Old notes.md", original)
        try drop.file("todo.txt", "buy milk")
        try drop.file("Slides.pdf", "%PDF")
        try drop.file("Vault/.obsidian/app.json", "{}")
        try drop.file("Vault/Daily/2026-11-10.md", "day")
        try drop.file("Vault/photo.png", "png")
        try drop.fixture.write("already here", to: "Uni/Imported/todo.md")

        let progress = ProgressLog()
        let report = try await drop.importer.run(
            drop.plan(["Old notes.md", "todo.txt", "Slides.pdf", "Vault"]), into: ItemPath("Imported")!,
            container: .space(drop.uni.id), progress: { progress.add($0) })

        let fixture = drop.fixture
        #expect(try fixture.read("Uni/Imported/Old notes.md") == original)
        #expect(try fixture.read("Uni/Imported/todo 2.md") == "buy milk")
        #expect(try fixture.read("Uni/Imported/todo.md") == "already here")
        #expect(try fixture.read("Uni/Imported/Slides.pdf") == "%PDF")
        #expect(try fixture.read("Uni/Imported/Vault/Daily/2026-11-10.md") == "day")
        #expect(fixture.exists("Uni/Imported/Vault/photo.png"))
        #expect(!fixture.exists("Uni/Imported/Vault/.obsidian"))
        #expect(
            report.notes == [
                fixture.ref(drop.uni, "Imported/Old notes.md"), fixture.ref(drop.uni, "Imported/todo 2.md"),
                fixture.ref(drop.uni, "Imported/Vault/Daily/2026-11-10.md"),
            ])
        #expect(
            report.files.map(\.description) == [
                "Imported/Slides.pdf", "Imported/Vault", "Imported/Vault/Daily", "Imported/Vault/photo.png",
            ])
        #expect(report.skipped.map(\.lastPathComponent) == [".obsidian"])
        #expect(report.failed.isEmpty)
        // Nothing left where it came from.
        #expect(TestFiles.names(in: drop.downloads) == ["Old notes.md", "todo.txt", "Slides.pdf", "Vault"])
        #expect(TestFiles.names(in: drop.downloads.appending(path: "Vault")) == [".obsidian", "Daily", "photo.png"])
        #expect(progress.all.last == ImportProgress(completed: 5, total: 5, currentName: nil))
        #expect(progress.all.first?.currentName == "Old notes.md")
    }

    @Test("A document's text becomes a note and the original stays beside it")
    func documents() async throws {
        let drop = try await Drop()
        defer { drop.fixture.remove() }
        try drop.file("Essay draft.docx", "the essay")
        try drop.file("Broken.rtf", "BROKEN")
        try drop.file("Later.md", "still imported")

        let report = try await drop.importer.run(
            drop.plan(["Essay draft.docx", "Broken.rtf", "Later.md"]), into: .root, container: .inbox)
        let note = try drop.fixture.read("Inbox/Essay draft.md")
        #expect(note.hasPrefix("---\nid: 00000000-0000-4000-8000-000000000001\ncreated: "))
        #expect(
            note.hasSuffix(
                "---\nOriginal: [Essay draft.docx](Attachments/Essay%20draft.docx)\n\nConverted: the essay\n"))
        #expect(try drop.fixture.read("Inbox/Attachments/Essay draft.docx") == "the essay")
        // One document that can't be read doesn't stop the rest.
        #expect(report.failed.map(\.source.lastPathComponent) == ["Broken.rtf"])
        #expect(report.notes.map(\.title) == ["Essay draft", "Later"])
    }

    @Test("Text in an old encoding is read, and written as UTF-8")
    func encodings() async throws {
        let drop = try await Drop()
        defer { drop.fixture.remove() }
        try Data([0x43, 0x61, 0x66, 0xE9]).write(to: drop.downloads.appending(component: "latin.txt"))  // "Café"
        var utf16 = Data([0xFF, 0xFE])
        utf16.append("Grüße".data(using: .utf16LittleEndian)!)
        try utf16.write(to: drop.downloads.appending(component: "wide.txt"))

        _ = try await drop.importer.run(drop.plan(["latin.txt", "wide.txt"]), into: .root, container: .inbox)
        #expect(try drop.fixture.read("Inbox/latin.md") == "Café")
        #expect(try drop.fixture.read("Inbox/wide.md") == "Grüße")
    }

    @Test("An exported chat becomes one note per thought, dated when it was sent, with its photos")
    func chat() async throws {
        let drop = try await Drop()
        defer { drop.fixture.remove() }
        try drop.file("WhatsApp Chat - Me/_chat.txt", ChatExportTests.iPhone)
        try drop.file("WhatsApp Chat - Me/00000012-PHOTO-2026-11-10-14-33-00.jpg", "jpeg")

        let plan = drop.plan(["WhatsApp Chat - Me"])
        #expect(plan.map(describe) == ["chat _chat.txt"])
        let report = try await drop.importer.run(plan, into: .root, container: .inbox)

        #expect(
            report.notes.map(\.title) == [
                "Idea- a note app that files things for me", "Buy bandages for the course",
                "https---example.com-article",
            ])
        let first = try drop.fixture.read("Inbox/Idea- a note app that files things for me.md")
        #expect(
            first == """
                ---
                id: 00000000-0000-4000-8000-000000000001
                created: 2026-11-10T14:30:05Z
                ---
                Idea: a note app that files things for me

                It should work offline
                and keep plain files

                ![[00000012-PHOTO-2026-11-10-14-33-00.jpg]]

                """)
        #expect(try drop.fixture.read("Inbox/Attachments/00000012-PHOTO-2026-11-10-14-33-00.jpg") == "jpeg")
        // One line that is its own title has no body.
        #expect(
            try drop.fixture.read("Inbox/Buy bandages for the course.md").hasSuffix(
                "created: 2026-11-13T09:05:10Z\n---\n"))
        #expect(
            try drop.fixture.read("Inbox/https---example.com-article.md").hasSuffix(
                "---\nhttps://example.com/article\n"))

        // A chat's text file dropped alone, with nothing beside it.
        try drop.file(
            "Alone/chat.txt",
            "[10/11/2026, 14:30:05] Sam: \u{200E}<attached: lost.jpg>\n[10/11/2026, 14:30:09] Sam: caption")
        let alone = try await drop.importer.run(
            drop.plan(["Alone/chat.txt"]), into: ItemPath("Chats")!, container: .space(drop.uni.id))
        #expect(alone.notes.map(\.title) == ["caption"])
        #expect(
            try drop.fixture.read("Uni/Chats/caption.md").hasSuffix(
                "---\n(lost.jpg was not in the export)\n\ncaption\n"))
    }

    @Test("How a note refers to an attachment")
    func attachmentLinks() {
        #expect(Importer.link(to: "photo.PNG") == "![[photo.PNG]]")
        #expect(Importer.link(to: "scan.pdf") == "![[scan.pdf]]")
        #expect(
            Importer.link(to: "My essay (v2).docx") == "[My essay (v2).docx](Attachments/My%20essay%20%28v2%29.docx)")
        #expect(Importer.link(to: "odd]name.png") == "[odd)name.png](Attachments/odd%5Dname.png)")
    }
}

/// Collects progress reports from another thread.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [ImportProgress] = []

    func add(_ report: ImportProgress) {
        lock.lock()
        defer { lock.unlock() }
        reports.append(report)
    }

    var all: [ImportProgress] {
        lock.lock()
        defer { lock.unlock() }
        return reports
    }
}
