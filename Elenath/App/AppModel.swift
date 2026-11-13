import AppKit
import ElenathCore
import Foundation
import Observation

/// Where the app is in opening its library folder. `MainView` shows one screen per state.
enum LibraryState: Equatable {
    /// First launch: no folder chosen yet.
    case needsFolder
    case loading
    case ready
    /// The bookmark is broken or the folder is gone (moved, deleted, drive unplugged): "Locate or choose
    /// folder". Elenath never starts an empty library from here.
    case folderMissing(path: String)
    /// The folder exists but has no library.json and nothing to recover it from.
    case noLibrary(path: String)
    /// library.json is damaged and couldn't be recovered.
    case unreadable(path: String, message: String)
}

/// What the detail area shows.
enum Route: Hashable {
    case today
    case inbox
    /// A space (the root path) or a folder inside a space or the Inbox.
    case folder(Container, ItemPath)
    /// The notes with a tag, as seen from a workplace.
    case tag(String, Workplace)
    case note(NoteRef)
    /// The results for `AppModel.searchText`.
    case search
}

/// Everything that works on the open library. All of them are actors, so the main thread never waits
/// for the disk or the index.
struct LibraryServices: Sendable {
    let catalog: LibraryCatalog
    let notes: NoteStore
    let indexer: Indexer
    let retrieval: Retrieval
    let importer: Importer
    let root: URL
    let support: FolderAccess.SupportFolders
}

/// The app's state: the open library, where the user is in it, and what the sidebar shows. Injected once
/// with `.environment(model)`.
///
/// - Everything that touches the disk or the index runs on the actors in `LibraryServices`. The model
///   only holds what the views draw.
/// - `contentRevision` goes up whenever notes may have changed (a save, an import, a change in Finder),
///   and the views that list notes ask again.
/// - Changes register Undo with the main window's undo manager (see `AppModel+Notes.swift`).
@Observable @MainActor
final class AppModel {
    // MARK: - Library

    private(set) var state: LibraryState = .loading
    private(set) var spaces: [Space] = []
    /// The library was written by a newer Elenath: shown, never changed.
    private(set) var isReadOnly = false
    /// The library folder, while `.ready`.
    private(set) var rootURL: URL? = nil
    private(set) var libraryID: LibraryID? = nil
    private(set) var services: LibraryServices? = nil
    let isDemo: Bool
    let timeSource: any TimeSource

    /// Set after a settings file was restored, or a space was sealed because its settings couldn't be
    /// read; the UI shows an alert, then sets nil.
    var recoveryNotice: String? = nil
    /// Why the folder the user just chose can't be used; the UI shows an alert, then sets nil.
    var folderError: String? = nil
    /// Why something the user asked for couldn't be done; the UI shows an alert, then sets nil.
    var operationError: String? = nil
    /// How the saved folder's bookmark resolved at launch, for the diagnostics report.
    private(set) var bookmarkStatus: String = "not used"
    /// While the library is being moved to another folder, nothing may change.
    var isMovingLibrary = false

    // MARK: - Navigation

    private(set) var route: Route = .today
    private(set) var backStack: [Route] = []
    private(set) var forwardStack: [Route] = []
    /// The workplace a search was started from: what it may read.
    private(set) var searchOrigin: Workplace = .everywhere
    /// The toolbar search field. While it has text, the detail shows results.
    var searchText = "" {
        didSet { searchTextChanged() }
    }
    /// The words to select in the note that opens next: a search result opens at its first match.
    var pendingHighlight: [String] = []
    /// ⌘O.
    var isJumpPanelShown = false
    /// The sheet for a new space or for editing one.
    var spaceSheet: SpaceSheetRequest? = nil
    /// A new note whose title should be selected when its editor appears.
    var pendingTitleFocus: NoteRef? = nil

    // MARK: - What the sidebar shows

    private(set) var inboxCount = 0
    /// The folders of each space, by path. A sealed space's are known only while working inside it.
    private(set) var folders: [SpaceID: [ItemPath]] = [:]
    /// The tags the current workplace may see.
    private(set) var tags: [TagCount] = []
    /// Goes up whenever notes may have changed. Views that list notes ask again.
    private(set) var contentRevision = 0
    private(set) var isIndexing = false

