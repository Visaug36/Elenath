import Foundation

/// A wiki link as it is written in a note: `[[Target#Heading|shown text]]`, or `![[file.png|300]]` for an
/// embed (docs/FORMAT.md, "Links").
public struct WikiLink: Hashable, Sendable {
    /// What the link points at: "Title", "Folder/Title" or "Space/Folder/Title". Empty for a link to a
    /// heading of the note it is in (`[[#Heading]]`).
    public var target: String
    /// The part after "#": a heading, or "^block" for a block.
    public var heading: String?
    /// The part after "|": the text shown instead of the target, or an embed's width.
    public var shownText: String?
    /// Whether it is written with "!" in front.
    public var isEmbed: Bool
    /// Whether the "|" is written as "\|", as it has to be inside a table.
    public var escapesPipe: Bool

    public init(
        target: String, heading: String? = nil, shownText: String? = nil, isEmbed: Bool = false,
        escapesPipe: Bool = false
    ) {
        self.target = target
        self.heading = heading
        self.shownText = shownText
        self.isEmbed = isEmbed
        self.escapesPipe = escapesPipe
    }

    /// Reads the text between "[[" and "]]". Nil when it names nothing.
    public init?(inner: String, isEmbed: Bool) {
        var left = inner
        var shown: String?
        var escaped = false
        if let pipe = inner.firstIndex(of: "|") {
            shown = String(inner[inner.index(after: pipe)...])
            left = String(inner[..<pipe])
            if left.hasSuffix("\\") {
                left.removeLast()
                escaped = true
            }
        }
        var heading: String?
        if let hash = left.firstIndex(of: "#") {
            heading = String(left[left.index(after: hash)...])
            left = String(left[..<hash])
        }
        let target = left.trimmingCharacters(in: .whitespaces)
        if target.isEmpty && (heading ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            return nil
        }
        self.init(target: target, heading: heading, shownText: shown, isEmbed: isEmbed, escapesPipe: escaped)
    }

    /// The link as it is written, brackets included.
    public var written: String {
        var text = isEmbed ? "![[" : "[["
        text += target
        if let heading {
            text += "#" + heading
        }
        if let shownText {
            text += (escapesPipe ? "\\|" : "|") + shownText
        }
        return text + "]]"
    }

    /// What a reader sees: the shown text, or the target (with its heading).
    public var displayText: String {
        if let shownText, !shownText.isEmpty {
            return shownText
        }
        guard let heading, !heading.isEmpty else { return target }
        return target.isEmpty ? heading : "\(target) › \(heading)"
    }

    /// The target as path parts, without a ".md" at the end: "Uni/Physics/Lecture 7.md" gives
    /// ["Uni", "Physics", "Lecture 7"]. Empty parts are dropped.
    public var targetComponents: [String] {
        var parts = target.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let last = parts.last {
            parts[parts.count - 1] = ItemPath.title(ofFileNamed: last)
        }
        return parts
    }
}
