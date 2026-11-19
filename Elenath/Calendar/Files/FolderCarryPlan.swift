import ElenathCore
import Foundation

/// An edit, as `FilesController` hands it to `EventFolders` to carry the event's folders along.
struct FolderUpdate: Sendable {
    /// The occurrence the user edited, as it was before the edit.
    var occurrence: Occurrence
    var scope: SeriesEditing.Scope
    var old: CalendarDocument
    var new: CalendarDocument
    /// The display time zone, where all-day occurrences are placed.
    var timeZone: TimeZone
}

/// A deletion, as `FilesController` hands it to `EventFolders` to put the deleted occurrences' folders in
/// the Trash.
struct FolderDeletion: Sendable {
    /// The occurrence the user deleted, as it was before.
    var occurrence: Occurrence
    var scope: SeriesEditing.Scope
    var old: CalendarDocument
    var new: CalendarDocument
    /// The display time zone, where all-day occurrences are placed.
    var timeZone: TimeZone
}

/// Works out which event folders an edit moves and which a deletion trashes. Pure: it only compares the
/// library before and after, following the rules of `SeriesEditing` (docs/ARCHITECTURE.md).
enum FolderCarryPlan {
    /// One folder to carry along: from the occurrence it belonged to, to the one it belongs to now.
    struct Move: Sendable {
        var from: Occurrence
        var to: Occurrence
    }

    /// Whether an edit or deletion of `occurrence` can concern more folders than the occurrence's own
    /// (it belongs to a repeating event), so every marked folder has to be looked at.
    static func concernsSeries(_ occurrence: Occurrence, in library: CalendarDocument) -> Bool {
        library.event(withID: occurrence.event.id)?.repeats ?? false
    }

    // MARK: - Edits

    /// The folders of the edited event that need to move, in an order where no move lands on a folder
    /// that is still waiting to move. `markedIDs` are the occurrences that have marked folders.
    ///
    /// Each folder of the edited event finds its new occurrence: the same event on the same date (a
    /// series moved to another day takes its dates along, as `SeriesEditing` does; a single event's folder
    /// follows it wherever it went); else the event detached from that date by this edit; else, after an
    /// "all future events" split, the new series' occurrence on that date. Folders with no new home are
    /// left where they are, and folders whose path and occurrence didn't change aren't touched.
    static func moves(forMarked markedIDs: [Occurrence.ID], update: FolderUpdate) -> [Move] {
        guard let edit = FolderEditContext(update) else { return [] }
        var moves: [Move] = []
        for id in markedIDs where id.eventID == edit.oldEvent.id {
            guard let from = edit.expander.occurrence(of: edit.oldEvent, on: id.date) else { continue }
            guard let to = edit.newHome(of: from) else { continue }
            let samePath = FolderNaming.relativePath(for: to) == FolderNaming.relativePath(for: from)
            if to.id == from.id && samePath {
                continue
            }
            moves.append(Move(from: from, to: to))
        }
        let movesForward = moves.contains { $0.from.date < $0.to.date }
        return moves.sorted { first, second in
            movesForward ? first.from.date > second.from.date : first.from.date < second.from.date
        }
    }

    // MARK: - Deletions

    /// The occurrences whose folders a deletion puts in the Trash: the deleted occurrence; for "all future
    /// events" of a series, every marked folder of the series from that date on, plus the folders of the
    /// detached events that were removed with it. An occurrence that still exists afterwards is never
    /// included.
    static func trashTargets(forMarked markedIDs: [Occurrence.ID], deletion: FolderDeletion) -> [Occurrence] {
        let expander = OccurrenceExpander(displayTimeZone: deletion.timeZone)
        let deleted = deletion.occurrence
        guard let oldEvent = deletion.old.event(withID: deleted.event.id) else { return [] }
        var candidates: [Occurrence] = []
        if oldEvent.repeats && deletion.scope == .allFutureEvents {
            for id in markedIDs where id.eventID == oldEvent.id && id.date >= deleted.date {
                if let occurrence = expander.occurrence(of: oldEvent, on: id.date) {
                    candidates.append(occurrence)
                }
            }
            let newIDs = Set(deletion.new.events.map(\.id))
            for event in deletion.old.events where !newIDs.contains(event.id) {
                guard event.detachedFrom?.seriesID == oldEvent.id else { continue }
                if let occurrence = expander.occurrence(of: event, on: event.timing.startDate) {
                    candidates.append(occurrence)
                }
            }
        } else {
            candidates.append(expander.occurrence(of: oldEvent, on: deleted.date) ?? deleted)
        }
        var newEvents: [UUID: Event] = [:]
        for event in deletion.new.events where newEvents[event.id] == nil {
            newEvents[event.id] = event
        }
        return candidates.filter { candidate in
            guard let event = newEvents[candidate.event.id] else { return true }
            return expander.occurrence(of: event, on: candidate.date) == nil
        }
    }

