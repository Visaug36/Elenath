import ElenathCore
import Foundation
import Testing

struct AlertSynchronizerTests {
    private typealias Fixture = AlertsFixture
    private typealias Call = FakeAlertScheduler.Call

    private let planner = AlertPlanner(displayTimeZone: AlertsFixture.amsterdam)

    /// Lecture (13 and 20 October), essay (7 October) and quiz (8 October): four alerts from `now`.
    private let week = AlertsFixture.library([AlertsFixture.lecture, AlertsFixture.essay, AlertsFixture.quiz])

    private func plannedIdentifiers(_ library: CalendarDocument, now: Date = AlertsFixture.now) -> [String] {
        AlertsFixture.identifiers(planner.plan(library, now: now))
    }

    /// The identifier of the only alert `event` has from `now`.
    private func onlyIdentifier(_ event: Event) throws -> String {
        let alerts = planner.plan(AlertsFixture.library([event]), now: AlertsFixture.now)
        try #require(alerts.count == 1)
        return alerts[0].identifier
    }

    @Test func addsTheMissingAlerts() async throws {
        let fake = FakeAlertScheduler()
        let synchronizer = AlertSynchronizer(scheduler: fake, planner: planner)
        let result = try await synchronizer.sync(library: week, now: Fixture.now)

        let expected = plannedIdentifiers(week)
        #expect(expected.count == 4)
        #expect(result == AlertSyncResult(added: expected, removed: []))
        #expect(await fake.pending == Set(expected))
        let expectedCalls: [Call] = [.pendingIdentifiers, .schedule(expected)]
        #expect(await fake.calls == expectedCalls)
        let scheduled = await fake.scheduledAlerts
        #expect(expected.compactMap { scheduled[$0] } == planner.plan(week, now: Fixture.now))
    }

    @Test func removesAlertsThatAreNoLongerPlanned() async throws {
        let fake = FakeAlertScheduler()
        let synchronizer = AlertSynchronizer(scheduler: fake, planner: planner)
        try await synchronizer.sync(library: week, now: Fixture.now)

        // The quiz is renamed and the essay deleted.
        let changed = Fixture.library([Fixture.lecture, Fixture.renamedQuiz])
        let result = try await synchronizer.sync(library: changed, now: Fixture.now)
        let essay = try onlyIdentifier(Fixture.essay)
        let oldQuiz = try onlyIdentifier(Fixture.quiz)
        let newQuiz = try onlyIdentifier(Fixture.renamedQuiz)
        #expect(result.added == [newQuiz])
        #expect(result.removed == [essay, oldQuiz].sorted())
        #expect(await fake.pending == Set(plannedIdentifiers(changed)))
    }

    @Test func leavesAlertsThatAreStillRightAlone() async throws {
        let fake = FakeAlertScheduler()
        let synchronizer = AlertSynchronizer(scheduler: fake, planner: planner)
        try await synchronizer.sync(library: week, now: Fixture.now)

        await fake.clearCalls()
        let again = try await synchronizer.sync(library: week, now: Fixture.now)
        #expect(again == AlertSyncResult(added: [], removed: []))
        let onlyALook: [Call] = [.pendingIdentifiers]
        #expect(await fake.calls == onlyALook)

        // Renaming the quiz replaces its alert and nothing else.
        await fake.clearCalls()
        let renamed = Fixture.library([Fixture.lecture, Fixture.essay, Fixture.renamedQuiz])
        let result = try await synchronizer.sync(library: renamed, now: Fixture.now)
        let oldQuiz = try onlyIdentifier(Fixture.quiz)
        let newQuiz = try onlyIdentifier(Fixture.renamedQuiz)
        #expect(result == AlertSyncResult(added: [newQuiz], removed: [oldQuiz]))
        let expectedCalls: [Call] = [.pendingIdentifiers, .cancel([oldQuiz]), .schedule([newQuiz])]
        #expect(await fake.calls == expectedCalls)
        #expect(await fake.pending == Set(plannedIdentifiers(renamed)))
    }

    @Test func otherAppsNotificationsAreNeverTouched() async throws {
        let foreign: Set<String> = ["com.example.reminder.42", "ithil-alert-lookalike", "alert.ithil.1"]
        // A leftover with Ithil's prefix (from an older version, say) is Ithil's to clean up.
        let leftover = AlertPlanner.identifierPrefix + "leftover"
        let fake = FakeAlertScheduler(pending: foreign.union([leftover]))
        let synchronizer = AlertSynchronizer(scheduler: fake, planner: planner)

        let result = try await synchronizer.sync(library: week, now: Fixture.now)
        #expect(result.added == plannedIdentifiers(week))
        #expect(result.removed == [leftover])
        #expect(await fake.pending == foreign.union(plannedIdentifiers(week)))

        // Emptying the library removes Ithil's alerts only.
        let emptied = try await synchronizer.sync(library: Fixture.library([]), now: Fixture.now)
        #expect(emptied.added.isEmpty)
        #expect(emptied.removed == plannedIdentifiers(week).sorted())
        #expect(await fake.pending == foreign)
        let calls = await fake.calls
        for case .cancel(let identifiers) in calls {
            #expect(identifiers.isDisjoint(with: foreign))
        }
    }

