@testable import WorkoutDomain

import Foundation
import Testing

/// How a run follows wall-clock time on the 25 s fixture:
/// 0 work 0–10 s, 1 rest 10–15 s, 2 manual pause at 15 s, 3 work 15–25 s.
@Suite
struct WorkoutRunTimeTests {
    private let running = RunOperation.start.applied(to: makeRun(makePausedWorkout()), at: origin)

    // MARK: - Background

    @Test
    func test_hourInBackground_tickAndPauseStopAtManualPause() {
        let later = moment(3_600)

        #expect(running.snapshot(at: later).currentStage?.kind == .pause)
        for operation in [RunOperation.tick, .pause] {
            #expect(RunState(operation.applied(to: running, at: later)) == RunState(.awaitingUser, cursor: 2, position: .seconds(15)))
        }
    }

    @Test
    func test_hourInBackground_resumeAndSkipPassManualPause() {
        let later = moment(3_600)

        let expected = RunState(.running(since: later), cursor: 3, position: .seconds(15))
        for operation in [RunOperation.resume, .skip] {
            #expect(RunState(operation.applied(to: running, at: later)) == expected)
        }
    }

    @Test
    func test_hourInBackground_withoutManualPause_finishes() {
        let workout = Workout(
            id: UUID(fixture: 902),
            warmUp: [makeStage(1, .seconds(10)), makeStage(2, .seconds(5), .rest)],
            training: [makeStage(3, .seconds(10))]
        )
        var run = RunOperation.start.applied(to: makeRun(workout), at: origin)
        run.tick(at: moment(3_600))

        #expect(RunState(run) == RunState(.finished, cursor: 3, position: .seconds(25)))
    }

    // MARK: - Stage boundaries

    @Test
    func test_stageEndDate_exactly_showsNextStage() throws {
        let end = try #require(running.snapshot(at: origin).currentStageEndDate)

        #expect(end == moment(10))
        #expect(running.snapshot(at: end).currentStage?.index == 1)
        #expect(running.snapshot(at: end.addingTimeInterval(-0.000_002)).currentStage?.index == 0)
        #expect(running.snapshot(at: end.addingTimeInterval(-0.000_000_5)).currentStage?.index == 1)

        var ticked = running
        ticked.tick(at: end)
        #expect(RunState(ticked) == RunState(.running(since: end), cursor: 1, position: .seconds(10)))
    }

    @Test
    func test_stageEndDate_beforeManualPauseAndOfLastStage_waitOrFinish() throws {
        #expect(running.snapshot(at: moment(15)).status == .awaitingUser)

        var lastStage = running
        lastStage.tick(at: moment(20))
        lastStage.resume(at: moment(20))
        let end = try #require(lastStage.snapshot(at: moment(20)).currentStageEndDate)
        #expect(lastStage.snapshot(at: end).status == .finished)
    }

    @Test
    func test_oneMillisecondStages_areNotSkippedByRounding() {
        let workout = Workout(id: UUID(fixture: 903), warmUp: [makeStage(1, .milliseconds(1)), makeStage(2, .milliseconds(1))])
        let run = RunOperation.start.applied(to: makeRun(workout), at: origin)

        #expect(run.snapshot(at: moment(0.001)).currentStage?.index == 1)
        #expect(run.snapshot(at: moment(0.002)).status == .finished)
    }

    // MARK: - Clock changes

    @Test
    func test_clockMovedBackPastAnchor_keepsProgressAndContinues() {
        var run = running
        run.tick(at: moment(5))
        run.tick(at: origin)

        #expect(RunState(run) == RunState(.running(since: origin), cursor: 0, position: .seconds(5)))
        #expect(run.snapshot(at: moment(1)).totalElapsed == .seconds(6))
    }

    @Test
    func test_clockMovedBackRightAfterStart_doesNotStall() {
        var run = RunOperation.start.applied(to: makeRun(makePausedWorkout()), at: moment(100))
        run.tick(at: moment(90))

        #expect(run.snapshot(at: moment(91)).totalElapsed == .seconds(1))
    }

    @Test
    func test_clockMovedBack_keepsCommittedManualPause() {
        var run = running
        run.tick(at: moment(20))
        let committed = run

        run.tick(at: origin)
        #expect(run == committed)
    }

    @Test
    func test_rebaseAfterClockMovedBack_restoresShownProgress() {
        var run = running
        run.tick(at: moment(5))
        let shown = run.snapshot(at: moment(8)).totalElapsed

        run.tick(at: moment(6))
        run.rebase(at: moment(6), keepingTotalElapsed: shown)

        #expect(RunState(run) == RunState(.running(since: moment(6)), cursor: 0, position: .seconds(8)))
        #expect(run.snapshot(at: moment(7)).totalElapsed == .seconds(9))
    }

    // MARK: - Rebase

    @Test(arguments: [
        (Duration.seconds(1), RunState(.running(since: moment(3)), cursor: 0, position: .seconds(3))),
        (.seconds(-1), RunState(.running(since: moment(3)), cursor: 0, position: .seconds(3))),
        (.seconds(7), RunState(.running(since: moment(3)), cursor: 0, position: .seconds(7))),
        (.seconds(7) + .microseconds(500), RunState(.running(since: moment(3)), cursor: 0, position: .seconds(7))),
        (.seconds(10), RunState(.running(since: moment(3)), cursor: 1, position: .seconds(10))),
        (.seconds(20), RunState(.awaitingUser, cursor: 2, position: .seconds(15))),
        (.seconds(Int64.max), RunState(.awaitingUser, cursor: 2, position: .seconds(15))),
    ])
    func test_rebase_neverMovesBackQuantizesAndStopsAtManualPause(kept: Duration, expected: RunState) {
        var run = running
        run.tick(at: moment(3))
        run.rebase(at: moment(3), keepingTotalElapsed: kept)

        #expect(RunState(run) == expected)
    }

    @Test
    func test_rebase_toTotalWithoutManualPause_finishes() {
        let workout = Workout(id: UUID(fixture: 904), warmUp: [makeStage(1, .seconds(10)), makeStage(2, .seconds(15))])
        var run = RunOperation.start.applied(to: makeRun(workout), at: origin)
        run.rebase(at: moment(1), keepingTotalElapsed: .seconds(25))

        #expect(RunState(run) == RunState(.finished, cursor: 2, position: .seconds(25)))
    }
}
