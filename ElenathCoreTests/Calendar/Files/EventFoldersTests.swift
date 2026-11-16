import ElenathCore
import Foundation
import Testing

/// The real disk, recording every place a change is made, so tests can check that nothing is written
/// outside the library root and that folders go to the Trash instead of being removed.
private final class EventFoldersTestDisk: FileSystem, @unchecked Sendable {
    private let base = LocalFileSystem()
    private let trash: TestTrash
    private let lock = NSLock()
    private var changedURLs: [URL] = []
    private var removedURLs: [URL] = []
    private var trashedURLs: [URL] = []
    private var trashedItems: [URL] = []
    private var writesFail = false

    /// Every URL created, written, copied to, moved from or to, removed or trashed.
    var changed: [URL] { locked { changedURLs } }
    var removed: [URL] { locked { removedURLs } }
    var trashed: [URL] { locked { trashedURLs } }
    /// Where trashed items ended up in the test's own Trash.
    var itemsInTrash: [URL] { locked { trashedItems } }

    init(trash: TestTrash) {
        self.trash = trash
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func record(_ urls: [URL]) {
        locked { changedURLs.append(contentsOf: urls) }
    }

    /// Makes every atomic write fail from now on, like a full disk.
    func makeWritesFail() {
        locked { writesFail = true }
    }

    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    func isDirectory(at url: URL) -> Bool { base.isDirectory(at: url) }
    func contentsOfDirectory(at url: URL) throws -> [URL] { try base.contentsOfDirectory(at: url) }
    func readData(at url: URL) throws -> Data { try base.readData(at: url) }
    func modificationDate(at url: URL) -> Date? { base.modificationDate(at: url) }
    func info(at url: URL) -> FileInfo? { base.info(at: url) }

    func createDirectory(at url: URL) throws {
        record([url])
        try base.createDirectory(at: url)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        record([url])
        let fails = locked { writesFail }
        if fails {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try base.writeAtomically(data, to: url)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        record([destination])
        try base.copyItem(at: source, to: destination)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        record([source, destination])
        try base.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        record([url])
        locked { removedURLs.append(url) }
        try base.removeItem(at: url)
    }

    func trashItem(at url: URL) throws {
        record([url])
        let item = try trash.trash(url)
        locked {
            trashedURLs.append(url)
            trashedItems.append(item)
        }
    }
}

/// A unique temporary folder holding the library root ("CalendarDocument") and a sibling ("Outside") that must stay
/// untouched, plus the `EventFolders` under test.
private struct EventFoldersSandbox {
    let base: URL
    let root: URL
    let outside: URL
    let disk: EventFoldersTestDisk
    let folders: EventFolders

    init() throws {
        let name = "IthilEventFoldersTests-\(UUID().uuidString)"
        base = FileManager.default.temporaryDirectory.appending(component: name, directoryHint: .isDirectory)
        root = base.appending(component: "CalendarDocument", directoryHint: .isDirectory)
        outside = base.appending(component: "Outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true, attributes: nil)
        disk = EventFoldersTestDisk(trash: TestTrash(in: base))
        folders = EventFolders(root: root, fileSystem: disk)
    }

    /// Deletes the temporary folder, the test's Trash included.
    func remove() {
        try? FileManager.default.removeItem(at: base)
    }

    /// A location inside the root, such as "2026-10-06/14.00 Physics Lecture". Nothing is created.
    func url(_ relativePath: String) -> URL {
        root.appending(path: relativePath)
    }

    /// Another `EventFolders` on the same root, as after relaunching the app.
    func reopened() -> EventFolders {
        EventFolders(root: root, fileSystem: disk)
    }

    /// Checks that every change was made inside the root, that nothing was removed permanently and that
    /// the folder next to the root is still empty.
    func expectNothingWrittenOutsideRoot() {
        let rootComponents = Self.components(of: root)
        let outsideRoot = disk.changed.filter { url in
            let components = Self.components(of: url)
            return components.count <= rootComponents.count || !components.starts(with: rootComponents)
        }
        #expect(outsideRoot.isEmpty)
        #expect(disk.removed.isEmpty)
        #expect(EventFoldersFixture.names(in: outside).isEmpty)
    }

    /// The path's components with `.` and `..` applied (no links resolved: the tests make none on these).
    private static func components(of url: URL) -> [String] {
        var result: [String] = []
        for part in url.path.split(separator: "/") {
            if part == ".." {
                if !result.isEmpty {
                    result.removeLast()
                }
            } else if part != "." {
                result.append(String(part))
            }
        }
        return result
    }
}

/// Fixed IDs, dates and events in Amsterdam (October 2026), and file helpers.
private enum EventFoldersFixture {
    static let amsterdam = TimeZone(identifier: "Europe/Amsterdam")!
    static let created = Date(timeIntervalSince1970: 1_788_220_800)
    static let expander = OccurrenceExpander(displayTimeZone: amsterdam)

    static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "4954484C-F01D-4000-8000-%012d", number))!
    }

    static func day(_ dayOfOctober: Int) -> CalendarDate {
        CalendarDate(year: 2026, month: 10, day: dayOfOctober)
    }

    static func timing(october dayOfOctober: Int, at hour: Int, _ minute: Int) -> EventTiming {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = amsterdam
        let parts = DateComponents(year: 2026, month: 10, day: dayOfOctober, hour: hour, minute: minute)
        let start = calendar.date(from: parts)!
        return .timed(start: start, end: start.addingTimeInterval(90 * 60), timeZone: amsterdam)
    }

