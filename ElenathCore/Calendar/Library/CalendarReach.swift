import Foundation

/// What of the calendar a workplace may read. **This is the calendar's one decision point**, beside
/// `Reach` (docs/ARCHITECTURE.md, "The sealing exception").
///
/// The calendar is the one deliberate exception to sealing: every event's title, time, location and
/// file count cross every seal (the calendar, Today, notifications and the menu bar show them from
/// everywhere), and "Open Files" opens any event's folder in Finder. An event's **content** (its notes, its
/// files' names and contents, and the notes linked to it) is read only where its home's content may be:
///
/// | The event | Its content is read from |
/// |---|---|
/// | no subject, or a subject without a home | where the spaces that mix are read: everywhere, an unsealed space |
/// | homed in a space | where `Reach` allows that space |
/// | homed in a space that is gone, or whose entry can't be read | nowhere, until the subject has a home again |
///
/// A home that can't be used fails closed: it may have been a sealed space.
public struct CalendarReach: Hashable, Sendable {
    public let reach: Reach

    private let settings: CalendarSettings
    private let spaceIDs: Set<SpaceID>
    private let sealedSpaceIDs: Set<SpaceID>
    /// Whether the workplace reads the spaces that mix, where events without a home belong.
    private let readsSpacesThatMix: Bool

    public init(workplace: Workplace, spaces: [Space], settings: CalendarSettings) {
        reach = Reach(workplace: workplace, spaces: spaces)
        self.settings = settings
        spaceIDs = Set(spaces.map(\.id))
        sealedSpaceIDs = Set(spaces.filter(\.isSealed).map(\.id))
        switch workplace {
        case .everywhere:
            readsSpacesThatMix = true
        case .inbox:
            readsSpacesThatMix = false
        case .space(let id):
            readsSpacesThatMix = spaces.first { $0.id == id }.map { !$0.isSealed } ?? false
        }
    }

    public var workplace: Workplace {
        reach.workplace
    }

    /// The event's home: its subject's home, when that space exists. Nil for an event without a home, and
    /// for one whose home can't be used (`hasMissingHome(_:)`).
    public func home(of event: Event) -> SubjectHome? {
        guard case .home(let home) = settings.entry(forSubject: event.subjectID), spaceIDs.contains(home.space)
        else { return nil }
        return home
    }

    /// Whether the event's subject has a home that can't be used: its space is gone, or its entry in
    /// library.json can't be read. The event's content is then read from nowhere, and the app asks for a
    /// new home.
    public func hasMissingHome(_ event: Event) -> Bool {
        switch settings.entry(forSubject: event.subjectID) {
        case .none: false
        case .unreadable: true
        case .home(let home): !spaceIDs.contains(home.space)
        }
    }

    /// Whether the event's notes, its files' names and contents, and the notes linked to it may be read
    /// from the workplace.
    public func mayReadContent(of event: Event) -> Bool {
        switch settings.entry(forSubject: event.subjectID) {
        case .none:
            return readsSpacesThatMix
        case .unreadable:
            return false
        case .home(let home):
            return spaceIDs.contains(home.space) && reach.allows(.space(home.space))
        }
    }

    /// Whether deleting the subject would bring its events' content out of a seal: the events would have no
    /// home, and an event without a home is read wherever the spaces that mix are. True when the subject has
    /// events and its home is a sealed space, a space that is gone, or an entry that can't be read. The app
    /// doesn't delete such a subject; its events need another subject first.
    public func deletingSubjectWouldUnseal(_ subject: UUID, in document: CalendarDocument) -> Bool {
        guard document.events.contains(where: { $0.subjectID == subject }) else { return false }
        switch settings.entry(forSubject: subject) {
        case .none:
            return false
        case .unreadable:
            return true
        case .home(let home):
            return !spaceIDs.contains(home.space) || sealedSpaceIDs.contains(home.space)
        }
    }

    /// The event's notes, or nil when they may not be read from the workplace.
    public func notes(of event: Event) -> String? {
        mayReadContent(of: event) ? event.notes : nil
    }

    /// The occurrence's files, or nil when their names may not be read from the workplace: the count
    /// (`EventFolders.fileCount(for:)`) and "Open Files" are all that is shown then.
    public func files(for occurrence: Occurrence, in folders: EventFolders) async -> [EventFile]? {
        guard mayReadContent(of: occurrence.event) else { return nil }
        return await folders.files(for: occurrence)
    }

    /// Whether the event matches a calendar search: by title and location always, by notes only where
    /// they may be read.
    public func matches(_ event: Event, query: String) -> Bool {
        EventSearch.matches(event, query: query, includingNotes: mayReadContent(of: event))
    }

    /// The calendar's own search (`EventSearch.search`): every event by its title and location, and by its
    /// notes only where they may be read. Never by its files.
    public func search(
        _ document: CalendarDocument, query: String, now: Date, expander: OccurrenceExpander
    ) -> [Occurrence] {
        EventSearch.search(document, query: query, now: now, expander: expander) { mayReadContent(of: $0) }
    }
}
