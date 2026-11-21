import ElenathCore
import SwiftUI

/// One day of the Month view: the day number top right ("1 Oct" on the first of a month, out-of-month
/// days in `TextTertiary`, today in an amber circle), then up to 3 events and "N more".
///
/// Timed events are rows (subject dot, title, start time); all-day events are tinted bars. Clicking the
/// cell's empty space selects the day and a double-click starts a new event that day; events select and
/// open like everywhere else in the calendar (`eventInteraction`).
struct MonthCellView: View {
    @Environment(CalendarModel.self) private var model
    let day: CalendarDate
    let column: Int
    let isInMonth: Bool
    let entries: [MonthCellEntry]
    let height: CGFloat
    let onBackgroundClick: () -> Void
    @State private var popover: MonthCellPopover? = nil

    var body: some View {
        let shownCount = MonthCellMetrics.visibleCount(entryCount: entries.count, height: height)
        let shown = Array(entries.prefix(shownCount))
        let hidden = Array(entries.dropFirst(shownCount))
        let arrowEdge: Edge = column < 4 ? .trailing : .leading
        VStack(alignment: .leading, spacing: MonthCellMetrics.rowSpacing) {
            MonthDayNumber(day: day, isInMonth: isInMonth)
                .frame(maxWidth: .infinity, alignment: .trailing)
            ForEach(shown) { entry in
                MonthEventRow(entry: entry, arrowEdge: arrowEdge)
            }
            if !hidden.isEmpty {
                MonthMoreButton(day: day, count: hidden.count)
            }
        }
        .padding(MonthCellMetrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .frame(height: height)
        .clipped()
        .background {
            if day == model.selectedDate {
                Color.controlFill
            }
        }
        .background(Color.backgroundWindow)
        .overlay(alignment: .trailing) {
            if column < 6 {
                Rectangle()
                    .fill(Color.separatorLine)
                    .frame(width: 1)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.separatorLine)
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            handleClick()
        }
        .popover(item: $popover, arrowEdge: arrowEdge) { item in
            popoverContent(item)
        }
        .onAppear {
            openPendingEditor(hidden: hidden)
        }
        .onChange(of: model.pendingEditorOccurrenceID) {
            openPendingEditor(hidden: hidden)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spokenLabel)
        .accessibilityAction(named: Text("New Event")) {
            startDraft()
        }
    }

    @ViewBuilder private func popoverContent(_ item: MonthCellPopover) -> some View {
        switch item {
        case .newEvent(let event):
            EventEditorView(mode: .new(event), onClose: { popover = nil })
        case .edit(let occurrence):
            EventEditorView(mode: .edit(occurrence), onClose: { popover = nil })
        }
    }

    /// "Tuesday, 6 October", with ", Today" on today.
    private var spokenLabel: String {
        let date = EventFormatting.longDate(day, timeZone: model.timeZone, includeYear: day.year != model.today.year)
        return day == model.today ? EventFormatting.spokenJoined([date, String(localized: "Today")]) : date
    }

    /// A click selects an in-month day. Days of the neighboring months aren't selected: that would switch
    /// the grid to their month under the pointer, and the second click of a double-click would then land
    /// on another day.
    private func handleClick() {
        onBackgroundClick()
        model.selectedOccurrenceID = nil
        if CalendarClick.isDoubleClick() {
            startDraft()
        } else if isInMonth {
            model.show(day, span: nil)
        }
    }

    private func startDraft() {
        guard !model.isReadOnly else { return }
        popover = .newEvent(model.newEvent(on: day, startMinute: nil))
    }

    /// Opens Quick Add's editor for an event behind "N more" whose first cell on the grid is this one.
    private func openPendingEditor(hidden: [MonthCellEntry]) {
        guard let pending = model.pendingEditorOccurrenceID,
            let entry = hidden.first(where: { $0.isFirstOnGrid && $0.occurrence.id == pending })
        else { return }
        model.selectedOccurrenceID = entry.occurrence.id
        let item = MonthCellPopover.edit(entry.occurrence)
        Task { @MainActor in
            guard model.pendingEditorOccurrenceID == pending else { return }
            model.pendingEditorOccurrenceID = nil
            popover = item
        }
    }
}

/// What a month cell shows in its own popover: the editor of a new event that day (double-click), or
/// Quick Add's editor for an event hidden behind "N more".
private enum MonthCellPopover: Identifiable {
    case newEvent(Event)
    case edit(Occurrence)

    var id: UUID {
        switch self {
        case .newEvent(let event): return event.id
        case .edit(let occurrence): return occurrence.event.id
        }
    }
}

/// Sizes inside a month cell.
private enum MonthCellMetrics {
    static let padding: CGFloat = 4
    static let numberHeight: CGFloat = 20
    static let rowHeight: CGFloat = 17
    static let rowSpacing: CGFloat = 1
    static let maxEvents = 3

