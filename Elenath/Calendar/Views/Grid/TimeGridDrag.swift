import ElenathCore
import SwiftUI

/// A new time for one occurrence of a timed event, from dragging its block or the ⌥-arrow keys, before it
/// is saved.
struct EventTimeChange: Equatable {
    enum Kind: Equatable {
        /// The whole event moves and keeps its length.
        case move
        /// Only the end changes.
        case resize
    }

    var occurrence: Occurrence
    var kind: Kind
    var start: Date
    var end: Date

    /// Whether the new time differs from the occurrence's.
    var changesTime: Bool { start != occurrence.start || end != occurrence.end }

    /// The occurrence's event with the new time, in the event's own time zone, as `CalendarModel.update` takes
    /// it.
    var edited: Event {
        var event = occurrence.event
        let zone = occurrence.event.timing.timeZone ?? .current
        event.timing = EventTiming.timed(start: start, end: end, timeZone: zone).roundedToSeconds
        return event
    }

    /// The occurrence at its new time, for showing it.
    var changedOccurrence: Occurrence {
        Occurrence(event: occurrence.event, date: occurrence.date, start: start, end: end)
    }
}

/// Where a dragged block would land, in grid terms: a day column and wall-clock minutes on that day.
struct TimeGridDragPreview: Equatable {
    var change: EventTimeChange
    var column: Int
    var startMinute: Int
    var endMinute: Int
}

/// What a block in the time grid needs to turn a drag into a new time: the grid's shared drag state, and
/// the block's day column among `dayCount` columns `columnWidth` wide.
struct TimeGridDragContext {
    let state: TimeGridDragState
    let day: CalendarDate
    let column: Int
    let dayCount: Int
    let columnWidth: CGFloat
}

/// The block being dragged in one time grid, where it would land, and a change waiting for "This Event
/// Only" / "All Future Events". The blocks write it; the preview reads `preview` and the blocks only
/// `activeID`, so moving the pointer redraws nothing but the preview.
@Observable @MainActor
final class TimeGridDragState {
    /// The occurrence being dragged or waiting for an answer; its block is dimmed meanwhile.
    private(set) var activeID: Occurrence.ID? = nil
    /// Where it would land.
    private(set) var preview: TimeGridDragPreview? = nil
    /// A change of a repeating event, waiting for the question to be answered.
    private(set) var pendingChange: EventTimeChange? = nil
    /// The occurrence a saved change turned the dragged one into, when that is a new one (another day, or
    /// a copy detached from its series): its block takes keyboard focus when it appears, so ⌥-arrow keys
    /// keep working on it.
    @ObservationIgnored private var focusRequest: (id: Occurrence.ID, time: ContinuousClock.Instant)? = nil

    /// For the question's `isPresented`: setting it to false (Esc, Cancel) drops the change.
    var isAskingScope: Bool {
        get { pendingChange != nil }
        set {
            if !newValue {
                cancel()
            }
        }
    }

    /// While dragging: shows where the block would land.
    func track(_ preview: TimeGridDragPreview) {
        let id = preview.change.occurrence.id
        if activeID != id {
            activeID = id
        }
        if self.preview != preview {
            self.preview = preview
        }
    }

    /// Saves a change: at once for an event that doesn't repeat, after the question for one that does
    /// (the preview stays until it is answered). A change that changes nothing, of an occurrence that
    /// changed meanwhile, or while the library can't be edited, is dropped.
    func propose(_ change: EventTimeChange, preview: TimeGridDragPreview?, model: CalendarModel) {
        let current = model.occurrence(id: change.occurrence.id)
        guard model.canEdit, change.changesTime, current == change.occurrence else {
            cancel()
            return
        }
        guard change.occurrence.event.repeats else {
            commit(change, scope: .thisEvent, model: model)
            return
        }
        activeID = change.occurrence.id
        self.preview = preview
        pendingChange = change
    }

