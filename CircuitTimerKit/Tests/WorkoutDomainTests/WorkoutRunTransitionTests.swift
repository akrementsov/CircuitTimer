@testable import WorkoutDomain

import Foundation
import Testing

/// The phase × operation table from docs/timer-engine.md, on the 25 s fixture:
/// 0 work 0–10 s, 1 rest 10–15 s, 2 manual pause at 15 s, 3 work 15–25 s.
@Suite
struct WorkoutRunTransitionTests {
    private let later = moment(3_600)

    @Test
    func test_operations_emptySchedule_leaveRunFinished() {
        let run = makeRun(Workout(id: UUID(fixture: 0)))

        #expect(run.phase == .finished)
        for operation in RunOperation.all {
            #expect(operation.applied(to: run, at: moment(5)) == run, "\(operation)")
        }
        #expect(run.snapshot(at: moment(5)).status == .finished)
        #expect(run.snapshot(at: moment(5)).totalElapsed == .zero)
    }

    @Test
    func test_operations_idle_onlyStartBeginsTheFirstStage() {
        let idle = makeRun(makePausedWorkout())

        for operation in RunOperation.allExceptStart {
            #expect(operation.applied(to: idle, at: later) == idle, "\(operation)")
        }
        let started = RunOperation.start.applied(to: idle, at: moment(1))
        #expect(RunState(started) == RunState(.running(since: moment(1)), cursor: 0, position: .zero))
    }

    /// No-op operations still commit the time elapsed until `now`.
    @Test(arguments: [
        (RunOperation.tick, RunState(.running(since: moment(3)), cursor: 0, position: .seconds(3))),
        (.start, RunState(.running(since: moment(3)), cursor: 0, position: .seconds(3))),
        (.resume, RunState(.running(since: moment(3)), cursor: 0, position: .seconds(3))),
        (.rebase(.seconds(1)), RunState(.running(since: moment(3)), cursor: 0, position: .seconds(3))),
        (.rebase(.seconds(7)), RunState(.running(since: moment(3)), cursor: 0, position: .seconds(7))),
        (.pause, RunState(.paused, cursor: 0, position: .seconds(3))),
        (.skip, RunState(.running(since: moment(3)), cursor: 1, position: .seconds(10))),
    ])
    func test_operations_running_followTable(operation: RunOperation, expected: RunState) {
        let running = RunOperation.start.applied(to: makeRun(makePausedWorkout()), at: origin)

        #expect(RunState(operation.applied(to: running, at: moment(3))) == expected)
    }

    @Test(arguments: [
        (RunOperation.tick, RunState(.paused, cursor: 0, position: .seconds(3))),
        (.start, RunState(.paused, cursor: 0, position: .seconds(3))),
        (.pause, RunState(.paused, cursor: 0, position: .seconds(3))),
        (.rebase(.seconds(7)), RunState(.paused, cursor: 0, position: .seconds(3))),
        (.resume, RunState(.running(since: moment(3_600)), cursor: 0, position: .seconds(3))),
        (.skip, RunState(.paused, cursor: 1, position: .seconds(10))),
    ])
    func test_operations_paused_followTableWhileTimeDoesNotFlow(operation: RunOperation, expected: RunState) {
        var paused = RunOperation.start.applied(to: makeRun(makePausedWorkout()), at: origin)
        paused.pause(at: moment(3))

        #expect(RunState(operation.applied(to: paused, at: later)) == expected)
    }

    @Test(arguments: [
        (RunOperation.tick, RunState(.awaitingUser, cursor: 2, position: .seconds(15))),
        (.start, RunState(.awaitingUser, cursor: 2, position: .seconds(15))),
        (.pause, RunState(.awaitingUser, cursor: 2, position: .seconds(15))),
        (.rebase(.seconds(20)), RunState(.awaitingUser, cursor: 2, position: .seconds(15))),
        (.resume, RunState(.running(since: moment(3_600)), cursor: 3, position: .seconds(15))),
        (.skip, RunState(.running(since: moment(3_600)), cursor: 3, position: .seconds(15))),
    ])
    func test_operations_awaitingUser_onlyResumeAndSkipLeaveThePause(operation: RunOperation, expected: RunState) {
        var awaiting = RunOperation.start.applied(to: makeRun(makePausedWorkout()), at: origin)
        awaiting.tick(at: moment(20))

        #expect(RunState(operation.applied(to: awaiting, at: later)) == expected)
    }

    @Test
    func test_operations_finished_changeNothing() {
        var finished = RunOperation.start.applied(to: makeRun(singleStageWorkout()), at: origin)
        finished.tick(at: moment(11))

        #expect(RunState(finished) == RunState(.finished, cursor: 1, position: .seconds(10)))
        for operation in RunOperation.all {
            #expect(operation.applied(to: finished, at: later) == finished, "\(operation)")
        }
    }

    @Test
    func test_skip_onLastStage_finishesFromRunningAndPaused() {
        let running = RunOperation.start.applied(to: makeRun(singleStageWorkout()), at: origin)
        let paused = RunOperation.pause.applied(to: running, at: moment(2))
        let finished = RunState(.finished, cursor: 1, position: .seconds(10))

        #expect(RunState(RunOperation.skip.applied(to: running, at: moment(2))) == finished)
        #expect(RunState(RunOperation.skip.applied(to: paused, at: moment(3))) == finished)
    }

    @Test
    func test_skip_runningOntoManualPause_waitsForUser() {
        var run = RunOperation.start.applied(to: makeRun(makePausedWorkout()), at: origin)
        run.skipToNextStage(at: moment(1))
        run.skipToNextStage(at: moment(2))

        #expect(RunState(run) == RunState(.awaitingUser, cursor: 2, position: .seconds(15)))
    }

    /// Review focus 2: skipping from a paused stage onto a manual pause and resuming passes it exactly once.
    @Test
    func test_skipFromPausedThenResume_passesManualPauseOnce() {
        var run = RunOperation.start.applied(to: makeRun(makePausedWorkout()), at: origin)
        run.skipToNextStage(at: moment(1))
        run.pause(at: moment(2))
        run.skipToNextStage(at: moment(3))
        #expect(RunState(run) == RunState(.awaitingUser, cursor: 2, position: .seconds(15)))

        run.resume(at: moment(4))
        #expect(RunState(run) == RunState(.running(since: moment(4)), cursor: 3, position: .seconds(15)))

        run.resume(at: moment(5))
        #expect(RunState(run) == RunState(.running(since: moment(5)), cursor: 3, position: .seconds(16)))
    }

    private func singleStageWorkout() -> Workout {
        Workout(id: UUID(fixture: 901), warmUp: [makeStage(1, .seconds(10))])
    }
}
