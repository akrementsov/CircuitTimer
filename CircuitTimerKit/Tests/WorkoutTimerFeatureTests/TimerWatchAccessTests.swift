@testable import WorkoutTimerFeature

import BackgroundNotifications
import ComposableArchitecture
import Foundation
import Testing
import TestSupport
import WatchLink
import WorkoutActivity
import WorkoutDomain

/// A timer the watch may not control, as one the app opens without the full version or turns off after a refund: the
/// watch's requests change and write nothing, while the timer still publishes its own run. The fixture runs 3 s into
/// a 10 s work stage, anchored at `origin`; a 5 s rest follows.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TimerWatchAccessTests {
    private static func command(_ id: Int, _ command: LiveActivityCommand, generation: Int = 3) -> WorkoutTimerFeature.Action {
        .internal(.watchRequestReceived(WatchControlRequest(id: id, kind: .command(command, generation: generation))))
    }

    /// Records every sync of the card and of the notifications, which a refused request must not cause.
    private static func recordSyncs(_ timer: TimerHarness) -> LockIsolated<Int> {
        let syncs = LockIsolated(0)
        timer.store.dependencies.liveActivity.sync = { _, _, _, _ in
            syncs.withValue { $0 += 1 }
            return nil
        }
        timer.store.dependencies.liveActivity.syncWithResult = { _, _, _, _ in
            syncs.withValue { $0 += 1 }
            return LiveActivitySyncResult(outcome: .applied)
        }
        timer.store.dependencies.backgroundNotifications.sync = { _, _, _ in
            syncs.withValue { $0 += 1 }
            return NotificationSyncReport()
        }
        return syncs
    }

    /// The command finds the work stage over unseen: refused before `advance`, the stage stays, nothing is written or
    /// synced, and the watch is told `unavailable` without the run.
    @Test
    func test_watchCommand_withoutWatchControl_isRefusedBeforeAdvance_andAnsweredWithoutTheRun() async {
        var state = WorkoutTimerFeature.State.fixture(.running)
        state.activityControls = WorkoutTimerFeature.ActivityControlState(generation: 3)
        let timer = TimerHarness(state)
        timer.store.dependencies.liveActivity.requestHandled = { _, requestID, result in
            Issue.record("The card was answered \(result) for request \(requestID)")
        }
        let syncs = Self.recordSyncs(timer)
        await timer.advance(seconds: 8)
        let before = timer.store.state

        // Exhaustive: the pass changes no state, the refusal included, which the same pass answers.
        await timer.send(Self.command(9, .pause))
        await timer.store.finish()

        #expect(timer.store.state == before)
        #expect(timer.store.state.snapshot.currentStage?.kind == .work)
        #expect(timer.watch.controls.value == [
            WatchControlAnswer(owner: timerID, requestID: 9, result: .unavailable, publication: nil),
        ])
        #expect(timer.writes.value.isEmpty)
        #expect(timer.assertions.value.isEmpty)
        #expect(syncs.value == 0)
    }

    /// A refresh past the stage's end settles nothing and is answered without the run.
    @Test
    func test_watchRefresh_withoutWatchControl_answersNilWithoutAdvance() async {
        let timer = TimerHarness(.fixture(.running))
        await timer.advance(seconds: 8)

        await timer.send(.internal(.watchRequestReceived(WatchControlRequest(id: 8, kind: .refresh))))
        await timer.store.finish()

        #expect(timer.store.state.snapshot.currentStage?.kind == .work)
        #expect(timer.watch.answers.value == [WatchAnswer(owner: timerID, requestID: 8, publication: nil)])
        #expect(timer.watch.published.value.isEmpty)
        #expect(timer.writes.value.isEmpty)
    }

    /// The timer's own publication does not depend on the watch's control: the link decides what reaches the watch.
    @Test
    func test_action_withoutWatchControl_stillPublishesTheRun() async {
        let timer = TimerHarness(.fixture(.paused), activity: true)

        await timer.send(.view(.notificationPreferencesChanged))
        await timer.send(.view(.notificationPreferencesChanged))
        await timer.store.finish()

        #expect(timer.watch.published.value.map(\.revision) == [1, 2])
        #expect(timer.watch.published.value.allSatisfy { $0.run.owner == timerID })
    }

    /// A command admitted before a refund whose drain ends after it is answered once, with its own result and without
    /// the run, though the pass published the run itself.
    @Test
    func test_watchCommandDrainingAcrossARefund_isAnsweredOnceWithItsResultWithoutTheRun() async {
        var state = WorkoutTimerFeature.State.fixture(.paused)
        var pending = WorkoutTimerFeature.PendingActivityControl(
            source: .watch(requestID: 9), result: .applied, admittedAt: MonotonicInstant(now: TestClock<Duration>())
        )
        pending.activityRevision = 5
        state.activityControls = WorkoutTimerFeature.ActivityControlState(generation: 4, pending: pending)
        #expect(!state.allowsWatchControl)
        let timer = TimerHarness(state)
        timer.store.exhaustivity = .off
        timer.store.dependencies.liveActivity.requestHandled = { _, requestID, result in
            Issue.record("The card was answered \(result) for request \(requestID)")
        }

        // The drain the command waits for ends: this pass answers it.
        await timer.store.send(.internal(.activitySynchronized(revision: 5, LiveActivitySyncResult(outcome: .applied))))
        await timer.watch.controls.wait { !$0.isEmpty }
        await timer.store.send(.view(.notificationPreferencesChanged))
        await timer.store.finish()

        #expect(timer.store.state.activityControls?.pending == nil)
        #expect(timer.watch.controls.value == [
            WatchControlAnswer(owner: timerID, requestID: 9, result: .applied, publication: nil),
        ])
        #expect(timer.watch.published.value.count == 2)
    }
}