    /// Saves `change` for `scope` (one "Move Event" Undo step) and selects the occurrence it became.
    func commit(_ change: EventTimeChange, scope: SeriesEditing.Scope, model: CalendarModel) {
        cancel()
        let previousEventIDs = Set(model.library.events.map(\.id))
        model.selectedOccurrenceID = change.occurrence.id
        model.update(change.occurrence, with: change.edited, scope: scope, undoAction: .moveEvent)
        guard let moved = Self.occurrenceID(after: change, previousEventIDs: previousEventIDs, model: model) else {
            return
        }
        model.selectedOccurrenceID = moved
        if moved != change.occurrence.id {
            focusRequest = (moved, ContinuousClock.now)
        }
    }

    /// Whether the block of `id` should take keyboard focus as it appears: once, right after a change made
    /// it the occurrence a dragged or ⌥-arrow-moved block became.
    func claimsFocus(_ id: Occurrence.ID) -> Bool {
        guard let request = focusRequest, request.id == id else { return false }
        focusRequest = nil
        return ContinuousClock.now - request.time < .seconds(2)
    }

    /// Drops the drag or the waiting change; the block stays where it was.
    func cancel() {
        if activeID != nil {
            activeID = nil
        }
        if preview != nil {
            preview = nil
        }
        if pendingChange != nil {
            pendingChange = nil
        }
    }

    /// The occurrence `change` turned into: a copy detached from its series or the new half of a split
    /// series (the event the update added), else the same event on its new first day; nil if neither
    /// exists.
    private static func occurrenceID(
        after change: EventTimeChange,
        previousEventIDs: Set<UUID>,
        model: CalendarModel
    ) -> Occurrence.ID? {
        if let added = model.library.events.first(where: { !previousEventIDs.contains($0.id) }) {
            return Occurrence.ID(eventID: added.id, date: added.timing.startDate)
        }
        let same = Occurrence.ID(eventID: change.occurrence.event.id, date: change.edited.timing.startDate)
        return model.occurrence(id: same) != nil ? same : nil
    }
}

/// Turns drags and arrow keys into new times. Moves go in whole days sideways (Week view) and 15-minute
/// steps up and down, onto the 15-minute grid; a drag of less than half a step keeps the time as it is.
/// Events stay at least 15 minutes long.
enum TimeGridDragMath {
    static let snapMinutes = 15
    static let minimumMinutes = 15

    /// Dragging the block of `item` by `translation`. The start lands on the 15-minute grid of the
    /// target day's wall clock; the event keeps its length.
    static func move(
        _ item: DayLayout.Item,
        by translation: CGSize,
        context: TimeGridDragContext,
        math: CalendarMath
    ) -> TimeGridDragPreview {
        let occurrence = item.occurrence
        let days = dayOffset(forWidth: translation.width, context: context)
        let targetDay = context.day.adding(days: days)
        let top = item.continuesBefore ? 0 : math.minutesOfDay(occurrence.start)
        let highest = TimeGridGeometry.minutesPerDay - snapMinutes
        let offset = snappedOffset(from: top, by: minutes(forHeight: translation.height), lowest: 0, highest: highest)
        let start: Date
        if item.continuesBefore || offset == 0 {
            // The same wall-clock time `days` later (for a segment of an event that began the day before,
            // moved by whole steps from there).
            let shifted = math.calendar.date(byAdding: .day, value: days, to: occurrence.start) ?? occurrence.start
            start = math.calendar.date(byAdding: .minute, value: offset, to: shifted) ?? shifted
        } else {
            start = instant(minute: top + offset, on: targetDay, math: math) ?? occurrence.start
        }
        let end = start.addingTimeInterval(occurrence.end.timeIntervalSince(occurrence.start))
        let change = EventTimeChange(occurrence: occurrence, kind: .move, start: start, end: end)
        return preview(of: change, column: context.column + days, day: targetDay, math: math)
    }

