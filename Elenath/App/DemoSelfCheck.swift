import AppKit
import ElenathCore

/// `-demo -demoSelfCheck`: walks through the app's screens and actions on the demo library, then quits.
///
/// CI runs it (`scripts/selfcheck/run.sh`) and fails when the app crashes, hangs, reports an error, or
/// doesn't print "SELF-CHECK PASSED". It opens every note, types hostile text into the editor, creates,
/// renames, moves, trashes and undoes notes, folders and spaces, searches, captures, imports a folder of
/// hostile files, renames a note behind Elenath's back, and opens the panels and Settings. It only ever
/// runs on the demo library in a temporary folder.
@MainActor
final class DemoSelfCheck {
    private let model: AppModel
    private let settings: AppSettings
    private var currentStep = "starting"

    private struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    init(model: AppModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
        EditorCoordinator.showsCompletionList = false
        // NSApp may not exist yet while the App is being initialized.
        Task { @MainActor [weak self] in
            await self?.run()
        }
    }

    private func run() async {
        say("SELF-CHECK START")
        do {
            try await step("open the demo library") { try await self.waitUntilReady() }
            try await step("wait for the main window") { try await self.waitForMainWindow() }
            try await step("visit every page") { try await self.visitPages() }
            try await step("open every note") { try await self.openEveryNote() }
            try await step("type into the editor") { try await self.typeIntoEditor() }
            try await step("change notes, then undo and redo") { try await self.changeNotes() }
            try await step("change folders, then undo") { try await self.changeFolders() }
            try await step("change spaces, then undo") { try await self.changeSpaces() }
            try await step("search") { try await self.search() }
            try await step("capture") { try await self.capture() }
            try await step("import hostile files") { try await self.importHostileFiles() }
            try await step("rename a note behind Elenath's back") { try await self.renameInFinder() }
            try await step("open the panels and Settings") { try await self.openPanels() }
            try await step("switch the appearance") { try await self.switchAppearance() }
            try await step("rebuild the index") { try await self.rebuildIndex() }
        } catch {
            say("SELF-CHECK FAILED in \"\(currentStep)\": \(error)")
            exit(1)
        }
        say("SELF-CHECK PASSED")
        // Quitting goes through the same path as ⌘Q, saves included.
        NSApp.terminate(nil)
    }

    // MARK: - Steps

    private func waitUntilReady() async throws {
        try await waitFor("the library to open", seconds: 60) {
            self.model.state == .ready && !self.model.isIndexing
        }
    }

    private func waitForMainWindow() async throws {
        try await waitFor("the main window", seconds: 60) {
            self.mainWindow != nil
        }
        try await waitFor("the window's undo manager", seconds: 10) {
            self.model.undoManager != nil
        }
    }

    private func visitPages() async throws {
        try await visit(.today)
        try await visit(.inbox)
        for space in model.spaces {
            try await visit(.folder(.space(space.id), .root))
            for folder in model.folders(in: .space(space.id)) {
                try await visit(.folder(.space(space.id), folder))
            }
            for tag in model.tags {
                try await visit(.tag(tag.tag, .space(space.id)))
            }
        }
        for tag in model.tags {
            try await visit(.tag(tag.tag, .everywhere))
        }
    }

    private func openEveryNote() async throws {
        for note in try await allNotes() {
            model.open(note)
            try await settle()
        }
        model.go(to: .today)
        try await settle()
    }

    /// Text that has broken editors before: unclosed fences and links, a very long line, a wide table,
    /// right-to-left and mixed text, emoji, and many links and tags.
    private func typeIntoEditor() async throws {
        guard let note = try await allNotes().first(where: { $0.container != .inbox }) else {
            throw Failure(description: "the demo library has no notes")
        }
        model.open(note)
        try await settle(seconds: 1)
        let textView = try await editorTextView()
        let hostile = [
            "\n\n```swift\nlet unclosed = [[[[",
            "\n[[" + String(repeating: "a", count: 5_000),
            "\n" + String(repeating: "[[Lecture 7 notes]] #tag ", count: 400),
            "\n| " + Array(repeating: "column", count: 200).joined(separator: " | ") + " |",
            "\nשלום world مرحبا 👩🏽‍🔬 \u{202E}reversed\u{202C} ![[missing.png]] ![[../../outside.png]]",
            "\n- [ ] task\n- [x] done\n> quote\n# Heading\n**bold *italic `code`**",
        ]
        for piece in hostile {
            textView.insertText(piece, replacementRange: textView.selectedRange())
            try await settle(seconds: 0.2)
        }
        // What "[[" offers, without the list's own loop, which waits for a keyboard the runner hasn't got.
        textView.insertText("\n[[Lec", replacementRange: textView.selectedRange())
        try await settle(seconds: 0.5)
        let offered =
            textView.delegate?.textView?(
                textView, completions: [], forPartialWordRange: textView.rangeForUserCompletion,
                indexOfSelectedItem: nil) ?? []
        try check(!offered.isEmpty, "\"[[Lec\" offered no notes")
        // Autosave, then the save when the note closes.
        try await settle(seconds: 1)
        model.go(to: .today)
        try await waitFor("the note to be saved", seconds: 15) { !self.model.hasPendingSaves }
        model.open(note)
        try await settle(seconds: 0.5)
        try check(model.session?.ref == note, "the note didn't open again")
    }

