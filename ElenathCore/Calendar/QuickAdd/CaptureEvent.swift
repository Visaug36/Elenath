import Foundation

/// The event Quick Capture's ⌥↩ adds (docs/ARCHITECTURE.md, "Capture"): Quick Add's reading of the text, sent
/// where the text says.
///
/// - Only the first line is read, and at most `maximumLength` characters of it: a capture is a note by
///   default, and a pasted page is never read again at every keystroke.
/// - Text that starts with a space's name or keyword ("red cross: debrief sat 9pm") goes to that space, as a
///   note would: the name isn't part of the event, and its subject is one whose home is that space (the one
///   Quick Add found if it lives there, else the first that does).
/// - Text for a sealed space where no subject has its home gives no event: it would have no home, and its
///   notes and files would show everywhere.
public enum CaptureEvent {
    /// How much of the first line Quick Add reads.
    public static let maximumLength = 300

    public enum Reading: Hashable, Sendable {
        case event(QuickAddDraft)
        /// The line names a date or time, and the sealed space it is meant for has no subject living there.
        case noSubjectIn(SpaceID)
    }

    /// What ⌥↩ would add for `text`, reading the line with `parse` (Quick Add). Nil when the line names no date
    /// or time.
    public static func read(
        _ text: String, spaces: [Space], subjects: [Subject], settings: CalendarSettings,
        parse: (String) -> QuickAddDraft?
    ) -> Reading? {
        guard let (destination, line) = eventLine(of: text, spaces: spaces), var draft = parse(line),
            draft.hasDate || draft.hasTime
        else { return nil }
        guard case .space(let space, _) = destination else { return .event(draft) }
        let homed = subjects.filter { subject in
            guard case .home(let home) = settings.entry(forSubject: subject.id) else { return false }
            return home.space == space
        }
        if let chosen = draft.subjectID, homed.contains(where: { $0.id == chosen }) {
            return .event(draft)
        }
        if let first = homed.first {
            draft.subjectID = first.id
            return .event(draft)
        }
        // A space that mixes keeps what Quick Add found; a sealed one (or one that is gone) can't be met.
        guard spaces.first(where: { $0.id == space })?.isSealed == false else { return .noSubjectIn(space) }
        return .event(draft)
    }

    /// Where the capture goes and the line Quick Add reads: the first line after the space's name or keyword,
    /// cut to `maximumLength` characters. Nil for blank text.
    public static func eventLine(of text: String, spaces: [Space]) -> (destination: CaptureDestination, line: String)? {
        guard let (destination, content) = CaptureParser(spaces: spaces).split(text) else { return nil }
        let firstLine = content.prefix(maximumLength).prefix { !$0.isNewline }
        let line = firstLine.trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : (destination, line)
    }
}
