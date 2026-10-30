@testable import WorkoutHealth
@testable import WorkoutTimerFeature

import ComposableArchitecture
import Foundation
import Testing
import WorkoutDomain

/// When the timer asks for its workout session and what it sends for the workout. The rest of each action is pinned by
/// the exhaustive timer tests, so these follow only the session.
@MainActor
struct TimerHealthTests {
    private struct Sync: Equatable {
        let owner: UUID
        let revision: Int
        let track: WorkoutHealthTrack
    }

    private struct End: Equatable {
        let owner: UUID
        let track: WorkoutHealthTrack
        let date: Date
    }

    private let starts = LockIsolated<[Date]>([])
    private let syncs = LockIsolated<[Sync]>([])
    private let ends = LockIsolated<[End]>([])

    private func harness(
        _ state: WorkoutTimerFeature.State,
        isSceneActive: Bool = true,
        hasActivityControls: Bool = true,
        followsHealth: Bool = true
    ) -> TimerHarness {
        var state = state
        state.isSceneActive = isSceneActive
        let timer = TimerHarness(state, activity: hasActivityControls, followsHealth: followsHealth)
        timer.store.exhaustivity = .off(showSkippedAssertions: false)
        timer.store.dependencies.workoutHealth.start = { [starts] owner, date in
            #expect(owner == timerID)
            starts.withValue { $0.append(date) }
        }
        timer.store.dependencies.workoutHealth.sync = { [syncs] owner, revision, track in
            syncs.withValue { $0.append(Sync(owner: owner, revision: revision, track: track)) }
        }
        timer.store.dependencies.workoutHealth.end = { [ends] owner, track, date in
            ends.withValue { $0.append(End(owner: owner, track: track, date: date)) }
        }
        return timer
    }

    private func send(_ action: WorkoutTimerFeature.Action, to timer: TimerHarness) async {
        await timer.store.send(action)
        await Task.megaYield()
    }

    /// One second at a time, so every loop wakes at each second it waits for.
    private func advance(_ timer: TimerHarness, seconds: Int) async {
        for _ in 0..<seconds {
            await timer.advance(seconds: 1)
            await Task.megaYield()
        }
    }

    /// A run restored at `origin` after a relaunch, started `elapsed` seconds before it and paused there if `paused`.
    private func restored(
        _ schedule: WorkoutSchedule = Schedules.workRest,
        elapsed: Double,
        paused: Bool = false
    ) -> WorkoutTimerFeature.State {
        var run = WorkoutTimerFeature.State.fresh(schedule).run
        run.start(at: moment(-elapsed))
        if paused { run.pause(at: origin) }
        return WorkoutTimerFeature.State(
            id: timerID,
            workoutID: timerWorkoutID,
            title: "Workout",
            workoutName: "Workout",
            restoring: run,
            at: origin
        )
    }

    /// What Health would get for `track` if nothing stopped it before.
    private func workout(of track: WorkoutHealthTrack?) -> HealthWorkout? {
        track?.workout(closingAt: .distantFuture)
    }

    private func workout(_ start: Double, _ end: Double, pauses: [(Double, Double)] = []) -> HealthWorkout {
        HealthWorkout(
            start: moment(start),
            end: moment(end),
            pauses: pauses.map { DateInterval(start: moment($0.0), end: moment($0.1)) }
        )
    }

    // MARK: - The session

    @Test
    func test_task_activeSceneOnceTheClockStarted_startsTheSessionOnce() async {
        let timer = harness(.appearing())

        await send(.view(.task), to: timer)

        #expect(starts.value == [origin])
        await timer.cancelClockLoop()
    }

    @Test
    func test_task_inactiveScene_startsNoSession() async {
        let timer = harness(.appearing(), isSceneActive: false)

        await send(.view(.task), to: timer)

        #expect(starts.value.isEmpty)
        await timer.cancelClockLoop()
    }

