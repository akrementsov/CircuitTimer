@testable import WorkoutTimerFeature

import ComposableArchitecture
import Foundation
import Testing
import WorkoutDomain

@MainActor
@Suite
struct TimerStageListTests {
    private typealias State = WorkoutTimerFeature.State
    private typealias Countdown = WorkoutTimerFeature.Countdown

    @Test(arguments: TimerPhase.allCases)
    func test_stagesButtonTapped_eachPhase_stopsTheClockAndPushesTheOutline(phase: TimerPhase) async {
        let schedule = phase == .awaitingUser ? Schedules.withPause : Schedules.workRest
        let timer = TimerHarness(.fixture(phase, schedule: schedule), activity: true)
        let activity = timer.recordActivity()
        let store = timer.store
        let expectedCalls: [TimerCall]

        switch phase {
            case .startCountdown, .resumeCountdown:
                let status = store.state.snapshot.status
                await timer.send(.view(.stagesButtonTapped), saving: true) {
                    $0.countdown = nil
                    $0.clockGeneration = 2
                    $0.activityControls?.generation = 1
                    $0.requestedAwake = false
                    $0.awakeRevision = 2
                    $0.path.append(.stageList($0.outline))
                }
                #expect(store.state.snapshot.status == status)
                expectedCalls = [.awake(false, 2)]
            case .running:
                await timer.send(.view(.stagesButtonTapped), saving: true) {
                    $0.run.pause(at: origin)
                    $0.settle(at: origin)
                    $0.clockGeneration = 2
                    $0.activityControls?.generation = 1
                    $0.clockAnchor = nil
                    $0.requestedAwake = false
                    $0.awakeRevision = 2
                    $0.path.append(.stageList($0.outline))
                }
                #expect(store.state.snapshot.status == .paused)
                expectedCalls = [.awake(false, 2)]
            case .idle, .paused, .awaitingUser, .finished:
                await timer.send(.view(.stagesButtonTapped)) { $0.path.append(.stageList($0.outline)) }
                expectedCalls = []
        }
        #expect(store.state.outline == WorkoutOutline(schedule: schedule))
        await store.finish()
        #expect(timer.calls.value == expectedCalls)
        let expectedGeneration = [TimerPhase.running, .startCountdown, .resumeCountdown].contains(phase) ? 1 : 0
        #expect(activity.syncs.value.last?.content.controlGeneration == expectedGeneration)
    }

    @Test
    func test_stagesButtonTapped_runningTickLoop_cancelsIt() async {
        let timer = TimerHarness(.fresh())
        let store = timer.store
        await timer.send(.view(.task), saving: true) {
            $0.clockGeneration = 1
            $0.requestedAwake = true
            $0.awakeRevision = 1
        }
        for remaining in [2, 1] {
            await timer.advance(seconds: 1)
            await timer.receive(.internal(.countdownTicked(generation: 1))) { $0.countdown?.remaining = remaining }
        }
        await timer.advance(seconds: 1)
        await timer.receive(.internal(.countdownTicked(generation: 1)), saving: true) {
            $0.countdown = nil
            $0.run.start(at: moment(3))
            $0.settle(at: moment(3))
            $0.clockGeneration = 2
            $0.clockAnchor = timer.anchor(totalElapsed: .zero)
        }

        await timer.send(.view(.stagesButtonTapped), saving: true) {
            $0.run.pause(at: moment(3))
            $0.settle(at: moment(3))
            $0.clockGeneration = 3
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 2
            $0.path.append(.stageList($0.outline))
        }
        // A tick loop still running would deliver a tick here.
        await timer.advance(seconds: 20)
        await store.finish()

        #expect(store.state.snapshot.totalElapsed == .zero)
        #expect(timer.calls.value == [.awake(true, 1), .awake(false, 2)])
    }

