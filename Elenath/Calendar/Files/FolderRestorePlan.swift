import ElenathCore
import Foundation

/// An Undo or Redo, as `FilesController` hands it to `EventFolders` to carry folders back along: the
/// library before it and the version it put back.
struct FolderRestore: Sendable {
    var old: CalendarDocument
    var new: CalendarDocument
    /// The display time zone, where all-day occurrences are placed.
    var timeZone: TimeZone
}

/// A folder `FilesController` moved to the Trash after a deletion, kept so Undo can put it back.
struct TrashedEventFolder: Sendable {
    /// The occurrence the folder belonged to, as it was when it was trashed.
    var occurrence: Occurrence
    /// Where the folder is in the Trash.
    var trashedURL: URL
}

/// Works out which event folders an Undo or Redo moves. Pure: it only compares the library before and
/// after.
///
/// An undo step puts back a whole earlier library, so there is no edited occurrence to start from as in
/// `FolderCarryPlan`. Instead each folder of a changed event looks for its occurrence in the library put
/// back, undoing (or redoing) what `SeriesEditing` did: the same event (moved along when a series moved to
/// another first day, a single event wherever it went), a detached occurrence going back to its series or
/// coming out of it again, or a split series joining up again or splitting again. Folders with no new home
/// stay where they are; nothing is ever trashed.
enum FolderRestorePlan {
    /// The events of `old` whose folders can need to move: changed in a way that touches folder names or
    /// occurrences (title, timing, repeat rule, excluded dates, series link), or gone from `new`.
    static func changedEvents(_ restore: FolderRestore) -> [Event] {
        var newEvents: [UUID: Event] = [:]
        for event in restore.new.events where newEvents[event.id] == nil {
            newEvents[event.id] = event
        }
        return restore.old.events.filter { event in
            guard let counterpart = newEvents[event.id] else { return true }
            return FolderShape(event) != FolderShape(counterpart)
        }
    }

    /// Whether the changed events' folders can only be found by a full scan of the markers: one of them
    /// repeats, so it can have a folder for every one of its dates.
    static func needsFullScan(_ changed: [Event]) -> Bool {
        changed.contains { $0.repeats }
    }

    /// The occurrences of changed events that don't repeat: each has one folder at most.
    static func singleOccurrenceIDs(_ changed: [Event]) -> [Occurrence.ID] {
        changed.filter { !$0.repeats }.map { Occurrence.ID(eventID: $0.id, date: $0.timing.startDate) }
    }

    /// The folders to move, in an order where no move lands on a folder that is still waiting to move.
    /// `markedIDs` are the occurrences that may have folders; only those of `changed` events are looked at.
    static func moves(
        forMarked markedIDs: [Occurrence.ID],
        restore: FolderRestore,
        changed: [Event]
    ) -> [FolderCarryPlan.Move] {
        let context = FolderRestoreContext(restore, changed: changed)
        var moves: [FolderCarryPlan.Move] = []
        for id in markedIDs {
            guard let oldEvent = context.changedEvents[id.eventID] else { continue }
            guard let from = context.expander.occurrence(of: oldEvent, on: id.date) else { continue }
            guard let to = context.newHome(of: from) else { continue }
            let samePath = FolderNaming.relativePath(for: to) == FolderNaming.relativePath(for: from)
            if to.id == from.id && samePath {
                continue
            }
            moves.append(FolderCarryPlan.Move(from: from, to: to))
        }
        let movesForward = moves.contains { $0.from.date < $0.to.date }
        return moves.sorted { first, second in
            movesForward ? first.from.date > second.from.date : first.from.date < second.from.date
        }
    }
}

/// The parts of an event that its folders' names and occurrences depend on.
private struct FolderShape: Equatable {
    var title: String
    var timing: EventTiming
    var recurrence: RecurrenceRule?
    var excludedDates: Set<CalendarDate>
    var detachedFrom: SeriesOccurrence?

    init(_ event: Event) {
        title = event.title
        timing = event.timing
        recurrence = event.recurrence
        excludedDates = event.excludedDates
        detachedFrom = event.detachedFrom
    }
}

/// What finding the new homes of folders after an Undo or Redo needs, worked out once.
private struct FolderRestoreContext {
    let expander: OccurrenceExpander
    /// The changed events, as they were in `old`.
    let changedEvents: [UUID: Event]
    /// Every event of the library put back.
    let newEvents: [UUID: Event]
    /// Events of the library put back that weren't in `old`: a detached occurrence or the second half of a
    /// split series, coming back with Redo.
    let added: [Event]

