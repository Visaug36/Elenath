import ElenathCore
import Foundation
import Testing

/// What a test disk did: where it wrote, what it removed, and where trashed items went.
private final class RestoreDiskLog: @unchecked Sendable {
    private let testTrash: TestTrash
    private let lock = NSLock()
    private var writtenURLs: [URL] = []
    private var removedURLs: [URL] = []
    private var trashedSources: [URL] = []
    private var itemsInTrashURLs: [URL] = []

    /// Every URL created, written, copied to or moved to.
    var written: [URL] { locked { writtenURLs } }
    var removed: [URL] { locked { removedURLs } }
    /// The items that were moved to the Trash, where they were.
    var trashed: [URL] { locked { trashedSources } }
    /// Where trashed items ended up.
    var itemsInTrash: [URL] { locked { itemsInTrashURLs } }

    init(trash: TestTrash) {
        testTrash = trash
    }

    func wrote(_ url: URL) {
        locked { writtenURLs.append(url) }
    }

    func removedItem(_ url: URL) {
        locked { removedURLs.append(url) }
    }

    func trashedItem(_ url: URL, to item: URL?) {
        locked {
            trashedSources.append(url)
            if let item {
                itemsInTrashURLs.append(item)
            }
        }
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Moves `url` to the test's own Trash and records where it went.
    func trash(_ url: URL) throws -> URL? {
        let item = try testTrash.trash(url)
        trashedItem(url, to: item)
        return item
    }
}

/// The real disk, recording every change, and telling where trashed items went (in a `TestTrash`).
private final class RestoreTestDisk: FileSystem, @unchecked Sendable {
    let log: RestoreDiskLog
    private let base = LocalFileSystem()

    init(trash: TestTrash) {
        log = RestoreDiskLog(trash: trash)
    }

    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    func isDirectory(at url: URL) -> Bool { base.isDirectory(at: url) }
    func contentsOfDirectory(at url: URL) throws -> [URL] { try base.contentsOfDirectory(at: url) }
    func readData(at url: URL) throws -> Data { try base.readData(at: url) }
    func modificationDate(at url: URL) -> Date? { base.modificationDate(at: url) }
    func info(at url: URL) -> FileInfo? { base.info(at: url) }

    func createDirectory(at url: URL) throws {
        log.wrote(url)
        try base.createDirectory(at: url)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        log.wrote(url)
        try base.writeAtomically(data, to: url)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        log.wrote(destination)
        try base.copyItem(at: source, to: destination)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        log.wrote(destination)
        try base.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        log.removedItem(url)
        try base.removeItem(at: url)
    }

    func trashItem(at url: URL) throws {
        _ = try log.trash(url)
    }

    func trashItemReturningURL(at url: URL) throws -> URL? {
        try log.trash(url)
    }
}

/// A file system that only offers `trashItem(at:)`, so `trashItemReturningURL(at:)` is the protocol's
/// default.
private final class TrashOnlyDisk: FileSystem, @unchecked Sendable {
    let log: RestoreDiskLog
    private let base = LocalFileSystem()

    init(trash: TestTrash) {
        log = RestoreDiskLog(trash: trash)
    }

    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    func isDirectory(at url: URL) -> Bool { base.isDirectory(at: url) }
    func contentsOfDirectory(at url: URL) throws -> [URL] { try base.contentsOfDirectory(at: url) }
    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
    func readData(at url: URL) throws -> Data { try base.readData(at: url) }
    func writeAtomically(_ data: Data, to url: URL) throws { try base.writeAtomically(data, to: url) }
    func copyItem(at source: URL, to destination: URL) throws { try base.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) throws { try base.moveItem(at: source, to: destination) }
    func removeItem(at url: URL) throws { try base.removeItem(at: url) }
    func modificationDate(at url: URL) -> Date? { base.modificationDate(at: url) }
    func info(at url: URL) -> FileInfo? { base.info(at: url) }

    func trashItem(at url: URL) throws {
        _ = try log.trash(url)
    }
}

/// A unique temporary folder holding the library root ("CalendarDocument") and a sibling ("Outside") that must stay
/// untouched, plus the `EventFolders` under test.
private struct RestoreSandbox {
    let base: URL
    let root: URL
    let outside: URL
    let disk: RestoreTestDisk
    let folders: EventFolders

