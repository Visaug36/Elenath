import Foundation

/// Why the calendar couldn't be opened.
public enum CalendarStoreError: Error, Equatable, Sendable {
    /// A space made by Elenath 0.1 is called "Calendar", the name the calendar's folder needs. It stays a
    /// space, untouched; the calendar opens once the space is renamed.
    case nameTakenBySpace
    /// The `Calendar` item in the library is a file or a link: never followed, never written through.
    case notAFolder
}

/// The result of `CalendarStore.load(readOnly:)`.
public struct CalendarLoad: Hashable, Sendable {
    public var document: CalendarDocument
    /// Set when events.json was missing or damaged and came back from a backup or the safety copy.
    public var recovery: RecoveryReport?
    /// The calendar is shown and never written: events.json is from a newer Ithil or Elenath, or the
    /// library itself is read-only.
    public var isReadOnly: Bool
    /// The calendar was made just now: the first launch with a calendar.
    public var isNew: Bool
    /// The calendar was made just now although its folder already held event folders or backups, so
    /// events.json was lost with nothing to bring it back from. The app says that an empty calendar was
    /// started and the event folders are untouched.
    public var startedOverLostFile: Bool

    public init(
        document: CalendarDocument, recovery: RecoveryReport?, isReadOnly: Bool, isNew: Bool,
        startedOverLostFile: Bool
    ) {
        self.document = document
        self.recovery = recovery
        self.isReadOnly = isReadOnly
        self.isNew = isNew
        self.startedOverLostFile = startedOverLostFile
    }
}

