import ElenathCore
import SwiftUI

/// The scrolling part of the Day and Week views: the time gutter, the hour lines and day separators, one
/// column of event blocks per day, and the now indicator. No stars or glows here: the grid stays plain.
///
/// Blocks can be dragged to another time (and, in Week view, another day) or resized at their bottom edge;
/// a translucent preview shows where they would land (`TimeGridDragState`). A repeating event asks "This
/// Event Only" / "All Future Events" before it moves, and Cancel puts it back.
struct TimeGridView: View {
    let days: [CalendarDate]
    let onBackgroundClick: () -> Void
    @State private var dragState = TimeGridDragState()

    var body: some View {
        GeometryReader { proxy in
            let columnWidth = TimeGridGeometry.columnWidth(totalWidth: proxy.size.width, dayCount: days.count)
            ZStack(alignment: .topLeading) {
                TimeGridLines(size: proxy.size, dayCount: days.count)
                HStack(alignment: .top, spacing: 0) {
                    TimeGridHourGutter(days: days)
                    ForEach(Array(days.enumerated()), id: \.element) { column, day in
                        let context = TimeGridDragContext(
                            state: dragState, day: day, column: column, dayCount: days.count, columnWidth: columnWidth)
                        TimeGridDayColumn(
                            day: day, column: column, dayCount: days.count, width: columnWidth,
                            dragContext: context, onBackgroundClick: onBackgroundClick)
                    }
                }
                TimeGridDragPreviewView(state: dragState, columnWidth: columnWidth)
                TimeGridNowIndicator(days: days, columnWidth: columnWidth)
            }
        }
        .frame(height: TimeGridGeometry.gridHeight)
        .padding(.vertical, TimeGridGeometry.verticalInset)
        .modifier(TimeGridDragConfirmation(state: dragState))
        .onChange(of: days) {
            dragState.cancel()
        }
    }
}

/// The hour lines, with a short tick into the gutter, and the vertical day separators: one path of 1 pt
/// rectangles in `SeparatorLine`, so the lines stay crisp.
private struct TimeGridLines: View {
    let size: CGSize
    let dayCount: Int

