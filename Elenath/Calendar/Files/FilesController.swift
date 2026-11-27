import AppKit
import ElenathCore
import Foundation
import Observation
import os

private let logger = Logger(subsystem: "io.github.visaug36.Elenath", category: "FilesController")

/// Event files for the app: counts on event blocks, file lists, adding files, Finder and the Trash, and
/// keeping event folders in step with the calendar. Injected with `.environment(files)`.
///
/// - The folder is the source of truth: counts and lists are read from disk on the `EventFolders` actor,
///   never on the main thread, and refreshed when `RootFolderWatcher` sees changes made in Finder.
/// - Everything that changes the disk (copies, folder renames and moves, the Trash) runs
///   one at a time, in the order it was asked for, so a rename never races a copy into the same folder.
/// - Files are copied, never moved; folders and files go to the Trash, never deleted; nothing is written
///   outside the root. Folders are trashed only for occurrences the user deleted (after the UI asked).
/// - Undo and Redo (`CalendarChange.restored`) carry folders back along, and folders trashed in this session
///   come back from the Trash when their occurrences come back. A restore never trashes anything.
/// - Work started for one library is dropped when another one opens (`session`).
@Observable @MainActor
final class FilesController: CalendarChangeObserver {
    // MARK: - Observed state

    /// The open library's root, following `CalendarChange.opened`.
    private(set) var root: URL? = nil
    /// Known file counts. A missing entry means not loaded yet: show nothing.
    private(set) var fileCounts: [Occurrence.ID: Int] = [:]
    /// Bumped whenever files may have changed: Finder edits, copies, renames, the Trash, another library.
    private(set) var changeToken = 0
    /// Copies in progress, or waiting their turn, by occurrence.
    private(set) var imports: [Occurrence.ID: FileCopyProgress] = [:]
    /// The library is being moved to another folder (Settings › Files): no file work until it has reopened.
    var isMovingLibrary: Bool { model.isMovingLibrary }
    /// The last failure as a sentence for the user. `MainView` shows it as an alert, then sets nil.
    var lastError: String? = nil

    /// For `.alert(isPresented:)`.
    var showsLastError: Bool {
        get { lastError != nil }
        set {
            if !newValue {
                lastError = nil
            }
        }
    }

    // MARK: - Private state

    private let model: CalendarModel
    @ObservationIgnored private var folders: EventFolders? = nil
    @ObservationIgnored private var watcher: RootFolderWatcher? = nil
    /// The root with symbolic links resolved, as FSEvents reports paths; nil until worked out.
    @ObservationIgnored private var resolvedRootPath: String? = nil
    /// Bumped whenever a library opens; results of work for an earlier one are dropped.
    @ObservationIgnored private var session = 0
    /// Occurrences whose counts were asked for, kept up to date after changes (the newest ones).
    @ObservationIgnored private var requested: [Occurrence.ID: Occurrence] = [:]
    @ObservationIgnored private var requestOrder: [Occurrence.ID] = []
    @ObservationIgnored private var pendingCounts: [Occurrence.ID: Occurrence] = [:]
    @ObservationIgnored private var countingIDs: Set<Occurrence.ID> = []
    @ObservationIgnored private var countTask: Task<Void, Never>? = nil
    @ObservationIgnored private var isReindexing = false
    @ObservationIgnored private var needsAnotherReindex = false
    /// The last piece of disk work; the next one waits for it.
    @ObservationIgnored private var lastWork: Task<Void, Never>? = nil
    /// Disk work asked for and not finished yet.
    @ObservationIgnored private var diskWorkInFlight = 0
    @ObservationIgnored private var importJobs: [Occurrence.ID: FileImportJob] = [:]
    /// Files dropped on an occurrence while a copy into it was running; copied right after it.
    @ObservationIgnored private var queuedSources: [Occurrence.ID: [URL]] = [:]
    @ObservationIgnored private var importNumber = 0
    /// Folders this session put in the Trash, by the occurrence they belonged to, so Undo can bring them back.
    @ObservationIgnored private var trashedFolders: [Occurrence.ID: TrashedEventFolder] = [:]

