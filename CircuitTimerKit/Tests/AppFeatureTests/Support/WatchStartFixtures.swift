@testable import AppFeature

import ComposableArchitecture
import Foundation
import WatchLink
import WorkoutDomain
import WorkoutTimerFeature

@MainActor
struct WatchStartFixture {
    let workout = makeWorkout(1)

    var request: WatchStartRequest {
        WatchStartRequest(id: 7, workoutID: workout.id, scheduleFingerprint: WorkoutSchedule(workout: workout).fingerprint)
    }

    func ready() -> AppFeature.State {
        var state = loaded([workout])
        state.hasScenePhase = true
        state.runRestore = .resolved
        return state
    }

    func pending(_ clock: TestClock<Duration>, stage: AppFeature.StartIntent.Stage = .health) -> AppFeature.State {
        var state = ready()
        state.startGeneration = 1
        state.startIntent = .init(
            generation: 1,
            origin: .watch(requestID: 7),
            workout: workout,
            stage: stage,
            acceptedAt: MonotonicInstant(now: clock)
        )
        return state
    }

    var timer: WorkoutTimerFeature.State {
        WorkoutTimerFeature.State(
            id: UUID(0),
            workoutID: workout.id,
            title: workout.name,
            workoutName: workout.name,
            schedule: WorkoutSchedule(workout: workout)
        )
    }
}
