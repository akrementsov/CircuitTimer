@testable import WorkoutTimerFeature

import ComposableArchitecture
import Foundation
import Testing
import WorkoutDomain

@MainActor
@Suite
struct TimerGenerationTests {
    private typealias State = WorkoutTimerFeature.State
    private typealias Countdown = WorkoutTimerFeature.Countdown

    @Test
    func test_sync_pausedRun_dropsTheAnchorSoAWallChangeIsNotReconciled() async {
        let timer = TimerHarness(.fixture(.running))
        let store = timer.store

        await store.send(.view(.playPauseButtonTapped)) {
            $0.run.pause(at: origin)
            $0.settle(at: origin)
            $0.clockGeneration = 2
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 2
        }
        await timer.clock.advance(by: .seconds(10))
        timer.moveWall(seconds: -30)

        await store.send(.view(.playPauseButtonTapped)) {
            $0.run.resume(at: moment(-30))
            $0.settle(at: moment(-30))
            $0.clockGeneration = 3
            $0.clockAnchor = timer.anchor(totalElapsed: .seconds(3))
            $0.requestedAwake = true
            $0.awakeRevision = 3
        }
        #expect(store.state.snapshot.totalElapsed == .seconds(3))

        await store.send(.view(.playPauseButtonTapped)) {
            $0.run.pause(at: moment(-30))
            $0.settle(at: moment(-30))
            $0.clockGeneration = 4
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 4
        }
    }

    @Test(arguments: [
        WorkoutTimerFeature.Action.Internal.ticked(generation: 2, isFinal: false),
        .ticked(generation: 2, isFinal: true),
        .countdownTicked(generation: 2),
        .clockFailed(generation: 2),
    ])
    func test_internalAction_olderGeneration_changesNothing(action: WorkoutTimerFeature.Action.Internal) async {
        var state = State.fixture(.running)
        state.clockGeneration = 3
        let timer = TimerHarness(state)
        await timer.advance(seconds: 1)

        await timer.store.send(.internal(action))
        #expect(!timer.store.state.hasClockFailed)
        #expect(timer.calls.value.isEmpty)
    }

    @Test
    func test_playPause_duringTheCountdownAfterATick_cancelsTheOldLoop() async {
        let timer = TimerHarness(.fresh())
        let store = timer.store

        await store.send(.view(.task)) {
            $0.clockGeneration = 1
            $0.requestedAwake = true
            $0.awakeRevision = 1
        }
        await timer.advance(seconds: 1)
        await store.receive(.internal(.countdownTicked(generation: 1))) { $0.countdown?.remaining = 2 }
        await store.send(.view(.playPauseButtonTapped)) {
            $0.countdown = nil
            $0.clockGeneration = 2
            $0.requestedAwake = false
            $0.awakeRevision = 2
        }
        await timer.advance(seconds: 3)
        await store.finish()

        #expect(store.state.snapshot.status == .idle)
        #expect(timer.calls.value == [.awake(true, 1), .awake(false, 2)])
    }

    @Test
    func test_clockFailed_tickLoopSleepThrows_pausesAndAsksToResume() async {
        let timer = TimerHarness(.appearing(elapsed: 3))
        let store = timer.store
        timer.failures.setValue(1)

        await timer.appearRunning()
        await store.receive(.internal(.clockFailed(generation: 1))) {
            $0.run.pause(at: origin)
            $0.settle(at: origin)
            $0.hasClockFailed = true
            $0.clockGeneration = 2
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 2
        }
        #expect(store.state.currentCard.name == String(localized: "timer.failed.resume", bundle: .module))
        #expect(timer.calls.value == [.awake(true, 1), .awake(false, 2)])
    }