    /// How long `requestCounts` collects requests before reading the disk.
    private static let countDelay: Duration = .milliseconds(50)
    /// The most occurrences read in one turn on the actor.
    private static let countBatchSize = 500
    /// How many requested occurrences are kept up to date; older ones are read again when asked for.
    private static let maximumRemembered = 3_000

    /// Registers as a library observer. If the model already has a library open, follows it at once.
    init(model: CalendarModel) {
        self.model = model
        model.addChangeObserver(self)
        if model.state == .ready, let current = model.rootURL {
            startSession(at: current)
        }
    }

    // MARK: - Counts

    /// Asks for the file counts of `occurrences`, e.g. the ones on screen. Cheap to call often: requests
    /// are de-duplicated, collected for a moment and read off the main thread; `fileCounts` updates once
    /// they are known.
    func requestCounts(for occurrences: [Occurrence]) {
        guard folders != nil else { return }
        var added = false
        for occurrence in occurrences {
            let id = occurrence.id
            let isKnown = fileCounts[id] != nil || pendingCounts[id] != nil || countingIDs.contains(id)
            if isKnown, requested[id] == occurrence {
                continue
            }
            remember(occurrence)
            pendingCounts[id] = occurrence
            added = true
        }
        if added {
            scheduleCounting()
        }
    }

    /// The occurrence's known file count, or nil while it isn't known yet (then it is asked for).
    func fileCount(for occurrence: Occurrence) -> Int? {
        if requested[occurrence.id] == nil {
            requestCounts(for: [occurrence])
        }
        return fileCounts[occurrence.id]
    }

    /// A count for notification bodies, read on the `EventFolders` actor of whatever library is open
    /// when it is called. 0 when no library is open.
    func makeFileCountProvider() -> @Sendable (Occurrence) async -> Int {
        return { [weak self] occurrence in
            guard let folders = await self?.currentFolders() else { return 0 }
            return await folders.fileCount(for: occurrence)
        }
    }

    private func currentFolders() -> EventFolders? {
        folders
    }

    private func remember(_ occurrence: Occurrence) {
        let id = occurrence.id
        guard requested.updateValue(occurrence, forKey: id) == nil else { return }
        requestOrder.append(id)
        let overflow = requestOrder.count - Self.maximumRemembered
        // Forget in chunks, so this stays cheap.
        guard overflow >= Self.maximumRemembered / 10 else { return }
        for forgotten in requestOrder.prefix(overflow) {
            requested[forgotten] = nil
        }
        requestOrder.removeFirst(overflow)
    }

    private func scheduleCounting() {
        guard countTask == nil else { return }
        let session = self.session
        countTask = Task { [weak self] in
            do {
                try await Task.sleep(for: FilesController.countDelay)
            } catch {
                return
            }
            await self?.drainCounts(session: session)
        }
    }

    /// Reads the pending counts in batches, one batch at a time, so a newer read never loses to an older one.
    private func drainCounts(session: Int) async {
        while session == self.session, let folders, !pendingCounts.isEmpty {
            let batch = Array(pendingCounts.values.prefix(Self.countBatchSize))
            for occurrence in batch {
                pendingCounts[occurrence.id] = nil
            }
            countingIDs = Set(batch.map(\.id))
            let counts = await folders.fileCounts(for: batch)
            guard session == self.session else { return }
            countingIDs = []
            apply(counts)
        }
        if session == self.session {
            countTask = nil
        }
    }

    /// Stores new counts with one change to `fileCounts`, and none if nothing changed.
    private func apply(_ counts: [Occurrence.ID: Int]) {
        var updated = fileCounts
        var changed = false
        for (id, count) in counts where updated[id] != count {
            updated[id] = count
            changed = true
        }
        if changed {
            fileCounts = updated
        }
    }

