import ElenathCore
import Foundation
import Testing

@Suite("Note store")
struct NoteStoreTests {
    // MARK: - Creating and reading

    @Test("A new note has front matter, a safe name, and a number when the name is taken")
    func create() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let uni = try await fixture.space("Uni")

        let note = try await fixture.notes.create(
            title: "Lecture 7: waves/optics", in: ItemPath("Physics")!, container: .space(uni.id), body: "First line")
        #expect(note.ref == fixture.ref(uni, "Physics/Lecture 7- waves-optics.md"))
        #expect(
            try fixture.read("Uni/Physics/Lecture 7- waves-optics.md")
                == "---\nid: 00000000-0000-4000-8000-000000000001\ncreated: 2026-11-10T14:30:00Z\n---\nFirst line\n")
        #expect(note.text?.id == IDSequence.id(1))
        #expect(!note.isReadOnly)

        let second = try await fixture.notes.create(
            title: "lecture 7: WAVES/optics", in: ItemPath("Physics")!, container: .space(uni.id), kind: .idea)
        #expect(second.ref.path.name == "lecture 7- WAVES-optics 2.md")
        #expect(second.text?.kind == .idea)

        let inbox = try await fixture.notes.create(title: "", in: .root, container: .inbox)
        #expect(inbox.ref == fixture.inbox("Untitled.md"))
    }

    @Test("Notes can't be put into folders Elenath keeps for itself")
    func reservedFolders() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let uni = try await fixture.space("Uni")
        for folder in ["Attachments", ".space", "Physics/.hidden", "Sketch.board"] {
            await #expect(throws: NoteStoreError.self) {
                try await fixture.notes.create(title: "x", in: ItemPath(folder)!, container: .space(uni.id))
            }
        }
        await #expect(throws: NoteStoreError.reservedName("Attachments")) {
            try await fixture.notes.createFolder(named: "Attachments", in: .root, container: .space(uni.id))
        }
        #expect(fixture.names(in: "Uni").isEmpty)
    }

    @Test("Reading gives the note's parts and a stamp of its bytes")
    func read() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let uni = try await fixture.space("Uni")
        try fixture.write("---\nkind: goal\n---\nPass it\n", to: "Uni/Pass Physics 1.md")

        let note = try await fixture.notes.read(fixture.ref(uni, "Pass Physics 1.md"))
        #expect(note.text?.kind == .goal)
        #expect(note.text?.body == "Pass it\n")
        #expect(note.stamp.byteCount == 27)
        #expect(note.stamp.contentHash == ContentHash.of(Data("---\nkind: goal\n---\nPass it\n".utf8)))

        await #expect(throws: NoteStoreError.notFound) {
            try await fixture.notes.read(fixture.ref(uni, "Missing.md"))
        }
        await #expect(throws: NoteStoreError.notANote) {
            try await fixture.notes.read(fixture.ref(uni, "picture.png"))
        }
    }

    @Test("A file that isn't UTF-8 is shown read-only and never rewritten")
    func notUTF8() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let uni = try await fixture.space("Uni")
        let bytes = Data([0x48, 0x69, 0x20, 0xE9, 0x0A])  // "Hi é" in Latin-1
        try bytes.write(to: fixture.url("Uni/Old.md"))

        let note = try await fixture.notes.read(fixture.ref(uni, "Old.md"))
        #expect(note.text == nil)
        #expect(note.isReadOnly)
        #expect(note.fallbackText?.hasPrefix("Hi ") == true)
        #expect(try Data(contentsOf: fixture.url("Uni/Old.md")) == bytes)
    }

    // MARK: - Saving

    @Test("Saving replaces the file and the first edit of a note from elsewhere adds an id")
    func save() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let uni = try await fixture.space("Uni")
        try fixture.write("# Title\r\nFrom another app\r\n", to: "Uni/Imported.md")
        let ref = fixture.ref(uni, "Imported.md")

        let loaded = try await fixture.notes.read(ref)
        var text = try #require(loaded.text)
        text.body += "A new line\r\n"
        guard case .saved(let saved) = try await fixture.notes.save(text, to: ref, expecting: loaded.stamp) else {
            Issue.record("expected a plain save")
            return
        }
        let onDisk = try fixture.read("Uni/Imported.md")
        #expect(onDisk.hasPrefix("---\r\nid: 00000000-0000-4000-8000-000000000001\r\ncreated: "))
        #expect(onDisk.hasSuffix("---\r\n# Title\r\nFrom another app\r\nA new line\r\n"))
        #expect(saved.text?.id == IDSequence.id(1))
        #expect(saved.stamp.contentHash == ContentHash.of(Data(onDisk.utf8)))

        // The next save keeps that id.
        var again = try #require(saved.text)
        again.body += "More\r\n"
        guard case .saved(let second) = try await fixture.notes.save(again, to: ref, expecting: saved.stamp) else {
            Issue.record("expected a plain save")
            return
        }
        #expect(second.text?.id == IDSequence.id(1))
    }

    @Test("A note that changed on disk meanwhile is never overwritten: both versions are kept")
    func conflict() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let uni = try await fixture.space("Uni")
        let created = try await fixture.notes.create(title: "Plan", in: .root, container: .space(uni.id), body: "v1")

        // Another editor saves while Elenath holds unsaved edits.
        let fromElsewhere = "---\nid: 00000000-0000-4000-8000-000000000001\n---\nchanged elsewhere\n"
        try fixture.write(fromElsewhere, to: "Uni/Plan.md")
        var mine = try #require(created.text)
        mine.body = "my edits\n"
        let outcome = try await fixture.notes.save(mine, to: created.ref, expecting: created.stamp)

        guard case .conflict(let copy, let onDisk) = outcome else {
            Issue.record("expected a conflict")
            return
        }
        #expect(try fixture.read("Uni/Plan.md") == fromElsewhere)
        #expect(copy.ref == fixture.ref(uni, "Plan (conflict 2026-11-10 14.30).md"))
        #expect(copy.text?.body == "my edits\n")
        #expect(copy.text?.id == IDSequence.id(2))
        #expect(onDisk.contentHash == ContentHash.of(Data(fromElsewhere.utf8)))
        #expect(fixture.names(in: "Uni") == ["Plan (conflict 2026-11-10 14.30).md", "Plan.md"])

        // A second conflict in the same minute gets a number.
        let again = try await fixture.notes.save(mine, to: created.ref, expecting: created.stamp)
        guard case .conflict(let secondCopy, _) = again else {
            Issue.record("expected a conflict")
            return
        }
        #expect(secondCopy.ref == fixture.ref(uni, "Plan (conflict 2026-11-10 14.30) 2.md"))
    }

    @Test("The same bytes on disk are not a conflict, and a touched file isn't either")
    func noFalseConflicts() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let uni = try await fixture.space("Uni")
        let created = try await fixture.notes.create(title: "Plan", in: .root, container: .space(uni.id), body: "v1")
        var mine = try #require(created.text)
        mine.body = "v2\n"

        // Something else wrote exactly what is being saved.
        try mine.data().write(to: fixture.url("Uni/Plan.md"))
        guard case .saved = try await fixture.notes.save(mine, to: created.ref, expecting: created.stamp) else {
            Issue.record("the same bytes are not a conflict")
            return
        }

        // The file's date changed but its bytes didn't.
        let current = try await fixture.notes.read(created.ref)
        var stale = current.stamp
        stale.modified = Date(timeIntervalSince1970: 0)
        mine.body = "v3\n"
        guard case .saved = try await fixture.notes.save(mine, to: created.ref, expecting: stale) else {
            Issue.record("a changed date alone is not a conflict")
            return
        }
        #expect(fixture.names(in: "Uni") == ["Plan.md"])
    }

    @Test("A note whose file is gone is written again")
    func recreated() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let uni = try await fixture.space("Uni")
        let created = try await fixture.notes.create(
            title: "Plan", in: ItemPath("Deep/Folder")!, container: .space(uni.id), body: "v1")
        try FileManager.default.removeItem(at: fixture.url("Uni/Deep"))

        var mine = try #require(created.text)
        mine.body = "still here\n"
        guard case .recreated(let note) = try await fixture.notes.save(mine, to: created.ref, expecting: created.stamp)
        else {
            Issue.record("expected the note to be written again")
            return
        }
        #expect(note.text?.body == "still here\n")
        #expect(try fixture.read("Uni/Deep/Folder/Plan.md").hasSuffix("still here\n"))
    }

    @Test("A save that is cut off halfway leaves the old note whole")
    func interruptedSave() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let uni = try await fixture.space("Uni")
        let body = String(repeating: "Every keystroke counts.\n", count: 2_000)
        let created = try await fixture.notes.create(title: "Thesis", in: .root, container: .space(uni.id), body: body)
        let before = try Data(contentsOf: fixture.url("Uni/Thesis.md"))

        let failing = NoteStore(
            catalog: fixture.catalog, fileSystem: InterruptedWriteFileSystem(interruptingUnder: fixture.root),
            timeSource: fixture.clock, timeZone: { LibraryFixture.timeZone })
        var mine = try #require(created.text)
        mine.body += "One more paragraph that never reaches the disk.\n"
        await #expect(throws: CocoaError.self) {
            _ = try await failing.save(mine, to: created.ref, expecting: created.stamp)
        }

        #expect(try Data(contentsOf: fixture.url("Uni/Thesis.md")) == before)
        // The half-written file is hidden, so it is not taken for a note.
        let listing = try await fixture.catalog.listing(of: .root, in: .space(uni.id))
        #expect(listing.notes.map(\.title) == ["Thesis"])

        // The same text saves once the disk works again.
        guard case .saved(let saved) = try await fixture.notes.save(mine, to: created.ref, expecting: created.stamp)
        else {
            Issue.record("expected the retry to save")
            return
        }
        #expect(saved.text?.body == mine.body)
    }

    // MARK: - Renaming and moving

    @Test("Renaming changes the file's name and keeps its extension")
    func rename() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let uni = try await fixture.space("Uni")
        try fixture.write("a", to: "Uni/First.markdown")
        try fixture.write("b", to: "Uni/Second.md")

        let renamed = try await fixture.notes.rename(fixture.ref(uni, "First.markdown"), to: "Chapter 1: Start")
        #expect(renamed == fixture.ref(uni, "Chapter 1- Start.markdown"))
        #expect(try fixture.read("Uni/Chapter 1- Start.markdown") == "a")

        await #expect(throws: NoteStoreError.nameTaken("second")) {
            try await fixture.notes.rename(renamed, to: "second")
        }
        let same = try await fixture.notes.rename(renamed, to: "Chapter 1: Start")
        #expect(same == renamed)

        // Only the letter case changes: the same file, not a clash.
        let recased = try await fixture.notes.rename(fixture.ref(uni, "Second.md"), to: "SECOND")
        #expect(recased == fixture.ref(uni, "SECOND.md"))
        #expect(fixture.names(in: "Uni") == ["Chapter 1- Start.markdown", "SECOND.md"])
    }

    @Test("Moving a note files it elsewhere, with a number when the name is taken there")
    func move() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let uni = try await fixture.space("Uni")
        try fixture.write("from the inbox", to: "Inbox/Idea.md")
        try fixture.write("already there", to: "Uni/Physics/Idea.md")

        let moved = try await fixture.notes.move(fixture.inbox("Idea.md"), to: ItemPath("Physics")!, in: .space(uni.id))
        #expect(moved == fixture.ref(uni, "Physics/Idea 2.md"))
        #expect(try fixture.read("Uni/Physics/Idea 2.md") == "from the inbox")
        #expect(try fixture.read("Uni/Physics/Idea.md") == "already there")
        #expect(!fixture.exists("Inbox/Idea.md"))

        // Into the folder it is already in: nothing happens.
        let unmoved = try await fixture.notes.move(moved, to: ItemPath("Physics")!, in: .space(uni.id))
        #expect(unmoved == moved)
    }

    @Test("A note's attachments follow it: moved when only it uses them, copied when others do")
    func attachmentsFollow() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let uni = try await fixture.space("Uni")
        try fixture.write(
            "![[photo.png]] ![[shared.pdf|300]] [doc](Attachments/my%20doc.txt) ![[missing.png]] [[Other note]]\n",
            to: "Inbox/Capture.md")
        try fixture.write("Also uses ![[shared.pdf]]", to: "Inbox/Other.md")
        try fixture.write("photo", to: "Inbox/Attachments/photo.png")
        try fixture.write("shared", to: "Inbox/Attachments/shared.pdf")
        try fixture.write("doc", to: "Inbox/Attachments/my doc.txt")
        try fixture.write("unrelated", to: "Inbox/Attachments/unrelated.png")

        let moved = try await fixture.notes.move(
            fixture.inbox("Capture.md"), to: ItemPath("Physics")!, in: .space(uni.id))
        #expect(moved == fixture.ref(uni, "Physics/Capture.md"))
        #expect(fixture.names(in: "Uni/Physics/Attachments") == ["my doc.txt", "photo.png", "shared.pdf"])
        #expect(fixture.names(in: "Inbox/Attachments") == ["shared.pdf", "unrelated.png"])
        // Nothing clashed, so the note's text is untouched.
        #expect(
            try fixture.read("Uni/Physics/Capture.md")
                == "![[photo.png]] ![[shared.pdf|300]] [doc](Attachments/my%20doc.txt) ![[missing.png]] [[Other note]]\n"
        )
    }

    @Test("An attachment that meets a different file of the same name gets a number, and the note follows")
    func attachmentClash() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let uni = try await fixture.space("Uni")
        try fixture.write(
            "See ![[diagram.png]] and ![x](Attachments/diagram.png) and ![[same.png]]\n", to: "Inbox/Capture.md")
        try fixture.write("new diagram", to: "Inbox/Attachments/diagram.png")
        try fixture.write("identical", to: "Inbox/Attachments/same.png")
        try fixture.write("old diagram", to: "Uni/Attachments/diagram.png")
        try fixture.write("identical", to: "Uni/Attachments/same.png")

        _ = try await fixture.notes.move(fixture.inbox("Capture.md"), to: .root, in: .space(uni.id))
        #expect(fixture.names(in: "Uni/Attachments") == ["diagram 2.png", "diagram.png", "same.png"])
        #expect(try fixture.read("Uni/Attachments/diagram.png") == "old diagram")
        #expect(try fixture.read("Uni/Attachments/diagram 2.png") == "new diagram")
        #expect(
            try fixture.read("Uni/Capture.md")
                == "See ![[diagram 2.png]] and ![x](Attachments/diagram%202.png) and ![[same.png]]\n")
    }

    @Test("Files and folders move too")
    func moveItems() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let uni = try await fixture.space("Uni")
        try fixture.write("pdf", to: "Inbox/Slides.pdf")
        try fixture.write("note", to: "Inbox/Scans/Page 1.md")
        try fixture.write("other", to: "Uni/Slides.pdf")

        let file = try await fixture.notes.moveItem(ItemPath("Slides.pdf")!, in: .inbox, to: .root, in: .space(uni.id))
        #expect(file == ItemPath("Slides 2.pdf"))
        let folder = try await fixture.notes.moveItem(
            ItemPath("Scans")!, in: .inbox, to: ItemPath("Physics")!, in: .space(uni.id))
        #expect(folder == ItemPath("Physics/Scans"))
        #expect(try fixture.read("Uni/Physics/Scans/Page 1.md") == "note")
        #expect(fixture.names(in: "Inbox").isEmpty)

        // A folder can't be moved into itself.
        await #expect(throws: NoteStoreError.self) {
            try await fixture.notes.moveItem(
                ItemPath("Physics")!, in: .space(uni.id), to: ItemPath("Physics/Scans")!, in: .space(uni.id))
        }
    }

    // MARK: - Trash

    @Test("Deleting moves to the Trash, and undo puts it back")
    func trashAndRestore() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let uni = try await fixture.space("Uni")
        let ref = fixture.ref(uni, "Physics/Lecture 7.md")
        try fixture.write("keep me", to: "Uni/Physics/Lecture 7.md")

        let trashed = try #require(try await fixture.notes.trash(ref))
        #expect(!fixture.exists("Uni/Physics/Lecture 7.md"))
        #expect(String(decoding: try Data(contentsOf: trashed), as: UTF8.self) == "keep me")

        // Meanwhile a new note took the name.
        try fixture.write("newer", to: "Uni/Physics/Lecture 7.md")
        let restored = try await fixture.notes.restore(from: trashed, to: ref.path, in: ref.container)
        #expect(restored == ItemPath("Physics/Lecture 7 2.md"))
        #expect(try fixture.read("Uni/Physics/Lecture 7 2.md") == "keep me")

        let folder = try #require(try await fixture.notes.trashItem(ItemPath("Physics")!, in: .space(uni.id)))
        #expect(!fixture.exists("Uni/Physics"))
        _ = try await fixture.notes.restore(from: folder, to: ItemPath("Physics")!, in: .space(uni.id))
        #expect(fixture.names(in: "Uni/Physics") == ["Lecture 7 2.md", "Lecture 7.md"])
    }

    // MARK: - Folders and attachments

    @Test("Folders: new ones get a number when the name is taken, renames refuse a clash")
    func folders() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let uni = try await fixture.space("Uni")
        let first = try await fixture.notes.createFolder(named: "New Folder", in: .root, container: .space(uni.id))
        let second = try await fixture.notes.createFolder(named: "new folder", in: .root, container: .space(uni.id))
        #expect(first == ItemPath("New Folder"))
        #expect(second == ItemPath("new folder 2"))

        let renamed = try await fixture.notes.renameFolder(second, in: .space(uni.id), to: "Maths: year 1")
        #expect(renamed == ItemPath("Maths- year 1"))
        await #expect(throws: NoteStoreError.nameTaken("New Folder")) {
            try await fixture.notes.renameFolder(renamed, in: .space(uni.id), to: "New Folder")
        }
        await #expect(throws: NoteStoreError.reservedName("Attachments")) {
            try await fixture.notes.renameFolder(renamed, in: .space(uni.id), to: "Attachments")
        }
        #expect(fixture.names(in: "Uni") == ["Maths- year 1", "New Folder"])
    }

    @Test("Dropped files are copied beside the note, never moved")
    func addAttachments() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let uni = try await fixture.space("Uni")
        let note = try await fixture.notes.create(title: "Lab", in: ItemPath("Physics")!, container: .space(uni.id))
        let outside = try fixture.folder.makeDirectory("Downloads")
        let photo = outside.appending(component: "photo.png")
        let hidden = outside.appending(component: ".secret")
        try Data("one".utf8).write(to: photo)
        try Data("two".utf8).write(to: hidden)

        let first = try await fixture.notes.addAttachments([photo, hidden], to: note.ref)
        let second = try await fixture.notes.addAttachments([photo], to: note.ref)
        #expect(first == [ItemPath("Physics/Attachments/photo.png"), ItemPath("Physics/Attachments/secret")])
        #expect(second == [ItemPath("Physics/Attachments/photo 2.png")])
        #expect(TestFiles.exists(photo))
        #expect(TestFiles.names(in: fixture.url("Uni/Physics/Attachments")) == ["photo.png", "photo 2.png", "secret"])

        let pasted = try await fixture.notes.addAttachment(Data("img".utf8), named: "Pasted image.png", to: note.ref)
        #expect(pasted == ItemPath("Physics/Attachments/Pasted image.png"))

        let found = await fixture.notes.attachmentURL(named: "photo.png", for: note.ref)
        #expect(found?.lastPathComponent == "photo.png")
        #expect(await fixture.notes.attachmentURL(named: "nothing.png", for: note.ref) == nil)
        // Attachments are not notes or folders of the space.
        let listing = try await fixture.catalog.listing(of: ItemPath("Physics")!, in: .space(uni.id))
        #expect(listing.folders.isEmpty)
        #expect(listing.notes.map(\.title) == ["Lab"])
    }

    // MARK: - Safety

    @Test("Nothing is written through a link that leads out of the library")
    func symbolicLinks() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let uni = try await fixture.space("Uni")
        let outside = try fixture.folder.makeDirectory("Outside")
        try Data("private".utf8).write(to: outside.appending(component: "Secret.md"))
        try FileManager.default.createSymbolicLink(at: fixture.url("Uni/Escape"), withDestinationURL: outside)

        await #expect(throws: LibraryCatalogError.outsideLibrary) {
            try await fixture.notes.create(title: "x", in: ItemPath("Escape")!, container: .space(uni.id))
        }
        await #expect(throws: LibraryCatalogError.outsideLibrary) {
            try await fixture.notes.read(fixture.ref(uni, "Escape/Secret.md"))
        }
        await #expect(throws: LibraryCatalogError.outsideLibrary) {
            try await fixture.notes.trash(fixture.ref(uni, "Escape/Secret.md"))
        }
        #expect(TestFiles.names(in: outside) == ["Secret.md"])
    }

    @Test("A library from a newer Elenath is not changed")
    func readOnlyLibrary() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let uni = try await fixture.space("Uni")
        let created = try await fixture.notes.create(title: "Plan", in: .root, container: .space(uni.id), body: "v1")
        let libraryFile = fixture.url(".elenath/library.json")
        let newer = try fixture.read(".elenath/library.json").replacingOccurrences(
            of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 99")
        try Data(newer.utf8).write(to: libraryFile)

        let catalog = LibraryCatalog(
            root: fixture.root, safetyDirectory: fixture.safety, fileSystem: fixture.fileSystem,
            timeSource: fixture.clock)
        #expect(try await catalog.open().isReadOnly)
        let notes = NoteStore(catalog: catalog, fileSystem: fixture.fileSystem, timeSource: fixture.clock)
        let ref = NoteRef(container: created.ref.container, path: created.ref.path)

        let loaded = try await notes.read(ref)
        #expect(loaded.isReadOnly)
        var text = try #require(loaded.text)
        text.body = "changed"
        await #expect(throws: NoteStoreError.readOnly) { try await notes.save(text, to: ref, expecting: loaded.stamp) }
        await #expect(throws: NoteStoreError.readOnly) {
            try await notes.create(title: "x", in: .root, container: .inbox)
        }
        await #expect(throws: NoteStoreError.readOnly) { try await notes.rename(ref, to: "y") }
        await #expect(throws: NoteStoreError.readOnly) { try await notes.trash(ref) }
        await #expect(throws: NoteStoreError.readOnly) { try await notes.move(ref, to: .root, in: .inbox) }
        #expect(try fixture.read("Uni/Plan.md").hasSuffix("v1\n"))
    }
}
