import ElenathCore
import SwiftUI

/// The main window's toolbar: the month title on the leading side; ‹ Today ›, Day | Week | Month and the
/// amber + on the trailing side. The search field comes from `.searchable` on `CalendarDetailView`.
///
/// Each item is its own view reading `CalendarModel` from the environment, so only the item whose data
/// changed is redrawn.
struct CalendarToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ToolbarMonthTitle()
        }
        ToolbarItem(placement: .navigation) {
            ToolbarWorkplaceCapsule()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            ToolbarDateControls()
            ToolbarSpanPicker()
            ToolbarNewEventButton()
        }
    }
}

/// "October 2026": the month in New York semibold 26 pt, the year in regular weight and `TextSecondary`.
/// The Day view shows the month and year too.
private struct ToolbarMonthTitle: View {
    @Environment(CalendarModel.self) private var model

    var body: some View {
        let date = model.selectedDate
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(EventFormatting.monthName(date))
                .font(Typography.monthTitle)
                .foregroundStyle(Color.textPrimary)
            Text(EventFormatting.year(date))
                .font(.system(size: 26, weight: .regular, design: .serif))
                .foregroundStyle(Color.textSecondary)
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(EventFormatting.monthAndYear(date))
        .accessibilityAddTraits(.isHeader)
    }
}

/// While the calendar works inside a space ("Open in Red Cross"): the space's symbol and name on its fill,
/// and a button that goes back to everywhere.
private struct ToolbarWorkplaceCapsule: View {
    @Environment(CalendarModel.self) private var model

    var body: some View {
        if case .space(let id) = model.workplace, let space = model.spaces.first(where: { $0.id == id }) {
            HStack(spacing: 6) {
                Image(systemName: SpaceStyle.symbol(for: space))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SpaceStyle.color(for: space))
                    .accessibilityHidden(true)
                Text(verbatim: space.name)
                    .font(Typography.secondary)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                Button {
                    model.work(in: .everywhere)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Leave \(space.name)")
                .accessibilityLabel(Text("Leave \(space.name)"))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(SpaceStyle.fill(for: space), in: Capsule())
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Working in \(space.name)"))
        }
    }
}

/// ‹ Today ›: steps by the current span, or jumps back to today.
private struct ToolbarDateControls: View {
    @Environment(CalendarModel.self) private var model

    var body: some View {
        ControlGroup {
            Button {
                model.step(-1)
            } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .help("Previous")
            .accessibilityLabel(previousLabel)
            Button("Today") {
                model.goToToday()
            }
            .help("Show Today")
            Button {
                model.step(1)
            } label: {
                Label("Next", systemImage: "chevron.right")
            }
            .help("Next")
            .accessibilityLabel(nextLabel)
        }
        .labelStyle(.iconOnly)
    }

    private var previousLabel: Text {
        switch model.span {
        case .day: return Text("Previous Day")
        case .week: return Text("Previous Week")
        case .month: return Text("Previous Month")
        }
    }

    private var nextLabel: Text {
        switch model.span {
        case .day: return Text("Next Day")
        case .week: return Text("Next Week")
        case .month: return Text("Next Month")
        }
    }
}

/// Day | Week | Month, bound to `CalendarModel.span`.
private struct ToolbarSpanPicker: View {
    @Environment(CalendarModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Picker("View", selection: $model.span) {
            Text("Day").tag(CalendarSpan.day)
            Text("Week").tag(CalendarSpan.week)
            Text("Month").tag(CalendarSpan.month)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// The square amber +: opens the new-event editor in a popover under the button, for the selected day.
private struct ToolbarNewEventButton: View {
    @Environment(CalendarModel.self) private var model
    /// The event being created; set when the popover opens, nil when it closes.
    @State private var draft: Event? = nil

    var body: some View {
        Button {
            draft = model.newEvent(on: model.selectedDate, startMinute: nil)
        } label: {
            Label("New Event", systemImage: "plus")
                .labelStyle(.iconOnly)
                .foregroundStyle(Color.textOnAccent)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.accentColor)
        .help("New Event")
        .accessibilityLabel(Text("New Event"))
        .disabled(model.isReadOnly)
        .popover(item: $draft, arrowEdge: .bottom) { event in
            EventEditorView(mode: .new(event), onClose: { draft = nil })
        }
        .onChange(of: model.requestsNewEvent, initial: true) { _, requested in
            guard requested else { return }
            model.requestsNewEvent = false
            if model.canEdit {
                draft = model.newEvent(on: model.selectedDate, startMinute: nil)
            }
        }
    }
}
