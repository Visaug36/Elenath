import ElenathCore
import SwiftUI

/// Where the all-day bars of the Day and Week views go: one row per set of overlapping events, each bar
/// spanning its days. With `maxRows`, the rows past it collapse into a last row of "N more" labels.
struct AllDayStripLayout {
    struct Bar: Identifiable {
        var occurrence: Occurrence
        var firstColumn: Int
        var lastColumn: Int
        var row: Int

        var id: Occurrence.ID { occurrence.id }

        func frame(columnWidth: CGFloat) -> CGRect {
            AllDayStripLayout.frame(firstColumn...lastColumn, row: row, columnWidth: columnWidth)
        }
    }

    /// The "N more" label of a day whose all-day events didn't all fit.
    struct Overflow: Identifiable {
        var column: Int
        var day: CalendarDate
        var count: Int
        /// The hidden events that start in this column, so the label can open Quick Add's editor for them.
        var startingHere: [Occurrence]

        var id: Int { column }

        func frame(row: Int, columnWidth: CGFloat) -> CGRect {
            AllDayStripLayout.frame(column...column, row: row, columnWidth: columnWidth)
        }
    }

    private(set) var bars: [Bar] = []
    private(set) var overflow: [Overflow] = []
    /// The rows drawn, the "N more" row included.
    private(set) var rowCount = 0

    /// Lays out the all-day occurrences among `occurrences` over `days`, which must be consecutive.
    init(days: [CalendarDate], occurrences: [Occurrence], maxRows: Int?) {
        guard let firstDay = days.first, let lastDay = days.last else { return }
        var columns: [CalendarDate: Int] = [:]
        for (column, day) in days.enumerated() {
            columns[day] = column
        }
        var placed: [Bar] = []
        for occurrence in occurrences where occurrence.isAllDay {
            let first = occurrence.date
            let last = CalendarGridDays.lastDay(ofAllDay: occurrence)
            guard first <= lastDay, last >= firstDay else { continue }
            let firstColumn = first < firstDay ? 0 : (columns[first] ?? 0)
            let lastColumn = max(firstColumn, last > lastDay ? days.count - 1 : (columns[last] ?? days.count - 1))
            placed.append(Bar(occurrence: occurrence, firstColumn: firstColumn, lastColumn: lastColumn, row: 0))
        }
        placed.sort(by: Self.drawingOrder)
        var rowEnds: [Int] = []
        for index in placed.indices {
            let bar = placed[index]
            if let row = rowEnds.firstIndex(where: { $0 < bar.firstColumn }) {
                placed[index].row = row
                rowEnds[row] = bar.lastColumn
            } else {
                placed[index].row = rowEnds.count
                rowEnds.append(bar.lastColumn)
            }
        }
        guard let maxRows, maxRows > 1, rowEnds.count > maxRows else {
            bars = placed
            rowCount = rowEnds.count
            return
        }
        let shownRows = maxRows - 1
        bars = placed.filter { $0.row < shownRows }
        let hidden = placed.filter { $0.row >= shownRows }
        for column in days.indices {
            let covering = hidden.filter { $0.firstColumn <= column && column <= $0.lastColumn }
            guard !covering.isEmpty else { continue }
            let starting = covering.filter { $0.firstColumn == column }.map(\.occurrence)
            let label = Overflow(column: column, day: days[column], count: covering.count, startingHere: starting)
            overflow.append(label)
        }
        rowCount = maxRows
    }

    /// The strip's height: its rows plus a little padding, or 0 when there are no all-day events.
    var height: CGFloat {
        guard rowCount > 0 else { return 0 }
        return CGFloat(rowCount) * TimeGridGeometry.allDayRowHeight + 2 * TimeGridGeometry.allDayPadding
    }

    /// Where something spanning `columns` in `row` goes, leaving 2 pt free at each end.
    static func frame(_ columns: ClosedRange<Int>, row: Int, columnWidth: CGFloat) -> CGRect {
        let x = TimeGridGeometry.gutterWidth + CGFloat(columns.lowerBound) * columnWidth + 2
        let width = CGFloat(columns.count) * columnWidth - 4
        let rowTop = TimeGridGeometry.allDayPadding + CGFloat(row) * TimeGridGeometry.allDayRowHeight
        let y = rowTop + (TimeGridGeometry.allDayRowHeight - TimeGridGeometry.allDayBarHeight) / 2
        return CGRect(x: x, y: y, width: max(0, width), height: TimeGridGeometry.allDayBarHeight)
    }

