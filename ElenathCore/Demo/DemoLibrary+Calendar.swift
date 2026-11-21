import Foundation

/// The demo library's calendar: Ithil's sample week (`DemoCalendar`) with each subject homed in a space,
/// a Red Cross subject whose events are sealed, a few event files and a note for one lecture. And a
/// separate Ithil folder to try "Bring in my Ithil calendar" with. Everything in it is invented.
extension DemoLibrary {
    /// The calendar's id, fixed like every other id of the demo.
    static let calendarID = UUID(uuidString: "4954484C-DE30-4000-8000-000000000001")!

    /// Writes the calendar into the demo library: events.json, the subjects' homes in library.json, event
    /// files and a note linked to one lecture.
    static func writeCalendar(
        catalog: LibraryCatalog, notes: NoteStore, libraryID: LibraryID, root: URL, safetyDirectory: URL,
        now: Date, timeZone: TimeZone, fileSystem: any FileSystem
    ) async throws {
        let spaces = await catalog.spaces()
        guard let uni = spaces.first(where: { $0.name == "Uni" }),
            let redCross = spaces.first(where: { $0.name == "Red Cross" })
        else { return }

        let week = DemoWeek(now: now, timeZone: timeZone)
        var calendar = DemoCalendar.make(weekContaining: now, timeZone: timeZone)
        calendar.id = calendarID
        let shifts = Subject(
            id: demoID(1, 6), name: "Red Cross", color: SubjectColor(hexString: "#C2453D") ?? .palette(.rose),
            keywords: ["shift", "first aid"])
        calendar.subjects.append(shifts)
        let shift = Event(
            id: demoID(3, 1), title: "Ambulance shift",
            timing: .timed(start: week.instant(day: 5, 18, 0), end: week.instant(day: 5, 23, 0), timeZone: timeZone),
            subjectID: shifts.id, location: "Harbour post",
            notes: "Meet at the post 15 minutes early. Radio check with the coordinator.", alert: .oneHour,
            createdAt: week.createdAt)
        let course = Event(
            id: demoID(3, 2), title: "First aid course",
            timing: .timed(start: week.instant(day: 2, 19, 0), end: week.instant(day: 2, 21, 0), timeZone: timeZone),
            subjectID: shifts.id, location: "Community hall",
            notes: "Session 4: burns and scalds. Bring the training manikin.", alert: .oneHour,
            recurrence: RecurrenceRule(frequency: .weekly), createdAt: week.createdAt)
        calendar.events += [shift, course]

        let store = CalendarStore(
            libraryRoot: root, libraryID: libraryID, safetyDirectory: safetyDirectory, knownCalendarID: calendarID,
            fileSystem: fileSystem, timeSource: FixedTimeSource(now))
        _ = try await store.load()
        try await store.save(calendar)

        var settings = CalendarSettings(calendarID: calendarID)
        let homes: [(String, Space, String)] = [
            ("Physics", uni, "Physics"), ("Linear Algebra", uni, "Linear Algebra"), ("Literature", uni, "Literature"),
            ("Biology", uni, "Biology"), ("Red Cross", redCross, "Shifts"),
        ]
        for (subjectName, space, folder) in homes {
            if let subject = calendar.subjects.first(where: { $0.name == subjectName }), let path = ItemPath(folder) {
                settings.setHome(SubjectHome(space: space.id, folder: path), forSubject: subject.id)
            }
        }
        try await catalog.saveCalendarSettings(settings)

        // Files in a few events' folders: one sealed (the shift's), two in Uni.
        let expander = OccurrenceExpander(displayTimeZone: timeZone)
        let occurrences = expander.occurrences(of: calendar.events, in: week.interval)
        func occurrence(_ title: String, day: Int) -> Occurrence? {
            occurrences.first { $0.event.title == title && $0.date == week.monday.adding(days: day) }
        }
        let files: [(String, Int, String, Data)] = [
            ("Physics Lecture", 1, "Slides - rotation.pdf", DemoFiles.pdf(text: "Rotation: torque and inertia")),
            ("Physics Lecture", 1, "Problem sheet 6.txt", Data("1. A wheel spins up from rest…\n".utf8)),
            ("Biology Lab", 0, "Lab sheet - osmosis.txt", Data("Potato cylinders in five salt solutions.\n".utf8)),
            ("Ambulance shift", 5, "Shift rota.pdf", DemoFiles.pdf(text: "Shift rota, harbour post")),
        ]
        for (title, day, name, data) in files {
            guard let occurrence = occurrence(title, day: day) else { continue }
            let folder = try await store.eventFolders.ensureFolder(for: occurrence)
            try fileSystem.writeAtomically(data, to: folder.appending(component: name, directoryHint: .notDirectory))
        }

        // A note for Thursday's lecture, in the subject's home.
        if let thursday = occurrence("Physics Lecture", day: 3) {
            let written = now.addingTimeInterval(-30 * 60)
            let note = try await notes.create(
                title: "Lecture 9 notes", in: ItemPath("Physics")!, container: .space(uni.id),
                body: "To read before the lecture: section 10.4, rolling motion.\n\n- [ ] Bring problem set 4\n",
                created: written, event: EventLink(thursday))
            let url = try await catalog.url(for: note.ref.path, in: .space(uni.id), isDirectory: false)
            try? FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: url.path)
        }
    }

    /// Writes an Ithil 1.0.0 folder into `folder` (which must be empty or missing), to try "Bring in my
    /// Ithil calendar" with: a subject and two events the demo calendar doesn't have, one it has (by id),
    /// and event folders with files, one of them already in the demo calendar.
    public static func writeIthilFolder(to folder: URL, now: Date, timeZone: TimeZone) throws {
        let week = DemoWeek(now: now, timeZone: timeZone)
        let demo = DemoCalendar.make(weekContaining: now, timeZone: timeZone)
        let chemistry = Subject(id: demoID(1, 7), name: "Chemistry", color: .palette(.fern), keywords: ["chem"])
        let physics = demo.subjects.first { $0.name == "Physics" }
        let tutorial = Event(
            id: demoID(4, 1), title: "Chemistry tutorial",
            timing: .timed(start: week.instant(day: 3, 11, 0), end: week.instant(day: 3, 12, 0), timeZone: timeZone),
            subjectID: chemistry.id, location: "Room C12", alert: .tenMinutes,
            recurrence: RecurrenceRule(frequency: .weekly), createdAt: week.createdAt)
        let books = Event(
            id: demoID(4, 2), title: "Return library books",
            timing: .allDay(start: week.monday.adding(days: 4), end: week.monday.adding(days: 4)),
            createdAt: week.createdAt)
        var events = [tutorial, books]
        if let lecture = demo.events.first(where: { $0.title == "Physics Lecture" }) {
            events.append(lecture)
        }
        let ithil = CalendarDocument(
            id: demoID(0, 2), subjects: [chemistry] + (physics.map { [$0] } ?? []), events: events)

        let metadata = folder.appending(
            component: LibraryLayout.calendarMetadataFolderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true, attributes: nil)
        try DocumentCodec.encode(ithil, savedAt: week.createdAt).write(
            to: metadata.appending(component: CalendarDocument.fileName, directoryHint: .notDirectory))

        let expander = OccurrenceExpander(displayTimeZone: timeZone)
        let occurrences = expander.occurrences(of: events, in: week.interval)
        let files: [(String, Int, String, Data)] = [
            ("Chemistry tutorial", 3, "Worksheet 3.txt", Data("Balance these equations…\n".utf8)),
            ("Physics Lecture", 1, "Slides - rotation.pdf", DemoFiles.pdf(text: "Rotation: torque and inertia")),
        ]
        for (title, day, name, data) in files {
            guard
                let occurrence = occurrences.first(where: {
                    $0.event.title == title && $0.date == week.monday.adding(days: day)
                })
            else { continue }
            let eventFolder = folder.appending(
                path: FolderNaming.relativePath(for: occurrence), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: eventFolder, withIntermediateDirectories: true, attributes: nil)
            let marker = EventFolderMarker(eventID: occurrence.event.id, date: occurrence.date)
            try marker.markerFileData().write(
                to: eventFolder.appending(component: EventFolderMarker.fileName, directoryHint: .notDirectory))
            try data.write(to: eventFolder.appending(component: name, directoryHint: .notDirectory))
        }
    }

    /// A fixed, valid version 4 UUID in the demo calendar's scheme: 4954484C-DE30-4000-8000-00000000GGNN.
    private static func demoID(_ group: UInt8, _ number: UInt8) -> UUID {
        UUID(uuid: (0x49, 0x54, 0x48, 0x4C, 0xDE, 0x30, 0x40, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, group, number))
    }
}

