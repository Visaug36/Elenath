import ElenathCore
import Foundation
import UserNotifications
import os

private let logger = Logger(subsystem: "io.github.visaug36.Elenath", category: "Notifications")

/// What a pending Elenath notification shows, read back from the notification center.
struct PendingAlertDetails: Hashable, Sendable {
    var title: String
    var body: String
    var categoryIdentifier: String
}

/// Elenath's alerts in macOS's notification center (`UNUserNotificationCenter.current()`).
///
/// - One request per `PlannedAlert`, identified by its `identifier`, with a calendar trigger at its fire
///   date (every component down to the second, on the Gregorian calendar in the planning time zone, not
///   repeating), so it fires even while Elenath is quit.
/// - Title and body come from `AlertText`; the file count from the provider (normally
///   `FilesController.makeFileCountProvider()`). Events with files get the `EVENT_FILES` category, which
///   offers "Open Files"; others get `EVENT`. Notifications of one event share a thread.
/// - Only identifiers with `AlertPlanner.identifierPrefix` are ever read or removed.
///
/// A value type with no state of its own, so `AlertSynchronizer` can call it from its actor.
struct UserNotificationScheduler: NotificationScheduling {
    /// The "Open Files" action: opens the event's folder (in Finder), launching Elenath if needed.
    static let openFilesActionIdentifier = "OPEN_FILES"
    /// The category of alerts for events that have files: offers "Open Files".
    static let filesCategoryIdentifier = "EVENT_FILES"
    /// The category of alerts for events without files.
    static let plainCategoryIdentifier = "EVENT"
    /// The `userInfo` key that holds the alert's identifier.
    static let identifierKey = "identifier"

    /// The time zone the alerts were planned in; times in the text are shown in it.
    let timeZone: TimeZone
    /// How many files an occurrence's folder holds.
    let fileCount: @Sendable (Occurrence) async -> Int

    // MARK: - NotificationScheduling

    func pendingAlertIdentifiers() async -> Set<String> {
        let pending = await pendingDetails()
        return Set(pending.keys)
    }

    /// Adds every alert it can; if some fail, the first error is thrown after the others were added, so
    /// the next sync only has to retry those.
    func schedule(_ alerts: [PlannedAlert]) async throws {
        var firstError: (any Error)? = nil
        for alert in alerts {
            let count = await fileCount(alert.occurrence)
            do {
                try await add(alert, fileCount: count)
            } catch {
                logger.error("Could not schedule an alert: \(error.localizedDescription, privacy: .private)")
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if let firstError {
            throw firstError
        }
    }

    func cancel(identifiers: Set<String>) async {
        let own = identifiers.filter { $0.hasPrefix(AlertPlanner.identifierPrefix) }
        guard !own.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: own.sorted())
    }

    // MARK: - Keeping pending alerts current

    /// Elenath's pending notifications, by identifier, with what each shows.
    func pendingDetails() async -> [String: PendingAlertDetails] {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        var details: [String: PendingAlertDetails] = [:]
        for request in requests where request.identifier.hasPrefix(AlertPlanner.identifierPrefix) {
            let content = request.content
            details[request.identifier] = PendingAlertDetails(
                title: content.title, body: content.body, categoryIdentifier: content.categoryIdentifier)
        }
        return details
    }

    /// Rewrites pending alerts whose text is out of date although their identifier still matches: files were
    /// added to or removed from the event (the "N files" part and the Open Files action), or the time
    /// format changed (region settings). A request with the same identifier replaces the pending one.
    ///
    /// `skipping` lists identifiers that were just scheduled and need no check. Returns how many were
    /// rewritten.
    @discardableResult
    func refreshPendingDetails(
        library: CalendarDocument,
        planner: AlertPlanner,
        now: Date,
        skipping recent: Set<String>
    ) async throws -> Int {
        let pending = await pendingDetails()
        guard !pending.isEmpty else { return 0 }
        var outdated: [(alert: PlannedAlert, fileCount: Int)] = []
        for alert in planner.plan(library, now: now) where !recent.contains(alert.identifier) {
            guard let shown = pending[alert.identifier] else { continue }
            let count = await fileCount(alert.occurrence)
            if shown != details(for: alert, fileCount: count) {
                outdated.append((alert: alert, fileCount: count))
            }
        }
        for entry in outdated {
            try await add(entry.alert, fileCount: entry.fileCount)
        }
        return outdated.count
    }

    // MARK: - Requests

    /// What the notification for one alert shows.
    func details(for alert: PlannedAlert, fileCount count: Int) -> PendingAlertDetails {
        PendingAlertDetails(
            title: AlertText.title(for: alert, timeZone: timeZone),
            body: AlertText.body(for: alert, fileCount: count, timeZone: timeZone),
            categoryIdentifier: count > 0 ? Self.filesCategoryIdentifier : Self.plainCategoryIdentifier)
    }

    /// The request for one alert (exposed for previews and checks; nothing is scheduled).
    func makeRequest(for alert: PlannedAlert, fileCount count: Int) -> UNNotificationRequest {
        let shown = details(for: alert, fileCount: count)
        let content = UNMutableNotificationContent()
        content.title = shown.title
        content.body = shown.body
        content.sound = .default
        content.threadIdentifier = alert.occurrence.event.id.uuidString
        content.categoryIdentifier = shown.categoryIdentifier
        content.userInfo = [Self.identifierKey: alert.identifier]
        let parts = triggerComponents(for: alert.fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        return UNNotificationRequest(identifier: alert.identifier, content: content, trigger: trigger)
    }

    private func add(_ alert: PlannedAlert, fileCount count: Int) async throws {
        let request = makeRequest(for: alert, fileCount: count)
        try await UNUserNotificationCenter.current().add(request)
    }

    /// Era and year to second of `fireDate` on the Gregorian calendar in the planning time zone. The calendar
    /// and zone are part of the components, so they name exactly one moment whatever calendar the Mac is
    /// set to, and a timed alert still fires at the right moment if the Mac changes time zone while Elenath
    /// is quit.
    private func triggerComponents(for fireDate: Date) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let units: Set<Calendar.Component> = [.era, .year, .month, .day, .hour, .minute, .second]
        var parts = calendar.dateComponents(units, from: fireDate)
        parts.calendar = calendar
        parts.timeZone = timeZone
        return parts
    }

    // MARK: - Categories and permission

    /// `EVENT_FILES` with the "Open Files" action, and the plain `EVENT`. Register once at launch.
    static func categories() -> Set<UNNotificationCategory> {
        let openFiles = UNNotificationAction(
            identifier: openFilesActionIdentifier, title: String(localized: "Open Files"), options: [.foreground])
        let withFiles = UNNotificationCategory(
            identifier: filesCategoryIdentifier, actions: [openFiles], intentIdentifiers: [], options: [])
        let plain = UNNotificationCategory(
            identifier: plainCategoryIdentifier, actions: [], intentIdentifiers: [], options: [])
        return [withFiles, plain]
    }

    /// Whether macOS lets Elenath show notifications. Provisional (quiet) permission counts as authorized.
    static func currentAuthorization() async -> NotificationsController.Authorization {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let status = settings.authorizationStatus
        if status == .notDetermined {
            return .notDetermined
        }
        if status == .denied {
            return .denied
        }
        if status == .authorized || status == .provisional {
            return .authorized
        }
        return .unknown
    }

    /// Shows macOS's permission prompt the first time; later calls return the answer the user gave.
    @discardableResult
    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            logger.error("Notification permission request failed: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }
}
