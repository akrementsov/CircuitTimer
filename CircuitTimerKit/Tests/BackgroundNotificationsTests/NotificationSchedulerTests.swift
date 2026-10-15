@testable import BackgroundNotifications

import Dependencies
import Foundation
import os
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

    @Test
    func test_end_lateAddCompletion_removesOnlyEndedPhysicalIdentifier() async throws {
        let fake = NotificationFake()
        fake.holdsAdd = true
        let scheduler = NotificationScheduler(transport: fake.transport)
        let operation = Task {
            try await scheduler.sync(owner, revision: 1, plan: [notification(after: 10)], now: { now }, clock: TestClock<Duration>())
        }
        await fake.waitForAdd()
        scheduler.end(owner)
        let oldID = try #require(fake.added.first)
        fake.completeAdds()
        let report = try await operation.value
        #expect(report.superseded)
        #expect(fake.removed.contains(oldID))
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

    @Test
    func test_sync_expiredEvent_doesNotMoveItIntoTheFuture() async throws {
        let fake = NotificationFake()
        let scheduler = NotificationScheduler(transport: fake.transport)
        let report = try await scheduler.sync(
            owner, revision: 1, plan: [notification(after: -1)], now: { now }, clock: TestClock<Duration>()
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
        await clock.advance(by: .seconds(29))
        let renewed = Task { try await scheduler.removeOrphans(clock: clock) }
        await fake.waitForPending(count: 2)
        #expect(fake.pendingReads == 2)
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

private final class NotificationFake: Sendable {
    private struct State {
        var added: [String] = []
        var pending: Set<String> = []
        var removed: [String] = []
        var recordsPending = true
        var holdsAdd = false
        var holdsPending = false
        var pendingReads = 0
        var pendingWaitCount = 1
        var holdsSettings = false
        var settingsReads = 0
        var settingsWaitCount = 1
        var settingsWaiter: AsyncStream<Void>.Continuation?
        var addFailure: NotificationFailure?
        var addCallbacks: [@Sendable (Result<Void, NotificationFailure>) -> Void] = []
        var pendingCallbacks: [@Sendable ([String]) -> Void] = []
        var addWaiter: AsyncStream<Void>.Continuation?
        var pendingWaiter: AsyncStream<Void>.Continuation?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var added: [String] { state.withLock { $0.added } }
    var removed: [String] { state.withLock { $0.removed } }
    var settingsReads: Int { state.withLock { $0.settingsReads } }
    var holdsSettings: Bool {
        get { state.withLock { $0.holdsSettings } }
        set { state.withLock { $0.holdsSettings = newValue } }
    }
    var pendingReads: Int { state.withLock { $0.pendingReads } }
    var addFailure: NotificationFailure? {
        get { state.withLock { $0.addFailure } }
        set { state.withLock { $0.addFailure = newValue } }
    }
    var recordsPending: Bool {
        get { state.withLock { $0.recordsPending } }
        set { state.withLock { $0.recordsPending = newValue } }
    }
    var holdsAdd: Bool {
        get { state.withLock { $0.holdsAdd } }
        set { state.withLock { $0.holdsAdd = newValue } }
    }
    var holdsPending: Bool {
        get { state.withLock { $0.holdsPending } }
        set { state.withLock { $0.holdsPending = newValue } }
    }
    var transport: NotificationTransport {
        NotificationTransport(
            settings: { [self] callback in
                let held = state.withLock { state in
                    state.settingsReads += 1
                    if state.settingsReads >= state.settingsWaitCount { state.settingsWaiter?.yield(()) }
                    return state.holdsSettings
                }
                if !held { callback(.authorized) }
            },
            authorize: { $0(.success(())) },
            add: { [self] id, _, _, _, callback in
                let (held, failure) = state.withLock { state in
                    state.added.append(id)
                    if state.recordsPending && state.addFailure == nil { state.pending.insert(id) }
                    state.addWaiter?.yield(())
                    if state.holdsAdd { state.addCallbacks.append(callback) }
                    return (state.holdsAdd, state.addFailure)
                }
                if !held {
                    if let failure { callback(.failure(failure)) } else { callback(.success(())) }
                }
            },
            pending: { [self] callback in
                let result = state.withLock { state -> [String]? in
                    state.pendingReads += 1
                    if state.pendingReads >= state.pendingWaitCount { state.pendingWaiter?.yield(()) }
                    if state.holdsPending { state.pendingCallbacks.append(callback); return nil }
                    return Array(state.pending)
                }
                if let result { callback(result) }
            },
            delivered: { $0([]) },
            removePending: { [self] ids in state.withLock { $0.removed += ids; $0.pending.subtract(ids) } },
            removeDelivered: { _ in }
        )
    }
    func completeAdds() {
        let callbacks = state.withLock { state in
            let callbacks = state.addCallbacks
            state.addCallbacks = []
            return callbacks
        }
        for callback in callbacks { callback(.success(())) }
    }
    func completePending() {
        let (callbacks, ids) = state.withLock { state in
            let callbacks = state.pendingCallbacks
            state.pendingCallbacks = []
            state.holdsPending = false
            return (callbacks, Array(state.pending))
        }
        for callback in callbacks { callback(ids) }
    }
    func waitForAdd() async {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        state.withLock { state in
            state.addWaiter = pair.continuation
            if !state.added.isEmpty { pair.continuation.yield(()) }
        }
        for await _ in pair.stream { break }
    }
    func waitForSettings(count: Int) async {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        state.withLock { state in
            state.settingsWaiter = pair.continuation
            state.settingsWaitCount = count
            if state.settingsReads >= count { pair.continuation.yield(()) }
        }
        for await _ in pair.stream { break }
    }
    func waitForPending(count: Int = 1) async {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        state.withLock { state in
            state.pendingWaiter = pair.continuation
            state.pendingWaitCount = count
            if state.pendingReads >= count { pair.continuation.yield(()) }
        }
        for await _ in pair.stream { break }
    }
}
