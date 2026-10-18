import Dependencies
import Foundation
import UITestContract
import WorkoutDomain
import WorkoutStorage

#if DEBUG
extension AppScenario {
    /// The workouts the list loads.
    var workouts: [Workout] {
        switch self {
            case .emptyList:
                []
            case .oneWorkout:
                [.legDay]
        }
    }
}

private extension Workout {
    /// Two rounds of 40 seconds of work and 20 of rest: two minutes in all.
    static let legDay = Workout(
        id: UUID(0xF1_0001),
        name: ScenarioFixture.workoutName,
        training: [
            Stage(id: UUID(0xF1_0002), name: "Squats", duration: .seconds(40), intensity: .work),
            Stage(id: UUID(0xF1_0003), name: "", duration: .seconds(20), intensity: .rest),
        ],
        trainingRounds: 2
    )
}

extension WorkoutStorageClient {
    /// The scenario's workouts in memory. Reading and saving work; the list's insert, delete and reorder stop the
    /// app until a scenario needs them.
    static func scenario(_ workouts: [Workout]) -> Self {
        let stored = LockIsolated(workouts)
        return Self(
            fetchAll: { StoredWorkouts(workouts: stored.value) },
            save: { workout in
                stored.withValue { workouts in
                    if let index = workouts.firstIndex(where: { $0.id == workout.id }) {
                        workouts[index] = workout
                    } else {
                        workouts.append(workout)
                    }
                }
            },
            insert: { _, _ in fatalError("Scenario storage has no insert yet; implement it with the scenario that needs it") },
            delete: { _ in fatalError("Scenario storage has no delete yet; implement it with the scenario that needs it") },
            reorder: { _ in fatalError("Scenario storage has no reorder yet; implement it with the scenario that needs it") }
        )
    }
}
#endif