    @Test
    func test_activeScene_beforeTheClockStarted_startsNoSession() async {
        let timer = harness(.fresh())

        await send(.view(.scenePhaseChanged(.active)), to: timer)

        #expect(starts.value.isEmpty)
        await timer.cancelClockLoop()
    }

    @Test
    func test_returnToTheActiveScene_startsAgainButTicksDoNot() async {
        let timer = harness(.appearing())
        await send(.view(.task), to: timer)

        await timer.advance(seconds: 1)
        await Task.megaYield()
        #expect(starts.value == [origin])

        await send(.view(.scenePhaseChanged(.background)), to: timer)
        await send(.view(.scenePhaseChanged(.active)), to: timer)
        // The harness moves the wall clock with the test clock.
        #expect(starts.value == [origin, moment(1)])
        await timer.cancelClockLoop()
    }

    /// Without the control subscription, as when the screen closes before the timer stack's `.activityTask` ran.
    @Test(arguments: [true, false])
    func test_closing_startsNoSessionOnAnActiveSceneBeforeTheCoverGoes(hasActivityControls: Bool) async {
        let timer = harness(.fixture(.finished), hasActivityControls: hasActivityControls)
        // Holds the close before its dismissal, as a slow teardown would.
        let teardown = AsyncStream<Void>.makeStream()
        timer.store.dependencies.timerSession.end = { _ in for await _ in teardown.stream {} }

        await send(.view(.closeButtonTapped), to: timer)
        await send(.view(.scenePhaseChanged(.active)), to: timer)

        #expect(starts.value.isEmpty)
        teardown.continuation.finish()
        await timer.store.finish()
    }

    @Test
    func test_closeConfirmationStay_startsNoSession() async {
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.destination = .closeConfirmation(.closeConfirmation(restart: nil))
        let timer = harness(state)

        await send(.destination(.presented(.closeConfirmation(.stay(restart: nil)))), to: timer)

        #expect(starts.value.isEmpty)
        await timer.cancelClockLoop()
    }

    /// A restored pause that never resumed did not run in this process, so it has no workout either.
    @Test(arguments: [false, true])
    func test_closeBeforeTheClockStarted_endsTheSessionHarmlesslyWithAnEmptyTrack(isRestoredPause: Bool) async {
        var state = isRestoredPause ? restored(elapsed: 3, paused: true) : WorkoutTimerFeature.State.fresh()
        state.recordSync = .stored(nil)
        state.destination = .closeConfirmation(.closeConfirmation(restart: isRestoredPause ? nil : .start))
        let timer = harness(state, followsHealth: !isRestoredPause)

        await advance(timer, seconds: 2)
        await send(.destination(.presented(.closeConfirmation(.finish))), to: timer)
        await timer.store.finish()

        #expect(ends.value == [End(owner: timerID, track: WorkoutHealthTrack(), date: moment(2))])
        #expect(syncs.value.isEmpty)
        #expect(starts.value.isEmpty)
    }

    // MARK: - The track

    @Test(arguments: TimerPhase.allCases)
    func test_healthPhase_eachPhaseOfTheRun(phase: TimerPhase) {
        let schedule = phase == .awaitingUser ? Schedules.withPause : Schedules.workRest
        let state = WorkoutTimerFeature.State.fixture(phase, schedule: schedule)

        let expected: WorkoutHealthTrack.Phase? = switch phase {
            case .startCountdown, .idle: nil
            // Work 10 s and rest 5 s, started 3 s before `origin`.
            case .running: .running(stopsAt: moment(12))
            case .resumeCountdown, .paused, .awaitingUser: .halted
            case .finished: .finished
        }
        #expect(state.healthPhase == expected)
    }

    @Test
    func test_startCountdown_sendsNothingUntilTheRunStartsThenTheFirstRevision() async {
        let timer = harness(.fresh())

        await send(.view(.task), to: timer)
        await advance(timer, seconds: 2)
        #expect(syncs.value.isEmpty)

        await advance(timer, seconds: 1)
        #expect(syncs.value.map(\.revision) == [1])
        #expect(syncs.value.map(\.owner) == [timerID])
        #expect(workout(of: syncs.value.last?.track) == workout(3, 18))
        await timer.cancelClockLoop()
    }

