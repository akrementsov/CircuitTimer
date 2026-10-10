@testable import WorkoutTimerFeature

import ComposableArchitecture
import Foundation
import Testing
import WorkoutDomain

@MainActor
@Suite
struct TimerControlTests {
    private typealias State = WorkoutTimerFeature.State
    private typealias Countdown = WorkoutTimerFeature.Countdown

    private static func schedule(for phase: TimerPhase) -> WorkoutSchedule {
        phase == .awaitingUser ? Schedules.withPause : Schedules.workRest
    }

    @Test(arguments: TimerPhase.allCases)
    func test_playPause_eachPhase_movesToItsCounterpart(phase: TimerPhase) async {
        let timer = TimerHarness(.fixture(phase, schedule: Self.schedule(for: phase)))
        let store = timer.store
        let expectedCalls: [TimerCall]

        switch phase {
            case .startCountdown, .resumeCountdown:
                let status = store.state.snapshot.status
                await store.send(.view(.playPauseButtonTapped)) {
                    $0.countdown = nil
                    $0.clockGeneration = 2
                    $0.requestedAwake = false
                    $0.awakeRevision = 2
                }
                #expect(store.state.snapshot.status == status)
                expectedCalls = [.awake(false, 2)]
            case .idle:
                await store.send(.view(.playPauseButtonTapped)) {
                    $0.countdown = Countdown(.start)
                    $0.clockGeneration = 2
                    $0.requestedAwake = true
                    $0.awakeRevision = 3
                }
                expectedCalls = [.awake(true, 3)]
            case .running:
                await store.send(.view(.playPauseButtonTapped)) {
                    $0.run.pause(at: origin)
                    $0.settle(at: origin)
                    $0.clockGeneration = 2
                    $0.clockAnchor = nil
                    $0.requestedAwake = false
                    $0.awakeRevision = 2
                }
                expectedCalls = [.awake(false, 2)]
            case .paused, .awaitingUser:
                await store.send(.view(.playPauseButtonTapped)) {
                    $0.run.resume(at: origin)
                    $0.settle(at: origin)
                    $0.clockGeneration = 2
                    $0.clockAnchor = timer.anchor(totalElapsed: $0.snapshot.totalElapsed)
                    $0.requestedAwake = true
                    $0.awakeRevision = 3
                }
                #expect(store.state.snapshot.status == .running)
                expectedCalls = [.awake(true, 3)]
            case .finished:
                await store.send(.view(.playPauseButtonTapped))
                expectedCalls = []
        }
        await timer.cancelClockLoop()
        #expect(timer.calls.value == expectedCalls)
    }

    @Test(arguments: TimerPhase.allCases)
    func test_next_eachPhase_movesOnOrStarts(phase: TimerPhase) async {
        let timer = TimerHarness(.fixture(phase, schedule: Self.schedule(for: phase)))
        let store = timer.store
        let expectedCalls: [TimerCall]

        switch phase {
            case .startCountdown, .idle:
                // Next before the start starts the first stage; it does not skip it.
                await store.send(.view(.nextButtonTapped)) {
                    $0.countdown = nil
                    $0.run.start(at: origin)
                    $0.settle(at: origin)
                    $0.clockGeneration = 2
                    $0.clockAnchor = timer.anchor(totalElapsed: .zero)
                    $0.requestedAwake = true
                    $0.awakeRevision = phase == .idle ? 3 : 1
                }
                #expect(store.state.snapshot.currentStage?.index == 0)
                expectedCalls = phase == .idle ? [.awake(true, 3)] : []
            case .resumeCountdown:
                // The stay countdown was about to resume, so the next stage runs.
                await store.send(.view(.nextButtonTapped)) {
                    $0.countdown = nil
                    $0.run.resume(at: origin)
                    $0.run.skipToNextStage(at: origin)
                    $0.settle(at: origin)
                    $0.clockGeneration = 2
                    $0.clockAnchor = timer.anchor(totalElapsed: .seconds(10))
                }
                #expect(store.state.snapshot.status == .running)
                expectedCalls = []
            case .running:
                await store.send(.view(.nextButtonTapped)) {
                    $0.run.skipToNextStage(at: origin)
                    $0.settle(at: origin)
                    $0.clockGeneration = 2
                    $0.clockAnchor = timer.anchor(totalElapsed: .seconds(10))
                }
                expectedCalls = []
            case .paused:
                // A plain pause stays paused on the next stage.
                await store.send(.view(.nextButtonTapped)) {
                    $0.run.skipToNextStage(at: origin)
                    $0.settle(at: origin)
                    $0.clockGeneration = 2
                }
                #expect(store.state.snapshot.status == .paused)
                #expect(store.state.snapshot.currentStage?.index == 1)
                expectedCalls = []
            case .awaitingUser:
                await store.send(.view(.nextButtonTapped)) {
                    $0.run.skipToNextStage(at: origin)
                    $0.settle(at: origin)
                    $0.clockGeneration = 2
                    $0.clockAnchor = timer.anchor(totalElapsed: .seconds(2))
                    $0.requestedAwake = true
                    $0.awakeRevision = 3
                }
                #expect(store.state.snapshot.currentStage?.index == 2)
                expectedCalls = [.awake(true, 3)]
            case .finished:
                await store.send(.view(.nextButtonTapped))
                expectedCalls = []
        }
        await timer.cancelClockLoop()
        #expect(timer.calls.value == expectedCalls)
    }

