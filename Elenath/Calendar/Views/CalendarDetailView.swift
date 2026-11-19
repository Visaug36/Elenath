import ElenathCore
import SwiftUI

/// The calendar in the main window's detail area (Ithil's `CalendarWindow`, fitted into Elenath's window):
/// the calendar for the current span, or the calendar's search results while the toolbar search field
/// has text. The sidebar parts (mini month, subjects) are in Elenath's sidebar, and the toolbar is
/// `CalendarToolbar`.
///
/// - Choosing a search result shows the event in the calendar but keeps the query in the field; editing the
///   query or pressing Return in the field brings the results back, and clearing it ends the search.
/// - Until the calendar is open, one screen says why: loading, a space that has the calendar's name, or a
///   calendar that can't be read.
struct CalendarDetailView: View {
    @Environment(CalendarModel.self) private var model

    var body: some View {
        switch model.state {
        case .ready:
            content
                .overlay(alignment: .bottom) {
                    if model.library.events.isEmpty, model.library.subjects.isEmpty, model.canEdit {
                        BringInHint()
                            .padding(20)
                    }
                }
        case .closed, .loading:
            Color.backgroundWindow
        case .nameTakenBySpace(let space):
            CalendarNameTakenView(space: space)
        case .unreadable(let message):
            CalendarUnreadableView(message: message)
        }
    }

    @ViewBuilder private var content: some View {
        if showsSearchResults {
            CalendarSearchResultsView {
                model.isSearchDismissed = true
            }
        } else {
            switch model.span {
            case .day, .week:
                DayWeekView(days: model.visibleDays)
            case .month:
                MonthView(month: model.selectedDate)
            }
        }
    }

    private var showsSearchResults: Bool {
        guard !model.isSearchDismissed else { return false }
        return !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A space from Elenath 0.1 is called "Calendar": rename it to open the calendar.
private struct CalendarNameTakenView: View {
    @Environment(AppModel.self) private var app
    let space: SpaceID

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.accentText)
                .accessibilityHidden(true)
            Text("The name Calendar is taken")
                .font(Typography.emptyHeadline)
                .foregroundStyle(Color.textPrimary)
            Text("A space is called Calendar, the name the calendar uses now. Rename the space to open the calendar.")
                .font(Typography.body)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Rename Space…") {
                app.renameSpaceNamedCalendar(space)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .foregroundStyle(Color.textOnAccent)
            .disabled(!app.canEdit)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .starryBackground(.backgroundWindow)
    }
}

/// The calendar's file can't be read: what happened, and the way to the folder.
private struct CalendarUnreadableView: View {
    @Environment(AppModel.self) private var app
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.accentText)
                .accessibilityHidden(true)
            Text("Elenath can't open the calendar")
                .font(Typography.emptyHeadline)
                .foregroundStyle(Color.textPrimary)
            Text(verbatim: message)
                .font(Typography.body)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Show Calendar Folder in Finder") {
                app.showCalendarFolderInFinder()
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .starryBackground(.backgroundWindow)
    }
}

/// On an empty calendar: "Coming from Ithil?" and Bring In Ithil Calendar…, so a user who had Ithil finds the
/// way in without onboarding.
private struct BringInHint: View {
    @State private var showsBringIn = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 16))
                .foregroundStyle(Color.accentText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Coming from Ithil?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Text("Bring in your events, subjects and files. Your Ithil folder stays as it is.")
                    .font(Typography.secondary)
                    .foregroundStyle(Color.textSecondary)
            }
            Spacer(minLength: 12)
            Button("Bring In Ithil Calendar…") {
                showsBringIn = true
            }
        }
        .padding(14)
        .frame(maxWidth: 560)
        .background(Color.backgroundRaised, in: RoundedRectangle(cornerRadius: Metrics.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.Radius.card)
                .strokeBorder(Color.separatorLine, lineWidth: 1)
        }
        .sheet(isPresented: $showsBringIn) {
            BringInIthilSheet()
        }
    }
}
