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

    @Test("The calendar's file reloads the calendar; its event folders refresh their files")
    func calendar() {
        let saved = classify("/Calendar/.ithil/events.json")
        #expect(saved.reloadsCalendar && !saved.calendarFiles && !saved.reloadsCatalog && saved.containers.isEmpty)

        let files = classify(
            "/Calendar/2026-11-16/14.00 Physics Lecture/Slides.pdf", "/Calendar/2026-11-16/14.00 Lab/.ithil-event")
        #expect(files.calendarFiles && !files.reloadsCalendar && !files.reloadsCatalog && files.containers.isEmpty)

        let folder = classify("/Calendar")
        #expect(folder.reloadsCalendar && folder.calendarFiles)

        let noise = classify(
            "/Calendar/.ithil/backups/events-20261116-143000.json", "/Calendar/.ithil/events.corrupt-1.json",
            "/Calendar/.ithil/.events.json.tmp", "/Calendar/.DS_Store", "/Calendar/2026-11-16/.DS_Store")
        #expect(noise.isEmpty)

        // A space from Elenath 0.1 called "Calendar" is still a space until it is renamed.
        let oldSpace = Space(name: "Calendar")
        let change = LibraryPathClassifier.classify(
            paths: [root + "/Calendar/Timetable.md"], rootPath: root, spaces: [uni, oldSpace])
        #expect(change.containers == [.space(oldSpace.id)])
        #expect(!change.reloadsCalendar && !change.calendarFiles)

        var merged = LibraryChange()
        merged.merge(saved)
        merged.merge(files)
        #expect(merged.reloadsCalendar && merged.calendarFiles && !merged.isEmpty)
    }
}
