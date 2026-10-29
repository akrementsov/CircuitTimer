import ComposableArchitecture
import Foundation

extension WorkoutTimerFeature {
    /// Holds a workout session while the cover is open, so iOS keeps the app running in the background and lets it end
    /// the card and notifications when the app is closed. HealthKit refuses a start from the background, so it waits
    /// for an active scene once the clock has started; the client ignores a repeat, and a start that failed is tried
    /// again on the next return to the app.
    func startHealthSession(_ state: State, after action: Action, at now: Date) -> Effect<Action> {
        guard action == .view(.task) || action == .view(.scenePhaseChanged(.active)),
              state.isSceneActive, state.clockGeneration > 0, !state.isClosing
        else { return .none }

        return .run { [workoutHealth, id = state.id] _ in
            await workoutHealth.start(id, now)
        }
    }
}
