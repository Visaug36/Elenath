import ElenathCore
import SwiftUI

/// The Day and Week views: one time grid for 1 or 7 days.
///
/// - A header row ("Mon 5", today in amber; the long date in Day view) and, when a visible day has
///   all-day events, the all-day strip. Both stay pinned while the hours scroll under them.
/// - 24 hour rows with the time gutter, the event blocks laid out by `DayLayout`, and the now line while
///   today is on screen. The grid opens at 08:00; with today on screen, an hour before now when that is
///   earlier, or six hours before now from 16:00. It scrolls there again whenever the days change.
/// - A Day view with nothing on it shows the "A quiet day." empty state instead of the grid.
/// - ← / → step by the span while the calendar has keyboard focus, and Delete deletes the selected event
///   (after asking). Blocks can be dragged to move them and resized at their bottom edge (`TimeGridView`).
struct DayWeekView: View {
    @Environment(CalendarModel.self) private var model
    @FocusState private var isFocused: Bool
    let days: [CalendarDate]

    var body: some View {
        content
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
            .onChange(of: days) {
                focusUnlessSearching()
            }
    }

    @ViewBuilder private var content: some View {
        if let day = emptyDay {
            GridEmptyDayView(day: day) {
                isFocused = true
            }
        } else {
            GridScrollView(days: days) {
                isFocused = true
            }
        }
    }

    /// The day of a Day view that has nothing on it.
    private var emptyDay: CalendarDate? {
        guard days.count == 1, let day = days.first, model.occurrences(on: day).isEmpty else { return nil }
        return day
    }

    /// Takes keyboard focus for ← / →, unless the user is searching (the field keeps its focus then).
    private func focusUnlessSearching() {
        guard model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isFocused = true
    }
}

/// The header and all-day strip, pinned over the scrolling time grid. Both live in the scroll view, so
/// their columns line up with the grid's even when the scroller takes up width.
private struct GridScrollView: View {
    @Environment(CalendarModel.self) private var model
    let days: [CalendarDate]
    let onBackgroundClick: () -> Void
    @State private var scrollRequest: TimeGridScrollRequest? = nil

    var body: some View {
        let maxRows: Int? = days.count > 1 ? TimeGridGeometry.maxAllDayRows : nil
        let allDay = AllDayStripLayout(days: days, occurrences: model.occurrences(in: days), maxRows: maxRows)
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    TimeGridView(days: days, onBackgroundClick: onBackgroundClick)
                } header: {
                    GridHeader(days: days, allDay: allDay)
                }
            }
            .background(alignment: .topLeading) {
                TimeGridScroller(request: scrollRequest)
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
            }
        }
        .onAppear {
            scrollToStart()
        }
        .onChange(of: days) {
            scrollToStart()
        }
        .onChange(of: model.pendingEditorOccurrenceID) { _, pending in
            if let hour = revealHour(for: pending) {
                scroll(toHour: hour)
            }
        }
    }

    /// An hour before the event whose editor Quick Add's ⌘↩ is about to open, so its popover points at a
    /// block on screen. Otherwise 08:00, the start of a student's day, unless today is on screen and now is
    /// earlier (then an hour before now) or late in the evening (then six hours before now).
    private func scrollToStart() {
        var hour = 8
        if let revealed = revealHour(for: model.pendingEditorOccurrenceID) {
            hour = revealed
        } else if days.contains(model.today) {
            let nowHour = model.math.minutesOfDay(model.now) / 60
            hour = nowHour < 16 ? max(0, min(8, nowHour - 1)) : nowHour - 6
        }
        scroll(toHour: hour)
    }

    /// Puts the hour's line just below the pinned header: the header and the grid's top inset sit above the
    /// grid in the scroll content, and stay on screen as the header is pinned.
    private func scroll(toHour hour: Int) {
        let serial = (scrollRequest?.serial ?? 0) + 1
        scrollRequest = TimeGridScrollRequest(offset: TimeGridGeometry.y(forHour: hour), serial: serial)
    }

    /// The hour to scroll to so a timed occurrence starting on one of these days is in view.
    private func revealHour(for id: Occurrence.ID?) -> Int? {
        guard let id, let occurrence = model.occurrence(id: id), !occurrence.isAllDay else { return nil }
        guard days.contains(CalendarDate(occurrence.start, in: model.timeZone)) else { return nil }
        return max(0, model.math.minutesOfDay(occurrence.start) / 60 - 1)
    }
}

/// The pinned top of the grid: the day header row, then the all-day strip when there is one.
private struct GridHeader: View {
    let days: [CalendarDate]
    let allDay: AllDayStripLayout

