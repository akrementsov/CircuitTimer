@testable import WorkoutTimerFeature

import BackgroundNotifications
import ComposableArchitecture
import Foundation
import Testing
import WorkoutActivity
import WorkoutDomain

@MainActor
@Suite
struct TimerActivityControlTests {
    @Test
    func test_resumeCountdown_thenAnotherManualPause_invalidatesTheOldResumeCard() async throws {
        var state = WorkoutTimerFeature.State.fixture(.resumeCountdown, schedule: Schedules.withPause, elapsed: 1)
        state.countdown?.remaining = 1
        let timer = TimerHarness(state, activity: true)
        let activity = timer.recordActivity()
        await timer.send(.view(.notificationPreferencesChanged))
        let oldGeneration = try #require(activity.syncs.value.last?.content.controlGeneration)

        await timer.send(.internal(.countdownTicked(generation: 1)), saving: true) {
            $0.countdown = nil
            $0.activityControls?.generation += 1
            $0.run.resume(at: origin)
            $0.settle(at: origin)
            $0.clockGeneration = 2
            $0.clockAnchor = timer.anchor(totalElapsed: $0.snapshot.totalElapsed)
        }
        await timer.advance(seconds: 1)
        await timer.receive(.internal(.ticked(generation: 2, isFinal: false)), saving: true) {
            $0.settle(at: timer.now)
            $0.clockGeneration = 3
            $0.activityControls?.generation += 1
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 2
        }
        #expect(timer.store.state.snapshot.status == .awaitingUser)
        #expect(try #require(activity.syncs.value.last?.content.controlGeneration) > oldGeneration)
        let acknowledgements = AsyncStream<LiveActivityControlResult>.makeStream()
        timer.store.dependencies.liveActivity.requestHandled = { _, _, result in acknowledgements.continuation.yield(result) }
        let revision = activity.revisionsTaken.value + 1
        await timer.send(.internal(.activityRequestReceived(.init(id: 17, command: .resume, generation: oldGeneration)))) {
            $0.activityControls?.pending = WorkoutTimerFeature.PendingActivityControl(id: 17, result: .stale, activityRevision: revision)
        }
        await timer.receive(.internal(.activitySynchronized(revision: revision, .init(outcome: .applied)))) {
            $0.activityControls?.pending = nil
        }
        var iterator = acknowledgements.stream.makeAsyncIterator()
        #expect(await iterator.next() == .stale)
        #expect(timer.store.state.snapshot.status == .awaitingUser)
        #expect(timer.store.state.snapshot.currentStage?.index == 1)
        await timer.store.finish()
    }
    enum ResumeContext: CaseIterable, Sendable {
        case stageList
        case closeConfirmation
        case resumeCountdown
        case manualPause
    }

    @Test(arguments: ResumeContext.allCases)
    func test_resume_clearsPresentationAndCountdown_andRunsImmediately(context: ResumeContext) async {
        let phase: TimerPhase = switch context {
            case .resumeCountdown: .resumeCountdown
            case .manualPause: .awaitingUser
            default: .paused
        }
        var state = WorkoutTimerFeature.State.fixture(phase, schedule: context == .manualPause ? Schedules.withPause : Schedules.workRest)
        state.activityControls = WorkoutTimerFeature.ActivityControlState(isReady: true, generation: 7)
        if context == .stageList { state.path.append(.stageList(state.outline)) }
        if context == .closeConfirmation { state.destination = .closeConfirmation(.closeConfirmation(restart: nil)) }
        let timer = TimerHarness(state)
        let activity = timer.recordActivity()
        let writes = holdRecordWrites(timer)
        let acknowledgements = recordAcknowledgements(timer)

        let effect = await timer.store.send(.internal(.activityRequestReceived(.init(id: 17, command: .resume, generation: 7)))) {
            $0.countdown = nil
            $0.destination = nil
            $0.path.removeAll()
            $0.run.resume(at: origin)
            $0.settle(at: origin)
            $0.clockGeneration = 2
            $0.clockAnchor = timer.anchor(totalElapsed: $0.snapshot.totalElapsed)
            $0.requestedAwake = true
            $0.awakeRevision = context == .resumeCountdown ? 1 : 3
            $0.activityControls?.generation = 8
            $0.activityControls?.pending = WorkoutTimerFeature.PendingActivityControl(id: 17, result: .applied, activityRevision: 1)
            $0.recordSync = .pending(revision: 1, record: WorkoutRunRecord(workoutID: $0.workoutID, run: $0.run))
        }
        await timer.receive(.internal(.activitySynchronized(revision: 1, .init(outcome: .applied)))) {
            $0.activityControls?.pending = nil
        }
        var iterator = acknowledgements.makeAsyncIterator()
        #expect(await iterator.next() == .applied)
        #expect(timer.store.state.countdown == nil)
        #expect(timer.store.state.snapshot.status == .running)
        #expect(activity.syncs.value.first?.content.controlGeneration == 8)
        // Record IO retains its own assertion and does not extend this command's wait.
        #expect(timer.writes.value.isEmpty)
        writes.finish()
        await timer.recordSaved(revision: 1)
        await effect.cancel()
        await timer.store.finish()
    }

