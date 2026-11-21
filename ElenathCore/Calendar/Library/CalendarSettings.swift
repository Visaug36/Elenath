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
/// **Damage fails closed.** An entry that can't be read, or two entries for one subject, make that
/// subject's home unreadable. When `settings["calendar"]` or its `homes` isn't an object at all, every
/// subject's home is unreadable (`isDamaged`) and the value is written back as it was found, until the app
/// settles it (`settleDamage(subjects:)`): then each subject of the calendar gets an entry that can't be read,
/// until the user gives it a home, and what was found is kept under `foundUnreadable`.
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
    /// What was found where an object was expected, until the app settles it.
    private var damage: Damage?

    private enum Damage: Hashable, Sendable {
        /// `settings["calendar"]` itself.
        case calendar(JSONValue)
        /// Its `homes`.
        case homes(JSONValue)

        var found: JSONValue {
            switch self {
            case .calendar(let value), .homes(let value): value
            }
        }
    }

    public init(calendarID: UUID? = nil, homes: [UUID: SubjectHome] = [:]) {
        self.calendarID = calendarID
        self.homes = homes
        self.unreadableHomes = []
        self.keptHomeEntries = [:]
        self.keptKeys = [:]
        self.damage = nil
    }

    /// Reads `settings["calendar"]` from library.json's settings. Anything missing reads as no setting.
    public init(from settings: [String: JSONValue]) {
        self.init()
        guard let value = settings[Self.settingsKey] else { return }
        guard case .object(var object) = value else {
            damage = .calendar(value)
            return
        }
        if case .string(let text) = object.removeValue(forKey: Keys.id) {
            calendarID = UUID(uuidString: text)
        }
        if let value = object.removeValue(forKey: Keys.homes) {
            if case .object(let entries) = value {
                readHomes(entries)
            } else {
                damage = .homes(value)
            }
        }
        keptKeys = object
    }

    /// Whether `settings["calendar"]` or its `homes` wasn't an object, and that hasn't been settled yet:
    /// every subject's home reads as unreadable meanwhile.
    public var isDamaged: Bool {
        damage != nil
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
        // Damaged settings may have named a sealed space for any subject.
        return damage == nil ? .none : .unreadable
    }

    /// Settles damaged settings (`isDamaged`) for the calendar's subjects: each that has no home gets an
    /// entry that can't be read, so its events stay sealed until the user gives it a home, and what was
    /// found is kept under `foundUnreadable`. Subjects made later have no home, as usual. Returns whether
    /// anything changed.
    public mutating func settleDamage(subjects: [UUID]) -> Bool {
        guard let damage else { return false }
        for subject in subjects where homes[subject] == nil && !unreadableHomes.contains(subject) {
            unreadableHomes.insert(subject)
            keptHomeEntries[subject.uuidString] = .object([:])  // An entry that can't be read.
        }
        keptKeys[Keys.foundUnreadable] = damage.found
        self.damage = nil
        return true
    }

    /// Gives a subject a home, or none. Replaces an entry that couldn't be read.
    public mutating func setHome(_ home: SubjectHome?, forSubject subject: UUID) {
        homes[subject] = home
        unreadableHomes.remove(subject)
        for key in keptHomeEntries.keys where UUID(uuidString: key) == subject {
            keptHomeEntries[key] = nil
        }
    }

    /// Writes these settings into library.json's settings, replacing `settings["calendar"]`. Damage that
    /// hasn't been settled is written back as it was found.
    public func written(into settings: inout [String: JSONValue]) {
        if case .calendar(let found) = damage {
            settings[Self.settingsKey] = found
            return
        }
        var object = keptKeys
        if let calendarID {
            object[Keys.id] = .string(calendarID.uuidString)
        }
        if case .homes(let found) = damage {
            object[Keys.homes] = found
        } else {
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
        }
        settings[Self.settingsKey] = object.isEmpty ? nil : .object(object)
    }

    // MARK: - Private

    private enum Keys {
        static let id = "id"
        static let homes = "homes"
        static let space = "space"
        static let folder = "folder"
        static let foundUnreadable = "foundUnreadable"
    }

    /// Reads `homes`. A subject with two entries (keys that differ only in letter case) is unreadable, like
    /// a damaged entry: which one counts would otherwise depend on the order they're read in.
    private mutating func readHomes(_ entries: [String: JSONValue]) {
        var bySubject: [UUID: [(key: String, value: JSONValue)]] = [:]
        for (key, value) in entries {
            guard let subject = UUID(uuidString: key) else {
                keptHomeEntries[key] = value  // Not a subject id: kept, never used.
                continue
            }
            bySubject[subject, default: []].append((key, value))
        }
        for (subject, found) in bySubject {
            if found.count == 1, let home = Self.home(from: found[0].value) {
                homes[subject] = home
            } else {
                unreadableHomes.insert(subject)
                for entry in found {
                    keptHomeEntries[entry.key] = entry.value
                }
            }
        }
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
