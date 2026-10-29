@testable import WorkoutTimerFeature

import ComposableArchitecture
import Foundation
import Testing
import WorkoutActivity
import WorkoutDomain

/// The fixture runs 3 s into a 10 s work stage, anchored at `origin`; a 5 s rest follows.
@MainActor
@Suite
struct TimerLiveActivityTests {
    private typealias Content = WorkoutActivityAttributes.ContentState

    @Test
    func test_liveActivityNoticeChanged_acceptsOnlyANewerSerial() async {
        let timer = TimerHarness(.fixture(.paused), activity: true)
        let activity = timer.recordActivity()
        let failing = LiveActivityNotice(serial: 1, isFailing: true)
        let recovered = LiveActivityNotice(serial: 2, isFailing: false)
        #expect(!timer.store.state.isLiveActivityFailing)

        await timer.send(.internal(.liveActivityNoticeChanged(failing))) { $0.liveActivityNotice = failing }
        #expect(timer.store.state.isLiveActivityFailing)
        await timer.send(.internal(.liveActivityNoticeChanged(LiveActivityNotice(serial: 1, isFailing: false))))
        await timer.send(.internal(.liveActivityNoticeChanged(recovered))) { $0.liveActivityNotice = recovered }
        await timer.send(.internal(.liveActivityNoticeChanged(LiveActivityNotice(serial: 2, isFailing: true))))
        await timer.store.finish()

        #expect(!timer.store.state.isLiveActivityFailing)
        #expect(activity.syncs.value.isEmpty)
    }

    @Test
    func test_action_afterTheClockStarted_syncsTheRunAndReceivesANotice() async {
        let timer = TimerHarness(.fixture(.paused), activity: true)
        let notice = LiveActivityNotice(serial: 1, isFailing: true)
        let activity = timer.recordActivity { $0 == 1 ? notice : nil }
        let content = Content(run: timer.store.state.run, at: origin)

        await timer.send(.view(.notificationPreferencesChanged))
        await timer.receive(.internal(.liveActivityNoticeChanged(notice))) { $0.liveActivityNotice = notice }
        await timer.send(.view(.notificationPreferencesChanged))
        await timer.store.finish()

        #expect(activity.syncs.value == [
            ActivitySync(owner: timerID, revision: 1, workoutName: "Workout", content: content),
            ActivitySync(owner: timerID, revision: 2, workoutName: "Workout", content: content),
        ])
    }

    @Test
    func test_action_beforeTheClockStarted_neverSyncs() async {
        let timer = TimerHarness(.fresh(), activity: true)
        let activity = timer.recordActivity()

        await timer.send(.view(.notificationPreferencesChanged))
        await timer.store.finish()

        #expect(activity.syncs.value.isEmpty)
        #expect(activity.revisionsTaken.value == 0)
    }

    @Test
    func test_ticked_stageChange_syncsTheNextStageWithoutWritingTheRecord() async {
        let timer = TimerHarness(.fixture(.running), activity: true)
        let activity = timer.recordActivity()

        for seconds in [1.0, 1, 6] {
            await timer.advance(seconds: seconds)
            await timer.send(.internal(.ticked(generation: 1, isFinal: false))) {
                $0.settle(at: timer.now)
                $0.clockAnchor = timer.anchor(totalElapsed: $0.snapshot.totalElapsed)
            }
        }
        await timer.store.finish()

        let contents = activity.syncs.value.map(\.content)
        #expect(contents.count == 3)
        #expect(contents[0] == contents[1])
        #expect(Self.stage(contents[0])?.kind == .work)
        #expect(Self.stage(contents[2])?.kind == .rest)
        #expect(timer.writes.value.isEmpty)
    }

    @Test
    func test_ticked_wallClockMovedBack_syncsTheRebasedBoundaries() async throws {
        let timer = TimerHarness(.fixture(.running), activity: true)
        let activity = timer.recordActivity()
        await timer.clock.advance(by: .seconds(1))
        timer.moveWall(seconds: 0.749)
        let now = timer.now

        await timer.send(.internal(.ticked(generation: 1, isFinal: false)), saving: true) {
            $0.run.rebase(at: now, keepingTotalElapsed: .seconds(4))
            $0.settle(at: now)
            $0.clockGeneration = 2
            $0.clockAnchor = timer.anchor(totalElapsed: $0.snapshot.totalElapsed)
        }
        await timer.cancelClockLoop()

        let content = try #require(activity.syncs.value.last?.content)
        #expect(content == Content(run: timer.store.state.run, at: now))
        #expect(Self.stageStart(content) != moment(-3))
    }

    @Test
    func test_close_finished_endsTheActivityAfterTheSessionAndBeforeDismissing() async {
        let timer = TimerHarness(.fixture(.finished), activity: true)
        let activity = timer.recordActivity()

        await timer.send(.view(.closeButtonTapped), saving: true) {
            $0.clockGeneration = 2
            $0.isClosing = true
            $0.activityControls?.isEnding = true
        }
        await timer.store.finish()

        #expect(timer.calls.value == [.end(owner: timerID), .endLiveActivity(owner: timerID), .dismiss])
        // Neither record completion nor late readiness may publish after the owner ended.
        #expect(timer.store.state.activityControls?.generation == 0)
        #expect(activity.syncs.value.isEmpty)
    }

    @Test
    func test_closeThenFinish_running_endsTheActivityBeforeDismissing() async {
        let timer = TimerHarness(.fixture(.running), activity: true)
        let activity = timer.recordActivity()

        await timer.send(.view(.closeButtonTapped), saving: true) {
            $0.run.pause(at: origin)
            $0.settle(at: origin)
            $0.activityControls?.generation += 1
            $0.destination = .closeConfirmation(.closeConfirmation(restart: .resume))
            $0.clockGeneration = 2
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 2
        }
        await timer.send(.destination(.presented(.closeConfirmation(.finish)))) {
            $0.destination = nil
            $0.isClosing = true
            $0.activityControls?.isEnding = true
        }
        await timer.store.finish()

        #expect(timer.calls.value == [.awake(false, 2), .end(owner: timerID), .endLiveActivity(owner: timerID), .dismiss])
        #expect(timer.store.state.activityControls?.generation == 1)
        // The close and its record write sync; the finish choice returns early.
        #expect(activity.syncs.value.map(\.revision) == [1, 2])
    }

    @Test
    func test_activityRequestsReady_ownerAlreadyClosing_doesNotPublishOrWrite() async {
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.activityControls = WorkoutTimerFeature.ActivityControlState(isEnding: true, generation: 7)
        let timer = TimerHarness(state)
        let activity = timer.recordActivity()
        await timer.send(.internal(.activityRequestsReady))
        await timer.send(.view(.notificationPreferencesChanged))
        await timer.store.finish()
        #expect(timer.store.state.activityControls?.isReady == false)
        #expect(timer.store.state.activityControls?.generation == 7)
        #expect(activity.syncs.value.isEmpty)
        #expect(timer.writes.value.isEmpty)
    }

    private static func stage(_ content: Content) -> WorkoutActivityAttributes.Stage? {
        guard case let .running(running) = content.phase else { return nil }

        return running.stage
    }

    private static func stageStart(_ content: Content) -> Date? {
        guard case let .running(running) = content.phase else { return nil }

        return running.stageStart
    }
}

