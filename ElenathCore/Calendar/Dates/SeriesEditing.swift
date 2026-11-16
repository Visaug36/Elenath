import Foundation

/// Applies an edit or a deletion to one occurrence, following the "Repeating events" rules in
/// docs/ARCHITECTURE.md.
///
/// For a repeating event the user picks a scope: this occurrence only, or this and all later ones.
/// Non-repeating events, including detached ones, are simply replaced or removed whatever the scope.
/// Dates are the occurrence's original day (`Occurrence.date`), and "the first occurrence" is the
/// series' start date.
public enum SeriesEditing {
    public enum Scope: Hashable, Sendable {
        case thisEvent, allFutureEvents
    }

    /// Replaces `occurrence` with `edited`.
    ///
    /// `edited` is the event as the editor left it: its `timing` is the occurrence's (possibly changed)
    /// timing, and `title`, `subjectID`, `location`, `notes`, `alert` and `recurrence` are what the
    /// occurrence should have from now on. Its `id`, `createdAt`, `excludedDates` and `detachedFrom` are
    /// managed here and ignored.
    ///
    /// - Non-repeating or detached event: replaced in place, keeping its `id`.
    /// - `thisEvent` on a series: the date is added to the series' `excludedDates`, and a new
    ///   non-repeating event with `detachedFrom = (series, date)` takes its place.
    /// - `allFutureEvents` on a series' first occurrence: the whole series is edited in place. If that
    ///   moves it to another day, its excluded dates and its detached events' links move along.
    /// - `allFutureEvents` on a later occurrence: the series ends the day before (`until = date - 1`) and
    ///   a new series starts with `edited`. Excluded dates and detached events from `date` on move to
    ///   the new series (shifted along if the edit moved the occurrence to another day); if `edited`
    ///   doesn't repeat, those detached events become ordinary events. A series left with no
    ///   occurrences is removed.
    ///
    /// Changed events get `modifiedAt = now`; new ones also `createdAt = now`. Replacing an event in
    /// place with an identical copy changes nothing. An occurrence of an event that is no longer in the
    /// library is ignored.
    public static func update(
        _ occurrence: Occurrence,
        with edited: Event,
        scope: Scope,
        in library: inout CalendarDocument,
        now: Date
    ) {
        guard let index = library.events.firstIndex(where: { $0.id == occurrence.event.id }) else { return }
        let stored = library.events[index]
        let stamp = now.roundedToSecond
        guard let rule = stored.recurrence else {
            replace(at: index, with: edited, in: &library, stamp: stamp)
            return
        }
        switch scope {
        case .thisEvent:
            detach(occurrence.date, ofSeriesAt: index, replacement: edited, in: &library, stamp: stamp)
        case .allFutureEvents where occurrence.date <= stored.timing.startDate:
            replace(at: index, with: edited, in: &library, stamp: stamp)
        case .allFutureEvents:
            split(seriesAt: index, rule: rule, from: occurrence.date, with: edited, in: &library, stamp: stamp)
        }
    }

    /// Deletes `occurrence`.
    ///
    /// - Non-repeating or detached event: removed (a detached event's date stays excluded from its
    ///   series, so the original occurrence doesn't come back).
    /// - `thisEvent` on a series: the date is added to `excludedDates`.
    /// - `allFutureEvents` on a series' first occurrence: the series and all its detached events are
    ///   removed.
    /// - `allFutureEvents` on a later occurrence: the series ends the day before, and its detached
    ///   events from that date on are removed.
    ///
    /// A series left with no occurrences is removed. `modifiedAt` is left alone (there is no clock
    /// here); the caller saves the library anyway.
    public static func delete(_ occurrence: Occurrence, scope: Scope, from library: inout CalendarDocument) {
        guard let index = library.events.firstIndex(where: { $0.id == occurrence.event.id }) else { return }
        let stored = library.events[index]
        guard let rule = stored.recurrence else {
            library.events.remove(at: index)
            return
        }
        let seriesID = stored.id
        let date = occurrence.date
        switch scope {
        case .thisEvent:
            library.events[index].excludedDates.insert(date)
        case .allFutureEvents where date <= stored.timing.startDate:
            library.events.removeAll { $0.id == seriesID || $0.detachedFrom?.seriesID == seriesID }
            return
        case .allFutureEvents:
            library.events[index].recurrence = endingRule(rule, before: date)
            library.events[index].excludedDates = stored.excludedDates.filter { $0 < date }
            library.events.removeAll { event in
                guard let link = event.detachedFrom else { return false }
                return link.seriesID == seriesID && link.date >= date
            }
        }
        removeSeriesIfEmpty(id: seriesID, in: &library)
    }