    private func changeNotes() async throws {
        let space = try uni()
        let container = Container.space(space.id)
        try await act("make a note") { self.model.newNote(titled: "Self check", in: container, folder: .root) }
        let created = NoteRef(container: container, path: ItemPath("Self check.md")!)
        try await act("rename it") { self.model.rename(created, to: "Self check renamed") }
        let renamed = NoteRef(container: container, path: ItemPath("Self check renamed.md")!)
        let folder = model.folders(in: container).first ?? .root
        try await act("move it to \(folder.description.isEmpty ? "the top" : folder.description)") {
            self.model.move(renamed, to: folder, in: container)
        }
        say("SELF-CHECK   the notes in Uni: \(demoFiles(in: space))")
        try await undo(times: 2)
        try await redo(times: 2)
        let moved = NoteRef(container: container, path: folder.appending("Self check renamed.md")!)
        try await act("move it to the Trash") { self.model.trash(moved) }
        try await undoMoveToTrash()
    }

    private func changeFolders() async throws {
        let container = Container.space(try uni().id)
        try await act("make a folder") { self.model.newFolder(in: container, folder: .root) }
        let made = model.folders(in: container).first { $0.name.hasPrefix("New Folder") }
        guard let made else { throw Failure(description: "the new folder isn't listed") }
        try await act("rename it") { self.model.renameFolder(made, in: container, to: "Self check folder") }
        try await undo(times: 1)
        try await redo(times: 1)
        try await act("move it to the Trash") { self.model.trashItem(ItemPath("Self check folder")!, in: container) }
        try await undoMoveToTrash()
    }

    private func changeSpaces() async throws {
        try await act("make a space") { self.model.createSpace(Space(name: "Self Check", keywords: ["selfcheck"])) }
        guard var space = model.spaces.first(where: { $0.name == "Self Check" }) else {
            throw Failure(description: "the new space isn't listed")
        }
        try await visit(.folder(.space(space.id), .root))
        space.name = "Self Check Sealed"
        space.isSealed = true
        let sealed = space
        try await act("rename and seal it") { self.model.updateSpace(sealed) }
        try await undo(times: 1)
        try await redo(times: 1)
        try await act("move it to the Trash") { self.model.trashSpace(sealed.id) }
        try await undoMoveToTrash()
    }

    /// Does one of Elenath's own changes, waits for it, and fails at once, naming it, if Elenath reported
    /// an error.
    private func act(_ name: String, _ body: () -> Void) async throws {
        say("SELF-CHECK   \(name)")
        body()
        try await stepsDone()
        if let error = model.operationError {
            say("SELF-CHECK   the open note: \(model.session?.ref.path.description ?? "none")")
            say("SELF-CHECK   the notes in Uni: \(demoFiles(in: try uni()))")
            throw Failure(description: "\(name): the app reported: \(error)")
        }
    }

    /// The Markdown files of a space of the demo library, by path: to see where notes really are when an
    /// action fails. Only ever the invented demo library.
    private func demoFiles(in space: Space) -> String {
        guard let folder = model.url(for: .root, in: .space(space.id), isDirectory: true),
            let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        else { return "(no folder)" }
        var paths: [String] = []
        let base = folder.standardizedFileURL.path
        while let url = walker.nextObject() as? URL {
            guard url.pathExtension == "md" else { continue }
            let path = url.standardizedFileURL.path
            paths.append(path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent)
        }
        return paths.sorted().joined(separator: ", ")
    }