    /// Reads every remembered count again and tells the views (file lists follow `changeToken`).
    private func filesChanged(session: Int) {
        guard session == self.session else { return }
        for (id, occurrence) in requested {
            pendingCounts[id] = occurrence
        }
        if !pendingCounts.isEmpty {
            scheduleCounting()
        }
        changeToken += 1
        model.eventFilesMayHaveChanged?()
    }

    // MARK: - Listing and Finder

    /// The visible items in the occurrence's folder, sorted like Finder; empty when it has none.
    func files(for occurrence: Occurrence) async -> [EventFile] {
        guard let folders else { return [] }
        let session = self.session
        let files = await folders.files(for: occurrence)
        if session == self.session {
            remember(occurrence)
            apply([occurrence.id: files.count])
        }
        return files
    }

    /// The occurrence's folder, or nil while it has none. Never creates one.
    func folderURL(for occurrence: Occurrence) async -> URL? {
        guard let folders else { return nil }
        return await folders.existingFolder(for: occurrence)
    }

    /// Opens the occurrence's folder in Finder; if it has none yet, its day folder, or else the root.
    func revealInFinder(_ occurrence: Occurrence) {
        guard let folders else { return }
        Task {
            let target = await folders.finderTarget(for: occurrence)
            if !NSWorkspace.shared.open(target) {
                NSWorkspace.shared.activateFileViewerSelecting([target])
            }
        }
    }

    /// Shows the file selected in a Finder window.
    func reveal(_ file: EventFile) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    /// Opens the file in its default app.
    func open(_ file: EventFile) {
        if !NSWorkspace.shared.open(file.url) {
            lastError = FileMessages.couldNotOpenFile(name: file.name)
        }
    }

    /// Moves one file (or folder) from an event's folder to the Trash. Never deletes anything.
    func moveToTrash(_ file: EventFile) {
        guard model.canEdit, let folders else {
            lastError = FileMessages.couldNotTrashFile(name: file.name, error: FilesError.notReady)
            return
        }
        let session = self.session
        enqueueWork { [weak self] in
            let failure = await FilesController.trash(file, folders: folders)
            self?.fileTrashed(file, failure: failure, session: session)
        }
    }

    private func fileTrashed(_ file: EventFile, failure: (any Error)?, session: Int) {
        guard session == self.session else { return }
        if let failure {
            let reason = String(describing: failure)
            logger.error("Could not trash \(file.name, privacy: .private): \(reason, privacy: .private)")
            lastError = FileMessages.couldNotTrashFile(name: file.name, error: failure)
        } else {
            logger.info("Moved \(file.name, privacy: .private) to the Trash")
        }
        filesChanged(session: session)
    }

