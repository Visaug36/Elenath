import ElenathCore
import Foundation
import Testing

struct LibraryCatalogTests {
    private struct Fixture {
        let folder: TempFolder
        let root: URL
        let safety: URL
        let clock = TestClock(Date(timeIntervalSince1970: 1_794_321_000))
        let fileSystem: TrashingFileSystem

        init() throws {
            folder = try TempFolder()
            root = try folder.makeDirectory("Elenath")
            safety = folder.child("Safety")
            fileSystem = TrashingFileSystem(trashIn: folder.url)
        }

        /// A catalog as a fresh launch would make it.
        func catalog(knownLibraryID: LibraryID? = nil) -> LibraryCatalog {
            LibraryCatalog(
                root: root, safetyDirectory: safety, knownLibraryID: knownLibraryID, fileSystem: fileSystem,
                timeSource: clock)
        }

        func space(_ name: String) -> URL {
            root.appending(component: name, directoryHint: .isDirectory)
        }

        func spaceFile(_ name: String) -> URL {
            space(name).appending(components: ".space", "space.json", directoryHint: .notDirectory)
        }

        func write(_ text: String, to path: String) throws {
            let url = root.appending(path: path, directoryHint: .notDirectory)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            try Data(text.utf8).write(to: url)
        }
    }

    // MARK: - Creating and opening

    @Test func aNewLibraryHasAnInboxAndNoSpaces() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        let created = try await fixture.catalog().create()
        #expect(created.spaces.isEmpty)
        #expect(!created.isReadOnly)
        #expect(TestFiles.names(in: fixture.root) == [".elenath", "Inbox"])

