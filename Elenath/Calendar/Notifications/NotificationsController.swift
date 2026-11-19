import AppKit
import ElenathCore
import Foundation
import Observation
import UserNotifications
import os

private let logger = Logger(subsystem: "io.github.visaug36.Elenath", category: "Notifications")

/// Keeps macOS's pending notifications in step with the library, and knows whether Elenath may show any.
///
/// - **Scheduling:** `AlertPlanner` picks the nearest upcoming alerts (14 days, at most 48) and
///   `AlertSynchronizer` makes the pending notifications match, touching only Elenath's own. A sync runs about
///   a second after the library opens or changes, after waking from sleep, at midnight, after the clock,
///   the system or display time zone or the region settings change, after files change (the "N files"
///   part), when permission is granted, and every hour while Elenath runs. Syncs run one after another,
///   never side by side, so the latest library wins.
/// - **Permission:** read at launch and whenever Elenath becomes active. Elenath asks only when the user
///   presses "Turn On Notifications" in an explaining card (`NotificationPermissionView`).
/// - **Clicks:** "Open Files" shows the event's folder in Finder; clicking the notification itself shows
///   the event in the calendar. A click that launched Elenath waits until the library is open.
/// - **Demo mode** never reads permission, schedules or cancels anything (it would otherwise replace the
///   user's real alerts), so `authorization` stays `.unknown`.
@Observable @MainActor
final class NotificationsController: CalendarChangeObserver {
    enum Authorization: Equatable {
        case unknown, notDetermined, denied, authorized
    }

    /// What macOS allows. `.unknown` until it has been read (and always in demo mode).
    private(set) var authorization: Authorization = .unknown

    /// "Not Now" on the sidebar card: it stays hidden from then on. Kept per Mac; in demo mode only in memory.
    var isPromptDismissed: Bool {
        get { storedPromptDismissed }
        set {
            guard newValue != storedPromptDismissed else { return }
            storedPromptDismissed = newValue
            defaults?.set(newValue, forKey: Key.promptDismissed)
        }
    }

    /// Set by the app: opens a main window when none exists (e.g. with SwiftUI's `openWindow`), so clicking
    /// a notification always shows the calendar.
    @ObservationIgnored var openMainWindow: (() -> Void)? = nil

    private var storedPromptDismissed: Bool

    private let model: CalendarModel
    private let files: FilesController
    private let mode: Mode
    private let defaults: UserDefaults?
    @ObservationIgnored private var pipeline: AlertPipeline? = nil
    /// The next sync makes a new planner, scheduler and synchronizer (a library opened, or the time zone changed).
    @ObservationIgnored private var needsFreshPipeline = false
    /// The next sync first cancels every pending Elenath alert (after a time zone change).
    @ObservationIgnored private var cancelsBeforeNextSync = false
    @ObservationIgnored private var debounceTask: Task<Void, Never>? = nil
    @ObservationIgnored private var hourlyTask: Task<Void, Never>? = nil
    @ObservationIgnored private var isSyncing = false
    @ObservationIgnored private var needsAnotherSync = false
    /// A click that arrived before a library was open.
    @ObservationIgnored private var pendingResponse: NotificationResponse? = nil
    @ObservationIgnored private var systemObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var upcomingCache: (key: UpcomingKey, value: Bool)? = nil

    /// Registers as a library observer and with `NotificationDelegate`. In the real app it also registers
    /// the notification categories, reads the permission and starts the hourly re-plan.
    convenience init(model: CalendarModel, files: FilesController) {
        self.init(model: model, files: files, mode: model.isDemo ? .demo : .live)
    }

    private init(model: CalendarModel, files: FilesController, mode: Mode) {
        let defaults: UserDefaults? = mode == .live ? .standard : nil
        self.model = model
        self.files = files
        self.mode = mode
        self.defaults = defaults
        self.storedPromptDismissed = defaults?.bool(forKey: Key.promptDismissed) ?? false
        model.addChangeObserver(self)
        guard mode != .preview else { return }
        NotificationDelegate.install()
        NotificationDelegate.shared.attach(self)
        guard mode == .live else { return }
        UNUserNotificationCenter.current().setNotificationCategories(UserNotificationScheduler.categories())
        observeSystemEvents()
        observeTimeZone()
        observeFiles()
        startHourlyReplanning()
        Task {
            await self.refreshAuthorization()
        }
    }

    /// Whether any alert would fire in the next 14 days (so asking for permission is worth it).
    var hasUpcomingAlerts: Bool {
        let key = UpcomingKey(revision: model.libraryRevision, now: model.now, timeZone: model.timeZone)
        if let cached = upcomingCache, cached.key == key { return cached.value }
        let planner = AlertPlanner(displayTimeZone: key.timeZone, maximumCount: 1)
        let value = !planner.plan(model.library, now: planningNow).isEmpty
        upcomingCache = (key: key, value: value)
        return value
    }

