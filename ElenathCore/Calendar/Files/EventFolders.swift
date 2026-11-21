import Foundation

/// Why an event folder operation was refused.
public enum EventFoldersError: Error, Equatable, Sendable {
    /// A path Ithil was about to write to (or move or trash) is not inside the library root, for example
    /// because a day folder is a symbolic link to somewhere else. Nothing was changed. The text is the
    /// path, for logs (it contains file names, so log it as private).
    case outsideRoot(String)
    /// Something Ithil needs as a folder is missing or is a file: the library root itself (a moved
    /// folder or an unplugged drive; it is never recreated) or a day folder's name taken by a file.
    case notADirectory(String)
}

/// Finds, creates, lists, renames and trashes event folders.
///
/// ```
/// <root>/2026-10-06/14.00 Physics Lecture/
/// <root>/2026-10-06/14.00 Physics Lecture/.ithil-event      (EventFolderMarker: event ID + occurrence date)
/// ```
///
/// - The folder is the source of truth for an event's files. Folders are created only by
///   `ensureFolder(for:)`, which the app calls when the first file arrives; lookups never create one.
/// - Every folder carries a marker, so a folder renamed (or moved to another day folder) in Finder is still
///   found. Markers are indexed by scanning `<root>/<yyyy-MM-dd>/*/.ithil-event`; `reindex()` rescans
///   everything. A lookup that misses refreshes only what changed since the last scan (judged by
///   modification dates): after a change in the root itself (day folders came or went), every day folder
///   that changed; otherwise just the occurrence's own day folder, if it changed. A stale entry (the
///   folder moved again) always refreshes. So a marked folder copied in while Ithil runs is found by the
///   next lookup when it lands in a new day folder or its own one, and anywhere after `reindex()`.
/// - Nothing is ever written outside the root: every create, write, move and trash checks `contains(_:)`
///   first (symbolic links resolved), so a link inside the root that points elsewhere is never written
///   through. Folders reached through such a link, and links in place of event folders, are ignored.
/// - Nothing is deleted permanently: event folders go to the Trash. The only removals are of folders
///   that are completely empty (a day folder left behind, or a folder this actor just made when writing
///   its marker failed), done with `rmdir`, which refuses a folder with anything in it. A trashed folder can
///   be put back where it belongs (`restoreFolder(from:for:)`), so Undo brings back an event's files too.
///
/// All disk work runs on the actor, off the caller's thread.
public actor EventFolders {
    /// The library root (the folder that contains `.ithil`).
    public nonisolated let root: URL

    private let fileSystem: any FileSystem
    private let logger = CoreLog(category: "EventFolders")

    /// What the last scan of each day folder found, by day folder name.
    private var dayScans: [String: EventFoldersDayScan] = [:]
    /// Marker → folder, built from `dayScans`. On duplicates (a folder copied in Finder) the first by
    /// day and folder name wins; the folder at an occurrence's expected path always wins over the index.
    private var index: [Occurrence.ID: URL] = [:]
    /// The root's modification date at the last full listing; a change means day folders came or went.
    private var scannedRootModified: Date?
    private var hasScanned = false

    /// The highest clash suffix tried (" 2" … " 999") before giving up.
    private static let maximumSuffix = 999

    public init(root: URL, fileSystem: any FileSystem) {
        self.root = root
        self.fileSystem = fileSystem
    }

    // MARK: - Finding

    /// The occurrence's folder if one exists, or nil.
    ///
    /// The expected path (`FolderNaming.relativePath(for:)`) wins when its marker names this occurrence.
    /// Otherwise the folder is looked up in the marker index, wherever it was renamed or moved to. A
    /// folder at the expected path without a marker (made by the user) is adopted by writing one, unless
    /// the occurrence already has a marked folder elsewhere (for example one that got a " 2" because
    /// the user's folder held the name). Never creates a folder.
    public func existingFolder(for occurrence: Occurrence) -> URL? {
        let id = occurrence.id
        let expected = expectedFolder(for: occurrence)
        let dayName = FolderNaming.dayFolderName(for: occurrence)
        switch state(of: expected) {
        case .marked(let found) where found == id:
            if isStrictlyInsideRoot(expected) {
                return expected
            }
        case .unmarked:
            if let marked = indexedFolder(for: id, dayName: dayName) {
                return marked
            }
            if isStrictlyInsideRoot(expected) {
                adopt(expected, for: occurrence)
                return expected
            }
            return nil
        case .absent, .marked, .notAFolder:
            break
        }
        return indexedFolder(for: id, dayName: dayName)
    }

    /// The occurrence's existing folder, or a new one at its expected path with its marker.
    ///
    /// When that name is taken by another event's folder or by something that isn't an Ithil folder, the
    /// new folder gets " 2", " 3"… like Finder. Creates the day folder if needed, but never the root:
    /// throws `notADirectory` if the root is missing.
    public func ensureFolder(for occurrence: Occurrence) throws -> URL {
        if let existing = existingFolder(for: occurrence) {
            return existing
        }
        guard fileSystem.isDirectory(at: root) else {
            throw EventFoldersError.notADirectory(root.path)
        }
        let dayName = FolderNaming.dayFolderName(for: occurrence)
        let day = dayFolder(named: dayName)
        let createdDay = try createDayFolderIfNeeded(day)
        do {
            let folder = try createEventFolder(for: occurrence, in: day)
            rescanDays([dayName])
            return folder
        } catch {
            if createdDay {
                removeIfCompletelyEmpty(day)
            }
            throw error
        }
    }

    // MARK: - Listing

    /// The visible items in the occurrence's folder (not its marker, dotfiles or `.DS_Store`), sorted
    /// like Finder sorts names. Empty when there is no folder or it can't be read.
    public func files(for occurrence: Occurrence) -> [EventFile] {
        guard let folder = existingFolder(for: occurrence) else { return [] }
        var files: [EventFile] = []
        for name in visibleNames(in: folder) {
            let isDirectory = fileSystem.isDirectory(at: folder.appending(component: name))
            let url = folder.appending(component: name, directoryHint: isDirectory ? .isDirectory : .notDirectory)
            let byteCount = EventFoldersDisk.byteCount(of: url, isDirectory: isDirectory)
            let modified = fileSystem.modificationDate(at: url)
            files.append(
                EventFile(url: url, name: name, byteCount: byteCount, modified: modified, isDirectory: isDirectory))
        }
        return files.sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.name < rhs.name : order == .orderedAscending
        }
    }

    /// How many items `files(for:)` would list, without measuring them.
    public func fileCount(for occurrence: Occurrence) -> Int {
        guard let folder = existingFolder(for: occurrence) else { return 0 }
        return visibleNames(in: folder).count
    }

    // MARK: - Renaming, moving and trashing

    /// Moves the folder of `old` to where `new` expects it, after an event's title or time changed.
    ///
    /// Creates the new day folder if needed and adds " 2", " 3"… when the name is taken by something
    /// else. The marker is rewritten when the occurrence changed (another date, or another event, as
    /// when one occurrence is detached from its series). A title change that differs only in case is a
    /// plain rename. When the expected path didn't change, a folder renamed in Finder keeps its name.
    /// Afterwards the old day folder is removed if it is completely empty (not even a `.DS_Store`).
    ///
    /// Returns the folder's new URL, or nil when `old` had no folder. On failure nothing has moved.
    @discardableResult
    public func relocate(from old: Occurrence, to new: Occurrence) throws -> URL? {
        guard let current = existingFolder(for: old) else { return nil }
        guard isStrictlyInsideRoot(current) else {
            throw EventFoldersError.outsideRoot(current.path)
        }
        let oldDay = current.deletingLastPathComponent()
        let newDayName = FolderNaming.dayFolderName(for: new)
        let newDay = dayFolder(named: newDayName)
        let needsMarker = readMarker(in: current)?.occurrenceID != new.id

        var target = current
        if FolderNaming.relativePath(for: old) != FolderNaming.relativePath(for: new) {
            target = try relocationTarget(for: current, in: newDay, for: new)
        }
        let moves = target.path != current.path
        guard !moves || isStrictlyInsideRoot(target) else {
            throw EventFoldersError.outsideRoot(target.path)
        }

        if needsMarker {
            try writeMarker(EventFolderMarker(occurrence: new), in: current)
        }
        if moves {
            do {
                let createdDay = try createDayFolderIfNeeded(newDay)
                do {
                    try moveFolder(current, to: target)
                } catch {
                    if createdDay {
                        removeIfCompletelyEmpty(newDay)
                    }
                    throw error
                }
            } catch {
                if needsMarker {
                    try? writeMarker(EventFolderMarker(occurrence: old), in: current)
                }
                rescanDays([oldDay.lastPathComponent, newDayName])
                throw error
            }
            if oldDay.path != newDay.path {
                removeDayFolderIfCompletelyEmpty(oldDay)
            }
        }
        rescanDays([oldDay.lastPathComponent, newDayName])
        return target
    }

    /// Moves the occurrence's folder to the Trash; never deletes it. Does nothing when there is none.
    /// Its day folder is removed afterwards if that is now completely empty.
    ///
    /// Returns where the folder is in the Trash now, for `restoreFolder(from:for:)`; nil when there was no
    /// folder, or when the file system can't tell.
    @discardableResult
    public func trashFolder(for occurrence: Occurrence) throws -> URL? {
        guard let folder = existingFolder(for: occurrence) else { return nil }
        guard isStrictlyInsideRoot(folder) else {
            throw EventFoldersError.outsideRoot(folder.path)
        }
        let day = folder.deletingLastPathComponent()
        let trashed = try fileSystem.trashItemReturningURL(at: folder)
        removeDayFolderIfCompletelyEmpty(day)
        rescanDays([day.lastPathComponent])
        return trashed
    }

    /// Puts a folder that `trashFolder(for:)` moved to the Trash back at the occurrence's expected path,
    /// e.g. when the user undoes deleting the event. Returns the folder's new URL.
    ///
    /// - `trashed` must be a folder (not a symbolic link) whose marker names `occurrence`; anything else
    ///   is left alone and this throws `CocoaError(.fileNoSuchFile)`: the folder that was trashed is no
    ///   longer there.
    /// - The occurrence must not have a folder already, so two folders never claim one occurrence:
    ///   otherwise this throws `CocoaError(.fileWriteFileExists)`.
    /// - Creates the day folder if needed, but never the root (`notADirectory` if it is missing). When the
    ///   folder's name is taken, it gets " 2", " 3"… like Finder. Every place written to is checked to be
    ///   inside the root first (`outsideRoot`).
    ///
    /// On failure the folder stays where it was, in the Trash.
    public func restoreFolder(from trashed: URL, for occurrence: Occurrence) throws -> URL {
        let isTrashedFolder = fileSystem.isDirectory(at: trashed) && !EventFoldersDisk.isSymbolicLink(trashed)
        guard isTrashedFolder, readMarker(in: trashed)?.occurrenceID == occurrence.id else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSURLErrorKey: trashed])
        }
        // Never move the root, or a folder that holds it, into the root.
        guard let rootComponents = EventFoldersDisk.resolvedComponents(of: root),
            let trashedComponents = EventFoldersDisk.resolvedComponents(of: trashed),
            !rootComponents.starts(with: trashedComponents)
        else {
            throw EventFoldersError.outsideRoot(trashed.path)
        }
        guard fileSystem.isDirectory(at: root) else {
            throw EventFoldersError.notADirectory(root.path)
        }
        let dayName = FolderNaming.dayFolderName(for: occurrence)
        if let existing = folderClaiming(occurrence, dayName: dayName) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSURLErrorKey: existing])
        }
        let day = dayFolder(named: dayName)
        let createdDay = try createDayFolderIfNeeded(day)
        do {
            let target = try freeFolderName(for: occurrence, in: day)
            guard isStrictlyInsideRoot(target) else {
                throw EventFoldersError.outsideRoot(target.path)
            }
            try fileSystem.moveItem(at: trashed, to: target)
            rescanDays([dayName])
            return target
        } catch {
            if createdDay {
                removeIfCompletelyEmpty(day)
            }
            throw error
        }
    }

    /// Rescans every day folder for markers, e.g. after the folder watcher saw changes in Finder.
    public func reindex() {
        refreshIndex(rescanningEverything: true)
    }

    /// Every marked event folder in the root, keyed by the occurrence its marker names, after a full
    /// rescan. The app uses it to carry folders along when a repeating event is edited or split.
    public func markedFolders() -> [Occurrence.ID: URL] {
        refreshIndex(rescanningEverything: true)
        return index
    }

    // MARK: - Containment

    /// Whether `url` is the root or inside it, after resolving `.`, `..` and symbolic links (in the
    /// existing part of the path; parts that don't exist yet are taken as written). False for anything
    /// that isn't a file URL.
    public nonisolated func contains(_ url: URL) -> Bool {
        guard let rootComponents = EventFoldersDisk.resolvedComponents(of: root),
            let components = EventFoldersDisk.resolvedComponents(of: url)
        else { return false }
        return components.starts(with: rootComponents)
    }

    /// Whether `url` is inside the root and not the root itself: the only places Ithil writes to.
    private nonisolated func isStrictlyInsideRoot(_ url: URL) -> Bool {
        guard let rootComponents = EventFoldersDisk.resolvedComponents(of: root),
            let components = EventFoldersDisk.resolvedComponents(of: url)
        else { return false }
        return components.count > rootComponents.count && components.starts(with: rootComponents)
    }

    // MARK: - Paths and markers

    private func dayFolder(named name: String) -> URL {
        root.appending(component: name, directoryHint: .isDirectory)
    }

    private func expectedFolder(for occurrence: Occurrence) -> URL {
        let day = dayFolder(named: FolderNaming.dayFolderName(for: occurrence))
        return day.appending(component: FolderNaming.eventFolderName(for: occurrence), directoryHint: .isDirectory)
    }

    private static func markerFile(in folder: URL) -> URL {
        folder.appending(component: EventFolderMarker.fileName, directoryHint: .notDirectory)
    }

    private func readMarker(in folder: URL) -> EventFolderMarker? {
        EventFolderMarker.read(in: folder, fileSystem: fileSystem)
    }

    private func writeMarker(_ marker: EventFolderMarker, in folder: URL) throws {
        let file = Self.markerFile(in: folder)
        guard isStrictlyInsideRoot(file) else {
            throw EventFoldersError.outsideRoot(file.path)
        }
        let data = try marker.markerFileData()
        try fileSystem.writeAtomically(data, to: file)
    }

    /// What is at `url`, as far as event folders go. Symbolic links are never treated as folders.
    private func state(of url: URL) -> EventFoldersItemState {
        guard fileSystem.fileExists(at: url) else {
            return EventFoldersDisk.isSymbolicLink(url) ? .notAFolder : .absent
        }
        guard fileSystem.isDirectory(at: url), !EventFoldersDisk.isSymbolicLink(url) else {
            return .notAFolder
        }
        guard let marker = readMarker(in: url) else { return .unmarked }
        return .marked(marker.occurrenceID)
    }

    /// Writes the marker into a folder the user made at an occurrence's expected path. A failure is
    /// logged: the folder is still found by its path.
    private func adopt(_ folder: URL, for occurrence: Occurrence) {
        do {
            try writeMarker(EventFolderMarker(occurrence: occurrence), in: folder)
            rescanDays([folder.deletingLastPathComponent().lastPathComponent])
        } catch {
            let name = folder.lastPathComponent
            let reason = String(describing: error)
            logger.error("Could not adopt an event folder", private: "\(name): \(reason)")
        }
    }

    /// The names `files(for:)` and `fileCount(for:)` show: no dotfiles (the marker, `.DS_Store`, copies in
    /// progress) and no custom-icon file.
    private func visibleNames(in folder: URL) -> [String] {
        let contents: [URL]
        do {
            contents = try fileSystem.contentsOfDirectory(at: folder)
        } catch {
            let name = folder.lastPathComponent
            let reason = String(describing: error)
            logger.error("Could not list an event folder", private: "\(name): \(reason)")
            return []
        }
        return contents.map(\.lastPathComponent).filter { !$0.hasPrefix(".") && $0 != "Icon\r" }
    }

    // MARK: - Creating

    /// Creates the day folder unless it exists. Returns whether it was created.
    private func createDayFolderIfNeeded(_ day: URL) throws -> Bool {
        guard isStrictlyInsideRoot(day) else {
            throw EventFoldersError.outsideRoot(day.path)
        }
        if fileSystem.isDirectory(at: day) {
            return false
        }
        guard !fileSystem.fileExists(at: day), !EventFoldersDisk.isSymbolicLink(day) else {
            throw EventFoldersError.notADirectory(day.path)
        }
        try fileSystem.createDirectory(at: day)
        return true
    }

    /// Creates the occurrence's folder in `day` under the first free name ("14.00 Lab", "14.00 Lab 2"…)
    /// and writes its marker. A taken name that already holds this occurrence's folder is used as is.
    private func createEventFolder(for occurrence: Occurrence, in day: URL) throws -> URL {
        let baseName = FolderNaming.eventFolderName(for: occurrence)
        for number in 1...Self.maximumSuffix {
            let name = number == 1 ? baseName : "\(baseName) \(number)"
            let candidate = day.appending(component: name, directoryHint: .isDirectory)
            switch state(of: candidate) {
            case .absent:
                guard isStrictlyInsideRoot(candidate) else {
                    throw EventFoldersError.outsideRoot(candidate.path)
                }
                try fileSystem.createDirectory(at: candidate)
                do {
                    try writeMarker(EventFolderMarker(occurrence: occurrence), in: candidate)
                } catch {
                    removeIfCompletelyEmpty(candidate)
                    throw error
                }
                return candidate
            case .marked(let found) where found == occurrence.id:
                if isStrictlyInsideRoot(candidate) {
                    return candidate
                }
            case .marked, .unmarked, .notAFolder:
                break
            }
        }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSURLErrorKey: day.appending(component: baseName)])
    }

    // MARK: - Moving

    /// Where `relocate` puts `current` for `occurrence`: the first of "Name", "Name 2"… in `day` that is
    /// free or is `current` itself (so a folder that already got a suffix keeps it, and a case-only
    /// rename on a case-insensitive volume is allowed).
    private func relocationTarget(for current: URL, in day: URL, for occurrence: Occurrence) throws -> URL {
        let baseName = FolderNaming.eventFolderName(for: occurrence)
        for number in 1...Self.maximumSuffix {
            let name = number == 1 ? baseName : "\(baseName) \(number)"
            let candidate = day.appending(component: name, directoryHint: .isDirectory)
            if candidate.path == current.path {
                return candidate
            }
            let taken = fileSystem.fileExists(at: candidate) || EventFoldersDisk.isSymbolicLink(candidate)
            if !taken || EventFoldersDisk.isSameItem(candidate, current) {
                return candidate
            }
        }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSURLErrorKey: day.appending(component: baseName)])
    }

    /// The first of "Name", "Name 2"… in `day` that nothing has taken, for a folder coming back from the
    /// Trash.
    private func freeFolderName(for occurrence: Occurrence, in day: URL) throws -> URL {
        let baseName = FolderNaming.eventFolderName(for: occurrence)
        for number in 1...Self.maximumSuffix {
            let name = number == 1 ? baseName : "\(baseName) \(number)"
            let candidate = day.appending(component: name, directoryHint: .isDirectory)
            if !fileSystem.fileExists(at: candidate), !EventFoldersDisk.isSymbolicLink(candidate) {
                return candidate
            }
        }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSURLErrorKey: day.appending(component: baseName)])
    }

    /// The marked folder the occurrence already has, at its expected path or anywhere in the index. Unlike
    /// `existingFolder(for:)` it never adopts an unmarked folder, so a folder the user made meanwhile stays
    /// theirs.
    private func folderClaiming(_ occurrence: Occurrence, dayName: String) -> URL? {
        let expected = expectedFolder(for: occurrence)
        if case .marked(let found) = state(of: expected), found == occurrence.id {
            return expected
        }
        return indexedFolder(for: occurrence.id, dayName: dayName)
    }

    /// Renames or moves a folder inside the root. When `destination` already exists it is `source` under
    /// another spelling (a case-only rename), so the folder goes through a hidden temporary name.
    private func moveFolder(_ source: URL, to destination: URL) throws {
        guard fileSystem.fileExists(at: destination) else {
            try fileSystem.moveItem(at: source, to: destination)
            return
        }
        let temporaryName = ".elenath-renaming-\(UUID().uuidString)"
        let temporary = source.deletingLastPathComponent().appending(component: temporaryName)
        guard isStrictlyInsideRoot(temporary) else {
            throw EventFoldersError.outsideRoot(temporary.path)
        }
        try fileSystem.moveItem(at: source, to: temporary)
        do {
            try fileSystem.moveItem(at: temporary, to: destination)
        } catch {
            do {
                try fileSystem.moveItem(at: temporary, to: source)
            } catch {
                // Nothing is lost, but the folder now has a hidden name; say where it is.
                let name = source.lastPathComponent
                logger.error(
                    "Could not undo renaming an event folder; it has a hidden name",
                    private: "\(name) → \(temporaryName)")
            }
            throw error
        }
    }

    /// Removes a day folder (`<root>/yyyy-MM-dd`) if nothing at all is left in it.
    private func removeDayFolderIfCompletelyEmpty(_ day: URL) {
        guard CalendarDate(isoString: day.lastPathComponent) != nil,
            day.deletingLastPathComponent().path == root.path
        else { return }
        removeIfCompletelyEmpty(day)
    }

    /// Removes a folder inside the root that has nothing in it, hidden files included. Never removes
    /// anything with contents: `rmdir` refuses a folder that isn't empty.
    private func removeIfCompletelyEmpty(_ folder: URL) {
        guard isStrictlyInsideRoot(folder), !EventFoldersDisk.isSymbolicLink(folder),
            let contents = try? fileSystem.contentsOfDirectory(at: folder), contents.isEmpty
        else { return }
        if !EventFoldersDisk.removeEmptyDirectory(folder) {
            logger.error("Could not remove an empty day folder", private: folder.lastPathComponent)
        }
    }

    // MARK: - Index

    /// The occurrence's folder from the marker index, refreshing the index first when it has never been
    /// built, when its entry turned out stale, or when the disk changed where the folder could have
    /// appeared (the root, or the occurrence's own day folder).
    private func indexedFolder(for id: Occurrence.ID, dayName: String) -> URL? {
        if !hasScanned {
            refreshIndex(rescanningEverything: true)
        } else if let known = index[id] {
            if isMarkedFolder(known, for: id) {
                return known
            }
            let staleDay = known.deletingLastPathComponent().lastPathComponent
            refreshIndex(rescanningEverything: false, alsoRescanning: [staleDay])
        } else if Self.hasChanged(fileSystem.modificationDate(at: root), since: scannedRootModified) {
            refreshIndex(rescanningEverything: false)
        } else if dayFolderChanged(dayName) {
            rescanDays([dayName])
        } else {
            return nil
        }
        guard let found = index[id], isMarkedFolder(found, for: id) else { return nil }
        return found
    }

    private func isMarkedFolder(_ folder: URL, for id: Occurrence.ID) -> Bool {
        guard case .marked(let found) = state(of: folder) else { return false }
        return found == id
    }

    /// Whether a day folder appeared, disappeared or changed since it was last scanned.
    private func dayFolderChanged(_ name: String) -> Bool {
        let day = dayFolder(named: name)
        guard fileSystem.isDirectory(at: day), !EventFoldersDisk.isSymbolicLink(day) else {
            return dayScans[name] != nil
        }
        return Self.hasChanged(fileSystem.modificationDate(at: day), since: dayScans[name]?.modified)
    }

    /// Lists the root and rescans the day folders that changed since their last scan (every one when
    /// `rescanningEverything`, and those named in `forced` regardless), then rebuilds the index.
    private func refreshIndex(rescanningEverything: Bool, alsoRescanning forced: [String] = []) {
        let rootModified = fileSystem.modificationDate(at: root)
        var scans: [String: EventFoldersDayScan] = [:]
        let contents = (try? fileSystem.contentsOfDirectory(at: root)) ?? []
        for name in contents.map(\.lastPathComponent) where CalendarDate(isoString: name) != nil {
            let day = dayFolder(named: name)
            guard fileSystem.isDirectory(at: day), !EventFoldersDisk.isSymbolicLink(day) else { continue }
            let cached = (rescanningEverything || forced.contains(name)) ? nil : dayScans[name]
            if let cached, !Self.hasChanged(fileSystem.modificationDate(at: day), since: cached.modified) {
                scans[name] = cached
            } else {
                scans[name] = scanDay(day)
            }
        }
        dayScans = scans
        scannedRootModified = rootModified
        hasScanned = true
        rebuildIndex()
    }

    /// Rescans the named day folders now (after Ithil changed them itself) and rebuilds the index.
    private func rescanDays(_ names: [String]) {
        for name in Set(names) {
            let day = dayFolder(named: name)
            let isDayFolder = fileSystem.isDirectory(at: day) && !EventFoldersDisk.isSymbolicLink(day)
            dayScans[name] = isDayFolder && CalendarDate(isoString: name) != nil ? scanDay(day) : nil
        }
        rebuildIndex()
    }

    /// The marked event folders directly inside a day folder, by name.
    private func scanDay(_ day: URL) -> EventFoldersDayScan {
        let modified = fileSystem.modificationDate(at: day)
        let contents = (try? fileSystem.contentsOfDirectory(at: day)) ?? []
        var entries: [EventFoldersIndexEntry] = []
        for name in contents.map(\.lastPathComponent).sorted() where !name.hasPrefix(".") {
            let folder = day.appending(component: name, directoryHint: .isDirectory)
            if case .marked(let id) = state(of: folder) {
                entries.append(EventFoldersIndexEntry(id: id, folder: folder))
            }
        }
        return EventFoldersDayScan(modified: modified, entries: entries)
    }

    private func rebuildIndex() {
        var rebuilt: [Occurrence.ID: URL] = [:]
        for name in dayScans.keys.sorted() {
            for entry in dayScans[name]?.entries ?? [] where rebuilt[entry.id] == nil {
                rebuilt[entry.id] = entry.folder
            }
        }
        index = rebuilt
    }

    /// Whether a modification date differs from the one recorded; unknown dates always count as changed.
    private static func hasChanged(_ current: Date?, since recorded: Date?) -> Bool {
        guard let current, let recorded else { return true }
        return current != recorded
    }
}