        let opened = try await fixture.catalog().open()
        #expect(opened.id == created.id)
        #expect(opened.spaces.isEmpty)
        #expect(opened.recoveries.isEmpty)
        await #expect(throws: (any Error).self) {
            try await fixture.catalog().create()
        }
    }

    @Test func aFolderWithoutALibraryIsMissing() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        await #expect(throws: DocumentStoreError.missing) {
            try await fixture.catalog().open()
        }
        #expect(TestFiles.names(in: fixture.root).isEmpty)
    }

    @Test func spacesAreCreatedAsFoldersAndKeepTheirOrderAndSettings() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        let catalog = fixture.catalog()
        _ = try await catalog.create()
        let uni = try await catalog.createSpace(
            named: "Uni", color: .palette(.teal), symbol: "graduationcap", description: "Courses.",
            keywords: ["Uni", "exam"])
        let redCross = try await catalog.createSpace(named: "Red Cross", color: .palette(.rose), sealed: true)
        let ideas = try await catalog.createSpace(named: "Ideas")
        #expect(TestFiles.exists(fixture.spaceFile("Uni")))
        #expect(uni.keywords == ["uni", "exam"])

        let opened = try await fixture.catalog().open()
        #expect(opened.spaces.map(\.name) == ["Uni", "Red Cross", "Ideas"])
        #expect(opened.spaces.map(\.id) == [uni.id, redCross.id, ideas.id])
        #expect(opened.spaces.map(\.isSealed) == [false, true, false])
        #expect(opened.spaces[0].symbol == "graduationcap")
        #expect(opened.spaces[0].description == "Courses.")
        #expect(opened.sealedByDefault.isEmpty)
    }

    @Test func namesAreMadeSafeAndClashesAndReservedNamesAreRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        let catalog = fixture.catalog()
        _ = try await catalog.create()
        let space = try await catalog.createSpace(named: " Uni: year 2/3 ")
        #expect(space.name == "Uni- year 2-3")
        await #expect(throws: LibraryCatalogError.nameTaken("uni- year 2-3")) {
            try await catalog.createSpace(named: "uni: year 2/3")
        }
        await #expect(throws: LibraryCatalogError.reservedName("Inbox")) {
            try await catalog.createSpace(named: "Inbox")
        }
        await #expect(throws: LibraryCatalogError.reservedName("Sketches.board")) {
            try await catalog.createSpace(named: "Sketches.board")
        }
        #expect(try await catalog.createSpace(named: ".hidden").name == "hidden")
    }

    @Test func aFolderMadeInFinderBecomesASpaceThatMixes() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        _ = try await fixture.catalog().create()
        try fixture.write("# Hello", to: "Travel/Packing list.md")
        try fixture.write("not a space", to: "loose file.md")
        try fixture.write("x", to: ".hidden/secret.md")
        try fixture.write("{}", to: "Sketches.board/board.json")

        let opened = try await fixture.catalog().open()
        #expect(opened.spaces.map(\.name) == ["Travel"])
        #expect(opened.spaces[0].isSealed == false)
        #expect(opened.sealedByDefault.isEmpty)
        #expect(TestFiles.exists(fixture.spaceFile("Travel")))
        // The same space, with the same id, the next time.
        let again = try await fixture.catalog().open()
        #expect(again.spaces.map(\.id) == opened.spaces.map(\.id))
    }

    @Test func spacesNotInTheSavedOrderComeLastByName() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        let catalog = fixture.catalog()
        _ = try await catalog.create()
        _ = try await catalog.createSpace(named: "Uni")
        try fixture.write("x", to: "zebra/a.md")
        try fixture.write("x", to: "Apple 10/a.md")
        try fixture.write("x", to: "apple 9/a.md")
        let opened = try await fixture.catalog().open()
        #expect(opened.spaces.map(\.name) == ["Uni", "apple 9", "Apple 10", "zebra"])
    }

    // MARK: - Sealing fails closed

    @Test func aLostSpaceFileIsRestoredFromTheSafetyCopyAndStaysSealed() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        let catalog = fixture.catalog()
        _ = try await catalog.create()
        let redCross = try await catalog.createSpace(named: "Red Cross", color: .palette(.rose), sealed: true)
        try FileManager.default.removeItem(at: fixture.space("Red Cross").appending(component: ".space"))

        let opened = try await fixture.catalog().open()
        let space = try #require(opened.spaces.first)
        #expect(space.id == redCross.id)
        #expect(space.isSealed)
        #expect(space.color == .palette(.rose))
        #expect(opened.recoveries.count == 1)
        #expect(opened.sealedByDefault.isEmpty)
        #expect(TestFiles.exists(fixture.spaceFile("Red Cross")))
    }

    @Test func aKnownSpaceThatCannotBeRestoredIsSealedUntilDecided() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        let catalog = fixture.catalog()
        _ = try await catalog.create()
        // It was never sealed, but once its settings are gone Elenath can't know that.
        let uni = try await catalog.createSpace(named: "Uni")
        try FileManager.default.removeItem(at: fixture.space("Uni").appending(component: ".space"))
        let library = try #require(TestFiles.names(in: fixture.safety).first { !$0.hasSuffix(".json") })
        let safetyCopy = fixture.safety.appending(components: library, "\(uni.id.rawValue.uuidString).json")
        try FileManager.default.removeItem(at: safetyCopy)

        let reopened = fixture.catalog()
        let opened = try await reopened.open()
        let space = try #require(opened.spaces.first)
        #expect(space.id == uni.id)
        #expect(space.isSealed)
        #expect(opened.sealedByDefault == [uni.id])
        #expect(!TestFiles.exists(fixture.spaceFile("Uni")))

        // The user decides: it mixes again, and that is written down.
        var decided = space
        decided.isSealed = false
        try await reopened.update(decided)
        let after = try await fixture.catalog().open()
        #expect(after.spaces.first?.isSealed == false)
        #expect(after.sealedByDefault.isEmpty)
    }

    @Test func aDamagedSpaceFileWithNothingToRestoreFromIsSealedAndLeftInPlace() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        _ = try await fixture.catalog().create()
        try fixture.write("{ damaged", to: "Notes/.space/space.json")
        let opened = try await fixture.catalog().open()
        #expect(opened.spaces.map(\.name) == ["Notes"])
        #expect(opened.spaces[0].isSealed)
        #expect(opened.sealedByDefault.count == 1)
        #expect(try Data(contentsOf: fixture.spaceFile("Notes")) == Data("{ damaged".utf8))
    }

    @Test func aSealedValueThatIsNotABooleanSealsTheSpace() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        _ = try await fixture.catalog().create()
        try fixture.write(
            #"{"schemaVersion": 1, "id": "0E6C3E2F-6F0B-4C55-9A1E-1D6A2B7C8D90", "sealed": "no"}"#,
            to: "Notes/.space/space.json")
        let opened = try await fixture.catalog().open()
        #expect(opened.spaces[0].isSealed)
        #expect(opened.sealedByDefault.count == 1)
    }

    // MARK: - Changing spaces

    @Test func updatingASpaceSavesItsSettings() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        let catalog = fixture.catalog()
        _ = try await catalog.create()
        var space = try await catalog.createSpace(named: "Ideas")
        space.isSealed = true
        space.color = .custom(red: 1, green: 2, blue: 3)
        space.keywords = ["idea"]
        try await catalog.update(space)
        #expect(await catalog.spaces() == [space])
        #expect(try await fixture.catalog().open().spaces == [space])
        await #expect(throws: LibraryCatalogError.unknownSpace) {
            try await catalog.update(Space(name: "Nowhere"))
        }
    }

    @Test func renamingASpaceRenamesItsFolderAndKeepsItsIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        let catalog = fixture.catalog()
        _ = try await catalog.create()
        let uni = try await catalog.createSpace(named: "Uni", sealed: true)
        _ = try await catalog.createSpace(named: "Ideas")
        try fixture.write("# Notes", to: "Uni/Physics/Lecture 7 notes.md")

        let renamed = try await catalog.renameSpace(uni.id, to: "University")
        #expect(renamed.id == uni.id)
        #expect(renamed.name == "University")
        #expect(!TestFiles.exists(fixture.space("Uni")))
        #expect(TestFiles.exists(fixture.space("University").appending(path: "Physics/Lecture 7 notes.md")))
        await #expect(throws: LibraryCatalogError.nameTaken("ideas")) {
            try await catalog.renameSpace(uni.id, to: "ideas")
        }
        await #expect(throws: LibraryCatalogError.reservedName("Inbox")) {
            try await catalog.renameSpace(uni.id, to: "Inbox")
        }
        // Only the letter case changes: the same folder, not a clash.
        #expect(try await catalog.renameSpace(uni.id, to: "UNIVERSITY").name == "UNIVERSITY")

        let opened = try await fixture.catalog().open()
        #expect(opened.spaces.map(\.name) == ["UNIVERSITY", "Ideas"])
        #expect(opened.spaces[0].id == uni.id)
        #expect(opened.spaces[0].isSealed)
    }

    @Test func reorderingIsRemembered() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        let catalog = fixture.catalog()
        _ = try await catalog.create()
        let first = try await catalog.createSpace(named: "First")
        let second = try await catalog.createSpace(named: "Second")
        let third = try await catalog.createSpace(named: "Third")
        try await catalog.reorderSpaces([third.id, first.id])
        #expect(await catalog.spaces().map(\.id) == [third.id, first.id, second.id])
        #expect(try await fixture.catalog().open().spaces.map(\.name) == ["Third", "First", "Second"])
    }

    @Test func trashingASpaceMovesItsWholeFolderToTheTrash() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        let catalog = fixture.catalog()
        _ = try await catalog.create()
        let space = try await catalog.createSpace(named: "Old")
        try fixture.write("keep me", to: "Old/note.md")
        let trashed = try #require(try await catalog.trashSpace(space.id))
        #expect(!TestFiles.exists(fixture.space("Old")))
        #expect(try Data(contentsOf: trashed.appending(component: "note.md")) == Data("keep me".utf8))
        #expect(await catalog.spaces().isEmpty)
        #expect(try await fixture.catalog().open().spaces.isEmpty)
    }

    // MARK: - Folders

    @Test func aListingShowsFoldersNotesAndFilesButNotElenathsOwn() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        let catalog = fixture.catalog()
        _ = try await catalog.create()
        let uni = try await catalog.createSpace(named: "Uni")
        try fixture.write("a", to: "Uni/Reading list.md")
        try fixture.write("b", to: "Uni/notes 10.markdown")
        try fixture.write("c", to: "Uni/notes 9.md")
        try fixture.write("pdf", to: "Uni/Syllabus.pdf")
        try fixture.write("x", to: "Uni/.DS_Store")
        try fixture.write("x", to: "Uni/Physics/Lecture 7 notes.md")
        try fixture.write("x", to: "Uni/Attachments/photo.png")
        try fixture.write("{}", to: "Uni/Diagrams.board/board.json")

        let listing = try await catalog.listing(of: .root, in: .space(uni.id))
        #expect(listing.folders.map(\.description) == ["Physics"])
        #expect(listing.notes.map(\.title) == ["notes 9", "notes 10", "Reading list"])
        #expect(listing.notes.first?.byteCount == 1)
        #expect(listing.files.map(\.name) == ["Syllabus.pdf"])

        let physics = try #require(ItemPath("Physics"))
        #expect(
            try await catalog.listing(of: physics, in: .space(uni.id)).notes.map(\.path.description)
                == ["Physics/Lecture 7 notes.md"])
        let nowhere = try #require(ItemPath("Nowhere"))
        #expect(try await catalog.listing(of: nowhere, in: .space(uni.id)).notes.isEmpty)
        #expect(try await catalog.listing(of: .root, in: .inbox).notes.isEmpty)
    }

    @Test func nothingIsReachedThroughALinkThatLeavesTheLibrary() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        let catalog = fixture.catalog()
        _ = try await catalog.create()
        let uni = try await catalog.createSpace(named: "Uni")
        let outside = try fixture.folder.makeDirectory("Outside")
        try Data("private".utf8).write(to: outside.appending(component: "secret.md"))
        try FileManager.default.createSymbolicLink(
            at: fixture.space("Uni").appending(component: "Way out"), withDestinationURL: outside)

        // The link isn't listed as a folder, and a path through it is refused.
        #expect(try await catalog.listing(of: .root, in: .space(uni.id)).folders.isEmpty)
        let through = try #require(ItemPath("Way out/secret.md"))
        let wayOut = try #require(ItemPath("Way out"))
        await #expect(throws: LibraryCatalogError.outsideLibrary) {
            try await catalog.url(for: through, in: .space(uni.id), isDirectory: false)
        }
        await #expect(throws: LibraryCatalogError.outsideLibrary) {
            try await catalog.listing(of: wayOut, in: .space(uni.id))
        }
        #expect(catalog.contains(fixture.space("Uni")))
        #expect(!catalog.contains(outside))
    }

    // MARK: - Newer versions

    @Test func aLibraryFromANewerElenathOpensReadOnly() async throws {
        let fixture = try Fixture()
        defer { fixture.folder.remove() }
        let catalog = fixture.catalog()
        _ = try await catalog.create()
        _ = try await catalog.createSpace(named: "Uni")
        let file = fixture.root.appending(components: ".elenath", "library.json", directoryHint: .notDirectory)
        let text = try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 7")
            .replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 7")
        try Data(text.utf8).write(to: file)
        try fixture.write("x", to: "New folder/a.md")

        let reopened = fixture.catalog()
        let opened = try await reopened.open()
        #expect(opened.isReadOnly)
        #expect(opened.spaces.map(\.name) == ["Uni", "New folder"])
        #expect(opened.spaces.filter { !$0.isReadOnly }.isEmpty)
        // Nothing is written: not library.json, not a space.json for the new folder.
        #expect(try String(contentsOf: file, encoding: .utf8) == text)
        #expect(!TestFiles.exists(fixture.spaceFile("New folder")))
        await #expect(throws: LibraryCatalogError.readOnly) {
            try await reopened.createSpace(named: "More")
        }
    }
}