    /// Undoes a move to the Trash. In the App Sandbox Elenath may not take an item back out of the Trash
    /// (an open question since Ithil): then it must say so plainly, naming Finder's Put Back, and drop the
    /// older undo steps instead of failing at each. Either way the log says which happened.
    private func undoMoveToTrash() async throws {
        guard let undoManager = model.undoManager, undoManager.canUndo else {
            throw Failure(description: "the move to the Trash can't be undone")
        }
        say("SELF-CHECK   undo \(undoManager.undoActionName)")
        undoManager.undo()
        try await stepsDone()
        guard let error = model.operationError else {
            say("SELF-CHECK note: a move to the Trash was undone")
            return
        }
        guard error.contains("Put Back") else {
            throw Failure(description: "undoing the move to the Trash: the app reported: \(error)")
        }
        say("SELF-CHECK note: the sandbox keeps Elenath out of the Trash; the app pointed to Finder's Put Back")
        model.operationError = nil
    }

    private func search() async throws {
        for text in [
            "inertia", "\"", "*", "NEAR(", "a OR b", "-", "^", "col:", "((", String(repeating: "x", count: 2_000),
        ] {
            model.searchText = text
            try await settle(seconds: 0.3)
        }
        model.searchText = ""
        try await settle()
        model.isJumpPanelShown = true
        try await settle()
        model.isJumpPanelShown = false
        try await settle()
    }

    private func capture() async throws {
        let before = model.inboxCount
        _ = try await model.capture("self check capture", attachments: [])
        _ = try await model.capture("uni: self check capture for a space", attachments: [])
        try await waitFor("the Inbox count to grow", seconds: 10) { self.model.inboxCount > before }
    }