    /// How many events a cell `height` tall shows: all of them when they fit (3 at most), otherwise as
    /// many as fit above the "N more" line.
    static func visibleCount(entryCount: Int, height: CGFloat) -> Int {
        let available = height - 2 * padding - numberHeight
        let fit = max(0, Int((available / (rowHeight + rowSpacing)).rounded(.down)))
        if entryCount <= min(maxEvents, fit) {
            return entryCount
        }
        return max(0, min(maxEvents, fit - 1))
    }
}

/// The day number, top right. "1 Oct" on the first of a month; out-of-month days in `TextTertiary`;
/// today bold in `TextOnAccent` on an amber circle.
private struct MonthDayNumber: View {
    @Environment(CalendarModel.self) private var model
    let day: CalendarDate
    let isInMonth: Bool

    var body: some View {
        let isToday = day == model.today
        let weight: Font.Weight = isToday ? .bold : .medium
        Text(day.day == 1 ? CalendarGridLabels.dayAndShortMonth(day) : day.day.formatted())
            .font(.system(size: 12, weight: weight))
            .monospacedDigit()
            .foregroundStyle(numberColor(isToday: isToday))
            .lineLimit(1)
            .padding(.horizontal, 4)
            .frame(minWidth: MonthCellMetrics.numberHeight, minHeight: MonthCellMetrics.numberHeight)
            .background {
                if isToday {
                    Capsule()
                        .fill(Color.accentColor)
                }
            }
            .accessibilityHidden(true)
    }

    private func numberColor(isToday: Bool) -> Color {
        if isToday { return Color.textOnAccent }
        return isInMonth ? Color.textPrimary : Color.textTertiary
    }
}

/// "N more" in `TextTertiary`: shows the day in Day view.
private struct MonthMoreButton: View {
    @Environment(CalendarModel.self) private var model
    let day: CalendarDate
    let count: Int

    var body: some View {
        Button {
            model.show(day, span: .day)
        } label: {
            Text("\(count) more")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.textTertiary)
                .lineLimit(1)
                .padding(.horizontal, 4)
                .frame(height: MonthCellMetrics.rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text("Show in Day View"))
    }
}

/// One event in a month cell: a row for a timed event, a tinted bar for an all-day one.
private struct MonthEventRow: View {
    @Environment(CalendarModel.self) private var model
    @Environment(\.colorSchemeContrast) private var contrast
    let entry: MonthCellEntry
    let arrowEdge: Edge

    var body: some View {
        let occurrence = entry.occurrence
        let isSelected = model.selectedOccurrenceID == occurrence.id
        content(isSelected: isSelected)
            .frame(height: MonthCellMetrics.rowHeight)
            .opacity(CalendarEventStyle.opacity(for: occurrence, now: model.now, contrast: contrast))
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(EventFormatting.accessibilityLabel(occurrence, timeZone: model.timeZone))
            .accessibilityAddTraits(CalendarEventStyle.traits(isSelected: isSelected))
            .eventInteraction(occurrence: occurrence, arrowEdge: arrowEdge, handlesPendingEditor: entry.isFirstOnGrid)
    }

    @ViewBuilder private func content(isSelected: Bool) -> some View {
        let occurrence = entry.occurrence
        let subject = model.subject(for: occurrence.event)
        let showsTime = entry.startsOnDay
        if occurrence.isAllDay {
            MonthAllDayBar(occurrence: occurrence, subject: subject, isSelected: isSelected)
        } else {
            MonthTimedRow(occurrence: occurrence, subject: subject, isSelected: isSelected, showsTime: showsTime)
        }
    }
}

/// A timed event in a month cell: subject dot, title (truncated with "…") and, on its first day, the
/// start time right-aligned in `TextSecondary`. Selected: an `AccentSoft` row with the amber ring.
private struct MonthTimedRow: View {
    @Environment(CalendarModel.self) private var model
    let occurrence: Occurrence
    let subject: Subject?
    let isSelected: Bool
    let showsTime: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        HStack(spacing: 5) {
            SubjectDot(subject: subject, size: 7)
            Text(EventFormatting.displayTitle(occurrence.event))
                .font(.system(size: 12))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 2)
            if showsTime {
                Text(EventFormatting.time(occurrence.start, timeZone: model.timeZone))
                    .font(Typography.eventTime)
                    .monospacedDigit()
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 4)
        .frame(maxHeight: .infinity)
        .background {
            shape.fill(isSelected ? Color.accentSoft : Color.clear)
        }
        .overlay {
            if isSelected {
                shape.strokeBorder(Color.accentColor, lineWidth: Metrics.Glow.selectionRing)
            }
        }
    }
}

/// An all-day event in a month cell: a bar in the subject fill with the title in the subject's color.
private struct MonthAllDayBar: View {
    @Environment(\.colorScheme) private var colorScheme
    let occurrence: Occurrence
    let subject: Subject?
    let isSelected: Bool

    var body: some View {
        Text(EventFormatting.displayTitle(occurrence.event))
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(SubjectStyle.text(for: subject, scheme: colorScheme))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                EventShapeBackground(subject: subject, isSelected: isSelected, cornerRadius: 4)
            }
    }
}
