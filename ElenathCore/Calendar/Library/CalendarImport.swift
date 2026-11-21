import Foundation

/// Why an Ithil folder couldn't be brought in.
public enum CalendarImportError: Error, Equatable, Sendable {
    /// The folder holds no Ithil calendar: no `.ithil/events.json` and no backup of one.
    case notAnIthilFolder
    /// The folder's events.json was written by a newer Ithil.
    case newerSchema(found: Int, supported: Int)
    /// events.json and every backup of it are damaged.
    case unreadable
    /// The folder is the library, is inside it, or holds it: nothing would come in from outside.
    case insideLibrary
}

/// What bringing in an Ithil calendar did, and what the check afterwards found.
public struct CalendarImportReport: Hashable, Sendable {
    /// What the Ithil folder holds.
    public var subjectsInSource = 0
    public var eventsInSource = 0
    /// Folders in the Ithil folder's day folders: one per event occurrence that has files.
    public var foldersInSource = 0
    /// The files in the day folders and event folders, hidden ones included (a project's `.git`, an
    /// `.env`). Left behind, and not counted: Ithil's markers (written anew), the system's `.DS_Store`,
    /// AppleDouble (`._…`) and custom-icon files, and copies that never finished.
    public var filesInSource = 0

    /// Brought in this time.
    public var subjectsAdded = 0
    public var eventsAdded = 0
    public var filesCopied = 0

    /// Already in Elenath's calendar and left alone: from an earlier run, or (for a subject) one of the
    /// same name that the calendar already had.
    public var subjectsAlreadyThere = 0
    public var eventsAlreadyThere = 0
    public var filesAlreadyThere = 0

    /// The Ithil folder's events.json was damaged or missing, and its newest readable backup was used.
    public var readFromBackup = false
    /// Files of the Ithil folder (paths inside it) that aren't in the calendar after copying. Names of the
    /// user's files: shown to the user, never logged in the open.
    public var missingFiles: [String] = []

    public init() {}

    /// Whether everything in the Ithil folder is in Elenath's calendar now: every subject, every event and
    /// every file.
    public var countsMatch: Bool {
        missingFiles.isEmpty && subjectsAdded + subjectsAlreadyThere == subjectsInSource
            && eventsAdded + eventsAlreadyThere == eventsInSource
            && filesCopied + filesAlreadyThere == filesInSource
    }
}

/// The calendar with the Ithil folder's subjects and events merged in, the Ithil folder's calendar as it was
/// read, and the report.
public struct CalendarImportResult: Hashable, Sendable {
    /// The calendar `run` was given, with the Ithil folder's subjects and events merged in.
    public var document: CalendarDocument
    /// The Ithil folder's calendar as it was read. The app merges this, and only this, into the calendar as
    /// it is once the files are copied (`merge(_:into:)`), so nothing deleted meanwhile comes back.
    public var source: CalendarDocument
    public var report: CalendarImportReport

    public init(document: CalendarDocument, source: CalendarDocument, report: CalendarImportReport) {
        self.document = document
        self.source = source
        self.report = report
    }
}

