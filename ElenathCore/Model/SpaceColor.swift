import Foundation

/// The space palette. Each case matches a `Space…` color set in the app's asset catalog, with Night and
/// Dawn variants.
public enum PaletteColor: String, CaseIterable, Codable, Sendable {
    case clay
    case teal
    case iris
    case fern
    case rose
}

/// A space's color: one of the palette's slots or a custom color.
///
/// Stored in space.json as the palette name ("teal") or as `#RRGGBB`.
public enum SpaceColor: Hashable, Sendable, Codable {
    case palette(PaletteColor)
    case custom(red: UInt8, green: UInt8, blue: UInt8)

    /// The color a space gets when nothing else is chosen.
    public static let fallback = SpaceColor.palette(.teal)

    /// Reads `#RRGGBB` (the `#` is optional, either letter case). Nil for anything else.
    public init?(hexString: String) {
        var hex = Substring(hexString)
        if hex.hasPrefix("#") {
            hex = hex.dropFirst()
        }
        guard hex.utf8.count == 6, hex.allSatisfy(\.isHexDigit), let value = UInt32(hex, radix: 16) else {
            return nil
        }
        self = .custom(
            red: UInt8((value >> 16) & 0xFF), green: UInt8((value >> 8) & 0xFF), blue: UInt8(value & 0xFF))
    }

    /// `#RRGGBB` for a custom color, nil for a palette color.
    public var hexString: String? {
        guard case .custom(let red, let green, let blue) = self else { return nil }
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        if let palette = PaletteColor(rawValue: string) {
            self = .palette(palette)
        } else if let custom = SpaceColor(hexString: string) {
            self = custom
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Not a palette name or #RRGGBB: \(string)")
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