    var body: some View {
        VStack(spacing: 0) {
            GridHeaderRow(days: days)
            if allDay.rowCount > 0 {
                AllDayStripView(layout: allDay, days: days)
            }
        }
        .background(Color.backgroundWindow)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.separatorLine)
                .frame(height: 1)
        }
    }
}

/// The 56 pt header row: a cell per day in Week view, the long date in Day view.
private struct GridHeaderRow: View {
    let days: [CalendarDate]

    var body: some View {
        GeometryReader { proxy in
            let columnWidth = TimeGridGeometry.columnWidth(totalWidth: proxy.size.width, dayCount: days.count)
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: TimeGridGeometry.gutterWidth)
                if days.count == 1, let day = days.first {
                    GridDayTitle(day: day)
                        .padding(.leading, 12)
                        .frame(width: columnWidth, alignment: .leading)
                } else {
                    ForEach(days, id: \.self) { day in
                        GridHeaderCell(day: day)
                            .frame(width: columnWidth)
                    }
                }
            }
        }
        .frame(height: Metrics.weekHeaderHeight)
    }
}

/// "Mon 5": the short weekday in `TextSecondary` and the day number in `TextPrimary`; today has an amber
/// weekday and the number in an amber circle. Clicking it shows that day in Day view.
private struct GridHeaderCell: View {
    @Environment(CalendarModel.self) private var model
    let day: CalendarDate

    var body: some View {
        let isToday = day == model.today
        Button {
            model.show(day, span: .day)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(CalendarGridLabels.shortWeekday(day))
                    .font(.system(size: 13))
                    .foregroundStyle(isToday ? Color.accentText : Color.textSecondary)
                GridDayNumber(number: day.day, isToday: isToday)
            }
            .lineLimit(1)
            .padding(.leading, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text("Show in Day View"))
        .accessibilityLabel(spokenLabel(isToday: isToday))
    }

    private func spokenLabel(isToday: Bool) -> String {
        let date = EventFormatting.longDate(day, timeZone: model.timeZone, includeYear: day.year != model.today.year)
        return isToday ? EventFormatting.spokenJoined([date, String(localized: "Today")]) : date
    }
}

/// The day number of a header cell, in an amber circle on today.
private struct GridDayNumber: View {
    let number: Int
    let isToday: Bool

    var body: some View {
        Text(number.formatted())
            .font(.system(size: 17, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(isToday ? Color.textOnAccent : Color.textPrimary)
            .frame(minWidth: 28, minHeight: 28)
            .background {
                if isToday {
                    Circle()
                        .fill(Color.accentColor)
                }
            }
    }
}

/// The Day view's heading: "Tuesday, 6 October" in New York, with an amber "Today" on today.
private struct GridDayTitle: View {
    @Environment(CalendarModel.self) private var model
    let day: CalendarDate

    var body: some View {
        let title = EventFormatting.longDate(day, timeZone: model.timeZone, includeYear: day.year != model.today.year)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(Typography.dayHeader)
                .foregroundStyle(Color.textPrimary)
            if day == model.today {
                Text("Today")
                    .font(Typography.caption)
                    .foregroundStyle(Color.accentText)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A Day view with nothing planned: the day's heading and the "A quiet day." empty state on stars.
/// Double-clicking it starts a new event that day.
private struct GridEmptyDayView: View {
    @Environment(CalendarModel.self) private var model
    let day: CalendarDate
    let onBackgroundClick: () -> Void
    @State private var draft: Event? = nil
    @State private var anchor = CGPoint(x: 40, y: 40)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GridDayTitle(day: day)
                .padding(.leading, 20)
                .padding(.top, 16)
            EmptyStateView(
                illustration: .emptyDay,
                title: "A quiet day.",
                message: "Nothing planned. Press ⌘N to add something."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { location in
            handleClick(at: location)
        }
        .overlay(alignment: .topLeading) {
            newEventAnchor
        }
        .starryBackground(Color.backgroundWindow)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("New Event")) {
            startDraft(at: anchor)
        }
    }

    /// An invisible point at the double-click for the new-event editor to point at.
    private var newEventAnchor: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .popover(item: $draft, arrowEdge: .trailing) { event in
                EventEditorView(mode: .new(event), onClose: { draft = nil })
            }
            .position(anchor)
    }

    private func handleClick(at location: CGPoint) {
        onBackgroundClick()
        model.selectedOccurrenceID = nil
        if CalendarClick.isDoubleClick() {
            startDraft(at: location)
        }
    }

    private func startDraft(at location: CGPoint) {
        guard !model.isReadOnly else { return }
        anchor = location
        draft = model.newEvent(on: day, startMinute: nil)
    }
}