/// "Bring in my Ithil calendar" (docs/ARCHITECTURE.md, "Bringing in an Ithil calendar").
///
/// - **The Ithil folder is only read.** Nothing is created, changed, recovered or migrated inside it, and
///   links in it are never followed, `.ithil` and its `backups` included.
/// - **Copy, never move or overwrite.** Event folders are copied into the calendar's folder (and nowhere
///   else in the library), file by file under a hidden name until each is complete (`FileCopier`), each
///   under its own name, hidden ones included. Each event folder gets its marker: read from Ithil's and
///   written anew, or, for a folder Ithil never marked, the marker of the one occurrence whose folder it
///   is. A file that is already there is left alone, so running it again brings in nothing twice.
/// - **Merge by id.** A subject or event whose id the calendar already has is left alone. A subject
///   that the calendar already had under the same name is used instead of a second one of that name.
/// - **Check.** Afterwards every file of the Ithil folder is looked for in the calendar, and the counts
///   are compared.
public enum CalendarImport {
    /// Reads the Ithil folder's calendar, copies its event folders into `calendarFolder` and returns
    /// `calendar` with its subjects and events merged in. The app saves the returned document.
    ///
    /// A file that can't be copied is listed in `missingFiles` and the rest go on. Throws
    /// `CancellationError` when cancelled (files already copied stay, and a later run brings in the rest),
    /// and `CalendarImportError` when the folder can't be brought in at all.
    public static func run(
        from ithilFolder: URL,
        into calendar: CalendarDocument,
        calendarFolder: URL,
        libraryRoot: URL,
        eventFolders: EventFolders,
        fileSystem: any FileSystem,
        progress: @escaping @Sendable (FileCopyProgress) -> Void = { _ in }
    ) async throws -> CalendarImportResult {
        let source = ithilFolder.standardizedFileURL
        guard !PathContainment.contains(source, in: libraryRoot), !PathContainment.contains(libraryRoot, in: source)
        else { throw CalendarImportError.insideLibrary }

        var report = CalendarImportReport()
        let (ithil, fromBackup) = try readCalendar(in: source, fileSystem: fileSystem)
        report.readFromBackup = fromBackup
        let document = merge(ithil, into: calendar, report: &report)

        let plan = await planCopies(
            from: source, calendar: ithil, into: calendarFolder, eventFolders: eventFolders, fileSystem: fileSystem)
        report.foldersInSource = plan.folderCount
        report.filesInSource = plan.files.count
        try await copy(
            plan, calendarFolder: calendarFolder, fileSystem: fileSystem, report: &report, progress: progress)
        await eventFolders.reindex()
        return CalendarImportResult(document: document, source: ithil, report: report)
    }

    /// `result` merged into the calendar as it is now, which may have changed while the files were copied:
    /// only the Ithil folder's subjects and events are merged, so nothing deleted meanwhile comes back. The
    /// report's subject and event counts are counted again against `current`; its file counts stay.
    public static func merge(_ result: CalendarImportResult, into current: CalendarDocument) -> CalendarImportResult {
        var report = result.report
        report.subjectsAdded = 0
        report.subjectsAlreadyThere = 0
        report.eventsAdded = 0
        report.eventsAlreadyThere = 0
        let document = merge(result.source, into: current, report: &report)
        return CalendarImportResult(document: document, source: result.source, report: report)
    }

    // MARK: - Reading the Ithil folder

    /// The newest calendar the folder holds: its events.json, or the newest backup that can be read when
    /// that is damaged or missing.
    static func readCalendar(in folder: URL, fileSystem: any FileSystem) throws -> (CalendarDocument, Bool) {
        let metadata = folder.appending(
            component: LibraryLayout.calendarMetadataFolderName, directoryHint: .isDirectory)
        // `.ithil` must be the folder's own: a link to another folder's would bring in someone else's calendar.
        guard isRealFolder(metadata, fileSystem: fileSystem) else { throw CalendarImportError.notAnIthilFolder }
        let file = metadata.appending(component: CalendarDocument.fileName, directoryHint: .notDirectory)
        var foundSomething = false
        if let data = readRegularFile(file, fileSystem: fileSystem) {
            foundSomething = true
            do {
                return (try DocumentCodec.decode(CalendarDocument.self, from: data).document, false)
            } catch DocumentStoreError.newerSchema(let found, let supported) {
                throw CalendarImportError.newerSchema(found: found, supported: supported)
            } catch {
                // Damaged: look at the backups.
            }
        }
        let backups = metadata.appending(component: LibraryLayout.backupsFolderName, directoryHint: .isDirectory)
        var newest: DecodedDocument<CalendarDocument>?
        let names =
            isRealFolder(backups, fileSystem: fileSystem)
            ? ((try? fileSystem.contentsOfDirectory(at: backups)) ?? []).map(\.lastPathComponent) : []
        for name in names where name.hasPrefix(CalendarDocument.backupPrefix) && name.hasSuffix(".json") {
            let url = backups.appending(component: name, directoryHint: .notDirectory)
            guard let data = readRegularFile(url, fileSystem: fileSystem) else { continue }
            foundSomething = true
            guard let decoded = try? DocumentCodec.decode(CalendarDocument.self, from: data) else { continue }
            if newest == nil || (decoded.savedAt ?? .distantPast) > (newest?.savedAt ?? .distantPast) {
                newest = decoded
            }
        }
        if let newest {
            return (newest.document, true)
        }
        throw foundSomething ? CalendarImportError.unreadable : CalendarImportError.notAnIthilFolder
    }