    static func timed(
        _ number: Int,
        _ title: String,
        october dayOfOctober: Int,
        at hour: Int,
        _ minute: Int = 0,
        recurrence: RecurrenceRule? = nil
    ) -> Event {
        Event(
            id: id(number),
            title: title,
            timing: timing(october: dayOfOctober, at: hour, minute),
            recurrence: recurrence,
            createdAt: created)
    }

    static func allDay(_ number: Int, _ title: String, october dayOfOctober: Int) -> Event {
        let date = day(dayOfOctober)
        return Event(id: id(number), title: title, timing: .allDay(start: date, end: date), createdAt: created)
    }

    static func occurrence(of event: Event, october dayOfOctober: Int) -> Occurrence {
        expander.occurrence(of: event, on: day(dayOfOctober))!
    }

    static func retitled(_ event: Event, _ title: String) -> Event {
        var copy = event
        copy.title = title
        return copy
    }

    static func moved(_ event: Event, october dayOfOctober: Int, at hour: Int, _ minute: Int = 0) -> Event {
        var copy = event
        copy.timing = timing(october: dayOfOctober, at: hour, minute)
        return copy
    }

    // MARK: Files

    static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    static func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
    }

    /// The names of the items in a folder, hidden ones included, sorted; empty if it doesn't exist.
    static func names(in folder: URL) -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return contents.sorted()
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func marker(in folder: URL) throws -> EventFolderMarker {
        let file = folder.appending(component: EventFolderMarker.fileName, directoryHint: .notDirectory)
        return try JSONDecoder().decode(EventFolderMarker.self, from: Data(contentsOf: file))
    }

    static func writeMarker(_ marker: EventFolderMarker, in folder: URL) throws {
        let file = folder.appending(component: EventFolderMarker.fileName, directoryHint: .notDirectory)
        try JSONEncoder().encode(marker).write(to: file)
    }

    /// The `EventFoldersError` that `body` throws, or nil when it throws nothing (or another error).
    static func folderError(from body: () async throws -> Void) async -> EventFoldersError? {
        do {
            try await body()
            return nil
        } catch {
            return error as? EventFoldersError
        }
    }

    static func isOutsideRoot(_ error: EventFoldersError?) -> Bool {
        guard let error, case .outsideRoot = error else { return false }
        return true
    }

    static func isNotADirectory(_ error: EventFoldersError?) -> Bool {
        guard let error, case .notADirectory = error else { return false }
        return true
    }
}

struct EventFoldersTests {
    private typealias Fixture = EventFoldersFixture

    // MARK: - Markers

    @Test func markersAreSmallJSONFiles() throws {
        let marker = EventFolderMarker(eventID: Fixture.id(7), date: Fixture.day(6))
        #expect(EventFolderMarker.fileName == ".ithil-event")
        #expect(marker.version == 1)

        let data = try JSONEncoder().encode(marker)
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        let object = try #require(parsed as? [String: Any])
        let eventID = object["eventID"] as? String
        let date = object["date"] as? String
        let version = object["version"] as? Int
        #expect(eventID == Fixture.id(7).uuidString)
        #expect(date == "2026-10-06")
        #expect(version == 1)

        let withoutVersion = "{\"eventID\": \"\(Fixture.id(7).uuidString)\", \"date\": \"2026-10-06\"}"
        let decoded = try JSONDecoder().decode(EventFolderMarker.self, from: Data(withoutVersion.utf8))
        #expect(decoded == marker)
    }

    // MARK: - Creating

    @Test func ensureFolderCreatesTheExpectedFolderWithAMarker() async throws {
        let sandbox = try EventFoldersSandbox()
        defer { sandbox.remove() }
        let lecture = Fixture.timed(1, "Physics Lecture", october: 6, at: 14)
        let occurrence = Fixture.occurrence(of: lecture, october: 6)
        let expected = sandbox.url("2026-10-06/14.00 Physics Lecture")

        let folder = try await sandbox.folders.ensureFolder(for: occurrence)
        #expect(folder.path == expected.path)
        #expect(Fixture.names(in: folder) == [".ithil-event"])
        let marker = try Fixture.marker(in: folder)
        #expect(marker == EventFolderMarker(eventID: lecture.id, date: Fixture.day(6)))

        let again = try await sandbox.folders.ensureFolder(for: occurrence)
        let found = await sandbox.folders.existingFolder(for: occurrence)
        #expect(again.path == expected.path)
        #expect(found?.path == expected.path)
        #expect(Fixture.names(in: sandbox.root) == ["2026-10-06"])
        #expect(Fixture.names(in: sandbox.url("2026-10-06")) == ["14.00 Physics Lecture"])
        sandbox.expectNothingWrittenOutsideRoot()
    }

    @Test func markedFoldersListsEveryMarkedFolderWhereverItIs() async throws {
        let sandbox = try EventFoldersSandbox()
        defer { sandbox.remove() }
        let lecture = Fixture.timed(1, "Physics Lecture", october: 6, at: 14)
        let tuesday = Fixture.occurrence(of: lecture, october: 6)
        let folder = try await sandbox.folders.ensureFolder(for: tuesday)
        let renamed = sandbox.url("2026-10-06/Mechanics")
        try FileManager.default.moveItem(at: folder, to: renamed)

        let marked = await sandbox.folders.markedFolders()
        #expect(marked.count == 1)
        #expect(marked[tuesday.id]?.lastPathComponent == "Mechanics")
        sandbox.expectNothingWrittenOutsideRoot()
    }

