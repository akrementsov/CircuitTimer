@testable import WorkoutTimerFeature

import BackgroundNotifications
import ComposableArchitecture
import Foundation
import Testing
import WorkoutActivity
import WorkoutDomain
import WorkoutStorage

@MainActor
@Suite
struct TimerActivitySettlementTests {
    enum Rejection: CaseIterable, Sendable {
        case staleBoundary, staleBackwardJump, notReady, busy
    }

    @Test(arguments: Rejection.allCases)
    func test_rejectedCommand_elapsedTime_commitsProgressAndKeepsItsOwnOutcome(rejection: Rejection) async {
        let backward = rejection == .staleBackwardJump
        let schedule = backward ? Schedules.workRest : Schedules.withPause
        var state = WorkoutTimerFeature.State.fixture(.running, schedule: schedule, elapsed: backward ? 3 : 1)
        state.activityControls = WorkoutTimerFeature.ActivityControlState(isReady: rejection != .notReady, generation: 7)
        if rejection == .busy {
            state.activityControls?.pending = WorkoutTimerFeature.PendingActivityControl(id: 16, result: .stale)
            state.notifications.revision = 2
        }
        let timer = TimerHarness(state)
        timer.store.dependencies.continuousClock = SuspendingClock(base: timer.clock)
        let activity = timer.recordActivity()
        let gate = AsyncStream<Void>.makeStream()
        let write = timer.store.dependencies.workoutRunRecord.write
        timer.store.dependencies.workoutRunRecord.write = { record, revision in
            for await _ in gate.stream { break }
            try await write(record, revision)
        }
        let results = LockIsolated<[LiveActivityControlResult]>([])
        timer.store.dependencies.liveActivity.requestHandled = { _, id, result in
            #expect(id == 17)
            results.withValue { $0.append(result) }
        }
        if backward {
            await timer.clock.advance(by: .seconds(1))
            timer.moveWall(seconds: -1)
        } else {
            await timer.advance(seconds: 2)
        }
        let effect = await timer.store.send(.internal(.activityRequestReceived(.init(id: 17, command: .pause, generation: 6)))) {
            if backward { $0.run.rebase(at: timer.now, keepingTotalElapsed: .seconds(4)) }
            $0.settle(at: timer.now)
            $0.clockGeneration = 2
            $0.clockAnchor = backward ? timer.anchor(totalElapsed: .seconds(4)) : nil
            if !backward {
                $0.requestedAwake = false
                $0.awakeRevision = 2
                $0.activityControls?.generation = 8
            }
            if rejection == .busy {
                $0.activityControls?.pending?.activityRevision = 1
                $0.activityControls?.pending?.notificationRevision = 2
            } else if rejection != .notReady {
                $0.activityControls?.pending = WorkoutTimerFeature.PendingActivityControl(id: 17, result: .stale, activityRevision: 1)
            }
            $0.recordSync = .pending(revision: 1, record: WorkoutRunRecord(workoutID: $0.workoutID, run: $0.run))
        }
        if rejection != .notReady {
            await timer.receive(.internal(.activitySynchronized(revision: 1, .init(outcome: .applied)))) {
                if rejection == .busy {
                    $0.activityControls?.pending?.activityResult = .applied
                } else {
                    $0.activityControls?.pending = nil
                }
            }
        }
        gate.continuation.finish()
        await timer.recordSaved(revision: 1)
        await effect.cancel()
        await timer.store.finish()
        let expected: LiveActivityControlResult = rejection == .notReady ? .unavailable : rejection == .busy ? .busy : .stale
        #expect(results.value == [expected])
        #expect(timer.store.state.snapshot.totalElapsed == .seconds(backward ? 4 : 2))
        #expect(timer.store.state.snapshot.status == (backward ? .running : .awaitingUser))
        #expect(timer.writes.value.count == 1)
        #expect(activity.syncs.value.isEmpty == (rejection == .notReady))
    }

    @Test
    func test_ack_supersededNotifications_waitsForTheNewestWindow() async {
        var state = WorkoutTimerFeature.State.fixture(.running)
        state.$isSoundOn = SharedReader(value: false)
        state.notifications.access = .authorized
        state.notifications.projection = state.notificationProjection(at: origin, language: "en")
        state.notifications.revision = 1
        state.activityControls = WorkoutTimerFeature.ActivityControlState(isReady: true, generation: 8)
        state.activityControls?.pending = WorkoutTimerFeature.PendingActivityControl(
            id: 17, result: .applied, activityRevision: 1, activityResult: .applied, notificationRevision: 1
        )
        // A changed preference needs a newer window before the admitted command can be acknowledged.
        state.$isSoundOn = SharedReader(value: true)
        let timer = TimerHarness(state, signals: true, notifications: true)
        _ = timer.recordActivity()
        let gate = AsyncStream<Void>.makeStream()
        timer.store.dependencies.backgroundNotifications.access = { throw CancellationError() }
        timer.store.dependencies.backgroundNotifications.sync = { _, revision, _ in
            #expect(revision == 2)
            for await _ in gate.stream { break }
            return NotificationSyncReport()
        }
        let results = LockIsolated<[LiveActivityControlResult]>([])
        timer.store.dependencies.liveActivity.requestHandled = { _, id, result in
            #expect(id == 17)
            results.withValue { $0.append(result) }
        }
        await timer.send(.view(.notificationPreferencesChanged)) {
            $0.notifications.accessGeneration = 1
            $0.notifications.projection = $0.notificationProjection(at: origin, language: "en")
            $0.notifications.revision = 2
            $0.notifications.lastAttempt = MonotonicInstant(now: timer.clock)
            $0.activityControls?.pending?.notificationRevision = 2
        }
        await timer.send(.internal(.notificationsSynced(revision: 1, report: NotificationSyncReport())))
        #expect(timer.store.state.activityControls?.pending != nil)
        #expect(results.value.isEmpty)
        gate.continuation.finish()
        await timer.receive(.internal(.notificationsSynced(revision: 2, report: NotificationSyncReport()))) {
            $0.activityControls?.pending = nil
        }
        await timer.store.finish()
        #expect(results.value == [.applied])
    }

    @Test
    func test_countdownDigitAndSceneChanges_keepTheRenderedGeneration() async {
        var state = WorkoutTimerFeature.State.fixture(.resumeCountdown)
        state.activityControls = WorkoutTimerFeature.ActivityControlState(isReady: true, generation: 7)
        let timer = TimerHarness(state)
        let activity = timer.recordActivity()
        await timer.send(.internal(.countdownTicked(generation: 1))) { $0.countdown?.remaining = 2 }
        await timer.send(.view(.scenePhaseChanged(.inactive)))
        await timer.send(.view(.scenePhaseChanged(.background)), saving: true) {
            $0.isInBackground = true
            $0.countdown?.remaining = 3
            $0.clockGeneration = 2
        }
        await timer.store.finish()
        #expect(!activity.syncs.value.isEmpty)
        #expect(activity.syncs.value.allSatisfy { $0.content.controlGeneration == 7 })
    }
}
