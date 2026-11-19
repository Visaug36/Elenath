import ElenathCore
import Foundation

/// The words of an Elenath notification: "Physics Lecture in 10 min" over "14:00 – 15:30 · Room B204 · 4 files".
///
/// Not tied to the main actor: `UserNotificationScheduler` builds requests wherever `AlertSynchronizer` runs.
/// Times are shown in the time zone the alerts were planned in (the display time zone), in the user's
/// locale, as everywhere else in Elenath.
enum AlertText {
    private static let minutesPerHour = 60
    private static let minutesPerDay = 24 * 60

    /// The title: the event's name and when it starts.
    ///
    /// - Timed events: "… is starting" (at time of event), "… in 10 min", "… in 1 hour", "… in 3 hours",
    ///   "… in 1 h 30 min", "… tomorrow" (1 day before), "… in 2 days".
    /// - All-day events: by the day the alert fires on, "… today", "… tomorrow" or "… in 3 days".
    static func title(for alert: PlannedAlert, timeZone: TimeZone) -> String {
        let title = EventFormatting.displayTitle(alert.occurrence.event)
        if alert.occurrence.isAllDay {
            let fireDay = CalendarDate(alert.fireDate, in: timeZone)
            return allDayTitle(title, daysAhead: fireDay.days(to: alert.occurrence.date))
        }
        return timedTitle(title, minutesBefore: max(0, alert.minutesBefore))
    }

    /// The body: the time range ("All day" for all-day events), then the location and "N files" when there
    /// are any, joined with " · ".
    static func body(for alert: PlannedAlert, fileCount: Int, timeZone: TimeZone) -> String {
        var parts = [EventFormatting.timeRange(alert.occurrence, timeZone: timeZone)]
        let location = alert.occurrence.event.location.trimmingCharacters(in: .whitespacesAndNewlines)
        if !location.isEmpty {
            parts.append(location)
        }
        if let files = filesText(fileCount) {
            parts.append(files)
        }
        return EventFormatting.joined(parts)
    }

    /// "1 file", "4 files"; nil for none.
    static func filesText(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? String(localized: "1 file") : String(localized: "\(count) files")
    }

    // MARK: - Private

    private static func timedTitle(_ title: String, minutesBefore minutes: Int) -> String {
        if minutes == 0 {
            return String(localized: "\(title) is starting", comment: "Notification title: an event starts now")
        }
        if minutes == minutesPerDay {
            return String(localized: "\(title) tomorrow", comment: "Notification title: an event is tomorrow")
        }
        if minutes % minutesPerDay == 0 {
            let days = minutes / minutesPerDay
            return String(localized: "\(title) in \(days) days", comment: "Notification title: starts in N days")
        }
        if minutes < minutesPerHour {
            return String(localized: "\(title) in \(minutes) min", comment: "Notification title: starts in N minutes")
        }
        let hours = minutes / minutesPerHour
        let rest = minutes % minutesPerHour
        if rest != 0 {
            return String(
                localized: "\(title) in \(hours) h \(rest) min",
                comment: "Notification title: starts in N hours and M minutes")
        }
        if hours == 1 {
            return String(localized: "\(title) in 1 hour", comment: "Notification title: starts in one hour")
        }
        return String(localized: "\(title) in \(hours) hours", comment: "Notification title: starts in N hours")
    }

    /// `daysAhead` is how many days after the alert's own day the event begins.
    private static func allDayTitle(_ title: String, daysAhead: Int) -> String {
        if daysAhead <= 0 {
            return String(localized: "\(title) today", comment: "Notification title: an all-day event is today")
        }
        if daysAhead == 1 {
            return String(localized: "\(title) tomorrow", comment: "Notification title: an event is tomorrow")
        }
        return String(localized: "\(title) in \(daysAhead) days", comment: "Notification title: starts in N days")
    }
}