    @Test func allDayOccurrencesGetFoldersWithoutATime() async throws {
        let sandbox = try EventFoldersSandbox()
        defer { sandbox.remove() }
        let birthday = Fixture.allDay(1, "Mara's birthday", october: 14)
        let folder = try await sandbox.folders.ensureFolder(for: Fixture.occurrence(of: birthday, october: 14))
        #expect(folder.path == sandbox.url("2026-10-14/Mara's birthday").path)
        sandbox.expectNothingWrittenOutsideRoot()
    }

    @Test func lookupsNeverCreateAnything() async throws {
        let sandbox = try EventFoldersSandbox()
        defer { sandbox.remove() }
        let lecture = Fixture.timed(1, "Physics Lecture", october: 6, at: 14)
        let occurrence = Fixture.occurrence(of: lecture, october: 6)
        let later = Fixture.occurrence(of: Fixture.moved(lecture, october: 7, at: 9), october: 7)

        let found = await sandbox.folders.existingFolder(for: occurrence)
        let files = await sandbox.folders.files(for: occurrence)
        let count = await sandbox.folders.fileCount(for: occurrence)
        let relocated = try await sandbox.folders.relocate(from: occurrence, to: later)
        try await sandbox.folders.trashFolder(for: occurrence)
        await sandbox.folders.reindex()

        #expect(found == nil)
        #expect(files.isEmpty)
        #expect(count == 0)
        #expect(relocated == nil)
        #expect(Fixture.names(in: sandbox.root).isEmpty)
        #expect(sandbox.disk.changed.isEmpty)
    }