    /// Trashes an item that is inside an event folder of `folders` (at least three levels below the root:
    /// day folder, event folder, item), and nothing else.
    nonisolated private static func trash(_ file: EventFile, folders: EventFolders) async -> (any Error)? {
        let url = file.url.standardizedFileURL
        let rootDepth = folders.root.standardizedFileURL.pathComponents.count
        let isInEventFolder = folders.contains(url) && url.pathComponents.count >= rootDepth + 3
        guard isInEventFolder, !url.lastPathComponent.hasPrefix(".") else {
            return EventFoldersError.outsideRoot(url.path)
        }
        do {
            try LocalFileSystem().trashItem(at: url)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Names

    /// Where the occurrence's files go, for the editor and details: "Calendar › 2026-10-06 › 14.00 Physics
    /// Lecture". The expected place, even if the folder was renamed in Finder.
    func displayPath(for occurrence: Occurrence) -> String {
        let rootName = root?.lastPathComponent ?? NameSanitizer.calendarFolderName
        let dayName = FolderNaming.dayFolderName(for: occurrence)
        return [rootName, dayName, FolderNaming.eventFolderName(for: occurrence)].joined(separator: " › ")
    }

    /// The occurrence's folder name: "14.00 Physics Lecture".
    func folderName(for occurrence: Occurrence) -> String {
        FolderNaming.eventFolderName(for: occurrence)
    }

    // MARK: - Adding files

    /// Copies (never moves) `urls` into the occurrence's folder, creating it if needed, in the background
    /// with progress in `imports`. Files dropped while a copy into the same occurrence runs are copied
    /// right after it. The occurrence must already be in the library (add a new event first). Failures
    /// set `lastError`; cancelling is silent.
    func addFiles(_ urls: [URL], to occurrence: Occurrence) {
        let sources = Self.uniqueFileURLs(urls)
        guard !sources.isEmpty else { return }
        guard !isMovingLibrary else {
            lastError = FileMessages.cannotAddWhileMoving
            return
        }
        guard model.canEdit, folders != nil else {
            lastError = FileMessages.cannotAddFilesNow
            return
        }
        guard let current = model.occurrence(id: occurrence.id) else {
            lastError = FileMessages.importFailed(FilesError.eventNotFound, progress: nil)
            return
        }
        let id = current.id
        guard importJobs[id] == nil else {
            var queued = queuedSources[id] ?? []
            for source in sources where !queued.contains(source) {
                queued.append(source)
            }
            queuedSources[id] = queued
            if imports[id] == nil {
                imports[id] = FileCopyProgress(totalFiles: queued.count)
            }
            return
        }
        startImport(sources, for: current)
    }

    /// Stops the copy into the occurrence and drops files waiting for it. Items already copied stay.
    func cancelImport(for occurrence: Occurrence) {
        let id = occurrence.id
        queuedSources[id] = nil
        imports[id] = nil
        guard var job = importJobs[id] else { return }
        job.isCancelled = true
        importJobs[id] = job
        job.task.cancel()
    }

    private func startImport(_ sources: [URL], for occurrence: Occurrence) {
        guard let folders, let root else { return }
        importNumber += 1
        let number = importNumber
        let id = occurrence.id
        let session = self.session
        imports[id] = FileCopyProgress(totalFiles: sources.count)
        let gate = ImportProgressGate()
        let deliver: @MainActor @Sendable (FileCopyProgress) -> Void = { [weak self] progress in
            self?.importProgressed(progress, id: id, number: number)
        }
        let task = enqueueWork { [weak self] in
            let outcome = await FilesController.performImport(
                sources, for: occurrence, folders: folders, root: root, gate: gate, deliver: deliver)
            self?.importFinished(outcome, id: id, number: number, session: session)
        }
        importJobs[id] = FileImportJob(number: number, occurrence: occurrence, task: task)
        logger.info("Copying \(sources.count, privacy: .public) items into an event folder")
    }

    /// Makes the folder and copies into it, off the main actor. Starts the security scope of each source
    /// for the copy (needed for files from a file importer; harmless otherwise).
    nonisolated private static func performImport(
        _ sources: [URL],
        for occurrence: Occurrence,
        folders: EventFolders,
        root: URL,
        gate: ImportProgressGate,
        deliver: @escaping @MainActor @Sendable (FileCopyProgress) -> Void
    ) async -> FileImportOutcome {
        guard !Task.isCancelled else { return .cancelled }
        let folder: URL
        do {
            folder = try await folders.ensureFolder(for: occurrence)
        } catch {
            return .failed(error, progress: nil)
        }
        var accessed: [URL] = []
        for source in sources where source.startAccessingSecurityScopedResource() {
            accessed.append(source)
        }
        defer {
            for source in accessed {
                source.stopAccessingSecurityScopedResource()
            }
        }
        let report: @Sendable (FileCopyProgress) -> Void = { progress in
            if gate.admit(progress) {
                Task { @MainActor in
                    deliver(progress)
                }
            }
        }
        do {
            let copied = try await FileCopier.copy(
                sources, into: folder, root: root, fileSystem: LocalFileSystem(), progress: report)
            return .finished(count: copied.count)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(error, progress: gate.latest)
        }
    }

    private func importProgressed(_ progress: FileCopyProgress, id: Occurrence.ID, number: Int) {
        guard let job = importJobs[id], job.number == number, !job.isCancelled else { return }
        // Reports hop to the main actor one by one; never let an older one replace a newer one.
        if let shown = imports[id], shown.totalBytes == progress.totalBytes {
            let fewerBytes = progress.completedBytes < shown.completedBytes
            guard !fewerBytes, progress.completedFiles >= shown.completedFiles else { return }
        }
        imports[id] = progress
    }

    private func importFinished(_ outcome: FileImportOutcome, id: Occurrence.ID, number: Int, session: Int) {
        guard session == self.session, let job = importJobs[id], job.number == number else { return }
        importJobs[id] = nil
        imports[id] = nil
        switch outcome {
        case .finished(let count):
            logger.info("Copied \(count, privacy: .public) items into an event folder")
        case .cancelled:
            logger.notice("Stopped copying files into an event folder")
        case .failed(let error, let progress):
            let reason = String(describing: error)
            let name = progress?.currentName ?? ""
            logger.error("Could not copy \(name, privacy: .private): \(reason, privacy: .private)")
            if !job.isCancelled {
                lastError = FileMessages.importFailed(error, progress: progress)
            }
        }
        // Its count is read again even if no view asked for it yet.
        remember(job.occurrence)
        filesChanged(session: session)
        startQueuedImport(for: id)
    }

    /// Copies the files that were dropped on the occurrence while the last copy into it ran.
    private func startQueuedImport(for id: Occurrence.ID) {
        guard let queued = queuedSources.removeValue(forKey: id), !queued.isEmpty else { return }
        guard model.canEdit, !isMovingLibrary, let current = model.occurrence(id: id) else {
            imports[id] = nil
            lastError = FileMessages.importFailed(FilesError.eventNotFound, progress: nil)
            return
        }
        startImport(queued, for: current)
    }

    /// File URLs only, each once, in order.
    private static func uniqueFileURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var unique: [URL] = []
        for url in urls where url.isFileURL {
            if seen.insert(url.standardizedFileURL.path).inserted {
                unique.append(url)
            }
        }
        return unique
    }

    // MARK: - Disk work, one at a time

    /// Runs `work` after every piece of disk work asked for before it. Cancelling the returned task
    /// cancels `work`, not the work before it.
    @discardableResult
    private func enqueueWork(_ work: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = lastWork
        diskWorkInFlight += 1
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            await work()
            self?.diskWorkInFlight -= 1
        }
        lastWork = task
        return task
    }