    @Test func cancelAllRemovesEverythingIthilScheduled() async throws {
        let foreign: Set<String> = ["com.example.reminder.42"]
        let fake = FakeAlertScheduler(pending: foreign)
        let synchronizer = AlertSynchronizer(scheduler: fake, planner: planner)
        try await synchronizer.sync(library: week, now: Fixture.now)

        await synchronizer.cancelAll()
        #expect(await fake.pending == foreign)

        // Nothing of Ithil's pending: nothing to cancel.
        await fake.clearCalls()
        await synchronizer.cancelAll()
        let onlyALook: [Call] = [.pendingIdentifiers]
        #expect(await fake.calls == onlyALook)

        // The next sync schedules everything again.
        let result = try await synchronizer.sync(library: week, now: Fixture.now)
        #expect(result.added == plannedIdentifiers(week))
        #expect(await fake.pending == foreign.union(plannedIdentifiers(week)))
    }

    @Test func aFailedScheduleIsRetriedByTheNextSync() async throws {
        let fake = FakeAlertScheduler()
        let synchronizer = AlertSynchronizer(scheduler: fake, planner: planner)
        let library = week
        await fake.failNextSchedule()
        await #expect(throws: FakeAlertSchedulerFailure.self) {
            _ = try await synchronizer.sync(library: library, now: AlertsFixture.now)
        }
        #expect(await fake.pending.isEmpty)

        let result = try await synchronizer.sync(library: week, now: Fixture.now)
        #expect(result.added == plannedIdentifiers(week))
        #expect(await fake.pending == Set(plannedIdentifiers(week)))
    }

    @Test func alertsMoveAlongWithNow() async throws {
        let fake = FakeAlertScheduler()
        let synchronizer = AlertSynchronizer(scheduler: fake, planner: planner)
        let library = Fixture.library([Fixture.lecture])
        try await synchronizer.sync(library: library, now: Fixture.now)

        // A week later the 13 October alert has passed and 27 October comes within the horizon. (The fake
        // never delivers anything, so the passed alert is still pending and gets cancelled.)
        let weekLater = Fixture.instant(2026, 10, 13, 14, 0, in: Fixture.amsterdam)
        let result = try await synchronizer.sync(library: library, now: weekLater)
        let before = plannedIdentifiers(library)
        let after = plannedIdentifiers(library, now: weekLater)
        try #require(before.count == 2)
        try #require(after.count == 2)
        #expect(after[0] == before[1])
        #expect(result == AlertSyncResult(added: [after[1]], removed: [before[0]]))
        #expect(await fake.pending == Set(after))
    }

    @Test(.timeLimit(.minutes(1)))
    func overlappingSyncsEndWithTheLatestLibrary() async throws {
        let fake = FakeAlertScheduler()
        let synchronizer = AlertSynchronizer(scheduler: fake, planner: planner)
        let older = week
        let newer = Fixture.library([Fixture.lecture, Fixture.renamedQuiz])
        let now = Fixture.now
        // The first sync must reach `schedule(_:)`, or the hold below would never be reached.
        try #require(!plannedIdentifiers(older).isEmpty)

        await fake.holdNextSchedule()
        let first = Task { try await synchronizer.sync(library: older, now: now) }
        await fake.waitUntilScheduleIsHeld()
        // The first sync is waiting on the notification center. Give the second every chance to run
        // ahead of it; it must wait its turn instead.
        let second = Task { try await synchronizer.sync(library: newer, now: now) }
        for _ in 0..<100 {
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(20))
        await fake.releaseHeldSchedule()
        let firstResult = try await first.value
        let secondResult = try await second.value

        let olderIdentifiers = plannedIdentifiers(older)
        let newerIdentifiers = plannedIdentifiers(newer)
        let stale = Set(olderIdentifiers).subtracting(newerIdentifiers)
        let missing = newerIdentifiers.filter { !olderIdentifiers.contains($0) }
        #expect(!stale.isEmpty)
        #expect(!missing.isEmpty)
        #expect(firstResult == AlertSyncResult(added: olderIdentifiers, removed: []))
        #expect(secondResult == AlertSyncResult(added: missing, removed: stale.sorted()))
        #expect(await fake.pending == Set(newerIdentifiers))
        let expectedCalls: [Call] = [
            .pendingIdentifiers, .schedule(olderIdentifiers), .pendingIdentifiers, .cancel(stale), .schedule(missing),
        ]
        #expect(await fake.calls == expectedCalls)
    }
}
