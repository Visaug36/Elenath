import ElenathCore
import Foundation

/// Fixed dates and a sample calendar for the calendar's storage tests (Ithil's `StorageFixtures`).
enum CalendarFixtures {
    /// Tuesday 2026-10-06 11:50:00 UTC (13:50 in Amsterdam), the design's mock "now".
    static let start = instant(year: 2026, month: 10, day: 6, hour: 11, minute: 50, zone: "UTC")

    static func timeZone(_ identifier: String) -> TimeZone {
        TimeZone(identifier: identifier)!
    }

    /// A wall-clock time in an explicit time zone, on the Gregorian calendar.
    static func instant(year: Int, month: Int, day: Int, hour: Int, minute: Int, zone: String) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone(zone)
        let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        return calendar.date(from: parts)!
    }

    static let lectureStart = instant(year: 2026, month: 10, day: 6, hour: 14, minute: 0, zone: "Europe/Amsterdam")
    static let lectureEnd = instant(year: 2026, month: 10, day: 6, hour: 15, minute: 30, zone: "Europe/Amsterdam")

    /// Two subjects (a palette and a custom color) and three events covering every stored field:
    /// a weekly timed lecture with exclusions, a multi-day all-day trip and a detached occurrence in
    /// another time zone. All timestamps are whole seconds.
    static func sampleCalendar() -> CalendarDocument {
        let physics = Subject(name: "Physics", color: .palette(.clay), keywords: ["phys", "mechanics"])
        let personal = Subject(name: "Personal", color: SubjectColor(hexString: "#3366CC")!)
        let created = instant(year: 2026, month: 9, day: 1, hour: 8, minute: 0, zone: "UTC")
        let modified = instant(year: 2026, month: 9, day: 2, hour: 9, minute: 30, zone: "UTC")

        let lastLecture = CalendarDate(year: 2026, month: 12, day: 18)
        let skipped: Set<CalendarDate> = [
            CalendarDate(year: 2026, month: 10, day: 20),
            CalendarDate(year: 2026, month: 11, day: 3),
        ]
        let lecture = Event(
            title: "Physics Lecture",
            timing: .timed(start: lectureStart, end: lectureEnd, timeZone: timeZone("Europe/Amsterdam")),
            subjectID: physics.id,
            location: "Room B/204",
            notes: "Slides: https://example.com/physics/week-6",
            alert: .tenMinutes,
            recurrence: RecurrenceRule(frequency: .weekly, until: lastLecture),
            excludedDates: skipped,
            createdAt: created,
            modifiedAt: modified)

        let tripStart = CalendarDate(year: 2026, month: 10, day: 9)
        let tripEnd = CalendarDate(year: 2026, month: 10, day: 11)
        let trip = Event(
            title: "Field Trip",
            timing: .allDay(start: tripStart, end: tripEnd),
            subjectID: personal.id,
            alert: .oneDay,
            createdAt: created)

        let movedStart = instant(year: 2026, month: 10, day: 21, hour: 9, minute: 0, zone: "Asia/Tokyo")
        let movedEnd = instant(year: 2026, month: 10, day: 21, hour: 10, minute: 30, zone: "Asia/Tokyo")
        let replaced = SeriesOccurrence(seriesID: lecture.id, date: CalendarDate(year: 2026, month: 10, day: 20))
        let moved = Event(
            title: "Physics Lecture",
            timing: .timed(start: movedStart, end: movedEnd, timeZone: timeZone("Asia/Tokyo")),
            subjectID: physics.id,
            detachedFrom: replaced,
            createdAt: created,
            modifiedAt: modified)

        return CalendarDocument(subjects: [physics, personal], events: [lecture, trip, moved])
    }

    /// The first occurrence of an event, as the calendar shows it.
    static func firstOccurrence(of event: Event) -> Occurrence {
        switch event.timing {
        case .timed(let start, let end, _):
            return Occurrence(event: event, date: event.timing.startDate, start: start, end: end)
        case .allDay(let start, let end):
            let zone = timeZone("UTC")
            return Occurrence(event: event, date: start, start: start.start(in: zone), end: end.end(in: zone))
        }
    }

    /// A marker file's contents, as Ithil 1.0.0 writes it.
    static func markerJSON(for occurrence: Occurrence) -> String {
        """
        {
          "date" : "\(occurrence.date.isoString)",
          "eventID" : "\(occurrence.event.id.uuidString)",
          "version" : 1
        }
        """
    }
}

/// Whether `error` is `DocumentStoreError.unreadable`, whatever its message.
func calendarErrorIsUnreadable(_ error: (any Error)?) -> Bool {
    guard let storeError = error as? DocumentStoreError, case .unreadable = storeError else { return false }
    return true
}

extension LibraryFixture {
    /// The library's calendar store, as the app makes it.
    func calendarStore(knownCalendarID: UUID? = nil, libraryID: LibraryID = LibraryID()) -> CalendarStore {
        CalendarStore(
            libraryRoot: root, libraryID: libraryID, safetyDirectory: safety, knownCalendarID: knownCalendarID,
            fileSystem: fileSystem, timeSource: clock, backupInterval: 60 * 60, maxBackups: 10)
    }
}

/// An Ithil 1.0.0 folder: `.ithil/events.json` exactly as Ithil writes it, and event folders with their
/// markers and files.
struct IthilFolderFixture {
    let url: URL

    /// Makes `<parent>/Ithil` with the calendar's events.json.
    init(in parent: URL, calendar: CalendarDocument, savedAt: Date = CalendarFixtures.start) throws {
        url = parent.appending(component: "Ithil", directoryHint: .isDirectory)
        try write(DocumentCodec.encode(calendar, savedAt: savedAt), to: ".ithil/events.json")
    }

    /// Makes the occurrence's folder (`<yyyy-MM-dd>/<HH.mm Title>`) with its marker and `files`, by path
    /// inside the folder. Returns the folder's path inside the Ithil folder.
    @discardableResult
    func addFolder(for occurrence: Occurrence, files: [String: String]) throws -> String {
        let folder = FolderNaming.relativePath(for: occurrence)
        try write(Data(CalendarFixtures.markerJSON(for: occurrence).utf8), to: "\(folder)/.ithil-event")
        for (path, text) in files {
            try write(Data(text.utf8), to: "\(folder)/\(path)")
        }
        return folder
    }

    func write(_ data: Data, to path: String) throws {
        let file = url.appending(path: path, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try data.write(to: file)
    }

    /// Every item in the folder, hidden ones included, by path inside it: the bytes of each file, and
    /// nil for each folder. Equal before and after means the folder was left untouched.
    func snapshot() -> [String: Data?] {
        var result: [String: Data?] = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard
            let walker = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: keys, options: [], errorHandler: nil)
        else { return result }
        let base = url.resolvingSymlinksInPath().path + "/"
        for case let item as URL in walker {
            let path = String(item.resolvingSymlinksInPath().path.dropFirst(base.count))
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true || values?.isSymbolicLink == true {
                result[path.isEmpty ? item.lastPathComponent : path] = .some(nil)
            } else {
                result[path] = try? Data(contentsOf: item)
            }
        }
        return result
    }
}
