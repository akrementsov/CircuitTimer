import ComposableArchitecture
import Foundation
import WorkoutDomain
import WorkoutTimerFeature

extension AppFeature {
    /// Presents the timer over the tab bar; the Workouts stack returns to the list once the cover is up.
    func startWorkout(_ workout: Workout, _ state: inout State) -> Effect<Action> {
        // The workout's screen offers Start only for a playable workout and never under a presentation.
        guard state.destination == nil else {
            Self.logger.error("Refused to start a workout while something is presented")
            return .none
        }
        guard workout.isPlayable else {
            Self.logger.error("Refused to start a workout with nothing to play")
            return .none
        }
        guard let editorID = state.path.ids.last else {
            Self.logger.error("Refused to start a workout without its screen")
            return .none
        }
        if let intent = state.startIntent {
            // Start is free again only once the Health sheet has stalled; this tap goes on without it.
            guard intent.stage == .health, state.isHealthRequestOutstanding else { return .none }

            return .merge(discardStartIntent(&state), openTimer(workout, editorID: editorID, &state))
        }
        return prepareNotificationPermission(workout, editorID: editorID, &state)
    }

    // A timer's state is built only here and in `restoredTimerState`, so both get the same identifiers and title.

    func timerState(for workout: Workout) -> WorkoutTimerFeature.State {
        WorkoutTimerFeature.State(
            id: uuid(),
            workoutID: workout.id,
            title: workout.displayName,
            workoutName: workout.name,
            schedule: WorkoutSchedule(workout: workout)
        )
    }

    /// A timer over a saved run already settled at `now`.
    func restoredTimerState(for workout: Workout, run: WorkoutRun, at now: Date) -> WorkoutTimerFeature.State {
        WorkoutTimerFeature.State(
            id: uuid(),
            workoutID: workout.id,
            title: workout.displayName,
            workoutName: workout.name,
            restoring: run,
            at: now
        )
    }
}