    // MARK: - Series days

    /// Where an original series day lands when the series moves from `start` to `newStart`: the same
    /// number of days later for daily and weekly rules, the same number of months later (on `newStart`'s
    /// day of the month) for monthly ones; nil when that month lacks the day. The same rule
    /// `SeriesEditing` applies to excluded dates and detached events.
    static func movedSeriesDay(
        _ day: CalendarDate,
        rule: RecurrenceRule,
        from start: CalendarDate,
        to newStart: CalendarDate
    ) -> CalendarDate? {
        guard newStart != start else { return day }
        switch rule.frequency {
        case .daily, .weekly:
            return day.adding(days: start.days(to: newStart))
        case .monthly:
            let index = monthIndex(newStart) + monthIndex(day) - monthIndex(start)
            guard index >= 0 else { return nil }
            let moved = CalendarDate(year: index / 12, month: index % 12 + 1, day: newStart.day)
            return moved.isValid ? moved : nil
        }
    }

    private static func monthIndex(_ day: CalendarDate) -> Int {
        day.year * 12 + day.month - 1
    }
}

/// What finding the new home of an edited event's folders needs, worked out once per edit.
private struct FolderEditContext {
    let update: FolderUpdate
    let oldEvent: Event
    /// Events the edit added: a detached occurrence, or the new series after a split.
    let added: [Event]
    let expander: OccurrenceExpander

    init?(_ update: FolderUpdate) {
        guard let oldEvent = update.old.event(withID: update.occurrence.event.id) else { return nil }
        let oldIDs = Set(update.old.events.map(\.id))
        self.update = update
        self.oldEvent = oldEvent
        self.added = update.new.events.filter { !oldIDs.contains($0.id) }
        self.expander = OccurrenceExpander(displayTimeZone: update.timeZone)
    }

    /// The occurrence the folder of `from` belongs to after the edit, or nil if it has none.
    func newHome(of from: Occurrence) -> Occurrence? {
        if let same = update.new.event(withID: oldEvent.id) {
            if let found = sameEventHome(of: from.date, newEvent: same) {
                return found
            }
        }
        let link = SeriesOccurrence(seriesID: oldEvent.id, date: from.date)
        if let detached = added.first(where: { $0.detachedFrom == link }) {
            return expander.occurrence(of: detached, on: detached.timing.startDate)
        }
        return splitHome(of: from.date)
    }

    /// Where the folder on `date` goes when the event still exists (edited in place, or the part of a
    /// split series before the edited occurrence).
    private func sameEventHome(of date: CalendarDate, newEvent: Event) -> Occurrence? {
        let oldStart = oldEvent.timing.startDate
        let newStart = newEvent.timing.startDate
        guard let rule = oldEvent.recurrence else {
            // A single event's folder follows it, whatever day it moved to (and if it repeats now, to its
            // first occurrence).
            return expander.occurrence(of: newEvent, on: newStart)
        }
        guard newEvent.repeats else {
            // The series became a single event: only its first occurrence's folder goes with it.
            return date == oldStart ? expander.occurrence(of: newEvent, on: newStart) : nil
        }
        let moved = FolderCarryPlan.movedSeriesDay(date, rule: rule, from: oldStart, to: newStart)
        return moved.flatMap { expander.occurrence(of: newEvent, on: $0) }
    }

    /// After "all future events" was edited on a later occurrence: the new series' occurrence that takes
    /// the place of `date` (the edited occurrence and the ones after it).
    private func splitHome(of date: CalendarDate) -> Occurrence? {
        let split = update.occurrence.date
        guard update.scope == .allFutureEvents, let rule = oldEvent.recurrence, date >= split else { return nil }
        for continuation in added where continuation.detachedFrom == nil {
            let newStart = continuation.timing.startDate
            if continuation.repeats {
                let moved = FolderCarryPlan.movedSeriesDay(date, rule: rule, from: split, to: newStart)
                if let moved, let found = expander.occurrence(of: continuation, on: moved) {
                    return found
                }
            } else if date == split {
                return expander.occurrence(of: continuation, on: newStart)
            }
        }
        return nil
    }
}
