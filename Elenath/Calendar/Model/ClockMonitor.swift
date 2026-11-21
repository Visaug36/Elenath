import AppKit
import Foundation

/// Keeps `CalendarModel.now`, `today` and its calendar math current.
///
/// - A main-actor task wakes at every minute boundary and re-reads the clock.
/// - Midnight (`NSCalendarDayChanged`) and a changed system clock re-read it at once.
/// - A time zone or locale change, and waking from sleep, rebuild the calendar math too.
///
/// With a pinned clock (`-demoNow`) the model's time source never moves, so neither does `now`.
///
/// `NotificationsController` follows the same system events itself (re-plan at midnight, on wake and when
/// the clock changes; start over after a time zone change), so this type stays about the model only.
@MainActor
final class ClockMonitor {
    private weak var model: CalendarModel?
    private var tickTask: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []

    init(model: CalendarModel) {
        self.model = model
    }

    func start() {
        guard tickTask == nil else { return }
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: ClockMonitor.delayUntilNextMinute(after: Date()))
                } catch {
                    return
                }
                guard let model = self?.model else { return }
                model.refreshClock()
            }
        }
        let center = NotificationCenter.default
        observe(.NSCalendarDayChanged, in: center) { $0.refreshClock() }
        observe(.NSSystemClockDidChange, in: center) { $0.refreshClock() }
        observe(.NSSystemTimeZoneDidChange, in: center) { $0.refreshCalendar() }
        observe(NSLocale.currentLocaleDidChangeNotification, in: center) { $0.refreshCalendar() }
        observe(NSWorkspace.didWakeNotification, in: NSWorkspace.shared.notificationCenter) { $0.refreshCalendar() }
    }

    private func observe(
        _ name: Notification.Name,
        in center: NotificationCenter,
        action: @escaping @MainActor @Sendable (CalendarModel) -> Void
    ) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let model = self?.model else { return }
                action(model)
            }
        }
        observers.append(observer)
    }

    /// Just past the next whole minute, so the tick lands after the boundary rather than before it.
    nonisolated static func delayUntilNextMinute(after date: Date) -> Duration {
        let intoMinute = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
        let remaining = max(0, 60 - intoMinute)
        return .milliseconds(Int((remaining * 1_000).rounded(.up)) + 50)
    }
}