/// What `EventFolders` finds at a path.
private enum EventFoldersItemState {
    /// Nothing there.
    case absent
    /// A file, a symbolic link, or anything else that isn't a plain folder.
    case notAFolder
    /// A folder without a readable marker.
    case unmarked
    /// A folder with a marker, and the occurrence it names.
    case marked(Occurrence.ID)
}

/// One scanned day folder: its modification date at the time, and the marked folders in it.
private struct EventFoldersDayScan {
    var modified: Date?
    var entries: [EventFoldersIndexEntry]
}

private struct EventFoldersIndexEntry {
    var id: Occurrence.ID
    var folder: URL
}

/// Disk queries the `FileSystem` protocol doesn't offer, straight through `FileManager` and POSIX: they
/// only read, except `removeEmptyDirectory`, which can only remove an empty folder.
private enum EventFoldersDisk {
    /// Whether `url` itself is a symbolic link (not followed; a dangling link counts).
    static func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// Whether two paths name the same file or folder (same volume and file number), as two spellings of
    /// one name do on a case-insensitive volume.
    static func isSameItem(_ first: URL, _ second: URL) -> Bool {
        guard let firstID = itemIdentity(first), let secondID = itemIdentity(second) else { return false }
        return firstID == secondID
    }

    private static func itemIdentity(_ url: URL) -> [UInt64]? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let volume = attributes[.systemNumber] as? NSNumber,
            let file = attributes[.systemFileNumber] as? NSNumber
        else { return nil }
        return [volume.uint64Value, file.uint64Value]
    }

    /// A file's size, or for a folder the total size of the regular files inside it (links not followed).
    static func byteCount(of url: URL, isDirectory: Bool) -> Int64 {
        guard !isSymbolicLink(url) else { return 0 }
        guard isDirectory else {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return size(attributes: attributes)
        }
        guard let enumerator = FileManager.default.enumerator(atPath: url.path) else { return 0 }
        var total: Int64 = 0
        while enumerator.nextObject() != nil {
            let attributes = enumerator.fileAttributes
            if (attributes?[.type] as? FileAttributeType) == FileAttributeType.typeRegular {
                total += size(attributes: attributes)
            }
        }
        return total
    }

    private static func size(attributes: [FileAttributeKey: Any]?) -> Int64 {
        guard let number = attributes?[.size] as? NSNumber else { return 0 }
        return number.int64Value
    }

    /// Removes `url` only if it is an empty folder (POSIX `rmdir`). Returns whether it was removed.
    static func removeEmptyDirectory(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return rmdir(path) == 0
        }
    }

    /// The absolute path of `url` as components, with `.` and `..` applied and every symbolic link in the
    /// existing part of the path resolved (components that don't exist are kept as written). Nil for a
    /// URL that isn't a file URL, or for a loop of links.
    static func resolvedComponents(of url: URL) -> [String]? {
        guard url.isFileURL else { return nil }
        var pending = Array(url.absoluteURL.path.split(separator: "/").map { String($0) }.reversed())
        var resolved: [String] = []
        var linksFollowed = 0
        while let component = pending.popLast() {
            if component == "." {
                continue
            }
            if component == ".." {
                if !resolved.isEmpty {
                    resolved.removeLast()
                }
                continue
            }
            let path = "/" + (resolved + [component]).joined(separator: "/")
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
                resolved.append(component)
                continue
            }
            linksFollowed += 1
            guard linksFollowed <= 64 else { return nil }
            if destination.hasPrefix("/") {
                resolved.removeAll()
            }
            pending.append(contentsOf: destination.split(separator: "/").map { String($0) }.reversed())
        }
        return resolved
    }
}
