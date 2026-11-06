@testable import WorkoutTimerFeature

import ComposableArchitecture
import Foundation
import Testing
import WatchLink
import WorkoutActivity
import WorkoutDomain

/// The fixture runs 3 s into a 10 s work stage, anchored at `origin`; a 5 s rest follows.
@MainActor
@Suite
struct TimerWatchTests {
    /// A timer the watch may control, as one the app opens with the full version.
    private static func harness(_ state: WorkoutTimerFeature.State, activity: Bool = false) -> TimerHarness {
        var state = state
        state.allowsWatchControl = true
        return TimerHarness(state, activity: activity)
    }

    private static func run(of state: WorkoutTimerFeature.State, at now: Date) -> WatchRun {
        WatchRun(
            owner: state.id,
            attributes: WorkoutActivityAttributes(workoutName: state.workoutName),
            content: WorkoutActivityAttributes.ContentState(
                run: state.run, at: now, controlGeneration: state.activityControls?.generation ?? 0
            )
        )
    }

    @Test
    func test_action_afterTheClockStarted_publishesTheRunWithARevisionTakenForEachAction() async {
        let timer = Self.harness(.fixture(.paused), activity: true)
        let run = Self.run(of: timer.store.state, at: origin)

        await timer.send(.view(.notificationPreferencesChanged))
        await timer.send(.view(.notificationPreferencesChanged))
        await timer.store.finish()

        #expect(run.owner == timerID)
        #expect(run.attributes.workoutName == "Workout")
        #expect(run.content.controlGeneration == timer.store.state.activityControls?.generation)
        // The link drops the same run; the timer publishes after every action all the same.
        #expect(timer.watch.published.value == [
            WatchRunPublication(revision: 1, run: run),
            WatchRunPublication(revision: 2, run: run),
        ])
        #expect(timer.watch.answers.value.isEmpty)
    }

    @Test
    func test_action_beforeTheClockStarted_publishesNothing() async {
        let timer = Self.harness(.fresh())

        await timer.send(.view(.notificationPreferencesChanged))
        await timer.store.finish()

        #expect(timer.watch.published.value.isEmpty)
        #expect(timer.watch.revisions.value == 0)
    }

    @Test
    func test_watchRequest_answersWithTheRunSettledForIt_withoutAPublicationOfItsOwn() async {
        let timer = Self.harness(.fixture(.paused), activity: true)
        await timer.advance(seconds: 2)
        let run = Self.run(of: timer.store.state, at: timer.now)

        await timer.send(.internal(.watchRequestReceived(WatchControlRequest(id: 7, kind: .refresh))))
        await timer.store.finish()

        #expect(timer.watch.answers.value == [
            WatchAnswer(owner: timerID, requestID: 7, publication: WatchRunPublication(revision: 1, run: run)),
        ])
        #expect(timer.watch.published.value.isEmpty)
        // A paused run has nothing to settle: no new clock loop, and the exhaustive store saw no state change.
        #expect(timer.store.state.clockGeneration == 1)
    }

    /// A request after the work stage ended unseen commits the run in the rest stage before it answers with it. A new
    /// stage changes neither the status nor an operation, so the running loop stays and nothing is written.
    @Test
    func test_watchRequest_runningPastTheStageEnd_commitsTheNextStageAndAnswersWithIt() async throws {
        let timer = Self.harness(.fixture(.running))
        // No loop runs in the fixture, so nothing has moved the run past the work stage's end, 7 s from now.
        await timer.advance(seconds: 8)

        await timer.send(.internal(.watchRequestReceived(WatchControlRequest(id: 8, kind: .refresh)))) {
            $0.settle(at: timer.now)
        }
        await timer.store.finish()

        #expect(timer.store.state.snapshot.currentStage?.kind == .rest)
        let answer = try #require(timer.watch.answers.value.first)
        #expect(answer.publication == WatchRunPublication(revision: 1, run: Self.run(of: timer.store.state, at: timer.now)))
        guard case let .running(running) = answer.publication?.run.content.phase else {
            Issue.record("The answer is not a running stage")
            return
        }
        #expect(running.stage.kind == .rest)
    }

    @Test(arguments: [false, true])
    func test_watchRequest_beforeTheClockStartedOrWhileClosing_answersNil(closing: Bool) async {
        var state: WorkoutTimerFeature.State = closing ? .fixture(.paused) : .fresh()
        state.isClosing = closing
        let timer = Self.harness(state)

        await timer.send(.internal(.watchRequestReceived(WatchControlRequest(id: 3, kind: .refresh))))
        await timer.store.finish()

        #expect(timer.watch.answers.value == [WatchAnswer(owner: timerID, requestID: 3, publication: nil)])
        #expect(timer.watch.published.value.isEmpty)
    }

    /// The close dialog stops the controls, not the watch's requests: its subscription starts, and a request
    /// reaches the timer.
    @Test
    func test_watchTask_closeDialogOpen_subscribesAndAnswersTheWatch() async {
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.destination = .closeConfirmation(.closeConfirmation(restart: nil))
        let timer = Self.harness(state)

        await timer.send(.view(.watchTask)) {
            $0.activityControls = WorkoutTimerFeature.ActivityControlState()
        }
        timer.watch.request(4)
        await timer.receive(.internal(.watchRequestReceived(WatchControlRequest(id: 4, kind: .refresh))))
        timer.watch.finish()
        await timer.store.finish()

        #expect(timer.watch.subscriptions.value == [timerID])
        #expect(timer.watch.answers.value.map(\.requestID) == [4])
    }

    /// A second subscription replaces the first, so one request is answered once.
    @Test
    func test_watchTask_again_replacesTheSubscription() async {
        let timer = Self.harness(.fixture(.paused))

        await timer.send(.view(.watchTask)) {
            $0.activityControls = WorkoutTimerFeature.ActivityControlState()
        }
        await timer.send(.view(.watchTask))
        timer.watch.request(5)
        await timer.receive(.internal(.watchRequestReceived(WatchControlRequest(id: 5, kind: .refresh))))
        timer.watch.finish()
        await timer.store.finish()

        #expect(timer.watch.subscriptions.value == [timerID, timerID])
        #expect(timer.watch.answers.value.map(\.requestID) == [5])
    }
}