    @Test
    func test_next_runningOnTheLastStage_finishesAndLetsTheScreenSleep() async {
        let timer = TimerHarness(.fixture(.running, elapsed: 12))
        let store = timer.store

        await store.send(.view(.nextButtonTapped)) {
            $0.run.skipToNextStage(at: origin)
            $0.settle(at: origin)
            $0.clockGeneration = 2
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 2
        }
        #expect(store.state.snapshot.status == .finished)
        #expect(timer.calls.value == [.awake(false, 2)])
    }

    @Test(arguments: [false, true])
    func test_playOrNext_finishedByTheSettle_stopsTheClock(isNext: Bool) async {
        let timer = TimerHarness(.fixture(.running))
        let store = timer.store
        await timer.advance(seconds: 20)

        await store.send(.view(isNext ? .nextButtonTapped : .playPauseButtonTapped)) {
            $0.settle(at: moment(20))
            $0.clockGeneration = 2
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 2
        }
        #expect(store.state.snapshot.status == .finished)
        // Once finished, nothing changes: no sync, no request.
        await store.send(.view(isNext ? .nextButtonTapped : .playPauseButtonTapped))
        #expect(timer.calls.value == [.awake(false, 2)])
    }

    @Test(arguments: [TimerPhase.startCountdown, .resumeCountdown, .running, .idle, .paused, .awaitingUser])
    func test_closeThenStay_eachPhase_restartsTheCountdownItStopped(phase: TimerPhase) async {
        let timer = TimerHarness(.fixture(phase, schedule: Self.schedule(for: phase)))
        let store = timer.store
        let restart: Countdown.Purpose? = switch phase {
            case .startCountdown: .start
            case .resumeCountdown, .running: .resume
            case .idle, .paused, .awaitingUser, .finished: nil
        }

        await store.send(.view(.closeButtonTapped)) {
            $0.destination = .closeConfirmation(.closeConfirmation(restart: restart))
            guard restart != nil else { return }

            $0.countdown = nil
            if phase == .running {
                $0.run.pause(at: origin)
                $0.settle(at: origin)
                $0.clockAnchor = nil
            }
            $0.clockGeneration = 2
            $0.requestedAwake = false
            $0.awakeRevision = 2
        }
        await store.send(.destination(.presented(.closeConfirmation(.stay(restart: restart))))) {
            $0.destination = nil
            guard let restart else { return }

            $0.countdown = Countdown(restart)
            $0.clockGeneration = 3
            $0.requestedAwake = true
            $0.awakeRevision = 3
        }
        await timer.cancelClockLoop()
        #expect(timer.calls.value == (restart == nil ? [] : [.awake(false, 2), .awake(true, 3)]))
    }

