import ElenathCore
import Foundation
import Testing

@Suite("Library changes")
struct LibraryPathClassifierTests {
    let uni = Space(name: "Uni")
    let redCross = Space(name: "Red Cross", isSealed: true)
    let root = "/Users/someone/Documents/Elenath"

    private func classify(_ paths: String...) -> LibraryChange {
        LibraryPathClassifier.classify(paths: paths.map { root + $0 }, rootPath: root, spaces: [uni, redCross])
    }

    @Test("A changed note names its container and itself")
    func notes() {
        let change = classify("/Uni/Physics/Lecture 7.md", "/Inbox/Thought.md", "/red cross/Shift plan.MARKDOWN")
        #expect(!change.reloadsCatalog)
        #expect(change.containers == [.space(uni.id), .inbox, .space(redCross.id)])
        #expect(
            change.notes == [
                NoteRef(container: .space(uni.id), path: ItemPath("Physics/Lecture 7.md")!),
                NoteRef(container: .inbox, path: ItemPath("Thought.md")!),
                NoteRef(container: .space(redCross.id), path: ItemPath("Shift plan.MARKDOWN")!),
            ])
    }

    @Test("Other files and folders refresh their container without naming a note")
    func files() {
        let change = classify("/Uni/Physics", "/Uni/Physics/Slides.pdf", "/Uni/Physics/Attachments/photo.png", "/Inbox")
        #expect(change.containers == [.space(uni.id), .inbox])
        #expect(change.notes.isEmpty)
        #expect(!change.reloadsCatalog)
        // A Markdown file in an attachments folder is a file, not a note.
        #expect(classify("/Uni/Attachments/readme.md").notes.isEmpty)
    }

    @Test("Noise costs nothing")
    func noise() {
        let change = classify(
            "/.elenath/library.json", "/.elenath/backups/library-20261110-143000.json", "/.DS_Store",
            "/Uni/.DS_Store", "/Uni/Physics/.elenath-copying-1234", "/Uni/.space/backups/space-1.json",
            "/Uni/Physics/.Lecture 7.md.sb-1234/Lecture 7.md")
        #expect(change.isEmpty)
    }

    @Test("What may change the list of spaces reopens the catalog")
    func structure() {
        #expect(classify("/Ideas").reloadsCatalog)  // a new top-level folder
        #expect(classify("/Ideas/First.md").reloadsCatalog)
        #expect(classify("/Uni").reloadsCatalog)  // a space's folder was renamed away or deleted
        #expect(classify("/Uni/.space/space.json").reloadsCatalog)
        #expect(classify("").reloadsCatalog)
        #expect(
            LibraryPathClassifier.classify(paths: ["/somewhere/else"], rootPath: root, spaces: [uni]).reloadsCatalog)
        #expect(!classify("/Uni/Physics/space.json").reloadsCatalog)
    }
}
