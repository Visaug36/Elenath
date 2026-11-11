import Foundation

/// Names for items that would clash with one already there: "Notes.md", then "Notes 2.md", "Notes 3.md"…,
/// as Finder does it. The number goes before the extension.
public enum UniqueName {
    /// The longest name a volume accepts, in UTF-8 bytes.
    static let maximumNameBytes = 255

    /// `name` if `isTaken` says it is free, otherwise the first numbered variant that is.
    ///
    /// A name that already ends in a Finder number continues from it: "Notes 2.md" becomes "Notes 3.md",
    /// not "Notes 2 2.md". Names are offered to `isTaken` exactly as they would be created, so the caller
    /// decides how names compare (see `NameSanitizer.key`).
    public static func available(_ name: String, isTaken: (String) -> Bool) -> String {
        if !isTaken(name) {
            return name
        }
        let parts = NumberedName(name)
        let first = (parts.number ?? 1) + 1
        for number in first..<(first + 10_000) {
            let candidate = parts.name(withSuffix: String(number))
            if !isTaken(candidate) {
                return candidate
            }
        }
        return parts.name(withSuffix: UUID().uuidString)
    }
}

/// A name taken apart into its base, the number Finder may have added, and its extension.
struct NumberedName {
    /// The name without its extension and without its number.
    var base: String
    /// The Finder number already at the end of the name, if any.
    var number: Int?
    /// The extension without its dot, if any.
    var pathExtension: String?

    init(_ name: String) {
        var stem = name
        var pathExtension: String?
        // An extension follows the last dot, unless that dot starts the name (".gitignore"), or the part
        // after it has no letters ("Chapter 1.2") or has spaces in it ("Dr. Smith").
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            let suffix = name[name.index(after: dot)...]
            let before = name[..<dot]
            let isExtension = suffix.contains(where: \.isLetter) && !suffix.contains(where: \.isWhitespace)
            if isExtension && before.contains(where: { $0 != "." }) {
                stem = String(before)
                pathExtension = String(suffix)
            }
        }
        var number: Int?
        if let space = stem.lastIndex(of: " "), space != stem.startIndex {
            if let value = Self.finderNumber(stem[stem.index(after: space)...]) {
                number = value
                stem = String(stem[..<space])
            }
        }
        self.base = stem
        self.number = number
        self.pathExtension = pathExtension
    }

    /// "base suffix.extension", with the base shortened if the name would be too long for a volume.
    func name(withSuffix suffix: String) -> String {
        let ending = pathExtension.map { " \(suffix).\($0)" } ?? " \(suffix)"
        var shortened = base
        while !shortened.isEmpty && (shortened + ending).utf8.count > UniqueName.maximumNameBytes {
            shortened.removeLast()
        }
        return shortened + ending
    }

    /// The value of a number like the ones Finder adds: 2…999, plain digits, no leading zero. A year
    /// ("Report 2026") or "Track 01" isn't one.
    private static func finderNumber(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.count <= 3, text.first != "0" else { return nil }
        guard text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(text) else { return nil }
        return value >= 2 ? value : nil
    }
}
