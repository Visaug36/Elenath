import Foundation

/// A note file that was renamed or moved outside Elenath, as the indexer recognized it.
public struct NoteMove: Hashable, Sendable {
    public var from: NoteRef
    public var to: NoteRef

    public init(from: NoteRef, to: NoteRef) {
        self.from = from
        self.to = to
    }
}

/// What one pass over a container changed in its index.
public struct IndexReport: Hashable, Sendable {
    public var added = 0
    public var updated = 0
    public var removed = 0
    public var unchanged = 0
    /// Notes that are the same note under a new name or in a new folder. Their links can be repaired.
    public var moved: [NoteMove] = []

    public init() {}

    /// Whether the index is different after the pass.
    public var changedAnything: Bool {
        added > 0 || updated > 0 || removed > 0 || !moved.isEmpty
    }
}

public struct IndexStatus: Hashable, Sendable {
    public var isPaused: Bool
    public var isIndexing: Bool
}

/// Keeps the index in step with the folder (docs/ARCHITECTURE.md, "Index and retrieval").
///
/// The indexer is the only writer. It reads a file again only when its size or date changed, and
/// rewrites its rows only when its bytes did. A file that disappeared and one that appeared with the same
/// `id`, the same file identity or the same bytes are one note that moved.
public actor Indexer {
    private let catalog: LibraryCatalog
    private let indexDirectory: URL
    private let fileSystem: any FileSystem
    private let timeZone: @Sendable () -> TimeZone
    private let log = CoreLog(category: "Indexer")

    private var indexes: [Container: SpaceIndex] = [:]
    /// The last pass started for each container: the next one waits for it.
    private var tails: [Container: Task<Void, Never>] = [:]
    private var isPaused = false
    private var running = 0

    /// How many notes are read and written in one transaction.
    private static let chunkSize = 100

    public init(
        catalog: LibraryCatalog, indexDirectory: URL, fileSystem: any FileSystem,
        timeZone: @escaping @Sendable () -> TimeZone = { .current }
    ) {
        self.catalog = catalog
        self.indexDirectory = indexDirectory
        self.fileSystem = fileSystem
        self.timeZone = timeZone
    }

    // MARK: - Indexing

    /// Brings a container's index in step with its folder, touching only what changed.
    @discardableResult
    public func refresh(_ container: Container) async throws -> IndexReport {
        try await serialized(container) { try await self.performRefresh(container) }
    }

    /// Indexes the given notes again, or drops them when they are gone: what follows a save.
    @discardableResult
    public func update(_ paths: [ItemPath], in container: Container) async throws -> IndexReport {
        try await serialized(container) { try await self.performUpdate(paths, in: container) }
    }

    /// Empties a container's index and fills it again from the folder.
    @discardableResult
    public func rebuild(_ container: Container) async throws -> IndexReport {
        try await serialized(container) { try await self.performRebuild(container) }
    }

    /// Refreshes the Inbox and every space. A container that fails is logged and skipped.
    @discardableResult
    public func refreshAll() async -> [Container: IndexReport] {
        var reports: [Container: IndexReport] = [:]
        let containers = [Container.inbox] + (await catalog.spaces()).map { Container.space($0.id) }
        for container in containers {
            do {
                reports[container] = try await refresh(container)
            } catch {
                log.error("Could not index a container", private: String(describing: error))
            }
        }
        return reports
    }

    /// Deletes the index of a space that no longer exists.
    public func removeIndex(of container: Container) {
        indexes[container] = nil
        let file = indexDirectory.appending(
            component: SpaceIndex.fileName(for: container), directoryHint: .notDirectory)
        for suffix in ["", "-wal", "-shm"] {
            try? fileSystem.removeItem(at: URL(fileURLWithPath: file.path + suffix))
        }
    }

    /// Stops reading files until `resume()`: for Low Power Mode. A pass that is under way finishes the
    /// notes it is on and waits.
    public func pause() {
        isPaused = true
    }

    public func resume() {
        isPaused = false
    }

    public func status() -> IndexStatus {
        IndexStatus(isPaused: isPaused, isIndexing: running > 0)
    }

    // MARK: - Private

    /// Runs `work` after every pass that was started for the container before it.
    private func serialized(
        _ container: Container, _ work: @escaping @Sendable () async throws -> IndexReport
    ) async throws -> IndexReport {
        let previous = tails[container]
        let task = Task {
            await previous?.value
            return try await work()
        }
        tails[container] = Task { _ = try? await task.value }
        running += 1
        defer { running -= 1 }
        return try await task.value
    }

    private func index(for container: Container) throws -> SpaceIndex {
        if let index = indexes[container] {
            return index
        }
        try fileSystem.createDirectory(at: indexDirectory)
        let url = indexDirectory.appending(component: SpaceIndex.fileName(for: container), directoryHint: .notDirectory)
        let index = try SpaceIndex(url: url, container: container)
        indexes[container] = index
        return index
    }

    private func waitWhilePaused() async throws {
        while isPaused {
            try await Task.sleep(for: .milliseconds(200))
        }
        try Task.checkCancellation()
    }

    /// Everything in the container's folder: its notes, and its other files and folders.
    private func walk(_ container: Container) async throws -> (notes: [NoteEntry], files: [FileRecord]) {
        var notes: [NoteEntry] = []
        var files: [FileRecord] = []
        var pending: [ItemPath] = [.root]
        while let folder = pending.popLast() {
            let listing = try await catalog.listing(of: folder, in: container)
            notes += listing.notes
            for file in listing.files {
                files.append(
                    FileRecord(path: file.path, isFolder: false, modified: file.modified, byteCount: file.byteCount))
            }
            for subfolder in listing.folders {
                files.append(FileRecord(path: subfolder, isFolder: true, modified: nil, byteCount: 0))
                pending.append(subfolder)
            }
        }
        return (notes, files)
    }

    private func performRebuild(_ container: Container) async throws -> IndexReport {
        try index(for: container).clear()
        return try await performRefresh(container)
    }

    private func performRefresh(_ container: Container) async throws -> IndexReport {
        try await waitWhilePaused()
        let (notes, files) = try await walk(container)
        let base = try await catalog.folderURL(of: container)
        let index = try index(for: container)
        var report = IndexReport()

        // What changed, judged by size and date alone.
        var known: [String: IndexedNoteState] = [:]
        for state in try index.noteStates() {
            known[NameSanitizer.key(state.path.description)] = state
        }
        var seen = Set<String>()
        var toRead: [(entry: NoteEntry, existing: IndexedNoteState?)] = []
        for entry in notes {
            let key = NameSanitizer.key(entry.path.description)
            seen.insert(key)
            guard let state = known[key] else {
                toRead.append((entry, nil))
                continue
            }
            if state.path == entry.path && state.byteCount == entry.byteCount
                && Indexer.sameMoment(state.modified, entry.modified)
            {
                report.unchanged += 1
            } else {
                toRead.append((entry, state))
            }
        }
        var gone = known.filter { !seen.contains($0.key) }.map(\.value)

        var start = 0
        while start < toRead.count {
            try await waitWhilePaused()
            let chunk = toRead[start..<min(start + Indexer.chunkSize, toRead.count)]
            start += Indexer.chunkSize
            try index.transaction {
                for (entry, existing) in chunk {
                    let url = entry.path.url(under: base, isDirectory: false)
                    guard let data = try? fileSystem.readData(at: url) else { continue }
                    let record = NoteRecord(
                        path: entry.path, data: data, info: fileSystem.info(at: url), timeZone: timeZone())
                    if let existing {
                        if existing.contentHash == record.contentHash && existing.path == entry.path {
                            try index.touch(rowID: existing.rowID, modified: record.modified, identity: record.identity)
                            report.unchanged += 1
                        } else {
                            try index.store(record, replacing: existing.rowID)
                            report.updated += 1
                        }
                    } else if let match = Indexer.takeMatch(for: record, from: &gone) {
                        try index.store(record, replacing: match.rowID)
                        report.moved.append(
                            NoteMove(
                                from: NoteRef(container: container, path: match.path),
                                to: NoteRef(container: container, path: entry.path)))
                    } else {
                        try index.store(record, replacing: nil)
                        report.added += 1
                    }
                }
            }
        }

        try index.transaction {
            for state in gone {
                try index.remove(rowID: state.rowID)
                report.removed += 1
            }
            try index.replaceFiles(files)
        }
        return report
    }

    private func performUpdate(_ paths: [ItemPath], in container: Container) async throws -> IndexReport {
        try await waitWhilePaused()
        var urls: [(path: ItemPath, url: URL)] = []
        for path in paths where ItemPath.isNoteFileName(path.name) {
            // Nothing inside Elenath's own folders or an attachments folder is a note.
            guard !path.components.dropLast().contains(where: NameSanitizer.isReservedInSpace) else { continue }
            urls.append((path, try await catalog.url(for: path, in: container, isDirectory: false)))
        }
        let index = try index(for: container)
        var report = IndexReport()
        var known: [String: IndexedNoteState] = [:]
        for state in try index.noteStates() {
            known[NameSanitizer.key(state.path.description)] = state
        }
        try index.transaction {
            for (path, url) in urls {
                let existing = known[NameSanitizer.key(path.description)]
                guard let info = fileSystem.info(at: url), !info.isDirectory, !info.isSymbolicLink,
                    let data = try? fileSystem.readData(at: url)
                else {
                    if let existing {
                        try index.remove(rowID: existing.rowID)
                        report.removed += 1
                    }
                    continue
                }
                let record = NoteRecord(path: path, data: data, info: info, timeZone: timeZone())
                if let existing, existing.contentHash == record.contentHash, existing.path == path {
                    try index.touch(rowID: existing.rowID, modified: record.modified, identity: record.identity)
                    report.unchanged += 1
                } else {
                    try index.store(record, replacing: existing?.rowID)
                    if existing == nil {
                        report.added += 1
                    } else {
                        report.updated += 1
                    }
                }
            }
        }
        return report
    }

    /// The row among those whose files are gone that is the same note as `record`: by `id`, else by file
    /// identity, else by its bytes when exactly one row has them. The match is taken out of `gone`.
    private static func takeMatch(for record: NoteRecord, from gone: inout [IndexedNoteState]) -> IndexedNoteState? {
        var position: Int?
        if let id = record.noteID?.string {
            position = gone.firstIndex { $0.noteID == id }
        }
        if position == nil, let identity = record.identity {
            position = gone.firstIndex { $0.identity == identity }
        }
        if position == nil, record.byteCount > 0 {
            let same = gone.indices.filter {
                gone[$0].contentHash == record.contentHash && gone[$0].byteCount == record.byteCount
            }
            if same.count == 1 {
                position = same[0]
            }
        }
        return position.map { gone.remove(at: $0) }
    }

    private static func sameMoment(_ first: Date?, _ second: Date?) -> Bool {
        switch (first, second) {
        case (nil, nil): true
        case (let first?, let second?): abs(first.timeIntervalSince(second)) < 0.001
        default: false
        }
    }
}