    // MARK: - Steps

    /// Replaces the event at `index` with `edited`, keeping its identity.
    private static func replace(at index: Int, with edited: Event, in library: inout CalendarDocument, stamp: Date) {
        let stored = library.events[index]
        var replacement = edited
        replacement.id = stored.id
        replacement.timing = edited.timing.roundedToSeconds
        replacement.createdAt = stored.createdAt
        replacement.modifiedAt = stored.modifiedAt
        if replacement.recurrence == nil {
            // Exclusions mean nothing without a rule; a detached event stays linked to its series.
            replacement.excludedDates = []
            replacement.detachedFrom = stored.detachedFrom
        } else {
            replacement.excludedDates = stored.excludedDates
            replacement.detachedFrom = nil
        }
        // A whole series moved to another day ("lectures are on Wednesday now") takes its deleted and
        // detached dates along, so they don't come back on the new day.
        let oldStart = stored.timing.startDate
        let newStart = replacement.timing.startDate
        let movedRule = (replacement.recurrence != nil && oldStart != newStart) ? stored.recurrence : nil
        if let rule = movedRule {
            var moved: Set<CalendarDate> = []
            for excluded in stored.excludedDates {
                guard let day = movedSeriesDay(excluded, rule: rule, from: oldStart, to: newStart) else { continue }
                moved.insert(day)
            }
            replacement.excludedDates = moved
        }
        guard replacement != stored else { return }
        replacement.modifiedAt = stamp
        library.events[index] = replacement
        guard let rule = movedRule else { return }
        for position in library.events.indices {
            guard let link = library.events[position].detachedFrom, link.seriesID == stored.id else { continue }
            let day = movedSeriesDay(link.date, rule: rule, from: oldStart, to: newStart) ?? link.date
            library.events[position].detachedFrom = SeriesOccurrence(seriesID: stored.id, date: day)
            library.events[position].modifiedAt = stamp
        }
    }

    /// "Edit this event only" on a series: excludes `date` and adds a detached replacement.
    private static func detach(
        _ date: CalendarDate,
        ofSeriesAt index: Int,
        replacement edited: Event,
        in library: inout CalendarDocument,
        stamp: Date
    ) {
        let seriesID = library.events[index].id
        library.events[index].excludedDates.insert(date)
        library.events[index].modifiedAt = stamp
        let detached = Event(
            title: edited.title,
            timing: edited.timing,
            subjectID: edited.subjectID,
            location: edited.location,
            notes: edited.notes,
            alert: edited.alert,
            detachedFrom: SeriesOccurrence(seriesID: seriesID, date: date),
            createdAt: stamp,
            modifiedAt: stamp)
        library.events.append(detached)
        removeSeriesIfEmpty(id: seriesID, in: &library)
    }