    // MARK: - Editing and importing

    /// The note that is open, while `route` is a note.
    private(set) var session: EditorSession? = nil
    var importStatus: ImportStatus? = nil
    @ObservationIgnored var importTask: Task<Void, Never>?
    @ObservationIgnored var importDismissal: Task<Void, Never>?

    /// The main window's undo manager; `MainView` sets it from `@Environment(\.undoManager)`.
    @ObservationIgnored weak var undoManager: UndoManager?

    // MARK: - Private state

    let settings: AppSettings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let support: FolderAccess.SupportFolders
    @ObservationIgnored private var hasStarted = false
    /// Bumped by every attempt to open a folder; results of older attempts are dropped.
    @ObservationIgnored private var loadGeneration = 0
    /// Bumped whenever a library opens; work started for an earlier library is dropped.
    @ObservationIgnored private var librarySession = 0
    @ObservationIgnored private var sidebarGeneration = 0
    @ObservationIgnored private var savedFolder: SavedFolder?
    /// The folder of the last open attempt, for "Start a New Library Here".
    @ObservationIgnored private var attemptedRoot: URL?
    @ObservationIgnored private var attemptedSupport: FolderAccess.SupportFolders?
    /// The folder whose security scope was entered from a bookmark.
    @ObservationIgnored private var accessedFolder: URL?
    @ObservationIgnored private var watcher: LibraryWatcher?
    @ObservationIgnored private var watchedRootPath: String?
    @ObservationIgnored private var pendingChange = LibraryChange()
    @ObservationIgnored private var changeTask: Task<Void, Never>?
    /// Notes that were closed and are still being saved.
    @ObservationIgnored private var closingSessions: [EditorSession] = []
    private nonisolated static let log = CoreLog(category: "AppModel")

    /// A `-demo` screenshot of onboarding: no library is opened.
    @ObservationIgnored private let showsOnboardingScene: Bool

    init(options: LaunchOptions, settings: AppSettings, defaults: UserDefaults) {
        isDemo = options.isDemo
        showsOnboardingScene = options.demoScene.screen == .onboarding
        timeSource = options.timeSource
        self.settings = settings
        self.defaults = defaults
        support = .standard
    }

