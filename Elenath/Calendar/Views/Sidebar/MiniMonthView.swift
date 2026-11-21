import ElenathCore
import SwiftUI

/// The sidebar's month: a header with ‹ › that page it on their own, weekday initials in the locale's
/// order, and the day grid. What the main view shows gets a `ControlFill` pill (the week's row, the day,
/// or the whole month), today is an amber circle, and clicking a day shows it in the main view.
struct MiniMonthView: View {
    @Environment(CalendarModel.self) private var model
    /// The month the user paged to with ‹ ›; nil follows the main view's selected date.
    @State private var pagedMonth: CalendarDate? = nil

    var body: some View {
        let month = displayedMonth
        VStack(alignment: .leading, spacing: 6) {
            header(month)
            weekdayInitials
            dayGrid(month)
        }
        .onChange(of: model.selectedDate) {
            pagedMonth = nil
        }
    }

    /// The first day of the month on screen.
    private var displayedMonth: CalendarDate {
        let date = pagedMonth ?? model.selectedDate
        return CalendarDate(year: date.year, month: date.month, day: 1)
    }

    private func header(_ month: CalendarDate) -> some View {
        HStack(spacing: 6) {
            Text(EventFormatting.monthName(month))
                .font(Typography.sidebarMonth)
                .foregroundStyle(Color.textPrimary)
            if month.year != model.today.year {
                Text(EventFormatting.year(month))
                    .font(.system(size: 18, weight: .regular, design: .serif))
                    .foregroundStyle(Color.textSecondary)
            }
            Spacer(minLength: 4)
            pageButton("Previous Month", systemImage: "chevron.left", direction: -1)
            pageButton("Next Month", systemImage: "chevron.right", direction: 1)
        }
        .padding(.leading, 4)
        .accessibilityElement(children: .contain)
    }

    private func pageButton(_ label: LocalizedStringKey, systemImage: String, direction: Int) -> some View {
        Button {
            pagedMonth = model.math.step(displayedMonth, by: .month, count: direction)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.textSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private var weekdayInitials: some View {
        HStack(spacing: 0) {
            ForEach(model.math.weekdayOrder(), id: \.self) { weekday in
                Text(EventFormatting.veryShortWeekdaySymbol(weekday))
                    .font(Typography.caption)
                    .foregroundStyle(Color.textTertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private func dayGrid(_ month: CalendarDate) -> some View {
        let days = model.math.monthGrid(year: month.year, month: month.month)
        let weeks: [[CalendarDate]] = stride(from: 0, to: days.count, by: 7).map { start in
            Array(days[start..<min(start + 7, days.count)])
        }
        let selected = model.selectedDate
        let showsMonth = model.span == .month && month.year == selected.year && month.month == selected.month
        return VStack(spacing: 2) {
            ForEach(weeks, id: \.self) { week in
                MiniMonthWeek(days: week, month: month)
            }
        }
        .background {
            if showsMonth {
                RoundedRectangle(cornerRadius: Metrics.Radius.formGroup, style: .continuous)
                    .fill(Color.controlFill)
            }
        }
    }
}

/// One row of the mini month. The week on screen in Week view gets a pill across the row.
private struct MiniMonthWeek: View {
    @Environment(CalendarModel.self) private var model
    let days: [CalendarDate]
    let month: CalendarDate

    var body: some View {
        let showsWeek = model.span == .week && days.contains(model.selectedDate)
        HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                MiniMonthDay(day: day, isInMonth: day.year == month.year && day.month == month.month)
            }
        }
        .background {
            if showsWeek {
                Capsule()
                    .fill(Color.controlFill)
            }
        }
    }
}

/// One day of the mini month: a button that shows the day in the main view.
private struct MiniMonthDay: View {
    @Environment(CalendarModel.self) private var model
    let day: CalendarDate
    let isInMonth: Bool

    var body: some View {
        let isToday = day == model.today
        let isSelected = day == model.selectedDate
        let showsDay = model.span == .day && isSelected
        Button {
            model.show(day, span: nil)
        } label: {
            number(isToday: isToday)
                .frame(maxWidth: .infinity, minHeight: 26)
                .background {
                    if showsDay {
                        Capsule()
                            .fill(Color.controlFill)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(isToday: isToday))
        .accessibilityAddTraits(traits(isSelected: isSelected))
    }

    private func number(isToday: Bool) -> some View {
        let weight: Font.Weight = isToday ? .bold : .regular
        return Text(day.day, format: .number)
            .font(.system(size: 12, weight: weight))
            .monospacedDigit()
            .foregroundStyle(numberColor(isToday: isToday))
            .frame(width: 22, height: 22)
            .background {
                if isToday {
                    Circle()
                        .fill(Color.accentColor)
                }
            }
    }

    private func numberColor(isToday: Bool) -> Color {
        if isToday { return Color.textOnAccent }
        return isInMonth ? Color.textPrimary : Color.textTertiary
    }

    private func accessibilityLabel(isToday: Bool) -> String {
        let date = EventFormatting.longDate(day, timeZone: model.timeZone, includeYear: day.year != model.today.year)
        return isToday ? String(localized: "\(date), today", comment: "VoiceOver: a day in the mini month") : date
    }

    private func traits(isSelected: Bool) -> AccessibilityTraits {
        isSelected ? [.isSelected] : []
    }
}
