import AppKit
import ElenathCore

/// The crash check's calendar steps: Ithil's views and actions inside Elenath, on the demo library's
/// calendar only.
extension DemoSelfCheck {
    func useCalendar() async throws {
        let calendar = model.calendar
        try await waitFor("the calendar to open", seconds: 30) { calendar.state == .ready }
        try await visit(.calendar)
        for span in [CalendarSpan.day, .week, .month] {
            calendar.span = span
            try await settle(seconds: 0.4)
            calendar.step(1)
            try await settle(seconds: 0.2)
            calendar.step(-2)
            try await settle(seconds: 0.2)
            calendar.goToToday()
            try await settle(seconds: 0.2)
        }
        calendar.span = .week

        // The details of an event of each kind: one homed in Uni, one sealed in Red Cross, one without a home.
        for title in ["Physics Lecture", "Ambulance shift", "Lunch with Mara"] {
            guard
                let occurrence = calendar.occurrences(in: calendar.visibleDays).first(where: { $0.event.title == title }
                )
            else { continue }
            calendar.selectedOccurrenceID = occurrence.id
            calendar.pendingDetailsOccurrenceID = occurrence.id
            try await settle(seconds: 0.5)
        }

        // Add, edit, move and delete an event, then undo and redo all of it.
        var event = calendar.newEvent(on: calendar.today, startMinute: 10 * 60)
        event.title = "Self-check event"
        try await calendarAct("add an event") { calendar.add(event) }
        guard let added = occurrence(of: event.id) else { throw Failure(description: "the new event isn't there") }
        var edited = added.event
        edited.title = "Self-check event, edited"
        edited.location = "Room 1"
        try await calendarAct("edit it") { calendar.update(added, with: edited, scope: .thisEvent) }
        guard let current = occurrence(of: event.id) else { throw Failure(description: "the edited event isn't there") }
        var moved = current.event
        if case .timed(let start, let end, let zone) = moved.timing {
            moved.timing = .timed(
                start: start.addingTimeInterval(3600), end: end.addingTimeInterval(3600), timeZone: zone)
        }
        try await calendarAct("move it") {
            calendar.update(current, with: moved, scope: .thisEvent, undoAction: .moveEvent)
        }

        // Files dropped on it are copied into its folder.
        guard let withFiles = occurrence(of: event.id) else {
            throw Failure(description: "the moved event isn't there")
        }
        let source = FileManager.default.temporaryDirectory.appending(component: "Self-check handout.txt")
        try Data("handout".utf8).write(to: source)
        files.addFiles([source], to: withFiles)
        try await waitFor("the file to be copied", seconds: 30) { self.files.imports.isEmpty }
        try await settle(seconds: 0.5)
        try check(files.lastError == nil, "copying a file into an event: \(files.lastError ?? "")")

        try await calendarAct("delete it") { calendar.delete(withFiles, scope: .thisEvent) }
        try await undoAll(4)
        try await redoAll(4)

        // Working inside the sealed space, and everywhere again.
        if let sealed = model.spaces.first(where: { $0.isSealed }) {
            calendar.work(in: .space(sealed.id))
            try await settle(seconds: 0.3)
            calendar.work(in: .everywhere)
        }

        // Quick Capture's event line.
        let text = "physics quiz thursday 10am"
        guard let draft = calendar.captureEvent(for: text) else {
            throw Failure(description: "Quick Capture found no event in “\(text)”")
        }
        let captured = calendar.makeEvent(from: draft)
        try await calendarAct("add an event from Quick Capture") { calendar.add(captured) }
        try check(calendar.captureEvent(for: "just a thought about tea") == nil, "a plain note became an event")

        // A note for an event, in its subject's home.
        if let lecture = calendar.occurrences(in: calendar.visibleDays).first(where: {
            $0.event.title == "Physics Lecture"
        }) {
            let home = calendar.reach.home(of: lecture.event)
            try await act("a note for an event") { self.model.newNote(for: lecture, home: home) }
            try check(model.route != .calendar, "the note for the event didn't open")
            try await visit(.calendar)
        }

        // Subjects and homes.
        let subject = Subject(name: "Self-check subject", color: .palette(.iris))
        try await calendarAct("add a subject") { calendar.addSubject(subject) }
        if let uni = model.spaces.first(where: { $0.name == "Uni" }) {
            calendar.setHome(SubjectHome(space: uni.id), forSubject: subject.id)
            try await settle(seconds: 0.5)
        }
        var renamed = subject
        renamed.name = "Self-check subject, renamed"
        try await calendarAct("rename it") { calendar.updateSubject(renamed) }
        try await calendarAct("delete it") { calendar.deleteSubject(id: subject.id) }
        try await undoAll(1)

        // The calendar's search, with and without results.
        calendar.searchText = "lecture"
        try await settle(seconds: 0.4)
        calendar.searchText = "nothing by this name"
        try await settle(seconds: 0.4)
        calendar.searchText = ""
        try await settle()
    }