    // MARK: - Permission

    /// Reads what macOS allows. Becoming authorized starts a sync.
    func refreshAuthorization() async {
        guard mode == .live else { return }
        let status = await UserNotificationScheduler.currentAuthorization()
        let wasAuthorized = authorization == .authorized
        if authorization != status {
            authorization = status
        }
        if status == .authorized, !wasAuthorized {
            scheduleSync()
        }
    }

    /// Shows macOS's permission prompt. Call only from a button the user pressed, after explaining why.
    func requestAuthorization() async {
        guard mode == .live else { return }
        let granted = await UserNotificationScheduler.requestAuthorization()
        logger.notice("Notification permission granted: \(granted, privacy: .public)")
        await refreshAuthorization()
    }

    /// Opens Elenath's page in System Settings → Notifications.
    func openSystemSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? "io.github.visaug36.Elenath"
        let addresses = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)",
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
        ]
        for address in addresses {
            guard let url = URL(string: address) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
        logger.error("Could not open System Settings → Notifications")
    }

    // MARK: - Scheduling

    /// Syncs about a second from now; calls in the meantime are folded into that one.
    func scheduleSync() {
        guard canSchedule else { return }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: NotificationsController.debounceDelay)
            } catch {
                return
            }
            guard !Task.isCancelled, let controller = self else { return }
            controller.debounceTask = nil
            await controller.runSyncs()
        }
    }

    /// The display time zone changed: the next sync uses a new planner and first cancels every pending
    /// alert, whose times were written for the old zone. (The controller also notices the change itself
    /// through `CalendarModel.timeZone`; calling this as well is harmless.)
    func timeZoneDidChange() {
        needsFreshPipeline = true
        cancelsBeforeNextSync = true
        scheduleSync()
    }

    // MARK: - Clicks

    /// A click on a notification: "Open Files" shows the event's folder in Finder; anything else shows
    /// the event in the calendar. Alerts Elenath doesn't know (any more) just bring Elenath forward.
    func handleResponse(identifier: String, actionIdentifier: String) {
        if actionIdentifier == UNNotificationDismissActionIdentifier { return }
        guard model.state == .ready else {
            // Launched by the click: handled once the library is open.
            pendingResponse = NotificationResponse(identifier: identifier, actionIdentifier: actionIdentifier)
            activateApp()
            return
        }
        guard let parsed = AlertPlanner.parse(identifier: identifier),
            let occurrence = model.occurrence(id: Occurrence.ID(eventID: parsed.eventID, date: parsed.date))
        else {
            activateApp()
            return
        }
        if actionIdentifier == UserNotificationScheduler.openFilesActionIdentifier {
            files.revealInFinder(occurrence)
        } else {
            show(occurrence)
        }
    }

    // MARK: - CalendarChangeObserver

    func calendarDidChange(_ change: CalendarChange, from old: CalendarDocument, to new: CalendarDocument) {
        switch change {
        case .opened:
            // Another folder may mean another file count provider.
            needsFreshPipeline = true
            scheduleSync()
            if pendingResponse != nil {
                // After every observer has heard about the new library (FilesController follows its root).
                Task { @MainActor [weak self] in
                    self?.handlePendingResponse()
                }
            }
        case .added, .updated, .deleted, .subjectsChanged, .restored, .broughtIn:
            scheduleSync()
        case .closed:
            // Alerts already scheduled stay until a calendar opens again and the sync replaces them.
            break
        }
    }

    // MARK: - Private

    /// What the controller may touch.
    private enum Mode {
        /// The real app: reads permission, registers categories, schedules and cancels alerts.
        case live
        /// `-demo`: handles clicks, nothing else.
        case demo
        /// SwiftUI previews: no system calls at all.
        case preview
    }

    private enum Key {
        static let promptDismissed = "notificationPromptDismissed"
    }

    private static let debounceDelay: Duration = .seconds(1)
    private static let replanInterval: Duration = .seconds(60 * 60)

    private var canSchedule: Bool { mode == .live && authorization == .authorized }

    /// The real clock in the app (`model.now` only ticks every minute); the model's clock otherwise.
    private var planningNow: Date { mode == .live ? Date() : model.now }

    /// Runs syncs one after another until no more were asked for, so `AlertSynchronizer` gets its calls
    /// in order.
    private func runSyncs() async {
        guard !isSyncing else {
            needsAnotherSync = true
            return
        }
        isSyncing = true
        repeat {
            needsAnotherSync = false
            await syncOnce()
        } while needsAnotherSync
        isSyncing = false
    }

    private func syncOnce() async {
        guard canSchedule, model.state == .ready else { return }
        let pipeline = currentPipeline()
        if cancelsBeforeNextSync {
            cancelsBeforeNextSync = false
            await pipeline.synchronizer.cancelAll()
        }
        let library = model.library
        let now = planningNow
        do {
            let result = try await pipeline.synchronizer.sync(library: library, now: now)
            let refreshed = try await pipeline.scheduler.refreshPendingDetails(
                library: library, planner: pipeline.planner, now: now, skipping: Set(result.added))
            let added = result.added.count
            let removed = result.removed.count
            logger.debug("Alerts: \(added, privacy: .public) added, \(removed, privacy: .public) removed")
            if refreshed > 0 {
                logger.debug("Alerts: \(refreshed, privacy: .public) rewritten with current details")
            }
        } catch {
            // The next sync tries again.
            logger.error("Could not schedule alerts: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// The pipeline for the model's display time zone; a new one when the zone changed (then everything
    /// pending is cancelled first) or a library opened. Only called between syncs, so the old one is idle.
    private func currentPipeline() -> AlertPipeline {
        let zone = model.timeZone
        if let pipeline, pipeline.timeZone == zone, !needsFreshPipeline {
            return pipeline
        }
        if let pipeline, pipeline.timeZone != zone {
            cancelsBeforeNextSync = true
        }
        let planner = AlertPlanner(displayTimeZone: zone)
        let scheduler = UserNotificationScheduler(timeZone: zone, fileCount: files.makeFileCountProvider())
        let fresh = AlertPipeline(
            timeZone: zone, planner: planner, scheduler: scheduler,
            synchronizer: AlertSynchronizer(scheduler: scheduler, planner: planner))
        pipeline = fresh
        needsFreshPipeline = false
        return fresh
    }

    private func handlePendingResponse() {
        guard model.state == .ready, let response = pendingResponse else { return }
        pendingResponse = nil
        handleResponse(identifier: response.identifier, actionIdentifier: response.actionIdentifier)
    }

    /// Brings Elenath forward on the occurrence's day with the occurrence selected.
    private func show(_ occurrence: Occurrence) {
        activateApp()
        model.reveal(occurrence)
        bringMainWindowForward()
    }

    private func activateApp() {
        NSApplication.shared.activate()
    }

    /// The calendar window (not Settings, not a panel), restored if minimized; `openMainWindow` if there
    /// is none.
    private func bringMainWindowForward() {
        let candidates = NSApplication.shared.windows.filter { window in
            !(window is NSPanel) && window.canBecomeMain && !NotificationsController.isSettingsWindow(window)
        }
        let shown = candidates.first { $0.isVisible || $0.isMiniaturized }
        guard let window = shown ?? candidates.first else {
            openMainWindow?()
            return
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }

    private static func isSettingsWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.localizedCaseInsensitiveContains("settings") ?? false
    }

    // MARK: - Triggers

    private func observeSystemEvents() {
        let center = NotificationCenter.default
        observe(NSApplication.didBecomeActiveNotification, in: center) { controller in
            Task {
                await controller.refreshAuthorization()
            }
        }
        // The same system events `ClockMonitor` follows for `CalendarModel` (day change, clock, time zone, wake).
        observe(.NSCalendarDayChanged, in: center) { $0.scheduleSync() }
        observe(.NSSystemClockDidChange, in: center) { $0.scheduleSync() }
        observe(.NSSystemTimeZoneDidChange, in: center) { $0.timeZoneDidChange() }
        // The time format in the alerts' text follows the region settings.
        observe(NSLocale.currentLocaleDidChangeNotification, in: center) { $0.scheduleSync() }
        observe(NSWorkspace.didWakeNotification, in: NSWorkspace.shared.notificationCenter) { $0.scheduleSync() }
    }

    private func observe(
        _ name: Notification.Name,
        in center: NotificationCenter,
        action: @escaping @MainActor @Sendable (NotificationsController) -> Void
    ) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let controller = self else { return }
                action(controller)
            }
        }
        systemObservers.append(observer)
    }

    /// Follows the model's display time zone (time zone changes, also those found on wake); a sync then
    /// notices the new zone and starts over in it.
    private func observeTimeZone() {
        withObservationTracking {
            _ = model.timeZone
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.scheduleSync()
                self?.observeTimeZone()
            }
        }
    }

    /// Files added to or removed from an event change its alert's text.
    private func observeFiles() {
        withObservationTracking {
            _ = files.changeToken
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.scheduleSync()
                self?.observeFiles()
            }
        }
    }

    private func startHourlyReplanning() {
        hourlyTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: NotificationsController.replanInterval)
                } catch {
                    return
                }
                guard let controller = self else { return }
                controller.scheduleSync()
            }
        }
    }
}

/// One planner, the scheduler and the synchronizer over them, all for one display time zone.
private struct AlertPipeline {
    var timeZone: TimeZone
    var planner: AlertPlanner
    var scheduler: UserNotificationScheduler
    var synchronizer: AlertSynchronizer
}

/// What `hasUpcomingAlerts` depends on.
private struct UpcomingKey: Hashable {
    var revision: Int
    var now: Date
    var timeZone: TimeZone
}
