import Foundation

/// What one `AlertSynchronizer.sync(library:now:)` changed.
public struct AlertSyncResult: Hashable, Sendable {
    /// Identifiers that were scheduled, earliest fire date first.
    public var added: [String]
    /// Identifiers that were cancelled because they are no longer planned, sorted.
    public var removed: [String]

    public init(added: [String], removed: [String]) {
        self.added = added
        self.removed = removed
    }
}

/// Keeps the system's pending notifications in step with the library.
///
/// Each `sync(library:now:)` compares Ithil's pending identifiers with `AlertPlanner.plan(_:now:)` and
/// touches only the difference: alerts that are still right stay scheduled, outdated ones (an event was
/// renamed, moved or deleted, or its alert changed) are cancelled, missing ones are added. Notifications
/// that don't carry `AlertPlanner.identifierPrefix` belong to someone else and are never touched.
///
/// Calls run one at a time, in the order they arrive, so a sync that starts while another is waiting
/// on the notification center can never be overwritten by the older one: the latest library always wins.
/// "Order they arrive" is the order the calls reach this actor, so the app should make them from one
/// place in order (for example awaiting them one after another from the main actor); two separate
/// unstructured tasks may arrive in either order.
///
/// The planner is fixed. When the display time zone changes, make a new synchronizer once the old one's
/// last call has returned, and call `cancelAll()` before its first sync: a timed alert's identifier
/// doesn't include the display time zone, so an alert whose text was written for the old zone would
/// otherwise stay pending.
public actor AlertSynchronizer {
    private let scheduler: any NotificationScheduling
    private let planner: AlertPlanner
    /// Whether a sync or cancel is running.
    private var isBusy = false
    /// Calls waiting for their turn, oldest first.
    private var waitingTurns: [CheckedContinuation<Void, Never>] = []

    public init(scheduler: any NotificationScheduling, planner: AlertPlanner) {
        self.scheduler = scheduler
        self.planner = planner
    }

    /// Makes the pending notifications match planner.plan(library, now): cancels pending Ithil identifiers that
    /// are no longer planned, schedules planned ones that aren't pending. Calls are serialized; a call that
    /// arrives while one is running waits its turn (the latest library always wins — no stale overwrite).
    ///
    /// Stale alerts are cancelled before new ones are scheduled, so the system's limit on pending
    /// notifications is never exceeded on the way. If scheduling throws, the next sync tries again.
    @discardableResult
    public func sync(library: CalendarDocument, now: Date) async throws -> AlertSyncResult {
        await beginTurn()
        defer { endTurn() }
        let planned = planner.plan(library, now: now)
        let reported = await scheduler.pendingAlertIdentifiers()
        let pending = Self.ownIdentifiers(reported)
        let plannedIdentifiers = Set(planned.map { $0.identifier })
        let stale = pending.subtracting(plannedIdentifiers)
        let missing = planned.filter { !pending.contains($0.identifier) }
        if !stale.isEmpty {
            await scheduler.cancel(identifiers: stale)
        }
        if !missing.isEmpty {
            try await scheduler.schedule(missing)
        }
        return AlertSyncResult(added: missing.map { $0.identifier }, removed: stale.sorted())
    }

    /// Cancels everything Ithil scheduled (e.g. when notifications are turned off or the folder changes).
    ///
    /// Waits for a running sync to finish first, so nothing it schedules survives the cancel. A later
    /// `sync(library:now:)` schedules everything again.
    public func cancelAll() async {
        await beginTurn()
        defer { endTurn() }
        let reported = await scheduler.pendingAlertIdentifiers()
        let pending = Self.ownIdentifiers(reported)
        if !pending.isEmpty {
            await scheduler.cancel(identifiers: pending)
        }
    }

    // MARK: - Turns

    /// Returns when it is this call's turn: at once if nothing is running, otherwise after every call
    /// that arrived earlier has finished.
    private func beginTurn() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            waitingTurns.append(continuation)
        }
    }

    /// Hands the turn to the oldest waiting call, if any.
    private func endTurn() {
        if waitingTurns.isEmpty {
            isBusy = false
        } else {
            waitingTurns.removeFirst().resume()
        }
    }

    /// Only Ithil's identifiers, even if the notification center reports others.
    private static func ownIdentifiers(_ identifiers: Set<String>) -> Set<String> {
        identifiers.filter { $0.hasPrefix(AlertPlanner.identifierPrefix) }
    }
}
