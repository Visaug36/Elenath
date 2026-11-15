import Foundation

/// A space: a top-level folder of the library with its settings from space.json.
public struct Space: Hashable, Sendable, Identifiable {
    public var id: SpaceID
    /// The folder's name, which is the space's name.
    public var name: String
    public var color: SpaceColor
    /// An SF Symbol name.
    public var symbol: String
    /// A sealed space's content is used only while working inside it (see `Reach`).
    public var isSealed: Bool
    /// What the space is for, in a sentence. Helps file things here.
    public var description: String
    /// Words that mean this space, for filing and for Quick Capture ("uni: …"). Lowercase, no duplicates.
    public var keywords: [String]
    /// Its space.json was written by a newer Elenath, so nothing in the space is changed.
    public var isReadOnly: Bool

    public init(
        id: SpaceID = SpaceID(),
        name: String,
        color: SpaceColor = .fallback,
        symbol: String = Space.fallbackSymbol,
        isSealed: Bool = false,
        description: String = "",
        keywords: [String] = [],
        isReadOnly: Bool = false
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.symbol = symbol
        self.isSealed = isSealed
        self.description = description
        self.keywords = Space.normalizedKeywords(keywords)
        self.isReadOnly = isReadOnly
    }

    /// The symbol a space gets when nothing else is chosen.
    public static let fallbackSymbol = "folder"

    /// Keywords as they are stored: trimmed, lowercase, without empty ones or duplicates, in their order.
    public static func normalizedKeywords(_ keywords: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for keyword in keywords {
            let cleaned = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !cleaned.isEmpty, seen.insert(cleaned).inserted {
                result.append(cleaned)
            }
        }
        return result
    }
}
