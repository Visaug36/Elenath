import Foundation

/// One change to a note's body: the text at `range` becomes `replacement`.
public struct LinkEdit: Hashable, Sendable {
    /// The note to change, by where it is after the move.
    public var note: NoteRef
    /// In UTF-16 units of that note's body.
    public var range: NSRange
    public var replacement: String

    public init(note: NoteRef, range: NSRange, replacement: String) {
        self.note = note
        self.range = range
        self.replacement = replacement
    }
}

/// Keeps links pointing at the same notes when a note is renamed or moved (docs/FORMAT.md, "Links").
public enum LinkRewriter {
    /// The edits that keep every link in `notes` pointing at the note it pointed at before `old` became
    /// `new`.
    ///
    /// A link is rewritten only if it resolved before the move and would resolve to something else, or
    /// to nothing, after it. Its shown text and heading are kept. Links that were ambiguous or unresolved
    /// are left alone, and so is everything inside code.
    ///
    /// - Parameters:
    ///   - notes: The notes that link to `old`, and `old` itself (its own links may need a longer form
    ///     in its new place), each with its body as it is now. A note is named by where it is before
    ///     the move.
    ///   - before: A resolver over the notes as they are now.
    ///   - after: A resolver over the notes as they will be: see `TitleCatalog.replacing(_:with:)`.
    public static func edits(
        forMoving old: NoteRef, to new: NoteRef, notes: [(note: NoteRef, body: String)], before: LinkResolver,
        after: LinkResolver
    ) -> [LinkEdit] {
        edits(forMoving: [old: new], notes: notes, before: before, after: after)
    }

    /// The same for several notes that move at once, as when a folder is renamed: `moves` maps where
    /// each note was to where it is.
    public static func edits(
        forMoving moves: [NoteRef: NoteRef], notes: [(note: NoteRef, body: String)], before: LinkResolver,
        after: LinkResolver
    ) -> [LinkEdit] {
        var edits: [LinkEdit] = []
        for (note, body) in notes {
            let noteAfter = moves[note] ?? note
            for span in MarkdownScanner.scan(body).links {
                switch span.target {
                case .wiki(let link):
                    guard !link.target.isEmpty, case .resolved(let target) = before.resolve(link, from: note) else {
                        continue
                    }
                    let targetAfter = moves[target] ?? target
                    if after.resolve(link, from: noteAfter) == .resolved(targetAfter) {
                        continue
                    }
                    var rewritten = link
                    rewritten.target = after.shortestTarget(for: targetAfter, from: noteAfter)
                    guard after.resolve(rewritten, from: noteAfter) == .resolved(targetAfter) else { continue }
                    edits.append(LinkEdit(note: noteAfter, range: span.range, replacement: rewritten.written))
                case .markdown(let destination, _):
                    guard let range = span.destinationRange,
                        case .resolved(let target) = before.resolve(markdownDestination: destination, from: note)
                    else { continue }
                    let targetAfter = moves[target] ?? target
                    if after.resolve(markdownDestination: destination, from: noteAfter) == .resolved(targetAfter) {
                        continue
                    }
                    guard var replacement = after.markdownDestination(for: targetAfter, from: noteAfter) else {
                        continue
                    }
                    if let hash = destination.firstIndex(of: "#") {
                        replacement += destination[hash...]
                    }
                    edits.append(LinkEdit(note: noteAfter, range: range, replacement: replacement))
                case .url:
                    continue
                }
            }
        }
        return edits
    }

    /// `body` with the edits made to it. The edits must all be for the note this is the body of.
    public static func apply(_ edits: [LinkEdit], to body: String) -> String {
        let text = NSMutableString(string: body)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location })
        where NSMaxRange(edit.range) <= text.length {
            text.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return text as String
    }
}