    /// Dragging the bottom edge of the block of `item` (the segment that holds the event's end) by
    /// `height`. The end lands on the 15-minute grid, at least 15 minutes after the start.
    static func resize(
        _ item: DayLayout.Item,
        by height: CGFloat,
        context: TimeGridDragContext,
        math: CalendarMath
    ) -> TimeGridDragPreview {
        let occurrence = item.occurrence
        let top = item.continuesBefore ? 0 : math.minutesOfDay(occurrence.start)
        let bottom = minute(of: occurrence.end, on: context.day, math: math)
        let lowest = min(top + minimumMinutes, TimeGridGeometry.minutesPerDay)
        let offset = snappedOffset(
            from: bottom, by: minutes(forHeight: height), lowest: lowest, highest: TimeGridGeometry.minutesPerDay)
        var end = occurrence.end
        if offset != 0, let moved = instant(minute: bottom + offset, on: context.day, math: math) {
            let shortest = occurrence.start.addingTimeInterval(TimeInterval(minimumMinutes * 60))
            end = max(moved, shortest)
        }
        let change = EventTimeChange(occurrence: occurrence, kind: .resize, start: occurrence.start, end: end)
        return preview(of: change, column: context.column, day: context.day, math: math)
    }

    /// ⌥↑ / ⌥↓: the whole event `minutes` later (earlier when negative).
    static func moved(_ occurrence: Occurrence, byMinutes minutes: Int) -> EventTimeChange {
        let offset = TimeInterval(minutes * 60)
        return EventTimeChange(
            occurrence: occurrence, kind: .move, start: occurrence.start.addingTimeInterval(offset),
            end: occurrence.end.addingTimeInterval(offset))
    }

    /// ⌥⇧↑ / ⌥⇧↓: the end `minutes` later (earlier when negative); nil when that would leave the event
    /// shorter than 15 minutes.
    static func endMoved(_ occurrence: Occurrence, byMinutes minutes: Int) -> EventTimeChange? {
        let end = occurrence.end.addingTimeInterval(TimeInterval(minutes * 60))
        guard end.timeIntervalSince(occurrence.start) >= TimeInterval(minimumMinutes * 60) else { return nil }
        return EventTimeChange(occurrence: occurrence, kind: .resize, start: occurrence.start, end: end)
    }

    /// Where `change` is drawn in `column`, the column of `day`.
    static func preview(
        of change: EventTimeChange,
        column: Int,
        day: CalendarDate,
        math: CalendarMath
    ) -> TimeGridDragPreview {
        let start = min(minute(of: change.start, on: day, math: math), TimeGridGeometry.minutesPerDay - snapMinutes)
        let shortestEnd = min(start + TimeGridGeometry.minimumBlockMinutes, TimeGridGeometry.minutesPerDay)
        let end = max(minute(of: change.end, on: day, math: math), shortestEnd)
        return TimeGridDragPreview(change: change, column: column, startMinute: start, endMinute: end)
    }

    /// The wall-clock minute of `instant` on `day`: 0 before the day starts, 1440 once it is over.
    static func minute(of instant: Date, on day: CalendarDate, math: CalendarMath) -> Int {
        if instant <= day.start(in: math.timeZone) {
            return 0
        }
        if instant >= day.end(in: math.timeZone) {
            return TimeGridGeometry.minutesPerDay
        }
        return math.minutesOfDay(instant)
    }

    /// The instant of wall-clock `minute` (0…1440) on `day` in the display time zone; 1440 is the start of
    /// the next day. A time that doesn't exist that day (a DST gap) moves forward, as `Calendar` does.
    static func instant(minute: Int, on day: CalendarDate, math: CalendarMath) -> Date? {
        guard minute < TimeGridGeometry.minutesPerDay else { return day.end(in: math.timeZone) }
        let clamped = max(0, minute)
        let parts = DateComponents(
            year: day.year, month: day.month, day: day.day, hour: clamped / 60, minute: clamped % 60)
        return math.calendar.date(from: parts)
    }

    /// How many minutes a drag of `delta` minutes moves `minute`: none for less than half a step, else
    /// onto the 15-minute grid, kept within `lowest`…`highest`.
    static func snappedOffset(from minute: Int, by delta: Double, lowest: Int, highest: Int) -> Int {
        guard abs(delta) >= Double(snapMinutes) / 2 else { return 0 }
        let steps = ((Double(minute) + delta) / Double(snapMinutes)).rounded()
        let snapped = Int(steps) * snapMinutes
        return min(max(snapped, lowest), max(lowest, highest)) - minute
    }