    func bringInIthil() async throws {
        let calendar = model.calendar
        let folder = FileManager.default.temporaryDirectory.appending(
            component: "Self-check Ithil \(UUID().uuidString)", directoryHint: .isDirectory)
        try DemoLibrary.writeIthilFolder(to: folder, now: calendar.now, timeZone: calendar.timeZone)
        defer { try? FileManager.default.removeItem(at: folder) }
        for run in 1...2 {
            guard let calendarFolder = calendar.rootURL, let root = model.rootURL, let eventFolders = files.eventFolders
            else { throw Failure(description: "the calendar isn't open") }
            let result = try await CalendarImport.run(
                from: folder, into: calendar.library, calendarFolder: calendarFolder, libraryRoot: root,
                eventFolders: eventFolders, fileSystem: LocalFileSystem())
            try check(result.report.countsMatch, "bringing in, run \(run): the counts don't match")
            if run == 2 {
                try check(
                    result.report.eventsAdded == 0 && result.report.filesCopied == 0,
                    "the second run brought things in twice")
            }
            try await calendarAct("bring in an Ithil calendar, run \(run)") { calendar.bringIn(result.document) }
        }
        try await undoAll(1)
        try await redoAll(1)
    }

    // MARK: - Helpers

    /// Runs a calendar change and fails when the calendar or its files report an error.
    private func calendarAct(_ name: String, _ body: () -> Void) async throws {
        say("SELF-CHECK   \(name)")
        body()
        try await settle(seconds: 0.3)
        try await waitFor("the calendar to save", seconds: 30) { !self.model.calendar.hasPendingSaves }
        if let error = model.calendar.saveError {
            throw Failure(description: "\(name): the calendar reported: \(error)")
        }
        if let error = files.lastError {
            throw Failure(description: "\(name): the files reported: \(error)")
        }
    }

    private func undoAll(_ times: Int) async throws {
        guard let undoManager = model.undoManager else { throw Failure(description: "no undo manager") }
        for _ in 0..<times where undoManager.canUndo {
            let name = "undo \(undoManager.undoActionName)"
            try await calendarAct(name) { undoManager.undo() }
            try await stepsDone()
        }
    }

    private func redoAll(_ times: Int) async throws {
        guard let undoManager = model.undoManager else { throw Failure(description: "no undo manager") }
        for _ in 0..<times where undoManager.canRedo {
            let name = "redo \(undoManager.redoActionName)"
            try await calendarAct(name) { undoManager.redo() }
            try await stepsDone()
        }
    }

    private func occurrence(of eventID: UUID) -> Occurrence? {
        guard let event = model.calendar.library.event(withID: eventID) else { return nil }
        return model.calendar.occurrence(id: Occurrence.ID(eventID: eventID, date: event.timing.startDate))
    }
}
