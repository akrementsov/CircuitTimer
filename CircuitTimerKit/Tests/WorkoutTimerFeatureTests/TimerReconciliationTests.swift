@testable import WorkoutTimerFeature

import ComposableArchitecture
import Foundation
import Testing
import WorkoutDomain

/// The fixture runs 3 s into its first stage, anchored at `origin` and the test clock's start.
@MainActor
@Suite
struct TimerReconciliationTests {
    private typealias State = WorkoutTimerFeature.State

    @Test(arguments: [-251, -250, 250, 251])
    func test_ticked_clocksDisagreeAtTheTolerance_countsOnlyBeyondIt(milliseconds: Int) async {
        let timer = TimerHarness(.fixture(.running))
        let store = timer.store
        await timer.clock.advance(by: .seconds(1))
        timer.moveWall(seconds: 1 + Double(milliseconds) / 1_000)
        let now = timer.now

        await store.send(.internal(.ticked(generation: 1, isFinal: false))) {
            switch milliseconds {
                case -251:
                    $0.run.rebase(at: now, keepingTotalElapsed: .seconds(4))
                    $0.settle(at: now)
                    $0.clockGeneration = 2
                case 251:
                    $0.settle(at: now)
                    $0.clockGeneration = 2
                default:
                    $0.settle(at: now)
            }
            $0.clockAnchor = timer.anchor(totalElapsed: $0.snapshot.totalElapsed)
        }
        let expected: Duration = switch milliseconds {
            case -251: .seconds(4)
            case 251: .milliseconds(4_251)
            default: .seconds(3) + .seconds(1) + .milliseconds(milliseconds)
        }
        #expect(store.state.snapshot.totalElapsed == expected)
        await timer.cancelClockLoop()
    }

    @Test(arguments: [0.5, -1])
    func test_ticked_wallClockWentBack_keepsTheProgressTheMonotonicClockVouchesFor(wall: Double) async {
        let timer = TimerHarness(.fixture(.running))
        let store = timer.store
        await timer.clock.advance(by: .seconds(2))
        timer.moveWall(seconds: wall)
        let now = timer.now

        await store.send(.internal(.ticked(generation: 1, isFinal: false))) {
            $0.run.rebase(at: now, keepingTotalElapsed: .seconds(5))
            $0.settle(at: now)
            $0.clockGeneration = 2
            $0.clockAnchor = timer.anchor(totalElapsed: .seconds(5))
        }
        #expect(store.state.snapshot.totalElapsed == .seconds(5))
        await timer.cancelClockLoop()
    }

    @Test
    func test_playPause_wallClockWentBack_pausesAtTheKeptProgress() async {
        let timer = TimerHarness(.fixture(.running))
        let store = timer.store
        await timer.clock.advance(by: .seconds(2))
        timer.moveWall(seconds: 0.5)

        await store.send(.view(.playPauseButtonTapped)) {
            $0.run.rebase(at: moment(0.5), keepingTotalElapsed: .seconds(5))
            $0.run.pause(at: moment(0.5))
            $0.settle(at: moment(0.5))
            $0.clockGeneration = 2
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 2
        }
        #expect(store.state.snapshot.totalElapsed == .seconds(5))
        #expect(store.state.snapshot.status == .paused)
    }

    @Test(arguments: [3.0, 9, 100])
    func test_ticked_wallClockJumpedForward_keepsTheWallProgressWithOneSync(wall: Double) async {
        let timer = TimerHarness(.fixture(.running))
        let store = timer.store
        await timer.clock.advance(by: .seconds(1))
        timer.moveWall(seconds: wall)
        let now = timer.now

        await store.send(.internal(.ticked(generation: 1, isFinal: false))) {
            $0.settle(at: now)
            $0.clockGeneration = 2
            if $0.snapshot.status == .running {
                $0.clockAnchor = timer.anchor(totalElapsed: $0.snapshot.totalElapsed)
            } else {
                $0.clockAnchor = nil
                $0.requestedAwake = false
                $0.awakeRevision = 2
            }
        }
        switch wall {
            case 3:
                #expect(store.state.snapshot.currentStage?.index == 0)
                #expect(store.state.snapshot.totalElapsed == .seconds(6))
            case 9:
                #expect(store.state.snapshot.currentStage?.index == 1)
                #expect(store.state.snapshot.totalElapsed == .seconds(12))
            default:
                #expect(store.state.snapshot.status == .finished)
                #expect(timer.calls.value == [.awake(false, 2)])
        }
        await timer.cancelClockLoop()
    }

    @Test
    func test_ticked_slowDriftOverManyTicks_isNeverAJump() async {
        let timer = TimerHarness(.fixture(.running))
        let store = timer.store

        for _ in 1...5 {
            await timer.clock.advance(by: .seconds(1))
            timer.moveWall(seconds: 1.1)
            let now = timer.now
            await store.send(.internal(.ticked(generation: 1, isFinal: false))) {
                $0.settle(at: now)
                $0.clockAnchor = timer.anchor(totalElapsed: $0.snapshot.totalElapsed)
            }
        }
        #expect(store.state.clockGeneration == 1)
        #expect(store.state.snapshot.totalElapsed == .milliseconds(8_500))
    }

    @Test
    func test_ticked_anchorFromAnotherClock_skipsReconciling() async {
        var state = State.fixture(.running)
        state.clockAnchor = ClockAnchor(
            date: origin,
            instant: MonotonicInstant(now: LateClock(lateness: .zero)),
            totalElapsed: .seconds(3)
        )
        let timer = TimerHarness(state)
        let store = timer.store
        await timer.clock.advance(by: .seconds(2))
        timer.moveWall(seconds: -5)

        await store.send(.internal(.ticked(generation: 1, isFinal: false))) {
            $0.settle(at: moment(-5))
            $0.clockAnchor = timer.anchor(totalElapsed: .seconds(3))
        }
        #expect(store.state.snapshot.totalElapsed == .seconds(3))
    }

    @Test
    func test_monotonicInstant_sameClock_measuresTheExactDuration() async {
        let clock = TestClock<Duration>()
        let reading = MonotonicInstant(now: clock)

        await clock.advance(by: .milliseconds(1_500))

        #expect(reading.duration(toNowOf: clock) == .milliseconds(1_500))
    }

    @Test
    func test_monotonicInstant_anotherClockType_measuresNothing() {
        let reading = MonotonicInstant(now: TestClock<Duration>())

        #expect(reading.duration(toNowOf: LateClock(lateness: .zero)) == nil)
        #expect(reading.duration(toNowOf: ContinuousClock()) == nil)
    }

    @Test
    func test_monotonicInstant_equality_comparesTypeAndInstant() async {
        let clock = TestClock<Duration>()
        let first = MonotonicInstant(now: clock)

        #expect(first == MonotonicInstant(now: clock))
        #expect(first == MonotonicInstant(now: TestClock<Duration>()))
        #expect(first != MonotonicInstant(now: LateClock(lateness: .zero)))
        await clock.advance(by: .seconds(1))
        #expect(first != MonotonicInstant(now: clock))
    }
}