    var body: some View {
        Path { path in
            let gutter = TimeGridGeometry.gutterWidth
            let tick: CGFloat = 6
            let columnWidth = TimeGridGeometry.columnWidth(totalWidth: size.width, dayCount: dayCount)
            for hour in 0...24 {
                let y = TimeGridGeometry.y(forHour: hour)
                path.addRect(CGRect(x: gutter - tick, y: y, width: max(0, size.width - gutter + tick), height: 1))
            }
            for column in 0..<dayCount {
                let x = gutter + CGFloat(column) * columnWidth
                path.addRect(CGRect(x: x, y: 0, width: 1, height: size.height))
            }
        }
        .fill(Color.separatorLine)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The hour labels, right-aligned in the gutter and centered on their lines, in `TextTertiary` with
/// tabular digits. A label the now pill would cover is left out.
private struct TimeGridHourGutter: View {
    @Environment(CalendarModel.self) private var model
    let days: [CalendarDate]

    var body: some View {
        let labels = CalendarGridLabels.hourLabels()
        let covered = coveredHour
        let labelWidth = TimeGridGeometry.gutterWidth - 8
        ZStack(alignment: .topLeading) {
            ForEach(0..<24, id: \.self) { hour in
                if hour != covered, labels.indices.contains(hour) {
                    Text(labels[hour])
                        .font(Typography.eventTime)
                        .monospacedDigit()
                        .foregroundStyle(Color.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(width: labelWidth, alignment: .trailing)
                        .position(x: labelWidth / 2, y: TimeGridGeometry.y(forHour: hour))
                }
            }
        }
        .frame(width: TimeGridGeometry.gutterWidth, height: TimeGridGeometry.gridHeight, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    /// The hour whose label is within 15 minutes of the now pill, while today is on screen.
    private var coveredHour: Int? {
        guard days.contains(model.today) else { return nil }
        let minute = model.math.minutesOfDay(model.now)
        let nearestHour = (minute + 30) / 60
        return abs(nearestHour * 60 - minute) < 15 ? nearestHour : nil
    }
}

/// One day of the time grid: its event blocks and the empty space around them. A click there clears the
/// selection; a double-click starts a new event at that time (rounded down to 15 minutes), with the
/// editor in a popover pointing at a placeholder block.
private struct TimeGridDayColumn: View {
    @Environment(CalendarModel.self) private var model
    let day: CalendarDate
    let column: Int
    let dayCount: Int
    let width: CGFloat
    let dragContext: TimeGridDragContext
    let onBackgroundClick: () -> Void
    @State private var draft: Event? = nil
    @State private var draftMinute = 9 * 60

    var body: some View {
        let occurrences = model.occurrences(on: day)
        let minimum = TimeGridGeometry.minimumBlockMinutes
        let items = DayLayout.layout(occurrences, on: day, timeZone: model.timeZone, minimumMinutes: minimum)
        let arrowEdge = TimeGridGeometry.popoverEdge(column: column, dayCount: dayCount)
        ZStack(alignment: .topLeading) {
            TimeGridDayBlocks(
                items: items, width: width, arrowEdge: arrowEdge, isFirstColumn: column == 0,
                dragContext: dragContext)
            newEventAnchor(arrowEdge: arrowEdge)
        }
        .frame(width: width, height: TimeGridGeometry.gridHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { location in
            handleClick(at: location)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(EventFormatting.longDate(day, timeZone: model.timeZone))
        .accessibilityAction(named: Text("New Event")) {
            startDraft(minute: 9 * 60)
        }
    }

    /// The placeholder block the new-event editor points at, invisible until a double-click starts a draft.
    private func newEventAnchor(arrowEdge: Edge) -> some View {
        let frame = TimeGridGeometry.draftFrame(minute: draftMinute, columnWidth: width)
        return TimeGridNewEventGhost(isVisible: draft != nil)
            .allowsHitTesting(false)
            .frame(width: frame.width, height: frame.height)
            .popover(item: $draft, arrowEdge: arrowEdge) { event in
                EventEditorView(mode: .new(event), onClose: { draft = nil })
            }
            .position(x: frame.midX, y: frame.midY)
    }

    private func handleClick(at location: CGPoint) {
        onBackgroundClick()
        model.selectedOccurrenceID = nil
        if CalendarClick.isDoubleClick() {
            startDraft(minute: TimeGridGeometry.snappedMinute(atY: location.y))
        }
    }

    private func startDraft(minute: Int) {
        guard !model.isReadOnly else { return }
        draftMinute = minute
        draft = model.newEvent(on: day, startMinute: minute)
    }
}

/// The blocks of one day, positioned from their `DayLayout` items. Kept apart from `TimeGridDayColumn`, so
/// a change of selection redraws the blocks without laying the day out again.
private struct TimeGridDayBlocks: View {
    @Environment(CalendarModel.self) private var model
    let items: [DayLayout.Item]
    let width: CGFloat
    let arrowEdge: Edge
    /// The first day on screen: its segments of events that began earlier open Quick Add's editor.
    let isFirstColumn: Bool
    let dragContext: TimeGridDragContext

    var body: some View {
        let selectedID = model.selectedOccurrenceID
        ForEach(items, id: \.occurrence.id) { item in
            let frame = TimeGridGeometry.blockFrame(for: item, columnWidth: width)
            let handlesPendingEditor = !item.continuesBefore || isFirstColumn
            EventBlockView(
                item: item, arrowEdge: arrowEdge, handlesPendingEditor: handlesPendingEditor,
                dragContext: dragContext
            )
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .zIndex(item.occurrence.id == selectedID ? 1 : 0)
        }
    }
}

/// A soft amber block marking where a new event goes while its editor is open.
private struct TimeGridNewEventGhost: View {
    let isVisible: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.eventBlock, style: .continuous)
        ZStack(alignment: .topLeading) {
            if isVisible {
                shape.fill(Color.accentSoft)
                shape.strokeBorder(Color.accentColor, lineWidth: Metrics.Glow.selectionRing)
                Text("New Event")
                    .font(Typography.eventTitle)
                    .foregroundStyle(Color.accentText)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
            }
        }
        .accessibilityHidden(true)
    }
}