struct ActivitySync: Equatable, Sendable {
    let owner: UUID
    let revision: Int
    let workoutName: String
    let content: WorkoutActivityAttributes.ContentState
}

struct ActivityRecorder: Sendable {
    let syncs = LockIsolated<[ActivitySync]>([])
    let revisionsTaken = LockIsolated(0)
}

extension TimerHarness {
    /// Records the Live Activity syncs, answers each with `notice(revision)`, and logs ends in `calls`.
    func recordActivity(notice: @escaping @Sendable (Int) -> LiveActivityNotice? = { _ in nil }) -> ActivityRecorder {
        let recorder = ActivityRecorder()
        let calls = calls
        store.dependencies.liveActivity.nextRevision = {
            recorder.revisionsTaken.withValue {
                $0 += 1
                return $0
            }
        }
        store.dependencies.liveActivity.sync = { owner, revision, attributes, content in
            recorder.syncs.withValue {
                $0.append(ActivitySync(owner: owner, revision: revision, workoutName: attributes.workoutName, content: content))
            }
            return notice(revision)
        }
        store.dependencies.liveActivity.syncWithResult = { owner, revision, attributes, content in
            recorder.syncs.withValue {
                $0.append(ActivitySync(owner: owner, revision: revision, workoutName: attributes.workoutName, content: content))
            }
            return LiveActivitySyncResult(outcome: .applied, notice: notice(revision))
        }
        store.dependencies.liveActivity.end = { owner in
            calls.withValue { $0.append(.endLiveActivity(owner: owner)) }
        }
        return recorder
    }
}
