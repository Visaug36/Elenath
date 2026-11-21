import ElenathCore
import Foundation
import Testing

/// "Bring in my Ithil calendar": everything comes across, the Ithil folder is left untouched, and running
/// it again brings in nothing twice.
struct CalendarImportTests {
    /// A library with an open calendar, and an Ithil folder beside it (outside the library).
    private struct Setup {
        let fixture: LibraryFixture
        let store: CalendarStore
        let ithil: IthilFolderFixture
        let source: CalendarDocument
        var calendar: CalendarDocument
        let lectureFolder: String
        let tripFolder: String

        init(calendar existing: CalendarDocument? = nil) async throws {
            fixture = try await LibraryFixture()
            store = fixture.calendarStore()
            calendar = try await store.load().document
            if let existing {
                calendar = existing
                try await store.save(existing)
            }
            source = CalendarFixtures.sampleCalendar()
            ithil = try IthilFolderFixture(in: fixture.folder.url, calendar: source)
            let lecture = CalendarFixtures.firstOccurrence(of: source.events[0])
            lectureFolder = try ithil.addFolder(
                for: lecture, files: ["Slides.pdf": "%PDF slides", "Problems/Sheet 6.txt": "1. A ball rolls"])
            try ithil.write(Data("finder".utf8), to: "\(lectureFolder)/.DS_Store")
            tripFolder = try ithil.addFolder(
                for: CalendarFixtures.firstOccurrence(of: source.events[1]), files: ["Map.png": "PNG"])
        }

        func bringIn() async throws -> CalendarImportResult {
            try await CalendarImport.run(
                from: ithil.url, into: calendar, calendarFolder: store.folder, libraryRoot: fixture.root,
                eventFolders: store.eventFolders, fileSystem: fixture.fileSystem)
        }

        func calendarFile(_ path: String) throws -> String {
            try fixture.read("Calendar/\(path)")
        }
    }

    @Test func bringsInEverythingAndLeavesTheOriginalUntouched() async throws {
        let setup = try await Setup()
        defer { setup.fixture.remove() }
        let before = setup.ithil.snapshot()

        let result = try await setup.bringIn()
        let report = result.report
        #expect(result.document.subjects == setup.source.subjects)
        #expect(result.document.events == setup.source.events)
        #expect(result.document.id == setup.calendar.id)
        #expect(report.subjectsInSource == 2 && report.subjectsAdded == 2)
        #expect(report.eventsInSource == 3 && report.eventsAdded == 3)
        #expect(report.foldersInSource == 2)
        #expect(report.filesInSource == 3 && report.filesCopied == 3)
        #expect(report.missingFiles.isEmpty)
        #expect(report.countsMatch)
        #expect(!report.readFromBackup)

        #expect(try setup.calendarFile("\(setup.lectureFolder)/Slides.pdf") == "%PDF slides")
        #expect(try setup.calendarFile("\(setup.lectureFolder)/Problems/Sheet 6.txt") == "1. A ball rolls")
        #expect(try setup.calendarFile("\(setup.tripFolder)/Map.png") == "PNG")
        #expect(setup.fixture.exists("Calendar/\(setup.lectureFolder)/.ithil-event"))
        #expect(!setup.fixture.exists("Calendar/\(setup.lectureFolder)/.DS_Store"))
        #expect(setup.ithil.snapshot() == before)

        // Elenath finds the copied folders by their markers.
        let lecture = CalendarFixtures.firstOccurrence(of: setup.source.events[0])
        #expect(await setup.store.eventFolders.fileCount(for: lecture) == 2)
    }

    @Test func runningItAgainBringsInNothingTwice() async throws {
        var setup = try await Setup()
        defer { setup.fixture.remove() }
        let first = try await setup.bringIn()
        try await setup.store.save(first.document)
        setup.calendar = first.document
        let folders = setup.fixture.names(in: "Calendar/2026-10-06")

        let second = try await setup.bringIn()
        #expect(second.document == first.document)
        #expect(second.report.subjectsAdded == 0 && second.report.subjectsAlreadyThere == 2)
        #expect(second.report.eventsAdded == 0 && second.report.eventsAlreadyThere == 3)
        #expect(second.report.filesCopied == 0 && second.report.filesAlreadyThere == 3)
        #expect(second.report.countsMatch)
        #expect(setup.fixture.names(in: "Calendar/2026-10-06") == folders)
    }

