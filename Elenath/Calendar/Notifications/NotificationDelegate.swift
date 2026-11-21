import Foundation
import UserNotifications

/// A notification the user clicked: which alert, and which button (the default action, "Open Files"…).
struct NotificationResponse: Hashable, Sendable {
    var identifier: String
    var actionIdentifier: String
}

/// The notification center's delegate: shows Elenath's alerts while Elenath is frontmost and hands clicks to
/// `NotificationsController`.
///
/// It must be the delegate before launch finishes, or a click that launched Elenath is lost, so the app
/// delegate calls `NotificationDelegate.install()` in `applicationWillFinishLaunching`, before any
/// controller exists. The controller attaches itself when it is created; clicks that arrive before that are
/// kept and handed over then.
///
/// macOS may call the delegate methods on any thread, so they are `nonisolated`: they copy the strings they
/// need out of the system's objects and only then hop to the main actor.
@MainActor
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    private weak var controller: NotificationsController?
    /// Clicks that arrived before a controller was attached, oldest first.
    private var waitingResponses: [NotificationResponse] = []

    /// Makes `shared` the delegate of the notification center. Safe to call more than once.
    static func install() {
        UNUserNotificationCenter.current().delegate = shared
    }

    /// Hands clicks to `controller` from now on, starting with any that were waiting.
    func attach(_ controller: NotificationsController) {
        self.controller = controller
        let waiting = waitingResponses
        waitingResponses.removeAll()
        for response in waiting {
            controller.handleResponse(identifier: response.identifier, actionIdentifier: response.actionIdentifier)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// While Elenath is frontmost its alerts still show as banners, in Notification Center, with sound.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let received = NotificationResponse(
            identifier: response.notification.request.identifier, actionIdentifier: response.actionIdentifier)
        await receive(received)
    }

    // MARK: - Private

    private func receive(_ response: NotificationResponse) {
        guard let controller else {
            waitingResponses.append(response)
            return
        }
        controller.handleResponse(identifier: response.identifier, actionIdentifier: response.actionIdentifier)
    }
}