    private func importHostileFiles() async throws {
        let folder = try HostileFiles.write()
        let before = model.inboxCount
        model.importItems([folder], into: .inbox, folder: .root)
        try await waitFor("the import to finish", seconds: 120) { self.model.importTask == nil }
        try await waitFor("the imported notes to be indexed", seconds: 30) { self.model.inboxCount > before }
        model.dismissImportStatus()
        // Every note in the Inbox, the imported ones included, opens in the editor.
        for note in try await allNotes() where note.container == .inbox {
            model.open(note)
            try await settle(seconds: 0.2)
        }
        // A note too large to open, put in the Inbox behind Elenath's back, opens with a banner and
        // nothing that could be typed over it.
        guard let inbox = model.url(for: .root, in: .inbox, isDirectory: true) else {
            throw Failure(description: "the Inbox has no folder")
        }
        let huge = inbox.appending(component: "Grew too large.md", directoryHint: .notDirectory)
        try Data("# Grew too large\n".utf8).write(to: huge)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(NoteLimits.maximumOpenedBytes + 1))
        try handle.close()
        let hugeNote = NoteRef(container: .inbox, path: ItemPath("Grew too large.md")!)
        model.open(hugeNote)
        try await waitFor("the too-large banner", seconds: 10) { self.model.session?.banner == .tooLarge }
        try check(model.session?.isReadOnly == true, "a note too large to open could be edited")
        model.go(to: .today)
        try await settle()
    }

    /// Renames a note's file the way Finder would, and accepts the offer to update its links.
    private func renameInFinder() async throws {
        let container = Container.space(try uni().id)
        guard
            let note = try await allNotes().first(where: { $0.container == container && $0.title == "Lecture 8 notes" }
            ),
            let from = model.url(for: note.path, in: container)
        else { return }
        let to = from.deletingLastPathComponent().appending(component: "Lecture eight.md")
        try FileManager.default.moveItem(at: from, to: to)
        try await waitFor("the offer to update links", seconds: 30) { !self.model.linkRepairOffers.isEmpty }
        model.go(to: .folder(container, .root))
        try await settle()
        if let offer = model.visibleLinkRepairOffer {
            model.acceptLinkRepair(offer)
            try await stepsDone()
            try await undo(times: 1)
        }
    }

    private func openPanels() async throws {
        QuickCapturePanelController.shared.show(model: model, text: "thursday 10am physics quiz")
        try await settle(seconds: 0.5)
        QuickCapturePanelController.shared.close()
        model.demoOpensSettings = true
        try await settle(seconds: 1)
        for window in NSApp.windows where window !== mainWindow && window.isVisible && !(window is NSPanel) {
            window.close()
        }
        try await settle()
    }

    private func switchAppearance() async throws {
        for choice in [AppearanceChoice.dawn, .night, .system] {
            settings.appearance = choice
            Appearance.apply(choice)
            try await settle(seconds: 0.3)
        }
    }

    private func rebuildIndex() async throws {
        await model.rebuildIndex()
        try await waitFor("the index to be rebuilt", seconds: 60) { !self.model.isIndexing }
        try await visit(.today)
    }

    // MARK: - Helpers

    private func step(_ name: String, _ body: @MainActor () async throws -> Void) async throws {
        currentStep = name
        say("SELF-CHECK step: \(name)")
        model.operationError = nil
        try await body()
        try await settle()
        // An error Elenath reported to the user is a failure here.
        if let error = model.operationError {
            throw Failure(description: "the app reported: \(error)")
        }
    }

    private func visit(_ route: Route) async throws {
        model.go(to: route)
        try await settle()
    }

    private func undo(times: Int) async throws {
        guard let undoManager = model.undoManager else { throw Failure(description: "no undo manager") }
        for _ in 0..<times where undoManager.canUndo {
            let name = "undo \(undoManager.undoActionName)"
            try await act(name) { undoManager.undo() }
        }
    }

    private func redo(times: Int) async throws {
        guard let undoManager = model.undoManager else { throw Failure(description: "no undo manager") }
        for _ in 0..<times where undoManager.canRedo {
            let name = "redo \(undoManager.redoActionName)"
            try await act(name) { undoManager.redo() }
        }
    }

    /// Waits for Elenath's own steps (renames, moves, undo) to finish.
    private func stepsDone() async throws {
        try await settle()
        try await waitFor("the step to finish", seconds: 30) { self.model.stepsInFlight == 0 }
        try await settle()
    }

    private func settle(seconds: Double = 0.15) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private func waitFor(_ what: String, seconds: Double, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure(description: "timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func check(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw Failure(description: message)
        }
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
    }

    private func uni() throws -> Space {
        guard let space = model.spaces.first(where: { $0.name == "Uni" }) else {
            throw Failure(description: "the demo library has no Uni space")
        }
        return space
    }

    /// Every note in the library, sealed spaces and the Inbox included, each asked from its own place.
    private func allNotes() async throws -> [NoteRef] {
        guard let retrieval = model.services?.retrieval else { return [] }
        var notes: [NoteRef] = []
        var workplaces: [Workplace] = [.everywhere, .inbox]
        workplaces += model.spaces.filter(\.isSealed).map { .space($0.id) }
        for workplace in workplaces {
            for hit in try await retrieval.search(SearchQuery(text: "", limit: 10_000), from: workplace) {
                if case .note(let note) = hit.item, !notes.contains(note) {
                    notes.append(note)
                }
            }
        }
        return notes
    }

    /// The text view of the open note.
    private func editorTextView() async throws -> NoteTextView {
        for _ in 0..<50 {
            if let view = mainWindow?.contentView.flatMap({ DemoSelfCheck.find(in: $0) }) {
                mainWindow?.makeFirstResponder(view)
                return view
            }
            try await settle(seconds: 0.1)
        }
        throw Failure(description: "the editor's text view didn't appear")
    }

    private static func find(in view: NSView) -> NoteTextView? {
        if let textView = view as? NoteTextView {
            return textView
        }
        for subview in view.subviews {
            if let found = find(in: subview) {
                return found
            }
        }
        return nil
    }

    private func say(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

/// A folder of files that are hard to import: written into the app's own temporary folder for the
/// self-check's import step. Every name and byte is invented.
enum HostileFiles {
    static func write() throws -> URL {
        let fileManager = FileManager.default
        let base = URL.temporaryDirectory.appending(
            component: "Elenath self-check \(UUID().uuidString)", directoryHint: .isDirectory)
        let folder = base.appending(component: "Hostile import", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        func writeData(_ name: String, _ data: Data) throws {
            try data.write(to: folder.appending(component: name, directoryHint: .notDirectory))
        }
        func writeText(_ name: String, _ text: String) throws {
            try writeData(name, Data(text.utf8))
        }
        try writeText("Plain note.md", "A plain note with a [[link]] and a #tag.\n")
        // Two megabytes of links, tags and tasks: still styled. Three megabytes: shown as plain text.
        try writeText(
            "Huge note.md", String(repeating: "Some text [[Link]] #tag - [ ] task `code` **bold**\n", count: 40_000))
        try writeText(
            "Plain huge note.md",
            String(repeating: "Some text [[Link]] #tag - [ ] task `code` **bold**\n", count: 60_000))
        // Larger than a note can be: imported as a file. A hole in the file, so it takes no room.
        let tooLarge = folder.appending(component: "Too large to be a note.md", directoryHint: .notDirectory)
        try writeText(tooLarge.lastPathComponent, "# Too large\n")
        let handle = try FileHandle(forWritingTo: tooLarge)
        try handle.truncate(atOffset: UInt64(NoteLimits.maximumOpenedBytes + 1))
        try handle.close()
        // A named pipe: reading it would wait forever, so it is never read.
        guard mkfifo(folder.appending(component: "Pipe.md").path, 0o644) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        // Embeds of a picture that claims to be enormous, a damaged PDF, a missing file, a folder and a
        // picture on the web.
        try writeText(
            "Embeds.md",
            "![[Enormous.png]]\n![[Garbage.pdf]]\n![[Missing.png]]\n![[Deep]]\n![[Pipe.md]]\n"
                + "![remote](https://example.invalid/x.png)\n![[Enormous.png|300]]\n")
        try writeText("One long line.md", String(repeating: "word ", count: 300_000))
        try writeText(
            "Unclosed.md", "```\nnever closed\n[[also never closed\n> quote\n" + String(repeating: "[", count: 10_000))
        try writeText(
            "Front matter.md",
            "---\nid: [unclosed\ntags: {a: [b, {c: d}]}\n" + String(repeating: "  nested:\n", count: 2_000)
                + "---\nBody\n")
        try writeText(
            "Front matter never closed.md",
            "---\nid: 1\ntags: [a, b]\n" + String(repeating: "key: value\n", count: 10_000))
        try writeData("Not UTF-8.md", Data([0x48, 0x69, 0xFF, 0xFE, 0x00, 0xC3, 0x28, 0x0A]))
        try writeData("NUL bytes.txt", Data("before\u{0}after\u{0}\n".utf8))
        try writeText("CR only.txt", "line one\rline two\rline three\r")
        try writeData("BOM.md", Data([0xEF, 0xBB, 0xBF]) + Data("# Title\n".utf8))
        try writeText(String(repeating: "Very long name ", count: 14) + ".md", "long name\n")
        try writeText("Colon: in name.md", "colon\n")
        try writeText("Ünïcödé ñame.md", "unicode\n")
        try writeText("ÜNÏCÖDÉ ÑAME.md", "clashing case\n")
        try writeText(".hidden.md", "hidden: should be skipped\n")
        try writeData("Garbage.docx", Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
        try writeText("Garbage.rtf", "{\\rtf1 {{{{{{{{{{ \\unclosed" + String(repeating: "{", count: 5_000))
        try writeText(
            "Remote.html", "<html><body><img src=\"https://example.invalid/x.png\"><p>remote</p></body></html>")
        try writeText("Garbage.pdf", "%PDF-1.7\n" + String(repeating: "garbage ", count: 1_000))
        // A PNG header that claims an enormous picture.
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52])
        png += Data([0x00, 0x01, 0x86, 0xA0, 0x00, 0x01, 0x86, 0xA0, 8, 6, 0, 0, 0])
        try writeData("Enormous.png", png)
        // A chat export unpacked into a folder of its own, as Finder unzips one.
        let chat = folder.appending(component: "WhatsApp Chat", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: chat, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: chat.appending(component: "IMG-0001.jpg"))
        try Data(
            """
            10/11/2026, 09:01 - Me: a message
            10/11/2026, 09:02 - Me: IMG-0001.jpg (file attached)
            10/11/2026, 09:03 - Me: ../../../outside.txt (file attached)
            99/99/9999, 99:99 - Me: a broken date
            [10/11/2026, 09:04:00] Me: the other format
            \(String(repeating: "a line without a date\n", count: 1_000))
            """.utf8
        ).write(to: chat.appending(component: "_chat.txt"))
        // Links that point out of the folder, at themselves, and around in a loop.
        try fileManager.createSymbolicLink(
            at: folder.appending(component: "Link out.md"), withDestinationURL: URL(filePath: "/etc/hosts"))
        try fileManager.createSymbolicLink(
            at: folder.appending(component: "Loop"), withDestinationURL: folder)
        try fileManager.createSymbolicLink(
            at: folder.appending(component: "Self.md"), withDestinationURL: folder.appending(component: "Self.md"))
        let nested = folder.appending(component: "Deep", directoryHint: .isDirectory)
        var deepest = nested
        for level in 0..<40 {
            deepest = deepest.appending(component: "Level \(level)", directoryHint: .isDirectory)
        }
        try fileManager.createDirectory(at: deepest, withIntermediateDirectories: true)
        try Data("deep\n".utf8).write(to: deepest.appending(component: "Deep note.md"))
        return folder
    }
}