    @Test(arguments: [LiveActivityCommand.pause, .resume])
    func test_command_waitsForRequiredNotifications_andDoesNotUndoAnAppliedCommandOnPartialFailure(command: LiveActivityCommand) async {
        var state = WorkoutTimerFeature.State.fixture(command == .pause ? .running : .paused)
        state.activityControls = WorkoutTimerFeature.ActivityControlState(isReady: true, generation: 7)
        state.notifications.access = .authorized
        state.$isBackgroundNotificationsOn = SharedReader(value: true)
        state.$isSoundOn = SharedReader(value: false)
        state.notifications.projection = state.notificationProjection(at: origin, language: "en")
        let runningTimer = TimerHarness(state, notifications: true)
        let activity = runningTimer.recordActivity()
        let writes = holdRecordWrites(runningTimer)
        let acknowledgements = recordAcknowledgements(runningTimer)
        let notificationGate = AsyncStream<Void>.makeStream()
        let requests = LockIsolated<[[ScheduledNotification]]>([])
        let report = NotificationSyncReport(failed: command == .resume ? 1 : 0)
        runningTimer.store.dependencies.backgroundNotifications.sync = { _, _, plan in
            requests.withValue { $0.append(plan) }
            for await _ in notificationGate.stream { break }
            return report
        }

        let effect = await runningTimer.store.send(.internal(.activityRequestReceived(.init(id: 17, command: command, generation: 7)))) {
            if command == .pause { $0.run.pause(at: origin) } else { $0.run.resume(at: origin) }
            $0.settle(at: origin)
            $0.clockGeneration = 2
            $0.clockAnchor = command == .pause ? nil : runningTimer.anchor(totalElapsed: $0.snapshot.totalElapsed)
            $0.requestedAwake = command == .resume
            $0.awakeRevision = command == .pause ? 2 : 3
            $0.activityControls?.generation = 8
            $0.activityControls?.pending = WorkoutTimerFeature.PendingActivityControl(
                id: 17, result: .applied, activityRevision: 1, notificationRevision: 1
            )
            $0.notifications.projection = $0.notificationProjection(at: origin, language: "en")
            $0.notifications.revision = 1
            $0.notifications.lastAttempt = MonotonicInstant(now: runningTimer.clock)
            $0.recordSync = .pending(revision: 1, record: WorkoutRunRecord(workoutID: $0.workoutID, run: $0.run))
        }
        await runningTimer.receive(.internal(.activitySynchronized(revision: 1, .init(outcome: .applied)))) {
            $0.activityControls?.pending?.activityResult = .applied
        }
        #expect(runningTimer.store.state.activityControls?.pending != nil)
        notificationGate.continuation.finish()
        await runningTimer.receive(.internal(.notificationsSynced(revision: 1, report: report))) {
            $0.activityControls?.pending = nil
            $0.notifications.hasSchedulingFailed = command == .resume
            $0.notifications.needsRetry = command == .resume
        }
        var iterator = acknowledgements.makeAsyncIterator()
        #expect(await iterator.next() == .applied)
        #expect(requests.value.count == 1)
        #expect(requests.value.first?.isEmpty == (command == .pause))
        #expect(runningTimer.store.state.activityControls?.generation == 8)
        if command == .pause {
            #expect(runningTimer.store.state.snapshot.status == .paused)
            #expect(activity.syncs.value.last?.content == WorkoutActivityAttributes.ContentState(
                phase: .paused(.init(stage: .init(kind: .work, name: "Stage 1"), remainingMilliseconds: 7_000)),
                controlGeneration: 8
            ))
        }
        if command == .resume { #expect(runningTimer.store.state.notificationFootnote == "timer.notifications.failed") }
        writes.finish()
        await runningTimer.recordSaved(revision: 1)
        await effect.cancel()
        await runningTimer.store.finish()
    }

    @Test
    func test_activityTask_waitsForSubscriptionWithoutDelayingTheClock_andGatesEarlyBackgroundPublication() async {
        let timer = TimerHarness(.appearing(elapsed: 3))
        let activity = timer.recordActivity()
        let registration = AsyncStream<Void>.makeStream()
        let commands = AsyncStream<LiveActivityControlRequest>.makeStream()
        timer.store.dependencies.liveActivity.requests = { _ in
            for await _ in registration.stream { break }
            return commands.stream
        }
        let subscription = await timer.store.send(.view(.activityTask)) {
            $0.activityControls = WorkoutTimerFeature.ActivityControlState()
        }
        await timer.appearRunning()
        #expect(timer.store.state.clockGeneration == 1)
        #expect(activity.syncs.value.isEmpty)
        let clockEffect = await timer.store.send(.view(.scenePhaseChanged(.background))) {
            $0.isInBackground = true
            $0.clockGeneration = 2
            $0.clockAnchor = timer.anchor(totalElapsed: $0.snapshot.totalElapsed)
            $0.recordSync = .pending(revision: 2, record: WorkoutRunRecord(workoutID: $0.workoutID, run: $0.run))
        }
        await timer.recordSaved(revision: 2)
        #expect(activity.syncs.value.isEmpty)
        await timer.store.send(.view(.playPauseButtonTapped)) {
            $0.run.pause(at: origin)
            $0.settle(at: origin)
            $0.clockGeneration = 3
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 2
            $0.activityControls?.generation = 1
            $0.recordSync = .pending(revision: 3, record: WorkoutRunRecord(workoutID: $0.workoutID, run: $0.run))
        }
        await timer.recordSaved(revision: 3)
        #expect(activity.syncs.value.isEmpty)

        registration.continuation.finish()
        await timer.receive(.internal(.activityRequestsReady)) { $0.activityControls?.isReady = true }
        #expect(timer.store.state.clockGeneration == 3)
        await subscription.cancel()
        await clockEffect.cancel()
        await timer.store.finish()
        #expect(activity.revisionsTaken.value == 1)
        #expect(activity.syncs.value.last?.content == WorkoutActivityAttributes.ContentState(
            phase: .paused(.init(stage: .init(kind: .work, name: "Stage 1"), remainingMilliseconds: 7_000)),
            controlGeneration: 1
        ))
    }

    @Test(arguments: [LiveActivitySyncResult.Outcome.failed, .superseded])
    func test_ack_usesTheDrainOutcome_andWaitsForANewerSyncWhenSuperseded(firstOutcome: LiveActivitySyncResult.Outcome) async {
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.activityControls = WorkoutTimerFeature.ActivityControlState(isReady: true, generation: 7)
        let timer = TimerHarness(state)
        _ = timer.recordActivity()
        let acknowledgements = recordAcknowledgements(timer)
        let sync = timer.store.dependencies.liveActivity.syncWithResult
        timer.store.dependencies.liveActivity.syncWithResult = { owner, revision, attributes, content in
            _ = await sync(owner, revision, attributes, content)
            return LiveActivitySyncResult(outcome: revision == 1 ? firstOutcome : .applied)
        }
        await timer.send(.internal(.activityRequestReceived(.init(id: 17, command: .resume, generation: 6)))) {
            $0.activityControls?.pending = WorkoutTimerFeature.PendingActivityControl(id: 17, result: .stale, activityRevision: 1)
        }
        let first = WorkoutTimerFeature.Action.internal(.activitySynchronized(revision: 1, .init(outcome: firstOutcome)))
        if firstOutcome == .failed {
            await timer.receive(first) { $0.activityControls?.pending = nil }
        } else {
            await timer.receive(first)
        }
        if firstOutcome == .superseded {
            await timer.send(.view(.notificationPreferencesChanged)) { $0.activityControls?.pending?.activityRevision = 2 }
            await timer.receive(.internal(.activitySynchronized(revision: 2, .init(outcome: .applied)))) {
                $0.activityControls?.pending = nil
            }
        }
        var iterator = acknowledgements.makeAsyncIterator()
        #expect(await iterator.next() == (firstOutcome == .failed ? .failed : .stale))
        #expect(timer.store.state.snapshot.status == .paused)
        #expect(timer.writes.value.isEmpty)
        await timer.store.finish()
    }

    @Test(arguments: [
        (TimerPhase.startCountdown, LiveActivityCommand.resume),
        (.idle, .resume), (.finished, .resume), (.running, .resume), (.paused, .pause), (.awaitingUser, .pause),
    ])
    func test_command_incompatiblePhase_doesNotStartSkipOrWrite(phase: TimerPhase, command: LiveActivityCommand) async {
        var state = WorkoutTimerFeature.State.fixture(phase, schedule: phase == .awaitingUser ? Schedules.withPause : Schedules.workRest)
        state.activityControls = WorkoutTimerFeature.ActivityControlState(isReady: true, generation: 7)
        let timer = TimerHarness(state)
        _ = timer.recordActivity()
        let acknowledgements = recordAcknowledgements(timer)
        await timer.send(.internal(.activityRequestReceived(.init(id: 17, command: command, generation: 7)))) {
            $0.activityControls?.pending = WorkoutTimerFeature.PendingActivityControl(id: 17, result: .stale, activityRevision: 1)
        }
        await timer.receive(.internal(.activitySynchronized(revision: 1, .init(outcome: .applied)))) {
            $0.activityControls?.pending = nil
        }
        var iterator = acknowledgements.makeAsyncIterator()
        #expect(await iterator.next() == .stale)
        #expect(timer.writes.value.isEmpty)
        #expect(timer.calls.value.isEmpty)
        await timer.store.finish()
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

    private func recordAcknowledgements(_ timer: TimerHarness) -> AsyncStream<LiveActivityControlResult> {
        let pair = AsyncStream<LiveActivityControlResult>.makeStream()
        timer.store.dependencies.liveActivity.requestHandled = { owner, requestID, result in
            #expect(owner == timerID)
            #expect(requestID == 17)
            pair.continuation.yield(result)
        }
        return pair.stream
    }
}