    init(_ restore: FolderRestore, changed: [Event]) {
        expander = OccurrenceExpander(displayTimeZone: restore.timeZone)
        var changedEvents: [UUID: Event] = [:]
        for event in changed where changedEvents[event.id] == nil {
            changedEvents[event.id] = event
        }
        self.changedEvents = changedEvents
        var newEvents: [UUID: Event] = [:]
        for event in restore.new.events where newEvents[event.id] == nil {
            newEvents[event.id] = event
        }
        self.newEvents = newEvents
        let oldIDs = Set(restore.old.events.map(\.id))
        added = restore.new.events.filter { !oldIDs.contains($0.id) }
    }

    /// The occurrence in the library put back that the folder of `from` belongs to, or nil if it has none.
    func newHome(of from: Occurrence) -> Occurrence? {
        let oldEvent = from.event
        if let same = newEvents[oldEvent.id] {
            if let found = sameEventHome(of: from.date, oldEvent: oldEvent, newEvent: same) {
                return found
            }
            if let found = splitAgainHome(of: from.date, series: oldEvent, cut: same) {
                return found
            }
        } else {
            if let found = seriesHome(ofDetached: oldEvent) {
                return found
            }
            if let found = rejoinedHome(of: from.date, continuation: oldEvent) {
                return found
            }
        }
        let link = SeriesOccurrence(seriesID: oldEvent.id, date: from.date)
        if let detached = added.first(where: { $0.detachedFrom == link }) {
            // Redo of "this event only": the occurrence is its own event again.
            return expander.occurrence(of: detached, on: detached.timing.startDate)
        }
        return nil
    }

    /// The same event in the library put back: a single event's folder follows it to whatever day it is on
    /// (its first occurrence if it repeats there); a series' folders move along when its first day moved.
    private func sameEventHome(of date: CalendarDate, oldEvent: Event, newEvent: Event) -> Occurrence? {
        let oldStart = oldEvent.timing.startDate
        let newStart = newEvent.timing.startDate
        guard let rule = oldEvent.recurrence else {
            return expander.occurrence(of: newEvent, on: newStart)
        }
        guard newEvent.repeats else {
            return date == oldStart ? expander.occurrence(of: newEvent, on: newStart) : nil
        }
        let moved = FolderCarryPlan.movedSeriesDay(date, rule: rule, from: oldStart, to: newStart)
        return moved.flatMap { expander.occurrence(of: newEvent, on: $0) }
    }

    /// Undo of "this event only": the detached event is gone, and its series has the date again.
    private func seriesHome(ofDetached event: Event) -> Occurrence? {
        guard let link = event.detachedFrom, let series = newEvents[link.seriesID] else { return nil }
        return expander.occurrence(of: series, on: link.date)
    }

    /// Undo of "all future events" on a later occurrence: `continuation` (the second half) is gone, and
    /// the series it split from runs on past the day it ended. The occurrences go back to the dates they
    /// had in that series.
    private func rejoinedHome(of date: CalendarDate, continuation: Event) -> Occurrence? {
        guard continuation.detachedFrom == nil else { return nil }
        let start = continuation.timing.startDate
        for candidate in changedEvents.values where candidate.id != continuation.id {
            guard let cut = candidate.recurrence?.until, let series = newEvents[candidate.id] else { continue }
            guard let rule = series.recurrence, rule.until.map({ $0 > cut }) ?? true else { continue }
            let split = cut.adding(days: 1)
            let target: CalendarDate?
            if continuation.repeats {
                target = FolderCarryPlan.movedSeriesDay(date, rule: rule, from: start, to: split)
            } else {
                target = date == start ? split : nil
            }
            if let target, let found = expander.occurrence(of: series, on: target) {
                return found
            }
        }
        return nil
    }

    /// Redo of "all future events" on a later occurrence: the series ends again the day before `date`'s
    /// part, and the second half (new in the library put back) takes the occurrence.
    private func splitAgainHome(of date: CalendarDate, series oldSeries: Event, cut newSeries: Event) -> Occurrence? {
        guard let rule = oldSeries.recurrence, let cut = newSeries.recurrence?.until, date > cut else { return nil }
        guard rule.until.map({ $0 > cut }) ?? true else { return nil }
        let split = cut.adding(days: 1)
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
