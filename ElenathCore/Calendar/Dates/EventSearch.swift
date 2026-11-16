import Foundation

/// The toolbar search: finds events by title, location and notes.
public enum EventSearch {
    /// Whether every whitespace-separated term of `query` appears in the event's title, location or
    /// notes, ignoring case and diacritics ("cafe" finds "Café"). Terms may match different fields. A
    /// blank query matches every event.
    public static func matches(_ event: Event, query: String) -> Bool {
        matches(event, terms: searchTerms(in: query))
    }

    /// One row per matching event: its next occurrence that hasn't ended yet (one in progress counts),
    /// or, if it has none, its latest past occurrence. Upcoming rows come first, soonest first; then
    /// past rows, most recent first. A blank query finds nothing.
    public static func search(
        _ library: CalendarDocument,
        query: String,
        now: Date,
        expander: OccurrenceExpander
    ) -> [Occurrence] {
        let terms = searchTerms(in: query)
        guard !terms.isEmpty else { return [] }
        var upcoming: [Occurrence] = []
        var past: [Occurrence] = []
        for event in library.events where matches(event, terms: terms) {
            if let next = expander.nextOccurrence(of: event, unfinishedAt: now) {
                upcoming.append(next)
            } else if let latest = expander.latestOccurrence(of: event, finishedBy: now) {
                past.append(latest)
            }
        }
        upcoming.sort(by: OccurrenceExpander.chronologicalOrder)
        past.sort { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start > rhs.start }
            return OccurrenceExpander.chronologicalOrder(lhs, rhs)
        }
        return upcoming + past
    }

    private static func searchTerms(in query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
    }

    private static func matches(_ event: Event, terms: [String]) -> Bool {
        terms.allSatisfy { term in
            fieldContains(event.title, term) || fieldContains(event.location, term) || fieldContains(event.notes, term)
        }
    }

    private static func fieldContains(_ field: String, _ term: String) -> Bool {
        field.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
