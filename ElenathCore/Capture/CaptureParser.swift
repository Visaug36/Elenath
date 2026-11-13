import Foundation

/// Where a capture goes.
public enum CaptureDestination: Hashable, Sendable {
    case inbox
    /// Straight into a space, because the text started with its name or one of its keywords.
    case space(SpaceID, matched: String)
}

/// A capture taken apart: where it goes, what the note is called and what is in it.
public struct CaptureDraft: Hashable, Sendable {
    public var destination: CaptureDestination
    public var title: String
    /// The note's text. Empty when the capture is one line that became the title unchanged.
    public var body: String

    public init(destination: CaptureDestination, title: String, body: String) {
        self.destination = destination
        self.title = title
        self.body = body
    }
}

/// Reads what was typed into Quick Capture (docs/ARCHITECTURE.md, "Capture").
///
/// Text that starts with a space's name or one of its keywords, a colon and a space ("uni: ask about the
/// exam") goes straight to that space, sealed ones included: it is the user's own choice, not retrieval.
/// The longest name or keyword that fits wins. Everything else goes to the Inbox.
public struct CaptureParser: Sendable {
    private struct Prefix: Sendable {
        var key: String
        var space: SpaceID
        var written: String
    }

    /// Every name and keyword, longest first; spaces in sidebar order among equals.
    private let prefixes: [Prefix]

    public init(spaces: [Space]) {
        var all: [Prefix] = []
        for space in spaces {
            for word in [space.name] + space.keywords {
                let key = NameSanitizer.key(word.trimmingCharacters(in: .whitespaces))
                if !key.isEmpty {
                    all.append(Prefix(key: key, space: space.id, written: word))
                }
            }
        }
        var order: [SpaceID: Int] = [:]
        for (index, space) in spaces.enumerated() {
            order[space.id] = index
        }
        prefixes = all.sorted { first, second in
            if first.key.count != second.key.count {
                return first.key.count > second.key.count
            }
            return (order[first.space] ?? 0) < (order[second.space] ?? 0)
        }
    }

    /// The draft for `text`, or nil when there is nothing in it.
    public func parse(_ text: String, now: Date, timeZone: TimeZone) -> CaptureDraft? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var destination = CaptureDestination.inbox
        var content = trimmed
        if let (prefix, rest) = matchingPrefix(of: trimmed) {
            destination = .space(prefix.space, matched: prefix.written)
            content = rest
        }
        let firstLine = content.split(whereSeparator: \.isNewline).first.map(String.init)
        let title = NameSanitizer.captureTitle(firstLine: firstLine, now: now, timeZone: timeZone)
        // One line that is the title, letter for letter, needs no body that repeats it.
        let body = content == title ? "" : content
        return CaptureDraft(destination: destination, title: title, body: body)
    }

    /// The longest name or keyword `text` starts with, when a colon, whitespace and more text follow.
    private func matchingPrefix(of text: String) -> (Prefix, rest: String)? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let typed = NameSanitizer.key(text[..<colon].trimmingCharacters(in: .whitespaces))
        let afterColon = text[text.index(after: colon)...]
        guard let next = afterColon.first, next.isWhitespace, !typed.isEmpty else { return nil }
        let rest = afterColon.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty, let prefix = prefixes.first(where: { $0.key == typed }) else { return nil }
        return (prefix, rest)
    }
}
