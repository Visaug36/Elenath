import ElenathCore
import SwiftUI

/// The Month view: a weekday header in the user's first-weekday order over the month's 5 or 6 weeks,
/// which fill the window. Each day shows up to 3 events, then "N more". ← / → step by month while the
/// calendar has keyboard focus, and Delete deletes the selected event (after asking).
struct MonthView: View {
    @Environment(CalendarModel.self) private var model
    @FocusState private var isFocused: Bool
    let month: CalendarDate

    var body: some View {
        let days = model.math.monthGrid(year: month.year, month: month.month)
        let occurrences = model.occurrences(in: days)
        let entries = MonthGridLayout.entries(days: days, occurrences: occurrences, calendar: model.math.calendar)
        VStack(spacing: 0) {
            MonthWeekdayHeader(weekdays: model.math.weekdayOrder())
            GeometryReader { proxy in
                MonthGrid(days: days, entries: entries, month: month, size: proxy.size) {
                    isFocused = true
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.backgroundWindow)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .calendarArrowKeys()
        .calendarDeleteCommand()
        .onAppear {
            focusUnlessSearching()
        }
        .onChange(of: month) {
            focusUnlessSearching()
        }
    }

    /// Takes keyboard focus for ← / →, unless the user is searching (the field keeps its focus then).
    private func focusUnlessSearching() {
        guard model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isFocused = true
    }
}

/// One event in a month cell.
struct MonthCellEntry: Identifiable {
    var occurrence: Occurrence
    /// This is the first cell of the grid the event appears in; only that one opens Quick Add's editor.
    var isFirstOnGrid: Bool
    /// The event starts on this cell's day, so a timed one shows its start time.
    var startsOnDay: Bool

    var id: Occurrence.ID { occurrence.id }
}

/// Sorts a month grid's occurrences into its day cells.
enum MonthGridLayout {
    /// The entries of each day of `days`, in the same order: every event that touches the day, all-day
    /// events first, then by start.
    static func entries(days: [CalendarDate], occurrences: [Occurrence], calendar: Calendar) -> [[MonthCellEntry]] {
        var cells = Array(repeating: [MonthCellEntry](), count: days.count)
        guard let firstDay = days.first, let lastDay = days.last else { return cells }
        var positions: [CalendarDate: Int] = [:]
        for (position, day) in days.enumerated() {
            positions[day] = position
        }
        for occurrence in occurrences {
            let covered = CalendarGridDays.coveredDays(occurrence, calendar: calendar)
            guard covered.lowerBound <= lastDay, covered.upperBound >= firstDay else { continue }
            let start = covered.lowerBound < firstDay ? 0 : (positions[covered.lowerBound] ?? 0)
            var position = start
            while position < days.count, days[position] <= covered.upperBound {
                let startsOnDay = days[position] == covered.lowerBound
                let entry = MonthCellEntry(
                    occurrence: occurrence, isFirstOnGrid: position == start, startsOnDay: startsOnDay)
                cells[position].append(entry)
                position += 1
            }
        }
        for position in cells.indices {
            let allDay = cells[position].filter { $0.occurrence.isAllDay }
            let timed = cells[position].filter { !$0.occurrence.isAllDay }
            cells[position] = allDay + timed
        }
        return cells
    }
}

/// "Mon … Sun" in `TextSecondary`, right-aligned over the day numbers.
private struct MonthWeekdayHeader: View {
    let weekdays: [Int]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(weekdays, id: \.self) { weekday in
                Text(CalendarGridLabels.shortWeekdaySymbol(weekday))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .padding(.trailing, 8)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(height: 28)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.separatorLine)
                .frame(height: 1)
        }
        .accessibilityHidden(true)
    }
}

/// The weeks of the month, in a 7-column grid whose rows share the height.
private struct MonthGrid: View {
    let days: [CalendarDate]
    let entries: [[MonthCellEntry]]
    let month: CalendarDate
    let size: CGSize
    let onBackgroundClick: () -> Void

    var body: some View {
        let rowCount = max(1, days.count / 7)
        let rowHeight = max(0, size.height / CGFloat(rowCount))
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(Array(days.enumerated()), id: \.element) { position, day in
                let isInMonth = day.year == month.year && day.month == month.month
                let cellEntries: [MonthCellEntry] = position < entries.count ? entries[position] : []
                MonthCellView(
                    day: day, column: position % 7, isInMonth: isInMonth, entries: cellEntries, height: rowHeight,
                    onBackgroundClick: onBackgroundClick)
            }
        }
    }
}