/// The calendar of a library: `<library>/Calendar`, in Ithil's format (docs/FORMAT.md, "The calendar").
///
/// ```
/// <library>/Calendar/.ithil/events.json
/// <library>/Calendar/.ithil/backups/events-yyyyMMdd-HHmmss.json
/// <library>/Calendar/2026-11-16/14.00 Physics Lecture/.ithil-event
/// <safety directory>/<library id>/<calendar id>.json
/// ```
///
/// events.json is saved by a `DocumentStore`, with Ithil's backups, the safety copy and recovery. The
/// `Calendar` folder is made the first time the calendar opens, never through a link, and never in a
/// read-only library. All disk work happens on the actor.
public actor CalendarStore {
    /// `<library>/Calendar`
    public nonisolated let folder: URL
    /// The event folders, rooted at `folder`.
    public nonisolated let eventFolders: EventFolders

    private let libraryRoot: URL
    private let knownCalendarID: UUID?
    private let fileSystem: any FileSystem
    private let store: DocumentStore<CalendarDocument>
    private var isReadOnly = false
    private let log = CoreLog(category: "CalendarStore")

    /// - Parameters:
    ///   - libraryRoot: The library folder.
    ///   - libraryID: The library's id: the calendar's safety copy lives beside its spaces'.
    ///   - safetyDirectory: Where safety copies live, e.g. Application Support/Elenath/SafetyCopies, as
    ///     given to `LibraryCatalog`.
    ///   - knownCalendarID: The calendar's id from library.json (`CalendarSettings.calendarID`), to find
    ///     its safety copy when its own files are gone.
    public init(
        libraryRoot: URL,
        libraryID: LibraryID,
        safetyDirectory: URL,
        knownCalendarID: UUID?,
        fileSystem: any FileSystem,
        timeSource: any TimeSource,
        backupInterval: TimeInterval = 15 * 60,
        maxBackups: Int = 50
    ) {
        self.libraryRoot = libraryRoot
        self.knownCalendarID = knownCalendarID
        self.fileSystem = fileSystem
        let folder = LibraryLayout.calendarFolder(in: libraryRoot)
        self.folder = folder
        eventFolders = EventFolders(root: folder, fileSystem: fileSystem)
        store = DocumentStore(
            owner: folder, metadataFolderName: LibraryLayout.calendarMetadataFolderName,
            safetyDirectory: LibraryLayout.safetyDirectory(of: libraryID, in: safetyDirectory),
            knownDocumentID: knownCalendarID, fileSystem: fileSystem, timeSource: timeSource,
            backupInterval: backupInterval, maxBackups: maxBackups)
    }

    /// Opens the calendar.
    ///
    /// The first time, makes the `Calendar` folder and an empty calendar in it. A missing or damaged
    /// events.json comes back from a backup or the safety copy (`DocumentStore.load()`); with nothing to
    /// bring it back from, an empty calendar is started and `startedOverLostFile` says so. A file from a
    /// newer version opens read-only.
    ///
    /// With `readOnly` (a library from a newer Elenath) nothing is made, recovered or written: the
    /// calendar is read as it is, and a missing one reads as empty.
    ///
    /// Throws `CalendarStoreError.nameTakenBySpace` while a space from Elenath 0.1 is called "Calendar",
    /// `.notAFolder` for a link or a file, `DocumentStoreError.missing` when the library folder is gone,
    /// and `DocumentStoreError.unreadable` when events.json is damaged and nothing could be recovered.
    public func load(readOnly: Bool = false) async throws -> CalendarLoad {
        isReadOnly = readOnly
        guard fileSystem.isDirectory(at: libraryRoot) else { throw DocumentStoreError.missing }
        if let info = fileSystem.info(at: folder) {
            guard info.isDirectory, !info.isSymbolicLink else { throw CalendarStoreError.notAFolder }
            if holdsSpaceFromOlderVersion() {
                throw CalendarStoreError.nameTakenBySpace
            }
        } else if !readOnly {
            try fileSystem.createDirectory(at: folder)
        }
        guard !fileSystem.fileExists(at: folder) || PathContainment.isStrictlyInside(folder, folder: libraryRoot)
        else { throw CalendarStoreError.notAFolder }

        if readOnly {
            return try readAsItIs()
        }
        do {
            let load = try await store.load()
            return CalendarLoad(
                document: load.document, recovery: load.recovery, isReadOnly: false, isNew: false,
                startedOverLostFile: false)
        } catch DocumentStoreError.missing {
            let lostFile = holdsEarlierCalendar()
            let document = CalendarDocument(id: knownCalendarID ?? UUID())
            try await store.create(document)
            if lostFile {
                log.error("events.json was missing and nothing could bring it back; started an empty calendar")
            }
            return CalendarLoad(
                document: document, recovery: nil, isReadOnly: false, isNew: true, startedOverLostFile: lostFile)
        } catch DocumentStoreError.newerSchema {
            isReadOnly = true
            log.notice("events.json is from a newer version; opening the calendar read-only")
            return try readAsItIs()
        }
    }

    /// Saves the calendar (`DocumentStore.save(_:)`). Throws `DocumentStoreError.readOnly` when it was
    /// opened read-only.
    public func save(_ document: CalendarDocument) async throws {
        guard !isReadOnly else { throw DocumentStoreError.readOnly }
        try await store.save(document)
    }

    // MARK: - Private

    /// A space folder from Elenath 0.1 called "Calendar": it has `.space` and no `.ithil`.
    private func holdsSpaceFromOlderVersion() -> Bool {
        let space = LibraryLayout.spaceMetadataFolder(in: folder)
        let calendar = LibraryLayout.calendarMetadataFolder(in: libraryRoot)
        return fileSystem.info(at: space) != nil && fileSystem.info(at: calendar) == nil
    }

    /// Whether the folder shows that a calendar was here before: event folders, or backups of events.json.
    private func holdsEarlierCalendar() -> Bool {
        let backups = LibraryLayout.calendarMetadataFolder(in: libraryRoot).appending(
            component: LibraryLayout.backupsFolderName, directoryHint: .isDirectory)
        if let contents = try? fileSystem.contentsOfDirectory(at: backups), !contents.isEmpty {
            return true
        }
        let contents = (try? fileSystem.contentsOfDirectory(at: folder)) ?? []
        return contents.contains { !$0.lastPathComponent.hasPrefix(".") }
    }

    /// events.json read as it is, without recovering or writing anything: for a read-only library, and
    /// for a file from a newer version (read as far as this version understands it). Missing reads as an
    /// empty calendar; a file that can't be read at all throws `unreadable`.
    private func readAsItIs() throws -> CalendarLoad {
        let metadata = LibraryLayout.calendarMetadataFolder(in: libraryRoot)
        // `.ithil` must be the calendar's own folder, as the writing path requires: never read through a link.
        if let info = fileSystem.info(at: metadata), !info.isDirectory || info.isSymbolicLink {
            throw CalendarStoreError.notAFolder
        }
        let file = metadata.appending(component: CalendarDocument.fileName, directoryHint: .notDirectory)
        guard fileSystem.fileExists(at: file) else {
            return CalendarLoad(
                document: CalendarDocument(id: knownCalendarID ?? UUID()), recovery: nil, isReadOnly: true,
                isNew: false, startedOverLostFile: false)
        }
        let data = try fileSystem.readData(at: file)
        let document: CalendarDocument
        do {
            document = try DocumentCodec.decode(CalendarDocument.self, from: data).document
        } catch DocumentStoreError.newerSchema {
            guard DocumentCodec.isSafeToParse(data, maximumByteCount: CalendarDocument.maximumByteCount) else {
                throw DocumentStoreError.unreadable("events.json is too large, or nested too deeply")
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let newer = try? decoder.decode(CalendarDocument.self, from: data) else {
                throw DocumentStoreError.unreadable("events.json is from a newer version and can't be shown")
            }
            document = newer
        }
        return CalendarLoad(
            document: document, recovery: nil, isReadOnly: true, isNew: false, startedOverLostFile: false)
    }
}
