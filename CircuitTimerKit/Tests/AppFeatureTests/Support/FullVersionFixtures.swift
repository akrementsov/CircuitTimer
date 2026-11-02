@testable import AppFeature

import Foundation
import Purchases
import Testing
import WorkoutDomain
import WorkoutStorage
import WorkoutTimerFeature

/// A loaded list whose launch question is settled, with the full version `status` known at the root and in Settings.
func freeVersion(_ workouts: [Workout], status: FullVersionStatus = .free) -> AppFeature.State {
    var state = loaded(workouts)
    state.fullVersion = status
    state.settings.fullVersion = status
    state.runRestore = .resolved
    return state
}

/// A run of `workout` paused a few seconds after it started at `date`, saved then: offered at a launch at `date`.
func pausedRun(of workout: Workout, at date: Date) throws -> StoredRunRecord {
    var run = WorkoutRun(schedule: WorkoutSchedule(workout: workout))
    run.start(at: date)
    run.pause(at: date.addingTimeInterval(3))
    return StoredRunRecord(record: try #require(WorkoutRunRecord(workoutID: workout.id, run: run)), savedAt: date)
}

func timerState(for workout: Workout, id: UUID = UUID(0)) -> WorkoutTimerFeature.State {
    WorkoutTimerFeature.State(
        id: id,
        workoutID: workout.id,
        title: workout.name,
        workoutName: workout.name,
        schedule: WorkoutSchedule(workout: workout)
    )
}
