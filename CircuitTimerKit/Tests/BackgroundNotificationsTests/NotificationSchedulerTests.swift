@testable import BackgroundNotifications

import Dependencies
import Foundation
import Testing

struct NotificationSchedulerTests: Sendable {
    private let owner = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test
    func test_sync_unchangedPlan_keepsPhysicalIdentifier() async throws {
        let fake = NotificationFake()
        let scheduler = NotificationScheduler(transport: fake.transport)
        let plan = [notification(after: 10)]
        let first = try await scheduler.sync(owner, revision: 1, plan: plan, now: { now }, clock: TestClock<Duration>())
        let second = try await scheduler.sync(owner, revision: 2, plan: plan, now: { now }, clock: TestClock<Duration>())
        #expect(first.isClean)
        #expect(first.confirmedFuture == 1)
        #expect(first.expired == 0)
        #expect(second.isClean)
        #expect(second.confirmedFuture == 1)
        #expect(fake.added.count == 1)
    }

    @Test
    func test_sync_missingFuture_retriesWithUniqueIdentifier() async throws {
        let fake = NotificationFake()
        fake.recordsPending = false
        let scheduler = NotificationScheduler(transport: fake.transport)
        let first = try await scheduler.sync(
            owner,
            revision: 1,
            plan: [notification(after: 10)],
            now: { now },
            clock: TestClock<Duration>()
        )
        let second = try await scheduler.sync(
            owner,
            revision: 2,
            plan: [notification(after: 10)],
            now: { now },
            clock: TestClock<Duration>()
        )
        #expect(first.missing == 1)
        #expect(first.confirmedFuture == 0)
        #expect(first.expired == 0)
        #expect(!first.isClean)
        #expect(second.missing == 1)
        #expect(Set(fake.added).count == 2)
    }

    @Test
    func test_sync_imminentAbsent_reportsUnconfirmedWithoutReplacing() async throws {
        let fake = NotificationFake()
        fake.recordsPending = false
        let scheduler = NotificationScheduler(transport: fake.transport)
        let plan = [notification(after: 0.5)]
        let report = try await scheduler.sync(owner, revision: 1, plan: plan, now: { now }, clock: TestClock<Duration>())
        _ = try await scheduler.sync(owner, revision: 2, plan: plan, now: { now }, clock: TestClock<Duration>())
        #expect(report.imminentUnconfirmed == 1)
        #expect(report.confirmedFuture == 0)
        #expect(report.expired == 0)
        #expect(!report.isClean)
        #expect(fake.added.count == 1)
    }

    @Test(arguments: OwnerEnding.allCases)
    func test_end_lateAddCompletion_removesOnlyEndedPhysicalIdentifier(ending: OwnerEnding) async throws {
        let fake = NotificationFake()
        fake.holdsAdd = true
        let scheduler = NotificationScheduler(transport: fake.transport)
        let operation = Task {
            try await scheduler.sync(owner, revision: 1, plan: [notification(after: 10)], now: { now }, clock: TestClock<Duration>())
        }
        await fake.waitForAdd()
        ending.fire(scheduler, owner: owner)
        let oldID = try #require(fake.added.first)
        fake.completeAdds()
        let report = try await operation.value
        #expect(report.superseded)
        #expect(fake.removed.contains(oldID))
        #expect(fake.removedDelivered.contains(oldID))
        let afterEnd = try await scheduler.sync(
            owner,
            revision: 2,
            plan: [notification(after: 20)],
            now: { now },
            clock: TestClock<Duration>()
        )
        #expect(afterEnd.superseded)
        #expect(fake.added.count == 1)
    }

