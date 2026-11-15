import ElenathCore
import Foundation

/// A clock the tests move by hand.
final class TestClock: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

/// A unique folder under the temporary directory. Call `remove()` when done (usually in a `defer`).
struct TempFolder {
    let url: URL

    init() throws {
        let name = "ElenathTests-\(UUID().uuidString)"
        url = FileManager.default.temporaryDirectory.appending(component: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// A URL inside the folder; `path` may contain slashes. Nothing is created.
    func child(_ path: String) -> URL {
        url.appending(path: path, directoryHint: .isDirectory)
    }

    /// Creates a subfolder (and its parents; `name` may contain slashes) and returns it.
    func makeDirectory(_ name: String) throws -> URL {
        let directory = child(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        return directory
    }
}

/// A real file system whose atomic writes fail under one folder, like a full disk or a locked file.
struct FaultyFileSystem: FileSystem {
    var failingWritesUnder: URL
    let base = LocalFileSystem()

    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    func isDirectory(at url: URL) -> Bool { base.isDirectory(at: url) }
    func contentsOfDirectory(at url: URL) throws -> [URL] { try base.contentsOfDirectory(at: url) }
    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
    func readData(at url: URL) throws -> Data { try base.readData(at: url) }

    func writeAtomically(_ data: Data, to url: URL) throws {
        let folder = failingWritesUnder.path
        if url.path == folder || url.path.hasPrefix(folder + "/") {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try base.writeAtomically(data, to: url)
    }

    func copyItem(at source: URL, to destination: URL) throws { try base.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) throws { try base.moveItem(at: source, to: destination) }
    func removeItem(at url: URL) throws { try base.removeItem(at: url) }
    func trashItem(at url: URL) throws { try base.trashItem(at: url) }
    func modificationDate(at url: URL) -> Date? { base.modificationDate(at: url) }
    func info(at url: URL) -> FileInfo? { base.info(at: url) }
}

/// A real file system with a Trash of its own, inside the test's temporary folder: each trashed item goes
/// into a new subfolder there, so it keeps its name. Tests never touch the user's Trash, and it works on
/// systems that have none.
struct TrashingFileSystem: FileSystem {
    let trash: URL
    let base = LocalFileSystem()

    init(trashIn folder: URL) {
        trash = folder.appending(component: "Trash", directoryHint: .isDirectory)
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
    func trashItem(at url: URL) throws { _ = try trashItemReturningURL(at: url) }

    func trashItemReturningURL(at url: URL) throws -> URL? {
        let slot = trash.appending(component: UUID().uuidString, directoryHint: .isDirectory)
        try base.createDirectory(at: slot)
        let destination = slot.appending(component: url.lastPathComponent)
        try base.moveItem(at: url, to: destination)
        return destination
    }

    func modificationDate(at url: URL) -> Date? { base.modificationDate(at: url) }
    func info(at url: URL) -> FileInfo? { base.info(at: url) }
}

/// Small helpers for looking at what a test left on disk.
enum TestFiles {
    /// The names of the items in a folder, hidden ones included; empty if it doesn't exist.
    static func names(in folder: URL) -> Set<String> {
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return Set(contents.map(\.lastPathComponent))
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