/// The Monday-start week that contains `now`, as `DemoCalendar` places its events.
private struct DemoWeek {
    let monday: CalendarDate
    let timeZone: TimeZone
    let createdAt: Date

    init(now: Date, timeZone: TimeZone) {
        let today = CalendarDate(now, in: timeZone)
        monday = today.adding(days: -((today.weekday + 5) % 7))
        self.timeZone = timeZone
        createdAt = monday.start(in: timeZone)
    }

    /// The week and the one after it.
    var interval: DateInterval {
        DateInterval(start: monday.start(in: timeZone), end: monday.adding(days: 14).start(in: timeZone))
    }

    func instant(day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = monday.adding(days: day)
        let parts = DateComponents(year: date.year, month: date.month, day: date.day, hour: hour, minute: minute)
        return calendar.date(from: parts) ?? date.start(in: timeZone)
    }
}

/// Small invented files for the demo's event folders.
enum DemoFiles {
    /// A one-page PDF that shows `text`, built by hand (no PDF library is needed for one line of text).
    static func pdf(text: String) -> Data {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
        let ascii = String(escaped.unicodeScalars.map { $0.isASCII ? Character($0) : "-" })
        let stream = "BT /F1 18 Tf 72 720 Td (\(ascii)) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
                + "/Resources << /Font << /F1 5 0 R >> >> >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]
        var output = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(output.utf8.count)
            output += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = output.utf8.count
        output += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            output += String(format: "%010d 00000 n \n", offset)
        }
        output += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(output.utf8)
    }
}
