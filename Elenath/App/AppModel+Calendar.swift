import AppKit
import ElenathCore
import Foundation

/// The calendar inside Elenath: it opens and closes with the library, follows its spaces and subject
/// homes, and its notes ("Notes for this lecture") are ordinary notes in the subject's home.
extension AppModel {
    /// Hooks the calendar up to the library. Called once, at launch.
    func connectCalendar() {
        calendar.start()
        calendar.saveSettings = { [weak self] settings in
            guard let services = self?.services else { return }
            try await services.catalog.saveCalendarSettings(settings)
        }
        calendar.showCalendar = { [weak self] in
            self?.showCalendar()
        }
        calendar.workplaceChanged = { [weak self] in
            self?.workplaceMayHaveChanged()
        }
        calendar.eventFilesMayHaveChanged = { [weak self] in
            self?.eventFoldersMayHaveChanged()
        }
    }

    /// The library's spaces or settings were read again: the calendar follows, and opens once a space from
    /// Elenath 0.1 that had its name was renamed.
    func calendarSnapshotChanged(_ snapshot: LibrarySnapshot) {
        calendar.libraryChanged(spaces: snapshot.spaces, calendarSettings: snapshot.calendarSettings)
        if case .nameTakenBySpace = calendar.state, snapshot.spaceNamedCalendar == nil, let services, let libraryID {
            calendar.open(
                libraryRoot: services.root, libraryID: libraryID, safetyDirectory: services.support.safetyCopies,
                snapshot: snapshot)
        }
    }

    /// Shows the calendar in the main window.
    func showCalendar() {
        go(to: .calendar)
    }

    /// Opens the space sheet for a space from Elenath 0.1 called "Calendar", to rename it.
    func renameSpaceNamedCalendar(_ id: SpaceID) {
        guard canEdit, space(id) != nil else { return }
        spaceSheet = .edit(id)
    }

    /// Shows the calendar's folder in Finder (or the library's, when the calendar has none).
    func showCalendarFolderInFinder() {
        guard let rootURL else { return }
        let folder = LibraryLayout.calendarFolder(in: rootURL)
        let target = FileManager.default.fileExists(atPath: folder.path) ? folder : rootURL
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    // MARK: - Notes for an event

    /// The notes linked to an occurrence ("Notes for this lecture"), as far as `workplace` may read them.
    /// The calendar asks only where the event's own content may be read (`CalendarReach`).
    func notes(linkedTo occurrence: Occurrence, from workplace: Workplace) async -> [NoteHit] {
        guard let services else { return [] }
        do {
            return try await services.retrieval.notes(linkedTo: EventLink(occurrence), from: workplace)
        } catch {
            AppModel.calendarLog.error("Could not find an event's notes", private: String(describing: error))
            return []
        }
    }

    /// Makes a note for an occurrence in its home (the Inbox without one), linked to it, and opens it. One
    /// undo step.
    func newNote(for occurrence: Occurrence, home: SubjectHome?) {
        let container: Container = home.map { .space($0.space) } ?? .inbox
        let folder = home?.folder ?? .root
        guard canEdit(container) else {
            NSSound.beep()
            return
        }
        let title = EventFormatting.noteTitle(for: occurrence, timeZone: calendar.timeZone)
        run(
            String(localized: "New Note", comment: "Undo action name"),
            UndoableStep { model in
                guard let services = model.services else { return nil }
                let note = try await services.notes.create(
                    title: title, in: folder, container: container, event: EventLink(occurrence))
                await model.noteChanged([note.ref])
                await model.containerChanged([container])
                model.open(note.ref)
                return AppModel.trashNoteStep(note.ref)
            })
    }

    nonisolated static let calendarLog = CoreLog(category: "AppModel.Calendar")
}