    /// The minutes a vertical drag of `height` points covers.
    static func minutes(forHeight height: CGFloat) -> Double {
        Double(height / TimeGridGeometry.hourHeight * 60)
    }

    /// Whole days a sideways drag of `width` points covers in Week view, kept within the visible week.
    static func dayOffset(forWidth width: CGFloat, context: TimeGridDragContext) -> Int {
        guard context.dayCount > 1, context.columnWidth > 0 else { return 0 }
        let offset = Int((width / context.columnWidth).rounded())
        return min(max(offset, -context.column), context.dayCount - 1 - context.column)
    }
}

/// A translucent copy of the dragged block where it would land, with its new times. It moves in steps with
/// the pointer, without animation, and never takes clicks.
struct TimeGridDragPreviewView: View {
    let state: TimeGridDragState
    let columnWidth: CGFloat

    var body: some View {
        if let preview = state.preview {
            let frame = Self.frame(for: preview, columnWidth: columnWidth)
            TimeGridDragGhost(change: preview.change, height: frame.height)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .allowsHitTesting(false)
                .transaction { transaction in
                    transaction.animation = nil
                }
                .accessibilityHidden(true)
        }
    }

    /// The full width of the target column, from the new start to the new end.
    static func frame(for preview: TimeGridDragPreview, columnWidth: CGFloat) -> CGRect {
        let gap = TimeGridGeometry.blockGap
        let x = TimeGridGeometry.gutterWidth + CGFloat(preview.column) * columnWidth + gap
        let width = max(0, columnWidth - gap - TimeGridGeometry.columnTrailingInset)
        let top = TimeGridGeometry.y(forMinute: preview.startMinute)
        let height = max(1, TimeGridGeometry.y(forMinute: preview.endMinute) - top - gap)
        return CGRect(x: x, y: top, width: width, height: height)
    }
}

/// The dragged event, drawn like its block with the selection ring, the new time range under the title.
private struct TimeGridDragGhost: View {
    @Environment(CalendarModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let change: EventTimeChange
    let height: CGFloat

    var body: some View {
        let subject = model.subject(for: change.occurrence.event)
        VStack(alignment: .leading, spacing: 1) {
            Text(EventFormatting.displayTitle(change.occurrence.event))
                .font(Typography.eventTitle)
                .foregroundStyle(SubjectStyle.text(for: subject, scheme: colorScheme))
                .lineLimit(1)
            if height >= 34 {
                Text(EventFormatting.timeRange(change.changedOccurrence, timeZone: model.timeZone))
                    .font(Typography.eventTime)
                    .monospacedDigit()
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, height < 34 ? 1 : 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            EventShapeBackground(subject: subject, isSelected: true)
        }
        .clipped()
        .opacity(0.8)
    }
}

/// "This Event Only" / "All Future Events" before a drag or ⌥-arrow change of a repeating event is saved.
/// Cancel or Esc puts the block back where it was.
struct TimeGridDragConfirmation: ViewModifier {
    @Environment(CalendarModel.self) private var model
    let state: TimeGridDragState

    func body(content: Content) -> some View {
        @Bindable var question = state
        let pending = state.pendingChange
        content.confirmationDialog(
            title(for: pending), isPresented: $question.isAskingScope, titleVisibility: .visible, presenting: pending
        ) { change in
            Button("This Event Only") {
                state.commit(change, scope: .thisEvent, model: model)
            }
            Button("All Future Events") {
                state.commit(change, scope: .allFutureEvents, model: model)
            }
            Button("Cancel", role: .cancel) {
                state.cancel()
            }
        } message: { _ in
            Text("This is a repeating event. Change only this event, or this and all future events?")
        }
    }

    private func title(for change: EventTimeChange?) -> Text {
        guard let change else { return Text(verbatim: "") }
        let title = EventFormatting.displayTitle(change.occurrence.event)
        switch change.kind {
        case .move:
            return Text("Move “\(title)”?")
        case .resize:
            return Text("Change the end of “\(title)”?")
        }
    }
}