    @Test
    func test_ticksAndNext_sendOnlyChangesWithARisingRevision() async {
        let timer = harness(.appearing())
        await send(.view(.task), to: timer)

        await advance(timer, seconds: 3)
        #expect(syncs.value.isEmpty)

        // The rest of 5 s now stops the run at 8 s instead of 15 s.
        await send(.view(.nextButtonTapped), to: timer)
        #expect(syncs.value.map(\.revision) == [2])
        #expect(syncs.value.last?.track.workout(closingAt: moment(5)) == workout(0, 5))
        #expect(workout(of: syncs.value.last?.track) == workout(0, 8))

        await advance(timer, seconds: 5)
        #expect(syncs.value.map(\.revision) == [2, 3])
        #expect(syncs.value.map(\.owner) == [timerID, timerID])
        #expect(workout(of: syncs.value.last?.track) == workout(0, 8))
        await timer.store.skipReceivedActions(strict: false)
        #expect(timer.store.state.snapshot.status == .finished)

        await advance(timer, seconds: 2)
        #expect(syncs.value.count == 2)
        await timer.cancelClockLoop()
    }

    @Test
    func test_pauseStageListStayCountdownAndFinish_sendOneTrackPerChange() async throws {
        let timer = harness(.fixture(.running))

        await advance(timer, seconds: 1)
        await send(.view(.stagesButtonTapped), to: timer)
        #expect(syncs.value.map(\.revision) == [2])
        #expect(workout(of: syncs.value.last?.track) == workout(0, 1))

        let list = try #require(timer.store.state.path.ids.first)
        await send(.path(.popFrom(id: list)), to: timer)
        await advance(timer, seconds: 1)
        await send(.view(.playPauseButtonTapped), to: timer)
        #expect(syncs.value.map(\.revision) == [2, 3])

        await advance(timer, seconds: 1)
        await send(.view(.closeButtonTapped), to: timer)
        await advance(timer, seconds: 1)
        await send(.destination(.presented(.closeConfirmation(.stay(restart: .resume)))), to: timer)
        await advance(timer, seconds: 2)
        // The resume countdown is a pause of the workout like the close dialog before it.
        #expect(syncs.value.map(\.revision) == [2, 3, 4])
        #expect(workout(of: syncs.value.last?.track) == workout(0, 3, pauses: [(1, 2)]))

        await advance(timer, seconds: 1)
        #expect(syncs.value.map(\.revision) == [2, 3, 4, 5])
        // Of the 12 s left at `origin`, 1 s ran before the list and 1 s before the dialog.
        #expect(workout(of: syncs.value.last?.track) == workout(0, 17, pauses: [(1, 2), (3, 7)]))

        await advance(timer, seconds: 10)
        await timer.store.skipReceivedActions(strict: false)
        #expect(timer.store.state.snapshot.status == .finished)
        #expect(syncs.value.map(\.revision) == [2, 3, 4, 5, 6])
        #expect(workout(of: syncs.value.last?.track) == workout(0, 17, pauses: [(1, 2), (3, 7)]))
        await timer.cancelClockLoop()
    }

    @Test
    func test_restoredRunning_firstActionStartsTheTrackAtItsDate() async {
        let timer = harness(restored(elapsed: 5), followsHealth: false)
        #expect(timer.store.state.healthTrack == WorkoutHealthTrack())

        await send(.view(.task), to: timer)

        #expect(syncs.value.map(\.revision) == [1])
        // The time before the relaunch is in no workout of this process.
        #expect(workout(of: syncs.value.last?.track) == workout(0, 10))
        await timer.cancelClockLoop()
    }

    enum Restored: CaseIterable, Sendable {
        case pausedPlay
        case awaitingUserPlay
        case awaitingUserNext
    }