    /// "Edit all future events" from a later occurrence: ends the series the day before `date` and
    /// starts a new one with `edited`.
    private static func split(
        seriesAt index: Int,
        rule: RecurrenceRule,
        from date: CalendarDate,
        with edited: Event,
        in library: inout CalendarDocument,
        stamp: Date
    ) {
        let stored = library.events[index]
        var ended = stored
        ended.recurrence = endingRule(rule, before: date)
        ended.excludedDates = stored.excludedDates.filter { $0 < date }
        ended.modifiedAt = stamp
        library.events[index] = ended

        // Dates excluded from the old series stay excluded in the new one, and detached events from the
        // split on are linked to it. When the edit moved the occurrence to another day ("from now on,
        // lectures are on Wednesday"), their original dates move along, so a deleted or detached
        // occurrence doesn't come back on the new day.
        let newStart = edited.timing.startDate
        var carriedExclusions: Set<CalendarDate> = []
        if edited.recurrence != nil {
            for excluded in stored.excludedDates where excluded >= date {
                guard let moved = movedSeriesDay(excluded, rule: rule, from: date, to: newStart) else { continue }
                carriedExclusions.insert(moved)
            }
        }
        let continuation = Event(
            title: edited.title,
            timing: edited.timing,
            subjectID: edited.subjectID,
            location: edited.location,
            notes: edited.notes,
            alert: edited.alert,
            recurrence: edited.recurrence,
            excludedDates: carriedExclusions,
            createdAt: stamp,
            modifiedAt: stamp)
        for position in library.events.indices {
            guard let link = library.events[position].detachedFrom else { continue }
            guard link.seriesID == stored.id, link.date >= date else { continue }
            if continuation.recurrence == nil {
                // There is no new series to belong to: the detached event becomes an ordinary event.
                library.events[position].detachedFrom = nil
            } else {
                let moved = movedSeriesDay(link.date, rule: rule, from: date, to: newStart) ?? link.date
                library.events[position].detachedFrom = SeriesOccurrence(seriesID: continuation.id, date: moved)
            }
            library.events[position].modifiedAt = stamp
        }
        library.events.append(continuation)
        removeSeriesIfEmpty(id: stored.id, in: &library)
    }

    /// Where an original series day on or after `date` lands when the series is split at `date` and the
    /// new series starts on `newStart`: the same number of days later for daily and weekly rules, the
    /// same number of months later (on `newStart`'s day of the month) for monthly ones. Nil when that
    /// month doesn't have the day, so the new series has no occurrence there.
    private static func movedSeriesDay(
        _ day: CalendarDate,
        rule: RecurrenceRule,
        from date: CalendarDate,
        to newStart: CalendarDate
    ) -> CalendarDate? {
        guard newStart != date else { return day }
        switch rule.frequency {
        case .daily, .weekly:
            return day.adding(days: date.days(to: newStart))
        case .monthly:
            let dayMonth = OccurrenceDayMath.monthIndex(year: day.year, month: day.month)
            let splitMonth = OccurrenceDayMath.monthIndex(year: date.year, month: date.month)
            let newMonth = OccurrenceDayMath.monthIndex(year: newStart.year, month: newStart.month)
            let index = newMonth + dayMonth - splitMonth
            let (year, month) = OccurrenceDayMath.yearAndMonth(ofIndex: index)
            let moved = CalendarDate(year: year, month: month, day: newStart.day)
            return moved.isValid ? moved : nil
        }
    }

    /// `rule`, ending on the day before `date` (or earlier, if it already did).
    private static func endingRule(_ rule: RecurrenceRule, before date: CalendarDate) -> RecurrenceRule {
        let dayBefore = date.adding(days: -1)
        var ended = rule
        ended.until = min(rule.until ?? dayBefore, dayBefore)
        return ended
    }

    /// Removes the repeating event `id` if none of its dates is left.
    private static func removeSeriesIfEmpty(id: UUID, in library: inout CalendarDocument) {
        guard let index = library.events.firstIndex(where: { $0.id == id }) else { return }
        let event = library.events[index]
        guard event.recurrence != nil, !OccurrenceDayMath.seriesHasOccurrences(event) else { return }
        library.events.remove(at: index)
    }
}
