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
struct TimerActivityLifecycleTests {
    @Test(arguments: [false, true])
    func test_pause_atAStageBoundary_usesTheSettledPhase(manualPause: Bool) async {
        let schedule = manualPause ? Schedules.withPause : Schedules.workRest
        let elapsed = manualPause ? 1.0 : 9.0
        var state = WorkoutTimerFeature.State.fixture(.running, schedule: schedule, elapsed: elapsed)
        state.activityControls = WorkoutTimerFeature.ActivityControlState(isReady: true, generation: 7)
        let timer = TimerHarness(state)
        let activity = timer.recordActivity()
        let acknowledgements = recordAcknowledgements(timer)
        let writes = holdRecordWrites(timer)
        await timer.advance(seconds: 2)

        let effect = await timer.store.send(.internal(.activityRequestReceived(.init(id: 17, command: .pause, generation: 7)))) {
            $0.settle(at: timer.now)
            if !manualPause { $0.run.pause(at: timer.now); $0.settle(at: timer.now) }
            $0.clockGeneration = 2
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 2
            $0.activityControls?.generation = 8
            $0.activityControls?.pending = WorkoutTimerFeature.PendingActivityControl(
                id: 17, result: manualPause ? .stale : .applied, activityRevision: 1
            )
            $0.recordSync = .pending(revision: 1, record: WorkoutRunRecord(workoutID: $0.workoutID, run: $0.run))
            $0.followHealth(at: timer.now)
        }
        await timer.receive(.internal(.activitySynchronized(revision: 1, .init(outcome: .applied)))) {
            $0.activityControls?.pending = nil
        }
        writes.finish()
        await timer.recordSaved(revision: 1)
        await effect.cancel()
        await timer.store.finish()
        #expect(acknowledgements.value == [manualPause ? .stale : .applied])
        #expect(timer.store.state.snapshot.currentStage?.index == 1)
        #expect(timer.store.state.snapshot.status == (manualPause ? .awaitingUser : .paused))
        #expect(activity.syncs.value.last?.content.controlGeneration == 8)
    }

    @Test
    func test_activityTask_liveSubscription_doesNotRegisterAgainOrResetPending() async {
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.activityControls = WorkoutTimerFeature.ActivityControlState(isReady: true, generation: 7)
        state.notifications.revision = 2
        state.activityControls?.pending = WorkoutTimerFeature.PendingActivityControl(
            id: 17, result: .applied, activityRevision: 1, activityResult: .applied, notificationRevision: 2
        )
        let timer = TimerHarness(state)
        _ = timer.recordActivity()
        timer.store.dependencies.liveActivity.requests = { _ in
            Issue.record("A live subscription must not register again.")
            return AsyncStream { $0.finish() }
        }
        let acknowledgements = recordAcknowledgements(timer)
        await timer.send(.view(.activityTask))
        await timer.store.finish()
        #expect(timer.store.state.activityControls == state.activityControls)
        #expect(acknowledgements.value.isEmpty)
    }

    enum Admission: CaseIterable, Sendable {
        case notReady, ending, busy
    }

    @Test(arguments: Admission.allCases)
    func test_command_unavailableOrBusy_preservesTheFirstCommand(admission: Admission) async {
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.activityControls = WorkoutTimerFeature.ActivityControlState(
            isReady: admission != .notReady, isEnding: admission == .ending, generation: 7
        )
        if admission == .busy {
            state.notifications.revision = 2
            state.activityControls?.pending = WorkoutTimerFeature.PendingActivityControl(
                id: 16, result: .applied, notificationRevision: 2
            )
        }
        let timer = TimerHarness(state)
        _ = timer.recordActivity()
        let acknowledgements = recordAcknowledgements(timer)
        let action = WorkoutTimerFeature.Action.internal(.activityRequestReceived(.init(id: 17, command: .resume, generation: 7)))
        if admission == .busy {
            await timer.send(action) { $0.activityControls?.pending?.activityRevision = 1 }
        } else {
            await timer.send(action)
        }
        if admission == .busy {
            await timer.receive(.internal(.activitySynchronized(revision: 1, .init(outcome: .applied)))) {
                $0.activityControls?.pending?.activityResult = .applied
            }
        }
        await timer.store.finish()
        #expect(acknowledgements.value == [admission == .busy ? .busy : .unavailable])
        #expect(timer.store.state.activityControls?.pending?.id == (admission == .busy ? 16 : nil))
        #expect(timer.store.state.snapshot.status == .paused)
        #expect(timer.writes.value.isEmpty)
    }