    @Test func aMissingRootIsNeverRecreated() async throws {
        let sandbox = try EventFoldersSandbox()
        defer { sandbox.remove() }
        let occurrence = Fixture.occurrence(of: Fixture.timed(1, "Physics Lecture", october: 6, at: 14), october: 6)
        try FileManager.default.removeItem(at: sandbox.root)

        await #expect(throws: EventFoldersError.notADirectory(sandbox.root.path)) {
            _ = try await sandbox.folders.ensureFolder(for: occurrence)
        }
        let found = await sandbox.folders.existingFolder(for: occurrence)
        try await sandbox.folders.trashFolder(for: occurrence)
        #expect(found == nil)
        #expect(!Fixture.exists(sandbox.root))
        #expect(sandbox.disk.changed.isEmpty)
    }

    @Test func aFileWhereTheDayFolderShouldBeIsReported() async throws {
        let sandbox = try EventFoldersSandbox()
        defer { sandbox.remove() }
        let occurrence = Fixture.occurrence(of: Fixture.timed(1, "Physics Lecture", october: 6, at: 14), october: 6)
        try Fixture.write("not a folder", to: sandbox.url("2026-10-06"))

        let error = await Fixture.folderError {
            _ = try await sandbox.folders.ensureFolder(for: occurrence)
        }
        #expect(Fixture.isNotADirectory(error))
        #expect(Fixture.names(in: sandbox.root) == ["2026-10-06"])
        sandbox.expectNothingWrittenOutsideRoot()
    }

    @Test func eachRepeatingOccurrenceGetsItsOwnFolder() async throws {
        let sandbox = try EventFoldersSandbox()
        defer { sandbox.remove() }
        let weekly = RecurrenceRule(frequency: .weekly)
        let lecture = Fixture.timed(1, "Physics Lecture", october: 6, at: 14, recurrence: weekly)
        let first = Fixture.occurrence(of: lecture, october: 6)
        let second = Fixture.occurrence(of: lecture, october: 13)

        let firstFolder = try await sandbox.folders.ensureFolder(for: first)
        let secondFolder = try await sandbox.folders.ensureFolder(for: second)
        try Fixture.write("week 1", to: firstFolder.appending(component: "notes.txt"))

        #expect(firstFolder.path == sandbox.url("2026-10-06/14.00 Physics Lecture").path)
        #expect(secondFolder.path == sandbox.url("2026-10-13/14.00 Physics Lecture").path)
        let firstMarker = try Fixture.marker(in: firstFolder)
        let secondMarker = try Fixture.marker(in: secondFolder)
        #expect(firstMarker == EventFolderMarker(eventID: lecture.id, date: Fixture.day(6)))
        #expect(secondMarker == EventFolderMarker(eventID: lecture.id, date: Fixture.day(13)))
        let firstCount = await sandbox.folders.fileCount(for: first)
        let secondCount = await sandbox.folders.fileCount(for: second)
        #expect(firstCount == 1)
        #expect(secondCount == 0)
        sandbox.expectNothingWrittenOutsideRoot()
    }

    @Test func ensureFolderAddsASuffixWhenTheNameIsTaken() async throws {
        let sandbox = try EventFoldersSandbox()
        defer { sandbox.remove() }
        let events = (1...3).map { Fixture.timed($0, "Physics Lecture", october: 6, at: 14) }
        var folders: [URL] = []
        for event in events {
            let folder = try await sandbox.folders.ensureFolder(for: Fixture.occurrence(of: event, october: 6))
            folders.append(folder)
        }

        let names = folders.map(\.lastPathComponent)
        #expect(names == ["14.00 Physics Lecture", "14.00 Physics Lecture 2", "14.00 Physics Lecture 3"])
        for (event, folder) in zip(events, folders) {
            let marker = try Fixture.marker(in: folder)
            #expect(marker.eventID == event.id)
        }
        let second = Fixture.occurrence(of: events[1], october: 6)
        let found = await sandbox.folders.existingFolder(for: second)
        let again = try await sandbox.folders.ensureFolder(for: second)
        #expect(found?.path == folders[1].path)
        #expect(again.path == folders[1].path)
        #expect(Fixture.names(in: sandbox.url("2026-10-06")).count == 3)

        // A file (not an Ithil folder) holding the name is skipped too.
        try Fixture.makeDirectory(sandbox.url("2026-10-07"))
        try Fixture.write("someone else's", to: sandbox.url("2026-10-07/09.00 Lab"))
        let lab = Fixture.timed(4, "Lab", october: 7, at: 9)
        let labFolder = try await sandbox.folders.ensureFolder(for: Fixture.occurrence(of: lab, october: 7))
        #expect(labFolder.lastPathComponent == "09.00 Lab 2")
        sandbox.expectNothingWrittenOutsideRoot()
    }

    @Test func aFailedMarkerWriteLeavesNoEmptyFolderBehind() async throws {
        let sandbox = try EventFoldersSandbox()
        defer { sandbox.remove() }
        let occurrence = Fixture.occurrence(of: Fixture.timed(1, "Physics Lecture", october: 6, at: 14), october: 6)
        sandbox.disk.makeWritesFail()

        await #expect(throws: (any Error).self) {
            _ = try await sandbox.folders.ensureFolder(for: occurrence)
        }
        #expect(Fixture.names(in: sandbox.root).isEmpty)
        sandbox.expectNothingWrittenOutsideRoot()
    }

    // MARK: - Finding

    @Test func findsAFolderRenamedOrMovedInFinder() async throws {
        let sandbox = try EventFoldersSandbox()
        defer { sandbox.remove() }
        let occurrence = Fixture.occurrence(of: Fixture.timed(1, "Physics Lecture", october: 6, at: 14), october: 6)
        let folder = try await sandbox.folders.ensureFolder(for: occurrence)
        try Fixture.write("notes", to: folder.appending(component: "notes.txt"))

        let renamed = sandbox.url("2026-10-06/Physics (my notes)")
        try FileManager.default.moveItem(at: folder, to: renamed)
        let found = await sandbox.folders.existingFolder(for: occurrence)
        let count = await sandbox.folders.fileCount(for: occurrence)
        let foundAfterRelaunch = await sandbox.reopened().existingFolder(for: occurrence)
        #expect(found?.path == renamed.path)
        #expect(count == 1)
        #expect(foundAfterRelaunch?.path == renamed.path)

        // Dragged into another day folder as well.
        try Fixture.makeDirectory(sandbox.url("2026-10-20"))
        let moved = sandbox.url("2026-10-20/Physics")
        try FileManager.default.moveItem(at: renamed, to: moved)
        let foundAgain = await sandbox.folders.existingFolder(for: occurrence)
        #expect(foundAgain?.path == moved.path)
        sandbox.expectNothingWrittenOutsideRoot()
    }

    @Test func findsMarkedFoldersCopiedFromAnotherMac() async throws {
        let sandbox = try EventFoldersSandbox()
        defer { sandbox.remove() }
        let lecture = Fixture.timed(1, "Physics Lecture", october: 6, at: 14)
        let copied = sandbox.url("2026-10-06/Physics from my old Mac")
        try Fixture.makeDirectory(copied)
        try Fixture.writeMarker(EventFolderMarker(eventID: lecture.id, date: Fixture.day(6)), in: copied)
        try Fixture.write("slides", to: copied.appending(component: "slides.pdf"))

        let found = await sandbox.folders.existingFolder(for: Fixture.occurrence(of: lecture, october: 6))
        #expect(found?.path == copied.path)

        // One that lands in a day folder other than its own after the index was built is found once the
        // folder watcher asks for a reindex.
        let lab = Fixture.timed(2, "Lab", october: 7, at: 9)
        let labOccurrence = Fixture.occurrence(of: lab, october: 7)
        let stray = sandbox.url("2026-10-06/Lab copy")
        try Fixture.makeDirectory(stray)
        try Fixture.writeMarker(EventFolderMarker(eventID: lab.id, date: Fixture.day(7)), in: stray)
        await sandbox.folders.reindex()
        let foundLab = await sandbox.folders.existingFolder(for: labOccurrence)
        #expect(foundLab?.path == stray.path)
        sandbox.expectNothingWrittenOutsideRoot()
    }

    @Test func adoptsAnUnmarkedFolderAtTheExpectedPath() async throws {
        let sandbox = try EventFoldersSandbox()
        defer { sandbox.remove() }
        let lecture = Fixture.timed(1, "Physics Lecture", october: 6, at: 14)
        let occurrence = Fixture.occurrence(of: lecture, october: 6)
        let made = sandbox.url("2026-10-06/14.00 Physics Lecture")
        try Fixture.makeDirectory(made)
        try Fixture.write("slides", to: made.appending(component: "slides.pdf"))

        let found = await sandbox.folders.existingFolder(for: occurrence)
        #expect(found?.path == made.path)
        let marker = try Fixture.marker(in: made)
        #expect(marker == EventFolderMarker(eventID: lecture.id, date: Fixture.day(6)))
        let count = await sandbox.folders.fileCount(for: occurrence)
        let ensured = try await sandbox.folders.ensureFolder(for: occurrence)
        #expect(count == 1)
        #expect(ensured.path == made.path)
        #expect(Fixture.names(in: sandbox.url("2026-10-06")) == ["14.00 Physics Lecture"])
        sandbox.expectNothingWrittenOutsideRoot()
    }

    @Test func anotherEventsFolderAtTheExpectedPathIsNotTaken() async throws {
        let sandbox = try EventFoldersSandbox()
        defer { sandbox.remove() }
        let first = Fixture.occurrence(of: Fixture.timed(1, "Physics Lecture", october: 6, at: 14), october: 6)
        let second = Fixture.occurrence(of: Fixture.timed(2, "Physics Lecture", october: 6, at: 14), october: 6)
        _ = try await sandbox.folders.ensureFolder(for: first)

        let found = await sandbox.folders.existingFolder(for: second)
        let count = await sandbox.folders.fileCount(for: second)
        #expect(found == nil)
        #expect(count == 0)
        sandbox.expectNothingWrittenOutsideRoot()
    }

    // MARK: - Listing

    @Test func filesListsVisibleItemsSortedLikeFinder() async throws {
        let sandbox = try EventFoldersSandbox()
        defer { sandbox.remove() }
        let occurrence = Fixture.occurrence(of: Fixture.timed(1, "Physics Lecture", october: 6, at: 14), october: 6)
        let folder = try await sandbox.folders.ensureFolder(for: occurrence)
        try Fixture.write("# Notes", to: folder.appending(component: "notes.md"))
        try Fixture.write("ten", to: folder.appending(component: "Lecture 10.pdf"))
        try Fixture.write("two", to: folder.appending(component: "Lecture 2.pdf"))
        try Fixture.write("finder", to: folder.appending(component: ".DS_Store"))
        try Fixture.write("hidden", to: folder.appending(component: ".hidden"))
        try Fixture.write("", to: folder.appending(component: "Icon\r"))
        let slides = folder.appending(component: "Slides", directoryHint: .isDirectory)
        try Fixture.makeDirectory(slides)
        try Fixture.write("12345", to: slides.appending(component: "week1.key"))
        try Fixture.write("123", to: slides.appending(component: "week2.key"))

        let files = await sandbox.folders.files(for: occurrence)
        let count = await sandbox.folders.fileCount(for: occurrence)
        #expect(files.map(\.name) == ["Lecture 2.pdf", "Lecture 10.pdf", "notes.md", "Slides"])
        #expect(count == 4)

        let notesFile = files.first { $0.name == "notes.md" }
        let notes = try #require(notesFile)
        #expect(notes.byteCount == 7)
        #expect(!notes.isDirectory)
        #expect(notes.modified != nil)
        #expect(notes.url.path == folder.appending(component: "notes.md").path)
        #expect(notes.id == notes.url)

        let slidesFile = files.first { $0.name == "Slides" }
        let slidesItem = try #require(slidesFile)
        #expect(slidesItem.isDirectory)
        #expect(slidesItem.byteCount == 8)
        sandbox.expectNothingWrittenOutsideRoot()
    }

    @Test func filesAlwaysShowWhatIsInTheFolderNow() async throws {
        let sandbox = try EventFoldersSandbox()
        defer { sandbox.remove() }
        let occurrence = Fixture.occurrence(of: Fixture.timed(1, "Physics Lecture", october: 6, at: 14), october: 6)
        let folder = try await sandbox.folders.ensureFolder(for: occurrence)
        try Fixture.write("one", to: folder.appending(component: "a.txt"))
        let before = await sandbox.folders.files(for: occurrence)

        // Edited in Finder: one file added, one removed.
        try Fixture.write("two", to: folder.appending(component: "b.txt"))
        try FileManager.default.removeItem(at: folder.appending(component: "a.txt"))
        let after = await sandbox.folders.files(for: occurrence)

        #expect(before.map(\.name) == ["a.txt"])
        #expect(after.map(\.name) == ["b.txt"])
        sandbox.expectNothingWrittenOutsideRoot()
    }

    // MARK: - Relocating

    @Test func relocateRenamesTheFolderAfterATitleChange() async throws {
        let sandbox = try EventFoldersSandbox()
        defer { sandbox.remove() }
        let lecture = Fixture.timed(1, "Physics Lecture", october: 6, at: 14)
        let before = Fixture.occurrence(of: lecture, october: 6)
        let folder = try await sandbox.folders.ensureFolder(for: before)
        try Fixture.write("notes", to: folder.appending(component: "notes.txt"))

        let after = Fixture.occurrence(of: Fixture.retitled(lecture, "Physics Seminar"), october: 6)
        let relocated = try await sandbox.folders.relocate(from: before, to: after)

        let expected = sandbox.url("2026-10-06/14.00 Physics Seminar")
        #expect(relocated?.path == expected.path)
        #expect(Fixture.names(in: sandbox.url("2026-10-06")) == ["14.00 Physics Seminar"])
        #expect(Fixture.exists(expected.appending(component: "notes.txt")))
        let marker = try Fixture.marker(in: expected)
        #expect(marker == EventFolderMarker(eventID: lecture.id, date: Fixture.day(6)))
        let found = await sandbox.folders.existingFolder(for: after)
        #expect(found?.path == expected.path)
        sandbox.expectNothingWrittenOutsideRoot()
    }

    @Test func relocateToAnotherDayMovesTheFolderAndRemovesTheEmptyDay() async throws {
        let sandbox = try EventFoldersSandbox()
        defer { sandbox.remove() }
        let lecture = Fixture.timed(1, "Physics Lecture", october: 6, at: 14)
        let before = Fixture.occurrence(of: lecture, october: 6)
        let folder = try await sandbox.folders.ensureFolder(for: before)
        try Fixture.write("notes", to: folder.appending(component: "notes.txt"))

        let after = Fixture.occurrence(of: Fixture.moved(lecture, october: 8, at: 10, 30), october: 8)
        let relocated = try await sandbox.folders.relocate(from: before, to: after)

        let expected = sandbox.url("2026-10-08/10.30 Physics Lecture")
        #expect(relocated?.path == expected.path)
        #expect(Fixture.names(in: sandbox.root) == ["2026-10-08"])
        #expect(Fixture.exists(expected.appending(component: "notes.txt")))
        let marker = try Fixture.marker(in: expected)
        #expect(marker == EventFolderMarker(eventID: lecture.id, date: Fixture.day(8)))
        let found = await sandbox.folders.existingFolder(for: after)
        let oldFound = await sandbox.folders.existingFolder(for: before)
        #expect(found?.path == expected.path)
        #expect(oldFound == nil)
        sandbox.expectNothingWrittenOutsideRoot()
    }

    @Test func relocateKeepsAnOldDayFolderThatStillHasSomethingInIt() async throws {
        let sandbox = try EventFoldersSandbox()
        defer { sandbox.remove() }
        // Another event's folder stays behind.
        let lecture = Fixture.timed(1, "Physics Lecture", october: 6, at: 14)
        let lab = Fixture.timed(2, "Lab", october: 6, at: 9)
        let lectureBefore = Fixture.occurrence(of: lecture, october: 6)
        _ = try await sandbox.folders.ensureFolder(for: lectureBefore)
        _ = try await sandbox.folders.ensureFolder(for: Fixture.occurrence(of: lab, october: 6))
        let lectureAfter = Fixture.occurrence(of: Fixture.moved(lecture, october: 8, at: 14), october: 8)
        _ = try await sandbox.folders.relocate(from: lectureBefore, to: lectureAfter)
        #expect(Fixture.names(in: sandbox.url("2026-10-06")) == ["09.00 Lab"])

        // A day folder with only Finder's .DS_Store in it isn't completely empty either.
        let seminar = Fixture.timed(3, "Seminar", october: 7, at: 11)
        let seminarBefore = Fixture.occurrence(of: seminar, october: 7)
        _ = try await sandbox.folders.ensureFolder(for: seminarBefore)
        try Fixture.write("finder", to: sandbox.url("2026-10-07/.DS_Store"))
        let seminarAfter = Fixture.occurrence(of: Fixture.moved(seminar, october: 9, at: 11), october: 9)
        _ = try await sandbox.folders.relocate(from: seminarBefore, to: seminarAfter)
        #expect(Fixture.names(in: sandbox.url("2026-10-07")) == [".DS_Store"])
        #expect(Fixture.names(in: sandbox.root) == ["2026-10-06", "2026-10-07", "2026-10-08", "2026-10-09"])
        sandbox.expectNothingWrittenOutsideRoot()
    }

    @Test func relocateAddsASuffixWhenTheNewNameIsTaken() async throws {
        let sandbox = try EventFoldersSandbox()
        defer { sandbox.remove() }
        let lab = Fixture.timed(1, "Lab", october: 6, at: 9)
        let seminar = Fixture.timed(2, "Seminar", october: 6, at: 11)
        let labOccurrence = Fixture.occurrence(of: lab, october: 6)
        let seminarBefore = Fixture.occurrence(of: seminar, october: 6)
        _ = try await sandbox.folders.ensureFolder(for: labOccurrence)
        _ = try await sandbox.folders.ensureFolder(for: seminarBefore)

        let seminarAsLab = Fixture.moved(Fixture.retitled(seminar, "Lab"), october: 6, at: 9)
        let seminarAfter = Fixture.occurrence(of: seminarAsLab, october: 6)
        let relocated = try await sandbox.folders.relocate(from: seminarBefore, to: seminarAfter)

        #expect(relocated?.lastPathComponent == "09.00 Lab 2")
        #expect(Fixture.names(in: sandbox.url("2026-10-06")) == ["09.00 Lab", "09.00 Lab 2"])
        let labMarker = try Fixture.marker(in: sandbox.url("2026-10-06/09.00 Lab"))
        let seminarMarker = try Fixture.marker(in: sandbox.url("2026-10-06/09.00 Lab 2"))
        #expect(labMarker.eventID == lab.id)
        #expect(seminarMarker.eventID == seminar.id)
        let labFound = await sandbox.folders.existingFolder(for: labOccurrence)
        let seminarFound = await sandbox.folders.existingFolder(for: seminarAfter)
        #expect(labFound?.lastPathComponent == "09.00 Lab")
        #expect(seminarFound?.lastPathComponent == "09.00 Lab 2")
        sandbox.expectNothingWrittenOutsideRoot()
    }

    @Test func relocateAvoidsAUserFolderThatHasTheNewName() async throws {
        let sandbox = try EventFoldersSandbox()
        defer { sandbox.remove() }
        let lecture = Fixture.timed(1, "Physics Lecture", october: 6, at: 14)
        let before = Fixture.occurrence(of: lecture, october: 6)
        let folder = try await sandbox.folders.ensureFolder(for: before)
        try Fixture.write("notes", to: folder.appending(component: "notes.txt"))
        let users = sandbox.url("2026-10-08/10.30 Physics Lecture")
        try Fixture.makeDirectory(users)
        try Fixture.write("mine", to: users.appending(component: "mine.txt"))

        let after = Fixture.occurrence(of: Fixture.moved(lecture, october: 8, at: 10, 30), october: 8)
        let relocated = try await sandbox.folders.relocate(from: before, to: after)

        #expect(relocated?.lastPathComponent == "10.30 Physics Lecture 2")
        let found = await sandbox.folders.existingFolder(for: after)
        let files = await sandbox.folders.files(for: after)
        #expect(found?.lastPathComponent == "10.30 Physics Lecture 2")
        #expect(files.map(\.name) == ["notes.txt"])
        #expect(Fixture.names(in: users) == ["mine.txt"])
        sandbox.expectNothingWrittenOutsideRoot()
    }

    @Test func relocateCanChangeOnlyTheCaseOfATitle() async throws {
        let sandbox = try EventFoldersSandbox()
        defer { sandbox.remove() }
        let lecture = Fixture.timed(1, "physics lecture", october: 6, at: 14)
        let before = Fixture.occurrence(of: lecture, october: 6)
        let folder = try await sandbox.folders.ensureFolder(for: before)
        try Fixture.write("notes", to: folder.appending(component: "notes.txt"))

        let after = Fixture.occurrence(of: Fixture.retitled(lecture, "Physics Lecture"), october: 6)
        let relocated = try await sandbox.folders.relocate(from: before, to: after)

        #expect(relocated?.lastPathComponent == "14.00 Physics Lecture")
        #expect(Fixture.names(in: sandbox.url("2026-10-06")) == ["14.00 Physics Lecture"])
        #expect(Fixture.names(in: sandbox.url("2026-10-06/14.00 Physics Lecture")) == [".ithil-event", "notes.txt"])
        sandbox.expectNothingWrittenOutsideRoot()
    }

    @Test func relocateRewritesTheMarkerForADetachedOccurrence() async throws {
        let sandbox = try EventFoldersSandbox()
        defer { sandbox.remove() }
        let weekly = RecurrenceRule(frequency: .weekly)
        let series = Fixture.timed(1, "Physics Lecture", october: 6, at: 14, recurrence: weekly)
        let seriesOccurrence = Fixture.occurrence(of: series, october: 13)
        _ = try await sandbox.folders.ensureFolder(for: seriesOccurrence)

        // "This event only": the 13 October lecture moves to 15:00 as an event of its own.
        let detached = Event(
            id: Fixture.id(2),
            title: "Physics Lecture",
            timing: Fixture.timing(october: 13, at: 15, 0),
            detachedFrom: SeriesOccurrence(seriesID: series.id, date: Fixture.day(13)),
            createdAt: Fixture.created)
        let detachedOccurrence = Fixture.occurrence(of: detached, october: 13)
        let relocated = try await sandbox.folders.relocate(from: seriesOccurrence, to: detachedOccurrence)

        let expected = sandbox.url("2026-10-13/15.00 Physics Lecture")
        #expect(relocated?.path == expected.path)
        let marker = try Fixture.marker(in: expected)
        #expect(marker == EventFolderMarker(eventID: detached.id, date: Fixture.day(13)))
        let found = await sandbox.folders.existingFolder(for: detachedOccurrence)
        let seriesFound = await sandbox.folders.existingFolder(for: seriesOccurrence)
        #expect(found?.path == expected.path)
        #expect(seriesFound == nil)
        sandbox.expectNothingWrittenOutsideRoot()
    }

    @Test func relocateKeepsAFinderRenameWhenThePathDidNotChange() async throws {
        let sandbox = try EventFoldersSandbox()
        defer { sandbox.remove() }
        let lecture = Fixture.timed(1, "Physics Lecture", october: 6, at: 14)
        let before = Fixture.occurrence(of: lecture, october: 6)
        let folder = try await sandbox.folders.ensureFolder(for: before)
        let renamed = sandbox.url("2026-10-06/Physics (my notes)")
        try FileManager.default.moveItem(at: folder, to: renamed)

        var edited = lecture
        edited.notes = "Bring a calculator"
        let after = Fixture.occurrence(of: edited, october: 6)
        let relocated = try await sandbox.folders.relocate(from: before, to: after)
        #expect(relocated?.path == renamed.path)
        #expect(Fixture.names(in: sandbox.url("2026-10-06")) == ["Physics (my notes)"])
        sandbox.expectNothingWrittenOutsideRoot()
    }

    @Test func aFailedRelocationMovesNothing() async throws {
        let sandbox = try EventFoldersSandbox()
        defer { sandbox.remove() }
        let lecture = Fixture.timed(1, "Physics Lecture", october: 6, at: 14)
        let before = Fixture.occurrence(of: lecture, october: 6)
        let folder = try await sandbox.folders.ensureFolder(for: before)
        sandbox.disk.makeWritesFail()

        let after = Fixture.occurrence(of: Fixture.moved(lecture, october: 8, at: 14), october: 8)
        await #expect(throws: (any Error).self) {
            _ = try await sandbox.folders.relocate(from: before, to: after)
        }
        #expect(Fixture.names(in: sandbox.root) == ["2026-10-06"])
        let marker = try Fixture.marker(in: folder)
        let found = await sandbox.folders.existingFolder(for: before)
        #expect(marker == EventFolderMarker(eventID: lecture.id, date: Fixture.day(6)))
        #expect(found?.path == folder.path)
        sandbox.expectNothingWrittenOutsideRoot()
    }

    // MARK: - Trashing

    @Test func trashFolderMovesTheFolderToTheTrash() async throws {
        let sandbox = try EventFoldersSandbox()
        defer { sandbox.remove() }
        let occurrence = Fixture.occurrence(of: Fixture.timed(1, "Physics Lecture", october: 6, at: 14), october: 6)
        let folder = try await sandbox.folders.ensureFolder(for: occurrence)
        try Fixture.write("draft", to: folder.appending(component: "essay.txt"))

        try await sandbox.folders.trashFolder(for: occurrence)

        #expect(!Fixture.exists(folder))
        #expect(Fixture.names(in: sandbox.root).isEmpty)
        #expect(sandbox.disk.trashed.map(\.path) == [folder.path])
        #expect(sandbox.disk.itemsInTrash.count == 1)
        let found = await sandbox.folders.existingFolder(for: occurrence)
        #expect(found == nil)
        sandbox.expectNothingWrittenOutsideRoot()
    }

    @Test func trashFolderKeepsTheDayFolderWhenOtherItemsAreLeft() async throws {
        let sandbox = try EventFoldersSandbox()
        defer { sandbox.remove() }
        let lecture = Fixture.occurrence(of: Fixture.timed(1, "Physics Lecture", october: 6, at: 14), october: 6)
        let lab = Fixture.occurrence(of: Fixture.timed(2, "Lab", october: 6, at: 9), october: 6)
        _ = try await sandbox.folders.ensureFolder(for: lecture)
        _ = try await sandbox.folders.ensureFolder(for: lab)

        try await sandbox.folders.trashFolder(for: lecture)

        #expect(Fixture.names(in: sandbox.url("2026-10-06")) == ["09.00 Lab"])
        let labFound = await sandbox.folders.existingFolder(for: lab)
        #expect(labFound != nil)
        sandbox.expectNothingWrittenOutsideRoot()
    }

    // MARK: - Staying inside the root

    @Test func containsRejectsPathsThatClimbOutOfTheRoot() throws {
        let sandbox = try EventFoldersSandbox()
        defer { sandbox.remove() }
        let folders = sandbox.folders

        #expect(folders.contains(sandbox.root))
        #expect(folders.contains(sandbox.url("2026-10-06/14.00 Lab/notes.txt")))
        #expect(folders.contains(sandbox.url("2026-10-06/../2026-10-07")))
        #expect(!folders.contains(sandbox.url("..")))
        #expect(!folders.contains(sandbox.url("../Outside")))
        #expect(!folders.contains(sandbox.url("2026-10-06/../../Outside/notes.txt")))
        #expect(!folders.contains(sandbox.base.appending(component: "CalendarDocument 2")))
        #expect(!folders.contains(sandbox.base.appending(component: "Library2")))
        #expect(!folders.contains(URL(string: "https://example.com/CalendarDocument")!))
    }

    @Test func containsResolvesSymbolicLinks() throws {
        let sandbox = try EventFoldersSandbox()
        defer { sandbox.remove() }
        let folders = sandbox.folders
        let escape = sandbox.url("escape")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: sandbox.outside)
        let relativeEscape = sandbox.url("2026-10-06")
        try FileManager.default.createSymbolicLink(atPath: relativeEscape.path, withDestinationPath: "../Outside")
        let inner = sandbox.url("Inner")
        try Fixture.makeDirectory(inner)
        let alias = sandbox.url("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: inner)

        #expect(!folders.contains(escape))
        #expect(!folders.contains(escape.appending(component: "notes.txt")))
        #expect(!folders.contains(relativeEscape.appending(component: "14.00 Lab")))
        #expect(folders.contains(alias.appending(component: "14.00 Lab")))
    }

    @Test func neverWritesThroughADayFolderThatLinksOutside() async throws {
        let sandbox = try EventFoldersSandbox()
        defer { sandbox.remove() }
        try FileManager.default.createSymbolicLink(at: sandbox.url("2026-10-06"), withDestinationURL: sandbox.outside)
        let lecture = Fixture.occurrence(of: Fixture.timed(1, "Physics Lecture", october: 6, at: 14), october: 6)

        let ensureError = await Fixture.folderError {
            _ = try await sandbox.folders.ensureFolder(for: lecture)
        }
        #expect(Fixture.isOutsideRoot(ensureError))

        // Moving another event's folder onto that day is refused as well; the folder stays where it was.
        let lab = Fixture.timed(2, "Lab", october: 7, at: 9)
        let labBefore = Fixture.occurrence(of: lab, october: 7)
        let labFolder = try await sandbox.folders.ensureFolder(for: labBefore)
        let labAfter = Fixture.occurrence(of: Fixture.moved(lab, october: 6, at: 9), october: 6)
        let relocateError = await Fixture.folderError {
            _ = try await sandbox.folders.relocate(from: labBefore, to: labAfter)
        }
        #expect(Fixture.isOutsideRoot(relocateError))
        #expect(Fixture.exists(labFolder))
        let labMarker = try Fixture.marker(in: labFolder)
        #expect(labMarker == EventFolderMarker(eventID: lab.id, date: Fixture.day(7)))
        sandbox.expectNothingWrittenOutsideRoot()
    }

    @Test func aLinkInPlaceOfAnEventFolderIsNotFollowed() async throws {
        let sandbox = try EventFoldersSandbox()
        defer { sandbox.remove() }
        try Fixture.makeDirectory(sandbox.url("2026-10-06"))
        let link = sandbox.url("2026-10-06/14.00 Physics Lecture")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sandbox.outside)
        let lecture = Fixture.occurrence(of: Fixture.timed(1, "Physics Lecture", october: 6, at: 14), october: 6)

        let found = await sandbox.folders.existingFolder(for: lecture)
        let folder = try await sandbox.folders.ensureFolder(for: lecture)
        #expect(found == nil)
        #expect(folder.path == sandbox.url("2026-10-06/14.00 Physics Lecture 2").path)
        sandbox.expectNothingWrittenOutsideRoot()
    }
}
