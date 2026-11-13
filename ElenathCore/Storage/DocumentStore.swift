import Foundation

/// Why a document couldn't be loaded or saved.
public enum DocumentStoreError: Error, Equatable, Sendable {
    /// Nothing to load and nothing to recover from (or the folder it belongs to is missing).
    case missing
    /// The file was written by a newer Elenath. It is opened read-only and never overwritten.
    case newerSchema(found: Int, supported: Int)
    /// The file is damaged and no backup or safety copy could be loaded. The text is a technical
    /// detail for logs, not for display.
    case unreadable(String)
    /// `save(_:)` after loading a file from a newer Elenath.
    case readOnly
}

/// How a damaged or missing file was recovered, so the app can tell the user.
public struct RecoveryReport: Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        /// A file in `.elenath/backups/`.
        case backup(URL)
        /// The safety copy in Application Support.
        case safetyCopy(URL)

        public var url: URL {
            switch self {
            case .backup(let url), .safetyCopy(let url): return url
            }
        }
    }

    public var source: Source
    /// When the recovered copy was saved, if it says.
    public var recoveredSavedAt: Date?
    /// Where the damaged file was set aside; nil when it was missing.
    public var damagedFileMovedTo: URL?

    public init(source: Source, recoveredSavedAt: Date?, damagedFileMovedTo: URL?) {
        self.source = source
        self.recoveredSavedAt = recoveredSavedAt
        self.damagedFileMovedTo = damagedFileMovedTo
    }
}

/// The result of `DocumentStore.load()`.
public struct DocumentLoad<Document: VersionedDocument>: Hashable, Sendable {
    public var document: Document
    /// Set when the file was missing or damaged and the document came from a backup or safety copy.
    public var recovery: RecoveryReport?

    public init(document: Document, recovery: RecoveryReport?) {
        self.document = document
        self.recovery = recovery
    }
}

