@testable import WorkoutTimerFeature

import ComposableArchitecture
import Foundation
import Testing
import WorkoutDomain

@MainActor
@Suite
struct TimerLifecycleTests {
    @Test
    func test_task_freshState_countsDownThenStartsTheRunOnce() async {
        let initial = WorkoutTimerFeature.State.fresh()
        #expect(initial.countdown == WorkoutTimerFeature.Countdown(purpose: .start, remaining: 3))
        #expect(initial.snapshot == initial.run.snapshot(at: .distantPast))
        #expect(initial.snapshot.status == .idle)
        #expect(!initial.hasClockFailed)
        #expect(initial.clockGeneration == 0)
        #expect(initial.clockAnchor == nil)
        #expect(!initial.requestedAwake)
        #expect(initial.awakeRevision == 0)
        #expect(initial.destination == nil)
        let timer = TimerHarness(initial)
        let store = timer.store

        await store.send(.view(.task)) {
            $0.clockGeneration = 1
            $0.requestedAwake = true
            $0.awakeRevision = 1
        }
        await timer.advance(seconds: 1)
        await store.receive(.internal(.countdownTicked(generation: 1))) { $0.countdown?.remaining = 2 }
        await timer.advance(seconds: 1)
        await store.receive(.internal(.countdownTicked(generation: 1))) { $0.countdown?.remaining = 1 }
        await timer.advance(seconds: 1)
        await store.receive(.internal(.countdownTicked(generation: 1))) {
            $0.countdown = nil
            $0.run.start(at: moment(3))
            $0.settle(at: moment(3))
            $0.clockGeneration = 2
            $0.clockAnchor = timer.anchor(totalElapsed: .zero)
        }
        #expect(store.state.run.phase == .running(since: moment(3)))
        #expect(store.state.snapshot.totalElapsed == .zero)
        #expect(timer.calls.value == [.awake(true, 1)])

        await store.send(.view(.playPauseButtonTapped)) {
            $0.run.pause(at: moment(3))
            $0.settle(at: moment(3))
            $0.clockGeneration = 3
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 2
        }
        #expect(timer.calls.value == [.awake(true, 1), .awake(false, 2)])
    }

    @Test
    func test_ticked_runReachesTheEnd_finishesAndLetsTheScreenSleep() async {
        let timer = TimerHarness(.appearing(Schedules.short))
        let store = timer.store

        await timer.appearRunning()
        await timer.advance(seconds: 1)
        await store.receive(.internal(.ticked(generation: 1, isFinal: false))) {
            $0.settle(at: moment(1))
            $0.clockAnchor = timer.anchor(totalElapsed: .seconds(1))
        }
        await timer.advance(seconds: 1)
        // The reducer's own reading reaches the end first and replaces the loop, so the loop's final tick is
        // dropped with it.
        await store.receive(.internal(.ticked(generation: 1, isFinal: false))) {
            $0.settle(at: moment(2))
            $0.clockGeneration = 2
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 2
        }
        #expect(store.state.snapshot.status == .finished)
        #expect(store.state.snapshot.totalRemaining == .zero)
        #expect(timer.calls.value == [.awake(true, 1), .awake(false, 2)])
    }

    @Test
    func test_ticked_runReachesAManualPause_stopsTheClockUntilPlay() async {
        let timer = TimerHarness(.appearing(Schedules.withPause))
        let store = timer.store

        await timer.appearRunning()
        await timer.advance(seconds: 1)
        await store.receive(.internal(.ticked(generation: 1, isFinal: false))) {
            $0.settle(at: moment(1))
            $0.clockAnchor = timer.anchor(totalElapsed: .seconds(1))
        }
        await timer.advance(seconds: 1)
        await store.receive(.internal(.ticked(generation: 1, isFinal: false))) {
            $0.settle(at: moment(2))
            $0.clockGeneration = 2
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 2
        }
        #expect(store.state.snapshot.status == .awaitingUser)
        await timer.advance(seconds: 5)

        await store.send(.view(.playPauseButtonTapped)) {
            $0.run.resume(at: moment(7))
            $0.settle(at: moment(7))
            $0.clockGeneration = 3
            $0.clockAnchor = timer.anchor(totalElapsed: .seconds(2))
            $0.requestedAwake = true
            $0.awakeRevision = 3
        }
        #expect(store.state.snapshot.currentStage?.index == 2)
        #expect(store.state.snapshot.status == .running)

        await store.send(.view(.playPauseButtonTapped)) {
            $0.run.pause(at: moment(7))
            $0.settle(at: moment(7))
            $0.clockGeneration = 4
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 4
        }
        #expect(timer.calls.value == [.awake(true, 1), .awake(false, 2), .awake(true, 3), .awake(false, 4)])
    }

    @Test
    func test_emptySchedule_startsFinishedAndClosesWithoutAlert() async {
        let state = WorkoutTimerFeature.State.fresh(Schedules.empty)
        #expect(state.snapshot.status == .finished)
        #expect(state.countdown == nil)
        let timer = TimerHarness(state)
        let store = timer.store

        await store.send(.view(.task)) { $0.clockGeneration = 1 }
        await store.send(.view(.playPauseButtonTapped))
        await store.send(.view(.nextButtonTapped))
        await store.send(.view(.closeButtonTapped)) { $0.clockGeneration = 2 }
        await store.finish()

        #expect(timer.calls.value == [.end(owner: timerID), .dismiss])
    }

    @Test
    func test_task_sentAgainAfterAppearing_keepsTheRunningLoop() async {
        let timer = TimerHarness(.appearing())
        let store = timer.store
        await timer.appearRunning()

        await store.send(.view(.task))
        await timer.advance(seconds: 1)
        await store.receive(.internal(.ticked(generation: 1, isFinal: false))) {
            $0.settle(at: moment(1))
            $0.clockAnchor = timer.anchor(totalElapsed: .seconds(1))
        }

        await store.send(.view(.playPauseButtonTapped)) {
            $0.run.pause(at: moment(1))
            $0.settle(at: moment(1))
            $0.clockGeneration = 2
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 2
        }
        #expect(timer.calls.value == [.awake(true, 1), .awake(false, 2)])
    }

    @Test
    func test_ticked_finalWhileTheRunStillRuns_startsANewLoop() async {
        let timer = TimerHarness(.appearing())
        let store = timer.store
        await timer.appearRunning()

        await store.send(.internal(.ticked(generation: 1, isFinal: true))) {
            $0.clockGeneration = 2
            $0.clockAnchor = timer.anchor(totalElapsed: .zero)
        }
        await timer.advance(seconds: 1)
        await store.receive(.internal(.ticked(generation: 2, isFinal: false))) {
            $0.settle(at: moment(1))
            $0.clockAnchor = timer.anchor(totalElapsed: .seconds(1))
        }

        await store.send(.view(.playPauseButtonTapped)) {
            $0.run.pause(at: moment(1))
            $0.settle(at: moment(1))
            $0.clockGeneration = 3
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 2
        }
        #expect(timer.calls.value == [.awake(true, 1), .awake(false, 2)])
    }
}
