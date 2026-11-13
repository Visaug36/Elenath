import ElenathCore
import Foundation
import Testing

struct ModelTests {
    @Test func spaceColorsReadAndWriteAsText() throws {
        let colors: [SpaceColor] = [.palette(.clay), .palette(.rose), .custom(red: 0x33, green: 0x66, blue: 0xCC)]
        let data = try JSONEncoder().encode(colors)
        #expect(String(decoding: data, as: UTF8.self) == "[\"clay\",\"rose\",\"#3366CC\"]")
        #expect(try JSONDecoder().decode([SpaceColor].self, from: data) == colors)
    }

    @Test func customColorsParseLeniently() {
        #expect(SpaceColor(hexString: "#3366cc") == .custom(red: 0x33, green: 0x66, blue: 0xCC))
        #expect(SpaceColor(hexString: "3366CC") == .custom(red: 0x33, green: 0x66, blue: 0xCC))
        #expect(SpaceColor(hexString: "#36C") == nil)
        #expect(SpaceColor(hexString: "#GGGGGG") == nil)
        #expect(SpaceColor(hexString: "teal") == nil)
        #expect(SpaceColor.palette(.teal).hexString == nil)
    }

    @Test func anUnknownColorIsAnError() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode([SpaceColor].self, from: Data("[\"mauve\"]".utf8))
        }
    }

    @Test func identifiersAreStoredAsPlainUUIDs() throws {
        let uuid = UUID(uuidString: "0E6C3E2F-6F0B-4C55-9A1E-1D6A2B7C8D90")!
        let data = try JSONEncoder().encode([SpaceID(uuid)])
        #expect(String(decoding: data, as: UTF8.self) == "[\"0E6C3E2F-6F0B-4C55-9A1E-1D6A2B7C8D90\"]")
        #expect(try JSONDecoder().decode([SpaceID].self, from: data) == [SpaceID(uuid)])
        #expect(NoteID(string: "0e6c3e2f-6f0b-4c55-9a1e-1d6a2b7c8d90") == NoteID(uuid))
        #expect(NoteID(uuid).string == "0E6C3E2F-6F0B-4C55-9A1E-1D6A2B7C8D90")
        #expect(NoteID(string: "not an id") == nil)
    }

    @Test func itemPathsNeverLeaveTheirContainer() {
        #expect(ItemPath("Physics/Lecture 7 notes.md")?.components == ["Physics", "Lecture 7 notes.md"])
        #expect(ItemPath("") == .root)
        #expect(ItemPath("..") == nil)
        #expect(ItemPath("Physics/../../etc") == nil)
        #expect(ItemPath("/etc/passwd") == nil)
        #expect(ItemPath("Physics//notes.md") == nil)
        #expect(ItemPath("./notes.md") == nil)
        #expect(ItemPath.root.appending("..") == nil)
        #expect(ItemPath.root.appending("a/b") == nil)
        #expect(ItemPath(name: "notes.md")?.description == "notes.md")
    }

    @Test func itemPathParts() throws {
        let path = try #require(ItemPath("Physics/Week 3/Lecture 7 notes.md"))
        #expect(path.name == "Lecture 7 notes.md")
        #expect(path.title == "Lecture 7 notes")
        #expect(path.folder.description == "Physics/Week 3")
        #expect(path.folder.folder.folder == .root)
        #expect(ItemPath.root.folder == .root)
        #expect(path.isInside(ItemPath("Physics")!))
        #expect(path.isInside(.root))
        #expect(!path.isInside(ItemPath("Phys")!))
        #expect(path.description == "Physics/Week 3/Lecture 7 notes.md")
    }

    @Test func noteFileNames() {
        #expect(ItemPath.isNoteFileName("Lecture 7 notes.md"))
        #expect(ItemPath.isNoteFileName("README.MD"))
        #expect(ItemPath.isNoteFileName("Old notes.markdown"))
        #expect(!ItemPath.isNoteFileName("Slides.pdf"))
        #expect(!ItemPath.isNoteFileName(".md"))
        #expect(!ItemPath.isNoteFileName(".hidden.md"))
        #expect(ItemPath("Version 1.2 plan.md")?.title == "Version 1.2 plan")
        #expect(ItemPath("Slides.pdf")?.title == "Slides.pdf")
    }

    @Test func itemPathURLs() throws {
        let base = URL(filePath: "/tmp/Library/Uni", directoryHint: .isDirectory)
        let path = try #require(ItemPath("Physics/Lecture 7 notes.md"))
        #expect(path.url(under: base, isDirectory: false).path == "/tmp/Library/Uni/Physics/Lecture 7 notes.md")
        #expect(ItemPath.root.url(under: base, isDirectory: true) == base)
    }

    @Test func keywordsAreNormalized() {
        let space = Space(name: "Uni", keywords: [" Uni ", "lecture", "UNI", "", "Exam"])
        #expect(space.keywords == ["uni", "lecture", "exam"])
        #expect(space.color == .palette(.teal))
        #expect(space.symbol == "folder")
        #expect(!space.isSealed)
    }
}