    /// Earlier first; on the same first day, longer first; then by title and ID, so rows never swap.
    private static func drawingOrder(_ lhs: Bar, _ rhs: Bar) -> Bool {
        if lhs.firstColumn != rhs.firstColumn { return lhs.firstColumn < rhs.firstColumn }
        let lhsLength = lhs.lastColumn - lhs.firstColumn
        let rhsLength = rhs.lastColumn - rhs.firstColumn
        if lhsLength != rhsLength { return lhsLength > rhsLength }
        if lhs.occurrence.event.title != rhs.occurrence.event.title {
            return lhs.occurrence.event.title < rhs.occurrence.event.title
        }
        return lhs.occurrence.event.id.uuidString < rhs.occurrence.event.id.uuidString
    }
}

/// The all-day strip under the day headers: an "all-day" label in the gutter, the day separators, and
/// the bars tinted with their subject.
struct AllDayStripView: View {
    let layout: AllDayStripLayout
    let days: [CalendarDate]

    var body: some View {
        GeometryReader { proxy in
            let columnWidth = TimeGridGeometry.columnWidth(totalWidth: proxy.size.width, dayCount: days.count)
            ZStack(alignment: .topLeading) {
                AllDayStripSeparators(size: proxy.size, dayCount: days.count)
                AllDayStripLabel()
                ForEach(layout.bars) { bar in
                    let frame = bar.frame(columnWidth: columnWidth)
                    AllDayBarView(occurrence: bar.occurrence)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }
                ForEach(layout.overflow) { overflow in
                    let frame = overflow.frame(row: layout.rowCount - 1, columnWidth: columnWidth)
                    AllDayOverflowButton(overflow: overflow)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .frame(height: layout.height)
    }
}

/// The day separators continued through the strip.
private struct AllDayStripSeparators: View {
    let size: CGSize
    let dayCount: Int

    var body: some View {
        Path { path in
            let columnWidth = TimeGridGeometry.columnWidth(totalWidth: size.width, dayCount: dayCount)
            for column in 0..<dayCount {
                let x = TimeGridGeometry.gutterWidth + CGFloat(column) * columnWidth
                path.addRect(CGRect(x: x, y: 0, width: 1, height: size.height))
            }
        }
        .fill(Color.separatorLine)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// "all-day" in the gutter, beside the first row.
private struct AllDayStripLabel: View {
    var body: some View {
        let width = TimeGridGeometry.gutterWidth - 8
        let y = TimeGridGeometry.allDayPadding + TimeGridGeometry.allDayRowHeight / 2
        Text("all-day")
            .font(Typography.eventTime)
            .foregroundStyle(Color.textTertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: width, alignment: .trailing)
            .position(x: width / 2, y: y)
            .accessibilityHidden(true)
    }
}

/// One all-day event in the strip: a tinted bar with its title. Its popovers open below it.
private struct AllDayBarView: View {
    @Environment(CalendarModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    let occurrence: Occurrence

    var body: some View {
        let subject = model.subject(for: occurrence.event)
        let isSelected = model.selectedOccurrenceID == occurrence.id
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
            .opacity(CalendarEventStyle.opacity(for: occurrence, now: model.now, contrast: contrast))
            .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(EventFormatting.accessibilityLabel(occurrence, timeZone: model.timeZone))
            .accessibilityAddTraits(CalendarEventStyle.traits(isSelected: isSelected))
            .eventInteraction(occurrence: occurrence, arrowEdge: .bottom, handlesPendingEditor: true)
    }
}

/// "N more" on a day whose all-day events didn't all fit: shows the day in Day view, where every row is
/// drawn. It also opens Quick Add's editor for a hidden event that starts that day.
private struct AllDayOverflowButton: View {
    @Environment(CalendarModel.self) private var model
    let overflow: AllDayStripLayout.Overflow
    @State private var editing: Occurrence? = nil

    var body: some View {
        Button {
            model.show(overflow.day, span: .day)
        } label: {
            Text("\(overflow.count) more")
                .font(Typography.eventTime)
                .foregroundStyle(Color.textTertiary)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text("Show in Day View"))
        .popover(item: $editing, arrowEdge: .bottom) { occurrence in
            EventEditorView(mode: .edit(occurrence), onClose: { editing = nil })
        }
        .onAppear {
            openPendingEditor()
        }
        .onChange(of: model.pendingEditorOccurrenceID) {
            openPendingEditor()
        }
    }

    private func openPendingEditor() {
        guard let pending = model.pendingEditorOccurrenceID,
            let occurrence = overflow.startingHere.first(where: { $0.id == pending })
        else { return }
        model.selectedOccurrenceID = occurrence.id
        Task { @MainActor in
            guard model.pendingEditorOccurrenceID == pending else { return }
            model.pendingEditorOccurrenceID = nil
            editing = occurrence
        }
    }
}
