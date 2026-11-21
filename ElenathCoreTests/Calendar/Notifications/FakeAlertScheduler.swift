import ElenathCore
import Foundation

/// The error `FakeAlertScheduler` throws when told to fail.
struct FakeAlertSchedulerFailure: Error {}

/// A notification center in memory that records every call, for the AlertSynchronizer tests.
///
/// Like a careless real implementation, `pendingAlertIdentifiers()` also reports other apps' pending
/// notifications (`foreign`), so the tests can check the synchronizer leaves them alone.
actor FakeAlertScheduler: NotificationScheduling {
    enum Call: Hashable, Sendable {
        case pendingIdentifiers
        case schedule([String])
        case cancel(Set<String>)
    }

    /// Every pending identifier: Ithil's and anyone else's.
    private(set) var pending: Set<String>
    /// The alerts scheduled so far, by identifier (cancelled ones included).
    private(set) var scheduledAlerts: [String: PlannedAlert] = [:]
    private(set) var calls: [Call] = []

    private var failsNextSchedule = false
    private var holdsNextSchedule = false
    private var heldSchedule: CheckedContinuation<Void, Never>?
    private var holdWatcher: CheckedContinuation<Void, Never>?

    init(pending: Set<String> = []) {
        self.pending = pending
    }

    // MARK: - NotificationScheduling

    func pendingAlertIdentifiers() async -> Set<String> {
        calls.append(.pendingIdentifiers)
        return pending
    }

    func schedule(_ alerts: [PlannedAlert]) async throws {
        calls.append(.schedule(alerts.map { $0.identifier }))
        if failsNextSchedule {
            failsNextSchedule = false
            throw FakeAlertSchedulerFailure()
        }
        if holdsNextSchedule {
            holdsNextSchedule = false
            await withCheckedContinuation { continuation in
                heldSchedule = continuation
                holdWatcher?.resume()
                holdWatcher = nil
            }
        }
        for alert in alerts {
            pending.insert(alert.identifier)
            scheduledAlerts[alert.identifier] = alert
        }
    }

    func cancel(identifiers: Set<String>) async {
        calls.append(.cancel(identifiers))
        pending.subtract(identifiers)
    }

    // MARK: - Test controls

    /// Makes the next `schedule(_:)` throw without scheduling anything.
    func failNextSchedule() {
        failsNextSchedule = true
    }

    /// Makes the next `schedule(_:)` wait, before it schedules anything, until `releaseHeldSchedule()`.
    func holdNextSchedule() {
        holdsNextSchedule = true
    }

    /// Returns once a `schedule(_:)` call is being held.
    func waitUntilScheduleIsHeld() async {
        guard heldSchedule == nil else { return }
        await withCheckedContinuation { continuation in
            holdWatcher = continuation
        }
    }

    /// Lets the held `schedule(_:)` call continue.
    func releaseHeldSchedule() {
        heldSchedule?.resume()
        heldSchedule = nil
    }

    func clearCalls() {
        calls = []
    }
}