    @Test
    func test_cleanup_lateSnapshot_preservesRegisteredOwner() async throws {
        let fake = NotificationFake()
        fake.holdsPending = true
        let scheduler = NotificationScheduler(transport: fake.transport)
        let cleanup = Task { try await scheduler.removeOrphans(clock: TestClock<Duration>()) }
        await fake.waitForPending()
        let sync = Task {
            try await scheduler.sync(owner, revision: 1, plan: [notification(after: 10)], now: { now }, clock: TestClock<Duration>())
        }
        await fake.waitForAdd()
        fake.completePending()
        #expect(try await cleanup.value)
        #expect(try await sync.value.isClean)
        #expect(fake.removed.isEmpty)
    }

    @Test(arguments: [-1.0, 0.0])
    func test_sync_expiredEvent_doesNotMoveItIntoTheFuture(interval: TimeInterval) async throws {
        let fake = NotificationFake()
        let scheduler = NotificationScheduler(transport: fake.transport)
        let report = try await scheduler.sync(
            owner, revision: 1, plan: [notification(after: interval)], now: { now }, clock: TestClock<Duration>()
        )
        #expect(fake.added.isEmpty)
        #expect(report.expired == 1)
        #expect(report.confirmedFuture == 0)
        #expect(report.isClean)
    }

    @Test
    func test_sync_failedAdd_recoveryRequiresVerifiedRetry() async throws {
        let fake = NotificationFake()
        fake.addFailure = .system("Rejected")
        let scheduler = NotificationScheduler(transport: fake.transport)
        let plan = [notification(after: 10)]
        let failed = try await scheduler.sync(owner, revision: 1, plan: plan, now: { now }, clock: TestClock<Duration>())
        #expect(failed.failed == 1)
        #expect(failed.confirmedFuture == 0)
        #expect(!failed.isClean)
        fake.addFailure = nil
        let recovered = try await scheduler.sync(owner, revision: 2, plan: plan, now: { now }, clock: TestClock<Duration>())
        #expect(recovered.isClean)
        #expect(recovered.confirmedFuture == 1)
        #expect(Set(fake.added).count == 2)
    }

    @Test
    func test_cleanup_unresolvedSweep_rateLimitsNewReadsForThirtySeconds() async throws {
        let fake = NotificationFake()
        fake.holdsPending = true
        let clock = TestClock<Duration>()
        let scheduler = NotificationScheduler(transport: fake.transport)
        let first = Task { try await scheduler.removeOrphans(clock: clock) }
        await fake.waitForPending()
        await clock.advance(by: .milliseconds(500))
        #expect(try await first.value == false)
        let retry = Task { try await scheduler.removeOrphans(clock: clock) }
        await clock.advance(by: .milliseconds(500))
        #expect(try await retry.value == false)
        #expect(fake.pendingReads == 1)
        #expect(fake.deliveredReads == 1)
        await clock.advance(by: .seconds(29))
        let renewed = Task { try await scheduler.removeOrphans(clock: clock) }
        await fake.waitForPending(count: 2)
        #expect(fake.pendingReads == 2)
        #expect(fake.deliveredReads == 2)
        fake.completePending()
        #expect(try await renewed.value)
    }

    @Test
    func test_sync_emptyPlan_clearsWithoutWaitingForSettings() async throws {
        let fake = NotificationFake()
        let scheduler = NotificationScheduler(transport: fake.transport)
        _ = try await scheduler.sync(owner, revision: 1, plan: [notification(after: 10)], now: { now }, clock: TestClock<Duration>())
        let oldID = try #require(fake.added.first)
        fake.holdsSettings = true
        let report = try await scheduler.sync(owner, revision: 2, plan: [], now: { now }, clock: TestClock<Duration>())
        #expect(report.isClean)
        #expect(fake.removed.contains(oldID))
        #expect(fake.settingsReads == 1)
    }

    @Test
    func test_sync_changedPlan_retiresOldRequestsBeforeSettingsRespond() async throws {
        let fake = NotificationFake()
        let scheduler = NotificationScheduler(transport: fake.transport)
        _ = try await scheduler.sync(owner, revision: 1, plan: [notification(after: 10)], now: { now }, clock: TestClock<Duration>())
        let oldID = try #require(fake.added.first)
        fake.holdsSettings = true
        let operation = Task {
            try await scheduler.sync(owner, revision: 2, plan: [notification(after: 20)], now: { now }, clock: TestClock<Duration>())
        }
        await fake.waitForSettings(count: 2)
        #expect(fake.removed.contains(oldID))
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
    }

