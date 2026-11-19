import ElenathCore
import SwiftUI

/// "Up next" (Today's first card): the next few events of visible subjects, from every space (the calendar
/// exception: title, time and location only). The very next one is highlighted in `AccentSoft` with its
/// secondary line in amber ("in 10 min · 14:00 · Room B204"). Clicking a row shows the event in the calendar.
struct SidebarUpNextSection: View {
    @Environment(CalendarModel.self) private var model

    var body: some View {
        let upNext = model.upNext
        VStack(alignment: .leading, spacing: 2) {
            CalendarSidebarSectionLabel(title: "Up next")
            if upNext.isEmpty {
                Text("Nothing coming up")
                    .font(Typography.secondary)
                    .foregroundStyle(Color.textTertiary)
                    .padding(.horizontal, 8)
            } else {
                ForEach(upNext) { occurrence in
                    SidebarUpNextRow(occurrence: occurrence, isNext: occurrence.id == upNext.first?.id)
                }
            }
        }
    }
}

struct SidebarUpNextRow: View {
    @Environment(CalendarModel.self) private var model
    let occurrence: Occurrence
    let isNext: Bool
    @State private var isHovered = false

    var body: some View {
        let title = EventFormatting.displayTitle(occurrence.event)
        let parts = EventFormatting.upNextParts(occurrence, now: model.now, math: model.math)
        Button {
            open()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    SubjectDot(subject: model.subject(for: occurrence.event))
                    Text(title)
                        .font(Typography.body)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                }
                Text(EventFormatting.joined(parts))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(isNext ? Color.accentText : Color.textSecondary)
                    .lineLimit(1)
                    .padding(.leading, 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metrics.Padding.sidebarRow)
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
        .accessibilityLabel(EventFormatting.spokenJoined([title] + parts))
        .accessibilityHint(Text("Shows the event in the calendar"))
    }

    private var rowFill: Color {
        if isNext { return Color.accentSoft }
        return isHovered ? Color.controlFill : Color.clear
    }

    private func open() {
        model.reveal(occurrence)
    }
}

/// Today's "Up next" card content: Ithil's Up next rows, or a line when there is nothing.
struct TodayUpNext: View {
    @Environment(CalendarModel.self) private var model

    var body: some View {
        let upNext = model.upNext
        if model.state != .ready {
            CardPlaceholder(text: Text("The calendar isn't open."))
        } else if upNext.isEmpty {
            CardPlaceholder(text: Text("Nothing coming up."))
        } else {
            ForEach(upNext) { occurrence in
                SidebarUpNextRow(occurrence: occurrence, isNext: occurrence.id == upNext.first?.id)
            }
        }
    }
}