    @Test func aSubjectTheCalendarAlreadyHasByNameIsUsed() async throws {
        let mine = Subject(name: "physics", color: .palette(.iris))
        let setup = try await Setup(calendar: CalendarDocument(subjects: [mine]))
        defer { setup.fixture.remove() }
        let result = try await setup.bringIn()
        #expect(result.document.subjects.map(\.name) == ["physics", "Personal"])
        #expect(result.report.subjectsAdded == 1 && result.report.subjectsAlreadyThere == 1)
        let lectures = result.document.events.filter { $0.title == "Physics Lecture" }
        #expect(lectures.count == 2 && lectures.allSatisfy { $0.subjectID == mine.id })
        #expect(result.report.countsMatch)
    }

    /// An event folder Elenath renamed (the event got a new title) is found by its marker and filled.
    @Test func aFolderRenamedInElenathIsFilledInsteadOfCopiedAgain() async throws {
        var setup = try await Setup()
        defer { setup.fixture.remove() }
        let first = try await setup.bringIn()
        try await setup.store.save(first.document)
        setup.calendar = first.document
        try FileManager.default.moveItem(
            at: setup.fixture.url("Calendar/\(setup.lectureFolder)"),
            to: setup.fixture.url("Calendar/2026-10-06/14.00 Mechanics"))
        try setup.ithil.write(Data("late file".utf8), to: "\(setup.lectureFolder)/Answers.txt")

        let second = try await setup.bringIn()
        #expect(second.report.filesCopied == 1)
        #expect(second.report.countsMatch)
        #expect(try setup.calendarFile("2026-10-06/14.00 Mechanics/Answers.txt") == "late file")
        #expect(!setup.fixture.exists("Calendar/\(setup.lectureFolder)"))
    }

    /// The same name in Elenath belongs to another event: Ithil's folder comes in beside it, as " 2".
    @Test func anotherEventsFolderOfTheSameNameIsLeftAlone() async throws {
        let setup = try await Setup()
        defer { setup.fixture.remove() }
        let other = Event(
            title: "Physics Lecture",
            timing: .timed(
                start: CalendarFixtures.lectureStart, end: CalendarFixtures.lectureEnd,
                timeZone: CalendarFixtures.timeZone("Europe/Amsterdam")))
        let otherFolder = try await setup.store.eventFolders.ensureFolder(
            for: CalendarFixtures.firstOccurrence(of: other))
        try Data("mine".utf8).write(to: otherFolder.appending(component: "Slides.pdf"))

        let result = try await setup.bringIn()
        #expect(result.report.countsMatch)
        #expect(try setup.calendarFile("\(setup.lectureFolder)/Slides.pdf") == "mine")
        #expect(try setup.calendarFile("\(setup.lectureFolder) 2/Slides.pdf") == "%PDF slides")
    }

    @Test func aFileAlreadyThereIsNeverOverwritten() async throws {
        let setup = try await Setup()
        defer { setup.fixture.remove() }
        try setup.fixture.write("my edited slides", to: "Calendar/\(setup.lectureFolder)/Slides.pdf")
        try setup.fixture.write(
            CalendarFixtures.markerJSON(for: CalendarFixtures.firstOccurrence(of: setup.source.events[0])),
            to: "Calendar/\(setup.lectureFolder)/.ithil-event")

        let result = try await setup.bringIn()
        #expect(try setup.calendarFile("\(setup.lectureFolder)/Slides.pdf") == "my edited slides")
        #expect(result.report.filesAlreadyThere == 1 && result.report.filesCopied == 2)
        #expect(result.report.countsMatch)
    }