/// Loads and saves one of Elenath's JSON documents (library.json or space.json), with rolling backups, a
/// safety copy outside the folder and recovery from either.
///
/// ```
/// <owner>/<metadata folder>/library.json
/// <owner>/<metadata folder>/backups/library-yyyyMMdd-HHmmss.json   (UTC; "-2", "-3"… within one second)
/// <owner>/<metadata folder>/library.corrupt-yyyyMMdd-HHmmss.json   (a damaged file, set aside, never deleted)
/// <safetyDirectory>/<document id>.json
/// ```
///
/// All disk work happens on the actor, never on the caller's thread. Call `load()` or `create(_:)`
/// before `save(_:)`; a save without one first checks the file it would replace, so it can
/// never overwrite a file from a newer Elenath or destroy a damaged one. Nothing is written outside
/// `owner` except the safety copy, and nothing is written at all if `owner` is missing (a moved folder
/// or an unplugged drive).
public actor DocumentStore<Document: VersionedDocument> {
    /// The folder the document belongs to: the library folder, or a space's folder.
    public nonisolated let owner: URL

    private let safetyDirectory: URL
    private var knownDocumentID: UUID?
    private let fileSystem: any FileSystem
    private let timeSource: any TimeSource
    private let backupInterval: TimeInterval
    private let maxBackups: Int

    private let metadataFolder: URL
    private let file: URL
    private let backupsFolder: URL
    private let log = CoreLog(category: "DocumentStore")

    /// Set when the file was written by a newer Elenath.
    private var isReadOnly = false
    /// Set once the file has been loaded, created or checked, so `save(_:)` knows what it replaces.
    private var hasCheckedEventsFile = false
    /// The schema of the file last loaded; an older one forces a backup before the first save rewrites it.
    private var loadedSchemaVersion = Document.currentSchemaVersion

    /// - Parameters:
    ///   - owner: The folder the document belongs to. It must exist; it is never created.
    ///   - metadataFolderName: The hidden folder inside `owner` that holds the file and its backups.
    ///   - safetyDirectory: Where safety copies live, e.g. Application Support/Elenath/SafetyCopies.
    ///   - knownDocumentID: The ID of the document last opened from this folder, used to find its safety
    ///     copy when the file is damaged. nil uses the ID found in the newest backup.
    ///   - backupInterval: The minimum time between backups.
    ///   - maxBackups: How many backups to keep; 0 turns backups off.
    public init(
        owner: URL,
        metadataFolderName: String,
        safetyDirectory: URL,
        knownDocumentID: UUID?,
        fileSystem: any FileSystem,
        timeSource: any TimeSource,
        backupInterval: TimeInterval,
        maxBackups: Int
    ) {
        self.owner = owner
        self.safetyDirectory = safetyDirectory
        self.knownDocumentID = knownDocumentID
        self.fileSystem = fileSystem
        self.timeSource = timeSource
        self.backupInterval = backupInterval
        self.maxBackups = maxBackups
        let metadataFolder = owner.appending(component: metadataFolderName, directoryHint: .isDirectory)
        self.metadataFolder = metadataFolder
        self.file = metadataFolder.appending(component: Document.fileName, directoryHint: .notDirectory)
        self.backupsFolder = metadataFolder.appending(
            component: LibraryLayout.backupsFolderName, directoryHint: .isDirectory)
    }

    // MARK: - Loading

    /// Reads the file, migrating an older schema in memory.
    ///
    /// If it is missing or damaged, the newest backup or safety copy that decodes (by `savedAt`) is
    /// used: the damaged file is set aside beside it (`library.corrupt-….json`), the recovered document is
    /// written back as the file, and the result carries a `RecoveryReport`.
    ///
    /// Throws `missing` when there's nothing to load (or `owner` is missing), `unreadable` when
    /// the file is damaged and nothing could be recovered (it is then left untouched), and
    /// `newerSchema` for a file from a newer Elenath, after which the store is read-only.
    public func load() throws -> DocumentLoad<Document> {
        isReadOnly = false
        hasCheckedEventsFile = false
        guard fileSystem.isDirectory(at: owner) else {
            log.error("The folder is missing")
            throw DocumentStoreError.missing
        }

        let fileExists = fileSystem.fileExists(at: file)
        var damage: DocumentStoreError?
        if fileExists {
            do {
                let data = try fileSystem.readData(at: file)
                let decoded = try DocumentCodec.decode(Document.self, from: data)
                adopt(decoded)
                return DocumentLoad(document: decoded.document, recovery: nil)
            } catch let error as DocumentStoreError {
                if case .newerSchema = error {
                    isReadOnly = true
                    log.notice("The file is from a newer Elenath; opening read-only")
                    throw error
                }
                damage = error
            } catch {
                damage = .unreadable("the file could not be read: \(error.localizedDescription)")
            }
            log.error("The file is damaged; looking for a backup")
        }

        guard let winner = recoveryCandidates().first else {
            log.error("No backup or safety copy could be loaded")
            throw damage ?? DocumentStoreError.missing
        }

        var damagedFileMovedTo: URL?
        if fileExists {
            damagedFileMovedTo = try setDamagedEventsFileAside()
        }

        do {
            try fileSystem.createDirectory(at: metadataFolder)
            try fileSystem.writeAtomically(winner.data, to: file)
        } catch {
            // The document is still returned; the next save writes the file again.
            log.error("Could not write the recovered file", private: String(describing: error))
        }

        adopt(winner.decoded)
        if winner.isSafetyCopy {
            log.notice("Recovered from the safety copy")
        } else {
            log.notice("Recovered from a backup")
        }
        let report = RecoveryReport(
            source: winner.source, recoveredSavedAt: winner.decoded.savedAt, damagedFileMovedTo: damagedFileMovedTo)
        return DocumentLoad(document: winner.decoded.document, recovery: report)
    }

    // MARK: - Writing

    /// Writes a brand-new document. Refuses (throws) if `owner` is missing or the file already exists, so
    /// an existing document is never replaced by an empty one.
    public func create(_ document: Document) throws {
        guard fileSystem.isDirectory(at: owner) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSURLErrorKey: owner])
        }
        guard !fileSystem.fileExists(at: file) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSURLErrorKey: file])
        }
        let data = try DocumentCodec.encode(document, savedAt: timeSource.now)
        try fileSystem.createDirectory(at: metadataFolder)
        try fileSystem.writeAtomically(data, to: file)
        isReadOnly = false
        hasCheckedEventsFile = true
        knownDocumentID = document.documentID
        loadedSchemaVersion = Document.currentSchemaVersion
        writeSafetyCopy(data, documentID: document.documentID)
    }

    /// Saves the document.
    ///
    /// If no backup was made within the last `backupInterval`, the current file is first copied
    /// into `backups/` and the oldest backups beyond `maxBackups` are removed. Then the file is
    /// written atomically (a failure leaves the previous file intact and is thrown), and the same bytes
    /// go to the safety copy (a failure there is only logged).
    ///
    /// Throws `readOnly` without touching anything after loading a file from a newer Elenath. Without a
    /// successful `load()` or `create(_:)` first, the existing file is checked: one from a newer
    /// Elenath makes the store read-only, and a damaged one is set aside like in `load()`.
    public func save(_ document: Document) throws {
        try save(document, backingUpNewVersion: false)
    }

    /// Saves the document like `save(_:)`. With `backingUpNewVersion`, the new file is also copied into
    /// `backups/` at once, whatever the interval: for a change that must survive the loss of the file
    /// even on a Mac without the safety copy (sealing a space).
    public func save(_ document: Document, backingUpNewVersion: Bool) throws {
        guard !isReadOnly else { throw DocumentStoreError.readOnly }
        guard fileSystem.isDirectory(at: owner) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSURLErrorKey: owner])
        }
        if !hasCheckedEventsFile {
            try checkEventsFileBeforeFirstSave()
        }
        let now = timeSource.now
        let data = try DocumentCodec.encode(document, savedAt: now)
        try fileSystem.createDirectory(at: metadataFolder)
        backUpEventsFileIfDue(now: now)
        try fileSystem.writeAtomically(data, to: file)
        knownDocumentID = document.documentID
        loadedSchemaVersion = Document.currentSchemaVersion
        writeSafetyCopy(data, documentID: document.documentID)
        if backingUpNewVersion {
            writeBackup(now: now)
        }
    }

    // MARK: - Helpers

    private func adopt(_ decoded: DecodedDocument<Document>) {
        knownDocumentID = decoded.document.documentID
        loadedSchemaVersion = decoded.schemaVersion
        isReadOnly = false
        hasCheckedEventsFile = true
    }

    /// Moves the damaged file aside as `<corrupt prefix>yyyyMMdd-HHmmss.json` and returns where it
    /// went. Throws `unreadable` if it can't be moved, so it is never overwritten.
    private func setDamagedEventsFileAside() throws -> URL {
        let destination = uniqueTimestampedFile(
            in: metadataFolder, prefix: Document.corruptPrefix, date: timeSource.now)
        do {
            try fileSystem.moveItem(at: file, to: destination)
        } catch {
            log.error("Could not set the damaged file aside", private: String(describing: error))
            throw DocumentStoreError.unreadable("the file is damaged and could not be set aside")
        }
        return destination
    }

    /// For a save that no successful `load()` or `create(_:)` preceded: refuses to replace a file from a
    /// newer Elenath (the store becomes read-only) and sets a damaged file aside instead of overwriting it.
    private func checkEventsFileBeforeFirstSave() throws {
        guard fileSystem.fileExists(at: file) else {
            hasCheckedEventsFile = true
            return
        }
        do {
            let decoded = try DocumentCodec.decode(Document.self, from: fileSystem.readData(at: file))
            loadedSchemaVersion = decoded.schemaVersion
        } catch let error as DocumentStoreError {
            if case .newerSchema = error {
                isReadOnly = true
                log.notice("The file is from a newer Elenath; not saving over it")
                throw DocumentStoreError.readOnly
            }
            _ = try setDamagedEventsFileAside()
        } catch {
            _ = try setDamagedEventsFileAside()
        }
        hasCheckedEventsFile = true
    }

    private func safetyCopyFile(for documentID: UUID) -> URL {
        safetyDirectory.appending(component: "\(documentID.uuidString).json", directoryHint: .notDirectory)
    }

    private func writeSafetyCopy(_ data: Data, documentID: UUID) {
        do {
            try fileSystem.createDirectory(at: safetyDirectory)
            try fileSystem.writeAtomically(data, to: safetyCopyFile(for: documentID))
        } catch {
            log.error("Could not write the safety copy", private: String(describing: error))
        }
    }

    /// Copies the file into `backups/` unless a backup was made within `backupInterval` of now
    /// (in either direction, so a clock set back doesn't stop backups), then prunes. Failures are
    /// logged: a missing backup must not stop the user's change from being saved.
    private func backUpEventsFileIfDue(now: Date) {
        guard maxBackups > 0, fileSystem.fileExists(at: file) else { return }
        let afterMigration = loadedSchemaVersion < Document.currentSchemaVersion
        let existing = backupFiles()
        let hasRecentBackup = existing.contains { abs(now.timeIntervalSince($0.date)) < backupInterval }
        guard afterMigration || !hasRecentBackup else { return }
        writeBackup(now: now)
    }

    /// Copies the file into `backups/` now, then prunes.
    private func writeBackup(now: Date) {
        guard maxBackups > 0, fileSystem.fileExists(at: file) else { return }
        let existing = backupFiles()
        // Within one second, number past every backup already there (even after older ones were pruned),
        // so the new backup always sorts newest and pruning never removes it.
        let stamp = DocumentStoreTimestamp.string(from: now)
        var highestCounter = 0
        for backup in existing where backup.stamp == stamp {
            highestCounter = max(highestCounter, backup.counter)
        }
        do {
            try fileSystem.createDirectory(at: backupsFolder)
            let destination = uniqueTimestampedFile(
                in: backupsFolder, prefix: Document.backupPrefix, date: now, firstCounter: highestCounter + 1)
            try fileSystem.copyItem(at: file, to: destination)
        } catch {
            log.error("Could not back up the file", private: String(describing: error))
            return
        }
        pruneBackups()
    }

    /// Keeps the newest `maxBackups` backups, by the timestamp (and counter) in their names.
    private func pruneBackups() {
        let backups = backupFiles()
        guard backups.count > maxBackups else { return }
        for backup in backups.prefix(backups.count - maxBackups) {
            do {
                try fileSystem.removeItem(at: backup.url)
            } catch {
                log.error("Could not remove an old backup", private: String(describing: error))
            }
        }
    }

    /// Elenath's backups in `backups/`, oldest first. Other files there are ignored and never touched.
    private func backupFiles() -> [DocumentStoreBackupFile] {
        guard let contents = try? fileSystem.contentsOfDirectory(at: backupsFolder) else { return [] }
        var backups: [DocumentStoreBackupFile] = []
        for item in contents {
            let name = item.lastPathComponent
            if let backup = DocumentStoreBackupFile(name: name, in: backupsFolder, prefix: Document.backupPrefix) {
                backups.append(backup)
            }
        }
        return backups.sorted { ($0.stamp, $0.counter) < ($1.stamp, $1.counter) }
    }

    /// `<prefix>yyyyMMdd-HHmmss.json` for `date` (UTC), with "-2", "-3"… added if that name is taken.
    /// `firstCounter` skips numbers that must not be reused (1 is the plain name).
    private func uniqueTimestampedFile(in folder: URL, prefix: String, date: Date, firstCounter: Int = 1) -> URL {
        let stamp = DocumentStoreTimestamp.string(from: date)
        var counter = max(firstCounter, 1)
        var url = Self.timestampedFile(in: folder, prefix: prefix, stamp: stamp, counter: counter)
        while fileSystem.fileExists(at: url) {
            counter += 1
            url = Self.timestampedFile(in: folder, prefix: prefix, stamp: stamp, counter: counter)
        }
        return url
    }

    private static func timestampedFile(in folder: URL, prefix: String, stamp: String, counter: Int) -> URL {
        let name = counter == 1 ? "\(prefix)\(stamp).json" : "\(prefix)\(stamp)-\(counter).json"
        return folder.appending(component: name, directoryHint: .notDirectory)
    }

    /// Every backup and the safety copy that decodes, newest `savedAt` first. The safety copy is the one
    /// for `knownDocumentID`, or else for the document ID in the newest backup.
    private func recoveryCandidates() -> [DocumentStoreCandidate<Document>] {
        var backups: [DocumentStoreCandidate<Document>] = []
        for backup in backupFiles().reversed() {
            if let candidate = recoveryCandidate(at: backup.url, isSafetyCopy: false, order: backups.count) {
                backups.append(candidate)
            }
        }
        backups = DocumentStoreCandidate.newestFirst(backups)

        var candidates = backups
        if let documentID = knownDocumentID ?? backups.first?.decoded.document.documentID {
            let safetyCopy = safetyCopyFile(for: documentID)
            if let candidate = recoveryCandidate(at: safetyCopy, isSafetyCopy: true, order: candidates.count) {
                candidates.append(candidate)
            }
        }
        return DocumentStoreCandidate.newestFirst(candidates)
    }

    private func recoveryCandidate(at url: URL, isSafetyCopy: Bool, order: Int) -> DocumentStoreCandidate<Document>? {
        guard fileSystem.fileExists(at: url) else { return nil }
        do {
            let data = try fileSystem.readData(at: url)
            let decoded = try DocumentCodec.decode(Document.self, from: data)
            return DocumentStoreCandidate(
                url: url, isSafetyCopy: isSafetyCopy, data: data, decoded: decoded, order: order)
        } catch {
            let detail = "\(url.lastPathComponent): \(String(describing: error))"
            log.error("Skipping a copy that can't be read", private: detail)
            return nil
        }
    }
}