    /// A regular file's bytes, when it is one (not a link, folder or special file) and not too large to be
    /// a calendar.
    private static func readRegularFile(_ url: URL, fileSystem: any FileSystem) -> Data? {
        guard let info = fileSystem.info(at: url), !info.isDirectory, !info.isSymbolicLink, !info.isSpecial,
            info.byteCount <= Int64(CalendarDocument.maximumByteCount)
        else { return nil }
        return try? fileSystem.readData(at: url)
    }

    // MARK: - Merging

    /// `calendar` with the subjects and events of `ithil` that it doesn't have yet (by id, or for a subject
    /// by name). Counts into `report`'s subject and event numbers.
    public static func merge(
        _ ithil: CalendarDocument, into calendar: CalendarDocument, report: inout CalendarImportReport
    ) -> CalendarDocument {
        var merged = calendar
        report.subjectsInSource = ithil.subjects.count
        report.eventsInSource = ithil.events.count

        var subjectIDs = Set(calendar.subjects.map(\.id))
        var sameNamed: [UUID: UUID] = [:]
        for subject in ithil.subjects {
            if subjectIDs.contains(subject.id) {
                report.subjectsAlreadyThere += 1
            } else if let existing = calendar.subjects.first(where: {
                NameSanitizer.key($0.name) == NameSanitizer.key(subject.name)
            }) {
                sameNamed[subject.id] = existing.id
                report.subjectsAlreadyThere += 1
            } else {
                merged.subjects.append(subject)
                subjectIDs.insert(subject.id)
                report.subjectsAdded += 1
            }
        }

        var eventIDs = Set(calendar.events.map(\.id))
        for var event in ithil.events {
            guard !eventIDs.contains(event.id) else {
                report.eventsAlreadyThere += 1
                continue
            }
            if let subject = event.subjectID, let existing = sameNamed[subject] {
                event.subjectID = existing
            }
            merged.events.append(event)
            eventIDs.insert(event.id)
            report.eventsAdded += 1
        }
        return merged
    }

    // MARK: - Copying the event folders

    struct CopyPlan {
        struct File {
            var source: URL
            /// The folder the file goes into, inside the calendar's folder.
            var folder: URL
            var relativePath: String
        }

        var files: [File] = []
        /// The markers to write into event folders that don't have one yet.
        var markers: [(folder: URL, marker: EventFolderMarker)] = []
        var folderCount = 0
    }

