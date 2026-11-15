import Foundation

/// A small JSON file Elenath owns: library.json or space.json. Both are saved by `DocumentStore`, with a
/// schema version, backups, a safety copy and recovery (docs/FORMAT.md, "Saving, backups and recovery").
public protocol VersionedDocument: Codable, Hashable, Sendable {
    /// "library.json"
    static var fileName: String { get }
    /// The start of a backup's name: "library-" gives "library-20261110-143000.json".
    static var backupPrefix: String { get }
    /// The start of the name a damaged file is set aside under: "library.corrupt-".
    static var corruptPrefix: String { get }
    /// The schema this version of Elenath writes.
    static var currentSchemaVersion: Int { get }
    /// The migrations applied to files written with an older schema. Step `n` turns version `n` into
    /// `n + 1`.
    static var migrator: SchemaMigrator { get }
    /// The document's identity, which names its safety copy.
    var documentID: UUID { get }
}

/// library.json: the library's identity, the order of its spaces, and the settings that travel with it.
public struct LibraryDocument: VersionedDocument {
    public var id: LibraryID
    /// The spaces in sidebar order, by their space.json ids. An id without a folder is kept.
    public var spaces: [SpaceID]
    /// Settings that belong to the library rather than to the Mac. Keys Elenath doesn't know are kept.
    public var settings: [String: JSONValue]

    public init(id: LibraryID = LibraryID(), spaces: [SpaceID] = [], settings: [String: JSONValue] = [:]) {
        self.id = id
        self.spaces = spaces
        self.settings = settings
    }

    public static let fileName = "library.json"
    public static let backupPrefix = "library-"
    public static let corruptPrefix = "library.corrupt-"
    public static let currentSchemaVersion = 1
    public static let migrator = SchemaMigrator(currentVersion: currentSchemaVersion, steps: [:])

    public var documentID: UUID { id.rawValue }

    private enum CodingKeys: String, CodingKey {
        case id, spaces, settings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(LibraryID.self, forKey: .id)
        spaces = try container.decodeIfPresent([SpaceID].self, forKey: .spaces) ?? []
        settings = try container.decodeIfPresent([String: JSONValue].self, forKey: .settings) ?? [:]
    }
}

/// space.json: a space's identity and settings. Its name is its folder's name, not stored here.
public struct SpaceDocument: VersionedDocument {
    public var id: SpaceID
    public var color: SpaceColor
    public var symbol: String
    public var sealed: Bool
    public var description: String
    public var keywords: [String]

    public init(
        id: SpaceID = SpaceID(),
        color: SpaceColor = .fallback,
        symbol: String = Space.fallbackSymbol,
        sealed: Bool = false,
        description: String = "",
        keywords: [String] = []
    ) {
        self.id = id
        self.color = color
        self.symbol = symbol
        self.sealed = sealed
        self.description = description
        self.keywords = Space.normalizedKeywords(keywords)
    }

    public static let fileName = "space.json"
    public static let backupPrefix = "space-"
    public static let corruptPrefix = "space.corrupt-"
    public static let currentSchemaVersion = 1
    public static let migrator = SchemaMigrator(currentVersion: currentSchemaVersion, steps: [:])

    public var documentID: UUID { id.rawValue }

    private enum CodingKeys: String, CodingKey {
        case id, color, symbol, sealed, description, keywords
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SpaceID.self, forKey: .id)
        // A color or symbol this version can't read falls back rather than making the space unreadable.
        color = (try? container.decodeIfPresent(SpaceColor.self, forKey: .color)) ?? .fallback
        symbol = (try? container.decodeIfPresent(String.self, forKey: .symbol)) ?? Space.fallbackSymbol
        // `sealed` is the one setting that must not be guessed: a value that isn't a boolean is an error,
        // so the file counts as damaged and the space stays sealed until it is restored or decided.
        sealed = try container.decodeIfPresent(Bool.self, forKey: .sealed) ?? false
        description = (try? container.decodeIfPresent(String.self, forKey: .description)) ?? ""
        keywords = Space.normalizedKeywords((try? container.decodeIfPresent([String].self, forKey: .keywords)) ?? [])
    }
}