    @Test(arguments: Restored.allCases)
    func test_restoredPause_startsTheTrackOnlyWhenTheRunGoesOn(restoredRun: Restored) async {
        // Work 10 s and rest 5 s paused with 12 s left, or waiting at the manual pause before the last 2 s.
        let state = restoredRun == .pausedPlay ? restored(elapsed: 3, paused: true) : restored(Schedules.withPause, elapsed: 10)
        let timer = harness(state, followsHealth: false)

        await send(.view(.task), to: timer)
        await advance(timer, seconds: 5)
        #expect(syncs.value.isEmpty)
        #expect(timer.store.state.healthTrack == WorkoutHealthTrack())

        await send(.view(restoredRun == .awaitingUserNext ? .nextButtonTapped : .playPauseButtonTapped), to: timer)

        #expect(syncs.value.map(\.revision) == [1])
        #expect(workout(of: syncs.value.last?.track) == (restoredRun == .pausedPlay ? workout(5, 17) : workout(5, 7)))
        await timer.cancelClockLoop()
    }

    enum FailurePoint: CaseIterable, Sendable {
        case midStage
        case atAManualPause
        case afterTheEnd
    }

    @Test(arguments: FailurePoint.allCases)
    func test_clockFailed_stopsTheTrackAndSendsTheNextRevision(failure: FailurePoint) async {
        let (state, end): (WorkoutTimerFeature.State, Double) = switch failure {
            // Work 10 s and rest 5 s, 12 s left at `origin`: the failure pauses it.
            case .midStage: (.fixture(.running), 2)
            // The warm-up stage ran out at 1 s, into the manual pause.
            case .atAManualPause: (.fixture(.running, schedule: Schedules.withPause, elapsed: 1), 1)
            case .afterTheEnd: (.fixture(.running), 12)
        }
        let timer = harness(state)
        await timer.advance(seconds: failure == .afterTheEnd ? 20 : 2)

        await send(.internal(.clockFailed(generation: 1)), to: timer)

        #expect(syncs.value.map(\.revision) == [2])
        #expect(workout(of: syncs.value.last?.track) == workout(0, end))
        await timer.cancelClockLoop()
    }

    @Test
    func test_closeFromARun_endsWithTheTrackStoppedAtTheCloseButton() async {
        let timer = harness(.fixture(.running))
        await advance(timer, seconds: 2)
        await send(.view(.closeButtonTapped), to: timer)
        await advance(timer, seconds: 3)

        await send(.destination(.presented(.closeConfirmation(.finish))), to: timer)
        await timer.store.finish()

        #expect(ends.value.map(\.date) == [moment(5)])
        #expect(ends.value.first?.track.workout(closingAt: moment(5)) == workout(0, 2))
    }

    @Test
    func test_closeOfARunThatEndedUnseen_endsWithTheTrackFinishedAtItsStop() async {
        let timer = harness(.fixture(.running))
        timer.moveWall(seconds: 20)

        await send(.view(.closeButtonTapped), to: timer)
        await timer.store.finish()

        #expect(ends.value.map(\.date) == [moment(20)])
        #expect(ends.value.first?.track.workout(closingAt: moment(20)) == workout(0, 12))
        var finished = WorkoutHealthTrack()
        finished.follow(.running(stopsAt: moment(12)), at: origin)
        finished.follow(.finished, at: moment(20))
        #expect(ends.value.first?.track == finished)
    }

    @Test
    func test_closing_sendsNoTrackAfterwards() async {
        let timer = harness(.fixture(.running))
        timer.moveWall(seconds: 20)
        // Holds the close before its dismissal, as a slow teardown would.
        let teardown = AsyncStream<Void>.makeStream()
        timer.store.dependencies.timerSession.end = { _ in for await _ in teardown.stream {} }

        await send(.view(.closeButtonTapped), to: timer)
        await send(.view(.scenePhaseChanged(.background)), to: timer)
        await send(.view(.scenePhaseChanged(.active)), to: timer)

        #expect(syncs.value.isEmpty)
        #expect(timer.store.state.healthRevision == 1)
        teardown.continuation.finish()
        await timer.store.finish()
    }
}