/// A backup or safety copy that decoded, with its bytes so it can be written back unchanged.
private struct DocumentStoreCandidate<Document: VersionedDocument> {
    var url: URL
    var isSafetyCopy: Bool
    var data: Data
    var decoded: DecodedDocument<Document>
    /// Tie-breaker for equal `savedAt`: lower wins (newer backups come first, the safety copy last).
    var order: Int

    var source: RecoveryReport.Source {
        isSafetyCopy ? .safetyCopy(url) : .backup(url)
    }

    static func newestFirst(_ candidates: [DocumentStoreCandidate<Document>]) -> [DocumentStoreCandidate<Document>] {
        candidates.sorted { lhs, rhs in
            let lhsSavedAt = lhs.decoded.savedAt ?? .distantPast
            let rhsSavedAt = rhs.decoded.savedAt ?? .distantPast
            if lhsSavedAt != rhsSavedAt { return lhsSavedAt > rhsSavedAt }
            return lhs.order < rhs.order
        }
    }
}

/// A file in `backups/` named `<prefix>yyyyMMdd-HHmmss.json` or `<prefix>yyyyMMdd-HHmmss-N.json`.
private struct DocumentStoreBackupFile {
    var url: URL
    /// `yyyyMMdd-HHmmss`; fixed width, so it sorts chronologically as text.
    var stamp: String
    /// 1 for the plain name, N for a "-N" suffix.
    var counter: Int
    var date: Date

