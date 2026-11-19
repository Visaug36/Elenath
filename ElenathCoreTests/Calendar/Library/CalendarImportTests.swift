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
}