    @Test
    func test_clockFailed_countdownSleepThrows_asksToStartAndPlayRecovers() async {
        let timer = TimerHarness(.fresh())
        let store = timer.store
        timer.failures.setValue(1)

        await store.send(.view(.task)) {
            $0.clockGeneration = 1
            $0.requestedAwake = true
            $0.awakeRevision = 1
        }
        await store.receive(.internal(.clockFailed(generation: 1))) {
            $0.countdown = nil
            $0.hasClockFailed = true
            $0.clockGeneration = 2
            $0.requestedAwake = false
            $0.awakeRevision = 2
        }
        #expect(store.state.currentCard.name == String(localized: "timer.failed.start", bundle: .module))

        await store.send(.view(.playPauseButtonTapped)) {
            $0.countdown = Countdown(.start)
            $0.hasClockFailed = false
            $0.clockGeneration = 3
            $0.requestedAwake = true
            $0.awakeRevision = 3
        }
        await store.send(.view(.playPauseButtonTapped)) {
            $0.countdown = nil
            $0.clockGeneration = 4
            $0.requestedAwake = false
            $0.awakeRevision = 4
        }
    }

    @Test
    func test_clockFailed_thenNextToAPausedStage_keepsTheFailureUntilPlay() async {
        var state = State.fixture(.paused)
        state.hasClockFailed = true
        let timer = TimerHarness(state)
        let store = timer.store

        await store.send(.view(.nextButtonTapped)) {
            $0.run.skipToNextStage(at: origin)
            $0.settle(at: origin)
            $0.clockGeneration = 2
        }
        #expect(store.state.hasClockFailed)

        await store.send(.view(.playPauseButtonTapped)) {
            $0.run.resume(at: origin)
            $0.settle(at: origin)
            $0.hasClockFailed = false
            $0.clockGeneration = 3
            $0.clockAnchor = timer.anchor(totalElapsed: .seconds(10))
            $0.requestedAwake = true
            $0.awakeRevision = 3
        }
        await timer.cancelClockLoop()
    }

    @Test
    func test_clockFailed_runReachedAManualPause_asksToResumeAndPlayRecovers() async {
        let timer = TimerHarness(.fixture(.running, schedule: Schedules.withPause, elapsed: 1))
        let store = timer.store
        await timer.advance(seconds: 2)

        await store.send(.internal(.clockFailed(generation: 1))) {
            $0.settle(at: moment(2))
            $0.hasClockFailed = true
            $0.clockGeneration = 2
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 2
        }
        #expect(store.state.snapshot.status == .awaitingUser)
        #expect(store.state.currentCard.name == String(localized: "timer.failed.resume", bundle: .module))

        await store.send(.view(.playPauseButtonTapped)) {
            $0.run.resume(at: moment(2))
            $0.settle(at: moment(2))
            $0.hasClockFailed = false
            $0.clockGeneration = 3
            $0.clockAnchor = timer.anchor(totalElapsed: .seconds(2))
            $0.requestedAwake = true
            $0.awakeRevision = 3
        }
        await timer.cancelClockLoop()
        #expect(timer.calls.value == [.awake(false, 2), .awake(true, 3)])
    }

    @Test
    func test_clockFailed_runFinishedSinceTheLastTick_showsTheEnd() async {
        let timer = TimerHarness(.fixture(.running))
        let store = timer.store
        await timer.advance(seconds: 20)

        await store.send(.internal(.clockFailed(generation: 1))) {
            $0.settle(at: moment(20))
            $0.clockGeneration = 2
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 2
        }
        #expect(store.state.snapshot.status == .finished)
        #expect(!store.state.hasClockFailed)
    }

    @Test
    func test_next_afterAFailureOnTheLastStage_showsTheEnd() async {
        var state = State.fixture(.paused, elapsed: 12)
        state.hasClockFailed = true
        let timer = TimerHarness(state)

        await timer.store.send(.view(.nextButtonTapped)) {
            $0.run.skipToNextStage(at: origin)
            $0.settle(at: origin)
            $0.hasClockFailed = false
            $0.clockGeneration = 2
        }
        #expect(timer.store.state.snapshot.status == .finished)
    }
}