    @Test(arguments: [false, true])
    func test_sync_naturalBoundary_leavesJustDueRequestForDelivery(untilEmptyPlan: Bool) async throws {
        let fake = NotificationFake()
        let scheduler = NotificationScheduler(transport: fake.transport)
        _ = try await scheduler.sync(
            owner,
            revision: 1,
            plan: [notification(after: 10)],
            now: { now },
            clock: TestClock<Duration>()
        )
        let dueID = try #require(fake.added.first)
        let boundary = now.addingTimeInterval(10)
        let report = try await scheduler.sync(
            owner,
            revision: 2,
            plan: untilEmptyPlan ? [] : [notification(after: 20)],
            now: { boundary },
            clock: TestClock<Duration>()
        )
        #expect(report.expired == 1)
        #expect(report.confirmedFuture == (untilEmptyPlan ? 0 : 1))
        #expect(!fake.removed.contains(dueID))
        scheduler.end(owner)
        #expect(fake.removed.contains(dueID))
    }

    @Test
    func test_sync_dueRequestLateCallback_doesNotCancelNaturalDelivery() async throws {
        let fake = NotificationFake()
        fake.holdsAdd = true
        let scheduler = NotificationScheduler(transport: fake.transport)
        let wall = LockIsolated(now)
        let first = Task {
            try await scheduler.sync(owner, revision: 1, plan: [notification(after: 10)], now: { wall.value }, clock: TestClock<Duration>())
        }
        await fake.waitForAdd()
        let dueID = try #require(fake.added.first)
        let boundary = now.addingTimeInterval(10)
        wall.setValue(boundary)
        _ = try await scheduler.sync(owner, revision: 2, plan: [], now: { wall.value }, clock: TestClock<Duration>())
        fake.completeAdds()
        #expect(try await first.value.superseded)
        #expect(!fake.removed.contains(dueID))
        scheduler.end(owner)
        #expect(fake.removed.contains(dueID))
    }

    @Test
    func test_sync_pendingSnapshotAfterBoundary_countsExpiredWithoutCancellingDelivery() async throws {
        let fake = NotificationFake()
        fake.holdsPending = true
        let wall = LockIsolated(now)
        let scheduler = NotificationScheduler(transport: fake.transport)
        let operation = Task {
            try await scheduler.sync(owner, revision: 1, plan: [notification(after: 10)], now: { wall.value }, clock: TestClock<Duration>())
        }
        await fake.waitForAdd()
        wall.setValue(now.addingTimeInterval(10))
        fake.completePending()
        let report = try await operation.value
        let dueID = try #require(fake.added.first)
        #expect(report.expired == 1)
        #expect(report.confirmedFuture == 0)
        #expect(!fake.removed.contains(dueID))
    }

    @Test
    func test_sync_pendingSnapshotMissing_doesNotConfirmFutureCoverage() async throws {
        let fake = NotificationFake()
        fake.holdsPending = true
        let clock = TestClock<Duration>()
        let scheduler = NotificationScheduler(transport: fake.transport)
        let operation = Task {
            try await scheduler.sync(owner, revision: 1, plan: [notification(after: 10)], now: { now }, clock: clock)
        }
        await fake.waitForPending(count: 2)
        await clock.advance(by: .milliseconds(500))
        let report = try await operation.value
        #expect(!report.isVerified)
        #expect(report.confirmedFuture == 0)
        #expect(report.expired == 0)
        #expect(!report.isClean)
        fake.completePending()
    }

    private func notification(after seconds: TimeInterval) -> ScheduledNotification {
        ScheduledNotification(key: "stage-1", fireDate: now.addingTimeInterval(seconds), title: "Workout", body: "Work", isAudible: true)
    }
}
