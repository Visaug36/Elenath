import AppKit

/// AppKit hooks SwiftUI's `App` doesn't offer.
///
/// - Before launch finishes, `NotificationDelegate.shared` becomes the notification center's delegate, so a
///   click on an alert that launched Elenath reaches `NotificationsController`.
/// - Quitting waits (briefly) for the open note's last save and the calendar's, so a keystroke or an event
///   made just before ⌘Q is never lost. The app sets `model` when its first window appears.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    /// How long quitting waits for a save in progress before giving up.
    private let saveTimeout: Duration = .seconds(5)

    func applicationWillFinishLaunching(_ notification: Notification) {
        NotificationDelegate.install()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasPendingSaves || model.calendar.hasPendingSaves else { return .terminateNow }
        let timeout = saveTimeout
        Task { @MainActor in
            await model.finishPendingSaves(timeout: timeout)
            await model.calendar.finishPendingSaves(timeout: timeout)
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Elenath has one main window. Closing it leaves the app running, so the Quick Capture shortcut
    /// keeps working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
