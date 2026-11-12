import ElenathCore
import Foundation

/// Note ids that count up, so tests can say which one a note got.
final class IDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 1

    func make() -> NoteID {
        lock.lock()
        defer { lock.unlock() }
        let id = IDSequence.id(next)
        next += 1
        return id
    }

    static func id(_ number: Int) -> NoteID {
        NoteID(UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number))!)
    }
}

/// A new library in a temporary folder, with a catalog and a note store over it. Its clock stands at
/// 2026-11-10 14:30 UTC and its time zone is UTC. Call `remove()` when done.
struct LibraryFixture {
    static let timeZone = TimeZone(secondsFromGMT: 0)!
    static let start = Date(timeIntervalSince1970: 1_794_321_000)

    let folder: TempFolder
    let root: URL
    let safety: URL
    let indexDirectory: URL
    let clock = TestClock(LibraryFixture.start)
    let fileSystem: TrashingFileSystem
    let catalog: LibraryCatalog
    let notes: NoteStore
    let ids = IDSequence()

    init() async throws {
        folder = try TempFolder()
        root = try folder.makeDirectory("Elenath")
        safety = folder.child("Safety")
        indexDirectory = folder.child("Index")
        fileSystem = TrashingFileSystem(trashIn: folder.url)
        catalog = LibraryCatalog(root: root, safetyDirectory: safety, fileSystem: fileSystem, timeSource: clock)
        _ = try await catalog.create()
        let ids = ids
        notes = NoteStore(
            catalog: catalog, fileSystem: fileSystem, timeSource: clock, timeZone: { LibraryFixture.timeZone },
            makeID: { ids.make() })
    }

    func remove() {
        folder.remove()
    }

    func space(_ name: String, sealed: Bool = false, keywords: [String] = []) async throws -> Space {
        try await catalog.createSpace(named: name, sealed: sealed, keywords: keywords)
    }

    /// A note in a space, by its path inside the space.
    func ref(_ space: Space, _ path: String) -> NoteRef {
        NoteRef(container: .space(space.id), path: ItemPath(path)!)
    }

    func inbox(_ path: String) -> NoteRef {
        NoteRef(container: .inbox, path: ItemPath(path)!)
    }

    /// The URL of a path from the library folder, such as "Uni/Physics/Lecture 7.md".
    func url(_ path: String) -> URL {
        root.appending(path: path, directoryHint: .notDirectory)
    }

    /// Writes a file as another app would: straight to disk, parents created.
    func write(_ text: String, to path: String) throws {
        let url = url(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String) throws -> String {
        String(decoding: try Data(contentsOf: url(path)), as: UTF8.self)
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url(path).path)
    }

    /// The visible names in a folder given by its path from the library folder.
    func names(in path: String) -> [String] {
        TestFiles.names(in: root.appending(path: path, directoryHint: .isDirectory))
            .filter { !$0.hasPrefix(".") }.sorted()
    }
}

/// A real file system whose atomic writes stop halfway under one folder: a temporary file with half the
/// bytes is left behind and the rename never happens, as when the power goes or the disk fills up.
struct InterruptedWriteFileSystem: FileSystem {
    var interruptingUnder: URL
    let base = LocalFileSystem()

    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    func isDirectory(at url: URL) -> Bool { base.isDirectory(at: url) }
    func contentsOfDirectory(at url: URL) throws -> [URL] { try base.contentsOfDirectory(at: url) }
    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
    func readData(at url: URL) throws -> Data { try base.readData(at: url) }

    func writeAtomically(_ data: Data, to url: URL) throws {
        let folder = interruptingUnder.path
        guard url.path == folder || url.path.hasPrefix(folder + "/") else {
            try base.writeAtomically(data, to: url)
            return
        }
        let partial = url.deletingLastPathComponent().appending(
            component: ".\(url.lastPathComponent).partial-\(UUID().uuidString)", directoryHint: .notDirectory)
        try data.prefix(data.count / 2).write(to: partial)
        throw CocoaError(.fileWriteOutOfSpace)
    }

    func copyItem(at source: URL, to destination: URL) throws { try base.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) throws { try base.moveItem(at: source, to: destination) }
    func removeItem(at url: URL) throws { try base.removeItem(at: url) }
    func trashItem(at url: URL) throws { try base.trashItem(at: url) }
    func modificationDate(at url: URL) -> Date? { base.modificationDate(at: url) }
    func info(at url: URL) -> FileInfo? { base.info(at: url) }
}
