import ElenathCore
import SwiftUI

/// The menu bar extra's agenda: a card for the next event (as in the sidebar's Up next: the next one that
/// hasn't started, of a visible subject), then today's and tomorrow's events.
struct MenuBarAgenda: View {
    @Environment(CalendarModel.self) private var model

    var body: some View {
        let today = model.today
        let tomorrow = today.adding(days: 1)
        let timeColumnWidth = MenuBarFormatting.timeColumnWidth()
        VStack(alignment: .leading, spacing: 12) {
            if let next = model.upNext.first {
                MenuBarNextCard(occurrence: next)
            }
            MenuBarDaySection(
                title: "Today", day: today, occurrences: model.occurrences(on: today),
                timeColumnWidth: timeColumnWidth)
            MenuBarDaySection(
                title: "Tomorrow", day: tomorrow, occurrences: model.occurrences(on: tomorrow),
                timeColumnWidth: timeColumnWidth)
        }
    }
}

/// "Next, in 10 min" / "Physics Lecture" / "14:00 – 15:30 · Room B204" on an `AccentSoft` card with an
/// amber edge, then an amber "Open Files" button and "4 files" once the event has files. Clicking the text
/// shows the event in the calendar.
private struct MenuBarNextCard: View {
    @Environment(CalendarModel.self) private var model
    @Environment(FilesController.self) private var files
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorSchemeContrast) private var contrast
    let occurrence: Occurrence

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.formGroup, style: .continuous)
        let fileCount = files.fileCount(for: occurrence) ?? 0
        VStack(alignment: .leading, spacing: 8) {
            summary
            if fileCount > 0 {
                HStack(spacing: 10) {
                    Button {
                        files.revealInFinder(occurrence)
                    } label: {
                        Label("Open Files", systemImage: "folder")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(MenuBarProminentButtonStyle())
                    .accessibilityHint(Text("Show the event’s folder in Finder"))
                    // On the amber card `TextTertiary` would miss AA in Night; `TextSecondary` keeps it.
                    Text(verbatim: FileLabels.count(fileCount))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Color.textSecondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentSoft, in: shape)
        .overlay {
            shape.strokeBorder(border, lineWidth: 1)
        }
    }

    private var summary: some View {
        let label = MenuBarFormatting.nextLabel(occurrence, now: model.now, math: model.math)
        let title = EventFormatting.displayTitle(occurrence.event)
        let detail = MenuBarFormatting.detail(occurrence, timeZone: model.timeZone)
        return Button {
            MenuBarNavigation.show(occurrence, model: model, openWindow: openWindow)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: label)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentText)
                Text(verbatim: title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                Text(verbatim: detail)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(EventFormatting.spokenJoined([label, title, detail]))
        .accessibilityHint(Text("Shows the event in Elenath"))
    }

    private var border: Color {
        contrast == .increased ? Color.accentText : Color.accentColor.opacity(0.55)
    }
}

/// "Today" or "Tomorrow" in `TextTertiary`, then a row per event (at most `maximumRows`, then "N more"), or
/// "Nothing planned".
private struct MenuBarDaySection: View {
    /// More than this many events show as "N more", which opens the day in Elenath.
    static let maximumRows = 6

    let title: LocalizedStringKey
    let day: CalendarDate
    let occurrences: [Occurrence]
    let timeColumnWidth: CGFloat

    var body: some View {
        let shown = Array(occurrences.prefix(Self.maximumRows))
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(Typography.caption)
                .foregroundStyle(Color.textTertiary)
                .padding(.horizontal, 8)
                .padding(.bottom, 3)
                .accessibilityAddTraits(.isHeader)
            if shown.isEmpty {
                Text("Nothing planned")
                    .font(Typography.secondary)
                    .foregroundStyle(Color.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            } else {
                ForEach(shown) { occurrence in
                    MenuBarEventRow(occurrence: occurrence, timeColumnWidth: timeColumnWidth)
                }
                if occurrences.count > shown.count {
                    MenuBarMoreRow(
                        day: day, count: occurrences.count - shown.count,
                        inset: MenuBarEventRowLabel.titleInset(timeColumnWidth: timeColumnWidth))
                }
            }
        }
    }
}

/// "14:00 · Physics Lecture · 4": the start time (tabular), the subject dot, the title, and `paperclip`
/// with the file count. Events that are over are dimmed to the quieter text colors, which keep AA
/// contrast. Clicking shows the event in the calendar.
private struct MenuBarEventRow: View {
    @Environment(CalendarModel.self) private var model
    @Environment(FilesController.self) private var files
    @Environment(\.openWindow) private var openWindow
    let occurrence: Occurrence
    let timeColumnWidth: CGFloat

    var body: some View {
        let fileCount = files.fileCount(for: occurrence) ?? 0
        Button {
            MenuBarNavigation.show(occurrence, model: model, openWindow: openWindow)
        } label: {
            MenuBarEventRowLabel(
                occurrence: occurrence, subject: model.subject(for: occurrence.event),
                isPast: occurrence.end < model.now, fileCount: fileCount, timeColumnWidth: timeColumnWidth)
        }
        .buttonStyle(MenuBarRowButtonStyle())
        .accessibilityLabel(spokenLabel(fileCount: fileCount))
        .accessibilityHint(Text("Shows the event in Elenath"))
    }

    /// "Physics Lecture, 2:00 PM to 3:30 PM, 4 files".
    private func spokenLabel(fileCount: Int) -> String {
        let label = EventFormatting.accessibilityLabel(occurrence, timeZone: model.timeZone)
        guard fileCount > 0 else { return label }
        return EventFormatting.spokenJoined([label, FileLabels.count(fileCount)])
    }
}

private struct MenuBarEventRowLabel: View {
    private static let spacing: CGFloat = 10
    private static let dotSize: CGFloat = 7

    @Environment(CalendarModel.self) private var model
    @Environment(\.isMenuBarRowHighlighted) private var isHighlighted
    let occurrence: Occurrence
    let subject: Subject?
    let isPast: Bool
    let fileCount: Int
    let timeColumnWidth: CGFloat

    /// Where the title starts, for lining up "N more" with it.
    static func titleInset(timeColumnWidth: CGFloat) -> CGFloat {
        timeColumnWidth + spacing + dotSize + spacing
    }

    var body: some View {
        HStack(spacing: Self.spacing) {
            Text(verbatim: MenuBarFormatting.timeColumn(occurrence, timeZone: model.timeZone))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(isPast && !isHighlighted ? Color.textTertiary : Color.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: timeColumnWidth, alignment: .leading)
            SubjectDot(subject: subject, size: Self.dotSize)
                .opacity(isPast ? 0.55 : 1)
            Text(verbatim: EventFormatting.displayTitle(occurrence.event))
                .font(Typography.body)
                .foregroundStyle(isPast ? Color.textSecondary : Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if fileCount > 0 {
                HStack(spacing: 1) {
                    Image(systemName: "paperclip")
                    Text(fileCount, format: .number)
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(isHighlighted ? Color.textSecondary : Color.textTertiary)
                .fixedSize()
                .accessibilityHidden(true)
            }
        }
    }
}

/// "N more" under a day with more events than fit; opens that day in Elenath.
private struct MenuBarMoreRow: View {
    @Environment(CalendarModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let day: CalendarDate
    let count: Int
    /// Lines the text up with the event titles.
    let inset: CGFloat

    var body: some View {
        Button {
            MenuBarNavigation.show(day, model: model, openWindow: openWindow)
        } label: {
            MenuBarMoreLabel(count: count)
                .padding(.leading, inset)
        }
        .buttonStyle(MenuBarRowButtonStyle())
        .accessibilityHint(Text("Shows the day in Elenath"))
    }
}

private struct MenuBarMoreLabel: View {
    @Environment(\.isMenuBarRowHighlighted) private var isHighlighted
    let count: Int

    var body: some View {
        Text("\(count) more")
            .font(Typography.secondary)
            .foregroundStyle(isHighlighted ? Color.textSecondary : Color.textTertiary)
    }
}