    @Test(arguments: [false, true])
    func test_activityRequestsEnded_clearsReadinessAndReleasesOnlyAnExistingRequest(hasPending: Bool) async {
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.activityControls = WorkoutTimerFeature.ActivityControlState(isReady: true, generation: 7)
        if hasPending { state.activityControls?.pending = WorkoutTimerFeature.PendingActivityControl(id: 17, result: .applied) }
        let timer = TimerHarness(state)
        let activity = timer.recordActivity()
        let acknowledgements = recordAcknowledgements(timer)
        await timer.send(.internal(.activityRequestsEnded)) {
            $0.activityControls?.isReady = false
            $0.activityControls?.pending = nil
        }
        await timer.store.finish()
        #expect(acknowledgements.value == (hasPending ? [.unavailable] : []))
        #expect(activity.syncs.value.isEmpty)
        #expect(timer.writes.value.isEmpty)
    }

    @Test(arguments: [
        LiveActivitySyncResult(outcome: .failed, notice: .init(serial: 2, isFailing: true)),
        .init(outcome: .deferred),
        .init(outcome: .unavailable, notice: .init(serial: 2, isFailing: false)),
    ])
    func test_resume_appliedButActivitySyncFails_preservesTheRunAndActualNotice(result: LiveActivitySyncResult) async {
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.liveActivityNotice = LiveActivityNotice(serial: 1, isFailing: true)
        state.activityControls = WorkoutTimerFeature.ActivityControlState(isReady: true, generation: 7)
        let timer = TimerHarness(state)
        _ = timer.recordActivity()
        let sync = timer.store.dependencies.liveActivity.syncWithResult
        timer.store.dependencies.liveActivity.syncWithResult = { owner, revision, attributes, content in
            _ = await sync(owner, revision, attributes, content)
            return result
        }
        let writes = holdRecordWrites(timer)
        let acknowledgements = recordAcknowledgements(timer)
        timer.store.dependencies.continuousClock = SuspendingClock(base: timer.clock)
        let effect = await timer.store.send(.internal(.activityRequestReceived(.init(id: 17, command: .resume, generation: 7)))) {
            $0.run.resume(at: origin)
            $0.settle(at: origin)
            $0.clockGeneration = 2
            $0.clockAnchor = timer.anchor(totalElapsed: $0.snapshot.totalElapsed)
            $0.requestedAwake = true
            $0.awakeRevision = 3
            $0.activityControls?.generation = 8
            $0.activityControls?.pending = WorkoutTimerFeature.PendingActivityControl(id: 17, result: .applied, activityRevision: 1)
            $0.recordSync = .pending(revision: 1, record: WorkoutRunRecord(workoutID: $0.workoutID, run: $0.run))
            $0.followHealth(at: timer.now)
        }
        await timer.receive(.internal(.activitySynchronized(revision: 1, result))) {
            $0.activityControls?.pending = nil
            if let notice = result.notice { $0.liveActivityNotice = notice }
        }
        writes.finish()
        await timer.recordSaved(revision: 1)
        await effect.cancel()
        await timer.store.finish()
        #expect(timer.store.state.snapshot.status == .running)
        #expect(timer.store.state.liveActivityNotice == (result.notice ?? state.liveActivityNotice))
        #expect(acknowledgements.value == [result.outcome == .unavailable ? .unavailable : .failed])
    }

