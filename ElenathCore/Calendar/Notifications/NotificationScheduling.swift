import Foundation

/// What Ithil needs from the system's notification center. The app implements it with UNUserNotificationCenter;
/// tests use a fake.
///
/// Implementations build each notification from the `PlannedAlert` (title, body, the "Open Files" action)
/// and use `PlannedAlert.identifier` as the request identifier, so `AlertSynchronizer` can match pending
/// notifications against the plan.
public protocol NotificationScheduling: Sendable {
    /// Identifiers of Ithil's pending (not yet delivered) notifications, i.e. those with AlertPlanner.identifierPrefix.
    func pendingAlertIdentifiers() async -> Set<String>

    /// Adds a pending notification for each alert, firing at its `fireDate`. A request with an identifier
    /// that is already pending replaces it.
    func schedule(_ alerts: [PlannedAlert]) async throws

    /// Removes the pending notifications with these identifiers. Unknown identifiers are ignored.
    func cancel(identifiers: Set<String>) async
}
