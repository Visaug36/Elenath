import Foundation

/// The identity of a library: the `id` in its library.json. It never changes.
public struct LibraryID: Hashable, Sendable, Codable {
    public var rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The identity of a space: the `id` in its space.json. It survives renaming the folder.
public struct SpaceID: Hashable, Sendable, Codable {
    public var rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The identity of a note: the `id` in its front matter. With it, links follow the note when its file is
/// renamed or moved outside Elenath.
public struct NoteID: Hashable, Sendable, Codable {
    public var rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    /// Reads an id as written in front matter, in either letter case. Nil for anything else.
    public init?(string: String) {
        guard let value = UUID(uuidString: string.trimmingCharacters(in: .whitespaces)) else { return nil }
        rawValue = value
    }

    /// The id as Elenath writes it: uppercase, with hyphens.
    public var string: String {
        rawValue.uuidString
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