    @Test(arguments: [false, true], [LiveActivityCommand.pause, .resume])
    func test_command_offscreenWithSignalsEnabled_staysSilent(inBackground: Bool, command: LiveActivityCommand) async {
        var state = WorkoutTimerFeature.State.fixture(command == .pause ? .running : .paused)
        state.isInBackground = inBackground
        state.$isSoundOn = SharedReader(value: true)
        state.$isVibrationOn = SharedReader(value: true)
        state.$isSpeechOn = SharedReader(value: true)
        state.activityControls = WorkoutTimerFeature.ActivityControlState(isReady: true, generation: 7)
        let timer = TimerHarness(state, signals: true)
        _ = timer.recordActivity()
        let writes = holdRecordWrites(timer)
        let acknowledgements = recordAcknowledgements(timer)
        let bursts = LockIsolated<[CueBurst]>([])
        timer.store.dependencies.cues.play = { burst in
            bursts.withValue { $0.append(burst) }
            return CueResult()
        }
        let effect = await timer.store.send(.internal(.activityRequestReceived(.init(id: 17, command: command, generation: 7)))) {
            if command == .pause { $0.run.pause(at: origin) } else { $0.run.resume(at: origin) }
            $0.settle(at: origin)
            $0.clockGeneration = 2
            $0.clockAnchor = command == .pause ? nil : timer.anchor(totalElapsed: $0.snapshot.totalElapsed)
            $0.requestedAwake = command == .resume
            $0.awakeRevision = command == .pause ? 2 : 3
            $0.activityControls?.generation = 8
            $0.activityControls?.pending = WorkoutTimerFeature.PendingActivityControl(id: 17, result: .applied, activityRevision: 1)
            $0.recordSync = .pending(revision: 1, record: WorkoutRunRecord(workoutID: $0.workoutID, run: $0.run))
            $0.followHealth(at: timer.now)
        }
        await timer.receive(.internal(.activitySynchronized(revision: 1, .init(outcome: .applied)))) {
            $0.activityControls?.pending = nil
        }
        writes.finish()
        await timer.recordSaved(revision: 1)
        await effect.cancel()
        await timer.store.finish()
        #expect(acknowledgements.value == [.applied])
        #expect(bursts.value.isEmpty)
        #expect(timer.store.state.haptic == nil)
        #expect(timer.store.state.signals.cueRevision == 0)
    }

    @Test
    func test_activitySync_cancelledBeforeItsResponse_doesNotSendOrAcknowledgeTheResponse() async {
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.activityControls = WorkoutTimerFeature.ActivityControlState(isReady: true, generation: 7)
        let timer = TimerHarness(state)
        _ = timer.recordActivity()
        let gate = holdActivitySync(timer)
        let acknowledgements = recordAcknowledgements(timer)
        let effect = await timer.store.send(.internal(.activityRequestReceived(.init(id: 17, command: .pause, generation: 7)))) {
            $0.activityControls?.pending = WorkoutTimerFeature.PendingActivityControl(id: 17, result: .stale, activityRevision: 1)
        }
        var arrivals = gate.entered.makeAsyncIterator()
        _ = await arrivals.next()
        await effect.cancel()
        gate.release.finish()
        await timer.store.finish()
        #expect(acknowledgements.value.isEmpty)
    }

    private func holdRecordWrites(_ timer: TimerHarness) -> AsyncStream<Void>.Continuation {
        let gate = AsyncStream<Void>.makeStream()
        let write = timer.store.dependencies.workoutRunRecord.write
        timer.store.dependencies.workoutRunRecord.write = { record, revision in
            for await _ in gate.stream { break }
            try await write(record, revision)
        }
        return gate.continuation
    }

    private func recordAcknowledgements(_ timer: TimerHarness) -> LockIsolated<[LiveActivityControlResult]> {
        let results = LockIsolated<[LiveActivityControlResult]>([])
        timer.store.dependencies.liveActivity.requestHandled = { owner, requestID, result in
            #expect(owner == timerID)
            #expect(requestID == 17)
            results.withValue { $0.append(result) }
        }
        return results
    }

    private func holdActivitySync(_ timer: TimerHarness) -> (entered: AsyncStream<Void>, release: AsyncStream<Void>.Continuation) {
        let gate = AsyncStream<Void>.makeStream()
        let entered = AsyncStream<Void>.makeStream()
        let sync = timer.store.dependencies.liveActivity.syncWithResult
        timer.store.dependencies.liveActivity.syncWithResult = { owner, revision, attributes, content in
            entered.continuation.yield()
            for await _ in gate.stream { break }
            return await sync(owner, revision, attributes, content)
        }
        return (entered.stream, gate.continuation)
    }
}
