import ElenathCore
import Foundation
import Testing

/// What ⌘-click opens without asking, and how edits that couldn't be saved are kept. From the independent
/// review before 0.1.1 (docs/RELEASE_CHECKLIST.md).
@Suite("Opening links and files, and Recovery")
struct OpenAndRecoveryTests {
    // MARK: - Opening

    @Test("Web and mail links open at once; every other link is asked about")
    func links() {
        for address in ["https://example.com/a?b=c", "http://example.com", "HTTPS://EXAMPLE.COM", "mailto:a@b.example"]
        {
            #expect(OpenPolicy.decision(forLink: address) == .open, "\(address)")
        }
        for address in [
            "file:///Applications/Calculator.app", "file:///etc/hosts", "javascript:alert(1)", "ssh://host",
            "x-apple.systempreferences:com.apple.preference.security", "shortcuts://run-shortcut?name=x",
            "zotero://select/items/1", "obsidian://open?vault=a", "smb://server/share", "vnc://host", "tel:123",
            "facetime://a@b.example", "data:text/html,<b>x</b>", "Attachments/report.pdf", "", "http", "://x",
        ] {
            #expect(OpenPolicy.decision(forLink: address) == .ask, "\(address)")
        }
    }

    @Test("Documents, pictures, sound and video open at once; anything that could be a program is asked about")
    func files() {
        for name in [
            "photo.JPG", "scan.pdf", "essay.docx", "slides.key", "song.mp3", "lecture.mov", "notes.md", "a.b.png",
        ] {
            #expect(OpenPolicy.decision(forFileNamed: name) == .open, "\(name)")
        }
        for name in [
            "Calculator.app", "install.command", "run.sh", "script.scpt", "Automator.workflow", "page.webloc",
            "place.inetloc", "file.fileloc", "setup.pkg", "image.dmg", "tool.terminal", "archive.zip", "page.html",
            "drawing.svg", "macro.docm", "program", ".hidden", "trailing.", "x.jar", "shortcut.shortcut",
        ] {
            #expect(OpenPolicy.decision(forFileNamed: name) == .ask, "\(name)")
        }
    }

    // MARK: - Recovery

    private static let now = Date(timeIntervalSince1970: 1_794_321_005)
    private static let utc = TimeZone(secondsFromGMT: 0)!

    @Test("A recovery copy's name keeps its time, however long the title")
    func recoveryNames() {
        #expect(
            NameSanitizer.recoveryTitle(for: "Lecture 7", now: Self.now, timeZone: Self.utc)
                == "Lecture 7 (unsaved 2026-11-10 14.30.05)")
        let long = String(repeating: "Very long title ", count: 30)
        let name = NameSanitizer.recoveryTitle(for: long, now: Self.now, timeZone: Self.utc)
        #expect(name.hasSuffix(" (unsaved 2026-11-10 14.30.05)"))
        #expect(name.utf8.count <= 200)
        #expect(NameSanitizer.recoveryTitle(for: "a/b:c", now: Self.now, timeZone: Self.utc).hasPrefix("a-b-c "))
    }

    @Test("Copies are kept by where the note was, and none replaces another")
    func recoveryCopies() throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        let recovery = RecoveryFolder(folder: temp.child("Recovery/Library"), fileSystem: LocalFileSystem())
        let sealed = SpaceID()
        let long = String(repeating: "Very long title ", count: 30)
        var kept: [URL] = []
        for number in 0..<3 {
            kept.append(
                try recovery.keep(
                    Data("inbox \(number)".utf8), title: long, from: .inbox, now: Self.now, timeZone: Self.utc))
        }
        kept.append(
            try recovery.keep(
                Data("sealed".utf8), title: "Shift notes", from: .space(sealed), now: Self.now, timeZone: Self.utc))
        #expect(Set(kept).count == 4)
        let copies = recovery.copies()
        #expect(copies.map(\.space) == [nil, nil, nil, sealed])
        #expect(
            Set(copies.map { try! String(contentsOf: $0.file, encoding: .utf8) }) == [
                "inbox 0", "inbox 1", "inbox 2", "sealed",
            ])
        #expect(copies.last?.title == "Shift notes (unsaved 2026-11-10 14.30.05)")
        // Nothing half-written is left behind.
        #expect(TestFiles.names(in: recovery.folder).filter { $0.hasPrefix(".") }.isEmpty)
    }

    @Test("Copies kept by 0.1.0, at the top of the folder, are the Inbox's")
    func olderCopies() throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        let folder = try temp.makeDirectory("Recovery/Library")
        try Data("old".utf8).write(to: folder.appending(component: "Old note 2026-11-10 14.30.05.md"))
        try Data("x".utf8).write(to: folder.appending(component: ".DS_Store"))
        _ = try temp.makeDirectory("Recovery/Library/not a space")
        let copies = RecoveryFolder(folder: folder, fileSystem: LocalFileSystem()).copies()
        #expect(copies.map(\.title) == ["Old note 2026-11-10 14.30.05"])
        #expect(copies.first?.space == nil)
    }
}
