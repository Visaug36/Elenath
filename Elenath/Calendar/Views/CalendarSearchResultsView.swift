import ElenathCore
import SwiftUI

/// Search results, shown in place of the calendar while the toolbar search field has text.
///
/// One row per matching event (its next occurrence, or its latest past one), in "Upcoming" and "Past"
/// sections. Choosing a row shows that day in the calendar, in Day view if that's on screen and otherwise
/// in Week view, selects the event, and calls `onShowEvent` so the window puts the calendar back while
/// the query stays in the field. No matches → the "Nothing by that name." empty state.
struct CalendarSearchResultsView: View {
    @Environment(CalendarModel.self) private var model
    let onShowEvent: () -> Void

    var body: some View {
        let results = model.searchResults
        if results.isEmpty {
            let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            EmptyStateView(
                illustration: .emptySearch,
                title: "Nothing by that name.",
                message: "No events match “\(query)”."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .starryBackground(.backgroundWindow)
        } else {
            CalendarSearchResultsList(results: results, onShowEvent: onShowEvent)
        }
    }
}

private struct CalendarSearchResultsList: View {
    @Environment(CalendarModel.self) private var model
    let results: [Occurrence]
    let onShowEvent: () -> Void

    var body: some View {
        let now = model.now
        let upcoming = results.filter { $0.end > now }
        let past = results.filter { $0.end <= now }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if !upcoming.isEmpty {
                    CalendarSearchSectionLabel(title: "Upcoming")
                    ForEach(upcoming) { occurrence in
                        CalendarSearchResultRow(occurrence: occurrence, onShowEvent: onShowEvent)
                    }
                }
                if !past.isEmpty {
                    CalendarSearchSectionLabel(title: "Past")
                        .padding(.top, upcoming.isEmpty ? 0 : 16)
                    ForEach(past) { occurrence in
                        CalendarSearchResultRow(occurrence: occurrence, onShowEvent: onShowEvent)
                    }
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
    }
}

/// "Upcoming" / "Past": 11 pt semibold in `TextTertiary`.
private struct CalendarSearchSectionLabel: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(Typography.caption)
            .foregroundStyle(Color.textTertiary)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct CalendarSearchResultRow: View {
    @Environment(CalendarModel.self) private var model
    let occurrence: Occurrence
    let onShowEvent: () -> Void
    @State private var isHovered = false

    var body: some View {
        let title = EventFormatting.displayTitle(occurrence.event)
        let when = whenText
        let location = occurrence.event.location.trimmingCharacters(in: .whitespacesAndNewlines)
        Button {
            open()
        } label: {
            HStack(spacing: 10) {
                SubjectDot(subject: model.subject(for: occurrence.event))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    Text(when)
                        .font(Typography.secondary)
                        .monospacedDigit()
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                if !location.isEmpty {
                    Label(location, systemImage: "mappin")
                        .font(Typography.secondary)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background {
                RoundedRectangle(cornerRadius: Metrics.Radius.listRow, style: .continuous)
                    .fill(rowFill)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel(EventFormatting.spokenJoined([title, when, location].filter { !$0.isEmpty }))
        .accessibilityHint(Text("Shows the event in the calendar"))
    }

    /// The day and time, with the year when it isn't this year.
    private var whenText: String {
        let day = EventFormatting.displayDay(of: occurrence, timeZone: model.timeZone)
        return EventFormatting.dayAndTime(
            occurrence, timeZone: model.timeZone, includeYear: day.year != model.today.year)
    }

    private var rowFill: Color {
        if model.selectedOccurrenceID == occurrence.id { return Color.accentSoft }
        return isHovered ? Color.controlFill : Color.clear
    }

    private func open() {
        let day = EventFormatting.displayDay(of: occurrence, timeZone: model.timeZone)
        model.show(day, span: model.span == .day ? .day : .week)
        model.selectedOccurrenceID = occurrence.id
        onShowEvent()
    }
}