    @Test func aCalendarFromANewerIthilIsRefused() async throws {
        let setup = try await Setup()
        defer { setup.fixture.remove() }
        try setup.ithil.write(
            Data(#"{"schemaVersion": 2, "id": "8C0F3E0A-7B6B-4F43-9C5E-2D2B9D1C7A11"}"#.utf8), to: ".ithil/events.json")
        let before = setup.ithil.snapshot()
        await #expect(throws: CalendarImportError.newerSchema(found: 2, supported: 1)) {
            _ = try await setup.bringIn()
        }
        #expect(setup.fixture.names(in: "Calendar").isEmpty)
        #expect(setup.ithil.snapshot() == before)
    }

    /// The damaged file is read around, never set aside or repaired: the Ithil folder is only read.
    @Test func aDamagedFileIsReadFromTheNewestBackup() async throws {
        let setup = try await Setup()
        defer { setup.fixture.remove() }
        var older = setup.source
        older.events.removeLast()
        try setup.ithil.write(
            DocumentCodec.encode(older, savedAt: CalendarFixtures.start),
            to: ".ithil/backups/events-20261006-115000.json")
        try setup.ithil.write(
            DocumentCodec.encode(setup.source, savedAt: CalendarFixtures.start.addingTimeInterval(60)),
            to: ".ithil/backups/events-20261006-115100.json")
        try setup.ithil.write(Data("{ damaged".utf8), to: ".ithil/events.json")
        let before = setup.ithil.snapshot()

        let result = try await setup.bringIn()
        #expect(result.report.readFromBackup)
        #expect(result.document.events == setup.source.events)
        #expect(setup.ithil.snapshot() == before)
    }

    @Test func aFolderWithoutACalendarIsNotAnIthilFolder() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.calendarStore()
        let calendar = try await store.load().document
        let empty = try fixture.folder.makeDirectory("Documents")
        await #expect(throws: CalendarImportError.notAnIthilFolder) {
            _ = try await CalendarImport.run(
                from: empty, into: calendar, calendarFolder: store.folder, libraryRoot: fixture.root,
                eventFolders: store.eventFolders, fileSystem: fixture.fileSystem)
        }
        try fixture.write("{ damaged", to: "../Broken/.ithil/events.json")
        await #expect(throws: CalendarImportError.unreadable) {
            _ = try await CalendarImport.run(
                from: fixture.folder.child("Broken"), into: calendar, calendarFolder: store.folder,
                libraryRoot: fixture.root, eventFolders: store.eventFolders, fileSystem: fixture.fileSystem)
        }
    }

    @Test func theLibraryItselfIsNeverBroughtIn() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.calendarStore()
        let calendar = try await store.load().document
        for folder in [store.folder, fixture.root, fixture.folder.url] {
            await #expect(throws: CalendarImportError.insideLibrary) {
                _ = try await CalendarImport.run(
                    from: folder, into: calendar, calendarFolder: store.folder, libraryRoot: fixture.root,
                    eventFolders: store.eventFolders, fileSystem: fixture.fileSystem)
            }
        }
    }

    @Test func linksInTheIthilFolderAreNeverFollowed() async throws {
        let setup = try await Setup()
        defer { setup.fixture.remove() }
        let secret = try setup.fixture.folder.makeDirectory("Private")
        try Data("private".utf8).write(to: secret.appending(component: "Diary.txt"))
        try FileManager.default.createSymbolicLink(
            at: setup.ithil.url.appending(path: "\(setup.lectureFolder)/Diary.txt"),
            withDestinationURL: secret.appending(component: "Diary.txt"))
        try FileManager.default.createSymbolicLink(
            at: setup.ithil.url.appending(component: "2026-10-30"), withDestinationURL: secret)

        let result = try await setup.bringIn()
        #expect(result.report.countsMatch)
        #expect(!setup.fixture.exists("Calendar/\(setup.lectureFolder)/Diary.txt"))
        #expect(!setup.fixture.exists("Calendar/2026-10-30"))
    }

    // MARK: - Found in the review for 0.2.0

    /// Hidden files come along under their own names (a project's `.git`, an `.env`) and are counted, so
    /// "everything is in Elenath" is true. Only the markers, the system's files and unfinished copies stay.
    @Test func hiddenFilesComeAlongUnderTheirOwnNames() async throws {
        let setup = try await Setup()
        defer { setup.fixture.remove() }
        let folder = setup.lectureFolder
        let files = [
            "Lab/main.swift": "print(1)", "Lab/.git/HEAD": "ref: refs/heads/main", "Lab/.env": "KEY=1",
            ".notes.txt": "a hidden note", "Lab/.DS_Store": "finder", "._Slides.pdf": "apple double",
            "Icon\r": "icon", ".ithil-copying-1234": "half a copy",
        ]
        for (path, text) in files {
            try setup.ithil.write(Data(text.utf8), to: "\(folder)/\(path)")
        }

        let result = try await setup.bringIn()
        // The setup's three files, main.swift, HEAD, .env and .notes.txt.
        #expect(result.report.filesInSource == 7 && result.report.filesCopied == 7)
        #expect(result.report.countsMatch)
        #expect(try setup.calendarFile("\(folder)/Lab/.git/HEAD") == "ref: refs/heads/main")
        #expect(try setup.calendarFile("\(folder)/Lab/.env") == "KEY=1")
        #expect(try setup.calendarFile("\(folder)/.notes.txt") == "a hidden note")
        #expect(!setup.fixture.exists("Calendar/\(folder)/notes.txt"))
        for left in ["Lab/.DS_Store", "._Slides.pdf", "Icon\r", ".ithil-copying-1234"] {
            #expect(!setup.fixture.exists("Calendar/\(folder)/\(left)"), "\(left) was brought in")
        }
    }

    /// A folder the user made in Finder that Ithil never marked belongs to the occurrence whose folder it
    /// is: it gets that marker, and bringing the calendar in again finds it instead of copying it twice.
    @Test func aFolderIthilNeverMarkedIsntCopiedAgain() async throws {
        var setup = try await Setup()
        defer { setup.fixture.remove() }
        let trip = CalendarFixtures.firstOccurrence(of: setup.source.events[1])
        try FileManager.default.removeItem(at: setup.ithil.url.appending(path: "\(setup.tripFolder)/.ithil-event"))
        let day = String(setup.tripFolder.split(separator: "/")[0])

        let first = try await setup.bringIn()
        #expect(first.report.countsMatch)
        #expect(setup.fixture.exists("Calendar/\(setup.tripFolder)/.ithil-event"))
        try await setup.store.save(first.document)
        setup.calendar = first.document
        // Elenath looks the folder up, as showing the event's files does.
        #expect(await setup.store.eventFolders.existingFolder(for: trip) != nil)
        let folders = setup.fixture.names(in: "Calendar/\(day)")

        let second = try await setup.bringIn()
        #expect(second.report.filesCopied == 0 && second.report.filesAlreadyThere == 3)
        #expect(second.report.countsMatch)
        #expect(setup.fixture.names(in: "Calendar/\(day)") == folders)
    }

    /// Whatever was deleted while the files were copied stays deleted: only the Ithil folder's calendar is
    /// merged into the calendar as it is afterwards, and the report counts against that.
    @Test func whatWasDeletedDuringTheCopyStaysDeleted() async throws {
        let dentist = Event(
            title: "Dentist",
            timing: .timed(
                start: CalendarFixtures.lectureStart, end: CalendarFixtures.lectureEnd,
                timeZone: CalendarFixtures.timeZone("Europe/Amsterdam")))
        let setup = try await Setup(calendar: CalendarDocument(events: [dentist]))
        defer { setup.fixture.remove() }
        let result = try await setup.bringIn()
        #expect(result.document.events.contains { $0.id == dentist.id })

        var current = setup.calendar
        current.events.removeAll { $0.id == dentist.id }
        let merged = CalendarImport.merge(result, into: current)
        #expect(!merged.document.events.contains { $0.id == dentist.id })
        #expect(merged.document.events == setup.source.events)
        #expect(merged.report.eventsAdded == 3 && merged.report.subjectsAdded == 2)
        #expect(merged.report.filesCopied == result.report.filesCopied)
        #expect(merged.report.countsMatch)
    }

    /// A chosen folder whose `.ithil` links to another folder's calendar isn't an Ithil folder, and backups
    /// reached through a link aren't read.
    @Test func linkedCalendarFoldersAreNeverFollowed() async throws {
        let setup = try await Setup()
        defer { setup.fixture.remove() }
        let chosen = try setup.fixture.folder.makeDirectory("Chosen")
        try FileManager.default.createSymbolicLink(
            at: chosen.appending(component: ".ithil"),
            withDestinationURL: setup.ithil.url.appending(component: ".ithil"))
        await #expect(throws: CalendarImportError.notAnIthilFolder) {
            _ = try await CalendarImport.run(
                from: chosen, into: setup.calendar, calendarFolder: setup.store.folder, libraryRoot: setup.fixture.root,
                eventFolders: setup.store.eventFolders, fileSystem: setup.fixture.fileSystem)
        }

        let elsewhere = try setup.fixture.folder.makeDirectory("Elsewhere")
        try DocumentCodec.encode(setup.source, savedAt: CalendarFixtures.start).write(
            to: elsewhere.appending(component: "events-20261006-115000.json"))
        try FileManager.default.createSymbolicLink(
            at: setup.ithil.url.appending(path: ".ithil/backups"), withDestinationURL: elsewhere)
        try setup.ithil.write(Data("{ damaged".utf8), to: ".ithil/events.json")
        await #expect(throws: CalendarImportError.unreadable) {
            _ = try await setup.bringIn()
        }
    }

    /// A day folder in the calendar that is a link (into a space, here) is never written through: copies
    /// stay inside the calendar's folder, and what couldn't come in is reported.
    @Test func nothingIsWrittenThroughALinkInTheCalendarFolder() async throws {
        let setup = try await Setup()
        defer { setup.fixture.remove() }
        _ = try await setup.fixture.space("Uni")
        try FileManager.default.createDirectory(
            at: setup.fixture.url("Uni/Planted"), withIntermediateDirectories: true, attributes: nil)
        let day = String(setup.lectureFolder.split(separator: "/")[0])
        try FileManager.default.createSymbolicLink(
            at: setup.fixture.url("Calendar/\(day)"), withDestinationURL: setup.fixture.url("Uni/Planted"))

        let result = try await setup.bringIn()
        #expect(!result.report.countsMatch)
        #expect(!result.report.missingFiles.isEmpty)
        #expect(setup.fixture.names(in: "Uni/Planted").isEmpty)
    }
}
