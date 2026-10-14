@testable import WorkoutDomain

import Foundation
import Testing

@Suite
struct WorkoutRunRestoreTests {
    @Test(arguments: [2.0, 12.0, 1_000.0])
    func test_restore_running_commitsElapsedTimeUntilManualPause(elapsed: Double) throws {
        let workout = makePausedWorkout()
        var run = makeRun(workout)
        run.start(at: origin)
        let record = try #require(WorkoutRunRecord(workoutID: workout.id, run: run))

        let restored = try WorkoutRun(schedule: run.schedule, restoring: record, at: moment(elapsed))

        if elapsed < 10 {
            #expect(restored.cursor == 0)
            #expect(restored.position == .seconds(2))
        } else if elapsed < 15 {
            #expect(restored.cursor == 1)
            #expect(restored.position == .seconds(12))
        } else {
            #expect(restored.phase == .awaitingUser)
            #expect(restored.cursor == 2)
            #expect(restored.position == .seconds(15))
        }
    }

    @Test(arguments: [false, true])
    func test_restore_stopped_doesNotCountTimeAway(manualPause: Bool) throws {
        let workout = makePausedWorkout()
        var run = makeRun(workout)
        run.start(at: origin)
        if manualPause {
            run.tick(at: moment(15))
        } else {
            run.pause(at: moment(3))
        }
        let record = try #require(WorkoutRunRecord(workoutID: workout.id, run: run))

        let restored = try WorkoutRun(schedule: run.schedule, restoring: record, at: moment(1_000))

        #expect(RunState(restored) == RunState(run))
        #expect(record.sinceEpochMs == nil)
    }

    @Test
    func test_restore_runningPastEnd_finishes() throws {
        let workout = Workout(id: UUID(fixture: 1), training: [makeStage(1, .seconds(10))])
        var run = makeRun(workout)
        run.start(at: origin)
        let record = try #require(WorkoutRunRecord(workoutID: workout.id, run: run))

        let restored = try WorkoutRun(schedule: run.schedule, restoring: record, at: moment(1_000))

        #expect(RunState(restored) == RunState(.finished, cursor: 1, position: .seconds(10)))
        #expect(WorkoutRunRecord(workoutID: workout.id, run: restored) == nil)
    }

    @Test
    func test_restore_clockBeforeAnchor_keepsSavedProgressAndReanchors() throws {
        let workout = makePausedWorkout()
        var run = makeRun(workout)
        run.start(at: origin)
        run.tick(at: moment(3))
        let record = try #require(WorkoutRunRecord(workoutID: workout.id, run: run))

        var restored = try WorkoutRun(schedule: run.schedule, restoring: record, at: moment(-100))
        #expect(RunState(restored) == RunState(.running(since: moment(-100)), cursor: 0, position: .seconds(3)))
        restored.tick(at: moment(-99))
        #expect(restored.position == .seconds(4))
    }

    @Test(arguments: [-1, 4, Int.max])
    func test_restore_invalidCursor_rejects(cursor: Int) throws {
        let schedule = WorkoutSchedule(workout: makePausedWorkout())
        let record = WorkoutRunRecord(
            workoutID: UUID(fixture: 1),
            scheduleFingerprint: schedule.fingerprint,
            phase: .paused,
            positionMs: 0,
            cursor: cursor,
            sinceEpochMs: nil,
        )
        #expect(throws: WorkoutRun.RestoreError.cursorOutOfRange) {
            try WorkoutRun(schedule: schedule, restoring: record, at: origin)
        }
    }

    @Test(arguments: [-1, 10_000, Int64.max])
    func test_restore_positionOutsideCurrentStage_rejects(positionMs: Int64) {
        let schedule = WorkoutSchedule(workout: makePausedWorkout())
        let record = WorkoutRunRecord(
            workoutID: UUID(fixture: 1),
            scheduleFingerprint: schedule.fingerprint,
            phase: .paused,
            positionMs: positionMs,
            cursor: 0,
            sinceEpochMs: nil,
        )
        #expect(throws: WorkoutRun.RestoreError.inconsistentState) {
            try WorkoutRun(schedule: schedule, restoring: record, at: origin)
        }
    }

    @Test(arguments: [WorkoutRunRecord.Phase.running, .paused, .awaitingUser])
    func test_restore_phaseAnchorOrStageMismatch_rejects(phase: WorkoutRunRecord.Phase) {
        let schedule = WorkoutSchedule(workout: makePausedWorkout())
        let record = WorkoutRunRecord(
            workoutID: UUID(fixture: 1),
            scheduleFingerprint: schedule.fingerprint,
            phase: phase,
            positionMs: 0,
            cursor: 0,
            sinceEpochMs: phase == .paused ? 0 : nil,
        )
        #expect(throws: WorkoutRun.RestoreError.inconsistentState) {
            try WorkoutRun(schedule: schedule, restoring: record, at: origin)
        }
    }

    @Test(arguments: [WorkoutRunRecord.Phase.running, .paused, .awaitingUser])
    func test_restore_manualPauseWithInvalidPhaseOrAnchor_rejects(phase: WorkoutRunRecord.Phase) {
        let schedule = WorkoutSchedule(workout: makePausedWorkout())
        let record = WorkoutRunRecord(
            workoutID: UUID(fixture: 1),
            scheduleFingerprint: schedule.fingerprint,
            phase: phase,
            positionMs: 15_000,
            cursor: 2,
            sinceEpochMs: 1_700_000_000_000,
        )
        #expect(throws: WorkoutRun.RestoreError.inconsistentState) {
            try WorkoutRun(schedule: schedule, restoring: record, at: origin)
        }
    }

    @Test(arguments: [Int64(9_999), 15_000])
    func test_restore_laterStageOutsideItsBounds_rejects(positionMs: Int64) {
        let schedule = WorkoutSchedule(workout: makePausedWorkout())
        let record = WorkoutRunRecord(
            workoutID: UUID(fixture: 1),
            scheduleFingerprint: schedule.fingerprint,
            phase: .paused,
            positionMs: positionMs,
            cursor: 1,
            sinceEpochMs: nil,
        )
        #expect(throws: WorkoutRun.RestoreError.inconsistentState) {
            try WorkoutRun(schedule: schedule, restoring: record, at: origin)
        }
    }

    @Test
    func test_restore_changedSchedule_rejectsFingerprint() throws {
        let workout = makePausedWorkout()
        var run = makeRun(workout)
        run.start(at: origin)
        let record = try #require(WorkoutRunRecord(workoutID: workout.id, run: run))
        var changed = workout
        changed.training[0].duration = .seconds(20)

        #expect(throws: WorkoutRun.RestoreError.fingerprintMismatch) {
            try WorkoutRun(schedule: WorkoutSchedule(workout: changed), restoring: record, at: origin)
        }
    }
}
