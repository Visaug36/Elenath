import Foundation

/// The names Elenath gives to notes and folders, and how names are compared (docs/FORMAT.md, "Names").
///
/// Elenath only creates and renames items with names that pass through here. Names made in Finder are used
/// as they are.
public enum NameSanitizer {
    /// The most Characters (grapheme clusters) a sanitized title keeps.
    public static let maximumTitleLength = 120

    /// The most Characters the title of a capture keeps.
    public static let maximumCaptureTitleLength = 60

    /// The title used when nothing is left after sanitizing.
    public static let fallbackTitle = "Untitled"

    /// The most UTF-8 bytes a sanitized title keeps. File names are limited to 255 bytes; this leaves room
    /// for an extension, a clash number (" 999") and a conflict suffix (" (conflict 2026-11-10 14.30)").
    static let maximumTitleUTF8Length = 200

    /// `title` made safe as the name of a note (without its extension) or of a folder.
    ///
    /// - "/" and ":" become "-", and so do "#", "|", "^", "[" and "]", which would break a wiki link to
    ///   the note (as in Obsidian).
    /// - Control characters and line breaks become spaces; runs of whitespace collapse to one space;
    ///   whitespace at both ends is trimmed.
    /// - Leading dots (and spaces after them) are removed, so the item is never hidden.
    /// - Trailing dots and spaces are removed.
    /// - The result is cut to `maximumTitleLength` Characters and 200 UTF-8 bytes without splitting a
    ///   Character, then trimmed again.
    /// - Nothing left ("", ".", "..") gives `fallbackTitle`.
    public static func sanitizedTitle(_ title: String) -> String {
        sanitized(title, maximumLength: maximumTitleLength) ?? fallbackTitle
    }

    /// The title of a capture: its first line made safe as a name and cut to
    /// `maximumCaptureTitleLength`, or "Capture 2026-11-10 14.30" (local time) when the line is missing or
    /// has nothing in it.
    public static func captureTitle(firstLine: String?, now: Date, timeZone: TimeZone) -> String {
        if let firstLine, let title = sanitized(firstLine, maximumLength: maximumCaptureTitleLength) {
            return title
        }
        return "Capture \(stamp(now, in: timeZone))"
    }

    /// The title of the copy that keeps unsaved edits when a note changed on disk meanwhile:
    /// "Title (conflict 2026-11-10 14.30)", in local time.
    ///
    /// A long title is shortened so that the whole stays within 200 UTF-8 bytes, like any title Elenath
    /// makes: a name made in Finder can be close to the file system's limit already.
    public static func conflictTitle(for title: String, now: Date, timeZone: TimeZone) -> String {
        let suffix = " (conflict \(stamp(now, in: timeZone)))"
        var base = title
        while !base.isEmpty, (base + suffix).utf8.count > maximumTitleUTF8Length {
            base.removeLast()
        }
        return droppingTrailingDotsAndSpaces(base) + suffix
    }

    /// How names are compared: without regard to case or Unicode normalization, as macOS volumes do.
    /// Two names are the same item when their keys are equal.
    public static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Whether `name`, directly inside the library folder, is not a space: Elenath's own folder, the
    /// Inbox, or anything hidden.
    public static func isReservedAtLibraryRoot(_ name: String) -> Bool {
        name.hasPrefix(".") || key(name) == key(inboxFolderName)
    }

    /// Whether `name`, inside a space or the Inbox, is not a folder of notes: Elenath's own folder, an
    /// attachments folder, a board package, or anything hidden.
    public static func isReservedInSpace(_ name: String) -> Bool {
        if name.hasPrefix(".") {
            return true
        }
        let nameKey = key(name)
        return nameKey == key(attachmentsFolderName) || nameKey.hasSuffix(boardExtension)
    }

    /// The Inbox's folder, whatever language Elenath runs in.
    public static let inboxFolderName = "Inbox"

    /// The folder beside a note that holds the files dropped on it.
    public static let attachmentsFolderName = "Attachments"

    /// The end of a board package's name.
    static let boardExtension = ".board"

    // MARK: - Private

    /// `text` sanitized and cut to `maximumLength` Characters, or nil when nothing is left.
    private static func sanitized(_ text: String, maximumLength: Int) -> String? {
        var cleaned = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "/", ":", "#", "|", "^", "[", "]":
                cleaned.append("-")
            default:
                cleaned.append(isControlOrLineBreak(scalar) ? " " : scalar)
            }
        }
        var result = collapsingWhitespace(String(cleaned))
        result = droppingLeadingDots(result)
        result = droppingTrailingDotsAndSpaces(result)
        result = truncated(result, maximumLength: maximumLength)
        return result.isEmpty ? nil : result
    }

    /// Control characters (tab, NUL, DEL…) and line or paragraph separators.
    private static func isControlOrLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator:
            return true
        default:
            return false
        }
    }

    /// `text` with every run of whitespace replaced by one space and no whitespace at either end.
    private static func collapsingWhitespace(_ text: String) -> String {
        var result = ""
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                pendingSpace = !result.isEmpty
            } else {
                if pendingSpace {
                    result.append(" ")
                }
                pendingSpace = false
                result.append(character)
            }
        }
        return result
    }

    /// `text` without leading dots or the spaces between them. A Character that merely starts with a dot
    /// (a dot with a combining mark) counts as a dot, since the file system only sees the first byte.
    private static func droppingLeadingDots(_ text: String) -> String {
        var remainder = Substring(text)
        while let first = remainder.first, first.unicodeScalars.first == "." || first.isWhitespace {
            remainder = remainder.dropFirst()
        }
        return String(remainder)
    }

    private static func droppingTrailingDotsAndSpaces(_ text: String) -> String {
        var remainder = Substring(text)
        while let last = remainder.last, last == "." || last.isWhitespace {
            remainder = remainder.dropLast()
        }
        return String(remainder)
    }

    /// `text` cut to `maximumLength` Characters and `maximumTitleUTF8Length` bytes, whole Characters only,
    /// then trimmed again.
    private static func truncated(_ text: String, maximumLength: Int) -> String {
        var result = String(text.prefix(maximumLength))
        while result.utf8.count > maximumTitleUTF8Length {
            result.removeLast()
        }
        return droppingTrailingDotsAndSpaces(result)
    }

    /// "2026-11-10 14.30": the wall-clock time in `timeZone`, built from calendar components (no
    /// DateFormatter, so the user's locale and calendar can't change it).
    private static func stamp(_ date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let time = String(format: "%02d.%02d", parts.hour ?? 0, parts.minute ?? 0)
        return "\(day) \(time)"
    }
}