    @Test
    func test_close_runReachedAManualPauseSinceTheLastTick_asksWithoutRestart() async {
        let timer = TimerHarness(.fixture(.running, schedule: Schedules.withPause, elapsed: 1))
        let store = timer.store
        await timer.advance(seconds: 2)

        await store.send(.view(.closeButtonTapped)) {
            $0.settle(at: moment(2))
            $0.destination = .closeConfirmation(.closeConfirmation(restart: nil))
            $0.clockGeneration = 2
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 2
        }
        #expect(store.state.snapshot.status == .awaitingUser)
        #expect(timer.calls.value == [.awake(false, 2)])
    }

    @Test
    func test_closeConfirmationAlert_buttons_mapStayAndFinish() {
        let alert = AlertState<WorkoutTimerFeature.CloseConfirmation>.closeConfirmation(restart: .start)

        #expect(alert.buttons.map(\.role) == [.cancel, .destructive])
        #expect(alert.buttons.map(\.action) == [.send(.stay(restart: .start)), .send(.finish)])
    }

    @Test
    func test_close_systemDismissesTheAlert_leavesTheClockStopped() async {
        let timer = TimerHarness(.fixture(.running))
        let store = timer.store

        await store.send(.view(.closeButtonTapped)) {
            $0.run.pause(at: origin)
            $0.settle(at: origin)
            $0.destination = .closeConfirmation(.closeConfirmation(restart: .resume))
            $0.clockGeneration = 2
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 2
        }
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        #expect(timer.calls.value == [.awake(false, 2)])
    }

    @Test
    func test_closeThenStay_running_resumesAfterTheCountdownOnce() async {
        let timer = TimerHarness(.appearing(elapsed: 3))
        let store = timer.store
        await timer.appearRunning()

        await store.send(.view(.closeButtonTapped)) {
            $0.run.pause(at: origin)
            $0.settle(at: origin)
            $0.destination = .closeConfirmation(.closeConfirmation(restart: .resume))
            $0.clockGeneration = 2
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 2
        }
        await store.send(.destination(.presented(.closeConfirmation(.stay(restart: .resume))))) {
            $0.destination = nil
            $0.countdown = Countdown(.resume)
            $0.clockGeneration = 3
            $0.requestedAwake = true
            $0.awakeRevision = 3
        }
        await timer.advance(seconds: 1)
        await store.receive(.internal(.countdownTicked(generation: 3))) { $0.countdown?.remaining = 2 }
        await timer.advance(seconds: 1)
        await store.receive(.internal(.countdownTicked(generation: 3))) { $0.countdown?.remaining = 1 }
        await timer.advance(seconds: 1)
        await store.receive(.internal(.countdownTicked(generation: 3))) {
            $0.countdown = nil
            $0.run.resume(at: moment(3))
            $0.settle(at: moment(3))
            $0.clockGeneration = 4
            $0.clockAnchor = timer.anchor(totalElapsed: .seconds(3))
        }
        #expect(store.state.run.phase == .running(since: moment(3)))
        #expect(store.state.snapshot.totalElapsed == .seconds(3))

        await store.send(.view(.playPauseButtonTapped)) {
            $0.run.pause(at: moment(3))
            $0.settle(at: moment(3))
            $0.clockGeneration = 5
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 4
        }
        #expect(timer.calls.value == [.awake(true, 1), .awake(false, 2), .awake(true, 3), .awake(false, 4)])
    }

    @Test
    func test_close_finished_endsTheSessionThenDismisses() async {
        let timer = TimerHarness(.fixture(.finished))
        let store = timer.store

        await store.send(.view(.closeButtonTapped)) { $0.clockGeneration = 2 }
        await store.finish()

        #expect(store.state.destination == nil)
        #expect(timer.calls.value == [.end(owner: timerID), .dismiss])
    }

