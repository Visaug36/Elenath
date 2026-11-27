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
    /// Vectors made by an embedding pass, and whether chunks are still waiting for one.
    public var vectorsMade = 0
    public var vectorsPending = false
    /// Rows of files (and folders) a pass added, changed or removed.
    public var filesChanged = 0

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

/// What the background passes still have to do, over the Inbox and every space.
public struct IndexBacklog: Hashable, Sendable {
    /// Files whose text waits to be read.
    public var filesWaiting = 0
    /// Passages (chunks) waiting for a vector from a model the embedder has.
    public var passagesWaiting = 0

    public init(filesWaiting: Int = 0, passagesWaiting: Int = 0) {
        self.filesWaiting = filesWaiting
        self.passagesWaiting = passagesWaiting
    }
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
    private var embedder: (any Embedder)?
    /// The containers whose models were compared with the index's stamps in this embedding pass.
    private var checkedStamps: Set<Container> = []
    private var extractor: (any TextExtractor)?
    /// How long a file's reading may take before it is given up.
    private var readingTimeout = FileTextLimits.timeout
    /// The event folders whose files are indexed, by the space each is indexed into; nil until the app has said
    /// (`setEventFolders(_:)`), and a refresh leaves event files as they are until then.
    private var eventFolders: [Container: [EventFolderHome]]?

