@testable import WorkoutDomain

import Foundation
import Testing

/// The snapshot table from docs/timer-engine.md, on the 25 s fixture:
/// 0 work 0–10 s, 1 rest 10–15 s, 2 manual pause at 15 s, 3 work 15–25 s.
@Suite
struct WorkoutRunSnapshotTests {
    private let idle = makeRun(makePausedWorkout())

    private var stages: [ScheduledStage] {
        idle.schedule.stages
    }

    @Test
    func test_snapshot_idle_showsFirstStageAndWholeWorkoutAhead() {
        #expect(idle.snapshot(at: origin) == WorkoutRun.Snapshot(
            status: .idle,
            currentStage: stages[0],
            nextStage: stages[1],
            stageElapsed: .zero,
            stageRemaining: .seconds(10),
            totalElapsed: .zero,
            totalRemaining: .seconds(25),
            currentStageEndDate: nil
        ))
    }

    @Test
    func test_snapshot_idleSingleStage_hasNoNextStage() {
        let run = makeRun(Workout(id: UUID(fixture: 905), warmUp: [makeStage(1, .seconds(10))]))

        #expect(run.snapshot(at: origin).nextStage == nil)
    }

    @Test
    func test_snapshot_running_derivesProgressAndEndDateFromNow() {
        let run = RunOperation.start.applied(to: idle, at: origin)

        #expect(run.snapshot(at: moment(3)) == WorkoutRun.Snapshot(
            status: .running,
            currentStage: stages[0],
            nextStage: stages[1],
            stageElapsed: .seconds(3),
            stageRemaining: .seconds(7),
            totalElapsed: .seconds(3),
            totalRemaining: .seconds(22),
            currentStageEndDate: moment(10)
        ))
    }

    @Test
    func test_snapshot_paused_keepsStoredProgressWithoutEndDate() {
        var run = RunOperation.start.applied(to: idle, at: origin)
        run.pause(at: moment(3))

        #expect(run.snapshot(at: moment(3_600)) == WorkoutRun.Snapshot(
            status: .paused,
            currentStage: stages[0],
            nextStage: stages[1],
            stageElapsed: .seconds(3),
            stageRemaining: .seconds(7),
            totalElapsed: .seconds(3),
            totalRemaining: .seconds(22),
            currentStageEndDate: nil
        ))
    }

    @Test
    func test_snapshot_awaitingUser_showsManualPauseAndWhatFollows() {
        var run = RunOperation.start.applied(to: idle, at: origin)
        run.tick(at: moment(20))

        #expect(run.snapshot(at: moment(3_600)) == WorkoutRun.Snapshot(
            status: .awaitingUser,
            currentStage: stages[2],
            nextStage: stages[3],
            stageElapsed: .zero,
            stageRemaining: .zero,
            totalElapsed: .seconds(15),
            totalRemaining: .seconds(10),
            currentStageEndDate: nil
        ))
    }

    @Test
    func test_snapshot_lastStage_hasNoNextStage() {
        var run = RunOperation.start.applied(to: idle, at: origin)
        run.tick(at: moment(20))
        run.resume(at: moment(20))

        #expect(run.snapshot(at: moment(21)).currentStage == stages[3])
        #expect(run.snapshot(at: moment(21)).nextStage == nil)
    }

    @Test
    func test_snapshot_finished_showsWholeWorkoutDone() {
        var run = RunOperation.start.applied(to: idle, at: origin)
        // Work → rest → manual pause → last work → finished.
        for _ in 0..<4 {
            run.skipToNextStage(at: moment(1))
        }

        #expect(run.snapshot(at: moment(2)) == WorkoutRun.Snapshot(
            status: .finished,
            currentStage: nil,
            nextStage: nil,
            stageElapsed: .zero,
            stageRemaining: .zero,
            totalElapsed: .seconds(25),
            totalRemaining: .zero,
            currentStageEndDate: nil
        ))
    }
}