    @Test
    func test_close_runFinishedSinceTheLastTick_stopsTheClockThenCloses() async {
        let timer = TimerHarness(.fixture(.running))
        let store = timer.store
        await timer.advance(seconds: 20)

        await store.send(.view(.closeButtonTapped)) {
            $0.settle(at: moment(20))
            $0.clockGeneration = 2
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 2
        }
        await store.finish()

        #expect(store.state.destination == nil)
        // The vote and the close run side by side; `end` drops the vote either way.
        #expect(timer.calls.value.contains(.awake(false, 2)))
        #expect(timer.calls.value.filter { $0 != .awake(false, 2) } == [.end(owner: timerID), .dismiss])
    }

    @Test
    func test_closeThenFinish_running_endsTheSessionBeforeDismissing() async {
        let timer = TimerHarness(.fixture(.running))
        let store = timer.store

        await store.send(.view(.closeButtonTapped)) {
            $0.run.pause(at: origin)
            $0.settle(at: origin)
            $0.destination = .closeConfirmation(.closeConfirmation(restart: .resume))
            $0.clockGeneration = 2
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 2
        }
        await store.send(.destination(.presented(.closeConfirmation(.finish)))) { $0.destination = nil }
        await store.finish()

        #expect(timer.calls.value == [.awake(false, 2), .end(owner: timerID), .dismiss])
    }

    @Test(arguments: [
        WorkoutTimerFeature.Action.View.closeButtonTapped,
        .playPauseButtonTapped,
        .nextButtonTapped,
    ])
    func test_viewAction_alertShown_isIgnored(action: WorkoutTimerFeature.Action.View) async {
        var state = State.fixture(.paused)
        state.destination = .closeConfirmation(.closeConfirmation(restart: .resume))
        let timer = TimerHarness(state)

        await timer.store.send(.view(action))
        #expect(timer.calls.value.isEmpty)
    }

    @Test
    func test_task_alertShownBeforeTheFirstAppearance_syncsTheClock() async {
        var state = State.fresh()
        state.countdown = nil
        state.destination = .closeConfirmation(.closeConfirmation(restart: nil))
        let timer = TimerHarness(state)

        await timer.store.send(.view(.task)) { $0.clockGeneration = 1 }
        #expect(timer.calls.value.isEmpty)
    }

    @Test
    func test_keepAwakeVote_acrossControls_isSentOnlyWhenItChanges() async {
        let timer = TimerHarness(.fresh())
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
        let now = moment(3)
        await store.receive(.internal(.countdownTicked(generation: 1))) {
            $0.countdown = nil
            $0.run.start(at: now)
            $0.settle(at: now)
            $0.clockGeneration = 2
            $0.clockAnchor = timer.anchor(totalElapsed: .zero)
        }
        await store.send(.view(.playPauseButtonTapped)) {
            $0.run.pause(at: now)
            $0.settle(at: now)
            $0.clockGeneration = 3
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 2
        }
        await store.send(.view(.nextButtonTapped)) {
            $0.run.skipToNextStage(at: now)
            $0.settle(at: now)
            $0.clockGeneration = 4
        }
        await store.send(.view(.playPauseButtonTapped)) {
            $0.run.resume(at: now)
            $0.settle(at: now)
            $0.clockGeneration = 5
            $0.clockAnchor = timer.anchor(totalElapsed: .seconds(10))
            $0.requestedAwake = true
            $0.awakeRevision = 3
        }
        await store.send(.view(.closeButtonTapped)) {
            $0.run.pause(at: now)
            $0.settle(at: now)
            $0.destination = .closeConfirmation(.closeConfirmation(restart: .resume))
            $0.clockGeneration = 6
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 4
        }
        await store.send(.destination(.presented(.closeConfirmation(.stay(restart: .resume))))) {
            $0.destination = nil
            $0.countdown = Countdown(.resume)
            $0.clockGeneration = 7
            $0.requestedAwake = true
            $0.awakeRevision = 5
        }
        await store.send(.view(.playPauseButtonTapped)) {
            $0.countdown = nil
            $0.clockGeneration = 8
            $0.requestedAwake = false
            $0.awakeRevision = 6
        }

        #expect(timer.calls.value == [
            .awake(true, 1), .awake(false, 2), .awake(true, 3), .awake(false, 4), .awake(true, 5), .awake(false, 6),
        ])
    }
}