    init() throws {
        let name = "IthilEventFoldersRestoreTests-\(UUID().uuidString)"
        base = FileManager.default.temporaryDirectory.appending(component: name, directoryHint: .isDirectory)
        root = base.appending(component: "CalendarDocument", directoryHint: .isDirectory)
        outside = base.appending(component: "Outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true, attributes: nil)
        disk = RestoreTestDisk(trash: TestTrash(in: base))
        folders = EventFolders(root: root, fileSystem: disk)
    }

    /// The test's own Trash, inside the temporary folder.
    var trash: TestTrash { TestTrash(in: base) }

    /// Deletes the temporary folder, Trash included.
    func remove() {
        try? FileManager.default.removeItem(at: base)
    }

    /// A location inside the root, such as "2026-10-06/14.00 Physics Lecture". Nothing is created.
    func url(_ relativePath: String) -> URL {
        root.appending(path: relativePath)
    }

    /// Makes the occurrence's folder with one file in it, and returns the folder.
    func folderWithFile(for occurrence: Occurrence, named name: String = "notes.txt") async throws -> URL {
        let folder = try await folders.ensureFolder(for: occurrence)
        try Data("Kepler".utf8).write(to: folder.appending(component: name, directoryHint: .notDirectory))
        return folder
    }

    /// Checks that every change landed strictly inside the root, that nothing was removed permanently and
    /// that the folder next to the root is still empty.
    func expectNothingWrittenOutsideRoot() {
        let rootComponents = root.standardizedFileURL.pathComponents
        let outsideRoot = disk.log.written.filter { url in
            let components = url.standardizedFileURL.pathComponents
            return components.count <= rootComponents.count || !components.starts(with: rootComponents)
        }
        #expect(outsideRoot.isEmpty)
        #expect(disk.log.removed.isEmpty)
        #expect(RestoreFixture.names(in: outside).isEmpty)
    }
}

/// Fixed IDs and events in Amsterdam (October 2026), and file helpers.
private enum RestoreFixture {
    static let amsterdam = TimeZone(identifier: "Europe/Amsterdam")!
    static let created = Date(timeIntervalSince1970: 1_788_220_800)
    static let expander = OccurrenceExpander(displayTimeZone: amsterdam)

