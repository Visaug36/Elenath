import Foundation

extension EventLink {
    /// The link a note's front matter holds for one occurrence: its event's id and its original day
    /// (`Occurrence.date`, the series key), as Ithil's folder markers name it.
    public init(_ occurrence: Occurrence) {
        self.init(eventID: occurrence.event.id, day: occurrence.date.isoString)
    }

    /// The link for an occurrence's id, as `init(_:)` gives for the occurrence.
    public init(_ id: Occurrence.ID) {
        self.init(eventID: id.eventID, day: id.date.isoString)
    }

    /// The occurrence this link names, when its day is a real date.
    public var occurrenceID: Occurrence.ID? {
        guard let date = CalendarDate(isoString: day), date.isValid else { return nil }
        return Occurrence.ID(eventID: eventID, date: date)
    }
}
