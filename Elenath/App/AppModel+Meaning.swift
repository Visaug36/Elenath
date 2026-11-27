import AppKit
import ElenathCore
import Foundation

/// Reading files and finding meaning in the background, the event files the index holds, and pausing both
/// (docs/ARCHITECTURE.md, "Meaning"; docs/DESIGN.md, Settings › Files).
///
/// - Keyword search works from the first moment and never waits for any of this.
/// - One background pass at a time: asked again while it runs, it runs once more afterwards.
/// - Pausing, by the user or Low Power Mode, holds back only reading files and making vectors: notes are
///   indexed as they are saved.
extension AppModel {
    /// Gives the index this Mac's text extractor and embedder, and follows Low Power Mode.
    func startMeaning(_ services: LibraryServices) async {
        await services.indexer.setTextExtractor(SystemTextExtractor())
        let embedder = ContextualEmbedder()
        await services.indexer.setEmbedder(embedder)
        await services.retrieval.setEmbedder(embedder)
        meaningScripts = (await embedder.models()).map(\.script).sorted()
        observePowerState()
        applyIndexingPause()
    }

    // MARK: - The background pass

    /// Reads the files that wait and makes the vectors that are missing, in the background.
    func scheduleBackgroundIndexing() {
        guard let services, state == .ready else { return }
        guard backgroundIndexing == nil else {
            backgroundIndexingAgain = true
            return
        }
        let session = librarySession
        backgroundIndexing = Task {
            repeat {
                backgroundIndexingAgain = false
                let read = await services.indexer.readAllFiles()
                let made = await services.indexer.embedAll()
                guard session == librarySession, !Task.isCancelled else { return }
                await refreshBacklog()
                if read > 0 || made > 0 {
                    contentChanged()
                }
            } while backgroundIndexingAgain && session == librarySession && !Task.isCancelled
            if session == librarySession {
                backgroundIndexing = nil
            }
        }
    }

    /// Counts what reading files and finding meaning still have to do, for Settings › Files.
    func refreshBacklog() async {
        guard let services else { return }
        indexBacklog = await services.indexer.backlog()
        if meaningScripts?.isEmpty ?? true {
            meaningScripts = (await services.indexer.embeddingScripts()).sorted()
        }
    }

    // MARK: - Pausing

    /// Pauses reading files and finding meaning, or lets them go on.
    func setIndexingPaused(_ paused: Bool) {
        isIndexingPausedByUser = paused
        applyIndexingPause()
    }

    /// Whether the background passes are held back now: by the user, or by Low Power Mode.
    var isIndexingPaused: Bool {
        isIndexingPausedByUser || isLowPowerMode
    }

    private func applyIndexingPause() {
        guard let services else { return }
        let paused = isIndexingPaused
        Task {
            if paused {
                await services.indexer.pause()
            } else {
                await services.indexer.resume()
            }
        }
    }

    private func observePowerState() {
        guard powerObserver == nil else { return }
        powerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
                self.applyIndexingPause()
            }
        }
    }

    // MARK: - Event files

    /// Works out again which event files the index holds, and in which space, whenever the events, a subject's
    /// home or an event folder may have changed. At once, never after a pause: a file whose event moved into a
    /// sealed space leaves the open one first.
    func eventFoldersMayHaveChanged() {
        guard services != nil, state == .ready else { return }
        guard eventFolderTask == nil else {
            eventFoldersAgain = true
            return
        }
        let session = librarySession
        eventFolderTask = Task {
            repeat {
                eventFoldersAgain = false
                await updateEventFolders()
            } while eventFoldersAgain && session == librarySession && !Task.isCancelled
            guard session == librarySession else { return }
            eventFolderTask = nil
            scheduleBackgroundIndexing()
        }
    }

    private func updateEventFolders() async {
        guard let services, calendar.state == .ready, let calendarFolder = calendar.rootURL,
            let folders = eventFolders?()
        else { return }
        let reach = CalendarReach(workplace: .everywhere, spaces: spaces, settings: calendar.calendarSettings)
        let document = calendar.library
        let marked = await folders.markedFolders()
        await services.indexer.setEventFolders(
            reach.indexedHomes(of: marked, in: document, calendarFolder: calendarFolder))
    }

    // MARK: - Opening what was found

    /// Opens a search or related hit: a note in the editor (at its first match), a file in its app, a file of an
    /// event's folder in Finder.
    func open(_ hit: SearchHit) {
        switch hit.item {
        case .note(let note):
            open(note, highlighting: hit.matchedTerms)
        case .file(let container, let path):
            openFile(path, in: container)
        case .eventFile(_, _, let path):
            revealEventFile(path)
        }
    }

    /// The event a hit's event file belongs to, by its title and day, from the calendar: what the hit's place
    /// line shows. A title crosses every seal, and the hit itself came only from where its home may be read.
    func eventLabel(of link: EventLink) -> (title: String, day: String)? {
        guard let id = link.occurrenceID, let event = calendar.library.events.first(where: { $0.id == id.eventID })
        else { return nil }
        let day = id.date.start(in: calendar.timeZone).formatted(
            .dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return (event.title, day)
    }
}