    /// How many notes are read and written in one transaction.
    private static let chunkSize = 100
    /// How many chunks are embedded at a time; other passes may run between batches.
    static let embeddingBatch = 16

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
        try await serialized(container) {
            try await self.replacingDamaged(container) { try await self.performRefresh(container) }
        }
    }

    /// Indexes the given notes again, or drops them when they are gone: what follows a save.
    @discardableResult
    public func update(_ paths: [ItemPath], in container: Container) async throws -> IndexReport {
        try await serialized(container) {
            try await self.replacingDamaged(container) { try await self.performUpdate(paths, in: container) }
        }
    }

    /// Empties a container's index and fills it again from the folder.
    @discardableResult
    public func rebuild(_ container: Container) async throws -> IndexReport {
        try await serialized(container) {
            try await self.replacingDamaged(container) { try await self.performRebuild(container) }
        }
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

    // MARK: - Vectors (meaning)

    /// The embedder whose vectors meaning search uses; nil leaves search to keywords.
    public func setEmbedder(_ embedder: (any Embedder)?) {
        self.embedder = embedder
        checkedStamps = []
    }

    /// Makes vectors for the container's chunks that have none, a batch at a time with the models the embedder
    /// has now. Other passes over the container run between batches, so a save is never kept waiting. A model
    /// whose stamp changed (a macOS update) has its script's vectors made again; text in a script without a
    /// model asks the embedder for one. Waits while paused.
    @discardableResult
    public func embed(_ container: Container) async throws -> Int {
        checkedStamps.remove(container)
        var made = 0
        while true {
            try await waitWhilePaused()
            let report = try await serialized(container) {
                try await self.replacingDamaged(container) { try await self.performEmbeddingBatch(container) }
            }
            made += report.vectorsMade
            guard report.vectorsPending, report.vectorsMade > 0 || report.changedAnything else { break }
        }
        return made
    }

    /// Embeds the Inbox and every space, then lets the models rest. A container that fails is logged and
    /// skipped.
    @discardableResult
    public func embedAll() async -> Int {
        guard let embedder else { return 0 }
        var made = 0
        let containers = [Container.inbox] + (await catalog.spaces()).map { Container.space($0.id) }
        for container in containers {
            do {
                made += try await embed(container)
            } catch is CancellationError {
                break
            } catch {
                log.error("Could not make vectors for a container", private: String(describing: error))
            }
        }
        await embedder.rest()
        return made
    }

    private func performEmbeddingBatch(_ container: Container) async throws -> IndexReport {
        var report = IndexReport()
        guard let embedder else { return report }
        let index = try index(for: container)
        let models = await embedder.models()
        var byScript: [String: EmbeddingModel] = [:]
        for model in models {
            byScript[model.script] = model
        }
        if !checkedStamps.contains(container) {
            checkedStamps.insert(container)
            try index.transaction {
                for model in models where try index.modelStamp(forScript: model.script) != model.stamp.key {
                    try index.forgetVectors(script: model.script)
                    try index.setModelStamp(model.stamp, forScript: model.script)
                }
            }
            for script in try index.waitingScripts(besides: Set(byScript.keys)) {
                await embedder.requestModel(for: script)
            }
        }
        let batch = try index.pendingChunks(scripts: Set(byScript.keys), limit: Indexer.embeddingBatch)
        for (script, chunks) in Dictionary(grouping: batch, by: \.script) {
            guard let model = byScript[script] else { continue }
            let vectors = try await embedder.vectors(for: chunks.map(\.text), with: model)
            try index.transaction {
                for (offset, chunk) in chunks.enumerated() {
                    if offset < vectors.count, let vector = vectors[offset], vector.count == model.dimension {
                        try index.setVector(vector, model: model.stamp, forChunk: chunk.id)
                        report.vectorsMade += 1
                    } else {
                        try index.setUnreadable(chunk: chunk.id, model: model.stamp)
                        report.updated += 1
                    }
                }
            }
        }
        report.vectorsPending = batch.count == Indexer.embeddingBatch
        return report
    }

    // MARK: - Files' text

    /// The extractor for PDFs and pictures; without one, their text waits (plain text is read regardless).
    public func setTextExtractor(_ extractor: (any TextExtractor)?) {
        self.extractor = extractor
    }

    /// For tests: how long a reading may take.
    func setReadingTimeout(_ timeout: Duration) {
        readingTimeout = timeout
    }

    /// Reads the text of the container's files that wait for it, a file at a time, oldest first, and returns how
    /// many were read. Each reading is counted in the database before it starts, so a file that crashes or hangs
    /// is tried at most `FileTextLimits.maximumAttempts` times until it changes; one that takes longer than the
    /// timeout is given up. A file that changed since the walk is left for the next refresh. Other passes over
    /// the container run between files, and the pass waits while paused.
    @discardableResult
    public func readFiles(_ container: Container) async throws -> Int {
        var cursor: Int64 = 0
        var read = 0
        while true {
            try await waitWhilePaused()
            let after = cursor
            let next = try await serialized(container) {
                try await self.replacingDamaged(container, otherwise: FileToRead?.none) {
                    try await self.performNextFileToRead(container, after: after)
                }
            }
            guard let file = next else { return read }
            cursor = file.id
            guard let url = await fileURL(of: file, in: container),
                let info = fileSystem.info(at: url), !info.isDirectory, !info.isSymbolicLink, !info.isSpecial,
                info.byteCount == file.byteCount, Indexer.sameMoment(info.modified, file.modified)
            else { continue }
            let extractor = self.extractor
            guard file.kind == .plainText || extractor != nil else { continue }
            try await serialized(container) {
                try await self.replacingDamaged(container, otherwise: ()) {
                    try await self.performStartReading(file, in: container)
                }
            }
            let text: ExtractedText?
            if file.kind == .plainText {
                text = (try? fileSystem.readData(at: url, upTo: FileTextLimits.maximumTextBytes)).map {
                    ExtractedText.plainText($0)
                }
            } else if let extractor {
                switch await withDeadline(readingTimeout, { try await extractor.text(of: url, kind: file.kind) }) {
                case .success(let extracted)?:
                    text = extracted?.limited()
                case .failure(let error)? where error is CancellationError:
                    throw error
                case .failure(let error)?:
                    log.error("Could not read a file's text", private: String(describing: error))
                    text = nil
                case nil:
                    log.error("Gave up reading a file's text: it took too long")
                    text = nil
                }
            } else {
                continue
            }
            // A file that changed while it was read: what was read may be half of each. The next refresh sees the
            // change and has it read again.
            guard let after = fileSystem.info(at: url), after.byteCount == file.byteCount,
                Indexer.sameMoment(after.modified, file.modified)
            else { continue }
            let stored = try await serialized(container) {
                try await self.replacingDamaged(container, otherwise: false) {
                    try await self.performFinishReading(file, text: text, in: container)
                }
            }
            if stored, text?.hasText == true {
                read += 1
            }
        }
    }

    private func performNextFileToRead(_ container: Container, after cursor: Int64) throws -> FileToRead? {
        try index(for: container).nextFileToRead(after: cursor)
    }

    private func performStartReading(_ file: FileToRead, in container: Container) throws {
        try index(for: container).startReading(file)
    }

    private func performFinishReading(
        _ file: FileToRead, text: ExtractedText?, in container: Container
    ) throws -> Bool {
        try index(for: container).finishReading(file, text: text)
    }

    /// Reads the files of the Inbox and every space. A container that fails is logged and skipped.
    @discardableResult
    public func readAllFiles() async -> Int {
        var read = 0
        let containers = [Container.inbox] + (await catalog.spaces()).map { Container.space($0.id) }
        for container in containers {
            do {
                read += try await readFiles(container)
            } catch is CancellationError {
                break
            } catch {
                log.error("Could not read the files of a container", private: String(describing: error))
            }
        }
        return read
    }

    /// Where a file of the container's index is: in its folder, or in the calendar's folder for an event file.
    /// Nil when that place is outside the library or can't be found.
    private func fileURL(of file: FileToRead, in container: Container) async -> URL? {
        switch file.origin {
        case .folder:
            return try? await catalog.url(for: file.path, in: container, isDirectory: false)
        case .event:
            let calendar = LibraryLayout.calendarFolder(in: catalog.root)
            let url = file.path.url(under: calendar, isDirectory: false)
            return PathContainment.contains(url, in: calendar) ? url : nil
        }
    }

    // MARK: - Event files

    /// Which event folders have their files indexed, and into which space (`CalendarReach.indexedHomes`). First
    /// every space loses the event files that are no longer its own, so a file whose event moved to another home
    /// is never found in the old one once the new one has it; then each space's event files are listed again.
    public func setEventFolders(_ folders: [EventFolderHome]) async {
        var assigned: [Container: [EventFolderHome]] = [:]
        for home in folders {
            assigned[.space(home.space), default: []].append(home)
        }
        eventFolders = assigned
        let containers = (await catalog.spaces()).map { Container.space($0.id) }
        for container in containers {
            let kept = Set((assigned[container] ?? []).map(\.occurrence.string))
            do {
                try await serialized(container) {
                    try await self.replacingDamaged(container, otherwise: ()) {
                        try await self.performRemoveEventFiles(container, keeping: kept)
                    }
                }
            } catch {
                log.error("Could not remove event files from a space", private: String(describing: error))
            }
        }
        for container in containers {
            guard let homes = assigned[container] else { continue }
            do {
                try await serialized(container) {
                    try await self.replacingDamaged(container, otherwise: ()) {
                        _ = try await self.syncEventFiles(container, homes: homes)
                    }
                }
            } catch {
                log.error("Could not list event files into a space", private: String(describing: error))
            }
        }
    }

    private func performRemoveEventFiles(_ container: Container, keeping kept: Set<String>) throws {
        let index = try index(for: container)
        try index.transaction {
            _ = try index.removeEventFiles(keeping: kept)
        }
    }

    /// Lists the files of `homes`' folders into the container's index, as event files, and drops the rest.
    private func syncEventFiles(_ container: Container, homes: [EventFolderHome]) throws -> Int {
        let index = try index(for: container)
        let records = eventFileRecords(homes)
        return try index.transaction {
            try index.removeEventFiles(keeping: Set(homes.map(\.occurrence.string)))
                + index.syncFiles(records, origin: .event)
        }
    }

    /// The most files listed from one event folder.
    static let maximumEventFiles = 10_000

    /// The files in the event folders, in their subfolders too, as rows of origin `.event`: hidden items (the
    /// marker among them), links, named pipes and devices are left out, and so is anything past
    /// `maximumEventFiles` or eight folders deep. A folder that isn't inside the calendar folder is skipped.
    private func eventFileRecords(_ homes: [EventFolderHome]) -> [FileRecord] {
        let calendar = LibraryLayout.calendarFolder(in: catalog.root)
        var records: [FileRecord] = []
        for home in homes {
            let top = home.folder.url(under: calendar, isDirectory: true)
            guard home.folder.components.count >= 2, PathContainment.contains(top, in: calendar) else { continue }
            var pending: [(path: ItemPath, url: URL, depth: Int)] = [(home.folder, top, 0)]
            var count = 0
            while let (path, url, depth) = pending.popLast(), count < Indexer.maximumEventFiles {
                guard let info = fileSystem.info(at: url), info.isDirectory, !info.isSymbolicLink,
                    let items = try? fileSystem.contentsOfDirectory(at: url)
                else { continue }
                for item in items {
                    let name = item.lastPathComponent
                    guard !name.hasPrefix("."), name != "Icon\r", let child = path.appending(name),
                        let info = fileSystem.info(at: item), !info.isSymbolicLink, !info.isSpecial
                    else { continue }
                    if info.isDirectory {
                        if depth < 8 {
                            pending.append((child, item, depth + 1))
                        }
                    } else if count < Indexer.maximumEventFiles {
                        count += 1
                        records.append(
                            FileRecord(
                                origin: .event, path: child, isFolder: false, modified: info.modified,
                                byteCount: info.byteCount, folder: home.homeFolder, event: home.occurrence))
                    }
                }
            }
        }
        return records
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

    /// What reading files and making vectors still have to do. A container that can't be read counts nothing.
    public func backlog() async -> IndexBacklog {
        var backlog = IndexBacklog()
        let scripts = Set((await embedder?.models() ?? []).map(\.script))
        let containers = [Container.inbox] + (await catalog.spaces()).map { Container.space($0.id) }
        for container in containers {
            guard let index = try? index(for: container) else { continue }
            backlog.filesWaiting += (try? index.filesWaiting()) ?? 0
            backlog.passagesWaiting += (try? index.chunksWaiting(scripts: scripts)) ?? 0
        }
        return backlog
    }

    // MARK: - Private

    /// Runs `work` after every pass that was started for the container before it.
    private func serialized<Value: Sendable>(
        _ container: Container, _ work: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
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

    /// Runs `work`. When the container's database turns out to be damaged, it is thrown away (the index
    /// is a cache, the folder is the truth) and the whole container is indexed again from the folder.
    private func replacingDamaged(
        _ container: Container, _ work: () async throws -> IndexReport
    ) async throws -> IndexReport {
        do {
            return try await work()
        } catch let error as SQLiteError where error.isDamagedFile {
            log.error("Replacing a damaged index", private: String(describing: error))
            removeIndex(of: container)
            return try await performRefresh(container)
        }
    }

    /// `replacingDamaged(_:_:)` for work that gives something else than a report: after the container has been
    /// indexed again, `fallback` is returned.
    private func replacingDamaged<Value: Sendable>(
        _ container: Container, otherwise fallback: Value, _ work: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await work()
        } catch let error as SQLiteError where error.isDamagedFile {
            log.error("Replacing a damaged index", private: String(describing: error))
            removeIndex(of: container)
            _ = try await performRefresh(container)
            return fallback
        }
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

    /// A note's bytes, at most `NoteLimits.maximumIndexedBytes` of them, without a character cut in half.
    private static func readBeginning(of url: URL, fileSystem: any FileSystem) throws -> Data {
        let data = try fileSystem.readData(at: url, upTo: NoteLimits.maximumIndexedBytes)
        return data.count < NoteLimits.maximumIndexedBytes ? data : NoteLimits.droppingSplitCharacter(data)
    }

    private func waitWhilePaused() async throws {
        while isPaused {
            try await Task.sleep(for: .milliseconds(200))
        }
        try Task.checkCancellation()
    }

    /// Everything in the container's folder: its notes, and its other files and folders, the files in its
    /// attachments folders included.
    private func walk(_ container: Container) async throws -> (notes: [NoteEntry], files: [FileRecord]) {
        var notes: [NoteEntry] = []
        var files: [FileRecord] = []
        var pending: [ItemPath] = [.root]
        while let folder = pending.popLast() {
            let listing = try await catalog.listing(of: folder, in: container)
            notes += listing.notes
            var entries = listing.files
            if let attachments = listing.attachmentsFolder {
                entries += try await catalog.attachmentFiles(in: attachments, of: container)
            }
            for file in entries {
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
                    guard let data = try? Indexer.readBeginning(of: url, fileSystem: fileSystem) else { continue }
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
            report.filesChanged += try index.syncFiles(files, origin: .folder)
        }
        if let assigned = eventFolders {
            report.filesChanged += try syncEventFiles(container, homes: assigned[container] ?? [])
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
                guard let info = fileSystem.info(at: url), !info.isDirectory, !info.isSymbolicLink, !info.isSpecial,
                    let data = try? Indexer.readBeginning(of: url, fileSystem: fileSystem)
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
