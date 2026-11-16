import Foundation

/// Everything stored in a calendar's `.ithil/events.json`: its subjects and events. Ithil's `Library`,
/// ported as it is; only the name changed, since Elenath's library is the whole folder
/// (docs/ARCHITECTURE.md, "Calendar").
///
/// The keys and the schema version are Ithil 1.0.0's, so the `Calendar` folder stays a valid Ithil folder.
public struct CalendarDocument: VersionedDocument {
    /// Identifies this calendar, e.g. to name its safety copy.
    public var id: UUID
    public var subjects: [Subject]
    public var events: [Event]

    public init(id: UUID = UUID(), subjects: [Subject] = [], events: [Event] = []) {
        self.id = id
        self.subjects = subjects
        self.events = events
    }

    public static let fileName = "events.json"
    public static let backupPrefix = "events-"
    public static let corruptPrefix = "events.corrupt-"
    /// Ithil 1.0.0's schema. A calendar written by a newer Ithil opens read-only.
    public static let currentSchemaVersion = 1
    public static let migrator = SchemaMigrator(currentVersion: currentSchemaVersion, steps: [:])

    public var documentID: UUID { id }

    private enum CodingKeys: String, CodingKey {
        case id, subjects, events
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            subjects: try container.decodeIfPresent([Subject].self, forKey: .subjects) ?? [],
            events: try container.decodeIfPresent([Event].self, forKey: .events) ?? [])
    }

    public func subject(withID id: UUID?) -> Subject? {
        guard let id else { return nil }
        return subjects.first { $0.id == id }
    }

    public func event(withID id: UUID) -> Event? {
        events.first { $0.id == id }
    }
}
