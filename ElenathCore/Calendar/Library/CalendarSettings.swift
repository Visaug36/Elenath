import Foundation

/// Where a subject's notes go and where its events' files belong: a space, and a folder in it
/// (docs/FORMAT.md, "settings.calendar"). An event's sealing follows its subject's home.
public struct SubjectHome: Hashable, Sendable {
    public var space: SpaceID
    /// A folder in the space; the root for the top of the space.
    public var folder: ItemPath

    public init(space: SpaceID, folder: ItemPath = .root) {
        self.space = space
        self.folder = folder
    }
}

/// What library.json says about one subject's home.
public enum SubjectHomeEntry: Hashable, Sendable {
    /// No entry: the subject has no home. Its events are never sealed and their notes go to the Inbox.
    case none
    case home(SubjectHome)
    /// An entry that can't be read. It may have named a sealed space, so the subject's events count as
    /// sealed (their content is read from nowhere) until the user gives the subject a home again.
    case unreadable
}

/// Elenath's own settings for the calendar, kept in library.json under `settings["calendar"]`, so the
/// calendar's events.json stays exactly Ithil's. Keys this version doesn't know are kept as they were.
///
/// ```json
/// "calendar" : {
///   "id" : "…",
///   "homes" : { "8E2F…" : { "folder" : "Physics", "space" : "…" } }
/// }
/// ```
public struct CalendarSettings: Hashable, Sendable {
    /// The key in library.json's `settings`.
    public static let settingsKey = "calendar"

    /// The id of the library's calendar (events.json's `id`), so its safety copy can be found when the
    /// calendar's own files are gone. Nil until the calendar was first opened.
    public var calendarID: UUID?

    /// Each subject's home that could be read, by the subject's id.
    public private(set) var homes: [UUID: SubjectHome]
    /// Subjects whose entry is there but can't be read.
    public private(set) var unreadableHomes: Set<UUID>

    /// Entries of `homes` that can't be read, kept as they were so a newer Elenath's don't get lost.
    private var keptHomeEntries: [String: JSONValue]
    /// Other keys of `settings["calendar"]`, kept as they were.
    private var keptKeys: [String: JSONValue]

    public init(calendarID: UUID? = nil, homes: [UUID: SubjectHome] = [:]) {
        self.calendarID = calendarID
        self.homes = homes
        self.unreadableHomes = []
        self.keptHomeEntries = [:]
        self.keptKeys = [:]
    }

    /// Reads `settings["calendar"]` from library.json's settings. Anything missing reads as no setting.
    public init(from settings: [String: JSONValue]) {
        self.init()
        guard case .object(var object) = settings[Self.settingsKey] else { return }
        if case .string(let text) = object.removeValue(forKey: Keys.id) {
            calendarID = UUID(uuidString: text)
        }
        if case .object(let entries) = object.removeValue(forKey: Keys.homes) {
            for (key, value) in entries {
                guard let subject = UUID(uuidString: key) else {
                    keptHomeEntries[key] = value  // Not a subject id: kept, never used.
                    continue
                }
                if let home = Self.home(from: value) {
                    homes[subject] = home
                } else {
                    unreadableHomes.insert(subject)
                    keptHomeEntries[key] = value
                }
            }
        }
        keptKeys = object
    }

    /// What library.json says about a subject's home. An event without a subject has none.
    public func entry(forSubject subject: UUID?) -> SubjectHomeEntry {
        guard let subject else { return .none }
        if unreadableHomes.contains(subject) {
            return .unreadable
        }
        if let home = homes[subject] {
            return .home(home)
        }
        return .none
    }

    /// Gives a subject a home, or none. Replaces an entry that couldn't be read.
    public mutating func setHome(_ home: SubjectHome?, forSubject subject: UUID) {
        homes[subject] = home
        unreadableHomes.remove(subject)
        for key in keptHomeEntries.keys where UUID(uuidString: key) == subject {
            keptHomeEntries[key] = nil
        }
    }

    /// Writes these settings into library.json's settings, replacing `settings["calendar"]`.
    public func written(into settings: inout [String: JSONValue]) {
        var object = keptKeys
        if let calendarID {
            object[Keys.id] = .string(calendarID.uuidString)
        }
        var entries = keptHomeEntries
        for (subject, home) in homes {
            entries[subject.uuidString] = .object([
                Keys.space: .string(home.space.rawValue.uuidString),
                Keys.folder: .string(home.folder.description),
            ])
        }
        if !entries.isEmpty {
            object[Keys.homes] = .object(entries)
        }
        settings[Self.settingsKey] = object.isEmpty ? nil : .object(object)
    }

    // MARK: - Private

    private enum Keys {
        static let id = "id"
        static let homes = "homes"
        static let space = "space"
        static let folder = "folder"
    }

    /// A home from its JSON. A folder that isn't a folder of notes inside the space (not a valid path, or
    /// one through a hidden, attachments or board folder) reads as the top of the space: the space is what
    /// sealing follows, and it is still known.
    private static func home(from value: JSONValue) -> SubjectHome? {
        guard case .object(let fields) = value, case .string(let spaceText) = fields[Keys.space],
            let space = UUID(uuidString: spaceText)
        else { return nil }
        var folder = ItemPath.root
        if case .string(let path) = fields[Keys.folder], let parsed = ItemPath(path),
            !parsed.components.contains(where: NameSanitizer.isReservedInSpace)
        {
            folder = parsed
        }
        return SubjectHome(space: SpaceID(space), folder: folder)
    }
}