    @Test
    func test_stagesButtonTapped_countdownLoop_cancelsItAndIgnoresItsLateTick() async {
        let timer = TimerHarness(.fresh())
        let store = timer.store
        await timer.send(.view(.task), saving: true) {
            $0.clockGeneration = 1
            $0.requestedAwake = true
            $0.awakeRevision = 1
        }
        await timer.advance(seconds: 1)
        await timer.receive(.internal(.countdownTicked(generation: 1))) { $0.countdown?.remaining = 2 }

        await timer.send(.view(.stagesButtonTapped)) {
            $0.countdown = nil
            $0.clockGeneration = 2
            $0.requestedAwake = false
            $0.awakeRevision = 2
            $0.path.append(.stageList($0.outline))
        }
        await timer.advance(seconds: 5)
        // A tick the old loop sent before its cancel landed only cancels that loop again.
        await timer.send(.internal(.countdownTicked(generation: 1)))
        await store.finish()

        #expect(store.state.snapshot.status == .idle)
        #expect(timer.calls.value == [.awake(true, 1), .awake(false, 2)])
    }

    @Test
    func test_stagesButtonTapped_listAlreadyPushed_opensNothing() async {
        var state = State.fixture(.running)
        state.path.append(.stageList(state.outline))
        let timer = TimerHarness(state)

        await timer.send(.view(.stagesButtonTapped))

        #expect(timer.calls.value.isEmpty)
        await timer.cancelClockLoop()
    }

    @Test
    func test_pop_listOpenedOverARunningStage_keepsTheRunPaused() async throws {
        let timer = TimerHarness(.fixture(.running))
        let store = timer.store
        await timer.send(.view(.stagesButtonTapped), saving: true) {
            $0.run.pause(at: origin)
            $0.settle(at: origin)
            $0.clockGeneration = 2
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 2
            $0.path.append(.stageList($0.outline))
        }

        let listID = try #require(store.state.path.ids.first)
        await timer.send(.path(.popFrom(id: listID))) { $0.path = StackState() }
        await timer.advance(seconds: 20)
        await store.finish()

        #expect(store.state.snapshot.status == .paused)
        #expect(timer.calls.value == [.awake(false, 2)])
    }

    @Test
    func test_playAfterPop_listOpenedOverTheStartCountdown_startsItAgain() async throws {
        let timer = TimerHarness(.fixture(.startCountdown))
        let store = timer.store
        await timer.send(.view(.stagesButtonTapped), saving: true) {
            $0.countdown = nil
            $0.clockGeneration = 2
            $0.requestedAwake = false
            $0.awakeRevision = 2
            $0.path.append(.stageList($0.outline))
        }
        let listID = try #require(store.state.path.ids.first)
        await timer.send(.path(.popFrom(id: listID))) { $0.path = StackState() }

        await timer.send(.view(.playPauseButtonTapped)) {
            $0.countdown = Countdown(.start)
            $0.clockGeneration = 3
            $0.requestedAwake = true
            $0.awakeRevision = 3
        }

        #expect(timer.calls.value == [.awake(false, 2), .awake(true, 3)])
        await timer.cancelClockLoop()
    }

    @Test
    func test_stagesButtonTapped_runReachedAManualPauseSinceTheLastTick_usesTheSettledRun() async {
        let timer = TimerHarness(.fixture(.running, schedule: Schedules.withPause, elapsed: 1))
        let store = timer.store
        await timer.advance(seconds: 2)

        await timer.send(.view(.stagesButtonTapped), saving: true) {
            $0.settle(at: moment(2))
            $0.clockGeneration = 2
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 2
            $0.path.append(.stageList($0.outline))
        }

        #expect(store.state.snapshot.status == .awaitingUser)
        #expect(timer.calls.value == [.awake(false, 2)])
    }

    @Test
    func test_stagesButtonTapped_runFinishedSinceTheLastTick_stopsTheClock() async {
        let timer = TimerHarness(.fixture(.running))
        let store = timer.store
        await timer.advance(seconds: 20)

        await timer.send(.view(.stagesButtonTapped), saving: true) {
            $0.settle(at: moment(20))
            $0.clockGeneration = 2
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 2
            $0.path.append(.stageList($0.outline))
        }

        #expect(store.state.snapshot.status == .finished)
        #expect(timer.calls.value == [.awake(false, 2)])
    }
}
