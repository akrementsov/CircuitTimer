@testable import WorkoutTimerFeature

import ComposableArchitecture
import Testing
import WorkoutDomain

@MainActor
@Suite
struct TimerSceneTests {
    @Test
    func test_scenePhaseChanged_closeAlertPresented_refreshesTheSavedRun() async {
        var state = WorkoutTimerFeature.State.fixture(.paused)
        let record = WorkoutRunRecord(workoutID: state.workoutID, run: state.run)
        state.recordSync = .stored(record)
        state.destination = .closeConfirmation(.closeConfirmation(restart: nil))
        let timer = TimerHarness(state)

        await timer.send(.view(.scenePhaseChanged(.background)), saving: true) {
            $0.isInBackground = true
            $0.clockGeneration = 2
        }
        await timer.store.finish()
        #expect(timer.store.state.destination == state.destination)
        #expect(timer.writes.value == [RecordWrite(record: record, revision: 1)])
        #expect(timer.releasedAssertions.value == timer.assertions.value)
    }

    @Test(arguments: TimerPhase.allCases)
    func test_scenePhaseChanged_inactive_doesNotChangeTheRunOrSave(phase: TimerPhase) async {
        let schedule = phase == .awaitingUser ? Schedules.withPause : Schedules.workRest
        let timer = TimerHarness(.fixture(phase, schedule: schedule))
        await timer.advance(seconds: 5)

        await timer.send(.view(.scenePhaseChanged(.inactive)))
        await timer.store.finish()

        #expect(timer.writes.value.isEmpty)
        #expect(timer.assertions.value.isEmpty)
        #expect(timer.calls.value.isEmpty)
    }

    @Test
    func test_scenePhaseChanged_backgroundCountdown_resetsAndWaitsUntilActive() async {
        let timer = TimerHarness(.fresh())
        await timer.send(.view(.task), saving: true) {
            $0.clockGeneration = 1
            $0.requestedAwake = true
            $0.awakeRevision = 1
        }
        await timer.advance(seconds: 1)
        await timer.receive(.internal(.countdownTicked(generation: 1))) { $0.countdown?.remaining = 2 }

        await timer.send(.view(.scenePhaseChanged(.background)), saving: true) {
            $0.isInBackground = true
            $0.countdown?.remaining = 3
            $0.clockGeneration = 2
        }
        await timer.advance(seconds: 20)
        await timer.store.finish()
        #expect(timer.store.state.countdown?.remaining == 3)
        #expect(timer.store.state.snapshot.status == .idle)

        await timer.send(.view(.scenePhaseChanged(.background)))
        await timer.send(.view(.scenePhaseChanged(.active))) {
            $0.isInBackground = false
            $0.clockGeneration = 3
        }
        await timer.send(.view(.scenePhaseChanged(.active)))
        for remaining in [2, 1] {
            await timer.advance(seconds: 1)
            await timer.receive(.internal(.countdownTicked(generation: 3))) { $0.countdown?.remaining = remaining }
        }
        await timer.advance(seconds: 1)
        await timer.receive(.internal(.countdownTicked(generation: 3)), saving: true) {
            $0.countdown = nil
            $0.run.start(at: moment(24))
            $0.settle(at: moment(24))
            $0.clockGeneration = 4
            $0.clockAnchor = timer.anchor(totalElapsed: .zero)
        }
        await timer.send(.view(.playPauseButtonTapped), saving: true) {
            $0.run.pause(at: moment(24))
            $0.settle(at: moment(24))
            $0.clockGeneration = 5
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 2
        }
        await timer.store.finish()
        #expect(timer.writes.value.map(\.revision) == [1, 2, 3, 4])
    }

    @Test(arguments: [false, true])
    func test_scenePhaseChanged_runningAfterSuspension_keepsElapsedTime(clockWentBack: Bool) async {
        let timer = TimerHarness(.fixture(.running))
        timer.store.dependencies.continuousClock = SuspendingClock(base: timer.clock)
        await timer.send(.view(.scenePhaseChanged(.background)), saving: true) {
            $0.isInBackground = true
            $0.clockGeneration = 2
            $0.clockAnchor = timer.anchor(totalElapsed: .seconds(3))
        }
        // The clock instant advances during suspension, but its sleeper cannot deliver a tick.
        await timer.clock.advance(by: .seconds(4))
        timer.moveWall(seconds: clockWentBack ? -10 : 4)
        let now = timer.now

        await timer.send(.view(.scenePhaseChanged(.active)), saving: true) {
            $0.isInBackground = false
            if clockWentBack {
                $0.run.rebase(at: now, keepingTotalElapsed: .seconds(7))
                $0.healthTrack.rebase(from: moment(4), to: now)
            }
            $0.settle(at: now)
            $0.clockGeneration = 3
            $0.clockAnchor = timer.anchor(totalElapsed: .seconds(7))
        }
        #expect(timer.store.state.snapshot.totalElapsed == .seconds(7))
        #expect(timer.store.state.snapshot.status == .running)
        await timer.send(.view(.playPauseButtonTapped), saving: true) {
            $0.run.pause(at: now)
            $0.settle(at: now)
            $0.clockGeneration = 4
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 2
        }
        await timer.store.finish()
    }

    @Test
    func test_scenePhaseChanged_elapsedAcrossAManualPause_waitsForTheUser() async {
        let timer = TimerHarness(.fixture(.running, schedule: Schedules.withPause, elapsed: 1))
        timer.store.dependencies.continuousClock = SuspendingClock(base: timer.clock)
        await timer.send(.view(.scenePhaseChanged(.background)), saving: true) {
            $0.isInBackground = true
            $0.clockGeneration = 2
            $0.clockAnchor = timer.anchor(totalElapsed: .seconds(1))
        }
        await timer.advance(seconds: 5)

        await timer.send(.view(.scenePhaseChanged(.active)), saving: true) {
            $0.isInBackground = false
            $0.settle(at: moment(5))
            $0.clockGeneration = 3
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 2
        }
        await timer.store.finish()

        #expect(timer.store.state.snapshot.status == .awaitingUser)
        #expect(timer.store.state.snapshot.totalElapsed == .seconds(2))
    }

    @Test
    func test_scenePhaseChanged_pausedRun_refreshesTheRecordWithoutAdvancing() async {
        let timer = TimerHarness(.fixture(.paused))
        await timer.send(.view(.scenePhaseChanged(.background)), saving: true) {
            $0.isInBackground = true
            $0.clockGeneration = 2
        }
        await timer.advance(seconds: 100)
        await timer.send(.view(.scenePhaseChanged(.active))) {
            $0.isInBackground = false
            $0.clockGeneration = 3
        }
        await timer.store.finish()

        await timer.send(.view(.scenePhaseChanged(.background)), saving: true) {
            $0.isInBackground = true
            $0.clockGeneration = 4
        }
        await timer.store.finish()

        #expect(timer.store.state.snapshot.totalElapsed == .seconds(3))
        #expect(timer.writes.value.count == 2)
        #expect(timer.releasedAssertions.value == timer.assertions.value)
    }
}