    static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "4954484C-F01E-4000-8000-%012d", number))!
    }

    static func day(_ dayOfOctober: Int) -> CalendarDate {
        CalendarDate(year: 2026, month: 10, day: dayOfOctober)
    }

    static func timed(_ number: Int, _ title: String, october dayOfOctober: Int, at hour: Int) -> Event {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = amsterdam
        let parts = DateComponents(year: 2026, month: 10, day: dayOfOctober, hour: hour)
        let start = calendar.date(from: parts)!
        let timing = EventTiming.timed(start: start, end: start.addingTimeInterval(90 * 60), timeZone: amsterdam)
        return Event(id: id(number), title: title, timing: timing, createdAt: created)
    }

    static func occurrence(of event: Event, october dayOfOctober: Int) -> Occurrence {
        expander.occurrence(of: event, on: day(dayOfOctober))!
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

    /// The `CocoaError` code that `body` throws, or nil when it throws nothing (or another error).
    static func cocoaCode(from body: () async throws -> Void) async -> CocoaError.Code? {
        do {
            try await body()
            return nil
        } catch {
            return (error as? CocoaError)?.code
        }
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
}

struct EventFoldersRestoreTests {
    private typealias Fixture = RestoreFixture

    // MARK: - Trashing

    @Test func trashFolderSaysWhereTheFolderIsInTheTrash() async throws {
        let sandbox = try RestoreSandbox()
        defer { sandbox.remove() }
        let lecture = Fixture.timed(1, "Physics Lecture", october: 6, at: 14)
        let occurrence = Fixture.occurrence(of: lecture, october: 6)
        let folder = try await sandbox.folderWithFile(for: occurrence)

        let trashedFolder = try await sandbox.folders.trashFolder(for: occurrence)
        let trashed = try #require(trashedFolder)
        #expect(!Fixture.exists(folder))
        #expect(Fixture.exists(trashed))
        let marker = try Fixture.marker(in: trashed)
        #expect(Fixture.names(in: trashed) == [".ithil-event", "notes.txt"])
        #expect(marker == EventFolderMarker(eventID: lecture.id, date: Fixture.day(6)))
        #expect(sandbox.disk.log.trashed.map(\.path) == [folder.path])
        sandbox.expectNothingWrittenOutsideRoot()
    }

    @Test func trashFolderReturnsNilWithoutAFolder() async throws {
        let sandbox = try RestoreSandbox()
        defer { sandbox.remove() }
        let lecture = Fixture.timed(1, "Physics Lecture", october: 6, at: 14)

        let trashed = try await sandbox.folders.trashFolder(for: Fixture.occurrence(of: lecture, october: 6))
        #expect(trashed == nil)
        #expect(sandbox.disk.log.trashed.isEmpty)
    }

    @Test func fileSystemsThatCannotTellStillTrashTheFolder() async throws {
        let sandbox = try RestoreSandbox()
        defer { sandbox.remove() }
        let disk = TrashOnlyDisk(trash: sandbox.trash)
        let folders = EventFolders(root: sandbox.root, fileSystem: disk)
        let lecture = Fixture.timed(1, "Physics Lecture", october: 6, at: 14)
        let occurrence = Fixture.occurrence(of: lecture, october: 6)
        let folder = try await folders.ensureFolder(for: occurrence)

        let trashed = try await folders.trashFolder(for: occurrence)
        #expect(trashed == nil)
        #expect(!Fixture.exists(folder))
        #expect(disk.log.trashed.map(\.path) == [folder.path])
        #expect(disk.log.itemsInTrash.count == 1)
    }

    // Only macOS has a Trash that Foundation can say anything about.
    #if canImport(Darwin)
        @Test func localFileSystemSaysWhereTheTrashedItemWent() throws {
            let sandbox = try RestoreSandbox()
            defer { sandbox.remove() }
            // The real Trash, so a name no other test uses.
            let file = sandbox.url("Syllabus \(UUID().uuidString).pdf")
            try Data("Week 1".utf8).write(to: file)

            let trashedItem = try LocalFileSystem().trashItemReturningURL(at: file)
            let trashed = try #require(trashedItem)
            defer { try? FileManager.default.removeItem(at: trashed) }
            let contents = try Data(contentsOf: trashed)
            #expect(!Fixture.exists(file))
            #expect(contents == Data("Week 1".utf8))
        }
    #endif

    // MARK: - Putting back

    @Test func restoreFolderPutsTheFolderBackWithItsFiles() async throws {
        let sandbox = try RestoreSandbox()
        defer { sandbox.remove() }
        let lecture = Fixture.timed(1, "Physics Lecture", october: 6, at: 14)
        let occurrence = Fixture.occurrence(of: lecture, october: 6)
        let folder = try await sandbox.folderWithFile(for: occurrence)
        let trashedFolder = try await sandbox.folders.trashFolder(for: occurrence)
        let trashed = try #require(trashedFolder)
        // The day folder was left empty, so it went too.
        #expect(Fixture.names(in: sandbox.root).isEmpty)

        let restored = try await sandbox.folders.restoreFolder(from: trashed, for: occurrence)
        #expect(restored.path == folder.path)
        #expect(!Fixture.exists(trashed))
        let marker = try Fixture.marker(in: restored)
        #expect(Fixture.names(in: restored) == [".ithil-event", "notes.txt"])
        #expect(marker == EventFolderMarker(eventID: lecture.id, date: Fixture.day(6)))
        let found = await sandbox.folders.existingFolder(for: occurrence)
        let count = await sandbox.folders.fileCount(for: occurrence)
        #expect(found?.path == folder.path)
        #expect(count == 1)
        sandbox.expectNothingWrittenOutsideRoot()
    }

    @Test func restoreFolderUsesTheOccurrencesCurrentName() async throws {
        let sandbox = try RestoreSandbox()
        defer { sandbox.remove() }
        let lecture = Fixture.timed(1, "Physics Lecture", october: 6, at: 14)
        let occurrence = Fixture.occurrence(of: lecture, october: 6)
        _ = try await sandbox.folderWithFile(for: occurrence)
        let trashedFolder = try await sandbox.folders.trashFolder(for: occurrence)
        let trashed = try #require(trashedFolder)
        var renamed = lecture
        renamed.title = "Mechanics"

        let restored = try await sandbox.folders.restoreFolder(
            from: trashed, for: Fixture.occurrence(of: renamed, october: 6))
        #expect(restored.path == sandbox.url("2026-10-06/14.00 Mechanics").path)
        #expect(Fixture.names(in: restored) == [".ithil-event", "notes.txt"])
        sandbox.expectNothingWrittenOutsideRoot()
    }

    @Test func restoreFolderAddsASuffixWhenTheNameIsTaken() async throws {
        let sandbox = try RestoreSandbox()
        defer { sandbox.remove() }
        let lecture = Fixture.timed(1, "Physics Lecture", october: 6, at: 14)
        let twin = Fixture.timed(2, "Physics Lecture", october: 6, at: 14)
        let occurrence = Fixture.occurrence(of: lecture, october: 6)
        _ = try await sandbox.folderWithFile(for: occurrence)
        let trashedFolder = try await sandbox.folders.trashFolder(for: occurrence)
        let trashed = try #require(trashedFolder)
        let twinFolder = try await sandbox.folders.ensureFolder(for: Fixture.occurrence(of: twin, october: 6))
        #expect(twinFolder.path == sandbox.url("2026-10-06/14.00 Physics Lecture").path)

        let restored = try await sandbox.folders.restoreFolder(from: trashed, for: occurrence)
        #expect(restored.path == sandbox.url("2026-10-06/14.00 Physics Lecture 2").path)
        #expect(Fixture.names(in: restored) == [".ithil-event", "notes.txt"])
        #expect(Fixture.names(in: twinFolder) == [".ithil-event"])
        let found = await sandbox.folders.existingFolder(for: occurrence)
        #expect(found?.path == restored.path)
        sandbox.expectNothingWrittenOutsideRoot()
    }

    @Test func restoreFolderLeavesAFolderTheUserMadeMeanwhileAlone() async throws {
        let sandbox = try RestoreSandbox()
        defer { sandbox.remove() }
        let lecture = Fixture.timed(1, "Physics Lecture", october: 6, at: 14)
        let occurrence = Fixture.occurrence(of: lecture, october: 6)
        _ = try await sandbox.folderWithFile(for: occurrence)
        let trashedFolder = try await sandbox.folders.trashFolder(for: occurrence)
        let trashed = try #require(trashedFolder)
        let usersFolder = sandbox.url("2026-10-06/14.00 Physics Lecture")
        try FileManager.default.createDirectory(at: usersFolder, withIntermediateDirectories: true, attributes: nil)

        let restored = try await sandbox.folders.restoreFolder(from: trashed, for: occurrence)
        #expect(restored.path == sandbox.url("2026-10-06/14.00 Physics Lecture 2").path)
        #expect(Fixture.names(in: usersFolder).isEmpty)
        sandbox.expectNothingWrittenOutsideRoot()
    }

    @Test func restoreFolderRefusesTheFolderOfAnotherOccurrence() async throws {
        let sandbox = try RestoreSandbox()
        defer { sandbox.remove() }
        let lecture = Fixture.timed(1, "Physics Lecture", october: 6, at: 14)
        let seminar = Fixture.timed(2, "Seminar", october: 7, at: 10)
        let occurrence = Fixture.occurrence(of: lecture, october: 6)
        _ = try await sandbox.folderWithFile(for: occurrence)
        let trashedFolder = try await sandbox.folders.trashFolder(for: occurrence)
        let trashed = try #require(trashedFolder)

        let code = await Fixture.cocoaCode {
            _ = try await sandbox.folders.restoreFolder(from: trashed, for: Fixture.occurrence(of: seminar, october: 7))
        }
        #expect(code == .fileNoSuchFile)
        #expect(Fixture.names(in: trashed) == [".ithil-event", "notes.txt"])
        #expect(Fixture.names(in: sandbox.root).isEmpty)
    }

    @Test func restoreFolderRefusesWhatIsNoLongerInTheTrash() async throws {
        let sandbox = try RestoreSandbox()
        defer { sandbox.remove() }
        let lecture = Fixture.timed(1, "Physics Lecture", october: 6, at: 14)
        let occurrence = Fixture.occurrence(of: lecture, october: 6)
        _ = try await sandbox.folders.ensureFolder(for: occurrence)
        let trashedFolder = try await sandbox.folders.trashFolder(for: occurrence)
        let trashed = try #require(trashedFolder)
        try FileManager.default.removeItem(at: trashed)

        let code = await Fixture.cocoaCode {
            _ = try await sandbox.folders.restoreFolder(from: trashed, for: occurrence)
        }
        #expect(code == .fileNoSuchFile)
        #expect(Fixture.names(in: sandbox.root).isEmpty)
    }

    @Test func restoreFolderRefusesAFileOrALinkInsteadOfAFolder() async throws {
        let sandbox = try RestoreSandbox()
        defer { sandbox.remove() }
        let lecture = Fixture.timed(1, "Physics Lecture", october: 6, at: 14)
        let occurrence = Fixture.occurrence(of: lecture, october: 6)
        let file = sandbox.outside.appending(component: "14.00 Physics Lecture", directoryHint: .notDirectory)
        try Data("not a folder".utf8).write(to: file)
        let link = sandbox.base.appending(component: "Link", directoryHint: .isDirectory)
        let folder = try await sandbox.folders.ensureFolder(for: occurrence)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)

        let fileCode = await Fixture.cocoaCode {
            _ = try await sandbox.folders.restoreFolder(from: file, for: occurrence)
        }
        let linkCode = await Fixture.cocoaCode {
            _ = try await sandbox.folders.restoreFolder(from: link, for: occurrence)
        }
        #expect(fileCode == .fileNoSuchFile)
        #expect(linkCode == .fileNoSuchFile)
        #expect(Fixture.exists(file))
        #expect(Fixture.names(in: sandbox.url("2026-10-06")) == ["14.00 Physics Lecture"])
    }

    @Test func restoreFolderRefusesWhenTheOccurrenceHasAFolderAgain() async throws {
        let sandbox = try RestoreSandbox()
        defer { sandbox.remove() }
        let lecture = Fixture.timed(1, "Physics Lecture", october: 6, at: 14)
        let occurrence = Fixture.occurrence(of: lecture, october: 6)
        _ = try await sandbox.folderWithFile(for: occurrence)
        let trashedFolder = try await sandbox.folders.trashFolder(for: occurrence)
        let trashed = try #require(trashedFolder)
        let fresh = try await sandbox.folders.ensureFolder(for: occurrence)

        let code = await Fixture.cocoaCode {
            _ = try await sandbox.folders.restoreFolder(from: trashed, for: occurrence)
        }
        #expect(code == .fileWriteFileExists)
        #expect(Fixture.names(in: trashed) == [".ithil-event", "notes.txt"])
        #expect(Fixture.names(in: sandbox.url("2026-10-06")) == [fresh.lastPathComponent])
    }

    @Test func restoreFolderNeverWritesThroughALinkOutOfTheRoot() async throws {
        let sandbox = try RestoreSandbox()
        defer { sandbox.remove() }
        let lecture = Fixture.timed(1, "Physics Lecture", october: 6, at: 14)
        let occurrence = Fixture.occurrence(of: lecture, october: 6)
        _ = try await sandbox.folderWithFile(for: occurrence)
        let trashedFolder = try await sandbox.folders.trashFolder(for: occurrence)
        let trashed = try #require(trashedFolder)
        try FileManager.default.createSymbolicLink(at: sandbox.url("2026-10-06"), withDestinationURL: sandbox.outside)

        let error = await Fixture.folderError {
            _ = try await sandbox.folders.restoreFolder(from: trashed, for: occurrence)
        }
        #expect(error == .outsideRoot(sandbox.url("2026-10-06").path))
        #expect(Fixture.names(in: trashed) == [".ithil-event", "notes.txt"])
        sandbox.expectNothingWrittenOutsideRoot()
    }

    @Test func restoreFolderNeverRecreatesAMissingRoot() async throws {
        let sandbox = try RestoreSandbox()
        defer { sandbox.remove() }
        let lecture = Fixture.timed(1, "Physics Lecture", october: 6, at: 14)
        let occurrence = Fixture.occurrence(of: lecture, october: 6)
        _ = try await sandbox.folderWithFile(for: occurrence)
        let trashedFolder = try await sandbox.folders.trashFolder(for: occurrence)
        let trashed = try #require(trashedFolder)
        let moved = sandbox.base.appending(component: "CalendarDocument moved", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: sandbox.root, to: moved)

        let error = await Fixture.folderError {
            _ = try await sandbox.folders.restoreFolder(from: trashed, for: occurrence)
        }
        #expect(error == .notADirectory(sandbox.root.path))
        #expect(!Fixture.exists(sandbox.root))
        #expect(Fixture.names(in: trashed) == [".ithil-event", "notes.txt"])
    }
}
