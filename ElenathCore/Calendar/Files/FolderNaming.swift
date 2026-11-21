import Foundation

/// The names of event folders inside the library root.
///
/// ```
/// <root>/2026-10-06/14.00 Physics Lecture/    a timed occurrence: its day and HH.mm in the event's own time zone
/// <root>/2026-10-14/Mara's birthday/          an all-day occurrence: its first day, no time
/// ```
///
/// Timed names use the event's own time zone, not the Mac's, so a folder never changes name when the
/// user travels. Each occurrence of a repeating event has its own day, so its own folder.
public enum FolderNaming {
    /// The most Characters (grapheme clusters) a sanitized title keeps.
    public static let maximumTitleLength = 80

    /// The folder title used when a title has nothing left after sanitizing.
    public static let fallbackTitle = "Event"

    /// The most UTF-8 bytes a sanitized title keeps. File names are limited to 255 bytes, and a folder
    /// name adds "HH.mm " (6 bytes) and maybe a " 999" clash suffix (4 bytes), so titles made of wide
    /// characters (80 emoji are 320 bytes) are cut a little earlier, still on a Character boundary.
    static let maximumTitleUTF8Length = 240

    /// `title` made safe as (part of) a folder name.
    ///
    /// - "/" and ":" become "-".
    /// - Control characters and line breaks become spaces; runs of whitespace collapse to one space;
    ///   whitespace at both ends is trimmed.
    /// - Leading dots (and spaces after them) are removed, so the folder is never hidden.
    /// - Trailing dots and spaces are removed.
    /// - The result is cut to `maximumTitleLength` Characters (fewer for very wide characters) without
    ///   splitting a Character, then trimmed again.
    /// - Nothing left ("", ".", "..") gives `fallbackTitle`.
    public static func sanitizedTitle(_ title: String) -> String {
        var cleaned = String.UnicodeScalarView()
        for scalar in title.unicodeScalars {
            switch scalar {
            case "/", ":":
                cleaned.append("-")
            default:
                cleaned.append(isControlOrLineBreak(scalar) ? " " : scalar)
            }
        }
        var result = collapsingWhitespace(String(cleaned))
        result = droppingLeadingDots(result)
        result = droppingTrailingDotsAndSpaces(result)
        result = truncated(result)
        return result.isEmpty ? fallbackTitle : result
    }

    /// The day folder, `yyyy-MM-dd`: for a timed occurrence the day it starts on in the event's own time
    /// zone, for an all-day occurrence its first day.
    public static func dayFolderName(for occurrence: Occurrence) -> String {
        switch occurrence.event.timing {
        case .timed(_, _, let timeZone):
            return CalendarDate(occurrence.start, in: timeZone).isoString
        case .allDay:
            return occurrence.date.isoString
        }
    }

    /// The event folder inside the day folder: "HH.mm Title" (24-hour, in the event's own time zone) for
    /// a timed occurrence, the sanitized title alone for an all-day one.
    public static func eventFolderName(for occurrence: Occurrence) -> String {
        let title = sanitizedTitle(occurrence.event.title)
        switch occurrence.event.timing {
        case .timed(_, _, let timeZone):
            return "\(timePrefix(of: occurrence.start, in: timeZone)) \(title)"
        case .allDay:
            return title
        }
    }

    /// "yyyy-MM-dd/<event folder name>", relative to the library root.
    public static func relativePath(for occurrence: Occurrence) -> String {
        "\(dayFolderName(for: occurrence))/\(eventFolderName(for: occurrence))"
    }

    // MARK: - Helpers

    /// "HH.mm" for `instant` in `timeZone`, 24-hour and zero-padded.
    private static func timePrefix(of instant: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: instant)
        return String(format: "%02d.%02d", parts.hour ?? 0, parts.minute ?? 0)
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

    /// `text` cut to `maximumTitleLength` Characters and `maximumTitleUTF8Length` bytes, whole
    /// Characters only, then trimmed again.
    private static func truncated(_ text: String) -> String {
        var result = String(text.prefix(maximumTitleLength))
        while result.utf8.count > maximumTitleUTF8Length {
            result.removeLast()
        }
        return droppingTrailingDotsAndSpaces(result)
    }
}