    /// Whether files are being copied into an event, or wait to be.
    var isCopyingFiles: Bool {
        !imports.isEmpty || !queuedSources.isEmpty
    }

    /// Waits until the disk work asked for so far (copies, folders that follow their events, trashing) has
    /// finished, or `timeout` passes. Returns whether it has.
    func finishDiskWork(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while diskWorkInFlight > 0, ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                break
            }
        }
        return diskWorkInFlight == 0
    }

    // MARK: - Following the library

    func calendarDidChange(_ change: CalendarChange, from old: CalendarDocument, to new: CalendarDocument) {
        switch change {
        case .opened(let newRoot):
            startSession(at: newRoot)
        case .closed:
            endSession()
        case .updated, .deleted, .restored:
            applyFolderChange(change, old: old, new: new)
        case .added, .subjectsChanged:
            break
        case .broughtIn:
            // The folders were copied in through `eventFolders`: look at them again.
            reindex()
        }
    }

    /// Carries folders along after an edit or an Undo / Redo, or trashes them after a deletion.
    private func applyFolderChange(_ change: CalendarChange, old: CalendarDocument, new: CalendarDocument) {
        switch change {
        case .updated(let occurrence, _, let scope):
            carryFolders(of: occurrence, scope: scope, old: old, new: new)
        case .deleted(let occurrence, let scope):
            trashFolders(of: occurrence, scope: scope, old: old, new: new)
        case .restored:
            followRestore(old: old, new: new)
        case .opened, .closed, .added, .subjectsChanged, .broughtIn:
            break
        }
    }

    /// Starts fresh for a newly opened library: a new `EventFolders` actor, an index scan and the folder
    /// watcher. Nothing is written, except the sample files of a demo library.
    private func startSession(at newRoot: URL) {
        session += 1
        let session = self.session
        countTask?.cancel()
        countTask = nil
        pendingCounts = [:]
        countingIDs = []
        requested = [:]
        requestOrder = []
        isReindexing = false
        needsAnotherReindex = false
        for job in importJobs.values {
            job.task.cancel()
        }
        importJobs = [:]
        queuedSources = [:]
        trashedFolders = [:]
        watcher?.stop()
        watcher = nil
        resolvedRootPath = nil

        let folders = EventFolders(root: newRoot, fileSystem: LocalFileSystem())
        self.folders = folders
        root = newRoot
        fileCounts = [:]
        imports = [:]
        changeToken += 1
        startWatching(newRoot)
        Task { [weak self] in
            let resolved = await FilesController.prepare(folders, root: newRoot)
            self?.didPrepare(resolvedPath: resolved, session: session)
        }
    }

    /// Stops following the calendar that was open: its copies, its watcher and what is known about it.
    /// Nothing on disk changes.
    private func endSession() {
        session += 1
        countTask?.cancel()
        countTask = nil
        pendingCounts = [:]
        countingIDs = []
        requested = [:]
        requestOrder = []
        for job in importJobs.values {
            job.task.cancel()
        }
        importJobs = [:]
        queuedSources = [:]
        trashedFolders = [:]
        watcher?.stop()
        watcher = nil
        resolvedRootPath = nil
        folders = nil
        root = nil
        fileCounts = [:]
        imports = [:]
        changeToken += 1
    }

    /// The event folders of the calendar that is open, for bringing in an Ithil calendar, so the folders
    /// copied in are found by the same index the views use.
    var eventFolders: EventFolders? {
        folders
    }

    /// Builds the marker index and resolves the root's path, off the main actor.
    nonisolated private static func prepare(_ folders: EventFolders, root: URL) async -> String {
        await folders.reindex()
        return FolderChangeFilter.resolvedPath(of: root)
    }

    private func didPrepare(resolvedPath: String, session: Int) {
        guard session == self.session else { return }
        resolvedRootPath = resolvedPath
        filesChanged(session: session)
    }

    private func startWatching(_ watchedRoot: URL) {
        let watcher = RootFolderWatcher(root: watchedRoot) { [weak self] change in
            self?.folderChanged(change)
        }
        guard watcher.start() else {
            logger.error("Could not watch the library folder for changes")
            return
        }
        self.watcher = watcher
    }

    /// FSEvents saw changes: rescan the marker index if folders came, went or were renamed, then refresh.
    private func folderChanged(_ change: RootFolderChange) {
        guard !isMovingLibrary else { return }
        switch FolderChangeFilter.impact(of: change, rootPath: resolvedRootPath) {
        case .unrelated:
            return
        case .contents:
            filesChanged(session: session)
        case .structure:
            reindex()
        }
    }

    /// One rescan at a time; changes that arrive meanwhile get one more afterwards.
    private func reindex() {
        guard let folders else { return }
        guard !isReindexing else {
            needsAnotherReindex = true
            return
        }
        isReindexing = true
        let session = self.session
        Task { [weak self] in
            await folders.reindex()
            self?.didReindex(session: session)
        }
    }

    private func didReindex(session: Int) {
        guard session == self.session else { return }
        isReindexing = false
        filesChanged(session: session)
        if needsAnotherReindex {
            needsAnotherReindex = false
            reindex()
        }
    }

    /// After an edit: renames and moves the edited event's folders so they match it again.
    private func carryFolders(
        of occurrence: Occurrence, scope: SeriesEditing.Scope, old: CalendarDocument, new: CalendarDocument
    ) {
        guard let folders else { return }
        let update = FolderUpdate(occurrence: occurrence, scope: scope, old: old, new: new, timeZone: model.timeZone)
        let session = self.session
        enqueueWork { [weak self] in
            let report = await folders.carryFolders(update)
            self?.folderWorkFinished(report, kind: .carry, session: session)
        }
    }

    /// After a deletion the user confirmed: stops copies into the deleted occurrences, then puts their
    /// folders in the Trash.
    private func trashFolders(
        of occurrence: Occurrence, scope: SeriesEditing.Scope, old: CalendarDocument, new: CalendarDocument
    ) {
        guard let folders else { return }
        for id in Array(importJobs.keys) where model.occurrence(id: id) == nil {
            if var job = importJobs[id] {
                job.isCancelled = true
                importJobs[id] = job
                job.task.cancel()
            }
            imports[id] = nil
        }
        for id in Array(queuedSources.keys) where model.occurrence(id: id) == nil {
            queuedSources[id] = nil
        }
        let deletion = FolderDeletion(
            occurrence: occurrence, scope: scope, old: old, new: new, timeZone: model.timeZone)
        let session = self.session
        enqueueWork { [weak self] in
            let report = await folders.trashFolders(deletion)
            self?.folderWorkFinished(report, kind: .trash, session: session)
        }
    }

    /// After Undo or Redo: moves folders back along with the library put back, then brings back from the
    /// Trash the folders of occurrences that came back. Never trashes anything.
    private func followRestore(old: CalendarDocument, new: CalendarDocument) {
        guard let folders else { return }
        let restore = FolderRestore(old: old, new: new, timeZone: model.timeZone)
        let session = self.session
        enqueueWork { [weak self] in
            let report = await folders.followRestore(restore)
            self?.folderWorkFinished(report, kind: .carry, session: session)
            await self?.putBackTrashedFolders(cameBackFrom: old, session: session)
        }
    }

    /// Brings back from the Trash every folder this session trashed whose occurrence this Undo or Redo
    /// brought back: missing from `old`, the library before it, and in the library now (decided when the
    /// work runs, so a quick Redo that deletes it again leaves it in the Trash). An occurrence that came
    /// back some other way, such as a repeat rule running longer again, leaves its old folder in the Trash.
    private func putBackTrashedFolders(cameBackFrom old: CalendarDocument, session: Int) async {
        guard session == self.session, let folders else { return }
        let expander = OccurrenceExpander(displayTimeZone: model.timeZone)
        var items: [TrashedEventFolder] = []
        for (id, trashed) in trashedFolders {
            if let event = old.event(withID: id.eventID), expander.occurrence(of: event, on: id.date) != nil {
                continue
            }
            guard let current = model.occurrence(id: id) else { continue }
            items.append(TrashedEventFolder(occurrence: current, trashedURL: trashed.trashedURL))
            trashedFolders[id] = nil
        }
        guard !items.isEmpty else { return }
        let report = await folders.putBack(items)
        if report.changed > 0 {
            logger.info("Brought \(report.changed, privacy: .public) event folders back from the Trash")
        }
        folderWorkFinished(report, kind: .putBack, session: session)
    }

    private enum FolderWorkKind {
        case carry
        case trash
        case putBack
    }

    private func folderWorkFinished(_ report: EventFolderWorkReport, kind: FolderWorkKind, session: Int) {
        guard session == self.session else { return }
        for failure in report.failures {
            let reason = String(describing: failure.error)
            logger.error("Folder change failed for \(failure.title, privacy: .private): \(reason, privacy: .private)")
        }
        for item in report.trashed {
            trashedFolders[item.occurrence.id] = item
        }
        if let failure = report.failures.first {
            switch kind {
            case .carry:
                lastError = FileMessages.couldNotRenameFolder(title: failure.title, error: failure.error)
            case .trash:
                lastError = FileMessages.couldNotTrashFolder(title: failure.title, error: failure.error)
            case .putBack:
                lastError = FileMessages.couldNotPutBackFolder(title: failure.title, error: failure.error)
            }
        }
        if report.changed > 0 || !report.failures.isEmpty {
            filesChanged(session: session)
        }
    }
}
