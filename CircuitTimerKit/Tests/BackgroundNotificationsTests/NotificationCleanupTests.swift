@testable import BackgroundNotifications

import Dependencies
import Foundation
import os
import Testing

struct NotificationCleanupTests: Sendable {
    private let owner = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))

    @Test
    func test_cleanup_prefixAndOwner_removesOnlyOrphanPendingAndDelivered() async throws {
        let fake = NotificationFake()
        let scheduler = NotificationScheduler(transport: fake.transport)
        _ = try await scheduler.sync(owner, revision: 1, plan: [], now: { .distantPast }, clock: TestClock<Duration>())
        let ended = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))
        let unknown = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3))
        scheduler.end(ended)
        let activeID = "ct.cue.\(owner.uuidString).stage-1.1"
        let orphans: Set<String> = ["ct.cue.\(ended.uuidString).stage-1.1", "ct.cue.\(unknown.uuidString).stage-1.1", "ct.cue.invalid"]
        let retained: Set<String> = [activeID, "foreign.identifier"]
        fake.pendingIdentifiers = orphans.union(retained)
        fake.deliveredIdentifiers = orphans.union(retained)
        #expect(try await scheduler.removeOrphans(clock: TestClock<Duration>()))
        #expect(Set(fake.removed) == orphans)
        #expect(Set(fake.removedDelivered) == orphans)
        #expect(fake.pendingIdentifiers == retained)
        #expect(fake.deliveredIdentifiers == retained)
    }

    @Test(arguments: [false, true])
    func test_cleanup_sharedSweep_cancellingOneWaiterDoesNotCancelOther(cancelFirst: Bool) async throws {
        try await withMainSerialExecutor {
            let fake = NotificationFake()
            fake.holdsPending = true
            fake.holdsDelivered = true
            let scheduler = NotificationScheduler(transport: fake.transport)
            let clock = WaiterRegistrationClock()
            let secondFinished = LockIsolated(false)
            let firstFinished = LockIsolated(false)
            let first = Task {
                let result = try await scheduler.removeOrphans(clock: clock)
                firstFinished.setValue(true)
                return result
            }
            let second = Task {
                let result = try await scheduler.removeOrphans(clock: clock)
                secondFinished.setValue(true)
                return result
            }
            await fake.waitForPending()
            await fake.waitForDelivered()
            await clock.waitForSleeps(2)
            #expect(fake.pendingReads == 1)
            #expect(fake.deliveredReads == 1)
            if cancelFirst {
                first.cancel()
                await #expect(throws: CancellationError.self) { try await first.value }
            }
            #expect(!secondFinished.value)
            fake.completePending()
            await Task.megaYield()
            #expect(!firstFinished.value)
            #expect(!secondFinished.value)
            fake.completeDelivered()
            #expect(try await second.value)
            if !cancelFirst { #expect(try await first.value) }
            #expect(cancelFirst || firstFinished.value)
            try await clock.checkSuspension()
        }
    }

    @Test
    func test_cleanup_completedSweep_reusesResultUntilThirtySeconds() async throws {
        let fake = NotificationFake()
        let scheduler = NotificationScheduler(transport: fake.transport)
        let clock = TestClock<Duration>()
        #expect(try await scheduler.removeOrphans(clock: clock))
        #expect(try await scheduler.removeOrphans(clock: clock))
        #expect(fake.pendingReads == 1)
        #expect(fake.deliveredReads == 1)
        await clock.advance(by: .seconds(30))
        #expect(try await scheduler.removeOrphans(clock: clock))
        #expect(fake.pendingReads == 2)
        #expect(fake.deliveredReads == 2)
    }

    @Test(arguments: [false, true])
    func test_sync_planPresence_startsSweepOnlyForNonemptyPlan(hasPlan: Bool) async throws {
        let fake = NotificationFake()
        let scheduler = NotificationScheduler(transport: fake.transport)
        let now = Date(timeIntervalSince1970: 1_000)
        let event = ScheduledNotification(
            key: "finish", fireDate: now.addingTimeInterval(10), title: "Workout", body: "Done", isAudible: false
        )
        let report = try await scheduler.sync(owner, revision: 1, plan: hasPlan ? [event] : [], now: { now }, clock: TestClock<Duration>())
        #expect(report.isClean)
        #expect(fake.pendingReads == (hasPlan ? 2 : 0))
        #expect(fake.deliveredReads == (hasPlan ? 1 : 0))
    }
}

private final class WaiterRegistrationClock: Clock {
    typealias Duration = Swift.Duration
    typealias Instant = TestClock<Duration>.Instant

    private struct State {
        var sleepCount = 0
        var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let base = TestClock<Duration>()
    private let state = OSAllocatedUnfairLock(initialState: State())

    var now: Instant { base.now }
    var minimumResolution: Duration { base.minimumResolution }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let ready = state.withLock { state in
            state.sleepCount += 1
            let ready = state.waiters.filter { $0.count <= state.sleepCount }.map(\.continuation)
            state.waiters.removeAll { $0.count <= state.sleepCount }
            return ready
        }
        for continuation in ready { continuation.resume() }
        try await base.sleep(until: deadline, tolerance: tolerance)
    }

    func waitForSleeps(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                guard state.sleepCount < count else { return true }
                state.waiters.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func checkSuspension() async throws {
        try await base.checkSuspension()
    }
}
