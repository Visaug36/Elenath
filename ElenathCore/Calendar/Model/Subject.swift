import Foundation

/// A course or area of life the user files events under, such as "Physics" or "Personal".
public struct Subject: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var color: SubjectColor
    /// Extra words Quick Add recognizes besides the name, e.g. "phys" or "mechanics".
    public var keywords: [String]

    public init(id: UUID = UUID(), name: String, color: SubjectColor, keywords: [String] = []) {
        self.id = id
        self.name = name
        self.color = color
        self.keywords = keywords
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, color, keywords
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            color: try container.decodeIfPresent(SubjectColor.self, forKey: .color) ?? .palette(.clay),
            keywords: try container.decodeIfPresent([String].self, forKey: .keywords) ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(color, forKey: .color)
        if !keywords.isEmpty { try container.encode(keywords, forKey: .keywords) }
    }
}

/// A subject's color: one of the design's palette slots (which have Night and Dawn variants in the
/// asset catalog) or a custom sRGB color.
public enum SubjectColor: Hashable, Sendable {
    case palette(PaletteColor)
    case custom(red: Double, green: Double, blue: Double)

    /// `#RRGGBB` for custom colors, nil for palette colors.
    public var hexString: String? {
        guard case .custom(let red, let green, let blue) = self else { return nil }
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// Parses `#RRGGBB`.
    public init?(hexString: String) {
        var hex = Substring(hexString)
        if hex.hasPrefix("#") { hex = hex.dropFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self = .custom(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}

extension SubjectColor: Codable {
    /// Stored as the palette name ("clay") or as `#RRGGBB`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        if let palette = PaletteColor(rawValue: string) {
            self = .palette(palette)
        } else if let custom = SubjectColor(hexString: string) {
            self = custom
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown color \"\(string)\"")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .palette(let palette): try container.encode(palette.rawValue)
        case .custom: try container.encode(hexString ?? "#000000")
        }
    }
}

// `PaletteColor` (clay, teal, iris, fern, rose) is Elenath's, in SpaceColor.swift: subjects and spaces share
// the palette, and its raw values are the ones Ithil writes to events.json.