    /// Every file to bring in, with the folder it goes into. An event folder goes into the calendar's
    /// folder for the same occurrence when there is one (found by its marker, wherever it was renamed to),
    /// else under its own name in the same day folder, or the next free name when that is another's. A
    /// folder without a marker belongs to the one occurrence of `calendar` whose folder it is, if there is
    /// exactly one.
    static func planCopies(
        from source: URL, calendar: CalendarDocument, into calendarFolder: URL, eventFolders: EventFolders,
        fileSystem: any FileSystem
    ) async -> CopyPlan {
        var plan = CopyPlan()
        let existing = await eventFolders.markedFolders()
        var claimed = Set(existing.values.map(\.standardizedFileURL))
        let days = ((try? fileSystem.contentsOfDirectory(at: source)) ?? [])
            .filter { isDayFolderName($0.lastPathComponent) && isRealFolder($0, fileSystem: fileSystem) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for day in days {
            let dayName = day.lastPathComponent
            let destinationDay = calendarFolder.appending(component: dayName, directoryHint: .isDirectory)
            for item in sortedContents(of: day, fileSystem: fileSystem) {
                let name = item.lastPathComponent
                guard !isLeftBehind(name), let info = fileSystem.info(at: item), !info.isSymbolicLink,
                    !info.isSpecial
                else { continue }
                if !info.isDirectory {
                    plan.files.append(
                        CopyPlan.File(source: item, folder: destinationDay, relativePath: "\(dayName)/\(name)"))
                    continue
                }
                plan.folderCount += 1
                let marker =
                    EventFolderMarker.read(in: item, fileSystem: fileSystem)
                    ?? marker(forFolderNamed: name, inDay: dayName, of: calendar)
                let destination = destinationFolder(
                    for: item, marker: marker, in: destinationDay, existing: existing, claimed: &claimed,
                    fileSystem: fileSystem)
                if let marker, EventFolderMarker.read(in: destination, fileSystem: fileSystem) == nil {
                    plan.markers.append((destination, marker))
                }
                addTree(
                    item, into: destination, relativePath: "\(dayName)/\(name)", depth: 1, plan: &plan,
                    fileSystem: fileSystem)
            }
        }
        return plan
    }

    /// The marker of the one occurrence of `calendar` whose folder is `<dayName>/<name>`, for a folder
    /// Ithil never marked (one the user made in Finder). Nil when no occurrence or more than one has that
    /// folder.
    static func marker(
        forFolderNamed name: String, inDay dayName: String, of calendar: CalendarDocument
    )
        -> EventFolderMarker?
    {
        guard let day = CalendarDate(isoString: dayName), day.isValid else { return nil }
        // A day in any time zone lies inside the same date ± 2 days in UTC; the folder names decide.
        let window = DateInterval(start: day.adding(days: -2).start(in: .gmt), end: day.adding(days: 3).start(in: .gmt))
        let key = NameSanitizer.key(name)
        let owners = OccurrenceExpander(displayTimeZone: .gmt).occurrences(of: calendar.events, in: window).filter {
            FolderNaming.dayFolderName(for: $0) == dayName
                && NameSanitizer.key(FolderNaming.eventFolderName(for: $0)) == key
        }
        guard owners.count == 1, let owner = owners.first else { return nil }
        return EventFolderMarker(occurrence: owner)
    }

    /// Where an event folder of the Ithil folder goes.
    private static func destinationFolder(
        for folder: URL, marker: EventFolderMarker?, in destinationDay: URL, existing: [Occurrence.ID: URL],
        claimed: inout Set<URL>, fileSystem: any FileSystem
    ) -> URL {
        if let marker, let found = existing[marker.occurrenceID] {
            return found
        }
        let name = folder.lastPathComponent
        let sameName = destinationDay.appending(component: name, directoryHint: .isDirectory)
        let free: Bool
        if let info = fileSystem.info(at: sameName) {
            // The same occurrence's folder (unmarked ones are the user's own and are merged), never another's.
            let other = EventFolderMarker.read(in: sameName, fileSystem: fileSystem)
            free =
                info.isDirectory && !info.isSymbolicLink && (other == nil || other == marker)
                && !claimed.contains(sameName.standardizedFileURL)
        } else {
            free = !claimed.contains(sameName.standardizedFileURL)
        }
        if free {
            claimed.insert(sameName.standardizedFileURL)
            return sameName
        }
        let taken = Set(
            ((try? fileSystem.contentsOfDirectory(at: destinationDay)) ?? []).map {
                NameSanitizer.key($0.lastPathComponent)
            })
        let freeName = UniqueName.available(name) { candidate in
            taken.contains(NameSanitizer.key(candidate))
                || claimed.contains(destinationDay.appending(component: candidate).standardizedFileURL)
        }
        let destination = destinationDay.appending(component: freeName, directoryHint: .isDirectory)
        claimed.insert(destination.standardizedFileURL)
        return destination
    }

    /// Adds every file in `folder` (folders inside it included, hidden ones too, apart from what
    /// `isLeftBehind` names), never through a link.
    private static func addTree(
        _ folder: URL, into destination: URL, relativePath: String, depth: Int, plan: inout CopyPlan,
        fileSystem: any FileSystem
    ) {
        guard depth < FileCopier.maximumFolderDepth else { return }
        for item in sortedContents(of: folder, fileSystem: fileSystem) {
            let name = item.lastPathComponent
            guard !isLeftBehind(name), let info = fileSystem.info(at: item), !info.isSymbolicLink, !info.isSpecial
            else { continue }
            let path = "\(relativePath)/\(name)"
            if info.isDirectory {
                addTree(
                    item, into: destination.appending(component: name, directoryHint: .isDirectory),
                    relativePath: path, depth: depth + 1, plan: &plan, fileSystem: fileSystem)
            } else {
                plan.files.append(CopyPlan.File(source: item, folder: destination, relativePath: path))
            }
        }
    }

    /// Copies every planned file that isn't there yet, then looks for each one. Everything is written inside
    /// the calendar's folder, never elsewhere in the library, even through a link planted in it.
    private static func copy(
        _ plan: CopyPlan, calendarFolder: URL, fileSystem: any FileSystem, report: inout CalendarImportReport,
        progress: @escaping @Sendable (FileCopyProgress) -> Void
    ) async throws {
        let log = CoreLog(category: "CalendarImport")
        // Markers first, so a folder is found by its marker even if copying its files stops halfway.
        for (folder, marker) in plan.markers {
            do {
                try createFolders(folder, under: calendarFolder, fileSystem: fileSystem)
                let file = folder.appending(component: EventFolderMarker.fileName, directoryHint: .notDirectory)
                if fileSystem.info(at: file) == nil {
                    try fileSystem.writeAtomically(marker.markerFileData(), to: file)
                }
            } catch {
                log.error("An event folder couldn't be made", private: "\(folder.lastPathComponent): \(error)")
            }
        }
        let pending = plan.files.filter { file in
            !fileSystem.fileExists(at: file.folder.appending(component: file.source.lastPathComponent))
        }
        let sizes = pending.map { fileSystem.info(at: $0.source)?.byteCount ?? 0 }
        var state = FileCopyProgress(totalBytes: sizes.reduce(0, +), totalFiles: pending.count)
        progress(state)
        var failed = Set<String>()
        for (index, file) in pending.enumerated() {
            try Task.checkCancellation()
            do {
                try createFolders(file.folder, under: calendarFolder, fileSystem: fileSystem)
                let base = state
                _ = try await FileCopier.copy(
                    [file.source], into: file.folder, root: calendarFolder, fileSystem: fileSystem, naming: .exact
                ) { step in
                    var combined = base
                    combined.completedBytes = base.completedBytes + step.completedBytes
                    combined.currentName = step.currentName
                    progress(combined)
                }
                report.filesCopied += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failed.insert(file.relativePath)
                log.error("A file couldn't be brought in", private: "\(file.relativePath): \(error)")
            }
            state.completedBytes += sizes[index]
            state.completedFiles += 1
            progress(state)
        }
        state.currentName = nil
        progress(state)

        let copiedNow = Set(pending.map(\.relativePath)).subtracting(failed)
        for file in plan.files {
            let target = file.folder.appending(component: file.source.lastPathComponent)
            if !fileSystem.fileExists(at: target) {
                report.missingFiles.append(file.relativePath)
            } else if !copiedNow.contains(file.relativePath) {
                report.filesAlreadyThere += 1
            }
        }
    }

    /// Creates `folder` and the folders above it inside `root`, refusing a path that leads outside it.
    private static func createFolders(_ folder: URL, under root: URL, fileSystem: any FileSystem) throws {
        guard PathContainment.isStrictlyInside(folder, folder: root) else {
            throw FileCopyError.outsideLibrary
        }
        if let info = fileSystem.info(at: folder), !info.isDirectory || info.isSymbolicLink {
            throw FileCopyError.noSuchFolder
        }
        try fileSystem.createDirectory(at: folder)
    }

    // MARK: - Helpers

    /// What isn't brought in: Ithil's markers (written anew), the system's `.DS_Store`, AppleDouble files
    /// (`._…`, metadata from other file systems), custom-icon files and copies that never finished. Every
    /// other file comes along, hidden or not.
    static func isLeftBehind(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        return lowercased == EventFolderMarker.fileName.lowercased() || lowercased == ".ds_store"
            || name.hasPrefix("._") || name == "Icon\r" || lowercased.hasPrefix(".ithil-copying-")
            || lowercased.hasPrefix(FileCopier.temporaryNamePrefix)
    }

    /// "2026-11-16": a day folder of Ithil's.
    static func isDayFolderName(_ name: String) -> Bool {
        guard name.count == 10, let date = CalendarDate(isoString: name) else { return false }
        return date.isValid && date.isoString == name
    }

    private static func isRealFolder(_ url: URL, fileSystem: any FileSystem) -> Bool {
        guard let info = fileSystem.info(at: url) else { return false }
        return info.isDirectory && !info.isSymbolicLink
    }

    private static func sortedContents(of folder: URL, fileSystem: any FileSystem) -> [URL] {
        ((try? fileSystem.contentsOfDirectory(at: folder)) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
