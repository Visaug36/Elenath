import SwiftUI

/// The calendar's parts of Elenath's sidebar, under the Calendar row while the calendar is open (Ithil's
/// sidebar): the mini month and the subjects with their visibility. Up next is on Today.
struct CalendarSidebarSections: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            MiniMonthView()
            SidebarSubjectsSection()
        }
        .padding(.leading, 2)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }
}

/// The explain-then-ask card, only when an alert is coming up in the next two weeks: while permission
/// hasn't been asked for (until "Not Now"), or while notifications are off.
struct SidebarNotificationPrompt: View {
    @Environment(NotificationsController.self) private var notifications

    var body: some View {
        if isShown {
            NotificationPermissionView()
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
    }

    private var isShown: Bool {
        switch notifications.authorization {
        case .notDetermined:
            return !notifications.isPromptDismissed && notifications.hasUpcomingAlerts
        case .denied:
            return notifications.hasUpcomingAlerts
        case .unknown, .authorized:
            return false
        }
    }
}

/// A sidebar section label ("Up next", "Subjects"): 11 pt semibold in `TextTertiary`.
struct CalendarSidebarSectionLabel: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(Typography.caption)
            .foregroundStyle(Color.textTertiary)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}