    init?(name: String, in folder: URL, prefix: String) {
        let suffix = ".json"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        guard name.count > prefix.count + suffix.count else { return nil }
        let core = name.dropFirst(prefix.count).dropLast(suffix.count)
        let pieces = core.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 2 || pieces.count == 3 else { return nil }
        let stamp = "\(pieces[0])-\(pieces[1])"
        guard let date = DocumentStoreTimestamp.date(from: stamp) else { return nil }
        var counter = 1
        if pieces.count == 3 {
            guard let number = Int(pieces[2]), number >= 2 else { return nil }
            counter = number
        }
        self.url = folder.appending(component: name, directoryHint: .notDirectory)
        self.stamp = stamp
        self.counter = counter
        self.date = date
    }
}

/// `yyyyMMdd-HHmmss` timestamps in UTC, built from calendar components (no DateFormatter, so the
/// user's locale and calendar can't change them).
private enum DocumentStoreTimestamp {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    static func string(from date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let day = String(format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let time = String(format: "%02d%02d%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        return "\(day)-\(time)"
    }

    /// Parses `yyyyMMdd-HHmmss`; nil for anything else, including impossible dates.
    static func date(from text: String) -> Date? {
        let pieces = text.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 2, pieces[0].count == 8, pieces[1].count == 6 else { return nil }
        guard let day = Int(pieces[0]), let time = Int(pieces[1]) else { return nil }
        let parts = DateComponents(
            year: day / 10_000, month: day / 100 % 100, day: day % 100,
            hour: time / 10_000, minute: time / 100 % 100, second: time % 100)
        guard let date = calendar.date(from: parts), string(from: date) == text else { return nil }
        return date
    }
}