    /// Opens the library: the demo folder, the saved folder, or `.needsFolder`. Call once at launch;
    /// later calls do nothing.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        if isDemo, showsOnboardingScene {
            state = .needsFolder
        } else if isDemo {
            openDemoLibrary()
        } else if let saved = SavedFolder.load(from: defaults) {
            savedFolder = saved
            openSavedFolder(saved)
        } else {
            state = .needsFolder
        }
    }

    /// Whether the library can be changed right now.
    var canEdit: Bool { state == .ready && !isReadOnly && !isMovingLibrary }

    /// Whether things can be changed in a container: not in a read-only library or space.
    func canEdit(_ container: Container) -> Bool {
        guard canEdit else { return false }
        if case .space(let id) = container {
            return space(id).map { !$0.isReadOnly } ?? false
        }
        return true
    }

    func space(_ id: SpaceID) -> Space? {
        spaces.first { $0.id == id }
    }

    /// The space a container is, when it is one.
    func space(of container: Container) -> Space? {
        if case .space(let id) = container {
            return space(id)
        }
        return nil
    }

    // MARK: - Navigation

    /// Where the user is working: what search, links and suggestions may read.
    var workplace: Workplace {
        switch route {
        case .today: .everywhere
        case .inbox: .inbox
        case .folder(let container, _): Reach.workplace(of: container)
        case .tag(_, let workplace): workplace
        case .note(let note): Reach.workplace(of: note.container)
        case .search: searchOrigin
        }
    }

    /// Where new things go, from what is open: the folder shown, the folder of the note shown, or the
    /// Inbox.
    var currentPlace: (container: Container, folder: ItemPath) {
        switch route {
        case .folder(let container, let folder): (container, folder)
        case .note(let note): (note.container, note.path.folder)
        case .today, .inbox, .tag, .search: (.inbox, .root)
        }
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// Shows something, remembering where the user came from.
    func go(to destination: Route) {
        guard destination != route else { return }
        backStack.append(route)
        if backStack.count > 200 {
            backStack.removeFirst(backStack.count - 200)
        }
        forwardStack.removeAll()
        setRoute(destination)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(route)
        setRoute(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(route)
        setRoute(next)
    }

    /// Opens a note. `highlighting` selects the first of those words in it.
    func open(_ note: NoteRef, highlighting terms: [String] = []) {
        pendingHighlight = terms
        go(to: .note(note))
    }

    /// Every place that named `old` now names `new`: after a rename or a move.
    func replaceInNavigation(_ old: Route, with new: Route) {
        backStack = backStack.map { $0 == old ? new : $0 }
        forwardStack = forwardStack.map { $0 == old ? new : $0 }
        if route == old {
            route = new
        }
    }

    /// Takes a place that no longer exists out of the history, and leaves it if it is showing.
    func removeFromNavigation(where isGone: (Route) -> Bool) {
        backStack.removeAll(where: isGone)
        forwardStack.removeAll(where: isGone)
        if isGone(route) {
            setRoute(backStack.popLast() ?? .today)
        }
    }

    func requestTitleFocus(for note: NoteRef) {
        pendingTitleFocus = note
    }

    private func setRoute(_ destination: Route) {
        let previousWorkplace = workplace
        route = destination
        if case .note(let note) = destination {
            if session?.ref != note {
                closeSession()
                let session = EditorSession(ref: note, model: self)
                self.session = session
                session.load()
            }
        } else {
            closeSession()
        }
        if route != .search, !searchText.isEmpty, backStack.last != .search {
            // Leaving the results by other means than opening one ends the search.
            searchText = ""
        }
        if workplace != previousWorkplace {
            refreshSidebar()
        }
    }

    private func searchTextChanged() {
        let isSearching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isSearching, route != .search {
            searchOrigin = workplace
            go(to: .search)
        } else if !isSearching, route == .search {
            goBack()
        }
    }

    // MARK: - The open note

    private func closeSession() {
        guard let closing = session else { return }
        session = nil
        closingSessions.append(closing)
        Task {
            await closing.close()
            closingSessions.removeAll { $0 === closing }
        }
    }

    /// The session follows its note to a new place: after a rename, a move, or a conflict copy.
    func sessionMoved(from old: NoteRef, to new: NoteRef) {
        replaceInNavigation(.note(old), with: .note(new))
    }

    /// Whether an edit hasn't reached the disk yet.
    var hasPendingSaves: Bool {
        (session?.hasUnsavedChanges ?? false) || !closingSessions.isEmpty
    }

    /// Saves what is open and waits for notes that are still being saved, or until `timeout` passes.
    func finishPendingSaves(timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        await session?.flush()
        while !closingSessions.isEmpty, ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return
            }
        }
    }

    // MARK: - Content

    /// Notes may have changed: lists ask again and the sidebar's numbers are refreshed.
    func contentChanged() {
        contentRevision += 1
        refreshSidebar()
    }

    /// Indexes the given notes again after Elenath changed them, then lets the views know.
    func noteChanged(_ notes: [NoteRef]) async {
        guard let services else { return }
        var byContainer: [Container: [ItemPath]] = [:]
        for note in notes {
            byContainer[note.container, default: []].append(note.path)
        }
        for (container, paths) in byContainer {
            do {
                try await services.indexer.update(paths, in: container)
            } catch {
                AppModel.log.error("Could not index a saved note", private: String(describing: error))
            }
        }
        contentChanged()
    }

    /// Looks at a container's folder again after files or folders came or went.
    func containerChanged(_ containers: Set<Container>) async {
        guard let services else { return }
        for container in containers {
            do {
                try await services.indexer.refresh(container)
            } catch {
                AppModel.log.error("Could not refresh a container's index", private: String(describing: error))
            }
        }
        contentChanged()
    }

    func refreshSidebar() {
        guard let services, state == .ready else { return }
        sidebarGeneration += 1
        let generation = sidebarGeneration
        let workplace = workplace
        Task {
            let count = (try? await services.retrieval.inboxCount()) ?? 0
            var folders: [SpaceID: [ItemPath]] = [:]
            for destination in await services.retrieval.filingDestinations() {
                folders[destination.space] = destination.folders
            }
            // A sealed space's folders are known only from inside it.
            if case .space(let id) = workplace, self.space(id)?.isSealed == true {
                folders[id] = (try? await services.retrieval.folders(of: .space(id), from: workplace)) ?? []
            }
            let tags = (try? await services.retrieval.tags(from: workplace)) ?? []
            guard generation == sidebarGeneration else { return }
            self.inboxCount = count
            self.folders = folders
            self.tags = tags
        }
    }

    /// Shows a failure to the user.
    func report(_ error: any Error) {
        if error is CancellationError {
            return
        }
        AppModel.log.error("An operation failed", private: String(describing: error))
        operationError = LibraryMessages.operationFailed(error)
    }

    var showsRecoveryNotice: Bool {
        get { recoveryNotice != nil }
        set {
            if !newValue {
                recoveryNotice = nil
            }
        }
    }

    var showsFolderError: Bool {
        get { folderError != nil }
        set {
            if !newValue {
                folderError = nil
            }
        }
    }

    var showsOperationError: Bool {
        get { operationError != nil }
        set {
            if !newValue {
                operationError = nil
            }
        }
    }

    // MARK: - Spaces

    /// Reads the spaces again after one was added, changed or removed, in Elenath or in Finder.
    func reloadSpaces() async {
        guard let services, state == .ready else { return }
        do {
            let snapshot = try await services.catalog.open()
            apply(snapshot)
        } catch DocumentStoreError.missing {
            // The library folder itself is gone.
            let path = services.root.path
            closeLibrary()
            state = .folderMissing(path: path)
        } catch {
            AppModel.log.error("Could not read the spaces again", private: String(describing: error))
        }
    }

    private func apply(_ snapshot: LibrarySnapshot) {
        let before = Set(spaces.map(\.id))
        spaces = snapshot.spaces
        isReadOnly = snapshot.isReadOnly
        let now = Set(spaces.map(\.id))
        let gone = before.subtracting(now)
        if !gone.isEmpty {
            removeFromNavigation { route in
                switch route {
                case .folder(.space(let id), _): gone.contains(id)
                case .note(let note):
                    if case .space(let id) = note.container {
                        gone.contains(id)
                    } else {
                        false
                    }
                case .tag(_, .space(let id)): gone.contains(id)
                default: false
                }
            }
            if let services {
                Task {
                    for id in gone {
                        await services.indexer.removeIndex(of: .space(id))
                    }
                }
            }
        }
        if let notice = LibraryMessages.recovery(
            snapshot.recoveries,
            sealedByDefault: snapshot.sealedByDefault.compactMap { id in snapshot.spaces.first { $0.id == id }?.name })
        {
            recoveryNotice = notice
        }
    }

    // MARK: - Folders

    /// Uses the folder the user chose: `LibraryFolderPolicy` picks the folder itself (empty or already a
    /// library) or an `Elenath` subfolder; it is bookmarked, then opened or, if new, given an empty
    /// library.
    func useFolder(_ chosen: URL) {
        openChosenFolder(chosen, relocating: false)
    }

    /// "Locate Folder…": the same library in a new place. Only a library (or a folder that contains one
    /// named `Elenath`) is accepted, so a lost library is never quietly replaced by an empty one.
    func relocateFolder(_ chosen: URL) {
        openChosenFolder(chosen, relocating: true)
    }

    /// From `.noLibrary`: creates an empty library in that folder.
    func startFresh() {
        guard case .noLibrary = state, let root = attemptedRoot else { return }
        let support = attemptedSupport ?? support
        let generation = beginOpening()
        Task {
            await openLibrary(
                at: root, support: support, knownLibraryID: nil, createsLibrary: true, generation: generation)
        }
    }

    /// Tries the last folder again, e.g. after reconnecting a drive.
    func retryLoad() {
        switch state {
        case .ready, .loading:
            return
        case .needsFolder, .folderMissing, .noLibrary, .unreadable:
            break
        }
        if isDemo {
            openDemoLibrary()
        } else if let saved = savedFolder ?? SavedFolder.load(from: defaults) {
            savedFolder = saved
            openSavedFolder(saved)
        } else {
            state = .needsFolder
        }
    }

    private func beginOpening() -> Int {
        loadGeneration += 1
        closeLibrary()
        state = .loading
        return loadGeneration
    }

    /// Lets go of the open library: its watcher, its services and what was shown from it.
    private func closeLibrary() {
        watcher?.stop()
        watcher = nil
        watchedRootPath = nil
        changeTask?.cancel()
        pendingChange = LibraryChange()
        closeSession()
        services = nil
        spaces = []
        folders = [:]
        tags = []
        inboxCount = 0
        rootURL = nil
        librarySession += 1
    }

    private func openSavedFolder(_ saved: SavedFolder) {
        let generation = beginOpening()
        let bookmark = saved.bookmark
        Task {
            let resolution = await Task.detached(priority: .userInitiated) {
                FolderAccess.resolve(bookmark)
            }.value
            guard generation == loadGeneration else {
                // A newer attempt took over: leave the scope this one entered, so starts and stops balance.
                if case .available(let url, _, let isAccessing) = resolution, isAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
                return
            }
            let madeBy = saved.madeByVersion ?? "an earlier version"
            switch resolution {
            case .unresolvable:
                bookmarkStatus = "did not resolve (made by \(madeBy))"
                state = .folderMissing(path: saved.path)
            case .missing:
                bookmarkStatus = "resolved to a folder that is gone (made by \(madeBy))"
                state = .folderMissing(path: saved.path)
            case .available(let url, let refreshedBookmark, let isAccessing):
                bookmarkStatus =
                    "resolved\(refreshedBookmark == nil ? "" : ", was stale and was renewed")"
                    + "\(isAccessing ? "" : ", without a security scope") (made by \(madeBy))"
                var updated = saved
                updated.bookmark = refreshedBookmark ?? saved.bookmark
                updated.path = url.path
                if refreshedBookmark != nil {
                    updated.madeByVersion = SavedFolder.currentVersion
                }
                if updated != saved {
                    rememberFolder(updated)
                }
                if isAccessing {
                    enterAccessedFolder(url)
                }
                await openLibrary(
                    at: url, support: support, knownLibraryID: saved.libraryID, createsLibrary: false,
                    generation: generation)
            }
        }
    }

    private func openChosenFolder(_ chosen: URL, relocating: Bool) {
        guard !isDemo else {
            folderError = LibraryMessages.demoCannotChangeFolder
            return
        }
        let previousState = state
        let generation = beginOpening()
        Task {
            let prepared: FolderAccess.PreparedFolder
            do {
                prepared = try await Task.detached(priority: .userInitiated) {
                    try FolderAccess.prepare(chosen, relocating: relocating)
                }.value
            } catch {
                guard generation == loadGeneration else { return }
                AppModel.log.error("Could not use the chosen folder", private: String(describing: error))
                folderError = LibraryMessages.cannotUseFolder(error)
                if previousState == .ready || previousState == .loading {
                    retryLoadAfterFailedChoice()
                } else {
                    state = previousState
                }
                return
            }
            guard generation == loadGeneration else { return }
            let libraryID = relocating ? savedFolder?.libraryID : nil
            rememberFolder(
                SavedFolder(
                    bookmark: prepared.bookmark, path: prepared.root.path, libraryID: libraryID,
                    madeByVersion: SavedFolder.currentVersion))
            bookmarkStatus = "made just now"
            leaveAccessedFolder()
            await openLibrary(
                at: prepared.root, support: support, knownLibraryID: libraryID, createsLibrary: !prepared.hasLibrary,
                generation: generation)
        }
    }

    /// The folder that was open before a choice that didn't work out is opened again.
    private func retryLoadAfterFailedChoice() {
        if let saved = savedFolder {
            openSavedFolder(saved)
        } else {
            state = .needsFolder
        }
    }

    private func openDemoLibrary() {
        let generation = beginOpening()
        let now = timeSource.now
        Task {
            let folders: FolderAccess.DemoFolders
            do {
                folders = try await Task.detached(priority: .userInitiated) {
                    try FolderAccess.makeDemoFolders()
                }.value
                _ = try await DemoLibrary.write(
                    to: folders.root, safetyDirectory: folders.support.safetyCopies, now: now, timeZone: .current,
                    fileSystem: LocalFileSystem())
            } catch {
                guard generation == loadGeneration else { return }
                state = .unreadable(path: "", message: LibraryMessages.couldNotSetUpDemo(error))
                return
            }
            guard generation == loadGeneration else { return }
            await openLibrary(
                at: folders.root, support: folders.support, knownLibraryID: nil, createsLibrary: false,
                generation: generation)
        }
    }

    /// Opens the library in `root`, or creates an empty one there, and moves to the matching state.
    private func openLibrary(
        at root: URL, support: FolderAccess.SupportFolders, knownLibraryID: UUID?, createsLibrary: Bool,
        generation: Int
    ) async {
        attemptedRoot = root
        attemptedSupport = support
        await Task.detached(priority: .userInitiated) {
            FolderAccess.prepareDirectory(support.safetyCopies)
        }.value
        guard generation == loadGeneration else { return }
        let catalog = LibraryCatalog(
            root: root, safetyDirectory: support.safetyCopies, knownLibraryID: knownLibraryID.map { LibraryID($0) },
            fileSystem: LocalFileSystem(), timeSource: timeSource)
        do {
            let snapshot = createsLibrary ? try await catalog.create() : try await catalog.open()
            guard generation == loadGeneration else { return }
            didOpen(snapshot, catalog: catalog, root: root, support: support)
        } catch DocumentStoreError.missing {
            let exists = await Task.detached(priority: .userInitiated) {
                FolderAccess.folderExists(at: root)
            }.value
            guard generation == loadGeneration else { return }
            state = exists ? .noLibrary(path: root.path) : .folderMissing(path: root.path)
        } catch let error as DocumentStoreError {
            guard generation == loadGeneration else { return }
            AppModel.log.error("The library can't be opened", private: String(describing: error))
            state = .unreadable(path: root.path, message: LibraryMessages.damaged)
        } catch {
            guard generation == loadGeneration else { return }
            AppModel.log.error("Could not open the library", private: String(describing: error))
            let message = createsLibrary ? LibraryMessages.couldNotCreate(error) : LibraryMessages.couldNotOpen(error)
            state = .unreadable(path: root.path, message: message)
        }
    }

    private func didOpen(
        _ snapshot: LibrarySnapshot, catalog: LibraryCatalog, root: URL, support: FolderAccess.SupportFolders
    ) {
        librarySession += 1
        let fileSystem = LocalFileSystem()
        let indexDirectory = support.index.appending(
            component: snapshot.id.rawValue.uuidString, directoryHint: .isDirectory)
        let notes = NoteStore(catalog: catalog, fileSystem: fileSystem, timeSource: timeSource)
        let indexer = Indexer(catalog: catalog, indexDirectory: indexDirectory, fileSystem: fileSystem)
        let retrieval = Retrieval(indexDirectory: indexDirectory, spaces: { await catalog.spaces() })
        let importer = Importer(
            noteStore: notes, converter: DocumentConverter(), fileSystem: fileSystem, timeSource: timeSource)
        services = LibraryServices(
            catalog: catalog, notes: notes, indexer: indexer, retrieval: retrieval, importer: importer, root: root,
            support: support)
        libraryID = snapshot.id
        rootURL = root
        spaces = []
        apply(snapshot)
        backStack = []
        forwardStack = []
        route = .today
        searchText = ""
        // Undo steps belong to the library that was open before.
        undoManager?.removeAllActions(withTarget: self)
        if !isDemo, var saved = savedFolder, saved.libraryID != snapshot.id.rawValue {
            saved.libraryID = snapshot.id.rawValue
            rememberFolder(saved)
        }
        state = .ready
        startWatching(root)
        startIndexing()
    }

    func rememberFolder(_ folder: SavedFolder) {
        savedFolder = folder
        guard !isDemo else { return }
        folder.save(to: defaults)
    }

    /// Records a folder whose security scope `FolderAccess.resolve` just entered. Entering the same folder
    /// again (a retry) leaves the extra scope at once, so every start is balanced by a stop.
    private func enterAccessedFolder(_ url: URL) {
        if accessedFolder == url {
            url.stopAccessingSecurityScopedResource()
            return
        }
        leaveAccessedFolder()
        accessedFolder = url
    }

    /// Leaves the current folder's security scope once the notes that were open are saved.
    private func leaveAccessedFolder() {
        guard let previous = accessedFolder else { return }
        accessedFolder = nil
        Task {
            await finishPendingSaves(timeout: .seconds(5))
            previous.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - Indexing and watching

    private func startIndexing() {
        guard let services else { return }
        let session = librarySession
        isIndexing = true
        refreshSidebar()
        Task {
            await services.indexer.refreshAll()
            guard session == librarySession else { return }
            isIndexing = false
            contentChanged()
        }
    }

    /// Fills every index again from the folder: Settings › Files › Rebuild Index.
    func rebuildIndex() async {
        guard let services else { return }
        isIndexing = true
        for container in [Container.inbox] + spaces.map({ Container.space($0.id) }) {
            do {
                try await services.indexer.rebuild(container)
            } catch {
                AppModel.log.error("Could not rebuild an index", private: String(describing: error))
            }
        }
        isIndexing = false
        contentChanged()
    }

    private func startWatching(_ root: URL) {
        let session = librarySession
        Task { [weak self] in
            let resolved = await Task.detached(priority: .utility) {
                FolderAccess.resolvedPath(of: root)
            }.value
            guard let self, session == librarySession else { return }
            watchedRootPath = resolved
            let watcher = LibraryWatcher(root: root) { [weak self] change in
                self?.folderChanged(change)
            }
            watcher.start()
            self.watcher = watcher
        }
    }

    /// The watcher saw something. Changes are gathered for a moment, so a burst is handled once.
    private func folderChanged(_ change: WatchedChange) {
        guard state == .ready, let rootPath = watchedRootPath else { return }
        if change.needsRescan {
            var everything = LibraryChange()
            everything.reloadsCatalog = true
            pendingChange.merge(everything)
        } else {
            pendingChange.merge(
                LibraryPathClassifier.classify(paths: change.paths, rootPath: rootPath, spaces: spaces))
        }
        guard !pendingChange.isEmpty, changeTask == nil else { return }
        let session = librarySession
        changeTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard session == librarySession else { return }
            changeTask = nil
            await processPendingChange()
        }
    }

    private func processPendingChange() async {
        guard let services, state == .ready else { return }
        let change = pendingChange
        pendingChange = LibraryChange()
        var containers = change.containers
        if change.reloadsCatalog {
            await reloadSpaces()
            guard state == .ready else { return }
            containers = Set([Container.inbox] + spaces.map { Container.space($0.id) })
        }
        var moves: [NoteMove] = []
        for container in containers {
            do {
                moves += try await services.indexer.refresh(container).moved
            } catch {
                AppModel.log.error("Could not refresh an index after a change", private: String(describing: error))
            }
        }
        // A note that was renamed or moved in Finder while it is open is followed to its new place.
        for move in moves {
            if session?.ref == move.from {
                await session?.follow(to: move.to)
            } else {
                replaceInNavigation(.note(move.from), with: .note(move.to))
            }
        }
        if let session, change.notes.contains(session.ref) || change.reloadsCatalog {
            await session.fileMayHaveChanged()
        }
        contentChanged()
    }
}

/// What the space sheet is for.
enum SpaceSheetRequest: Identifiable, Hashable {
    case new
    case edit(SpaceID)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let id): id.rawValue.uuidString
        }
    }
}

/// How an import is going, for the card at the foot of the sidebar.
struct ImportStatus: Equatable {
    enum Phase: Equatable {
        case running(completed: Int, total: Int, currentName: String?)
        /// `archives` counts the .zip files that were copied as they are: an exported chat has to be
        /// unpacked first, and the card says so.
        case finished(notes: Int, files: Int, skipped: Int, failed: Int, archives: Int)
    }

    var phase: Phase
    /// Where the import went, to show it afterwards.
    var destination: Route
    var destinationName: String
}
